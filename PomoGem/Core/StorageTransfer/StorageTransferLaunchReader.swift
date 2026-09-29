import Foundation
import SwiftData

/// Read-only access to THIS device's on-disk stores from the launch host, at a
/// point where no session exists and the user has consented to nothing.
///
/// Two screens need it, both strictly before any destructive decision:
///
/// * the pre-flight comparison, so the device side of 「このiPhone / iCloud」 is a
///   counted fact rather than an assumption, and
/// * `storage-refresh-export`, the rescue door `Docs/MultiDeviceCloudSafety.md`
///   asks for on behalf of the generation that is about to lose.
///
/// Every read happens against a **disposable copy** produced by the existing
/// `StorageTransferStoreFiles.makeFrozenReaderCopy`, mounted with CloudKit
/// disabled, under a throwaway transfer root in the temporary directory. The
/// real stores are only ever read and hashed, never opened, renamed or
/// written; the copy and its root are removed before this type returns. No
/// journal is created, no checkpoint is written, no CloudKit call is made, and
/// nothing here can authorize a transfer.
@MainActor
enum StorageTransferLaunchReader {
    /// A failure is always surfaced. "We could not look" and "there is nothing
    /// there" must never be confusable on a screen that offers a deletion.
    enum Failure: Error, LocalizedError, Equatable {
        case unavailable
        var errorDescription: String? {
            String(localized: "この端末の記録を読み取れませんでした。記録は変更していません。", table: "Storage",
                   comment: "The launch host could not read this device's stores for the comparison or the export")
        }
    }

    /// The device side of the comparison is reduced by the **same** per-row
    /// reduction as the iCloud side (`StorageTransferCloudPreview.Reducer`),
    /// over the same mirrored models, so the two rows a user compares are
    /// computed identically and a difference between them is a difference in
    /// the data. It reads the rows directly rather than through a full
    /// `PomoGemStorageSnapshot`: only the mirrored models' scalar fields, in
    /// one pass, so a long-time user is not frozen on the stop screen while
    /// every relationship of every entity is captured just to be counted.
    /// `otherDeviceIDs` is meaningless for the local side and is ignored by
    /// the UI; only the counts and the newest dated row are read from it.
    static func captureDevicePreview(selection: PersistenceDeploymentSelection,
                                     localDeviceID: String = FocusDeviceIdentity.current())
        throws -> StorageTransferCloudPreview {
        try withDisposableReader(selection: selection) { container in
            let context = ModelContext(container)
            context.autosaveEnabled = false
            return try StorageTransferCloudPreview.make(context: context, localDeviceID: localDeviceID)
        }
    }

    /// Writes the ordinary Settings export from the disposable copy. The
    /// resulting file lives in `PomoGemDataExporter`'s own owned temporary
    /// namespace, not in the reader root, so removing the reader cannot take
    /// the user's rescue copy with it.
    /// The reader root is removed only after the export has finished. A
    /// `@ModelActor` keeps its container — and therefore these files — alive
    /// across the suspension, so the copy must outlive the await rather than
    /// the synchronous scope that created it.
    static func exportDeviceData(selection: PersistenceDeploymentSelection,
                                 appInfo: PomoGemDataExportAppInfo = .current) async throws -> URL {
        let root = readerRoot(id: UUID())
        defer {
            try? FileManager.default.removeItem(at: root)
            removeReaderRoots()
        }
        let worker = try autoreleasepool { () throws -> PomoGemDataExportWorker in
            let files = try StorageTransferStoreFiles(transactionID: UUID(), transferRoot: root)
            let urls = try files.makeFrozenReaderCopy(selection: selection)
            let container = try StorageTransferPersistence.makeContainer(
                selection: selection, urls: urls, cloudEnabled: false)
            return PomoGemDataExportWorker(modelContainer: container)
        }
        return try await worker.export(appInfo: appInfo).fileURL
    }

    /// Mounts a throwaway copy, hands it to `body`, and removes the copy.
    /// Synchronous and wrapped in an autorelease pool so the container is gone
    /// before the next caller reaches `requireAllReleased()`; a reader that
    /// outlived its scope would otherwise refuse the real transfer later.
    private static func withDisposableReader<T>(selection: PersistenceDeploymentSelection,
                                                _ body: (ModelContainer) throws -> T) throws -> T {
        let root = readerRoot(id: UUID())
        defer { try? FileManager.default.removeItem(at: root) }
        return try autoreleasepool {
            let files = try StorageTransferStoreFiles(transactionID: UUID(), transferRoot: root)
            let urls = try files.makeFrozenReaderCopy(selection: selection)
            let container = try StorageTransferPersistence.makeContainer(
                selection: selection, urls: urls, cloudEnabled: false)
            return try body(container)
        }
    }

    private static let readerRootPrefix = "storage-transfer-launch-reader-"

    private static func readerRoot(id: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(readerRootPrefix + id.uuidString.lowercased(), isDirectory: true)
            .standardizedFileURL
    }

