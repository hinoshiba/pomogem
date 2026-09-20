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
        // Deliberately updated by PLAN Step 11. The legacy localOnly -> cloud
        // replacement stays absent in cloud mode and stays disabled on its own
        // bit; the NEW, generation-fenced device -> iCloud door is what cloud
        // mode gains, and in this phase it is present and refused.
        XCTAssertFalse(app.buttons["storage-switch.keep-cloud"].exists)
        XCTAssertFalse(app.buttons["storage-switch.replace-cloud"].exists)
        let overwrite = app.buttons["storage-switch.overwrite-cloud"]
        XCTAssertTrue(reveal(overwrite))
        XCTAssertFalse(overwrite.isEnabled)
        openConfirmation("storage-switch.disable-keep-copy")
        XCTAssertTrue(text(containing: "このiPhoneにコピーしたデータと、iCloudのデータの両方が残ります").exists)
        XCTAssertFalse(app.switches["storage-switch.confirm-data-loss"].exists)
        let confirm = app.buttons["storage-switch.confirm"]
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertEqual(confirm.label, "コピーしてiCloudを解除")
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        app.navigationBars["iCloudと保存先の変更"].buttons["キャンセル"].tap()
        assertNoOperation()
        assertNoDatasetRequest()
        openChoices()
        openConfirmation("storage-switch.disable-keep-copy")
        attach("Disable — both copies remain")
        app.buttons["storage-switch.confirm"].tap()
        assertAccepted("disableCloudKeepingCopy")
    }

    // MARK: Settings direction (A) — この端末のデータでiCloudを置き換える

    /// The shipping build. The door exists, is described, and is refused:
    /// `StorageTransferReleasePolicy.standard.allowsDatasetOverwriteFromDevice`
    /// is false, so nothing about it can be started from Settings.
    func testSettingsOverwriteDoorIsPresentDisabledAndExplainedInCloudMode() {
        launch("cloud")
        openChoices()
        XCTAssertTrue(app.navigationBars["iCloudと保存先の変更"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["storage-switch.keep-cloud"].exists)
        XCTAssertFalse(app.buttons["storage-switch.replace-cloud"].exists)
        let reason = app.staticTexts["storage-switch.overwrite-cloud-unavailable"]
        XCTAssertTrue(reveal(reason))
        XCTAssertTrue(reason.label.contains("いまは利用できません"))
        XCTAssertTrue(reason.label.contains("削除せず保持します"))
        let door = app.buttons["storage-switch.overwrite-cloud"]
        XCTAssertTrue(reveal(door))
        XCTAssertFalse(door.isEnabled)
        door.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.navigationBars["最後の確認"].exists)
        XCTAssertFalse(app.buttons["storage-switch.overwrite-cloud-confirm"].exists)
        attach("Settings overwrite — present, disabled and explained")
        app.navigationBars["iCloudと保存先の変更"].buttons["キャンセル"].tap()
        assertNoOperation()
        assertNoDatasetRequest()
    }

    /// The door never acts on tap: it opens 「最後の確認」, whose acknowledgement is
    /// its own state, starts unchecked on every presentation and is discarded
    /// by 戻る. Only the acknowledged action records exactly one request.
    func testSettingsOverwriteNeedsItsOwnAcknowledgmentAndRecordsOneRequest() {
        launch("cloudDatasetDoors")
        openChoices()
        openConfirmation("storage-switch.overwrite-cloud")
        XCTAssertTrue(reveal(text(containing: "現在iCloudにあるPomoGemのテーマ・記録・設定をすべて削除し")))
        XCTAssertTrue(reveal(app.staticTexts["storage-switch.overwrite-cloud-recovery-copy"]))
        XCTAssertTrue(reveal(app.staticTexts["storage-switch.overwrite-cloud-relaunch"]))
        XCTAssertTrue(reveal(app.staticTexts["storage-switch.overwrite-cloud-not-cancellable"]))
        assertUncheckedDatasetConfirmation("overwrite-cloud")
        acknowledgeDataset("overwrite-cloud")
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.navigationBars["iCloudと保存先の変更"].waitForExistence(timeout: 4))
        app.navigationBars["iCloudと保存先の変更"].buttons["キャンセル"].tap()
        assertNoDatasetRequest()
        assertNoOperation()

        openChoices()
        openConfirmation("storage-switch.overwrite-cloud")
        assertUncheckedDatasetConfirmation("overwrite-cloud")
        acknowledgeDataset("overwrite-cloud")
        attach("Settings overwrite — acknowledged final confirmation")
        app.buttons["storage-switch.overwrite-cloud-confirm"].doubleTap()
        assertDatasetRequested("overwriteCloudFromDevice")
    }

    func testAX5SettingsOverwriteDoorAndConfirmationRemainReachableAndDescribed() throws {
        launch("cloudDatasetDoors", accessibility5: true)
        openChoices()
        let door = app.buttons["storage-switch.overwrite-cloud"]
        XCTAssertTrue(reveal(door))
        assertTouchTarget(door)
        XCTAssertTrue(door.isEnabled)
        attach("AX5 Settings overwrite — reachable door")
        try auditDescriptionsAndTraits()
        openConfirmation("storage-switch.overwrite-cloud")
        let checkbox = app.switches["storage-switch.overwrite-cloud-confirm-data-loss"]
        XCTAssertTrue(reveal(checkbox))
        assertTouchTarget(checkbox)
        XCTAssertGreaterThan(checkbox.frame.height, 100,
            "The modal must actually inherit AX5, not silently reset to normal text")
        XCTAssertEqual(checkbox.value as? String, "0")
        acknowledgeDataset("overwrite-cloud")
        let confirm = app.buttons["storage-switch.overwrite-cloud-confirm"]
        XCTAssertTrue(reveal(confirm))
        assertTouchTarget(confirm)
        XCTAssertTrue(confirm.isEnabled)
        attach("AX5 Settings overwrite — explicit acknowledgment and action")
        try auditDescriptionsAndTraits()
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        app.navigationBars["iCloudと保存先の変更"].buttons["キャンセル"].tap()
        assertNoDatasetRequest()
        assertNoOperation()
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
        // The cloud-mode screen is no longer only about unlinking iCloud, so
        // its title moved with PLAN Step 11. This assertion is the only line
        // of this test that changed.
        app.navigationBars["iCloudと保存先の変更"].buttons["キャンセル"].tap()
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

    func testOfflineRootNavigationAndFullScreenFocusDoNotOverlapBanner() {
        assertOfflineRootNavigation(accessibility5: false)
    }

    func testAX5OfflineRootNavigationAndFullScreenFocusDoNotOverlapBanner() {
        assertOfflineRootNavigation(accessibility5: true)
    }

    func testAX5OfflineRecoveredBreakKeepsBannerAndReturnActionReachable() {
        launch("offlineBreakNavigation", accessibility5: true, expectsSettingsFixture: false)
        let skips = app.buttons.matching(NSPredicate(format: "label == %@", "休憩をスキップ"))
        XCTAssertTrue(skips.firstMatch.waitForExistence(timeout: 15), "Root must present its actual recovered BreakTimerView")
        // Break has header and footer actions with the same meaning. Its
        // foreground header is already visible; the Settings scroll helper
        // must not compare it against the covered Root's navigation bar.
        let visibleSkips = skips.allElementsBoundByIndex.filter(\.isHittable)
            .sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertFalse(visibleSkips.isEmpty)
        guard let skip = visibleSkips.first else { return }
        let details = visibleBannerButton("cloud-offline-details")
        XCTAssertTrue(details.isHittable)
        assertTouchTarget(details)
        assertTouchTarget(skip)
        XCTAssertGreaterThanOrEqual(skip.frame.minY, details.frame.maxY)
        XCTAssertLessThanOrEqual(skip.frame.maxY, app.windows.firstMatch.frame.maxY)
        XCTAssertFalse(skip.frame.intersects(details.frame))
        attach("AX5 offline actual Root — recovered break and return action")
        skip.tap()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 5))
        assertNavigationClearOfBanner(app.navigationBars.firstMatch)
        assertNoNavigationRetry()
    }

    private func assertOfflineRootNavigation(accessibility5: Bool) {
        launch("offlineNavigation", accessibility5: accessibility5, expectsSettingsFixture: false)
        let menu = app.buttons["メニュー"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "Use the actual Root/Home toolbar, not a toolbar-free fixture")
        attach("Offline actual Root — Home toolbar and banner")
        assertNavigationClearOfBanner(app.navigationBars.firstMatch)
        XCTAssertTrue(menu.isHittable)
        menu.tap()
        XCTAssertTrue(app.navigationBars["メニュー"].waitForExistence(timeout: 4),
            "A Home menu tap must open the menu, never invoke the cloud retry beneath it")
        app.buttons["home.menu.close"].tap()
        assertNoNavigationRetry()

        for (action, title) in [("記録を見る", "記録"), ("設定", "設定")] {
            menu.tap()
            XCTAssertTrue(app.navigationBars["メニュー"].waitForExistence(timeout: 4))
            let destination = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", action)).firstMatch
            XCTAssertTrue(reveal(destination))
            destination.tap()
            let bar = app.navigationBars[title]
            XCTAssertTrue(bar.waitForExistence(timeout: 5))
            assertNavigationClearOfBanner(bar)
            let back = bar.buttons.element(boundBy: 0)
            XCTAssertTrue(back.isHittable)
            attach("Offline actual Root — \(title) and back control")
            back.tap()
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            assertNoNavigationRetry()
        }

        let launcher = app.buttons["home.focus-launcher"]
        XCTAssertTrue(reveal(launcher))
        launcher.tap()
        let pause = app.buttons["一時停止"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        // This is HomeView's real new-focus fullScreenCover. It must have its
        // own visible banner; an inaccessible copy underneath cannot satisfy.
        let details = visibleBannerButton("cloud-offline-details")
        XCTAssertTrue(details.isHittable)
        XCTAssertTrue(visibleBannerButton("cloud-offline-retry").isHittable)
        let subject = app.staticTexts["focus.subject"]
        XCTAssertTrue(subject.exists)
        XCTAssertGreaterThanOrEqual(subject.frame.minY, details.frame.maxY)
        XCTAssertTrue(reveal(pause))
        XCTAssertFalse(pause.frame.intersects(details.frame))
        pause.tap()
        let resume = app.buttons["再開する"]
        XCTAssertTrue(resume.waitForExistence(timeout: 4))
        XCTAssertTrue(reveal(resume))
        XCTAssertFalse(resume.frame.intersects(details.frame))
        attach("Offline actual Root — paused full-screen focus with visible banner")
        assertNoNavigationRetry()
        details.tap()
        XCTAssertTrue(app.navigationBars["同期の状態"].waitForExistence(timeout: 4))
        let message = app.staticTexts["cloud-offline-details-message"]
        XCTAssertTrue(reveal(message))
        XCTAssertTrue(message.label.contains("retryCalls=0"))
        app.buttons["cloud-offline-details-close"].tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 4), "Closing banner details must preserve the paused timer")
        let retry = visibleBannerButton("cloud-offline-retry")
        XCTAssertTrue(retry.isHittable)
        retry.doubleTap()
        XCTAssertFalse(retry.isEnabled)
        XCTAssertTrue(resume.exists, "Updating banner state must not recreate Root or discard its paused focus")
        details.tap()
        XCTAssertTrue(app.navigationBars["同期の状態"].waitForExistence(timeout: 4))
        XCTAssertTrue(reveal(message))
        XCTAssertTrue(message.label.contains("retryCalls=1"), "The visible full-screen banner invokes exactly one connection action")
        app.buttons["cloud-offline-details-close"].tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 4))
        let timer = app.descendants(matching: .any).matching(identifier: "focus.timer-display").firstMatch
        let pausedValue = timer.value as? String
        XCTAssertNotNil(pausedValue)

        // A real UI-created paused timer is recovered through Root's separate
        // fullScreenCover on the next process. No synthesized focus envelope.
        launch("offlineNavigationRecovered", accessibility5: accessibility5, expectsSettingsFixture: false)
        let recoveredResume = app.buttons["再開する"]
        XCTAssertTrue(recoveredResume.waitForExistence(timeout: 15))
        XCTAssertTrue(visibleBannerButton("cloud-offline-details").isHittable)
        XCTAssertTrue(visibleBannerButton("cloud-offline-retry").isHittable)
        XCTAssertTrue(reveal(recoveredResume))
        XCTAssertFalse(recoveredResume.frame.intersects(visibleBannerButton("cloud-offline-details").frame))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "focus.timer-display").firstMatch.value as? String, pausedValue)
        attach("Offline actual Root — recovered paused focus retains banner and remainder")
        assertNoNavigationRetry()
    }

    private func assertNavigationClearOfBanner(_ navigationBar: XCUIElement) {
        let details = visibleBannerButton("cloud-offline-details")
        let retry = visibleBannerButton("cloud-offline-retry")
        XCTAssertTrue(details.isHittable)
        XCTAssertTrue(retry.isHittable)
        assertTouchTarget(details)
        assertTouchTarget(retry)
        XCTAssertGreaterThanOrEqual(navigationBar.frame.minY,
            max(details.frame.maxY, retry.frame.maxY) - 0.5,
            "The Host banner must reserve height above the real navigation bar")
        for button in navigationBar.buttons.allElementsBoundByIndex {
            XCTAssertFalse(button.frame.intersects(details.frame))
            XCTAssertFalse(button.frame.intersects(retry.frame))
        }
    }

    private func assertNoNavigationRetry() {
        let retry = visibleBannerButton("cloud-offline-retry")
        XCTAssertTrue(retry.isHittable)
        XCTAssertTrue(retry.isEnabled, "Navigating/pausing must not invoke the connection action")
    }

    private func visibleBannerButton(_ identifier: String) -> XCUIElement {
        // UIKit retains the covered Root in the AX snapshot. Require exactly
        // one actionable foreground copy; merely finding its background twin
        // would falsely pass a missing full-screen banner.
        let buttons = app.buttons.matching(identifier: identifier)
        let visible = buttons.allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertEqual(visible.count, 1, "Exactly one foreground banner control must be actionable: \(identifier)")
        return visible.first ?? buttons.firstMatch
    }

    private func launch(_ scenario: String, accessibility5: Bool = false, expectsSettingsFixture: Bool = true) {
        app?.terminate()
        app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_STORAGE_TRANSFER"] = scenario
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = accessibility5 ? "1" : "0"
        app.launchArguments += ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        if expectsSettingsFixture {
            XCTAssertTrue(state.waitForExistence(timeout: 12), "The explicit Debug-only fixture must be selected")
            assertNoOperation()
        }
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
        XCTAssertFalse(app.navigationBars["iCloudと保存先の変更"].exists)
        XCTAssertFalse(app.buttons["storage-switch.disable-keep-copy"].exists)
        XCTAssertFalse(app.buttons["storage-switch.keep-cloud"].exists)
        XCTAssertFalse(app.buttons["storage-switch.replace-cloud"].exists)
        XCTAssertFalse(app.buttons["storage-switch.confirm"].exists)
        // PLAN Step 11/12: an offline session must not reach either dataset
        // door. Docs/OfflineCloudMode.md forbids using an offline launch as a
        // detour, and both directions are online-only by construction.
        XCTAssertFalse(app.buttons["storage-switch.overwrite-cloud"].exists)
        XCTAssertFalse(app.buttons["storage-switch.overwrite-cloud-confirm"].exists)
        assertNoDatasetRequest()
    }

    private var datasetState: XCUIElement { app.staticTexts["storage-switch.dataset-fixture-state"] }

    private func assertNoDatasetRequest() {
        XCTAssertTrue(reveal(datasetState, upwards: false))
        XCTAssertEqual(datasetState.label, "dataset=none;datasetCalls=0")
    }

    private func assertDatasetRequested(_ direction: String) {
        let recorded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "dataset=\(direction);datasetCalls=1"),
            object: datasetState
        )
        XCTAssertEqual(XCTWaiter.wait(for: [recorded], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["settings.storage-switch"].isEnabled)
    }

    private func assertUncheckedDatasetConfirmation(_ door: String) {
        let checkbox = app.switches["storage-switch.\(door)-confirm-data-loss"]
        XCTAssertTrue(reveal(checkbox))
        XCTAssertEqual(checkbox.value as? String, "0")
        let confirm = app.buttons["storage-switch.\(door)-confirm"]
        XCTAssertTrue(reveal(confirm))
        XCTAssertFalse(confirm.isEnabled)
    }

    private func acknowledgeDataset(_ door: String) {
        let checkbox = app.switches["storage-switch.\(door)-confirm-data-loss"]
        if !reveal(checkbox) { XCTAssertTrue(reveal(checkbox, upwards: false)) }
        checkbox.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let checked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: checkbox)
        XCTAssertEqual(XCTWaiter.wait(for: [checked], timeout: 3), .completed)
        XCTAssertTrue(app.buttons["storage-switch.\(door)-confirm"].isEnabled)
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
