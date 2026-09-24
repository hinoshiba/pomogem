import XCTest
@testable import PomoGem

/// The wording invariants behind PLAN §3 S14 — 「never authorize deleting
/// contents the app never enumerated」 — stated as tests rather than as
/// comments, for the three surfaces the fix-up pass touched.
///
/// None of these tests builds a container, resolves an account or reaches
/// CloudKit. They read the shipped strings and the pure preview reductions,
/// which is exactly the level at which the defects they pin were introduced:
/// every one of them was a sentence that claimed something about a side the
/// screen had not read.
final class StorageTransferConsentEvidenceTests: XCTestCase {
    // MARK: review-1-1 / review-2-2 — the lineage-start door

    /// The sheet used to open with 「現在のiCloudには、このアプリが使えるPomoGemの
    /// データがありません」. `cloudLineageUnavailable` proves only that
    /// `PomoGemStorageTransfer-v1/control-v1` is absent; it is silent about
    /// `com.apple.coredata.cloudkit.zone`, which the action purges.
    func testTheLineageSheetNeverClaimsTheServerHoldsNothing() {
        let warning = StorageTransferLineageCopy.sheetWarning
        XCTAssertFalse(warning.contains("データがありません"),
            "An unverified factual claim about the server may not sit before a deletion")
        XCTAssertTrue(warning.contains("削除"),
            "The action deletes the account's records and the sheet must say so")
        XCTAssertTrue(warning.contains("元に戻すことはできません"),
            "Irreversibility is stated here exactly as in the overwrite copy")
    }

    /// `StorageTransferOverwriteCopy.dataLossWarning` is the already-approved
    /// wording for the same irreversibility. The lineage sheet must not be
    /// softer about it.
    func testTheLineageSheetMatchesTheOverwriteCopysIrreversibility() {
        for text in [StorageTransferOverwriteCopy.sheetWarning,
                     StorageTransferLineageCopy.sheetWarning] {
            XCTAssertTrue(text.contains("元に戻すことはできません"), text)
        }
    }

    /// The acknowledgement used to mention only sending this iPhone's data and
    /// asking other devices to re-fetch. It never mentioned deletion.
    func testTheLineageAcknowledgementNamesTheDeletion() {
        XCTAssertTrue(StorageTransferLineageCopy.acknowledgement.contains("削除"),
            "A user cannot acknowledge a deletion that the sentence does not name")
    }

    /// The screen's own explanation must not imply the server side is empty
    /// either: `refreshCloudDatasetWithoutLineage` exists precisely because
    /// records under a missing control record are real and mirrorable.
    func testTheLineageScreenExplanationSaysWhatHappensToTheRemainingRecords() {
        let explanation = StorageTransferLineageCopy.startExplanation
        XCTAssertTrue(explanation.contains("iCloudに残っている記録"))
        XCTAssertTrue(explanation.contains("このiPhoneの記録は削除しません"),
            "and it still states which side survives")
    }

    /// The enumerated iCloud side is rendered by the same reduction the
    /// Settings sheet uses, so the two surfaces cannot disagree about one
    /// dataset, and it never prints a 「最終」 row that implies a lineage.
    func testTheNoLineageCloudRowCountsTheRecordsAndImpliesNoLedger() {
        let row = StorageTransferOverwriteCopy.cloudSideWithoutLineage(preview: Self.preview(
            subjects: 9, sessions: 312, stones: 28, otherDeviceIDs: 1))
        XCTAssertEqual(row, "iCloud: テーマ9・記録312・成果28")
        XCTAssertFalse(row.contains("最終"))
        // transfer-10. No internal term on a screen where a deletion is chosen.
        XCTAssertFalse(row.contains("管理情報"))
    }

    /// transfer-03. Bookkeeping rows are not the user's records. A server that
    /// holds only a Prefs writer row, a device claim, a reset marker and the
    /// five seeded preset themes still holds nothing the user made, and the
    /// row may not read as if it did.
    func testBookkeepingRowsNeitherInflateTheRowNorHideAnEmptyServer() {
        var counts = Dictionary(uniqueKeysWithValues:
            PomoGemStorageSnapshot.cloudModelNames.map { ($0, 0) })
        counts["Subject"] = 5
        counts["Prefs"] = 1
        counts["FocusTimerDeviceClaim"] = 1
        counts["ActivityResetMarker"] = 1
        counts["SyncedFocusTimer"] = 1
        let bookkeeping = StorageTransferCloudPreview(recordCounts: counts,
            latestRecordAt: Date(timeIntervalSinceReferenceDate: 0), otherDeviceIDs: 1, ignoredWriterIDs: 0)
        XCTAssertEqual(bookkeeping.totalRecordCount, 9)
        XCTAssertEqual(bookkeeping.userContentRecordCount, 0)
        XCTAssertTrue(StorageTransferRefreshCopy.cloudSideIsEmpty(bookkeeping),
                      "The documented 0件 warning must fire for this account")
        XCTAssertEqual(StorageTransferOverwriteCopy.cloudSideWithoutLineage(preview: bookkeeping),
                       "iCloud: テーマ5・記録0・成果0")

        let withRecords = Self.preview(subjects: 0, sessions: 1, stones: 0, otherDeviceIDs: 0)
        XCTAssertFalse(StorageTransferRefreshCopy.cloudSideIsEmpty(withRecords))
        let withStones = Self.preview(subjects: 0, sessions: 0, stones: 1, otherDeviceIDs: 0)
        XCTAssertFalse(StorageTransferRefreshCopy.cloudSideIsEmpty(withStones))
        XCTAssertFalse(StorageTransferRefreshCopy.cloudSideIsEmpty(nil),
                       "A read that did not happen is never an empty server")
    }

    // MARK: review-2-7 — the disabled door's reason

