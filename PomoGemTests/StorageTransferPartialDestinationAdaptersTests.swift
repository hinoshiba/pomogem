import CloudKit
import Darwin
import Foundation
import SwiftData
import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferPartialDestinationAdaptersTests: XCTestCase {
    private let account = String(repeating: "a", count: 64)

    private func binding() throws -> ActiveAccountLocalBinding {
        try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: account))
    }

    private func graph() throws -> PomoGemStorageSnapshot {
        let schema = PersistenceStoreTopology.shippingSchema
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(
            "PartialAdapterTests-\(UUID())", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = container.mainContext
        let subject = Subject(name: "synthetic", colorHex: "blue", sortOrder: 0)
        context.insert(subject)
        context.insert(StudySession(subject: subject, startAt: Date(timeIntervalSince1970: 1_700_000_000),
            endAt: Date(timeIntervalSince1970: 1_700_001_800), seconds: 1_800, source: .manual, deviceDayKey: "synthetic-day"))
        try context.save()
        return try PomoGemStorageSnapshot.capture(from: ModelContext(container))
    }

    private func snapshot(binding: ActiveAccountLocalBinding, graph: PomoGemStorageSnapshot,
                          token: Data = Data([1])) -> CloudStorageTransferSnapshot {
        CloudStorageTransferSnapshot(snapshot: graph, binding: binding, zones: [.init(
            zoneID: CKRecordZone.ID(zoneName: StorageTransferCloudSchema.managedZoneName,
                                    ownerName: CKRecordZone.default().zoneID.ownerName),
            terminalToken: token, recordCount: graph.records.count)])
    }

    private func plan() throws -> StorageTransferPartialDestinationPlan {
        let original = try graph()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifest = try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account,
                                                           payload: encoder.encode(original))
        let observed = try StorageTransferPartialStrictGraphAdapter.observation(snapshot(binding: binding(), graph: original))
        let proof = try StorageTransferPartialDestinationSubset.verify(observed, belongsTo: original)
        return try StorageTransferPartialDestinationPlan(attemptID: UUID(), manifest: manifest, observation: observed, proof: proof)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PartialAdapterTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func changed(_ plan: StorageTransferPartialDestinationPlan,
                         _ update: (inout [String: Any]) -> Void) throws -> StorageTransferPartialDestinationPlan {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        update(&object)
        return try JSONDecoder().decode(StorageTransferPartialDestinationPlan.self,
                                        from: JSONSerialization.data(withJSONObject: object))
    }

    func testPlanFileReopensEveryCheckpointAndRefusesStaleCAS() throws {
        let root = try directory()
        let original = try plan()
        let store = try StorageTransferPartialDestinationFileStore(transactionDirectory: root, transactionID: original.transactionID)
        try store.save(original, replacing: nil)
        let intent = try original.advancing(to: .deletionIntentRecorded)
        try store.save(intent, replacing: original)
        let reopened = try StorageTransferPartialDestinationFileStore(transactionDirectory: root, transactionID: original.transactionID)
        XCTAssertEqual(try reopened.load(), intent)
        XCTAssertThrowsError(try reopened.save(intent, replacing: original))
        let complete = try intent.advancing(to: .absenceVerified)
        try reopened.save(complete, replacing: intent)
        XCTAssertEqual(try store.load(), complete)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path),
                       [StorageTransferPartialDestinationFileStore.filename])
    }

    func testAttemptPayloadObservationAndTokenCannotChangeAcrossCAS() throws {
        let root = try directory()
        let original = try plan()
        let store = try StorageTransferPartialDestinationFileStore(transactionDirectory: root, transactionID: original.transactionID)
        try store.save(original, replacing: nil)
        let intent = try original.advancing(to: .deletionIntentRecorded)
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["attemptID"] = UUID().uuidString },
            { $0["sourcePayloadSHA256"] = String(repeating: "b", count: 64) },
            { $0["observedSHA256"] = String(repeating: "b", count: 64) },
            { $0["terminalToken"] = Data([2]).base64EncodedString() },
            { $0["observedRecordCount"] = 1 }
        ]
        for mutation in mutations { XCTAssertThrowsError(try store.save(changed(intent, mutation), replacing: original)) }
        XCTAssertThrowsError(try store.save(intent.advancing(to: .absenceVerified), replacing: original))
        XCTAssertEqual(try store.load(), original)
    }

    func testMalformedUnknownAndOversizedPlanCannotBeReplacedAsMissing() throws {
        let original = try plan()
        var unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        unknown["futureCleanupPermission"] = true
        for data in [Data("not-json".utf8), try JSONSerialization.data(withJSONObject: unknown),
                     Data(repeating: 0, count: StorageTransferPartialDestinationFileStore.maximumBytes + 1)] {
            let root = try directory()
            let file = root.appendingPathComponent(StorageTransferPartialDestinationFileStore.filename)
            try data.write(to: file)
            let store = try StorageTransferPartialDestinationFileStore(transactionDirectory: root, transactionID: original.transactionID)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(original, replacing: nil))
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func testLinksDirectoriesAndFIFOFailClosedWithoutFollowingOutsidePath() throws {
        let original = try plan()
        for kind in 0..<4 {
            let root = try directory()
            let file = root.appendingPathComponent(StorageTransferPartialDestinationFileStore.filename)
            let outside = try directory().appendingPathComponent("outside")
            let retained = Data("retained outside bytes".utf8)
            try retained.write(to: outside)
            switch kind {
            case 0: try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
            case 1: try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside.appendingPathExtension("missing"))
            case 2: try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            default: XCTAssertEqual(mkfifo(file.path, 0o600), 0)
            }
            let store = try StorageTransferPartialDestinationFileStore(transactionDirectory: root, transactionID: original.transactionID)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(original, replacing: nil))
            XCTAssertEqual(try Data(contentsOf: outside), retained)
        }
    }

    func testCopiedPlanCannotAdoptAnotherTransactionOrDirectorySymlink() throws {
        let root = try directory()
        let original = try plan()
        try JSONEncoder().encode(original).write(to: root.appendingPathComponent(StorageTransferPartialDestinationFileStore.filename))
        let other = try StorageTransferPartialDestinationFileStore(transactionDirectory: root, transactionID: UUID())
        XCTAssertThrowsError(try other.load())
        let link = try directory().appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try StorageTransferPartialDestinationFileStore(transactionDirectory: link, transactionID: original.transactionID))
    }

    func testStrictGraphConversionRetainsExactFieldsPhysicalEdgesAndRealToken() throws {
        let original = try graph()
        let expected = try binding()
        let token = Data([1, 2, 3])
        let observed = try StorageTransferPartialStrictGraphAdapter.observation(snapshot(binding: expected, graph: original, token: token))
        XCTAssertEqual(observed.terminalToken, token)
        XCTAssertEqual(observed.accountFingerprint, expected.accountFingerprint)
        XCTAssertEqual(observed.rows.count, original.records.count)
        XCTAssertEqual(try StorageTransferPartialDestinationSubset.verify(observed, belongsTo: original).matchedRecordCount, 2)
        let subject = try XCTUnwrap(observed.rows.first { $0.entity == "Subject" })
        let session = try XCTUnwrap(observed.rows.first { $0.entity == "StudySession" })
        XCTAssertEqual(session.subjectRecordName, subject.recordName)
        XCTAssertEqual(session.fields, original.records.first { $0.entity == "StudySession" }?.fields)
        let movedToken = try StorageTransferPartialStrictGraphAdapter.observation(snapshot(binding: expected, graph: original, token: Data([9])))
        XCTAssertNotEqual(try observed.digest(), try movedToken.digest())
    }

    func testInvalidGraphNeverFabricatesMissingParentAndAbsentZoneRequiresNoRows() throws {
        let expected = try binding()
        var original = try graph()
        original.records.removeAll { $0.entity == "Subject" }
        XCTAssertThrowsError(try StorageTransferPartialStrictGraphAdapter.observation(snapshot(binding: expected, graph: original)))
        let full = try graph()
        XCTAssertThrowsError(try StorageTransferPartialStrictGraphAdapter.observation(
            CloudStorageTransferSnapshot(snapshot: full, binding: expected, zones: [])))
        let empty = try StorageTransferPartialStrictGraphAdapter.observation(
            CloudStorageTransferSnapshot(snapshot: PomoGemStorageSnapshot(records: []), binding: expected, zones: []))
        XCTAssertTrue(empty.confirmsAbsence)
    }

    func testExistingStrictReaderDanglingFailureIsExplicitlyBlocked() async throws {
        let client = StorageTransferManagedZoneCloudClient(verifyAccount: { _ in },
            readSnapshot: { _ in throw CloudStorageTransferCloudError.missingRelationship },
            deleteZone: { _ in XCTFail("Must not delete"); throw StorageTransferPartialRecoveryError.invalidObservation })
        let adapter = StorageTransferPartialDestinationCloudKit(expectedBinding: try binding(), client: client, validateAccess: {})
        do { _ = try await adapter.readRawDestination(); XCTFail("Expected dangling block") }
        catch { XCTAssertEqual(error as? StorageTransferPartialRecoveryError, .danglingRelationship) }
    }

    func testConcurrentReadCannotOverwriteCaptureForFirstRead() async throws {
        let expected = try binding()
        let supplied = snapshot(binding: expected, graph: try graph())
        var continuation: CheckedContinuation<CloudStorageTransferSnapshot, Never>?
        let started = expectation(description: "first read started")
        let client = StorageTransferManagedZoneCloudClient(verifyAccount: { _ in }, readSnapshot: { _ in
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        }, deleteZone: { .deleted($0) })
        let adapter = StorageTransferPartialDestinationCloudKit(expectedBinding: expected, client: client, validateAccess: {})
        let first = Task { try await adapter.readRawDestination() }
        await fulfillment(of: [started], timeout: 1)
        do { _ = try await adapter.readRawDestination(); XCTFail("Expected concurrent read rejection") }
        catch { XCTAssertEqual(error as? StorageTransferPartialRecoveryError, .stalePlan) }
        continuation?.resume(returning: supplied)
        let actual = try await first.value
        XCTAssertEqual(actual.rows.count, supplied.snapshot.records.count)
    }

    func testTimedOutLateReadCannotPoisonSuccessfulRetryCapture() async throws {
        let expected = try binding()
        let original = try graph()
        let old = snapshot(binding: expected, graph: original, token: Data([1]))
        let fresh = snapshot(binding: expected, graph: original, token: Data([2]))
        var continuation: CheckedContinuation<CloudStorageTransferSnapshot, Never>?
        var calls = 0
        let client = StorageTransferManagedZoneCloudClient(verifyAccount: { _ in }, readSnapshot: { _ in
            calls += 1
            if calls == 1 { return await withCheckedContinuation { continuation = $0 } }
            return fresh
        }, deleteZone: { .deleted($0) })
        let adapter = StorageTransferPartialDestinationCloudKit(expectedBinding: expected, client: client,
                                                                timeout: 0.05, validateAccess: {})
        do { _ = try await adapter.readRawDestination(); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? StorageTransferManagedZoneAdapterError, .timedOut) }
        let retry = try await adapter.readRawDestination()
        XCTAssertEqual(retry.terminalToken, Data([2]))
        continuation?.resume(returning: old)
        await Task.yield()
        let again = try await adapter.readRawDestination()
        XCTAssertEqual(again.terminalToken, Data([2]))
    }

    func testAccountChangeInvalidatesReadAndFollowingDeleteWithoutRevival() async throws {
        let expected = try binding()
        let supplied = snapshot(binding: expected, graph: try graph())
        let center = NotificationCenter()
        var continuation: CheckedContinuation<CloudStorageTransferSnapshot, Never>?
        var deletes = 0
        let started = expectation(description: "read started")
        let client = StorageTransferManagedZoneCloudClient(verifyAccount: { _ in }, readSnapshot: { _ in
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        }, deleteZone: { deletes += 1; return .deleted($0) })
        let adapter = StorageTransferPartialDestinationCloudKit(expectedBinding: expected, client: client,
                                                                notificationCenter: center, validateAccess: {})
        let first = Task { try await adapter.readRawDestination() }
        await fulfillment(of: [started], timeout: 1)
        center.post(name: .CKAccountChanged, object: nil)
        do { _ = try await first.value; XCTFail("Expected account change") }
        catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .identityMismatch) }
        continuation?.resume(returning: supplied)
        let zone = try StorageTransferManagedZoneID(XCTUnwrap(supplied.zones.first?.zoneID))
        do { _ = try await adapter.deleteZone(zone); XCTFail("Expected retained invalidation") }
        catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .identityMismatch) }
        XCTAssertEqual(deletes, 0)
    }
}
