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

        confirm.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
        let toast = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "数学")
        ).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "The confirmation toast names the chosen theme")
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

    // MARK: - Helpers

    /// A running timer survives relaunch; end it so later tests start on Home.
    private func cancelFocusIfPresented() {
        let stop = app.buttons["今日はここまで"].firstMatch
        guard stop.waitForExistence(timeout: 1) else { return }
        stop.tap()
        let alert = app.alerts["今日はここまで"]
        if alert.waitForExistence(timeout: 3) { alert.buttons["今日はここまで"].tap() }
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 6))
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
        // A row cut by the half-height sheet's bottom edge reports hittable
        // while its sliver sits in the home-indicator area; scroll it fully in.
        for _ in 0..<8 where !(row.exists && row.isHittable
            && row.frame.maxY <= app.windows.firstMatch.frame.maxY) {
            app.swipeUp()
        }
        XCTAssertTrue(row.exists && row.isHittable, "Missing menu row: \(title)")
        row.tap()
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
