import XCTest

/// a11y-04: the theme editor always shows which colour a theme has. A new
/// theme starts on the first swatch no theme uses; a colour saved by 1.0.x
/// outside the palette is shown, selected, as 「現在の色」.
@MainActor
final class ThemeColorPaletteUITests: XCTestCase {
    private var app: XCUIApplication!
    private var persistentStoreName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        guard let persistentStoreName else { return }
        let cleaner = XCUIApplication()
        cleaner.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        cleaner.launchEnvironment["POMOGEM_UI_TEST_PERSISTENT_STORE"] = persistentStoreName
        cleaner.launchEnvironment["POMOGEM_UI_TEST_PERSISTENT_ACTION"] = "clean"
        PomoGemUITestLanguage.configureJapanese(cleaner)
        cleaner.launch()
        XCTAssertTrue(cleaner.staticTexts["fixture.40y.cleaned"].waitForExistence(timeout: 15))
        cleaner.terminate()
    }

    func testThemeDefaultDurationsPersistAndAllowAOneRunOverride() {
        executionTimeAllowance = 360
        let storeName = "theme-default-duration-\(UUID().uuidString)"
        persistentStoreName = storeName
        app.launchEnvironment["POMOGEM_UI_TEST_PERSISTENT_STORE"] = storeName
        app.launchEnvironment["POMOGEM_UI_TEST_PERSISTENT_ACTION"] = "normal"
        app.launch()
        assertHomeDuration(minutes: 25)

        openSettings()
        openThemeEditor(named: "英語")
        chooseThemeDefault("45分")
        saveScreenshot("subject-default-duration")
        saveThemeEditor()

        openAddTheme()
        let name = app.textFields["subject-editor.name"]
        XCTAssertTrue(scrollUntilHittable(name, upward: true))
        name.tap()
        name.typeText("数学\n")
        chooseThemeDefault("60分")
        saveThemeEditor()
        PomoGemSettingsUITestNavigation.returnHome(in: app)
        assertHomeDuration(minutes: 45)

        selectHomeTheme(named: "数学")
        assertHomeDuration(minutes: 60)
        app.buttons["home.duration-picker"].tap()
        let ninetyMinutes = app.buttons["90分"].firstMatch
        XCTAssertTrue(ninetyMinutes.waitForExistence(timeout: 4))
        ninetyMinutes.tap()
        assertHomeDuration(minutes: 90)
        // A preference update or an unrelated presentation must not undo
        // the explicitly selected time while this theme remains selected.
        app.buttons["home.menu.open"].tap()
        let closeMenu = app.buttons["home.menu.close"]
        XCTAssertTrue(closeMenu.waitForExistence(timeout: 5))
        closeMenu.tap()
        assertHomeDuration(minutes: 90)

        selectHomeTheme(named: "英語")
        assertHomeDuration(minutes: 45)
        selectHomeTheme(named: "数学")
        assertHomeDuration(minutes: 60)
        app.terminate()
        app.launch()
        assertHomeTheme(named: "数学")
        assertHomeDuration(minutes: 60)

        openSettings()
        openThemeEditor(named: "数学")
        chooseThemeDefault("共通設定を使う")
        saveThemeEditor()
        PomoGemSettingsUITestNavigation.returnHome(in: app)
        // The last manually chosen app preference was 90 minutes. Setting
        // and applying theme defaults must not replace that shared value.
        assertHomeDuration(minutes: 90)
        selectHomeTheme(named: "英語")
        assertHomeDuration(minutes: 45)
        selectHomeTheme(named: "数学")
        assertHomeDuration(minutes: 90)
        app.terminate()
        app.launch()
        assertHomeTheme(named: "数学")
        assertHomeDuration(minutes: 90)
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
        app.navigationBars["取り組みを追加"].buttons["保存"].tap()
        XCTAssertTrue(waitForAbsence(app.navigationBars["取り組みを追加"]))

        // The next theme moves on to the third swatch.
        openAddTheme()
        let teal = app.buttons["色候補3、青緑"]
        XCTAssertTrue(scrollUntilHittable(teal))
        XCTAssertTrue(teal.isSelected)
        XCTAssertEqual(selectedSwatches().count, 1)
        app.navigationBars["取り組みを追加"].buttons["キャンセル"].tap()
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
        XCTAssertTrue(app.navigationBars["取り組みを編集"].waitForExistence(timeout: 5))

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
        app.navigationBars["取り組みを編集"].buttons["キャンセル"].tap()
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
        XCTAssertTrue(app.navigationBars["取り組みを編集"].waitForExistence(timeout: 5))

        let current = app.buttons["subject-editor.color.current"]
        XCTAssertTrue(scrollUntilHittable(current))
        XCTAssertTrue(current.isSelected)
        saveScreenshot("theme-edit-current-colour-ax5")
        app.navigationBars["取り組みを編集"].buttons["キャンセル"].tap()
    }

    // MARK: - Helpers

    private func openThemeEditor(named name: String) {
        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", name)
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(row, upward: true))
        row.tap()
        XCTAssertTrue(app.navigationBars["取り組みを編集"].waitForExistence(timeout: 5))
    }

    private func chooseThemeDefault(_ title: String) {
        let picker = app.buttons["subject-editor.default-focus-duration"]
        XCTAssertTrue(scrollUntilHittable(picker))
        picker.tap()
        let option = app.buttons[title].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 4))
        option.tap()
    }

    private func saveThemeEditor() {
        let save = app.buttons["subject-editor.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 4))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(waitForAbsence(save))
    }

    private func selectHomeTheme(named name: String) {
        let picker = app.buttons["home.subject-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        picker.tap()
        let option = app.buttons[name].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 4))
        option.tap()
        assertHomeTheme(named: name)
    }

    private func assertHomeTheme(named name: String) {
        let picker = app.buttons["home.subject-picker"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", name),
            object: picker
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }

    private func assertHomeDuration(minutes: Int) {
        let picker = app.buttons["home.duration-picker"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", "\(minutes)分"),
            object: picker
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed,
                       "The selected theme must show \(minutes) minutes")
    }

    private func selectedSwatches() -> [XCUIElement] {
        let swatches = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@ OR identifier == %@",
            "色候補",
            "subject-editor.color.current"
        ))
        return swatches.allElementsBoundByIndex.filter(\.isSelected)
    }

    private func openSettings() {
        let menu = app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label == %@", "home.menu.open", "メニュー"
        )).firstMatch
        if !menu.waitForExistence(timeout: 3) {
            // At accessibility sizes the debug toolbar can place Menu in
            // the system overflow menu. Follow the same visible route.
            let overflow = app.buttons["OverflowBarButtonItem"]
            if overflow.waitForExistence(timeout: 5) { overflow.tap() }
        }
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        XCTAssertTrue(app.navigationBars["メニュー"].waitForExistence(timeout: 5))
        let settings = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "設定")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(settings))
        settings.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 6))
        PomoGemSettingsUITestNavigation.open(.themes, in: app)
    }

    private func openAddTheme() {
        let addTheme = app.buttons["取り組みを追加"]
        XCTAssertTrue(scrollUntilHittable(addTheme))
        addTheme.tap()
        XCTAssertTrue(app.navigationBars["取り組みを追加"].waitForExistence(timeout: 5))
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
