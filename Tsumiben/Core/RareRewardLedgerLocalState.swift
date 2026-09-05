import Foundation
import SwiftData

/// Local outbox row saved in the same SwiftData transaction as StudySession.
/// Until this row is committed in the private custom zone, the corresponding
/// session carries no finalized rare outcome and can safely be retried after a
/// process kill or offline interval.
@Model
final class RareRewardPendingCommit {
    var id: UUID = UUID()
    var dataEpochID: UUID?
    var epochID: UUID = RareRewardLedgerV2.legacyEpochID
    var sessionID: UUID = UUID()
    var sourceRawValue: String = SessionSource.timerDemoted.rawValue
    var completedSeconds: Int = 0
    var completedGrams: Int = 0
    var modeRawValue: String = RareRewardMode.off.rawValue
    var migrationFingerprint: String = ""
    var migrationTotalCreditedGrams: Int = 0
    var migrationSinceLastGold: Int = 0
    var migrationSeedRawValue: String = "0"
    var createdAt: Date = Date(timeIntervalSince1970: 0)

    init(
        id: UUID = UUID(),
        dataEpochID: UUID?,
        submission: RareRewardLedgerSubmission,
        migration: RareRewardLedgerMigration,
        createdAt: Date = .now
    ) {
        self.id = id
        self.dataEpochID = dataEpochID
        epochID = submission.epochID
        sessionID = submission.sessionID
        sourceRawValue = submission.source.rawValue
        completedSeconds = submission.completedSeconds
        completedGrams = submission.completedGrams
        modeRawValue = submission.mode.rawValue
        migrationFingerprint = migration.fingerprint
        migrationTotalCreditedGrams = migration.totalCreditedGrams
        migrationSinceLastGold = migration.sinceLastGold
        migrationSeedRawValue = String(migration.seed)
        self.createdAt = createdAt
    }

    func payload() throws -> (
        submission: RareRewardLedgerSubmission,
        migration: RareRewardLedgerMigration
    ) {
        guard epochID == RareRewardLedgerV2.normalizedEpochID(dataEpochID),
              let source = SessionSource(rawValue: sourceRawValue),
              let mode = RareRewardMode(rawValue: modeRawValue),
              let seed = UInt64(migrationSeedRawValue),
              !migrationFingerprint.isEmpty else {
            throw RareRewardLedgerLocalStateError.corruptPendingCommit
        }
        return (
            RareRewardLedgerSubmission(
                epochID: epochID,
                sessionID: sessionID,
                source: source,
                completedSeconds: completedSeconds,
                completedGrams: completedGrams,
                mode: mode
            ),
            RareRewardLedgerMigration(
                epochID: epochID,
                fingerprint: migrationFingerprint,
                totalCreditedGrams: migrationTotalCreditedGrams,
                sinceLastGold: migrationSinceLastGold,
                seed: seed
            )
        )
    }
}

/// A synchronized local mirror of the server epoch. It retains the immutable
/// migration baseline so later completions never derive a new fingerprint from
/// the already-advanced legacy GachaState cache.
@Model
final class RareRewardLedgerCursor {
    var id: UUID = UUID()
    var dataEpochID: UUID?
    var epochID: UUID = RareRewardLedgerV2.legacyEpochID
    var migrationFingerprint: String = ""
    var migrationTotalCreditedGrams: Int = 0
    var migrationSinceLastGold: Int = 0
    var seedRawValue: String = "0"
    var totalCreditedGrams: Int = 0
    var creditRemainderGrams: Int = 0
    var nextOrdinal: Int64 = 0
    var sinceLastGold: Int = 0
    var revision: Int64 = 0
    var updatedAt: Date = Date(timeIntervalSince1970: 0)

    init(
        id: UUID = UUID(),
        dataEpochID: UUID?,
        migration: RareRewardLedgerMigration,
        receipt: RareRewardLedgerReceipt,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.dataEpochID = dataEpochID
        epochID = migration.epochID
        migrationFingerprint = migration.fingerprint
        migrationTotalCreditedGrams = migration.totalCreditedGrams
        migrationSinceLastGold = migration.sinceLastGold
        seedRawValue = String(migration.seed)
        apply(receipt, updatedAt: updatedAt)
    }

