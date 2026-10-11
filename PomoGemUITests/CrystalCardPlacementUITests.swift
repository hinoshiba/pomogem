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
        if !accessibility5, app.windows.firstMatch.frame.height < 700 {
            let core = try XCTUnwrap(rect(resting["core"]), "The probe reports the total-time meter: \(resting)")
            let hud = try XCTUnwrap(rect(resting["hud"]), "The probe reports the total readout: \(resting)")
            let bottle = try XCTUnwrap(rect(resting["bottle"]), "The probe reports the bottle: \(resting)")
            let context = "core=\(core); hud=\(hud); bottle=\(bottle)"
            let geometry = XCTAttachment(string: context)
            geometry.name = "Small jar — total-time meter beside the crystal pile"
            geometry.lifetime = .keepAlways
            add(geometry)
            XCTAssertTrue(core.maxX < bottle.midX || core.minX > bottle.midX,
                          "The 9.75 kg pile leaves the total-time meter visible beside the bottle's center: \(context)")
            XCTAssertFalse(core.intersects(hud), "The total-time meter must remain clear of the readout: \(context)")
        }

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
        XCTAssertTrue(waitUntilFrameSettles(launcher))
        XCTAssertTrue(waitUntil(timeout: 4) { launcher.isHittable && launcher.isEnabled },
                      "Closing the overview leaves the focus action usable")
        XCTAssertFalse(app.buttons["jar.aggregate.inspect"].exists)
        if !accessibility5 {
            XCTAssertEqual(jar.frame.height, jarBefore.height, accuracy: 0.5)
            XCTAssertEqual(launcher.frame.minY, launcherBefore.minY, accuracy: 0.5)
        }
        saveScreenshot("\(screenshot)-returned-home")

        let durationPicker = app.buttons["home.duration-picker"]
        let subjectPicker = app.buttons["home.subject-picker"]
        XCTAssertTrue(durationPicker.waitForExistence(timeout: 4))
        XCTAssertTrue(subjectPicker.waitForExistence(timeout: 4))
        if accessibility5 {
            XCTAssertTrue(revealFocusPickers(durationPicker, subjectPicker, above: launcher),
                          "Both focus pickers fit in Home's scroll area above the pinned launcher")
        }
        XCTAssertTrue(waitUntilFrameSettles(durationPicker))
        XCTAssertTrue(waitUntilFrameSettles(subjectPicker))
        XCTAssertTrue(durationPicker.isHittable,
                      "The duration picker stays uncovered after crystal inspection")
        XCTAssertTrue(subjectPicker.isHittable,
                      "The theme picker stays uncovered after crystal inspection")
        tapSettledFrame(durationPicker)
        let fortyFiveMinutes = app.buttons["45分"].firstMatch
        XCTAssertTrue(fortyFiveMinutes.waitForExistence(timeout: 4))
        XCTAssertTrue(waitUntilFrameSettles(fortyFiveMinutes))
        XCTAssertTrue(fortyFiveMinutes.isHittable)
        XCTAssertFalse(app.buttons["jar.aggregate.inspect"].exists)
        saveScreenshot("\(screenshot)-duration-menu")
        tapSettledFrame(fortyFiveMinutes)
        XCTAssertTrue(waitUntil(timeout: 4) {
            durationPicker.label.contains("45分") && launcher.label.contains("45分集中する")
        }, "The duration menu remains functional after returning from a crystal")
    }

    /// Keep the gesture inside the scrollable viewport. A whole-app swipe
    /// starts on the pinned launcher at AX5 and can fail to move the pickers.
    private func revealFocusPickers(
        _ duration: XCUIElement,
        _ subject: XCUIElement,
        above launcher: XCUIElement
    ) -> Bool {
        let scrollView = app.scrollViews.containing(.button, identifier: "home.duration-picker").firstMatch
        guard scrollView.waitForExistence(timeout: 5) else { return false }
        for _ in 0..<8 {
            let window = app.windows.firstMatch.frame
            let viewport = scrollView.frame
            let navigationBottom = app.navigationBars.allElementsBoundByIndex
                .filter { $0.exists && $0.frame.intersects(window) }
                .map { $0.frame.maxY }.max() ?? window.minY
            let top = max(viewport.minY, window.minY, navigationBottom) + 8
            let bottom = min(viewport.maxY, window.maxY, launcher.frame.minY) - 8
            let pickers = duration.frame.union(subject.frame)
            if pickers.minY >= top, pickers.maxY <= bottom { return true }
            let room = bottom - top
            guard room > 60, pickers.height <= room else { return false }
            let moveUp = pickers.maxY > bottom
            let correction = moveUp ? pickers.maxY - bottom : top - pickers.minY
            let distance = min(room * 0.65, max(40, correction + 12))
            let startY = moveUp ? bottom - 12 : top + 12
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.midX, dy: startY))
            let end = origin.withOffset(CGVector(dx: viewport.midX,
                                                 dy: startY + (moveUp ? -distance : distance)))
            start.press(forDuration: 0.05, thenDragTo: end)
            guard waitUntilFrameSettles(duration), waitUntilFrameSettles(subject) else { return false }
        }
        return false
    }

    /// Use the measured control center once stable; the surrounding
    /// assertions still verify actual menu behavior after sheet dismissal.
    private func tapSettledFrame(_ element: XCUIElement) {
        XCTAssertTrue(waitUntilFrameSettles(element))
        let frame = element.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(center))
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: center.x, dy: center.y))
            .tap()
    }

    /// Wait for the crystal and the measured readouts to hold still. The
    /// compact meter chooses its clear side after a 450 ms settle, so its
    /// final frame must be stable too before checking the crowded jar.
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
            let framesChanged = ["core", "hud", "bottle"].contains {
                rect(next[$0]) == nil || next[$0] != latest[$0]
            }
            if x < 0 || abs(x - lastX) > 0.5 || abs(y - lastY) > 0.5 || framesChanged {
                stillSince = Date()
            } else if Date().timeIntervalSince(stillSince) >= 0.8 {
                return next
            }
            latest = next
        }
        XCTFail("The crystal and readout frames did not come to rest: \(latest)")
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

    private func rect(_ value: String?) -> CGRect? {
        guard let value, value != "none" else { return nil }
        let numbers = value.split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        let frame = CGRect(x: numbers[0], y: numbers[1],
                           width: numbers[2] - numbers[0], height: numbers[3] - numbers[1])
        return frame.isEmpty ? nil : frame
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
