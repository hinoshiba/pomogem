import CryptoKit
import Foundation
import SwiftData

enum ExactReplicaReadPolicy {
    static func isStable(
        countBefore: Int,
        fetchedCount: Int,
        countAfter: Int,
        maximumSupportedCount: Int
    ) -> Bool {
        countBefore >= 0
            && countBefore <= maximumSupportedCount
            && fetchedCount == countBefore
            && countAfter == countBefore
    }
}

/// A short-lived executor for one bounded, restartable reconciliation slice.
/// The coordinator intentionally creates a new actor for every invocation so
/// registered SwiftData faults cannot accumulate for the life of the app.
@ModelActor
actor SyncMaintenanceSliceWorker {
    enum StableSessionGroupRead {
        case resolved([StudySession])
        case oversized
        case insufficientBudget
        case changedDuringRead
    }

    enum StableAggregateGroupRead {
        case resolved([AggregatePebble])
        case oversized
        case insufficientBudget
        case changedDuringRead
    }

    struct Runtime {
        let limits: SyncMaintenanceSliceLimits
        let now: Date
        var audit = SyncMaintenanceFetchAudit()
    }

    func run(
        _ request: SyncMaintenanceSliceRequest
    ) throws -> SyncMaintenanceSliceResult {
        do {
            if #available(iOS 18.0, *) {
                modelContext.author =
                    SyncMaintenanceNotificationPolicy.maintenanceAuthor
            }
            try Task.checkCancellation()
            var runtime = Runtime(limits: request.limits, now: .now)
            let marker = try latestResetMarker(runtime: &runtime)
            let winningEpochID = marker?.epochID
            let cursor: SyncMaintenanceCursor
            if let existing = request.cursor,
               existing.observedWinningEpochID == winningEpochID {
                cursor = existing
            } else {
                // Every downstream cursor is scoped to one winning reset gate.
                cursor = SyncMaintenanceCursor(
                    observedWinningEpochID: winningEpochID
                )
            }

            switch request.kind {
            case .preferences:
                return try reconcilePreferences(
                    request: request,
                    cursor: cursor,
                    runtime: &runtime
                )
            case .gacha:
                return try reconcileGacha(
                    request: request,
                    currentEpochID: winningEpochID,
                    runtime: &runtime
                )
            case .sessions:
                return try reconcileSessions(
                    request: request,
                    cursor: cursor,
                    currentEpochID: winningEpochID,
                    runtime: &runtime
                )
            case .focusFairness:
                return try reconcileFocusIdentity(
                    request: request,
                    cursor: cursor,
                    currentEpochID: winningEpochID,
                    runtime: &runtime
                )
            case .achievements:
                return try reconcileAchievements(
                    request: request,
                    cursor: cursor,
                    currentEpochID: winningEpochID,
                    runtime: &runtime
                )
            case .bedrock:
                return try reconcileBedrock(
                    request: request,
                    cursor: cursor,
                    currentEpochID: winningEpochID,
                    runtime: &runtime
                )
            case .staleEpochCompaction:
                return try compactStaleEpochs(
                    request: request,
                    cursor: cursor,
                    winningMarker: marker,
                    runtime: &runtime
                )
            case .subjects:
                return try reconnectSubjects(
                    request: request,
                    cursor: cursor,
                    currentEpochID: winningEpochID,
                    runtime: &runtime
                )
            case .strata:
                return try reconcileStrataDuplicates(
                    request: request,
                    cursor: cursor,
                    currentEpochID: winningEpochID,
                    runtime: &runtime
                )
            case .aggregates:
                return try AggregateProjectionMutationGate.withMaintenanceAccess {
                    try reconcileAggregateDuplicates(
                        request: request,
                        cursor: cursor,
                        currentEpochID: winningEpochID,
                        runtime: &runtime
                    )
                }
            case .verificationSweep:
                let followups = Set(SyncMaintenanceKind.allCases.filter {
                    $0 != .verificationSweep
                })
                return .completed(
                    request: request,
                    audit: runtime.audit,
                    followups: followups
                )
            }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    // MARK: - Common bounded operations

    private func fetch<T: PersistentModel>(
        _ source: FetchDescriptor<T>,
        limit: Int,
        runtime: inout Runtime
    ) throws -> [T] {
        try Task.checkCancellation()
        let boundedLimit = min(limit, runtime.limits.maximumRowsPerFetch)
        var descriptor = source
        descriptor.fetchLimit = boundedLimit
        let rows = try modelContext.fetch(descriptor)
        try runtime.audit.recordFetch(
            rows: rows.count,
            requestedLimit: boundedLimit,
            limits: runtime.limits
        )
        return rows
    }

    private func fetchCount<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        runtime: inout Runtime
    ) throws -> Int {
        try Task.checkCancellation()
        runtime.audit.recordCountQuery()
        return try modelContext.fetchCount(descriptor)
    }

    private func saveIfNeeded(runtime: inout Runtime) throws -> Bool {
        guard modelContext.hasChanges else { return false }
        try Task.checkCancellation()
        do {
            try modelContext.save()
            try runtime.audit.recordSave(limits: runtime.limits)
            return true
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func stableSessionGroup(
        id: UUID,
        currentEpochID: UUID?,
        reservingRows: Int = 0,
        runtime: inout Runtime
    ) throws -> StableSessionGroupRead {
        let descriptor = sessionGroupDescriptor(
            id: id,
            currentEpochID: currentEpochID
        )
        let countBefore = try fetchCount(descriptor, runtime: &runtime)
        guard countBefore <= runtime.limits.maximumRowsPerFetch else {
            return .oversized
        }
        guard countBefore <= runtime.limits.maximumRowsPerSlice
                - runtime.audit.totalRowsAccessed
                - max(0, reservingRows)
        else { return .insufficientBudget }
        let rows = try fetch(
            descriptor,
            limit: runtime.limits.maximumRowsPerFetch,
            runtime: &runtime
        )
        let countAfter = try fetchCount(descriptor, runtime: &runtime)
        guard ExactReplicaReadPolicy.isStable(
            countBefore: countBefore,
            fetchedCount: rows.count,
            countAfter: countAfter,
            maximumSupportedCount: runtime.limits.maximumRowsPerFetch
        ) else { return .changedDuringRead }
        return .resolved(rows)
    }

    /// Count/fetch/count detects cardinality changes around the bounded fetch.
    /// It is not a linearizable fence for a same-count replacement; aggregate
    /// writers in this process are additionally serialized by the mutation
    /// gate, while imported source changes enqueue a newer durable generation
    /// and keep cloud presentation unverified until that generation completes.
    private func stableAggregateGroup(
        id: UUID,
        currentEpochID: UUID?,
        reservingRows: Int = 0,
        runtime: inout Runtime
    ) throws -> StableAggregateGroupRead {
        let descriptor = aggregateGroupDescriptor(
            id: id,
            currentEpochID: currentEpochID
        )
        let countBefore = try fetchCount(descriptor, runtime: &runtime)
        guard countBefore <= runtime.limits.maximumRowsPerFetch else {
            return .oversized
        }
        guard countBefore <= runtime.limits.maximumRowsPerSlice
                - runtime.audit.totalRowsAccessed
                - max(0, reservingRows)
        else { return .insufficientBudget }
        let rows = try fetch(
            descriptor,
            limit: runtime.limits.maximumRowsPerFetch,
            runtime: &runtime
        )
        let countAfter = try fetchCount(descriptor, runtime: &runtime)
        guard ExactReplicaReadPolicy.isStable(
            countBefore: countBefore,
            fetchedCount: rows.count,
            countAfter: countAfter,
            maximumSupportedCount: runtime.limits.maximumRowsPerFetch
        ) else { return .changedDuringRead }
        return .resolved(rows)
    }

    private func latestResetMarker(
        runtime: inout Runtime
    ) throws -> ActivityResetSnapshot? {
        let descriptor = ActivityResetPolicy.currentMarkerDescriptor(
            now: runtime.now
        )
        return try fetch(descriptor, limit: 1, runtime: &runtime)
            .first?
            .policySnapshot
    }

    // MARK: - Preferences

    private func reconcilePreferences(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        let descriptor = FetchDescriptor<Prefs>(
            sortBy: [SortDescriptor(\Prefs.syncRecordID)]
        )
        let values = try fetch(
            descriptor,
            limit: runtime.limits.maximumRowsPerFetch,
            runtime: &runtime
        )
        if values.count == runtime.limits.maximumRowsPerFetch,
           try fetchCount(descriptor, runtime: &runtime) > values.count {
            // Do not partially fold a singleton group or batch-delete rows
            // that may have arrived after the read snapshot.
            return .retry(
                request: request,
                cursor: cursor,
                audit: runtime.audit,
                category: "oversized-preferences-group"
            )
        }

        guard !values.isEmpty else {
            // Launch preparation owns singleton creation on the MainActor.
            // The background ModelActor remains read-only so it cannot race a
            // user mutation on the device-owned writer row.
            return .completed(
                request: request,
                audit: runtime.audit
            )
        }
        do {
            try PrefsSyncPolicy.validateReplicaSet(in: values)
        } catch let error as PrefsSyncError {
            return .retry(
                request: request,
                cursor: cursor,
                audit: runtime.audit,
                category: error == .conflictingStampedValues
                    ? "conflicting-preference-stamp"
                    : "invalid-preference-replica-set"
            )
        }
        return .completed(
            request: request,
            audit: runtime.audit
        )
    }

    // MARK: - Gacha singleton

    private func reconcileGacha(
        request: SyncMaintenanceSliceRequest,
        currentEpochID: UUID?,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        let statePredicate: Predicate<GachaState>
        if let currentEpochID {
            statePredicate = #Predicate { $0.dataEpochID == currentEpochID }
        } else {
            statePredicate = #Predicate { $0.dataEpochID == nil }
        }
        let stateDescriptor = FetchDescriptor<GachaState>(
            predicate: statePredicate,
            sortBy: [SortDescriptor(\GachaState.id)]
        )
        var values = try fetch(
            stateDescriptor,
            limit: runtime.limits.maximumRowsPerFetch,
            runtime: &runtime
        )
        if values.count == runtime.limits.maximumRowsPerFetch,
           try fetchCount(stateDescriptor, runtime: &runtime) > values.count {
            return .retry(
                request: request,
                cursor: request.cursor,
                audit: runtime.audit,
                category: "oversized-gacha-group"
            )
        }

        let ledgerCursors: [RareRewardLedgerCursor]
        if request.includesRareRewardLedgerMaintenance {
            let cursorPredicate: Predicate<RareRewardLedgerCursor>
            if let currentEpochID {
                cursorPredicate = #Predicate { $0.dataEpochID == currentEpochID }
            } else {
                cursorPredicate = #Predicate { $0.dataEpochID == nil }
            }
            let cursorDescriptor = FetchDescriptor<RareRewardLedgerCursor>(
                predicate: cursorPredicate,
                sortBy: [
                    SortDescriptor(\RareRewardLedgerCursor.revision, order: .reverse),
                    SortDescriptor(\RareRewardLedgerCursor.updatedAt, order: .reverse),
                    SortDescriptor(\RareRewardLedgerCursor.id, order: .reverse)
                ]
            )
            ledgerCursors = try fetch(
                cursorDescriptor,
                limit: runtime.limits.maximumRowsPerFetch,
                runtime: &runtime
            )
            if ledgerCursors.count == runtime.limits.maximumRowsPerFetch,
               try fetchCount(cursorDescriptor, runtime: &runtime) > ledgerCursors.count {
                return .retry(
                    request: request,
                    cursor: request.cursor,
                    audit: runtime.audit,
                    category: "oversized-v2-ledger-cursor-group"
                )
            }
        } else {
            ledgerCursors = []
        }

        let canonical: GachaState
        if let existing = values.first(where: {
            $0.id == SyncMaintenanceCanonicalIDs.gacha
        }) ?? values.first {
            canonical = existing
        } else {
            canonical = GachaState(
                id: SyncMaintenanceCanonicalIDs.gacha,
                dataEpochID: currentEpochID
            )
            modelContext.insert(canonical)
            values.append(canonical)
        }

        if !ledgerCursors.isEmpty {
            let normalizedEpochID = RareRewardLedgerV2.normalizedEpochID(
                currentEpochID
            )
            let valid = ledgerCursors.filter {
                $0.epochID == normalizedEpochID
                    && !$0.migrationFingerprint.isEmpty
                    && UInt64($0.seedRawValue) != nil
                    && $0.totalCreditedGrams >= 0
                    && $0.creditRemainderGrams >= 0
                    && $0.creditRemainderGrams < Constants.Gacha.creditGrams
                    && $0.creditRemainderGrams
                        == $0.totalCreditedGrams % Constants.Gacha.creditGrams
                    && $0.nextOrdinal == Int64(
                        $0.totalCreditedGrams / Constants.Gacha.creditGrams
                    )
                    && $0.sinceLastGold >= 0
                    && $0.revision >= 0
            }
            guard valid.count == ledgerCursors.count,
                  Set(valid.map(\.migrationFingerprint)).count == 1,
                  let authoritative = valid.max(by: { lhs, rhs in
                      if lhs.revision != rhs.revision {
                          return lhs.revision < rhs.revision
                      }
                      if lhs.updatedAt != rhs.updatedAt {
                          return lhs.updatedAt < rhs.updatedAt
                      }
                      return lhs.id.uuidString < rhs.id.uuidString
                  }) else {
                return .retry(
                    request: request,
                    cursor: request.cursor,
                    audit: runtime.audit,
                    category: "invalid-or-conflicting-v2-ledger-cursor"
                )
            }

            // Once V2 has an acknowledged server revision, its cursor is the
            // only authority. Replaying the bounded legacy StudySession tail
            // here could resurrect a pre-gold miss maximum or branch the mass
            // ledger after another device won the CAS.
            canonical.id = SyncMaintenanceCanonicalIDs.gacha
            canonical.dataEpochID = currentEpochID
            canonical.sinceLastGold = authoritative.sinceLastGold
            canonical.rewardCreditGrams = authoritative.totalCreditedGrams
            for value in values where value !== canonical {
                modelContext.delete(value)
            }
            _ = try saveIfNeeded(runtime: &runtime)
            return .completed(request: request, audit: runtime.audit)
        }

        let sessionPredicate: Predicate<StudySession>
        if let currentEpochID {
            sessionPredicate = #Predicate { $0.dataEpochID == currentEpochID }
        } else {
            sessionPredicate = #Predicate { $0.dataEpochID == nil }
        }
        var firstDescriptor = FetchDescriptor<StudySession>(
            predicate: sessionPredicate,
            sortBy: [
                SortDescriptor(\StudySession.endAt, order: .reverse),
                SortDescriptor(\StudySession.id, order: .reverse)
            ]
        )
        let tailPageLimit = min(
            runtime.limits.maximumRowsPerFetch,
            GachaHistoryReconciliationPolicy.maximumCandidateRecordCount
        )
        let first = try fetch(
            firstDescriptor,
            limit: tailPageLimit,
            runtime: &runtime
        )
        var tail = first
        if first.count == tailPageLimit,
           tail.count < GachaHistoryReconciliationPolicy.maximumCandidateRecordCount {
            firstDescriptor.fetchOffset = tailPageLimit
            let remaining = min(
                tailPageLimit,
                GachaHistoryReconciliationPolicy.maximumCandidateRecordCount - tail.count
            )
            tail += try fetch(
                firstDescriptor,
                limit: remaining,
                runtime: &runtime
            )
        }
        let history = StudySessionIntegrityPolicy.supported(tail).map {
            GachaHistorySnapshot(
                id: $0.id,
                endAt: $0.endAt,
                seconds: $0.seconds,
                source: $0.source,
                pebbleKind: $0.pebbleKind,
                rareRewardRuleVersion: $0.rareRewardRuleVersion,
                rareRewardParticipated: $0.rareRewardParticipated,
                rareRewardCreditedGrams: $0.rareRewardCreditedGrams,
                rareRewardOutcomes: RareRewardOutcomeCodec.decode(
                    $0.rareRewardOutcomesRawValue
                )
            )
        }

        let storedCredit = values.map(\.rewardCreditGrams).max() ?? 0
        let coherent = values
            .filter { $0.rewardCreditGrams == storedCredit }
            .max(by: { lhs, rhs in
                let leftCanonical = lhs.id == SyncMaintenanceCanonicalIDs.gacha
                let rightCanonical = rhs.id == SyncMaintenanceCanonicalIDs.gacha
                if leftCanonical != rightCanonical { return !leftCanonical }
                return lhs.id.uuidString < rhs.id.uuidString
            })
        let knownProgress = storedCredit == 0
            ? values.map(\.sinceLastGold).max() ?? 0
            : coherent?.sinceLastGold ?? 0
        canonical.id = SyncMaintenanceCanonicalIDs.gacha
        canonical.dataEpochID = currentEpochID
        canonical.sinceLastGold = GachaHistoryReconciliationPolicy.reconciledProgress(
            knownProgress: knownProgress,
            sessions: history
        )
        canonical.rewardCreditGrams = max(
            storedCredit,
            GachaHistoryReconciliationPolicy.observedRewardCreditGrams(
                sessions: history
            )
        )
        for value in values where value !== canonical {
            modelContext.delete(value)
        }
        _ = try saveIfNeeded(runtime: &runtime)
        return .completed(request: request, audit: runtime.audit)
    }

    // MARK: - Bedrock

    private func reconcileBedrock(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        currentEpochID: UUID?,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        if cursor.phase == 1 {
            // Lifecycle facts are synchronized source too. A background
            // ModelActor must not overwrite a newer MainActor mutation on the
            // same device-owned preference row. The explicit import path owns
            // setting `hasEverImportedBedrock`.
            return .completed(request: request, audit: runtime.audit)
        }
        guard cursor.phase == 0 else {
            throw SyncMaintenanceError.invalidCursorPayload
        }

        let predicate: Predicate<Bedrock>
        if let currentEpochID {
            predicate = #Predicate { $0.dataEpochID == currentEpochID }
        } else {
            predicate = #Predicate { $0.dataEpochID == nil }
        }
        let descriptor = FetchDescriptor<Bedrock>(
            predicate: predicate,
            sortBy: [SortDescriptor(\Bedrock.importedAt)]
        )
        let values = try fetch(
            descriptor,
            limit: runtime.limits.maximumRowsPerFetch,
            runtime: &runtime
        )
        if values.count == runtime.limits.maximumRowsPerFetch,
           try fetchCount(descriptor, runtime: &runtime) > values.count {
            return .retry(
                request: request,
                cursor: request.cursor,
                audit: runtime.audit,
                category: "oversized-bedrock-group"
            )
        }
        guard let canonical = values.first else {
            return .completed(request: request, audit: runtime.audit)
        }
        let mergedHours = values.map(\.hours).max() ?? canonical.hours
        let earliestImport = values.map(\.importedAt).min() ?? canonical.importedAt
        if canonical.hours != mergedHours { canonical.hours = mergedHours }
        if canonical.importedAt != earliestImport {
            canonical.importedAt = earliestImport
        }
        if canonical.dataEpochID != currentEpochID {
            canonical.dataEpochID = currentEpochID
        }
        for value in values.dropFirst() { modelContext.delete(value) }
        _ = try saveIfNeeded(runtime: &runtime)
        var next = cursor
        next.phase = 1
        return .moreWork(
            request: request,
            cursor: next,
            audit: runtime.audit
        )
    }

    // Remaining phases are split below so every save still represents one
    // complete logical group or one independent stale-row batch.
}

// MARK: - Logical StudySession identity

private extension SyncMaintenanceSliceWorker {
    struct AggregateProjectionRebuildBoundary: Codable {
        let endAt: Date
        let id: UUID
        let startedWithoutProjection: Bool
    }

    struct SessionPhysicalCursor: Codable {
        let endAt: Date
        let id: UUID
        let syncRecordID: UUID

        init(_ session: StudySession) {
            endAt = session.endAt
            id = session.id
            syncRecordID = session.syncRecordID
        }
    }

    struct RetentionBoundaryCandidate: Codable {
        let endAt: Date
        let id: UUID
        let syncRecordID: UUID

        init(_ session: StudySession) {
            endAt = session.endAt
            id = session.id
            syncRecordID = session.syncRecordID
        }
    }

    struct AggregateRetentionBoundaryScanState: Codable {
        var physicalCursor: SessionPhysicalCursor?
        var scannedPhysicalRows: Int
        var candidates: [RetentionBoundaryCandidate]
        var unsupportedOnlyIDs: [UUID]

        init() {
            physicalCursor = nil
            scannedPhysicalRows = 0
            candidates = []
            unsupportedOnlyIDs = []
        }
    }

    enum RetentionBoundaryResolution {
        case resolved(RetentionBoundaryCandidate?)
        case moreWork(AggregateRetentionBoundaryScanState)
        case unavailable(String)
    }

    struct AggregateLeafValidationState: Codable {
        let leafID: UUID
        let memberIDs: [UUID]
        var snapshotFingerprints: [String]
    }

    enum AggregateLeafMemberRead {
        case resolved(StudySessionSyncPolicy.ChangeToken)
        case insufficientBudget
        case changedDuringRead
        case invalid
    }

    enum AggregateLineageDerivation {
        case resolved
        case insufficientBudget
        case changedDuringRead
        case invalid
    }

    func resolveAggregateRetentionBoundary(
        currentEpochID: UUID?,
        initialState: AggregateRetentionBoundaryScanState,
        runtime: inout Runtime
    ) throws -> RetentionBoundaryResolution {
        let retainedCount = HomeProjectionPolicy.looseSessionLimit
        let requiredLogicalCount = NonnegativeIntPolicy.adding(retainedCount, 1)
        let physicalScanLimit = HomeProjectionPolicy.maximumLooseSessionScanRows
        let pageSize = min(128, runtime.limits.maximumRowsPerFetch)
        var state = initialState
        var resolvedByID = Dictionary(
            uniqueKeysWithValues: state.candidates.map { ($0.id, $0) }
        )
        var resolvedIDs = Set(resolvedByID.keys)
        var unsupportedOnlyIDs = Set(state.unsupportedOnlyIDs)

        while state.scannedPhysicalRows < physicalScanLimit {
            let remainingSliceRows = runtime.limits.maximumRowsPerSlice
                - runtime.audit.totalRowsAccessed
            guard remainingSliceRows >= 1 else {
                state.candidates = Array(resolvedByID.values)
                state.unsupportedOnlyIDs = Array(unsupportedOnlyIDs)
                return .moreWork(state)
            }
            let fetchLimit = min(
                pageSize,
                physicalScanLimit - state.scannedPhysicalRows,
                remainingSliceRows
            )
            let page = try fetch(
                newestSessionDescriptor(
                    currentEpochID: currentEpochID,
                    after: state.physicalCursor
                ),
                limit: fetchLimit,
                runtime: &runtime
            )
            let reachedRawEnd = page.count < fetchLimit

            for row in page {
                guard StudySessionIntegrityPolicy.isSupported(row) else {
                    if !resolvedIDs.contains(row.id) {
                        unsupportedOnlyIDs.insert(row.id)
                    }
                    continue
                }
                unsupportedOnlyIDs.remove(row.id)
                guard resolvedIDs.insert(row.id).inserted else { continue }
                switch try stableSessionGroup(
                    id: row.id,
                    currentEpochID: currentEpochID,
                    reservingRows: 1,
                    runtime: &runtime
                ) {
                case let .resolved(exact):
                    if let resolved = StudySessionSyncPolicy.canonicalSession(from: exact) {
                        resolvedByID[row.id] = RetentionBoundaryCandidate(resolved)
                    }
                case .oversized:
                    return .unavailable("oversized-retention-session-group")
                case .insufficientBudget, .changedDuringRead:
                    resolvedIDs.remove(row.id)
                    state.candidates = Array(resolvedByID.values)
                    state.unsupportedOnlyIDs = Array(unsupportedOnlyIDs)
                    return .moreWork(state)
                }
            }

            state.scannedPhysicalRows = NonnegativeIntPolicy.adding(
                state.scannedPhysicalRows,
                page.count,
                maximum: physicalScanLimit
            )
            if let edge = page.last {
                state.physicalCursor = SessionPhysicalCursor(edge)
            }

            if reachedRawEnd { unsupportedOnlyIDs.removeAll() }
            let ordered = resolvedByID.values.sorted(by: newestSessionComesFirst)
            if reachedRawEnd {
                return .resolved(
                    ordered.count >= requiredLogicalCount
                        ? ordered[retainedCount - 1]
                        : nil
                )
            }
            guard let edge = page.last else { return .resolved(nil) }
            if unsupportedOnlyIDs.isEmpty,
               ordered.count >= requiredLogicalCount,
               !newestSessionComesFirst(
                    RetentionBoundaryCandidate(edge),
                    ordered[retainedCount - 1]
               ) {
                return .resolved(ordered[retainedCount - 1])
            }
            if runtime.audit.totalRowsAccessed
                >= runtime.limits.maximumRowsPerSlice / 2 {
                state.candidates = Array(resolvedByID.values)
                state.unsupportedOnlyIDs = Array(unsupportedOnlyIDs)
                return .moreWork(state)
            }
        }

        guard let physicalCursor = state.physicalCursor,
              runtime.audit.totalRowsAccessed
                < runtime.limits.maximumRowsPerSlice
        else { return .unavailable("retention-boundary-scan-limit") }
        let sentinel = try fetch(
            newestSessionDescriptor(
                currentEpochID: currentEpochID,
                after: physicalCursor
            ),
            limit: 1,
            runtime: &runtime
        )
        guard sentinel.isEmpty else {
            return .unavailable("retention-boundary-scan-limit")
        }
        let ordered = resolvedByID.values.sorted(by: newestSessionComesFirst)
        return .resolved(
            ordered.count >= requiredLogicalCount
                ? ordered[retainedCount - 1]
                : nil
        )
    }

    func newestSessionComesFirst(
        _ lhs: RetentionBoundaryCandidate,
        _ rhs: RetentionBoundaryCandidate
    ) -> Bool {
        if lhs.endAt != rhs.endAt { return lhs.endAt > rhs.endAt }
        if lhs.id != rhs.id {
            return lhs.id.uuidString > rhs.id.uuidString
        }
        return lhs.syncRecordID.uuidString > rhs.syncRecordID.uuidString
    }

    func reconcileSessions(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        currentEpochID: UUID?,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        let pageLimit = min(128, runtime.limits.maximumRowsPerFetch)
        let descriptor = sessionPageDescriptor(
            currentEpochID: currentEpochID,
            after: cursor.lastLogicalID
        )
        let page = try fetch(descriptor, limit: pageLimit, runtime: &runtime)
        guard !page.isEmpty else {
            return .completed(request: request, audit: runtime.audit)
        }

        let grouped = Dictionary(grouping: page, by: \.id)
        let duplicateID = page.lazy
            .map(\.id)
            .first { (grouped[$0]?.count ?? 0) > 1 }
        let boundaryID = page.count == pageLimit ? page.last?.id : nil
        let targetID = duplicateID ?? boundaryID
        var lastProcessedID: UUID?

        if let targetID {
            let exactDescriptor = sessionGroupDescriptor(
                id: targetID,
                currentEpochID: currentEpochID
            )
            let exactCount = try fetchCount(exactDescriptor, runtime: &runtime)
            guard exactCount <= runtime.limits.maximumRowsPerFetch else {
                return .retry(
                    request: request,
                    cursor: cursor,
                    audit: runtime.audit,
                    category: "oversized-session-logical-group"
                )
            }
            let exact = try fetch(
                exactDescriptor,
                limit: runtime.limits.maximumRowsPerFetch,
                runtime: &runtime
            )
            for value in page where value.id.uuidString < targetID.uuidString {
                normalizeSessionGroup([value], currentEpochID: currentEpochID)
            }
            normalizeSessionGroup(exact, currentEpochID: currentEpochID)
            lastProcessedID = targetID
        } else {
            for value in page {
                normalizeSessionGroup([value], currentEpochID: currentEpochID)
            }
            lastProcessedID = page.last?.id
        }

        let finished = page.count < pageLimit && targetID == nil
        if finished {
            return .completed(
                request: request,
                audit: runtime.audit
            )
        }
        var next = cursor
        next.lastLogicalID = lastProcessedID
        return .moreWork(
            request: request,
            cursor: next,
            audit: runtime.audit
        )
    }

    func sessionPageDescriptor(
        currentEpochID: UUID?,
        after: UUID?
    ) -> FetchDescriptor<StudySession> {
        let predicate: Predicate<StudySession>
        switch (currentEpochID, after) {
        case let (epochID?, lastID?):
            predicate = #Predicate {
                $0.dataEpochID == epochID && $0.id > lastID
            }
        case let (epochID?, nil):
            predicate = #Predicate { $0.dataEpochID == epochID }
        case let (nil, lastID?):
            predicate = #Predicate {
                $0.dataEpochID == nil && $0.id > lastID
            }
        case (nil, nil):
            predicate = #Predicate { $0.dataEpochID == nil }
        }
        return FetchDescriptor<StudySession>(
            predicate: predicate,
            sortBy: [SortDescriptor(\StudySession.id)]
        )
    }

    func sessionGroupDescriptor(
        id: UUID,
        currentEpochID: UUID?
    ) -> FetchDescriptor<StudySession> {
        let predicate: Predicate<StudySession>
        if let currentEpochID {
            predicate = #Predicate {
                $0.id == id && $0.dataEpochID == currentEpochID
            }
        } else {
            predicate = #Predicate {
                $0.id == id && $0.dataEpochID == nil
            }
        }
        return FetchDescriptor<StudySession>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\StudySession.endAt),
                SortDescriptor(\StudySession.startAt),
                SortDescriptor(\StudySession.deviceDayKey)
            ]
        )
    }

    func normalizeSessionGroup(
        _ values: [StudySession],
        currentEpochID: UUID?
    ) {
        _ = currentEpochID
        // Read-only by design. Two devices can observe overlapping partial
        // replica sets ({A,B} and {B,C}); rewriting either set can destroy the
        // only evidence for a concurrent value through CloudKit record-level
        // conflict resolution. Consumers call the same pure resolver.
        _ = StudySessionSyncPolicy.canonicalSession(from: values)
    }
}

