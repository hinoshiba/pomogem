import XCTest
@testable import PomoGem

/// 重さの旅 (GemExperienceDesign §5, D1/D6/D7). The journey is derived from
/// lifetime grams alone, so every expectation here is plain arithmetic on
/// 1 minute = 10g.
final class WeightJourneyTests: XCTestCase {
    private typealias Journey = WeightJourney

    // MARK: - §5.3 every threshold

    private struct Rung {
        let minutes: Int
        let name: String
        let time: String
        let comparison: String
        let subComparison: String?
        let celebration: Journey.Celebration
        let markerOrdinal: Int?
    }

    /// §5.3 with the comparisons fixed by Docs/WeightJourneyComparisons.md.
    private let ladder: [Rung] = [
        Rung(minutes: 25, name: "最初の一粒", time: "25分", comparison: "りんご1個ほど", subComparison: nil, celebration: .small, markerOrdinal: nil),
        Rung(minutes: 60, name: "はじめての1時間", time: "1時間", comparison: "卵10個ほど", subComparison: nil, celebration: .medium, markerOrdinal: nil),
        Rung(minutes: 120, name: "2時間", time: "2時間", comparison: "キャベツ1玉ほど", subComparison: nil, celebration: .small, markerOrdinal: nil),
        Rung(minutes: 300, name: "5時間", time: "5時間", comparison: "サケ1尾ほど", subComparison: nil, celebration: .small, markerOrdinal: nil),
        Rung(minutes: 600, name: "10時間", time: "10時間", comparison: "大玉スイカ1玉ほど", subComparison: nil, celebration: .medium, markerOrdinal: 1),
        Rung(minutes: 1_200, name: "20時間", time: "20時間", comparison: "コーギー1頭ほど", subComparison: nil, celebration: .medium, markerOrdinal: 2),
        Rung(minutes: 3_000, name: "50時間", time: "50時間", comparison: "コウテイペンギン1羽ほど", subComparison: nil, celebration: .medium, markerOrdinal: 5),
        Rung(minutes: 6_000, name: "100時間", time: "100時間", comparison: "米俵1俵", subComparison: nil, celebration: .medium, markerOrdinal: 10),
        Rung(minutes: 12_000, name: "200時間", time: "200時間", comparison: "ジャイアントパンダ1頭ほど", subComparison: nil, celebration: .medium, markerOrdinal: 20),
        Rung(minutes: 30_000, name: "500時間", time: "500時間", comparison: "シマウマ1頭ほど", subComparison: nil, celebration: .medium, markerOrdinal: 50),
        Rung(minutes: 60_000, name: "1,000時間", time: "1,000時間", comparison: "乳牛1頭ほど", subComparison: nil, celebration: .medium, markerOrdinal: 100),
        Rung(minutes: 120_000, name: "2,000時間", time: "2,000時間", comparison: "キリン1頭ほど", subComparison: nil, celebration: .medium, markerOrdinal: 200),
        Rung(minutes: 300_000, name: "5,000時間", time: "5,000時間", comparison: "シロナガスクジラの赤ちゃん1頭ほど", subComparison: nil, celebration: .medium, markerOrdinal: 500),
        Rung(minutes: 600_000, name: "ゾウ1頭ぶん", time: "10,000時間", comparison: "アフリカゾウ（オス）1頭ほど", subComparison: nil, celebration: .extraLarge, markerOrdinal: 1_000),
        Rung(minutes: 1_200_000, name: "ゾウ2頭ぶん", time: "20,000時間", comparison: "アフリカゾウ（オス）2頭ほど", subComparison: nil, celebration: .medium, markerOrdinal: 2_000),
        Rung(minutes: 1_800_000, name: "ゾウ3頭ぶん", time: "30,000時間", comparison: "アフリカゾウ（オス）3頭ほど", subComparison: nil, celebration: .medium, markerOrdinal: 3_000),
        Rung(minutes: 2_400_000, name: "ゾウ4頭ぶん", time: "40,000時間", comparison: "アフリカゾウ（オス）4頭ほど", subComparison: nil, celebration: .medium, markerOrdinal: 4_000),
        Rung(minutes: 3_000_000, name: "ゾウ5頭ぶん", time: "50,000時間", comparison: "アフリカゾウ（オス）5頭ほど", subComparison: "ザトウクジラ1頭ほど", celebration: .medium, markerOrdinal: 5_000),
        Rung(minutes: 3_600_000, name: "ゾウ6頭ぶん", time: "60,000時間", comparison: "アフリカゾウ（オス）6頭ほど", subComparison: nil, celebration: .medium, markerOrdinal: 6_000),
    ]

