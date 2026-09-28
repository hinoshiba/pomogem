import XCTest

/// F1 in the product-default configuration: the leave pause is on. Every
/// other UI-test process switches it off (shared Simulators background many
/// focuses), so this is the one place its copy and notice are rendered and
/// audited at AX5. The Simulator has no passcode, so it shows the
/// no-passcode wording and pauses after 20 s away; the passcode wording and
/// the lock path are covered by the real-device table in
/// `Docs/FocusLeavePause.md`.
@MainActor
final class FocusLeavePauseUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Every running-row wording the leave pause can show (with and without a
    /// passcode; end alerts allowed, not asked yet, or denied).
    private let leavePauseRunningCopy = [
        "画面ロック中も通常は進みます。ほかのアプリに移ると一時停止します。",
        "画面を消したり、ほかのアプリに移ると一時停止します。",
        "画面ロック中も通常は進みます。終了通知を許可",
        "終了通知を許可",
        "画面ロック中も通常は進みます。終了通知は端末の設定から",
        "終了通知は端末の設定から"
    ]
    private let leavePausedNotice = "アプリを離れていたので一時停止しました"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 300

        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_FOCUS_LEAVE_PAUSE"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launchArguments += [
            "-share.prompt.\(studyDayKey())", "false"
        ]
        app.launch()

        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 10))
    }

    func testAX5LeavePauseCopyAndNoticeStayReachableAndUnclipped() throws {
        defer { app.terminate() }
        startTwentyFiveMinuteFocus()

        let pause = app.buttons["一時停止"]
        XCTAssertTrue(pause.waitForExistence(timeout: 8))
        let runningRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", leavePauseRunningCopy)
        ).firstMatch
        XCTAssertTrue(
            runningRow.waitForExistence(timeout: 8),
            "With the leave pause on, the running row must not promise the timer runs in other apps"
        )
        XCTAssertFalse(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "画面を閉じても")
            ).firstMatch.exists,
            "The feature-off promise would be false"
        )
        retainScreenshot(named: "AX5 running focus — leave pause on")
        try auditLeavePauseRows(named: "AX5 running focus — leave pause on")

        // Away longer than the 20-second lock window. No passcode on the
        // Simulator, so nothing can tell this from a lock: it pauses.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 26)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        let notice = app.descendants(matching: .any)["focus.leave-paused-notice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "The pause the person did not tap is explained")
        XCTAssertEqual(notice.label, leavePausedNotice)
        let resume = app.buttons["再開する"]
        XCTAssertTrue(resume.waitForExistence(timeout: 4))
        XCTAssertTrue(resume.isHittable, "再開 continues from the moment the person left")
        XCTAssertGreaterThanOrEqual(resume.frame.height, 43.5)
        let viewport = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(resume.frame.maxY, viewport.maxY)
        retainScreenshot(named: "AX5 focus paused after leaving the app")
        try auditLeavePauseRows(named: "AX5 focus paused after leaving the app")

        resume.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 4))
        XCTAssertFalse(notice.exists, "A resumed focus is no longer leave-paused")

        let giveUp = app.buttons["今日はここまで"]
        XCTAssertTrue(giveUp.waitForExistence(timeout: 4))
        giveUp.tap()
        let confirmation = app.alerts["今日はここまで"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 4))
        confirmation.buttons["今日はここまで"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))
    }

    // MARK: - Helpers

    private func startTwentyFiveMinuteFocus() {
        let durationPicker = app.buttons["home.duration-picker"]
        XCTAssertTrue(scrollUntilHittable(durationPicker, attempts: 12))
        durationPicker.tap()
        let twentyFive = app.buttons["25分"].firstMatch
        XCTAssertTrue(twentyFive.waitForExistence(timeout: 4))
        XCTAssertTrue(scrollUntilHittable(twentyFive))
        twentyFive.tap()
        let launcher = app.buttons["home.focus-launcher"]
        XCTAssertTrue(scrollUntilHittable(launcher, attempts: 12))
        launcher.tap()
        let rareChoice = app.descendants(matching: .any)["focus.rare-reward-choice"]
        if rareChoice.waitForExistence(timeout: 1) {
            app.buttons["rare-reward.choice.off"].tap()
            app.buttons["focus.rare-reward-choice.confirm"].tap()
        }
    }

    /// Apple's hit-region and text-clipping audits, scoped to the rows this
    /// feature adds: the running copy, the paused notice and 再開. The rest
    /// of the timer screen is owned by `AccessibilityAdversarialUITests`.
    private func auditLeavePauseRows(named name: String) throws {
        let audits: [(String, XCUIAccessibilityAuditType)] = [
            ("hit region", .hitRegion),
            ("text clipping", .textClipped)
        ]
        let watchedLabels = Set(leavePauseRunningCopy + [leavePausedNotice, "再開する"])
        for (auditName, auditType) in audits {
            try XCTContext.runActivity(named: "\(name) — \(auditName)") { _ in
                try app.performAccessibilityAudit(for: auditType) { issue in
                    guard let element = issue.element else { return false }
                    let isLeavePauseRow = watchedLabels.contains(element.label)
                        || element.identifier == "focus.leave-paused-notice"
                    // Ignore only issues outside this feature's rows.
                    return !isLeavePauseRow
                }
            }
        }
    }

    private func retainScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func scrollUntilHittable(_ element: XCUIElement, attempts: Int = 10) -> Bool {
        for _ in 0 ..< attempts {
            if element.exists, element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func studyDayKey(for date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .current
        let boundary = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: date)
            ?? calendar.startOfDay(for: date)
        let studyDay = date < boundary
            ? (calendar.date(byAdding: .day, value: -1, to: date) ?? date)
            : date
        let components = calendar.dateComponents([.year, .month, .day], from: studyDay)
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