// MARK: - Subject relationship repair

private extension SyncMaintenanceSliceWorker {
    /// Audits subject references without rewriting CloudKit source rows.
    /// Presentation resolves same-ID subjects in memory; relationship repair
    /// across contexts would otherwise race a concurrent user edit.
    func reconnectSubjects(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        currentEpochID: UUID?,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        let subjectDescriptor = FetchDescriptor<Subject>(sortBy: [
            SortDescriptor(\Subject.id),
            SortDescriptor(\Subject.createdAt)
        ])
        let subjects = try fetch(
            subjectDescriptor,
            limit: runtime.limits.maximumRowsPerFetch,
            runtime: &runtime
        )
        if subjects.count == runtime.limits.maximumRowsPerFetch,
           try fetchCount(subjectDescriptor, runtime: &runtime) > subjects.count {
            return .retry(
                request: request,
                cursor: cursor,
                audit: runtime.audit,
                category: "oversized-subject-catalogue"
            )
        }
        let subjectGroups = Dictionary(grouping: subjects, by: \.id)
        let canonicalSubjects = subjectGroups.compactMapValues { values in
            SubjectSyncPolicy.canonical(from: values)
        }

        let pageLimit = min(128, runtime.limits.maximumRowsPerFetch)
        if cursor.phase == 0 {
            let descriptor = sessionPageDescriptor(
                currentEpochID: currentEpochID,
                after: cursor.lastLogicalID
            )
            let sessions = try fetch(
                descriptor,
                limit: pageLimit,
                runtime: &runtime
            )
            for session in sessions where StudySessionIntegrityPolicy.isSupported(session) {
                _ = session.subjectIDSnapshot.flatMap { canonicalSubjects[$0] }
            }
            if sessions.count == pageLimit, let lastID = sessions.last?.id {
                var next = cursor
                next.lastLogicalID = lastID
                return .moreWork(
                    request: request,
                    cursor: next,
                    audit: runtime.audit
                )
            }
            var next = SyncMaintenanceCursor(
                observedWinningEpochID: cursor.observedWinningEpochID,
                phase: 1
            )
            next.lastLogicalID = nil
            return .moreWork(
                request: request,
                cursor: next,
                audit: runtime.audit
            )
        }

        let achievementDescriptor = achievementPageDescriptor(
            currentEpochID: currentEpochID,
            after: cursor.lastLogicalID
        )
        let stones = try fetch(
            achievementDescriptor,
            limit: pageLimit,
            runtime: &runtime
        )
        for stone in stones {
            _ = stone.subject.flatMap { canonicalSubjects[$0.id] }
        }
        if stones.count == pageLimit, let lastID = stones.last?.id {
            var next = cursor
            next.lastLogicalID = lastID
            return .moreWork(
                request: request,
                cursor: next,
                audit: runtime.audit
            )
        }
        return .completed(
            request: request,
            audit: runtime.audit
        )
    }
}