    func testEveryLandmarkOfTheLadderSitsAtItsHourWithItsLedgerComparison() {
        var previousGrams = 0
        for (index, rung) in ladder.enumerated() {
            let grams = rung.minutes * 10
            let context = "landmark \(index) at \(rung.minutes) min"

            let reached = Journey.landmark(reachedAt: grams)
            XCTAssertEqual(reached?.index, index, context)
            XCTAssertEqual(reached?.minutes, rung.minutes, context)
            XCTAssertEqual(reached?.grams, grams, context)
            XCTAssertEqual(reached?.name, rung.name, context)
            XCTAssertEqual(reached?.timeText, rung.time, context)
            XCTAssertEqual(reached?.comparison.label, rung.comparison, context)
            XCTAssertEqual(reached?.subComparison?.label, rung.subComparison, context)
            XCTAssertEqual(reached?.celebration, rung.celebration, context)
            XCTAssertEqual(reached?.marker?.ordinal, rung.markerOrdinal, context)

            // One minute short, the previous rung is still the one reached and
            // this one is next.
            XCTAssertEqual(Journey.landmark(reachedAt: grams - 10)?.index, index == 0 ? nil : index - 1, context)
            XCTAssertEqual(Journey.landmark(after: grams - 10), reached, context)
            XCTAssertEqual(Journey.landmark(after: previousGrams), reached, context)
            XCTAssertGreaterThan(grams, previousGrams, context)
            previousGrams = grams
        }
        XCTAssertNil(Journey.landmark(reachedAt: 0))
        XCTAssertEqual(Journey.fixedLandmarks.count, 13)
    }

    func testTheLadderIsOneTwoFiveHoursAndNeverLandsOnACoreStage() {
        let hours = Journey.fixedLandmarks.dropFirst(2).map { $0.minutes / 60 }
        XCTAssertEqual(hours, [2, 5, 10, 20, 50, 100, 200, 500, 1_000, 2_000, 5_000])
        let coreStages = (0..<8).map { 2_500 * Int(pow(10, Double($0))) }
        for landmark in Journey.fixedLandmarks + (1...20).map(Journey.elephantLandmark(count:)) {
            XCTAssertFalse(coreStages.contains(landmark.grams), "\(landmark.minutes) min")
        }
        for ordinal in 1...20_000 {
            XCTAssertFalse(coreStages.contains(ordinal * 6_000), "marker \(ordinal)")
        }
    }

    func testOnlyTheRiceBaleIsExactAndEveryOtherComparisonSaysHodo() {
        let comparisons = Journey.fixedLandmarks.map(\.comparison)
            + [.bullAfricanElephants(1), .bullAfricanElephants(7), .humpbackWhale]
        for comparison in comparisons {
            if comparison == .riceBale {
                XCTAssertTrue(comparison.isExact)
                XCTAssertFalse(comparison.label.contains("ほど"))
            } else {
                XCTAssertFalse(comparison.isExact, comparison.label)
                XCTAssertTrue(comparison.label.hasSuffix("ほど"), comparison.label)
            }
        }
        XCTAssertEqual(Set(comparisons.map(\.label)).count, comparisons.count, "Every comparison is its own object")
    }

