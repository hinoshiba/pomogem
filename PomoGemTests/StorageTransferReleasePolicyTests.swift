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

    // MARK: - Three independent bits

    func testStandardPolicyKeepsAllThreeReplacementBitsClosed() throws {
        let policy = StorageTransferReleasePolicy.standard
        XCTAssertFalse(policy.allowsCloudReplacement)
        XCTAssertFalse(policy.allowsDatasetOverwriteFromDevice)
        XCTAssertFalse(policy.allowsRemoteResumeBeforeReplacing)
        XCTAssertNoThrow(try policy.validate(.enableCloudKeepingCloud))
        XCTAssertNoThrow(try policy.validate(.disableCloudKeepingCopy))
        XCTAssertThrowsError(try policy.validate(.overwriteCloudFromDevice)) {
            XCTAssertEqual($0 as? StorageTransferReleaseError, .datasetOverwriteUnavailable)
        }
        XCTAssertThrowsError(try policy.requireRemoteResumeIsPublished()) {
            XCTAssertEqual($0 as? StorageTransferReleaseError, .remoteReplacementResumeUnavailable)
        }
        for phase in StorageTransferRecoveryControl.Phase.allCases {
            XCTAssertThrowsError(try policy.validateRemoteResume(phase), "Phase: \(phase)") {
                XCTAssertEqual($0 as? StorageTransferReleaseError, .remoteReplacementResumeUnavailable)
            }
        }
    }

    func testLegacyRefusalTextIsUnchangedAndTheNewCasesCarryTheirOwnWording() {
        XCTAssertEqual(StorageTransferReleaseError.cloudReplacementUnavailable.localizedDescription,
            "複数端末での同時操作から記録を保護するため、iCloudの置き換えと、その復旧の再開は一時的に利用できません。端末のデータと復旧用コピーは削除せず保持します。")
        let texts = [StorageTransferReleaseError.cloudReplacementUnavailable.localizedDescription,
                     StorageTransferReleaseError.datasetOverwriteUnavailable.localizedDescription,
                     StorageTransferReleaseError.remoteReplacementResumeUnavailable.localizedDescription]
        XCTAssertEqual(Set(texts).count, 3)
        // Every refusal states that nothing was deleted.
        XCTAssertTrue(texts.allSatisfy { $0.contains("削除せず保持します") })
    }

    func testOverwriteRefusalHappensBeforeAnyJournalFileIsCreated() async throws {
        let (root, store, runtime, binding) = try fixture()
        let context = try contextWithUnsavedChange()
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        do {
            try await runtime.begin(choice: .overwriteCloudFromDevice,
                source: .cloud(binding: binding), sourceContext: context, validateAccess: {})
            XCTFail("The ordinary Runtime must refuse an overwrite before any source check")
        } catch { XCTAssertEqual(error as? StorageTransferReleaseError, .datasetOverwriteUnavailable) }
        XCTAssertTrue(context.hasChanges)
        XCTAssertNil(try store.load())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
    }

    func testNormalRuntimeKeepsEveryPendingOverwritePhaseAndSourceEvidenceUnchanged() async throws {
        for phase in StorageTransferJournal.Phase.allCases {
            let (root, store, runtime, binding) = try fixture()
            let previous = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                                   accountFingerprint: digest))
            var journal = try StorageTransferJournal(choice: .overwriteCloudFromDevice,
                source: .cloud(binding: previous), destination: .cloud(binding: binding),
                cloudBinding: binding)
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
            let evidence = root.appendingPathComponent("synthetic-source-evidence")
            let bytes = Data("unchanged synthetic source".utf8)
            try bytes.write(to: evidence)
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
            let selection = try store.committedSelection()
            var containers = 0
            do {
                try await runtime.resumePendingTransfer(validateAccess: {}, trackContainer: { _, _ in containers += 1 })
                XCTFail("Expected overwrite refusal for \(phase)")
            } catch {
                XCTAssertEqual(error as? StorageTransferReleaseError, .datasetOverwriteUnavailable, "Phase: \(phase)")
            }
            XCTAssertEqual(try store.load(), journal)
            XCTAssertEqual(try store.committedSelection(), selection)
            XCTAssertEqual(try Data(contentsOf: evidence), bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), names)
            XCTAssertEqual(containers, 0)
        }
    }

    #if DEBUG
    func testRemoteResumeIsRefusedAtReplacingEvenWhenOverwriteIsPermitted() throws {
        let published = StorageTransferReleasePolicy.isolatedTestingPolicy(
            allowsDatasetOverwriteFromDevice: true, allowsRemoteResumeBeforeReplacing: true)
        // The backupVerified -> replacing CAS elects exactly one executor. Any
        // later arrival observes .replacing and is refused.
        XCTAssertNoThrow(try published.requireRemoteResumeIsPublished())
        XCTAssertNoThrow(try published.validateRemoteResume(.staging))
        XCTAssertNoThrow(try published.validateRemoteResume(.backupVerified))
        for phase in [StorageTransferRecoveryControl.Phase.replacing, .committed, .cancelled] {
            XCTAssertThrowsError(try published.validateRemoteResume(phase), "Phase: \(phase)") {
                XCTAssertEqual($0 as? StorageTransferReleaseError, .remoteReplacementResumeUnavailable)
            }
        }
        let overwriteOnly = StorageTransferReleasePolicy.isolatedTestingPolicy(allowsDatasetOverwriteFromDevice: true)
        XCTAssertThrowsError(try overwriteOnly.requireRemoteResumeIsPublished())
        for phase in StorageTransferRecoveryControl.Phase.allCases {
            XCTAssertThrowsError(try overwriteOnly.validateRemoteResume(phase), "Phase: \(phase)")
        }
    }

    func testEnablingOverwriteDoesNotEnableLocalOnlyReplacement() throws {
        let overwrite = StorageTransferReleasePolicy.isolatedTestingPolicy(
            allowsDatasetOverwriteFromDevice: true, allowsRemoteResumeBeforeReplacing: true)
        XCTAssertFalse(overwrite.allowsCloudReplacement)
        XCTAssertNoThrow(try overwrite.validate(.overwriteCloudFromDevice))
        XCTAssertThrowsError(try overwrite.validate(.enableCloudReplacingCloud)) {
            XCTAssertEqual($0 as? StorageTransferReleaseError, .cloudReplacementUnavailable)
        }
        let legacyOnly = StorageTransferReleasePolicy.isolatedTestingPolicy(allowsCloudReplacement: true)
        XCTAssertNoThrow(try legacyOnly.validate(.enableCloudReplacingCloud))
        XCTAssertThrowsError(try legacyOnly.validate(.overwriteCloudFromDevice)) {
            XCTAssertEqual($0 as? StorageTransferReleaseError, .datasetOverwriteUnavailable)
        }
        XCTAssertThrowsError(try legacyOnly.requireRemoteResumeIsPublished())
    }

    func testIsolatedTestingIsTheOnlyPolicyConstantThatPassesAnyBit() throws {
        let isolated = StorageTransferReleasePolicy.isolatedTesting
        XCTAssertTrue(isolated.allowsCloudReplacement)
        XCTAssertTrue(isolated.allowsDatasetOverwriteFromDevice)
        XCTAssertTrue(isolated.allowsRemoteResumeBeforeReplacing)
        for choice in StorageTransferChoice.allCases { XCTAssertNoThrow(try isolated.validate(choice)) }
        XCTAssertEqual(StorageTransferReleasePolicy.standard,
                       StorageTransferReleasePolicy.isolatedTestingPolicy())
    }
    #endif
}
