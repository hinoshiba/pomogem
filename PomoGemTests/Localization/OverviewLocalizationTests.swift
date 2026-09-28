import Foundation
import XCTest
@testable import PomoGem

/// English expectations for localization package l10n-04-overview (table: Overview).
///
/// Only that package edits this file (Docs/Localization.md). Resolve English
/// explicitly with `LocalizationTestSupport.englishBundle()` and
/// `LocalizationTestSupport.english`, which skip until English is activated;
/// never change the process language, because the rest of the suite asserts
/// Japanese.
final class OverviewLocalizationTests: XCTestCase {
    private let en = LocalizationTestSupport.english
    private let ja = LocalizationTestSupport.japanese

    /// The English value of an Overview key, formatted the way the app formats
    /// it (plural forms follow the English locale).
    private func english(_ key: String, _ arguments: CVarArg...) throws -> String {
        let bundle = try LocalizationTestSupport.englishBundle()
        let format = bundle.localizedString(forKey: key, value: "<missing \(key)>", table: "Overview")
        return arguments.isEmpty ? format : String(format: format, locale: en, arguments: arguments)
    }

    private func englishCommon(_ key: String, _ arguments: CVarArg...) throws -> String {
        let bundle = try LocalizationTestSupport.englishBundle()
        let format = bundle.localizedString(forKey: key, value: "<missing \(key)>", table: "Common")
        return arguments.isEmpty ? format : String(format: format, locale: en, arguments: arguments)
    }

    // MARK: Japanese stays as it was

    /// Strings this package rebuilt from separate pieces: whole sentences
    /// joined per language, a year label from DateText, the legend from the
    /// duration and mass helpers. The Japanese is pinned byte for byte.
    func testRebuiltJapaneseIsUnchanged() throws {
        let legacy = AccumulationClusterSummary(
            id: UUID(),
            level: 1,
            pebbleCount: 10,
            grams: 2_500,
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 0),
            colorMix: [StratumColorFraction(hex: "#E85D4A", fraction: 1)],
            subjectMix: [],
            childCount: 0,
            sessionIDs: [UUID()],
            measuredPebbleCount: 0,
            manualPebbleCount: 0,
            goldPebbleCount: 0,
            prismPebbleCount: 0,
            storage: .legacyStratum(hasSessionReferences: true)
        )
        XCTAssertEqual(
            legacy.preservationMessage,
            "色・粒数・質量と、まとめた日は残っています。元記録への参照は残っています。旧形式のため、テーマ・入力方法・レアの内訳はこの粒自体には保存されていません。記念石は別の石として残します。"
        )

        XCTAssertEqual(
            FusionLegendStep.allCases.map(\.title),
            ["10分 = 100g", "25分 = 250g", "60分 = 600g", "時間の核"]
        )
        XCTAssertEqual(
            FusionLegendStep.allCases.map(\.accessibilityIdentifier),
            [
                "overview.fusion-step.10分 = 100g",
                "overview.fusion-step.25分 = 250g",
                "overview.fusion-step.60分 = 600g",
                "overview.fusion-step.時間の核"
            ],
            "AccessibilityAdversarialUITests finds the legend by these, in every language"
        )