    func testCoreStagesAreThresholdsOfTheirOwnWithTheLargeBeat() {
        let stages = [2_500, 25_000, 250_000, 2_500_000, 25_000_000]
        for (offset, grams) in stages.enumerated() {
            let crossing = Journey.crossing(from: grams - 10, to: grams)
            XCTAssertEqual(crossing.thresholds.count, 1, "\(grams)g")
            XCTAssertEqual(crossing.highest?.grams, grams)
            XCTAssertEqual(crossing.highest?.coreStage, offset + 1)
            XCTAssertNil(crossing.highest?.landmark)
            XCTAssertNil(crossing.highest?.marker)
            XCTAssertEqual(crossing.largestCelebration, .large)
            // The core never becomes Home's target (D6).
            let target = Journey.state(grams: grams - 10, isProvisional: false).nextTarget
            XCTAssertNotEqual(target.grams, grams)
        }
    }

    // MARK: - 一里塚

    func testMarkersLightEveryTenHoursAndFoldDecimally() {
        let cases: [(grams: Int, count: Int, diamonds: Int, stars: Int, crowns: Int, elephants: Int)] = [
            (0, 0, 0, 0, 0, 0),
            (5_990, 0, 0, 0, 0, 0),
            (6_000, 1, 1, 0, 0, 0),
            (54_000, 9, 9, 0, 0, 0),
            (60_000, 10, 0, 1, 0, 0),
            (66_000, 11, 1, 1, 0, 0),
            (599_990, 99, 9, 9, 0, 0),
            (600_000, 100, 0, 0, 1, 0),
            (5_999_990, 999, 9, 9, 9, 0),
            (6_000_000, 1_000, 0, 0, 0, 1),
            (6_066_000, 1_011, 1, 1, 0, 1),
        ]
        for item in cases {
            let fold = Journey.state(grams: item.grams, isProvisional: false).markers
            XCTAssertEqual(fold.count, item.count, "\(item.grams)g")
            XCTAssertEqual(fold.diamonds, item.diamonds, "\(item.grams)g ◇")
            XCTAssertEqual(fold.stars, item.stars, "\(item.grams)g 星")
            XCTAssertEqual(fold.crowns, item.crowns, "\(item.grams)g 冠")
            XCTAssertEqual(fold.elephants, item.elephants, "\(item.grams)g ゾウ")
        }

        XCTAssertEqual(Journey.Marker(ordinal: 1).completes, .diamond)
        XCTAssertEqual(Journey.Marker(ordinal: 9).completes, .diamond)
        XCTAssertEqual(Journey.Marker(ordinal: 10).completes, .star)
        XCTAssertEqual(Journey.Marker(ordinal: 110).completes, .star)
        XCTAssertEqual(Journey.Marker(ordinal: 100).completes, .crown)
        XCTAssertEqual(Journey.Marker(ordinal: 1_000).completes, .elephant)
        XCTAssertEqual(Journey.Marker(ordinal: 3_000).completes, .elephant)
        XCTAssertEqual(Journey.Marker(ordinal: 8).minutes, 4_800)
        XCTAssertEqual(Journey.Marker(ordinal: 8).grams, 48_000)
    }

