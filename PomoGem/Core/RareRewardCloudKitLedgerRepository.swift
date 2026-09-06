import CloudKit
import Foundation

enum RareRewardCloudKitOperationPolicy {
    /// Ledger work is backed by a durable local outbox, so a stalled request can
    /// stop promptly and retry on the next foreground/drain opportunity.
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 30

    @discardableResult
    static func configure<Operation: CKOperation>(
        _ operation: Operation
    ) -> Operation {
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        operation.configuration = configuration
        return operation
    }
}

enum RareRewardCloudKitErrorClassifier {
    static func repositoryError(
        from error: any Error
    ) -> RareRewardLedgerRepositoryError {
        if let repositoryError = error as? RareRewardLedgerRepositoryError {
            return repositoryError
        }
        if isConflict(error) {
            return .conflict
        }
        if isUnknownItem(error) {
            return .notFound
        }
        return .transport(actionableDescription(for: error))
    }

    static func translated(_ error: any Error) -> any Error {
        if error is CancellationError || isCancellation(error) {
            return CancellationError()
        }
        return repositoryError(from: error)
    }

    static func isConflict(_ error: any Error) -> Bool {
        if let itemError = error as? RareRewardCloudKitPerItemError {
            return itemError.errors.values.contains { isConflict($0) }
        }
        guard let cloudError = error as? CKError else { return false }
        if cloudError.code == .serverRecordChanged { return true }
        // In an atomic save, CloudKit reports batchRequestFailed for the items
        // that merely accompanied the actual failure. It is not itself proof of
        // compare-and-swap contention.
        if cloudError.code == .batchRequestFailed { return false }
        guard cloudError.code == .partialFailure,
              let partial = cloudError.partialErrorsByItemID else {
            return false
        }
        return partial.values.contains { isConflict($0) }
    }

    static func isUnknownItem(
        _ error: any Error,
        recordID: CKRecord.ID? = nil
    ) -> Bool {
        if let itemError = error as? RareRewardCloudKitPerItemError {
            if let recordID,
               let recordError = itemError.errors[AnyHashable(recordID)] {
                return isUnknownItem(recordError)
            }
            return allMeaningfulErrors(
                in: itemError.errors.values,
                satisfy: { isUnknownItem($0) }
            )
        }
        guard let cloudError = error as? CKError else { return false }
        if cloudError.code == .unknownItem || cloudError.code == .zoneNotFound {
            return true
        }
        guard cloudError.code == .partialFailure,
              let partial = cloudError.partialErrorsByItemID else {
            return false
        }
        if let recordID, let recordError = partial[AnyHashable(recordID)] {
            return isUnknownItem(recordError)
        }
        return allMeaningfulErrors(
            in: partial.values,
            satisfy: { isUnknownItem($0) }
        )
    }

    static func isZoneNotFound(_ error: any Error) -> Bool {
        if let itemError = error as? RareRewardCloudKitPerItemError {
            return itemError.errors.values.contains { isZoneNotFound($0) }
        }
        guard let cloudError = error as? CKError else { return false }
        if cloudError.code == .zoneNotFound { return true }
        guard cloudError.code == .partialFailure,
              let partial = cloudError.partialErrorsByItemID else {
            return false
        }
        return partial.values.contains { isZoneNotFound($0) }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if let itemError = error as? RareRewardCloudKitPerItemError {
            return itemError.errors.values.contains { isCancellation($0) }
        }
        guard let cloudError = error as? CKError else { return false }
        if cloudError.code == .operationCancelled { return true }
        guard cloudError.code == .partialFailure,
              let partial = cloudError.partialErrorsByItemID else {
            return false
        }
        return partial.values.contains { isCancellation($0) }
    }

    private static func allMeaningfulErrors(
        in errors: some Sequence<any Error>,
        satisfy predicate: (any Error) -> Bool
    ) -> Bool {
        let meaningful = errors.filter { error in
            (error as? CKError)?.code != .batchRequestFailed
        }
        return !meaningful.isEmpty && meaningful.allSatisfy(predicate)
    }

