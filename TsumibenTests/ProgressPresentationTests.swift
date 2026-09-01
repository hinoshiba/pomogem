import XCTest
@testable import Tsumiben

final class ProgressPresentationTests: XCTestCase {
    func testEffortProgressWeightsOneTenTwentyFiveAndSixtyMinutesByMass() {
        let fixtures: [(minutes: Int, units: Double, fraction: Double)] = [
            (1, 0.04, 0.004),
            (10, 0.4, 0.04),
            (25, 1.0, 0.10),
            (60, 2.4, 0.24)
        ]

        for fixture in fixtures {
            let grams = fixture.minutes * Constants.Mass.gramsPerMinute
            let snapshot = EffortProgressPolicy.snapshot(totalGrams: grams)
            XCTAssertEqual(
                EffortProgressPolicy.standardUnitEquivalent(totalGrams: grams),
                fixture.units,
                accuracy: 0.000_001,
                "minutes=\(fixture.minutes)"
            )
            XCTAssertEqual(
                snapshot.progressFraction,
                fixture.fraction,
                accuracy: 0.000_001,
                "minutes=\(fixture.minutes)"
            )
            XCTAssertEqual(snapshot.displayedTargetGrams, 2_500)
        }

        XCTAssertEqual(EffortProgressPresentation.formattedStandardUnits(grams: 100), "0.4標準単位")
        XCTAssertEqual(EffortProgressPresentation.formattedStandardUnits(grams: 250), "1.0標準単位")
        XCTAssertEqual(EffortProgressPresentation.formattedStandardUnits(grams: 600), "2.4標準単位")
    }

    func testSplittingTheSameTimeAcrossTimersCannotFarmEffortProgress() {
        let tenOneMinuteTimers = EffortProgressPolicy.snapshot(
            totalGrams: 10 * 1 * Constants.Mass.gramsPerMinute
        )
        let oneTenMinuteTimer = EffortProgressPolicy.snapshot(
            totalGrams: 10 * Constants.Mass.gramsPerMinute
        )
        let sixTenMinuteTimers = EffortProgressPolicy.snapshot(
            totalGrams: 6 * 10 * Constants.Mass.gramsPerMinute
        )
        let oneSixtyMinuteTimer = EffortProgressPolicy.snapshot(
            totalGrams: 60 * Constants.Mass.gramsPerMinute
        )

        XCTAssertEqual(tenOneMinuteTimers, oneTenMinuteTimer)
        XCTAssertEqual(sixTenMinuteTimers, oneSixtyMinuteTimer)
        XCTAssertEqual(tenOneMinuteTimers.progressFraction, 0.04, accuracy: 0.000_001)
        XCTAssertEqual(oneSixtyMinuteTimer.progressFraction, 0.24, accuracy: 0.000_001)
    }

    func testFortyYearsHaveIdenticalValueAcrossTenTwentyFiveAndSixtyMinuteSegments() {
        let days = 14_610
        let routes = [
            (minutesPerSession: 10, sessionsPerDay: 60),
            (minutesPerSession: 25, sessionsPerDay: 24),
            (minutesPerSession: 60, sessionsPerDay: 10)
        ]
        let totals = routes.map { route in
            let completionCount = days * route.sessionsPerDay
            let minutes = completionCount * route.minutesPerSession
            let grams = minutes * Constants.Mass.gramsPerMinute
            return (
                completionCount: completionCount,
                minutes: minutes,
                grams: grams,
                effort: EffortProgressPolicy.snapshot(totalGrams: grams),
                presence: JarAccumulationPresencePresentation.state(totalGrams: grams)
            )
        }

        XCTAssertEqual(totals.map(\.completionCount), [876_600, 350_640, 146_100])
        XCTAssertEqual(Set(totals.map(\.minutes)), [8_766_000])
        XCTAssertEqual(Set(totals.map(\.grams)), [87_660_000])
        for total in totals.dropFirst() {
            XCTAssertEqual(total.effort, totals[0].effort)
            XCTAssertEqual(total.presence, totals[0].presence)
        }
        XCTAssertEqual(
            EffortProgressPolicy.standardUnitEquivalent(totalGrams: totals[0].grams),
            350_640,
            accuracy: 0.000_001
        )
    }

    func testEffortRewardBridgeFreezesCrossedMilestoneAndCarriesOvershoot() {
        // 240 minutes existed before the latest 60-minute completion.
        let state = EffortProgressPolicy.snapshot(
            totalGrams: 300 * Constants.Mass.gramsPerMinute,
            latestContributionGrams: 60 * Constants.Mass.gramsPerMinute
        )

        XCTAssertEqual(state.crossedMilestoneGrams, 2_500)
        XCTAssertEqual(state.displayedTargetLevel, 1)
        XCTAssertEqual(state.progressFraction, 1, accuracy: 0.000_001)
        XCTAssertEqual(state.overflowGrams, 500)
        XCTAssertEqual(state.nextTargetGrams, 25_000)
        XCTAssertEqual(state.nextProgressFraction, 0.12, accuracy: 0.000_001)

        let display = EffortProgressPresentation.display(
            snapshot: state,
            projectionIsLowerBound: false
        )
        XCTAssertEqual(display.progressLabel, "最初の時間の核 到達")
        XCTAssertEqual(display.nextStepLabel, "超過した50分も次の段へ保持")
        XCTAssertEqual(display.longTermContextLabel, "次：5時間 / 41時間40分")
    }

    func testLifetimeCoreUsesMassWhileCountHierarchyRemainsIndependent() {
        XCTAssertFalse(JarLifetimeCorePresentation.shouldShowCore(
            totalPebbleCount: 10,
            totalGrams: 100
        ), "Ten one-minute pebbles are only 0.4 standard units")
        XCTAssertTrue(JarLifetimeCorePresentation.shouldShowCore(
            totalPebbleCount: 3,
            totalGrams: 2_500
        ), "A core is earned by 250 minutes even when completed in fewer timers")

        let tenMinutes = try! XCTUnwrap(JarLifetimeCorePresentation.state(
            totalPebbleCount: 1,
            totalGrams: 100,
            projectionIsLowerBound: false
        ))
        let sixtyMinutes = try! XCTUnwrap(JarLifetimeCorePresentation.state(
            totalPebbleCount: 1,
            totalGrams: 600,
            projectionIsLowerBound: false
        ))
        XCTAssertEqual(tenMinutes.progressLabel, "時間 10分 / 4時間10分")
        XCTAssertEqual(sixtyMinutes.progressLabel, "時間 1時間 / 4時間10分")
        XCTAssertEqual(tenMinutes.countLabel, "100g")
        XCTAssertEqual(sixtyMinutes.countLabel, "600g")
        XCTAssertEqual(tenMinutes.litOrbitSlotCount, 0)
        XCTAssertEqual(sixtyMinutes.litOrbitSlotCount, 2)
    }

    func testConstellationMassValueIsMonotonicAcrossDurationChoices() {
        let one = EffortConstellationPresentation.nodeDiameter(grams: 10)
        let ten = EffortConstellationPresentation.nodeDiameter(grams: 100)
        let twentyFive = EffortConstellationPresentation.nodeDiameter(grams: 250)
        let sixty = EffortConstellationPresentation.nodeDiameter(grams: 600)

        XCTAssertLessThan(one, ten)
        XCTAssertLessThan(ten, twentyFive)
        XCTAssertLessThan(twentyFive, sixty)
        XCTAssertLessThanOrEqual(sixty, 62)
    }

    func testOverviewPageScopeSeparatesExactTotalsFromBoundedDisplay() {
        let partial = AccumulationOverviewPageScope(
            totalSessionCount: 721,
            displayedSessionCount: 720,
            totalAchievementCount: 121,
            displayedAchievementCount: 120
        )

        XCTAssertTrue(partial.historyPageIsPartial)
        XCTAssertTrue(partial.achievementPageIsPartial)
        XCTAssertEqual(
            partial.timelineDetail,
            "生涯瓶は代表表示のまま、年と月を選ぶと、この端末に届いた範囲を正確に集計します。"
        )
        XCTAssertEqual(partial.shelfScopeLabel, "全721件のうち直近720件から")
        XCTAssertEqual(partial.achievementSectionSubtitle, "全121個のうち最新120個を表示")
        XCTAssertEqual(partial.achievementAccessibilitySummary, "記念石121個、最新120個を表示")
        XCTAssertEqual(
            partial.bottleRepresentativeDisclosure(
                displayedRecordCount: 28,
                displayedClusterCount: 16,
                displayedAchievementCount: 8
            ),
            "瓶の中は、粒28個・表示中のまとまり16個・記念石8個の代表表示です。"
        )

        let complete = AccumulationOverviewPageScope(
            totalSessionCount: 9,
            displayedSessionCount: 9,
            totalAchievementCount: 2,
            displayedAchievementCount: 2
        )
        XCTAssertFalse(complete.historyPageIsPartial)
        XCTAssertFalse(complete.achievementPageIsPartial)
        XCTAssertEqual(complete.shelfScopeLabel, "月ごと・全9件")
        XCTAssertEqual(complete.achievementSectionSubtitle, "質量とは別の記念・全2個")
        XCTAssertEqual(complete.achievementAccessibilitySummary, "記念石2個")
    }