    func testFortyYearsAtTenHoursADayStayBounded() {
        // 40 years × 365.25 days × 10 hours = 146,100 hours = 87.66t
        // (EngagementArchitecture §7, GemExperienceDesign 付録C).
        let hours = 40 * 36_525 / 100 * 10
        XCTAssertEqual(hours, 146_100)
        let grams = hours * 60 * 10
        XCTAssertEqual(grams, 87_660_000)

        let state = Journey.state(grams: grams, isProvisional: false)
        XCTAssertEqual(state.markers.count, 14_610)
        XCTAssertEqual(state.markers.diamonds, 0)
        XCTAssertEqual(state.markers.stars, 1)
        XCTAssertEqual(state.markers.crowns, 6)
        XCTAssertEqual(state.markers.elephants, 14)
        XCTAssertEqual(state.reachedLandmark?.kind, .elephants(14))
        XCTAssertEqual(state.nextLandmark.kind, .elephants(15))
        XCTAssertEqual(state.nextTarget, .marker(Journey.Marker(ordinal: 14_611)))

        // Day by day, nothing on the orbit ever leaves 0–9, and the herd only
        // grows by one per 10,000 hours.
        var previousElephants = 0
        for day in stride(from: 0, through: 40 * 36_525 / 100, by: 1) {
            let fold = Journey.state(grams: day * 6_000, isProvisional: false).markers
            XCTAssertTrue((0...9).contains(fold.diamonds))
            XCTAssertTrue((0...9).contains(fold.stars))
            XCTAssertTrue((0...9).contains(fold.crowns))
            XCTAssertTrue((0...14).contains(fold.elephants))
            XCTAssertTrue(fold.elephants - previousElephants <= 1)
            previousElephants = fold.elephants
        }

        // A new device that reads all forty years at once gets a bounded list.
        let crossing = Journey.crossing(from: 0, to: grams)
        XCTAssertEqual(crossing.markerCount, 14_610)
        XCTAssertEqual(crossing.highest?.grams, grams)
        XCTAssertEqual(crossing.highest?.marker?.ordinal, 14_610)
        XCTAssertLessThanOrEqual(crossing.thresholds.count, 13 + 11 + 10 + 5)
        XCTAssertTrue(crossing.thresholds.contains { $0.landmark?.kind == .elephants(1) },
                      "ゾウ1頭ぶん, the one extra-large beat, is always named")
        XCTAssertEqual(crossing.largestCelebration, .extraLarge)
    }

    // MARK: - §5.5 next target and the 50% rule

    func testHomeNamesALandmarkWithinTenHoursAndTheNextMarkerOtherwise() {
        let cases: [(grams: Int, target: Journey.Target)] = [
            (0, .landmark(Journey.fixedLandmarks[0])),
            (250, .landmark(Journey.fixedLandmarks[1])),
            (1_200, .landmark(Journey.fixedLandmarks[3])),
            (3_000, .landmark(Journey.fixedLandmarks[4])),
            // Exactly ten hours away still names the landmark (10時間以内).
            (6_000, .landmark(Journey.fixedLandmarks[5])),
            (12_000, .marker(Journey.Marker(ordinal: 3))),
            (18_000, .marker(Journey.Marker(ordinal: 4))),
            (24_000, .landmark(Journey.fixedLandmarks[6])),
            (29_990, .landmark(Journey.fixedLandmarks[6])),
            (30_000, .marker(Journey.Marker(ordinal: 6))),
            // 「つぎの一里塚　80時間」
            (45_000, .marker(Journey.Marker(ordinal: 8))),
            (48_000, .marker(Journey.Marker(ordinal: 9))),
            // 「つぎの名所　米俵1俵・100時間」
            (54_000, .landmark(Journey.fixedLandmarks[7])),
            (60_000, .marker(Journey.Marker(ordinal: 11))),
            (114_000, .landmark(Journey.fixedLandmarks[8])),
            (5_994_000, .landmark(Journey.elephantLandmark(count: 1))),
            (6_000_000, .marker(Journey.Marker(ordinal: 1_001))),
            (29_994_000, .landmark(Journey.elephantLandmark(count: 5))),
        ]
        for item in cases {
            let state = Journey.state(grams: item.grams, isProvisional: false)
            XCTAssertEqual(state.nextTarget, item.target, "\(item.grams)g")
            XCTAssertGreaterThan(state.nextTarget.grams, item.grams, "\(item.grams)g")
            XCTAssertLessThanOrEqual(state.nextTarget.grams - item.grams, 6_000, "\(item.grams)g")
        }
        XCTAssertEqual(Journey.Target.marker(Journey.Marker(ordinal: 8)).minutes, 4_800)
        if case let .landmark(landmark) = Journey.state(grams: 54_000, isProvisional: false).nextTarget {
            XCTAssertEqual(landmark.comparison.label, "米俵1俵")
            XCTAssertEqual(landmark.timeText, "100時間")
        } else {
            XCTFail("90 hours should point at the 100-hour landmark")
        }
    }

