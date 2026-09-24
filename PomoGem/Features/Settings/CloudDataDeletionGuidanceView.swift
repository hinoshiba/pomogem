import SwiftUI

/// settings-03 / transfer-09. The fixed Japanese copy for the page the
/// disabled iCloud reset points to. Kept in one place so a reviewer can diff
/// the shipped wording against PRIVACY.md.
enum CloudDataDeletionGuidanceCopy {
    static let rowTitle = "記録を消す・やり直す方法"

    static let startOverTitle = "このiPhoneだけで0から始める"
    static let startOver =
        "設定の「iCloudと保存先の変更」で「このiPhoneへ引き継ぐ」を選ぶと、保存先がこのiPhoneだけになります。そのあと「表示中の記録をリセット」で0から始められます。iCloudの記録は削除されずに残り、以後は同期しません。"

    static let deleteTitle = "iCloudのデータを削除する"
    static let delete =
        "iCloudに保存したポモジェムのデータは、iPhoneの「設定」アプリから削除できます。同じApple Accountのすべての端末から消え、元に戻せません。"
    static let exportTitle = "先に記録を書き出す"
    /// The transfer screens' sentence, not a second spelling of it.
    static let exportNote = StorageTransferOverwriteCopy.exportNote
    /// Version-neutral wording and no deep link: the labels of iOS Settings
    /// move between releases, and a link that lands on the wrong page is worse
    /// than a sentence.
    static let steps = [
        "1. このApple Accountでポモジェムを使っているすべての端末で、アプリを削除します。",
        "2. iPhoneの「設定」を開き、いちばん上の自分の名前から「iCloud」に進みます。",
        "3. 「アカウントのストレージを管理」（または「ストレージを管理」）で「ポモジェム」を選び、データを削除します。"
    ]
    static let why =
        "アプリの中からiCloudのデータを消す機能は、ほかの端末の記録が消えてしまわないよう、いまは用意していません。"
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