    /// Only this type's own, name-and-UUID-matched roots are ever removed, so a
    /// malformed path can never turn cleanup into a broad delete.
    private static func removeReaderRoots() {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.standardizedFileURL
        guard let children = try? manager.contentsOfDirectory(at: temporary,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else { return }
        for child in children {
            let name = child.lastPathComponent
            guard name.hasPrefix(readerRootPrefix),
                  UUID(uuidString: String(name.dropFirst(readerRootPrefix.count))) != nil,
                  let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try? manager.removeItem(at: child)
        }
    }
}

extension PomoGemDataExportAppInfo {
    static var current: Self {
        Self(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
             build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
    }
}

/// The fixed copy (Storage table) for the iCloud → device direction — 「iCloudから再取得」
/// — kept here so both surfaces that offer it quote one text. It destroys the
/// DEVICE side, never the server side, and says so in every sentence.
enum StorageTransferRefreshCopy {
    static let settingsTitle = String(
        localized: "iCloudのデータでこの端末を置き換える", table: "Storage",
        comment: "Settings section title: the iCloud → device direction, which deletes this device's data")
    static let dataLossWarning = String(
        localized: "この端末のテーマ・記録・設定を削除し、現在のiCloudのデータに置き換えます。未送信の端末データは失われ、iCloudのデータとは結合されません。iCloudのデータは残ります。",
        table: "Storage", comment: "Irreversible: what re-downloading from iCloud deletes on this device")
    static let relaunch = SentenceText.join([
        String(localized: "処理の途中で、アプリの終了と再起動をお願いします。", table: "Storage",
               comment: "Final confirmation: the transfer asks for a quit and relaunch partway through"),
        StorageTransferProgressCopy.keepTheApp
    ])
    static let acknowledgement = String(
        localized: "端末データの削除を確認しました", table: "Storage",
        comment: "Acknowledgement toggle before re-downloading from iCloud deletes this device's data")
    static let confirmTitle = String(
        localized: "iCloudから再取得", table: "Storage",
        comment: "Destructive button: replace this device's data with iCloud's (re-download from iCloud)")

    static let requestAccepted = String(
        localized: "iCloudのデータでこの端末を置き換える手続きを受け付けました。Appスイッチャーでポモジェムを終了し、もう一度開いてください。iCloudのデータは削除しません。",
        table: "Storage", comment: "Relaunch screen after the iCloud → device replacement was accepted")

    /// review-1-2 / review-2-4. This direction deletes the DEVICE side and
    /// stages no recovery copy anywhere, so the user may not be asked to
    /// authorize it without being told what is actually on the side they are
    /// about to fetch from. The read is read-only and gates nothing else.
    static let settingsPreviewUnavailable = String(
        localized: "iCloudの内容を確認できませんでした。通信を確認して、もう一度「\(confirmTitle)」を押してください。どちらの記録も削除していません。",
        table: "Storage", comment: "The read-only iCloud check failed. %@ is the title of the button to tap again")

    /// The one shape that turns this direction into silent data loss: the
    /// account's iCloud side holds none of the user's records — the state
    /// ROOT-CAUSE §6.2 names when the app's data is deleted from iOS Settings.
    /// 「iCloudのデータは残ります」 is true and useless there, so the empty side
    /// is stated in its own paragraph, before the acknowledgement, together
    /// with what THIS device is about to lose when that was counted.
    ///
    /// transfer-03. "Empty" is decided by
    /// `StorageTransferCloudPreview.userContentRecordCount`, never by the total
    /// row count: a Prefs writer row and the seeded preset themes exist on
    /// every account a device ever opened, and counting them made this
    /// paragraph unreachable in practice.
    ///
    /// One catalog entry per sentence, joined by `SentenceText`: the counted
    /// loss sits inside the second sentence, so each variant of it is a whole
    /// sentence of its own. The Japanese counts stay ungrouped digits, as before.
    static func cloudSideEmpty(device: StorageTransferCloudPreview?) -> String {
        let loss: String
        if let device {
            let (themes, records, achievements) = StorageTransferOverwriteCopy.countArguments(device)
            loss = String(
                localized: "このまま実行すると、このiPhoneのテーマ\(themes)・記録\(records)・成果\(achievements)を含む、テーマ・記録・設定はすべて削除され、元に戻すことはできません。",
                table: "Storage",
                comment: "Re-download warning when iCloud is empty. The arguments are this iPhone's theme, record and achievement counts as digit text (ungrouped in Japanese, grouped in English)")
        } else {
            loss = String(
                localized: "このまま実行すると、このiPhoneのテーマ・記録・設定は削除され、元に戻すことはできません。",
                table: "Storage", comment: "Re-download warning when iCloud is empty and this iPhone could not be counted")
        }
        return SentenceText.join([
            StorageTransferOverwriteCopy.cloudHoldsNoUserRecords,
            loss,
            String(localized: "中止して、先にこの端末の記録を書き出すか、他の端末の同期が終わるのをお待ちください。",
                   table: "Storage", comment: "Re-download warning when iCloud is empty: what to do instead")
        ])
    }

    /// True only when a read actually succeeded and found none of the user's
    /// own records. A missing preview is never reported as an empty dataset.
    static func cloudSideIsEmpty(_ preview: StorageTransferCloudPreview?) -> Bool {
        preview?.userContentRecordCount == 0
    }
}

/// transfer-02. The fixed copy (Storage table) for the one published local-only →
/// iCloud door, 「iCloudのデータを使う」. It deletes the device's whole jar, so
/// its confirmation now carries the same read-only evidence as the refresh
/// door: what each side holds, and a warning when iCloud holds none of the
/// user's records.
enum StorageTransferEnableCopy {
    static let keepCloudTitle = String(
        localized: "iCloudのデータを使う", table: "Storage",
        comment: "Destructive button on the local-only screen: turn on iCloud and keep iCloud's data (deletes this iPhone's)")
    static let previewUnavailable = String(
        localized: "iCloudの内容を確認できませんでした。通信とApple Accountを確認して、もう一度「\(keepCloudTitle)」を押してください。どちらの記録も削除していません。",
        table: "Storage", comment: "The read-only iCloud check failed. %@ is the title of the button to tap again")

