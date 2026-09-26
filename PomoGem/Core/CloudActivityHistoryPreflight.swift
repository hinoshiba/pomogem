import CloudKit
import CoreFoundation
import Foundation
import SwiftData

/// Absence of a receipt is not a verified observation of an empty history.
enum CloudActivityHistoryRecordedBaseline: Equatable, Sendable {
    case unavailable
    case observed(ActivityResetSnapshot?)

    init(receipt: CloudOfflineAccessReceipt?) {
        guard let receipt, receipt.origin != .revokedWithoutBaseline else {
            self = .unavailable
            return
        }
        self = .observed(receipt.resetBaseline)
    }
}

/// A reachable account is insufficient to authorize new activity: the local
/// store must have imported at least the reset history observed on the server.
enum CloudActivityHistoryAdmissionPolicy {
    static func isReady(local: ActivityResetSnapshot?, remote: ActivityResetSnapshot?) -> Bool {
        guard let remote else { return true }
        guard ActivityResetPolicy.isSupported(remote), let local,
              ActivityResetPolicy.isSupported(local) else { return false }
        // resetAt is audit metadata, not part of the ordering. Its transport
        // precision must not make an otherwise identical generation wait.
        if local.sequence != remote.sequence { return local.sequence > remote.sequence }
        if local.writerDeviceID != remote.writerDeviceID { return local.writerDeviceID > remote.writerDeviceID }
        if local.epochID != remote.epochID { return local.epochID.uuidString > remote.epochID.uuidString }
        return local.id.uuidString >= remote.id.uuidString
    }

    static func recordedBaselineMatches(
        _ recordedBaseline: CloudActivityHistoryRecordedBaseline,
        remote: ActivityResetSnapshot?
    ) -> Bool {
        guard case let .observed(marker) = recordedBaseline else { return false }
        return CloudActivityHistoryPreflight.sameOfflineHistory(marker, remote)
    }

    /// A past observation can authorize unchanged server history. Otherwise a
    /// fresh local winner must exactly match: an arbitrary newer local reset
    /// alone is not authority to supersede the current server generation.
    static func permitsExistingReplica(
        recordedBaseline: CloudActivityHistoryRecordedBaseline,
        currentLocal: ActivityResetSnapshot?,
        remote: ActivityResetSnapshot?
    ) -> Bool {
        recordedBaselineMatches(recordedBaseline, remote: remote)
            || CloudActivityHistoryPreflight.sameOfflineHistory(currentLocal, remote)
    }
}

enum CloudActivityHistoryPreflightError: Error, LocalizedError, Equatable {
    case timedOut, malformedHistory, incompleteHistory, unsupportedZone, historyLimit, localHistoryUnavailable
    case offlineHistoryChanged
    case cloud(CloudAccountVerificationFailure)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            "iCloudの記録の履歴を確認するのに時間がかかっています。記録を保護するため保存領域をまだ開いていません。通信状態を確認して再試行してください。"
        case .cloud(let failure): failure.errorDescription
        case .localHistoryUnavailable:
            "端末に届いたiCloudの履歴を確認できませんでした。再試行してください。"
        case .offlineHistoryChanged:
            "別の端末で記録の履歴が変更されています。このiPhoneで保存した記録を守るため、同期を停止しています。端末の記録は保持しています。"
        case .malformedHistory, .incompleteHistory, .unsupportedZone, .historyLimit:
            "iCloudの記録の履歴を安全に確認できませんでした。記録を保護するため保存領域をまだ開いていません。アプリを最新版へ更新し、再試行してください。"
        }
    }

    static func sanitized(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let known = error as? Self { return known }
        return Self.cloud(CloudAccountVerificationFailure.classify(error, stage: .privateDatabase))
    }
}

/// What one complete, account-verified traversal of the server's zones saw.
struct CloudActivityHistoryObservation: Equatable, Sendable {
    var markers: [ActivityResetSnapshot]
    /// launch-06. Whether the traversal passed at least one theme, focus
    /// record or achievement stone — rows only a device that finished
    /// onboarding (or used the app) on this account writes. The traversal
    /// already walks every record for the reset markers, so this costs no
    /// request.
    ///
    /// Presentation evidence only: it chooses between the new-user tutorial
    /// and 「iCloudから記録を復元しています」 on a store that has not finished
    /// onboarding, and never authorizes, blocks or delays a mount. A false
    /// positive costs a waiting screen that already offers 「新しく始める」;
    /// a false negative shows the tutorial, which is today's behaviour.
    ///
    /// A delta read (PR 15) only sees what changed since the cached tokens,
    /// so each cached zone carries what its last full traversal saw and
    /// stays true for as long as the cache key matches
    /// (`CloudActivityHistoryMarkerCache.Zone.holdsUserRecords`).
    var holdsUserRecords: Bool

