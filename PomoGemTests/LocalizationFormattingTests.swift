import Foundation
import XCTest
@testable import PomoGem

/// The formatting helpers in PomoGem/Core/Localization reproduce today's
/// hand-built Japanese byte for byte, so screens can adopt them without a
/// visible change, and give English its natural form.
final class LocalizationFormattingTests: XCTestCase {
    private let ja = LocalizationTestSupport.japanese
    private let en = LocalizationTestSupport.english
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    // MARK: Durations

    func testDurationsInJapanese() {
        XCTAssertEqual(DurationText.short(seconds: 30, locale: ja), "30秒")
        XCTAssertEqual(DurationText.short(seconds: 25 * 60, locale: ja), "25分")
        XCTAssertEqual(DurationText.short(seconds: 90, locale: ja), "1分30秒")
        XCTAssertEqual(DurationText.short(seconds: 4_500, locale: ja), "1時間15分")
        XCTAssertEqual(DurationText.short(seconds: 3_601, locale: ja), "1時間1秒")
        XCTAssertEqual(DurationText.short(seconds: 123 * 3_600 + 45 * 60, locale: ja), "123時間45分")
        XCTAssertEqual(DurationText.short(seconds: 1_234 * 3_600, locale: ja), "1,234時間")
        XCTAssertEqual(DurationText.short(seconds: 0, locale: ja), "0秒")
        XCTAssertEqual(DurationText.short(seconds: -5, locale: ja), "0秒")
        XCTAssertEqual(DurationText.short(seconds: 5_400, units: .minutesSeconds, locale: ja), "90分")
        XCTAssertEqual(DurationText.short(seconds: 90, units: .hoursMinutes, locale: ja), "1分", "seconds are dropped, never rounded up")
        XCTAssertEqual(DurationText.short(minutes: 0, locale: ja), "0分")
        XCTAssertEqual(DurationText.short(minutes: 75, locale: ja), "1時間15分")
        XCTAssertTrue(DurationText.short(minutes: Int.max, locale: ja).hasSuffix("時間30分"), "an overflowing total is clamped to Int.max seconds, not trapped")
        XCTAssertEqual(DurationText.spoken(seconds: 4_500, locale: ja), "1時間15分")
        XCTAssertEqual(DurationText.spoken(minutes: 25, locale: ja), "25分")
    }

    func testDurationsFollowTheHostLanguageByDefault() {
        XCTAssertEqual(DurationText.short(seconds: 4_500), "1時間15分")
        XCTAssertEqual(DurationText.short(minutes: 25), "25分")
    }

    /// Once English ships, a Korean iPhone falls back to the Japanese strings
    /// while `Locale.current` turns English (en_KR). Formatting follows the
    /// language the strings resolve in, so those screens stay in one language.
    func testFormattingFollowsTheLanguageOfTheStringsNotTheDevice() {
        let koreanDevice = Locale(identifier: "en_KR")
        let japaneseStrings = PomoGemLocale.locale(localization: "ja", base: koreanDevice)
        XCTAssertEqual(japaneseStrings.language.languageCode, .japanese)
        XCTAssertEqual(japaneseStrings.region, .southKorea)
        XCTAssertEqual(DurationText.short(seconds: 4_500, locale: japaneseStrings), "1時間15分")
        XCTAssertEqual(DateText.yearMonth(Date(timeIntervalSince1970: 1_790_000_000), locale: japaneseStrings, timeZone: tokyo), "2026年9月")
        XCTAssertEqual(DurationText.short(seconds: 4_500, locale: koreanDevice), "1 hr 15 min", "what Locale.current alone would print")

        let englishStrings = PomoGemLocale.locale(localization: "en", base: ja)
        XCTAssertEqual(englishStrings.region, .japan)
        XCTAssertEqual(DurationText.short(seconds: 4_500, locale: englishStrings), "1 hr 15 min")
        XCTAssertEqual(PomoGemLocale.locale(localization: nil, base: koreanDevice), koreanDevice)

        XCTAssertEqual(PomoGemLocale.current.language.languageCode, .japanese)
        XCTAssertEqual(PomoGemLocale.current.region, .japan)
    }

    /// The Live Activity and the timer picker label timer lengths in minutes and
    /// seconds. Every length a timer can have reads the same through DurationText.
    func testTimerLengthsMatchTheLiveActivityAndPickerLabels() {
        for seconds in 1 ... 6 * 3_600 {
            XCTAssertEqual(
                DurationText.short(seconds: seconds, units: .minutesSeconds, locale: ja),
                FocusActivityConstants.durationLabel(seconds: seconds),
                "\(seconds) seconds"
            )
        }
        let minimum = Constants.Timer.customMinimumMinutes * 60
        let maximum = Constants.Timer.customMaximumMinutes * 60
        for seconds in minimum ... maximum {
            let duration = PomodoroDuration.customSeconds(totalSeconds: seconds)
            XCTAssertEqual(DurationText.short(seconds: duration.seconds, units: .minutesSeconds, locale: ja), duration.displayLabel)
        }
        for duration in PomodoroDuration.freePresets {
            XCTAssertEqual(DurationText.short(seconds: duration.seconds, units: .minutesSeconds, locale: ja), duration.displayLabel)
        }
    }

