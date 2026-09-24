import Observation
import SwiftData
import SwiftUI
import UIKit

enum NotificationPreference: Hashable {
    case dailyReminder
    case wrapped
    case focusReturnReminder
}

/// Authorization may outlive a later toggle. Keep independent user intents
/// for each setting so a delayed permission result cannot restore an old
/// value or cancel an update to a different reminder.
@MainActor
final class NotificationPreferenceIntentGate {
    private var intents: [NotificationPreference: UUID] = [:]

    func begin(_ preference: NotificationPreference) -> UUID {
        let intent = UUID()
        intents[preference] = intent
        return intent
    }

    func isCurrent(_ preference: NotificationPreference, intent: UUID) -> Bool {
        !Task.isCancelled && intents[preference] == intent
    }

    /// Nil means a newer update or task cancellation superseded this request.
    func authorizeUpdate(
        _ preference: NotificationPreference,
        intent: UUID,
        enabled: Bool,
        refreshAuthorization: () async -> Bool,
        requestAuthorization: () async -> Bool
    ) async -> Bool? {
        guard isCurrent(preference, intent: intent) else { return nil }
        guard enabled else { return true }
        let alreadyAuthorized = await refreshAuthorization()
        guard isCurrent(preference, intent: intent) else { return nil }
        guard !alreadyAuthorized else { return true }
        let granted = await requestAuthorization()
        guard isCurrent(preference, intent: intent) else { return nil }
        return granted
    }
}

struct SettingsView: View {
    let persistenceMode: PersistenceLaunchMode

    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    @Environment(CompleteDataDeletionController.self) private var completeDeletion
    @Environment(StorageTransferController.self) private var storageTransfer
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isCloudOfflineSession) private var isCloudOfflineSession
    @Query private var storedSubjects: [Subject]
    @Query private var preferences: [Prefs]
    @Query private var activityResetMarkers: [ActivityResetMarker]

    @AppStorage(AccountScopedLocalState.defaultsKey(base: "notifications.wrapped"))
    private var wrappedNotifications = false
    @AppStorage(FocusActivityPreference.enabledDefaultsKey)
    private var liveActivityEnabled = true
    @AppStorage(FocusReturnReminderPolicy.enabledDefaultsKey)
    private var focusReturnReminderEnabled = false
    @AppStorage(TimerOrientationPreference.defaultsKey)
    private var defaultTimerOrientationRawValue = TimerDefaultOrientation.automatic.rawValue
    @State private var purchase = PurchaseManager.shared
    @State private var isSubjectEditorPresented = false
    @State private var editingSubjectID: UUID?
    @State private var subjectPendingDeletion: Subject?
    @State private var subjectPendingDeletionRecordCount: Int?
    @State private var showResetData = false
    @State private var showFontLicense = false
    @State private var showCustomDuration = false
    @State private var notificationError: String?
    @State private var notificationPreferenceIntents =
        NotificationPreferenceIntentGate()
    @State private var viewTasks = ViewTaskScope()
    @State private var resetCleanupJournal = ActivityResetCleanupJournal.live()
    @State private var settingsError: String?
    @State private var dataExportTask: Task<Void, Never>?
    @State private var activeDataExportID: UUID?
    @State private var dataExportProgress: PomoGemDataExportProgress?
    @State private var dataExportFileURL: URL?
    @State private var isExportingData = false
    @State private var showDataExportShareSheet = false
    @State private var dataExportError: String?
    @State private var showCompleteDeletionConfirmation = false
    @State private var booleanSettingsCommitGeneration = 0
    @State private var completionPreview = TimerCompletionPreviewController()
#if DEBUG
    @State private var lastBooleanSettingsCommitMilliseconds = -1
    @State private var lastBooleanSettingsCommitSucceeded = false
#endif

    private var resolvedPreferences: PrefsSyncPolicy.ResolvedState? {
        _ = booleanSettingsCommitGeneration
        return PrefsConsumerPolicy.resolvedState(
            in: preferences,
            markers: resetSnapshots
        )
    }
    private var sensoryPreferences: PrefsSyncPolicy.ResolvedSensoryState {
        _ = booleanSettingsCommitGeneration
        return PrefsConsumerPolicy.resolvedSensoryState(in: preferences)
    }
    private var resetSnapshots: [ActivityResetSnapshot] {
        activityResetMarkers.map(\.policySnapshot)
    }
    private var subjects: [Subject] {
        SubjectSyncPolicy.presentationSubjects(from: storedSubjects)
    }
    private func isCurrentActivity(_ epochID: UUID?) -> Bool {
        ActivityResetPolicy.isCurrent(epochID, markers: resetSnapshots)
    }

    init(persistenceMode: PersistenceLaunchMode = .inMemoryPreview) {
        self.persistenceMode = persistenceMode
        var subjectDescriptor = FetchDescriptor<Subject>(sortBy: [
            SortDescriptor(\Subject.sortOrder),
            SortDescriptor(\Subject.createdAt),
            SortDescriptor(\Subject.id)
        ])
        subjectDescriptor.fetchLimit = SubjectSyncPolicy.maximumPhysicalRows + 1
        _storedSubjects = Query(subjectDescriptor)

        _preferences = Query(PrefsConsumerPolicy.descriptor())

        _activityResetMarkers = Query(ActivityResetPolicy.currentMarkerDescriptor())
    }

    var body: some View {
        List {
            subjectsSection
            focusSection
            screenTimeSection
            if RareRewardReleasePolicy.isEnabled {
                rarePebbleSection
            }
            sensorySection
            CloudSyncSettingsSection(persistenceMode: persistenceMode)
            StorageTransferSettingsSection(
                persistenceMode: persistenceMode,
                controller: storageTransfer,
                otherWorkIsActive: isCloudOfflineSession || isExportingData || completeDeletion.hasStarted
                    || router.focusPresentationIsActive || router.recoveredFocus != nil
                    || router.deferredFocusRecovery != nil || router.recoveredBreak != nil
                    || router.cloudFocusRecoveryOffer != nil,
                disclosesScreenTimeReset: screenTimeIsInUse
            )
            notificationSection
            shareSection
            proSection
            privacySection
            creditsSection
            dataSection
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground())
        .pomogemNavigationTitle("設定")
        .toolbarTitleDisplayMode(.large)
        .sheet(isPresented: $isSubjectEditorPresented, onDismiss: {
            editingSubjectID = nil
        }) {
            if let editingSubjectID,
               let subject = subjects.first(where: { $0.id == editingSubjectID }) {
                SubjectEditorView(
                    subject: subject,
                    suggestedColorHex: subject.colorHex
                ) { name, color, isArchived in
                    saveSubjectEdits(
                        subject: subject,
                        name: name,
                        color: color,
                        isArchived: isArchived
                    )
                }
            } else {
                SubjectEditorView(
                    subject: nil,
                    suggestedColorHex: nextSubjectColor,
                    onSave: addSubject
                )
            }
        }
        .sheet(isPresented: $showCustomDuration) {
            CustomDurationView(
                initialSeconds: resolvedPreferences?.preferredFocusSeconds
                    ?? Constants.Timer.twentyFiveMinutes * Constants.Timer.secondsPerMinute,
                onConfirm: confirmPreferredFocusSeconds
            )
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showFontLicense) {
            FontLicenseView()
        }
        .sheet(isPresented: $showDataExportShareSheet, onDismiss: {
            removePresentedDataExport()
        }) {
            if let dataExportFileURL {
                PomoGemDataExportShareSheet(fileURL: dataExportFileURL) { error in
                    if let error {
                        dataExportError = "書き出したファイルを共有できませんでした。\n\(error.localizedDescription)"
                    }
                    showDataExportShareSheet = false
                }
            }
        }
        .sheet(isPresented: $showCompleteDeletionConfirmation) {
            CompleteDataDeletionConfirmationView {
                showCompleteDeletionConfirmation = false
                completeDeletion.startOrRetry()
            }
        }
        .alert(
            "テーマを削除",
            isPresented: Binding(
                get: { subjectPendingDeletion != nil },
                set: {
                    if !$0 {
                        subjectPendingDeletion = nil
                        subjectPendingDeletionRecordCount = nil
                    }
                }
            ),
            presenting: subjectPendingDeletion
        ) { subject in
            Button("「\(subject.safeDisplayName)」を削除", role: .destructive) {
                subjectPendingDeletion = nil
                subjectPendingDeletionRecordCount = nil
                deleteSubject(subject)
            }
            Button("キャンセル", role: .cancel) {
                subjectPendingDeletion = nil
                subjectPendingDeletionRecordCount = nil
            }
        } message: { subject in
            Text(subjectDeletionMessage(
                for: subject,
                recordCount: subjectPendingDeletionRecordCount ?? 0
            ))
        }
        .alert("表示中の記録をリセット", isPresented: $showResetData) {
            Button("キャンセル", role: .cancel) {}
            Button("リセット", role: .destructive) { resetStudyData() }
        } message: {
            Text(resetDataMessage)
        }
        .alert("通知を設定できませんでした", isPresented: Binding(
            get: { notificationError != nil },
            set: { if !$0 { notificationError = nil } }
        )) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(notificationError ?? "")
        }
        .alert("設定を完了できませんでした", isPresented: Binding(
            get: { settingsError != nil },
            set: { if !$0 { settingsError = nil } }
        )) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(settingsError ?? "")
        }
        .alert("データを書き出せませんでした", isPresented: Binding(
            get: { dataExportError != nil },
            set: { if !$0 { dataExportError = nil } }
        )) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(dataExportError ?? "")
        }
