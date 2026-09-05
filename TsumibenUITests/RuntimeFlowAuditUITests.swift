import XCTest

/// Exercises the four free timer choices and the complete theme lifecycle.
///
/// These paths are intentionally kept separate from the fast 12-second demo:
/// a production regression can otherwise leave the real preset controls
/// or a destructive theme action unusable while every completion test passes.
@MainActor
final class RuntimeFlowAuditUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 360

        app = XCUIApplication()
        app.launchEnvironment["TSUMIBEN_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_MODE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()

        let menu = app.buttons["メニュー"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        // A previously interrupted XCTest may have left its disposable focus
        // overlay restored above Home. Cancel only that in-memory test run.
        if !menu.isHittable {
            cancelPresentedFocusIfNeeded()
        }
        XCTAssertTrue(waitForHittable(menu, timeout: 5))
    }

    override func tearDownWithError() throws {
        // If an assertion aborts while Focus is presented, leave the shared
        // simulator process in a reversible state for the next test. The
        // in-memory data itself is never erased or uninstalled.
        cancelPresentedFocusIfNeeded()
        app.terminate()
        app = nil
    }

    func testFreeTimersStartPauseResumeAndCancelWithoutCreatingEffort() throws {
        let presentationProbe = app.descendants(matching: .any)["jar.presentation.probe"]
        XCTAssertTrue(presentationProbe.waitForExistence(timeout: 5))
        let initialPresentation = presentationValue(from: presentationProbe)

        try exerciseInterruptibleFocus(
            durationButtonPrefix: "25分",
            launcherFragment: "25分集中する",
            expectedRemainingMinute: "24分",
            attachmentName: "25-minute focus — paused and reversible"
        )
        XCTAssertEqual(
            presentationValue(from: presentationProbe),
            initialPresentation,
            "Cancelling 25 minutes must not invent a study pebble"
        )

        try exerciseInterruptibleFocus(
            durationButtonPrefix: "45分",
            launcherFragment: "45分集中する",
            expectedRemainingMinute: "44分",
            attachmentName: "45-minute focus — paused and reversible"
        )
        XCTAssertEqual(
            presentationValue(from: presentationProbe),
            initialPresentation,
            "Cancelling 45 minutes must not invent a study pebble"
        )

        try exerciseInterruptibleFocus(
            durationButtonPrefix: "60分",
            launcherFragment: "60分集中する",
            expectedRemainingMinute: "59分",
            attachmentName: "60-minute focus — paused and reversible"
        )
        XCTAssertEqual(
            presentationValue(from: presentationProbe),
            initialPresentation,
            "Cancelling 60 minutes must not invent a study pebble"
        )

        try exerciseInterruptibleFocus(
            durationButtonPrefix: "90分",
            launcherFragment: "90分集中する",
            expectedRemainingMinute: "89分",
            attachmentName: "90-minute focus — paused and reversible"
        )
        XCTAssertEqual(
            presentationValue(from: presentationProbe),
            initialPresentation,
            "Cancelling 90 minutes must not invent a study pebble"
        )
    }

    func testLongPressLauncherChangesThemeWithoutStartingTimer() {
        let alternateTheme = "長押しテーマ"

        openMenuAction(containing: "設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 6))
        let addTheme = app.buttons["テーマを追加"]
        XCTAssertTrue(scrollUntilHittable(addTheme))
        addTheme.tap()
        XCTAssertTrue(app.navigationBars["テーマを追加"].waitForExistence(timeout: 5))
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 4))
        nameField.tap()
        nameField.typeText(alternateTheme)
        app.navigationBars["テーマを追加"].buttons["保存"].tap()
        XCTAssertTrue(waitForAbsence(app.navigationBars["テーマを追加"]))
        tapNavigationBack(from: "設定")

        let launcher = app.descendants(matching: .any)["home.focus-launcher"]
        XCTAssertTrue(waitForHittable(launcher, timeout: 6))
        launcher.press(forDuration: 0.9)

        let alternateChoice = app.buttons[alternateTheme]
        XCTAssertTrue(
            alternateChoice.waitForExistence(timeout: 5),
            "A long press must reveal the active theme choices"
        )
        alternateChoice.tap()

        XCTAssertFalse(
            app.buttons["一時停止"].exists,
            "Choosing a theme from the long-press menu must not start focus"
        )
        XCTAssertTrue(
            launcher.label.contains(alternateTheme),
            "The launcher must immediately reflect the selected theme"
        )

        launcher.tap()
        let focusSubject = app.staticTexts["focus.subject"]
        XCTAssertTrue(focusSubject.waitForExistence(timeout: 6))
        XCTAssertEqual(focusSubject.label, alternateTheme)
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: 4))
    }

    func testThemeCanBeAddedEditedHiddenRestoredSelectedAndDeleted() {
        let originalName = "監査テーマ"
        let editedName = "監査テーマ改"

        openMenuAction(containing: "設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 6))

        let addTheme = app.buttons["テーマを追加"]
        XCTAssertTrue(scrollUntilHittable(addTheme), "Settings must expose theme creation")
        addTheme.tap()

        XCTAssertTrue(app.navigationBars["テーマを追加"].waitForExistence(timeout: 5))
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 4))
        nameField.tap()
        nameField.typeText(originalName)
        let color = app.buttons["色候補2、瑠璃"]
        XCTAssertTrue(scrollUntilHittable(color))
        color.tap()
        app.navigationBars["テーマを追加"].buttons["保存"].tap()
        XCTAssertTrue(waitForAbsence(app.navigationBars["テーマを追加"]))
        waitForUISettle()

        let createdRow = button(containing: originalName)
        XCTAssertTrue(waitForHittable(createdRow, timeout: 6))
        createdRow.tap()

        XCTAssertTrue(app.navigationBars["テーマを編集"].waitForExistence(timeout: 5))
        replaceText(in: app.textFields.firstMatch, with: editedName)
        dismissKeyboard(from: app.textFields.firstMatch)
        let visibility = app.switches["ホームの選択肢に表示"]
        XCTAssertTrue(scrollUntilHittable(visibility))
        XCTAssertTrue(waitForSwitch(visibility, value: "1"))
        tapSwitch(visibility)
        XCTAssertTrue(waitForSwitch(visibility, value: "0"))
        app.navigationBars["テーマを編集"].buttons["保存"].tap()
        XCTAssertTrue(waitForAbsence(app.navigationBars["テーマを編集"]))
        waitForUISettle()

        var editedRow = button(containing: editedName)
        XCTAssertTrue(editedRow.waitForExistence(timeout: 6))
        XCTAssertTrue(editedRow.label.contains("非表示"), editedRow.label)
        editedRow.tap()

        XCTAssertTrue(app.navigationBars["テーマを編集"].waitForExistence(timeout: 5))
        let restoredVisibility = app.switches["ホームの選択肢に表示"]
        XCTAssertTrue(scrollUntilHittable(restoredVisibility))
        XCTAssertTrue(waitForSwitch(restoredVisibility, value: "0"))
        tapSwitch(restoredVisibility)
        XCTAssertTrue(waitForSwitch(restoredVisibility, value: "1"))
        app.navigationBars["テーマを編集"].buttons["保存"].tap()
        XCTAssertTrue(waitForAbsence(app.navigationBars["テーマを編集"]))
        waitForUISettle()

        editedRow = button(containing: editedName)
        XCTAssertTrue(editedRow.waitForExistence(timeout: 6))
        XCTAssertFalse(editedRow.label.contains("非表示"), editedRow.label)

        tapNavigationBack(from: "設定")
        app.buttons["メニュー"].tap()
        let themeMenu = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "テーマ、")
        ).firstMatch
        XCTAssertTrue(themeMenu.waitForExistence(timeout: 4))
        themeMenu.tap()
        let themeChoice = app.buttons[editedName]
        XCTAssertTrue(themeChoice.waitForExistence(timeout: 4))
        themeChoice.tap()
        app.buttons["home.menu.close"].tap()

        let selectedLauncher = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", editedName)
        ).firstMatch
        XCTAssertTrue(
            selectedLauncher.waitForExistence(timeout: 5),
            "A restored theme must be selectable from Home"
        )

        openMenuAction(containing: "設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))
        // Scope to the exact Settings row. The previously selected Home
        // launcher remains in the backing navigation hierarchy and also
        // contains the theme name, but is intentionally not hittable here.
        editedRow = app.buttons[editedName]
        XCTAssertTrue(scrollUntilHittable(editedRow))
        editedRow.swipeLeft()
        let delete = app.buttons["削除"]
        XCTAssertTrue(delete.waitForExistence(timeout: 4))
        delete.tap()

        // Assert the destructive alert's visible contract and its explicit,
        // reversible cancel action before exercising deletion.
        let confirmationTitle = app.staticTexts["テーマを削除"]
        XCTAssertTrue(confirmationTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "過去の記録")
            ).firstMatch.exists,
            "Deletion must explain the history-preservation contract"
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "取り消せません")
            ).firstMatch.exists,
            "Deletion must make irreversibility explicit"
        )

        let cancel = app.buttons["キャンセル"]
        let cancelExists = cancel.exists
        let cancelIsHittable = cancelExists && cancel.isHittable
        let cancelFrame = cancelExists ? cancel.frame : .null
        let cancelProbe = XCTAttachment(
            string: "exists=\(cancelExists)\nhittable=\(cancelIsHittable)\nframe=\(String(describing: cancelFrame))"
        )
        cancelProbe.name = "Theme deletion — cancel AX probe"
        cancelProbe.lifetime = .keepAlways
        add(cancelProbe)
        XCTAssertTrue(cancelExists, "Deletion confirmation must expose an explicit cancel action")
        XCTAssertTrue(cancelIsHittable, "Deletion confirmation cancel action must be operable")
        XCTAssertFalse(cancelFrame.isEmpty, "Deletion confirmation cancel action needs a visible hit target")

        cancel.tap()
        XCTAssertTrue(waitForAbsence(confirmationTitle))
        editedRow = app.buttons[editedName]
        XCTAssertTrue(
            editedRow.waitForExistence(timeout: 3),
            "Cancelling deletion must preserve the category"
        )

        editedRow.swipeLeft()
        XCTAssertTrue(delete.waitForExistence(timeout: 4))
        delete.tap()
        XCTAssertTrue(confirmationTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["キャンセル"].isHittable)

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Theme deletion — explicit history-preservation confirmation"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["「\(editedName)」を削除"].tap()
        XCTAssertFalse(app.buttons[editedName].waitForExistence(timeout: 2))

        tapNavigationBack(from: "設定")
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", "集中する")
            ).firstMatch.waitForExistence(timeout: 5),
            "Deleting the selected theme must fall back to another usable theme"
        )
    }

    /// Captures the unretouched Japanese UI used for the App Store product page.
    ///
    /// The disposable Debug fixture is only a way to reach deterministic states:
    /// no screenshot includes its 12-second launcher, accessibility probes, fault
    /// controls, personal text, or a simulated Pro entitlement. Export the five
    /// named attachments from the xcresult instead of taking ad-hoc Simulator
    /// captures so the set remains reproducible.
    func testAppStoreScreenshotSetJapaneseReleaseCandidate() {
        // Relaunch the disposable store. Release 1.0 has no rare-reward draw or
        // opt-in surface, keeping this product-page set deterministic.
        app.terminate()
        // The in-memory SwiftData fixture intentionally survives no records,
        // while UserDefaults normally retains the optional-rest cadence between
        // UI-test runs. An invalid argument-domain value makes the typed Data
        // lookup start from zero without deleting any simulator or app data.
        app.launchArguments += ["-focus.rest-cadence.v2", "screenshot-fixture-reset"]
        app.launch()
        let interruptedReward = app.buttons["休憩の提案を閉じる"]
        if interruptedReward.waitForExistence(timeout: 1) {
            interruptedReward.tap()
            XCTAssertTrue(waitForAbsence(interruptedReward, timeout: 5))
        }
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 10))

        // 1. Show the real free 25-minute timer, never the test-only duration.
        app.buttons["メニュー"].tap()
        let productionDuration = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "25分")
        ).firstMatch
        XCTAssertTrue(productionDuration.waitForExistence(timeout: 4))
        productionDuration.tap()
        app.buttons["home.menu.close"].tap()

        let productionLauncher = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "25分集中する")
        ).firstMatch
        XCTAssertTrue(waitForHittable(productionLauncher, timeout: 5))
        productionLauncher.tap()
        let rareRewardChoice = app.descendants(matching: .any)["focus.rare-reward-choice"]
        XCTAssertFalse(rareRewardChoice.waitForExistence(timeout: 1))
        let focusTimer = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "集中タイマー")
        ).firstMatch
        XCTAssertTrue(focusTimer.waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: 4))
        waitForUISettle()
        retainScreenshot(named: "ASC_02_25-minute-focus")

        app.buttons["今日はここまで"].tap()
        let giveUpConfirmation = app.alerts["今日はここまで"]
        XCTAssertTrue(giveUpConfirmation.waitForExistence(timeout: 4))
        giveUpConfirmation.buttons["今日はここまで"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))

        // 2. Create one deterministic 250g completion. The Debug-only duration
        // picker is closed before any image is retained.
        selectDemoDurationForVisualAudit()
        startDemoFocusForVisualAudit()
        let dismissBridge = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(dismissBridge.waitForExistence(timeout: 30))
        XCTAssertTrue(
            app.descendants(matching: .any)["reward.fusion-progress"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.buttons["5分休憩する"].waitForExistence(timeout: 4),
            "The 250g screenshot fixture must match a first 25-minute completion"
        )
        waitForUISettle()
        retainScreenshot(named: "ASC_03_completion-reward")
        dismissBridge.tap()
        XCTAssertTrue(waitForAbsence(dismissBridge, timeout: 5))

        // Restore the real release duration before showing Home.
        app.buttons["メニュー"].tap()
        XCTAssertTrue(productionDuration.waitForExistence(timeout: 4))
        productionDuration.tap()
        app.buttons["home.menu.close"].tap()
        XCTAssertTrue(waitForHittable(productionLauncher, timeout: 6))
        let jar = app.buttons["瓶"]
        XCTAssertTrue(jar.waitForExistence(timeout: 5))
        XCTAssertTrue(((jar.value as? String) ?? "").contains("1粒"), String(describing: jar.value))
        waitForUISettle()
        retainScreenshot(named: "ASC_01_home-with-first-pebble")

        // 4. Show exact, current accumulation values from the same fixture.
        openMenuAction(containing: "積み上がりを見る")
        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 6))
        XCTAssertTrue(
            app.descendants(matching: .any)["overview.weekly-crystal"]
                .waitForExistence(timeout: 5)
        )
        waitForUISettle()
        retainScreenshot(named: "ASC_04_accumulation-overview")

        app.buttons["overview.close"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))

        // 5. Finish with the shipped privacy/storage explanation. This avoids
        // showing the shortened fixture duration in History and directly
        // documents the selected storage contract promised by the product page.
        openMenuAction(containing: "設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 6))
        let cloudStorage = app.staticTexts["iCloud"]
        let localStorage = app.staticTexts["このiPhoneのみ"]
        XCTAssertTrue(
            scrollUntilVisible(cloudStorage) || scrollUntilVisible(localStorage)
        )
        let selectedStorage: XCUIElement
        if cloudStorage.exists {
            selectedStorage = cloudStorage
            XCTAssertTrue(app.staticTexts[
                "あなたのプライベートデータベースのみ"
            ].exists)
        } else {
            selectedStorage = localStorage
            XCTAssertTrue(app.staticTexts[
                "iCloudへ送信しない端末内の専用領域"
            ].exists)
        }
        XCTAssertFalse(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", "ユーザー内容を削除")
            ).firstMatch.exists,
            "Version 1.0 must not expose the experimental cross-container deletion transaction"
        )
        // Keep the storage row and its privacy explanation together. The
        // visibility helper already positions this section; another upward
        // drag can hide the iCloud/local-only label below the navigation bar.
        XCTAssertTrue(selectedStorage.waitForExistence(timeout: 3))
        waitForUISettle()
        retainScreenshot(named: "ASC_05_iCloud-and-privacy")
    }

    /// Retains visual evidence around the first exact decimal carry. The
    /// screenshots make the pre-fusion rail, completed Reward Bridge, fusion
    /// celebration, and newly born lifetime core reviewable together.
    func testVisualEvolutionFromNineMeasuredParticlesThroughFirstCrystal() {
        selectDemoDurationForVisualAudit()

        let presentationProbe = app.descendants(matching: .any)["jar.presentation.probe"]
        XCTAssertTrue(presentationProbe.waitForExistence(timeout: 5))

        for expectedCount in 1 ... 8 {
            completeDemoFocusAndDismissBridgeForVisualAudit(
                expectedPresentationCount: expectedCount,
                presentationProbe: presentationProbe
            )
        }

        startDemoFocusForVisualAudit()
        let dismissBridge = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(dismissBridge.waitForExistence(timeout: 28))
        XCTAssertTrue(
            waitForPresentationCount(9, from: presentationProbe, timeout: 5),
            "Ninth completion must materialize nine live particles; probe=\(presentationValue(from: presentationProbe))"
        )
        let ninthProgress = app.descendants(matching: .any)["reward.fusion-progress"]
        XCTAssertTrue(ninthProgress.waitForExistence(timeout: 4))
        XCTAssertTrue(ninthProgress.label.contains("×10へ 9/10"), ninthProgress.label)
        waitForUISettle()
        retainScreenshot(named: "Ninth Reward Bridge — nine exact orbit sources")

        dismissBridge.tap()
        XCTAssertTrue(
            waitForAbsence(dismissBridge, timeout: 5),
            "The ninth Reward Bridge must leave the accessibility tree before another focus starts"
        )
        XCTAssertTrue(
            waitForHittable(demoLauncherForVisualAudit, timeout: 6),
            "The demo launcher must be operable after the ninth Reward Bridge closes"
        )
        let nineJarValue = (app.buttons["瓶"].value as? String) ?? ""
        XCTAssertTrue(nineJarValue.contains("9粒"), nineJarValue)
        XCTAssertFalse(nineJarValue.contains("まとまり粒"), nineJarValue)
        waitForUISettle()
        retainScreenshot(named: "Nine measured particles — pre-fusion Home rail")

        startDemoFocusForVisualAudit()
        XCTAssertTrue(dismissBridge.waitForExistence(timeout: 28))
        let tenthProgress = app.descendants(matching: .any)["reward.fusion-progress"]
        XCTAssertTrue(tenthProgress.waitForExistence(timeout: 4))
        XCTAssertTrue(tenthProgress.label.contains("×10完成 10/10"), tenthProgress.label)
        waitForUISettle()
        retainScreenshot(named: "Tenth Reward Bridge — exact completed orbit")

        dismissBridge.tap()
        let celebration = app.staticTexts["10粒を、ひとつに整理した"]
        XCTAssertTrue(celebration.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2.5kg"].waitForExistence(timeout: 4))
        waitForUISettle()
        retainScreenshot(named: "First decimal fusion — lossless celebration")

        let closeCelebration = app.buttons["fusion.celebration.close"]
        XCTAssertTrue(closeCelebration.waitForExistence(timeout: 4))
        closeCelebration.tap()
        XCTAssertTrue(waitForHittable(demoLauncherForVisualAudit, timeout: 8))
        let tenJarValue = (app.buttons["瓶"].value as? String) ?? ""
        XCTAssertTrue(tenJarValue.contains("まとまり粒1個"), tenJarValue)
        XCTAssertTrue(tenJarValue.contains("合計10粒分"), tenJarValue)
        waitForUISettle()
        retainScreenshot(named: "First decimal crystal — Home lifetime core")
    }

    /// Opens the bounded forty-year fixture directly at the lifetime camera so
    /// the representative star field and its exact mass can be inspected
    /// without mutating any simulator's ordinary user store.
    func testFortyYearLifetimeConstellationVisualSnapshot() {
        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["TSUMIBEN_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_MODE"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_FORTY_YEAR_OVERVIEW"] = "1"
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()

        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["fixture.40y.timeline-ready"].waitForExistence(timeout: 10))
        let lenses = app.segmentedControls["overview.lens"]
        XCTAssertTrue(lenses.waitForExistence(timeout: 4))
        if !lenses.buttons["結晶"].isSelected {
            lenses.buttons["結晶"].tap()
        }

        let constellation = app.descendants(matching: .any)["overview.lifetime-constellation"]
        XCTAssertTrue(scrollUntilVisible(constellation))
        let core = app.descendants(matching: .any)["overview.constellation.core"]
        XCTAssertTrue(scrollUntilVisible(core))
        XCTAssertEqual(core.label, "時間の核")
        let coreValue = (core.value as? String) ?? ""
        XCTAssertTrue(
            coreValue.replacingOccurrences(of: ",", with: "").contains("350640粒"),
            coreValue
        )
        XCTAssertTrue(coreValue.contains("87.66t"), coreValue)
        waitForUISettle()
        retainScreenshot(named: "Forty-year lifetime constellation — exact 87.66t")
    }

    /// Guards the geometry-based core caption at the largest supported text
    /// category. The representative orbit keeps the same eight-node meaning;
    /// only the surrounding overview becomes vertically expansive.
    func testFortyYearLifetimeConstellationAtAccessibility5() {
        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["TSUMIBEN_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_MODE"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_FORTY_YEAR_OVERVIEW"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_AX5"] = "1"
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()

        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["fixture.40y.timeline-ready"].waitForExistence(timeout: 10))
        let lensMenu = app.buttons["overview.lens"]
        XCTAssertTrue(scrollUntilVisible(lensMenu))
        lensMenu.tap()
        let crystal = app.buttons.matching(
            NSPredicate(
                format: "label == %@ AND identifier != %@",
                "結晶",
                "overview.lens"
            )
        ).firstMatch
        XCTAssertTrue(crystal.waitForExistence(timeout: 4))
        crystal.tap()

        let core = app.descendants(matching: .any)["overview.constellation.core"]
        XCTAssertTrue(scrollUntilVisible(core))
        XCTAssertEqual(core.label, "時間の核")
        let coreValue = (core.value as? String) ?? ""
        XCTAssertTrue(
            coreValue.replacingOccurrences(of: ",", with: "").contains("350640粒"),
            coreValue
        )
        XCTAssertTrue(coreValue.contains("87.66t"), coreValue)
        waitForUISettle()
        retainScreenshot(named: "Forty-year lifetime constellation — AX5 geometry")
    }

    private func exerciseInterruptibleFocus(
        durationButtonPrefix: String,
        launcherFragment: String,
        expectedRemainingMinute: String,
        attachmentName: String
    ) throws {
        app.buttons["メニュー"].tap()
        let duration = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", durationButtonPrefix)
        ).firstMatch
        XCTAssertTrue(duration.waitForExistence(timeout: 4))
        XCTAssertTrue(scrollUntilHittable(duration))
        duration.tap()
        app.buttons["home.menu.close"].tap()

        let launcher = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", launcherFragment)
        ).firstMatch
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertTrue(launcher.isHittable)
        launcher.tap()

        let pause = app.buttons["一時停止"]
        XCTAssertTrue(pause.waitForExistence(timeout: 8))
        let timer = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "集中タイマー")
        ).firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 4))
        XCTAssertTrue(
            ((timer.value as? String) ?? "").contains(expectedRemainingMinute),
            "Timer must expose the selected real duration: \(String(describing: timer.value))"
        )

        pause.tap()
        let resume = app.buttons["再開する"]
        XCTAssertTrue(resume.waitForExistence(timeout: 4))
        let pausedTimer = app.descendants(matching: .any).matching(
            NSPredicate(format: "value CONTAINS %@", "一時停止中")
        ).firstMatch
        XCTAssertTrue(pausedTimer.waitForExistence(timeout: 4))
        XCTAssertEqual(
            pausedTimer.label,
            "集中タイマー",
            "Pausing must preserve whether this is the focus or break timer"
        )
        XCTAssertTrue(
            waitForValue(of: pausedTimer, containing: "一時停止中"),
            "The timer value must announce its paused state"
        )
        XCTAssertTrue(app.staticTexts["一時停止"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "PAUSED")
            ).firstMatch.exists,
            "The Japanese Focus UI must not mix in an English paused state"
        )
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "label == %@", "今日はここまで")
            ).count,
            1,
            "Focus must expose one unambiguous give-up action"
        )

        // Wait past the full-screen presentation and numeric countdown
        // transitions so the retained evidence represents the steady state a
        // person sees, rather than one interpolated compositor frame.
        waitForUISettle()
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = attachmentName
        attachment.lifetime = .keepAlways
        add(attachment)

        resume.tap()
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: 4))
        let textGiveUp = app.buttons["今日はここまで"]
        XCTAssertTrue(textGiveUp.waitForExistence(timeout: 3))
        textGiveUp.tap()

        let confirmation = app.alerts["今日はここまで"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 4))
        XCTAssertTrue(confirmation.buttons["続ける"].exists)
        XCTAssertTrue(
            confirmation.staticTexts["この回の粒は積まれません。これまでの瓶はそのままです。"].exists
        )
        confirmation.buttons["今日はここまで"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))
    }

    private var demoLauncherForVisualAudit: XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "12秒集中する")
        ).firstMatch
    }

    private func selectDemoDurationForVisualAudit() {
        app.buttons["メニュー"].tap()
        let demo = app.buttons["12秒、DEMO"]
        XCTAssertTrue(demo.waitForExistence(timeout: 4))
        demo.tap()
        app.buttons["home.menu.close"].tap()
        XCTAssertTrue(waitForHittable(demoLauncherForVisualAudit, timeout: 5))
    }

    private func startDemoFocusForVisualAudit() {
        let dismissBridge = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(
            waitForAbsence(dismissBridge, timeout: 5),
            "A previous Reward Bridge must be fully absent before starting another focus"
        )
        XCTAssertTrue(
            waitForHittable(demoLauncherForVisualAudit, timeout: 6),
            "The demo launcher must be visible and operable before it is tapped"
        )
        demoLauncherForVisualAudit.tap()

        // A deliberately unselected migrated fixture may require the same
        // informed, equal-weight choice as production before its first timer.
        let choicePanel = app.descendants(matching: .any)["focus.rare-reward-choice"]
        if choicePanel.waitForExistence(timeout: 1) {
            app.buttons["rare-reward.choice.off"].tap()
            let confirm = app.buttons["focus.rare-reward-choice.confirm"]
            XCTAssertTrue(confirm.isEnabled)
            confirm.tap()
        }

        let focusTimer = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "集中タイマー")
        ).firstMatch
        XCTAssertTrue(
            focusTimer.waitForExistence(timeout: 6),
            "The launcher tap must establish a new Focus screen, not hit a transitioning Home element"
        )
        XCTAssertTrue(app.buttons["一時停止"].waitForExistence(timeout: 4))
        XCTAssertTrue(
            waitForAbsence(dismissBridge, timeout: 2),
            "The previous Reward Bridge must remain absent while the new timer is running"
        )
    }

    private func completeDemoFocusAndDismissBridgeForVisualAudit(
        expectedPresentationCount: Int,
        presentationProbe: XCUIElement
    ) {
        startDemoFocusForVisualAudit()
        let dismiss = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 28))
        XCTAssertTrue(
            waitForPresentationCount(
                expectedPresentationCount,
                from: presentationProbe,
                timeout: 5
            ),
            "Completion \(expectedPresentationCount) must add exactly one live particle; probe=\(presentationValue(from: presentationProbe))"
        )
        dismiss.tap()
        XCTAssertTrue(
            waitForAbsence(dismiss, timeout: 5),
            "Reward Bridge \(expectedPresentationCount) must disappear before the next iteration"
        )
        XCTAssertTrue(
            waitForHittable(demoLauncherForVisualAudit, timeout: 6),
            "The launcher must become operable after Reward Bridge \(expectedPresentationCount) closes"
        )
    }

    private func retainScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openMenuAction(containing title: String) {
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
        app.buttons["メニュー"].tap()
        let action = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", title)
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(action), "Missing menu action: \(title)")
        action.tap()
    }

    private func button(containing text: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", text)
        ).firstMatch
    }

    private func presentationValue(from probe: XCUIElement) -> String {
        (probe.value as? String) ?? probe.label
    }

    private func waitForPresentationCount(
        _ expectedCount: Int,
        from probe: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if presentationCount(from: probe) == expectedCount { return true }
            usleep(50_000)
        } while Date() < deadline
        return presentationCount(from: probe) == expectedCount
    }

    private func presentationCount(from probe: XCUIElement) -> Int? {
        let rawValue = presentationValue(from: probe)
        for field in rawValue.split(separator: ";") {
            let pieces = field.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            if pieces.count == 2, pieces[0] == "count" {
                return Int(pieces[1])
            }
        }
        return nil
    }

    private func replaceText(in field: XCUIElement, with replacement: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        field.typeText(replacement)
    }

    private func dismissKeyboard(from field: XCUIElement) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        field.typeText(XCUIKeyboardKey.return.rawValue)
        XCTAssertTrue(
            waitForAbsence(keyboard, timeout: 3),
            "The subject-name keyboard must dismiss before operating the visibility switch"
        )
    }

    private func tapSwitch(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    private func waitForSwitch(
        _ element: XCUIElement,
        value: String,
        timeout: TimeInterval = 3
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.value as? String == value { return true }
            usleep(50_000)
        } while Date() < deadline
        return element.value as? String == value
    }

    private func waitForValue(
        of element: XCUIElement,
        containing fragment: String,
        timeout: TimeInterval = 3
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if ((element.value as? String) ?? "").contains(fragment) { return true }
            usleep(50_000)
        } while Date() < deadline
        return ((element.value as? String) ?? "").contains(fragment)
    }

    private func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, element.isHittable { return true }
            usleep(50_000)
        } while Date() < deadline
        return element.exists && element.isHittable
    }

    private func waitForAbsence(
        _ element: XCUIElement,
        timeout: TimeInterval = 4
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !element.exists { return true }
            usleep(50_000)
        } while Date() < deadline
        return !element.exists
    }

    private func waitForUISettle(_ seconds: useconds_t = 800_000) {
        usleep(seconds)
    }

    private func scrollUntilVisible(
        _ element: XCUIElement,
        attempts: Int = 14
    ) -> Bool {
        for _ in 0 ..< attempts {
            if element.exists,
               !element.frame.isEmpty,
               app.windows.firstMatch.frame.insetBy(dx: 0, dy: 44).intersects(element.frame) {
                return true
            }
            app.swipeUp()
        }
        return element.exists
            && !element.frame.isEmpty
            && app.windows.firstMatch.frame.insetBy(dx: 0, dy: 44).intersects(element.frame)
    }

    private func cancelPresentedFocusIfNeeded() {
        let giveUp = app.buttons["今日はここまで"].firstMatch
        guard giveUp.exists, giveUp.isHittable else { return }
        giveUp.tap()
        let confirmation = app.alerts["今日はここまで"]
        if confirmation.waitForExistence(timeout: 2) {
            confirmation.buttons["今日はここまで"].tap()
        }
    }

    private func tapNavigationBack(from title: String) {
        let navigationBar = app.navigationBars[title]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 4))
        let back = navigationBar.buttons.element(boundBy: 0)
        XCTAssertTrue(back.exists)
        back.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
    }

    @discardableResult
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
