import XCTest

/// Ten real DEBUG completions each credit the standard 25-minute record.
/// The jar shows their conserved total, including the unfinished time unit,
/// and opens the total-time view without inventing a source subset.
@MainActor
final class DecimalFusionEndToEndUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 420
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launchArguments += ["-review.requested-version", "1.0"]
    }

    func testTenMeasuredCompletionsConserveTimeAndOpenTheOriginalRecords() throws {
        app.launch()
        let probe = app.descendants(matching: .any)["jar.presentation.probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 12))

        for index in 1...10 {
            selectDemoDuration()
            let start = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "12秒集中する")).firstMatch
            XCTAssertTrue(wait(timeout: 8) { start.exists && start.isEnabled })
            start.tap()
            stopCompletionAlertIfPresented(in: app)
            let dismiss = app.buttons["休憩の提案を閉じる"]
            XCTAssertTrue(dismiss.waitForExistence(timeout: 28), "Completion \(index)")
            XCTAssertFalse(app.staticTexts["fusion.celebration.title"].exists,
                           "The immediate reward must be acknowledged before time fusion")
            dismiss.tap()

            if index < 10 {
                try waitForTotal(index * 250, probe: probe)
                XCTAssertFalse(app.staticTexts["fusion.celebration.title"].exists,
                               "Less than 250 minutes cannot create a time crystal")
            }
        }

        let title = app.staticTexts["fusion.celebration.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 12))
        XCTAssertTrue(title.label.contains("4時間10分"), title.label)
        XCTAssertTrue(app.staticTexts["fusion.celebration.core-birth"].exists)
        XCTAssertFalse(app.buttons["fusion.celebration.month-label-hint"].exists,
                       "A total-time crystal cannot promise the month of arbitrary source records")
        let mechanics = app.buttons["fusion.celebration.mechanics"]
        XCTAssertTrue(mechanics.exists)
        XCTAssertTrue(mechanics.label.contains("合計時間"), mechanics.label)
        XCTAssertTrue(mechanics.label.contains("元のまま"), mechanics.label)
        capture("Ten measured completions — 250 minutes conserved")
        app.buttons["fusion.celebration.close"].tap()
        try waitForTotal(2_500, probe: probe)

        try tapRestingCrystal(probe)
        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.navigationBars["結晶の内訳"].exists,
                       "A time unit is not an arbitrary group of the original sessions")
        try openOriginalRecords()
        capture("Ten measured completions — original records remain reachable")
    }

    func testTimeCrystalTapOpensTimeAndRecordsAtAccessibilitySize() throws {
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_GEM_SHOWCASE"] = "timeLong"
        app.launch()
        let probe = app.descendants(matching: .any)["jar.presentation.probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 12))
        try waitForTotal(5_000, probe: probe)
        try tapRestingCrystal(probe)
        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["jar.aggregate.inspect"].exists)
        try openOriginalRecords()
        capture("AX5 — time crystal opens original records")
    }

    private func selectDemoDuration() {
        let picker = app.buttons["home.duration-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        picker.tap()
        let demo = app.buttons["12秒、DEMO"]
        XCTAssertTrue(demo.waitForExistence(timeout: 4))
        demo.tap()
    }

    private func openOriginalRecords() throws {
        let segments = app.segmentedControls["overview.lens"]
        if segments.waitForExistence(timeout: 2) {
            segments.buttons["結晶"].tap()
        } else {
            let menu = app.buttons["overview.lens"]
            XCTAssertTrue(menu.waitForExistence(timeout: 4))
            menu.tap()
            app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "結晶", "overview.lens")).firstMatch.tap()
        }
        let records = app.buttons["overview.time-crystals.records"]
        for _ in 0..<12 where !(records.exists && records.isHittable) { app.swipeUp() }
        XCTAssertTrue(records.exists && records.isHittable)
        records.tap()
        XCTAssertTrue(app.descendants(matching: .any)["overview.timeline.year-list"].waitForExistence(timeout: 8))
    }

    private func waitForTotal(_ grams: Int, probe: XCUIElement) throws {
        XCTAssertTrue(wait(timeout: 12) {
            let fields = self.probeFields(probe)
            let entries = (fields["records"] ?? "").split(separator: ",")
            let masses = entries.compactMap { $0.split(separator: ":").last.flatMap { Int($0) } }
            return masses.reduce(0, +) == grams && masses.count == (grams < 5_000 ? 1 : 2)
        }, probe.value as? String ?? "")
    }

    private func tapRestingCrystal(_ probe: XCUIElement) throws {
        var last = CGPoint(x: -1, y: -1)
        var resting: CGPoint?
        var stillSince = Date()
        XCTAssertTrue(wait(timeout: 12) {
            let fields = self.probeFields(probe)
            guard let x = fields["crystalWindowX"].flatMap(Double.init),
                  let y = fields["crystalWindowY"].flatMap(Double.init), x >= 0, y >= 0 else { return false }
            let point = CGPoint(x: x, y: y)
            if abs(point.x - last.x) > 0.5 || abs(point.y - last.y) > 0.5 { stillSince = Date() }
            last = point
            guard Date().timeIntervalSince(stillSince) >= 0.6 else { return false }
            resting = point
            return true
        }, "A projected time crystal must settle inside the jar")
        let point = try XCTUnwrap(resting)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
    }

    private func probeFields(_ probe: XCUIElement) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (probe.value as? String ?? "").split(separator: ";").compactMap {
            let fields = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { return nil }
            return (String(fields[0]), String(fields[1]))
        })
    }

    private func wait(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return condition()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
