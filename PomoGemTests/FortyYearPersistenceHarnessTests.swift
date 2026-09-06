#if DEBUG
import XCTest
@testable import PomoGem

final class FortyYearPersistenceHarnessTests: XCTestCase {
    func testFixtureShapeMatchesTheFortyYearContractWithoutOpeningAStore() {
        XCTAssertEqual(FortyYearPersistenceHarness.Expected.sessionCount, 350_640)
        XCTAssertEqual(FortyYearPersistenceHarness.Expected.bakedSessionCount, 350_640)
        XCTAssertEqual(FortyYearPersistenceHarness.Expected.looseSessionCount, 0)
        XCTAssertEqual(FortyYearPersistenceHarness.Expected.aggregateCount, 38_958)
        XCTAssertEqual(FortyYearPersistenceHarness.Expected.rootAggregateCount, 18)
        XCTAssertEqual(FortyYearPersistenceHarness.Expected.achievementCount, 120)
        XCTAssertEqual(FortyYearPersistenceHarness.Expected.visibleAchievementCount, 12)
        XCTAssertEqual(FortyYearPersistenceHarness.Expected.achievementCountsByKind, [
            .perfectScore: 40,
            .examPass: 40,
            .workMilestone: 40
        ])
        XCTAssertEqual(FortyYearPersistenceHarness.Expected.projectedStudyDescriptorCount, 18)
        XCTAssertEqual(FortyYearPersistenceHarness.Expected.projectedDescriptorCount, 30)
        XCTAssertEqual(FortyYearPersistenceHarness.Expected.representedPebbleCount, 350_640)
        XCTAssertEqual(FortyYearPersistenceHarness.Expected.grams, 87_660_000)
        XCTAssertEqual(FortyYearPersistenceHarness.Expected.studyHierarchyRowCount, 389_603)
        XCTAssertEqual(FortyYearPersistenceHarness.Expected.totalPersistedRows, 389_723)
        XCTAssertEqual(FortyYearPersistenceHarness.Expected.sessionIDReferenceCount, 350_640)
        XCTAssertEqual(FortyYearPersistenceHarness.Expected.maximumSessionIDsPerAggregate, 10)
        XCTAssertEqual(FortyYearPersistenceHarness.Expected.childAggregateIDReferenceCount, 38_940)
        XCTAssertEqual(FortyYearPersistenceHarness.Expected.maximumChildIDsPerAggregate, 10)
    }

    func testPerformanceBudgetAcceptsItsBoundaryAndExplainsEveryOverage() {
        let budget = FortyYearPersistenceHarness.PerformanceBudget.self
        let insertionAtLimit = metrics(
            seconds: budget.maximumInsertionSeconds,
            peakBytes: budget.maximumInsertionPeakResidentBytes
        )
        let fetchAtLimit = metrics(
            seconds: budget.maximumFullFetchSeconds,
            peakBytes: budget.maximumFullFetchPeakResidentBytes
        )
        let coldAtLimit = metrics(
            seconds: budget.maximumColdProjectionSeconds,
            peakBytes: budget.maximumColdProjectionPeakResidentBytes
        )

        XCTAssertTrue(budget.failureReasons(
            storeBytes: budget.maximumStoreBytes,
            insertion: insertionAtLimit,
            fullFetch: fetchAtLimit,
            coldProjection: coldAtLimit
        ).isEmpty)

        let failures = budget.failureReasons(
            storeBytes: budget.maximumStoreBytes + 1,
            insertion: metrics(
                seconds: budget.maximumInsertionSeconds + 0.01,
                peakBytes: budget.maximumInsertionPeakResidentBytes + 1
            ),
            fullFetch: metrics(
                seconds: budget.maximumFullFetchSeconds + 0.01,
                peakBytes: budget.maximumFullFetchPeakResidentBytes + 1
            ),
            coldProjection: metrics(
                seconds: budget.maximumColdProjectionSeconds + 0.01,
                peakBytes: budget.maximumColdProjectionPeakResidentBytes + 1
            )
        )

        XCTAssertEqual(failures.count, 7)
        for expectedName in [
            "保存 ",
            "全件fetch ",
            "cold projection ",
            "store容量 ",
            "保存peak ",
            "全件fetch peak ",
            "cold projection peak "
        ] {
            XCTAssertTrue(
                failures.contains(where: { $0.hasPrefix(expectedName) }),
                "Missing an actionable reason for \(expectedName): \(failures)"
            )
        }
        XCTAssertFalse(budget.summary.isEmpty)
        XCTAssertFalse(budget.rationale.isEmpty)
    }

