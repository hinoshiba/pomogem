import Foundation

/// The calendar the app buckets and labels years and months with.
///
/// Month and year buckets are Gregorian everywhere they are stored or shown
/// (`StrataMath.monthLabel`, `FairnessPolicy.deviceDayKey`, the 年月
/// timeline). With the iPhone set to 和暦, the current calendar's year of
/// 2026 is 8, so a year chip built from it read 「8年」. Every other date keeps
/// the person's calendar through `Date.FormatStyle`.
enum PomoGemCalendar {
    /// Gregorian, in the person's time zone, language and week settings.
    static var gregorian: Calendar {
        gregorian(basedOn: .autoupdatingCurrent)
    }

    static func gregorian(basedOn base: Calendar) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = base.locale
        calendar.timeZone = base.timeZone
        calendar.firstWeekday = base.firstWeekday
        calendar.minimumDaysInFirstWeek = base.minimumDaysInFirstWeek
        return calendar
    }

    /// Formats `date` in the calendar's language but on the Gregorian year,
    /// e.g. 「2026年9月」 rather than 「令和8年9月」 next to a 「2026年」 chip.
    static func text(
        _ date: Date,
        _ style: Date.FormatStyle,
        calendar: Calendar = gregorian
    ) -> String {
        var style = style
        style.locale = calendar.locale ?? .autoupdatingCurrent
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}
