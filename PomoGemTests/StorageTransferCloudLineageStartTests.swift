import Foundation
import XCTest
@testable import PomoGem

/// L3 / P0-2. When the CloudKit database holds no transfer ledger at all, the
/// device is stranded: `refreshCloudDataset` and `overwriteCloudDataset` both
/// fence against a DISPLAYED committed generation, and the launch host only
/// offers the refresh screen when the control is terminal AND carries one. So
/// the one state the reported device is actually in had no exit.
///
/// There is nothing to fence against, because there is no server-side lineage
/// to protect: `stage()` already encodes exactly that rule by requiring
/// `previousDatasetGenerationID == nil` when the control record is absent.
/// `startCloudLineageFromDevice` is the same device -> iCloud overwrite with a
/// nil expected generation, behind the SAME closed policy bit.
@MainActor
final class StorageTransferCloudLineageStartTests: XCTestCase {
    private let account = String(repeating: "9", count: 64)

    private struct Fixture {
        let root: URL
        let binding: ActiveAccountLocalBinding
        let store: StorageTransferJournalStore
        let runtime: StorageTransferRuntime
    }

    /// `policy == nil` means the shipping `.standard` policy, i.e. every bit
    /// closed. Otherwise ONLY the overwrite bit is raised, so the test can
    /// prove the other prohibitions stay shut.
    private func fixture(published: Bool) throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("LineageStart-\(UUID())")
        let root = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                              accountFingerprint: account))
        let store = StorageTransferJournalStore(directory: root)
        let runtime: StorageTransferRuntime
        #if DEBUG
        runtime = StorageTransferRuntime(store: store, root: root,
            releasePolicy: published ? .isolatedTestingPolicy(allowsDatasetOverwriteFromDevice: true)
                                     : .standard)
        #else
        runtime = StorageTransferRuntime(store: store, root: root)
        #endif
        return Fixture(root: root, binding: binding, store: store, runtime: runtime)
    }

    private func manifest(previous: UUID?, payload: Data = Data("lineage start payload".utf8))
        throws -> StorageTransferRecoveryManifest {
        try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account,
            payload: payload, previousDatasetGenerationID: previous)
    }

    private func committed(previous: UUID?) throws -> StorageTransferRecoveryControl {
        let payload = Data("lineage start payload".utf8)
        return try StorageTransferRecoveryControl(manifest: manifest(previous: previous, payload: payload))
            .advancing(to: .backupVerified)
            .advancing(to: .replacing)
            .advancing(to: .committed,
                       verifiedDestinationSHA256: StorageTransferRecoverySchema.digest(payload))
    }

    private func checkpoint(_ f: Fixture, _ journal: StorageTransferJournal) throws
        -> StorageTransferRuntimeCheckpoint? {
        try StorageTransferStateFile<StorageTransferRuntimeCheckpoint>(url:
            f.root.appendingPathComponent(journal.transactionID.uuidString.lowercased())
                .appendingPathComponent("runtime-v1.json")).load()
    }

    // MARK: - The closed bit

    /// The shipping policy refuses before any remote read and before a single
    /// byte is written, exactly as the overwrite does.
    func testStartingALineageIsRefusedUnderTheStandardPolicy() async throws {
        let f = try fixture(published: false)
        let before = try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted()
        var reads = 0
        var accountChecks = 0
        do {
            try await f.runtime.startCloudLineageFromDevice(binding: f.binding,
                verifyAccount: { accountChecks += 1; return f.binding },
                readControl: { reads += 1; return nil }, validateAccess: {})
            XCTFail("A closed policy bit must refuse a new lineage")
        } catch {
            XCTAssertEqual(error as? StorageTransferReleaseError, .datasetOverwriteUnavailable)
        }
        XCTAssertEqual(reads, 0, "A closed bit must not cost a network round trip")
        XCTAssertEqual(accountChecks, 0)
        XCTAssertNil(try f.store.load())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted(), before)
    }

    // MARK: - The nil-lineage path

    #if DEBUG
    /// The rescue itself: an absent control record opens a transaction whose
    /// durable baseline is nil, which is what lets the staged manifest carry
    /// `previousDatasetGenerationID == nil`.
    func testAnAbsentControlOpensATransactionWithNoBaseline() async throws {
        let f = try fixture(published: true)
        var reads = 0
        try await f.runtime.startCloudLineageFromDevice(binding: f.binding,
            verifyAccount: { f.binding },
            readControl: { reads += 1; return nil }, validateAccess: {})
        XCTAssertEqual(reads, 2, "The control is read before and after the checkpoint")
        let journal = try XCTUnwrap(f.store.load())
        XCTAssertEqual(journal.choice, .overwriteCloudFromDevice)
        XCTAssertTrue(journal.choice.replacesCloud)
        XCTAssertEqual(journal.source, .cloud(binding: f.binding))
        XCTAssertNotEqual(journal.destination.storageNamespace, f.binding.namespace)
        let saved = try XCTUnwrap(checkpoint(f, journal))
        XCTAssertNil(saved.baselineControl, "An empty ledger is recorded as an empty ledger")
        XCTAssertTrue(saved.didObserveBaselineControl,
                      "...but it WAS observed; nil here is a fact, not a missing read")
        XCTAssertFalse(saved.recoveredFromServer)
        XCTAssertNoThrow(try saved.validate(journal: journal))
    }

    /// A terminal control with no predecessor is the same state: the ledger
    /// carries no committed generation, so it is also a nil lineage.
    func testACancelledControlWithoutAPredecessorIsAlsoANilLineage() async throws {
        let f = try fixture(published: true)
        let orphan = try StorageTransferRecoveryControl(manifest: manifest(previous: nil)).cancelling()
        XCTAssertTrue(orphan.isTerminal)
        XCTAssertNil(orphan.datasetGenerationID)
        try await f.runtime.startCloudLineageFromDevice(binding: f.binding,
            verifyAccount: { f.binding }, readControl: { orphan }, validateAccess: {})
        let journal = try XCTUnwrap(f.store.load())
        XCTAssertEqual(try checkpoint(f, journal)?.baselineControl, orphan)
    }

    /// The fence in the other direction: the moment a committed generation
    /// exists, this entry point refuses and the caller has to go through the
    /// ordinary generation-fenced CAS in `overwriteCloudDataset`.
    func testAnExistingLineageIsRefusedAndMustUseTheFencedOverwrite() async throws {
        let f = try fixture(published: true)
        let control = try committed(previous: nil)
        XCTAssertNotNil(control.datasetGenerationID)
        let before = try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted()
        do {
            try await f.runtime.startCloudLineageFromDevice(binding: f.binding,
                verifyAccount: { f.binding }, readControl: { control }, validateAccess: {})
            XCTFail("A server that already has a lineage must not be started over")
        } catch { XCTAssertEqual(error as? StorageTransferError, .staleTransaction) }
        XCTAssertNil(try f.store.load())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted(), before)

        // ...and the fenced overwrite accepts exactly that generation.
        try await f.runtime.overwriteCloudDataset(binding: f.binding,
            expectedGenerationID: try XCTUnwrap(control.datasetGenerationID),
            verifyAccount: { f.binding }, readControl: { control }, validateAccess: {})
        XCTAssertEqual(try f.store.load()?.choice, .overwriteCloudFromDevice)
    }

    /// A pending transfer still blocks, so "no committed generation" can never
    /// be confused with "a replacement is halfway through".
    func testAPendingTransferStillBlocksANewLineage() async throws {
        let f = try fixture(published: true)
        let staging = try StorageTransferRecoveryControl(manifest: manifest(previous: nil))
        XCTAssertTrue(staging.blocksWriters)
        XCTAssertNil(staging.datasetGenerationID)
        do {
            try await f.runtime.startCloudLineageFromDevice(binding: f.binding,
                verifyAccount: { f.binding }, readControl: { staging }, validateAccess: {})
            XCTFail("A staging control must not be adopted as an empty ledger")
        } catch { XCTAssertEqual(error as? StorageTransferError, .staleTransaction) }
        XCTAssertNil(try f.store.load())
    }

    /// The control must be unchanged across the checkpoint, as in every other
    /// entry point - including when "unchanged" means "still absent".
    func testAControlThatAppearsDuringTheRequestAbortsIt() async throws {
        let f = try fixture(published: true)
        let arriving = try committed(previous: nil)
        var reads = 0
        do {
            try await f.runtime.startCloudLineageFromDevice(binding: f.binding,
                verifyAccount: { f.binding },
                readControl: { reads += 1; return reads == 1 ? nil : arriving }, validateAccess: {})
            XCTFail("A lineage that appears mid-request must abort the transaction")
        } catch { XCTAssertEqual(error as? StorageTransferError, .staleTransaction) }
        XCTAssertEqual(reads, 2)
        XCTAssertNil(try f.store.load())
    }
    #endif

    // MARK: - The server-side rule this relies on

    /// `stage()` creates the control record only when the manifest claims no
    /// predecessor. This is the pre-existing rule that makes a nil-lineage
    /// overwrite legal at all, pinned here against the real implementation.
    func testStagingAgainstAnAbsentControlRequiresNoPredecessor() async throws {
        let payload = Data("lineage start payload".utf8)
        let backend = LineageStartBackendFake(accountFingerprint: account)
        let recovery = StorageTransferRemoteRecovery(backend: backend, validateAccess: {})

        let orphanClaim = try manifest(previous: UUID(), payload: payload)
        do {
            _ = try await recovery.stage(manifest: orphanClaim, payload: payload)
            XCTFail("A predecessor cannot be claimed against an absent control")
        } catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .staleControl) }
        XCTAssertNil(backend.control)

        let fresh = try manifest(previous: nil, payload: payload)
        let receipt = try await recovery.stage(manifest: fresh, payload: payload)
        XCTAssertNil(receipt.envelope.control.manifest.previousDatasetGenerationID)
        XCTAssertNil(receipt.envelope.control.datasetGenerationID,
                     "A staging control still reports no committed generation")
        XCTAssertEqual(receipt.envelope.control.phase, .backupVerified)
        XCTAssertEqual(backend.control?.control.manifest, fresh)
    }

    /// And the local checkpoint invariants accept the pair a nil lineage
    /// produces: a nil baseline with a manifest that claims no predecessor.
    func testACheckpointWithNoBaselineAcceptsAManifestWithNoPredecessor() throws {
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                              accountFingerprint: account))
        let destination = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                                  accountFingerprint: account))
        let payload = Data("lineage start payload".utf8)
        var journal = try StorageTransferJournal(choice: .overwriteCloudFromDevice,
            source: .cloud(binding: binding), destination: .cloud(binding: destination),
            cloudBinding: destination)
        journal = try journal.advancing(to: .sourceSaved,
            sourceDigest: StorageTransferRecoverySchema.digest(payload))
        var value = StorageTransferRuntimeCheckpoint(transactionID: journal.transactionID,
                                                     requestingProcessID: UUID())
        value.didObserveBaselineControl = true
        value.baselineControl = nil
        value.recoveryManifest = try StorageTransferRecoveryManifest(
            transactionID: journal.transactionID, accountFingerprint: account,
            payload: payload, previousDatasetGenerationID: nil)
        XCTAssertNoThrow(try value.validate(journal: journal))

        // ...and rejects a manifest that claims a predecessor the baseline
        // never observed, so a nil lineage cannot smuggle in a fake ancestor.
        value.recoveryManifest = try StorageTransferRecoveryManifest(
            transactionID: journal.transactionID, accountFingerprint: account,
            payload: payload, previousDatasetGenerationID: UUID())
        XCTAssertThrowsError(try value.validate(journal: journal))
    }
}

