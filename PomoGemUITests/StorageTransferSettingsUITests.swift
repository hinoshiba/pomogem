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

    /// transfer-02. 「iCloudのデータを使う」 deletes this device's whole jar,
    /// so both sides are counted before 「最後の確認」 opens, with an export
    /// beside them. Screen Time is not in use here, so nothing about it shows.
    func testKeepingCloudCountsBothSidesBeforeItsConfirmation() {
        launch("local")
        openChoices()
        openConfirmation("storage-switch.keep-cloud")
        let comparison = app.staticTexts["storage-switch.keep-cloud-comparison"]
        XCTAssertTrue(reveal(comparison))
        XCTAssertTrue(comparison.label.contains("このiPhone: テーマ12・記録480・成果36"), "saw: \(comparison.label)")
        XCTAssertTrue(comparison.label.contains("iCloud: テーマ9・記録312・成果28"), "saw: \(comparison.label)")
        XCTAssertFalse(app.staticTexts["storage-switch.keep-cloud-empty-cloud"].exists)
        XCTAssertTrue(reveal(app.buttons["storage-switch.export"]))
        XCTAssertFalse(app.staticTexts["storage-switch.screen-time"].exists)
        attach("Enable iCloud — both sides counted before the acknowledgement")
        assertUncheckedConfirmation()
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.navigationBars["iCloudを有効にする"].waitForExistence(timeout: 4))
        app.navigationBars["iCloudを有効にする"].buttons["キャンセル"].tap()
        assertPreviewReads(1)
        assertNoOperation()
    }

    /// The common case for someone who never used sync: iCloud holds only
    /// what every onboarded device mirrors. The user is told, with counts,
    /// that this iPhone's jar is deleted and sync starts from nothing.
    func testKeepingCloudWarnsWhenICloudHoldsNoneOfTheUsersRecords() {
        launch("localEmptyCloud")
        openChoices()
        openConfirmation("storage-switch.keep-cloud")
        let empty = app.staticTexts["storage-switch.keep-cloud-empty-cloud"]
        XCTAssertTrue(reveal(empty))
        XCTAssertTrue(empty.label.contains("1件も見つかりませんでした"), "saw: \(empty.label)")
        XCTAssertTrue(empty.label.contains("このiPhoneのテーマ12・記録480・成果36"), "saw: \(empty.label)")
        XCTAssertTrue(empty.label.contains("空の状態からiCloudの同期を始めます"), "saw: \(empty.label)")
        attach("Enable iCloud — iCloud holds none of the user's records")
        assertUncheckedConfirmation()
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.navigationBars["iCloudを有効にする"].waitForExistence(timeout: 4))
        app.navigationBars["iCloudを有効にする"].buttons["キャンセル"].tap()
        assertNoOperation()
    }

    /// "Could not look" is never shown as "nothing there": a failed read
    /// keeps 最後の確認 closed and names the button to press again.
    func testKeepingCloudStaysClosedWhenICloudCannotBeRead() {
        launch("localPreviewUnreadable")
        openChoices()
        let door = app.buttons["storage-switch.keep-cloud"]
        XCTAssertTrue(reveal(door))
        door.tap()
        let failure = app.staticTexts["storage-switch.keep-cloud-preview-error"]
        XCTAssertTrue(reveal(failure))
        XCTAssertTrue(failure.label.contains("「iCloudのデータを使う」"), "saw: \(failure.label)")
        XCTAssertTrue(failure.label.contains("どちらの記録も削除していません"))
        XCTAssertFalse(app.navigationBars["最後の確認"].exists)
        attach("Enable iCloud — unreadable iCloud keeps the confirmation closed")
        app.navigationBars["iCloudを有効にする"].buttons["キャンセル"].tap()
        assertPreviewReads(1)
        assertNoOperation()
    }

    /// transfer-07. Every published switch moves to a new storage namespace
    /// and resets Screen Time gems; each confirmation says so while the
    /// feature is in use, including the non-destructive 「このiPhoneへ引き継ぐ」.
    func testEveryPublishedSwitchDisclosesTheScreenTimeReset() {
        launch("localScreenTime")
        openChoices()
        openConfirmation("storage-switch.keep-cloud")
        let enable = app.staticTexts["storage-switch.screen-time"]
        XCTAssertTrue(reveal(enable))
        XCTAssertTrue(enable.label.contains("選び直してください"), "saw: \(enable.label)")
        XCTAssertTrue(enable.label.contains("保存済みの勉強時間と通常gemは引き継ぎます"))
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.navigationBars["iCloudを有効にする"].waitForExistence(timeout: 4))
        app.navigationBars["iCloudを有効にする"].buttons["キャンセル"].tap()

        launch("cloudScreenTime")
        openChoices()
        openConfirmation("storage-switch.disable-keep-copy")
        XCTAssertTrue(reveal(app.staticTexts["storage-switch.screen-time"]))
        attach("Keep a copy — Screen Time reset disclosed")
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                               object: app.navigationBars["最後の確認"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        openConfirmation("storage-switch.refresh-from-cloud")
        XCTAssertTrue(reveal(app.staticTexts["storage-switch.refresh-from-cloud-screen-time"]))
        XCTAssertTrue(reveal(app.buttons["storage-switch.refresh-from-cloud-export"]))
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.navigationBars["iCloudと保存先の変更"].waitForExistence(timeout: 4))
        app.navigationBars["iCloudと保存先の変更"].buttons["キャンセル"].tap()
        assertNoOperation()
        assertNoDatasetRequest()
    }

    func testReplacingCloudIsDisabledWithReasonAndCannotOpenConfirmation() {
        launch("local")
        openChoices()
        let reason = app.staticTexts["storage-switch.replace-cloud-unavailable"]
        XCTAssertTrue(reveal(reason))
        XCTAssertTrue(reason.label.contains("複数端末での同時操作"))
        XCTAssertTrue(reason.label.contains("いまは利用できません"))
        // transfer-10. Nothing was ever staged at a closed door.
        XCTAssertFalse(reason.label.contains("復旧用コピー"))
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
        XCTAssertFalse(reason.label.contains("削除していません"),
            "Nobody pressed a closed door; its reason reports no event")
        XCTAssertFalse(reason.label.contains("復旧用コピー"))
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
        // Assert on the sheet's OWN identified paragraphs: the section body
        // behind it carries similar wording, and an unhittable background copy
        // must never be able to satisfy an assertion about the sheet.
        let overwriteWarning = app.staticTexts["storage-switch.overwrite-cloud-warning"]
        XCTAssertTrue(reveal(overwriteWarning))
        XCTAssertTrue(overwriteWarning.label.contains("元に戻すことはできません"))
        // PLAN §3 S14/S15: the counts of what would be destroyed and the
        // other-device evidence are on the consent screen, not behind it.
        let comparison = app.staticTexts["storage-switch.overwrite-cloud-comparison"]
        XCTAssertTrue(reveal(comparison))
        XCTAssertTrue(comparison.label.contains("このiPhone"))
        XCTAssertTrue(comparison.label.contains("iCloud"))
        XCTAssertTrue(comparison.label.contains("テーマ"))
        XCTAssertTrue(comparison.label.contains("記録"))
        let evidence = app.staticTexts["storage-switch.overwrite-cloud-other-devices"]
        XCTAssertTrue(reveal(evidence))
        XCTAssertTrue(evidence.label.contains("2台"))
        XCTAssertTrue(evidence.label.contains("未送信"))
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

    /// The evidence is read BEFORE the acknowledgement, and a failed read keeps
    /// the door shut rather than opening it on an assumption. 「we could not
    /// look」 and 「there is nothing there」 must not be confusable here.
    func testSettingsOverwriteReadsTheEvidenceBeforeConsentAndRefusesWhenItCannot() {
        launch("cloudDatasetDoorsUnreadable")
        openChoices()
        let door = app.buttons["storage-switch.overwrite-cloud"]
        XCTAssertTrue(reveal(door))
        XCTAssertTrue(door.isEnabled)
        door.tap()
        let failure = app.staticTexts["storage-switch.overwrite-cloud-preview-error"]
        XCTAssertTrue(reveal(failure))
        XCTAssertTrue(failure.label.contains("iCloudの内容を確認できませんでした"))
        XCTAssertTrue(failure.label.contains("どちらの記録も削除していません"))
        XCTAssertFalse(app.navigationBars["最後の確認"].exists,
            "Nobody may be asked to authorize deleting contents the app failed to enumerate")
        XCTAssertFalse(app.switches["storage-switch.overwrite-cloud-confirm-data-loss"].exists)
        attach("Settings overwrite — unreadable iCloud keeps the confirmation closed")
        // The opposite direction is unaffected: it destroys the device side.
        XCTAssertTrue(reveal(app.buttons["storage-switch.refresh-from-cloud"]))
        app.navigationBars["iCloudと保存先の変更"].buttons["キャンセル"].tap()
        assertPreviewReads(1)
        assertNoDatasetRequest()
        assertNoOperation()
    }

    /// review-1-2 / review-2-4. Direction (B) destroys the DEVICE side and
    /// stages no recovery copy anywhere (`retireSource` removes the source
    /// store family after `selectionCommitted`), and W6 opened it to accounts
    /// with no transfer ledger — the accounts whose iCloud side is most likely
    /// to be empty. It therefore reads the server before its confirmation and
    /// shows what it would re-fetch from, exactly as direction (A) does.
    func testTheRefreshDirectionReadsTheICloudSideBeforeItsConfirmation() {
        launch("cloudDatasetDoors")
        openChoices()
        openConfirmation("storage-switch.refresh-from-cloud")
        let comparison = app.staticTexts["storage-switch.refresh-from-cloud-comparison"]
        XCTAssertTrue(reveal(comparison))
        XCTAssertTrue(comparison.label.contains("iCloud: テーマ"), "saw: \(comparison.label)")
        XCTAssertFalse(app.staticTexts["storage-switch.refresh-from-cloud-empty-cloud"].exists,
            "This account's server side is not empty; the loud warning is for the one that is")
        assertUncheckedDatasetConfirmation("refresh-from-cloud")
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.navigationBars["iCloudと保存先の変更"].waitForExistence(timeout: 4))
        app.navigationBars["iCloudと保存先の変更"].buttons["キャンセル"].tap()
        assertPreviewReads(1)
        assertNoDatasetRequest()
        assertNoOperation()
    }

    /// The shape in which 「iCloudのデータは残ります」 is true and still leaves
    /// the user with an empty app and no copy anywhere: PomoGem's data deleted
    /// from iOS Settings, months of records still on the device.
    func testTheRefreshDirectionSaysSoWhenTheServerSideIsEmpty() {
        launch("cloudDatasetDoorsEmptyCloud")
        openChoices()
        openConfirmation("storage-switch.refresh-from-cloud")
        let comparison = app.staticTexts["storage-switch.refresh-from-cloud-comparison"]
        XCTAssertTrue(reveal(comparison))
        XCTAssertTrue(comparison.label.contains("iCloud: テーマ0・記録0・成果0"), "saw: \(comparison.label)")
        XCTAssertTrue(comparison.label.contains("このiPhone: テーマ12・記録480・成果36"),
            "The side this direction deletes is counted too, saw: \(comparison.label)")
        let empty = app.staticTexts["storage-switch.refresh-from-cloud-empty-cloud"]
        XCTAssertTrue(reveal(empty))
        XCTAssertTrue(empty.label.contains("1件も見つかりませんでした"))
        XCTAssertTrue(empty.label.contains("このiPhoneのテーマ12・記録480・成果36"), "saw: \(empty.label)")
        XCTAssertTrue(empty.label.contains("元に戻すことはできません"))
        attach("Settings refresh-from-cloud — the server side is empty")
        assertUncheckedDatasetConfirmation("refresh-from-cloud")
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.navigationBars["iCloudと保存先の変更"].waitForExistence(timeout: 4))
        app.navigationBars["iCloudと保存先の変更"].buttons["キャンセル"].tap()
        assertPreviewReads(1)
        assertNoDatasetRequest()
        assertNoOperation()
    }

    /// transfer-03, the shipping build. Five seeded themes, a Prefs row and a
    /// device claim are not the user's records: the row names the three things
    /// a person recognises, never a bookkeeping total, and the warning fires.
    func testTheRefreshDirectionWarnsWhenICloudHoldsOnlyBookkeepingRows() {
        launch("cloudRefreshBookkeepingOnly")
        openChoices()
        openConfirmation("storage-switch.refresh-from-cloud")
        let comparison = app.staticTexts["storage-switch.refresh-from-cloud-comparison"]
        XCTAssertTrue(reveal(comparison))
        XCTAssertTrue(comparison.label.contains("iCloud: テーマ5・記録0・成果0"), "saw: \(comparison.label)")
        XCTAssertTrue(comparison.label.contains("このiPhone: テーマ12・記録480・成果36"), "saw: \(comparison.label)")
        XCTAssertFalse(comparison.label.contains("管理情報"))
        XCTAssertFalse(comparison.label.contains("記録件数"))
        let empty = app.staticTexts["storage-switch.refresh-from-cloud-empty-cloud"]
        XCTAssertTrue(reveal(empty), "The documented 0件 warning must reach a real account")
        XCTAssertTrue(empty.label.contains("このiPhoneのテーマ12・記録480・成果36"), "saw: \(empty.label)")
        attach("Settings refresh-from-cloud — only bookkeeping rows in iCloud")
        assertUncheckedDatasetConfirmation("refresh-from-cloud")
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.navigationBars["iCloudと保存先の変更"].waitForExistence(timeout: 4))
        app.navigationBars["iCloudと保存先の変更"].buttons["キャンセル"].tap()
        assertPreviewReads(1)
        assertNoDatasetRequest()
        assertNoOperation()
    }

    /// A failed read keeps direction (B)'s confirmation closed too, and names
    /// the control this door actually carries rather than the other one's.
    func testTheRefreshDirectionRefusesToConfirmWhenItCouldNotLook() {
        launch("cloudDatasetDoorsUnreadable")
        openChoices()
        let door = app.buttons["storage-switch.refresh-from-cloud"]
        XCTAssertTrue(reveal(door))
        door.tap()
        let failure = app.staticTexts["storage-switch.refresh-from-cloud-preview-error"]
        XCTAssertTrue(reveal(failure))
        XCTAssertTrue(failure.label.contains("iCloudから再取得"), "saw: \(failure.label)")
        XCTAssertTrue(failure.label.contains("どちらの記録も削除していません"))
        XCTAssertFalse(app.navigationBars["最後の確認"].exists,
            "Nobody may be asked to discard this device's only copy on an unread server")
        attach("Settings refresh-from-cloud — unreadable iCloud keeps the confirmation closed")
        app.navigationBars["iCloudと保存先の変更"].buttons["キャンセル"].tap()
        assertPreviewReads(1)
        assertNoDatasetRequest()
        assertNoOperation()
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

    // MARK: Settings direction (B) — iCloudのデータでこの端末を置き換える

    /// PLAN Step 12. Direction (B) replaces nothing on the server and carries
    /// no release bit, so it is usable in the SHIPPING build — unlike direction
    /// (A) beside it, which stays disabled while
    /// `allowsDatasetOverwriteFromDevice` is false. It still acts on nothing by
    /// tap: 「最後の確認」 owns its own, unchecked acknowledgement.
    func testSettingsRefreshDoorIsUsableInTheShippingBuildWhileTheOverwriteStaysClosed() {
        launch("cloud")
        openChoices()
        XCTAssertFalse(app.staticTexts["storage-switch.refresh-from-cloud-unavailable"].exists,
            "A direction that deletes nothing on the server has no unavailability to explain")
        let overwrite = app.buttons["storage-switch.overwrite-cloud"]
        XCTAssertTrue(reveal(overwrite))
        XCTAssertFalse(overwrite.isEnabled,
            "The destructive direction is still unpublished in the shipping build")
        let door = app.buttons["storage-switch.refresh-from-cloud"]
        XCTAssertTrue(reveal(door))
        XCTAssertTrue(door.isEnabled,
            "Direction (B) must not be fenced by the opposite direction's release bit")
        attach("Settings refresh-from-cloud — usable while the overwrite stays closed")
        openConfirmation("storage-switch.refresh-from-cloud")
        let comparison = app.staticTexts["storage-switch.refresh-from-cloud-comparison"]
        XCTAssertTrue(reveal(comparison))
        XCTAssertTrue(comparison.label.contains("iCloud: テーマ"), "saw: \(comparison.label)")
        // transfer-03. This direction ships and deletes THIS iPhone's side, so
        // the shipping build counts it before the acknowledgement.
        XCTAssertTrue(comparison.label.contains("このiPhone: テーマ12・記録480・成果36"),
            "saw: \(comparison.label)")
        assertUncheckedDatasetConfirmation("refresh-from-cloud")
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.navigationBars["iCloudと保存先の変更"].waitForExistence(timeout: 4))
        app.navigationBars["iCloudと保存先の変更"].buttons["キャンセル"].tap()
        assertNoOperation()
        assertNoDatasetRequest()
    }

    func testSettingsRefreshNeedsItsOwnAcknowledgmentAndRecordsOneRequest() {
        launch("cloudDatasetDoors")
        openChoices()
        openConfirmation("storage-switch.refresh-from-cloud")
        let refreshWarning = app.staticTexts["storage-switch.refresh-from-cloud-warning"]
        XCTAssertTrue(reveal(refreshWarning))
        XCTAssertTrue(refreshWarning.label.contains("未送信の端末データは失われ"))
        XCTAssertTrue(refreshWarning.label.contains("iCloudのデータは残ります"))
        XCTAssertTrue(reveal(app.staticTexts["storage-switch.refresh-from-cloud-relaunch"]))
        XCTAssertTrue(reveal(app.staticTexts["storage-switch.refresh-from-cloud-comparison"]))
        assertUncheckedDatasetConfirmation("refresh-from-cloud")
        acknowledgeDataset("refresh-from-cloud")
        attach("Settings refresh-from-cloud — acknowledged final confirmation")
        app.buttons["storage-switch.refresh-from-cloud-confirm"].doubleTap()
        assertDatasetRequested("refreshFromCloud")
    }

    /// W6. An account with records in iCloud but NO transfer control record —
    /// the ordinary state of an account that was never transferred. Both doors
    /// stay usable; the comparison names the absence instead of printing a
    /// 「最終」 row that implies a lineage, and the device → iCloud confirmation
    /// says the operation STARTS a lineage rather than replacing one.
    func testSettingsDoorsStayUsableForAnAccountWithNoTransferLedger() {
        launch("cloudDatasetDoorsNoLineage")
        openChoices()
        openConfirmation("storage-switch.overwrite-cloud")
        let comparison = app.staticTexts["storage-switch.overwrite-cloud-comparison"]
        XCTAssertTrue(reveal(comparison))
        XCTAssertTrue(comparison.label.contains("このiPhone: テーマ"))
        XCTAssertTrue(comparison.label.contains("iCloud: テーマ9・記録312・成果28"), "saw: \(comparison.label)")
        XCTAssertFalse(comparison.label.contains("iCloud: テーマ9・記録312・成果28（最終"),
            "A dataset with no ledger must not print a 「最終」 row that implies one")
        XCTAssertFalse(comparison.label.contains("管理情報"))
        let starts = app.staticTexts["storage-switch.overwrite-cloud-starts-lineage"]
        XCTAssertTrue(reveal(starts))
        XCTAssertTrue(starts.label.contains("新しく使い始める"))
        assertUncheckedDatasetConfirmation("overwrite-cloud")
        acknowledgeDataset("overwrite-cloud")
        attach("Settings overwrite — an account with no transfer ledger")
        app.buttons["storage-switch.overwrite-cloud-confirm"].doubleTap()
        // One request, recorded through the SAME durable mechanism; the launch
        // host dispatches it to `startCloudLineageFromDevice`.
        assertDatasetRequested("overwriteCloudFromDevice")
    }

    /// PLAN §3 S9. The two opposite directions destroy opposite datasets, so
    /// acknowledging one must never arm the other. Each confirmation owns its
    /// own state and every presentation starts unchecked.
    func testSettingsDatasetDirectionsNeverShareAnAcknowledgment() {
        launch("cloudDatasetDoors")
        openChoices()
        openConfirmation("storage-switch.overwrite-cloud")
        acknowledgeDataset("overwrite-cloud")
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.navigationBars["iCloudと保存先の変更"].waitForExistence(timeout: 4))
        openConfirmation("storage-switch.refresh-from-cloud")
        assertUncheckedDatasetConfirmation("refresh-from-cloud")
        acknowledgeDataset("refresh-from-cloud")
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.navigationBars["iCloudと保存先の変更"].waitForExistence(timeout: 4))
        openConfirmation("storage-switch.overwrite-cloud")
        assertUncheckedDatasetConfirmation("overwrite-cloud")
        attach("Settings dataset doors — isolated acknowledgments")
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.navigationBars["iCloudと保存先の変更"].waitForExistence(timeout: 4))
        app.navigationBars["iCloudと保存先の変更"].buttons["キャンセル"].tap()
        assertNoDatasetRequest()
        assertNoOperation()
    }

    func testAX5SettingsRefreshDoorAndConfirmationRemainReachableAndDescribed() throws {
        launch("cloudDatasetDoors", accessibility5: true)
        openChoices()
        let door = app.buttons["storage-switch.refresh-from-cloud"]
        XCTAssertTrue(reveal(door))
        assertTouchTarget(door)
        XCTAssertTrue(door.isEnabled)
        attach("AX5 Settings refresh-from-cloud — reachable door")
        openConfirmation("storage-switch.refresh-from-cloud")
        let checkbox = app.switches["storage-switch.refresh-from-cloud-confirm-data-loss"]
        XCTAssertTrue(reveal(checkbox))
        assertTouchTarget(checkbox)
        XCTAssertGreaterThan(checkbox.frame.height, 100,
            "The modal must actually inherit AX5, not silently reset to normal text")
        acknowledgeDataset("refresh-from-cloud")
        let confirm = app.buttons["storage-switch.refresh-from-cloud-confirm"]
        XCTAssertTrue(reveal(confirm))
        assertTouchTarget(confirm)
        attach("AX5 Settings refresh-from-cloud — explicit acknowledgment and action")
        try auditDescriptionsAndTraits()
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        app.navigationBars["iCloudと保存先の変更"].buttons["キャンセル"].tap()
        assertNoDatasetRequest()
        assertNoOperation()
    }

    /// settings-03 / transfer-09. The disabled iCloud reset leads somewhere:
    /// a page naming the in-app route to start over and the iOS route to
    /// delete iCloud data, with an export first. It starts nothing itself.
    func testTheDisabledICloudResetPointsToTheRoutesThatWork() {
        launch("cloudResetGuidance")
        let row = app.buttons["settings.activity-reset-alternatives"]
        XCTAssertTrue(reveal(row))
        row.tap()
        XCTAssertTrue(app.navigationBars["記録を消す・やり直す方法"].waitForExistence(timeout: 4))
        let startOver = app.staticTexts["settings.reset-guidance.start-over"]
        XCTAssertTrue(reveal(startOver))
        XCTAssertTrue(startOver.label.contains("「iCloudと保存先の変更」"))
        XCTAssertTrue(startOver.label.contains("「このiPhoneへ引き継ぐ」"))
        let delete = app.staticTexts["settings.reset-guidance.delete"]
        XCTAssertTrue(reveal(delete))
        XCTAssertTrue(delete.label.contains("元に戻せません"))
        attach("Settings — where the disabled iCloud reset points")
        let export = app.buttons["settings.reset-guidance.export"]
        XCTAssertTrue(reveal(export))
        export.tap()
        let state = app.staticTexts["settings.reset-guidance.fixture-state"]
        app.navigationBars["記録を消す・やり直す方法"].buttons.firstMatch.tap()
        XCTAssertTrue(reveal(state))
        XCTAssertEqual(state.label, "guidanceExports=1")
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
        XCTAssertFalse(app.staticTexts["通信が戻るのを待っています"].exists)
        XCTAssertFalse(app.buttons["cloud-offline-continue"].exists)
        XCTAssertFalse(app.buttons["storage-transfer-recover"].exists)
        XCTAssertFalse(app.buttons["iCloudに保存して同期"].exists)
        let explanation = app.staticTexts["cloud-launch-timeout-offline-explanation"]
        XCTAssertTrue(reveal(explanation))
        // quality-01. The retry is named, the automatic check after a lost
        // connection is promised, and relaunching is offered only for use
        // without any connection.
        XCTAssertTrue(explanation.label.contains("「オンラインで再試行」で確認し直せます"))
        XCTAssertTrue(explanation.label.contains("つながると自動で確認します"))
        XCTAssertTrue(explanation.label.contains("通信のない場所で使うときは"))
        XCTAssertTrue(explanation.label.contains("アプリは削除しないでください"))
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

    /// quality-01. Every iCloud waiting screen keeps the closed session's
    /// running focus visible — as a time and a phase only, the Live
    /// Activity's payload — and the offline wall leads with the automatic
    /// check instead of a relaunch.
    func testICloudWaitingScreensShowTheRunningFocusWithoutAccountData() {
        let screens: [(scenario: String, title: String)] = [
            ("cloudBackgroundReturnWithFocus", "準備中"),
            ("cloudOfflineWallWithFocus", "通信が戻るのを待っています"),
            ("cloudLaunchTimedOutWithFocus", "iCloudの確認に時間がかかっています"),
        ]
        for screen in screens {
            launch(screen.scenario)
            XCTAssertTrue(app.staticTexts[screen.title].waitForExistence(timeout: 4), screen.scenario)
            let card = app.descendants(matching: .any)["launch-timer-status"]
            XCTAssertTrue(card.waitForExistence(timeout: 4), screen.scenario)
            XCTAssertTrue(card.label.hasPrefix("集中は続いています。残り"), card.label)
            XCTAssertFalse(card.label.contains("テーマ"), "No theme, memo or mass on a wait screen")
            attach("waiting-\(screen.scenario)")
        }
        // The offline wall: the automatic check first, the manual retry kept,
        // and the relaunch only for immediate use without a connection.
        launch("cloudOfflineWallWithFocus")
        let message = app.staticTexts["storage-launch-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 4))
        XCTAssertTrue(message.label.hasPrefix("通信が戻ると自動で確認して"))
        XCTAssertFalse(app.staticTexts["オフラインで開くには再起動が必要です"].exists)
        let relaunch = app.staticTexts["cloud-offline-relaunch-explanation"]
        XCTAssertTrue(reveal(relaunch))
        XCTAssertTrue(relaunch.label.hasPrefix("すぐに通信なしで使うときは"))
        let retry = app.buttons["cloud-offline-online-retry"]
        XCTAssertTrue(reveal(retry, upwards: false))
        assertTouchTarget(retry)
        XCTAssertFalse(app.buttons["cloud-offline-continue"].exists,
                       "A process that opened a mirror never offers the .none door")
        assertNoOperation()
    }

    func testAX5OfflineWallKeepsTheTimerAndTheRetryReachable() throws {
        launch("cloudOfflineWallWithFocus", accessibility5: true)
        XCTAssertTrue(app.staticTexts["通信が戻るのを待っています"].waitForExistence(timeout: 4))
        let card = app.descendants(matching: .any)["launch-timer-status"]
        XCTAssertTrue(card.waitForExistence(timeout: 4))
        XCTAssertTrue(reveal(card))
        attach("waiting-offline-wall-ax5-timer")
        let retry = app.buttons["cloud-offline-online-retry"]
        XCTAssertTrue(reveal(retry, upwards: false))
        assertTouchTarget(retry)
        attach("waiting-offline-wall-ax5-retry")
        try auditDescriptionsAndTraits()
        retry.tap()
        let retried = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "retryCalls=1"),
            object: app.staticTexts["cloud-launch-timeout.fixture-state"])
        XCTAssertEqual(XCTWaiter.wait(for: [retried], timeout: 4), .completed)
    }

    /// sync-04. The iCloud section reports what the store's own mirroring
    /// said: the last send, full iCloud storage, and failures that repeat.
    func testICloudSettingsShowsLastSendQuotaAndRepeatedExportFailures() {
        launch("cloudExportHealthy")
        let lastExport = app.descendants(matching: .any)["settings.icloud.last-export"]
        XCTAssertTrue(lastExport.waitForExistence(timeout: 8))
        XCTAssertTrue(lastExport.label.contains("iCloudへの最終送信："), lastExport.label)
        XCTAssertTrue(lastExport.label.contains("分前"), lastExport.label)
        XCTAssertFalse(app.descendants(matching: .any)["settings.icloud.quota.open-settings"].exists)
        attach("icloud-settings-last-send")

        launch("cloudExportQuota")
        let status = app.descendants(matching: .any)["settings.icloud.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        let quota = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "iCloudの空き容量が不足しています"),
                                              object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [quota], timeout: 8), .completed, status.label)
        XCTAssertTrue(status.label.contains("記録はこのiPhoneに保存されています"))
        XCTAssertTrue(reveal(app.staticTexts["settings.icloud.quota.hint"]))
        let open = app.buttons["settings.icloud.quota.open-settings"]
        XCTAssertTrue(reveal(open, upwards: false))
        assertTouchTarget(open)
        XCTAssertFalse(app.descendants(matching: .any)["settings.icloud.last-export"].exists,
                       "A stale last-send time is not shown beside a storage problem")
        attach("icloud-settings-quota")

        launch("cloudExportFailing")
        let failingStatus = app.descendants(matching: .any)["settings.icloud.status"]
        XCTAssertTrue(failingStatus.waitForExistence(timeout: 8))
        let failing = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "iCloudへの送信がうまくいっていません"),
            object: failingStatus)
        XCTAssertEqual(XCTWaiter.wait(for: [failing], timeout: 8), .completed, failingStatus.label)
        XCTAssertTrue(failingStatus.label.contains("自動で再試行しています"), failingStatus.label)
        XCTAssertFalse(failingStatus.label.contains("iCloudに接続できます"),
                       "No 「接続できます」 checkmark above a sending problem")
        attach("icloud-settings-export-failing")
        assertNoOperation()
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
        assertCompactOfflineBanner(expectsRetry: false, syncStopped: true)
        let entry = app.buttons["cloud-offline-recovery-details"]
        XCTAssertTrue(entry.isHittable)
        assertTouchTarget(entry)
        entry.tap()
        XCTAssertTrue(app.navigationBars["同期の状態"].waitForExistence(timeout: 4))
        // device-01. A session opened from a stop screen does not resume on
        // its own, so neither the banner nor its details say 「待機中」.
        let title = app.staticTexts["cloud-offline-details-title"]
        XCTAssertTrue(reveal(title))
        XCTAssertEqual(title.label, "このiPhoneに保存・iCloud同期は停止中")
        let disclosure = app.staticTexts["cloud-offline-recovery-disclosure"]
        XCTAssertTrue(reveal(disclosure))
        XCTAssertTrue(disclosure.label.contains("データの置き換えや削除には、その後の確認が必要です"))
        closeOfflineDetails()
        // Settings' own status row agrees with the banner.
        XCTAssertTrue(reveal(text(containing: "通信が戻っても同期は自動では再開しません")))
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
        assertCompactOfflineBanner(expectsRetry: false, syncStopped: true)
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
        assertCompactOfflineBanner(expectsRetry: false, syncStopped: true)
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

    private func assertCompactOfflineBanner(expectsRetry: Bool = true, syncStopped: Bool = false) {
        let details = app.buttons["cloud-offline-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 4))
        XCTAssertTrue(details.isHittable)
        XCTAssertEqual(details.label, syncStopped
            ? "このiPhoneに保存・iCloud同期は停止中。詳細を表示"
            : "このiPhoneに保存・iCloud同期は待機中。詳細を表示")
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
        XCTAssertEqual(entry.label, "iCloudと保存先の変更")
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
        XCTAssertFalse(app.buttons["storage-switch.refresh-from-cloud"].exists)
        XCTAssertFalse(app.buttons["storage-switch.refresh-from-cloud-confirm"].exists)
        assertNoDatasetRequest()
    }

    private var datasetState: XCUIElement { app.staticTexts["storage-switch.dataset-fixture-state"] }

    private func assertPreviewReads(_ count: Int) {
        let state = app.staticTexts["storage-switch.preview-fixture-state"]
        XCTAssertTrue(reveal(state))
        let matched = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "previewCalls=\(count)"), object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 6), .completed,
            "Expected previewCalls=\(count), saw \(state.label)")
    }

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
    /// `upwards` is the first guess at where the element lies. When that scan
    /// ends at a list edge without finding it — an AX5 row that grew moves
    /// everything below it — the opposite direction is scanned before failing.
    private func reveal(_ element: XCUIElement, upwards: Bool = true) -> Bool {
        if scan(element, upwards: upwards) { return true }
        return scan(element, upwards: !upwards)
    }

    private func scan(_ element: XCUIElement, upwards: Bool) -> Bool {
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
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Also written as a PNG for review when the runner is given a folder.
        guard let directory = ProcessInfo.processInfo.environment["POMOGEM_SHOTS_DIR"] else { return }
        let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(String(safe) + ".png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