    func testTheSegmentStartsAtTheLastMarkerOrLandmarkAndTurnsAtHalfway() {
        let cases: [(grams: Int, start: Int, end: Int)] = [
            (0, 0, 250),
            (100, 0, 250),
            (1_800, 1_200, 3_000),
            (4_000, 3_000, 6_000),
            (20_000, 18_000, 24_000),
            (27_000, 24_000, 30_000),
            (70_000, 66_000, 72_000),
            (6_003_000, 6_000_000, 6_006_000),
        ]
        for item in cases {
            let state = Journey.state(grams: item.grams, isProvisional: false)
            XCTAssertEqual(state.segmentStartGrams, item.start, "\(item.grams)g")
            XCTAssertEqual(state.segment?.startGrams, item.start, "\(item.grams)g")
            XCTAssertEqual(state.segment?.endGrams, item.end, "\(item.grams)g")
        }

        // 5 h → 10 h. Up to and including half: what was stacked. Past half:
        // what is left.
        let atStart = Journey.state(grams: 3_000, isProvisional: false).segment
        XCTAssertEqual(atStart?.reading, .accumulated(grams: 0))
        let atHalf = Journey.state(grams: 4_500, isProvisional: false).segment
        XCTAssertEqual(atHalf?.reading, .accumulated(grams: 1_500))
        XCTAssertEqual(atHalf?.accumulatedMinutes, 150)
        XCTAssertEqual(atHalf?.fraction, 0.5)
        let pastHalf = Journey.state(grams: 4_510, isProvisional: false).segment
        XCTAssertEqual(pastHalf?.reading, .remaining(grams: 1_490))
        XCTAssertEqual(pastHalf?.remainingMinutes, 149)

        // 「+3時間10分 積みました」 then 「あと4時間50分」 on a 10-hour stretch.
        let early = Journey.state(grams: 18_000 + 1_900, isProvisional: false).segment
        XCTAssertEqual(early?.reading, .accumulated(grams: 1_900))
        XCTAssertEqual(early?.accumulatedMinutes, 190)
        let late = Journey.state(grams: 18_000 + 3_100, isProvisional: false).segment
        XCTAssertEqual(late?.reading, .remaining(grams: 2_900))
        XCTAssertEqual(late?.remainingMinutes, 290)

        // Remaining minutes round up, so the line never says 「あと0分」 early.
        let odd = Journey.Segment(startGrams: 0, endGrams: 6_000, grams: 5_995)
        XCTAssertEqual(odd.remainingMinutes, 1)
        XCTAssertEqual(odd.accumulatedMinutes, 599)
    }

    func testAProvisionalTotalNamesAFloorButNoSegmentProgress() {
        for grams in [0, 250, 4_500, 50_000, 87_660_000] {
            let verified = Journey.state(grams: grams, isProvisional: false)
            let provisional = Journey.state(grams: grams, isProvisional: true)
            XCTAssertTrue(provisional.isProvisional)
            XCTAssertNil(provisional.segment, "\(grams)g: a lower bound says nothing about the stretch")
            XCTAssertNotNil(verified.segment)
            // 「80時間以上・同期中」: the floor and the orbit stay readable.
            XCTAssertEqual(provisional.segmentStartGrams, verified.segmentStartGrams)
            XCTAssertEqual(provisional.markers, verified.markers)
            XCTAssertEqual(provisional.reachedLandmark, verified.reachedLandmark)
            XCTAssertEqual(provisional.nextTarget, verified.nextTarget)
        }
        XCTAssertEqual(Journey.state(grams: 50_000, isProvisional: true).segmentStartGrams, 48_000)
    }

    // MARK: - §5.4 acceptance