        XCTAssertEqual(EffortConstellationPresentation.formattedMass(87_660_000), "87.66t")
        XCTAssertEqual(EffortConstellationPresentation.timeCoreTitle, "時間の核")
        XCTAssertEqual(AccumulationClusterSummary.singleGemLabel, "一粒")
    }

    /// The year chip names the bucket's Gregorian year, whatever time zone
    /// the bucket was built in: its label comes from the middle of the year.
    func testYearTitlesNameTheBucketInAnyTimeZone() throws {
        for identifier in ["Asia/Tokyo", "UTC", "Pacific/Honolulu", "Pacific/Kiritimati"] {
            let calendar = PomoGemCalendar.gregorian(timeZone: try XCTUnwrap(TimeZone(identifier: identifier)))
            for year in [1985, 2026, 2099] {
                let start = try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: 1, day: 1)))
                let end = try XCTUnwrap(calendar.date(byAdding: .year, value: 1, to: start))
                let bucket = AccumulationTimelineYear(year: year, interval: DateInterval(start: start, end: end))
                XCTAssertEqual(bucket.title, "\(year)年", identifier)
                let middle = bucket.interval.start.addingTimeInterval(bucket.interval.duration / 2)
                XCTAssertEqual(DateText.year(middle, locale: en), String(year), identifier)
            }
        }
    }

    // MARK: English

    func testProgressScreenCopyInEnglish() throws {
        XCTAssertEqual(try english("積み上がり"), "Progress")
        XCTAssertEqual(try english("積み上がりを閉じる"), "Close Progress")
        XCTAssertEqual(try english("一粒は消えず、\n時間の景色に変わる。"), "No gem disappears.\nIt becomes a landscape of time.")
        XCTAssertEqual(try english("時間をズームする"), "Zoom Through Time")
        XCTAssertEqual(
            try ["いま", "結晶", "年月"].map { try english($0) },
            ["Now", "Crystals", "Years & Months"]
        )
        XCTAssertEqual(try english("時間の核"), "Time Core")
        XCTAssertEqual(try english("生涯の瓶"), "Lifetime Jar")
        XCTAssertEqual(try english("結晶の段"), "Crystal Tiers")
        XCTAssertEqual(try english("記念石"), "Milestone Stones")
    }

    func testWeeklyCardInEnglish() throws {
        XCTAssertEqual(try english("今週は、まだ透明。"), "This week is still clear.")
        XCTAssertEqual(
            try english("次の完走から時間と質量を加えます。休んでも、これまでの瓶は減りません。"),
            "Your next completed session adds time and mass. Taking a break never shrinks your jar."
        )
        let key = "今週の積み上げ、%@、実測%@、完走した回数%lld回。回数は時間の価値とは別に数えています"
        XCTAssertEqual(
            try english(key, "25 min", "250 g", 1),
            "This week: 25 min of focus, 250 g timed, 1 completed session. Sessions are counted separately from the value of your time"
        )
        XCTAssertEqual(
            try english(key, "1 hr 15 min", "750 g", 3),
            "This week: 1 hr 15 min of focus, 750 g timed, 3 completed sessions. Sessions are counted separately from the value of your time"
        )
        XCTAssertEqual(try english("このほか自己申告 %@", "250 g"), "Plus 250 g self-reported")
    }

    func testCountsTakeEnglishPluralForms() throws {
        XCTAssertEqual(try english("月ごと・全%lld件", 1), "By month · 1 record")
        XCTAssertEqual(try english("月ごと・全%lld件", 9), "By month · 9 records")
        XCTAssertEqual(try english("全%lld件のうち直近%lld件から", 721, 720), "From the latest 720 of 721 records")
        XCTAssertEqual(try english("%lld件以上のうち直近%lld件から", 720, 720), "From the latest 720 of 720+ records")
        XCTAssertEqual(try english("記念石%lld個", 1), "1 milestone stone")
        XCTAssertEqual(try english("記念石%lld個", 1_200), "1,200 milestone stones")
        XCTAssertEqual(
            try english("記念石%lld個以上、最新%lld個を表示", 1_200, 120),
            "At least 1,200 milestone stones, latest 120 shown"
        )
        XCTAssertEqual(
            try english("瓶の中は、粒%lld個・表示中の結晶%lld個・記念石%lld個の代表表示です。", 28, 16, 8),
            "The jar shows a sample of gems (28), crystals from this page (16) and milestone stones (8)."
        )
        XCTAssertEqual(try english("%lld段", 1), "1 tier")
        XCTAssertEqual(try english("%lld段", 4), "4 tiers")
        XCTAssertEqual(try english("%lld粒分の積み重ね", 1), "1 Gem of Focus")
        XCTAssertEqual(try english("%lld粒分の積み重ね", 1_234), "1,234 Gems of Focus")
        XCTAssertEqual(try english("いま瓶で動く粒、%lld粒", 1), "1 gem moving in your jar now")
        XCTAssertEqual(try englishCommon("%lld粒", 350_640), "350,640 gems", "gem counters come from Common")
    }

    func testCrystalDetailInEnglish() throws {
        XCTAssertEqual(try english("結晶の内訳"), "Crystal Details")
        XCTAssertEqual(try english("%@の結晶", "×10"), "×10 crystal")
        XCTAssertEqual(try english("結晶になっても情報は削除されません"), "Nothing is deleted when gems become a crystal")
        XCTAssertEqual(
            try ["朱色", "瑠璃", "紅藤", "緑青", "菫", "金色"].map { try english($0) },
            ["Vermilion", "Lapis", "Orchid", "Verdigris", "Violet", "Gold"]
        )
        XCTAssertEqual(try english("色%lld", 3), "Color 3")
        XCTAssertEqual(try english("1%未満"), "Under 1%")
        XCTAssertEqual(try english("%lldパーセント", 40), "40 percent")
        XCTAssertEqual(try english("%lld粒・%@", 1, "10%"), "1 gem · 10%")
        XCTAssertEqual(try english("%lld粒・%@", 12, "40%"), "12 gems · 40%")
        XCTAssertEqual(try english("まとめた日：%@ 〜 %@", "Sep 1, 2026", "Sep 24, 2026"), "Combined Sep 1, 2026 – Sep 24, 2026")
    }

    /// The legend's "=" is glued to the time, so a narrow chip wraps as
    /// "10 min =" over "100 g" and never splits a unit.
    func testLegendStepKeepsUnitsWholeInEnglish() throws {
        let bundle = try LocalizationTestSupport.englishBundle()
        let time = DurationText.short(seconds: 600, units: .minutesSeconds, locale: en)
        let mass = MassText.grams("100", bundle: bundle, locale: en)
        XCTAssertEqual(time, "10 min")
        XCTAssertEqual(mass, "100 g")
        XCTAssertEqual(try english("%@ = %@", "10\u{00A0}min", "100\u{00A0}g"), "10\u{00A0}min\u{00A0}= 100\u{00A0}g")
    }

    func testTimeCoreVoiceOverInEnglish() throws {
        XCTAssertEqual(try english("%@t", "87.66"), "87.66 t")
        XCTAssertEqual(try english("、"), ", ")
        XCTAssertEqual(try english("集中%@", "2.75 kg"), "2.75 kg of focus")
        XCTAssertEqual(try english("%lld粒以上", 99), "at least 99 gems")
        XCTAssertEqual(
            try english("表示中の結晶%lld個のうち代表%lld個を配置", 18, 8),
            "showing 8 of the crystals on this page (18 in all)"
        )
        XCTAssertEqual(
            try english("集中%@。最初の結晶まで、あと%lld粒です", "25 min", 1),
            "25 min of focus. 1 more gem until the first crystal"
        )
    }

    func testYearsAndMonthsInEnglish() throws {
        XCTAssertEqual(try english("年月をたどる"), "Browse Years & Months")
        XCTAssertEqual(try english("年を選ぶ"), "Choose a year")
        XCTAssertEqual(
            try english("この端末に届いている%@の記録、%lld粒、%@", "2026", 1, "10 grams"),
            "Records from 2026 on this device, 1 gem, 10 grams"
        )
        XCTAssertEqual(
            try english("%@、この端末に届いている%lld粒、%@", "September 2026", 42, "1,050 grams"),
            "September 2026, 42 gems on this device, 1,050 grams"
        )
        XCTAssertEqual(
            try english("全%lld粒・%@。瓶は最新%lld粒の代表表示です。", 120, "3.0 kg", 96),
            "120 gems in all · 3.0 kg. The jar shows only the latest 96 as a sample."
        )
        XCTAssertEqual(try english("この月を振り返る"), "Review This Month")
    }

    /// Every live key of the Overview table has English, and no English value
    /// still carries Japanese characters.
    func testEveryOverviewKeyHasEnglish() throws {
        _ = try LocalizationTestSupport.englishBundle()
        let catalog = try LocalizationCatalogFile(
            table: "Overview",
            relativePath: "PomoGem/Localization/Overview.xcstrings"
        )
        XCTAssertFalse(catalog.strings.isEmpty)
        for (key, entry) in catalog.strings where entry["extractionState"] as? String != "stale" {
            let english = try XCTUnwrap(
                LocalizationCatalogFile.localizations(of: entry)["en"],
                "\(key) has no English"
            )
            var units = LocalizationCatalogFile.units(of: english)
            for (_, substitution) in english["substitutions"] as? [String: [String: Any]] ?? [:] {
                units += LocalizationCatalogFile.units(of: substitution)
            }
            XCTAssertFalse(units.isEmpty, key)
            for unit in units {
                XCTAssertEqual(unit.state, "translated", "\(key) \(unit.label)")
                XCTAssertFalse(LocalizationTestSupport.containsJapanese(unit.value), "\(key) \(unit.label): \(unit.value)")
            }
        }
    }
}
