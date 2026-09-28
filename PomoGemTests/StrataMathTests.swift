import Metal
import SpriteKit
import XCTest
@testable import PomoGem

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

    func testLegacyClusterSummaryNormalizesOnlyItsStoredColorEvidence() {
        let summary = AccumulationClusterSummary(legacyStratum: JarStratumVisual(
            bakedAt: Date(timeIntervalSince1970: 10_000),
            pebbleCount: 20,
            grams: 5_000,
            height: 12,
            colorMix: [
                StratumColorFraction(hex: "#AA0000", fraction: 0.8),
                StratumColorFraction(hex: "#aa0000", fraction: 0.8),
                StratumColorFraction(hex: "#0000AA", fraction: 0.4),
                StratumColorFraction(hex: "#00AA00", fraction: -3)
            ],
            monthLabel: "2026年9月"
        ))

        XCTAssertEqual(summary.storage, .legacyStratum(hasSessionReferences: false))
        XCTAssertTrue(summary.usesCompatibilityPresentation)
        XCTAssertTrue(summary.canPresentStoredPeriod)
        XCTAssertFalse(summary.hasStrongPreservationEvidence)
        XCTAssertFalse(summary.hasCompleteSourceBreakdown)
        XCTAssertEqual(summary.colorMix.map(\.hex), ["#AA0000", "#0000AA"])
        XCTAssertEqual(summary.colorMix[0].fraction, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(summary.colorMix[1].fraction, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(
            summary.colorMix.reduce(0) { $0 + $1.fraction },
            1,
            accuracy: 0.000_001
        )
        XCTAssertTrue(summary.subjectMix.isEmpty)
        XCTAssertEqual(summary.measuredPebbleCount, 0)
        XCTAssertEqual(summary.manualPebbleCount, 0)
        XCTAssertEqual(summary.preservationTitle, "この粒に残っている情報")
        XCTAssertTrue(summary.preservationMessage.contains("色・粒数・質量"))
        XCTAssertTrue(summary.preservationMessage.contains("テーマ・入力方法・レア"))
        XCTAssertTrue(summary.preservationMessage.contains("元記録への参照が保存されていません"))

        let noColorSummary = AccumulationClusterSummary(
            legacyStratum: JarStratumVisual(
                pebbleCount: 4,
                grams: 1_000,
                height: 4,
                colorMix: [],
                monthLabel: ""
            )
        )
        XCTAssertTrue(noColorSummary.preservationMessage.contains("粒数・質量"))
        XCTAssertFalse(noColorSummary.preservationMessage.contains("色・粒数"))
    }

    func testUnattributedAggregateSummaryDoesNotClaimMissingBreakdowns() {
        let aggregate = AggregatePebble(
            level: 1,
            pebbleCount: 10,
            grams: 2_500,
            measuredPebbleCount: 10,
            colorMixJSON: "[]",
            subjectMixJSON: StrataMath.encodeSubjectMix([
                AggregateSubjectFraction(
                    name: "過去の集中",
                    colorHex: Constants.Color.english,
                    pebbleCount: 10
                )
            ]),
            periodStart: Date(timeIntervalSince1970: 9_000),
            periodEnd: Date(timeIntervalSince1970: 9_000)
        )
        let summary = AccumulationClusterSummary(
            aggregate: aggregate,
            sessionIDs: []
        )

        XCTAssertEqual(summary.storage, .aggregate(hasStoredLineage: false))
        XCTAssertTrue(summary.usesCompatibilityPresentation)
        XCTAssertFalse(summary.canPresentStoredPeriod)
        XCTAssertFalse(summary.hasStrongPreservationEvidence)
        XCTAssertFalse(
            summary.hasCompleteSourceBreakdown,
            "Compatibility counts must not be presented as a verified timer/manual split"
        )
        XCTAssertTrue(summary.colorMix.isEmpty)
        XCTAssertTrue(summary.subjectMix.isEmpty)
        XCTAssertEqual(summary.preservationTitle, "この粒に残っている情報")
        XCTAssertTrue(summary.preservationMessage.contains("一部の内訳がない場合があります"))
        XCTAssertFalse(summary.preservationMessage.contains("元の記録・色・テーマ"))

        let memberID = UUID()
        let attributed = AggregatePebble(
            level: 1,
            pebbleCount: 1,
            grams: 250,
            measuredPebbleCount: 1,
            colorMixJSON: StrataMath.encodeColorMix([
                StratumColorFraction(hex: Constants.Color.english, fraction: 1)
            ]),
            subjectMixJSON: StrataMath.encodeSubjectMix([
                AggregateSubjectFraction(
                    name: "英語",
                    colorHex: Constants.Color.english,
                    pebbleCount: 1
                )
            ]),
            periodStart: Date(timeIntervalSince1970: 9_000),
            periodEnd: Date(timeIntervalSince1970: 10_000),
            sessionIDs: [memberID]
        )
        let attributedSummary = AccumulationClusterSummary(
            aggregate: attributed,
            sessionIDs: [memberID]
        )
        XCTAssertEqual(
            attributedSummary.storage,
            .aggregate(hasStoredLineage: true)
        )
        XCTAssertTrue(attributedSummary.hasStrongPreservationEvidence)
        XCTAssertEqual(
            attributedSummary.preservationTitle,
            "まとまり化で情報は削除されません"
        )

        let partialThemeAggregate = AggregatePebble(
            level: 1,
            pebbleCount: 2,
            grams: 500,
            measuredPebbleCount: 2,
            colorMixJSON: StrataMath.encodeColorMix([
                StratumColorFraction(hex: Constants.Color.english, fraction: 1)
            ]),
            subjectMixJSON: StrataMath.encodeSubjectMix([
                AggregateSubjectFraction(
                    name: "英語",
                    colorHex: Constants.Color.english,
                    pebbleCount: 1
                )
            ]),
            periodStart: Date(timeIntervalSince1970: 9_000),
            periodEnd: Date(timeIntervalSince1970: 10_000),
            sessionIDs: [UUID(), UUID()]
        )
        let partialThemeSummary = AccumulationClusterSummary(
            aggregate: partialThemeAggregate,
            sessionIDs: []
        )
        XCTAssertFalse(partialThemeSummary.hasCompleteSubjectBreakdown)
        XCTAssertFalse(partialThemeSummary.hasStrongPreservationEvidence)
        XCTAssertEqual(
            partialThemeSummary.preservationTitle,
            "この粒に残っている情報"
        )

        let inconsistentColorAggregate = AggregatePebble(
            level: 1,
            pebbleCount: 2,
            grams: 500,
            measuredPebbleCount: 2,
            colorMixJSON: StrataMath.encodeColorMix([
                StratumColorFraction(hex: Constants.Color.english, fraction: 1)
            ]),
            subjectMixJSON: StrataMath.encodeSubjectMix([
                AggregateSubjectFraction(
                    name: "英語",
                    colorHex: Constants.Color.english,
                    pebbleCount: 1
                ),
                AggregateSubjectFraction(
                    name: "数学",
                    colorHex: Constants.Color.mathematics,
                    pebbleCount: 1
                )
            ]),
            periodStart: Date(timeIntervalSince1970: 9_000),
            periodEnd: Date(timeIntervalSince1970: 10_000),
            sessionIDs: [UUID(), UUID()]
        )
        let inconsistentColorSummary = AccumulationClusterSummary(
            aggregate: inconsistentColorAggregate,
            sessionIDs: []
        )
        XCTAssertTrue(inconsistentColorSummary.hasCompleteSubjectBreakdown)
        XCTAssertFalse(
            inconsistentColorSummary.hasConsistentColorAndSubjectBreakdowns
        )
        XCTAssertFalse(inconsistentColorSummary.hasStrongPreservationEvidence)

        let unverifiedParent = AggregatePebble(
            level: 2,
            pebbleCount: 10,
            childAggregateCount: 1,
            grams: 2_500,
            measuredPebbleCount: 10,
            colorMixJSON: StrataMath.encodeColorMix([
                StratumColorFraction(hex: Constants.Color.english, fraction: 1)
            ]),
            subjectMixJSON: StrataMath.encodeSubjectMix([
                AggregateSubjectFraction(
                    name: "英語",
                    colorHex: Constants.Color.english,
                    pebbleCount: 10
                )
            ]),
            periodStart: Date(timeIntervalSince1970: 9_000),
            periodEnd: Date(timeIntervalSince1970: 10_000),
            childAggregateIDs: [UUID()],
            projectionValidationVersion: 0
        )
        let unverifiedParentSummary = AccumulationClusterSummary(
            aggregate: unverifiedParent,
            sessionIDs: []
        )
        XCTAssertEqual(
            unverifiedParentSummary.storage,
            .aggregate(hasStoredLineage: false)
        )
        XCTAssertFalse(unverifiedParentSummary.canPresentStoredPeriod)
        XCTAssertTrue(unverifiedParentSummary.subjectMix.isEmpty)
        XCTAssertFalse(unverifiedParentSummary.hasStrongPreservationEvidence)
    }

    @MainActor
    func testLegacyStratumPresentationFingerprintTracksEveryDetailField() {
        let stratum = Stratum(
            bakedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            pebbleCount: 10,
            heightPt: 12,
            colorMixJSON: "[]",
            monthLabel: "2026年9月",
            grams: 2_500
        )

        var previous = LegacyStratumPresentationChangeFingerprint.value(for: stratum)
        stratum.grams = 2_501
        var current = LegacyStratumPresentationChangeFingerprint.value(for: stratum)
        XCTAssertNotEqual(current, previous)

        previous = current
        stratum.bakedAt = stratum.bakedAt.addingTimeInterval(1)
        current = LegacyStratumPresentationChangeFingerprint.value(for: stratum)
        XCTAssertNotEqual(current, previous)

        previous = current
        stratum.dataEpochID = UUID()
        current = LegacyStratumPresentationChangeFingerprint.value(for: stratum)
        XCTAssertNotEqual(current, previous)
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

    func testHistoryProjectionsExcludeUnsupportedSyncedSessionsBeforeAggregation() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        func timer(id: UUID = UUID()) -> StudySession {
            StudySession(
                id: id,
                startAt: end.addingTimeInterval(-1_500),
                endAt: end,
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "integrity-projection"
            )
        }

        let valid = timer()
        let overflow = timer()
        overflow.seconds = Int.max
        overflow.grams = Int.max
        let negative = timer()
        negative.seconds = -1
        negative.grams = -1
        let incoherentMass = timer()
        incoherentMass.seconds = 60
        incoherentMass.grams = 1_800
        let badDate = timer()
        badDate.startAt = badDate.endAt.addingTimeInterval(1)
        let values = [valid, overflow, negative, incoherentMass, badDate]

        XCTAssertEqual(StrataMath.totalGrams(sessions: values, strata: []), 250)
        XCTAssertEqual(StrataMath.totalPebbleCount(sessions: values, strata: []), 1)
        XCTAssertEqual(
            HomeProjectionPolicy.totals(roots: [], looseSessions: values),
            HomeProjectionPolicy.Totals(grams: 250, pebbleCount: 1)
        )
        XCTAssertEqual(
            ShareCardSelection.visibleLooseSessions(from: values, representedBy: [ShareStratumVisual]())
                .map(\.id),
            [valid.id]
        )

        let taintedStratum = Stratum(
            pebbleCount: 1,
            heightPt: 1,
            colorMixJSON: "[]",
            monthLabel: "unsupported",
            grams: Int.max,
            sessionIDs: [overflow.id]
        )
        XCTAssertEqual(
            StrataMath.totalGrams(sessions: values, strata: [taintedStratum]),
            250
        )
        XCTAssertEqual(
            StrataMath.totalPebbleCount(sessions: values, strata: [taintedStratum]),
            1
        )

        let taintedLeaf = AggregatePebble(
            level: 1,
            pebbleCount: 1,
            grams: Int.max,
            measuredPebbleCount: 1,
            manualPebbleCount: 0,
            colorMixJSON: "[]",
            periodStart: overflow.startAt,
            periodEnd: overflow.endAt,
            sessionIDs: [overflow.id]
        )
        let taintedParent = AggregatePebble(
            level: 2,
            pebbleCount: 1,
            childAggregateCount: 1,
            grams: Int.max,
            measuredPebbleCount: 1,
            manualPebbleCount: 0,
            colorMixJSON: "[]",
            periodStart: overflow.startAt,
            periodEnd: overflow.endAt,
            childAggregateIDs: [taintedLeaf.id]
        )
        taintedLeaf.parentAggregateID = taintedParent.id
        XCTAssertEqual(
            StrataMath.totalGrams(
                sessions: values,
                aggregates: [taintedLeaf, taintedParent]
            ),
            250
        )
        XCTAssertEqual(
            StrataMath.totalPebbleCount(
                sessions: values,
                aggregates: [taintedLeaf, taintedParent]
            ),
            1
        )
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
        XCTAssertFalse(request.outputDescriptor.accessibilityDescription.contains("虹2粒"))
        XCTAssertTrue(
            request.outputDescriptor.aggregate?
                .accessibilityDescription(presentsRareRewards: true)
                .contains("虹2粒") == true
        )
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
        let base = Date.now.addingTimeInterval(-200_000)
        for group in 0..<10 {
            let members = (0..<10).map { index -> StudySession in
                let offset = Double((group * 10 + index) * 1_500)
                let sessionStart = base.addingTimeInterval(offset)
                let session = StudySession(
                    id: UUID(),
                    startAt: sessionStart,
                    endAt: sessionStart.addingTimeInterval(1_500),
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
        let base = Date.now.addingTimeInterval(-30_000)
        let sessions = (0..<11).map { index in
            let sessionStart = base.addingTimeInterval(Double(index * 1_500))
            return StudySession(
                id: UUID(),
                startAt: sessionStart,
                endAt: sessionStart.addingTimeInterval(1_500),
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
    func testReduceMotionFinishesFormationOnceAndKeepsAggregatePhysics() async throws {
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
        XCTAssertEqual(scene.physicalPebbleCount, 0)
        XCTAssertTrue(deliveredRequestIDs.isEmpty)

        scene.reduceMotion = true

        XCTAssertFalse(scene.isBakeInProgress)
        XCTAssertEqual(deliveredRequestIDs.count, 1)
        XCTAssertEqual(scene.physicalPebbleCount, 1)
        XCTAssertEqual(scene.representedPebbleCount, 100)
        let aggregate = try XCTUnwrap(scene.childNode(withName: "//pebble.*") as? PebbleNode)
        let body = try XCTUnwrap(aggregate.physicsBody)
        XCTAssertTrue(body.isDynamic)
        XCTAssertFalse(body.isResting)
        XCTAssertEqual(body.velocity.dx, 0, accuracy: 0.001)
        XCTAssertEqual(body.velocity.dy, Constants.Jar.aggregateBirthImpulse, accuracy: 0.001)
        XCTAssertEqual(body.angularVelocity, 0, accuracy: 0.001)
        XCTAssertFalse(aggregate.hasActions())

        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(
            deliveredRequestIDs.count,
            1,
            "The old animation deadline must not commit the transaction twice"
        )
        XCTAssertEqual(scene.physicalPebbleCount, 1)
        XCTAssertEqual(scene.representedPebbleCount, 100)
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
    func testSameIDAggregateRepairRefreshesOnlyItsPhysicalPresentation() throws {
        let updatedID = UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!
        let stableID = UUID(uuidString: "A1000000-0000-4000-8000-000000000002")!
        let updated = makeStoredSceneAggregate(
            id: updatedID,
            colorHex: Constants.Color.english,
            pebbleCount: 10,
            grams: 2_500
        )
        let stable = makeStoredSceneAggregate(
            id: stableID,
            colorHex: Constants.Color.science,
            pebbleCount: 10,
            grams: 2_500
        )
        let scene = makeDropScene(reduceMotion: false)
        scene.configureAggregates([updated, stable])

        let oldUpdatedNode = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(updatedID.uuidString)"
        ) as? PebbleNode)
        let stableNode = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(stableID.uuidString)"
        ) as? PebbleNode)
        oldUpdatedNode.position = CGPoint(x: 110, y: 120)
        stableNode.position = CGPoint(x: 270, y: 120)
        oldUpdatedNode.physicsBody?.velocity = CGVector(dx: 7, dy: 9)
        let stablePosition = stableNode.position
        let revision = scene.physicalContentRevision

        updated.level = 2
        updated.pebbleCount = 100
        updated.grams = 30_000
        updated.measuredPebbleCount = 100
        updated.colorMixJSON = StrataMath.encodeColorMix([
            StratumColorFraction(hex: Constants.Color.mathematics, fraction: 1)
        ])
        updated.subjectMixJSON = StrataMath.encodeSubjectMix([
            AggregateSubjectFraction(
                name: "数学",
                colorHex: Constants.Color.mathematics,
                pebbleCount: 100
            )
        ])

        scene.configureAggregates([updated, stable])

        let refreshedNode = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(updatedID.uuidString)"
        ) as? PebbleNode)
        let untouchedNode = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(stableID.uuidString)"
        ) as? PebbleNode)
        let refreshedBody = try XCTUnwrap(refreshedNode.physicsBody)
        XCTAssertFalse(refreshedNode === oldUpdatedNode)
        XCTAssertTrue(untouchedNode === stableNode)
        XCTAssertEqual(untouchedNode.position.x, stablePosition.x, accuracy: 0.001)
        XCTAssertEqual(untouchedNode.position.y, stablePosition.y, accuracy: 0.001)
        XCTAssertEqual(refreshedNode.position.x, 110, accuracy: 0.001)
        XCTAssertEqual(refreshedNode.position.y, 120, accuracy: 0.001)
        XCTAssertEqual(refreshedNode.descriptor.aggregate?.pebbleCount, 100)
        XCTAssertEqual(refreshedNode.descriptor.colorHex, Constants.Color.mathematics)
        XCTAssertEqual(refreshedNode.descriptor.grams, 30_000)
        XCTAssertGreaterThan(refreshedNode.radius, oldUpdatedNode.radius)
        XCTAssertEqual(refreshedBody.velocity.dx, 7, accuracy: 0.001)
        XCTAssertEqual(refreshedBody.velocity.dy, 9, accuracy: 0.001)
        XCTAssertEqual(scene.physicalPebbleCount, 2)
        XCTAssertEqual(scene.representedPebbleCount, 110)
        XCTAssertGreaterThan(scene.physicalContentRevision, revision)
    }

    @MainActor
    func testSameIDAggregateRepairPreservesPhysicsWithReduceMotion() throws {
        let id = UUID(uuidString: "A2000000-0000-4000-8000-000000000001")!
        let aggregate = makeStoredSceneAggregate(
            id: id,
            colorHex: Constants.Color.english,
            pebbleCount: 10,
            grams: 2_500
        )
        let scene = makeDropScene(reduceMotion: true)
        scene.configureAggregates([aggregate])
        let originalNode = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(id.uuidString)"
        ) as? PebbleNode)
        originalNode.physicsBody?.velocity = CGVector(dx: 7, dy: 9)
        originalNode.physicsBody?.angularVelocity = 1.5
        aggregate.grams = 3_200
        aggregate.colorMixJSON = StrataMath.encodeColorMix([
            StratumColorFraction(hex: Constants.Color.science, fraction: 1)
        ])

        scene.configureAggregates([aggregate])

        let refreshedNode = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(id.uuidString)"
        ) as? PebbleNode)
        let body = try XCTUnwrap(refreshedNode.physicsBody)
        XCTAssertEqual(refreshedNode.descriptor.grams, 3_200)
        XCTAssertEqual(refreshedNode.descriptor.colorHex, Constants.Color.science)
        XCTAssertTrue(body.isDynamic)
        XCTAssertEqual(body.velocity.dx, 7, accuracy: 0.001)
        XCTAssertEqual(body.velocity.dy, 9, accuracy: 0.001)
        XCTAssertEqual(body.angularVelocity, 1.5, accuracy: 0.001)
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

    func testMotionUpdateGateAcceptsGravityRegardlessOfReduceMotion() {
        var gate = JarMotionUpdateGate()
        let firstGeneration = gate.begin()
        XCTAssertTrue(gate.accepts(firstGeneration))
        XCTAssertTrue(gate.acceptsGravity(firstGeneration, reduceMotion: false))
        XCTAssertTrue(gate.acceptsGravity(firstGeneration, reduceMotion: true))

        gate.invalidate()
        XCTAssertFalse(gate.accepts(firstGeneration))
        XCTAssertFalse(gate.acceptsGravity(firstGeneration, reduceMotion: false))

        let secondGeneration = gate.begin()
        XCTAssertNotEqual(firstGeneration, secondGeneration)
        XCTAssertFalse(
            gate.accepts(firstGeneration),
            "A queued task from an older run must not apply after restart"
        )
        XCTAssertTrue(gate.accepts(secondGeneration))
        XCTAssertTrue(gate.acceptsGravity(secondGeneration, reduceMotion: false))
    }

    func testJarMotionActivationRequiresOneVisibleActiveJarWithStudyGems() {
        XCTAssertTrue(JarMotionActivationPolicy.shouldRun(
            isMotionEnabled: true,
            reduceMotion: false,
            sceneIsActive: true,
            hasStudyGems: true
        ))
        XCTAssertFalse(JarMotionActivationPolicy.shouldRun(
            isMotionEnabled: false,
            reduceMotion: false,
            sceneIsActive: true,
            hasStudyGems: true
        ))
        XCTAssertTrue(JarMotionActivationPolicy.shouldRun(
            isMotionEnabled: true,
            reduceMotion: true,
            sceneIsActive: true,
            hasStudyGems: true
        ))
        XCTAssertEqual(JarMotionActivationPolicy.mode(
            isMotionEnabled: true,
            reduceMotion: true,
            sceneIsActive: true,
            hasStudyGems: true
        ), .tiltAndShake)
        XCTAssertEqual(JarMotionActivationPolicy.mode(
            isMotionEnabled: true,
            reduceMotion: false,
            sceneIsActive: true,
            hasStudyGems: true
        ), .tiltAndShake)
        XCTAssertFalse(JarMotionActivationPolicy.shouldRun(
            isMotionEnabled: true,
            reduceMotion: false,
            sceneIsActive: false,
            hasStudyGems: true
        ))
        XCTAssertFalse(JarMotionActivationPolicy.shouldRun(
            isMotionEnabled: true,
            reduceMotion: false,
            sceneIsActive: true,
            hasStudyGems: false
        ))
        XCTAssertTrue(JarMotionActivationPolicy.shouldCaptureShake(
            isMotionEnabled: true,
            sceneIsActive: true,
            hasPhysicalContent: true
        ))
        XCTAssertFalse(JarMotionActivationPolicy.shouldCaptureShake(
            isMotionEnabled: true,
            sceneIsActive: false,
            hasPhysicalContent: true
        ))
    }

    func testTransientMotionGateInvalidatesScheduledTapWorkSynchronously() {
        var gate = JarTransientMotionGate()
        let tapGeneration = gate.begin()
        XCTAssertTrue(gate.accepts(tapGeneration))

        gate.invalidate()
        XCTAssertFalse(gate.accepts(tapGeneration))

        let nextTapGeneration = gate.begin()
        XCTAssertNotEqual(tapGeneration, nextTapGeneration)
        XCTAssertFalse(gate.accepts(tapGeneration))
        XCTAssertTrue(gate.accepts(nextTapGeneration))
    }

    func testInteractionMotionWindowUsesBoundedMonotonicDeadlines() {
        let window = JarInteractionMotionWindow(
            openedAt: 10,
            settleDelay: 3,
            hardStopDelay: 5
        )

        XCTAssertEqual(window.openedAt, 10)
        XCTAssertEqual(window.settleAt, 13)
        XCTAssertEqual(window.hardStopAt, 15)
        XCTAssertFalse(window.canSettle(at: 12.999))
        XCTAssertTrue(window.canSettle(at: 13))
        XCTAssertFalse(window.mustStop(at: 14.999))
        XCTAssertTrue(window.mustStop(at: 15))
    }

    func testInteractionMotionWindowFailSoftsMalformedDurations() {
        let malformed = JarInteractionMotionWindow(
            openedAt: .nan,
            settleDelay: -.infinity,
            hardStopDelay: .nan
        )
        XCTAssertEqual(malformed.openedAt, 0)
        XCTAssertEqual(malformed.settleAt, 0)
        XCTAssertEqual(malformed.hardStopAt, 0)
        XCTAssertFalse(malformed.canSettle(at: .nan))
        XCTAssertFalse(malformed.mustStop(at: .infinity))

        let reversed = JarInteractionMotionWindow(
            openedAt: 7,
            settleDelay: 4,
            hardStopDelay: 1
        )
        XCTAssertEqual(reversed.settleAt, 11)
        XCTAssertEqual(
            reversed.hardStopAt,
            reversed.settleAt,
            "The hard stop may never precede the natural-settling deadline"
        )
    }

    func testTapLaunchPlanTargetsThreeDiametersAndCapsHeavyGemTravel() {
        let standardRadius = Constants.Jar.measuredRadius
        let standard = JarTapLaunchPolicy.plan(
            radius: standardRadius,
            strength: 1,
            upwardRoom: 400
        )
        XCTAssertEqual(
            standard.targetTravel,
            standardRadius * 2 * JarTapLaunchPolicy.targetDiameterMultiplier,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(standard.verticalVelocity, 200)
        XCTAssertGreaterThan(standard.horizontalVelocity, 80)
        XCTAssertGreaterThan(standard.returnVelocity, 180)

        let heavy = JarTapLaunchPolicy.plan(
            radius: Constants.Jar.aggregateMaximumRadius,
            strength: 1,
            upwardRoom: 400
        )
        XCTAssertEqual(
            heavy.targetTravel,
            JarTapLaunchPolicy.maximumTargetTravel,
            accuracy: 0.001
        )
        XCTAssertLessThan(
            heavy.targetTravel,
            Constants.Jar.aggregateMaximumRadius * 2
                * JarTapLaunchPolicy.targetDiameterMultiplier,
            "A large aggregate should retain visible weight instead of crossing most of the jar"
        )

        let cramped = JarTapLaunchPolicy.plan(
            radius: standardRadius,
            strength: 1,
            upwardRoom: 17
        )
        XCTAssertEqual(cramped.targetTravel, 17, accuracy: 0.001)
        XCTAssertTrue(cramped.verticalVelocity.isFinite)
        XCTAssertTrue(cramped.horizontalVelocity.isFinite)
        XCTAssertTrue(cramped.returnVelocity.isFinite)
    }

    func testTapLaunchPlanFailSoftsMalformedInputs() {
        let plan = JarTapLaunchPolicy.plan(
            radius: .nan,
            strength: .infinity,
            upwardRoom: -.infinity
        )
        XCTAssertEqual(plan.targetTravel, 0)
        XCTAssertEqual(plan.verticalVelocity, 0)
        XCTAssertEqual(plan.horizontalVelocity, 0)
        XCTAssertEqual(plan.returnVelocity, 0)
    }

    func testNudgeRateLimiterRejectsRepeatAndNonmonotonicInput() {
        var limiter = JarGestureRateLimiter()
        XCTAssertTrue(limiter.accepts(uptime: 10, cooldown: 0.45))
        XCTAssertFalse(limiter.accepts(uptime: 10.44, cooldown: 0.45))
        XCTAssertTrue(limiter.accepts(uptime: 10.46, cooldown: 0.45))
        XCTAssertFalse(limiter.accepts(uptime: 9, cooldown: 0.45))
        XCTAssertFalse(limiter.accepts(uptime: .nan, cooldown: 0.45))
    }

    func testShakeVelocityPolicyClampsAndPreservesMassWeighting() {
        let impulse = CGVector(dx: 12, dy: 8)
        let small = JarShakeVelocityPolicy.velocity(
            current: .zero,
            impulse: impulse,
            mass: 1,
            maximumHorizontalVelocity: 20,
            maximumVerticalVelocity: 20
        )
        let large = JarShakeVelocityPolicy.velocity(
            current: .zero,
            impulse: impulse,
            mass: 4,
            maximumHorizontalVelocity: 20,
            maximumVerticalVelocity: 20
        )
        XCTAssertGreaterThan(hypot(small.dx, small.dy), hypot(large.dx, large.dy))

        let clamped = JarShakeVelocityPolicy.velocity(
            current: CGVector(dx: 100, dy: -100),
            impulse: .zero,
            mass: 1,
            maximumHorizontalVelocity: 12,
            maximumVerticalVelocity: 14
        )
        XCTAssertEqual(clamped.dx, 12, accuracy: 0.001)
        XCTAssertEqual(clamped.dy, -14, accuracy: 0.001)
    }

    func testInteractionCollisionBudgetIsBoundedToGestureWindow() {
        var budget = JarInteractionCollisionBudget()
        XCTAssertFalse(budget.isOpen(uptime: 10), "Passive contacts have no budget")

        budget.begin(
            uptime: 10,
            muteDuration: 0.20,
            followUpDuration: 0.80,
            soundLimit: 2,
            hapticLimit: 1
        )
        XCTAssertEqual(
            budget.consume(uptime: 10.19, soundReady: true, hapticReady: true),
            JarInteractionCollisionDecision(playSound: false, playHaptic: false)
        )
        XCTAssertEqual(
            budget.consume(uptime: 10.20, soundReady: true, hapticReady: true),
            JarInteractionCollisionDecision(playSound: true, playHaptic: true)
        )
        XCTAssertEqual(
            budget.consume(uptime: 10.40, soundReady: true, hapticReady: true),
            JarInteractionCollisionDecision(playSound: true, playHaptic: false)
        )
        XCTAssertEqual(
            budget.consume(uptime: 10.60, soundReady: true, hapticReady: true),
            JarInteractionCollisionDecision(playSound: false, playHaptic: false)
        )
        XCTAssertFalse(budget.isOpen(uptime: 10.81))

        budget.cancel()
        XCTAssertFalse(budget.isOpen(uptime: 10.50))
    }

    func testJarSensoryPlanMakesPhysicalAbundanceDenseButBounded() throws {
        let sample = JarSensorySample(radius: 11.5, coupling: 1)
        let one = JarSensoryPolicy.plan(
            trigger: .tap,
            samples: [sample],
            gestureStrength: 0.9,
            abundanceCount: 1,
            seed: 42
        )
        let many = JarSensoryPolicy.plan(
            trigger: .tap,
            samples: [sample],
            gestureStrength: 0.9,
            abundanceCount: 64,
            seed: 42
        )
        let shaken = JarSensoryPolicy.plan(
            trigger: .shake,
            samples: Array(repeating: sample, count: Constants.Jar.maxPhysicsBodies),
            gestureStrength: 1,
            abundanceCount: Constants.Jar.maxPhysicsBodies,
            seed: 42
        )

        XCTAssertEqual(one.clinks.count, 1)
        XCTAssertGreaterThan(many.clinks.count, one.clinks.count)
        XCTAssertLessThanOrEqual(many.clinks.count, 4)
        XCTAssertLessThanOrEqual(many.hapticPulses.count, 3)
        XCTAssertLessThanOrEqual(shaken.clinks.count, 6)
        XCTAssertLessThanOrEqual(shaken.hapticPulses.count, 4)
        XCTAssertLessThan(many.soundCooldown, one.soundCooldown)
        XCTAssertTrue(shaken.clinks.allSatisfy {
            $0.delay.isFinite && (0 ... 0.20).contains($0.delay)
                && $0.pitchRate.isFinite && (0.50 ... 1.75).contains($0.pitchRate)
                && $0.gain.isFinite && (0 ... 0.52).contains($0.gain)
        })
        let squaredGain = shaken.clinks.reduce(0.0) {
            $0 + Double($1.gain * $1.gain)
        }
        XCTAssertLessThanOrEqual(squaredGain, 0.52 * 0.52 + 0.000_01)
    }

    func testJarSensoryPlanMakesLargeGemLowerAndHeavier() throws {
        let small = JarSensoryPolicy.plan(
            trigger: .tap,
            samples: [JarSensorySample(radius: 8, coupling: 1)],
            gestureStrength: 0.85,
            seed: 7
        )
        let large = JarSensoryPolicy.plan(
            trigger: .tap,
            samples: [JarSensorySample(radius: 28, coupling: 1)],
            gestureStrength: 0.85,
            seed: 7
        )

        XCTAssertLessThan(
            try XCTUnwrap(large.clinks.first).pitchRate,
            try XCTUnwrap(small.clinks.first).pitchRate
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(large.hapticPulses.first).intensity,
            try XCTUnwrap(small.hapticPulses.first).intensity
        )
        XCTAssertLessThan(
            try XCTUnwrap(large.hapticPulses.first).sharpness,
            try XCTUnwrap(small.hapticPulses.first).sharpness
        )
        XCTAssertNil(small.rumble)
        XCTAssertNotNil(large.rumble)
    }

    func testJarSensoryPlanIsDeterministicAndRejectsInvalidInput() {
        let input = [
            JarSensorySample(radius: 11.5, coupling: 1),
            JarSensorySample(radius: 28, coupling: 0.7)
        ]
        let first = JarSensoryPolicy.plan(
            trigger: .shake,
            samples: input,
            gestureStrength: 0.8,
            abundanceCount: 18,
            seed: 9_001
        )
        let second = JarSensoryPolicy.plan(
            trigger: .shake,
            samples: input,
            gestureStrength: 0.8,
            abundanceCount: 18,
            seed: 9_001
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            JarSensoryPolicy.plan(
                trigger: .tap,
                samples: [],
                gestureStrength: 1,
                seed: 1
            ),
            .silent
        )
        XCTAssertEqual(
            JarSensoryPolicy.plan(
                trigger: .tap,
                samples: [JarSensorySample(radius: .nan, coupling: 1)],
                gestureStrength: 1,
                seed: 1
            ),
            .silent
        )
        XCTAssertEqual(
            JarSensoryPolicy.plan(
                trigger: .tap,
                samples: input,
                gestureStrength: .infinity,
                seed: 1
            ),
            .silent
        )
    }

    func testShakeDetectorRequiresOpposingPeaksAndRateLimitsHapticEcho() throws {
        var detector = JarShakeDetector()
        XCTAssertNil(detector.ingest(x: 0.2, y: 0.1, z: 0, uptime: 1.0))
        XCTAssertNil(detector.ingest(x: 1.5, y: 0, z: 0, uptime: 1.1))
        XCTAssertNil(
            detector.ingest(x: 1.6, y: 0.1, z: 0, uptime: 1.2),
            "A stronger peak in the same direction is not a shake by itself"
        )
        let event = try XCTUnwrap(
            detector.ingest(x: -1.7, y: 0, z: 0, uptime: 1.36)
        )
        XCTAssertTrue((0.35 ... 1).contains(event.strength))
        XCTAssertEqual(event.horizontalDirection, -1, accuracy: 0.001)
        XCTAssertFalse(detector.isArmed)

        XCTAssertNil(
            detector.ingest(x: 1.8, y: 0, z: 0, uptime: 1.45),
            "The haptic generated by a shake cannot immediately retrigger it"
        )
        XCTAssertNil(detector.ingest(x: 0.1, y: 0, z: 0, uptime: 2.20))
        XCTAssertNil(detector.ingest(x: 0.1, y: 0, z: 0, uptime: 2.36))
        XCTAssertTrue(detector.isArmed)
        XCTAssertNil(detector.ingest(x: 1.5, y: 0, z: 0, uptime: 2.40))
        XCTAssertNotNil(detector.ingest(x: -1.5, y: 0, z: 0, uptime: 2.58))
    }

    func testShakeDetectorRecognizesAComfortableLightBackAndForthGesture() {
        var detector = JarShakeDetector()
        XCTAssertNil(detector.ingest(x: 0.96, y: 0.05, z: 0, uptime: 1.0))
        XCTAssertNotNil(
            detector.ingest(x: -0.98, y: -0.04, z: 0, uptime: 1.36),
            "A deliberate light shake must not require a forceful 1.35g snap"
        )
    }

    func testShakeDetectorRejectsSingleBumpExpiredPeakAndNonfiniteInput() {
        var detector = JarShakeDetector()
        XCTAssertNil(detector.ingest(x: .nan, y: 0, z: 0, uptime: 1))
        XCTAssertNil(detector.ingest(x: 1.8, y: 0, z: 0, uptime: 2))
        XCTAssertNil(
            detector.ingest(x: -1.8, y: 0, z: 0, uptime: 2.5),
            "Opposing peaks outside the reversal window are separate bumps"
        )
    }

    func testShakeDetectorPreservesExternalHapticSuppressionAcrossReset() {
        var detector = JarShakeDetector()
        detector.suppress(until: 5)
        detector.reset()

        XCTAssertNil(detector.ingest(x: 1.8, y: 0, z: 0, uptime: 4.7))
        XCTAssertNil(detector.ingest(x: -1.8, y: 0, z: 0, uptime: 4.9))
        XCTAssertNil(detector.ingest(x: 1.8, y: 0, z: 0, uptime: 5.01))
        XCTAssertNotNil(detector.ingest(x: -1.8, y: 0, z: 0, uptime: 5.20))
    }

    @MainActor
    func testReduceMotionTogglePreservesLiveGravity() {
        let scene = JarScene()
        let gravity = CGVector(dx: 2.4, dy: -5)
        scene.setGravityVector(gravity, smoothing: false)

        for reduceMotion in [true, false] {
            scene.reduceMotion = reduceMotion
            XCTAssertEqual(scene.appliedGravityVector.dx, gravity.dx, accuracy: 0.001)
            XCTAssertEqual(scene.appliedGravityVector.dy, gravity.dy, accuracy: 0.001)
        }
    }

    @MainActor
    func testReduceMotionTogglePreservesActiveTapFlightAndAccounting() throws {
        let descriptor = PebbleDescriptor(
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            grams: Constants.Mass.measuredPebbleGrams
        )
        let scene = makeDropScene(reduceMotion: false)
        var landingIDs: [UUID] = []
        scene.onLanding = { landingIDs.append($0.pebble.id) }
        scene.restore(pebbles: [descriptor])
        let node = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(descriptor.id.uuidString)"
        ) as? PebbleNode)
        let body = try XCTUnwrap(node.physicsBody)
        node.position = CGPoint(x: 195, y: 90)
        XCTAssertTrue(scene.bouncePebbles(at: node.position))
        let position = node.position
        let velocity = body.velocity
        let angularVelocity = body.angularVelocity
        let damping = body.linearDamping
        let revision = scene.physicalContentRevision
        XCTAssertGreaterThan(velocity.dy, 200)

        for reduceMotion in [true, false] {
            scene.reduceMotion = reduceMotion
            XCTAssertEqual(scene.activeTapMotionPebbleID, descriptor.id)
            XCTAssertEqual(scene.activeTapDrivenBodyCount, 1)
            XCTAssertTrue(scene.isInteractionMotionActive)
            XCTAssertTrue(body.isDynamic)
            XCTAssertFalse(body.isResting)
            XCTAssertTrue(body.usesPreciseCollisionDetection)
            XCTAssertEqual(node.position.x, position.x, accuracy: 0.001)
            XCTAssertEqual(node.position.y, position.y, accuracy: 0.001)
            XCTAssertEqual(body.velocity.dx, velocity.dx, accuracy: 0.001)
            XCTAssertEqual(body.velocity.dy, velocity.dy, accuracy: 0.001)
            XCTAssertEqual(body.angularVelocity, angularVelocity, accuracy: 0.001)
            XCTAssertEqual(body.linearDamping, damping, accuracy: 0.001)
            XCTAssertEqual(scene.physicalContentRevision, revision)
            XCTAssertEqual(scene.physicalPebbleCount, 1)
            XCTAssertEqual(scene.representedPebbleCount, 1)
            XCTAssertTrue(landingIDs.isEmpty, "Motion preferences must never mint study records")
        }
    }

    @MainActor
    func testReduceMotionFusionAggregateKeepsBirthBounceAndStaticAura() throws {
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
        XCTAssertFalse(pebble.hasLanded)
        XCTAssertGreaterThanOrEqual(
            pebble.position.y,
            Constants.Jar.floorInset + output.radius
        )
        XCTAssertEqual(body.velocity.dx, 0, accuracy: 0.001)
        XCTAssertEqual(body.velocity.dy, Constants.Jar.aggregateBirthImpulse, accuracy: 0.001)
        XCTAssertEqual(body.angularVelocity, 0, accuracy: 0.001)
        XCTAssertFalse(body.isResting)
        XCTAssertTrue(body.isDynamic)
        XCTAssertNotNil(pebble.childNode(withName: "aggregate.aura"))
        XCTAssertNil(
            pebble.childNode(withName: "aggregate.aura")?
                .action(forKey: "aggregate.aura.breath")
        )
    }

    @MainActor
    func testLooseAndAggregateDropsKeepFallingLaunchRegardlessOfReduceMotion() throws {
        for reduceMotion in [false, true] {
            let loose = PebbleDescriptor(
                subjectName: "資格",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams
            )
            let aggregate = try XCTUnwrap(makeSceneAggregateDescriptors().first)

            for descriptor in [loose, aggregate] {
                let scene = makeDropScene(reduceMotion: reduceMotion)
                scene.drop(descriptor)
                scene.update(0)

                let pebble = try XCTUnwrap(scene.childNode(
                    withName: "//pebble.\(descriptor.id.uuidString)"
                ) as? PebbleNode)
                let body = try XCTUnwrap(pebble.physicsBody)
                XCTAssertFalse(pebble.hasLanded)
                // Just under the mouth at the size it is shown (the jar-wide
                // scale of D4 enlarges a gem in an empty jar).
                XCTAssertEqual(
                    pebble.position.y,
                    Constants.Jar.height - Constants.Jar.wallInset - pebble.radius,
                    accuracy: 0.001
                )
                XCTAssertEqual(pebble.radius, descriptor.radius * pebble.jarScale, accuracy: 0.001)
                XCTAssertEqual(
                    body.velocity.dy,
                    Constants.Jar.dropVerticalSpeed,
                    accuracy: 0.001
                )
                XCTAssertFalse(body.isResting)
                XCTAssertTrue(body.isDynamic)
                if reduceMotion {
                    let auraName = descriptor.isAggregate ? "aggregate.aura" : "pebble.earlyEffortAura"
                    let aura = try XCTUnwrap(pebble.childNode(withName: auraName))
                    XCTAssertFalse(aura.hasActions(), "Decorative highlights remain static with Reduce Motion")
                }
                XCTAssertEqual(scene.completionDropSequence, 0)
                XCTAssertFalse(scene.hasCompletionDropInFlight)
            }
        }
    }

    @MainActor
    func testCompletionDropEntersVisibleTopEdgeAndSurvivesResizeWithoutFalseTravel() throws {
        for reduceMotion in [false, true] {
            let descriptor = PebbleDescriptor(
                subjectName: "資格",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams
            )
            let scene = makeDropScene(reduceMotion: reduceMotion)
            var landingIDs: [UUID] = []
            scene.onLanding = { landingIDs.append($0.pebble.id) }

            scene.dropFromAbove(descriptor)
            scene.dropFromAbove(descriptor)
            XCTAssertEqual(scene.queuedDropCount, 1)
            XCTAssertTrue(scene.hasCompletionDropInFlight)
            XCTAssertEqual(scene.completionDropSequence, 0, "Enqueueing is not visible travel")
            scene.update(0)

            let pebble = try XCTUnwrap(scene.childNode(
                withName: "//pebble.\(descriptor.id.uuidString)"
            ) as? PebbleNode)
            let body = try XCTUnwrap(pebble.physicsBody)
            XCTAssertEqual(pebble.position.y, scene.size.height, accuracy: 0.001)
            XCTAssertLessThan(pebble.position.y - pebble.radius, scene.size.height)
            XCTAssertGreaterThan(pebble.position.y + pebble.radius, scene.size.height)
            XCTAssertEqual(pebble.position.x, scene.size.width / 2, accuracy: 0.001)
            XCTAssertEqual(body.velocity.dx, 0, accuracy: 0.001)
            XCTAssertLessThan(body.velocity.dy, 0)
            XCTAssertEqual(body.categoryBitMask & JarPhysicsCategory.pebble, 0)
            XCTAssertEqual(body.collisionBitMask & JarPhysicsCategory.wall, 0)
            XCTAssertFalse(pebble.hasLanded)
            XCTAssertFalse(scene.hasLandedPebble(withID: descriptor.id))
            XCTAssertEqual(scene.completionDropSequence, 1)
            XCTAssertTrue(scene.hasCompletionDropInFlight)

            scene.size = CGSize(width: 320, height: 380)
            scene.didSimulatePhysics()
            XCTAssertEqual(pebble.position.y, 380, accuracy: 0.001)
            // Independently compute the inner neck edges, including the body's
            // radius, so a responsive rebuild cannot spawn it against a wall.
            let outer = scene.snapshotRect
            let neckInset = min(50, outer.width * 0.14)
            XCTAssertGreaterThanOrEqual(
                pebble.position.x - pebble.radius,
                outer.minX + neckInset + Constants.Jar.wallInset
            )
            XCTAssertLessThanOrEqual(
                pebble.position.x + pebble.radius,
                outer.maxX - neckInset - Constants.Jar.wallInset
            )
            XCTAssertEqual(scene.completionDropMaximumFall, 0, accuracy: 0.001)
            XCTAssertFalse(scene.completionDropHasLanded)
            XCTAssertTrue(landingIDs.isEmpty)
            scene.dropFromAbove(descriptor)
            XCTAssertEqual(scene.queuedDropCount, 0)
            XCTAssertEqual(scene.physicalPebbleCount, 1)
        }
    }

    @MainActor
    func testCompletionDropFallsThroughNeckAndReportsOneLandingOnSpriteKitRenderLoop() throws {
        for reduceMotion in [false, true] {
            let descriptor = PebbleDescriptor(
                subjectName: "資格",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams
            )
            let scene = makeDropScene(reduceMotion: reduceMotion)
            var landingIDs: [UUID] = []
            var landingObservedCompletedPresentation = false
            scene.onLanding = { [weak scene] in
                landingIDs.append($0.pebble.id)
                landingObservedCompletedPresentation = scene?.completionDropHasLanded == true
                    && scene?.hasCompletionDropInFlight == false
            }
            let device = try XCTUnwrap(
                MTLCreateSystemDefaultDevice(),
                "The SpriteKit renderer needs a Metal device to drive its scene update cycle"
            )
            let renderer = SKRenderer(device: device)
            let expectedSize = scene.size
            // A renderer without a viewport must retain the fixture's dimensions.
            // resizeFill would resize the jar and its floor to a zero-sized target.
            scene.scaleMode = .aspectFit
            renderer.scene = scene
            defer {
                scene.onLanding = nil
                renderer.scene = nil
            }
            // SKRenderer has no SKView mount callback. Build the empty scene's
            // size-dependent walls and floor through its existing lifecycle hook.
            scene.didChangeSize(.zero)
            let startTime = ProcessInfo.processInfo.systemUptime
            let frameInterval: TimeInterval = 1.0 / 60.0
            renderer.update(atTime: startTime)
            XCTAssertEqual(scene.size, expectedSize)
            scene.dropFromAbove(descriptor)
            var frame = 1
            renderer.update(atTime: startTime + Double(frame) * frameInterval)
            let pebble = try XCTUnwrap(scene.childNode(
                withName: "//pebble.\(descriptor.id.uuidString)"
            ) as? PebbleNode)
            let initialY = pebble.position.y
            var observedFall: CGFloat = 0
            // Drive the complete SpriteKit update/action/physics cycle explicitly.
            // This needs no window drawable, wall-clock sleep, or test-owned motion.
            while landingIDs.isEmpty, frame < 180 {
                frame += 1
                renderer.update(atTime: startTime + Double(frame) * frameInterval)
                observedFall = max(observedFall, initialY - pebble.position.y)
            }

            XCTAssertEqual(landingIDs, [descriptor.id])
            XCTAssertTrue(landingObservedCompletedPresentation)
            XCTAssertTrue(scene.hasLandedPebble(withID: descriptor.id))
            XCTAssertFalse(scene.hasLandedPebble(withID: UUID()))
            XCTAssertGreaterThan(observedFall, 300, "The body must really cross the jar")
            XCTAssertGreaterThan(scene.completionDropMaximumFall, 300)
            XCTAssertLessThanOrEqual(scene.completionDropMaximumFall, initialY)
            XCTAssertEqual(scene.completionDropSequence, 1)
            let body = try XCTUnwrap(pebble.physicsBody)
            XCTAssertEqual(body.categoryBitMask, JarPhysicsCategory.pebble)
            XCTAssertNotEqual(body.collisionBitMask & JarPhysicsCategory.wall, 0)
            XCTAssertNotEqual(body.contactTestBitMask & JarPhysicsCategory.wall, 0)

            scene.dropFromAbove(descriptor)
            frame += 1
            renderer.update(atTime: startTime + Double(frame) * frameInterval)
            XCTAssertEqual(scene.physicalPebbleCount, 1)
            XCTAssertEqual(scene.queuedDropCount, 0)
            XCTAssertEqual(landingIDs, [descriptor.id])
            let retainedFall = scene.completionDropMaximumFall
            scene.restore(pebbles: [descriptor])
            frame += 1
            renderer.update(atTime: startTime + Double(frame) * frameInterval)
            XCTAssertEqual(scene.completionDropSequence, 1)
            XCTAssertEqual(scene.completionDropMaximumFall, retainedFall)
            XCTAssertTrue(scene.completionDropHasLanded)
            XCTAssertFalse(scene.hasCompletionDropInFlight)
        }
    }

    @MainActor
    func testReduceMotionToggleDoesNotSettleCompletionDropBeforeItLands() throws {
        let descriptor = PebbleDescriptor(
            subjectName: "資格",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            grams: Constants.Mass.measuredPebbleGrams
        )
        for initiallyReduced in [false, true] {
            let scene = makeDropScene(reduceMotion: initiallyReduced)
            var landingIDs: [UUID] = []
            scene.onLanding = { landingIDs.append($0.pebble.id) }
            scene.dropFromAbove(descriptor)
            scene.update(0)
            let pebble = try XCTUnwrap(scene.childNode(
                withName: "//pebble.\(descriptor.id.uuidString)"
            ) as? PebbleNode)
            let body = try XCTUnwrap(pebble.physicsBody)
            let position = pebble.position
            let velocity = body.velocity
            let category = body.categoryBitMask
            let collisions = body.collisionBitMask
            let contacts = body.contactTestBitMask
            XCTAssertLessThan(velocity.dy, 0)

            scene.reduceMotion = !initiallyReduced

            XCTAssertFalse(pebble.hasLanded)
            XCTAssertTrue(body.isDynamic)
            XCTAssertFalse(body.isResting)
            XCTAssertEqual(pebble.position.x, position.x, accuracy: 0.001)
            XCTAssertEqual(pebble.position.y, position.y, accuracy: 0.001)
            XCTAssertEqual(body.velocity.dx, velocity.dx, accuracy: 0.001)
            XCTAssertEqual(body.velocity.dy, velocity.dy, accuracy: 0.001)
            XCTAssertEqual(body.categoryBitMask, category)
            XCTAssertEqual(body.collisionBitMask, collisions)
            XCTAssertEqual(body.contactTestBitMask, contacts)
            XCTAssertEqual(scene.completionDropSequence, 1)
            XCTAssertEqual(scene.completionDropMaximumFall, 0, accuracy: 0.001)
            XCTAssertFalse(scene.completionDropHasLanded)
            XCTAssertTrue(scene.hasCompletionDropInFlight)
            XCTAssertTrue(landingIDs.isEmpty)

            scene.dropFromAbove(descriptor)
            XCTAssertEqual(scene.physicalPebbleCount, 1)
            XCTAssertEqual(scene.queuedDropCount, 0)
            XCTAssertEqual(scene.completionDropSequence, 1)
        }
    }

    @MainActor
    func testInteractionHardStopHandsFreshUnlandedDropBackToLandingLifecycle() async throws {
        let descriptor = PebbleDescriptor(
            id: UUID(uuidString: "E0000000-0000-4000-8000-000000000001")!,
            subjectName: "資格",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            grams: Constants.Mass.measuredPebbleGrams
        )
        let sceneSize = CGSize(width: 390, height: Constants.Jar.height)
        let scene = makeDropScene(reduceMotion: false)
        var landingIDs: [UUID] = []
        scene.onLanding = { landingIDs.append($0.pebble.id) }
        scene.drop(descriptor)
        scene.update(0)

        let pebble = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(descriptor.id.uuidString)"
        ) as? PebbleNode)
        let body = try XCTUnwrap(pebble.physicsBody)
        let originalPhysicalCount = scene.physicalPebbleCount
        let originalRepresentedCount = scene.representedPebbleCount
        XCTAssertFalse(pebble.hasLanded)

        XCTAssertTrue(scene.shakePebbles(strength: 0.8, horizontal: 1))
        XCTAssertTrue(scene.isInteractionMotionActive)
        let velocityBeforeDeadline = body.velocity
        XCTAssertGreaterThan(
            hypot(velocityBeforeDeadline.dx, velocityBeforeDeadline.dy),
            0
        )

        scene.evaluateInteractionMotionForTesting(
            currentTime: Constants.Jar.interactionHardStopDelay + 1,
            uptime: ProcessInfo.processInfo.systemUptime
                + Constants.Jar.interactionHardStopDelay + 0.1
        )

        XCTAssertFalse(scene.isInteractionMotionActive)
        XCTAssertFalse(
            scene.isPaused,
            "An unlanded reward must keep simulating past the interaction deadline"
        )
        XCTAssertFalse(pebble.hasLanded)
        XCTAssertTrue(body.isDynamic)
        XCTAssertFalse(body.isResting)
        XCTAssertEqual(body.velocity.dx, velocityBeforeDeadline.dx, accuracy: 0.001)
        XCTAssertEqual(body.velocity.dy, velocityBeforeDeadline.dy, accuracy: 0.001)
        XCTAssertEqual(scene.physicalPebbleCount, originalPhysicalCount)
        XCTAssertEqual(scene.representedPebbleCount, originalRepresentedCount)

        // Move the still-live body close to the floor only to make this
        // semantic landing assertion fast and deterministic on the render loop.
        pebble.position = CGPoint(
            x: sceneSize.width / 2,
            y: Constants.Jar.floorInset + pebble.radius + 3
        )
        body.velocity = CGVector(dx: 0, dy: -90)
        body.angularVelocity = 0
        body.isResting = false
        let view = SKView(frame: CGRect(origin: .zero, size: sceneSize))
        view.preferredFramesPerSecond = Constants.Jar.targetFramesPerSecond
        view.presentScene(scene)
        defer { view.presentScene(nil) }

        let landingDeadline = Date().addingTimeInterval(1)
        while landingIDs.isEmpty, Date() < landingDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(landingIDs, [descriptor.id])
        XCTAssertTrue(pebble.hasLanded)
        XCTAssertEqual(scene.physicalPebbleCount, originalPhysicalCount)
        XCTAssertEqual(scene.representedPebbleCount, originalRepresentedCount)
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
            200,
            "The first physics frame must carry roughly three gem diameters of travel"
        )
        bouncedBody.velocity = .zero
        scene.didSimulatePhysics()
        XCTAssertGreaterThan(
            bouncedBody.velocity.dy,
            200,
            "A sleeping floor contact must not consume the visible tap response"
        )
        XCTAssertTrue(bouncedNode.hasLanded, "Tap bounce must not re-arm landing rewards")
        XCTAssertEqual(scene.physicalPebbleCount, bodyCount)
        XCTAssertEqual(scene.representedPebbleCount, representedCount)
        XCTAssertEqual(scene.queuedDropCount, queuedCount)
        XCTAssertFalse(scene.bouncePebbles(at: bouncedNode.position))
    }

    @MainActor
    func testDeviceShakePreservesRecordsAndLargeGemRespondsWithMoreWeight() throws {
        for reduceMotion in [false, true] {
            let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
            scene.soundEnabled = false
            scene.hapticsEnabled = false
            scene.reduceMotion = reduceMotion
            let small = PebbleDescriptor(
                id: UUID(uuidString: "E0000000-0000-4000-8000-000000000001")!,
                subjectName: "英語",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams
            )
            let large = try XCTUnwrap(makeSceneAggregateDescriptors().last)
            scene.restore(pebbles: [small, large])
            let smallNode = try XCTUnwrap(scene.childNode(
                withName: "//pebble.\(small.id.uuidString)"
            ) as? PebbleNode)
            let largeNode = try XCTUnwrap(scene.childNode(
                withName: "//pebble.\(large.id.uuidString)"
            ) as? PebbleNode)
            let smallBody = try XCTUnwrap(smallNode.physicsBody)
            let largeBody = try XCTUnwrap(largeNode.physicsBody)
            for body in [smallBody, largeBody] {
                body.velocity = .zero
                body.angularVelocity = 0
                body.isResting = true
                // Simulate the transient state left by a tap. Shake must restore
                // both values even after it invalidates the delayed tap cleanup.
                body.linearDamping = 0.03
                body.usesPreciseCollisionDetection = true
            }
            let originalIDs = Set([smallNode.descriptor.id, largeNode.descriptor.id])
            let originalCount = scene.physicalPebbleCount
            let originalRepresentedCount = scene.representedPebbleCount

            XCTAssertGreaterThan(largeBody.mass, smallBody.mass)
            XCTAssertTrue(scene.shakePebbles(strength: 0.8, horizontal: 1))
            XCTAssertFalse(scene.shakePebbles(strength: 0.8, horizontal: -1))
            XCTAssertEqual(scene.physicalPebbleCount, originalCount)
            XCTAssertEqual(scene.representedPebbleCount, originalRepresentedCount)
            XCTAssertEqual(
                Set([smallNode.descriptor.id, largeNode.descriptor.id]),
                originalIDs
            )
            XCTAssertFalse(smallBody.isResting)
            XCTAssertFalse(largeBody.isResting)
            for body in [smallBody, largeBody] {
                XCTAssertLessThanOrEqual(
                    abs(body.velocity.dx),
                    Constants.Jar.shakeMaximumHorizontalVelocity + 0.001
                )
                XCTAssertLessThanOrEqual(
                    abs(body.velocity.dy),
                    Constants.Jar.shakeMaximumVerticalVelocity + 0.001
                )
                XCTAssertEqual(body.linearDamping, Constants.Jar.linearDamping, accuracy: 0.001)
                XCTAssertFalse(
                    body.usesPreciseCollisionDetection,
                    "A landed body must not retain expensive CCD after shake"
                )
            }
            XCTAssertGreaterThan(
                hypot(smallBody.velocity.dx, smallBody.velocity.dy),
                hypot(largeBody.velocity.dx, largeBody.velocity.dy),
                "The same bounded impulse should move the larger radius-derived mass less"
            )
        }
    }

    @MainActor
    func testTapShakeAndNudgeHaveIdenticalPhysicsRegardlessOfReduceMotion() throws {
        enum Interaction: CaseIterable {
            case tap, shake, nudge
        }
        let loose = PebbleDescriptor(
            id: UUID(uuidString: "D0000000-0000-4000-8000-000000000001")!,
            subjectName: "資格",
            colorHex: Constants.Color.science,
            source: .timer,
            kind: .normal,
            grams: Constants.Mass.measuredPebbleGrams
        )
        let aggregate = try XCTUnwrap(makeSceneAggregateDescriptors().first)
        let descriptors = [loose, aggregate]

        for interaction in Interaction.allCases {
            let scenes = [false, true].map { makeDropScene(reduceMotion: $0) }
            var sceneBodies: [[SKPhysicsBody]] = []
            for scene in scenes {
                scene.restore(pebbles: descriptors)
                let nodes = try descriptors.map { descriptor in
                    try XCTUnwrap(scene.childNode(
                        withName: "//pebble.\(descriptor.id.uuidString)"
                    ) as? PebbleNode)
                }
                let bodies = try nodes.map { try XCTUnwrap($0.physicsBody) }
                nodes[0].position = CGPoint(x: 150, y: 90)
                nodes[1].position = CGPoint(x: 260, y: 90)
                for body in bodies {
                    body.velocity = .zero
                    body.angularVelocity = 0
                    body.isResting = true
                }
                let revision = scene.physicalContentRevision
                var landingCount = 0
                scene.onLanding = { _ in landingCount += 1 }

                switch interaction {
                case .tap:
                    XCTAssertTrue(scene.bouncePebbles(at: nodes[0].position))
                    XCTAssertEqual(scene.activeTapDrivenBodyCount, 1)
                    XCTAssertGreaterThan(bodies[0].velocity.dy, 200)
                case .shake:
                    XCTAssertTrue(scene.shakePebbles(strength: 0.8, horizontal: 1))
                    XCTAssertTrue(bodies.allSatisfy { $0.velocity.dy > 0 })
                case .nudge:
                    scene.nudge(horizontal: 1, uptime: 10)
                    XCTAssertTrue(bodies.allSatisfy { $0.velocity.dx > 0 })
                }
                XCTAssertTrue(scene.isInteractionMotionActive)
                XCTAssertTrue(bodies.allSatisfy(\.isDynamic))
                XCTAssertEqual(scene.physicalPebbleCount, 2)
                XCTAssertEqual(scene.physicalAggregateCount, 1)
                XCTAssertEqual(scene.representedPebbleCount, 11)
                XCTAssertEqual(scene.physicalContentRevision, revision)
                XCTAssertEqual(landingCount, 0)
                XCTAssertEqual(Set(nodes.map { $0.descriptor.id }), Set(descriptors.map(\.id)))
                sceneBodies.append(bodies)
            }
            for (standard, reduced) in zip(sceneBodies[0], sceneBodies[1]) {
                XCTAssertEqual(reduced.velocity.dx, standard.velocity.dx, accuracy: 0.001)
                XCTAssertEqual(reduced.velocity.dy, standard.velocity.dy, accuracy: 0.001)
                XCTAssertEqual(reduced.angularVelocity, standard.angularVelocity, accuracy: 0.001)
                XCTAssertEqual(reduced.linearDamping, standard.linearDamping, accuracy: 0.001)
                XCTAssertEqual(reduced.usesPreciseCollisionDetection, standard.usesPreciseCollisionDetection)
                XCTAssertEqual(reduced.collisionBitMask, standard.collisionBitMask)
                XCTAssertEqual(reduced.contactTestBitMask, standard.contactTestBitMask)
            }
        }
    }

    @MainActor
    func testTapLaunchDrivesOnlyPrimaryAndLeavesCollisionTransferToSpriteKit() throws {
        for reduceMotion in [false, true] {
            let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
            scene.soundEnabled = false
            scene.hapticsEnabled = false
            scene.reduceMotion = reduceMotion
            let descriptors = [
                PebbleDescriptor(
                    subjectName: "primary",
                    colorHex: Constants.Color.english,
                    source: .timer,
                    kind: .normal,
                    grams: Constants.Mass.measuredPebbleGrams
                ),
                PebbleDescriptor(
                    subjectName: "neighbour",
                    colorHex: Constants.Color.mathematics,
                    source: .timer,
                    kind: .normal,
                    grams: Constants.Mass.measuredPebbleGrams
                ),
                PebbleDescriptor(
                    subjectName: "far",
                    colorHex: Constants.Color.science,
                    source: .timer,
                    kind: .normal,
                    grams: Constants.Mass.measuredPebbleGrams
                )
            ]
            scene.restore(pebbles: descriptors)
            let nodes = try descriptors.map { descriptor in
                try XCTUnwrap(scene.childNode(
                    withName: "//pebble.\(descriptor.id.uuidString)"
                ) as? PebbleNode)
            }
            let bodies = try nodes.map { try XCTUnwrap($0.physicsBody) }
            nodes[0].position = CGPoint(x: 170, y: 90)
            nodes[1].position = CGPoint(x: 194, y: 90)
            nodes[2].position = CGPoint(x: 320, y: 90)
            for body in bodies {
                body.velocity = .zero
                body.angularVelocity = 0
                body.isResting = true
            }

            XCTAssertTrue(scene.bouncePebbles(at: nodes[0].position))
            XCTAssertEqual(
                scene.activeTapDrivenBodyCount,
                1,
                "Only the touched gem may receive scripted velocity"
            )
            XCTAssertGreaterThan(bodies[0].velocity.dy, 200)
            XCTAssertGreaterThan(abs(bodies[0].velocity.dx), 80)
            XCTAssertEqual(bodies[1].velocity.dx, 0, accuracy: 0.001)
            XCTAssertEqual(bodies[1].velocity.dy, 0, accuracy: 0.001)
            XCTAssertEqual(bodies[2].velocity.dx, 0, accuracy: 0.001)
            XCTAssertEqual(bodies[2].velocity.dy, 0, accuracy: 0.001)
            XCTAssertNotEqual(
                bodies[0].collisionBitMask & JarPhysicsCategory.pebble,
                .zero,
                "The launched gem must transfer motion through SpriteKit contacts"
            )
            XCTAssertNotEqual(
                bodies[1].collisionBitMask & JarPhysicsCategory.pebble,
                .zero
            )
        }
    }

    @MainActor
    func testFullPhysicsBudgetStillScriptsOnlyOneTapBody() throws {
        let descriptors = (0..<Constants.Jar.maxPhysicsBodies).map { index in
            PebbleDescriptor(
                subjectName: "body \(index)",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams
            )
        }
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.restore(pebbles: descriptors)
        let nodes = try descriptors.map { descriptor in
            try XCTUnwrap(scene.childNode(
                withName: "//pebble.\(descriptor.id.uuidString)"
            ) as? PebbleNode)
        }
        let bodies = try nodes.map { try XCTUnwrap($0.physicsBody) }
        for body in bodies {
            body.velocity = .zero
            body.angularVelocity = 0
            body.isResting = true
        }
        let originalRepresentedCount = scene.representedPebbleCount

        XCTAssertTrue(scene.bouncePebbles(at: nodes[0].position))
        XCTAssertEqual(scene.activeTapDrivenBodyCount, 1)
        XCTAssertEqual(bodies.filter {
            hypot($0.velocity.dx, $0.velocity.dy) > 0.001
        }.count, 1)
        XCTAssertEqual(bodies.filter(\.usesPreciseCollisionDetection).count, 1)
        XCTAssertTrue(bodies.allSatisfy {
            $0.velocity.dx.isFinite
                && $0.velocity.dy.isFinite
                && $0.angularVelocity.isFinite
        })
        XCTAssertEqual(scene.physicalPebbleCount, Constants.Jar.maxPhysicsBodies)
        XCTAssertEqual(scene.representedPebbleCount, originalRepresentedCount)

        let launchedVelocity = bodies[0].velocity
        scene.reduceMotion = true
        XCTAssertEqual(scene.activeTapMotionPebbleID, descriptors[0].id)
        XCTAssertEqual(scene.activeTapDrivenBodyCount, 1)
        XCTAssertTrue(bodies.allSatisfy(\.isDynamic))
        XCTAssertEqual(bodies.filter(\.usesPreciseCollisionDetection).count, 1)
        XCTAssertEqual(bodies[0].velocity.dx, launchedVelocity.dx, accuracy: 0.001)
        XCTAssertEqual(bodies[0].velocity.dy, launchedVelocity.dy, accuracy: 0.001)
        XCTAssertEqual(scene.physicalPebbleCount, Constants.Jar.maxPhysicsBodies)
        XCTAssertEqual(scene.representedPebbleCount, originalRepresentedCount)
    }

    @MainActor
    func testEquidistantTapSelectsStableUUIDTieBreaker() throws {
        let lowerID = try XCTUnwrap(UUID(
            uuidString: "A0000000-0000-4000-8000-000000000001"
        ))
        let higherID = try XCTUnwrap(UUID(
            uuidString: "B0000000-0000-4000-8000-000000000001"
        ))
        let descriptors = [higherID, lowerID].map { id in
            PebbleDescriptor(
                id: id,
                subjectName: id == lowerID ? "lower" : "higher",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams
            )
        }
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.restore(pebbles: descriptors)
        let higher = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(higherID.uuidString)"
        ) as? PebbleNode)
        let lower = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(lowerID.uuidString)"
        ) as? PebbleNode)
        higher.position = CGPoint(x: 170, y: 90)
        lower.position = CGPoint(x: 220, y: 90)

        XCTAssertTrue(scene.bouncePebbles(at: CGPoint(x: 195, y: 90)))
        XCTAssertEqual(scene.activeTapMotionPebbleID, lowerID)
    }

    @MainActor
    func testRestoreInvalidatesTapBeforeRecreatingSamePebbleID() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        let descriptor = PebbleDescriptor(
            subjectName: "sync target",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            grams: Constants.Mass.measuredPebbleGrams
        )
        scene.restore(pebbles: [descriptor])
        let oldNode = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(descriptor.id.uuidString)"
        ) as? PebbleNode)
        XCTAssertTrue(scene.bouncePebbles(at: oldNode.position))
        XCTAssertEqual(scene.activeTapMotionPebbleID, descriptor.id)

        scene.restore(pebbles: [descriptor])
        let restoredNode = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(descriptor.id.uuidString)"
        ) as? PebbleNode)
        let restoredBody = try XCTUnwrap(restoredNode.physicsBody)
        XCTAssertFalse(oldNode === restoredNode)
        XCTAssertNil(scene.activeTapMotionPebbleID)
        XCTAssertEqual(scene.activeTapDrivenBodyCount, 0)
        XCTAssertEqual(restoredBody.velocity.dx, 0, accuracy: 0.001)
        XCTAssertEqual(restoredBody.velocity.dy, 0, accuracy: 0.001)
        XCTAssertEqual(
            restoredBody.linearDamping,
            Constants.Jar.linearDamping,
            accuracy: 0.001
        )
        XCTAssertFalse(restoredBody.usesPreciseCollisionDetection)
    }

    @MainActor
    func testLaterTapSynchronouslyFinalizesSlowPreviousFlight() async throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        let descriptors = [
            PebbleDescriptor(
                subjectName: "first",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams
            ),
            PebbleDescriptor(
                subjectName: "second",
                colorHex: Constants.Color.mathematics,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams
            )
        ]
        scene.restore(pebbles: descriptors)
        let nodes = try descriptors.map { descriptor in
            try XCTUnwrap(scene.childNode(
                withName: "//pebble.\(descriptor.id.uuidString)"
            ) as? PebbleNode)
        }
        let bodies = try nodes.map { try XCTUnwrap($0.physicsBody) }
        nodes[0].position = CGPoint(x: 105, y: 90)
        nodes[1].position = CGPoint(x: 285, y: 90)
        for body in bodies {
            body.velocity = .zero
            body.isResting = true
        }

        XCTAssertTrue(scene.bouncePebbles(at: nodes[0].position))
        XCTAssertEqual(scene.activeTapMotionPebbleID, descriptors[0].id)
        XCTAssertLessThan(
            bodies[0].linearDamping,
            Constants.Jar.linearDamping
        )
        XCTAssertTrue(bodies[0].usesPreciseCollisionDetection)

        // With no attached SKView the frame-count gate intentionally keeps the
        // old launch pending beyond the gesture cooldown.
        try await Task.sleep(for: .milliseconds(760))
        XCTAssertTrue(scene.bouncePebbles(at: nodes[1].position))
        XCTAssertEqual(scene.activeTapMotionPebbleID, descriptors[1].id)
        XCTAssertEqual(
            bodies[0].linearDamping,
            Constants.Jar.linearDamping,
            accuracy: 0.001
        )
        XCTAssertFalse(bodies[0].usesPreciseCollisionDetection)
        XCTAssertLessThanOrEqual(bodies[0].velocity.dy, -130)
        XCTAssertEqual(scene.activeTapDrivenBodyCount, 1)
    }

    @MainActor
    func testReduceMotionToggleKeepsDelayedReturnAndCannotReapplyStaleUpwardKick() async throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        let descriptor = PebbleDescriptor(
            subjectName: "paused flight",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            grams: Constants.Mass.measuredPebbleGrams
        )
        scene.restore(pebbles: [descriptor])
        let node = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(descriptor.id.uuidString)"
        ) as? PebbleNode)
        let body = try XCTUnwrap(node.physicsBody)

        XCTAssertTrue(scene.bouncePebbles(at: node.position))
        XCTAssertGreaterThan(body.velocity.dy, 200)
        scene.reduceMotion = true
        XCTAssertEqual(scene.activeTapMotionPebbleID, descriptor.id)
        XCTAssertGreaterThan(body.velocity.dy, 200)
        // No SKView means no physics frames. The bounded deferral eventually
        // chooses return over waiting forever, as a backgrounded scene would.
        let returnDeadline = Date().addingTimeInterval(3)
        while scene.activeTapDrivenBodyCount > 0,
              Date() < returnDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertLessThan(body.velocity.dy, 0)
        XCTAssertEqual(scene.activeTapDrivenBodyCount, 0)

        let returnVelocity = body.velocity.dy
        scene.didSimulatePhysics()
        XCTAssertLessThanOrEqual(
            body.velocity.dy,
            returnVelocity,
            "A stale wake kick must not reverse the timed-out return"
        )
        let cleanupDeadline = Date().addingTimeInterval(1)
        while scene.activeTapMotionPebbleID != nil,
              Date() < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNil(scene.activeTapMotionPebbleID)
        XCTAssertEqual(
            body.linearDamping,
            Constants.Jar.linearDamping,
            accuracy: 0.001
        )
        XCTAssertFalse(body.usesPreciseCollisionDetection)
    }

    @MainActor
    func testTapContactMovesNeighbourOnSpriteKitRenderLoop() async throws {
        let sceneSize = CGSize(width: 390, height: Constants.Jar.height)
        let scene = JarScene(size: sceneSize)
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        let descriptors = [
            PebbleDescriptor(
                subjectName: "primary",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams
            ),
            PebbleDescriptor(
                subjectName: "neighbour",
                colorHex: Constants.Color.mathematics,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams
            )
        ]
        scene.restore(pebbles: descriptors)
        let nodes = try descriptors.map { descriptor in
            try XCTUnwrap(scene.childNode(
                withName: "//pebble.\(descriptor.id.uuidString)"
            ) as? PebbleNode)
        }
        let bodies = try nodes.map { try XCTUnwrap($0.physicsBody) }
        let view = SKView(frame: CGRect(origin: .zero, size: sceneSize))
        view.preferredFramesPerSecond = Constants.Jar.targetFramesPerSecond
        view.presentScene(scene)
        defer { view.presentScene(nil) }
        try await Task.sleep(for: .milliseconds(100))

        nodes[0].position = CGPoint(x: 170, y: 90)
        nodes[1].position = CGPoint(x: 194, y: 90)
        for body in bodies {
            body.velocity = .zero
            body.angularVelocity = 0
            body.isResting = true
        }
        let neighbourStart = nodes[1].position
        let originalCount = scene.physicalPebbleCount
        let originalRepresentedCount = scene.representedPebbleCount

        XCTAssertTrue(scene.bouncePebbles(at: nodes[0].position))
        XCTAssertEqual(bodies[1].velocity.dx, 0, accuracy: 0.001)
        XCTAssertEqual(bodies[1].velocity.dy, 0, accuracy: 0.001)
        try await Task.sleep(for: .milliseconds(500))

        let neighbourTravel = hypot(
            nodes[1].position.x - neighbourStart.x,
            nodes[1].position.y - neighbourStart.y
        )
        XCTAssertGreaterThan(
            neighbourTravel,
            1.5,
            "A contacted neighbour must move later through SpriteKit, not a scripted initial wave"
        )
        XCTAssertGreaterThanOrEqual(scene.tapPresentationMovedSecondaryCount, 1)
        XCTAssertEqual(scene.physicalPebbleCount, originalCount)
        XCTAssertEqual(scene.representedPebbleCount, originalRepresentedCount)
        for node in nodes {
            XCTAssertTrue(node.position.x.isFinite)
            XCTAssertTrue(node.position.y.isFinite)
            XCTAssertTrue(scene.frame.insetBy(dx: -1, dy: -1).contains(node.position))
        }

        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(scene.activeTapMotionPebbleID)
        XCTAssertEqual(
            bodies[0].linearDamping,
            Constants.Jar.linearDamping,
            accuracy: 0.001
        )
        XCTAssertFalse(bodies[0].usesPreciseCollisionDetection)
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
        XCTAssertGreaterThan(nearBody.velocity.dy, 200)
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
    func testSparseGlassTapBouncesNearestGemAndAcknowledgesExactPoint() {
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
        XCTAssertGreaterThan(
            body.velocity.dy,
            190,
            "A nonempty bottle must never report a successful tap without moving a real gem"
        )
        XCTAssertFalse(body.isResting)
        guard let caustic = scene.childNode(withName: "//jar.tap.caustic") else {
            XCTFail("Tap feedback must remain visible on empty glass")
            return
        }
        XCTAssertEqual(caustic.position.x, point.x, accuracy: 0.001)
        XCTAssertEqual(caustic.position.y, point.y, accuracy: 0.001)
    }

    @MainActor
    func testAggregateInspectionUsesTheSameDirectlyTappedGemAndClearsAfterRejection() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        let aggregate = try XCTUnwrap(makeSceneAggregateDescriptors().first)
        scene.restore(pebbles: [aggregate])
        let node = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(aggregate.id.uuidString)"
        ) as? PebbleNode)
        node.position = CGPoint(x: 195, y: 110)

        XCTAssertTrue(scene.bouncePebbles(at: node.position))
        XCTAssertEqual(scene.lastAcceptedTapSelection?.pebbleID, aggregate.id)
        XCTAssertEqual(
            scene.lastAcceptedTapSelection?.inspectableAggregateID,
            aggregate.id,
            "The detail affordance must describe the exact gem launched by physics"
        )
        XCTAssertEqual(scene.activeTapMotionPebbleID, aggregate.id)

        XCTAssertFalse(scene.bouncePebbles(at: CGPoint(x: 2, y: 210)))
        XCTAssertNil(
            scene.lastAcceptedTapSelection,
            "A rejected tap must not reuse a prior aggregate selection"
        )
    }

    @MainActor
    func testSparseGlassTapMayBounceAggregateWithoutClaimingDirectSelection() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        let aggregate = try XCTUnwrap(makeSceneAggregateDescriptors().first)
        scene.restore(pebbles: [aggregate])
        let node = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(aggregate.id.uuidString)"
        ) as? PebbleNode)
        node.position = CGPoint(x: 195, y: 90)
        let physicalCount = scene.physicalPebbleCount
        let representedCount = scene.representedPebbleCount

        XCTAssertTrue(scene.bouncePebbles(at: CGPoint(x: 195, y: 340)))
        XCTAssertEqual(scene.lastAcceptedTapSelection?.pebbleID, aggregate.id)
        XCTAssertNil(
            scene.lastAcceptedTapSelection?.inspectableAggregateID,
            "Bouncing the nearest gem from sparse glass is not a direct aggregate hit"
        )
        XCTAssertEqual(scene.physicalPebbleCount, physicalCount)
        XCTAssertEqual(scene.representedPebbleCount, representedCount)
    }

    @MainActor
    func testReduceMotionStillSelectsAndBouncesAggregateWithoutChangingAccounting() throws {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = true
        let aggregate = try XCTUnwrap(makeSceneAggregateDescriptors().first)
        scene.restore(pebbles: [aggregate])
        let node = try XCTUnwrap(scene.childNode(
            withName: "//pebble.\(aggregate.id.uuidString)"
        ) as? PebbleNode)
        let body = try XCTUnwrap(node.physicsBody)
        let originalPosition = node.position
        let physicalCount = scene.physicalPebbleCount
        let representedCount = scene.representedPebbleCount

        XCTAssertTrue(scene.bouncePebbles(at: node.position))
        XCTAssertEqual(
            scene.lastAcceptedTapSelection?.inspectableAggregateID,
            aggregate.id
        )
        XCTAssertGreaterThan(body.velocity.dy, 0)
        XCTAssertTrue(body.isDynamic)
        XCTAssertEqual(scene.activeTapMotionPebbleID, aggregate.id)
        XCTAssertEqual(scene.physicalPebbleCount, physicalCount)
        XCTAssertEqual(scene.representedPebbleCount, representedCount)

        XCTAssertEqual(node.position.x, originalPosition.x, accuracy: 0.001)
        XCTAssertGreaterThan(
            node.position.y,
            originalPosition.y,
            "The physical tap must clear the resting contact before launching the aggregate"
        )
    }

    @MainActor
    func testTapOpensAndHardStopsBoundedInteractionWindowRegardlessOfReduceMotion() throws {
        for reduceMotion in [false, true] {
            let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
            scene.soundEnabled = false
            scene.hapticsEnabled = false
            scene.reduceMotion = reduceMotion
            let descriptor = PebbleDescriptor(
                subjectName: "英語",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams
            )
            scene.restore(pebbles: [descriptor])
            let pebble = try XCTUnwrap(scene.childNode(
                withName: "//pebble.\(descriptor.id.uuidString)"
            ) as? PebbleNode)
            let body = try XCTUnwrap(pebble.physicsBody)
            let originalPhysicalCount = scene.physicalPebbleCount
            let originalRepresentedCount = scene.representedPebbleCount

            XCTAssertFalse(scene.isInteractionMotionActive)
            XCTAssertTrue(scene.bouncePebbles(at: pebble.position))
            XCTAssertTrue(
                scene.isInteractionMotionActive,
                "A deliberate tap should temporarily reopen live SpriteKit physics"
            )

            scene.evaluateInteractionMotionForTesting(
                currentTime: Constants.Jar.interactionHardStopDelay + 1,
                uptime: ProcessInfo.processInfo.systemUptime
                    + Constants.Jar.interactionHardStopDelay + 0.1
            )

            XCTAssertFalse(scene.isInteractionMotionActive)
            XCTAssertTrue(scene.isPaused)
            XCTAssertEqual(body.velocity.dx, 0, accuracy: 0.001)
            XCTAssertEqual(body.velocity.dy, 0, accuracy: 0.001)
            XCTAssertEqual(body.angularVelocity, 0, accuracy: 0.001)
            XCTAssertTrue(body.isResting)
            XCTAssertEqual(scene.physicalPebbleCount, originalPhysicalCount)
            XCTAssertEqual(scene.representedPebbleCount, originalRepresentedCount)
        }
    }

    @MainActor
    func testCoreMotionGravityUpdatePreservesTappedGemFlightDamping() throws {
        for reduceMotion in [false, true] {
            let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
            scene.soundEnabled = false
            scene.hapticsEnabled = false
            scene.reduceMotion = reduceMotion
            let descriptor = PebbleDescriptor(
                subjectName: "英語",
                colorHex: Constants.Color.english,
                source: .timer,
                kind: .normal,
                grams: Constants.Mass.measuredPebbleGrams
            )
            scene.restore(pebbles: [descriptor])
            let pebble = try XCTUnwrap(scene.childNode(
                withName: "//pebble.\(descriptor.id.uuidString)"
            ) as? PebbleNode)
            let body = try XCTUnwrap(pebble.physicsBody)

            XCTAssertTrue(scene.bouncePebbles(at: pebble.position))
            let flightDamping = body.linearDamping
            XCTAssertLessThan(flightDamping, Constants.Jar.linearDamping)

            scene.setGravityVector(
                CGVector(dx: 2.4, dy: -5),
                smoothing: false,
                wakesSimulation: false
            )

            XCTAssertTrue(scene.isInteractionMotionActive)
            XCTAssertEqual(
                body.linearDamping,
                flightDamping,
                accuracy: 0.0001,
                "Passive Core Motion samples must not erase the tapped gem's readable flight"
            )
        }
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

    private func makeStoredSceneAggregate(
        id: UUID,
        colorHex: String,
        pebbleCount: Int,
        grams: Int
    ) -> AggregatePebble {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        return AggregatePebble(
            id: id,
            createdAt: date,
            level: 1,
            pebbleCount: pebbleCount,
            grams: grams,
            measuredPebbleCount: pebbleCount,
            colorMixJSON: StrataMath.encodeColorMix([
                StratumColorFraction(hex: colorHex, fraction: 1)
            ]),
            subjectMixJSON: StrataMath.encodeSubjectMix([
                AggregateSubjectFraction(
                    name: "集中",
                    colorHex: colorHex,
                    pebbleCount: pebbleCount
                )
            ]),
            periodStart: date,
            periodEnd: date
        )
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
