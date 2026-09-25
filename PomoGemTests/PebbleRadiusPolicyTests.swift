import XCTest
@testable import PomoGem

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

    // MARK: Jar-wide scale (D4, Docs/GemExperienceDesign.md §7.5)

    /// Jar interiors (width × height, points) the policy is tuned for,
    /// measured in the Simulator: Home on the iPhone 17 Pro and 12 mini,
    /// the default 390 pt scene, the 17 Pro jar shortened by the completion
    /// card, and the lowest (320 pt) jar of the worst case. Only the first
    /// three are resting Home jars (`isTypical`).
    private let interiors: [(name: String, width: CGFloat, height: CGFloat, isTypical: Bool)] = [
        ("17 Pro", 306, 398, true),
        ("12 mini", 279, 356, true),
        ("390 pt scene", 334, 398, true),
        ("17 Pro, card", 306, 288, false),
        ("320 pt jar", 334, 298, false)
    ]

    /// One scale for every body keeps `PebbleRadiusPolicy`'s ratios: equal
    /// focus time still covers equal area, and the bounds scale together.
    @MainActor
    func testJarScaleKeepsAreaProportionalToMassBetweenGems() {
        for scale in [1, 1.37, JarScalePolicy.maximumScale] as [CGFloat] {
            let areas = [(10, 30), (25, 12), (60, 5)].map { minutes, count -> CGFloat in
                let node = PebbleNode(
                    descriptor: timerDescriptor(minutes: minutes),
                    reduceMotion: true,
                    jarScale: scale
                )
                XCTAssertEqual(node.radius, node.localRadius * scale, accuracy: 0.000_1)
                XCTAssertEqual(node.xScale, scale, accuracy: 0.000_1, "Visual and physics radius scale together")
                return CGFloat(count) * .pi * node.radius * node.radius
            }
            XCTAssertEqual(areas[0], areas[1], accuracy: 0.01)
            XCTAssertEqual(areas[1], areas[2], accuracy: 0.01)
            let one = PebbleNode(descriptor: timerDescriptor(minutes: 1), reduceMotion: true, jarScale: scale)
            let long = PebbleNode(descriptor: timerDescriptor(minutes: 180), reduceMotion: true, jarScale: scale)
            XCTAssertEqual(
                long.radius / one.radius,
                PebbleRadiusPolicy.maximumMeasuredScale / PebbleRadiusPolicy.minimumMeasuredScale,
                accuracy: 0.000_1
            )
        }
        // The stored geometry never sees the scale.
        XCTAssertEqual(timerDescriptor(minutes: 25).radius, Constants.Jar.measuredRadius)
    }

    /// More load never makes the jar larger, and the scale stays within
    /// 1 (the shipping size) … `maximumScale`.
    func testJarScaleFallsMonotonicallyWithLoadAndNeverLeavesItsBounds() {
        for interior in interiors {
            let area = interior.width * interior.height
            var previousTarget = CGFloat.greatestFiniteMagnitude
            var previousResolved = CGFloat.greatestFiniteMagnitude
            var current = JarScalePolicy.maximumScale
            var load: CGFloat = 100
            while load < area * 3 {
                let target = JarScalePolicy.targetScale(baseArea: load, interiorArea: area)
                XCTAssertLessThanOrEqual(target, previousTarget, "\(interior.name) \(load)")
                XCTAssertGreaterThanOrEqual(target, JarScalePolicy.minimumScale)
                XCTAssertLessThanOrEqual(target, JarScalePolicy.maximumScale)
                // A jar that only gains bodies only ever shrinks.
                current = JarScalePolicy.resolvedScale(current: current, target: target)
                XCTAssertLessThanOrEqual(current, previousResolved)
                XCTAssertLessThanOrEqual(current, target + 0.000_1, "Never above the budget")
                previousTarget = target
                previousResolved = current
                load *= 1.06
            }
            // A pile beyond the budget is shown at the shipping size.
            XCTAssertEqual(JarScalePolicy.targetScale(baseArea: area, interiorArea: area), 1)
            XCTAssertEqual(current, 1)
        }
        XCTAssertEqual(JarScalePolicy.targetScale(baseArea: 0, interiorArea: 100_000), JarScalePolicy.maximumScale)
        XCTAssertEqual(JarScalePolicy.targetScale(baseArea: .nan, interiorArea: 100_000), JarScalePolicy.maximumScale)
        XCTAssertEqual(JarScalePolicy.targetScale(baseArea: 1_000, interiorArea: 0), 1)
        XCTAssertEqual(JarScalePolicy.targetScale(baseArea: 1_000, interiorArea: .infinity), 1)
    }

    /// The floor is the shipping size for every input and every body kind.
    func testJarScaleNeverGoesBelowTheShippingSize() {
        for raw in [-1, 0, 0.2, 0.99, .nan, -.infinity] as [CGFloat] {
            XCTAssertEqual(JarScalePolicy.rung(atOrBelow: raw), 1)
            XCTAssertEqual(JarScalePolicy.resolvedScale(current: raw, target: raw), 1)
            XCTAssertEqual(JarScalePolicy.resolvedScale(current: 2, target: raw), 1)
            XCTAssertEqual(JarScalePolicy.obstacleScale(studyScale: raw), 1)
            XCTAssertEqual(PebbleNode.sanitizedJarScale(raw), 1)
        }
        XCTAssertEqual(JarScalePolicy.rung(atOrBelow: 99), JarScalePolicy.maximumScale)
        XCTAssertEqual(PebbleNode.sanitizedJarScale(99), JarScalePolicy.maximumScale)
        XCTAssertGreaterThanOrEqual(JarScalePolicy.maximumScale, 2)
        XCTAssertLessThanOrEqual(JarScalePolicy.maximumScale, 2.6)
    }

    /// Shrinking is immediate (the budget always holds); growing waits
    /// until the target clears the current rung by two rungs, so a load that
    /// wobbles around a boundary never makes the jar pulse.
    func testJarScaleHysteresisShrinksAtOnceAndGrowsOnlyPastTwoRungs() {
        let ratio = JarScalePolicy.rungRatio
        let current = pow(ratio, 12)
        XCTAssertEqual(JarScalePolicy.rung(atOrBelow: current), current, accuracy: 0.000_1)
        // A hair below: one rung down at once.
        XCTAssertEqual(
            JarScalePolicy.resolvedScale(current: current, target: current * 0.999),
            pow(ratio, 11),
            accuracy: 0.000_1
        )
        // Up to (but not including) two rungs above: unchanged.
        for factor in [1.0, 1.02, ratio, ratio * 1.03] {
            XCTAssertEqual(JarScalePolicy.resolvedScale(current: current, target: current * factor), current)
        }
        // Two rungs above: it grows to the rung under the target.
        XCTAssertEqual(
            JarScalePolicy.resolvedScale(current: current, target: current * ratio * ratio * 1.001),
            pow(ratio, 14),
            accuracy: 0.000_1
        )

        // No oscillation: a body arriving and leaving again and again (the
        // load crossing a rung) changes the scale once, then never again.
        let interior: CGFloat = 306 * 398
        let edge = interior * JarScalePolicy.interiorAreaBudgetFraction / (current * current)
        var scale = current
        var changes = 0
        for step in 0 ..< 40 {
            let load = step.isMultiple(of: 2) ? edge * 1.01 : edge * 0.99
            let next = JarScalePolicy.resolvedScale(
                current: scale,
                target: JarScalePolicy.targetScale(baseArea: load, interiorArea: interior)
            )
            if next != scale { changes += 1 }
            scale = next
        }
        XCTAssertEqual(changes, 1)
        // The same content always resolves to the same scale.
        let target = JarScalePolicy.targetScale(baseArea: 9_000, interiorArea: interior)
        let settled = JarScalePolicy.resolvedScale(current: 1, target: target)
        XCTAssertEqual(JarScalePolicy.resolvedScale(current: settled, target: target), settled)
    }

    /// Screen Time stones grow with their own cap: never beyond the study
    /// scale, and once they grow at all, never larger than a study gem of
    /// the same time in the same jar.
    func testBlackStonesScaleWithTheirOwnCapAndNeverOutgrowStudyGems() {
        var scale: CGFloat = 1
        while scale <= JarScalePolicy.maximumScale + 0.000_1 {
            let stoneScale = JarScalePolicy.obstacleScale(studyScale: scale)
            XCTAssertLessThanOrEqual(stoneScale, scale + 0.000_1)
            XCTAssertLessThanOrEqual(stoneScale, JarScalePolicy.maximumObstacleScale)
            XCTAssertGreaterThanOrEqual(stoneScale, 1)
            if stoneScale > 1 {
                for level in 0 ... 5 {
                    let stone = ScreenTimeObstacleDescriptor(
                        level: level,
                        slot: 0,
                        representedUnits: Int(pow(10, Double(level))),
                        isHistoryPile: false
                    )
                    let minutes = stone.representedUnits * 10
                    let study = PebbleRadiusPolicy.measuredRadius(
                        grams: minutes > Int.max / Constants.Mass.gramsPerMinute
                            ? Int.max
                            : minutes * Constants.Mass.gramsPerMinute
                    )
                    XCTAssertLessThanOrEqual(
                        stone.radius * stoneScale,
                        study * scale + 0.000_1,
                        "Level \(level) at \(scale)"
                    )
                }
            }
            let stone = PebbleDescriptor(screenTimeObstacle: ScreenTimeObstacleProjection.decimalRoots(totalUnits: 1)[0])
            XCTAssertEqual(JarScalePolicy.bodyScale(for: stone, studyScale: scale), stoneScale)
            XCTAssertEqual(JarScalePolicy.bodyScale(for: timerDescriptor(minutes: 25), studyScale: scale), scale)
            scale += 0.05
        }
    }

    /// Acceptance (a): a young and a mid jar — the first gem, five loose
    /// gems, 3.75 kg (×10 + five) and nine loose gems with three ×10 roots —
    /// show a 25-minute gem at about a fifth to a sixth of the interior
    /// width, like the reference image.
    func testTypicalLoadsShowLooseGemsAtAFifthToASixthOfTheJar() {
        let loose = timerDescriptor(minutes: 25)
        let root = aggregateDescriptor(grams: 10 * Constants.Mass.measuredPebbleGrams)
        let loads: [(name: String, bodies: [PebbleDescriptor])] = [
            ("first gem", [loose]),
            ("five loose", Array(repeating: loose, count: 5)),
            ("3.75 kg", [root] + Array(repeating: loose, count: 5)),
            ("nine loose + three roots", Array(repeating: root, count: 3) + Array(repeating: loose, count: 9))
        ]
        for interior in interiors where interior.isTypical {
            for load in loads {
                let scale = JarScalePolicy.resolvedScale(
                    current: 1,
                    target: JarScalePolicy.targetScale(
                        baseArea: JarScalePolicy.baseArea(radii: load.bodies.map(\.radius)),
                        interiorArea: interior.width * interior.height
                    )
                )
                let share = loose.radius * 2 * scale / interior.width
                XCTAssertGreaterThanOrEqual(share, 0.15, "\(interior.name), \(load.name)")
                XCTAssertLessThanOrEqual(share, 0.20, "\(interior.name), \(load.name)")
            }
        }
    }