// MARK: - Local projection duplicate repair

private extension SyncMaintenanceSliceWorker {
    func reconcileStrataDuplicates(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        currentEpochID: UUID?,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        let pageLimit = min(128, runtime.limits.maximumRowsPerFetch)
        let descriptor = stratumPageDescriptor(
            currentEpochID: currentEpochID,
            after: cursor.lastLogicalID
        )
        let page = try fetch(descriptor, limit: pageLimit, runtime: &runtime)
        guard !page.isEmpty else {
            return .completed(request: request, audit: runtime.audit)
        }
        let grouped = Dictionary(grouping: page, by: \.id)
        let duplicateID = page.lazy
            .map(\.id)
            .first { (grouped[$0]?.count ?? 0) > 1 }
        let boundaryID = page.count == pageLimit ? page.last?.id : nil
        let targetID = duplicateID ?? boundaryID
        var lastProcessed = page.last?.id
        if let targetID {
            let exactDescriptor = stratumGroupDescriptor(
                id: targetID,
                currentEpochID: currentEpochID
            )
            let count = try fetchCount(exactDescriptor, runtime: &runtime)
            guard count <= runtime.limits.maximumRowsPerFetch else {
                return .retry(
                    request: request,
                    cursor: cursor,
                    audit: runtime.audit,
                    category: "oversized-stratum-logical-group"
                )
            }
            let exact = try fetch(
                exactDescriptor,
                limit: runtime.limits.maximumRowsPerFetch,
                runtime: &runtime
            )
            normalizeStratumGroup(exact)
            lastProcessed = targetID
        } else {
            page.forEach { normalizeStratumGroup([$0]) }
        }
        let changed = try saveIfNeeded(runtime: &runtime)
        if page.count < pageLimit && targetID == nil {
            return .completed(
                request: request,
                audit: runtime.audit,
                effects: changed ? [.refreshActivityProjection] : [],
                followups: changed ? [.aggregates] : []
            )
        }
        var next = cursor
        next.lastLogicalID = lastProcessed
        return .moreWork(
            request: request,
            cursor: next,
            audit: runtime.audit,
            effects: changed ? [.refreshActivityProjection] : [],
            followups: changed ? [.aggregates] : []
        )
    }

