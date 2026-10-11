import Foundation

/// User-facing arithmetic always consumes the same saved time as the jar.
/// Counts in legacy receipts remain historical facts, never progress inputs.
enum TimeFusionPresentation {
    static func duration(grams: Int) -> String {
        DurationText.short(minutes: max(0, grams) / Constants.Mass.gramsPerMinute)
    }

    static func progress(totalGrams: Int?, isLowerBound: Bool) -> String {
        guard let totalGrams, !isLowerBound else {
            return String(localized: "結晶の時間を確認中", table: "Home",
                          comment: "Time-fusion progress while the total is unverified")
        }
        let state = TimeFusionPolicy.snapshot(totalGrams: totalGrams)
        let grams = state.nextCrystalRemainingGrams
        let remaining = DurationText.short(minutes: grams / Constants.Mass.gramsPerMinute
            + (grams % Constants.Mass.gramsPerMinute == 0 ? 0 : 1))
        return String(localized: "次の結晶まで あと\(remaining)", table: "Home",
                      comment: "Exact remaining saved focus time to the next 250-minute crystal")
    }

    static var explanation: String {
        String(localized: "合計4時間10分で結晶1個。10個分の時間で、次の大きさにまとまります。途中の時間も繰り越すので、短く分けても同じ時間なら同じ結晶になります。", table: "Home",
               comment: "Time-based fusion rules: exact remainder and split-invariant crystal sizes and counts")
    }
}
