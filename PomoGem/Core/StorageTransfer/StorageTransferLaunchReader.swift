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
            "この端末の記録を読み取れませんでした。記録は変更していません。"
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

/// The fixed Japanese copy for the iCloud → device direction — 「iCloudから再取得」
/// — kept here so both surfaces that offer it quote one text. It destroys the
/// DEVICE side, never the server side, and says so in every sentence.
enum StorageTransferRefreshCopy {
    static let settingsTitle = "iCloudのデータでこの端末を置き換える"
    static let dataLossWarning =
        "この端末のテーマ・記録・設定を削除し、現在のiCloudのデータに置き換えます。未送信の端末データは失われ、iCloudのデータとは結合されません。iCloudのデータは残ります。"
    static let relaunch = "処理の途中で、アプリの終了と再起動をお願いします。アプリ自体は削除しないでください。"
    static let acknowledgement = "端末データの削除を確認しました"
    static let confirmTitle = "iCloudから再取得"

    static let requestAccepted =
        "iCloudのデータでこの端末を置き換える手続きを受け付けました。Appスイッチャーでポモジェムを終了し、もう一度開いてください。iCloudのデータは削除しません。"

    /// review-1-2 / review-2-4. This direction deletes the DEVICE side and
    /// stages no recovery copy anywhere, so the user may not be asked to
    /// authorize it without being told what is actually on the side they are
    /// about to fetch from. The read is read-only and gates nothing else.
    static let settingsPreviewUnavailable =
        "iCloudの内容を確認できませんでした。通信を確認して、もう一度「\(confirmTitle)」を押してください。どちらの記録も削除していません。"

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
    static func cloudSideEmpty(device: StorageTransferCloudPreview?) -> String {
        let loss: String
        if let device {
            let counts = device.recordCounts
            loss = "このiPhoneのテーマ\(counts["Subject"] ?? 0)・記録\(counts["StudySession"] ?? 0)・成果\(counts["AchievementStone"] ?? 0)を含む、テーマ・記録・設定はすべて削除され、元に戻すことはできません。"
        } else {
            loss = "このiPhoneのテーマ・記録・設定は削除され、元に戻すことはできません。"
        }
        return "iCloudには、このアプリの記録と成果が1件も見つかりませんでした。このまま実行すると、" + loss
            + "中止して、先にこの端末の記録を書き出すか、他の端末の同期が終わるのをお待ちください。"
    }

    /// True only when a read actually succeeded and found none of the user's
    /// own records. A missing preview is never reported as an empty dataset.
    static func cloudSideIsEmpty(_ preview: StorageTransferCloudPreview?) -> Bool {
        preview?.userContentRecordCount == 0
    }
}

/// transfer-02. The fixed Japanese copy for the one published local-only →
/// iCloud door, 「iCloudのデータを使う」. It deletes the device's whole jar, so
/// its confirmation now carries the same read-only evidence as the refresh
/// door: what each side holds, and a warning when iCloud holds none of the
/// user's records.
enum StorageTransferEnableCopy {
    static let keepCloudTitle = "iCloudのデータを使う"
    static let previewUnavailable =
        "iCloudの内容を確認できませんでした。通信とApple Accountを確認して、もう一度「\(keepCloudTitle)」を押してください。どちらの記録も削除していません。"

    /// Deliberately not the refresh door's sentence: here the user is turning
    /// iCloud ON, and an empty iCloud means the synced jar starts from zero.
    static func cloudSideEmpty(device: StorageTransferCloudPreview?) -> String {
        let loss: String
        if let device {
            let counts = device.recordCounts
            loss = "このiPhoneのテーマ\(counts["Subject"] ?? 0)・記録\(counts["StudySession"] ?? 0)・成果\(counts["AchievementStone"] ?? 0)を含む、テーマ・記録・設定はすべて削除され、"
        } else {
            loss = "このiPhoneのテーマ・記録・設定はすべて削除され、"
        }
        return "iCloudには、このアプリの記録と成果が1件も見つかりませんでした。このまま実行すると、" + loss
            + "空の状態からiCloudの同期を始めます。元に戻すことはできません。"
    }
}