    init(markers: [ActivityResetSnapshot], holdsUserRecords: Bool = false) {
        self.markers = markers
        self.holdsUserRecords = holdsUserRecords
    }
}

/// One read of the server's reset markers. `commit` remembers what the read
/// saw for the next one (PR 15); the preflight calls it only after the
/// identity check that follows the read, and after its own mount validation,
/// have both passed. A read that is abandoned is never committed.
struct CloudActivityHistoryMarkerRead: Sendable {
    let observation: CloudActivityHistoryObservation
    let commit: @MainActor @Sendable () -> Void

    var markers: [ActivityResetSnapshot] { observation.markers }

    init(markers: [ActivityResetSnapshot], holdsUserRecords: Bool = false,
         commit: @escaping @MainActor @Sendable () -> Void = {}) {
        self.observation = CloudActivityHistoryObservation(markers: markers, holdsUserRecords: holdsUserRecords)
        self.commit = commit
    }
}

struct CloudActivityHistoryClient: Sendable {
    var verifyAccount: @MainActor @Sendable (ActiveAccountLocalBinding) async throws -> Void
    var readHistory: @MainActor @Sendable (ActiveAccountLocalBinding) async throws -> CloudActivityHistoryMarkerRead

    init(verifyAccount: @escaping @MainActor @Sendable (ActiveAccountLocalBinding) async throws -> Void,
         readHistory: @escaping @MainActor @Sendable (ActiveAccountLocalBinding) async throws -> CloudActivityHistoryMarkerRead) {
        self.verifyAccount = verifyAccount
        self.readHistory = readHistory
    }

    /// A reader with nothing to remember, for tests that script each step.
    init(verifyAccount: @escaping @MainActor @Sendable (ActiveAccountLocalBinding) async throws -> Void,
         readHistory: @escaping @Sendable () async throws -> CloudActivityHistoryObservation) {
        self.init(verifyAccount: verifyAccount, readHistory: { _ in
            let observation = try await readHistory()
            return CloudActivityHistoryMarkerRead(markers: observation.markers,
                                                  holdsUserRecords: observation.holdsUserRecords)
        })
    }

    /// A marker-only reader observes no user rows.
    init(verifyAccount: @escaping @MainActor @Sendable (ActiveAccountLocalBinding) async throws -> Void,
         readMarkers: @escaping @Sendable () async throws -> [ActivityResetSnapshot]) {
        self.init(verifyAccount: verifyAccount, readHistory: { _ in
            CloudActivityHistoryMarkerRead(markers: try await readMarkers())
        })
    }

    /// device-02 / launch-02. The identity checks on either side of the marker
    /// read no longer carry their own network probe (a zone-list fetch each,
    /// four per launch): the marker read between them is itself a fresh
    /// private-database request that fails without an account or a network,
    /// the same reasoning Docs/OfflineCloudMode.md applies to the control
    /// read. What is proved is unchanged — account status, then the identity
    /// read twice and resolved to exactly this binding before the read, the
    /// read, and the same again after it — and the preflight still validates
    /// its mount between every step.
    ///
    /// device-02 (PR 15). The read starts from the per-binding change-token
    /// cache when one is valid for exactly this binding, CloudKit environment,
    /// container and local dataset generation, and falls back to a full
    /// traversal on any doubt (`CloudActivityHistoryMarkerCache`).
    static var live: Self {
        Self(verifyAccount: { binding in
            try await CloudActivityHistoryIdentityCheck.verify(binding: binding)
        }, readHistory: { binding in
            let store = CloudActivityHistoryMarkerCacheStore.live()
            let key = CloudActivityHistoryMarkerCache.Key.current(binding: binding)
            let cached = key.flatMap { store?.load(matching: $0) }
            let read = try await CloudActivityHistoryReader.readMarkers(key: key, cached: cached)
            return CloudActivityHistoryMarkerRead(markers: read.markers, holdsUserRecords: read.holdsUserRecords, commit: {
                if let next = read.cache { store?.save(next) } else { store?.clear() }
            })
        })
    }
}

