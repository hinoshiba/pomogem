import Foundation
import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferRemoteCancellationTests: XCTestCase {
    private let account = String(repeating: "a", count: 64)
    private let bytes = Data("synthetic remote cancellation payload".utf8)

    private struct Fixture {
        let root: URL
        let binding: ActiveAccountLocalBinding
        let manifest: StorageTransferRecoveryManifest
        let observed: StorageTransferRecoveryControl
        let journal: StorageTransferJournalStore
        let cleanup: StorageTransferCleanup
        let operation: StorageTransferRemoteCancellation
        let backend: RemoteCancellationBackend
        let recovery: StorageTransferRemoteRecovery
    }

    private func fixture(verified: Bool = false) throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteCancellation-\(UUID())")
        let root = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: account))
        let manifest = try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account, payload: bytes)
        var observed = try StorageTransferRecoveryControl(manifest: manifest)
        if verified { observed = try observed.advancing(to: .backupVerified) }
        let journal = StorageTransferJournalStore(directory: root)
        let cleanup = try StorageTransferCleanup(featureRoot: root, journalStore: journal, validateLocalCleanup: {})
        let operation = try StorageTransferRemoteCancellation(featureRoot: root, journalStore: journal, cleanup: cleanup)
        let backend = RemoteCancellationBackend(account: account)
        backend.control = StorageTransferRecoveryEnvelope(control: observed, changeTag: "original-server-revision")
        return Fixture(root: root, binding: binding, manifest: manifest, observed: observed, journal: journal,
            cleanup: cleanup, operation: operation, backend: backend,
            recovery: StorageTransferRemoteRecovery(backend: backend, validateAccess: {}))
    }

    @discardableResult
    private func accept(_ f: Fixture) throws -> StorageTransferRemoteCancellationIntent {
        try f.operation.accept(binding: f.binding, expectedTransactionID: f.manifest.transactionID,
            observedControl: f.observed, validateAccess: {})
    }

    private func freshOperation(_ f: Fixture) throws -> StorageTransferRemoteCancellation {
        try StorageTransferRemoteCancellation(featureRoot: f.root, journalStore: f.journal, cleanup: f.cleanup)
    }

    func testIntentPersistsBeforeCancellationCASAndContainsNoPayloadOrPaths() async throws {
        let f = try fixture()
        let intent = try accept(f)
        XCTAssertEqual(try freshOperation(f).pendingIntent(), intent)
        XCTAssertTrue(f.backend.savedPhases.isEmpty)
        let data = try Data(contentsOf: f.root.appendingPathComponent(StorageTransferRemoteCancellation.filename))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(String(decoding: bytes, as: UTF8.self)))
        XCTAssertFalse(text.contains(f.root.path))
        f.backend.beforeCAS = {
            XCTAssertEqual(try f.operation.pendingIntent(), intent)
            XCTAssertTrue(try f.cleanup.pendingReceipts().isEmpty)
        }
        try await f.operation.resume(expectedBinding: f.binding, recovery: f.recovery, validateAccess: {})
        XCTAssertNil(try f.operation.pendingIntent())
        XCTAssertEqual(f.backend.savedPhases, [.cancelled])
        XCTAssertEqual(try f.cleanup.pendingReceipts().first?.recoveryManifest, f.manifest)
        XCTAssertEqual(f.backend.chunkWrites, 0)
        XCTAssertEqual(f.backend.chunkDeletes, 0)
    }

    func testCrashAfterCancelledCASBeforeQueueResumesUsingArchivedReceiptAfterNewerTransaction() async throws {
        let f = try fixture()
        let intent = try accept(f)
        _ = try await f.recovery.cancelBeforeReplacement(manifest: f.manifest)
        let newer = try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account, payload: bytes)
        _ = try await f.recovery.stage(manifest: newer, payload: bytes, replacingTerminalTransactionID: f.manifest.transactionID)
        let current = f.backend.control
        let writes = f.backend.savedPhases
        XCTAssertEqual(try f.operation.pendingIntent(), intent)
        try await freshOperation(f).resume(expectedBinding: f.binding, recovery: f.recovery, validateAccess: {})
        XCTAssertNil(try f.operation.pendingIntent())
        XCTAssertEqual(f.backend.control, current)
        XCTAssertEqual(f.backend.savedPhases, writes)
        XCTAssertEqual(try f.cleanup.pendingReceipts().first?.recoveryManifest, f.manifest)
        XCTAssertNotNil(f.backend.chunks[try newer.chunk(0, from: bytes).recordName])
    }

    func testCrashAfterCleanupQueueBeforeIntentClearRetriesIdempotently() async throws {
        let f = try fixture()
        let intent = try accept(f)
        var interrupted = false
        do {
            try await f.operation.resume(expectedBinding: f.binding, recovery: f.recovery, validateAccess: {
                if !interrupted, !(try f.cleanup.pendingReceipts()).isEmpty {
                    interrupted = true
                    XCTAssertEqual(try f.operation.pendingIntent(), intent)
                    throw CancellationError()
                }
            })
            XCTFail("Expected interruption after queue persistence")
        } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(interrupted)
        XCTAssertEqual(try f.operation.pendingIntent(), intent)
        XCTAssertEqual(try f.cleanup.pendingReceipts().count, 1)
        try await freshOperation(f).resume(expectedBinding: f.binding, recovery: f.recovery, validateAccess: {})
        XCTAssertNil(try f.operation.pendingIntent())
        XCTAssertEqual(f.backend.savedPhases, [.cancelled])
        XCTAssertEqual(try f.cleanup.pendingReceipts().count, 1)
    }

    func testNewerControlMissingControlAndReplacementWithoutArchivedCancellationRemainBlocked() async throws {
        for scenario in 0..<3 {
            let f = try fixture(verified: true)
            let intent = try accept(f)
            if scenario == 0 { f.backend.control = nil }
            else {
                let changed = scenario == 1
                    ? try StorageTransferRecoveryControl(manifest: StorageTransferRecoveryManifest(
                        transactionID: UUID(), accountFingerprint: account, payload: bytes))
                    : try f.observed.advancing(to: .replacing)
                f.backend.control = StorageTransferRecoveryEnvelope(control: changed, changeTag: "changed-state")
            }
            let current = f.backend.control
            do {
                try await f.operation.resume(expectedBinding: f.binding, recovery: f.recovery, validateAccess: {})
                XCTFail("Changed remote authority must stay blocked")
            } catch { XCTAssertEqual(error as? StorageTransferRemoteCancellationError, .remoteStateChanged) }
            XCTAssertEqual(f.backend.control, current)
            XCTAssertTrue(f.backend.savedPhases.isEmpty)
            XCTAssertEqual(try f.operation.pendingIntent(), intent)
            XCTAssertTrue(try f.cleanup.pendingReceipts().isEmpty)
        }
    }

    func testVerifiedOriginalCannotAcceptARecreatedStagingControlOrEarlierCancellation() async throws {
        for cancelled in [false, true] {
            let f = try fixture(verified: true)
            _ = try accept(f)
            let initial = try StorageTransferRecoveryControl(manifest: f.manifest)
            let downgraded = cancelled ? try initial.cancelling() : initial
            f.backend.control = StorageTransferRecoveryEnvelope(control: downgraded, changeTag: "recreated")
            if cancelled { f.backend.receipts[f.manifest.transactionID] = downgraded }
            do {
                try await f.operation.resume(expectedBinding: f.binding, recovery: f.recovery, validateAccess: {})
                XCTFail("An earlier-generation phase is not the accepted cancellation")
            } catch { XCTAssertEqual(error as? StorageTransferRemoteCancellationError, .remoteStateChanged) }
            XCTAssertTrue(f.backend.savedPhases.isEmpty)
            XCTAssertNotNil(try f.operation.pendingIntent())
        }
    }

    func testPendingIntentCannotBeReplacedAndWrongBindingOrTransactionIsRejected() async throws {
        let f = try fixture()
        let intent = try accept(f)
        XCTAssertEqual(try accept(f), intent)
        let other = try StorageTransferRecoveryControl(manifest: StorageTransferRecoveryManifest(
            transactionID: UUID(), accountFingerprint: account, payload: bytes))
        XCTAssertThrowsError(try f.operation.accept(binding: f.binding, expectedTransactionID: other.manifest.transactionID,
            observedControl: other, validateAccess: {}))
        XCTAssertThrowsError(try f.operation.accept(binding: f.binding, expectedTransactionID: UUID(),
            observedControl: f.observed, validateAccess: {}))
        for fingerprint in [account, String(repeating: "b", count: 64)] {
            let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: fingerprint))
            do {
                try await f.operation.resume(expectedBinding: binding, recovery: f.recovery, validateAccess: {})
                XCTFail("A different binding cannot resume the accepted intent")
            } catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .identityMismatch) }
        }
        XCTAssertEqual(f.backend.reads, 0)
        XCTAssertEqual(try f.operation.pendingIntent(), intent)
    }

    func testLocalJournalBlocksAcceptanceAndAppearingJournalStopsRemoteEffectsAfterAwait() async throws {
        let f = try fixture()
        let journal = try StorageTransferJournal(choice: .enableCloudReplacingCloud,
            source: .localOnly(namespace: AccountDataNamespace()), destination: .cloud(binding: f.binding), cloudBinding: f.binding)
        try f.journal.begin(journal)
        XCTAssertThrowsError(try accept(f)) {
            XCTAssertEqual($0 as? StorageTransferRemoteCancellationError, .localTransferPending)
        }
        XCTAssertNil(try f.operation.pendingIntent())
        try f.journal.cancel(journal)
        let intent = try accept(f)
        f.backend.onReceiptRead = { try f.journal.begin(journal) }
        do {
            try await f.operation.resume(expectedBinding: f.binding, recovery: f.recovery, validateAccess: {})
            XCTFail("New local journal must stop cancellation immediately after the read")
        } catch { XCTAssertEqual(error as? StorageTransferRemoteCancellationError, .localTransferPending) }
        XCTAssertTrue(f.backend.savedPhases.isEmpty)
        XCTAssertEqual(try f.journal.load(), journal)
        XCTAssertEqual(try f.operation.pendingIntent(), intent)
    }

    func testUnknownOrSymlinkIntentIsNeverTreatedAsAbsentOrOverwritten() throws {
        for symlink in [false, true] {
            let f = try fixture()
            let intent = try accept(f)
            let url = f.root.appendingPathComponent(StorageTransferRemoteCancellation.filename)
            if symlink {
                try FileManager.default.removeItem(at: url)
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: f.root.appendingPathComponent("absent-target"))
            } else {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(intent)) as? [String: Any])
                object["unknownAuthority"] = true
                try JSONSerialization.data(withJSONObject: object).write(to: url)
            }
            XCTAssertThrowsError(try f.operation.pendingIntent())
            XCTAssertThrowsError(try accept(f))
            XCTAssertTrue(f.backend.savedPhases.isEmpty)
        }
    }

    func testQueueFailureRetainsIntentAndNeverRemovesUnexpectedLocalFiles() async throws {
        let f = try fixture()
        let intent = try accept(f)
        let unexpected = f.root.appendingPathComponent(f.manifest.transactionID.uuidString.lowercased())
        try FileManager.default.createDirectory(at: unexpected, withIntermediateDirectories: true)
        let file = unexpected.appendingPathComponent("payload-v1.json")
        try bytes.write(to: file)
        do {
            try await f.operation.resume(expectedBinding: f.binding, recovery: f.recovery, validateAccess: {})
            XCTFail("Remote-only cleanup cannot claim a local transaction directory")
        } catch { XCTAssertEqual(error as? StorageTransferCleanupError, .unsafePath) }
        XCTAssertEqual(try f.operation.pendingIntent(), intent)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(f.backend.control?.control.phase, .cancelled)
        XCTAssertTrue(try f.cleanup.pendingReceipts().isEmpty)
    }

    func testNoIntentIsReadOnlyAndPreReplacementPhaseIsRequiredAtAcceptance() async throws {
        let f = try fixture(verified: true)
        try await f.operation.resume(expectedBinding: f.binding, recovery: f.recovery, validateAccess: {})
        XCTAssertEqual(f.backend.reads, 0)
        let replacing = try f.observed.advancing(to: .replacing)
        let committed = try replacing.advancing(to: .committed, verifiedDestinationSHA256: f.manifest.payloadSHA256)
        for control in [replacing, committed] {
            XCTAssertThrowsError(try f.operation.accept(binding: f.binding, expectedTransactionID: f.manifest.transactionID,
                observedControl: control, validateAccess: {}))
        }
        XCTAssertNil(try f.operation.pendingIntent())
        XCTAssertTrue(f.backend.savedPhases.isEmpty)
    }

    func testRetentionCapacityIsCheckedBeforePersistingNewIntentOrCancellingControl() throws {
        let f = try fixture()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for _ in 0..<StorageTransferCleanup.maximumRetainedRemoteReceipts {
            let manifest = try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account, payload: bytes)
            let cancelled = try StorageTransferRecoveryControl(manifest: manifest).cancelling()
            let receipt = try StorageTransferCleanupReceipt(remoteCancellation: cancelled, binding: f.binding)
            try encoder.encode(receipt).write(to: f.root.appendingPathComponent("cleanup-\(manifest.transactionID.uuidString.lowercased()).json"))
        }
        XCTAssertThrowsError(try accept(f)) {
            XCTAssertEqual($0 as? StorageTransferCleanupError, .limitExceeded)
        }
        XCTAssertNil(try f.operation.pendingIntent())
        XCTAssertEqual(f.backend.control?.control, f.observed)
        XCTAssertTrue(f.backend.savedPhases.isEmpty)
        XCTAssertEqual(try f.cleanup.pendingReceipts().count, StorageTransferCleanup.maximumRetainedRemoteReceipts)
    }
}