    private static func actionableDescription(for error: any Error) -> String {
        guard let itemError = error as? RareRewardCloudKitPerItemError else {
            return error.localizedDescription
        }
        let meaningful = itemError.errors.values.filter {
            ($0 as? CKError)?.code != .batchRequestFailed
        }
        return meaningful.first?.localizedDescription
            ?? itemError.localizedDescription
    }
}

/// Production persistence for `RareRewardLedgerCoordinator`.
///
/// One private custom zone contains both the epoch and its deterministic
/// session receipts. The epoch record fetched for a transition keeps its
/// CloudKit change tag, and `ifServerRecordUnchanged` rejects a stale writer.
/// `isAtomic` makes the epoch advance and receipt creation one indivisible
/// operation inside the zone.
actor CloudKitRareRewardLedgerRepository: RareRewardLedgerRepository {
    static let zoneName = "PomoGemRareRewardLedgerV2"

    private enum RecordType {
        static let epoch = "RareRewardEpochV2"
        static let receipt = "RareRewardReceiptV2"
    }

    private enum Field {
        static let schemaVersion = "schemaVersion"
        static let epochID = "epochID"
        static let migrationFingerprint = "migrationFingerprint"
        static let totalCreditedGrams = "totalCreditedGrams"
        static let creditRemainderGrams = "creditRemainderGrams"
        static let nextOrdinal = "nextOrdinal"
        static let sinceLastGold = "sinceLastGold"
        static let seed = "seed"
        static let revision = "revision"

        static let sessionID = "sessionID"
        static let submissionFingerprint = "submissionFingerprint"
        static let participated = "participated"
        static let nonparticipationReason = "nonparticipationReason"
        static let acceptedGrams = "acceptedGrams"
        static let firstOrdinal = "firstOrdinal"
        static let ordinalCount = "ordinalCount"
        static let outcomes = "outcomes"
        static let revisionBefore = "revisionBefore"
        static let revisionAfter = "revisionAfter"
        static let totalCreditedGramsAfter = "totalCreditedGramsAfter"
        static let creditRemainderGramsAfter = "creditRemainderGramsAfter"
        static let sinceLastGoldAfter = "sinceLastGoldAfter"
    }

    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private var hasEnsuredZone = false

    init(
        container: CKContainer,
        zoneName: String = CloudKitRareRewardLedgerRepository.zoneName
    ) {
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(
            zoneName: zoneName,
            ownerName: CKCurrentUserDefaultName
        )
    }

    init() {
        let container = CKContainer(
            identifier: CloudSyncConfiguration.operationsContainerIdentifier
        )
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(
            zoneName: Self.zoneName,
            ownerName: CKCurrentUserDefaultName
        )
    }

    func fetchEpoch(
        epochID: UUID
    ) async throws -> RareRewardLedgerEpochSnapshot? {
        try await ensureZone()
        guard let record = try await fetchRecord(
            recordID: epochRecordID(epochID)
        ) else { return nil }
        return try epochSnapshot(from: record)
    }

    func fetchReceipt(
        epochID: UUID,
        sessionID: UUID
    ) async throws -> RareRewardLedgerReceipt? {
        try await ensureZone()
        guard let record = try await fetchRecord(
            recordID: receiptRecordID(epochID: epochID, sessionID: sessionID)
        ) else { return nil }
        return try receipt(from: record)
    }

    func createEpoch(
        _ epoch: RareRewardLedgerEpoch
    ) async throws -> RareRewardLedgerEpochSnapshot {
        try await ensureZone()
        _ = try epoch.validated()
        let record = CKRecord(
            recordType: RecordType.epoch,
            recordID: epochRecordID(epoch.epochID)
        )
        write(epoch, to: record)
        do {
            let saved = try await modify(recordsToSave: [record])
            guard let savedRecord = saved.first else {
                throw RareRewardLedgerRepositoryError.corruptRecord
            }
            return try epochSnapshot(from: savedRecord)
        } catch {
            throw Self.translated(error)
        }
    }

    func commit(
        expected: RareRewardLedgerEpochSnapshot,
        updatedEpoch: RareRewardLedgerEpoch,
        receipt: RareRewardLedgerReceipt
    ) async throws -> RareRewardLedgerEpochSnapshot {
        try await ensureZone()
        _ = try updatedEpoch.validated()
        _ = try receipt.validated()
        guard expected.epoch.epochID == updatedEpoch.epochID,
              expected.epoch.epochID == receipt.epochID,
              updatedEpoch.revision == expected.epoch.revision + 1,
              receipt.revisionBefore == expected.epoch.revision,
              receipt.revisionAfter == updatedEpoch.revision else {
            throw RareRewardLedgerRepositoryError.corruptRecord
        }

        // Refetch immediately before mutation so the operation carries a real
        // CloudKit system field/change tag. A token mismatch means another
        // device won since the coordinator computed its transition.
        guard let epochRecord = try await fetchRecord(
            recordID: epochRecordID(expected.epoch.epochID)
        ) else {
            throw RareRewardLedgerRepositoryError.conflict
        }
        let current = try epochSnapshot(from: epochRecord)
        guard current == expected else {
            throw RareRewardLedgerRepositoryError.conflict
        }
        write(updatedEpoch, to: epochRecord)

        let receiptRecord = CKRecord(
            recordType: RecordType.receipt,
            recordID: receiptRecordID(
                epochID: receipt.epochID,
                sessionID: receipt.sessionID
            )
        )
        write(receipt, to: receiptRecord)

        do {
            let saved = try await modify(
                recordsToSave: [epochRecord, receiptRecord]
            )
            guard let savedEpoch = saved.first(where: {
                $0.recordID == epochRecord.recordID
            }) else {
                throw RareRewardLedgerRepositoryError.corruptRecord
            }
            return try epochSnapshot(from: savedEpoch)
        } catch {
            throw Self.translated(error)
        }
    }

    private func ensureZone() async throws {
        guard !hasEnsuredZone else { return }
        if try await fetchZone() != nil {
            hasEnsuredZone = true
            return
        }

        let zone = CKRecordZone(zoneID: zoneID)
        do {
            try await saveZone(zone)
            hasEnsuredZone = true
        } catch {
            if error is CancellationError { throw error }
            // A second device may create the deterministic zone between fetch
            // and save. Refetch instead of treating that race as data loss.
            if try await fetchZone() != nil {
                hasEnsuredZone = true
                return
            }
            throw Self.translated(error)
        }
    }

    private func epochRecordID(_ epochID: UUID) -> CKRecord.ID {
        CKRecord.ID(
            recordName: RareRewardLedgerV2.epochRecordName(epochID),
            zoneID: zoneID
        )
    }

    private func receiptRecordID(
        epochID: UUID,
        sessionID: UUID
    ) -> CKRecord.ID {
        CKRecord.ID(
            recordName: RareRewardLedgerV2.receiptRecordName(
                epochID: epochID,
                sessionID: sessionID
            ),
            zoneID: zoneID
        )
    }

    private func epochSnapshot(
        from record: CKRecord
    ) throws -> RareRewardLedgerEpochSnapshot {
        guard record.recordType == RecordType.epoch,
              integer(record, Field.schemaVersion)
                == Int64(RareRewardLedgerV2.ruleVersion),
              let epochID = uuid(record, Field.epochID),
              let migrationFingerprint = string(
                record,
                Field.migrationFingerprint
              ),
              let total = exactInt(record, Field.totalCreditedGrams),
              let remainder = exactInt(record, Field.creditRemainderGrams),
              let nextOrdinal = integer(record, Field.nextOrdinal),
              let misses = exactInt(record, Field.sinceLastGold),
              let seedText = string(record, Field.seed),
              let seed = UInt64(seedText),
              let revision = integer(record, Field.revision),
              let changeTag = record.recordChangeTag else {
            throw RareRewardLedgerRepositoryError.corruptRecord
        }
        let epoch = RareRewardLedgerEpoch(
            epochID: epochID,
            migrationFingerprint: migrationFingerprint,
            totalCreditedGrams: total,
            creditRemainderGrams: remainder,
            nextOrdinal: nextOrdinal,
            sinceLastGold: misses,
            seed: seed,
            revision: revision
        )
        return RareRewardLedgerEpochSnapshot(
            epoch: try epoch.validated(),
            changeToken: changeTag
        )
    }

    private func receipt(
        from record: CKRecord
    ) throws -> RareRewardLedgerReceipt {
        guard record.recordType == RecordType.receipt,
              integer(record, Field.schemaVersion)
                == Int64(RareRewardLedgerV2.ruleVersion),
              let epochID = uuid(record, Field.epochID),
              let sessionID = uuid(record, Field.sessionID),
              let submissionFingerprint = string(
                record,
                Field.submissionFingerprint
              ),
              let participatedNumber = record[Field.participated] as? NSNumber,
              let acceptedGrams = exactInt(record, Field.acceptedGrams),
              let ordinalCount = exactInt(record, Field.ordinalCount),
              let outcomesRaw = string(record, Field.outcomes),
              let outcomes = RareRewardOutcomeCodec.decode(outcomesRaw),
              let revisionBefore = integer(record, Field.revisionBefore),
              let revisionAfter = integer(record, Field.revisionAfter),
              let totalAfter = exactInt(
                record,
                Field.totalCreditedGramsAfter
              ),
              let remainderAfter = exactInt(
                record,
                Field.creditRemainderGramsAfter
              ),
              let missesAfter = exactInt(record, Field.sinceLastGoldAfter)
        else {
            throw RareRewardLedgerRepositoryError.corruptRecord
        }
        let reason: RareRewardLedgerNonparticipationReason?
        if let rawReason = string(record, Field.nonparticipationReason) {
            guard let decoded = RareRewardLedgerNonparticipationReason(
                rawValue: rawReason
            ) else {
                throw RareRewardLedgerRepositoryError.corruptRecord
            }
            reason = decoded
        } else {
            reason = nil
        }
        let firstOrdinal = integer(record, Field.firstOrdinal)
        let value = RareRewardLedgerReceipt(
            epochID: epochID,
            sessionID: sessionID,
            submissionFingerprint: submissionFingerprint,
            participated: participatedNumber.boolValue,
            nonparticipationReason: reason,
            acceptedGrams: acceptedGrams,
            firstOrdinal: firstOrdinal,
            ordinalCount: ordinalCount,
            outcomes: outcomes,
            revisionBefore: revisionBefore,
            revisionAfter: revisionAfter,
            totalCreditedGramsAfter: totalAfter,
            creditRemainderGramsAfter: remainderAfter,
            sinceLastGoldAfter: missesAfter
        )
        do {
            return try value.validated()
        } catch {
            throw RareRewardLedgerRepositoryError.corruptRecord
        }
    }

    private func write(
        _ epoch: RareRewardLedgerEpoch,
        to record: CKRecord
    ) {
        record[Field.schemaVersion] = RareRewardLedgerV2.ruleVersion as NSNumber
        record[Field.epochID] = epoch.epochID.uuidString.lowercased() as NSString
        record[Field.migrationFingerprint] = epoch.migrationFingerprint as NSString
        record[Field.totalCreditedGrams] = epoch.totalCreditedGrams as NSNumber
        record[Field.creditRemainderGrams] = epoch.creditRemainderGrams as NSNumber
        record[Field.nextOrdinal] = epoch.nextOrdinal as NSNumber
        record[Field.sinceLastGold] = epoch.sinceLastGold as NSNumber
        record[Field.seed] = String(epoch.seed) as NSString
        record[Field.revision] = epoch.revision as NSNumber
    }

    private func write(
        _ receipt: RareRewardLedgerReceipt,
        to record: CKRecord
    ) {
        record[Field.schemaVersion] = RareRewardLedgerV2.ruleVersion as NSNumber
        record[Field.epochID] = receipt.epochID.uuidString.lowercased() as NSString
        record[Field.sessionID] = receipt.sessionID.uuidString.lowercased() as NSString
        record[Field.submissionFingerprint] = receipt.submissionFingerprint as NSString
        record[Field.participated] = receipt.participated as NSNumber
        record[Field.nonparticipationReason] = receipt
            .nonparticipationReason?.rawValue as NSString?
        record[Field.acceptedGrams] = receipt.acceptedGrams as NSNumber
        if let firstOrdinal = receipt.firstOrdinal {
            record[Field.firstOrdinal] = NSNumber(value: firstOrdinal)
        } else {
            record[Field.firstOrdinal] = nil
        }
        record[Field.ordinalCount] = receipt.ordinalCount as NSNumber
        record[Field.outcomes] = RareRewardOutcomeCodec
            .encode(receipt.outcomes) as NSString
        record[Field.revisionBefore] = receipt.revisionBefore as NSNumber
        record[Field.revisionAfter] = receipt.revisionAfter as NSNumber
        record[Field.totalCreditedGramsAfter] = receipt
            .totalCreditedGramsAfter as NSNumber
        record[Field.creditRemainderGramsAfter] = receipt
            .creditRemainderGramsAfter as NSNumber
        record[Field.sinceLastGoldAfter] = receipt
            .sinceLastGoldAfter as NSNumber
    }

    private func fetchZone() async throws -> CKRecordZone? {
        let expectedZoneID = zoneID
        let operation = RareRewardCloudKitOperationPolicy.configure(
            CKFetchRecordZonesOperation(recordZoneIDs: [expectedZoneID])
        )
        let accumulator = RareRewardCloudKitResultAccumulator<
            CKRecordZone.ID,
            CKRecordZone
        >()

        do {
            let zones = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    operation.perRecordZoneResultBlock = { zoneID, result in
                        accumulator.store(result, for: zoneID)
                    }
                    operation.fetchRecordZonesResultBlock = { result in
                        continuation.resume(with: accumulator.finish(
                            expectedKeys: [expectedZoneID],
                            operationResult: result
                        ))
                    }
                    database.add(operation)
                }
            } onCancel: {
                operation.cancel()
            }
            return zones[expectedZoneID]
        } catch {
            if Self.isUnknownItem(error) { return nil }
            throw Self.translated(error)
        }
    }

    private func saveZone(_ zone: CKRecordZone) async throws {
        let expectedZoneID = zone.zoneID
        let operation = RareRewardCloudKitOperationPolicy.configure(
            CKModifyRecordZonesOperation(
                recordZonesToSave: [zone],
                recordZoneIDsToDelete: nil
            )
        )
        let accumulator = RareRewardCloudKitResultAccumulator<
            CKRecordZone.ID,
            CKRecordZone
        >()

        do {
            _ = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    operation.perRecordZoneSaveBlock = { zoneID, result in
                        accumulator.store(result, for: zoneID)
                    }
                    operation.modifyRecordZonesResultBlock = { result in
                        continuation.resume(with: accumulator.finish(
                            expectedKeys: [expectedZoneID],
                            operationResult: result
                        ))
                    }
                    database.add(operation)
                }
            } onCancel: {
                operation.cancel()
            }
        } catch {
            throw Self.translated(error)
        }
    }

    private func fetchRecord(recordID: CKRecord.ID) async throws -> CKRecord? {
        do {
            return try await fetchRecordOnce(recordID: recordID)
        } catch {
            guard Self.isZoneNotFound(error) else {
                throw Self.translated(error)
            }
            // A key reset or unexpected zone loss invalidates the process-wide
            // positive cache. Recreate the zone before the next commit.
            hasEnsuredZone = false
            try await ensureZone()
            do {
                return try await fetchRecordOnce(recordID: recordID)
            } catch {
                throw Self.translated(error)
            }
        }
    }

    private func fetchRecordOnce(recordID: CKRecord.ID) async throws -> CKRecord? {
        let operation = RareRewardCloudKitOperationPolicy.configure(
            CKFetchRecordsOperation(recordIDs: [recordID])
        )
        let accumulator = RareRewardCloudKitResultAccumulator<
            CKRecord.ID,
            CKRecord
        >()

        do {
            let records = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    operation.perRecordResultBlock = { recordID, result in
                        accumulator.store(result, for: recordID)
                    }
                    operation.fetchRecordsResultBlock = { result in
                        continuation.resume(with: accumulator.finish(
                            expectedKeys: [recordID],
                            operationResult: result
                        ))
                    }
                    database.add(operation)
                }
            } onCancel: {
                operation.cancel()
            }
            return records[recordID]
        } catch {
            if Self.isZoneNotFound(error) { throw error }
            if Self.isUnknownItem(error, recordID: recordID) { return nil }
            throw Self.translated(error)
        }
    }

    private func modify(recordsToSave: [CKRecord]) async throws -> [CKRecord] {
        do {
            return try await modifyOnce(recordsToSave: recordsToSave)
        } catch {
            guard Self.isZoneNotFound(error) else {
                throw Self.translated(error)
            }
            hasEnsuredZone = false
            try await ensureZone()
            do {
                return try await modifyOnce(recordsToSave: recordsToSave)
            } catch {
                throw Self.translated(error)
            }
        }
    }

    private func modifyOnce(recordsToSave: [CKRecord]) async throws -> [CKRecord] {
        let expectedRecordIDs = recordsToSave.map(\.recordID)
        let operation = RareRewardCloudKitOperationPolicy.configure(
            CKModifyRecordsOperation(
                recordsToSave: recordsToSave,
                recordIDsToDelete: nil
            )
        )
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = true
        let accumulator = RareRewardCloudKitResultAccumulator<
            CKRecord.ID,
            CKRecord
        >()

        let savedByID = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.perRecordSaveBlock = { recordID, result in
                    accumulator.store(result, for: recordID)
                }
                operation.modifyRecordsResultBlock = { result in
                    continuation.resume(with: accumulator.finish(
                        expectedKeys: expectedRecordIDs,
                        operationResult: result
                    ))
                }
                database.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
        return expectedRecordIDs.compactMap { savedByID[$0] }
    }

    private static func isUnknownItem(
        _ error: Error,
        recordID: CKRecord.ID? = nil
    ) -> Bool {
        RareRewardCloudKitErrorClassifier.isUnknownItem(
            error,
            recordID: recordID
        )
    }

    private static func isZoneNotFound(_ error: Error) -> Bool {
        RareRewardCloudKitErrorClassifier.isZoneNotFound(error)
    }

    private static func translated(_ error: Error) -> any Error {
        RareRewardCloudKitErrorClassifier.translated(error)
    }

    private func string(_ record: CKRecord, _ key: String) -> String? {
        record[key] as? String
    }

    private func integer(_ record: CKRecord, _ key: String) -> Int64? {
        (record[key] as? NSNumber)?.int64Value
    }

    private func exactInt(_ record: CKRecord, _ key: String) -> Int? {
        guard let value = integer(record, key),
              value >= Int64(Int.min),
              value <= Int64(Int.max) else { return nil }
        return Int(value)
    }

    private func uuid(_ record: CKRecord, _ key: String) -> UUID? {
        string(record, key).flatMap(UUID.init(uuidString:))
    }
}

