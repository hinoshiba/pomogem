import XCTest

/// Where a tapped crystal's card goes once its detail has been opened before
/// (home-11; the #50 follow-up). It shows in the row under the jar at every
/// text size, never over the jar: over the jar it covered the readout, the
/// time core or the pile, which since #47 reaches higher (adaptive gem
/// scale), and at AX5 it also spilled onto the start button.
///
/// The jar is the `midload` showcase: 39 completions stored as three ×10
/// crystals and nine loose gems under a 9.75 kg time core.
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
            // A crystal's detail has been opened before, so the tip row under
            // the jar is gone, and the one-time jar tip has been seen too.
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

    func testTappedCrystalCardStaysClearOfTheReadoutCoreAndStartButton() throws {
        try checkCrystalCard(accessibility5: false, screenshot: "crystal-card-default")
    }

    func testTappedCrystalCardStaysClearOfTheReadoutCoreAndStartButtonAtAccessibilitySize() throws {
        try checkCrystalCard(accessibility5: true, screenshot: "crystal-card-ax5")
    }

    private func checkCrystalCard(accessibility5: Bool, screenshot: String) throws {
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = accessibility5 ? "1" : "0"
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 10))
        let probe = app.descendants(matching: .any)["jar.presentation.probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        let jar = app.buttons["瓶"]
        XCTAssertTrue(jar.waitForExistence(timeout: 5))
        let launcher = app.buttons["home.focus-launcher"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))

        let resting = try waitForRestingCrystal(probe)
        XCTAssertGreaterThanOrEqual(
            Int(resting["count"] ?? "") ?? 0, 10,
            "The jar must hold at least ten bodies: \(resting)"
        )
        let jarBefore = jar.frame
        let launcherBefore = launcher.frame
        let picker = app.buttons["home.subject-picker"]
        let pickerBefore = picker.frame
        saveScreenshot("\(screenshot)-resting")

        let crystalX = try XCTUnwrap(resting["crystalWindowX"].flatMap(Double.init))
        let crystalY = try XCTUnwrap(resting["crystalWindowY"].flatMap(Double.init))
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: crystalX, dy: crystalY))
            .tap()
        let card = app.buttons["jar.aggregate.inspect"]
        XCTAssertTrue(card.waitForExistence(timeout: 3), "Tapping a crystal shows its card")
        // The card settles in (and at accessibility sizes Home scrolls it
        // into view) before its frame is read.
        XCTAssertTrue(
            waitUntil(timeout: 3) { card.isHittable },
            "The whole card is brought into view: card=\(card.frame)"
        )
        pause(0.8)
        saveScreenshot(screenshot)

        var fields = probeFields(probe)
        _ = waitUntil(timeout: 3) {
            fields = self.probeFields(probe)
            return fields["hud"] != "none" && fields["core"] != "none" && fields["bottle"] != "none"
        }
        let cardFrame = card.frame
        let jarFrame = jar.frame
        let launcherFrame = launcher.frame
        let window = app.windows.firstMatch.frame
        let hud = try XCTUnwrap(rect(fields["hud"]), "The probe reports the readout: \(fields)")
        let core = try XCTUnwrap(rect(fields["core"]), "A 9.75 kg jar has a time core: \(fields)")
        let bottle = try XCTUnwrap(rect(fields["bottle"]), "The probe reports the bottle: \(fields)")
        let context = "card=\(cardFrame) bottle=\(bottle) jar=\(jarFrame) hud=\(hud) core=\(core) start=\(launcherFrame)"

        XCTAssertFalse(cardFrame.intersects(hud), "The card covers the readout: \(context)")
        XCTAssertFalse(cardFrame.intersects(core), "The card covers the time core: \(context)")
        XCTAssertFalse(cardFrame.intersects(launcherFrame), "The card covers the start button: \(context)")
        // Every gem rests inside the bottle: under its base, the card covers none.
        XCTAssertGreaterThanOrEqual(cardFrame.minY, bottle.maxY, "The card sits under the bottle: \(context)")
        XCTAssertLessThanOrEqual(cardFrame.maxY, launcherFrame.minY + 0.5, "Above the start button: \(context)")
        XCTAssertTrue(launcher.isHittable, "The start button stays uncovered: \(context)")
        XCTAssertGreaterThanOrEqual(cardFrame.minY, window.minY, context)
        XCTAssertLessThanOrEqual(cardFrame.maxY, window.maxY, context)

        if !accessibility5 {
            // The first screen holds still: the jar keeps its size, and the
            // start button stays on screen.
            XCTAssertEqual(jarFrame.height, jarBefore.height, accuracy: 0.5, context)
            XCTAssertLessThanOrEqual(launcherFrame.maxY, window.maxY, "The start button stays on screen: \(context)")
            XCTAssertEqual(launcherFrame.minY, launcherBefore.minY, accuracy: 0.5, context)
            // Where the card reaches the theme and time pickers, they give
            // way to it (never drawn under it, never tapped through it).
            if cardFrame.intersects(pickerBefore) {
                XCTAssertFalse(picker.exists && picker.isHittable, "The pickers give way: \(context) picker=\(pickerBefore)")
            }
        }

        XCTAssertTrue(
            waitUntil(timeout: 9) { !card.exists },
            "The card still closes by itself"
        )
        if accessibility5 {
            // Home comes back to the jar once the card closes.
            XCTAssertTrue(
                waitUntil(timeout: 3) {
                    jar.frame.minY >= window.minY && jar.frame.maxY <= launcher.frame.minY + 0.5
                },
                "The jar is back in view: jar=\(jar.frame) start=\(launcher.frame)"
            )
        } else {
            XCTAssertEqual(jar.frame.minY, jarBefore.minY, accuracy: 0.5, "Nothing moved: jar=\(jar.frame)")
            XCTAssertTrue(
                waitUntil(timeout: 3) { picker.exists && picker.isHittable },
                "The pickers are back once the card closes"
            )
        }
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

    private func rect(_ value: String?) -> CGRect? {
        guard let value, value != "none" else { return nil }
        let numbers = value.split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2] - numbers[0], height: numbers[3] - numbers[1])
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
