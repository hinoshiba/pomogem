import XCTest
@testable import PomoGem

#if !targetEnvironment(macCatalyst)
final class FocusActivityDurationLabelTests: XCTestCase {
    func testWholeMinutesKeepExistingLiveActivityLabels() {
        for (seconds, label) in [(60, "1分"), (1_500, "25分"), (2_700, "45分"),
                                 (3_600, "60分"), (5_400, "90分"), (21_600, "360分")] {
            XCTAssertEqual(FocusActivityConstants.durationLabel(seconds: seconds), label)
        }
    }

    func testSecondLabelsPreserveDemoAndFractionalMinutes() {
        for (seconds, label) in [(1, "1秒"), (12, "12秒"), (59, "59秒"),
                                 (61, "1分1秒"), (119, "1分59秒"),
                                 (2_430, "40分30秒"), (21_599, "359分59秒")] {
            XCTAssertEqual(FocusActivityConstants.durationLabel(seconds: seconds), label)
        }
    }

    func testZeroAndNegativeInputsHaveANonnegativeLabelWithoutOverflow() {
        for seconds in [0, -1, -60, Int.min] {
            XCTAssertEqual(FocusActivityConstants.durationLabel(seconds: seconds), "0分")
        }
    }

    func testWidgetAndAppAgreeForEverySupportedDurationWithoutMinuteTruncation() {
        for seconds in 60...21_600 {
            XCTAssertEqual(
                FocusActivityConstants.durationLabel(seconds: seconds),
                PomodoroDuration(totalSeconds: seconds).displayLabel,
                "App and independently compiled widget formatter differ at \(seconds) seconds"
            )
        }
    }
}
#endif