#if DEBUG && targetEnvironment(simulator)
    /// Acceptance (b), the budget half: at every showcase fixture and in
    /// every jar the scaled bodies either stay within the area budget or the
    /// jar is at the shipping size. (The measured half — at least 15 % free
    /// under the mouth over ten or more settles of every fixture — is the
    /// Simulator settle probe, `POMOGEM_UI_TEST_SETTLE_PROBE`, §7.5.)
    func testEveryShowcaseFixtureStaysWithinTheAreaBudgetOrAtTheShippingSize() {
        let loose = timerDescriptor(minutes: 25)
        func roots(_ level: Int, _ count: Int) -> [PebbleDescriptor] {
            Array(repeating: aggregateDescriptor(
                grams: Int(pow(10, Double(level))) * Constants.Mass.measuredPebbleGrams,
                level: level
            ), count: count)
        }
        let achievement = PebbleDescriptor(
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: .manual,
            kind: .normal,
            achievementKind: .examPass,
            grams: 0
        )
        func stones(_ units: Int) -> [PebbleDescriptor] {
            ScreenTimeObstacleProjection.visibleDescriptors(totalUnits: units).map(PebbleDescriptor.init(screenTimeObstacle:))
        }
        let fixtures: [(name: String, bodies: [PebbleDescriptor])] = [
            ("first", [loose]),
            ("home", roots(1, 1) + Array(repeating: loose, count: 5)),
            ("midload", roots(1, 3) + Array(repeating: loose, count: 9)),
            ("tiers", roots(2, 1) + roots(1, 1) + Array(repeating: loose, count: 7) + [achievement]),
            ("heavy", roots(3, 1) + Array(repeating: loose, count: 4)),
            ("veteran", roots(4, 1) + Array(repeating: loose, count: 6)),
            ("gallery", GemShowcaseUITestFixture.galleryDescriptors() + stones(12)),
            ("fusionfx", GemShowcaseUITestFixture.fusionEffectDescriptors() + [GemShowcaseUITestFixture.fusionEffectDrop]),
            ("worstcase", GemShowcaseUITestFixture.worstCaseDescriptors() + stones(9_999)),
            ("stress", GemShowcaseUITestFixture.stressDescriptors() + stones(9_999))
        ]
        for interior in interiors {
            let area = interior.width * interior.height
            for fixture in fixtures {
                let unscaled = JarScalePolicy.baseArea(radii: fixture.bodies.map(\.radius))
                let scale = JarScalePolicy.resolvedScale(
                    current: 1,
                    target: JarScalePolicy.targetScale(baseArea: unscaled, interiorArea: area)
                )
                let covered = JarScalePolicy.baseArea(radii: fixture.bodies.map {
                    $0.radius * JarScalePolicy.bodyScale(for: $0, studyScale: scale)
                })
                if scale > 1 {
                    XCTAssertLessThanOrEqual(
                        covered / area,
                        JarScalePolicy.interiorAreaBudgetFraction + 0.000_1,
                        "\(fixture.name) in \(interior.name) at \(scale)"
                    )
                } else {
                    XCTAssertEqual(covered, unscaled, accuracy: 0.01, "\(fixture.name) at the shipping size")
                }
            }
        }
    }
#endif

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

    private func aggregateDescriptor(grams: Int, level: Int = 1) -> PebbleDescriptor {
        let pebbleCount = Int(pow(10, Double(level)))
        let metadata = AggregateMetadata(
            level: level,
            pebbleCount: pebbleCount,
            childAggregateCount: 0,
            colorMix: [StratumColorFraction(
                hex: Constants.Color.english,
                fraction: 1
            )],
            subjectMix: [AggregateSubjectFraction(
                name: "英語",
                colorHex: Constants.Color.english,
                pebbleCount: pebbleCount
            )],
            periodStart: Date(timeIntervalSinceReferenceDate: 0),
            periodEnd: Date(timeIntervalSinceReferenceDate: 10),
            sessionIDs: [],
            measuredPebbleCount: pebbleCount,
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