    /// Deliberately not the refresh door's sentence: here the user is turning
    /// iCloud ON, and an empty iCloud means the synced jar starts from zero.
    static func cloudSideEmpty(device: StorageTransferCloudPreview?) -> String {
        let loss: String
        if let device {
            let (themes, records, achievements) = StorageTransferOverwriteCopy.countArguments(device)
            loss = String(
                localized: "このまま実行すると、このiPhoneのテーマ\(themes)・記録\(records)・成果\(achievements)を含む、テーマ・記録・設定はすべて削除され、空の状態からiCloudの同期を始めます。",
                table: "Storage",
                comment: "Turn-on-iCloud warning when iCloud is empty. The arguments are this iPhone's theme, record and achievement counts as digit text (ungrouped in Japanese, grouped in English)")
        } else {
            loss = String(
                localized: "このまま実行すると、このiPhoneのテーマ・記録・設定はすべて削除され、空の状態からiCloudの同期を始めます。",
                table: "Storage", comment: "Turn-on-iCloud warning when iCloud is empty and this iPhone could not be counted")
        }
        return SentenceText.join([
            StorageTransferOverwriteCopy.cloudHoldsNoUserRecords,
            loss,
            String(localized: "元に戻すことはできません。", table: "Storage",
                   comment: "Closing sentence of an irreversible-deletion warning")
        ])
    }
}

/// transfer-07. Every published storage switch moves to a different storage
/// namespace, and the Screen Time ledger is bound to that namespace
/// (Docs/ScreenTimeGems.md: the selection, unimported reached events and
/// black gems are not carried over). Not carrying them is intended; not
/// saying so is what made users conclude the feature broke.
enum StorageTransferScreenTimeCopy {
    static let switchResets = String(
        localized: "切り替えると、スクリーンタイムの自動記録はオフになり、選んだアプリ、まだ取り込んでいない利用記録、黒い石は引き継ぎません。切り替えたあとで、設定の「スクリーンタイム」から選び直してください。保存済みの勉強時間と粒は引き継ぎます。",
        table: "Storage", comment: "Storage switch: what happens to Screen Time"
    )

    /// The same facts for the launch host's 「iCloudから再取得」 doors. No store
    /// is mounted there, so no Screen Time owner is bound and whether the
    /// feature is in use cannot be read; Settings shows `switchResets` only
    /// while it is. The conditional form is true either way, and these stop
    /// screens are rare enough that a sentence a non-user can skip costs less
    /// than a reset nobody was told about.
    static let switchResetsIfInUse = String(
        localized: "スクリーンタイムの自動記録を使っている場合、切り替えると自動記録はオフになり、選んだアプリ、まだ取り込んでいない利用記録、黒い石は引き継ぎません。切り替えたあとで、設定の「スクリーンタイム」から選び直してください。保存済みの勉強時間と粒は引き継ぎます。",
        table: "Storage", comment: "Launch stop screen: what happens to Screen Time if it is in use"
    )
}

/// The fixed copy (Storage table) for the device → iCloud overwrite. It lives beside
/// the runtime rather than inside a view so the launch host, Settings and the
/// review notes quote one text, and so a reviewer can diff the shipped strings
/// against the approved wording in one place.
enum StorageTransferOverwriteCopy {
    static let comparisonReading = String(
        localized: "iCloudの内容を確認しています", table: "Storage",
        comment: "Progress while the read-only check counts what is in iCloud")
    /// It must name a control that is on THIS screen, and the narrowest one:
    /// the re-read below re-arms the door in place, while the screen's own
    /// 「もう一度試す」 re-runs the whole launch. Without a named re-read a user on
    /// a flaky connection would be left with the destructive door disabled
    /// behind a missing preview.
    static let comparisonUnavailable = String(
        localized: "iCloudの内容を確認できませんでした。通信を確認して「\(retryPreviewTitle)」を押してください。どちらの記録も削除していません。",
        table: "Storage", comment: "The read-only iCloud check failed on the launch screen. %@ is the title of the re-check button")
    /// The re-read control the sentence above names. Non-destructive: it
    /// re-arms the read-only pre-flight and nothing else.
    static let retryPreviewTitle = String(
        localized: "iCloudの内容をもう一度確認", table: "Storage",
        comment: "Button: run the read-only iCloud check again (nothing is changed)")
    /// The same failure, in Settings, where the control that re-reads is the
    /// door itself. Each surface names the control it actually carries.
    static let settingsPreviewUnavailable = String(
        localized: "iCloudの内容を確認できませんでした。通信を確認して、もう一度「\(confirmTitle)」を押してください。どちらの記録も削除していません。",
        table: "Storage", comment: "The read-only iCloud check failed. %@ is the title of the button to tap again")

    static let dataLossWarning = String(
        localized: "iCloudにある現在のPomoGemのテーマ・記録・設定を削除し、このiPhoneのデータで置き換えます。2つのデータは結合しません。削除したiCloudのデータを元に戻すことはできません。同じApple Accountの他の端末は、次に開いたときにこの画面と同じ確認を求められ、その端末だけにある未送信のデータは残りません。",
        table: "Storage", comment: "Irreversible: what replacing iCloud with this iPhone's data deletes")

    /// transfer-10. The reason line under a CLOSED replacement door, in
    /// Settings and on the launch screen. `StorageTransferReleaseError` keeps
    /// its own text because it is also thrown when an already accepted
    /// replacement is refused on resume, where a recovery copy can exist; at a
    /// closed door nothing was ever staged, so this line promises none. It
    /// also reports no event: nobody pressed this door, so 「削除していません」
    /// would reassure about an operation that never happened.
    static let doorUnavailable = String(
        localized: "複数端末での同時操作から記録を保護するため、この操作はいまは利用できません。",
        table: "Storage", comment: "Reason under a replacement button that this build keeps disabled")

    static let exportTitle = String(
        localized: "先にこの端末の記録を書き出す", table: "Storage",
        comment: "Button: export this device's records before a switch deletes them")
    /// One sentence for every export control (the transfer screens and the
    /// reset guidance page), naming the app as its Home Screen icon does.
    static let exportNote = String(
        localized: "書き出したファイルはポモジェムに読み込めません。記録の控えとして保存します。",
        table: "Storage", comment: "Under every export button: the exported file cannot be imported back")
    static let confirmTitle = String(
        localized: "このiPhoneのデータで置き換える", table: "Storage",
        comment: "Destructive button: replace iCloud's data with this iPhone's")

    /// Rendered instead of either §6.2 variant while no server read has
    /// succeeded. Both approved variants claim that a search happened; saying
    /// 「見つかりませんでした」 before anything was read would be a false witness on
    /// the one screen where a deletion is chosen. The destructive door is
    /// disabled in exactly this state.
    static let otherDevicesUnknown = String(
        localized: "iCloudの記録をまだ読み取れていないため、このiPhone以外の端末が書き込んでいるかどうかは分かりません。",
        table: "Storage", comment: "Other-device evidence before iCloud has been read")

