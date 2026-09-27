import XCTest
@testable import PomoGem

final class PostDropProgressAccessibilityPresentationTests: XCTestCase {
    func testJarAnnouncesMassBeforeCountBasedOrganizationAndAchievements() throws {
        let message = JarAccessibilityPresentation.value(
            totalGrams: 3_100,
            pebbleCount: 2,
            achievementCount: 1,
            aggregateCount: 1,
            representedPebbleCount: 12,
            goldPebbleCount: 1,
            prismPebbleCount: 0,
            fusionProgressDescription: "×100へ 1/10",
            projectionIsLowerBound: false
        )

        let massRange = try XCTUnwrap(message.range(of: "集中時間の質量：3.10キログラム"))
        let organizationRange = try XCTUnwrap(message.range(of: "瓶の整理"))
        let achievementRange = try XCTUnwrap(message.range(of: "記念石1個"))
        XCTAssertLessThan(massRange.lowerBound, organizationRange.lowerBound)
        XCTAssertLessThan(organizationRange.lowerBound, achievementRange.lowerBound)
        XCTAssertTrue(message.contains("合計12粒分"))
        XCTAssertFalse(message.contains("金1粒"))
        XCTAssertTrue(message.contains("×100へ 1/10"))
    }

    func testJarNeverClaimsAnExactMassDuringPartialProjection() {
        let message = JarAccessibilityPresentation.value(
            totalGrams: 600,
            pebbleCount: 1,
            achievementCount: 0,
            aggregateCount: 0,
            representedPebbleCount: 1,
            goldPebbleCount: 0,
            prismPebbleCount: 0,
            fusionProgressDescription: nil,
            projectionIsLowerBound: true
        )

        XCTAssertTrue(message.hasPrefix("現在確認できた集中時間の質量：600グラム以上、集計整理中"))
        XCTAssertFalse(message.hasPrefix("記録した集中時間の質量"))
    }

    func testJarDisclosesLegacyAggregateWithoutAddingItToModernTotals() {
        let message = JarAccessibilityPresentation.value(
            totalGrams: 500,
            pebbleCount: 2,
            achievementCount: 0,
            aggregateCount: 0,
            legacyAggregateCount: 1,
            representedPebbleCount: 2,
            goldPebbleCount: 0,
            prismPebbleCount: 0,
            fusionProgressDescription: nil,
            projectionIsLowerBound: false
        )

        XCTAssertTrue(message.contains("瓶の整理：2粒"))
        XCTAssertTrue(message.contains("旧形式のまとまり粒1個"))
        XCTAssertFalse(message.contains("合計2粒分"))
    }

    func testMassReceiptAnnouncesEffortBeforeSecondaryJarOrganization() throws {
        let message = PostDropProgressAccessibilityPresentation.description(
            effortProgress: EffortProgressPolicy.snapshot(
                totalGrams: 3_100,
                latestContributionGrams: 600
            ),
            fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: 10),
            projectionIsLowerBound: false
        )

        let effortRange = try XCTUnwrap(message.range(of: "時間の核"))
        let organizationRange = try XCTUnwrap(message.range(of: "瓶の整理"))
        XCTAssertLessThan(effortRange.lowerBound, organizationRange.lowerBound)
        XCTAssertTrue(message.contains("5時間10分"))
        XCTAssertTrue(message.contains("10/10"))
    }

    func testPartialMassReceiptStillLeadsWithKnownContribution() {
        let message = PostDropProgressAccessibilityPresentation.description(
            effortProgress: EffortProgressPolicy.snapshot(
                totalGrams: 600,
                latestContributionGrams: 600
            ),
            fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: 3),
            projectionIsLowerBound: true
        )

        XCTAssertTrue(message.hasPrefix("今回の完走で1時間を追加"))
        XCTAssertTrue(message.contains("時間の核を整理中"))
        XCTAssertTrue(message.contains("瓶の整理"))
        XCTAssertTrue(message.contains("結晶進捗を整理中"))
    }

    func testLegacyReceiptKeepsCountCompatibilityPresentation() {
        let message = PostDropProgressAccessibilityPresentation.description(
            effortProgress: nil,
            fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: 9),
            projectionIsLowerBound: false
        )

        XCTAssertTrue(message.hasPrefix("×10へ 9/10"))
        XCTAssertTrue(message.contains("あと1粒"))
        XCTAssertFalse(message.contains("時間の核"))
    }
}

/// The completion card's copy (Docs/GemExperienceDesign.md §8.3,
/// walk-std-07/08, product-05): time first and grams second, an honest
/// week, and the mechanics only behind 「しくみ」.
final class CompletionCardPresentationTests: XCTestCase {
    func testMainLineLeadsWithTimeThenGrams() {
        XCTAssertEqual(
            CompletionCardPresentation.mainLine(subjectName: "英語", grams: 250),
            "英語 25分 → +250gの一粒"
        )
        XCTAssertEqual(
            CompletionCardPresentation.mainLine(subjectName: "数学", grams: 600),
            "数学 1時間 → +600gの一粒"
        )
        XCTAssertEqual(
            CompletionCardPresentation.mainLine(subjectName: "English", grams: 1_800),
            "English 3時間 → +1.8kgの一粒",
            "The theme name is the person's own text"
        )
        XCTAssertEqual(
            CompletionCardPresentation.spokenMainLine(subjectName: "英語", grams: 250),
            "英語、25分、250グラムの一粒。"
        )
    }

