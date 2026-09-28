import Foundation
import XCTest
@testable import PomoGem

/// English expectations for localization package l10n-06-settings (table: Settings).
///
/// Only that package edits this file (Docs/Localization.md). Resolve English
/// explicitly with `LocalizationTestSupport.englishBundle()` and
/// `LocalizationTestSupport.english`, which skip until English is activated;
/// never change the process language, because the rest of the suite asserts
/// Japanese.
final class SettingsLocalizationTests: XCTestCase {
    private let en = LocalizationTestSupport.english
    private let ja = LocalizationTestSupport.japanese

    /// The English value of a Settings key, formatted like the app formats it.
    private func english(_ key: String, _ arguments: CVarArg...) throws -> String {
        let bundle = try LocalizationTestSupport.englishBundle()
        let format = bundle.localizedString(forKey: key, value: "<missing \(key)>", table: "Settings")
        return arguments.isEmpty ? format : String(format: format, locale: en, arguments: arguments)
    }

    /// A counted English sentence, resolved the way `String(localized:)` resolves
    /// it in the app, so the plural variation is chosen by English rules.
    private func englishCounted(_ value: String.LocalizationValue) throws -> String {
        String(localized: value, table: "Settings", bundle: try LocalizationTestSupport.englishBundle(), locale: en)
    }

    // MARK: Typed deletion confirmation (L10N design §3.5)

    /// The word the last step asks for is one localized value: the prompt,
    /// the placeholder and the check all read it, in both languages.
    func testTheTypedDeletionWordIsTheSameValueThePromptShows() throws {
        let japanese = CompleteDataDeletionConfirmationWord.word()
        XCTAssertEqual(japanese, "削除", "Japanese devices keep the word they always typed")
        XCTAssertTrue(CompleteDataDeletionConfirmationWord.accepts("削除"))
        XCTAssertTrue(CompleteDataDeletionConfirmationWord.accepts("  削除\n"), "Whitespace around the word is trimmed")
        XCTAssertFalse(CompleteDataDeletionConfirmationWord.accepts("削 除"))
        XCTAssertFalse(CompleteDataDeletionConfirmationWord.accepts(""))
        XCTAssertFalse(CompleteDataDeletionConfirmationWord.accepts("DELETE"), "A Japanese device asks for 削除")
        XCTAssertFalse(CompleteDataDeletionConfirmationWord.typesCapitals(japanese), "Romaji input needs lower case")

        let bundle = try LocalizationTestSupport.englishBundle()
        let word = CompleteDataDeletionConfirmationWord.word(bundle: bundle, locale: en)
        XCTAssertEqual(word, "DELETE")
        XCTAssertTrue(CompleteDataDeletionConfirmationWord.accepts("DELETE", word: word))
        XCTAssertTrue(CompleteDataDeletionConfirmationWord.accepts(" DELETE ", word: word))
        XCTAssertFalse(CompleteDataDeletionConfirmationWord.accepts("delete", word: word), "The comparison stays exact")
        XCTAssertFalse(CompleteDataDeletionConfirmationWord.accepts("削除", word: word))
        XCTAssertTrue(CompleteDataDeletionConfirmationWord.typesCapitals(word), "The keyboard types the capitals the check expects")

        XCTAssertEqual(try english("「%@」と入力", word), "Type “DELETE”")
        XCTAssertEqual(try english("確認のため%@と入力", word), "Type DELETE to confirm")
        XCTAssertEqual(try english("ユーザー内容を削除"), "Delete Your Content")
        XCTAssertEqual(try english("最終確認"), "Final Confirmation")
    }

    // MARK: Plurals