    /// Absence of evidence is disclosed as absence of evidence. A device that
    /// has never written a witnessed row does not appear here, so a zero is
    /// never phrased as a guarantee that no other device exists.
    static func otherDevices(_ count: Int) -> String {
        guard count >= 1 else {
            return String(
                localized: "iCloudの記録には、このiPhone以外の端末は見つかりませんでした。ただし、これは他の端末が存在しない証明ではありません。まだ一度も記録を送っていない端末は分かりません。同じApple Accountの他の端末でPomoGemを開いている場合は、先に終了してください。",
                table: "Storage", comment: "Other-device evidence when iCloud's records show no other device")
        }
        return String(
            localized: "iCloudの記録には、このiPhone以外の端末（\(count)台）が書き込んだ記録があります。置き換えると、それらの端末は次に開いたときに「iCloudのデータが置き換わりました」の画面になり、その端末だけにある未送信の記録は失われます。置き換える前に、その端末でPomoGemを開いて同期を終わらせておくと、失われる記録を減らせます。",
            table: "Storage",
            comment: "Other-device evidence. %lld is the number of other devices that wrote to iCloud (en: plural variations). The quoted title is the screen those devices will show")
    }

    // MARK: 「最後の確認」

    static let sheetTitle = String(localized: "最後の確認", table: "Storage",
                                   comment: "Title of the last confirmation before an irreversible switch")
    static let sheetWarning = String(
        localized: "現在iCloudにあるPomoGemのテーマ・記録・設定をすべて削除し、この端末のデータに置き換えます。削除するiCloudのデータを元に戻すことはできません。",
        table: "Storage", comment: "Final confirmation: replacing iCloud deletes everything in it")
    static let recoveryCopy = String(
        localized: "置き換えるデータの復旧用コピーをiCloudに保存し、受領を確認してから削除を始めます。復旧用コピーには、このiPhoneだけの過去の記録も含まれます。処理完了後に復旧用コピーを削除します。通信が途切れた場合は、削除の再試行までiCloudに残ることがあります。",
        table: "Storage", comment: "Final confirmation: the recovery copy saved to iCloud before anything there is deleted")
    static let relaunch = StorageTransferRefreshCopy.relaunch
    static let notCancellable = String(
        localized: "iCloudの削除を始めたあとは取り消せません。中断しても、次に開いたときに続きから再開します。",
        table: "Storage", comment: "Final confirmation: once deletion in iCloud starts it cannot be canceled")
    static let screenTime = String(
        localized: "スクリーンタイムの連携を使っている場合は、監視を停止し、対応する設定と端末内の台帳を初期化します。",
        table: "Storage", comment: "Final confirmation: what replacing iCloud does to Screen Time")
    static let acknowledgement = String(
        localized: "iCloudのデータの削除と、他の端末への影響を確認しました", table: "Storage",
        comment: "Acknowledgement toggle before iCloud's data is deleted and replaced")
    static let sheetConfirm = String(localized: "iCloudを置き換える", table: "Storage",
                                     comment: "Destructive button that confirms replacing iCloud's data")

    // MARK: Progress and relaunch

    static let requestAccepted = String(
        localized: "このiPhoneのデータでiCloudを置き換える手続きを受け付けました。Appスイッチャーでポモジェムを終了し、もう一度開いてください。復旧用コピーの保存が終わるまで、iCloudの削除は始めません。",
        table: "Storage", comment: "Relaunch screen after replacing iCloud with this iPhone's data was accepted")

    /// Derived from the durable journal phase, never from an optimistic guess
    /// about an in-flight effect.
    static func progress(_ phase: StorageTransferJournal.Phase) -> String {
        switch phase {
        case .requested, .sourceSaved:
            String(localized: "このiPhoneのデータを確認しています", table: "Storage",
                   comment: "Replacing iCloud, step 1: checking this iPhone's data")
        case .recoveryCopySaved:
            String(localized: "復旧用コピーをiCloudに保存しました。置き換えを始めます", table: "Storage",
                   comment: "Replacing iCloud, step 2: the recovery copy is saved")
        case .preparingDestination:
            String(localized: "iCloudのデータを置き換えています。アプリを閉じても、次に開いたときに続きから再開します",
                   table: "Storage", comment: "Replacing iCloud, step 3: iCloud's data is being replaced")
        case .destinationSaved, .destinationVerified:
            String(localized: "置き換えた内容を照合しています", table: "Storage",
                   comment: "Replacing iCloud, step 4: verifying what was written")
        case .selectionCommitted, .sourceRetired:
            String(localized: "置き換えを完了しています", table: "Storage",
                   comment: "Replacing iCloud, last step")
        }
    }

    // MARK: `.blocked`

    /// The honest 「explain, do not offer」 screen. It may only promise what the
    /// next screen can actually offer: while
    /// `StorageTransferReleasePolicy.allowsDatasetOverwriteFromDevice` is false
    /// the overwrite door there is permanently disabled, so naming it here
    /// would send a user to a greyed-out control and leave the direction that
    /// discards THEIR device data as the only door they can open.
    ///
    /// transfer-06. Shown only on the one `.blocked` route whose retry can
    /// reach the refresh choice (`presentDatasetRefresh` could not read
    /// iCloud). Its message already asks the user to check the connection and
    /// says nothing was deleted, so this adds only what comes next.
    static func blockedExplanation(offersOverwrite: Bool) -> String {
        guard offersOverwrite else {
            return String(
                localized: "iCloudを読み取れれば、「もう一度試す」のあとに、iCloudのデータを再取得する選択肢が表示されます。",
                table: "Storage",
                comment: "Under a blocked launch screen. 「もう一度試す」 quotes that screen's Try Again button (Launch table)")
        }
        return String(
            localized: "iCloudを読み取れれば、「もう一度試す」のあとに、iCloudのデータを再取得するか、このiPhoneのデータでiCloudを置き換えるかを選べます。",
            table: "Storage",
            comment: "Under a blocked launch screen. 「もう一度試す」 quotes that screen's Try Again button (Launch table)")
    }

