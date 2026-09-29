import Foundation
import XCTest
@testable import PomoGem

/// English expectations for localization package l10n-09-storage-sync (table: Storage).
///
/// Only that package edits this file (Docs/Localization.md). Resolve English
/// explicitly with `LocalizationTestSupport.englishBundle()` and
/// `LocalizationTestSupport.english`, which skip until English is activated;
/// never change the process language, because the rest of the suite asserts
/// Japanese.
///
/// The Storage table holds the copy of irreversible actions: switching where
/// records are stored, replacing one side's data with the other's, and
/// deleting everything. Its English is checked for meaning, not only for
/// presence: every sentence that says data will be deleted, cannot be
/// restored, is not combined or has not been deleted must still say so.
@MainActor
final class StorageSyncLocalizationTests: XCTestCase {
    private let en = LocalizationTestSupport.english

    /// The English value of a Storage key, formatted like the app formats it.
    private func english(_ key: String, _ arguments: CVarArg..., table: String = "Storage") throws -> String {
        let bundle = try LocalizationTestSupport.englishBundle()
        let format = bundle.localizedString(forKey: key, value: "<missing \(key)>", table: table)
        return arguments.isEmpty ? format : String(format: format, locale: en, arguments: arguments)
    }

    /// Another package's English for a label this table quotes, or nil while
    /// that package has not landed on the branch yet.
    private func translated(_ key: String, table: String) throws -> String? {
        let value = try english(key, table: table)
        return value == key || value.hasPrefix("<missing") ? nil : value
    }

    // MARK: Japanese stays byte-identical where the code was restructured

