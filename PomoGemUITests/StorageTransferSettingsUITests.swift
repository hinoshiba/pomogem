import XCTest

/// Uses the production choice/confirmation views and a Debug simulator-only
/// operation recorder. These tests never authorize a real storage transfer.
@MainActor
final class StorageTransferSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0, let app {
            attach("Storage transfer UI failure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Storage transfer failure accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app?.terminate()
    }

    func testEnableShowsAvailableCloudAuthorityAndUnavailableReplacementWithoutMutating() {
        launch("local")
        openChoices()
        XCTAssertTrue(reveal(app.buttons["storage-switch.keep-cloud"]))
        XCTAssertTrue(reveal(app.buttons["storage-switch.replace-cloud"]))
        XCTAssertFalse(app.buttons["storage-switch.replace-cloud"].isEnabled)
        let noMerge = text(containing: "2つの保存先のデータは結合しません")
        XCTAssertTrue(reveal(noMerge, upwards: false))
        attach("Enable — cloud authority and unavailable replacement")
        app.navigationBars["iCloudを有効にする"].buttons["キャンセル"].tap()
        assertNoOperation()
    }

    func testKeepingCloudStartsUncheckedAndBackDiscardsAcknowledgment() {
        launch("local")
        openChoices()
        openConfirmation("storage-switch.keep-cloud")
        assertUncheckedConfirmation()
        let checkbox = app.switches["storage-switch.confirm-data-loss"]
        acknowledgeDeletion()
        XCTAssertEqual(checkbox.value as? String, "1")
        XCTAssertTrue(app.buttons["storage-switch.confirm"].isEnabled)
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.navigationBars["iCloudを有効にする"].waitForExistence(timeout: 4))
        openConfirmation("storage-switch.keep-cloud")
        assertUncheckedConfirmation()
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        app.navigationBars["iCloudを有効にする"].buttons["キャンセル"].tap()
        assertNoOperation()
    }

    func testKeepingCloudCallsOnlyConfirmedChoiceOnceAndLocksEntry() {
        launch("local")
        openChoices()
        openConfirmation("storage-switch.keep-cloud")
        assertUncheckedConfirmation()
        XCTAssertTrue(text(containing: "このiPhoneだけにあるPomoGemのデータを削除します").exists)
        acknowledgeDeletion()
        app.buttons["storage-switch.confirm"].doubleTap()
        assertAccepted("enableCloudKeepingCloud")
    }

    func testReplacingCloudIsDisabledWithReasonAndCannotOpenConfirmation() {
        launch("local")
        openChoices()
        let reason = app.staticTexts["storage-switch.replace-cloud-unavailable"]
        XCTAssertTrue(reveal(reason))
        XCTAssertTrue(reason.label.contains("複数端末での同時操作"))
        XCTAssertTrue(reason.label.contains("一時的に利用できません"))
        let replacement = app.buttons["storage-switch.replace-cloud"]
        XCTAssertTrue(reveal(replacement))
        XCTAssertFalse(replacement.isEnabled)
        replacement.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.navigationBars["最後の確認"].exists)
        XCTAssertFalse(app.buttons["storage-switch.confirm"].exists)
        attach("Replace cloud — unavailable with retained-data explanation")
        app.navigationBars["iCloudを有効にする"].buttons["キャンセル"].tap()
        assertNoOperation()
    }

    func testDisablingKeepsCloudAndRequiresExplicitCopyConfirmation() {
        launch("cloud")
        openChoices()
        XCTAssertTrue(text(containing: "iCloud側のデータは残ります").waitForExistence(timeout: 4))
        XCTAssertTrue(reveal(text(containing: "解除後の変更は他の端末へ同期されません")))
        XCTAssertFalse(app.buttons["storage-switch.keep-cloud"].exists)
        XCTAssertFalse(app.buttons["storage-switch.replace-cloud"].exists)
        openConfirmation("storage-switch.disable-keep-copy")
        XCTAssertTrue(text(containing: "このiPhoneにコピーしたデータと、iCloudのデータの両方が残ります").exists)
        XCTAssertFalse(app.switches["storage-switch.confirm-data-loss"].exists)
        let confirm = app.buttons["storage-switch.confirm"]
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertEqual(confirm.label, "コピーしてiCloudを解除")
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        app.navigationBars["iCloudを解除"].buttons["キャンセル"].tap()
        assertNoOperation()
        openChoices()
        openConfirmation("storage-switch.disable-keep-copy")
        attach("Disable — both copies remain")
        app.buttons["storage-switch.confirm"].tap()
        assertAccepted("disableCloudKeepingCopy")
    }

    func testBusyOrUnavailableEntryCannotOpenChoices() {
        // Active/export/delete are distinct callers of the production section's
        // external-work gate. The runtime separately enforces active timers.
        for scenario in ["activeTimer", "exporting", "deleting", "unavailable"] {
            launch(scenario)
            let button = app.buttons["settings.storage-switch"]
            XCTAssertTrue(reveal(button))
            XCTAssertFalse(button.isEnabled, "Scenario: \(scenario)")
            assertNoOperation()
            app.terminate()
        }
    }

    func testAX5EnableChoicesAndConfirmationRemainReachableAndDescribed() throws {
        launch("local", accessibility5: true)
        openChoices()
        let keepCloud = app.buttons["storage-switch.keep-cloud"]
        XCTAssertTrue(reveal(keepCloud))
        assertTouchTarget(keepCloud)
        attach("AX5 enable — retain cloud")
        let replaceCloud = app.buttons["storage-switch.replace-cloud"]
        XCTAssertTrue(reveal(replaceCloud))
        assertTouchTarget(replaceCloud)
        XCTAssertFalse(replaceCloud.isEnabled)
        let reason = app.staticTexts["storage-switch.replace-cloud-unavailable"]
        XCTAssertTrue(reveal(reason, upwards: false))
        XCTAssertTrue(reason.label.contains("複数端末での同時操作"))
        attach("AX5 enable — unavailable replacement reason")
        // The available choice is above the replacement section just checked.
        openConfirmation("storage-switch.keep-cloud", upwards: false)
        XCTAssertTrue(app.navigationBars["最後の確認"].waitForExistence(timeout: 4))
        XCTAssertTrue(reveal(text(containing: "このiPhoneだけにあるPomoGemのデータを削除します")))
        let checkbox = app.switches["storage-switch.confirm-data-loss"]
        XCTAssertTrue(reveal(checkbox))
        assertTouchTarget(checkbox)
        XCTAssertGreaterThan(checkbox.frame.height, 100, "The modal must actually inherit AX5, not silently reset to normal text")
        XCTAssertEqual(checkbox.value as? String, "0")
        acknowledgeDeletion()
        let confirm = app.buttons["storage-switch.confirm"]
        XCTAssertTrue(reveal(confirm))
        assertTouchTarget(confirm)
        XCTAssertTrue(confirm.isEnabled)
        attach("AX5 retain cloud — explicit acknowledgment and action")
        try auditDescriptionsAndTraits()
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        app.navigationBars["iCloudを有効にする"].buttons["キャンセル"].tap()
        assertNoOperation()
    }

    func testAX5DisableExplanationAndActionRemainReachable() throws {
        launch("cloud", accessibility5: true)
        openChoices()
        let retainedCloud = text(containing: "iCloud側のデータは残ります")
        XCTAssertTrue(reveal(retainedCloud))
        attach("AX5 disable — cloud copy remains")
        openConfirmation("storage-switch.disable-keep-copy")
        let retainedBoth = text(containing: "このiPhoneにコピーしたデータと、iCloudのデータの両方が残ります")
        XCTAssertTrue(reveal(retainedBoth))
        let confirm = app.buttons["storage-switch.confirm"]
        XCTAssertTrue(reveal(confirm))
        assertTouchTarget(confirm)
        attach("AX5 disable — verified copy confirmation")
        XCTAssertGreaterThan(confirm.frame.height, 100, "The modal must actually inherit AX5")
        try auditDescriptionsAndTraits()
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        app.navigationBars["iCloudを解除"].buttons["キャンセル"].tap()
        assertNoOperation()
    }

    func testAX5PostMirrorTimeoutOffersOnlineRetryWithoutStartingOfflineOrTransfer() {
        launch("cloudLaunchTimedOut", accessibility5: true)
        XCTAssertTrue(app.staticTexts["iCloudの確認に時間がかかっています"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["オフラインで開くには再起動が必要です"].exists)
        XCTAssertFalse(app.buttons["cloud-offline-continue"].exists)
        XCTAssertFalse(app.buttons["storage-transfer-recover"].exists)
        XCTAssertFalse(app.buttons["iCloudに保存して同期"].exists)
        let explanation = app.staticTexts["cloud-launch-timeout-offline-explanation"]
        XCTAssertTrue(reveal(explanation))
        XCTAssertTrue(explanation.label.contains("この画面からオンラインで確認し直せます"))
        XCTAssertTrue(explanation.label.contains("アプリ自体は削除しないでください"))
        let retry = app.buttons["cloud-offline-online-retry"]
        XCTAssertTrue(reveal(retry, upwards: false))
        XCTAssertEqual(retry.label, "オンラインで再試行")
        assertTouchTarget(retry)
        attach("AX5 post-mirror timeout — online retry and retained-data explanation")
        retry.tap()
        let retried = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "retryCalls=1"),
            object: app.staticTexts["cloud-launch-timeout.fixture-state"])
        XCTAssertEqual(XCTWaiter.wait(for: [retried], timeout: 4), .completed)
        XCTAssertFalse(retry.exists, "Claiming the retry replaces the action with preparation UI")
        XCTAssertFalse(app.buttons["cloud-offline-continue"].exists)
        assertNoOperation()
    }

    func testOfflineShowsPendingPhoneCopyAndCannotOpenStorageSwitch() {
        launch("offline")
        assertCompactOfflineBanner()
        openOfflineDetails()
        let message = app.staticTexts["cloud-offline-details-message"]
        XCTAssertTrue(reveal(message))
        XCTAssertEqual(message.label, "通信を確認できないため、端末のデータで利用を続けています。変更は端末に保存されます。")
        let pending = app.staticTexts["cloud-offline-details-pending"]
        XCTAssertTrue(reveal(pending))
        XCTAssertTrue(pending.label.contains("iCloudへの送信はまだ完了していません"))
        let account = app.staticTexts["cloud-offline-details-account"]
        XCTAssertTrue(reveal(account))
        XCTAssertTrue(account.label.contains("現在のiCloudアカウントと最新のデータは未確認です"))
        XCTAssertTrue(reveal(app.staticTexts["cloud-offline-details-recovery"]))
        closeOfflineDetails()
        XCTAssertTrue(reveal(text(containing: "このiPhoneに保存・iCloud同期は待機中")))
        XCTAssertTrue(reveal(text(containing: "iCloudへはまだ送信されません")))
        XCTAssertTrue(reveal(text(containing: "同じアカウントとデータを確認してから同期を再開します")))
        XCTAssertFalse(app.staticTexts["このiPhoneだけに保存"].exists,
            "Offline access must retain cloud mode, not claim a local-only selection")
        XCTAssertFalse(app.staticTexts["iCloudに接続できます"].exists)
        XCTAssertFalse(app.buttons["iCloudの状態を再確認"].exists,
            "The ordinary connectivity monitor must not replace the offline explanation")
        assertOfflineStorageSwitchDisabled()
        attach("Offline — phone copy retained and cloud sync pending")
        assertNoOperation()
    }

    func testOfflineRetryCallsOnceAndStaysDisabledWhileChecking() {
        launch("offline")
        assertCompactOfflineBanner()
        assertOfflineRetryCallsOnce()
        openOfflineDetails()
        closeOfflineDetails()
        XCTAssertFalse(app.buttons["cloud-offline-retry"].isEnabled,
            "Dismissing details must not forget the in-flight request")
        XCTAssertFalse(app.staticTexts["iCloudに接続できます"].exists)
        assertOfflineStorageSwitchDisabled()
        attach("Offline — one in-flight connection request")
        assertNoOperation()
    }

    func testAX5OfflineBannerAndPendingCopyExplanationRemainReadableAndReachable() throws {
        launch("offline", accessibility5: true)
        assertCompactOfflineBanner()
        attach("AX5 offline — visible banner and retry")

        openOfflineDetails()
        let message = app.staticTexts["cloud-offline-details-message"]
        XCTAssertTrue(reveal(message))
        XCTAssertEqual(message.label, "通信を確認できないため、端末のデータで利用を続けています。変更は端末に保存されます。")
        XCTAssertGreaterThan(message.frame.height, 100,
            "Details must inherit AX5 rather than silently reducing the text size")
        XCTAssertGreaterThan(message.frame.width, app.windows.firstMatch.frame.width * 0.75)
        let account = app.staticTexts["cloud-offline-details-account"]
        XCTAssertTrue(reveal(account))
        XCTAssertTrue(account.label.contains("現在のiCloudアカウントと最新のデータは未確認です"))
        let recovery = app.staticTexts["cloud-offline-details-recovery"]
        XCTAssertTrue(reveal(recovery), "The end of the full explanation must be reachable by scrolling")
        XCTAssertEqual(recovery.label, "同じアカウントとデータを確認できるまで、iCloudとの同期は始まりません。")
        attach("AX5 offline — scrolled details and reachable close action")
        try auditDescriptionsAndTraits()
        closeOfflineDetails()

        let pending = text(containing: "iCloudへはまだ送信されません")
        XCTAssertTrue(reveal(pending))
        XCTAssertGreaterThan(pending.frame.height, 100,
            "The production explanation must actually inherit AX5")
        XCTAssertGreaterThan(pending.frame.width, app.windows.firstMatch.frame.width * 0.65,
            "Explanation should retain a readable line width instead of collapsing into a narrow column")
        attach("AX5 offline — local persistence and deferred upload")
        let changedDataset = text(containing: "別端末でデータが置き換わっている場合")
        XCTAssertTrue(reveal(changedDataset))
        XCTAssertGreaterThan(changedDataset.frame.width, app.windows.firstMatch.frame.width * 0.65)
        assertOfflineStorageSwitchDisabled()
        attach("AX5 offline — retained data and disabled storage switch")
        try auditDescriptionsAndTraits()
        assertNoOperation()
        assertOfflineRetryCallsOnce()
    }

    func testNativeCloudNetworkWaitExplainsAutomaticRetryWithoutManualAdmission() {
        launch("cloudNetworkWaiting")
        assertCompactOfflineBanner(expectsRetry: false)
        openOfflineDetails()
        let message = app.staticTexts["cloud-offline-details-message"]
        XCTAssertTrue(reveal(message))
        XCTAssertEqual(message.label, "通信の回復を待っています。端末への記録は続けられます。")
        let pending = app.staticTexts["cloud-offline-details-pending"]
        XCTAssertTrue(reveal(pending))
        XCTAssertTrue(pending.label.contains("接続状態だけでは送信完了を確認できません"))
        let recovery = app.staticTexts["cloud-offline-details-recovery"]
        XCTAssertTrue(reveal(recovery))
        XCTAssertEqual(recovery.label, "通信の回復後、iCloudの同期はシステムが再試行します。")
        XCTAssertFalse(app.staticTexts["cloud-offline-details-account"].exists)
        XCTAssertFalse(text(containing: "同じアカウントとデータを確認できるまで").exists)
        XCTAssertFalse(text(containing: "「同期を再開」で接続を確認").exists)
        closeOfflineDetails()
        XCTAssertFalse(app.buttons["cloud-offline-retry"].exists)
        assertNoOperation()
    }

    func testOfflineRecoveryDetailsCanCloseWithoutRetiringOrAcceptingAnyTransfer() {
        launch("offlineRecovery")
        assertCompactOfflineBanner(expectsRetry: false)
        let entry = app.buttons["cloud-offline-recovery-details"]
        XCTAssertTrue(entry.isHittable)
        assertTouchTarget(entry)
        entry.tap()
        XCTAssertTrue(app.navigationBars["同期の状態"].waitForExistence(timeout: 4))
        let disclosure = app.staticTexts["cloud-offline-recovery-disclosure"]
        XCTAssertTrue(reveal(disclosure))
        XCTAssertTrue(disclosure.label.contains("データの置き換えや削除には、その後の確認が必要です"))
        closeOfflineDetails()
        let reviewState = app.staticTexts["cloud-offline.recovery-fixture-state"]
        XCTAssertTrue(reveal(reviewState, upwards: false))
        XCTAssertEqual(reviewState.label, "reviewCalls=0")
        assertNoOperation()
        openOfflineDetails()
        let review = app.buttons["cloud-offline-review-recovery"]
        XCTAssertTrue(reveal(review))
        assertTouchTarget(review)
        review.doubleTap()
        let waiting = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: review)
        XCTAssertEqual(XCTWaiter.wait(for: [waiting], timeout: 4), .completed)
        closeOfflineDetails()
        XCTAssertTrue(reveal(reviewState, upwards: false))
        XCTAssertEqual(reviewState.label, "reviewCalls=1")
        assertNoOperation()
    }

    func testAX5OfflineRecoveryDisclosureAndExplicitReviewRemainReachable() throws {
        launch("offlineRecovery", accessibility5: true)
        assertCompactOfflineBanner(expectsRetry: false)
        let entry = app.buttons["cloud-offline-recovery-details"]
        XCTAssertTrue(entry.isHittable)
        assertTouchTarget(entry)
        attach("AX5 offline — retained copy and recovery instructions")
        entry.tap()
        XCTAssertTrue(app.navigationBars["同期の状態"].waitForExistence(timeout: 4))
        let disclosure = app.staticTexts["cloud-offline-recovery-disclosure"]
        XCTAssertTrue(reveal(disclosure))
        XCTAssertGreaterThan(disclosure.frame.height, 100)
        XCTAssertGreaterThan(disclosure.frame.width, app.windows.firstMatch.frame.width * 0.75)
        let review = app.buttons["cloud-offline-review-recovery"]
        XCTAssertTrue(reveal(review))
        assertTouchTarget(review)
        XCTAssertTrue(review.isEnabled)
        attach("AX5 offline — explicit review before any later data-loss consent")
        try auditDescriptionsAndTraits()
        closeOfflineDetails()
        let reviewState = app.staticTexts["cloud-offline.recovery-fixture-state"]
        XCTAssertTrue(reveal(reviewState, upwards: false))
        XCTAssertEqual(reviewState.label, "reviewCalls=0")
        assertNoOperation()
    }

    func testResetHistoryConflictKeepsExportAndSupportChoicesWithoutInventingRefreshConsent() {
        launch("offlineHistory")
        assertCompactOfflineBanner(expectsRetry: false)
        app.buttons["cloud-offline-recovery-details"].tap()
        XCTAssertTrue(app.navigationBars["同期の状態"].waitForExistence(timeout: 4))
        let options = app.staticTexts["cloud-offline-history-options"]
        XCTAssertTrue(reveal(options))
        XCTAssertTrue(options.label.contains("自動で結合・送信できません"))
        XCTAssertTrue(options.label.contains("設定の「データを書き出す」"))
        XCTAssertFalse(app.buttons["cloud-offline-review-recovery"].exists)
        XCTAssertFalse(app.buttons["storage-refresh-confirm"].exists)
        attach("Reset-history difference — keep local copy and export/support options")
        closeOfflineDetails()
        let reviewState = app.staticTexts["cloud-offline.recovery-fixture-state"]
        XCTAssertTrue(reveal(reviewState, upwards: false))
        XCTAssertEqual(reviewState.label, "reviewCalls=0")
        assertNoOperation()
    }

    private func launch(_ scenario: String, accessibility5: Bool = false) {
        app?.terminate()
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_STORAGE_TRANSFER"] = scenario
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = accessibility5 ? "1" : "0"
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        XCTAssertTrue(state.waitForExistence(timeout: 12), "The explicit Debug-only fixture must be selected")
        assertNoOperation()
    }

    private var state: XCUIElement { app.staticTexts["storage-switch.fixture-state"] }

    private func assertCompactOfflineBanner(expectsRetry: Bool = true) {
        let details = app.buttons["cloud-offline-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 4))
        XCTAssertTrue(details.isHittable)
        XCTAssertEqual(details.label, "このiPhoneに保存・iCloud同期は待機中。詳細を表示")
        assertTouchTarget(details)
        XCTAssertEqual(app.buttons.matching(identifier: "cloud-offline-details").count, 1)
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(details.frame.height, window.height * 0.20)
        XCTAssertLessThanOrEqual(details.frame.maxY, window.minY + window.height * 0.30,
            "A fixed banner must leave most of the screen available to the underlying content")
        let retry = app.buttons["cloud-offline-retry"]
        if expectsRetry {
            XCTAssertTrue(retry.waitForExistence(timeout: 4))
            XCTAssertTrue(retry.isHittable)
            assertTouchTarget(retry)
            XCTAssertEqual(app.buttons.matching(identifier: "cloud-offline-retry").count, 1,
                "The banner must not override the retry control's AX identifier")
            XCTAssertGreaterThanOrEqual(retry.frame.width, 43.5)
            XCTAssertLessThanOrEqual(retry.frame.maxY, window.minY + window.height * 0.30)
        } else {
            XCTAssertFalse(retry.exists)
        }
        XCTAssertTrue(app.navigationBars["設定"].isHittable)
        XCTAssertTrue(state.isHittable, "The first ordinary Settings row must remain visible below the banner")
    }

    private func openOfflineDetails() {
        let details = app.buttons["cloud-offline-details"]
        XCTAssertTrue(details.isHittable)
        details.tap()
        XCTAssertTrue(app.navigationBars["同期の状態"].waitForExistence(timeout: 4))
    }

    private func closeOfflineDetails() {
        let close = app.buttons["cloud-offline-details-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 4))
        XCTAssertTrue(close.isHittable)
        assertTouchTarget(close)
        close.tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["同期の状態"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 4), .completed)
        XCTAssertTrue(app.navigationBars["設定"].isHittable)
        XCTAssertTrue(app.buttons["cloud-offline-details"].isHittable)
    }

    private func assertOfflineRetryCallsOnce() {
        let retry = app.buttons["cloud-offline-retry"]
        XCTAssertTrue(retry.isHittable)
        XCTAssertTrue(retry.isEnabled)
        XCTAssertEqual(retry.label, "同期を再開")
        retry.doubleTap()
        let checking = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == false AND label == %@", "接続を確認中"), object: retry)
        XCTAssertEqual(XCTWaiter.wait(for: [checking], timeout: 4), .completed)
        retry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let retryState = app.staticTexts["cloud-offline.fixture-state"]
        XCTAssertTrue(reveal(retryState, upwards: false))
        XCTAssertEqual(retryState.label, "retryCalls=1;checking=true")
    }

    private func assertOfflineStorageSwitchDisabled() {
        let entry = app.buttons["settings.storage-switch"]
        XCTAssertTrue(reveal(entry))
        XCTAssertEqual(entry.label, "iCloudを解除する")
        XCTAssertFalse(entry.isEnabled)
        entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.navigationBars["iCloudを解除"].exists)
        XCTAssertFalse(app.buttons["storage-switch.disable-keep-copy"].exists)
        XCTAssertFalse(app.buttons["storage-switch.keep-cloud"].exists)
        XCTAssertFalse(app.buttons["storage-switch.replace-cloud"].exists)
        XCTAssertFalse(app.buttons["storage-switch.confirm"].exists)
    }

    private func openChoices() {
        let button = app.buttons["settings.storage-switch"]
        XCTAssertTrue(reveal(button))
        let ready = NSPredicate(format: "enabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 4), .completed)
        button.tap()
        let presented = app.buttons["キャンセル"].waitForExistence(timeout: 4)
        if !presented {
            attach("Storage choices failed to appear")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Storage choices accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(presented)
    }

    private func openConfirmation(_ identifier: String, upwards: Bool = true) {
        let choice = app.buttons[identifier]
        if !reveal(choice, upwards: upwards) { XCTAssertTrue(reveal(choice, upwards: !upwards)) }
        choice.tap()
        XCTAssertTrue(app.navigationBars["最後の確認"].waitForExistence(timeout: 4))
    }

    private func assertUncheckedConfirmation() {
        let checkbox = app.switches["storage-switch.confirm-data-loss"]
        XCTAssertTrue(reveal(checkbox))
        XCTAssertEqual(checkbox.value as? String, "0")
        let confirm = app.buttons["storage-switch.confirm"]
        XCTAssertTrue(reveal(confirm))
        XCTAssertFalse(confirm.isEnabled)
    }

    private func acknowledgeDeletion() {
        let checkbox = app.switches["storage-switch.confirm-data-loss"]
        if !reveal(checkbox) { XCTAssertTrue(reveal(checkbox, upwards: false)) }
        // SwiftUI exposes the label and trailing switch as one wide AX node;
        // its center is noninteractive text. Exercise the real switch control.
        checkbox.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let checked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: checkbox)
        XCTAssertEqual(XCTWaiter.wait(for: [checked], timeout: 3), .completed)
    }

    private func assertNoOperation() {
        // At AX5 the entry is below the probe; List may recycle the probe while
        // the choice sheet is open. Return to that real row before reading it.
        XCTAssertTrue(reveal(state, upwards: false))
        XCTAssertEqual(state.label, "calls=0;choice=none;starting=false")
    }

    private func assertAccepted(_ choice: String) {
        let accepted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "calls=1;choice=\(choice);starting=true"),
            object: state
        )
        XCTAssertEqual(XCTWaiter.wait(for: [accepted], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["settings.storage-switch"].isEnabled)
    }

    private func text(containing value: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    @discardableResult
    private func reveal(_ element: XCUIElement, upwards: Bool = true) -> Bool {
        for _ in 0..<14 {
            if element.exists, element.isHittable {
                if element.elementType != .button && element.elementType != .switch { return true }
                let frame = element.frame
                let top = app.navigationBars.allElementsBoundByIndex.filter(\.isHittable).map(\.frame.maxY).max() ?? 0
                let bottom = app.windows.firstMatch.frame.maxY - 40
                if frame.minY >= top && frame.maxY <= bottom { return true }
                // Once the target is visible, correct toward the viewport
                // regardless of the original search direction. A full swipe
                // can leap past a tall AX5 row and oscillate across both edges.
                let correction = frame.minY < top ? top - frame.minY + 12 : bottom - frame.maxY - 12
                let distance = min(160, max(60, abs(correction))) * (correction < 0 ? -1 : 1)
                let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
                continue
            }
            if upwards { app.swipeUp() } else { app.swipeDown() }
        }
        return element.exists && element.isHittable
    }

    private func assertTouchTarget(_ element: XCUIElement) {
        XCTAssertGreaterThanOrEqual(element.frame.height, 43.5)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(element.frame.minX, window.minX)
        XCTAssertLessThanOrEqual(element.frame.maxX, window.maxX)
    }

    private func auditDescriptionsAndTraits() throws {
        if #available(iOS 17.0, *) {
            try app.performAccessibilityAudit(for: .sufficientElementDescription)
            try app.performAccessibilityAudit(for: .trait)
        }
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
