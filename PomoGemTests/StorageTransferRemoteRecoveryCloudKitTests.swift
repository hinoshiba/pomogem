import CloudKit
import Foundation
import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferRemoteRecoveryCloudKitTests: XCTestCase {
    private let fingerprint = String(repeating: "a", count: 64)
    private let payload = Data("entirely synthetic recovery payload".utf8)
    private func manifest() throws -> StorageTransferRecoveryManifest {
        try .init(transactionID: UUID(), accountFingerprint: fingerprint, payload: payload, chunkByteLimit: 16)
    }
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
    private func terminal(_ manifest: StorageTransferRecoveryManifest) throws -> StorageTransferRecoveryControl {
        try StorageTransferRecoveryControl(manifest: manifest).cancelling()
    }

    func testControlAndCancelledReceiptRoundTripRejectUnknownMetadata() throws {
        let control = try StorageTransferRecoveryControl(manifest: manifest())
        let name = StorageTransferRecoverySchema.controlRecordName
        let record = try StorageTransferRecoveryCloudCodec.control(control, name: name)
        XCTAssertEqual(try StorageTransferRecoveryCloudCodec.decodeControl(record, name: name, terminal: false), control)
        let cancelled = try control.cancelling()
        let receipt = try StorageTransferRecoveryCloudCodec.control(cancelled, name: cancelled.terminalReceiptRecordName)
        XCTAssertEqual(try StorageTransferRecoveryCloudCodec.decodeControl(receipt, name: cancelled.terminalReceiptRecordName, terminal: true), cancelled)
        record["futureMetadata"] = "unknown" as NSString
        XCTAssertThrowsError(try StorageTransferRecoveryCloudCodec.decodeControl(record, name: name, terminal: false))
        record["futureMetadata"] = nil
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(record["controlJSON"] as? Data)) as? [String: Any])
        object["futureControlRule"] = true
        let changed = try JSONSerialization.data(withJSONObject: object)
        record["controlJSON"] = changed as NSData
        record["controlSHA256"] = StorageTransferRecoverySchema.digest(changed) as NSString
        XCTAssertThrowsError(try StorageTransferRecoveryCloudCodec.decodeControl(record, name: name, terminal: false))
    }

    func testChunkCodecChecksIdentityBytesHashAndNonregularAssets() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let manifest = try manifest()
        let chunk = try manifest.chunk(0, from: payload)
        let file = folder.appendingPathComponent("chunk")
        try chunk.bytes.write(to: file)
        let record = try StorageTransferRecoveryCloudCodec.chunk(chunk, assetURL: file)
        XCTAssertEqual(try StorageTransferRecoveryCloudCodec.decodeChunk(record), chunk)
        record["byteCount"] = NSNumber(value: chunk.bytes.count + 1)
        XCTAssertThrowsError(try StorageTransferRecoveryCloudCodec.decodeChunk(record))
        record["byteCount"] = chunk.bytes.count as NSNumber
        record["chunkSHA256"] = String(repeating: "b", count: 64) as NSString
        XCTAssertThrowsError(try StorageTransferRecoveryCloudCodec.decodeChunk(record))
        record["chunkSHA256"] = StorageTransferRecoverySchema.digest(chunk.bytes) as NSString
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        record["asset"] = CKAsset(fileURL: link)
        XCTAssertThrowsError(try StorageTransferRecoveryCloudCodec.decodeChunk(record))
        record["asset"] = CKAsset(fileURL: folder)
        XCTAssertThrowsError(try StorageTransferRecoveryCloudCodec.decodeChunk(record))
    }

    func testNativeSavePolicyIsCASAndOnlyExactRecoveryZoneIsAllowed() throws {
        let control = try StorageTransferRecoveryControl(manifest: manifest())
        let record = try StorageTransferRecoveryCloudCodec.control(control, name: StorageTransferRecoverySchema.controlRecordName)
        let operation = try StorageTransferRecoveryCloudTransport.saveOperation(record, proof: nil)
        XCTAssertEqual(operation.savePolicy, .ifServerRecordUnchanged)
        XCTAssertTrue(operation.isAtomic)
        XCTAssertEqual(operation.recordsToSave?.map(\.recordID), [StorageTransferRecoveryCloudCodec.controlID])
        XCTAssertTrue(operation.recordIDsToDelete?.isEmpty ?? true)
        XCTAssertThrowsError(try StorageTransferRecoveryCloudTransport.saveOperation(record,
            proof: .init(changeTag: "invented-tag", systemFieldsProof: "invented-archive")))
        XCTAssertThrowsError(try StorageTransferRecoveryCloudCodec.systemFields(record), "An unsaved local record is not a server proof")
        for id in [CKRecord.ID(recordName: "control-v1"),
                   CKRecord.ID(recordName: "control-v1", zoneID: CKRecordZone.ID(zoneName: StorageTransferRecoverySchema.zoneName, ownerName: "other-owner")),
                   StorageTransferRecoveryCloudCodec.id("arbitrary-record")] {
            XCTAssertThrowsError(try StorageTransferRecoveryCloudTransport.requireID(id))
        }
    }

    func testMissingMeansExactAuthoritativeAbsenceNotTransportFailure() {
        let id = StorageTransferRecoveryCloudCodec.controlID
        XCTAssertTrue(StorageTransferRecoveryCloudTransport.isMissing(CKError(.unknownItem), id: id))
        XCTAssertTrue(StorageTransferRecoveryCloudTransport.isMissing(CKError(.zoneNotFound), id: id))
        for code in [CKError.Code.networkFailure, .permissionFailure, .notAuthenticated, .serverRejectedRequest] {
            XCTAssertFalse(StorageTransferRecoveryCloudTransport.isMissing(CKError(code), id: id))
        }
        let unrelated = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [StorageTransferRecoveryCloudCodec.id("other"): CKError(.unknownItem)]])
        XCTAssertFalse(StorageTransferRecoveryCloudTransport.isMissing(unrelated, id: id))
    }

    func testPerRecordAndTerminalAcknowledgmentsAreBothRequired() throws {
        let absent = RecoveryCloudSingleResult<Int>()
        XCTAssertThrowsError(try absent.complete(.success(())))
        let duplicate = RecoveryCloudSingleResult<Int>()
        duplicate.receive(matches: true, result: .success(1))
        duplicate.receive(matches: true, result: .success(1))
        XCTAssertThrowsError(try duplicate.complete(.success(())))
        let mismatched = RecoveryCloudSingleResult<Int>()
        mismatched.receive(matches: false, result: .success(1))
        XCTAssertThrowsError(try mismatched.complete(.success(())))
        let terminalFailure = RecoveryCloudSingleResult<Int>()
        terminalFailure.receive(matches: true, result: .success(1))
        XCTAssertThrowsError(try terminalFailure.complete(.failure(CKError(.networkFailure))))
        let success = RecoveryCloudSingleResult<Int>()
        success.receive(matches: true, result: .success(7))
        XCTAssertEqual(try success.complete(.success(())), 7)
    }

    func testBackendCarriesOpaqueServerProofAndRejectsStaleCAS() async throws {
        let fake = try RecoveryCloudTransportFake(account: fingerprint)
        defer { fake.removeFiles() }
        let backend = StorageTransferRemoteRecoveryCloudKit(client: fake.client, temporaryDirectory: fake.directory)
        try await backend.verifyAccount(fingerprint)
        let absent = try await backend.readControl()
        XCTAssertNil(absent)
        let control = try StorageTransferRecoveryControl(manifest: manifest())
        let first = try await backend.compareAndSwapControl(control, replacing: nil)
        let advanced = try control.advancing(to: .backupVerified)
        _ = try await backend.compareAndSwapControl(advanced, replacing: first)
        XCTAssertEqual(fake.saveProofs.last!, .init(changeTag: first.changeTag,
            systemFieldsProof: try XCTUnwrap(first.systemFieldsProof)))
        do { _ = try await backend.compareAndSwapControl(advanced, replacing: first); XCTFail("Expected stale CAS failure") }
        catch { XCTAssertEqual(error as? StorageTransferRecoveryCloudTransportError, .conflict) }
        let current = try await backend.readControl()
        XCTAssertEqual(current?.control, advanced)
        XCTAssertEqual(Set(fake.zoneRequests), [StorageTransferRecoveryCloudCodec.zoneID])
    }

    func testSameServerRevisionWithDifferentSaveAndFetchArchivesCompletesRecoveryRoundTrip() async throws {
        let fake = try RecoveryCloudTransportFake(account: fingerprint)
        defer { fake.removeFiles() }
        fake.varyFetchedSystemFieldsProof = true
        let backend = StorageTransferRemoteRecoveryCloudKit(client: fake.client, temporaryDirectory: fake.directory)
        let recovery = StorageTransferRemoteRecovery(backend: backend, validateAccess: {})
        let manifest = try manifest()
        let staged = try await recovery.stage(manifest: manifest, payload: payload)
        let observedValue = try await backend.readControl()
        let observed = try XCTUnwrap(observedValue)
        XCTAssertEqual(staged.envelope.changeTag, observed.changeTag)
        XCTAssertNotEqual(staged.envelope.systemFieldsProof, observed.systemFieldsProof)
        XCTAssertEqual(staged.envelope, observed, "Revision identity must not depend on archive representation")
        let recovered = try await recovery.recover(manifest: manifest)
        XCTAssertEqual(recovered.bytes, payload)
        _ = try await recovery.cancelBeforeReplacement(manifest: manifest)
        try await recovery.cleanupPayload(manifest: manifest)
        for chunk in manifest.chunks {
            let remaining = try await backend.readChunk(manifest: manifest, index: chunk.index)
            XCTAssertNil(remaining)
        }
        XCTAssertFalse(fake.saveProofs.compactMap { $0 }.isEmpty)
    }

    func testChangedActualServerRevisionWithUnchangedControlStillRejectsStaleReadback() async throws {
        let fake = try RecoveryCloudTransportFake(account: fingerprint)
        defer { fake.removeFiles() }
        fake.changeFetchedControlRevision = true
        let backend = StorageTransferRemoteRecoveryCloudKit(client: fake.client, temporaryDirectory: fake.directory)
        let recovery = StorageTransferRemoteRecovery(backend: backend, validateAccess: {})
        do {
            _ = try await recovery.stage(manifest: manifest(), payload: payload)
            XCTFail("A matching control payload does not authorize a different server revision")
        } catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .staleControl) }
        XCTAssertEqual(fake.saves, 1)
        XCTAssertTrue(fake.deletions.isEmpty)
    }

    func testLiveAdapterRefusesRevisionWithoutSeparateCASProofBeforeAnyWrite() async throws {
        let fake = try RecoveryCloudTransportFake(account: fingerprint)
        defer { fake.removeFiles() }
        let backend = StorageTransferRemoteRecoveryCloudKit(client: fake.client, temporaryDirectory: fake.directory)
        try await backend.verifyAccount(fingerprint)
        let control = try StorageTransferRecoveryControl(manifest: manifest())
        let previous = StorageTransferRecoveryEnvelope(control: control, changeTag: "actual-revision-without-archive")
        do {
            _ = try await backend.compareAndSwapControl(control.advancing(to: .backupVerified), replacing: previous)
            XCTFail("No archive is not authority to reconstruct a live CAS record")
        } catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .staleControl) }
        XCTAssertEqual(fake.saves, 0)
        XCTAssertTrue(fake.zoneRequests.isEmpty)
    }

    func testImmutableChunkSaveIsAcknowledgedReadBackAndIdempotent() async throws {
        let fake = try RecoveryCloudTransportFake(account: fingerprint)
        defer { fake.removeFiles() }
        let backend = StorageTransferRemoteRecoveryCloudKit(client: fake.client, temporaryDirectory: fake.directory)
        try await backend.verifyAccount(fingerprint)
        let manifest = try manifest()
        let chunk = try manifest.chunk(0, from: payload)
        try await backend.saveChunkIfAbsent(chunk)
        let savedCount = fake.saves
        try await backend.saveChunkIfAbsent(chunk)
        XCTAssertEqual(fake.saves, savedCount)
        let readback = try await backend.readChunk(manifest: manifest, index: 0)
        XCTAssertEqual(readback, chunk)
        XCTAssertGreaterThanOrEqual(fake.fetches, 4)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fake.directory.path)
        XCTAssertFalse(remaining.contains { $0.hasPrefix("pomogem-transfer-asset-") })
    }

    func testConflictingChunkNeverOverwritesAndLostAckRemainsFailureUntilRetry() async throws {
        let fake = try RecoveryCloudTransportFake(account: fingerprint)
        defer { fake.removeFiles() }
        let backend = StorageTransferRemoteRecoveryCloudKit(client: fake.client, temporaryDirectory: fake.directory)
        try await backend.verifyAccount(fingerprint)
        let manifest = try manifest()
        let chunk = try manifest.chunk(0, from: payload)
        fake.failAfterSaving = true
        do { try await backend.saveChunkIfAbsent(chunk); XCTFail("Uncertain response must not be upload success") }
        catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE_TRANSPORT_DETAIL")) }
        XCTAssertNotNil(fake.records[StorageTransferRecoveryCloudCodec.id(chunk.recordName)])
        fake.failAfterSaving = false
        try await backend.saveChunkIfAbsent(chunk)
        let conflicting = StorageTransferRecoveryChunk(transactionID: chunk.transactionID, accountFingerprint: fingerprint,
            payloadSHA256: chunk.payloadSHA256, index: chunk.index, bytes: Data([9, 9, 9]))
        let before = fake.saves
        do { try await backend.saveChunkIfAbsent(conflicting); XCTFail("Conflicting immutable chunk must be refused") }
        catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .corruptChunk) }
        XCTAssertEqual(fake.saves, before)
    }

    func testChunkCleanupRequiresExactImmutableTerminalReceiptAndNeverDeletesControl() async throws {
        let fake = try RecoveryCloudTransportFake(account: fingerprint)
        defer { fake.removeFiles() }
        let backend = StorageTransferRemoteRecoveryCloudKit(client: fake.client, temporaryDirectory: fake.directory)
        try await backend.verifyAccount(fingerprint)
        let manifest = try manifest()
        let chunk = try manifest.chunk(0, from: payload)
        try await backend.saveChunkIfAbsent(chunk)
        let cancelled = try terminal(manifest)
        do { try await backend.deleteChunkIfMatches(chunk, terminalReceipt: cancelled); XCTFail("No receipt, no deletion") }
        catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .invalidControl) }
        XCTAssertTrue(fake.deletions.isEmpty)
        try await backend.retainTerminalReceipt(cancelled)
        try await backend.retainTerminalReceipt(cancelled)
        try await backend.deleteChunkIfMatches(chunk, terminalReceipt: cancelled)
        XCTAssertEqual(fake.deletions, [StorageTransferRecoveryCloudCodec.id(chunk.recordName)])
        let absent = try await backend.readChunk(manifest: manifest, index: 0)
        let retained = try await backend.readTerminalReceipt(transactionID: manifest.transactionID)
        XCTAssertNil(absent)
        XCTAssertEqual(retained, cancelled)
    }

    func testTimeoutCancellationAndAccountChangeReleaseUnresponsiveFetch() async throws {
        for trigger in 0...2 {
            let fake = try RecoveryCloudTransportFake(account: fingerprint)
            defer { fake.removeFiles() }
            let center = NotificationCenter()
            let backend = StorageTransferRemoteRecoveryCloudKit(client: fake.client, timeout: trigger == 0 ? 0.02 : 1,
                notificationCenter: center, temporaryDirectory: fake.directory)
            try await backend.verifyAccount(fingerprint)
            fake.suspendFetch = true
            let task = Task { try await backend.readControl() }
            for _ in 0..<100 where fake.pendingFetch == nil { try await Task.sleep(for: .milliseconds(1)) }
            XCTAssertNotNil(fake.pendingFetch)
            if trigger == 1 { task.cancel() }
            if trigger == 2 { center.post(name: .CKAccountChanged, object: nil) }
            do { _ = try await task.value; XCTFail("Unresponsive operation must end without success") }
            catch {
                if trigger == 0 { XCTAssertEqual(error as? CloudStorageTransferCloudError, .timedOut) }
                if trigger == 1 { XCTAssertTrue(error is CancellationError) }
                if trigger == 2 { XCTAssertEqual(error as? StorageTransferRecoveryError, .identityMismatch) }
            }
            fake.pendingFetch?.resume(returning: nil); fake.pendingFetch = nil
            XCTAssertEqual(fake.saves, 0)
        }
    }

    func testAccountAndAccessGateMustRemainValidAcrossEverySuspension() async throws {
        let fake = try RecoveryCloudTransportFake(account: fingerprint)
        defer { fake.removeFiles() }
        var accessValid = true
        let backend = StorageTransferRemoteRecoveryCloudKit(client: fake.client, temporaryDirectory: fake.directory) {
            if !accessValid { throw StorageTransferRecoveryError.staleControl }
        }
        do { _ = try await backend.readControl(); XCTFail("Account was never verified") }
        catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .identityMismatch) }
        try await backend.verifyAccount(fingerprint)
        fake.afterFetch = { accessValid = false }
        do { _ = try await backend.readControl(); XCTFail("Late callback cannot bypass revoked access") }
        catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .staleControl) }
        XCTAssertEqual(fake.saves, 0)
    }

    func testVerifiedAppleAccountChangePreservesTypedMismatchThroughActualAdapterGate() async throws {
        let fake = try RecoveryCloudTransportFake(account: fingerprint)
        defer { fake.removeFiles() }
        var verifiedBinding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
            accountFingerprint: fingerprint))
        var client = fake.client
        client.verifyAccount = { expected in
            // Only the resolver response is injected; use the exact live
            // comparison and actual adapter suspension/error propagation.
            try StorageTransferRecoveryCloudClient.requireVerifiedAccount(verifiedBinding,
                expectedFingerprint: expected)
        }
        let backend = StorageTransferRemoteRecoveryCloudKit(client: client, temporaryDirectory: fake.directory)
        try await backend.verifyAccount(fingerprint)
        verifiedBinding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
            accountFingerprint: String(repeating: "b", count: 64)))
        do {
            _ = try await backend.readControl()
            XCTFail("A later verified Apple Account must not read the prior account's control")
        } catch {
            XCTAssertEqual(error as? AppleAccountBoundaryResolutionError, .blocked(.accountMismatch))
            XCTAssertEqual(CloudOfflineHostPolicy.revocationReason(for: error), .accountMismatch)
            XCTAssertFalse(CloudOfflineHostPolicy.allowsOfflineFallback(after: error))
        }
        XCTAssertEqual(fake.fetches, 0)
        XCTAssertEqual(fake.saves, 0)
        XCTAssertTrue(fake.deletions.isEmpty)
    }

    func testMalformedExpectedFingerprintDoesNotAssertARealAppleAccountChange() throws {
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
            accountFingerprint: fingerprint))
        for expected in ["", "invalid", String(repeating: "A", count: 64)] {
            XCTAssertThrowsError(try StorageTransferRecoveryCloudClient.requireVerifiedAccount(binding,
                expectedFingerprint: expected)) {
                XCTAssertEqual($0 as? StorageTransferRecoveryError, .identityMismatch)
                XCTAssertNil(CloudOfflineHostPolicy.revocationReason(for: $0))
                XCTAssertFalse(CloudOfflineHostPolicy.allowsOfflineFallback(after: $0))
            }
        }
    }

    func testDifferentControlAccountAndMalformedRecordIdentityDoNotRevokeVerifiedAppleAccount() async throws {
        let fake = try RecoveryCloudTransportFake(account: fingerprint)
        defer { fake.removeFiles() }
        let backend = StorageTransferRemoteRecoveryCloudKit(client: fake.client, temporaryDirectory: fake.directory)
        try await backend.verifyAccount(fingerprint)
        let foreignManifest = try StorageTransferRecoveryManifest(transactionID: UUID(),
            accountFingerprint: String(repeating: "b", count: 64), payload: payload)
        let foreignControl = try StorageTransferRecoveryControl(manifest: foreignManifest)
        let record = try StorageTransferRecoveryCloudCodec.control(foreignControl,
            name: StorageTransferRecoverySchema.controlRecordName)
        let malformed = CKRecord(recordType: record.recordType,
            recordID: StorageTransferRecoveryCloudCodec.id("unexpected-control-record"))
        for key in record.allKeys() { malformed[key] = record[key] }
        for (candidate, expected) in [(record, StorageTransferRecoveryError.identityMismatch),
                                      (malformed, StorageTransferRecoveryError.invalidControl)] {
            fake.records[StorageTransferRecoveryCloudCodec.controlID] = StorageTransferRecoveryCloudRecord(
                record: candidate, changeTag: "synthetic-read-revision", systemFieldsProof: "synthetic-read-proof")
            do {
                _ = try await backend.readControl()
                XCTFail("Inconsistent recovery metadata must fail closed")
            } catch {
                XCTAssertEqual(error as? StorageTransferRecoveryError, expected)
                XCTAssertNil(CloudOfflineHostPolicy.revocationReason(for: error))
                XCTAssertFalse(CloudOfflineHostPolicy.allowsOfflineFallback(after: error))
            }
        }
        XCTAssertEqual(fake.saves, 0)
        XCTAssertTrue(fake.deletions.isEmpty)
    }

    func testTemporaryCleanupTouchesOnlyOwnedExpiredChunkDirectories() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let assets = StorageTransferRecoveryAssetFiles(root: folder)
        let old = try assets.write(Data([1, 2]))
        let fresh = try assets.write(Data([3]))
        let unrelated = folder.appendingPathComponent("unrelated")
        try Data([4]).write(to: unrelated)
        let now = Date.now
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-172_800)], ofItemAtPath: old.deletingLastPathComponent().path)
        try assets.cleanStale(now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([4]))
        XCTAssertThrowsError(try assets.remove(unrelated))
    }
}