    /// These texts used to be glued together in code. They are now whole
    /// sentences joined by `SentenceText`, and must read exactly as before.
    func testRestructuredCopyStaysJapanese() {
        let device = Self.preview(subjects: 12, sessions: 1_234, stones: 36, latest: nil)
        XCTAssertEqual(
            StorageTransferRefreshCopy.cloudSideEmpty(device: device),
            "iCloudには、このアプリの記録と成果が1件も見つかりませんでした。このまま実行すると、このiPhoneのテーマ12・記録1234・成果36を含む、テーマ・記録・設定はすべて削除され、元に戻すことはできません。中止して、先にこの端末の記録を書き出すか、他の端末の同期が終わるのをお待ちください。",
            "counts stay ungrouped digits, as before"
        )
        XCTAssertEqual(
            StorageTransferRefreshCopy.cloudSideEmpty(device: nil),
            "iCloudには、このアプリの記録と成果が1件も見つかりませんでした。このまま実行すると、このiPhoneのテーマ・記録・設定は削除され、元に戻すことはできません。中止して、先にこの端末の記録を書き出すか、他の端末の同期が終わるのをお待ちください。"
        )
        XCTAssertEqual(
            StorageTransferEnableCopy.cloudSideEmpty(device: device),
            "iCloudには、このアプリの記録と成果が1件も見つかりませんでした。このまま実行すると、このiPhoneのテーマ12・記録1234・成果36を含む、テーマ・記録・設定はすべて削除され、空の状態からiCloudの同期を始めます。元に戻すことはできません。"
        )
        XCTAssertEqual(
            StorageTransferEnableCopy.cloudSideEmpty(device: nil),
            "iCloudには、このアプリの記録と成果が1件も見つかりませんでした。このまま実行すると、このiPhoneのテーマ・記録・設定はすべて削除され、空の状態からiCloudの同期を始めます。元に戻すことはできません。"
        )
        XCTAssertEqual(
            StorageTransferLineageCopy.screenMessage(offersLineageStart: true),
            "iCloudのデータとこのiPhoneの記録の対応を確認できないため、記録が混ざらないよう同期を止めています。このiPhoneの記録もiCloudのデータも削除していません。このiPhoneのデータでiCloudを使い始めるか、オフラインのまま使うかを選べます。"
        )
        XCTAssertEqual(StorageTransferLineageCopy.screenMessage(offersLineageStart: false),
                       StorageTransferLineageCopy.stopReason)
        XCTAssertEqual(
            StorageTransferLineageCopy.offlineExplanation(offersLineageStart: false),
            "iCloudへ送信せず、このiPhoneに保存されている記録でそのまま使います。変更はこのiPhoneに保存されますが、iCloudとの同期は止まったままです。どちらの記録も削除しません。同期を再開する方法は、利用中の画面上部の「復旧手順」からいつでも確認できます。あとで「iCloudから再取得」を選ぶと、オフラインで記録した変更も削除されます。"
        )
        XCTAssertEqual(
            StorageTransferLineageCopy.offlineExplanation(offersLineageStart: true),
            "iCloudへ送信せず、このiPhoneに保存されている記録でそのまま使います。変更はこのiPhoneに保存されますが、iCloudとの同期は止まったままです。どちらの記録も削除しません。あとでこの画面から、このiPhoneのデータでiCloudを使い始めることもできます。あとで「iCloudから再取得」を選ぶと、オフラインで記録した変更も削除されます。"
        )
        XCTAssertEqual(
            StorageTransferLineageCopy.requestAccepted,
            "このiPhoneのデータでiCloudを使い始める手続きを受け付けました。Appスイッチャーでポモジェムを終了し、もう一度開いてください。アプリ自体は削除しないでください。"
        )
        XCTAssertEqual(
            StorageTransferRuntimeError.relaunchRequired.localizedDescription,
            "データを安全に切り替えるため、Appスイッチャーでポモジェムを一度終了し、もう一度開いてください。アプリ自体は削除しないでください。"
        )
        XCTAssertEqual(
            StorageTransferRuntimeError.cloudCopyStillArriving.localizedDescription,
            "iCloudからの受信に時間がかかっています。記録は保護されています。通信の安定した場所で、Appスイッチャーでポモジェムを終了してもう一度開くと、続きから確認します。アプリ自体は削除しないでください。"
        )
        XCTAssertEqual(StorageTransferLineageCopy.sheetRelaunch, StorageTransferRefreshCopy.relaunch)
        XCTAssertEqual(
            StorageTransferProgressCopy.relaunchInstructions(after: ""),
            "Appスイッチャーを開き（画面の下端から上にスワイプして指を止めるか、ホームボタンを2回押します）、ポモジェムを上にスワイプして閉じてから、ホーム画面のアイコンで開き直してください。この画面で待っていても先へは進みません。アプリ自体は削除しないでください。"
        )
        XCTAssertEqual(StorageTransferLineageCopy.sheetTitle, "最後の確認")
        XCTAssertEqual(StorageTransferSettingsSection.cloudEntryTitle, "iCloudと保存先の変更")
        XCTAssertEqual(StorageTransferSettingsSection.enableCloudTitle, "iCloudを有効にする")
    }

    /// The comparison row keeps its Japanese, including ungrouped counts, and
    /// its date is now `DateText.longDate` in place of a pinned ja_JP formatter.
    func testComparisonRowStaysJapanese() {
        let latest = Self.date(2026, 9, 20)
        XCTAssertEqual(
            StorageTransferOverwriteCopy.side(StorageTransferOverwriteCopy.thisIPhoneSide,
                                              preview: Self.preview(subjects: 12, sessions: 12_480, stones: 36, latest: latest)),
            "このiPhone: テーマ12・記録12480・成果36（最終 2026年9月20日）"
        )
        XCTAssertEqual(StorageTransferOverwriteCopy.countsOnly("iCloud", preview: nil), "iCloud: 確認できませんでした")
        XCTAssertEqual(DateText.longDate(latest, locale: LocalizationTestSupport.japanese), "2026年9月20日")
        XCTAssertEqual(DateText.longDate(latest, locale: en), "September 20, 2026")
    }

