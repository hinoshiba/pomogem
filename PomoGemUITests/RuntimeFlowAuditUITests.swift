import XCTest

/// Exercises the four free timer choices and the complete theme lifecycle.
///
/// These paths are intentionally kept separate from the fast 12-second demo:
/// a production regression can otherwise leave the real preset controls
/// or a destructive theme action unusable while every completion test passes.
@MainActor
final class RuntimeFlowAuditUITests: XCTestCase {
    private var app: XCUIApplication!
    private var needsFocusReturnReminderCleanup = false
    private let focusReturnReminderBody = "集中時間が続いています。タイマーに戻って続けましょう。"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 360

        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()

        let menu = app.buttons["メニュー"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        // A previously interrupted XCTest may have left its disposable focus
        // overlay restored above Home. Cancel only that in-memory test run.
        if !menu.isHittable {
            cancelPresentedFocusIfNeeded()
        }
        XCTAssertTrue(waitForHittable(menu, timeout: 5))
    }

    override func tearDownWithError() throws {
        // If an assertion aborts while Focus is presented, leave the shared
        // simulator process in a reversible state for the next test. The
        // in-memory data itself is never erased or uninstalled.
        if needsFocusReturnReminderCleanup {
            _ = restoreFocusReturnReminderToOff()
        }
        cancelPresentedFocusIfNeeded()
        app.terminate()
        app = nil
    }

