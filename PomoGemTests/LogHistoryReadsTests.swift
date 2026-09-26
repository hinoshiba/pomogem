import SwiftData
import SwiftUI
import XCTest
@testable import PomoGem

/// 記録 reads its period page, newest thirty and aggregates on the repository's
/// actor now. These tests pin that the figures are the ones the main-context
/// reads produced, and that 記録 no longer runs those reads itself.
@MainActor
final class LogHistoryReadsTests: XCTestCase {
    func testPeriodContentMatchesTheMainContextPageItReplaces() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let epochID = UUID()
        let calendar = japaneseCalendar
        let now = date(2026, 9, 24, 15)
        let week = try XCTUnwrap(LogPeriodPolicy.interval(for: .week, now: now, calendar: calendar))
        let month = try XCTUnwrap(LogPeriodPolicy.interval(for: .month, now: now, calendar: calendar))
        let english = UUID()
        let math = UUID()

        func insert(
            id: UUID = UUID(),
            _ endAt: Date,
            seconds: Int = 1_500,
            source: SessionSource = .timer,
            theme: UUID?,
            name: String,
            color: String,
            epoch: UUID? = nil
        ) {
            context.insert(StudySession(
                id: id,
                startAt: endAt.addingTimeInterval(-TimeInterval(seconds)),
                endAt: endAt,
                seconds: seconds,
                source: source,
                deviceDayKey: "log-reads",
                subjectNameSnapshot: name,
                subjectColorHexSnapshot: color,
                subjectIDSnapshot: theme,
                dataEpochID: epoch ?? epochID
            ))
        }
        // This week, across three days and every source.
        insert(date(2026, 9, 20, 9), theme: english, name: "英語", color: "#2457C5")
        insert(date(2026, 9, 22, 23, 59), seconds: 3_600, source: .manual, theme: math, name: "数学", color: "#6BE4FF")
        insert(date(2026, 9, 23, 0, 1), theme: english, name: "英語", color: "#2457C5")
        for minute in 0 ..< 6 {
            insert(date(2026, 9, 24, 8, minute * 10), seconds: SessionSource.screenTimeSeconds, source: .screenTime, theme: math, name: "数学", color: "#6BE4FF")
        }
        insert(date(2026, 9, 24, 10), source: .timerDemoted, theme: nil, name: "古いテーマ", color: "#A979FF")
        // Two copies of one completion count once. The theme was renamed
        // before it: the newest record names the theme.
        let duplicate = UUID()
        insert(id: duplicate, date(2026, 9, 24, 12), theme: english, name: "英会話", color: "#2457C5")
        insert(id: duplicate, date(2026, 9, 24, 12), theme: english, name: "英会話", color: "#2457C5")
        // Earlier this month, before the week.
        insert(date(2026, 9, 3, 7), theme: math, name: "数学", color: "#6BE4FF")
        insert(date(2026, 9, 1, 0), theme: nil, name: "古いテーマ", color: "#A979FF")
        // Outside both periods, or another reset's rows.
        insert(date(2026, 8, 31, 23, 59), theme: english, name: "英語", color: "#2457C5")
        insert(date(2026, 9, 21, 12), theme: english, name: "英語", color: "#2457C5", epoch: UUID())
        try context.save()

