import CloudKit
import CoreFoundation
import Foundation

enum StorageTransferCloudSchema {
    /// This exact current-owner zone is validated independently by the durable
    /// pending-transaction gate. A source manifest never claims to cover it.
    static let zoneName = "PomoGemStorageTransfer-v1"
    static let managedZoneName = "com.apple.coredata.cloudkit.zone"

    static func isSourceZone(_ id: CKRecordZone.ID) throws -> Bool {
        let defaultID = CKRecordZone.default().zoneID
        guard id.ownerName == defaultID.ownerName else { throw CloudStorageTransferCloudError.unsupportedZone }
        if id == defaultID || id.zoneName == zoneName { return false }
        guard id.zoneName == managedZoneName else { throw CloudStorageTransferCloudError.unsupportedZone }
        return true
    }
}

enum CloudStorageTransferCloudError: Error, LocalizedError, Equatable {
    case timedOut, incomplete, malformedRecord, unsupportedSchema, unsupportedZone
    case missingRelationship, changedDuringRead, limitExceeded
    case cloud(CloudAccountVerificationFailure)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            "iCloudの全データの確認に時間がかかっています。保存先は変更していません。通信状態を確認して再試行してください。"
        case .changedDuringRead:
            "確認中にiCloudの保存領域が変わりました。保存先は変更していません。ほかの端末での操作が落ち着いてから再試行してください。"
        case .cloud(let failure): failure.errorDescription
        case .incomplete, .malformedRecord, .unsupportedSchema, .unsupportedZone,
             .missingRelationship, .limitExceeded:
            "iCloudの全データを安全に確認できませんでした。保存先は変更していません。アプリを最新版へ更新して再試行してください。"
        }
    }

    static func sanitized(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let known = error as? Self { return known }
        if let known = error as? AppleAccountBoundaryResolutionError { return known }
        return Self.cloud(CloudAccountVerificationFailure.classify(error, stage: .privateDatabase))
    }
}

/// Tokens and record names are private, account-bound transport evidence. This
/// is an observed complete read, not a transaction lock or a deletion permit.
struct CloudStorageTransferSnapshot: Sendable {
    let snapshot: PomoGemStorageSnapshot
    let binding: ActiveAccountLocalBinding
    let zones: [CloudStorageTransferZoneManifest]
}

struct CloudStorageTransferZoneManifest: @unchecked Sendable {
    let zoneID: CKRecordZone.ID
    let terminalToken: Data
    let recordCount: Int
}

struct CloudStorageTransferDatabaseSnapshot: Sendable {
    let snapshot: PomoGemStorageSnapshot
    let zones: [CloudStorageTransferZoneManifest]
}

struct CloudStorageTransferCloudClient: Sendable {
    var verifyAccount: @MainActor @Sendable (ActiveAccountLocalBinding) async throws -> Void
    var readDatabase: @Sendable () async throws -> CloudStorageTransferDatabaseSnapshot

    @MainActor static var live: Self {
        let decoder = CloudStorageTransferRecordDecoder()
        return Self(verifyAccount: { binding in
            _ = try await AppleAccountBoundaryResolver().resolve(expectedBinding: binding)
        }, readDatabase: {
            try await CloudStorageTransferDatabaseReader.read(decoder: decoder)
        })
    }
}

/// Read only: no subscriptions, schema creation, record writes, zone deletion,
/// operations container, or persistence deployment changes occur here.
@MainActor
struct CloudStorageTransferCloudKit {
    nonisolated static let defaultTimeout: TimeInterval = 180
    private let client: CloudStorageTransferCloudClient
    private let timeout: TimeInterval
    private let notificationCenter: NotificationCenter

    init(client: CloudStorageTransferCloudClient? = nil,
         timeout: TimeInterval = defaultTimeout,
         notificationCenter: NotificationCenter = .default) {
        self.client = client ?? .live
        self.timeout = timeout.isFinite ? min(max(timeout, 0.01), 300) : Self.defaultTimeout
        self.notificationCenter = notificationCenter
    }

