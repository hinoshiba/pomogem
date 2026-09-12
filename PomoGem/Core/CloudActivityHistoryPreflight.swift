import CloudKit
import CoreFoundation
import Foundation
import SwiftData

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
}

enum CloudActivityHistoryPreflightError: Error, LocalizedError, Equatable {
    case timedOut, malformedHistory, incompleteHistory, unsupportedZone, historyLimit, localHistoryUnavailable
    case cloud(CloudAccountVerificationFailure)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            "iCloudの記録の履歴を確認するのに時間がかかっています。記録を保護するため保存領域をまだ開いていません。通信状態を確認して再試行してください。"
        case .cloud(let failure): failure.errorDescription
        case .localHistoryUnavailable:
            "端末に届いたiCloudの履歴を確認できませんでした。再試行してください。"
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

struct CloudActivityHistoryClient: Sendable {
    var verifyAccount: @MainActor @Sendable (ActiveAccountLocalBinding) async throws -> Void
    var readMarkers: @Sendable () async throws -> [ActivityResetSnapshot]

    static var live: Self {
        Self(verifyAccount: { binding in
            _ = try await AppleAccountBoundaryResolver().resolve(expectedBinding: binding)
        }, readMarkers: {
            try await CloudActivityHistoryReader.readMarkers()
        })
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

    func run(context: ModelContext, expectedBinding: ActiveAccountLocalBinding,
             validateMount: () throws -> Void) async throws {
        let container = context.container
        try await run(expectedBinding: expectedBinding, validateMount: validateMount) {
            // A long-lived main context can retain a stale registered object.
            // A fresh reader sees imports committed by the mirroring stack.
            let reader = ModelContext(container)
            reader.autosaveEnabled = false
            do { return try ActivityResetStore.latestSnapshot(context: reader) }
            catch { throw CloudActivityHistoryPreflightError.localHistoryUnavailable }
        }
    }

    /// The closure form also exercises the real asynchronous admission flow in
    /// tests without inventing a cloud-backed ModelContainer or local fixture.
    func run(expectedBinding: ActiveAccountLocalBinding,
             validateMount: () throws -> Void,
             localMarker: () throws -> ActivityResetSnapshot?) async throws {
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
        let markers = try await cloudHistoryWithDeadline(deadline) {
            try await client.readMarkers()
        }
        try validate()
        let remote = ActivityResetPolicy.currentMarker(from: markers)
        try await cloudHistoryWithDeadline(deadline) {
            try await client.verifyAccount(expectedBinding)
        }
        try validate()
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
struct CloudActivityHistoryAccumulator {
    static let maximumMarkers = 10_000
    private var markers: [CKRecord.ID: ActivityResetSnapshot] = [:]
    private var failure: Error?
    private var finishedAllPages = false

    mutating func record(_ id: CKRecord.ID, result: Result<CKRecord, Error>) {
        guard failure == nil else { return }
        do {
            let record = try result.get()
            if let marker = try CloudActivityHistoryRecordParser.parse(record) {
                guard markers[id] != nil || markers.count < Self.maximumMarkers else {
                    throw CloudActivityHistoryPreflightError.historyLimit
                }
                markers[id] = marker
            } else { markers[id] = nil }
        } catch { failure = CloudActivityHistoryPreflightError.sanitized(error) }
    }

    mutating func deleted(_ id: CKRecord.ID) { markers[id] = nil }
    mutating func page(_ result: Result<Bool, Error>) {
        switch result {
        case let .success(moreComing): finishedAllPages = !moreComing
        case let .failure(error): failure = failure ?? CloudActivityHistoryPreflightError.sanitized(error)
        }
    }

    func result(operation: Result<Void, Error>) throws -> [ActivityResetSnapshot] {
        if let failure { throw failure }
        do { try operation.get() } catch { throw CloudActivityHistoryPreflightError.sanitized(error) }
        guard finishedAllPages else { throw CloudActivityHistoryPreflightError.incompleteHistory }
        return Array(markers.values)
    }
}

private enum CloudActivityHistoryReader {
    static func readMarkers() async throws -> [ActivityResetSnapshot] {
        let database = CKContainer(identifier: CloudSyncConfiguration.synchronizedDataContainerIdentifier).privateCloudDatabase
        let zones: [CKRecordZone] = try await cloudHistoryOperation { finish in
            let operation = CKFetchRecordZonesOperation.fetchAllRecordZonesOperation()
            configure(operation)
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
            database.add(operation)
            return operation
        }
        guard zones.count <= 128 else { throw CloudActivityHistoryPreflightError.historyLimit }
        var markers: [ActivityResetSnapshot] = []
        for zone in zones {
            try Task.checkCancellation()
            if zone.zoneID == CKRecordZone.default().zoneID { continue }
            guard zone.capabilities.contains(.fetchChanges) else {
                throw CloudActivityHistoryPreflightError.unsupportedZone
            }
            let zoneMarkers: [ActivityResetSnapshot] = try await cloudHistoryOperation { finish in
                let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
                configuration.previousServerChangeToken = nil
                configuration.resultsLimit = 200
                configuration.desiredKeys = CloudActivityHistoryRecordParser.desiredKeys
                let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zone.zoneID], configurationsByRecordZoneID: [zone.zoneID: configuration])
                configure(operation)
                operation.fetchAllChanges = true
                let state = CloudHistoryLocked(CloudActivityHistoryAccumulator())
                operation.recordWasChangedBlock = { id, result in state.withValue { $0.record(id, result: result) } }
                operation.recordWithIDWasDeletedBlock = { id, _ in state.withValue { $0.deleted(id) } }
                operation.recordZoneFetchResultBlock = { _, result in state.withValue { $0.page(result.map { $0.moreComing }) } }
                operation.fetchRecordZoneChangesResultBlock = { result in
                    do { finish(.success(try state.withValue { try $0.result(operation: result) })) }
                    catch { finish(.failure(error)) }
                }
                database.add(operation)
                return operation
            }
            markers.append(contentsOf: zoneMarkers)
            guard markers.count <= CloudActivityHistoryAccumulator.maximumMarkers else {
                throw CloudActivityHistoryPreflightError.historyLimit
            }
        }
        try Task.checkCancellation()
        return markers
    }

    private static func configure(_ operation: CKOperation) {
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        operation.configuration = configuration
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
    start: (@escaping (Result<Value, Error>) -> Void) -> CKOperation
) async throws -> Value {
    let completion = CloudHistoryCompletion<Value>()
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation)
            let operation = start { result in
                completion.finish(result.mapError(CloudActivityHistoryPreflightError.sanitized))
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
