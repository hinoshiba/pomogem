import CloudKit
import Darwin
import Foundation
import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferManagedZoneDeletionAdaptersTests: XCTestCase {
    private let account = String(repeating: "a", count: 64)

    private func binding() throws -> ActiveAccountLocalBinding {
        try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: account))
    }

    private func zone() throws -> StorageTransferManagedZoneID {
        try StorageTransferManagedZoneID(CKRecordZone.ID(zoneName: StorageTransferCloudSchema.managedZoneName,
            ownerName: CKRecordZone.default().zoneID.ownerName))
    }

    private func snapshot(_ binding: ActiveAccountLocalBinding) -> CloudStorageTransferSnapshot {
        CloudStorageTransferSnapshot(snapshot: PomoGemStorageSnapshot(records: []), binding: binding, zones: [])
    }

    private func plan() throws -> StorageTransferManagedZoneDeletionPlan {
        let manifest = try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account,
                                                           payload: Data("synthetic snapshot".utf8))
        return try StorageTransferManagedZoneDeletionPlan(manifest: manifest,
            baseline: StorageTransferManagedZoneObservation(snapshot: snapshot(binding())))
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ManagedZoneAdapterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func encoded(_ value: StorageTransferManagedZoneDeletionPlan) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func testFileStoreReopensEachDurableCheckpointAndRejectsStaleCallbacks() throws {
        let root = try directory()
        let original = try plan()
        let store = try StorageTransferManagedZoneDeletionFileStore(transactionDirectory: root,
                                                                    transactionID: original.transactionID)
        XCTAssertNil(try store.load())
        try store.save(original, replacing: nil)
        XCTAssertThrowsError(try store.save(original, replacing: nil))
        let intent = try original.advancing(to: .deletionIntentRecorded)
        try store.save(intent, replacing: original)
        let reopened = try StorageTransferManagedZoneDeletionFileStore(transactionDirectory: root,
                                                                       transactionID: original.transactionID)
        XCTAssertEqual(try reopened.load(), intent)
        XCTAssertThrowsError(try reopened.save(intent, replacing: original))
        let completed = try intent.advancing(to: .absenceVerified)
        try reopened.save(completed, replacing: intent)
        XCTAssertEqual(try store.load(), completed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path),
                       [StorageTransferManagedZoneDeletionFileStore.filename])
    }

    func testFileStoreRefusesDifferentTransactionSkippedPhaseAndChangedBaseline() throws {
        let root = try directory()
        let original = try plan()
        let store = try StorageTransferManagedZoneDeletionFileStore(transactionDirectory: root,
                                                                    transactionID: original.transactionID)
        try store.save(original, replacing: nil)
        XCTAssertThrowsError(try store.save(plan(), replacing: original))
        let intent = try original.advancing(to: .deletionIntentRecorded)
        let completed = try intent.advancing(to: .absenceVerified)
        XCTAssertThrowsError(try store.save(completed, replacing: original))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(intent)) as? [String: Any])
        object["sourcePayloadSHA256"] = String(repeating: "b", count: 64)
        let changed = try JSONDecoder().decode(StorageTransferManagedZoneDeletionPlan.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try store.save(changed, replacing: original))
        XCTAssertEqual(try store.load(), original)
    }

    func testMalformedOversizedFutureAndUnknownPlanFieldsNeverLookAbsent() throws {
        let original = try plan()
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(original)) as? [String: Any])
        future["formatVersion"] = 2
        var unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(original)) as? [String: Any])
        unknown["unrecognizedDestructionAuthorization"] = true
        let inputs = [Data("not-json".utf8),
                      Data(repeating: 0, count: StorageTransferManagedZoneDeletionFileStore.maximumBytes + 1),
                      try JSONSerialization.data(withJSONObject: future),
                      try JSONSerialization.data(withJSONObject: unknown)]
        for input in inputs {
            let root = try directory()
            let file = root.appendingPathComponent(StorageTransferManagedZoneDeletionFileStore.filename)
            try input.write(to: file)
            let store = try StorageTransferManagedZoneDeletionFileStore(transactionDirectory: root,
                                                                        transactionID: original.transactionID)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(original, replacing: nil))
            XCTAssertEqual(try Data(contentsOf: file), input)
        }
    }

    func testPlanSymlinkDirectoryAndFIFONeverReadOrReplaceOutsideData() throws {
        let original = try plan()
        for kind in 0..<4 {
            let root = try directory()
            let outside = try directory().appendingPathComponent("outside")
            let contents = Data("outside bytes retained".utf8)
            try contents.write(to: outside)
            let file = root.appendingPathComponent(StorageTransferManagedZoneDeletionFileStore.filename)
            switch kind {
            case 0: try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
            case 1: try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside.appendingPathExtension("missing"))
            case 2: try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            default: XCTAssertEqual(mkfifo(file.path, 0o600), 0)
            }
            let store = try StorageTransferManagedZoneDeletionFileStore(transactionDirectory: root,
                                                                        transactionID: original.transactionID)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(original, replacing: nil))
            XCTAssertEqual(try Data(contentsOf: outside), contents)
        }
        let parent = try directory()
        let target = try directory()
        let link = parent.appendingPathComponent("transaction-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try StorageTransferManagedZoneDeletionFileStore(transactionDirectory: link,
                                                                             transactionID: original.transactionID))
    }

    func testPlanCopiedIntoDifferentTransactionCannotBeAdopted() throws {
        let root = try directory()
        let original = try plan()
        try encoded(original).write(to: root.appendingPathComponent(StorageTransferManagedZoneDeletionFileStore.filename))
        let other = try StorageTransferManagedZoneDeletionFileStore(transactionDirectory: root, transactionID: UUID())
        XCTAssertThrowsError(try other.load())
    }

    func testAcknowledgmentsRequireExactSinglePerZoneAndSuccessfulTerminalResult() throws {
        let id = try zone()
        let success = StorageTransferManagedZoneAcknowledgments(expected: id)
        success.receive(id: id.cloudKitID, result: .success(()))
        XCTAssertEqual(try success.complete(.success(())), .deleted(id))
        let missing = StorageTransferManagedZoneAcknowledgments(expected: id)
        XCTAssertThrowsError(try missing.complete(.success(())))
        XCTAssertThrowsError(try missing.complete(.failure(CKError(.zoneNotFound))))
        let duplicate = StorageTransferManagedZoneAcknowledgments(expected: id)
        duplicate.receive(id: id.cloudKitID, result: .success(()))
        duplicate.receive(id: id.cloudKitID, result: .success(()))
        XCTAssertThrowsError(try duplicate.complete(.success(())))
        let wrong = StorageTransferManagedZoneAcknowledgments(expected: id)
        wrong.receive(id: CKRecordZone.default().zoneID, result: .success(()))
        XCTAssertThrowsError(try wrong.complete(.success(())))
        let terminalFailure = StorageTransferManagedZoneAcknowledgments(expected: id)
        terminalFailure.receive(id: id.cloudKitID, result: .success(()))
        XCTAssertThrowsError(try terminalFailure.complete(.failure(CKError(.networkFailure))))
    }

    func testOnlyExactAuthoritativeZoneNotFoundCanAcknowledgeAbsence() throws {
        let id = try zone()
        let terminals: [Result<Void, Error>] = [.success(()), .failure(CKError(.zoneNotFound)),
            .failure(CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id.cloudKitID: CKError(.zoneNotFound)]]))]
        for terminal in terminals {
            let state = StorageTransferManagedZoneAcknowledgments(expected: id)
            state.receive(id: id.cloudKitID, result: .failure(CKError(.zoneNotFound)))
            XCTAssertEqual(try state.complete(terminal), .alreadyAbsent(id))
        }
        for code in [CKError.Code.unknownItem, .permissionFailure, .networkUnavailable] {
            let state = StorageTransferManagedZoneAcknowledgments(expected: id)
            state.receive(id: id.cloudKitID, result: .failure(CKError(code)))
            XCTAssertThrowsError(try state.complete(.failure(CKError(.zoneNotFound))))
        }
        let unrelated = StorageTransferManagedZoneAcknowledgments(expected: id)
        unrelated.receive(id: id.cloudKitID, result: .failure(CKError(.zoneNotFound)))
        let error = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey:
            [id.cloudKitID: CKError(.zoneNotFound), CKRecordZone.default().zoneID: CKError(.zoneNotFound)]])
        XCTAssertThrowsError(try unrelated.complete(.failure(error)))
    }

    func testAdapterVerifiesBindingBeforeAndAfterExactDelete() async throws {
        let expected = try binding()
        let id = try zone()
        var verified: [ActiveAccountLocalBinding] = []
        var deleted: [StorageTransferManagedZoneID] = []
        let client = StorageTransferManagedZoneCloudClient(verifyAccount: { verified.append($0) },
            readSnapshot: { self.snapshot($0) }, deleteZone: { deleted.append($0); return .deleted($0) })
        let adapter = StorageTransferManagedZoneDeletionCloudKit(expectedBinding: expected, client: client,
                                                                 validateAccess: {})
        let result = try await adapter.deleteZone(id)
        XCTAssertEqual(result, .deleted(id))
        XCTAssertEqual(deleted, [id])
        XCTAssertEqual(verified, [expected, expected])
        let observed = try await adapter.readSnapshot()
        XCTAssertTrue(observed.confirmsNoManagedZone)
    }

    func testAdapterRejectsWrongSnapshotBindingAndInvalidGenerationBeforeMutation() async throws {
        let expected = try binding()
        let other = try binding()
        let id = try zone()
        var calls = 0
        let client = StorageTransferManagedZoneCloudClient(verifyAccount: { _ in },
            readSnapshot: { _ in self.snapshot(other) }, deleteZone: { calls += 1; return .deleted($0) })
        let adapter = StorageTransferManagedZoneDeletionCloudKit(expectedBinding: expected, client: client,
                                                                 validateAccess: {})
        do {
            _ = try await adapter.readSnapshot()
            XCTFail("Expected exact local account binding mismatch")
        } catch { XCTAssertEqual(error as? StorageTransferManagedZoneDeletionError, .invalidRecoveryReceipt) }
        let invalid = StorageTransferManagedZoneDeletionCloudKit(expectedBinding: expected, client: client,
            validateAccess: { throw StorageTransferManagedZoneDeletionError.stalePlan })
        do {
            _ = try await invalid.deleteZone(id)
            XCTFail("Expected invalid generation")
        } catch { XCTAssertEqual(error as? StorageTransferManagedZoneDeletionError, .stalePlan) }
        XCTAssertEqual(calls, 0)
    }

    func testTimeoutDoesNotWaitForLateUncooperativeDeleteCallback() async throws {
        let id = try zone()
        var continuation: CheckedContinuation<StorageTransferManagedZoneDeleteAcknowledgment, Never>?
        let started = expectation(description: "held delete started")
        let client = StorageTransferManagedZoneCloudClient(verifyAccount: { _ in },
            readSnapshot: { self.snapshot($0) }, deleteZone: { _ in
                await withCheckedContinuation { continuation = $0; started.fulfill() }
            })
        let adapter = StorageTransferManagedZoneDeletionCloudKit(expectedBinding: try binding(), client: client,
                                                                 timeout: 0.05, validateAccess: {})
        let task = Task { try await adapter.deleteZone(id) }
        await fulfillment(of: [started], timeout: 1)
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await task.value
            XCTFail("Expected bounded timeout")
        } catch { XCTAssertEqual(error as? StorageTransferManagedZoneAdapterError, .timedOut) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        continuation?.resume(returning: .deleted(id))
    }

    func testCallerCancellationDoesNotAwaitCloudKitCancellationAcknowledgment() async throws {
        let id = try zone()
        var continuation: CheckedContinuation<StorageTransferManagedZoneDeleteAcknowledgment, Never>?
        let started = expectation(description: "delete started")
        let client = StorageTransferManagedZoneCloudClient(verifyAccount: { _ in },
            readSnapshot: { self.snapshot($0) }, deleteZone: { _ in
                await withCheckedContinuation { continuation = $0; started.fulfill() }
            })
        let adapter = StorageTransferManagedZoneDeletionCloudKit(expectedBinding: try binding(), client: client,
                                                                 validateAccess: {})
        let task = Task { try await adapter.deleteZone(id) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        continuation?.resume(returning: .deleted(id))
    }

    func testAccountChangeFailsHeldCallImmediatelyAndNeverRevivesAdapter() async throws {
        let id = try zone()
        let center = NotificationCenter()
        var continuation: CheckedContinuation<StorageTransferManagedZoneDeleteAcknowledgment, Never>?
        var calls = 0
        let started = expectation(description: "delete started")
        let client = StorageTransferManagedZoneCloudClient(verifyAccount: { _ in },
            readSnapshot: { self.snapshot($0) }, deleteZone: { _ in
                calls += 1
                return await withCheckedContinuation { continuation = $0; started.fulfill() }
            })
        let adapter = StorageTransferManagedZoneDeletionCloudKit(expectedBinding: try binding(), client: client,
                                                                 notificationCenter: center, validateAccess: {})
        let task = Task { try await adapter.deleteZone(id) }
        await fulfillment(of: [started], timeout: 1)
        center.post(name: .CKAccountChanged, object: nil)
        center.post(name: .CKAccountChanged, object: nil)
        do { _ = try await task.value; XCTFail("Expected account invalidation") }
        catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .identityMismatch) }
        continuation?.resume(returning: .deleted(id))
        do { _ = try await adapter.deleteZone(id); XCTFail("Expected permanent invalidation") }
        catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .identityMismatch) }
        XCTAssertEqual(calls, 1)
    }
}
