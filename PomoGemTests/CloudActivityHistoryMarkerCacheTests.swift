import CloudKit
import XCTest
@testable import PomoGem

/// device-02 / launch-02 (PR 15). The reset-history read starts from a
/// per-binding change-token cache and falls back to a full traversal on any
/// doubt. A delta read must produce exactly what a full traversal would, and
/// nothing a doubtful read saw may be remembered.
@MainActor
final class CloudActivityHistoryMarkerCacheTests: XCTestCase {
    // MARK: Fixtures

    private let zoneA = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone", ownerName: CKCurrentUserDefaultName)
    private let zoneB = CKRecordZone.ID(zoneName: "PomoGemStorageTransfer-v1", ownerName: CKCurrentUserDefaultName)

    private func marker(_ sequence: Int, writer: String = "device-b") -> ActivityResetSnapshot {
        ActivityResetSnapshot(id: UUID(), epochID: UUID(), sequence: sequence,
                              resetAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence)),
                              writerDeviceID: writer)
    }

    private func record(_ marker: ActivityResetSnapshot, name: String, zone: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: "CD_ActivityResetMarker", recordID: CKRecord.ID(recordName: name, zoneID: zone))
        record["CD_entityName"] = "ActivityResetMarker" as CKRecordValue
        record["CD_id"] = marker.id.uuidString as CKRecordValue
        record["CD_epochID"] = marker.epochID.uuidString as CKRecordValue
        record["CD_sequence"] = NSNumber(value: marker.sequence)
        record["CD_resetAt"] = marker.resetAt as CKRecordValue
        record["CD_writerDeviceID"] = marker.writerDeviceID as CKRecordValue
        return record
    }

    private func session(name: String, zone: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: "CD_StudySession", recordID: CKRecord.ID(recordName: name, zoneID: zone))
        record["CD_entityName"] = "StudySession" as CKRecordValue
        return record
    }

    private func makeKey(namespace: AccountDataNamespace = AccountDataNamespace(),
                     environment: StorageTransferCloudEnvironment = .production,
                     generation: UUID? = nil) -> CloudActivityHistoryMarkerCache.Key {
        CloudActivityHistoryMarkerCache.Key(
            binding: ActiveAccountLocalBinding(namespace: namespace, accountFingerprint: String(repeating: "a", count: 64))!,
            scope: StorageTransferCloudScope(environment: environment,
                                             containerIdentifier: CloudSyncConfiguration.synchronizedDataContainerIdentifier),
            datasetGenerationID: generation)!
    }

    /// One scripted zone-changes answer: the events it delivers and the
    /// token it ends with, or the error it fails with.
    private enum Answer {
        case changes(changed: [CKRecord], deleted: [CKRecord.ID], pages: [Bool], token: String?)
        case failure(Error)
    }

    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        var zones: [CloudActivityHistoryZone] = []
        /// Keyed by zone name and the token the request carried ("nil" for none).
        var answers: [String: Answer] = [:]
        private(set) var requests: [String] = []

        func request(_ zone: CloudActivityHistoryZone, token: Data?) -> Answer? {
            let tokenName = token.map { String(decoding: $0, as: UTF8.self) } ?? "nil"
            let key = "\(zone.zoneID.zoneName)@\(tokenName)"
            return lock.withLock {
                requests.append(key)
                return answers[key]
            }
        }

        var source: CloudActivityHistoryZoneSource {
            CloudActivityHistoryZoneSource(listZones: { self.lock.withLock { self.zones } },
                fetchChanges: { zone, token, seed in
                    guard let answer = self.request(zone, token: token) else {
                        throw CloudActivityHistoryPreflightError.incompleteHistory
                    }
                    switch answer {
                    case let .failure(error):
                        throw CloudActivityHistoryReader.requiresFullTraversal(after: error)
                            ? CloudActivityHistoryReadRefused.server(error)
                            : CloudActivityHistoryPreflightError.sanitized(error)
                    case let .changes(changed, deleted, pages, token):
                        var accumulator = CloudActivityHistoryAccumulator(seed: seed)
                        changed.forEach { accumulator.record($0.recordID, result: .success($0)) }
                        deleted.forEach { accumulator.deleted($0) }
                        pages.forEach { accumulator.page(.success($0)) }
                        return CloudActivityHistoryZoneRead(markers: try accumulator.markerMap(operation: .success(())),
                                                            changeToken: token.map { Data($0.utf8) },
                                                            holdsUserRecords: accumulator.sawUserRecord)
                    }
                })
        }
    }

    private func zones(_ ids: CKRecordZone.ID...) -> [CloudActivityHistoryZone] {
        [CloudActivityHistoryZone(zoneID: CKRecordZone.default().zoneID, supportsFetchChanges: false)]
            + ids.map { CloudActivityHistoryZone(zoneID: $0, supportsFetchChanges: true) }
    }

    private func sorted(_ markers: [ActivityResetSnapshot]) -> [Int] {
        markers.map(\.sequence).sorted()
    }

    // MARK: Full traversal and first cache

    func testAFirstReadTraversesEveryZoneFromNilAndLeavesACache() async throws {
        let server = Server()
        let key = makeKey()
        let m1 = marker(1), m2 = marker(2)
        server.zones = zones(zoneA, zoneB)
        server.answers["\(zoneA.zoneName)@nil"] = .changes(
            changed: [record(m1, name: "m1", zone: zoneA), session(name: "s1", zone: zoneA), record(m2, name: "m2", zone: zoneA)],
            deleted: [], pages: [true, false], token: "A1")
        server.answers["\(zoneB.zoneName)@nil"] = .changes(changed: [], deleted: [], pages: [false], token: "B1")

        let read = try await CloudActivityHistoryReader.read(source: server.source, key: key, cached: nil)
        XCTAssertEqual(read.mode, .full)
        XCTAssertEqual(sorted(read.markers), [1, 2])
        XCTAssertEqual(server.requests, ["\(zoneA.zoneName)@nil", "\(zoneB.zoneName)@nil"],
                       "The default zone is skipped, every custom zone is read from the beginning")
        let cache = try XCTUnwrap(read.cache)
        XCTAssertEqual(cache.key, key)
        XCTAssertEqual(cache.zones.map(\.zoneName).sorted(), [zoneA.zoneName, zoneB.zoneName].sorted())
        XCTAssertEqual(cache.seed(for: zoneA).count, 2, "Only marker rows are remembered")
        XCTAssertTrue(cache.seed(for: zoneB).isEmpty)
    }

    // MARK: Delta reads

    private func cachedFirstRead(_ server: Server, key: CloudActivityHistoryMarkerCache.Key,
                                 m1: ActivityResetSnapshot, m2: ActivityResetSnapshot) async throws -> CloudActivityHistoryMarkerCache {
        server.zones = zones(zoneA, zoneB)
        server.answers["\(zoneA.zoneName)@nil"] = .changes(
            changed: [record(m1, name: "m1", zone: zoneA), record(m2, name: "m2", zone: zoneA)],
            deleted: [], pages: [false], token: "A1")
        server.answers["\(zoneB.zoneName)@nil"] = .changes(changed: [], deleted: [], pages: [false], token: "B1")
        let read = try await CloudActivityHistoryReader.read(source: server.source, key: key, cached: nil)
        return try XCTUnwrap(read.cache)
    }

    func testADeltaAppliesAddsUpdatesAndDeletesExactlyLikeAFullTraversal() async throws {
        let server = Server()
        let key = makeKey()
        let m1 = marker(1), m2 = marker(2)
        let cache = try await cachedFirstRead(server, key: key, m1: m1, m2: m2)

        let updated = marker(5), added = marker(7)
        server.answers["\(zoneA.zoneName)@A1"] = .changes(
            changed: [record(updated, name: "m2", zone: zoneA), record(added, name: "m3", zone: zoneA)],
            deleted: [CKRecord.ID(recordName: "m1", zoneID: zoneA)], pages: [false], token: "A2")
        server.answers["\(zoneB.zoneName)@B1"] = .changes(changed: [], deleted: [], pages: [false], token: "B2")

        let delta = try await CloudActivityHistoryReader.read(source: server.source, key: key, cached: cache)
        XCTAssertEqual(delta.mode, .delta)
        XCTAssertEqual(sorted(delta.markers), [5, 7])
        XCTAssertEqual(ActivityResetPolicy.currentMarker(from: delta.markers), added)

        // The same server state read from nil gives the same answer.
        server.answers["\(zoneA.zoneName)@nil"] = .changes(
            changed: [record(updated, name: "m2", zone: zoneA), record(added, name: "m3", zone: zoneA)],
            deleted: [], pages: [false], token: "A2")
        server.answers["\(zoneB.zoneName)@nil"] = .changes(changed: [], deleted: [], pages: [false], token: "B2")
        let full = try await CloudActivityHistoryReader.read(source: server.source, key: key, cached: nil)
        XCTAssertEqual(sorted(full.markers), sorted(delta.markers))
        XCTAssertEqual(full.cache, delta.cache, "Both paths leave the same cache behind")
    }

    /// launch-06 after the merge with #35. A steady-state delta only reports
    /// rows changed since the token, so the restore screen's evidence must
    /// come from the cache: a user who quit during the iCloud restore sees
    /// 「iCloudから記録を復元しています」 again on the next launch, not the
    /// new-user tutorial.
    func testADeltaReadAfterAFullReadStillReportsUserRecords() async throws {
        let server = Server()
        let key = makeKey()
        server.zones = zones(zoneA, zoneB)
        server.answers["\(zoneA.zoneName)@nil"] = .changes(
            changed: [record(marker(1), name: "m1", zone: zoneA), session(name: "s1", zone: zoneA)],
            deleted: [], pages: [false], token: "A1")
        server.answers["\(zoneB.zoneName)@nil"] = .changes(changed: [], deleted: [], pages: [false], token: "B1")
        let full = try await CloudActivityHistoryReader.read(source: server.source, key: key, cached: nil)
        XCTAssertTrue(full.holdsUserRecords)
        let cache = try XCTUnwrap(full.cache)
        XCTAssertEqual(cache.zones.first { $0.zoneID == zoneA }?.holdsUserRecords, true)
        XCTAssertEqual(cache.zones.first { $0.zoneID == zoneB }?.holdsUserRecords, false)

        // Nothing changed since the tokens: the delta passes no row at all.
        server.answers["\(zoneA.zoneName)@A1"] = .changes(changed: [], deleted: [], pages: [false], token: "A2")
        server.answers["\(zoneB.zoneName)@B1"] = .changes(changed: [], deleted: [], pages: [false], token: "B2")
        let delta = try await CloudActivityHistoryReader.read(source: server.source, key: key, cached: cache)
        XCTAssertEqual(delta.mode, .delta)
        XCTAssertTrue(delta.holdsUserRecords, "The cache remembers what the full traversal saw")
        let next = try XCTUnwrap(delta.cache)
        XCTAssertEqual(next.zones.first { $0.zoneID == zoneA }?.holdsUserRecords, true)

        // And again from the cache the delta left behind.
        server.answers["\(zoneA.zoneName)@A2"] = .changes(changed: [], deleted: [], pages: [false], token: "A3")
        server.answers["\(zoneB.zoneName)@B2"] = .changes(changed: [], deleted: [], pages: [false], token: "B3")
        let again = try await CloudActivityHistoryReader.read(source: server.source, key: key, cached: next)
        XCTAssertTrue(again.holdsUserRecords)

        // A full traversal recomputes it from nothing.
        server.answers["\(zoneA.zoneName)@nil"] = .changes(changed: [], deleted: [], pages: [false], token: "A4")
        server.answers["\(zoneB.zoneName)@nil"] = .changes(changed: [], deleted: [], pages: [false], token: "B4")
        let recomputed = try await CloudActivityHistoryReader.read(source: server.source, key: key, cached: nil)
        XCTAssertFalse(recomputed.holdsUserRecords)
    }

    func testADeltaThatPassesAUserRowAddsItToTheCache() async throws {
        let server = Server()
        let key = makeKey()
        let cache = try await cachedFirstRead(server, key: key, m1: marker(1), m2: marker(2))
        XCTAssertFalse(cache.zones.contains { $0.holdsUserRecords }, "Markers alone are not an earlier jar")
        server.answers["\(zoneA.zoneName)@A1"] = .changes(changed: [], deleted: [], pages: [false], token: "A2")
        server.answers["\(zoneB.zoneName)@B1"] = .changes(
            changed: [session(name: "s1", zone: zoneB)], deleted: [], pages: [false], token: "B2")
        let delta = try await CloudActivityHistoryReader.read(source: server.source, key: key, cached: cache)
        XCTAssertTrue(delta.holdsUserRecords)
        XCTAssertEqual(delta.cache?.zones.first { $0.zoneID == zoneB }?.holdsUserRecords, true)
        XCTAssertEqual(delta.cache?.zones.first { $0.zoneID == zoneA }?.holdsUserRecords, false)
    }

    func testTheLiveClientCarriesUserRecordsThroughThePreflight() async throws {
        let binding = ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                accountFingerprint: String(repeating: "a", count: 64))!
        for holds in [false, true] {
            let client = CloudActivityHistoryClient(verifyAccount: { _ in }, readHistory: { _ in
                CloudActivityHistoryMarkerRead(markers: [], holdsUserRecords: holds)
            })
            let observed = try await CloudActivityHistoryPreflight(client: client, timeout: 1)
                .run(expectedBinding: binding, validateMount: {}, localMarker: { nil })
            XCTAssertEqual(observed.holdsUserRecords, holds)
        }
    }

    func testARefusedTokenStartsOverFromNil() async throws {
        for refusal in [CKError(.changeTokenExpired), CKError(.zoneNotFound), CKError(.userDeletedZone),
                        CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [zoneA: CKError(.changeTokenExpired)]])] {
            let server = Server()
            let key = makeKey()
            let m1 = marker(1), m2 = marker(2)
            let cache = try await cachedFirstRead(server, key: key, m1: m1, m2: m2)
            server.answers["\(zoneA.zoneName)@A1"] = .failure(refusal)
            let m9 = marker(9)
            server.answers["\(zoneA.zoneName)@nil"] = .changes(
                changed: [record(m9, name: "m9", zone: zoneA)], deleted: [], pages: [false], token: "A9")
            server.answers["\(zoneB.zoneName)@nil"] = .changes(changed: [], deleted: [], pages: [false], token: "B9")

            let read = try await CloudActivityHistoryReader.read(source: server.source, key: key, cached: cache)
            XCTAssertEqual(read.mode, .fullAfterRefusedDelta, "\(refusal.code)")
            XCTAssertEqual(sorted(read.markers), [9], "Nothing from the refused delta or the old cache survives")
            XCTAssertEqual(read.cache?.seed(for: zoneA).count, 1)
        }
    }

    func testAnyOtherDeltaFailureFailsClosedAndNeverFallsBack() async throws {
        let failures: [(Answer, CloudActivityHistoryPreflightError?)] = [
            (.failure(CKError(.networkUnavailable)), nil),
            (.failure(CKError(.serviceUnavailable)), nil),
            (.changes(changed: [], deleted: [], pages: [true], token: "A2"), .incompleteHistory),
        ]
        for (answer, expected) in failures {
            let server = Server()
            let key = makeKey()
            let cache = try await cachedFirstRead(server, key: key, m1: marker(1), m2: marker(2))
            server.answers["\(zoneA.zoneName)@A1"] = answer
            let before = server.requests.count
            do {
                _ = try await CloudActivityHistoryReader.read(source: server.source, key: key, cached: cache)
                XCTFail("A failed delta must fail the read")
            } catch let error as CloudActivityHistoryPreflightError {
                if let expected { XCTAssertEqual(error, expected) }
                XCTAssertFalse(CloudActivityHistoryReader.requiresFullTraversal(after: error))
            }
            XCTAssertEqual(server.requests.count - before, 1, "No second, full traversal hides the failure")
        }
    }

    func testAMalformedMarkerInADeltaFailsClosed() async throws {
        let server = Server()
        let key = makeKey()
        let cache = try await cachedFirstRead(server, key: key, m1: marker(1), m2: marker(2))
        let malformed = record(marker(3), name: "m3", zone: zoneA)
        malformed["CD_writerDeviceID"] = nil
        server.answers["\(zoneA.zoneName)@A1"] = .changes(changed: [malformed], deleted: [], pages: [false], token: "A2")
        server.answers["\(zoneB.zoneName)@B1"] = .changes(changed: [], deleted: [], pages: [false], token: "B2")
        do {
            _ = try await CloudActivityHistoryReader.read(source: server.source, key: key, cached: cache)
            XCTFail("A malformed marker must never be skipped")
        } catch let error as CloudActivityHistoryPreflightError {
            XCTAssertEqual(error, .malformedHistory)
        }
    }

    func testTheMarkerLimitStillCountsTheCachedMarkers() async throws {
        var seed: [CKRecord.ID: ActivityResetSnapshot] = [:]
        for index in 0..<CloudActivityHistoryAccumulator.maximumMarkers {
            seed[CKRecord.ID(recordName: "seed-\(index)", zoneID: zoneA)] = marker(1)
        }
        var accumulator = CloudActivityHistoryAccumulator(seed: seed)
        let extra = record(marker(2), name: "one-too-many", zone: zoneA)
        accumulator.record(extra.recordID, result: .success(extra))
        accumulator.page(.success(false))
        XCTAssertThrowsError(try accumulator.markerMap(operation: .success(()))) {
            XCTAssertEqual($0 as? CloudActivityHistoryPreflightError, .historyLimit)
        }
    }

    // MARK: Every doubt reads everything

    func testAChangedZoneSetIgnoresTheCache() async throws {
        let server = Server()
        let key = makeKey()
        let cache = try await cachedFirstRead(server, key: key, m1: marker(1), m2: marker(2))
        let zoneC = CKRecordZone.ID(zoneName: "another-zone", ownerName: CKCurrentUserDefaultName)
        server.zones = zones(zoneA, zoneC)
        server.answers["\(zoneA.zoneName)@nil"] = .changes(changed: [], deleted: [], pages: [false], token: "A5")
        server.answers["\(zoneC.zoneName)@nil"] = .changes(changed: [], deleted: [], pages: [false], token: "C5")
        let read = try await CloudActivityHistoryReader.read(source: server.source, key: key, cached: cache)
        XCTAssertEqual(read.mode, .full)
        XCTAssertTrue(read.markers.isEmpty, "Cached markers of a zone set that no longer exists are not reused")
    }

    func testAnotherBindingEnvironmentOrGenerationIgnoresTheCache() async throws {
        let namespace = AccountDataNamespace()
        let original = makeKey(namespace: namespace)
        let server = Server()
        let cache = try await cachedFirstRead(server, key: original, m1: marker(1), m2: marker(2))
        let others = [makeKey(), makeKey(namespace: namespace, environment: .development),
                      makeKey(namespace: namespace, generation: UUID())]
        for other in others {
            XCTAssertNil(cache.validated(for: other))
            server.answers["\(zoneA.zoneName)@nil"] = .changes(changed: [], deleted: [], pages: [false], token: "A7")
            server.answers["\(zoneB.zoneName)@nil"] = .changes(changed: [], deleted: [], pages: [false], token: "B7")
            let read = try await CloudActivityHistoryReader.read(source: server.source, key: other, cached: cache)
            XCTAssertEqual(read.mode, .full)
            XCTAssertEqual(read.cache?.key, other)
        }
        XCTAssertNil(CloudActivityHistoryMarkerCache.Key(
            binding: ActiveAccountLocalBinding(namespace: namespace, accountFingerprint: String(repeating: "a", count: 64))!,
            scope: .unknown, datasetGenerationID: nil), "An unproven environment is never a cache key")
    }

    func testAReadWithoutAKeyOrWithoutEveryTokenLeavesNoCache() async throws {
        let server = Server()
        server.zones = zones(zoneA, zoneB)
        server.answers["\(zoneA.zoneName)@nil"] = .changes(changed: [], deleted: [], pages: [false], token: "A1")
        server.answers["\(zoneB.zoneName)@nil"] = .changes(changed: [], deleted: [], pages: [false], token: nil)
        let missingToken = try await CloudActivityHistoryReader.read(source: server.source, key: makeKey(), cached: nil)
        XCTAssertNil(missingToken.cache)
        server.answers["\(zoneB.zoneName)@nil"] = .changes(changed: [], deleted: [], pages: [false], token: "B1")
        let withoutKey = try await CloudActivityHistoryReader.read(source: server.source, key: nil, cached: nil)
        XCTAssertNil(withoutKey.cache)
    }

    func testARefusalDuringAFullTraversalIsAnOrdinarySanitizedFailure() async throws {
        let server = Server()
        server.zones = zones(zoneA)
        server.answers["\(zoneA.zoneName)@nil"] = .failure(CKError(.zoneNotFound))
        do {
            _ = try await CloudActivityHistoryReader.read(source: server.source, key: makeKey(), cached: nil)
            XCTFail("A zone that vanished mid-read is a failed read")
        } catch let error as CloudActivityHistoryPreflightError {
            guard case .cloud = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: The file

    func testTheStoreRoundTripsAndRejectsCorruptMismatchedOrOversizedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryCache-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CloudActivityHistoryMarkerCacheStore(url: directory.appendingPathComponent(CloudActivityHistoryMarkerCacheStore.fileName))
        let key = makeKey()
        let cache = CloudActivityHistoryMarkerCache(key: key, zones: [
            .init(zoneName: zoneA.zoneName, ownerName: zoneA.ownerName, changeToken: Data("A1".utf8),
                  markers: [.init(recordName: "m1", snapshot: marker(1))], holdsUserRecords: true)])
        XCTAssertNil(store.load(matching: key), "No file is the ordinary first state")
        store.save(cache)
        XCTAssertEqual(store.load(matching: key), cache)
        XCTAssertEqual(store.load(matching: key)?.seed(for: zoneA).values.first, cache.seed(for: zoneA).values.first,
                       "Marker dates survive bit-exactly")
        XCTAssertNil(store.load(matching: makeKey()), "Another binding never reads this file")

        // A file from before zones remembered user rows does not decode, so
        // the next read is a full traversal that recomputes them.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        legacy["zones"] = (legacy["zones"] as? [[String: Any]])?.map { zone in
            zone.filter { $0.key != "holdsUserRecords" }
        }
        try JSONSerialization.data(withJSONObject: legacy).write(to: store.url)
        XCTAssertNil(store.load(matching: key))
        store.save(cache)

        try Data("{ not json".utf8).write(to: store.url)
        XCTAssertNil(store.load(matching: key))

        let unreadableToken = CloudActivityHistoryMarkerCache(key: key, zones: [
            .init(zoneName: zoneA.zoneName, ownerName: zoneA.ownerName, changeToken: Data(), markers: [],
                  holdsUserRecords: false)])
        store.save(unreadableToken)
        XCTAssertNil(store.load(matching: key), "An empty token is not a starting point")

        store.save(cache)
        store.clear()
        XCTAssertNil(store.load(matching: key))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testOnlyServerRefusalsRequestAFullTraversal() {
        XCTAssertTrue(CloudActivityHistoryReader.requiresFullTraversal(after: CKError(.changeTokenExpired)))
        XCTAssertTrue(CloudActivityHistoryReader.requiresFullTraversal(after: CKError(.zoneNotFound)))
        XCTAssertTrue(CloudActivityHistoryReader.requiresFullTraversal(after: CKError(.userDeletedZone)))
        XCTAssertTrue(CloudActivityHistoryReader.requiresFullTraversal(
            after: CloudActivityHistoryReadRefused.server(CKError(.changeTokenExpired))))
        XCTAssertTrue(CloudActivityHistoryReader.requiresFullTraversal(
            after: CloudActivityHistoryPreflightError.cloud(.classify(CKError(.changeTokenExpired), stage: .privateDatabase))))
        for other in [CKError(.networkUnavailable), CKError(.notAuthenticated), CKError(.quotaExceeded),
                      CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [zoneA: CKError(.serverRecordChanged)]])] {
            XCTAssertFalse(CloudActivityHistoryReader.requiresFullTraversal(after: other), "\(other.code)")
        }
        XCTAssertFalse(CloudActivityHistoryReader.requiresFullTraversal(after: CloudActivityHistoryPreflightError.malformedHistory))
        XCTAssertFalse(CloudActivityHistoryReader.requiresFullTraversal(after: CancellationError()))
    }
}