    func readSnapshot(expectedBinding: ActiveAccountLocalBinding,
                      validateTransfer: () throws -> Void) async throws -> CloudStorageTransferSnapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let accountLease = StorageTransferAccountLease(center: notificationCenter)
        defer { accountLease.stop() }
        func validate() throws {
            try Task.checkCancellation()
            try accountLease.check()
            try validateTransfer()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CloudStorageTransferCloudError.timedOut
            }
        }
        try validate()
        let client = client
        try await storageTransferWithDeadline(deadline) {
            try await client.verifyAccount(expectedBinding)
        }
        try validate()
        let result = try await storageTransferWithDeadline(deadline) {
            try await client.readDatabase()
        }
        try validate()
        try await storageTransferWithDeadline(deadline) {
            try await client.verifyAccount(expectedBinding)
        }
        try result.snapshot.validate()
        try validate()
        return CloudStorageTransferSnapshot(snapshot: result.snapshot, binding: expectedBinding, zones: result.zones)
    }
}

/// Core Data's published read mapping uses CD_<attribute>, an optional
/// CD_<attribute>_ckAsset, and string record names for to-one foreign keys.
/// See https://developer.apple.com/documentation/coredata/reading-cloudkit-records-for-core-data
struct CloudStorageTransferRecordDecoder: Sendable {
    typealias Scalar = PomoGemStorageSnapshot.Scalar
    struct Field: Sendable {
        let name: String
        let kind: Scalar.Kind
        let isOptional: Bool
    }
    static let entities: Set<String> = ["Subject", "StudySession", "AchievementStone", "Prefs", "ActivityResetMarker", "SyncedFocusTimer", "FocusTimerDeviceClaim"]
    static let maximumFieldBytes = 4 * 1024 * 1024
    let fieldsByEntity: [String: [Field]]

    @MainActor init() {
        fieldsByEntity = PomoGemStorageSnapshot.fieldDescriptors
            .filter { Self.entities.contains($0.key) }
            .mapValues { $0.map { Field(name: $0.name, kind: $0.kind, isOptional: $0.isOptional) } }
    }

    func decode(_ record: CKRecord) throws -> CloudStorageTransferDecodedRecord {
        guard let entity = record["CD_entityName"] as? String,
              Self.entities.contains(entity), record.recordType == "CD_" + entity,
              let descriptors = fieldsByEntity[entity] else {
            throw CloudStorageTransferCloudError.unsupportedSchema
        }
        var allowed = Set(["CD_entityName"])
        for field in descriptors {
            allowed.insert("CD_" + field.name)
            if [.string, .data].contains(field.kind) {
                allowed.insert("CD_" + field.name + "_ckAsset")
            }
        }
        let hasSubject = entity == "StudySession" || entity == "AchievementStone"
        if hasSubject { allowed.insert("CD_subject") }
        guard Set(record.allKeys()).isSubset(of: allowed) else {
            throw CloudStorageTransferCloudError.unsupportedSchema
        }
        var fields: [String: Scalar] = [:]
        for descriptor in descriptors {
            fields[descriptor.name] = try scalar(record: record, entity: entity, field: descriptor)
        }
        let subject: CKRecord.ID?
        if let value = record["CD_subject"] {
            guard hasSubject, let name = value as? String, !name.isEmpty, name.utf8.count <= 4096 else {
                throw CloudStorageTransferCloudError.malformedRecord
            }
            subject = CKRecord.ID(recordName: name, zoneID: record.recordID.zoneID)
        } else { subject = nil }
        return CloudStorageTransferDecodedRecord(id: record.recordID, entity: entity, fields: fields, subject: subject)
    }