    func migration() throws -> RareRewardLedgerMigration {
        guard epochID == RareRewardLedgerV2.normalizedEpochID(dataEpochID),
              !migrationFingerprint.isEmpty,
              let seed = UInt64(seedRawValue) else {
            throw RareRewardLedgerLocalStateError.corruptCursor
        }
        return RareRewardLedgerMigration(
            epochID: epochID,
            fingerprint: migrationFingerprint,
            totalCreditedGrams: migrationTotalCreditedGrams,
            sinceLastGold: migrationSinceLastGold,
            seed: seed
        )
    }

    func epochMirror() throws -> RareRewardLedgerEpoch {
        _ = try migration()
        return try RareRewardLedgerEpoch(
            epochID: epochID,
            migrationFingerprint: migrationFingerprint,
            totalCreditedGrams: totalCreditedGrams,
            creditRemainderGrams: creditRemainderGrams,
            nextOrdinal: nextOrdinal,
            sinceLastGold: sinceLastGold,
            seed: UInt64(seedRawValue) ?? 0,
            revision: revision
        ).validated()
    }

    func apply(
        _ receipt: RareRewardLedgerReceipt,
        updatedAt: Date = .now
    ) {
        guard receipt.epochID == epochID,
              receipt.revisionAfter >= revision else { return }
        totalCreditedGrams = receipt.totalCreditedGramsAfter
        creditRemainderGrams = receipt.creditRemainderGramsAfter
        nextOrdinal = Int64(
            receipt.totalCreditedGramsAfter / Constants.Gacha.creditGrams
        )
        sinceLastGold = receipt.sinceLastGoldAfter
        revision = receipt.revisionAfter
        self.updatedAt = updatedAt
    }
}

enum RareRewardLedgerLocalStateError: Error, LocalizedError, Equatable {
    case corruptPendingCommit
    case corruptCursor
    case missingPendingCommit
    case missingSynchronizedCursor
    case conflictingCursors

    var errorDescription: String? {
        switch self {
        case .corruptPendingCommit:
            "保留中のレア粒台帳を検証できませんでした。記録は保持されています。"
        case .corruptCursor:
            "同期済みのレア粒台帳を検証できませんでした。記録は保持されています。"
        case .missingPendingCommit:
            "完走記録よりレア粒の再送情報が遅れているため、iCloud同期後に再試行してください。"
        case .missingSynchronizedCursor:
            "レア粒の完走結果より台帳情報が遅れているため、iCloud同期後に再試行してください。"
        case .conflictingCursors:
            "同期されたレア粒台帳の移行情報が一致しないため、抽選を停止しました。"
        }
    }
}

enum RareRewardPendingCommitDrainOutcome: Equatable, Sendable {
    case none
    case waitingForSynchronizedRows
    case blockedByReset
    case discardedStale
    case finalized(sessionID: UUID, kind: PebbleKind)
}

/// Drains one logical outbox session at a time. Keeping the page to one session
/// bounds every SwiftData read and every foreground CloudKit transaction while
/// still allowing RootView to yield between pages.
@MainActor
struct RareRewardPendingCommitDrainer {
    static let maximumDuplicateRowsPerLogicalSession = 64
    static let maximumCursorRowsPerEpoch = 64
    static let maximumGachaRowsPerEpoch = 64

    let coordinator: RareRewardLedgerCoordinator

