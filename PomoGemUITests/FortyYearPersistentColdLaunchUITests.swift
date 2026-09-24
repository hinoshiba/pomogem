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
        secondColdLaunch.terminate()
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

    private func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 8
    ) -> Bool {
        for _ in 0..<attempts {
            if isSafelyHittable(element, in: app) { return true }
            app.swipeUp()
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