    private func scalar(record: CKRecord, entity: String, field: Field) throws -> Scalar {
        let key = "CD_" + field.name
        var value = record[key]
        let assetValue = record[key + "_ckAsset"]
        if let assetValue {
            guard [.string, .data].contains(field.kind), let asset = assetValue as? CKAsset else {
                throw CloudStorageTransferCloudError.malformedRecord
            }
            let originalIsEmpty = value == nil || (value as? String)?.isEmpty == true || (value as? Data)?.isEmpty == true
            if originalIsEmpty {
                guard let url = asset.fileURL else { throw CloudStorageTransferCloudError.incomplete }
                let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard size.isRegularFile == true, let count = size.fileSize,
                      count <= Self.maximumFieldBytes else { throw CloudStorageTransferCloudError.limitExceeded }
                let bytes = try Data(contentsOf: url)
                guard bytes.count <= Self.maximumFieldBytes else { throw CloudStorageTransferCloudError.limitExceeded }
                if field.kind == .string, !Self.isEnum(entity: entity, field: field.name) {
                    guard let string = String(data: bytes, encoding: .utf8) else { throw CloudStorageTransferCloudError.malformedRecord }
                    value = string as NSString
                } else { value = bytes as NSData }
            }
        }
        guard let value else {
            guard field.isOptional else { throw CloudStorageTransferCloudError.incomplete }
            return .null
        }
        switch field.kind {
        case .string:
            if Self.isEnum(entity: entity, field: field.name) {
                return .string(try Self.enumValue(value, property: field.name))
            }
            guard let string = value as? String else { throw CloudStorageTransferCloudError.malformedRecord }
            guard string.utf8.count <= Self.maximumFieldBytes else { throw CloudStorageTransferCloudError.limitExceeded }
            return .string(string)
        case .integer:
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw CloudStorageTransferCloudError.malformedRecord
            }
            let integer: Int?
            if ["f", "d"].contains(String(cString: number.objCType)) { integer = Int(exactly: number.doubleValue) }
            else { integer = Int(number.stringValue) }
            guard let integer else { throw CloudStorageTransferCloudError.malformedRecord }
            return .integer(integer)
        case .boolean:
            guard let number = value as? NSNumber, number == 0 || number == 1 else {
                throw CloudStorageTransferCloudError.malformedRecord
            }
            return .boolean(number.boolValue)
        case .double:
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
                throw CloudStorageTransferCloudError.malformedRecord
            }
            return .doubleBits(number.doubleValue.bitPattern)
        case .date:
            guard let date = value as? Date, date.timeIntervalSinceReferenceDate.isFinite else {
                throw CloudStorageTransferCloudError.malformedRecord
            }
            return .dateBits(date.timeIntervalSinceReferenceDate.bitPattern)
        case .uuid:
            guard let string = value as? String, let uuid = UUID(uuidString: string) else {
                throw CloudStorageTransferCloudError.malformedRecord
            }
            return .uuid(uuid)
        case .data:
            guard let data = value as? Data else { throw CloudStorageTransferCloudError.malformedRecord }
            guard data.count <= Self.maximumFieldBytes else { throw CloudStorageTransferCloudError.limitExceeded }
            return .data(data)
        }
    }

    private static func isEnum(entity: String, field: String) -> Bool {
        (entity == "StudySession" && ["source", "pebbleKind"].contains(field)) || (entity == "AchievementStone" && field == "kind")
    }

    /// SwiftData's observed secure archive stores {<property name>: <raw enum>}.
    /// Only public Foundation classes are decoded. Unknown enum values fail
    /// closed instead of substituting a model initializer's default value.
    static func enumValue(_ value: CKRecordValue, property: String) throws -> String {
        let allowed: Set<String>
        switch property {
        case "source": allowed = ["timer", "manual", "timerDemoted"]
        case "pebbleKind": allowed = ["normal", "gold", "prism"]
        case "kind": allowed = ["perfectScore", "examPass", "workMilestone"]
        default: throw CloudStorageTransferCloudError.unsupportedSchema
        }
        if let string = value as? String, allowed.contains(string) { return string }
        guard let data = value as? Data, data.count <= maximumFieldBytes,
              let object = try? NSKeyedUnarchiver.unarchivedObject(
                // Core Data's NSKnownKeysDictionary uses Foundation arrays
                // and numbers internally even for a one-string dictionary.
                ofClasses: [NSDictionary.self, NSArray.self, NSString.self, NSNumber.self], from: data
              ), let dictionary = object as? NSDictionary, dictionary.count == 1,
              let string = dictionary[property] as? String, allowed.contains(string) else {
            throw CloudStorageTransferCloudError.malformedRecord
        }
        return string
    }
}

