import XCTest

/// Opt-in audit of PomoGem's everyday core loop on a real, explicitly
/// authorized iPhone: a brand-new install is driven through the storage choice,
/// onboarding, a real 25-minute focus that keeps wall-clock time while the app
/// is in the background, pause/resume, a full focus that finishes while the app
/// is in the background, the reward, and the Log and Settings screens.
///
/// The Simulator cannot establish any of this: its clock, suspension,
/// notification delivery and SpriteKit/Metal cost differ from a phone, so every
/// test refuses to run there. The application is always launched with an empty
/// launch environment and no launch arguments, exactly as it ships; no hook
/// exists in the app target for this suite.
///
/// Set these in the UI TEST RUNNER's environment (EnvironmentVariables in a
/// private .xctestrun, or TEST_RUNNER_ variables):
///   POMOGEM_REAL_CORE_LOOP_AUDIT=1                 (required opt-in)
///   POMOGEM_REAL_CORE_LOOP_THEME=<4...24 ASCII letters/digits/hyphens>
///        Theme created during onboarding and used by every later test.
///        Absent ⇒ "CoreLoopAudit".
///   POMOGEM_REAL_CORE_LOOP_NOTIFICATIONS=allow|deny|skip   (default allow)
///        The answer given to iOS's notification permission prompt after the
///        focus screen's opt-in 「終了通知を許可」 control is tapped. `skip`
///        never taps the opt-in control.
///   POMOGEM_REAL_CORE_LOOP_HOLD_SECONDS=<30...900>
///        Opts in to test07, which holds the app idle on Home for that long
///        so Instruments can be recorded from the Mac. Absent ⇒ test07 skips.
///
/// The tests are ordered by name and share one app process: run the whole
/// class once after an independent uninstall/reinstall, or run any single
/// test with -only-testing. Every test after the first checks (and, where it
/// is harmless, prepares) its own precondition, so a partial run still yields
/// evidence:
///   test01  fresh install → 「このiPhoneだけに保存」 → onboarding → Home
///   test02  Home → 25-minute focus → countdown advances → notification opt-in
///   test03  ~60 s on the Home Screen → remaining time dropped by wall time
///   test04  pause holds the remaining time, resume continues it
///   test05  the rest of the focus elapses in the background → banner →
///           return → completion/reward flow → the gem is credited
///   test06  Log and Settings reflect the completed focus; ends on Home
///   test07  (opt-in) holds the idle Home screen for Instruments profiling
///
/// Operator steps
///  1. Build the Release app for the phone (development signing), and the
///     runner alone with `xcodebuild build -target PomoGemUITests
///     -configuration Release -sdk iphoneos SYMROOT=<Products> OBJROOT=…`:
///     `build-for-testing -configuration Release` fails on PomoGemTests, and a
///     Debug build must never be installed on the audit phone.
///  2. Write a private .xctestrun whose TestHostPath is the Release runner,
///     whose UITargetAppPath is the Release app, whose EnvironmentVariables
///     carry the flags above, and whose UITargetAppEnvironmentVariables and
///     launch arguments are empty. Run it with `xcodebuild test-without-building`.
///  3. Keep the phone unlocked, connected and awake. This suite never enters a
///     passcode and never opens iOS Settings; if the phone locks or a passcode
///     prompt appears it stops with "needs human". It uses the local-only
///     storage mode, so it never touches iCloud data.
///  4. Screenshots, the accessibility hierarchy on failure and a transcript
///     with every measured number are attached with .keepAlways; export them
///     with `xcrun xcresulttool export attachments`.
@MainActor
final class RealDeviceCoreLoopUITests: XCTestCase {
    private enum AuditFailure: Error { case stopped }

    private enum NotificationAnswer: String {
        case allow, deny, skip
    }

    private struct HomeTotals {
        var grams: Int
        var pebbles: Int
        var label: String
    }

    private static let springboardID = "com.apple.springboard"
    private static let defaultThemeName = "CoreLoopAudit"
    private static let focusSeconds = 25 * 60
    private static let focusGrams = 250
    private static let completionNotificationBody = "集中時間が終わりました"

    /// Home totals read immediately before test02 starts its focus. The class
    /// shares one runner process, so test05 can require an exact +1 pebble.
    private static var totalsBeforeFocus: HomeTotals?

