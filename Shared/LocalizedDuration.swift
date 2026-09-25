import Foundation

// The formatting locale and the duration helper (Docs/Localization.md).
//
// This file is compiled into the app AND the widget extension, so the Live
// Activity (FocusActivityConstants.durationLabel) and the widgets can format
// durations exactly like the app. The widget bundle has no Common table, so
// keep this file free of String Catalog keys: Japanese is composed in code and
// every other language uses Foundation's format styles. The app-only helpers
// (MassText, DateText, ListText, SentenceText, CountText) live in
// PomoGem/Core/Localization/LocalizedFormat.swift.

/// The locale PomoGem formats numbers, units and dates in.
///
/// `Locale.current` does not always speak the language of the strings. With a
/// Japanese and an English localization, a Korean iPhone gets the Japanese
/// strings (the development region) while `Locale.current` becomes en_KR
/// (iOS 26.5 Simulator), so dates and units would read "Sep 2026" or "25 min"
/// next to Japanese labels. Pairing the language of the resolved localization
/// with the user's region keeps each screen in one language. While the app is
/// Japanese-only this is the same as `Locale.current` (ja_KR, ja_US, ...).
/// In an extension `Bundle.main` is the extension's own bundle, which ships the
/// same localizations as the app.
enum PomoGemLocale {
    static var current: Locale {
        locale(localization: Bundle.main.preferredLocalizations.first, base: .current)
    }

    /// `base` with its language replaced by `localization` (region, calendar
    /// and other preferences are kept).
    static func locale(localization: String?, base: Locale) -> Locale {
        guard let localization, !localization.isEmpty else { return base }
        var components = Locale.Components(locale: base)
        // The region lives in the language components (en_KR), so keep it
        // unless the localization names its own (en-GB).
        let region = components.languageComponents.region
        components.languageComponents = Locale.Language.Components(identifier: localization)
        if components.languageComponents.region == nil {
            components.languageComponents.region = region
        }
        return Locale(components: components)
    }

    /// Whether a helper composes its Japanese itself. The formatting locale
    /// always follows the language the strings resolve in.
    static func composesJapanese(_ locale: Locale) -> Bool {
        locale.language.languageCode == .japanese
    }

    /// Digits grouped the way `locale` groups them (1,234).
    static func grouped(_ value: Int, locale: Locale) -> String {
        value.formatted(.number.grouping(.automatic).locale(locale))
    }
}

enum DurationText {
    /// Which units a duration may use. Smaller remainders are dropped, never rounded up.
    enum Units: Sendable {
        /// 30秒 · 25分 · 1分30秒 · 1時間15分
        case hoursMinutesSeconds
        /// 25分 · 1時間 · 1時間15分 · 1,234時間 (totals of whole minutes)
        case hoursMinutes
        /// 30秒 · 90分 · 1分30秒 (timer lengths, which never switch to hours)
        case minutesSeconds
    }

    /// A compact duration: ja 「1時間15分」, en "1 hr 15 min".
    static func short(
        seconds: Int,
        units: Units = .hoursMinutesSeconds,
        locale: Locale = PomoGemLocale.current
    ) -> String {
        if PomoGemLocale.composesJapanese(locale) {
            return japanese(seconds: seconds, units: units, locale: locale)
        }
        return foundation(seconds: seconds, units: units, width: .condensedAbbreviated, locale: locale)
    }

    /// A compact duration of whole minutes: ja 「25分」「1時間15分」, en "25 min".
    static func short(minutes: Int, locale: Locale = PomoGemLocale.current) -> String {
        short(seconds: seconds(fromMinutes: minutes), units: .hoursMinutes, locale: locale)
    }

    /// The VoiceOver form: ja reads the compact text naturally, en spells the
    /// units out ("1 hour, 15 minutes").
    static func spoken(
        seconds: Int,
        units: Units = .hoursMinutesSeconds,
        locale: Locale = PomoGemLocale.current
    ) -> String {
        if PomoGemLocale.composesJapanese(locale) {
            return japanese(seconds: seconds, units: units, locale: locale)
        }
        return foundation(seconds: seconds, units: units, width: .wide, locale: locale)
    }

    static func spoken(minutes: Int, locale: Locale = PomoGemLocale.current) -> String {
        spoken(seconds: seconds(fromMinutes: minutes), units: .hoursMinutes, locale: locale)
    }

    private static func seconds(fromMinutes minutes: Int) -> Int {
        let result = max(0, minutes).multipliedReportingOverflow(by: 60)
        return result.overflow ? Int.max : result.partialValue
    }

    private static func foundation(
        seconds: Int,
        units: Units,
        width: Duration.UnitsFormatStyle.UnitWidth,
        locale: Locale
    ) -> String {
        let allowed: Set<Duration.UnitsFormatStyle.Unit>
        switch units {
        case .hoursMinutesSeconds: allowed = [.hours, .minutes, .seconds]
        case .hoursMinutes: allowed = [.hours, .minutes]
        case .minutesSeconds: allowed = [.minutes, .seconds]
        }
        return Duration.seconds(max(0, seconds)).formatted(
            .units(allowed: allowed, width: width, fractionalPart: .hide(rounded: .down))
                .locale(locale)
        )
    }

    // l10n-ignore-begin: Japanese units are composed here so they cannot drift with ICU data
    private static func japanese(seconds: Int, units: Units, locale: Locale) -> String {
        let value = max(0, seconds)
        let hours: Int
        let minutes: Int
        let remainder: Int
        switch units {
        case .hoursMinutesSeconds:
            (hours, minutes, remainder) = (value / 3_600, value % 3_600 / 60, value % 60)
        case .hoursMinutes:
            (hours, minutes, remainder) = (value / 3_600, value % 3_600 / 60, 0)
        case .minutesSeconds:
            (hours, minutes, remainder) = (0, value / 60, value % 60)
        }
        var text = ""
        if hours > 0 { text += PomoGemLocale.grouped(hours, locale: locale) + "時間" }
        if minutes > 0 { text += PomoGemLocale.grouped(minutes, locale: locale) + "分" }
        if remainder > 0 { text += "\(remainder)秒" }
        if text.isEmpty {
            return units == .hoursMinutes ? "0分" : "0秒"
        }
        return text
    }
    // l10n-ignore-end
}
