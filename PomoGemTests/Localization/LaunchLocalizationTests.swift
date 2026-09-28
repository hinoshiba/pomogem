import Foundation
import XCTest
@testable import PomoGem

/// English expectations for localization package l10n-08-launch (table: Launch).
///
/// Only that package edits this file (Docs/Localization.md). Resolve English
/// explicitly with `LocalizationTestSupport.englishBundle()` and
/// `LocalizationTestSupport.english`, which skip until English is activated;
/// never change the process language, because the rest of the suite asserts
/// Japanese.
///
/// The Launch table holds the fail-closed iCloud and storage copy. Its English
/// is checked for meaning, not only for presence: every sentence that says
/// something cannot happen, will be replaced, or is not deleted must still say
/// so, as plainly as the Japanese.
final class LaunchLocalizationTests: XCTestCase {
    private let en = LocalizationTestSupport.english
    private let ja = LocalizationTestSupport.japanese

    /// The English value of a Launch key, formatted like the app formats it.
    private func english(_ key: String, _ arguments: CVarArg...) throws -> String {
        let bundle = try LocalizationTestSupport.englishBundle()
        let format = bundle.localizedString(forKey: key, value: "<missing \(key)>", table: "Launch")
        return arguments.isEmpty ? format : String(format: format, locale: en, arguments: arguments)
    }

    // MARK: Japanese stays byte-identical where the code was restructured

    /// These three messages used to be concatenated in code. They are now one
    /// catalog entry per statement joined as sentences, which must reproduce
    /// the old Japanese exactly.
    func testRestructuredMessagesStayJapanese() {
        let interruption = "起動を続けられませんでした。iPhoneの画面にiOSの確認（Apple Accountのサインインなど）が出ている場合は、先にそれを完了するか閉じてから「もう一度試す」を押してください。"
        XCTAssertEqual(
            LaunchActivationWatchdogPolicy.blockedMessage(progress: .nothingCommitted),
            interruption + "記録や保存先の設定は変更していません。"
        )
        XCTAssertEqual(
            LaunchActivationWatchdogPolicy.blockedMessage(progress: .storageWorkCommitted),
            interruption + "記録は削除していません。ただしこの起動では保存先の準備が途中まで進んでいるため、アプリを終了して開き直すほうが確実です。"
        )

        let failure = CloudAccountVerificationFailure(
            kind: .serviceUnavailable, stage: .privateDatabase, cloudKitCode: 7, retryAfter: 1_200
        )
        XCTAssertEqual(
            failure.errorDescription,
            "iCloudのサービスが一時的に混み合っているか、利用できません。しばらく待って再試行してください。\n確認箇所: iCloudへの接続・CloudKit 7\n再試行まで約1200秒お待ちください。",
            "codes and seconds stay ungrouped, as before"
        )
        XCTAssertEqual(
            CloudAccountVerificationFailure(kind: .timedOut, stage: .verification, retryAfter: 7_200).errorDescription,
            "iCloudの確認に時間がかかっています。通信状態を確認して再試行してください。\n確認箇所: 全体確認\niCloudが待機を指定しています。時間をおいて再試行してください。"
        )
        XCTAssertEqual(
            [CloudAccountVerificationStage.verification, .accountStatus, .identityBeforeProbe,
             .privateDatabase, .identityAfterProbe].map(\.title),
            ["全体確認", "Apple Accountの状態", "Apple Accountの識別", "iCloudへの接続", "Apple Accountの再確認"]
        )
    }

    // MARK: First-run storage choice

    /// The two options carry the labels the review notes and the real-device
    /// tests quote, and neither is framed as the default.
    func testStorageChoiceInEnglish() throws {
        XCTAssertEqual(try english("記録の保存先を選んでください"), "Choose Where to Save Your Records")
        XCTAssertEqual(try english("iCloudに保存して同期"), "Save to iCloud and Sync")
        XCTAssertEqual(try english("このiPhoneだけに保存"), "Save on This iPhone Only")
        XCTAssertEqual(try english("このiPhoneだけで始める"), "Start on This iPhone Only")
        XCTAssertEqual(try english("iCloudに保存して同期しますか？"), "Save to iCloud and Sync?")
        XCTAssertEqual(try english("このiPhoneだけに保存しますか？"), "Save on This iPhone Only?")
        XCTAssertEqual(try english("どちらを選んでも、タイマーと瓶は同じように使えます。"),
                       "Either way, the timer and your jar work the same.")
        XCTAssertEqual(try english("集中した時間が、粒になって瓶にたまっていきます。"),
                       "Your focused time turns into gems that fill your jar.")
    }