/// transfer-07. Every published storage switch moves to a different storage
/// namespace, and the Screen Time ledger is bound to that namespace
/// (Docs/ScreenTimeGems.md: the selection, unimported reached events and
/// black gems are not carried over). Not carrying them is intended; not
/// saying so is what made users conclude the feature broke.
enum StorageTransferScreenTimeCopy {
    static let switchResets =
        "切り替えると、スクリーンタイムの自動記録はオフになり、選んだアプリ、まだ取り込んでいない利用記録、黒いgemは引き継ぎません。切り替えたあとで、設定の「スクリーンタイム」から選び直してください。保存済みの勉強時間と通常gemは引き継ぎます。"

    /// The same facts for the launch host's 「iCloudから再取得」 doors. No store
    /// is mounted there, so no Screen Time owner is bound and whether the
    /// feature is in use cannot be read; Settings shows `switchResets` only
    /// while it is. The conditional form is true either way, and these stop
    /// screens are rare enough that a sentence a non-user can skip costs less
    /// than a reset nobody was told about.
    static let switchResetsIfInUse =
        "スクリーンタイムの自動記録を使っている場合、切り替えると自動記録はオフになり、選んだアプリ、まだ取り込んでいない利用記録、黒いgemは引き継ぎません。切り替えたあとで、設定の「スクリーンタイム」から選び直してください。保存済みの勉強時間と通常gemは引き継ぎます。"
}

/// The fixed Japanese copy for the device → iCloud overwrite. It lives beside
/// the runtime rather than inside a view so the launch host, Settings and the
/// review notes quote one text, and so a reviewer can diff the shipped strings
/// against the approved wording in one place.
enum StorageTransferOverwriteCopy {
    static let comparisonReading = "iCloudの内容を確認しています"
    /// It must name a control that is on THIS screen, and the narrowest one:
    /// the re-read below re-arms the door in place, while the screen's own
    /// 「もう一度試す」 re-runs the whole launch. Without a named re-read a user on
    /// a flaky connection would be left with the destructive door disabled
    /// behind a missing preview.
    static let comparisonUnavailable =
        "iCloudの内容を確認できませんでした。通信を確認して「\(retryPreviewTitle)」を押してください。どちらの記録も削除していません。"
    /// The re-read control the sentence above names. Non-destructive: it
    /// re-arms the read-only pre-flight and nothing else.
    static let retryPreviewTitle = "iCloudの内容をもう一度確認"
    /// The same failure, in Settings, where the control that re-reads is the
    /// door itself. Each surface names the control it actually carries.
    static let settingsPreviewUnavailable =
        "iCloudの内容を確認できませんでした。通信を確認して、もう一度「\(confirmTitle)」を押してください。どちらの記録も削除していません。"

    static let dataLossWarning =
        "iCloudにある現在のPomoGemのテーマ・記録・設定を削除し、このiPhoneのデータで置き換えます。2つのデータは結合しません。削除したiCloudのデータを元に戻すことはできません。同じApple Accountの他の端末は、次に開いたときにこの画面と同じ確認を求められ、その端末だけにある未送信のデータは残りません。"

    /// transfer-10. The reason line under a CLOSED replacement door, in
    /// Settings and on the launch screen. `StorageTransferReleaseError` keeps
    /// its own text because it is also thrown when an already accepted
    /// replacement is refused on resume, where a recovery copy can exist; at a
    /// closed door nothing was ever staged, so this line promises none. It
    /// also reports no event: nobody pressed this door, so 「削除していません」
    /// would reassure about an operation that never happened.
    static let doorUnavailable =
        "複数端末での同時操作から記録を保護するため、この操作はいまは利用できません。"

    static let exportTitle = "先にこの端末の記録を書き出す"
    /// One sentence for every export control (the transfer screens and the
    /// reset guidance page), naming the app as its Home Screen icon does.
    static let exportNote = "書き出したファイルはポモジェムに読み込めません。記録の控えとして保存します。"
    static let confirmTitle = "このiPhoneのデータで置き換える"