#if DEBUG
        .overlay(alignment: .topLeading) {
            if LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess {
                Text("Settings render audit probe")
                    .font(.system(size: 1))
                    .foregroundStyle(Color.clear)
                    .frame(width: 1, height: 1)
                    .accessibilityIdentifier("settings.render-audit.probe")
                    .accessibilityLabel("Settings render audit probe")
                    .accessibilityValue(Text(verbatim:
                        (router.settingsRenderAuditValue ?? "state=waiting")
                            + ";commitGeneration=\(booleanSettingsCommitGeneration)"
                            + ";commitMilliseconds=\(lastBooleanSettingsCommitMilliseconds)"
                            + ";commitSucceeded=\(lastBooleanSettingsCommitSucceeded)"
                    ))
                    .allowsHitTesting(false)
                    .onAppear {
                        router.completeSettingsRenderAudit(
                            subjectCount: subjects.count,
                            preferenceCount: preferences.count,
                            resetMarkerCount: activityResetMarkers.count
                        )
                    }
            }
        }
#endif
        .onAppear { viewTasks.activate() }
        .task {
            await refreshViewServices()
            guard !Task.isCancelled else { return }
            await removeStaleDataExports()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                completionPreview.cancel()
                return
            }
            viewTasks.start {
                await refreshViewServices()
            }
        }
        .onChange(of: completionPreviewConfiguration) { _, _ in
            completionPreview.cancel()
        }
        .onDisappear {
            viewTasks.cancelAll()
            completionPreview.cancel()
            guard !showDataExportShareSheet else { return }
            cancelDataExport(announce: false)
            removePresentedDataExport()
        }
    }

    private var rareRewardMode: RareRewardMode {
        PrefsConsumerPolicy.rareRewardMode(from: resolvedPreferences)
    }

    private var hasExplicitRareRewardSelection: Bool {
        PrefsConsumerPolicy.hasExplicitRareRewardSelection(
            in: resolvedPreferences
        )
    }

    private var rareRewardModeBinding: Binding<RareRewardMode> {
        Binding(
            get: { rareRewardMode },
            set: { updateRareRewardMode($0) }
        )
    }

    private func updateRareRewardMode(_ mode: RareRewardMode) {
        guard mode != rareRewardMode || !hasExplicitRareRewardSelection else { return }
        guard resolvedPreferences != nil else {
            settingsError = "ランダムなレア粒の設定を\(storageDestination)へ保存できませんでした。しばらく待ってから、もう一度お試しください。"
            return
        }

        let changedAt = Date.now
        do {
            try PrefsConsumerPolicy.mutate(
                .rareReward,
                context: modelContext,
                markers: resetSnapshots
            ) {
                $0.rareRewardModeRawValue = mode.rawValue
                $0.rareRewardModeUpdatedAt = changedAt
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            settingsError = "ランダムなレア粒の設定を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)"
        }
    }

    private var subjectsSection: some View {
        Section {
            ForEach(Array(subjects.enumerated()), id: \.element.id) { index, subject in
                Button {
                    editingSubjectID = subject.id
                    isSubjectEditorPresented = true
                } label: {
                    HStack(spacing: 13) {
                        ZStack {
                            Circle().fill(Color(hex: subject.colorHex)).frame(width: 15, height: 15)
                            if subject.isArchived {
                                Circle().stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 21, height: 21)
                            }
                        }
                        Text(subject.safeDisplayName)
                            .foregroundStyle(subject.isArchived ? PomoGemTheme.muted : PomoGemTheme.text)
                        Spacer()
                        if subject.isArchived {
                            Text("非表示").font(.caption).foregroundStyle(PomoGemTheme.muted)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(PomoGemTheme.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PomoGemRowButtonStyle())
                .accessibilityHint(
                    subjects.count > 1
                        ? "ダブルタップで編集。アクションで順番を変更できます"
                        : "ダブルタップで編集できます"
                )
                .modifier(
                    SubjectReorderAccessibilityModifier(
                        index: index,
                        count: subjects.count,
                        moveUp: { moveSubject(at: index, direction: .up) },
                        moveDown: { moveSubject(at: index, direction: .down) }
                    )
                )
                .swipeActions(edge: .leading) {
                    Button(subject.isArchived ? "表示" : "非表示") {
                        do {
                            subject.isArchived.toggle()
                            try SubjectSyncPolicy.recordUserMutation(
                                from: subject,
                                among: storedSubjects
                            )
                            try modelContext.save()
                        } catch {
                            modelContext.rollback()
                            settingsError = "テーマの表示設定を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)"
                        }
                    }
                    .tint(PomoGemTheme.raised)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("削除", role: .destructive) {
                        prepareSubjectDeletion(subject)
                    }
                }
            }
            .onMove(perform: moveSubjects)

            Button {
                editingSubjectID = nil
                isSubjectEditorPresented = true
            } label: {
                Label("テーマを追加", systemImage: "plus")
            }
            .disabled(subjects.count >= Constants.App.maximumSubjects)
            .accessibilityHint(
                subjects.count >= Constants.App.maximumSubjects
                    ? "最大12件です。不要な項目を削除すると追加できます"
                    : "新しいテーマを追加します"
            )
        } header: {
            Text("テーマ")
        } footer: {
            Text("勉強も仕事も同じ一覧です。最大12件。追加画面には名前のヒントがあります。削除しても過去の質量と記録は残ります。長押しで順番を変更できます。")
        }
    }

    private var focusSection: some View {
        Section("集中") {
            Toggle(isOn: $liveActivityEnabled) {
                SettingLabel(
                    title: "画面を閉じてもタイマーを表示",
                    subtitle: "ロック画面とDynamic Islandに残り時間・進捗を表示",
                    symbol: "lock.display"
                )
            }
            .accessibilityIdentifier("settings.live-activity")
            .onChange(of: liveActivityEnabled) { _, enabled in
                Task { @MainActor in
                    if enabled {
                        FocusActivityManager.shared.refreshAuthorization()
                    } else {
                        await FocusActivityManager.shared.endAll()
                    }
                }
            }

            Text("タイマーはバックグラウンドでも止まりません。iPhoneの設定でライブアクティビティが許可されている場合に表示します。")
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)

            Toggle(isOn: Binding(
                get: { focusReturnReminderEnabled },
                set: { updateFocusReturnReminder(enabled: $0) }
            )) {
                SettingLabel(
                    title: "集中に戻るお知らせ",
                    subtitle: "アプリを離れて30秒後に一度通知",
                    symbol: "bell.badge"
                )
            }
            .accessibilityIdentifier("settings.focus-return-reminder")

            Text("既定はオフ。集中タイマー中だけ通知し、戻ると取り消します。一時停止中・休憩中・終了間際は通知しません。画面をロックした場合も通知されます。")
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)

            if let resolvedPreferences {
                NavigationLink {
                    TimerDisplayModeSelectionView(selection: timerDisplayModeBinding)
                } label: {
                    SettingLabel(
                        title: "集中タイマーの表示",
                        subtitle: resolvedPreferences.timerDisplayMode.title,
                        symbol: "circle.dotted"
                    )
                }
                .accessibilityIdentifier("settings.timer-display-mode")
                .accessibilityHint("4つの見本から、タイマーの見た目を選べます")

                Toggle(isOn: settingBinding(
                    .keepScreenAwake,
                    currentValue: resolvedPreferences.keepScreenAwake,
                    update: { $0.keepScreenAwake = $1 }
                )) {
                    SettingLabel(
                        title: "タイマー中は画面をロックしない",
                        subtitle: "集中・休憩のタイマー画面を開いている間だけ有効",
                        symbol: "sun.max"
                    )
                }
                .accessibilityIdentifier("settings.keep-screen-awake")
            }
            NavigationLink {
                TimerDefaultOrientationSettingsView(selection: Binding(
                    get: { TimerDefaultOrientation(rawValue: defaultTimerOrientationRawValue) ?? .automatic },
                    set: { defaultTimerOrientationRawValue = $0.rawValue }
                ))
            } label: {
                SettingLabel(
                    title: "タイマーの既定の向き",
                    subtitle: (TimerDefaultOrientation(rawValue: defaultTimerOrientationRawValue) ?? .automatic).title,
                    symbol: "rotate.right"
                )
            }
            .accessibilityIdentifier("settings.timer-default-orientation")
            .accessibilityHint("新しい集中・休憩タイマーを開く向きを選べます")

            if let resolvedPreferences {
                PreferredFocusDurationPicker(
                    preferredSeconds: resolvedPreferences.preferredFocusSeconds,
                    isPro: purchase.isPro,
                    onSelectPreset: { duration in
                        _ = savePreferredFocusSeconds(duration.seconds)
                    },
                    onCustomDuration: {
                        if purchase.isPro {
                            showCustomDuration = true
                        } else {
                            router.presentPaywall(from: .customTimer)
                        }
                    }
                )
            }
        }
    }

    private var sensorySection: some View {
        Section {
            Toggle(isOn: settingBinding(
                .sound,
                currentValue: sensoryPreferences.soundOn,
                update: { $0.soundOn = $1 },
                onCommitted: { value in
                    completionPreview.cancel()
                    SoundSynth.shared.isEnabled = value
                    synchronizeNotifications()
                }
            )) {
                SettingLabel(title: "音", subtitle: "サイレントスイッチに従います", symbol: "speaker.wave.2")
            }

            Picker(selection: timerCompletionSoundBinding) {
                ForEach(TimerCompletionSound.allCases) { style in
                    Text(style.title)
                        .tag(style)
                        .accessibilityLabel("\(style.title)。\(style.detail)")
                        .accessibilityIdentifier(
                            "settings.completion-sound.\(style.rawValue)"
                        )
                }
            } label: {
                SettingLabel(
                    title: "タイマー終了音",
                    subtitle: sensoryPreferences.timerCompletionSound.detail,
                    symbol: sensoryPreferences.timerCompletionSound.systemImage
                )
            }
            .pickerStyle(.navigationLink)
            .disabled(!sensoryPreferences.soundOn)
            .accessibilityIdentifier("settings.completion-sound")

            Toggle(isOn: settingBinding(
                .haptics,
                currentValue: sensoryPreferences.hapticsOn,
                update: { $0.hapticsOn = $1 },
                onCommitted: {
                    completionPreview.cancel()
                    Haptics.shared.isEnabled = $0
                }
            )) {
                SettingLabel(
                    title: "触覚",
                    subtitle: RareRewardReleasePolicy.isEnabled
                        ? "アプリ内の完了・着地・瓶操作。レア専用は標準モードのみ"
                        : "アプリ内の完了・着地・瓶操作に使います",
                    symbol: "waveform"
                )
            }

            Picker(selection: timerCompletionHapticBinding) {
                ForEach(TimerCompletionHaptic.allCases) { style in
                    Text(style.title)
                        .tag(style)
                        .accessibilityLabel("\(style.title)。\(style.detail)")
                        .accessibilityIdentifier(
                            "settings.completion-haptic.\(style.rawValue)"
                        )
                }
            } label: {
                SettingLabel(
                    title: "タイマー終了時の触覚",
                    subtitle: sensoryPreferences.timerCompletionHaptic.detail,
                    symbol: sensoryPreferences.timerCompletionHaptic.systemImage
                )
            }
            .pickerStyle(.navigationLink)
            .disabled(!sensoryPreferences.hapticsOn)
            .accessibilityIdentifier("settings.completion-haptic")

            TimerCompletionPreviewRow(
                controller: completionPreview,
                configuration: completionPreviewConfiguration
            )
            .disabled(completionPreviewConfiguration.isSilent)
        } header: {
            Text("音と触覚")
        } footer: {
            Text("アプリが前面にある間は、終了音と触覚を停止操作まで繰り返します。音はサイレントモードに従います。通知を許可している場合、ロック中は1回の通知となり、音と触覚はiPhoneの通知設定に従います。")
        }
    }

    private var rarePebbleSection: some View {
        Section {
            Text("粒のバリエーション")
                .font(.headline.weight(.black))
                .foregroundStyle(Color.white)
                .textCase(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black)
                .accessibilityAddTraits(.isHeader)
                .listRowBackground(Color.black)
                .listRowSeparator(.hidden)

            Picker(selection: rareRewardModeBinding) {
                ForEach(RareRewardMode.choiceOrder) { mode in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.title)
                        Text(mode.settingsDescription)
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                    .tag(mode)
                }
            } label: {
                SettingLabel(
                    title: "ランダムなレア粒",
                    subtitle: hasExplicitRareRewardSelection
                        ? rareRewardMode.settingsDescription
                        : "未選択のため抽選しません。最初の実測タイマー前にも選べます",
                    symbol: rareRewardMode.systemImage
                )
            }
            .pickerStyle(.navigationLink)
            .disabled(resolvedPreferences == nil)
            .accessibilityIdentifier("settings.rare-reward-mode")
            .accessibilityHint("質量、融合、結晶、成果、機能は変わりません。オフでは抽選用の端数と金の保証カウントを停止します")

            if !hasExplicitRareRewardSelection {
                Button {
                    updateRareRewardMode(.off)
                } label: {
                    Label("「抽選しない」を選択として保存", systemImage: "checkmark.shield.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(PomoGemBareButtonStyle())
                .foregroundStyle(PomoGemTheme.amber)
                .disabled(resolvedPreferences == nil)
                .accessibilityHint("乱数、抽選用の端数、金の保証カウントを動かさない選択を\(storageDestination)へ保存します")
                .accessibilityIdentifier("settings.rare-reward-confirm-off")
            }

            RarePebbleGuideRow(
                kind: .normal,
                title: "いつもの粒",
                detail: "全モードで同じ質量・結晶進捗"
            )
            RarePebbleGuideRow(
                kind: .gold,
                title: "金の粒",
                detail: rareRewardMode == .off
                    ? "オフ中は新しく抽選しません"
                    : "自然抽選 \(GachaEngine.probabilityLabel(for: .gold))。\(Constants.Gacha.pityMissCount)回続けて出なければ、次の抽選で保証"
            )
            RarePebbleGuideRow(
                kind: .prism,
                title: "虹の粒",
                detail: rareRewardMode == .off
                    ? "オフ中は新しく抽選しません"
                    : "自然抽選 \(GachaEngine.probabilityLabel(for: .prism))"
            )
        } footer: {
            Text(
                "自然確率は、いつもの粒 \(GachaEngine.probabilityLabel(for: .normal))、金 \(GachaEngine.probabilityLabel(for: .gold))、虹 \(GachaEngine.probabilityLabel(for: .prism))。標準と控えめでは、実測タイマーで250g積むごとに1回抽選し、250g未満の端数は次回へ繰り越します。10分を6回、25分を2回と10分を1回、60分を1回はいずれも600gなので、抽選2回と100gの端数で同じです。\(GachaEngine.goldGuaranteeDisclosure) 控えめは種類を履歴に残しますが、追加の発光・専用音・専用触覚を使いません。抽選しない間は乱数を使わず、その間の質量を抽選用に貯めません。既存の端数と金の保証は同じ位置で停止し、標準または控えめに戻すとそこから再開します。どのモードでも質量・融合・結晶・成果・機能は同じで、既に獲得した金・虹、記録、シェアも変わりません。端末の「視差効果を減らす」は抽選を止めず、動きだけを抑えます。"
            )
        }
    }

    private var notificationSection: some View {
        Section {
            if let resolvedPreferences {
                Toggle(isOn: Binding(
                    get: { resolvedPreferences.reminderEnabled },
                    set: { enabled in updateReminder(enabled: enabled) }
                )) {
                    SettingLabel(title: "毎日のリマインダ", subtitle: Constants.UIStrings.eveningNotification, symbol: "bell")
                }

                if resolvedPreferences.reminderEnabled {
                    DatePicker(
                        "通知する時刻",
                        selection: reminderTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                }

                Toggle(isOn: Binding(
                    get: { wrappedNotifications },
                    set: { enabled in updateWrappedNotification(enabled: enabled) }
                )) {
                    SettingLabel(title: "今月の積み重ね", subtitle: "毎月1日に一度だけ", symbol: "circle.grid.3x3.fill")
                }
            }
        } header: {
            Text("通知")
        } footer: {
            Text("既定はオフ。赤いバッジや連続記録の警告は使いません。")
        }
    }

    private var shareSection: some View {
        Section("シェア") {
            if let resolvedPreferences {
                Toggle(isOn: settingBinding(
                    .shareIncludesManual,
                    currentValue: resolvedPreferences.shareIncludesManual,
                    update: { $0.shareIncludesManual = $1 }
                )) {
                    SettingLabel(title: "自己申告を含める", subtitle: "既定は実測のみ", symbol: "square.and.arrow.up")
                }
            }
        }
    }

    private var screenTimeSection: some View {
        Section("アプリの利用時間") {
            NavigationLink {
                ScreenTimeSettingsView()
            } label: {
                SettingLabel(
                    title: "スクリーンタイム",
                    subtitle: "10分ごとに勉強のgem・黒いgemを積む",
                    symbol: "hourglass"
                )
            }
            .accessibilityIdentifier("settings.screen-time")
        }
    }

    private var proSection: some View {
        Section {
            Button {
                router.presentPaywall(from: .settings)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: purchase.isPro ? "checkmark.seal.fill" : "sparkles")
                        .foregroundStyle(PomoGemTheme.amber)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Constants.UIStrings.paywallTitle).font(.headline)
                        Text(purchase.isPro ? "利用中" : "任意時間・月刻印・勉強アプリ数の無制限")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(PomoGemTheme.muted)
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(PomoGemBareButtonStyle())
        }
    }

    private var privacySection: some View {
        Section("サポートとプライバシー") {
            if persistenceMode == .localOnly {
                SettingLabel(
                    title: "このiPhoneのみ",
                    subtitle: "このiPhoneの専用領域",
                    symbol: "iphone"
                )
            } else {
                SettingLabel(
                    title: "iCloud",
                    subtitle: "あなたのプライベートデータベースのみ",
                    symbol: "icloud"
                )
            }
            Link(destination: AppLinks.support) {
                SettingLabel(title: "サポート・お問い合わせ", subtitle: "Webで開く", symbol: "questionmark.circle")
            }
            Link(destination: AppLinks.privacyPolicy) {
                SettingLabel(title: "プライバシーポリシー", subtitle: "Webで開く", symbol: "doc.text")
            }
        }
    }

    private var creditsSection: some View {
        Section("クレジット") {
            LabeledContent("バージョン", value: appVersionLabel)
            LabeledContent("著作権", value: "© 2026 hinoshiba")
            LabeledContent("見出し書体", value: "Zen Maru Gothic")
            Button("SIL Open Font License 1.1を読む") {
                showFontLicense = true
            }
            Link(destination: AppLinks.sourceCode) {
                SettingLabel(
                    title: "ソースコードとライセンス",
                    subtitle: "MIT License・GitHub",
                    symbol: "chevron.left.forwardslash.chevron.right"
                )
            }
        }
    }

    /// transfer-07. Whether a storage switch would reset anything the user
    /// set up in Screen Time: the feature is on or monitoring, or black gems
    /// are still held on this iPhone.
    private var screenTimeIsInUse: Bool {
        let screenTime = ScreenTimeController.shared
        return screenTime.configuration.enabled || screenTime.isMonitoring
            || screenTime.negativeGemCount > 0
    }

    private var appVersionLabel: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String

        guard let build, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }

    private var dataSection: some View {
        Section {
            Button(action: startDataExport) {
                HStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(PomoGemTheme.specular)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("データを書き出す")
                            .font(.headline)
                        Text(isExportingData ? "JSONファイルを作成中" : "全記録をJSONで保存・共有")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                    Spacer()
                    if isExportingData {
                        ProgressView()
                            .tint(PomoGemTheme.specular)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(PomoGemBareButtonStyle())
            .disabled(isExportingData)
            .accessibilityLabel("データを書き出す")
            .accessibilityHint("この端末で利用可能な記録、テーマ、設定をJSONファイルにして、保存先を選びます")

            if isExportingData, let dataExportProgress {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: dataExportProgress.fractionCompleted)
                        .tint(PomoGemTheme.specular)
                    Text(dataExportProgress.accessibilityDescription)
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(dataExportProgress.accessibilityDescription)

                Button("書き出しをキャンセル", role: .cancel) {
                    cancelDataExport(announce: true)
                }
            }

            Button("表示中の記録をリセット", role: .destructive) { showResetData = true }
                .disabled(!ActivityResetAdmissionPolicy.permitsUserReset(in: persistenceMode))
                .accessibilityIdentifier("settings.activity-reset")

            if !ActivityResetAdmissionPolicy.permitsUserReset(in: persistenceMode) {
                Text(ActivityResetAdmissionPolicy.cloudResetUnavailableMessage)
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .accessibilityIdentifier("settings.activity-reset-unavailable")
            }

            // settings-03 / transfer-09. The disabled reset used to be a dead
            // end: its only next step hid in the footer. The routes that do
            // work — switch this iPhone to local-only and reset, or delete the
            // iCloud data in iOS Settings — get their own row.
            if ActivityResetAdmissionPolicy.offersCloudDeletionGuidance(in: persistenceMode) {
                NavigationLink {
                    CloudDataDeletionGuidanceView(isExporting: isExportingData, export: startDataExport)
                } label: {
                    Text(CloudDataDeletionGuidanceCopy.rowTitle)
                        .frame(minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("settings.activity-reset-alternatives")
            }

            if CompleteDataDeletionReleasePolicy.isEnabled,
               persistenceMode != .localOnly {
                Button(role: .destructive) {
                    showCompleteDeletionConfirmation = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "trash.slash.fill")
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("ユーザー内容を削除")
                                .font(.headline)
                            Text("端末とiCloudの内容（削除世代記録を除く）")
                                .font(.caption)
                                .foregroundStyle(PomoGemTheme.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(PomoGemBareButtonStyle())
                .disabled(isExportingData || completeDeletion.hasStarted)
                .accessibilityHint("二段階の確認画面を開きます。この操作は取り消せません")
            }

            if persistenceMode != .localOnly,
               case let .failed(phase, message) = completeDeletion.status {
                VStack(alignment: .leading, spacing: 8) {
                    Label("削除は未完了です", systemImage: "exclamationmark.icloud")
                        .font(.headline)
                    if let phase {
                        Text(phase.userFacingTitle)
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                    Button("削除を再試行") {
                        completeDeletion.startOrRetry()
                    }
                }
            }
        } header: {
            Text("データ")
        } footer: {
            Text(dataStorageDisclosure)
        }
    }

    private var resetDataMessage: String {
        if persistenceMode == .localOnly {
            return "集中の粒・まとまり粒・記念石を表示と集計から外し、0から始めます。旧世代の行は端末内に残り、データ書き出しには含まれる場合があります。端末内の物理データはアプリを削除すると消去できます。この操作は取り消せません。"
        }
        return "集中の粒・まとまり粒・記念石を表示と集計から外し、0から始めます。同じiCloudの端末には接続後に反映されます。オフライン端末から古い記録が戻ることを防ぐため、旧世代の行は同期用に残り、データ書き出しには含まれます。端末内の物理データはアプリを削除すると消去できます。iCloud側のアプリデータはAppleのiCloudストレージ管理から削除してください。この操作は取り消せません。"
    }

    private var dataStorageDisclosure: String {
        let contents = "書き出しファイルには、テーマ名・成果メモ・設定・タイマー整合用のランダムな端末識別子と、以前リセットした旧世代を含む、この端末で利用可能な全11種類の出荷対象保存データが入ります。SNS用の共有画像とは異なります。保存先を確認してください。"
        if persistenceMode == .localOnly {
            return contents + " 通常のリセット後はテーマとアプリ設定が残ります。端末内の物理データはアプリの削除で消去できます。JSONは保管用で、アプリへ再読込したりiCloudの記録へ移行したりする機能はありません。"
        }
        return contents + " 端末内の物理データはアプリの削除、iCloud側はAppleのiCloudストレージ管理から削除できます。"
    }

    private func startDataExport() {
        guard !isExportingData else { return }
        do {
            if modelContext.hasChanges {
                try modelContext.save()
            }
        } catch {
            dataExportError = "保存中の変更を確定できませんでした。\n\(error.localizedDescription)"
            return
        }

        removePresentedDataExport()
        let exportID = UUID()
        let worker = PomoGemDataExportWorker(modelContainer: modelContext.container)
        let appInfo = PomoGemDataExportAppInfo(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        )
        activeDataExportID = exportID
        isExportingData = true
        dataExportProgress = PomoGemDataExportProgress(
            phase: .preparing,
            completedRecords: 0,
            estimatedTotalRecords: 0
        )

        dataExportTask = Task { @MainActor in
            do {
                let result = try await worker.export(appInfo: appInfo) { progress in
                    Task { @MainActor in
                        guard activeDataExportID == exportID else { return }
                        dataExportProgress = progress
                    }
                }
                guard activeDataExportID == exportID, !Task.isCancelled else {
                    try? PomoGemDataExporter.removeExport(at: result.fileURL)
                    return
                }
                dataExportFileURL = result.fileURL
                showDataExportShareSheet = true
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "\(result.recordCounts.total)件のデータを書き出しました。保存先を選んでください"
                )
            } catch is CancellationError {
                // The explicit cancel control announces immediately. Navigating
                // away cancels silently so VoiceOver is not interrupted.
            } catch {
                guard activeDataExportID == exportID else { return }
                dataExportError = "データを書き出せませんでした。\n\(error.localizedDescription)"
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "データを書き出せませんでした"
                )
            }

            guard activeDataExportID == exportID else { return }
            activeDataExportID = nil
            dataExportTask = nil
            isExportingData = false
            dataExportProgress = nil
        }
    }

    private func cancelDataExport(announce: Bool) {
        guard isExportingData else { return }
        activeDataExportID = nil
        dataExportTask?.cancel()
        dataExportTask = nil
        dataExportProgress = nil
        isExportingData = false
        if announce {
            UIAccessibility.post(notification: .announcement, argument: "データの書き出しをキャンセルしました")
        }
    }

    private func removePresentedDataExport() {
        guard let url = dataExportFileURL else { return }
        dataExportFileURL = nil
        Task.detached(priority: .utility) {
            try? PomoGemDataExporter.removeExport(at: url)
        }
    }

    private func removeStaleDataExports() async {
        _ = try? await CancellationResponsiveTaskWaiter.value {
            await Task.detached(priority: .utility) {
                try? PomoGemDataExporter.removeStaleTemporaryExports()
            }.value
        }
    }

    private func settingBinding(
        _ group: PrefsSyncPolicy.Group,
        currentValue: Bool,
        update: @escaping (Prefs, Bool) -> Void,
        onCommitted: @escaping (Bool) -> Void = { _ in }
    ) -> Binding<Bool> {
        Binding(
            get: {
                // Establish an explicit SwiftUI dependency so a successful
                // synchronous SwiftData save is reflected by the Toggle in the
                // same interaction, without retaining an uncommitted overlay.
                _ = booleanSettingsCommitGeneration
                return currentValue
            },
            set: { value in
                guard currentValue != value else { return }
#if DEBUG
                let commitStartedAt = ProcessInfo.processInfo.systemUptime
#endif
                let didCommit = updateSetting(
                    group,
                    value: value,
                    update: update,
                    onCommitted: onCommitted
                )
                booleanSettingsCommitGeneration &+= 1
#if DEBUG
                if LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess {
                    lastBooleanSettingsCommitMilliseconds = Int(
                        (ProcessInfo.processInfo.systemUptime - commitStartedAt)
                            * 1_000
                    )
                    lastBooleanSettingsCommitSucceeded = didCommit
                }
#endif
            }
        )
    }

    private var timerCompletionSoundBinding: Binding<TimerCompletionSound> {
        Binding(
            get: { sensoryPreferences.timerCompletionSound },
            set: { updateTimerCompletionSound($0) }
        )
    }

    private var timerCompletionHapticBinding: Binding<TimerCompletionHaptic> {
        Binding(
            get: { sensoryPreferences.timerCompletionHaptic },
            set: { updateTimerCompletionHaptic($0) }
        )
    }

    private var completionPreviewConfiguration: TimerCompletionPreviewConfiguration {
        TimerCompletionPreviewConfiguration(
            sound: sensoryPreferences.soundOn
                ? sensoryPreferences.timerCompletionSound
                : nil,
            haptic: sensoryPreferences.hapticsOn
                ? sensoryPreferences.timerCompletionHaptic
                : nil
        )
    }

    private func updateTimerCompletionSound(_ style: TimerCompletionSound) {
        guard style != sensoryPreferences.timerCompletionSound else { return }
        completionPreview.cancel()
        do {
            try PrefsConsumerPolicy.mutate(
                .timerCompletionSound,
                context: modelContext,
                markers: resetSnapshots
            ) {
                $0.timerCompletionSoundRawValue = style.rawValue
            }
            try modelContext.save()
            booleanSettingsCommitGeneration &+= 1
            // Materialize the selected notification cue while the app is active.
            // Scheduling also retries and safely falls back to the system sound.
            _ = try? TimerCompletionSoundLibrary.ensureSoundFile(for: style)
        } catch {
            modelContext.rollback()
            settingsError = "タイマー終了音を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)"
        }
    }

    private func updateTimerCompletionHaptic(_ style: TimerCompletionHaptic) {
        guard style != sensoryPreferences.timerCompletionHaptic else { return }
        completionPreview.cancel()
        do {
            try PrefsConsumerPolicy.mutate(
                .timerCompletionHaptic,
                context: modelContext,
                markers: resetSnapshots
            ) {
                $0.timerCompletionHapticRawValue = style.rawValue
            }
            try modelContext.save()
            booleanSettingsCommitGeneration &+= 1
        } catch {
            modelContext.rollback()
            settingsError = "タイマー終了時の触覚を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)"
        }
    }

    private var timerDisplayModeBinding: Binding<TimerDisplayMode> {
        Binding(
            get: {
                resolvedPreferences?.timerDisplayMode ?? .ringAndTime
            },
            set: { mode in
                updateTimerDisplayMode(mode)
            }
        )
    }

    private var reminderTimeBinding: Binding<Date> {
        Binding(
            get: {
                var components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
                components.hour = resolvedPreferences?.reminderHour
                    ?? Constants.Notification.defaultReminderHour
                components.minute = resolvedPreferences?.reminderMinute
                    ?? Constants.Notification.defaultReminderMinute
                return Calendar.current.date(from: components) ?? .now
            },
            set: { date in
                guard resolvedPreferences != nil else { return }
                let hour = Calendar.current.component(.hour, from: date)
                let minute = Calendar.current.component(.minute, from: date)
                do {
                    try PrefsConsumerPolicy.mutate(
                        .reminderTime,
                        context: modelContext,
                        markers: resetSnapshots
                    ) {
                        $0.reminderHour = hour
                        $0.reminderMinute = minute
                    }
                    try modelContext.save()
                    synchronizeNotifications()
                } catch {
                    modelContext.rollback()
                    settingsError = "通知時刻を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)"
                }
            }
        )
    }

    private var nextSubjectColor: String {
        let hue = Double(subjects.count % Constants.App.maximumSubjects)
            / Double(Constants.App.maximumSubjects)
        return UIColor(
            hue: hue,
            saturation: Constants.App.subjectColorSaturation,
            brightness: Constants.App.subjectColorBrightness,
            alpha: 1
        ).hexString
    }

    private func addSubject(name: String, colorHex: String, isArchived _: Bool) -> String? {
        guard subjects.count < Constants.App.maximumSubjects else {
            return "テーマは最大\(Constants.App.maximumSubjects)件までです。"
        }
        if let validationError = subjectNameValidationError(name) {
            return validationError
        }
        guard let sanitizedName = SubjectNamePolicy.validated(name) else {
            return SubjectNamePolicy.validationError(for: name)?.message
                ?? "テーマ名を入力してください。"
        }
        modelContext.insert(
            Subject(
                name: sanitizedName,
                colorHex: colorHex,
                sortOrder: NonnegativeIntPolicy.next(
                    after: subjects.map(\.sortOrder).max()
                )
            )
        )
        return commitChanges(failureMessage: "テーマを追加できませんでした。")
    }

    private func saveSubjectEdits(
        subject: Subject,
        name: String,
        color: String,
        isArchived: Bool
    ) -> String? {
        if let validationError = subjectNameValidationError(
            name,
            excluding: subject
        ) {
            return validationError
        }
        guard let sanitizedName = SubjectNamePolicy.validated(name) else {
            return SubjectNamePolicy.validationError(for: name)?.message
                ?? "テーマ名を入力してください。"
        }
        do {
            subject.name = sanitizedName
            subject.colorHex = color
            subject.isArchived = isArchived
            try SubjectSyncPolicy.recordUserMutation(
                from: subject,
                among: storedSubjects
            )
            try modelContext.save()
            return nil
        } catch {
            modelContext.rollback()
            return "テーマの変更を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)"
        }
    }

    private func subjectNameValidationError(
        _ name: String,
        excluding editedSubject: Subject? = nil
    ) -> String? {
        if let validationError = SubjectNamePolicy.validationError(for: name) {
            return validationError.message
        }
        let normalized = SubjectNamePolicy.comparisonKey(name)
        let duplicate = subjects.first {
            $0.id != editedSubject?.id
                && SubjectNamePolicy.comparisonKey($0.name) == normalized
        }
        guard let duplicate else { return nil }
        return "同じ名前のテーマ「\(duplicate.safeDisplayName)」がすでにあります。"
    }

    private func deleteSubject(_ subject: Subject) {
        do {
            subject.isArchived = true
            subject.deletedAt = .now
            try SubjectSyncPolicy.recordUserMutation(
                from: subject,
                among: storedSubjects
            )
            try modelContext.save()
        } catch {
            modelContext.rollback()
            settingsError = "テーマを削除できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)"
        }
    }

    private func subjectDeletionMessage(
        for subject: Subject,
        recordCount: Int
    ) -> String {
        if recordCount == 0 {
            return "「\(subject.safeDisplayName)」を削除します。関連する過去の記録はありません。この操作は取り消せません。"
        }
        return "「\(subject.safeDisplayName)」だけを削除します。過去の記録\(recordCount)件と質量は消えず、現在の名前と色も残ります。この操作は取り消せません。"
    }

    private func prepareSubjectDeletion(_ subject: Subject) {
        do {
            let related = try currentRelatedRecords(for: subject)
            subjectPendingDeletionRecordCount = NonnegativeIntPolicy.adding(
                Set(related.sessions.map(\.id)).count,
                Set(related.achievements.map(\.id)).count
            )
            subjectPendingDeletion = subject
        } catch {
            modelContext.rollback()
            settingsError = "関連する記録を確認できないため、テーマを削除できません。\n\(error.localizedDescription)"
        }
    }

    private func currentRelatedRecords(
        for subject: Subject
    ) throws -> (sessions: [StudySession], achievements: [AchievementStone]) {
        let targetID = subject.id
        let currentEpochID = ActivityResetPolicy.currentEpochID(from: resetSnapshots)
        let sessionDescriptor: FetchDescriptor<StudySession>
        let achievementDescriptor: FetchDescriptor<AchievementStone>
        if let currentEpochID {
            sessionDescriptor = FetchDescriptor(predicate: #Predicate {
                $0.dataEpochID == currentEpochID
                    && ($0.subjectIDSnapshot == targetID || $0.subject?.id == targetID)
            })
            achievementDescriptor = FetchDescriptor(predicate: #Predicate {
                $0.dataEpochID == currentEpochID && $0.subject?.id == targetID
            })
        } else {
            sessionDescriptor = FetchDescriptor(predicate: #Predicate {
                $0.dataEpochID == nil
                    && ($0.subjectIDSnapshot == targetID || $0.subject?.id == targetID)
            })
            achievementDescriptor = FetchDescriptor(predicate: #Predicate {
                $0.dataEpochID == nil && $0.subject?.id == targetID
            })
        }

        let sessions = StudySessionSyncPolicy.canonicalSessions(
            from: try modelContext.fetch(sessionDescriptor)
        )
        let achievements = AchievementStonePolicy.canonicalStones(
            from: try modelContext.fetch(achievementDescriptor)
        ).filter { $0.deletedAt == nil }
        return (sessions, achievements)
    }

    private func moveSubjects(from source: IndexSet, to destination: Int) {
        var reordered = subjects
        reordered.move(fromOffsets: source, toOffset: destination)
        do {
            for (index, subject) in reordered.enumerated()
            where subject.sortOrder != index {
                subject.sortOrder = index
                try SubjectSyncPolicy.recordUserMutation(
                    from: subject,
                    among: storedSubjects
                )
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            settingsError = "テーマの並び順を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)"
        }
    }

    private enum SubjectMoveDirection {
        case up
        case down
    }

    private func moveSubject(at index: Int, direction: SubjectMoveDirection) {
        guard subjects.indices.contains(index) else { return }
        switch direction {
        case .up:
            guard index > subjects.startIndex else { return }
            moveSubjects(from: IndexSet(integer: index), to: index - 1)
        case .down:
            guard index < subjects.index(before: subjects.endIndex) else { return }
            // `move(fromOffsets:toOffset:)` interprets the destination before
            // removing the source, hence +2 moves one visible row downward.
            moveSubjects(from: IndexSet(integer: index), to: index + 2)
        }
    }

    private func confirmPreferredFocusSeconds(_ totalSeconds: Int) -> Bool {
        guard purchase.isPro else {
            router.showToast("Proの購入状態を確認してください", symbol: "lock")
            return false
        }
        guard savePreferredFocusSeconds(totalSeconds) else { return false }
        showCustomDuration = false
        return true
    }

    private func savePreferredFocusSeconds(_ totalSeconds: Int) -> Bool {
        let duration = PomodoroDuration(totalSeconds: totalSeconds)
        guard let resolvedPreferences,
              duration.isValid,
              !duration.requiresPro || purchase.isPro else { return false }
        if resolvedPreferences.preferredFocusSeconds == totalSeconds {
            return true
        }
        do {
            try PrefsConsumerPolicy.setPreferredFocusSeconds(
                totalSeconds,
                context: modelContext,
                markers: resetSnapshots
            )
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            router.showToast("既定の集中時間を保存できませんでした", symbol: "exclamationmark.triangle")
            return false
        }
    }

    private func updateTimerDisplayMode(_ mode: TimerDisplayMode) {
        guard let resolvedPreferences,
              resolvedPreferences.timerDisplayMode != mode else { return }
        do {
            try PrefsConsumerPolicy.mutate(
                .timerDisplayMode,
                context: modelContext,
                markers: resetSnapshots
            ) {
                $0.timerDisplayModeRawValue = mode.rawValue
            }
            try modelContext.save()
            booleanSettingsCommitGeneration &+= 1
        } catch {
            modelContext.rollback()
            settingsError = "タイマーの表示を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)"
        }
    }

    private func updateReminder(enabled: Bool) {
        updatePassiveNotification(.dailyReminder, enabled: enabled)
    }

    private func updateWrappedNotification(enabled: Bool) {
        updatePassiveNotification(.wrapped, enabled: enabled)
    }

    private func updateFocusReturnReminder(enabled: Bool) {
        let intent = notificationPreferenceIntents.begin(.focusReturnReminder)
        let manager = NotificationManager.shared
        if !enabled {
            focusReturnReminderEnabled = false
            manager.cancelFocusReturnReminder()
            return
        }

        viewTasks.start {
            guard let granted = await notificationPreferenceIntents.authorizeUpdate(
                .focusReturnReminder,
                intent: intent,
                enabled: true,
                refreshAuthorization: {
                    await manager.refreshAuthorizationStatus()
                    return manager.isAuthorized
                },
                requestAuthorization: {
                    await manager.requestAuthorization()
                }
            ), notificationPreferenceIntents.isCurrent(.focusReturnReminder, intent: intent)
            else { return }
            focusReturnReminderEnabled = granted
            if !granted {
                manager.cancelFocusReturnReminder()
                notificationError = notificationPermissionMessage(
                    underlyingError: manager.lastErrorDescription
                )
            }
        }
    }

    private func updatePassiveNotification(
        _ preference: PassiveNotificationPreference,
        enabled: Bool
    ) {
        guard resolvedPreferences != nil else { return }
        let intent = notificationPreferenceIntents.begin(preference.intentKey)
        viewTasks.start {
            let manager = NotificationManager.shared
            guard let permitted = await notificationPreferenceIntents.authorizeUpdate(
                preference.intentKey,
                intent: intent,
                enabled: enabled,
                refreshAuthorization: {
                    await manager.refreshAuthorizationStatus()
                    return manager.isAuthorized
                },
                requestAuthorization: {
                    await manager.requestAuthorization()
                }
            ), notificationPreferenceIntents.isCurrent(preference.intentKey, intent: intent)
            else { return }
            guard permitted else {
                disableNotificationPreference(preference)
                notificationError = notificationPermissionMessage(
                    underlyingError: manager.lastErrorDescription
                )
                await synchronizeNotificationsNow()
                return
            }

            switch preference {
            case .dailyReminder:
                do {
                    try PrefsConsumerPolicy.mutate(
                        .reminderEnabled,
                        context: modelContext,
                        markers: resetSnapshots
                    ) {
                        $0.reminderEnabled = enabled
                    }
                    try modelContext.save()
                } catch {
                    modelContext.rollback()
                    settingsError = "毎日のリマインダ設定を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)"
                    return
                }
            case .wrapped:
                wrappedNotifications = enabled
            }

            await synchronizeNotificationsNow()
        }
    }

    private func synchronizeNotifications() {
        viewTasks.start {
            await synchronizeNotificationsNow()
        }
    }

    private func resetStudyData() {
        guard ActivityResetAdmissionPolicy.permitsUserReset(in: persistenceMode) else {
            settingsError = ActivityResetAdmissionPolicy.cloudResetUnavailableMessage
            return
        }
        let marker: ActivityResetMarker
        do {
            marker = try ActivityResetStore.beginUserInitiatedReset(
                context: modelContext,
                persistenceMode: persistenceMode,
                deviceID: FocusDeviceIdentity.current()
            )
        } catch {
            settingsError = "リセット情報を安全に保存できませんでした。\n\(error.localizedDescription)"
            return
        }

        // The append-only marker is the atomic deletion boundary. Every view
        // immediately rejects the previous generation, and offline devices
        // learn the same rule through CloudKit. Eagerly materializing and
        // deleting hundreds of thousands of rows here made Settings itself an
        // unrecoverable main-thread freeze for long-lived accounts. Physical
        // row compaction is maintenance, never a prerequisite for reset.
        do {
            let writer = try PrefsSyncPolicy.ensureWriterRow(
                context: modelContext,
                currentEpochID: marker.epochID
            )
            writer.manualDayKey = FairnessPolicy.deviceDayKey(for: .now)
            writer.manualUsedToday = 0
        } catch {
            modelContext.rollback()
            settingsError = "記録をリセットできませんでした。\n\(error.localizedDescription)"
            return
        }
        if let error = commitChanges(failureMessage: "記録をリセットできませんでした。") {
            settingsError = error
            return
        }

        TimerCompletionAlertController.shared.stop()
        TimerCompletionAlertAcknowledgementStore.removeAll()
        FocusPersistence.clear()
        FocusPersistence.clearBreak()
        PendingStratumCelebrationStore.removeAll()
        PendingRewardReceiptStore.removeAll()
        FocusRestCadenceStore.removeAll()
        UserDefaults.standard.removeObject(forKey: FocusPersistence.localCompletionIDKey)
        UserDefaults.standard.removeObject(
            forKey: AccountScopedLocalState.defaultsKey(
                base: "review.local-completion-count"
            )
        )
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where AccountScopedLocalState.keyBelongsToActiveNamespace(
            key,
            basePrefix: "share.prompt."
        ) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        router.showToast(
            persistenceMode == .localOnly
                ? "このiPhone内の記録をリセットしました"
                : "記録をリセットしました。ほかの端末にはiCloud接続後に反映されます",
            symbol: "trash"
        )

        // The reset marker is already committed. Complete its external cleanup
        // even if Settings disappears, and keep the old container leased until
        // that cleanup settles so it cannot reach a remounted account's timer.
        // Only the optional error presentation belongs to this view's task.
        let ticket = resetCleanupJournal.begin(epochID: marker.epochID)
        let notificationCleanup = NotificationManager.shared.prepareTimerNotificationCleanup()
        let activityCleanup = FocusActivityManager.shared.prepareCurrentActivityRetirement()
        let deliveredStateCleanup = NotificationManager.shared.prepareDeliveredStateCleanup()
        let cleanupTask = AcceptedActivityResetCleanup.start(
            retaining: modelContext.container,
            completing: ticket
        ) {
            await notificationCleanup()
            await activityCleanup.end()
            await deliveredStateCleanup()
            try await WidgetSnapshotStore.shared.clear()
        }
        viewTasks.start {
            do {
                try await CancellationResponsiveTaskWaiter.value { try await cleanupTask.value }
            } catch {
                guard !Task.isCancelled else { return }
                settingsError = persistenceMode == .localOnly
                    ? "このiPhone内の記録はリセット済みですが、端末上の補助表示を消去できませんでした。\n\(error.localizedDescription)"
                    : "この端末の記録はリセット済みですが、ウィジェットの表示を消去できませんでした。iCloudへの反映には時間がかかる場合があります。\n\(error.localizedDescription)"
            }
        }
    }

    private var storageDestination: String {
        persistenceMode == .localOnly ? "このiPhone" : "iCloud"
    }

    private func updateSetting(
        _ group: PrefsSyncPolicy.Group,
        value: Bool,
        update: (Prefs, Bool) -> Void,
        onCommitted: (Bool) -> Void
    ) -> Bool {
        do {
            try PrefsConsumerPolicy.mutate(
                group,
                context: modelContext,
                markers: resetSnapshots
            ) {
                update($0, value)
            }
            try modelContext.save()
            onCommitted(value)
            return true
        } catch {
            modelContext.rollback()
            settingsError = "設定を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)"
            return false
        }
    }

    private func commitChanges(failureMessage: String) -> String? {
        do {
            try modelContext.save()
            return nil
        } catch {
            modelContext.rollback()
            return "\(failureMessage)\n変更前の状態に戻しました。\n\(error.localizedDescription)"
        }
    }

    private func disableNotificationPreference(_ preference: PassiveNotificationPreference) {
        switch preference {
        case .dailyReminder:
            guard resolvedPreferences?.reminderEnabled == true else { return }
            do {
                try PrefsConsumerPolicy.mutate(
                    .reminderEnabled,
                    context: modelContext,
                    markers: resetSnapshots
                ) {
                    $0.reminderEnabled = false
                }
                try modelContext.save()
            } catch {
                modelContext.rollback()
                settingsError = "毎日のリマインダをオフにできませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)"
            }
        case .wrapped:
            wrappedNotifications = false
        }
    }

    private func refreshViewServices() async {
        // Only the process-wide service is retained by the system wait. The
        // Settings task can release its ModelContext when the view disappears.
        let purchase = purchase
        do {
            try await CancellationResponsiveTaskWaiter.value {
                await purchase.refreshEntitlements()
            }
        } catch { return }
        guard !Task.isCancelled else { return }
        await reconcileNotificationAuthorization()
    }

    private func reconcileNotificationAuthorization() async {
        let manager = NotificationManager.shared
        await manager.refreshAuthorizationStatus()
        guard !Task.isCancelled else { return }
        let prefs = resolvedPreferences

        if !manager.isAuthorized {
            let hadEnabledPreference = (prefs?.reminderEnabled ?? false)
                || wrappedNotifications
                || focusReturnReminderEnabled
            if prefs?.reminderEnabled == true {
                do {
                    try PrefsConsumerPolicy.mutate(
                        .reminderEnabled,
                        context: modelContext,
                        markers: resetSnapshots
                    ) {
                        $0.reminderEnabled = false
                    }
                    try modelContext.save()
                } catch {
                    modelContext.rollback()
                    settingsError = "通知の実際の状態を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)"
                }
            }
            wrappedNotifications = false
            focusReturnReminderEnabled = false
            manager.cancelFocusReturnReminder()

            if hadEnabledPreference {
                notificationError = notificationPermissionMessage(underlyingError: nil)
            }
        }

        await synchronizeNotificationsNow()
    }

    private func synchronizeNotificationsNow() async {
        let manager = NotificationManager.shared
        await manager.refreshAuthorizationStatus()
        guard !Task.isCancelled else { return }
        let prefs = resolvedPreferences
        do {
            try await manager.synchronizePassiveNotifications(
                dailyReminderEnabled: (prefs?.reminderEnabled ?? false)
                    && manager.isAuthorized,
                wrappedEnabled: wrappedNotifications && manager.isAuthorized,
                hour: prefs?.reminderHour
                    ?? Constants.Notification.defaultReminderHour,
                minute: prefs?.reminderMinute
                    ?? Constants.Notification.defaultReminderMinute,
                playsSound: prefs?.soundOn ?? false
            )
        } catch {
            guard !Task.isCancelled else { return }
            notificationError = "通知の予定を更新できませんでした。\n\(error.localizedDescription)"
        }
    }

    private func notificationPermissionMessage(underlyingError: String?) -> String {
        let message = "通知が許可されていません。端末の「設定」から「ポモジェム」の通知を許可してください。"
        guard let underlyingError, !underlyingError.isEmpty else { return message }
        return "\(message)\n\(underlyingError)"
    }

    private enum PassiveNotificationPreference {
        case dailyReminder
        case wrapped

        var intentKey: NotificationPreference {
            switch self {
            case .dailyReminder: .dailyReminder
            case .wrapped: .wrapped
            }
        }
    }
}