/// The identity check around a marker read: `accountStatus → identity →
/// identity`, then the fingerprint/registry resolution compared with the
/// binding. It makes no network request of its own; the read it brackets is
/// the network proof.
@MainActor
enum CloudActivityHistoryIdentityCheck {
    static func verify(
        binding: ActiveAccountLocalBinding,
        accountClient: CloudAccountVerificationClient = .live(
            containerIdentifier: CloudSyncConfiguration.synchronizedDataContainerIdentifier),
        defaults: UserDefaults = .standard,
        transferJournalStore: StorageTransferJournalStore? = nil,
        retryDelay: TimeInterval = 0.5
    ) async throws {
        var client = accountClient
        client.probePrivateDatabase = {}
        let boundary = try await AppleAccountBoundaryResolver(defaults: defaults, client: client,
            retryDelay: retryDelay, transferJournalStore: transferJournalStore)
            .resolve(expectedBinding: binding)
        guard boundary.binding == binding else {
            throw AppleAccountBoundaryResolutionError.blocked(.accountMismatch)
        }
    }
}

@MainActor
struct CloudActivityHistoryPreflight {
    nonisolated static let defaultTimeout: TimeInterval = 90
    private let client: CloudActivityHistoryClient
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval

    init(client: CloudActivityHistoryClient = .live,
         timeout: TimeInterval = defaultTimeout,
         pollInterval: TimeInterval = 0.25) {
        self.client = client
        self.timeout = timeout.isFinite ? min(max(0.01, timeout), 300) : Self.defaultTimeout
        self.pollInterval = pollInterval.isFinite ? min(max(0.01, pollInterval), 1) : 0.25
    }

    @discardableResult
    func run(context: ModelContext, expectedBinding: ActiveAccountLocalBinding,
             validateMount: () throws -> Void) async throws -> CloudActivityHistoryObservation {
        let container = context.container
        return try await run(expectedBinding: expectedBinding, validateMount: validateMount) {
            // A long-lived main context can retain a stale registered object.
            // A fresh reader sees imports committed by the mirroring stack.
            let reader = ModelContext(container)
            reader.autosaveEnabled = false
            do { return try ActivityResetStore.latestSnapshot(context: reader) }
            catch { throw CloudActivityHistoryPreflightError.localHistoryUnavailable }
        }
    }

    /// The strict recorded-baseline path used while a `.none` session is live.
    /// Its local reset history cannot receive CloudKit imports in that session.
    func verifyOfflineBaseline(_ baseline: ActivityResetSnapshot?,
                               expectedBinding: ActiveAccountLocalBinding,
                               validateMount: () throws -> Void) async throws {
        try await verifyExistingReplicaBeforeMirroring(recordedBaseline: .observed(baseline),
            expectedBinding: expectedBinding,
            readCurrentLocalMarker: { throw CloudActivityHistoryPreflightError.offlineHistoryChanged },
            validateMount: validateMount)
    }