    func stratumPageDescriptor(
        currentEpochID: UUID?,
        after: UUID?
    ) -> FetchDescriptor<Stratum> {
        let predicate: Predicate<Stratum>
        switch (currentEpochID, after) {
        case let (epochID?, lastID?):
            predicate = #Predicate {
                $0.dataEpochID == epochID && $0.id > lastID
            }
        case let (epochID?, nil):
            predicate = #Predicate { $0.dataEpochID == epochID }
        case let (nil, lastID?):
            predicate = #Predicate {
                $0.dataEpochID == nil && $0.id > lastID
            }
        case (nil, nil):
            predicate = #Predicate { $0.dataEpochID == nil }
        }
        return FetchDescriptor<Stratum>(
            predicate: predicate,
            sortBy: [SortDescriptor(\Stratum.id)]
        )
    }

    func stratumGroupDescriptor(
        id: UUID,
        currentEpochID: UUID?
    ) -> FetchDescriptor<Stratum> {
        let predicate: Predicate<Stratum>
        if let currentEpochID {
            predicate = #Predicate {
                $0.id == id && $0.dataEpochID == currentEpochID
            }
        } else {
            predicate = #Predicate {
                $0.id == id && $0.dataEpochID == nil
            }
        }
        return FetchDescriptor<Stratum>(
            predicate: predicate,
            sortBy: [SortDescriptor(\Stratum.bakedAt)]
        )
    }

    func normalizeStratumGroup(_ values: [Stratum]) {
        guard let canonical = values.min(by: { lhs, rhs in
            if lhs.bakedAt != rhs.bakedAt { return lhs.bakedAt < rhs.bakedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }) else { return }
        let membership = Set(values.flatMap(\.sessionIDs))
        canonical.replaceSessionIDs(Array(membership))
        canonical.pebbleCount = max(
            membership.count,
            values.map(\.pebbleCount).max() ?? 0
        )
        canonical.grams = max(0, values.map(\.grams).max() ?? 0)
        canonical.heightPt = max(0, values.map(\.heightPt).max() ?? 0)
        canonical.bakedAt = values.map(\.bakedAt).min() ?? canonical.bakedAt
        if canonical.colorMixJSON == "[]" {
            canonical.colorMixJSON = values
                .map(\.colorMixJSON)
                .filter { $0 != "[]" }
                .sorted()
                .first ?? "[]"
        }
        if canonical.monthLabel.isEmpty {
            canonical.monthLabel = values
                .map(\.monthLabel)
                .filter { !$0.isEmpty }
                .sorted()
                .first ?? ""
        }
        for value in values where value !== canonical {
            modelContext.delete(value)
        }
    }

    func reconcileAggregateDuplicates(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        currentEpochID: UUID?,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        switch cursor.phase {
        case 1:
            return try verifyAggregateLeafProjection(
                request: request,
                cursor: cursor,
                currentEpochID: currentEpochID,
                runtime: &runtime
            )
        case 2:
            return try rebuildMissingAggregateLeaves(
                request: request,
                cursor: cursor,
                currentEpochID: currentEpochID,
                runtime: &runtime
            )
        case 3...:
            return try rollUpRebuiltAggregateRoots(
                request: request,
                cursor: cursor,
                currentEpochID: currentEpochID,
                runtime: &runtime
            )
        default:
            break
        }

        let pageLimit = min(128, runtime.limits.maximumRowsPerFetch)
        let descriptor = aggregatePageDescriptor(
            currentEpochID: currentEpochID,
            after: cursor.lastLogicalID
        )
        let page = try fetch(descriptor, limit: pageLimit, runtime: &runtime)
        guard !page.isEmpty else {
            return .moreWork(
                request: request,
                cursor: aggregateLeafValidationCursor(from: cursor),
                audit: runtime.audit
            )
        }
        let grouped = Dictionary(grouping: page, by: \.id)
        let duplicateID = page.lazy
            .map(\.id)
            .first { (grouped[$0]?.count ?? 0) > 1 }
        let boundaryID = page.count == pageLimit ? page.last?.id : nil
        let targetID = duplicateID ?? boundaryID
        var lastProcessed = page.last?.id
        if let targetID {
            switch try stableAggregateGroup(
                id: targetID,
                currentEpochID: currentEpochID,
                runtime: &runtime
            ) {
            case .oversized:
                return .retry(
                    request: request,
                    cursor: cursor,
                    audit: runtime.audit,
                    category: "oversized-aggregate-logical-group"
                )
            case .insufficientBudget:
                return .moreWork(
                    request: request,
                    cursor: cursor,
                    audit: runtime.audit
                )
            case .changedDuringRead:
                return .retry(
                    request: request,
                    cursor: cursor,
                    audit: runtime.audit,
                    category: "changed-aggregate-logical-group"
                )
            case let .resolved(exact):
                normalizeAggregateGroup(exact)
                lastProcessed = targetID
            }
        } else {
            page.forEach { normalizeAggregateGroup([$0]) }
        }
        let changed = try saveIfNeeded(runtime: &runtime)
        if page.count < pageLimit && targetID == nil {
            return .moreWork(
                request: request,
                cursor: aggregateLeafValidationCursor(from: cursor),
                audit: runtime.audit,
                effects: changed ? [.refreshActivityProjection] : []
            )
        }
        var next = cursor
        next.lastLogicalID = lastProcessed
        return .moreWork(
            request: request,
            cursor: next,
            audit: runtime.audit,
            effects: changed ? [.refreshActivityProjection] : []
        )
    }

    /// Phase one walks every device-local leaf, keeps it v0 while its logical
    /// source groups are being proven, and re-derives every semantic field from
    /// the current canonical winners. Fixed-size digests make collection
    /// restartable; promotion still requires one complete second pass in the
    /// current slice, followed by stable ancestor reads.
    func verifyAggregateLeafProjection(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        currentEpochID: UUID?,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        let restoredState = cursor.payload.flatMap {
            try? JSONDecoder().decode(AggregateLeafValidationState.self, from: $0)
        }
        let leaf: AggregatePebble
        if let restoredState {
            switch try stableAggregateGroup(
                id: restoredState.leafID,
                currentEpochID: currentEpochID,
                runtime: &runtime
            ) {
            case let .resolved(rows) where rows.count == 1:
                leaf = rows[0]
            case let .resolved(rows) where rows.isEmpty:
                var next = cursor
                next.lastLogicalID = restoredState.leafID
                next.payload = nil
                return .moreWork(
                    request: request,
                    cursor: next,
                    audit: runtime.audit
                )
            case .insufficientBudget:
                return .moreWork(
                    request: request,
                    cursor: cursor,
                    audit: runtime.audit
                )
            case .changedDuringRead:
                return .retry(
                    request: request,
                    cursor: cursor,
                    audit: runtime.audit,
                    category: "changed-aggregate-leaf-validation-row"
                )
            case .oversized, .resolved(_):
                return .retry(
                    request: request,
                    cursor: cursor,
                    audit: runtime.audit,
                    category: "ambiguous-aggregate-leaf-validation-row"
                )
            }
        } else {
            guard let discoveredLeaf = try fetch(
                aggregateLeafValidationDescriptor(
                    currentEpochID: currentEpochID,
                    after: cursor.lastLogicalID
                ),
                limit: 1,
                runtime: &runtime
            ).first else {
                return .moreWork(
                    request: request,
                    cursor: aggregateLeafRebuildCursor(from: cursor),
                    audit: runtime.audit
                )
            }
            switch try stableAggregateGroup(
                id: discoveredLeaf.id,
                currentEpochID: currentEpochID,
                runtime: &runtime
            ) {
            case let .resolved(rows) where rows.count == 1:
                leaf = rows[0]
            case let .resolved(rows) where rows.isEmpty:
                var next = cursor
                next.lastLogicalID = discoveredLeaf.id
                return .moreWork(
                    request: request,
                    cursor: next,
                    audit: runtime.audit
                )
            case .insufficientBudget:
                return .moreWork(
                    request: request,
                    cursor: cursor,
                    audit: runtime.audit
                )
            case .changedDuringRead:
                return .retry(
                    request: request,
                    cursor: cursor,
                    audit: runtime.audit,
                    category: "changed-discovered-aggregate-leaf"
                )
            case .oversized, .resolved(_):
                return .retry(
                    request: request,
                    cursor: cursor,
                    audit: runtime.audit,
                    category: "ambiguous-discovered-aggregate-leaf"
                )
            }
        }

        let memberIDs = Set(leaf.sessionIDs)
        let orderedMemberIDs = memberIDs.sorted { $0.uuidString < $1.uuidString }
        if let restoredState {
            let stateIsValid = restoredState.leafID == leaf.id
                && restoredState.memberIDs == orderedMemberIDs
                && restoredState.snapshotFingerprints.count
                    <= restoredState.memberIDs.count
                && restoredState.snapshotFingerprints.allSatisfy {
                    $0.utf8.count == 64 && $0.allSatisfy(\.isHexDigit)
                }
            guard stateIsValid else {
                try markAggregateLineageUnverified(from: leaf, runtime: &runtime)
                let changed = try saveIfNeeded(runtime: &runtime)
                var next = cursor
                // Restart this leaf from its durable predecessor. Advancing a
                // corrupt checkpoint would strand a v0 projection until a new
                // external generation happened to arrive.
                next.payload = nil
                return .moreWork(
                    request: request,
                    cursor: next,
                    audit: runtime.audit,
                    effects: changed ? [.refreshActivityProjection] : []
                )
            }
        }
        let structurallyValid = leaf.level == 1
            && (1...Constants.Jar.aggregateFanIn).contains(memberIDs.count)
            && leaf.childAggregateIDs.isEmpty
        guard structurallyValid else {
            try markAggregateLineageUnverified(from: leaf, runtime: &runtime)
            let changed = try saveIfNeeded(runtime: &runtime)
            var next = cursor
            next.lastLogicalID = leaf.id
            next.payload = nil
            return .moreWork(
                request: request,
                cursor: next,
                audit: runtime.audit,
                effects: changed ? [.refreshActivityProjection] : []
            )
        }

        var state = restoredState ?? AggregateLeafValidationState(
            leafID: leaf.id,
            memberIDs: orderedMemberIDs,
            snapshotFingerprints: []
        )
        let startedWithCompleteSnapshot = state.snapshotFingerprints.count
            == state.memberIDs.count
        let invalidationReserve = 64

        while state.snapshotFingerprints.count < state.memberIDs.count {
            let memberID = state.memberIDs[state.snapshotFingerprints.count]
            switch try aggregateLeafMemberToken(
                memberID: memberID,
                leafID: leaf.id,
                currentEpochID: currentEpochID,
                reservingRows: invalidationReserve,
                runtime: &runtime
            ) {
            case let .resolved(token):
                state.snapshotFingerprints.append(
                    aggregateLeafMemberFingerprint(token)
                )
            case .insufficientBudget:
                try markAggregateLineageUnverified(from: leaf, runtime: &runtime)
                let changed = try saveIfNeeded(runtime: &runtime)
                var next = cursor
                next.payload = try JSONEncoder().encode(state)
                return .moreWork(
                    request: request,
                    cursor: next,
                    audit: runtime.audit,
                    effects: changed ? [.refreshActivityProjection] : []
                )
            case .changedDuringRead:
                try markAggregateLineageUnverified(from: leaf, runtime: &runtime)
                let changed = try saveIfNeeded(runtime: &runtime)
                var next = cursor
                next.payload = try JSONEncoder().encode(state)
                return .retry(
                    request: request,
                    cursor: next,
                    audit: runtime.audit,
                    category: changed
                        ? "unstable-aggregate-leaf-source-invalidated"
                        : "unstable-aggregate-leaf-source"
                )
            case .invalid:
                try markAggregateLineageUnverified(from: leaf, runtime: &runtime)
                let changed = try saveIfNeeded(runtime: &runtime)
                var next = cursor
                next.lastLogicalID = leaf.id
                next.payload = nil
                return .moreWork(
                    request: request,
                    cursor: next,
                    audit: runtime.audit,
                    effects: changed ? [.refreshActivityProjection] : []
                )
            }
        }

        // A second bounded pass proves that a source observed in an earlier
        // slice did not change before this leaf becomes authoritative. A
        // mismatch restarts collection while the leaf and its ancestors remain
        // persistently invalidated.
        var verifiedSnapshots: [StudySessionSyncPolicy.ChangeToken] = []
        verifiedSnapshots.reserveCapacity(state.memberIDs.count)
        for index in state.memberIDs.indices {
            switch try aggregateLeafMemberToken(
                memberID: state.memberIDs[index],
                leafID: leaf.id,
                currentEpochID: currentEpochID,
                reservingRows: invalidationReserve,
                runtime: &runtime
            ) {
            case let .resolved(token):
                guard aggregateLeafMemberFingerprint(token)
                        == state.snapshotFingerprints[index]
                else {
                    state.snapshotFingerprints = []
                    try markAggregateLineageUnverified(from: leaf, runtime: &runtime)
                    let changed = try saveIfNeeded(runtime: &runtime)
                    var next = cursor
                    next.payload = try JSONEncoder().encode(state)
                    return .moreWork(
                        request: request,
                        cursor: next,
                        audit: runtime.audit,
                        effects: changed ? [.refreshActivityProjection] : []
                    )
                }
                verifiedSnapshots.append(token)
            case .insufficientBudget:
                // A final verification is meaningful only when every token is
                // checked in the same slice immediately before promotion.
                // Persisting a prefix would let member zero change while a
                // later slice resumes at member one. If collection consumed
                // this slice, checkpoint once so verification can start with a
                // fresh budget. If an already-complete checkpoint still cannot
                // fit, the leaf is too dense for one atomic pass: keep it v0
                // and apply durable exponential backoff instead of rereading
                // the same maximum-sized groups every 100 ms forever.
                try markAggregateLineageUnverified(from: leaf, runtime: &runtime)
                let changed = try saveIfNeeded(runtime: &runtime)
                var next = cursor
                next.payload = try JSONEncoder().encode(state)
                guard startedWithCompleteSnapshot else {
                    return .moreWork(
                        request: request,
                        cursor: next,
                        audit: runtime.audit,
                        effects: changed ? [.refreshActivityProjection] : []
                    )
                }
                return .retry(
                    request: request,
                    cursor: next,
                    audit: runtime.audit,
                    category: changed
                        ? "dense-aggregate-leaf-final-pass-invalidated"
                        : "dense-aggregate-leaf-final-pass"
                )
            case .changedDuringRead:
                state.snapshotFingerprints = []
                try markAggregateLineageUnverified(from: leaf, runtime: &runtime)
                let changed = try saveIfNeeded(runtime: &runtime)
                var next = cursor
                next.payload = try JSONEncoder().encode(state)
                return .retry(
                    request: request,
                    cursor: next,
                    audit: runtime.audit,
                    category: changed
                        ? "unstable-aggregate-leaf-verification-invalidated"
                        : "unstable-aggregate-leaf-verification"
                )
            case .invalid:
                try markAggregateLineageUnverified(from: leaf, runtime: &runtime)
                let changed = try saveIfNeeded(runtime: &runtime)
                var next = cursor
                next.lastLogicalID = leaf.id
                next.payload = nil
                return .moreWork(
                    request: request,
                    cursor: next,
                    audit: runtime.audit,
                    effects: changed ? [.refreshActivityProjection] : []
                )
            }
        }

        let expected = rebuiltLeaf(
            from: verifiedSnapshots.map(detachedSession),
            currentEpochID: currentEpochID
        )
        applyDerivedProjection(from: expected, to: leaf)
        switch try rederiveAggregateAncestors(from: leaf, runtime: &runtime) {
        case .resolved, .invalid:
            break
        case .insufficientBudget:
            // Re-prove every source in one later slice before promotion. The
            // leaf remains v0 while an ancestor exact read lacks budget.
            leaf.projectionValidationVersion = 0
            let changed = try saveIfNeeded(runtime: &runtime)
            var next = cursor
            next.payload = try JSONEncoder().encode(state)
            return .moreWork(
                request: request,
                cursor: next,
                audit: runtime.audit,
                effects: changed ? [.refreshActivityProjection] : []
            )
        case .changedDuringRead:
            leaf.projectionValidationVersion = 0
            let changed = try saveIfNeeded(runtime: &runtime)
            var next = cursor
            next.payload = try JSONEncoder().encode(state)
            return .retry(
                request: request,
                cursor: next,
                audit: runtime.audit,
                category: changed
                    ? "unstable-aggregate-lineage-invalidated"
                    : "unstable-aggregate-lineage"
            )
        }
        let changed = try saveIfNeeded(runtime: &runtime)

        var next = cursor
        next.lastLogicalID = leaf.id
        next.payload = nil
        return .moreWork(
            request: request,
            cursor: next,
            audit: runtime.audit,
            effects: changed ? [.refreshActivityProjection] : []
        )
    }

    /// Resolves one logical leaf member through exhaustive bounded membership
    /// and cardinality-checked source reads. The caller reserves enough of this
    /// slice for lineage invalidation. Same-count concurrent replacement is
    /// fenced by the full digest pass plus the newer-generation notification
    /// contract, not by either individual count query.
    func aggregateLeafMemberToken(
        memberID: UUID,
        leafID: UUID,
        currentEpochID: UUID?,
        reservingRows: Int,
        runtime: inout Runtime
    ) throws -> AggregateLeafMemberRead {
        switch try aggregateMembershipState(
            for: memberID,
            currentEpochID: currentEpochID,
            acceptingUnverifiedOwnerID: leafID,
            reservingRows: NonnegativeIntPolicy.adding(
                runtime.limits.maximumRowsPerFetch,
                max(0, reservingRows)
            ),
            runtime: &runtime
        ) {
        case .represented:
            break
        case .insufficientBudget:
            return .insufficientBudget
        case .changedDuringRead:
            return .changedDuringRead
        case .missing, .ambiguous, .oversized:
            return .invalid
        }

        switch try stableSessionGroup(
            id: memberID,
            currentEpochID: currentEpochID,
            reservingRows: reservingRows,
            runtime: &runtime
        ) {
        case let .resolved(rows):
            guard let canonical = StudySessionSyncPolicy.canonicalSession(
                from: rows
            ) else { return .invalid }
            return .resolved(StudySessionSyncPolicy.changeToken(for: canonical))
        case .oversized:
            return .invalid
        case .insufficientBudget:
            return .insufficientBudget
        case .changedDuringRead:
            return .changedDuringRead
        }
    }

    func aggregateLeafMemberFingerprint(
        _ token: StudySessionSyncPolicy.ChangeToken
    ) -> String {
        SHA256.hash(data: Data(token.stableFingerprint.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Rehydrates an immutable token as an unattached value so the existing
    /// leaf calculator remains the single definition of every derived field.
    /// Live Subject relationship values captured in the token take precedence
    /// over historical fallbacks, matching `displaySubject*` at read time.
    func detachedSession(
        _ token: StudySessionSyncPolicy.ChangeToken
    ) -> StudySession {
        StudySession(
            id: token.id,
            startAt: token.startAt,
            endAt: token.endAt,
            seconds: token.seconds,
            source: token.source,
            pebbleKind: token.pebbleKind,
            grams: token.grams,
            deviceDayKey: token.deviceDayKey,
            isBaked: token.isBaked,
            subjectNameSnapshot: token.subjectName.isEmpty
                ? token.subjectNameSnapshot
                : token.subjectName,
            subjectColorHexSnapshot: token.subjectColorHex.isEmpty
                ? token.subjectColorHexSnapshot
                : token.subjectColorHex,
            subjectIDSnapshot: token.subjectID ?? token.subjectIDSnapshot,
            rareRewardRuleVersion: token.rareRewardRuleVersion,
            rareRewardParticipated: token.rareRewardParticipated,
            rareRewardCreditedGrams: token.rareRewardCreditedGrams,
            rareRewardOutcomesRawValue: token.rareRewardOutcomesRawValue,
            dataEpochID: token.dataEpochID,
            syncRecordID: token.syncRecordID
        )
    }

    func aggregateLeafValidationDescriptor(
        currentEpochID: UUID?,
        after: UUID?
    ) -> FetchDescriptor<AggregatePebble> {
        let predicate: Predicate<AggregatePebble>
        switch (currentEpochID, after) {
        case let (epochID?, lastID?):
            predicate = #Predicate {
                $0.dataEpochID == epochID && $0.level == 1 && $0.id > lastID
            }
        case let (epochID?, nil):
            predicate = #Predicate {
                $0.dataEpochID == epochID && $0.level == 1
            }
        case let (nil, lastID?):
            predicate = #Predicate {
                $0.dataEpochID == nil && $0.level == 1 && $0.id > lastID
            }
        case (nil, nil):
            predicate = #Predicate { $0.dataEpochID == nil && $0.level == 1 }
        }
        return FetchDescriptor<AggregatePebble>(
            predicate: predicate,
            sortBy: [SortDescriptor(\AggregatePebble.id)]
        )
    }

    func applyDerivedProjection(
        from source: AggregatePebble,
        to destination: AggregatePebble
    ) {
        destination.dataEpochID = source.dataEpochID
        destination.createdAt = source.createdAt
        destination.level = source.level
        destination.pebbleCount = source.pebbleCount
        destination.childAggregateCount = source.childAggregateCount
        destination.grams = source.grams
        destination.measuredPebbleCount = source.measuredPebbleCount
        destination.manualPebbleCount = source.manualPebbleCount
        destination.goldPebbleCount = source.goldPebbleCount
        destination.prismPebbleCount = source.prismPebbleCount
        destination.colorMixJSON = source.colorMixJSON
        destination.subjectMixJSON = source.subjectMixJSON
        destination.periodStart = source.periodStart
        destination.periodEnd = source.periodEnd
        destination.replaceSessionIDs(source.sessionIDs)
        destination.replaceChildAggregateIDs(source.childAggregateIDs)
        destination.projectionValidationVersion =
            AggregateProjectionValidation.currentVersion
    }

    func rederiveAggregateAncestors(
        from leaf: AggregatePebble,
        runtime: inout Runtime
    ) throws -> AggregateLineageDerivation {
        var parentID = leaf.parentAggregateID
        var visited = Set<UUID>()
        for _ in 0 ..< 24 {
            guard let id = parentID else { return .resolved }
            guard visited.insert(id).inserted else {
                leaf.projectionValidationVersion = 0
                return .invalid
            }
            let parentRows: [AggregatePebble]
            switch try stableAggregateGroup(
                id: id,
                currentEpochID: leaf.dataEpochID,
                runtime: &runtime
            ) {
            case let .resolved(rows):
                parentRows = rows
            case .insufficientBudget:
                leaf.projectionValidationVersion = 0
                return .insufficientBudget
            case .changedDuringRead:
                leaf.projectionValidationVersion = 0
                return .changedDuringRead
            case .oversized:
                leaf.projectionValidationVersion = 0
                return .invalid
            }
            guard parentRows.count == 1, let parent = parentRows.first else {
                // A missing parent leaves this exact leaf as a safe root. A
                // duplicate parent is ambiguous and remains globally v0.
                guard !parentRows.isEmpty else { return .resolved }
                parentRows.forEach { $0.projectionValidationVersion = 0 }
                return .invalid
            }
            parentID = parent.parentAggregateID
            let childIDs = Set(parent.childAggregateIDs)
            guard childIDs.count == Constants.Jar.aggregateFanIn,
                  parent.id == JarAggregateRequest.deterministicID(
                    sourceIDs: Array(childIDs),
                    outputLevel: parent.level
                  )
            else {
                parent.projectionValidationVersion = 0
                return .invalid
            }

            var children: [AggregatePebble] = []
            children.reserveCapacity(childIDs.count)
            for childID in childIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                let rows: [AggregatePebble]
                switch try stableAggregateGroup(
                    id: childID,
                    currentEpochID: leaf.dataEpochID,
                    runtime: &runtime
                ) {
                case let .resolved(values):
                    rows = values
                case .insufficientBudget:
                    parent.projectionValidationVersion = 0
                    leaf.projectionValidationVersion = 0
                    return .insufficientBudget
                case .changedDuringRead:
                    parent.projectionValidationVersion = 0
                    leaf.projectionValidationVersion = 0
                    return .changedDuringRead
                case .oversized:
                    parent.projectionValidationVersion = 0
                    leaf.projectionValidationVersion = 0
                    return .invalid
                }
                guard rows.count == 1,
                      let child = rows.first,
                      child.parentAggregateID == parent.id,
                      child.projectionValidationVersion
                        == AggregateProjectionValidation.currentVersion
                else {
                    rows.forEach { $0.projectionValidationVersion = 0 }
                    parent.projectionValidationVersion = 0
                    return .invalid
                }
                children.append(child)
            }
            guard let calculation = StrataMath.aggregate(
                    sources: children.map(aggregateSource)
                  )
            else {
                parent.projectionValidationVersion = 0
                return .invalid
            }
            apply(calculation, to: parent)
        }
        // A cycle or impossible depth is a derived-data integrity failure.
        // Keeping the traversed root unverified makes every consumer lower-bound.
        leaf.projectionValidationVersion = 0
        return .invalid
    }

    func markAggregateLineageUnverified(
        from leaf: AggregatePebble,
        runtime: inout Runtime
    ) throws {
        leaf.projectionValidationVersion = 0
        var parentID = leaf.parentAggregateID
        var visited = Set<UUID>()
        for _ in 0 ..< 24 {
            guard let id = parentID, visited.insert(id).inserted else { return }
            let rows = try fetch(
                aggregateGroupDescriptor(id: id, currentEpochID: leaf.dataEpochID),
                limit: 2,
                runtime: &runtime
            )
            guard let parent = rows.first else { return }
            rows.forEach { $0.projectionValidationVersion = 0 }
            parentID = parent.parentAggregateID
        }
    }

    func rebuildMissingAggregateLeaves(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        currentEpochID: UUID?,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        guard runtime.limits.maximumRowsPerSlice >= 2 else {
            return .retry(
                request: request,
                cursor: cursor,
                audit: runtime.audit,
                category: "projection-rebuild-budget-too-small"
            )
        }

        let boundary: AggregateProjectionRebuildBoundary
        if let boundaryData = cursor.payload,
           let decoded = try? JSONDecoder().decode(
                AggregateProjectionRebuildBoundary.self,
                from: boundaryData
           ) {
            boundary = decoded
        } else {
            let scanState = cursor.payload.flatMap {
                try? JSONDecoder().decode(
                    AggregateRetentionBoundaryScanState.self,
                    from: $0
                )
            } ?? AggregateRetentionBoundaryScanState()
            switch try resolveAggregateRetentionBoundary(
                currentEpochID: currentEpochID,
                initialState: scanState,
                runtime: &runtime
            ) {
            case let .resolved(value):
                guard let oldestRetained = value else {
                    // Every current session fits in Home's normal loose
                    // projection; a partial aggregate would hide a completion.
                    return .moreWork(
                        request: request,
                        cursor: aggregateRollupCursor(from: cursor),
                        audit: runtime.audit
                    )
                }
                let resolvedBoundary = AggregateProjectionRebuildBoundary(
                    endAt: oldestRetained.endAt,
                    id: oldestRetained.id,
                    // Retained only for decoding an in-flight pre-release cursor.
                    startedWithoutProjection: false
                )
                var next = cursor
                next.lastLogicalID = nil
                next.payload = try JSONEncoder().encode(resolvedBoundary)
                return .moreWork(
                    request: request,
                    cursor: next,
                    audit: runtime.audit
                )
            case let .moreWork(state):
                var next = cursor
                next.lastLogicalID = nil
                next.payload = try JSONEncoder().encode(state)
                return .moreWork(
                    request: request,
                    cursor: next,
                    audit: runtime.audit
                )
            case let .unavailable(category):
                return .retry(
                    request: request,
                    cursor: cursor,
                    audit: runtime.audit,
                    category: category
                )
            }
        }

        // A small discovery page leaves enough room to prove at least one
        // maximum-sized session replica group, its exhaustive membership, and
        // a colliding aggregate ID in the same slice. Progress advances only
        // through IDs for which all of those decisions are closed.
        let availablePageBudget = runtime.limits.maximumRowsPerSlice
            - runtime.audit.totalRowsAccessed
        guard availablePageBudget >= 1 + runtime.limits.maximumRowsPerFetch * 3 else {
            return .retry(
                request: request,
                cursor: cursor,
                audit: runtime.audit,
                category: "projection-rebuild-boundary-budget-too-small"
            )
        }
        let pageLimit = min(
            16,
            runtime.limits.maximumRowsPerFetch,
            max(1, availablePageBudget - runtime.limits.maximumRowsPerFetch * 3)
        )
        let page = try fetch(
            projectionRebuildSessionPageDescriptor(
                currentEpochID: currentEpochID,
                after: cursor.lastLogicalID,
                olderThan: boundary
            ),
            limit: pageLimit,
            runtime: &runtime
        )
        guard !page.isEmpty else {
            return .moreWork(
                request: request,
                cursor: aggregateRollupCursor(from: cursor),
                audit: runtime.audit
            )
        }

        // The date predicate discovers IDs only. Each ID is exact-read across
        // the whole epoch and receives an exhaustive local ownership lookup
        // before the cursor can cross it. Dense replica groups therefore make
        // slower durable progress instead of pinning one page forever.
        var seenPageIDs = Set<UUID>()
        let pageIDs = page.compactMap { row in
            seenPageIDs.insert(row.id).inserted ? row.id : nil
        }
        var missing: [StudySession] = []
        var processedIDs: [UUID] = []
        var stoppedForBudget = false
        for id in pageIDs {
            switch try stableSessionGroup(
                id: id,
                currentEpochID: currentEpochID,
                // Membership plus an exact deterministic-leaf collision read.
                reservingRows: runtime.limits.maximumRowsPerFetch * 2,
                runtime: &runtime
            ) {
            case .oversized:
                return .retry(
                    request: request,
                    cursor: cursor,
                    audit: runtime.audit,
                    category: "oversized-projection-rebuild-session-group"
                )
            case .insufficientBudget:
                stoppedForBudget = true
            case .changedDuringRead:
                if processedIDs.isEmpty {
                    return .retry(
                        request: request,
                        cursor: cursor,
                        audit: runtime.audit,
                        category: "changed-projection-rebuild-session-group"
                    )
                }
                stoppedForBudget = true
            case let .resolved(exact):
                guard let session = StudySessionSyncPolicy.canonicalSession(from: exact),
                      session.endAt < boundary.endAt
                        || (session.endAt == boundary.endAt
                            && session.id.uuidString < boundary.id.uuidString)
                else {
                    processedIDs.append(id)
                    continue
                }
                switch try aggregateMembershipState(
                    for: session.id,
                    currentEpochID: currentEpochID,
                    reservingRows: runtime.limits.maximumRowsPerFetch,
                    runtime: &runtime
                ) {
                case .represented:
                    processedIDs.append(id)
                case .missing:
                    missing.append(session)
                    processedIDs.append(id)
                case .ambiguous:
                    return .retry(
                        request: request,
                        cursor: cursor,
                        audit: runtime.audit,
                        category: "ambiguous-local-projection-membership"
                    )
                case .oversized:
                    return .retry(
                        request: request,
                        cursor: cursor,
                        audit: runtime.audit,
                        category: "oversized-local-projection-membership"
                    )
                case .insufficientBudget:
                    stoppedForBudget = true
                case .changedDuringRead:
                    return .retry(
                        request: request,
                        cursor: cursor,
                        audit: runtime.audit,
                        category: "changed-local-projection-membership"
                    )
                }
            }
            if stoppedForBudget { break }
        }
        guard let lastProcessedID = processedIDs.last else {
            return .retry(
                request: request,
                cursor: cursor,
                audit: runtime.audit,
                category: "projection-rebuild-exact-read-budget"
            )
        }
        missing.sort { $0.id.uuidString < $1.id.uuidString }
        let candidateGroups = sessionGroups(from: missing)
        let processedAllPageIDs = processedIDs.count == pageIDs.count

        guard !candidateGroups.isEmpty else {
            var next = cursor
            if processedAllPageIDs && page.count < pageLimit {
                return .moreWork(
                    request: request,
                    cursor: aggregateRollupCursor(from: cursor),
                    audit: runtime.audit
                )
            }
            next.lastLogicalID = lastProcessedID
            return .moreWork(
                request: request,
                cursor: next,
                audit: runtime.audit
            )
        }

        let candidates = candidateGroups.map {
            rebuiltLeaf(from: $0, currentEpochID: currentEpochID)
        }
        var rebuilt: [AggregatePebble] = []
        for (group, aggregate) in zip(candidateGroups, candidates) {
            switch try stableAggregateGroup(
                id: aggregate.id,
                currentEpochID: currentEpochID,
                runtime: &runtime
            ) {
            case .oversized:
                return .retry(
                    request: request,
                    cursor: cursor,
                    audit: runtime.audit,
                    category: "oversized-projection-rebuild-leaf-group"
                )
            case .insufficientBudget:
                return .moreWork(
                    request: request,
                    cursor: cursor,
                    audit: runtime.audit
                )
            case .changedDuringRead:
                return .retry(
                    request: request,
                    cursor: cursor,
                    audit: runtime.audit,
                    category: "changed-projection-rebuild-leaf-group"
                )
            case let .resolved(existing):
                guard existing.isEmpty else {
                    let expectedMembership = Set(group.map(\.id))
                    guard existing.allSatisfy({
                        Set($0.sessionIDs) == expectedMembership
                            && $0.projectionValidationVersion
                                == AggregateProjectionValidation.currentVersion
                    }) else {
                        // The ID is a hash of this exact membership. Seeing it
                        // with a different or invalid payload is a conflict,
                        // not a safe insertion replay.
                        return .retry(
                            request: request,
                            cursor: cursor,
                            audit: runtime.audit,
                            category: "conflicting-projection-rebuild-leaf"
                        )
                    }
                    continue
                }
                rebuilt.append(aggregate)
            }
        }

        // `run(.aggregates)` holds the process-wide projection mutation gate
        // from the exhaustive ownership lookup above through this insertion.
        // No foreground aggregate can enter the former check/insert gap.
        rebuilt.forEach(modelContext.insert)
        let changed = try saveIfNeeded(runtime: &runtime)

        var next = cursor
        next.lastLogicalID = lastProcessedID
        return .moreWork(
            request: request,
            cursor: next,
            audit: runtime.audit,
            effects: changed ? [.refreshActivityProjection] : []
        )
    }

    func sessionGroups(
        from sessions: [StudySession]
    ) -> [[StudySession]] {
        stride(
            from: 0,
            to: sessions.count,
            by: Constants.Jar.aggregateFanIn
        ).map { start in
            Array(sessions[start ..< min(
                start + Constants.Jar.aggregateFanIn,
                sessions.count
            )])
        }
    }

    func newestSessionDescriptor(
        currentEpochID: UUID?,
        after cursor: SessionPhysicalCursor? = nil
    ) -> FetchDescriptor<StudySession> {
        let predicate: Predicate<StudySession>
        if let currentEpochID, let cursor {
            let cursorEnd = cursor.endAt
            let cursorID = cursor.id
            let cursorRecordID = cursor.syncRecordID
            predicate = #Predicate {
                $0.dataEpochID == currentEpochID
                    && ($0.endAt < cursorEnd
                        || ($0.endAt == cursorEnd && $0.id < cursorID)
                        || ($0.endAt == cursorEnd && $0.id == cursorID
                            && $0.syncRecordID < cursorRecordID))
            }
        } else if let currentEpochID {
            predicate = #Predicate { $0.dataEpochID == currentEpochID }
        } else if let cursor {
            let cursorEnd = cursor.endAt
            let cursorID = cursor.id
            let cursorRecordID = cursor.syncRecordID
            predicate = #Predicate {
                $0.dataEpochID == nil
                    && ($0.endAt < cursorEnd
                        || ($0.endAt == cursorEnd && $0.id < cursorID)
                        || ($0.endAt == cursorEnd && $0.id == cursorID
                            && $0.syncRecordID < cursorRecordID))
            }
        } else {
            predicate = #Predicate { $0.dataEpochID == nil }
        }
        return FetchDescriptor<StudySession>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\StudySession.endAt, order: .reverse),
                SortDescriptor(\StudySession.id, order: .reverse),
                SortDescriptor(\StudySession.syncRecordID, order: .reverse)
            ]
        )
    }

    func projectionRebuildSessionPageDescriptor(
        currentEpochID: UUID?,
        after: UUID?,
        olderThan boundary: AggregateProjectionRebuildBoundary
    ) -> FetchDescriptor<StudySession> {
        let boundaryDate = boundary.endAt
        let boundaryID = boundary.id
        let predicate: Predicate<StudySession>
        switch (currentEpochID, after) {
        case let (epochID?, lastID?):
            predicate = #Predicate {
                $0.dataEpochID == epochID
                    && ($0.endAt < boundaryDate
                        || ($0.endAt == boundaryDate && $0.id < boundaryID))
                    && $0.id > lastID
            }
        case let (epochID?, nil):
            predicate = #Predicate {
                $0.dataEpochID == epochID
                    && ($0.endAt < boundaryDate
                        || ($0.endAt == boundaryDate && $0.id < boundaryID))
            }
        case let (nil, lastID?):
            predicate = #Predicate {
                $0.dataEpochID == nil
                    && ($0.endAt < boundaryDate
                        || ($0.endAt == boundaryDate && $0.id < boundaryID))
                    && $0.id > lastID
            }
        case (nil, nil):
            predicate = #Predicate {
                $0.dataEpochID == nil
                    && ($0.endAt < boundaryDate
                        || ($0.endAt == boundaryDate && $0.id < boundaryID))
            }
        }
        return FetchDescriptor<StudySession>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\StudySession.id),
                SortDescriptor(\StudySession.syncRecordID)
            ]
        )
    }

    enum AggregateMembershipState {
        case represented
        case missing
        case ambiguous
        case oversized
        case insufficientBudget
        case changedDuringRead
    }

    func aggregateMembershipState(
        for sessionID: UUID,
        currentEpochID: UUID?,
        acceptingUnverifiedOwnerID: UUID? = nil,
        reservingRows: Int = 0,
        runtime: inout Runtime
    ) throws -> AggregateMembershipState {
        let encodedID = sessionID.uuidString
        let predicate: Predicate<AggregatePebble>
        if let currentEpochID {
            predicate = #Predicate { aggregate in
                aggregate.dataEpochID == currentEpochID
                    && aggregate.sessionIDsJSON.contains(encodedID)
            }
        } else {
            predicate = #Predicate { aggregate in
                aggregate.dataEpochID == nil
                    && aggregate.sessionIDsJSON.contains(encodedID)
            }
        }
        let descriptor = FetchDescriptor<AggregatePebble>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\AggregatePebble.id),
                SortDescriptor(\AggregatePebble.createdAt)
            ]
        )
        let countBefore = try fetchCount(descriptor, runtime: &runtime)
        guard countBefore <= runtime.limits.maximumRowsPerFetch else {
            return .oversized
        }
        guard countBefore <= runtime.limits.maximumRowsPerSlice
                - runtime.audit.totalRowsAccessed
                - max(0, reservingRows)
        else { return .insufficientBudget }
        let candidates = try fetch(
            descriptor,
            limit: runtime.limits.maximumRowsPerFetch,
            runtime: &runtime
        )
        let countAfter = try fetchCount(descriptor, runtime: &runtime)
        guard ExactReplicaReadPolicy.isStable(
            countBefore: countBefore,
            fetchedCount: candidates.count,
            countAfter: countAfter,
            maximumSupportedCount: runtime.limits.maximumRowsPerFetch
        ) else { return .changedDuringRead }

        let owners = candidates.filter {
            Set($0.sessionIDs).contains(sessionID)
        }
        guard !owners.isEmpty else { return .missing }
        let ownerIDs = Set(owners.map(\.id))
        guard ownerIDs.count == 1 else { return .ambiguous }
        if let acceptingUnverifiedOwnerID,
           ownerIDs == Set([acceptingUnverifiedOwnerID]) {
            return .represented
        }
        guard owners.allSatisfy({
                $0.projectionValidationVersion
                    == AggregateProjectionValidation.currentVersion
              }) else {
            // An invalidated or migrated owner must be repaired in phase one;
            // treating it as absent would allow a second leaf to claim the same
            // logical completion.
            return .ambiguous
        }
        return .represented
    }

    func rebuiltLeaf(
        from sessions: [StudySession],
        currentEpochID: UUID?
    ) -> AggregatePebble {
        let unique = StudySessionSyncPolicy.canonicalSessions(from: sessions)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let rewards = RareRewardCounts.total(unique.map(\.rareRewardCounts))
        let completionDates = unique.map(\.endAt)
        let subjectMix = StrataMath.mergedSubjectMix(unique.map {
            [AggregateSubjectFraction(
                name: $0.displaySubjectName,
                colorHex: $0.displaySubjectColorHex,
                pebbleCount: 1
            )]
        })
        return AggregatePebble(
            id: JarAggregateRequest.deterministicID(
                sourceIDs: unique.map(\.id),
                outputLevel: 1
            ),
            createdAt: completionDates.max() ?? .distantPast,
            level: 1,
            pebbleCount: unique.count,
            grams: HomeProjectionPolicy.saturatingNonnegativeSum(unique.map(\.grams)),
            measuredPebbleCount: unique.filter(\.source.isMeasured).count,
            manualPebbleCount: unique.filter { !$0.source.isMeasured }.count,
            goldPebbleCount: rewards.goldCount,
            prismPebbleCount: rewards.prismCount,
            colorMixJSON: StrataMath.encodeColorMix(
                StrataMath.colorMix(hexColors: unique.map(\.displaySubjectColorHex))
            ),
            subjectMixJSON: StrataMath.encodeSubjectMix(subjectMix),
            periodStart: completionDates.min() ?? .distantPast,
            periodEnd: completionDates.max() ?? .distantPast,
            sessionIDs: unique.map(\.id),
            dataEpochID: currentEpochID
        )
    }

    /// Phase two performs decimal carry over local roots, one deterministic
    /// parent per save. Children and parent share the local store, so their
    /// backlink transaction is atomic; a stale checkpoint merely recomputes
    /// the next still-root group.
    func rollUpRebuiltAggregateRoots(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        currentEpochID: UUID?,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        let minimumLevel = max(1, cursor.offset)
        let nextDescriptor = aggregateRootDescriptor(
            currentEpochID: currentEpochID,
            minimumLevel: minimumLevel
        )
        guard let nextRoot = try fetch(
            nextDescriptor,
            limit: 1,
            runtime: &runtime
        ).first else {
            return .completed(request: request, audit: runtime.audit)
        }
        let level = max(minimumLevel, nextRoot.level)
        let levelDescriptor = aggregateRootDescriptor(
            currentEpochID: currentEpochID,
            level: level
        )
        let rootCount = try fetchCount(levelDescriptor, runtime: &runtime)
        guard rootCount >= Constants.Jar.aggregateFanIn else {
            guard level < Int.max else {
                return .completed(request: request, audit: runtime.audit)
            }
            var next = cursor
            next.offset = level + 1
            return .moreWork(
                request: request,
                cursor: next,
                audit: runtime.audit
            )
        }

        let selected = try fetch(
            levelDescriptor,
            limit: Constants.Jar.aggregateFanIn,
            runtime: &runtime
        )
        guard selected.count == Constants.Jar.aggregateFanIn,
              Set(selected.map(\.id)).count == Constants.Jar.aggregateFanIn,
              let calculation = StrataMath.aggregate(
                sources: selected.map(aggregateSource)
              ) else {
            return .retry(
                request: request,
                cursor: cursor,
                audit: runtime.audit,
                category: "invalid-projection-rollup-group"
            )
        }
        let parentID = JarAggregateRequest.deterministicID(
            sourceIDs: selected.map(\.id),
            outputLevel: calculation.level
        )
        let existingParents: [AggregatePebble]
        switch try stableAggregateGroup(
            id: parentID,
            currentEpochID: currentEpochID,
            runtime: &runtime
        ) {
        case .oversized:
            return .retry(
                request: request,
                cursor: cursor,
                audit: runtime.audit,
                category: "oversized-projection-rollup-parent-group"
            )
        case .insufficientBudget:
            return .moreWork(
                request: request,
                cursor: cursor,
                audit: runtime.audit
            )
        case .changedDuringRead:
            return .retry(
                request: request,
                cursor: cursor,
                audit: runtime.audit,
                category: "changed-projection-rollup-parent-group"
            )
        case let .resolved(rows):
            existingParents = rows
        }
        let selectedIDs = Set(selected.map(\.id))
        guard existingParents.allSatisfy({ parent in
            let children = Set(parent.childAggregateIDs)
            return children.isEmpty || children == selectedIDs
        }) else {
            return .retry(
                request: request,
                cursor: cursor,
                audit: runtime.audit,
                category: "conflicting-projection-rollup-parent"
            )
        }

        let parent: AggregatePebble
        if let canonical = existingParents.first {
            parent = canonical
            apply(calculation, to: parent)
            for duplicate in existingParents.dropFirst() {
                modelContext.delete(duplicate)
            }
        } else {
            parent = AggregatePebble(
                id: parentID,
                createdAt: selected.map(\.createdAt).max() ?? .distantPast,
                level: calculation.level,
                pebbleCount: calculation.pebbleCount,
                childAggregateCount: calculation.childAggregateCount,
                grams: calculation.grams,
                measuredPebbleCount: calculation.measuredPebbleCount,
                manualPebbleCount: calculation.manualPebbleCount,
                goldPebbleCount: calculation.goldPebbleCount,
                prismPebbleCount: calculation.prismPebbleCount,
                colorMixJSON: StrataMath.encodeColorMix(calculation.colorMix),
                subjectMixJSON: StrataMath.encodeSubjectMix(calculation.subjectMix),
                periodStart: calculation.periodStart,
                periodEnd: calculation.periodEnd,
                childAggregateIDs: calculation.childAggregateIDs,
                dataEpochID: currentEpochID
            )
            modelContext.insert(parent)
        }
        selected.forEach { $0.parentAggregateID = parentID }
        let changed = try saveIfNeeded(runtime: &runtime)

        var next = cursor
        next.offset = level
        return .moreWork(
            request: request,
            cursor: next,
            audit: runtime.audit,
            effects: changed ? [.refreshActivityProjection] : []
        )
    }

    func aggregateRootDescriptor(
        currentEpochID: UUID?,
        minimumLevel: Int
    ) -> FetchDescriptor<AggregatePebble> {
        let validationVersion = AggregateProjectionValidation.currentVersion
        let predicate: Predicate<AggregatePebble>
        if let currentEpochID {
            predicate = #Predicate { aggregate in
                aggregate.dataEpochID == currentEpochID
                    && aggregate.parentAggregateID == nil
                    && aggregate.level >= minimumLevel
                    && aggregate.projectionValidationVersion == validationVersion
            }
        } else {
            predicate = #Predicate { aggregate in
                aggregate.dataEpochID == nil
                    && aggregate.parentAggregateID == nil
                    && aggregate.level >= minimumLevel
                    && aggregate.projectionValidationVersion == validationVersion
            }
        }
        return FetchDescriptor<AggregatePebble>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\AggregatePebble.level),
                SortDescriptor(\AggregatePebble.id)
            ]
        )
    }

    func aggregateRootDescriptor(
        currentEpochID: UUID?,
        level: Int
    ) -> FetchDescriptor<AggregatePebble> {
        let validationVersion = AggregateProjectionValidation.currentVersion
        let predicate: Predicate<AggregatePebble>
        if let currentEpochID {
            predicate = #Predicate { aggregate in
                aggregate.dataEpochID == currentEpochID
                    && aggregate.parentAggregateID == nil
                    && aggregate.level == level
                    && aggregate.projectionValidationVersion == validationVersion
            }
        } else {
            predicate = #Predicate { aggregate in
                aggregate.dataEpochID == nil
                    && aggregate.parentAggregateID == nil
                    && aggregate.level == level
                    && aggregate.projectionValidationVersion == validationVersion
            }
        }
        return FetchDescriptor<AggregatePebble>(
            predicate: predicate,
            sortBy: [SortDescriptor(\AggregatePebble.id)]
        )
    }

    func aggregateSource(_ aggregate: AggregatePebble) -> AggregateSource {
        AggregateSource(
            id: aggregate.id,
            level: aggregate.level,
            pebbleCount: aggregate.pebbleCount,
            childAggregateCount: aggregate.childAggregateCount,
            grams: aggregate.grams,
            radius: StrataMath.aggregateRadius(level: aggregate.level),
            colorMix: aggregate.colorMix,
            subjectMix: aggregate.subjectMix,
            periodStart: aggregate.periodStart,
            periodEnd: aggregate.periodEnd,
            sessionIDs: aggregate.sessionIDs,
            measuredPebbleCount: aggregate.measuredPebbleCount,
            manualPebbleCount: aggregate.manualPebbleCount,
            goldPebbleCount: aggregate.goldPebbleCount,
            prismPebbleCount: aggregate.prismPebbleCount
        )
    }

    func apply(
        _ calculation: AggregateCalculation,
        to aggregate: AggregatePebble
    ) {
        aggregate.createdAt = calculation.periodEnd
        aggregate.level = calculation.level
        aggregate.pebbleCount = calculation.pebbleCount
        aggregate.childAggregateCount = calculation.childAggregateCount
        aggregate.grams = calculation.grams
        aggregate.measuredPebbleCount = calculation.measuredPebbleCount
        aggregate.manualPebbleCount = calculation.manualPebbleCount
        aggregate.goldPebbleCount = calculation.goldPebbleCount
        aggregate.prismPebbleCount = calculation.prismPebbleCount
        aggregate.colorMixJSON = StrataMath.encodeColorMix(calculation.colorMix)
        aggregate.subjectMixJSON = StrataMath.encodeSubjectMix(calculation.subjectMix)
        aggregate.periodStart = calculation.periodStart
        aggregate.periodEnd = calculation.periodEnd
        aggregate.replaceSessionIDs(calculation.sessionIDs)
        aggregate.replaceChildAggregateIDs(calculation.childAggregateIDs)
        aggregate.projectionValidationVersion = AggregateProjectionValidation.currentVersion
    }

    func aggregateLeafValidationCursor(
        from cursor: SyncMaintenanceCursor
    ) -> SyncMaintenanceCursor {
        var next = cursor
        next.phase = 1
        next.lastLogicalID = nil
        next.offset = 0
        next.payload = nil
        return next
    }

    func aggregateLeafRebuildCursor(
        from cursor: SyncMaintenanceCursor
    ) -> SyncMaintenanceCursor {
        var next = cursor
        next.phase = 2
        next.lastLogicalID = nil
        next.offset = 0
        next.payload = nil
        return next
    }

    func aggregateRollupCursor(
        from cursor: SyncMaintenanceCursor
    ) -> SyncMaintenanceCursor {
        var next = cursor
        next.phase = 3
        next.lastLogicalID = nil
        next.offset = 1
        next.payload = nil
        return next
    }

    func aggregatePageDescriptor(
        currentEpochID: UUID?,
        after: UUID?
    ) -> FetchDescriptor<AggregatePebble> {
        let predicate: Predicate<AggregatePebble>
        switch (currentEpochID, after) {
        case let (epochID?, lastID?):
            predicate = #Predicate {
                $0.dataEpochID == epochID && $0.id > lastID
            }
        case let (epochID?, nil):
            predicate = #Predicate { $0.dataEpochID == epochID }
        case let (nil, lastID?):
            predicate = #Predicate {
                $0.dataEpochID == nil && $0.id > lastID
            }
        case (nil, nil):
            predicate = #Predicate { $0.dataEpochID == nil }
        }
        return FetchDescriptor<AggregatePebble>(
            predicate: predicate,
            sortBy: [SortDescriptor(\AggregatePebble.id)]
        )
    }

    func aggregateGroupDescriptor(
        id: UUID,
        currentEpochID: UUID?
    ) -> FetchDescriptor<AggregatePebble> {
        let predicate: Predicate<AggregatePebble>
        if let currentEpochID {
            predicate = #Predicate {
                $0.id == id && $0.dataEpochID == currentEpochID
            }
        } else {
            predicate = #Predicate {
                $0.id == id && $0.dataEpochID == nil
            }
        }
        return FetchDescriptor<AggregatePebble>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\AggregatePebble.level, order: .reverse),
                SortDescriptor(\AggregatePebble.createdAt, order: .reverse)
            ]
        )
    }

    func normalizeAggregateGroup(_ values: [AggregatePebble]) {
        guard let canonical = values.max(by: { lhs, rhs in
            if lhs.level != rhs.level { return lhs.level < rhs.level }
            return lhs.createdAt < rhs.createdAt
        }) else { return }
        canonical.level = max(1, values.map(\.level).max() ?? 1)
        canonical.pebbleCount = max(0, values.map(\.pebbleCount).max() ?? 0)
        canonical.grams = max(0, values.map(\.grams).max() ?? 0)
        canonical.measuredPebbleCount = max(
            0,
            values.map(\.measuredPebbleCount).max() ?? 0
        )
        canonical.manualPebbleCount = max(
            0,
            values.map(\.manualPebbleCount).max() ?? 0
        )
        canonical.goldPebbleCount = max(0, values.map(\.goldPebbleCount).max() ?? 0)
        canonical.prismPebbleCount = max(0, values.map(\.prismPebbleCount).max() ?? 0)
        canonical.periodStart = values.map(\.periodStart).min() ?? canonical.periodStart
        canonical.periodEnd = values.map(\.periodEnd).max() ?? canonical.periodEnd
        canonical.replaceSessionIDs(values.flatMap(\.sessionIDs))
        canonical.replaceChildAggregateIDs(values.flatMap(\.childAggregateIDs))
        if canonical.colorMixJSON == "[]" {
            canonical.colorMixJSON = values
                .map(\.colorMixJSON)
                .filter { $0 != "[]" }
                .sorted()
                .first ?? "[]"
        }
        if canonical.subjectMixJSON == "[]" {
            canonical.subjectMixJSON = values
                .map(\.subjectMixJSON)
                .filter { $0 != "[]" }
                .sorted()
                .first ?? "[]"
        }
        canonical.parentAggregateID = values
            .compactMap(\.parentAggregateID)
            .sorted { $0.uuidString < $1.uuidString }
            .first
        for value in values where value !== canonical {
            modelContext.delete(value)
        }
    }
}

