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
/// The time shown is the credited focus time: the whole minutes of each
/// completion, which are exactly what earns `Constants.Mass.gramsPerMinute`
/// grams a minute. A Pro focus of 40分30秒 credits 40分 and 400 g; its last
/// 30 seconds earn no mass, so they are not counted as time either. Screens
/// therefore derive time from mass (`focusMinutes(grams:)`,
/// `creditedFocusMinutes(of:)`), never by adding raw seconds: summed seconds
/// said 1時間21分 in 記録 and Wrapped for two such focuses while the card
/// made from them, which only knows grams, said 1時間20分. The 年月
/// drill-down's month, day and theme rows, 記録's month list and Wrapped's
/// theme rows read their time from the same mass for the same reason.
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
                comment: "A duration in whole minutes"
            )
        }
        if remainder == 0 {
            return String(
                localized: "\(hours)時間",
                table: "Common",
                comment: "A duration in whole hours"
            )
        }
        return String(
            localized: "\(hours)時間\(remainder)分",
            table: "Common",
            comment: "A duration in hours and minutes"
        )
    }

    /// Whole minutes of focus a mass stands for, rounded down so a label
    /// never claims more time than was stacked.
    static func focusMinutes(grams: Int) -> Int {
        max(0, grams) / Constants.Mass.gramsPerMinute
    }

    /// The credited focus minutes of these records: their summed mass in
    /// minutes, so a list of records reads the same time as a card or a
    /// summary built from the same mass.
    static func creditedFocusMinutes<Records: Sequence>(
        of sessions: Records
    ) -> Int where Records.Element == StudySession {
        focusMinutes(grams: NonnegativeIntPolicy.sum(sessions.map(\.grams)))
    }

    /// The focus time a mass stands for, e.g. 2,500 g → 「4時間10分」.
    static func focusLabel(grams: Int) -> String {
        minutesLabel(focusMinutes(grams: grams))
    }

    /// The same, for the 64-bit totals of the 年月 repository.
    static func focusMinutes(grams: Int64) -> Int {
        focusMinutes(grams: Int(clamping: grams))
    }

    /// The same, for the 64-bit totals of the 年月 repository.
    static func focusLabel(grams: Int64) -> String {
        minutesLabel(focusMinutes(grams: grams))
    }

    /// Whole minutes of a span of seconds, rounded down. Only for time that
    /// is not credited focus, such as Screen Time's whole ten-minute chunks;
    /// focus totals go through the mass (see the type's comment).
    static func minutesLabel(seconds: Int) -> String {
        minutesLabel(NonnegativeIntPolicy.clamped(seconds) / 60)
    }
}