/// Shared by Settings navigation and the active timer's presentation sheet.
/// The caller owns persistence; these samples never create or advance a timer.
struct TimerDisplayModeSelectionView: View {
    @Binding var selection: TimerDisplayMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), alignment: .top),
            count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("残り時間の見え方を選ぶ")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(PomoGemTheme.text)
                        .accessibilityAddTraits(.isHeader)
                    Text("見本は25分タイマーの途中、残り16分15秒です。選んだ表示はすぐに反映されます。")
                        .font(.subheadline)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(TimerDisplayMode.allCases) { mode in
                        displayOption(mode)
                    }
                }

                Text("どの表示でも、タイマーの時間や集中の記録は変わりません。")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(NightBackground())
        .navigationTitle("タイマーの表示")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timer-display.selection")
    }

    private func displayOption(_ mode: TimerDisplayMode) -> some View {
        let isSelected = selection == mode
        return Button {
            guard selection != mode else { return }
            selection = mode
        } label: {
            VStack(spacing: 14) {
                displayPreview(mode)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    Text(mode.title)
                        .font(.headline)
                        .foregroundStyle(PomoGemTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(mode.detail)
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(
                maxWidth: .infinity,
                minHeight: dynamicTypeSize.isAccessibilitySize ? nil : 246,
                alignment: .top
            )
            .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .topTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? PomoGemTheme.amber : PomoGemTheme.muted)
                    .padding(12)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(PomoGemRowButtonStyle(isSelected: isSelected, cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mode.title)。\(mode.detail)")
        .accessibilityValue(isSelected ? "選択中" : "未選択")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected ? "現在のタイマー表示です" : "選ぶとすぐに反映されます")
        .accessibilityIdentifier("timer-display.option.\(mode.rawValue)")
        .accessibilityAction {
            guard selection != mode else { return }
            selection = mode
        }
    }

    private func displayPreview(_ mode: TimerDisplayMode) -> some View {
        // Scale the production layout as a whole, preserving its proportions.
        // The card's accessible title and detail describe this decorative image.
        FocusTimerDisplay(
            size: 240,
            progress: 0.35,
            remainingTime: "16:15",
            accessibleRemainingTime: "残り16分15秒",
            modeLabel: "FOCUS",
            displayMode: mode,
            isBreakMode: false,
            isPaused: false,
            accent: PomoGemTheme.amber,
            reduceMotion: true
        )
        .environment(\.dynamicTypeSize, .large)
        .scaleEffect(112.0 / 240.0)
        .frame(width: 112, height: 112)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct TimerCompletionPreviewConfiguration: Equatable, Sendable {
    let sound: TimerCompletionSound?
    let haptic: TimerCompletionHaptic?

    var isSilent: Bool { sound == nil && haptic == nil }
}

enum TimerCompletionPreviewState: Equatable {
    case idle
    case countingDown(Int)

    var remainingSeconds: Int? {
        guard case let .countingDown(value) = self else { return nil }
        return value
    }
}

/// Generation fencing is intentional in addition to Task cancellation: an
/// injected or system await may finish after cancellation, and an obsolete
/// preview must never play with a stale selection.
@MainActor
@Observable
final class TimerCompletionPreviewController {
    typealias Sleeper = @Sendable () async throws -> Void
    typealias Playback = @MainActor @Sendable (
        TimerCompletionPreviewConfiguration
    ) -> Void

    private(set) var state: TimerCompletionPreviewState = .idle

    private let sleeper: Sleeper
    private let playback: Playback
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(
        sleeper: @escaping Sleeper = {
            try await Task.sleep(for: .seconds(1))
        },
        playback: @escaping Playback = { configuration in
            if let sound = configuration.sound {
                SoundSynth.shared.isEnabled = true
                SoundSynth.shared.playTimerCompletion(sound)
            }
            if let haptic = configuration.haptic {
                Haptics.shared.isEnabled = true
                Haptics.shared.playTimerCompletion(haptic)
            }
        }
    ) {
        self.sleeper = sleeper
        self.playback = playback
    }

    var isRunning: Bool { state != .idle }

    func start(_ configuration: TimerCompletionPreviewConfiguration) {
        guard !configuration.isSilent else {
            cancel()
            return
        }

        generation &+= 1
        let previewGeneration = generation
        task?.cancel()
        state = .countingDown(3)
        let sleeper = self.sleeper
        let playback = self.playback

        task = Task { @MainActor [weak self] in
            for nextValue in [2, 1, 0] {
                do {
                    try await sleeper()
                } catch {
                    guard let self, self.generation == previewGeneration else {
                        return
                    }
                    self.task = nil
                    self.state = .idle
                    return
                }

                guard let self,
                      !Task.isCancelled,
                      self.generation == previewGeneration else { return }
                if nextValue > 0 {
                    self.state = .countingDown(nextValue)
                }
            }

            guard let self,
                  !Task.isCancelled,
                  self.generation == previewGeneration else { return }
            self.task = nil
            self.state = .idle
            playback(configuration)
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        state = .idle
    }
}

private struct TimerCompletionPreviewRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let controller: TimerCompletionPreviewController
    let configuration: TimerCompletionPreviewConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: togglePreview) {
                HStack(spacing: 12) {
                    Image(systemName: controller.isRunning
                        ? "xmark.circle.fill"
                        : "play.circle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(PomoGemTheme.amber)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.isRunning
                            ? "プレビューをキャンセル"
                            : "3秒後に試す")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(PomoGemTheme.text)
                        Text("選んだ終了音と触覚を一緒に確認します")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                    Spacer(minLength: 8)
                    if let remaining = controller.state.remainingSeconds {
                        Text("\(remaining)")
                            .font(.title3.monospacedDigit().weight(.bold))
                            .foregroundStyle(PomoGemTheme.amber)
                            .contentTransition(
                                reduceMotion
                                    ? .identity
                                    : .numericText(countsDown: true)
                            )
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PomoGemRowButtonStyle())
            .accessibilityIdentifier("settings.completion-preview")
            .accessibilityLabel(controller.isRunning
                ? "プレビューをキャンセル"
                : "3秒後に試す")
            .accessibilityValue(controller.state.remainingSeconds.map {
                "あと\($0)秒"
            } ?? "待機中")
            .accessibilityHint(configuration.isSilent
                ? "音か触覚をオンにすると試せます"
                : "選んだタイマー終了音と触覚を3秒後に再生します")

            if let remaining = controller.state.remainingSeconds {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(
                        value: Double(3 - remaining),
                        total: 3
                    )
                    .tint(PomoGemTheme.amber)
                    Text("あと\(remaining)秒")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PomoGemTheme.muted)
                        .contentTransition(
                            reduceMotion
                                ? .identity
                                : .numericText(countsDown: true)
                        )
                        .accessibilityIdentifier(
                            "settings.completion-preview.status"
                        )
                }
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.18),
                    value: remaining
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("プレビューまであと\(remaining)秒")
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private func togglePreview() {
        if controller.isRunning {
            controller.cancel()
            UIAccessibility.post(
                notification: .announcement,
                argument: "プレビューをキャンセルしました"
            )
        } else {
            controller.start(configuration)
            UIAccessibility.post(
                notification: .announcement,
                argument: "3秒後にプレビューします。もう一度押すとキャンセルできます"
            )
        }
    }
}

private struct CompleteDataDeletionConfirmationView: View {
    private enum Step {
        case consequences
        case finalConfirmation
    }

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .consequences
    @State private var understoodOtherDevices = false
    @State private var confirmationText = ""

    let onConfirmed: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if step == .consequences {
                    consequences
                } else {
                    finalConfirmation
                }
            }
            .scrollContentBackground(.hidden)
            .background(NightBackground())
            .navigationTitle(step == .consequences ? "ユーザー内容を削除" : "最終確認")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                actionButton
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
            }
        }
    }

    private var consequences: some View {
        Group {
            Section {
                Label("テーマと成果メモ", systemImage: "tag.slash")
                Label("集中記録・粒・集計", systemImage: "clock.badge.xmark")
                Label("設定・タイマー復元情報・ウィジェット", systemImage: "gear.badge.xmark")
                Label("このAppのプライベートiCloud上のユーザー内容", systemImage: "icloud.slash")
            } header: {
                Text("取り消せない削除対象")
            } footer: {
                Text("テーマ・記録・設定などのユーザー内容を削除します。古い端末からの再流入を検知するため、内容を含まない削除世代記録1件（世代ID・処理ID・連番・状態・日時）はiCloudに残ります。Proの購入履歴はAppleが管理しているため削除されず、同じApple Accountでは復元できます。")
            }

            Section("削除を始める前に") {
                Text("iCloudへ接続できる状態で実行してください。通信が切れた場合は完了と表示せず、安全な位置から再試行します。")
                Text("ほかの端末も最新版へ更新し、オンラインで一度起動してください。オフラインのままの端末や、この削除世代に対応していない古いバージョンは、端末内の古い記録を後からiCloudへ再送する可能性があります。")
                Text("本Appは別端末のローカル保存を遠隔消去できません。削除後も、使わない古いインストールは削除してください。")
            }
        }
    }

    private var finalConfirmation: some View {
        Group {
            Section {
                Toggle(
                    "ほかの端末と古いバージョンに関する制約を確認しました",
                    isOn: $understoodOtherDevices
                )
            }

            Section {
                TextField("削除", text: $confirmationText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .accessibilityLabel("確認のため削除と入力")
            } header: {
                Text("「削除」と入力")
            } footer: {
                Text("開始後は記録の追加を停止します。iCloudでユーザー内容の削除と、内容を含まない削除世代記録の確定を確認するまで、通常画面には戻りません。")
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if step == .consequences {
            Button("内容を確認して次へ") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    step = .finalConfirmation
                }
            }
            .buttonStyle(PomoGemPrimaryButtonStyle())
        } else {
            Button("ユーザー内容を削除", role: .destructive) {
                onConfirmed()
            }
            .buttonStyle(PomoGemPrimaryButtonStyle())
            .disabled(
                !understoodOtherDevices
                    || confirmationText.trimmingCharacters(in: .whitespacesAndNewlines)
                        != "削除"
            )
        }
    }
}

