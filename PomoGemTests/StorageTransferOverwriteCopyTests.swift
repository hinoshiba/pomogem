import Foundation
import XCTest
@testable import PomoGem

/// PLAN §6.1–6.5. The approved Japanese wording, pinned byte-for-byte.
///
/// Every other assertion over these strings lives in XCUITest and matches a
/// three-to-ten character fragment, so a reviewed sentence could lose the one
/// clause that discloses what a user is about to destroy and the suite would
/// stay green (review-3-7). This file is the second, independent copy of the
/// approved text: changing a shipped string must mean deliberately changing it
/// here too. No simulator, no view, no I/O.
@MainActor
final class StorageTransferOverwriteCopyTests: XCTestCase {

    // MARK: - §6.1 The overwrite side of `.datasetRefresh`

    func testComparisonAndWarningStringsAreTheApprovedWording() {
        XCTAssertEqual(StorageTransferOverwriteCopy.comparisonReading,
                       "iCloudの内容を確認しています")
        XCTAssertEqual(StorageTransferOverwriteCopy.comparisonUnavailable,
                       "iCloudの内容を確認できませんでした。通信を確認して「iCloudの内容をもう一度確認」を押してください。どちらの記録も削除していません。")
        XCTAssertEqual(StorageTransferOverwriteCopy.retryPreviewTitle,
                       "iCloudの内容をもう一度確認")
        XCTAssertEqual(StorageTransferOverwriteCopy.dataLossWarning,
                       "iCloudにある現在のPomoGemのテーマ・記録・設定を削除し、このiPhoneのデータで置き換えます。2つのデータは結合しません。削除したiCloudのデータを元に戻すことはできません。同じApple Accountの他の端末は、次に開いたときにこの画面と同じ確認を求められ、その端末だけにある未送信のデータは残りません。")
        XCTAssertEqual(StorageTransferOverwriteCopy.exportTitle, "先にこの端末の記録を書き出す")
        XCTAssertEqual(StorageTransferOverwriteCopy.exportNote,
                       "書き出したファイルはポモジェムに読み込めません。記録の控えとして保存します。")
        XCTAssertEqual(StorageTransferOverwriteCopy.confirmTitle, "このiPhoneのデータで置き換える")
    }

    /// review-3-1: the failure copy must name a control that is actually on the
    /// screen. `もう一度試す` exists only on `.blocked`/`.failed`.
    func testTheFailureCopyNamesTheRetryControlThatTheScreenActuallyCarries() {
        XCTAssertTrue(StorageTransferOverwriteCopy.comparisonUnavailable
            .contains("「\(StorageTransferOverwriteCopy.retryPreviewTitle)」"))
        XCTAssertFalse(StorageTransferOverwriteCopy.comparisonUnavailable.contains("もう一度試す"),
            "`.datasetRefresh` has no 「もう一度試す」 button to point at")
        // Settings carries no re-read control of its own: the door IS the
        // re-read, so that surface names the door.
        XCTAssertEqual(StorageTransferOverwriteCopy.settingsPreviewUnavailable,
                       "iCloudの内容を確認できませんでした。通信を確認して、もう一度「このiPhoneのデータで置き換える」を押してください。どちらの記録も削除していません。")
        XCTAssertTrue(StorageTransferOverwriteCopy.settingsPreviewUnavailable
            .contains("「\(StorageTransferOverwriteCopy.confirmTitle)」"))
    }

    // MARK: - §6.2 Other-device evidence

