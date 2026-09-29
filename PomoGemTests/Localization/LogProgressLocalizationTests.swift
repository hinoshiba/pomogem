import Foundation
import XCTest
@testable import PomoGem

/// English expectations for localization package l10n-03-log-progress (tables: Log, Progress and Planning).
///
/// Only that package edits this file (Docs/Localization.md). Resolve English
/// explicitly with `LocalizationTestSupport.englishBundle()` and
/// `LocalizationTestSupport.english`, which skip until English is activated;
/// never change the process language, because the rest of the suite asserts
/// Japanese.
final class LogProgressLocalizationTests: XCTestCase {
    private let en = LocalizationTestSupport.english
    private let ja = LocalizationTestSupport.japanese

    /// The English value of a key, formatted the way `String(localized:)`
    /// formats it (plural variations included).
    private func english(_ key: String, table: String, _ arguments: CVarArg...) throws -> String {
        let bundle = try LocalizationTestSupport.englishBundle()
        let format = bundle.localizedString(forKey: key, value: "<missing \(key)>", table: table)
        return arguments.isEmpty ? format : String(format: format, locale: en, arguments: arguments)
    }

    // MARK: Every key has English

    func testEveryKeyOfThePackageTablesHasEnglishWithoutJapanese() throws {
        let tableMap = try LocalizationTestSupport.tableMap()
        guard tableMap.shippingLanguages.contains("en") else {
            throw XCTSkip("English is not activated yet")
        }
        for table in ["Log", "Planning", "Progress"] {
            let path = try XCTUnwrap(tableMap.catalogs[table], "\(table) has no catalog")
            let catalog = try LocalizationCatalogFile(table: table, relativePath: path)
            XCTAssertFalse(catalog.strings.isEmpty, table)
            for (key, entry) in catalog.strings {
                if (entry["extractionState"] as? String) == "stale" { continue }
                let english = LocalizationCatalogFile.localizations(of: entry)["en"]
                let substitutions = (english?["substitutions"] as? [String: [String: Any]]) ?? [:]
                let units = (english.map { LocalizationCatalogFile.units(of: $0) } ?? [])
                    + substitutions.values.flatMap { LocalizationCatalogFile.units(of: $0) }
                XCTAssertFalse(units.isEmpty, "\(table): \(key) has no English")
                for unit in units {
                    XCTAssertEqual(unit.state, "translated", "\(table): \(key) \(unit.label)")
                    XCTAssertFalse(
                        LocalizationTestSupport.containsJapanese(unit.value),
                        "\(table): \(key) \(unit.label) is not English: \(unit.value)"
                    )
                    for word in ["bottle", "pebble", "subject", "streak"] {
                        XCTAssertFalse(
                            unit.value.lowercased().contains(word),
                            "\(table): \(key) says “\(word)”: \(unit.value)"
                        )
                    }
                }
            }
        }
    }

    // MARK: Log

    func testLogScreenInEnglish() throws {
        XCTAssertEqual(try english("記録", table: "Log"), "Log")
        XCTAssertEqual(try english("今週", table: "Log"), "This Week")
        XCTAssertEqual(try english("今月", table: "Log"), "This Month")
        XCTAssertEqual(try english("月の振り返り", table: "Log"), "Month in Review")
        XCTAssertEqual(try english("質量の推移", table: "Log"), "Mass Over Time")
        XCTAssertEqual(try english("記念石アーカイブ", table: "Log"), "Milestone Stone Archive")
        XCTAssertEqual(try english("結晶アーカイブ", table: "Log"), "Crystal Archive")
        XCTAssertEqual(try english("SUBJECTS", table: "Log"), "Themes", "the eyebrow says themes, never subjects")
        XCTAssertEqual(try english("%@〜%@", table: "Log", "Sun, Sep 20", "Sat, Sep 26"), "Sun, Sep 20 – Sat, Sep 26")
        XCTAssertEqual(
            try english("この期間は記録が多いため、最新%lld件の表示分です。", table: "Log", 2_048),
            "This period has a lot of records, so only the newest 2,048 are shown."
        )
        XCTAssertEqual(
            try english("スクリーンタイムの%@は、完走した回数に含みません", table: "Log", "30 min"),
            "30 min of Screen Time isn't counted in completed sessions"
        )
        XCTAssertEqual(try english("このうち自己申告 %@", table: "Log", "300 g"), "Including 300 g self-reported")
    }

