import Foundation

/// Japanese focus-time text for history screens: 「25分」「1時間」「1時間15分」.
/// Log, Wrapped and the 年月 drill-down share this one formatter so the same
/// minutes never read differently on two screens.
enum DurationPresentation {
    /// Whole minutes, clamped at zero. Hours are grouped (「1,234時間」).
    static func minutesLabel(_ minutes: Int) -> String {
        let value = max(0, minutes)
        guard value >= 60 else {
            return String(localized: "\(value)分", table: "Common", comment: "A duration in whole minutes")
        }
        let hours = value / 60
        let remainder = value % 60
        return remainder == 0
            ? String(localized: "\(hours)時間", table: "Common", comment: "A duration in whole hours")
            : String(localized: "\(hours)時間\(remainder)分", table: "Common", comment: "A duration in hours and minutes")
    }

    /// Rounds down to whole minutes, like every other duration in the app.
    static func minutesLabel(seconds: Int) -> String {
        minutesLabel(NonnegativeIntPolicy.clamped(seconds) / 60)
    }
}
