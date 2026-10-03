import XCTest

@MainActor
final class EnglishLocalizationSmokeUITests: XCTestCase {
    func testHomeMenuAndSettingsAppearInEnglish() {
        let app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_REDUCE_MOTION"] = "1"
        PomoGemUITestLanguage.configureEnglish(app)
        app.launch()
        defer { app.terminate() }

        let menu = app.buttons["home.menu.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        XCTAssertEqual(menu.label, "Menu")
        let themePicker = app.buttons["home.subject-picker"]
        XCTAssertTrue(themePicker.waitForExistence(timeout: 8))
        XCTAssertTrue(themePicker.label.contains("English"), themePicker.label)
        XCTAssertFalse(themePicker.label.contains("英語"), themePicker.label)
        retainScreenshot(of: app, named: "English Home")
        menu.tap()

        XCTAssertTrue(app.navigationBars["Menu"].waitForExistence(timeout: 8))
        let settings = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Settings")
        ).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.navigationBars["設定"].exists)
        retainScreenshot(of: app, named: "English Settings")

        for (identifier, label) in [
            ("settings.category.themes", "Themes"),
            ("settings.category.timer", "Focus Timer"),
            ("settings.screen-time", "App Usage"),
            ("settings.category.sensory", "Sound & Haptics"),
            ("settings.category.jar", "Jar & Sharing"),
            ("settings.category.notifications", "Reminders"),
            ("settings.category.data", "Records & iCloud"),
            ("settings.category.support", "Support & App Info")
        ] {
            let row = app.buttons[identifier]
            XCTAssertTrue(PomoGemSettingsUITestNavigation.reveal(row, in: app))
            XCTAssertTrue(row.label.contains(label), row.label)
        }

        PomoGemSettingsUITestNavigation.open(.timer, in: app, english: true)
        let display = app.buttons["settings.timer-display-mode"]
        XCTAssertTrue(PomoGemSettingsUITestNavigation.reveal(display, in: app))
        XCTAssertTrue(display.label.contains("Timer Display"), display.label)
        retainScreenshot(of: app, named: "English Settings — Focus Timer")
        display.tap()
        XCTAssertTrue(app.navigationBars["Timer Display"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["timer-display.option.ringAndTime"].waitForExistence(timeout: 4))
        app.navigationBars["Timer Display"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Focus Timer"].waitForExistence(timeout: 6))

        PomoGemSettingsUITestNavigation.open(.data, in: app, english: true)
        let reset = app.buttons["settings.activity-reset"]
        XCTAssertTrue(PomoGemSettingsUITestNavigation.reveal(reset, in: app))
        XCTAssertEqual(reset.label, "Reset Current Records")
        retainScreenshot(of: app, named: "English Settings — Records & iCloud")
        PomoGemSettingsUITestNavigation.backToIndex(in: app, english: true)
        app.navigationBars["Settings"].buttons.firstMatch.tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
    }

    private func retainScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
