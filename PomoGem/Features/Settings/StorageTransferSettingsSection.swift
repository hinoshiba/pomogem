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
    /// The read-only pre-flight the device -> iCloud direction must show BEFORE
    /// its acknowledgement (PLAN §3 S14). It starts nothing, records nothing
    /// and opens no container; a failure closes the door rather than opening it
    /// on an assumption.
    typealias DatasetPreviewOperation =
        @MainActor @Sendable () async throws -> StorageTransferDatasetPreviewSummary

    private(set) var isStarting = false
    private(set) var error: String?
    private var operation: Operation?
    private var datasetOperation: DatasetOperation?
    private var datasetPreviewOperation: DatasetPreviewOperation?
    private var registrationID: UUID?
    private var task: Task<Void, Never>?

    var isAvailable: Bool { operation != nil && !isStarting }
    var isDatasetAvailable: Bool { datasetOperation != nil && !isStarting }

    @discardableResult
    func install(_ operation: @escaping Operation, dataset: DatasetOperation? = nil,
                 datasetPreview: DatasetPreviewOperation? = nil) -> UUID {
        let id = UUID()
        self.operation = operation
        datasetOperation = dataset
        datasetPreviewOperation = datasetPreview
        registrationID = id
        return id
    }

    /// Read-only. Surfaced to the view so a failed read can keep the door shut
    /// with its own message instead of being reported as an empty dataset.
    func previewDataset() async throws -> StorageTransferDatasetPreviewSummary {
        guard let datasetPreviewOperation else { throw StorageTransferError.staleTransaction }
        return try await datasetPreviewOperation()
    }

    /// A registered operation captures its Root and model context. Detach it
    /// as that Root disappears so an idle controller cannot retain a retired
    /// persistence session. A confirmed operation already owns its own copy;
    /// it must finish its durable handoff without being cancelled or unlocked.
    func uninstall(registrationID: UUID) {
        guard self.registrationID == registrationID else { return }
        operation = nil
        datasetOperation = nil
        datasetPreviewOperation = nil
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
                self?.error = Self.failureMessage(for: error)
                self?.isStarting = false
            }
            self?.task = nil
        }
    }

    /// Shown alone under 「iCloudと保存先」. The shared timer check describes
    /// the timer, not the switch it stopped, so its message is restated to
    /// say what did not happen. Other errors keep their own message.
    static func failureMessage(for error: Error) -> String {
        guard (error as? FocusCloudSyncError) == .timerHistoryRequiresMaintenance else {
            return error.localizedDescription
        }
        return "タイマーの履歴を確認できなかったため、保存先を切り替えられませんでした。少し時間をおいてから、もう一度お試しください。解決しない場合は、設定のサポートからお問い合わせください。"
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
                self?.error = Self.failureMessage(for: error)
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
    /// transfer-07. True while Screen Time gems are on, monitoring, or holding
    /// black gems — the state every switch resets. Users who never used the
    /// feature see no extra paragraph.
    var disclosesScreenTimeReset = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsChoices = false

    /// The iCloud-mode entry, named after the sheet it opens. Other screens
    /// that send the user here quote this constant.
    static let cloudEntryTitle = "iCloudと保存先の変更"

    var body: some View {
        if persistenceMode == .cloudKit || persistenceMode == .localOnly {
            Section {
                LabeledContent("現在の保存先", value: persistenceMode == .cloudKit ? "iCloud" : "このiPhoneのみ")
                // transfer-08. In iCloud mode the sheet this opens is no longer
                // only 「解除」: it also holds 「iCloudから再取得」. The entry is
                // named after the sheet, so nobody has to guess that re-fetching
                // lives behind a button that says it unlinks iCloud.
                Button(persistenceMode == .cloudKit ? Self.cloudEntryTitle : "iCloudを有効にする") {
                    showsChoices = true
                }
                .accessibilityHint(persistenceMode == .cloudKit
                    ? "このiPhoneへの引き継ぎや、iCloudからの再取得を選べます"
                    : "iCloudのデータをこのiPhoneで使う方法を選べます")
                .disabled(!controller.isAvailable || otherWorkIsActive)
                .accessibilityIdentifier("settings.storage-switch")
                // List flattens Section into rows. Attach presentation to the
                // concrete entry row so its presenter remains in the hierarchy.
                .sheet(isPresented: $showsChoices) {
                    StorageTransferChoiceView(
                        persistenceMode: persistenceMode,
                        releasePolicy: releasePolicy,
                        offersDatasetDoors: controller.isDatasetAvailable,
                        disclosesScreenTimeReset: disclosesScreenTimeReset,
                        previewDataset: { try await controller.previewDataset() },
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
    let disclosesScreenTimeReset: Bool
    let previewDataset: @MainActor @Sendable () async throws -> StorageTransferDatasetPreviewSummary
    let confirmed: (StorageTransferChoice) -> Void
    let confirmedDataset: (StorageTransferDatasetRequestDirection) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.modelContext) private var modelContext
    @State private var choice: StorageTransferChoice?
    /// transfer-02. The same read-only pre-flight, for the local-only door
    /// that deletes this device's jar. Its own state, so a reading taken for a
    /// dataset direction is never the evidence behind this confirmation.
    @State private var choicePreview: StorageTransferDatasetPreviewSummary?
    @State private var isReadingChoicePreview = false
    @State private var choicePreviewError: String?
    /// Its own presentation state, so a tentative dataset direction can never
    /// be confused with a tentative storage-mode choice, and so the two kinds
    /// of confirmation never share an acknowledgement.
    @State private var datasetDirection: StorageTransferDatasetRequestDirection?
    /// The pre-flight BOTH directions must show before their acknowledgement.
    /// Discarded with every presentation, so a stale reading can never be the
    /// evidence behind a later confirmation.
    ///
    /// review-1-2 / review-2-4. Direction (B) used to open its confirmation
    /// with no server read at all. W6 then made it reachable for accounts with
    /// no transfer ledger — exactly the accounts whose iCloud side is most
    /// likely to be empty — while `refreshCloudDatasetWithoutLineage` retires
    /// the device's stores with no recovery payload anywhere. 「iCloudのデータは
    /// 残ります」 reads as reassurance while saying nothing about how much there
    /// is, so this direction is now armed by the same enumeration.
    @State private var datasetPreview: StorageTransferDatasetPreviewSummary?
    @State private var isReadingDatasetPreview = false
    @State private var datasetPreviewError: String?
    @State private var readingDirection: StorageTransferDatasetRequestDirection?

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
                    enableDoors
                }
                Section {
                    Text("通信状態やデータ量によって時間がかかります。安全のため、画面の案内に従ってアプリを終了し、開き直す手順があります。アプリ自体は削除しないでください。中断した場合は、次回起動時に復旧画面を表示します。")
                }
            }
            // The cloud-mode screen no longer only unlinks iCloud: it also
            // offers the generation-fenced device -> iCloud replacement.
            .navigationTitle(persistenceMode == .cloudKit
                ? StorageTransferSettingsSection.cloudEntryTitle : "iCloudを有効にする")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } } }
            .sheet(item: $choice) { selected in choiceConfirmation(selected) }
            .sheet(item: $datasetDirection) { direction in datasetConfirmation(direction) }
        }
    }

    /// The local-only screen's doors.
    @ViewBuilder
    private var enableDoors: some View {
        Section {
            Text("残すデータを選んでください。2つの保存先のデータは結合しません。")
        }
        Section("iCloudのデータを残す") {
            Text("現在このiPhoneにあるテーマ・記録・設定を削除し、iCloudのデータに置き換えます。端末だけの記録は失われます。")
            if isReadingChoicePreview {
                ProgressView(StorageTransferOverwriteCopy.comparisonReading)
                    .accessibilityIdentifier("storage-switch.keep-cloud-reading")
            }
            if let choicePreviewError {
                Text(choicePreviewError)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("storage-switch.keep-cloud-preview-error")
            }
            Button(StorageTransferEnableCopy.keepCloudTitle, role: .destructive) {
                // transfer-02. Never opens 「最後の確認」 on an assumption:
                // both sides are counted first, and a failed read keeps the
                // confirmation closed.
                loadPreviewThenConfirmChoice(.enableCloudKeepingCloud)
            }
            .disabled(isReadingChoicePreview)
            .accessibilityIdentifier("storage-switch.keep-cloud")
        }
        Section("このiPhoneのデータを残す") {
            Text("現在iCloudにあるPomoGemのテーマ・記録・設定を削除し、このiPhoneのデータに置き換えます。同じApple Accountの他の端末にも影響します。")
            Text(StorageTransferOverwriteCopy.doorUnavailable)
                .accessibilityIdentifier("storage-switch.replace-cloud-unavailable")
            Button("このiPhoneのデータで置き換える", role: .destructive) { choice = .enableCloudReplacingCloud }
                .disabled(!StorageTransferReleasePolicy.standard.allowsCloudReplacement)
                .accessibilityIdentifier("storage-switch.replace-cloud")
        }
        Section {
            Text("テーマ名・成果メモ・記録・設定・タイマーの整合用データが、あなたのApple AccountのプライベートiCloud領域に保存されます。")
        }
    }

    private func choiceConfirmation(_ selected: StorageTransferChoice) -> some View {
        let deletesThisDevice = selected == .enableCloudKeepingCloud
        var export: StorageTransferExportControl.Export?
        if deletesThisDevice { export = exportAction() }
        return StorageTransferConfirmationView(
            choice: selected,
            preview: deletesThisDevice ? choicePreview : nil,
            disclosesScreenTimeReset: disclosesScreenTimeReset,
            export: export
        ) { confirmed(selected) }
            .dynamicTypeSize(dynamicTypeSize)
    }

    private func datasetConfirmation(_ direction: StorageTransferDatasetRequestDirection) -> some View {
        var export: StorageTransferExportControl.Export?
        if direction == .refreshFromCloud { export = exportAction() }
        return StorageTransferDatasetConfirmationView(
            direction: direction,
            preview: datasetPreview,
            screenTimeDisclosure: disclosesScreenTimeReset ? StorageTransferScreenTimeCopy.switchResets : nil,
            export: export
        ) {
            confirmedDataset(direction)
        }
        .dynamicTypeSize(dynamicTypeSize)
    }

    /// PLAN Steps 11-12. The two directional dataset doors, the one a
    /// shipping build can open first. `storage-switch.replace-cloud` — the legacy
    /// `localOnly -> cloud` replacement — is untouched and still keyed off its
    /// own, separate bit in the enable branch below.
    @ViewBuilder
    private var datasetDoors: some View {
        if offersDatasetDoors {
            // transfer-08. The door this build can actually open comes first.
            // Direction (B) carries NO release bit (PLAN Step 12). It deletes
            // nothing on the server and is the same operation the recovery
            // screen runs unconditionally; gating it on the opposite,
            // destructive direction's bit would ship the one thing a user with
            // a diverged device always needs as a permanently greyed-out row.
            Section(StorageTransferRefreshCopy.settingsTitle) {
                Text(StorageTransferRefreshCopy.dataLossWarning)
                if isReading(.refreshFromCloud) {
                    ProgressView(StorageTransferOverwriteCopy.comparisonReading)
                        .accessibilityIdentifier("storage-switch.refresh-from-cloud-reading")
                }
                if let error = previewError(for: .refreshFromCloud) {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("storage-switch.refresh-from-cloud-preview-error")
                }
                Button(StorageTransferRefreshCopy.confirmTitle, role: .destructive) {
                    // review-1-2 / review-2-4. The same read-only enumeration
                    // direction (A) already performs. This direction deletes
                    // the device side and stages no recovery copy anywhere, so
                    // the user may not be asked to authorize it without being
                    // shown what is on each side.
                    loadPreviewThenConfirm(.refreshFromCloud)
                }
                .disabled(isReadingDatasetPreview)
                .accessibilityIdentifier("storage-switch.refresh-from-cloud")
            }
            Section("このiPhoneのデータでiCloudを置き換える") {
                // transfer-08. The long irreversible-deletion warning belongs to
                // a door that can open. A closed door states only its reason.
                if releasePolicy.allowsDatasetOverwriteFromDevice {
                    Text(StorageTransferOverwriteCopy.dataLossWarning)
                } else {
                    Text(StorageTransferOverwriteCopy.doorUnavailable)
                        .accessibilityIdentifier("storage-switch.overwrite-cloud-unavailable")
                }
                if isReading(.overwriteCloudFromDevice) {
                    ProgressView(StorageTransferOverwriteCopy.comparisonReading)
                        .accessibilityIdentifier("storage-switch.overwrite-cloud-reading")
                }
                if let error = previewError(for: .overwriteCloudFromDevice) {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("storage-switch.overwrite-cloud-preview-error")
                }
                Button(StorageTransferOverwriteCopy.confirmTitle, role: .destructive) {
                    // Never acts on tap, and never opens 「最後の確認」 on an
                    // assumption: the read-only pre-flight runs FIRST, and the
                    // confirmation is presented only once it has enumerated
                    // what would be destroyed. The sheet's own acknowledgement
                    // starts unchecked on every presentation.
                    loadPreviewThenConfirm(.overwriteCloudFromDevice)
                }
                .disabled(!releasePolicy.allowsDatasetOverwriteFromDevice || isReadingDatasetPreview)
                .accessibilityIdentifier("storage-switch.overwrite-cloud")
            }
        }
    }

    /// A failed read closes the door with its own message. "We could not look"
    /// and "there is nothing there" must not be confusable before a deletion,
    /// so nothing is presented and nothing is armed. Each direction names the
    /// control the user would press again, because each carries its own.
    private func loadPreviewThenConfirm(_ direction: StorageTransferDatasetRequestDirection) {
        guard !isReadingDatasetPreview else { return }
        datasetPreview = nil
        datasetPreviewError = nil
        readingDirection = direction
        isReadingDatasetPreview = true
        Task { @MainActor in
            defer { isReadingDatasetPreview = false }
            do {
                datasetPreview = try await previewDataset()
                datasetDirection = direction
            } catch {
                datasetPreview = nil
                datasetPreviewError = direction == .overwriteCloudFromDevice
                    ? StorageTransferOverwriteCopy.settingsPreviewUnavailable
                    : StorageTransferRefreshCopy.settingsPreviewUnavailable
            }
        }
    }

    /// transfer-02. The local-only twin of `loadPreviewThenConfirm`.
    private func loadPreviewThenConfirmChoice(_ selected: StorageTransferChoice) {
        guard !isReadingChoicePreview else { return }
        choicePreview = nil
        choicePreviewError = nil
        isReadingChoicePreview = true
        Task { @MainActor in
            defer { isReadingChoicePreview = false }
            do {
                choicePreview = try await previewDataset()
                choice = selected
            } catch {
                choicePreview = nil
                choicePreviewError = StorageTransferEnableCopy.previewUnavailable
            }
        }
    }

    /// The ordinary Settings export of the mounted session, offered inside
    /// the confirmations that delete this device's side.
    private func exportAction() -> StorageTransferExportControl.Export {
        let context = modelContext
        return { try await StorageTransferExportControl.exportMountedSession(context) }
    }

    private func isReading(_ direction: StorageTransferDatasetRequestDirection) -> Bool {
        isReadingDatasetPreview && readingDirection == direction
    }

    private func previewError(for direction: StorageTransferDatasetRequestDirection) -> String? {
        guard readingDirection == direction, !isReadingDatasetPreview else { return nil }
        return datasetPreviewError
    }
}

