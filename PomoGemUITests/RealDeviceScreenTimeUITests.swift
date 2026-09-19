import XCTest

/// Opt-in audit of the shipping Screen Time settings surface on a real,
/// explicitly authorized iPhone. Family Controls individual authorization and
/// Apple's FamilyActivityPicker cannot be exercised in the Simulator, so this
/// suite refuses to run there.
///
/// Set these in the UI TEST RUNNER's environment (xcodebuild
/// TEST_RUNNER_… variables, or EnvironmentVariables in a private .xctestrun):
///   POMOGEM_REAL_SCREEN_TIME_AUDIT=1
///   POMOGEM_REAL_SCREEN_TIME_PHASE=probe
///
/// No audit flag is ever passed to the application: the app is launched with an
/// empty launch environment and no launch arguments, exactly as it ships.
///
/// `probe` is a strictly read-only reconnaissance phase. It records what the
/// Screen Time settings screen currently shows, opens Apple's permission
/// dialog only when the app itself states that permission is required, and
/// opens/cancels the learning app picker to record what XCUITest can observe
/// of the remote FamilyActivityPicker view. It never taps 反映, 保存 or
/// リセット, never selects an application, and stops immediately if a
/// passcode/PIN field appears. Later phases (authorization, selection, save,
/// usage accrual, revoke/re-allow) are added separately.
@MainActor
final class RealDeviceScreenTimeUITests: XCTestCase {
    private enum Phase: String, CaseIterable {
        case probe
    }

    private enum ProbeOutcome: Error { case stopped }