    func testLogCountsUsePluralForms() throws {
        XCTAssertEqual(try english("元 %lld粒", table: "Log", 1), "From 1 gem")
        XCTAssertEqual(try english("元 %lld粒", table: "Log", 1_000), "From 1,000 gems")
        XCTAssertEqual(try english("ほか %lldテーマ", table: "Log", 1), "1 more theme")
        XCTAssertEqual(try english("ほか%lldテーマ", table: "Log", 4), "4 more themes")
        // Counts and masses inside VoiceOver sentences come from the plural
        // helpers (CountText, MassText.spoken), so each sentence has at most
        // one plural of its own.
        let bundle = try LocalizationTestSupport.englishBundle()
        XCTAssertEqual(
            try english(
                "この日の記録、%@、%@、%@",
                table: "Log",
                DurationText.spoken(minutes: 75, locale: en),
                CountText.gems(1, bundle: bundle, locale: en),
                MassText.spoken(grams: 1, locale: en)
            ),
            "Records for this day: 1 hour, 15 minutes, 1 gem, 1 gram"
        )
        XCTAssertEqual(
            try english("%@、%@、%@、プラス%@、%@", table: "Log", "Math", "regular gem", "Timed", MassText.spoken(grams: 250, locale: en), "2:30 PM"),
            "Math, regular gem, Timed, plus 250 grams, 2:30 PM"
        )
        XCTAssertEqual(
            try english("%@の結晶、%@、%@、実測%lld粒、手動%lld粒", table: "Log", CountText.gems(10, bundle: bundle, locale: en), "250 g", "Sep 1, 2026", 9, 1),
            "Crystal of 10 gems, 250 g, Sep 1, 2026. Gems: 9 timed, 1 added manually"
        )
        XCTAssertEqual(
            try english("瓶では新しい12個が動き、これまでの%lld個を振り返れます。行をタップすると編集・削除できます。", table: "Log", 1),
            "Up to 12 of your newest milestone stones move in your jar. Here you can look back on your 1 milestone stone. Tap a row to edit or delete it."
        )
        XCTAssertEqual(
            try english("瓶では新しい12個が動き、これまでの%lld個を振り返れます。行をタップすると編集・削除できます。", table: "Log", 40),
            "Up to 12 of your newest milestone stones move in your jar. Here you can look back on all 40 of them. Tap a row to edit or delete it."
        )
        XCTAssertEqual(
            try english("%lld日分、期間合計%@。", table: "Log", 7, "1,250 grams"),
            "7 days, total for the period: 1,250 grams."
        )
        XCTAssertEqual(
            try english("%lld日分、期間合計%@。", table: "Log", 1, "0 grams"),
            "1 day, total for the period: 0 grams."
        )
        XCTAssertEqual(
            try english("%@の瓶。%@をひとつのまとまりで俯瞰する演出", table: "Log", "September 2026", CountText.gems(1, bundle: bundle, locale: en)),
            "Your jar for September 2026. An animation that gathers its 1 gem into one."
        )
    }

    /// The month-row and chart pieces come from the shared helpers: the same
    /// Japanese as before, English units and plurals.
    func testLogHelpersKeepJapaneseAndSpeakEnglish() throws {
        XCTAssertEqual(ListText.compact(["1時間15分", CountText.gems(3, locale: ja)]), "1時間15分・3粒")
        let bundle = try LocalizationTestSupport.englishBundle()
        XCTAssertEqual(
            ListText.compact(
                [DurationText.short(minutes: 75, locale: en), CountText.gems(1, bundle: bundle, locale: en)],
                bundle: bundle
            ),
            "1 hr 15 min · 1 gem"
        )
        XCTAssertEqual(DayHistorySheet.spokenFocusTime(grams: 750), "1時間15分", "ja reads the tile's text")
        XCTAssertEqual(DurationText.spoken(minutes: 75, locale: en), "1 hour, 15 minutes")
        XCTAssertEqual(HistoryMassText.text(250), "250g")
        XCTAssertEqual(HistoryMassText.text(2_500), "2.5kg")
        XCTAssertEqual(HistoryMassText.text(1_300_000), "1.3t")
        XCTAssertEqual(try english("%@t", table: "Log", "1.2"), "1.2\u{00A0}t", "a no-break space keeps the unit with its number")
    }

