import Foundation

// Formatting helpers for units, dates, lists and counters (Docs/Localization.md).
//
// The Japanese output of every helper is byte-identical to what the app builds
// by hand today, so a screen can switch to a helper without changing a single
// Japanese character. Two rules make that hold on every supported iOS version:
//
// - Durations and spoken masses compose their Japanese themselves instead of
//   asking ICU. Unit spacing comes from ICU data that differs across iOS
//   releases, and only the newest runtime is available for testing. Other
//   languages use Foundation's format styles ("1 hr 15 min", "250 grams").
// - Units and counters that need translation go through the `Common` String
//   Catalog. The key is the Japanese source, so the Japanese value is the key
//   itself and never depends on a translation.
//
// Every helper formats in `PomoGemLocale.current` by default: the language the
// app's strings are shown in, with the user's region. `locale` and `bundle`
// parameters exist for tests; screens use the defaults.
//
// These helpers are compiled into the app only. `PomoGemLocale` and
// `DurationText` live in Shared/LocalizedDuration.swift, which the widget
// extension (widgets and the Live Activity) compiles too.

/// The calendar for PomoGem's month and year buckets.
///
/// Month buckets are Gregorian (`StrataMath.monthLabel`, `FairnessPolicy`), so
/// their labels must be too: on an iPhone set to the Japanese calendar the
/// system style would print 令和8年9月 for the 2026年9月 bucket. Time zone and
/// week settings still follow the user. The 年月 timeline still buckets years
/// with `Calendar.autoupdatingCurrent` (critic-04); it must move to this
/// calendar when its labels move to `DateText`.
enum PomoGemCalendar {
    static func gregorian(
        timeZone: TimeZone = .current,
        basedOn calendar: Calendar = .current
    ) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        gregorian.locale = calendar.locale
        gregorian.firstWeekday = calendar.firstWeekday
        gregorian.minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
        return gregorian
    }
}

enum MassText {
    /// 「250g」. Pass the number exactly as the screen formats it today (grouping
    /// and decimals differ between screens); en reads "250 g".
    static func grams(_ number: String, bundle: Bundle = .main, locale: Locale = PomoGemLocale.current) -> String {
        String(
            localized: "\(number)g",
            table: "Common",
            bundle: bundle,
            locale: locale,
            comment: "Mass in grams. %@ is the number, already formatted. en: '%@ g' (with a space; never converted to ounces)."
        )
    }

    /// 「2.5kg」; en "2.5 kg".
    static func kilograms(_ number: String, bundle: Bundle = .main, locale: Locale = PomoGemLocale.current) -> String {
        String(
            localized: "\(number)kg",
            table: "Common",
            bundle: bundle,
            locale: locale,
            comment: "Mass in kilograms. %@ is the number, already formatted. en: '%@ kg'."
        )
    }

    /// VoiceOver: ja 「250グラム」, en "250 grams" / "1 gram". Digits are grouped
    /// by the locale, which VoiceOver reads the same as ungrouped digits.
    static func spoken(grams: Int, locale: Locale = PomoGemLocale.current) -> String {
        if PomoGemLocale.composesJapanese(locale) {
            return japaneseGrams(grams, locale: locale)
        }
        return Measurement(value: Double(grams), unit: UnitMass.grams)
            .formatted(.measurement(width: .wide, usage: .asProvided).locale(locale))
    }

    /// VoiceOver: ja 「2.5キログラム」 (POSIX decimals, as the screens print them
    /// today), en "2.5 kilograms".
    static func spoken(kilograms: Double, fractionDigits: Int, locale: Locale = PomoGemLocale.current) -> String {
        let digits = max(0, fractionDigits)
        if PomoGemLocale.composesJapanese(locale) {
            return japaneseKilograms(kilograms, fractionDigits: digits)
        }
        return Measurement(value: kilograms, unit: UnitMass.kilograms).formatted(
            .measurement(
                width: .wide,
                usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(digits))
            ).locale(locale)
        )
    }

    // l10n-ignore-begin: Japanese units are composed here so they cannot drift with ICU data
    private static func japaneseGrams(_ grams: Int, locale: Locale) -> String {
        PomoGemLocale.grouped(grams, locale: locale) + "グラム"
    }

    private static func japaneseKilograms(_ kilograms: Double, fractionDigits: Int) -> String {
        String(format: "%.\(fractionDigits)f", kilograms) + "キログラム"
    }
    // l10n-ignore-end
}