// MARK: - Known-stale physical compaction

private extension SyncMaintenanceSliceWorker {
    /// Cursor phases: 0 enumerates non-winning markers, 1 deletes one known
    /// stale epoch across every activity model, and 2 removes legacy nil rows
    /// only when a winning marker exists. Unknown non-nil epochs are never a
    /// deletion predicate.
    func compactStaleEpochs(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        winningMarker: ActivityResetSnapshot?,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        switch cursor.phase {
        case 1:
            guard let target = cursor.targetEpochID else {
                throw SyncMaintenanceError.invalidCursorPayload
            }
            return try deleteEpochAcrossModels(
                request: request,
                cursor: cursor,
                epochID: target,
                isLegacy: false,
                runtime: &runtime
            )
        case 2:
            guard winningMarker != nil else {
                return .completed(request: request, audit: runtime.audit)
            }
            return try deleteEpochAcrossModels(
                request: request,
                cursor: cursor,
                epochID: nil,
                isLegacy: true,
                runtime: &runtime
            )
        default:
            return try selectNextStaleMarker(
                request: request,
                cursor: cursor,
                winningMarker: winningMarker,
                runtime: &runtime
            )
        }
    }

    func selectNextStaleMarker(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        winningMarker: ActivityResetSnapshot?,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        let pageLimit = runtime.limits.maximumRowsPerFetch
        var descriptor = ActivityResetPolicy.currentMarkerDescriptor(
            now: runtime.now,
            fetchLimit: pageLimit
        )
        // Marker enumeration is read-only, so offset pagination is stable for
        // this generation. Any imported marker increments the generation and
        // invalidates the cursor before another slice is applied.
        guard cursor.offset >= 0 else {
            throw SyncMaintenanceError.invalidCursorPayload
        }
        descriptor.fetchOffset = cursor.offset
        let page = try fetch(descriptor, limit: pageLimit, runtime: &runtime)
        if let selectedOffset = page.firstIndex(where: {
            $0.epochID != winningMarker?.epochID
        }) {
            var next = cursor
            next.phase = 1
            let pageAdvance = NonnegativeIntPolicy.next(after: selectedOffset)
            guard cursor.offset <= Int.max - pageAdvance else {
                throw SyncMaintenanceError.invalidCursorPayload
            }
            next.offset = cursor.offset + pageAdvance
            next.secondaryOffset = 0
            next.targetEpochID = page[selectedOffset].epochID
            return .moreWork(
                request: request,
                cursor: next,
                audit: runtime.audit
            )
        }

        if page.count == pageLimit {
            var next = cursor
            guard cursor.offset <= Int.max - page.count else {
                throw SyncMaintenanceError.invalidCursorPayload
            }
            next.offset = cursor.offset + page.count
            return .moreWork(
                request: request,
                cursor: next,
                audit: runtime.audit
            )
        }
        guard winningMarker != nil else {
            return .completed(request: request, audit: runtime.audit)
        }
        var next = cursor
        next.phase = 2
        next.secondaryOffset = 0
        next.targetEpochID = nil
        return .moreWork(
            request: request,
            cursor: next,
            audit: runtime.audit
        )
    }

