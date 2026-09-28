import XCTest

/// notify-03 / quality-03 / product-04. Widget taps and `pomogem://` links
/// land on the right screen from every in-app state, start a focus only where
/// Home's start button could, and never start a second session.
///
/// `openLink` hands the URL to the system, which delivers it to the running
/// app exactly as a widget tap does. (`XCUIApplication.open(_:)` would
/// relaunch the app instead and lose the state under test.) App Shortcuts put
/// the same request in the same inbox (StartFocusIntent), so these paths cover
/// them too.
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

        openLink(URL(string: "pomogem://focus/start?minutes=45")!)

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

    /// main's focus music sheet (#48) is presented by Settings. Leaving
    /// Settings for the jar takes it down too, so the focus still opens.
    func testStartLinkFromTheSettingsMusicSheetStarts() throws {
        openMenuAction(containing: "設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 6))
        let row = app.buttons["settings.focus-music"]
        for _ in 0 ..< 10 where !(row.exists && row.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(waitForHittable(row, timeout: 3))
        row.tap()
        XCTAssertTrue(app.buttons["focus-music.close"].waitForExistence(timeout: 8))

        openLink(URL(string: "pomogem://focus/start?minutes=25")!)

        let timer = focusTimerDisplay
        XCTAssertTrue(
            timer.waitForExistence(timeout: 10),
            "The music sheet and Settings close, and the focus opens"
        )
        let remaining = try timerRemainingSeconds(timer)
        XCTAssertGreaterThan(remaining, 24 * 60)
        XCTAssertFalse(app.buttons["focus-music.close"].exists)
    }

    func testHomeLinkLeavesLogForTheJarWithoutStarting() {
        openMenuAction(containing: "記録")
        XCTAssertTrue(app.navigationBars["記録"].waitForExistence(timeout: 6))

        openLink(URL(string: "pomogem://home")!)

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

        openLink(URL(string: "pomogem://focus/start?minutes=90")!)
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

        openLink(URL(string: "pomogem://focus/start?minutes=25")!)

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

        openLink(URL(string: "pomogem://focus/start")!)

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
        // The receipt is removed only when the gem lands. Leaving earlier
        // would keep it in UserDefaults for the next test's fresh in-memory
        // store, where no row matches it and Home's start button stays off.
        let launcher = app.buttons["home.focus-launcher"]
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: launcher)
        wait(for: [enabled], timeout: 10)
    }

    /// A form the person may be typing in is never closed for a request:
    /// it waits, and starts once they close the form themselves.
    func testStartLinkKeepsAnOpenManualEntryAndStartsAfterItCloses() throws {
        openMenuAction(containing: "手動で積む")
        let thirtyMinutes = app.buttons["30分、300グラム加算"]
        XCTAssertTrue(thirtyMinutes.waitForExistence(timeout: 6))
        waitForUISettle(600_000)
        thirtyMinutes.tap()
        let confirm = app.buttons["manual.confirm"]
        if !confirm.waitForExistence(timeout: 3), thirtyMinutes.exists, thirtyMinutes.isHittable {
            thirtyMinutes.tap()
        }
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "30分 is chosen, not yet saved")

        openLink(URL(string: "pomogem://focus/start?minutes=25")!)
        waitForUISettle(1_500_000)

        XCTAssertTrue(confirm.exists, "The person's choice in 手動で積む is kept")
        XCTAssertFalse(focusTimerDisplay.exists, "Nothing starts over the form")
        retain("Start link while 手動で積む is open — the form stays")

        let close = app.buttons["閉じる"].firstMatch
        XCTAssertTrue(waitForHittable(close, timeout: 4))
        close.tap()

        let timer = focusTimerDisplay
        XCTAssertTrue(
            timer.waitForExistence(timeout: 10),
            "Closing the form lets the waiting 25-minute start through"
        )
        let remaining = try timerRemainingSeconds(timer)
        XCTAssertLessThanOrEqual(remaining, 25 * 60)
        XCTAssertGreaterThan(remaining, 24 * 60)
    }

    /// A start waiting behind the fusion celebration belongs to 「続ける」.
    /// Choosing the crystal's breakdown instead drops it: the overview the
    /// person asked for stays, and no focus opens over it.
    func testStartLinkWaitingOnTheCelebrationYieldsToItsBreakdown() throws {
        executionTimeAllowance = 600
        app.terminate()
        // Ten completions cross the review threshold; keep the App Store
        // review prompt out of this test.
        app.launchArguments += ["-review.requested-version", "1.0"]
        app.launch()
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 10))
        selectDemoDuration()
        for _ in 1 ... 9 {
            completeDemoFocusAndDismissReward()
        }
        tapDemoLauncher()
        stopCompletionAlertIfPresented()
        let dismissReward = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(dismissReward.waitForExistence(timeout: 30))
        dismissReward.tap()
        // The fusion sheet's headline, by identifier: its wording is copy.
        let celebration = app.staticTexts["fusion.celebration.title"]
        XCTAssertTrue(celebration.waitForExistence(timeout: 12))

        openLink(URL(string: "pomogem://focus/start?minutes=25")!)
        waitForUISettle(1_500_000)
        XCTAssertTrue(celebration.exists, "The celebration is the person's to close")
        XCTAssertFalse(focusTimerDisplay.exists)

        app.buttons["この結晶の内訳を見る"].tap()
        let overview = app.navigationBars.matching(
            NSPredicate(format: "identifier IN %@", ["積み上がり", "まとまり粒"])
        ).firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 8), "The breakdown opens")
        waitForUISettle(2_500_000)
        XCTAssertTrue(overview.exists, "The breakdown stays open")
        XCTAssertFalse(
            focusTimerDisplay.exists,
            "The waiting start was dropped, not fired over the breakdown"
        )
        retain("Start link behind the celebration, then 内訳 — breakdown kept")
    }

    /// A break whose time is up keeps the request: its screen says so, and
    /// 「瓶へ戻る」 then starts the focus that was asked for.
    func testStartLinkOnAnEndedBreakStartsAfterReturningToTheJar() throws {
        executionTimeAllowance = 720
        app.terminate()
        // Keep the suggestion at five minutes regardless of the shared
        // simulator's previous rest cadence.
        app.launchArguments += ["-focus.rest-cadence.v2", "break-return-ui-test-reset"]
        app.launch()
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 10))
        selectDemoDuration()
        tapDemoLauncher()
        stopCompletionAlertIfPresented()
        let startBreak = app.buttons["5分休憩する"]
        XCTAssertTrue(waitForHittable(startBreak, timeout: 30))
        startBreak.tap()
        XCTAssertTrue(app.staticTexts["休憩"].waitForExistence(timeout: 12))

        // Leave until the five minutes are over, then ask from outside.
        XCUIDevice.shared.press(.home)
        sleep(310)
        openLink(URL(string: "pomogem://focus/start?minutes=25")!)

        let breakEnd = app.buttons["break.completion-alert.stop"]
        XCTAssertTrue(breakEnd.waitForExistence(timeout: 12))
        let waitingLine = app.staticTexts["break.waiting-focus-start"]
        XCTAssertTrue(waitingLine.waitForExistence(timeout: 6))
        XCTAssertEqual(waitingLine.label, "瓶へ戻ると、集中が始まります")
        XCTAssertFalse(focusTimerDisplay.exists)
        retain("Start link on an ended break — waits for 瓶へ戻る")

        XCTAssertTrue(waitForHittable(breakEnd, timeout: 3))
        breakEnd.tap()
        let timer = focusTimerDisplay
        XCTAssertTrue(
            timer.waitForExistence(timeout: 12),
            "Returning to the jar lets the waiting start through"
        )
        let remaining = try timerRemainingSeconds(timer)
        XCTAssertLessThanOrEqual(remaining, 25 * 60)
        XCTAssertGreaterThan(remaining, 24 * 60)
    }

    // MARK: - Helpers

    /// Opens a link in the running app, the way a widget tap does.
    private func openLink(_ url: URL) {
        XCUIDevice.shared.system.open(url)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 6))
    }

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

    private func tapDemoLauncher() {
        let launcher = button(containing: "12秒集中する")
        XCTAssertTrue(waitForHittable(launcher, timeout: 8))
        launcher.tap()
    }

    private func stopCompletionAlertIfPresented() {
        let stop = app.buttons["focus.completion-alert.stop"]
        if stop.waitForExistence(timeout: 30) {
            stop.tap()
        }
    }

    /// One 12-second demo focus, then 「閉じる」 on its reward card. Waits
    /// for the launcher again: the receipt is retired only when the gem lands.
    private func completeDemoFocusAndDismissReward() {
        tapDemoLauncher()
        stopCompletionAlertIfPresented()
        let dismissReward = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(dismissReward.waitForExistence(timeout: 30))
        dismissReward.tap()
        let launcher = button(containing: "12秒集中する")
        if !launcher.waitForExistence(timeout: 3) { selectDemoDuration() }
        let enabled = expectation(
            for: NSPredicate(format: "exists == true AND isEnabled == true"),
            evaluatedWith: launcher
        )
        wait(for: [enabled], timeout: 12)
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
