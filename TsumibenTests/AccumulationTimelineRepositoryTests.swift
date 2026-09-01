import SwiftData
import XCTest
@testable import Tsumiben

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
        let extent = try await repository.extent(currentEpochID: epochID)
        let year = try XCTUnwrap(
            AccumulationTimelineYearPolicy.years(in: extent, calendar: calendar).first
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
                grams: index + 1,
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
                grams: 0,
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
        XCTAssertEqual(detail.summary.exactLocalGrams, 6_105)
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
        grams: Int = 250,
        epochID: UUID?
    ) {
        context.insert(StudySession(
            id: id,
            startAt: endAt.addingTimeInterval(-1_500),
            endAt: endAt,
            seconds: 1_500,
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
