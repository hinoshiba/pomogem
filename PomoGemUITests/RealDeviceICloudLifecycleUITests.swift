import XCTest

/// Opt-in audit of the shipping UI against the device's real Apple Account.
/// Set these in the UI TEST RUNNER's private .xctestrun EnvironmentVariables:
///   POMOGEM_REAL_ICLOUD_AUDIT=1
///   POMOGEM_REAL_ICLOUD_PHASE=seed | relaunch | restore | reset | mount-existing
///     | timer-running | timer-paused | local-seed | local-relaunch | local-reset
///     | offline | timer-start-for-uninstall | timer-restore
///     | theme-delete | theme-delete-restore | theme-deleted-relaunch
///     | offline-online | offline-use | offline-relaunch | offline-recover | offline-warm | offline-cleanup | offline-resume
/// Offline-use phases accept POMOGEM_REAL_ICLOUD_THEME_NAME only in the runner
/// to select an existing independently retained synthetic Development theme.
///   POMOGEM_REAL_ICLOUD_RUN_PREFIX=<unique 8...24 ASCII letters/digits/hyphens>
/// Run one matching test at a time, preserving the same prefix. Run restore only
/// after independently uninstalling/reinstalling the app, before the reset phase.
/// Seed requires a clean installation and empty test account data. Cloud reset
/// must be unavailable. Local-seed requires a separate clean installation;
/// local-reset explicitly performs the destructive visible-record reset there.
/// Timer phases require the cloud audit theme and no already-running timer.
/// Offline starts ONLINE with an existing cloud installation. Activate external
/// network loss only after POMOGEM_REAL_NETWORK_ARM_READY appears; the runner
/// waits 45 seconds before relaunching the terminated target. An OS certificate
/// or launch failure is not evidence of the app's offline behavior.
/// Offline-warm keeps a real running timer open through the loss window, then
/// backgrounds/activates the same process. Restore external networking during
/// its POMOGEM_REAL_NETWORK_RESTORE_READY window before the explicit online retry.
/// Offline-cleanup is a separate operator-selected phase after an interrupted
/// audit. It requires a paused timer for the exact retained synthetic theme,
/// then cancels only that timer through the ordinary UI. Retain the interrupted
/// store snapshot first; teardown never performs this cleanup automatically.
/// Offline-resume explicitly resumes an interrupted audit from its retained
/// paused timer and manual record, including a fresh externally offline launch.
/// Timer-start-for-uninstall deliberately leaves a paused active
/// timer; confirm its server upload before uninstalling and running timer-restore.
/// Run theme-delete after timer phases. Before uninstalling for theme-delete-restore,
/// independently verify the original Subject record's uploaded deletion tombstone.
/// Theme-deleted-relaunch only verifies an already deleted theme across two launches.
/// Do not configure StoreKitConfigurationFile, UITargetAppEnvironmentVariables,
/// or fixture launch arguments in the .xctestrun file. No audit flags are passed
/// to the app. Restore requires fresh storage selection and remote hydration;
/// retain independent uninstall/server evidence to establish its provenance.
@MainActor
final class RealDeviceICloudLifecycleUITests: XCTestCase {
    private enum Phase: String, CaseIterable {
        case seed, relaunch, restore, reset
        case mountExisting = "mount-existing"
        case timerRunning = "timer-running"
        case timerPaused = "timer-paused"
        case localSeed = "local-seed"
        case localRelaunch = "local-relaunch"
        case localReset = "local-reset"
        case offline
        case offlineOnline = "offline-online", offlineUse = "offline-use"
        case offlineRelaunch = "offline-relaunch", offlineRecover = "offline-recover"
        case offlineWarm = "offline-warm"
        case offlineCleanup = "offline-cleanup"
        case offlineResume = "offline-resume"
        case timerStartForUninstall = "timer-start-for-uninstall"
        case timerRestore = "timer-restore"
        case themeDelete = "theme-delete"
        case themeDeleteRestore = "theme-delete-restore"
        case themeDeletedRelaunch = "theme-deleted-relaunch"
    }
    private enum AuditFailure: Error { case failed }
    private enum ScrollDirection { case up, down }