    func drainNext(
        context: ModelContext
    ) async throws -> RareRewardPendingCommitDrainOutcome {
        var firstDescriptor = FetchDescriptor<RareRewardPendingCommit>(sortBy: [
            SortDescriptor(\.createdAt),
            SortDescriptor(\.sessionID),
            SortDescriptor(\.id)
        ])
        firstDescriptor.fetchLimit = 1
        guard let first = try context.fetch(firstDescriptor).first else {
            return .none
        }

        let initialMarker = try latestResetMarker(context: context)
        switch try activityState(
            of: first.dataEpochID,
            currentMarker: initialMarker,
            context: context
        ) {
        case .awaitingMarker:
            return .blockedByReset
        case .stale:
            let staleRows = try pendingRows(
                epochID: first.epochID,
                sessionID: first.sessionID,
                context: context
            )
            staleRows.forEach(context.delete)
            try context.save()
            return .discardedStale
        case .current:
            break
        }

        let pending = try pendingRows(
            epochID: first.epochID,
            sessionID: first.sessionID,
            context: context
        )
        let payload = try consistentPayload(from: pending)
        guard payload.submission.epochID
                == RareRewardLedgerV2.normalizedEpochID(first.dataEpochID) else {
            throw RareRewardLedgerError.submissionEpochMismatch
        }

        let sessions = try sessionRows(
            sessionID: payload.submission.sessionID,
            context: context
        )
        guard !sessions.isEmpty else {
            return .waitingForSynchronizedRows
        }
        try validate(
            sessions: sessions,
            submission: payload.submission,
            dataEpochID: first.dataEpochID,
            currentMarker: initialMarker,
            context: context
        )
        _ = try canonicalCursor(
            epochID: payload.submission.epochID,
            expectedMigration: payload.migration,
            context: context
        )

        let receipt = try await coordinator.commit(
            payload.submission,
            migration: payload.migration
        )
        try Task.checkCancellation()
        guard receipt.epochID == payload.submission.epochID,
              receipt.sessionID == payload.submission.sessionID,
              receipt.submissionFingerprint == payload.submission.fingerprint else {
            throw RareRewardLedgerRepositoryError.corruptRecord
        }

        // The reset generation and local rows may change while CloudKit is
        // suspended. Refetch every mutable input before exposing the receipt.
        let currentMarker = try latestResetMarker(context: context)
        guard try activityState(
            of: first.dataEpochID,
            currentMarker: currentMarker,
            context: context
        ) == .current else {
            return .blockedByReset
        }
        let freshSessions = try sessionRows(
            sessionID: payload.submission.sessionID,
            context: context
        )
        guard !freshSessions.isEmpty else {
            return .waitingForSynchronizedRows
        }
        try validate(
            sessions: freshSessions,
            submission: payload.submission,
            dataEpochID: first.dataEpochID,
            currentMarker: currentMarker,
            context: context
        )
        let freshPending = try pendingRows(
            epochID: payload.submission.epochID,
            sessionID: payload.submission.sessionID,
            context: context
        )
        _ = try consistentPayload(from: freshPending)

        guard let mutationTarget = StudySessionSyncPolicy.canonicalSession(
            from: freshSessions
        ) else {
            throw RareRewardLedgerError.duplicateSessionPayloadMismatch
        }
        // Retain foreign physical copies as concurrent evidence. The optional
        // ledger is release-disabled, but its dormant finalizer must not encode
        // a source-row fan-out contract that would be unsafe to re-enable.
        mutationTarget.pebbleKind = receipt.representativeKind
        mutationTarget.rareRewardRuleVersion = RareRewardLedgerV2.ruleVersion
        mutationTarget.rareRewardParticipated = receipt.participated
        mutationTarget.rareRewardCreditedGrams = receipt.acceptedGrams
        mutationTarget.rareRewardOutcomesRawValue = RareRewardOutcomeCodec.encode(
            receipt.outcomes
        )

        let cursor: RareRewardLedgerCursor
        if let existing = try canonicalCursor(
            epochID: payload.submission.epochID,
            expectedMigration: payload.migration,
            context: context
        ) {
            try validateSameRevision(existing, receipt: receipt)
            cursor = existing
            cursor.apply(receipt, updatedAt: .now)
        } else {
            cursor = RareRewardLedgerCursor(
                id: payload.migration.epochID,
                dataEpochID: first.dataEpochID,
                migration: payload.migration,
                receipt: receipt
            )
            context.insert(cursor)
        }

        freshPending.forEach(context.delete)
        // The synchronized session, cursor, and outbox share one store and one
        // atomic save. Never mix the disposable local GachaState cache into
        // that boundary.
        try context.save()

        do {
            try replaceGachaCache(
                with: cursor,
                dataEpochID: first.dataEpochID,
                currentMarker: currentMarker,
                context: context
            )
            if context.hasChanges { try context.save() }
        } catch {
            // Cursor/session are already durable and authoritative. Rolling
            // back this local-only phase lets maintenance rebuild the cache.
            context.rollback()
        }
        return .finalized(
            sessionID: payload.submission.sessionID,
            kind: receipt.representativeKind
        )
    }

