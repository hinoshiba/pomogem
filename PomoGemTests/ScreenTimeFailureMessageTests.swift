import Foundation
import XCTest
@testable import PomoGem

/// a11y-07. The Screen Time page's alert never shows a framework's own text.
@MainActor
final class ScreenTimeFailureMessageTests: XCTestCase {
    private struct FrameworkRefusal: LocalizedError {
        var errorDescription: String? { "The operation couldn’t be completed. (DeviceActivity.MonitoringError error 1.)" }
    }

    private let recorded = "スクリーンタイムの監視を開始できませんでした。もう一度お試しください。"

    func testTheAppsOwnErrorsKeepTheirCuratedSentence() {
        XCTAssertEqual(
            ScreenTimeFailureMessage.text(for: ScreenTimeError.missingTheme, recordedMonitoringError: recorded, action: .save),
            ScreenTimeError.missingTheme.localizedDescription
        )
        XCTAssertEqual(
            ScreenTimeFailureMessage.text(
                for: ScreenTimeController.OperationError.busy, recordedMonitoringError: nil, action: .reset
            ),
            ScreenTimeController.OperationError.busy.localizedDescription
        )
    }

    func testAFrameworkRefusalShowsTheLedgersOwnExplanation() {
        let text = ScreenTimeFailureMessage.text(
            for: FrameworkRefusal(), recordedMonitoringError: recorded, action: .save
        )
        XCTAssertEqual(text, recorded)
    }

    func testAnUnknownErrorWithoutAnExplanationGetsAPlainRetryLine() {
        for action in [ScreenTimeFailureMessage.Action.save, .clearBlackStones, .reset] {
            let text = ScreenTimeFailureMessage.text(
                for: FrameworkRefusal(), recordedMonitoringError: nil, action: action
            )
            XCTAssertTrue(text.hasSuffix("もう一度お試しください。"), text)
            XCTAssertFalse(text.contains("operation couldn"), text)
            XCTAssertFalse(text.contains("MonitoringError"), text)
        }
    }
}
