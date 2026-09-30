import XCTest

/// 重さの旅 on Home (GemExperienceDesign §5.5, §5.6, §8.1; D5, D6, D7, D11):
/// where the readout sits (above the mouth, or inside the jar on short
/// screens and at accessibility sizes), that it never meets the time core or
/// the start button, the one next-target line, and the 小 celebrations (the
/// completion card's chip, the new-device chip and the chip for what arrived
/// while away).
///
/// Run on the SE, 12 mini, 17 Pro and 17 Pro Max simulators; screenshots go
/// to `POMOGEM_SHOTS_DIR` (pass `TEST_RUNNER_POMOGEM_SHOTS_DIR` to
/// xcodebuild) as well as the result bundle.
@MainActor
final class WeightJourneyHomeUITests: XCTestCase {
    private var app: XCUIApplication!

    private enum TextSize: String {
        case standard, xxxLarge, accessibility5
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 600
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchArguments += [
            // The crystal tip row and the one-time jar hint are for other
            // tests; the jar keeps its resting size here.
            "-jar.aggregate-detail-seen", "YES",
            "-jar.tap-hint-seen", "YES",
            "-review.requested-version", "1.0"
        ]
        PomoGemUITestLanguage.configureJapanese(app)
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    // MARK: - D5: placement at three text sizes

    func testReadoutPlacementAtTheDefaultTextSize() throws {
        try checkPlacement(.standard)
    }

    func testReadoutPlacementAtXXXL() throws {
        try checkPlacement(.xxxLarge)
    }

    func testReadoutPlacementAtAccessibility5() throws {
        try checkPlacement(.accessibility5)
    }

