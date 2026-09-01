import XCTest
@testable import Tsumiben

final class AccumulationPlanProjectionTests: XCTestCase {
    func testFormerFortyYearBoundaryProjectsExactlyWithoutOpeningAStore() {
        let projection = AccumulationPlanProjection.make(
            plan: .fortyYearDemonstration
        )

        XCTAssertEqual(projection.elapsedMonths, 480)
        XCTAssertEqual(projection.completionCount, 350_640)
        XCTAssertEqual(projection.focusMinutes, 8_766_000)
        XCTAssertEqual(projection.focusHours, 146_100)
        XCTAssertEqual(projection.grams, 87_660_000)
        XCTAssertEqual(projection.aggregateCreationCount, 38_958)
        XCTAssertEqual(projection.bodiesByLevel, [
            1: 4,
            2: 6,
            4: 5,
            5: 3
        ])
        XCTAssertEqual(projection.studyBodyCount, 18)
        XCTAssertEqual(projection.representedPebbleCount, 350_640)
        XCTAssertEqual(projection.representedGrams, 87_660_000)
        XCTAssertTrue(projection.isInternallyConsistent)
    }

    func testTimelineProjectionChangesJarMassAndCountAtTheSelectedMonth() {
        let plan = AccumulationPlanProjection.Plan(
            years: 1,
            sessionsPerWeek: 5,
            minutesPerSession: 60
        )

        let now = AccumulationPlanProjection.make(plan: plan, elapsedMonths: 0)
        XCTAssertEqual(now.completionCount, 0)
        XCTAssertEqual(now.grams, 0)
        XCTAssertTrue(now.bodies.isEmpty)
        XCTAssertTrue(now.isInternallyConsistent)

        let halfway = AccumulationPlanProjection.make(plan: plan, elapsedMonths: 6)
        XCTAssertEqual(halfway.completionCount, 130)
        XCTAssertEqual(halfway.focusMinutes, 7_827)
        XCTAssertEqual(halfway.grams, 78_270)
        XCTAssertEqual(halfway.bodiesByLevel, [1: 3, 2: 1])
        XCTAssertEqual(halfway.aggregateCreationCount, 14)
        XCTAssertEqual(halfway.representedGrams, halfway.grams)
        XCTAssertTrue(halfway.isInternallyConsistent)

        let endpoint = AccumulationPlanProjection.make(plan: plan)
        XCTAssertEqual(endpoint.completionCount, 261)
        XCTAssertEqual(endpoint.focusMinutes, 15_654)
        XCTAssertEqual(endpoint.grams, 156_540)
        XCTAssertEqual(endpoint.bodiesByLevel, [0: 1, 1: 6, 2: 2])
        XCTAssertEqual(endpoint.aggregateCreationCount, 28)
        XCTAssertEqual(endpoint.representedGrams, endpoint.grams)
        XCTAssertTrue(endpoint.isInternallyConsistent)
    }

    func testInputsAndTimelineAreBoundedBeforeProjection() {
        let plan = AccumulationPlanProjection.Plan(
            years: 0,
            sessionsPerWeek: 0,
            minutesPerSession: 999
        )

        XCTAssertEqual(plan.years, 1)
        XCTAssertEqual(plan.sessionsPerWeek, 1)
        XCTAssertEqual(plan.minutesPerSession, 180)

        XCTAssertEqual(
            AccumulationPlanProjection.make(plan: plan, elapsedMonths: -5).elapsedMonths,
            0
        )
        XCTAssertEqual(
            AccumulationPlanProjection.make(plan: plan, elapsedMonths: 999).elapsedMonths,
            12
        )
    }

