import Foundation
import XCTest
@testable import PomoGem

/// English expectations for localization package l10n-05-share-jar (tables: Share and Jar).
///
/// Only that package edits this file (Docs/Localization.md). Resolve English
/// explicitly with `LocalizationTestSupport.englishBundle()` and
/// `LocalizationTestSupport.english`, which skip until English is activated;
/// never change the process language, because the rest of the suite asserts
/// Japanese.
///
/// The Japanese half of each test pins the text the share composer, the share
/// card, its caption and the jar's VoiceOver built by hand before they were
/// localized, byte for byte.
final class ShareJarLocalizationTests: XCTestCase {
    private let en = LocalizationTestSupport.english
    private let ja = LocalizationTestSupport.japanese

    /// The English value of a key, formatted like the app formats it.
    private func english(_ key: String, table: String = "Share", _ arguments: CVarArg...) throws -> String {
        let bundle = try LocalizationTestSupport.englishBundle()
        let format = bundle.localizedString(forKey: key, value: "<missing \(key)>", table: table)
        return arguments.isEmpty ? format : String(format: format, locale: en, arguments: arguments)
    }

    // MARK: Caption and hashtags

    func testCaptionJapaneseIsUnchanged() {
        XCTAssertEqual(ShareCopy.hashtags, ["#ポモジェム", "#ポモドーロ"])
        XCTAssertEqual(ShareCopy.suggestedHashtags, ["#勉強記録", "#勉強垢"])
        XCTAssertEqual(
            ShareCopy.caption(
                subject: "これまでの集中",
                grams: "2,500g",
                focusTime: "4時間10分",
                includesSelfReportedFocus: true,
                achievementCount: 1,
                rewardDetail: "報酬内訳：記念石：100点1個",
                visualDisclosure: "瓶は代表表示（ほか集中粒48粒）",
                hashtags: ["#ポモジェム"]
            ),
            "これまでの集中を 2,500g（4時間10分）積みました（自己申告の集中を含む・記念石は自己申告）。\n"
                + "報酬内訳：記念石：100点1個。瓶は代表表示（ほか集中粒48粒）。\n"
                + "https://pomogem.hinoshiba.com/\n#ポモジェム"
        )
        XCTAssertEqual(
            ShareCopy.caption(subject: "今月の集中", grams: "0g", includesSelfReportedFocus: false, achievementCount: 0, hashtags: []),
            "今月の集中を 0g 積みました。\nhttps://pomogem.hinoshiba.com/"
        )
        XCTAssertEqual(
            ShareCopy.caption(subject: "今月の集中", grams: "250g", focusTime: "25分", includesSelfReportedFocus: false, achievementCount: 0, hashtags: []),
            "今月の集中を 250g（25分）積みました。\nhttps://pomogem.hinoshiba.com/"
        )
        XCTAssertEqual(
            ShareCopy.caption(subject: "今月の集中", grams: "0g", includesSelfReportedFocus: false, achievementCount: 2, hashtags: []),
            "今月の集中を 0g 積みました（記念石は自己申告）。\nhttps://pomogem.hinoshiba.com/"
        )
    }

    func testEnglishHashtagsAreValidDistinctAndLocal() throws {
        let defaults = try ["#ポモジェム", "#ポモドーロ"].map { try english($0) }
        let suggestions = try english("#勉強記録 #勉強垢").split(separator: " ").map(String.init)
        XCTAssertEqual(defaults, ["#PomoGem", "#pomodoro"], "DECISIONS.md #7")
        XCTAssertEqual(suggestions, ["#studywithme"], "DECISIONS.md #7: one unselected suggestion")
        let all = defaults + suggestions
        for tag in all {
            XCTAssertEqual(ShareHashtagPolicy.normalized(tag), tag, "every chip must survive the caption's validation")
        }
        XCTAssertEqual(Set(all.map { $0.lowercased() }).count, all.count, "the chips are identified by their text")
    }