    /// Run for every established cache before constructing a new mirror,
    /// including older releases with no offline receipt. A cloud mount never
    /// proves native history was exported. The callback reads only the current
    /// local marker using an unpublished, read-only context; it must not hydrate
    /// or repair the source to make this comparison pass. Callers retain exact
    /// account/store/scene leases and track and retire the reader container.
    /// This does not stop an already-live mirror's autonomous reconnection.
    func verifyExistingReplicaBeforeMirroring(
        recordedBaseline: CloudActivityHistoryRecordedBaseline,
        expectedBinding: ActiveAccountLocalBinding,
        readCurrentLocalMarker: @MainActor () throws -> ActivityResetSnapshot?,
        validateMount: () throws -> Void
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func validate() throws {
            try Task.checkCancellation()
            try validateMount()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CloudActivityHistoryPreflightError.timedOut
            }
        }
        try validate()
        let client = client
        try await cloudHistoryWithDeadline(deadline) {
            try await client.verifyAccount(expectedBinding)
        }
        try validate()
        let read = try await cloudHistoryWithDeadline(deadline) {
            try await client.readHistory(expectedBinding)
        }
        try validate()
        try await cloudHistoryWithDeadline(deadline) {
            try await client.verifyAccount(expectedBinding)
        }
        try validate()
        read.commit()
        let markers = read.markers
        let remote = ActivityResetPolicy.currentMarker(from: markers)
        if CloudActivityHistoryAdmissionPolicy.recordedBaselineMatches(recordedBaseline, remote: remote) { return }
        let local: ActivityResetSnapshot?
        do { local = try readCurrentLocalMarker() }
        catch is CancellationError { throw CancellationError() }
        catch let error as CloudActivityHistoryPreflightError { throw error }
        catch { throw CloudActivityHistoryPreflightError.localHistoryUnavailable }
        try validate()
        guard CloudActivityHistoryAdmissionPolicy.permitsExistingReplica(
            recordedBaseline: recordedBaseline, currentLocal: local, remote: remote) else {
            throw CloudActivityHistoryPreflightError.offlineHistoryChanged
        }
    }

    nonisolated static func sameOfflineHistory(_ local: ActivityResetSnapshot?,
                                              _ remote: ActivityResetSnapshot?) -> Bool {
        switch (local, remote) {
        case (nil, nil): return true
        case let (local?, remote?):
            return ActivityResetPolicy.isSupported(local) && ActivityResetPolicy.isSupported(remote)
                && local.id == remote.id && local.epochID == remote.epochID
                && local.sequence == remote.sequence && local.writerDeviceID == remote.writerDeviceID
        default: return false
        }
    }

    /// The closure form also exercises the real asynchronous admission flow in
    /// tests without inventing a cloud-backed ModelContainer or local fixture.
    @discardableResult
    func run(expectedBinding: ActiveAccountLocalBinding,
             validateMount: () throws -> Void,
             localMarker: () throws -> ActivityResetSnapshot?) async throws -> CloudActivityHistoryObservation {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func validate() throws {
            try Task.checkCancellation()
            try validateMount()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CloudActivityHistoryPreflightError.timedOut
            }
        }
        try validate()
        let client = client
        try await cloudHistoryWithDeadline(deadline) {
            try await client.verifyAccount(expectedBinding)
        }
        try validate()
        let read = try await cloudHistoryWithDeadline(deadline) {
            try await client.readHistory(expectedBinding)
        }
        try validate()
        let remote = ActivityResetPolicy.currentMarker(from: read.markers)
        try await cloudHistoryWithDeadline(deadline) {
            try await client.verifyAccount(expectedBinding)
        }
        try validate()
        read.commit()
        while !CloudActivityHistoryAdmissionPolicy.isReady(local: try localMarker(), remote: remote) {
            try validate()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .seconds(min(pollInterval, max(0, remaining))))
            try validate()
        }
        // Root must additionally recheck its live account and exact candidate
        // before publication. This callback checks its generation/selection on
        // both sides of every suspension, including the final import wait.
        try validate()
        return read.observation
    }
}

/// Apple's documented read mapping: CD_ActivityResetMarker and CD_<attribute>.
/// This reader does not create schemas, subscriptions, records, or change tokens.
/// See developer.apple.com/documentation/coredata/reading-cloudkit-records-for-core-data
enum CloudActivityHistoryRecordParser {
    static let desiredKeys = ["CD_entityName", "CD_id", "CD_epochID", "CD_sequence", "CD_resetAt", "CD_writerDeviceID"]

    static func parse(_ record: CKRecord) throws -> ActivityResetSnapshot? {
        let entity = record["CD_entityName"] as? String
        guard record.recordType == "CD_ActivityResetMarker" || entity == "ActivityResetMarker" else { return nil }
        guard record.recordType == "CD_ActivityResetMarker", entity == "ActivityResetMarker",
              let number = record["CD_sequence"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw CloudActivityHistoryPreflightError.malformedHistory
        }
        let ordinal = number.doubleValue
        guard ordinal.isFinite, ordinal.rounded() == ordinal else {
            throw CloudActivityHistoryPreflightError.malformedHistory
        }
        // Match the existing local policy: impossible ordinals cannot become
        // a winner or pin the clock. Never silently ignore missing fields.
        guard ordinal >= 0, ordinal <= Double(ActivityResetPolicy.maximumSupportedSequence) else { return nil }
        guard let idString = record["CD_id"] as? String, let id = UUID(uuidString: idString),
              let epochString = record["CD_epochID"] as? String, let epoch = UUID(uuidString: epochString),
              let date = record["CD_resetAt"] as? Date, date.timeIntervalSince1970.isFinite,
              let writer = record["CD_writerDeviceID"] as? String, writer.utf8.count <= 4096 else {
            throw CloudActivityHistoryPreflightError.malformedHistory
        }
        return ActivityResetSnapshot(id: id, epochID: epoch, sequence: Int(ordinal), resetAt: date, writerDeviceID: writer)
    }
}

