import XCTest

@MainActor
final class EngagementOverviewUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCompletionGrowsWeeklyCrystalAndAllThreeScalesRemainReachable() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TSUMIBEN_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_MODE"] = "1"
        app.launchArguments += [
            "-AppleLanguages", "(ja)",
            "-AppleLocale", "ja_JP",
            // Exercise the widest completion action row deterministically.
            // Argument-domain defaults override a prompt receipt that another
            // Simulator run may have left in the shared UserDefaults domain.
            "-share.prompt.\(studyDayKey())", "false"
        ]
        app.launch()

        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))
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
        XCTAssertTrue(launcher.waitForExistence(timeout: 4))
        launcher.tap()

        stopCompletionAlertIfPresented(in: app)

        let weeklyCompletion = app.descendants(matching: .any)["reward.heading"]
        XCTAssertTrue(
            weeklyCompletion.waitForExistence(timeout: 20),
            "The guaranteed completion reward must explain real weekly progress"
        )
        XCTAssertTrue(
            String(describing: weeklyCompletion.value).contains("戻った回数1回"),
            "The reward heading must retain weekly recurrence context without presenting count as time value"
        )
        let rewardBridge = app.descendants(matching: .any)["reward.bridge"]
        XCTAssertTrue(
            rewardBridge.waitForExistence(timeout: 3),
            "The Reward Bridge must remain visible while its progress evidence is presented"
        )
        let fusionProgress = app.descendants(matching: .any)["reward.fusion-progress"]
        XCTAssertTrue(fusionProgress.waitForExistence(timeout: 3))
        XCTAssertTrue(fusionProgress.label.contains("×10へ 1/10"), fusionProgress.label)
        XCTAssertTrue(fusionProgress.label.contains("あと9粒"), fusionProgress.label)

        let rewardBridgeAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        rewardBridgeAttachment.name = "Reward Bridge — weekly and fusion progress"
        rewardBridgeAttachment.lifetime = .keepAlways
        add(rewardBridgeAttachment)

        let share = app.buttons["今の瓶をGIFでシェアする"]
        XCTAssertTrue(
            share.waitForExistence(timeout: 8),
            "The close control must be checked beside the optional share CTA"
        )
        let rest = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "分休憩する")
        ).firstMatch
        XCTAssertTrue(rest.waitForExistence(timeout: 3))

        let dismiss = app.buttons["reward.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 3))
        XCTAssertEqual(dismiss.label, "休憩の提案を閉じる")
        XCTAssertTrue(dismiss.isHittable)
        XCTAssertGreaterThanOrEqual(
            dismiss.frame.width,
            72,
            "The secondary exit must not collapse to its 34pt glyph width"
        )
        XCTAssertGreaterThanOrEqual(
            dismiss.frame.height,
            43.5,
            "The visible close capsule must meet Apple's minimum target height"
        )
        XCTAssertFalse(dismiss.frame.intersects(share.frame))
        XCTAssertFalse(dismiss.frame.intersects(rest.frame))
        XCTAssertLessThan(
            dismiss.frame.midX,
            share.frame.midX,
            "The completion actions must read left-to-right as close, GIF, then rest"
        )
        XCTAssertLessThan(
            share.frame.midX,
            rest.frame.midX,
            "The rest CTA must remain the rightmost completion action"
        )
        XCTAssertEqual(
            share.frame.midX - dismiss.frame.midX,
            rest.frame.midX - share.frame.midX,
            accuracy: 12,
            "The three completion actions must be distributed evenly instead of packed to one side"
        )
        let geometry = XCTAttachment(
            string: "dismiss=\(dismiss.frame)\nshare=\(share.frame)\nrest=\(rest.frame)"
        )
        geometry.name = "Reward Bridge CTA geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        try app.performAccessibilityAudit(for: .hitRegion)
        // Exercise the label's far edge, not only XCTest's center point. This
        // regresses the old 34pt glyph-only target hidden inside a wider frame.
        dismiss.coordinate(
            withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)
        ).tap()
        XCTAssertFalse(rewardBridge.waitForExistence(timeout: 2))

        app.buttons["メニュー"].tap()
        let overview = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "積み上がりを見る")
        ).firstMatch
        for _ in 0..<4 where !overview.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(overview.waitForExistence(timeout: 4))
        XCTAssertTrue(overview.isHittable)
        overview.tap()

        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 6))
        let weeklyCrystal = app.descendants(matching: .any)["overview.weekly-crystal"]
        XCTAssertTrue(weeklyCrystal.waitForExistence(timeout: 4))
        XCTAssertTrue((weeklyCrystal.label).contains("タイマー完走1回"))

        let lenses = app.segmentedControls["overview.lens"]
        XCTAssertTrue(lenses.waitForExistence(timeout: 4))
        XCTAssertEqual(lenses.buttons.count, 3)
        XCTAssertTrue(lenses.buttons["いま"].isSelected)

        lenses.buttons["結晶"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["overview.fusion-hierarchy"]
                .waitForExistence(timeout: 4),
            "The crystal lens must expose the decimal fusion ladder"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["overview.lifetime-constellation"]
                .waitForExistence(timeout: 4)
        )
        let destination = app.descendants(matching: .any)[
            "overview.constellation.destination"
        ]
        XCTAssertTrue(destination.waitForExistence(timeout: 4))
        XCTAssertTrue(destination.label.contains("最初の時間の核"), destination.label)
        XCTAssertTrue(
            String(describing: destination.value).contains("あと9粒"),
            String(describing: destination.value)
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["overview.constellation.core"].exists,
            "A single effort must expose only the destination vessel, not a completed core"
        )
        XCTAssertTrue(
            scrollUntilVisible(app.staticTexts["まとまり粒"], in: app),
            "The cluster section must remain reachable below the constellation"
        )

        let destinationAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        destinationAttachment.name = "One effort — outlined constellation destination"
        destinationAttachment.lifetime = .keepAlways
        add(destinationAttachment)

        // Reopen at the top before changing scale. This is both a real return
        // journey and a regression for the sticky close control; it avoids
        // trusting Simulator `isHittable` when a segment is partly underneath
        // the navigation chrome after a long scroll.
        app.buttons["overview.close"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 4))
        app.buttons["メニュー"].tap()
        let reopenedOverview = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "積み上がりを見る")
        ).firstMatch
        XCTAssertTrue(scrollUntilVisible(reopenedOverview, in: app))
        reopenedOverview.tap()
        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 6))

        let timelineLens = app.segmentedControls["overview.lens"].buttons["年月"]
        XCTAssertTrue(timelineLens.waitForExistence(timeout: 3))
        XCTAssertTrue(timelineLens.isHittable)
        timelineLens.tap()
        let selectedTimeline = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"),
            object: timelineLens
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selectedTimeline], timeout: 3), .completed)
        let timelineCoverage = app.descendants(matching: .any)[
            "overview.timeline.coverage-notice"
        ]
        XCTAssertTrue(
            scrollUntilVisible(timelineCoverage, in: app),
            "The timeline lens must expose its local-iCloud coverage contract"
        )

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Three-scale accumulation overview"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFortyYearTimelineBrowsesOldestYearAndLatest96RepresentativePebbles() {
        let app = XCUIApplication()
        app.launchEnvironment["TSUMIBEN_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_MODE"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_FORTY_YEAR_OVERVIEW"] = "1"
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()

        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.staticTexts["fixture.40y.timeline-ready"].waitForExistence(timeout: 8),
            app.staticTexts["fixture.40y.timeline-error"].label
        )
        let lenses = app.segmentedControls["overview.lens"]
        XCTAssertTrue(lenses.waitForExistence(timeout: 4))
        lenses.buttons["年月"].tap()

        let coverage = app.descendants(matching: .any)["overview.timeline.coverage-notice"]
        XCTAssertTrue(scrollUntilVisible(coverage, in: app))
        XCTAssertTrue(coverage.label.contains("この端末に届いている範囲"), coverage.label)

        let yearList = app.descendants(matching: .any)["overview.timeline.year-list"]
        XCTAssertTrue(yearList.waitForExistence(timeout: 8))
        let oldestYear = app.buttons["overview.timeline.year.1985"]
        for _ in 0 ..< 16 where !(oldestYear.exists && oldestYear.isHittable) {
            yearList.swipeLeft()
        }
        XCTAssertTrue(oldestYear.exists && oldestYear.isHittable)
        oldestYear.tap()

        let yearSummary = app.descendants(matching: .any)["overview.timeline.year.summary"]
        XCTAssertTrue(
            waitForLabel(
                of: yearSummary,
                containing: ["1985年", "110粒", "27,500グラム"],
                timeout: 10
            ),
            yearSummary.label
        )

        let january = app.buttons["overview.timeline.month.1985-01"]
        XCTAssertTrue(scrollUntilVisible(january, in: app))
        XCTAssertTrue(january.isHittable)
        january.tap()

        let monthSummary = app.descendants(matching: .any)["overview.timeline.month.summary"]
        XCTAssertTrue(
            waitForLabel(
                of: monthSummary,
                containing: ["110粒", "27,500グラム"],
                timeout: 8
            ),
            monthSummary.label
        )
        let preview = app.descendants(matching: .any)["overview.timeline.month.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        XCTAssertTrue(preview.label.contains("最新96粒"), preview.label)
        XCTAssertTrue(app.buttons["overview.timeline.month.close"].isHittable)

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "40-year timeline — oldest month exact and representative"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRewardReceiptSurvivesRelaunchWithoutDuplicatingTheSavedPebble() {
        let storeName = "reward-receipt-\(UUID().uuidString)"
        let initialCleaner = rewardReceiptApp(storeName: storeName, action: "clean")
        initialCleaner.launch()
        XCTAssertTrue(
            initialCleaner.staticTexts["fixture.40y.cleaned"].waitForExistence(timeout: 15)
        )
        initialCleaner.terminate()

        defer {
            let finalCleaner = rewardReceiptApp(storeName: storeName, action: "clean")
            finalCleaner.launch()
            _ = finalCleaner.staticTexts["fixture.40y.cleaned"].waitForExistence(timeout: 15)
            finalCleaner.terminate()
        }

        let app = rewardReceiptApp(storeName: storeName)
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 12))

        // UserDefaults outlives the dedicated SwiftData fixture. A receipt
        // left by an interrupted earlier test must not contaminate this case.
        let staleDismiss = app.buttons["休憩の提案を閉じる"]
        if staleDismiss.waitForExistence(timeout: 1), staleDismiss.isHittable {
            staleDismiss.tap()
        }

        app.buttons["メニュー"].tap()
        let demoDuration = app.buttons["12秒、DEMO"]
        XCTAssertTrue(demoDuration.waitForExistence(timeout: 4))
        demoDuration.tap()
        app.buttons["home.menu.close"].tap()

        let launcher = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "12秒集中する")
        ).firstMatch
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        launcher.tap()

        stopCompletionAlertIfPresented(in: app)

        let firstBridge = app.descendants(matching: .any)["reward.bridge"]
        XCTAssertTrue(firstBridge.waitForExistence(timeout: 25))
        let firstProgress = app.descendants(matching: .any)["reward.fusion-progress"]
        XCTAssertTrue(firstProgress.waitForExistence(timeout: 3))
        XCTAssertTrue(firstProgress.label.contains("×10へ 1/10"), firstProgress.label)

        app.terminate()
        app.launch()

        let recoveredBridge = app.descendants(matching: .any)["reward.bridge"]
        XCTAssertTrue(
            recoveredBridge.waitForExistence(timeout: 12),
            "A committed reward receipt must survive a process termination"
        )
        let recoveredProgress = app.descendants(matching: .any)["reward.fusion-progress"]
        XCTAssertTrue(recoveredProgress.waitForExistence(timeout: 3))
        XCTAssertTrue(recoveredProgress.label.contains("×10へ 1/10"), recoveredProgress.label)
        XCTAssertTrue(
            waitForProbeValue(
                in: app,
                containing: ["count=1", ":250"],
                timeout: 8
            ),
            "Relaunch must retain exactly one persisted 250g pebble"
        )

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Recovered Reward Receipt — one saved pebble"
        attachment.lifetime = .keepAlways
        add(attachment)

        let dismiss = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 3))
        dismiss.tap()
        app.terminate()
        app.launch()

        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 12))
        XCTAssertFalse(
            app.descendants(matching: .any)["reward.bridge"].waitForExistence(timeout: 2),
            "An acknowledged receipt must not be presented twice"
        )
        XCTAssertTrue(
            waitForProbeValue(
                in: app,
                containing: ["count=1", ":250"],
                timeout: 8
            ),
            "Acknowledging the receipt must not delete or duplicate the study record"
        )
        app.terminate()
    }

    func testFortyYearProjectionRendersExactFusionHierarchy() {
        let app = XCUIApplication()
        app.launchEnvironment["TSUMIBEN_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_MODE"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_FORTY_YEAR_OVERVIEW"] = "1"
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()

        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 8))
        let lenses = app.segmentedControls["overview.lens"]
        XCTAssertTrue(lenses.waitForExistence(timeout: 4))
        XCTAssertTrue(
            lenses.buttons["結晶"].isSelected,
            "A quiet forty-year account must open on durable lifetime progress, not a zero-week card"
        )

        let hierarchy = app.descendants(matching: .any)["overview.fusion-hierarchy"]
        XCTAssertTrue(scrollUntilVisible(hierarchy, in: app))

        let levelFive = app.descendants(matching: .any)["overview.fusion-level.5"]
        XCTAssertTrue(scrollUntilVisible(levelFive, in: app))
        XCTAssertTrue(levelFive.label.contains("3個"), levelFive.label)
        XCTAssertTrue(normalizedNumbers(in: levelFive).contains("300000粒"), levelFive.label)
        XCTAssertTrue(normalizedNumbers(in: levelFive).contains("75000000グラム"), levelFive.label)

        let upper = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        upper.name = "40-year fusion hierarchy — upper levels"
        upper.lifetime = .keepAlways
        add(upper)

        let levelFour = app.descendants(matching: .any)["overview.fusion-level.4"]
        XCTAssertTrue(scrollUntilVisible(levelFour, in: app))
        XCTAssertTrue(levelFour.label.contains("5個"), levelFour.label)
        XCTAssertTrue(normalizedNumbers(in: levelFour).contains("50000粒"), levelFour.label)
        XCTAssertTrue(normalizedNumbers(in: levelFour).contains("12500000グラム"), levelFour.label)

        let levelTwo = app.descendants(matching: .any)["overview.fusion-level.2"]
        XCTAssertTrue(scrollUntilVisible(levelTwo, in: app))
        XCTAssertTrue(levelTwo.label.contains("6個"), levelTwo.label)
        XCTAssertTrue(levelTwo.label.contains("600粒"), levelTwo.label)
        XCTAssertTrue(normalizedNumbers(in: levelTwo).contains("150000グラム"), levelTwo.label)

        let levelOne = app.descendants(matching: .any)["overview.fusion-level.1"]
        XCTAssertTrue(scrollUntilVisible(levelOne, in: app))
        XCTAssertTrue(levelOne.label.contains("4個"), levelOne.label)
        XCTAssertTrue(levelOne.label.contains("40粒"), levelOne.label)
        XCTAssertTrue(normalizedNumbers(in: levelOne).contains("10000グラム"), levelOne.label)

        let lower = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        lower.name = "40-year fusion hierarchy — lower levels"
        lower.lifetime = .keepAlways
        add(lower)
    }

    @discardableResult
    private func stopCompletionAlertIfPresented(
        in app: XCUIApplication,
        timeout: TimeInterval = 25
    ) -> Bool {
        let stop = app.buttons["focus.completion-alert.stop"]
        guard stop.waitForExistence(timeout: timeout) else { return false }
        XCTAssertEqual(stop.label, "終了アラートを止める")
        XCTAssertTrue(stop.isHittable)
        stop.tap()
        return true
    }

    private func scrollUntilVisible(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 12
    ) -> Bool {
        for _ in 0..<attempts {
            if isVisible(element, in: app) { return true }
            app.swipeUp()
        }
        return isVisible(element, in: app)
    }

    /// Mirrors the app's Gregorian 04:00 study-day boundary so the once-per-
    /// day completion share affordance is deterministic around midnight.
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

    private func isVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let windowFrame = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 44)
        return !element.frame.isEmpty && windowFrame.intersects(element.frame)
    }

    private func waitForLabel(
        of element: XCUIElement,
        containing fragments: [String],
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, fragments.allSatisfy(element.label.contains) {
                return true
            }
            usleep(50_000)
        } while Date() < deadline
        return element.exists && fragments.allSatisfy(element.label.contains)
    }

    private func normalizedNumbers(in element: XCUIElement) -> String {
        element.label
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
    }

    private func rewardReceiptApp(
        storeName: String,
        action: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TSUMIBEN_UI_TEST_PERSISTENT_STORE"] = storeName
        app.launchEnvironment["TSUMIBEN_UI_TEST_MODE"] = "1"
        if let action {
            app.launchEnvironment["TSUMIBEN_UI_TEST_PERSISTENT_ACTION"] = action
        }
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        return app
    }

    private func waitForProbeValue(
        in app: XCUIApplication,
        containing fragments: [String],
        timeout: TimeInterval
    ) -> Bool {
        let probe = app.descendants(matching: .any)["jar.presentation.probe"]
        guard probe.waitForExistence(timeout: min(4, timeout)) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let value = (probe.value as? String) ?? probe.label
            if fragments.allSatisfy(value.contains) { return true }
            usleep(50_000)
        } while Date() < deadline
        let value = (probe.value as? String) ?? probe.label
        return fragments.allSatisfy(value.contains)
    }
}