    func testEnglishCaptionSentences() throws {
        XCTAssertEqual(
            try english("%@を %@（%@）積みました（%@）。", "My focus so far", "2,500 g", "4 hr 10 min", "Includes self-reported focus"),
            "My focus so far: 2,500 g (4 hr 10 min) added to my jar. Includes self-reported focus."
        )
        XCTAssertEqual(
            try english("%@を %@（%@）積みました。", "My focus in September 2026", "250 g", "25 min"),
            "My focus in September 2026: 250 g (25 min) added to my jar."
        )
        XCTAssertEqual(
            try english("%@を %@ 積みました（%@）。", "My focus so far", "0 g", "Milestone stones are self-reported"),
            "My focus so far: 0 g added to my jar. Milestone stones are self-reported."
        )
        XCTAssertEqual(try english("%@を %@ 積みました。", "My focus so far", "0 g"), "My focus so far: 0 g added to my jar.")
        XCTAssertEqual(try english("%@。", "The jar shows a sample (not drawn: 48 focus gems)"), "The jar shows a sample (not drawn: 48 focus gems).")
        XCTAssertEqual(try english("share.caption.subject.month", "September 2026"), "My focus in September 2026")
        XCTAssertEqual(try english("%@の集中", "4 hr 10 min"), "4 hr 10 min of focus", "the card's line under the mass")
        XCTAssertEqual(try english("これまでの集中（記念石は最新%lld個）", 60), "My focus so far (newest 60 milestone stones)")
        XCTAssertEqual(try english("瓶は代表表示（ほか%@）", "48 focus gems · 17 crystals"), "The jar shows a sample (not drawn: 48 focus gems · 17 crystals)")
    }

    func testCaptionDetailsJapaneseIsUnchanged() {
        let semantics = ShareRewardSemantics(
            goldCount: 2,
            prismCount: 1,
            achievementKinds: [.perfectScore, .examPass, .examPass, .workMilestone],
            presentsRareRewards: true
        )
        XCTAssertEqual(
            semantics.captionDetail,
            "報酬内訳：金のレア粒2粒・虹のレア粒1粒／記念石：100点1個・試験合格2個・仕事の節目1個"
        )
        XCTAssertEqual(
            semantics.accessibilityDetail,
            "金のレア粒2粒、虹のレア粒1粒。記念石の内訳、100点1個、試験合格2個、仕事の節目1個"
        )
        let stonesOnly = ShareRewardSemantics(goldCount: 0, prismCount: 0, achievementKinds: [.examPass], presentsRareRewards: false)
        XCTAssertEqual(stonesOnly.captionDetail, "報酬内訳：記念石：試験合格1個")
        XCTAssertEqual(stonesOnly.accessibilityDetail, "記念石の内訳、試験合格1個")
        XCTAssertEqual(
            ShareRewardSemantics(goldCount: 0, prismCount: 0, achievementKinds: [], presentsRareRewards: true).accessibilityDetail,
            "レア粒なし。記念石なし"
        )

        let hidden = ShareHiddenContent(loosePebbleCount: 1_500, aggregateCount: 17, achievementCount: 9)
        XCTAssertEqual(hidden.compactLabel, "代表表示 +1526", "the chip keeps its ungrouped number")
        // A counted noun interpolates its Int for the English plural, which
        // groups from 1,000 as 結晶%lld個 already did (Docs/Localization.md);
        // below 1,000 the text is exactly as before.
        XCTAssertEqual(hidden.captionDisclosure, "瓶は代表表示（ほか集中粒1,500粒・結晶17個・記念石9個）")
        XCTAssertEqual(
            ShareHiddenContent(loosePebbleCount: 48, aggregateCount: 17, achievementCount: 9).captionDisclosure,
            "瓶は代表表示（ほか集中粒48粒・結晶17個・記念石9個）"
        )
    }

    func testEnglishPluralsOnTheCardAndInTheComposer() throws {
        XCTAssertEqual(try english("タグ%lld個", 1), "1 hashtag")
        XCTAssertEqual(try english("タグ%lld個", 3), "3 hashtags")
        XCTAssertEqual(try english("%lld粒の積み重ね", 1), "1 gem added")
        XCTAssertEqual(try english("%lld粒の積み重ね", 1_250), "1,250 gems added")
        XCTAssertEqual(try english("%lld個の記念石", 1), "1 milestone stone")
        XCTAssertEqual(try english("実測 %lld粒", 1), "1 timed gem")
        XCTAssertEqual(try english("実測 %lld粒", 12), "12 timed gems")
        XCTAssertEqual(try english("結晶 %lld", 1), "1 crystal")
        XCTAssertEqual(try english("記念石 %lld", 2), "2 milestone stones")
        XCTAssertEqual(try english("集中粒%lld粒", 48), "48 focus gems")
        XCTAssertEqual(try english("結晶%lld個", 1), "1 crystal")
        XCTAssertEqual(try english("記念石%lld個", 9), "9 milestone stones")
        XCTAssertEqual(try english("うち実測%lld粒", 1), "including 1 timed gem")
        XCTAssertEqual(try english("金のレア粒%lld粒", 1), "1 gold rare gem")
        XCTAssertEqual(try english("文字・数字・_ のみ、%lld文字まで。本文やURLは追加しません。", ShareHashtagPolicy.maximumBodyLength),
                       "Letters, numbers and _ only, up to 30 characters. Text and links can't be added here.")
        XCTAssertEqual(try english("%@%lld個", "Passed an exam", 2), "Passed an exam (2)")
    }