/// Retain only marker rows, not the unrelated session history traversed by a
/// zone fetch. Deletions and updates can lower a zone's observed live maximum.
/// A delta read starts from the markers the cache recorded for that zone
/// (`seed`) and applies exactly the changes and deletions since its token.
struct CloudActivityHistoryAccumulator {
    static let maximumMarkers = 10_000
    /// launch-06. The mirrored rows that exist only because somebody set up
    /// or used a jar on this account: finishing onboarding always creates a
    /// theme. Prefs is deliberately not one of them — every launch's bounded
    /// preparation creates this device's settings row before onboarding, so
    /// a new user who quit during the tutorial would find their own row on
    /// the next launch. Reset markers, timers and device claims are
    /// bookkeeping and say nothing about an earlier jar either.
    static let userRecordTypes: Set<CKRecord.RecordType> = [
        "CD_Subject", "CD_StudySession", "CD_AchievementStone"
    ]
    private var markers: [CKRecord.ID: ActivityResetSnapshot]
    private var failure: Error?
    private var finishedAllPages = false
    /// A flag, not a count: a full traversal with no change token reports
    /// current rows once, and the only consumer asks whether any exist. A
    /// delta read reports only rows changed since its token; the reader adds
    /// what the zone's cache entry remembered.
    private(set) var sawUserRecord = false
    /// The unsanitized zone error, kept only to recognise the few server
    /// answers that ask for a full traversal instead (`changeTokenExpired`,
    /// `zoneNotFound`, `userDeletedZone`). Never presented or persisted.
    private(set) var rawZoneError: Error?

    init(seed: [CKRecord.ID: ActivityResetSnapshot] = [:]) {
        markers = seed
    }

    mutating func record(_ id: CKRecord.ID, result: Result<CKRecord, Error>) {
        guard failure == nil else { return }
        do {
            let record = try result.get()
            if let marker = try CloudActivityHistoryRecordParser.parse(record) {
                guard markers[id] != nil || markers.count < Self.maximumMarkers else {
                    throw CloudActivityHistoryPreflightError.historyLimit
                }
                markers[id] = marker
            } else {
                markers[id] = nil
                if Self.userRecordTypes.contains(record.recordType) { sawUserRecord = true }
            }
        } catch { failure = CloudActivityHistoryPreflightError.sanitized(error) }
    }

    mutating func deleted(_ id: CKRecord.ID) { markers[id] = nil }
    mutating func page(_ result: Result<Bool, Error>) {
        switch result {
        case let .success(moreComing): finishedAllPages = !moreComing
        case let .failure(error):
            rawZoneError = rawZoneError ?? error
            failure = failure ?? CloudActivityHistoryPreflightError.sanitized(error)
        }
    }

    func result(operation: Result<Void, Error>) throws -> [ActivityResetSnapshot] {
        try observation(operation: operation).markers
    }

    /// The zone's result only once every page arrived: an incomplete zone is
    /// never evidence of anything, including of user rows.
    func observation(operation: Result<Void, Error>) throws -> CloudActivityHistoryObservation {
        CloudActivityHistoryObservation(markers: Array(try markerMap(operation: operation).values),
                                        holdsUserRecords: sawUserRecord)
    }

    func markerMap(operation: Result<Void, Error>) throws -> [CKRecord.ID: ActivityResetSnapshot] {
        if let failure { throw failure }
        do { try operation.get() } catch { throw CloudActivityHistoryPreflightError.sanitized(error) }
        guard finishedAllPages else { throw CloudActivityHistoryPreflightError.incompleteHistory }
        return markers
    }
}

/// One custom zone of the synchronized container, as the zone list reported it.
struct CloudActivityHistoryZone: Hashable, Sendable {
    let zoneID: CKRecordZone.ID
    let supportsFetchChanges: Bool
}

/// What one zone-changes request returned: the finished accumulator and the
/// archived server change token the zone reported with its last page.
struct CloudActivityHistoryZoneRead: Sendable {
    let markers: [CKRecord.ID: ActivityResetSnapshot]
    let changeToken: Data?
    /// Whether this request passed a user row (launch-06). For a delta read,
    /// only rows changed since the token.
    let holdsUserRecords: Bool
}

/// The two CloudKit requests the reader makes. The live source adds real
/// operations to the private database; tests script them.
struct CloudActivityHistoryZoneSource: Sendable {
    var listZones: @Sendable () async throws -> [CloudActivityHistoryZone]
    /// Every change in `zone` since `changeToken` (nil: since the beginning),
    /// applied to an accumulator that starts from `seed`.
    var fetchChanges: @Sendable (_ zone: CloudActivityHistoryZone, _ changeToken: Data?,
                                 _ seed: [CKRecord.ID: ActivityResetSnapshot]) async throws -> CloudActivityHistoryZoneRead
}

