import Observation
import SwiftUI

@MainActor
@Observable
final class StorageTransferController {
    typealias Operation = @MainActor @Sendable (StorageTransferChoice) async throws -> Void
    /// The two directional dataset operations. They do not go through
    /// `begin`: a mounted cloud session has already opened the CloudKit
    /// mirror, so they record a durable request and ask for the deliberate
    /// relaunch that executes it. See `StorageTransferDatasetRequest`.
    typealias DatasetOperation =
        @MainActor @Sendable (StorageTransferDatasetRequestDirection) async throws -> Void

    private(set) var isStarting = false
    private(set) var error: String?
    private var operation: Operation?
    private var datasetOperation: DatasetOperation?
    private var registrationID: UUID?
    private var task: Task<Void, Never>?

    var isAvailable: Bool { operation != nil && !isStarting }
    var isDatasetAvailable: Bool { datasetOperation != nil && !isStarting }

    @discardableResult
    func install(_ operation: @escaping Operation, dataset: DatasetOperation? = nil) -> UUID {
        let id = UUID()
        self.operation = operation
        datasetOperation = dataset
        registrationID = id
        return id
    }

    /// A registered operation captures its Root and model context. Detach it
    /// as that Root disappears so an idle controller cannot retain a retired
    /// persistence session. A confirmed operation already owns its own copy;
    /// it must finish its durable handoff without being cancelled or unlocked.
    func uninstall(registrationID: UUID) {
        guard self.registrationID == registrationID else { return }
        operation = nil
        datasetOperation = nil
        self.registrationID = nil
    }