    private func pendingRows(
        epochID: UUID,
        sessionID: UUID,
        context: ModelContext
    ) throws -> [RareRewardPendingCommit] {
        let descriptor = FetchDescriptor<RareRewardPendingCommit>(
            predicate: #Predicate {
                $0.epochID == epochID && $0.sessionID == sessionID
            },
            sortBy: [
                SortDescriptor(\.createdAt),
                SortDescriptor(\.id)
            ]
        )
        guard try context.fetchCount(descriptor)
                <= Self.maximumDuplicateRowsPerLogicalSession else {
            throw RareRewardLedgerError.duplicateSessionPayloadMismatch
        }
        var bounded = descriptor
        bounded.fetchLimit = Self.maximumDuplicateRowsPerLogicalSession
        return try context.fetch(bounded)
    }

    private func consistentPayload(
        from rows: [RareRewardPendingCommit]
    ) throws -> (
        submission: RareRewardLedgerSubmission,
        migration: RareRewardLedgerMigration
    ) {
        guard let first = rows.first else {
            throw RareRewardLedgerLocalStateError.missingPendingCommit
        }
        let expected = try first.payload()
        for row in rows.dropFirst() {
            let candidate = try row.payload()
            guard candidate.submission == expected.submission,
                  candidate.migration == expected.migration else {
                throw RareRewardLedgerError.duplicateSessionPayloadMismatch
            }
        }
        return expected
    }

    private func sessionRows(
        sessionID: UUID,
        context: ModelContext
    ) throws -> [StudySession] {
        let descriptor = FetchDescriptor<StudySession>(
            predicate: #Predicate { $0.id == sessionID },
            sortBy: [SortDescriptor(\.endAt), SortDescriptor(\.startAt)]
        )
        guard try context.fetchCount(descriptor)
                <= Self.maximumDuplicateRowsPerLogicalSession else {
            throw RareRewardLedgerError.duplicateSessionPayloadMismatch
        }
        var bounded = descriptor
        bounded.fetchLimit = Self.maximumDuplicateRowsPerLogicalSession
        return try context.fetch(bounded)
    }

    private func validate(
        sessions: [StudySession],
        submission: RareRewardLedgerSubmission,
        dataEpochID: UUID?,
        currentMarker: ActivityResetSnapshot?,
        context: ModelContext
    ) throws {
        guard try activityState(
            of: dataEpochID,
            currentMarker: currentMarker,
            context: context
        ) == .current,
              sessions.allSatisfy({ session in
                  StudySessionIntegrityPolicy.isSupported(session)
                      && RareRewardLedgerV2.normalizedEpochID(session.dataEpochID)
                      == submission.epochID
                      && session.source == submission.source
                      && max(0, session.seconds) == submission.completedSeconds
                      && max(0, session.grams) == submission.completedGrams
                      && session.rareRewardRuleVersion
                        == RareRewardLedgerV2.ruleVersion
              }) else {
            throw RareRewardLedgerError.duplicateSessionPayloadMismatch
        }
    }

    private func canonicalCursor(
        epochID: UUID,
        expectedMigration: RareRewardLedgerMigration,
        context: ModelContext
    ) throws -> RareRewardLedgerCursor? {
        let descriptor = FetchDescriptor<RareRewardLedgerCursor>(
            predicate: #Predicate { $0.epochID == epochID },
            sortBy: [
                SortDescriptor(\.revision, order: .reverse),
                SortDescriptor(\.updatedAt, order: .reverse),
                SortDescriptor(\.id)
            ]
        )
        guard try context.fetchCount(descriptor)
                <= Self.maximumCursorRowsPerEpoch else {
            throw RareRewardLedgerLocalStateError.conflictingCursors
        }
        var bounded = descriptor
        bounded.fetchLimit = Self.maximumCursorRowsPerEpoch
        let values = try context.fetch(bounded)
        guard let canonical = values.first else { return nil }
        let canonicalMigration = try canonical.migration()
        guard canonicalMigration == expectedMigration else {
            throw RareRewardLedgerLocalStateError.conflictingCursors
        }
        let canonicalEpoch = try canonical.epochMirror()
        for value in values.dropFirst() {
            guard try value.migration() == canonicalMigration else {
                throw RareRewardLedgerLocalStateError.conflictingCursors
            }
            let candidateEpoch = try value.epochMirror()
            if candidateEpoch.revision == canonicalEpoch.revision,
               candidateEpoch != canonicalEpoch {
                throw RareRewardLedgerLocalStateError.conflictingCursors
            }
        }
        return canonical
    }

    private func validateSameRevision(
        _ cursor: RareRewardLedgerCursor,
        receipt: RareRewardLedgerReceipt
    ) throws {
        guard cursor.revision == receipt.revisionAfter else { return }
        guard cursor.totalCreditedGrams == receipt.totalCreditedGramsAfter,
              cursor.creditRemainderGrams == receipt.creditRemainderGramsAfter,
              cursor.sinceLastGold == receipt.sinceLastGoldAfter else {
            throw RareRewardLedgerLocalStateError.conflictingCursors
        }
    }

    private func replaceGachaCache(
        with cursor: RareRewardLedgerCursor,
        dataEpochID: UUID?,
        currentMarker: ActivityResetSnapshot?,
        context: ModelContext
    ) throws {
        let descriptor = FetchDescriptor<GachaState>(sortBy: [
            SortDescriptor(\.id)
        ])
        guard try context.fetchCount(descriptor)
                <= Self.maximumGachaRowsPerEpoch else {
            throw RareRewardLedgerLocalStateError.conflictingCursors
        }
        var bounded = descriptor
        bounded.fetchLimit = Self.maximumGachaRowsPerEpoch
        let currentValues = try context.fetch(bounded).filter {
            (try? activityState(
                of: $0.dataEpochID,
                currentMarker: currentMarker,
                context: context
            )) == .current
        }
        let canonical: GachaState
        if let existing = currentValues.first(where: {
            $0.id == SyncMaintenanceCanonicalIDs.gacha
        }) ?? currentValues.first {
            canonical = existing
        } else {
            canonical = GachaState(
                id: SyncMaintenanceCanonicalIDs.gacha,
                dataEpochID: dataEpochID
            )
            context.insert(canonical)
        }
        canonical.id = SyncMaintenanceCanonicalIDs.gacha
        canonical.dataEpochID = dataEpochID
        canonical.rewardCreditGrams = cursor.totalCreditedGrams
        canonical.sinceLastGold = cursor.sinceLastGold
        for value in currentValues where value !== canonical {
            context.delete(value)
        }
    }

    private func latestResetMarker(
        context: ModelContext
    ) throws -> ActivityResetSnapshot? {
        let descriptor = ActivityResetPolicy.currentMarkerDescriptor()
        return try context.fetch(descriptor).first?.policySnapshot
    }

    private func activityState(
        of dataEpochID: UUID?,
        currentMarker: ActivityResetSnapshot?,
        context: ModelContext
    ) throws -> ActivityEpochState {
        guard let currentMarker else {
            return dataEpochID == nil ? .current : .awaitingMarker
        }
        guard dataEpochID != currentMarker.epochID else { return .current }
        guard let dataEpochID else { return .stale }
        let maximumSupportedSequence = ActivityResetPolicy.maximumSupportedSequence
        var descriptor = FetchDescriptor<ActivityResetMarker>(
            predicate: #Predicate {
                $0.epochID == dataEpochID
                    && $0.sequence >= 0
                    && $0.sequence <= maximumSupportedSequence
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).isEmpty ? .awaitingMarker : .stale
    }
}

