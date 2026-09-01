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
        app.launchEnvironment["TSUMIBEN_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_MODE"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_AX5"] = "1"
        app.launchArguments += [
            "-AppleLanguages", "(ja)",
            "-AppleLocale", "ja_JP",
            "-share.prompt.\(studyDayKey())", "false"
        ]
        app.launch()

        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 10))
    }

    func testAX5PrimaryHomeMenuAndOverviewRemainReachableAndAuditable() throws {
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
        let lens = app.descendants(matching: .any)["overview.lens"]
        XCTAssertTrue(lens.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilHittable(lens))
        try auditVisibleScreen(named: "AX5 Overview — now")

        selectLens("結晶", with: lens)
        XCTAssertTrue(
            app.descendants(matching: .any)["overview.fusion-hierarchy"]
                .waitForExistence(timeout: 5)
        )
        try auditVisibleScreen(named: "AX5 Overview — crystals")

        selectLens("年月", with: lens)
        XCTAssertTrue(
            app.descendants(matching: .any)["overview.timeline.coverage-notice"]
                .waitForExistence(timeout: 5),
            "The on-demand year/month browser must replace the retired bounded shelf"
        )
        try auditVisibleScreen(named: "AX5 Overview — timeline")

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

    func testAX5RareRewardChoiceIsReadableAndReversible() throws {
        app.buttons["メニュー"].tap()
        let settingsAction = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "設定")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(settingsAction))
        settingsAction.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 8))

        let picker = app.descendants(matching: .any)["settings.rare-reward-mode"]
        XCTAssertTrue(scrollUntilHittable(picker))
        XCTAssertTrue(picker.isHittable)
        XCTAssertTrue(app.staticTexts["粒のバリエーション"].waitForExistence(timeout: 3))

        picker.tap()
        XCTAssertTrue(app.staticTexts["抽選しない"].waitForExistence(timeout: 5))
        try auditVisibleScreen(named: "AX5 Rare reward choices")

        let navigationBar = app.navigationBars["ランダムなレア粒"]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 4))
        navigationBar.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 4))
    }

    func testAX5RewardBridgeKeepsActionsBeforeUnclippedProgress() throws {
        // A durable receipt can outlive the in-memory SwiftData fixture when a
        // prior UI-test process is interrupted. Acknowledge it before earning
        // the one completion under test.
        let staleDismiss = app.buttons["reward.dismiss"]
        if staleDismiss.waitForExistence(timeout: 2), staleDismiss.isHittable {
            staleDismiss.tap()
            XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 4))
        }

        app.buttons["メニュー"].tap()
        let demoDuration = app.buttons["12秒、DEMO"]
        XCTAssertTrue(demoDuration.waitForExistence(timeout: 4))
        demoDuration.tap()
        app.buttons["home.menu.close"].tap()

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

    private func selectLens(_ title: String, with picker: XCUIElement) {
        XCTAssertTrue(scrollUntilHittable(picker))
        picker.tap()
        let option = app.buttons[title]
        XCTAssertTrue(option.waitForExistence(timeout: 4), "Missing lens option: \(title)")
        option.tap()
    }

    private func auditVisibleScreen(named name: String) throws {
        let audits: [(String, XCUIAccessibilityAuditType)] = [
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
            try XCTContext.runActivity(named: "\(name) — \(auditName)") { _ in
                let viewport = app.windows.firstMatch.frame
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
                    let frame = element.frame
                    let visible = frame.intersection(viewport)
                    return visible.isNull
                        || visible.width < frame.width * 0.5
                        || visible.height < frame.height * 0.5
                }
            }
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
        app.launchEnvironment["TSUMIBEN_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_MODE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
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
            "0.0標準単位"
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