    func testFocusReturnNotificationReopensContinuingTimerAndPausedFocusStaysQuiet() throws {
        enableFocusReturnReminderFromSettings()
        let timer = startTwentyFiveMinuteFocusForReminder()
        let initialSeconds = try timerRemainingSeconds(timer)
        let departure = Date()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let reminder = focusReturnNotification(in: springboard)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(reminder.waitForExistence(timeout: 42),
                      "An opted-in running focus must deliver its real OS reminder after 30 seconds")
        retainScreenshot(named: "Focus return — delivered SpringBoard notification")
        reminder.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8),
                      "Tapping the notification must open the app without an explicit activate call")
        XCTAssertTrue(timer.waitForExistence(timeout: 8))
        let returnedSeconds = try timerRemainingSeconds(timer)
        XCTAssertLessThanOrEqual(returnedSeconds, initialSeconds - 25)
        XCTAssertEqual(Double(initialSeconds - returnedSeconds), Date().timeIntervalSince(departure),
                       accuracy: 8,
                       "Returning must preserve the same deadline rather than restart or pause focus")
        retainScreenshot(named: "Focus return — original timer continues after notification tap")

        app.buttons["一時停止"].tap()
        XCTAssertTrue(app.buttons["再開する"].waitForExistence(timeout: 4))
        let pausedSeconds = try timerRemainingSeconds(timer)
        XCUIDevice.shared.press(.home)
        assertNoFocusReturnNotification(reminder, for: 40)
        app.activate()
        XCTAssertTrue(app.buttons["再開する"].waitForExistence(timeout: 6))
        XCTAssertEqual(try timerRemainingSeconds(timer), pausedSeconds,
                       "Backgrounding a paused focus must preserve its remaining time")
        app.buttons["再開する"].tap()
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: 4))
        XCTAssertTrue(restoreFocusReturnReminderToOff())
    }

    func testEarlyReturnThenPauseCancelsReminderBeforeItsOriginalDeadline() throws {
        enableFocusReturnReminderFromSettings()
        let timer = startTwentyFiveMinuteFocusForReminder()
        let initialSeconds = try timerRemainingSeconds(timer)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let reminder = focusReturnNotification(in: springboard)

        XCUIDevice.shared.press(.home)
        assertNoFocusReturnNotification(reminder, for: 3)
        app.activate()
        XCTAssertTrue(timer.waitForExistence(timeout: 6))
        XCTAssertLessThan(try timerRemainingSeconds(timer), initialSeconds)
        app.buttons["一時停止"].tap()
        XCTAssertTrue(app.buttons["再開する"].waitForExistence(timeout: 4))
        let pausedSeconds = try timerRemainingSeconds(timer)

        // Waiting only in the foreground would also pass when iOS suppresses
        // foreground presentation. Background the now-paused timer so a stale
        // request would really appear, without scheduling another running episode.
        XCUIDevice.shared.press(.home)
        assertNoFocusReturnNotification(reminder, for: 40)
        retainScreenshot(named: "Focus return — early return and pause leave no delayed notification")
        app.activate()
        XCTAssertTrue(app.buttons["再開する"].waitForExistence(timeout: 6))
        XCTAssertEqual(try timerRemainingSeconds(timer), pausedSeconds)
        XCTAssertTrue(restoreFocusReturnReminderToOff())
    }

    private func enableFocusReturnReminderFromSettings() {
        // Set this before the first assertion so a failed permission prompt or
        // later OS interaction still restores the device-local opt-in in tearDown.
        needsFocusReturnReminderCleanup = true
        openMenuAction(containing: "設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))
        let toggle = app.switches["settings.focus-return-reminder"]
        XCTAssertTrue(scrollUntilHittable(toggle, attempts: 20))
        XCTAssertEqual(toggle.value as? String, "0", "The return reminder must start disabled")
        tapSwitch(toggle)
        allowReminderNotificationPermissionIfPresented(timeout: 5)
        XCTAssertTrue(waitForSwitch(toggle, value: "1", timeout: 8),
                      "The reminder may turn on only after notification permission is granted")
        tapNavigationBack(from: "設定")
    }

    private func startTwentyFiveMinuteFocusForReminder() -> XCUIElement {
        app.buttons["home.duration-picker"].tap()
        app.buttons["25分"].tap()
        app.buttons["home.focus-launcher"].tap()
        let timer = app.descendants(matching: .any)["focus.timer-display"].firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: 4))
        return timer
    }

    private func allowReminderNotificationPermissionIfPresented(timeout: TimeInterval) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons.matching(NSPredicate(
            format: "label IN %@", ["許可", "Allow", "通知を許可", "Allow Notifications"]
        )).firstMatch
        if allow.waitForExistence(timeout: timeout) {
            allow.tap()
        }
    }

    private func focusReturnNotification(in springboard: XCUIApplication) -> XCUIElement {
        // iOS versions expose a banner either as a static text or a containing
        // notification element. Match its actual user-visible body in both cases.
        springboard.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", focusReturnReminderBody
        )).firstMatch
    }

    private func assertNoFocusReturnNotification(
        _ reminder: XCUIElement,
        for duration: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let unexpectedDelivery = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"), object: reminder
        )
        unexpectedDelivery.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedDelivery], timeout: duration), .completed,
                       "The OS must not deliver a focus-return reminder during this interval",
                       file: file, line: line)
    }

    @discardableResult
    private func restoreFocusReturnReminderToOff() -> Bool {
        app.activate()
        allowReminderNotificationPermissionIfPresented(timeout: 0.5)
        let permissionError = app.alerts["通知を設定できませんでした"]
        if permissionError.exists {
            permissionError.buttons["閉じる"].tap()
        }
        let cancel = app.buttons["今日はここまで"].firstMatch
        if cancel.exists {
            _ = scrollUntilHittable(cancel, attempts: 6)
        }
        cancelPresentedFocusIfNeeded()
        if !app.navigationBars["設定"].exists {
            let menu = app.buttons["メニュー"]
            guard waitForHittable(menu, timeout: 6) else { return false }
            menu.tap()
            let settings = button(containing: "設定")
            guard scrollUntilHittable(settings) else { return false }
            settings.tap()
        }
        guard app.navigationBars["設定"].waitForExistence(timeout: 5) else { return false }
        let toggle = app.switches["settings.focus-return-reminder"]
        guard scrollUntilHittable(toggle, attempts: 20) else { return false }
        if toggle.value as? String == "1" {
            tapSwitch(toggle)
        }
        guard waitForSwitch(toggle, value: "0", timeout: 5) else { return false }
        needsFocusReturnReminderCleanup = false
        let back = app.navigationBars["設定"].buttons.element(boundBy: 0)
        if back.exists, back.isHittable { back.tap() }
        return waitForHittable(app.buttons["メニュー"], timeout: 5)
    }

    func testSettingsTimerDisplayChoicesPersistAndFocusKeepsPauseAndCancel() throws {
        let presentation = app.descendants(matching: .any)["jar.presentation.probe"]
        XCTAssertTrue(presentation.waitForExistence(timeout: 5))
        let initialPresentation = presentationValue(from: presentation)
        openTimerDisplaySettings()
        for rawValue in ["ringAndTime", "filledDial", "timeOnly", "ringOnly"] {
            let option = app.buttons["timer-display.option.\(rawValue)"]
            XCTAssertTrue(scrollUntilHittable(option))
            option.tap()
            XCTAssertEqual(option.value as? String, "選択中")
        }
        let dial = app.buttons["timer-display.option.filledDial"]
        XCTAssertTrue(scrollUntilHittable(dial, swipingDown: true))
        dial.tap()
        XCTAssertEqual(dial.value as? String, "選択中")
        retainScreenshot(named: "Timer styles in Settings — four choices and selected dial")
        closeTimerDisplaySettings()

        app.buttons["home.duration-picker"].tap()
        app.buttons["25分"].tap()
        app.buttons["home.focus-launcher"].tap()
        let timer = app.descendants(matching: .any)["focus.timer-display"].firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["focus.display-mode"].exists,
                       "Timer appearance must be configurable only in Settings")
        XCTAssertFalse(app.descendants(matching: .any)["timer-display.selection"].exists)
        // Mode is intentionally absent from the spoken countdown. Retain the
        // rendered dial so its application from Settings can be reviewed.
        retainScreenshot(named: "Settings timer style — physical dial applied to Focus")
        app.buttons["一時停止"].tap()
        let resume = app.buttons["再開する"]
        XCTAssertTrue(resume.waitForExistence(timeout: 4))
        let pausedSeconds = try timerRemainingSeconds(timer)
        usleep(1_100_000)
        XCTAssertEqual(try timerRemainingSeconds(timer), pausedSeconds,
                       "The selected appearance must preserve pause behavior")
        XCTAssertFalse(app.buttons["focus.display-mode"].exists)
        resume.tap()
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: 4))
        XCTAssertLessThanOrEqual(try timerRemainingSeconds(timer), pausedSeconds)
        XCTAssertTrue(scrollUntilHittable(app.buttons["今日はここまで"]))
        cancelPresentedFocusIfNeeded()
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 6))
        XCTAssertEqual(presentationValue(from: presentation), initialPresentation)

        openTimerDisplaySettings()
        XCTAssertTrue(scrollUntilHittable(dial))
        XCTAssertEqual(dial.value as? String, "選択中",
                       "Cancelling a focus must preserve the appearance saved in Settings")
        closeTimerDisplaySettings()
    }

    func testFocusCompletionWithSettingsDisplayKeepsRewardReachable() throws {
        openTimerDisplaySettings()
        let dial = app.buttons["timer-display.option.filledDial"]
        XCTAssertTrue(scrollUntilHittable(dial))
        dial.tap()
        XCTAssertEqual(dial.value as? String, "選択中")
        closeTimerDisplaySettings()
        selectDemoDurationForVisualAudit()
        let presentation = app.descendants(matching: .any)["jar.presentation.probe"]
        let initialDrop = try completionDropSample(from: presentation)
        startDemoFocusForVisualAudit()
        XCTAssertFalse(app.buttons["focus.display-mode"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["timer-display.selection"].exists)
        retainScreenshot(named: "Settings timer style — dial during the completion demo")
        XCTAssertTrue(
            stopCompletionAlertIfPresented(in: app),
            "The saved timer appearance must keep the completion alert reachable"
        )

        let dismissBridge = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(dismissBridge.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForHittable(dismissBridge, timeout: 5))
        XCTAssertEqual(presentationCount(from: presentation), initialDrop.count,
                       "The earned pebble must wait for the Reward Bridge to close")
        retainScreenshot(named: "Settings timer style — completion reaches the Reward Bridge")
        dismissBridge.tap()
        XCTAssertTrue(waitForAbsence(dismissBridge, timeout: 5))
        _ = try waitForLandedCompletion(from: presentation, after: initialDrop, timeout: 10)
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 6))
    }

    private func openTimerDisplaySettings() {
        openMenuAction(containing: "設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))
        let settingsDisplay = app.descendants(matching: .any)["settings.timer-display-mode"].firstMatch
        XCTAssertTrue(scrollUntilHittable(settingsDisplay, attempts: 20))
        settingsDisplay.tap()
        XCTAssertTrue(app.navigationBars["タイマーの表示"].waitForExistence(timeout: 5))
    }

    private func closeTimerDisplaySettings() {
        app.navigationBars["タイマーの表示"].buttons.element(boundBy: 0).tap()
        tapNavigationBack(from: "設定")
    }

    func testCompletionDropsOnePebbleOnlyAfterRewardDismissalAndDoesNotReplay() throws {
        try verifyCompletionDropAfterRewardDismissal(reduceMotion: false)
    }

    func testReducedMotionCompletionDropsOnePebbleAfterRewardDismissalAndDoesNotReplay() throws {
        try verifyCompletionDropAfterRewardDismissal(reduceMotion: true)
    }

    func testBreakContinuationDropsOnePebbleAndOpensBreakOnce() throws {
        app.terminate()
        app.launchEnvironment["POMOGEM_UI_TEST_REDUCE_MOTION"] = "0"
        // Keep this first-completion fixture on the five-minute suggestion,
        // independent of the shared simulator's previous rest cadence.
        app.launchArguments += ["-focus.rest-cadence.v2", "reward-rest-ui-test-reset"]
        app.launch()
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 10))
        selectDemoDurationForVisualAudit()

        let probe = app.descendants(matching: .any)["jar.presentation.probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        let initial = try completionDropSample(from: probe)
        XCTAssertEqual(initial.count, 0)
        XCTAssertTrue(initial.records.isEmpty)
        startDemoFocusForVisualAudit()
        XCTAssertTrue(stopCompletionAlertIfPresented(in: app))

        let startBreak = app.buttons["5分休憩する"]
        XCTAssertTrue(waitForHittable(startBreak, timeout: 20))
        try assertCompletionPresentationUnchanged(from: probe, matching: initial, duration: 1)
        startBreak.tap()

        let breakHeading = app.staticTexts["休憩"]
        XCTAssertTrue(breakHeading.waitForExistence(timeout: 12),
                      "Acknowledging the reward for a rest must continue to the break screen")
        XCTAssertEqual(app.staticTexts.matching(identifier: "休憩").count, 1)
        XCTAssertTrue(app.staticTexts["瓶の粒は、そのまま待っています。"].exists)
        retainScreenshot(named: "Reward continuation — break after the earned pebble lands")
        let skipBreak = app.buttons["休憩をスキップ"].firstMatch
        XCTAssertTrue(waitForHittable(skipBreak, timeout: 4))
        skipBreak.tap()
        XCTAssertTrue(waitForAbsence(breakHeading, timeout: 5))
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 6))

        // The full-screen break can hide Home from accessibility. Read the
        // scene's retained landing metrics immediately after closing it.
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        let landed = try completionDropSample(from: probe)
        XCTAssertEqual(landed.count, initial.count + 1)
        XCTAssertEqual(landed.sequence, initial.sequence + 1)
        XCTAssertTrue(landed.landed, "The rest continuation must retain an already-landed reward")
        XCTAssertGreaterThan(landed.fall, 60)
        XCTAssertEqual(landed.records.split(separator: ",").count, 1)
        XCTAssertTrue(landed.records.hasSuffix(":250"), landed.records)
        try assertCompletionPresentationUnchanged(from: probe, matching: landed, duration: 1)
        XCTAssertFalse(breakHeading.exists, "Closing the break must not replay the continuation")
        XCTAssertFalse(app.buttons["休憩の提案を閉じる"].exists)
    }

    private func verifyCompletionDropAfterRewardDismissal(reduceMotion: Bool) throws {
        app.terminate()
        app.launchEnvironment["POMOGEM_UI_TEST_REDUCE_MOTION"] = reduceMotion ? "1" : "0"
        app.launch()
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 10))
        selectDemoDurationForVisualAudit()

        let probe = app.descendants(matching: .any)["jar.presentation.probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        let initial = try completionDropSample(from: probe)
        XCTAssertEqual(initial.count, 0, "The disposable preview must begin with an empty jar")
        XCTAssertTrue(initial.records.isEmpty)

        startDemoFocusForVisualAudit()
        XCTAssertTrue(stopCompletionAlertIfPresented(in: app))
        let dismiss = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForHittable(dismiss, timeout: 5))
        // Observe for a full second: a delayed Home sync must not slip the
        // already-saved reward into the scene underneath the open card.
        try assertCompletionPresentationUnchanged(from: probe, matching: initial, duration: 1)
        XCTAssertTrue(dismiss.exists)
        retainScreenshot(named: reduceMotion
            ? "Reduced Motion — reward card before first pebble"
            : "Reward card — first pebble remains outside the jar")

        dismiss.tap()
        XCTAssertTrue(waitForAbsence(dismiss, timeout: 5))
        let landed = try waitForLandedCompletion(from: probe, after: initial, timeout: 10)
        XCTAssertEqual(landed.records.split(separator: ",").count, 1)
        XCTAssertTrue(landed.records.hasSuffix(":250"), landed.records)
        XCTAssertGreaterThan(landed.fall, 60,
                             "Both motion settings must show the earned pebble fall before landing")
        retainScreenshot(named: reduceMotion
            ? "Reduced Motion — first earned pebble fall and landing"
            : "First earned pebble — observed fall and landing")

        openMenuAction(containing: "設定")
        tapNavigationBack(from: "設定")
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        try assertCompletionPresentationUnchanged(from: probe, matching: landed, duration: 1)
        XCTAssertFalse(dismiss.exists, "A landed receipt must not reopen its Reward Bridge")
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

    func testFreeTimersStartPauseResumeAndCancelWithoutCreatingEffort() throws {
        let presentationProbe = app.descendants(matching: .any)["jar.presentation.probe"]
        XCTAssertTrue(presentationProbe.waitForExistence(timeout: 5))
        let initialPresentation = presentationValue(from: presentationProbe)

        try exerciseInterruptibleFocus(
            durationButtonPrefix: "25分",
            launcherFragment: "25分集中する",
            expectedRemainingMinute: "24分",
            attachmentName: "25-minute focus — paused and reversible"
        )
        XCTAssertEqual(
            presentationValue(from: presentationProbe),
            initialPresentation,
            "Cancelling 25 minutes must not invent a study pebble"
        )

        try exerciseInterruptibleFocus(
            durationButtonPrefix: "45分",
            launcherFragment: "45分集中する",
            expectedRemainingMinute: "44分",
            attachmentName: "45-minute focus — paused and reversible"
        )
        XCTAssertEqual(
            presentationValue(from: presentationProbe),
            initialPresentation,
            "Cancelling 45 minutes must not invent a study pebble"
        )

        try exerciseInterruptibleFocus(
            durationButtonPrefix: "60分",
            launcherFragment: "60分集中する",
            expectedRemainingMinute: "59分",
            attachmentName: "60-minute focus — paused and reversible"
        )
        XCTAssertEqual(
            presentationValue(from: presentationProbe),
            initialPresentation,
            "Cancelling 60 minutes must not invent a study pebble"
        )

        try exerciseInterruptibleFocus(
            durationButtonPrefix: "90分",
            launcherFragment: "90分集中する",
            expectedRemainingMinute: "89分",
            attachmentName: "90-minute focus — paused and reversible"
        )
        XCTAssertEqual(
            presentationValue(from: presentationProbe),
            initialPresentation,
            "Cancelling 90 minutes must not invent a study pebble"
        )
    }

    func testHomeMenuKeepsEqualSpaceCardsAndDirectFocusControlsAtDefaultAndAX5() {
        for usesLargeText in [false, true] {
            app.terminate()
            app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = usesLargeText ? "1" : "0"
            app.launch()
            XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 10))

            let durationPicker = app.buttons["home.duration-picker"]
            XCTAssertTrue(scrollUntilHittable(durationPicker, attempts: 12))
            durationPicker.tap()
            let fortyFiveMinutes = app.buttons["45分"].firstMatch
            XCTAssertTrue(fortyFiveMinutes.waitForExistence(timeout: 4))
            fortyFiveMinutes.tap()

            // Theme management must remain reachable from the visible selector
            // when its duplicate entry and launcher context menu are removed.
            let themePicker = app.buttons["home.subject-picker"]
            XCTAssertTrue(scrollUntilHittable(themePicker, attempts: 12, swipingDown: true))
            themePicker.tap()
            let manageThemes = app.buttons["テーマを管理"]
            XCTAssertTrue(manageThemes.waitForExistence(timeout: 4))
            manageThemes.tap()
            XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 6))
            tapNavigationBack(from: "設定")
            let launcher = app.buttons["home.focus-launcher"]
            XCTAssertTrue(scrollUntilHittable(launcher, attempts: 12))
            XCTAssertTrue(launcher.label.contains("45分集中する"))
            XCTAssertFalse(app.buttons["一時停止"].exists)

            app.buttons["メニュー"].tap()
            XCTAssertTrue(app.navigationBars["メニュー"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["集中設定"].exists)
            XCTAssertFalse(app.buttons["45分"].exists)

            var referenceSize: CGSize?
            for rawValue in ["midnight", "aurora", "dawn", "study"] {
                let card = app.buttons["home.atmosphere.\(rawValue)"]
                XCTAssertTrue(scrollUntilHittable(card, attempts: 12))
                XCTAssertGreaterThanOrEqual(card.frame.height, 44)
                if let referenceSize {
                    XCTAssertEqual(card.frame.width, referenceSize.width, accuracy: 1,
                                   "All four space cards need the same width at this text size")
                    XCTAssertEqual(card.frame.height, referenceSize.height, accuracy: 1,
                                   "The image and subtitle must not change an individual card's height")
                } else {
                    referenceSize = card.frame.size
                }
                let originalSize = card.frame.size
                card.tap()
                XCTAssertEqual(card.frame.width, originalSize.width, accuracy: 1)
                XCTAssertEqual(card.frame.height, originalSize.height, accuracy: 1,
                               "Selecting a space must not resize its card")
            }
            retainScreenshot(named: usesLargeText ? "Home spaces — equal cards at AX5" : "Home spaces — equal cards at default text")
            app.buttons["home.menu.close"].tap()
            XCTAssertTrue(scrollUntilHittable(launcher, attempts: 12))
            XCTAssertTrue(launcher.label.contains("45分集中する"))
            XCTAssertFalse(app.buttons["一時停止"].exists,
                           "Choosing a space must preserve the prepared timer without starting it")
        }
    }

    func testVisibleHomeControlsConfigureFocusWithoutStartingIt() throws {
        let launcher = app.buttons["home.focus-launcher"]
        let themePicker = app.buttons["home.subject-picker"]
        let durationPicker = app.buttons["home.duration-picker"]
        XCTAssertTrue(waitForHittable(launcher, timeout: 6))
        XCTAssertTrue(themePicker.isHittable, "Theme selection must be visible without a long press")
        XCTAssertTrue(durationPicker.isHittable, "Duration must be visible before starting focus")
        XCTAssertLessThanOrEqual(launcher.frame.maxY, app.frame.maxY - 16)
        retainScreenshot(named: "Release Home — visible theme and duration")

        for minutes in [25, 45, 60, 90] {
            durationPicker.tap()
            let duration = app.buttons["\(minutes)分"].firstMatch
            XCTAssertTrue(duration.waitForExistence(timeout: 4))
            duration.tap()
            XCTAssertTrue(waitForHittable(launcher, timeout: 4))
            XCTAssertTrue(launcher.label.contains("\(minutes)分集中する"))
            XCTAssertFalse(app.buttons["一時停止"].exists, "Choosing a time must not start a timer")
            XCTAssertFalse(app.staticTexts["ポモジェムPro"].exists, "Every advertised free preset must stay free")
        }

        themePicker.tap()
        let manageThemes = app.buttons["テーマを管理"]
        XCTAssertTrue(manageThemes.waitForExistence(timeout: 4))
        manageThemes.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 6))
        let addTheme = app.buttons["テーマを追加"]
        XCTAssertTrue(scrollUntilHittable(addTheme))
        addTheme.tap()
        XCTAssertTrue(app.navigationBars["テーマを追加"].waitForExistence(timeout: 5))
        let themeName = "ホームから選ぶテーマ"
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 4))
        nameField.tap()
        nameField.typeText(themeName)
        app.navigationBars["テーマを追加"].buttons["保存"].tap()
        XCTAssertTrue(waitForAbsence(app.navigationBars["テーマを追加"]))
        tapNavigationBack(from: "設定")
        XCTAssertTrue(waitForHittable(launcher, timeout: 5))
        themePicker.tap()
        let theme = app.buttons[themeName]
        XCTAssertTrue(theme.waitForExistence(timeout: 4))
        theme.tap()
        XCTAssertTrue(waitForHittable(launcher, timeout: 5))
        XCTAssertTrue(launcher.label.contains(themeName))
        XCTAssertFalse(app.buttons["一時停止"].exists)

        launcher.tap()
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: 5))
        retainScreenshot(named: "Release Focus — chosen 90-minute session")
    }

    func testHomeCustomDurationCanBeDismissedWithoutLosingFreeSelection() {
        let picker = app.buttons["home.duration-picker"]
        XCTAssertTrue(waitForHittable(picker, timeout: 5))
        picker.tap()
        app.buttons["45分"].firstMatch.tap()
        XCTAssertTrue(waitForHittable(picker, timeout: 4))
        picker.tap()
        let customTime = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "自由な時間を設定")
        ).firstMatch
        XCTAssertTrue(customTime.waitForExistence(timeout: 4))
        customTime.tap()
        XCTAssertTrue(app.staticTexts["ポモジェムPro"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["1〜360分"].exists)
        app.buttons["閉じる"].tap()
        let launcher = app.buttons["home.focus-launcher"]
        XCTAssertTrue(waitForHittable(launcher, timeout: 5))
        XCTAssertTrue(launcher.label.contains("45分集中する"))
        XCTAssertFalse(app.buttons["一時停止"].exists)
    }

    func testThemeCanBeAddedEditedHiddenRestoredSelectedAndDeleted() {
        let originalName = "監査テーマ"
        let editedName = "監査テーマ改"

        openMenuAction(containing: "設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 6))

        let addTheme = app.buttons["テーマを追加"]
        XCTAssertTrue(scrollUntilHittable(addTheme), "Settings must expose theme creation")
        addTheme.tap()

        XCTAssertTrue(app.navigationBars["テーマを追加"].waitForExistence(timeout: 5))
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 4))
        nameField.tap()
        nameField.typeText(originalName)
        let color = app.buttons["色候補2、瑠璃"]
        XCTAssertTrue(scrollUntilHittable(color))
        color.tap()
        app.navigationBars["テーマを追加"].buttons["保存"].tap()
        XCTAssertTrue(waitForAbsence(app.navigationBars["テーマを追加"]))
        waitForUISettle()

        let createdRow = button(containing: originalName)
        XCTAssertTrue(waitForHittable(createdRow, timeout: 6))
        createdRow.tap()

        XCTAssertTrue(app.navigationBars["テーマを編集"].waitForExistence(timeout: 5))
        replaceText(in: app.textFields.firstMatch, with: editedName)
        dismissKeyboard(from: app.textFields.firstMatch)
        let visibility = app.switches["ホームの選択肢に表示"]
        XCTAssertTrue(scrollUntilHittable(visibility))
        XCTAssertTrue(waitForSwitch(visibility, value: "1"))
        tapSwitch(visibility)
        XCTAssertTrue(waitForSwitch(visibility, value: "0"))
        app.navigationBars["テーマを編集"].buttons["保存"].tap()
        XCTAssertTrue(waitForAbsence(app.navigationBars["テーマを編集"]))
        waitForUISettle()

        var editedRow = button(containing: editedName)
        XCTAssertTrue(editedRow.waitForExistence(timeout: 6))
        XCTAssertTrue(editedRow.label.contains("非表示"), editedRow.label)
        editedRow.tap()

        XCTAssertTrue(app.navigationBars["テーマを編集"].waitForExistence(timeout: 5))
        let restoredVisibility = app.switches["ホームの選択肢に表示"]
        XCTAssertTrue(scrollUntilHittable(restoredVisibility))
        XCTAssertTrue(waitForSwitch(restoredVisibility, value: "0"))
        tapSwitch(restoredVisibility)
        XCTAssertTrue(waitForSwitch(restoredVisibility, value: "1"))
        app.navigationBars["テーマを編集"].buttons["保存"].tap()
        XCTAssertTrue(waitForAbsence(app.navigationBars["テーマを編集"]))
        waitForUISettle()

        editedRow = button(containing: editedName)
        XCTAssertTrue(editedRow.waitForExistence(timeout: 6))
        XCTAssertFalse(editedRow.label.contains("非表示"), editedRow.label)

        tapNavigationBack(from: "設定")
        let themeMenu = app.buttons["home.subject-picker"]
        XCTAssertTrue(themeMenu.waitForExistence(timeout: 4))
        themeMenu.tap()
        let themeChoice = app.buttons[editedName]
        XCTAssertTrue(themeChoice.waitForExistence(timeout: 4))
        themeChoice.tap()

        let selectedLauncher = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", editedName)
        ).firstMatch
        XCTAssertTrue(
            selectedLauncher.waitForExistence(timeout: 5),
            "A restored theme must be selectable from Home"
        )

        openMenuAction(containing: "設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))
        // Scope to the exact Settings row. The previously selected Home
        // launcher remains in the backing navigation hierarchy and also
        // contains the theme name, but is intentionally not hittable here.
        editedRow = app.buttons[editedName]
        XCTAssertTrue(scrollUntilHittable(editedRow))
        editedRow.swipeLeft()
        let delete = app.buttons["削除"]
        XCTAssertTrue(delete.waitForExistence(timeout: 4))
        delete.tap()

        // Assert the destructive alert's visible contract and its explicit,
        // reversible cancel action before exercising deletion.
        let confirmationTitle = app.staticTexts["テーマを削除"]
        XCTAssertTrue(confirmationTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "過去の記録")
            ).firstMatch.exists,
            "Deletion must explain the history-preservation contract"
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "取り消せません")
            ).firstMatch.exists,
            "Deletion must make irreversibility explicit"
        )

        let cancel = app.buttons["キャンセル"]
        let cancelExists = cancel.exists
        let cancelIsHittable = cancelExists && cancel.isHittable
        let cancelFrame = cancelExists ? cancel.frame : .null
        let cancelProbe = XCTAttachment(
            string: "exists=\(cancelExists)\nhittable=\(cancelIsHittable)\nframe=\(String(describing: cancelFrame))"
        )
        cancelProbe.name = "Theme deletion — cancel AX probe"
        cancelProbe.lifetime = .keepAlways
        add(cancelProbe)
        XCTAssertTrue(cancelExists, "Deletion confirmation must expose an explicit cancel action")
        XCTAssertTrue(cancelIsHittable, "Deletion confirmation cancel action must be operable")
        XCTAssertFalse(cancelFrame.isEmpty, "Deletion confirmation cancel action needs a visible hit target")

        cancel.tap()
        XCTAssertTrue(waitForAbsence(confirmationTitle))
        editedRow = app.buttons[editedName]
        XCTAssertTrue(
            editedRow.waitForExistence(timeout: 3),
            "Cancelling deletion must preserve the category"
        )

        editedRow.swipeLeft()
        XCTAssertTrue(delete.waitForExistence(timeout: 4))
        delete.tap()
        XCTAssertTrue(confirmationTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["キャンセル"].isHittable)

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Theme deletion — explicit history-preservation confirmation"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["「\(editedName)」を削除"].tap()
        XCTAssertFalse(app.buttons[editedName].waitForExistence(timeout: 2))

        tapNavigationBack(from: "設定")
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", "集中する")
            ).firstMatch.waitForExistence(timeout: 5),
            "Deleting the selected theme must fall back to another usable theme"
        )
    }

    /// Captures unretouched Japanese UI candidates for product-page review.
    ///
    /// The disposable Debug fixture is only a way to reach deterministic states:
    /// restore the real duration before capturing Home or its completion card.
    /// Export the five named attachments from the xcresult so the set remains
    /// reproducible, then verify against signed Release on a physical device.
    /// Naturally scroll the storage screen to its privacy explanation so
    /// Simulator-only diagnostics are outside the captured viewport.
    func testAppStoreScreenshotSetJapaneseReleaseCandidate() {
        // Relaunch the disposable store. Release 1.0 has no rare-reward draw or
        // opt-in surface, keeping this product-page set deterministic.
        app.terminate()
        // The in-memory SwiftData fixture intentionally survives no records,
        // while UserDefaults normally retains the optional-rest cadence between
        // UI-test runs. An invalid argument-domain value makes the typed Data
        // lookup start from zero without deleting any simulator or app data.
        app.launchArguments += ["-focus.rest-cadence.v2", "screenshot-fixture-reset"]
        app.launch()
        let interruptedReward = app.buttons["休憩の提案を閉じる"]
        if interruptedReward.waitForExistence(timeout: 1) {
            interruptedReward.tap()
            XCTAssertTrue(waitForAbsence(interruptedReward, timeout: 5))
        }
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 10))

        // 1. Show the real free 25-minute timer, never the test-only duration.
        app.buttons["home.duration-picker"].tap()
        let productionDuration = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "25分")
        ).firstMatch
        XCTAssertTrue(productionDuration.waitForExistence(timeout: 4))
        productionDuration.tap()

        let productionLauncher = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "25分集中する")
        ).firstMatch
        XCTAssertTrue(waitForHittable(productionLauncher, timeout: 5))
        productionLauncher.tap()
        let rareRewardChoice = app.descendants(matching: .any)["focus.rare-reward-choice"]
        XCTAssertFalse(rareRewardChoice.waitForExistence(timeout: 1))
        let focusTimer = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "集中タイマー")
        ).firstMatch
        XCTAssertTrue(focusTimer.waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: 4))
        waitForUISettle()
        retainScreenshot(named: "ASC_02_25-minute-focus")

        app.buttons["今日はここまで"].tap()
        let giveUpConfirmation = app.alerts["今日はここまで"]
        XCTAssertTrue(giveUpConfirmation.waitForExistence(timeout: 4))
        giveUpConfirmation.buttons["今日はここまで"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))

        // 2. Create one deterministic 250g completion. The Debug-only duration
        // picker is closed before any image is retained.
        selectDemoDurationForVisualAudit()
        startDemoFocusForVisualAudit()
        stopCompletionAlertIfPresented(in: app)
        let dismissBridge = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(dismissBridge.waitForExistence(timeout: 30))
        XCTAssertTrue(
            app.descendants(matching: .any)["reward.fusion-progress"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.buttons["5分休憩する"].waitForExistence(timeout: 4),
            "The 250g screenshot fixture must match a first 25-minute completion"
        )
        // The duration is now visible behind the completion card. Restore a
        // release preset without dismissing the completed session's reward.
        let visibleDuration = app.buttons["home.duration-picker"]
        XCTAssertTrue(waitForHittable(visibleDuration, timeout: 5))
        visibleDuration.tap()
        let freeTwentyFiveMinutes = app.buttons["25分"]
        XCTAssertTrue(freeTwentyFiveMinutes.waitForExistence(timeout: 4))
        freeTwentyFiveMinutes.tap()
        XCTAssertEqual(visibleDuration.label, "集中時間、25分")
        XCTAssertTrue(dismissBridge.exists)
        waitForUISettle()
        retainScreenshot(named: "ASC_03_completion-reward")
        dismissBridge.tap()
        XCTAssertTrue(waitForAbsence(dismissBridge, timeout: 5))

        XCTAssertTrue(waitForHittable(productionLauncher, timeout: 6))
        let jar = app.buttons["瓶"]
        XCTAssertTrue(jar.waitForExistence(timeout: 5))
        XCTAssertTrue(((jar.value as? String) ?? "").contains("1粒"), String(describing: jar.value))
        // Let the ordinary landing toast disappear before retaining the image.
        waitForUISettle(4_000_000)
        retainScreenshot(named: "ASC_01_home-with-first-pebble")

        // 4. Show exact, current accumulation values from the same fixture.
        openMenuAction(containing: "積み上がりを見る")
        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 6))
        XCTAssertTrue(
            app.descendants(matching: .any)["overview.weekly-crystal"]
                .waitForExistence(timeout: 5)
        )
        waitForUISettle()
        retainScreenshot(named: "ASC_04_accumulation-overview")

        app.buttons["overview.close"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))

        // 5. Finish with the shipped privacy/storage explanation. This avoids
        // showing the shortened fixture duration in History and directly
        // documents the selected storage contract promised by the product page.
        openMenuAction(containing: "設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 6))
        let cloudStorage = app.staticTexts["iCloud"]
        let localStorage = app.staticTexts["このiPhoneのみ"]
        XCTAssertTrue(
            scrollUntilVisible(cloudStorage) || scrollUntilVisible(localStorage)
        )
        let selectedStorage: XCUIElement
        if cloudStorage.exists {
            selectedStorage = cloudStorage
            XCTAssertTrue(app.staticTexts[
                "あなたのプライベートデータベースのみ"
            ].exists)
        } else {
            selectedStorage = localStorage
            XCTAssertTrue(app.staticTexts[
                "iCloudへ送信しない端末内の専用領域"
            ].exists)
        }
        XCTAssertFalse(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", "ユーザー内容を削除")
            ).firstMatch.exists,
            "Version 1.0 must not expose the experimental cross-container deletion transaction"
        )
        // Keep the privacy explanation and the version in the viewport using
        // ordinary scrolling. SwiftUI exposes LabeledContent as one combined
        // accessibility row, rather than a standalone version-value element.
        XCTAssertTrue(selectedStorage.waitForExistence(timeout: 3))
        let version = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "バージョン")
        ).firstMatch
        XCTAssertTrue(scrollUntilVisible(version))
        waitForUISettle()
        retainScreenshot(named: "ASC_05_iCloud-and-privacy")
    }

    /// Captures the production Product.displayPrice without purchasing or
    /// restoring. Explicitly opt in and run without a StoreKit configuration file.
    func testCaptureActualStoreKitPrice() throws {
        guard ProcessInfo.processInfo.environment["POMOGEM_CAPTURE_LIVE_STOREKIT"] == "1" else {
            throw XCTSkip("Set POMOGEM_CAPTURE_LIVE_STOREKIT=1 to capture the live StoreKit product price.")
        }
        openMenuAction(containing: "設定")
        let pro = button(containing: "ポモジェムPro")
        XCTAssertTrue(scrollUntilHittable(pro))
        pro.tap()
        let purchase = app.buttons["paywall.purchase"]
        guard purchase.waitForExistence(timeout: 45) else {
            retainScreenshot(named: "IAP_live-price-unavailable")
            throw XCTSkip("The live StoreKit product was not returned; no review price is claimed.")
        }
        XCTAssertTrue(purchase.isEnabled)
        XCTAssertTrue(purchase.label.contains("でProを購入"), purchase.label)
        XCTAssertTrue(scrollUntilVisible(purchase))
        waitForUISettle()
        retainScreenshot(named: "IAP_01-pomogem-pro-live-price")
        let evidence = XCTAttachment(string: purchase.label)
        evidence.name = "IAP_live-purchase-label"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    /// Retains visual evidence around the first exact decimal carry. The
    /// screenshots make the pre-fusion rail, completed Reward Bridge, fusion
    /// celebration, and newly born lifetime core reviewable together.
    func testVisualEvolutionFromNineMeasuredParticlesThroughFirstCrystal() {
        selectDemoDurationForVisualAudit()

        let presentationProbe = app.descendants(matching: .any)["jar.presentation.probe"]
        XCTAssertTrue(presentationProbe.waitForExistence(timeout: 5))

        for expectedCount in 1 ... 8 {
            completeDemoFocusAndDismissBridgeForVisualAudit(
                expectedPresentationCount: expectedCount,
                presentationProbe: presentationProbe
            )
        }

        startDemoFocusForVisualAudit()
        stopCompletionAlertIfPresented(in: app)
        let dismissBridge = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(dismissBridge.waitForExistence(timeout: 28))
        XCTAssertTrue(
            waitForPresentationCount(8, from: presentationProbe, timeout: 5),
            "The ninth reward must remain outside the jar until its card closes; probe=\(presentationValue(from: presentationProbe))"
        )
        let ninthProgress = app.descendants(matching: .any)["reward.fusion-progress"]
        XCTAssertTrue(ninthProgress.waitForExistence(timeout: 4))
        XCTAssertTrue(ninthProgress.label.contains("×10へ 9/10"), ninthProgress.label)
        waitForUISettle()
        retainScreenshot(named: "Ninth Reward Bridge — ninth pebble awaits dismissal")

        dismissBridge.tap()
        XCTAssertTrue(
            waitForAbsence(dismissBridge, timeout: 5),
            "The ninth Reward Bridge must leave the accessibility tree before another focus starts"
        )
        XCTAssertTrue(waitForPresentationCount(9, from: presentationProbe, timeout: 10))
        XCTAssertTrue(
            waitForHittable(demoLauncherForVisualAudit, timeout: 6),
            "The demo launcher must be operable after the ninth Reward Bridge closes"
        )
        let nineJarValue = (app.buttons["瓶"].value as? String) ?? ""
        XCTAssertTrue(nineJarValue.contains("9粒"), nineJarValue)
        XCTAssertFalse(nineJarValue.contains("まとまり粒"), nineJarValue)
        waitForUISettle()
        retainScreenshot(named: "Nine measured particles — pre-fusion Home rail")

        startDemoFocusForVisualAudit()
        stopCompletionAlertIfPresented(in: app)
        XCTAssertTrue(dismissBridge.waitForExistence(timeout: 28))
        let tenthProgress = app.descendants(matching: .any)["reward.fusion-progress"]
        XCTAssertTrue(tenthProgress.waitForExistence(timeout: 4))
        XCTAssertTrue(tenthProgress.label.contains("×10完成 10/10"), tenthProgress.label)
        waitForUISettle()
        retainScreenshot(named: "Tenth Reward Bridge — exact completed orbit")

        dismissBridge.tap()
        let celebration = app.staticTexts["10粒を、ひとつに整理した"]
        XCTAssertTrue(celebration.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2.5kg"].waitForExistence(timeout: 4))
        waitForUISettle()
        retainScreenshot(named: "First decimal fusion — lossless celebration")

        let closeCelebration = app.buttons["fusion.celebration.close"]
        XCTAssertTrue(closeCelebration.waitForExistence(timeout: 4))
        closeCelebration.tap()
        XCTAssertTrue(waitForHittable(demoLauncherForVisualAudit, timeout: 8))
        let tenJarValue = (app.buttons["瓶"].value as? String) ?? ""
        XCTAssertTrue(tenJarValue.contains("まとまり粒1個"), tenJarValue)
        XCTAssertTrue(tenJarValue.contains("合計10粒分"), tenJarValue)
        waitForUISettle()
        retainScreenshot(named: "First decimal crystal — Home lifetime core")
    }

    /// Opens the bounded forty-year fixture directly at the lifetime camera so
    /// the representative star field and its exact mass can be inspected
    /// without mutating any simulator's ordinary user store.
    func testFortyYearLifetimeConstellationVisualSnapshot() {
        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_FORTY_YEAR_OVERVIEW"] = "1"
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()

        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["fixture.40y.timeline-ready"].waitForExistence(timeout: 10))
        let lenses = app.segmentedControls["overview.lens"]
        XCTAssertTrue(lenses.waitForExistence(timeout: 4))
        if !lenses.buttons["結晶"].isSelected {
            lenses.buttons["結晶"].tap()
        }

        let constellation = app.descendants(matching: .any)["overview.lifetime-constellation"]
        XCTAssertTrue(scrollUntilVisible(constellation))
        let core = app.descendants(matching: .any)["overview.constellation.core"]
        XCTAssertTrue(scrollUntilVisible(core))
        XCTAssertEqual(core.label, "時間の核")
        let coreValue = (core.value as? String) ?? ""
        XCTAssertTrue(
            coreValue.replacingOccurrences(of: ",", with: "").contains("350640粒"),
            coreValue
        )
        XCTAssertTrue(coreValue.contains("87.66t"), coreValue)
        waitForUISettle()
        retainScreenshot(named: "Forty-year lifetime constellation — exact 87.66t")
    }

    /// Guards the geometry-based core caption at the largest supported text
    /// category. The representative orbit keeps the same eight-node meaning;
    /// only the surrounding overview becomes vertically expansive.
    func testFortyYearLifetimeConstellationAtAccessibility5() {
        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_FORTY_YEAR_OVERVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()

        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["fixture.40y.timeline-ready"].waitForExistence(timeout: 10))
        let lensMenu = app.buttons["overview.lens"]
        XCTAssertTrue(scrollUntilVisible(lensMenu))
        lensMenu.tap()
        let crystal = app.buttons.matching(
            NSPredicate(
                format: "label == %@ AND identifier != %@",
                "結晶",
                "overview.lens"
            )
        ).firstMatch
        XCTAssertTrue(crystal.waitForExistence(timeout: 4))
        crystal.tap()

        let core = app.descendants(matching: .any)["overview.constellation.core"]
        XCTAssertTrue(scrollUntilVisible(core))
        XCTAssertEqual(core.label, "時間の核")
        let coreValue = (core.value as? String) ?? ""
        XCTAssertTrue(
            coreValue.replacingOccurrences(of: ",", with: "").contains("350640粒"),
            coreValue
        )
        XCTAssertTrue(coreValue.contains("87.66t"), coreValue)
        waitForUISettle()
        retainScreenshot(named: "Forty-year lifetime constellation — AX5 geometry")
    }

    private func exerciseInterruptibleFocus(
        durationButtonPrefix: String,
        launcherFragment: String,
        expectedRemainingMinute: String,
        attachmentName: String
    ) throws {
        app.buttons["home.duration-picker"].tap()
        let duration = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", durationButtonPrefix)
        ).firstMatch
        XCTAssertTrue(duration.waitForExistence(timeout: 4))
        XCTAssertTrue(scrollUntilHittable(duration))
        duration.tap()

        let launcher = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", launcherFragment)
        ).firstMatch
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertTrue(launcher.isHittable)
        launcher.tap()

        let pause = app.buttons["一時停止"]
        XCTAssertTrue(pause.waitForExistence(timeout: 8))
        let timer = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "集中タイマー")
        ).firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 4))
        XCTAssertTrue(
            ((timer.value as? String) ?? "").contains(expectedRemainingMinute),
            "Timer must expose the selected real duration: \(String(describing: timer.value))"
        )

        pause.tap()
        let resume = app.buttons["再開する"]
        XCTAssertTrue(resume.waitForExistence(timeout: 4))
        let pausedTimer = app.descendants(matching: .any).matching(
            NSPredicate(format: "value CONTAINS %@", "一時停止中")
        ).firstMatch
        XCTAssertTrue(pausedTimer.waitForExistence(timeout: 4))
        XCTAssertEqual(
            pausedTimer.label,
            "集中タイマー",
            "Pausing must preserve whether this is the focus or break timer"
        )
        XCTAssertTrue(
            waitForValue(of: pausedTimer, containing: "一時停止中"),
            "The timer value must announce its paused state"
        )
        XCTAssertTrue(app.staticTexts["一時停止"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "PAUSED")
            ).firstMatch.exists,
            "The Japanese Focus UI must not mix in an English paused state"
        )
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "label == %@", "今日はここまで")
            ).count,
            1,
            "Focus must expose one unambiguous give-up action"
        )

        // Wait past the full-screen presentation and numeric countdown
        // transitions so the retained evidence represents the steady state a
        // person sees, rather than one interpolated compositor frame.
        waitForUISettle()
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = attachmentName
        attachment.lifetime = .keepAlways
        add(attachment)

        resume.tap()
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: 4))
        let textGiveUp = app.buttons["今日はここまで"]
        XCTAssertTrue(textGiveUp.waitForExistence(timeout: 3))
        textGiveUp.tap()

        let confirmation = app.alerts["今日はここまで"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 4))
        XCTAssertTrue(confirmation.buttons["続ける"].exists)
        XCTAssertTrue(
            confirmation.staticTexts["この回の粒は積まれません。これまでの瓶はそのままです。"].exists
        )
        confirmation.buttons["今日はここまで"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))
    }

    private var demoLauncherForVisualAudit: XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "12秒集中する")
        ).firstMatch
    }

    private func selectDemoDurationForVisualAudit() {
        app.buttons["home.duration-picker"].tap()
        let demo = app.buttons["12秒、DEMO"]
        XCTAssertTrue(demo.waitForExistence(timeout: 4))
        demo.tap()
        XCTAssertTrue(waitForHittable(demoLauncherForVisualAudit, timeout: 5))
    }

    private func startDemoFocusForVisualAudit() {
        let dismissBridge = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(
            waitForAbsence(dismissBridge, timeout: 5),
            "A previous Reward Bridge must be fully absent before starting another focus"
        )
        XCTAssertTrue(
            waitForHittable(demoLauncherForVisualAudit, timeout: 6),
            "The demo launcher must be visible and operable before it is tapped"
        )
        demoLauncherForVisualAudit.tap()

        // A deliberately unselected migrated fixture may require the same
        // informed, equal-weight choice as production before its first timer.
        let choicePanel = app.descendants(matching: .any)["focus.rare-reward-choice"]
        if choicePanel.waitForExistence(timeout: 1) {
            app.buttons["rare-reward.choice.off"].tap()
            let confirm = app.buttons["focus.rare-reward-choice.confirm"]
            XCTAssertTrue(confirm.isEnabled)
            confirm.tap()
        }

        let focusTimer = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "集中タイマー")
        ).firstMatch
        XCTAssertTrue(
            focusTimer.waitForExistence(timeout: 6),
            "The launcher tap must establish a new Focus screen, not hit a transitioning Home element"
        )
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: 4))
        XCTAssertTrue(
            waitForAbsence(dismissBridge, timeout: 2),
            "The previous Reward Bridge must remain absent while the new timer is running"
        )
    }

    private func completeDemoFocusAndDismissBridgeForVisualAudit(
        expectedPresentationCount: Int,
        presentationProbe: XCUIElement
    ) {
        startDemoFocusForVisualAudit()
        stopCompletionAlertIfPresented(in: app)
        let dismiss = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 28))
        XCTAssertTrue(
            waitForPresentationCount(
                expectedPresentationCount - 1,
                from: presentationProbe,
                timeout: 5
            ),
            "Completion \(expectedPresentationCount) must wait for its card to close; probe=\(presentationValue(from: presentationProbe))"
        )
        dismiss.tap()
        XCTAssertTrue(
            waitForAbsence(dismiss, timeout: 5),
            "Reward Bridge \(expectedPresentationCount) must disappear before the next iteration"
        )
        XCTAssertTrue(
            waitForPresentationCount(expectedPresentationCount, from: presentationProbe, timeout: 10),
            "Closing Reward Bridge \(expectedPresentationCount) must add exactly one live particle"
        )
        XCTAssertTrue(
            waitForHittable(demoLauncherForVisualAudit, timeout: 6),
            "The launcher must become operable after Reward Bridge \(expectedPresentationCount) closes"
        )
    }

    @discardableResult
    private func stopCompletionAlertIfPresented(
        in app: XCUIApplication,
        timeout: TimeInterval = 25
    ) -> Bool {
        let stop = app.buttons["focus.completion-alert.stop"]
        guard stop.waitForExistence(timeout: timeout) else { return false }
        XCTAssertEqual(stop.label, "終了アラートを止める")
        XCTAssertTrue(stop.isHittable)
        stop.tap()
        return true
    }

    private func retainScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openMenuAction(containing title: String) {
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
        app.buttons["メニュー"].tap()
        let action = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", title)
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(action), "Missing menu action: \(title)")
        action.tap()
    }

    private func button(containing text: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", text)
        ).firstMatch
    }

    private func presentationValue(from probe: XCUIElement) -> String {
        (probe.value as? String) ?? probe.label
    }

    private func waitForPresentationCount(
        _ expectedCount: Int,
        from probe: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if presentationCount(from: probe) == expectedCount { return true }
            usleep(50_000)
        } while Date() < deadline
        return presentationCount(from: probe) == expectedCount
    }

    private func presentationCount(from probe: XCUIElement) -> Int? {
        let rawValue = presentationValue(from: probe)
        for field in rawValue.split(separator: ";") {
            let pieces = field.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            if pieces.count == 2, pieces[0] == "count" {
                return Int(pieces[1])
            }
        }
        return nil
    }

    private struct CompletionDropSample: Equatable {
        let count: Int
        let records: String
        let sequence: Int
        let fall: Double
        let landed: Bool
    }

    private func completionDropSample(from probe: XCUIElement) throws -> CompletionDropSample {
        let raw = presentationValue(from: probe)
        let fields = Dictionary(uniqueKeysWithValues: raw.split(separator: ";").compactMap {
            field -> (String, String)? in
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        })
        let count = try XCTUnwrap(fields["count"].flatMap(Int.init), raw)
        let records = try XCTUnwrap(fields["records"], raw)
        let sequence = try XCTUnwrap(fields["dropSequence"].flatMap(Int.init), raw)
        let fall = try XCTUnwrap(fields["dropFall"].flatMap(Double.init), raw)
        let landed = try XCTUnwrap(fields["dropLanded"].flatMap(Int.init), raw)
        XCTAssertTrue(fall.isFinite && fall >= 0, raw)
        XCTAssertTrue(landed == 0 || landed == 1, raw)
        return CompletionDropSample(
            count: count, records: records, sequence: sequence, fall: fall, landed: landed == 1
        )
    }

    private func assertCompletionPresentationUnchanged(
        from probe: XCUIElement,
        matching expected: CompletionDropSample,
        duration: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            XCTAssertEqual(try completionDropSample(from: probe), expected,
                           "The physical reward and its drop must not change", file: file, line: line)
            usleep(50_000)
        } while Date() < deadline
    }

    private func waitForLandedCompletion(
        from probe: XCUIElement,
        after initial: CompletionDropSample,
        timeout: TimeInterval
    ) throws -> CompletionDropSample {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = try completionDropSample(from: probe)
        repeat {
            latest = try completionDropSample(from: probe)
            if latest.count == initial.count + 1,
               latest.sequence == initial.sequence + 1,
               latest.landed { return latest }
            usleep(50_000)
        } while Date() < deadline
        XCTFail("Expected one new landed reward after dismissal; probe=\(presentationValue(from: probe))")
        return latest
    }

    private func replaceText(in field: XCUIElement, with replacement: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        field.typeText(replacement)
    }

    private func dismissKeyboard(from field: XCUIElement) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        field.typeText(XCUIKeyboardKey.return.rawValue)
        XCTAssertTrue(
            waitForAbsence(keyboard, timeout: 3),
            "The subject-name keyboard must dismiss before operating the visibility switch"
        )
    }

    private func tapSwitch(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    private func waitForSwitch(
        _ element: XCUIElement,
        value: String,
        timeout: TimeInterval = 3
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.value as? String == value { return true }
            usleep(50_000)
        } while Date() < deadline
        return element.value as? String == value
    }

    private func waitForValue(
        of element: XCUIElement,
        containing fragment: String,
        timeout: TimeInterval = 3
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if ((element.value as? String) ?? "").contains(fragment) { return true }
            usleep(50_000)
        } while Date() < deadline
        return ((element.value as? String) ?? "").contains(fragment)
    }

    private func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, element.isHittable { return true }
            usleep(50_000)
        } while Date() < deadline
        return element.exists && element.isHittable
    }

    private func waitForAbsence(
        _ element: XCUIElement,
        timeout: TimeInterval = 4
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !element.exists { return true }
            usleep(50_000)
        } while Date() < deadline
        return !element.exists
    }

    private func waitForUISettle(_ seconds: useconds_t = 800_000) {
        usleep(seconds)
    }

    private func scrollUntilVisible(
        _ element: XCUIElement,
        attempts: Int = 14
    ) -> Bool {
        for _ in 0 ..< attempts {
            if element.exists,
               !element.frame.isEmpty,
               app.windows.firstMatch.frame.insetBy(dx: 0, dy: 44).intersects(element.frame) {
                return true
            }
            app.swipeUp()
        }
        return element.exists
            && !element.frame.isEmpty
            && app.windows.firstMatch.frame.insetBy(dx: 0, dy: 44).intersects(element.frame)
    }

    private func cancelPresentedFocusIfNeeded() {
        let giveUp = app.buttons["今日はここまで"].firstMatch
        guard giveUp.exists, giveUp.isHittable else { return }
        giveUp.tap()
        let confirmation = app.alerts["今日はここまで"]
        if confirmation.waitForExistence(timeout: 2) {
            confirmation.buttons["今日はここまで"].tap()
        }
    }

    private func tapNavigationBack(from title: String) {
        let navigationBar = app.navigationBars[title]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 4))
        let back = navigationBar.buttons.element(boundBy: 0)
        XCTAssertTrue(back.exists)
        back.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
    }

    @discardableResult
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
}