    private func checkPlacement(_ size: TextSize) throws {
        launch(showcase: "home", size: size)
        let fields = try waitForRestingJar()
        let window = app.windows.firstMatch.frame
        let launcher = app.buttons["home.focus-launcher"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        let hud = try XCTUnwrap(rect(fields["hud"]), "The probe reports the readout: \(fields)")
        let core = try XCTUnwrap(rect(fields["core"]), "A 3.75 kg jar has a time core: \(fields)")
        let bottle = try XCTUnwrap(rect(fields["bottle"]), "The probe reports the bottle: \(fields)")
        let start = launcher.frame
        let placement = fields["hudPlacement"] ?? "none"
        let context = "\(device) \(size.rawValue) placement=\(placement) hud=\(hud) core=\(core) bottle=\(bottle) start=\(start) window=\(window) line=\(fields["journey"] ?? "none")"
        saveScreenshot("hud-\(size.rawValue)")
        add(attachment("hud-\(size.rawValue)-geometry", context))

        // Accessibility sizes and the iPhone SE keep the readout inside
        // (§8.1); the tall phones put it above the mouth at the default size,
        // the Pro Max at xxxL too. The rest follows the 320 pt rule.
        if size == .accessibility5 || device == "se" {
            XCTAssertEqual(placement, "inside", context)
        } else if device == "promax" || (device == "17pro" && size == .standard) {
            XCTAssertEqual(placement, "above", context)
        }
        if placement == "above" {
            XCTAssertLessThanOrEqual(hud.maxY, bottle.minY + 0.5, "Above the mouth: \(context)")
            XCTAssertGreaterThanOrEqual(hud.minY, window.minY, context)
        } else {
            XCTAssertGreaterThanOrEqual(hud.minY, bottle.minY, "Inside the jar: \(context)")
        }
        XCTAssertFalse(hud.intersects(core), "The readout meets the time core: \(context)")
        XCTAssertFalse(hud.intersects(start), "The readout meets the start button: \(context)")
        XCTAssertFalse(core.intersects(start), "The time core meets the start button: \(context)")
        XCTAssertGreaterThanOrEqual(core.minY, bottle.minY, "The core is in the bottle: \(context)")
        XCTAssertTrue(launcher.isHittable, context)

        // D6: one next-target line, in the readout, or at accessibility
        // sizes in full-size text under the jar.
        if size == .accessibility5 {
            let card = app.descendants(matching: .any)["home.fusion-progress.large-text"]
            XCTAssertTrue(card.waitForExistence(timeout: 5), context)
            XCTAssertTrue(card.label.contains("つぎの名所　大玉スイカ1玉ほど・10時間"), card.label)
            XCTAssertFalse(card.label.contains("核まであと"), card.label)
        } else {
            XCTAssertTrue(
                (fields["journey"] ?? "").hasPrefix("つぎの名所　大玉スイカ1玉ほど・10時間・+1時間15分 積みました"),
                context
            )
        }
    }

    // MARK: - The showcase jars (§5.3)

    /// Home at 250 g, 3.75 kg, 9.75 kg, 29.25 kg, 251 kg and 2.5 t: what the
    /// line says, and the screenshots for review. The two heavy fixtures
    /// open as a lower bound (their bounded session page cannot cover the
    /// ×1千 and ×1万 roots, 「251.0kg以上」), so their line names the floor
    /// and never guesses the stretch (§5.5); a verified total would read
    /// the second form.
    func testTheLineAtEachShowcaseJar() throws {
        let jars: [(fixture: String, name: String, lines: [String])] = [
            ("first", "home-250g", ["つぎの名所　卵10個ほど・1時間"]),
            ("home", "home-3.75kg", ["つぎの名所　大玉スイカ1玉ほど・10時間・+1時間15分 積みました"]),
            ("midload", "home-9.75kg", ["つぎの名所　コーギー1頭ほど・20時間・あと3時間45分"]),
            ("tiers", "home-29kg", ["つぎの名所　コウテイペンギン1羽ほど・50時間・あと1時間15分"]),
            ("heavy", "home-251kg", ["410時間以上・同期中", "つぎの一里塚　420時間・あと1時間40分"]),
            ("veteran", "home-2.5t", ["4,160時間以上・同期中", "つぎの一里塚　4,170時間・あと50分"]),
        ]
        for jar in jars {
            app.terminate()
            app.launchEnvironment["POMOGEM_UI_TEST_GEM_SHOWCASE"] = jar.fixture
            launch(size: .standard)
            let fields = try waitForRestingJar(timeout: 60)
            let line = fields["journey"] ?? "none"
            saveScreenshot(jar.name)
            add(attachment("\(jar.name)-probe", "\(fields)"))
            XCTAssertTrue(
                jar.lines.contains(line) || jar.lines.contains { line == $0 + "・あと1本" },
                "\(jar.fixture): \(line)"
            )
            XCTAssertFalse(line.contains("核まであと"), line)
        }
        // The orbit's 星 and the 冠 clasp on a verified heavy jar: the
        // standalone gallery (about 2.7 t, never a lower bound).
        app.terminate()
        app.launchEnvironment["POMOGEM_UI_TEST_GEM_SHOWCASE"] = "gallery"
        launch(size: .standard, waitsForMenu: false)
        pause(8)
        saveScreenshot("orbit-gallery")
    }

    // MARK: - §5.6 celebrations

    func testANewDeviceReadsTheJourneyOnceWithoutReplayingIt() throws {
        app.launchEnvironment["POMOGEM_UI_TEST_JOURNEY"] = "fresh"
        launch(showcase: "home", size: .standard)
        let toast = app.descendants(matching: .any).matching(identifier: "app.toast").firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 12), "A device without a watermark says it loaded the journey")
        XCTAssertTrue(
            toast.label.contains("重さの旅を読み込みました。いまは5時間、つぎは名所 大玉スイカ1玉ほど・10時間です"),
            toast.label
        )
        pause(0.6)
        saveScreenshot("chip-new-device")
        XCTAssertTrue(waitUntil(timeout: 9) { !toast.exists }, "Quiet, and once")
        pause(3)
        XCTAssertFalse(toast.exists, "Nothing is replayed: \(toast.label)")
    }

