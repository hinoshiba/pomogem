import SwiftUI

/// settings-03 / transfer-09. The fixed copy for the page the disabled
/// iCloud reset points to. Kept in one place so a reviewer can diff the
/// shipped wording against PRIVACY.md.
enum CloudDataDeletionGuidanceCopy {
    static let rowTitle = String(
        localized: "記録を消す・やり直す方法",
        table: "Settings",
        comment: "Settings row and page title: how to delete the iCloud records or start over"
    )

    static let startOverTitle = String(
        localized: "このiPhoneだけで0から始める",
        table: "Settings",
        comment: "Section header: switch this iPhone to local-only storage and reset"
    )
    /// Quotes the storage section's entry by its constant, as that section asks.
    static let startOver = String(
        localized: "設定の「\(StorageTransferSettingsSection.cloudEntryTitle)」で「このiPhoneへ引き継ぐ」を選ぶと、保存先がこのiPhoneだけになります。そのあと「表示中の記録をリセット」で0から始められます。iCloudの記録は削除されずに残り、以後は同期しません。",
        table: "Settings",
        comment: "The argument is the Settings button that opens the storage change sheet (iCloudと保存先の変更, Storage table). このiPhoneへ引き継ぐ is the button in that sheet, 表示中の記録をリセット the reset button in Settings: keep their English identical to those buttons."
    )

    static let deleteTitle = String(
        localized: "iCloudのデータを削除する",
        table: "Settings",
        comment: "Section header: delete the app's data from iCloud in iOS Settings"
    )
    static let delete = String(
        localized: "iCloudに保存したポモジェムのデータは、iPhoneの「設定」アプリから削除できます。同じApple Accountのすべての端末から消え、元に戻せません。",
        table: "Settings",
        comment: "設定 is the iOS Settings app"
    )
    static let exportTitle = String(
        localized: "先に記録を書き出す",
        table: "Settings",
        comment: "Button: export the records before deleting them"
    )
    /// The transfer screens' sentence, not a second spelling of it.
    static let exportNote = StorageTransferOverwriteCopy.exportNote
    /// Version-neutral wording and no deep link: the labels of iOS Settings
    /// move between releases, and a link that lands on the wrong page is worse
    /// than a sentence.
    static let steps = [
        String(
            localized: "1. このApple Accountでポモジェムを使っているすべての端末で、アプリを削除します。",
            table: "Settings",
            comment: "Step 1 of deleting the iCloud data"
        ),
        String(
            localized: "2. iPhoneの「設定」を開き、いちばん上の自分の名前から「iCloud」に進みます。",
            table: "Settings",
            comment: "Step 2 of deleting the iCloud data; quote iOS Settings as it reads in the language"
        ),
        String(
            localized: "3. 「アカウントのストレージを管理」（または「ストレージを管理」）で「ポモジェム」を選び、データを削除します。",
            table: "Settings",
            comment: "Step 3 of deleting the iCloud data; アカウントのストレージを管理 / ストレージを管理 are iOS Settings labels (Manage Account Storage / Manage Storage)"
        )
    ]
    static let why = String(
        localized: "アプリの中からiCloudのデータを消す機能は、ほかの端末の記録が消えてしまわないよう、いまは用意していません。",
        table: "Settings",
        comment: "Footer: why the app has no in-app iCloud deletion"
    )
}

/// A static page. It starts nothing itself: the only control is the ordinary
/// Settings export, and every destructive step it describes happens outside
/// this app, in iOS Settings, under Apple's own confirmation.
struct CloudDataDeletionGuidanceView: View {
    let isExporting: Bool
    let export: () -> Void

    var body: some View {
        List {
            Section {
                Text(CloudDataDeletionGuidanceCopy.startOver)
                    .accessibilityIdentifier("settings.reset-guidance.start-over")
            } header: {
                Text(CloudDataDeletionGuidanceCopy.startOverTitle)
            }
            Section {
                Text(CloudDataDeletionGuidanceCopy.delete)
                    .accessibilityIdentifier("settings.reset-guidance.delete")
                Button(action: export) {
                    HStack {
                        Text(CloudDataDeletionGuidanceCopy.exportTitle)
                        Spacer()
                        if isExporting { ProgressView() }
                    }
                    .frame(minHeight: 44)
                }
                .disabled(isExporting)
                .accessibilityIdentifier("settings.reset-guidance.export")
                Text(CloudDataDeletionGuidanceCopy.exportNote)
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                ForEach(CloudDataDeletionGuidanceCopy.steps, id: \.self) { step in
                    Text(step)
                }
            } header: {
                Text(CloudDataDeletionGuidanceCopy.deleteTitle)
            } footer: {
                Text(CloudDataDeletionGuidanceCopy.why)
            }
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground())
        .navigationTitle(CloudDataDeletionGuidanceCopy.rowTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}