    /// The local-only confirmation is the step that commits it: the loss on
    /// deletion, the replacement on a later switch, and the missing upload
    /// must all survive translation.
    func testLocalOnlyConfirmationStatesEveryConsequence() throws {
        let message = try english("記録はこのiPhoneだけに保存し、iCloudへは送信しません。アプリを削除すると、記録は失われます。あとでiCloud同期に切り替えると、このiPhoneの記録はiCloudの記録に置き換わります。このiPhoneの記録をiCloudへ移すことは、現在できません。")
        XCTAssertEqual(message, "Your records save on this iPhone only and are never sent to iCloud. If you delete the app, your records will be lost. If you switch to iCloud sync later, this iPhone's records will be replaced with your iCloud records. This iPhone's records cannot be moved to iCloud at this time.")
        for phrase in ["never sent to iCloud", "will be lost", "will be replaced", "cannot be moved"] {
            XCTAssertTrue(message.contains(phrase), phrase)
        }
        let cloud = try english("テーマ名、成果メモ、集中記録、設定、進行中タイマーをApple AccountのプライベートiCloudへ送信します。オンラインでApple Accountを確認した後に保存方式を確定します。このiPhoneに保存済みの記録があれば、オフラインでも使えます。初回の取得や同期の再開には通信が必要です。後で同期を止めるときは、iCloudの記録をこのiPhoneへコピーし、iCloudの記録も残します。")
        for phrase in ["Theme names", "achievement notes", "focus sessions", "private iCloud", "need a connection",
                       "also kept in iCloud"] {
            XCTAssertTrue(cloud.contains(phrase), phrase)
        }
    }

    // MARK: Fail-closed iCloud and offline copy

    func testOfflineBannerAndStatusInEnglish() throws {
        XCTAssertEqual(try english("このiPhoneに保存・iCloud同期は待機中"), "Saving to this iPhone · iCloud sync waiting")
        XCTAssertEqual(try english("このiPhoneに保存・iCloud同期は停止中"), "Saving to this iPhone · iCloud sync stopped")
        XCTAssertEqual(try english("%@。詳細を表示", "Saving to this iPhone · iCloud sync waiting"),
                       "Saving to this iPhone · iCloud sync waiting. Show details")
        XCTAssertEqual(try english("同期を再開"), "Resume Sync")
        XCTAssertEqual(try english("復旧手順"), "Recovery Steps")
        // The sentences that name a button quote its English title.
        XCTAssertTrue(try english("通信が戻ったら「同期を再開」で接続を確認できます。").contains("“Resume Sync”"))
        XCTAssertTrue(try english("保存済みのテーマと記録を使い、タイマーや記録の追加を続けられます。この間の変更は端末に保存され、iCloudへは送信されません。通信が戻っても同期は自動では再開しません。再開する方法は、画面上部の「復旧手順」から確認できます。")
            .contains("“Recovery Steps”"))
        let tryAgain = try english("もう一度試す")
        XCTAssertEqual(tryAgain, "Try Again")
        XCTAssertTrue(try english("Apple Accountの状態が変わったため、どのApple Accountでサインインしているかを確認するまで、この端末に保存したデータは開きません。通信が使える場所で「もう一度試す」をタップしてください。記録は消えていません。")
            .contains("“\(tryAgain)”"))
    }

    /// "Cannot", "not deleted" and "stopped" are the content of these screens.
    func testSafetyCopyNeverSoftens() throws {
        let expectations: [(key: String, phrases: [String])] = [
            ("記録や保存先の設定は変更していません。", ["have not been changed"]),
            ("記録は削除していません。ただしこの起動では保存先の準備が途中まで進んでいるため、アプリを終了して開き直すほうが確実です。",
             ["have not been deleted"]),
            ("以前の保存領域がまだ閉じていません。しばらく待って再試行するか、アプリを終了して再起動してください。記録は削除されません。",
             ["will not be deleted"]),
            ("記録の履歴が異なるため、自動で結合・送信できません。この画面を閉じて端末への記録を続けるか、設定の「データを書き出す」で記録を保存してください。同期の復旧についてはサポートへご相談ください。この操作で端末やiCloudの記録は削除しません。",
             ["can't be combined or sent automatically", "None of this deletes"]),
            ("元のiCloudの記録を残して、この切り替えを取り消します。データの置き換えが始まっている場合は取り消せません。",
             ["keeps your original iCloud records", "can't be canceled"]),
            ("端末データの削除を確認しました", ["will be deleted"]),
            ("このインストールでiCloud保存を選んだApple Accountと一致しません。元のApple Accountへ戻すまで保存領域は開きません。",
             ["won't open until"]),
            ("削除は完了扱いになっていません。記録の追加は停止したままです。iCloudに接続して再試行してください。",
             ["has not been completed", "stays stopped"]),
            ("記録を保護するため、別の保存先には切り替えていません。iCloudと空き容量を確認してください。",
             ["has not switched"]),
            ("iCloudの記録を使う場合は、下の保存先の設定で端末の記録が置き換わることを確認して切り替えられます。端末の記録でiCloudを置き換える操作は現在利用できません。アプリを削除すると、このiPhoneだけに保存した記録は失われます。",
             ["will replace this device's records", "isn't available", "will be lost"]),
            ("通信が戻ると自動で確認して、いつもの画面に戻ります。記録はこのiPhoneに残っています。",
             ["still on this iPhone"]),
            ("通信がないまま今すぐ使うには、Appスイッチャーでポモジェムを終了してから開き直してください（アプリは削除しないでください）。",
             ["PomoGem", "App Switcher", "don't delete the app"])
        ]
        for (key, phrases) in expectations {
            let value = try english(key)
            XCTAssertFalse(value.hasPrefix("<missing"), key)
            for phrase in phrases {
                XCTAssertTrue(value.contains(phrase), "\(key) → \(value) should say \(phrase)")
            }
        }
    }