    func testWhatArrivedWhileAwayIsNamedOnceOnHome() throws {
        // The device had celebrated up to 3.75 kg; 9.75 kg arrived meanwhile.
        app.launchEnvironment["POMOGEM_UI_TEST_JOURNEY"] = "3750"
        launch(showcase: "midload", size: .standard)
        let toast = app.descendants(matching: .any).matching(identifier: "app.toast").firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 12))
        XCTAssertTrue(toast.label.contains("10時間。大玉スイカ1玉ほどの重さになりました"), toast.label)
        pause(0.6)
        saveScreenshot("chip-away")
    }

    func testTheCompletionCardNamesTheLandmarkItReached() throws {
        // 5,998 g: the 12-second demo (2 g) reaches 10 hours.
        app.launchEnvironment["POMOGEM_UI_TEST_EDGE_GRAMS"] = "5998"
        launch(showcase: "edge", size: .standard)
        let fields = try waitForRestingJar()
        XCTAssertTrue((fields["journey"] ?? "").hasPrefix("つぎの名所　大玉スイカ1玉ほど・10時間・あと1分"), "\(fields)")
        runDemoFocus()
        let chip = app.descendants(matching: .any)["reward.journey"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "The card names the landmark")
        XCTAssertTrue(chip.label.contains("10時間。大玉スイカ1玉ほどの重さになりました"), chip.label)
        pause(0.8)
        saveScreenshot("chip-card-landmark")
        finishCompletionCard()
        let after = try waitForJourneyLine(prefix: "つぎの名所　コーギー1頭ほど・20時間")
        saveScreenshot("home-after-landmark")
        add(attachment("home-after-landmark-probe", after))
    }

    func testTheCompletionCardNamesTheMarkerAndItsDiamondLightsAfterTheDrop() throws {
        // 29h59m48s: the demo reaches the third 一里塚 (30 hours).
        app.launchEnvironment["POMOGEM_UI_TEST_EDGE_GRAMS"] = "17998"
        launch(showcase: "edge", size: .standard)
        _ = try waitForRestingJar()
        saveScreenshot("home-before-marker")
        runDemoFocus()
        let chip = app.descendants(matching: .any)["reward.journey"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "The card names the marker")
        XCTAssertEqual(chip.label, "◇ 30時間")
        pause(0.8)
        saveScreenshot("chip-card-marker")
        finishCompletionCard()
        let after = try waitForJourneyLine(prefix: "つぎの一里塚　40時間")
        pause(1)
        saveScreenshot("home-after-marker")
        add(attachment("home-after-marker-probe", after))
    }

    func testTheSettingHidesTheLine() throws {
        app.launchArguments += ["-home.shows-next-target.v1", "NO"]
        launch(showcase: "home", size: .standard)
        let fields = try waitForRestingJar()
        XCTAssertEqual(fields["journey"], "none", "「Home に次の目標を表示」 off: \(fields)")
        XCTAssertNotEqual(fields["hud"], "none", "The rest of the readout stays: \(fields)")
    }

    // MARK: - Helpers

    private func launch(showcase: String? = nil, size: TextSize, waitsForMenu: Bool = true) {
        if let showcase {
            app.launchEnvironment["POMOGEM_UI_TEST_GEM_SHOWCASE"] = showcase
        }
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = size == .accessibility5 ? "1" : "0"
        if size == .xxxLarge, !app.launchArguments.contains("UICTContentSizeCategoryXXXL") {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
        }
        app.launch()
        if waitsForMenu {
            XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 20))
        }
    }

    private var probe: XCUIElement {
        app.descendants(matching: .any)["jar.presentation.probe"]
    }

    /// Waits until the readout, the core (when there is one) and the bottle
    /// have held still for a moment.
    private func waitForRestingJar(timeout: TimeInterval = 25) throws -> [String: String] {
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(timeout)
        var latest = probeFields()
        var stillSince = Date()
        while Date() < deadline {
            pause(0.2)
            let next = probeFields()
            let keys = ["hud", "core", "bottle", "journey", "hudPlacement", "maxY"]
            if next["hud"] == "none" || keys.contains(where: { next[$0] != latest[$0] }) {
                stillSince = Date()
            } else if Date().timeIntervalSince(stillSince) >= 1.2 {
                return next
            }
            latest = next
        }
        XCTFail("The jar did not come to rest: \(latest)")
        return latest
    }

    private func waitForJourneyLine(prefix: String) throws -> String {
        var fields: [String: String] = [:]
        let found = waitUntil(timeout: 20) {
            fields = self.probeFields()
            return (fields["journey"] ?? "").hasPrefix(prefix)
        }
        XCTAssertTrue(found, "Expected 「\(prefix)…」: \(fields)")
        return "\(fields)"
    }

    /// The 12-second Debug focus: picks it, starts it and stops its alarm.
    private func runDemoFocus() {
        let launcher = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "12秒集中する")).firstMatch
        let demo = app.buttons["12秒、DEMO"]
        for _ in 0..<3 where !launcher.exists {
            if !demo.exists {
                app.buttons["home.duration-picker"].tap()
                XCTAssertTrue(demo.waitForExistence(timeout: 4))
            }
            _ = waitUntilFrameSettles(demo, timeout: 3)
            demo.tap()
            _ = launcher.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilFrameSettles(launcher))
        launcher.tap()
        stopCompletionAlertIfPresented(in: app)
        XCTAssertTrue(app.buttons["休憩の提案を閉じる"].waitForExistence(timeout: 30), "The demo focus completes and offers its card")
    }

    private func finishCompletionCard() {
        tapUntilGone(app.buttons["休憩の提案を閉じる"])
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "homeSettles=1;"),
            object: probe
        )
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 20), .completed, "\(probeFields())")
    }

    private var device: String {
        switch app.windows.firstMatch.frame.height {
        case ..<700: "se"
        case ..<840: "mini"
        case ..<900: "17pro"
        default: "promax"
        }
    }

    private func probeFields() -> [String: String] {
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

    private func attachment(_ name: String, _ text: String) -> XCTAttachment {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }

    private func saveScreenshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(name)-\(device)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["POMOGEM_SHOTS_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(device).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