    func testOtherDeviceEvidenceIsTheApprovedWordingForNoneAndForN() {
        XCTAssertEqual(StorageTransferOverwriteCopy.otherDevices(0),
                       "iCloudの記録には、このiPhone以外の端末は見つかりませんでした。ただし、これは他の端末が存在しない証明ではありません。まだ一度も記録を送っていない端末は分かりません。同じApple Accountの他の端末でPomoGemを開いている場合は、先に終了してください。")
        XCTAssertEqual(StorageTransferOverwriteCopy.otherDevices(0),
                       StorageTransferOverwriteCopy.otherDevices(-1),
                       "A negative count can only be a bug; it must never read as evidence")
        XCTAssertEqual(StorageTransferOverwriteCopy.otherDevices(2),
                       "iCloudの記録には、このiPhone以外の端末（2台）が書き込んだ記録があります。置き換えると、それらの端末は次に開いたときに「iCloudのデータが置き換わりました」の画面になり、その端末だけにある未送信の記録は失われます。置き換える前に、その端末でPomoGemを開いて同期を終わらせておくと、失われる記録を減らせます。")
        XCTAssertTrue(StorageTransferOverwriteCopy.otherDevices(1).contains("（1台）"))
        XCTAssertEqual(StorageTransferOverwriteCopy.otherDevicesUnknown,
                       "iCloudの記録をまだ読み取れていないため、このiPhone以外の端末が書き込んでいるかどうかは分かりません。")
    }

    // MARK: - §6.3 「最後の確認」

    func testFinalConfirmationStringsAreTheApprovedWording() {
        XCTAssertEqual(StorageTransferOverwriteCopy.sheetTitle, "最後の確認")
        XCTAssertEqual(StorageTransferOverwriteCopy.sheetWarning,
                       "現在iCloudにあるPomoGemのテーマ・記録・設定をすべて削除し、この端末のデータに置き換えます。削除するiCloudのデータを元に戻すことはできません。")
        XCTAssertEqual(StorageTransferOverwriteCopy.recoveryCopy,
                       "置き換えるデータの復旧用コピーをiCloudに保存し、受領を確認してから削除を始めます。復旧用コピーには、このiPhoneだけの過去の記録も含まれます。処理完了後に復旧用コピーを削除します。通信が途切れた場合は、削除の再試行までiCloudに残ることがあります。")
        XCTAssertEqual(StorageTransferOverwriteCopy.relaunch,
                       "処理の途中で、アプリの終了と再起動をお願いします。アプリ自体は削除しないでください。")
        XCTAssertEqual(StorageTransferOverwriteCopy.notCancellable,
                       "iCloudの削除を始めたあとは取り消せません。中断しても、次に開いたときに続きから再開します。")
        XCTAssertEqual(StorageTransferOverwriteCopy.screenTime,
                       "スクリーンタイムの連携を使っている場合は、監視を停止し、対応する設定と端末内の台帳を初期化します。")
        XCTAssertEqual(StorageTransferOverwriteCopy.acknowledgement,
                       "iCloudのデータの削除と、他の端末への影響を確認しました")
        XCTAssertEqual(StorageTransferOverwriteCopy.sheetConfirm, "iCloudを置き換える")
    }

    /// The iCloud → device direction destroys the DEVICE side and says so in
    /// every sentence; its acknowledgement must not be interchangeable with the
    /// opposite direction's (PLAN §3 S9).
    func testTheRefreshDirectionsOwnWordingIsTheApprovedWordingAndNamesTheDeviceSide() {
        XCTAssertEqual(StorageTransferRefreshCopy.settingsTitle, "iCloudのデータでこの端末を置き換える")
        XCTAssertEqual(StorageTransferRefreshCopy.dataLossWarning,
                       "この端末のテーマ・記録・設定を削除し、現在のiCloudのデータに置き換えます。未送信の端末データは失われ、iCloudのデータとは結合されません。iCloudのデータは残ります。")
        XCTAssertEqual(StorageTransferRefreshCopy.acknowledgement, "端末データの削除を確認しました")
        XCTAssertEqual(StorageTransferRefreshCopy.confirmTitle, "iCloudから再取得")
        XCTAssertEqual(StorageTransferRefreshCopy.relaunch,
                       "処理の途中で、アプリの終了と再起動をお願いします。アプリ自体は削除しないでください。")
        XCTAssertNotEqual(StorageTransferRefreshCopy.acknowledgement,
                          StorageTransferOverwriteCopy.acknowledgement)
    }

    // MARK: - §6.4 `.blocked`

