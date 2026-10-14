import XCTest

@MainActor
final class TimeFusionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launchArguments += ["-review.requested-version", "1.0"]
    }

    func testEqualFiveHundredMinutesShowTheSameTwoTimeCrystals() throws {
        var recordSignatures: [String] = []
        for fixture in ["timeShort", "timeLong"] {
            launch(fixture)
            let records = try waitForRecords(grams: [2_500, 2_500])
            recordSignatures.append(records)
            let jar = app.buttons["瓶"]
            XCTAssertTrue(jar.waitForExistence(timeout: 5))
            XCTAssertFalse((jar.value as? String ?? "").contains("次の結晶まであと10粒"))
            capture("500 minutes — \(fixture)")
            app.terminate()
        }
        XCTAssertEqual(recordSignatures[0], recordSignatures[1],
                       "Fifty 10-minute sessions and five 100-minute sessions must have identical time units")
    }

    func testFirstTimeCrystalWaitsForRewardAcknowledgementAndSharesTheTotal() throws {
        launch("nine")
        _ = try waitForRecords(grams: [2_250])
        app.buttons["home.duration-picker"].tap()
        let demo = app.buttons["12秒、DEMO"]
        XCTAssertTrue(demo.waitForExistence(timeout: 5))
        demo.tap()
        let start = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "12秒集中する")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        stopCompletionAlertIfPresented(in: app)
        let dismiss = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 28))
        XCTAssertFalse(app.staticTexts["fusion.celebration.title"].exists)
        let progress = app.descendants(matching: .any)["reward.fusion-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 4))
        XCTAssertFalse(progress.label.contains("10/10"), progress.label)
        capture("250 minutes — reward before landing")
        dismiss.tap()
        let celebration = app.staticTexts["fusion.celebration.title"]
        XCTAssertTrue(celebration.waitForExistence(timeout: 12))
        XCTAssertTrue(celebration.label.contains("4時間10分"), celebration.label)
        capture("250 minutes — first time crystal")
        let share = app.buttons["積み上がりをカードにする"]
        XCTAssertTrue(scrollTo(share))
        share.tap()
        XCTAssertTrue(app.navigationBars["カードにする"].waitForExistence(timeout: 8))
        let duration = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "4時間10分")
        ).firstMatch
        XCTAssertTrue(duration.waitForExistence(timeout: 10))
        capture("250 minutes — public share")
        app.navigationBars["カードにする"].buttons["閉じる"].tap()
        _ = try waitForRecords(grams: [2_500])
        openOverview()
        selectCrystalLens()
        let explanation = app.descendants(matching: .any)["overview.fusion-hierarchy.explanation"]
        XCTAssertTrue(scrollTo(explanation))
        XCTAssertTrue(explanation.label.contains("合計時間"), explanation.label)
        capture("250 minutes — time hierarchy")
    }

    func testLargeTextTimeHierarchyAndOriginalRecordsRemainReachable() throws {
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        launch("timeLong")
        _ = try waitForRecords(grams: [2_500, 2_500])
        capture("AX5 — two time crystals")
        let progress = app.buttons["jar.time-fusion.progress"]
        XCTAssertTrue(revealHomeProgressFullyAboveLauncher(progress),
                      "The complete time-progress action must fit below navigation and above the fixed Start button")
        XCTAssertLessThan(progress.frame.maxY, app.buttons["home.focus-launcher"].frame.minY)
        XCTAssertTrue(progress.label.contains("次の結晶まで あと4時間10分"), progress.label)
        capture("AX5 — reachable time-progress action")
        progress.tap()
        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 8))
        let lensMenu = app.buttons["overview.lens"]
        XCTAssertTrue(lensMenu.waitForExistence(timeout: 5))
        XCTAssertEqual(lensMenu.value as? String, "結晶",
                       "The progress action opens its time breakdown without another lens selection")
        let explanation = app.descendants(matching: .any)["overview.fusion-hierarchy.explanation"]
        XCTAssertTrue(scrollTo(explanation))
        XCTAssertTrue(explanation.label.contains("合計時間"), explanation.label)
        capture("AX5 — time hierarchy")
        let records = app.buttons["overview.time-crystals.records"]
        XCTAssertTrue(scrollTo(records))
        records.tap()
        XCTAssertTrue(app.descendants(matching: .any)["overview.timeline.year-list"].waitForExistence(timeout: 8))
        let year = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "overview.timeline.year.")
        ).firstMatch
        XCTAssertTrue(year.waitForExistence(timeout: 5))
        XCTAssertTrue(year.isHittable,
                      "Opening the original records must expose a usable year choice without another scroll")
        capture("AX5 — original records")
    }

    func testEnglishTimeProgressAndOriginalRecords() throws {
        PomoGemUITestLanguage.configureEnglish(app)
        launch("timeLong")
        _ = try waitForRecords(grams: [2_500, 2_500])
        let progress = app.buttons["jar.time-fusion.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        let progressText = progress.label
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\u{202f}", with: " ")
        XCTAssertTrue(progressText.contains("4 hr"), progressText)
        XCTAssertTrue(progressText.contains("10 min"), progressText)
        XCTAssertTrue(progressText.contains("until the next crystal"), progressText)
        capture("English — 500 minutes, two crystals, five original records")
        // The visual HUD is deliberately hidden from accessibility. Its
        // source-record count is available in the menu's combined readout.
        let menu = app.buttons["home.menu.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertEqual(menu.label, "Menu")
        menu.tap()
        XCTAssertTrue(app.navigationBars["Menu"].waitForExistence(timeout: 5))
        let originalCount = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "5 original records")
        ).firstMatch
        XCTAssertTrue(originalCount.waitForExistence(timeout: 5),
                      "The five source records stay distinct from the two time crystals")
        capture("English — original records in the accessible menu readout")
        app.buttons["home.menu.close"].tap()
        XCTAssertTrue(scrollTo(progress))
        progress.tap()
        XCTAssertTrue(app.navigationBars["Progress"].waitForExistence(timeout: 8))
        let lenses = app.segmentedControls["overview.lens"]
        XCTAssertTrue(lenses.waitForExistence(timeout: 4))
        XCTAssertTrue(lenses.buttons["Crystals"].isSelected,
                      "The progress action opens its time breakdown without another lens selection")
        let title = app.staticTexts["Crystals of accumulated time"]
        XCTAssertTrue(scrollTo(title))
        let records = app.buttons["overview.time-crystals.records"]
        XCTAssertTrue(scrollTo(records))
        XCTAssertEqual(records.label, "View original records")
        capture("English — time crystals and original records in Progress")
    }

    func testExploreOpensOverviewBeforeTheNextQueuedCelebration() {
        checkExploreWithQueuedCelebrations(reduceMotion: false)
    }

    func testExploreOpensOverviewBeforeTheNextQueuedCelebrationWithReduceMotion() {
        checkExploreWithQueuedCelebrations(reduceMotion: true, accessibility5: true)
    }

    func testShareOpensBeforeTheNextQueuedCelebration() {
        checkShareWithQueuedCelebrations(reduceMotion: false)
    }

    func testShareOpensBeforeTheNextQueuedCelebrationWithReduceMotion() {
        checkShareWithQueuedCelebrations(reduceMotion: true, accessibility5: true)
    }

    private func checkShareWithQueuedCelebrations(reduceMotion: Bool, accessibility5: Bool = false) {
        app.launchEnvironment["POMOGEM_UI_TEST_QUEUED_CELEBRATIONS"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_REDUCE_MOTION"] = reduceMotion ? "1" : "0"
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = accessibility5 ? "1" : "0"
        app.launchEnvironment["POMOGEM_UI_TEST_GEM_SHOWCASE"] = "tiers"
        app.launch()
        defer {
            if (testRun?.failureCount ?? 0) > 0 {
                capture("Queued celebrations — share handoff failure")
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "Queued celebrations — share handoff accessibility hierarchy"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
            }
        }

        let title = app.staticTexts["fusion.celebration.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 12))
        XCTAssertTrue(title.label.contains("4時間10分"), title.label)
        let share = app.buttons["積み上がりをカードにする"]
        XCTAssertTrue(scrollTo(share))
        capture("Queued celebrations — first crystal before Share")
        share.tap()

        let composer = app.navigationBars["カードにする"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8),
                      "Share must open before the queued second celebration")
        // This is the composer's own close control, not the completion
        // sheet's close button or the system activity sheet's Cancel.
        let close = app.buttons["share.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "share.close").count, 1)
        let shareReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            composer.exists && close.isHittable && close.isEnabled && !title.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shareReady], timeout: 8), .completed,
                       "The next celebration must not cover or replace the share composer")
        capture("Queued celebrations — Share before next celebration")
        close.tap()

        let celebrationClose = app.buttons["fusion.celebration.close"]
        let nextTitle = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            title.exists && title.label.contains("41時間40分")
                && celebrationClose.isHittable && !composer.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [nextTitle], timeout: 8), .completed,
                       "Closing Share must reveal a usable second celebration")
        capture("Queued celebrations — second crystal after Share closes")
        celebrationClose.tap()

        let launcher = app.buttons["home.focus-launcher"]
        let homeReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            launcher.exists && launcher.isHittable && launcher.isEnabled
                && !title.exists && !composer.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [homeReady], timeout: 8), .completed,
                       "Finishing both celebrations must leave Home usable")
    }

    private func checkExploreWithQueuedCelebrations(reduceMotion: Bool, accessibility5: Bool = false) {
        app.launchEnvironment["POMOGEM_UI_TEST_QUEUED_CELEBRATIONS"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_REDUCE_MOTION"] = reduceMotion ? "1" : "0"
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = accessibility5 ? "1" : "0"
        app.launchEnvironment["POMOGEM_UI_TEST_GEM_SHOWCASE"] = "tiers"
        app.launch()

        let title = app.staticTexts["fusion.celebration.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 12))
        XCTAssertTrue(title.label.contains("4時間10分"), title.label)
        let explore = app.buttons["積み上げた時間と記録を見る"]
        XCTAssertTrue(scrollTo(explore))
        capture("Queued celebrations — first crystal")
        explore.tap()

        let overview = app.navigationBars["積み上がり"]
        XCTAssertTrue(overview.waitForExistence(timeout: 8),
                      "Explore must open Progress before the queued second celebration")
        if accessibility5 {
            let lenses = app.buttons["overview.lens"]
            XCTAssertTrue(lenses.waitForExistence(timeout: 5))
            XCTAssertEqual(lenses.value as? String, "結晶")
        } else {
            let lenses = app.segmentedControls["overview.lens"]
            XCTAssertTrue(lenses.waitForExistence(timeout: 5))
            XCTAssertTrue(lenses.buttons["結晶"].isSelected)
        }
        let time = app.descendants(matching: .any)["overview.lifetime-time"].firstMatch
        XCTAssertTrue(time.waitForExistence(timeout: 5))
        XCTAssertTrue(time.label.contains("集中時間"), time.label)
        XCTAssertTrue(time.label.contains("48時間45分"), time.label)
        XCTAssertTrue(time.isHittable)
        XCTAssertGreaterThanOrEqual(time.frame.minY, overview.frame.maxY - 1)
        XCTAssertLessThanOrEqual(time.frame.maxY, app.windows.firstMatch.frame.maxY - 12,
                                 "Explore must show the focus-time answer in the first viewport")
        XCTAssertFalse(title.exists, "The next celebration waits until Progress has closed")
        capture("Queued celebrations — crystal lens before next celebration")
        app.buttons["overview.close"].tap()

        let nextTitle = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            title.exists && title.label.contains("41時間40分")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [nextTitle], timeout: 8), .completed,
                       "Closing Progress must resume the second queued celebration")
        XCTAssertFalse(overview.exists)
        capture("Queued celebrations — second crystal after Progress closes")
        app.buttons["fusion.celebration.close"].tap()
        let launcher = app.buttons["home.focus-launcher"]
        let homeReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            launcher.exists && launcher.isHittable && launcher.isEnabled && !title.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [homeReady], timeout: 8), .completed)
    }

    private func launch(_ fixture: String) {
        app.launchEnvironment["POMOGEM_UI_TEST_GEM_SHOWCASE"] = fixture
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["jar.presentation.probe"].waitForExistence(timeout: 12))
    }

    private func waitForRecords(grams expected: [Int]) throws -> String {
        let probe = app.descendants(matching: .any)["jar.presentation.probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 8))
        var records = ""
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let raw = probe.value as? String ?? ""
            records = raw.split(separator: ";").first { $0.hasPrefix("records=") }
                .map { String($0.dropFirst("records=".count)) } ?? ""
            let grams = records.split(separator: ",").compactMap { entry in
                entry.split(separator: ":", maxSplits: 1).last.flatMap { Int($0) }
            }.sorted()
            return grams == expected.sorted()
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 12), .completed, records)
        return records.split(separator: ",").map(String.init).sorted().joined(separator: ",")
    }

    private func openOverview() {
        if !app.buttons["メニュー"].waitForExistence(timeout: 2) {
            // Compact toolbar layouts can place the menu in the native
            // overflow at accessibility sizes.
            let overflow = app.buttons["OverflowBarButtonItem"]
            XCTAssertTrue(overflow.waitForExistence(timeout: 5))
            overflow.tap()
        }
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
        app.buttons["メニュー"].tap()
        let action = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "積み上がりを見る")).firstMatch
        XCTAssertTrue(scrollTo(action))
        action.tap()
        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 8))
    }

    private func selectCrystalLens() {
        let segments = app.segmentedControls["overview.lens"]
        if segments.waitForExistence(timeout: 2) {
            segments.buttons["結晶"].tap()
        } else {
            let menu = app.buttons["overview.lens"]
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            menu.tap()
            app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "結晶", "overview.lens")).firstMatch.tap()
        }
    }

    private func revealHomeProgressFullyAboveLauncher(_ progress: XCUIElement) -> Bool {
        let scrollView = app.scrollViews.containing(.button, identifier: "jar.time-fusion.progress").firstMatch
        let launcher = app.buttons["home.focus-launcher"]
        guard scrollView.waitForExistence(timeout: 5), progress.exists, launcher.exists else { return false }
        guard waitUntilFrameSettles(progress), waitUntilFrameSettles(launcher) else { return false }
        var observations: [String] = []

        for attempt in 0..<10 {
            let window = app.windows.firstMatch.frame
            let scrollFrame = scrollView.frame
            let navigationBottom = app.navigationBars.allElementsBoundByIndex
                .filter { $0.exists && $0.frame.intersects(window) }
                .map { $0.frame.maxY }.max() ?? window.minY
            let visibleTop = max(window.minY, scrollFrame.minY, navigationBottom) + 8
            let visibleBottom = min(window.maxY, scrollFrame.maxY, launcher.frame.minY) - 8
            let frame = progress.frame
            observations.append("attempt=\(attempt); progress=\(frame); visibleTop=\(visibleTop); visibleBottom=\(visibleBottom); launcher=\(launcher.frame); scrollView=\(scrollFrame)")
            if frame.minY >= visibleTop, frame.maxY <= visibleBottom, progress.isHittable {
                let geometry = XCTAttachment(string: observations.joined(separator: "\n"))
                geometry.name = "AX5 — complete time-progress action geometry"
                geometry.lifetime = .keepAlways
                add(geometry)
                return true
            }

            // Drag entirely in Home's scrollable viewport using global
            // coordinates, so scrolling cannot move the gesture's anchor.
            // Center the whole action and hold before lifting the finger;
            // a fling can overshoot from below Start to above navigation.
            let room = visibleBottom - visibleTop
            guard room > 60, frame.height <= room else { break }
            let correction = frame.midY - (visibleTop + visibleBottom) / 2
            let moveUp = correction > 0
            let distance = min(room * 0.65, max(24, abs(correction)))
            let startY = moveUp ? visibleBottom - 12 : visibleTop + 12
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: scrollFrame.midX, dy: startY))
            let end = origin.withOffset(CGVector(dx: scrollFrame.midX,
                                                 dy: startY + (moveUp ? -distance : distance)))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
            guard waitUntilFrameSettles(progress) else { break }
        }
        let geometry = XCTAttachment(string: observations.joined(separator: "\n"))
        geometry.name = "AX5 — time-progress action failed-fit geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        capture("AX5 — time-progress action could not fit above Start")
        return false
    }

    private func scrollTo(_ element: XCUIElement) -> Bool {
        for _ in 0..<12 {
            if element.exists, element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