        for (period, interval) in [(LogView.Period.week, week), (.month, month)] {
            let content = try await AccumulationTimelineLoader.read(from: container) { repository in
                try await repository.logPeriodContent(
                    period: period,
                    interval: interval,
                    calendar: calendar,
                    currentEpochID: epochID
                )
            }

            // What 記録 computed from the main context before.
            let page = try BoundedHistoryPolicy.resolvedSessionPage(
                context: context,
                epochID: epochID,
                start: interval.start,
                end: interval.end,
                order: .reverse,
                logicalLimit: BoundedHistoryPolicy.periodSessionLimit
            )
            let sessions = StudySessionSyncPolicy.canonicalSessions(from: page.sessions)

            XCTAssertEqual(content.period, period)
            XCTAssertEqual(content.epochID, epochID)
            XCTAssertEqual(content.isPartial, page.isPartial)
            XCTAssertEqual(content.records.map(\.id), sessions.map(\.id), "\(period)")
            XCTAssertEqual(content.records.map(\.row), sessions.map(HistorySessionSummary.init), "\(period)")
            XCTAssertEqual(content.presentation.summary, LogPeriodSummary(sessions: sessions), "\(period)")
            XCTAssertEqual(
                content.presentation.dailyMass.map { [$0.date.timeIntervalSinceReferenceDate, Double($0.grams)] },
                Self.referenceDailyMass(sessions, interval: interval, calendar: calendar),
                "\(period)"
            )
            XCTAssertEqual(
                content.presentation.subjectMass.map(\.id).sorted(),
                Self.referenceSubjectMass(sessions).map(\.id).sorted(),
                "\(period)"
            )
            for reference in Self.referenceSubjectMass(sessions) {
                let shown = try XCTUnwrap(content.presentation.subjectMass.first { $0.id == reference.id })
                XCTAssertEqual(shown.name, reference.name)
                XCTAssertEqual(shown.colorHex, reference.colorHex)
                XCTAssertEqual(shown.grams, reference.grams)
                XCTAssertEqual(shown.fraction, reference.fraction, accuracy: 0.000_001)
            }
        }