/// Version 1.0 deliberately ships without the optional random-reward ledger.
///
/// Re-enable only after the raw CloudKit store is bound to a verified Apple
/// Account identity, account switches quarantine every local outbox/cursor,
/// raw records are included in data export/deletion, and the complete flow has
/// passed physical multi-device, offline, restore, and account-switch testing.
/// Re-enabling also requires an explicit device-owned StudySession writer
/// identity; mutating every observed physical copy is never permitted.
enum RareRewardReleasePolicy {
    static let isEnabled = false

    /// Retained rare-ledger code remains directly testable in Debug, while an
    /// accidental explicit `true` at a shipping call site is still clamped to
    /// the release policy.
    static func permitsInternalTestOverride(_ requested: Bool) -> Bool {
#if DEBUG
        requested
#else
        isEnabled
#endif
    }
}

enum RareRewardLedgerRuntime {
    enum Backend: Equatable, Sendable {
        case disabledInMemory
        case simulatorInMemory
        case cloudKit
    }

    static let backend: Backend = {
        guard RareRewardReleasePolicy.isEnabled else {
            return .disabledInMemory
        }
#if targetEnvironment(simulator)
        return .simulatorInMemory
#else
        return .cloudKit
#endif
    }()

    /// The disabled fallback is intentionally non-networked. Shipping call
    /// sites are gated as well, but this second boundary ensures an accidental
    /// future call cannot instantiate or write the raw CloudKit repository.
    static let coordinator: RareRewardLedgerCoordinator = {
        switch backend {
        case .disabledInMemory, .simulatorInMemory:
            return RareRewardLedgerCoordinator(
                repository: InMemoryRareRewardLedgerRepository()
            )
        case .cloudKit:
            return RareRewardLedgerCoordinator(
                repository: CloudKitRareRewardLedgerRepository()
            )
        }
    }()
}