/// The result of one reset-history read and the cache it may leave behind.
struct CloudActivityHistoryRead: Sendable {
    enum Mode: Equatable, Sendable {
        /// Every page of every zone, from a nil token.
        case full
        /// Only the changes since the cached tokens.
        case delta
        /// A delta was refused by the server (expired token, missing zone)
        /// and the read started over as a full traversal.
        case fullAfterRefusedDelta
    }

    let markers: [ActivityResetSnapshot]
    /// launch-06: a full traversal's answer, or for a delta read what each
    /// zone's cache entry remembered plus what the delta passed.
    let holdsUserRecords: Bool
    /// Present only when every zone reported a token under a known key. The
    /// caller writes it only after the identity bracket accepted this read.
    let cache: CloudActivityHistoryMarkerCache?
    let mode: Mode
}

enum CloudActivityHistoryReader {
    static let maximumZones = 128

    /// Reads with the live source, starting from the cache when it is valid.
    static func readMarkers(key: CloudActivityHistoryMarkerCache.Key?,
                            cached: CloudActivityHistoryMarkerCache?) async throws -> CloudActivityHistoryRead {
        try await read(source: .live, key: key, cached: cached)
    }

    static func read(source: CloudActivityHistoryZoneSource,
                     key: CloudActivityHistoryMarkerCache.Key?,
                     cached: CloudActivityHistoryMarkerCache?) async throws -> CloudActivityHistoryRead {
        let listed = try await source.listZones()
        guard listed.count <= maximumZones else { throw CloudActivityHistoryPreflightError.historyLimit }
        var zones: [CloudActivityHistoryZone] = []
        for zone in listed where zone.zoneID != CKRecordZone.default().zoneID {
            guard zone.supportsFetchChanges else { throw CloudActivityHistoryPreflightError.unsupportedZone }
            zones.append(zone)
        }
        if let key, let cache = cached?.validated(for: key),
           Set(cache.zones.map(\.zoneID)) == Set(zones.map(\.zoneID)) {
            do {
                return try await traverse(zones, source: source, key: key, from: cache, mode: .delta)
            } catch let error where requiresFullTraversal(after: error) {
                return try await traverse(zones, source: source, key: key, from: nil, mode: .fullAfterRefusedDelta)
            }
        }
        return try await traverse(zones, source: source, key: key, from: nil, mode: .full)
    }

    private struct DeltaRefused: Error {
        let underlying: Error
    }

    private static func traverse(_ zones: [CloudActivityHistoryZone], source: CloudActivityHistoryZoneSource,
                                 key: CloudActivityHistoryMarkerCache.Key?,
                                 from cache: CloudActivityHistoryMarkerCache?,
                                 mode: CloudActivityHistoryRead.Mode) async throws -> CloudActivityHistoryRead {
        var markers: [ActivityResetSnapshot] = []
        var holdsUserRecords = false
        var cachedZones: [CloudActivityHistoryMarkerCache.Zone] = []
        var everyZoneHasToken = true
        for zone in zones {
            try Task.checkCancellation()
            var token: Data?
            // launch-06. A delta only reports rows changed since the token,
            // so a zone keeps what its last full traversal saw while the key
            // matches; a full traversal recomputes it from nothing.
            var zoneHeldUserRecords = false
            if let cache {
                guard let stored = cache.zones.first(where: { $0.zoneID == zone.zoneID }) else {
                    throw DeltaRefused(underlying: CloudActivityHistoryPreflightError.incompleteHistory)
                }
                token = stored.changeToken
                zoneHeldUserRecords = stored.holdsUserRecords
            }
            let read: CloudActivityHistoryZoneRead
            do {
                read = try await source.fetchChanges(zone, token, cache?.seed(for: zone.zoneID) ?? [:])
            } catch let CloudActivityHistoryReadRefused.server(underlying) where cache == nil {
                // Nothing left to start over from: a full traversal that is
                // refused is an ordinary, sanitized read failure.
                throw CloudActivityHistoryPreflightError.sanitized(underlying)
            }
            markers.append(contentsOf: read.markers.values)
            let zoneHoldsUserRecords = zoneHeldUserRecords || read.holdsUserRecords
            holdsUserRecords = holdsUserRecords || zoneHoldsUserRecords
            guard markers.count <= CloudActivityHistoryAccumulator.maximumMarkers else {
                throw CloudActivityHistoryPreflightError.historyLimit
            }
            if let changeToken = read.changeToken, !changeToken.isEmpty {
                cachedZones.append(.init(zoneName: zone.zoneID.zoneName, ownerName: zone.zoneID.ownerName,
                    changeToken: changeToken,
                    markers: read.markers.map { .init(recordName: $0.key.recordName, snapshot: $0.value) }
                        .sorted { $0.recordName < $1.recordName },
                    holdsUserRecords: zoneHoldsUserRecords))
            } else {
                everyZoneHasToken = false
            }
        }
        try Task.checkCancellation()
        let nextCache = key.flatMap { everyZoneHasToken ? CloudActivityHistoryMarkerCache(key: $0, zones: cachedZones) : nil }
        return CloudActivityHistoryRead(markers: markers, holdsUserRecords: holdsUserRecords,
                                        cache: nextCache, mode: mode)
    }

