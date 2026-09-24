import XCTest

/// The launch-host screens a device that was fenced out of the current iCloud
/// generation actually lands on. These tests drive the shipping
/// `PersistenceLaunchStatusView` through a Debug simulator-only recorder: no
/// journal, container, account or CloudKit call exists in the process, so a
/// passing run is also evidence that reading these screens starts nothing.
@MainActor
final class StorageTransferOverwriteLaunchUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0, let app {
            attach("Overwrite launch UI failure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Overwrite launch failure accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app?.terminate()
    }

    // MARK: - 1. Two symmetric doors, two independent consents

    /// Runs against the PUBLISHED screen (`datasetRefreshOtherDevices`), where
    /// the overwrite door can actually open. Against the shipping scenario the
    /// door is unconditionally disabled by the release bit, so every assertion
    /// below would hold for a reason that has nothing to do with consent — the
    /// S9 property would be certified by a test that cannot fail for it.
    func testBothDirectionsAreOfferedWithIndependentConsentsAndNeitherStartsAnything() {
        launch("datasetRefreshOtherDevices")
        let refresh = app.buttons["storage-refresh-confirm"]
        let overwrite = app.buttons["storage-overwrite-confirm"]
        XCTAssertTrue(reveal(refresh))
        XCTAssertTrue(reveal(overwrite, upwards: false))
        XCTAssertFalse(refresh.isEnabled, "The iCloud → device door starts unconsented")
        XCTAssertTrue(overwrite.isEnabled,
            "The premise of this test: on the published screen this door CAN open")

        // Ticking the device-side acknowledgement must not pre-arm the sheet's
        // own, opposite acknowledgement.
        acknowledge("storage-refresh-confirm-data-loss")
        XCTAssertTrue(reveal(refresh))
        XCTAssertTrue(refresh.isEnabled)
        openOverwriteSheet()
        let sheetToggle = app.switches["storage-overwrite-confirm-data-loss"]
        XCTAssertTrue(reveal(sheetToggle))
        XCTAssertEqual(sheetToggle.value as? String, "0",
            "端末データの削除を確認しました must never arm iCloudを置き換える")
        let sheetConfirm = app.buttons["storage-overwrite-sheet-confirm"]
        XCTAssertTrue(reveal(sheetConfirm, upwards: false))
        XCTAssertFalse(sheetConfirm.isEnabled,
            "One acknowledgement must not authorize the opposite, destructive direction")
        attach("Dataset refresh — both doors with separate acknowledgements")

        // And the reverse: consenting on the sheet leaves the first screen's
        // own toggle exactly as the user left it, and starts nothing.
        acknowledge("storage-overwrite-confirm-data-loss")
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.buttons["storage-overwrite-confirm"].waitForExistence(timeout: 4))
        let refreshToggle = app.switches["storage-refresh-confirm-data-loss"]
        XCTAssertTrue(reveal(refreshToggle))
        XCTAssertEqual(refreshToggle.value as? String, "1")
        openOverwriteSheet()
        XCTAssertTrue(reveal(app.switches["storage-overwrite-confirm-data-loss"]))
        XCTAssertEqual(app.switches["storage-overwrite-confirm-data-loss"].value as? String, "0",
            "戻る discards the destructive acknowledgement; it is never remembered")
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.buttons["storage-overwrite-confirm"].waitForExistence(timeout: 4))
        assertNoOperation()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0)
    }

    /// The shipping build still offers the door and refuses it, stating only
    /// its reason (transfer-08, as in Settings). The door that deletes nothing
    /// comes before it (review of transfer-04 / device-01).
    func testTheShippingBuildShowsTheOverwriteDoorDisabledWithItsReason() {
        launch("datasetRefreshChoice")
        let overwrite = app.buttons["storage-overwrite-confirm"]
        XCTAssertTrue(reveal(overwrite, upwards: false))
        XCTAssertFalse(overwrite.isEnabled)
        let reason = app.staticTexts["storage-overwrite-unavailable"]
        XCTAssertTrue(reveal(reason))
        XCTAssertTrue(reason.label.contains("いまは利用できません"))
        XCTAssertFalse(reason.label.contains("削除していません"),
            "Nobody pressed a closed door; its reason reports no event")
        XCTAssertFalse(app.staticTexts["storage-overwrite-data-loss-warning"].exists,
            "The long irreversible-deletion warning belongs to a door that can open")
        XCTAssertFalse(app.staticTexts["storage-overwrite-other-devices"].exists)
        // transfer-03. 「iCloudから再取得」 deletes THIS side and ships, so this
        // iPhone is counted in every build now.
        let comparison = app.staticTexts["storage-dataset-comparison"]
        XCTAssertTrue(reveal(comparison))
        XCTAssertTrue(comparison.label.contains("このiPhone: テーマ12・記録480・成果36"), "saw: \(comparison.label)")
        XCTAssertTrue(comparison.label.contains("iCloud: テーマ9・記録312・成果28"))
        XCTAssertFalse(comparison.label.contains("確認できませんでした"))
        XCTAssertFalse(app.staticTexts["storage-refresh-empty-cloud"].exists,
            "iCloud holds the user's records here")
        // The offline door deletes nothing, says what a later refresh does to
        // what is recorded meanwhile, and sits above the closed door.
        let offlineExplanation = app.staticTexts["storage-refresh-offline-explanation"]
        XCTAssertTrue(reveal(offlineExplanation))
        XCTAssertTrue(offlineExplanation.label.contains("同期は止まったまま"))
        XCTAssertTrue(offlineExplanation.label.contains("「iCloudから再取得」を選ぶと、オフラインで記録した変更も削除されます"))
        let offline = app.buttons["cloud-offline-continue"]
        XCTAssertTrue(reveal(offline))
        XCTAssertLessThan(offline.frame.minY, app.buttons["storage-overwrite-confirm"].frame.minY)
        overwrite.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.navigationBars["最後の確認"].exists)
        // PLAN Step 6: the raw and the FILTERED witness count are both stated,
        // so a writer the ignore list moved is visible as moved, not as absent.
        XCTAssertTrue(reveal(writerState, upwards: false))
        XCTAssertEqual(writerState.label, "others=0;ignored=1")
        attach("Dataset refresh — shipping build keeps the overwrite closed")
        assertNoOperation()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0)
    }

    // MARK: - 2. The comparison, and the read that gates the destructive door

    func testComparisonShowsBothSidesAndDisclosesOtherDevicesAsEvidence() {
        launch("datasetRefreshOtherDevices")
        let comparison = app.staticTexts["storage-dataset-comparison"]
        XCTAssertTrue(reveal(comparison))
        XCTAssertTrue(comparison.label.contains("このiPhone"))
        XCTAssertTrue(comparison.label.contains("iCloud"))
        XCTAssertTrue(comparison.label.contains("テーマ"))
        XCTAssertTrue(comparison.label.contains("記録"))

        let evidence = app.staticTexts["storage-overwrite-other-devices"]
        XCTAssertTrue(reveal(evidence))
        XCTAssertTrue(evidence.label.contains("このiPhone以外の端末"))
        XCTAssertTrue(evidence.label.contains("未送信"))

        let warning = app.staticTexts["storage-overwrite-data-loss-warning"]
        XCTAssertTrue(reveal(warning))
        XCTAssertTrue(warning.label.contains("2つのデータは結合しません"))
        XCTAssertTrue(warning.label.contains("元に戻すことはできません"))
        attach("Dataset refresh — comparison and other-device evidence")
        assertNoOperation()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0)
    }

    /// On the published screen: a shipping build's closed door states only
    /// its reason, so the evidence is read after the named re-read succeeds.
    func testNoOtherDeviceIsStatedAsAbsenceOfEvidenceNotAsAGuarantee() {
        launch("datasetRefreshPreviewFailed")
        let retry = app.buttons["storage-dataset-retry-preview"]
        XCTAssertTrue(reveal(retry))
        retry.tap()
        let evidence = app.staticTexts["storage-overwrite-other-devices"]
        XCTAssertTrue(reveal(evidence))
        XCTAssertTrue(evidence.label.contains("見つかりませんでした"))
        XCTAssertTrue(evidence.label.contains("証明ではありません"),
            "Absence of evidence must never be phrased as proof that no other device exists")
        attach("Dataset refresh — no witnessed device, stated as absence of evidence")
        assertNoOperation()
    }

    func testPreviewFailureKeepsTheOverwriteDoorDisabledAndSaysNothingWasDeleted() {
        launch("datasetRefreshPreviewFailed")
        let comparison = app.staticTexts["storage-dataset-comparison"]
        XCTAssertTrue(reveal(comparison))
        XCTAssertTrue(comparison.label.contains("iCloudの内容を確認できませんでした"))
        XCTAssertTrue(comparison.label.contains("どちらの記録も削除していません"))
        let overwrite = app.buttons["storage-overwrite-confirm"]
        XCTAssertTrue(reveal(overwrite, upwards: false))
        XCTAssertFalse(overwrite.isEnabled,
            "Nobody may authorize deleting contents the app failed to enumerate")
        overwrite.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.navigationBars["最後の確認"].exists)
        // S14 for the refresh too: it deletes THIS side, and nobody is asked
        // to do that on the strength of an iCloud read that never happened.
        acknowledge("storage-refresh-confirm-data-loss")
        let refresh = app.buttons["storage-refresh-confirm"]
        XCTAssertTrue(reveal(refresh))
        XCTAssertFalse(refresh.isEnabled,
            "An acknowledgement alone must not arm 「iCloudから再取得」 over an unread iCloud")
        attach("Dataset refresh — unreadable iCloud keeps both doors closed")
        assertNoOperation()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0)
    }

    /// The failure copy names a control. It has to be on this screen, and it
    /// has to work: without it the door stays closed for the rest of the launch
    /// and the only escape is force-quitting the app.
    func testTheNamedRetryControlExistsAndReArmsTheDoorAfterASuccessfulReRead() {
        launch("datasetRefreshPreviewFailed")
        let comparison = app.staticTexts["storage-dataset-comparison"]
        XCTAssertTrue(reveal(comparison))
        let named = "iCloudの内容をもう一度確認"
        XCTAssertTrue(comparison.label.contains("「\(named)」"),
            "The instruction must name the control this screen carries")
        // The screen's own 「もう一度試す」 re-runs the whole launch; the
        // sentence names the narrower control that re-reads iCloud only.
        XCTAssertFalse(comparison.label.contains("もう一度試す"),
            "The failure sentence names the re-read control, not the relaunch retry")

        let retry = app.buttons["storage-dataset-retry-preview"]
        XCTAssertTrue(reveal(retry))
        XCTAssertEqual(retry.label, named)
        XCTAssertTrue(retry.isEnabled)
        attach("Dataset refresh — the re-read control the failure copy names")
        retry.tap()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0, previewRetries: 1)

        // The successful re-read replaces the failure sentence with the real
        // comparison and re-arms the door it was gating.
        let rearmed = app.staticTexts["storage-dataset-comparison"]
        XCTAssertTrue(reveal(rearmed))
        XCTAssertTrue(rearmed.label.contains("このiPhone"))
        XCTAssertTrue(rearmed.label.contains("テーマ"))
        XCTAssertFalse(rearmed.label.contains("確認できませんでした"))
        XCTAssertFalse(app.buttons["storage-dataset-retry-preview"].exists,
            "A succeeded read is not offered a re-read")
        let overwrite = app.buttons["storage-overwrite-confirm"]
        XCTAssertTrue(reveal(overwrite, upwards: false))
        XCTAssertTrue(overwrite.isEnabled)
        attach("Dataset refresh — the re-read re-arms the door")
        assertNoOperation()
    }

    // MARK: - 3. The final confirmation sheet

    func testFinalConfirmationNeedsItsOwnAcknowledgementAndBackStartsNothing() {
        launch("datasetRefreshOtherDevices")
        openOverwriteSheet()
        XCTAssertTrue(reveal(app.staticTexts["storage-overwrite-warning"]))
        let recoveryCopy = app.staticTexts["storage-overwrite-recovery-copy"]
        XCTAssertTrue(reveal(recoveryCopy))
        XCTAssertTrue(recoveryCopy.label.contains("復旧用コピー"))
        let relaunch = app.staticTexts["storage-overwrite-relaunch"]
        XCTAssertTrue(reveal(relaunch))
        XCTAssertTrue(relaunch.label.contains("アプリ自体は削除しないでください"))
        let notCancellable = app.staticTexts["storage-overwrite-not-cancellable"]
        XCTAssertTrue(reveal(notCancellable))
        XCTAssertTrue(notCancellable.label.contains("取り消せません"))
        XCTAssertTrue(reveal(app.staticTexts["storage-overwrite-screen-time"]))
        let sheetEvidence = app.staticTexts["storage-overwrite-sheet-other-devices"]
        XCTAssertTrue(reveal(sheetEvidence))
        XCTAssertTrue(sheetEvidence.label.contains("2台"),
            "The last screen before deletion must restate how many other devices wrote here")

        let confirm = app.buttons["storage-overwrite-sheet-confirm"]
        let toggle = app.switches["storage-overwrite-confirm-data-loss"]
        XCTAssertTrue(reveal(toggle))
        XCTAssertEqual(toggle.value as? String, "0",
            "Reading the explanation is never consent")
        XCTAssertTrue(reveal(confirm, upwards: false))
        XCTAssertFalse(confirm.isEnabled)
        attach("Final confirmation — unchecked acknowledgement")

        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.buttons["storage-overwrite-confirm"].waitForExistence(timeout: 4))
        assertNoOperation()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0)

        // Re-opening must not remember the previous screen's acknowledgement.
        openOverwriteSheet()
        XCTAssertTrue(reveal(app.switches["storage-overwrite-confirm-data-loss"]))
        XCTAssertEqual(app.switches["storage-overwrite-confirm-data-loss"].value as? String, "0")
        acknowledge("storage-overwrite-confirm-data-loss")
        let armed = app.buttons["storage-overwrite-sheet-confirm"]
        XCTAssertTrue(reveal(armed, upwards: false))
        XCTAssertTrue(armed.isEnabled)
        attach("Final confirmation — explicit acknowledgement arms the replacement")
        armed.tap()
        assertOverwriteFixture(refresh: 0, overwrite: 1, export: 0)
    }

    /// transfer-03, the shipping build. 「iCloudから再取得」 deletes THIS iPhone's
    /// side, so before its acknowledgement can arm it the screen counts both
    /// sides, warns — with this iPhone's counts — when iCloud holds none of
    /// the user's records, offers the export, and discloses the Screen Time
    /// reset. The warning ends 「中止して…」, so the door is not the amber one.
    func testTheShippingRefreshCountsBothSidesAndSaysSoWhenICloudIsEmpty() {
        launch("datasetRefreshEmptyCloud")
        let comparison = app.staticTexts["storage-dataset-comparison"]
        XCTAssertTrue(reveal(comparison))
        XCTAssertTrue(comparison.label.contains("このiPhone: テーマ12・記録480・成果36"), "saw: \(comparison.label)")
        XCTAssertTrue(comparison.label.contains("iCloud: テーマ5・記録0・成果0"), "saw: \(comparison.label)")
        let empty = app.staticTexts["storage-refresh-empty-cloud"]
        XCTAssertTrue(reveal(empty))
        XCTAssertTrue(empty.label.contains("1件も見つかりませんでした"), "saw: \(empty.label)")
        XCTAssertTrue(empty.label.contains("このiPhoneのテーマ12・記録480・成果36"), "saw: \(empty.label)")
        let screenTime = app.staticTexts["storage-refresh-screen-time"]
        XCTAssertTrue(reveal(screenTime))
        XCTAssertTrue(screenTime.label.hasPrefix("スクリーンタイムの自動記録を使っている場合"))
        XCTAssertTrue(reveal(app.buttons["storage-refresh-export"]))
        attach("Dataset refresh — iCloud holds none of the user's records")

        let refresh = app.buttons["storage-refresh-confirm"]
        XCTAssertTrue(reveal(refresh))
        XCTAssertFalse(refresh.isEnabled, "Reading the evidence is never consent")
        for evidence in [empty, screenTime] {
            XCTAssertLessThan(evidence.frame.minY, app.switches["storage-refresh-confirm-data-loss"].frame.minY,
                "Every disclosure comes before the acknowledgement")
        }
        acknowledge("storage-refresh-confirm-data-loss")
        XCTAssertTrue(reveal(refresh))
        XCTAssertTrue(refresh.isEnabled)
        refresh.tap()
        assertOverwriteFixture(refresh: 1, overwrite: 0, export: 0)
        assertNoOperation()
    }

    // MARK: - 4. `.blocked` explains, it does not offer

    func testBlockedOffersNoDestructiveActionButExplainsWhatComesNext() {
        launch("datasetRefreshBlocked")
        XCTAssertTrue(app.staticTexts["保存領域を確認できません"].waitForExistence(timeout: 8))
        let message = app.staticTexts["storage-launch-message"]
        XCTAssertTrue(reveal(message))
        XCTAssertTrue(message.label.contains("どちらの記録も削除していません"))
        let explanation = app.staticTexts["storage-refresh-blocked-explanation"]
        XCTAssertTrue(reveal(explanation))
        XCTAssertTrue(explanation.label.contains("もう一度試す"))
        XCTAssertFalse(explanation.label.contains("通信を確認"),
            "transfer-06: the message above already says it; the caption only adds what comes next")
        XCTAssertFalse(app.buttons["storage-refresh-confirm"].exists,
            "A screen that could not read the terminal control record has no lineage to act on")
        XCTAssertFalse(app.buttons["storage-overwrite-confirm"].exists)
        XCTAssertFalse(app.switches["storage-overwrite-confirm-data-loss"].exists)
        XCTAssertTrue(reveal(app.buttons["もう一度試す"]))
        attach("Blocked — explanation without any destructive affordance")
        assertNoOperation()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0)
    }

    /// transfer-06 / launch-05. Every other producer of the generic screen —
    /// here an account mismatch — shows only its own message. A promise that
    /// 「もう一度試す」 re-fetches iCloud data is false there.
    func testTheGenericBlockedScreenShowsOnlyItsOwnMessage() {
        launch("launchBlockedGeneric")
        XCTAssertTrue(app.staticTexts["保存領域を確認できません"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["storage-refresh-blocked-explanation"].exists)
        let message = app.staticTexts["storage-launch-message"]
        XCTAssertTrue(reveal(message))
        XCTAssertFalse(message.label.contains("再取得"), "saw: \(message.label)")
        XCTAssertTrue(reveal(app.buttons["もう一度試す"]))
        attach("Blocked — generic producer, no refresh caption")
        assertNoOperation()
    }

    // MARK: - 5. The non-destructive rescue door

    func testExportBeforeReplacingIsOfferedAndIsNonDestructive() {
        launch("datasetRefreshChoice")
        let export = app.buttons["storage-refresh-export"]
        XCTAssertTrue(reveal(export, upwards: false))
        XCTAssertTrue(export.isEnabled, "The rescue door must not require a data-loss acknowledgement")
        let note = app.staticTexts["storage-refresh-export-note"]
        XCTAssertTrue(reveal(note))
        XCTAssertTrue(note.label.contains("ポモジェムに読み込めません"))
        attach("Dataset refresh — non-destructive export before either replacement")
        XCTAssertTrue(reveal(export, upwards: false))
        export.tap()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 1)
        // Writing a copy out is not a transfer: no storage operation is recorded.
        assertNoOperation()
    }

    // MARK: - 6. While the replacement runs

    func testReplacementInProgressShowsPhaseCopyAndNoCancelControl() {
        launch("overwriteInProgress")
        let progress = app.staticTexts["storage-overwrite-progress"]
        XCTAssertTrue(reveal(progress))
        XCTAssertTrue(progress.label.contains("iCloudのデータを置き換えています"))
        XCTAssertTrue(progress.label.contains("続きから再開します"))
        let notCancellable = app.staticTexts["storage-overwrite-not-cancellable"]
        XCTAssertTrue(reveal(notCancellable))
        XCTAssertTrue(notCancellable.label.contains("取り消せません"))
        XCTAssertFalse(app.buttons["storage-transfer-cancel-local"].exists,
            "Past preparingDestination the operation is not cancellable")
        XCTAssertFalse(app.buttons["storage-overwrite-confirm"].exists)
        XCTAssertFalse(app.buttons["storage-refresh-confirm"].exists)
        attach("Replacement in progress — phase copy without a cancel control")
        assertNoOperation()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0)
    }

    /// transfer-04. A planned continuation of 「iCloudから再取得」 is progress,
    /// not an interruption, and says what is happening in this phase.
    func testAPlannedContinuationIsShownAsProgressNotAsAnInterruption() {
        launch("refreshInProgress")
        XCTAssertTrue(app.staticTexts["保存先の切り替えを続けています"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["中断された保存先の切り替えを再開しています"].exists)
        let progress = app.staticTexts["storage-transfer-progress"]
        XCTAssertTrue(reveal(progress))
        XCTAssertTrue(progress.label.contains("iCloudからデータを受け取っています"), "saw: \(progress.label)")
        XCTAssertFalse(app.staticTexts["storage-overwrite-not-cancellable"].exists,
            "The replacement's warning belongs to the replacement only")
        attach("Refresh continuing — phase copy")
        assertNoOperation()
    }

    /// transfer-04. The relaunch screen has no button on purpose; it says how
    /// to relaunch and, on the last step, that the next launch completes it.
    func testTheFinalRelaunchSaysHowAndThatItIsTheLastOne() {
        launch("relaunchFinal")
        let final = app.staticTexts["storage-transfer-relaunch-final"]
        XCTAssertTrue(final.waitForExistence(timeout: 8))
        XCTAssertTrue(final.label.contains("次に開くと"))
        let instructions = app.staticTexts["storage-transfer-relaunch-required"]
        XCTAssertTrue(reveal(instructions))
        XCTAssertTrue(instructions.label.contains("Appスイッチャー"), "saw: \(instructions.label)")
        XCTAssertTrue(instructions.label.contains("ポモジェムを上にスワイプ"),
            "The App Switcher card shows the Home Screen name, not the Latin brand")
        let message = app.staticTexts["storage-launch-message"]
        XCTAssertTrue(reveal(message))
        XCTAssertTrue(message.label.contains("Appスイッチャー"))
        // Said once on the screen: the message already carries it.
        XCTAssertTrue(message.label.contains("アプリ自体は削除しないでください"))
        XCTAssertFalse(instructions.label.contains("アプリ自体は削除しないでください"))
        attach("Relaunch — last step, with instructions")
        assertNoOperation()
    }

    /// No stop screen is a dead end: the remote-recovery screen keeps a
    /// re-check and support even while its resume door is closed.
    func testTheRemoteRecoveryScreenAlwaysOffersARecheck() {
        launch("remoteResumeClosed")
        let retry = app.buttons["storage-transfer-recovery-retry"]
        XCTAssertTrue(reveal(retry, upwards: false))
        XCTAssertTrue(retry.isEnabled)
        XCTAssertTrue(reveal(app.buttons["サポートを見る"], upwards: false))
        assertNoOperation()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0)
    }

    // MARK: - 5b. Resuming another installation's transaction

    /// PLAN §4: the flip is `allowsDatasetOverwriteFromDevice` and
    /// `allowsRemoteResumeBeforeReplacing`; `allowsCloudReplacement` stays
    /// false. The 「復旧を続ける」 door is governed by the resume bit, so raising
    /// ONLY that bit must open it — and the refusal it shows while the bit is
    /// closed must name that bit, not the legacy prohibition.
    func testRemoteResumeDoorFollowsItsOwnBitAndNamesItsOwnProhibition() {
        launch("remoteResumeClosed")
        let closed = app.buttons["storage-transfer-recover"]
        XCTAssertTrue(reveal(closed))
        XCTAssertFalse(closed.isEnabled)
        let reason = app.staticTexts["storage-transfer-recover-unavailable"]
        XCTAssertTrue(reveal(reason))
        XCTAssertTrue(reason.label.contains("別の端末が始めた置き換えを、このiPhoneからは再開できません"))
        XCTAssertFalse(reason.label.contains("iCloudの置き換えと、その復旧の再開は一時的に利用できません"),
            "The legacy prohibition no longer governs this action and must not be quoted here")
        closed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        attach("Remote recovery — refused, naming the gate that governs it")
        assertNoOperation()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0)

        launch("remoteResumeOpen")
        let open = app.buttons["storage-transfer-recover"]
        XCTAssertTrue(reveal(open))
        XCTAssertTrue(open.isEnabled,
            "Raising only allowsRemoteResumeBeforeReplacing must open the resume door")
        XCTAssertFalse(app.staticTexts["storage-transfer-recover-unavailable"].exists)
        attach("Remote recovery — the resume bit alone opens the door")
        open.tap()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0, recover: 1)
        assertNoOperation()
    }

    // MARK: - 6b. After the replacement: the one late-arrival comparison

    /// PLAN Step 9 / §6.5. `Docs/MultiDeviceCloudSafety.md` defect 1 cannot be
    /// prevented by this design; this banner is the only thing promised about
    /// it. It is non-blocking, hedged, and neither of its actions is
    /// destructive.
    func testLateArrivalIsDisclosedAsAPossibilityAndNeitherActionTouchesData() {
        launch("lateArrival")
        let banner = app.staticTexts["storage-overwrite-late-arrival"]
        XCTAssertTrue(reveal(banner))
        XCTAssertTrue(banner.label.contains("他の端末から古い記録が届いた可能性があります"),
            "A bounded detector must be phrased as a possibility, never as a fact")
        XCTAssertTrue(banner.label.contains("削除したはずのテーマが戻っていないか確認してください"))
        // Nothing on it is a destructive control.
        XCTAssertFalse(app.buttons["storage-overwrite-confirm"].exists)
        XCTAssertFalse(app.buttons["storage-refresh-confirm"].exists)
        attach("Late arrival — non-blocking disclosure after a committed replacement")

        let settings = app.buttons["storage-overwrite-late-arrival-settings"]
        XCTAssertTrue(reveal(settings))
        XCTAssertEqual(settings.label, "設定を開く")
        settings.tap()
        assertLateArrivalFixture(settingsCalls: 1, shown: true)

        let dismiss = app.buttons["storage-overwrite-late-arrival-dismiss"]
        XCTAssertTrue(reveal(dismiss))
        XCTAssertEqual(dismiss.label, "このまま使う")
        dismiss.tap()
        assertLateArrivalFixture(settingsCalls: 1, shown: false)
        XCTAssertFalse(app.staticTexts["storage-overwrite-late-arrival"].exists,
            "「このまま使う」 dismisses the banner and decides nothing about the data")
        attach("Late arrival — dismissed without any data decision")
        assertNoOperation()
    }

    // MARK: - 7. AX5

    func testAX5OverwriteDoorsAndFinalConfirmationRemainReachableAndDescribed() throws {
        launch("datasetRefreshOtherDevices", accessibility5: true)
        let comparison = app.staticTexts["storage-dataset-comparison"]
        XCTAssertTrue(reveal(comparison))
        XCTAssertGreaterThan(comparison.frame.width,
            app.windows.firstMatch.frame.width * 0.65,
            "The comparison must keep a readable line width instead of collapsing")
        attach("AX5 dataset refresh — comparison")

        // Top to bottom, in the order the screen lays them out, so each reveal
        // scrolls one way only: the export sits in the refresh door's own
        // section, above its button, and the overwrite door comes last.
        let export = app.buttons["storage-refresh-export"]
        XCTAssertTrue(reveal(export))
        assertTouchTarget(export)
        let refresh = app.buttons["storage-refresh-confirm"]
        XCTAssertTrue(reveal(refresh))
        assertTouchTarget(refresh)
        let overwrite = app.buttons["storage-overwrite-confirm"]
        XCTAssertTrue(reveal(overwrite))
        assertTouchTarget(overwrite)
        attach("AX5 dataset refresh — both doors and the rescue door reachable")
        try auditDescriptionsAndTraits()

        openOverwriteSheet(upwards: true)
        let toggle = app.switches["storage-overwrite-confirm-data-loss"]
        XCTAssertTrue(reveal(toggle))
        assertTouchTarget(toggle)
        XCTAssertGreaterThan(toggle.frame.height, 100,
            "The confirmation must actually inherit AX5, not silently reset to normal text")
        XCTAssertEqual(toggle.value as? String, "0")
        acknowledge("storage-overwrite-confirm-data-loss")
        let confirm = app.buttons["storage-overwrite-sheet-confirm"]
        XCTAssertTrue(reveal(confirm, upwards: false))
        assertTouchTarget(confirm)
        XCTAssertTrue(confirm.isEnabled)
        attach("AX5 final confirmation — acknowledgement and action reachable")
        try auditDescriptionsAndTraits()
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.buttons["storage-overwrite-confirm"].waitForExistence(timeout: 4))
        assertNoOperation()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0)
    }

    // MARK: - 5. P0-2 / device-01 — 「iCloudとの同期を止めています」

    /// The state the reported iPhone is actually in, in the SHIPPING build.
    /// device-01: the screen leads with what this build can run, describes
    /// each honestly, names no door it keeps shut, and starts nothing by
    /// being read.
    func testTheLineageScreenOffersOnlyWhatThisBuildCanRunAndStartsNothing() {
        launch("lineageUnavailable")
        XCTAssertTrue(app.staticTexts["iCloudとの同期を止めています"].waitForExistence(timeout: 6))
        let message = app.staticTexts["storage-launch-message"]
        XCTAssertTrue(reveal(message))
        for jargon in ["開発用", "配布用", "管理情報", "使い始める"] {
            XCTAssertFalse(message.label.contains(jargon), "saw: \(message.label)")
        }
        XCTAssertTrue(message.label.contains("削除していません"))

        // 1. Offline first, described as what it is.
        let offlineExplanation = app.staticTexts["storage-lineage-offline-explanation"]
        XCTAssertTrue(reveal(offlineExplanation, upwards: false))
        XCTAssertTrue(offlineExplanation.label.contains("iCloudへ送信せず"))
        XCTAssertTrue(offlineExplanation.label.contains("同期は止まったまま"),
            "saw: \(offlineExplanation.label)")
        XCTAssertFalse(offlineExplanation.label.contains("使い始める"),
            "The offline door may not promise a way back this build keeps shut")
        XCTAssertTrue(reveal(app.buttons["cloud-offline-continue"], upwards: false))

        // 2. The one way back to sync this build has, with both sides counted.
        let refreshExplanation = app.staticTexts["storage-lineage-refresh-explanation"]
        XCTAssertTrue(reveal(refreshExplanation, upwards: false))
        XCTAssertTrue(refreshExplanation.label.contains("iCloudのデータは削除しません"))
        // One operation, one name: the section is named after its button.
        XCTAssertTrue(app.staticTexts["iCloudから再取得"].exists)
        XCTAssertFalse(app.staticTexts["iCloudのデータを取り込み直す"].exists)
        let comparison = app.staticTexts["storage-lineage-comparison"]
        XCTAssertTrue(reveal(comparison, upwards: false))
        XCTAssertTrue(comparison.label.contains("このiPhone: テーマ12・記録480・成果36"),
            "The side this door deletes is counted, saw: \(comparison.label)")
        XCTAssertTrue(comparison.label.contains("iCloud: テーマ9・記録312・成果28"),
            "saw: \(comparison.label)")
        XCTAssertFalse(app.staticTexts["storage-lineage-refresh-empty-cloud"].exists,
            "This account's iCloud side holds the user's records")
        XCTAssertTrue(reveal(app.buttons["storage-refresh-export"], upwards: false))
        let refresh = app.buttons["storage-lineage-refresh"]
        XCTAssertTrue(reveal(refresh, upwards: false))
        XCTAssertTrue(refresh.isEnabled)

        // 3. Retry and support. No door the build keeps shut.
        let retry = app.buttons["storage-lineage-retry"]
        XCTAssertTrue(reveal(retry, upwards: false))
        XCTAssertTrue(retry.isEnabled)
        XCTAssertFalse(app.buttons["storage-lineage-start"].exists,
            "A shipping build does not show the start-from-device door at all")
        XCTAssertFalse(app.staticTexts["storage-lineage-start-unavailable"].exists)
        XCTAssertFalse(app.buttons["storage-refresh-confirm"].exists)
        XCTAssertFalse(app.buttons["storage-overwrite-confirm"].exists)
        attach("Lineage unavailable — shipping build, offline first and a way back")
        assertNoOperation()
        assertLineageFixture(lineage: 0, offline: 0, refresh: 0)
    }

    /// The least destructive choice comes first; the door that deletes this
    /// iPhone's side comes after it.
    func testTheShippingLineageScreenLeadsWithTheChoiceThatDeletesNothing() {
        launch("lineageUnavailable")
        let offline = app.buttons["cloud-offline-continue"]
        XCTAssertTrue(reveal(offline, upwards: false))
        let offlineY = offline.frame.minY
        let refresh = app.buttons["storage-lineage-refresh"]
        XCTAssertTrue(refresh.exists)
        XCTAssertLessThan(offlineY, refresh.frame.minY,
            "Offline use must lead; 「iCloudから再取得」 deletes this iPhone's side")
        offline.tap()
        assertLineageFixture(lineage: 0, offline: 1, refresh: 0)
    }

    /// 「iCloudから再取得」 on this screen is the SAME consented flow Settings
    /// ships: its own 「最後の確認」, both sides counted, an unchecked
    /// acknowledgement, and 「戻る」 discards it.
    func testTheLineageRefreshRequiresItsOwnAcknowledgementAndRequestsOnce() {
        launch("lineageUnavailable")
        let refresh = app.buttons["storage-lineage-refresh"]
        XCTAssertTrue(reveal(refresh, upwards: false))
        refresh.tap()
        XCTAssertTrue(app.navigationBars["最後の確認"].waitForExistence(timeout: 4))
        let warning = app.staticTexts["storage-switch.refresh-from-cloud-warning"]
        XCTAssertTrue(reveal(warning))
        XCTAssertTrue(warning.label.contains("未送信の端末データは失われ"))
        let comparison = app.staticTexts["storage-switch.refresh-from-cloud-comparison"]
        XCTAssertTrue(reveal(comparison))
        XCTAssertTrue(comparison.label.contains("このiPhone: テーマ12・記録480・成果36"))
        XCTAssertTrue(comparison.label.contains("iCloud: テーマ9・記録312・成果28"))
        // transfer-07. The switch resets Screen Time, and no Screen Time owner
        // is mounted on the launch host, so the sheet always carries the
        // conditional sentence — before the acknowledgement.
        let screenTime = app.staticTexts["storage-switch.refresh-from-cloud-screen-time"]
        XCTAssertTrue(reveal(screenTime, upwards: false))
        XCTAssertTrue(screenTime.label.hasPrefix("スクリーンタイムの自動記録を使っている場合"), "saw: \(screenTime.label)")
        XCTAssertTrue(screenTime.label.contains("黒い石は引き継ぎません"))
        let toggle = app.switches["storage-switch.refresh-from-cloud-confirm-data-loss"]
        XCTAssertTrue(reveal(toggle, upwards: false))
        XCTAssertLessThan(screenTime.frame.minY, toggle.frame.minY)
        XCTAssertEqual(toggle.value as? String, "0")
        let confirm = app.buttons["storage-switch.refresh-from-cloud-confirm"]
        XCTAssertTrue(reveal(confirm, upwards: false))
        XCTAssertFalse(confirm.isEnabled, "Opening the sheet is not consent")
        attach("Lineage refresh — 「最後の確認」 before acknowledgement")
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        waitForConfirmationToClose()
        XCTAssertTrue(app.buttons["storage-lineage-refresh"].waitForExistence(timeout: 4))
        assertLineageFixture(lineage: 0, offline: 0, refresh: 0)

        XCTAssertTrue(reveal(app.buttons["storage-lineage-refresh"], upwards: false))
        app.buttons["storage-lineage-refresh"].tap()
        XCTAssertTrue(app.navigationBars["最後の確認"].waitForExistence(timeout: 4))
        let reopened = app.switches["storage-switch.refresh-from-cloud-confirm-data-loss"]
        XCTAssertTrue(reveal(reopened, upwards: false))
        XCTAssertEqual(reopened.value as? String, "0", "戻る discards the acknowledgement")
        acknowledge("storage-switch.refresh-from-cloud-confirm-data-loss")
        let confirmAgain = app.buttons["storage-switch.refresh-from-cloud-confirm"]
        XCTAssertTrue(reveal(confirmAgain, upwards: false))
        XCTAssertTrue(confirmAgain.isEnabled)
        confirmAgain.tap()
        assertLineageFixture(lineage: 0, offline: 0, refresh: 1)
        assertNoOperation()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0)
    }

    /// The account whose iCloud side holds none of the user's records (app
    /// data deleted from iOS Settings). The way back would leave this iPhone
    /// with nothing, and both the screen and the sheet say so, with counts.
    func testTheLineageRefreshSaysSoWhenICloudHoldsNoneOfTheUsersRecords() {
        launch("lineageUnavailableEmptyCloud")
        let empty = app.staticTexts["storage-lineage-refresh-empty-cloud"]
        XCTAssertTrue(reveal(empty, upwards: false))
        XCTAssertTrue(empty.label.contains("1件も見つかりませんでした"), "saw: \(empty.label)")
        XCTAssertTrue(empty.label.contains("このiPhoneのテーマ12・記録480・成果36"), "saw: \(empty.label)")
        attach("Lineage refresh — iCloud holds none of the user's records")
        let refresh = app.buttons["storage-lineage-refresh"]
        XCTAssertTrue(reveal(refresh, upwards: false))
        refresh.tap()
        XCTAssertTrue(app.navigationBars["最後の確認"].waitForExistence(timeout: 4))
        let sheetEmpty = app.staticTexts["storage-switch.refresh-from-cloud-empty-cloud"]
        XCTAssertTrue(reveal(sheetEmpty))
        XCTAssertTrue(sheetEmpty.label.contains("元に戻すことはできません"))
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        waitForConfirmationToClose()
        XCTAssertTrue(reveal(app.buttons["storage-refresh-export"], upwards: false))
        app.buttons["storage-refresh-export"].tap()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 1)
        assertLineageFixture(lineage: 0, offline: 0, refresh: 0)
    }

    /// The published door. Nothing destructive may fire without the sheet's
    /// own acknowledgement, and 「戻る」 must discard it.
    func testTheLineageStartRequiresItsOwnAcknowledgement() {
        launch("lineageUnavailableEnabled")
        // review-2-5. Only a build that publishes the door states the choice.
        let message = app.staticTexts["storage-launch-message"]
        XCTAssertTrue(reveal(message))
        XCTAssertTrue(message.label.contains("オフラインのまま使うかを選べます"),
                      "saw: \(message.label)")
        let start = app.buttons["storage-lineage-start"]
        XCTAssertTrue(reveal(start, upwards: false))
        XCTAssertTrue(start.isEnabled, "The premise of this test: this door CAN open")
        start.tap()
        XCTAssertTrue(app.navigationBars["最後の確認"].waitForExistence(timeout: 4))

        let warning = app.staticTexts["storage-lineage-warning"]
        XCTAssertTrue(reveal(warning))
        XCTAssertTrue(warning.label.contains("新しく使い始める操作"))
        // review-1-1 / review-2-2. The sheet no longer asserts the server holds
        // nothing, and it states the deletion and its irreversibility.
        XCTAssertFalse(warning.label.contains("データがありません"))
        XCTAssertTrue(warning.label.contains("元に戻すことはできません"))
        let sheetComparison = app.staticTexts["storage-lineage-sheet-comparison"]
        XCTAssertTrue(reveal(sheetComparison))
        XCTAssertTrue(sheetComparison.label.contains("iCloud: テーマ9・記録312・成果28"))
        XCTAssertTrue(reveal(app.staticTexts["storage-lineage-sheet-other-devices"]))
        XCTAssertTrue(reveal(app.staticTexts["storage-lineage-other-builds"]))
        let toggle = app.switches["storage-lineage-confirm-data-loss"]
        XCTAssertTrue(reveal(toggle, upwards: false))
        XCTAssertEqual(toggle.value as? String, "0")
        let confirm = app.buttons["storage-lineage-sheet-confirm"]
        XCTAssertTrue(reveal(confirm, upwards: false))
        XCTAssertFalse(confirm.isEnabled, "Opening the sheet is not consent")

        acknowledge("storage-lineage-confirm-data-loss")
        XCTAssertTrue(reveal(confirm, upwards: false))
        XCTAssertTrue(confirm.isEnabled)
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        waitForConfirmationToClose()
        XCTAssertTrue(app.buttons["storage-lineage-start"].waitForExistence(timeout: 4))
        assertLineageFixture(lineage: 0, offline: 0)

        // Re-opened, the acknowledgement is unchecked again; only the second
        // one, given now, starts the request.
        XCTAssertTrue(reveal(app.buttons["storage-lineage-start"]))
        app.buttons["storage-lineage-start"].tap()
        XCTAssertTrue(app.navigationBars["最後の確認"].waitForExistence(timeout: 4))
        let reopened = app.switches["storage-lineage-confirm-data-loss"]
        XCTAssertTrue(reveal(reopened, upwards: false))
        XCTAssertEqual(reopened.value as? String, "0",
                       "戻る discards the acknowledgement; it is never remembered")
        acknowledge("storage-lineage-confirm-data-loss")
        let confirmAgain = app.buttons["storage-lineage-sheet-confirm"]
        XCTAssertTrue(reveal(confirmAgain, upwards: false))
        confirmAgain.tap()
        attach("Lineage start — acknowledged once, requested once")
        assertLineageFixture(lineage: 1, offline: 0)
        assertNoOperation()
        assertOverwriteFixture(refresh: 0, overwrite: 0, export: 0)
    }

    /// When the offline route is not eligible the screen says so instead of
    /// showing a control that would do nothing.
    func testAnIneligibleOfflineRouteIsExplainedRatherThanOffered() {
        launch("lineageUnavailableEnabled")
        let explanation = app.staticTexts["storage-lineage-offline-explanation"]
        XCTAssertTrue(reveal(explanation, upwards: false))
        XCTAssertTrue(explanation.label.contains("確認済みの記録"))
        XCTAssertFalse(app.buttons["cloud-offline-continue"].exists)
        assertLineageFixture(lineage: 0, offline: 0)
    }

    /// review-1-3 / review-2-1. The shipping build on a device whose offline
    /// copy is ALSO ineligible — the `.enrol` + `requireNoArtifacts` path that
    /// raises this very stop reason. Before the retry was added the screen was
    /// a disabled door and a support link: no way to re-attempt inside the app.
    func testTheClosedLineageScreenStillCarriesAWorkingControl() {
        launch("lineageUnavailableClosed")
        XCTAssertTrue(app.staticTexts["iCloudとの同期を止めています"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.buttons["storage-lineage-start"].exists)
        XCTAssertFalse(app.buttons["cloud-offline-continue"].exists,
            "The premise: no eligible offline copy, so that door is absent")
        let explanation = app.staticTexts["storage-lineage-offline-explanation"]
        XCTAssertTrue(reveal(explanation, upwards: false))
        XCTAssertTrue(explanation.label.contains("確認済みの記録"))
        let refresh = app.buttons["storage-lineage-refresh"]
        XCTAssertTrue(reveal(refresh, upwards: false))
        XCTAssertTrue(refresh.isEnabled, "The way back to sync is still on the screen")
        let retry = app.buttons["storage-lineage-retry"]
        XCTAssertTrue(reveal(retry, upwards: false))
        XCTAssertTrue(retry.isEnabled,
            "The screen must never be a dead end that only a force-quit leaves")
        // review-2-5. And the message may not state a choice this build refuses.
        let message = app.staticTexts["storage-launch-message"]
        XCTAssertTrue(reveal(message))
        XCTAssertFalse(message.label.contains("選べます"),
            "The screen states a choice and then greys it out, saw: \(message.label)")
        XCTAssertFalse(message.label.contains("使い始める"), "saw: \(message.label)")
        attach("Lineage unavailable — shipping build, no offline copy")
        assertLineageFixture(lineage: 0, offline: 0)
        assertNoOperation()
    }

    /// review-1-1 / review-2-2. S14 on this screen: the published door stays
    /// shut until the read-only server enumeration succeeded, and the named
    /// re-read is what opens it. Nobody may authorize deleting contents the
    /// app never enumerated.
    func testTheLineageDoorStaysShutUntilTheServerHasBeenEnumerated() {
        launch("lineageUnavailableUnreadable")
        let comparison = app.staticTexts["storage-lineage-comparison"]
        XCTAssertTrue(reveal(comparison))
        XCTAssertTrue(comparison.label.contains("iCloudの内容を確認できませんでした"))
        XCTAssertTrue(comparison.label.contains("どちらの記録も削除していません"))
        let evidence = app.staticTexts["storage-lineage-other-devices"]
        XCTAssertTrue(reveal(evidence))
        XCTAssertTrue(evidence.label.contains("まだ読み取れていない"),
            "Absence of a read is disclosed as absence of a read, saw: \(evidence.label)")
        let start = app.buttons["storage-lineage-start"]
        XCTAssertTrue(reveal(start, upwards: false))
        XCTAssertFalse(start.isEnabled,
            "The release bit is raised in this fixture; only the missing enumeration closes it")
        XCTAssertFalse(app.staticTexts["storage-lineage-start-unavailable"].exists,
            "The bit is open, so the release reason is not what is being reported")
        let refresh = app.buttons["storage-lineage-refresh"]
        XCTAssertTrue(reveal(refresh, upwards: false))
        XCTAssertFalse(refresh.isEnabled,
            "Nobody is asked to discard this iPhone's side on an unread server")
        attach("Lineage start — unreadable iCloud keeps the door shut")

        let reRead = app.buttons["storage-lineage-retry-preview"]
        XCTAssertTrue(reveal(reRead, upwards: false))
        reRead.tap()
        XCTAssertTrue(reveal(comparison))
        let counted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "iCloud: テーマ9・記録312・成果28"),
            object: comparison)
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 6), .completed,
            "saw: \(comparison.label)")
        XCTAssertTrue(reveal(start, upwards: false))
        XCTAssertTrue(start.isEnabled, "Only a successful enumeration arms this door")
        XCTAssertTrue(reveal(refresh))
        XCTAssertTrue(refresh.isEnabled, "and the same read arms the way back")
        assertLineageFixture(lineage: 0, offline: 0)
        assertNoOperation()
    }

    /// The two explanation-only screens carry no destructive control at all,
    /// in any policy: no start, no refresh, no overwrite, no sheet.
    func testTheExplanationScreensOfferNothingDestructive() {
        for scenario in ["environmentMismatch", "localLedgerMissingExplain"] {
            launch(scenario)
            let explanation = app.staticTexts["storage-dataset-explanation"]
            XCTAssertTrue(reveal(explanation), scenario)
            XCTAssertTrue(explanation.label.contains("削除していません"), scenario)
            if scenario == "localLedgerMissingExplain" {
                // review-1-4. This screen is reached only after the server read
                // SUCCEEDED, so it may not name a failed read or a network
                // remedy that does not address the state.
                XCTAssertFalse(explanation.label.contains("読み取れなかった"), scenario)
                XCTAssertFalse(explanation.label.contains("通信を確認"), scenario)
                XCTAssertTrue(explanation.label.contains("受け取った記録がありません"), scenario)
            }
            for identifier in ["storage-lineage-start", "storage-lineage-refresh", "storage-refresh-confirm",
                               "storage-overwrite-confirm", "storage-transfer-recover"] {
                XCTAssertFalse(app.buttons[identifier].exists, "\(scenario): \(identifier)")
            }
            XCTAssertTrue(reveal(app.buttons["もう一度試す"], upwards: false), scenario)
            attach("Explanation only — \(scenario)")
            assertNoOperation()
            assertLineageFixture(lineage: 0, offline: 0)
        }
        // And the offline route appears only where it is eligible.
        launch("environmentMismatch")
        XCTAssertTrue(reveal(app.buttons["cloud-offline-continue"], upwards: false))
        launch("localLedgerMissingExplain")
        XCTAssertTrue(reveal(app.staticTexts["storage-dataset-explanation"]))
        XCTAssertFalse(app.buttons["cloud-offline-continue"].exists)
    }

    /// AX5 on the screen that carries the only action, including its sheet.
    func testAX5LineageScreenKeepsBothChoicesAndTheConfirmationReachable() throws {
        launch("lineageUnavailableEnabled", accessibility5: true)
        // Top to bottom, in the order the screen presents its choices.
        XCTAssertTrue(reveal(app.staticTexts["storage-lineage-offline-explanation"]))
        XCTAssertTrue(reveal(app.buttons["storage-lineage-refresh"]))
        assertTouchTarget(app.buttons["storage-lineage-refresh"])
        let startExplanation = app.staticTexts["storage-lineage-start-explanation"]
        XCTAssertTrue(reveal(startExplanation))
        XCTAssertGreaterThan(startExplanation.frame.width,
            app.windows.firstMatch.frame.width * 0.65,
            "The explanation must keep a readable line width instead of collapsing")
        let start = app.buttons["storage-lineage-start"]
        XCTAssertTrue(reveal(start))
        assertTouchTarget(start)
        attach("AX5 lineage unavailable — every choice reachable")
        try auditDescriptionsAndTraits()

        XCTAssertTrue(reveal(start, upwards: false))
        start.tap()
        XCTAssertTrue(app.navigationBars["最後の確認"].waitForExistence(timeout: 6))
        // Scroll toward the toggle first: at AX5 it lies below the fold, and a
        // downward swipe on a sheet dismisses it instead of scrolling.
        let toggle = app.switches["storage-lineage-confirm-data-loss"]
        XCTAssertTrue(reveal(toggle))
        assertTouchTarget(toggle)
        XCTAssertGreaterThan(toggle.frame.height, 100,
            "The confirmation must actually inherit AX5, not silently reset to normal text")
        acknowledge("storage-lineage-confirm-data-loss")
        let confirm = app.buttons["storage-lineage-sheet-confirm"]
        XCTAssertTrue(reveal(confirm, upwards: false))
        assertTouchTarget(confirm)
        attach("AX5 lineage 「最後の確認」")
        try auditDescriptionsAndTraits()
        app.navigationBars["最後の確認"].buttons["戻る"].tap()
        XCTAssertTrue(app.buttons["storage-lineage-start"].waitForExistence(timeout: 6))
        assertLineageFixture(lineage: 0, offline: 0)
    }

    // MARK: - Helpers

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
    }

    private var state: XCUIElement { app.staticTexts["storage-switch.fixture-state"] }
    private var overwriteState: XCUIElement { app.staticTexts["storage-overwrite.fixture-state"] }
    private var writerState: XCUIElement { app.staticTexts["storage-overwrite.writer-fixture-state"] }

    private func openOverwriteSheet(upwards: Bool = false) {
        let overwrite = app.buttons["storage-overwrite-confirm"]
        if !reveal(overwrite, upwards: upwards) { XCTAssertTrue(reveal(overwrite, upwards: !upwards)) }
        overwrite.tap()
        XCTAssertTrue(app.navigationBars["最後の確認"].waitForExistence(timeout: 4))
    }

    /// A tap issued while 「最後の確認」 is still animating away lands on
    /// nothing, and the next sheet never opens.
    private func waitForConfirmationToClose() {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                             object: app.navigationBars["最後の確認"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }

    private func acknowledge(_ identifier: String) {
        let checkbox = app.switches[identifier]
        if !reveal(checkbox) { XCTAssertTrue(reveal(checkbox, upwards: false)) }
        // SwiftUI exposes the label and trailing switch as one wide AX node;
        // its center is noninteractive text. Exercise the real switch control.
        // A tap that lands while a correction scroll is still decelerating
        // only stops the scroll, so an unchanged value earns one more tap.
        let isChecked = NSPredicate(format: "value == %@", "1")
        for attempt in 0..<2 {
            checkbox.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            let checked = XCTNSPredicateExpectation(predicate: isChecked, object: checkbox)
            if XCTWaiter.wait(for: [checked], timeout: 3) == .completed { return }
            if attempt == 1 { XCTFail("The acknowledgement did not turn on: \(identifier)") }
        }
    }

    private func assertNoOperation() {
        XCTAssertTrue(reveal(state, upwards: false))
        XCTAssertEqual(state.label, "calls=0;choice=none;starting=false")
    }

    private func assertLateArrivalFixture(settingsCalls: Int, shown: Bool) {
        let state = app.staticTexts["storage-overwrite.late-arrival-fixture-state"]
        XCTAssertTrue(reveal(state, upwards: false))
        let expected = "settingsCalls=\(settingsCalls);shown=\(shown)"
        let matched = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", expected), object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 5), .completed,
            "Expected \(expected), saw \(state.label)")
    }

    private func assertLineageFixture(lineage: Int, offline: Int, refresh: Int = 0) {
        let state = app.staticTexts["storage-lineage.fixture-state"]
        XCTAssertTrue(reveal(state, upwards: false))
        let expected = "lineage=\(lineage);offline=\(offline);refresh=\(refresh)"
        let matched = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", expected), object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 5), .completed,
            "Expected \(expected), saw \(state.label)")
    }

    private func assertOverwriteFixture(refresh: Int, overwrite: Int, export: Int,
                                        previewRetries: Int = 0, recover: Int = 0) {
        let expected = "refresh=\(refresh);overwrite=\(overwrite);export=\(export);previewRetries=\(previewRetries);recover=\(recover)"
        let matched = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", expected), object: overwriteState)
        XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 5), .completed,
            "Expected \(expected), saw \(overwriteState.label)")
    }

    /// `upwards` is only the first guess at which way this element lies. The
    /// two doors sit above and below one another in one scroll view, so a test
    /// that asserts on both must not depend on knowing the order; a miss is
    /// retried in the opposite direction before it is reported as a failure.
    @discardableResult
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

    private func assertTouchTarget(_ element: XCUIElement, line: UInt = #line) {
        let described = element.identifier.isEmpty ? element.label : element.identifier
        XCTAssertGreaterThanOrEqual(element.frame.height, 43.5,
            "\(described) is \(element.frame.height) pt tall", line: line)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(element.frame.minX, window.minX, described, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxX, window.maxX, described, line: line)
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
