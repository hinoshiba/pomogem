import SpriteKit
import XCTest
@testable import Tsumiben

final class StrataMathTests: XCTestCase {
    func testHeightUsesTotalCrossSectionPackingAndRounding() {
        let radii = [11.5, 11.5, 14, 17]
        let width = 300.0
        let expected = (
            radii.reduce(0) { $0 + Double.pi * $1 * $1 }
                / width
                * Constants.Jar.strataPackingFactor
        ).rounded(.toNearestOrAwayFromZero)

        XCTAssertEqual(
            StrataMath.stratumHeight(pebbleRadii: radii, innerWidth: width),
            expected
        )
        XCTAssertEqual(
            StrataMath.stratumHeight(pebbleRadii: radii, innerWidth: 0),
            0
        )
    }

    func testColorCompositionSumsExactlyToOneAndRoundTripsJSON() throws {
        let colors = [
            Constants.Color.english,
            Constants.Color.english,
            Constants.Color.english,
            Constants.Color.mathematics,
            Constants.Color.science
        ]
        let mix = StrataMath.colorMix(hexColors: colors)

        XCTAssertEqual(mix.reduce(0) { $0 + $1.fraction }, 1, accuracy: 1e-12)
        XCTAssertEqual(mix.first?.hex, Constants.Color.english)
        XCTAssertEqual(try XCTUnwrap(mix.first).fraction, 0.6, accuracy: 1e-12)

        let json = StrataMath.encodeColorMix(mix)
        XCTAssertTrue(json.contains("\"frac\""))
        XCTAssertFalse(json.contains("\"fraction\""))
        XCTAssertEqual(StrataMath.decodeColorMix(json), mix)
    }

    func testBakeSelectsLowestFortyEightAndPreservesMass() throws {
        let pebbles = (0 ..< Constants.Jar.bakeThreshold).map { index in
            StrataPebble(
                y: Double(Constants.Jar.bakeThreshold - index),
                colorHex: index.isMultiple(of: 2)
                    ? Constants.Color.english
                    : Constants.Color.mathematics,
                grams: index.isMultiple(of: 3) ? 600 : 250
            )
        }
        let massBefore = pebbles.reduce(0) { $0 + $1.grams }
        let result = try XCTUnwrap(StrataMath.bake(pebbles: pebbles, innerWidth: 320))

        XCTAssertEqual(result.bakedPebbles.count, Constants.Jar.bakeCount)
        XCTAssertEqual(
            result.remainingPebbles.count,
            Constants.Jar.bakeThreshold - Constants.Jar.bakeCount
        )
        XCTAssertEqual(result.bakedPebbles.map(\.y), result.bakedPebbles.map(\.y).sorted())
        XCTAssertEqual(result.totalGramsAfterBake, massBefore)
        XCTAssertEqual(result.colorMix.reduce(0) { $0 + $1.fraction }, 1, accuracy: 1e-12)
    }

    func testBakeThresholdAccountsForQueuedIncomingBodies() {
        XCTAssertFalse(StrataMath.shouldBake(
            physicalBodyCount: Constants.Jar.bakeThreshold - 1
        ))
        XCTAssertTrue(StrataMath.shouldBake(
            physicalBodyCount: Constants.Jar.bakeThreshold - 1,
            adding: 1
        ))
        XCTAssertNil(StrataMath.bake(
            pebbles: Array(
                repeating: StrataPebble(y: 0, colorHex: Constants.Color.science),
                count: Constants.Jar.bakeThreshold - 1
            ),
            innerWidth: 320
        ))
    }

    func testCapacityUsesCrossSectionInsteadOfRawBodyCount() {
        let normal = Double(Constants.Jar.measuredRadius)
        let large = Double(Constants.Jar.manualOneTwentyRadius)

        XCTAssertEqual(
            StrataMath.capacityUnits(pebbleRadii: Array(repeating: normal, count: 120)),
            120,
            accuracy: 1e-12
        )
        XCTAssertFalse(StrataMath.shouldBake(
            pebbleRadii: Array(repeating: large, count: 54)
        ))
        XCTAssertTrue(StrataMath.shouldBake(
            pebbleRadii: Array(repeating: large, count: 55)
        ))
        XCTAssertTrue(StrataMath.shouldBake(
            pebbleRadii: Array(repeating: normal, count: 119),
            adding: [normal]
        ))
    }

    func testDynamicBakeSelectionLeavesAtMostSeventyTwoCapacityUnits() throws {
        let normal = Double(Constants.Jar.measuredRadius)
        let normalRadii = Array(repeating: normal, count: 120)
        XCTAssertEqual(
            StrataMath.bakeSelectionCount(pebbleRadiiInBakeOrder: normalRadii),
            48
        )

        let large = Double(Constants.Jar.manualOneTwentyRadius)
        let largeRadii = Array(repeating: large, count: 55)
        let selectedCount = StrataMath.bakeSelectionCount(
            pebbleRadiiInBakeOrder: largeRadii
        )
        XCTAssertGreaterThan(selectedCount, 0)
        XCTAssertLessThan(selectedCount, Constants.Jar.bakeCount)
        XCTAssertLessThanOrEqual(
            StrataMath.capacityUnits(
                pebbleRadii: Array(largeRadii.dropFirst(selectedCount))
            ),
            Constants.Jar.postBakeCapacityUnits + 1e-12
        )

        let pebbles = largeRadii.enumerated().map { index, radius in
            StrataPebble(
                y: Double(index),
                radius: radius,
                colorHex: Constants.Color.science
            )
        }
        let result = try XCTUnwrap(
            StrataMath.bake(pebbles: pebbles, innerWidth: 320)
        )
        XCTAssertEqual(result.pebbleCount, selectedCount)
        XCTAssertEqual(
            result.bakedPebbles.map(\.y),
            result.bakedPebbles.map(\.y).sorted()
        )
    }

    func testCapacitySanitizesInvalidRadiiAndBaseline() {
        XCTAssertEqual(
            StrataMath.capacityUnits(pebbleRadii: [-10, 0, 11.5]),
            1,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            StrataMath.capacityUnits(pebbleRadii: [11.5], baselineRadius: 0),
            0
        )
        XCTAssertEqual(
            StrataMath.bakeSelectionCount(
                pebbleRadiiInBakeOrder: Array(repeating: 11.5, count: 119)
            ),
            0
        )
    }

    func testPersistedTotalsRemainUnchangedAfterBake() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let sessions = (0 ..< Constants.Jar.bakeCount).map { index in
            StudySession(
                startAt: start,
                endAt: start.addingTimeInterval(1_500),
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "2026-08-29"
            )
        }
        let beforeMass = StrataMath.totalGrams(sessions: sessions, strata: [])
        let beforeCount = StrataMath.totalPebbleCount(sessions: sessions, strata: [])

        sessions.forEach { $0.isBaked = true }
        let mix = StrataMath.colorMix(
            hexColors: Array(repeating: Constants.Color.english, count: sessions.count)
        )
        let stratum = Stratum(
            pebbleCount: sessions.count,
            heightPt: 32,
            colorMixJSON: StrataMath.encodeColorMix(mix),
            monthLabel: "2026年8月",
            grams: beforeMass
        )

