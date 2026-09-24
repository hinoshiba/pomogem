import UIKit
import XCTest

/// Exercises native timer scene rotation, including manual rotation while
/// locked and the upside-down content fallback on unsupported iPhones.
@MainActor
final class TimerOrientationUITests: XCTestCase {
    private var app: XCUIApplication!
    private var needsDefaultOrientationCleanup = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchArguments += [
            "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP",
            "-focus.rest-cadence.v2", "timer-orientation-ui-test-reset",
            "-timer.default-orientation", "automatic"
        ]
    }

    override func tearDownWithError() throws {
        defer {
            app?.terminate()
            app = nil
        }
        XCUIDevice.shared.orientation = .portrait
        if app?.state == .runningForeground {
            dismissPresentedTimerIfNeeded()
        }
        if needsDefaultOrientationCleanup {
            if app.state != .runningForeground { app.launch() }
            dismissPresentedTimerIfNeeded()
            openDefaultOrientationSettings()
            selectDefaultOrientation("automatic", towardStart: true)
            closeDefaultOrientationSettings()
        }
    }

    func testSettingsDefaultOrientationChoicesPersistAndEachNewFocusUsesSavedDirection() throws {
        useStoredDefaultOrientation()
        launch()
        openDefaultOrientationSettings()

        let choices = ["automatic", "up", "right", "down", "left"]
        for choice in choices {
            selectDefaultOrientation(choice, towardStart: choice == "automatic")
            for other in choices {
                let option = app.buttons["timer-default-orientation.option.\(other)"]
                XCTAssertEqual(option.value as? String, other == choice ? "選択中" : "未選択",
                               "Exactly one default orientation must be selected")
            }
        }
        selectDefaultOrientation("right", towardStart: true)
        retainScreenshot(named: "timer-default-orientation-settings")
        closeDefaultOrientationSettings()

        app.terminate()
        app.launch()
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 10))
        openDefaultOrientationSettings()
        XCTAssertEqual(app.buttons["timer-default-orientation.option.right"].value as? String, "選択中",
                       "The device-local default must survive an app restart")
        closeDefaultOrientationSettings()

        let timer = startFocus(duration: "25分")
        assertDirection("右")
        XCUIDevice.shared.orientation = .landscapeRight
        assertDirection("右")
        XCUIDevice.shared.orientation = .portrait
        let initialSeconds = try remainingSeconds(timer)
        let started = Date()
        rotate(to: "下")
        try assertCountdownContinued(timer, from: initialSeconds, since: started)
        cancelFocusAndVerifyHome()

        openDefaultOrientationSettings()
        XCTAssertEqual(app.buttons["timer-default-orientation.option.right"].value as? String, "選択中",
                       "An in-timer manual rotation must not overwrite the saved default")
        closeDefaultOrientationSettings()
        _ = startFocus(duration: "25分")
        assertDirection("右")
        cancelFocusAndVerifyHome()
    }

    func testNewBreakUsesSavedDefaultAfterFocusChangesItsOwnDirection() throws {
        useStoredDefaultOrientation()
        launch(rotationLocked: true)
        openDefaultOrientationSettings()
        selectDefaultOrientation("right")
        closeDefaultOrientationSettings()

        let timer = startFiveMinuteBreak(expectedDirection: "右", focusManualDirection: "下")
        assertAccessibleRotationControl()
        let initialSeconds = try remainingSeconds(timer)
        let started = Date()
        rotate(to: "下")
        try assertCountdownContinued(timer, from: initialSeconds, since: started)
        skipBreakAndVerifyHome()
        openDefaultOrientationSettings()
        XCTAssertEqual(app.buttons["timer-default-orientation.option.right"].value as? String, "選択中",
                       "The break's manual direction must also stay separate from the saved default")
        closeDefaultOrientationSettings()
    }

    func testAX5DefaultOrientationSettingsChoicesRemainReachable() throws {
        useStoredDefaultOrientation()
        launch(rotationLocked: true, accessibilitySize: true)
        openDefaultOrientationSettings()

        for choice in ["automatic", "up", "right", "down", "left"] {
            selectDefaultOrientation(choice, towardStart: choice == "automatic")
            let option = app.buttons["timer-default-orientation.option.\(choice)"]
            XCTAssertGreaterThanOrEqual(option.frame.height, 43.5)
            XCTAssertFalse(option.label.isEmpty)
        }
        selectDefaultOrientation("down", towardStart: true)
        retainScreenshot(named: "timer-default-orientation-settings-ax5")
        closeDefaultOrientationSettings()
        _ = startFocus(duration: "25分")
        assertDirection("下")
        assertAccessibleRotationControl()
        cancelFocusAndVerifyHome()
    }

    func testLockedRotationManualCycleKeepsRunningDeadlineAndCapturesFourLayouts() throws {
        launch(rotationLocked: true)
        let timer = startFocus(duration: "25分")
        assertDirection("上")

        // This Debug-only fixture represents the same absence of automatic
        // orientation updates as a device whose rotation is locked.
        XCUIDevice.shared.orientation = .landscapeLeft
        assertDirection("上")
        XCUIDevice.shared.orientation = .portrait

        let initialSeconds = try remainingSeconds(timer)
        let started = Date()
        let layouts = [("上", "up"), ("右", "right"), ("下", "down"), ("左", "left")]
        for (index, layout) in layouts.enumerated() {
            if index > 0 { rotate(to: layout.0) }
            XCTAssertTrue(waitForHittable(app.buttons["一時停止"]))
            XCTAssertTrue(timer.exists)
            XCTAssertFalse(app.buttons["再開する"].exists)
            retainScreenshot(named: "timer-\(layout.1)")
        }
        rotate(to: "上")
        try assertCountdownContinued(timer, from: initialSeconds, since: started)
        cancelFocusAndVerifyHome()
    }

    func testPausedManualCycleAndReturnToAutomaticPreserveRemainingTime() throws {
        launch()
        let timer = startFocus(duration: "25分")
        app.buttons["一時停止"].tap()
        XCTAssertTrue(app.buttons["再開する"].waitForExistence(timeout: 4))
        let pausedSeconds = try remainingSeconds(timer)

        for direction in ["右", "下", "左", "上"] {
            rotate(to: direction)
            XCTAssertTrue(waitForHittable(app.buttons["再開する"]))
            XCTAssertEqual(try remainingSeconds(timer), pausedSeconds,
                           "Rotating a paused timer must not resume or restart it")
        }

        // Manual selection must hold its direction when the device moves;
        // returning to automatic must immediately use the current direction.
        XCUIDevice.shared.orientation = .landscapeLeft
        assertDirection("上")
        let automatic = app.buttons["timer.rotation.automatic"]
        XCTAssertTrue(waitForHittable(automatic))
        automatic.tap()
        assertDirection("右")
        XCTAssertFalse(automatic.exists)
        XCTAssertEqual(try remainingSeconds(timer), pausedSeconds)

        app.buttons["再開する"].tap()
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: 4))
        let resumed = Date()
        XCUIDevice.shared.orientation = .portrait
        assertDirection("上")
        try assertCountdownContinued(timer, from: pausedSeconds, since: resumed)
        cancelFocusAndVerifyHome()
    }

    func testAutomaticDeviceRotationSupportsAllDirectionsAndReturnsToPortraitHome() throws {
        launch()
        let timer = startFocus(duration: "25分")
        let initialSeconds = try remainingSeconds(timer)
        let started = Date()
        let directions: [(UIDeviceOrientation, String)] = [
            (.portrait, "上"),
            (.landscapeLeft, "右"),
            // Opposite landscapes have identical bounds and safe-area sizes.
            (.landscapeRight, "左"),
            (.portraitUpsideDown, "下"),
            (.landscapeRight, "左")
        ]

        for (orientation, direction) in directions {
            XCUIDevice.shared.orientation = orientation
            assertDirection(direction)
            XCTAssertTrue(waitForHittable(app.buttons["一時停止"]))
            XCTAssertFalse(app.buttons["timer.rotation.automatic"].exists,
                           "Following the device must not enter manual mode")
        }
        try assertCountdownContinued(timer, from: initialSeconds, since: started)
        cancelFocusAndVerifyHome()
    }

    func testPausedManualLandscapeSurvivesBackgroundAndResume() throws {
        launch()
        let timer = startFocus(duration: "25分")
        app.buttons["一時停止"].tap()
        XCTAssertTrue(waitForHittable(app.buttons["再開する"]))
        let pausedSeconds = try remainingSeconds(timer)
        rotate(to: "右")

        XCUIDevice.shared.press(.home)
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 8), .completed)
        // The physical device now points the other way. Returning to the app
        // must restore its manual scene choice and retain the paused timer.
        XCUIDevice.shared.orientation = .landscapeRight
        app.activate()

        assertDirection("右")
        XCTAssertTrue(waitForHittable(app.buttons["再開する"], timeout: 8))
        XCTAssertFalse(app.buttons["一時停止"].exists)
        XCTAssertTrue(app.buttons["timer.rotation.automatic"].exists,
                      "Backgrounding must preserve the timer's manual selection")
        XCTAssertEqual(try remainingSeconds(timer), pausedSeconds,
                       "Restoring the native scene must not resume or restart the timer")
        cancelFocusAndVerifyHome()
    }

    func testBreakManualCycleKeepsDeadlineAndCapturesFourLayouts() throws {
        launch(rotationLocked: true)
        let timer = startFiveMinuteBreak()
        let initialSeconds = try remainingSeconds(timer)
        let started = Date()
        let layouts = [("上", "up"), ("右", "right"), ("下", "down"), ("左", "left")]

        for (index, layout) in layouts.enumerated() {
            if index > 0 { rotate(to: layout.0) }
            assertAccessibleRotationControl()
            XCTAssertTrue(timer.exists)
            XCTAssertTrue(waitForHittable(app.buttons["休憩をスキップ"].firstMatch))
            retainScreenshot(named: "break-\(layout.1)")
        }
        try assertCountdownContinued(timer, from: initialSeconds, since: started)
        // Leave the break while its scene is still landscape so Home's
        // portrait restoration cannot pass merely because the timer was upright.
        skipBreakAndVerifyHome()
    }

    func testAX5ReducedMotionManualControlsAndBreakRemainUsableInEveryDirection() throws {
        launch(rotationLocked: true, accessibilitySize: true)
        _ = startFocus(duration: "25分")
        for direction in ["右", "下", "左", "上"] {
            rotate(to: direction)
            assertAccessibleRotationControl()
        }
        XCTAssertTrue(reveal(app.buttons["一時停止"], towardStart: false))
        app.buttons["一時停止"].tap()
        XCTAssertTrue(app.buttons["再開する"].waitForExistence(timeout: 4))
        cancelFocusAndVerifyHome()

        // Enter the real break flow at the ordinary text size, then recover
        // that same running break at AX5. This keeps the timer audit independent
        // of Home's separate scrollable reward inset on short screens.
        app.terminate()
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "0"
        app.launch()
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 10))
        let breakTimer = startFiveMinuteBreak()
        let beforeRecovery = try remainingSeconds(breakTimer)
        let recoveryStarted = Date()
        app.terminate()
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["休憩"].waitForExistence(timeout: 12))
        assertDirection("上")
        let initialSeconds = try remainingSeconds(breakTimer)
        XCTAssertEqual(
            Double(beforeRecovery - initialSeconds), Date().timeIntervalSince(recoveryStarted),
            accuracy: 4,
            "Recovering at AX5 must retain the same running break deadline"
        )
        let started = Date()

        for direction in ["右", "下", "左", "上"] {
            rotate(to: direction)
            assertAccessibleRotationControl()
        }
        try assertCountdownContinued(breakTimer, from: initialSeconds, since: started)
        retainScreenshot(named: "timer-break-ax5-reduced-motion")
        skipBreakAndVerifyHome()
    }

    func testCompletionKeepsTheTimerOrientationUntilTheCoverCloses() throws {
        launch(rotationLocked: true)
        for direction in ["右", "下"] {
            _ = startFocus(duration: "12秒、DEMO")
            // Freeze the 12-second fixture while the scene rotates.
            app.buttons["一時停止"].tap()
            XCTAssertTrue(waitForHittable(app.buttons["再開する"]))
            rotate(to: "右")
            if direction == "下" { rotate(to: "下") }
            app.buttons["再開する"].tap()

            let stop = app.buttons["focus.completion-alert.stop"]
            XCTAssertTrue(stop.waitForExistence(timeout: 25))
            // Give a regressed release time to snap the scene back.
            usleep(1_500_000)
            let window = app.windows.firstMatch.frame
            if direction == "右" {
                assertWindowOrientation(isLandscape: true)
                XCTAssertEqual(sceneInterfaceOrientation, .landscapeRight,
                               "The completion screen must keep the timer's scene")
            } else {
                assertWindowOrientation(isLandscape: false)
                // On Face ID iPhones 下 is a portrait scene plus a 180° content
                // turn: the pinned Stop must stay at the phone's physical top.
                if sceneInterfaceOrientation == .portrait {
                    XCTAssertLessThan(stop.frame.midY, window.midY,
                                      "The upside-down timer must stay upside down at completion")
                }
            }
            XCTAssertTrue(waitForHittable(stop))
            XCTAssertTrue(window.contains(stop.frame), "Stop must fit the timer's scene")
            retainScreenshot(named: "timer-completion-\(direction == "右" ? "right" : "down")")
            stop.tap()
            let reward = app.buttons["reward.dismiss"]
            XCTAssertTrue(reward.waitForExistence(timeout: 20))
            assertWindowOrientation(isLandscape: false)
            XCTAssertTrue(reveal(reward, towardStart: false))
            reward.tap()
            XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 8))
        }
    }

    private func startFiveMinuteBreak(
        expectedDirection: String = "上",
        focusManualDirection: String? = nil
    ) -> XCUIElement {
        _ = startFocus(duration: "12秒、DEMO")
        if focusManualDirection != nil {
            // Native scene checks take time. Freeze the 12-second fixture so
            // its completion cannot remove the timer during a direction check.
            app.buttons["一時停止"].tap()
            XCTAssertTrue(waitForHittable(app.buttons["再開する"]))
        }
        assertDirection(expectedDirection)
        if let focusManualDirection {
            rotate(to: focusManualDirection)
            app.buttons["再開する"].tap()
        }
        let stop = app.buttons["focus.completion-alert.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 25))
        XCTAssertTrue(reveal(stop, towardStart: false))
        stop.tap()
        let startBreak = app.buttons["5分休憩する"]
        XCTAssertTrue(startBreak.waitForExistence(timeout: 20))
        XCTAssertTrue(reveal(startBreak, towardStart: false))
        startBreak.tap()
        XCTAssertTrue(app.staticTexts["休憩"].waitForExistence(timeout: 12))
        assertDirection(expectedDirection)
        let timer = app.staticTexts.matching(NSPredicate(
            format: "label MATCHES %@", "残り[0-9]+分[0-9]+秒"
        )).firstMatch
        XCTAssertTrue(timer.exists)
        return timer
    }

    private func skipBreakAndVerifyHome() {
        let skipBreak = app.buttons["休憩をスキップ"].firstMatch
        XCTAssertTrue(reveal(skipBreak, towardStart: false))
        skipBreak.tap()
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 8))
        XCTAssertFalse(app.buttons["timer.rotate"].exists)
        assertWindowOrientation(isLandscape: false)
    }

    private func useStoredDefaultOrientation() {
        // NSArgumentDomain intentionally isolates the older rotation tests.
        // Settings persistence needs the real writable UserDefaults domain.
        if let index = app.launchArguments.firstIndex(of: "-timer.default-orientation") {
            app.launchArguments.removeSubrange(index ... index + 1)
        }
        needsDefaultOrientationCleanup = true
    }

    private func openDefaultOrientationSettings() {
        if app.navigationBars["タイマーの既定の向き"].exists { return }
        if !app.navigationBars["設定"].exists {
            let menu = app.buttons["メニュー"]
            XCTAssertTrue(waitForHittable(menu))
            menu.tap()
            let settings = app.buttons.matching(NSPredicate(
                format: "label CONTAINS %@", "設定"
            )).firstMatch
            XCTAssertTrue(reveal(settings, towardStart: false))
            settings.tap()
        }
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))
        let row = app.descendants(matching: .any)["settings.timer-default-orientation"].firstMatch
        XCTAssertTrue(reveal(row, towardStart: false, attempts: 20))
        row.tap()
        XCTAssertTrue(app.navigationBars["タイマーの既定の向き"].waitForExistence(timeout: 5))
    }

    private func selectDefaultOrientation(_ value: String, towardStart: Bool = false) {
        let option = app.buttons["timer-default-orientation.option.\(value)"]
        XCTAssertTrue(reveal(option, towardStart: towardStart))
        // AX5 rows can remain hittable after scrolling even when their center
        // is covered by the navigation bar. Bring the whole row into content
        // before tapping, as in the existing accessibility settings audit.
        let windowFrame = app.windows.firstMatch.frame
        let contentTop = app.navigationBars["タイマーの既定の向き"].frame.maxY
        for _ in 0 ..< 6 {
            let frame = option.frame
            if frame.minY >= contentTop, frame.maxY <= windowFrame.maxY { break }
            let contentMovesUp = frame.maxY > windowFrame.maxY
            let startY = contentMovesUp ? 0.72 : 0.38
            let endY = contentMovesUp ? 0.50 : 0.60
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
                .press(
                    forDuration: 0.05,
                    thenDragTo: app.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: endY)
                    )
                )
        }
        XCTAssertGreaterThanOrEqual(option.frame.minY, contentTop)
        XCTAssertLessThanOrEqual(option.frame.maxY, windowFrame.maxY)
        XCTAssertTrue(waitForHittable(option))
        option.tap()
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value == %@", "選択中"),
            object: option
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 4), .completed,
                       "Tapping the visible option must save and select \(value)")
    }

    private func closeDefaultOrientationSettings() {
        app.navigationBars["タイマーの既定の向き"].buttons.element(boundBy: 0).tap()
        let settings = app.navigationBars["設定"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"]))
    }

    private func launch(rotationLocked: Bool = false, accessibilitySize: Bool = false) {
        app.launchEnvironment["POMOGEM_UI_TEST_ORIENTATION_LOCKED"] = rotationLocked ? "1" : "0"
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = accessibilitySize ? "1" : "0"
        app.launchEnvironment["POMOGEM_UI_TEST_REDUCE_MOTION"] = accessibilitySize ? "1" : "0"
        app.launch()
        let menu = app.buttons["メニュー"]
        // A recovered timer or completion may hide Home from accessibility.
        // Wait for launch readiness without failing before that reversible
        // presentation has had a chance to be dismissed.
        _ = menu.waitForExistence(timeout: 10)
        // A reward inset can leave the menu hittable while blocking the next
        // duration picker, so also clean it up when Home's toolbar is visible.
        dismissPresentedTimerIfNeeded()
        XCTAssertTrue(waitForHittable(menu, timeout: 8))
        assertWindowOrientation(isLandscape: false)
    }

    @discardableResult
    private func startFocus(duration: String) -> XCUIElement {
        let picker = app.buttons["home.duration-picker"]
        XCTAssertTrue(reveal(picker, towardStart: false))
        picker.tap()
        let choice = app.buttons[duration]
        XCTAssertTrue(choice.waitForExistence(timeout: 4))
        choice.tap()
        let launcher = app.buttons["home.focus-launcher"]
        XCTAssertTrue(reveal(launcher, towardStart: false))
        launcher.tap()
        let rewardChoice = app.descendants(matching: .any)["focus.rare-reward-choice"]
        if rewardChoice.waitForExistence(timeout: 1) {
            app.buttons["rare-reward.choice.off"].tap()
            app.buttons["focus.rare-reward-choice.confirm"].tap()
        }
        let timer = app.descendants(matching: .any)["focus.timer-display"].firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["timer.rotate"].waitForExistence(timeout: 4))
        return timer
    }

    private func rotate(to direction: String) {
        let rotate = app.buttons["timer.rotate"]
        XCTAssertTrue(reveal(rotate, towardStart: true))
        rotate.tap()
        assertDirection(direction)
    }

    private func assertDirection(_ direction: String) {
        let rotate = app.buttons["timer.rotate"]
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value == %@", direction),
            object: rotate
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 6), .completed,
                       "Expected timer orientation \(direction), got \(String(describing: rotate.value))")
        let isLandscape = direction == "右" || direction == "左"
        assertWindowOrientation(isLandscape: isLandscape)
        let nativeScene = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            guard let native = sceneInterfaceOrientation else { return false }
            if direction == "右" { return native == .landscapeRight }
            if direction == "左" { return native == .landscapeLeft }
            if direction == "下" { return native == .portraitUpsideDown || native == .portrait }
            return native == .portrait
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [nativeScene], timeout: 6), .completed,
                       "The timer must rotate UIWindowScene, including the system gesture edges")
    }

    private var sceneInterfaceOrientation: UIInterfaceOrientation? {
        let marker = app.staticTexts["timer.interface-orientation"]
        guard marker.exists, let rawValue = Int(marker.label) else { return nil }
        return UIInterfaceOrientation(rawValue: rawValue)
    }

    private func assertWindowOrientation(isLandscape: Bool) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            let frame = app.windows.firstMatch.frame
            guard frame.width > 0, frame.height > 0 else { return false }
            return isLandscape ? frame.width > frame.height : frame.height > frame.width
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 8), .completed,
                       "Expected a native \(isLandscape ? "landscape" : "portrait") window, got \(app.windows.firstMatch.frame)")
    }

    private func assertAccessibleRotationControl() {
        let rotate = app.buttons["timer.rotate"]
        XCTAssertTrue(waitForHittable(rotate))
        XCTAssertFalse(rotate.label.isEmpty)
        XCTAssertGreaterThanOrEqual(rotate.frame.width, 43.5)
        XCTAssertGreaterThanOrEqual(rotate.frame.height, 43.5)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(rotate.frame),
                      "The quiet rotation control must stay inside the viewport")
    }

    private func remainingSeconds(_ timer: XCUIElement) throws -> Int {
        // Focus exposes its countdown as a value, while Break's static text
        // uses a label and may still report a non-nil empty accessibility value.
        let text = [timer.value as? String, timer.label].compactMap { $0 }.joined(separator: " ")
        let expression = try NSRegularExpression(pattern: "残り([0-9]+)分([0-9]+)秒")
        let match = try XCTUnwrap(expression.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)
        ), text)
        let minuteRange = try XCTUnwrap(Range(match.range(at: 1), in: text))
        let secondRange = try XCTUnwrap(Range(match.range(at: 2), in: text))
        return try XCTUnwrap(Int(text[minuteRange])) * 60 + XCTUnwrap(Int(text[secondRange]))
    }

    private func assertCountdownContinued(
        _ timer: XCUIElement,
        from initialSeconds: Int,
        since started: Date
    ) throws {
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            guard let current = try? remainingSeconds(timer) else { return false }
            return current < initialSeconds
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 4), .completed)
        let remaining = try remainingSeconds(timer)
        XCTAssertGreaterThanOrEqual(remaining, initialSeconds - Int(ceil(Date().timeIntervalSince(started))) - 4,
                                    "Changing layout must preserve the timer's existing deadline")
    }

    private func cancelFocusAndVerifyHome() {
        let timerWasLandscape = app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
        let cancel = app.buttons["今日はここまで"].firstMatch
        XCTAssertTrue(reveal(cancel, towardStart: false))
        cancel.tap()
        let alert = app.alerts["今日はここまで"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        assertWindowOrientation(isLandscape: timerWasLandscape)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(alert.frame),
                      "The system cancellation alert must fit the timer's native scene")
        alert.buttons["今日はここまで"].tap()
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 8))
        XCTAssertFalse(app.buttons["timer.rotate"].exists)
        assertWindowOrientation(isLandscape: false)
    }

    private func dismissPresentedTimerIfNeeded() {
        let stop = app.buttons["focus.completion-alert.stop"]
        let stoppedCompletion = stop.exists && reveal(stop, towardStart: false)
        if stoppedCompletion { stop.tap() }
        let reward = app.buttons["reward.dismiss"]
        // Completion commits and then presents its reward asynchronously. A
        // failed demo test must not leave that later bridge blocking the next run.
        if reward.exists || (stoppedCompletion && reward.waitForExistence(timeout: 12)) {
            if reveal(reward, towardStart: false) { reward.tap() }
        }
        let skip = app.buttons["休憩をスキップ"].firstMatch
        if skip.exists, reveal(skip, towardStart: false) { skip.tap() }
        let cancel = app.buttons["今日はここまで"].firstMatch
        if cancel.exists, reveal(cancel, towardStart: false) {
            cancel.tap()
            let alert = app.alerts["今日はここまで"]
            if alert.waitForExistence(timeout: 2) { alert.buttons["今日はここまで"].tap() }
        }
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func reveal(_ element: XCUIElement, towardStart: Bool, attempts: Int = 8) -> Bool {
        for _ in 0 ..< attempts {
            if element.exists, element.isHittable { return true }
            // The AX5 reward uses a separate scrollable bottom inset. A swipe
            // on the app can move Home behind it without ever exposing the
            // reward action, so target the innermost scroll containing it.
            var scrollSurface: XCUIElement = app
            if element.exists {
                let identifier = element.identifier
                let target = identifier.isEmpty
                    ? NSPredicate(format: "label == %@", element.label)
                    : NSPredicate(format: "identifier == %@", identifier)
                let viewport = app.windows.firstMatch.frame
                let containers = app.scrollViews.containing(target).allElementsBoundByIndex
                    .filter { !$0.frame.intersection(viewport).isEmpty }
                if let innermost = containers.first(where: {
                    $0.scrollViews.containing(target).count == 0
                }) {
                    scrollSurface = innermost
                } else if let container = containers.last {
                    scrollSurface = container
                }
            }
            // Native landscape uses the window's ordinary vertical axis.
            // Only an unsupported upside-down scene retains a content transform.
            let rotationControl = app.buttons["timer.rotate"]
            let direction = rotationControl.exists ? rotationControl.value as? String : nil
            let isUpsideDownFallback = direction == "下" && sceneInterfaceOrientation == .portrait
            if towardStart != isUpsideDownFallback {
                scrollSurface.swipeDown()
            } else {
                scrollSurface.swipeUp()
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