    /// The server answers after which a delta read starts over from nil. Any
    /// other failure is a failure of the read and fails closed as before.
    static func requiresFullTraversal(after error: Error) -> Bool {
        if error is DeltaRefused { return true }
        let refusals: Set<Int> = [CKError.Code.changeTokenExpired.rawValue,
                                  CKError.Code.zoneNotFound.rawValue,
                                  CKError.Code.userDeletedZone.rawValue]
        func refused(_ error: Error) -> Bool {
            let nsError = error as NSError
            guard nsError.domain == CKErrorDomain else { return false }
            if refusals.contains(nsError.code) { return true }
            if nsError.code == CKError.Code.partialFailure.rawValue,
               let partial = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
                return partial.values.contains(where: refused)
            }
            return false
        }
        if case let CloudActivityHistoryReadRefused.server(underlying) = error { return refused(underlying) }
        if case let CloudActivityHistoryPreflightError.cloud(failure) = error,
           let code = failure.cloudKitCode { return refusals.contains(code) }
        return refused(error)
    }

    fileprivate static func configure(_ operation: CKOperation) {
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        operation.configuration = configuration
    }
}

/// A zone-changes request the server refused in a way that asks for a full
/// traversal. Carries the raw CloudKit error only as far as the reader, which
/// never lets it escape: it either starts over or throws a sanitized error.
enum CloudActivityHistoryReadRefused: Error {
    case server(Error)
}

