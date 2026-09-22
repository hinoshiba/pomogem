import Foundation
import SwiftData
import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferReleasePolicyTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    private func fixture() throws -> (URL, StorageTransferJournalStore, StorageTransferRuntime, ActiveAccountLocalBinding) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("TransferReleasePolicy-\(UUID())", isDirectory: true)
        // The runtime's cancellation/cleanup workers require the exact feature
        // root name; a random root would fail path validation before the policy.
        let root = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let store = StorageTransferJournalStore(directory: root)
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: digest))
        let runtime = StorageTransferRuntime(store: store, root: root)
        XCTAssertNil(try runtime.pendingRemoteCancellationIntent(), "The real path/intent prerequisites must pass before exercising release policy")
        return (root, store, runtime, binding)
    }

    private func contextWithUnsavedChange() throws -> ModelContext {
        let schema = PersistenceStoreTopology.shippingSchema
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(
            "ReplacementPolicy-\(UUID())", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.insert(Subject(name: "synthetic preserved source", colorHex: "blue", sortOrder: 0))
        return context
    }

    func testStandardPolicyBlocksOnlyCloudReplacementInEveryBuildConfiguration() throws {
        XCTAssertFalse(StorageTransferReleasePolicy.standard.allowsCloudReplacement)
        XCTAssertNoThrow(try StorageTransferReleasePolicy.standard.validate(.enableCloudKeepingCloud))
        XCTAssertNoThrow(try StorageTransferReleasePolicy.standard.validate(.disableCloudKeepingCopy))
        XCTAssertThrowsError(try StorageTransferReleasePolicy.standard.validate(.enableCloudReplacingCloud)) {
            XCTAssertEqual($0 as? StorageTransferReleaseError, .cloudReplacementUnavailable)
        }
    }

    func testNormalRuntimeRejectsNewReplacementBeforeSourceChecksOrCreatingJournal() async throws {
        let (root, store, runtime, _) = try fixture()
        let context = try contextWithUnsavedChange()
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        do {
            try await runtime.begin(choice: .enableCloudReplacingCloud,
                source: .localOnly(namespace: AccountDataNamespace()), sourceContext: context, validateAccess: {})
            XCTFail("The ordinary Runtime must refuse replacement before account resolution")
        } catch { XCTAssertEqual(error as? StorageTransferReleaseError, .cloudReplacementUnavailable) }
        XCTAssertTrue(context.hasChanges)
        XCTAssertNil(try store.load())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
    }

    func testNormalRuntimeKeepsEveryPendingReplacementPhaseAndSourceEvidenceUnchanged() async throws {
        for phase in StorageTransferJournal.Phase.allCases {
            let (root, store, runtime, binding) = try fixture()
            var journal = try StorageTransferJournal(choice: .enableCloudReplacingCloud,
                source: .localOnly(namespace: AccountDataNamespace()), destination: .cloud(binding: binding), cloudBinding: binding)
            try store.begin(journal)
            for nextPhase in StorageTransferJournal.Phase.allCases.dropFirst() where nextPhase <= phase {
                if nextPhase == .selectionCommitted { try store.commitSelection(for: journal) }
                let next = try journal.advancing(to: nextPhase,
                    sourceDigest: nextPhase == .sourceSaved ? digest : nil,
                    destinationDigest: nextPhase == .destinationSaved ? digest : nil,
                    remoteRecoveryTransactionID: nextPhase == .recoveryCopySaved ? journal.transactionID : nil)
                try store.save(next, replacing: journal)
                journal = next
            }
            // Deliberately omit a runtime checkpoint. A publication gate must
            // run before opening/copying any transaction data or remote client.
            let evidence = root.appendingPathComponent("synthetic-source-evidence")
            let bytes = Data("unchanged synthetic source".utf8)
            try bytes.write(to: evidence)
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
            let selection = try store.committedSelection()
            var containers = 0
            do {
                try await runtime.resumePendingTransfer(validateAccess: {}, trackContainer: { _, _ in containers += 1 })
                XCTFail("Expected release refusal for \(phase)")
            } catch { XCTAssertEqual(error as? StorageTransferReleaseError, .cloudReplacementUnavailable, "Phase: \(phase)") }
            XCTAssertEqual(try store.load(), journal)
            XCTAssertEqual(try store.committedSelection(), selection)
            XCTAssertEqual(try Data(contentsOf: evidence), bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), names)
            XCTAssertEqual(containers, 0)
        }
    }

    func testServerOnlyRecoveryCannotCreateASecondExecutorOrAnyLocalFiles() async throws {
        let (root, store, runtime, binding) = try fixture()
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        do {
            try await runtime.recoverRemoteTransfer(binding: binding, expectedTransactionID: UUID(), validateAccess: {})
            XCTFail("A fresh installation must not become another destructive executor")
        } catch { XCTAssertEqual(error as? StorageTransferReleaseError, .cloudReplacementUnavailable) }
        XCTAssertNil(try store.load())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
    }

    func testNoPendingTransferRemainsANoop() async throws {
        let (_, store, runtime, _) = try fixture()
        var tracked = 0
        try await runtime.resumePendingTransfer(validateAccess: {}, trackContainer: { _, _ in tracked += 1 })
        XCTAssertEqual(tracked, 0)
        XCTAssertNil(try store.load())
    }

    #if DEBUG
    func testOnlyExplicitIsolatedInjectionCanPassReplacementPolicyAndStillCannotBypassRuntimeGuards() async throws {
        let (root, store, ordinary, _) = try fixture()
        let isolated = StorageTransferRuntime(store: store, root: root, releasePolicy: .isolatedTesting)
        let context = try contextWithUnsavedChange()
        for (runtime, allowsExperiment) in [(ordinary, false), (isolated, true)] {
            do {
                try await runtime.begin(choice: .enableCloudReplacingCloud,
                    source: .localOnly(namespace: AccountDataNamespace()), sourceContext: context, validateAccess: {})
                XCTFail("An unsaved source cannot reach account resolution even with isolated injection")
            } catch {
                if allowsExperiment { XCTAssertEqual(error as? StorageTransferError, .activeTimer) }
                else { XCTAssertEqual(error as? StorageTransferReleaseError, .cloudReplacementUnavailable) }
            }
        }
        XCTAssertNil(try store.load())
    }
    #endif
}
