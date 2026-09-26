import XCTest

/// F1's two Settings rows in the product-default configuration (the leave
/// pause on). 「集中が切れたらお知らせ」 exists only while
/// 「アプリを離れたら一時停止」 is on, and 集中に戻るお知らせ is shown only
/// while it is off, so the two notices never contradict. Every UI-test
/// process starts from its own default (`FocusLeavePreferences`), so the
/// switches flipped here never leak into another suite on the same Simulator.
@MainActor
final class FocusLeaveSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 300

        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_FOCUS_LEAVE_PAUSE"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 12))
    }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0, let app {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Leave pause Settings accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app?.terminate()
        app = nil
    }

    func testTheLeavePauseRowsSwapWithTheReturnReminderAndKeepTheirChoice() throws {
        openSettings()

        let leavePause = app.switches["settings.focus-leave-pause"]
        let nudges = app.switches["settings.focus-leave-nudges"]
        let returnReminder = app.switches["settings.focus-return-reminder"]
        let liveActivity = app.switches["settings.live-activity"]
        let behavior = element("settings.focus-leave-footer.behavior")
        let resume = element("settings.focus-leave-footer.resume")
        let nudgesFooter = element("settings.focus-leave-footer.nudges")

        // Product default: both on, the older reminder superseded.
        XCTAssertTrue(scrollUntilHittable(leavePause, attempts: 12))
        XCTAssertTrue(leavePause.label.contains("アプリを離れたら一時停止"), leavePause.label)
        XCTAssertEqual(leavePause.value as? String, "1")
        XCTAssertTrue(nudges.waitForExistence(timeout: 3))
        XCTAssertTrue(nudges.label.contains("集中が切れたらお知らせ"), nudges.label)
        XCTAssertTrue(nudges.label.contains("離れてから20分までに最大5回"), nudges.label)
        XCTAssertEqual(nudges.value as? String, "1")
        XCTAssertGreaterThan(nudges.frame.minY, leavePause.frame.minY)

        XCTAssertTrue(scrollUntilHittable(behavior, attempts: 6))
        XCTAssertTrue(behavior.label.contains("20秒以内に戻れば止まりません"), behavior.label)
        XCTAssertTrue(
            behavior.label.contains("パスコードを設定しているiPhoneでは、画面をロックしてもタイマーは進みます"),
            behavior.label
        )
        XCTAssertTrue(
            behavior.label.contains("パスコードがないiPhoneでは、ロックとアプリの切り替えを区別できないため、画面ロックでも一時停止します"),
            behavior.label
        )
        XCTAssertTrue(scrollUntilHittable(resume, attempts: 4))
        XCTAssertTrue(resume.label.contains("自動では再開しません"), resume.label)
        XCTAssertTrue(resume.label.contains("「再開する」をタップすると"), resume.label)
        XCTAssertTrue(nudgesFooter.exists)
        XCTAssertTrue(nudgesFooter.label.contains("「集中に戻るお知らせ」の代わりに"), nudgesFooter.label)

        XCTAssertTrue(scrollUntilHittable(liveActivity, attempts: 6))
        XCTAssertFalse(returnReminder.exists, "Superseded while the leave pause is on")
        XCTAssertFalse(element("settings.focus-return-permission").exists)
        let liveActivityFooter = element("settings.live-activity-footer")
        XCTAssertTrue(scrollUntilHittable(liveActivityFooter, attempts: 4))
        XCTAssertTrue(liveActivityFooter.label.contains("「アプリを離れたら一時停止」の設定に従います"),
                      liveActivityFooter.label)
        XCTAssertFalse(text(containing: "タイマーはバックグラウンドでも止まりません").exists,
                       "That promise is false while the leave pause is on")
        XCTAssertFalse(text(containing: "30秒後に一度通知し").exists)
        retainScreenshot(named: "Settings — leave pause on (product default)")
        try auditLeavePauseRows(named: "Settings — leave pause on")

        // The series off: its permission notice goes with it.
        XCTAssertTrue(scrollUntilHittable(nudges, attempts: 6, swipingDown: true))
        tapSwitch(nudges)
        XCTAssertTrue(waitForSwitch(nudges, value: "0", timeout: 4))
        XCTAssertFalse(element("settings.focus-leave-nudges-permission").exists)

        // The leave pause off: 集中に戻るお知らせ is back, exactly as before.
        XCTAssertTrue(scrollUntilHittable(leavePause, attempts: 4, swipingDown: true))
        tapSwitch(leavePause)
        XCTAssertTrue(waitForSwitch(leavePause, value: "0", timeout: 4))
        XCTAssertTrue(waitForAbsence(nudges, timeout: 3), "The series exists only with the leave pause")
        XCTAssertTrue(waitForAbsence(nudgesFooter, timeout: 3))
        XCTAssertTrue(behavior.exists, "The footer says what happens with the switch off as well")
        XCTAssertTrue(resume.exists)
        XCTAssertTrue(resume.label.contains("オフのときは、アプリを離れてもタイマーは止まりません"), resume.label)
        XCTAssertTrue(scrollUntilHittable(returnReminder, attempts: 6))
        XCTAssertEqual(returnReminder.value as? String, "0", "Its own choice is untouched")
        XCTAssertTrue(scrollUntilHittable(text(containing: "30秒後に一度通知し"), attempts: 4))
        retainScreenshot(named: "Settings — leave pause off, return reminder back")

        // Back on: the series keeps the explicit off chosen above.
        XCTAssertTrue(scrollUntilHittable(leavePause, attempts: 6, swipingDown: true))
        tapSwitch(leavePause)
        XCTAssertTrue(waitForSwitch(leavePause, value: "1", timeout: 4))
        XCTAssertTrue(nudges.waitForExistence(timeout: 3))
        XCTAssertEqual(nudges.value as? String, "0")
        XCTAssertTrue(waitForAbsence(returnReminder, timeout: 3))

        // Turning the series on needs this iPhone's permission, like every
        // notification switch. A Simulator that already declined answers at
        // once; the switch then stays off and the alert leads to Settings.
        tapSwitch(nudges)
        allowNotificationPermissionIfPresented(timeout: 5)
        let permissionError = app.alerts["通知を設定できませんでした"]
        let expectedNudges: String
        if permissionError.waitForExistence(timeout: 2) {
            XCTAssertTrue(permissionError.buttons["設定を開く"].exists)
            permissionError.buttons["閉じる"].tap()
            XCTAssertTrue(waitForSwitch(nudges, value: "0", timeout: 4),
                          "A refused ON must save nothing")
            expectedNudges = "0"
        } else {
            XCTAssertTrue(waitForSwitch(nudges, value: "1", timeout: 8))
            XCTAssertFalse(element("settings.focus-leave-nudges-permission").exists)
            expectedNudges = "1"
        }

        // Settings reads the choices back when it opens again.
        let back = app.navigationBars["設定"].buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 6))
        openSettings()
        XCTAssertTrue(scrollUntilHittable(leavePause, attempts: 12))
        XCTAssertEqual(leavePause.value as? String, "1")
        XCTAssertTrue(nudges.waitForExistence(timeout: 3))
        XCTAssertEqual(nudges.value as? String, expectedNudges)
        XCTAssertFalse(returnReminder.exists)
    }

    // MARK: - Helpers

    private func openSettings() {
        let menu = app.buttons["メニュー"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
        let settings = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "設定")).firstMatch
        XCTAssertTrue(scrollUntilHittable(settings))
        settings.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 8))
    }

    /// Apple's hit-region and text-clipping audits, scoped to the rows and
    /// footer this feature adds; the rest of Settings is owned by
    /// `SettingsPaywallUITests` and `AccessibilityAdversarialUITests`.
    private func auditLeavePauseRows(named name: String) throws {
        let identifiers: Set<String> = [
            "settings.focus-leave-pause",
            "settings.focus-leave-nudges",
            "settings.focus-leave-nudges-permission",
            "settings.focus-leave-nudges-permission.action",
            "settings.focus-leave-footer.behavior",
            "settings.focus-leave-footer.resume",
            "settings.focus-leave-footer.nudges",
            "settings.live-activity-footer"
        ]
        let audits: [(String, XCUIAccessibilityAuditType)] = [
            ("hit region", .hitRegion),
            ("text clipping", .textClipped)
        ]
        for (auditName, auditType) in audits {
            try XCTContext.runActivity(named: "\(name) — \(auditName)") { _ in
                try app.performAccessibilityAudit(for: auditType) { issue in
                    // Only issues XCTest attributes to this feature's rows
                    // fail here. The audit scrolls the whole List; on iOS 26.5
                    // it reports one clipped text without naming any element,
                    // and its screenshot shows the lower Settings cards, not
                    // these rows. The suites owning that part judge it.
                    guard let element = issue.element else { return true }
                    return !identifiers.contains(element.identifier)
                }
            }
        }
    }

    private func allowNotificationPermissionIfPresented(timeout: TimeInterval) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons.matching(NSPredicate(
            format: "label IN %@", ["許可", "Allow", "通知を許可", "Allow Notifications"]
        )).firstMatch
        if allow.waitForExistence(timeout: timeout) {
            allow.tap()
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func text(containing value: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    private func tapSwitch(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    private func waitForSwitch(_ element: XCUIElement, value: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.value as? String == value { return true }
            usleep(50_000)
        } while Date() < deadline
        return element.value as? String == value
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(250_000)
        }
        return !element.exists
    }

    private func scrollUntilHittable(
        _ element: XCUIElement,
        attempts: Int = 10,
        swipingDown: Bool = false
    ) -> Bool {
        for _ in 0 ..< attempts {
            if element.exists, element.isHittable { return true }
            if swipingDown {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        return element.exists && element.isHittable
    }

    private func retainScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