    // MARK: Share card VoiceOver

    func testCardVoiceOverJapaneseIsUnchanged() {
        let sessions = (0..<3).map { index in
            ShareSessionVisual(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                grams: 250,
                source: .timer,
                kind: .normal,
                rewardCounts: RareRewardCounts(drawCount: 1, goldCount: 0, prismCount: 0),
                colorHex: Constants.Color.mathematics,
                endAt: Date(timeIntervalSinceReferenceDate: Double(index * 1_500))
            )
        }
        let card = ShareCardView(
            sessions: sessions,
            aggregates: [],
            achievements: [
                ShareAchievementVisual(
                    id: UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!,
                    kind: .perfectScore,
                    colorHex: Constants.Color.english
                )
            ],
            includesSelfReportedFocus: false,
            format: .feed,
            jarSnapshot: nil,
            periodLabel: "これまで",
            hashtags: ["#ポモジェム", "#ポモドーロ"],
            animationPhase: 0
        )
        XCTAssertEqual(
            card.accessibilityDescription,
            "ポモジェムシェアカード。これまで。瓶に積んだ集中、750グラム、1時間15分。3粒、うち実測3粒、結晶0個、記念石1個。"
                + "記念石の内訳、100点1個。すべての石を表示。記念石は自己申告。公式サイト、pomogem.hinoshiba.com。"
                + "ハッシュタグ、#ポモジェム、#ポモドーロ"
        )
    }

    func testCardVoiceOverInEnglish() throws {
        XCTAssertEqual(try english("ポモジェムシェアカード。"), "PomoGem share card.")
        XCTAssertEqual(try english("瓶に積んだ集中、%@、%@。", "750 grams", "1 hour, 15 minutes"), "Focus in the jar: 750 grams, 1 hour, 15 minutes.")
        XCTAssertEqual(try english("公式サイト、%@。", ShareCopy.websiteDisplayName), "Official website: pomogem.hinoshiba.com.")
        XCTAssertEqual(try english("ハッシュタグ、%@", "#PomoGem and #pomodoro"), "Hashtags: #PomoGem and #pomodoro")
        XCTAssertEqual(try english("記念石は自己申告"), "Milestone stones are self-reported")
        XCTAssertEqual(try english("すべての石を表示"), "Every gem and stone is shown")
    }

    // MARK: Period labels

    func testMonthLabelsFollowTheAppLanguage() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        XCTAssertEqual(ShareScope.displayMonthLabel("2026年9月", locale: ja, timeZone: tokyo), "2026年9月")
        XCTAssertEqual(ShareScope.displayMonthLabel("1985年12月", locale: ja, timeZone: tokyo), "1985年12月")
        XCTAssertEqual(ShareScope.displayMonthLabel("2026年9月", locale: en, timeZone: tokyo), "September 2026")
        XCTAssertEqual(ShareScope.displayMonthLabel("2026年13月", locale: en, timeZone: tokyo), "2026年13月", "an unknown shape is shown as stored")
        XCTAssertEqual(ShareScope.displayMonthLabel("", locale: en, timeZone: tokyo), "")
        let september = try XCTUnwrap(PomoGemCalendar.gregorian.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        XCTAssertEqual(ShareScope.month(september).periodLabel, "2026年9月")
        XCTAssertEqual(ShareScope.aggregate(id: UUID(), monthLabel: "2026年9月").periodLabel, "2026年9月")
        XCTAssertEqual(ShareScope.all.periodLabel, "これまで")
        XCTAssertEqual(try english("これまで"), "So far")
        XCTAssertEqual(try english("%@・表示分", "September 2026"), "September 2026 · partial")
        XCTAssertEqual(try english("最近の記録・最新%@件", String(BoundedHistoryPolicy.periodSessionLimit)), "Recent · newest 2048 records")
    }

    // MARK: Jar VoiceOver