    /// 1日1本（25分）以上なら、名前の付いた次の目標までが30日を超えない。
    /// Seventy years, one day at a time.
    func testOneSessionADayNeverWaitsMoreThanThirtyDaysForTheNextNamedTarget() {
        let seventyYears = 70 * 36_525 / 100
        let paces: [(sessions: Int, longestHomeGap: Int, longestFirstTenHours: Int)] = [
            (1, 24, 12),
            (2, 12, 6),
            (4, 6, 3),
        ]
        for pace in paces {
            let perDay = 250 * pace.sessions
            var longestHomeWait = 0
            var longestGapBetweenNamed = 0
            var longestGapInFirstTenHours = 0
            var lastNamedDay = 0
            var firstElephantDay: Int?

            for day in 0...seventyYears {
                let grams = day * perDay
                let state = Journey.state(grams: grams, isProvisional: false)
                // Days until what Home names today is reached.
                let wait = (state.nextTarget.grams - grams + perDay - 1) / perDay
                longestHomeWait = max(longestHomeWait, wait)

                // Days between named thresholds (一里塚 or 名所) actually reached.
                if day > 0 {
                    let crossing = Journey.crossing(from: grams - perDay, to: grams)
                    if crossing.thresholds.contains(where: { $0.landmark != nil || $0.marker != nil }) {
                        let gap = day - lastNamedDay
                        longestGapBetweenNamed = max(longestGapBetweenNamed, gap)
                        if grams <= 6_000 { longestGapInFirstTenHours = max(longestGapInFirstTenHours, gap) }
                        lastNamedDay = day
                    }
                    if firstElephantDay == nil, crossing.thresholds.contains(where: { $0.landmark?.kind == .elephants(1) }) {
                        firstElephantDay = day
                    }
                }
            }

            XCTAssertLessThanOrEqual(longestHomeWait, 30, "\(pace.sessions)/day")
            XCTAssertEqual(longestHomeWait, pace.longestHomeGap, "\(pace.sessions)/day")
            XCTAssertEqual(longestGapBetweenNamed, pace.longestHomeGap, "\(pace.sessions)/day")
            XCTAssertEqual(longestGapInFirstTenHours, pace.longestFirstTenHours, "\(pace.sessions)/day")
            // ゾウ1頭ぶん: 600,000 min ÷ 25 min/session.
            XCTAssertEqual(firstElephantDay, 24_000 / pace.sessions, "\(pace.sessions)/day")
        }
    }

    // MARK: - Determinism and crossings

    func testTheJourneyDependsOnlyOnTheTotalNotOnHowItWasSplit() {
        // 600 minutes as 1 min × 600, 10 min × 60, 25 min × 24, 600 min × 1.
        for sessionMinutes in [1, 10, 25, 600] {
            var grams = 0
            var crossed: [Int] = []
            for _ in 0..<(600 / sessionMinutes) {
                let next = grams + sessionMinutes * 10
                crossed += Journey.crossing(from: grams, to: next).thresholds.map(\.grams)
                grams = next
            }
            XCTAssertEqual(Journey.state(grams: grams, isProvisional: false),
                           Journey.state(grams: 6_000, isProvisional: false), "\(sessionMinutes)-minute sessions")
            XCTAssertEqual(crossed.sorted(), Journey.crossing(from: 0, to: 6_000).thresholds.map(\.grams).sorted(),
                           "\(sessionMinutes)-minute sessions cross the same thresholds")
        }

        // Same input, same output, across a wide sample.
        var generator = SplitMix64(seed: 0x5EED_1A7E)
        for _ in 0..<2_000 {
            let grams = Int(generator.next() % 100_000_000)
            let isProvisional = generator.next() % 2 == 0
            XCTAssertEqual(Journey.state(grams: grams, isProvisional: isProvisional),
                           Journey.state(grams: grams, isProvisional: isProvisional))
            let step = Int(generator.next() % 4_000)
            XCTAssertEqual(Journey.crossing(from: grams, to: grams + step),
                           Journey.crossing(from: grams, to: grams + step))
        }
    }

