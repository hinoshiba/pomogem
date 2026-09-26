import XCTest

/// Exercises the reversible edges of every primary Home destination. This is
/// deliberately one stateful journey: a real user does not relaunch between
/// adding effort, recording an achievement, reviewing it, sharing it and
/// checking settings.
@MainActor
final class CriticalFlowAdversarialUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // This intentionally traverses every primary destination in one
        // stateful journey. Keep XCTest's default per-test watchdog from
        // mistaking the comprehensive audit for a hung application.
        executionTimeAllowance = 180
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))
    }

    func testPrimaryJourneyRemainsReversibleAndKeepsItsMeaning() throws {
        openMenuAction(containing: "時間を手動で積む")
        let thirtyMinutes = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "30分")
        ).firstMatch
        XCTAssertTrue(thirtyMinutes.waitForExistence(timeout: 4))
        let remaining = app.staticTexts["manual.remaining-count"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 4))
        // The manual-entry allowance belongs to this device in every storage
        // mode; the copy must not imply a shared iCloud-wide allowance.
        let initialRemainingLabel = "この端末で本日あと3回"
        XCTAssertEqual(remaining.label, initialRemainingLabel)
        thirtyMinutes.tap()
        let manualConfirm = app.buttons["manual.confirm"]
        XCTAssertTrue(
            manualConfirm.waitForExistence(timeout: 4),
            "Choosing a duration must open an explicit confirmation instead of saving"
        )
        XCTAssertEqual(
            remaining.label,
            initialRemainingLabel,
            "Previewing a duration must not consume the daily allowance"
        )
        let postSaveCount = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "保存後", "この端末で本日あと2回")
        ).firstMatch
        XCTAssertTrue(
            postSaveCount.waitForExistence(timeout: 4),
            "Confirmation must disclose the remaining allowance after saving"
        )
        XCTAssertTrue(scrollUntilHittable(manualConfirm, swiping: .up))
        manualConfirm.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 4))
        XCTAssertTrue(
            app.buttons["瓶"].waitForExistence(timeout: 4),
            "A saved self-reported session must become a visible pebble"
        )

        openMenuAction(containing: "成果を積む")
        XCTAssertTrue(app.navigationBars["成果を選ぶ"].waitForExistence(timeout: 4))
        let examPass = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "試験合格")
        ).firstMatch
        XCTAssertTrue(examPass.waitForExistence(timeout: 4))
        examPass.tap()
        XCTAssertTrue(app.navigationBars["記念石にする"].waitForExistence(timeout: 4))
        app.textFields.firstMatch.tap()
        app.textFields.firstMatch.typeText("資格合格QA")
        app.buttons["この成果を積む"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 4))

        openMenuAction(containing: "積み上がりを見る")
        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["成果の星"].waitForExistence(timeout: 4))
        app.buttons["overview.close"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 4))

        openMenuAction(containing: "記録を見る")
        XCTAssertTrue(app.navigationBars["記録"].waitForExistence(timeout: 5))
        let achievementRow = app.buttons["achievement.history.row"].firstMatch
        XCTAssertTrue(
            scrollUntilHittable(achievementRow, swiping: .up),
            "The achievement must be discoverable near the top of Log"
        )
        XCTAssertTrue(
            achievementRow.label.contains("資格合格QA"),
            "The Log row must preserve the recorded achievement meaning; label=\(achievementRow.label)"
        )
        tapNavigationBack(from: "記録")

        openMenuAction(containing: "動く瓶をシェア")
        XCTAssertTrue(app.navigationBars["カードにする"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.descendants(matching: .any)["share.primary-action"].exists)
        app.navigationBars["カードにする"].buttons["閉じる"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 4))

        openMenuAction(containing: "設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))
        let keepAwake = app.switches["settings.keep-screen-awake"]
        XCTAssertTrue(scrollUntilHittable(keepAwake, swiping: .up))
        let originalKeepAwake = keepAwake.value as? String
        tapSwitchControl(keepAwake)
        tapSwitchControl(keepAwake)
        XCTAssertEqual(
            keepAwake.value as? String,
            originalKeepAwake,
            "A reversible settings audit must leave the preference unchanged"
        )

        let customTimer = app.buttons["settings.custom-timer"]
        XCTAssertTrue(scrollUntilHittable(customTimer, swiping: .up))
        customTimer.tap()
        XCTAssertTrue(app.staticTexts["ポモジェムPro"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["閉じる"].exists, "Paywall must always expose an exit")
        app.buttons["閉じる"].tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 4))
        tapNavigationBack(from: "設定")

        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 4))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Adversarial primary journey returned Home"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testKeepAwakeOptionChangesAndRestores() {
        openMenuAction(containing: "設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))

        let keepAwake = app.switches["settings.keep-screen-awake"]
        XCTAssertTrue(scrollUntilHittable(keepAwake, swiping: .up))
        let original = keepAwake.value as? String

        tapSwitchControl(keepAwake)
        let didChange = waitForValue(of: keepAwake, toDifferFrom: original)
        XCTAssertTrue(
            didChange,
            "One tap must visibly change the keep-awake setting; alert=\(alertDiagnostic())"
        )

        tapSwitchControl(keepAwake)
        XCTAssertTrue(
            waitForValue(of: keepAwake, toEqual: original),
            "A second tap must restore the original setting"
        )

        let twentyFiveMinutes = app.buttons["settings.focus-preset.25"]
        XCTAssertTrue(scrollUntilHittable(twentyFiveMinutes, swiping: .up))
        let fortyFiveMinutes = app.buttons["settings.focus-preset.45"]
        XCTAssertTrue(scrollUntilHittable(fortyFiveMinutes, swiping: .up))
        fortyFiveMinutes.tap()
        XCTAssertTrue(waitForValue(of: fortyFiveMinutes, toEqual: "選択中"))
        XCTAssertEqual(twentyFiveMinutes.value as? String, "未選択")
        XCTAssertTrue(twentyFiveMinutes.isHittable)
        twentyFiveMinutes.tap()
        XCTAssertTrue(waitForValue(of: twentyFiveMinutes, toEqual: "選択中"))
        XCTAssertEqual(fortyFiveMinutes.value as? String, "未選択")

        let customTimer = app.buttons["settings.custom-timer"]
        // Keep the first preset row visible while bringing the complete
        // custom option into the screenshot below it.
        for _ in 0..<8 {
            if customTimer.exists, customTimer.isHittable,
               customTimer.frame.maxY <= app.frame.maxY - 24 { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
                .press(forDuration: 0.05, thenDragTo:
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)))
        }
        XCTAssertTrue(customTimer.exists && customTimer.isHittable)
        XCTAssertEqual(customTimer.value as? String, "未選択")
        let navigationBottom = app.navigationBars["設定"].frame.maxY
        for minutes in [25, 45, 60, 90] {
            let preset = app.buttons["settings.focus-preset.\(minutes)"]
            XCTAssertTrue(preset.isHittable)
            XCTAssertGreaterThanOrEqual(preset.frame.minY, navigationBottom)
            XCTAssertEqual(preset.label, "\(minutes)分")
            XCTAssertEqual(preset.value as? String, minutes == 25 ? "選択中" : "未選択")
        }
        XCTAssertGreaterThanOrEqual(customTimer.frame.minY,
                                    app.buttons["settings.focus-preset.90"].frame.maxY)
        XCTAssertLessThanOrEqual(customTimer.frame.maxY, app.frame.maxY)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Settings free duration tiles and Pro custom option"
        attachment.lifetime = .keepAlways
        add(attachment)

        tapNavigationBack(from: "設定")
        let homeDuration = app.buttons["home.duration-picker"]
        XCTAssertTrue(homeDuration.waitForExistence(timeout: 5))
        XCTAssertTrue(homeDuration.label.contains("25分"))
        XCTAssertFalse(homeDuration.label.contains("秒"))
    }

    func testTimerCompletionChoicesExposeCancellableThreeSecondPreview() {
        openMenuAction(containing: "設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))

        let soundPicker = app.descendants(matching: .any)[
            "settings.completion-sound"
        ]
        XCTAssertTrue(scrollUntilHittable(soundPicker, swiping: .up))
        XCTAssertTrue(soundPicker.isEnabled)

        let hapticPicker = app.descendants(matching: .any)[
            "settings.completion-haptic"
        ]
        XCTAssertTrue(scrollUntilHittable(hapticPicker, swiping: .up))
        XCTAssertTrue(hapticPicker.isEnabled)

        let preview = app.buttons["settings.completion-preview"]
        XCTAssertTrue(scrollUntilHittable(preview, swiping: .up))
        XCTAssertEqual(preview.value as? String, "待機中")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Timer completion sound and haptic settings"
        attachment.lifetime = .keepAlways
        add(attachment)
        preview.tap()
        XCTAssertTrue(waitForValue(of: preview, timeout: 1.5) {
            $0?.hasPrefix("あと") == true
        })
        XCTAssertEqual(preview.label, "プレビューをキャンセル")

        preview.tap()
        XCTAssertTrue(waitForValue(of: preview, toEqual: "待機中"))
        XCTAssertEqual(preview.label, "3秒後に試す")
    }

    func testRareRewardParticipationControlsAreAbsentForRelease() {
        openMenuAction(containing: "設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))

        let picker = app.descendants(matching: .any)["settings.rare-reward-mode"]
        XCTAssertFalse(picker.waitForExistence(timeout: 1))
        XCTAssertFalse(app.staticTexts["粒のバリエーション"].exists)
        XCTAssertFalse(app.navigationBars["ランダムなレア粒"].exists)
    }

    func testAchievementCanBeEditedDeletedAndUndoneFromLog() {
        openMenuAction(containing: "成果を積む")
        XCTAssertTrue(app.navigationBars["成果を選ぶ"].waitForExistence(timeout: 4))
        let examPass = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "試験合格")
        ).firstMatch
        XCTAssertTrue(examPass.waitForExistence(timeout: 4))
        examPass.tap()
        XCTAssertTrue(app.navigationBars["記念石にする"].waitForExistence(timeout: 4))
        app.textFields.firstMatch.tap()
        app.textFields.firstMatch.typeText("編集前")
        app.buttons["この成果を積む"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 4))

        openMenuAction(containing: "記録を見る")
        XCTAssertTrue(app.navigationBars["記録"].waitForExistence(timeout: 5))
        let row = app.buttons["achievement.history.row"].firstMatch
        XCTAssertTrue(scrollUntilHittable(row, swiping: .up))
        waitForUISettle()
        row.tap()

        XCTAssertTrue(app.navigationBars["成果を編集"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["achievement.editor.kind"].exists)
        XCTAssertTrue(app.buttons["achievement.editor.subject"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["achievement.editor.date"].exists)
        let note = app.textFields["achievement.editor.note"]
        XCTAssertTrue(note.exists)
        note.tap()
        note.typeText("更新")
        // 「変更を保存」 stays above the keyboard without scrolling, even on
        // an iPhone SE, where the keyboard used to cover it.
        let save = app.buttons["achievement.editor.save"]
        XCTAssertTrue(save.isHittable, "The keyboard must not cover 変更を保存")
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            XCTAssertLessThanOrEqual(save.frame.maxY, keyboard.frame.minY + 0.5)
        }
        XCTAssertTrue(note.isHittable, "The memo being typed stays in view")
        let typing = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        typing.name = "成果を編集 — the memo being typed, with 変更を保存 above the keyboard"
        typing.lifetime = .keepAlways
        add(typing)

        app.buttons["achievement.editor.kind"].tap()
        let perfectScore = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "100点")
        ).firstMatch
        XCTAssertTrue(perfectScore.waitForExistence(timeout: 4))
        perfectScore.tap()
        XCTAssertTrue(scrollUntilHittable(save, swiping: .up))
        save.tap()

        XCTAssertTrue(app.navigationBars["記録"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["編集前更新"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "100点")
        ).firstMatch.exists)

        let revisedRow = app.buttons["achievement.history.row"].firstMatch
        XCTAssertTrue(scrollUntilHittable(revisedRow, swiping: .up))
        waitForUISettle()
        revisedRow.tap()
        XCTAssertTrue(app.navigationBars["成果を編集"].waitForExistence(timeout: 4))
        let delete = app.buttons["achievement.editor.delete"]
        XCTAssertTrue(scrollUntilHittable(delete, swiping: .up))
        delete.tap()
        XCTAssertTrue(app.alerts["この記念石を削除しますか？"].waitForExistence(timeout: 4))
        app.buttons["achievement.editor.confirm-delete"].firstMatch.tap()

        XCTAssertTrue(app.navigationBars["記録"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["編集前更新"].exists)
        let undo = app.buttons["achievement.undo-delete"]
        XCTAssertTrue(scrollUntilHittable(undo, swiping: .down))
        XCTAssertGreaterThanOrEqual(undo.frame.height, 43.5)
        undo.tap()
        XCTAssertTrue(app.staticTexts["編集前更新"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["achievement.undo-delete"].exists)
    }

    /// At the largest text size the pinned 「変更を保存」 still stays above the
    /// keyboard, and the memo being typed stays in view above it.
    func testMilestoneEditorKeepsSaveAboveTheKeyboardAtAccessibility5() {
        app.terminate()
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))
        openMenuAction(containing: "成果を積む")
        XCTAssertTrue(app.navigationBars["成果を選ぶ"].waitForExistence(timeout: 4))
        let examPass = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "試験合格")
        ).firstMatch
        XCTAssertTrue(examPass.waitForExistence(timeout: 4))
        XCTAssertTrue(scrollUntilHittable(examPass, swiping: .up))
        examPass.tap()
        XCTAssertTrue(app.navigationBars["記念石にする"].waitForExistence(timeout: 4))
        let addSave = app.buttons["achievement.create.save"]
        XCTAssertTrue(addSave.waitForExistence(timeout: 4))
        addSave.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 4))

        openMenuAction(containing: "記録を見る")
        XCTAssertTrue(app.navigationBars["記録"].waitForExistence(timeout: 5))
        let row = app.buttons["achievement.history.row"].firstMatch
        XCTAssertTrue(scrollUntilHittable(row, swiping: .up))
        waitForUISettle()
        row.tap()
        let editor = app.navigationBars["成果を編集"]
        XCTAssertTrue(editor.waitForExistence(timeout: 4))
        let note = app.textFields["achievement.editor.note"]
        let save = app.buttons["achievement.editor.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 4))
        // At this size the memo starts below the fold, and a full swipe
        // carries it past the navigation bar. Drag a little at a time until
        // it sits between the bar at the top and the pinned 変更を保存.
        func noteIsClear() -> Bool {
            note.exists
                && note.frame.minY >= editor.frame.maxY
                && note.frame.maxY <= save.frame.minY
        }
        for _ in 0 ..< 12 where !noteIsClear() {
            let start = app.scrollViews.firstMatch.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            )
            let distance: CGFloat = note.frame.minY < editor.frame.maxY ? 100 : -100
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
            waitForUISettle(0.3)
        }
        XCTAssertTrue(noteIsClear(), "The memo must be reachable at the largest text size")
        note.tap()
        note.typeText("二次")
        waitForUISettle()

        XCTAssertTrue(save.isHittable, "The keyboard must not cover 変更を保存")
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            XCTAssertLessThanOrEqual(save.frame.maxY, keyboard.frame.minY + 0.5)
        }
        XCTAssertTrue(note.isHittable, "The memo being typed stays in view")
        XCTAssertLessThanOrEqual(note.frame.maxY, save.frame.minY + 0.5, "The memo sits above the pinned bar")
        let typing = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        typing.name = "成果を編集 at AX5 — the memo being typed, with 変更を保存 above the keyboard"
        typing.lifetime = .keepAlways
        add(typing)

        save.tap()
        XCTAssertTrue(app.navigationBars["記録"].waitForExistence(timeout: 4))
    }

    /// 記録 says which days 「今週」 covers and what is inside its total, a day
    /// in the chart opens every record of that day, and older history is
    /// one step away instead of ending at the newest thirty records.
    func testLogSaysWhichWeekItShowsAndReachesOlderHistory() {
        openMenuAction(containing: "時間を手動で積む")
        let thirtyMinutes = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "30分")
        ).firstMatch
        XCTAssertTrue(thirtyMinutes.waitForExistence(timeout: 4))
        thirtyMinutes.tap()
        let manualConfirm = app.buttons["manual.confirm"]
        XCTAssertTrue(manualConfirm.waitForExistence(timeout: 4))
        XCTAssertTrue(scrollUntilHittable(manualConfirm, swiping: .up))
        manualConfirm.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 4))

        // 積み上がり counts measured time only, but a self-reported week is
        // not an empty one.
        openMenuAction(containing: "積み上がりを見る")
        XCTAssertTrue(app.navigationBars["積み上がり"].waitForExistence(timeout: 5))
        let weekly = app.descendants(matching: .any)["overview.weekly-crystal"]
        XCTAssertTrue(weekly.waitForExistence(timeout: 5))
        XCTAssertTrue(weekly.label.contains("自己申告の300g"), weekly.label)
        XCTAssertFalse(app.staticTexts["今週は、まだ透明。"].exists)
        XCTAssertTrue(app.staticTexts["今週は、自己申告で積んでいる。"].exists)
        let weeklyAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        weeklyAttachment.name = "積み上がり — a self-reported week"
        weeklyAttachment.lifetime = .keepAlways
        add(weeklyAttachment)
        app.buttons["overview.close"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 4))

        openMenuAction(containing: "記録を見る")
        XCTAssertTrue(app.navigationBars["記録"].waitForExistence(timeout: 5))
        let period = app.segmentedControls.firstMatch
        XCTAssertTrue(period.buttons["今週"].waitForExistence(timeout: 4))
        XCTAssertTrue(period.buttons["今週"].isSelected)
        XCTAssertTrue(period.buttons["今月"].exists)
        let range = app.descendants(matching: .any)["log.period-range"].firstMatch
        XCTAssertTrue(range.waitForExistence(timeout: 4))
        XCTAssertTrue(range.label.contains("〜"), range.label)
        let selfReported = app.descendants(matching: .any)["log.self-reported-share"].firstMatch
        XCTAssertTrue(selfReported.waitForExistence(timeout: 4))
        XCTAssertTrue(selfReported.label.contains("このうち自己申告 300g"), selfReported.label)
        XCTAssertFalse(
            app.staticTexts["この期間の粒は、まだありません。"].exists,
            "A week with a record must never show the empty-period copy"
        )
        // The device audits find the tiles by identifier, whatever the period.
        let mass = app.descendants(matching: .any)["log.summary.mass"].firstMatch
        XCTAssertTrue(mass.exists)
        XCTAssertTrue(mass.label.contains("300g") && mass.label.contains("今週の質量"), mass.label)
        let weekAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        weekAttachment.name = "記録 — calendar week with its self-reported share"
        weekAttachment.lifetime = .keepAlways
        add(weekAttachment)

        // Back from the background, 記録 reads again but keeps what it shows:
        // never the empty-period copy over a week that has a record.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            app.wait(for: .runningBackground, timeout: 5)
                || app.wait(for: .runningBackgroundSuspended, timeout: 5)
        )
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertFalse(
            app.staticTexts["この期間の粒は、まだありません。"].exists,
            "Returning to 記録 must not show the empty-period copy"
        )
        XCTAssertTrue(selfReported.waitForExistence(timeout: 4))
        XCTAssertTrue(selfReported.label.contains("このうち自己申告 300g"), selfReported.label)
        XCTAssertTrue(period.buttons["今週"].isSelected, "Returning must keep the chosen period")

        // Tap today's column in the chart.
        let chart = app.descendants(matching: .any)["log.mass-chart"]
        XCTAssertTrue(scrollUntilHittable(chart, swiping: .up))
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ja_JP")
        let todayIndex = (calendar.component(.weekday, from: .now) - calendar.firstWeekday + 7) % 7
        let plotLeading: CGFloat = 44
        let plotWidth = chart.frame.width - plotLeading
        chart.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: plotLeading + plotWidth * (CGFloat(todayIndex) + 0.5) / 7,
            dy: chart.frame.height * 0.6
        )).tap()
        let daySummary = app.descendants(matching: .any)["history.day.summary"]
        XCTAssertTrue(daySummary.waitForExistence(timeout: 8), "Tapping today's bar must open the day")
        XCTAssertTrue(daySummary.label.contains("30分"), daySummary.label)
        let dayAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        dayAttachment.name = "記録 — one day from the chart"
        dayAttachment.lifetime = .keepAlways
        add(dayAttachment)
        app.buttons["history.day.close"].tap()
        XCTAssertTrue(app.navigationBars["記録"].waitForExistence(timeout: 4))

        // The twelve monthly jars end with the way to older months.
        let olderMonths = app.buttons["log.past-history.from-months"]
        XCTAssertTrue(scrollUntilHittable(olderMonths, swiping: .up))
        let monthsAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        monthsAttachment.name = "記録 — 月ごとの瓶 leads to older months"
        monthsAttachment.lifetime = .keepAlways
        add(monthsAttachment)
        olderMonths.tap()
        XCTAssertTrue(app.navigationBars["過去の記録"].waitForExistence(timeout: 5))
        app.buttons["log.past-history.close"].tap()
        XCTAssertTrue(app.navigationBars["記録"].waitForExistence(timeout: 4))

        let past = app.buttons["log.past-history"]
        XCTAssertTrue(scrollUntilHittable(past, swiping: .up))
        past.tap()
        XCTAssertTrue(app.navigationBars["過去の記録"].waitForExistence(timeout: 5))
        let yearSummary = app.descendants(matching: .any)["overview.timeline.year.summary"]
        XCTAssertTrue(yearSummary.waitForExistence(timeout: 10))
        let pastAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        pastAttachment.name = "記録 — 過去の記録 by year and month"
        pastAttachment.lifetime = .keepAlways
        add(pastAttachment)
        app.buttons["log.past-history.close"].tap()
        XCTAssertTrue(app.navigationBars["記録"].waitForExistence(timeout: 4))
    }

    /// The same 記録 at the largest text size: the period dates, the
    /// self-reported line and the way to older history stay readable.
    func testLogAtAccessibility5() {
        app.terminate()
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 8))
        openMenuAction(containing: "時間を手動で積む")
        let thirtyMinutes = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "30分")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(thirtyMinutes, swiping: .up))
        thirtyMinutes.tap()
        let manualConfirm = app.buttons["manual.confirm"]
        XCTAssertTrue(manualConfirm.waitForExistence(timeout: 4))
        XCTAssertTrue(scrollUntilHittable(manualConfirm, swiping: .up))
        manualConfirm.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 4))

        openMenuAction(containing: "記録を見る")
        XCTAssertTrue(app.navigationBars["記録"].waitForExistence(timeout: 5))
        let range = app.descendants(matching: .any)["log.period-range"].firstMatch
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        let top = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        top.name = "記録 at AX5 — period and totals"
        top.lifetime = .keepAlways
        add(top)
        let selfReported = app.descendants(matching: .any)["log.self-reported-share"].firstMatch
        XCTAssertTrue(scrollUntilHittable(selfReported, swiping: .up))
        let share = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        share.name = "記録 at AX5 — self-reported line"
        share.lifetime = .keepAlways
        add(share)
        let past = app.buttons["log.past-history"]
        XCTAssertTrue(scrollUntilHittable(past, swiping: .up))
        let bottom = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        bottom.name = "記録 at AX5 — way to older history"
        bottom.lifetime = .keepAlways
        add(bottom)
        past.tap()
        XCTAssertTrue(app.navigationBars["過去の記録"].waitForExistence(timeout: 5))
        let yearSummary = app.descendants(matching: .any)["overview.timeline.year.summary"]
        XCTAssertTrue(yearSummary.waitForExistence(timeout: 10))
        let pastShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        pastShot.name = "過去の記録 at AX5"
        pastShot.lifetime = .keepAlways
        add(pastShot)
    }

    /// Deleting a theme keeps its history. Correcting only the memo of a
    /// milestone recorded under it must not move the milestone to whichever
    /// theme happens to sort first.
    func testEditingAMilestoneKeepsItsDeletedTheme() {
        let themeName = "英検QA"
        openMenuAction(containing: "設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 6))
        let addTheme = app.buttons["テーマを追加"]
        XCTAssertTrue(scrollUntilHittable(addTheme, swiping: .up))
        addTheme.tap()
        XCTAssertTrue(app.navigationBars["テーマを追加"].waitForExistence(timeout: 5))
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 4))
        nameField.tap()
        nameField.typeText(themeName)
        app.navigationBars["テーマを追加"].buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))
        waitForUISettle()
        tapNavigationBack(from: "設定")

        let themeMenu = app.buttons["home.subject-picker"]
        XCTAssertTrue(themeMenu.waitForExistence(timeout: 4))
        themeMenu.tap()
        let themeChoice = app.buttons[themeName]
        XCTAssertTrue(themeChoice.waitForExistence(timeout: 4))
        themeChoice.tap()

        openMenuAction(containing: "成果を積む")
        XCTAssertTrue(app.navigationBars["成果を選ぶ"].waitForExistence(timeout: 4))
        let examPass = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "試験合格")
        ).firstMatch
        XCTAssertTrue(examPass.waitForExistence(timeout: 4))
        examPass.tap()
        XCTAssertTrue(app.navigationBars["記念石にする"].waitForExistence(timeout: 4))
        app.textFields.firstMatch.tap()
        app.textFields.firstMatch.typeText("二次試験")
        app.buttons["この成果を積む"].tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 4))

        openMenuAction(containing: "設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))
        let themeRow = app.buttons[themeName]
        XCTAssertTrue(scrollUntilHittable(themeRow, swiping: .up))
        themeRow.swipeLeft()
        let delete = app.buttons["削除"]
        XCTAssertTrue(delete.waitForExistence(timeout: 4))
        delete.tap()
        let confirm = app.buttons["「\(themeName)」を削除"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertFalse(app.buttons[themeName].waitForExistence(timeout: 2))
        tapNavigationBack(from: "設定")

        openMenuAction(containing: "記録を見る")
        XCTAssertTrue(app.navigationBars["記録"].waitForExistence(timeout: 5))
        let row = app.buttons["achievement.history.row"].firstMatch
        XCTAssertTrue(scrollUntilHittable(row, swiping: .up))
        XCTAssertTrue(row.label.contains(themeName), row.label)
        waitForUISettle()
        row.tap()

        XCTAssertTrue(app.navigationBars["成果を編集"].waitForExistence(timeout: 4))
        let subject = app.buttons["achievement.editor.subject"]
        XCTAssertTrue(subject.waitForExistence(timeout: 4))
        XCTAssertTrue(
            subject.label.contains(themeName),
            "The editor must start on the milestone's own theme; label=\(subject.label)"
        )
        XCTAssertTrue(
            app.staticTexts["achievement.editor.kept-subject"].exists,
            "The editor must say why the deleted theme is still shown"
        )
        let editor = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        editor.name = "Milestone editor keeps a deleted theme"
        editor.lifetime = .keepAlways
        add(editor)

        let note = app.textFields["achievement.editor.note"]
        XCTAssertTrue(note.exists)
        note.tap()
        note.typeText("合格")
        let save = app.buttons["achievement.editor.save"]
        XCTAssertTrue(scrollUntilHittable(save, swiping: .up))
        save.tap()

        XCTAssertTrue(app.navigationBars["記録"].waitForExistence(timeout: 4))
        let revised = app.buttons["achievement.history.row"].firstMatch
        XCTAssertTrue(scrollUntilHittable(revised, swiping: .up))
        XCTAssertTrue(revised.label.contains("二次試験合格"), revised.label)
        XCTAssertTrue(
            revised.label.contains(themeName),
            "Editing only the memo must keep the deleted theme; label=\(revised.label)"
        )
    }

    private func openMenuAction(containing title: String) {
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 4))
        app.buttons["メニュー"].tap()
        let action = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", title)
        ).firstMatch
        // A row cut by the half-height sheet's bottom edge reports hittable,
        // but its visible sliver sits in the home-indicator area. Scroll
        // until the whole row is on screen.
        for _ in 0..<8 where !isFullyVisible(action) {
            app.swipeUp()
        }
        XCTAssertTrue(isFullyVisible(action), "Missing menu action: \(title)")
        action.tap()
    }

    private func isFullyVisible(_ element: XCUIElement) -> Bool {
        element.exists && element.isHittable
            && element.frame.maxY <= app.windows.firstMatch.frame.maxY
    }

    private func alertDiagnostic() -> String {
        let alert = app.alerts.firstMatch
        return alert.exists ? alert.label : "<none>"
    }

    private func tapSwitchControl(_ element: XCUIElement) {
        // SwiftUI exposes the multiline label and trailing switch as one wide
        // accessibility element. Tap the visible control rather than XCTest's
        // computed point, which can land on the noninteractive label.
        element.coordinate(
            withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
        ).tap()
    }

    private func tapNavigationBack(from title: String) {
        let navigationBar = app.navigationBars[title]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 4))
        let back = navigationBar.buttons.element(boundBy: 0)
        XCTAssertTrue(back.exists)
        back.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 4))
    }

    private enum SwipeDirection {
        case up
        case down
    }

    @discardableResult
    private func scrollUntilHittable(
        _ element: XCUIElement,
        swiping direction: SwipeDirection,
        attempts: Int = 8
    ) -> Bool {
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return true }
            switch direction {
            case .up:
                app.swipeUp()
            case .down:
                app.swipeDown()
            }
        }
        return element.exists && element.isHittable
    }

    private func waitForValue(
        of element: XCUIElement,
        toDifferFrom value: String?,
        timeout: TimeInterval = 2
    ) -> Bool {
        waitForValue(of: element, timeout: timeout) { $0 != value }
    }

    private func waitForValue(
        of element: XCUIElement,
        toEqual value: String?,
        timeout: TimeInterval = 2
    ) -> Bool {
        waitForValue(of: element, timeout: timeout) { $0 == value }
    }

    private func waitForValue(
        of element: XCUIElement,
        timeout: TimeInterval,
        matching predicate: @escaping (String?) -> Bool
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { candidate, _ in
                guard let candidate = candidate as? XCUIElement else { return false }
                return predicate(candidate.value as? String)
            },
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForUISettle(_ seconds: TimeInterval = 0.5) {
        let settleExpectation = expectation(description: "UI settles after scrolling")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            settleExpectation.fulfill()
        }
        wait(for: [settleExpectation], timeout: seconds + 1)
    }
}