    func testMonthTitlesComeFromTheDateNotTheStoredLabel() throws {
        var components = DateComponents()
        components.calendar = PomoGemCalendar.gregorian
        components.timeZone = .current
        components.year = 2026
        components.month = 9
        components.day = 24
        let date = try XCTUnwrap(components.date)
        let month = WrappedMonth(containing: date)
        XCTAssertEqual(month.title, "2026年9月")
        XCTAssertEqual(month.title, StrataMath.monthLabel(for: date), "Japanese is unchanged")
        XCTAssertEqual(DateText.yearMonth(month.start, locale: en), "September 2026")
        XCTAssertEqual(try english("%@の瓶", table: "Log", "September 2026"), "Your Jar for September 2026")
    }

    func testMilestoneEditorInEnglish() throws {
        XCTAssertEqual(try english("成果を編集", table: "Log"), "Edit Achievement")
        XCTAssertEqual(try english("変更を保存", table: "Log"), "Save Changes")
        XCTAssertEqual(try english("この記念石を削除しますか？", table: "Log"), "Delete This Milestone Stone?")
        XCTAssertEqual(
            try english("記録・瓶・共有から非表示になります。質量は変わりません。削除直後は記録画面で元に戻せます。", table: "Log"),
            "It will be hidden from your Log, jar and shares. Your mass won't change. Right after deleting, you can undo it on the Log screen."
        )
        XCTAssertEqual(
            try english("「%@」は設定で削除したテーマです。ほかのテーマを選ばなければ、このまま残ります。", table: "Log", "Math"),
            "“Math” is a theme you deleted in Settings. It stays as it is unless you choose another theme."
        )
    }

    // MARK: Progress

    func testCrystalCountsCompactByLanguage() {
        XCTAssertEqual(AggregatePresentation.countLabel(10, locale: ja), "×10")
        XCTAssertEqual(AggregatePresentation.countLabel(1_000, locale: ja), "×1千")
        XCTAssertEqual(AggregatePresentation.countLabel(350_640, locale: ja), "×35.1万")
        XCTAssertEqual(AggregatePresentation.countLabel(100_000_000, locale: ja), "×1億")
        XCTAssertEqual(AggregatePresentation.countLabel(10, locale: en), "×10")
        XCTAssertEqual(AggregatePresentation.countLabel(999, locale: en), "×999")
        XCTAssertEqual(AggregatePresentation.countLabel(1_000, locale: en), "×1K")
        XCTAssertEqual(AggregatePresentation.countLabel(12_345, locale: en), "×12K")
        XCTAssertEqual(AggregatePresentation.countLabel(100_000_000, locale: en), "×100M")
    }

    func testCompletionCardProgressInEnglish() throws {
        XCTAssertEqual(try english("%@へ %lld/%lld", table: "Progress", "×10", 1, 10), "1/10 toward ×10")
        XCTAssertEqual(try english("%@完成 %lld/%lld", table: "Progress", "×10", 10, 10), "×10 complete · 10/10")
        XCTAssertEqual(try english("長期：%@へ %lld/%lld", table: "Progress", "×100", 1, 10), "Long-term: 1/10 toward ×100")
        XCTAssertEqual(try english("次の結晶まで、あと%lld粒", table: "Progress", 1), "1 more gem to the next crystal")
        XCTAssertEqual(try english("次の結晶まで、あと%lld粒", table: "Progress", 9), "9 more gems to the next crystal")
        let bundle = try LocalizationTestSupport.englishBundle()
        XCTAssertEqual(
            try english("あと%@で%lld段融合", table: "Progress", CountText.gems(1, bundle: bundle, locale: en), 2),
            "1 gem to go until 2 levels fuse"
        )
        XCTAssertEqual(try english("瓶%lld杯", table: "Progress", 1), "1 full jar")
        XCTAssertEqual(try english("瓶%lld杯", table: "Progress", 3), "3 full jars")
        XCTAssertEqual(try english("時間の核", table: "Progress"), "Time Core")
        XCTAssertEqual(try english("結晶の芽", table: "Progress"), "Crystal Seed")
        XCTAssertEqual(
            try english("時間の核・%lld段目へ %@ / %@", table: "Progress", 2, "1 hr", "41 hr 40 min"),
            "Time core stage 2: 1 hr / 41 hr 40 min"
        )
        XCTAssertEqual(try english("最初の時間の核", table: "Progress"), "the first time core")
        XCTAssertEqual(try english("%@標準単位", table: "Progress", "1.0"), "1.0 standard units")
    }

