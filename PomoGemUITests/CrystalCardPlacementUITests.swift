import XCTest

/// Tapping a time crystal opens the total-time overview directly. Closing it
/// returns to an unobstructed Home at standard and accessibility text sizes.
/// The midload fixture's 975 minutes produces three 250-minute crystals and
/// a 225-minute growing gem, independently of its 39 source records.
@MainActor
final class CrystalCardPlacementUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 300
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_GEM_SHOWCASE"] = "midload"
        app.launchArguments += [
            // The old detail tip has already been seen; it must not revive
            // the obsolete per-aggregate inspection card.
            "-jar.aggregate-detail-seen", "YES",
            "-jar.tap-hint-seen", "YES",
            // 39 completions cross the review threshold.
            "-review.requested-version", "1.0"
        ]
        PomoGemUITestLanguage.configureJapanese(app)
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    func testTappedTimeCrystalOpensOverviewAndReturnsToHome() throws {
        try checkCrystalNavigation(accessibility5: false, screenshot: "crystal-card-default")
    }

    func testTappedTimeCrystalOpensOverviewAndReturnsToHomeAtAccessibilitySize() throws {
        try checkCrystalNavigation(accessibility5: true, screenshot: "crystal-card-ax5")
    }

    private func checkCrystalNavigation(accessibility5: Bool, screenshot: String) throws {
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = accessibility5 ? "1" : "0"
        app.launch()
        let probe = app.descendants(matching: .any)["jar.presentation.probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        let jar = app.buttons["瓶"]
        XCTAssertTrue(jar.waitForExistence(timeout: 5))
        let launcher = app.buttons["home.focus-launcher"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))

        let resting = try waitForRestingCrystal(probe)
        XCTAssertEqual(Int(resting["count"] ?? ""), 4,
                       "975 minutes has three crystals and one growing gem: \(resting)")
        let jarBefore = jar.frame
        let launcherBefore = launcher.frame
        saveScreenshot("\(screenshot)-resting")

        let crystalX = try XCTUnwrap(resting["crystalWindowX"].flatMap(Double.init))
        let crystalY = try XCTUnwrap(resting["crystalWindowY"].flatMap(Double.init))
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: crystalX, dy: crystalY))
            .tap()
        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 6),
                      "A time crystal opens the whole time overview")
        XCTAssertFalse(app.buttons["jar.aggregate.inspect"].exists,
                       "There is no per-crystal membership card over Home")
        let close = app.buttons["overview.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 4))
        XCTAssertTrue(close.isHittable)
        saveScreenshot(screenshot)
        close.tap()

        XCTAssertTrue(launcher.waitForExistence(timeout: 6))
        if accessibility5 {
            for _ in 0..<6 where !launcher.isHittable { app.swipeUp() }
        }
        XCTAssertTrue(waitUntil(timeout: 4) { launcher.isHittable && launcher.isEnabled },
                      "Closing the overview leaves the focus action usable")
        XCTAssertFalse(app.buttons["jar.aggregate.inspect"].exists)
        if !accessibility5 {
            XCTAssertEqual(jar.frame.height, jarBefore.height, accuracy: 0.5)
            XCTAssertEqual(launcher.frame.minY, launcherBefore.minY, accuracy: 0.5)
        }
        saveScreenshot("\(screenshot)-returned-home")
    }

    /// The crystal is placed when Home first lays out the jar and may still
    /// settle for a moment; wait until it has held still.
    private func waitForRestingCrystal(_ probe: XCUIElement) throws -> [String: String] {
        let deadline = Date().addingTimeInterval(15)
        var latest = probeFields(probe)
        var stillSince = Date()
        while Date() < deadline {
            pause(0.1)
            let next = probeFields(probe)
            let x = next["crystalWindowX"].flatMap(Double.init) ?? -1
            let y = next["crystalWindowY"].flatMap(Double.init) ?? -1
            let lastX = latest["crystalWindowX"].flatMap(Double.init) ?? -1
            let lastY = latest["crystalWindowY"].flatMap(Double.init) ?? -1
            if x < 0 || abs(x - lastX) > 0.5 || abs(y - lastY) > 0.5 {
                stillSince = Date()
            } else if Date().timeIntervalSince(stillSince) >= 0.8 {
                return next
            }
            latest = next
        }
        XCTFail("No crystal came to rest: \(latest)")
        return latest
    }

    private func probeFields(_ probe: XCUIElement) -> [String: String] {
        guard let rawValue = probe.value as? String else { return [:] }
        return Dictionary(rawValue.split(separator: ";").compactMap { field -> (String, String)? in
            let pieces = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { return nil }
            return (String(pieces[0]), String(pieces[1]))
        }, uniquingKeysWith: { $1 })
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

    private func saveScreenshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["POMOGEM_SHOTS_DIR"] else { return }
        let prefix = ProcessInfo.processInfo.environment["POMOGEM_SHOTS_PREFIX"].map { "\($0)-" } ?? ""
        // One run can cover several Simulators at once: name the phone by size.
        let size = app.windows.firstMatch.frame.size
        let url = URL(fileURLWithPath: directory)
            .appendingPathComponent("\(prefix)\(name)-\(Int(size.width))x\(Int(size.height)).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
