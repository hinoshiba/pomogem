import SwiftData
import XCTest
@testable import Tsumiben

@MainActor
final class HomeProjectionTests: XCTestCase {
    func testHistoryDestinationDescriptorsAreEpochFilteredAndHardBounded() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let currentEpoch = UUID()
        let staleEpoch = UUID()
        let base = Date(timeIntervalSince1970: 5_000)

        for index in 0..<24 {
            context.insert(StudySession(
                startAt: base.addingTimeInterval(Double(index)),
                endAt: base.addingTimeInterval(Double(index + 1)),
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "current",
                dataEpochID: currentEpoch
            ))
            context.insert(StudySession(
                startAt: base.addingTimeInterval(Double(index)),
                endAt: base.addingTimeInterval(Double(index + 1)),
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "stale",
                dataEpochID: staleEpoch
            ))
        }
        try context.save()

        let descriptor = BoundedHistoryPolicy.sessionDescriptor(
            epochID: currentEpoch,
            order: .reverse,
            limit: 11
        )
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(descriptor.fetchLimit, 11)
        XCTAssertEqual(fetched.count, 11)
        XCTAssertTrue(fetched.allSatisfy { $0.dataEpochID == currentEpoch })

        XCTAssertEqual(
            BoundedHistoryPolicy.latestResetMarkerDescriptor().fetchLimit,
            1
        )
        XCTAssertEqual(
            BoundedHistoryPolicy.rootAggregateDescriptor(
                epochID: currentEpoch,
                limit: BoundedHistoryPolicy.aggregateRootLimit + 1
            ).fetchLimit,
            BoundedHistoryPolicy.aggregateRootLimit + 1
        )
    }

    func testShareAggregateSummaryIsSupplementalWithoutExpandingMembership() {
        let memberIDs = (0..<10).map { _ in UUID() }
        let aggregate = AggregatePebble(
            level: 1,
            pebbleCount: 10,
            grams: 2_500,
            measuredPebbleCount: 8,
            manualPebbleCount: 2,
            goldPebbleCount: 1,
            prismPebbleCount: 1,
            colorMixJSON: "[]",
            periodStart: .now.addingTimeInterval(-3_600),
            periodEnd: .now,
            sessionIDs: memberIDs
        )

        let summary = ShareAggregateVisual(aggregateSummary: aggregate)
        XCTAssertTrue(summary.sessionIDs.isEmpty)
        XCTAssertEqual(summary.pebbleCount, 10)
        XCTAssertEqual(summary.grams, 2_500)
        XCTAssertEqual(summary.measuredPebbleCount, 8)
        XCTAssertEqual(summary.manualPebbleCount, 2)
        XCTAssertEqual(summary.goldPebbleCount, 1)
        XCTAssertEqual(summary.prismPebbleCount, 1)
        XCTAssertTrue(summary.contributesStandaloneTotals)
    }

    func testScopedAggregateShareUsesOneAuthoritativeAccountingSource() {
        let base = Date(timeIntervalSince1970: 50_000)
        let aggregate = AggregatePebble(
            level: 1,
            pebbleCount: 10,
            grams: 2_500,
            measuredPebbleCount: 10,
            manualPebbleCount: 0,
            colorMixJSON: "[]",
            periodStart: base,
            periodEnd: base.addingTimeInterval(15_000),
            sessionIDs: (0..<10).map { _ in UUID() }
        )

        XCTAssertEqual(
            ScopedAggregateShareProjection.mode(
                for: aggregate,
                includesSelfReportedFocus: false
            ),
            .authoritativeSummary
        )
        XCTAssertEqual(
            ScopedAggregateShareProjection.mode(
                for: aggregate,
                includesSelfReportedFocus: true
            ),
            .authoritativeSummary
        )
    }

    func testScopedMixedAggregateReconstructsMeasuredOnlyButSummarizesWhenIncluded() {
        let base = Date(timeIntervalSince1970: 60_000)
        let aggregate = AggregatePebble(
            level: 1,
            pebbleCount: 10,
            grams: 3_200,
            measuredPebbleCount: 8,
            manualPebbleCount: 2,
            colorMixJSON: "[]",
            periodStart: base,
            periodEnd: base.addingTimeInterval(15_000),
            sessionIDs: (0..<10).map { _ in UUID() }
        )

        XCTAssertEqual(
            ScopedAggregateShareProjection.mode(
                for: aggregate,
                includesSelfReportedFocus: false
            ),
            .filteredMembers
        )
        XCTAssertEqual(
            ScopedAggregateShareProjection.mode(
                for: aggregate,
                includesSelfReportedFocus: true
            ),
            .authoritativeSummary
        )
    }

    func testHomeFetchDescriptorsRemainHardBounded() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let base = Date(timeIntervalSince1970: 10_000)

        for index in 0..<600 {
            context.insert(StudySession(
                startAt: base.addingTimeInterval(Double(index)),
                endAt: base.addingTimeInterval(Double(index + 1)),
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "fixture",
                isBaked: false
            ))
        }
        for index in 0..<160 {
            context.insert(AggregatePebble(
                createdAt: base.addingTimeInterval(Double(index)),
                level: 2,
                pebbleCount: 100,
                grams: 25_000,
                colorMixJSON: "[]",
                periodStart: base,
                periodEnd: base.addingTimeInterval(Double(index + 1))
            ))
        }
        for index in 0..<40 {
            context.insert(AchievementStone(
                kind: .perfectScore,
                achievedAt: base.addingTimeInterval(Double(index)),
                createdAt: base.addingTimeInterval(Double(index))
            ))
        }
        for index in 0..<24 {
            context.insert(Stratum(
                bakedAt: base.addingTimeInterval(Double(index)),
                pebbleCount: 10,
                heightPt: 1,
                colorMixJSON: "[]",
                monthLabel: "legacy"
            ))
        }
        try context.save()

        XCTAssertEqual(
            try context.fetch(HomeProjectionPolicy.looseSessionDescriptor()).count,
            HomeProjectionPolicy.looseSessionQueryLimit
        )
        XCTAssertEqual(
            try context.fetch(HomeProjectionPolicy.aggregateRootDescriptor()).count,
            HomeProjectionPolicy.aggregateRootLimit
        )
        XCTAssertEqual(
            try context.fetch(HomeProjectionPolicy.achievementCandidateDescriptor()).count,
            HomeProjectionPolicy.achievementLimit
        )
        XCTAssertEqual(
            try context.fetch(HomeProjectionPolicy.legacyCompatibilityDescriptor()).count,
            HomeProjectionPolicy.legacyCompatibilityLimit
        )
    }

    func testFortyYearProjectionTotalsUseOnlyEighteenDecimalRoots() {
        let base = Date(timeIntervalSince1970: 20_000)
        let rootPebbleCounts = Array(repeating: 10, count: 4)
            + Array(repeating: 100, count: 6)
            + Array(repeating: 10_000, count: 5)
            + Array(repeating: 100_000, count: 3)
        let roots = rootPebbleCounts.enumerated().map { index, count in
            AggregatePebble(
                createdAt: base.addingTimeInterval(Double(index)),
                level: count == 10 ? 1 : (count == 100 ? 2 : (count == 10_000 ? 4 : 5)),
                pebbleCount: count,
                grams: count * 250,
                colorMixJSON: "[]",
                periodStart: base,
                periodEnd: base.addingTimeInterval(Double(index + 1))
            )
        }
        let loose: [StudySession] = []

        let totals = HomeProjectionPolicy.totals(roots: roots, looseSessions: loose)
        XCTAssertEqual(roots.count, 18)
        XCTAssertEqual(rootPebbleCounts.reduce(0, +), 350_640)
        XCTAssertEqual(totals.pebbleCount, 350_640)
        XCTAssertEqual(totals.grams, 87_660_000)
        XCTAssertEqual(roots.count + loose.count, 18)
        XCTAssertLessThanOrEqual(roots.count + loose.count, Constants.Jar.maxPhysicsBodies)
    }

    func testHomeProjectionTotalsSaturateInsteadOfCrashingOnIntegerOverflow() {
        let base = Date(timeIntervalSince1970: 21_000)
        let roots = [
            AggregatePebble(
                createdAt: base,
                level: 1,
                pebbleCount: Int.max,
                grams: Int.max,
                colorMixJSON: "[]",
                periodStart: base,
                periodEnd: base
            ),
            AggregatePebble(
                createdAt: base.addingTimeInterval(1),
                level: 1,
                pebbleCount: 1,
                grams: 250,
                colorMixJSON: "[]",
                periodStart: base,
                periodEnd: base.addingTimeInterval(1)
            )
        ]

        let totals = HomeProjectionPolicy.totals(
            roots: roots,
            looseSessions: []
        )

        XCTAssertEqual(totals.grams, Int.max)
        XCTAssertEqual(totals.pebbleCount, Int.max)
        XCTAssertEqual(
            HomeProjectionPolicy.saturatingNonnegativeSum([-10, 40, Int.max]),
            Int.max
        )
    }

    func testCompletionMetricsCountSaturatesAtIntegerLimit() throws {
        let container = try makeContainer()
        let now = Date(timeIntervalSince1970: 22_000)
        let root = AggregatePebble(
            createdAt: now,
            level: 1,
            pebbleCount: Int.max,
            grams: Int.max,
            measuredPebbleCount: Int.max,
            manualPebbleCount: 0,
            colorMixJSON: "[]",
            periodStart: now,
            periodEnd: now
        )
        let loose = StudySession(
            startAt: now.addingTimeInterval(-600),
            endAt: now,
            seconds: 600,
            source: .timer,
            grams: 100,
            deviceDayKey: "fixture"
        )

        let metrics = try HomeProjectionPolicy.completionMetrics(
            context: container.mainContext,
            resetMarkers: [],
            roots: [root],
            looseSessions: [loose],
            at: now
        )
        XCTAssertEqual(metrics.completedFocusCount, Int.max)
    }

    func testBoundedProjectionDoesNotSumFlattenedParentAndRootChild() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let base = Date(timeIntervalSince1970: 25_000)
        let parentSessionIDs = (0..<100).map { _ in UUID() }
        let child = AggregatePebble(
            createdAt: base.addingTimeInterval(1),
            level: 1,
            pebbleCount: 10,
            grams: 2_500,
            measuredPebbleCount: 10,
            manualPebbleCount: 0,
            colorMixJSON: "[]",
            periodStart: base,
            periodEnd: base.addingTimeInterval(1),
            sessionIDs: Array(parentSessionIDs.prefix(10))
        )
        let flattenedParent = AggregatePebble(
            createdAt: base,
            level: 2,
            pebbleCount: 100,
            childAggregateCount: 1,
            grams: 25_000,
            measuredPebbleCount: 100,
            manualPebbleCount: 0,
            colorMixJSON: "[]",
            periodStart: base,
            periodEnd: base.addingTimeInterval(2),
            sessionIDs: parentSessionIDs,
            childAggregateIDs: [child.id]
        )
        context.insert(flattenedParent)
        context.insert(child)
        try context.save()

        let acceptedIDs = try HomeProjectionPolicy.acceptedRootSummaryIDs(
            roots: [child, flattenedParent],
            context: context,
            resetMarkers: []
        )
        let acceptedRoots = [child, flattenedParent].filter {
            acceptedIDs.contains($0.id)
        }
        let totals = HomeProjectionPolicy.totals(
            roots: acceptedRoots,
            looseSessions: []
        )

        XCTAssertEqual(acceptedIDs, [flattenedParent.id])
        XCTAssertEqual(totals.pebbleCount, 100)
        XCTAssertEqual(totals.grams, 25_000)
    }

    func testAggregatePersistenceMissingLeafDoesNotMutateAnySource() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try makeLeafAggregateFixture()
        for session in fixture.sessions.dropLast() {
            context.insert(session)
        }
        try context.save()

        XCTAssertThrowsError(try HomeAggregatePersistence.persist(
            fixture.request,
            context: context,
            dataEpochID: nil,
            resetMarkers: []
        )) { error in
            XCTAssertEqual(
                error as? HomeAggregatePersistenceError,
                .missingCurrentSource(fixture.sessions.last!.id)
            )
        }

        XCTAssertTrue(fixture.sessions.dropLast().allSatisfy { !$0.isBaked })
        XCTAssertTrue(try aggregateRows(id: fixture.request.id, context: context).isEmpty)
    }

    func testAggregatePersistenceAlreadyBakedLeafDoesNotMutateSiblings() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try makeLeafAggregateFixture()
        fixture.sessions[3].isBaked = true
        fixture.sessions.forEach { context.insert($0) }
        try context.save()

        XCTAssertThrowsError(try HomeAggregatePersistence.persist(
            fixture.request,
            context: context,
            dataEpochID: nil,
            resetMarkers: []
        )) { error in
            XCTAssertEqual(
                error as? HomeAggregatePersistenceError,
                .alreadyConsumedSource(fixture.sessions[3].id)
            )
        }

        XCTAssertTrue(fixture.sessions[3].isBaked)
        XCTAssertTrue(
            fixture.sessions.enumerated().allSatisfy { index, session in
                index == 3 || !session.isBaked
            }
        )
        XCTAssertTrue(try aggregateRows(id: fixture.request.id, context: context).isEmpty)
    }

    func testAggregatePersistenceCompetingChildParentIsNeverOverwritten() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try makeHigherLevelAggregateFixture()
        let competingParentID = UUID()
        fixture.children[4].parentAggregateID = competingParentID
        fixture.children.forEach { context.insert($0) }
        try context.save()

        XCTAssertThrowsError(try HomeAggregatePersistence.persist(
            fixture.request,
            context: context,
            dataEpochID: nil,
            resetMarkers: []
        )) { error in
            XCTAssertEqual(
                error as? HomeAggregatePersistenceError,
                .competingParent(
                    childID: fixture.children[4].id,
                    parentID: competingParentID
                )
            )
        }

        XCTAssertEqual(fixture.children[4].parentAggregateID, competingParentID)
        XCTAssertTrue(
            fixture.children.enumerated().allSatisfy { index, child in
                index == 4 || child.parentAggregateID == nil
            }
        )
        XCTAssertTrue(try aggregateRows(id: fixture.request.id, context: context).isEmpty)
    }

    func testExactExistingAggregateRequestIsIdempotentAndRepairsAvailableLeaves() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try makeLeafAggregateFixture()
        // A CloudKit replay may deliver the deterministic aggregate before its
        // final member. Existing materialization is authoritative; every member
        // that is present is repaired without creating a duplicate aggregate.
        for session in fixture.sessions.dropLast() {
            context.insert(session)
        }
        let existing = fixture.request.makeAggregatePebble()
        context.insert(existing)
        try context.save()

        try HomeAggregatePersistence.persist(
            fixture.request,
            context: context,
            dataEpochID: nil,
            resetMarkers: []
        )

        XCTAssertTrue(fixture.sessions.dropLast().allSatisfy(\.isBaked))
        XCTAssertEqual(try aggregateRows(id: fixture.request.id, context: context).count, 1)
    }

    func testExactExistingHigherLevelRequestRepairsOnlyNilBacklinks() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try makeHigherLevelAggregateFixture()
        fixture.children[0].parentAggregateID = fixture.request.id
        fixture.children.forEach { context.insert($0) }
        context.insert(fixture.request.makeAggregatePebble())
        try context.save()

        try HomeAggregatePersistence.persist(
            fixture.request,
            context: context,
            dataEpochID: nil,
            resetMarkers: []
        )

        XCTAssertTrue(fixture.children.allSatisfy {
            $0.parentAggregateID == fixture.request.id
        })
        XCTAssertEqual(try aggregateRows(id: fixture.request.id, context: context).count, 1)
    }

    func testCompletionMetricsUseBoundedProjectionAndFilterEnumInMemory() throws {
        let container = try makeContainer()
        let context = container.mainContext
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 31,
            hour: 12
        ))!
        let measuredID = UUID()
        let manualID = UUID()
        let measured = StudySession(
            id: measuredID,
            startAt: now.addingTimeInterval(-1_500),
            endAt: now,
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "fixture"
        )
        let manual = StudySession(
            id: manualID,
            startAt: now.addingTimeInterval(-1_800),
            endAt: now.addingTimeInterval(-300),
            seconds: 1_500,
            source: .manual,
            grams: 250,
            deviceDayKey: "fixture"
        )
        context.insert(measured)
        context.insert(manual)
        try context.save()

        let root = AggregatePebble(
            level: 3,
            pebbleCount: 1_000,
            grams: 250_000,
            measuredPebbleCount: 997,
            manualPebbleCount: 3,
            colorMixJSON: "[]",
            periodStart: now.addingTimeInterval(-100_000),
            periodEnd: now.addingTimeInterval(-10_000)
        )
        let metrics = try HomeProjectionPolicy.completionMetrics(
            context: context,
            resetMarkers: [],
            roots: [root],
            looseSessions: [measured, manual],
            at: now,
            calendar: calendar
        )

        XCTAssertEqual(metrics.completedFocusCount, 998)
        XCTAssertEqual(metrics.weeklyMeasuredSessionIDs, [measuredID])
        XCTAssertEqual(metrics.weeklyMeasuredDates, [now])
        XCTAssertEqual(metrics.weeklyMeasuredGrams, 250)
    }

    func testWeeklyMeasuredMassPagesPastNonTimerRowsBeforeFiltering() throws {
        let container = try makeContainer()
        let context = container.mainContext
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 2,
            hour: 12
        ))!

        // Newer manual rows fill the first 512-row database page. A fetch
        // limit applied before the in-memory source filter would report 0g.
        for index in 0 ..< 520 {
            let end = now.addingTimeInterval(TimeInterval(-index))
            context.insert(StudySession(
                startAt: end.addingTimeInterval(-600),
                endAt: end,
                seconds: 600,
                source: .manual,
                grams: 100,
                deviceDayKey: "fixture"
            ))
        }
        let measuredIDs = (0 ..< 6).map { index -> UUID in
            let id = UUID()
            let end = now.addingTimeInterval(TimeInterval(-2_000 - index))
            context.insert(StudySession(
                id: id,
                startAt: end.addingTimeInterval(-600),
                endAt: end,
                seconds: 600,
                source: .timer,
                grams: 100,
                deviceDayKey: "fixture"
            ))
            return id
        }
        try context.save()

        let metrics = try HomeProjectionPolicy.completionMetrics(
            context: context,
            resetMarkers: [],
            roots: [],
            looseSessions: [],
            at: now,
            calendar: calendar
        )

        XCTAssertEqual(metrics.weeklyMeasuredSessionIDs, Set(measuredIDs))
        XCTAssertEqual(metrics.weeklyMeasuredDates.count, 6)
        XCTAssertEqual(metrics.weeklyMeasuredGrams, 600)
    }

    func testOverviewWeeklyLoaderReadsPastTheOrdinaryHistoryPage() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let currentEpoch = UUID()
        let staleEpoch = UUID()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let reference = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 31,
            hour: 12
        ))!

        for index in 0 ..< 721 {
            let end = reference.addingTimeInterval(TimeInterval(index))
            context.insert(StudySession(
                startAt: end.addingTimeInterval(-600),
                endAt: end,
                seconds: 600,
                source: index.isMultiple(of: 3) ? .manual : .timer,
                grams: 100,
                deviceDayKey: "fixture",
                dataEpochID: currentEpoch
            ))
        }
        context.insert(StudySession(
            startAt: reference.addingTimeInterval(-600),
            endAt: reference,
            seconds: 600,
            source: .timer,
            grams: 100,
            deviceDayKey: "stale",
            dataEpochID: staleEpoch
        ))
        let previousWeek = reference.addingTimeInterval(-8 * 86_400)
        context.insert(StudySession(
            startAt: previousWeek.addingTimeInterval(-600),
            endAt: previousWeek,
            seconds: 600,
            source: .timer,
            grams: 100,
            deviceDayKey: "outside",
            dataEpochID: currentEpoch
        ))
        try context.save()

        let weekly = try AccumulationOverviewLoaderPolicy.weeklySessions(
            context: context,
            currentEpochID: currentEpoch,
            referenceDate: reference,
            calendar: calendar
        )

        XCTAssertEqual(weekly.count, 721)
        XCTAssertTrue(weekly.allSatisfy { $0.dataEpochID == currentEpoch })
        XCTAssertEqual(weekly.filter { $0.source == .manual }.count, 241)
    }

    private func makeLeafAggregateFixture() throws -> (
        request: JarAggregateRequest,
        sessions: [StudySession]
    ) {
        let base = Date(timeIntervalSince1970: 70_000)
        var sessions: [StudySession] = []
        sessions.reserveCapacity(Constants.Jar.aggregateFanIn)
        for index in 0..<Constants.Jar.aggregateFanIn {
            let session = StudySession(
                startAt: base.addingTimeInterval(Double(index * 1_500)),
                endAt: base.addingTimeInterval(Double((index + 1) * 1_500)),
                seconds: 1_500,
                source: .timer,
                pebbleKind: index == 0 ? .gold : .normal,
                grams: 250,
                deviceDayKey: "fixture"
            )
            sessions.append(session)
        }
        let request = try XCTUnwrap(JarAggregateRequest(
            pebbles: sessions.map(PebbleDescriptor.init(session:)),
            innerWidth: 320
        ))
        return (request, sessions)
    }

    private func makeHigherLevelAggregateFixture() throws -> (
        request: JarAggregateRequest,
        children: [AggregatePebble]
    ) {
        let base = Date(timeIntervalSince1970: 90_000)
        var children: [AggregatePebble] = []
        children.reserveCapacity(Constants.Jar.aggregateFanIn)
        for index in 0..<Constants.Jar.aggregateFanIn {
            let sessionIDs = (0..<10).map { _ in UUID() }
            let child = AggregatePebble(
                createdAt: base.addingTimeInterval(Double(index)),
                level: 1,
                pebbleCount: 10,
                grams: 2_500,
                measuredPebbleCount: 10,
                manualPebbleCount: 0,
                goldPebbleCount: index == 0 ? 1 : 0,
                prismPebbleCount: 0,
                colorMixJSON: "[]",
                subjectMixJSON: "[]",
                periodStart: base.addingTimeInterval(Double(index * 10)),
                periodEnd: base.addingTimeInterval(Double(index * 10 + 9)),
                sessionIDs: sessionIDs
            )
            children.append(child)
        }
        let request = try XCTUnwrap(JarAggregateRequest(
            pebbles: children.map(PebbleDescriptor.init(aggregate:)),
            innerWidth: 320
        ))
        return (request, children)
    }

    private func aggregateRows(
        id: UUID,
        context: ModelContext
    ) throws -> [AggregatePebble] {
        let aggregateID = id
        return try context.fetch(FetchDescriptor<AggregatePebble>(
            predicate: #Predicate { aggregate in aggregate.id == aggregateID }
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
                "HomeProjectionTests-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )]
        )
    }
}
