import XCTest
@testable import PomoGem

final class CustomDurationEditingStateTests: XCTestCase {
    func testInitialSecondsPreserveMinuteAndSecondComponents() {
        for seconds in [60, 90, 2_400, 2_430, 21_599, 21_600] {
            let editor = CustomDurationEditingState(initialSeconds: seconds)
            XCTAssertEqual(editor.totalSeconds, seconds)
            XCTAssertEqual(editor.minutesText, String(seconds / 60))
            XCTAssertEqual(editor.secondsText, String(seconds % 60))
            XCTAssertTrue(editor.canConfirm)
        }
    }

    func testInvalidDraftRemainsUnchangedAndCannotSwitchOrConfirm() {
        for (minutes, seconds) in [("", "30"), ("1", ""), ("0", "59"), ("360", "1"),
                                    ("361", "0"), ("1", "60"), ("-1", "0"), ("1.5", "0"),
                                    ("1 ", "0"), ("abc", "0"), (String(repeating: "9", count: 80), "0")] {
            var editor = CustomDurationEditingState(initialSeconds: 2_400)
            editor.editMinutes(minutes)
            editor.editSeconds(seconds)
            XCTAssertNil(editor.totalSeconds)
            XCTAssertNotNil(editor.validationMessage)
            XCTAssertFalse(editor.canChangeMode)
            XCTAssertFalse(editor.selectMode(.scroll))
            XCTAssertNil(editor.beginConfirmation())
            XCTAssertEqual(editor.mode, .input)
            XCTAssertEqual(editor.minutesText, minutes)
            XCTAssertEqual(editor.secondsText, seconds)
        }
    }

    func testEditingEmptyFieldCanRecoverWithoutPrematureClamping() {
        var editor = CustomDurationEditingState(initialSeconds: 2_430)
        editor.editMinutes("")
        XCTAssertEqual(editor.minutesText, "")
        XCTAssertNil(editor.totalSeconds)
        editor.editMinutes("9")
        XCTAssertEqual(editor.totalSeconds, 570)
        editor.editMinutes("90")
        XCTAssertEqual(editor.totalSeconds, 5_430)
        XCTAssertNil(editor.validationMessage)
    }

    func testDecimalDigitsAcceptLocalizedInputWithoutChangingItsText() {
        var editor = CustomDurationEditingState(initialSeconds: 60)
        editor.editMinutes("４０")
        editor.editSeconds("٣٠")
        XCTAssertEqual(editor.totalSeconds, 2_430)
        XCTAssertEqual(editor.minutesText, "４０")
        XCTAssertEqual(editor.secondsText, "٣٠")
        editor.editMinutes("Ⅳ")
        XCTAssertNil(editor.totalSeconds, "Non-decimal numeric symbols are not keyboard digits")
    }

    func testInputAndWheelsShareExactSecondsAcrossModeChanges() {
        var editor = CustomDurationEditingState(initialSeconds: 2_400)
        editor.editMinutes("040")
        editor.editSeconds("30")
        XCTAssertTrue(editor.selectMode(.scroll))
        XCTAssertEqual(editor.wheelMinutes, 40)
        XCTAssertEqual(editor.wheelSeconds, 30)
        XCTAssertEqual(editor.minutesText, "040", "Changing mode must not rewrite a valid typed draft")
        editor.selectWheelMinutes(41)
        editor.selectWheelSeconds(29)
        XCTAssertTrue(editor.selectMode(.input))
        XCTAssertEqual(editor.minutesText, "41")
        XCTAssertEqual(editor.secondsText, "29")
        XCTAssertEqual(editor.beginConfirmation(), 2_489)
    }

    func testWheelMaximumSelectsSixHoursAndRefusesOutOfRangeSeconds() {
        var editor = CustomDurationEditingState(initialSeconds: 21_599)
        XCTAssertTrue(editor.selectMode(.scroll))
        editor.selectWheelMinutes(360)
        XCTAssertEqual(editor.wheelSeconds, 0)
        XCTAssertEqual(editor.maximumWheelSeconds, 0)
        XCTAssertEqual(editor.totalSeconds, 21_600)
        editor.selectWheelSeconds(59)
        editor.selectWheelMinutes(361)
        XCTAssertEqual(editor.totalSeconds, 21_600)
        editor.selectWheelMinutes(359)
        editor.selectWheelSeconds(59)
        XCTAssertEqual(editor.totalSeconds, 21_599)
    }

    func testAcceptedConfirmationIsDeliveredOnceAndFreezesDraft() {
        var editor = CustomDurationEditingState(initialSeconds: 2_430)
        XCTAssertEqual(editor.beginConfirmation(), 2_430)
        XCTAssertNil(editor.beginConfirmation(), "A reentrant confirmation cannot send a second value")
        editor.editSeconds("0")
        XCTAssertEqual(editor.totalSeconds, 2_430)
        editor.finishConfirmation(accepted: true)
        XCTAssertNil(editor.beginConfirmation())
        XCTAssertFalse(editor.selectMode(.scroll))
        editor.cancel()
        editor.finishConfirmation(accepted: false)
        XCTAssertNil(editor.beginConfirmation(), "A late response cannot reopen accepted state")
    }

    func testParentRejectionKeepsDraftAndPermitsAValidRetry() {
        var editor = CustomDurationEditingState(initialSeconds: 2_430)
        XCTAssertEqual(editor.beginConfirmation(), 2_430)
        editor.finishConfirmation(accepted: false)
        XCTAssertTrue(editor.canConfirm)
        XCTAssertNotNil(editor.validationMessage)
        XCTAssertEqual(editor.minutesText, "40")
        XCTAssertEqual(editor.secondsText, "30")
        editor.editSeconds("31")
        XCTAssertNil(editor.validationMessage)
        XCTAssertEqual(editor.beginConfirmation(), 2_431)
        editor.finishConfirmation(accepted: true)
        XCTAssertNil(editor.beginConfirmation())
    }

    func testCancelledDraftNeverProducesAConfirmation() {
        var editor = CustomDurationEditingState(initialSeconds: 2_700)
        editor.editMinutes("40")
        editor.editSeconds("30")
        editor.cancel()
        XCTAssertNil(editor.beginConfirmation())
        editor.editMinutes("90")
        XCTAssertEqual(editor.minutesText, "40")
    }

    func testCancellationWhileParentRespondsCannotReenableConfirmation() {
        var editor = CustomDurationEditingState(initialSeconds: 2_430)
        XCTAssertEqual(editor.beginConfirmation(), 2_430)
        editor.cancel()
        editor.finishConfirmation(accepted: false)
        XCTAssertNil(editor.beginConfirmation())
        XCTAssertFalse(editor.isEditing)
    }

    func testInvalidInitialDurationIsNotSilentlyReplaced() {
        for seconds in [0, 59, 21_601, Int.max, Int.min] {
            var editor = CustomDurationEditingState(initialSeconds: seconds)
            XCTAssertNil(editor.totalSeconds)
            XCTAssertNotNil(editor.validationMessage)
            XCTAssertNil(editor.beginConfirmation())
        }
    }
}