    func testCountedSentencesPickTheEnglishPluralForm() throws {
        XCTAssertEqual(
            try englishCounted("\(1)件のデータを書き出しました。保存先を選んでください"),
            "Exported 1 record. Choose where to save the file."
        )
        XCTAssertEqual(
            try englishCounted("\(1_234)件のデータを書き出しました。保存先を選んでください"),
            "Exported 1,234 records. Choose where to save the file."
        )
        XCTAssertEqual(try englishCounted("あと\(1)秒"), "1 second left")
        XCTAssertEqual(try englishCounted("あと\(3)秒"), "3 seconds left")
        XCTAssertEqual(try englishCounted("プレビューまであと\(2)秒"), "Preview in 2 seconds")
        XCTAssertEqual(
            try englishCounted("テーマは最大\(Constants.App.maximumSubjects)件までです。"),
            "You can have up to 12 themes."
        )
        XCTAssertEqual(try englishCounted("あと\(1)文字入力できます。"), "You can type 1 more character.")
        XCTAssertEqual(try englishCounted("あと\(7)文字入力できます。"), "You can type 7 more characters.")
        XCTAssertEqual(
            try englishCounted("1〜\(SubjectNamePolicy.maximumCharacters)文字で入力してください。"),
            "Enter 1–\(SubjectNamePolicy.maximumCharacters) characters."
        )

        // Counts inside two-argument sentences are their own phrases, so
        // each can carry English plural forms.
        let bundle = try LocalizationTestSupport.englishBundle()
        func records(_ count: Int) -> String {
            String(localized: "settings.theme-deletion.record-count", defaultValue: "過去の記録\(count)件", table: "Settings", bundle: bundle, locale: en)
        }
        func notifications(_ count: Int) -> String {
            String(localized: "settings.focus-leave.nudge-count", defaultValue: "\(count)回", table: "Settings", bundle: bundle, locale: en)
        }
        func misses(_ count: Int) -> String {
            String(localized: "settings.rare.pity-misses", defaultValue: "\(count)回続けて", table: "Settings", bundle: bundle, locale: en)
        }
        XCTAssertEqual([records(1), records(42)], ["1 past record", "42 past records"])
        XCTAssertEqual([notifications(1), notifications(5)], ["1 notification", "5 notifications"])
        XCTAssertEqual([misses(1), misses(20)], ["1 miss in a row", "20 misses in a row"])
        let deletion = "「%@」だけを削除します。%@と質量は消えず、現在の名前と色も残ります。この操作は取り消せません。"
        XCTAssertEqual(
            try english(deletion, "SAT prep", records(1)),
            "Only the theme “SAT prep” will be deleted. Its mass and its 1 past record are not deleted and still show its current name and color. This can't be undone."
        )
        XCTAssertEqual(
            try english(deletion, "SAT prep", records(42)),
            "Only the theme “SAT prep” will be deleted. Its mass and its 42 past records are not deleted and still show its current name and color. This can't be undone."
        )
        let twentyMinutes = DurationText.short(seconds: 1_200, units: .minutesSeconds, locale: en)
        XCTAssertEqual(
            try english("離れてから%@までに最大%@", twentyMinutes, notifications(5)),
            "Up to 5 notifications within 20 min of leaving"
        )
        XCTAssertEqual(
            try english("自然抽選 %@。%@出なければ、次の抽選で保証", "5%", misses(20)),
            "Natural odds 5%. Guaranteed on the next draw after 20 misses in a row"
        )

        // The Japanese is the same text as before the split.
        XCTAssertEqual(
            String(localized: "settings.theme-deletion.record-count", defaultValue: "過去の記録\(3)件", table: "Settings"),
            "過去の記録3件"
        )
        XCTAssertEqual(String(localized: "settings.focus-leave.nudge-count", defaultValue: "\(5)回", table: "Settings"), "5回")
        XCTAssertEqual(
            String(localized: "settings.rare.pity-misses", defaultValue: "\(20)回続けて", table: "Settings"),
            "20回続けて"
        )
    }

    // MARK: Screens

