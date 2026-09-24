import Foundation
import SwiftData

enum AccumulationTimelineQueryPolicy {
    static let metricBatchSize = 256
    static let representativeRecordLimit = 96
    static let maximumBrowsableYearSpan = 200
    static let stabilityAttemptCount = 2
    /// 記録 shows this month and the eleven before it.
    static let recentMonthCount = 12

    static func latestResetMarkerDescriptor(
        now: Date = .now
    ) -> FetchDescriptor<ActivityResetMarker> {
        ActivityResetPolicy.currentMarkerDescriptor(now: now)
    }

    static func edgeSessionDescriptor(
        currentEpochID: UUID?,
        order: SortOrder
    ) -> FetchDescriptor<StudySession> {
        let predicate: Predicate<StudySession>
        if let currentEpochID {
            let epochID = currentEpochID
            predicate = #Predicate { session in
                session.dataEpochID == epochID
            }
        } else {
            predicate = #Predicate { session in
                session.dataEpochID == nil
            }
        }
        var descriptor = FetchDescriptor<StudySession>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\StudySession.endAt, order: order),
                SortDescriptor(\StudySession.id, order: order)
            ]
        )
        descriptor.fetchLimit = 1
        descriptor.propertiesToFetch = [\StudySession.id, \StudySession.endAt]
        return descriptor
    }

    static func periodMetricDescriptor(
        currentEpochID: UUID?,
        interval: DateInterval
    ) -> FetchDescriptor<StudySession> {
        let start = interval.start
        let end = interval.end
        let predicate: Predicate<StudySession>
        if let currentEpochID {
            let epochID = currentEpochID
            predicate = #Predicate { session in
                session.dataEpochID == epochID
                    && session.endAt >= start
                    && session.endAt < end
            }
        } else {
            predicate = #Predicate { session in
                session.dataEpochID == nil
                    && session.endAt >= start
                    && session.endAt < end
            }
        }
        return FetchDescriptor<StudySession>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\StudySession.endAt, order: .forward),
                SortDescriptor(\StudySession.id, order: .forward)
            ]
        )
    }

    static func periodCountDescriptor(
        currentEpochID: UUID?,
        interval: DateInterval
    ) -> FetchDescriptor<StudySession> {
        var descriptor = periodMetricDescriptor(
            currentEpochID: currentEpochID,
            interval: interval
        )
        descriptor.sortBy = []
        descriptor.propertiesToFetch = []
        return descriptor
    }

}

struct AccumulationTimelineEdge: Equatable, Sendable {
    let id: UUID
    let date: Date
}

struct AccumulationTimelineSnapshotStamp: Equatable, Sendable {
    let rawRowCount: Int
    let oldest: AccumulationTimelineEdge?
    let newest: AccumulationTimelineEdge?
}

enum AccumulationTimelineCoverage: Equatable, Sendable {
    case locallyStable(capturedAt: Date)
    case changedDuringLoad(capturedAt: Date)

    var isLocallyStable: Bool {
        if case .locallyStable = self { return true }
        return false
    }

    var capturedAt: Date {
        switch self {
        case let .locallyStable(capturedAt), let .changedDuringLoad(capturedAt):
            capturedAt
        }
    }
}

enum AccumulationTimelineStabilityPolicy {
    static func coverage(
        before: AccumulationTimelineSnapshotStamp,
        after: AccumulationTimelineSnapshotStamp,
        capturedAt: Date
    ) -> AccumulationTimelineCoverage {
        before == after
            ? .locallyStable(capturedAt: capturedAt)
            : .changedDuringLoad(capturedAt: capturedAt)
    }
}

struct AccumulationTimelineExtent: Equatable, Sendable {
    let currentEpochID: UUID?
    let stamp: AccumulationTimelineSnapshotStamp
    let capturedAt: Date

    var oldestDate: Date? { stamp.oldest?.date }
    var newestDate: Date? { stamp.newest?.date }
    var localRawRowCount: Int { stamp.rawRowCount }
}