    func testOverviewPageScopeDoesNotClaimEmptyLifetimeForUnloadedHistory() {
        let unloaded = AccumulationOverviewPageScope(
            totalSessionCount: 350_640,
            displayedSessionCount: 0,
            totalAchievementCount: 0,
            displayedAchievementCount: 0
        )

        XCTAssertTrue(unloaded.historyPageIsPartial)
        XCTAssertEqual(unloaded.shelfScopeLabel, "月別履歴は未読み込み")
        XCTAssertEqual(
            unloaded.emptyShelfMessage,
            "生涯記録は保存されていますが、この表示では月別履歴を読み込んでいません。"
        )
        XCTAssertFalse(unloaded.emptyShelfMessage.contains("最初の一粒"))
    }

    func testConstellationSamplesOldMiddleAndRecentRootsDeterministically() {
        let nodes = (0..<20).map(makeConstellationNode)

        let first = EffortConstellationPresentation.representativeNodes(nodes)
        let second = EffortConstellationPresentation.representativeNodes(Array(nodes.reversed()))

        XCTAssertEqual(first.count, EffortConstellationPresentation.maximumVisibleNodes)
        XCTAssertEqual(Set(first.map(\.id)).count, first.count)
        XCTAssertEqual(first.first?.id, nodes.first?.id)
        XCTAssertEqual(first.last?.id, nodes.last?.id)
        XCTAssertEqual(
            first.compactMap { node in nodes.firstIndex(where: { $0.id == node.id }) },
            [0, 3, 5, 8, 11, 14, 16, 19]
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            EffortConstellationPresentation.representativeNodes(nodes, maximum: 1),
            [nodes.last!]
        )
        XCTAssertTrue(
            EffortConstellationPresentation.representativeNodes(nodes, maximum: 0).isEmpty
        )
    }

