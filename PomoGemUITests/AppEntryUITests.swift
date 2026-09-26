import XCTest

/// notify-03 / quality-03 / product-04. Widget taps and `pomogem://` links
/// land on the right screen from every in-app state, start a focus only where
/// Home's start button could, and never start a second session.
///
/// `XCUIApplication.open(_:)` delivers the URL through the system exactly as
/// a widget tap does. App Shortcuts put the same request in the same inbox
/// (StartFocusIntent), so these paths cover them too.
@MainActor
final class AppEntryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240

        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_REDUCE_MOTION"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launch()

        let menu = app.buttons["メニュー"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        if !menu.isHittable {
            cancelPresentedFocusIfNeeded()
        }
        dismissStaleRewardIfNeeded()
        XCTAssertTrue(waitForHittable(menu, timeout: 5))
    }

    override func tearDownWithError() throws {
        cancelPresentedFocusIfNeeded()
        app.terminate()
        app = nil
    }

    func testStartLinkFromSettingsReturnsToTheJarAndStartsThatLength() throws {
        openMenuAction(containing: "設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 6))

        app.open(URL(string: "pomogem://focus/start?minutes=45")!)

        let timer = focusTimerDisplay
        XCTAssertTrue(
            timer.waitForExistence(timeout: 10),
            "A widget's 45分 must leave Settings and open that focus"
        )
        let remaining = try timerRemainingSeconds(timer)
        XCTAssertLessThanOrEqual(remaining, 45 * 60)
        XCTAssertGreaterThan(remaining, 44 * 60, "The link's length, not another one")
        retain("Start link from Settings — 45-minute focus")
    }

    func testHomeLinkLeavesLogForTheJarWithoutStarting() {
        openMenuAction(containing: "記録")
        XCTAssertTrue(app.navigationBars["記録"].waitForExistence(timeout: 6))

        app.open(URL(string: "pomogem://home")!)

        XCTAssertTrue(waitForHittable(app.buttons["home.focus-launcher"], timeout: 8))
        XCTAssertFalse(app.navigationBars["記録"].exists)
        XCTAssertFalse(focusTimerDisplay.exists, "The home link only navigates")
    }

    func testStartLinkDuringARunningFocusNeverStartsASecondSession() throws {
        app.buttons["home.duration-picker"].tap()
        let twentyFive = app.buttons["25分"]
        XCTAssertTrue(waitForHittable(twentyFive, timeout: 4))
        twentyFive.tap()
        let launcher = app.buttons["home.focus-launcher"]
        XCTAssertTrue(waitForHittable(launcher, timeout: 4))
        launcher.tap()
        let timer = focusTimerDisplay
        XCTAssertTrue(timer.waitForExistence(timeout: 8))
        let before = try timerRemainingSeconds(timer)

        app.open(URL(string: "pomogem://focus/start?minutes=90")!)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 6))
        waitForUISettle(1_500_000)

        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "focus.timer-display").count,
            1
        )
        let after = try timerRemainingSeconds(timer)
        XCTAssertLessThanOrEqual(after, before, "Still the same 25-minute session")
        XCTAssertGreaterThan(after, 20 * 60, "Not replaced by a 90-minute one")
        XCTAssertTrue(app.buttons["一時停止"].exists)
    }

    func testStartLinkClosesTheHomeMenuAndStarts() {
        app.buttons["メニュー"].tap()
        let settingsAction = button(containing: "設定")
        XCTAssertTrue(settingsAction.waitForExistence(timeout: 5), "The menu sheet is open")

        app.open(URL(string: "pomogem://focus/start?minutes=25")!)

        XCTAssertTrue(
            focusTimerDisplay.waitForExistence(timeout: 10),
            "The menu closes and the focus opens over the jar"
        )
    }

    func testStartLinkWhileTheRewardWaitsExplainsAndStartsNothing() {
        selectDemoDuration()
        let demoLauncher = button(containing: "12秒集中する")
        XCTAssertTrue(waitForHittable(demoLauncher, timeout: 6))
        demoLauncher.tap()
        let stop = app.buttons["focus.completion-alert.stop"]
        if stop.waitForExistence(timeout: 30) {
            stop.tap()
        }
        let dismissReward = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(dismissReward.waitForExistence(timeout: 30))

        app.open(URL(string: "pomogem://focus/start")!)

        let toast = app.descendants(matching: .any)["app.toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 6))
        XCTAssertTrue(
            toast.label.contains("休憩の選択を終えると、集中を始められます"),
            toast.label
        )
        retain("Start link while the reward card waits — explained, nothing started")
        XCTAssertFalse(focusTimerDisplay.exists)
        XCTAssertTrue(dismissReward.exists, "The rest choice stays the person's")
        dismissReward.tap()
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 8))
    }

    // MARK: - Helpers

    private var focusTimerDisplay: XCUIElement {
        app.descendants(matching: .any)["focus.timer-display"].firstMatch
    }

    private func timerRemainingSeconds(_ timer: XCUIElement) throws -> Int {
        let text = try XCTUnwrap(timer.value as? String)
        let expression = try NSRegularExpression(pattern: "残り([0-9]+)分([0-9]+)秒")
        let match = try XCTUnwrap(expression.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)
        ), text)
        let minutesRange = try XCTUnwrap(Range(match.range(at: 1), in: text))
        let secondsRange = try XCTUnwrap(Range(match.range(at: 2), in: text))
        return try XCTUnwrap(Int(text[minutesRange])) * 60
            + XCTUnwrap(Int(text[secondsRange]))
    }

    private func selectDemoDuration() {
        app.buttons["home.duration-picker"].tap()
        let demo = app.buttons["12秒、DEMO"]
        XCTAssertTrue(waitForHittable(demo, timeout: 4))
        waitForUISettle(400_000)
        demo.tap()
        let launcher = button(containing: "12秒集中する")
        if !waitForHittable(launcher, timeout: 3), demo.exists, demo.isHittable {
            demo.tap()
        }
        XCTAssertTrue(waitForHittable(launcher, timeout: 5))
    }

    private func openMenuAction(containing title: String) {
        let menu = app.buttons["メニュー"]
        XCTAssertTrue(waitForHittable(menu, timeout: 5))
        menu.tap()
        let action = button(containing: title)
        XCTAssertTrue(action.waitForExistence(timeout: 5), "Missing menu action: \(title)")
        for _ in 0 ..< 6 where !action.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(action.isHittable, "Unreachable menu action: \(title)")
        action.tap()
    }

    private func button(containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func dismissStaleRewardIfNeeded() {
        let dismiss = app.buttons["休憩の提案を閉じる"]
        if dismiss.waitForExistence(timeout: 1) {
            dismiss.tap()
        }
    }

    private func cancelPresentedFocusIfNeeded() {
        guard let app else { return }
        let giveUp = app.buttons["今日はここまで"].firstMatch
        guard giveUp.exists, giveUp.isHittable else { return }
        giveUp.tap()
        let confirmation = app.alerts["今日はここまで"]
        if confirmation.waitForExistence(timeout: 2) {
            confirmation.buttons["今日はここまで"].tap()
        }
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, element.isHittable { return true }
            usleep(50_000)
        } while Date() < deadline
        return element.exists && element.isHittable
    }

    private func waitForUISettle(_ microseconds: useconds_t) {
        usleep(microseconds)
    }

    private func retain(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