@MainActor
private final class RemoteCancellationBackend: StorageTransferRecoveryBackend {
    let account: String
    var reads = 0
    var control: StorageTransferRecoveryEnvelope?
    var receipts: [UUID: StorageTransferRecoveryControl] = [:]
    var chunks: [String: StorageTransferRecoveryChunk] = [:]
    var savedPhases: [StorageTransferRecoveryControl.Phase] = []
    var chunkWrites = 0
    var chunkDeletes = 0
    var beforeCAS: (() throws -> Void)?
    var onReceiptRead: (() throws -> Void)?
    private var version = 0
    init(account: String) { self.account = account }
    func verifyAccount(_ fingerprint: String) async throws {
        guard fingerprint == account else { throw StorageTransferRecoveryError.identityMismatch }
    }
    func readControl() async throws -> StorageTransferRecoveryEnvelope? { reads += 1; return control }
    func compareAndSwapControl(_ value: StorageTransferRecoveryControl,
                               replacing previous: StorageTransferRecoveryEnvelope?) async throws -> StorageTransferRecoveryEnvelope {
        let hook = beforeCAS; beforeCAS = nil; try hook?()
        guard control == previous else { throw StorageTransferRecoveryError.staleControl }
        version += 1
        let next = StorageTransferRecoveryEnvelope(control: value, changeTag: "intent-server-revision-\(version)")
        control = next; savedPhases.append(value.phase)
        return next
    }
    func readChunk(manifest: StorageTransferRecoveryManifest, index: Int) async throws -> StorageTransferRecoveryChunk? {
        chunks["chunk-\(manifest.transactionID.uuidString.lowercased())-\(index)"]
    }
    func saveChunkIfAbsent(_ chunk: StorageTransferRecoveryChunk) async throws {
        if let previous = chunks[chunk.recordName], previous != chunk { throw StorageTransferRecoveryError.corruptChunk }
        chunkWrites += 1; chunks[chunk.recordName] = chunk
    }
    func retainTerminalReceipt(_ value: StorageTransferRecoveryControl) async throws {
        try value.validate()
        guard value.isTerminal else { throw StorageTransferRecoveryError.invalidControl }
        if let previous = receipts[value.manifest.transactionID], previous != value { throw StorageTransferRecoveryError.staleControl }
        receipts[value.manifest.transactionID] = value
    }
    func readTerminalReceipt(transactionID: UUID) async throws -> StorageTransferRecoveryControl? {
        reads += 1
        let hook = onReceiptRead; onReceiptRead = nil; try hook?()
        return receipts[transactionID]
    }
    func deleteChunkIfMatches(_ chunk: StorageTransferRecoveryChunk,
                              terminalReceipt: StorageTransferRecoveryControl) async throws {
        guard terminalReceipt.isTerminal, receipts[terminalReceipt.manifest.transactionID] == terminalReceipt,
              chunks[chunk.recordName] == chunk else { throw StorageTransferRecoveryError.staleControl }
        chunkDeletes += 1; chunks.removeValue(forKey: chunk.recordName)
    }
}
