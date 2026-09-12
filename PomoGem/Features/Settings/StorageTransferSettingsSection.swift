import Observation
import SwiftUI

@MainActor
@Observable
final class StorageTransferController {
    typealias Operation = @MainActor @Sendable (StorageTransferChoice) async throws -> Void

    private(set) var isStarting = false
    private(set) var error: String?
    private var operation: Operation?
    private var task: Task<Void, Never>?

    var isAvailable: Bool { operation != nil && !isStarting }

    func install(_ operation: @escaping Operation) { self.operation = operation }

    /// Only a confirmed choice reaches this method. A second tap cannot launch
    /// another transaction while the first account check is suspended.
    func start(_ choice: StorageTransferChoice) {
        guard !isStarting, task == nil, let operation else { return }
        error = nil
        isStarting = true
        task = Task { @MainActor [weak self] in
            do {
                try await operation(choice)
            } catch {
                self?.error = error.localizedDescription
                self?.isStarting = false
            }
            self?.task = nil
        }
    }
}

/// A navigation choice followed by a specific confirmation makes the losing
/// dataset explicit. Merely opening Settings or changing a tentative selection
/// cannot mutate either store.
struct StorageTransferSettingsSection: View {
    let persistenceMode: PersistenceLaunchMode
    let controller: StorageTransferController
    let otherWorkIsActive: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsChoices = false

    var body: some View {
        if persistenceMode == .cloudKit || persistenceMode == .localOnly {
            Section {
                LabeledContent("現在の保存先", value: persistenceMode == .cloudKit ? "iCloud" : "このiPhoneのみ")
                Button(persistenceMode == .cloudKit ? "iCloudを解除する" : "iCloudを有効にする") {
                    showsChoices = true
                }
                .disabled(!controller.isAvailable || otherWorkIsActive)
                .accessibilityIdentifier("settings.storage-switch")
                // List flattens Section into rows. Attach presentation to the
                // concrete entry row so its presenter remains in the hierarchy.
                .sheet(isPresented: $showsChoices) {
                    StorageTransferChoiceView(persistenceMode: persistenceMode) { choice in
                        showsChoices = false
                        controller.start(choice)
                    }
                    .dynamicTypeSize(dynamicTypeSize)
                }
                if controller.isStarting {
                    ProgressView("保存先の切り替えを準備しています")
                }
                if let error = controller.error {
                    Text(error).foregroundStyle(.red)
                        .accessibilityIdentifier("settings.storage-switch-error")
                }
            } header: {
                Text("iCloudと保存先")
            } footer: {
                Text("切り替え前に確認画面を表示します。実行中・一時停止中のタイマーは、先に終了してください。")
            }
        }
    }
}

private struct StorageTransferChoiceView: View {
    let persistenceMode: PersistenceLaunchMode
    let confirmed: (StorageTransferChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var choice: StorageTransferChoice?

    var body: some View {
        NavigationStack {
            List {
                if persistenceMode == .cloudKit {
                    Section {
                        Text("iCloudのデータをこのiPhoneにコピーしてから、同期を解除します。iCloud側のデータは残ります。")
                        Text("解除後の変更は他の端末へ同期されません。このiPhoneのアプリを削除すると、解除後に端末で追加・変更したデータは失われます。")
                        Button("このiPhoneへ引き継ぐ") { choice = .disableCloudKeepingCopy }
                            .accessibilityIdentifier("storage-switch.disable-keep-copy")
                    }
                } else {
                    Section {
                        Text("残すデータを選んでください。2つの保存先のデータは結合しません。")
                    }
                    Section("iCloudのデータを残す") {
                        Text("現在このiPhoneにあるテーマ・記録・設定を削除し、iCloudのデータに置き換えます。端末だけの記録は失われます。")
                        Button("iCloudのデータを使う", role: .destructive) { choice = .enableCloudKeepingCloud }
                            .accessibilityIdentifier("storage-switch.keep-cloud")
                    }
                    Section("このiPhoneのデータを残す") {
                        Text("現在iCloudにあるPomoGemのテーマ・記録・設定を削除し、このiPhoneのデータに置き換えます。同じApple Accountの他の端末にも影響します。")
                        Text("他の端末のPomoGemを終了し、最新版へ更新してください。古い版やオフラインの端末が後から接続すると、古いデータが再び届く可能性があります。")
                        Button("このiPhoneのデータで置き換える", role: .destructive) { choice = .enableCloudReplacingCloud }
                            .accessibilityIdentifier("storage-switch.replace-cloud")
                    }
                    Section {
                        Text("テーマ名・成果メモ・記録・設定・タイマーの整合用データが、あなたのApple AccountのプライベートiCloud領域に保存されます。")
                    }
                }
                Section {
                    Text("通信状態やデータ量によって時間がかかります。安全のため、画面の案内に従ってアプリを終了し、開き直す手順があります。アプリ自体は削除しないでください。中断した場合は、次回起動時に復旧画面を表示します。")
                }
            }
            .navigationTitle(persistenceMode == .cloudKit ? "iCloudを解除" : "iCloudを有効にする")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } } }
            .sheet(item: $choice) { selected in
                StorageTransferConfirmationView(choice: selected) { confirmed(selected) }
                    .dynamicTypeSize(dynamicTypeSize)
            }
        }
    }
}

extension StorageTransferChoice: Identifiable { var id: Self { self } }

private struct StorageTransferConfirmationView: View {
    let choice: StorageTransferChoice
    let confirmed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var understandsDeletion = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(message)
                    if choice == .enableCloudReplacingCloud {
                        Text("置き換えるデータの復旧用コピーをiCloudに保存し、受領を確認してから削除を始めます。復旧用コピーには、このiPhoneだけの過去の記録も含まれます。処理完了後に復旧用コピーを削除します。通信が途切れた場合は、削除の再試行までiCloudに残ることがあります。")
                    }
                    if choice != .disableCloudKeepingCopy {
                        Toggle("削除される保存先とデータを確認しました", isOn: $understandsDeletion)
                            .accessibilityIdentifier("storage-switch.confirm-data-loss")
                    }
                    Button(choice == .disableCloudKeepingCopy ? "コピーしてiCloudを解除" : "置き換えてiCloudを有効にする",
                           role: choice == .disableCloudKeepingCopy ? nil : .destructive,
                           action: confirmed)
                        .disabled(choice != .disableCloudKeepingCopy && !understandsDeletion)
                        .accessibilityIdentifier("storage-switch.confirm")
                }
            }
            .navigationTitle("最後の確認")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("戻る") { dismiss() } } }
        }
    }

    private var message: String {
        switch choice {
        case .disableCloudKeepingCopy:
            "このiPhoneにコピーしたデータと、iCloudのデータの両方が残ります。コピーを検証できるまで同期を解除しません。"
        case .enableCloudKeepingCloud:
            "このiPhoneだけにあるPomoGemのデータを削除します。iCloudのデータは残ります。削除後に元の端末データへ戻すことはできません。"
        case .enableCloudReplacingCloud:
            "iCloudにあるPomoGemのデータを削除します。このiPhoneのデータを残して同期を有効にします。削除するiCloudデータを元に戻すことはできません。"
        }
    }
}