    /// The Home and Overview helpers in SyncMaintenance keep their Japanese.
    func testSyncMaintenanceHelpersStayJapanese() {
        let pending = AggregateProjectionPresentationContext.initial(for: .cloudKit)
        let local = AggregateProjectionPresentationContext.initial(for: .localOnly)
        XCTAssertEqual(AggregateProjectionPresentationPolicy.homeCountSummary(
            count: 12_345, milestoneSuffix: " ・ 記念石 3", hasLocalLowerBound: false, context: pending),
            "この端末で確認済み 12,345粒 ・ 記念石 3")
        XCTAssertEqual(AggregateProjectionPresentationPolicy.homeCountSummary(
            count: 12_345, milestoneSuffix: "", hasLocalLowerBound: true, context: local), "12,345+粒")
        XCTAssertEqual(AggregateProjectionPresentationPolicy.homeCountSummary(
            count: 3, milestoneSuffix: " ・ 記念石 1", hasLocalLowerBound: false, context: local), "3粒 ・ 記念石 1")
        XCTAssertEqual(AggregateProjectionPresentationPolicy.homeCountSummary(
            count: -4, milestoneSuffix: "", hasLocalLowerBound: false, context: local), "0粒")
        XCTAssertEqual(AggregateProjectionPresentationPolicy.homeMassUnit(
            verifiedUnit: "g", hasLocalLowerBound: true, context: local), "g以上")
        XCTAssertEqual(AggregateProjectionPresentationPolicy.overviewLifetimeValue(
            verifiedValue: "2.5kg", isLocalLowerBound: true, context: local), "2.5kg以上")
        XCTAssertEqual(AggregateProjectionPresentationPolicy.overviewLifetimeValue(
            verifiedValue: "2.5kg", isLocalLowerBound: false, context: local), "2.5kg")
        XCTAssertEqual(AggregateProjectionPresentationPolicy.cloudPendingNotice,
                       "iCloudを確認中です。この端末で確認できた記録だけを表示しています。")
    }

    // MARK: Irreversible actions keep their full meaning

