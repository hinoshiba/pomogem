import XCTest

/// The app's free learning ceiling (`ScreenTimePolicy.freeLearningApplicationLimit`).
/// The UI test target does not link the app module, so it is restated here; the
/// on-screen 「無料では勉強アプリを5つまで選べます」 string the limits phase asserts
/// is what keeps the two honest.
private let screenTimeFreeLearningLimit = 5

/// Opt-in audit of the shipping Screen Time surface on a real, explicitly
/// authorized iPhone. Family Controls individual authorization, Apple's
/// FamilyActivityPicker and DeviceActivity threshold delivery cannot be
/// exercised in the Simulator, so every phase refuses to run there.
///
/// Set these in the UI TEST RUNNER's environment (xcodebuild
/// TEST_RUNNER_… variables, or EnvironmentVariables in a private .xctestrun).
/// No audit flag is ever passed to the application: it is launched with an
/// empty launch environment and no launch arguments, exactly as it ships.
///
///   POMOGEM_REAL_SCREEN_TIME_AUDIT=1                (required opt-in)
///   POMOGEM_REAL_SCREEN_TIME_PHASE=<phase>          (required, one per run)
///   POMOGEM_REAL_SCREEN_TIME_APPS_LEARNING=計算機,メモ
///   POMOGEM_REAL_SCREEN_TIME_APPS_DISTRACTION=時計
///        Comma-separated application DISPLAY NAMES to tick in Apple's
///        FamilyActivityPicker. Use Apple built-ins only.
///   POMOGEM_REAL_SCREEN_TIME_THEME=<theme display name>
///        Theme to record learning gems into. Absent ⇒ the first theme.
///   POMOGEM_REAL_SCREEN_TIME_USAGE_BUNDLE_IDS=com.apple.calculator,com.apple.mobilenotes
///        Bundle ids of the SAME apps, for the usage phases. The usage phase
///        splits its minutes evenly across them.
///   POMOGEM_REAL_SCREEN_TIME_USAGE_MINUTES=11       (default 11, ≥10 required)
///   POMOGEM_REAL_SCREEN_TIME_STORAGE_ACTION=none|retry|offline-continue
///        What to do when the app opens on 「保存領域を確認できません」.
///        none (default) stops with evidence; retry taps 「もう一度試す」 once
///        and waits ≤90 s; offline-continue taps cloud-offline-continue.
///
/// Phases (POMOGEM_REAL_SCREEN_TIME_PHASE), one xcodebuild run each:
///   probe             read-only reconnaissance of the settings screen, the
///                     authorization prompt and the picker (unchanged from W1).
///   dump              records the Screen Time settings screen only. Taps
///                     nothing but the navigation needed to reach it.
///   baseline    (P0)  Home totals + full settings state. Reports stale
///                     selections/black gems; never resets (run `reset`).
///   authorize   (P1)  drives Apple's Family Controls prompt to an
///                     affirmative answer; asserts アクセス許可済み.
///   limits      (P2)  free 5-app ceiling, category/Web rejection, same-app
///                     cross-lane rejection. Always cancels, never 反映s.
///   save        (P3)  picks theme + both lanes, saves, MEASURES the time to
///                     screen-time.updating appearing (<1.5 s) and vanishing,
///                     asserts back navigation stays hittable, then saves
///                     twice in rapid succession and asserts no duplicate
///                     registration error and at most one toast.
///   usage-learning   (P4) foregrounds the learning apps for the configured
///                     minutes, then polls ≤20 min for exactly one +1粒/+100 g
///                     step, then 5 more minutes for a forbidden second step.
///   usage-distraction(P5) same for the black-gem lane; expects
///                     screen-time.negative-total to grow by exactly one
///                     「10分 × 1個ぶん」 step.
///   timer-pause (P6)  starts a real 25-minute timer, records that the focus
///                     screen is interactive-dismiss-disabled (so the paused
///                     status string is unreachable from XCUITest), cancels
///                     it and asserts the learning lane re-registers.
///   relaunch    (P7)  terminates and relaunches twice; selections, totals and
///                     status must be unchanged and no import alert may appear.
///   revoke      (P8)  drives iOS 設定 → スクリーンタイム, toggles PomoGem's
///                     Screen Time access OFF, verifies the revoked state in
///                     PomoGem, then restores the toggle to ON.
///   reset       (P9)  the in-app 「スクリーンタイムの内容をリセット」 flow.
///
/// Operator steps
///  1. Unlock the phone and keep it unlocked and connected; do not run
///     iPhone Mirroring at the same time.
///  2. Install the development-signed build and run ONE phase per xcodebuild
///     invocation, in the order above, with -resultBundlePath set.
///  3. Screenshots, accessibility hierarchies and a text transcript are
///     attached with .keepAlways; export them from the .xcresult.
///  4. A phase whose precondition is not met XCTSkips WITH the evidence
///     attached. Only genuine app misbehaviour XCTFails. A skipped phase is
///     never evidence that the behaviour works.
///  5. This suite never enters a passcode. If any secure field or passcode UI
///     appears it screenshots it and skips with "needs human".
///  6. After `revoke`, confirm by hand that PomoGem's Screen Time access
///     toggle is back ON in iOS Settings.
@MainActor
final class RealDeviceScreenTimeUITests: XCTestCase {
    private enum Phase: String, CaseIterable {
        case probe
        case dump
        case baseline
        case authorize
        case limits
        case save
        case usageLearning = "usage-learning"
        case usageDistraction = "usage-distraction"
        case timerPause = "timer-pause"
        case relaunch
        case revoke
        case reset
    }

    private enum StorageAction: String {
        case none
        case retry
        case offlineContinue = "offline-continue"
    }

    private enum Lane {
        case learning
        case distraction

        var identifier: String {
            self == .learning ? "screen-time.learning-apps" : "screen-time.distraction-apps"
        }
        var title: String { self == .learning ? "勉強のgem" : "黒いgem" }
    }

    private enum AuditFailure: Error { case stopped }

    private struct HomeTotals {
        var pebbles: Int
        var grams: Int
        var gramsAreExact: Bool
        var menuLabel: String
        var jarValue: String

        var summary: String {
            "pebbles=\(pebbles) grams=\(grams)\(gramsAreExact ? "" : " (rounded kg — not exact)") menu=\"\(menuLabel)\" jar=\"\(jarValue)\""
        }
    }

    private static let springboardID = "com.apple.springboard"
    private static let preferencesID = "com.apple.Preferences"
    private static let affirmatives = ["続ける", "Continue", "許可", "Allow", "OK", "はい", "Yes"]

    private var app: XCUIApplication?
    private var phase: Phase?
    private var learningAppNames: [String] = []
    private var distractionAppNames: [String] = []
    private var themeName: String?
    private var usageBundleIDs: [String] = []
    private var usageMinutes = 11
    private var storageAction: StorageAction = .none
    private var transcript: [String] = []
    private var attachmentIndex = 0
    /// Set only while this suite is deliberately driving a SpringBoard-owned
    /// prompt it is allowed to answer (Apple's Family Controls authorization
    /// prompt). While it is set, the system-modal probe stays silent so the
    /// authorization step is not skipped by its own prompt.
    private var isDrivingSystemPrompt = false

    // MARK: - opt-in

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Usage phases foreground another app for ~11 minutes and then poll
        // PomoGem for up to 25 more. 3600 s is xcodebuild's default ceiling.
        executionTimeAllowance = 3_600
#if targetEnvironment(simulator)
        throw XCTSkip("Real Screen Time auditing requires an explicitly authorized physical iPhone.")
#else
        let environment = ProcessInfo.processInfo.environment
        guard environment["POMOGEM_REAL_SCREEN_TIME_AUDIT"] == "1" else {
            throw XCTSkip("Set POMOGEM_REAL_SCREEN_TIME_AUDIT=1 in the test runner to opt in.")
        }
        let permittedKeys: Set<String> = [
            "POMOGEM_REAL_SCREEN_TIME_AUDIT",
            "POMOGEM_REAL_SCREEN_TIME_PHASE",
            "POMOGEM_REAL_SCREEN_TIME_APPS_LEARNING",
            "POMOGEM_REAL_SCREEN_TIME_APPS_DISTRACTION",
            "POMOGEM_REAL_SCREEN_TIME_THEME",
            "POMOGEM_REAL_SCREEN_TIME_USAGE_BUNDLE_IDS",
            "POMOGEM_REAL_SCREEN_TIME_USAGE_MINUTES",
            "POMOGEM_REAL_SCREEN_TIME_STORAGE_ACTION"
        ]
        let unexpectedFlags = environment.keys.filter {
            ($0.hasPrefix("POMOGEM_") && !permittedKeys.contains($0))
                || $0 == "XCODE_RUNNING_FOR_PREVIEWS"
                || $0 == "StoreKitConfigurationFile"
        }
        guard unexpectedFlags.isEmpty else {
            XCTFail("Remove preview, mock, and fixture flags from the runner environment: \(unexpectedFlags.sorted()).")
            throw AuditFailure.stopped
        }
        phase = Phase(rawValue: environment["POMOGEM_REAL_SCREEN_TIME_PHASE"] ?? "")
        guard phase != nil else {
            XCTFail("Choose one runner phase: \(Phase.allCases.map(\.rawValue).joined(separator: ", ")).")
            throw AuditFailure.stopped
        }
        learningAppNames = Self.list(environment["POMOGEM_REAL_SCREEN_TIME_APPS_LEARNING"])
        distractionAppNames = Self.list(environment["POMOGEM_REAL_SCREEN_TIME_APPS_DISTRACTION"])
        usageBundleIDs = Self.list(environment["POMOGEM_REAL_SCREEN_TIME_USAGE_BUNDLE_IDS"])
        let theme = environment["POMOGEM_REAL_SCREEN_TIME_THEME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        themeName = (theme?.isEmpty == false) ? theme : nil
        if let raw = environment["POMOGEM_REAL_SCREEN_TIME_USAGE_MINUTES"] {
            guard let minutes = Int(raw.trimmingCharacters(in: .whitespaces)), minutes >= 10, minutes <= 60 else {
                XCTFail("POMOGEM_REAL_SCREEN_TIME_USAGE_MINUTES must be an integer between 10 and 60: \(raw).")
                throw AuditFailure.stopped
            }
            usageMinutes = minutes
        }
        if let raw = environment["POMOGEM_REAL_SCREEN_TIME_STORAGE_ACTION"] {
            guard let action = StorageAction(rawValue: raw.trimmingCharacters(in: .whitespaces)) else {
                XCTFail("POMOGEM_REAL_SCREEN_TIME_STORAGE_ACTION must be none, retry or offline-continue: \(raw).")
                throw AuditFailure.stopped
            }
            storageAction = action
        }
#endif
    }

    override func tearDownWithError() throws {
        flushTranscript()
        app?.terminate()
        app = nil
    }