    /// Only a confirmed choice reaches this method. A second tap cannot launch
    /// another transaction while the first account check is suspended.
    func start(_ choice: StorageTransferChoice) {
        guard !isStarting, task == nil, let operation else { return }
        do { try StorageTransferReleasePolicy.standard.validate(choice) }
        catch {
            self.error = error.localizedDescription
            return
        }
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

    /// Only an acknowledged direction reaches this method. The policy is passed
    /// in rather than read from `.standard` so the Debug UI-test fixture can
    /// exercise the published flow with exactly one bit raised; every other
    /// caller passes `.standard`, and the runtime entry point that finally runs
    /// the direction re-validates `.standard` for itself.
    func startDataset(_ direction: StorageTransferDatasetRequestDirection,
                      policy: StorageTransferReleasePolicy = .standard) {
        guard !isStarting, task == nil, let datasetOperation else { return }
        do { try StorageTransferDatasetRequestPolicy.validate(direction, policy: policy) }
        catch {
            self.error = error.localizedDescription
            return
        }
        error = nil
        isStarting = true
        task = Task { @MainActor [weak self] in
            do {
                try await datasetOperation(direction)
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
    /// Injected so the Debug UI-test fixture can exercise a published door with
    /// exactly one bit raised. Every shipping caller uses the default.
    var releasePolicy: StorageTransferReleasePolicy = .standard
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
                    StorageTransferChoiceView(
                        persistenceMode: persistenceMode,
                        releasePolicy: releasePolicy,
                        offersDatasetDoors: controller.isDatasetAvailable,
                        confirmed: { choice in
                            showsChoices = false
                            controller.start(choice)
                        },
                        confirmedDataset: { direction in
                            showsChoices = false
                            controller.startDataset(direction, policy: releasePolicy)
                        }
                    )
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
    let releasePolicy: StorageTransferReleasePolicy
    let offersDatasetDoors: Bool
    let confirmed: (StorageTransferChoice) -> Void
    let confirmedDataset: (StorageTransferDatasetRequestDirection) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var choice: StorageTransferChoice?
    /// Its own presentation state, so a tentative dataset direction can never
    /// be confused with a tentative storage-mode choice, and so the two kinds
    /// of confirmation never share an acknowledgement.
    @State private var datasetDirection: StorageTransferDatasetRequestDirection?

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
                    datasetDoors
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
                        Text(StorageTransferReleaseError.cloudReplacementUnavailable.localizedDescription)
                            .accessibilityIdentifier("storage-switch.replace-cloud-unavailable")
                        Button("このiPhoneのデータで置き換える", role: .destructive) { choice = .enableCloudReplacingCloud }
                            .disabled(!StorageTransferReleasePolicy.standard.allowsCloudReplacement)
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
            // The cloud-mode screen no longer only unlinks iCloud: it also
            // offers the generation-fenced device -> iCloud replacement.
            .navigationTitle(persistenceMode == .cloudKit ? "iCloudと保存先の変更" : "iCloudを有効にする")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } } }
            .sheet(item: $choice) { selected in
                StorageTransferConfirmationView(choice: selected) { confirmed(selected) }
                    .dynamicTypeSize(dynamicTypeSize)
            }
            .sheet(item: $datasetDirection) { direction in
                StorageTransferDatasetConfirmationView(direction: direction) {
                    confirmedDataset(direction)
                }
                .dynamicTypeSize(dynamicTypeSize)
            }
        }
    }

    /// PLAN Steps 11-12. The two directional dataset doors, in the order the
    /// plan lists them. `storage-switch.replace-cloud` — the legacy
    /// `localOnly -> cloud` replacement — is untouched and still keyed off its
    /// own, separate bit in the enable branch below.
    @ViewBuilder
    private var datasetDoors: some View {
        if offersDatasetDoors {
            Section("このiPhoneのデータでiCloudを置き換える") {
                Text(StorageTransferOverwriteCopy.dataLossWarning)
                if !releasePolicy.allowsDatasetOverwriteFromDevice {
                    Text(StorageTransferReleaseError.datasetOverwriteUnavailable.localizedDescription)
                        .accessibilityIdentifier("storage-switch.overwrite-cloud-unavailable")
                }
                Button(StorageTransferOverwriteCopy.confirmTitle, role: .destructive) {
                    // Never acts on tap: it presents 「最後の確認」, whose own
                    // acknowledgement starts unchecked on every presentation.
                    datasetDirection = .overwriteCloudFromDevice
                }
                .disabled(!releasePolicy.allowsDatasetOverwriteFromDevice)
                .accessibilityIdentifier("storage-switch.overwrite-cloud")
            }
            // Direction (B) carries NO release bit (PLAN Step 12). It deletes
            // nothing on the server and is the same operation the recovery
            // screen runs unconditionally; gating it on the opposite,
            // destructive direction's bit would ship the one thing a user with
            // a diverged device always needs as a permanently greyed-out row.
            Section(StorageTransferRefreshCopy.settingsTitle) {
                Text(StorageTransferRefreshCopy.dataLossWarning)
                Button(StorageTransferRefreshCopy.confirmTitle, role: .destructive) {
                    datasetDirection = .refreshFromCloud
                }
                .accessibilityIdentifier("storage-switch.refresh-from-cloud")
            }
        }
    }
}

extension StorageTransferChoice: Identifiable { var id: Self { self } }
extension StorageTransferDatasetRequestDirection: Identifiable { var id: Self { self } }