    // MARK: Late arrival (§6.5)

    /// PLAN Step 9's non-blocking banner. A hedged detector, never a claim of
    /// fact: `Docs/MultiDeviceCloudSafety.md` defect 1 cannot be prevented, and
    /// a device that flushes days later is never caught. Neither offered action
    /// is destructive.
    static let lateArrival = String(
        localized: "置き換えの後に、他の端末から古い記録が届いた可能性があります。削除したはずのテーマが戻っていないか確認してください。もう一度この端末のデータで置き換えることもできます。",
        table: "Storage", comment: "Banner after a replacement: old records from another device may have arrived")
    static let lateArrivalOpenSettings = String(localized: "設定を開く", table: "Storage",
                                                comment: "Late-arrival banner button: open the app's Settings")
    static let lateArrivalDismiss = String(localized: "このまま使う", table: "Storage",
                                           comment: "Late-arrival banner button: dismiss and keep using the app as is")

    // MARK: The comparison row

    /// The year is part of the evidence, not decoration: without it a device
    /// last used in September 2025 and a dataset from September 2026 render two
    /// days apart, and this date is the only recency signal on the screen where
    /// an irreversible deletion is chosen. `DateText.longDate` always prints
    /// the year, on the Gregorian calendar in the app's language (ja
    /// 「2026年9月20日」, as before; en "September 20, 2026"), so the rendered
    /// string stays pinnable by a unit test.
    private static func comparisonDate(_ date: Date) -> String {
        DateText.longDate(date)
    }

    /// The device row's label in Settings' comparisons, beside the 「iCloud」
    /// row. ("iCloud" is the service's name in every language.)
    static let thisIPhoneSide = String(
        localized: "このiPhone", table: "Storage",
        comment: "Label of this iPhone's row in the record comparison, as in 「このiPhone: テーマ12・記録480…」")

    /// The first sentence of both empty-iCloud warnings.
    static let cloudHoldsNoUserRecords = String(
        localized: "iCloudには、このアプリの記録と成果が1件も見つかりませんでした。", table: "Storage",
        comment: "First sentence of the warning shown when iCloud holds none of the user's records")

    /// The three counts a user recognizes, as text in `locale`'s digits. They
    /// are passed as text, not as Int: the Japanese has always printed
    /// 「記録1234」, and an interpolated Int would group it as 「記録1,234」, so
    /// Japanese keeps ungrouped digits. Every other language groups them the
    /// way its readers expect ("Records 1,234"). English labels each count
    /// instead of pluralizing a noun, so no plural variation is needed.
    static func countArguments(
        _ preview: StorageTransferCloudPreview,
        locale: Locale = PomoGemLocale.current
    ) -> (String, String, String) {
        let counts = preview.recordCounts
        func digits(_ key: String) -> String {
            let value = counts[key] ?? 0
            return PomoGemLocale.composesJapanese(locale) ? String(value) : PomoGemLocale.grouped(value, locale: locale)
        }
        return (digits("Subject"), digits("StudySession"), digits("AchievementStone"))
    }

    /// W6. The iCloud row when the server holds records but no transfer
    /// control record. The counts come from the read-only snapshot and are
    /// the same three a user recognizes on every other row.
    ///
    /// transfer-03 / transfer-10. It used to read 「iCloud側の管理情報なし（記録
    /// 件数: n）」: an internal term, and one total across all seven mirrored
    /// models, so a server holding only a Prefs row and a device claim read as
    /// 「記録件数: 2」 — "your records are in iCloud" — on the screen where the
    /// device's own records are deleted. The row still omits the 「最終」 date:
    /// with no ledger the newest mirrored timestamp is as likely to be a Prefs
    /// stamp as a record, and whether a ledger exists is stated, where it
    /// changes what an action does, by its own paragraph.
    static func cloudSideWithoutLineage(preview: StorageTransferCloudPreview?) -> String {
        countsOnly("iCloud", preview: preview)
    }

    /// The same three counts, without the 「最終」 date. Used for an iCloud
    /// side whose newest mirrored timestamp may be a Prefs stamp rather than
    /// anything the user recorded.
    static func countsOnly(_ label: String, preview: StorageTransferCloudPreview?) -> String {
        guard let preview else { return side(label, preview: nil) }
        return String(localized: "\(label): \(counts(preview))", table: "Storage",
                      comment: "Comparison row without a date. The arguments are the side (This iPhone / iCloud) and its counts")
    }

    /// 「テーマ12・記録480・成果36（最終 2026年9月20日）」. Only the three models a
    /// user recognizes are named; the remaining mirrored models are counted by
    /// the runtime but would not help someone decide.
    static func side(_ label: String, preview: StorageTransferCloudPreview?) -> String {
        guard let preview else {
            return String(localized: "\(label): 確認できませんでした", table: "Storage",
                          comment: "Comparison row when a side could not be read. %@ is the side (This iPhone / iCloud)")
        }
        let body = counts(preview)
        guard let latest = preview.latestRecordAt else {
            return String(localized: "\(label): \(body)（日付のある記録なし）", table: "Storage",
                          comment: "Comparison row with no dated record. The arguments are the side (This iPhone / iCloud) and its counts")
        }
        return String(localized: "\(label): \(body)（最終 \(comparisonDate(latest))）", table: "Storage",
                      comment: "Comparison row. The arguments are the side (This iPhone / iCloud), its counts and the date of its newest record")
    }