/// A minimal in-memory control/chunk store. Only the operations `stage` needs.
private final class LineageStartBackendFake: StorageTransferRecoveryBackend {
    let accountFingerprint: String
    var control: StorageTransferRecoveryEnvelope?
    private var chunks: [String: StorageTransferRecoveryChunk] = [:]
    private var receipts: [UUID: StorageTransferRecoveryControl] = [:]
    private var version = 0

    init(accountFingerprint: String) { self.accountFingerprint = accountFingerprint }

    func verifyAccount(_ fingerprint: String) async throws {
        guard fingerprint == accountFingerprint else { throw StorageTransferRecoveryError.identityMismatch }
    }
    func readControl() async throws -> StorageTransferRecoveryEnvelope? { control }
    func compareAndSwapControl(_ next: StorageTransferRecoveryControl,
                               replacing previous: StorageTransferRecoveryEnvelope?) async throws -> StorageTransferRecoveryEnvelope {
        guard control == previous else { throw StorageTransferRecoveryError.staleControl }
        try next.validate()
        version += 1
        let result = StorageTransferRecoveryEnvelope(control: next, changeTag: "v\(version)")
        control = result
        return result
    }
    func readChunk(manifest: StorageTransferRecoveryManifest, index: Int) async throws -> StorageTransferRecoveryChunk? {
        chunks["chunk-\(manifest.transactionID.uuidString.lowercased())-\(index)"]
    }
    func saveChunkIfAbsent(_ chunk: StorageTransferRecoveryChunk) async throws {
        if let prior = chunks[chunk.recordName] {
            guard prior == chunk else { throw StorageTransferRecoveryError.corruptChunk }
            return
        }
        chunks[chunk.recordName] = chunk
    }
    func retainTerminalReceipt(_ control: StorageTransferRecoveryControl) async throws {
        guard control.isTerminal else { throw StorageTransferRecoveryError.invalidControl }
        receipts[control.manifest.transactionID] = control
    }
    func readTerminalReceipt(transactionID: UUID) async throws -> StorageTransferRecoveryControl? {
        receipts[transactionID]
    }
    func deleteChunkIfMatches(_ chunk: StorageTransferRecoveryChunk,
                              terminalReceipt: StorageTransferRecoveryControl) async throws {
        chunks.removeValue(forKey: chunk.recordName)
    }
}