    /// review-1-5. While `allowsDatasetOverwriteFromDevice` is false the next
    /// screen's overwrite door is permanently disabled, so this screen may not
    /// promise a choice between the two directions.
    func testBlockedExplanationOnlyPromisesTheDirectionThisBuildCanOffer() {
        XCTAssertEqual(StorageTransferOverwriteCopy.blockedExplanation(offersOverwrite: true),
                       "iCloudを読み取れれば、「もう一度試す」のあとに、iCloudのデータを再取得するか、このiPhoneのデータでiCloudを置き換えるかを選べます。")
        XCTAssertEqual(StorageTransferOverwriteCopy.blockedExplanation(offersOverwrite: false),
                       "iCloudを読み取れれば、「もう一度試す」のあとに、iCloudのデータを再取得する選択肢が表示されます。")
        // transfer-06. The message it sits under already says both of these.
        XCTAssertTrue(StorageTransferLineageCopy.refreshScreenUnavailable.contains("通信を確認"))
        XCTAssertTrue(StorageTransferLineageCopy.refreshScreenUnavailable.contains("どちらの記録も削除していません"))
        XCTAssertFalse(StorageTransferOverwriteCopy.blockedExplanation(offersOverwrite: false)
            .contains("iCloudを置き換える"),
            "An unpublished direction must not be promised by the screen before it")
        XCTAssertFalse(StorageTransferReleasePolicy.standard.allowsDatasetOverwriteFromDevice,
            "This test's premise: the shipping build still publishes nothing")
    }

    // MARK: - §6.5 Progress, relaunch, late arrival

    func testProgressCopyIsPinnedForEveryJournalPhase() {
        let expected: [StorageTransferJournal.Phase: String] = [
            .requested: "このiPhoneのデータを確認しています",
            .sourceSaved: "このiPhoneのデータを確認しています",
            .recoveryCopySaved: "復旧用コピーをiCloudに保存しました。置き換えを始めます",
            .preparingDestination: "iCloudのデータを置き換えています。アプリを閉じても、次に開いたときに続きから再開します",
            .destinationSaved: "置き換えた内容を照合しています",
            .destinationVerified: "置き換えた内容を照合しています",
            .selectionCommitted: "置き換えを完了しています",
            .sourceRetired: "置き換えを完了しています"
        ]
        XCTAssertEqual(Set(expected.keys).count, StorageTransferJournal.Phase.allCases.count,
            "A new journal phase must get its own approved sentence, not fall into a default")
        for phase in StorageTransferJournal.Phase.allCases {
            XCTAssertEqual(StorageTransferOverwriteCopy.progress(phase), expected[phase], "\(phase)")
        }
    }

    func testRequestAcceptedCopyIsTheApprovedWordingForBothDirections() {
        XCTAssertEqual(StorageTransferOverwriteCopy.requestAccepted,
                       "このiPhoneのデータでiCloudを置き換える手続きを受け付けました。Appスイッチャーでポモジェムを終了し、もう一度開いてください。復旧用コピーの保存が終わるまで、iCloudの削除は始めません。")
        XCTAssertEqual(StorageTransferRefreshCopy.requestAccepted,
                       "iCloudのデータでこの端末を置き換える手続きを受け付けました。Appスイッチャーでポモジェムを終了し、もう一度開いてください。iCloudのデータは削除しません。")
    }

    /// transfer-10. Apple's Japanese name for the control is 「Appスイッチャー」.
    func testRelaunchInstructionsUseApplesNameForTheAppSwitcher() {
        let texts = [StorageTransferOverwriteCopy.requestAccepted, StorageTransferRefreshCopy.requestAccepted,
                     StorageTransferLineageCopy.requestAccepted,
                     CloudLaunchReconnectWall.offlineRelaunchRequired.relaunchExplanation,
                     CloudLaunchReconnectWall.cloudVerificationTimedOut.relaunchExplanation]
        for text in texts {
            XCTAssertTrue(text.contains("Appスイッチャー"), text)
            XCTAssertFalse(text.contains("アプリスイッチャー"), text)
        }
        // quality-01. The offline wall's message leads with the automatic
        // check; the relaunch is said once, in the line under the retry.
        let offlineMessage = CloudOfflineSessionError.relaunchRequired.localizedDescription
        XCTAssertFalse(offlineMessage.contains("Appスイッチャー"), offlineMessage)
        XCTAssertFalse(offlineMessage.contains("削除しないでください"), offlineMessage)
    }