    private static func counts(_ preview: StorageTransferCloudPreview) -> String {
        let (themes, records, achievements) = countArguments(preview)
        return String(localized: "テーマ\(themes)・記録\(records)・成果\(achievements)", table: "Storage",
                      comment: "Counts in a comparison row: themes, records (focus sessions) and achievements, as digit text (ungrouped in Japanese, grouped in English)")
    }
}

/// transfer-04. Which transfer the launch host is continuing, and where its
/// durable journal is. Presentation only.
struct StorageTransferProgress: Equatable, Sendable {
    let choice: StorageTransferChoice
    let phase: StorageTransferJournal.Phase
}

/// transfer-04. Every storage switch continues across one or more planned
/// relaunches. The launch host used to call each planned continuation
/// 「中断された保存先の切り替えを再開しています」, which reads as a failure,
/// and showed phase copy for the unpublished overwrite only.
enum StorageTransferProgressCopy {
    static let continuing = String(localized: "保存先の切り替えを続けています", table: "Storage",
                                   comment: "Launch progress while a storage switch continues after a planned relaunch")

    /// After a confirmed 「iCloudから再取得」 has been recorded by the runtime:
    /// the next launch starts receiving iCloud's data.
    static let refreshReady = String(
        localized: "iCloudから取り込む準備ができました。Appスイッチャーでポモジェムを終了し、もう一度開いてください。次に開くと、iCloudからの受信を始めます。iCloudのデータは削除しません。",
        table: "Storage", comment: "Relaunch screen: re-downloading from iCloud starts on the next launch")

    static let nextLaunchCompletes = String(
        localized: "次に開くと、保存先の切り替えが完了します。", table: "Storage",
        comment: "Relaunch screen: the storage switch finishes on the next launch")

    /// How, not only that. The launch host deliberately offers no button here.
    /// The app is named as the App Switcher card and the Home Screen icon name
    /// it (CFBundleDisplayName), because that is where the user looks for it.
    static let relaunchInstructions = String(
        localized: "Appスイッチャーを開き（画面の下端から上にスワイプして指を止めるか、ホームボタンを2回押します）、ポモジェムを上にスワイプして閉じてから、ホーム画面のアイコンで開き直してください。この画面で待っていても先へは進みません。",
        table: "Storage", comment: "Relaunch screen: how to quit and reopen the app with the App Switcher")
    /// Every message that carries this warning appends this very entry with
    /// `SentenceText`, rather than repeating the sentence in its own catalog
    /// entry, so `relaunchInstructions(after:)` finds it in every language.
    static let keepTheApp = String(localized: "アプリ自体は削除しないでください。", table: "Storage",
                                   comment: "Relaunch warning: quit the app, but do not delete it")

    /// The caption under a relaunch message. Most messages already ask the
    /// user to quit and reopen and some already say not to delete the app;
    /// the caption adds the steps, and the warning only when it is missing,
    /// so the screen never says the same sentence twice.
    static func relaunchInstructions(after message: String) -> String {
        message.contains(keepTheApp) ? relaunchInstructions : SentenceText.join([relaunchInstructions, keepTheApp])
    }

    /// Derived from the durable journal phase, never from an optimistic guess
    /// about an in-flight effect, so a relaunch shows the same sentence.
    static func progress(_ progress: StorageTransferProgress) -> String {
        switch progress.choice {
        case .overwriteCloudFromDevice, .enableCloudReplacingCloud:
            return StorageTransferOverwriteCopy.progress(progress.phase)
        case .enableCloudKeepingCloud:
            switch progress.phase {
            case .requested, .sourceSaved, .recoveryCopySaved:
                return checkingCurrentRecords
            case .preparingDestination:
                return String(
                    localized: "iCloudからデータを受け取っています。数分かかることがあります。画面を開いたままお待ちください",
                    table: "Storage", comment: "Turning on iCloud, step 2: receiving iCloud's data")
            case .destinationSaved, .destinationVerified:
                return String(localized: "受け取った内容を照合しています", table: "Storage",
                              comment: "Turning on iCloud, step 3: verifying what was received")
            case .selectionCommitted, .sourceRetired:
                return finishingSwitch
            }
        case .disableCloudKeepingCopy:
            switch progress.phase {
            case .requested, .sourceSaved, .recoveryCopySaved:
                return checkingCurrentRecords
            case .preparingDestination:
                return String(localized: "iCloudのデータをこのiPhoneへコピーしています", table: "Storage",
                              comment: "Moving to this iPhone, step 2: copying iCloud's data")
            case .destinationSaved, .destinationVerified:
                return String(localized: "コピーした内容を照合しています", table: "Storage",
                              comment: "Moving to this iPhone, step 3: verifying the copy")
            case .selectionCommitted, .sourceRetired:
                return finishingSwitch
            }
        }
    }

    private static var checkingCurrentRecords: String {
        String(localized: "いまの記録を確認しています", table: "Storage",
               comment: "Storage switch, step 1: checking the current records")
    }

    private static var finishingSwitch: String {
        String(localized: "切り替えを完了しています", table: "Storage", comment: "Storage switch, last step")
    }
}

/// The fixed copy (Storage table) for the launch screens the split dataset-lineage
/// taxonomy reaches (ROOT-CAUSE §6.2). Kept beside the other two copy holders
/// so every sentence a stop reason can produce is diffable in one place.
///
/// Two of the three screens are explanation-only. The third — the
/// `cloudLineageUnavailable` screen — is the state the reported iPhone is
/// actually in. device-01: it leads with the choices this build can actually
/// run (keep using this iPhone's records offline, or take iCloud's data back
/// with 「iCloudから再取得」), and only a build that publishes
/// `allowsDatasetOverwriteFromDevice` adds starting a NEW iCloud lineage from
/// this device behind its own 「最後の確認」.
enum StorageTransferLineageCopy {
    // MARK: The `cloudLineageUnavailable` screen