/// 「最後の確認」 for a directional dataset replacement. Everything the direction
/// will do, restated in full, with its own unchecked acknowledgement and its
/// own destructive action. A fresh instance is built for every presentation, so
/// 戻る discards the acknowledgement and no other confirmation in this screen
/// can ever arm this one (PLAN §3 S9).
private struct StorageTransferDatasetConfirmationView: View {
    let direction: StorageTransferDatasetRequestDirection
    let confirmed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var understandsDeletion = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    switch direction {
                    case .overwriteCloudFromDevice:
                        paragraph(StorageTransferOverwriteCopy.sheetWarning, suffix: "warning")
                        paragraph(StorageTransferOverwriteCopy.recoveryCopy, suffix: "recovery-copy")
                        paragraph(StorageTransferOverwriteCopy.relaunch, suffix: "relaunch")
                        paragraph(StorageTransferOverwriteCopy.notCancellable, suffix: "not-cancellable")
                        paragraph(StorageTransferOverwriteCopy.screenTime, suffix: "screen-time")
                    case .refreshFromCloud:
                        // No recovery-copy paragraph: this direction stages
                        // nothing on the server and deletes nothing there. The
                        // device side is what is discarded, and it has no
                        // backup — saying otherwise would be a false promise.
                        paragraph(StorageTransferRefreshCopy.dataLossWarning, suffix: "warning")
                        paragraph(StorageTransferRefreshCopy.relaunch, suffix: "relaunch")
                    }
                    Toggle(acknowledgement, isOn: $understandsDeletion)
                        .accessibilityIdentifier(identifier("confirm-data-loss"))
                    Button(confirmTitle, role: .destructive, action: confirmed)
                        .disabled(!understandsDeletion)
                        .accessibilityIdentifier(identifier("confirm"))
                }
            }
            .navigationTitle("最後の確認")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("戻る") { dismiss() } } }
        }
    }

    private var door: String {
        switch direction {
        case .overwriteCloudFromDevice: "overwrite-cloud"
        case .refreshFromCloud: "refresh-from-cloud"
        }
    }

    /// Each direction names the side it destroys. The two sentences are
    /// deliberately not interchangeable.
    private var acknowledgement: String {
        switch direction {
        case .overwriteCloudFromDevice: StorageTransferOverwriteCopy.acknowledgement
        case .refreshFromCloud: StorageTransferRefreshCopy.acknowledgement
        }
    }

    private var confirmTitle: String {
        switch direction {
        case .overwriteCloudFromDevice: StorageTransferOverwriteCopy.sheetConfirm
        case .refreshFromCloud: StorageTransferRefreshCopy.confirmTitle
        }
    }

    private func identifier(_ suffix: String) -> String { "storage-switch.\(door)-\(suffix)" }

    private func paragraph(_ text: String, suffix: String) -> some View {
        Text(text).accessibilityIdentifier(identifier(suffix))
    }
}

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
                    // Every choice that replaces the iCloud dataset stages a
                    // recovery copy first, not only the legacy one.
                    if choice.replacesCloud {
                        Text("置き換えるデータの復旧用コピーをiCloudに保存し、受領を確認してから削除を始めます。復旧用コピーには、このiPhoneだけの過去の記録も含まれます。処理完了後に復旧用コピーを削除します。通信が途切れた場合は、削除の再試行までiCloudに残ることがあります。")
                    }
                    if choice != .disableCloudKeepingCopy {
                        Toggle("削除される保存先とデータを確認しました", isOn: $understandsDeletion)
                            .accessibilityIdentifier("storage-switch.confirm-data-loss")
                    }
                    Button(choice == .disableCloudKeepingCopy ? "コピーしてiCloudを解除" : "置き換えてiCloudを有効にする",
                           role: choice == .disableCloudKeepingCopy ? nil : .destructive,
                           action: confirmed)
                        // Per choice, not per bit: the three release bits are
                        // independent, so asking the policy about THIS choice
                        // is the only gate that stays correct as cases are
                        // added. `.overwriteCloudFromDevice` never reaches this
                        // view — Settings routes it through its own directional
                        // confirmation — but it must not be gated on the legacy
                        // bit if it ever does.
                        .disabled(((try? StorageTransferReleasePolicy.standard.validate(choice)) == nil)
                                  || (choice != .disableCloudKeepingCopy && !understandsDeletion))
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
        case .overwriteCloudFromDevice:
            "現在iCloudにあるPomoGemのテーマ・記録・設定をすべて削除し、この端末のデータに置き換えます。削除するiCloudのデータを元に戻すことはできません。"
        }
    }
}
