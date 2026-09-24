import StoreKitTest
import XCTest

/// Uses Xcode's local StoreKit environment, never a real App Store purchase.
/// Run serially: SKTestSession controls the simulator's shared test storefront.
@MainActor
final class ProCustomDurationUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storeSession: SKTestSession!
    private var usesPreseededLocalStore = false

    override func setUpWithError() throws {
        let storeMode = ProcessInfo.processInfo.environment["POMOGEM_RUN_STOREKIT_TESTS"]
        try XCTSkipUnless(
            storeMode == "1" || storeMode == "preseeded",
            "Requires an explicitly initialized local Xcode StoreKit test environment"
        )
        usesPreseededLocalStore = storeMode == "preseeded"
        continueAfterFailure = false
        executionTimeAllowance = 240
        XCUIApplication().terminate()
        if !usesPreseededLocalStore {
            let configuration = try XCTUnwrap(Bundle(for: Self.self).url(
                forResource: "Products", withExtension: "storekit"
            ))
            storeSession = try SKTestSession(contentsOf: configuration)
            storeSession.resetToDefaultState()
            storeSession.disableDialogs = true
            storeSession.clearTransactions()
        }
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
    }

    override func tearDownWithError() throws {
        if app != nil, app.state == .runningForeground { cancelFocusIfPresented() }
        app?.terminate()
        storeSession?.clearTransactions()
        storeSession?.resetToDefaultState()
        app = nil
        storeSession = nil
    }

    func testNumericSecondsConfirmStartPauseAndRestore() async throws {
        try await launchWithPro()
        try openEditor()
        try replaceInput("minutes", with: "40")
        try replaceInput("seconds", with: "30")
        try finishKeyboard()
        screenshot("Pro duration — numeric 40 minutes 30 seconds")
        try confirmEditor()
        XCTAssertTrue(app.buttons["home.duration-picker"].label.contains("40分30秒"))
        app.buttons["home.focus-launcher"].tap()
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: 8))
        app.buttons["一時停止"].tap()
        XCTAssertTrue(app.buttons["再開する"].waitForExistence(timeout: 4))
        let paused = try remainingSeconds()
        XCTAssertTrue((2_420...2_430).contains(paused), "The focus must start from 2,430 seconds")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["再開する"].waitForExistence(timeout: 12))
        XCTAssertEqual(try remainingSeconds(), paused)
        screenshot("Pro duration — exact paused seconds survive process relaunch")
    }

    func testWheelInputAndCancelKeepPreviousSetting() async throws {
        try await launchWithPro()
        try openEditor()
        try replaceInput("minutes", with: "40")
        try replaceInput("seconds", with: "30")
        try finishKeyboard()
        try confirmEditor()
        try openEditor()
        app.segmentedControls["custom-timer.mode"].buttons["スクロール"].tap()
        let minutes = app.pickers["custom-timer.minutes-wheel"].pickerWheels.firstMatch
        let seconds = app.pickers["custom-timer.seconds-wheel"].pickerWheels.firstMatch
        XCTAssertTrue(minutes.waitForExistence(timeout: 4))
        XCTAssertTrue(seconds.exists)
        minutes.adjust(toPickerWheelValue: "41分")
        seconds.adjust(toPickerWheelValue: "35秒")
        screenshot("Pro duration — independent minute and second wheels")
        app.segmentedControls["custom-timer.mode"].buttons["入力"].tap()
        XCTAssertEqual(app.textFields["custom-timer.minutes-input"].value as? String, "41")
        XCTAssertEqual(app.textFields["custom-timer.seconds-input"].value as? String, "35")
        app.buttons["custom-timer.close"].tap()
        XCTAssertTrue(app.buttons["home.duration-picker"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["home.duration-picker"].label.contains("40分30秒"))
        try openEditor()
        XCTAssertEqual(app.textFields["custom-timer.minutes-input"].value as? String, "40")
        XCTAssertEqual(app.textFields["custom-timer.seconds-input"].value as? String, "30")
        app.buttons["custom-timer.close"].tap()
    }

    func testInvalidAndEmptyInputCannotConfirmOrDiscardDraftByChangingMode() async throws {
        try await launchWithPro()
        try openEditor()
        for (minutes, seconds) in [("1", "60"), ("360", "1"), ("", "0"), ("99999999999999999999999", "0")] {
            try replaceInput("minutes", with: minutes)
            try replaceInput("seconds", with: seconds)
            try finishKeyboard()
            XCTAssertFalse(app.buttons["custom-timer.confirm"].isEnabled)
            XCTAssertFalse(app.segmentedControls["custom-timer.mode"].isEnabled)
            XCTAssertTrue(app.staticTexts["custom-timer.validation"].exists)
            XCTAssertEqual(app.textFields["custom-timer.minutes-input"].value as? String,
                           minutes.isEmpty ? "分" : minutes)
        }
        try replaceInput("minutes", with: "360")
        try replaceInput("seconds", with: "0")
        try finishKeyboard()
        XCTAssertTrue(app.buttons["custom-timer.confirm"].isEnabled)
        screenshot("Pro duration — upper bound accepted after invalid draft correction")
        try confirmEditor()
        XCTAssertTrue(app.buttons["home.duration-picker"].label.contains("360分"))
    }

    func testLargestTextKeepsKeyboardCloseAndConfirmationReachable() async throws {
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        try await launchWithPro()
        try openEditor()
        try replaceInput("minutes", with: "1")
        try replaceInput("seconds", with: "59")
        try finishKeyboard()
        XCTAssertTrue(app.buttons["custom-timer.close"].isHittable)
        XCTAssertTrue(reveal(app.buttons["custom-timer.confirm"]))
        screenshot("Pro duration — largest text on small iPhone with confirmation reachable")
        try confirmEditor()
        XCTAssertTrue(app.buttons["home.duration-picker"].label.contains("1分59秒"))
    }

    func testSettingsEditsTheSamePrecisePreferenceAndCanClearSeconds() async throws {
        try await launchWithPro()
        try openEditor()
        try replaceInput("minutes", with: "25")
        try replaceInput("seconds", with: "30")
        try finishKeyboard()
        try confirmEditor()
        app.buttons["メニュー"].tap()
        let settings = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "設定")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 4))
        settings.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))
        let preference = app.buttons["settings.preferred-focus-duration"]
        XCTAssertTrue(reveal(preference))
        XCTAssertTrue(preference.label.contains("25分30秒"))
        XCTAssertEqual(preference.value as? String, "選択中")
        for minutes in [25, 45, 60, 90] {
            let preset = app.buttons["settings.focus-preset.\(minutes)"]
            XCTAssertTrue(preset.exists)
            XCTAssertEqual(preset.value as? String, "未選択")
        }
        preference.tap()
        XCTAssertTrue(app.textFields["custom-timer.seconds-input"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["custom-timer.minutes-input"].value as? String, "25")
        XCTAssertEqual(app.textFields["custom-timer.seconds-input"].value as? String, "30")
        let confirm = app.buttons["custom-timer.confirm"]
        XCTAssertTrue(reveal(confirm))
        confirm.tap()
        XCTAssertTrue(preference.waitForExistence(timeout: 5))
        XCTAssertTrue(preference.label.contains("25分30秒"))
        XCTAssertEqual(preference.value as? String, "選択中")

        let twentyFiveMinutes = app.buttons["settings.focus-preset.25"]
        XCTAssertTrue(reveal(twentyFiveMinutes))
        twentyFiveMinutes.tap()
        XCTAssertEqual(twentyFiveMinutes.value as? String, "選択中")
        for minutes in [45, 60, 90] {
            XCTAssertEqual(app.buttons["settings.focus-preset.\(minutes)"].value as? String, "未選択")
        }
        XCTAssertTrue(reveal(preference))
        XCTAssertEqual(preference.value as? String, "未選択")
        screenshot("Pro duration — Settings preset clears fractional seconds")
        app.navigationBars["設定"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["home.duration-picker"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.duration-picker"].label.contains("25分"))
        XCTAssertFalse(app.buttons["home.duration-picker"].label.contains("30秒"))
    }

    func testRecentCustomDurationStaysOneTapAwayAfterAPreset() async throws {
        try await launchWithPro()
        try openEditor()
        try replaceInput("minutes", with: "50")
        try replaceInput("seconds", with: "0")
        try finishKeyboard()
        try confirmEditor()
        let picker = app.buttons["home.duration-picker"]
        XCTAssertTrue(picker.label.contains("50分"))

        picker.tap()
        XCTAssertTrue(app.staticTexts["定番の時間"].waitForExistence(timeout: 4)
            || app.buttons["25分"].waitForExistence(timeout: 1))
        app.buttons["25分"].firstMatch.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 4))
        XCTAssertTrue(picker.label.contains("25分"))

        picker.tap()
        let recent = app.buttons["50分"].firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 4), "The last custom time is listed after a preset")
        screenshot("Pro duration — recent custom time in the Home menu")
        recent.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 4))
        XCTAssertTrue(picker.label.contains("50分"), "One tap restores the custom time")

        picker.tap()
        app.buttons["25分"].firstMatch.tap()
        try openEditor()
        XCTAssertEqual(app.textFields["custom-timer.minutes-input"].value as? String, "50",
                       "The editor opens at the most recent custom time, not at the preset")
        app.buttons["custom-timer.close"].tap()
    }

    private func launchWithPro() async throws {
        if !usesPreseededLocalStore {
            _ = try await storeSession.buyProduct(identifier: "com.hinoshiba.pomogem.pro.lifetime")
        }
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 12))
        cancelFocusIfPresented()
        XCTAssertTrue(reveal(app.buttons["home.duration-picker"]))
    }

    private func openEditor() throws {
        let picker = app.buttons["home.duration-picker"]
        try requireControl(reveal(picker), "Duration picker must be reachable")
        picker.tap()
        let custom = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "自由な時間を設定")).firstMatch
        try requireControl(custom.waitForExistence(timeout: 4), "Custom duration menu item must exist")
        custom.tap()
        try requireControl(app.textFields["custom-timer.minutes-input"].waitForExistence(timeout: 8),
                      "The real StoreKit test entitlement must open the editor, not a paywall")
    }

    private func replaceInput(_ component: String, with value: String) throws {
        let field = app.textFields["custom-timer.\(component)-input"]
        // At accessibility sizes the fields stack vertically. Dismiss the
        // number pad before scrolling to a field it currently covers.
        if !field.isHittable { try finishKeyboard() }
        try requireControl(reveal(field), "The input field must be reachable after dismissing the keyboard")
        field.tap()
        let current = field.value as? String ?? ""
        let count = current == "分" || current == "秒" ? 0 : current.count
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count) + value)
    }

    private func finishKeyboard() throws {
        guard app.keyboards.firstMatch.exists else { return }
        let done = app.buttons["custom-timer.keyboard-done"]
        try requireControl(done.waitForExistence(timeout: 2) && done.isHittable,
                           "Number pad must expose its Done action")
        done.tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch
        )
        try requireControl(XCTWaiter.wait(for: [dismissed], timeout: 3) == .completed,
                           "Done must dismiss the number pad")
    }

    private func confirmEditor() throws {
        let confirm = app.buttons["custom-timer.confirm"]
        XCTAssertTrue(reveal(confirm))
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        XCTAssertTrue(app.buttons["home.duration-picker"].waitForExistence(timeout: 5))
    }

    private enum InteractionFailure: Error { case unavailableControl }

    private func requireControl(_ available: Bool, _ message: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        guard available else {
            XCTFail(message, file: file, line: line)
            throw InteractionFailure.unavailableControl
        }
    }

    private func reveal(_ element: XCUIElement) -> Bool {
        for _ in 0..<8 {
            if element.exists, element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func remainingSeconds() throws -> Int {
        let timer = app.descendants(matching: .any)["focus.timer-display"].firstMatch
        let text = try XCTUnwrap(timer.value as? String)
        let expression = try NSRegularExpression(pattern: "残り([0-9]+)分([0-9]+)秒")
        let match = try XCTUnwrap(expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        let minutes = try XCTUnwrap(Range(match.range(at: 1), in: text))
        let seconds = try XCTUnwrap(Range(match.range(at: 2), in: text))
        return try XCTUnwrap(Int(text[minutes])) * 60 + XCTUnwrap(Int(text[seconds]))
    }

    private func cancelFocusIfPresented() {
        let cancel = app.buttons["今日はここまで"].firstMatch
        guard cancel.exists, reveal(cancel) else { return }
        cancel.tap()
        let alert = app.alerts["今日はここまで"]
        if alert.waitForExistence(timeout: 2) { alert.buttons["今日はここまで"].tap() }
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
