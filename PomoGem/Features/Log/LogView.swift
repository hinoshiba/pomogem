import Accessibility
import Charts
import SwiftData
import SwiftUI

/// Shared, hard-bounded query contract for history-heavy destinations.
///
/// The active bottle already keeps exact lifetime mass in decimal aggregate
/// roots. History screens must not instantiate every original StudySession to
/// draw a chart or card. Every descriptor below either has a narrow date/ID
/// predicate or a fixed limit; callers disclose whenever the `limit + 1`
/// sentinel proves that a page is partial.
enum BoundedHistoryPolicy {
    static let periodSessionLimit = 2_048
    static let recentSessionLimit = 30
    static let achievementLimit = 60
    static let aggregateRootLimit = 64
    static let legacyAggregateLimit = 16
    static let shareLooseSessionLimit = 256
    static let aggregateMemberSessionLimit = 64
    /// Session maintenance also refuses to reason about a larger physical
    /// replica set in one slice. Read paths use the same ceiling and fail
    /// closed instead of selecting a winner from an arbitrary prefix.
    static let maximumPhysicalRowsPerLogicalSession = 256
    static let finiteIntervalSessionRowLimit = 100_000
    static let weeklySessionRowLimit = 16_384

    struct ResolvedSessionPage {
        let sessions: [StudySession]
        let isPartial: Bool
        let scannedPhysicalRowCount: Int
        let boundaryIsProven: Bool
    }

    enum SessionPageResolutionMode: Equatable {
        case failClosed
        /// Home may present a clearly disclosed lower bound while maintenance
        /// retries. Oversized groups are omitted rather than guessed.
        case lowerBound
    }

    enum SessionResolutionError: Error, LocalizedError, Equatable {
        case candidateScanLimitExceeded
        case logicalReplicaLimitExceeded
        case unsupportedInterval

        var errorDescription: String? {
            switch self {
            case .candidateScanLimitExceeded:
                "同期中の記録が多いため、安全な表示範囲を確定できませんでした。"
            case .logicalReplicaLimitExceeded:
                "同じ記録の同期コピーが多いため、安全な内容を確定できませんでした。"
            case .unsupportedInterval:
                "一度に確認できる記録期間を超えています。"
            }
        }
    }

    static func latestResetMarkerDescriptor(
        now: Date = .now
    ) -> FetchDescriptor<ActivityResetMarker> {
        ActivityResetPolicy.currentMarkerDescriptor(now: now)
    }

