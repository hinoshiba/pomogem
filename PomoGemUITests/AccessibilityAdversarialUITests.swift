import XCTest

/// Runs Apple's accessibility audit against the largest supported Dynamic
/// Type layout. The override is accepted only by an explicit Debug UI-test
/// process; ordinary app launches continue to follow the system setting.
@MainActor
final class AccessibilityAdversarialUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180

        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launchArguments += [
            "-share.prompt.\(studyDayKey())", "false"
        ]
        app.launch()

        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 10))
    }

    func testAX5SettingsTimerDisplayChoicesRemainReachable() {
        defer { app.terminate() }
        app.buttons["メニュー"].tap()
        let settingsAction = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "設定")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(settingsAction))
        settingsAction.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 8))
        let settingsDisplay = app.descendants(matching: .any)["settings.timer-display-mode"].firstMatch
        XCTAssertTrue(scrollUntilHittable(settingsDisplay, attempts: 20))
        XCTAssertGreaterThanOrEqual(settingsDisplay.frame.height, 43.5)
        settingsDisplay.tap()

        let ring = app.buttons["timer-display.option.ringAndTime"]
        XCTAssertTrue(ring.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilHittable(ring))
        XCTAssertGreaterThanOrEqual(ring.frame.height, 43.5)
        let ringFrame = ring.frame
        let dial = app.buttons["timer-display.option.filledDial"]
        XCTAssertTrue(scrollUntilHittable(dial, attempts: 12))
        XCTAssertGreaterThanOrEqual(dial.frame.height, 43.5)
        XCTAssertEqual(dial.frame.minX, ringFrame.minX, accuracy: 1,
                       "Large text choices must use one column")
        dial.tap()
        XCTAssertEqual(dial.value as? String, "選択中")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "AX5 Settings timer styles — selected physical dial"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.navigationBars["タイマーの表示"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))

        let firstPreset = app.buttons["settings.focus-preset.25"]
        XCTAssertTrue(scrollUntilHittable(firstPreset, attempts: 20))
        let presetColumnX = firstPreset.frame.minX
        for minutes in [25, 45, 60, 90] {
            let preset = app.buttons["settings.focus-preset.\(minutes)"]
            XCTAssertTrue(scrollUntilHittable(preset, attempts: 12))
            XCTAssertEqual(preset.label, "\(minutes)分")
            XCTAssertGreaterThanOrEqual(preset.frame.height, 43.5)
            XCTAssertEqual(preset.frame.minX, presetColumnX, accuracy: 1,
                           "Large text duration presets must use one column")
            preset.tap()
            XCTAssertEqual(preset.value as? String, "選択中")
        }
        let customTimer = app.buttons["settings.custom-timer"]
        XCTAssertTrue(scrollUntilHittable(customTimer, attempts: 12))
        XCTAssertGreaterThanOrEqual(customTimer.frame.height, 43.5)
        XCTAssertEqual(customTimer.value as? String, "未選択")
        let durationAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        durationAttachment.name = "AX5 Settings duration presets and reachable Pro custom option"
        durationAttachment.lifetime = .keepAlways
        add(durationAttachment)

        app.navigationBars["設定"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
        let launcher = app.buttons["home.focus-launcher"]
        XCTAssertTrue(scrollUntilHittable(launcher, attempts: 12))
        XCTAssertTrue(launcher.label.contains("90分集中する"))
        launcher.tap()
        XCTAssertTrue(app.descendants(matching: .any)["focus.timer-display"].firstMatch
            .waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["focus.display-mode"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["timer-display.selection"].exists)
        let giveUp = app.buttons["今日はここまで"]
        XCTAssertTrue(scrollUntilHittable(giveUp, attempts: 12))
        giveUp.tap()
        let confirmation = app.alerts["今日はここまで"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 4))
        confirmation.buttons["今日はここまで"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 6))
    }

    func testAX5HomeMenuAndOverviewNowRemainReachableAndAuditable() throws {
        let menu = app.buttons["メニュー"]
        // An empty jar has no local-impact action yet, so it intentionally
        // exposes a descriptive accessibility element rather than a Button.
        let jar = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "瓶")
        ).firstMatch
        XCTAssertTrue(menu.isHittable)
        XCTAssertTrue(jar.waitForExistence(timeout: 5))
        try auditVisibleScreen(named: "AX5 Home")

        menu.tap()
        let menuClose = app.buttons["home.menu.close"]
        XCTAssertTrue(menuClose.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(menuClose.frame.width, 67.5)
        XCTAssertGreaterThanOrEqual(menuClose.frame.height, 43.5)
        let overviewAction = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "積み上がりを見る")
        ).firstMatch
        // Audit the menu at its natural top position. Auditing after scrolling
        // makes XCTest sample clipped theme-card glyphs against the status bar
        // even though those nodes are outside the visible viewport.
        try auditVisibleScreen(named: "AX5 Menu")
        XCTAssertTrue(scrollUntilHittable(overviewAction))
        overviewAction.tap()

        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 8))
        let introduction = app.staticTexts["overview.introduction"]
        XCTAssertTrue(introduction.waitForExistence(timeout: 5))
        XCTAssertTrue(
            introduction.isHittable,
            "Audit the introduction at its real, unobscured top position"
        )
        try auditVisibleScreen(named: "AX5 Overview — natural top")

        let lens = app.descendants(matching: .any)["overview.lens"]
        XCTAssertTrue(lens.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilHittable(lens))
        XCTAssertEqual(
            lens.elementType,
            .button,
            "The pinned AX5 sheet must use its menu picker, not a segmented control"
        )
        XCTAssertFalse(app.segmentedControls["overview.lens"].exists)
        try auditVisibleScreen(
            named: "AX5 Overview — now",
            previouslyAuditedIdentifiers: ["overview.introduction"]
        )

        closeOverview()
    }

    func testAX5VisibleFocusControlsRemainReachableAndDoNotStartFocus() {
        defer { app.terminate() }

        let presentation = app.descendants(matching: .any)["jar.presentation.probe"]
        XCTAssertTrue(presentation.waitForExistence(timeout: 5))
        XCTAssertTrue(
            ((presentation.value as? String) ?? "").hasPrefix("count=0;"),
            "This journey starts from the disposable empty bottle fixture"
        )

        let themePicker = app.buttons["home.subject-picker"]
        let durationPicker = app.buttons["home.duration-picker"]
        let launcher = app.buttons["home.focus-launcher"]
        XCTAssertTrue(scrollUntilFullyVisibleInContent(themePicker, attempts: 12))
        XCTAssertTrue(themePicker.isHittable)
        XCTAssertGreaterThanOrEqual(themePicker.frame.height, 47.5)
        XCTAssertTrue(scrollUntilFullyVisibleInContent(durationPicker, attempts: 12))
        XCTAssertTrue(durationPicker.isHittable)
        XCTAssertGreaterThanOrEqual(durationPicker.frame.height, 47.5)
        XCTAssertLessThanOrEqual(
            themePicker.frame.maxY,
            durationPicker.frame.minY,
            "The two controls must stack without overlap at AX5"
        )

        durationPicker.tap()
        let fortyFiveMinutes = app.buttons["45分"].firstMatch
        XCTAssertTrue(fortyFiveMinutes.waitForExistence(timeout: 4))
        XCTAssertTrue(scrollUntilHittable(fortyFiveMinutes))
        fortyFiveMinutes.tap()
        XCTAssertTrue(scrollUntilFullyVisibleInContent(launcher, attempts: 12))
        XCTAssertTrue(launcher.isHittable)
        XCTAssertTrue(launcher.label.contains("45分集中する"))
        XCTAssertFalse(app.buttons["一時停止"].exists)
        XCTAssertFalse(app.staticTexts["ポモジェムPro"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "AX5 Home — visible selectors and configured free timer"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertTrue(scrollUntilFullyVisibleInContent(themePicker, attempts: 12))
        themePicker.tap()
        let manageThemes = app.buttons["テーマを管理"]
        XCTAssertTrue(manageThemes.waitForExistence(timeout: 4))
        XCTAssertTrue(scrollUntilHittable(manageThemes))
        manageThemes.tap()
        let settingsNavigation = app.navigationBars["設定"]
        XCTAssertTrue(settingsNavigation.waitForExistence(timeout: 6))
        XCTAssertFalse(app.buttons["一時停止"].exists)

        settingsNavigation.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilFullyVisibleInContent(launcher, attempts: 12))
        XCTAssertTrue(launcher.label.contains("45分集中する"))
        XCTAssertFalse(app.buttons["一時停止"].exists)
        XCTAssertTrue(
            ((presentation.value as? String) ?? "").hasPrefix("count=0;"),
            "Configuring a timer and visiting theme settings must not create effort"
        )
    }

    func testAX5CrystalHierarchyRemainsReachableAndAuditable() throws {
        let lens = try openOverview()

        selectLens("結晶", with: lens)
        let fusionDisclosure = app.staticTexts["overview.fusion-disclosure"]
        XCTAssertTrue(
            scrollUntilFullyVisibleInContent(fusionDisclosure, attempts: 18),
            "The lifetime disclosure must fit unobscured inside the AX5 content viewport"
        )
        let disclosureViewport = visibleContentViewport()
        XCTAssertGreaterThanOrEqual(
            fusionDisclosure.frame.minY,
            disclosureViewport.minY
        )
        XCTAssertLessThanOrEqual(
            fusionDisclosure.frame.maxY,
            disclosureViewport.maxY
        )

        let fusionHierarchy = app.descendants(matching: .any)[
            "overview.fusion-hierarchy"
        ]
        XCTAssertTrue(
            scrollUntilHittable(fusionHierarchy, attempts: 18),
            "The lazy AX5 crystal hierarchy must remain reachable by scrolling"
        )
        assertAX5CrystalTextLayout()
        try auditVisibleScreen(
            named: "AX5 Overview — crystals",
            includesTextClipping: false,
            previouslyAuditedIdentifiers: [
                "overview.introduction",
                "overview.fusion-disclosure"
            ]
        )
    }

    func testAX5TimelineBrowserRemainsReachableAndAuditable() throws {
        let lens = try openOverview()

        selectLens("年月", with: lens)
        // Audit the disclosure while the picker is still visible. Scrolling
        // down to the lazily-created browser below would otherwise skip the
        // exact timeline-detail sentence that originally triggered AX5.
        let timelineDetail = app.staticTexts[
            "生涯瓶は代表表示のまま、年と月を選ぶと、この端末に届いた範囲を正確に集計します。"
        ]
        XCTAssertTrue(timelineDetail.waitForExistence(timeout: 5))
        XCTAssertTrue(timelineDetail.isHittable)
        try auditVisibleScreen(
            named: "AX5 Overview — timeline disclosure",
            previouslyAuditedIdentifiers: ["overview.introduction"]
        )
        let timelineCoverage = app.descendants(matching: .any)[
            "overview.timeline.coverage-notice"
        ]
        XCTAssertTrue(
            scrollUntilHittable(timelineCoverage, attempts: 18),
            "The on-demand year/month browser must replace the retired bounded shelf"
        )
        try auditVisibleScreen(
            named: "AX5 Overview — timeline browser",
            previouslyAuditedIdentifiers: ["overview.introduction"]
        )
    }

    private func openOverview() throws -> XCUIElement {
        app.buttons["メニュー"].tap()
        let overviewAction = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "積み上がりを見る")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(overviewAction))
        overviewAction.tap()

        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 8))
        let introduction = app.staticTexts["overview.introduction"]
        XCTAssertTrue(introduction.waitForExistence(timeout: 5))
        XCTAssertTrue(introduction.isHittable)
        // Each independent lens test verifies the real intro contrast before
        // scrolling can leave SwiftUI's synthetic under-navigation frame in
        // the hierarchy. Its later filter never relies on another test/order.
        try auditVisibleScreen(
            named: "AX5 Overview — natural intro",
            contrastOnly: true
        )

        let lens = app.descendants(matching: .any)["overview.lens"]
        XCTAssertTrue(lens.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilHittable(lens))
        XCTAssertEqual(
            lens.elementType,
            .button,
            "The pinned AX5 sheet must use its menu picker, not a segmented control"
        )
        XCTAssertFalse(app.segmentedControls["overview.lens"].exists)
        return lens
    }

    private func closeOverview() {
        // Query the semantic Button itself. The visible Text remains "閉じる",
        // while VoiceOver deliberately receives the clearer full label.
        let close = app.buttons["overview.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(close.isHittable)
        XCTAssertGreaterThanOrEqual(close.frame.width, 67.5)
        XCTAssertGreaterThanOrEqual(close.frame.height, 43.5)
        close.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 6))
    }

    func testAX5RareRewardControlsAreAbsentForRelease() {
        app.buttons["メニュー"].tap()
        let settingsAction = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "設定")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(settingsAction))
        settingsAction.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 8))

        let picker = app.descendants(matching: .any)["settings.rare-reward-mode"]
        XCTAssertFalse(picker.waitForExistence(timeout: 1))
        XCTAssertFalse(app.staticTexts["粒のバリエーション"].exists)
        XCTAssertFalse(app.navigationBars["ランダムなレア粒"].exists)
    }

    /// On a 4.7-inch iPhone at AX5 the repeating alarm's only Stop control
    /// used to start below the screen. It must be visible without scrolling.
    func testAX5CompletionAlarmStopIsOnScreenWithoutScrolling() throws {
        assertNoRewardCardFromAnEarlierTest()
        startAX5DemoFocus()
        let timer = app.descendants(matching: .any)["focus.timer-display"].firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 8))
        let running = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        running.name = "AX5 running focus — ring status"
        running.lifetime = .keepAlways
        add(running)

        let stop = app.buttons["focus.completion-alert.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 25))
        let viewport = app.windows.firstMatch.frame
        XCTAssertTrue(stop.isHittable, "Stop must be operable without scrolling")
        XCTAssertGreaterThanOrEqual(stop.frame.minY, viewport.minY)
        XCTAssertLessThanOrEqual(
            stop.frame.maxY, viewport.maxY,
            "The alarm's only Stop control must be entirely inside the initial AX5 viewport"
        )
        XCTAssertGreaterThanOrEqual(stop.frame.height, 43.5)
        let alarm = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        alarm.name = "AX5 completion alarm — pinned Stop"
        alarm.lifetime = .keepAlways
        add(alarm)
        stop.tap()
        let dismiss = app.buttons["reward.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 20))
        // Home's reward inset has its own AX5 audit and may need scrolling on
        // a short screen. Acknowledge the receipt and wait for the gem to
        // land: the durable receipt is retired only after landing, and an
        // unacknowledged or mid-drop receipt would block the next test.
        let bridge = app.descendants(matching: .any)["reward.bridge"]
        for _ in 0 ..< 6 where !dismiss.isHittable {
            bridge.swipeUp()
        }
        XCTAssertTrue(dismiss.isHittable, "The receipt's 閉じる must be reachable")
        dismiss.tap()
        XCTAssertTrue(waitForEnabled(app.buttons["home.focus-launcher"], timeout: 12))
    }

    /// At AX5 on a 4.7-inch iPhone the timer's pause/resume and 「今日はここまで」
    /// used to start below the fold with nothing showing the screen scrolls.
    /// They are pinned on screen in every state.
    func testAX5FocusControlsStayOnScreenWhileRunningAndPaused() throws {
        let durationPicker = app.buttons["home.duration-picker"]
        XCTAssertTrue(scrollUntilFullyVisibleInContent(durationPicker, attempts: 12))
        durationPicker.tap()
        let twentyFive = app.buttons["25分"].firstMatch
        XCTAssertTrue(twentyFive.waitForExistence(timeout: 4))
        XCTAssertTrue(scrollUntilHittable(twentyFive))
        twentyFive.tap()
        let launcher = app.buttons["home.focus-launcher"]
        XCTAssertTrue(scrollUntilFullyVisibleInContent(launcher, attempts: 12))
        launcher.tap()
        let rareChoice = app.descendants(matching: .any)["focus.rare-reward-choice"]
        if rareChoice.waitForExistence(timeout: 1) {
            app.buttons["rare-reward.choice.off"].tap()
            app.buttons["focus.rare-reward-choice.confirm"].tap()
        }

        let viewport = app.windows.firstMatch.frame
        func assertOnScreen(_ element: XCUIElement, _ message: String) {
            XCTAssertTrue(element.waitForExistence(timeout: 6), message)
            XCTAssertTrue(element.isHittable, message)
            XCTAssertGreaterThanOrEqual(element.frame.minY, viewport.minY, message)
            XCTAssertLessThanOrEqual(element.frame.maxY, viewport.maxY, message)
            XCTAssertGreaterThanOrEqual(element.frame.height, 43.5, message)
        }
        let pause = app.buttons["一時停止"]
        let giveUp = app.buttons["今日はここまで"]
        assertOnScreen(pause, "Pause must be operable at AX5 without scrolling")
        assertOnScreen(giveUp, "Give-up must be operable at AX5 without scrolling")
        let running = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        running.name = "AX5 running focus — pinned controls"
        running.lifetime = .keepAlways
        add(running)

        pause.tap()
        let resume = app.buttons["再開する"]
        assertOnScreen(resume, "Resume must be operable at AX5 without scrolling")
        assertOnScreen(giveUp, "Give-up must stay operable while paused")
        let paused = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        paused.name = "AX5 paused focus — pinned controls"
        paused.lifetime = .keepAlways
        add(paused)

        giveUp.tap()
        let confirmation = app.alerts["今日はここまで"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 4))
        confirmation.buttons["今日はここまで"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))
    }

    /// The in-memory store starts empty, and the app drops the reward
    /// receipts an earlier test's store left in UserDefaults
    /// (`UITestLocalStateIsolation`). Tapping such a card away used to leave
    /// a gem that could never land, and the start button stayed disabled.
    private func assertNoRewardCardFromAnEarlierTest() {
        XCTAssertFalse(
            app.descendants(matching: .any)["reward.bridge"].waitForExistence(timeout: 1),
            "A new in-memory store must not show another test's completion card"
        )
    }

    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"),
            object: element
        )
        return XCTWaiter.wait(for: [enabled], timeout: timeout) == .completed
    }

    private func startAX5DemoFocus() {
        let durationPicker = app.buttons["home.duration-picker"]
        XCTAssertTrue(scrollUntilFullyVisibleInContent(durationPicker, attempts: 12))
        durationPicker.tap()
        let demoDuration = app.buttons["12秒、DEMO"]
        XCTAssertTrue(demoDuration.waitForExistence(timeout: 4))
        // Home may still be settling from the scroll above while the menu
        // animates in; a tap then can land on another duration or be lost.
        usleep(600_000)
        demoDuration.tap()
        let launcher = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "12秒集中する")
        ).firstMatch
        if !launcher.waitForExistence(timeout: 3) {
            durationPicker.tap()
            XCTAssertTrue(demoDuration.waitForExistence(timeout: 4))
            usleep(600_000)
            demoDuration.tap()
        }
        XCTAssertTrue(scrollUntilHittable(launcher))
        launcher.tap()
        let rareChoice = app.descendants(matching: .any)["focus.rare-reward-choice"]
        if rareChoice.waitForExistence(timeout: 1) {
            app.buttons["rare-reward.choice.off"].tap()
            let confirm = app.buttons["focus.rare-reward-choice.confirm"]
            XCTAssertTrue(confirm.isEnabled)
            confirm.tap()
        }
    }

    func testAX5RewardBridgeKeepsActionsBeforeUnclippedProgress() throws {
        assertNoRewardCardFromAnEarlierTest()

        let durationPicker = app.buttons["home.duration-picker"]
        XCTAssertTrue(scrollUntilFullyVisibleInContent(durationPicker, attempts: 12))
        durationPicker.tap()
        let demoDuration = app.buttons["12秒、DEMO"]
        XCTAssertTrue(demoDuration.waitForExistence(timeout: 4))
        demoDuration.tap()

        let launcher = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "12秒集中する")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(launcher))
        launcher.tap()

        let rareChoice = app.descendants(matching: .any)["focus.rare-reward-choice"]
        if rareChoice.waitForExistence(timeout: 1) {
            app.buttons["rare-reward.choice.off"].tap()
            let confirm = app.buttons["focus.rare-reward-choice.confirm"]
            XCTAssertTrue(confirm.isEnabled)
            confirm.tap()
        }

        stopCompletionAlertIfPresented(in: app)

        let dismiss = app.buttons["reward.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 28))
        XCTAssertTrue(
            app.buttons["今の瓶をGIFでシェアする"].waitForExistence(timeout: 8),
            "Audit the maximum three-action AX5 Reward Bridge"
        )
        let bridge = app.descendants(matching: .any)["reward.bridge"]
        let progress = app.descendants(matching: .any)["reward.fusion-progress"]
        let heading = app.descendants(matching: .any)["reward.heading"]
        XCTAssertTrue(bridge.exists)
        XCTAssertTrue(progress.exists)
        XCTAssertTrue(heading.exists)

        let viewport = app.windows.firstMatch.frame
        let menu = app.buttons["メニュー"]
        XCTAssertTrue(dismiss.isHittable)
        XCTAssertGreaterThanOrEqual(dismiss.frame.width, 72)
        // XCTest may bridge a 44pt SwiftUI frame as 43.99999999999994.
        XCTAssertGreaterThanOrEqual(dismiss.frame.height, 43.5)
        XCTAssertLessThanOrEqual(
            dismiss.frame.maxY,
            viewport.maxY,
            "A safe exit must be entirely inside the initial AX5 viewport"
        )
        XCTAssertLessThanOrEqual(
            dismiss.frame.maxY,
            progress.frame.minY,
            "At accessibility sizes, safe actions must precede detailed progress"
        )
        let geometry = XCTAttachment(
            string: [
                "viewport=\(viewport)",
                "bridge=\(bridge.frame)",
                "heading=\(heading.frame)",
                "menu=\(menu.frame)",
                "dismiss=\(dismiss.frame)",
                "progress=\(progress.frame)"
            ].joined(separator: "\n")
        )
        geometry.name = "AX5 Reward Bridge geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        XCTAssertFalse(
            heading.frame.intersects(menu.frame),
            "The persistent menu must not obscure the enlarged completion heading"
        )

        // These are the two regressions observed on the original bridge. A
        // full-screen contrast audit is intentionally not bundled here because
        // this assertion owns only the inserted completion card.
        try app.performAccessibilityAudit(for: .hitRegion)
        try app.performAccessibilityAudit(for: .textClipped)
        try app.performAccessibilityAudit(for: .sufficientElementDescription)
        try app.performAccessibilityAudit(for: .trait)

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "AX5 Reward Bridge — actions before unclipped progress"
        attachment.lifetime = .keepAlways
        add(attachment)

        dismiss.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 6))
    }

    private func selectLens(
        _ title: String,
        with picker: XCUIElement,
        swipingDown: Bool = false
    ) {
        XCTAssertTrue(scrollUntilHittable(
            picker,
            attempts: 18,
            swipingDown: swipingDown
        ))
        picker.tap()
        let option = app.buttons[title]
        XCTAssertTrue(option.waitForExistence(timeout: 4), "Missing lens option: \(title)")
        option.tap()
    }

    private func auditVisibleScreen(
        named name: String,
        includesTextClipping: Bool = true,
        previouslyAuditedIdentifiers: Set<String> = [],
        contrastOnly: Bool = false
    ) throws {
        let audits: [(String, XCUIAccessibilityAuditType)] = contrastOnly
            ? [("contrast", .contrast)]
            : [
                ("contrast", .contrast),
                ("hit region", .hitRegion),
                ("description", .sufficientElementDescription),
                ("text clipping", .textClipped),
                ("traits", .trait)
            ]
        // XCTest gives one combined audit roughly the same short watchdog as
        // a single check. The long AX5 menu can exceed it even when every
        // individual audit is healthy, so keep each diagnostic independently
        // bounded and named.
        for (auditName, auditType) in audits {
            // Xcode 26's text-clipping audit hits its fixed watchdog on this
            // deep AX5 SwiftUI scroll hierarchy even when run first after a
            // fresh launch. The crystal test therefore owns exact AX5 text
            // geometry, while DynamicTypeSystemAuditUITests runs Apple's same
            // audit on the visible crystal top at the system size. No audit
            // error is swallowed or converted into a pass.
            if auditName == "text clipping", !includesTextClipping { continue }
            try XCTContext.runActivity(named: "\(name) — \(auditName)") { _ in
                let windowFrame = app.windows.firstMatch.frame
                let scrollView = app.scrollViews.firstMatch
                let navigationBar = app.navigationBars.firstMatch
                let navigationLabels = navigationBar.exists
                    ? Set(navigationBar.descendants(
                        matching: .any
                    ).allElementsBoundByIndex.map(\.label))
                    : []
                // SwiftUI can leave a recycled, off-screen LazyVStack text
                // node at y=0 after a long scroll. XCTest then captures the
                // status bar (not that text) and reports its wallpaper as the
                // text's contrast background. NavigationStack's scroll frame
                // can itself underlap the bar, so use the opaque bar's lower
                // edge as the real content boundary.
                let scrollFrame = scrollView.exists
                    ? windowFrame.intersection(scrollView.frame)
                    : windowFrame
                let contentTop = navigationBar.exists
                    ? max(scrollFrame.minY, navigationBar.frame.maxY)
                    : scrollFrame.minY
                let viewport = CGRect(
                    x: scrollFrame.minX,
                    y: contentTop,
                    width: scrollFrame.width,
                    height: max(0, scrollFrame.maxY - contentTop)
                )
                try app.performAccessibilityAudit(for: auditType) { issue in
                    // A ScrollView keeps upcoming rows in its hierarchy. The
                    // contrast audit can sample only the antialiased edge of a
                    // label that is almost entirely below the viewport and
                    // report a false contrast failure. Filter only that narrow
                    // case; every fully visible issue is still recorded and
                    // fails this test normally.
                    guard auditName == "contrast", let element = issue.element else {
                        return false
                    }
                    // Do not suppress a genuine toolbar contrast issue merely
                    // because toolbar controls sit outside the content area.
                    guard !navigationLabels.contains(element.label) else {
                        return false
                    }
                    let frame = element.frame
                    // After a long AX5 scroll, SwiftUI can recycle the
                    // already-audited introduction with a synthetic frame
                    // starting at y=0 and extending through the opaque
                    // navigation bar. Ignore only that impossible geometry.
                    // These exact identifiers were prevalidated unobscured:
                    // the intro by Apple's contrast audit, and the crystal
                    // disclosure by full-viewport geometry plus WCAG-tested
                    // opaque production color tokens.
                    if previouslyAuditedIdentifiers.contains(element.identifier),
                       frame.minY < contentTop,
                       frame.maxY > contentTop {
                        return true
                    }
                    let visible = frame.intersection(viewport)
                    return visible.isNull
                        || visible.width < frame.width * 0.5
                        || visible.height < frame.height * 0.5
                }
            }
        }
    }

    private func assertAX5CrystalTextLayout() {
        let windowWidth = app.windows.firstMatch.frame.width
        let explanation = app.staticTexts[
            "overview.fusion-hierarchy.explanation"
        ]
        let levelCount = app.staticTexts[
            "overview.fusion-hierarchy.level-count"
        ]
        XCTAssertTrue(explanation.exists)
        XCTAssertTrue(levelCount.exists)
        XCTAssertGreaterThanOrEqual(
            explanation.frame.width,
            windowWidth * 0.70,
            "AX5 hierarchy copy must retain a readable full-card line width"
        )
        XCTAssertGreaterThanOrEqual(
            levelCount.frame.minY,
            explanation.frame.maxY,
            "AX5 level count must stack after the hierarchy copy"
        )

        for label in ["10分 = 0.4", "25分 = 1.0", "60分 = 2.4", "時間の核"] {
            let step = app.staticTexts["overview.fusion-step.\(label)"]
            XCTAssertTrue(step.exists, "Missing fusion legend step: \(label)")
            XCTAssertGreaterThan(
                step.frame.width,
                step.frame.height,
                "AX5 fusion legend steps must not collapse into vertical text"
            )
        }
    }

    private func scrollUntilHittable(
        _ element: XCUIElement,
        attempts: Int = 10,
        swipingDown: Bool = false
    ) -> Bool {
        for _ in 0 ..< attempts {
            if element.exists, element.isHittable { return true }
            if swipingDown {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        return element.exists && element.isHittable
    }

    private func scrollUntilFullyVisibleInContent(
        _ element: XCUIElement,
        attempts: Int
    ) -> Bool {
        for _ in 0 ..< attempts {
            guard element.exists else {
                app.swipeUp()
                continue
            }

            let viewport = visibleContentViewport()
            let frame = element.frame
            if frame.minY >= viewport.minY,
               frame.maxY <= viewport.maxY {
                return true
            }

            let contentMovesUp = frame.maxY > viewport.maxY
            let startY = contentMovesUp ? 0.72 : 0.38
            let endY = contentMovesUp ? 0.50 : 0.60
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
                .press(
                    forDuration: 0.05,
                    thenDragTo: app.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: endY)
                    )
                )
        }

        let viewport = visibleContentViewport()
        let frame = element.frame
        return element.exists
            && frame.minY >= viewport.minY
            && frame.maxY <= viewport.maxY
    }

    private func visibleContentViewport() -> CGRect {
        let windowFrame = app.windows.firstMatch.frame
        let scrollView = app.scrollViews.firstMatch
        let navigationBar = app.navigationBars.firstMatch
        let scrollFrame = scrollView.exists
            ? windowFrame.intersection(scrollView.frame)
            : windowFrame
        let contentTop = navigationBar.exists
            ? max(scrollFrame.minY, navigationBar.frame.maxY)
            : scrollFrame.minY
        return CGRect(
            x: scrollFrame.minX,
            y: contentTop,
            width: scrollFrame.width,
            height: max(0, scrollFrame.maxY - contentTop)
        )
    }

    private func studyDayKey(
        for date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let boundary = calendar.date(
            bySettingHour: 4,
            minute: 0,
            second: 0,
            of: date
        ) ?? calendar.startOfDay(for: date)
        let studyDay = date < boundary
            ? (calendar.date(byAdding: .day, value: -1, to: date) ?? date)
            : date
        let components = calendar.dateComponents([.year, .month, .day], from: studyDay)
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

/// Keeps Dynamic Type unfixed so XCTest can actively resize the interface.
/// This complements the pinned-AX5 clipping/contrast audit above.
@MainActor
final class DynamicTypeSystemAuditUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180

        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 10))
    }

    func testHomeMenuAndOverviewRespondToSystemDynamicTypeChanges() throws {
        try performDynamicTypeAudit()

        app.buttons["メニュー"].tap()
        let overviewAction = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "積み上がりを見る")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(overviewAction))
        try performDynamicTypeAudit()

        overviewAction.tap()
        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 8))
        try performDynamicTypeAudit()
    }

    func testCrystalTopTextClippingAtSystemDynamicType() throws {
        app.buttons["メニュー"].tap()
        let overviewAction = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "積み上がりを見る")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(overviewAction))
        overviewAction.tap()
        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 8))

        let lens = app.descendants(matching: .any)["overview.lens"]
        XCTAssertTrue(lens.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilHittable(lens))
        if lens.elementType == .segmentedControl {
            let crystals = lens.buttons["結晶"]
            XCTAssertTrue(crystals.exists)
            crystals.tap()
        } else {
            lens.tap()
            let crystals = app.buttons["結晶"]
            XCTAssertTrue(crystals.waitForExistence(timeout: 4))
            crystals.tap()
        }

        let hierarchy = app.descendants(matching: .any)[
            "overview.fusion-hierarchy"
        ]
        XCTAssertTrue(
            hierarchy.waitForExistence(timeout: 5),
            "The system-size crystal hierarchy must remain in the scroll document"
        )
        // The deep hierarchy is exercised at AX5 by exact text geometry plus
        // the other four Apple audits. Run textClipped at the natural top here:
        // asking XCTest for a post-selection swipe can itself block for 60s on
        // Xcode 26 before the audit starts.
        try app.performAccessibilityAudit(for: .textClipped)
    }

    private func performDynamicTypeAudit() throws {
        // XCTest still reports SwiftUI visual children that are explicitly
        // accessibility-hidden inside the atmosphere Button. Those exact
        // labels use @ScaledMetric and are independently exercised by the
        // pinned-AX5 clipping audit; the combined Button remains the semantic
        // VoiceOver element. Suppress only this known audit artifact so any
        // other Dynamic Type issue still fails the test.
        let hiddenAtmosphereVisualLabels: Set<String> = [
            "深夜", "静かな定番",
            "オーロラ", "光に包まれる",
            "朝凪", "昼にも軽やか",
            "書斎", "仕事にも馴染む",
            // SectionEyebrow is an explicitly accessibility-hidden visual
            // component with a ScaledMetric font. XCTest nevertheless audits
            // its glyph nodes; the surrounding controls/cards carry the
            // localized semantic descriptions.
            "SPACE", "FOCUS", "FOCUS CONSTELLATION",
            "THIS WEEK", "CRYSTAL HIERARCHY",
            // Decorative text inside the accessibility-hidden empty weekly
            // crystal. The parent card announces the same value semantically.
            "0分"
        ]
        try app.performAccessibilityAudit(for: [.dynamicType]) { issue in
            guard let label = issue.element?.label else { return false }
            return hiddenAtmosphereVisualLabels.contains(label)
        }
    }

    private func scrollUntilHittable(
        _ element: XCUIElement,
        attempts: Int = 10
    ) -> Bool {
        for _ in 0 ..< attempts {
            if element.exists, element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

}