    func testConstellationCanonicalizesDuplicateIDsBeforeSampling() {
        let id = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        let values = [
            EffortConstellationNode(
                id: id,
                level: 1,
                pebbleCount: 10,
                grams: 2_500,
                colorHex: "#AA0000",
                periodEnd: Date(timeIntervalSince1970: 30),
                containsRare: false
            ),
            EffortConstellationNode(
                id: id,
                level: 2,
                pebbleCount: 100,
                grams: 25_000,
                colorHex: "#0000AA",
                periodEnd: Date(timeIntervalSince1970: 10),
                containsRare: false
            ),
            EffortConstellationNode(
                id: id,
                level: 2,
                pebbleCount: 100,
                grams: 25_000,
                colorHex: "#00AA00",
                periodEnd: Date(timeIntervalSince1970: 20),
                containsRare: true
            )
        ]

        let result = EffortConstellationPresentation.representativeNodes(values)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.colorHex, "#00AA00")
        XCTAssertEqual(result.first?.periodEnd, Date(timeIntervalSince1970: 20))
    }

    func testConstellationDominantColorUsesMassRatherThanNodeCount() {
        let heavy = EffortConstellationNode(
            id: UUID(),
            level: 1,
            pebbleCount: 10,
            grams: 1_000,
            colorHex: "#AA0000",
            periodEnd: .distantPast,
            containsRare: false
        )
        let light = (0..<3).map { index in
            EffortConstellationNode(
                id: UUID(),
                level: 5,
                pebbleCount: 100_000,
                grams: 100,
                colorHex: "#0000AA",
                periodEnd: Date(timeIntervalSince1970: Double(index)),
                containsRare: true
            )
        }

        XCTAssertEqual(
            EffortConstellationPresentation.dominantColorHex(nodes: [heavy] + light),
            "#AA0000"
        )
    }

    func testConstellationCoreColorWeightsEveryClusterFraction() {
        let mixed = EffortConstellationNode(
            id: UUID(),
            level: 1,
            pebbleCount: 10,
            grams: 1_000,
            colorHex: "#AA0000",
            colorMix: [
                StratumColorFraction(hex: "#AA0000", fraction: 0.51),
                StratumColorFraction(hex: "#0000AA", fraction: 0.49)
            ],
            periodEnd: .distantPast,
            containsRare: false
        )
        let blue = EffortConstellationNode(
            id: UUID(),
            level: 1,
            pebbleCount: 10,
            grams: 900,
            colorHex: "#0000AA",
            colorMix: [StratumColorFraction(hex: "#0000AA", fraction: 1)],
            periodEnd: .distantFuture,
            containsRare: false
        )

        XCTAssertEqual(
            EffortConstellationPresentation.dominantColorHex(nodes: [mixed, blue]),
            "#0000AA"
        )
        XCTAssertEqual(
            EffortConstellationPresentation.dominantColorHex(
                nodes: [EffortConstellationNode(
                    id: UUID(),
                    level: 1,
                    pebbleCount: 0,
                    grams: 0,
                    colorHex: "#000000",
                    periodEnd: .now,
                    containsRare: false
                )],
                fallback: "#FA11BA"
            ),
            "#FA11BA"
        )
    }

    func testConstellationGeometryRemainsBoundedAndMonotonic() {
        var previousDiameter: CGFloat = 0
        for level in 1...20 {
            let diameter = EffortConstellationPresentation.nodeDiameter(level: level)
            XCTAssertGreaterThanOrEqual(diameter, previousDiameter)
            XCTAssertLessThanOrEqual(diameter, 62)
            previousDiameter = diameter
        }

        let size = CGSize(width: 360, height: 320)
        for count in 1...EffortConstellationPresentation.maximumVisibleNodes {
            for index in 0..<count {
                let point = EffortConstellationPresentation.orbitPosition(
                    index: index,
                    count: count,
                    in: size
                )
                XCTAssertTrue(point.x.isFinite)
                XCTAssertTrue(point.y.isFinite)
                XCTAssertGreaterThanOrEqual(point.x, 0)
                XCTAssertLessThanOrEqual(point.x, size.width)
                XCTAssertGreaterThanOrEqual(point.y, 0)
                XCTAssertLessThanOrEqual(point.y, size.height)
            }
        }
    }

    func testConstellationMassAndCoreLevelScaleAcrossFortyYears() {
        XCTAssertEqual(EffortConstellationPresentation.formattedMass(999), "999g")
        XCTAssertEqual(EffortConstellationPresentation.formattedMass(-1), "0g")
        XCTAssertEqual(EffortConstellationPresentation.formattedMass(0), "0g")
        XCTAssertEqual(EffortConstellationPresentation.formattedMass(1_000), "1.00kg")
        XCTAssertEqual(EffortConstellationPresentation.formattedMass(10_000), "10.0kg")
        XCTAssertEqual(EffortConstellationPresentation.formattedMass(1_000_000), "1.00t")
        XCTAssertEqual(EffortConstellationPresentation.formattedMass(87_660_000), "87.66t")
        XCTAssertEqual(EffortConstellationPresentation.coreLevel(totalPebbleCount: 0), 1)
        XCTAssertEqual(EffortConstellationPresentation.coreLevel(totalPebbleCount: 9), 1)
        XCTAssertEqual(EffortConstellationPresentation.coreLevel(totalPebbleCount: 10), 1)
        XCTAssertEqual(EffortConstellationPresentation.coreLevel(totalPebbleCount: 100), 2)
        XCTAssertEqual(EffortConstellationPresentation.coreLevel(totalPebbleCount: 1_000), 3)
        XCTAssertEqual(EffortConstellationPresentation.coreLevel(totalPebbleCount: 350_640), 5)
    }

    func testConstellationCoreExistsOnceTheFirstFusionIsGuaranteed() {
        for count in 0 ... 9 {
            XCTAssertFalse(
                EffortConstellationPresentation.coreIsMaterialized(
                    totalPebbleCount: count,
                    projectionIsLowerBound: false
                )
            )
        }
        XCTAssertTrue(
            EffortConstellationPresentation.coreIsMaterialized(
                totalPebbleCount: 10,
                projectionIsLowerBound: false
            )
        )
        XCTAssertTrue(
            EffortConstellationPresentation.coreIsMaterialized(
                totalPebbleCount: 350_640,
                projectionIsLowerBound: false
            )
        )
        XCTAssertTrue(
            EffortConstellationPresentation.coreIsMaterialized(
                totalPebbleCount: 350_640,
                projectionIsLowerBound: true
            ),
            "A lower bound above ten proves that a lifetime core exists"
        )
        XCTAssertFalse(
            EffortConstellationPresentation.coreIsMaterialized(
                totalPebbleCount: 9,
                projectionIsLowerBound: true
            ),
            "A lower bound below ten cannot claim the first materialized core"
        )
    }

    func testConstellationMaterializedCoreAccessibilityIncludesBothExactFusionHorizons() {
        XCTAssertEqual(
            EffortConstellationPresentation.materializedCoreAccessibilityLabel(
                totalPebbleCount: 11,
                totalGrams: 2_750,
                projectionIsLowerBound: false,
                totalNodeCount: 2,
                visibleNodeCount: 2
            ),
            "時間の核、集中2.75kg、11.0標準単位、物理履歴11粒、時間 4時間35分 / 41時間40分、核まであと37時間5分、表示中のまとまり結晶2個のうち代表2個を配置、瓶の物理整理：集中11粒"
        )
        XCTAssertEqual(
            EffortConstellationPresentation.materializedCoreAccessibilityLabel(
                totalPebbleCount: 99,
                totalGrams: 24_750,
                projectionIsLowerBound: false,
                totalNodeCount: 18,
                visibleNodeCount: 8
            ),
            "時間の核、集中24.8kg、99.0標準単位、物理履歴99粒、時間 41時間15分 / 41時間40分、核まであと25分、表示中のまとまり結晶18個のうち代表8個を配置、瓶の物理整理：集中99粒"
        )
    }

    func testConstellationMaterializedCoreAccessibilityNeverGuessesDuringPartialSync() {
        let label = EffortConstellationPresentation.materializedCoreAccessibilityLabel(
            totalPebbleCount: 99,
            totalGrams: 24_750,
            projectionIsLowerBound: true,
            totalNodeCount: 18,
            visibleNodeCount: 8
        )

        XCTAssertEqual(
            label,
            "時間の核、集中24.8kg以上、99.0標準単位以上、物理履歴99粒以上、進捗を同期中、表示中のまとまり結晶18個のうち代表8個を配置、瓶の物理整理：集中99粒"
        )
        XCTAssertFalse(label.contains("×100へ"))
        XCTAssertFalse(label.contains("あと1粒"))
        XCTAssertFalse(label.contains("9/10"))
    }

    func testAggregateCountLabelsStayCompactAcrossFortyYears() {
        XCTAssertEqual(AggregatePresentation.countLabel(10), "×10")
        XCTAssertEqual(AggregatePresentation.countLabel(100), "×100")
        XCTAssertEqual(AggregatePresentation.countLabel(1_000), "×1千")
        XCTAssertEqual(AggregatePresentation.countLabel(10_000), "×1万")
        XCTAssertEqual(AggregatePresentation.countLabel(100_000), "×10万")
        XCTAssertEqual(AggregatePresentation.countLabel(350_640), "×35.1万")
        XCTAssertEqual(AggregatePresentation.countLabel(100_000_000), "×1億")
    }

    func testHomeLifetimeCoreMakesGuaranteedProgressVisibleAtEveryScale() {
        XCTAssertNil(
            JarLifetimeCorePresentation.state(
                totalPebbleCount: 0,
                projectionIsLowerBound: false
            )
        )

        let first = try! XCTUnwrap(JarLifetimeCorePresentation.state(
            totalPebbleCount: 1,
            projectionIsLowerBound: false
        ))
        XCTAssertEqual(first.coreLevel, 1)
        XCTAssertEqual(first.title, "結晶の芽")
        XCTAssertEqual(first.countLabel, "1粒")
        XCTAssertEqual(first.litOrbitSlotCount, 1)
        XCTAssertEqual(first.nextFusionLabel, "次の結晶まであと9粒")
        XCTAssertEqual(first.progressLabel, "×10へ 1/10")
        XCTAssertEqual(first.prismDiameterFactor, 0.20, accuracy: 0.0001)

        let ninth = try! XCTUnwrap(JarLifetimeCorePresentation.state(
            totalPebbleCount: 9,
            projectionIsLowerBound: false
        ))
        XCTAssertGreaterThan(ninth.prismDiameterFactor, first.prismDiameterFactor)
        XCTAssertEqual(ninth.prismDiameterFactor, 0.235, accuracy: 0.0001)

        let firstCrystal = try! XCTUnwrap(JarLifetimeCorePresentation.state(
            totalPebbleCount: 10,
            projectionIsLowerBound: false
        ))
        XCTAssertEqual(firstCrystal.title, "時間の核")
        XCTAssertEqual(firstCrystal.countLabel, "10粒")
        XCTAssertEqual(firstCrystal.litOrbitSlotCount, 1)
        XCTAssertEqual(firstCrystal.nextFusionLabel, "次の結晶まであと10粒")
        XCTAssertEqual(firstCrystal.progressLabel, "×100へ 1/10")
        XCTAssertGreaterThan(firstCrystal.prismDiameterFactor, ninth.prismDiameterFactor)

        let fortyYears = try! XCTUnwrap(JarLifetimeCorePresentation.state(
            totalPebbleCount: 350_640,
            projectionIsLowerBound: false
        ))
        XCTAssertEqual(fortyYears.coreLevel, 5)
        XCTAssertEqual(fortyYears.title, "時間の核")
        XCTAssertEqual(fortyYears.countLabel, "35.1万粒")
        XCTAssertEqual(fortyYears.litOrbitSlotCount, 4)
        XCTAssertEqual(fortyYears.nextFusionLabel, "次の結晶まであと10粒")
        XCTAssertEqual(fortyYears.progressLabel, "×100へ 4/10")
        XCTAssertGreaterThan(fortyYears.visibleHaloRingCount, first.visibleHaloRingCount)
        XCTAssertGreaterThan(fortyYears.prismDiameterFactor, firstCrystal.prismDiameterFactor)
        XCTAssertEqual(fortyYears.prismDiameterFactor, 0.51, accuracy: 0.0001)
    }

    func testHomeLifetimeCoreKeepsProximalAndDurableFusionProgressTogether() {
        let cases: [(count: Int, slot: Int, durable: String, proximal: String)] = [
            (10, 1, "×100へ 1/10", "次の結晶まであと10粒"),
            (11, 1, "×100へ 1/10", "次の結晶まであと9粒"),
            (19, 1, "×100へ 1/10", "次の結晶まであと1粒"),
            (20, 2, "×100へ 2/10", "次の結晶まであと10粒"),
            (99, 9, "×100へ 9/10", "あと1粒で2段融合"),
            (100, 1, "×1千へ 1/10", "次の結晶まであと10粒")
        ]

        for item in cases {
            let state = try! XCTUnwrap(JarLifetimeCorePresentation.state(
                totalPebbleCount: item.count,
                projectionIsLowerBound: false
            ))
            XCTAssertEqual(state.litOrbitSlotCount, item.slot, "count=\(item.count)")
            XCTAssertEqual(state.progressLabel, item.durable, "count=\(item.count)")
            XCTAssertEqual(state.nextFusionLabel, item.proximal, "count=\(item.count)")
        }
    }

    func testJarAccumulationPresenceCoversEmptyFirstParticleAndLongTermStates() {
        let empty = JarAccumulationPresencePresentation.state(totalGrams: 0)
        XCTAssertFalse(empty.isVisible)
        XCTAssertEqual(empty.presenceFraction, 0)
        XCTAssertEqual(empty.fieldDiameterFactor, 0)
        XCTAssertEqual(empty.shelfHeightFactor, 0)
        XCTAssertEqual(empty.fieldOpacity, 0)
        XCTAssertEqual(empty.milestoneProgressFraction, 0)
        XCTAssertEqual(empty.nextMilestoneGrams, 2_500)
        XCTAssertNil(empty.lastCompletedMilestoneGrams)
        XCTAssertEqual(empty.completedMilestoneCount, 0)
        XCTAssertEqual(empty.visibleMilestoneTraceCount, 0)
        XCTAssertFalse(empty.isMilestoneBoundary)
        XCTAssertEqual(
            JarAccumulationPresencePresentation.state(totalGrams: -1),
            empty
        )

        let firstMeasuredParticle = JarAccumulationPresencePresentation.state(
            totalGrams: Constants.Mass.measuredPebbleGrams
        )
        XCTAssertTrue(firstMeasuredParticle.isVisible)
        XCTAssertEqual(firstMeasuredParticle.presenceFraction, 0.18, accuracy: 0.000_001)
        XCTAssertEqual(firstMeasuredParticle.fieldDiameterFactor, 0.848, accuracy: 0.000_001)
        XCTAssertEqual(firstMeasuredParticle.shelfHeightFactor, 0.1144, accuracy: 0.000_001)
        XCTAssertEqual(firstMeasuredParticle.fieldOpacity, 0.5448, accuracy: 0.000_001)
        XCTAssertEqual(firstMeasuredParticle.milestoneProgressFraction, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(firstMeasuredParticle.nextMilestoneGrams, 2_500)
        XCTAssertEqual(firstMeasuredParticle.completedMilestoneCount, 0)

        let fortyYears = JarAccumulationPresencePresentation.state(
            totalGrams: 350_640 * Constants.Mass.measuredPebbleGrams
        )
        XCTAssertGreaterThan(fortyYears.presenceFraction, 0.90)
        XCTAssertLessThan(fortyYears.presenceFraction, 1)
        XCTAssertGreaterThan(
            fortyYears.fieldDiameterFactor,
            firstMeasuredParticle.fieldDiameterFactor
        )

        let saturated = JarAccumulationPresencePresentation.state(
            totalGrams: JarAccumulationPresencePresentation.saturationGrams
        )
        XCTAssertEqual(saturated.presenceFraction, 1, accuracy: 0.000_001)
        XCTAssertEqual(saturated.fieldDiameterFactor, 1.34, accuracy: 0.000_001)
        XCTAssertEqual(saturated.shelfHeightFactor, 0.18, accuracy: 0.000_001)
        XCTAssertEqual(saturated.fieldOpacity, 0.84, accuracy: 0.000_001)
        XCTAssertTrue(saturated.isMilestoneBoundary)
        XCTAssertEqual(saturated.milestoneProgressFraction, 1, accuracy: 0.000_001)
        XCTAssertEqual(saturated.lastCompletedMilestoneGrams, 250_000_000)
        XCTAssertEqual(saturated.nextMilestoneGrams, 2_500_000_000)
        XCTAssertEqual(saturated.completedMilestoneCount, 6)
        XCTAssertEqual(saturated.visibleMilestoneTraceCount, 6)
    }

    func testJarAccumulationBottleFillRepeatsEveryFixedCycleAndCarriesOverflow() {
        let beforeFirstCycle = JarAccumulationPresencePresentation.state(
            totalGrams: 2_499
        )
        XCTAssertEqual(beforeFirstCycle.completedCycleCount, 0)
        XCTAssertEqual(
            beforeFirstCycle.cycleProgressFraction,
            2_499.0 / 2_500.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(beforeFirstCycle.nextCycleBoundaryGrams, 2_500)
        XCTAssertNil(beforeFirstCycle.lastCompletedCycleBoundaryGrams)
        XCTAssertFalse(beforeFirstCycle.isCycleBoundary)

        let firstCycle = JarAccumulationPresencePresentation.state(totalGrams: 2_500)
        XCTAssertEqual(firstCycle.cycleProgressFraction, 1, accuracy: 0.000_001)
        XCTAssertEqual(firstCycle.completedCycleCount, 1)
        XCTAssertEqual(firstCycle.lastCompletedCycleBoundaryGrams, 2_500)
        XCTAssertEqual(firstCycle.nextCycleBoundaryGrams, 5_000)
        XCTAssertTrue(firstCycle.isCycleBoundary)
        XCTAssertTrue(firstCycle.isMajorMilestoneBoundary)

        let overflow = JarAccumulationPresencePresentation.state(totalGrams: 2_600)
        XCTAssertEqual(overflow.cycleProgressFraction, 0.04, accuracy: 0.000_001)
        XCTAssertEqual(overflow.completedCycleCount, 1)
        XCTAssertEqual(overflow.lastCompletedCycleBoundaryGrams, 2_500)
        XCTAssertEqual(overflow.nextCycleBoundaryGrams, 5_000)
        XCTAssertFalse(overflow.isCycleBoundary)
        XCTAssertEqual(
            overflow.majorMilestoneProgressFraction,
            0.104,
            accuracy: 0.000_001
        )

        let secondCycle = JarAccumulationPresencePresentation.state(totalGrams: 5_000)
        XCTAssertEqual(secondCycle.cycleProgressFraction, 1, accuracy: 0.000_001)
        XCTAssertEqual(secondCycle.completedCycleCount, 2)
        XCTAssertEqual(secondCycle.nextCycleBoundaryGrams, 7_500)
        XCTAssertTrue(secondCycle.isCycleBoundary)
        XCTAssertFalse(secondCycle.isMajorMilestoneBoundary)
        XCTAssertEqual(secondCycle.completedMajorMilestoneCount, 1)
        XCTAssertEqual(
            secondCycle.majorMilestoneProgressFraction,
            0.2,
            accuracy: 0.000_001
        )

        XCTAssertEqual(
            JarAccumulationPresencePresentation.cycleBeat(
                previousTotalGrams: 2_499,
                currentTotalGrams: 2_600
            ),
            JarAccumulationCycleBeat(
                cycleBoundaryGrams: 2_500,
                completedCycleCount: 1,
                crossedCycleCount: 1
            )
        )
        let overflowBeat = try! XCTUnwrap(
            JarAccumulationPresencePresentation.cycleBeat(
                previousTotalGrams: 2_499,
                currentTotalGrams: 2_600
            )
        )
        let crossingField = JarAccumulationLightFieldPresentation.state(
            presence: overflow,
            cycleBeat: overflowBeat
        )
        XCTAssertEqual(
            crossingField.activeCycleFillFraction,
            0.04,
            accuracy: 0.000_001
        )
        XCTAssertEqual(crossingField.completionOverlayFillFraction, 1)
        XCTAssertNil(JarAccumulationLightFieldPresentation.state(
            presence: overflow,
            cycleBeat: nil
        ).completionOverlayFillFraction)

        XCTAssertEqual(
            JarAccumulationPresencePresentation.cycleBeat(
                previousTotalGrams: 2_499,
                currentTotalGrams: 7_600
            ),
            JarAccumulationCycleBeat(
                cycleBoundaryGrams: 7_500,
                completedCycleCount: 3,
                crossedCycleCount: 3
            )
        )
        XCTAssertNil(JarAccumulationPresencePresentation.cycleBeat(
            previousTotalGrams: 2_500,
            currentTotalGrams: 2_501
        ))
    }

    func testJarAccumulationCycleCountNeverRetreatsAtLongTermAndIntegerLimits() {
        let samples = [
            0, 1, 2_499, 2_500, 2_501, 5_000,
            87_660_000, 250_000_000, Int.max
        ]
        var previousCompletedCycleCount = 0
        for grams in samples {
            let state = JarAccumulationPresencePresentation.state(totalGrams: grams)
            XCTAssertGreaterThanOrEqual(
                state.completedCycleCount,
                previousCompletedCycleCount,
                "grams=\(grams)"
            )
            XCTAssertGreaterThanOrEqual(state.cycleProgressFraction, 0)
            XCTAssertLessThanOrEqual(state.cycleProgressFraction, 1)
            previousCompletedCycleCount = state.completedCycleCount
        }

        let fortyYears = JarAccumulationPresencePresentation.state(
            totalGrams: 87_660_000
        )
        XCTAssertEqual(fortyYears.completedCycleCount, 35_064)
        XCTAssertEqual(fortyYears.cycleProgressFraction, 1, accuracy: 0.000_001)
        XCTAssertEqual(fortyYears.completedMajorMilestoneCount, 5)
        XCTAssertEqual(fortyYears.nextMajorMilestoneGrams, 250_000_000)

        let integerLimit = JarAccumulationPresencePresentation.state(
            totalGrams: Int.max
        )
        XCTAssertNil(integerLimit.nextCycleBoundaryGrams)
        XCTAssertGreaterThan(integerLimit.completedCycleCount, fortyYears.completedCycleCount)
    }

    func testPresenceLayoutKeepsFullHeightFieldButSuppressesCoreGlowAndMovesTrace() {
        let withoutCore = JarAccumulationPresenceLayoutPresentation.state(
            showsLifetimeCore: false
        )
        let withCore = JarAccumulationPresenceLayoutPresentation.state(
            showsLifetimeCore: true
        )

        XCTAssertEqual(withoutCore.centerGlowOpacityScale, 1)
        XCTAssertLessThan(withCore.centerGlowOpacityScale, 0.25)
        XCTAssertEqual(withoutCore.traceBandYFraction, 0.86, accuracy: 0.000_001)
        XCTAssertEqual(withCore.traceBandYFraction, 0.075, accuracy: 0.000_001)
        XCTAssertLessThan(withCore.traceBandYFraction, withoutCore.traceBandYFraction)
    }

    func testPresenceAndLifetimeCoreShareExactMajorMilestoneSnapshot() {
        let exactMilestones = [2_500, 25_000, 250_000]

        for (index, grams) in exactMilestones.enumerated() {
            let snapshot = JarAccumulationPresencePresentation.effortSnapshot(
                totalGrams: grams
            )
            let presence = JarAccumulationPresencePresentation.state(
                totalGrams: grams,
                effortSnapshot: snapshot
            )
            let core = try! XCTUnwrap(JarLifetimeCorePresentation.state(
                totalPebbleCount: max(1, grams / Constants.Mass.measuredPebbleGrams),
                totalGrams: grams,
                projectionIsLowerBound: false,
                effortSnapshot: snapshot
            ))

            XCTAssertNil(
                snapshot.crossedMilestoneGrams,
                "A static exact state must not claim a newly observed event"
            )
            XCTAssertEqual(snapshot.displayedTargetLevel, index + 1)
            XCTAssertEqual(snapshot.displayedTargetGrams, grams)
            XCTAssertEqual(snapshot.displayedProgressGrams, grams)
            XCTAssertEqual(snapshot.progressFraction, 1, accuracy: 0.000_001)
            XCTAssertEqual(snapshot.nextTargetGrams, grams * 10)
            XCTAssertTrue(presence.isCycleBoundary)
            XCTAssertTrue(presence.isMajorMilestoneBoundary)
            XCTAssertEqual(
                JarAccumulationLightFieldPresentation.state(
                    presence: presence,
                    cycleBeat: nil
                ).activeCycleFillFraction,
                1,
                accuracy: 0.000_001
            )
            XCTAssertEqual(
                presence.majorMilestoneProgressFraction,
                snapshot.progressFraction,
                accuracy: 0.000_001
            )
            XCTAssertEqual(core.litOrbitSlotCount, 10)
            XCTAssertEqual(
                core.progressLabel,
                "時間 \(EffortProgressPresentation.formattedDuration(grams: grams)) / \(EffortProgressPresentation.formattedDuration(grams: grams))"
            )
            XCTAssertEqual(
                core.nextFusionLabel,
                "次の核：\(EffortProgressPresentation.formattedDuration(grams: grams * 10))"
            )
            XCTAssertFalse(core.nextFusionLabel?.contains("あと0分") ?? true)
        }
    }

    func testJarAccumulationPresenceIsMassOnlyBoundedAndMonotonic() {
        let samples = [
            1, 10, 100, 249, 250, 251,
            2_500, 25_000, 250_000, 2_500_000, 25_000_000,
            JarAccumulationPresencePresentation.saturationGrams,
            1_000_000_000,
            Int.max
        ]
        var previous = JarAccumulationPresencePresentation.state(totalGrams: 0)
        for grams in samples {
            let current = JarAccumulationPresencePresentation.state(totalGrams: grams)
            XCTAssertGreaterThanOrEqual(
                current.presenceFraction,
                previous.presenceFraction,
                "grams=\(grams)"
            )
            XCTAssertGreaterThanOrEqual(
                current.fieldDiameterFactor,
                previous.fieldDiameterFactor,
                "grams=\(grams)"
            )
            XCTAssertLessThanOrEqual(current.presenceFraction, 1, "grams=\(grams)")
            XCTAssertLessThanOrEqual(current.fieldDiameterFactor, 1.34, "grams=\(grams)")
            XCTAssertLessThanOrEqual(current.shelfHeightFactor, 0.18, "grams=\(grams)")
            XCTAssertLessThanOrEqual(current.fieldOpacity, 0.84, "grams=\(grams)")
            previous = current
        }

        // The renderer never receives body count. These names model the
        // carry boundary explicitly: identical stored mass must produce the
        // same background whether SpriteKit currently shows 45 bodies or one.
        let carriedMass = 45 * Constants.Mass.measuredPebbleGrams
        let fortyFiveMovableBodies = JarAccumulationPresencePresentation.state(
            totalGrams: carriedMass
        )
        let oneMovableAggregate = JarAccumulationPresencePresentation.state(
            totalGrams: carriedMass
        )
        XCTAssertEqual(fortyFiveMovableBodies, oneMovableAggregate)
    }

    func testJarAccumulationMilestoneReachesFullOnceAndRetainsItsTrace() {
        let before = JarAccumulationPresencePresentation.state(totalGrams: 2_499)
        XCTAssertFalse(before.isMilestoneBoundary)
        XCTAssertEqual(before.completedMilestoneCount, 0)
        XCTAssertEqual(before.visibleMilestoneTraceCount, 0)
        XCTAssertGreaterThan(before.milestoneProgressFraction, 0.99)
        XCTAssertLessThan(before.milestoneProgressFraction, 1)

        let complete = JarAccumulationPresencePresentation.state(totalGrams: 2_500)
        XCTAssertTrue(complete.isMilestoneBoundary)
        XCTAssertEqual(complete.milestoneProgressFraction, 1, accuracy: 0.000_001)
        XCTAssertEqual(complete.lastCompletedMilestoneGrams, 2_500)
        XCTAssertEqual(complete.nextMilestoneGrams, 25_000)
        XCTAssertEqual(complete.completedMilestoneCount, 1)
        XCTAssertEqual(complete.visibleMilestoneTraceCount, 1)

        let after = JarAccumulationPresencePresentation.state(totalGrams: 2_501)
        XCTAssertFalse(after.isMilestoneBoundary)
        XCTAssertEqual(after.completedMilestoneCount, 1)
        XCTAssertEqual(after.visibleMilestoneTraceCount, 1)
        XCTAssertEqual(after.lastCompletedMilestoneGrams, 2_500)
        XCTAssertGreaterThan(after.presenceFraction, complete.presenceFraction)
        XCTAssertGreaterThan(after.fieldDiameterFactor, complete.fieldDiameterFactor)
        XCTAssertGreaterThan(after.milestoneProgressFraction, 0.1)
        XCTAssertLessThan(after.milestoneProgressFraction, 0.11)

        XCTAssertEqual(
            JarAccumulationPresencePresentation.milestoneBeat(
                previousTotalGrams: 2_499,
                currentTotalGrams: 2_500
            ),
            JarAccumulationMilestoneBeat(
                milestoneGrams: 2_500,
                completedMilestoneCount: 1,
                crossedMilestoneCount: 1
            )
        )
        XCTAssertEqual(
            JarAccumulationPresencePresentation.milestoneBeat(
                previousTotalGrams: 2_499,
                currentTotalGrams: 2_501
            )?.milestoneGrams,
            2_500
        )
        XCTAssertNil(JarAccumulationPresencePresentation.milestoneBeat(
            previousTotalGrams: 2_500,
            currentTotalGrams: 2_501
        ))
        XCTAssertNil(JarAccumulationPresencePresentation.milestoneBeat(
            previousTotalGrams: 2_500,
            currentTotalGrams: 2_500
        ))

        let skippedTwoThresholds = JarAccumulationPresencePresentation.milestoneBeat(
            previousTotalGrams: 2_499,
            currentTotalGrams: 25_001
        )
        XCTAssertEqual(skippedTwoThresholds?.milestoneGrams, 25_000)
        XCTAssertEqual(skippedTwoThresholds?.completedMilestoneCount, 2)
        XCTAssertEqual(skippedTwoThresholds?.crossedMilestoneCount, 2)
    }

    func testHomeOpticalCoreIsBornOnlyAfterFirstRealFusion() {
        XCTAssertFalse(JarLifetimeCorePresentation.shouldShowCore(totalPebbleCount: -1))
        XCTAssertFalse(JarLifetimeCorePresentation.shouldShowCore(totalPebbleCount: 0))
        XCTAssertFalse(JarLifetimeCorePresentation.shouldShowCore(totalPebbleCount: 1))
        XCTAssertFalse(JarLifetimeCorePresentation.shouldShowCore(totalPebbleCount: 9))
        XCTAssertTrue(JarLifetimeCorePresentation.shouldShowCore(totalPebbleCount: 10))
        XCTAssertTrue(JarLifetimeCorePresentation.shouldShowCore(totalPebbleCount: 350_640))
    }

    func testHomeLifetimeCoreNeverInventsDecimalProgressDuringPartialSync() {
        let state = try! XCTUnwrap(JarLifetimeCorePresentation.state(
            totalPebbleCount: 350_640,
            projectionIsLowerBound: true
        ))

        XCTAssertNil(state.litOrbitSlotCount)
        XCTAssertNil(state.nextFusionLabel)
        XCTAssertEqual(state.progressLabel, "結晶を同期中")
        XCTAssertEqual(state.countLabel, "35.1万粒以上")
    }

    func testAggregateImportanceIsVisuallyMonotonicWithoutGrowingPhysicsForever() {
        var previousGlow: CGFloat = 0
        var previousFacets = 0
        var previousRings = 0

        for level in 1...8 {
            let glow = AggregatePresentation.glowScale(level: level, containsRare: false)
            let facets = AggregatePresentation.facetCount(level: level)
            let rings = AggregatePresentation.ringCount(level: level)
            XCTAssertGreaterThanOrEqual(glow, previousGlow)
            XCTAssertGreaterThanOrEqual(facets, previousFacets)
            XCTAssertGreaterThanOrEqual(rings, previousRings)
            previousGlow = glow
            previousFacets = facets
            previousRings = rings
        }

        XCTAssertGreaterThan(
            AggregatePresentation.glowScale(level: 5, containsRare: false),
            AggregatePresentation.glowScale(level: 1, containsRare: false)
        )
        XCTAssertLessThan(
            AggregatePresentation.coreBlendAmount(level: 5),
            AggregatePresentation.coreBlendAmount(level: 1)
        )
        XCTAssertLessThanOrEqual(
            StrataMath.aggregateRadius(level: 99),
            Double(Constants.Jar.aggregateMaximumRadius)
        )
    }

    func testWeeklyProgressCountsCalendarContextWithoutAStreakPenalty() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ja_JP")
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4

        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour
            )))
        }

        let reference = try date(2026, 8, 30)
        let completions = [
            try date(2026, 8, 23), // Previous week.
            try date(2026, 8, 24),
            try date(2026, 8, 27), // Two rest days do not erase Monday.
            try date(2026, 8, 30, 23),
            try date(2026, 8, 31)  // Next week.
        ]

        XCTAssertEqual(
            WeeklyProgressPolicy.completionCount(
                dates: completions,
                at: reference,
                calendar: calendar
            ),
            3
        )
    }

    func testWeeklySummaryValuesMeasuredMassNotManualTapCount() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let records = [
            AccumulationRecord(
                id: UUID(),
                date: base,
                subjectName: "英語",
                colorHex: "#2457C5",
                grams: 250,
                isMeasured: true,
                isBaked: false
            ),
            AccumulationRecord(
                id: UUID(),
                date: base.addingTimeInterval(1),
                subjectName: "資格",
                colorHex: "#E6A53A",
                grams: 600,
                isMeasured: true,
                isBaked: false
            ),
            AccumulationRecord(
                id: UUID(),
                date: base.addingTimeInterval(2),
                subjectName: "手動",
                colorHex: "#FF00FF",
                grams: Int.max,
                isMeasured: false,
                isBaked: false
            )
        ]

        let summary = AccumulationWeeklyPolicy.summary(records: records)
        XCTAssertEqual(summary.measuredCompletionCount, 2)
        XCTAssertEqual(summary.measuredGrams, 850)
        XCTAssertEqual(summary.dominantColorHex, "#E6A53A")

        let saturated = AccumulationWeeklyPolicy.summary(records: [
            AccumulationRecord(
                id: UUID(),
                date: base,
                subjectName: "長期",
                colorHex: "#2457C5",
                grams: Int.max,
                isMeasured: true,
                isBaked: false
            ),
            AccumulationRecord(
                id: UUID(),
                date: base.addingTimeInterval(1),
                subjectName: "長期",
                colorHex: "#2457C5",
                grams: 250,
                isMeasured: true,
                isBaked: false
            )
        ])
        XCTAssertEqual(saturated.measuredGrams, Int.max)
    }

    func testCrystalFacetsAreGuaranteedAndSafelyCapped() {
        XCTAssertEqual(WeeklyProgressPolicy.litFacetCount(for: 0), 0)
        XCTAssertEqual(WeeklyProgressPolicy.litFacetCount(for: 1), 1)
        XCTAssertEqual(WeeklyProgressPolicy.litFacetCount(for: 12), 12)
        XCTAssertEqual(WeeklyProgressPolicy.litFacetCount(for: 400), 12)
        XCTAssertEqual(WeeklyProgressPolicy.litFacetCount(for: -10), 0)
    }

    func testWeeklyCrystalKeepsGrowingAfterTheFirstTwelveFacets() {
        XCTAssertEqual(
            WeeklyProgressPolicy.growthState(for: 0),
            .init(
                outerLitFacetCount: 0,
                activeLayerLitFacetCount: 0,
                completedLayerCount: 0,
                visibleRingCount: 0
            )
        )
        XCTAssertEqual(WeeklyProgressPolicy.growthState(for: 12).outerLitFacetCount, 12)
        XCTAssertEqual(WeeklyProgressPolicy.growthState(for: 12).completedLayerCount, 0)
        XCTAssertEqual(WeeklyProgressPolicy.growthState(for: 13).activeLayerLitFacetCount, 1)
        XCTAssertEqual(WeeklyProgressPolicy.growthState(for: 13).visibleRingCount, 1)
        XCTAssertEqual(WeeklyProgressPolicy.growthState(for: 24).activeLayerLitFacetCount, 12)
        XCTAssertEqual(WeeklyProgressPolicy.growthState(for: 24).completedLayerCount, 1)
        XCTAssertEqual(WeeklyProgressPolicy.growthState(for: 25).activeLayerLitFacetCount, 1)
        XCTAssertEqual(WeeklyProgressPolicy.growthState(for: 25).completedLayerCount, 2)
        XCTAssertEqual(WeeklyProgressPolicy.growthState(for: 25).visibleRingCount, 2)
    }

    func testAggregateMorphologyDoesNotPlateauAcrossTheFirstEightLevels() {
        let states = (1 ... 8).map { level in
            "\(AggregatePresentation.title(level: level))|"
                + "\(AggregatePresentation.ringCount(level: level))|"
                + "\(AggregatePresentation.facetCount(level: level))|"
                + "\(AggregatePresentation.glowScale(level: level, containsRare: false))"
        }
        XCTAssertEqual(Set(states).count, states.count)
        XCTAssertEqual(AggregatePresentation.title(level: 5), "軌道核")
        XCTAssertEqual(AggregatePresentation.title(level: 8), "永続核")
        XCTAssertGreaterThan(AggregatePresentation.ringCount(level: 5), 4)
        XCTAssertGreaterThan(AggregatePresentation.facetCount(level: 7), 14)
    }

    func testOverviewStartsAtTheDistanceThatContainsMeaningfulProgress() {
        XCTAssertEqual(
            OverviewInitialLensPolicy.selection(
                hasInitialCluster: false,
                currentWeekMeasuredCount: 1,
                currentRecordCount: 0,
                clusterCount: 18,
                lifetimePebbleCount: 350_640
            ),
            .now,
            "Fresh measured work should keep the tactile weekly view first"
        )
        XCTAssertEqual(
            OverviewInitialLensPolicy.selection(
                hasInitialCluster: false,
                currentWeekMeasuredCount: 0,
                currentRecordCount: 0,
                clusterCount: 18,
                lifetimePebbleCount: 350_640
            ),
            .crystals,
            "A quiet forty-year account must not be introduced as zero progress"
        )
        XCTAssertEqual(
            OverviewInitialLensPolicy.selection(
                hasInitialCluster: true,
                currentWeekMeasuredCount: 9,
                currentRecordCount: 9,
                clusterCount: 1,
                lifetimePebbleCount: 19
            ),
            .crystals,
            "Opening a specific aggregate must reveal that aggregate"
        )
        XCTAssertEqual(
            OverviewInitialLensPolicy.selection(
                hasInitialCluster: false,
                currentWeekMeasuredCount: 0,
                currentRecordCount: 0,
                clusterCount: 0,
                lifetimePebbleCount: 0
            ),
            .now,
            "A genuinely empty account should retain its first-action cue"
        )
    }

    func testOverviewLayoutPolicyPreservesCompactOverviewAtStandardSizes() {
        let policy = AccumulationOverviewLayoutPolicy.resolve(isAccessibilitySize: false)

        XCTAssertFalse(policy.usesMenuLensPicker)
        XCTAssertFalse(policy.stacksSummaryCards)
        XCTAssertEqual(policy.shelfColumnCount, 2)
    }

    func testOverviewLayoutPolicyExpandsOverviewAtAccessibilitySizes() {
        let policy = AccumulationOverviewLayoutPolicy.resolve(isAccessibilitySize: true)

        XCTAssertTrue(policy.usesMenuLensPicker)
        XCTAssertTrue(policy.stacksSummaryCards)
        XCTAssertEqual(policy.shelfColumnCount, 1)
    }

    func testRewardBridgeKeepsCompletedFusionAndLongTermContextVisible() {
        let one = FusionRewardBridgePresentation.state(totalPebbleCount: 1)
        XCTAssertEqual(one.progressLabel, "×10へ 1/10")
        XCTAssertEqual(one.litSlotCount, 1)
        XCTAssertEqual(one.nextStepLabel, "次のまとまりまで、あと9粒")
        XCTAssertFalse(one.isFusionComplete)

        let nine = FusionRewardBridgePresentation.state(totalPebbleCount: 9)
        XCTAssertEqual(nine.progressLabel, "×10へ 9/10")
        XCTAssertEqual(nine.litSlotCount, 9)
        XCTAssertEqual(nine.nextStepLabel, "次のまとまりまで、あと1粒")
        XCTAssertFalse(nine.isFusionComplete)

        let ten = FusionRewardBridgePresentation.state(totalPebbleCount: 10)
        XCTAssertEqual(ten.destinationLabel, "×10")
        XCTAssertEqual(ten.progressLabel, "×10完成 10/10")
        XCTAssertEqual(ten.litSlotCount, 10)
        XCTAssertTrue(ten.isFusionComplete)

        let eleven = FusionRewardBridgePresentation.state(totalPebbleCount: 11)
        XCTAssertEqual(eleven.progressLabel, "×10へ 1/10")
        XCTAssertEqual(eleven.litSlotCount, 1)
        XCTAssertFalse(eleven.isFusionComplete)
        XCTAssertEqual(eleven.longTermContextLabel, "長期：×100へ 1/10")

        let nineteen = FusionRewardBridgePresentation.state(totalPebbleCount: 19)
        XCTAssertEqual(nineteen.progressLabel, "×10へ 9/10")
        XCTAssertEqual(nineteen.litSlotCount, 9)
        XCTAssertFalse(nineteen.isFusionComplete)

        let ninetyNine = FusionRewardBridgePresentation.state(totalPebbleCount: 99)
        XCTAssertEqual(ninetyNine.progressLabel, "×10へ 9/10")
        XCTAssertEqual(ninetyNine.litSlotCount, 9)
        XCTAssertFalse(ninetyNine.isFusionComplete)
        XCTAssertEqual(ninetyNine.nextStepLabel, "あと1粒で2段融合")

        let oneHundred = FusionRewardBridgePresentation.state(totalPebbleCount: 100)
        XCTAssertEqual(oneHundred.destinationLabel, "×100")
        XCTAssertEqual(oneHundred.progressLabel, "×100完成 10/10")
        XCTAssertEqual(oneHundred.litSlotCount, 10)
        XCTAssertTrue(oneHundred.isFusionComplete)
        XCTAssertEqual(oneHundred.longTermContextLabel, "次は×1千へ 1/10")
    }

    func testRewardBridgeDoesNotInferDecimalPositionFromPartialSyncLowerBound() {
        let ambiguousLowerBound = FusionRewardBridgePresentation.state(
            totalPebbleCount: 10
        )
        let display = FusionRewardBridgePresentation.display(
            state: ambiguousLowerBound,
            projectionIsLowerBound: true
        )

        XCTAssertEqual(display.eyebrow, "CRYSTAL SYNC")
        XCTAssertEqual(display.progressLabel, "今回 +1粒")
        XCTAssertEqual(display.nextStepLabel, "結晶進捗を同期中")
        XCTAssertNil(display.litSlotCount)
        XCTAssertFalse(display.accessibilityLabel.contains("10/10"))
        XCTAssertFalse(display.accessibilityLabel.contains("×10"))

        let exact = FusionRewardBridgePresentation.display(
            state: ambiguousLowerBound,
            projectionIsLowerBound: false
        )
        XCTAssertEqual(exact.progressLabel, "×10完成 10/10")
        XCTAssertEqual(exact.litSlotCount, 10)
    }

    func testFusionOrbitUsesExactDecimalSourcesAndCompletedDestination() {
        let one = FusionOrbitStagePresentation.bridge(
            state: FusionRewardBridgePresentation.state(totalPebbleCount: 1),
            projectionIsLowerBound: false
        )
        XCTAssertEqual(one.slotCount, 10)
        XCTAssertEqual(one.litSlotCount, 1)
        XCTAssertEqual(one.latestLitSlotIndex, 0)
        XCTAssertEqual(one.progressFraction ?? -1, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(one.destinationLevel, 1)
        XCTAssertEqual(one.destinationPebbleCount, 10)
        XCTAssertFalse(one.isFusionComplete)
        XCTAssertFalse(one.destinationMaterialized)

        let nine = FusionOrbitStagePresentation.bridge(
            state: FusionRewardBridgePresentation.state(totalPebbleCount: 9),
            projectionIsLowerBound: false
        )
        XCTAssertFalse(nine.isFusionComplete)
        XCTAssertFalse(nine.destinationMaterialized)

        let ten = FusionOrbitStagePresentation.bridge(
            state: FusionRewardBridgePresentation.state(totalPebbleCount: 10),
            projectionIsLowerBound: false
        )
        XCTAssertEqual(ten.litSlotCount, 10)
        XCTAssertEqual(ten.latestLitSlotIndex, 9)
        XCTAssertEqual(ten.progressFraction ?? -1, 1, accuracy: 0.000_001)
        XCTAssertEqual(ten.destinationLevel, 1)
        XCTAssertEqual(ten.destinationPebbleCount, 10)
        XCTAssertTrue(ten.isFusionComplete)
        XCTAssertTrue(ten.destinationMaterialized)

        for count in [11, 19] {
            let incompleteNextSet = FusionOrbitStagePresentation.bridge(
                state: FusionRewardBridgePresentation.state(totalPebbleCount: count),
                projectionIsLowerBound: false
            )
            XCTAssertFalse(incompleteNextSet.isFusionComplete)
            XCTAssertFalse(incompleteNextSet.destinationMaterialized)
        }

        let twenty = FusionOrbitStagePresentation.bridge(
            state: FusionRewardBridgePresentation.state(totalPebbleCount: 20),
            projectionIsLowerBound: false
        )
        XCTAssertTrue(twenty.isFusionComplete)
        XCTAssertTrue(twenty.destinationMaterialized)

        let oneHundred = FusionOrbitStagePresentation.bridge(
            state: FusionRewardBridgePresentation.state(totalPebbleCount: 100),
            projectionIsLowerBound: false
        )
        XCTAssertEqual(oneHundred.destinationLevel, 2)
        XCTAssertEqual(oneHundred.destinationPebbleCount, 100)
        XCTAssertTrue(oneHundred.isFusionComplete)
    }

    func testFusionOrbitNeverDrawsInventedSlotsDuringPartialSync() {
        let lowerBound = FusionOrbitStagePresentation.bridge(
            state: FusionRewardBridgePresentation.state(totalPebbleCount: 10),
            projectionIsLowerBound: true
        )

        XCTAssertNil(lowerBound.litSlotCount)
        XCTAssertNil(lowerBound.latestLitSlotIndex)
        XCTAssertNil(lowerBound.progressFraction)
        XCTAssertFalse(lowerBound.isFusionComplete)
        XCTAssertFalse(lowerBound.destinationMaterialized)
        XCTAssertEqual(lowerBound.destinationPebbleCount, 10)
    }

    func testCompletedAggregateOrbitKeepsLegacyNonDecimalCountsSafe() {
        let state = FusionOrbitStagePresentation.completedAggregate(
            pebbleCount: 48,
            level: nil
        )

        XCTAssertEqual(state.slotCount, 10)
        XCTAssertEqual(state.litSlotCount, 10)
        XCTAssertEqual(state.destinationPebbleCount, 48)
        XCTAssertGreaterThanOrEqual(state.destinationLevel, 1)
        XCTAssertTrue(state.isFusionComplete)
        XCTAssertTrue(state.destinationMaterialized)
    }

    func testLifetimeOrbitUsesDurableDigitWithoutPretendingToCompleteFusion() {
        let fortyYears = FusionOrbitStagePresentation.lifetime(
            totalPebbleCount: 350_640,
            projectionIsLowerBound: false
        )
        XCTAssertEqual(fortyYears.slotCount, 10)
        XCTAssertEqual(fortyYears.litSlotCount, 4)
        XCTAssertEqual(fortyYears.destinationLevel, 5)
        XCTAssertEqual(fortyYears.destinationPebbleCount, 350_640)
        XCTAssertFalse(fortyYears.isFusionComplete)
        XCTAssertTrue(fortyYears.destinationMaterialized)

        let firstNine = FusionOrbitStagePresentation.lifetime(
            totalPebbleCount: 9,
            projectionIsLowerBound: false
        )
        XCTAssertFalse(firstNine.destinationMaterialized)
        let firstCrystal = FusionOrbitStagePresentation.lifetime(
            totalPebbleCount: 10,
            projectionIsLowerBound: false
        )
        XCTAssertTrue(firstCrystal.destinationMaterialized)

        let lowerBound = FusionOrbitStagePresentation.lifetime(
            totalPebbleCount: 350_640,
            projectionIsLowerBound: true
        )
        XCTAssertNil(lowerBound.litSlotCount)
        XCTAssertFalse(lowerBound.isFusionComplete)
        XCTAssertTrue(lowerBound.destinationMaterialized)

        let lowerBoundBeforeFirstFusion = FusionOrbitStagePresentation.lifetime(
            totalPebbleCount: 9,
            projectionIsLowerBound: true
        )
        XCTAssertNil(lowerBoundBeforeFirstFusion.litSlotCount)
        XCTAssertFalse(lowerBoundBeforeFirstFusion.destinationMaterialized)
    }

    func testRestCadenceUsesFocusedMassInsteadOfCompletionCount() throws {
        let suiteName = "TsumibenTests.rest-cadence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let short = Constants.Timer.shortBreakMinutes
        let long = Constants.Timer.longBreakMinutes
        for index in 0 ..< 9 {
            XCTAssertEqual(
                FocusRestCadenceStore.record(
                    sessionID: UUID(),
                    contributionGrams: 100,
                    defaults: defaults
                ),
                short,
                "10分の\(index + 1)回目はまだ100分境界前"
            )
        }
        XCTAssertEqual(
            FocusRestCadenceStore.record(
                sessionID: UUID(),
                contributionGrams: 100,
                defaults: defaults
            ),
            long
        )
        XCTAssertEqual(FocusRestCadenceStore.load(defaults: defaults).creditedGrams, 0)
    }

    func testRestCadenceTreatsEqualFocusedTimeEquallyAndReplaysIdempotently() throws {
        let makeDefaults: () throws -> (UserDefaults, String) = {
            let name = "TsumibenTests.rest-cadence.\(UUID().uuidString)"
            return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
        }
        let (tenMinuteDefaults, tenMinuteName) = try makeDefaults()
        let (twentyFiveDefaults, twentyFiveName) = try makeDefaults()
        let (sixtyMinuteDefaults, sixtyMinuteName) = try makeDefaults()
        defer {
            tenMinuteDefaults.removePersistentDomain(forName: tenMinuteName)
            twentyFiveDefaults.removePersistentDomain(forName: twentyFiveName)
            sixtyMinuteDefaults.removePersistentDomain(forName: sixtyMinuteName)
        }

        for _ in 0 ..< 6 {
            _ = FocusRestCadenceStore.record(
                sessionID: UUID(),
                contributionGrams: 100,
                defaults: tenMinuteDefaults
            )
        }
        for grams in [250, 250, 100] {
            _ = FocusRestCadenceStore.record(
                sessionID: UUID(),
                contributionGrams: grams,
                defaults: twentyFiveDefaults
            )
        }
        let sixtyID = UUID()
        let sixtyBreak = FocusRestCadenceStore.record(
            sessionID: sixtyID,
            contributionGrams: 600,
            defaults: sixtyMinuteDefaults
        )
        XCTAssertEqual(sixtyBreak, Constants.Timer.shortBreakMinutes)
        XCTAssertEqual(
            FocusRestCadenceStore.record(
                sessionID: sixtyID,
                contributionGrams: 600,
                defaults: sixtyMinuteDefaults
            ),
            sixtyBreak
        )

        XCTAssertEqual(FocusRestCadenceStore.load(defaults: tenMinuteDefaults).creditedGrams, 600)
        XCTAssertEqual(FocusRestCadenceStore.load(defaults: twentyFiveDefaults).creditedGrams, 600)
        XCTAssertEqual(FocusRestCadenceStore.load(defaults: sixtyMinuteDefaults).creditedGrams, 600)
    }

    func testRestCadenceKeepsExactRemainderAtIntegerLimit() throws {
        let suiteName = "TsumibenTests.rest-cadence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = FocusRestCadenceStore.record(
            sessionID: UUID(),
            contributionGrams: 600,
            defaults: defaults
        )
        XCTAssertEqual(
            FocusRestCadenceStore.record(
                sessionID: UUID(),
                contributionGrams: Int.max,
                defaults: defaults
            ),
            Constants.Timer.longBreakMinutes
        )
        XCTAssertEqual(
            FocusRestCadenceStore.load(defaults: defaults).creditedGrams,
            (600 + Int.max % FocusRestCadenceStore.longBreakIntervalGrams)
                % FocusRestCadenceStore.longBreakIntervalGrams
        )
    }

    func testReviewRequestRequiresReturnAcrossTimeNotSameDayBurst() {
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(ReviewRequestPolicy.isEarned(
            completionCount: 9,
            firstCompletionDate: first,
            now: first.addingTimeInterval(30 * 24 * 60 * 60)
        ))
        XCTAssertFalse(ReviewRequestPolicy.isEarned(
            completionCount: 100,
            firstCompletionDate: first,
            now: first.addingTimeInterval(6 * 24 * 60 * 60 + 86_399)
        ))
        XCTAssertTrue(ReviewRequestPolicy.isEarned(
            completionCount: 10,
            firstCompletionDate: first,
            now: first.addingTimeInterval(7 * 24 * 60 * 60)
        ))
    }

    func testPendingRewardReceiptStoreRoundTripsDeduplicatesAndRemoves() throws {
        let suiteName = "TsumibenTests.reward-receipts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
        let first = PendingRewardReceipt(
            id: firstID,
            createdAt: Date(timeIntervalSince1970: 1_800_400_000),
            breakMinutes: 5,
            grams: 250,
            subjectName: "資格勉強",
            colorHex: "#5DE0BD",
            weeklyCompletionCount: 10,
            weeklyStudyGrams: 2_500,
            kind: .gold,
            totalPebbleCount: 10,
            projectionIsLowerBound: false
        )
        let duplicateID = PendingRewardReceipt(
            id: firstID,
            createdAt: Date(timeIntervalSince1970: 1_800_400_001),
            breakMinutes: 15,
            grams: 999,
            subjectName: "重複は採用しない",
            colorHex: "#FF0000",
            weeklyCompletionCount: 99,
            kind: .prism,
            totalPebbleCount: 99,
            projectionIsLowerBound: true
        )
        let second = PendingRewardReceipt(
            id: UUID(uuidString: "30000000-0000-4000-8000-000000000002")!,
            createdAt: Date(timeIntervalSince1970: 1_800_400_002),
            breakMinutes: 15,
            grams: 250,
            subjectName: "英語",
            colorHex: "#6CA8FF",
            weeklyCompletionCount: 11,
            kind: .normal,
            totalPebbleCount: 11,
            projectionIsLowerBound: true
        )

        PendingRewardReceiptStore.insert(first, defaults: defaults)
        PendingRewardReceiptStore.insert(duplicateID, defaults: defaults)
        PendingRewardReceiptStore.insert(second, defaults: defaults)
        XCTAssertEqual(PendingRewardReceiptStore.load(defaults: defaults), [first, second])

        PendingRewardReceiptStore.remove(id: first.id, defaults: defaults)
        XCTAssertEqual(PendingRewardReceiptStore.load(defaults: defaults), [second])

        PendingRewardReceiptStore.removeAll(defaults: defaults)
        XCTAssertTrue(PendingRewardReceiptStore.load(defaults: defaults).isEmpty)
        XCTAssertNil(defaults.data(forKey: PendingRewardReceiptStore.defaultsKey))
    }

    func testPendingRewardReceiptDecodesLegacyCountPayloadWithoutMass() throws {
        let receipt = PendingRewardReceipt(
            id: UUID(uuidString: "31000000-0000-4000-8000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            breakMinutes: 5,
            grams: 600,
            subjectName: "数学",
            colorHex: "#123456",
            weeklyCompletionCount: 2,
            weeklyStudyGrams: 850,
            kind: .normal,
            totalPebbleCount: 7,
            totalStudyGrams: 1_850,
            projectionIsLowerBound: false
        )
        let encoded = try JSONEncoder().encode(receipt)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "totalStudyGrams")
        object.removeValue(forKey: "weeklyStudyGrams")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            PendingRewardReceipt.self,
            from: legacyData
        )
        XCTAssertNil(decoded.totalStudyGrams)
        XCTAssertNil(decoded.weeklyStudyGrams)
        XCTAssertEqual(decoded.totalPebbleCount, 7)
        XCTAssertEqual(decoded.grams, 600)

        let current = try JSONDecoder().decode(
            PendingRewardReceipt.self,
            from: encoded
        )
        XCTAssertEqual(current.totalStudyGrams, 1_850)
        XCTAssertEqual(current.weeklyStudyGrams, 850)
    }

    private func makeConstellationNode(_ index: Int) -> EffortConstellationNode {
        EffortConstellationNode(
            id: UUID(uuidString: String(
                format: "20000000-0000-4000-8000-%012X",
                index + 1
            ))!,
            level: index % 5 + 1,
            pebbleCount: Int(pow(10.0, Double(index % 5 + 1))),
            grams: (index + 1) * 250,
            colorHex: index.isMultiple(of: 2) ? "#AA0000" : "#0000AA",
            periodEnd: Date(timeIntervalSince1970: Double(index)),
            containsRare: index.isMultiple(of: 7)
        )
    }
}