    func deleteEpochAcrossModels(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        epochID: UUID?,
        isLegacy: Bool,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        var modelIndex = cursor.secondaryOffset
        guard modelIndex >= 0 else {
            throw SyncMaintenanceError.invalidCursorPayload
        }
        // Prefs is deliberately excluded. Its epoch scopes only activity
        // counters; reversible settings are resolved across epochs and source
        // replicas remain read-only rather than being folded into one row.
        let modelCount = request.includesRareRewardLedgerMaintenance ? 10 : 8
        while modelIndex < modelCount {
            let deleted = try deleteStaleBatch(
                modelIndex: modelIndex,
                epochID: epochID,
                isLegacy: isLegacy,
                runtime: &runtime
            )
            if deleted > 0 {
                _ = try saveIfNeeded(runtime: &runtime)
                var next = cursor
                // Re-query the same predicate from the beginning after a full
                // page delete. Never advance an offset through a mutating set.
                next.secondaryOffset = deleted == runtime.limits.maximumRowsPerFetch
                    ? modelIndex
                    : modelIndex + 1
                if next.secondaryOffset >= modelCount {
                    if isLegacy {
                        return .completed(
                            request: request,
                            audit: runtime.audit,
                            effects: [.refreshActivityProjection, .reevaluateLocalFocus]
                        )
                    }
                    next.phase = 0
                    next.secondaryOffset = 0
                    next.targetEpochID = nil
                }
                return .moreWork(
                    request: request,
                    cursor: next,
                    audit: runtime.audit,
                    effects: [.refreshActivityProjection, .reevaluateLocalFocus]
                )
            }
            modelIndex += 1
        }

        if isLegacy {
            return .completed(request: request, audit: runtime.audit)
        }
        var next = cursor
        next.phase = 0
        next.secondaryOffset = 0
        next.targetEpochID = nil
        return .moreWork(
            request: request,
            cursor: next,
            audit: runtime.audit
        )
    }