private struct FontLicenseView: View {
    @Environment(\.dismiss) private var dismiss

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "LICENSE-fonts", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "ライセンス文書を読み込めませんでした。" }
        return text
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(licenseText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(PomoGemTheme.muted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .background(NightBackground())
            .navigationTitle("フォントライセンス")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PomoGemSheetCloseButton(
                        accessibilityIdentifier: "font-license.close"
                    ) {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SubjectReorderAccessibilityModifier: ViewModifier {
    let index: Int
    let count: Int
    let moveUp: () -> Void
    let moveDown: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if count <= 1 {
            content
        } else if index == 0 {
            content.accessibilityAction(named: "下へ移動", moveDown)
        } else if index == count - 1 {
            content.accessibilityAction(named: "上へ移動", moveUp)
        } else {
            content
                .accessibilityAction(named: "上へ移動", moveUp)
                .accessibilityAction(named: "下へ移動", moveDown)
        }
    }
}

private struct SettingLabel: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(PomoGemTheme.text)
                Text(subtitle).font(.caption).foregroundStyle(PomoGemTheme.muted)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(PomoGemTheme.amber).frame(width: 26)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RarePebbleGuideRow: View {
    let kind: PebbleKind
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(fillStyle)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Circle()
                            .strokeBorder(strokeColor, lineWidth: kind == .normal ? 1 : 2)
                    }
                    .shadow(color: glowColor, radius: kind == .normal ? 0 : 6)

                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white.opacity(0.94))
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(PomoGemTheme.text)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch kind {
        case .normal: "circle.fill"
        case .gold: "sparkle"
        case .prism: "diamond.fill"
        }
    }

    private var fillStyle: AnyShapeStyle {
        switch kind {
        case .normal:
            AnyShapeStyle(Color(hex: Constants.Color.mathematics))
        case .gold:
            AnyShapeStyle(
                LinearGradient(
                    colors: [Color(hex: Constants.Color.pebbleGold), .white.opacity(0.86)],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                )
            )
        case .prism:
            AnyShapeStyle(
                AngularGradient(
                    colors: [.pink, .orange, .yellow, .mint, .cyan, .indigo, .pink],
                    center: .center
                )
            )
        }
    }

    private var strokeColor: Color {
        switch kind {
        case .normal: .white.opacity(0.34)
        case .gold: .white.opacity(0.82)
        case .prism: .white.opacity(0.92)
        }
    }

    private var glowColor: Color {
        switch kind {
        case .normal: .clear
        case .gold: Color(hex: Constants.Color.pebbleGold).opacity(0.38)
        case .prism: .cyan.opacity(0.34)
        }
    }
}