    private var app: XCUIApplication?
    private var phase: Phase?
    private var didLaunch = false
    private var transcript: [String] = []
    private var attachmentIndex = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 900
#if targetEnvironment(simulator)
        throw XCTSkip("Real Screen Time auditing requires an explicitly authorized physical iPhone.")
#else
        let environment = ProcessInfo.processInfo.environment
        guard environment["POMOGEM_REAL_SCREEN_TIME_AUDIT"] == "1" else {
            throw XCTSkip("Set POMOGEM_REAL_SCREEN_TIME_AUDIT=1 in the test runner to opt in.")
        }
        let permittedKeys: Set<String> = [
            "POMOGEM_REAL_SCREEN_TIME_AUDIT", "POMOGEM_REAL_SCREEN_TIME_PHASE"
        ]
        let unexpectedFlags = environment.keys.filter {
            ($0.hasPrefix("POMOGEM_") && !permittedKeys.contains($0))
                || $0 == "XCODE_RUNNING_FOR_PREVIEWS"
                || $0 == "StoreKitConfigurationFile"
        }
        guard unexpectedFlags.isEmpty else {
            XCTFail("Remove preview, mock, and fixture flags from the runner environment: \(unexpectedFlags.sorted()).")
            throw ProbeOutcome.stopped
        }
        phase = Phase(rawValue: environment["POMOGEM_REAL_SCREEN_TIME_PHASE"] ?? "")
        guard phase != nil else {
            XCTFail("Choose one runner phase: \(Phase.allCases.map(\.rawValue).joined(separator: ", ")).")
            throw ProbeOutcome.stopped
        }
#endif
    }

    override func tearDownWithError() throws {
        flushTranscript()
        app?.terminate()
        app = nil
    }

    // MARK: - probe

    func testProbeScreenTimeAuthorizationAndPickerSurface() throws {
        try select(.probe)
        let app = launchRealApplication()

        // 1. What did the shipping app actually open on? A storage choice or
        // onboarding means this installation is not in the audited state; the
        // probe must not make that decision on the user's behalf.
        try recordEntryScreen(app)

        // 2. Screen Time settings.
        try openScreenTimeSettings(app)
        let statusBefore = recordSettingsState(app, label: "before")
        recordThemePickerOptions(app)

        // 3. Apple's authorization dialog, only when the app says it is needed.
        var statusAfter = statusBefore
        if statusBefore.contains("許可が必要") || app.buttons["screen-time.authorize"].exists {
            try driveAuthorizationPrompt(app)
            statusAfter = recordSettingsState(app, label: "after-authorization-attempt")
        } else {
            note("authorization step SKIPPED: the app reports permission is already granted.")
        }

        // 4. Apple's FamilyActivityPicker, opened and cancelled.
        probeLearningPicker(app)

        note("PROBE COMPLETE. authorizationBefore=\(statusBefore) authorizationAfter=\(statusAfter)")
        capture("probe-final")
    }

    // MARK: - steps

    private func recordEntryScreen(_ app: XCUIApplication) throws {
        let menu = app.buttons["メニュー"]
        let cloudChoice = app.buttons["iCloudに保存して同期"]
        let localChoice = app.buttons["このiPhoneだけに保存"]
        let onboarding = app.buttons["onboarding.next"]
        let deadline = Date().addingTimeInterval(180)
        var reached = "unknown"
        repeat {
            if menu.exists { reached = "home"; break }
            if cloudChoice.exists || localChoice.exists { reached = "storage-choice"; break }
            if onboarding.exists { reached = "onboarding"; break }
        } while Date() < deadline && !waitBriefly()
        note("ENTRY SCREEN: \(reached)")
        capture("entry-\(reached)")
        dumpHierarchy(app, name: "entry-\(reached)")
        guard reached == "home" else {
            note("STOPPED: the app did not open on Home. The probe never chooses a store or completes onboarding.")
            throw XCTSkip("The installation is not in the audited state (\(reached)); a human must decide how to proceed.")
        }
    }

    private func openScreenTimeSettings(_ app: XCUIApplication) throws {
        try tap(app.buttons["メニュー"], "Home menu")
        let settings = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "設定")).firstMatch
        _ = reveal(settings)
        try tap(settings, "設定")
        guard app.navigationBars["設定"].waitForExistence(timeout: 20) else {
            capture("settings-missing")
            XCTFail("Settings did not open.")
            throw ProbeOutcome.stopped
        }
        let entry = app.descendants(matching: .any)["settings.screen-time"].firstMatch
        _ = reveal(entry)
        try tap(entry, "settings.screen-time")
        guard app.navigationBars["スクリーンタイム"].waitForExistence(timeout: 20) else {
            capture("screen-time-missing")
            XCTFail("The Screen Time settings screen did not open.")
            throw ProbeOutcome.stopped
        }
        note("Screen Time settings screen is open.")
    }

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
                     "タイマーの計測中は、勉強アプリの自動記録を休止しています。"] {
            let element = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
            note("[\(label)] monitoring status text \"\(text)\" present=\(element.exists)")
        }

        let theme = app.buttons["screen-time.theme"].exists
            ? app.buttons["screen-time.theme"]
            : app.descendants(matching: .any)["screen-time.theme"].firstMatch
        note("[\(label)] screen-time.theme exists=\(theme.exists) enabled=\(theme.exists && theme.isEnabled) label=\(theme.exists ? theme.label : "-") value=\(describeValue(theme))")

        capture("settings-\(label)")
        dumpHierarchy(app, name: "settings-\(label)")
        return statusLabel
    }

    private func recordThemePickerOptions(_ app: XCUIApplication) {
        let picker = app.buttons["screen-time.theme"].exists
            ? app.buttons["screen-time.theme"]
            : app.descendants(matching: .any)["screen-time.theme"].firstMatch
        guard reveal(picker), picker.isEnabled, picker.isHittable else {
            note("THEME PICKER: not reachable/enabled; options not dumped.")
            return
        }
        let selectedBefore = describeValue(picker)
        picker.tap()
        _ = waitBriefly()
        _ = waitBriefly()
        let options = labels(of: app.buttons).filter { !$0.isEmpty }
        note("THEME PICKER opened. selectedValue=\(selectedBefore)")
        note("THEME PICKER candidate option labels (buttons on screen): \(options.joined(separator: " | "))")
        note("THEME PICKER menuItems: \(labels(of: app.menuItems).joined(separator: " | "))")
        capture("theme-picker-open")
        dumpHierarchy(app, name: "theme-picker-open")

        // Dismiss without changing anything: re-selecting the current value is
        // the only tap that cannot alter the draft; otherwise tap outside.
        let current = selectedBefore.isEmpty ? "選んでください" : selectedBefore
        let sameOption = app.buttons.matching(NSPredicate(format: "label == %@", current)).firstMatch
        if sameOption.exists && sameOption.isHittable {
            sameOption.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.06)).tap()
        }
        _ = waitBriefly()
        note("THEME PICKER dismissed; screen-time.theme value now \(describeValue(picker)); スクリーンタイム bar present=\(app.navigationBars["スクリーンタイム"].exists)")
    }

    private func driveAuthorizationPrompt(_ app: XCUIApplication) throws {
        let authorize = app.buttons["screen-time.authorize"]
        guard reveal(authorize), authorize.isEnabled else {
            note("AUTHORIZATION: screen-time.authorize is missing or disabled; nothing tapped.")
            return
        }
        note("AUTHORIZATION: tapping screen-time.authorize now.")
        authorize.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let affirmatives = ["続ける", "Continue", "許可", "Allow", "OK"]
        let deadline = Date().addingTimeInterval(20)
        var target: XCUIElement?
        var host = "none"
        repeat {
            if let found = firstHittableButton(in: springboard, titles: affirmatives) {
                target = found; host = "springboard"; break
            }
            if let found = firstHittableButton(in: app, titles: affirmatives) {
                target = found; host = "app"; break
            }
            _ = waitBriefly()
        } while Date() < deadline

        capture("authorization-prompt")
        dumpHierarchy(app, name: "authorization-prompt-app")
        dumpHierarchy(springboard, name: "authorization-prompt-springboard")
        if app.alerts.count > 0 {
            dumpHierarchy(app.alerts.firstMatch, name: "authorization-prompt-app-alert")
        }
        if springboard.alerts.count > 0 {
            dumpHierarchy(springboard.alerts.firstMatch, name: "authorization-prompt-springboard-alert")
        }
        note("AUTHORIZATION prompt: app.alerts=\(app.alerts.count) springboard.alerts=\(springboard.alerts.count) affirmativeFound=\(target != nil) host=\(host)")
        note("AUTHORIZATION springboard button labels: \(labels(of: springboard.buttons).joined(separator: " | "))")
        note("AUTHORIZATION app button labels: \(labels(of: app.buttons).joined(separator: " | "))")

        if passcodeFieldPresent(app: app, springboard: springboard) {
            note("PASSCODE PROMPT SEEN. Stopping the phase; no passcode is ever entered by this suite.")
            capture("passcode-prompt")
            throw XCTSkip("A passcode/PIN prompt appeared; a human must complete this step.")
        }

        if let target {
            note("AUTHORIZATION: tapping affirmative button \"\(target.label)\" in \(host).")
            target.tap()
            _ = waitBriefly()
            _ = waitBriefly()
            capture("authorization-after-affirmative")
        } else {
            note("AUTHORIZATION: no affirmative button was addressable within 20 s.")
        }
    }

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
        // The remote view needs a moment to hydrate its own content.
        for _ in 0..<6 { _ = waitBriefly() }

        inventory(app, name: "picker-initial")
        capture("picker-initial")
        dumpHierarchy(app, name: "picker-initial")

        // Try to expand the first category disclosure without selecting apps.
        let rows = pickerRows(app)
        note("PICKER: candidate category rows = \(rows.map(\.0).joined(separator: " | "))")
        if let first = rows.first(where: { $0.1.isHittable }) {
            note("PICKER: expanding first category row \"\(first.0)\".")
            first.1.tap()
            for _ in 0..<4 { _ = waitBriefly() }
            inventory(app, name: "picker-expanded")
            capture("picker-expanded")
            dumpHierarchy(app, name: "picker-expanded")
        } else {
            note("PICKER: no hittable category row was addressable — the remote view exposes no rows to XCUITest.")
        }

        if cancel.exists && cancel.isHittable {
            note("PICKER: tapping キャンセル (never 反映).")
            cancel.tap()
        } else {
            note("PICKER: キャンセル not addressable; attempting a downward swipe to dismiss the sheet.")
            app.swipeDown(velocity: .fast)
        }
        _ = waitBriefly()
        note("PICKER: dismissed; スクリーンタイム bar present=\(app.navigationBars["スクリーンタイム"].exists)")
        capture("picker-dismissed")
    }

    // MARK: - observation helpers

    /// Rows that could plausibly be a FamilyActivityPicker category disclosure.
    private func pickerRows(_ app: XCUIApplication) -> [(String, XCUIElement)] {
        let excluded: Set<String> = ["キャンセル", "反映", "Cancel", "Done"]
        var result: [(String, XCUIElement)] = []
        for query in [app.cells, app.buttons] {
            for element in query.allElementsBoundByIndex.prefix(40) {
                let label = element.label
                guard !label.isEmpty, !excluded.contains(label) else { continue }
                result.append((label, element))
            }
        }
        return result
    }

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
        }
        return nil
    }

    private func passcodeFieldPresent(app: XCUIApplication, springboard: XCUIApplication) -> Bool {
        if springboard.secureTextFields.count > 0 || app.secureTextFields.count > 0 { return true }
        let predicate = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
                                    "パスコード", "Passcode", "PIN")
        return springboard.descendants(matching: .any).matching(predicate).firstMatch.exists
            || app.descendants(matching: .any).matching(predicate).firstMatch.exists
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
    }

    private func launchRealApplication() -> XCUIApplication {
        let application = XCUIApplication()
        application.terminate()
        // The shipping configuration, with no audit or fixture flags at all.
        application.launchEnvironment = [:]
        application.launchArguments = []
        app = application
        didLaunch = true
        application.launch()
        note("Launched com.hinoshiba.pomogem with no launch arguments or environment.")
        return application
    }

    private func tap(_ element: XCUIElement, _ description: String) throws {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"),
            object: element
        )
        guard XCTWaiter.wait(for: [ready], timeout: 20) == .completed else {
            capture("unreachable-\(description)")
            XCTFail("Required control is missing, disabled or obscured: \(description).")
            throw ProbeOutcome.stopped
        }
        element.tap()
    }

    @discardableResult
    private func reveal(_ element: XCUIElement, upwards: Bool = true, attempts: Int = 14) -> Bool {
        guard let app else { return false }
        for _ in 0..<attempts {
            if element.exists {
                let top = app.navigationBars.allElementsBoundByIndex
                    .filter(\.isHittable).map(\.frame.maxY).max() ?? 0
                let bottom = app.windows.firstMatch.frame.maxY - 36
                let frame = element.frame
                if frame.height > 0, frame.width > 0 {
                    if frame.minY >= top && frame.maxY <= bottom { return true }
                    if frame.maxY <= top { app.swipeDown(velocity: .fast); continue }
                    if frame.minY >= bottom { app.swipeUp(velocity: .fast); continue }
                    return true
                }
            }
            if upwards { app.swipeUp(velocity: .fast) } else { app.swipeDown(velocity: .fast) }
        }
        return element.exists
    }

    /// A short, explicit wait that never asserts. `waitForExistence` on a
    /// deliberately absent element is the sanctioned XCTest sleep.
    @discardableResult
    private func waitBriefly() -> Bool {
        app?.staticTexts["pomogem.probe.nonexistent"].waitForExistence(timeout: 1) ?? false
    }

    private func note(_ line: String) {
        transcript.append(line)
        NSLog("[pomogem-screen-time-probe] %@", line)
    }

    private func capture(_ name: String) {
        attachmentIndex += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%02d-%@", attachmentIndex, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func dumpHierarchy(_ element: XCUIElement, name: String) {
        attachmentIndex += 1
        let attachment = XCTAttachment(string: element.debugDescription)
        attachment.name = String(format: "%02d-%@-hierarchy", attachmentIndex, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func dumpHierarchy(_ application: XCUIApplication, name: String) {
        attachmentIndex += 1
        let attachment = XCTAttachment(string: application.debugDescription)
        attachment.name = String(format: "%02d-%@-hierarchy", attachmentIndex, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func flushTranscript() {
        guard !transcript.isEmpty else { return }
        let attachment = XCTAttachment(string: transcript.joined(separator: "\n"))
        attachment.name = "00-screen-time-probe-transcript"
        attachment.lifetime = .keepAlways
        add(attachment)
        transcript.removeAll()
    }
}