    /// Copy that sends the user into iOS — the App Switcher card, the Home
    /// Screen icon — names the app as iOS shows it there (CFBundleDisplayName
    /// 「ポモジェム」), not by its Latin brand name.
    func testCopyThatSendsTheUserIntoIOSNamesTheAppAsIOSShowsIt() {
        let texts = [StorageTransferOverwriteCopy.requestAccepted, StorageTransferRefreshCopy.requestAccepted,
                     StorageTransferLineageCopy.requestAccepted, StorageTransferProgressCopy.refreshReady,
                     StorageTransferProgressCopy.relaunchInstructions,
                     StorageTransferRuntimeError.relaunchRequired.localizedDescription,
                     StorageTransferRuntimeError.cloudCopyStillArriving.localizedDescription,
                     StorageTransferRuntimeError.cloudCopyStillPending.localizedDescription,
                     CloudLaunchReconnectWall.offlineRelaunchRequired.relaunchExplanation,
                     CloudLaunchReconnectWall.cloudVerificationTimedOut.relaunchExplanation]
        for text in texts {
            XCTAssertTrue(text.contains("ポモジェム"), text)
            XCTAssertFalse(text.contains("PomoGem"), text)
        }
        XCTAssertEqual(CloudDataDeletionGuidanceCopy.exportNote, StorageTransferOverwriteCopy.exportNote,
            "One export note, not two spellings of it")
    }

    /// The relaunch screen shows a message and, under it, how to relaunch.
    /// Whatever the message, 「アプリ自体は削除しないでください」 appears exactly
    /// once on the screen.
    func testTheRelaunchCaptionNeverRepeatsTheMessage() {
        let keep = StorageTransferProgressCopy.keepTheApp
        XCTAssertFalse(StorageTransferProgressCopy.relaunchInstructions.contains(keep))
        for message in [StorageTransferRuntimeError.relaunchRequired.localizedDescription,
                        StorageTransferRuntimeError.cloudCopyStillArriving.localizedDescription,
                        StorageTransferLineageCopy.requestAccepted, StorageTransferProgressCopy.refreshReady,
                        StorageTransferRefreshCopy.requestAccepted, StorageTransferOverwriteCopy.requestAccepted,
                        "切り替えを取り消しました。元の記録を残しています。アプリを終了して開き直してください。"] {
            let screen = message + StorageTransferProgressCopy.relaunchInstructions(after: message)
            XCTAssertEqual(screen.components(separatedBy: keep).count - 1, 1, message)
            XCTAssertTrue(screen.contains("ホーム画面のアイコンで開き直してください"), message)
        }
    }

    /// transfer-04. Every choice gets phase copy for every phase, and none of
    /// it calls a planned continuation an interruption.
    func testEveryChoiceHasProgressCopyForEveryPhase() {
        for choice in StorageTransferChoice.allCases {
            for phase in StorageTransferJournal.Phase.allCases {
                let text = StorageTransferProgressCopy.progress(
                    StorageTransferProgress(choice: choice, phase: phase))
                XCTAssertFalse(text.isEmpty, "\(choice) \(phase)")
                XCTAssertFalse(text.contains("中断"), "\(choice) \(phase): \(text)")
            }
        }
        XCTAssertEqual(StorageTransferProgressCopy.progress(
            StorageTransferProgress(choice: .overwriteCloudFromDevice, phase: .preparingDestination)),
            StorageTransferOverwriteCopy.progress(.preparingDestination),
            "The overwrite keeps its approved sentences")
        XCTAssertFalse(StorageTransferProgressCopy.continuing.contains("中断"))
        XCTAssertTrue(StorageTransferProgressCopy.relaunchInstructions.contains("Appスイッチャー"))
        XCTAssertTrue(StorageTransferProgressCopy.relaunchInstructions(after: "")
            .contains("削除しないでください"))
        XCTAssertTrue(StorageTransferRuntimeError.relaunchRequired.localizedDescription.contains("Appスイッチャー"))
        XCTAssertTrue(StorageTransferRuntimeError.cloudCopyStillArriving.localizedDescription.contains("Appスイッチャー"))
        XCTAssertFalse(StorageTransferRuntimeError.cloudCopyStillArriving.localizedDescription.contains("もう一度試す"),
            "The relaunch screen carries no retry, so its text may not name one")
    }