struct CloudStorageTransferDecodedRecord: @unchecked Sendable {
    let id: CKRecord.ID
    let entity: String
    let fields: [String: PomoGemStorageSnapshot.Scalar]
    let subject: CKRecord.ID?

    var estimatedBytes: Int {
        fields.reduce(id.recordName.utf8.count + 128) { count, entry in
            let size: Int
            switch entry.value {
            case .string(let value): size = value.utf8.count
            case .data(let value): size = value.count
            default: size = 32
            }
            return count + entry.key.utf8.count + size
        }
    }
}

struct CloudStorageTransferZoneAccumulator {
    static let maximumRows = 100_000
    static let maximumBytes = 64 * 1024 * 1024
    private(set) var rows: [CKRecord.ID: CloudStorageTransferDecodedRecord] = [:]
    private var byteCount = 0
    private var failure: Error?
    private var token: Data?
    private var finished = false

    mutating func changed(_ id: CKRecord.ID, result: Result<CKRecord, Error>, decoder: CloudStorageTransferRecordDecoder) {
        guard failure == nil else { return }
        do {
            let record = try result.get()
            guard record.recordID == id else { throw CloudStorageTransferCloudError.incomplete }
            let row = try decoder.decode(record)
            let nextBytes = byteCount - (rows[id]?.estimatedBytes ?? 0) + row.estimatedBytes
            guard nextBytes <= Self.maximumBytes, rows[id] != nil || rows.count < Self.maximumRows else {
                throw CloudStorageTransferCloudError.limitExceeded
            }
            rows[id] = row
            byteCount = nextBytes
        } catch { failure = CloudStorageTransferCloudError.sanitized(error) }
    }

    mutating func deleted(_ id: CKRecord.ID) {
        if let row = rows.removeValue(forKey: id) { byteCount -= row.estimatedBytes }
    }

    mutating func page(_ result: Result<(token: Data, moreComing: Bool), Error>) {
        switch result {
        case .success(let page):
            token = page.token
            finished = !page.moreComing
        case .failure(let error): failure = failure ?? CloudStorageTransferCloudError.sanitized(error)
        }
    }

    func complete(_ result: Result<Void, Error>) throws -> (rows: [CloudStorageTransferDecodedRecord], token: Data) {
        if let failure { throw failure }
        do { try result.get() } catch { throw CloudStorageTransferCloudError.sanitized(error) }
        guard finished, let token, !token.isEmpty else { throw CloudStorageTransferCloudError.incomplete }
        return (Array(rows.values), token)
    }
}

