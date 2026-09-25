import SwiftData
import SwiftUI
import XCTest
@testable import PomoGem

@MainActor
final class AccumulationTimelineRepositoryTests: XCTestCase {
    func testExtentUsesLimitOneEdgesAndOnlyCurrentEpoch() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let epochID = UUID()
        let staleEpochID = UUID()
        let oldest = date(year: 1985, month: 1, day: 1)
        let newest = date(year: 2024, month: 12, day: 31)

        insertSession(in: context, endAt: oldest, epochID: epochID)
        insertSession(in: context, endAt: newest, epochID: epochID)
        insertSession(in: context, endAt: date(year: 1970, month: 1, day: 1), epochID: staleEpochID)
        insertSession(in: context, endAt: date(year: 2030, month: 1, day: 1), epochID: nil)
        try context.save()

        XCTAssertEqual(
            AccumulationTimelineQueryPolicy.edgeSessionDescriptor(
                currentEpochID: epochID,
                order: .forward
            ).fetchLimit,
            1
        )
        let repository = AccumulationTimelineRepository(modelContainer: container)
        let extent = try await repository.extent(currentEpochID: epochID)

        XCTAssertEqual(extent.localRawRowCount, 2)
        XCTAssertEqual(extent.oldestDate, oldest)
        XCTAssertEqual(extent.newestDate, newest)
    }

    func testTimelineQuarantinesUnsupportedRowsFromExtentAndMetrics() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let epochID = UUID()
        let validDate = date(year: 2024, month: 4, day: 15)
        let valid = StudySession(
            startAt: validDate.addingTimeInterval(-1_500),
            endAt: validDate,
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "timeline-integrity",
            dataEpochID: epochID
        )
        let overflow = StudySession(
            startAt: date(year: 1980, month: 1, day: 1),
            endAt: date(year: 1980, month: 1, day: 2),
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "timeline-integrity",
            dataEpochID: epochID
        )
        overflow.seconds = Int.max
        overflow.grams = Int.max
        let incoherentMass = StudySession(
            startAt: validDate.addingTimeInterval(-60),
            endAt: validDate,
            seconds: 60,
            source: .timer,
            grams: 600,
            deviceDayKey: "timeline-integrity",
            dataEpochID: epochID
        )
        let reversed = StudySession(
            startAt: date(year: 2030, month: 1, day: 2),
            endAt: date(year: 2030, month: 1, day: 1),
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "timeline-integrity",
            dataEpochID: epochID
        )
        [valid, overflow, incoherentMass, reversed].forEach(context.insert)
        try context.save()

        let repository = AccumulationTimelineRepository(modelContainer: container)
        let extent = try await repository.extent(currentEpochID: epochID)
        XCTAssertEqual(extent.oldestDate, validDate)
        XCTAssertEqual(extent.newestDate, validDate)

        let year = try XCTUnwrap(
            AccumulationTimelineYearPolicy.years(in: extent, calendar: calendar).first
        )
        let summary = try await repository.yearSummary(
            for: year,
            currentEpochID: epochID,
            calendar: calendar
        )
        XCTAssertEqual(summary.exactLocalCount, 1)
        XCTAssertEqual(summary.exactLocalGrams, 250)
    }

    func testYearSummaryDeduplicatesUUIDAcrossBatchBoundary() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let epochID = UUID()
        let firstID = UUID()
        let monthStart = date(year: 2024, month: 1, day: 1)

        for index in 0 ..< 300 {
            insertSession(
                id: index == 0 ? firstID : UUID(),
                in: context,
                endAt: monthStart.addingTimeInterval(Double(index * 60)),
                grams: 250,
                epochID: epochID
            )
        }
        // A lower-mass CloudKit duplicate must not inflate count or replace
        // the canonical logical record, even when it falls in another batch.
        insertSession(
            id: firstID,
            in: context,
            endAt: monthStart.addingTimeInterval(301 * 60),
            seconds: 600,
            grams: 100,
            epochID: epochID
        )
        insertSession(
            in: context,
            endAt: monthStart.addingTimeInterval(302 * 60),
            grams: 9_999,
            epochID: UUID()
        )
        try context.save()

        let repository = AccumulationTimelineRepository(modelContainer: container)
        // Extent discovery has its own deliberately smaller candidate bound.
        // Construct the known year directly so this test does not also depend
        // on public extent-to-year selection before exercising metric paging.
        let year = AccumulationTimelineYear(
            year: 2024,
            interval: DateInterval(
                start: monthStart,
                end: date(year: 2025, month: 1, day: 1)
            )
        )
        let summary = try await repository.yearSummary(
            for: year,
            currentEpochID: epochID,
            calendar: calendar
        )

        XCTAssertEqual(AccumulationTimelineQueryPolicy.metricBatchSize, 256)
        XCTAssertEqual(summary.exactLocalCount, 300)
        XCTAssertEqual(summary.exactLocalGrams, 75_000)
        XCTAssertEqual(summary.months.count, 1)
        XCTAssertEqual(summary.months.first?.exactLocalCount, 300)
        XCTAssertEqual(summary.months.first?.exactLocalGrams, 75_000)
        XCTAssertTrue(summary.coverage.isLocallyStable)
    }

    func testMonthDetailAppliesDateMembershipAfterExactDuplicateResolution() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let epochID = UUID()
        let boundaryID = UUID()
        let retainedID = UUID()
        let januaryStart = date(year: 2024, month: 1, day: 1)
        let insideDate = date(year: 2024, month: 1, day: 20)
        let outsideDate = date(year: 2024, month: 2, day: 1)

        insertSession(
            id: retainedID,
            in: context,
            endAt: date(year: 2024, month: 1, day: 10),
            epochID: epochID
        )
        context.insert(StudySession(
            id: boundaryID,
            startAt: insideDate.addingTimeInterval(-1_500),
            endAt: insideDate,
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "boundary-copy",
            dataEpochID: epochID
        ))
        // The conservative demotion wins for this logical completion. It is
        // outside January, so the losing in-month physical copy must not be
        // counted or presented as a January record.
        context.insert(StudySession(
            id: boundaryID,
            startAt: outsideDate.addingTimeInterval(-1_500),
            endAt: outsideDate,
            seconds: 1_500,
            source: .timerDemoted,
            grams: 250,
            deviceDayKey: "boundary-copy",
            dataEpochID: epochID
        ))
        try context.save()

        let detail = try await AccumulationTimelineRepository(
            modelContainer: container
        ).monthDetail(
            monthStart: januaryStart,
            currentEpochID: epochID,
            calendar: calendar
        )

        XCTAssertEqual(detail.summary.exactLocalCount, 1)
        XCTAssertEqual(detail.summary.exactLocalGrams, 250)
        XCTAssertEqual(detail.representativeRecords.map(\.id), [retainedID])
    }

    func testMonthDetailKeepsExactTotalsAndBoundsRepresentativeBottleToLatest96() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let epochID = UUID()
        let monthStart = date(year: 2024, month: 2, day: 1)
        var orderedIDs: [UUID] = []

        for index in 0 ..< 110 {
            let id = UUID()
            orderedIDs.append(id)
            insertSession(
                id: id,
                in: context,
                endAt: monthStart.addingTimeInterval(Double(index * 60)),
                grams: Constants.Mass.measuredPebbleGrams,
                epochID: epochID
            )
        }
        // More duplicate rows than the old fixed preview window must not
        // collapse a 96-logical-record representative bottle to one pebble.
        for index in 0 ..< 250 {
            insertSession(
                id: orderedIDs.last!,
                in: context,
                endAt: monthStart.addingTimeInterval(Double((1_000 + index) * 60)),
                grams: Constants.Mass.measuredPebbleGrams,
                epochID: epochID
            )
        }
        try context.save()

        let repository = AccumulationTimelineRepository(modelContainer: container)
        let detail = try await repository.monthDetail(
            monthStart: monthStart,
            currentEpochID: epochID,
            calendar: calendar
        )

        XCTAssertEqual(detail.summary.exactLocalCount, 110)
        XCTAssertEqual(
            detail.summary.exactLocalGrams,
            Int64(110 * Constants.Mass.measuredPebbleGrams)
        )
        XCTAssertEqual(detail.representativeRecords.count, 96)
        XCTAssertEqual(detail.representativeRecords.map(\.id), Array(orderedIDs.suffix(96)))
        XCTAssertTrue(detail.previewIsRepresentative)
        XCTAssertTrue(detail.coverage.isLocallyStable)
    }

    func testRecentMonthSummariesAreExactForTwelveMonths() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let epochID = UUID()
        let now = date(year: 2026, month: 9, day: 24)
        let duplicateID = UUID()

        // Thirteen months back is outside 記録's twelve.
        insertSession(in: context, endAt: date(year: 2025, month: 8, day: 31), epochID: epochID)
        // The first included month, including its first instant.
        insertSession(in: context, endAt: date(year: 2025, month: 10, day: 1), epochID: epochID)
        // The last instant of September and the first of October stay apart.
        let endOfSeptember2025 = date(year: 2025, month: 10, day: 1).addingTimeInterval(-1)
        insertSession(in: context, endAt: endOfSeptember2025, epochID: epochID)
        // Two CloudKit copies of one completion count once.
        insertSession(id: duplicateID, in: context, endAt: date(year: 2026, month: 9, day: 3), epochID: epochID)
        insertSession(id: duplicateID, in: context, endAt: date(year: 2026, month: 9, day: 3), epochID: epochID)
        insertSession(in: context, endAt: date(year: 2026, month: 9, day: 20), seconds: 3_600, grams: 600, epochID: epochID)
        insertSession(in: context, endAt: date(year: 2026, month: 9, day: 21), epochID: UUID())
        try context.save()

        // The way 記録 reads it: through the loader, off the main thread.
        let calendar = self.calendar
        let summaries = try await AccumulationTimelineLoader.read(from: container) { repository in
            try await repository.recentMonthSummaries(
                endingAt: now,
                currentEpochID: epochID,
                calendar: calendar
            )
        }

        XCTAssertEqual(summaries.map(\.monthStart), [
            date(year: 2026, month: 9, day: 1),
            date(year: 2025, month: 10, day: 1)
        ], "Newest first, empty months omitted, September 2025 is outside the twelve")
        XCTAssertEqual(summaries.first?.sessionCount, 2)
        XCTAssertEqual(summaries.first?.seconds, 1_500 + 3_600)
        XCTAssertEqual(summaries.first?.grams, 250 + 600)
        XCTAssertEqual(summaries.last?.sessionCount, 1)
        XCTAssertEqual(summaries.last?.seconds, 1_500)
        XCTAssertEqual(summaries.last?.grams, 250)
    }

    /// SwiftData runs a `@ModelActor`'s work on the thread that awaits it, so
    /// awaited straight from a main-actor `.task` the whole read froze 記録.
    /// This test is itself on the main actor, like a view.
    func testTimelineLoaderRunsTheRepositoryOffTheMainThread() async throws {
        let container = try makeContainer()
        XCTAssertTrue(Thread.isMainThread, "The caller must be on the main thread, as a view is")

        let ranOnMainThread = try await AccumulationTimelineLoader.read(from: container) { repository in
            await repository.probeIsRunningOnMainThread()
        }

        XCTAssertFalse(
            ranOnMainThread,
            "Repository reads awaited from main-actor code must not run on the main thread"
        )
    }

    func testTimelineLoaderForwardsCancellationToTheRead() async throws {
        let container = try makeContainer()
        let started = expectation(description: "the read started")
        let read = Task { @MainActor in
            try await AccumulationTimelineLoader.read(from: container) { repository in
                started.fulfill()
                return await repository.probeWaitForCancellation(upTo: .seconds(10))
            }
        }
        await fulfillment(of: [started], timeout: 10)
        read.cancel()

        let sawCancellation = try await read.value
        XCTAssertTrue(sawCancellation, "Leaving the view must stop the repository's read")
    }

    /// Every view reads through AccumulationTimelineLoader; creating the
    /// actor anywhere else would quietly bring the read back to the main thread.
    func testOnlyTheLoaderCreatesTheTimelineRepository() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSources = projectRoot.appendingPathComponent("PomoGem", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: appSources,
            includingPropertiesForKeys: nil
        ))
        var scannedFileCount = 0
        var constructions: [String] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            scannedFileCount += 1
            for (index, line) in source.components(separatedBy: .newlines).enumerated()
            where line.contains("AccumulationTimelineRepository(") {
                constructions.append("\(fileURL.lastPathComponent):\(index + 1)")
            }
        }

        XCTAssertGreaterThan(scannedFileCount, 100, "The scan must read the app sources at \(appSources.path)")
        XCTAssertEqual(constructions.count, 1, "\(constructions)")
        XCTAssertEqual(
            constructions.first?.hasPrefix("AccumulationTimelineRepository.swift:"),
            true,
            "Only AccumulationTimelineLoader may create the repository: \(constructions)"
        )
    }

    func testLogReloadsOnlyWhatAToggleOrForegroundChanges() {
        let epochID = UUID()
        func periodKey(_ period: LogView.Period, _ phase: ScenePhase) -> String {
            LogHistoryLoadPolicy.periodKey(
                epochID: epochID,
                period: period,
                scenePhase: phase,
                isCloudVerificationPending: false
            )
        }
        func monthKey(_ phase: ScenePhase) -> String {
            LogHistoryLoadPolicy.monthSummaryKey(
                epochID: epochID,
                scenePhase: phase,
                isCloudVerificationPending: false,
                now: date(year: 2026, month: 9, day: 24),
                calendar: calendar
            )
        }

        func recentKey(_ phase: ScenePhase) -> String {
            LogHistoryLoadPolicy.recentHistoryKey(
                epochID: epochID,
                scenePhase: phase,
                isCloudVerificationPending: false
            )
        }

        // 今週 → 今月 reloads the period page only: the newest thirty,
        // milestones and aggregates (recentKey) and the twelve months
        // (monthKey) have no period in their keys.
        XCTAssertNotEqual(periodKey(.week, .active), periodKey(.month, .active))
        // Closing Control Center (active → inactive → active) reloads nothing.
        XCTAssertEqual(periodKey(.week, .active), periodKey(.week, .inactive))
        XCTAssertEqual(recentKey(.active), recentKey(.inactive))
        XCTAssertEqual(monthKey(.active), monthKey(.inactive))
        // Returning from the background reloads all three.
        XCTAssertNotEqual(periodKey(.week, .active), periodKey(.week, .background))
        XCTAssertNotEqual(recentKey(.active), recentKey(.background))
        XCTAssertNotEqual(monthKey(.active), monthKey(.background))
        // A reset (new epoch) or iCloud re-verification reloads the lists.
        XCTAssertNotEqual(
            recentKey(.active),
            LogHistoryLoadPolicy.recentHistoryKey(
                epochID: UUID(),
                scenePhase: .active,
                isCloudVerificationPending: false
            )
        )
        XCTAssertNotEqual(
            recentKey(.active),
            LogHistoryLoadPolicy.recentHistoryKey(
                epochID: epochID,
                scenePhase: .active,
                isCloudVerificationPending: true
            )
        )
        XCTAssertFalse(LogHistoryLoadPolicy.isVisible(.background))
        XCTAssertTrue(LogHistoryLoadPolicy.isVisible(.inactive))
        // A new month is a new list.
        XCTAssertNotEqual(
            monthKey(.active),
            LogHistoryLoadPolicy.monthSummaryKey(
                epochID: epochID,
                scenePhase: .active,
                isCloudVerificationPending: false,
                now: date(year: 2026, month: 10, day: 1),
                calendar: calendar
            )
        )
    }

    func testMonthDetailBreaksTheMonthIntoDaysAndThemesOnce() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let epochID = UUID()
        let english = UUID()
        let math = UUID()
        let duplicateID = UUID()
        let lastSecondOfThirteenth = date(year: 2024, month: 3, day: 14).addingTimeInterval(-1)

        func insert(
            id: UUID = UUID(),
            _ endAt: Date,
            seconds: Int,
            theme: UUID,
            name: String,
            color: String
        ) {
            context.insert(StudySession(
                id: id,
                startAt: endAt.addingTimeInterval(-TimeInterval(seconds)),
                endAt: endAt,
                seconds: seconds,
                source: .timer,
                deviceDayKey: "breakdown",
                subjectNameSnapshot: name,
                subjectColorHexSnapshot: color,
                subjectIDSnapshot: theme,
                dataEpochID: epochID
            ))
        }
        // 23:59:59 and 00:00 fall on two days.
        insert(lastSecondOfThirteenth, seconds: 1_500, theme: english, name: "英語", color: "#2457C5")
        insert(date(year: 2024, month: 3, day: 14), seconds: 3_600, theme: math, name: "数学", color: "#6BE4FF")
        // A renamed theme stays one row, named by its newest record.
        insert(date(year: 2024, month: 3, day: 20), seconds: 600, theme: english, name: "英会話", color: "#2457C5")
        // Two copies of one completion count once.
        insert(id: duplicateID, date(year: 2024, month: 3, day: 20).addingTimeInterval(3_600), seconds: 1_500, theme: math, name: "数学", color: "#6BE4FF")
        insert(id: duplicateID, date(year: 2024, month: 3, day: 20).addingTimeInterval(3_600), seconds: 1_500, theme: math, name: "数学", color: "#6BE4FF")
        try context.save()

        let detail = try await AccumulationTimelineRepository(
            modelContainer: container
        ).monthDetail(
            monthStart: date(year: 2024, month: 3, day: 1),
            currentEpochID: epochID,
            calendar: calendar
        )

        XCTAssertEqual(detail.summary.exactLocalCount, 4)
        XCTAssertEqual(detail.totalSeconds, 1_500 + 3_600 + 600 + 1_500)
        XCTAssertEqual(detail.days.map(\.dayStart), [
            date(year: 2024, month: 3, day: 20),
            date(year: 2024, month: 3, day: 14),
            date(year: 2024, month: 3, day: 13)
        ])
        XCTAssertEqual(detail.days.map(\.sessionCount), [2, 1, 1])
        XCTAssertEqual(detail.days.first?.seconds, 2_100)
        XCTAssertEqual(detail.days.first?.colorHexes, ["#6BE4FF", "#2457C5"])
        XCTAssertEqual(detail.themes.map(\.name), ["数学", "英会話"])
        XCTAssertEqual(detail.themes.map(\.seconds), [5_100, 2_100])
        XCTAssertEqual(detail.themes.map(\.sessionCount), [2, 2])
    }

    func testDayBucketsFollowLocalMidnightAcrossDaylightSavingTime() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
            try XCTUnwrap(newYork.date(from: DateComponents(
                year: 2024, month: month, day: day, hour: hour, minute: minute
            )))
        }
        func entry(_ endAt: Date) -> AccumulationTimelineBreakdownPolicy.Entry {
            AccumulationTimelineBreakdownPolicy.Entry(
                themeKey: "theme",
                themeName: "英語",
                colorHex: "#2457C5",
                endAt: endAt,
                seconds: 600,
                grams: 100
            )
        }
        // 3 November 2024 has 25 hours; 10 March 2024 has 23.
        let entries = [
            entry(try local(11, 3, 0, 30)),
            entry(try local(11, 3, 23, 30)),
            entry(try local(11, 4, 0, 10)),
            entry(try local(3, 10, 23, 50)),
            entry(try local(3, 11, 0, 5))
        ]
        let days = AccumulationTimelineBreakdownPolicy.days(entries, calendar: newYork)
        XCTAssertEqual(days.map(\.sessionCount), [1, 2, 1, 1])
        XCTAssertEqual(days.map(\.dayStart), [
            try local(11, 4, 0),
            try local(11, 3, 0),
            try local(3, 11, 0),
            try local(3, 10, 0)
        ])
    }

    func testDayDetailListsEveryRecordOfOneDayNewestFirst() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let epochID = UUID()
        let duplicateID = UUID()
        let day = date(year: 1985, month: 1, day: 15)
        insertSession(in: context, endAt: day.addingTimeInterval(-60), epochID: epochID)
        insertSession(in: context, endAt: day.addingTimeInterval(9 * 3_600), epochID: epochID)
        insertSession(id: duplicateID, in: context, endAt: day.addingTimeInterval(13 * 3_600), seconds: 3_600, grams: 600, epochID: epochID)
        insertSession(id: duplicateID, in: context, endAt: day.addingTimeInterval(13 * 3_600), seconds: 3_600, grams: 600, epochID: epochID)
        insertSession(in: context, endAt: day.addingTimeInterval(86_400), epochID: epochID)
        insertSession(in: context, endAt: day.addingTimeInterval(10 * 3_600), epochID: UUID())
        try context.save()

        let detail = try await AccumulationTimelineRepository(
            modelContainer: container
        ).dayDetail(
            dayStart: day.addingTimeInterval(12 * 3_600),
            currentEpochID: epochID,
            calendar: calendar
        )

        XCTAssertEqual(detail.dayStart, day)
        XCTAssertEqual(detail.sessions.map(\.endAt), [
            day.addingTimeInterval(13 * 3_600),
            day.addingTimeInterval(9 * 3_600)
        ])
        XCTAssertEqual(detail.sessions.first?.id, duplicateID)
        XCTAssertEqual(detail.sessions.first?.source, .timer)
        XCTAssertEqual(detail.totalSeconds, 3_600 + 1_500)
        XCTAssertEqual(detail.totalGrams, 850)
        XCTAssertEqual(detail.themes.map(\.name), ["数学"])
        XCTAssertTrue(detail.coverage.isLocallyStable)
    }

    func testFortyYearExtentCreatesNewestFirstBoundedYearList() throws {
        let extent = AccumulationTimelineExtent(
            currentEpochID: nil,
            stamp: AccumulationTimelineSnapshotStamp(
                rawRowCount: 350_640,
                oldest: AccumulationTimelineEdge(
                    id: UUID(),
                    date: date(year: 1985, month: 1, day: 1)
                ),
                newest: AccumulationTimelineEdge(
                    id: UUID(),
                    date: date(year: 2024, month: 12, day: 31)
                )
            ),
            capturedAt: date(year: 2025, month: 1, day: 1)
        )

        let years = try AccumulationTimelineYearPolicy.years(in: extent, calendar: calendar)
        XCTAssertEqual(years.count, 40)
        XCTAssertEqual(years.first?.year, 2024)
        XCTAssertEqual(years.last?.year, 1985)
    }

    func testTimelineUsesGregorianYearsWhenTheIPhoneUsesTheJapaneseCalendar() throws {
        var japanese = Calendar(identifier: .japanese)
        japanese.locale = Locale(identifier: "ja_JP@calendar=japanese")
        japanese.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let reiwa8 = try XCTUnwrap(japanese.date(from: DateComponents(
            era: 236, year: 8, month: 9, day: 24, hour: 12
        )))
        XCTAssertEqual(japanese.component(.year, from: reiwa8), 8)

        let gregorian = PomoGemCalendar.gregorian(basedOn: japanese)
        XCTAssertEqual(gregorian.identifier, .gregorian)
        XCTAssertEqual(gregorian.timeZone, japanese.timeZone)
        let extent = AccumulationTimelineExtent(
            currentEpochID: nil,
            stamp: AccumulationTimelineSnapshotStamp(
                rawRowCount: 2,
                oldest: AccumulationTimelineEdge(
                    id: UUID(),
                    date: reiwa8.addingTimeInterval(-400 * 86_400)
                ),
                newest: AccumulationTimelineEdge(id: UUID(), date: reiwa8)
            ),
            capturedAt: reiwa8
        )
        let years = try AccumulationTimelineYearPolicy.years(in: extent, calendar: gregorian)
        XCTAssertEqual(years.map(\.title), ["2026年", "2025年"])
        XCTAssertEqual(
            AccumulationTimelineAccessibilityID.month(reiwa8, calendar: gregorian),
            "overview.timeline.month.2026-09"
        )
        XCTAssertEqual(
            PomoGemCalendar.text(reiwa8, .dateTime.year().month(.wide), calendar: gregorian),
            "2026年9月"
        )
    }

    func testStabilityPolicyReportsConcurrentSnapshotChange() {
        let capturedAt = date(year: 2025, month: 1, day: 1)
        let edge = AccumulationTimelineEdge(id: UUID(), date: capturedAt)
        let before = AccumulationTimelineSnapshotStamp(
            rawRowCount: 1,
            oldest: edge,
            newest: edge
        )
        let after = AccumulationTimelineSnapshotStamp(
            rawRowCount: 2,
            oldest: edge,
            newest: edge
        )

        XCTAssertEqual(
            AccumulationTimelineStabilityPolicy.coverage(
                before: before,
                after: before,
                capturedAt: capturedAt
            ),
            .locallyStable(capturedAt: capturedAt)
        )
        XCTAssertEqual(
            AccumulationTimelineStabilityPolicy.coverage(
                before: before,
                after: after,
                capturedAt: capturedAt
            ),
            .changedDuringLoad(capturedAt: capturedAt)
        )
    }

    func testTimelineAccessibilityIdentifiersRemainStableForFortyYearFixture() {
        XCTAssertEqual(
            AccumulationTimelineAccessibilityID.year(1985),
            "overview.timeline.year.1985"
        )
        XCTAssertEqual(
            AccumulationTimelineAccessibilityID.month(
                date(year: 1985, month: 1, day: 1),
                calendar: calendar
            ),
            "overview.timeline.month.1985-01"
        )
        XCTAssertEqual(
            AccumulationTimelineAccessibilityID.coverageNotice,
            "overview.timeline.coverage-notice"
        )
        XCTAssertEqual(
            AccumulationTimelineAccessibilityID.monthPreview,
            "overview.timeline.month.preview"
        )
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "ja_JP")
        value.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return value
    }

    private func date(year: Int, month: Int, day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func insertSession(
        id: UUID = UUID(),
        in context: ModelContext,
        endAt: Date,
        seconds: Int = 1_500,
        grams: Int = 250,
        epochID: UUID?
    ) {
        context.insert(StudySession(
            id: id,
            startAt: endAt.addingTimeInterval(-TimeInterval(seconds)),
            endAt: endAt,
            seconds: seconds,
            source: .timer,
            grams: grams,
            deviceDayKey: "timeline-fixture",
            subjectNameSnapshot: "数学",
            subjectColorHexSnapshot: "6BE4FF",
            dataEpochID: epochID
        ))
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
                "AccumulationTimelineRepositoryTests-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )]
        )
    }
}

/// Test-only probes that run on the repository's actor, where its reads run.
private extension AccumulationTimelineRepository {
    func probeIsRunningOnMainThread() -> Bool {
        Thread.isMainThread
    }

    /// True once the read's task is cancelled; false if `limit` passes first.
    func probeWaitForCancellation(upTo limit: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while clock.now < deadline {
            if Task.isCancelled { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return Task.isCancelled
    }
}