    func testProjectionIsDeterministicAndAlwaysFitsThePhysicsBudget() {
        let first = AccumulationPlanProjection.make(
            plan: .fortyYearDemonstration,
            elapsedMonths: 311
        )
        let second = AccumulationPlanProjection.make(
            plan: .fortyYearDemonstration,
            elapsedMonths: 311
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(Set(first.bodies.map(\.id)).count, first.bodies.count)
        XCTAssertLessThanOrEqual(first.studyBodyCount, Constants.Jar.maxPhysicsBodies)
        XCTAssertEqual(first.descriptors.count, first.studyBodyCount)
        XCTAssertTrue(first.isInternallyConsistent)
    }

    func testDurationChangesTimeMassAndMilestonesButNotThePlannedRhythm() {
        let tenMinutes = AccumulationPlanProjection.make(plan: .init(
            years: 1,
            sessionsPerWeek: 1,
            minutesPerSession: 10
        ))
        let sixtyMinutes = AccumulationPlanProjection.make(plan: .init(
            years: 1,
            sessionsPerWeek: 1,
            minutesPerSession: 60
        ))
        let tenMinutePresence = JarAccumulationPresencePresentation.state(
            totalGrams: tenMinutes.grams
        )
        let sixtyMinutePresence = JarAccumulationPresencePresentation.state(
            totalGrams: sixtyMinutes.grams
        )

        XCTAssertEqual(tenMinutes.completionCount, sixtyMinutes.completionCount)
        XCTAssertEqual(tenMinutes.focusMinutes, 522)
        XCTAssertEqual(sixtyMinutes.focusMinutes, 3_131)
        XCTAssertLessThanOrEqual(
            abs(sixtyMinutes.focusMinutes - tenMinutes.focusMinutes * 6),
            1
        )
        XCTAssertGreaterThan(
            sixtyMinutePresence.completedMilestoneCount,
            tenMinutePresence.completedMilestoneCount
        )
        XCTAssertTrue(tenMinutes.isInternallyConsistent)
        XCTAssertTrue(sixtyMinutes.isInternallyConsistent)
    }

    func testEquivalentWeeklyMinutesHaveIdenticalTimeAndMassAtEveryMonth() {
        let equivalentPairs: [(AccumulationPlanProjection.Plan, AccumulationPlanProjection.Plan)] = [
            // 50 minutes/week
            (.init(years: 40, sessionsPerWeek: 5, minutesPerSession: 10),
             .init(years: 40, sessionsPerWeek: 2, minutesPerSession: 25)),
            // 60 minutes/week
            (.init(years: 40, sessionsPerWeek: 6, minutesPerSession: 10),
             .init(years: 40, sessionsPerWeek: 1, minutesPerSession: 60)),
            // 300 minutes/week
            (.init(years: 40, sessionsPerWeek: 12, minutesPerSession: 25),
             .init(years: 40, sessionsPerWeek: 5, minutesPerSession: 60))
        ]

        for (firstPlan, secondPlan) in equivalentPairs {
            for month in 0 ... 480 {
                let first = AccumulationPlanProjection.make(
                    plan: firstPlan,
                    elapsedMonths: month
                )
                let second = AccumulationPlanProjection.make(
                    plan: secondPlan,
                    elapsedMonths: month
                )
                let context = "weeklyMinutes=\(firstPlan.sessionsPerWeek * firstPlan.minutesPerSession);month=\(month)"

                XCTAssertEqual(first.focusMinutes, second.focusMinutes, context)
                XCTAssertEqual(first.grams, second.grams, context)
                XCTAssertEqual(first.representedGrams, first.grams, context)
                XCTAssertEqual(second.representedGrams, second.grams, context)
                XCTAssertTrue(first.isInternallyConsistent, context)
                XCTAssertTrue(second.isInternallyConsistent, context)
            }
        }

        let longEndpoint = AccumulationPlanProjection.make(
            plan: .init(years: 40, sessionsPerWeek: 1, minutesPerSession: 60)
        )
        let shortEndpoint = AccumulationPlanProjection.make(
            plan: .init(years: 40, sessionsPerWeek: 6, minutesPerSession: 10)
        )
        XCTAssertEqual(longEndpoint.focusMinutes, 125_229)
        XCTAssertEqual(longEndpoint.grams, 1_252_290)
        XCTAssertEqual(longEndpoint.completionCount, 2_087)
        XCTAssertEqual(shortEndpoint.completionCount, 12_523)
    }

    func testTimeRoundsFromExpectationRatherThanRoundedDisplaySessionCount() {
        let projection = AccumulationPlanProjection.make(plan: .init(
            years: 1,
            sessionsPerWeek: 5,
            minutesPerSession: 60
        ))

        XCTAssertEqual(projection.completionCount, 261)
        XCTAssertEqual(projection.focusMinutes, 15_654)
        XCTAssertNotEqual(
            projection.focusMinutes,
            projection.completionCount * projection.plan.minutesPerSession
        )
        XCTAssertEqual(projection.grams, 156_540)
        XCTAssertEqual(projection.representedGrams, projection.grams)
        XCTAssertTrue(projection.isInternallyConsistent)
    }
}