    /// Rendered instead of either §6.2 variant while no server read has
    /// succeeded. Both approved variants claim that a search happened; saying
    /// 「見つかりませんでした」 before anything was read would be a false witness on
    /// the one screen where a deletion is chosen. The destructive door is
    /// disabled in exactly this state.
    static let otherDevicesUnknown =
        "iCloudの記録をまだ読み取れていないため、このiPhone以外の端末が書き込んでいるかどうかは分かりません。"

    /// Absence of evidence is disclosed as absence of evidence. A device that
    /// has never written a witnessed row does not appear here, so a zero is
    /// never phrased as a guarantee that no other device exists.
    static func otherDevices(_ count: Int) -> String {
        guard count >= 1 else {
            return "iCloudの記録には、このiPhone以外の端末は見つかりませんでした。ただし、これは他の端末が存在しない証明ではありません。まだ一度も記録を送っていない端末は分かりません。同じApple Accountの他の端末でPomoGemを開いている場合は、先に終了してください。"
        }
        return "iCloudの記録には、このiPhone以外の端末（\(count)台）が書き込んだ記録があります。置き換えると、それらの端末は次に開いたときに「iCloudのデータが置き換わりました」の画面になり、その端末だけにある未送信の記録は失われます。置き換える前に、その端末でPomoGemを開いて同期を終わらせておくと、失われる記録を減らせます。"
    }

    // MARK: 「最後の確認」

    static let sheetTitle = "最後の確認"
    static let sheetWarning =
        "現在iCloudにあるPomoGemのテーマ・記録・設定をすべて削除し、この端末のデータに置き換えます。削除するiCloudのデータを元に戻すことはできません。"
    static let recoveryCopy =
        "置き換えるデータの復旧用コピーをiCloudに保存し、受領を確認してから削除を始めます。復旧用コピーには、このiPhoneだけの過去の記録も含まれます。処理完了後に復旧用コピーを削除します。通信が途切れた場合は、削除の再試行までiCloudに残ることがあります。"
    static let relaunch = "処理の途中で、アプリの終了と再起動をお願いします。アプリ自体は削除しないでください。"
    static let notCancellable = "iCloudの削除を始めたあとは取り消せません。中断しても、次に開いたときに続きから再開します。"
    static let screenTime = "スクリーンタイムの連携を使っている場合は、監視を停止し、対応する設定と端末内の台帳を初期化します。"
    static let acknowledgement = "iCloudのデータの削除と、他の端末への影響を確認しました"
    static let sheetConfirm = "iCloudを置き換える"

    // MARK: Progress and relaunch

    static let requestAccepted =
        "このiPhoneのデータでiCloudを置き換える手続きを受け付けました。Appスイッチャーでポモジェムを終了し、もう一度開いてください。復旧用コピーの保存が終わるまで、iCloudの削除は始めません。"

    /// Derived from the durable journal phase, never from an optimistic guess
    /// about an in-flight effect.
    static func progress(_ phase: StorageTransferJournal.Phase) -> String {
        switch phase {
        case .requested, .sourceSaved:
            "このiPhoneのデータを確認しています"
        case .recoveryCopySaved:
            "復旧用コピーをiCloudに保存しました。置き換えを始めます"
        case .preparingDestination:
            "iCloudのデータを置き換えています。アプリを閉じても、次に開いたときに続きから再開します"
        case .destinationSaved, .destinationVerified:
            "置き換えた内容を照合しています"
        case .selectionCommitted, .sourceRetired:
            "置き換えを完了しています"
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
            return "iCloudを読み取れれば、「もう一度試す」のあとに、iCloudのデータを再取得する選択肢が表示されます。"
        }
        return "iCloudを読み取れれば、「もう一度試す」のあとに、iCloudのデータを再取得するか、このiPhoneのデータでiCloudを置き換えるかを選べます。"
    }

    // MARK: Late arrival (§6.5)

    /// PLAN Step 9's non-blocking banner. A hedged detector, never a claim of
    /// fact: `Docs/MultiDeviceCloudSafety.md` defect 1 cannot be prevented, and
    /// a device that flushes days later is never caught. Neither offered action
    /// is destructive.
    static let lateArrival =
        "置き換えの後に、他の端末から古い記録が届いた可能性があります。削除したはずのテーマが戻っていないか確認してください。もう一度この端末のデータで置き換えることもできます。"
    static let lateArrivalOpenSettings = "設定を開く"
    static let lateArrivalDismiss = "このまま使う"