enum DateText {
    /// A month bucket: ja 「2026年9月」, en "September 2026".
    static func yearMonth(_ date: Date, locale: Locale = PomoGemLocale.current, timeZone: TimeZone = .current) -> String {
        date.formatted(style(locale: locale, timeZone: timeZone).year().month(.wide))
    }

    /// A year bucket: ja 「2026年」, en "2026", for any date inside the year
    /// (pass the bucket's start).
    ///
    /// It takes a date, not the bucket's year number, so an era year cannot
    /// reach the label: on an iPhone set to 和暦, `Calendar.current` numbers
    /// 2026 as 8, and 「\(year)年」 or a helper fed that Int prints 「8年」
    /// (critic-04). The label alone does not fix that screen: the year buckets
    /// themselves must come from `PomoGemCalendar.gregorian()` as well, or an
    /// era change (May 2019) splits a year. Never interpolate the Int into a
    /// localized string either: that prints 「2,026年」.
    static func year(_ date: Date, locale: Locale = PomoGemLocale.current, timeZone: TimeZone = .current) -> String {
        date.formatted(style(locale: locale, timeZone: timeZone).year())
    }

    /// ja 「9月24日」, en "Sep 24".
    static func monthDay(_ date: Date, locale: Locale = PomoGemLocale.current, timeZone: TimeZone = .current) -> String {
        date.formatted(style(locale: locale, timeZone: timeZone).month().day())
    }

    /// ja 「2026年9月24日」, en "September 24, 2026".
    static func longDate(_ date: Date, locale: Locale = PomoGemLocale.current, timeZone: TimeZone = .current) -> String {
        date.formatted(
            Date.FormatStyle(
                date: .long,
                time: .omitted,
                locale: locale,
                calendar: PomoGemCalendar.gregorian(timeZone: timeZone),
                timeZone: timeZone
            )
        )
    }

    private static func style(locale: Locale, timeZone: TimeZone) -> Date.FormatStyle {
        Date.FormatStyle(
            locale: locale,
            calendar: PomoGemCalendar.gregorian(timeZone: timeZone),
            timeZone: timeZone
        )
    }
}

enum ListText {
    /// Compact stats: ja 「通常3・金1」, en "Standard 3 · Gold 1". Each item is
    /// already a complete localized phrase.
    static func compact(_ items: [String], bundle: Bundle = .main) -> String {
        items.joined(separator: String(
            localized: "・",
            table: "Common",
            bundle: bundle,
            comment: "Separator between compact stats, as in 通常3・金1. en: ' · ' (middle dot with spaces)."
        ))
    }

    /// A list inside a sentence: ja 「英語、数学、理科」, en "English, Math, and Science".
    static func inSentence(_ items: [String], locale: Locale = PomoGemLocale.current) -> String {
        items.formatted(.list(type: .and).locale(locale))
    }
}

enum SentenceText {
    /// Joins complete sentences, each carrying its own final punctuation:
    /// Japanese needs no space after 「。」, English (and every other language
    /// the app may fall back to) needs one after ".". An empty catalog value
    /// cannot express the Japanese separator (Foundation returns the key), so
    /// the language decides.
    static func join(_ sentences: [String], locale: Locale = PomoGemLocale.current) -> String {
        sentences.joined(separator: PomoGemLocale.composesJapanese(locale) ? "" : " ")
    }
}

enum CountText {
    /// ja 「3粒」「12,345粒」, en "1 gem" / "3 gems". Interpolating the Int (not a
    /// formatted String) is what lets English pick a plural form.
    static func gems(_ count: Int, bundle: Bundle = .main, locale: Locale = PomoGemLocale.current) -> String {
        String(
            localized: "\(count)粒",
            table: "Common",
            bundle: bundle,
            locale: locale,
            comment: "Number of gems. %lld is the count. en needs plural variations: '%lld gem' / '%lld gems'."
        )
    }
}
