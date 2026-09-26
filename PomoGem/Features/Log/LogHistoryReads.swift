import Foundation
import SwiftData

/// 記録's reads of the lifetime history, run on AccumulationTimelineRepository's
/// actor through AccumulationTimelineLoader, so the main thread never waits
/// for them.
///
/// They are the same bounded queries 記録 used to run on the main context:
/// the 今週／今月 page of at most `periodSessionLimit` logical records, the
/// newest `recentSessionLimit`, and the newest aggregate roots. Only where
/// they run changed. Nothing here pages through the whole history (see
/// Docs/SyncMaintenanceArchitecture.md §7.3): each read is one bounded
/// window, resolved exactly and handed back as values. SwiftData objects
/// never leave the actor.
extension AccumulationTimelineRepository {
    /// The 今週／今月 page and everything 記録 draws from it.
    func logPeriodContent(
        period: LogView.Period,
        interval: DateInterval?,
        calendar: Calendar,
        currentEpochID: UUID?
    ) throws -> LogPeriodContent {
        let page = try BoundedHistoryPolicy.resolvedSessionPage(
            context: modelContext,
            epochID: currentEpochID,
            start: interval?.start ?? .distantPast,
            end: interval?.end,
            order: .reverse,
            logicalLimit: BoundedHistoryPolicy.periodSessionLimit
        )
        try Task.checkCancellation()
        let records = StudySessionSyncPolicy.canonicalSessions(from: page.sessions)
            .map(LogSessionRecord.init)
        return LogPeriodContent(
            period: period,
            epochID: currentEpochID,
            records: records,
            isPartial: page.isPartial,
            presentation: LogPeriodPresentation(
                records: records,
                interval: interval,
                calendar: calendar
            )
        )
    }

    /// The newest thirty records and, when the jar's aggregates may be
    /// summarized, the newest aggregate roots and legacy layers.
    ///
    /// `aggregateCacheStamp` is the verified projection stamp when the read
    /// starts (`AggregateProjectionPresentationContext.verifiedCacheStamp`),
    /// nil while iCloud verification is pending. The archive carries it, so
    /// 記録 shows it only while that verification is still the current one.
    func logRecentContent(
        currentEpochID: UUID?,
        aggregateCacheStamp: AggregateProjectionCacheStamp?
    ) throws -> LogRecentContent {
        let recentPage = try BoundedHistoryPolicy.resolvedSessionPage(
            context: modelContext,
            epochID: currentEpochID,
            order: .reverse,
            logicalLimit: BoundedHistoryPolicy.recentSessionLimit
        )
        let records = recentPage.sessions.map(LogSessionRecord.init)
        guard let aggregateCacheStamp else {
            return LogRecentContent(
                epochID: currentEpochID,
                records: records,
                aggregates: .empty
            )
        }
        try Task.checkCancellation()

        let aggregateRaw = try modelContext.fetch(BoundedHistoryPolicy.rootAggregateDescriptor(
            epochID: currentEpochID,
            limit: BoundedHistoryPolicy.aggregateRootLimit + 1
        ))
        let aggregates = Array(aggregateRaw.prefix(BoundedHistoryPolicy.aggregateRootLimit))
        let strata = try modelContext.fetch(BoundedHistoryPolicy.legacyAggregateDescriptor(
            epochID: currentEpochID,
            limit: BoundedHistoryPolicy.legacyAggregateLimit
        ))
        // Only roots are shown. A ×100 parent already contains its ten ×10
        // children, so showing both as peers would double-count history. A
        // legacy layer that an aggregate replaced is left out for the same
        // reason.
        let aggregateIDs = Set(aggregates.map(\.id))
        return LogRecentContent(
            epochID: currentEpochID,
            records: records,
            aggregates: LogAggregateArchive(
                roots: AggregatePebblePolicy.disjointRootSummaries(from: aggregates)
                    .map(LogAggregateArchiveItem.init(aggregate:)),
                legacyLayers: strata
                    .filter { !aggregateIDs.contains($0.id) }
                    .map(LogLegacyLayer.init),
                isPartial: aggregateRaw.count > BoundedHistoryPolicy.aggregateRootLimit,
                cacheStamp: aggregateCacheStamp
            )
        )
    }
}