    func testVerificationFailureLinesInEnglish() throws {
        XCTAssertEqual(try english("確認箇所: %@・CloudKit %@", try english("iCloudへの接続"), "8"),
                       "Step: iCloud connection · CloudKit 8")
        XCTAssertEqual(try english("確認箇所: %@", try english("全体確認")), "Step: overall check")
        XCTAssertEqual(try english("再試行まで約%@秒お待ちください。", "1200"),
                       "Please wait about 1200 sec before trying again.")
        // The watchdog's two statements join with a space in English.
        XCTAssertEqual(
            SentenceText.join([
                try english("起動を続けられませんでした。iPhoneの画面にiOSの確認（Apple Accountのサインインなど）が出ている場合は、先にそれを完了するか閉じてから「もう一度試す」を押してください。"),
                try english("記録や保存先の設定は変更していません。")
            ], locale: en),
            "The app couldn't finish starting up. If iOS is showing a prompt on your iPhone (such as signing in to your Apple Account), finish or close it first, then tap “Try Again”. Your records and storage settings have not been changed."
        )
    }

    // MARK: Timer status on the waiting screens, and counted text

    func testWaitingScreenTimerInEnglish() throws {
        let bundle = try LocalizationTestSupport.englishBundle()
        func minutes(_ count: Int) -> String {
            String(localized: "\(count)分", table: "Launch", bundle: bundle, locale: en)
        }
        func seconds(_ count: Int) -> String {
            String(localized: "\(count)秒", table: "Launch", bundle: bundle, locale: en)
        }
        XCTAssertEqual([0, 1, 2, 12].map(minutes), ["0 minutes", "1 minute", "2 minutes", "12 minutes"])
        XCTAssertEqual([0, 1, 59].map(seconds), ["0 seconds", "1 second", "59 seconds"])
        XCTAssertEqual(try english("集中は一時停止中です。残り%@%@", minutes(1), seconds(1)),
                       "Focus is paused. 1 minute, 1 second left")
        XCTAssertEqual(try english("集中は一時停止中です。残り%@%@", minutes(12), seconds(34)),
                       "Focus is paused. 12 minutes, 34 seconds left")
        XCTAssertEqual(try english("休憩中です。残り%@%@", minutes(4), seconds(1)), "On a break. 4 minutes, 1 second left")
        XCTAssertEqual(try english("集中は続いています。残り%@%@", minutes(1), seconds(59)),
                       "Focus is still running. 1 minute, 59 seconds left")
        // The Japanese pieces put back together read exactly as before.
        XCTAssertEqual(
            String(localized: "集中は一時停止中です。残り\(String(localized: "\(12)分", table: "Launch"))\(String(localized: "\(34)秒", table: "Launch"))",
                   table: "Launch"),
            "集中は一時停止中です。残り12分34秒"
        )
        XCTAssertEqual(try english("残り %@", "12:34"), "12:34 left")
        XCTAssertEqual(try english("確認が済むと、この集中を瓶に積みます。"),
                       "Once the check is done, this focus will be added to your jar.")

        XCTAssertEqual(
            String(localized: "\("Math")・残り約\(25)分。", table: "Launch", bundle: bundle, locale: en),
            "Math · about 25 min left."
        )
        XCTAssertEqual(try english("手順%lld、%@", 2, "Turn on PomoGem in iCloud"), "Step 2, Turn on PomoGem in iCloud")
        XCTAssertEqual(try english("iCloudへの最終送信：%@", try english("たった今")), "Last sent to iCloud: just now")
    }

    // MARK: The whole table

    /// Every Launch key has an English value that holds no Japanese. l10n.py
    /// checks the same in CI; this keeps the failure inside the unit suite too.
    func testEveryLaunchKeyHasEnglish() throws {
        _ = try LocalizationTestSupport.englishBundle()
        let catalog = try LocalizationCatalogFile(table: "Launch", relativePath: "PomoGem/Localization/Launch.xcstrings")
        XCTAssertFalse(catalog.strings.isEmpty)
        for (key, entry) in catalog.strings {
            let english = LocalizationCatalogFile.localizations(of: entry)["en"]
            XCTAssertNotNil(english, "\(key) has no English")
            var units = english.map { LocalizationCatalogFile.units(of: $0) } ?? []
            for substitution in (english?["substitutions"] as? [String: [String: Any]] ?? [:]).values {
                units += LocalizationCatalogFile.units(of: substitution)
            }
            for unit in units {
                XCTAssertEqual(unit.state, "translated", "\(key) \(unit.label)")
                XCTAssertFalse(LocalizationTestSupport.containsJapanese(unit.value), "\(key) \(unit.label): \(unit.value)")
            }
        }
    }
}