    func testOptInRealSwiftDataFortyYearPersistenceAndColdProjection() async throws {
        guard FortyYearPersistenceHarness.isOptedInForCurrentProcess else {
            throw XCTSkip(
                "Heavy persistence soak is opt-in: set "
                    + "\(FortyYearPersistenceHarness.optInEnvironmentKey)=1"
            )
        }
        executionTimeAllowance = 3_600

        let report = try await FortyYearPersistenceHarness.run()

        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.insertedSessionCount, 350_640)
        XCTAssertEqual(report.insertedAggregateCount, 38_958)
        XCTAssertEqual(report.insertedAchievementCount, 120)
        XCTAssertEqual(report.insertion.rowCount, 389_723)
        XCTAssertEqual(report.fetchedSubjectCount, 5)
        XCTAssertEqual(report.fetchedSessionCount, 350_640)
        XCTAssertEqual(report.fetchedAggregateCount, 38_958)
        XCTAssertEqual(report.fetchedAchievementCount, 120)
        XCTAssertEqual(report.fetchedGoldSessionCount, 34_067)
        XCTAssertEqual(report.fetchedPrismSessionCount, 2_753)
        XCTAssertEqual(report.fullFetch.rowCount, 389_723)
        XCTAssertEqual(report.fetchedAggregatesByLevel, [
            1: 35_064,
            2: 3_506,
            3: 350,
            4: 35,
            5: 3
        ])
        XCTAssertEqual(report.sessionIDReferenceCount, 350_640)
        XCTAssertEqual(report.maximumSessionIDsPerAggregate, 10)
        XCTAssertEqual(report.childAggregateIDReferenceCount, 38_940)
        XCTAssertEqual(report.maximumChildIDsPerAggregate, 10)
        XCTAssertEqual(report.coldSessionCount, 350_640)
        XCTAssertEqual(report.coldAggregateCount, 38_958)
        XCTAssertEqual(report.coldRootAggregateCount, 18)
        XCTAssertEqual(report.coldLooseSessionCount, 0)
        XCTAssertEqual(report.coldAchievementCount, 120)
        XCTAssertEqual(report.coldVisibleAchievementCount, 12)
        XCTAssertEqual(report.coldAchievementCountsByKind, [
            .perfectScore: 40,
            .examPass: 40,
            .workMilestone: 40
        ])
        XCTAssertEqual(report.coldGoldCount, 34_067)
        XCTAssertEqual(report.coldPrismCount, 2_753)
        XCTAssertEqual(report.projectedDescriptorCount, 30)
        XCTAssertEqual(report.projectedQueueCount, 0)
        XCTAssertEqual(report.representedPebbleCount, 350_640)
        XCTAssertEqual(report.representedGrams, 87_660_000)
        XCTAssertTrue(report.performanceFailureReasons.isEmpty)
        XCTAssertTrue(report.failureReasons.isEmpty)

        let measurement = """
        PomoGem 40-year SwiftData persistence soak
        store_bytes=\(report.storeBytes)
        insertion_seconds=\(report.insertion.elapsedSeconds)
        insertion_peak_bytes=\(report.insertion.peakResidentBytes)
        full_fetch_seconds=\(report.fullFetch.elapsedSeconds)
        full_fetch_peak_bytes=\(report.fullFetch.peakResidentBytes)
        cold_projection_seconds=\(report.coldProjection.elapsedSeconds)
        cold_projection_peak_bytes=\(report.coldProjection.peakResidentBytes)
        sessions=\(report.fetchedSessionCount)
        aggregates=\(report.fetchedAggregateCount)
        achievements=\(report.coldAchievementCount)
        visible_achievements=\(report.coldVisibleAchievementCount)
        cold_gold=\(report.coldGoldCount)
        cold_prism=\(report.coldPrismCount)
        roots=\(report.coldRootAggregateCount)
        loose=\(report.coldLooseSessionCount)
        projected_descriptors=\(report.projectedDescriptorCount)
        projected_queue=\(report.projectedQueueCount)
        session_id_references=\(report.sessionIDReferenceCount)
        max_session_ids_per_aggregate=\(report.maximumSessionIDsPerAggregate)
        child_id_references=\(report.childAggregateIDReferenceCount)
        max_child_ids_per_aggregate=\(report.maximumChildIDsPerAggregate)
        """
        print(measurement)
        let attachment = XCTAttachment(string: measurement)
        attachment.name = "FortyYearPersistenceMeasurements.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func metrics(
        seconds: TimeInterval,
        peakBytes: UInt64
    ) -> FortyYearPersistenceHarness.StageMetrics {
        FortyYearPersistenceHarness.StageMetrics(
            elapsedSeconds: seconds,
            rowCount: 1,
            residentBytesBefore: 1,
            residentBytesAfter: peakBytes,
            peakResidentBytes: peakBytes
        )
    }
}
#endif