private enum RareRewardCloudKitOperationError: LocalizedError {
    case missingResult

    var errorDescription: String? {
        "CloudKit did not return a result for every requested item."
    }
}

private struct RareRewardCloudKitPerItemError: LocalizedError, @unchecked Sendable {
    let errors: [AnyHashable: any Error]

    var errorDescription: String? {
        "CloudKit rejected \(errors.count) item(s)."
    }
}

private final class RareRewardCloudKitResultAccumulator<
    Key: Hashable,
    Value
>: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Key: Result<Value, any Error>] = [:]

    func store(_ result: Result<Value, any Error>, for key: Key) {
        lock.lock()
        results[key] = result
        lock.unlock()
    }

    func finish(
        expectedKeys: [Key],
        operationResult: Result<Void, any Error>
    ) -> Result<[Key: Value], any Error> {
        do {
            try operationResult.get()
        } catch {
            return .failure(error)
        }

        lock.lock()
        let snapshot = results
        lock.unlock()

        var values: [Key: Value] = [:]
        var errors: [AnyHashable: any Error] = [:]
        for key in expectedKeys {
            guard let result = snapshot[key] else {
                errors[AnyHashable(key)] =
                    RareRewardCloudKitOperationError.missingResult
                continue
            }
            switch result {
            case let .success(value):
                values[key] = value
            case let .failure(error):
                errors[AnyHashable(key)] = error
            }
        }
        if !errors.isEmpty {
            return .failure(RareRewardCloudKitPerItemError(errors: errors))
        }
        return .success(values)
    }
}