/// Release 1.0 must ignore legacy/unselected rare-reward preferences and keep
/// every rare-reward choice surface outside the shipping flow.
@MainActor
final class RareRewardOptInUITests: XCTestCase {
    private var activeApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIApplication().terminate()
    }

    override func tearDownWithError() throws {
        activeApp?.terminate()
        activeApp = nil
    }

    func testOnboardingSkipsRareRewardChoiceForRelease() {
        let app = XCUIApplication()
        activeApp = app
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_RARE_REWARD_UNSELECTED"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_RARE_REWARD_ONBOARDING"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launch()

        let next = app.buttons["次へ"]
        XCTAssertTrue(next.waitForExistence(timeout: 8))
        let back = app.buttons["onboarding.back"]
        XCTAssertFalse(back.exists)
        let step = app.descendants(matching: .any)["onboarding.step"]
        XCTAssertTrue(step.label.contains("1ページ"))
        next.tap()

        XCTAssertTrue(back.waitForExistence(timeout: 4))
        XCTAssertTrue(back.isHittable)
        XCTAssertGreaterThanOrEqual(back.frame.height, 44)
        back.tap()
        XCTAssertTrue(next.waitForExistence(timeout: 4))
        XCTAssertFalse(back.exists)
        next.tap()

        let trialDrop = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "ためしに一粒")
        ).firstMatch
        XCTAssertTrue(trialDrop.waitForExistence(timeout: 4))
        XCTAssertTrue(
            waitUntilEnabled(next, timeout: 4),
            "The tutorial drop is an optional preview, not a setup gate"
        )
        next.tap()

        XCTAssertTrue(
            app.staticTexts["最初のテーマを選ぶ"].waitForExistence(timeout: 4)
        )
        XCTAssertFalse(app.buttons["勉強"].exists)
        XCTAssertFalse(app.buttons["仕事"].exists)
        let finish = app.buttons["瓶をひらく"]
        XCTAssertTrue(finish.waitForExistence(timeout: 4))
        XCTAssertFalse(finish.isEnabled)

        let firstSubject = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "英語")
        ).firstMatch
        XCTAssertTrue(firstSubject.waitForExistence(timeout: 4))
        firstSubject.tap()
        let selection = app.descendants(matching: .any)["onboarding.selection-summary"]
        XCTAssertTrue(selection.label.contains("英語"))
        XCTAssertTrue(selection.isHittable)

        back.tap()
        XCTAssertTrue(next.waitForExistence(timeout: 4))
        next.tap()
        XCTAssertTrue(finish.waitForExistence(timeout: 4))
        XCTAssertTrue(
            selection.label.contains("英語"),
            "Going back must preserve the explicitly chosen first theme"
        )

        let panel = app.descendants(matching: .any)["onboarding.rare-reward-choice"]
        XCTAssertFalse(panel.waitForExistence(timeout: 1))

        XCTAssertTrue(finish.isEnabled)
        finish.tap()

        XCTAssertTrue(
            app.buttons["メニュー"].waitForExistence(timeout: 8),
            "Onboarding must finish without exposing a rare-reward choice"
        )
    }

    func testUnselectedLegacyPreferenceDoesNotGateTimerForRelease() {
        let app = XCUIApplication()
        activeApp = app
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_RARE_REWARD_UNSELECTED"] = "1"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launch()

        let launcher = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "25分集中する")
        ).firstMatch
        XCTAssertTrue(launcher.waitForExistence(timeout: 8))
        // The visual Home audit may intentionally keep the hero button close
        // to the bottom safe area. Hit its exposed upper half instead of
        // XCTest's center point, which can overlap the tab-bar container.
        launcher.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18)
        ).tap()

        let choicePanel = app.descendants(matching: .any)["focus.rare-reward-choice"]
        XCTAssertFalse(choicePanel.waitForExistence(timeout: 1))
        XCTAssertTrue(
            app.buttons["一時停止"].waitForExistence(timeout: 7),
            "A legacy unselected preference must not block the shipping timer"
        )
        XCTAssertFalse(choicePanel.exists)

        // Leave process-local recovery clean for whichever UI journey runs
        // next; the in-memory SwiftData store does not own this envelope.
        app.buttons["今日はここまで"].firstMatch.tap()
        let destructiveGiveUp = app.alerts.buttons["今日はここまで"]
        XCTAssertTrue(destructiveGiveUp.waitForExistence(timeout: 3))
        destructiveGiveUp.tap()
    }

    private func waitUntilEnabled(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
