import XCTest

/// Opt-in audit of PomoGem's everyday core loop on a real, explicitly
/// authorized iPhone: a brand-new install is driven through the storage choice,
/// onboarding, a real 25-minute focus that keeps wall-clock time while the app
/// is in the background, pause/resume, a full focus that finishes while the app
/// is in the background, the reward, and the Log and Settings screens.
///
/// The Simulator cannot establish any of this: its clock, suspension,
/// notification delivery and SpriteKit/Metal cost differ from a phone, so every
/// test refuses to run there. The application is launched as it ships: no
/// launch environment beyond the scenario tag every UI test sends (only the
/// Debug Simulator build reads it), and only argument-domain preferences as
/// launch arguments — the Japanese language pin every UI test uses
/// (PomoGemUITestLanguage) and the leave-pause switch (off for test01–test07,
/// on for test08, test09 and test12). No hook exists in the app target for
/// this suite.
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
///   POMOGEM_REAL_CORE_LOOP_EXTRAS=1
///        Opts in to the focused device checks test08–test12 (each takes real
///        time: test09 and test12 wait out a focus and a 5-minute break).
///        Absent ⇒ they skip.
///   POMOGEM_REAL_CORE_LOOP_PHOTOS=allow|deny
///        test10's answer to iOS's Photos permission prompt. test10 saves two
///        animated GIFs to the phone's Photos library, so it skips unless this
///        is set.
///   POMOGEM_REAL_CORE_LOOP_MANUAL_ADDS=<1...3>
///        How many 「時間を手動で積む」 entries test11 saves. They count against
///        the app's per-device daily allowance (3), so it skips unless set.
///   POMOGEM_REAL_CORE_LOOP_PROFILE_PAUSE=<5...180>
///        test11 attaches the marker 「profile-landing-ready」 and waits this
///        long before its last entry, so Instruments can attach from the Mac
///        and record that gem landing.
///   POMOGEM_REAL_CORE_LOOP_ICLOUD_RESTORE=1
///        Runs ONLY test20 and test21 (every other test skips): a fresh
///        install that chooses iCloud on an Apple Account with existing
///        PomoGem data, then the same installation. They observe and never
///        answer a dialog that could replace or delete data.
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
///   test08  (extras) the leave pause (#51, Docs/FocusLeavePause.md): a
///           10-second visit to the Home Screen leaves the focus running; a
///           longer absence pauses it at the moment of leaving and delivers
///           「集中が切れています」; 再開する continues
///   test09  (extras) the focus ends on screen and rings until stopped →
///           reward → 5分休憩 → the break screen → a relaunch mid-break
///           recovers it → a relaunch with about 25 s left → the recovered
///           break rings at its end until stopped (#49)
///   test10  (extras, Photos) share → 動くGIF → 写真に2サイズ保存 → the
///           Photos permission prompt → the saved status
///   test11  (extras, manual adds) 時間を手動で積む within the daily allowance;
///           each gem's landing, the totals and the undo toast
///   test12  (extras) another on-screen focus end → 5分休憩 → 休憩をスキップ →
///           Home; no break-end notification arrives at the break's old end
///   test20  (iCloud restore run only) fresh install → iCloud → the restore
///           screen with live counts → Home; short and long absences
///   test21  (iCloud restore run only, after test20) how long Home's
///           「iCloudを確認中」 lasts after launch and after 5 s and 10 s
///           absences, with a burst of captures on each return
///
/// The lock screen (the break's Live Activity, a real lock) cannot be driven
/// from XCTest without a passcode risk, so those rows of the device tables in
/// Docs/FocusLeavePause.md stay manual.
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
///     That command rewrites the runner bundle in place (it loses its
///     Info.plist, and the next run fails with "not a valid bundle"), so keep
///     a copy of the freshly built runner and restore it before every run.
///  3. Keep the phone unlocked, connected and awake. This suite never enters a
///     passcode and never opens iOS Settings; if the phone locks or a passcode
///     prompt appears it stops with "needs human". test01–test12 use the
///     local-only storage mode and never touch iCloud data; test20 chooses
///     iCloud on an account that already has data and only observes.
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
    private var extrasEnabled = false
    private var photosAnswer: NotificationAnswer?
    private var manualAdds = 0
    private var profilePauseSeconds = 0
    private var cloudRestoreRun = false
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
            "POMOGEM_REAL_CORE_LOOP_NOTIFICATIONS", "POMOGEM_REAL_CORE_LOOP_HOLD_SECONDS",
            "POMOGEM_REAL_CORE_LOOP_EXTRAS", "POMOGEM_REAL_CORE_LOOP_PHOTOS",
            "POMOGEM_REAL_CORE_LOOP_MANUAL_ADDS", "POMOGEM_REAL_CORE_LOOP_PROFILE_PAUSE",
            "POMOGEM_REAL_CORE_LOOP_ICLOUD_RESTORE"
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
        extrasEnabled = environment["POMOGEM_REAL_CORE_LOOP_EXTRAS"] == "1"
        if let raw = environment["POMOGEM_REAL_CORE_LOOP_PHOTOS"] {
            guard let answer = NotificationAnswer(rawValue: raw), answer != .skip else {
                XCTFail("POMOGEM_REAL_CORE_LOOP_PHOTOS must be allow or deny.")
                throw AuditFailure.stopped
            }
            photosAnswer = answer
        }
        if let raw = environment["POMOGEM_REAL_CORE_LOOP_MANUAL_ADDS"] {
            guard let count = Int(raw), (1...3).contains(count) else {
                XCTFail("POMOGEM_REAL_CORE_LOOP_MANUAL_ADDS must be an integer in 1...3.")
                throw AuditFailure.stopped
            }
            manualAdds = count
        }
        if let raw = environment["POMOGEM_REAL_CORE_LOOP_PROFILE_PAUSE"] {
            guard let seconds = Int(raw), (5...180).contains(seconds) else {
                XCTFail("POMOGEM_REAL_CORE_LOOP_PROFILE_PAUSE must be an integer in 5...180.")
                throw AuditFailure.stopped
            }
            profilePauseSeconds = seconds
        }
        cloudRestoreRun = environment["POMOGEM_REAL_CORE_LOOP_ICLOUD_RESTORE"] == "1"
        // The iCloud restore run needs its own fresh install; nothing else
        // may run in it (test01 would choose local-only storage).
        if cloudRestoreRun, !(name.contains("test20") || name.contains("test21")) {
            throw XCTSkip("POMOGEM_REAL_CORE_LOOP_ICLOUD_RESTORE=1 runs only test20 and test21.")
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

    // MARK: - test08 leave pause (extras)

    /// #51 in its shipping default (Docs/FocusLeavePause.md): leaving for the
    /// Home Screen pauses the focus at the moment of leaving once 20 s have
    /// passed without a lock, and 「集中が切れています」 arrives about 30 s
    /// after leaving. A visit shorter than that changes nothing.
    func test08LeavePauseIgnoresAShortVisitAndPausesALongAbsenceRetroactively() throws {
        try requireExtras()
        let app = attachWithLeavePause()
        try ensureRunningFocus()
        let runningRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "一時停止します")
        ).firstMatch
        // With a passcode the row says the lock does not pause; without one
        // it says the screen turning off does.
        note("LEAVE running row: \(labelIfPresent(runningRow))")
        capture("leave-focus-running")

        // A visit shorter than the 20-second lock window.
        let shortBefore = try timerRemainingSeconds()
        let shortSampled = Date()
        XCUIDevice.shared.press(.home)
        lastKeepAwake = Date()
        pause(2)
        capture("leave-short-springboard")
        pause(max(0, 10 - Date().timeIntervalSince(shortSampled)))
        let shortAway = Date().timeIntervalSince(shortSampled)
        try returnToApp(reason: "leave-short-visit")
        try requireFocus(paused: false, timeout: 20)
        let shortAfter = try timerRemainingSeconds()
        let shortElapsed = Date().timeIntervalSince(shortSampled)
        let notice = app.descendants(matching: .any)["focus.leave-paused-notice"].firstMatch
        note("LEAVE short visit \(format(shortAway)) s away: remaining \(shortBefore) s → \(shortAfter) s over \(format(shortElapsed)) s (drift \(format(Double(shortBefore - shortAfter) - shortElapsed)) s); leave notice shown: \(notice.exists)")
        capture("leave-short-returned")
        try require(!notice.exists, "A visit under 15 s must not leave-pause the focus.")
        try require(abs(Double(shortBefore - shortAfter) - shortElapsed) <= 4,
                    "After a short visit the countdown must have kept wall-clock time.")
        _ = try requireRunningCountdown()
        // The visit's window closes on return; nothing may pause it later.
        pause(25)
        try requireFocus(paused: false)
        try require(!notice.exists, "A short visit must not pause the focus after the return either.")
        capture("leave-short-still-running")

        // An absence longer than the lock window.
        let longBefore = try timerRemainingSeconds()
        let longSampled = Date()
        XCUIDevice.shared.press(.home)
        let leftAt = Date()
        lastKeepAwake = leftAt
        let springboard = XCUIApplication(bundleIdentifier: Self.springboardID)
        let nudge = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "集中が切れています")
        ).firstMatch
        var nudgeSeenAt: Date?
        // Keep-awake presses stay out of 25...43 s so the Home press cannot
        // dismiss a banner due at about +30 s.
        var keepAwakeMarks: [TimeInterval] = [12, 24, 44]
        let watchDeadline = leftAt.addingTimeInterval(60)
        while Date() < watchDeadline {
            let away = Date().timeIntervalSince(leftAt)
            if nudgeSeenAt == nil, nudge.exists {
                nudgeSeenAt = Date()
                note("LEAVE nudge banner at +\(format(away)) s after leaving: \(labelIfPresent(nudge))")
                capture("leave-nudge-banner")
            }
            if nudgeSeenAt != nil, away >= 34 { break }
            if let mark = keepAwakeMarks.first, away >= mark {
                keepAwakeMarks.removeFirst()
                if nudgeSeenAt == nil {
                    try guardAgainstLock()
                    XCUIDevice.shared.press(.home)
                    lastKeepAwake = Date()
                }
            }
            pause(0.5)
        }
        if nudgeSeenAt == nil {
            note("LEAVE no 「集中が切れています」 banner within 60 s of leaving")
            capture("leave-no-nudge-banner")
            attach(string: springboard.debugDescription, name: "springboard-hierarchy-no-nudge")
        }
        let away = Date().timeIntervalSince(leftAt)
        if nudgeSeenAt != nil, nudge.exists, nudge.isHittable {
            nudge.tap()
            note("LEAVE return through the nudge banner after \(format(away)) s")
            if !waitForForeground(app, timeout: 10) {
                try returnToApp(reason: "after-nudge-tap-failed")
            }
        } else {
            try returnToApp(reason: "leave-long-absence")
        }
        try requireFocus(paused: true, timeout: 20)
        try require(notice.waitForExistence(timeout: 10),
                    "A focus paused by leaving must say so on the timer screen.")
        let pausedRemaining = try timerRemainingSeconds()
        let expected = Double(longBefore) - leftAt.timeIntervalSince(longSampled)
        note("LEAVE long absence \(format(away)) s: remaining \(longBefore) s → \(pausedRemaining) s; paused at the moment of leaving would read \(format(expected)) s (difference \(format(Double(pausedRemaining) - expected)) s); notice 「\(notice.label)」")
        capture("leave-long-returned-paused")
        try require(abs(Double(pausedRemaining) - expected) <= 4,
                    "The leave pause must take effect retroactively at the moment of leaving.")
        pause(8)
        let heldRemaining = try timerRemainingSeconds()
        note("LEAVE paused remaining \(pausedRemaining) s → \(heldRemaining) s after 8 s")
        try require(heldRemaining == pausedRemaining, "A leave-paused focus must hold its remaining time.")

        try tap(app.buttons["再開する"])
        try requireFocus(paused: false)
        _ = try requireRunningCountdown()
        try require(waitForAbsence(notice, timeout: 5), "A resumed focus is no longer leave-paused.")
        capture("leave-resumed")
        try require(nudgeSeenAt != nil,
                    "「集中が切れています」 must be delivered about 30 s after leaving (notifications were allowed in test02).")
    }

    // MARK: - test09 on-screen end, break, relaunches, recovered alarm (extras)

    func test09FocusEndsOnScreenThenBreakRecoversAcrossRelaunchesAndRings() throws {
        try requireExtras()
        let app = attachWithLeavePause()
        try ensureRunningFocus()
        try waitForOnScreenFocusCompletion()
        try startBreakFromReward()

        // The break screen and its countdown.
        let first = try breakRemainingSeconds()
        let firstAt = Date()
        note("BREAK screen: header 休憩=\(app.staticTexts["休憩"].exists); notice \(labelIfPresent(breakNotificationRow)); remaining \(first) s")
        capture("break-screen")
        pause(6)
        let second = try breakRemainingSeconds()
        let elapsed = Date().timeIntervalSince(firstAt)
        note("BREAK countdown \(first) s → \(second) s over \(format(elapsed)) s (drift \(format(Double(first - second) - elapsed)) s)")
        try require(abs(Double(first - second) - elapsed) <= 3, "The break countdown must follow wall-clock time.")

        // A relaunch mid-break reopens the break with the right time.
        let beforeKill = try breakRemainingSeconds()
        let killedAt = Date()
        capture("break-before-relaunch")
        app.terminate()
        note("BREAK terminated with \(beforeKill) s left")
        pause(3)
        app.launch()
        try require(breakSkip.waitForExistence(timeout: 60), "A relaunch mid-break must reopen the break screen.")
        let recovered = try breakRemainingSeconds()
        let away = Date().timeIntervalSince(killedAt)
        note("BREAK recovered after relaunch: \(beforeKill) s → \(recovered) s over \(format(away)) s (drift \(format(Double(beforeKill - recovered) - away)) s)")
        capture("break-recovered-after-relaunch")
        try require(abs(Double(beforeKill - recovered) - away) <= 5,
                    "The recovered break must keep wall-clock time across the relaunch.")

        // #49: relaunch with about 25 s left and stay on screen; the recovered
        // break must ring at its end until stopped.
        var left = try breakRemainingSeconds()
        while left > 26 {
            pause(min(20, Double(left - 26)))
            try guardAgainstLock()
            left = try breakRemainingSeconds()
        }
        let breakEnd = Date().addingTimeInterval(TimeInterval(left))
        capture("break-before-late-relaunch")
        app.terminate()
        note("BREAK terminated again with \(left) s left")
        pause(1)
        app.launch()
        note("BREAK relaunched; XCTest's launch returned \(format(breakEnd.timeIntervalSinceNow)) s before the break's end")
        capture("break-late-recovered")
        let stop = app.buttons["break.completion-alert.stop"]
        let ringing = waitForLabel(stop, containing: "停止して瓶へ戻る", timeout: max(15, breakEnd.timeIntervalSinceNow + 30))
        note("BREAK end on screen: stop button 「\(labelIfPresent(stop))」 \(format(-breakEnd.timeIntervalSinceNow)) s after the break's end; 「休憩終了のアラート中」 shown: \(app.staticTexts["休憩終了のアラート中"].exists)")
        capture("break-end-after-recovery")
        try require(ringing, "A recovered break that ends on screen must ring until stopped (#49).")
        pause(8)
        note("BREAK 8 s later: 「\(labelIfPresent(stop))」")
        capture("break-alarm-still-ringing")
        try require(stop.label.contains("停止して瓶へ戻る"), "The break-end alarm must keep repeating until stopped.")
        try tap(stop)
        try requireHome(timeout: 30)
        pause(1)
        capture("home-after-break-alarm")
    }

    // MARK: - test10 share the animated GIF to Photos (extras, Photos)

    func test10ShareSavesTheAnimatedGIFToPhotos() throws {
        try requireExtras()
        guard let photosAnswer else {
            throw XCTSkip("Set POMOGEM_REAL_CORE_LOOP_PHOTOS=allow|deny: this test saves two GIFs to the Photos library.")
        }
        let app = attach(freshLaunch: false)
        let screen = try waitForHomeOrFocus()
        try require(screen == .home, "Share is audited from Home without a running timer.")
        try dismissRewardIfPresent()
        let totals = try readHomeTotals(label: "before-share")
        try require(totals.pebbles >= 1, "Sharing the jar needs at least one gem.")

        try openMenuAction("動く瓶をシェア")
        try require(app.navigationBars["カードにする"].waitForExistence(timeout: 20), "The share composer must open.")
        pause(2)
        capture("share-composer")
        let include = app.buttons["share.include-self-reported-direct"]
        if include.exists, include.isHittable {
            note("SHARE including self-reported gems (offered directly)")
            include.tap()
        }
        // The composer pins its share button over the bottom of the scroll
        // view; XCTest still calls a row under it hittable, and a tap there
        // starts the share. Every control is scrolled clear of it first.
        let primary = app.descendants(matching: .any)["share.primary-action"].firstMatch
        // The segment reads 「動くGIF、新機能」 while its badge is up.
        let gif = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "動くGIF")).firstMatch
        if !gif.exists {
            let adjustments = app.buttons["調整"]
            note("SHARE 調整 before scrolling: \(adjustments.exists ? "\(adjustments.frame)" : "<absent>") under the share button at \(primary.exists ? "\(primary.frame)" : "<absent>")")
            try scrollClear(adjustments, of: primary)
            try tap(adjustments)
        }
        try scrollClear(gif, of: primary)
        note("SHARE media 動くGIF selected: \(gif.isSelected)")
        if !gif.isSelected { try tap(gif) }
        capture("share-gif-selected")
        let save = app.buttons["写真に2サイズ保存"]
        try scrollClear(save, of: primary, attempts: 16)
        capture("share-before-save")
        try tap(save)
        let savedAt = Date()

        let springboard = XCUIApplication(bundleIdentifier: Self.springboardID)
        let promptDeadline = Date().addingTimeInterval(30)
        var answered = false
        let status = app.staticTexts["share.status"]
        while Date() < promptDeadline, !answered {
            for alert in [springboard.alerts.firstMatch, app.alerts.firstMatch] where alert.exists {
                guard alert.label.contains("写真") || alert.label.localizedCaseInsensitiveContains("photo") else {
                    capture("share-unexpected-alert")
                    try require(false, "An unexpected alert appeared while saving: \(alert.label)")
                    throw AuditFailure.stopped
                }
                note("PHOTOS prompt 「\(alert.label)」 buttons \(alert.buttons.allElementsBoundByIndex.map(\.label)) after \(seconds(since: savedAt)) s")
                capture("photos-permission-prompt")
                let predicate = photosAnswer == .deny
                    ? NSPredicate(format: "label CONTAINS %@ OR label CONTAINS[c] %@", "しない", "don")
                    : NSPredicate(format: "(label BEGINSWITH %@ AND NOT (label CONTAINS %@)) OR label ==[c] %@",
                                  "許可", "しない", "allow")
                let button = alert.buttons.matching(predicate).firstMatch
                try require(button.exists, "The Photos prompt must offer an allow/deny button.")
                note("PHOTOS answered 「\(button.label)」")
                button.tap()
                answered = true
                break
            }
            if !answered, status.exists, status.label.contains("写真に保存") { break }
            pause(0.5)
        }
        if !answered { note("PHOTOS no permission prompt within 30 s (already answered?)") }

        let outcome = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND (label CONTAINS %@ OR label CONTAINS %@)",
                                   "写真に保存しました", "保存できませんでした"),
            object: status
        )
        let settled = XCTWaiter.wait(for: [outcome], timeout: 120) == .completed
        note("SHARE status after \(seconds(since: savedAt)) s: 「\(labelIfPresent(status))」")
        capture("share-after-save")
        try require(settled, "Saving to Photos must end with a status line.")
        if photosAnswer == .allow {
            try require(status.label.contains("動くGIFをフィード用とストーリー用で写真に保存しました"),
                        "An allowed save of 動くGIF must report both GIFs saved.")
        }
        try tap(app.buttons["share.close"])
        try requireHome(timeout: 15)
    }

    // MARK: - test11 manual adds (extras, manual adds)

    func test11ManualAddsDropGemsWithinTheDailyAllowance() throws {
        try requireExtras()
        guard manualAdds > 0 else {
            throw XCTSkip("Set POMOGEM_REAL_CORE_LOOP_MANUAL_ADDS=1...3: entries count against the daily allowance.")
        }
        let app = attach(freshLaunch: false)
        let screen = try waitForHomeOrFocus()
        try require(screen == .home, "Manual adds are audited from Home without a running timer.")
        try dismissRewardIfPresent()
        var before = try readHomeTotals(label: "before-manual")
        let choices: [(title: String, grams: Int)] = [("2時間", 1_200), ("1時間", 600), ("30分", 300)]
        for index in 0..<manualAdds {
            let step = index + 1
            if index == manualAdds - 1, profilePauseSeconds > 0 {
                capture("profile-landing-ready")
                note("PROFILE waiting \(profilePauseSeconds) s for Instruments before entry \(step)")
                pause(TimeInterval(profilePauseSeconds))
            }
            try openMenuAction("時間を手動で積む")
            let remaining = app.staticTexts["manual.remaining-count"]
            try require(remaining.waitForExistence(timeout: 10), "The manual entry sheet must open.")
            note("MANUAL \(step): 「\(remaining.label)」")
            capture("manual-sheet-\(step)")
            if remaining.label.contains("あと0回") {
                note("MANUAL the daily allowance is used up; stopping")
                app.buttons["閉じる"].firstMatch.tap()
                try requireHome()
                break
            }
            let choice = choices[index % choices.count]
            let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", choice.title + "、")).firstMatch
            try scrollTo(option)
            try tap(option)
            let confirm = app.buttons["manual.confirm"]
            try require(confirm.waitForExistence(timeout: 5), "Choosing a duration must show 「確認して積む」.")
            capture("manual-confirm-\(step)")
            try tap(confirm)
            let savedAt = Date()
            try requireHome(timeout: 15)
            capture("manual-dropping-\(step)")
            var toastNoted = false
            for sample in 1...6 {
                note("MANUAL \(step) jar +\(seconds(since: savedAt)) s (\(sample)): \(describeValue(jarElement))")
                if !toastNoted, app.descendants(matching: .any)["app.toast"].firstMatch.exists {
                    noteToastOverlap(context: "after manual add \(step)")
                    toastNoted = true
                }
                pause(0.4)
            }
            capture("manual-landed-\(step)")
            if index == manualAdds - 1, profilePauseSeconds > 0 {
                pause(6)
                capture("profile-landing-done")
            }
            // Past the few-second undo window before the menu covers Home.
            pause(8)
            let after = try readHomeTotals(label: "after-manual-\(step)")
            note("MANUAL \(step) \(choice.title): pebbles \(before.pebbles) → \(after.pebbles); grams \(before.grams) → \(after.grams)")
            try require(after.grams == before.grams + choice.grams,
                        "A \(choice.title) manual entry must add \(choice.grams) g.")
            before = after
        }
        pause(3)
        note("MANUAL jar at rest: \(describeValue(jarElement))")
        capture("home-after-manual-adds")
    }

    // MARK: - test12 skip a break (extras)

    func test12BreakSkipReturnsToTheJarWithoutALaterNotification() throws {
        try requireExtras()
        _ = attachWithLeavePause()
        try ensureRunningFocus()
        try waitForOnScreenFocusCompletion()
        try startBreakFromReward()
        let left = try breakRemainingSeconds()
        let breakEnd = Date().addingTimeInterval(TimeInterval(left))
        capture("skip-break-screen")
        let skip = app.buttons.matching(NSPredicate(format: "label == %@", "休憩をスキップ")).allElementsBoundByIndex
            .last(where: { $0.exists && $0.isHittable })
        try require(skip != nil, "The break screen must offer 「休憩をスキップ」.")
        skip?.tap()
        let skippedAt = Date()
        try requireHome(timeout: 20)
        note("SKIP Home \(seconds(since: skippedAt)) s after 休憩をスキップ with \(left) s of break left")
        capture("skip-home")

        // Wait out the break's old end on the Home Screen: a skipped break
        // must not notify.
        XCUIDevice.shared.press(.home)
        lastKeepAwake = Date()
        try waitOnHomeScreen(until: breakEnd.addingTimeInterval(-5), captureEvery: nil)
        let springboard = XCUIApplication(bundleIdentifier: Self.springboardID)
        let banner = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "休憩はここまで")
        ).firstMatch
        var bannerSeen = false
        let watchDeadline = breakEnd.addingTimeInterval(25)
        while Date() < watchDeadline {
            if banner.exists { bannerSeen = true; break }
            if Date().timeIntervalSince(lastKeepAwake) > 14 {
                try guardAgainstLock()
                XCUIDevice.shared.press(.home)
                lastKeepAwake = Date()
            }
            pause(0.5)
        }
        note("SKIP break-end banner at the old end: \(bannerSeen ? labelIfPresent(banner) : "none")")
        capture("skip-after-old-break-end")
        try returnToApp(reason: "after-skipped-break")
        try requireHome()
        try require(!app.buttons["break.completion-alert.stop"].exists, "A skipped break must not come back.")
        try require(!bannerSeen, "A skipped break must not deliver its end notification.")
        capture("skip-home-final")
    }

    // MARK: - test20 iCloud reinstall (iCloud restore run only)

    /// #35 launch-06: a fresh install that chooses iCloud on an Apple Account
    /// that already has PomoGem data shows 「iCloudから記録を復元しています」
    /// with live counts instead of the tutorial, then Home with the restored
    /// jar. #40: a short absence keeps the iCloud session. This test only
    /// observes: it never taps 「新しく始める」 and stops, without answering,
    /// at any dialog it did not expect.
    func test20ICloudReinstallRestoresWithoutTheTutorial() throws {
        guard cloudRestoreRun else {
            throw XCTSkip("Set POMOGEM_REAL_CORE_LOOP_ICLOUD_RESTORE=1 (after a fresh install) to run test20.")
        }
        let app = attach(freshLaunch: true)
        let cloudChoice = app.buttons["iCloudに保存して同期"]
        let launchStarted = Date()
        while !cloudChoice.exists, Date().timeIntervalSince(launchStarted) < 60 {
            if app.buttons["メニュー"].exists || focusTimer.exists {
                capture("icloud-not-at-storage-choice")
                throw XCTSkip("Not a fresh install: the app opened past the storage choice.")
            }
            pause(0.5)
        }
        try require(cloudChoice.exists, "A fresh install must open at the storage choice within 60 s.")
        note("ICLOUD storage choice \(seconds(since: launchStarted)) s after launch")
        capture("icloud-storage-choice")
        try tap(cloudChoice)
        let confirmation = app.alerts["iCloudに保存して同期しますか？"]
        try require(confirmation.waitForExistence(timeout: 5), "Choosing iCloud must ask for confirmation.")
        capture("icloud-confirmation")
        try tap(confirmation.buttons["確認して続ける"])
        let chosenAt = Date()

        let springboard = XCUIApplication(bundleIdentifier: Self.springboardID)
        let restoreTitle = app.descendants(matching: .any)["cloud-restore.title"]
        let restoreScreen = app.descendants(matching: .any)["cloud-restore.waiting"]
        let quiet = app.descendants(matching: .any)["cloud-restore.quiet"]
        let onboarding = app.buttons["onboarding.next"]
        let checking = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "確認中")
        ).firstMatch
        let menu = app.buttons["メニュー"]
        var seen = Set<String>()
        var lastRestoreNote = Date.distantPast
        var restoreCaptures = 0
        var lastOtherNote = Date()
        let deadline = chosenAt.addingTimeInterval(420)
        while Date() < deadline {
            let at = seconds(since: chosenAt)
            for alert in [app.alerts.firstMatch, springboard.alerts.firstMatch] where alert.exists {
                note("ICLOUD unexpected dialog at +\(at) s: 「\(alert.label)」 buttons \(alert.buttons.allElementsBoundByIndex.map(\.label)); stopping without answering")
                capture("icloud-unexpected-dialog")
                attach(string: app.debugDescription, name: "icloud-dialog-hierarchy")
                try require(false, "An unexpected dialog appeared during the iCloud restore; it was left unanswered.")
            }
            if restoreTitle.exists {
                if seen.insert("restore").inserted {
                    note("ICLOUD restore screen at +\(at) s: \(labelIfPresent(restoreTitle))")
                }
                if Date().timeIntervalSince(lastRestoreNote) >= 3 {
                    lastRestoreNote = Date()
                    let texts = restoreScreen.exists
                        ? restoreScreen.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
                        : "<screen>"
                    note("ICLOUD restore +\(at) s: \(texts)")
                    if restoreCaptures < 8 {
                        restoreCaptures += 1
                        capture("icloud-restore-\(restoreCaptures)")
                    }
                }
                if quiet.exists, seen.insert("quiet").inserted {
                    note("ICLOUD restore quiet hint at +\(at) s (waiting; 新しく始める is never tapped)")
                    capture("icloud-restore-quiet")
                }
            }
            if onboarding.exists, seen.insert("onboarding").inserted {
                note("ICLOUD the tutorial appeared at +\(at) s instead of the restore/Home")
                capture("icloud-tutorial-shown")
                try require(false, "An account with iCloud data must not be sent to the tutorial; it was left untouched.")
            }
            if checking.exists, seen.insert("checking").inserted {
                note("ICLOUD 「\(labelIfPresent(checking))」 at +\(at) s")
                capture("icloud-checking")
            }
            if menu.exists, menu.isHittable {
                note("ICLOUD Home at +\(at) s (restore screen seen: \(seen.contains("restore")))")
                break
            }
            // Anything else (a launch check, a stop screen) is recorded,
            // never answered.
            if !restoreTitle.exists, Date().timeIntervalSince(lastOtherNote) >= 20 {
                lastOtherNote = Date()
                let texts = app.staticTexts.allElementsBoundByIndex.prefix(12).map(\.label).joined(separator: " | ")
                note("ICLOUD +\(at) s other screen: \(texts)")
                capture("icloud-other-\(Int(Date().timeIntervalSince(chosenAt)))s")
            }
            pause(0.5)
        }
        try require(menu.exists && menu.isHittable, "The restored jar must open within 7 minutes.")
        capture("icloud-home-first")
        // The mass presentation right after launch: sample the jar's value
        // (it carries the HUD's text) until it stops saying 確認中.
        let homeAt = Date()
        var lastValue = ""
        while Date().timeIntervalSince(homeAt) < 90 {
            let value = describeValue(jarElement)
            if value != lastValue {
                note("ICLOUD jar +\(seconds(since: homeAt)) s: \(value)")
                lastValue = value
                capture("icloud-home-jar")
            }
            if !value.contains("確認中") && Date().timeIntervalSince(homeAt) > 10 { break }
            pause(1)
        }
        let totals = try readHomeTotals(label: "icloud-restored")
        note("ICLOUD restored totals: \(totals.label)")
        capture("icloud-home-settled")
        try inspectCrystalIfPresent()

        try openMenuAction("設定")
        try require(app.navigationBars["設定"].waitForExistence(timeout: 10), "Settings must open.")
        let storage = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "現在の保存先")
        ).firstMatch
        try scrollTo(storage, attempts: 24)
        note("ICLOUD settings storage: \(labelIfPresent(storage))")
        capture("icloud-settings-storage")
        for _ in 0..<12 { app.swipeDown() }
        try returnHome(from: "設定")

        // #40: a short absence keeps the session; a long one retires it.
        for awaySeconds in [10.0, 40.0] {
            capture("icloud-before-away-\(Int(awaySeconds))s")
            XCUIDevice.shared.press(.home)
            let leftAt = Date()
            lastKeepAwake = leftAt
            try waitOnHomeScreen(until: leftAt.addingTimeInterval(awaySeconds), captureEvery: nil)
            let returnedAt = Date()
            app.activate()
            var states: [String] = []
            var firstHittable: TimeInterval?
            var index = 0
            while Date().timeIntervalSince(returnedAt) < 20 {
                let state: String
                if menu.exists && menu.isHittable {
                    state = "home"
                    if firstHittable == nil { firstHittable = Date().timeIntervalSince(returnedAt) }
                } else if checking.exists {
                    state = "checking(\(labelIfPresent(checking)))"
                } else if restoreTitle.exists {
                    state = "restore"
                } else {
                    state = "other"
                }
                if states.last != state {
                    states.append(state)
                    index += 1
                    capture("icloud-return-\(Int(awaySeconds))s-\(index)-\(state.prefix(8))")
                }
                if firstHittable != nil, Date().timeIntervalSince(returnedAt) > 8 { break }
                pause(0.25)
            }
            note("ICLOUD back after \(Int(awaySeconds)) s away: states \(states) ; Home usable after \(firstHittable.map { format($0) } ?? "never") s; jar: \(describeValue(jarElement))")
            try require(firstHittable != nil, "Home must come back after \(Int(awaySeconds)) s away.")
        }
        capture("icloud-final-home")
    }

    // MARK: - test21 iCloud verification after short absences (iCloud restore run only)

    /// #40 keeps the iCloud session through an absence shorter than the
    /// 15-second grace window. This measures what Home shows on the way
    /// back: whether the jar's totals drop back to 「iCloudを確認中」, for how
    /// long, and what the first frames look like.
    func test21ICloudShortAbsencesKeepTheSettledJar() throws {
        guard cloudRestoreRun else {
            throw XCTSkip("Set POMOGEM_REAL_CORE_LOOP_ICLOUD_RESTORE=1 to run test21 on the iCloud installation.")
        }
        _ = attach(freshLaunch: false)
        let screen = try waitForHomeOrFocus()
        try require(screen == .home, "test21 starts on Home.")
        let settledAfterLaunch = waitForSettledJar(label: "start", limit: 150)
        try require(settledAfterLaunch != nil, "The jar must settle (no 確認中) on the iCloud installation.")
        capture("icloud21-settled")
        for awaySeconds in [5.0, 10.0] {
            XCUIDevice.shared.press(.home)
            let leftAt = Date()
            lastKeepAwake = leftAt
            pause(awaySeconds)
            let returnedAt = Date()
            app.activate()
            for index in 1...5 {
                capture("icloud21-return-\(Int(awaySeconds))s-burst-\(index)")
                pause(0.15)
            }
            note("ICLOUD21 back after \(format(returnedAt.timeIntervalSince(leftAt))) s away")
            let settled = waitForSettledJar(label: "after \(Int(awaySeconds)) s away", limit: 150)
            note("ICLOUD21 after \(Int(awaySeconds)) s away the jar settled \(settled.map { format($0) } ?? "never (150 s)") s after the return")
            capture("icloud21-after-\(Int(awaySeconds))s-settled")
        }
    }

    /// Seconds until the jar's value stops saying 確認中 (nil if it never does
    /// within `limit`), noting each distinct value on the way.
    private func waitForSettledJar(label: String, limit: TimeInterval) -> TimeInterval? {
        let started = Date()
        var last = ""
        while Date().timeIntervalSince(started) < limit {
            let value = describeValue(jarElement)
            if value != last {
                note("ICLOUD21 [\(label)] +\(seconds(since: started)) s: \(value)")
                last = value
            }
            if !value.contains("確認中"), value != "<missing>" {
                return Date().timeIntervalSince(started)
            }
            pause(1)
        }
        return nil
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
        try waitForRewardCard(since: returnStarted)
        let rewardHeading = app.descendants(matching: .any)["reward.heading"]
        capture("reward-card")
        let jar = jarElement
        // dev-D7: the jar's accessibility value carries the HUD's totals
        // (the HUD itself is hidden from VoiceOver), so reading it through
        // the drop shows whether the totals move before the gem lands.
        note("JAR value at the reward card: \(describeValue(jar))")
        let dismiss = app.buttons["reward.dismiss"]
        try require(dismiss.waitForExistence(timeout: 5), "The reward card must offer 「閉じる」.")
        try tap(dismiss)
        let dismissedAt = Date()
        try require(waitForAbsence(rewardHeading, timeout: 10), "Closing the reward must retire the card.")
        pause(0.4)
        capture("gem-dropping")
        var toastNoted = false
        for index in 1...8 {
            note("JAR value +\(seconds(since: dismissedAt)) s after 閉じる (\(index)): \(describeValue(jar))")
            if !toastNoted, app.descendants(matching: .any)["app.toast"].firstMatch.exists {
                noteToastOverlap(context: "after the reward drop")
                toastNoted = true
            }
            pause(0.4)
        }
        capture("gem-landed")
        note("JAR value after the drop (+\(seconds(since: dismissedAt)) s): \(describeValue(jar))")
        if !toastNoted { noteToastOverlap(context: "after the reward drop") }
    }

    private func waitForRewardCard(since returnStarted: Date) throws {
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
    }

    private var jarElement: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "瓶")).firstMatch
    }

    /// home-03/#33: a toast must never sit on Home's start button.
    private func noteToastOverlap(context: String) {
        let toast = app.descendants(matching: .any)["app.toast"].firstMatch
        let launcher = app.buttons["home.focus-launcher"]
        guard toast.exists else {
            note("TOAST none visible \(context)")
            return
        }
        let toastFrame = toast.frame
        let launcherFrame = launcher.exists ? launcher.frame : .null
        note("TOAST \(context): 「\(toast.label)」 frame=\(toastFrame) launcher=\(launcherFrame) overlaps=\(toastFrame.intersects(launcherFrame))")
        capture("toast-\(context.replacingOccurrences(of: " ", with: "-"))")
    }

    private func dismissRewardIfPresent() throws {
        let dismiss = app.buttons["reward.dismiss"]
        guard dismiss.exists else { return }
        note("PRECONDITION a reward card was pending; closing it")
        capture("pending-reward-card")
        try tap(dismiss)
        _ = waitForAbsence(dismiss, timeout: 10)
    }

    /// A restored jar with crystals: find one by tapping the resting pile
    /// (a tap only bounces gems), then check where its card appears at the
    /// default text size. The first card sits in the row under the jar until
    /// a crystal's detail has been opened once; after that it hangs over
    /// the upper jar under the readout (home-11). Opening the detail is
    /// read-only.
    private func inspectCrystalIfPresent() throws {
        let jar = jarElement
        let value = describeValue(jar)
        guard value.contains("、結晶") else {
            note("CRYSTAL none in this jar: \(value)")
            return
        }
        let card = app.buttons["jar.aggregate.inspect"]
        func sweep(_ label: String) -> Bool {
            let frame = jar.frame
            for row in 0..<5 {
                for column in 0..<5 {
                    let point = CGPoint(
                        x: frame.minX + frame.width * (0.18 + 0.16 * CGFloat(column)),
                        y: frame.minY + frame.height * (0.5 + 0.1 * CGFloat(row))
                    )
                    app.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: point.x, dy: point.y)).tap()
                    if card.waitForExistence(timeout: 1.2) {
                        note("CRYSTAL \(label) card after a tap at \(point): \(card.label); card=\(card.frame) jar=\(frame)")
                        return true
                    }
                }
            }
            note("CRYSTAL \(label) no card after 25 taps over the pile")
            return false
        }
        guard sweep("first") else { return }
        capture("crystal-card-first")
        let jarFrame = jar.frame
        let inside = card.frame.minY >= jarFrame.minY && card.frame.maxY <= jarFrame.maxY
        note("CRYSTAL first card \(inside ? "over the jar" : "outside the jar (row under it)")")
        guard !inside else { return }
        try tap(card)
        let detail = app.navigationBars["結晶の内訳"]
        try require(detail.waitForExistence(timeout: 8), "The crystal card must open its detail.")
        pause(1)
        capture("crystal-detail")
        let close = app.buttons["overview.cluster.close"]
        try tap(close.exists ? close : detail.buttons.element(boundBy: 0))
        try requireHome()
        pause(7)
        guard sweep("second") else { return }
        capture("crystal-card-over-jar")
        let hudClear = card.frame.minY >= jar.frame.minY + 187
        note("CRYSTAL second card inside the jar: \(card.frame.minY >= jar.frame.minY && card.frame.maxY <= jar.frame.maxY); at or below the former 188 pt line: \(hudClear)")
    }

    // MARK: - extras helpers (leave pause, on-screen end, break)

    private func requireExtras() throws {
        guard extrasEnabled else {
            throw XCTSkip("Set POMOGEM_REAL_CORE_LOOP_EXTRAS=1 to run the focused device checks.")
        }
    }

    /// Whether this runner process launched the app with the leave pause on.
    /// `attach` launches it off (see there); test08, test09 and test12 need
    /// the shipping default, so the first of them relaunches the app once.
    /// A running focus or break survives the relaunch.
    private static var appLaunchedWithLeavePause = false

    @discardableResult
    private func attachWithLeavePause() -> XCUIApplication {
        let application = XCUIApplication()
        application.launchEnvironment = [:]
        // Explicitly on, whatever this phone has stored; the argument domain
        // is never persisted.
        application.launchArguments = [
            "-focus.leave-pause.enabled", "YES",
            "-focus.leave-pause.nudges.enabled", "YES"
        ]
        PomoGemUITestLanguage.configureJapanese(application)
        app = application
        if Self.appLaunchedWithLeavePause, application.state != .notRunning {
            note("APP activate (leave pause on; state was \(application.state.rawValue))")
            application.activate()
        } else {
            note("APP relaunch with the leave pause on (state was \(application.state.rawValue))")
            if application.state != .notRunning { application.terminate() }
            application.launch()
            Self.appLaunchedWithLeavePause = true
        }
        return application
    }

    /// Waits in the foreground for the running focus to end (the timer
    /// screen keeps the phone awake by default), checks that its alarm keeps
    /// repeating until stopped, stops it and follows it to the reward card.
    private func waitForOnScreenFocusCompletion() throws {
        try requireFocus(paused: false)
        let remaining = try timerRemainingSeconds()
        let expectedEnd = Date().addingTimeInterval(TimeInterval(remaining))
        note("ONSCREEN waiting \(remaining) s for the focus to end on screen")
        capture("onscreen-wait-start")
        while expectedEnd.timeIntervalSinceNow > 20 {
            pause(min(60, expectedEnd.timeIntervalSinceNow - 20))
            try guardAgainstLock()
            try require(focusTimer.exists && app.buttons["一時停止"].exists,
                        "The focus must keep running on screen until its end.")
        }
        let stop = app.buttons["focus.completion-alert.stop"]
        try require(stop.waitForExistence(timeout: max(10, expectedEnd.timeIntervalSinceNow + 30)),
                    "A focus that ends on screen must start its completion alarm.")
        let rangAt = Date()
        note("ONSCREEN alarm 「\(labelIfPresent(stop))」 \(format(rangAt.timeIntervalSince(expectedEnd))) s after the expected end")
        capture("onscreen-alarm-ringing")
        pause(6)
        try require(stop.exists && stop.isHittable, "The completion alarm must keep ringing until stopped.")
        capture("onscreen-alarm-still-ringing")
        stop.tap()
        try waitForRewardCard(since: rangAt)
        capture("onscreen-reward-card")
        note("JAR value at the reward card: \(describeValue(jarElement))")
    }

    private func startBreakFromReward() throws {
        let offer = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "分休憩する")).firstMatch
        try require(offer.waitForExistence(timeout: 10), "The reward card must offer the break.")
        let title = offer.label
        try tap(offer)
        let tappedAt = Date()
        try require(breakSkip.waitForExistence(timeout: 30), "The break screen must open.")
        note("BREAK screen \(seconds(since: tappedAt)) s after 「\(title)」")
    }

    private var breakSkip: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", "休憩をスキップ")).firstMatch
    }

    private var breakNotificationRow: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "通知")).firstMatch
    }

    private func breakRemainingSeconds() throws -> Int {
        let timer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "残り")).firstMatch
        try require(timer.waitForExistence(timeout: 10), "The break screen must show its countdown.")
        let value = timer.label
        let expression = try NSRegularExpression(pattern: "残り([0-9]+)分([0-9]+)秒")
        guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let minutesRange = Range(match.range(at: 1), in: value),
              let secondsRange = Range(match.range(at: 2), in: value),
              let minutes = Int(value[minutesRange]), let seconds = Int(value[secondsRange]) else {
            try require(false, "The break must expose a readable remaining duration: \(value).")
            throw AuditFailure.stopped
        }
        return minutes * 60 + seconds
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
        // This suite measures a focus that keeps running on the Home Screen
        // (test03 and the lock-screen completion banner). F1's leave pause
        // (Docs/FocusLeavePause.md) is switched off for this process only;
        // the argument domain is never persisted. test08 audits F1 itself
        // (`attachWithLeavePause`); its lock rows stay manual.
        application.launchArguments = ["-focus.leave-pause.enabled", "NO"]
        PomoGemUITestLanguage.configureJapanese(application)
        app = application
        if freshLaunch || application.state == .notRunning {
            note("APP launch (fresh=\(freshLaunch), state was \(application.state.rawValue))")
            application.launch()
            Self.appLaunchedWithLeavePause = false
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
            // An interrupted share (test10) can leave iOS's share sheet and
            // the composer open; both only close without saving anything.
            for identifier in ["header.closeButton", "share.close"] {
                let close = app.buttons[identifier]
                if close.exists, close.isHittable {
                    note("PRECONDITION \(identifier) was left open; closing it")
                    close.tap()
                    break
                }
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

    /// Drags the content up in short steps until `element` sits wholly above
    /// `cover`, a pinned bar XCTest does not treat as covering it.
    private func scrollClear(_ element: XCUIElement, of cover: XCUIElement, attempts: Int = 12) throws {
        func isClear() -> Bool {
            guard element.exists, element.isHittable else { return false }
            return !cover.exists || element.frame.maxY <= cover.frame.minY - 8
        }
        for _ in 0..<attempts {
            if isClear() { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
            start.press(forDuration: 0.05, thenDragTo: end)
            pause(0.4)
        }
        try require(isClear(), "Could not reveal required content above the pinned action.")
    }

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