    /// Plain words for what the user can see happening. The old title named
    /// an internal record (「iCloudの管理情報が見つかりません」).
    static let title = String(localized: "iCloudとの同期を止めています", table: "Storage",
                              comment: "Launch stop screen title: sync with iCloud is stopped")
    static let startDoorTitle = String(
        localized: "このiPhoneのデータでiCloudを使い始める", table: "Storage",
        comment: "Section title and destructive button: start a new iCloud dataset from this iPhone's data")
    /// review-1-1 / review-2-2. The missing thing is the transfer CONTROL
    /// record, not the account's records: `refreshCloudDatasetWithoutLineage`
    /// exists precisely because rows under a missing control record are real
    /// and mirrorable. This sentence therefore says what the action does to
    /// them, and the screen renders the enumerated counts beside it.
    static let startExplanation = String(
        localized: "iCloud側に、このアプリが使っている管理情報が見つかりません。このiPhoneの記録をiCloudへ送信し、新しいiCloudのデータとして使い始めます。このiPhoneの記録は削除しません。iCloudに残っている記録は削除され、このiPhoneのデータで置き換えられます。",
        table: "Storage", comment: "What starting iCloud from this iPhone's data does, including the deletion in iCloud")

    /// review-2-5. The stop reason itself promises nothing: it is also the
    /// error text an offline session shows when its retry meets this state.
    /// transfer-01 / device-01: it no longer blames 「別のビルド（開発用／配布
    /// 用）」, a cause that does not exist for an App Store user. Nor does it
    /// guess any other cause: the state is reached by an older-generation
    /// receipt, or by a receipt-less store the 1.0 / 1.0.1 adoption rule does
    /// not take (Docs/iCloudSyncTroubleshooting.md), and a user whose iCloud
    /// data was deleted usually holds neither. It states what was observed and
    /// what was not done; the doors below say what can be done.
    static let stopReason = String(
        localized: "iCloudのデータとこのiPhoneの記録の対応を確認できないため、記録が混ざらないよう同期を止めています。このiPhoneの記録もiCloudのデータも削除していません。",
        table: "Storage", comment: "Why sync is stopped: iCloud's data and this iPhone's records cannot be matched")
    static let startAndOfflineChoices = String(
        localized: "このiPhoneのデータでiCloudを使い始めるか、オフラインのまま使うかを選べます。",
        table: "Storage", comment: "The two choices on the stop screen when both are offered")

    /// The screen's message. `offersLineageStart` is the release bit, so the
    /// app never states a choice and then refuses it in the next paragraph;
    /// a build that does not publish the start door adds no closing sentence
    /// at all, and each door below explains itself.
    static func screenMessage(offersLineageStart: Bool) -> String {
        offersLineageStart ? SentenceText.join([stopReason, startAndOfflineChoices]) : stopReason
    }
    static let offlineDoorTitle = String(localized: "オフラインのまま使う", table: "Storage",
                                         comment: "Section title and button: keep using this iPhone's records offline")
    /// device-01. The old sentence promised 「あとでこの画面から、このiPhoneの
    /// データでiCloudを使い始めることもできます」 in a build where that door is
    /// permanently disabled, so a user who chose offline had no enabled way
    /// back. Built from the release bit, like `screenMessage`.
    ///
    /// It also says what a later 「iCloudから再取得」 does to what is recorded
    /// offline: that door is the shipping build's way back to sync, and it
    /// discards this iPhone's records — including everything added meanwhile.
    /// Also used on `.datasetRefresh`, whose offline session carries the same
    /// 「復旧手順」 route back.
    static func offlineExplanation(offersLineageStart: Bool) -> String {
        let base = String(
            localized: "iCloudへ送信せず、このiPhoneに保存されている記録でそのまま使います。変更はこのiPhoneに保存されますが、iCloudとの同期は止まったままです。どちらの記録も削除しません。",
            table: "Storage", comment: "What keeping this iPhone's records offline does")
        let wayBack = offersLineageStart
            ? String(localized: "あとでこの画面から、このiPhoneのデータでiCloudを使い始めることもできます。",
                     table: "Storage", comment: "Offline choice: the way back when starting iCloud from this iPhone is offered")
            : String(localized: "同期を再開する方法は、利用中の画面上部の「復旧手順」からいつでも確認できます。",
                     table: "Storage",
                     comment: "Offline choice: the way back. 「復旧手順」 quotes the offline banner's Recovery Steps button (Launch table)")
        return SentenceText.join([base, wayBack, offlineChangesAreDiscardedByRefresh])
    }
    static let offlineChangesAreDiscardedByRefresh = String(
        localized: "あとで「\(StorageTransferRefreshCopy.confirmTitle)」を選ぶと、オフラインで記録した変更も削除されます。",
        table: "Storage", comment: "Offline choice: %@ is the re-download button, which also deletes changes recorded offline")
    /// Offered only when the offline route is actually eligible. When it is
    /// not, the screen says why instead of showing a control that does nothing.
    static let offlineUnavailable = String(
        localized: "このiPhoneには、オフラインで開ける確認済みの記録がまだありません。どちらの記録も削除していません。",
        table: "Storage", comment: "Why the offline choice is not offered")

    /// The banner message of an offline session opened FROM a storage-transfer
    /// stop screen. The generic 「接続回復後に同期を再開します」 is false there:
    /// a restored connection meets the same stop again, so the banner carries
    /// the 「復旧手順」 action instead of an automatic-resume promise.
    static let offlineSessionMessage = String(
        localized: "iCloudとの同期は止まったままです。変更はこのiPhoneに保存されます。「復旧手順」から、同期を再開する方法をいつでも確認できます。",
        table: "Storage",
        comment: "Offline banner after a storage stop screen. 「復旧手順」 quotes the banner's Recovery Steps button (Launch table)")

    // MARK: 「iCloudから再取得」 on this screen

    /// The policy-free way back to sync on this screen. It is the SAME
    /// `refreshCloudDatasetWithoutLineage` Settings already ships for accounts
    /// without a ledger: it writes nothing to iCloud and deletes this
    /// device's side only after the read-only pre-flight, the empty-iCloud
    /// warning and its own unchecked acknowledgement in 「最後の確認」. The
    /// section is named after its button and the sheet's confirm, so one
    /// operation has one name on this screen.
    static let refreshDoorTitle = StorageTransferRefreshCopy.confirmTitle
    static let refreshExplanation = String(
        localized: "iCloudにあるデータをこのiPhoneに取り込み直して、同期を再開します。このiPhoneのテーマ・記録・設定は削除され、iCloudのデータに置き換わります。2つのデータは結合しません。iCloudのデータは削除しません。",
        table: "Storage", comment: "What re-downloading from iCloud does on the stop screen, including the deletion on this iPhone")