extension StorageTransferChoice: Identifiable { var id: Self { self } }
extension StorageTransferDatasetRequestDirection: Identifiable { var id: Self { self } }

/// 「最後の確認」 for a directional dataset replacement. Everything the direction
/// will do, restated in full, with its own unchecked acknowledgement and its
/// own destructive action. A fresh instance is built for every presentation, so
/// 戻る discards the acknowledgement and no other confirmation in this screen
/// can ever arm this one (PLAN §3 S9). Shared with the launch host's
/// `.cloudLineageUnavailable` screen, so both surfaces quote one text.
struct StorageTransferDatasetConfirmationView: View {
    let direction: StorageTransferDatasetRequestDirection
    /// Non-nil for the device -> iCloud direction only, and non-nil is the
    /// precondition for presenting this view at all for that direction: the
    /// counts and the other-device evidence are what informed consent is
    /// consent TO (PLAN §3 S14/S15).
    var preview: StorageTransferDatasetPreviewSummary?
    /// transfer-07. What the switch resets in Screen Time, for the direction
    /// whose own copy does not already say so; nil when nothing needs saying.
    /// Settings passes the definite `switchResets` only while the feature is
    /// in use. The launch host, which has no Screen Time owner mounted and so
    /// cannot tell, passes the conditional `switchResetsIfInUse`.
    var screenTimeDisclosure: String?
    /// 「先にこの端末の記録を書き出す」, for the direction that deletes this
    /// device's side. nil where the surface carries its own export (the launch
    /// host) or where the deleted side is iCloud's.
    var export: StorageTransferExportControl.Export?
    let confirmed: () -> Void
    @Environment(\.dismiss) private var dismiss
    /// sync-04. nil on the launch host, which has no mounted session.
    @Environment(\.cloudKitMirroringActivity) private var mirroringActivity
    @State private var understandsDeletion = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    switch direction {
                    case .overwriteCloudFromDevice:
                        paragraph(StorageTransferOverwriteCopy.sheetWarning, suffix: "warning")
                        if preview?.hasCloudLineage == false {
                            // W6. There is no lineage to replace, so the
                            // sentence above is not the whole truth: this
                            // direction STARTS one. Said before the toggle.
                            paragraph(StorageTransferLineageCopy.settingsStartsLineage,
                                      suffix: "starts-lineage")
                        }
                        // The same two facts the launch screen requires before
                        // it arms its door: what is on each side, and whether
                        // another device has written here.
                        paragraph(comparison, suffix: "comparison")
                        paragraph(otherDeviceEvidence, suffix: "other-devices")
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
                        if mirroringActivity?.state.mayHaveUnsentChanges == true {
                            // sync-04. This direction deletes this iPhone's
                            // side, and its recent exports did not succeed.
                            paragraph(CloudKitMirroringCopy.unsentWarning(
                                exportButtonTitle: export == nil ? nil : StorageTransferOverwriteCopy.exportTitle
                            ), suffix: "unsent")
                        }
                        // review-1-2 / review-2-4. 「iCloudのデータは残ります」
                        // says nothing about how much there is. W6 opened this
                        // direction to accounts with no ledger, which are the
                        // ones most likely to have nothing on the server, and
                        // `retireSource` removes the device's only copy.
                        paragraph(comparison, suffix: "comparison")
                        if StorageTransferRefreshCopy.cloudSideIsEmpty(preview?.cloud) {
                            // transfer-03. Decided on the user's own records, and
                            // names what THIS iPhone holds, because that is the
                            // side the direction deletes.
                            paragraph(StorageTransferRefreshCopy.cloudSideEmpty(device: preview?.device),
                                      suffix: "empty-cloud")
                        }
                        if let export {
                            StorageTransferExportControl(identifier: identifier("export"), export: export)
                        }
                        if let screenTimeDisclosure {
                            paragraph(screenTimeDisclosure, suffix: "screen-time")
                        }
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

    /// 「このiPhone: …／iCloud: …」, rendered by the same function as the launch
    /// screen so the two surfaces cannot disagree about the same dataset.
    private var comparison: String {
        let cloud = preview?.hasCloudLineage == false
            ? StorageTransferOverwriteCopy.cloudSideWithoutLineage(preview: preview?.cloud)
            : StorageTransferOverwriteCopy.side("iCloud", preview: preview?.cloud)
        // The device side is best effort. When the host could not read this
        // iPhone the refresh row is omitted rather than rendered as
        // 「確認できませんでした」, which would claim a look that failed as if
        // it were evidence; the overwrite direction always shows both rows.
        guard preview?.device != nil || direction == .overwriteCloudFromDevice else { return cloud }
        return StorageTransferOverwriteCopy.side("このiPhone", preview: preview?.device)
            + "\n" + cloud
    }

    /// A missing preview is disclosed as a missing preview. Rendering 「見つかり
    /// ませんでした」 without having read anything would be a false witness on the
    /// last screen before a deletion. This view is not presented for the
    /// overwrite direction without one; the fallback exists so it cannot
    /// become one by accident later.
    private var otherDeviceEvidence: String {
        guard let preview else { return StorageTransferOverwriteCopy.otherDevicesUnknown }
        return StorageTransferOverwriteCopy.otherDevices(preview.cloud.otherDeviceIDs)
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
    /// transfer-02. Present for 「iCloudのデータを使う」, which is never offered
    /// without it: the counts are what the acknowledgement is consent TO.
    var preview: StorageTransferDatasetPreviewSummary?
    var disclosesScreenTimeReset = false
    var export: StorageTransferExportControl.Export?
    let confirmed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var understandsDeletion = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(message)
                    if let preview {
                        // The device side is the one deleted, so it comes first.
                        // The iCloud side carries counts only: its newest
                        // mirrored timestamp may be a Prefs stamp.
                        Text(StorageTransferOverwriteCopy.side("このiPhone", preview: preview.device)
                             + "\n" + StorageTransferOverwriteCopy.countsOnly("iCloud", preview: preview.cloud))
                            .accessibilityIdentifier("storage-switch.keep-cloud-comparison")
                        if StorageTransferRefreshCopy.cloudSideIsEmpty(preview.cloud) {
                            Text(StorageTransferEnableCopy.cloudSideEmpty(device: preview.device))
                                .accessibilityIdentifier("storage-switch.keep-cloud-empty-cloud")
                        }
                    }
                    if let export {
                        StorageTransferExportControl(identifier: "storage-switch.export", export: export)
                    }
                    if disclosesScreenTimeReset {
                        // transfer-07. Every choice here moves to another
                        // storage namespace, including the non-destructive one.
                        Text(StorageTransferScreenTimeCopy.switchResets)
                            .accessibilityIdentifier("storage-switch.screen-time")
                    }
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