extension CloudActivityHistoryZoneSource {
    static var live: Self {
        let database = CKContainer(identifier: CloudSyncConfiguration.synchronizedDataContainerIdentifier).privateCloudDatabase
        return Self(listZones: {
            let zones: [CKRecordZone] = try await cloudHistoryOperation { finish in
                let operation = CKFetchRecordZonesOperation.fetchAllRecordZonesOperation()
                CloudActivityHistoryReader.configure(operation)
                let state = CloudHistoryLocked((zones: [CKRecordZone](), failure: Optional<Error>.none))
                operation.perRecordZoneResultBlock = { _, result in
                    state.withValue { state in
                        switch result {
                        case let .success(zone): state.zones.append(zone)
                        case let .failure(error): state.failure = state.failure ?? error
                        }
                    }
                }
                operation.fetchRecordZonesResultBlock = { result in
                    let value = state.withValue { $0 }
                    if let failure = value.failure { finish(.failure(failure)) }
                    else { finish(result.map { value.zones }) }
                }
                CloudKitRoundTripLedger.record(.historyZoneList)
                database.add(operation)
                return operation
            }
            return zones.map { CloudActivityHistoryZone(zoneID: $0.zoneID,
                                                        supportsFetchChanges: $0.capabilities.contains(.fetchChanges)) }
        }, fetchChanges: { zone, changeToken, seed in
            let previousToken: CKServerChangeToken?
            if let changeToken {
                guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self,
                                                                          from: changeToken) else {
                    // An unreadable cached token is a doubt, never an error.
                    throw CloudActivityHistoryReadRefused.server(CKError(.changeTokenExpired))
                }
                previousToken = token
            } else {
                previousToken = nil
            }
            return try await cloudHistoryOperation(sanitizing: { error in
                // Keep the refusal recognisable; sanitize everything else.
                CloudActivityHistoryReader.requiresFullTraversal(after: error)
                    ? CloudActivityHistoryReadRefused.server(error)
                    : CloudActivityHistoryPreflightError.sanitized(error)
            }) { finish in
                let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
                configuration.previousServerChangeToken = previousToken
                // device-02. The server picks its own (larger) batch size on
                // a full traversal instead of the old fixed 200.
                configuration.desiredKeys = CloudActivityHistoryRecordParser.desiredKeys
                let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zone.zoneID],
                    configurationsByRecordZoneID: [zone.zoneID: configuration])
                CloudActivityHistoryReader.configure(operation)
                operation.fetchAllChanges = true
                let state = CloudHistoryLocked((accumulator: CloudActivityHistoryAccumulator(seed: seed),
                                                token: Optional<CKServerChangeToken>.none))
                operation.recordWasChangedBlock = { id, result in state.withValue { $0.accumulator.record(id, result: result) } }
                operation.recordWithIDWasDeletedBlock = { id, _ in state.withValue { $0.accumulator.deleted(id) } }
                operation.recordZoneFetchResultBlock = { _, result in
                    state.withValue { value in
                        if case let .success(page) = result { value.token = page.serverChangeToken }
                        value.accumulator.page(result.map { $0.moreComing })
                    }
                }
                operation.fetchRecordZoneChangesResultBlock = { result in
                    let value = state.withValue { $0 }
                    if let raw = value.accumulator.rawZoneError,
                       CloudActivityHistoryReader.requiresFullTraversal(after: raw) {
                        finish(.failure(raw))
                        return
                    }
                    if case let .failure(raw) = result,
                       CloudActivityHistoryReader.requiresFullTraversal(after: raw) {
                        finish(.failure(raw))
                        return
                    }
                    do {
                        let markers = try value.accumulator.markerMap(operation: result)
                        let archived = value.token.flatMap {
                            try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
                        }
                        finish(.success(CloudActivityHistoryZoneRead(markers: markers, changeToken: archived,
                            holdsUserRecords: value.accumulator.sawUserRecord)))
                    } catch {
                        finish(.failure(error))
                    }
                }
                CloudKitRoundTripLedger.record(.historyZoneChanges)
                database.add(operation)
                return operation
            }
        })
    }
}

private final class CloudHistoryLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<Result>(_ operation: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation(&value)
    }
}

private final class CloudHistoryCompletion<Value>: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, Error>?
        var result: Result<Value, Error>?
        var cancel: (() -> Void)?
    }
    private let state = CloudHistoryLocked(State())
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let result = state.withValue { state -> Result<Value, Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }
    func installCancellation(_ cancel: @escaping () -> Void) {
        let finished = state.withValue { state in
            if state.result != nil { return true }
            state.cancel = cancel
            return false
        }
        if finished { cancel() }
    }
    func finish(_ result: Result<Value, Error>) {
        let completion = state.withValue { state -> (CheckedContinuation<Value, Error>?, (() -> Void)?) in
            guard state.result == nil else { return (nil, nil) }
            state.result = result
            let completion = (state.continuation, state.cancel)
            state.continuation = nil
            state.cancel = nil
            return completion
        }
        completion.1?()
        completion.0?.resume(with: result)
    }
}

private func cloudHistoryOperation<Value>(
    sanitizing: @escaping (Error) -> Error = CloudActivityHistoryPreflightError.sanitized,
    start: (@escaping (Result<Value, Error>) -> Void) -> CKOperation
) async throws -> Value {
    let completion = CloudHistoryCompletion<Value>()
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation)
            let operation = start { result in
                completion.finish(result.mapError(sanitizing))
            }
            completion.installCancellation { operation.cancel() }
        }
    } onCancel: { completion.finish(.failure(CancellationError())) }
}

private func cloudHistoryWithDeadline<Value: Sendable>(
    _ deadline: TimeInterval,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let remaining = deadline - ProcessInfo.processInfo.systemUptime
    guard remaining > 0 else { throw CloudActivityHistoryPreflightError.timedOut }
    let completion = CloudHistoryCompletion<Value>()
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation)
            let work = Task {
                do { completion.finish(.success(try await operation())) }
                catch { completion.finish(.failure(error)) }
            }
            let timer = Task {
                do {
                    try await Task.sleep(for: .seconds(remaining))
                    completion.finish(.failure(CloudActivityHistoryPreflightError.timedOut))
                } catch { }
            }
            completion.installCancellation { work.cancel(); timer.cancel() }
        }
    } onCancel: { completion.finish(.failure(CancellationError())) }
}
