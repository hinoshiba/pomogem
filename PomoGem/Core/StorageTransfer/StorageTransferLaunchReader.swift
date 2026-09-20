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

    /// The device side of the comparison is reduced by the **same** function as
    /// the iCloud side (`StorageTransferCloudPreview.make`), over the same
    /// mirrored models, so the two rows a user compares are computed
    /// identically and a difference between them is a difference in the data.
    /// `otherDeviceIDs` is meaningless for a local snapshot and is ignored by
    /// the UI; only the counts and the newest dated row are read from it.
    static func captureDevicePreview(selection: PersistenceDeploymentSelection,
                                     localDeviceID: String = FocusDeviceIdentity.current())
        throws -> StorageTransferCloudPreview {
        try withDisposableReader(selection: selection) { container in
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let snapshot = try PomoGemStorageSnapshot.capture(from: context)
            return StorageTransferCloudPreview.make(snapshot: snapshot, localDeviceID: localDeviceID)
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
        "iCloudのデータでこの端末を置き換える手続きを受け付けました。アプリスイッチャーでPomoGemを終了し、もう一度開いてください。iCloudのデータは削除しません。"
}

/// The fixed Japanese copy for the device → iCloud overwrite. It lives beside
/// the runtime rather than inside a view so the launch host, Settings and the
/// review notes quote one text, and so a reviewer can diff the shipped strings
/// against the approved wording in one place.
enum StorageTransferOverwriteCopy {
    static let comparisonReading = "iCloudの内容を確認しています"
    /// It must name a control that is on THIS screen. `.datasetRefresh` carries
    /// no 「もう一度試す」 — that button exists only on `.blocked`/`.failed` — so
    /// pointing at it would leave a user on a flaky connection reading an
    /// instruction they cannot follow, with no in-app way to re-read iCloud
    /// and the destructive door permanently disabled behind a missing preview.
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

    static let exportTitle = "先にこの端末の記録を書き出す"
    static let exportNote = "書き出したファイルはPomoGemに読み込めません。記録の控えとして保存します。"
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
        "このiPhoneのデータでiCloudを置き換える手続きを受け付けました。アプリスイッチャーでPomoGemを終了し、もう一度開いてください。復旧用コピーの保存が終わるまで、iCloudの削除は始めません。"

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
    static func blockedExplanation(offersOverwrite: Bool) -> String {
        guard offersOverwrite else {
            return "iCloudの状態を確認できていません。通信を確認して「もう一度試す」を押すと、iCloudのデータを再取得できます。この画面では、どちらの記録も削除していません。"
        }
        return "iCloudの状態を確認できていません。通信を確認して「もう一度試す」を押すと、iCloudのデータを再取得するか、このiPhoneのデータでiCloudを置き換えるかを選べます。この画面では、どちらの記録も削除していません。"
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

    /// 「テーマ12・記録480・成果36（最終 2026年9月20日）」. Only the three models a
    /// user recognizes are named; the remaining mirrored models are counted by
    /// the runtime but would not help someone decide.
    /// W6. The iCloud row when the server holds records but no transfer
    /// control record. The count still comes from the read-only snapshot — it
    /// is the honest answer to 「what is over there」 — but the row does not
    /// imply a lineage that does not exist.
    static func cloudSideWithoutLineage(preview: StorageTransferCloudPreview?) -> String {
        guard let preview else { return side("iCloud", preview: nil) }
        let total = preview.recordCounts.values.reduce(0, +)
        return "iCloud側の管理情報なし（記録件数: \(total)）"
    }

    static func side(_ label: String, preview: StorageTransferCloudPreview?) -> String {
        guard let preview else { return "\(label): 確認できませんでした" }
        let counts = preview.recordCounts
        let body = "テーマ\(counts["Subject"] ?? 0)・記録\(counts["StudySession"] ?? 0)・成果\(counts["AchievementStone"] ?? 0)"
        guard let latest = preview.latestRecordAt else { return "\(label): \(body)（日付のある記録なし）" }
        return "\(label): \(body)（最終 \(comparisonFormatter.string(from: latest))）"
    }
}

/// The fixed Japanese copy for the launch screens the split dataset-lineage
/// taxonomy reaches (ROOT-CAUSE §6.2). Kept beside the other two copy holders
/// so every sentence a stop reason can produce is diffable in one place.
///
/// Two of the three screens are explanation-only. The third — 「iCloudの管理情報が
/// 見つかりません」 — is the state the reported iPhone is actually in, and it is
/// the only one that carries an action: starting a NEW iCloud lineage from this
/// device. That action is destructive to nothing on this device and to nothing
/// on the server (there is no lineage to destroy), but it does publish this
/// device's whole dataset, so it sits behind 「最後の確認」 and the same closed
/// `allowsDatasetOverwriteFromDevice` bit as the overwrite.
enum StorageTransferLineageCopy {
    // MARK: 「iCloudの管理情報が見つかりません」

    static let title = "iCloudの管理情報が見つかりません"
    static let startDoorTitle = "このiPhoneのデータでiCloudを使い始める"
    static let startExplanation =
        "iCloud側に、このアプリが使っている管理情報が見つかりません。このiPhoneの記録をiCloudへ送信し、新しいiCloudのデータとして使い始めます。このiPhoneの記録は削除しません。"
    static let offlineDoorTitle = "オフラインのまま使う"
    static let offlineExplanation =
        "iCloudへ送信せず、このiPhoneに保存されている記録でそのまま使います。あとでこの画面から、このiPhoneのデータでiCloudを使い始めることもできます。"
    /// Offered only when the offline route is actually eligible. When it is
    /// not, the screen says why instead of showing a control that does nothing.
    static let offlineUnavailable =
        "オフラインで利用するための確認済みデータが、この端末にまだありません。通信が使えるときに一度開いてください。どちらの記録も削除していません。"

    // MARK: 「最後の確認」 for the start-from-device action

    static let sheetTitle = "最後の確認"
    static let sheetWarning =
        "現在のiCloudには、このアプリが使えるPomoGemのデータがありません。このiPhoneのテーマ・記録・設定をiCloudへ送信し、新しいiCloudのデータとして使い始めます。"
    static let sheetOtherBuilds =
        "同じApple Accountの他の端末や、別のビルド（開発用／配布用）のPomoGemがこのアカウントを使っている場合、それらの端末は次に開いたときにiCloudのデータを取得し直す確認を求められます。その端末だけにある未送信の記録は残りません。"
    static let sheetRelaunch = StorageTransferOverwriteCopy.relaunch
    static let sheetScreenTime = StorageTransferOverwriteCopy.screenTime
    static let acknowledgement = "このiPhoneのデータをiCloudへ送ること、他の端末に取得し直しを求めることを確認しました"
    static let sheetConfirm = "iCloudを使い始める"

    static let requestAccepted =
        "このiPhoneのデータでiCloudを使い始める手続きを受け付けました。アプリスイッチャーでPomoGemを終了し、もう一度開いてください。アプリ自体は削除しないでください。"

    // MARK: The explanation-only screens

    static let environmentMismatchTitle = "別のiCloud環境のデータです"
    /// No door of any kind: nothing this build can run is meaningful against a
    /// database it does not talk to. It says what to do OUTSIDE the app.
    static let environmentMismatchExplanation =
        "この端末の記録は、いまのアプリとは別のiCloud環境（開発用／配布用）で作られたものです。この画面では、どちらの記録も削除していません。記録を作ったときと同じビルドのPomoGemで開き直すか、サポートの手順をご確認ください。"

    static let localLedgerMissingTitle = "iCloudのデータを受け取った記録がありません"
    /// Reached only when the server ALSO turns out to have no committed
    /// generation, so the 「iCloudから再取得」 screen cannot be built. Saying
    /// 「もう一度試す」 is honest here: the generic retry is on this screen.
    static let localLedgerMissingExplanation =
        "iCloud側の管理情報を読み取れなかったため、再取得の選択肢を表示できません。通信を確認して「もう一度試す」を押してください。この画面では、どちらの記録も削除していません。"

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
