import XCTest
@testable import PomoGem

/// Pins the one Japanese duration wording every history and share surface
/// uses (walk-edge-08, history-08). The localization wave re-bases the
/// implementation on Foundation's duration style; these outputs must not move.
final class DurationPresentationTests: XCTestCase {
    func testMinutesUseJapaneseUnitsWithoutDecimalHours() {
        XCTAssertEqual(DurationPresentation.minutesLabel(0), "0分")
        XCTAssertEqual(DurationPresentation.minutesLabel(1), "1分")
        XCTAssertEqual(DurationPresentation.minutesLabel(30), "30分")
        XCTAssertEqual(DurationPresentation.minutesLabel(59), "59分")
        XCTAssertEqual(DurationPresentation.minutesLabel(60), "1時間")
        XCTAssertEqual(DurationPresentation.minutesLabel(75), "1時間15分")
        XCTAssertEqual(DurationPresentation.minutesLabel(90), "1時間30分")
        XCTAssertEqual(DurationPresentation.minutesLabel(250), "4時間10分")
        XCTAssertEqual(DurationPresentation.minutesLabel(7_425), "123時間45分")
        XCTAssertEqual(DurationPresentation.minutesLabel(74_040), "1,234時間")
        XCTAssertEqual(DurationPresentation.minutesLabel(74_045), "1,234時間5分")
    }

    func testNegativeMinutesClampToZero() {
        XCTAssertEqual(DurationPresentation.minutesLabel(-1), "0分")
        XCTAssertEqual(DurationPresentation.minutesLabel(.min), "0分")
    }

    func testNoEnglishAbbreviationsOrDecimalsSurvive() {
        for minutes in [0, 5, 45, 60, 61, 100, 600, 6_001, 100_000] {
            let label = DurationPresentation.minutesLabel(minutes)
            XCTAssertFalse(label.contains("m"), label)
            XCTAssertFalse(label.contains("h"), label)
            XCTAssertFalse(label.contains("."), label)
        }
    }

    func testMassConvertsAtTenGramsAMinuteRoundingDown() {
        XCTAssertEqual(Constants.Mass.gramsPerMinute, 10)
        XCTAssertEqual(DurationPresentation.focusMinutes(grams: 2_500), 250)
        XCTAssertEqual(DurationPresentation.focusLabel(grams: 2_500), "4時間10分")
        XCTAssertEqual(DurationPresentation.focusLabel(grams: 250), "25分")
        XCTAssertEqual(DurationPresentation.focusLabel(grams: 600), "1時間")
        // A proportionally scaled summary can land between minutes; the label
        // never claims the extra part-minute.
        XCTAssertEqual(DurationPresentation.focusMinutes(grams: 1_259), 125)
        XCTAssertEqual(DurationPresentation.focusLabel(grams: 9), "0分")
        XCTAssertEqual(DurationPresentation.focusLabel(grams: -250), "0分")
        // The 年月 repository's 64-bit totals read the same way.
        XCTAssertEqual(DurationPresentation.focusMinutes(grams: Int64(1_259)), 125)
        XCTAssertEqual(DurationPresentation.focusLabel(grams: Int64(2_500)), "4時間10分")
        XCTAssertEqual(DurationPresentation.focusLabel(grams: Int64(-250)), "0分")
        XCTAssertEqual(
            DurationPresentation.focusMinutes(grams: Int64.max),
            Int.max / Constants.Mass.gramsPerMinute
        )
    }

    func testRecordsCreditWholeMinutesSoTimeMatchesTheirMass() {
        // Two Pro focuses of 40分30秒 credit 40分 and 400 g each. Summing raw
        // seconds said 1時間21分 in 記録 and Wrapped, while a card made from
        // the same records, which only knows their grams, said 1時間20分.
        let end = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let precise = (0..<2).map { index in
            record(endingAt: end.addingTimeInterval(Double(index) * 3_600), seconds: 2_430, source: .timer)
        }
        XCTAssertEqual(precise.map(\.grams), [400, 400])
        XCTAssertEqual(DurationPresentation.minutesLabel(
            NonnegativeIntPolicy.sum(precise.map(\.seconds)) / 60
        ), "1時間21分", "The old seconds-based total")
        XCTAssertEqual(DurationPresentation.creditedFocusMinutes(of: precise), 80)
        let preciseGrams = NonnegativeIntPolicy.sum(precise.map(\.grams))
        XCTAssertEqual(DurationPresentation.focusLabel(grams: preciseGrams), "1時間20分")
        XCTAssertEqual(
            DurationPresentation.minutesLabel(DurationPresentation.creditedFocusMinutes(of: precise)),
            DurationPresentation.focusLabel(grams: preciseGrams),
            "記録, Wrapped and the card read the same time"
        )

        // Whole-minute records, self-reported time and a Screen Time chunk
        // already credit exactly their minutes.
        let mixed = precise + [
            record(endingAt: end.addingTimeInterval(-7_200), seconds: 1_500, source: .timer),
            record(endingAt: end.addingTimeInterval(-10_800), seconds: 1_800, source: .manual),
            record(
                endingAt: end.addingTimeInterval(-14_400),
                seconds: SessionSource.screenTimeSeconds,
                source: .screenTime
            )
        ]
        XCTAssertEqual(DurationPresentation.creditedFocusMinutes(of: mixed), 80 + 25 + 30 + 10)
        XCTAssertEqual(DurationPresentation.creditedFocusMinutes(of: [StudySession]()), 0)
    }

    private func record(endingAt end: Date, seconds: Int, source: SessionSource) -> StudySession {
        StudySession(
            startAt: end.addingTimeInterval(-Double(seconds)),
            endAt: end,
            seconds: seconds,
            source: source,
            deviceDayKey: FairnessPolicy.deviceDayKey(for: end)
        )
    }

    func testEffortProgressDurationKeepsItsOutputThroughTheSharedHelper() {
        XCTAssertEqual(EffortProgressPresentation.formattedDuration(grams: 250), "25分")
        XCTAssertEqual(EffortProgressPresentation.formattedDuration(grams: 6_000), "10時間")
        XCTAssertEqual(EffortProgressPresentation.formattedDuration(grams: 6_150), "10時間15分")
        XCTAssertEqual(
            EffortProgressPresentation.formattedDuration(grams: 740_400),
            "1,234時間"
        )
        // Not a whole minute: the explicit mass fallback stays.
        XCTAssertEqual(EffortProgressPresentation.formattedDuration(grams: 1_255), "1,255g相当")
    }
}