struct AccumulationTimelineYear: Identifiable, Equatable, Hashable, Sendable {
    let year: Int
    let interval: DateInterval

    var id: Int { year }
    var title: String { "\(year)年" }
}

enum AccumulationTimelineYearPolicy {
    static func years(
        in extent: AccumulationTimelineExtent,
        calendar: Calendar
    ) throws -> [AccumulationTimelineYear] {
        guard let oldestDate = extent.oldestDate,
              let newestDate = extent.newestDate
        else { return [] }
        let oldestYear = calendar.component(.year, from: oldestDate)
        let newestYear = calendar.component(.year, from: newestDate)
        let span = newestYear - oldestYear
        guard span >= 0,
              span <= AccumulationTimelineQueryPolicy.maximumBrowsableYearSpan
        else { throw AccumulationTimelineRepositoryError.unsupportedDateSpan }

        return try stride(from: newestYear, through: oldestYear, by: -1).map { year in
            guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let end = calendar.date(byAdding: .year, value: 1, to: start)
            else { throw AccumulationTimelineRepositoryError.invalidCalendarInterval }
            return AccumulationTimelineYear(
                year: year,
                interval: DateInterval(start: start, end: end)
            )
        }
    }
}

struct AccumulationTimelineMonthSummary: Identifiable, Equatable, Sendable {
    let monthStart: Date
    let exactLocalCount: Int
    let exactLocalGrams: Int64

    var id: Date { monthStart }
}

/// One month of 記録's 「月ごとの瓶」: exact logical session count and focus
/// time for the months that have any record.
struct AccumulationRecentMonthSummary: Identifiable, Equatable, Sendable {
    let monthStart: Date
    let sessionCount: Int
    let seconds: Int

    var id: Date { monthStart }
}

struct AccumulationTimelineYearSummary: Equatable, Sendable {
    let year: AccumulationTimelineYear
    let months: [AccumulationTimelineMonthSummary]
    let exactLocalCount: Int
    let exactLocalGrams: Int64
    let coverage: AccumulationTimelineCoverage
}

/// One theme's part of a month or a day.
struct AccumulationTimelineThemeSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let colorHex: String
    let sessionCount: Int
    let seconds: Int
    let grams: Int64
}

/// A day with records inside a month.
struct AccumulationTimelineDaySummary: Identifiable, Equatable, Sendable {
    let dayStart: Date
    let sessionCount: Int
    let seconds: Int
    let grams: Int64
    /// Up to three theme colors, the most time first.
    let colorHexes: [String]

    var id: Date { dayStart }
}

/// One record as a history row shows it. A value copy, so views never hold
/// SwiftData objects that were read on the repository's actor.
struct HistorySessionSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let startAt: Date
    let endAt: Date
    let seconds: Int
    let grams: Int
    let subjectName: String
    let colorHex: String
    let source: SessionSource
    let pebbleKind: PebbleKind
    let rareRewardCounts: RareRewardCounts

    init(_ session: StudySession) {
        id = session.id
        startAt = session.startAt
        endAt = session.endAt
        seconds = NonnegativeIntPolicy.clamped(session.seconds)
        grams = NonnegativeIntPolicy.clamped(session.grams)
        subjectName = session.displaySubjectName
        colorHex = session.displaySubjectColorHex
        source = session.effectiveSource
        pebbleKind = session.pebbleKind
        rareRewardCounts = session.rareRewardCounts
    }
}

/// Every record of one day, newest first.
struct AccumulationTimelineDayDetail: Equatable, Sendable {
    let dayStart: Date
    let sessions: [HistorySessionSummary]
    let themes: [AccumulationTimelineThemeSummary]
    let totalSeconds: Int
    let totalGrams: Int64
    let coverage: AccumulationTimelineCoverage
}

/// Per-theme and per-day totals, computed from records that are already
/// exact and deduplicated. No streak-like counts: days are listed for
/// looking back, never tallied against the month.
enum AccumulationTimelineBreakdownPolicy {
    struct Entry: Sendable {
        let themeKey: String
        let themeName: String
        let colorHex: String
        let endAt: Date
        let seconds: Int
        let grams: Int64

