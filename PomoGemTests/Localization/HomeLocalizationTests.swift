import Foundation
import XCTest
@testable import PomoGem

/// English expectations for localization package l10n-01-home (tables: Home
/// and Widgets): Home, its sheets (menu, manual entry, achievement, custom
/// length, completion card, fusion sheet), the widgets and the Live Activity.
///
/// Only that package edits this file (Docs/Localization.md). Resolve English
/// explicitly with `LocalizationTestSupport.englishBundle()` and
/// `LocalizationTestSupport.english`, which skip until English is activated;
/// never change the process language, because the rest of the suite asserts
/// Japanese.
final class HomeLocalizationTests: XCTestCase {
    private let en = LocalizationTestSupport.english
    private let ja = LocalizationTestSupport.japanese

    /// A Home key in English, formatted for en_US (plural forms included).
    private func english(_ value: String.LocalizationValue) throws -> String {
        String(localized: value, table: "Home", bundle: try LocalizationTestSupport.englishBundle(), locale: en)
    }

    private func widgetBundle() throws -> Bundle {
        let bundle = try XCTUnwrap(
            LocalizationTestSupport.productBundles().first { $0.name == "PomoGemWidgets.appex" }?.bundle,
            "the widget extension is embedded in the app"
        )
        return try LocalizationTestSupport.englishBundle(in: bundle)
    }

    /// A Widgets key in English, resolved from the widget extension's own
    /// bundle, the way the widget and the Live Activity resolve it.
    private func widgetEnglish(_ value: String.LocalizationValue) throws -> String {
        String(localized: value, table: "Widgets", bundle: try widgetBundle(), locale: en)
    }

    // MARK: Japanese stays as it was

    func testNewHelpersKeepTheJapaneseHomePrinted() {
        XCTAssertEqual(HomeView.compactPair("12粒", "記念石 3"), "12粒 ・ 記念石 3")
        XCTAssertEqual(HomeView.spokenPhrases(["累計12 kg", "集中12粒", "記念石3個"]), "累計12 kg、集中12粒、記念石3個")
        XCTAssertEqual(HomeView.spokenPhrases(["深夜", "静かな定番"]), "深夜、静かな定番")
        XCTAssertEqual(HomeView.spokenPhrases(["時間の核の進み"]), "時間の核の進み")
        XCTAssertEqual(HomeView.spokenSentence("今週の完走5回"), "今週の完走5回。")
        XCTAssertEqual(ThemeSelectionMenu.accessibilityLabel(for: nil), "テーマ、未選択")
        XCTAssertEqual(ManualEntrySheet.dayBoundaryTimeLabel(), "4:00")
        XCTAssertEqual(
            ListText.compact(ManualDuration.allCases.map { DurationText.short(minutes: $0.minutes) }),
            "30分・1時間・2時間"
        )
        XCTAssertEqual(ListText.compact(AchievementKind.allCases.map(\.title)), "100点・試験合格・仕事の節目")
    }

