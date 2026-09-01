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
        app.launchEnvironment["TSUMIBEN_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_MODE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
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
        XCTAssertEqual(remaining.label, "本日あと3回")
        thirtyMinutes.tap()
        let manualConfirm = app.buttons["manual.confirm"]
        XCTAssertTrue(
            manualConfirm.waitForExistence(timeout: 4),
            "Choosing a duration must open an explicit confirmation instead of saving"
        )
        XCTAssertEqual(
            remaining.label,
            "本日あと3回",
            "Previewing a duration must not consume the daily allowance"
        )
        let postSaveCount = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "保存後", "本日あと2回")
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
        XCTAssertTrue(app.staticTexts["つみべんPro"].waitForExistence(timeout: 6))
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
    }

    func testRareRewardParticipationCanBeDisabledAndRestored() {
        openMenuAction(containing: "設定")
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))

        let picker = app.descendants(matching: .any)["settings.rare-reward-mode"]
        XCTAssertTrue(scrollUntilHittable(picker, swiping: .up))
        let originalValue = picker.value as? String

        picker.tap()
        let off = app.staticTexts["抽選しない"]
        XCTAssertTrue(off.waitForExistence(timeout: 4))
        off.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 4))
        XCTAssertTrue(
            waitForValue(of: picker, timeout: 2, matching: {
                $0?.contains("抽選しない") == true
            }),
            "The explicit no-draw choice must be visible after selection"
        )

        picker.tap()
        let standard = app.staticTexts["標準"]
        XCTAssertTrue(standard.waitForExistence(timeout: 4))
        standard.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 4))
        XCTAssertTrue(
            waitForValue(of: picker, toEqual: originalValue ?? "標準"),
            "The audit must restore the original participation choice"
        )
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

        app.buttons["achievement.editor.kind"].tap()
        let perfectScore = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "100点")
        ).firstMatch
        XCTAssertTrue(perfectScore.waitForExistence(timeout: 4))
        perfectScore.tap()
        let save = app.buttons["achievement.editor.save"]
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

    private func openMenuAction(containing title: String) {
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 4))
        app.buttons["メニュー"].tap()
        let action = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", title)
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(action, swiping: .up), "Missing menu action: \(title)")
        action.tap()
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

/// A fresh or migrated installation must see an informed, reversible choice
/// before any eligible timer starts. This launch flag is test-only and keeps
/// the otherwise shared UI-test fixture deliberately unselected.
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

    func testOnboardingRequiresAnEqualWeightRareRewardChoice() {
        let app = XCUIApplication()
        activeApp = app
        app.launchEnvironment["TSUMIBEN_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_MODE"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_RARE_REWARD_UNSELECTED"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_RARE_REWARD_ONBOARDING"] = "1"
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()

        let next = app.buttons["次へ"]
        XCTAssertTrue(next.waitForExistence(timeout: 8))
        next.tap()

        let trialDrop = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "ためしに一粒")
        ).firstMatch
        XCTAssertTrue(trialDrop.waitForExistence(timeout: 4))
        trialDrop.tap()
        XCTAssertTrue(waitUntilEnabled(next, timeout: 4))
        next.tap()

        let firstSubject = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "英語")
        ).firstMatch
        XCTAssertTrue(firstSubject.waitForExistence(timeout: 4))
        firstSubject.tap()
        XCTAssertTrue(waitUntilEnabled(next, timeout: 2))
        next.tap()

        let panel = app.descendants(matching: .any)["onboarding.rare-reward-choice"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        for mode in ["off", "quiet", "standard"] {
            let choice = app.buttons["rare-reward.choice.\(mode)"]
            XCTAssertTrue(choice.exists)
            XCTAssertEqual(choice.value as? String, "未選択")
        }

        let finish = app.buttons["瓶をひらく"]
        XCTAssertTrue(finish.exists)
        XCTAssertFalse(finish.isEnabled)
        app.buttons["rare-reward.choice.quiet"].tap()
        XCTAssertTrue(finish.isEnabled)
        finish.tap()

        XCTAssertTrue(
            app.buttons["メニュー"].waitForExistence(timeout: 8),
            "The explicit onboarding choice must be saved before Home opens"
        )
    }

    func testUnselectedUserChoosesBeforeTimerAndCanUseNoDraw() {
        let app = XCUIApplication()
        activeApp = app
        app.launchEnvironment["TSUMIBEN_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_MODE"] = "1"
        app.launchEnvironment["TSUMIBEN_UI_TEST_RARE_REWARD_UNSELECTED"] = "1"
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
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
        XCTAssertTrue(
            choicePanel.waitForExistence(timeout: 5),
            "An unselected user must not enter a running timer"
        )
        XCTAssertTrue(app.buttons["rare-reward.choice.off"].exists)
        XCTAssertTrue(app.buttons["rare-reward.choice.quiet"].exists)
        XCTAssertTrue(app.buttons["rare-reward.choice.standard"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["rare-reward.equal-outcomes"].exists)
        let probabilityDisclosure = app.descendants(matching: .any)[
            "rare-reward.disclosure.percent"
        ]
        XCTAssertTrue(probabilityDisclosure.exists)
        XCTAssertTrue(probabilityDisclosure.label.contains("いつもの粒 91.2%"))

        let confirm = app.buttons["focus.rare-reward-choice.confirm"]
        XCTAssertFalse(confirm.isEnabled)
        app.buttons["rare-reward.choice.off"].tap()
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()

        XCTAssertTrue(
            app.buttons["一時停止"].waitForExistence(timeout: 7),
            "The timer may begin only after the selected mode is saved"
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