    /// "Deleted", "can't be restored", "not combined", "will be lost" and "not
    /// deleted" are the content of these screens, not tone.
    func testIrreversibleCopyNeverSoftens() throws {
        let expectations: [(key: String, phrases: [String])] = [
            ("この端末のテーマ・記録・設定を削除し、現在のiCloudのデータに置き換えます。未送信の端末データは失われ、iCloudのデータとは結合されません。iCloudのデータは残ります。",
             ["deletes the themes, records and settings on this device", "replaces them", "will be lost",
              "won't be combined", "iCloud data is kept"]),
            ("iCloudにある現在のPomoGemのテーマ・記録・設定を削除し、このiPhoneのデータで置き換えます。2つのデータは結合しません。削除したiCloudのデータを元に戻すことはできません。同じApple Accountの他の端末は、次に開いたときにこの画面と同じ確認を求められ、その端末だけにある未送信のデータは残りません。",
             ["deletes the PomoGem themes, records and settings now in iCloud", "not combined", "can't be restored",
              "will not be kept"]),
            ("現在iCloudにあるPomoGemのテーマ・記録・設定をすべて削除し、この端末のデータに置き換えます。削除するiCloudのデータを元に戻すことはできません。",
             ["deletes all PomoGem themes, records and settings now in iCloud", "can't be restored"]),
            ("置き換えるデータの復旧用コピーをiCloudに保存し、受領を確認してから削除を始めます。復旧用コピーには、このiPhoneだけの過去の記録も含まれます。処理完了後に復旧用コピーを削除します。通信が途切れた場合は、削除の再試行までiCloudに残ることがあります。",
             ["recovery copy", "deletion starts only after", "is deleted when the process finishes",
              "may stay in iCloud"]),
            ("iCloudの削除を始めたあとは取り消せません。中断しても、次に開いたときに続きから再開します。",
             ["can't be canceled"]),
            ("iCloud側には、このアプリが使っている管理情報がありません。そのため、この操作は「置き換え」ではなく、このiPhoneのデータでiCloudを新しく使い始める操作になります。いまiCloudに残っている記録は削除し、このiPhoneのテーマ・記録・設定で置き換えます。削除したiCloudのデータを元に戻すことはできません。",
             ["will be deleted and replaced", "can't be restored"]),
            ("iCloud側に、このアプリが使っている管理情報が見つかりません。このiPhoneの記録をiCloudへ送信し、新しいiCloudのデータとして使い始めます。このiPhoneの記録は削除しません。iCloudに残っている記録は削除され、このiPhoneのデータで置き換えられます。",
             ["will not be deleted", "will be deleted and replaced"]),
            ("iCloudにあるデータをこのiPhoneに取り込み直して、同期を再開します。このiPhoneのテーマ・記録・設定は削除され、iCloudのデータに置き換わります。2つのデータは結合しません。iCloudのデータは削除しません。",
             ["will be deleted and replaced", "not combined", "will not be deleted"]),
            ("現在このiPhoneにあるテーマ・記録・設定を削除し、iCloudのデータに置き換えます。端末だけの記録は失われます。",
             ["deletes the themes, records and settings now on this iPhone", "will be lost"]),
            ("このiPhoneだけにあるPomoGemのデータを削除します。iCloudのデータは残ります。削除後に元の端末データへ戻すことはできません。",
             ["deletes the PomoGem data that exists only on this iPhone", "is kept", "can't go back"]),
            ("iCloudにあるPomoGemのデータを削除します。このiPhoneのデータを残して同期を有効にします。削除するiCloudデータを元に戻すことはできません。",
             ["deletes the PomoGem data in iCloud", "can't be restored"]),
            ("解除後の変更は他の端末へ同期されません。このiPhoneのアプリを削除すると、解除後に端末で追加・変更したデータは失われます。",
             ["won't sync", "will be lost"]),
            ("このまま実行すると、このiPhoneのテーマ・記録・設定は削除され、元に戻すことはできません。",
             ["will be deleted", "can't be restored"]),
            ("iCloudのデータとこのiPhoneの記録の対応を確認できないため、記録が混ざらないよう同期を止めています。このiPhoneの記録もiCloudのデータも削除していません。",
             ["sync has been stopped", "have not been deleted"]),
            ("iCloudのデータとこの端末の記録の対応を確認できませんでした。古いデータを送信しないよう同期を停止しています。どちらの記録も削除していません。",
             ["No records have been deleted on this device or in iCloud"]),
            ("iCloudで未完了のデータ切り替えが進んでいるため、この操作はまだ実行できません。完了してから、もう一度お試しください。どちらの記録も削除していません。",
             ["can't run yet", "No records have been deleted"]),
            ("複数端末での同時操作から記録を保護するため、iCloudの置き換えと、その復旧の再開は一時的に利用できません。端末のデータと復旧用コピーは削除せず保持します。",
             ["temporarily unavailable", "kept, not deleted"]),
            ("端末データの削除を確認しました", ["will be deleted"]),
            ("iCloudのデータの削除と、他の端末への影響を確認しました", ["will be deleted", "other devices"]),
            ("iCloudに残っている記録の削除と、他の端末への影響を確認しました", ["will be deleted", "other devices"]),
            ("削除される保存先とデータを確認しました", ["will be deleted"]),
            ("iCloudのデータでこの端末を置き換える手続きを受け付けました。Appスイッチャーでポモジェムを終了し、もう一度開いてください。iCloudのデータは削除しません。",
             ["PomoGem", "App Switcher", "will not be deleted"]),
            ("このiPhoneのデータでiCloudを置き換える手続きを受け付けました。Appスイッチャーでポモジェムを終了し、もう一度開いてください。復旧用コピーの保存が終わるまで、iCloudの削除は始めません。",
             ["PomoGem", "App Switcher", "Nothing in iCloud is deleted until the recovery copy has been saved"])
        ]
        for (key, phrases) in expectations {
            let value = try english(key)
            XCTAssertFalse(value.hasPrefix("<missing"), key)
            for phrase in phrases {
                XCTAssertTrue(value.contains(phrase), "\(key) → \(value) should say \(phrase)")
            }
            XCTAssertFalse(value.localizedCaseInsensitiveContains("merge"), "never “merge”: \(value)")
        }
    }