    /// 「朝4:00」: Japanese keeps the bare clock digits whatever the iPhone's
    /// 12/24-hour setting; English reads its own clock.
    func testDayBoundaryReadsAsATimeOfDay() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        for identifier in ["ja_JP", "ja_JP@hours=h12", "ja_JP@hours=h23"] {
            XCTAssertEqual(
                ManualEntrySheet.dayBoundaryTimeLabel(locale: Locale(identifier: identifier), timeZone: tokyo),
                "4:00",
                identifier
            )
        }
        let american = ManualEntrySheet.dayBoundaryTimeLabel(locale: en, timeZone: tokyo)
        XCTAssertEqual(american.replacingOccurrences(of: "\u{202F}", with: " "), "4:00 AM")
        XCTAssertEqual(ManualEntrySheet.dayBoundaryTimeLabel(locale: Locale(identifier: "en_GB"), timeZone: tokyo), "04:00")
    }

    func testLiveActivityLengthKeepsItsJapaneseAndReadsEnglishUnits() {
        XCTAssertEqual(FocusActivityConstants.durationLabel(seconds: 1_500), "25分")
        XCTAssertEqual(FocusActivityConstants.durationLabel(seconds: 90), "1分30秒")
        XCTAssertEqual(FocusActivityConstants.durationLabel(seconds: 0), "0分")
        XCTAssertEqual(FocusActivityConstants.durationLabel(seconds: 1_500, locale: en), "25 min")
        XCTAssertEqual(FocusActivityConstants.durationLabel(seconds: 90, locale: en), "1 min 30 sec")
        XCTAssertEqual(FocusActivityConstants.durationLabel(seconds: 12, locale: en), "12 sec")
        XCTAssertEqual(FocusActivityConstants.durationLabel(seconds: 21_600, locale: en), "360 min")
        XCTAssertEqual(FocusActivityConstants.durationLabel(seconds: -1, locale: en), "0 min")
    }

    // MARK: Home

    func testHomeInEnglish() throws {
        let focusLength = DurationText.short(seconds: 1_500, units: .minutesSeconds, locale: en)
        XCTAssertEqual(try english("\(focusLength)、集中する"), "Focus for 25 min")
        XCTAssertEqual(try english("テーマを選んではじめる"), "Choose a Theme to Start")
        let grams = MassText.grams(625.formatted(.number.locale(en)), bundle: try LocalizationTestSupport.englishBundle(), locale: en)
        XCTAssertEqual(try english("\("Math") ・ 完走で+\(grams)"), "Math · +625 g when you finish")
        XCTAssertEqual(
            try english("\("Math")を\(DurationText.spoken(minutes: 25, locale: en))集中する、完走で\(MassText.spoken(grams: 625, locale: en))"),
            "Focus on Math for 25 minutes, adding 625 grams when you finish"
        )
        XCTAssertEqual(try english("\(focusLength)の集中で、ここにひと粒落ちる。"), "Focus for 25 min and a gem drops in here.")
        XCTAssertEqual(try english("積み上げた集中"), "Focus built up")
        XCTAssertEqual(try english("テーマ、\("Math")"), "Theme, Math")
        let notChosen = try english("未選択")
        XCTAssertEqual(try english("テーマ、\(notChosen)"), "Theme, Not chosen")
        XCTAssertEqual(try english("メニュー"), "Menu")
        XCTAssertEqual(try english("時間を手動で積む"), "Add Time Manually")
        XCTAssertEqual(try english("成果を積む"), "Add an Achievement")
        XCTAssertEqual(try english("記録を見る"), "View Log")
        XCTAssertEqual(try english("積み上がりを見る"), "See Progress")
        XCTAssertEqual(try english("積み上がり計画"), "Plan Ahead")
        XCTAssertEqual(try english("\("12 kg")以上"), "12 kg or more")
        XCTAssertEqual(try english("\("12 gems") ・ \("3 milestone stones")"), "12 gems · 3 milestone stones")
        XCTAssertEqual(try english("\("A gem landed")。"), "A gem landed.")
    }

    func testHomeCountsHaveEnglishPluralForms() throws {
        XCTAssertEqual(try english("記念石 \(1)"), "1 milestone stone")
        XCTAssertEqual(try english("記念石 \(3)"), "3 milestone stones")
        XCTAssertEqual(try english("記念石 \(12)+"), "12+ milestone stones")
        XCTAssertEqual(try english("\(1)+粒"), "1+ gems")
        XCTAssertEqual(try english("この端末で確認済み \(1)粒"), "1 gem confirmed on this device")
        XCTAssertEqual(try english("この端末で確認済み \(1_234)粒"), "1,234 gems confirmed on this device")
        XCTAssertEqual(try english("集中\(1)粒"), "1 focus gem")
        XCTAssertEqual(try english("集中\(40)粒"), "40 focus gems")
        XCTAssertEqual(try english("記念石\(1)個"), "1 milestone stone")
        XCTAssertEqual(try english("\(1)粒が、ひとつの結晶になった"), "1 gem became one crystal")
        XCTAssertEqual(try english("\(10)粒が、ひとつの結晶になった"), "10 gems became one crystal")
        XCTAssertEqual(try english("\(100)粒が、ひとつの結晶になった"), "100 gems became one crystal")
        XCTAssertEqual(try english("瓶\(1)杯ぶん満ちました"), "Filled 1 jar")
        XCTAssertEqual(try english("瓶\(2)杯ぶん満ちました"), "Filled 2 jars")
        XCTAssertEqual(try english("小さな粒が\(2)段階で結晶になり、瓶に余白ができた"), "Small gems became crystals in 2 steps, making room in your jar")
        XCTAssertEqual(try english("あと\(12)%で、下の粒がひとつの結晶に"), "12% to go until the gems below become a crystal")
    }

    /// A count beside other arguments takes its plural from its own phrase
    /// (CountText, or a sentence of its own), never from a shared format.
    func testCountsBesideOtherArgumentsStillPlural() throws {
        let bundle = try LocalizationTestSupport.englishBundle()
        let oneGem = CountText.gems(1, bundle: bundle, locale: en)
        let twelveGems = CountText.gems(12, bundle: bundle, locale: en)
        XCTAssertEqual(try english("\("English")\(oneGem)"), "English 1 gem")
        XCTAssertEqual(try english("\("English")\(twelveGems)"), "English 12 gems")
        XCTAssertEqual(
            try english("\(CountText.gems(100, bundle: bundle, locale: en))の結晶、\("details")"),
            "A crystal of 100 gems, details"
        )
        XCTAssertEqual(try english("今週の実測は\("1.25 kg")。"), "This week: 1.25 kg timed.")
        XCTAssertEqual(
            try english("今週のタイマー完走は\(1)回です。回数は時間の価値とは別です。"),
            "You completed 1 timer this week. The count is separate from the value of your time."
        )
        XCTAssertEqual(
            try english("今週のタイマー完走は\(5)回です。回数は時間の価値とは別です。"),
            "You completed 5 timers this week. The count is separate from the value of your time."
        )
        XCTAssertEqual(try english("今週の実測 \("1.25 kg")・自己申告 \("300 g")"), "This week: 1.25 kg timed · 300 g self-reported")
        // Japanese joins the two sentences with nothing between them, as before.
        XCTAssertEqual(
            SentenceText.join(["今週の実測は1.25kg。", "今週のタイマー完走は5回です。回数は時間の価値とは別です。"]),
            "今週の実測は1.25kg。今週のタイマー完走は5回です。回数は時間の価値とは別です。"
        )
    }

    func testCompletionCardAndFusionSheetInEnglish() throws {
        XCTAssertEqual(try english("一粒、着地。"), "A gem landed.")
        XCTAssertEqual(try english("集中を記録しました。"), "Focus recorded.")
        XCTAssertEqual(try english("\(5)分休憩"), "5-Min Break")
        XCTAssertEqual(try english("\(15)分休憩を利用できます"), "You can take a 15-minute break")
        XCTAssertEqual(try english("\("Math") +\("250 g")（\("1.0 standard units")）"), "Math +250 g (1.0 standard units)")
        XCTAssertEqual(try english("\("Math") +\("1,125 g") 積んだ"), "Added 1,125 g to Math")
        XCTAssertEqual(try english("ここで休む"), "Rest Here")
        XCTAssertEqual(try english("この結晶をカードにする"), "Make a Card of This Crystal")
        XCTAssertEqual(try english("時間の核の進み"), "Time Core Progress")
        XCTAssertEqual(
            try english("時間の核は、粒の数ではなく積み上げた時間で進みます。次へ急ぐ必要はありません。"),
            "The time core grows with the time you have built up, not the number of gems. There is no need to hurry."
        )
    }

    // MARK: Sheets

    func testManualEntryInEnglish() throws {
        XCTAssertEqual(try english("手動で積む"), "Add Manually")
        XCTAssertEqual(try english("この端末で本日あと\(1)回"), "1 more entry today on this device")
        XCTAssertEqual(try english("この端末で本日あと\(3)回"), "3 more entries today on this device")
        XCTAssertEqual(try english("確認して積む"), "Confirm and Add")
        XCTAssertEqual(
            try english("この端末で1日3回まで・朝\(ManualEntrySheet.dayBoundaryTimeLabel(locale: en))に回数が切り替わります")
                .replacingOccurrences(of: "\u{202F}", with: " "),
            "Up to 3 a day on this device · The count resets at 4:00 AM"
        )
        XCTAssertEqual(
            try english("\("Math")に\(DurationText.spoken(minutes: 30, locale: en))、\(MassText.spoken(grams: 750, locale: en))を積みます"),
            "Adds 30 minutes (750 grams) to Math"
        )
        XCTAssertEqual(try english("自己申告はこの端末で1日3回までです。"), "You can add up to 3 self-reported entries a day on this device.")
    }

    func testAchievementSheetAndNoteCounterInEnglish() throws {
        XCTAssertEqual(try english("記念石にする"), "Make a Milestone Stone")
        XCTAssertEqual(try english("この成果を積む"), "Add This Achievement")
        XCTAssertEqual(try english("あと\(1)文字"), "1 character left")
        XCTAssertEqual(try english("あと\(30)文字"), "30 characters left")
        XCTAssertEqual(try english("\(1)文字超過"), "1 character over")
        XCTAssertEqual(try english("\(2)文字超過"), "2 characters over")
        XCTAssertEqual(try english("あと\(1)文字入力できます。"), "You can enter 1 more character.")
        XCTAssertEqual(try english("\(40)文字以内で入力してください（\(2)文字超過）。"), "Please keep it to 40 characters or fewer (2 over).")
        XCTAssertEqual(try english("\("Math")の\("Perfect score")を記念石にした"), "Added a milestone stone for Math: Perfect score")
    }

    func testCustomLengthInEnglish() throws {
        XCTAssertEqual(try english("集中時間を選ぶ"), "Choose a Focus Length")
        XCTAssertEqual(try english("\(25)分 \(0)秒"), "25 min 0 sec")
        XCTAssertEqual(try english("\(90)分"), "90 min")
        XCTAssertEqual(try english("分"), "Minutes")
        XCTAssertEqual(try english("この時間にする"), "Use This Length")
        XCTAssertEqual(try english("360分にする場合は、秒を0にしてください。"), "For 360 minutes, set the seconds to 0.")
    }

    // MARK: Widgets and Live Activity

    func testWidgetsAndLiveActivityInEnglish() throws {
        XCTAssertEqual(try widgetEnglish("ポモジェム"), "PomoGem")
        XCTAssertEqual(try widgetEnglish("集中を始める"), "Start Focus")
        XCTAssertEqual(try widgetEnglish("今日のひと粒を積もう"), "Add a gem today")
        XCTAssertEqual(try widgetEnglish("\(DurationText.spoken(seconds: 1_500, units: .minutesSeconds, locale: en))集中する"), "Focus for 25 minutes")
        // The glossary's timer states, shared with the in-app timer.
        XCTAssertEqual(try widgetEnglish("集中を続けています"), "Focusing")
        XCTAssertEqual(try widgetEnglish("一時停止中"), "Paused")
        XCTAssertEqual(try widgetEnglish("休憩中"), "On Break")
        XCTAssertEqual(try widgetEnglish("集中完了"), "Focus Complete")
        // Dynamic Island compact and minimal regions stay short.
        XCTAssertEqual(try widgetEnglish("終了"), "Done")
        XCTAssertEqual(try widgetEnglish("完了"), "Done")
        XCTAssertEqual(try widgetEnglish("残り時間、\("24:59")"), "Time remaining, 24:59")
        XCTAssertEqual(try widgetEnglish("タップして集中へ戻る"), "Tap to return to your focus")
    }

    // MARK: Catalogs

    /// Every Home and Widgets key reads in English from the compiled bundles,
    /// with no Japanese left, and Japanese devices still read the Japanese.
    func testEveryHomeAndWidgetKeyHasEnglish() throws {
        let tables: [(table: String, catalog: String, bundle: Bundle)] = [
            ("Home", "PomoGem/Localization/Home.xcstrings", try LocalizationTestSupport.englishBundle()),
            ("Widgets", "PomoGemWidgets/Localization/Widgets.xcstrings", try widgetBundle())
        ]
        for (table, path, bundle) in tables {
            let catalog = try LocalizationCatalogFile(table: table, relativePath: path)
            XCTAssertFalse(catalog.strings.isEmpty, table)
            for key in catalog.strings.keys {
                let value = bundle.localizedString(forKey: key, value: "<missing>", table: table)
                XCTAssertNotEqual(value, "<missing>", "\(table): \(key)")
                XCTAssertFalse(LocalizationTestSupport.containsJapanese(value), "\(table): \(key) -> \(value)")
            }
        }
    }
}
