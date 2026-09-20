import XCTest

/// Simulator navigation and accessibility coverage only. These tests never
/// grant permission, simulate a successful callback, or operate the app picker.
@MainActor
final class ScreenTimeSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("This suite checks the real unavailable Simulator state; use the signed-device checklist for Screen Time.")
#endif
        continueAfterFailure = false
        executionTimeAllowance = 180
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
    }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0, let app {
            attach("Screen Time failure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Screen Time accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app?.terminate()
        app = nil
    }

    func testSettingsExposeRealAuthorizationStateAndResetConsequences() {
        launchAndOpenSettings()
        assertAuthorizationHasNotBeenInvented()
        attach("Screen Time — permission required")

        let learning = app.buttons["screen-time.learning-apps"]
        XCTAssertTrue(reveal(learning))
        XCTAssertFalse(learning.isEnabled)
        XCTAssertEqual(learning.value as? String, "0アプリ選択中")
        let negative = app.buttons["screen-time.distraction-apps"]
        XCTAssertTrue(reveal(negative))
        XCTAssertFalse(negative.isEnabled)
        XCTAssertEqual(negative.value as? String, "0アプリ選択中")
        XCTAssertTrue(reveal(text(containing: "無料でもアプリ数は無制限")))

        let total = app.staticTexts["screen-time.negative-total"]
        XCTAssertTrue(reveal(total, upwards: false))
        let originalTotal = total.label
        XCTAssertTrue(originalTotal.contains("黒いgem"))
        XCTAssertTrue(originalTotal.contains("0"))
        XCTAssertTrue(reveal(text(containing: "JSON書き出しや保存先の切り替えでは引き継ぎません")))
        assertResetConfirmationCanBeCancelled()
        XCTAssertTrue(reveal(total, upwards: false))
        XCTAssertEqual(total.label, originalTotal)
        attach("Screen Time — local black gems and retained learning")
    }

    func testAX5ControlsAndLocalDataExplanationRemainReachable() {
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        launchAndOpenSettings()
        assertAuthorizationHasNotBeenInvented()
        attach("Screen Time AX5 — authorization and stopped recording")

        for identifier in ["screen-time.learning-apps", "screen-time.distraction-apps"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(reveal(button))
            XCTAssertGreaterThanOrEqual(button.frame.height, 43.5)
            XCTAssertFalse(button.label.isEmpty)
            XCTAssertFalse(button.isEnabled)
            attach("Screen Time AX5 — \(identifier)")
        }
        let explanation = text(containing: "JSON書き出しや保存先の切り替えでは引き継ぎません")
        XCTAssertTrue(reveal(explanation))
        XCTAssertGreaterThan(explanation.frame.height, 70,
                             "The settings must actually inherit the largest text size")
        attach("Screen Time AX5 — device-local disclosure")
        assertResetConfirmationCanBeCancelled()
    }

    /// The Simulator build carries no entitlements, so the App Group container
    /// is nil and the Screen Time ledger can never bind. That must be explained
    /// on screen, and it must never trap the user with the feature on: a save
    /// that only switches recording OFF stays available.
    func testUnavailableContextIsExplainedAndSwitchingOffStaysAvailable() {
        launchAndOpenSettings()
        let reason = app.staticTexts["screen-time.monitoring-error"]
        XCTAssertTrue(reveal(reason), "An unbound context must state a reason, not only grey 保存 out")
        XCTAssertTrue(reason.label.contains("スクリーンタイム"))
        XCTAssertTrue(reveal(text(containing: "オフにする変更はいつでも保存できます")),
                      "The footer must not promise a retry from a button the user cannot press")
        attach("Screen Time — unavailable context is explained")

        let save = app.buttons["screen-time.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 6))
        XCTAssertTrue(save.isEnabled, "Switching the feature off must never be blocked")
        save.tap()
        let alert = app.alerts["設定を完了できませんでした"]
        XCTAssertTrue(alert.waitForExistence(timeout: 6))
        attach("Screen Time — save reports the unbound context")
        alert.buttons["閉じる"].tap()
        XCTAssertTrue(app.navigationBars["スクリーンタイム"].waitForExistence(timeout: 4))
    }

    private func launchAndOpenSettings() {
        app.launch()
        let menu = app.buttons["メニュー"]
        XCTAssertTrue(menu.waitForExistence(timeout: 12))
        menu.tap()
        let settings = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "設定")).firstMatch
        XCTAssertTrue(reveal(settings))
        settings.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 8))
        let entry = app.descendants(matching: .any)["settings.screen-time"].firstMatch
        XCTAssertTrue(reveal(entry))
        entry.tap()
        XCTAssertTrue(app.navigationBars["スクリーンタイム"].waitForExistence(timeout: 6))
    }

    private func assertAuthorizationHasNotBeenInvented() {
        let status = app.staticTexts["screen-time.authorization-status"]
        XCTAssertTrue(reveal(status))
        XCTAssertTrue(status.label.contains("許可が必要"))
        let authorize = app.buttons["screen-time.authorize"]
        XCTAssertTrue(reveal(authorize))
        XCTAssertTrue(authorize.isEnabled)
        // Do not tap: Simulator UI is no proof of real-device authorization.
        let enabled = app.switches["screen-time.enabled"]
        XCTAssertTrue(reveal(enabled))
        XCTAssertFalse(enabled.isEnabled)
        XCTAssertEqual(enabled.value as? String, "0")
        XCTAssertFalse(app.staticTexts["自動記録中"].exists)
    }

    private func assertResetConfirmationCanBeCancelled() {
        let reset = app.buttons["screen-time.reset"]
        XCTAssertTrue(reveal(reset))
        XCTAssertGreaterThanOrEqual(reset.frame.height, 43.5)
        reset.tap()
        let alert = app.alerts["スクリーンタイムの内容をリセット"]
        XCTAssertTrue(alert.waitForExistence(timeout: 4))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "保存済みの勉強時間と通常gemは残ります"
        )).firstMatch.exists)
        XCTAssertTrue(alert.buttons["リセット"].exists)
        attach("Screen Time — explicit local reset confirmation")
        alert.buttons["キャンセル"].tap()
        XCTAssertFalse(alert.exists)
        XCTAssertTrue(app.navigationBars["スクリーンタイム"].exists)
    }

    private func text(containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    @discardableResult
    private func reveal(_ element: XCUIElement, upwards: Bool = true) -> Bool {
        for _ in 0..<16 {
            if element.exists {
                let top = app.navigationBars.allElementsBoundByIndex
                    .filter(\.isHittable).map(\.frame.maxY).max() ?? 0
                let bottom = app.windows.firstMatch.frame.maxY - 36
                let frame = element.frame
                if frame.height > 0 && frame.width > 0 {
                    if frame.minY >= top && frame.maxY <= bottom {
                        // Disabled controls still need to be visibly explained;
                        // the test never attempts to tap those controls.
                        return element.isHittable || !element.isEnabled
                    }
                    if frame.maxY <= top {
                        app.swipeDown(velocity: .fast)
                        continue
                    }
                    if frame.minY >= bottom {
                        app.swipeUp(velocity: .fast)
                        continue
                    }
                    if frame.height > bottom - top && element.isHittable {
                        return true
                    }
                }
                // Small corrections keep a tall AX5 row from being skipped by
                // alternating full-screen swipes near a viewport edge.
                let correction = frame.minY < top
                    ? top - frame.minY + 12 : bottom - frame.maxY - 12
                let distance = min(160, max(60, abs(correction))) * (correction < 0 ? -1 : 1)
                let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
            } else if upwards {
                app.swipeUp(velocity: .fast)
            } else {
                app.swipeDown(velocity: .fast)
            }
        }
        return element.exists && element.isHittable
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