    /// transfer-02. The local-only → iCloud door deletes this device's jar.
    /// When iCloud holds none of the user's records the warning names what is
    /// lost, in the comparison's nouns, and that sync then starts empty.
    func testTheEnableWarningNamesTheLossAndTheEmptyStart() {
        var counts = Dictionary(uniqueKeysWithValues:
            PomoGemStorageSnapshot.cloudModelNames.map { ($0, 0) })
        counts["Subject"] = 12
        counts["StudySession"] = 480
        counts["AchievementStone"] = 36
        let device = StorageTransferCloudPreview(recordCounts: counts, latestRecordAt: nil,
                                                 otherDeviceIDs: 0, ignoredWriterIDs: 0)
        let warning = StorageTransferEnableCopy.cloudSideEmpty(device: device)
        XCTAssertTrue(warning.contains("このiPhoneのテーマ12・記録480・成果36"), warning)
        XCTAssertTrue(warning.contains("空の状態からiCloudの同期を始めます"))
        XCTAssertTrue(warning.contains("元に戻すことはできません"))
        XCTAssertTrue(StorageTransferEnableCopy.cloudSideEmpty(device: nil).contains("元に戻すことはできません"))
        XCTAssertTrue(StorageTransferEnableCopy.previewUnavailable
            .contains("「\(StorageTransferEnableCopy.keepCloudTitle)」"),
            "A failed read names the control the user presses again")
        XCTAssertTrue(StorageTransferEnableCopy.previewUnavailable.contains("どちらの記録も削除していません"))
        XCTAssertEqual(StorageTransferOverwriteCopy.countsOnly("iCloud", preview: device),
                       "iCloud: テーマ12・記録480・成果36")
    }

    /// transfer-07. What a switch resets, and what it keeps, in the Screen
    /// Time settings' own nouns.
    func testTheScreenTimeDisclosureSaysWhatIsResetAndWhatIsKept() {
        for text in [StorageTransferScreenTimeCopy.switchResets, StorageTransferScreenTimeCopy.switchResetsIfInUse] {
            for noun in ["選んだアプリ", "まだ取り込んでいない利用記録", "黒い石", "「スクリーンタイム」",
                         "保存済みの勉強時間と粒は引き継ぎます"] {
                XCTAssertTrue(text.contains(noun), noun)
            }
        }
        // The launch host cannot read whether the feature is in use, so its
        // sentence is conditional rather than an assertion about this user.
        XCTAssertTrue(StorageTransferScreenTimeCopy.switchResetsIfInUse.hasPrefix("スクリーンタイムの自動記録を使っている場合、"))
    }

    /// transfer-10. A closed door has staged nothing, so its reason may not
    /// promise a recovery copy the way the resume-time refusal can.
    func testAClosedDoorsReasonPromisesNoRecoveryCopy() {
        let reason = StorageTransferOverwriteCopy.doorUnavailable
        XCTAssertFalse(reason.contains("復旧用コピー"))
        XCTAssertTrue(reason.contains("いまは利用できません"))
        // Nobody pressed a closed door, so its reason reports no event:
        // 「削除していません」 under it would reassure about a non-event.
        XCTAssertFalse(reason.contains("削除していません"), reason)
        XCTAssertEqual(reason, "複数端末での同時操作から記録を保護するため、この操作はいまは利用できません。")
    }

