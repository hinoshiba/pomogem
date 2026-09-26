import XCTest

/// home-07 / home-02: 積み上がり計画 continues from the person's jar today
/// and offers the timer lengths they can actually run.
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

    func testPlanStartsFromTodaysJarAndOffersTheFreePresets() {
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 10))
        addThirtyMinutesManually()
        pause(3.5) // let the drop toast go
        openPlan()

        // 今日 replaces 現在 at the timeline's start.
        XCTAssertTrue(scrollUntilHittable(app.staticTexts["今日"]))
        XCTAssertFalse(app.staticTexts["現在"].exists)
        scrollUntilHittable(app.buttons["45分"], upward: true)

        // The free presets, and no Pro caveat for a 10-minute option.
        for minutes in ["25分", "45分", "60分", "90分"] {
            XCTAssertTrue(app.buttons[minutes].exists, "Missing duration \(minutes)")
        }
        XCTAssertFalse(app.buttons["10分"].exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Proが必要")
        ).firstMatch.exists)
        saveScreenshot("plan-top")

        let breakdown = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "今日の瓶 300g ＋ この計画 ")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(breakdown), "The plan must start from the 300g jar")
        saveScreenshot("plan-jar-total")

        let result = app.descendants(matching: .any)["planning.accumulation.result"]
        XCTAssertTrue(scrollUntilExists(result))
        XCTAssertTrue(
            waitForValue(result, containing: "grams=3652500;"),
            "The plan's own mass is unchanged; value=\(result.value ?? "<nil>")"
        )
        XCTAssertTrue(
            waitForValue(result, containing: "start=300;jar=3652800"),
            "Today's jar is added on top; value=\(result.value ?? "<nil>")"
        )
        XCTAssertTrue(result.label.contains("瓶の合計"), result.label)
        XCTAssertFalse(result.label.contains("表示する可動体"), result.label)
        saveScreenshot("plan-results")

        // Back to the start of the timeline: today's jar, not an empty one.
        let timeline = app.sliders["planning.accumulation.timeline"]
        XCTAssertTrue(scrollUntilHittable(timeline, upward: true))
        // The slider speaks 「40年後」 rather than a percentage, so XCUITest
        // cannot adjust it by position; drag the thumb past the left end.
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).press(
            forDuration: 0.2,
            thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: -0.2, dy: 0.5))
        )
        XCTAssertTrue(waitForValue(timeline, containing: "今日"), "value=\(timeline.value ?? "<nil>")")
        saveScreenshot("plan-today")
        let todayBreakdown = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "今日の瓶 300g ＋ この計画 0g")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(todayBreakdown), "Month zero is today's 300g jar")
        XCTAssertFalse(
            app.staticTexts["最初の2.50kgへ"].exists,
            "A jar with 300g is past the first step"
        )
        saveScreenshot("plan-today-jar")
        // The results grid is below the fold; the lazy stack only has it
        // once it is scrolled into view.
        XCTAssertTrue(scrollUntilExists(result))
        XCTAssertTrue(waitForValue(result, containing: "months=0;"))
        XCTAssertTrue(waitForValue(result, containing: "start=300;jar=300"))
    }

    func testAnEmptyJarPlansFromZero() {
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 10))
        openPlan()

        let result = app.descendants(matching: .any)["planning.accumulation.result"]
        XCTAssertTrue(scrollUntilExists(result))
        XCTAssertTrue(waitForValue(result, containing: "start=0;jar=3652500"))
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "今日の瓶 ")
        ).firstMatch.exists, "An empty jar needs no breakdown")
    }

    /// At the largest accessibility size the jar total and its breakdown
    /// wrap instead of truncating.
    func testTheJarTotalWrapsAtAccessibility5() {
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 10))
        addThirtyMinutesManually()
        pause(3.5)
        openPlan()

        let breakdown = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "今日の瓶 300g ＋ この計画 ")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(breakdown), "The breakdown must be reachable at AX5")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(breakdown.frame.maxX, window.maxX)
        XCTAssertGreaterThanOrEqual(breakdown.frame.minX, window.minX)
        saveScreenshot("plan-jar-total-ax5")
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

    private func addThirtyMinutesManually() {
        app.buttons["メニュー"].tap()
        XCTAssertTrue(app.navigationBars["メニュー"].waitForExistence(timeout: 5))
        let row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "時間を手動で積む")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(row))
        row.tap()
        let thirtyMinutes = app.buttons["30分、300グラム加算"]
        XCTAssertTrue(thirtyMinutes.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilHittable(thirtyMinutes))
        thirtyMinutes.tap()
        let confirm = app.buttons["manual.confirm"]
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: confirm
        )], timeout: 4) == .completed)
        confirm.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
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

    private func waitForValue(
        _ element: XCUIElement,
        containing expected: String,
        timeout: TimeInterval = 8
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if (element.value as? String)?.contains(expected) == true { return true }
            pause(0.1)
        } while Date() < deadline
        return (element.value as? String)?.contains(expected) == true
    }

    private func pause(_ seconds: TimeInterval) {
        let idle = XCTestExpectation(description: "pause")
        idle.isInverted = true
        _ = XCTWaiter.wait(for: [idle], timeout: seconds)
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