    /// The reason line under 「このiPhoneのデータでiCloudを使い始める」 used to be
    /// the overwrite string, which describes a 「置き換え」 and promises a
    /// 復旧用コピー this path never stages before it is permitted to run.
    func testTheDisabledLineageDoorIsExplainedInItsOwnTerms() {
        let reason = StorageTransferLineageCopy.startUnavailable
        XCTAssertTrue(reason.contains("使い始める操作は、いまは利用できません"))
        XCTAssertFalse(reason.contains("置き換える操作"),
            "The screen insists this is not a replacement; its reason line must agree")
        XCTAssertFalse(reason.contains("復旧用コピー"),
            "No recovery copy exists on this path at the point the door is refused")
        XCTAssertNotEqual(reason,
            StorageTransferReleaseError.datasetOverwriteUnavailable.localizedDescription)
    }

    // MARK: review-1-4 — the localLedgerMissing explanation

    /// `.datasetExplanation(.localLedgerMissing)` is set only inside the
    /// SUCCESS branch of `presentDatasetRefresh`: a read that throws produces
    /// `refreshScreenUnavailable` instead. The copy may therefore not name a
    /// failed read, nor a remedy (check the connection) for a state that has
    /// no network cause.
    func testTheLocalLedgerExplanationDescribesWhatWasObservedNotAFailedRead() {
        let explanation = StorageTransferLineageCopy.localLedgerMissingExplanation
        XCTAssertFalse(explanation.contains("読み取れなかった"),
            "This screen is reached only after the read SUCCEEDED")
        XCTAssertFalse(explanation.contains("通信を確認"),
            "A network cause was not observed and naming one misdirects support")
        XCTAssertTrue(explanation.contains("受け取った記録がありません"))
        XCTAssertTrue(explanation.contains("削除していません"))
        // And the wording for a genuinely failed read keeps it, exclusively.
        XCTAssertTrue(StorageTransferLineageCopy.refreshScreenUnavailable
            .contains("読み取れなかった"))
        XCTAssertNotEqual(explanation, StorageTransferLineageCopy.refreshScreenUnavailable)
    }

    // MARK: review-1-2 / review-2-4 — Settings direction (B)

    /// The direction retires the device's store family with no recovery
    /// payload anywhere. 「iCloudのデータは残ります」 is true and says nothing
    /// about how much there is, so the empty case gets its own paragraph.
    func testTheRefreshDirectionDisclosesAnEmptyServerSide() {
        let empty = Self.preview(subjects: 0, sessions: 0, stones: 0, otherDeviceIDs: 0)
        XCTAssertEqual(empty.totalRecordCount, 0)
        XCTAssertTrue(StorageTransferRefreshCopy.cloudSideIsEmpty(empty))
        let warning = StorageTransferRefreshCopy.cloudSideEmpty(device: nil)
        XCTAssertTrue(warning.contains("1件も見つかりませんでした"))
        XCTAssertTrue(warning.contains("元に戻すことはできません"))
        // transfer-03. When this iPhone was counted, the warning says what it
        // is about to lose, in the same three nouns as the comparison rows.
        let counted = StorageTransferRefreshCopy.cloudSideEmpty(device: Self.preview(
            subjects: 12, sessions: 480, stones: 36, otherDeviceIDs: 0))
        XCTAssertTrue(counted.contains("このiPhoneのテーマ12・記録480・成果36"), counted)
        XCTAssertTrue(counted.contains("元に戻すことはできません"))
        // The reassurance sentence on its own must never be the whole story.
        XCTAssertTrue(StorageTransferRefreshCopy.dataLossWarning.contains("iCloudのデータは残ります"))
        XCTAssertFalse(StorageTransferRefreshCopy.dataLossWarning.contains("件"))
    }

    /// Each surface names the control the user would actually press again, so
    /// a failed read never points at a button that is not on the screen.
    func testEachDirectionsFailedReadNamesItsOwnControl() {
        XCTAssertTrue(StorageTransferRefreshCopy.settingsPreviewUnavailable
            .contains(StorageTransferRefreshCopy.confirmTitle))
        XCTAssertTrue(StorageTransferOverwriteCopy.settingsPreviewUnavailable
            .contains(StorageTransferOverwriteCopy.confirmTitle))
        for text in [StorageTransferRefreshCopy.settingsPreviewUnavailable,
                     StorageTransferOverwriteCopy.settingsPreviewUnavailable] {
            XCTAssertTrue(text.contains("どちらの記録も削除していません"), text)
        }
    }

    /// A read that has not happened is never reported as an empty dataset:
    /// the total is only asked of a preview that exists.
    func testAMissingPreviewIsNotAnEmptyDataset() {
        let unread: StorageTransferCloudPreview? = nil
        XCTAssertNil(unread?.totalRecordCount)
        XCTAssertEqual(StorageTransferOverwriteCopy.cloudSideWithoutLineage(preview: nil),
                       StorageTransferOverwriteCopy.side("iCloud", preview: nil))
        XCTAssertTrue(StorageTransferOverwriteCopy.side("iCloud", preview: nil)
            .contains("確認できませんでした"))
    }

    // MARK: Helper

    private static func preview(subjects: Int, sessions: Int, stones: Int,
                                otherDeviceIDs: Int) -> StorageTransferCloudPreview {
        var counts = Dictionary(uniqueKeysWithValues:
            PomoGemStorageSnapshot.cloudModelNames.map { ($0, 0) })
        counts["Subject"] = subjects
        counts["StudySession"] = sessions
        counts["AchievementStone"] = stones
        return StorageTransferCloudPreview(recordCounts: counts, latestRecordAt: nil,
                                           otherDeviceIDs: otherDeviceIDs, ignoredWriterIDs: 0)
    }
}