    private var app: XCUIApplication?
    private var phase: Phase?
    private var themeName = ""
    private var didLaunch = false
    private var retainedFailureEvidence = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 420
#if targetEnvironment(simulator)
        throw XCTSkip("Real iCloud lifecycle auditing requires an explicitly authorized physical iPhone.")
#else
        let environment = ProcessInfo.processInfo.environment
        guard environment["POMOGEM_REAL_ICLOUD_AUDIT"] == "1" else {
            throw XCTSkip("Set POMOGEM_REAL_ICLOUD_AUDIT=1 in the test runner to opt in.")
        }
        let permittedKeys: Set<String> = [
            "POMOGEM_REAL_ICLOUD_AUDIT", "POMOGEM_REAL_ICLOUD_PHASE",
            "POMOGEM_REAL_ICLOUD_RUN_PREFIX", "POMOGEM_REAL_ICLOUD_THEME_NAME"
        ]
        let unexpectedFlags = environment.keys.filter {
            ($0.hasPrefix("POMOGEM_") && !permittedKeys.contains($0))
                || $0 == "XCODE_RUNNING_FOR_PREVIEWS"
                || $0 == "StoreKitConfigurationFile"
        }
        try require(unexpectedFlags.isEmpty, "Remove preview, mock, and fixture flags from the runner environment.")
        phase = Phase(rawValue: environment["POMOGEM_REAL_ICLOUD_PHASE"] ?? "")
        try require(phase != nil, "Choose one runner phase: \(Phase.allCases.map(\.rawValue).joined(separator: ", ")).")
        let prefix = environment["POMOGEM_REAL_ICLOUD_RUN_PREFIX"] ?? ""
        try require(prefix.range(of: "^[A-Za-z0-9-]{8,24}$", options: .regularExpression) != nil,
                    "Supply a unique 8...24-character ASCII run prefix; reuse it for all phases.")
        themeName = "PomoGemAudit-\(prefix)"
        if let existingName = environment["POMOGEM_REAL_ICLOUD_THEME_NAME"] {
            try require([.offlineOnline, .offlineUse, .offlineRelaunch, .offlineRecover, .offlineWarm, .offlineCleanup, .offlineResume].contains(phase!),
                        "An existing synthetic theme override is limited to explicit offline audit phases.")
            try require(existingName.range(of: "^[A-Za-z0-9 -]{8,64}$", options: .regularExpression) != nil,
                        "Use an exact bounded synthetic ASCII theme name from the independently retained source snapshot.")
            themeName = existingName
        }
#endif
    }

    override func tearDownWithError() throws {
        if didLaunch, (testRun?.failureCount ?? 0) > 0 { retainEvidence(failure: true) }
        app?.terminate()
        app = nil
    }

    func testExistingCloudStoreReopensAndRemainsConnected() throws {
        try select(.mountExisting)
        let app = launchRealApplication()
        try require(app.buttons["メニュー"].waitForExistence(timeout: 120),
                    "The existing cloud store must open after an in-place app update.")
        try require(!app.staticTexts["保存領域を確認できません"].exists,
                    "Framework asset directories must not invalidate the existing store.")
        try openSettingsAndRequireRealCloud()
        try returnHome(from: "設定")
        retainEvidence(failure: false)
    }

    func testSeedCleanRealICloudOnboardingAndManualRecord() throws {
        try select(.seed)
        let app = launchRealApplication()
        let cloudChoice = app.buttons["iCloudに保存して同期"]
        try require(cloudChoice.waitForExistence(timeout: 60),
                    "Seed must start at the real storage choice. Do not reuse an initialized installation.")
        try tap(cloudChoice)
        let confirmation = app.alerts["iCloudに保存して同期しますか？"]
        try require(confirmation.waitForExistence(timeout: 5), "The real iCloud disclosure must be confirmed.")
        try tap(confirmation.buttons["確認して続ける"])

        try completeOnboardingWithAuditTheme()
        try selectAuditTheme()

        try openSettingsAndRequireRealCloud()
        try checkKeepAwake(expected: false, setIfNeeded: true)
        try returnHome(from: "設定")
        try openLog()
        try assertEmptyRecordState()
        try returnHome(from: "記録")
        try addAuditManualRecord()
        try openLog()
        try assertAuditRecordAndTotals()
        retainEvidence(failure: false)
    }

    private func completeOnboardingWithAuditTheme() throws {
        let app = app!
        let next = app.buttons["onboarding.next"]
        try require(next.waitForExistence(timeout: 120), "The selected real store must reach onboarding.")
        try require(app.descendants(matching: .any)["onboarding.step"].label.contains("1ページ"),
                    "Seed requires the first onboarding page.")
        try tap(next)
        try require(waitForLabel(app.descendants(matching: .any)["onboarding.step"], containing: "2ページ"),
                    "Onboarding must reach the optional trial page.")
        try tap(next)
        try require(app.staticTexts["最初のテーマを選ぶ"].waitForExistence(timeout: 5),
                    "Onboarding must reach real theme creation.")
        let nameField = app.textFields["例：英語、TOEIC、企画、開発"]
        try scrollTo(nameField)
        try tap(nameField)
        nameField.typeText(themeName)
        try tap(app.buttons["選択"])
        let selection = app.descendants(matching: .any)["onboarding.selection-summary"]
        try require(waitForLabel(selection, containing: themeName), "The unique audit theme must be selected.")
        try tap(next)
        try requireHome()
    }

    private func addAuditManualRecord() throws {
        let app = app!
        try openMenuAction("時間を手動で積む")
        try require(waitForLabel(app.buttons["manual.subject-picker"], containing: themeName, timeout: 5),
                    "The manual record must belong to the unique audit theme.")
        try tap(app.buttons["30分、300グラム加算"])
        let confirm = app.buttons["manual.confirm"]
        try scrollTo(confirm)
        try tap(confirm)
        try requireHome()
    }

    func testColdRelaunchRetainsRealICloudThemeRecordAndSetting() throws {
        try select(.relaunch)
        _ = launchRealApplication()
        try requireHome()
        try selectAuditTheme()
        try openSettingsAndRequireRealCloud()
        try checkKeepAwake(expected: false)
        try returnHome(from: "設定")
        try openLog()
        try assertAuditRecordAndTotals()
        retainEvidence(failure: false)
    }

    func testReinstallRestoresRealICloudThemeRecordAndSetting() throws {
        try select(.restore)
        let app = launchRealApplication()
        let cloudChoice = app.buttons["iCloudに保存して同期"]
        try require(cloudChoice.waitForExistence(timeout: 60),
                    "Restore requires an independently uninstalled/reinstalled app at fresh storage selection; cold relaunch is insufficient.")
        try tap(cloudChoice)
        let confirmation = app.alerts["iCloudに保存して同期しますか？"]
        try require(confirmation.waitForExistence(timeout: 5), "The real iCloud disclosure must be confirmed again.")
        try tap(confirmation.buttons["確認して続ける"])

        // Synced Prefs.hasCompletedOnboarding or prior sessions must replace
        // onboarding automatically. Advancing onboarding would manufacture the
        // state this phase needs to prove and could overwrite restored settings.
        let hydrationDeadline = Date().addingTimeInterval(180)
        let onboardingTimeout = try remainingHydrationTime(until: hydrationDeadline)
        try require(app.buttons["メニュー"].waitForExistence(timeout: onboardingTimeout),
                    "Remote onboarding/preferences or prior records did not hydrate within 180 seconds. Do not finish onboarding to bypass this failure.")
        try selectAuditTheme(timeout: remainingHydrationTime(until: hydrationDeadline))
        try openSettingsAndRequireRealCloud(timeout: remainingHydrationTime(until: hydrationDeadline))
        try checkKeepAwake(expected: false, timeout: remainingHydrationTime(until: hydrationDeadline))
        try returnHome(from: "設定")
        try openLog()
        let recordTimeout = try remainingHydrationTime(until: hydrationDeadline)
        try require(summary(value: "30m", title: "積んだ時間").waitForExistence(
            timeout: recordTimeout),
                    "The original manual record did not hydrate from iCloud within the restore budget.")
        try assertAuditRecordAndTotals()
        retainEvidence(failure: false)
    }

    func testCloudVisibleResetIsUnavailableAndRetainsRecords() throws {
        try select(.reset)
        let app = launchRealApplication()
        try requireHome()
        try selectAuditTheme()
        try openLog()
        try assertAuditRecordAndTotals()
        try returnHome(from: "記録")
        try openSettingsAndRequireRealCloud()
        try checkKeepAwake(expected: false)
        let reset = app.buttons["settings.activity-reset"]
        try scrollTo(reset, attempts: 28)
        try require(!reset.isEnabled, "Cloud reset must be disabled until delayed reset-generation imports are safe.")
        let reason = app.descendants(matching: .any)["settings.activity-reset-unavailable"]
        try scrollTo(reason)
        try require(reason.label.contains("iCloudのリセットは一時的に利用できません"),
                    "The cloud reset restriction must explain why the action is unavailable.")
        try require(!app.alerts["表示中の記録をリセット"].exists, "A disabled cloud reset must not open a confirmation.")
        try returnHome(from: "設定")
        try openLog()
        try assertAuditRecordAndTotals()
        retainEvidence(failure: false)
    }

    func testRunningTimerSurvivesRealProcessRelaunch() throws {
        try select(.timerRunning)
        _ = launchRealApplication()
        try prepareCloudTimerAudit()
        try startRealTwentyFiveMinuteTimer()
        let before = try requireRunningCountdown()
        let sampledAt = Date()
        _ = launchRealApplication()
        try requireFocus(paused: false)
        let after = try timerRemainingSeconds()
        let elapsed = Date().timeIntervalSince(sampledAt)
        try require(after > 0 && after < before, "A running timer must consume real elapsed time across process termination.")
        try require(abs(Double(before - after) - elapsed) <= 8,
                    "Recovered running time must match wall-clock elapsed time, without restarting the 25-minute duration.")
        _ = try requireRunningCountdown()
        retainEvidence(failure: false)
        try cancelAuditTimerAndRequireDurableHome()
    }

    func testPausedTimerSurvivesRelaunchThenResumes() throws {
        try select(.timerPaused)
        _ = launchRealApplication()
        try prepareCloudTimerAudit()
        try startRealTwentyFiveMinuteTimer()
        _ = try requireRunningCountdown()
        try tap(app!.buttons["一時停止"])
        try requireFocus(paused: true)
        let pausedSeconds = try timerRemainingSeconds()
        _ = launchRealApplication()
        try requireFocus(paused: true)
        let restoredSeconds = try timerRemainingSeconds()
        try require(restoredSeconds == pausedSeconds,
                    "A paused timer must recover the exact saved remaining seconds.")
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", focusTimer.value as? String ?? ""),
            object: focusTimer
        )
        changed.isInverted = true
        try require(XCTWaiter.wait(for: [changed], timeout: 3) == .completed,
                    "A recovered paused timer must remain stationary without an explicit resume.")
        try tap(app!.buttons["再開する"])
        try requireFocus(paused: false)
        let resumedSeconds = try requireRunningCountdown()
        try require(resumedSeconds < pausedSeconds, "Explicit resume must continue the saved countdown.")
        retainEvidence(failure: false)
        try cancelAuditTimerAndRequireDurableHome()
    }

    func testOfflineCloudLaunchUsesPreviouslyVerifiedLocalCopy() async throws {
        try select(.offline)
        _ = launchRealApplication()
        try requireHome()
        try require(!offlineBanner.exists,
                    "The network arm window requires a verified online session before external network loss.")
        // iOS may need the network to trust this development-signed runner and
        // target. Finish both initial launches before the operator enables loss.
        app!.terminate()
        NSLog("POMOGEM_REAL_NETWORK_ARM_READY")
        try await Task.sleep(for: .seconds(45))
        NSLog("POMOGEM_REAL_NETWORK_RELAUNCH_BEGIN")
        let started = ProcessInfo.processInfo.systemUptime
        let app = launchRealApplication()
        try requireOfflineAuditHome(timeout: 30)
        try requireOfflineBanner()
        recordOfflineLaunchTiming(started: started, expectation: "verifiedCacheNetworkLoss")
        try require(!app.staticTexts["保存領域を確認できません"].exists,
                    "The previously verified cache must remain usable during independently applied network loss.")
        try require(!app.buttons["iCloudに保存して同期"].exists
                    && !app.buttons["このiPhoneだけに保存"].exists
                    && !app.buttons["このiPhoneだけで始める"].exists,
                    "An existing cloud installation must not offer a replacement local store or new storage choice.")
        retainEvidence(failure: false)
    }

    func testNormalOnlineCloudLaunchForOfflineAudit() throws {
        try select(.offlineOnline)
        let started = ProcessInfo.processInfo.systemUptime
        _ = launchRealApplication()
        try requireOfflineAuditHome(timeout: 30)
        recordOfflineLaunchTiming(started: started, expectation: "onlineBaseline")
        try require(!offlineBanner.exists, "The independently online baseline must publish a verified cloud session, not silently time out to an offline copy.")
        try selectAuditTheme()
        try openSettingsAndRequireRealCloud(timeout: 30)
        try checkKeepAwake(expected: false)
        try returnHome(from: "設定")
        retainEvidence(failure: false)
    }

    /// The runner remains online until the ordinary app and runner have both
    /// launched. The operator applies real network loss during the explicit
    /// arm window, and independently saves the condition receipt.
    func testRealOfflineColdLaunchAllowsManualRecordAndTimerAcrossRelaunch() async throws {
        try select(.offlineUse)
        _ = launchRealApplication()
        try requireOfflineAuditHome(timeout: 30)
        try require(!offlineBanner.exists, "The network arm window requires the verified online baseline first.")
        try selectAuditTheme()
        app!.terminate()
        NSLog("POMOGEM_REAL_NETWORK_ARM_READY")
        try await Task.sleep(for: .seconds(45))
        NSLog("POMOGEM_REAL_NETWORK_RELAUNCH_BEGIN")
        let started = ProcessInfo.processInfo.systemUptime
        _ = launchRealApplication()
        try requireOfflineAuditHome(timeout: 30)
        try requireOfflineBanner()
        recordOfflineLaunchTiming(started: started, expectation: "coldNetworkLoss")
        try selectAuditTheme()
        try openLog()
        try require(!auditHistoryRow.exists, "The chosen synthetic theme must not already have the 30-minute manual row this phase creates.")
        try returnHome(from: "記録")
        try addAuditManualRecord()
        try openLog()
        try scrollTo(auditHistoryRow, attempts: 24)
        try require(auditHistoryRow.exists, "The real offline manual save must immediately appear in history.")
        try returnHome(from: "記録")
        // Returning from another app must retain the admitted offline session;
        // activate() deliberately does not terminate/relaunch the target.
        XCUIDevice.shared.press(.home)
        app!.activate()
        try requireOfflineAuditHome(timeout: 10)
        try requireOfflineBanner()
        try selectAuditTheme()
        try openLog()
        try scrollTo(auditHistoryRow, attempts: 24)
        try require(auditHistoryRow.exists, "An offline foreground transition must retain the manually saved row.")
        try returnHome(from: "記録")
        try startRealTwentyFiveMinuteTimer()
        _ = try requireRunningCountdown()
        try tap(app!.buttons["一時停止"])
        try requireFocus(paused: true)
        let paused = try timerRemainingSeconds()
        XCUIDevice.shared.press(.home)
        app!.activate()
        try requireFocus(paused: true, timeout: 10)
        try requireOfflineBanner()
        let resumedFromBackgroundPaused = try timerRemainingSeconds()
        try require(resumedFromBackgroundPaused == paused,
                    "A paused offline timer must keep its exact remainder across background/foreground.")
        _ = launchRealApplication()
        try requireFocus(paused: true, timeout: 30)
        try requireOfflineBanner()
        let restoredPaused = try timerRemainingSeconds()
        try require(restoredPaused == paused,
                    "A real offline timer must retain its exact paused remainder across process termination.")
        try tap(app!.buttons["再開する"])
        _ = try requireRunningCountdown()
        try cancelAuditTimerAndRequireDurableHome()
        try requireOfflineBanner()
        try selectAuditTheme()
        try openLog()
        try scrollTo(auditHistoryRow, attempts: 24)
        try require(auditHistoryRow.exists, "The offline manual row must survive the timer's stop and another cold process launch.")
        retainEvidence(failure: false)
    }

    func testOfflineManualRecordRemainsAfterIndependentColdRelaunch() throws {
        try select(.offlineRelaunch)
        let started = ProcessInfo.processInfo.systemUptime
        _ = launchRealApplication()
        try requireOfflineAuditHome(timeout: 30)
        try requireOfflineBanner()
        recordOfflineLaunchTiming(started: started, expectation: "offlineColdRelaunchAfterWrites")
        try require(!focusTimer.exists, "The previously cancelled offline timer must remain cancelled.")
        try selectAuditTheme()
        try openLog()
        try scrollTo(auditHistoryRow, attempts: 24)
        try require(auditHistoryRow.exists, "The real offline manual row must survive an independently scheduled fresh process.")
        retainEvidence(failure: false)
    }

    func testInterruptedOfflineAuditResumesPausedTimerAndRetainsManualRecord() async throws {
        try select(.offlineResume)
        _ = launchRealApplication()
        try requireFocus(paused: true, timeout: 30)
        try require(!offlineBanner.exists, "Arm network loss only after the updated ordinary app verifies its online session.")
        let paused = try timerRemainingSeconds()
        try require((1...1500).contains(paused), "Resume only the previously retained synthetic 25-minute timer.")
        app!.terminate()
        NSLog("POMOGEM_REAL_NETWORK_ARM_READY")
        try await Task.sleep(for: .seconds(45))
        NSLog("POMOGEM_REAL_NETWORK_RELAUNCH_BEGIN")
        _ = launchRealApplication()
        try requireFocus(paused: true, timeout: 30)
        try requireOfflineBanner()
        let restoredPaused = try timerRemainingSeconds()
        try require(restoredPaused == paused,
                    "A fresh offline process must recover the exact independently retained paused remainder.")
        try tap(app!.buttons["再開する"])
        try requireFocus(paused: false, timeout: 10)
        let resumed = try requireRunningCountdown()
        try require(resumed < paused, "An actual delivered resume must advance the retained countdown offline.")
        retainEvidence(failure: false)
        try cancelAuditTimerAndRequireDurableHome()
        try requireOfflineBanner()
        try selectAuditTheme()
        try openLog()
        try scrollTo(auditHistoryRow, attempts: 24)
        try require(auditHistoryRow.exists,
                    "The independently retained offline manual record must survive timer resume, cancellation and another cold launch.")
        retainEvidence(failure: false)
    }

    func testNetworkLossDuringTimerAndWarmOnlineRetryRetainPausedTime() async throws {
        try select(.offlineWarm)
        _ = launchRealApplication()
        try requireOfflineAuditHome(timeout: 30)
        try require(!offlineBanner.exists && !focusTimer.exists,
                    "The warm network test requires a verified online Home without an active timer.")
        try selectAuditTheme()
        try startRealTwentyFiveMinuteTimer()
        let beforeLoss = try requireRunningCountdown()
        NSLog("POMOGEM_REAL_NETWORK_ARM_READY")
        try await Task.sleep(for: .seconds(45))
        let duringLoss = try requireRunningCountdown()
        try require(duringLoss < beforeLoss - 30,
                    "The ordinary cloud timer must keep counting while external network loss is active.")
        try tap(app!.buttons["一時停止"])
        try requireFocus(paused: true, timeout: 10)
        let paused = try timerRemainingSeconds()
        XCUIDevice.shared.press(.home)
        app!.activate()
        let onlineRetry = app!.buttons["cloud-offline-online-retry"]
        try require(onlineRetry.waitForExistence(timeout: 30) && onlineRetry.isEnabled,
                    "When a prior cloud mirror prevents offline reopening, a bounded notice must still allow an explicit online retry.")
        try require(!app!.buttons["cloud-offline-continue"].exists,
                    "A process that opened a cloud mirror must not offer an offline action it cannot safely perform.")
        try require(!app!.buttons["iCloudに保存して同期"].exists
                    && !app!.buttons["このiPhoneだけに保存"].exists,
                    "The warm retry notice must not replace the initialized data with fresh storage selection.")
        retainEvidence(failure: false)
        NSLog("POMOGEM_REAL_NETWORK_RESTORE_READY")
        try await Task.sleep(for: .seconds(45))
        try tap(onlineRetry)
        try requireFocus(paused: true, timeout: 30)
        let afterRecovery = try timerRemainingSeconds()
        try require(afterRecovery == paused,
                    "The explicit online retry must restore the same paused countdown without restarting the app.")
        try require(!offlineBanner.exists,
                    "Successful online recovery must finish the guarded cloud mount.")
        retainEvidence(failure: false)
        try cancelAuditTimerAndRequireDurableHome()
    }

    func testOnlineRecoveryRetainsOfflineManualRecord() throws {
        try select(.offlineRecover)
        let started = ProcessInfo.processInfo.systemUptime
        _ = launchRealApplication()
        try requireOfflineAuditHome(timeout: 30)
        recordOfflineLaunchTiming(started: started, expectation: "onlineRecovery")
        try require(!offlineBanner.exists, "After independently restoring connectivity, normal startup must verify its cloud session within the connection budget.")
        try require(!focusTimer.exists, "The cancelled offline timer must not return during cloud import.")
        try selectAuditTheme()
        try openSettingsAndRequireRealCloud(timeout: 30)
        try checkKeepAwake(expected: false)
        try returnHome(from: "設定")
        try openLog()
        try scrollTo(auditHistoryRow, attempts: 24)
        try require(auditHistoryRow.exists, "Reconnecting must retain the exact offline manual activity in the ordinary UI.")
        retainEvidence(failure: false)
    }

    func testInterruptedOfflineAuditPausedTimerCanBeCancelledExplicitly() throws {
        try select(.offlineCleanup)
        let app = launchRealApplication()
        try requireFocus(paused: true, timeout: 30)
        let subject = app.staticTexts["focus.subject"]
        try require(subject.waitForExistence(timeout: 5) && subject.label == themeName,
                    "Cleanup must target the exact independently retained synthetic audit theme.")
        let pausedSeconds = try timerRemainingSeconds()
        try require((1...1500).contains(pausedSeconds),
                    "An interrupted audit must restore its paused 25-minute timer before cleanup.")
        retainEvidence(failure: false)
        try cancelAuditTimerAndRequireDurableHome()
        retainEvidence(failure: false)
    }

    private var offlineBanner: XCUIElement {
        app!.buttons.matching(identifier: "cloud-offline-details").firstMatch
    }

    private func requireOfflineAuditHome(timeout: TimeInterval) throws {
        let home = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: app!.buttons["メニュー"])
        try require(XCTWaiter.wait(for: [home], timeout: timeout) == .completed,
                    "Cached cloud data must publish usable Home within the bounded launch allowance.")
        try require(!app!.buttons["onboarding.next"].exists && !app!.buttons["iCloudに保存して同期"].exists,
                    "Existing cloud data must not be replaced by onboarding or a new storage chooser.")
    }

    private func requireOfflineBanner() throws {
        try require(offlineBanner.waitForExistence(timeout: 5), "The ordinary offline session must clearly disclose local saving and delayed synchronization.")
        // UIKit retains the covered Home in full-screen AX snapshots. Check
        // the single actionable foreground control before reading its label;
        // an ambiguous query failure can invalidate later tap evidence.
        let foreground = app!.buttons.matching(identifier: "cloud-offline-details")
            .allElementsBoundByIndex.filter(\.isHittable)
        try require(foreground.count == 1,
                    "Exactly one foreground offline banner must be actionable.")
        try require(foreground[0].label.contains("このiPhoneに保存・iCloud同期は待機中"),
                    "The banner must show the user-facing offline persistence explanation.")
        let retryControls = app!.buttons.matching(identifier: "cloud-offline-retry")
            .allElementsBoundByIndex.filter(\.isHittable)
        try require(retryControls.count == 1,
                    "A cold offline copy must expose its guarded reconnect action, independently of a normally mirrored store's network notice.")
    }

    private func recordOfflineLaunchTiming(started: TimeInterval, expectation: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let values: [String: Any] = ["phase": expectation, "elapsedFromXCUIApplicationLaunchToHomeSeconds": elapsed,
            "offlineBannerPresent": offlineBanner.exists, "usesShippingHost": true,
            "networkConditionMustBeIndependentlyVerified": true, "timingIncludesXCTestLaunchOverhead": true]
        let data = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data()
        let item = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        item.name = "real-offline-launch-timing"
        item.lifetime = .keepAlways
        add(item)
        NSLog("POMOGEM_REAL_OFFLINE_LAUNCH phase=%@ elapsed=%.3f banner=%@", expectation, elapsed, offlineBanner.exists ? "true" : "false")
    }

    func testStartRealTimerAndPreserveItForUninstall() throws {
        try select(.timerStartForUninstall)
        _ = launchRealApplication()
        try prepareCloudTimerAudit()
        try startRealTwentyFiveMinuteTimer()
        _ = try requireRunningCountdown()
        try tap(app!.buttons["一時停止"])
        try requireFocus(paused: true)
        let remaining = try timerRemainingSeconds()
        try require((1...1500).contains(remaining), "The persisted audit timer must have a valid paused remainder.")
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", focusTimer.value as? String ?? ""),
            object: focusTimer
        )
        changed.isInverted = true
        try require(XCTWaiter.wait(for: [changed], timeout: 10) == .completed,
                    "The timer prepared for uninstall must remain paused while its normal persistence work proceeds.")
        let checkpoint = XCTAttachment(string: "Paused real 25-minute timer; remainingSeconds=\(remaining). Confirm the original session fingerprint and paused state on the server before uninstalling.")
        checkpoint.name = "timer-before-uninstall"
        checkpoint.lifetime = .keepAlways
        add(checkpoint)
        retainEvidence(failure: false)
        // tearDown terminates the process. Do not cancel or manufacture a
        // replacement timer: the next phase must recover this cloud session.
    }

    func testReinstallOffersAndRestoresTheOriginalCloudTimer() throws {
        try select(.timerRestore)
        let app = launchRealApplication()
        let cloudChoice = app.buttons["iCloudに保存して同期"]
        try require(cloudChoice.waitForExistence(timeout: 60),
                    "Timer restore requires an independently uninstalled/reinstalled app at fresh storage selection.")
        try tap(cloudChoice)
        let confirmation = app.alerts["iCloudに保存して同期しますか？"]
        try require(confirmation.waitForExistence(timeout: 5), "The real iCloud disclosure must be confirmed again.")
        try tap(confirmation.buttons["確認して続ける"])
        let offer = app.alerts["iCloudに進行中のタイマーがあります"]
        try require(offer.waitForExistence(timeout: 180),
                    "The uploaded paused timer must hydrate and produce an explicit cloud recovery offer; automatic local recovery or new onboarding cannot pass.")
        try require(offer.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", themeName)).firstMatch.exists,
                    "The cloud recovery offer must identify the original audit theme.")
        try tap(offer.buttons["この端末で続ける"])
        try requireFocus(paused: true)
        let remaining = try timerRemainingSeconds()
        try require((1...1500).contains(remaining),
                    "The original paused cloud timer must restore a valid remainder; expired completion is a different scenario.")
        let checkpoint = XCTAttachment(string: "Adopted paused cloud timer; remainingSeconds=\(remaining). Compare with timer-before-uninstall and the independent original session fingerprint.")
        checkpoint.name = "timer-after-reinstall"
        checkpoint.lifetime = .keepAlways
        add(checkpoint)
        retainEvidence(failure: false)
        try tap(app.buttons["再開する"])
        try requireFocus(paused: false)
        _ = try requireRunningCountdown()
        try cancelAuditTimerAndRequireDurableHome()
    }

    func testCleanLocalOnlyOnboardingAndManualRecord() throws {
        try select(.localSeed)
        let app = launchRealApplication()
        let localChoice = app.buttons["このiPhoneだけに保存"]
        try require(localChoice.waitForExistence(timeout: 60),
                    "Local-seed requires an independently clean installation at storage selection.")
        try tap(localChoice)
        let confirmation = app.alerts["このiPhoneだけに保存しますか？"]
        try require(confirmation.waitForExistence(timeout: 5), "Local-only storage requires its real disclosure.")
        try tap(confirmation.buttons["このiPhoneだけで始める"])
        try completeOnboardingWithAuditTheme()
        try selectAuditTheme()
        try openSettingsAndRequireLocalOnly()
        try checkKeepAwake(expected: false, setIfNeeded: true)
        try returnHome(from: "設定")
        try openLog()
        try assertEmptyRecordState()
        try returnHome(from: "記録")
        try addAuditManualRecord()
        try openLog()
        try assertAuditRecordAndTotals()
        retainEvidence(failure: false)
    }

    func testDeleteRealCloudThemePreservesRecordAndSetting() throws {
        try select(.themeDelete)
        let app = launchRealApplication()
        try requireHome()
        try require(!focusTimer.exists, "Finish the timer audit before deleting its theme.")
        try selectAuditTheme()
        try openLog()
        try assertAuditRecordAndTotals()
        try returnHome(from: "記録")
        try openSettingsAndRequireRealCloud()
        try checkKeepAwake(expected: false)
        let theme = app.buttons[themeName]
        try scrollTo(theme, direction: .down, attempts: 24)
        theme.swipeLeft()
        try tap(app.buttons["削除"])
        let confirmation = app.alerts["テーマを削除"]
        try require(confirmation.waitForExistence(timeout: 5), "Theme deletion must require its real confirmation.")
        try require(confirmation.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", "過去の記録", "質量は消えず"
        )).firstMatch.exists, "The deletion disclosure must promise to retain the existing record and mass.")
        try tap(confirmation.buttons["「\(themeName)」を削除"])
        try require(waitForAbsence(confirmation), "The deletion confirmation must finish.")
        try require(waitForAbsence(theme), "The deleted theme must disappear from Settings.")
        try require(!app.alerts["設定を完了できませんでした"].exists, "A failed theme save cannot pass as deletion.")
        try returnHome(from: "設定")
        try assertDeletedThemeAndRetainedData()
        _ = launchRealApplication()
        try requireHome()
        try assertDeletedThemeAndRetainedData()
        retainEvidence(failure: false)
    }

    func testReinstallRetainsCloudThemeDeletionAndOriginalRecord() throws {
        try select(.themeDeleteRestore)
        let app = launchRealApplication()
        let cloudChoice = app.buttons["iCloudに保存して同期"]
        try require(cloudChoice.waitForExistence(timeout: 60),
                    "Deletion restore requires an independently uninstalled/reinstalled app after server tombstone verification.")
        try tap(cloudChoice)
        let confirmation = app.alerts["iCloudに保存して同期しますか？"]
        try require(confirmation.waitForExistence(timeout: 5), "The real iCloud disclosure must be confirmed again.")
        try tap(confirmation.buttons["確認して続ける"])
        let deadline = Date().addingTimeInterval(180)
        let timeout = try remainingHydrationTime(until: deadline)
        try require(app.buttons["メニュー"].waitForExistence(timeout: timeout),
                    "Original remote preferences or records must hydrate; do not complete onboarding or create a replacement theme.")
        try assertDeletedThemeAndRetainedData(hydrationDeadline: deadline)
        _ = launchRealApplication()
        try requireHome()
        try assertDeletedThemeAndRetainedData()
        retainEvidence(failure: false)
    }

    func testDeletedCloudThemeRemainsDeletedAcrossTwoRelaunches() throws {
        try select(.themeDeletedRelaunch)
        for _ in 0..<2 {
            _ = launchRealApplication()
            try requireHome()
            try require(!focusTimer.exists, "Deleted-theme verification requires the completed timer audit.")
            try assertDeletedThemeAndRetainedData()
        }
        retainEvidence(failure: false)
    }

    func testLocalOnlyRelaunchRetainsThemeRecordAndSetting() throws {
        try select(.localRelaunch)
        _ = launchRealApplication()
        try requireHome()
        try selectAuditTheme()
        try openSettingsAndRequireLocalOnly()
        try checkKeepAwake(expected: false)
        try returnHome(from: "設定")
        try openLog()
        try assertAuditRecordAndTotals()
        retainEvidence(failure: false)
    }

    func testLocalOnlyVisibleResetClearsRecordsButRetainsThemeAndSetting() throws {
        try select(.localReset)
        let app = launchRealApplication()
        try requireHome()
        try selectAuditTheme()
        try openLog()
        try assertAuditRecordAndTotals()
        try returnHome(from: "記録")
        try openSettingsAndRequireLocalOnly()
        try checkKeepAwake(expected: false)
        let reset = app.buttons["settings.activity-reset"]
        try scrollTo(reset, attempts: 28)
        try require(reset.isEnabled, "Local-only visible-record reset must remain available.")
        try tap(reset)
        let confirmation = app.alerts["表示中の記録をリセット"]
        try require(confirmation.waitForExistence(timeout: 5), "Reset must require the ordinary confirmation.")
        try tap(confirmation.buttons["リセット"])
        try require(waitForAbsence(confirmation), "Reset confirmation must finish.")
        try require(!app.alerts["設定を完了できませんでした"].exists, "The persisted reset must not fail.")
        try checkKeepAwake(expected: false)
        try returnHome(from: "設定")
        try selectAuditTheme()
        try openLog()
        try assertEmptyRecordState()

        // A second fresh process must observe the durable reset, not only the
        // first view's transient empty presentation.
        app.terminate()
        _ = launchRealApplication()
        try requireHome()
        try selectAuditTheme()
        try openSettingsAndRequireLocalOnly()
        try checkKeepAwake(expected: false)
        try returnHome(from: "設定")
        try openLog()
        try assertEmptyRecordState()
        retainEvidence(failure: false)
    }

    private func select(_ required: Phase) throws {
        guard phase == required else { throw XCTSkip("Select the \(required.rawValue) runner phase for this test.") }
    }

    private func assertDeletedThemeAndRetainedData(hydrationDeadline: Date? = nil) throws {
        let app = app!
        let cloudTimeout = try hydrationDeadline.map { try remainingHydrationTime(until: $0) } ?? 90
        try openSettingsAndRequireRealCloud(timeout: cloudTimeout)
        let settingsTimeout = try hydrationDeadline.map { try remainingHydrationTime(until: $0) } ?? 5
        try checkKeepAwake(expected: false, timeout: settingsTimeout)
        try returnHome(from: "設定")
        try openLog()
        let recordTimeout = try hydrationDeadline.map { try remainingHydrationTime(until: $0) } ?? 10
        try require(summary(value: "30m", title: "積んだ時間").waitForExistence(timeout: recordTimeout),
                    "The original 1,800-second manual record must remain after theme deletion.")
        try assertAuditRecordAndTotals()
        try returnHome(from: "記録")

        // Positive imported history and nondefault settings precede absence checks.
        // The independent server phase proves the original physical tombstone;
        // UI absence alone cannot establish that CloudKit imported that row.
        let picker = app.buttons["home.subject-picker"]
        let launcher = app.buttons["home.focus-launcher"]
        try scrollTo(launcher, direction: .down)
        if launcher.label == "テーマを選んではじめる" {
            // Deleting the final theme removes the picker entirely. The exact
            // empty-state launcher opens Settings without starting a timer.
            try require(!picker.exists, "Home with no selected theme must show the documented empty-theme state.")
            try tap(launcher)
        } else {
            try scrollTo(picker, direction: .down)
            try require(!picker.label.contains(themeName), "Home must stop selecting the deleted theme.")
            try tap(picker)
            let manage = app.buttons["テーマを管理"]
            try require(manage.waitForExistence(timeout: 5), "The real theme menu must be open before checking absence.")
            try require(!app.buttons[themeName].exists, "The deleted theme must not be selectable from Home.")
            try tap(manage)
        }
        try require(app.navigationBars["設定"].waitForExistence(timeout: 5), "Theme management must open Settings.")
        try scrollTo(app.buttons["テーマを追加"], direction: .down, attempts: 24)
        try require(!app.buttons[themeName].exists, "The deleted theme must not return in Settings.")
        try returnHome(from: "設定")
    }

    private func launchRealApplication() -> XCUIApplication {
        let application = XCUIApplication()
        application.terminate()
        application.launchEnvironment = [:]
        application.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app = application
        didLaunch = true
        application.launch()
        return application
    }

    private func requireHome() throws {
        let home = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: app!.buttons["メニュー"]
        )
        try require(XCTWaiter.wait(for: [home], timeout: 120) == .completed,
                    "The explicitly selected real store must open. Persistence errors cannot pass as successful recovery.")
    }

    private func prepareCloudTimerAudit() throws {
        try requireHome()
        try require(!focusTimer.exists, "Timer auditing must begin without an existing active timer.")
        try selectAuditTheme()
        try openSettingsAndRequireRealCloud()
        try returnHome(from: "設定")
    }

    private var focusTimer: XCUIElement {
        app!.descendants(matching: .any)["focus.timer-display"].firstMatch
    }

    private func startRealTwentyFiveMinuteTimer() throws {
        let app = app!
        let duration = app.buttons["home.duration-picker"]
        try scrollTo(duration, direction: .down)
        try tap(duration)
        try tap(app.buttons["25分"])
        let launcher = app.buttons["home.focus-launcher"]
        try require(waitForLabel(launcher, containing: "25分集中する"),
                    "Timer auditing must use the real 25-minute preset, never a shortened fixture.")
        try tap(launcher)
        try requireFocus(paused: false)
        let remaining = try timerRemainingSeconds()
        try require((1400...1500).contains(remaining), "The initial countdown must match a real 25-minute timer.")
    }

    private func requireFocus(paused: Bool, timeout: TimeInterval = 120) throws {
        let app = app!
        try require(focusTimer.waitForExistence(timeout: timeout),
                    "The persisted timer must open automatically; missing recovery or an unexpected handoff offer is a failure.")
        let subject = app.staticTexts["focus.subject"]
        try require(waitForLabel(subject, containing: themeName), "Recovered focus must retain its original audit theme.")
        let expectedAction = app.buttons[paused ? "再開する" : "一時停止"]
        try require(expectedAction.waitForExistence(timeout: 10), "The timer must restore its saved running or paused state.")
        let state = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: paused ? "value CONTAINS %@" : "NOT (value CONTAINS %@)", "一時停止中"),
            object: focusTimer
        )
        try require(XCTWaiter.wait(for: [state], timeout: 10) == .completed,
                    "The accessible countdown must agree with the restored timer state.")
        try require(!app.alerts["タイマーを開始できませんでした"].exists
                    && !app.alerts["操作を完了できませんでした"].exists,
                    "Timer persistence or control errors cannot count as successful recovery.")
    }

    private func timerRemainingSeconds() throws -> Int {
        let value = focusTimer.value as? String ?? ""
        let expression = try NSRegularExpression(pattern: "残り([0-9]+)分([0-9]+)秒")
        guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let minutesRange = Range(match.range(at: 1), in: value),
              let secondsRange = Range(match.range(at: 2), in: value),
              let minutes = Int(value[minutesRange]), let seconds = Int(value[secondsRange]) else {
            try require(false, "The real timer must expose a readable remaining duration: \(value).")
            throw AuditFailure.failed
        }
        return minutes * 60 + seconds
    }

    private func requireRunningCountdown() throws -> Int {
        let before = try timerRemainingSeconds()
        let currentValue = focusTimer.value as? String ?? ""
        let progressed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@ AND NOT (value CONTAINS %@)", currentValue, "一時停止中"),
            object: focusTimer
        )
        try require(XCTWaiter.wait(for: [progressed], timeout: 10) == .completed,
                    "A running timer must visibly progress using actual elapsed time.")
        let after = try timerRemainingSeconds()
        try require(after < before && after > 0, "Running countdown seconds must decrease monotonically.")
        return after
    }

    private func cancelAuditTimerAndRequireDurableHome() throws {
        let app = app!
        let stop = app.buttons["今日はここまで"]
        try scrollTo(stop)
        try tap(stop)
        let confirmation = app.alerts["今日はここまで"]
        try require(confirmation.waitForExistence(timeout: 5), "Timer cancellation requires its ordinary confirmation.")
        try tap(confirmation.buttons["今日はここまで"])
        try requireHome()
        try require(waitForAbsence(focusTimer), "A cancelled timer must dismiss its focus screen.")
        _ = launchRealApplication()
        try requireHome()
        let resurrected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"), object: focusTimer
        )
        resurrected.isInverted = true
        try require(XCTWaiter.wait(for: [resurrected], timeout: 3) == .completed,
                    "A cancelled timer must not recover after a fresh launch.")
        try require(!app.alerts["iCloudに進行中のタイマーがあります"].exists,
                    "A cancelled timer must not return as a cloud handoff offer.")
    }

    private func selectAuditTheme(timeout: TimeInterval = 10) throws {
        let app = app!
        let picker = app.buttons["home.subject-picker"]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            try scrollTo(picker, direction: .down)
            try tap(picker)
            let theme = app.buttons[themeName]
            if theme.waitForExistence(timeout: min(3, max(0, deadline.timeIntervalSinceNow))) {
                try tap(theme)
                try require(waitForLabel(app.buttons["home.focus-launcher"], containing: themeName),
                            "Home must use the persisted audit theme.")
                return
            }
            try require(deadline.timeIntervalSinceNow > 0,
                        "The original audit theme did not hydrate; restore must not create a replacement theme.")
            // A native Menu can retain its opening snapshot while CloudKit
            // imports another theme. Use an ordinary, non-editing destination
            // to dismiss it, then reopen with the refreshed source collection.
            try tap(app.buttons["テーマを管理"])
            try returnHome(from: "設定")
        } while deadline.timeIntervalSinceNow > 0
        try require(false, "The persisted audit theme is missing after the hydration deadline.")
    }

    private func openMenuAction(_ title: String) throws {
        try tap(app!.buttons["メニュー"])
        let action = app!.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        try scrollTo(action)
        try tap(action)
    }

    private func openSettingsAndRequireRealCloud(timeout: TimeInterval = 90) throws {
        let app = app!
        try openMenuAction("設定")
        try require(app.navigationBars["設定"].waitForExistence(timeout: 10), "Settings must open.")
        let statusTitles = [
            "iCloudを確認中", "iCloudに接続できます", "iCloudは実機で確認できます",
            "Apple Accountへのサインインが必要です", "この端末ではiCloudが制限されています",
            "iCloudへ一時的に接続できません", "iCloudの状態を確認できません"
        ]
        let statusPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: statusTitles.map {
            NSPredicate(format: "label BEGINSWITH %@", $0)
        })
        try scrollTo(app.descendants(matching: .any).matching(statusPredicate).firstMatch, attempts: 24)
        let available = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "iCloudに接続できます")
        ).firstMatch
        try require(available.waitForExistence(timeout: timeout),
                    "Settings must complete its real online iCloud check; simulator/local-only/error states cannot pass.")
    }

    private func openSettingsAndRequireLocalOnly() throws {
        try openMenuAction("設定")
        try require(app!.navigationBars["設定"].waitForExistence(timeout: 10), "Settings must open.")
        let local = app!.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "このiPhoneだけに保存")
        ).firstMatch
        try scrollTo(local, attempts: 24)
        try require(local.exists, "The chosen local-only store must remain explicitly local after relaunch.")
        let disclosure = app!.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "iCloudへの自動送信・自動切り替えはありません")
        ).firstMatch
        try require(disclosure.exists, "Local-only settings must disclose that data is not automatically sent to iCloud.")
        let cloudStatus = app!.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "iCloudに接続できます")
        ).firstMatch
        try require(!cloudStatus.exists, "A local-only installation must not present an active iCloud store.")
    }

    private func checkKeepAwake(expected: Bool, setIfNeeded: Bool = false, timeout: TimeInterval = 5) throws {
        let toggle = app!.switches["settings.keep-screen-awake"]
        try scrollTo(toggle, direction: .down, attempts: 24)
        let expectedValue = expected ? "1" : "0"
        if setIfNeeded, toggle.value as? String != expectedValue {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expectedValue), object: toggle
        )
        try require(XCTWaiter.wait(for: [changed], timeout: timeout) == .completed,
                    "The audit's saved keep-screen-awake setting must be retained.")
    }

    private func returnHome(from title: String) throws {
        let bar = app!.navigationBars[title]
        try require(bar.waitForExistence(timeout: 5), "Missing navigation bar: \(title).")
        try tap(bar.buttons.element(boundBy: 0))
        try requireHome()
    }

    private func openLog() throws {
        try openMenuAction("記録を見る")
        try require(app!.navigationBars["記録"].waitForExistence(timeout: 10), "Record history must open.")
    }

    private var auditHistoryRow: XCUIElement {
        app!.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label CONTAINS %@",
            themeName + "、", "自己申告、プラス300グラム"
        )).firstMatch
    }

    private func summary(value: String, title: String) -> XCUIElement {
        // Token boundaries prevent 30m/300g from satisfying the zero checks.
        let pattern = "(?:.*[\\s,、])?" + NSRegularExpression.escapedPattern(for: value)
            + "[\\s,、]+" + NSRegularExpression.escapedPattern(for: title)
        return app!.descendants(matching: .any).matching(
            NSPredicate(format: "label MATCHES %@", pattern)
        ).firstMatch
    }

    private func assertAuditRecordAndTotals() throws {
        try scrollTo(summary(value: "30m", title: "積んだ時間"), direction: .down)
        try require(summary(value: "300g", title: "今期の質量").exists,
                    "The unique 30-minute record must contribute exactly 300g.")
        try scrollTo(auditHistoryRow, attempts: 24)
        try require(auditHistoryRow.exists, "The actual saved audit record is missing from history.")
    }

    private func assertEmptyRecordState() throws {
        try scrollTo(summary(value: "0m", title: "積んだ時間"), direction: .down)
        try require(summary(value: "0g", title: "今期の質量").exists, "Record mass must be zero.")
        try scrollTo(app!.staticTexts["一粒積むと、ここに記録が残ります。"], attempts: 24)
        try require(!auditHistoryRow.exists, "The reset audit record must not remain in history.")
    }

    private func tap(_ element: XCUIElement) throws {
        // Reading a missing element's identifier in the failure message would
        // resolve its snapshot before require evaluates the waiting condition.
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
            if direction == .up { app!.swipeUp() } else { app!.swipeDown() }
        }
        try require(element.exists && element.isHittable, "Could not reveal required content.")
    }

    private func remainingHydrationTime(until deadline: Date) throws -> TimeInterval {
        let remaining = deadline.timeIntervalSinceNow
        try require(remaining > 0, "Real iCloud restore exceeded its 180-second remote hydration budget.")
        return remaining
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", text), object: element
        )], timeout: timeout) == .completed
    }

    private func waitForAbsence(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element
        )], timeout: 10) == .completed
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        guard condition() else {
            retainEvidence(failure: true)
            XCTFail(message, file: file, line: line)
            throw AuditFailure.failed
        }
    }

    private func retainEvidence(failure: Bool) {
        guard didLaunch, let app, !failure || !retainedFailureEvidence else { return }
        if failure { retainedFailureEvidence = true }
        let name = "real-iCloud-\(phase?.rawValue ?? "setup")-\(failure ? "failure" : "verified")"
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
