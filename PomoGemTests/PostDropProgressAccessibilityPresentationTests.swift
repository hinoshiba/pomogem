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
        XCTAssertTrue(message.contains("旧形式の結晶1個"))
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
        // The fusion sheet says the core was born; 「しくみ」 only says how
        // far its next growth is, in plain words (no 「次の段」).
        XCTAssertEqual(tenth.coreLine, "集中した時間があと37時間30分たまると、時間の核はさらに育ちます")
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

    /// The card that says 「時間の核が生まれました」 on its face (a 50-minute
    /// fifth gem) never says it again inside 「しくみ」, and no level of the
    /// core is named 「次の段」 without saying what it is.
    func testMechanicsNeverRepeatTheCoreBirthNorNameTheNextLevelBare() throws {
        let fifth = CompletionCardPresentation.mechanics(
            effortProgress: EffortProgressPolicy.snapshot(totalGrams: 2_500, latestContributionGrams: 500),
            fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: 5),
            projectionIsLowerBound: false,
            grams: 500,
            weeklyTimerCompletionCount: 5
        )
        XCTAssertEqual(CompletionCardPresentation.coreBirthMoment(
            effortProgress: EffortProgressPolicy.snapshot(totalGrams: 2_500, latestContributionGrams: 500),
            fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: 5),
            projectionIsLowerBound: false
        ), .card)
        XCTAssertEqual(fifth.coreLine, "集中した時間があと37時間30分たまると、時間の核はさらに育ちます")
        let shownWithTheFace = [
            CompletionCardPresentation.coreBirthOnCard,
            fifth.coreLine,
            fifth.unitLine,
            fifth.jarLine
        ].compactMap { $0 }.joined()
        XCTAssertEqual(
            shownWithTheFace.components(separatedBy: "時間の核が生まれました").count - 1,
            1,
            shownWithTheFace
        )

        let second = CompletionCardPresentation.mechanics(
            effortProgress: EffortProgressPolicy.snapshot(totalGrams: 25_000, latestContributionGrams: 250),
            fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: 100),
            projectionIsLowerBound: false,
            grams: 250,
            weeklyTimerCompletionCount: 1
        )
        XCTAssertEqual(
            second.coreLine,
            "時間の核が育ち、2段目になりました。集中した時間があと375時間たまると、さらに育ちます"
        )
        for mechanics in [fifth, second] {
            let visible = [mechanics.coreLine, mechanics.unitLine, mechanics.jarLine].compactMap { $0 }.joined()
            XCTAssertFalse(visible.contains("次の段"), visible)
            XCTAssertFalse(visible.contains("生まれました"), visible)
        }
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

    /// D18: only the jar's very first completion offers 「明日もこの時間に？」,
    /// and only while no reminder time has been chosen.
    func testReminderIsOfferedOnlyOnTheCertainFirstCompletion() {
        XCTAssertTrue(CompletionCardPresentation.offersReminder(
            fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: 1),
            projectionIsLowerBound: false,
            reminderTimeIsChosen: false
        ))
        XCTAssertFalse(CompletionCardPresentation.offersReminder(
            fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: 2),
            projectionIsLowerBound: false,
            reminderTimeIsChosen: false
        ))
        XCTAssertFalse(
            CompletionCardPresentation.offersReminder(
                fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: 1),
                projectionIsLowerBound: true,
                reminderTimeIsChosen: false
            ),
            "A lower bound may hide earlier gems"
        )
        XCTAssertFalse(
            CompletionCardPresentation.offersReminder(
                fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: 1),
                projectionIsLowerBound: false,
                reminderTimeIsChosen: true
            ),
            "An existing reminder (or 先月の瓶のお知らせ, which shares its time) is never moved by the card"
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 7, minute: 30))!
        XCTAssertEqual(
            CompletionCardPresentation.reminderTimeLabel(date, locale: Locale(identifier: "ja_JP")),
            "7:30"
        )
        // The offer names a thing that is off, not a promise.
        XCTAssertEqual(
            CompletionCardPresentation.reminderOfferDetail(time: "7:30"),
            "毎日 7:30 のリマインダー"
        )
        XCTAssertEqual(
            CompletionCardPresentation.spokenReminderOfferDetail(time: "7:30"),
            "毎日 7:30 のリマインダー。今はオフです"
        )
        // With notifications off nothing is promised for a time.
        XCTAssertFalse(CompletionCardPresentation.reminderNeedsPermission.contains("毎日"))
        XCTAssertTrue(CompletionCardPresentation.reminderNeedsPermission.contains("もう一度"))
        XCTAssertNotEqual(
            CompletionCardPresentation.reminderOutcome(.scheduleFailed),
            CompletionCardPresentation.reminderOutcome(.failed)
        )
    }

    /// product-05: the birth of the first time core is taught once, where
    /// it happened: on the fusion sheet when the completion also made the
    /// first ×10 (ten 25-minute gems), otherwise on the card itself.
    func testCoreBirthIsTaughtOnceWhereItHappened() {
        func moment(total: Int, latest: Int, pebbles: Int, lowerBound: Bool = false)
            -> CompletionCardPresentation.CoreBirthMoment {
            CompletionCardPresentation.coreBirthMoment(
                effortProgress: EffortProgressPolicy.snapshot(totalGrams: total, latestContributionGrams: latest),
                fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: pebbles),
                projectionIsLowerBound: lowerBound
            )
        }
        // Ten 25-minute gems: the tenth makes the first ×10 and the core.
        XCTAssertEqual(moment(total: 2_250, latest: 250, pebbles: 9), .none)
        XCTAssertEqual(moment(total: 2_500, latest: 250, pebbles: 10), .fusionSheet)
        XCTAssertEqual(moment(total: 2_750, latest: 250, pebbles: 11), .none)

        // 50-minute gems: the core comes with the fifth gem, no fusion.
        XCTAssertEqual(moment(total: 2_000, latest: 500, pebbles: 4), .none)
        XCTAssertEqual(moment(total: 2_500, latest: 500, pebbles: 5), .card)
        XCTAssertEqual(moment(total: 5_000, latest: 500, pebbles: 10), .none,
                       "The first ×10 of a 50-minute jar teaches nothing again")

        // 15-minute gems: the first ×10 at 1.5kg, the core at the 17th gem.
        XCTAssertEqual(moment(total: 1_500, latest: 150, pebbles: 10), .none)
        XCTAssertEqual(moment(total: 2_400, latest: 150, pebbles: 16), .none)
        XCTAssertEqual(moment(total: 2_550, latest: 150, pebbles: 17), .card)

        // A core that arrives with a later fusion is the card's to say.
        XCTAssertEqual(moment(total: 2_600, latest: 130, pebbles: 20), .card)
        XCTAssertEqual(moment(total: 2_500, latest: 250, pebbles: 10, lowerBound: true), .none)
        XCTAssertEqual(CompletionCardPresentation.coreBirthMoment(
            effortProgress: nil,
            fusionState: FusionRewardBridgePresentation.state(totalPebbleCount: 10),
            projectionIsLowerBound: false
        ), .none)
        XCTAssertEqual(
            CompletionCardPresentation.coreBirthOnCard,
            "時間の核が生まれました。これからは核が、積み上げた時間の重さを表します。"
        )

        func celebration(pebbles: Int, level: Int?) -> PendingStratumCelebration {
            PendingStratumCelebration(
                id: UUID(),
                createdAt: .now,
                pebbleCount: pebbles,
                grams: pebbles * 250,
                monthLabel: "2026年9月",
                colorHex: nil,
                level: level,
                projectionCacheStamp: nil
            )
        }
        XCTAssertTrue(StratumCelebrationTeaching.isTenGemCrystal(celebration(pebbles: 10, level: 1)))
        XCTAssertTrue(StratumCelebrationTeaching.isTenGemCrystal(celebration(pebbles: 10, level: nil)))
        XCTAssertFalse(StratumCelebrationTeaching.isTenGemCrystal(celebration(pebbles: 100, level: 2)))
    }

    /// A gold or rainbow gem and a focus with several 250 g draws are said
    /// in words on the card (quiet mode paints the theme colour).
    func testRareAndMultiDrawOutcomesAreSaidInWords() {
        XCTAssertNil(CompletionCardPresentation.rareLine(
            kind: .normal, counts: RareRewardCounts(drawCount: 1, goldCount: 0, prismCount: 0)))
        XCTAssertNil(CompletionCardPresentation.spokenRareLine(
            kind: .normal, counts: RareRewardCounts(drawCount: 0, goldCount: 0, prismCount: 0)))
        XCTAssertEqual(
            CompletionCardPresentation.rareLine(kind: .gold, counts: RareRewardCounts(drawCount: 1, goldCount: 1, prismCount: 0)),
            "この一粒は金の粒"
        )
        XCTAssertEqual(
            CompletionCardPresentation.spokenRareLine(kind: .prism, counts: RareRewardCounts(drawCount: 1, goldCount: 0, prismCount: 1)),
            "この一粒は虹の粒です。"
        )
        let twoDraws = RareRewardCounts(drawCount: 2, goldCount: 1, prismCount: 0)
        XCTAssertEqual(
            CompletionCardPresentation.rareLine(kind: .gold, counts: twoDraws),
            "250gごとの抽選2回（通常1・金1）"
        )
        XCTAssertEqual(
            CompletionCardPresentation.spokenRareLine(kind: .gold, counts: twoDraws),
            "250グラムごとの抽選が2回あり、内訳は通常1、金1です。"
        )
        XCTAssertEqual(
            CompletionCardPresentation.rareLine(kind: .normal, counts: RareRewardCounts(drawCount: 3, goldCount: 0, prismCount: 0)),
            "250gごとの抽選3回（通常3）"
        )
        XCTAssertEqual(CompletionCardPresentation.sentence("時間の核まで あと3時間45分"), "時間の核まで あと3時間45分。")
    }
}

/// walk-std-12: the onboarding trial gem's words.
final class TrialDropPresentationTests: XCTestCase {
    func testTrialGemSaysWhatOneGemStandsForWithoutACompetingWeight() {
        XCTAssertEqual(TrialDropPresentation.meaning, "25分の集中 = この一粒（+250g）")
        XCTAssertEqual(TrialDropPresentation.spokenMeaning, "25分の集中が、この一粒（250グラム）になります")
        XCTAssertFalse(TrialDropPresentation.trialNote.contains("0g"),
                       "「0g」 right under 「+250g」 read as a contradiction")
        XCTAssertTrue(TrialDropPresentation.trialNote.contains("記録には入りません"))
    }
}