/// Entirely synthetic transport; the fake tag never passes through the live
/// system-fields decoder and therefore cannot be used as production CAS proof.
@MainActor
private final class RecoveryCloudTransportFake {
    let account: String
    let directory: URL
    var records: [CKRecord.ID: StorageTransferRecoveryCloudRecord] = [:]
    var saves = 0
    var fetches = 0
    var saveProofs: [StorageTransferRecoveryCloudCASProof?] = []
    var zoneRequests: [CKRecordZone.ID] = []
    var deletions: [CKRecord.ID] = []
    var failAfterSaving = false
    var suspendFetch = false
    var pendingFetch: CheckedContinuation<StorageTransferRecoveryCloudRecord?, Error>?
    var afterFetch: (() -> Void)?
    var varyFetchedSystemFieldsProof = false
    var changeFetchedControlRevision = false
    init(account: String) throws {
        self.account = account
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func removeFiles() { try? FileManager.default.removeItem(at: directory) }
    var client: StorageTransferRecoveryCloudClient {
        .init(verifyAccount: { [self] expected in
            guard expected == account else { throw StorageTransferRecoveryError.identityMismatch }
        }, fetch: { [self] id in
            fetches += 1
            if suspendFetch { return try await withCheckedThrowingContinuation { pendingFetch = $0 } }
            afterFetch?()
            guard let found = records[id] else { return nil }
            return StorageTransferRecoveryCloudRecord(record: found.record,
                changeTag: changeFetchedControlRevision && id == StorageTransferRecoveryCloudCodec.controlID
                    ? found.changeTag + "-new-server-revision" : found.changeTag,
                systemFieldsProof: varyFetchedSystemFieldsProof
                    ? "synthetic-fetch-archive-\(fetches)" : found.systemFieldsProof)
        }, save: { [self] record, proof in
            saveProofs.append(proof)
            if let prior = records[record.recordID] {
                guard proof?.changeTag == prior.changeTag else { throw CKError(.serverRecordChanged) }
            } else if proof != nil { throw CKError(.serverRecordChanged) }
            saves += 1
            let copy = CKRecord(recordType: record.recordType, recordID: record.recordID)
            for key in record.allKeys() { copy[key] = record[key] }
            if let asset = record["asset"] as? CKAsset, let source = asset.fileURL {
                let remoteFile = directory.appendingPathComponent("fake-server-\(UUID())")
                try Data(contentsOf: source).write(to: remoteFile)
                copy["asset"] = CKAsset(fileURL: remoteFile)
            }
            let saved = StorageTransferRecoveryCloudRecord(record: copy, changeTag: "fake-server-tag-\(saves)",
                systemFieldsProof: "synthetic-save-archive-\(saves)")
            records[copy.recordID] = saved
            if failAfterSaving { throw CKError(.networkFailure, userInfo: [NSLocalizedDescriptionKey: "PRIVATE_TRANSPORT_DETAIL"]) }
            return saved
        }, ensureZone: { [self] id in zoneRequests.append(id) }, delete: { [self] id in
            deletions.append(id); records[id] = nil
        })
    }
}