    /// The two directions' acknowledgements name the side each destroys and
    /// stay distinct in English too (PLAN §3 S9).
    func testAcknowledgementsNameTheSideTheyDelete() throws {
        let refresh = try english("端末データの削除を確認しました")
        let overwrite = try english("iCloudのデータの削除と、他の端末への影響を確認しました")
        XCTAssertEqual(refresh, "I understand this device's data will be deleted")
        XCTAssertEqual(overwrite, "I understand the iCloud data will be deleted and how this affects other devices")
        XCTAssertNotEqual(refresh, overwrite)
    }

    // MARK: Labels and the sentences that quote them

    func testButtonsAndTitlesInEnglish() throws {
        XCTAssertEqual(try english("iCloudと保存先"), "iCloud & Storage")
        XCTAssertEqual(try english("iCloudと保存先の変更"), "Change iCloud & Storage")
        XCTAssertEqual(try english("iCloudを有効にする"), "Turn On iCloud")
        XCTAssertEqual(try english("現在の保存先"), "Current Storage")
        XCTAssertEqual(try english("このiPhoneのみ"), "This iPhone Only")
        XCTAssertEqual(try english("このiPhoneへ引き継ぐ"), "Move to This iPhone")
        XCTAssertEqual(try english("iCloudから再取得"), "Re-download from iCloud")
        XCTAssertEqual(try english("iCloudのデータを使う"), "Use iCloud's Data")
        XCTAssertEqual(try english("このiPhoneのデータで置き換える"), "Replace with This iPhone's Data")
        XCTAssertEqual(try english("iCloudを置き換える"), "Replace iCloud")
        XCTAssertEqual(try english("iCloudを使い始める"), "Start Using iCloud")
        XCTAssertEqual(try english("最後の確認"), "Final Confirmation")
        XCTAssertEqual(try english("先にこの端末の記録を書き出す"), "Export This Device's Records First")
        XCTAssertEqual(try english("コピーしてiCloudを解除"), "Copy and Turn Off iCloud")
        XCTAssertEqual(try english("置き換えてiCloudを有効にする"), "Replace and Turn On iCloud")
        XCTAssertEqual(try english("戻る"), "Back")
        XCTAssertEqual(try english("キャンセル"), "Cancel")
    }

