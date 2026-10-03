import XCTest

/// F5 part 1: the two pickers in 音と触覚 (the timer end sound and the alarm
/// strength). The app answers its own Alarms permission request
/// (`POMOGEM_UI_TEST_ALARMKIT`), so iOS's prompt never appears, and every
/// UI-test process starts from the default strength and sound.
@MainActor
final class AlarmSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 300
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_ALARMKIT"] = "denied"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 12))
    }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0, let app {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Alarm settings accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app?.terminate()
        app = nil
    }

    func testTheSoundAndStrengthPickersChooseAndExplainEachStrength() throws {
        openSettings()

        // The sound: eight choices, the alarm-grade five first.
        let soundRow = element("settings.completion-sound")
        XCTAssertTrue(reveal(soundRow))
        XCTAssertTrue(describe(soundRow).contains("澄んだチャイム"), "The synced chime until one is chosen: \(describe(soundRow))")
        soundRow.tap()
        XCTAssertTrue(app.navigationBars["タイマー終了音"].waitForExistence(timeout: 5))
        let raws = ["bell", "digital", "marimba", "schoolChime", "alarmClock", "standard", "soft", "bright"]
        for raw in raws {
            XCTAssertTrue(element("settings.completion-sound.\(raw)").waitForExistence(timeout: 3), raw)
        }
        XCTAssertEqual(element("settings.completion-sound.standard").value as? String, "選択中")
        XCTAssertLessThan(
            element("settings.completion-sound.alarmClock").frame.minY,
            element("settings.completion-sound.standard").frame.minY
        )
        let bell = element("settings.completion-sound.bell")
        // VoiceOver speaks what each sound is, not only its name.
        XCTAssertTrue(bell.label.contains("澄んだ鐘"), bell.label)
        tapUntilSelected(bell)
        XCTAssertEqual(element("settings.completion-sound.standard").value as? String, "未選択")
        let softHint = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "「アラーム」の音から選んでください")
        ).firstMatch
        if !softHint.exists { app.swipeUp() }
        XCTAssertTrue(softHint.waitForExistence(timeout: 3), "やわらかいベル points people who miss the end to the alarms")
        XCTAssertTrue(softHint.label.contains("「やわらかいベル」は音が小さく"), softHint.label)
        retainScreenshot(named: "Timer end sound list")
        goBack(from: "タイマー終了音")
        XCTAssertTrue(reveal(soundRow))
        XCTAssertTrue(waitForDescription(of: soundRow, containing: "ベル"), describe(soundRow))

        // The strength: 標準 by default.
        let strengthRow = element("settings.alarm-strength")
        XCTAssertTrue(reveal(strengthRow))
        XCTAssertTrue(describe(strengthRow).contains("標準"), describe(strengthRow))
        let footer = element("settings.sensory-footer")
        XCTAssertTrue(reveal(footer))
        XCTAssertTrue(footer.label.contains("画面をつけたまま"), footer.label)
        XCTAssertTrue(footer.label.contains("音はサイレントスイッチに従います"), footer.label)
        XCTAssertFalse(element("settings.alarm-maximum-status").exists)

        choose(strength: "gentle")
        XCTAssertTrue(reveal(footer))
        XCTAssertTrue(waitForLabel(of: footer, containing: "短い終了音"), footer.label)
        XCTAssertFalse(footer.label.contains("画面をつけたまま"), footer.label)

        // 最大 asks for alarms once; the app answers "denied" here, so the
        // row explains it and offers the Settings app.
        choose(strength: "maximum")
        let status = element("settings.alarm-maximum-status")
        XCTAssertTrue(reveal(status))
        XCTAssertTrue(waitForLabel(of: status, containing: "アラームが許可されていない"), status.label)
        XCTAssertTrue(element("settings.alarm-open-settings").exists)
        XCTAssertTrue(reveal(footer))
        XCTAssertTrue(footer.label.contains("サイレントスイッチがオンでも鳴らします"), footer.label)
        let sound = app.switches["settings.sound"]
        XCTAssertTrue(reveal(sound, swipingDown: true))
        XCTAssertTrue(sound.label.contains("オンでも鳴ります"), sound.label)
        retainScreenshot(named: "Sound & Haptics at Maximum, alarms denied")
    }

    // MARK: Helpers

    private func choose(strength raw: String) {
        let row = element("settings.alarm-strength")
        XCTAssertTrue(reveal(row))
        row.tap()
        XCTAssertTrue(app.navigationBars["終了アラームの強さ"].waitForExistence(timeout: 5))
        let option = element("settings.alarm-strength.\(raw)")
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        XCTAssertTrue(option.label.contains("サイレントスイッチ"), "What the strength does is in its label: \(option.label)")
        tapUntilSelected(option)
        goBack(from: "終了アラームの強さ")
    }

    /// Chooses a row once it has come to rest. On a loaded Simulator a tap
    /// can be lost (the recording of a failed run shows the list at rest
    /// with the old row still checked), so, as `tapUntilGone` does, a row
    /// that is still not selected 4 s later is tapped once more.
    private func tapUntilSelected(
        _ row: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(waitUntilFrameSettles(row), "The row must come to rest", file: file, line: line)
        row.tap()
        if !waitForValue(of: row, "選択中"), row.exists, row.isHittable {
            XCTContext.runActivity(named: "The first tap was lost; tapping again") { _ in }
            row.tap()
        }
        XCTAssertTrue(waitForValue(of: row, "選択中"), "The tapped row must be selected", file: file, line: line)
    }

    private func openSettings() {
        let menu = app.buttons["メニュー"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
        let settings = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "設定")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 8))
        PomoGemSettingsUITestNavigation.open(.sensory, in: app)
    }

    private func goBack(from title: String) {
        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 3))
        bar.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["音と触覚"].waitForExistence(timeout: 5))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func describe(_ element: XCUIElement) -> String {
        "\(element.label) \(element.value as? String ?? "")"
    }

    private func waitForValue(of element: XCUIElement, _ value: String, timeout: TimeInterval = 4) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.value as? String == value { return true }
            usleep(100_000)
        } while Date() < deadline
        return element.value as? String == value
    }

    private func waitForLabel(of element: XCUIElement, containing value: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, element.label.contains(value) { return true }
            usleep(100_000)
        } while Date() < deadline
        return element.exists && element.label.contains(value)
    }

    private func waitForDescription(of element: XCUIElement, containing value: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, describe(element).contains(value) { return true }
            usleep(100_000)
        } while Date() < deadline
        return false
    }

    /// Brings `element` fully below the navigation bar, turning back when a
    /// search in one direction runs out.
    private func reveal(_ element: XCUIElement, swipingDown: Bool = false) -> Bool {
        var swipingDown = swipingDown
        var swipesThisWay = 0
        for _ in 0 ..< 60 {
            if element.exists {
                settle(element)
                let top = app.navigationBars.allElementsBoundByIndex
                    .filter(\.isHittable).map(\.frame.maxY).max() ?? 0
                let bottom = app.windows.firstMatch.frame.maxY - 36
                let frame = element.frame
                if frame.height > 0, frame.width > 0 {
                    if frame.minY >= top, frame.maxY <= bottom { return true }
                    if frame.height > bottom - top, element.isHittable { return true }
                    let correction = frame.minY < top
                        ? top - frame.minY + 12 : bottom - frame.maxY - 12
                    let distance = min(220, max(60, abs(correction))) * (correction < 0 ? -1 : 1)
                    let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
                    continue
                }
            }
            if swipesThisWay == 20 {
                swipingDown.toggle()
                swipesThisWay = 0
            }
            swipesThisWay += 1
            if swipingDown {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        return false
    }

    private func settle(_ element: XCUIElement) {
        var frame = element.frame
        for _ in 0 ..< 20 {
            usleep(150_000)
            let next = element.frame
            if next == frame { return }
            frame = next
        }
    }

    private func retainScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
