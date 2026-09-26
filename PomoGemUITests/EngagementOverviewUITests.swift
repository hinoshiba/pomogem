import XCTest

@MainActor
final class EngagementOverviewUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCompletionGrowsWeeklyCrystalAndAllThreeScalesRemainReachable() throws {
        let app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launchArguments += [
            // Exercise the widest completion action row deterministically.
            // Argument-domain defaults override a prompt receipt that another
            // Simulator run may have left in the shared UserDefaults domain.
            "-share.prompt.\(studyDayKey())", "false"
        ]
        app.launch()

        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))
        assertNoRewardCardFromAnEarlierTest(in: app)
        app.buttons["home.duration-picker"].tap()

        let demoDuration = app.buttons["12秒、DEMO"]
        XCTAssertTrue(demoDuration.waitForExistence(timeout: 4))
        demoDuration.tap()

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
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_FORTY_YEAR_OVERVIEW"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
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

    /// A month from 1985, far older than 記録's twelve months, opens its
    /// themes and days, one day opens every record, and the month opens as
    /// its own monthly jar with a card.
    func testOldMonthOpensItsDaysAndItsMonthlyJar() {
        exerciseOldMonthDrillDown(accessibility5: false)
    }

    func testOldMonthDrillDownAtAccessibility5() {
        exerciseOldMonthDrillDown(accessibility5: true)
    }

    private func exerciseOldMonthDrillDown(accessibility5: Bool) {
        let app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_FORTY_YEAR_OVERVIEW"] = "1"
        if accessibility5 {
            app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        }
        PomoGemUITestLanguage.configureJapanese(app)
        app.launch()
        let suffix = accessibility5 ? " — AX5" : ""

        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.staticTexts["fixture.40y.timeline-ready"].waitForExistence(timeout: 8),
            app.staticTexts["fixture.40y.timeline-error"].label
        )
        if accessibility5 {
            let lensMenu = app.buttons["overview.lens"]
            XCTAssertTrue(scrollUntilVisible(lensMenu, in: app))
            lensMenu.tap()
            let timeline = app.buttons.matching(
                NSPredicate(format: "label == %@ AND identifier != %@", "年月", "overview.lens")
            ).firstMatch
            XCTAssertTrue(timeline.waitForExistence(timeout: 4))
            timeline.tap()
        } else {
            let lenses = app.segmentedControls["overview.lens"]
            XCTAssertTrue(lenses.waitForExistence(timeout: 4))
            lenses.buttons["年月"].tap()
        }

        let yearList = app.descendants(matching: .any)["overview.timeline.year-list"]
        XCTAssertTrue(scrollUntilVisible(yearList, in: app))
        let oldestYear = app.buttons["overview.timeline.year.1985"]
        for _ in 0 ..< 16 where !(oldestYear.exists && oldestYear.isHittable) {
            yearList.swipeLeft()
        }
        XCTAssertTrue(oldestYear.exists && oldestYear.isHittable)
        oldestYear.tap()
        let january = app.buttons["overview.timeline.month.1985-01"]
        XCTAssertTrue(scrollUntilVisible(january, in: app))
        january.tap()

        let monthSummary = app.descendants(matching: .any)["overview.timeline.month.summary"]
        XCTAssertTrue(
            waitForLabel(of: monthSummary, containing: ["110粒", "27,500グラム", "45時間50分"], timeout: 10),
            monthSummary.label
        )
        let themes = app.descendants(matching: .any)["overview.timeline.month.themes"]
        XCTAssertTrue(scrollUntilVisible(themes, in: app))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "40年の集中", "100パーセント")
            ).firstMatch.exists,
            "The theme row must read as one element with its share"
        )
        let monthAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        monthAttachment.name = "1985年1月 — themes\(suffix)"
        monthAttachment.lifetime = .keepAlways
        add(monthAttachment)

        let day = app.buttons["history.day.1985-01-15"]
        XCTAssertTrue(scrollUntilVisible(day, in: app))
        XCTAssertTrue(day.label.contains("45時間50分"), day.label)
        XCTAssertTrue(day.label.contains("110粒"), day.label)
        let dayListAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        dayListAttachment.name = "1985年1月 — days\(suffix)"
        dayListAttachment.lifetime = .keepAlways
        add(dayListAttachment)
        day.tap()

        let daySummary = app.descendants(matching: .any)["history.day.summary"]
        XCTAssertTrue(
            waitForLabel(of: daySummary, containing: ["110粒", "27,500グラム"], timeout: 10),
            daySummary.label
        )
        let firstRecord = app.descendants(matching: .any)["history.day.session"].firstMatch
        XCTAssertTrue(firstRecord.waitForExistence(timeout: 4))
        XCTAssertTrue(firstRecord.label.contains("40年の集中"), firstRecord.label)
        XCTAssertTrue(firstRecord.label.contains("実測"), firstRecord.label)
        let dayAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        dayAttachment.name = "1985年1月15日 — every record\(suffix)"
        dayAttachment.lifetime = .keepAlways
        add(dayAttachment)
        app.buttons["history.day.close"].tap()
        XCTAssertTrue(monthSummary.waitForExistence(timeout: 4))

        let wrapped = app.buttons["overview.timeline.month.wrapped"]
        for _ in 0 ..< 12 where !(wrapped.exists && wrapped.isHittable) {
            app.swipeDown()
        }
        XCTAssertTrue(wrapped.exists && wrapped.isHittable)
        XCTAssertTrue(wrapped.label.contains("この月を振り返る"), wrapped.label)
        wrapped.tap()
        XCTAssertTrue(app.staticTexts["1985年1月の瓶"].waitForExistence(timeout: 8))
        let themeTimes = app.descendants(matching: .any)["wrapped.theme-times"]
        XCTAssertTrue(scrollUntilVisible(themeTimes, in: app))
        let share = app.buttons["wrapped.share"]
        XCTAssertTrue(scrollUntilVisible(share, in: app))
        // Over a month sheet, dismissing returns to the month, not to a jar.
        XCTAssertTrue(app.buttons["月の記録へ戻る"].exists)
        XCTAssertFalse(app.buttons["瓶へ戻る"].exists)
        let wrappedAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        wrappedAttachment.name = "1985年1月 — monthly jar from 年月\(suffix)"
        wrappedAttachment.lifetime = .keepAlways
        add(wrappedAttachment)
        share.tap()
        XCTAssertTrue(
            app.navigationBars["カードにする"].waitForExistence(timeout: 10),
            "The card must open over Wrapped when it was opened from 年月"
        )
        let shareAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shareAttachment.name = "1985年1月 — card\(suffix)"
        shareAttachment.lifetime = .keepAlways
        add(shareAttachment)
    }

    /// With 設定 > 一般 > 言語と地域 > 暦法 set to 和暦, the current calendar
    /// calls 2024 「6年」. The year chips must stay 西暦 like every other
    /// month label in the app.
    func testTimelineYearsStayGregorianWithTheJapaneseCalendar() {
        let app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_FORTY_YEAR_OVERVIEW"] = "1"
        PomoGemUITestLanguage.configureJapaneseWithJapaneseCalendar(app)
        app.launch()

        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.staticTexts["fixture.40y.timeline-ready"].waitForExistence(timeout: 8),
            app.staticTexts["fixture.40y.timeline-error"].label
        )
        let lenses = app.segmentedControls["overview.lens"]
        XCTAssertTrue(lenses.waitForExistence(timeout: 4))
        lenses.buttons["年月"].tap()

        let newestYear = app.buttons["overview.timeline.year.2024"]
        XCTAssertTrue(scrollUntilVisible(newestYear, in: app))
        XCTAssertEqual(newestYear.label, "2024年")
        XCTAssertFalse(app.buttons["overview.timeline.year.6"].exists)
        let yearSummary = app.descendants(matching: .any)["overview.timeline.year.summary"]
        XCTAssertTrue(
            waitForLabel(of: yearSummary, containing: ["2024年", "2粒"], timeout: 10),
            yearSummary.label
        )
        let december = app.buttons["overview.timeline.month.2024-12"]
        XCTAssertTrue(scrollUntilVisible(december, in: app))
        XCTAssertTrue(december.label.contains("2024年12月"), december.label)

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "年月 with the Japanese calendar — Gregorian years"
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

        // UserDefaults outlives the dedicated SwiftData fixture. The clean
        // launch above dropped every receipt an earlier test left there.
        assertNoRewardCardFromAnEarlierTest(in: app)

        app.buttons["home.duration-picker"].tap()
        let demoDuration = app.buttons["12秒、DEMO"]
        XCTAssertTrue(demoDuration.waitForExistence(timeout: 4))
        demoDuration.tap()

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
        // The saved gem waits above the jar while its card is up, and closing
        // the card drops it (RuntimeFlowAuditUITests pins that order). A
        // relaunch keeps the order: nothing in the jar yet, then one drop.
        XCTAssertTrue(
            waitForProbeValue(in: app, containing: ["count=0;"], timeout: 8),
            "The recovered card must still hold its gem back until it is closed"
        )

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Recovered Reward Receipt — gem waiting for the card"
        attachment.lifetime = .keepAlways
        add(attachment)

        let dismiss = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 3))
        dismiss.tap()
        XCTAssertTrue(
            waitForProbeValue(
                in: app,
                containing: ["count=1;", ":250", "dropLanded=1"],
                timeout: 10
            ),
            "Closing the recovered card must land exactly the one persisted 250g pebble"
        )
        app.terminate()
        app.launch()

        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 12))
        let replayedLandingToast = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                "+250g",
                "積んだ"
            )
        ).firstMatch
        XCTAssertFalse(
            replayedLandingToast.waitForExistence(timeout: 5),
            "A restored pebble must not replay its landing toast on a later launch"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["reward.bridge"].waitForExistence(timeout: 2),
            "An acknowledged receipt must not be presented twice"
        )
        XCTAssertTrue(
            waitForProbeValue(
                in: app,
                containing: ["count=1;", ":250"],
                timeout: 8
            ),
            "Acknowledging the receipt must not delete or duplicate the study record"
        )
        app.terminate()
    }

    /// The other side of the test above. A local preview opens a new, empty
    /// in-memory store on every launch, so the previous process's receipt
    /// names a pebble this store never had. Shown again, its card would drop
    /// a gem that can never land, and the start button would stay disabled
    /// for every later test on the simulator.
    func testAnInMemoryRelaunchDoesNotInheritTheEarlierStoresReceipt() {
        let app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 12))
        assertNoRewardCardFromAnEarlierTest(in: app)

        app.buttons["home.duration-picker"].tap()
        let demoDuration = app.buttons["12秒、DEMO"]
        XCTAssertTrue(demoDuration.waitForExistence(timeout: 4))
        demoDuration.tap()
        let demoLauncher = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "12秒集中する")
        ).firstMatch
        XCTAssertTrue(demoLauncher.waitForExistence(timeout: 5))
        demoLauncher.tap()
        stopCompletionAlertIfPresented(in: app)
        let bridge = app.descendants(matching: .any)["reward.bridge"]
        XCTAssertTrue(
            bridge.waitForExistence(timeout: 25),
            "The premise: the completion is saved and its card is waiting"
        )

        // End the process with the card still up, as an interrupted test does.
        app.terminate()
        app.launch()

        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 12))
        XCTAssertFalse(
            bridge.waitForExistence(timeout: 3),
            "A new in-memory store must not show the replaced store's completion card"
        )
        XCTAssertTrue(
            waitForProbeValue(in: app, containing: ["count=0;"], timeout: 5),
            "The new store starts empty, so the jar has no gem to wait for"
        )
        let launcher = app.buttons["home.focus-launcher"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertTrue(
            launcher.isEnabled,
            "No stale receipt may keep the start button disabled"
        )
        app.terminate()
    }

    func testAggregateDetailMakesRetainedColorThemeAndAchievementSeparationExplicit() {
        let app = XCUIApplication()
        app.terminate()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_FORTY_YEAR_OVERVIEW"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launch()

        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 8))
        let lenses = app.segmentedControls["overview.lens"]
        XCTAssertTrue(lenses.waitForExistence(timeout: 4))
        if !lenses.buttons["結晶"].isSelected {
            lenses.buttons["結晶"].tap()
        }

        let cluster = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                "まとまり粒",
                "グラム"
            )
        ).firstMatch
        XCTAssertTrue(
            scrollUntilVisible(cluster, in: app),
            "The crystal lens must expose an inspectable aggregate summary"
        )
        XCTAssertTrue(cluster.isHittable)
        cluster.tap()

        XCTAssertTrue(app.navigationBars["まとまり粒"].waitForExistence(timeout: 4))
        let preservation = app.descendants(matching: .any)[
            "overview.cluster.preservation"
        ]
        XCTAssertTrue(preservation.waitForExistence(timeout: 3))
        XCTAssertTrue(preservation.label.contains("情報は削除されません"), preservation.label)
        XCTAssertTrue(preservation.label.contains("記念石"), preservation.label)

        let colorBreakdown = app.staticTexts["粒数による色の内訳"]
        XCTAssertTrue(scrollUntilVisible(colorBreakdown, in: app))
        XCTAssertTrue(app.staticTexts["テーマの内訳"].exists)

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Aggregate detail — lossless color and theme breakdown"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFortyYearProjectionRendersExactFusionHierarchy() {
        let app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_FORTY_YEAR_OVERVIEW"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
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

    /// The app drops the reward receipts an earlier test's store left in
    /// UserDefaults whenever it opens a new or cleaned store
    /// (`UITestLocalStateIsolation`). Tapping such a card away used to leave
    /// a gem that could never land, and the start button stayed disabled.
    private func assertNoRewardCardFromAnEarlierTest(in app: XCUIApplication) {
        XCTAssertFalse(
            app.descendants(matching: .any)["reward.bridge"].waitForExistence(timeout: 1),
            "A new store must not show another test's completion card"
        )
    }

    private func rewardReceiptApp(
        storeName: String,
        action: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["POMOGEM_UI_TEST_PERSISTENT_STORE"] = storeName
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        if let action {
            app.launchEnvironment["POMOGEM_UI_TEST_PERSISTENT_ACTION"] = action
        }
        PomoGemUITestLanguage.configureJapanese(app)
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
