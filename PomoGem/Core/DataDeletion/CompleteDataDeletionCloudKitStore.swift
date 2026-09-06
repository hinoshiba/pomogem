import CloudKit
import Foundation

enum CompleteDataDeletionCloudError: LocalizedError {
    case missingResult
    case malformedFence
    case concurrentDeletion
    case fenceConflict
    case zoneDeletionDidNotConverge

    var errorDescription: String? {
        switch self {
        case .missingResult:
            return "CloudKitが削除処理の個別結果を返しませんでした。"
        case .malformedFence:
            return "CloudKitの削除世代情報を検証できませんでした。"
        case .concurrentDeletion:
            return "別の端末でデータ削除が進行中です。"
        case .fenceConflict:
            return "CloudKitの削除世代が処理中に変更されました。"
        case .zoneDeletionDidNotConverge:
            return "CloudKitのユーザーデータ領域を空にできませんでした。"
        }
    }
}

/// Direct CloudKit implementation of Apple's data-deletion guidance.
///
/// SwiftData's generated zone and the direct-CloudKit operation zones live in
/// separate containers. Every private custom zone in the SwiftData container,
/// and every operation zone other than the fence, is permanently deleted and
/// re-enumerated. One dedicated zone containing a single non-content generation
/// record is retained so an offline device can detect a newer deletion.
actor CloudKitCompleteDataDeletionRemoteStore: CompleteDataDeletionRemoteStoring {
    static let fenceZoneName = "PomoGemDeletionFence"
    static let fenceRecordType = "PomoGemDeletionGeneration"
    static let fenceRecordName = "current"

    private enum Field {
        static let formatVersion = "formatVersion"
        static let generationID = "generationID"
        static let transactionID = "transactionID"
        static let sequence = "sequence"
        static let state = "state"
        static let createdAt = "createdAt"
        static let updatedAt = "updatedAt"
    }

    private static let maximumConflictAttempts = 5
    private static let maximumZoneDeletionPasses = 5

    // This read sits directly on the launch/foreground critical path. A short,
    // non-discretionary lookup is enough to distinguish a reachable account;
    // subsequent foregrounds retry when connectivity returns. Bounding the
    // CKOperation itself (rather than racing an uncooperative async child task)
    // keeps ordinary offline timer use from waiting on CloudKit's longer retry
    // policy while still letting an already-known pending journal fail closed.
    static let fenceLookupRequestTimeout: TimeInterval = 2.5
    static let fenceLookupResourceTimeout: TimeInterval = 3

    /// Used only for the framework-owned SwiftData/Core Data schema. No raw
    /// records are ever created in this container.
    private let synchronizedDataDatabase: CKDatabase

    /// Used for the rare-reward CAS ledger and the retained deletion fence.
    private let operationsDatabase: CKDatabase

    init(
        synchronizedDataContainerIdentifier: String = CloudSyncConfiguration
            .synchronizedDataContainerIdentifier,
        operationsContainerIdentifier: String = CloudSyncConfiguration
            .operationsContainerIdentifier
    ) {
        synchronizedDataDatabase = CKContainer(
            identifier: synchronizedDataContainerIdentifier
        ).privateCloudDatabase
        operationsDatabase = CKContainer(
            identifier: operationsContainerIdentifier
        ).privateCloudDatabase
    }

    func establishPendingFence(
        transactionID: UUID,
        requestedGenerationID: UUID,
        requestedAt: Date
    ) async throws -> CompleteDataDeletionFence {
        try await ensureFenceZone()

        for _ in 0..<Self.maximumConflictAttempts {
            let existing = try await fetchFenceRecord()
            let existingFence = try existing.map(Self.decodeFence)

            if let existingFence,
               existingFence.transactionID == transactionID,
               existingFence.generationID == requestedGenerationID {
                return existingFence
            }
            if existingFence?.state == .pending {
                throw CompleteDataDeletionCloudError.concurrentDeletion
            }

            let nextSequence = (existingFence?.sequence ?? -1) + 1
            let record = existing ?? CKRecord(
                recordType: Self.fenceRecordType,
                recordID: Self.fenceRecordID
            )
            let fence = CompleteDataDeletionFence(
                generationID: requestedGenerationID,
                transactionID: transactionID,
                sequence: nextSequence,
                state: .pending,
                createdAt: requestedAt,
                updatedAt: requestedAt
            )
            Self.encode(fence, into: record)

            do {
                let saved = try await saveFenceRecord(record)
                return try Self.decodeFence(saved)
            } catch {
                guard Self.isServerRecordConflict(error) else { throw error }
            }
        }
        throw CompleteDataDeletionCloudError.fenceConflict
    }

    func deletePrivateCloudData(
        preserving fence: CompleteDataDeletionFence
    ) async throws -> CompleteDataDeletionCloudReceipt {
        let current = try await requiredCurrentFence()
        guard current.transactionID == fence.transactionID,
              current.generationID == fence.generationID,
              current.sequence == fence.sequence
        else {
            throw CompleteDataDeletionCloudError.fenceConflict
        }

        let synchronizedCount = try await deleteCustomZones(
            in: synchronizedDataDatabase,
            preserving: []
        )
        let operationsCount = try await deleteCustomZones(
            in: operationsDatabase,
            preserving: [Self.fenceZoneID]
        )
        return CompleteDataDeletionCloudReceipt(
            deletedZoneCount: synchronizedCount + operationsCount
        )
    }

    func commitFence(
        _ fence: CompleteDataDeletionFence,
        committedAt: Date
    ) async throws -> CompleteDataDeletionFence {
        for _ in 0..<Self.maximumConflictAttempts {
            guard let record = try await fetchFenceRecord() else {
                throw CompleteDataDeletionCloudError.fenceConflict
            }
            let current = try Self.decodeFence(record)
            guard current.transactionID == fence.transactionID,
                  current.generationID == fence.generationID,
                  current.sequence == fence.sequence
            else {
                throw CompleteDataDeletionCloudError.fenceConflict
            }
            if current.state == .committed { return current }

            let committed = current.committed(at: committedAt)
            Self.encode(committed, into: record)
            do {
                return try Self.decodeFence(try await saveFenceRecord(record))
            } catch {
                guard Self.isServerRecordConflict(error) else { throw error }
            }
        }
        throw CompleteDataDeletionCloudError.fenceConflict
    }

    func fetchFence() async -> CompleteDataDeletionRemoteFenceLookup {
        let result: Result<CKRecord?, any Error>
        do {
            result = .success(try await fetchFenceRecordForAvailabilityCheck())
        } catch {
            result = .failure(error)
        }
        return Self.lookup(fromBoundedFetch: result)
    }

    static func makeFenceLookupOperation(
        recordID: CKRecord.ID = fenceRecordID
    ) -> CKFetchRecordsOperation {
        let operation = CKFetchRecordsOperation(recordIDs: [recordID])
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        configuration.timeoutIntervalForRequest = fenceLookupRequestTimeout
        configuration.timeoutIntervalForResource = fenceLookupResourceTimeout
        operation.configuration = configuration
        return operation
    }

    static func lookup(
        fromBoundedFetch result: Result<CKRecord?, any Error>
    ) -> CompleteDataDeletionRemoteFenceLookup {
        let record: CKRecord?
        switch result {
        case let .success(value):
            record = value
        case .failure:
            // Includes CKError request/resource timeouts. Unavailability is not
            // treated as proof that a deletion fence is absent.
            return .unavailable
        }
        guard let record else { return .absent }
        do {
            return .found(try decodeFence(record))
        } catch {
            // A reachable but malformed safety record is an integrity failure,
            // not an offline-first exception.
            return .invalid
        }
    }

    private static var fenceZoneID: CKRecordZone.ID {
        CKRecordZone.ID(
            zoneName: fenceZoneName,
            ownerName: CKCurrentUserDefaultName
        )
    }

    private static var fenceRecordID: CKRecord.ID {
        CKRecord.ID(recordName: fenceRecordName, zoneID: fenceZoneID)
    }

    private func deleteCustomZones(
        in database: CKDatabase,
        preserving preservedZoneIDs: Set<CKRecordZone.ID>
    ) async throws -> Int {
        var deletedZoneIDs = Set<CKRecordZone.ID>()
        for _ in 0..<Self.maximumZoneDeletionPasses {
            let zoneIDs = try await database.allRecordZones()
                .map(\.zoneID)
                .filter {
                    $0 != .default && !preservedZoneIDs.contains($0)
                }
            if zoneIDs.isEmpty { return deletedZoneIDs.count }

            let results = try await database.modifyRecordZones(
                saving: [],
                deleting: zoneIDs
            )
            for zoneID in zoneIDs {
                guard let result = results.deleteResults[zoneID] else {
                    throw CompleteDataDeletionCloudError.missingResult
                }
                try result.get()
                deletedZoneIDs.insert(zoneID)
            }
        }

        // A mounted mirroring stack or another device can recreate a zone
        // while deletion is running. Never claim success in that state.
        let remaining = try await database.allRecordZones()
            .map(\.zoneID)
            .filter {
                $0 != .default && !preservedZoneIDs.contains($0)
            }
        guard remaining.isEmpty else {
            throw CompleteDataDeletionCloudError.zoneDeletionDidNotConverge
        }
        return deletedZoneIDs.count
    }

    private func ensureFenceZone() async throws {
        let zone = CKRecordZone(zoneID: Self.fenceZoneID)
        let results = try await operationsDatabase.modifyRecordZones(
            saving: [zone],
            deleting: []
        )
        guard let result = results.saveResults[Self.fenceZoneID] else {
            throw CompleteDataDeletionCloudError.missingResult
        }
        _ = try result.get()
    }

    private func fetchFenceRecord() async throws -> CKRecord? {
        do {
            let results = try await operationsDatabase.records(
                for: [Self.fenceRecordID]
            )
            guard let result = results[Self.fenceRecordID] else {
                throw CompleteDataDeletionCloudError.missingResult
            }
            return try result.get()
        } catch {
            if Self.isMissingRecord(error) { return nil }
            throw error
        }
    }

    private func fetchFenceRecordForAvailabilityCheck() async throws -> CKRecord? {
        let operation = Self.makeFenceLookupOperation()
        let accumulator = CompleteDataDeletionFenceFetchAccumulator()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.perRecordResultBlock = { recordID, result in
                    guard recordID == Self.fenceRecordID else { return }
                    accumulator.store(result)
                }
                operation.fetchRecordsResultBlock = { result in
                    continuation.resume(with: accumulator.finish(operationResult: result))
                }
                operationsDatabase.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    private func requiredCurrentFence() async throws -> CompleteDataDeletionFence {
        guard let record = try await fetchFenceRecord() else {
            throw CompleteDataDeletionCloudError.fenceConflict
        }
        return try Self.decodeFence(record)
    }

    private func saveFenceRecord(_ record: CKRecord) async throws -> CKRecord {
        let results = try await operationsDatabase.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )
        guard let result = results.saveResults[record.recordID] else {
            throw CompleteDataDeletionCloudError.missingResult
        }
        return try result.get()
    }

    private static func encode(
        _ fence: CompleteDataDeletionFence,
        into record: CKRecord
    ) {
        record[Field.formatVersion] = fence.formatVersion
        record[Field.generationID] = fence.generationID.uuidString.lowercased()
        record[Field.transactionID] = fence.transactionID.uuidString.lowercased()
        record[Field.sequence] = fence.sequence
        record[Field.state] = fence.state.rawValue
        record[Field.createdAt] = fence.createdAt
        record[Field.updatedAt] = fence.updatedAt
    }

    private static func decodeFence(
        _ record: CKRecord
    ) throws -> CompleteDataDeletionFence {
        guard record.recordID == fenceRecordID,
              let formatVersion: Int = record[Field.formatVersion],
              formatVersion == CompleteDataDeletionFence.formatVersion,
              let generationRaw: String = record[Field.generationID],
              let generationID = UUID(uuidString: generationRaw),
              let transactionRaw: String = record[Field.transactionID],
              let transactionID = UUID(uuidString: transactionRaw),
              let sequence: Int64 = record[Field.sequence],
              sequence >= 0,
              let stateRaw: String = record[Field.state],
              let state = CompleteDataDeletionFence.State(rawValue: stateRaw),
              let createdAt: Date = record[Field.createdAt],
              let updatedAt: Date = record[Field.updatedAt]
        else {
            throw CompleteDataDeletionCloudError.malformedFence
        }
        return CompleteDataDeletionFence(
            generationID: generationID,
            transactionID: transactionID,
            sequence: sequence,
            state: state,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    fileprivate static func isMissingRecord(_ error: any Error) -> Bool {
        guard let cloudError = error as? CKError else { return false }
        return cloudError.code == .unknownItem || cloudError.code == .zoneNotFound
    }

    private static func isServerRecordConflict(_ error: any Error) -> Bool {
        guard let cloudError = error as? CKError else { return false }
        return cloudError.code == .serverRecordChanged
    }
}

/// CKFetchRecordsOperation may deliver the per-record and terminal callbacks on
/// different queues. Keep their handoff synchronized without involving the
/// MainActor or trusting callback ordering beyond CloudKit's terminal contract.
private final class CompleteDataDeletionFenceFetchAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var recordResult: Result<CKRecord, any Error>?

    func store(_ result: Result<CKRecord, any Error>) {
        lock.lock()
        recordResult = result
        lock.unlock()
    }

    func finish(
        operationResult: Result<Void, any Error>
    ) -> Result<CKRecord?, any Error> {
        lock.lock()
        defer { lock.unlock() }

        do {
            try operationResult.get()
            guard let recordResult else {
                return .failure(CompleteDataDeletionCloudError.missingResult)
            }
            do {
                return .success(try recordResult.get())
            } catch {
                if CloudKitCompleteDataDeletionRemoteStore.isMissingRecord(error) {
                    return .success(nil)
                }
                return .failure(error)
            }
        } catch {
            if CloudKitCompleteDataDeletionRemoteStore.isMissingRecord(error) {
                return .success(nil)
            }
            return .failure(error)
        }
    }
}
