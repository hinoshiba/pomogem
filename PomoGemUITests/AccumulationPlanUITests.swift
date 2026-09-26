import XCTest

/// home-02: the 積み上がり計画 results grid is read to VoiceOver from its
/// Japanese metrics only.
@MainActor
final class AccumulationPlanUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
    }

    /// home-02: outside a UI-test process (as in every Release build) the
    /// results grid carries no machine-readable value, so VoiceOver reads the
    /// Japanese metrics only.
    func testVoiceOverHearsNoTestValueOutsideUITests() {
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "0"
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 10))
        openPlan()

        let result = app.descendants(matching: .any)["planning.accumulation.result"]
        XCTAssertTrue(scrollUntilExists(result))
        XCTAssertTrue(result.label.contains("集中時間"), result.label)
        let value = (result.value as? String) ?? ""
        XCTAssertFalse(value.contains("months="), "value=\(value)")
        XCTAssertFalse(value.contains("consistent="), "value=\(value)")
    }

    // MARK: - Helpers

    private func openPlan() {
        app.buttons["メニュー"].tap()
        XCTAssertTrue(app.navigationBars["メニュー"].waitForExistence(timeout: 5))
        let openPlan = app.buttons["planning.accumulation.open"]
        XCTAssertTrue(scrollUntilHittable(openPlan))
        openPlan.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["planning.accumulation.view"]
                .waitForExistence(timeout: 8)
        )
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

    private func scrollUntilExists(_ element: XCUIElement, attempts: Int = 12) -> Bool {
        for _ in 0 ..< attempts {
            if element.exists { return true }
            app.swipeUp()
        }
        return element.exists
    }
}