private struct SubjectEditorView: View {
    let subject: Subject?
    let suggestedColorHex: String
    let onSave: (String, String, Bool) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var colorHex: String
    @State private var isArchived: Bool
    @State private var saveError: String?
    @FocusState private var isNameFocused: Bool

    private let palette = [
        SubjectColorChoice(hex: Constants.Color.english, name: "朱色"),
        SubjectColorChoice(hex: Constants.Color.mathematics, name: "瑠璃"),
        SubjectColorChoice(hex: Constants.Color.japanese, name: "紅藤"),
        SubjectColorChoice(hex: Constants.Color.science, name: "緑青"),
        SubjectColorChoice(hex: Constants.Color.socialStudies, name: "菫"),
        SubjectColorChoice(hex: "#D6863A", name: "琥珀"),
        SubjectColorChoice(hex: "#36A7AE", name: "青緑"),
        SubjectColorChoice(hex: "#D56B82", name: "珊瑚"),
        SubjectColorChoice(hex: "#739B45", name: "若草"),
        SubjectColorChoice(hex: "#5967C8", name: "藍"),
        SubjectColorChoice(hex: "#A76A3F", name: "赤銅"),
        SubjectColorChoice(hex: "#5688A8", name: "空色")
    ]

    private var nameValidationError: SubjectNamePolicy.ValidationError? {
        SubjectNamePolicy.validationError(for: name)
    }

