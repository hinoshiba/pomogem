import XCTest
@testable import Tsumiben

final class PebbleRadiusPolicyTests: XCTestCase {
    func testEqualFocusTimeHasEqualLoosePebbleAreaAcrossTenTwentyFiveAndSixtyMinutes() {
        // 300 minutes is divisible by every product-facing comparison duration.
        let routes = [
            (minutes: 10, completionCount: 30),
            (minutes: 25, completionCount: 12),
            (minutes: 60, completionCount: 5)
        ]
        let areas = routes.map { route in
            let radius = timerDescriptor(minutes: route.minutes).radius
            return Double(route.completionCount) * .pi * Double(radius * radius)
        }

        XCTAssertEqual(areas[0], areas[1], accuracy: 0.000_1)
        XCTAssertEqual(areas[1], areas[2], accuracy: 0.000_1)

        let baseline = Constants.Jar.measuredRadius
        XCTAssertEqual(
            timerDescriptor(minutes: 10).radius / baseline,
            CGFloat(0.4.squareRoot()),
            accuracy: 0.000_1
        )
        XCTAssertEqual(timerDescriptor(minutes: 25).radius, baseline, accuracy: 0.000_1)
        XCTAssertEqual(
            timerDescriptor(minutes: 60).radius / baseline,
            CGFloat(2.4.squareRoot()),
            accuracy: 0.000_1
        )
    }

    func testMeasuredRadiusClampsOneAndOneHundredEightyMinuteBoundaries() {
        let baseline = Constants.Jar.measuredRadius
        let oneMinute = timerDescriptor(minutes: 1).radius
        let oneHundredEightyMinutes = timerDescriptor(minutes: 180).radius

        XCTAssertEqual(
            oneMinute,
            baseline * PebbleRadiusPolicy.minimumMeasuredScale,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            oneHundredEightyMinutes,
            baseline * PebbleRadiusPolicy.maximumMeasuredScale,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            PebbleRadiusPolicy.measuredRadius(grams: 1),
            oneMinute,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            PebbleRadiusPolicy.measuredRadius(grams: Int.max),
            oneHundredEightyMinutes,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            PebbleRadiusPolicy.measuredRadius(grams: 0),
            baseline,
            accuracy: 0.000_1
        )
    }

    func testTimerDemotionKeepsTheSameMassGeometry() {
        let measured = timerDescriptor(minutes: 60, source: .timer)
        let demoted = timerDescriptor(minutes: 60, source: .timerDemoted)

        XCTAssertEqual(measured.radius, demoted.radius, accuracy: 0.000_1)
    }

    func testAggregateMassScalingIsDirectionalAndCautiouslyBounded() {
        let base = CGFloat(StrataMath.aggregateRadius(level: 1))
        let short = aggregateDescriptor(grams: 10 * 10 * Constants.Mass.gramsPerMinute)
        let nominal = aggregateDescriptor(
            grams: 10 * Constants.Mass.measuredPebbleGrams
        )
        let long = aggregateDescriptor(grams: 10 * 60 * Constants.Mass.gramsPerMinute)

        XCTAssertEqual(
            short.radius,
            base * PebbleRadiusPolicy.minimumAggregateScale,
            accuracy: 0.000_1
        )
        XCTAssertEqual(nominal.radius, base, accuracy: 0.000_1)
        XCTAssertEqual(
            long.radius,
            base * PebbleRadiusPolicy.maximumAggregateScale,
            accuracy: 0.000_1
        )
        XCTAssertLessThan(short.radius, nominal.radius)
        XCTAssertLessThan(nominal.radius, long.radius)

        XCTAssertEqual(
            PebbleRadiusPolicy.aggregateRadius(
                grams: 1,
                pebbleCount: 10,
                level: 1
            ),
            short.radius,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            PebbleRadiusPolicy.aggregateRadius(
                grams: Int.max,
                pebbleCount: 10,
                level: 1
            ),
            long.radius,
            accuracy: 0.000_1
        )
    }

    func testManualAndAchievementRadiusRulesRemainUnchanged() {
        XCTAssertEqual(
            manualDescriptor(minutes: 30).radius,
            Constants.Jar.manualThirtyRadius,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            manualDescriptor(minutes: 60).radius,
            Constants.Jar.manualSixtyRadius,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            manualDescriptor(minutes: 120).radius,
            Constants.Jar.manualOneTwentyRadius,
            accuracy: 0.000_1
        )
        let achievement = PebbleDescriptor(
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: .manual,
            kind: .normal,
            achievementKind: .examPass,
            grams: 0
        )
        XCTAssertEqual(
            achievement.radius,
            Constants.Jar.measuredRadius * Constants.Jar.achievementRadiusScale,
            accuracy: 0.000_1
        )
    }

    private func timerDescriptor(
        minutes: Int,
        source: SessionSource = .timer
    ) -> PebbleDescriptor {
        PebbleDescriptor(
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: source,
            kind: .normal,
            grams: minutes * Constants.Mass.gramsPerMinute
        )
    }

    private func manualDescriptor(minutes: Int) -> PebbleDescriptor {
        PebbleDescriptor(
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: .manual,
            kind: .normal,
            grams: minutes * Constants.Mass.gramsPerMinute
        )
    }

    private func aggregateDescriptor(grams: Int) -> PebbleDescriptor {
        let metadata = AggregateMetadata(
            level: 1,
            pebbleCount: 10,
            childAggregateCount: 0,
            colorMix: [StratumColorFraction(
                hex: Constants.Color.english,
                fraction: 1
            )],
            subjectMix: [AggregateSubjectFraction(
                name: "英語",
                colorHex: Constants.Color.english,
                pebbleCount: 10
            )],
            periodStart: Date(timeIntervalSinceReferenceDate: 0),
            periodEnd: Date(timeIntervalSinceReferenceDate: 10),
            sessionIDs: [],
            measuredPebbleCount: 10,
            manualPebbleCount: 0,
            goldPebbleCount: 0,
            prismPebbleCount: 0
        )
        return PebbleDescriptor(
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            aggregate: metadata,
            grams: grams,
            // Count-only callers used to pass this value. Aggregate mass must
            // now remain authoritative even when that legacy override exists.
            radius: baseAggregateRadius,
            createdAt: Date(timeIntervalSinceReferenceDate: 10)
        )
    }

    private var baseAggregateRadius: CGFloat {
        CGFloat(StrataMath.aggregateRadius(level: 1))
    }
}
