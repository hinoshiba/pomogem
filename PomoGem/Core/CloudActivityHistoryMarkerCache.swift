import CloudKit
import Foundation
import OSLog

/// device-02 / launch-02. What the last complete, account-verified reset
/// history read saw, so the next read can ask CloudKit only for what changed.
///
/// Before this, every cloud mount traversed every page of every custom zone
/// from a nil change token — twice per launch — just to find a handful of
/// `CD_ActivityResetMarker` rows, so launch time grew with the user's whole
/// history inside a 12-second budget. With this cache each read is one zone
/// list plus one delta page per zone in the steady state.
///
/// The cache never replaces a server read: a fresh request still reaches the
/// server on every read, and the identity bracket around it is unchanged. It
/// is only a starting point for that request, and every doubt falls back to
/// today's full traversal (`CloudActivityHistoryReader`):
/// - no cache, an unreadable or oversized file, another format version;
/// - a different account binding, namespace, CloudKit environment, container
///   or local dataset generation (`Key`);
/// - a different set of zones than the cached one;
/// - `changeTokenExpired`, `zoneNotFound` or `userDeletedZone` for any zone.
/// It is written only after a read that the identity bracket accepted, and
/// cleared on account-state movements, revocations, storage transfers and
/// complete deletion. Any other failure of a delta read fails closed exactly
/// like a full read, and leaves the cache untouched.
///
/// It lives beside the offline receipt (`Application Support/CloudOffline`),
/// never in iCloud, and holds no user content: zone names, opaque server
/// change tokens and the reset markers' own identifiers.
struct CloudActivityHistoryMarkerCache: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1
    /// Reset markers are rare. A cache that would exceed this is not written.
    static let maximumBytes = 1_048_576

    struct Key: Codable, Equatable, Sendable {
        let namespace: String
        let accountFingerprint: String
        let environment: String
        let containerIdentifier: String
        /// The local dataset admission's generation, or "none". A read that
        /// could not establish it has no key and is never cached.
        let datasetGeneration: String

        init?(binding: ActiveAccountLocalBinding, scope: StorageTransferCloudScope,
              datasetGenerationID: UUID?) {
            guard scope.isKnown else { return nil }
            namespace = binding.namespace.rawValue
            accountFingerprint = binding.accountFingerprint
            environment = scope.environment.rawValue
            containerIdentifier = scope.containerIdentifier
            datasetGeneration = datasetGenerationID?.uuidString ?? "none"
        }
    }

    struct Zone: Codable, Equatable, Sendable {
        let zoneName: String
        let ownerName: String
        /// `NSKeyedArchiver` data of the zone's `CKServerChangeToken`.
        let changeToken: Data
        let markers: [Marker]

        var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName) }
    }

    struct Marker: Codable, Equatable, Sendable {
        let recordName: String
        let id: UUID
        let epochID: UUID
        let sequence: Int
        let resetAtBits: UInt64
        let writerDeviceID: String

        init(recordName: String, snapshot: ActivityResetSnapshot) {
            self.recordName = recordName
            id = snapshot.id
            epochID = snapshot.epochID
            sequence = snapshot.sequence
            resetAtBits = snapshot.resetAt.timeIntervalSinceReferenceDate.bitPattern
            writerDeviceID = snapshot.writerDeviceID
        }

        var snapshot: ActivityResetSnapshot {
            ActivityResetSnapshot(id: id, epochID: epochID, sequence: sequence,
                resetAt: Date(timeIntervalSinceReferenceDate: Double(bitPattern: resetAtBits)),
                writerDeviceID: writerDeviceID)
        }
    }

    var formatVersion = Self.currentFormatVersion
    let key: Key
    let zones: [Zone]

    init(key: Key, zones: [Zone]) {
        self.key = key
        self.zones = zones.sorted { ($0.ownerName, $0.zoneName) < ($1.ownerName, $1.zoneName) }
    }

    /// A structurally sound cache for exactly this key, or nil.
    func validated(for key: Key) -> Self? {
        guard formatVersion == Self.currentFormatVersion, self.key == key,
              Set(zones.map(\.zoneID)).count == zones.count,
              zones.allSatisfy({ !$0.changeToken.isEmpty }),
              zones.reduce(0, { $0 + $1.markers.count }) <= CloudActivityHistoryAccumulator.maximumMarkers
        else { return nil }
        return self
    }

    func seed(for zoneID: CKRecordZone.ID) -> [CKRecord.ID: ActivityResetSnapshot] {
        guard let zone = zones.first(where: { $0.zoneID == zoneID }) else { return [:] }
        return Dictionary(zone.markers.map { (CKRecord.ID(recordName: $0.recordName, zoneID: zoneID), $0.snapshot) },
                          uniquingKeysWith: { first, _ in first })
    }
}

/// The file behind the cache. Best effort by design: a cache that cannot be
/// read or written only costs a full traversal, so nothing here throws.
@MainActor
struct CloudActivityHistoryMarkerCacheStore {
    static let fileName = "history-markers-v1.json"
    private static let logger = Logger(subsystem: "com.hinoshiba.pomogem", category: "CloudHistory")

    let url: URL

    init(url: URL) {
        self.url = url
    }

    /// Beside `access-v1.json`, in the directory `CloudOfflineAccessState`
    /// creates and validates (no links inside the app container).
    static func live() -> Self? {
        guard let directory = try? CloudOfflineAccessState().directory else { return nil }
        return Self(url: directory.appendingPathComponent(fileName))
    }

    func load(matching key: Key) -> CloudActivityHistoryMarkerCache? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              !data.isEmpty, data.count <= CloudActivityHistoryMarkerCache.maximumBytes,
              let cache = try? JSONDecoder().decode(CloudActivityHistoryMarkerCache.self, from: data)
        else { return nil }
        return cache.validated(for: key)
    }

    func save(_ cache: CloudActivityHistoryMarkerCache) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(cache)
            guard data.count <= CloudActivityHistoryMarkerCache.maximumBytes else {
                clear()
                return
            }
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.logger.notice("Reset-history cache could not be written; the next read traverses every zone")
            clear()
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    typealias Key = CloudActivityHistoryMarkerCache.Key

    /// Account-state movements, revocations, storage transfers and complete
    /// deletion call this. A missing file is the ordinary state.
    static func clearLive() {
        live()?.clear()
    }
}

extension CloudActivityHistoryMarkerCache.Key {
    /// The key for a read made now, or nil when any part of it cannot be
    /// established — in which case nothing is read from or written to the cache.
    @MainActor
    static func current(binding: ActiveAccountLocalBinding) -> Self? {
        guard let runtime = try? StorageTransferRuntime.live(),
              let admission = try? runtime.localDatasetAdmission(binding: binding) else {
            // No admission receipt (or an unreadable one) is not a generation
            // this cache may be keyed by.
            return nil
        }
        return Self(binding: binding, scope: .current(), datasetGenerationID: admission.datasetGenerationID)
    }
}
