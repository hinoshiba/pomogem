import XCTest

@MainActor
final class FortyYearPersistentColdLaunchUITests: XCTestCase {
    private var storeName = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Seeding 350,640 real SwiftData rows is intentionally much longer
        // than XCTest's default per-test watchdog. The assertions below still
        // enforce tight 15-second cold-launch and 5-second Settings budgets.
        executionTimeAllowance = 2_000
        storeName = "forty-year-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        guard !storeName.isEmpty else { return }
        let cleaner = configuredApp(action: "clean")
        cleaner.launch()
        XCTAssertTrue(
            cleaner.staticTexts["fixture.40y.cleaned"].waitForExistence(timeout: 15),
            "The test must remove only its named dedicated store"
        )
        cleaner.terminate()
    }

    func testRealFortyYearStoreSurvivesColdLaunchAndRelaunch() throws {
        let seeder = configuredApp(action: "seed")
        seeder.launch()
        XCTAssertTrue(
            seeder.staticTexts["fixture.40y.seeding"].waitForExistence(timeout: 10)
                || seeder.staticTexts["fixture.40y.ready"].exists
        )
        let ready = seeder.staticTexts["fixture.40y.ready"]
        XCTAssertTrue(
            ready.waitForExistence(timeout: 1_800),
            seeder.staticTexts["fixture.40y.error"].label
        )
        let readyFields = try fields(from: ready)
        XCTAssertEqual(readyFields["sessions"], "350640")
        XCTAssertEqual(readyFields["aggregates"], "38958")
        XCTAssertEqual(readyFields["uniqueAggregates"], "38958")
        XCTAssertEqual(readyFields["hierarchyClosed"], "true")
        assertExpected(readyFields)
        seeder.terminate()

        let firstColdLaunch = configuredApp()
        let firstHomeTimings = try launchAndAssertFirstInteractiveHome(
            firstColdLaunch
        )
        XCTContext.runActivity(named: String(
            format: "40-year first interactive Home elapsed: %.3fs",
            firstHomeTimings.firstInteractive
        )) { _ in }
        XCTContext.runActivity(named: String(
            format: "40-year first Home menu round trip elapsed: %.3fs",
            firstHomeTimings.menuRoundTrip
        )) { _ in }
        XCTAssertLessThan(
            firstHomeTimings.firstInteractive,
            15,
            "The first usable Home control must appear within 15 seconds"
        )
        XCTAssertLessThan(
            firstHomeTimings.menuRoundTrip,
            15,
            "The first Home menu must open and close within 15 seconds after its controls appear"
        )
        let firstProbe = try waitForStableFixtureProbe(in: firstColdLaunch, timeout: 30)
        assertExpected(firstProbe)
        firstColdLaunch.buttons["メニュー"].tap()
        let settings = firstColdLaunch.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "設定")
        ).firstMatch
        XCTAssertTrue(
            scrollUntilHittable(settings, in: firstColdLaunch),
            "Settings must remain reachable in the full Home menu"
        )
        settings.tap()
        XCTAssertTrue(firstColdLaunch.navigationBars["設定"].waitForExistence(timeout: 5))
        let settingsAudit = try waitForSettingsRenderAudit(in: firstColdLaunch)
        let settingsRenderMilliseconds = try integerField(
            "milliseconds",
            in: settingsAudit
        )
        XCTAssertLessThan(
            settingsRenderMilliseconds,
            5_000,
            "Settings must render within five in-app seconds without materializing the forty-year history"
        )
        XCTAssertLessThanOrEqual(
            try integerField("subjects", in: settingsAudit),
            16,
            "Settings must preserve its bounded Subject query"
        )
        XCTAssertLessThanOrEqual(
            try integerField("preferences", in: settingsAudit),
            16,
            "Settings must preserve its bounded Prefs query"
        )
        XCTAssertLessThanOrEqual(
            try integerField("resetMarkers", in: settingsAudit),
            1,
            "Settings must fetch only the current reset marker"
        )
        let initialCommitGeneration = try integerField(
            "commitGeneration",
            in: settingsAudit
        )
        let keepAwake = firstColdLaunch.switches["settings.keep-screen-awake"]
        XCTAssertTrue(
            scrollUntilHittable(keepAwake, in: firstColdLaunch),
            "A mounted Settings screen must remain interactive after 350,640 sessions"
        )
        let initialKeepAwakeValue = try XCTUnwrap(keepAwake.value as? String)
        let firstToggleStartedAt = ProcessInfo.processInfo.systemUptime
        tapSwitchControl(keepAwake)
        let didChangeKeepAwake = waitForValue(
            of: keepAwake,
            toDifferFrom: initialKeepAwakeValue
        )
        XCTAssertTrue(
            didChangeKeepAwake,
            "The keep-awake preference must visibly change after one tap; alert=\(alertDiagnostic(in: firstColdLaunch))"
        )
        let firstToggleElapsed = ProcessInfo.processInfo.systemUptime
            - firstToggleStartedAt
        let firstCommitAudit = try waitForSettingsCommitAudit(
            in: firstColdLaunch,
            afterGeneration: initialCommitGeneration
        )
        let firstCommitMilliseconds = try integerField(
            "commitMilliseconds",
            in: firstCommitAudit
        )
        let firstCommitGeneration = try integerField(
            "commitGeneration",
            in: firstCommitAudit
        )
        XCTContext.runActivity(named: String(
            format: "40-year keep-awake save elapsed: %.3fs XCUI / %dms app",
            firstToggleElapsed,
            firstCommitMilliseconds
        )) { _ in }
        XCTAssertEqual(firstCommitAudit["commitSucceeded"], "true")
        XCTAssertGreaterThan(firstCommitGeneration, initialCommitGeneration)
        XCTAssertGreaterThanOrEqual(firstCommitMilliseconds, 0)
        XCTAssertLessThan(
            firstCommitMilliseconds,
            4_000,
            "The in-app mutation and durable save must finish within four seconds"
        )
        // The strict durability budget comes from the in-process probe above.
        // This outer XCUI interval includes accessibility polling and app-wide
        // quiescence, so it is a deadlock watchdog rather than the save SLA.
        XCTAssertLessThan(
            firstToggleElapsed,
            10,
            "The XCUI round trip must not deadlock after saving one preference"
        )
        let secondToggleStartedAt = ProcessInfo.processInfo.systemUptime
        let restoreKeepAwake = firstColdLaunch.switches["settings.keep-screen-awake"]
        XCTAssertTrue(restoreKeepAwake.exists && restoreKeepAwake.isHittable)
        tapSwitchControl(restoreKeepAwake)
        XCTAssertTrue(
            waitForSwitchValue(
                in: firstColdLaunch,
                identifier: "settings.keep-screen-awake",
                toEqual: initialKeepAwakeValue
            ),
            "The reversible audit must restore the original preference"
        )
        let secondToggleElapsed = ProcessInfo.processInfo.systemUptime
            - secondToggleStartedAt
        let secondCommitAudit = try waitForSettingsCommitAudit(
            in: firstColdLaunch,
            afterGeneration: firstCommitGeneration
        )
        let secondCommitMilliseconds = try integerField(
            "commitMilliseconds",
            in: secondCommitAudit
        )
        let secondCommitGeneration = try integerField(
            "commitGeneration",
            in: secondCommitAudit
        )
        XCTContext.runActivity(named: String(
            format: "40-year keep-awake restore elapsed: %.3fs XCUI / %dms app",
            secondToggleElapsed,
            secondCommitMilliseconds
        )) { _ in }
        XCTAssertEqual(secondCommitAudit["commitSucceeded"], "true")
        XCTAssertGreaterThan(secondCommitGeneration, firstCommitGeneration)
        XCTAssertGreaterThanOrEqual(secondCommitMilliseconds, 0)
        XCTAssertLessThan(
            secondCommitMilliseconds,
            4_000,
            "The in-app restore and durable save must finish within four seconds"
        )
        // Keep the same coarse watchdog around the reversible audit; the app
        // probe remains the authoritative mutation-and-save measurement.
        XCTAssertLessThan(
            secondToggleElapsed,
            10,
            "The XCUI round trip must not deadlock after restoring one preference"
        )
        firstColdLaunch.navigationBars["設定"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(firstColdLaunch.buttons["メニュー"].waitForExistence(timeout: 5))
        assertExpected(try waitForStableFixtureProbe(in: firstColdLaunch, timeout: 10))
        firstColdLaunch.terminate()

        let secondColdLaunch = configuredApp()
        let secondHomeTimings = try launchAndAssertFirstInteractiveHome(
            secondColdLaunch
        )
        XCTContext.runActivity(named: String(
            format: "40-year second interactive Home elapsed: %.3fs",
            secondHomeTimings.firstInteractive
        )) { _ in }
        XCTContext.runActivity(named: String(
            format: "40-year second Home menu round trip elapsed: %.3fs",
            secondHomeTimings.menuRoundTrip
        )) { _ in }
        XCTAssertLessThan(
            secondHomeTimings.firstInteractive,
            15,
            "The relaunched first interactive Home must appear within 15 seconds"
        )
        XCTAssertLessThan(
            secondHomeTimings.menuRoundTrip,
            15,
            "The relaunched Home menu must open and close within 15 seconds after its controls appear"
        )
        let secondProbe = try waitForStableFixtureProbe(in: secondColdLaunch, timeout: 30)
        assertExpected(secondProbe)
        XCTAssertEqual(secondProbe, firstProbe, "Relaunch must preserve every projection invariant")
        secondColdLaunch.buttons["メニュー"].tap()
        let relaunchedSettings = secondColdLaunch.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "設定")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(relaunchedSettings, in: secondColdLaunch))
        relaunchedSettings.tap()
        XCTAssertTrue(secondColdLaunch.navigationBars["設定"].waitForExistence(timeout: 5))
        let persistedKeepAwake = secondColdLaunch.switches["settings.keep-screen-awake"]
        XCTAssertTrue(scrollUntilHittable(persistedKeepAwake, in: secondColdLaunch))
        XCTAssertEqual(
            persistedKeepAwake.value as? String,
            initialKeepAwakeValue,
            "The restored preference must survive a real cold relaunch"
        )

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "40-year persistent cold launch"
        attachment.lifetime = .keepAlways
        add(attachment)

        // 記録 over 350,640 sessions. Its period page, newest records,
        // aggregates, twelve month summaries and 年月 are all read off the
        // main thread, and a 今週／今月 toggle reads only the period page, so
        // the page answers while those reads are running. The budgets below
        // are the app's own measurements (LogLoadAudit). While one runs the
        // test leaves the app alone and waits for the audit's Darwin
        // notification: every XCUI query snapshots the app's accessibility
        // tree on the app's main thread, hundreds of milliseconds over this
        // screen, and would read as a stall of the app's own.
        secondColdLaunch.navigationBars["設定"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(secondColdLaunch.buttons["メニュー"].waitForExistence(timeout: 5))
        secondColdLaunch.buttons["メニュー"].tap()
        let log = secondColdLaunch.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "記録")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(log, in: secondColdLaunch))
        let logStartedAt = ProcessInfo.processInfo.systemUptime
        let openFinished = logLoadAuditFinished()
        log.tap()
        // 0.6 s after the push; the screenshot needs no query. Depending on
        // the Mac, the period page may already have arrived by then. The
        // placeholders themselves are pinned by
        // CriticalFlowAdversarialUITests.testLogSaysItIsReadingWhileItReads.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let openingAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        openingAttachment.name = "40-year persistent Log 0.6 s after opening"
        openingAttachment.lifetime = .keepAlways
        add(openingAttachment)
        wait(for: [openFinished], timeout: 60)
        XCTAssertTrue(secondColdLaunch.navigationBars["記録"].waitForExistence(timeout: 10))
        let period = secondColdLaunch.segmentedControls.firstMatch
        XCTAssertTrue(period.waitForExistence(timeout: 10))
        let week = period.buttons["今週"]
        let month = period.buttons["今月"]
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        let logElapsed = ProcessInfo.processInfo.systemUptime - logStartedAt
        // Years of history never read as an empty list. (This week is empty
        // in the fixture, so 「この期間の粒は、まだありません。」 is right.)
        XCTAssertFalse(secondColdLaunch.staticTexts["一粒積むと、ここに記録が残ります。"].exists)
        let openAudit = try waitForLogLoadAudit(
            in: secondColdLaunch,
            trigger: "open",
            afterGeneration: 0
        )
        // A toggle reads the period page only.
        let monthAudit = try auditPeriodToggle(
            to: month,
            in: secondColdLaunch,
            afterGeneration: try integerField("generation", in: openAudit)
        )
        let weekAudit = try auditPeriodToggle(
            to: week,
            in: secondColdLaunch,
            afterGeneration: try integerField("generation", in: monthAudit)
        )

        // Background, then back: 記録 reads everything again and still
        // answers.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            secondColdLaunch.wait(for: .runningBackground, timeout: 10)
                || secondColdLaunch.wait(for: .runningBackgroundSuspended, timeout: 10)
        )
        let resumeFinished = logLoadAuditFinished()
        secondColdLaunch.activate()
        XCTAssertTrue(secondColdLaunch.wait(for: .runningForeground, timeout: 10))
        wait(for: [resumeFinished], timeout: 60)
        let resumeAudit = try waitForLogLoadAudit(
            in: secondColdLaunch,
            trigger: "resume",
            afterGeneration: try integerField("generation", in: weekAudit)
        )
        XCTAssertTrue(week.isSelected, "Returning must keep the chosen period")
        let resumedMonthAudit = try auditPeriodToggle(
            to: month,
            in: secondColdLaunch,
            afterGeneration: try integerField("generation", in: resumeAudit)
        )
        week.tap()
        XCTAssertTrue(waitForSelection(week, timeout: 10))

        let audits = [
            ("open", openAudit),
            ("今月", monthAudit),
            ("今週", weekAudit),
            ("resume", resumeAudit),
            ("今月 after resume", resumedMonthAudit)
        ]
        XCTContext.runActivity(named: String(
            format: "40-year Log in app: open %ldms (push and first frame %ldms; longest main-thread stall while reading %ldms; period %ldms, newest %ldms, months %ldms), 今月 %ldms (stall %ldms), 今週 %ldms (stall %ldms), back from the background %ldms (stall %ldms), then 今月 %ldms (stall %ldms)",
            try integerField("milliseconds", in: openAudit),
            try integerField("openingStallMilliseconds", in: openAudit),
            try integerField("longestStallMilliseconds", in: openAudit),
            try integerField("periodMilliseconds", in: openAudit),
            try integerField("recentMilliseconds", in: openAudit),
            try integerField("monthsMilliseconds", in: openAudit),
            try integerField("milliseconds", in: monthAudit),
            try integerField("longestStallMilliseconds", in: monthAudit),
            try integerField("milliseconds", in: weekAudit),
            try integerField("longestStallMilliseconds", in: weekAudit),
            try integerField("milliseconds", in: resumeAudit),
            try integerField("longestStallMilliseconds", in: resumeAudit),
            try integerField("milliseconds", in: resumedMonthAudit),
            try integerField("longestStallMilliseconds", in: resumedMonthAudit)
        )) { _ in }
        XCTContext.runActivity(
            named: "40-year Log milestone read on the main thread: open \(openAudit["milestonesMilliseconds"] ?? "-")ms, back from the background \(resumeAudit["milestonesMilliseconds"] ?? "-")ms"
        ) { _ in }
        // The screen keeps scrolling, animating and answering taps while
        // forty years are read: the main thread never stops for a noticeable
        // moment, whether 記録 opens, switches period or comes back. The
        // push to 記録 and its first frame come before any read and have a
        // budget of their own.
        for (name, audit) in audits {
            XCTAssertLessThan(
                try integerField("longestStallMilliseconds", in: audit),
                Self.logMainThreadStallBudgetMilliseconds,
                "記録 (\(name)) blocked the main thread while reading: \(audit)"
            )
            XCTAssertLessThan(
                try integerField("openingStallMilliseconds", in: audit),
                Self.logOpeningBudgetMilliseconds,
                "記録 (\(name)) took too long to appear: \(audit)"
            )
        }
        // Every read arrives. They are bounded, so their time does not grow
        // with the years behind them beyond one pass over the table.
        XCTAssertLessThan(
            try integerField("periodMilliseconds", in: openAudit),
            Self.logReadBudgetMilliseconds,
            "記録's figures for 今週 must arrive: \(openAudit)"
        )
        XCTAssertLessThan(
            try integerField("milliseconds", in: openAudit),
            Self.logReadBudgetMilliseconds,
            "Every part of 記録 must arrive: \(openAudit)"
        )

        // Years of history never read as an empty list, before or after the
        // return from the background.
        // The newest thirty sit below up to 80 aggregate rows (37 fast
        // swipes on an iPhone 17 Pro simulator): allow about twice that.
        let pastHistory = secondColdLaunch.buttons["log.past-history"]
        for _ in 0 ..< 80 where !isSafelyHittable(pastHistory, in: secondColdLaunch) {
            secondColdLaunch.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(isSafelyHittable(pastHistory, in: secondColdLaunch))
        XCTAssertFalse(secondColdLaunch.staticTexts["一粒積むと、ここに記録が残ります。"].exists)
        XCTAssertTrue(
            secondColdLaunch.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "プラス", "グラム")
            ).firstMatch.exists,
            "The newest records must be listed"
        )
        let logAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        logAttachment.name = "40-year persistent Log"
        logAttachment.lifetime = .keepAlways
        add(logAttachment)

        // 過去の記録 counts the newest year off the main thread, so the sheet
        // opens and closes without waiting for that count.
        let pastStartedAt = ProcessInfo.processInfo.systemUptime
        pastHistory.tap()
        XCTAssertTrue(secondColdLaunch.navigationBars["過去の記録"].waitForExistence(timeout: 10))
        let pastClose = secondColdLaunch.buttons["log.past-history.close"]
        XCTAssertTrue(pastClose.waitForExistence(timeout: 5))
        pastClose.tap()
        XCTAssertTrue(secondColdLaunch.navigationBars["過去の記録"].waitForNonExistence(timeout: 10))
        let pastElapsed = ProcessInfo.processInfo.systemUptime - pastStartedAt

        XCTContext.runActivity(named: String(
            format: "40-year Log (XCUI): open and every read arrived %.3fs, 過去の記録 open and close: %.3fs",
            logElapsed,
            pastElapsed
        )) { _ in }
        XCTAssertLessThan(logElapsed, 10, "記録 must open within ten seconds over forty years")
        XCTAssertLessThan(pastElapsed, 8, "過去の記録 must open and close while its year is still being counted")
        secondColdLaunch.terminate()
    }

    /// The longest the main thread may go without turning its run loop while
    /// 記録 reads forty years. A frame is 16 ms; an idle simulator stays far
    /// below this, and it leaves room for a busy build machine.
    private static let logMainThreadStallBudgetMilliseconds = 500

    /// From the tap until 記録 is on screen and its first read starts: the
    /// push and the first frame, on a busy build machine.
    private static let logOpeningBudgetMilliseconds = 1_500

    /// How long 記録's reads may take off the main thread.
    private static let logReadBudgetMilliseconds = 15_000

    /// Fulfilled when 記録's next load audit has its timings. Create it
    /// before the action: a Darwin notification is not queued.
    private func logLoadAuditFinished() -> XCTDarwinNotificationExpectation {
        XCTDarwinNotificationExpectation(
            notificationName: "com.hinoshiba.pomogem.log-load-audit.finished"
        )
    }

    /// Picks 今週 or 今月 and returns the app's audit of that pick, without
    /// querying the app until its read has arrived.
    private func auditPeriodToggle(
        to segment: XCUIElement,
        in app: XCUIApplication,
        afterGeneration generation: Int
    ) throws -> [String: String] {
        let finished = logLoadAuditFinished()
        segment.tap()
        wait(for: [finished], timeout: 60)
        XCTAssertTrue(waitForSelection(segment, timeout: 10))
        return try waitForLogLoadAudit(
            in: app,
            trigger: "period",
            afterGeneration: generation
        )
    }

    private func waitForSelection(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        element.isSelected || XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "selected == true"),
                object: element
            )],
            timeout: timeout
        ) == .completed
    }

    func testNamedPersistentStoreCanChangeAndRestoreKeepAwake() {
        let app = configuredApp()
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 20))
        app.buttons["メニュー"].tap()

        let settings = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "設定")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(settings, in: app))
        settings.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))

        let keepAwake = app.switches["settings.keep-screen-awake"]
        XCTAssertTrue(keepAwake.waitForExistence(timeout: 5))
        let original = keepAwake.value as? String
        tapSwitchControl(keepAwake)
        let didChange = waitForValue(of: keepAwake, toDifferFrom: original)
        XCTAssertTrue(
            didChange,
            "Setting did not change; alert=\(alertDiagnostic(in: app))"
        )
        tapSwitchControl(keepAwake)
        XCTAssertTrue(waitForValue(of: keepAwake, toEqual: original))
        app.terminate()
    }

    private func configuredApp(action: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["POMOGEM_UI_TEST_PERSISTENT_STORE"] = storeName
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        if let action {
            app.launchEnvironment["POMOGEM_UI_TEST_PERSISTENT_ACTION"] = action
        }
        PomoGemUITestLanguage.configureJapanese(app)
        return app
    }

    private func alertDiagnostic(in app: XCUIApplication) -> String {
        let alert = app.alerts.firstMatch
        return alert.exists ? alert.label : "<none>"
    }

    private func tapSwitchControl(_ element: XCUIElement) {
        // SwiftUI exposes the multiline label and trailing switch as one wide
        // accessibility element. Tap the visible control rather than XCTest's
        // computed point, which can land on the noninteractive label.
        element.coordinate(
            withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
        ).tap()
    }

    private func launchAndAssertFirstInteractiveHome(
        _ app: XCUIApplication
    ) throws -> (firstInteractive: TimeInterval, menuRoundTrip: TimeInterval) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        app.launch()

        let menu = app.buttons["メニュー"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        XCTAssertTrue(menu.isHittable)
        // Stop the cold-launch clock at the first usable Home control, then
        // immediately start a separate action round trip so post-frame work
        // cannot hide inside later functional assertions.
        let responsiveElapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let menuRoundTripStartedAt = ProcessInfo.processInfo.systemUptime
        menu.tap()
        let close = app.buttons["home.menu.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(close, timeout: 5))
        close.tap()
        XCTAssertTrue(
            waitForHittable(menu, timeout: 5),
            "Home menu control must become hittable again after closing the menu"
        )
        let menuRoundTripElapsed = ProcessInfo.processInfo.systemUptime
            - menuRoundTripStartedAt

        XCTAssertTrue(app.buttons["瓶"].waitForExistence(timeout: 5))
        let launcher = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "集中する")
        ).firstMatch
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertTrue(launcher.isHittable)
        return (responsiveElapsed, menuRoundTripElapsed)
    }

    private func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate { candidate, _ in
            guard let candidate = candidate as? XCUIElement else { return false }
            return candidate.exists && candidate.isHittable
        }
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Short drags, judged only once the list has stopped. On an iPhone SE
    /// a fling carried the Home menu past 設定 between two checks, and the
    /// row was never safely on screen.
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 8
    ) -> Bool {
        for _ in 0..<attempts {
            if element.exists { _ = waitUntilFrameSettles(element, timeout: 3) }
            if isSafelyHittable(element, in: app) { return true }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo:
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        }
        return isSafelyHittable(element, in: app)
    }

    private func isSafelyHittable(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let frame = element.frame
        let visibleFrame = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 44)
        return !frame.isEmpty
            && frame.minY.isFinite
            && frame.maxY.isFinite
            && frame.minY >= visibleFrame.minY
            && frame.maxY <= visibleFrame.maxY
    }

    private func waitForValue(
        of element: XCUIElement,
        toDifferFrom value: String?,
        timeout: TimeInterval = 2
    ) -> Bool {
        let predicate = NSPredicate { candidate, _ in
            guard let candidate = candidate as? XCUIElement else { return false }
            return candidate.value as? String != value
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForValue(
        of element: XCUIElement,
        toEqual value: String?,
        timeout: TimeInterval = 2
    ) -> Bool {
        let predicate = NSPredicate { candidate, _ in
            guard let candidate = candidate as? XCUIElement else { return false }
            return candidate.value as? String == value
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForSwitchValue(
        in app: XCUIApplication,
        identifier: String,
        toEqual value: String,
        timeout: TimeInterval = 2
    ) -> Bool {
        let predicate = NSPredicate { candidate, _ in
            guard let candidate = candidate as? XCUIApplication else { return false }
            let switchControl = candidate.switches[identifier]
            return switchControl.exists && switchControl.value as? String == value
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForStableFixtureProbe(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> [String: String] {
        let probe = app.descendants(matching: .any)["fixture.40y.probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(timeout)
        var previous: [String: String]?
        var stableSamples = 0
        var latest: [String: String] = [:]
        var observed = Set<String>()
        repeat {
            latest = try fields(from: probe)
            observed.insert(canonicalDescription(of: latest))
            if isExpected(latest) {
                stableSamples = latest == previous ? stableSamples + 1 : 1
                if stableSamples >= 3 { return latest }
            } else {
                stableSamples = 0
            }
            previous = latest
            usleep(200_000)
        } while Date() < deadline
        throw ProbeError.didNotStabilize(
            latest: canonicalDescription(of: latest),
            observed: observed.sorted()
        )
    }

    /// Waits for 記録's in-app load audit (LogLoadAudit) to finish a load
    /// newer than `generation` that `trigger` started.
    private func waitForLogLoadAudit(
        in app: XCUIApplication,
        trigger: String,
        afterGeneration generation: Int,
        timeout: TimeInterval = 60
    ) throws -> [String: String] {
        let probe = app.descendants(matching: .any)["log.load-audit.probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(timeout)
        var latest: [String: String] = [:]
        repeat {
            latest = try fields(from: probe)
            if latest["state"] == "done",
               latest["trigger"] == trigger,
               let raw = latest["generation"],
               let observed = Int(raw),
               observed > generation {
                return latest
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        XCTFail("記録's load audit did not finish: \(canonicalDescription(of: latest))")
        return latest
    }

    private func waitForSettingsRenderAudit(
        in app: XCUIApplication,
        timeout: TimeInterval = 5
    ) throws -> [String: String] {
        let probe = app.descendants(matching: .any)["settings.render-audit.probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: timeout))
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let sample = try fields(from: probe)
            if sample["milliseconds"] != nil { return sample }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return try fields(from: probe)
    }

    private func waitForSettingsCommitAudit(
        in app: XCUIApplication,
        afterGeneration generation: Int,
        timeout: TimeInterval = 5
    ) throws -> [String: String] {
        let probe = app.descendants(matching: .any)["settings.render-audit.probe"]
        guard probe.waitForExistence(timeout: timeout) else {
            throw ProbeError.settingsCommitDidNotAdvance(
                afterGeneration: generation,
                observed: ["probe-missing"]
            )
        }
        let deadline = Date().addingTimeInterval(timeout)
        var observed = Set<String>()
        repeat {
            let sample = try fields(from: probe)
            observed.insert(canonicalDescription(of: sample))
            if let rawGeneration = sample["commitGeneration"],
               let observedGeneration = Int(rawGeneration),
               observedGeneration > generation,
               let rawMilliseconds = sample["commitMilliseconds"],
               let milliseconds = Int(rawMilliseconds),
               milliseconds >= 0 {
                return sample
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        throw ProbeError.settingsCommitDidNotAdvance(
            afterGeneration: generation,
            observed: observed.sorted()
        )
    }

    private func integerField(
        _ key: String,
        in fields: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Int {
        let rawValue = try XCTUnwrap(
            fields[key],
            "Missing \(key) in Settings render audit: \(fields)",
            file: file,
            line: line
        )
        return try XCTUnwrap(
            Int(rawValue),
            "Invalid \(key) in Settings render audit: \(fields)",
            file: file,
            line: line
        )
    }

    private func fields(from element: XCUIElement) throws -> [String: String] {
        guard let value = element.value as? String else {
            throw ProbeError.missingValue
        }
        return Dictionary(uniqueKeysWithValues: value.split(separator: ";").compactMap {
            let pieces = $0.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { return nil }
            return (pieces[0], pieces[1])
        })
    }

    private func isExpected(_ fields: [String: String]) -> Bool {
        fields["grams"] == "87660000"
            && fields["roots"] == "18"
            && fields["loose"] == "0"
            && fields["bodies"] == "18"
            && fields["queue"] == "0"
    }

    private func canonicalDescription(of fields: [String: String]) -> String {
        fields.keys.sorted().map { "\($0)=\(fields[$0] ?? "<missing>")" }
            .joined(separator: ";")
    }

    private func assertExpected(
        _ fields: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(fields["grams"], "87660000", file: file, line: line)
        XCTAssertEqual(fields["roots"], "18", file: file, line: line)
        XCTAssertEqual(fields["loose"], "0", file: file, line: line)
        XCTAssertEqual(fields["bodies"], "18", file: file, line: line)
        XCTAssertEqual(fields["queue"], "0", file: file, line: line)
    }
}

@MainActor
final class FortyYearPlanningUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    func testNormalLaunchHidesDeveloperOnlyControls() {
        let app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "0"
        PomoGemUITestLanguage.configureJapanese(app)
        // Without the UI-test flag nothing skips first-run onboarding, so on
        // a fresh Simulator this launch stops there; it only reached Home when
        // an earlier test had happened to finish onboarding. Mark onboarding
        // done for this launch only (argument domain, unscoped local key) so
        // the test always checks the Home and menu it is about.
        app.launchArguments += ["-onboarding.completed", "YES"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 10))
        // Ordinary local preview has no seeded themes. Create one through
        // the same Settings path as an empty Home before checking its timer menu.
        let launcher = app.buttons["home.focus-launcher"]
        XCTAssertTrue(scrollUntilHittable(launcher, in: app))
        XCTAssertEqual(launcher.label, "テーマを選んではじめる")
        launcher.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))
        let addTheme = app.buttons["テーマを追加"]
        XCTAssertTrue(scrollUntilHittable(addTheme, in: app))
        addTheme.tap()
        let themeEditor = app.navigationBars["テーマを追加"]
        XCTAssertTrue(themeEditor.waitForExistence(timeout: 5))
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 4))
        nameField.tap()
        nameField.typeText("通常起動のテーマ")
        themeEditor.buttons["保存"].tap()
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: themeEditor
            )], timeout: 5),
            .completed
        )
        app.navigationBars["設定"].buttons.element(boundBy: 0).tap()

        let durationPicker = app.buttons["home.duration-picker"]
        XCTAssertTrue(durationPicker.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilHittable(durationPicker, in: app))
        durationPicker.tap()
        XCTAssertTrue(app.buttons["25分"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["12秒、DEMO"].exists)
        app.buttons["25分"].tap()
        app.buttons["メニュー"].tap()
        XCTAssertTrue(app.navigationBars["メニュー"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["12秒、DEMO"].exists)
        XCTAssertFalse(app.buttons["debug.forty-year.open"].exists)
        XCTAssertFalse(app.staticTexts["40年品質検証"].exists)
        XCTAssertTrue(
            scrollUntilHittable(app.buttons["planning.accumulation.open"], in: app),
            "The user-facing accumulation plan must remain after removing developer controls"
        )
    }

    func testAccumulationPlanIsClearlySimulatedAndResetsWithoutSaving() {
        let app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launch()

        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 15))
        app.buttons["メニュー"].tap()

        let openPlan = app.buttons["planning.accumulation.open"]
        XCTAssertTrue(
            scrollUntilHittable(openPlan, in: app),
            "The release-safe accumulation plan must be reachable from Home"
        )
        openPlan.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["planning.accumulation.view"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["planning.accumulation.disclosure"]
                .waitForExistence(timeout: 5),
            "The sheet must identify the contents as a non-persistent prediction"
        )
        XCTAssertTrue(app.staticTexts["予測・保存なし"].exists)

        let sixtyMinutes = app.buttons["60分"].firstMatch
        XCTAssertTrue(scrollUntilHittable(sixtyMinutes, in: app))
        sixtyMinutes.tap()

        let result = app.descendants(matching: .any)["planning.accumulation.result"]
        XCTAssertTrue(scrollUntilExists(result, in: app))
        XCTAssertTrue(
            waitForValue(
                result,
                containing: "sessions=14610;minutes=876600;grams=8766000"
            ),
            "Changing only the duration must visibly change time and mass, not the planned rhythm; value=\(result.value ?? "<nil>")"
        )
        XCTAssertTrue(app.staticTexts["予測・保存なし"].exists)

        let closePlan = app.buttons["planning.accumulation.close"]
        XCTAssertTrue(closePlan.waitForExistence(timeout: 5))
        XCTAssertTrue(closePlan.isHittable)
        XCTAssertGreaterThanOrEqual(closePlan.frame.width, 67.5)
        XCTAssertGreaterThanOrEqual(closePlan.frame.height, 43.5)
        closePlan.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))
        app.buttons["メニュー"].tap()
        XCTAssertTrue(scrollUntilHittable(openPlan, in: app))
        openPlan.tap()

        let reopenedResult = app.descendants(matching: .any)["planning.accumulation.result"]
        XCTAssertTrue(scrollUntilExists(reopenedResult, in: app))
        XCTAssertTrue(
            waitForValue(
                reopenedResult,
                containing: "sessions=14610;minutes=365250;grams=3652500"
            ),
            "Closing the sheet must discard the 60-minute input; value=\(reopenedResult.value ?? "<nil>")"
        )
    }

    private func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 10
    ) -> Bool {
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func scrollUntilExists(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 12
    ) -> Bool {
        for _ in 0..<attempts {
            if element.exists { return true }
            app.swipeUp()
        }
        return element.exists
    }

    private func waitForValue(
        _ element: XCUIElement,
        containing expected: String,
        timeout: TimeInterval = 8
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if (element.value as? String)?.contains(expected) == true { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return (element.value as? String)?.contains(expected) == true
    }

}

private enum ProbeError: LocalizedError {
    case missingValue
    case didNotStabilize(latest: String, observed: [String])
    case settingsCommitDidNotAdvance(
        afterGeneration: Int,
        observed: [String]
    )

    var errorDescription: String? {
        switch self {
        case .missingValue:
            "40-year fixture probe has no accessibility value"
        case let .didNotStabilize(latest, observed):
            "40-year fixture probe did not reach the exact stable projection; latest=[\(latest)], observed=\(observed)"
        case let .settingsCommitDidNotAdvance(generation, observed):
            "Settings commit audit did not advance beyond generation \(generation); observed=\(observed)"
        }
    }
}