    /// Progress totals are whole minutes shown in hours and minutes.
    func testMinuteTotalsMatchTheProgressLabels() {
        for minutes in Array(0 ... 6_000) + [74_040, 74_041, 600_000] {
            XCTAssertEqual(
                DurationText.short(minutes: minutes, locale: ja),
                EffortProgressPresentation.formattedDuration(grams: minutes * Constants.Mass.gramsPerMinute),
                "\(minutes) minutes"
            )
        }
    }

    func testDurationsInEnglish() {
        XCTAssertEqual(DurationText.short(seconds: 30, locale: en), "30 sec")
        XCTAssertEqual(DurationText.short(seconds: 25 * 60, locale: en), "25 min")
        XCTAssertEqual(DurationText.short(seconds: 90, locale: en), "1 min 30 sec")
        XCTAssertEqual(DurationText.short(seconds: 4_500, locale: en), "1 hr 15 min")
        XCTAssertEqual(DurationText.short(minutes: 1, locale: en), "1 min")
        XCTAssertEqual(DurationText.spoken(seconds: 4_500, locale: en), "1 hour, 15 minutes")
        XCTAssertEqual(DurationText.spoken(minutes: 1, locale: en), "1 minute")
    }

    // MARK: Mass

    func testMassPatternsInJapanese() {
        XCTAssertEqual(MassText.grams("250", locale: ja), "250g")
        XCTAssertEqual(MassText.grams(12_345.formatted(.number.grouping(.automatic).locale(ja)), locale: ja), "12,345g")
        XCTAssertEqual(MassText.kilograms("2.5", locale: ja), "2.5kg")
        for grams in [0, 1, 10, 250, 999] {
            XCTAssertEqual(MassText.grams("\(grams)", locale: ja), "\(grams)g")
        }
    }

    /// VoiceOver masses read like the share card's (grouped) and the jar's
    /// (below 1 kg, where both agree) labels.
    func testSpokenMassMatchesTheExistingLabels() {
        for grams in Array(0 ... 1_200) + [12_345, 1_234_567] {
            XCTAssertEqual(
                MassText.spoken(grams: grams, locale: ja),
                "\(grams.formatted(.number.grouping(.automatic).locale(ja)))グラム"
            )
        }
        for grams in 0 ..< 1_000 {
            XCTAssertEqual(MassText.spoken(grams: grams, locale: ja), "\(grams)グラム")
        }
        XCTAssertEqual(MassText.spoken(kilograms: 2.5, fractionDigits: 1, locale: ja), "2.5キログラム")
        XCTAssertEqual(MassText.spoken(kilograms: 1.234, fractionDigits: 2, locale: ja), String(format: "%.2fキログラム", 1.234))
        XCTAssertEqual(MassText.spoken(grams: 250), "250グラム")
    }

    func testSpokenMassInEnglishIsNeverConverted() {
        XCTAssertEqual(MassText.spoken(grams: 1, locale: en), "1 gram")
        XCTAssertEqual(MassText.spoken(grams: 250, locale: en), "250 grams")
        XCTAssertEqual(MassText.spoken(grams: 1_234, locale: en), "1,234 grams")
        XCTAssertEqual(MassText.spoken(kilograms: 2.5, fractionDigits: 1, locale: en), "2.5 kilograms")
    }

    // MARK: Dates

