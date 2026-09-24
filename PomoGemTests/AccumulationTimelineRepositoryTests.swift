import SwiftData
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