    func testACrossingCelebratesTheHighestAndListsTheRest() {
        // A 60-minute completion from 4h to 5h: the core is born and 5 hours
        // is reached in one go.
        let bornAndFive = Journey.crossing(from: 2_400, to: 3_000)
        XCTAssertEqual(bornAndFive.thresholds.map(\.grams), [3_000, 2_500])
        XCTAssertEqual(bornAndFive.highest?.landmark?.minutes, 300)
        XCTAssertEqual(bornAndFive.others.map(\.coreStage), [1])
        XCTAssertEqual(bornAndFive.largestCelebration, .large)
        XCTAssertEqual(bornAndFive.markerCount, 0)

        // One 360-minute completion from zero.
        let long = Journey.crossing(from: 0, to: 3_600)
        XCTAssertEqual(long.thresholds.map(\.grams), [3_000, 2_500, 1_200, 600, 250])

        // 10 hours: the first ◇ and its landmark are one threshold.
        let ten = Journey.crossing(from: 5_990, to: 6_000)
        XCTAssertEqual(ten.thresholds.count, 1)
        XCTAssertEqual(ten.highest?.marker?.ordinal, 1)
        XCTAssertEqual(ten.highest?.landmark?.minutes, 600)
        XCTAssertEqual(ten.markerCount, 1)
        XCTAssertEqual(ten.largestCelebration, .medium)

        // 38h → 42h: an unnamed ◇ at 40h and the core's second stage.
        let fortyish = Journey.crossing(from: 22_800, to: 25_200)
        XCTAssertEqual(fortyish.thresholds.map(\.grams), [25_000, 24_000])
        XCTAssertEqual(fortyish.highest?.coreStage, 2)
        XCTAssertEqual(fortyish.others.first?.marker?.ordinal, 4)
        XCTAssertNil(fortyish.others.first?.landmark)
        XCTAssertEqual(fortyish.others.first?.celebration, .small)

        // 99h → 101h: the tenth ◇ folds into the first 星 at 米俵1俵.
        let star = Journey.crossing(from: 59_400, to: 60_600)
        XCTAssertEqual(star.highest?.marker?.completes, .star)
        XCTAssertEqual(star.highest?.landmark?.comparison, .riceBale)

        // ゾウ1頭ぶん is the only extra-large beat.
        XCTAssertEqual(Journey.crossing(from: 5_999_000, to: 6_000_000).largestCelebration, .extraLarge)
        XCTAssertEqual(Journey.crossing(from: 11_999_000, to: 12_000_000).largestCelebration, .medium)

        // Nothing between equal totals, and nothing on the way down: a deletion
        // walks the journey back without an undo beat (§5.6).
        XCTAssertTrue(Journey.crossing(from: 6_000, to: 6_000).isEmpty)
        XCTAssertTrue(Journey.crossing(from: 60_000, to: 30_000).isEmpty)
        XCTAssertNil(Journey.crossing(from: 60_000, to: 30_000).largestCelebration)
        XCTAssertEqual(Journey.crossing(from: 60_000, to: 30_000).markerCount, 0)
    }

    func testExtremeInputsStayRepresentable() {
        for grams in [-1, Int.min, Int.max, Int.max - 1] {
            let state = Journey.state(grams: grams, isProvisional: false)
            XCTAssertGreaterThanOrEqual(state.grams, 0)
            XCTAssertTrue((0...9).contains(state.markers.diamonds))
            XCTAssertGreaterThanOrEqual(state.nextTarget.grams, 0)
        }
        let everything = Journey.crossing(from: 0, to: Int.max)
        XCTAssertLessThanOrEqual(everything.thresholds.count, 13 + 11 + 10 + 16)
        XCTAssertEqual(everything.thresholds, everything.thresholds.sorted { $0.grams > $1.grams })
        XCTAssertEqual(Journey.state(grams: -500, isProvisional: false), Journey.state(grams: 0, isProvisional: false))
    }
}

/// A tiny deterministic generator, so the sample is the same on every run.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
