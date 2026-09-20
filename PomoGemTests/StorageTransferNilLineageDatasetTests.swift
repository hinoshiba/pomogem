import Foundation
import XCTest
@testable import PomoGem

/// W6. Most healthy single-generation accounts have NO transfer control record
/// at all: they were never transferred, so nothing ever wrote one. Both
/// Settings doors used to refuse exactly those accounts, because
/// `remoteRecoveryStatus` returned nil and the durable request demanded a
/// committed generation to CAS against.
///
/// A nil lineage is now carried as nil and dispatched to the entry point that
/// REQUIRES its absence — `startCloudLineageFromDevice` in the device → iCloud
/// direction, `refreshCloudDatasetWithoutLineage` in the other. Neither trusts
/// the recorded nil: both re-read the control record and refuse the moment a
/// committed generation exists.
@MainActor
final class StorageTransferNilLineageDatasetTests: XCTestCase {
    private let account = String(repeating: "7", count: 64)

    private struct Fixture {
        let root: URL
        let binding: ActiveAccountLocalBinding
        let store: StorageTransferJournalStore
        let runtime: StorageTransferRuntime
    }

    private func fixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("NilLineage-\(UUID())")
        let root = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                              accountFingerprint: account))
        let store = StorageTransferJournalStore(directory: root)
        // The SHIPPING policy. This direction carries no release bit, for the
        // same reason the generation-fenced refresh carries none: it deletes
        // nothing on the server.
        return Fixture(root: root, binding: binding, store: store,
                       runtime: StorageTransferRuntime(store: store, root: root))
    }

    private func manifest(previous: UUID?, payload: Data = Data("nil lineage payload".utf8))
        throws -> StorageTransferRecoveryManifest {
        try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account,
            payload: payload, previousDatasetGenerationID: previous)
    }

    private func committed(previous: UUID?) throws -> StorageTransferRecoveryControl {
        let payload = Data("nil lineage payload".utf8)
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

    private func request(_ f: Fixture, direction: StorageTransferDatasetRequestDirection,
                         generation: UUID?) -> StorageTransferDatasetRequest {
        StorageTransferDatasetRequest(direction: direction, binding: f.binding,
                                      datasetGenerationID: generation,
                                      requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                      requestingProcessID: UUID())
    }

    // MARK: - request → relaunch → dispatch

    /// The durable record survives the relaunch with its nil intact, and the
    /// launch host's dispatch is a pure function of what it holds.
    func testANilLineageRequestSurvivesAndDispatchesToTheAbsenceEntryPoint() throws {
        let f = try fixture()
        for (direction, expected) in [
            (StorageTransferDatasetRequestDirection.overwriteCloudFromDevice,
             StorageTransferDatasetDispatch.startCloudLineageFromDevice),
            (.refreshFromCloud, .refreshCloudDatasetWithoutLineage)
        ] {
            let recorded = request(f, direction: direction, generation: nil)
            try f.runtime.recordDatasetRequest(recorded)
            let consumed = try XCTUnwrap(f.runtime.consumeDatasetRequest())
            XCTAssertEqual(consumed, recorded, "\(direction) must round trip with its nil intact")
            XCTAssertNil(consumed.datasetGenerationID)
            XCTAssertEqual(consumed.dispatch(for: f.binding), expected)
            XCTAssertNil(try f.runtime.consumeDatasetRequest(), "single shot")
        }
    }

    /// And a request that DOES carry a generation still dispatches to the
    /// generation-fenced entry point, unchanged.
    func testAGenerationCarryingRequestStillDispatchesToTheFencedEntryPoint() throws {
        let f = try fixture()
        let generation = UUID()
        XCTAssertEqual(request(f, direction: .overwriteCloudFromDevice, generation: generation)
            .dispatch(for: f.binding), .overwriteCloudDataset(expectedGenerationID: generation))
        XCTAssertEqual(request(f, direction: .refreshFromCloud, generation: generation)
            .dispatch(for: f.binding), .refreshCloudDataset(expectedGenerationID: generation))
    }

    /// A request written for another binding is dropped, never translated —
    /// including, and especially, a nil-lineage one.
    func testARequestForAnotherBindingDispatchesToNothing() throws {
        let f = try fixture()
        let other = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
            accountFingerprint: String(repeating: "8", count: 64)))
        for generation in [nil, UUID()] {
            for direction in [StorageTransferDatasetRequestDirection.overwriteCloudFromDevice,
                              .refreshFromCloud] {
                XCTAssertNil(request(f, direction: direction, generation: generation)
                    .dispatch(for: other))
            }
        }
    }

    // MARK: - Direction (A): device → iCloud with no lineage

    /// The Settings gate refuses to RECORD the closed direction at all, so a
    /// nil-lineage account cannot even queue a device → iCloud publication
    /// while `allowsDatasetOverwriteFromDevice` is false.
    func testTheClosedBitStillRefusesTheDeviceDirectionForANilLineageAccount() {
        XCTAssertThrowsError(try StorageTransferDatasetRequestPolicy.validate(
            .overwriteCloudFromDevice, policy: .standard)) { error in
            XCTAssertEqual(error as? StorageTransferReleaseError, .datasetOverwriteUnavailable)
        }
        // ...while the direction that destroys only the device side stays open
        // for exactly the same account.
        XCTAssertNoThrow(try StorageTransferDatasetRequestPolicy.validate(
            .refreshFromCloud, policy: .standard))
    }

    /// The entry point the nil dispatches to is the one with the policy gate
    /// as its first statement, so a closed bit costs no round trip.
    func testTheDeviceDirectionsNilEntryPointIsTheClosedOne() async throws {
        let f = try fixture()
        var reads = 0
        do {
            try await f.runtime.startCloudLineageFromDevice(binding: f.binding,
                verifyAccount: { f.binding },
                readControl: { reads += 1; return nil }, validateAccess: {})
            XCTFail("The shipping policy must refuse a new lineage")
        } catch {
            XCTAssertEqual(error as? StorageTransferReleaseError, .datasetOverwriteUnavailable)
        }
        XCTAssertEqual(reads, 0)
        XCTAssertNil(try f.store.load())
    }

    // MARK: - Direction (B): iCloud → device with no lineage

    /// The rescue for the ordinary healthy account: a fresh destination
    /// namespace, no store artifacts, mirrored down through the ordinary enrol
    /// path, and an explicitly observed EMPTY ledger as the durable baseline.
    func testAnAbsentControlOpensARefreshWithNoBaseline() async throws {
        let f = try fixture()
        var reads = 0
        try await f.runtime.refreshCloudDatasetWithoutLineage(binding: f.binding,
            verifyAccount: { f.binding },
            readControl: { reads += 1; return nil }, validateAccess: {})
        XCTAssertEqual(reads, 2, "The control is read before and after the checkpoint")
        let journal = try XCTUnwrap(f.store.load())
        // The SAME journal the generation-fenced refresh opens: no new shape,
        // no server write, and nothing staged on the server.
        XCTAssertEqual(journal.choice, .enableCloudKeepingCloud)
        XCTAssertFalse(journal.choice.replacesCloud)
        XCTAssertEqual(journal.source, .cloud(binding: f.binding))
        XCTAssertNotEqual(journal.destination.storageNamespace, f.binding.namespace,
                          "A fresh namespace is what satisfies requireNoArtifacts on the next launch")
        let saved = try XCTUnwrap(checkpoint(f, journal))
        XCTAssertNil(saved.baselineControl, "An empty ledger is recorded as an empty ledger")
        XCTAssertTrue(saved.didObserveBaselineControl,
                      "...but it WAS observed; nil here is a fact, not a missing read")
        XCTAssertNil(saved.recoveryManifest, "Nothing is staged on the server")
        XCTAssertFalse(saved.recoveredFromServer)
        XCTAssertNoThrow(try saved.validate(journal: journal))
    }

    /// The authority fence keeps holding for the whole transaction: a lineage
    /// published by another device mid-flight stops this one rather than being
    /// mirrored over.
    func testALineageAppearingMidTransactionStopsTheRefresh() async throws {
        let f = try fixture()
        try await f.runtime.refreshCloudDatasetWithoutLineage(binding: f.binding,
            verifyAccount: { f.binding }, readControl: { nil }, validateAccess: {})
        let journal = try XCTUnwrap(f.store.load())
        let saved = try XCTUnwrap(checkpoint(f, journal))
        XCTAssertThrowsError(try StorageTransferCloudAuthorityFence.validate(
            observed: try committed(previous: nil), journal: journal, checkpoint: saved)) { error in
            XCTAssertEqual(error as? StorageTransferRuntimeError, .remoteRecoveryRequired)
        }
        XCTAssertNoThrow(try StorageTransferCloudAuthorityFence.validate(
            observed: nil, journal: journal, checkpoint: saved),
            "and the absence it recorded is still acceptable")
    }

    /// The fence in the other direction: the moment a committed generation
    /// exists, this entry point refuses and the caller must use the ordinary
    /// generation-fenced refresh.
    func testAnExistingLineageIsRefusedAndMustUseTheFencedRefresh() async throws {
        let f = try fixture()
        let control = try committed(previous: nil)
        let before = try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted()
        do {
            try await f.runtime.refreshCloudDatasetWithoutLineage(binding: f.binding,
                verifyAccount: { f.binding }, readControl: { control }, validateAccess: {})
            XCTFail("An account that HAS a lineage must go through the CAS")
        } catch { XCTAssertEqual(error as? StorageTransferError, .staleTransaction) }
        XCTAssertNil(try f.store.load())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted(), before)

        try await f.runtime.refreshCloudDataset(binding: f.binding,
            expectedGenerationID: try XCTUnwrap(control.datasetGenerationID),
            verifyAccount: { f.binding }, readControl: { control }, validateAccess: {})
        XCTAssertEqual(try f.store.load()?.choice, .enableCloudKeepingCloud)
    }

    /// A transfer in flight still blocks, so "no committed generation" can
    /// never be confused with "a replacement is halfway through".
    func testAPendingTransferStillBlocksTheNilLineageRefresh() async throws {
        let f = try fixture()
        let staging = try StorageTransferRecoveryControl(manifest: manifest(previous: nil))
        XCTAssertTrue(staging.blocksWriters)
        XCTAssertNil(staging.datasetGenerationID)
        do {
            try await f.runtime.refreshCloudDatasetWithoutLineage(binding: f.binding,
                verifyAccount: { f.binding }, readControl: { staging }, validateAccess: {})
            XCTFail("A staging control must not be adopted as an empty ledger")
        } catch { XCTAssertEqual(error as? StorageTransferError, .staleTransaction) }
        XCTAssertNil(try f.store.load())
    }

    /// A control that appears between the two reads aborts the request, as in
    /// every other entry point — including when "unchanged" means "absent".
    func testAControlThatAppearsDuringTheRequestAbortsIt() async throws {
        let f = try fixture()
        let control = try committed(previous: nil)
        var reads = 0
        do {
            try await f.runtime.refreshCloudDatasetWithoutLineage(binding: f.binding,
                verifyAccount: { f.binding },
                readControl: { reads += 1; return reads == 1 ? nil : control },
                validateAccess: {})
            XCTFail("A ledger that appears mid-request must abort it")
        } catch { XCTAssertEqual(error as? StorageTransferError, .staleTransaction) }
        XCTAssertEqual(reads, 2)
        XCTAssertNil(try f.store.load(), "No journal is opened on an aborted request")
    }

    /// An identity that changes under the request is refused before anything
    /// is written, exactly as in the generation-fenced entry point.
    func testAChangedAccountIsRefusedBeforeAnythingIsWritten() async throws {
        let f = try fixture()
        let other = try XCTUnwrap(ActiveAccountLocalBinding(namespace: f.binding.namespace,
            accountFingerprint: String(repeating: "6", count: 64)))
        let before = try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted()
        do {
            try await f.runtime.refreshCloudDatasetWithoutLineage(binding: f.binding,
                verifyAccount: { other }, readControl: { nil }, validateAccess: {})
            XCTFail("A changed identity must refuse")
        } catch {
            XCTAssertEqual(error as? StorageTransferRecoveryError, .identityMismatch)
        }
        XCTAssertNil(try f.store.load())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted(), before)
    }

    // MARK: - Copy

    /// The comparison names what it actually saw: records, and no ledger. It
    /// must not print a 「最終」 row that implies a lineage the server lacks.
    func testTheNilLineageComparisonNamesTheAbsenceAndTheCount() {
        var counts = Dictionary(uniqueKeysWithValues:
            PomoGemStorageSnapshot.cloudModelNames.map { ($0, 0) })
        counts["Subject"] = 2
        counts["StudySession"] = 3
        let preview = StorageTransferCloudPreview(recordCounts: counts,
            latestRecordAt: Date(timeIntervalSinceReferenceDate: 0),
            otherDeviceIDs: 0, ignoredWriterIDs: 0)
        XCTAssertEqual(StorageTransferOverwriteCopy.cloudSideWithoutLineage(preview: preview),
                       "iCloud側の管理情報なし（記録件数: 5）")
        // A read that never happened is still reported as a read that never
        // happened, not as an absent ledger.
        XCTAssertEqual(StorageTransferOverwriteCopy.cloudSideWithoutLineage(preview: nil),
                       "iCloud: 確認できませんでした")
    }

    /// The error that remains is about a transfer IN FLIGHT, not about an
    /// account that simply never transferred.
    func testTheRemainingRefusalIsAboutAnInFlightTransfer() {
        let text = StorageTransferDatasetRequestError.transferInFlight.localizedDescription
        XCTAssertTrue(text.contains("未完了"))
        XCTAssertTrue(text.contains("削除していません"))
    }
}