    func testLateArrivalBannerIsTheApprovedWordingAndOffersOnlyNonDestructiveActions() {
        XCTAssertEqual(StorageTransferOverwriteCopy.lateArrival,
                       "置き換えの後に、他の端末から古い記録が届いた可能性があります。削除したはずのテーマが戻っていないか確認してください。もう一度この端末のデータで置き換えることもできます。")
        XCTAssertEqual(StorageTransferOverwriteCopy.lateArrivalOpenSettings, "設定を開く")
        XCTAssertEqual(StorageTransferOverwriteCopy.lateArrivalDismiss, "このまま使う")
        // It is a hedged detector, never a claim of fact and never an action.
        XCTAssertTrue(StorageTransferOverwriteCopy.lateArrival.contains("可能性があります"))
    }

    // MARK: - The comparison row

    /// review-3-5. Two datasets a year apart must not read as a two-day
    /// difference on the one screen where an irreversible deletion is chosen.
    func testTheComparisonRowRendersTheYearAndIsPinnedForEveryPreviewState() {
        let preview = Self.preview(subjects: 12, sessions: 480, stones: 36,
                                   latest: Self.date(2026, 9, 20))
        XCTAssertEqual(StorageTransferOverwriteCopy.side("このiPhone", preview: preview),
                       "このiPhone: テーマ12・記録480・成果36（最終 2026年9月20日）")
        XCTAssertEqual(StorageTransferOverwriteCopy.side("iCloud", preview:
            Self.preview(subjects: 9, sessions: 312, stones: 28, latest: Self.date(2025, 9, 18))),
                       "iCloud: テーマ9・記録312・成果28（最終 2025年9月18日）")
        XCTAssertEqual(StorageTransferOverwriteCopy.side("iCloud", preview:
            Self.preview(subjects: 0, sessions: 0, stones: 0, latest: nil)),
                       "iCloud: テーマ0・記録0・成果0（日付のある記録なし）")
        // One fallback for both sides: an unreadable side says so in the same
        // shape as a readable one, so neither can look like the other's answer.
        XCTAssertEqual(StorageTransferOverwriteCopy.side("このiPhone", preview: nil),
                       "このiPhone: 確認できませんでした")
        XCTAssertEqual(StorageTransferOverwriteCopy.side("iCloud", preview: nil),
                       "iCloud: 確認できませんでした")
    }

    /// A year apart must be visibly a year apart.
    func testTwoSidesAYearApartDoNotRenderAsTheSameDate() {
        let older = StorageTransferOverwriteCopy.side("iCloud", preview:
            Self.preview(subjects: 1, sessions: 1, stones: 1, latest: Self.date(2025, 9, 20)))
        let newer = StorageTransferOverwriteCopy.side("iCloud", preview:
            Self.preview(subjects: 1, sessions: 1, stones: 1, latest: Self.date(2026, 9, 20)))
        XCTAssertNotEqual(older, newer)
        XCTAssertTrue(older.contains("2025"))
        XCTAssertTrue(newer.contains("2026"))
    }

    // MARK: - Fixtures

    private static func preview(subjects: Int, sessions: Int, stones: Int,
                                latest: Date?) -> StorageTransferCloudPreview {
        var counts = Dictionary(uniqueKeysWithValues:
            PomoGemStorageSnapshot.cloudModelNames.map { ($0, 0) })
        counts["Subject"] = subjects
        counts["StudySession"] = sessions
        counts["AchievementStone"] = stones
        return StorageTransferCloudPreview(recordCounts: counts, latestRecordAt: latest,
                                           otherDeviceIDs: 0, ignoredWriterIDs: 0)
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        // The shipping formatter renders in the reader's own time zone, which
        // is correct for a user and would otherwise make this assertion depend
        // on the simulator's region. Build the instant in the SAME zone so the
        // rendered calendar day is the one written above, wherever this runs.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: components) ?? Date(timeIntervalSinceReferenceDate: 0)
    }
}