/// One canonical record as 記録 uses it: the history row, plus what
/// 「テーマの構成」 groups by. Copied on the repository's actor.
struct LogSessionRecord: Identifiable, Equatable, Sendable {
    let row: HistorySessionSummary
    let subjectIDSnapshot: UUID?
    let subjectNameSnapshot: String
    let subjectColorHexSnapshot: String

    init(_ session: StudySession) {
        row = HistorySessionSummary(session)
        subjectIDSnapshot = session.subjectIDSnapshot
        subjectNameSnapshot = session.subjectNameSnapshot
        subjectColorHexSnapshot = session.subjectColorHexSnapshot
    }

    var id: UUID { row.id }
    var startAt: Date { row.startAt }
    var endAt: Date { row.endAt }
    var seconds: Int { row.seconds }
    var grams: Int { row.grams }
    var source: SessionSource { row.source }
    var rareRewardCounts: RareRewardCounts { row.rareRewardCounts }
    var displaySubjectName: String { row.subjectName }
    var displaySubjectColorHex: String { row.colorHex }

    /// Records keep their theme's ID; older ones without it group by the
    /// name and color they were saved with.
    var subjectCompositionKey: String {
        subjectIDSnapshot?.uuidString
            ?? "deleted:\(subjectNameSnapshot):\(subjectColorHexSnapshot)"
    }
}

/// One day's bar in 「質量の推移」.
struct LogDailyMass: Identifiable, Equatable, Sendable {
    var id: Date { date }
    let date: Date
    let grams: Int
}

/// One theme in 「テーマの構成」.
struct LogSubjectMass: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let colorHex: String
    let grams: Int
    let fraction: Double
}

/// What 記録 draws from one period page: the tiles, the daily bars and the
/// theme bar. Built once per page, on the repository's actor, instead of on
/// every redraw.
struct LogPeriodPresentation: Equatable, Sendable {
    let summary: LogPeriodSummary
    let dailyMass: [LogDailyMass]
    let subjectMass: [LogSubjectMass]

    init(
        records: [LogSessionRecord],
        interval: DateInterval?,
        calendar: Calendar
    ) {
        summary = LogPeriodSummary(records: records)
        if let interval {
            dailyMass = LogPeriodPolicy.days(in: interval, calendar: calendar).map { day in
                LogDailyMass(
                    date: day,
                    grams: NonnegativeIntPolicy.sum(
                        records
                            .filter { calendar.isDate($0.endAt, inSameDayAs: day) }
                            .map(\.grams)
                    )
                )
            }
        } else {
            dailyMass = []
        }

        let grouped = Dictionary(grouping: records, by: \.subjectCompositionKey)
        let values = grouped.compactMap { identity, records -> LogSubjectMass? in
            // The first record of a theme names it, in page order (newest
            // first), as before.
            guard let first = records.first else { return nil }
            return LogSubjectMass(
                id: identity,
                name: first.displaySubjectName,
                colorHex: first.displaySubjectColorHex,
                grams: NonnegativeIntPolicy.sum(records.map(\.grams)),
                fraction: 0
            )
        }
        let total = max(1, NonnegativeIntPolicy.sum(values.map(\.grams)))
        subjectMass = values
            .map {
                LogSubjectMass(
                    id: $0.id,
                    name: $0.name,
                    colorHex: $0.colorHex,
                    grams: $0.grams,
                    fraction: Double($0.grams) / Double(total)
                )
            }
            // Heaviest first; equal masses in a fixed order rather than the
            // dictionary's.
            .sorted {
                if $0.grams != $1.grams { return $0.grams > $1.grams }
                return $0.id < $1.id
            }
    }
}

/// The 今週／今月 page 記録 shows, with what it was read for.
struct LogPeriodContent: Equatable, Sendable {
    let period: LogView.Period
    let epochID: UUID?
    let records: [LogSessionRecord]
    /// More than `periodSessionLimit` records: the page is the newest part.
    let isPartial: Bool
    let presentation: LogPeriodPresentation

