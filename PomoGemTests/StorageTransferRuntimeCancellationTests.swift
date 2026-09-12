import Foundation
import XCTest
@testable import PomoGem

/// Exercises the real runtime, immutable payload/checkpoint files, journal CAS
/// and durable cleanup queue with only the remote transport replaced. No model
/// container, Apple Account resolver or CloudKit service is opened by these tests.
@MainActor
final class StorageTransferRuntimeCancellationTests: XCTestCase {
    private let account = String(repeating: "a", count: 64)

    private struct Fixture {
        let root: URL
        let store: StorageTransferJournalStore
        let journal: StorageTransferJournal
        let files: StorageTransferStoreFiles
        let checkpoint: StorageTransferStateFile<StorageTransferRuntimeCheckpoint>
        let manifest: StorageTransferRecoveryManifest
        let payload: Data
        let runtime: StorageTransferRuntime
        let cleanup: StorageTransferCleanup
    }

    private func fixture(phase: StorageTransferJournal.Phase = .sourceSaved,
                         recovered: Bool = false) throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("RuntimeCancellation-\(UUID())")
        let root = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        let sourceRoot = parent.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: account))
        var journal = try StorageTransferJournal(choice: .enableCloudReplacingCloud,
            source: .localOnly(namespace: AccountDataNamespace()), destination: .cloud(binding: binding), cloudBinding: binding)
        let files = try StorageTransferStoreFiles(transactionID: journal.transactionID, transferRoot: root, storeDirectory: sourceRoot)
        // Preserve non-canonical but valid recovered bytes to catch accidental
        // reconstruction of a different manifest during cancellation.
        let bytes = Data("{ \"records\" : [], \"formatVersion\" : 1 }\n".utf8)
        let manifest = try StorageTransferRecoveryManifest(transactionID: journal.transactionID,
            accountFingerprint: account, payload: bytes)
        _ = try StorageTransferPayloadStore(files: files).saveRecovered(bytes, manifest: manifest)
        let store = StorageTransferJournalStore(directory: root)
        try store.begin(journal)
        for nextPhase in StorageTransferJournal.Phase.allCases.dropFirst() where nextPhase <= phase {
            if nextPhase == .selectionCommitted { try store.commitSelection(for: journal) }
            let next = try journal.advancing(to: nextPhase,
                sourceDigest: nextPhase == .sourceSaved ? manifest.payloadSHA256 : nil,
                destinationDigest: nextPhase == .destinationSaved ? manifest.payloadSHA256 : nil,
                remoteRecoveryTransactionID: nextPhase == .recoveryCopySaved ? journal.transactionID : nil)
            try store.save(next, replacing: journal)
            journal = next
        }
        var saved = StorageTransferRuntimeCheckpoint(transactionID: journal.transactionID, requestingProcessID: UUID())
        saved.didObserveBaselineControl = true
        saved.recoveredFromServer = recovered
        if recovered { saved.baselineControl = try StorageTransferRecoveryControl(manifest: manifest) }
        if phase >= .recoveryCopySaved { saved.recoveryManifest = manifest }
        if phase >= .preparingDestination {
            saved.importedPayloadDigest = manifest.payloadSHA256
            saved.cloudExportIntentRecorded = true
            saved.verifiedCloudProcessID = UUID()
            saved.verifiedCloudPayloadDigest = manifest.payloadSHA256
        }
        try saved.validate(journal: journal)
        let checkpoint = try StorageTransferStateFile<StorageTransferRuntimeCheckpoint>(
            url: files.transactionDirectory.appendingPathComponent("runtime-v1.json"))
        try checkpoint.save(saved, replacing: nil)
        return Fixture(root: root, store: store, journal: journal, files: files,
            checkpoint: checkpoint, manifest: manifest, payload: bytes,
            runtime: StorageTransferRuntime(store: store, root: root),
            cleanup: try StorageTransferCleanup(featureRoot: root, journalStore: store, validateLocalCleanup: {}))
    }

    private func recovery(_ backend: RuntimeCancellationBackend) -> StorageTransferRemoteRecovery {
        StorageTransferRemoteRecovery(backend: backend, validateAccess: {})
    }

    private func expectStale(_ action: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected stale transaction refusal", file: file, line: line) }
        catch { XCTAssertEqual(error as? StorageTransferError, .staleTransaction, file: file, line: line) }
    }

    func testUnacknowledgedNilStageCreatesExactCancelledFenceWithoutPayloadUpload() async throws {
        let f = try fixture()
        let backend = RuntimeCancellationBackend(account: account)
        var checkedBeforeCAS = false
        backend.beforeCAS = {
            checkedBeforeCAS = true
            XCTAssertEqual(try f.store.load(), f.journal)
            XCTAssertEqual(try f.checkpoint.load()?.recoveryManifest, f.manifest)
            XCTAssertTrue(try f.cleanup.pendingReceipts().isEmpty)
            XCTAssertEqual(try StorageTransferPayloadStore(files: f.files).bytes(expectedDigest: f.manifest.payloadSHA256), f.payload)
        }
        try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
            recovery: recovery(backend), validateAccess: {})
        XCTAssertTrue(checkedBeforeCAS)
        XCTAssertNil(try f.store.load())
        XCTAssertEqual(backend.savedPhases, [.cancelled])
        XCTAssertEqual(backend.control?.control.manifest, f.manifest)
        XCTAssertEqual(backend.chunkSaves, 0)
        XCTAssertEqual(backend.chunkDeletes, 0)
        let queued = try XCTUnwrap(f.cleanup.pendingReceipts().first)
        XCTAssertEqual(queued.recoveryManifest, f.manifest)
        XCTAssertFalse(queued.localRemoved)
        XCTAssertNil(queued.committedSelection)
        XCTAssertEqual(backend.receipts[f.journal.transactionID]?.phase, .cancelled)
        let delayedStage = try StorageTransferRecoveryControl(manifest: f.manifest)
        do {
            _ = try await backend.compareAndSwapControl(delayedStage, replacing: nil)
            XCTFail("Old nil-baseline staging must lose to the durable cancelled fence")
        } catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .staleControl) }
    }

    func testArchivedOldCancellationClearsLocalJournalWithoutTouchingNewerCommittedTransaction() async throws {
        let f = try fixture()
        let backend = RuntimeCancellationBackend(account: account)
        let remote = recovery(backend)
        _ = try await remote.cancelUnclaimed(manifest: f.manifest)
        let newerBytes = Data("newer synthetic payload".utf8)
        let newer = try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account, payload: newerBytes)
        _ = try await remote.stage(manifest: newer, payload: newerBytes, replacingTerminalTransactionID: f.journal.transactionID)
        _ = try await remote.authorizeReplacement(manifest: newer)
        _ = try await remote.commitReplacement(manifest: newer, verifiedDestinationSHA256: newer.payloadSHA256)
        let current = backend.control
        let saved = backend.savedPhases
        let chunks = backend.chunks
        let reads = backend.controlReads
        try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
            recovery: remote, validateAccess: {})
        XCTAssertNil(try f.store.load())
        XCTAssertEqual(backend.control, current)
        XCTAssertEqual(backend.savedPhases, saved)
        XCTAssertEqual(backend.chunks, chunks)
        XCTAssertEqual(backend.controlReads, reads)
        XCTAssertEqual(try f.cleanup.pendingReceipts().first?.recoveryManifest, f.manifest)
    }

    func testRecoveredRequestedPayloadIsAcknowledgedBeforeCancellationAndRetainsOriginalBytes() async throws {
        let f = try fixture(phase: .requested, recovered: true)
        let backend = RuntimeCancellationBackend(account: account)
        backend.control = StorageTransferRecoveryEnvelope(control: try StorageTransferRecoveryControl(manifest: f.manifest),
                                                          changeTag: "recovered-source-control")
        var observedAcknowledgment = false
        backend.onReceiptRead = {
            observedAcknowledgment = true
            XCTAssertEqual(try f.store.load()?.phase, .sourceSaved)
            XCTAssertEqual(try f.store.load()?.sourceDigest, f.manifest.payloadSHA256)
            XCTAssertEqual(try f.checkpoint.load()?.recoveryManifest, f.manifest)
        }
        try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
            recovery: recovery(backend), validateAccess: {})
        XCTAssertTrue(observedAcknowledgment)
        XCTAssertNil(try f.store.load())
        XCTAssertEqual(try Data(contentsOf: f.files.snapshotURL), f.payload)
        let queued = try XCTUnwrap(f.cleanup.pendingReceipts().first)
        guard case let .cancelled(journal, control) = queued.authorization else {
            return XCTFail("Expected a local cancellation authorization")
        }
        XCTAssertEqual(journal.phase, .sourceSaved)
        XCTAssertEqual(control?.manifest, f.manifest)
        XCTAssertEqual(backend.chunkSaves, 0)
    }

    func testDestructivePhasesAndWrongTransactionAreRefusedBeforeRemoteCalls() async throws {
        for phase in [StorageTransferJournal.Phase.preparingDestination, .destinationSaved, .sourceRetired] {
            let f = try fixture(phase: phase)
            let backend = RuntimeCancellationBackend(account: account)
            await expectStale {
                try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
                    recovery: self.recovery(backend), validateAccess: {})
            }
            XCTAssertEqual(try f.store.load(), f.journal)
            XCTAssertEqual(backend.accountChecks, 0)
            XCTAssertTrue(try f.cleanup.pendingReceipts().isEmpty)
        }
        let f = try fixture()
        let backend = RuntimeCancellationBackend(account: account)
        await expectStale {
            try await f.runtime.cancelPendingTransfer(expectedTransactionID: UUID(), recovery: self.recovery(backend), validateAccess: {})
        }
        XCTAssertEqual(backend.accountChecks, 0)
        XCTAssertEqual(try f.store.load(), f.journal)
    }

    func testJournalRevisionChangingDuringRemoteReadPreventsCancellationCAS() async throws {
        let f = try fixture()
        let backend = RuntimeCancellationBackend(account: account)
        let advanced = try f.journal.advancing(to: .recoveryCopySaved, remoteRecoveryTransactionID: f.journal.transactionID)
        backend.onReceiptRead = { try f.store.save(advanced, replacing: f.journal) }
        await expectStale {
            try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
                recovery: self.recovery(backend), validateAccess: {})
        }
        XCTAssertEqual(try f.store.load(), advanced)
        XCTAssertTrue(backend.savedPhases.isEmpty)
        XCTAssertNil(backend.control)
        XCTAssertTrue(try f.cleanup.pendingReceipts().isEmpty)
    }

    func testEntireJournalReplacedDuringRemoteReadNeverClearsOrCancelsNewTransaction() async throws {
        let f = try fixture()
        let backend = RuntimeCancellationBackend(account: account)
        let next = try StorageTransferJournal(choice: f.journal.choice, source: f.journal.source,
            destination: f.journal.destination, cloudBinding: f.journal.cloudBinding)
        backend.onReceiptRead = {
            try f.store.cancel(f.journal)
            try f.store.begin(next)
        }
        await expectStale {
            try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
                recovery: self.recovery(backend), validateAccess: {})
        }
        XCTAssertEqual(try f.store.load(), next)
        XCTAssertTrue(backend.savedPhases.isEmpty)
        XCTAssertTrue(try f.cleanup.pendingReceipts().isEmpty)
    }

    func testQueueIsDurableBeforeJournalClearAndInterruptedFinalClearCanRetry() async throws {
        let f = try fixture()
        let backend = RuntimeCancellationBackend(account: account)
        var interrupted = false
        do {
            try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
                recovery: recovery(backend), validateAccess: {
                    if !interrupted, !(try f.cleanup.pendingReceipts()).isEmpty {
                        interrupted = true
                        XCTAssertEqual(try f.store.load(), f.journal)
                        throw CancellationError()
                    }
                })
            XCTFail("Expected interruption after durable queue and before journal removal")
        } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(interrupted)
        XCTAssertEqual(try f.store.load(), f.journal)
        XCTAssertEqual(try f.cleanup.pendingReceipts().first?.recoveryManifest, f.manifest)
        let restart = StorageTransferRuntime(store: f.store, root: f.root)
        try await restart.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
            recovery: recovery(backend), validateAccess: {})
        XCTAssertNil(try f.store.load())
        XCTAssertEqual(backend.savedPhases, [.cancelled])
        XCTAssertEqual(try f.cleanup.pendingReceipts().count, 1)
    }

    func testQueueWriteFailureKeepsJournalAndPayloadAfterAcknowledgedRemoteCancellation() async throws {
        let f = try fixture()
        let backend = RuntimeCancellationBackend(account: account)
        let unknown = f.files.transactionDirectory.appendingPathComponent("unknown-user-file")
        let protected = Data("synthetic unknown file".utf8)
        try protected.write(to: unknown)
        do {
            try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
                recovery: recovery(backend), validateAccess: {})
            XCTFail("Unknown artifact must prevent cleanup authorization")
        } catch { XCTAssertEqual(error as? StorageTransferCleanupError, .unknownArtifact) }
        XCTAssertEqual(backend.control?.control.phase, .cancelled)
        XCTAssertEqual(try f.store.load(), f.journal)
        XCTAssertEqual(try Data(contentsOf: f.files.snapshotURL), f.payload)
        XCTAssertEqual(try Data(contentsOf: unknown), protected)
        XCTAssertTrue(try f.cleanup.pendingReceipts().isEmpty)
    }
}