    /// A sentence that tells the user to tap a button quotes that button's
    /// English title, including buttons whose titles live in other tables.
    func testSentencesQuoteTheButtonsEnglishTitle() throws {
        let refresh = try english("iCloudから再取得")
        let settingsFailure = try english(
            "iCloudの内容を確認できませんでした。通信を確認して、もう一度「%@」を押してください。どちらの記録も削除していません。",
            refresh)
        XCTAssertEqual(settingsFailure,
                       "Couldn't check your iCloud data. Check your connection, then tap “Re-download from iCloud” again. No records have been deleted on this device or in iCloud.")
        XCTAssertTrue(try english("iCloudの内容を確認できませんでした。通信を確認して「%@」を押してください。どちらの記録も削除していません。",
                                  try english("iCloudの内容をもう一度確認")).contains("“Check iCloud Data Again”"))
        XCTAssertTrue(try english("iCloudの内容を確認できませんでした。通信とApple Accountを確認して、もう一度「%@」を押してください。どちらの記録も削除していません。",
                                  try english("iCloudのデータを使う")).contains("“Use iCloud's Data”"))
        XCTAssertEqual(try english("あとで「%@」を選ぶと、オフラインで記録した変更も削除されます。", refresh),
                       "If you choose “Re-download from iCloud” later, the changes you recorded offline will also be deleted.")

        // Labels owned by other tables. Checked once those tables carry English.
        let quotes: [(key: String, table: String, sentences: [String])] = [
            ("もう一度試す", "Launch", [
                "iCloudを読み取れれば、「もう一度試す」のあとに、iCloudのデータを再取得する選択肢が表示されます。",
                "iCloudを読み取れれば、「もう一度試す」のあとに、iCloudのデータを再取得するか、このiPhoneのデータでiCloudを置き換えるかを選べます。"
            ]),
            ("復旧手順", "Launch", [
                "同期を再開する方法は、利用中の画面上部の「復旧手順」からいつでも確認できます。",
                "iCloudとの同期は止まったままです。変更はこのiPhoneに保存されます。「復旧手順」から、同期を再開する方法をいつでも確認できます。"
            ]),
            ("スクリーンタイム", "ScreenTime", [
                "切り替えると、スクリーンタイムの自動記録はオフになり、選んだアプリ、まだ取り込んでいない利用記録、黒い石は引き継ぎません。切り替えたあとで、設定の「スクリーンタイム」から選び直してください。保存済みの勉強時間と粒は引き継ぎます。"
            ])
        ]
        for quote in quotes {
            guard let title = try translated(quote.key, table: quote.table) else { continue }
            for sentence in quote.sentences {
                let value = try english(sentence)
                XCTAssertTrue(value.contains("“\(title)”"), "\(value) should quote “\(title)”")
            }
        }
        // Settings quotes this table's 「このiPhoneへ引き継ぐ」 in its own sentence.
        if let settings = try translated(
            "設定の「%@」で「このiPhoneへ引き継ぐ」を選ぶと、保存先がこのiPhoneだけになります。そのあと「表示中の記録をリセット」で0から始められます。iCloudの記録は削除されずに残り、以後は同期しません。",
            table: "Settings"
        ) {
            XCTAssertTrue(settings.contains("“\(try english("このiPhoneへ引き継ぐ"))"), settings)
        }
    }

    // MARK: Relaunch screens

    /// The caption under a relaunch message adds "Don't delete the app itself."
    /// only when the message does not already say it. The messages append the
    /// same catalog entry, so the check works in English as in Japanese.
    func testTheRelaunchWarningAppearsOnceInEnglish() throws {
        let keep = try english("アプリ自体は削除しないでください。")
        XCTAssertEqual(keep, "Don't delete the app itself.")
        let instructions = try english("Appスイッチャーを開き（画面の下端から上にスワイプして指を止めるか、ホームボタンを2回押します）、ポモジェムを上にスワイプして閉じてから、ホーム画面のアイコンで開き直してください。この画面で待っていても先へは進みません。")
        for phrase in ["App Switcher", "PomoGem", "Home Screen icon"] {
            XCTAssertTrue(instructions.contains(phrase), phrase)
        }
        XCTAssertFalse(instructions.contains(keep))
        let messages = try [
            "データを安全に切り替えるため、Appスイッチャーでポモジェムを一度終了し、もう一度開いてください。",
            "iCloudからの受信に時間がかかっています。記録は保護されています。通信の安定した場所で、Appスイッチャーでポモジェムを終了してもう一度開くと、続きから確認します。",
            "このiPhoneのデータでiCloudを使い始める手続きを受け付けました。Appスイッチャーでポモジェムを終了し、もう一度開いてください。"
        ].map { try SentenceText.join([english($0), keep], locale: en) }
        for message in messages {
            XCTAssertTrue(message.hasSuffix(". " + keep), message)
            XCTAssertTrue(message.contains("PomoGem") && message.contains("App Switcher"), message)
            XCTAssertFalse(message.contains("Try Again"), "the relaunch screen has no retry: \(message)")
        }
        XCTAssertEqual(
            SentenceText.join([try english("処理の途中で、アプリの終了と再起動をお願いします。"), keep], locale: en),
            "Partway through, you'll be asked to quit and reopen the app. Don't delete the app itself."
        )
    }