    private static func list(_ raw: String?) -> [String] {
        (raw ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - probe (W1 reconnaissance, unchanged contract)

    func testProbeScreenTimeAuthorizationAndPickerSurface() throws {
        try select(.probe)
        let app = launchRealApplication()

        try reachHome(app)

        try openScreenTimeSettings(app)
        let statusBefore = recordSettingsState(app, label: "before")
        recordThemePickerOptions(app)

        var statusAfter = statusBefore
        if statusBefore.contains("許可が必要") || app.buttons["screen-time.authorize"].exists {
            try driveAuthorizationPrompt(app)
            statusAfter = recordSettingsState(app, label: "after-authorization-attempt")
        } else {
            note("authorization step SKIPPED: the app reports permission is already granted.")
        }

        probeLearningPicker(app)

        note("PROBE COMPLETE. authorizationBefore=\(statusBefore) authorizationAfter=\(statusAfter)")
        capture("probe-final")
    }

    // MARK: - dump

    func testDumpScreenTimeSettingsScreen() throws {
        try select(.dump)
        let app = launchRealApplication()
        try reachHome(app)
        try openScreenTimeSettings(app)
        recordSettingsState(app, label: "dump")
        inventory(app, name: "dump-settings")
        note("DUMP COMPLETE: the settings screen was recorded and nothing was changed.")
    }

    // MARK: - P0 baseline

    func testBaselineScreenTimeState() throws {
        try select(.baseline)
        let app = launchRealApplication()
        try reachHome(app)

        let totals = readHomeTotals(app, label: "baseline")
        note("BASELINE Home totals: \(totals.summary)")

        try openScreenTimeSettings(app)
        let status = recordSettingsState(app, label: "baseline")
        recordThemePickerOptions(app)

        let learning = selectionCount(app, lane: .learning)
        let distraction = selectionCount(app, lane: .distraction)
        let blackGems = negativeGemCount(app)
        note("BASELINE authorization=\(status) learningApps=\(describeCount(learning)) distractionApps=\(describeCount(distraction)) blackGems=\(describeCount(blackGems))")

        let isStale = (learning ?? 0) > 0 || (distraction ?? 0) > 0 || (blackGems ?? 0) > 0
        if isStale {
            note("BASELINE: this installation already carries Screen Time state. Run the `reset` phase before the audit so the later increments are unambiguous. This phase never resets on its own.")
        } else {
            note("BASELINE: no stored selections and no black gems — a clean starting point.")
        }
        note("BASELINE COMPLETE. stale=\(isStale)")
    }

    // MARK: - P1 authorize

    func testAuthorizeFamilyControlsIndividualAccess() throws {
        try select(.authorize)
        let app = launchRealApplication()
        try reachHome(app)
        try openScreenTimeSettings(app)
        let before = recordSettingsState(app, label: "authorize-before")

        guard before.contains("許可が必要") || app.buttons["screen-time.authorize"].exists else {
            note("AUTHORIZE: the app already reports granted access, so Apple's prompt cannot be re-shown from here.")
            try require(before.contains("許可済み"),
                        "The status text must state granted access when the authorize button is absent: \(before).",
                        evidence: "authorize-inconsistent")
            try skipWithEvidence("authorize-already-granted",
                                 "Screen Time access is already granted on this device; the authorization prompt cannot be exercised without revoking it first (run the `revoke` phase).")
        }

        try driveAuthorizationPrompt(app)
        let status = app.staticTexts["screen-time.authorization-status"]
        let granted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", "許可済み"),
            object: status
        )
        let settled = XCTWaiter.wait(for: [granted], timeout: 40) == .completed
        let after = recordSettingsState(app, label: "authorize-after")

        guard settled else {
            note("AUTHORIZE: the app still reports \(after) after an affirmative answer. This is either an app defect or an Apple-account level refusal (managed/child account, Screen Time disabled).")
            try require(false,
                        "After an affirmative answer to Apple's Family Controls prompt the app must report アクセス許可済み; it reports \(after). Check screen-time.monitoring-error in the attachments before calling this an app defect.",
                        evidence: "authorize-not-granted")
            throw AuditFailure.stopped
        }

        let toggle = app.switches["screen-time.enabled"]
        _ = reveal(toggle)
        try require(toggle.exists && toggle.isEnabled,
                    "screen-time.enabled must become operable once access is granted.",
                    evidence: "authorize-toggle")
        try require(!app.staticTexts["screen-time.monitoring-error"].exists,
                    "Granting access must not leave a monitoring error: \(app.staticTexts["screen-time.monitoring-error"].label).",
                    evidence: "authorize-error")
        note("AUTHORIZE PASS: status=\(after), screen-time.enabled operable, no monitoring error.")
    }

    // MARK: - P2 limits

    func testSelectionLimitsAndValidation() throws {
        try select(.limits)
        let app = launchRealApplication()
        try reachHome(app)
        try openScreenTimeSettings(app)
        let status = recordSettingsState(app, label: "limits-before")
        guard status.contains("許可済み") else {
            try skipWithEvidence("limits-not-authorized",
                                 "Screen Time access is not granted (\(status)); run the `authorize` phase first.")
        }
        guard learningAppNames.count >= 6 else {
            try skipWithEvidence("limits-not-enough-apps",
                                 "POMOGEM_REAL_SCREEN_TIME_APPS_LEARNING lists \(learningAppNames.count) app(s); the free-tier ceiling check needs 6 distinct display names.")
        }

        try openPicker(app, lane: .learning)
        let apply = app.buttons["screen-time.picker-apply"]
        var ticked: [String] = []
        for name in learningAppNames.prefix(6) {
            if tickApplication(app, named: name) { ticked.append(name) }
        }
        inventory(app, name: "limits-six-selected")
        capture("limits-six-selected")
        dumpHierarchy(app, name: "limits-six-selected")
        note("LIMITS: ticked \(ticked.count)/6 requested apps: \(ticked.joined(separator: " | "))")

        guard ticked.count >= 6 else {
            cancelPicker(app)
            try skipWithEvidence("limits-picker-not-addressable",
                                 "Only \(ticked.count) of 6 applications could be ticked in Apple's FamilyActivityPicker from XCUITest (remote view). Hand the 6-app ceiling check to a human or drive it through iPhone Mirroring. Ticked: \(ticked.joined(separator: ", ")).")
        }
        // The sheet seeds from the saved selection, so the app's own counter —
        // not the number of taps — decides whether the ceiling is exceeded.
        let selectedInSheet = pickerSelectionCount(app)
        note("LIMITS: the sheet reports \(describeCount(selectedInSheet)) selected app(s).")
        guard let selectedInSheet, selectedInSheet > screenTimeFreeLearningLimit else {
            cancelPicker(app)
            try skipWithEvidence("limits-selection-not-over-ceiling",
                                 "The picker sheet reports \(describeCount(selectedInSheet)) selected app(s) after ticking \(ticked.count); the free-tier ceiling is \(screenTimeFreeLearningLimit) and cannot be judged from that state.")
        }

        let overLimitMessage = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "無料では勉強アプリを5つまで選べます")
        ).firstMatch
        try require(overLimitMessage.waitForExistence(timeout: 5),
                    "Six learning apps must raise 「無料では勉強アプリを5つまで選べます…」 in the picker.",
                    evidence: "limits-message-missing")
        try require(apply.exists && !apply.isEnabled,
                    "反映 (screen-time.picker-apply) must be disabled while the free learning ceiling is exceeded.",
                    evidence: "limits-apply-enabled")
        note("LIMITS PASS: 6 learning apps ⇒ 反映 disabled + free-tier message shown.")