        XCTAssertEqual(StrataMath.totalGrams(sessions: sessions, strata: [stratum]), beforeMass)
        XCTAssertEqual(StrataMath.totalPebbleCount(sessions: sessions, strata: [stratum]), beforeCount)
    }

    func testOrphanBakedSessionStaysVisibleUntilItsStratumArrives() {
        let sessionID = UUID()
        let now = Date(timeIntervalSince1970: 2_000)
        let session = StudySession(
            id: sessionID,
            startAt: now.addingTimeInterval(-1_500),
            endAt: now,
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "2026-08-30",
            isBaked: true
        )

        XCTAssertEqual(StrataMath.totalGrams(sessions: [session], strata: []), 250)
        XCTAssertEqual(StrataMath.totalPebbleCount(sessions: [session], strata: []), 1)

        let stratum = Stratum(
            pebbleCount: 1,
            heightPt: 1,
            colorMixJSON: "[]",
            monthLabel: "2026年8月",
            grams: 250,
            sessionIDs: [sessionID]
        )
        XCTAssertEqual(StrataMath.totalGrams(sessions: [session], strata: [stratum]), 250)
        XCTAssertEqual(StrataMath.totalPebbleCount(sessions: [session], strata: [stratum]), 1)
    }

    func testDuplicateCloudRecordsDoNotDoubleCountStableIDs() {
        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        let first = StudySession(
            id: sessionID,
            startAt: start,
            endAt: start.addingTimeInterval(1_500),
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "2026-08-29"
        )
        let duplicate = StudySession(
            id: sessionID,
            startAt: start,
            endAt: start.addingTimeInterval(1_500),
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "2026-08-29"
        )
        XCTAssertEqual(StrataMath.totalGrams(sessions: [first, duplicate], strata: []), 250)
        XCTAssertEqual(StrataMath.totalPebbleCount(sessions: [first, duplicate], strata: []), 1)

        first.isBaked = true
        duplicate.isBaked = true
        let stratumID = UUID()
        let firstStratum = Stratum(
            id: stratumID,
            pebbleCount: 1,
            heightPt: 1,
            colorMixJSON: "[]",
            monthLabel: "2026年8月",
            grams: 250
        )
        let duplicateStratum = Stratum(
            id: stratumID,
            pebbleCount: 1,
            heightPt: 1,
            colorMixJSON: "[]",
            monthLabel: "2026年8月",
            grams: 250
        )
        XCTAssertEqual(
            StrataMath.totalGrams(
                sessions: [first, duplicate],
                strata: [firstStratum, duplicateStratum]
            ),
            250
        )
        XCTAssertEqual(
            StrataMath.totalPebbleCount(
                sessions: [first, duplicate],
                strata: [firstStratum, duplicateStratum]
            ),
            1
        )
    }

    func testFiveHundredPebbleBakeChainPreservesMassAndCount() {
        let originalCount = 500
        var loose = (0 ..< originalCount).map { index in
            StrataPebble(
                y: Double(index),
                colorHex: Constants.Color.science,
                grams: Constants.Mass.measuredPebbleGrams
            )
        }
        var bakedMass = 0
        var bakedCount = 0

        while let result = StrataMath.bake(pebbles: loose, innerWidth: 320) {
            bakedMass += result.grams
            bakedCount += result.pebbleCount
            loose = result.remainingPebbles
        }

        let looseMass = loose.reduce(0) { $0 + $1.grams }
        XCTAssertEqual(bakedMass + looseMass, originalCount * Constants.Mass.measuredPebbleGrams)
        XCTAssertEqual(bakedCount + loose.count, originalCount)
        XCTAssertLessThan(loose.count, Constants.Jar.bakeThreshold)
    }

    func testBedrockHeightIsClampedAndMonthLabelIsGregorian() throws {
        XCTAssertEqual(StrataMath.bedrockHeight(hours: 0), 18)
        XCTAssertEqual(StrataMath.bedrockHeight(hours: 400), 24)
        XCTAssertEqual(StrataMath.bedrockHeight(hours: 9_999), 46)

        var calendar = Calendar(identifier: .gregorian)
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        calendar.timeZone = tokyo
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 29
        )))
        XCTAssertEqual(StrataMath.monthLabel(for: date, timeZone: tokyo), "2026年8月")
    }

    func testArchiveLayoutKeepsPermanentHistoryInsideBoundedShelf() {
        let layout = StrataMath.archiveLayout(
            rawStrataHeight: 48 * 10_000,
            requestedBedrockHeight: 46,
            interiorHeight: 398
        )

        XCTAssertEqual(layout.bedrockHeight, 20)
        XCTAssertEqual(layout.totalHeight, 72, accuracy: 1e-12)
        XCTAssertEqual(layout.liveChamberHeight, 326, accuracy: 1e-12)
        XCTAssertGreaterThan(layout.strataScale, 0)
        XCTAssertLessThan(layout.strataScale, 1)
    }

    func testArchiveLayoutAlwaysPreservesLiveFractionOnSmallScenes() {
        for interiorHeight in [0.0, 1, 40, 100, 240, 398, 800] {
            let layout = StrataMath.archiveLayout(
                rawStrataHeight: 1_000_000,
                requestedBedrockHeight: 9_999,
                interiorHeight: interiorHeight
            )
            let archiveLimit = min(
                Double(Constants.Jar.archiveMaximumHeight),
                interiorHeight * Double(Constants.Jar.archiveMaximumFraction)
            )

            XCTAssertLessThanOrEqual(layout.totalHeight, archiveLimit + 1e-12)
            XCTAssertGreaterThanOrEqual(
                layout.liveChamberHeight,
                interiorHeight - archiveLimit - 1e-12
            )
            XCTAssertGreaterThanOrEqual(layout.strataScale, 0)
            XCTAssertLessThanOrEqual(layout.strataScale, 1)
        }
    }

    func testArchiveLayoutDoesNotInventHeightAndSanitizesNegativeInputs() {
        let empty = StrataMath.archiveLayout(
            rawStrataHeight: 0,
            requestedBedrockHeight: 0,
            interiorHeight: 398
        )
        XCTAssertEqual(
            empty,
            JarArchiveLayout(
                bedrockHeight: 0,
                strataScale: 1,
                totalHeight: 0,
                liveChamberHeight: 398
            )
        )

        let invalid = StrataMath.archiveLayout(
            rawStrataHeight: -100,
            requestedBedrockHeight: -20,
            interiorHeight: -1
        )
        XCTAssertEqual(
            invalid,
            JarArchiveLayout(
                bedrockHeight: 0,
                strataScale: 1,
                totalHeight: 0,
                liveChamberHeight: 0
            )
        )
    }

    func testMeasuredShareReconstructsMixedStratumWithoutLooseBakedPebbles() throws {
        let measuredID = UUID()
        let manualID = UUID()
        let looseID = UUID()
        let now = Date(timeIntervalSince1970: 3_000)
        let measured = StudySession(
            id: measuredID,
            startAt: now.addingTimeInterval(-1_500),
            endAt: now,
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "2026-08-30",
            isBaked: true,
            subjectNameSnapshot: "英語",
            subjectColorHexSnapshot: Constants.Color.english
        )
        let manual = StudySession(
            id: manualID,
            startAt: now.addingTimeInterval(-3_600),
            endAt: now,
            seconds: 3_600,
            source: .manual,
            grams: 600,
            deviceDayKey: "2026-08-30",
            isBaked: true,
            subjectNameSnapshot: "数学",
            subjectColorHexSnapshot: Constants.Color.mathematics
        )
        let loose = StudySession(
            id: looseID,
            startAt: now,
            endAt: now.addingTimeInterval(1_500),
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "2026-08-30",
            subjectNameSnapshot: "理科",
            subjectColorHexSnapshot: Constants.Color.science
        )
        let stratum = Stratum(
            pebbleCount: 2,
            heightPt: 40,
            colorMixJSON: StrataMath.encodeColorMix(
                StrataMath.colorMix(hexColors: [
                    Constants.Color.english,
                    Constants.Color.mathematics
                ])
            ),
            monthLabel: "2026年8月",
            grams: 850,
            sessionIDs: [measuredID, manualID]
        )

        let visual = try XCTUnwrap(
            ShareStratumVisual(
                reconstructing: stratum,
                allMemberSessions: [measured, manual],
                includedMemberSessions: [measured]
            )
        )
        let measuredRadius = ShareStratumVisual.radius(for: measured)
        let manualRadius = ShareStratumVisual.radius(for: manual)
        let expectedFraction = measuredRadius * measuredRadius
            / (measuredRadius * measuredRadius + manualRadius * manualRadius)

        XCTAssertEqual(visual.pebbleCount, 1)
        XCTAssertEqual(visual.sessionIDs, [measuredID])
        XCTAssertEqual(visual.heightPt, 40 * expectedFraction, accuracy: 1e-9)
        XCTAssertEqual(visual.colorMix, [
            StratumColorFraction(hex: Constants.Color.english, fraction: 1)
        ])
        XCTAssertEqual(
            ShareCardSelection.visibleLooseSessions(
                from: [measured, loose],
                representedBy: [visual]
            ).map(\.id),
            [looseID]
        )
    }

    func testSpecialLandingCopyUsesAwardedMass() {
        XCTAssertEqual(Constants.UIStrings.goldToast(grams: 250), Constants.UIStrings.goldToast)
        XCTAssertEqual(Constants.UIStrings.prismToast(grams: 250), Constants.UIStrings.prismToast)
        XCTAssertEqual(Constants.UIStrings.goldToast(grams: 600), "✦ 金のつぶが出た！ +600g")
        XCTAssertEqual(Constants.UIStrings.prismToast(grams: 900), "❖ 虹のつぶ！！ +900g")
    }

    func testTenStudyPebblesBecomeOneDecimalAggregateWithoutLosingDetail() throws {
        let base = Date(timeIntervalSince1970: 10_000)
        var descriptors: [PebbleDescriptor] = []
        for index in 0..<Constants.Jar.aggregateFanIn {
            let descriptor = PebbleDescriptor(
                subjectName: index < 6 ? "英語" : "数学",
                colorHex: index < 6 ? Constants.Color.english : Constants.Color.mathematics,
                source: index < 7 ? .timer : .manual,
                kind: index == 0 ? .gold : (index == 1 ? .prism : .normal),
                rareRewardCounts: index == 0
                    ? RareRewardCounts(drawCount: 2, goldCount: 1, prismCount: 1)
                    : nil,
                grams: index < 7 ? 250 : 600,
                createdAt: base.addingTimeInterval(Double(index))
            )
            descriptors.append(descriptor)
        }
        let request = try XCTUnwrap(JarAggregateRequest(
            pebbles: descriptors,
            innerWidth: 320
        ))
        let result = request.calculation

        XCTAssertEqual(result.level, 1)
        XCTAssertEqual(result.pebbleCount, 10)
        XCTAssertEqual(result.childAggregateCount, 0)
        XCTAssertEqual(result.sessionIDs.count, 10)
        XCTAssertEqual(result.grams, 7 * 250 + 3 * 600)
        XCTAssertEqual(result.measuredPebbleCount, 7)
        XCTAssertEqual(result.manualPebbleCount, 3)
        XCTAssertEqual(result.goldPebbleCount, 1)
        XCTAssertEqual(result.prismPebbleCount, 2)
        XCTAssertEqual(result.subjectMix.map(\.pebbleCount), [6, 4])
        XCTAssertEqual(result.colorMix.reduce(0) { $0 + $1.fraction }, 1, accuracy: 1e-12)
        XCTAssertTrue(request.outputDescriptor.accessibilityDescription.contains("英語など"))
        XCTAssertTrue(request.outputDescriptor.accessibilityDescription.contains("10粒"))
        XCTAssertTrue(request.outputDescriptor.accessibilityDescription.contains("自己申告3粒"))
        XCTAssertTrue(request.outputDescriptor.accessibilityDescription.contains("虹2粒"))
        XCTAssertEqual(request.outputDescriptor.aggregate?.pebbleCount, 10)
    }

    func testTenSameLevelAggregatesBecomeTimesOneHundred() throws {
        var levelOne: [AggregateSource] = []
        for group in 0..<10 {
            let leaves = (0..<10).map { index in
                let kind: PebbleKind
                if group == 0, index < 8 {
                    kind = .gold
                } else if group == 4, index == 0 {
                    kind = .gold
                } else if group == 9, index < 3 {
                    kind = .prism
                } else {
                    kind = .normal
                }
                return makeLeafSource(index: group * 10 + index, kind: kind)
            }
            let calculation = try XCTUnwrap(StrataMath.aggregate(sources: leaves))
            levelOne.append(makeAggregateSource(calculation))
        }

        XCTAssertEqual(levelOne.map(\.goldPebbleCount), [8, 0, 0, 0, 1, 0, 0, 0, 0, 0])
        XCTAssertEqual(levelOne.map(\.prismPebbleCount), [0, 0, 0, 0, 0, 0, 0, 0, 0, 3])

        let levelTwo = try XCTUnwrap(StrataMath.aggregate(sources: levelOne))
        XCTAssertEqual(levelTwo.level, 2)
        XCTAssertEqual(levelTwo.pebbleCount, 100)
        XCTAssertEqual(levelTwo.childAggregateCount, 10)
        XCTAssertEqual(levelTwo.childAggregateIDs.count, 10)
        XCTAssertTrue(levelTwo.sessionIDs.isEmpty)
        XCTAssertEqual(levelTwo.grams, 100 * Constants.Mass.measuredPebbleGrams)
        XCTAssertEqual(levelTwo.goldPebbleCount, 9)
        XCTAssertEqual(levelTwo.prismPebbleCount, 3)
        XCTAssertEqual(
            levelTwo.goldPebbleCount,
            levelOne.reduce(0) { $0 + $1.goldPebbleCount }
        )
        XCTAssertEqual(
            levelTwo.prismPebbleCount,
            levelOne.reduce(0) { $0 + $1.prismPebbleCount }
        )
        XCTAssertGreaterThan(levelTwo.radius, levelOne[0].radius)
        XCTAssertLessThanOrEqual(levelTwo.radius, Double(Constants.Jar.aggregateMaximumRadius))
    }

    func testCompactLineageResolvesDetailsWithoutDoubleCountingTotals() {
        let parentID = UUID()
        var sessions: [StudySession] = []
        var leaves: [AggregatePebble] = []
        let base = Date(timeIntervalSince1970: 20_000)
        for group in 0..<10 {
            let members = (0..<10).map { index -> StudySession in
                let session = StudySession(
                    id: UUID(),
                    startAt: base.addingTimeInterval(Double(group * 10 + index)),
                    endAt: base.addingTimeInterval(Double(group * 10 + index + 1)),
                    seconds: 1_500,
                    source: .timer,
                    grams: Constants.Mass.measuredPebbleGrams,
                    deviceDayKey: "2026-08-30",
                    isBaked: true
                )
                return session
            }
            sessions.append(contentsOf: members)
            leaves.append(AggregatePebble(
                level: 1,
                pebbleCount: 10,
                grams: 10 * Constants.Mass.measuredPebbleGrams,
                measuredPebbleCount: 10,
                colorMixJSON: "[]",
                periodStart: members.first?.startAt ?? base,
                periodEnd: members.last?.endAt ?? base,
                sessionIDs: members.map(\.id),
                parentAggregateID: parentID
            ))
        }
        let parent = AggregatePebble(
            id: parentID,
            level: 2,
            pebbleCount: 100,
            childAggregateCount: 10,
            grams: 100 * Constants.Mass.measuredPebbleGrams,
            measuredPebbleCount: 100,
            colorMixJSON: "[]",
            periodStart: sessions.first?.startAt ?? base,
            periodEnd: sessions.last?.endAt ?? base,
            childAggregateIDs: leaves.map(\.id)
        )
        let hierarchy = leaves + [parent]

        XCTAssertTrue(parent.sessionIDs.isEmpty)
        XCTAssertEqual(parent.childAggregateIDs.count, 10)
        XCTAssertEqual(AggregatePebblePolicy.directSessionIDs(from: hierarchy).count, 100)
        XCTAssertEqual(
            AggregatePebblePolicy.descendantSessionIDs(of: parent, in: hierarchy).count,
            100
        )
        XCTAssertTrue(AggregatePebblePolicy.hasCompleteLineage(parent, in: hierarchy))
        XCTAssertFalse(AggregatePebblePolicy.isUnattributedCompatibility(parent))
        XCTAssertEqual(
            StrataMath.totalGrams(sessions: sessions, aggregates: hierarchy),
            100 * Constants.Mass.measuredPebbleGrams
        )
        XCTAssertEqual(
            StrataMath.totalGrams(sessions: [], aggregates: hierarchy),
            100 * Constants.Mass.measuredPebbleGrams
        )
        XCTAssertEqual(StrataMath.totalPebbleCount(sessions: sessions, aggregates: hierarchy), 100)
        XCTAssertEqual(StrataMath.totalPebbleCount(sessions: [], aggregates: hierarchy), 100)
    }

    func testMissingBacklinkDoesNotCountParentAndChild() {
        let parentID = UUID()
        let base = Date(timeIntervalSince1970: 30_000)
        var leaves: [AggregatePebble] = []
        for group in 0..<10 {
            let memberIDs = (0..<10).map { _ in UUID() }
            leaves.append(makeAccountingAggregate(
                createdAt: base.addingTimeInterval(Double(group)),
                level: 1,
                pebbleCount: 10,
                sessionIDs: memberIDs,
                parentAggregateID: group == 9 ? nil : parentID
            ))
        }
        let parent = makeAccountingAggregate(
            id: parentID,
            createdAt: base.addingTimeInterval(100),
            level: 2,
            pebbleCount: 100,
            childAggregateIDs: leaves.map(\.id)
        )
        let hierarchy = leaves + [parent]

        XCTAssertEqual(AggregatePebblePolicy.activeRoots(from: hierarchy).count, 2)
        let frontier = AggregatePebblePolicy.accountingFrontier(from: hierarchy)
        XCTAssertEqual(frontier.summaries.map(\.id), [parentID])
        XCTAssertEqual(frontier.representedSessionIDs.count, 100)
        XCTAssertFalse(frontier.isLowerBound)
        XCTAssertEqual(StrataMath.totalPebbleCount(sessions: [], aggregates: hierarchy), 100)
        XCTAssertEqual(StrataMath.totalGrams(sessions: [], aggregates: hierarchy), 25_000)

        let overview = StrataMath.overview(aggregates: hierarchy)
        XCTAssertEqual(overview.rootCount, 1)
        XCTAssertEqual(overview.pebbleCount, 100)
        XCTAssertEqual(overview.grams, 25_000)
    }

    func testOverlappingRootsWithoutSessionsUseConservativeFrontier() {
        let base = Date(timeIntervalSince1970: 31_000)
        let sessionIDs = (0..<11).map { _ in UUID() }
        let first = makeAccountingAggregate(
            createdAt: base,
            level: 1,
            pebbleCount: 10,
            sessionIDs: Array(sessionIDs.prefix(10))
        )
        let second = makeAccountingAggregate(
            createdAt: base.addingTimeInterval(1),
            level: 1,
            pebbleCount: 10,
            sessionIDs: Array(sessionIDs.suffix(10))
        )
        let aggregates = [first, second]

        let frontier = AggregatePebblePolicy.accountingFrontier(from: aggregates)
        XCTAssertEqual(frontier.summaries.count, 1)
        XCTAssertEqual(frontier.representedSessionIDs.count, 10)
        XCTAssertEqual(frontier.conflictedAggregateIDs, Set([first.id, second.id]))
        XCTAssertTrue(frontier.isLowerBound)
        XCTAssertEqual(StrataMath.totalPebbleCount(sessions: [], aggregates: aggregates), 10)
        XCTAssertEqual(StrataMath.totalGrams(sessions: [], aggregates: aggregates), 2_500)
    }

    func testOverlappingRootsRecoverExactTotalFromDownloadedSessions() {
        let base = Date(timeIntervalSince1970: 32_000)
        let sessions = (0..<11).map { index in
            StudySession(
                id: UUID(),
                startAt: base.addingTimeInterval(Double(index)),
                endAt: base.addingTimeInterval(Double(index + 1)),
                seconds: 1_500,
                source: .timer,
                grams: Constants.Mass.measuredPebbleGrams,
                deviceDayKey: "2026-08-31",
                isBaked: true
            )
        }
        let first = makeAccountingAggregate(
            createdAt: base,
            level: 1,
            pebbleCount: 10,
            sessionIDs: Array(sessions.map(\.id).prefix(10))
        )
        let second = makeAccountingAggregate(
            createdAt: base.addingTimeInterval(1),
            level: 1,
            pebbleCount: 10,
            sessionIDs: Array(sessions.map(\.id).suffix(10))
        )
        let aggregates = [first, second]

        XCTAssertEqual(
            StrataMath.totalPebbleCount(sessions: sessions, aggregates: aggregates),
            11
        )
        XCTAssertEqual(
            StrataMath.totalGrams(sessions: sessions, aggregates: aggregates),
            2_750
        )
    }

    func testIncompleteParentFallsBackToCompleteChildren() {
        let parentID = UUID()
        let base = Date(timeIntervalSince1970: 33_000)
        let expectedChildIDs = (0..<10).map { _ in UUID() }
        let downloadedChildren = expectedChildIDs.prefix(9).enumerated().map { index, id in
            makeAccountingAggregate(
                id: id,
                createdAt: base.addingTimeInterval(Double(index)),
                level: 1,
                pebbleCount: 10,
                sessionIDs: (0..<10).map { _ in UUID() },
                parentAggregateID: parentID
            )
        }
        let parent = makeAccountingAggregate(
            id: parentID,
            createdAt: base.addingTimeInterval(100),
            level: 2,
            pebbleCount: 100,
            childAggregateIDs: expectedChildIDs
        )
        let partialHierarchy = downloadedChildren + [parent]

        let frontier = AggregatePebblePolicy.accountingFrontier(from: partialHierarchy)
        XCTAssertEqual(frontier.summaries.count, 9)
        XCTAssertEqual(frontier.representedSessionIDs.count, 90)
        XCTAssertTrue(frontier.isLowerBound)
        XCTAssertEqual(
            StrataMath.totalPebbleCount(sessions: [], aggregates: partialHierarchy),
            90
        )
        XCTAssertEqual(
            StrataMath.totalGrams(sessions: [], aggregates: partialHierarchy),
            22_500
        )
    }

    func testFortyYearCompactLineageReferenceBudgetStaysBounded() {
        // Matches the deterministic forty-year harness population.
        var sourceCount = 350_640
        var totalArrayReferences = 0
        var maximumReferencesInOneRow = 0
        while sourceCount >= Constants.Jar.aggregateFanIn {
            let parentCount = sourceCount / Constants.Jar.aggregateFanIn
            let referencesAtLevel = parentCount * Constants.Jar.aggregateFanIn
            totalArrayReferences += referencesAtLevel
            maximumReferencesInOneRow = max(
                maximumReferencesInOneRow,
                Constants.Jar.aggregateFanIn
            )
            sourceCount = parentCount
        }

        XCTAssertLessThanOrEqual(totalArrayReferences, 740_000)
        XCTAssertEqual(totalArrayReferences, 389_580)
        XCTAssertLessThanOrEqual(maximumReferencesInOneRow, 10)
    }

    func testBoundedVisibleRootsConserveEveryOmittedEffortAndRareCount() {
        let base = Date(timeIntervalSince1970: 45_000)
        let roots = (0..<60).map { index in
            let level = index % 6 + 1
            let pebbleCount = (0..<level).reduce(1) { value, _ in value * 10 }
            return AggregatePebble(
                id: UUID(uuidString: String(
                    format: "45000000-0000-4000-8000-%012X",
                    index + 1
                ))!,
                createdAt: base.addingTimeInterval(Double(index)),
                level: level,
                pebbleCount: pebbleCount,
                grams: pebbleCount * Constants.Mass.measuredPebbleGrams,
                measuredPebbleCount: pebbleCount,
                goldPebbleCount: index % 4,
                prismPebbleCount: index % 3,
                colorMixJSON: "[]",
                periodStart: base.addingTimeInterval(Double(index)),
                periodEnd: base.addingTimeInterval(Double(index))
            )
        }

        let projection = AggregatePebblePolicy.visibleRootProjection(from: roots)
        let reversed = AggregatePebblePolicy.visibleRootProjection(from: Array(roots.reversed()))
        let visibleIDs = Set(projection.visibleRoots.map(\.id))
        let recentIDs = Set(roots.suffix(Constants.Jar.minimumRecentAggregateRoots).map(\.id))

        XCTAssertEqual(
            projection.visibleRoots.map(\.id),
            reversed.visibleRoots.map(\.id),
            "CloudKit delivery order must not change the physical root set"
        )
        XCTAssertEqual(projection.visibleRoots.count, Constants.Jar.maximumVisibleAggregateRoots)
        XCTAssertEqual(projection.totalRootCount, roots.count)
        XCTAssertEqual(projection.omittedRootCount, 12)
        XCTAssertTrue(projection.hasOmittedRoots)
        XCTAssertTrue(recentIDs.isSubset(of: visibleIDs))
        XCTAssertEqual(
            projection.visibleRoots.reduce(0) { $0 + $1.pebbleCount }
                + projection.omittedPebbleCount,
            roots.reduce(0) { $0 + $1.pebbleCount }
        )
        XCTAssertEqual(
            projection.visibleRoots.reduce(0) { $0 + $1.grams }
                + projection.omittedGrams,
            roots.reduce(0) { $0 + $1.grams }
        )
        XCTAssertEqual(
            projection.visibleRoots.reduce(0) { $0 + $1.goldPebbleCount }
                + projection.omittedGoldPebbleCount,
            roots.reduce(0) { $0 + $1.goldPebbleCount }
        )
        XCTAssertEqual(
            projection.visibleRoots.reduce(0) { $0 + $1.prismPebbleCount }
                + projection.omittedPrismPebbleCount,
            roots.reduce(0) { $0 + $1.prismPebbleCount }
        )
        XCTAssertEqual(
            AggregatePebblePolicy.visibleRoots(from: roots).map(\.id),
            projection.visibleRoots.map(\.id),
            "The existing scene API must preserve its selection behavior"
        )
    }

    func testVisibleRootProjectionHasNoOmissionForNormalFortyYearDecimalFrontier() {
        let base = Date(timeIntervalSince1970: 46_000)
        let counts = Array(repeating: 10, count: 4)
            + Array(repeating: 100, count: 6)
            + Array(repeating: 10_000, count: 5)
            + Array(repeating: 100_000, count: 3)
        let roots = counts.enumerated().map { index, pebbleCount in
            makeAccountingAggregate(
                createdAt: base.addingTimeInterval(Double(index)),
                level: StrataMath.decimalAggregateLevel(forPebbleCount: pebbleCount),
                pebbleCount: pebbleCount
            )
        }

        let projection = AggregatePebblePolicy.visibleRootProjection(from: roots)

        XCTAssertEqual(projection.visibleRoots.count, 18)
        XCTAssertEqual(projection.totalRootCount, 18)
        XCTAssertEqual(projection.omittedRootCount, 0)
        XCTAssertEqual(projection.omittedPebbleCount, 0)
        XCTAssertEqual(projection.omittedGrams, 0)
        XCTAssertEqual(projection.omittedGoldPebbleCount, 0)
        XCTAssertEqual(projection.omittedPrismPebbleCount, 0)
        XCTAssertFalse(projection.hasOmittedRoots)
        XCTAssertEqual(projection.visibleRoots.reduce(0) { $0 + $1.pebbleCount }, 350_640)
    }

    func testOneHundredTwentyPebblesFuseRepeatedlyUntilSafeCapacity() throws {
        var bodies = (0..<120).map { makeLeafSource(index: $0) }
        var reliefIsActive = false
        var levelOneFormations = 0
        var iteration = 0

        while true {
            iteration += 1
            XCTAssertLessThan(iteration, 100)
            let capacity = bodyCapacity(bodies)
            if capacity >= Constants.Jar.aggregateCapacityUnits { reliefIsActive = true }
            if capacity <= Constants.Jar.postAggregateCapacityUnits { reliefIsActive = false }
            guard reliefIsActive else { break }
            XCTAssertTrue(try combineFirstTen(level: 0, bodies: &bodies))
            levelOneFormations += 1
        }

        XCTAssertEqual(levelOneFormations, 7)
        XCTAssertEqual(bodies.filter { $0.level == 1 }.count, 7)
        XCTAssertEqual(bodies.reduce(0) { $0 + $1.pebbleCount }, 120)
        XCTAssertEqual(
            bodies.reduce(0) { $0 + $1.grams },
            120 * Constants.Mass.measuredPebbleGrams
        )
        XCTAssertLessThanOrEqual(
            bodyCapacity(bodies),
            Constants.Jar.postAggregateCapacityUnits + 1e-12
        )
    }

    func testFiveThousandPebblesStayWithinPhysicsBudgetAndKeepMovingSet() throws {
        var bodies: [AggregateSource] = []
        var reliefIsActive = false
        for index in 0..<5_000 {
            bodies.append(makeLeafSource(index: index))
            try carryDecimalHierarchy(bodies: &bodies)

            if bodyCapacity(bodies) >= Constants.Jar.aggregateCapacityUnits {
                reliefIsActive = true
            }
            while reliefIsActive {
                guard try combineFirstTen(level: 0, bodies: &bodies) else { break }
                try carryDecimalHierarchy(bodies: &bodies)
                if bodyCapacity(bodies) <= Constants.Jar.postAggregateCapacityUnits {
                    reliefIsActive = false
                }
            }
            XCTAssertLessThanOrEqual(bodies.count, Constants.Jar.maxPhysicsBodies)
        }

        XCTAssertEqual(bodies.reduce(0) { $0 + $1.pebbleCount }, 5_000)
        XCTAssertEqual(
            bodies.reduce(0) { $0 + $1.grams },
            5_000 * Constants.Mass.measuredPebbleGrams
        )
        XCTAssertGreaterThanOrEqual(bodies.count, 12)
        XCTAssertLessThanOrEqual(bodies.count, Constants.Jar.maxPhysicsBodies)
    }

    @MainActor
    func testTenLoosePebblesFuseImmediatelyAndChooseOldestChronologically() throws {
        let descriptors = (0..<11).map { index in
            PebbleDescriptor(
                id: UUID(uuidString: String(
                    format: "30000000-0000-4000-8000-%012X",
                    index + 1
                ))!,
                subjectName: "資格",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams,
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = true
        var requests: [JarAggregateRequest] = []
        scene.onAggregateRequested = { requests.append($0) }

        // Restore in the opposite order to prove physics/insertion order does
        // not decide which ten pieces of study history are fused.
        scene.restore(pebbles: Array(descriptors.reversed()))
        scene.update(0)

        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.outputLevel, 1)
        XCTAssertEqual(request.sourceCount, Constants.Jar.aggregateFanIn)
        XCTAssertEqual(Set(request.pebbleIDs), Set(descriptors.prefix(10).map(\.id)))
        XCTAssertEqual(scene.physicalPebbleCount, 2)
        XCTAssertEqual(scene.representedPebbleCount, 11)
    }

    @MainActor
    func testNineLoosePebblesDoNotFuseBeforeTheDecimalMilestone() {
        let descriptors = (0..<9).map { index in
            PebbleDescriptor(
                subjectName: "資格",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams,
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = true
        var requestCount = 0
        scene.onAggregateRequested = { _ in requestCount += 1 }
        scene.restore(pebbles: descriptors)

        scene.update(0)

        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(scene.physicalPebbleCount, 9)
        XCTAssertEqual(scene.representedPebbleCount, 9)
    }

    @MainActor
    func testAggregatePersistenceHandlerSurvivesCallbackRemovalAtAnimationBoundaries() async throws {
        let removalMilliseconds = [0, 100, 400, 520]

        for removalMillisecond in removalMilliseconds {
            let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
            scene.soundEnabled = false
            scene.hapticsEnabled = false
            scene.reduceMotion = false
            let descriptors = makeSceneAggregateDescriptors()
            var deliveredRequestIDs: [UUID] = []
            scene.onAggregateRequested = { request in
                deliveredRequestIDs.append(request.id)
            }
            scene.restore(pebbles: descriptors)

            scene.update(0)
            XCTAssertTrue(scene.isBakeInProgress)
            if removalMillisecond > 0 {
                try await Task.sleep(
                    for: .milliseconds(Int64(removalMillisecond))
                )
            }
            scene.onAggregateRequested = nil
            try await Task.sleep(
                for: .milliseconds(Int64(850 - removalMillisecond))
            )

            XCTAssertEqual(
                deliveredRequestIDs.count,
                1,
                "The handler captured at t=0 must survive removal at \(removalMillisecond) ms"
            )
            XCTAssertFalse(scene.isBakeInProgress)
            XCTAssertEqual(scene.physicalPebbleCount, 1)
            XCTAssertEqual(scene.representedPebbleCount, 100)
        }
    }

    @MainActor
    func testAggregateDoesNotStartWithoutPersistenceReceiver() {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = true
        scene.restore(pebbles: makeSceneAggregateDescriptors())

        scene.update(0)

        XCTAssertFalse(scene.isBakeInProgress)
        XCTAssertEqual(scene.physicalPebbleCount, 10)
        XCTAssertEqual(scene.representedPebbleCount, 100)
    }

    @MainActor
    func testConsecutivePersistenceFailuresAllowOnlyExplicitRetryAttempts() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = true
        let descriptors = makeSceneAggregateDescriptors()
        var attempts = 0
        var attemptedRequestIDs: [UUID] = []
        scene.onAggregateRequested = { request in
            attempts += 1
            attemptedRequestIDs.append(request.id)
            scene.suspendAggregateAfterPersistenceFailure(id: request.id)
            scene.restore(pebbles: descriptors)
        }
        scene.restore(pebbles: descriptors)

        scene.update(0)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(scene.physicalPebbleCount, 10)
        XCTAssertFalse(scene.isBakeInProgress)

        for tick in 1 ... 20 {
            scene.update(TimeInterval(tick))
        }
        XCTAssertEqual(
            attempts,
            1,
            "A failed save must not retry automatically on subsequent frames"
        )

        let requestID = try XCTUnwrap(attemptedRequestIDs.first)
        XCTAssertTrue(scene.retryAggregatePersistence(id: requestID))
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(Set(attemptedRequestIDs), [requestID])

        for tick in 21 ... 40 {
            scene.update(TimeInterval(tick))
        }
        XCTAssertEqual(
            attempts,
            2,
            "A second consecutive failure also requires another explicit retry"
        )

        scene.onAggregateRequested = { request in
            attempts += 1
            attemptedRequestIDs.append(request.id)
        }
        XCTAssertTrue(scene.retryAggregatePersistence(id: requestID))
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(Set(attemptedRequestIDs), [requestID])
        XCTAssertEqual(scene.physicalPebbleCount, 1)
        XCTAssertEqual(scene.representedPebbleCount, 100)
        XCTAssertFalse(scene.isBakeInProgress)
    }

    @MainActor
    func testExternalGravityRejectsInvalidAndClampsExtremeVectors() {
        let scene = JarScene()
        scene.setGravityVector(CGVector(dx: 100, dy: -100), smoothing: false)
        XCTAssertLessThanOrEqual(
            hypot(scene.appliedGravityVector.dx, scene.appliedGravityVector.dy),
            Constants.Jar.maximumExternalGravityMagnitude + 1e-12
        )
        let valid = scene.appliedGravityVector
        scene.setGravityVector(CGVector(dx: .nan, dy: -.infinity), smoothing: false)
        XCTAssertEqual(scene.appliedGravityVector.dx, valid.dx)
        XCTAssertEqual(scene.appliedGravityVector.dy, valid.dy)
    }

    @MainActor
    func testJarAccessibilityUsesPhysicalBodiesForAggregateAndAchievementOnlyContent() {
        let aggregateScene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        let aggregate = AggregateMetadata(
            level: 1,
            pebbleCount: 24,
            childAggregateCount: 0,
            colorMix: [StratumColorFraction(hex: Constants.Color.english, fraction: 1)],
            subjectMix: [AggregateSubjectFraction(
                name: "英語",
                colorHex: Constants.Color.english,
                pebbleCount: 24
            )],
            periodStart: .now,
            periodEnd: .now,
            sessionIDs: (0 ..< 24).map { _ in UUID() },
            measuredPebbleCount: 24,
            manualPebbleCount: 0,
            goldPebbleCount: 0,
            prismPebbleCount: 0
        )
        aggregateScene.restore(pebbles: [PebbleDescriptor(
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            aggregate: aggregate,
            grams: 6_000
        )])
        let aggregateOnlyView = JarSpriteView(
            scene: aggregateScene,
            totalGrams: 6_000,
            pebbleCount: 0,
            aggregateCount: 1,
            representedPebbleCount: 24
        )
        XCTAssertEqual(aggregateScene.physicalPebbleCount, 1)
        XCTAssertTrue(aggregateOnlyView.hasPhysicalContent)

        let achievementScene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        achievementScene.restore(pebbles: [PebbleDescriptor(
            subjectName: "資格",
            colorHex: Constants.Color.science,
            source: .manual,
            kind: .normal,
            achievementKind: .examPass,
            grams: 0
        )])
        let achievementOnlyView = JarSpriteView(
            scene: achievementScene,
            totalGrams: 0,
            pebbleCount: 0,
            achievementCount: 1
        )
        XCTAssertEqual(achievementScene.physicalPebbleCount, 1)
        XCTAssertTrue(achievementOnlyView.hasPhysicalContent)

        let emptyScene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        XCTAssertFalse(JarSpriteView(
            scene: emptyScene,
            totalGrams: 0,
            pebbleCount: 0
        ).hasPhysicalContent)
    }

    func testCatalystDragOwnershipRemainsMonotonicWhenPointerReturns() {
        var ownership = JarDragGestureOwnership()
        XCTAssertFalse(ownership.observe(distance: 2.9))
        XCTAssertTrue(ownership.observe(distance: 12))
        XCTAssertTrue(ownership.observe(distance: 0.5))
        XCTAssertTrue(
            ownership.finish(distance: 0),
            "Returning to the start must remain a drag and reset gravity instead of bouncing"
        )
        XCTAssertFalse(ownership.exceededThreshold)
        XCTAssertFalse(ownership.finish(distance: 0.5), "The next interaction may be a tap")
    }

    func testMotionUpdateGateRejectsQueuedUpdatesAfterStopAndRestart() {
        var gate = JarMotionUpdateGate()
        let firstGeneration = gate.begin()
        XCTAssertTrue(gate.accepts(firstGeneration, reduceMotion: false))
        XCTAssertFalse(gate.accepts(firstGeneration, reduceMotion: true))

        gate.invalidate()
        XCTAssertFalse(gate.accepts(firstGeneration, reduceMotion: false))

        let secondGeneration = gate.begin()
        XCTAssertNotEqual(firstGeneration, secondGeneration)
        XCTAssertFalse(
            gate.accepts(firstGeneration, reduceMotion: false),
            "A queued task from an older run must not apply after restart"
        )
        XCTAssertTrue(gate.accepts(secondGeneration, reduceMotion: false))
    }

    @MainActor
    func testReduceMotionImmediatelyRestoresDefaultGravity() {
        let scene = JarScene()
        scene.reduceMotion = false
        scene.setGravityVector(CGVector(dx: 2.4, dy: -5), smoothing: false)
        XCTAssertNotEqual(scene.appliedGravityVector.dx, Constants.Jar.gravityVector.dx)

        scene.reduceMotion = true

        XCTAssertEqual(scene.appliedGravityVector.dx, Constants.Jar.gravityVector.dx)
        XCTAssertEqual(scene.appliedGravityVector.dy, Constants.Jar.gravityVector.dy)
    }

    @MainActor
    func testReduceMotionLooseDropStartsSettledAndKeepsStaticSpotlight() throws {
        let descriptor = PebbleDescriptor(
            id: UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!,
            subjectName: "資格",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            grams: Constants.Mass.measuredPebbleGrams
        )
        var landingIDs: [UUID] = []
        let scene = makeDropScene(reduceMotion: true)
        scene.onLanding = { landingIDs.append($0.pebble.id) }

        scene.drop(descriptor)
        scene.update(0)

        let pebble = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(descriptor.id.uuidString)"
        ) as? PebbleNode)
        let body = try XCTUnwrap(pebble.physicsBody)
        XCTAssertEqual(scene.physicalPebbleCount, 1)
        XCTAssertEqual(scene.representedPebbleCount, 1)
        XCTAssertEqual(pebble.descriptor.id, descriptor.id)
        XCTAssertEqual(pebble.descriptor.grams, descriptor.grams)
        XCTAssertTrue(pebble.hasLanded)
        XCTAssertEqual(
            pebble.position.y,
            Constants.Jar.floorInset + descriptor.radius,
            accuracy: 0.001
        )
        XCTAssertEqual(body.velocity.dx, 0, accuracy: 0.001)
        XCTAssertEqual(body.velocity.dy, 0, accuracy: 0.001)
        XCTAssertEqual(body.angularVelocity, 0, accuracy: 0.001)
        XCTAssertTrue(body.isResting)
        XCTAssertEqual(body.categoryBitMask, JarPhysicsCategory.pebble)
        XCTAssertNotEqual(body.collisionBitMask & JarPhysicsCategory.floor, .zero)
        XCTAssertEqual(landingIDs, [descriptor.id])

        let spotlight = try XCTUnwrap(pebble.childNode(withName: "pebble.earlyEffortAura"))
        XCTAssertNil(
            spotlight.action(forKey: "pebble.earlyEffortAura.breath"),
            "Reduce Motion keeps the earned highlight visible but static"
        )

        let matchingScene = makeDropScene(reduceMotion: true)
        matchingScene.drop(descriptor)
        matchingScene.update(0)
        let matchingPebble = try XCTUnwrap(matchingScene.childNode(
            withName: "//pebble.\(descriptor.id.uuidString)"
        ) as? PebbleNode)
        XCTAssertEqual(matchingPebble.position.x, pebble.position.x, accuracy: 0.001)
        XCTAssertEqual(matchingPebble.position.y, pebble.position.y, accuracy: 0.001)
        XCTAssertEqual(matchingPebble.zRotation, pebble.zRotation, accuracy: 0.001)
    }

    @MainActor
    func testReduceMotionAggregateDropStartsSettledWithStaticAura() throws {
        let descriptor = try XCTUnwrap(makeSceneAggregateDescriptors().first)
        var landingCount = 0
        let scene = makeDropScene(reduceMotion: true)
        scene.onLanding = { _ in landingCount += 1 }

        scene.drop(descriptor)
        scene.update(0)

        let pebble = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(descriptor.id.uuidString)"
        ) as? PebbleNode)
        let body = try XCTUnwrap(pebble.physicsBody)
        XCTAssertTrue(pebble.descriptor.isAggregate)
        XCTAssertEqual(pebble.descriptor.aggregate, descriptor.aggregate)
        XCTAssertEqual(scene.physicalAggregateCount, 1)
        XCTAssertEqual(scene.representedPebbleCount, descriptor.aggregate?.pebbleCount)
        XCTAssertTrue(pebble.hasLanded)
        XCTAssertEqual(
            pebble.position.y,
            Constants.Jar.floorInset + descriptor.radius,
            accuracy: 0.001
        )
        XCTAssertEqual(body.velocity.dx, 0, accuracy: 0.001)
        XCTAssertEqual(body.velocity.dy, 0, accuracy: 0.001)
        XCTAssertEqual(body.angularVelocity, 0, accuracy: 0.001)
        XCTAssertTrue(body.isResting)
        XCTAssertEqual(body.categoryBitMask, JarPhysicsCategory.pebble)
        XCTAssertEqual(landingCount, 0, "Aggregate drops never impersonate a new study session")

        let aura = try XCTUnwrap(pebble.childNode(withName: "aggregate.aura"))
        XCTAssertNil(
            aura.action(forKey: "aggregate.aura.breath"),
            "The aggregate's dimensional highlight remains present and static"
        )
    }

    @MainActor
    func testReduceMotionFusionAggregateIsBornSettledWithoutBounce() throws {
        let scene = makeDropScene(reduceMotion: true)
        let descriptors = (0 ..< Constants.Jar.aggregateFanIn).map { index in
            PebbleDescriptor(
                id: UUID(uuidString: String(
                    format: "B0000000-0000-4000-8000-%012X",
                    index + 1
                ))!,
                subjectName: "資格",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        var request: JarAggregateRequest?
        scene.onAggregateRequested = { request = $0 }
        scene.restore(pebbles: descriptors)

        scene.update(0)

        let output = try XCTUnwrap(request?.outputDescriptor)
        let pebble = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(output.id.uuidString)"
        ) as? PebbleNode)
        let body = try XCTUnwrap(pebble.physicsBody)
        XCTAssertEqual(pebble.descriptor.id, output.id)
        XCTAssertEqual(pebble.descriptor.aggregate, output.aggregate)
        XCTAssertEqual(scene.physicalAggregateCount, 1)
        XCTAssertEqual(scene.representedPebbleCount, Constants.Jar.aggregateFanIn)
        XCTAssertTrue(pebble.hasLanded)
        XCTAssertEqual(
            pebble.position.y,
            Constants.Jar.floorInset + output.radius,
            accuracy: 0.001
        )
        XCTAssertEqual(body.velocity.dx, 0, accuracy: 0.001)
        XCTAssertEqual(body.velocity.dy, 0, accuracy: 0.001)
        XCTAssertEqual(body.angularVelocity, 0, accuracy: 0.001)
        XCTAssertTrue(body.isResting)
        XCTAssertNotNil(pebble.childNode(withName: "aggregate.aura"))
        XCTAssertNil(
            pebble.childNode(withName: "aggregate.aura")?
                .action(forKey: "aggregate.aura.breath")
        )
    }

    @MainActor
    func testStandardMotionLooseAndAggregateDropsKeepFallingLaunch() throws {
        let loose = PebbleDescriptor(
            subjectName: "資格",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            grams: Constants.Mass.measuredPebbleGrams
        )
        let aggregate = try XCTUnwrap(makeSceneAggregateDescriptors().first)

        for descriptor in [loose, aggregate] {
            let scene = makeDropScene(reduceMotion: false)
            scene.drop(descriptor)
            scene.update(0)

            let pebble = try XCTUnwrap(scene.childNode(
                withName: "//pebble.\(descriptor.id.uuidString)"
            ) as? PebbleNode)
            let body = try XCTUnwrap(pebble.physicsBody)
            XCTAssertFalse(pebble.hasLanded)
            XCTAssertEqual(
                pebble.position.y,
                Constants.Jar.height - Constants.Jar.wallInset - descriptor.radius,
                accuracy: 0.001
            )
            XCTAssertEqual(
                body.velocity.dy,
                Constants.Jar.dropVerticalSpeed,
                accuracy: 0.001
            )
            XCTAssertFalse(body.isResting)
        }
    }

    @MainActor
    func testTapBouncePreservesBodiesAndUsesCooldown() {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        let descriptors = [
            PebbleDescriptor(
                subjectName: "英語",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams
            ),
            PebbleDescriptor(
                subjectName: "簿記",
                colorHex: Constants.Color.mathematics,
                source: .manual,
                kind: .normal,
                achievementKind: .examPass,
                grams: 0
            ),
            PebbleDescriptor(
                subjectName: "仕事",
                colorHex: Constants.Color.science,
                source: .timer,
                kind: .gold,
                grams: Constants.Mass.measuredPebbleGrams
            )
        ]
        scene.restore(pebbles: descriptors)

        guard let bouncedNode = scene.childNode(
            withName: "//pebble.\(descriptors[0].id.uuidString)"
        ) as? PebbleNode,
            let bouncedBody = bouncedNode.physicsBody
        else {
            XCTFail("Restored pebble must have a physical body")
            return
        }
        bouncedBody.velocity = .zero
        bouncedBody.isResting = true
        scene.isPaused = true

        let bodyCount = scene.physicalPebbleCount
        let representedCount = scene.representedPebbleCount
        let queuedCount = scene.queuedDropCount
        XCTAssertTrue(scene.bouncePebbles(at: bouncedNode.position))
        XCTAssertFalse(scene.isPaused)
        XCTAssertFalse(bouncedBody.isResting)
        XCTAssertGreaterThan(
            bouncedBody.velocity.dy,
            65,
            "The first physics frame needs enough upward velocity for an 18 pt+ visible hop"
        )
        bouncedBody.velocity = .zero
        scene.didSimulatePhysics()
        XCTAssertGreaterThan(
            bouncedBody.velocity.dy,
            65,
            "A sleeping floor contact must not consume the visible tap response"
        )
        XCTAssertTrue(bouncedNode.hasLanded, "Tap bounce must not re-arm landing rewards")
        XCTAssertEqual(scene.physicalPebbleCount, bodyCount)
        XCTAssertEqual(scene.representedPebbleCount, representedCount)
        XCTAssertEqual(scene.queuedDropCount, queuedCount)
        XCTAssertFalse(scene.bouncePebbles(at: bouncedNode.position))
    }

    @MainActor
    func testTapImpactUsesTwoDimensionalFalloffAndLeavesFarBodyUntouched() {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        let descriptors = [
            PebbleDescriptor(
                subjectName: "近い粒",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams
            ),
            PebbleDescriptor(
                subjectName: "遠い粒",
                colorHex: Constants.Color.mathematics,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams
            )
        ]
        scene.restore(pebbles: descriptors)

        guard let near = scene.childNode(
            withName: "//pebble.\(descriptors[0].id.uuidString)"
        ) as? PebbleNode,
            let far = scene.childNode(
                withName: "//pebble.\(descriptors[1].id.uuidString)"
            ) as? PebbleNode,
            let nearBody = near.physicsBody,
            let farBody = far.physicsBody
        else {
            XCTFail("Both restored pebbles need physics bodies")
            return
        }

        // Same X coordinate proves that vertical distance is part of the
        // falloff. The previous implementation only measured horizontal X.
        near.position = CGPoint(x: 195, y: 110)
        far.position = CGPoint(x: 195, y: 300)
        nearBody.velocity = .zero
        farBody.velocity = .zero
        nearBody.linearDamping = Constants.Jar.linearDamping
        farBody.linearDamping = Constants.Jar.linearDamping
        nearBody.isResting = true
        farBody.isResting = true

        XCTAssertTrue(scene.bouncePebbles(at: near.position))
        XCTAssertGreaterThan(nearBody.velocity.dy, 70)
        XCTAssertFalse(nearBody.isResting)
        XCTAssertEqual(farBody.velocity.dx, 0, accuracy: 0.001)
        XCTAssertEqual(farBody.velocity.dy, 0, accuracy: 0.001)
        XCTAssertEqual(farBody.linearDamping, Constants.Jar.linearDamping, accuracy: 0.001)
        XCTAssertTrue(farBody.isResting)

        scene.didSimulatePhysics()
        XCTAssertEqual(farBody.velocity.dx, 0, accuracy: 0.001)
        XCTAssertEqual(farBody.velocity.dy, 0, accuracy: 0.001)
        XCTAssertTrue(farBody.isResting)
    }

    @MainActor
    func testEmptyLocalTapAcknowledgesExactPointWithoutMovingBodies() {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        let descriptor = PebbleDescriptor(
            subjectName: "資格",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            grams: Constants.Mass.measuredPebbleGrams
        )
        scene.restore(pebbles: [descriptor])
        guard let pebble = scene.childNode(
            withName: "//pebble.\(descriptor.id.uuidString)"
        ) as? PebbleNode,
            let body = pebble.physicsBody
        else {
            XCTFail("Restored pebble needs a physics body")
            return
        }
        pebble.position = CGPoint(x: 195, y: 90)
        body.velocity = .zero
        body.isResting = true
        let point = CGPoint(x: 195, y: 340)

        XCTAssertTrue(scene.bouncePebbles(at: point))
        XCTAssertEqual(body.velocity.dx, 0, accuracy: 0.001)
        XCTAssertEqual(body.velocity.dy, 0, accuracy: 0.001)
        XCTAssertTrue(body.isResting)
        guard let caustic = scene.childNode(withName: "//jar.tap.caustic") else {
            XCTFail("Tap feedback must remain visible on empty glass")
            return
        }
        XCTAssertEqual(caustic.position.x, point.x, accuracy: 0.001)
        XCTAssertEqual(caustic.position.y, point.y, accuracy: 0.001)
    }

    @MainActor
    func testTapBounceRejectsOutsideJarAndReduceMotionPreservesBodies() {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = true
        scene.restore(pebbles: [PebbleDescriptor(
            subjectName: "資格",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            grams: Constants.Mass.measuredPebbleGrams
        )])

        let body = (scene.childNode(withName: "//pebble.*") as? PebbleNode)?.physicsBody
        body?.velocity = .zero
        body?.isResting = true

        XCTAssertFalse(scene.bouncePebbles(at: CGPoint(x: 2, y: 210)))
        XCTAssertTrue(scene.bouncePebbles())
        XCTAssertEqual(scene.physicalPebbleCount, 1)
        XCTAssertEqual(scene.representedPebbleCount, 1)
        XCTAssertEqual(body?.velocity.dx ?? .nan, 0, accuracy: 0.001)
        XCTAssertEqual(body?.velocity.dy ?? .nan, 0, accuracy: 0.001)
        XCTAssertEqual(body?.isResting, true)
        XCTAssertNotNil(
            scene.childNode(withName: "//jar.tap.caustic")?
                .action(forKey: "jar.tapCaustic"),
            "Reduce Motion needs local visual confirmation at the activation point"
        )
        XCTAssertNil(
            scene.childNode(withName: "//jar.reducedMotion.highlight")?
                .action(forKey: "jar.reducedMotionHighlight"),
            "A local touch must not flash the whole bottle"
        )
    }

    @MainActor
    func testReduceMotionDirectionalNudgePreservesPhysicsPositionsAndAccounting() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = true
        let loose = PebbleDescriptor(
            id: UUID(uuidString: "D0000000-0000-4000-8000-000000000001")!,
            subjectName: "資格",
            colorHex: Constants.Color.science,
            source: .timer,
            kind: .gold,
            grams: Constants.Mass.measuredPebbleGrams
        )
        let aggregate = try XCTUnwrap(makeSceneAggregateDescriptors().first)
        let descriptors = [loose, aggregate]
        scene.restore(pebbles: descriptors)

        let pebbles = try descriptors.map { descriptor in
            try XCTUnwrap(scene.childNode(
                withName: "//pebble.\(descriptor.id.uuidString)"
            ) as? PebbleNode)
        }
        for pebble in pebbles {
            pebble.physicsBody?.velocity = .zero
            pebble.physicsBody?.angularVelocity = 0
            pebble.physicsBody?.isResting = true
        }
        let originalStates = try pebbles.map { pebble in
            let body = try XCTUnwrap(pebble.physicsBody)
            return (
                position: pebble.position,
                velocity: body.velocity,
                angularVelocity: body.angularVelocity,
                isResting: body.isResting
            )
        }
        let physicalCount = scene.physicalPebbleCount
        let aggregateCount = scene.physicalAggregateCount
        let representedCount = scene.representedPebbleCount
        let queuedCount = scene.queuedDropCount
        let contentRevision = scene.physicalContentRevision

        scene.nudge(horizontal: -1)
        scene.nudge(horizontal: 1)

        for (pebble, original) in zip(pebbles, originalStates) {
            let body = try XCTUnwrap(pebble.physicsBody)
            XCTAssertEqual(pebble.position.x, original.position.x, accuracy: 0.001)
            XCTAssertEqual(pebble.position.y, original.position.y, accuracy: 0.001)
            XCTAssertEqual(body.velocity.dx, original.velocity.dx, accuracy: 0.001)
            XCTAssertEqual(body.velocity.dy, original.velocity.dy, accuracy: 0.001)
            XCTAssertEqual(body.angularVelocity, original.angularVelocity, accuracy: 0.001)
            XCTAssertEqual(body.isResting, original.isResting)
        }
        XCTAssertEqual(scene.physicalPebbleCount, physicalCount)
        XCTAssertEqual(scene.physicalAggregateCount, aggregateCount)
        XCTAssertEqual(scene.representedPebbleCount, representedCount)
        XCTAssertEqual(scene.queuedDropCount, queuedCount)
        XCTAssertEqual(scene.physicalContentRevision, contentRevision)
        XCTAssertEqual(
            scene.representedPebbleCount,
            1 + (aggregate.aggregate?.pebbleCount ?? 0),
            "A static accessibility acknowledgement must not alter represented study effort"
        )
    }

    func testAchievementGemMaterialsStayDistinctAndVivid() {
        XCTAssertEqual(AchievementKind.perfectScore.gemBaseHex, "D93D68")
        XCTAssertEqual(AchievementKind.examPass.gemBaseHex, "008E76")
        XCTAssertEqual(AchievementKind.workMilestone.gemBaseHex, "6D50EA")
        XCTAssertEqual(Set(AchievementKind.allCases.map(\.gemEdgeHex)).count, 3)
        XCTAssertEqual(Set(AchievementKind.allCases.map(\.gemGlowHex)).count, 3)
    }

    @MainActor
    func testLegacyLayersOccupyNoVisualOrPhysicalFloorHeight() {
        let renderer = StrataRenderer()
        let parent = SKNode()
        renderer.install(in: parent)
        renderer.render(
            strata: [JarStratumVisual(
                pebbleCount: 10_000,
                height: 50_000,
                colorMix: [StratumColorFraction(hex: Constants.Color.english, fraction: 1)],
                monthLabel: "2026年8月"
            )],
            bedrock: JarBedrockVisual(hours: 9_999),
            in: CGRect(x: 0, y: 0, width: 320, height: 398),
            showsMonthLabels: true,
            reduceMotion: false
        )
        XCTAssertEqual(renderer.totalHeight, 0)
        XCTAssertEqual(renderer.compactionScale, 1)
    }

    private func makeSceneAggregateDescriptors() -> [PebbleDescriptor] {
        (0 ..< Constants.Jar.aggregateFanIn).map { index in
            let date = Date(timeIntervalSince1970: TimeInterval(index))
            let sessionIDs = (0 ..< 10).map { sessionIndex in
                UUID(uuidString: String(
                    format: "00000000-0000-4000-8000-%012X",
                    index * 10 + sessionIndex + 1
                ))!
            }
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
                periodStart: date,
                periodEnd: date,
                sessionIDs: sessionIDs,
                measuredPebbleCount: 10,
                manualPebbleCount: 0,
                goldPebbleCount: 0,
                prismPebbleCount: 0
            )
            return PebbleDescriptor(
                id: UUID(uuidString: String(
                    format: "10000000-0000-4000-8000-%012X",
                    index + 1
                ))!,
                subjectName: "英語",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .normal,
                aggregate: metadata,
                grams: 10 * Constants.Mass.measuredPebbleGrams,
                radius: CGFloat(StrataMath.aggregateRadius(level: 1)),
                createdAt: date
            )
        }
    }

    @MainActor
    private func makeDropScene(reduceMotion: Bool) -> JarScene {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = reduceMotion
        return scene
    }

    private func makeAccountingAggregate(
        id: UUID = UUID(),
        createdAt: Date,
        level: Int,
        pebbleCount: Int,
        grams: Int? = nil,
        sessionIDs: [UUID] = [],
        childAggregateIDs: [UUID] = [],
        parentAggregateID: UUID? = nil
    ) -> AggregatePebble {
        AggregatePebble(
            id: id,
            createdAt: createdAt,
            level: level,
            pebbleCount: pebbleCount,
            childAggregateCount: childAggregateIDs.count,
            grams: grams ?? pebbleCount * Constants.Mass.measuredPebbleGrams,
            measuredPebbleCount: pebbleCount,
            colorMixJSON: "[]",
            periodStart: createdAt,
            periodEnd: createdAt,
            sessionIDs: sessionIDs,
            childAggregateIDs: childAggregateIDs,
            parentAggregateID: parentAggregateID
        )
    }

    private func makeLeafSource(
        index: Int,
        kind: PebbleKind = .normal
    ) -> AggregateSource {
        let date = Date(timeIntervalSince1970: Double(index))
        let id = UUID()
        return AggregateSource(
            id: id,
            grams: Constants.Mass.measuredPebbleGrams,
            radius: Double(Constants.Jar.measuredRadius),
            colorMix: [StratumColorFraction(hex: Constants.Color.english, fraction: 1)],
            subjectMix: [AggregateSubjectFraction(
                name: "英語",
                colorHex: Constants.Color.english,
                pebbleCount: 1
            )],
            periodStart: date,
            periodEnd: date,
            sessionIDs: [id],
            measuredPebbleCount: 1,
            manualPebbleCount: 0,
            goldPebbleCount: kind == .gold ? 1 : 0,
            prismPebbleCount: kind == .prism ? 1 : 0
        )
    }

    private func makeAggregateSource(_ calculation: AggregateCalculation) -> AggregateSource {
        AggregateSource(
            id: UUID(),
            level: calculation.level,
            pebbleCount: calculation.pebbleCount,
            childAggregateCount: calculation.childAggregateCount,
            grams: calculation.grams,
            radius: calculation.radius,
            colorMix: calculation.colorMix,
            subjectMix: calculation.subjectMix,
            periodStart: calculation.periodStart,
            periodEnd: calculation.periodEnd,
            sessionIDs: calculation.sessionIDs,
            measuredPebbleCount: calculation.measuredPebbleCount,
            manualPebbleCount: calculation.manualPebbleCount,
            goldPebbleCount: calculation.goldPebbleCount,
            prismPebbleCount: calculation.prismPebbleCount
        )
    }

    private func bodyCapacity(_ bodies: [AggregateSource]) -> Double {
        StrataMath.capacityUnits(pebbleRadii: bodies.map(\.radius))
    }

    @discardableResult
    private func combineFirstTen(
        level: Int,
        bodies: inout [AggregateSource]
    ) throws -> Bool {
        let indices = bodies.indices.filter { bodies[$0].level == level }
        guard indices.count >= Constants.Jar.aggregateFanIn else { return false }
        let selectedIndices = Array(indices.prefix(Constants.Jar.aggregateFanIn))
        let calculation = try XCTUnwrap(
            StrataMath.aggregate(sources: selectedIndices.map { bodies[$0] })
        )
        let selectedSet = Set(selectedIndices)
        bodies = bodies.indices
            .filter { !selectedSet.contains($0) }
            .map { bodies[$0] }
        bodies.append(makeAggregateSource(calculation))
        return true
    }

    private func carryDecimalHierarchy(bodies: inout [AggregateSource]) throws {
        while let level = Set(bodies.map(\.level))
            .filter({ $0 > 0 })
            .sorted()
            .first(where: {
                candidate in bodies.filter { $0.level == candidate }.count
                    >= Constants.Jar.aggregateFanIn
            }) {
            XCTAssertTrue(try combineFirstTen(level: level, bodies: &bodies))
        }
    }
}