@MainActor
private final class RuntimeCancellationBackend: StorageTransferRecoveryBackend {
    let account: String
    var accountChecks = 0
    var controlReads = 0
    var control: StorageTransferRecoveryEnvelope?
    var receipts: [UUID: StorageTransferRecoveryControl] = [:]
    var chunks: [String: StorageTransferRecoveryChunk] = [:]
    var savedPhases: [StorageTransferRecoveryControl.Phase] = []
    var chunkSaves = 0
    var chunkDeletes = 0
    var onReceiptRead: (() throws -> Void)?
    var beforeCAS: (() throws -> Void)?
    private var version = 0

    init(account: String) { self.account = account }
    func verifyAccount(_ fingerprint: String) async throws {
        accountChecks += 1
        guard fingerprint == account else { throw StorageTransferRecoveryError.identityMismatch }
    }
    func readControl() async throws -> StorageTransferRecoveryEnvelope? {
        controlReads += 1
        return control
    }
    func compareAndSwapControl(_ next: StorageTransferRecoveryControl,
                               replacing previous: StorageTransferRecoveryEnvelope?) async throws -> StorageTransferRecoveryEnvelope {
        let hook = beforeCAS; beforeCAS = nil; try hook?()
        guard control == previous else { throw StorageTransferRecoveryError.staleControl }
        try next.validate()
        version += 1
        let result = StorageTransferRecoveryEnvelope(control: next, changeTag: "synthetic-cancellation-\(version)")
        control = result
        savedPhases.append(next.phase)
        return result
    }
    func readChunk(manifest: StorageTransferRecoveryManifest, index: Int) async throws -> StorageTransferRecoveryChunk? {
        chunks["chunk-\(manifest.transactionID.uuidString.lowercased())-\(index)"]
    }
    func saveChunkIfAbsent(_ chunk: StorageTransferRecoveryChunk) async throws {
        if let previous = chunks[chunk.recordName], previous != chunk { throw StorageTransferRecoveryError.corruptChunk }
        chunkSaves += 1
        chunks[chunk.recordName] = chunk
    }
    func retainTerminalReceipt(_ value: StorageTransferRecoveryControl) async throws {
        try value.validate()
        guard value.isTerminal else { throw StorageTransferRecoveryError.invalidControl }
        if let previous = receipts[value.manifest.transactionID], previous != value { throw StorageTransferRecoveryError.staleControl }
        receipts[value.manifest.transactionID] = value
    }
    func readTerminalReceipt(transactionID: UUID) async throws -> StorageTransferRecoveryControl? {
        let hook = onReceiptRead; onReceiptRead = nil; try hook?()
        return receipts[transactionID]
    }
    func deleteChunkIfMatches(_ chunk: StorageTransferRecoveryChunk,
                              terminalReceipt: StorageTransferRecoveryControl) async throws {
        guard terminalReceipt.isTerminal, receipts[terminalReceipt.manifest.transactionID] == terminalReceipt,
              chunks[chunk.recordName] == chunk else { throw StorageTransferRecoveryError.staleControl }
        chunkDeletes += 1
        chunks.removeValue(forKey: chunk.recordName)
    }
}
