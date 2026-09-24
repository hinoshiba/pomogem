import XCTest

/// Home's menu and the two ways to add to the jar from it. Run on the
/// smallest supported phone as well (iPhone SE, 375 x 667) — that is where a
/// half-height sheet hides the most.
@MainActor
final class HomeMenuAndManualEntryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
    }

    private func launch(accessibility5: Bool = false) {
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = accessibility5 ? "1" : "0"
        app.launch()
        XCTAssertTrue(
            app.buttons["メニュー"].waitForExistence(timeout: 10)
                || app.buttons["今日はここまで"].exists
        )
        cancelFocusIfPresented()
    }

    // MARK: - Menu

    func testMenuShowsRecordsAndSettingsWithoutScrolling() {
        launch()
        app.buttons["メニュー"].tap()
        XCTAssertTrue(app.navigationBars["メニュー"].waitForExistence(timeout: 5))
        let records = menuRow("記録を見る")
        let settings = menuRow("設定")
        XCTAssertTrue(records.waitForExistence(timeout: 4))
        // No swipe: both destinations must be on screen at the sheet's
        // initial half height.
        XCTAssertTrue(records.isHittable, "記録を見る must be visible when the menu opens")
        XCTAssertTrue(settings.isHittable, "設定 must be visible when the menu opens")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(settings.frame.maxY, window.maxY)
        XCTAssertLessThan(records.frame.minY, settings.frame.minY)

        // The background picker is still there, last: below the fold.
        let aurora = app.buttons["home.atmosphere.aurora"]
        XCTAssertFalse(aurora.exists && aurora.isHittable)
        saveScreenshot("menu-default")
        XCTAssertTrue(scrollUntilHittable(aurora))
        XCTAssertGreaterThan(aurora.frame.minY, settings.frame.maxY)
        saveScreenshot("menu-default-scrolled-to-spaces")

        app.buttons["home.menu.close"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 4))
    }

    func testMenuReachesSettingsFirstAtAccessibilitySize() {
        launch(accessibility5: true)
        app.buttons["メニュー"].tap()
        XCTAssertTrue(app.navigationBars["メニュー"].waitForExistence(timeout: 5))
        let settings = menuRow("設定")
        XCTAssertTrue(scrollUntilHittable(settings, attempts: 4),
                      "設定 must be within a few scrolls at AX5, not thousands of points down")
        saveScreenshot("menu-ax5")
    }

    // MARK: - Manual entry

    func testManualEntryConfirmIsReachableAndThemeIsChosenInTheSheet() {
        launch()
        addTheme(named: "数学")
        let homeTheme = app.buttons["home.subject-picker"]
        XCTAssertTrue(homeTheme.waitForExistence(timeout: 5))
        let homeThemeLabel = homeTheme.label

        openMenuRow("時間を手動で積む")
        let picker = app.buttons["manual.subject-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("英語"), "The sheet starts from Home's theme; label=\(picker.label)")
        saveScreenshot("manual-open")

        picker.tap()
        let math = app.buttons["数学"].firstMatch
        XCTAssertTrue(math.waitForExistence(timeout: 4))
        math.tap()
        XCTAssertTrue(waitForLabel(picker, containing: "数学"))

        let thirtyMinutes = app.buttons["30分、300グラム加算"]
        XCTAssertTrue(thirtyMinutes.waitForExistence(timeout: 4))
        thirtyMinutes.tap()
        let confirm = app.buttons["manual.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 4))
        // No swipe: choosing a duration must put the commit button on screen.
        XCTAssertTrue(waitForHittable(confirm), "確認して積む must be reachable right after choosing a duration")
        let summary = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "テーマ", "数学")
        ).firstMatch
        XCTAssertTrue(summary.exists, "The confirmation names the theme that will be saved")
        XCTAssertEqual(
            app.staticTexts["manual.remaining-count"].label,
            "この端末で本日あと3回",
            "Previewing must not consume the allowance"
        )
        saveScreenshot("manual-confirm")

        let toast = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "数学")
        ).firstMatch
        confirm.tap()
        // The toast lives three seconds: look for it first. (メニュー is no
        // proof the sheet closed; Home's toolbar is there behind it.)
        XCTAssertTrue(toast.waitForExistence(timeout: 5), "The confirmation toast names the chosen theme")
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
        XCTAssertEqual(homeTheme.label, homeThemeLabel, "Choosing a theme in the sheet must not change Home's theme")
    }

    func testManualEntryConfirmIsReachableAtAccessibilitySize() {
        launch(accessibility5: true)
        openMenuRow("時間を手動で積む")
        let thirtyMinutes = app.buttons["30分、300グラム加算"]
        XCTAssertTrue(scrollUntilHittable(thirtyMinutes))
        thirtyMinutes.tap()
        let confirm = app.buttons["manual.confirm"]
        XCTAssertTrue(waitForHittable(confirm), "確認して積む must stay reachable at AX5")
        saveScreenshot("manual-confirm-ax5")
        app.buttons["閉じる"].firstMatch.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
    }

    func testAchievementSaveIsReachableBeforeAndWhileTyping() {
        launch()
        openMenuRow("成果を積む")
        XCTAssertTrue(app.navigationBars["成果を選ぶ"].waitForExistence(timeout: 4))
        let examPass = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "試験合格")).firstMatch
        XCTAssertTrue(examPass.waitForExistence(timeout: 4))
        examPass.tap()
        XCTAssertTrue(app.navigationBars["記念石にする"].waitForExistence(timeout: 4))
        let save = app.buttons["この成果を積む"]
        XCTAssertTrue(waitForHittable(save), "この成果を積む must be visible without scrolling")
        XCTAssertTrue(app.buttons["achievement.create.subject-picker"].exists)
        app.textFields.firstMatch.tap()
        XCTAssertTrue(waitForHittable(save), "この成果を積む must stay above the keyboard")
        saveScreenshot("achievement-details")
        app.buttons["achievement.create.close"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
    }

    func testAchievementNameKeepsTheSpacesTyped() {
        launch()
        openMenuRow("成果を積む")
        XCTAssertTrue(app.navigationBars["成果を選ぶ"].waitForExistence(timeout: 4))
        let examPass = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "試験合格")).firstMatch
        XCTAssertTrue(examPass.waitForExistence(timeout: 4))
        examPass.tap()
        let field = app.textFields["achievement.create.note"]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText("TOEIC ")
        XCTAssertEqual(field.value as? String, "TOEIC ", "A typed space must not disappear")
        field.typeText("800点")
        XCTAssertEqual(field.value as? String, "TOEIC 800点")
        saveScreenshot("achievement-name-with-space")
        // 「TOEIC 800点」 is 10 characters, the space included.
        let counter = app.staticTexts["achievement.note.counter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 2))
        XCTAssertEqual(counter.label, "あと30文字")
        XCTAssertTrue(counter.isHittable, "The counter stays above the keyboard while typing")
        app.buttons["この成果を積む"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))

        openMenuRow("記録を見る")
        XCTAssertTrue(app.navigationBars["記録"].waitForExistence(timeout: 5))
        let row = app.buttons["achievement.history.row"].firstMatch
        XCTAssertTrue(scrollUntilHittable(row))
        XCTAssertTrue(row.label.contains("TOEIC 800点"), "Saved with its space; label=\(row.label)")
    }

    func testPaywallTitleDoesNotBreakInsideTheProductName() {
        // The system text size itself, so the sheet renders at AX5 too.
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        launch()
        openMenuRow("設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 6))
        let customTimer = app.buttons["settings.custom-timer"]
        XCTAssertTrue(scrollUntilHittable(customTimer, attempts: 20))
        customTimer.tap()
        let titles = app.staticTexts.matching(identifier: "ポモジェムPro")
        XCTAssertTrue(titles.firstMatch.waitForExistence(timeout: 6))
        saveScreenshot("paywall-ax5")
        // The hero title is the topmost match; one line means the name
        // shrinks instead of breaking as 「ポモジェ／ムPro」.
        let hero = titles.allElementsBoundByIndex.min { $0.frame.minY < $1.frame.minY }
        let frame = hero?.frame ?? .zero
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertLessThan(frame.height, 110, "title frame=\(frame)")
        XCTAssertLessThanOrEqual(frame.maxX, app.windows.firstMatch.frame.maxX)
    }

    // MARK: - Toast

    func testDropToastNeverCoversOrBlocksTheStartButton() {
        launch()
        // A timer left running would take over every later launch.
        addTeardownBlock { @MainActor [weak self] in self?.cancelFocusIfPresented() }
        let launcher = app.buttons["home.focus-launcher"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 3))
        let launcherFrame = launcher.frame
        let menuFrame = app.buttons["メニュー"].frame
        let toast = app.descendants(matching: .any).matching(identifier: "app.toast").firstMatch
        addThirtyMinutesManually()
        XCTAssertTrue(toast.waitForExistence(timeout: 5))
        let toastFrame = toast.frame
        XCTAssertTrue(toast.label.contains("+300g"), "toast=\(toast.label)")
        XCTAssertFalse(toastFrame.intersects(launcherFrame), "toast=\(toastFrame) launcher=\(launcherFrame)")
        XCTAssertFalse(toastFrame.intersects(menuFrame), "The toast must clear the メニュー button")
        saveScreenshot("toast-after-manual")
        // The upper-middle band of the button is where the old toast sat.
        launcher.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: 6),
                      "A tap on the start button while a toast is visible must start the timer")
        cancelFocusIfPresented()
    }

    func testFirstJarHintWaitsForTheToastAndStaysOffTheGem() {
        checkFirstJarHint(accessibility5: false, screenshot: "jar-hint-after-toast")
    }

    func testFirstJarHintStaysOffTheGemAtAccessibilitySize() {
        checkFirstJarHint(accessibility5: true, screenshot: "jar-hint-ax5")
    }

    private func checkFirstJarHint(accessibility5: Bool, screenshot: String) {
        // Show the one-time hint again for this launch only.
        app.launchArguments += ["-jar.tap-hint-seen", "NO"]
        launch(accessibility5: accessibility5)
        let probe = app.descendants(matching: .any)["jar.presentation.probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        let toast = app.descendants(matching: .any).matching(identifier: "app.toast").firstMatch
        addThirtyMinutesManually()
        XCTAssertTrue(toast.waitForExistence(timeout: 5))

        var fields: [String: String] = [:]
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            fields = probeFields(probe)
            if let hint = fields["jarHint"], hint != "none" { break }
            pause(0.2)
        }
        let hint = rect(fields["jarHint"])
        XCTAssertNotNil(hint, "The first gem shows the jar hint once; probe=\(fields)")
        XCTAssertFalse(toast.exists, "One message at a time: the hint waits for the toast")
        pause(0.6) // let the hint finish fading in
        saveScreenshot(screenshot)

        guard let hint,
              let gemX = fields["targetWindowX"].flatMap(Double.init),
              let gemY = fields["targetWindowY"].flatMap(Double.init),
              gemX >= 0, gemY >= 0 else {
            return XCTFail("No resting gem in the probe: \(fields)")
        }
        // The hint asks people to tap the gem; it must not sit on it. The
        // first gem rests on the jar floor, so the hint belongs above it.
        let gemRadius: CGFloat = 18
        XCTAssertLessThan(hint.maxY, CGFloat(gemY) - gemRadius, "hint=\(hint) gem=(\(gemX), \(gemY))")
    }

    func testOverLongAchievementNameExplainsTheDisabledSave() {
        checkOverLongAchievementName(accessibility5: false, screenshot: "achievement-name-too-long")
    }

    func testOverLongAchievementNameExplainsTheDisabledSaveAtAccessibilitySize() {
        checkOverLongAchievementName(accessibility5: true, screenshot: "achievement-name-too-long-ax5")
    }

    private func checkOverLongAchievementName(accessibility5: Bool, screenshot: String) {
        launch(accessibility5: accessibility5)
        openMenuRow("成果を積む")
        let examPass = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "試験合格")).firstMatch
        XCTAssertTrue(examPass.waitForExistence(timeout: 4))
        XCTAssertTrue(scrollUntilHittable(examPass))
        examPass.tap()
        let field = app.textFields["achievement.create.note"]
        let save = app.buttons["この成果を積む"]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        // At AX5 the pinned save bar covers the lower third of an SE, so
        // drag above it, a short way at a time.
        for _ in 0..<8 where !(field.isHittable && field.frame.maxY <= save.frame.minY) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        }
        XCTAssertTrue(field.isHittable)
        field.tap()
        field.typeText(String(repeating: "A", count: 42))

        // With the keyboard up, the pinned save bar is what stays in view,
        // so the reason for the greyed-out button is there.
        let message = app.descendants(matching: .any)
            .matching(identifier: "achievement.note.limit-message").firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 3))
        XCTAssertTrue(message.label.contains("2文字超過"), "message=\(message.label)")
        XCTAssertTrue(waitForHittable(message), "The reason must be visible above the keyboard")
        XCTAssertFalse(save.isEnabled)
        XCTAssertLessThan(message.frame.maxY, save.frame.minY + 1, "The reason sits above the button")
        // The whole field sits between the navigation bar and the pinned
        // bar, not half under it. At AX5 on a 4.7-inch phone the keyboard,
        // the explanation and the button leave no room for the field at all;
        // there the explanation above is what has to stay in view.
        let navigationBar = app.navigationBars["記念石にする"]
        let windowHeight = app.windows.firstMatch.frame.height
        if !accessibility5 || windowHeight >= 700 {
            XCTAssertTrue(waitUntil(timeout: 3) {
                field.frame.maxY <= message.frame.minY && field.frame.minY >= navigationBar.frame.maxY
            }, "field=\(field.frame) message=\(message.frame) bar=\(navigationBar.frame)")
        }
        saveScreenshot(screenshot)

        field.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(waitUntil(timeout: 3) { !message.exists })
        XCTAssertTrue(save.isEnabled)
        app.buttons["achievement.create.close"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
    }

    func testPickingABackgroundLowersTheMenuSoTheBackgroundShows() {
        launch()
        app.buttons["メニュー"].tap()
        let title = app.navigationBars["メニュー"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let halfHeightTop = title.frame.minY
        let window = app.windows.firstMatch.frame

        // The picker is last, so reaching it raises the menu over Home.
        let candidates = ["dawn", "midnight", "study"].map { app.buttons["home.atmosphere.\($0)"] }
        let midnight = app.buttons["home.atmosphere.midnight"]
        XCTAssertTrue(bringFullyIntoView(midnight))
        XCTAssertLessThan(title.frame.minY, halfHeightTop - 100, "Scrolling to the picker raises the menu")
        guard let card = candidates.first(where: { $0.exists && !$0.isSelected && $0.isHittable }) else {
            return XCTFail("No unselected background card on screen")
        }
        let cardIdentifier = card.identifier
        card.tap()

        XCTAssertTrue(waitUntil(timeout: 4) { title.frame.minY > window.height * 0.3 },
                      "Picking a background lowers the menu to half height; title=\(title.frame)")
        let picked = app.buttons[cardIdentifier]
        XCTAssertTrue(waitUntil(timeout: 3) {
            picked.isSelected && picked.isHittable && picked.frame.maxY <= window.maxY
        }, "The chosen card stays in view; card=\(picked.frame)")
        saveScreenshot("menu-background-picked")

        // Put the default back for later tests and screenshots.
        let aurora = app.buttons["home.atmosphere.aurora"]
        XCTAssertTrue(bringFullyIntoView(aurora))
        aurora.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { aurora.isSelected })
        app.buttons["home.menu.close"].tap()
    }

    // MARK: - Helpers

    private func probeFields(_ probe: XCUIElement) -> [String: String] {
        guard let rawValue = probe.value as? String else { return [:] }
        return Dictionary(rawValue.split(separator: ";").compactMap { field -> (String, String)? in
            let pieces = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { return nil }
            return (String(pieces[0]), String(pieces[1]))
        }, uniquingKeysWith: { $1 })
    }

    private func rect(_ value: String?) -> CGRect? {
        guard let value, value != "none" else { return nil }
        let numbers = value.split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2] - numbers[0], height: numbers[3] - numbers[1])
    }

    private func pause(_ seconds: TimeInterval) {
        let idle = XCTestExpectation(description: "pause")
        idle.isInverted = true
        _ = XCTWaiter.wait(for: [idle], timeout: seconds)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            pause(0.2)
        } while Date() < deadline
        return condition()
    }

    /// A running timer survives relaunch; end it so later tests start on Home.
    private func cancelFocusIfPresented() {
        let stop = app.buttons["今日はここまで"].firstMatch
        guard stop.waitForExistence(timeout: 1) else { return }
        stop.tap()
        let alert = app.alerts["今日はここまで"]
        if alert.waitForExistence(timeout: 3) { alert.buttons["今日はここまで"].tap() }
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 6))
    }

    /// Returns right after 「確認して積む」. The toast that confirms the save
    /// lives three seconds, so callers look for it before anything else.
    private func addThirtyMinutesManually() {
        openMenuRow("時間を手動で積む")
        let thirtyMinutes = app.buttons["30分、300グラム加算"]
        XCTAssertTrue(thirtyMinutes.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilHittable(thirtyMinutes))
        thirtyMinutes.tap()
        let confirm = app.buttons["manual.confirm"]
        XCTAssertTrue(waitForHittable(confirm))
        confirm.tap()
    }

    /// The UI-test store starts with one theme (英語); add a second one.
    private func addTheme(named name: String) {
        openMenuRow("設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 6))
        let addTheme = app.buttons["テーマを追加"]
        XCTAssertTrue(scrollUntilHittable(addTheme))
        addTheme.tap()
        XCTAssertTrue(app.navigationBars["テーマを追加"].waitForExistence(timeout: 5))
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 4))
        nameField.tap()
        nameField.typeText(name)
        app.navigationBars["テーマを追加"].buttons["保存"].tap()
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["テーマを追加"]
        )], timeout: 5) == .completed)
        let back = app.navigationBars["設定"].buttons.element(boundBy: 0)
        XCTAssertTrue(back.exists)
        back.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
    }

    private func menuRow(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func openMenuRow(_ title: String) {
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
        app.buttons["メニュー"].tap()
        let row = menuRow(title)
        XCTAssertTrue(bringFullyIntoView(row), "Missing menu row: \(title)")
        row.tap()
    }

    /// Short drags instead of flings: at large text a fling scrolls straight
    /// past a row, and a row cut by the half-height sheet's edge reports
    /// hittable while its visible sliver sits in the home-indicator area.
    private func bringFullyIntoView(_ element: XCUIElement, attempts: Int = 16) -> Bool {
        let window = app.windows.firstMatch.frame
        let topInset: CGFloat = 100
        for _ in 0..<attempts {
            if element.exists, element.isHittable,
               element.frame.minY >= window.minY + topInset,
               element.frame.maxY <= window.maxY { return true }
            let isAbove = element.exists && element.frame.minY < window.minY + topInset
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: isAbove ? 0.45 : 0.8))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: isAbove ? 0.75 : 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        return element.exists && element.isHittable
    }

    @discardableResult
    private func scrollUntilHittable(_ element: XCUIElement, attempts: Int = 8) -> Bool {
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 4) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element
        )], timeout: timeout) == .completed
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 4) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", text), object: element
        )], timeout: timeout) == .completed
    }

    /// Keeps a screenshot with the result bundle and, when the runner is
    /// given POMOGEM_SHOTS_DIR, also as a PNG for review.
    private func saveScreenshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["POMOGEM_SHOTS_DIR"] else { return }
        let device = app.windows.firstMatch.frame.height < 700 ? "se" : "17pro"
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(device).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