    func testWeekLineNamesSelfReportedFocusInTheSameSentence() {
        XCTAssertEqual(
            CompletionCardPresentation.weekLine(measuredGrams: 750, selfReportedGrams: 0),
            "今週の実測 1時間15分"
        )
        XCTAssertEqual(
            CompletionCardPresentation.weekLine(measuredGrams: 750, selfReportedGrams: 300),
            "今週の実測 1時間15分・自己申告 30分"
        )
        XCTAssertEqual(
            CompletionCardPresentation.spokenWeekLine(measuredGrams: 750, selfReportedGrams: 300),
            "今週の実測は1時間15分、自己申告は30分。"
        )
    }

    func testMechanicsKeepTheAccountingInPlainWordsWithoutJargon() throws {
        let first = CompletionCardPresentation.mechanics(
            effortProgress: EffortProgressPolicy.snapshot(totalGrams: 250, latestContributionGrams: 250),
            fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: 1),
            projectionIsLowerBound: false,
            grams: 250,
            weeklyTimerCompletionCount: 1
        )
        XCTAssertEqual(first.coreLine, "時間の核まで あと3時間45分")
        XCTAssertEqual(try XCTUnwrap(first.coreFraction), 0.1, accuracy: 0.0001)
        XCTAssertTrue(try XCTUnwrap(first.unitLine).contains("1.0標準単位"))
        XCTAssertTrue(first.jarLine.contains("次の結晶まで あと9粒"), first.jarLine)
        XCTAssertEqual(first.weekCountLine, "今週のタイマー完走は1回です。回数は時間の価値とは別です。")
        let visible = [first.coreLine, first.unitLine, first.jarLine, first.weekCountLine].compactMap { $0 }.joined()
        for jargon in ["TIME CORE", "最初の時間の核", "戻った", "瓶の整理"] {
            XCTAssertFalse(visible.contains(jargon), "「\(jargon)」 in \(visible)")
        }

        let tenth = CompletionCardPresentation.mechanics(
            effortProgress: EffortProgressPolicy.snapshot(totalGrams: 2_500, latestContributionGrams: 250),
            fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: 10),
            projectionIsLowerBound: false,
            grams: 250,
            weeklyTimerCompletionCount: 0
        )
        XCTAssertEqual(tenth.coreLine, "時間の核が生まれました。次の段まで あと37時間30分")
        XCTAssertEqual(tenth.coreFraction, 1)
        XCTAssertTrue(tenth.jarLine.contains("10粒がそろい"), tenth.jarLine)
        XCTAssertNil(tenth.weekCountLine)

        let partial = CompletionCardPresentation.mechanics(
            effortProgress: EffortProgressPolicy.snapshot(totalGrams: 600, latestContributionGrams: 600),
            fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: 3),
            projectionIsLowerBound: true,
            grams: 600,
            weeklyTimerCompletionCount: 1
        )
        XCTAssertEqual(partial.coreLine, "時間の核の進みを確認しています")
        XCTAssertNil(partial.coreFraction)
        XCTAssertFalse(partial.jarLine.contains("あと"), "A lower bound never claims a position")

        let legacy = CompletionCardPresentation.mechanics(
            effortProgress: nil,
            fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: 9),
            projectionIsLowerBound: false,
            grams: 250,
            weeklyTimerCompletionCount: 2
        )
        XCTAssertNil(legacy.coreLine)
        XCTAssertNil(legacy.unitLine)
        XCTAssertTrue(legacy.jarLine.contains("あと1粒"), legacy.jarLine)
    }

    func testRemainingTimeNeverClaimsLessThanIsLeft() {
        // 2,245 g left is 224.5 minutes: 「あと3時間45分」, not 44.
        let mechanics = CompletionCardPresentation.mechanics(
            effortProgress: EffortProgressPolicy.snapshot(totalGrams: 255, latestContributionGrams: 255),
            fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: 1),
            projectionIsLowerBound: false,
            grams: 255,
            weeklyTimerCompletionCount: 1
        )
        XCTAssertEqual(mechanics.coreLine, "時間の核まで あと3時間45分")
    }

    func testStandardUnitsAndMassKeepTheirFamiliarForms() {
        XCTAssertEqual(CompletionCardPresentation.standardUnits(grams: 100), "0.4")
        XCTAssertEqual(CompletionCardPresentation.standardUnits(grams: 250), "1.0")
        XCTAssertEqual(CompletionCardPresentation.standardUnits(grams: 600), "2.4")
        XCTAssertEqual(CompletionCardPresentation.mass(grams: 250), "250g")
        XCTAssertEqual(CompletionCardPresentation.mass(grams: 2_500), "2.5kg")
        XCTAssertEqual(CompletionCardPresentation.mass(grams: 1_250), "1.25kg")
    }
}