    // MARK: 「最後の確認」 for the start-from-device action

    static let sheetTitle = StorageTransferOverwriteCopy.sheetTitle
    /// review-1-1 / review-2-2. The previous wording asserted 「現在のiCloudには、
    /// このアプリが使えるPomoGemのデータがありません」 — an unverified factual
    /// claim about the server, on the one screen where an irreversible
    /// deletion of that server's rows is authorized. `startCloudLineageFromDevice`
    /// opens an `.overwriteCloudFromDevice` journal whose `replacesCloud` is
    /// true, so `prepareDestination` purges the mirrored zone; the staged
    /// recovery copy is this device's payload and backs none of it up.
    static let sheetWarning = String(
        localized: "iCloud側には、このアプリが使っている管理情報がありません。そのため、この操作は「置き換え」ではなく、このiPhoneのデータでiCloudを新しく使い始める操作になります。いまiCloudに残っている記録は削除し、このiPhoneのテーマ・記録・設定で置き換えます。削除したiCloudのデータを元に戻すことはできません。",
        table: "Storage", comment: "Final confirmation for starting iCloud from this iPhone: the records left in iCloud are deleted")
    static let sheetOtherBuilds = String(
        localized: "同じApple Accountの他の端末や、別のビルド（開発用／配布用）のPomoGemがこのアカウントを使っている場合、それらの端末は次に開いたときにiCloudのデータを取得し直す確認を求められます。その端末だけにある未送信の記録は残りません。",
        table: "Storage", comment: "Final confirmation for starting iCloud from this iPhone: the effect on other devices")
    static let sheetRelaunch = StorageTransferOverwriteCopy.relaunch
    static let sheetScreenTime = StorageTransferOverwriteCopy.screenTime
    /// It names the deletion, because the action performs one. The previous
    /// sentence mentioned only sending this iPhone's data and asking other
    /// devices to re-fetch.
    static let acknowledgement = String(
        localized: "iCloudに残っている記録の削除と、他の端末への影響を確認しました", table: "Storage",
        comment: "Acknowledgement toggle before starting iCloud from this iPhone deletes the records left in iCloud")
    static let sheetConfirm = String(localized: "iCloudを使い始める", table: "Storage",
                                     comment: "Destructive button that confirms starting iCloud from this iPhone's data")

    static let requestAccepted = SentenceText.join([
        String(localized: "このiPhoneのデータでiCloudを使い始める手続きを受け付けました。Appスイッチャーでポモジェムを終了し、もう一度開いてください。",
               table: "Storage", comment: "Relaunch screen after starting iCloud from this iPhone's data was accepted"),
        StorageTransferProgressCopy.keepTheApp
    ])

    // MARK: The explanation-only screens

    static let environmentMismatchTitle = String(
        localized: "別のiCloud環境のデータです", table: "Storage",
        comment: "Launch stop screen title: the records belong to a different iCloud environment (development or release)")
    /// No door of any kind: nothing this build can run is meaningful against a
    /// database it does not talk to. It says what to do OUTSIDE the app.
    static let environmentMismatchExplanation = String(
        localized: "この端末の記録は、いまのアプリとは別のiCloud環境（開発用／配布用）で作られたものです。この画面では、どちらの記録も削除していません。記録を作ったときと同じビルドのPomoGemで開き直すか、サポートの手順をご確認ください。",
        table: "Storage", comment: "Explanation on the different-iCloud-environment stop screen")

    static let localLedgerMissingTitle = String(
        localized: "iCloudのデータを受け取った記録がありません", table: "Storage",
        comment: "Launch stop screen title: this device has no record of receiving iCloud's current data")
    /// review-1-4. This screen is reached only from the SUCCESS branch of
    /// `presentDatasetRefresh`: the server read worked and reported no
    /// terminal committed generation. A read that throws produces
    /// `refreshScreenUnavailable` instead. The copy therefore states what was
    /// observed and never names a network cause that was not.
    static let localLedgerMissingExplanation = String(
        localized: "この端末には、いまiCloudにあるデータを受け取った記録がありません。iCloud側にも、再取得の元になる管理情報は見つかりませんでした。そのため、この画面では再取得の選択肢を表示できません。この画面では、どちらの記録も削除していません。",
        table: "Storage", comment: "Explanation on the no-receipt stop screen")

    // MARK: Settings, when the account has no transfer ledger (W6)

    /// Shown in the device → iCloud 「最後の確認」 when the pre-flight found
    /// records on the server but NO transfer control record. The sheet's first
    /// paragraph says the iCloud dataset is deleted and replaced; with no
    /// ledger that is not the whole truth, because this direction STARTS one.
    static let settingsStartsLineage = String(
        localized: "iCloud側には、このアプリが使っている管理情報がありません。そのため、この操作は「置き換え」ではなく、このiPhoneのデータでiCloudを新しく使い始める操作になります。iCloudに残っている記録は、このiPhoneのデータで置き換えられます。",
        table: "Storage", comment: "Settings final confirmation when iCloud has no transfer ledger: this starts one")

    /// P1-4 (ROOT-CAUSE §6.1). The catch arm of `presentDatasetRefresh` used to
    /// put the CAUGHT error's own text on the generic blocked screen, which
    /// hid — from the user and from the operator — that the rescue UI could not
    /// be built at all. The failure now names itself.
    static let refreshScreenUnavailable = String(
        localized: "iCloud側の情報を読み取れなかったため、復旧の選択肢を表示できません。通信を確認して、もう一度お試しください。どちらの記録も削除していません。",
        table: "Storage", comment: "Blocked launch screen: iCloud could not be read, so no recovery choices can be shown")
}
