import Foundation

/// The one way the app says how long someone focused: 「45分」, 「2時間」,
/// 「4時間10分」, 「1,234時間5分」.
///
/// Every history screen used to format time on its own. 記録 said 「0m」 and
/// 「1.5h」 (English abbreviations that Japanese VoiceOver can read as
/// meters, and a decimal hour that hides the minutes), Wrapped said 「1時間
/// 15分」 for the same month, and share cards gave only grams, which a
/// follower cannot turn into time (walk-edge-08, history-08). Screens now ask
/// this type, so the same effort reads the same everywhere.
///
/// Mass converts exactly: focus earns `Constants.Mass.gramsPerMinute` grams a
/// minute, and nothing on the study side of a jar or a card weighs anything
/// else (black Screen Time stones are never counted there).
enum DurationPresentation {
    /// Whole minutes as 「N分」, 「H時間」 or 「H時間M分」. Negative input is
    /// clamped to 「0分」; hours are digit-grouped (「1,234時間」).
    static func minutesLabel(_ minutes: Int) -> String {
        let value = max(0, minutes)
        let hours = value / 60
        let remainder = value % 60
        if hours == 0 {
            return String(
                localized: "\(remainder)分",
                table: "Common",
                comment: "Focus duration under an hour. Argument: minutes"
            )
        }
        if remainder == 0 {
            return String(
                localized: "\(hours)時間",
                table: "Common",
                comment: "Focus duration in whole hours. Argument: hours"
            )
        }
        return String(
            localized: "\(hours)時間\(remainder)分",
            table: "Common",
            comment: "Focus duration. Arguments: hours, then minutes"
        )
    }

    /// Whole minutes of focus a mass stands for, rounded down so a label
    /// never claims more time than was stacked.
    static func focusMinutes(grams: Int) -> Int {
        max(0, grams) / Constants.Mass.gramsPerMinute
    }

    /// The focus time a mass stands for, e.g. 2,500 g → 「4時間10分」.
    static func focusLabel(grams: Int) -> String {
        minutesLabel(focusMinutes(grams: grams))
    }
}