    // MARK: Counted text

    func testOtherDeviceEvidenceIsPluralized() throws {
        let bundle = try LocalizationTestSupport.englishBundle()
        func evidence(_ count: Int) -> String {
            String(
                localized: "iCloudの記録には、このiPhone以外の端末（\(count)台）が書き込んだ記録があります。置き換えると、それらの端末は次に開いたときに「iCloudのデータが置き換わりました」の画面になり、その端末だけにある未送信の記録は失われます。置き換える前に、その端末でPomoGemを開いて同期を終わらせておくと、失われる記録を減らせます。",
                table: "Storage", bundle: bundle, locale: en
            )
        }
        XCTAssertTrue(evidence(1).hasPrefix("Your iCloud records include records written by 1 device other than this iPhone."))
        XCTAssertTrue(evidence(1).contains("that device will show"))
        XCTAssertTrue(evidence(1).contains("will be lost"))
        XCTAssertTrue(evidence(2).hasPrefix("Your iCloud records include records written by 2 devices other than this iPhone."))
        XCTAssertTrue(evidence(2).contains("those devices will show"))
        XCTAssertTrue(evidence(2).contains("will be lost"))
        // The screen those devices will show is titled in the Launch table.
        if let title = try translated("iCloudのデータが置き換わりました", table: "Launch") {
            XCTAssertTrue(evidence(2).contains("“\(title)”"), evidence(2))
        }
        let none = try english("iCloudの記録には、このiPhone以外の端末は見つかりませんでした。ただし、これは他の端末が存在しない証明ではありません。まだ一度も記録を送っていない端末は分かりません。同じApple Accountの他の端末でPomoGemを開いている場合は、先に終了してください。")
        XCTAssertTrue(none.contains("doesn't prove that no other device exists"), none)
    }

    func testGemCountsArePluralized() throws {
        let bundle = try LocalizationTestSupport.englishBundle()
        func confirmed(_ count: Int) -> String {
            String(localized: "この端末で確認済み \(count)粒", table: "Storage", bundle: bundle, locale: en)
        }
        func atLeast(_ count: Int) -> String {
            String(localized: "\(count)+粒", table: "Storage", bundle: bundle, locale: en)
        }
        XCTAssertEqual(confirmed(1), "1 gem confirmed on this device")
        XCTAssertEqual(confirmed(12_345), "12,345 gems confirmed on this device")
        XCTAssertEqual(atLeast(1), "1+ gems")
        XCTAssertEqual(atLeast(40), "40+ gems")
        XCTAssertEqual(try english("%@以上", "12 kg"), "12 kg or more")
        XCTAssertEqual(try english("iCloudを確認中"), "Checking iCloud")
        XCTAssertEqual(try english("このiPhoneの集計を確認中"), "Checking this iPhone's totals")
    }