    /// The composed labels keep their Japanese exactly (the presentation tests
    /// pin more of it); only the source of each sentence changed.
    func testComposedProgressLabelsStayJapanese() {
        let bridge = FusionRewardBridgePresentation.state(totalPebbleCount: 11)
        let display = FusionRewardBridgePresentation.display(state: bridge, projectionIsLowerBound: false)
        XCTAssertEqual(display.accessibilityLabel, "結晶の進み、×10へ 1/10、次の結晶まで、あと9粒、長期：×100へ 1/10")
        XCTAssertEqual(FusionHierarchyText.cascade(remaining: 1, levels: 2), "あと1粒で2段融合")
        XCTAssertEqual(EffortProgressPresentation.targetTitle(level: 1), "最初の時間の核")
        XCTAssertEqual(EffortProgressPresentation.targetTitle(level: 3), "時間の核・3段目")
        XCTAssertEqual(EffortProgressPresentation.formattedDuration(grams: 1_005), "1,005g相当")
        XCTAssertEqual(EffortProgressPresentation.formattedMass(grams: 2_500), "2.5kg")
    }

    // MARK: Planning

    func testPlanInEnglish() throws {
        XCTAssertEqual(try english("積み上がり計画", table: "Planning"), "Plan Ahead")
        XCTAssertEqual(try english("BOTTLE CYCLE", table: "Planning"), "Jar Cycle", "English says jar, never bottle")
        XCTAssertEqual(try english("%lld年", table: "Planning", 1), "1 year")
        XCTAssertEqual(try english("%lld年", table: "Planning", 10), "10 years")
        XCTAssertEqual(try english("%lldか月後", table: "Planning", 1), "In 1 month")
        XCTAssertEqual(
            try english("%@%@後", table: "Planning", try english("%lld年", table: "Planning", 1), try english("%lldか月", table: "Planning", 6)),
            "In 1 year, 6 months"
        )
        XCTAssertEqual(
            try english("%@%@後", table: "Planning", try english("%lld年", table: "Planning", 2), try english("%lldか月", table: "Planning", 1)),
            "In 2 years, 1 month"
        )
        XCTAssertEqual(try english("%lld段階到達 · 次 %@", table: "Planning", 1, "25 kg"), "1 stage reached · next 25 kg")
        XCTAssertEqual(try english("%lld回", table: "Planning", 1_300), "1,300 sessions")
        XCTAssertEqual(try english("%@t", table: "Planning", "3.68"), "3.68\u{00A0}t")
        XCTAssertEqual(
            try english("ここで動かす瓶や数値は、実際の学習記録・保存領域・ウィジェットには保存されません。画面を閉じると入力も消えます。", table: "Planning"),
            "The jar and numbers you move here are never saved to your real records, your storage or your widgets. What you enter is cleared when you close this screen."
        )
    }

    func testPlanTimesStayJapanese() {
        XCTAssertEqual(AccumulationPlanView.laterTitle(years: 0, months: 3), "3か月後")
        XCTAssertEqual(AccumulationPlanView.laterTitle(years: 2, months: 0), "2年後")
        XCTAssertEqual(AccumulationPlanView.laterTitle(years: 1, months: 6), "1年6か月後")
        XCTAssertEqual(AccumulationPlanView.yearCount(10), "10年")
        XCTAssertEqual(AccumulationPlanView.percentValue(0.42), "42パーセント")
        XCTAssertEqual(DurationText.short(seconds: 90 * 60, units: .minutesSeconds, locale: ja), "90分", "a timer length never says 1時間30分")
        XCTAssertEqual(DurationText.short(seconds: 90 * 60, units: .minutesSeconds, locale: en), "90 min")
    }
}