    func testSettingsHeadersAndRowsInEnglish() throws {
        XCTAssertEqual(try english("設定"), "Settings")
        XCTAssertEqual(
            try ["テーマ", "集中", "音と触覚", "瓶の表示", "通知", "シェア", "アプリの利用時間", "記録の書き出しとリセット", "サポートとプライバシー"]
                .map { try english($0) },
            ["Themes", "Focus", "Sound & Haptics", "Jar Display", "Notifications", "Sharing", "App Usage", "Export and Reset Records", "Support & Privacy"]
        )
        XCTAssertEqual(try english("集中が切れたらお知らせ"), "Notify Me When I Drift Away")
        XCTAssertEqual(try english("集中に戻るお知らせ"), "Return-to-Focus Reminder", "Glossary name")
        XCTAssertEqual(try english("毎日のリマインダー"), "Daily Reminder", "Glossary name")
        XCTAssertEqual(try english("演出の強さ"), "Effect Intensity")
        XCTAssertEqual(try english("表示中の記録をリセット"), "Reset Current Records")
        XCTAssertEqual(try english("このアプリについて"), "About This App")
        XCTAssertEqual(
            try english("バージョン %@・クレジット・ライセンス", "1.1.0 (10)"),
            "Version 1.1.0 (10) · Credits · License"
        )

        let notifications = try english("「毎日のリマインダー」と「先月の瓶のお知らせ」は既定でオフです。赤いバッジや連続記録の警告は使いません。タイマー終了の通知だけは「即時通知」として送るため、iPhoneの集中モード（おやすみモードなど）で即時通知を許可していれば、その間も届きます。")
        XCTAssertTrue(notifications.hasPrefix("“Daily Reminder” and “Last Month's Jar” are off by default."), notifications)
        XCTAssertTrue(notifications.contains("no streaks"), notifications)
        XCTAssertTrue(notifications.contains("Time Sensitive"), notifications)

        XCTAssertEqual(
            try english("%@。%@", "Clear Chime", "A calm two-note tone"),
            "Clear Chime. A calm two-note tone",
            "Picker options are read as their name, then their description"
        )
        XCTAssertEqual(
            try english("%@\n変更前の状態に戻しました。\n%@", "Couldn't add the theme.", "Disk full"),
            "Couldn't add the theme.\nYour change was undone.\nDisk full"
        )
    }

    /// Same Japanese, different English: the semantic keys keep the Japanese
    /// exactly as before and give each place its own English.
    func testSemanticKeysKeepTheirJapaneseAndSplitTheEnglish() throws {
        XCTAssertEqual(
            String(localized: "settings.themes.swipe.hide", defaultValue: "非表示", table: "Settings"),
            "非表示"
        )
        XCTAssertEqual(try english("settings.themes.swipe.hide"), "Hide")
        XCTAssertEqual(try english("非表示"), "Hidden")
        XCTAssertEqual(try english("表示"), "Show")

        XCTAssertEqual(
            String(localized: "settings.export.collection.themes", defaultValue: "テーマ", table: "Settings"),
            "テーマ"
        )
        XCTAssertEqual(
            String(localized: "settings.export.collection.preferences", defaultValue: "設定", table: "Settings"),
            "設定"
        )
        XCTAssertEqual(try english("settings.export.collection.themes"), "themes")
        XCTAssertEqual(try english("settings.export.collection.preferences"), "settings")
    }

    /// The deletion and reset copy says at least as much as the Japanese:
    /// what is removed, what stays, and that it cannot be undone.
    func testResetAndDeletionCopyStaysExplicitInEnglish() throws {
        let local = try english("集中の粒・結晶・記念石を表示と集計から外し、0から始めます。テーマと設定は残ります。リセット前の記録はこのiPhoneの中に残り、データの書き出しに含まれることがあります。このiPhoneから完全に消すには、アプリを削除してください。この操作は取り消せません。")
        XCTAssertTrue(local.contains("milestone stones"), local)
        XCTAssertTrue(local.contains("remain on this iPhone"), local)
        XCTAssertTrue(local.hasSuffix("This can't be undone."), local)

        let cloud = try english("集中の粒・結晶・記念石を表示と集計から外し、0から始めます。同じiCloudを使うほかのiPhoneにも、接続したときに反映されます。オフラインのiPhoneから古い記録が戻らないよう、リセット前の記録は同期のために残り、データの書き出しにも含まれます。このiPhoneから完全に消すにはアプリを削除し、iCloudのデータはiPhoneの「設定」にあるiCloudのストレージ管理から削除してください。この操作は取り消せません。")
        XCTAssertTrue(cloud.contains("remain for syncing"), cloud)
        XCTAssertTrue(cloud.hasSuffix("This can't be undone."), cloud)

        let single = try english("「%@」を削除します。関連する過去の記録はありません。この操作は取り消せません。", "Math")
        XCTAssertEqual(single, "“Math” will be deleted. It has no past records. This can't be undone.")

        let startOver = try english(
            "設定の「%@」で「このiPhoneへ引き継ぐ」を選ぶと、保存先がこのiPhoneだけになります。そのあと「表示中の記録をリセット」で0から始められます。iCloudの記録は削除されずに残り、以後は同期しません。",
            "iCloud & Storage"
        )
        XCTAssertTrue(startOver.contains("“iCloud & Storage”"), startOver)
        XCTAssertTrue(startOver.contains("“\(try english("表示中の記録をリセット"))”"), "Names the reset button as it reads: \(startOver)")
        XCTAssertTrue(startOver.contains("are not deleted"), startOver)

        let delete = try english("iCloudに保存したポモジェムのデータは、iPhoneの「設定」アプリから削除できます。同じApple Accountのすべての端末から消え、元に戻せません。")
        XCTAssertTrue(delete.contains("every device"), delete)
        XCTAssertTrue(delete.contains("can't be restored"), delete)
    }