    func deleteStaleBatch(
        modelIndex: Int,
        epochID: UUID?,
        isLegacy: Bool,
        runtime: inout Runtime
    ) throws -> Int {
        let limit = runtime.limits.maximumRowsPerFetch
        switch modelIndex {
        case 0:
            let predicate: Predicate<StudySession> = isLegacy
                ? #Predicate { $0.dataEpochID == nil }
                : #Predicate { $0.dataEpochID == epochID }
            let rows = try fetch(
                FetchDescriptor<StudySession>(predicate: predicate),
                limit: limit,
                runtime: &runtime
            )
            rows.forEach(modelContext.delete)
            return rows.count
        case 1:
            let predicate: Predicate<AchievementStone> = isLegacy
                ? #Predicate { $0.dataEpochID == nil }
                : #Predicate { $0.dataEpochID == epochID }
            let rows = try fetch(
                FetchDescriptor<AchievementStone>(predicate: predicate),
                limit: limit,
                runtime: &runtime
            )
            rows.forEach(modelContext.delete)
            return rows.count
        case 2:
            let predicate: Predicate<AggregatePebble> = isLegacy
                ? #Predicate { $0.dataEpochID == nil }
                : #Predicate { $0.dataEpochID == epochID }
            let rows = try fetch(
                FetchDescriptor<AggregatePebble>(predicate: predicate),
                limit: limit,
                runtime: &runtime
            )
            rows.forEach(modelContext.delete)
            return rows.count
        case 3:
            let predicate: Predicate<Stratum> = isLegacy
                ? #Predicate { $0.dataEpochID == nil }
                : #Predicate { $0.dataEpochID == epochID }
            let rows = try fetch(
                FetchDescriptor<Stratum>(predicate: predicate),
                limit: limit,
                runtime: &runtime
            )
            rows.forEach(modelContext.delete)
            return rows.count
        case 4:
            let predicate: Predicate<Bedrock> = isLegacy
                ? #Predicate { $0.dataEpochID == nil }
                : #Predicate { $0.dataEpochID == epochID }
            let rows = try fetch(
                FetchDescriptor<Bedrock>(predicate: predicate),
                limit: limit,
                runtime: &runtime
            )
            rows.forEach(modelContext.delete)
            return rows.count
        case 5:
            let predicate: Predicate<GachaState> = isLegacy
                ? #Predicate { $0.dataEpochID == nil }
                : #Predicate { $0.dataEpochID == epochID }
            let rows = try fetch(
                FetchDescriptor<GachaState>(predicate: predicate),
                limit: limit,
                runtime: &runtime
            )
            rows.forEach(modelContext.delete)
            return rows.count
        case 6:
            let predicate: Predicate<SyncedFocusTimer> = isLegacy
                ? #Predicate { $0.dataEpochID == nil }
                : #Predicate { $0.dataEpochID == epochID }
            let rows = try fetch(
                FetchDescriptor<SyncedFocusTimer>(predicate: predicate),
                limit: limit,
                runtime: &runtime
            )
            rows.forEach(modelContext.delete)
            return rows.count
        case 7:
            let predicate: Predicate<FocusTimerDeviceClaim> = isLegacy
                ? #Predicate { $0.dataEpochID == nil }
                : #Predicate { $0.dataEpochID == epochID }
            let rows = try fetch(
                FetchDescriptor<FocusTimerDeviceClaim>(predicate: predicate),
                limit: limit,
                runtime: &runtime
            )
            rows.forEach(modelContext.delete)
            return rows.count
        case 8:
            let predicate: Predicate<RareRewardPendingCommit> = isLegacy
                ? #Predicate { $0.dataEpochID == nil }
                : #Predicate { $0.dataEpochID == epochID }
            let rows = try fetch(
                FetchDescriptor<RareRewardPendingCommit>(predicate: predicate),
                limit: limit,
                runtime: &runtime
            )
            rows.forEach(modelContext.delete)
            return rows.count
        case 9:
            let predicate: Predicate<RareRewardLedgerCursor> = isLegacy
                ? #Predicate { $0.dataEpochID == nil }
                : #Predicate { $0.dataEpochID == epochID }
            let rows = try fetch(
                FetchDescriptor<RareRewardLedgerCursor>(predicate: predicate),
                limit: limit,
                runtime: &runtime
            )
            rows.forEach(modelContext.delete)
            return rows.count
        default:
            preconditionFailure("Unknown stale-compaction model index")
        }
    }
}

// MARK: - Focus logical identity

private struct FocusMaintenanceQuarantine: Codable {
    private static let maximumRememberedSessionIDs = 32

    private(set) var conflictingTimerSessionIDs: [UUID] = []
    private(set) var additionalConflictCount = 0
    var validationBoundary: FocusTimerValidationBoundary?
    var validatedRowCount: Int?

    var hasConflicts: Bool {
        !conflictingTimerSessionIDs.isEmpty || additionalConflictCount > 0
    }

    mutating func record(_ sessionID: UUID) {
        guard !conflictingTimerSessionIDs.contains(sessionID) else { return }
        guard conflictingTimerSessionIDs.count < Self.maximumRememberedSessionIDs else {
            additionalConflictCount = NonnegativeIntPolicy.next(
                after: additionalConflictCount
            )
            return
        }
        conflictingTimerSessionIDs.append(sessionID)
    }
}

private struct FocusTimerValidationBoundary: Codable, Equatable {
    let key: FocusTimerValidationKey
    let payload: FocusCloudPayload
}

/// Codable form of every field used by `FocusSyncRecordSnapshot` equality.
/// The exact group descriptor sorts by this tuple, making equal policy
/// snapshots adjacent without sorting or persisting the payload itself.
private struct FocusTimerValidationKey: Codable, Equatable {
    let recordID: UUID
    let sessionID: UUID
    let status: SyncedFocusStatus
    let startedAt: Date
    let scheduledEndAt: Date?
    let updatedAt: Date
    let terminalAt: Date?
    let revision: Int
    let ownershipSequence: Int
    let writerDeviceID: String
    let dataEpochID: UUID?

    init(_ value: SyncedFocusTimer) {
        let snapshot = value.policySnapshot
        recordID = snapshot.recordID
        sessionID = snapshot.sessionID
        status = snapshot.status
        startedAt = snapshot.startedAt
        scheduledEndAt = snapshot.scheduledEndAt
        updatedAt = snapshot.updatedAt
        terminalAt = snapshot.terminalAt
        revision = snapshot.revision
        ownershipSequence = snapshot.ownershipSequence
        writerDeviceID = snapshot.writerDeviceID
        dataEpochID = snapshot.dataEpochID
    }
}

private extension SyncMaintenanceSliceWorker {
    /// This phase intentionally does not demote a different StudySession UUID.
    /// Two devices that complete distinct timers offline retain both measured
    /// records in the 1.0 contract. Current source duplicates are validated and
    /// resolved in memory; physical rows remain untouched until a materialized
    /// StudySession independently proves that an active timer tail is closed.
    func reconcileFocusIdentity(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        currentEpochID: UUID?,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        switch cursor.phase {
        case 0:
            return try reconcileFocusTimerPage(
                request: request,
                cursor: cursor,
                currentEpochID: currentEpochID,
                runtime: &runtime
            )
        case 1:
            return try reconcileFocusClaimPage(
                request: request,
                cursor: cursor,
                currentEpochID: currentEpochID,
                runtime: &runtime
            )
        default:
            return try removeClosedFocusTimerTail(
                request: request,
                cursor: cursor,
                currentEpochID: currentEpochID,
                runtime: &runtime
            )
        }
    }

    func reconcileFocusTimerPage(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        currentEpochID: UUID?,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        guard let targetID = cursor.targetLogicalID else {
            return try reconcileCompleteFocusTimerGroupsPage(
                request: request,
                cursor: cursor,
                currentEpochID: currentEpochID,
                runtime: &runtime
            )
        }
        let state = focusMaintenanceQuarantine(from: cursor)
        // A pre-release checkpoint may still point at the retired destructive
        // pass. Restarting validation is safe and leaves all source rows intact.
        return try validateFocusTimerGroup(
            request: request,
            cursor: cursor,
            targetID: targetID,
            currentEpochID: currentEpochID,
            state: state,
            runtime: &runtime
        )
    }

    /// Most historical timers are singleton logical groups. Validate
    /// every complete group in one 128-row page so a decades-long history does
    /// not require one actor launch per row. Only the final group of a full
    /// page can be truncated; it enters the explicit two-pass state machine.
    func reconcileCompleteFocusTimerGroupsPage(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        currentEpochID: UUID?,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        let pageLimit = min(128, runtime.limits.maximumRowsPerFetch)
        let page = try fetch(
            focusTimerPageDescriptor(
                currentEpochID: currentEpochID,
                after: cursor.lastLogicalID
            ),
            limit: pageLimit,
            runtime: &runtime
        )
        var state = focusMaintenanceQuarantine(from: cursor)
        guard !page.isEmpty else {
            state.validationBoundary = nil
            state.validatedRowCount = nil
            return .moreWork(
                request: request,
                cursor: SyncMaintenanceCursor(
                    observedWinningEpochID: cursor.observedWinningEpochID,
                    phase: 1,
                    payload: try encodedFocusMaintenanceQuarantine(state)
                ),
                audit: runtime.audit
            )
        }

        let boundaryID = page.count == pageLimit ? page.last?.sessionID : nil
        let completeRows = boundaryID.map { boundary in
            page.filter { $0.sessionID != boundary }
        } ?? page
        let grouped = Dictionary(grouping: completeRows, by: \.sessionID)
        var seenSessionIDs = Set<UUID>()
        for row in completeRows
        where seenSessionIDs.insert(row.sessionID).inserted {
            let sessionID = row.sessionID
            guard let group = grouped[sessionID] else { continue }
            if hasUnsafeFocusTimerPayload(group) {
                state.record(sessionID)
                continue
            }
            _ = FocusSyncPolicy.resolveSameSession(group.map(\.policySnapshot))
        }

        state.validationBoundary = nil
        state.validatedRowCount = nil
        var next = cursor
        if let boundaryID {
            next.lastLogicalID = completeRows.last?.sessionID ?? cursor.lastLogicalID
            next.targetLogicalID = boundaryID
            next.offset = 0
            next.secondaryOffset = 0
        } else {
            next.lastLogicalID = page.last?.sessionID
        }
        next.payload = try encodedFocusMaintenanceQuarantine(state)
        return .moreWork(
            request: request,
            cursor: next,
            audit: runtime.audit
        )
    }

    /// The validation pass is entirely read-only. Every physical revision is
    /// retained because a partially delivered group is not a server-coordinated
    /// garbage-collection boundary.
    func validateFocusTimerGroup(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        targetID: UUID,
        currentEpochID: UUID?,
        state sourceState: FocusMaintenanceQuarantine,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        var descriptor = focusTimerGroupDescriptor(
            sessionID: targetID,
            currentEpochID: currentEpochID
        )
        descriptor.fetchOffset = cursor.offset
        let page = try fetch(
            descriptor,
            limit: runtime.limits.maximumRowsPerFetch,
            runtime: &runtime
        )
        var state = sourceState

        guard !hasUnsafeFocusTimerPayload(page),
              !focusTimerBoundaryConflicts(
                  state.validationBoundary,
                  first: page.first
              ) else {
            return try quarantineFocusTimerGroup(
                request: request,
                cursor: cursor,
                targetID: targetID,
                state: state,
                runtime: &runtime
            )
        }

        if let last = page.last,
           let payload = try? last.decodedPayload() {
            state.validationBoundary = FocusTimerValidationBoundary(
                key: FocusTimerValidationKey(last),
                payload: payload
            )
        }
        guard cursor.offset >= 0,
              cursor.offset <= Int.max - page.count else {
            throw SyncMaintenanceError.invalidCursorPayload
        }
        let validatedCount = cursor.offset + page.count
        if page.count == runtime.limits.maximumRowsPerFetch {
            var next = cursor
            next.offset = validatedCount
            state.validatedRowCount = nil
            next.payload = try encodedFocusMaintenanceQuarantine(state)
            return .moreWork(
                request: request,
                cursor: next,
                audit: runtime.audit
            )
        }

        state.validationBoundary = nil
        state.validatedRowCount = nil
        var next = cursor
        next.lastLogicalID = targetID
        next.targetLogicalID = nil
        next.offset = 0
        next.secondaryOffset = 0
        next.payload = try encodedFocusMaintenanceQuarantine(state)
        return .moreWork(
            request: request,
            cursor: next,
            audit: runtime.audit
        )
    }

    /// Compatibility shim for a checkpoint produced by a pre-release build
    /// that had a destructive second pass. It validates then advances without
    /// changing or deleting synchronized rows.
    func compactValidatedFocusTimerGroup(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        targetID: UUID,
        currentEpochID: UUID?,
        state sourceState: FocusMaintenanceQuarantine,
        prevalidatedRows: [SyncedFocusTimer]?,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        let descriptor = focusTimerGroupDescriptor(
            sessionID: targetID,
            currentEpochID: currentEpochID
        )
        var state = sourceState
        let count: Int
        let exact: [SyncedFocusTimer]
        if let prevalidatedRows {
            count = prevalidatedRows.count
            exact = prevalidatedRows
        } else {
            count = try fetchCount(descriptor, runtime: &runtime)
            guard state.validatedRowCount == count else {
                var next = cursor
                next.offset = 0
                next.secondaryOffset = 0
                state.validationBoundary = nil
                state.validatedRowCount = nil
                next.payload = try encodedFocusMaintenanceQuarantine(state)
                return .moreWork(
                    request: request,
                    cursor: next,
                    audit: runtime.audit
                )
            }
            exact = try fetch(
                descriptor,
                limit: runtime.limits.maximumRowsPerFetch,
                runtime: &runtime
            )
        }

        guard !hasUnsafeFocusTimerPayload(exact) else {
            return try quarantineFocusTimerGroup(
                request: request,
                cursor: cursor,
                targetID: targetID,
                state: state,
                runtime: &runtime
            )
        }
        _ = FocusSyncPolicy.resolveSameSession(exact.map(\.policySnapshot))
        guard count >= exact.count else {
            throw SyncMaintenanceError.invalidCursorPayload
        }
        var next = cursor
        next.lastLogicalID = targetID
        next.targetLogicalID = nil
        next.offset = 0
        next.secondaryOffset = 0
        state.validationBoundary = nil
        state.validatedRowCount = nil
        next.payload = try encodedFocusMaintenanceQuarantine(state)
        return .moreWork(
            request: request,
            cursor: next,
            audit: runtime.audit
        )
    }

    func quarantineFocusTimerGroup(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        targetID: UUID,
        state sourceState: FocusMaintenanceQuarantine,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        var state = sourceState
        state.record(targetID)
        state.validationBoundary = nil
        state.validatedRowCount = nil
        var next = cursor
        next.lastLogicalID = targetID
        next.targetLogicalID = nil
        next.offset = 0
        next.secondaryOffset = 0
        next.payload = try encodedFocusMaintenanceQuarantine(state)
        return .moreWork(
            request: request,
            cursor: next,
            audit: runtime.audit
        )
    }

    func focusTimerBoundaryConflicts(
        _ boundary: FocusTimerValidationBoundary?,
        first value: SyncedFocusTimer?
    ) -> Bool {
        guard let boundary, let value,
              boundary.key == FocusTimerValidationKey(value) else {
            return false
        }
        guard let payload = try? value.decodedPayload() else { return true }
        return boundary.payload != payload
    }

    func hasUnsafeFocusTimerPayload(
        _ values: [SyncedFocusTimer]
    ) -> Bool {
        var representatives: [(
            snapshot: FocusSyncRecordSnapshot,
            payload: FocusCloudPayload
        )] = []
        representatives.reserveCapacity(values.count)
        for value in values {
            guard let payload = try? value.decodedPayload() else { return true }
            if let existing = representatives.first(where: {
                $0.snapshot == value.policySnapshot
            }) {
                if existing.payload != payload { return true }
            } else {
                representatives.append((value.policySnapshot, payload))
            }
        }
        return false
    }

    func focusMaintenanceQuarantine(
        from cursor: SyncMaintenanceCursor
    ) -> FocusMaintenanceQuarantine {
        guard let payload = cursor.payload,
              let decoded = try? JSONDecoder().decode(
                  FocusMaintenanceQuarantine.self,
                  from: payload
              ) else {
            return FocusMaintenanceQuarantine()
        }
        return decoded
    }