        let weekContent = try await AccumulationTimelineLoader.read(from: container) { repository in
            try await repository.logPeriodContent(
                period: .week,
                interval: week,
                calendar: calendar,
                currentEpochID: epochID
            )
        }
        // The figures a person reads, spelled out once.
        XCTAssertEqual(weekContent.records.count, 11)
        XCTAssertEqual(weekContent.presentation.summary.timerCompletionCount, 3)
        XCTAssertEqual(weekContent.presentation.summary.selfReportedGrams, 600 + 250)
        XCTAssertEqual(weekContent.presentation.summary.screenTimeSeconds, 3_600)
        XCTAssertEqual(weekContent.presentation.dailyMass.count, 7)
        XCTAssertEqual(
            weekContent.presentation.subjectMass.map(\.name),
            ["数学", "英会話", "古いテーマ"],
            "Heaviest first; a theme is named by its newest record"
        )
    }

    func testRecentContentMatchesTheNewestThirtyAndTheArchiveRoots() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let epochID = UUID()
        let start = date(2026, 1, 1, 8)
        var sessionIDs: [UUID] = []
        for index in 0 ..< 45 {
            let id = UUID()
            sessionIDs.append(id)
            let endAt = start.addingTimeInterval(TimeInterval(index * 3_600))
            // Every seventh is a self-reported 30 minutes (a manual record
            // must be one of the durations the app offers).
            let isManual = index.isMultiple(of: 7)
            let seconds = isManual ? 1_800 : 1_500
            context.insert(StudySession(
                id: id,
                startAt: endAt.addingTimeInterval(-TimeInterval(seconds)),
                endAt: endAt,
                seconds: seconds,
                source: isManual ? .manual : .timer,
                deviceDayKey: "log-recent",
                subjectNameSnapshot: "英語",
                subjectColorHexSnapshot: "#2457C5",
                dataEpochID: epochID
            ))
        }
        // A ×100 root that holds two ×10 children, a free ×10 root, and a
        // legacy layer that an aggregate replaced next to one that it did not.
        let parentID = UUID()
        let childIDs = [UUID(), UUID()]
        let freeRootID = UUID()
        let colorMix = StrataMath.encodeColorMix([StratumColorFraction(hex: "#2457C5", fraction: 1)])
        for (offset, childID) in childIDs.enumerated() {
            context.insert(AggregatePebble(
                id: childID,
                createdAt: start.addingTimeInterval(TimeInterval(offset)),
                level: 1,
                pebbleCount: 10,
                grams: 2_500,
                measuredPebbleCount: 10,
                colorMixJSON: colorMix,
                periodStart: start,
                periodEnd: start.addingTimeInterval(36_000),
                sessionIDs: Array(sessionIDs[(offset * 10) ..< (offset * 10 + 10)]),
                parentAggregateID: parentID,
                dataEpochID: epochID
            ))
        }
        context.insert(AggregatePebble(
            id: parentID,
            createdAt: start.addingTimeInterval(100),
            level: 2,
            pebbleCount: 100,
            childAggregateCount: 2,
            grams: 25_000,
            measuredPebbleCount: 100,
            colorMixJSON: colorMix,
            periodStart: start,
            periodEnd: start.addingTimeInterval(72_000),
            childAggregateIDs: childIDs,
            dataEpochID: epochID
        ))
        context.insert(AggregatePebble(
            id: freeRootID,
            createdAt: start.addingTimeInterval(200),
            level: 1,
            pebbleCount: 10,
            grams: 2_500,
            measuredPebbleCount: 10,
            colorMixJSON: colorMix,
            periodStart: start,
            periodEnd: start.addingTimeInterval(36_000),
            sessionIDs: Array(sessionIDs[20 ..< 30]),
            dataEpochID: epochID
        ))
        context.insert(Stratum(
            id: freeRootID,
            bakedAt: start,
            pebbleCount: 10,
            heightPt: 4,
            colorMixJSON: colorMix,
            monthLabel: "2026年1月",
            sessionIDs: Array(sessionIDs[20 ..< 30]),
            dataEpochID: epochID
        ))
        let legacyID = UUID()
        context.insert(Stratum(
            id: legacyID,
            bakedAt: start.addingTimeInterval(50),
            pebbleCount: 10,
            heightPt: 4,
            colorMixJSON: colorMix,
            monthLabel: "2026年1月",
            sessionIDs: Array(sessionIDs[35 ..< 45]),
            dataEpochID: epochID
        ))
        try context.save()

        let stamp = AggregateProjectionPresentationContext.localVerified.verifiedCacheStamp
        let content = try await AccumulationTimelineLoader.read(from: container) { repository in
            try await repository.logRecentContent(
                currentEpochID: epochID,
                aggregateCacheStamp: stamp
            )
        }

        // What 記録 read from the main context before.
        let recentPage = try BoundedHistoryPolicy.resolvedSessionPage(
            context: context,
            epochID: epochID,
            order: .reverse,
            logicalLimit: BoundedHistoryPolicy.recentSessionLimit
        )
        let aggregateRaw = try context.fetch(BoundedHistoryPolicy.rootAggregateDescriptor(
            epochID: epochID,
            limit: BoundedHistoryPolicy.aggregateRootLimit + 1
        ))
        let roots = AggregatePebblePolicy.disjointRootSummaries(
            from: Array(aggregateRaw.prefix(BoundedHistoryPolicy.aggregateRootLimit))
        )

        XCTAssertEqual(content.epochID, epochID)
        XCTAssertEqual(content.records.count, 30)
        XCTAssertEqual(content.records.map(\.row), recentPage.sessions.map(HistorySessionSummary.init))
        XCTAssertEqual(content.records.first?.id, sessionIDs.last, "Newest first")
        XCTAssertEqual(content.aggregates.roots.map(\.id), roots.map(\.id))
        XCTAssertEqual(Set(content.aggregates.roots.map(\.id)), [parentID, freeRootID])
        XCTAssertEqual(content.aggregates.roots.first { $0.id == parentID }?.pebbleCount, 100)
        XCTAssertFalse(content.aggregates.isPartial)
        XCTAssertEqual(content.aggregates.cacheStamp, stamp, "The archive carries the verification it was read under")
        XCTAssertFalse(content.isUnavailable)
        XCTAssertEqual(
            content.aggregates.legacyLayers.map(\.id),
            [legacyID],
            "A legacy layer that an aggregate replaced is not listed twice"
        )
        XCTAssertEqual(content.aggregates.legacyLayers.first?.sessionIDs, Set(sessionIDs[35 ..< 45]))

        // The legacy row counts the records on screen that it holds.
        let legacy = try XCTUnwrap(content.aggregates.legacyLayers.first)
        let item = LogAggregateArchiveItem(
            legacy: legacy,
            members: content.records.filter { legacy.sessionIDs.contains($0.id) }
        )
        XCTAssertEqual(item.pebbleCount, 10)
        XCTAssertEqual(item.measuredPebbleCount + item.manualPebbleCount, 10)
        XCTAssertEqual(item.manualPebbleCount, [35, 42].count)

        // While iCloud verification is pending there is no verified stamp,
        // and the aggregates are not read.
        let withoutAggregates = try await AccumulationTimelineLoader.read(from: container) { repository in
            try await repository.logRecentContent(
                currentEpochID: epochID,
                aggregateCacheStamp: nil
            )
        }
        XCTAssertEqual(withoutAggregates.records, content.records)
        XCTAssertEqual(withoutAggregates.aggregates, .empty)
    }

    /// After a toggle the page on screen stays until the next one arrives,
    /// then gives way to placeholders if that takes long; a page read before
    /// a reset is never shown.
    func testShownPeriodContentLagsTheToggleOnlyBriefly() {
        let epochID = UUID()
        let weekPage = LogPeriodContent.empty(
            period: .week,
            epochID: epochID,
            interval: nil,
            calendar: japaneseCalendar
        )
        func shown(
            _ content: LogPeriodContent?,
            _ selected: LogView.Period,
            epoch: UUID? = nil,
            slow: Bool = false
        ) -> LogView.Period? {
            LogHistoryLoadPolicy.shownPeriodContent(
                content,
                selected: selected,
                currentEpochID: epoch ?? epochID,
                reloadIsSlow: slow
            )?.period
        }

        XCTAssertNil(shown(nil, .week), "Placeholders until the first page")
        XCTAssertEqual(shown(weekPage, .week), .week)
        XCTAssertEqual(shown(weekPage, .week, slow: true), .week, "A page of the chosen period always shows")
        XCTAssertEqual(shown(weekPage, .month), .week, "今週 stays, with its own labels, while 今月 loads")
        XCTAssertNil(shown(weekPage, .month, slow: true), "A slow 今月 shows placeholders, not 今週's figures")
        XCTAssertNil(shown(weekPage, .week, epoch: UUID()), "Never a page from before a reset")
        XCTAssertLessThanOrEqual(
            LogHistoryLoadPolicy.periodReloadPlaceholderDelay,
            .milliseconds(300)
        )

        let recent = LogRecentContent(epochID: epochID, records: [], aggregates: .empty)
        XCTAssertNotNil(LogHistoryLoadPolicy.shownRecentContent(recent, currentEpochID: epochID))
        XCTAssertNil(LogHistoryLoadPolicy.shownRecentContent(recent, currentEpochID: UUID()))
        XCTAssertNil(LogHistoryLoadPolicy.shownRecentContent(nil, currentEpochID: epochID))
    }

    /// A failed read always ends in a final state. Most people never reset
    /// their data, so the epoch is nil; with nothing read yet, the old
    /// check compared nil with nil and left 最近の記録 loading forever.
    func testFailedReadsEndInAFinalStateAlsoWithoutAReset() {
        let calendar = japaneseCalendar
        for epochID in [nil, UUID()] as [UUID?] {
            let recent = LogHistoryLoadPolicy.recentContentAfterFailedRead(nil, currentEpochID: epochID)
            XCTAssertTrue(recent.isUnavailable, "\(String(describing: epochID))")
            XCTAssertEqual(recent.epochID, epochID)
            XCTAssertNotNil(
                LogHistoryLoadPolicy.shownRecentContent(recent, currentEpochID: epochID),
                "The section shows the failure instead of loading"
            )

            // A refresh that failed keeps what this epoch already shows.
            let loaded = LogRecentContent(epochID: epochID, records: [], aggregates: .empty)
            XCTAssertEqual(
                LogHistoryLoadPolicy.recentContentAfterFailedRead(loaded, currentEpochID: epochID),
                loaded
            )
            // Another epoch's content never stays.
            let otherEpoch = LogRecentContent(epochID: UUID(), records: [], aggregates: .empty)
            XCTAssertTrue(
                LogHistoryLoadPolicy.recentContentAfterFailedRead(otherEpoch, currentEpochID: epochID)
                    .isUnavailable
            )

            // The period page: a failed first read ends on this period's
            // name over no figures; a failed refresh keeps its page.
            let week = LogPeriodPolicy.interval(for: .week, now: date(2026, 9, 24), calendar: calendar)
            let empty = LogHistoryLoadPolicy.periodContentAfterFailedRead(
                nil,
                period: .week,
                currentEpochID: epochID,
                interval: week,
                calendar: calendar
            )
            XCTAssertEqual(empty.period, .week)
            XCTAssertEqual(empty.epochID, epochID)
            XCTAssertTrue(empty.records.isEmpty)
            XCTAssertNotNil(LogHistoryLoadPolicy.shownPeriodContent(
                empty,
                selected: .week,
                currentEpochID: epochID,
                reloadIsSlow: true
            ))
            let monthPage = LogPeriodContent.empty(
                period: .month,
                epochID: epochID,
                interval: nil,
                calendar: calendar
            )
            XCTAssertEqual(
                LogHistoryLoadPolicy.periodContentAfterFailedRead(
                    monthPage,
                    period: .month,
                    currentEpochID: epochID,
                    interval: week,
                    calendar: calendar
                ),
                monthPage
            )
            XCTAssertEqual(
                LogHistoryLoadPolicy.periodContentAfterFailedRead(
                    monthPage,
                    period: .week,
                    currentEpochID: epochID,
                    interval: week,
                    calendar: calendar
                ).period,
                .week,
                "Never the other period's page under this period's name"
            )
        }
    }

    /// まとまり粒 are projections. An archive read under one verification is
    /// never shown after that verification was invalidated, even once the
    /// next one succeeds and before a read under it arrives, whether the
    /// reads in between were cancelled or failed.
    func testArchiveReadBeforeAVerificationIsInvalidatedIsNeverShownAgain() {
        let epochID: UUID? = nil
        var projection = AggregateProjectionPresentationContext(
            usesCloudPersistence: true,
            isVerified: true,
            cacheNamespace: UUID()
        )
        func content(stamp: AggregateProjectionCacheStamp?) -> LogRecentContent {
            LogRecentContent(
                epochID: epochID,
                records: [],
                aggregates: LogAggregateArchive(
                    roots: [],
                    legacyLayers: [],
                    isPartial: true,
                    cacheStamp: stamp
                )
            )
        }
        func shows(_ content: LogRecentContent?) -> Bool {
            LogHistoryLoadPolicy.shownAggregateArchive(
                content,
                currentEpochID: epochID,
                projection: projection
            ) != nil
        }

        // Verified: content A, with its aggregates.
        let contentA = content(stamp: projection.verifiedCacheStamp)
        XCTAssertTrue(shows(contentA))
        XCTAssertFalse(shows(nil))

        // Pending: A's aggregates are hidden at once, before any read.
        projection.invalidate()
        XCTAssertFalse(shows(contentA))
        // A read during the pending phase reads no aggregates.
        let pendingRead = content(stamp: projection.verifiedCacheStamp)
        XCTAssertNil(pendingRead.aggregates.cacheStamp)
        XCTAssertFalse(shows(pendingRead))

        // Verified again: neither A nor the pending read comes back.
        projection.markVerified()
        XCTAssertFalse(shows(contentA), "A pre-invalidation archive stays hidden after re-verification")
        XCTAssertFalse(shows(pendingRead))
        // A failed refresh keeps A's records, but not its aggregates.
        let afterFailure = LogHistoryLoadPolicy.recentContentAfterFailedRead(contentA, currentEpochID: epochID)
        XCTAssertEqual(afterFailure, contentA)
        XCTAssertFalse(shows(afterFailure))
        // Only a read under the new verification shows.
        XCTAssertTrue(shows(content(stamp: projection.verifiedCacheStamp)))

        // Without iCloud nothing is ever pending, and the archive stays.
        var local = AggregateProjectionPresentationContext.localVerified
        let localContent = content(stamp: local.verifiedCacheStamp)
        local.invalidate()
        XCTAssertTrue(LogHistoryLoadPolicy.shownAggregateArchive(
            localContent,
            currentEpochID: epochID,
            projection: local
        ) != nil)
    }

    /// Lifetime-sized reads block the main thread. 記録 itself may read only
    /// its milestones; every session and aggregate page goes through
    /// AccumulationTimelineLoader.
    func testLogViewLeavesLifetimeReadsToTheLoader() throws {
        let source = try String(contentsOf: sourceURL("PomoGem/Features/Log/LogView.swift"), encoding: .utf8)
        let viewStart = try XCTUnwrap(source.range(of: "struct LogView: View {"))
        let viewEnd = try XCTUnwrap(source.range(of: "private enum AchievementMutationError"))
        let view = source[viewStart.upperBound ..< viewEnd.lowerBound]

        for forbidden in [
            "resolvedSessionPage(",
            "resolvedSessionsInFiniteInterval(",
            "rootAggregateDescriptor(",
            "legacyAggregateDescriptor(",
            "FetchDescriptor<StudySession>"
        ] {
            XCTAssertFalse(view.contains(forbidden), "LogView must not run \(forbidden) on the main context")
        }
        XCTAssertGreaterThanOrEqual(
            view.components(separatedBy: "AccumulationTimelineLoader.read(").count - 1,
            3,
            "The period page, the newest thirty and the months are read through the loader"
        )
    }

    /// The milestones are 記録's one read on the main context. A main-context
    /// fetch that arrives while a lifetime-sized read runs off the main
    /// thread waits for it, so every load reads the milestones before it
    /// starts its own read (the first one to run does the work).
    func testEveryLoadReadsTheMilestonesBeforeItsLifetimeRead() throws {
        let source = try String(contentsOf: sourceURL("PomoGem/Features/Log/LogView.swift"), encoding: .utf8)
        for function in [
            "private func loadPeriodPage(for key: String) async {",
            "private func loadRecentHistory(for key: String) async {",
            "private func loadMonthSummaries(for key: String) async {"
        ] {
            let start = try XCTUnwrap(source.range(of: function), function)
            let body = source[start.upperBound...]
            let gate = try XCTUnwrap(body.range(of: "loadAchievementsBeforeLifetimeReads()"), function)
            let read = try XCTUnwrap(body.range(of: "AccumulationTimelineLoader.read("), function)
            XCTAssertLessThan(gate.lowerBound, read.lowerBound, "\(function) must read the milestones first")
        }
        // Nothing else reads the milestones on the way in.
        let view = try XCTUnwrap(source.range(of: "var body: some View {"))
        let tasks = source[view.upperBound...]
        let firstTask = try XCTUnwrap(tasks.range(of: ".task(id: loadKey)"))
        let lastTask = try XCTUnwrap(tasks.range(of: "await loadMonthSummaries(for: monthSummaryKey)"))
        XCTAssertFalse(
            tasks[firstTask.lowerBound ..< lastTask.upperBound].contains("loadAchievements()"),
            "A task that read the milestones on its own could queue behind another task's read"
        )
    }

    /// 記録's reads take turns, so a main-context fetch elsewhere in the app
    /// waits for one of them at most; the 今週／今月 page goes first.
    func testReadQueueReadsOneAtATimeWithThePeriodPageFirst() async throws {
        let queue = LogReadQueue()
        let recorder = ReadRecorder()
        let firstRead = Gate()

        let running = Task {
            try await queue.run {
                await recorder.enter("recent")
                await firstRead.wait()
                await recorder.leave()
            }
        }
        try await waitUntil { await recorder.entered == ["recent"] }
        let months = Task {
            try await queue.run {
                await recorder.enter("months")
                await recorder.leave()
            }
        }
        try await waitUntil { await queue.waitingReadCount == 1 }
        let period = Task {
            try await queue.run(first: true) {
                await recorder.enter("period")
                await recorder.leave()
            }
        }
        try await waitUntil { await queue.waitingReadCount == 2 }

        await firstRead.open()
        try await running.value
        try await months.value
        try await period.value

        let entered = await recorder.entered
        let mostAtOnce = await recorder.mostAtOnce
        XCTAssertEqual(entered, ["recent", "period", "months"], "The period page skips the line")
        XCTAssertEqual(mostAtOnce, 1, "One read at a time")
    }

    /// A read whose screen moved on (a toggle, leaving 記録) leaves the line
    /// without reading and without holding up the reads behind it.
    func testCancelledWaitingReadLeavesTheLine() async throws {
        let queue = LogReadQueue()
        let recorder = ReadRecorder()
        let firstRead = Gate()

        let running = Task {
            try await queue.run {
                await recorder.enter("first")
                await firstRead.wait()
                await recorder.leave()
            }
        }
        try await waitUntil { await recorder.entered == ["first"] }
        let abandoned = Task {
            try await queue.run {
                await recorder.enter("abandoned")
                await recorder.leave()
            }
        }
        try await waitUntil { await queue.waitingReadCount == 1 }
        abandoned.cancel()
        do {
            try await abandoned.value
            XCTFail("A cancelled read must not run")
        } catch is CancellationError {
        }
        let waitingAfterCancel = await queue.waitingReadCount
        XCTAssertEqual(waitingAfterCancel, 0)

        await firstRead.open()
        try await running.value
        try await queue.run {
            await recorder.enter("next")
            await recorder.leave()
        }
        let entered = await recorder.entered
        XCTAssertEqual(entered, ["first", "next"])
    }

    // MARK: - The view's former computations, kept as the reference

    /// 「質量の推移」 as LogView computed it from the main-context page.
    private static func referenceDailyMass(
        _ sessions: [StudySession],
        interval: DateInterval,
        calendar: Calendar
    ) -> [[Double]] {
        LogPeriodPolicy.days(in: interval, calendar: calendar).map { day in
            [
                day.timeIntervalSinceReferenceDate,
                Double(NonnegativeIntPolicy.sum(
                    sessions
                        .filter { calendar.isDate($0.endAt, inSameDayAs: day) }
                        .map(\.grams)
                ))
            ]
        }
    }

    private struct ReferenceSubjectMass {
        let id: String
        let name: String
        let colorHex: String
        let grams: Int
        let fraction: Double
    }

    /// 「テーマの構成」 as LogView computed it from the main-context page.
    private static func referenceSubjectMass(_ sessions: [StudySession]) -> [ReferenceSubjectMass] {
        let grouped = Dictionary(grouping: sessions) { session in
            session.subjectIDSnapshot?.uuidString
                ?? "deleted:\(session.subjectNameSnapshot):\(session.subjectColorHexSnapshot)"
        }
        let values = grouped.compactMap { identity, sessions -> (String, String, String, Int)? in
            guard let first = sessions.first else { return nil }
            return (
                identity,
                first.displaySubjectName,
                first.displaySubjectColorHex,
                NonnegativeIntPolicy.sum(sessions.map(\.grams))
            )
        }
        let total = max(1, NonnegativeIntPolicy.sum(values.map(\.3)))
        return values.map {
            ReferenceSubjectMass(
                id: $0.0,
                name: $0.1,
                colorHex: $0.2,
                grams: $0.3,
                fraction: Double($0.3) / Double(total)
            )
        }
    }

    // MARK: - Fixtures

    private actor ReadRecorder {
        private(set) var entered: [String] = []
        private(set) var mostAtOnce = 0
        private var active = 0

        func enter(_ name: String) {
            entered.append(name)
            active += 1
            mostAtOnce = max(mostAtOnce, active)
        }

        func leave() {
            active -= 1
        }
    }

    /// Holds a read until the test opens it.
    private actor Gate {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            isOpen = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for the read queue")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private var japaneseCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ja_JP")
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        japaneseCalendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func sourceURL(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Subject.self,
            StudySession.self,
            AchievementStone.self,
            AggregatePebble.self,
            Stratum.self,
            Bedrock.self,
            GachaState.self,
            Prefs.self,
            ActivityResetMarker.self,
            SyncedFocusTimer.self,
            FocusTimerDeviceClaim.self
        ])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                "LogHistoryReadsTests-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )]
        )
    }
}