enum CloudStorageTransferGraph {
    static func snapshot(_ rows: [CloudStorageTransferDecodedRecord]) throws -> PomoGemStorageSnapshot {
        let rows = rows.sorted {
            let a = [$0.id.zoneID.ownerName, $0.id.zoneID.zoneName, $0.id.recordName]
            let b = [$1.id.zoneID.ownerName, $1.id.zoneID.zoneName, $1.id.recordName]
            return a.lexicographicallyPrecedes(b)
        }
        guard Set(rows.map(\.id)).count == rows.count else { throw CloudStorageTransferCloudError.incomplete }
        let references = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
        var studies: [Int: [Int]] = [:]
        var achievements: [Int: [Int]] = [:]
        var parents: [Int: Int] = [:]
        for (reference, row) in rows.enumerated() {
            guard let subject = row.subject else { continue }
            guard let parent = references[subject], rows[parent].entity == "Subject" else {
                throw CloudStorageTransferCloudError.missingRelationship
            }
            parents[reference] = parent
            if row.entity == "StudySession" { studies[parent, default: []].append(reference) }
            else if row.entity == "AchievementStone" { achievements[parent, default: []].append(reference) }
            else { throw CloudStorageTransferCloudError.malformedRecord }
        }
        let records = rows.enumerated().map { reference, row in
            var relationships: [String: PomoGemStorageSnapshot.Relationship] = [:]
            if row.entity == "Subject" {
                relationships["studySessions"] = .toMany(studies[reference] ?? [])
                relationships["achievementStones"] = .toMany(achievements[reference] ?? [])
            } else if row.entity == "StudySession" || row.entity == "AchievementStone" {
                relationships["subject"] = .toOne(parents[reference])
            }
            return PomoGemStorageSnapshot.Record(reference: reference, entity: row.entity, fields: row.fields, relationships: relationships)
        }
        return PomoGemStorageSnapshot(records: records)
    }
}

private enum CloudStorageTransferDatabaseReader {
    static func read(decoder: CloudStorageTransferRecordDecoder) async throws -> CloudStorageTransferDatabaseSnapshot {
        let database = CKContainer(identifier: CloudSyncConfiguration.synchronizedDataContainerIdentifier).privateCloudDatabase
        let before = try await zones(database)
        var allRows: [CloudStorageTransferDecodedRecord] = []
        var manifests: [CloudStorageTransferZoneManifest] = []
        var totalBytes = 0
        // The separate launch/coordinator transaction gate must validate the
        // control zone before authorizing this source-data-only read.
        for zone in before where try StorageTransferCloudSchema.isSourceZone(zone.zoneID) {
            try Task.checkCancellation()
            guard zone.capabilities.contains(.fetchChanges) else { throw CloudStorageTransferCloudError.unsupportedZone }
            let page: (rows: [CloudStorageTransferDecodedRecord], token: Data) = try await storageTransferOperation { finish in
                let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
                config.previousServerChangeToken = nil
                config.resultsLimit = 200
                config.desiredKeys = nil
                let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zone.zoneID], configurationsByRecordZoneID: [zone.zoneID: config])
                configure(operation)
                operation.fetchAllChanges = true
                let state = StorageTransferLocked(CloudStorageTransferZoneAccumulator())
                operation.recordWasChangedBlock = { id, result in state.withValue { $0.changed(id, result: result, decoder: decoder) } }
                operation.recordWithIDWasDeletedBlock = { id, _ in state.withValue { $0.deleted(id) } }
                operation.recordZoneFetchResultBlock = { id, result in
                    guard id == zone.zoneID else {
                        state.withValue { $0.page(.failure(CloudStorageTransferCloudError.incomplete)) }
                        return
                    }
                    let mapped = result.flatMap { page -> Result<(token: Data, moreComing: Bool), Error> in
                        Result { (try NSKeyedArchiver.archivedData(withRootObject: page.serverChangeToken, requiringSecureCoding: true), page.moreComing) }
                    }
                    state.withValue { $0.page(mapped) }
                }
                operation.fetchRecordZoneChangesResultBlock = { result in
                    finish(Result { try state.withValue { try $0.complete(result) } })
                }
                database.add(operation)
                return operation
            }
            totalBytes += page.rows.reduce(0) { $0 + $1.estimatedBytes }
            guard allRows.count + page.rows.count <= CloudStorageTransferZoneAccumulator.maximumRows,
                  totalBytes <= CloudStorageTransferZoneAccumulator.maximumBytes else { throw CloudStorageTransferCloudError.limitExceeded }
            allRows.append(contentsOf: page.rows)
            manifests.append(CloudStorageTransferZoneManifest(zoneID: zone.zoneID, terminalToken: page.token, recordCount: page.rows.count))
        }
        let after = try await zones(database)
        guard Set(before.map(\.zoneID)) == Set(after.map(\.zoneID)) else { throw CloudStorageTransferCloudError.changedDuringRead }
        try Task.checkCancellation()
        return CloudStorageTransferDatabaseSnapshot(snapshot: try CloudStorageTransferGraph.snapshot(allRows), zones: manifests)
    }

    private static func zones(_ database: CKDatabase) async throws -> [CKRecordZone] {
        try await storageTransferOperation { finish in
            let operation = CKFetchRecordZonesOperation.fetchAllRecordZonesOperation()
            configure(operation)
            let state = StorageTransferLocked((zones: [CKRecordZone.ID: CKRecordZone](), failure: Optional<Error>.none))
            operation.perRecordZoneResultBlock = { id, result in
                state.withValue { state in
                    do {
                        let zone = try result.get()
                        let defaultID = CKRecordZone.default().zoneID
                        guard id == zone.zoneID, id.ownerName == defaultID.ownerName,
                              id.zoneName != defaultID.zoneName || id == defaultID else { throw CloudStorageTransferCloudError.unsupportedZone }
                        _ = try StorageTransferCloudSchema.isSourceZone(id)
                        guard state.zones[id] != nil || state.zones.count < 128 else { throw CloudStorageTransferCloudError.limitExceeded }
                        state.zones[id] = zone
                    } catch { state.failure = state.failure ?? error }
                }
            }
            operation.fetchRecordZonesResultBlock = { result in
                let value = state.withValue { $0 }
                if let failure = value.failure { finish(.failure(failure)) }
                else { finish(result.map { Array(value.zones.values) }) }
            }
            database.add(operation)
            return operation
        }
    }

    private static func configure(_ operation: CKOperation) {
        operation.configuration.qualityOfService = .userInitiated
        operation.configuration.timeoutIntervalForRequest = 15
        operation.configuration.timeoutIntervalForResource = 45
    }
}