    func testThemeEditorAndPaletteInEnglish() throws {
        XCTAssertEqual(
            SubjectPalette.swatches.map(\.name),
            ["朱色", "瑠璃", "青緑", "緑青", "空色", "藍", "琥珀", "紅藤", "赤銅", "菫", "珊瑚", "若草"]
        )
        XCTAssertEqual(
            try SubjectPalette.swatches.map(\.name).map { try english($0) },
            ["Vermilion", "Lapis", "Teal", "Verdigris", "Sky Blue", "Indigo", "Amber", "Orchid", "Copper", "Violet", "Coral", "Leaf Green"]
        )
        XCTAssertEqual(try english("色候補%lld、%@", 3, "Teal"), "Color option 3, Teal")
        XCTAssertEqual(try english("同じ名前のテーマ「%@」がすでにあります。", "Math"), "You already have a theme named “Math”.")
        XCTAssertEqual(try english("テーマを追加"), "Add Theme")
        XCTAssertEqual(try english("テーマを編集"), "Edit Theme")
    }

    func testTimerPagesInEnglish() throws {
        XCTAssertEqual(try english("タイマーの既定の向き"), "Default Timer Orientation")
        XCTAssertEqual(
            try english("「%@」は端末の向きに合わせます。上・右・下・左は、縦に持ったiPhoneの画面内でタイマーの上辺が向く方向です。", "Automatic"),
            "“Automatic” follows how you hold your iPhone. Up, Right, Down and Left are the way the top of the timer faces on an iPhone held upright."
        )
        XCTAssertEqual(try english("タイマーの表示"), "Timer Display")
        XCTAssertEqual(try english("既定の集中時間"), "Default Focus Length")
        XCTAssertEqual(try english("カスタム時間"), "Custom Length")
        XCTAssertEqual(try english("選択中"), "Selected")
        XCTAssertEqual(try english("未選択"), "Not selected")
    }

    // MARK: Support mail and export

    /// The human sentences are translated; the diagnostics stay one
    /// `label: value` line each, so support can read them in either language.
    func testSupportMailInEnglish() throws {
        XCTAssertEqual(try english("ポモジェムについてのお問い合わせ"), "Question about PomoGem")
        XCTAssertEqual(
            [
                try english("アプリ：ポモジェム %@", "1.1.0 (10)"),
                try english("iOS：%@", "26.5"),
                try english("機種：%@", "iPhone13,1"),
                try english("保存先：%@", try english("このiPhoneのみ")),
                try english("Pro：%@", try english("未購入"))
            ],
            ["App: PomoGem 1.1.0 (10)", "iOS: 26.5", "Model: iPhone13,1", "Storage: This iPhone Only", "Pro: Not purchased"]
        )
        XCTAssertEqual(try english("iCloud（オフラインで利用中）"), "iCloud (used offline)")
        XCTAssertEqual(try english("利用中"), "Active")
        XCTAssertEqual(try english("承認待ち"), "Awaiting approval")
    }

    func testExportProgressInBothLanguages() throws {
        let writing = PomoGemDataExportProgress(
            phase: .writing(collectionName: "集中記録"),
            completedRecords: 3,
            estimatedTotalRecords: 10
        )
        XCTAssertEqual(writing.accessibilityDescription, "集中記録を書き出し中、10件中3件")
        XCTAssertEqual(
            try english("%@を書き出し中、%lld件中%lld件", try english("集中記録"), 10, 3),
            "Exporting focus sessions: 3 of 10"
        )
        XCTAssertEqual(try english("%@を書き出し中", try english("settings.export.collection.themes")), "Exporting themes…")
        XCTAssertEqual(try english("データを書き出す準備中"), "Preparing to export data")
    }
}