        init(
            themeKey: String,
            themeName: String,
            colorHex: String,
            endAt: Date,
            seconds: Int,
            grams: Int64
        ) {
            self.themeKey = themeKey
            self.themeName = themeName
            self.colorHex = colorHex
            self.endAt = endAt
            self.seconds = NonnegativeIntPolicy.clamped(seconds)
            self.grams = max(0, grams)
        }

        /// A renamed theme stays one row: records group by the theme's ID,
        /// and the newest record names it. Records without an ID group by
        /// their stored name and color.
        init(session: StudySession) {
            let name = session.displaySubjectName
            let color = session.displaySubjectColorHex
            self.init(
                themeKey: session.subjectIDSnapshot?.uuidString
                    ?? "snapshot|\(name)|\(color.uppercased())",
                themeName: name,
                colorHex: color,
                endAt: session.endAt,
                seconds: session.seconds,
                grams: Int64(NonnegativeIntPolicy.clamped(session.grams))
            )
        }
    }

    /// Most time first; ties by mass, then name.
    static func themes(_ entries: [Entry]) -> [AccumulationTimelineThemeSummary] {
        Dictionary(grouping: entries, by: \.themeKey).compactMap { key, values in
            guard let newest = values.max(by: { $0.endAt < $1.endAt }) else { return nil }
            return AccumulationTimelineThemeSummary(
                id: key,
                name: newest.themeName,
                colorHex: newest.colorHex,
                sessionCount: values.count,
                seconds: NonnegativeIntPolicy.sum(values.map(\.seconds)),
                grams: NonnegativeIntPolicy.sum(values.map(\.grams))
            )
        }
        .sorted { lhs, rhs in
            if lhs.seconds != rhs.seconds { return lhs.seconds > rhs.seconds }
            if lhs.grams != rhs.grams { return lhs.grams > rhs.grams }
            if lhs.name != rhs.name {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    /// Days by the calendar's local midnight (DST-safe), newest first.
    static func days(
        _ entries: [Entry],
        calendar: Calendar
    ) -> [AccumulationTimelineDaySummary] {
        Dictionary(grouping: entries) { calendar.startOfDay(for: $0.endAt) }
            .map { dayStart, values in
                let colors = themes(values)
                    .map { $0.colorHex.uppercased() }
                    .reduce(into: [String]()) { result, hex in
                        if !result.contains(hex) { result.append(hex) }
                    }
                return AccumulationTimelineDaySummary(
                    dayStart: dayStart,
                    sessionCount: values.count,
                    seconds: NonnegativeIntPolicy.sum(values.map(\.seconds)),
                    grams: NonnegativeIntPolicy.sum(values.map(\.grams)),
                    colorHexes: Array(colors.prefix(3))
                )
            }
            .sorted { $0.dayStart > $1.dayStart }
    }
}

struct AccumulationTimelineMonthDetail: Equatable, Sendable {
    let summary: AccumulationTimelineMonthSummary
    let representativeRecords: [AccumulationRecord]
    /// Every day of the month that has a record, newest first (at most 31).
    let days: [AccumulationTimelineDaySummary]
    /// Every theme of the month, the most time first.
    let themes: [AccumulationTimelineThemeSummary]
    let totalSeconds: Int
    let coverage: AccumulationTimelineCoverage

    var previewIsRepresentative: Bool {
        representativeRecords.count < summary.exactLocalCount
    }
}

enum AccumulationTimelineRepositoryError: Error, LocalizedError, Equatable {
    case invalidCalendarInterval
    case unsupportedDateSpan

    var errorDescription: String? {
        switch self {
        case .invalidCalendarInterval:
            "年月の範囲を確認できませんでした。"
        case .unsupportedDateSpan:
            "記録の日付範囲を安全に表示できませんでした。"
        }
    }
}

@ModelActor
actor AccumulationTimelineRepository {
    func extent(currentEpochID: UUID?) throws -> AccumulationTimelineExtent {
        let stamp = try snapshotStamp(currentEpochID: currentEpochID)
        return AccumulationTimelineExtent(
            currentEpochID: currentEpochID,
            stamp: stamp,
            capturedAt: .now
        )
    }

    func yearSummary(
        for year: AccumulationTimelineYear,
        currentEpochID: UUID?,
        calendar: Calendar
    ) throws -> AccumulationTimelineYearSummary {
        var lastResult: AccumulationTimelineYearSummary?
        for _ in 0 ..< AccumulationTimelineQueryPolicy.stabilityAttemptCount {
            try checkCancellation()
            let before = try snapshotStamp(currentEpochID: currentEpochID)
            let metrics = try canonicalMetrics(
                currentEpochID: currentEpochID,
                interval: year.interval
            )
            let after = try snapshotStamp(currentEpochID: currentEpochID)
            let capturedAt = Date.now
            let coverage = AccumulationTimelineStabilityPolicy.coverage(
                before: before,
                after: after,
                capturedAt: capturedAt
            )
            let summary = try makeYearSummary(
                year: year,
                metrics: metrics,
                calendar: calendar,
                coverage: coverage
            )
            if coverage.isLocallyStable { return summary }
            lastResult = summary
        }
        guard let lastResult else {
            throw AccumulationTimelineRepositoryError.invalidCalendarInterval
        }
        return lastResult
    }

    func monthDetail(
        monthStart: Date,
        currentEpochID: UUID?,
        calendar: Calendar
    ) throws -> AccumulationTimelineMonthDetail {
        guard let interval = calendar.dateInterval(of: .month, for: monthStart) else {
            throw AccumulationTimelineRepositoryError.invalidCalendarInterval
        }

        var lastResult: AccumulationTimelineMonthDetail?
        for _ in 0 ..< AccumulationTimelineQueryPolicy.stabilityAttemptCount {
            try checkCancellation()
            let before = try snapshotStamp(currentEpochID: currentEpochID)
            let metrics = try canonicalMetrics(
                currentEpochID: currentEpochID,
                interval: interval
            )
            let preview = representativeRecords(from: metrics)
            // The month is already exact and in memory: its days and themes
            // are one more pass over it, with no further query.
            let entries = metrics.values.map(\.breakdownEntry)
            let after = try snapshotStamp(currentEpochID: currentEpochID)
            let coverage = AccumulationTimelineStabilityPolicy.coverage(
                before: before,
                after: after,
                capturedAt: .now
            )
            let summary = AccumulationTimelineMonthSummary(
                monthStart: interval.start,
                exactLocalCount: metrics.count,
                exactLocalGrams: NonnegativeIntPolicy.sum(metrics.values.map(\.grams))
            )
            let detail = AccumulationTimelineMonthDetail(
                summary: summary,
                representativeRecords: preview,
                days: AccumulationTimelineBreakdownPolicy.days(entries, calendar: calendar),
                themes: AccumulationTimelineBreakdownPolicy.themes(entries),
                totalSeconds: NonnegativeIntPolicy.sum(entries.map(\.seconds)),
                coverage: coverage
            )
            if coverage.isLocallyStable { return detail }
            lastResult = detail
        }
        guard let lastResult else {
            throw AccumulationTimelineRepositoryError.invalidCalendarInterval
        }
        return lastResult
    }

    /// One day, read as one bounded interval: the answer to 「あの日、何を
    /// した？」 without paging the lifetime list.
    func dayDetail(
        dayStart: Date,
        currentEpochID: UUID?,
        calendar: Calendar
    ) throws -> AccumulationTimelineDayDetail {
        let start = calendar.startOfDay(for: dayStart)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start), end > start else {
            throw AccumulationTimelineRepositoryError.invalidCalendarInterval
        }
        let interval = DateInterval(start: start, end: end)

        var lastResult: AccumulationTimelineDayDetail?
        for _ in 0 ..< AccumulationTimelineQueryPolicy.stabilityAttemptCount {
            try checkCancellation()
            let before = try snapshotStamp(currentEpochID: currentEpochID)
            let metrics = try canonicalMetrics(
                currentEpochID: currentEpochID,
                interval: interval
            )
            let newestFirst = metrics.values.sorted { lhs, rhs in
                if lhs.endAt == rhs.endAt {
                    return lhs.id.uuidString > rhs.id.uuidString
                }
                return lhs.endAt > rhs.endAt
            }
            let entries = newestFirst.map(\.breakdownEntry)
            let sessions = newestFirst.map { HistorySessionSummary($0.session) }
            let after = try snapshotStamp(currentEpochID: currentEpochID)
            let coverage = AccumulationTimelineStabilityPolicy.coverage(
                before: before,
                after: after,
                capturedAt: .now
            )
            let detail = AccumulationTimelineDayDetail(
                dayStart: start,
                sessions: sessions,
                themes: AccumulationTimelineBreakdownPolicy.themes(entries),
                totalSeconds: NonnegativeIntPolicy.sum(entries.map(\.seconds)),
                totalGrams: NonnegativeIntPolicy.sum(entries.map(\.grams)),
                coverage: coverage
            )
            if coverage.isLocallyStable { return detail }
            lastResult = detail
        }
        guard let lastResult else {
            throw AccumulationTimelineRepositoryError.invalidCalendarInterval
        }
        return lastResult
    }

    /// 記録's 「月ごとの瓶」 for this month and the eleven before it. One
    /// bounded interval read on this actor (at most 366 days, inside the
    /// finite-interval guard) replaces twelve month pages that used to run on
    /// the main thread on every open, 今週／今月 toggle and foreground. Counts
    /// are exact logical sessions; months with no record are omitted.
    func recentMonthSummaries(
        endingAt now: Date,
        currentEpochID: UUID?,
        calendar: Calendar
    ) throws -> [AccumulationRecentMonthSummary] {
        guard let currentMonth = calendar.dateInterval(of: .month, for: now),
              let firstMonthStart = calendar.date(
                byAdding: .month,
                value: -(AccumulationTimelineQueryPolicy.recentMonthCount - 1),
                to: currentMonth.start
              )
        else { throw AccumulationTimelineRepositoryError.invalidCalendarInterval }

        let sessions = try BoundedHistoryPolicy.resolvedSessionsInFiniteInterval(
            context: modelContext,
            epochID: currentEpochID,
            interval: DateInterval(start: firstMonthStart, end: currentMonth.end),
            maximumPhysicalRows: BoundedHistoryPolicy.finiteIntervalSessionRowLimit
        )
        var grouped: [Date: (count: Int, seconds: Int)] = [:]
        for session in sessions {
            try checkCancellation()
            guard let monthStart = calendar.dateInterval(of: .month, for: session.endAt)?.start else {
                throw AccumulationTimelineRepositoryError.invalidCalendarInterval
            }
            let current = grouped[monthStart] ?? (0, 0)
            grouped[monthStart] = (
                NonnegativeIntPolicy.adding(current.count, 1),
                NonnegativeIntPolicy.adding(current.seconds, NonnegativeIntPolicy.clamped(session.seconds))
            )
        }
        return grouped.map { monthStart, value in
            AccumulationRecentMonthSummary(
                monthStart: monthStart,
                sessionCount: value.count,
                seconds: value.seconds
            )
        }
        .sorted { $0.monthStart > $1.monthStart }
    }

    private struct CanonicalMetric {
        let session: StudySession

        var id: UUID { session.id }
        var endAt: Date { session.endAt }
        var grams: Int64 { Int64(max(0, session.grams)) }
        var breakdownEntry: AccumulationTimelineBreakdownPolicy.Entry {
            AccumulationTimelineBreakdownPolicy.Entry(session: session)
        }
        var record: AccumulationRecord {
            AccumulationRecord(
                id: session.id,
                date: session.endAt,
                subjectName: session.displaySubjectName,
                colorHex: session.displaySubjectColorHex,
                grams: max(0, session.grams),
                isMeasured: session.effectiveSource.isMeasured,
                isTimerCompletion: session.effectiveSource.isTimerCompletion,
                // Timeline records are raw activity. A caller that also
                // presents local aggregates resolves membership separately.
                isRepresentedByLocalAggregate: false
            )
        }

    }

    private func canonicalMetrics(
        currentEpochID: UUID?,
        interval: DateInterval
    ) throws -> [UUID: CanonicalMetric] {
        let sessions = try BoundedHistoryPolicy.resolvedSessionsInFiniteInterval(
            context: modelContext,
            epochID: currentEpochID,
            interval: interval,
            maximumPhysicalRows: BoundedHistoryPolicy.finiteIntervalSessionRowLimit
        )
        var values: [UUID: CanonicalMetric] = [:]
        values.reserveCapacity(sessions.count)
        for session in sessions {
            try checkCancellation()
            values[session.id] = CanonicalMetric(session: session)
        }
        return values
    }

    private func makeYearSummary(
        year: AccumulationTimelineYear,
        metrics: [UUID: CanonicalMetric],
        calendar: Calendar,
        coverage: AccumulationTimelineCoverage
    ) throws -> AccumulationTimelineYearSummary {
        var grouped: [Date: (count: Int, grams: Int64)] = [:]
        for metric in metrics.values {
            guard let monthStart = calendar.dateInterval(of: .month, for: metric.endAt)?.start else {
                throw AccumulationTimelineRepositoryError.invalidCalendarInterval
            }
            let current = grouped[monthStart] ?? (0, 0)
            grouped[monthStart] = (
                NonnegativeIntPolicy.adding(current.count, 1),
                NonnegativeIntPolicy.adding(current.grams, metric.grams)
            )
        }
        let months = grouped.map { monthStart, value in
            AccumulationTimelineMonthSummary(
                monthStart: monthStart,
                exactLocalCount: value.count,
                exactLocalGrams: value.grams
            )
        }
        .sorted { $0.monthStart > $1.monthStart }
        return AccumulationTimelineYearSummary(
            year: year,
            months: months,
            exactLocalCount: metrics.count,
            exactLocalGrams: NonnegativeIntPolicy.sum(metrics.values.map(\.grams)),
            coverage: coverage
        )
    }

    private func representativeRecords(
        from metrics: [UUID: CanonicalMetric]
    ) -> [AccumulationRecord] {
        let newest = metrics.values.sorted { lhs, rhs in
            if lhs.endAt == rhs.endAt {
                return lhs.id.uuidString > rhs.id.uuidString
            }
            return lhs.endAt > rhs.endAt
        }
        .prefix(AccumulationTimelineQueryPolicy.representativeRecordLimit)
        return newest.reversed().map(\.record)
    }

    private func snapshotStamp(
        currentEpochID: UUID?
    ) throws -> AccumulationTimelineSnapshotStamp {
        let count = try modelContext.fetchCount(
            BoundedHistoryPolicy.sessionCountDescriptor(epochID: currentEpochID)
        )
        // Extent discovery must never instantiate lifetime history. Scan only
        // bounded physical edge candidates, then exact-resolve their logical
        // IDs so a malformed or losing edge row cannot define the browser.
        let oldestPage = try BoundedHistoryPolicy.resolvedSessionPage(
            context: modelContext,
            epochID: currentEpochID,
            order: .forward,
            logicalLimit: 1
        )
        let newestPage = try BoundedHistoryPolicy.resolvedSessionPage(
            context: modelContext,
            epochID: currentEpochID,
            order: .reverse,
            logicalLimit: 1
        )
        let oldest = oldestPage.sessions.first.map {
            AccumulationTimelineEdge(id: $0.id, date: $0.endAt)
        }
        let newest = newestPage.sessions.first.map {
            AccumulationTimelineEdge(id: $0.id, date: $0.endAt)
        }
        return AccumulationTimelineSnapshotStamp(
            rawRowCount: count,
            oldest: oldest,
            newest: newest
        )
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw CancellationError() }
    }
}