    func testJarValueJapaneseIsUnchanged() {
        XCTAssertEqual(
            JarAccessibilityPresentation.value(
                totalGrams: 3_100,
                pebbleCount: 2,
                achievementCount: 1,
                aggregateCount: 1,
                legacyAggregateCount: 1,
                representedPebbleCount: 12,
                goldPebbleCount: 0,
                prismPebbleCount: 0,
                fusionProgressDescription: "×100へ 1/10",
                projectionIsLowerBound: false
            ),
            "記録した集中時間の質量：3.10キログラム。瓶の整理：2粒、結晶1個、合計12粒分、旧形式の結晶1個（保存済み情報を確認できます）、×100へ 1/10。記念石1個"
        )
        XCTAssertEqual(
            JarAccessibilityPresentation.value(
                totalGrams: 600,
                pebbleCount: 2,
                achievementCount: 0,
                aggregateCount: 0,
                representedPebbleCount: 2,
                goldPebbleCount: 0,
                prismPebbleCount: 0,
                fusionProgressDescription: "×10へ 2/10",
                projectionIsLowerBound: false,
                projectionIsUnverified: true,
                pendingMass: .init(grams: 600, isLowerBound: true)
            ),
            "iCloudを確認中。この端末で確認済みの集中時間の質量：600グラム以上。瓶の整理：2粒。記念石0個"
        )
        XCTAssertEqual(
            JarAccessibilityPresentation.value(
                totalGrams: 0,
                pebbleCount: 0,
                achievementCount: 0,
                aggregateCount: 0,
                representedPebbleCount: 0,
                goldPebbleCount: 0,
                prismPebbleCount: 0,
                fusionProgressDescription: nil,
                projectionIsLowerBound: false,
                projectionIsUnverified: true,
                isCloudOfflineSession: true
            ),
            "このiPhoneの集計を確認中。これまでの合計は確認が済むと表示します。瓶の整理：0粒。記念石0個"
        )
    }

    func testJarValueInEnglish() throws {
        XCTAssertEqual(try english("記録した集中時間の質量：%@。", table: "Jar", "3.10 kilograms"), "Mass of recorded focus time: 3.10 kilograms.")
        XCTAssertEqual(try english("瓶の整理：%@。", table: "Jar", "2 gems and 1 crystal holding 12 gems"), "In the jar: 2 gems and 1 crystal holding 12 gems.")
        let crystals = try english("結晶%lld個", table: "Jar", 1)
        let held = try english("合計%lld粒分", table: "Jar", 12)
        XCTAssertEqual(try english("jar.value.crystals", table: "Jar", crystals, held), "1 crystal holding 12 gems")
        XCTAssertEqual(try english("記念石%lld個", table: "Jar", 1), "1 milestone stone")
        XCTAssertEqual(try english("旧形式の結晶%lld個（保存済み情報を確認できます）", table: "Jar", 2),
                       "2 crystals in the old format (their saved details can be opened)")
        XCTAssertEqual(
            try english("%@。この端末で確認済みの集中時間の質量：%@以上。", table: "Jar", "Checking iCloud", "600 grams"),
            "Checking iCloud. Mass of focus time confirmed on this device: at least 600 grams."
        )
        XCTAssertEqual(try english("瓶", table: "Jar"), "Jar")
        XCTAssertEqual(try english("最新の結晶の内訳を見る", table: "Jar"), "View Newest Crystal Details")
    }

    func testBlackStonesInBothLanguages() throws {
        let stone = ScreenTimeObstacleDescriptor(level: 1, slot: 0, representedUnits: 1_000, isHistoryPile: false)
        XCTAssertEqual(stone.accessibilityDescription, "寄り道の黒い石、10分の石1,000個分。勉強の積み上げには含まれません")

        let stones = try english("寄り道の黒い石%lld個", table: "Jar", 1)
        let units = try english("10分の石%lld個分", table: "Jar", 12)
        XCTAssertEqual(
            try english("%@、%@。", table: "Jar", stones, units),
            "1 black stone from apps you want to use less, worth 12 ten-minute stones."
        )
        XCTAssertEqual(try english("勉強の積み上げには含まれません", table: "Jar"), "Not part of your study progress")
        XCTAssertEqual(
            try english("寄り道の黒い石、10分の石%lld個分。勉強の積み上げには含まれません", table: "Jar", 1),
            "Black stone from apps you want to use less, worth 1 ten-minute stone. Not part of your study progress"
        )
    }

