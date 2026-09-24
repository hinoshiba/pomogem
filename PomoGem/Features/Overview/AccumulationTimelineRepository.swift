import Foundation
import SwiftData

enum AccumulationTimelineQueryPolicy {
    static let metricBatchSize = 256
    static let representativeRecordLimit = 96
    static let maximumBrowsableYearSpan = 200
    static let stabilityAttemptCount = 2

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

struct AccumulationTimelineYearSummary: Equatable, Sendable {
    let year: AccumulationTimelineYear
    let months: [AccumulationTimelineMonthSummary]
    let exactLocalCount: Int
    let exactLocalGrams: Int64
    let coverage: AccumulationTimelineCoverage
}

struct AccumulationTimelineMonthDetail: Equatable, Sendable {
    let summary: AccumulationTimelineMonthSummary
    let representativeRecords: [AccumulationRecord]
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

    private struct CanonicalMetric {
        let session: StudySession

        var id: UUID { session.id }
        var endAt: Date { session.endAt }
        var grams: Int64 { Int64(max(0, session.grams)) }
        var record: AccumulationRecord {
            AccumulationRecord(
                id: session.id,
                date: session.endAt,
                subjectName: session.displaySubjectName,
                colorHex: session.displaySubjectColorHex,
                grams: max(0, session.grams),
                isMeasured: session.effectiveSource.isMeasured,
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