        // Back down to the ceiling: the picker must become applicable again.
        var removed = false
        var remaining = selectedInSheet
        for name in ticked.reversed() where remaining > screenTimeFreeLearningLimit {
            guard untickApplication(app, named: name) else { continue }
            removed = true
            remaining = pickerSelectionCount(app) ?? remaining
        }
        note("LIMITS: unticked down to \(remaining) app(s); anyRemoved=\(removed)")
        if removed, remaining == screenTimeFreeLearningLimit {
            let enabled = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "enabled == true"), object: apply
            )
            try require(XCTWaiter.wait(for: [enabled], timeout: 8) == .completed,
                        "Reducing the learning selection to five apps must re-enable 反映.",
                        evidence: "limits-apply-still-disabled")
            try require(!overLimitMessage.exists,
                        "The free-tier message must disappear once five apps remain.",
                        evidence: "limits-message-sticky")
            note("LIMITS PASS: \(remaining) learning apps ⇒ 反映 enabled, message cleared.")
        } else {
            note("LIMITS PENDING: the ≤\(screenTimeFreeLearningLimit) recovery could not be driven from XCUITest; the sheet still reports \(remaining) selected app(s).")
        }

        // Category / Web selection must be refused.
        if selectWholeCategory(app) {
            let categoryMessage = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "カテゴリやWebサイトは選べません")
            ).firstMatch
            try require(categoryMessage.waitForExistence(timeout: 5),
                        "Selecting a whole category must raise 「カテゴリやWebサイトは選べません…」.",
                        evidence: "limits-category-message-missing")
            try require(apply.exists && !apply.isEnabled,
                        "反映 must be disabled while a category or Web domain is selected.",
                        evidence: "limits-category-apply-enabled")
            note("LIMITS PASS: whole-category selection ⇒ 反映 disabled + category message.")
        } else {
            capture("limits-category-not-addressable")
            note("LIMITS PENDING: no whole-category control was addressable in the remote picker; the category rejection path is unverified.")
        }

        cancelPicker(app)
        recordSettingsState(app, label: "limits-after-cancel")

        // Same app in both lanes must be refused. This needs a stored
        // distraction selection, i.e. the `save` phase must have run.
        let distractionCount = selectionCount(app, lane: .distraction)
        if let count = distractionCount, count > 0, let conflicting = distractionAppNames.first {
            try openPicker(app, lane: .learning)
            let tickedConflict = tickApplication(app, named: conflicting)
            if tickedConflict {
                let conflictMessage = app.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS %@", "同じアプリを勉強のgemと黒いgemの両方には登録できません")
                ).firstMatch
                try require(conflictMessage.waitForExistence(timeout: 5),
                            "Selecting \(conflicting) — already in the black-gem lane — must raise the cross-lane conflict message.",
                            evidence: "limits-conflict-message-missing")
                try require(apply.exists && !apply.isEnabled,
                            "反映 must be disabled while the same app is in both lanes.",
                            evidence: "limits-conflict-apply-enabled")
                note("LIMITS PASS: \(conflicting) in both lanes ⇒ 反映 disabled + conflict message.")
            } else {
                note("LIMITS PENDING: \(conflicting) could not be ticked, so the cross-lane conflict is unverified.")
            }
            cancelPicker(app)
        } else {
            note("LIMITS PENDING: the black-gem lane holds \(describeCount(distractionCount)) apps, so the cross-lane conflict check has no counterpart. Run `save` first.")
        }

        let after = recordSettingsState(app, label: "limits-final")
        try require(after.contains("許可済み"),
                    "The limits phase must not disturb the authorization state.",
                    evidence: "limits-authorization-changed")
        note("LIMITS COMPLETE. Nothing was applied: every picker was cancelled.")
    }

    // MARK: - P3 save

    func testSaveRegistersWithoutBlockingTheSettingsScreen() throws {
        try select(.save)
        guard !learningAppNames.isEmpty || !distractionAppNames.isEmpty else {
            throw XCTSkip("Set POMOGEM_REAL_SCREEN_TIME_APPS_LEARNING and/or POMOGEM_REAL_SCREEN_TIME_APPS_DISTRACTION for the save phase.")
        }
        let app = launchRealApplication()
        try reachHome(app)
        try openScreenTimeSettings(app)
        let status = recordSettingsState(app, label: "save-before")
        guard status.contains("許可済み") else {
            try skipWithEvidence("save-not-authorized",
                                 "Screen Time access is not granted (\(status)); run the `authorize` phase first.")
        }

        // Selections first: everything stays a draft until 保存.
        var learningTicked: [String] = []
        if !learningAppNames.isEmpty {
            try openPicker(app, lane: .learning)
            for name in learningAppNames.prefix(5) where tickApplication(app, named: name) {
                learningTicked.append(name)
            }
            capture("save-learning-picked")
            dumpHierarchy(app, name: "save-learning-picked")
            if learningTicked.isEmpty {
                cancelPicker(app)
                try skipWithEvidence("save-learning-not-addressable",
                                     "No learning application could be ticked in Apple's FamilyActivityPicker from XCUITest. The save phase needs a real selection; hand the picking step to a human.")
            }
            try applyPicker(app)
            note("SAVE: learning lane drafted with \(learningTicked.joined(separator: " | "))")
        }

        var distractionTicked: [String] = []
        if !distractionAppNames.isEmpty {
            try openPicker(app, lane: .distraction)
            for name in distractionAppNames where tickApplication(app, named: name) {
                distractionTicked.append(name)
            }
            capture("save-distraction-picked")
            dumpHierarchy(app, name: "save-distraction-picked")
            if distractionTicked.isEmpty {
                cancelPicker(app)
                note("SAVE PENDING: no black-gem application could be ticked; continuing with the learning lane only.")
            } else {
                try applyPicker(app)
                note("SAVE: black-gem lane drafted with \(distractionTicked.joined(separator: " | "))")
            }
        }

        if !learningTicked.isEmpty {
            let picked = try selectRecordingTheme(app)
            note("SAVE: recording theme = \(picked)")
        }
        try setRecordingToggle(app, on: true)

        // --- measured save #1 -------------------------------------------------
        let save = app.buttons["screen-time.save"]
        _ = reveal(save)
        try require(save.exists && save.isEnabled,
                    "保存 must be enabled once a valid draft exists. Validation footer: \(validationFooter(app)).",
                    evidence: "save-disabled")

        let updating = app.descendants(matching: .any)["screen-time.updating"].firstMatch
        let start = Date()
        save.tap()

        var appearedAfter: TimeInterval?
        var sawBackButtonHittableWhileUpdating = false
        while Date().timeIntervalSince(start) < 6 {
            if updating.exists {
                appearedAfter = Date().timeIntervalSince(start)
                break
            }
        }
        if let appearedAfter {
            note(String(format: "SAVE MEASUREMENT: screen-time.updating appeared %.3f s after tapping 保存.", appearedAfter))
            attach(string: String(format: "%.3f", appearedAfter), name: "save-updating-appeared-seconds")
            let backButton = app.navigationBars["スクリーンタイム"].buttons.firstMatch
            sawBackButtonHittableWhileUpdating = backButton.exists && backButton.isEnabled && backButton.isHittable
            note("SAVE: while updating — back button exists=\(backButton.exists) hittable=\(sawBackButtonHittableWhileUpdating) label=\(backButton.exists ? backButton.label : "-"); 保存 enabled=\(save.isEnabled); リセット enabled=\(app.buttons["screen-time.reset"].isEnabled)")
            capture("save-updating-visible")
        } else {
            note("SAVE MEASUREMENT: screen-time.updating was never sampled within 6 s. Either registration completed faster than XCUITest could poll, or the row never appeared — see the following state.")
            attach(string: "not-observed", name: "save-updating-appeared-seconds")
            capture("save-updating-not-observed")
        }

        let disappeared = Date()
        var vanishedAfter: TimeInterval?
        if appearedAfter != nil {
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: updating)
            let finished = XCTWaiter.wait(for: [gone], timeout: 180) == .completed
            vanishedAfter = Date().timeIntervalSince(start)
            note(String(format: "SAVE MEASUREMENT: screen-time.updating vanished=%@ after %.3f s (wait started %.3f s in).",
                        finished ? "true" : "false",
                        vanishedAfter ?? -1,
                        disappeared.timeIntervalSince(start)))
            attach(string: String(format: "%.3f", vanishedAfter ?? -1), name: "save-updating-vanished-seconds")
            try require(finished,
                        "screen-time.updating must clear within 180 s; the registration worker appears stuck.",
                        evidence: "save-updating-stuck")
        }

        if let appearedAfter {
            try require(appearedAfter < 1.5,
                        String(format: "screen-time.updating must appear within 1.5 s of tapping 保存; it took %.3f s.", appearedAfter),
                        evidence: "save-updating-late")
            try require(sawBackButtonHittableWhileUpdating,
                        "The navigation bar back button must stay hittable while the registration runs — that is the point of PR #24.",
                        evidence: "save-back-blocked")
        }

        try require(!app.alerts["設定を完了できませんでした"].exists,
                    "The first save must not raise 「設定を完了できませんでした」: \(alertMessage(app)).",
                    evidence: "save-error-alert")
        try waitForToastToClear(app)

        // --- duplicate save: two taps in rapid succession ---------------------
        _ = reveal(save)
        let toast = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "スクリーンタイムの設定を保存しました")
        ).firstMatch
        try require(save.exists && save.isEnabled,
                    "保存 must be re-enabled after a completed registration.",
                    evidence: "save-not-reenabled")
        note("SAVE: tapping 保存 twice in rapid succession.")
        save.tap()
        let secondTapWasOffered = save.exists && save.isEnabled && save.isHittable
        if secondTapWasOffered { save.tap() }
        note("SAVE: the second tap was \(secondTapWasOffered ? "delivered (保存 was still enabled)" : "refused (保存 was already disabled — duplicate prevention)").")

        var toastEdges = 0
        var toastWasVisible = false
        let toastDeadline = Date().addingTimeInterval(45)
        while Date() < toastDeadline {
            let visible = toast.exists
            if visible && !toastWasVisible { toastEdges += 1 }
            toastWasVisible = visible
            if app.alerts["設定を完了できませんでした"].exists { break }
            pause(0.25)
        }
        capture("save-duplicate-settled")
        try guardAgainstSystemAlert("save-duplicate-window")
        note("SAVE: toast appearances observed during the duplicate window = \(toastEdges).")
        attach(string: "\(toastEdges)", name: "save-duplicate-toast-count")

        try require(!app.alerts["設定を完了できませんでした"].exists,
                    "A duplicate 保存 must not raise a registration error: \(alertMessage(app)).",
                    evidence: "save-duplicate-error-alert")
        try require(toastEdges <= 1,
                    "A duplicate 保存 must show at most one 「スクリーンタイムの設定を保存しました」 toast; \(toastEdges) were observed.",
                    evidence: "save-duplicate-toasts")

        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: updating)
        _ = XCTWaiter.wait(for: [gone], timeout: 180)
        try guardAgainstSystemAlert("save-updating-settled")
        let final = recordSettingsState(app, label: "save-after")
        let monitoring = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "自動記録中")).firstMatch
        try require(monitoring.waitForExistence(timeout: 30),
                    "After a successful save the status must read 自動記録中 (or 黒いgemを自動記録中); the screen shows \(final).",
                    evidence: "save-not-monitoring")
        note("SAVE: final monitoring status = \(monitoring.label)")
        try require(!app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "自動記録は停止中です")).firstMatch.exists,
                    "Monitoring must not report 自動記録は停止中です after a successful save.",
                    evidence: "save-stopped")
        try require(!app.staticTexts["screen-time.monitoring-error"].exists,
                    "A successful save must leave no screen-time.monitoring-error: \(app.staticTexts["screen-time.monitoring-error"].label).",
                    evidence: "save-monitoring-error")
        try require(save.isEnabled,
                    "保存 must be re-enabled once the registration has settled.",
                    evidence: "save-left-disabled")
        note("SAVE COMPLETE. learning=\(describeCount(selectionCount(app, lane: .learning))) distraction=\(describeCount(selectionCount(app, lane: .distraction)))")
    }

    // MARK: - P4 usage (learning lane)

    func testLearningUsageAccruesExactlyOneGem() throws {
        try select(.usageLearning)
        guard !usageBundleIDs.isEmpty else {
            throw XCTSkip("Set POMOGEM_REAL_SCREEN_TIME_USAGE_BUNDLE_IDS to the bundle ids of the learning apps.")
        }
        let app = launchRealApplication()
        try reachHome(app)
        try openScreenTimeSettings(app)
        let status = recordSettingsState(app, label: "usage-learning-before")
        guard status.contains("許可済み") else {
            try skipWithEvidence("usage-learning-not-authorized", "Screen Time access is not granted (\(status)).")
        }
        let learning = selectionCount(app, lane: .learning)
        guard let learning, learning > 0 else {
            try skipWithEvidence("usage-learning-no-selection",
                                 "The learning lane holds \(describeCount(learning)) apps; run the `save` phase first.")
        }
        try require(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "自動記録中")).firstMatch.exists,
                    "The learning usage phase requires active monitoring before the usage window.",
                    evidence: "usage-learning-not-monitoring")
        try returnToHome(app, from: "スクリーンタイム")

        let before = readHomeTotals(app, label: "usage-learning-before")
        note("USAGE-LEARNING baseline: \(before.summary)")

        try burnUsage(app, label: "usage-learning")

        let change = try pollForHomeTotalsChange(app, baseline: before, minutes: 20)
        note("USAGE-LEARNING first change after \(Int(change.1)) s: \(change.0.summary)")
        try require(change.0.pebbles == before.pebbles + 1,
                    "Ten minutes of combined learning-app usage must add exactly one gem: \(before.pebbles) → \(change.0.pebbles).",
                    evidence: "usage-learning-wrong-step")
        if before.gramsAreExact && change.0.gramsAreExact {
            try require(change.0.grams == before.grams + 100,
                        "A 10-minute learning gem must weigh exactly 100 g: \(before.grams) g → \(change.0.grams) g.",
                        evidence: "usage-learning-wrong-mass")
        } else {
            note("USAGE-LEARNING: the Home mass readout is rounded to 0.01 kg at this total, so the +100 g step is recorded but not asserted (before=\(before.grams) after=\(change.0.grams)).")
        }

        let second = try pollForHomeTotalsChange(app, baseline: change.0, minutes: 5, expectNone: true)
        try require(second == nil,
                    "A single 10-minute usage window must not produce a second gem: \(second?.0.summary ?? "").",
                    evidence: "usage-learning-double-count")
        note("USAGE-LEARNING PASS: exactly one +1粒 step, no second increment in the following 5 minutes.")
        note("USAGE-LEARNING NOTE: Home exposes device-wide totals only (jar value + メニュー summary). Per-theme attribution of this gem must be confirmed from 積み上がり or the record log by a human.")
    }

    // MARK: - P5 usage (black gem lane)

    func testDistractionUsageAccruesExactlyOneBlackGem() throws {
        try select(.usageDistraction)
        guard !usageBundleIDs.isEmpty else {
            throw XCTSkip("Set POMOGEM_REAL_SCREEN_TIME_USAGE_BUNDLE_IDS to the bundle ids of the black-gem apps.")
        }
        let app = launchRealApplication()
        try reachHome(app)
        let homeBefore = readHomeTotals(app, label: "usage-distraction-home-before")
        try openScreenTimeSettings(app)
        let status = recordSettingsState(app, label: "usage-distraction-before")
        guard status.contains("許可済み") else {
            try skipWithEvidence("usage-distraction-not-authorized", "Screen Time access is not granted (\(status)).")
        }
        let distraction = selectionCount(app, lane: .distraction)
        guard let distraction, distraction > 0 else {
            try skipWithEvidence("usage-distraction-no-selection",
                                 "The black-gem lane holds \(describeCount(distraction)) apps; run the `save` phase first.")
        }
        guard let baseline = negativeGemCount(app) else {
            try skipWithEvidence("usage-distraction-no-total",
                                 "screen-time.negative-total could not be read, so an increment cannot be measured.")
        }
        note("USAGE-DISTRACTION baseline: blackGems=\(baseline) homeTotals=\(homeBefore.summary)")

        try burnUsage(app, label: "usage-distraction")

        // The settings screen re-reads the controller on every foreground.
        let change = try pollForNegativeTotalChange(app, baseline: baseline, minutes: 20)
        note("USAGE-DISTRACTION first change after \(Int(change.1)) s: blackGems=\(change.0)")
        try require(change.0 == baseline + 1,
                    "Ten minutes of combined black-gem-app usage must add exactly one black gem: \(baseline) → \(change.0).",
                    evidence: "usage-distraction-wrong-step")
        if baseline == 0 {
            let label = app.staticTexts["screen-time.negative-total"].label
            try require(label.contains("10分 × 1個ぶん"),
                        "screen-time.negative-total must read 「10分 × 1個ぶん」 after the first black gem; it reads \(label).",
                        evidence: "usage-distraction-wrong-text")
            note("USAGE-DISTRACTION: negative-total label = \(label)")
        }

        let second = try pollForNegativeTotalChange(app, baseline: change.0, minutes: 5, expectNone: true)
        try require(second == nil,
                    "A single 10-minute usage window must not produce a second black gem: \(second.map { "\($0.0)" } ?? "").",
                    evidence: "usage-distraction-double-count")

        try returnToHome(app, from: "スクリーンタイム")
        let homeAfter = readHomeTotals(app, label: "usage-distraction-home-after")
        try require(homeAfter.pebbles == homeBefore.pebbles,
                    "A black gem must not change the study totals on Home: \(homeBefore.pebbles) → \(homeAfter.pebbles).",
                    evidence: "usage-distraction-home-changed")
        note("USAGE-DISTRACTION PASS: exactly one black gem, no second increment, Home study totals unchanged (\(homeAfter.summary)).")
    }

    // MARK: - P6 timer pause

    func testTimerPausesTheLearningLane() throws {
        try select(.timerPause)
        let app = launchRealApplication()
        try reachHome(app)
        try openScreenTimeSettings(app)
        let status = recordSettingsState(app, label: "timer-pause-before")
        guard status.contains("許可済み") else {
            try skipWithEvidence("timer-pause-not-authorized", "Screen Time access is not granted (\(status)).")
        }
        let monitoring = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "自動記録中")).firstMatch
        guard monitoring.exists else {
            try skipWithEvidence("timer-pause-not-monitoring",
                                 "The timer phase requires active monitoring (自動記録中) before starting a timer; the screen shows \(status).")
        }
        note("TIMER-PAUSE: status before the timer = \(monitoring.label)")
        try returnToHome(app, from: "スクリーンタイム")

        let timer = app.descendants(matching: .any)["focus.timer-display"].firstMatch
        guard !timer.exists else {
            try skipWithEvidence("timer-pause-timer-running",
                                 "A focus timer is already running; the timer phase must begin from a quiet Home.")
        }
        if let themeName { try selectHomeTheme(app, named: themeName) }
        try startTwentyFiveMinuteTimer(app)
        capture("timer-pause-running")
        dumpHierarchy(app, name: "timer-pause-running")

        // The focus screen is presented as an interactive-dismiss-disabled
        // fullScreenCover with no affordance back to Home, so the paused
        // status string on the Screen Time settings screen is genuinely
        // unreachable from XCUITest while a timer runs.
        let escapes = ["メニュー", "設定", "閉じる", "戻る", "瓶へ戻る", "ホーム"]
        let reachable = escapes.filter { app.buttons[$0].exists && app.buttons[$0].isHittable }
        note("TIMER-PAUSE: affordances back to Home while the timer runs = \(reachable.isEmpty ? "<none>" : reachable.joined(separator: " | "))")

        try cancelTimer(app)
        try openScreenTimeSettings(app)
        let after = recordSettingsState(app, label: "timer-pause-after")
        let resumed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "自動記録中")).firstMatch
        try require(resumed.waitForExistence(timeout: 60),
                    "After the timer is cancelled the learning lane must re-register and the status must return to 自動記録中; the screen shows \(after).",
                    evidence: "timer-pause-not-resumed")
        try require(!app.staticTexts.matching(
                        NSPredicate(format: "label CONTAINS %@", "タイマーの計測中は、勉強アプリの自動記録を休止しています")
                    ).firstMatch.exists,
                    "The timer-pause notice must disappear once no timer is running.",
                    evidence: "timer-pause-notice-sticky")
        try require(!app.staticTexts["screen-time.monitoring-error"].exists,
                    "Re-registration after a cancelled timer must not raise a monitoring error: \(app.staticTexts["screen-time.monitoring-error"].label).",
                    evidence: "timer-pause-error")
        note("TIMER-PAUSE: post-timer status = \(resumed.label), no monitoring error.")

        if reachable.isEmpty {
            try skipWithEvidence("timer-pause-paused-state-unreachable",
                                 "PASSED the post-timer half (自動記録中 restored, no monitoring error) but the paused half is UNVERIFIED: FocusView is an interactive-dismiss-disabled fullScreenCover with no route back to Home, so 「タイマーの計測中は、勉強アプリの自動記録を休止しています。」 and 「黒いgemを自動記録中」 cannot be observed from XCUITest while a timer runs. Drive that half through iPhone Mirroring or by hand.")
        }
        note("TIMER-PAUSE COMPLETE.")
    }

    // MARK: - P7 relaunch

    func testStateSurvivesTwoRelaunches() throws {
        try select(.relaunch)
        let app = launchRealApplication()
        try reachHome(app)
        let homeBefore = readHomeTotals(app, label: "relaunch-before")
        try openScreenTimeSettings(app)
        let statusBefore = recordSettingsState(app, label: "relaunch-0")
        guard statusBefore.contains("許可済み") else {
            try skipWithEvidence("relaunch-not-authorized", "Screen Time access is not granted (\(statusBefore)).")
        }
        let learningBefore = selectionCount(app, lane: .learning)
        let distractionBefore = selectionCount(app, lane: .distraction)
        let blackBefore = negativeGemCount(app)
        let monitoringBefore = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "自動記録中")).firstMatch
        guard monitoringBefore.exists else {
            try skipWithEvidence("relaunch-not-monitoring",
                                 "The relaunch phase requires active monitoring (自動記録中); the screen shows \(statusBefore).")
        }
        let statusTextBefore = monitoringBefore.label
        note("RELAUNCH baseline: status=\(statusTextBefore) learning=\(describeCount(learningBefore)) distraction=\(describeCount(distractionBefore)) blackGems=\(describeCount(blackBefore)) home=\(homeBefore.summary)")

        for round in 1...2 {
            let relaunched = launchRealApplication()
            try reachHome(relaunched)
            try require(!relaunched.alerts["Screen Timeの記録を保留しています"].exists,
                        "Relaunch \(round) must not raise the pending-import alert: \(alertMessage(relaunched)).",
                        evidence: "relaunch-\(round)-import-alert")
            let home = readHomeTotals(relaunched, label: "relaunch-\(round)-home")
            try require(home.pebbles == homeBefore.pebbles,
                        "Relaunch \(round) must not re-import gems: \(homeBefore.pebbles) → \(home.pebbles) 粒.",
                        evidence: "relaunch-\(round)-home-changed")
            try openScreenTimeSettings(relaunched)
            let status = recordSettingsState(relaunched, label: "relaunch-\(round)")
            try require(status.contains("許可済み"),
                        "Relaunch \(round) must keep granted access; it reports \(status).",
                        evidence: "relaunch-\(round)-authorization")
            let monitoring = relaunched.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "自動記録中")).firstMatch
            try require(monitoring.waitForExistence(timeout: 30) && monitoring.label == statusTextBefore,
                        "Relaunch \(round) must restore the same monitoring status (\(statusTextBefore)); it shows \(monitoring.exists ? monitoring.label : "<absent>").",
                        evidence: "relaunch-\(round)-status")
            try require(selectionCount(relaunched, lane: .learning) == learningBefore,
                        "Relaunch \(round) changed the learning selection: \(describeCount(learningBefore)) → \(describeCount(selectionCount(relaunched, lane: .learning))).",
                        evidence: "relaunch-\(round)-learning")
            try require(selectionCount(relaunched, lane: .distraction) == distractionBefore,
                        "Relaunch \(round) changed the black-gem selection: \(describeCount(distractionBefore)) → \(describeCount(selectionCount(relaunched, lane: .distraction))).",
                        evidence: "relaunch-\(round)-distraction")
            try require(negativeGemCount(relaunched) == blackBefore,
                        "Relaunch \(round) changed the black-gem total: \(describeCount(blackBefore)) → \(describeCount(negativeGemCount(relaunched))).",
                        evidence: "relaunch-\(round)-black")
            try require(!relaunched.staticTexts["screen-time.monitoring-error"].exists,
                        "Relaunch \(round) raised a monitoring error: \(relaunched.staticTexts["screen-time.monitoring-error"].label).",
                        evidence: "relaunch-\(round)-error")
            note("RELAUNCH \(round) PASS: status, selections, black gems and Home totals unchanged.")
        }
        note("RELAUNCH COMPLETE.")
    }

    // MARK: - P8 revoke / re-allow

    func testRevokeAndRestoreScreenTimeAccess() throws {
        try select(.revoke)
        let app = launchRealApplication()
        try reachHome(app)
        try openScreenTimeSettings(app)
        let before = recordSettingsState(app, label: "revoke-before")
        guard before.contains("許可済み") else {
            try skipWithEvidence("revoke-not-authorized",
                                 "Screen Time access is already not granted (\(before)); there is nothing to revoke.")
        }
        let blackBefore = negativeGemCount(app)
        note("REVOKE baseline: status=\(before) learning=\(describeCount(selectionCount(app, lane: .learning))) distraction=\(describeCount(selectionCount(app, lane: .distraction))) blackGems=\(describeCount(blackBefore))")

        let settings = XCUIApplication(bundleIdentifier: Self.preferencesID)
        guard let toggle = try openScreenTimeAccessToggle(in: settings) else {
            leavePreferences(settings)
            try skipWithEvidence("revoke-toggle-not-found",
                                 "PomoGem's Screen Time access toggle could not be located in 設定 → スクリーンタイム from XCUITest. Nothing in iOS Settings was changed; hand this phase to a human.")
        }
        note("REVOKE: found access toggle label=\(toggle.label) value=\(describeValue(toggle))")
        guard describeValue(toggle) == "1" else {
            leavePreferences(settings)
            try skipWithEvidence("revoke-toggle-already-off",
                                 "The located toggle (\(toggle.label)) is already off; the app reported granted access, so this is not the right control. Nothing was changed.")
        }

        try setPreferencesToggle(settings, toggle, on: false, label: "revoke-off")

        var restored = false
        defer {
            if !restored {
                note("REVOKE CLEANUP: restoring PomoGem's Screen Time access toggle to ON.")
                let settingsApp = XCUIApplication(bundleIdentifier: Self.preferencesID)
                settingsApp.activate()
                pause(2)
                let located = (try? openScreenTimeAccessToggle(in: settingsApp)) ?? nil
                if let located, describeValue(located) == "0" {
                    try? setPreferencesToggle(settingsApp, located, on: true, label: "revoke-cleanup-on")
                }
                leavePreferences(settingsApp)
            }
        }

        app.activate()
        pause(3)
        if !app.navigationBars["スクリーンタイム"].exists {
            try reachHome(app)
            try openScreenTimeSettings(app)
        }
        let revoked = recordSettingsState(app, label: "revoke-after-off")
        let revokedMessage = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "スクリーンタイムの許可が解除されました")
        ).firstMatch
        let statusSaysNeeded = app.staticTexts["screen-time.authorization-status"].label.contains("許可が必要")
        try require(revokedMessage.waitForExistence(timeout: 60) || statusSaysNeeded,
                    "Revoking Screen Time access must surface the revoked state in PomoGem; the screen shows \(revoked).",
                    evidence: "revoke-no-message")
        note("REVOKE: revokedMessage=\(revokedMessage.exists) statusSaysNeeded=\(statusSaysNeeded) status=\(revoked)")
        try require(selectionCount(app, lane: .learning) == 0,
                    "Revocation must clear the learning selection (Apple voids the opaque tokens): \(describeCount(selectionCount(app, lane: .learning))).",
                    evidence: "revoke-learning-retained")
        try require(selectionCount(app, lane: .distraction) == 0,
                    "Revocation must clear the black-gem selection: \(describeCount(selectionCount(app, lane: .distraction))).",
                    evidence: "revoke-distraction-retained")
        try require(negativeGemCount(app) == blackBefore,
                    "Revocation must retain the recorded black-gem total: \(describeCount(blackBefore)) → \(describeCount(negativeGemCount(app))).",
                    evidence: "revoke-black-lost")
        note("REVOKE PASS: selections cleared, black-gem total retained.")

        // Re-allow.
        settings.activate()
        pause(2)
        guard let again = try openScreenTimeAccessToggle(in: settings) else {
            try skipWithEvidence("revoke-restore-toggle-not-found",
                                 "The Screen Time access toggle could not be located again to restore it. RESTORE IT BY HAND: 設定 → スクリーンタイム → PomoGem → ON.")
        }
        try setPreferencesToggle(settings, again, on: true, label: "revoke-on")
        restored = true

        app.activate()
        pause(3)
        if !app.navigationBars["スクリーンタイム"].exists {
            try reachHome(app)
            try openScreenTimeSettings(app)
        }
        let reallowed = recordSettingsState(app, label: "revoke-after-on")
        let status = app.staticTexts["screen-time.authorization-status"]
        let grantedAgain = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", "許可済み"),
            object: status
        )
        let isGranted = XCTWaiter.wait(for: [grantedAgain], timeout: 60) == .completed
        note("REVOKE: after re-allowing, status=\(isGranted ? status.label : reallowed)")
        if !isGranted {
            try skipWithEvidence("revoke-reallow-needs-prompt",
                                 "Restored the iOS toggle to ON, but PomoGem still reports \(status.label). Apple may require a fresh in-app authorization; run the `authorize` phase next. The iOS toggle IS back ON.")
        }
        try require(selectionCount(app, lane: .learning) == 0,
                    "Re-allowing must not resurrect the voided selections.",
                    evidence: "revoke-selection-resurrected")
        note("REVOKE COMPLETE: access restored to granted, selections still empty (Apple voids tokens on revocation). Re-pick and save with the `save` phase.")
    }

    // MARK: - P9 reset

    func testInAppResetClearsScreenTimeStateOnly() throws {
        try select(.reset)
        let app = launchRealApplication()
        try reachHome(app)
        let homeBefore = readHomeTotals(app, label: "reset-home-before")
        try openScreenTimeSettings(app)
        let before = recordSettingsState(app, label: "reset-before")
        note("RESET baseline: status=\(before) learning=\(describeCount(selectionCount(app, lane: .learning))) distraction=\(describeCount(selectionCount(app, lane: .distraction))) blackGems=\(describeCount(negativeGemCount(app))) home=\(homeBefore.summary)")

        let reset = app.buttons["screen-time.reset"]
        _ = reveal(reset, upwards: true)
        try require(reset.exists && reset.isEnabled,
                    "screen-time.reset must be available.",
                    evidence: "reset-unavailable")
        reset.tap()
        let alert = app.alerts["スクリーンタイムの内容をリセット"]
        try require(alert.waitForExistence(timeout: 10),
                    "The reset must ask for its ordinary confirmation.",
                    evidence: "reset-no-confirmation")
        capture("reset-confirmation")
        try tap(alert.buttons["リセット"], "リセット")

        let cleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", "自動記録は停止中です"),
            object: app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "自動記録は停止中です")).firstMatch
        )
        let stopped = XCTWaiter.wait(for: [cleared], timeout: 120) == .completed
        let after = recordSettingsState(app, label: "reset-after")
        try require(stopped,
                    "After a reset the status must read 自動記録は停止中です。; the screen shows \(after).",
                    evidence: "reset-not-stopped")
        try require(selectionCount(app, lane: .learning) == 0,
                    "Reset must clear the learning selection: \(describeCount(selectionCount(app, lane: .learning))).",
                    evidence: "reset-learning")
        try require(selectionCount(app, lane: .distraction) == 0,
                    "Reset must clear the black-gem selection: \(describeCount(selectionCount(app, lane: .distraction))).",
                    evidence: "reset-distraction")
        try require(negativeGemCount(app) == 0,
                    "Reset must clear the black-gem total: \(describeCount(negativeGemCount(app))).",
                    evidence: "reset-black")
        try require(!app.staticTexts["screen-time.monitoring-error"].exists,
                    "Reset must not leave a monitoring error: \(app.staticTexts["screen-time.monitoring-error"].label).",
                    evidence: "reset-error")

        try returnToHome(app, from: "スクリーンタイム")
        let homeAfter = readHomeTotals(app, label: "reset-home-after")
        try require(homeAfter.pebbles == homeBefore.pebbles,
                    "Reset must retain saved study records: \(homeBefore.pebbles) → \(homeAfter.pebbles) 粒.",
                    evidence: "reset-home-changed")
        note("RESET PASS: selections and black gems cleared, monitoring stopped, Home totals unchanged (\(homeAfter.summary)).")
    }

    // MARK: - entry / navigation

    private func reachHome(_ app: XCUIApplication) throws {
        let menu = app.buttons["メニュー"]
        let cloudChoice = app.buttons["iCloudに保存して同期"]
        let localChoice = app.buttons["このiPhoneだけに保存"]
        let onboarding = app.buttons["onboarding.next"]
        let blocked = app.staticTexts["保存領域を確認できません"]
        var reached = "unknown"
        var systemModal: SystemModal?
        let deadline = Date().addingTimeInterval(180)
        repeat {
            // A SpringBoard modal is checked FIRST: it covers the app's own
            // screen, so anything classified underneath it would be untappable.
            if let modal = currentSystemModal() { systemModal = modal; reached = "system-alert"; break }
            if menu.exists { reached = "home"; break }
            if blocked.exists { reached = "storage-blocked"; break }
            if cloudChoice.exists || localChoice.exists { reached = "storage-choice"; break }
            if onboarding.exists { reached = "onboarding"; break }
            pause(1)
        } while Date() < deadline

        if reached == "storage-blocked" {
            reached = try resolveStorageBlock(app)
        }

        note("ENTRY SCREEN: \(reached)")
        note("ENTRY system alert: \(systemModal?.summary ?? describeSystemModal())")
        capture("entry-\(reached)")
        dumpHierarchy(app, name: "entry-\(reached)")
        if let systemModal {
            recordSystemModal(systemModal, context: "entry")
            throw XCTSkip("system alert: \(systemModal.title) — needs human")
        }
        guard reached == "home" else {
            note("STOPPED: the app did not open on Home. This suite never chooses a store or completes onboarding.")
            throw XCTSkip("The installation is not in the audited state (\(reached)); a human must decide how to proceed.")
        }
    }

    /// 「保存領域を確認できません」 handling, governed by
    /// POMOGEM_REAL_SCREEN_TIME_STORAGE_ACTION.
    private func resolveStorageBlock(_ app: XCUIApplication) throws -> String {
        capture("storage-blocked")
        dumpHierarchy(app, name: "storage-blocked")
        note("STORAGE: 「保存領域を確認できません」 is on screen; POMOGEM_REAL_SCREEN_TIME_STORAGE_ACTION=\(storageAction.rawValue).")
        switch storageAction {
        case .none:
            return "storage-blocked"
        case .retry:
            let retry = app.buttons["もう一度試す"]
            guard retry.exists && retry.isHittable else {
                note("STORAGE: 「もう一度試す」 is not addressable.")
                return "storage-blocked"
            }
            retry.tap()
            note("STORAGE: tapped 「もう一度試す」 once; waiting up to 90 s for Home.")
            let home = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"),
                                                 object: app.buttons["メニュー"])
            let reached = XCTWaiter.wait(for: [home], timeout: 90) == .completed
            capture("storage-after-retry")
            return reached ? "home" : "storage-blocked-after-retry"
        case .offlineContinue:
            let offline = app.buttons["cloud-offline-continue"]
            // 「端末のデータでオフライン利用」 is gated on `canStartOfflineContinuation`,
            // which is false while the launch task still holds `isPreparing` and
            // while a previous container has not been released. Both clear
            // asynchronously *after* `launchState = .blocked(...)` renders, so a
            // single `exists` sample right after the heading appears can miss a
            // button that is about to be offered. Poll instead, and keep the
            // settled hierarchy either way. Nothing else on this screen is ever
            // tapped: no 「もう一度試す」, no refresh, no local-only choice.
            let appeared = offline.waitForExistence(timeout: 60)
            capture("storage-blocked-settled")
            dumpHierarchy(app, name: "storage-blocked-settled")
            guard appeared, offline.isHittable else {
                note("STORAGE: cloud-offline-continue did not appear within 60 s (exists=\(offline.exists)). The only non-destructive action is unavailable; no other button was tapped.")
                return "storage-blocked"
            }
            offline.tap()
            note("STORAGE: tapped cloud-offline-continue; waiting up to 90 s for Home.")
            let home = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"),
                                                 object: app.buttons["メニュー"])
            let reached = XCTWaiter.wait(for: [home], timeout: 90) == .completed
            capture("storage-after-offline-continue")
            return reached ? "home" : "storage-blocked-after-offline-continue"
        }
    }

    private func openScreenTimeSettings(_ app: XCUIApplication) throws {
        if app.navigationBars["スクリーンタイム"].exists { return }
        if !app.navigationBars["設定"].exists {
            try tap(app.buttons["メニュー"], "Home menu")
            let settings = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "設定")).firstMatch
            _ = reveal(settings)
            try tap(settings, "設定")
            guard app.navigationBars["設定"].waitForExistence(timeout: 20) else {
                capture("settings-missing")
                XCTFail("Settings did not open.")
                throw AuditFailure.stopped
            }
        }
        let entry = app.descendants(matching: .any)["settings.screen-time"].firstMatch
        _ = reveal(entry)
        try tap(entry, "settings.screen-time")
        guard app.navigationBars["スクリーンタイム"].waitForExistence(timeout: 20) else {
            capture("screen-time-missing")
            XCTFail("The Screen Time settings screen did not open.")
            throw AuditFailure.stopped
        }
        note("Screen Time settings screen is open.")
    }

    private func returnToHome(_ app: XCUIApplication, from navigationBar: String) throws {
        var guardCount = 0
        while guardCount < 6, !app.buttons["メニュー"].exists {
            guardCount += 1
            let bar = app.navigationBars.allElementsBoundByIndex.last ?? app.navigationBars.firstMatch
            let back = bar.buttons.firstMatch
            if back.exists && back.isHittable {
                back.tap()
            } else {
                app.swipeRight(velocity: .fast)
            }
            pause(1)
        }
        guard app.buttons["メニュー"].waitForExistence(timeout: 20) else {
            capture("return-home-failed-from-\(navigationBar)")
            XCTFail("Navigating back to Home from \(navigationBar) did not reach the Home screen.")
            throw AuditFailure.stopped
        }
    }

    // MARK: - settings observation

    @discardableResult
    private func recordSettingsState(_ app: XCUIApplication, label: String) -> String {
        let status = app.staticTexts["screen-time.authorization-status"]
        _ = reveal(status)
        let statusLabel = status.exists ? status.label : "<missing>"
        note("[\(label)] screen-time.authorization-status = \(statusLabel)")

        let authorize = app.buttons["screen-time.authorize"]
        note("[\(label)] screen-time.authorize exists=\(authorize.exists) enabled=\(authorize.exists && authorize.isEnabled) label=\(authorize.exists ? authorize.label : "-")")

        let toggle = app.switches["screen-time.enabled"]
        _ = reveal(toggle)
        note("[\(label)] screen-time.enabled exists=\(toggle.exists) enabled=\(toggle.exists && toggle.isEnabled) value=\(describeValue(toggle))")

        for identifier in ["screen-time.learning-apps", "screen-time.distraction-apps"] {
            let button = app.buttons[identifier]
            _ = reveal(button)
            note("[\(label)] \(identifier) exists=\(button.exists) enabled=\(button.exists && button.isEnabled) value=\(describeValue(button)) label=\(button.exists ? button.label : "-")")
        }

        let negative = app.staticTexts["screen-time.negative-total"]
        _ = reveal(negative, upwards: false)
        note("[\(label)] screen-time.negative-total = \(negative.exists ? negative.label : "<missing>")")

        let monitoringError = app.staticTexts["screen-time.monitoring-error"]
        note("[\(label)] screen-time.monitoring-error = \(monitoringError.exists ? monitoringError.label : "<absent>")")

        let updating = app.descendants(matching: .any)["screen-time.updating"].firstMatch
        note("[\(label)] screen-time.updating present=\(updating.exists) label=\(updating.exists ? updating.label : "-")")

        for text in ["自動記録中", "黒いgemを自動記録中", "自動記録は停止中です。",
                     "タイマーの計測中は、勉強アプリの自動記録を休止しています。",
                     "スクリーンタイムの許可が解除されました"] {
            let element = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
            note("[\(label)] status text \"\(text)\" present=\(element.exists)")
        }

        let theme = themePicker(app)
        note("[\(label)] screen-time.theme exists=\(theme.exists) enabled=\(theme.exists && theme.isEnabled) label=\(theme.exists ? theme.label : "-") value=\(describeValue(theme))")

        let save = app.buttons["screen-time.save"]
        note("[\(label)] screen-time.save exists=\(save.exists) enabled=\(save.exists && save.isEnabled)")
        note("[\(label)] validation footer = \(validationFooter(app))")

        capture("settings-\(label)")
        dumpHierarchy(app, name: "settings-\(label)")
        return statusLabel
    }

    private func themePicker(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["screen-time.theme"].exists
            ? app.buttons["screen-time.theme"]
            : app.descendants(matching: .any)["screen-time.theme"].firstMatch
    }

    private func validationFooter(_ app: XCUIApplication) -> String {
        let candidates = [
            "スクリーンタイムへのアクセスを許可してください。",
            "記録するアプリを1つ以上選んでください。",
            "勉強時間を記録するテーマを選んでください。",
            "カテゴリやWebサイトは選べません",
            "同じアプリを勉強のgemと黒いgemの両方には登録できません",
            "無料では勉強アプリを5つまで選べます"
        ]
        let found = candidates.filter {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", $0)).firstMatch.exists
        }
        return found.isEmpty ? "<none>" : found.joined(separator: " / ")
    }

    private func selectionCount(_ app: XCUIApplication, lane: Lane) -> Int? {
        let button = app.buttons[lane.identifier]
        _ = reveal(button)
        guard button.exists else { return nil }
        return firstInteger(in: describeValue(button), pattern: "([0-9][0-9,]*)アプリ選択中")
    }

    private func negativeGemCount(_ app: XCUIApplication) -> Int? {
        let element = app.staticTexts["screen-time.negative-total"]
        _ = reveal(element, upwards: false)
        guard element.exists else { return nil }
        return firstInteger(in: element.label, pattern: "× ?([0-9][0-9,]*)個ぶん")
    }

    private func describeCount(_ value: Int?) -> String {
        value.map(String.init) ?? "<unreadable>"
    }

    private func recordThemePickerOptions(_ app: XCUIApplication) {
        let picker = themePicker(app)
        guard reveal(picker), picker.isEnabled, picker.isHittable else {
            note("THEME PICKER: not reachable/enabled; options not dumped.")
            return
        }
        let selectedBefore = describeValue(picker)
        picker.tap()
        pause(2)
        let options = labels(of: app.buttons).filter { !$0.isEmpty }
        note("THEME PICKER opened. selectedValue=\(selectedBefore)")
        note("THEME PICKER candidate option labels (buttons on screen): \(options.joined(separator: " | "))")
        note("THEME PICKER menuItems: \(labels(of: app.menuItems).joined(separator: " | "))")
        capture("theme-picker-open")
        dumpHierarchy(app, name: "theme-picker-open")

        let current = selectedBefore.isEmpty ? "選んでください" : selectedBefore
        let sameOption = app.buttons.matching(NSPredicate(format: "label == %@", current)).firstMatch
        if sameOption.exists && sameOption.isHittable {
            sameOption.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.06)).tap()
        }
        pause(1)
        note("THEME PICKER dismissed; screen-time.theme value now \(describeValue(picker)); スクリーンタイム bar present=\(app.navigationBars["スクリーンタイム"].exists)")
    }

    /// Picks POMOGEM_REAL_SCREEN_TIME_THEME, or the first real theme.
    @discardableResult
    private func selectRecordingTheme(_ app: XCUIApplication) throws -> String {
        let picker = themePicker(app)
        guard reveal(picker), picker.exists, picker.isEnabled else {
            capture("theme-picker-unavailable")
            XCTFail("screen-time.theme must be operable to choose a recording theme.")
            throw AuditFailure.stopped
        }
        if let themeName, describeValue(picker).contains(themeName) {
            note("THEME: \(themeName) is already selected.")
            return themeName
        }
        picker.tap()
        pause(2)
        capture("theme-picker-choose")
        dumpHierarchy(app, name: "theme-picker-choose")
        let excluded: Set<String> = ["選んでください", "削除されたテーマ", "記録先のテーマ", "キャンセル", "保存"]
        var chosen: XCUIElement?
        var chosenLabel = ""
        if let themeName {
            let match = app.buttons.matching(NSPredicate(format: "label == %@", themeName)).firstMatch
            if match.exists && match.isHittable { chosen = match; chosenLabel = themeName }
        } else {
            for candidate in app.buttons.allElementsBoundByIndex.prefix(40) {
                let label = candidate.label
                guard !label.isEmpty, !excluded.contains(label), candidate.isHittable else { continue }
                chosen = candidate
                chosenLabel = label
                break
            }
        }
        guard let chosen else {
            capture("theme-picker-no-option")
            let available = labels(of: app.buttons).joined(separator: " | ")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.06)).tap()
            XCTFail("No selectable theme was offered by screen-time.theme. Options seen: \(available). Create a theme through the ordinary UI first.")
            throw AuditFailure.stopped
        }
        chosen.tap()
        pause(1)
        let value = describeValue(themePicker(app))
        note("THEME: selected \(chosenLabel); screen-time.theme value=\(value)")
        return chosenLabel
    }

    private func setRecordingToggle(_ app: XCUIApplication, on: Bool) throws {
        let toggle = app.switches["screen-time.enabled"]
        _ = reveal(toggle)
        try require(toggle.exists && toggle.isEnabled,
                    "screen-time.enabled must be operable to \(on ? "enable" : "disable") recording.",
                    evidence: "toggle-unavailable")
        let wanted = on ? "1" : "0"
        guard describeValue(toggle) != wanted else {
            note("TOGGLE: screen-time.enabled is already \(on ? "on" : "off").")
            return
        }
        toggle.tap()
        pause(1)
        try require(describeValue(toggle) == wanted,
                    "screen-time.enabled did not move to \(wanted); it reads \(describeValue(toggle)).",
                    evidence: "toggle-stuck")
        note("TOGGLE: screen-time.enabled set to \(wanted).")
    }

    private func waitForToastToClear(_ app: XCUIApplication) throws {
        try guardAgainstSystemAlert("wait-toast")
        let toast = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "スクリーンタイムの設定を保存しました")
        ).firstMatch
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: toast)
        let cleared = XCTWaiter.wait(for: [gone], timeout: 30) == .completed
        try guardAgainstSystemAlert("wait-toast-settled")
        note("SAVE: first-save toast cleared=\(cleared)")
    }

    private func alertMessage(_ app: XCUIApplication) -> String {
        guard app.alerts.count > 0 else { return "<no alert>" }
        let alert = app.alerts.firstMatch
        return "\(alert.label) :: " + labels(of: alert.staticTexts).joined(separator: " / ")
    }

    // MARK: - FamilyActivityPicker (REMOTE VIEW — structure unknown)

    private func openPicker(_ app: XCUIApplication, lane: Lane) throws {
        let button = app.buttons[lane.identifier]
        _ = reveal(button)
        try require(button.exists && button.isEnabled,
                    "\(lane.identifier) must be operable to open Apple's picker.",
                    evidence: "picker-\(lane.identifier)-unavailable")
        button.tap()
        let cancel = app.buttons["キャンセル"]
        let apply = app.buttons["screen-time.picker-apply"]
        let opened = cancel.waitForExistence(timeout: 20) || apply.waitForExistence(timeout: 5)
        note("PICKER(\(lane.title)): opened=\(opened) cancel=\(cancel.exists) apply=\(apply.exists)")
        // The remote view hydrates its own content asynchronously.
        pause(6)
        try guardAgainstPasscode(app)
        inventory(app, name: "picker-\(lane.title)-initial")
        capture("picker-\(lane.title)-initial")
        dumpHierarchy(app, name: "picker-\(lane.title)-initial")
        try require(opened,
                    "The \(lane.title) picker sheet did not open.",
                    evidence: "picker-\(lane.title)-not-open")
    }

    private func applyPicker(_ app: XCUIApplication) throws {
        let apply = app.buttons["screen-time.picker-apply"]
        try require(apply.exists && apply.isEnabled,
                    "反映 must be enabled to apply a valid selection. Footer: \(validationFooter(app)).",
                    evidence: "picker-apply-disabled")
        apply.tap()
        guard app.navigationBars["スクリーンタイム"].waitForExistence(timeout: 20) else {
            capture("picker-apply-stuck")
            XCTFail("The picker did not dismiss after 反映.")
            throw AuditFailure.stopped
        }
        pause(1)
    }

    private func cancelPicker(_ app: XCUIApplication) {
        let cancel = app.buttons["キャンセル"]
        if cancel.exists && cancel.isHittable {
            cancel.tap()
        } else {
            app.swipeDown(velocity: .fast)
        }
        pause(1)
        note("PICKER: cancelled; スクリーンタイム bar present=\(app.navigationBars["スクリーンタイム"].exists)")
    }

    /// Ticks one application by display name inside Apple's remote picker.
    /// The picker's accessibility structure is not documented, so this tries
    /// several element types and expands category disclosure rows first.
    private func tickApplication(_ app: XCUIApplication, named name: String) -> Bool {
        if setApplication(app, named: name, selected: true) { return true }
        // Category rows hide their applications until expanded.
        for row in categoryRows(app).prefix(12) {
            guard row.exists, row.isHittable else { continue }
            note("PICKER: expanding category row \"\(row.label)\" while looking for \(name).")
            row.tap()
            pause(2)
            if setApplication(app, named: name, selected: true) { return true }
        }
        // Last resort: scroll the sheet and retry.
        for _ in 0..<8 {
            app.swipeUp(velocity: .fast)
            pause(1)
            if setApplication(app, named: name, selected: true) { return true }
        }
        note("PICKER: \(name) was not addressable.")
        capture("picker-missing-\(name)")
        dumpHierarchy(app, name: "picker-missing-\(name)")
        return false
    }

    private func untickApplication(_ app: XCUIApplication, named name: String) -> Bool {
        setApplication(app, named: name, selected: false)
    }

    /// The sheet's own live 「<n>アプリ選択中」 counter (ScreenTimeAppSelectionSheet's
    /// bottom inset). Apple's picker rows are a remote view that publishes
    /// neither `isSelected` nor a value, so this counter is the only evidence
    /// the app gives for what is ticked inside it.
    private func pickerSelectionCount(_ app: XCUIApplication) -> Int? {
        let element = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "アプリ選択中")
        ).firstMatch
        guard element.exists else { return nil }
        return firstInteger(in: element.label, pattern: "([0-9][0-9,]*)アプリ選択中")
    }

    /// Returns true only when the sheet's counter actually moved the way the
    /// caller asked. The old short-circuit required BOTH `isSelected` and a
    /// "1"/"0" value, which the remote rows never publish, so an already-ticked
    /// row was tapped again — i.e. UNTICKED — and reported as success. The
    /// callers build their `ticked` arrays from this boolean and assert on
    /// their length, so a miscount was reported as an app defect.
    private func setApplication(_ app: XCUIApplication, named name: String, selected: Bool) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", name, name)
        let queries: [XCUIElementQuery] = [app.cells, app.switches, app.buttons, app.staticTexts, app.images]
        for query in queries {
            let element = query.matching(predicate).firstMatch
            guard element.exists else { continue }
            _ = reveal(element)
            guard element.isHittable else { continue }
            guard let before = pickerSelectionCount(app) else {
                note("PICKER: the sheet's 「<n>アプリ選択中」 counter is unreadable; \(name) cannot be verified.")
                return false
            }
            element.tap()
            pause(1)
            let after = pickerSelectionCount(app)
            note("PICKER: tapped \(name) (\(element.elementType.rawValue)) count \(before) → \(describeCount(after))")
            guard let after else {
                note("PICKER: the counter became unreadable after tapping \(name).")
                return false
            }
            let wanted = selected ? 1 : -1
            if after == before + wanted { return true }
            if after == before - wanted {
                // The row was already in the requested state and this tap
                // reversed it. Put it back before reporting the state reached.
                element.tap()
                pause(1)
                let restored = pickerSelectionCount(app)
                note("PICKER: \(name) was already \(selected ? "selected" : "cleared"); restored count \(describeCount(restored)).")
                return restored == before
            }
            note("PICKER: tapping \(name) did not move the counter (\(before) → \(after)); not addressable.")
            return false
        }
        return false
    }

    private func categoryRows(_ app: XCUIApplication) -> [XCUIElement] {
        let excluded: Set<String> = ["キャンセル", "反映", "Cancel", "Done", ""]
        var result: [XCUIElement] = []
        for query in [app.cells, app.buttons] {
            for element in query.allElementsBoundByIndex.prefix(40)
            where !excluded.contains(element.label) {
                result.append(element)
            }
        }
        return result
    }

    /// Attempts to select an entire category, which the app must refuse.
    private func selectWholeCategory(_ app: XCUIApplication) -> Bool {
        for row in categoryRows(app).prefix(12) {
            guard row.exists, row.isHittable else { continue }
            // A category header usually carries its own selection control as a
            // sibling image/button; try the row's leading edge first.
            let leading = row.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.5))
            leading.tap()
            pause(2)
            if app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "カテゴリやWebサイトは選べません")
            ).firstMatch.exists {
                note("PICKER: whole-category selection reproduced via row \"\(row.label)\".")
                capture("picker-category-selected")
                return true
            }
            // Undo whatever that tap did before trying the next row.
            leading.tap()
            pause(1)
        }
        return false
    }

    // MARK: - authorization prompt (REMOTE system view)

    private func driveAuthorizationPrompt(_ app: XCUIApplication) throws {
        let authorize = app.buttons["screen-time.authorize"]
        guard reveal(authorize), authorize.isEnabled else {
            note("AUTHORIZATION: screen-time.authorize is missing or disabled; nothing tapped.")
            return
        }
        note("AUTHORIZATION: tapping screen-time.authorize now.")
        // Apple's Family Controls prompt is itself a SpringBoard modal, and it
        // is the ONE system prompt this suite is authorized to answer, so the
        // system-modal probe is muted for the duration of this helper.
        isDrivingSystemPrompt = true
        defer { isDrivingSystemPrompt = false }
        authorize.tap()

        let springboard = XCUIApplication(bundleIdentifier: Self.springboardID)
        let deadline = Date().addingTimeInterval(25)
        var target: XCUIElement?
        var host = "none"
        repeat {
            if let found = firstHittableButton(in: springboard, titles: Self.affirmatives) {
                target = found; host = "springboard"; break
            }
            if let found = firstHittableButton(in: app, titles: Self.affirmatives) {
                target = found; host = "app"; break
            }
            pause(1)
        } while Date() < deadline

        capture("authorization-prompt")
        dumpHierarchy(app, name: "authorization-prompt-app")
        dumpHierarchy(springboard, name: "authorization-prompt-springboard")
        if app.alerts.count > 0 { dumpHierarchy(app.alerts.firstMatch, name: "authorization-prompt-app-alert") }
        if springboard.alerts.count > 0 { dumpHierarchy(springboard.alerts.firstMatch, name: "authorization-prompt-springboard-alert") }
        note("AUTHORIZATION prompt: app.alerts=\(app.alerts.count) springboard.alerts=\(springboard.alerts.count) affirmativeFound=\(target != nil) host=\(host)")
        note("AUTHORIZATION springboard button labels: \(labels(of: springboard.buttons).joined(separator: " | "))")
        note("AUTHORIZATION app button labels: \(labels(of: app.buttons).joined(separator: " | "))")

        try guardAgainstPasscode(app)

        if let target {
            note("AUTHORIZATION: tapping affirmative button \"\(target.label)\" in \(host).")
            target.tap()
            pause(3)
            capture("authorization-after-affirmative")
        } else {
            note("AUTHORIZATION: no affirmative button was addressable within 25 s.")
            try skipWithEvidence("authorization-prompt-unreachable",
                                 "Apple's Family Controls authorization prompt exposed no addressable affirmative button (tried \(Self.affirmatives.joined(separator: ", ")) in the app, in any sheet and in SpringBoard). Hand the authorization step to a human.")
        }
    }

    // MARK: - probe picker reconnaissance

    private func probeLearningPicker(_ app: XCUIApplication) {
        let learning = app.buttons["screen-time.learning-apps"]
        guard reveal(learning) else {
            note("PICKER: screen-time.learning-apps not reachable.")
            return
        }
        guard learning.isEnabled else {
            note("PICKER: screen-time.learning-apps is DISABLED (authorization not granted); picker not opened.")
            return
        }
        note("PICKER: opening screen-time.learning-apps.")
        learning.tap()
        let header = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "カテゴリを開き、記録するアプリを1つずつ選んでください"
        )).firstMatch
        let cancel = app.buttons["キャンセル"]
        let apply = app.buttons["screen-time.picker-apply"]
        let opened = cancel.waitForExistence(timeout: 20) || header.waitForExistence(timeout: 5)
        note("PICKER: sheet opened=\(opened) header visible=\(header.exists) cancel=\(cancel.exists) apply(反映)=\(apply.exists) applyEnabled=\(apply.exists && apply.isEnabled)")
        pause(6)

        inventory(app, name: "picker-initial")
        capture("picker-initial")
        dumpHierarchy(app, name: "picker-initial")

        let rows = categoryRows(app)
        note("PICKER: candidate category rows = \(rows.map(\.label).joined(separator: " | "))")
        if let first = rows.first(where: { $0.isHittable }) {
            note("PICKER: expanding first category row \"\(first.label)\".")
            first.tap()
            pause(4)
            inventory(app, name: "picker-expanded")
            capture("picker-expanded")
            dumpHierarchy(app, name: "picker-expanded")
        } else {
            note("PICKER: no hittable category row was addressable — the remote view exposes no rows to XCUITest.")
        }

        cancelPicker(app)
        capture("picker-dismissed")
    }

    // MARK: - Home totals

    private func readHomeTotals(_ app: XCUIApplication, label: String) -> HomeTotals {
        let jar = app.buttons["瓶"].exists
            ? app.buttons["瓶"]
            : app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "瓶")).firstMatch
        let jarValue = jar.exists ? describeValue(jar) : "<missing>"

        var menuLabel = "<missing>"
        let menu = app.buttons["メニュー"]
        if menu.exists && menu.isHittable {
            menu.tap()
            let summary = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "集中", "粒")
            ).firstMatch
            if summary.waitForExistence(timeout: 10) { menuLabel = summary.label }
            capture("home-totals-\(label)")
            let close = app.buttons["home.menu.close"]
            if close.exists && close.isHittable {
                close.tap()
            } else {
                app.swipeDown(velocity: .fast)
            }
            pause(1)
        }

        let pebbles = firstInteger(in: menuLabel, pattern: "集中([0-9][0-9,]*)粒")
            ?? firstInteger(in: jarValue, pattern: "([0-9][0-9,]*)粒")
            ?? -1
        var grams = -1
        var exact = false
        if let (value, unit) = firstMass(in: menuLabel) {
            if unit == "g" {
                grams = Int(value.rounded())
                exact = true
            } else {
                grams = Int((value * 1_000).rounded())
                exact = false
            }
        }
        let totals = HomeTotals(pebbles: pebbles, grams: grams, gramsAreExact: exact,
                                menuLabel: menuLabel, jarValue: jarValue)
        note("[\(label)] HOME TOTALS \(totals.summary)")
        return totals
    }

    private func firstMass(in text: String) -> (Double, String)? {
        guard let expression = try? NSRegularExpression(pattern: "累計([0-9][0-9,]*(?:\\.[0-9]+)?) ?(kg|g)") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let value = Double(text[valueRange].replacingOccurrences(of: ",", with: ""))
        else { return nil }
        return (value, String(text[unitRange]))
    }

    private func firstInteger(in text: String, pattern: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[valueRange].replacingOccurrences(of: ",", with: ""))
    }

    // MARK: - usage windows

    /// Foregrounds each configured bundle id for an equal share of
    /// POMOGEM_REAL_SCREEN_TIME_USAGE_MINUTES, tapping a neutral point every
    /// 30 s so the screen never locks.
    private func burnUsage(_ app: XCUIApplication, label: String) throws {
        let seconds = Double(usageMinutes) * 60
        let share = seconds / Double(usageBundleIDs.count)
        note("\(label.uppercased()): burning \(usageMinutes) min across \(usageBundleIDs.count) app(s) (\(Int(share)) s each): \(usageBundleIDs.joined(separator: ", "))")
        for bundleID in usageBundleIDs {
            let target = XCUIApplication(bundleIdentifier: bundleID)
            target.activate()
            pause(3)
            guard target.state == .runningForeground else {
                capture("\(label)-activate-failed-\(bundleID)")
                try skipWithEvidence("\(label)-activate-failed",
                                     "\(bundleID) could not be brought to the foreground (state=\(target.state.rawValue)); the usage window cannot be produced.")
            }
            note("\(label.uppercased()): \(bundleID) is foreground; holding for \(Int(share)) s.")
            let deadline = Date().addingTimeInterval(share)
            var ticks = 0
            while Date() < deadline {
                pause(min(30, max(1, deadline.timeIntervalSinceNow)))
                ticks += 1
                try guardAgainstSystemAlert("\(label)-usage-tick\(ticks)")
                if target.state != .runningForeground {
                    note("\(label.uppercased()): \(bundleID) left the foreground; re-activating.")
                    target.activate()
                    pause(2)
                }
                // Neutral keep-awake tap in the status area.
                target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.012)).tap()
                if ticks % 4 == 0 { capture("\(label)-\(bundleID)-tick\(ticks)") }
            }
            note("\(label.uppercased()): \(bundleID) held for \(Int(share)) s (\(ticks) keep-awake taps).")
        }
        app.activate()
        pause(5)
        capture("\(label)-back-in-pomogem")
        note("\(label.uppercased()): back in PomoGem; polling for the expected change.")
    }

    private func cyclePomoGem(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        pause(4)
        app.activate()
        // The integration modifier refreshes on a 3 s cadence while active.
        pause(8)
    }

    /// Polls Home until the pebble count leaves `baseline`, cycling PomoGem
    /// through the background every 60 s. Returns nil on timeout.
    private func scanHomeTotals(
        _ app: XCUIApplication,
        baseline: HomeTotals,
        minutes: Double
    ) throws -> (HomeTotals, TimeInterval)? {
        let start = Date()
        let deadline = start.addingTimeInterval(minutes * 60)
        var cycle = 0
        repeat {
            cycle += 1
            try guardAgainstSystemAlert("poll-home-\(cycle)")
            if !app.buttons["メニュー"].exists { try? returnToHome(app, from: "unknown") }
            let totals = readHomeTotals(app, label: "poll-\(cycle)")
            if totals.pebbles != baseline.pebbles {
                capture("poll-changed-\(cycle)")
                return (totals, Date().timeIntervalSince(start))
            }
            if Date() >= deadline { break }
            cyclePomoGem(app)
            let elapsed = Date().timeIntervalSince(start)
            let nextTick = Double(cycle) * 60
            if elapsed < nextTick { pause(min(nextTick - elapsed, max(0, deadline.timeIntervalSinceNow))) }
        } while Date() < deadline
        return nil
    }

    private func pollForHomeTotalsChange(
        _ app: XCUIApplication,
        baseline: HomeTotals,
        minutes: Double
    ) throws -> (HomeTotals, TimeInterval) {
        try guardAgainstSystemAlert("poll-home-start")
        if let result = try scanHomeTotals(app, baseline: baseline, minutes: minutes) { return result }
        capture("poll-timeout")
        XCTFail("No Home totals change was observed within \(Int(minutes)) minutes after \(usageMinutes) minutes of learning-app usage. Baseline \(baseline.summary). DeviceActivity delivery may simply be late — re-run the poll before calling this a defect.")
        throw AuditFailure.stopped
    }

    private func pollForHomeTotalsChange(
        _ app: XCUIApplication,
        baseline: HomeTotals,
        minutes: Double,
        expectNone: Bool
    ) throws -> (HomeTotals, TimeInterval)? {
        guard expectNone else {
            return try pollForHomeTotalsChange(app, baseline: baseline, minutes: minutes)
        }
        let result = try scanHomeTotals(app, baseline: baseline, minutes: minutes)
        if result == nil { note("POLL: no second Home totals increment in \(Int(minutes)) minutes, as required.") }
        return result
    }

    private func pollForNegativeTotalChange(
        _ app: XCUIApplication,
        baseline: Int,
        minutes: Double
    ) throws -> (Int, TimeInterval) {
        let start = Date()
        let deadline = start.addingTimeInterval(minutes * 60)
        var cycle = 0
        repeat {
            cycle += 1
            try guardAgainstSystemAlert("poll-black-\(cycle)")
            if !app.navigationBars["スクリーンタイム"].exists {
                try reachHome(app)
                try openScreenTimeSettings(app)
            }
            if let current = negativeGemCount(app), current != baseline {
                capture("poll-black-changed-\(cycle)")
                note("POLL \(cycle): screen-time.negative-total = \(app.staticTexts["screen-time.negative-total"].label)")
                return (current, Date().timeIntervalSince(start))
            }
            note("POLL \(cycle): blackGems=\(describeCount(negativeGemCount(app)))")
            if Date() >= deadline { break }
            cyclePomoGem(app)
            let elapsed = Date().timeIntervalSince(start)
            let nextTick = Double(cycle) * 60
            if elapsed < nextTick { pause(min(nextTick - elapsed, max(0, deadline.timeIntervalSinceNow))) }
        } while Date() < deadline
        capture("poll-black-timeout")
        XCTFail("No black-gem change was observed within \(Int(minutes)) minutes after \(usageMinutes) minutes of usage (baseline \(baseline)). DeviceActivity delivery may simply be late — re-run the poll before calling this a defect.")
        throw AuditFailure.stopped
    }

    private func pollForNegativeTotalChange(
        _ app: XCUIApplication,
        baseline: Int,
        minutes: Double,
        expectNone: Bool
    ) throws -> (Int, TimeInterval)? {
        guard expectNone else {
            return try pollForNegativeTotalChange(app, baseline: baseline, minutes: minutes)
        }
        let start = Date()
        let deadline = start.addingTimeInterval(minutes * 60)
        var cycle = 0
        repeat {
            cycle += 1
            try guardAgainstSystemAlert("poll-black-\(cycle)")
            if !app.navigationBars["スクリーンタイム"].exists {
                try reachHome(app)
                try openScreenTimeSettings(app)
            }
            if let current = negativeGemCount(app), current != baseline {
                capture("poll-black-second-change-\(cycle)")
                return (current, Date().timeIntervalSince(start))
            }
            if Date() >= deadline { break }
            cyclePomoGem(app)
            let elapsed = Date().timeIntervalSince(start)
            let nextTick = Double(cycle) * 60
            if elapsed < nextTick { pause(min(nextTick - elapsed, max(0, deadline.timeIntervalSinceNow))) }
        } while Date() < deadline
        note("POLL: no second black-gem increment in \(Int(minutes)) minutes, as required.")
        return nil
    }

    // MARK: - timer

    private func selectHomeTheme(_ app: XCUIApplication, named name: String) throws {
        let picker = app.buttons["home.subject-picker"]
        _ = reveal(picker)
        guard picker.exists, picker.isHittable else {
            note("TIMER: home.subject-picker is not reachable; the current theme is used.")
            return
        }
        picker.tap()
        pause(1)
        let theme = app.buttons[name]
        if theme.waitForExistence(timeout: 5) && theme.isHittable {
            theme.tap()
            pause(1)
            note("TIMER: selected theme \(name) on Home.")
        } else {
            capture("timer-theme-missing")
            note("TIMER: theme \(name) was not offered on Home; dismissing the menu and using the current theme.")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.06)).tap()
            pause(1)
        }
    }

    private func startTwentyFiveMinuteTimer(_ app: XCUIApplication) throws {
        let duration = app.buttons["home.duration-picker"]
        _ = reveal(duration)
        try tap(duration, "home.duration-picker")
        let preset = app.buttons["25分"]
        try require(preset.waitForExistence(timeout: 10),
                    "The real 25-minute preset must be offered.",
                    evidence: "timer-no-25")
        try tap(preset, "25分")
        let launcher = app.buttons["home.focus-launcher"]
        _ = reveal(launcher)
        try tap(launcher, "home.focus-launcher")
        let timer = app.descendants(matching: .any)["focus.timer-display"].firstMatch
        try require(timer.waitForExistence(timeout: 30),
                    "The focus timer must start.",
                    evidence: "timer-not-started")
        note("TIMER: started, focus.timer-display value=\(describeValue(timer))")
    }

    private func cancelTimer(_ app: XCUIApplication) throws {
        let stop = app.buttons["今日はここまで"]
        _ = reveal(stop)
        try require(stop.exists && stop.isHittable,
                    "The timer must offer its ordinary 今日はここまで cancellation.",
                    evidence: "timer-no-cancel")
        stop.tap()
        let confirmation = app.alerts["今日はここまで"]
        try require(confirmation.waitForExistence(timeout: 10),
                    "Cancelling the timer must ask for its ordinary confirmation.",
                    evidence: "timer-no-cancel-confirmation")
        try tap(confirmation.buttons["今日はここまで"], "今日はここまで (confirm)")
        try require(app.buttons["メニュー"].waitForExistence(timeout: 60),
                    "Cancelling the timer must return to Home.",
                    evidence: "timer-cancel-stuck")
        note("TIMER: cancelled and Home restored.")
        capture("timer-cancelled")
    }

    // MARK: - iOS Settings (revoke phase only)

    /// Locates PomoGem's Screen Time access toggle. Touches nothing else.
    private func openScreenTimeAccessToggle(in settings: XCUIApplication) throws -> XCUIElement? {
        settings.terminate()
        settings.activate()
        pause(3)
        try guardAgainstPasscode(settings)
        capture("preferences-root")

        let screenTime = settings.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "スクリーンタイム")
        ).firstMatch
        var found = false
        for _ in 0..<10 {
            if screenTime.exists && screenTime.isHittable { found = true; break }
            settings.swipeUp(velocity: .fast)
            pause(1)
        }
        guard found else {
            capture("preferences-no-screen-time")
            dumpHierarchy(settings, name: "preferences-no-screen-time")
            note("SETTINGS: the スクリーンタイム row was not addressable.")
            return nil
        }
        screenTime.tap()
        pause(3)
        try guardAgainstPasscode(settings)
        capture("preferences-screen-time")
        dumpHierarchy(settings, name: "preferences-screen-time")

        let appPredicate = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "ポモジェム", "PomoGem")
        if let toggle = findAccessSwitch(settings, matching: appPredicate) { return toggle }

        // iOS nests the list of apps with Screen Time access one level deeper
        // on some releases. Drill into any row whose label mentions the app or
        // the access list, then search again.
        let drillPredicate = NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
            "ポモジェム", "PomoGem", "スクリーンタイムを使用", "アクセス"
        )
        for query in [settings.cells, settings.buttons] {
            for row in query.matching(drillPredicate).allElementsBoundByIndex.prefix(6) {
                guard row.exists, reveal(element: row, in: settings), row.isHittable else { continue }
                note("SETTINGS: drilling into \"\(row.label)\" to look for the access toggle.")
                row.tap()
                pause(3)
                try guardAgainstPasscode(settings)
                capture("preferences-drill-\(row.label)")
                dumpHierarchy(settings, name: "preferences-drill")
                if let toggle = findAccessSwitch(settings, matching: appPredicate) { return toggle }
                let back = settings.navigationBars.firstMatch.buttons.firstMatch
                if back.exists && back.isHittable { back.tap(); pause(2) }
            }
        }
        capture("preferences-toggle-not-found")
        dumpHierarchy(settings, name: "preferences-toggle-not-found")
        note("SETTINGS: no switch labelled ポモジェム/PomoGem was addressable under スクリーンタイム.")
        return nil
    }

    private func findAccessSwitch(_ settings: XCUIApplication, matching predicate: NSPredicate) -> XCUIElement? {
        for _ in 0..<12 {
            let toggle = settings.switches.matching(predicate).firstMatch
            if toggle.exists {
                _ = reveal(element: toggle, in: settings)
                if toggle.isHittable { return toggle }
            }
            settings.swipeUp(velocity: .fast)
            pause(1)
        }
        return nil
    }

    private func setPreferencesToggle(
        _ settings: XCUIApplication,
        _ toggle: XCUIElement,
        on: Bool,
        label: String
    ) throws {
        let wanted = on ? "1" : "0"
        guard describeValue(toggle) != wanted else {
            note("SETTINGS: \(toggle.label) is already \(wanted).")
            return
        }
        capture("\(label)-before")
        toggle.tap()
        pause(2)
        try guardAgainstPasscode(settings)
        // A confirmation sheet may appear; answer it affirmatively, since this
        // is exactly the operator-authorized action.
        if settings.alerts.count > 0 || settings.sheets.count > 0 {
            dumpHierarchy(settings, name: "\(label)-confirmation")
            let titles = on ? Self.affirmatives : ["解除", "オフにする", "確認", "OK", "許可しない", "Turn Off", "Remove"]
            if let button = firstHittableButton(in: settings, titles: titles) {
                note("SETTINGS: confirming with \"\(button.label)\".")
                button.tap()
                pause(2)
            } else {
                note("SETTINGS: a confirmation appeared with no recognised button: \(labels(of: settings.buttons).joined(separator: " | "))")
            }
        }
        capture("\(label)-after")
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", wanted), object: toggle
        )
        try require(XCTWaiter.wait(for: [settled], timeout: 20) == .completed,
                    "PomoGem's Screen Time access toggle did not move to \(wanted); it reads \(describeValue(toggle)).",
                    evidence: "\(label)-stuck")
        note("SETTINGS: \(toggle.label) set to \(wanted).")
    }

    private func leavePreferences(_ settings: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        pause(2)
        note("SETTINGS: left the Settings app without changing anything else.")
    }

    // MARK: - observation helpers

    private func inventory(_ app: XCUIApplication, name: String) {
        var lines: [String] = ["ELEMENT INVENTORY: \(name)"]
        let queries: [(String, XCUIElementQuery)] = [
            ("any", app.descendants(matching: .any)),
            ("buttons", app.buttons), ("cells", app.cells), ("staticTexts", app.staticTexts),
            ("switches", app.switches), ("images", app.images), ("tables", app.tables),
            ("collectionViews", app.collectionViews), ("otherElements", app.otherElements),
            ("navigationBars", app.navigationBars), ("searchFields", app.searchFields),
            ("sheets", app.sheets), ("alerts", app.alerts), ("scrollViews", app.scrollViews),
            ("textFields", app.textFields), ("secureTextFields", app.secureTextFields)
        ]
        for (title, query) in queries {
            let count = query.count
            var line = "  \(title): count=\(count)"
            if count > 0, title != "any", title != "otherElements" {
                let sample = query.allElementsBoundByIndex.prefix(25).map {
                    "[id=\($0.identifier)|label=\($0.label)|value=\(describeValue($0))|hittable=\($0.isHittable)]"
                }
                line += " -> " + sample.joined(separator: " ")
            }
            lines.append(line)
        }
        note(lines.joined(separator: "\n"))
    }

    private func labels(of query: XCUIElementQuery) -> [String] {
        query.allElementsBoundByIndex.prefix(40).map(\.label)
    }

    private func firstHittableButton(in application: XCUIApplication, titles: [String]) -> XCUIElement? {
        for title in titles {
            let button = application.buttons[title]
            if button.exists && button.isHittable { return button }
            let inAlert = application.alerts.buttons[title]
            if inAlert.exists && inAlert.isHittable { return inAlert }
            let inSheet = application.sheets.buttons[title]
            if inSheet.exists && inSheet.isHittable { return inSheet }
        }
        return nil
    }

    // MARK: - system (SpringBoard) modals

    /// An iOS system modal (「iCloudにサインイン」, a passcode prompt, an
    /// App Store dialog...) is owned by SpringBoard, not by PomoGem. It covers
    /// the app completely while being INVISIBLE to `app.buttons[...]`, so a
    /// classification built only from the app's hierarchy reports "unknown"
    /// and every tap silently misses. Probe SpringBoard directly instead.
    /// This suite NEVER taps, answers or dismisses a system modal.
    private struct SystemModal {
        let kind: String
        let title: String
        let buttons: [String]
        let hasSecureField: Bool
        let hierarchy: String

        var summary: String {
            let buttonList = buttons.isEmpty ? "<none>" : buttons.joined(separator: " | ")
            let secure = hasSecureField ? " (secure text field present — password/passcode entry)" : ""
            return "\(kind) 「\(title)」 buttons: \(buttonList)\(secure)"
        }
    }

    private func currentSystemModal() -> SystemModal? {
        guard !isDrivingSystemPrompt else { return nil }
        let springboard = XCUIApplication(bundleIdentifier: Self.springboardID)
        let hasSecureField = springboard.secureTextFields.count > 0
        let element: XCUIElement
        let kind: String
        if springboard.alerts.count > 0 {
            element = springboard.alerts.firstMatch
            kind = "alert"
        } else if springboard.sheets.count > 0 {
            element = springboard.sheets.firstMatch
            kind = "sheet"
        } else if hasSecureField {
            element = springboard.windows.firstMatch
            kind = "secure-entry"
        } else {
            return nil
        }
        let texts = labels(of: element.staticTexts).filter { !$0.isEmpty }
        let ownLabel = element.exists ? element.label : ""
        let title = [ownLabel, texts.first ?? ""].first(where: { !$0.isEmpty }) ?? "<untitled>"
        return SystemModal(
            kind: kind,
            title: title,
            buttons: labels(of: element.buttons).filter { !$0.isEmpty },
            hasSecureField: hasSecureField,
            hierarchy: element.debugDescription
        )
    }

    /// One line for a classification report: the modal, or `<none>`.
    private func describeSystemModal() -> String {
        currentSystemModal()?.summary ?? "<none>"
    }

    private func recordSystemModal(_ modal: SystemModal, context: String) {
        note("SYSTEM ALERT at \(context): \(modal.summary)")
        capture("system-alert-\(context)")
        attach(string: modal.hierarchy, name: "system-alert-\(context)-hierarchy")
        note("STOPPED: an iOS system modal is on top of the app; this suite never taps, answers or dismisses one.")
    }

    /// Skips the phase — with a screenshot, the modal's hierarchy and its
    /// title/buttons in the transcript — when a SpringBoard modal is up.
    private func guardAgainstSystemAlert(_ context: String) throws {
        guard let modal = currentSystemModal() else { return }
        recordSystemModal(modal, context: context)
        throw XCTSkip("system alert: \(modal.title) — needs human")
    }

    /// This suite never enters a passcode.
    private func guardAgainstPasscode(_ application: XCUIApplication) throws {
        let springboard = XCUIApplication(bundleIdentifier: Self.springboardID)
        let predicate = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
                                    "パスコード", "Passcode", "PIN")
        let present = springboard.secureTextFields.count > 0
            || application.secureTextFields.count > 0
            || springboard.descendants(matching: .any).matching(predicate).firstMatch.exists
            || application.descendants(matching: .any).matching(predicate).firstMatch.exists
        guard present else { return }
        note("PASSCODE PROMPT SEEN. Stopping; no passcode is ever entered by this suite.")
        capture("passcode-prompt")
        dumpHierarchy(application, name: "passcode-prompt")
        throw XCTSkip("needs human: a passcode/PIN prompt appeared and this suite never enters one.")
    }

    private func describeValue(_ element: XCUIElement) -> String {
        guard element.exists else { return "<missing>" }
        if let value = element.value as? String { return value }
        if let value = element.value { return String(describing: value) }
        return ""
    }

    // MARK: - plumbing

    private func select(_ required: Phase) throws {
        guard phase == required else { throw XCTSkip("Select the \(required.rawValue) runner phase for this test.") }
        note("PHASE \(required.rawValue) — apps(learning)=\(learningAppNames.joined(separator: ",")) apps(distraction)=\(distractionAppNames.joined(separator: ",")) theme=\(themeName ?? "<first>") bundles=\(usageBundleIDs.joined(separator: ",")) minutes=\(usageMinutes) storageAction=\(storageAction.rawValue)")
    }

    private func launchRealApplication() -> XCUIApplication {
        let application = XCUIApplication()
        application.terminate()
        // The shipping configuration, with no audit or fixture flags at all.
        application.launchEnvironment = [:]
        application.launchArguments = []
        app = application
        application.launch()
        note("Launched com.hinoshiba.pomogem with no launch arguments or environment.")
        return application
    }

    private func require(_ condition: Bool, _ message: String, evidence: String? = nil) throws {
        guard !condition else { return }
        if let evidence {
            capture(evidence)
            if let app { dumpHierarchy(app, name: evidence) }
        }
        note("FAIL: \(message)")
        XCTFail(message)
        throw AuditFailure.stopped
    }

    private func skipWithEvidence(_ name: String, _ message: String) throws -> Never {
        capture(name)
        if let app { dumpHierarchy(app, name: name) }
        note("SKIP: \(message)")
        throw XCTSkip(message)
    }

    private func tap(_ element: XCUIElement, _ description: String) throws {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"),
            object: element
        )
        guard XCTWaiter.wait(for: [ready], timeout: 20) == .completed else {
            capture("unreachable-\(description)")
            XCTFail("Required control is missing, disabled or obscured: \(description).")
            throw AuditFailure.stopped
        }
        element.tap()
    }

    @discardableResult
    private func reveal(_ element: XCUIElement, upwards: Bool = true, attempts: Int = 14) -> Bool {
        guard let app else { return false }
        return reveal(element: element, in: app, upwards: upwards, attempts: attempts)
    }

    @discardableResult
    private func reveal(
        element: XCUIElement,
        in application: XCUIApplication,
        upwards: Bool = true,
        attempts: Int = 14
    ) -> Bool {
        for _ in 0..<attempts {
            if element.exists {
                let top = application.navigationBars.allElementsBoundByIndex
                    .filter(\.isHittable).map(\.frame.maxY).max() ?? 0
                let bottom = application.windows.firstMatch.frame.maxY - 36
                let frame = element.frame
                if frame.height > 0, frame.width > 0 {
                    if frame.minY >= top && frame.maxY <= bottom { return true }
                    if frame.maxY <= top { application.swipeDown(velocity: .fast); continue }
                    if frame.minY >= bottom { application.swipeUp(velocity: .fast); continue }
                    return true
                }
            }
            if upwards { application.swipeUp(velocity: .fast) } else { application.swipeDown(velocity: .fast) }
        }
        return element.exists
    }

    /// The sanctioned XCTest sleep: an inverted expectation that always
    /// times out. Unlike `waitForExistence` it does not query the app.
    private func pause(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let expectation = XCTestExpectation(description: "pause \(seconds)")
        expectation.isInverted = true
        _ = XCTWaiter().wait(for: [expectation], timeout: seconds)
    }

    private func note(_ line: String) {
        transcript.append("\(ISO8601DateFormatter().string(from: Date())) \(line)")
        NSLog("[pomogem-screen-time-audit] %@", line)
    }

    private func capture(_ name: String) {
        attachmentIndex += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%02d-%@", attachmentIndex, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attach(string: String, name: String) {
        attachmentIndex += 1
        let attachment = XCTAttachment(string: string)
        attachment.name = String(format: "%02d-%@", attachmentIndex, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func dumpHierarchy(_ element: XCUIElement, name: String) {
        attach(string: element.debugDescription, name: "\(name)-hierarchy")
    }

    private func dumpHierarchy(_ application: XCUIApplication, name: String) {
        attach(string: application.debugDescription, name: "\(name)-hierarchy")
    }

    private func flushTranscript() {
        guard !transcript.isEmpty else { return }
        let attachment = XCTAttachment(string: transcript.joined(separator: "\n"))
        attachment.name = "00-screen-time-audit-transcript"
        attachment.lifetime = .keepAlways
        add(attachment)
        transcript.removeAll()
    }
}