    // MARK: The comparison row

    /// The year is part of the evidence, not decoration: without it a device
    /// last used in September 2025 and a dataset from September 2026 render two
    /// days apart, and this date is the only recency signal on the screen where
    /// an irreversible deletion is chosen. The format is explicit rather than
    /// templated so the rendered string is pinnable by a unit test.
    private static let comparisonFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "y年M月d日"
        return formatter
    }()

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
        return "\(label): \(counts(preview))"
    }

    /// 「テーマ12・記録480・成果36（最終 2026年9月20日）」. Only the three models a
    /// user recognizes are named; the remaining mirrored models are counted by
    /// the runtime but would not help someone decide.
    static func side(_ label: String, preview: StorageTransferCloudPreview?) -> String {
        guard let preview else { return "\(label): 確認できませんでした" }
        let body = counts(preview)
        guard let latest = preview.latestRecordAt else { return "\(label): \(body)（日付のある記録なし）" }
        return "\(label): \(body)（最終 \(comparisonFormatter.string(from: latest))）"
    }

    private static func counts(_ preview: StorageTransferCloudPreview) -> String {
        let counts = preview.recordCounts
        return "テーマ\(counts["Subject"] ?? 0)・記録\(counts["StudySession"] ?? 0)・成果\(counts["AchievementStone"] ?? 0)"
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
    static let continuing = "保存先の切り替えを続けています"

    /// After a confirmed 「iCloudから再取得」 has been recorded by the runtime:
    /// the next launch starts receiving iCloud's data.
    static let refreshReady =
        "iCloudから取り込む準備ができました。Appスイッチャーでポモジェムを終了し、もう一度開いてください。次に開くと、iCloudからの受信を始めます。iCloudのデータは削除しません。"

    static let nextLaunchCompletes = "次に開くと、保存先の切り替えが完了します。"

    /// How, not only that. The launch host deliberately offers no button here.
    /// The app is named as the App Switcher card and the Home Screen icon name
    /// it (CFBundleDisplayName), because that is where the user looks for it.
    static let relaunchInstructions =
        "Appスイッチャーを開き（画面の下端から上にスワイプして指を止めるか、ホームボタンを2回押します）、ポモジェムを上にスワイプして閉じてから、ホーム画面のアイコンで開き直してください。この画面で待っていても先へは進みません。"
    static let keepTheApp = "アプリ自体は削除しないでください。"

    /// The caption under a relaunch message. Most messages already ask the
    /// user to quit and reopen and some already say not to delete the app;
    /// the caption adds the steps, and the warning only when it is missing,
    /// so the screen never says the same sentence twice.
    static func relaunchInstructions(after message: String) -> String {
        message.contains(keepTheApp) ? relaunchInstructions : relaunchInstructions + keepTheApp
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
                return "いまの記録を確認しています"
            case .preparingDestination:
                return "iCloudからデータを受け取っています。数分かかることがあります。画面を開いたままお待ちください"
            case .destinationSaved, .destinationVerified:
                return "受け取った内容を照合しています"
            case .selectionCommitted, .sourceRetired:
                return "切り替えを完了しています"
            }
        case .disableCloudKeepingCopy:
            switch progress.phase {
            case .requested, .sourceSaved, .recoveryCopySaved:
                return "いまの記録を確認しています"
            case .preparingDestination:
                return "iCloudのデータをこのiPhoneへコピーしています"
            case .destinationSaved, .destinationVerified:
                return "コピーした内容を照合しています"
            case .selectionCommitted, .sourceRetired:
                return "切り替えを完了しています"
            }
        }
    }
}