    func testCrystalAndGemVoiceOverJapaneseIsUnchanged() {
        let metadata = AggregateMetadata(
            level: 1,
            pebbleCount: 10,
            childAggregateCount: 0,
            colorMix: [],
            subjectMix: [
                AggregateSubjectFraction(name: "英語", colorHex: "E85D4A", pebbleCount: 7),
                AggregateSubjectFraction(name: "数学", colorHex: "4A90E2", pebbleCount: 3)
            ],
            periodStart: Date(timeIntervalSinceReferenceDate: 0),
            periodEnd: Date(timeIntervalSinceReferenceDate: 0),
            sessionIDs: [],
            measuredPebbleCount: 7,
            manualPebbleCount: 3,
            goldPebbleCount: 0,
            prismPebbleCount: 0
        )
        XCTAssertEqual(metadata.accessibilityDescription, "英語など、10粒を含むまとまり粒、実測7粒、自己申告3粒")

        let legacy = AggregateMetadata(
            level: 2,
            pebbleCount: 100,
            childAggregateCount: 10,
            colorMix: [],
            subjectMix: [],
            periodStart: Date(timeIntervalSinceReferenceDate: 0),
            periodEnd: Date(timeIntervalSinceReferenceDate: 0),
            sessionIDs: [],
            measuredPebbleCount: 100,
            manualPebbleCount: 0,
            goldPebbleCount: 0,
            prismPebbleCount: 0
        )
        XCTAssertEqual(legacy.primarySubjectName, "過去の集中", "the stored sentinel stays Japanese data")
        XCTAssertEqual(legacy.accessibilityDescription, "過去の集中、100粒、10個のまとまりを含むまとまり粒、実測100粒")
    }

    func testCrystalAndGemVoiceOverInEnglish() throws {
        XCTAssertEqual(try english("%lld粒を含むまとまり粒", table: "Jar", 10), "crystal holding 10 gems")
        XCTAssertEqual(try english("%lld粒、%lld個のまとまりを含むまとまり粒", table: "Jar", 100, 10),
                       "crystal holding 100 gems (smaller crystals inside: 10)")
        XCTAssertEqual(try english("%@など", table: "Jar", "English"), "English and others")
        XCTAssertEqual(try english("実測%lld粒", table: "Jar", 1), "1 timed gem")
        XCTAssertEqual(try english("自己申告%lld粒", table: "Jar", 3), "3 self-reported gems")
        XCTAssertEqual(try english("実測のつぶ", table: "Jar"), "timed gem")
        XCTAssertEqual(try english("スクリーンタイムのつぶ", table: "Jar"), "Screen Time gem")
        XCTAssertEqual(try english("%@、%@の記念石、質量には含まれません", table: "Jar", "English", "Perfect score"),
                       "English, milestone stone: Perfect score, adds no mass")
    }

    func testPreThemeHistoryIsNamedOnlyForDisplay() throws {
        XCTAssertEqual(JarSubjectDisplayName.name("過去の集中"), "過去の集中")
        XCTAssertEqual(JarSubjectDisplayName.name("過去の集中 2"), "過去の集中 2")
        XCTAssertEqual(JarSubjectDisplayName.name("英語"), "英語")

        let bundle = try LocalizationTestSupport.englishBundle()
        XCTAssertEqual(JarSubjectDisplayName.name("過去の集中", bundle: bundle, locale: en), "Earlier focus")
        XCTAssertEqual(JarSubjectDisplayName.name("過去の集中 3", bundle: bundle, locale: en), "Earlier focus 3")
        XCTAssertEqual(JarSubjectDisplayName.name("過去の集中 x", bundle: bundle, locale: en), "過去の集中 x", "only the stored shapes are mapped")
        XCTAssertEqual(JarSubjectDisplayName.name("My theme", bundle: bundle, locale: en), "My theme")
    }

    // MARK: Whole tables

    /// Every English value of both tables reads as English and keeps the
    /// glossary nouns (the check script enforces the rest).
    func testNoEnglishValueUsesRetiredNouns() throws {
        // Whole words only: "earn" must not match "learn".
        let retired = try NSRegularExpression(pattern: #"\b(bottles?|pebbles?|streaks?|earn(s|ed|ing)?)\b"#, options: [.caseInsensitive])
        for table in ["Share", "Jar"] {
            let catalog = try LocalizationCatalogFile(table: table, relativePath: "PomoGem/Localization/\(table).xcstrings")
            for (key, entry) in catalog.strings {
                let english = try XCTUnwrap(LocalizationCatalogFile.localizations(of: entry)["en"], "\(table): \(key) has no English")
                for unit in LocalizationCatalogFile.units(of: english) {
                    XCTAssertFalse(LocalizationTestSupport.containsJapanese(unit.value), "\(table): \(key) → \(unit.value)")
                    let range = NSRange(unit.value.startIndex..., in: unit.value)
                    XCTAssertNil(retired.firstMatch(in: unit.value, range: range), "\(table): \(key) → \(unit.value)")
                }
            }
        }
    }
}