    func testMonthLabelsMatchTheGregorianBuckets() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        for year in [1999, 2000, 2026, 2099] {
            for month in 1 ... 12 {
                for day in [1, 15, 28] {
                    let date = try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 0, minute: 30)))
                    XCTAssertEqual(
                        DateText.yearMonth(date, locale: ja, timeZone: tokyo),
                        StrataMath.monthLabel(for: date, timeZone: tokyo)
                    )
                }
            }
        }
    }

    func testYearLabelsMatchTheTimelineAndNeverGroupDigits() throws {
        let calendar = PomoGemCalendar.gregorian(timeZone: tokyo)
        for year in [1970, 1999, 2000, 2026, 2100, 9_999] {
            let start = try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: 1, day: 1)))
            let end = try XCTUnwrap(calendar.date(byAdding: .year, value: 1, to: start))
            let bucket = AccumulationTimelineYear(year: year, interval: DateInterval(start: start, end: end))
            XCTAssertEqual(DateText.year(bucket.interval.start, locale: ja, timeZone: tokyo), bucket.title)
            let lastSecond = end.addingTimeInterval(-1)
            XCTAssertEqual(DateText.year(lastSecond, locale: ja, timeZone: tokyo), bucket.title, "any date inside the year")
        }
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 24)))
        XCTAssertEqual(DateText.year(date, locale: en, timeZone: tokyo), "2026")
    }

    /// The label half of critic-04: the helpers label a date in the Gregorian
    /// calendar whatever the iPhone's calendar is. They cannot repair a year
    /// number that is already an era year, which is why the 年月 timeline
    /// buckets years with `PomoGemCalendar.gregorian` (see
    /// AccumulationTimelineRepositoryTests) and a screen that moves to
    /// `DateText.year` passes the bucket's start date.
    func testBucketLabelsIgnoreANonGregorianDeviceCalendar() throws {
        let imperial = Locale(identifier: "ja_JP@calendar=japanese")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 17)))
        let unpinned = date.formatted(
            Date.FormatStyle(locale: imperial, calendar: Calendar(identifier: .japanese), timeZone: tokyo).year().month()
        )
        XCTAssertTrue(unpinned.contains("令和"), "the system style follows the device calendar: \(unpinned)")
        XCTAssertEqual(DateText.yearMonth(date, locale: imperial, timeZone: tokyo), "2026年9月")
        XCTAssertEqual(DateText.year(date, locale: imperial, timeZone: tokyo), "2026年")
        XCTAssertEqual(DateText.longDate(date, locale: imperial, timeZone: tokyo), "2026年9月24日")

        var japaneseCalendar = Calendar(identifier: .japanese)
        japaneseCalendar.timeZone = tokyo
        XCTAssertEqual(
            japaneseCalendar.component(.year, from: date), 8,
            "an era year like this must never be the input of a year label"
        )
    }

    func testDatesInJapaneseAndEnglish() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 17, minute: 37)))
        XCTAssertEqual(DateText.yearMonth(date, locale: ja, timeZone: tokyo), "2026年9月")
        XCTAssertEqual(DateText.monthDay(date, locale: ja, timeZone: tokyo), "9月24日")
        XCTAssertEqual(DateText.longDate(date, locale: ja, timeZone: tokyo), "2026年9月24日")
        XCTAssertEqual(DateText.yearMonth(date, locale: en, timeZone: tokyo), "September 2026")
        XCTAssertEqual(DateText.monthDay(date, locale: en, timeZone: tokyo), "Sep 24")
        XCTAssertEqual(DateText.longDate(date, locale: en, timeZone: tokyo), "September 24, 2026")
    }

    func testPinnedCalendarKeepsTheUsersTimeZoneAndWeek() {
        var base = Calendar(identifier: .japanese)
        base.firstWeekday = 2
        base.minimumDaysInFirstWeek = 4
        let pinned = PomoGemCalendar.gregorian(timeZone: tokyo, basedOn: base)
        XCTAssertEqual(pinned.identifier, .gregorian)
        XCTAssertEqual(pinned.timeZone, tokyo)
        XCTAssertEqual(pinned.firstWeekday, 2)
        XCTAssertEqual(pinned.minimumDaysInFirstWeek, 4)
    }

    // MARK: Lists, sentences and counters

    func testListsSentencesAndCountersInJapanese() {
        XCTAssertEqual(ListText.compact(["通常3", "金1"]), "通常3・金1")
        XCTAssertEqual(ListText.compact(["通常3"]), "通常3")
        XCTAssertEqual(ListText.compact([]), "")
        XCTAssertEqual(ListText.inSentence(["英語", "数学", "理科"], locale: ja), "英語、数学、理科")
        XCTAssertEqual(SentenceText.join(["減らない。", "消えない。", "責めない。"]), "減らない。消えない。責めない。")
        XCTAssertEqual(SentenceText.join(["減らない。"], locale: ja), "減らない。")
        XCTAssertEqual(CountText.gems(3, locale: ja), "3粒")
        for count in [0, 1, 999, 1_000, 12_345, 1_234_567] {
            XCTAssertEqual(CountText.gems(count, locale: ja), "\(count.formatted(.number.grouping(.automatic).locale(ja)))粒")
        }
    }

    func testSentenceListsAndSentencesInEnglish() {
        XCTAssertEqual(ListText.inSentence(["English", "Math", "Science"], locale: en), "English, Math, and Science")
        XCTAssertEqual(ListText.inSentence(["English", "Math"], locale: en), "English and Math")
        XCTAssertEqual(SentenceText.join(["Nothing shrinks.", "No guilt."], locale: en), "Nothing shrinks. No guilt.")
    }

    /// The catalog half of English (units, separators, plural counters). Skipped
    /// until English is activated; the integration must then provide these values.
    func testCommonEnglishValuesOnceActivated() throws {
        let english = try LocalizationTestSupport.englishBundle()
        XCTAssertEqual(MassText.grams("250", bundle: english, locale: en), "250 g")
        XCTAssertEqual(MassText.kilograms("2.5", bundle: english, locale: en), "2.5 kg")
        XCTAssertEqual(CountText.gems(1, bundle: english, locale: en), "1 gem")
        XCTAssertEqual(CountText.gems(3, bundle: english, locale: en), "3 gems")
        XCTAssertEqual(CountText.gems(12_345, bundle: english, locale: en), "12,345 gems")
        XCTAssertEqual(ListText.compact(["Standard 3", "Gold 1"], bundle: english), "Standard 3 · Gold 1")
    }
}