    private var nameIsTooLong: Bool {
        guard let nameValidationError else { return false }
        if case .tooLong = nameValidationError { return true }
        return false
    }

    private var nameStatusMessage: String {
        if nameIsTooLong, let nameValidationError {
            return nameValidationError.message
        }
        if SubjectNamePolicy.trimmed(name).isEmpty {
            return "1〜\(SubjectNamePolicy.maximumCharacters)文字で入力してください。"
        }
        return "あと\(SubjectNamePolicy.remainingCharacters(for: name))文字入力できます。"
    }

    init(
        subject: Subject?,
        suggestedColorHex: String,
        onSave: @escaping (String, String, Bool) -> String?
    ) {
        self.subject = subject
        self.suggestedColorHex = suggestedColorHex
        self.onSave = onSave
        _name = State(initialValue: subject?.name ?? "")
        _colorHex = State(initialValue: subject?.colorHex ?? suggestedColorHex)
        _isArchived = State(initialValue: subject?.isArchived ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(SubjectSuggestionCatalog.inputPlaceholder, text: $name)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .focused($isNameFocused)
                        .onSubmit { isNameFocused = false }
                        .accessibilityHint("テーマ名は\(SubjectNamePolicy.maximumCharacters)文字までです")
                } header: {
                    Text("名前")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(nameStatusMessage)
                            .foregroundStyle(nameIsTooLong ? Color.red : PomoGemTheme.muted)
                            .accessibilityLabel(nameStatusMessage)
                        if subject == nil {
                            Text(SubjectSuggestionCatalog.exampleHint)
                                .foregroundStyle(PomoGemTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(SubjectSuggestionCatalog.privacyGuidance)
                                .foregroundStyle(PomoGemTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(SubjectSuggestionCatalog.professionalUseGuidance)
                                .foregroundStyle(PomoGemTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Section("粒の色") {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 64, maximum: 92), spacing: 8)],
                        spacing: 12
                    ) {
                        ForEach(Array(palette.enumerated()), id: \.element.id) { index, choice in
                            Button {
                                colorHex = choice.hex
                            } label: {
                                VStack(spacing: 5) {
                                    Circle()
                                        .fill(Color(hex: choice.hex))
                                        .frame(width: 34, height: 34)
                                        .overlay {
                                            if colorHex == choice.hex {
                                                Circle().stroke(.white, lineWidth: 3).padding(-4)
                                            }
                                        }
                                    Text("\(index + 1) \(choice.name)")
                                        .font(.caption2)
                                        .foregroundStyle(PomoGemTheme.text)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                }
                                .frame(maxWidth: .infinity, minHeight: 60)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PomoGemBareButtonStyle())
                            .accessibilityLabel("色候補\(index + 1)、\(choice.name)")
                            .accessibilityAddTraits(colorHex == choice.hex ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 8)
                }
                if let subject {
                    Section {
                        Toggle("ホームの選択肢に表示", isOn: Binding(
                            get: { !isArchived },
                            set: { isArchived = !$0 }
                        ))
                    } footer: {
                        Text("非表示にしても、\(subject.safeDisplayName)の過去の粒は瓶に残ります。")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(NightBackground())
            .navigationTitle(subject == nil ? "テーマを追加" : "テーマを編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let sanitizedName = SubjectNamePolicy.validated(name) else {
                            saveError = nameValidationError?.message
                                ?? "テーマ名を入力してください。"
                            return
                        }
                        let error = onSave(
                            sanitizedName,
                            colorHex,
                            isArchived
                        )
                        if let error {
                            saveError = error
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(nameValidationError != nil)
                }
            }
            .alert("保存できませんでした", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("閉じる", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }
}

/// Shared with the launch host: the `.datasetRefresh` rescue door hands the
/// user the same export through the same presentation.
struct PomoGemDataExportShareSheet: UIViewControllerRepresentable {
    let fileURL: URL
    let completion: (Error?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
        controller.allowsProminentActivity = true
        controller.completionWithItemsHandler = { _, _, _, error in
            DispatchQueue.main.async {
                completion(error)
            }
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

private struct SubjectColorChoice: Identifiable {
    let hex: String
    let name: String

    var id: String { hex }
}

private extension UIColor {
    var hexString: String {
        guard let components = cgColor.components, components.count >= 3 else { return Constants.Color.textMute }
        let red = Int(round(components[0] * 255))
        let green = Int(round(components[1] * 255))
        let blue = Int(round(components[2] * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