    private var app: XCUIApplication!
    private var themeName = RealDeviceCoreLoopUITests.defaultThemeName
    private var notificationAnswer = NotificationAnswer.allow
    private var holdSeconds = 0
    private var transcript: [String] = []
    private var attachmentIndex = 0
    private var retainedFailureEvidence = false
    private var lastKeepAwake = Date.distantPast

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 2_400
#if targetEnvironment(simulator)
        throw XCTSkip("The core-loop audit requires an explicitly authorized physical iPhone.")
#else
        let environment = ProcessInfo.processInfo.environment
        guard environment["POMOGEM_REAL_CORE_LOOP_AUDIT"] == "1" else {
            throw XCTSkip("Set POMOGEM_REAL_CORE_LOOP_AUDIT=1 in the test runner to opt in.")
        }
        let permittedKeys: Set<String> = [
            "POMOGEM_REAL_CORE_LOOP_AUDIT", "POMOGEM_REAL_CORE_LOOP_THEME",
            "POMOGEM_REAL_CORE_LOOP_NOTIFICATIONS", "POMOGEM_REAL_CORE_LOOP_HOLD_SECONDS"
        ]
        let unexpected = environment.keys.filter {
            ($0.hasPrefix("POMOGEM_") && !permittedKeys.contains($0))
                || $0 == "XCODE_RUNNING_FOR_PREVIEWS"
                || $0 == "StoreKitConfigurationFile"
        }
        guard unexpected.isEmpty else {
            XCTFail("Remove preview, mock and fixture flags from the runner environment: \(unexpected.sorted()).")
            throw AuditFailure.stopped
        }
        if let name = environment["POMOGEM_REAL_CORE_LOOP_THEME"] {
            guard name.range(of: "^[A-Za-z0-9-]{4,24}$", options: .regularExpression) != nil else {
                XCTFail("POMOGEM_REAL_CORE_LOOP_THEME must be 4...24 ASCII letters, digits or hyphens.")
                throw AuditFailure.stopped
            }
            themeName = name
        }
        if let raw = environment["POMOGEM_REAL_CORE_LOOP_NOTIFICATIONS"] {
            guard let answer = NotificationAnswer(rawValue: raw) else {
                XCTFail("POMOGEM_REAL_CORE_LOOP_NOTIFICATIONS must be allow, deny or skip.")
                throw AuditFailure.stopped
            }
            notificationAnswer = answer
        }
        if let raw = environment["POMOGEM_REAL_CORE_LOOP_HOLD_SECONDS"] {
            guard let seconds = Int(raw), (30...900).contains(seconds) else {
                XCTFail("POMOGEM_REAL_CORE_LOOP_HOLD_SECONDS must be an integer in 30...900.")
                throw AuditFailure.stopped
            }
            holdSeconds = seconds
        }
        // Backup only: the prompt is normally answered explicitly through
        // SpringBoard. The monitor is limited to the notification prompt so
        // it can never answer an unrelated system alert.
        _ = addUIInterruptionMonitor(withDescription: "notification permission") { [weak self] alert in
            MainActor.assumeIsolated {
                guard let self else { return false }
                return self.answerNotificationPrompt(alert, source: "interruption monitor")
            }
        }
#endif
    }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 { retainFailureEvidence() }
        if !transcript.isEmpty { attach(string: transcript.joined(separator: "\n"), name: "transcript") }
        // The app is deliberately left running: the next ordered test
        // continues the same process, and the last one ends on Home.
        app = nil
    }

    // MARK: - test01 fresh install

    func test01FreshInstallChoosesLocalStorageAndFinishesOnboarding() throws {
        let app = attach(freshLaunch: true)
        let localChoice = app.buttons["このiPhoneだけに保存"]
        let launchStarted = Date()
        let deadline = launchStarted.addingTimeInterval(60)
        while !localChoice.exists, Date() < deadline {
            if app.buttons["メニュー"].exists || focusTimer.exists {
                capture("not-at-storage-choice")
                throw XCTSkip("Not a fresh install: the app opened past the storage choice. Uninstall and reinstall before test01.")
            }
            pause(0.5)
        }
        if !localChoice.exists {
            capture("not-at-storage-choice")
            try require(false, "A fresh install must open at the storage choice within 60 s.")
        }
        note("STORAGE CHOICE visible \(seconds(since: launchStarted)) s after launch")
        capture("storage-choice")
        try scrollTo(localChoice)
        capture("storage-choice-local-option")
        try tap(localChoice)

        let confirmation = app.alerts["このiPhoneだけに保存しますか？"]
        try require(confirmation.waitForExistence(timeout: 5), "Local-only storage requires its disclosure alert.")
        capture("storage-local-confirmation")
        try tap(confirmation.buttons["このiPhoneだけで始める"])

        let next = app.buttons["onboarding.next"]
        let step = app.descendants(matching: .any)["onboarding.step"]
        try require(next.waitForExistence(timeout: 60), "Local-only storage must reach onboarding.")
        try require(waitForLabel(step, containing: "1ページ"), "Onboarding must start on page 1.")
        capture("onboarding-page1")
        try tap(next)
        try require(waitForLabel(step, containing: "2ページ"), "Onboarding must reach the optional trial page.")
        capture("onboarding-page2")
        try tap(next)
        try require(app.staticTexts["最初のテーマを選ぶ"].waitForExistence(timeout: 5),
                    "Onboarding must reach theme creation.")
        capture("onboarding-page3-theme")

        let nameField = app.textFields["例：英語、TOEIC、企画、開発"]
        try scrollTo(nameField)
        try tap(nameField)
        nameField.typeText(themeName)
        capture("onboarding-theme-typed")
        try tap(app.buttons["選択"])
        let summary = app.descendants(matching: .any)["onboarding.selection-summary"]
        try require(waitForLabel(summary, containing: themeName), "The audit theme must be selected.")
        capture("onboarding-theme-selected")
        try require(waitForLabel(next, containing: "瓶をひらく"), "The last onboarding page must offer 「瓶をひらく」.")
        let openedAt = Date()
        try tap(next)
        try requireHome()
        note("HOME visible \(seconds(since: openedAt)) s after 瓶をひらく")
        capture("home-first")
        let launcher = app.buttons["home.focus-launcher"]
        try require(waitForLabel(launcher, containing: themeName), "Home must preselect the onboarding theme.")
        let totals = try readHomeTotals(label: "after-onboarding")
        try require(totals.pebbles == 0 && totals.grams == 0, "A fresh local install must start with an empty jar.")
        capture("home-after-onboarding")
    }

    // MARK: - test02 start a real 25-minute focus

    func test02HomeStartsTwentyFiveMinuteFocusAndCountdownAdvances() throws {
        _ = attach(freshLaunch: false)
        if try waitForHomeOrFocus() == .focus {
            capture("focus-already-running")
            throw XCTSkip("A focus is already running; test02 needs Home without a timer.")
        }
        try dismissRewardIfPresent()
        try selectAuditTheme()
        Self.totalsBeforeFocus = try readHomeTotals(label: "before-focus")
        capture("home-before-focus")
        try startRealTwentyFiveMinuteFocus()
        capture("focus-started")

        // Counting down: the accessible value must advance at wall-clock pace.
        let first = try timerRemainingSeconds()
        let firstAt = Date()
        _ = try requireRunningCountdown()
        pause(10)
        let second = try timerRemainingSeconds()
        let elapsed = Date().timeIntervalSince(firstAt)
        note("COUNTDOWN \(first) s → \(second) s over \(format(elapsed)) s wall time (drift \(format(Double(first - second) - elapsed)) s)")
        try require(second < first, "The countdown must advance.")
        try require(abs(Double(first - second) - elapsed) <= 3,
                    "The foreground countdown must follow wall-clock time.")
        capture("focus-countdown-advanced")

        try optIntoCompletionNotification()
        capture("focus-after-notification-choice")
    }

    // MARK: - test03 background for about 60 s

    func test03BackgroundSixtySecondsConsumesWallClockTime() throws {
        _ = attach(freshLaunch: false)
        try ensureRunningFocus()
        let before = try timerRemainingSeconds()
        let sampledAt = Date()
        capture("focus-before-background")
        XCUIDevice.shared.press(.home)
        lastKeepAwake = Date()
        pause(2)
        capture("springboard-with-focus-running")
        try waitOnHomeScreen(until: sampledAt.addingTimeInterval(60), captureEvery: nil)
        let returnStarted = Date()
        try returnToApp(reason: "after-60s-background")
        try requireFocus(paused: false, timeout: 20)
        let after = try timerRemainingSeconds()
        let elapsed = Date().timeIntervalSince(sampledAt)
        let dropped = Double(before - after)
        note("BACKGROUND remaining \(before) s → \(after) s; dropped \(format(dropped)) s over \(format(elapsed)) s wall time (drift \(format(dropped - elapsed)) s); return took \(seconds(since: returnStarted)) s")
        capture("focus-after-background")
        try require(abs(dropped - elapsed) <= 4,
                    "Remaining time must drop by the wall-clock time spent in the background.")
        _ = try requireRunningCountdown()
        capture("focus-still-counting-after-background")
    }

    // MARK: - test04 pause and resume

    func test04PauseHoldsRemainingTimeAndResumeContinues() throws {
        let app = attach(freshLaunch: false)
        try ensureRunningFocus()
        try tap(app.buttons["一時停止"])
        try requireFocus(paused: true)
        let paused = try timerRemainingSeconds()
        capture("focus-paused")
        pause(10)
        let stillPaused = try timerRemainingSeconds()
        note("PAUSE remaining \(paused) s → \(stillPaused) s after 10 s paused")
        try require(stillPaused == paused, "A paused timer must hold its remaining time.")
        capture("focus-paused-after-10s")

        try tap(app.buttons["再開する"])
        let resumedAt = Date()
        try requireFocus(paused: false)
        _ = try requireRunningCountdown()
        pause(5)
        let resumed = try timerRemainingSeconds()
        let elapsed = Date().timeIntervalSince(resumedAt)
        note("RESUME remaining \(paused) s → \(resumed) s over \(format(elapsed)) s after resume (drift \(format(Double(paused - resumed) - elapsed)) s)")
        try require(resumed < paused, "Resume must continue the countdown from the paused time.")
        try require(abs(Double(paused - resumed) - elapsed) <= 3,
                    "Resume must not lose or gain time relative to the paused remainder.")
        capture("focus-resumed")
    }

    // MARK: - test05 complete a full focus in the background

    func test05FullFocusCompletesInBackgroundAndCreditsGem() throws {
        let app = attach(freshLaunch: false)
        try ensureRunningFocus()
        let remaining = try timerRemainingSeconds()
        let expectedEnd = Date().addingTimeInterval(TimeInterval(remaining))
        let scheduledNotice = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "終了時に通知します")
        ).firstMatch.exists
        note("COMPLETION remaining \(remaining) s; expected end \(ISO8601DateFormatter().string(from: expectedEnd)); in-app notice says a completion notification is scheduled: \(scheduledNotice)")
        capture("focus-before-final-background")

        XCUIDevice.shared.press(.home)
        lastKeepAwake = Date()
        pause(2)
        capture("springboard-final-wait-start")
        try waitOnHomeScreen(until: expectedEnd.addingTimeInterval(-8), captureEvery: 300)

        // Watch for the banner from just before the expected end.
        let springboard = XCUIApplication(bundleIdentifier: Self.springboardID)
        let banner = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", Self.completionNotificationBody)
        ).firstMatch
        var bannerSeenAt: Date?
        let watchDeadline = expectedEnd.addingTimeInterval(60)
        while Date() < watchDeadline {
            if banner.exists {
                bannerSeenAt = Date()
                break
            }
            if Date().timeIntervalSince(lastKeepAwake) > 20 {
                try guardAgainstLock()
                XCUIDevice.shared.press(.home)
                lastKeepAwake = Date()
            }
            pause(0.5)
        }
        if let bannerSeenAt {
            note("NOTIFICATION banner appeared \(format(bannerSeenAt.timeIntervalSince(expectedEnd))) s after the expected end: \(labelIfPresent(banner))")
            capture("notification-banner")
        } else {
            note("NOTIFICATION no banner containing 「\(Self.completionNotificationBody)」 was visible on the Home Screen within 60 s of the expected end")
            capture("no-notification-banner")
            attach(string: springboard.debugDescription, name: "springboard-hierarchy-no-banner")
        }

        // Return the way a person would: through the banner when it is there.
        let returnStarted = Date()
        if bannerSeenAt != nil, banner.exists, banner.isHittable {
            banner.tap()
            note("RETURN via the notification banner")
            if !waitForForeground(app, timeout: 10) {
                note("RETURN banner tap did not foreground the app within 10 s; activating instead")
                try returnToApp(reason: "after-banner-tap-failed")
            }
        } else {
            try returnToApp(reason: "after-completion")
        }
        note("RETURN app foreground \(seconds(since: returnStarted)) s after starting the return")
        capture("return-after-completion")

        try followCompletionToHome(returnStarted: returnStarted)

        let totals = try readHomeTotals(label: "after-completion")
        if let before = Self.totalsBeforeFocus {
            note("CREDIT pebbles \(before.pebbles) → \(totals.pebbles); grams \(before.grams) → \(totals.grams)")
            try require(totals.pebbles == before.pebbles + 1, "One completed focus must add exactly one pebble.")
            try require(totals.grams == before.grams + Self.focusGrams, "A 25-minute focus must add exactly 250 g.")
        } else {
            note("CREDIT baseline unknown in this partial run; pebbles=\(totals.pebbles) grams=\(totals.grams)")
            try require(totals.pebbles >= 1 && totals.grams >= Self.focusGrams,
                        "A completed focus must be credited to the jar.")
        }
        capture("home-after-credit")
    }

    // MARK: - test06 Log and Settings

    func test06LogAndSettingsReflectCompletedFocus() throws {
        let app = attach(freshLaunch: false)
        let screen = try waitForHomeOrFocus()
        try require(screen == .home, "Log and Settings are audited from Home without a running timer.")
        try dismissRewardIfPresent()
        let totals = try readHomeTotals(label: "before-log")
        try require(totals.pebbles >= 1, "Log auditing requires at least one completed focus.")

        try openMenuAction("記録を見る")
        try require(app.navigationBars["記録"].waitForExistence(timeout: 10), "Record history must open.")
        pause(1)
        capture("log-top")
        // The focus just completed, so it is inside the default 今週.
        let time = summaryTile("log.summary.time")
        let mass = summaryTile("log.summary.mass")
        try scrollTo(time, direction: .down)
        note("LOG summary: \(labelIfPresent(time)) / \(labelIfPresent(mass))")
        try require(mass.exists, "The log must show this period's mass.")
        // The theme breakdown row also begins with the theme name; only a
        // history row carries 「プラス…グラム」.
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", themeName + "、", "プラス")
        ).firstMatch
        try scrollTo(row, attempts: 12)
        note("LOG history row: \(labelIfPresent(row))")
        try require(row.exists && row.label.contains("プラス\(Self.focusGrams)グラム"),
                    "The completed 25-minute focus must appear in the history with 250 g.")
        capture("log-history-row")
        for index in 1...3 {
            app.swipeUp()
            capture("log-scrolled-\(index)")
        }
        try returnHome(from: "記録")

        try openMenuAction("設定")
        try require(app.navigationBars["設定"].waitForExistence(timeout: 10), "Settings must open.")
        pause(1)
        capture("settings-top")
        let local = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "このiPhoneだけに保存")
        ).firstMatch
        try scrollTo(local, attempts: 24)
        note("SETTINGS storage: \(labelIfPresent(local))")
        capture("settings-storage")
        // Walk the whole screen once from the top so every section is seen.
        for _ in 0..<10 { app.swipeDown() }
        for index in 1...10 {
            app.swipeUp()
            capture("settings-scrolled-\(index)")
        }
        try returnHome(from: "設定")
        pause(2)
        capture("home-final-for-profiling")
    }

    // MARK: - test07 idle Home for profiling (opt-in)

    /// Holds the app idle on Home while the operator records Instruments from
    /// the Mac. Home does not disable the idle timer, so every 20 s this taps
    /// the status bar through SpringBoard's coordinate space: that keeps the
    /// phone from auto-locking without querying or driving the app between
    /// taps, and at most asks an already-top scroll view to scroll to the top.
    func test07HoldIdleHomeForProfiling() throws {
        guard holdSeconds > 0 else {
            throw XCTSkip("Set POMOGEM_REAL_CORE_LOOP_HOLD_SECONDS to hold Home for profiling.")
        }
        _ = attach(freshLaunch: false)
        let screen = try waitForHomeOrFocus()
        try require(screen == .home, "Profiling holds Home without a running timer.")
        try dismissRewardIfPresent()
        capture("home-hold-start")
        note("HOLD idle Home for \(holdSeconds) s")
        let statusBar = XCUIApplication(bundleIdentifier: Self.springboardID)
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005))
        let deadline = Date().addingTimeInterval(TimeInterval(holdSeconds))
        while Date() < deadline {
            pause(min(20, max(0, deadline.timeIntervalSinceNow)))
            if deadline.timeIntervalSinceNow > 1 { statusBar.tap() }
        }
        note("HOLD finished")
        capture("home-hold-end")
    }

    // MARK: - focus helpers

    private var focusTimer: XCUIElement {
        app.descendants(matching: .any)["focus.timer-display"].firstMatch
    }

    private func startRealTwentyFiveMinuteFocus() throws {
        let duration = app.buttons["home.duration-picker"]
        try scrollTo(duration, direction: .down)
        try tap(duration)
        capture("duration-menu")
        try tap(app.buttons["25分"])
        let launcher = app.buttons["home.focus-launcher"]
        try require(waitForLabel(launcher, containing: "25分集中する"),
                    "The audit uses the real 25-minute preset, never a shortened fixture.")
        try require(launcher.label.contains("\(Self.focusGrams)グラム"), "A 25-minute focus must promise 250 g.")
        capture("home-25min-selected")
        try tap(launcher)
        let tappedAt = Date()
        try require(focusTimer.waitForExistence(timeout: 30), "The focus screen must open.")
        note("FOCUS timer visible \(seconds(since: tappedAt)) s after the launcher tap (XCTest polls about once a second)")
        try requireFocus(paused: false)
        let remaining = try timerRemainingSeconds()
        note("FOCUS initial remaining \(remaining) s")
        try require((Self.focusSeconds - 60...Self.focusSeconds).contains(remaining),
                    "The initial countdown must match a real 25-minute focus.")
    }

    /// Later tests can run alone: they reuse a running focus, resume a paused
    /// one, or start a fresh 25-minute focus from Home.
    private func ensureRunningFocus() throws {
        if try waitForHomeOrFocus() == .focus {
            if app.buttons["再開する"].waitForExistence(timeout: 3) {
                note("PRECONDITION focus was paused; resuming it")
                try tap(app.buttons["再開する"])
            }
            try requireFocus(paused: false)
            return
        }
        note("PRECONDITION no running focus; starting a fresh 25-minute focus for this test")
        try dismissRewardIfPresent()
        try selectAuditTheme()
        if Self.totalsBeforeFocus == nil {
            Self.totalsBeforeFocus = try readHomeTotals(label: "before-focus")
        }
        try startRealTwentyFiveMinuteFocus()
    }

    private func requireFocus(paused: Bool, timeout: TimeInterval = 30) throws {
        try require(focusTimer.waitForExistence(timeout: timeout), "The focus screen must be showing.")
        try require(waitForLabel(app.staticTexts["focus.subject"], containing: themeName),
                    "The focus must belong to the audit theme.")
        try require(app.buttons[paused ? "再開する" : "一時停止"].waitForExistence(timeout: 10),
                    "The focus controls must match the \(paused ? "paused" : "running") state.")
        let state = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: paused ? "value CONTAINS %@" : "NOT (value CONTAINS %@)", "一時停止中"),
            object: focusTimer
        )
        try require(XCTWaiter.wait(for: [state], timeout: 10) == .completed,
                    "The accessible countdown must agree with the timer state.")
        try require(!app.alerts["タイマーを開始できませんでした"].exists
                    && !app.alerts["操作を完了できませんでした"].exists,
                    "Timer errors cannot count as a working focus.")
    }

    private func timerRemainingSeconds() throws -> Int {
        let value = focusTimer.value as? String ?? ""
        let expression = try NSRegularExpression(pattern: "残り([0-9]+)分([0-9]+)秒")
        guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let minutesRange = Range(match.range(at: 1), in: value),
              let secondsRange = Range(match.range(at: 2), in: value),
              let minutes = Int(value[minutesRange]), let seconds = Int(value[secondsRange]) else {
            try require(false, "The timer must expose a readable remaining duration: \(value).")
            throw AuditFailure.stopped
        }
        return minutes * 60 + seconds
    }

    private func requireRunningCountdown() throws -> Int {
        let before = try timerRemainingSeconds()
        let current = focusTimer.value as? String ?? ""
        let progressed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@ AND NOT (value CONTAINS %@)", current, "一時停止中"),
            object: focusTimer
        )
        try require(XCTWaiter.wait(for: [progressed], timeout: 10) == .completed,
                    "A running timer must visibly progress.")
        let after = try timerRemainingSeconds()
        try require(after < before && after > 0, "Running countdown seconds must decrease.")
        return after
    }

    private func optIntoCompletionNotification() throws {
        let optIn = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "終了通知を許可")).firstMatch
        let scheduled = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "終了時に通知します")
        ).firstMatch
        if scheduled.waitForExistence(timeout: 3) {
            note("NOTIFICATION already authorized and scheduled: \(scheduled.label)")
            return
        }
        guard optIn.exists else {
            let notice = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "通知")
            ).firstMatch
            note("NOTIFICATION opt-in control absent; focus notice: \(labelIfPresent(notice))")
            return
        }
        note("NOTIFICATION opt-in control: \(optIn.label)")
        capture("focus-notification-opt-in")
        guard notificationAnswer != .skip else {
            note("NOTIFICATION opt-in left untouched (skip)")
            return
        }
        try tap(optIn)
        let springboard = XCUIApplication(bundleIdentifier: Self.springboardID)
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 10) {
            capture("notification-permission-prompt")
            try require(answerNotificationPrompt(alert, source: "springboard"),
                        "The notification permission prompt must offer allow/deny buttons.")
        } else {
            note("NOTIFICATION no SpringBoard prompt appeared within 10 s (answered earlier?)")
        }
        pause(2)
        if notificationAnswer == .allow {
            try require(scheduled.waitForExistence(timeout: 10),
                        "After allowing notifications the focus must report 「終了時に通知します」.")
            note("NOTIFICATION scheduled: \(scheduled.label)")
        }
    }

    @discardableResult
    private func answerNotificationPrompt(_ alert: XCUIElement, source: String) -> Bool {
        let allowTitles = ["許可", "Allow"]
        let denyTitles = ["許可しない", "Don’t Allow", "Don't Allow"]
        let titles = notificationAnswer == .deny ? denyTitles : allowTitles
        guard notificationAnswer != .skip,
              alert.label.contains("通知") || alert.label.localizedCaseInsensitiveContains("notification")
        else { return false }
        for title in titles where alert.buttons[title].exists {
            note("NOTIFICATION prompt 「\(alert.label)」 answered 「\(title)」 via \(source)")
            alert.buttons[title].tap()
            return true
        }
        // Wording differs across iOS releases; fall back to the one button
        // that affirms (or declines) without matching the other.
        let fallback = notificationAnswer == .deny
            ? NSPredicate(format: "label CONTAINS %@ OR label CONTAINS[c] %@", "しない", "don")
            : NSPredicate(format: "(label BEGINSWITH %@ AND NOT (label CONTAINS %@)) OR label ==[c] %@",
                          "許可", "しない", "allow")
        let button = alert.buttons.matching(fallback).firstMatch
        guard button.exists else {
            note("NOTIFICATION prompt 「\(alert.label)」 had no recognizable button: \(alert.buttons.allElementsBoundByIndex.map(\.label))")
            return false
        }
        note("NOTIFICATION prompt 「\(alert.label)」 answered 「\(button.label)」 via \(source)")
        button.tap()
        return true
    }

    /// The completion normally passes through the commit view and the
    /// foreground completion alert before Home shows the reward card.
    private func followCompletionToHome(returnStarted: Date) throws {
        let stopAlert = app.buttons["focus.completion-alert.stop"]
        let saveError = app.descendants(matching: .any)["focus.completion-save.error"]
        let committing = app.staticTexts["粒を瓶へ運んでいます"]
        let rewardHeading = app.descendants(matching: .any)["reward.heading"]
        let backToJar = app.buttons["瓶を見る"]
        var seen = Set<String>()
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if saveError.exists {
                capture("completion-save-error")
                try require(false, "The completed focus failed to save: \(labelIfPresent(saveError))")
            }
            if committing.exists, seen.insert("committing").inserted {
                note("COMPLETION commit view 「粒を瓶へ運んでいます」 at +\(seconds(since: returnStarted)) s")
                capture("completion-commit-view")
            }
            if stopAlert.exists, stopAlert.isHittable {
                note("COMPLETION foreground completion alert active at +\(seconds(since: returnStarted)) s")
                capture("completion-alert-active")
                stopAlert.tap()
                pause(1)
                capture("completion-alert-stopped")
                continue
            }
            if backToJar.exists, backToJar.isHittable, seen.insert("completion-view").inserted {
                note("COMPLETION completion view with 「瓶を見る」 at +\(seconds(since: returnStarted)) s")
                capture("completion-view")
                backToJar.tap()
                continue
            }
            if rewardHeading.exists {
                note("COMPLETION reward card at +\(seconds(since: returnStarted)) s: \(labelIfPresent(rewardHeading)) / \(String(describing: rewardHeading.value ?? ""))")
                break
            }
            if app.buttons["メニュー"].exists, app.buttons["メニュー"].isHittable, !focusTimer.exists,
               seen.insert("home").inserted {
                note("COMPLETION Home visible without a reward card yet at +\(seconds(since: returnStarted)) s")
                capture("completion-home-before-reward")
            }
            pause(0.5)
        }
        try require(rewardHeading.exists, "Home must present the reward for the completed focus.")
        capture("reward-card")
        let dismiss = app.buttons["reward.dismiss"]
        try require(dismiss.waitForExistence(timeout: 5), "The reward card must offer 「閉じる」.")
        try tap(dismiss)
        try require(waitForAbsence(rewardHeading, timeout: 10), "Closing the reward must retire the card.")
        pause(0.4)
        capture("gem-dropping")
        pause(3)
        capture("gem-landed")
        let jar = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "瓶")).firstMatch
        note("JAR value after the drop: \(describeValue(jar))")
    }

    private func dismissRewardIfPresent() throws {
        let dismiss = app.buttons["reward.dismiss"]
        guard dismiss.exists else { return }
        note("PRECONDITION a reward card was pending; closing it")
        capture("pending-reward-card")
        try tap(dismiss)
        _ = waitForAbsence(dismiss, timeout: 10)
    }

    // MARK: - background helpers

    /// Stays on the Home Screen until `deadline`. A Home press every 15 s
    /// keeps the phone from auto-locking; it never unlocks anything.
    private func waitOnHomeScreen(until deadline: Date, captureEvery interval: TimeInterval?) throws {
        var nextCapture = interval.map { Date().addingTimeInterval($0) }
        while Date() < deadline {
            pause(min(15, max(0, deadline.timeIntervalSinceNow)))
            try guardAgainstLock()
            if deadline.timeIntervalSinceNow > 1 {
                XCUIDevice.shared.press(.home)
                lastKeepAwake = Date()
            }
            if let capturedAt = nextCapture, Date() >= capturedAt, let interval {
                capture("springboard-waiting-\(Int(deadline.timeIntervalSinceNow))s-left")
                nextCapture = Date().addingTimeInterval(interval)
            }
        }
    }

    private func returnToApp(reason: String) throws {
        try guardAgainstLock()
        app.activate()
        guard waitForForeground(app, timeout: 20) else {
            capture("could-not-foreground-\(reason)")
            try guardAgainstLock()
            try require(false, "The app did not return to the foreground (\(reason)); the phone may be locked — needs human.")
            return
        }
    }

    private func waitForForeground(_ application: XCUIApplication, timeout: TimeInterval) -> Bool {
        application.wait(for: .runningForeground, timeout: timeout)
    }

    /// This suite never enters a passcode. A lock screen or passcode prompt
    /// stops the run with evidence.
    private func guardAgainstLock() throws {
        let springboard = XCUIApplication(bundleIdentifier: Self.springboardID)
        let predicate = NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
            "パスコードを入力", "パスコードの入力", "Enter Passcode", "Enter PIN"
        )
        let locked = springboard.secureTextFields.count > 0
            || springboard.descendants(matching: .any).matching(predicate).firstMatch.exists
        guard locked else { return }
        note("LOCKED a passcode prompt is showing. Stopping; this suite never enters a passcode.")
        capture("passcode-prompt")
        throw XCTSkip("needs human: the phone locked or asked for a passcode; unlock it and re-run.")
    }

    // MARK: - Home helpers

    private func attach(freshLaunch: Bool) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchEnvironment = [:]
        application.launchArguments = []
        app = application
        if freshLaunch || application.state == .notRunning {
            note("APP launch (fresh=\(freshLaunch), state was \(application.state.rawValue))")
            application.launch()
        } else {
            note("APP activate (state was \(application.state.rawValue))")
            application.activate()
        }
        return application
    }

    private enum Screen { case home, focus }

    /// A relaunched process may reopen a saved focus instead of Home, and an
    /// interrupted earlier test may have left 記録 or 設定 open on top of it.
    private func waitForHomeOrFocus(timeout: TimeInterval = 60) throws -> Screen {
        let menu = app.buttons["メニュー"]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if focusTimer.exists { return .focus }
            if menu.exists, menu.isHittable { return .home }
            for title in ["記録", "設定"] where app.navigationBars[title].exists {
                note("PRECONDITION \(title) was left open; returning to Home")
                let back = app.navigationBars[title].buttons.element(boundBy: 0)
                if back.exists, back.isHittable { back.tap() }
            }
            pause(0.5)
        } while Date() < deadline
        try require(false, "Neither Home nor the focus screen opened.")
        throw AuditFailure.stopped
    }

    private func requireHome(timeout: TimeInterval = 60) throws {
        let home = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: app.buttons["メニュー"]
        )
        try require(XCTWaiter.wait(for: [home], timeout: timeout) == .completed, "Home must be showing.")
    }

    private func selectAuditTheme() throws {
        let launcher = app.buttons["home.focus-launcher"]
        try scrollTo(launcher, direction: .down)
        if launcher.label.contains(themeName) { return }
        let picker = app.buttons["home.subject-picker"]
        try scrollTo(picker, direction: .down)
        try tap(picker)
        try tap(app.buttons[themeName])
        try require(waitForLabel(launcher, containing: themeName), "Home must use the audit theme.")
    }

    private func readHomeTotals(label: String) throws -> HomeTotals {
        try tap(app.buttons["メニュー"])
        // The empty jar's hint 「25分の集中で、ここにひと粒落ちる。」 also mentions
        // 集中 and 粒; only the menu's combined metrics row mentions 累計.
        let summary = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "累計", "集中")
        ).firstMatch
        try require(summary.waitForExistence(timeout: 10), "The Home menu must summarize the totals.")
        let deadline = Date().addingTimeInterval(60)
        while summary.label.contains("確認中") || summary.label.contains("再集計中"), Date() < deadline {
            pause(2)
        }
        let text = summary.label
        capture("menu-totals-\(label)")
        try tap(app.buttons["home.menu.close"])
        try requireHome()
        let expression = try NSRegularExpression(pattern: "累計([0-9][0-9,]*(?:\\.[0-9]+)?) ?(kg|g)、集中([0-9][0-9,]*)粒")
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let massRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let countRange = Range(match.range(at: 3), in: text),
              let mass = Double(text[massRange].replacingOccurrences(of: ",", with: "")),
              let pebbles = Int(text[countRange].replacingOccurrences(of: ",", with: "")) else {
            try require(false, "The Home totals must be readable and settled: \(text)")
            throw AuditFailure.stopped
        }
        let grams = text[unitRange] == "kg" ? Int((mass * 1_000).rounded()) : Int(mass.rounded())
        note("TOTALS [\(label)] \(text) → pebbles=\(pebbles) grams=\(grams)")
        return HomeTotals(grams: grams, pebbles: pebbles, label: text)
    }

    private func openMenuAction(_ title: String) throws {
        try tap(app.buttons["メニュー"])
        let action = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        try scrollTo(action)
        capture("menu-before-\(title)")
        try tap(action)
    }

    private func returnHome(from title: String) throws {
        let bar = app.navigationBars[title]
        try require(bar.waitForExistence(timeout: 5), "Missing navigation bar: \(title).")
        try tap(bar.buttons.element(boundBy: 0))
        try requireHome()
    }

    /// By identifier: the tile's wording follows the period (今週の質量／今月の質量).
    private func summaryTile(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    // MARK: - plumbing

    private enum ScrollDirection { case up, down }

    private func tap(_ element: XCUIElement) throws {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"),
            object: element
        )
        try require(XCTWaiter.wait(for: [ready], timeout: 10) == .completed,
                    "A required UI control is missing, disabled, or obscured.")
        element.tap()
    }

    private func scrollTo(_ element: XCUIElement, direction: ScrollDirection = .up, attempts: Int = 16) throws {
        for _ in 0..<attempts {
            if element.exists && element.isHittable { return }
            if direction == .up { app.swipeUp() } else { app.swipeDown() }
        }
        try require(element.exists && element.isHittable, "Could not reveal required content.")
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", text), object: element
        )], timeout: timeout) == .completed
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element
        )], timeout: timeout) == .completed
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        guard condition() else {
            note("FAILED \(message)")
            retainFailureEvidence()
            XCTFail(message, file: file, line: line)
            throw AuditFailure.stopped
        }
    }

    private func retainFailureEvidence() {
        guard !retainedFailureEvidence else { return }
        retainedFailureEvidence = true
        capture("failure")
        if let app { attach(string: app.debugDescription, name: "failure-hierarchy") }
    }

    /// Reading `label` of a missing element raises; evidence strings must not.
    private func labelIfPresent(_ element: XCUIElement) -> String {
        element.exists ? element.label : "<absent>"
    }

    private func describeValue(_ element: XCUIElement) -> String {
        guard element.exists else { return "<missing>" }
        return element.value.map { String(describing: $0) } ?? ""
    }

    private func pause(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let expectation = XCTestExpectation(description: "pause \(seconds)")
        expectation.isInverted = true
        _ = XCTWaiter().wait(for: [expectation], timeout: seconds)
    }

    private func seconds(since date: Date) -> String {
        format(Date().timeIntervalSince(date))
    }

    private func format(_ value: TimeInterval) -> String {
        String(format: "%.1f", value)
    }

    private func note(_ line: String) {
        transcript.append("\(ISO8601DateFormatter().string(from: Date())) \(line)")
        NSLog("[pomogem-core-loop-audit] %@", line)
    }

    private func capture(_ name: String) {
        attachmentIndex += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%@-%02d-%@", testStepPrefix, attachmentIndex, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attach(string: String, name: String) {
        attachmentIndex += 1
        let attachment = XCTAttachment(string: string)
        attachment.name = String(format: "%@-%02d-%@", testStepPrefix, attachmentIndex, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// "test03" etc., so exported attachments sort by test and then by step.
    private var testStepPrefix: String {
        String(name.split(separator: " ").last?.prefix(6) ?? "test")
    }
}
