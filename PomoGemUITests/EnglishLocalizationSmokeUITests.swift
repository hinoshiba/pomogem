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
    }

    private func retainScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