    /// Shown when the read fails: this period's name over no figures, never
    /// another period's figures.
    static func empty(
        period: LogView.Period,
        epochID: UUID?,
        interval: DateInterval?,
        calendar: Calendar
    ) -> LogPeriodContent {
        LogPeriodContent(
            period: period,
            epochID: epochID,
            records: [],
            isPartial: false,
            presentation: LogPeriodPresentation(
                records: [],
                interval: interval,
                calendar: calendar
            )
        )
    }
}

/// A pre-aggregate layer (Stratum) the archive still lists.
struct LogLegacyLayer: Identifiable, Equatable, Sendable {
    let id: UUID
    let bakedAt: Date
    let pebbleCount: Int
    let grams: Int
    let colorMix: [StratumColorFraction]
    let sessionIDs: Set<UUID>

    init(_ layer: Stratum) {
        id = layer.id
        bakedAt = layer.bakedAt
        pebbleCount = layer.pebbleCount
        grams = layer.grams
        colorMix = StrataMath.decodeColorMix(layer.colorMixJSON)
        sessionIDs = Set(layer.sessionIDs)
    }
}

/// 「まとまり粒アーカイブ」's rows before the legacy layers are matched with
/// the records on screen.
struct LogAggregateArchive: Equatable, Sendable {
    let roots: [LogAggregateArchiveItem]
    let legacyLayers: [LogLegacyLayer]
    /// More than `aggregateRootLimit` roots: the archive lists the newest.
    let isPartial: Bool
    /// The verified projection the archive was read under; nil when it was
    /// not read (iCloud verification pending). Aggregates are projections:
    /// after a verification is invalidated, an archive read before it is
    /// never shown again, even once the next verification succeeds (see
    /// `LogHistoryLoadPolicy.shownAggregateArchive`).
    let cacheStamp: AggregateProjectionCacheStamp?

    static let empty = LogAggregateArchive(
        roots: [],
        legacyLayers: [],
        isPartial: false,
        cacheStamp: nil
    )
}

/// Everything 記録 shows that does not depend on 今週／今月.
struct LogRecentContent: Equatable, Sendable {
    let epochID: UUID?
    /// The newest thirty records, newest first.
    let records: [LogSessionRecord]
    let aggregates: LogAggregateArchive
    /// The read failed before any of this epoch's records were read: 最近の記録
    /// says it could not read them, instead of loading forever or saying
    /// there is nothing to show.
    let isUnavailable: Bool

    init(
        epochID: UUID?,
        records: [LogSessionRecord],
        aggregates: LogAggregateArchive,
        isUnavailable: Bool = false
    ) {
        self.epochID = epochID
        self.records = records
        self.aggregates = aggregates
        self.isUnavailable = isUnavailable
    }

    static func unavailable(epochID: UUID?) -> LogRecentContent {
        LogRecentContent(
            epochID: epochID,
            records: [],
            aggregates: .empty,
            isUnavailable: true
        )
    }
}

/// Runs 記録's reads one at a time.
///
/// Core Data runs every request for a store on one serial SQL queue, so
/// three reads started together take no less time than three in a row. They
/// only fill that queue: a main-context fetch from elsewhere in the app
/// (Home's queries, the reminder check on a return from the background)
/// then waits for all of them, and the screen stops meanwhile. One read at a
/// time, it waits for one at most.
///
/// The 今週／今月 page goes ahead of reads still waiting: it is what the
/// person just asked for, and it heads the screen.
actor LogReadQueue {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var isReading = false
    private var waiters: [Waiter] = []

    /// Reads waiting for their turn.
    var waitingReadCount: Int { waiters.count }

    func run<Value: Sendable>(
        first: Bool = false,
        _ read: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire(first: first)
        defer { release() }
        return try await read()
    }

    private func acquire(first: Bool) async throws {
        try Task.checkCancellation()
        guard isReading else {
            isReading = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let waiter = Waiter(id: id, continuation: continuation)
                if first {
                    waiters.insert(waiter, at: 0)
                } else {
                    waiters.append(waiter)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// A read whose screen moved on leaves the line without reading.
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Hands the turn to the next read, if any.
    private func release() {
        guard !waiters.isEmpty else {
            isReading = false
            return
        }
        waiters.removeFirst().continuation.resume()
    }
}