final class StorageTransferAccountLease: @unchecked Sendable {
    private let changed = StorageTransferLocked(false)
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?
    init(center: NotificationCenter) {
        self.center = center
        observer = center.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
            self?.changed.withValue { $0 = true }
        }
    }
    func check() throws {
        guard !changed.withValue({ $0 }) else {
            throw AppleAccountBoundaryResolutionError.blocked(.accountMismatch)
        }
    }
    func stop() {
        if let observer { center.removeObserver(observer) }
        observer = nil
    }
    deinit { stop() }
}

private final class StorageTransferLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<Result>(_ action: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try action(&value)
    }
}

private final class StorageTransferCompletion<Value>: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, Error>?
        var result: Result<Value, Error>?
        var cancel: (() -> Void)?
    }
    private let state = StorageTransferLocked(State())
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

private func storageTransferOperation<Value>(start: (@escaping (Result<Value, Error>) -> Void) -> CKOperation) async throws -> Value {
    let completion = StorageTransferCompletion<Value>()
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation)
            let operation = start { completion.finish($0.mapError(CloudStorageTransferCloudError.sanitized)) }
            completion.installCancellation { operation.cancel() }
        }
    } onCancel: { completion.finish(.failure(CancellationError())) }
}

private func storageTransferWithDeadline<Value: Sendable>(_ deadline: TimeInterval,
    operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
    let remaining = deadline - ProcessInfo.processInfo.systemUptime
    guard remaining > 0 else { throw CloudStorageTransferCloudError.timedOut }
    let completion = StorageTransferCompletion<Value>()
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation)
            let work = Task {
                do { completion.finish(.success(try await operation())) }
                catch { completion.finish(.failure(CloudStorageTransferCloudError.sanitized(error))) }
            }
            let timer = Task {
                do {
                    try await Task.sleep(for: .seconds(remaining))
                    completion.finish(.failure(CloudStorageTransferCloudError.timedOut))
                } catch { }
            }
            completion.installCancellation { work.cancel(); timer.cancel() }
        }
    } onCancel: { completion.finish(.failure(CancellationError())) }
}