    func encodedFocusMaintenanceQuarantine(
        _ value: FocusMaintenanceQuarantine
    ) throws -> Data {
        let encoder = JSONEncoder()
        // The payload is part of the durable cursor's equality. Stable bytes
        // make a read-only slice replay return the identical checkpoint, not
        // merely a semantically equivalent JSON object with reordered keys.
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func focusTimerPageDescriptor(
        currentEpochID: UUID?,
        after: UUID?
    ) -> FetchDescriptor<SyncedFocusTimer> {
        let predicate: Predicate<SyncedFocusTimer>
        switch (currentEpochID, after) {
        case let (epochID?, lastID?):
            predicate = #Predicate {
                $0.dataEpochID == epochID && $0.sessionID > lastID
            }
        case let (epochID?, nil):
            predicate = #Predicate { $0.dataEpochID == epochID }
        case let (nil, lastID?):
            predicate = #Predicate {
                $0.dataEpochID == nil && $0.sessionID > lastID
            }
        case (nil, nil):
            predicate = #Predicate { $0.dataEpochID == nil }
        }
        return FetchDescriptor<SyncedFocusTimer>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\SyncedFocusTimer.sessionID),
                SortDescriptor(\SyncedFocusTimer.id)
            ]
        )
    }

    func focusTimerGroupDescriptor(
        sessionID: UUID,
        currentEpochID: UUID?
    ) -> FetchDescriptor<SyncedFocusTimer> {
        let predicate: Predicate<SyncedFocusTimer>
        if let currentEpochID {
            predicate = #Predicate {
                $0.sessionID == sessionID && $0.dataEpochID == currentEpochID
            }
        } else {
            predicate = #Predicate {
                $0.sessionID == sessionID && $0.dataEpochID == nil
            }
        }
        return FetchDescriptor<SyncedFocusTimer>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\SyncedFocusTimer.id),
                SortDescriptor(\SyncedFocusTimer.statusRaw),
                SortDescriptor(\SyncedFocusTimer.startedAt),
                SortDescriptor(\SyncedFocusTimer.scheduledEndAt),
                SortDescriptor(\SyncedFocusTimer.updatedAt),
                SortDescriptor(\SyncedFocusTimer.terminalAt),
                SortDescriptor(\SyncedFocusTimer.revision),
                SortDescriptor(\SyncedFocusTimer.ownershipSequence),
                SortDescriptor(\SyncedFocusTimer.writerDeviceID)
            ]
        )
    }

    func reconcileFocusClaimPage(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        currentEpochID: UUID?,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        let pageLimit = min(128, runtime.limits.maximumRowsPerFetch)
        let descriptor = focusClaimPageDescriptor(
            currentEpochID: currentEpochID,
            after: cursor.lastLogicalID
        )
        let page = try fetch(descriptor, limit: pageLimit, runtime: &runtime)
        guard !page.isEmpty else {
            return .moreWork(
                request: request,
                cursor: closedFocusTimerCleanupCursor(from: cursor),
                audit: runtime.audit
            )
        }
        let grouped = Dictionary(grouping: page, by: \.id)
        let duplicateID = page.lazy
            .map(\.id)
            .first { (grouped[$0]?.count ?? 0) > 1 }
        let boundaryID = page.count == pageLimit ? page.last?.id : nil
        let targetID = duplicateID ?? boundaryID
        var lastProcessed = page.last?.id
        if let targetID {
            let exactDescriptor = focusClaimGroupDescriptor(
                id: targetID,
                currentEpochID: currentEpochID
            )
            let count = try fetchCount(exactDescriptor, runtime: &runtime)
            let exact = try fetch(
                exactDescriptor,
                limit: runtime.limits.maximumRowsPerFetch,
                runtime: &runtime
            )
            if count > exact.count {
                // Without server-coordinated garbage collection, page-wise
                // deletion can lose a release or later edit held by an unseen
                // copy. Preserve the entire oversized group and fail closed.
                return .retry(
                    request: request,
                    cursor: cursor,
                    audit: runtime.audit,
                    category: "oversized-focus-claim-logical-group"
                )
            }
            normalizeFocusClaimGroup(exact)
            lastProcessed = targetID
        }
        if page.count < pageLimit && targetID == nil {
            return .moreWork(
                request: request,
                cursor: closedFocusTimerCleanupCursor(from: cursor),
                audit: runtime.audit
            )
        }
        var next = cursor
        next.lastLogicalID = lastProcessed
        return .moreWork(
            request: request,
            cursor: next,
            audit: runtime.audit
        )
    }

    func focusClaimPageDescriptor(
        currentEpochID: UUID?,
        after: UUID?
    ) -> FetchDescriptor<FocusTimerDeviceClaim> {
        let predicate: Predicate<FocusTimerDeviceClaim>
        switch (currentEpochID, after) {
        case let (epochID?, lastID?):
            predicate = #Predicate {
                $0.dataEpochID == epochID && $0.id > lastID
            }
        case let (epochID?, nil):
            predicate = #Predicate { $0.dataEpochID == epochID }
        case let (nil, lastID?):
            predicate = #Predicate {
                $0.dataEpochID == nil && $0.id > lastID
            }
        case (nil, nil):
            predicate = #Predicate { $0.dataEpochID == nil }
        }
        return FetchDescriptor<FocusTimerDeviceClaim>(
            predicate: predicate,
            sortBy: [SortDescriptor(\FocusTimerDeviceClaim.id)]
        )
    }

    func focusClaimGroupDescriptor(
        id: UUID,
        currentEpochID: UUID?
    ) -> FetchDescriptor<FocusTimerDeviceClaim> {
        let predicate: Predicate<FocusTimerDeviceClaim>
        if let currentEpochID {
            predicate = #Predicate {
                $0.id == id && $0.dataEpochID == currentEpochID
            }
        } else {
            predicate = #Predicate {
                $0.id == id && $0.dataEpochID == nil
            }
        }
        return FetchDescriptor<FocusTimerDeviceClaim>(
            predicate: predicate,
            sortBy: [SortDescriptor(\FocusTimerDeviceClaim.claimedAt)]
        )
    }

    func normalizeFocusClaimGroup(_ values: [FocusTimerDeviceClaim]) {
        guard let sessionID = values.first?.sessionID else { return }
        // FocusSyncPolicy performs the logical release-aware fold in memory.
        // Every physical claim remains immutable source evidence.
        _ = FocusSyncPolicy.notificationOwner(
            for: sessionID,
            claims: values.map(\.policySnapshot)
        )
    }

    func isPolicyValidFocusClaim(_ value: FocusTimerDeviceClaim) -> Bool {
        (0 ... FocusSyncPolicy.maximumSupportedOwnershipSequence)
            .contains(value.sequence)
    }

    func focusClaimIsOrderedBefore(
        _ lhs: FocusTimerDeviceClaim,
        _ rhs: FocusTimerDeviceClaim
    ) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        if (lhs.releasedAt != nil) != (rhs.releasedAt != nil) {
            return lhs.releasedAt == nil
        }
        if lhs.claimedAt != rhs.claimedAt { return lhs.claimedAt < rhs.claimedAt }
        if lhs.deviceID != rhs.deviceID { return lhs.deviceID < rhs.deviceID }
        if lhs.sessionID != rhs.sessionID {
            return lhs.sessionID.uuidString < rhs.sessionID.uuidString
        }
        return lhs.syncRecordID.uuidString < rhs.syncRecordID.uuidString
    }

    func closedFocusTimerCleanupCursor(
        from cursor: SyncMaintenanceCursor
    ) -> SyncMaintenanceCursor {
        SyncMaintenanceCursor(
            observedWinningEpochID: cursor.observedWinningEpochID,
            phase: 2,
            payload: cursor.payload
        )
    }

    /// A materialized StudySession is the irreversible closure sentinel for a
    /// focus. Recoverable timer copies for that exact current-epoch ID are no
    /// longer useful, and enough such tails can otherwise exhaust the bounded
    /// logical scan before a genuinely open timer is reached.
    func removeClosedFocusTimerTail(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        currentEpochID: UUID?,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        let candidate = try fetch(
            activeFocusTimerPageDescriptor(
                currentEpochID: currentEpochID,
                after: cursor.lastLogicalID
            ),
            limit: 1,
            runtime: &runtime
        ).first
        guard let candidate else {
            if focusMaintenanceQuarantine(from: cursor).hasConflicts {
                // Reset the scan for a future, exponentially backed-off pass.
                // `failureCategory` remains durable in the checkpoint while
                // per-kind scheduling lets all independent work continue.
                let revisit = SyncMaintenanceCursor(
                    observedWinningEpochID: cursor.observedWinningEpochID
                )
                return .retry(
                    request: request,
                    cursor: revisit,
                    audit: runtime.audit,
                    category: "quarantined-focus-timer-payload"
                )
            }
            // A delayed CloudKit timer can sort outside Root's recent-row
            // sentinel. Read-only verification still has to wake the recovery
            // query; otherwise that timer stays invisible until foregrounding.
            return .completed(
                request: request,
                audit: runtime.audit,
                effects: [.reevaluateLocalFocus]
            )
        }

        let sessionID = candidate.sessionID
        var next = cursor
        let activeRows = try fetch(
            activeFocusTimerGroupDescriptor(
                sessionID: sessionID,
                currentEpochID: currentEpochID
            ),
            limit: runtime.limits.maximumRowsPerFetch,
            runtime: &runtime
        )
        if hasUnsafeFocusTimerPayload(activeRows) {
            // A singleton row/session mismatch is not visible to duplicate
            // compaction. The active-tail scan therefore validates every
            // logical candidate as well, quarantining both running and pending
            // corruptions while its keyset continues to later valid timers.
            var quarantine = focusMaintenanceQuarantine(from: cursor)
            quarantine.record(sessionID)
            next.lastLogicalID = sessionID
            next.payload = try encodedFocusMaintenanceQuarantine(quarantine)
            return .moreWork(
                request: request,
                cursor: next,
                audit: runtime.audit
            )
        }

        let materializedSessions = try fetch(
            materializedFocusSessionDescriptor(
                sessionID: sessionID,
                currentEpochID: currentEpochID
            ),
            limit: 1,
            runtime: &runtime
        )
        let isClosed = materializedSessions.contains {
            StudySessionIntegrityPolicy.isSupported($0)
        }
        guard isClosed else {
            next.lastLogicalID = sessionID
            return .moreWork(
                request: request,
                cursor: next,
                audit: runtime.audit
            )
        }

        activeRows.forEach(modelContext.delete)
        let changed = try saveIfNeeded(runtime: &runtime)
        // An exactly-full page may have a tail. Retaining the prior keyset
        // revisits this logical ID; once its rows are gone the same query
        // naturally advances, including after a save-before-checkpoint crash.
        if activeRows.count < runtime.limits.maximumRowsPerFetch {
            next.lastLogicalID = sessionID
        }
        return .moreWork(
            request: request,
            cursor: next,
            audit: runtime.audit,
            effects: changed ? [.reevaluateLocalFocus] : []
        )
    }

    func activeFocusTimerPageDescriptor(
        currentEpochID: UUID?,
        after: UUID?
    ) -> FetchDescriptor<SyncedFocusTimer> {
        let running = SyncedFocusStatus.running.rawValue
        let paused = SyncedFocusStatus.paused.rawValue
        let pending = SyncedFocusStatus.completionPending.rawValue
        let predicate: Predicate<SyncedFocusTimer>
        switch (currentEpochID, after) {
        case let (epochID?, lastID?):
            predicate = #Predicate {
                $0.dataEpochID == epochID
                    && $0.sessionID > lastID
                    && ($0.statusRaw == running
                        || $0.statusRaw == paused
                        || $0.statusRaw == pending)
            }
        case let (epochID?, nil):
            predicate = #Predicate {
                $0.dataEpochID == epochID
                    && ($0.statusRaw == running
                        || $0.statusRaw == paused
                        || $0.statusRaw == pending)
            }
        case let (nil, lastID?):
            predicate = #Predicate {
                $0.dataEpochID == nil
                    && $0.sessionID > lastID
                    && ($0.statusRaw == running
                        || $0.statusRaw == paused
                        || $0.statusRaw == pending)
            }
        case (nil, nil):
            predicate = #Predicate {
                $0.dataEpochID == nil
                    && ($0.statusRaw == running
                        || $0.statusRaw == paused
                        || $0.statusRaw == pending)
            }
        }
        return FetchDescriptor(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\SyncedFocusTimer.sessionID),
                SortDescriptor(\SyncedFocusTimer.id)
            ]
        )
    }

    func activeFocusTimerGroupDescriptor(
        sessionID: UUID,
        currentEpochID: UUID?
    ) -> FetchDescriptor<SyncedFocusTimer> {
        let running = SyncedFocusStatus.running.rawValue
        let paused = SyncedFocusStatus.paused.rawValue
        let pending = SyncedFocusStatus.completionPending.rawValue
        let predicate: Predicate<SyncedFocusTimer>
        if let currentEpochID {
            predicate = #Predicate {
                $0.dataEpochID == currentEpochID
                    && $0.sessionID == sessionID
                    && ($0.statusRaw == running
                        || $0.statusRaw == paused
                        || $0.statusRaw == pending)
            }
        } else {
            predicate = #Predicate {
                $0.dataEpochID == nil
                    && $0.sessionID == sessionID
                    && ($0.statusRaw == running
                        || $0.statusRaw == paused
                        || $0.statusRaw == pending)
            }
        }
        return FetchDescriptor(
            predicate: predicate,
            sortBy: [SortDescriptor(\SyncedFocusTimer.id)]
        )
    }

    func materializedFocusSessionDescriptor(
        sessionID: UUID,
        currentEpochID: UUID?
    ) -> FetchDescriptor<StudySession> {
        let predicate: Predicate<StudySession>
        if let currentEpochID {
            predicate = #Predicate {
                $0.id == sessionID && $0.dataEpochID == currentEpochID
            }
        } else {
            predicate = #Predicate {
                $0.id == sessionID && $0.dataEpochID == nil
            }
        }
        return FetchDescriptor(predicate: predicate)
    }
}

// MARK: - Achievement identity

private extension SyncMaintenanceSliceWorker {
    func reconcileAchievements(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        currentEpochID: UUID?,
        runtime: inout Runtime
    ) throws -> SyncMaintenanceSliceResult {
        let pageLimit = min(128, runtime.limits.maximumRowsPerFetch)
        let descriptor = achievementPageDescriptor(
            currentEpochID: currentEpochID,
            after: cursor.lastLogicalID
        )
        let page = try fetch(descriptor, limit: pageLimit, runtime: &runtime)
        guard !page.isEmpty else {
            return .completed(request: request, audit: runtime.audit)
        }

        let grouped = Dictionary(grouping: page, by: \.id)
        let duplicateID = page.lazy
            .map(\.id)
            .first { (grouped[$0]?.count ?? 0) > 1 }
        let boundaryID = page.count == pageLimit ? page.last?.id : nil
        let targetID = duplicateID ?? boundaryID
        var lastProcessedID: UUID?

        if let targetID {
            let exactDescriptor = achievementGroupDescriptor(
                id: targetID,
                currentEpochID: currentEpochID
            )
            let count = try fetchCount(exactDescriptor, runtime: &runtime)
            guard count <= runtime.limits.maximumRowsPerFetch else {
                return .retry(
                    request: request,
                    cursor: cursor,
                    audit: runtime.audit,
                    category: "oversized-achievement-logical-group"
                )
            }
            let exact = try fetch(
                exactDescriptor,
                limit: runtime.limits.maximumRowsPerFetch,
                runtime: &runtime
            )
            for value in page where value.id.uuidString < targetID.uuidString {
                normalizeAchievementGroup([value])
            }
            normalizeAchievementGroup(exact)
            lastProcessedID = targetID
        } else {
            for value in page { normalizeAchievementGroup([value]) }
            lastProcessedID = page.last?.id
        }

        if page.count < pageLimit && targetID == nil {
            return .completed(
                request: request,
                audit: runtime.audit
            )
        }
        var next = cursor
        next.lastLogicalID = lastProcessedID
        return .moreWork(
            request: request,
            cursor: next,
            audit: runtime.audit
        )
    }

    func achievementPageDescriptor(
        currentEpochID: UUID?,
        after: UUID?
    ) -> FetchDescriptor<AchievementStone> {
        let predicate: Predicate<AchievementStone>
        switch (currentEpochID, after) {
        case let (epochID?, lastID?):
            predicate = #Predicate {
                $0.dataEpochID == epochID && $0.id > lastID
            }
        case let (epochID?, nil):
            predicate = #Predicate { $0.dataEpochID == epochID }
        case let (nil, lastID?):
            predicate = #Predicate {
                $0.dataEpochID == nil && $0.id > lastID
            }
        case (nil, nil):
            predicate = #Predicate { $0.dataEpochID == nil }
        }
        return FetchDescriptor<AchievementStone>(
            predicate: predicate,
            sortBy: [SortDescriptor(\AchievementStone.id)]
        )
    }

    func achievementGroupDescriptor(
        id: UUID,
        currentEpochID: UUID?
    ) -> FetchDescriptor<AchievementStone> {
        let predicate: Predicate<AchievementStone>
        if let currentEpochID {
            predicate = #Predicate {
                $0.id == id && $0.dataEpochID == currentEpochID
            }
        } else {
            predicate = #Predicate {
                $0.id == id && $0.dataEpochID == nil
            }
        }
        return FetchDescriptor<AchievementStone>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\AchievementStone.revision, order: .reverse),
                SortDescriptor(\AchievementStone.deletedAt, order: .reverse),
                SortDescriptor(\AchievementStone.updatedAt, order: .reverse)
            ]
        )
    }

    func normalizeAchievementGroup(_ values: [AchievementStone]) {
        // Invalid revisions stay quarantined and all physical rows remain
        // untouched. Presentation resolves the supported winner in memory.
        _ = AchievementStonePolicy.canonicalStone(from: values)
    }
}
