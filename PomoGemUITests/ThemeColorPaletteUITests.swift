import XCTest

/// a11y-04: the theme editor always shows which colour a theme has. A new
/// theme starts on the first swatch no theme uses; a colour saved by 1.0.x
/// outside the palette is shown, selected, as 「現在の色」.
@MainActor
final class ThemeColorPaletteUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
    }

    func testANewThemeStartsOnTheFirstSwatchNoThemeUses() {
        app.launch()
        openSettings()

        // The fixture theme 英語 uses 朱色, the first swatch.
        openAddTheme()
        let vermilion = app.buttons["色候補1、朱色"]
        let lapis = app.buttons["色候補2、瑠璃"]
        XCTAssertTrue(scrollUntilHittable(lapis))
        XCTAssertTrue(lapis.isSelected, "The first unused swatch must be selected")
        XCTAssertFalse(vermilion.isSelected)
        XCTAssertEqual(selectedSwatches().count, 1)
        saveScreenshot("theme-add-suggested")

        let nameField = app.textFields.firstMatch
        XCTAssertTrue(scrollUntilHittable(nameField, upward: true))
        nameField.tap()
        nameField.typeText("二つ目のテーマ")
        app.navigationBars["テーマを追加"].buttons["保存"].tap()
        XCTAssertTrue(waitForAbsence(app.navigationBars["テーマを追加"]))

        // The next theme moves on to the third swatch.
        openAddTheme()
        let teal = app.buttons["色候補3、青緑"]
        XCTAssertTrue(scrollUntilHittable(teal))
        XCTAssertTrue(teal.isSelected)
        XCTAssertEqual(selectedSwatches().count, 1)
        app.navigationBars["テーマを追加"].buttons["キャンセル"].tap()
    }

    func testAnOffPaletteColourIsShownAsTheCurrentColour() {
        // 1.0.x suggested this HSB step for a second theme.
        app.launchEnvironment["POMOGEM_UI_TEST_LEGACY_THEME_COLOR"] = "#CC8D4E"
        app.launch()
        openSettings()

        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "旧色のテーマ")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(row))
        row.tap()
        XCTAssertTrue(app.navigationBars["テーマを編集"].waitForExistence(timeout: 5))

        let current = app.buttons["subject-editor.color.current"]
        XCTAssertTrue(scrollUntilHittable(current))
        XCTAssertEqual(current.label, "現在の色")
        XCTAssertTrue(current.isSelected, "The saved colour must be shown as selected")
        XCTAssertEqual(selectedSwatches().count, 1)
        saveScreenshot("theme-edit-current-colour")

        let vermilion = app.buttons["色候補1、朱色"]
        vermilion.tap()
        XCTAssertTrue(vermilion.isSelected)
        XCTAssertFalse(current.isSelected)
        // The saved colour stays available until the person saves.
        current.tap()
        XCTAssertTrue(current.isSelected)
        XCTAssertEqual(selectedSwatches().count, 1)
        app.navigationBars["テーマを編集"].buttons["キャンセル"].tap()
    }

    func testTheCurrentColourAtAccessibility5() {
        app.launchEnvironment["POMOGEM_UI_TEST_LEGACY_THEME_COLOR"] = "#CC8D4E"
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        app.launch()
        openSettings()

        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "旧色のテーマ")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(row))
        row.tap()
        XCTAssertTrue(app.navigationBars["テーマを編集"].waitForExistence(timeout: 5))

        let current = app.buttons["subject-editor.color.current"]
        XCTAssertTrue(scrollUntilHittable(current))
        XCTAssertTrue(current.isSelected)
        saveScreenshot("theme-edit-current-colour-ax5")
        app.navigationBars["テーマを編集"].buttons["キャンセル"].tap()
    }

    // MARK: - Helpers

    private func selectedSwatches() -> [XCUIElement] {
        let swatches = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@ OR identifier == %@",
            "色候補",
            "subject-editor.color.current"
        ))
        return swatches.allElementsBoundByIndex.filter(\.isSelected)
    }

    private func openSettings() {
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 10))
        app.buttons["メニュー"].tap()
        XCTAssertTrue(app.navigationBars["メニュー"].waitForExistence(timeout: 5))
        let settings = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "設定")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(settings))
        settings.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 6))
    }

    private func openAddTheme() {
        let addTheme = app.buttons["テーマを追加"]
        XCTAssertTrue(scrollUntilHittable(addTheme))
        addTheme.tap()
        XCTAssertTrue(app.navigationBars["テーマを追加"].waitForExistence(timeout: 5))
    }

    @discardableResult
    private func scrollUntilHittable(
        _ element: XCUIElement,
        upward: Bool = false,
        attempts: Int = 10
    ) -> Bool {
        for _ in 0 ..< attempts {
            if element.exists, element.isHittable { return true }
            upward ? app.swipeDown() : app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )], timeout: timeout) == .completed
    }

    private func saveScreenshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["POMOGEM_SHOTS_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
