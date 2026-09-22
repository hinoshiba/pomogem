import Foundation
import XCTest
@testable import PomoGem

/// Real Runtime admission files and guards; only Apple/CloudKit responses are
/// injected. No model container or cloud transport is constructed here.
@MainActor
final class StorageTransferRuntimeAdmissionTests: XCTestCase {
    private let account = String(repeating: "a", count: 64)

    private struct Fixture {
        let root: URL
        let binding: ActiveAccountLocalBinding
        let control: StorageTransferRecoveryControl
        let store: StorageTransferJournalStore
        let intent: StorageTransferRemoteCancellation
        let runtime: StorageTransferRuntime
        let admission: StorageTransferStateFile<StorageTransferDatasetAdmission>
    }

    private func fixture(hasGeneration: Bool = false) throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("RuntimeAdmission-\(UUID())")
        let root = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: account))
        let manifest = try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account,
            payload: Data("synthetic admission payload".utf8), previousDatasetGenerationID: hasGeneration ? UUID() : nil)
        let control = try StorageTransferRecoveryControl(manifest: manifest).cancelling()
        let store = StorageTransferJournalStore(directory: root)
        let cleanup = try StorageTransferCleanup(featureRoot: root, journalStore: store, validateLocalCleanup: {})
        return Fixture(root: root, binding: binding, control: control, store: store,
            intent: try StorageTransferRemoteCancellation(featureRoot: root, journalStore: store, cleanup: cleanup),
            runtime: StorageTransferRuntime(store: store, root: root),
            admission: try StorageTransferStateFile(url: root.appendingPathComponent("admission-\(binding.namespace.rawValue).json")))
    }

    private func accept(_ f: Fixture) throws {
        try f.intent.accept(binding: f.binding, expectedTransactionID: f.control.manifest.transactionID,
                            observedControl: f.control, validateAccess: {})
    }

    private func expectIntentBlock(_ action: () async throws -> Void,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected pending cancellation to block admission", file: file, line: line) }
        catch { XCTAssertEqual(error as? StorageTransferRemoteCancellationError, .conflictingIntent, file: file, line: line) }
    }

    func testStablePreflightAcknowledgesOnlyExactAccountAndDataset() async throws {
        let f = try fixture()
        var reads = 0
        try await f.runtime.preflightCloudMount(binding: f.binding, readControl: {
            reads += 1
            return f.control
        }, validateAccess: {})
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(try f.admission.load(), StorageTransferDatasetAdmission(binding: f.binding, datasetGenerationID: nil))
        XCTAssertNil(try f.store.load())
    }

    func testExistingIntentBlocksPreflightAndRefreshBeforeAccountOrCloudRead() async throws {
        let f = try fixture(hasGeneration: true)
        try accept(f)
        var accountChecks = 0
        var reads = 0
        await expectIntentBlock {
            try await f.runtime.preflightCloudMount(binding: f.binding, readControl: {
                reads += 1; return f.control
            }, validateAccess: {})
        }
        let generation = try XCTUnwrap(f.control.datasetGenerationID)
        await expectIntentBlock {
            try await f.runtime.refreshCloudDataset(binding: f.binding, expectedGenerationID: generation,
                verifyAccount: { accountChecks += 1; return f.binding },
                readControl: { reads += 1; return f.control }, validateAccess: {})
        }
        XCTAssertEqual(accountChecks, 0)
        XCTAssertEqual(reads, 0)
        XCTAssertNil(try f.admission.load())
        XCTAssertNil(try f.store.load())
    }

    func testIntentAcceptedDuringInitialCloudReadPreventsAdmissionFileWrite() async throws {
        let f = try fixture()
        var reads = 0
        await expectIntentBlock {
            try await f.runtime.preflightCloudMount(binding: f.binding, readControl: {
                reads += 1
                try self.accept(f)
                return f.control
            }, validateAccess: {})
        }
        XCTAssertEqual(reads, 1)
        XCTAssertNil(try f.admission.load())
        XCTAssertNotNil(try f.intent.pendingIntent())
    }

    func testIntentAcceptedDuringFinalCloudReadPreventsSuccessfulMountAdmission() async throws {
        let f = try fixture()
        var reads = 0
        var callerCouldConstructContainer = false
        await expectIntentBlock {
            try await f.runtime.preflightCloudMount(binding: f.binding, readControl: {
                reads += 1
                if reads == 2 { try self.accept(f) }
                return f.control
            }, validateAccess: {})
            callerCouldConstructContainer = true
        }
        XCTAssertEqual(reads, 2)
        XCTAssertFalse(callerCouldConstructContainer)
        XCTAssertNotNil(try f.intent.pendingIntent())
        // An earlier matching cache admission file is not sufficient to pass
        // the next launch while the separate cancellation intent is pending.
        XCTAssertNotNil(try f.admission.load())
        await expectIntentBlock {
            try await f.runtime.preflightCloudMount(binding: f.binding, readControl: {
                XCTFail("Pending intent must fail before another read")
                return f.control
            }, validateAccess: {})
        }
    }

    func testIntentAcceptedDuringAccountVerificationStopsRefreshBeforeCloudRead() async throws {
        let f = try fixture(hasGeneration: true)
        let generation = try XCTUnwrap(f.control.datasetGenerationID)
        var reads = 0
        await expectIntentBlock {
            try await f.runtime.refreshCloudDataset(binding: f.binding, expectedGenerationID: generation,
                verifyAccount: { try self.accept(f); return f.binding },
                readControl: { reads += 1; return f.control }, validateAccess: {})
        }
        XCTAssertEqual(reads, 0)
        XCTAssertNil(try f.store.load())
        XCTAssertNotNil(try f.intent.pendingIntent())
    }

    func testIntentAcceptedDuringFinalRefreshReadPreventsConflictingLocalJournal() async throws {
        let f = try fixture(hasGeneration: true)
        let generation = try XCTUnwrap(f.control.datasetGenerationID)
        var reads = 0
        await expectIntentBlock {
            try await f.runtime.refreshCloudDataset(binding: f.binding, expectedGenerationID: generation,
                verifyAccount: { f.binding }, readControl: {
                    reads += 1
                    if reads == 2 { try self.accept(f) }
                    return f.control
                }, validateAccess: {})
        }
        XCTAssertEqual(reads, 2)
        XCTAssertNil(try f.store.load(), "A local journal and remote-only intent must not deadlock each other's recovery")
        XCTAssertNotNil(try f.intent.pendingIntent())
    }

    func testStableRefreshCreatesDifferentNamespaceWithExactVerifiedGeneration() async throws {
        let f = try fixture(hasGeneration: true)
        let generation = try XCTUnwrap(f.control.datasetGenerationID)
        var accountChecks = 0
        var reads = 0
        try await f.runtime.refreshCloudDataset(binding: f.binding, expectedGenerationID: generation,
            verifyAccount: { accountChecks += 1; return f.binding },
            readControl: { reads += 1; return f.control }, validateAccess: {})
        XCTAssertEqual(accountChecks, 1)
        XCTAssertEqual(reads, 2)
        let journal = try XCTUnwrap(f.store.load())
        XCTAssertEqual(journal.phase, .requested)
        XCTAssertEqual(journal.choice, .enableCloudKeepingCloud)
        XCTAssertEqual(journal.source, .cloud(binding: f.binding))
        XCTAssertEqual(journal.cloudBinding.accountFingerprint, f.binding.accountFingerprint)
        XCTAssertNotEqual(journal.destination.storageNamespace, f.binding.namespace)
        let checkpoint = try StorageTransferStateFile<StorageTransferRuntimeCheckpoint>(url:
            f.root.appendingPathComponent(journal.transactionID.uuidString.lowercased()).appendingPathComponent("runtime-v1.json"))
        XCTAssertEqual(try checkpoint.load()?.baselineControl, f.control)
        XCTAssertNil(try f.intent.pendingIntent())
    }

    func testInjectedBoundaryCannotAuthorizeDifferentAccountOrLocalBinding() async throws {
        let f = try fixture(hasGeneration: true)
        let generation = try XCTUnwrap(f.control.datasetGenerationID)
        let otherBinding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: account))
        var reads = 0
        do {
            try await f.runtime.refreshCloudDataset(binding: f.binding, expectedGenerationID: generation,
                verifyAccount: { otherBinding }, readControl: { reads += 1; return f.control }, validateAccess: {})
            XCTFail("The independently verified binding must match exactly")
        } catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .identityMismatch) }
        XCTAssertEqual(reads, 0)
        let foreign = try StorageTransferRecoveryControl(manifest: StorageTransferRecoveryManifest(transactionID: UUID(),
            accountFingerprint: String(repeating: "b", count: 64), payload: Data("foreign synthetic payload".utf8))).cancelling()
        do {
            try await f.runtime.preflightCloudMount(binding: f.binding, readControl: { foreign }, validateAccess: {})
            XCTFail("Remote response for another account must fail")
        } catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .identityMismatch) }
        XCTAssertNil(try f.admission.load())
        XCTAssertNil(try f.store.load())
    }

    func testFinalAwaitRechecksCallerLeaseBeforeRefreshAcknowledgment() async throws {
        let f = try fixture(hasGeneration: true)
        let generation = try XCTUnwrap(f.control.datasetGenerationID)
        var reads = 0
        var valid = true
        do {
            try await f.runtime.refreshCloudDataset(binding: f.binding, expectedGenerationID: generation,
                verifyAccount: { f.binding }, readControl: {
                    reads += 1
                    if reads == 2 { valid = false }
                    return f.control
                }, validateAccess: { if !valid { throw CancellationError() } })
            XCTFail("An expired caller lease must not acknowledge a request")
        } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(reads, 2)
        XCTAssertNil(try f.store.load())
    }

    func testAbsentIntentResumeReturnsBeforeValidationOrCloudPath() async throws {
        let f = try fixture()
        // This is the production overload. A nil intent returns synchronously
        // before lease/resolver/remote construction; a validation call here
        // would prove that execution wrongly entered the nonempty branch.
        try await f.runtime.resumeRemoteCancellation(validateAccess: {
            XCTFail("No intent must return before the Apple Account path")
            throw CancellationError()
        })
        XCTAssertNil(try f.runtime.pendingRemoteCancellationIntent())
        XCTAssertNil(try f.store.load())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.root.path).isEmpty)
    }

    // MARK: - Device -> iCloud overwrite (overwriteCloudDataset)

    #if DEBUG
    /// Publishes ONLY the overwrite bit, so every other prohibition stays shut.
    private func overwriteFixture(hasGeneration: Bool = true) throws -> Fixture {
        let base = try fixture(hasGeneration: hasGeneration)
        return Fixture(root: base.root, binding: base.binding, control: base.control, store: base.store,
            intent: base.intent,
            runtime: StorageTransferRuntime(store: base.store, root: base.root,
                releasePolicy: .isolatedTestingPolicy(allowsDatasetOverwriteFromDevice: true)),
            admission: base.admission)
    }

    func testStableOverwriteCreatesADifferentNamespaceFromTheExactVerifiedGeneration() async throws {
        let f = try overwriteFixture()
        let generation = try XCTUnwrap(f.control.datasetGenerationID)
        var accountChecks = 0
        var reads = 0
        try await f.runtime.overwriteCloudDataset(binding: f.binding, expectedGenerationID: generation,
            verifyAccount: { accountChecks += 1; return f.binding },
            readControl: { reads += 1; return f.control }, validateAccess: {})
        XCTAssertEqual(accountChecks, 1)
        XCTAssertEqual(reads, 2, "The control must be read before and after the checkpoint, as a refresh does")
        let journal = try XCTUnwrap(f.store.load())
        XCTAssertEqual(journal.phase, .requested)
        XCTAssertEqual(journal.choice, .overwriteCloudFromDevice)
        XCTAssertTrue(journal.choice.replacesCloud, "A recovery copy must be staged before anything is deleted")
        XCTAssertEqual(journal.source, .cloud(binding: f.binding))
        XCTAssertNotEqual(journal.destination.storageNamespace, f.binding.namespace)
        XCTAssertEqual(journal.destination, .cloud(binding: journal.cloudBinding))
        XCTAssertEqual(journal.cloudBinding.accountFingerprint, f.binding.accountFingerprint)
        let checkpoint = try StorageTransferStateFile<StorageTransferRuntimeCheckpoint>(url:
            f.root.appendingPathComponent(journal.transactionID.uuidString.lowercased())
                .appendingPathComponent("runtime-v1.json"))
        XCTAssertEqual(try checkpoint.load()?.baselineControl, f.control)
        XCTAssertFalse(try XCTUnwrap(checkpoint.load()).recoveredFromServer)
        XCTAssertNil(try f.intent.pendingIntent())
    }

    func testOverwriteRefusesAStaleDisplayedGenerationWithoutWritingAnything() async throws {
        let f = try overwriteFixture()
        let before = try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted()
        var reads = 0
        do {
            try await f.runtime.overwriteCloudDataset(binding: f.binding, expectedGenerationID: UUID(),
                verifyAccount: { f.binding }, readControl: { reads += 1; return f.control }, validateAccess: {})
            XCTFail("Only the displayed committed generation may authorize an overwrite")
        } catch { XCTAssertEqual(error as? StorageTransferError, .staleTransaction) }
        XCTAssertEqual(reads, 1)
        XCTAssertNil(try f.store.load())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted(), before)
    }

    func testOverwriteRefusesWhileAnotherReplacementStillBlocksWriters() async throws {
        let f = try overwriteFixture()
        let manifest = try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account,
            payload: Data("synthetic blocking payload".utf8), previousDatasetGenerationID: UUID())
        let staging = try StorageTransferRecoveryControl(manifest: manifest)
        XCTAssertTrue(staging.blocksWriters)
        let generation = try XCTUnwrap(staging.datasetGenerationID)
        do {
            try await f.runtime.overwriteCloudDataset(binding: f.binding, expectedGenerationID: generation,
                verifyAccount: { f.binding }, readControl: { staging }, validateAccess: {})
            XCTFail("A fenced account must not accept a new overwrite")
        } catch { XCTAssertEqual(error as? StorageTransferError, .staleTransaction) }
        XCTAssertNil(try f.store.load())
    }

    func testOverwriteRefusesWithAPendingJournalBeforeResolvingTheAccount() async throws {
        let f = try overwriteFixture()
        let generation = try XCTUnwrap(f.control.datasetGenerationID)
        let next = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                           accountFingerprint: account))
        let pending = try StorageTransferJournal(choice: .enableCloudKeepingCloud,
            source: .cloud(binding: f.binding), destination: .cloud(binding: next), cloudBinding: next)
        try f.store.begin(pending)
        var reads = 0
        do {
            try await f.runtime.overwriteCloudDataset(binding: f.binding, expectedGenerationID: generation,
                verifyAccount: { XCTFail("A pending journal must refuse first"); return f.binding },
                readControl: { reads += 1; return f.control }, validateAccess: {})
            XCTFail("Two transfers must never overlap")
        } catch { XCTAssertEqual(error as? StorageTransferRuntimeError, .relaunchRequired) }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(try f.store.load(), pending)
    }

    func testExistingIntentBlocksOverwriteBeforeAccountOrCloudRead() async throws {
        let f = try overwriteFixture()
        try accept(f)
        let generation = try XCTUnwrap(f.control.datasetGenerationID)
        var accountChecks = 0
        var reads = 0
        await expectIntentBlock {
            try await f.runtime.overwriteCloudDataset(binding: f.binding, expectedGenerationID: generation,
                verifyAccount: { accountChecks += 1; return f.binding },
                readControl: { reads += 1; return f.control }, validateAccess: {})
        }
        XCTAssertEqual(accountChecks, 0)
        XCTAssertEqual(reads, 0)
        XCTAssertNil(try f.store.load())
    }

    func testOverwriteRefusesAnIndependentlyVerifiedDifferentBinding() async throws {
        let f = try overwriteFixture()
        let generation = try XCTUnwrap(f.control.datasetGenerationID)
        let other = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                            accountFingerprint: account))
        var reads = 0
        do {
            try await f.runtime.overwriteCloudDataset(binding: f.binding, expectedGenerationID: generation,
                verifyAccount: { other }, readControl: { reads += 1; return f.control }, validateAccess: {})
            XCTFail("The independently verified binding must match exactly")
        } catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .identityMismatch) }
        XCTAssertEqual(reads, 0)
        XCTAssertNil(try f.store.load())
    }

    func testOverwriteAcknowledgmentRequiresTheControlToBeUnchangedAfterTheCheckpoint() async throws {
        let f = try overwriteFixture()
        let generation = try XCTUnwrap(f.control.datasetGenerationID)
        let changed = try StorageTransferRecoveryControl(manifest: StorageTransferRecoveryManifest(
            transactionID: UUID(), accountFingerprint: account,
            payload: Data("synthetic later payload".utf8),
            previousDatasetGenerationID: generation)).cancelling()
        var reads = 0
        do {
            try await f.runtime.overwriteCloudDataset(binding: f.binding, expectedGenerationID: generation,
                verifyAccount: { f.binding }, readControl: {
                    reads += 1
                    return reads == 1 ? f.control : changed
                }, validateAccess: {})
            XCTFail("A control that moved under the request must not be acknowledged")
        } catch { XCTAssertEqual(error as? StorageTransferError, .staleTransaction) }
        XCTAssertEqual(reads, 2)
        XCTAssertNil(try f.store.load())
    }
    #endif

    func testOnlyADisableWithCopyRequiresCloudEqualityOfTheFrozenSource() {
        // S11. An overwrite deliberately destroys a divergent - usually newer -
        // remote dataset, so requiring equality would make it impossible.
        XCTAssertTrue(StorageTransferChoice.disableCloudKeepingCopy.requiresCloudEqualityOfFrozenSource)
        XCTAssertFalse(StorageTransferChoice.overwriteCloudFromDevice.requiresCloudEqualityOfFrozenSource)
        XCTAssertFalse(StorageTransferChoice.enableCloudReplacingCloud.requiresCloudEqualityOfFrozenSource)
        XCTAssertFalse(StorageTransferChoice.enableCloudKeepingCloud.requiresCloudEqualityOfFrozenSource)
    }
}