    /// The comparison a user reads before a deletion: counts as labeled
    /// digits, grouped the English way, and a date that always carries its year.
    func testComparisonRowInEnglish() throws {
        let preview = Self.preview(subjects: 12, sessions: 12_480, stones: 36, latest: nil)
        let (themes, records, achievements) = StorageTransferOverwriteCopy.countArguments(preview, locale: en)
        XCTAssertEqual([themes, records, achievements], ["12", "12,480", "36"], "English groups the digits")
        let japanese = StorageTransferOverwriteCopy.countArguments(preview, locale: LocalizationTestSupport.japanese)
        XCTAssertEqual([japanese.0, japanese.1, japanese.2], ["12", "12480", "36"],
                       "Japanese keeps 「記録12480」, as before")

        let counts = try english("テーマ%@・記録%@・成果%@", themes, records, achievements)
        XCTAssertEqual(counts, "Themes 12 · Records 12,480 · Achievements 36")
        let date = DateText.longDate(Self.date(2025, 9, 18), locale: en)
        XCTAssertEqual(try english("%@: %@（最終 %@）", try english("このiPhone"), counts, date),
                       "This iPhone: Themes 12 · Records 12,480 · Achievements 36 (latest record: September 18, 2025)")
        XCTAssertEqual(try english("%@: %@（日付のある記録なし）", "iCloud", counts),
                       "iCloud: Themes 12 · Records 12,480 · Achievements 36 (no dated records)")
        XCTAssertEqual(try english("%@: 確認できませんでした", "iCloud"), "iCloud: couldn't be checked")
        XCTAssertEqual(try english("%@: %@", "iCloud", counts), "iCloud: Themes 12 · Records 12,480 · Achievements 36")

        let empty = SentenceText.join([
            try english("iCloudには、このアプリの記録と成果が1件も見つかりませんでした。"),
            try english("このまま実行すると、このiPhoneのテーマ%@・記録%@・成果%@を含む、テーマ・記録・設定はすべて削除され、元に戻すことはできません。",
                        themes, records, achievements),
            try english("中止して、先にこの端末の記録を書き出すか、他の端末の同期が終わるのをお待ちください。")
        ], locale: en)
        XCTAssertEqual(empty, "No records or achievements from this app were found in iCloud. If you continue, all themes, records and settings on this iPhone (themes: 12, records: 12,480, achievements: 36) will be deleted and can't be restored. Stop here and export this device's records first, or wait for your other devices to finish syncing.")
    }

    // MARK: Data deletion

    func testDeletionProgressAndFailureInEnglish() throws {
        XCTAssertEqual(
            try ["iCloudに削除要求を保護しています", "タイマーと保存処理を停止しています", "この端末の設定と一時ファイルを消去しています",
                 "この端末の記録を消去しています", "iCloudの記録を消去しています", "iCloudで削除完了を確認しています",
                 "この端末に削除世代を記録しています", "削除結果を検証しています"].map { try english($0) },
            ["Securing the deletion request in iCloud", "Stopping the timer and saving",
             "Erasing this device's settings and temporary files", "Erasing the records on this device",
             "Erasing your records in iCloud", "Confirming with iCloud that the deletion is complete",
             "Recording the deletion marker on this device", "Verifying the deletion"]
        )
        XCTAssertEqual(try english("データ削除を完了できませんでした。\n%@", try english("再試行すると、安全な位置から続けます。")),
                       "Couldn't finish deleting your data.\nTry again to continue from a safe point.")
        XCTAssertEqual(try english("データ削除の再開情報が不正です: %@", try english("SwiftDataに%@件のレコードが残っています", "3")),
                       "The information for resuming the data deletion is invalid: Some records are still in SwiftData (3)")
    }

    // MARK: The whole table

    /// Every Storage key has an English value in state `translated` that holds
    /// no Japanese. l10n.py checks the same in CI; this keeps the failure
    /// inside the unit suite too.
    func testEveryStorageKeyHasEnglish() throws {
        _ = try LocalizationTestSupport.englishBundle()
        let catalog = try LocalizationCatalogFile(table: "Storage", relativePath: "PomoGem/Localization/Storage.xcstrings")
        XCTAssertFalse(catalog.strings.isEmpty)
        for (key, entry) in catalog.strings {
            let english = LocalizationCatalogFile.localizations(of: entry)["en"]
            XCTAssertNotNil(english, "\(key) has no English")
            for unit in english.map({ LocalizationCatalogFile.units(of: $0) }) ?? [] {
                XCTAssertEqual(unit.state, "translated", "\(key) \(unit.label)")
                XCTAssertFalse(LocalizationTestSupport.containsJapanese(unit.value), "\(key) \(unit.label): \(unit.value)")
                XCTAssertFalse(unit.value.localizedCaseInsensitiveContains("merge"), "\(key): never “merge”")
            }
        }
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

    /// Noon in the current time zone, as the app's own comparison renders it.
    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
            ?? Date(timeIntervalSinceReferenceDate: 0)
    }
}