/// The fixed Japanese copy for the launch screens the split dataset-lineage
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
    static let title = "iCloudとの同期を止めています"
    static let startDoorTitle = "このiPhoneのデータでiCloudを使い始める"
    /// review-1-1 / review-2-2. The missing thing is the transfer CONTROL
    /// record, not the account's records: `refreshCloudDatasetWithoutLineage`
    /// exists precisely because rows under a missing control record are real
    /// and mirrorable. This sentence therefore says what the action does to
    /// them, and the screen renders the enumerated counts beside it.
    static let startExplanation =
        "iCloud側に、このアプリが使っている管理情報が見つかりません。このiPhoneの記録をiCloudへ送信し、新しいiCloudのデータとして使い始めます。このiPhoneの記録は削除しません。iCloudに残っている記録は削除され、このiPhoneのデータで置き換えられます。"

    /// review-2-5. The stop reason itself promises nothing: it is also the
    /// error text an offline session shows when its retry meets this state.
    /// transfer-01 / device-01: it no longer blames 「別のビルド（開発用／配布
    /// 用）」, a cause that does not exist for an App Store user. Nor does it
    /// guess any other cause: the state is reached by an older-generation
    /// receipt, or by a receipt-less store the 1.0 / 1.0.1 adoption rule does
    /// not take (Docs/iCloudSyncTroubleshooting.md), and a user whose iCloud
    /// data was deleted usually holds neither. It states what was observed and
    /// what was not done; the doors below say what can be done.
    static let stopReason =
        "iCloudのデータとこのiPhoneの記録の対応を確認できないため、記録が混ざらないよう同期を止めています。このiPhoneの記録もiCloudのデータも削除していません。"
    static let startAndOfflineChoices =
        "このiPhoneのデータでiCloudを使い始めるか、オフラインのまま使うかを選べます。"

    /// The screen's message. `offersLineageStart` is the release bit, so the
    /// app never states a choice and then refuses it in the next paragraph;
    /// a build that does not publish the start door adds no closing sentence
    /// at all, and each door below explains itself.
    static func screenMessage(offersLineageStart: Bool) -> String {
        offersLineageStart ? stopReason + startAndOfflineChoices : stopReason
    }
    static let offlineDoorTitle = "オフラインのまま使う"
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
        let base = "iCloudへ送信せず、このiPhoneに保存されている記録でそのまま使います。変更はこのiPhoneに保存されますが、iCloudとの同期は止まったままです。どちらの記録も削除しません。"
        return base + (offersLineageStart
            ? "あとでこの画面から、このiPhoneのデータでiCloudを使い始めることもできます。"
            : "同期を再開する方法は、利用中の画面上部の「復旧手順」からいつでも確認できます。")
            + offlineChangesAreDiscardedByRefresh
    }
    static let offlineChangesAreDiscardedByRefresh =
        "あとで「\(StorageTransferRefreshCopy.confirmTitle)」を選ぶと、オフラインで記録した変更も削除されます。"
    /// Offered only when the offline route is actually eligible. When it is
    /// not, the screen says why instead of showing a control that does nothing.
    static let offlineUnavailable =
        "このiPhoneには、オフラインで開ける確認済みの記録がまだありません。どちらの記録も削除していません。"

    /// The banner message of an offline session opened FROM a storage-transfer
    /// stop screen. The generic 「接続回復後に同期を再開します」 is false there:
    /// a restored connection meets the same stop again, so the banner carries
    /// the 「復旧手順」 action instead of an automatic-resume promise.
    static let offlineSessionMessage =
        "iCloudとの同期は止まったままです。変更はこのiPhoneに保存されます。「復旧手順」から、同期を再開する方法をいつでも確認できます。"

    // MARK: 「iCloudから再取得」 on this screen

    /// The policy-free way back to sync on this screen. It is the SAME
    /// `refreshCloudDatasetWithoutLineage` Settings already ships for accounts
    /// without a ledger: it writes nothing to iCloud and deletes this
    /// device's side only after the read-only pre-flight, the empty-iCloud
    /// warning and its own unchecked acknowledgement in 「最後の確認」. The
    /// section is named after its button and the sheet's confirm, so one
    /// operation has one name on this screen.
    static let refreshDoorTitle = StorageTransferRefreshCopy.confirmTitle
    static let refreshExplanation =
        "iCloudにあるデータをこのiPhoneに取り込み直して、同期を再開します。このiPhoneのテーマ・記録・設定は削除され、iCloudのデータに置き換わります。2つのデータは結合しません。iCloudのデータは削除しません。"

    // MARK: 「最後の確認」 for the start-from-device action

    static let sheetTitle = "最後の確認"
    /// review-1-1 / review-2-2. The previous wording asserted 「現在のiCloudには、
    /// このアプリが使えるPomoGemのデータがありません」 — an unverified factual
    /// claim about the server, on the one screen where an irreversible
    /// deletion of that server's rows is authorized. `startCloudLineageFromDevice`
    /// opens an `.overwriteCloudFromDevice` journal whose `replacesCloud` is
    /// true, so `prepareDestination` purges the mirrored zone; the staged
    /// recovery copy is this device's payload and backs none of it up.
    static let sheetWarning =
        "iCloud側には、このアプリが使っている管理情報がありません。そのため、この操作は「置き換え」ではなく、このiPhoneのデータでiCloudを新しく使い始める操作になります。いまiCloudに残っている記録は削除し、このiPhoneのテーマ・記録・設定で置き換えます。削除したiCloudのデータを元に戻すことはできません。"
    static let sheetOtherBuilds =
        "同じApple Accountの他の端末や、別のビルド（開発用／配布用）のPomoGemがこのアカウントを使っている場合、それらの端末は次に開いたときにiCloudのデータを取得し直す確認を求められます。その端末だけにある未送信の記録は残りません。"
    static let sheetRelaunch = StorageTransferOverwriteCopy.relaunch
    static let sheetScreenTime = StorageTransferOverwriteCopy.screenTime
    /// It names the deletion, because the action performs one. The previous
    /// sentence mentioned only sending this iPhone's data and asking other
    /// devices to re-fetch.
    static let acknowledgement = "iCloudに残っている記録の削除と、他の端末への影響を確認しました"
    static let sheetConfirm = "iCloudを使い始める"

    static let requestAccepted =
        "このiPhoneのデータでiCloudを使い始める手続きを受け付けました。Appスイッチャーでポモジェムを終了し、もう一度開いてください。アプリ自体は削除しないでください。"

    // MARK: The explanation-only screens

    static let environmentMismatchTitle = "別のiCloud環境のデータです"
    /// No door of any kind: nothing this build can run is meaningful against a
    /// database it does not talk to. It says what to do OUTSIDE the app.
    static let environmentMismatchExplanation =
        "この端末の記録は、いまのアプリとは別のiCloud環境（開発用／配布用）で作られたものです。この画面では、どちらの記録も削除していません。記録を作ったときと同じビルドのPomoGemで開き直すか、サポートの手順をご確認ください。"

    static let localLedgerMissingTitle = "iCloudのデータを受け取った記録がありません"
    /// review-1-4. This screen is reached only from the SUCCESS branch of
    /// `presentDatasetRefresh`: the server read worked and reported no
    /// terminal committed generation. A read that throws produces
    /// `refreshScreenUnavailable` instead. The copy therefore states what was
    /// observed and never names a network cause that was not.
    static let localLedgerMissingExplanation =
        "この端末には、いまiCloudにあるデータを受け取った記録がありません。iCloud側にも、再取得の元になる管理情報は見つかりませんでした。そのため、この画面では再取得の選択肢を表示できません。この画面では、どちらの記録も削除していません。"

    // MARK: Settings, when the account has no transfer ledger (W6)

    /// Shown in the device → iCloud 「最後の確認」 when the pre-flight found
    /// records on the server but NO transfer control record. The sheet's first
    /// paragraph says the iCloud dataset is deleted and replaced; with no
    /// ledger that is not the whole truth, because this direction STARTS one.
    static let settingsStartsLineage =
        "iCloud側には、このアプリが使っている管理情報がありません。そのため、この操作は「置き換え」ではなく、このiPhoneのデータでiCloudを新しく使い始める操作になります。iCloudに残っている記録は、このiPhoneのデータで置き換えられます。"

    /// P1-4 (ROOT-CAUSE §6.1). The catch arm of `presentDatasetRefresh` used to
    /// put the CAUGHT error's own text on the generic blocked screen, which
    /// hid — from the user and from the operator — that the rescue UI could not
    /// be built at all. The failure now names itself.
    static let refreshScreenUnavailable =
        "iCloud側の情報を読み取れなかったため、復旧の選択肢を表示できません。通信を確認して、もう一度お試しください。どちらの記録も削除していません。"
}