    static func sessionDescriptor(
        epochID: UUID?,
        start: Date? = nil,
        end: Date? = nil,
        onlyUnbaked: Bool = false,
        order: SortOrder = .reverse,
        limit: Int
    ) -> FetchDescriptor<StudySession> {
        let predicate: Predicate<StudySession>
        switch (epochID, start, end, onlyUnbaked) {
        case let (.some(epoch), .some(start), .some(end), false):
            predicate = #Predicate {
                $0.dataEpochID == epoch && $0.endAt >= start && $0.endAt < end
            }
        case let (.none, .some(start), .some(end), false):
            predicate = #Predicate {
                $0.dataEpochID == nil && $0.endAt >= start && $0.endAt < end
            }
        case let (.some(epoch), .some(start), .none, false):
            predicate = #Predicate { $0.dataEpochID == epoch && $0.endAt >= start }
        case let (.none, .some(start), .none, false):
            predicate = #Predicate { $0.dataEpochID == nil && $0.endAt >= start }
        case let (.some(epoch), .none, .none, true):
            // `onlyUnbaked` is retained as a source-compatible request for a
            // bounded loose *candidate* page. Exact exclusion is performed
            // against local AggregatePebble membership after this fetch.
            predicate = #Predicate { $0.dataEpochID == epoch }
        case (.none, .none, .none, true):
            predicate = #Predicate { $0.dataEpochID == nil }
        case let (.some(epoch), .none, .none, false):
            predicate = #Predicate { $0.dataEpochID == epoch }
        case (.none, .none, .none, false):
            predicate = #Predicate { $0.dataEpochID == nil }
        default:
            // No current caller needs an end-only or date-bounded unbaked
            // query. Returning an impossible predicate is safer than silently
            // widening a future malformed request to the entire store.
            predicate = #Predicate { _ in false }
        }
        var descriptor = FetchDescriptor<StudySession>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\StudySession.endAt, order: order),
                SortDescriptor(\StudySession.id, order: order),
                SortDescriptor(\StudySession.syncRecordID, order: order)
            ]
        )
        descriptor.fetchLimit = max(1, limit)
        return descriptor
    }

    /// Count-only descriptor. `ModelContext.fetchCount` executes this in the
    /// store and does not instantiate the matching StudySession objects.
    static func sessionCountDescriptor(epochID: UUID?) -> FetchDescriptor<StudySession> {
        if let epochID {
            return FetchDescriptor<StudySession>(
                predicate: #Predicate { $0.dataEpochID == epochID }
            )
        }
        return FetchDescriptor<StudySession>(
            predicate: #Predicate { $0.dataEpochID == nil }
        )
    }

    static func sessionDescriptor(
        id: UUID,
        epochID: UUID?,
        limit: Int = maximumPhysicalRowsPerLogicalSession + 1
    ) -> FetchDescriptor<StudySession> {
        let predicate: Predicate<StudySession>
        if let epochID {
            predicate = #Predicate { $0.id == id && $0.dataEpochID == epochID }
        } else {
            predicate = #Predicate { $0.id == id && $0.dataEpochID == nil }
        }
        var descriptor = FetchDescriptor<StudySession>(
            predicate: predicate,
            sortBy: [SortDescriptor(\StudySession.endAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        return descriptor
    }

    /// Resolves every supported physical copy for one logical completion.
    /// The extra row is a sentinel; reaching it means that choosing any value
    /// would depend on an unseen copy, so the caller must fail closed.
    static func resolvedSession(
        id: UUID,
        epochID: UUID?,
        context: ModelContext
    ) throws -> StudySession? {
        let rows = try context.fetch(sessionDescriptor(id: id, epochID: epochID))
        guard rows.count <= maximumPhysicalRowsPerLogicalSession else {
            throw SessionResolutionError.logicalReplicaLimitExceeded
        }
        return StudySessionSyncPolicy.canonicalSession(from: rows)
    }

    /// Returns a logical page, not a physical-row page. Candidate overfetch is
    /// deliberately large enough for one maximum-sized duplicate run and for
    /// ordinary two-copy convergence. Every candidate ID is then exact-read
    /// before date membership and the logical limit are applied.
    static func resolvedSessionPage(
        context: ModelContext,
        epochID: UUID?,
        start: Date? = nil,
        end: Date? = nil,
        onlyUnbaked: Bool = false,
        order: SortOrder = .reverse,
        logicalLimit: Int,
        maximumCandidateRows: Int? = nil,
        mode: SessionPageResolutionMode = .failClosed
    ) throws -> ResolvedSessionPage {
        let limit = max(1, logicalLimit)
        let scanLimit = max(
            1,
            maximumCandidateRows
                ?? maximumSessionCandidateRows(forLogicalLimit: limit)
        )
        let pageSize = min(256, scanLimit)
        var cursor: SessionPhysicalCursor?
        var scanned = 0
        var reachedRawEnd = false
        var exactResolvedIDs = Set<UUID>()
        var unsupportedOnlyCandidateIDs = Set<UUID>()
        var oversizedLogicalGroupIDs = Set<UUID>()
        var resolvedByID: [UUID: StudySession] = [:]

        while scanned < scanLimit {
            try Task.checkCancellation()
            let fetchLimit = min(pageSize, scanLimit - scanned)
            let descriptor: FetchDescriptor<StudySession>
            if let cursor {
                descriptor = sessionDescriptor(
                    epochID: epochID,
                    start: start,
                    end: end,
                    order: order,
                    after: cursor,
                    limit: fetchLimit
                )
            } else {
                descriptor = sessionDescriptor(
                    epochID: epochID,
                    start: start,
                    end: end,
                    onlyUnbaked: onlyUnbaked,
                    order: order,
                    limit: fetchLimit
                )
            }
            let physicalPage = try context.fetch(descriptor)
            reachedRawEnd = physicalPage.count < fetchLimit
            scanned = NonnegativeIntPolicy.adding(
                scanned,
                physicalPage.count,
                maximum: scanLimit
            )
            var newlySupportedCandidateIDs = Set<UUID>()
            for row in physicalPage {
                guard StudySessionIntegrityPolicy.isSupported(row) else {
                    if !exactResolvedIDs.contains(row.id) {
                        unsupportedOnlyCandidateIDs.insert(row.id)
                    }
                    continue
                }
                unsupportedOnlyCandidateIDs.remove(row.id)
                guard exactResolvedIDs.insert(row.id).inserted else { continue }
                newlySupportedCandidateIDs.insert(row.id)
            }
            let batch = try resolvedSessionBatch(
                candidateIDs: newlySupportedCandidateIDs,
                epochID: epochID,
                context: context
            )
            if !batch.oversizedLogicalGroupIDs.isEmpty,
               mode == .failClosed {
                throw SessionResolutionError.logicalReplicaLimitExceeded
            }
            resolvedByID.merge(batch.sessionsByID) { _, newest in newest }
            oversizedLogicalGroupIDs.formUnion(
                batch.oversizedLogicalGroupIDs
            )

            if reachedRawEnd {
                // With the entire physical predicate exhausted, IDs observed
                // only as unsupported rows cannot have an eligible canonical
                // copy in this window. No exact lookup is needed for them.
                unsupportedOnlyCandidateIDs.removeAll()
            }
            let hasUnresolvedLogicalGroup = !unsupportedOnlyCandidateIDs.isEmpty
                || !oversizedLogicalGroupIDs.isEmpty

            let resolved = resolvedByID.values
                .filter { isInsideRequestedWindow($0, start: start, end: end) }
                .sorted { isPresentedBefore($0, $1, order: order) }
            if reachedRawEnd {
                return ResolvedSessionPage(
                    sessions: Array(resolved.prefix(limit)),
                    isPartial: hasUnresolvedLogicalGroup || resolved.count > limit,
                    scannedPhysicalRowCount: scanned,
                    boundaryIsProven: !hasUnresolvedLogicalGroup
                )
            }
            guard let edge = physicalPage.last else {
                return ResolvedSessionPage(
                    sessions: Array(resolved.prefix(limit)),
                    isPartial: hasUnresolvedLogicalGroup || resolved.count > limit,
                    scannedPhysicalRowCount: scanned,
                    boundaryIsProven: !hasUnresolvedLogicalGroup
                )
            }
            if !hasUnresolvedLogicalGroup,
               resolved.count >= limit,
               rawEdgeHasPassed(
                    edge,
                    canonicalBoundary: resolved[limit - 1],
                    order: order
               ) {
                return ResolvedSessionPage(
                    sessions: Array(resolved.prefix(limit)),
                    // Unscanned physical rows might all be redundant or
                    // unsupported, so this is intentionally conservative.
                    isPartial: true,
                    scannedPhysicalRowCount: scanned,
                    boundaryIsProven: true
                )
            }
            cursor = SessionPhysicalCursor(edge)
        }

        // Distinguish an exact raw end at the cap from one more unseen row
        // without widening the accepted scan. A non-empty sentinel cannot be
        // interpreted safely and therefore remains fail-closed.
        if let cursor {
            let sentinel = try context.fetch(sessionDescriptor(
                epochID: epochID,
                start: start,
                end: end,
                order: order,
                after: cursor,
                limit: 1
            ))
            if sentinel.isEmpty {
                unsupportedOnlyCandidateIDs.removeAll()
                let hasUnresolvedLogicalGroup = !oversizedLogicalGroupIDs.isEmpty
                let resolved = resolvedByID.values
                    .filter { isInsideRequestedWindow($0, start: start, end: end) }
                    .sorted { isPresentedBefore($0, $1, order: order) }
                return ResolvedSessionPage(
                    sessions: Array(resolved.prefix(limit)),
                    isPartial: hasUnresolvedLogicalGroup || resolved.count > limit,
                    scannedPhysicalRowCount: scanned,
                    boundaryIsProven: !hasUnresolvedLogicalGroup
                )
            }
        }
        if mode == .lowerBound {
            let resolved = resolvedByID.values
                .filter { isInsideRequestedWindow($0, start: start, end: end) }
                .sorted { isPresentedBefore($0, $1, order: order) }
            return ResolvedSessionPage(
                sessions: Array(resolved.prefix(limit)),
                isPartial: true,
                scannedPhysicalRowCount: scanned,
                boundaryIsProven: false
            )
        }
        throw SessionResolutionError.candidateScanLimitExceeded
    }

    /// Exact finite-period accounting. Only logical IDs discovered in the
    /// requested week/month/year are expanded beyond its date boundary; the
    /// canonical winner is then tested against the interval. This fixes a
    /// loser-inside/winner-outside copy without scanning lifetime history.
    static func resolvedSessionsInFiniteInterval(
        context: ModelContext,
        epochID: UUID?,
        interval: DateInterval,
        maximumPhysicalRows: Int
    ) throws -> [StudySession] {
        let maximumDuration: TimeInterval = 370 * 24 * 60 * 60
        guard interval.duration > 0,
              interval.duration <= maximumDuration,
              maximumPhysicalRows > 0
        else { throw SessionResolutionError.unsupportedInterval }

        let descriptor = sessionDescriptor(
            epochID: epochID,
            start: interval.start,
            end: interval.end,
            order: .forward,
            limit: NonnegativeIntPolicy.adding(maximumPhysicalRows, 1)
        )
        var scanned = 0
        var candidateIDs = Set<UUID>()
        try context.enumerate(descriptor, batchSize: min(256, maximumPhysicalRows)) {
            session in
            try Task.checkCancellation()
            scanned = NonnegativeIntPolicy.adding(scanned, 1)
            guard scanned <= maximumPhysicalRows else {
                throw SessionResolutionError.candidateScanLimitExceeded
            }
            // With the whole finite predicate scanned, an ID observed only as
            // unsupported cannot have an eligible in-window canonical row.
            if StudySessionIntegrityPolicy.isSupported(session) {
                candidateIDs.insert(session.id)
            }
        }
        return try resolvedSessions(
            candidateIDs: candidateIDs,
            epochID: epochID,
            context: context
        )
        .filter {
            $0.endAt >= interval.start && $0.endAt < interval.end
        }
        .sorted { isPresentedBefore($0, $1, order: .forward) }
    }

    static func maximumSessionCandidateRows(forLogicalLimit rawLimit: Int) -> Int {
        let limit = max(1, rawLimit)
        let duplicateRunCapacity = NonnegativeIntPolicy.adding(
            limit,
            maximumPhysicalRowsPerLogicalSession
        )
        let ordinaryReplicaCapacity = NonnegativeIntPolicy.adding(
            NonnegativeIntPolicy.multiplying(limit, 2),
            1
        )
        return max(duplicateRunCapacity, ordinaryReplicaCapacity)
    }

    private struct SessionPhysicalCursor {
        let endAt: Date
        let id: UUID
        let syncRecordID: UUID

        init(_ session: StudySession) {
            endAt = session.endAt
            id = session.id
            syncRecordID = session.syncRecordID
        }
    }

    private static func sessionDescriptor(
        epochID: UUID?,
        start: Date?,
        end: Date?,
        order: SortOrder,
        after cursor: SessionPhysicalCursor,
        limit: Int
    ) -> FetchDescriptor<StudySession> {
        let cursorEnd = cursor.endAt
        let cursorID = cursor.id
        let cursorRecordID = cursor.syncRecordID
        let predicate: Predicate<StudySession>

        if let epochID {
            if let start, let end {
                if order == .forward {
                    predicate = #Predicate {
                        $0.dataEpochID == epochID
                            && $0.endAt >= start && $0.endAt < end
                            && ($0.endAt > cursorEnd
                                || ($0.endAt == cursorEnd && $0.id > cursorID)
                                || ($0.endAt == cursorEnd && $0.id == cursorID
                                    && $0.syncRecordID > cursorRecordID))
                    }
                } else {
                    predicate = #Predicate {
                        $0.dataEpochID == epochID
                            && $0.endAt >= start && $0.endAt < end
                            && ($0.endAt < cursorEnd
                                || ($0.endAt == cursorEnd && $0.id < cursorID)
                                || ($0.endAt == cursorEnd && $0.id == cursorID
                                    && $0.syncRecordID < cursorRecordID))
                    }
                }
            } else if let start {
                if order == .forward {
                    predicate = #Predicate {
                        $0.dataEpochID == epochID && $0.endAt >= start
                            && ($0.endAt > cursorEnd
                                || ($0.endAt == cursorEnd && $0.id > cursorID)
                                || ($0.endAt == cursorEnd && $0.id == cursorID
                                    && $0.syncRecordID > cursorRecordID))
                    }
                } else {
                    predicate = #Predicate {
                        $0.dataEpochID == epochID && $0.endAt >= start
                            && ($0.endAt < cursorEnd
                                || ($0.endAt == cursorEnd && $0.id < cursorID)
                                || ($0.endAt == cursorEnd && $0.id == cursorID
                                    && $0.syncRecordID < cursorRecordID))
                    }
                }
            } else if end == nil {
                if order == .forward {
                    predicate = #Predicate {
                        $0.dataEpochID == epochID
                            && ($0.endAt > cursorEnd
                                || ($0.endAt == cursorEnd && $0.id > cursorID)
                                || ($0.endAt == cursorEnd && $0.id == cursorID
                                    && $0.syncRecordID > cursorRecordID))
                    }
                } else {
                    predicate = #Predicate {
                        $0.dataEpochID == epochID
                            && ($0.endAt < cursorEnd
                                || ($0.endAt == cursorEnd && $0.id < cursorID)
                                || ($0.endAt == cursorEnd && $0.id == cursorID
                                    && $0.syncRecordID < cursorRecordID))
                    }
                }
            } else {
                predicate = #Predicate { _ in false }
            }
        } else if let start, let end {
            if order == .forward {
                predicate = #Predicate {
                    $0.dataEpochID == nil
                        && $0.endAt >= start && $0.endAt < end
                        && ($0.endAt > cursorEnd
                            || ($0.endAt == cursorEnd && $0.id > cursorID)
                            || ($0.endAt == cursorEnd && $0.id == cursorID
                                && $0.syncRecordID > cursorRecordID))
                }
            } else {
                predicate = #Predicate {
                    $0.dataEpochID == nil
                        && $0.endAt >= start && $0.endAt < end
                        && ($0.endAt < cursorEnd
                            || ($0.endAt == cursorEnd && $0.id < cursorID)
                            || ($0.endAt == cursorEnd && $0.id == cursorID
                                && $0.syncRecordID < cursorRecordID))
                }
            }
        } else if let start {
            if order == .forward {
                predicate = #Predicate {
                    $0.dataEpochID == nil && $0.endAt >= start
                        && ($0.endAt > cursorEnd
                            || ($0.endAt == cursorEnd && $0.id > cursorID)
                            || ($0.endAt == cursorEnd && $0.id == cursorID
                                && $0.syncRecordID > cursorRecordID))
                }
            } else {
                predicate = #Predicate {
                    $0.dataEpochID == nil && $0.endAt >= start
                        && ($0.endAt < cursorEnd
                            || ($0.endAt == cursorEnd && $0.id < cursorID)
                            || ($0.endAt == cursorEnd && $0.id == cursorID
                                && $0.syncRecordID < cursorRecordID))
                }
            }
        } else if end == nil {
            if order == .forward {
                predicate = #Predicate {
                    $0.dataEpochID == nil
                        && ($0.endAt > cursorEnd
                            || ($0.endAt == cursorEnd && $0.id > cursorID)
                            || ($0.endAt == cursorEnd && $0.id == cursorID
                                && $0.syncRecordID > cursorRecordID))
                }
            } else {
                predicate = #Predicate {
                    $0.dataEpochID == nil
                        && ($0.endAt < cursorEnd
                            || ($0.endAt == cursorEnd && $0.id < cursorID)
                            || ($0.endAt == cursorEnd && $0.id == cursorID
                                && $0.syncRecordID < cursorRecordID))
                }
            }
        } else {
            predicate = #Predicate { _ in false }
        }

        var descriptor = FetchDescriptor<StudySession>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\StudySession.endAt, order: order),
                SortDescriptor(\StudySession.id, order: order),
                SortDescriptor(\StudySession.syncRecordID, order: order)
            ]
        )
        descriptor.fetchLimit = max(1, limit)
        return descriptor
    }

    private static func resolvedSessions(
        candidateIDs: Set<UUID>,
        epochID: UUID?,
        context: ModelContext
    ) throws -> [StudySession] {
        let batch = try resolvedSessionBatch(
            candidateIDs: candidateIDs,
            epochID: epochID,
            context: context
        )
        guard batch.oversizedLogicalGroupIDs.isEmpty else {
            throw SessionResolutionError.logicalReplicaLimitExceeded
        }
        return Array(batch.sessionsByID.values)
    }

    private struct SessionBatchResolution {
        var sessionsByID: [UUID: StudySession] = [:]
        var oversizedLogicalGroupIDs = Set<UUID>()

        mutating func merge(_ other: SessionBatchResolution) {
            sessionsByID.merge(other.sessionsByID) { _, newest in newest }
            oversizedLogicalGroupIDs.formUnion(
                other.oversizedLogicalGroupIDs
            )
        }
    }

    /// Exact-resolves a candidate set with one store scan in the ordinary
    /// case. `StudySession.id` is intentionally not unique because CloudKit
    /// replicas are retained, and the iOS 17 SwiftData schema has no supported
    /// compound-index declaration. Issuing one exact fetch per logical ID
    /// therefore turns a 256-row Home page into 256 lifetime table scans.
    ///
    /// The aggregate sentinel preserves the per-ID 256-copy trust boundary.
    /// If it fires, recursively splitting the finite ID set isolates only the
    /// oversized groups; valid neighbours remain available in lower-bound
    /// mode without ever accepting an arbitrary physical prefix.
    private static func resolvedSessionBatch(
        candidateIDs: Set<UUID>,
        epochID: UUID?,
        context: ModelContext
    ) throws -> SessionBatchResolution {
        let orderedIDs = candidateIDs.sorted {
            $0.uuidString < $1.uuidString
        }
        var result = SessionBatchResolution()
        // Keep the ordinary-case materialization ceiling at 8,193 rows even
        // when a caller supplies the full 256-ID history page.
        let maximumIDsPerBatch = 32
        for offset in stride(
            from: 0,
            to: orderedIDs.count,
            by: maximumIDsPerBatch
        ) {
            let end = min(offset + maximumIDsPerBatch, orderedIDs.count)
            result.merge(try resolvedSessionBatch(
                orderedCandidateIDs: Array(orderedIDs[offset..<end]),
                epochID: epochID,
                context: context
            ))
        }
        return result
    }

    private static func resolvedSessionBatch(
        orderedCandidateIDs: [UUID],
        epochID: UUID?,
        context: ModelContext
    ) throws -> SessionBatchResolution {
        try Task.checkCancellation()
        guard !orderedCandidateIDs.isEmpty else {
            return SessionBatchResolution()
        }

        let candidateIDs = orderedCandidateIDs
        let predicate: Predicate<StudySession>
        if let epochID {
            predicate = #Predicate {
                candidateIDs.contains($0.id) && $0.dataEpochID == epochID
            }
        } else {
            predicate = #Predicate {
                candidateIDs.contains($0.id) && $0.dataEpochID == nil
            }
        }
        let maximumAcceptedRows = NonnegativeIntPolicy.multiplying(
            candidateIDs.count,
            maximumPhysicalRowsPerLogicalSession
        )
        var descriptor = FetchDescriptor<StudySession>(predicate: predicate)
        descriptor.fetchLimit = NonnegativeIntPolicy.adding(
            maximumAcceptedRows,
            1
        )
        let rows = try context.fetch(descriptor)

        if rows.count > maximumAcceptedRows {
            guard candidateIDs.count > 1 else {
                return SessionBatchResolution(
                    oversizedLogicalGroupIDs: Set(candidateIDs)
                )
            }
            let midpoint = candidateIDs.count / 2
            var result = try resolvedSessionBatch(
                orderedCandidateIDs: Array(candidateIDs[..<midpoint]),
                epochID: epochID,
                context: context
            )
            result.merge(try resolvedSessionBatch(
                orderedCandidateIDs: Array(candidateIDs[midpoint...]),
                epochID: epochID,
                context: context
            ))
            return result
        }

        let groups = Dictionary(grouping: rows, by: \.id)
        var result = SessionBatchResolution()
        result.sessionsByID.reserveCapacity(candidateIDs.count)
        for id in candidateIDs {
            let group = groups[id] ?? []
            guard group.count <= maximumPhysicalRowsPerLogicalSession else {
                result.oversizedLogicalGroupIDs.insert(id)
                continue
            }
            if let canonical = StudySessionSyncPolicy.canonicalSession(
                from: group
            ) {
                result.sessionsByID[id] = canonical
            }
        }
        return result
    }

    private static func isInsideRequestedWindow(
        _ session: StudySession,
        start: Date?,
        end: Date?
    ) -> Bool {
        if let start, session.endAt < start { return false }
        if let end, session.endAt >= end { return false }
        return true
    }

    private static func isPresentedBefore(
        _ lhs: StudySession,
        _ rhs: StudySession,
        order: SortOrder
    ) -> Bool {
        if lhs.endAt != rhs.endAt {
            return order == .forward
                ? lhs.endAt < rhs.endAt
                : lhs.endAt > rhs.endAt
        }
        if lhs.id != rhs.id {
            return order == .forward
                ? lhs.id.uuidString < rhs.id.uuidString
                : lhs.id.uuidString > rhs.id.uuidString
        }
        return order == .forward
            ? lhs.syncRecordID.uuidString < rhs.syncRecordID.uuidString
            : lhs.syncRecordID.uuidString > rhs.syncRecordID.uuidString
    }

    private static func rawEdgeHasPassed(
        _ edge: StudySession,
        canonicalBoundary: StudySession,
        order: SortOrder
    ) -> Bool {
        !isPresentedBefore(edge, canonicalBoundary, order: order)
    }

    /// Returns a bounded page of active candidates. Callers must pass the page
    /// through `AchievementStonePolicy.resolvedVisibleCandidates` before use;
    /// that exact-ID lookup includes tombstones and prevents late stale rows
    /// from resurfacing without loading the lifetime ledger.
    static func achievementCandidateDescriptor(
        epochID: UUID?,
        start: Date? = nil,
        end: Date? = nil,
        order: SortOrder = .reverse,
        limit: Int
    ) -> FetchDescriptor<AchievementStone> {
        let predicate: Predicate<AchievementStone>
        switch (epochID, start, end) {
        case let (.some(epoch), .some(start), .some(end)):
            predicate = #Predicate {
                $0.dataEpochID == epoch
                    && $0.deletedAt == nil
                    && $0.achievedAt >= start
                    && $0.achievedAt < end
            }
        case let (.none, .some(start), .some(end)):
            predicate = #Predicate {
                $0.dataEpochID == nil
                    && $0.deletedAt == nil
                    && $0.achievedAt >= start
                    && $0.achievedAt < end
            }
        case let (.some(epoch), .none, .none):
            predicate = #Predicate { $0.dataEpochID == epoch && $0.deletedAt == nil }
        case (.none, .none, .none):
            predicate = #Predicate { $0.dataEpochID == nil && $0.deletedAt == nil }
        default:
            predicate = #Predicate { _ in false }
        }
        var descriptor = FetchDescriptor<AchievementStone>(
            predicate: predicate,
            sortBy: [SortDescriptor(\AchievementStone.achievedAt, order: order)]
        )
        descriptor.fetchLimit = max(1, limit)
        return descriptor
    }

    /// Includes tombstones so edit/delete/Undo can choose one mutation target
    /// without rewriting the other synchronized source replicas.
    static func achievementRevisionDescriptor(
        id: UUID,
        epochID: UUID?,
        limit: Int = AchievementStonePolicy.maximumPhysicalRowsPerLogicalStone + 1
    ) -> FetchDescriptor<AchievementStone> {
        let predicate: Predicate<AchievementStone>
        if let epochID {
            predicate = #Predicate { $0.id == id && $0.dataEpochID == epochID }
        } else {
            predicate = #Predicate { $0.id == id && $0.dataEpochID == nil }
        }
        // Always retain the canonical head inside this bounded mutation page.
        // Otherwise an unusually large duplicate set could let an arbitrary
        // fetch omit a newer tombstone and make an edit appear to resurrect it.
        var descriptor = FetchDescriptor<AchievementStone>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\AchievementStone.revision, order: .reverse),
                SortDescriptor(\AchievementStone.deletedAt, order: .reverse),
                SortDescriptor(\AchievementStone.deletionMutationID, order: .reverse),
                SortDescriptor(\AchievementStone.updatedAt, order: .reverse),
                SortDescriptor(\AchievementStone.createdAt, order: .reverse),
                SortDescriptor(\AchievementStone.achievedAt, order: .reverse),
                SortDescriptor(\AchievementStone.note, order: .reverse),
                SortDescriptor(\AchievementStone.subjectNameSnapshot, order: .reverse),
                SortDescriptor(\AchievementStone.syncRecordID, order: .reverse)
            ]
        )
        descriptor.fetchLimit = max(1, limit)
        return descriptor
    }

    static func rootAggregateDescriptor(
        epochID: UUID?,
        limit: Int
    ) -> FetchDescriptor<AggregatePebble> {
        let predicate: Predicate<AggregatePebble>
        if let epochID {
            predicate = #Predicate {
                $0.dataEpochID == epochID && $0.parentAggregateID == nil
            }
        } else {
            predicate = #Predicate {
                $0.dataEpochID == nil && $0.parentAggregateID == nil
            }
        }
        var descriptor = FetchDescriptor<AggregatePebble>(
            predicate: predicate,
            sortBy: [SortDescriptor(\AggregatePebble.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        return descriptor
    }

    static func aggregateDescriptor(
        id: UUID,
        epochID: UUID?,
        limit: Int = 4
    ) -> FetchDescriptor<AggregatePebble> {
        let predicate: Predicate<AggregatePebble>
        if let epochID {
            predicate = #Predicate { $0.id == id && $0.dataEpochID == epochID }
        } else {
            predicate = #Predicate { $0.id == id && $0.dataEpochID == nil }
        }
        var descriptor = FetchDescriptor<AggregatePebble>(
            predicate: predicate,
            sortBy: [SortDescriptor(\AggregatePebble.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        return descriptor
    }

    static func legacyAggregateDescriptor(
        epochID: UUID?,
        limit: Int
    ) -> FetchDescriptor<Stratum> {
        let predicate: Predicate<Stratum>
        if let epochID {
            predicate = #Predicate { $0.dataEpochID == epochID }
        } else {
            predicate = #Predicate { $0.dataEpochID == nil }
        }
        var descriptor = FetchDescriptor<Stratum>(
            predicate: predicate,
            sortBy: [SortDescriptor(\Stratum.bakedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        return descriptor
    }

    static func legacyAggregateDescriptor(
        id: UUID,
        epochID: UUID?,
        limit: Int = 4
    ) -> FetchDescriptor<Stratum> {
        let predicate: Predicate<Stratum>
        if let epochID {
            predicate = #Predicate { $0.id == id && $0.dataEpochID == epochID }
        } else {
            predicate = #Predicate { $0.id == id && $0.dataEpochID == nil }
        }
        var descriptor = FetchDescriptor<Stratum>(
            predicate: predicate,
            sortBy: [SortDescriptor(\Stratum.bakedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        return descriptor
    }
}

/// 記録's 「今週」 and 「今月」 are the calendar week and month that contain
/// today: the same 「今週」 the completion card and 積み上がり use, never a
/// rolling seven days.
enum LogPeriodPolicy {
    static func interval(
        for period: LogView.Period,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> DateInterval? {
        switch period {
        case .week:
            WeeklyProgressPolicy.week(containing: now, calendar: calendar)
        case .month:
            calendar.dateInterval(of: .month, for: now)
        }
    }

    /// Every day of the period, including the days still to come, so the
    /// chart reads like a calendar rather than a window that slides.
    static func days(
        in interval: DateInterval,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [Date] {
        var days: [Date] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end, days.count < 32 {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    /// 「9月21日(日)〜9月27日(土)」: says which days 「今週」 covers.
    static func rangeLabel(
        for interval: DateInterval,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end)
            ?? interval.start
        var style = Date.FormatStyle.dateTime.month().day().weekday(.abbreviated)
        style.locale = calendar.locale ?? .autoupdatingCurrent
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return "\(interval.start.formatted(style))〜\(lastDay.formatted(style))"
    }
}

/// The period tiles in 記録. Totals include every source; the split says how
/// much of it was self-reported and how much came from Screen Time, so the
/// measured part matches 「今週の実測」 in 積み上がり.
struct LogPeriodSummary: Equatable, Sendable {
    let totalSeconds: Int
    let grams: Int
    /// Timers that ran to their end (「完走ポモ」).
    let timerCompletionCount: Int
    let selfReportedGrams: Int
    let screenTimeSeconds: Int

    /// The 「積んだ時間」 tile: credited focus time, read from the mass so it
    /// matches Wrapped and the card built from the same records.
    var focusMinutes: Int {
        DurationPresentation.focusMinutes(grams: grams)
    }

    init(records: [LogSessionRecord]) {
        totalSeconds = NonnegativeIntPolicy.sum(records.map(\.seconds))
        grams = NonnegativeIntPolicy.sum(records.map(\.grams))
        timerCompletionCount = records
            .filter { $0.source.isTimerCompletion }
            .count
        selfReportedGrams = NonnegativeIntPolicy.sum(
            records.filter { $0.source.isSelfReported }.map(\.grams)
        )
        screenTimeSeconds = NonnegativeIntPolicy.sum(
            records.filter { $0.source == .screenTime }.map(\.seconds)
        )
    }

    init(sessions: [StudySession]) {
        self.init(records: sessions.map(LogSessionRecord.init))
    }
}

/// When 記録 reloads. Three loads, each keyed by only what it depends on:
/// - the period page follows the 今週／今月 toggle, and is all a toggle reads;
/// - the newest thirty records, milestones and aggregate pebbles do not
///   depend on the period;
/// - the twelve month summaries change only with the month.
/// The period page, the newest thirty with the aggregates, and the months
/// are read off the main thread through AccumulationTimelineLoader
/// (LogHistoryReads.swift), one at a time (LogReadQueue); their cost grows
/// with lifetime history. Only the milestones stay on the main context: a
/// few dozen rows that an edit in this screen must refresh at once.
/// None reloads for an inactive flip (closing Control Center or the
/// notification shade); coming back from the background reloads all three.
enum LogHistoryLoadPolicy {
    enum Part: String, CaseIterable {
        /// The 今週／今月 page.
        case period
        /// The newest thirty records and the aggregate pebbles.
        case recent
        /// The twelve monthly jars.
        case months
    }

    static func isVisible(_ scenePhase: ScenePhase) -> Bool {
        scenePhase != .background
    }

    /// After a 今週／今月 toggle the page on screen stays until the new one
    /// arrives, which on most phones is at once. Past this delay the
    /// placeholders take over, so the other period's figures never linger.
    static let periodReloadPlaceholderDelay: Duration = .milliseconds(250)

    /// The period page to draw, if any. Its figures and labels always
    /// describe one period: a page read for the other period lags the
    /// picker only until `reloadIsSlow`, and one read before a reset is
    /// never shown.
    static func shownPeriodContent(
        _ content: LogPeriodContent?,
        selected period: LogView.Period,
        currentEpochID: UUID?,
        reloadIsSlow: Bool
    ) -> LogPeriodContent? {
        guard let content, content.epochID == currentEpochID else { return nil }
        if content.period != period, reloadIsSlow { return nil }
        return content
    }

    /// The newest records and aggregates to draw, if any: never from
    /// before a reset.
    static func shownRecentContent(
        _ content: LogRecentContent?,
        currentEpochID: UUID?
    ) -> LogRecentContent? {
        guard let content, content.epochID == currentEpochID else { return nil }
        return content
    }

    /// The まとまり粒 archive to draw, if any: only one read under the
    /// verification that is current now. The newest records do not depend
    /// on verification and stay; the archive does, like every cache derived
    /// from aggregate projections (`AggregateProjectionCacheStamp`). After
    /// verified → pending → verified, an archive read before the pending
    /// phase stays hidden until a read under the new verification arrives,
    /// even if the reads in between were cancelled or failed.
    static func shownAggregateArchive(
        _ content: LogRecentContent?,
        currentEpochID: UUID?,
        projection: AggregateProjectionPresentationContext
    ) -> LogAggregateArchive? {
        guard let archive = shownRecentContent(content, currentEpochID: currentEpochID)?.aggregates,
              projection.acceptsVerifiedAggregateCache(archive.cacheStamp)
        else { return nil }
        return archive
    }

    /// The dates the range label names: those of the page on screen, which
    /// the tiles, chart and theme bar describe, even when today has moved
    /// into the next week or month while the new page is on its way. Only
    /// while no page is shown, the selected period around `now`.
    static func shownInterval(
        _ shown: LogPeriodContent?,
        selected period: LogView.Period,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> DateInterval? {
        if let shown { return shown.interval }
        return LogPeriodPolicy.interval(for: period, now: now, calendar: calendar)
    }

    /// What stays after the period page failed to read: a page of this
    /// period and epoch (a refresh that failed); otherwise this period's
    /// name over no figures, never another period's or a pre-reset page.
    static func periodContentAfterFailedRead(
        _ content: LogPeriodContent?,
        period: LogView.Period,
        currentEpochID: UUID?,
        interval: DateInterval?,
        calendar: Calendar
    ) -> LogPeriodContent {
        if let content, content.period == period, content.epochID == currentEpochID {
            return content
        }
        return .empty(
            period: period,
            epochID: currentEpochID,
            interval: interval,
            calendar: calendar
        )
    }

    /// What stays after the newest records failed to read: this epoch's
    /// records (a refresh that failed); otherwise 最近の記録 says it could
    /// not read them. No content at all counts as nothing of this epoch,
    /// also when the epoch is nil (no reset ever), so the section always
    /// ends in a final state instead of loading forever.
    static func recentContentAfterFailedRead(
        _ content: LogRecentContent?,
        currentEpochID: UUID?
    ) -> LogRecentContent {
        if let content, content.epochID == currentEpochID { return content }
        return .unavailable(epochID: currentEpochID)
    }

    static func periodKey(
        epochID: UUID?,
        period: LogView.Period,
        scenePhase: ScenePhase,
        isCloudVerificationPending: Bool
    ) -> String {
        "\(epochID?.uuidString ?? "pre-reset")|\(period.rawValue)|\(isVisible(scenePhase))|\(isCloudVerificationPending)"
    }

    static func recentHistoryKey(
        epochID: UUID?,
        scenePhase: ScenePhase,
        isCloudVerificationPending: Bool
    ) -> String {
        "\(epochID?.uuidString ?? "pre-reset")|\(isVisible(scenePhase))|\(isCloudVerificationPending)"
    }

    static func monthSummaryKey(
        epochID: UUID?,
        scenePhase: ScenePhase,
        isCloudVerificationPending: Bool,
        now: Date = .now,
        calendar: Calendar = PomoGemCalendar.gregorian
    ) -> String {
        let month = calendar.dateInterval(of: .month, for: now)?.start
            .timeIntervalSinceReferenceDate ?? 0
        return "\(epochID?.uuidString ?? "pre-reset")|\(isVisible(scenePhase))|\(isCloudVerificationPending)|\(month)"
    }
}

struct LogView: View {
    enum Period: String, CaseIterable, Identifiable, Sendable {
        case week
        case month
        var id: Self { self }

        var title: String {
            switch self {
            case .week: String(localized: "今週", table: "Log", comment: "Log period picker: the calendar week that contains today")
            case .month: String(localized: "今月", table: "Log", comment: "Log period picker: the calendar month that contains today")
            }
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isCloudOfflineSession) private var isCloudOfflineSession
    @Environment(\.aggregateProjectionPresentation)
    private var aggregateProjectionPresentation
    @Query private var activityResetMarkers: [ActivityResetMarker]
    /// Live theme rows only; tombstones never count toward the row bound.
    @Query(sort: \Subject.sortOrder) private var storedSubjects: [Subject]
    /// Observed so a deletion delivered as a new physical row refreshes the
    /// list; see `SubjectSyncPolicy.presentationSubjects(live:tombstones:context:)`.
    @Query private var storedSubjectTombstones: [Subject]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
#if DEBUG
    @Environment(AppRouter.self) private var router
#endif
    @State private var period: Period = .week
    @State private var selectedWrappedMonth: WrappedMonth?
    /// Nil until the first page arrives, so the first frames show
    /// placeholders instead of 「この期間の粒は、まだありません。」 over years
    /// of history that simply have not been read yet.
    @State private var periodContent: LogPeriodContent?
    /// The page for the chosen period is taking longer than
    /// `periodReloadPlaceholderDelay`.
    @State private var periodReloadIsSlow = false
    /// The same for 「一粒積むと、ここに記録が残ります。」 under 最近の記録.
    @State private var recentContent: LogRecentContent?
    @State private var achievementStones: [AchievementStone] = []
    @State private var monthSummaries: [LogMonthSummary] = []
    @State private var achievementPageIsPartial = false
    @State private var periodLoadFailed = false
    @State private var recentHistoryLoadFailed = false
    @State private var achievementLoadFailed = false
    /// The `recentHistoryKey` the milestones were last read for.
    @State private var achievementLoadKey: String?
    /// 記録's reads of the lifetime history take turns (see LogReadQueue).
    @State private var readQueue = LogReadQueue()
    @State private var mutationError: String?
    @State private var selectedAchievement: AchievementEditSelection?
    @State private var selectedDay: HistoryDaySelection?
    @State private var showsPastHistory = false
    @State private var pendingAchievementUndo: AchievementStoneRevisionSnapshot?

    init() {
        _storedSubjects = Query(SubjectSyncPolicy.liveRowsDescriptor(sortBy: [
            SortDescriptor(\Subject.sortOrder),
            SortDescriptor(\Subject.syncRecordID)
        ]))
        _storedSubjectTombstones = Query(SubjectSyncPolicy.tombstoneRowsDescriptor())
        _activityResetMarkers = Query(BoundedHistoryPolicy.latestResetMarkerDescriptor())
    }

    private var resetSnapshots: [ActivityResetSnapshot] {
        activityResetMarkers.map(\.policySnapshot)
    }
    private var subjects: [Subject] {
        SubjectSyncPolicy.presentationSubjects(
            live: storedSubjects, tombstones: storedSubjectTombstones, context: modelContext
        )
    }
    private var currentEpochID: UUID? {
        ActivityResetPolicy.currentEpochID(from: resetSnapshots)
    }

    /// Picking a period also forgets that the previous pick was slow, in the
    /// same update, so a new pick never opens on placeholders for a frame.
    private var periodSelection: Binding<Period> {
        Binding(
            get: { period },
            set: { newValue in
#if DEBUG
                if newValue != period {
                    // Before the change, so the audit is running when the
                    // new page's load starts.
                    router.logLoadAudit.begin(.period)
                }
#endif
                periodReloadIsSlow = false
                period = newValue
            }
        )
    }

    private var shownPeriodContent: LogPeriodContent? {
        LogHistoryLoadPolicy.shownPeriodContent(
            periodContent,
            selected: period,
            currentEpochID: currentEpochID,
            reloadIsSlow: periodReloadIsSlow
        )
    }

    /// The period the figures below the picker describe. Right after a
    /// toggle it is still the previous one, for as long as its page is shown.
    private var shownPeriod: Period {
        shownPeriodContent?.period ?? period
    }

    private var periodRecords: [LogSessionRecord] {
        shownPeriodContent?.records ?? []
    }

    private var periodPageIsPartial: Bool {
        shownPeriodContent?.isPartial ?? false
    }

    private var shownRecentContent: LogRecentContent? {
        LogHistoryLoadPolicy.shownRecentContent(
            recentContent,
            currentEpochID: currentEpochID
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                Picker("表示期間", selection: periodSelection) {
                    ForEach(Period.allCases) { item in Text(item.title).tag(item) }
                }
                .pickerStyle(.segmented)

                if let interval = LogHistoryLoadPolicy.shownInterval(
                    shownPeriodContent,
                    selected: period
                ) {
                    Text(LogPeriodPolicy.rangeLabel(for: interval))
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 2)
                        .accessibilityLabel(String(
                            localized: "\(shownPeriod.title)、\(LogPeriodPolicy.rangeLabel(for: interval))",
                            table: "Log",
                            comment: "VoiceOver: the period (今週 or 今月), then its date range"
                        ))
                        .accessibilityIdentifier("log.period-range")
                }

                achievementUndoNotice

                if periodPageIsPartial {
                    Label(
                        "この期間は記録が多いため、最新\(BoundedHistoryPolicy.periodSessionLimit)件の表示分です。",
                        systemImage: "rectangle.stack.badge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("log.partial-period-notice")
                }

                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                summaryGrid
                    .modifier(LoadingSummaryTiles(isLoading: shownPeriodContent == nil))
                // A chosen, real-world milestone is stronger evidence of
                // progress than charts or a random visual variant. Keep it
                // near the top of the log so a qualification or completed
                // deliverable is visible without hunting below rare stats.
                achievementArchive
                massChart
                subjectComposition
                if RareRewardReleasePolicy.isEnabled {
                    rarePebbles
                }
                wrappedArchive
                aggregateArchive
                recentHistory
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background(NightBackground())
        .pomogemNavigationTitle("記録")
        .toolbarTitleDisplayMode(.large)
        .fullScreenCover(item: $selectedWrappedMonth) { month in
            WrappedView(month: month)
        }
        .sheet(item: $selectedDay) { day in
            DayHistorySheet(
                dayStart: day.dayStart,
                currentEpochID: currentEpochID,
                calendar: PomoGemCalendar.gregorian
            )
            .environment(\.dynamicTypeSize, dynamicTypeSize)
        }
        .sheet(isPresented: $showsPastHistory) {
            PastHistorySheet()
                .environment(\.dynamicTypeSize, dynamicTypeSize)
        }
        .sheet(item: $selectedAchievement, onDismiss: {
            selectedAchievement = nil
        }) { selection in
            AchievementEditorSheet(
                selection: selection,
                subjects: editableSubjects(for: selection),
                onSave: { draft in
                    saveAchievement(selection: selection, draft: draft)
                },
                onDelete: {
                    deleteAchievement(selection: selection)
                }
            )
            // Like the other sheets here: a sheet does not inherit a Dynamic
            // Type size set above it.
            .environment(\.dynamicTypeSize, dynamicTypeSize)
        }
        .alert(
            "記念石を変更できません",
            isPresented: Binding(
                get: { mutationError != nil },
                set: { if !$0 { mutationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { mutationError = nil }
        } message: {
            Text(mutationError ?? "もう一度お試しください。")
        }
        .task(id: loadKey) {
            await loadPeriodPage(for: loadKey)
        }
        .task(id: period) {
            // Restarted by every toggle: the previous page stays for a
            // moment, then the placeholders take over if the new one is slow.
            try? await Task.sleep(for: LogHistoryLoadPolicy.periodReloadPlaceholderDelay)
            guard !Task.isCancelled else { return }
            periodReloadIsSlow = true
        }
        .task(id: recentHistoryKey) {
            await loadRecentHistory(for: recentHistoryKey)
        }
        .task(id: monthSummaryKey) {
            await loadMonthSummaries(for: monthSummaryKey)
        }
        .onChange(of: LogHistoryLoadPolicy.isVisible(scenePhase)) { _, isVisible in
            guard !isVisible else { return }
            // Coming back from the background reads the milestones again,
            // like everything else on this screen.
            achievementLoadKey = nil
#if DEBUG
            router.logLoadAudit.noteHidden()
#endif
        }
#if DEBUG
        .overlay(alignment: .topLeading) {
            if LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess {
                LogLoadAuditProbe(audit: router.logLoadAudit)
            }
        }
#endif
    }

    /// Tells the UI-test load audit that a load has arrived (see LogLoadAudit).
    private func completeLoadAudit(_ part: LogHistoryLoadPolicy.Part) {
#if DEBUG
        router.logLoadAudit.complete(part)
#endif
    }

    private var summaryGrid: some View {
        let summary = shownPeriodContent?.presentation.summary
            ?? LogPeriodSummary(records: [])
        return VStack(alignment: .leading, spacing: 8) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 10) {
                        summaryTiles(summary)
                    }
                } else {
                    HStack(spacing: 10) {
                        summaryTiles(summary)
                    }
                }
            }
            summaryComposition(summary)
        }
    }

    @ViewBuilder
    private func summaryTiles(_ summary: LogPeriodSummary) -> some View {
        SummaryTile(label: periodPageIsPartial ? "表示分の時間" : "積んだ時間", value: formatMinutes(summary.focusMinutes), symbol: "hourglass", identifier: "log.summary.time")
        // Timers that ran to their end; Screen Time chunks are not completions.
        SummaryTile(label: periodPageIsPartial ? "表示分の完走" : "完走ポモ", value: "\(summary.timerCompletionCount)", symbol: "checkmark.circle", identifier: "log.summary.completions")
        SummaryTile(
            label: periodPageIsPartial
                ? "表示分の質量"
                : (shownPeriod == .week
                    ? String(localized: "今週の質量", table: "Log", comment: "Log tile: mass added this calendar week")
                    : String(localized: "今月の質量", table: "Log", comment: "Log tile: mass added this calendar month")),
            value: formatMass(summary.grams),
            symbol: "scalemass",
            identifier: "log.summary.mass"
        )
    }

    /// Only shown when it applies, so a timer-only week stays uncluttered.
    @ViewBuilder
    private func summaryComposition(_ summary: LogPeriodSummary) -> some View {
        if summary.selfReportedGrams > 0 {
            Label(
                String(
                    localized: "このうち自己申告 \(formatMass(summary.selfReportedGrams))",
                    table: "Log",
                    comment: "Log: how much of the period's mass was self-reported; the argument is a mass such as 300g"
                ),
                systemImage: "hand.tap"
            )
            .font(.caption)
            .foregroundStyle(PomoGemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("log.self-reported-share")
        }
        if summary.screenTimeSeconds > 0 {
            Label(
                String(
                    localized: "スクリーンタイムの\(DurationPresentation.minutesLabel(seconds: summary.screenTimeSeconds))は、完走ポモに含みません",
                    table: "Log",
                    comment: "Log: Screen Time learning in the period is not counted as completed timers; the argument is a duration"
                ),
                systemImage: "apps.iphone"
            )
            .font(.caption)
            .foregroundStyle(PomoGemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("log.screen-time-share")
        }
    }

    private var massChart: some View {
        let values = shownPeriodContent?.presentation.dailyMass ?? []
        let descriptor = DailyMassChartDescriptor(
            values: values,
            periodTitle: shownPeriod.title,
            isPartial: periodPageIsPartial
        )
        return PomoGemCard {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionEyebrow(text: "MASS")
                    Text("質量の推移")
                        .font(PomoGemTheme.brand(20))
                }
                if shownPeriodContent == nil {
                    HistoryLoadingPlaceholder()
                } else if values.allSatisfy({ $0.grams == 0 }) {
                    EmptyChartMessage(text: "この期間の粒は、まだありません。")
                        .accessibilityChartDescriptor(descriptor)
                } else {
                    Chart(values) { item in
                        BarMark(
                            x: .value("日", item.date, unit: .day),
                            y: .value("グラム", item.grams)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [PomoGemTheme.amber, PomoGemTheme.amber.opacity(0.44)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .cornerRadius(4)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: shownPeriod == .week ? .day : .weekOfMonth)) { value in
                            AxisValueLabel(format: shownPeriod == .week ? .dateTime.weekday(.narrow) : .dateTime.day())
                            AxisGridLine().foregroundStyle(.clear)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine().foregroundStyle(PomoGemTheme.glassEdge.opacity(0.08))
                            AxisValueLabel {
                                if let grams = value.as(Int.self) { Text(formatMass(grams)).font(.caption2) }
                            }
                        }
                    }
                    .frame(height: 180)
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onTapGesture { location in
                                    openDay(at: location, proxy: proxy, geometry: geometry, values: values)
                                }
                        }
                    }
                    .accessibilityChartDescriptor(descriptor)
                    .accessibilityIdentifier("log.mass-chart")
                    .accessibilityActions {
                        ForEach(values.filter { $0.grams > 0 }) { item in
                            Button(String(
                                localized: "\(item.date.formatted(.dateTime.month().day()))の記録を見る",
                                table: "Log",
                                comment: "VoiceOver action on the mass chart; the argument is a date such as 9月24日"
                            )) {
                                selectedDay = HistoryDaySelection(dayStart: item.date)
                            }
                        }
                    }
                    Text("棒を選ぶと、その日の記録を一件ずつ見られます。", tableName: "Log")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A tap anywhere in a day's column opens that day, when it has records.
    private func openDay(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy,
        values: [LogDailyMass]
    ) {
        guard let plotFrame = proxy.plotFrame else { return }
        let origin = geometry[plotFrame].origin
        guard let date = proxy.value(atX: location.x - origin.x, as: Date.self) else { return }
        let calendar = Calendar.autoupdatingCurrent
        guard let day = values.first(where: { calendar.isDate($0.date, inSameDayAs: date) }),
              day.grams > 0
        else { return }
        selectedDay = HistoryDaySelection(dayStart: day.date)
    }

    private var subjectComposition: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 17) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionEyebrow(text: "SUBJECTS")
                    Text("テーマの構成")
                        .font(PomoGemTheme.brand(20))
                }
                if shownPeriodContent == nil {
                    HistoryLoadingPlaceholder()
                } else if subjectMass.isEmpty {
                    EmptyChartMessage(text: "積んだテーマがここに並びます。")
                } else {
                    GeometryReader { proxy in
                        HStack(spacing: 3) {
                            ForEach(subjectMass) { item in
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(hex: item.colorHex))
                                    .frame(width: max(4, proxy.size.width * item.fraction))
                                    .accessibilityLabel(
                                        "\(item.name)、\(NonnegativeIntPolicy.clamped(item.fraction * 100, maximum: 100))パーセント"
                                    )
                            }
                        }
                    }
                    .frame(height: 18)

                    VStack(spacing: 9) {
                        ForEach(subjectMass) { item in
                            HStack(spacing: 10) {
                                Circle().fill(Color(hex: item.colorHex)).frame(width: 9, height: 9)
                                Text(item.name).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(formatMass(item.grams))
                                    .font(.system(.caption, design: .rounded, weight: .bold))
                                    .foregroundStyle(PomoGemTheme.muted)
                            }
                        }
                    }
                }
            }
        }
    }

    private var rarePebbles: some View {
        let totals = RareRewardCounts.total(periodRecords.map(\.rareRewardCounts))
        let rareSessions = periodRecords.filter { $0.rareRewardCounts.rareCount > 0 }
        return PomoGemCard {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 14) {
                        RareStat(kind: .gold, count: totals.goldCount)
                        RareStat(kind: .prism, count: totals.prismCount)
                        if let latest = rareSessions.max(by: { $0.endAt < $1.endAt }) {
                            LabeledContent(
                                "最後に出た日",
                                value: latest.endAt.formatted(date: .abbreviated, time: .omitted)
                            )
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                        }
                    }
                } else {
                    HStack(spacing: 18) {
                        RareStat(kind: .gold, count: totals.goldCount)
                        Divider().overlay(PomoGemTheme.glassEdge.opacity(0.15))
                        RareStat(kind: .prism, count: totals.prismCount)
                        Spacer()
                        if let latest = rareSessions.max(by: { $0.endAt < $1.endAt }) {
                            VStack(alignment: .trailing, spacing: 3) {
                                Text("最後に出た日").font(.caption2).foregroundStyle(PomoGemTheme.muted)
                                Text(latest.endAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption.weight(.bold))
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var achievementArchive: some View {
        let stones = uniqueAchievementStones
        if !stones.isEmpty {
            PomoGemCard {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionEyebrow(text: "MILESTONES")
                        Text("記念石アーカイブ")
                            .font(PomoGemTheme.brand(20))
                        Text(achievementArchiveDescription(count: stones.count))
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(stones) { stone in
                        Button {
                            selectedAchievement = AchievementEditSelection(stone)
                        } label: {
                            AchievementHistoryRow(stone: stone)
                        }
                        .buttonStyle(PomoGemBareButtonStyle())
                        .accessibilityIdentifier("achievement.history.row")
                        .accessibilityHint("詳細を開いて、種類・テーマ・日付・メモを編集できます")
                        if stone.id != stones.last?.id {
                            Divider().overlay(PomoGemTheme.glassEdge.opacity(0.08))
                        }
                    }
                }
            }
        }
    }

    private var uniqueAchievementStones: [AchievementStone] {
        AchievementStonePolicy.canonicalStones(from: achievementStones)
        .filter { $0.deletedAt == nil }
        .sorted {
            if $0.achievedAt == $1.achievedAt { return $0.id.uuidString > $1.id.uuidString }
            return $0.achievedAt > $1.achievedAt
        }
    }

    @ViewBuilder
    private var achievementUndoNotice: some View {
        if let pendingAchievementUndo {
            PomoGemCard {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.title3)
                        .foregroundStyle(PomoGemTheme.amber)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("記念石を削除しました")
                            .font(.subheadline.weight(.bold))
                        Text("質量は変わりません。記録・瓶・共有から非表示になりました。")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button("元に戻す") {
                        undoAchievementDeletion(pendingAchievementUndo)
                    }
                    .font(.subheadline.weight(.bold))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .buttonStyle(PomoGemRowButtonStyle())
                    .accessibilityIdentifier("achievement.undo-delete")
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var wrappedArchive: some View {
        if !monthSummaries.isEmpty {
            PomoGemCard {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionEyebrow(text: "MONTHLY WRAPPED")
                        Text("月ごとの瓶")
                            .font(PomoGemTheme.brand(20))
                        Text("直近12か月を、月ごとの瓶で振り返れます。")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                    }

                    ForEach(monthSummaries) { summary in
                        let month = summary.month
                        Button {
                            selectedWrappedMonth = month
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "sparkles.rectangle.stack.fill")
                                    .foregroundStyle(PomoGemTheme.amber)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(month.title)
                                        .font(.subheadline.weight(.bold))
                                    Text(summary.rowLabel(formatMinutes: formatMinutes))
                                        .font(.caption)
                                        .foregroundStyle(PomoGemTheme.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(PomoGemTheme.muted)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PomoGemRowButtonStyle())
                    }

                    // The twelve months end here; older months are one step
                    // away instead of only at the bottom of 最近の記録.
                    Divider().overlay(PomoGemTheme.glassEdge.opacity(0.08))
                    Button {
                        showsPastHistory = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "calendar")
                                .foregroundStyle(PomoGemTheme.amber)
                                .frame(width: 28)
                                .accessibilityHidden(true)
                            Text("もっと前の月を見る", tableName: "Log", comment: "Log: row under the twelve monthly jars that opens 年月 for older months")
                                .font(.subheadline.weight(.bold))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(PomoGemTheme.muted)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PomoGemRowButtonStyle())
                    .accessibilityHint(Text("年と月を選んで、日ごとの記録までたどれます", tableName: "Log"))
                    .accessibilityIdentifier(HistoryDrillDownAccessibilityID.pastHistoryFromMonths)
                }
            }
        }
    }

    @ViewBuilder
    private var aggregateArchive: some View {
        let items = aggregateArchiveItems
        if aggregateProjectionPresentation.isCloudVerificationPending {
            PomoGemCard {
                Label(
                    isCloudOfflineSession
                        ? "このiPhoneのまとまり粒を確認中です。確認できた個別記録は引き続き表示しています。"
                        : "iCloudのまとまり粒を再集計中です。この端末で確認できた個別記録は引き続き表示しています。",
                    systemImage: isCloudOfflineSession ? "checklist" : "icloud.and.arrow.down"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PomoGemTheme.muted)
                .accessibilityIdentifier("log.aggregate-verification-pending")
            }
        } else if !items.isEmpty {
            PomoGemCard {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionEyebrow(text: "OVERVIEW PEBBLES")
                        Text("まとまり粒アーカイブ")
                            .font(PomoGemTheme.brand(20))
                        Text("小さな粒は消えません。10粒ずつまとまり、瓶の中で動き続けます。")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if shownAggregateArchive?.isPartial == true {
                        Text("ここでは最新\(BoundedHistoryPolicy.aggregateRootLimit)個を表示しています。生涯の質量は瓶の俯瞰画面で確認できます。")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(items) { item in
                        AggregateArchiveRow(item: item)
                        if item.id != items.last?.id {
                            Divider().overlay(PomoGemTheme.glassEdge.opacity(0.08))
                        }
                    }
                }
            }
        }
    }

    /// Only roots are shown (see `logRecentContent`). A legacy layer lists
    /// the records on screen that it holds.
    private var aggregateArchiveItems: [LogAggregateArchiveItem] {
        guard let archive = shownAggregateArchive else { return [] }
        let legacy = archive.legacyLayers.map { layer in
            LogAggregateArchiveItem(
                legacy: layer,
                members: uniqueRecords.filter { layer.sessionIDs.contains($0.id) }
            )
        }
        return (archive.roots + legacy).sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString > rhs.id.uuidString }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private var shownAggregateArchive: LogAggregateArchive? {
        LogHistoryLoadPolicy.shownAggregateArchive(
            recentContent,
            currentEpochID: currentEpochID,
            projection: aggregateProjectionPresentation
        )
    }

    /// The period page and the newest thirty, each record once.
    private var uniqueRecords: [LogSessionRecord] {
        var seen = Set<UUID>()
        return (periodRecords + (shownRecentContent?.records ?? [])).filter {
            seen.insert($0.id).inserted
        }
    }

    private var recentHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近の記録").font(PomoGemTheme.brand(20))
                Spacer()
                Text("最新30件").font(.caption).foregroundStyle(PomoGemTheme.muted)
            }
            if let recent = shownRecentContent {
                if recent.isUnavailable {
                    // Not 「一粒積むと…」: the records may be years deep.
                    PomoGemCard {
                        EmptyChartMessage(text: String(
                            localized: "最近の記録を読み込めませんでした。",
                            table: "Log",
                            comment: "Log: shown under 最近の記録 when the newest records could not be read"
                        ))
                        .accessibilityIdentifier("log.recent.unavailable")
                    }
                } else if recent.records.isEmpty {
                    PomoGemCard { EmptyChartMessage(text: "一粒積むと、ここに記録が残ります。") }
                } else {
                    recentRows(Array(recent.records.prefix(BoundedHistoryPolicy.recentSessionLimit)))
                }
            } else {
                PomoGemCard { HistoryLoadingPlaceholder() }
            }
        }
    }

    @ViewBuilder
    private func recentRows(_ records: [LogSessionRecord]) -> some View {
        VStack(spacing: 0) {
            ForEach(records) { record in
                HistorySessionRow(item: record.row)
                if record.id != records.last?.id {
                    Divider().overlay(PomoGemTheme.glassEdge.opacity(0.08)).padding(.leading, 48)
                }
            }
        }
        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 16))

        // The list stays bounded; older history is one step away,
        // by year, month and day.
        Button {
            showsPastHistory = true
        } label: {
            Label(
                String(localized: "過去の記録を月・日ごとに見る", table: "Log", comment: "Log: opens 年月 to reach older history by month and day"),
                systemImage: "calendar"
            )
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PomoGemSecondaryButtonStyle())
        .accessibilityHint(Text("年と月を選んで、日ごとの記録までたどれます", tableName: "Log"))
        .accessibilityIdentifier(HistoryDrillDownAccessibilityID.pastHistory)
    }

    private var subjectMass: [LogSubjectMass] {
        shownPeriodContent?.presentation.subjectMass ?? []
    }

    private var loadKey: String {
        LogHistoryLoadPolicy.periodKey(
            epochID: currentEpochID,
            period: period,
            scenePhase: scenePhase,
            isCloudVerificationPending: aggregateProjectionPresentation.isCloudVerificationPending
        )
    }

    private var recentHistoryKey: String {
        LogHistoryLoadPolicy.recentHistoryKey(
            epochID: currentEpochID,
            scenePhase: scenePhase,
            isCloudVerificationPending: aggregateProjectionPresentation.isCloudVerificationPending
        )
    }

    private var loadError: String? {
        guard periodLoadFailed || recentHistoryLoadFailed || achievementLoadFailed else { return nil }
        return "記録の一部を読み込めませんでした。もう一度この画面を開いてください。"
    }

    private var monthSummaryKey: String {
        LogHistoryLoadPolicy.monthSummaryKey(
            epochID: currentEpochID,
            scenePhase: scenePhase,
            isCloudVerificationPending: aggregateProjectionPresentation.isCloudVerificationPending
        )
    }

    /// The 今週／今月 page: the only read a toggle causes. Bounded, and read
    /// off the main thread through AccumulationTimelineLoader, so 記録 keeps
    /// scrolling and answering while it arrives.
    @MainActor
    private func loadPeriodPage(for key: String) async {
        guard LogHistoryLoadPolicy.isVisible(scenePhase) else { return }
        loadAchievementsBeforeLifetimeReads()
        let epochID = currentEpochID
        let period = self.period
        let calendar = Calendar.autoupdatingCurrent
        let interval = LogPeriodPolicy.interval(
            for: period,
            now: .now,
            calendar: calendar
        )
        do {
            let container = modelContext.container
            let content = try await readQueue.run(first: true) {
                try await AccumulationTimelineLoader.read(from: container) { repository in
                    try await repository.logPeriodContent(
                        period: period,
                        interval: interval,
                        calendar: calendar,
                        currentEpochID: epochID
                    )
                }
            }
            try Task.checkCancellation()
            guard key == loadKey else { return }
            periodContent = content
            periodLoadFailed = false
        } catch is CancellationError {
            return
        } catch {
            guard key == loadKey else { return }
            periodLoadFailed = true
            periodContent = LogHistoryLoadPolicy.periodContentAfterFailedRead(
                periodContent,
                period: period,
                currentEpochID: epochID,
                interval: interval,
                calendar: calendar
            )
        }
        completeLoadAudit(.period)
    }

    /// The newest thirty records and the aggregate pebbles: they do not
    /// depend on 今週／今月, so a toggle never re-reads them. Off the main
    /// thread, like the period page.
    @MainActor
    private func loadRecentHistory(for key: String) async {
        guard LogHistoryLoadPolicy.isVisible(scenePhase) else { return }
        loadAchievementsBeforeLifetimeReads()
        let epochID = currentEpochID
        // Nil while iCloud verification is pending: the aggregates are then
        // not read, and whatever is read is tied to this verification.
        let aggregateCacheStamp = aggregateProjectionPresentation.verifiedCacheStamp
        do {
            let container = modelContext.container
            let content = try await readQueue.run {
                try await AccumulationTimelineLoader.read(from: container) { repository in
                    try await repository.logRecentContent(
                        currentEpochID: epochID,
                        aggregateCacheStamp: aggregateCacheStamp
                    )
                }
            }
            try Task.checkCancellation()
            guard key == recentHistoryKey else { return }
            recentContent = content
            recentHistoryLoadFailed = false
        } catch is CancellationError {
            return
        } catch {
            guard key == recentHistoryKey else { return }
            recentHistoryLoadFailed = true
            recentContent = LogHistoryLoadPolicy.recentContentAfterFailedRead(
                recentContent,
                currentEpochID: epochID
            )
        }
        completeLoadAudit(.recent)
    }

    /// Reads the milestones once per `recentHistoryKey`, before any of that
    /// key's reads starts off the main thread. Each load calls it first, so
    /// whichever runs first reads them while the store is idle.
    ///
    /// The contexts of one container take turns at the store (Core Data runs
    /// every request for a store on one serial SQL queue): a main-context
    /// fetch that arrives while a lifetime-sized read is running off the
    /// main thread waits for it, and the screen freezes just as if the main
    /// thread ran that read.
    @MainActor
    private func loadAchievementsBeforeLifetimeReads() {
#if DEBUG
        // The first load after a return from the background starts the
        // UI-test audit of that return, and every load marks when reading
        // starts, both before anything is read.
        router.logLoadAudit.beginResumeIfReturning()
        router.logLoadAudit.loadStarting()
#endif
        let key = recentHistoryKey
        guard achievementLoadKey != key else { return }
        achievementLoadKey = key
        loadAchievements()
    }

    /// Milestones stay on the main context: at most `achievementLimit`
    /// candidates from a table that holds only milestones, and an edit,
    /// deletion or undo in this screen re-reads them before the sheet closes.
    @MainActor
    private func loadAchievements() {
        guard LogHistoryLoadPolicy.isVisible(scenePhase) else { return }
#if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
        defer {
            router.logLoadAudit.noteMilestoneRead(
                seconds: ProcessInfo.processInfo.systemUptime - startedAt
            )
        }
#endif
        let epochID = currentEpochID
        do {
            let achievementRaw = try modelContext.fetch(BoundedHistoryPolicy.achievementCandidateDescriptor(
                epochID: epochID,
                order: .reverse,
                limit: BoundedHistoryPolicy.achievementLimit + 1
            ))
            achievementPageIsPartial = achievementRaw.count > BoundedHistoryPolicy.achievementLimit
            achievementStones = try AchievementStonePolicy.resolvedVisibleCandidates(
                from: Array(achievementRaw.prefix(BoundedHistoryPolicy.achievementLimit)),
                context: modelContext
            )
            achievementLoadFailed = false
        } catch {
            achievementLoadFailed = true
        }
    }

    /// Reads through AccumulationTimelineLoader, off the main thread. On an
    /// error the section stays hidden, as it does for a person with no history.
    @MainActor
    private func loadMonthSummaries(for key: String) async {
        guard LogHistoryLoadPolicy.isVisible(scenePhase) else { return }
        loadAchievementsBeforeLifetimeReads()
        let epochID = currentEpochID
        // Gregorian like the month titles, 年月, Wrapped and the card, so a
        // row opens the same month it is labelled with on any calendar.
        let calendar = PomoGemCalendar.gregorian
        let now = Date.now
        do {
            let container = modelContext.container
            let summaries = try await readQueue.run {
                try await AccumulationTimelineLoader.read(from: container) { repository in
                    try await repository.recentMonthSummaries(
                        endingAt: now,
                        currentEpochID: epochID,
                        calendar: calendar
                    )
                }
            }
            try Task.checkCancellation()
            guard key == monthSummaryKey else { return }
            monthSummaries = summaries.map {
                LogMonthSummary(
                    month: WrappedMonth(containing: $0.monthStart, calendar: calendar),
                    // Credited time from the month's mass, like the tiles
                    // above and Wrapped (see DurationPresentation).
                    minutes: DurationPresentation.focusMinutes(grams: $0.grams),
                    pebbleCount: $0.sessionCount
                )
            }
            completeLoadAudit(.months)
        } catch is CancellationError {
            return
        } catch {
            guard key == monthSummaryKey else { return }
            monthSummaries = []
            completeLoadAudit(.months)
        }
    }

    private func editableSubjects(
        for selection: AchievementEditSelection
    ) -> [Subject] {
        SubjectSyncPolicy.canonicalSubjects(from: subjects)
        .filter { !$0.isArchived || $0.id == selection.subjectID }
        .sorted { lhs, rhs in
            if lhs.sortOrder == rhs.sortOrder { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    @MainActor
    private func saveAchievement(
        selection: AchievementEditSelection,
        draft: AchievementEditDraft
    ) -> String? {
        do {
            let values = try achievementRevisionRows(for: selection.id, epochID: selection.dataEpochID)
            guard let canonical = AchievementStonePolicy.canonicalStone(from: values),
                  canonical.deletedAt == nil else {
                loadAchievements()
                return "この記念石は別の端末ですでに削除されています。"
            }
            let result: AchievementStoneRevisionPolicy.MutationResult
            if let subjectID = draft.subjectID {
                guard let subject = subjects.first(where: { $0.id == subjectID }) else {
                    return "選んだテーマが見つかりません。テーマを選び直してください。"
                }
                result = AchievementStoneRevisionPolicy.edit(
                    values,
                    subject: subject,
                    kind: draft.kind,
                    note: draft.note,
                    achievedAt: draft.achievedAt
                )
            } else {
                // The stone's own theme is not offered (deleted in Settings).
                // Keep it exactly as it is rather than relabelling the stone.
                result = AchievementStoneRevisionPolicy.editKeepingSubject(
                    values,
                    kind: draft.kind,
                    note: draft.note,
                    achievedAt: draft.achievedAt
                )
            }
            guard result == .applied else {
                return "この記念石の編集履歴が上限に達したため、編集できませんでした。"
            }
            try modelContext.save()
            loadAchievements()
            return nil
        } catch {
            modelContext.rollback()
            loadAchievements()
            return "編集内容を保存できませんでした。通信状態を確認して、もう一度お試しください。"
        }
    }

    @MainActor
    private func deleteAchievement(
        selection: AchievementEditSelection
    ) -> String? {
        do {
            let values = try achievementRevisionRows(for: selection.id, epochID: selection.dataEpochID)
            guard let canonical = AchievementStonePolicy.canonicalStone(from: values) else {
                return "この記念石は見つかりませんでした。"
            }
            guard canonical.deletedAt == nil else {
                loadAchievements()
                return "この記念石は別の端末ですでに削除されています。"
            }
            let snapshot = AchievementStoneRevisionSnapshot(canonical)
            guard AchievementStoneRevisionPolicy.delete(values) == .applied else {
                return "この記念石の編集履歴が上限に達したため、削除できませんでした。"
            }
            try modelContext.save()
            pendingAchievementUndo = snapshot
            loadAchievements()
            return nil
        } catch {
            modelContext.rollback()
            loadAchievements()
            return "記念石を削除できませんでした。通信状態を確認して、もう一度お試しください。"
        }
    }

    @MainActor
    private func undoAchievementDeletion(
        _ snapshot: AchievementStoneRevisionSnapshot
    ) {
        do {
            let values = try achievementRevisionRows(
                for: snapshot.id,
                epochID: snapshot.dataEpochID
            )
            guard let canonical = AchievementStonePolicy.canonicalStone(from: values) else {
                mutationError = "削除した記念石が見つからないため、元に戻せませんでした。"
                return
            }
            if canonical.deletedAt == nil {
                pendingAchievementUndo = nil
                loadAchievements()
                return
            }
            let subject = snapshot.subjectID.flatMap { subjectID in
                subjects.first { $0.id == subjectID }
            }
            guard AchievementStoneRevisionPolicy.restore(
                values,
                snapshot: snapshot,
                subject: subject
            ) == .applied else {
                mutationError = "この記念石の編集履歴が上限に達したため、元に戻せませんでした。"
                return
            }
            try modelContext.save()
            pendingAchievementUndo = nil
            loadAchievements()
        } catch {
            modelContext.rollback()
            loadAchievements()
            mutationError = "削除した記念石を元に戻せませんでした。通信状態を確認して、もう一度お試しください。"
        }
    }

    @MainActor
    private func achievementRevisionRows(
        for id: UUID,
        epochID: UUID?
    ) throws -> [AchievementStone] {
        let rows = try modelContext.fetch(BoundedHistoryPolicy.achievementRevisionDescriptor(
            id: id,
            epochID: epochID
        ))
        guard rows.count <= AchievementStonePolicy.maximumPhysicalRowsPerLogicalStone else {
            throw AchievementMutationError.replicaSetOverflow
        }
        return rows
    }

    private func achievementArchiveDescription(count: Int) -> String {
        if achievementPageIsPartial {
            return "瓶では新しい12個が動き、ここでは最新\(count)個を表示しています。行をタップすると編集・削除できます。"
        }
        return "瓶では新しい12個が動き、これまでの\(count)個を振り返れます。行をタップすると編集・削除できます。"
    }

    private func formatMass(_ grams: Int) -> String {
        grams >= 1_000 ? String(format: "%.1fkg", Double(grams) / 1_000) : "\(grams)g"
    }

    private func formatMinutes(_ minutes: Int) -> String {
        DurationPresentation.minutesLabel(minutes)
    }
}

private enum AchievementMutationError: Error {
    case replicaSetOverflow
}

private struct LogMonthSummary: Identifiable {
    let month: WrappedMonth
    let minutes: Int
    let pebbleCount: Int

    var id: Date { month.id }

    func rowLabel(formatMinutes: (Int) -> String) -> String {
        "\(formatMinutes(minutes))・\(pebbleCount)粒"
    }
}

private struct DailyMassChartDescriptor: AXChartDescriptorRepresentable {
    let values: [LogDailyMass]
    let periodTitle: String
    let isPartial: Bool

    var accessibilitySummary: String {
        let safeValues = values.map { max(0, $0.grams) }
        let total = NonnegativeIntPolicy.sum(safeValues)
        guard !values.isEmpty else {
            return "\(periodTitle)の質量の推移。日ごとのデータはありません。\(totalLabel)0グラム。"
        }
        guard let maximum = safeValues.max(), maximum > 0,
              let maximumIndex = safeValues.firstIndex(of: maximum)
        else {
            return "\(periodTitle)の質量の推移。\(values.count)日分、\(totalLabel)0グラム。記録された質量はありません。"
        }
        let maximumDate = spokenDate(values[maximumIndex].date)
        return "\(periodTitle)の質量の推移。\(values.count)日分、\(totalLabel)\(total)グラム。最大は\(maximumDate)の\(maximum)グラム。"
    }

    private var totalLabel: String {
        isPartial ? "最新記録の表示分合計" : "期間合計"
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        let categories = values.map { spokenDate($0.date) }
        let maximum = values.map { max(0, $0.grams) }.max() ?? 0
        let upperBound = Double(max(1, maximum))
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "日付",
            categoryOrder: categories
        )
        let yAxis = AXNumericDataAxisDescriptor(
            title: "質量",
            range: 0 ... upperBound,
            gridlinePositions: maximum > 0 ? [0, upperBound] : [0]
        ) { value in
            "\(NonnegativeIntPolicy.clamped(value.rounded()))グラム"
        }
        let points = values.map { item in
            let date = spokenDate(item.date)
            let grams = max(0, item.grams)
            return AXDataPoint(
                x: date,
                y: Double(grams),
                label: "\(date)、\(grams)グラム"
            )
        }
        let series = AXDataSeriesDescriptor(
            name: "日ごとの質量",
            isContinuous: false,
            dataPoints: points
        )
        return AXChartDescriptor(
            title: "質量の推移",
            summary: accessibilitySummary,
            xAxis: xAxis,
            yAxis: yAxis,
            series: [series]
        )
    }

    private func spokenDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).day().weekday(.wide))
    }
}

/// One row of 「まとまり粒アーカイブ」. Roots are built on the repository's
/// actor; legacy layers here, with the records on screen that they hold.
struct LogAggregateArchiveItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let level: Int
    let pebbleCount: Int
    let grams: Int
    let measuredPebbleCount: Int
    let manualPebbleCount: Int
    let goldPebbleCount: Int
    let prismPebbleCount: Int
    let colorMix: [StratumColorFraction]
    let subjectMix: [AggregateSubjectFraction]
    let periodStart: Date
    let periodEnd: Date

    init(aggregate: AggregatePebble) {
        id = aggregate.id
        createdAt = aggregate.createdAt
        level = aggregate.level
        pebbleCount = aggregate.pebbleCount
        grams = aggregate.grams
        measuredPebbleCount = aggregate.measuredPebbleCount
        manualPebbleCount = aggregate.manualPebbleCount
        goldPebbleCount = aggregate.goldPebbleCount
        prismPebbleCount = aggregate.prismPebbleCount
        colorMix = aggregate.colorMix
        subjectMix = aggregate.subjectMix
        periodStart = aggregate.periodStart
        periodEnd = aggregate.periodEnd
    }

    init(legacy layer: LogLegacyLayer, members: [LogSessionRecord]) {
        id = layer.id
        createdAt = layer.bakedAt
        level = StrataMath.decimalAggregateLevel(forPebbleCount: layer.pebbleCount)
        pebbleCount = layer.pebbleCount
        grams = layer.grams
        measuredPebbleCount = members.isEmpty
            ? layer.pebbleCount
            : members.filter { $0.source.isMeasured }.count
        manualPebbleCount = members.filter { !$0.source.isMeasured }.count
        let rewards = RareRewardCounts.total(members.map(\.rareRewardCounts))
        goldPebbleCount = rewards.goldCount
        prismPebbleCount = rewards.prismCount
        colorMix = layer.colorMix
        subjectMix = StrataMath.mergedSubjectMix(
            members.map {
                [AggregateSubjectFraction(
                    name: $0.displaySubjectName,
                    colorHex: $0.displaySubjectColorHex,
                    pebbleCount: 1
                )]
            }
        )
        periodStart = members.map(\.startAt).min() ?? layer.bakedAt
        periodEnd = members.map(\.endAt).max() ?? layer.bakedAt
    }

    var periodLabel: String {
        let calendar = Calendar.autoupdatingCurrent
        let start = periodStart.formatted(.dateTime.year().month().day())
        guard !calendar.isDate(periodStart, inSameDayAs: periodEnd) else { return start }
        return "\(start) – \(periodEnd.formatted(.dateTime.year().month().day()))"
    }

    var formattedMass: String {
        grams >= 1_000 ? String(format: "%.1fkg", Double(grams) / 1_000) : "\(grams)g"
    }
}

private struct AggregateArchiveRow: View {
    let item: LogAggregateArchiveItem

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 13) {
                AggregateArchiveSwatch(item: item)

                VStack(alignment: .leading, spacing: 3) {
                    Text("×\(item.pebbleCount) のまとまり")
                        .font(.system(.headline, design: .rounded, weight: .heavy))
                    Text(item.periodLabel)
                        .font(.caption2)
                        .foregroundStyle(PomoGemTheme.muted)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(item.formattedMass)
                        .font(.system(.subheadline, design: .rounded, weight: .heavy))
                    Text("元 \(item.pebbleCount)粒")
                        .font(.caption2)
                        .foregroundStyle(PomoGemTheme.muted)
                }
            }

            AggregateColorBar(mix: item.colorMix)

            if !item.subjectMix.isEmpty {
                VStack(spacing: 5) {
                    ForEach(Array(item.subjectMix.prefix(3).enumerated()), id: \.offset) { _, subject in
                        HStack(spacing: 7) {
                            Circle()
                                .fill(Color(hex: subject.colorHex))
                                .frame(width: 7, height: 7)
                            Text(SubjectNamePolicy.displayName(subject.name))
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Text("\(subject.pebbleCount)粒")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(PomoGemTheme.muted)
                        }
                    }
                    if item.subjectMix.count > 3 {
                        Text("ほか \(item.subjectMix.count - 3)テーマ")
                            .font(.caption2)
                            .foregroundStyle(PomoGemTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) { compositionBadges }
                VStack(alignment: .leading, spacing: 7) { compositionBadges }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        let base = "\(item.pebbleCount)粒のまとまり、\(item.formattedMass)、\(item.periodLabel)、実測\(item.measuredPebbleCount)粒、手動\(item.manualPebbleCount)粒"
        guard RareRewardReleasePolicy.isEnabled else { return base }
        return "\(base)、金\(item.goldPebbleCount)粒、虹\(item.prismPebbleCount)粒"
    }

    @ViewBuilder
    private var compositionBadges: some View {
        AggregateStatBadge(symbol: "timer", text: "実測 \(item.measuredPebbleCount)")
        AggregateStatBadge(symbol: "hand.tap", text: "手動 \(item.manualPebbleCount)")
        if RareRewardReleasePolicy.isEnabled {
            AggregateStatBadge(symbol: "sparkles", text: "金 \(item.goldPebbleCount)")
            AggregateStatBadge(symbol: "rainbow", text: "虹 \(item.prismPebbleCount)")
        }
    }
}

private struct AggregateArchiveSwatch: View {
    let item: LogAggregateArchiveItem

    private var colors: [Color] {
        let values = item.colorMix.prefix(5).map { Color(hex: $0.hex) }
        return values.isEmpty ? [PomoGemTheme.raised, PomoGemTheme.card] : values
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(AngularGradient(colors: colors + [colors[0]], center: .center))
            Circle()
                .fill(.black.opacity(0.22))
            ForEach(0..<min(item.level, 3), id: \.self) { ring in
                Circle()
                    .stroke(.white.opacity(0.18 + Double(ring) * 0.08), lineWidth: 1)
                    .padding(CGFloat(ring) * 4 + 3)
            }
            Text("×\(item.pebbleCount)")
                .font(.system(size: item.pebbleCount >= 1_000 ? 8 : 10, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.65)
                .padding(6)
        }
        .frame(width: 50, height: 50)
        .overlay { Circle().stroke(.white.opacity(0.18), lineWidth: 1) }
        .shadow(color: colors[0].opacity(0.22), radius: 8, y: 4)
        .accessibilityHidden(true)
    }
}

private struct AggregateColorBar: View {
    let mix: [StratumColorFraction]

    var body: some View {
        GeometryReader { proxy in
            if mix.isEmpty {
                Capsule().fill(PomoGemTheme.raised)
            } else {
                HStack(spacing: 1) {
                    ForEach(Array(mix.enumerated()), id: \.offset) { _, fraction in
                        Color(hex: fraction.hex)
                            .frame(width: max(2, proxy.size.width * fraction.fraction))
                    }
                }
            }
        }
        .frame(height: 7)
        .clipShape(Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.08), lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

private struct AggregateStatBadge: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(PomoGemTheme.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(PomoGemTheme.raised.opacity(0.7), in: Capsule())
    }
}

private struct SummaryTile: View {
    let label: String
    let value: String
    let symbol: String
    /// Stable across the 今週／今月 wording, for the device audit.
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.caption).foregroundStyle(PomoGemTheme.amber)
            Text(value).font(.system(.headline, design: .rounded, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.72)
            Text(label).font(.caption2).foregroundStyle(PomoGemTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

/// Neutral while the first page loads: never the empty-history copy.
private struct HistoryLoadingPlaceholder: View {
    var body: some View {
        ProgressView()
            .tint(PomoGemTheme.amber)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            .accessibilityLabel(Text("記録を読み込み中", tableName: "Log", comment: "VoiceOver: Log is loading"))
            .accessibilityIdentifier("log.loading")
    }
}

/// The period tiles while their page is on its way: placeholder shapes,
/// hidden from VoiceOver, under one element that says 記録 is loading. The
/// placeholder figures are no period's: 「0分、積んだ時間」 read aloud
/// would claim an empty period over years of history.
private struct LoadingSummaryTiles: ViewModifier {
    let isLoading: Bool

    func body(content: Content) -> some View {
        if isLoading {
            content
                .redacted(reason: .placeholder)
                .accessibilityHidden(true)
                .overlay {
                    Color.clear
                        .accessibilityElement()
                        .accessibilityLabel(Text("記録を読み込み中", tableName: "Log", comment: "VoiceOver: Log is loading"))
                        .accessibilityIdentifier("log.summary.loading")
                }
        } else {
            content
        }
    }
}

private struct EmptyChartMessage: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(PomoGemTheme.muted)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
    }
}

private struct RareStat: View {
    let kind: PebbleKind
    let count: Int
    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(kind == .gold ? AnyShapeStyle(Color("pebble.gold")) : AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .blue, .purple], center: .center)))
                .frame(width: 28, height: 28)
                .shadow(color: PomoGemTheme.amber.opacity(kind == .gold ? 0.32 : 0.16), radius: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind == .gold ? "金" : "虹").font(.caption2).foregroundStyle(PomoGemTheme.muted)
                Text("×\(count)").font(.system(.headline, design: .rounded, weight: .heavy))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AchievementEditSelection: Identifiable {
    let id: UUID
    let dataEpochID: UUID?
    let subjectID: UUID?
    /// The stone still points at a theme that was deleted in Settings.
    let subjectIsDeleted: Bool
    let subjectName: String
    let subjectColorHex: String
    let kind: AchievementKind
    let note: String
    let achievedAt: Date

    init(_ stone: AchievementStone) {
        id = stone.id
        dataEpochID = stone.dataEpochID
        subjectID = stone.subject?.id
        subjectIsDeleted = stone.subject?.deletedAt != nil
        subjectName = stone.displaySubjectName
        subjectColorHex = stone.displaySubjectColorHex
        kind = stone.kind
        note = stone.note
        achievedAt = stone.achievedAt
    }
}

private struct AchievementEditDraft {
    /// `nil` keeps the stone's current theme link and name/color snapshots.
    let subjectID: UUID?
    let kind: AchievementKind
    let note: String
    let achievedAt: Date
}

/// 「成果を編集」. Like 「成果を積む」 on Home, 「変更を保存」 is pinned above
/// the home indicator, and above the keyboard while the memo is being typed:
/// on an iPhone SE the keyboard used to cover it at the bottom of the form.
private struct AchievementEditorSheet: View {
    private static let noteFieldScrollID = "achievement.editor.note-field"

    let selection: AchievementEditSelection
    let subjects: [Subject]
    let onSave: (AchievementEditDraft) -> String?
    let onDelete: () -> String?

    /// Stands for "keep this stone's theme as it is" when that theme is not
    /// among the offered ones (deleted in Settings, or not linked on this
    /// iPhone). It never equals a live theme's ID, so "a theme is selected"
    /// still decides whether 変更を保存 is available.
    private let keptSubjectChoiceID: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedSubjectID: UUID?
    @State private var kind: AchievementKind
    @State private var note: String
    @State private var achievedAt: Date
    @State private var errorMessage: String?
    @State private var confirmsDeletion = false
    @State private var isCommitting = false
    @State private var noteIsFocused = false

    init(
        selection: AchievementEditSelection,
        subjects: [Subject],
        onSave: @escaping (AchievementEditDraft) -> String?,
        onDelete: @escaping () -> String?
    ) {
        self.selection = selection
        self.subjects = subjects
        self.onSave = onSave
        self.onDelete = onDelete
        // Never fall back to an unrelated theme: a stone whose theme is not
        // offered starts on "keep as it is", so saving a memo or date fix
        // cannot silently relabel it. Any live theme stays one tap away.
        let offeredSubjectID = selection.subjectID.flatMap { id in
            subjects.contains(where: { $0.id == id }) ? id : nil
        }
        // A stone that lost its link (never a deleted theme) may relink to
        // the live theme with the same name and color: nothing visible moves.
        let matchingSubjectID = selection.subjectID == nil
            ? subjects.first(where: {
                $0.safeDisplayName == selection.subjectName
                    && $0.colorHex.caseInsensitiveCompare(selection.subjectColorHex) == .orderedSame
            })?.id
            : nil
        let keptChoiceID = offeredSubjectID == nil && matchingSubjectID == nil
            ? (selection.subjectID ?? selection.id)
            : nil
        keptSubjectChoiceID = keptChoiceID
        _selectedSubjectID = State(
            initialValue: offeredSubjectID ?? matchingSubjectID ?? keptChoiceID
        )
        _kind = State(initialValue: selection.kind)
        _note = State(initialValue: selection.note)
        _achievedAt = State(initialValue: min(selection.achievedAt, .now))
    }

    private var selectedSubject: Subject? {
        subjects.first { $0.id == selectedSubjectID }
    }

    private var keepsOriginalSubject: Bool {
        keptSubjectChoiceID != nil && selectedSubjectID == keptSubjectChoiceID
    }

    private var selectedSubjectTitle: String? {
        keepsOriginalSubject ? selection.subjectName : selectedSubject?.safeDisplayName
    }

    private var keptSubjectMenuTitle: String {
        selection.subjectIsDeleted
            ? String(localized: "\(selection.subjectName)（削除したテーマ）", table: "Log", comment: "Milestone editor theme menu: keep the milestone's deleted theme; the argument is the theme name")
            : String(localized: "\(selection.subjectName)（今のまま）", table: "Log", comment: "Milestone editor theme menu: keep the milestone's theme as it is; the argument is the theme name")
    }

    private var keptSubjectNotice: String {
        selection.subjectIsDeleted
            ? String(localized: "「\(selection.subjectName)」は設定で削除したテーマです。ほかのテーマを選ばなければ、このまま残ります。", table: "Log", comment: "Milestone editor: why a deleted theme is shown; the argument is the theme name")
            : String(localized: "「\(selection.subjectName)」は今のテーマ一覧にありません。ほかのテーマを選ばなければ、このまま残ります。", table: "Log", comment: "Milestone editor: why a theme missing from the list is shown; the argument is the theme name")
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    editorHeader
                    typeEditor
                    subjectEditor
                    noteEditor
                        .id(Self.noteFieldScrollID)
                    dateEditor

                    Label(
                        "記念石は0gです。編集・削除しても、集中時間・質量・通常の粒数は変わりません。",
                        systemImage: "checkmark.shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                    // Deleting stays at the end of the form, away from the
                    // pinned 変更を保存.
                    Button(role: .destructive) {
                        confirmsDeletion = true
                    } label: {
                        Label("この記念石を削除", systemImage: "trash")
                    }
                    .buttonStyle(PomoGemDestructiveButtonStyle())
                    .disabled(isCommitting)
                    .accessibilityIdentifier("achievement.editor.delete")
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.immediately)
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                saveBar
            }
            // With the keyboard up on a small phone only a sliver is left
            // above the pinned bar, and the system counts a field half under
            // the bar as visible. Bring the whole memo field above the bar,
            // and again when the bar grows to explain an over-long memo.
            .onChange(of: noteIsFocused) { _, focused in
                guard focused else { return }
                revealNoteField(scrollProxy, after: .milliseconds(350))
            }
            .onChange(of: AchievementNotePolicy.isTooLong(note)) { _, _ in
                guard noteIsFocused else { return }
                revealNoteField(scrollProxy, after: .milliseconds(50))
            }
            }
            .background(NightBackground())
            .navigationTitle("成果を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PomoGemSheetCloseButton(
                        accessibilityIdentifier: "achievement.editor.close"
                    ) {
                        dismiss()
                    }
                    .disabled(isCommitting)
                }
            }
            .alert("この記念石を削除しますか？", isPresented: $confirmsDeletion) {
                Button("削除", role: .destructive) { delete() }
                    .accessibilityIdentifier("achievement.editor.confirm-delete")
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("記録・瓶・共有から非表示になります。質量は変わりません。削除直後は記録画面で元に戻せます。")
            }
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: kind.gemEdgeHex), Color(hex: kind.gemBaseHex)],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 34
                        )
                    )
                Text(kind.shortMark)
                    .font(.system(size: kind == .perfectScore ? 10 : 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)
            .shadow(color: Color(hex: kind.gemGlowHex).opacity(0.4), radius: 10)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                SectionEyebrow(text: "MILESTONE")
                Text(AchievementStone.sanitizedNote(note).isEmpty ? kind.title : AchievementStone.sanitizedNote(note))
                    .font(PomoGemTheme.brand(22))
                    .lineLimit(2)
            }
        }
    }

    private var typeEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            editorLabel("種類")
            Menu {
                ForEach(AchievementKind.allCases) { candidate in
                    Button {
                        kind = candidate
                    } label: {
                        if candidate == kind {
                            Label(candidate.title, systemImage: "checkmark")
                        } else {
                            Text(candidate.title)
                        }
                    }
                }
            } label: {
                editorMenuLabel(
                    title: kind.title,
                    colorHex: kind.gemBaseHex,
                    symbol: kind.systemImage
                )
            }
            .accessibilityLabel("種類、\(kind.title)")
            .accessibilityHint("記念石の種類を変更できます")
            .accessibilityIdentifier("achievement.editor.kind")
        }
    }

    private var subjectEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            editorLabel("テーマ")
            Menu {
                if let keptSubjectChoiceID {
                    Button {
                        selectedSubjectID = keptSubjectChoiceID
                    } label: {
                        if keepsOriginalSubject {
                            Label(keptSubjectMenuTitle, systemImage: "checkmark")
                        } else {
                            Text(keptSubjectMenuTitle)
                        }
                    }
                }
                ForEach(subjects) { subject in
                    Button {
                        selectedSubjectID = subject.id
                    } label: {
                        if selectedSubjectID == subject.id {
                            Label(subject.safeDisplayName, systemImage: "checkmark")
                        } else {
                            Text(subject.safeDisplayName)
                        }
                    }
                }
            } label: {
                editorMenuLabel(
                    title: selectedSubjectTitle ?? "テーマを選択",
                    colorHex: keepsOriginalSubject
                        ? selection.subjectColorHex
                        : (selectedSubject?.colorHex ?? Constants.Color.textMute),
                    symbol: "folder.fill"
                )
            }
            .disabled(subjects.isEmpty && keptSubjectChoiceID == nil)
            .accessibilityLabel("テーマ、\(selectedSubjectTitle ?? "未選択")")
            .accessibilityHint(
                subjects.isEmpty
                    ? (keptSubjectChoiceID == nil
                        ? "テーマがないため変更できません"
                        : String(localized: "ほかに選べるテーマはありません", table: "Log", comment: "VoiceOver hint: no other theme to choose"))
                    : "成果を結びつけるテーマを変更できます"
            )
            .accessibilityIdentifier("achievement.editor.subject")

            if keepsOriginalSubject {
                Text(keptSubjectNotice)
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("achievement.editor.kept-subject")
            }
        }
    }

    private var noteEditor: some View {
        // Kept as typed (spaces and IME composition included); bounded when
        // saved. See AchievementNotePolicy.
        AchievementNoteField(
            title: "成果メモ（任意）",
            placeholder: kind.notePlaceholder,
            text: $note,
            accessibilityIdentifier: "achievement.editor.note",
            onFocusChange: { noteIsFocused = $0 }
        )
    }

    /// The pinned bar. Why 変更を保存 is unavailable, or why saving failed,
    /// sits right above it, as in 「成果を積む」.
    private var saveBar: some View {
        VStack(spacing: 8) {
            AchievementNoteLimitMessage(text: note)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.red.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("achievement.editor.error")
            }
            Button {
                save()
            } label: {
                if isCommitting {
                    ProgressView().tint(PomoGemTheme.background)
                } else {
                    Label("変更を保存", systemImage: "checkmark.circle.fill")
                }
            }
            .buttonStyle(PomoGemPrimaryButtonStyle())
            .disabled(selectedSubjectID == nil || isCommitting || AchievementNotePolicy.isTooLong(note))
            .accessibilityIdentifier("achievement.editor.save")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider().overlay(PomoGemTheme.glassEdge.opacity(0.16))
        }
    }

    private func revealNoteField(_ scrollProxy: ScrollViewProxy, after delay: Duration) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard noteIsFocused else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                // nil: the least scroll that shows the whole field, so
                // nothing moves on a phone where it is already clear.
                scrollProxy.scrollTo(Self.noteFieldScrollID, anchor: nil)
            }
        }
    }

    private var dateEditor: some View {
        DatePicker(
            "達成した日",
            selection: $achievedAt,
            in: ...Date.now,
            displayedComponents: .date
        )
        .datePickerStyle(.compact)
        .padding(14)
        .background(PomoGemTheme.raised, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("achievement.editor.date")
    }

    private func editorLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(PomoGemTheme.muted)
    }

    private func editorMenuLabel(
        title: String,
        colorHex: String,
        symbol: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color(hex: colorHex))
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.body, design: .rounded, weight: .bold))
                .foregroundStyle(PomoGemTheme.text)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(PomoGemTheme.raised, in: RoundedRectangle(cornerRadius: 12))
    }

    private func save() {
        guard !isCommitting, let selectedSubjectID else { return }
        isCommitting = true
        errorMessage = onSave(AchievementEditDraft(
            subjectID: selectedSubjectID == keptSubjectChoiceID ? nil : selectedSubjectID,
            kind: kind,
            note: note,
            achievedAt: achievedAt
        ))
        isCommitting = false
        if errorMessage == nil { dismiss() }
    }

    private func delete() {
        guard !isCommitting else { return }
        isCommitting = true
        errorMessage = onDelete()
        isCommitting = false
        if errorMessage == nil { dismiss() }
    }
}

private struct AchievementHistoryRow: View {
    let stone: AchievementStone

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(hex: stone.kind.gemEdgeHex),
                                Color(hex: stone.kind.gemBaseHex)
                            ],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 30
                        )
                    )
                Circle()
                    .stroke(Color(hex: stone.kind.gemEdgeHex), lineWidth: 2)
                Text(stone.kind.shortMark)
                    .font(.system(size: stone.kind == .perfectScore ? 8 : 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            .shadow(color: Color(hex: stone.kind.gemGlowHex).opacity(0.42), radius: 8)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(stone.displayTitle)
                    .font(.subheadline.weight(.semibold))
                Text("\(stone.displaySubjectName)・\(stone.kind.title)")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
            }
            Spacer()
            Text(stone.achievedAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PomoGemTheme.muted)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(stone.displaySubjectName)、\(stone.kind.title)、\(stone.displayTitle)、\(stone.achievedAt.formatted(date: .long, time: .omitted))"
        )
    }
}
