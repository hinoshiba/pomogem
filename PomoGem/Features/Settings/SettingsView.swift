import Observation
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

enum NotificationPreference: Hashable {
    case dailyReminder
    case wrapped
    case focusReturnReminder
    case focusLeaveNudges
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
    @Environment(\.openURL) private var openURL
    /// Live theme rows only; tombstones never count toward the row bound.
    /// They are complete mutation evidence for a presented theme: a supported
    /// tombstone for its ID would have hidden it.
    @Query private var storedSubjects: [Subject]
    /// Observed so a deletion delivered as a new physical row refreshes the
    /// list; see `SubjectSyncPolicy.presentationSubjects(live:tombstones:context:)`.
    @Query private var storedSubjectTombstones: [Subject]
    @Query private var preferences: [Prefs]
    @Query private var activityResetMarkers: [ActivityResetMarker]

    @AppStorage(AccountScopedLocalState.defaultsKey(base: "notifications.wrapped"))
    private var wrappedNotifications = false
    @AppStorage(FocusActivityPreference.enabledDefaultsKey)
    private var liveActivityEnabled = true
    @AppStorage(FocusReturnReminderPolicy.enabledDefaultsKey)
    private var focusReturnReminderEnabled = false
    /// The two device-local F1 switches, read through `FocusLeavePreferences`
    /// rather than @AppStorage: the default depends on the process (UI tests
    /// opt in) and on the older return-reminder opt-in, and a launch argument
    /// stores the string "NO", which @AppStorage's Bool does not read.
    @State private var focusLeavePauseEnabled = FocusLeavePreferences.isEnabled()
    @State private var focusLeaveNudgesEnabled = FocusLeavePreferences.nudgesAreEnabled()
    /// On because the person chose it, not only by the product default:
    /// only then does the permission notice sit under the switch.
    @State private var focusLeaveNudgesChosen = FocusLeavePreferences.nudgesWereChosen()
    @AppStorage(TimerOrientationPreference.defaultsKey)
    private var defaultTimerOrientationRawValue = TimerDefaultOrientation.automatic.rawValue
    @AppStorage(FocusMusicPreferences.sourceKey)
    private var focusMusicSourceID = ""
    @State private var focusMusic = FocusMusicController.shared
    @State private var isFocusMusicPresented = false
    @State private var purchase = PurchaseManager.shared
    @State private var isSubjectEditorPresented = false
    @State private var editingSubjectID: UUID?
    @State private var subjectPendingDeletion: Subject?
    @State private var subjectPendingDeletionRecordCount: Int?
    @State private var showResetData = false
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
        SubjectSyncPolicy.presentationSubjects(
            live: storedSubjects, tombstones: storedSubjectTombstones, context: modelContext
        )
    }
    private func isCurrentActivity(_ epochID: UUID?) -> Bool {
        ActivityResetPolicy.isCurrent(epochID, markers: resetSnapshots)
    }

    init(persistenceMode: PersistenceLaunchMode = .inMemoryPreview) {
        self.persistenceMode = persistenceMode
        _storedSubjects = Query(SubjectSyncPolicy.liveRowsDescriptor(sortBy: [
            SortDescriptor(\Subject.sortOrder),
            SortDescriptor(\Subject.createdAt),
            SortDescriptor(\Subject.id)
        ]))
        _storedSubjectTombstones = Query(SubjectSyncPolicy.tombstoneRowsDescriptor())

        _preferences = Query(PrefsConsumerPolicy.descriptor())

        _activityResetMarkers = Query(ActivityResetPolicy.currentMarkerDescriptor())
    }

    var body: some View {
        // settings-06. Ordered by what people look for, not by when each
        // feature was built: the timer, then Pro beside the timer it
        // extends, then the other preferences, then everything about the
        // records and iCloud together, then support and the app itself.
        List {
            subjectsSection
            focusSection
            focusLeaveSection
            focusNoticesSection
            proSection
            screenTimeSection
            if RareRewardReleasePolicy.isEnabled {
                rarePebbleSection
            }
            sensorySection
            // 演出の強さ sits with 音と触覚: both are how the app feels on
            // this iPhone, not what it records.
            JarEffectsSettingsSection()
            notificationSection
            shareSection
            // 記録とiCloud: where the records live, moving them, exporting
            // and resetting them.
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
            dataSection
            privacySection
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground())
        .pomogemNavigationTitle(String(localized: "設定", table: "Settings", comment: "Navigation title of the Settings screen"))
        .toolbarTitleDisplayMode(.large)
        .sheet(isPresented: $isSubjectEditorPresented, onDismiss: {
            editingSubjectID = nil
        }) {
            Group {
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
            .environment(\.dynamicTypeSize, dynamicTypeSize)
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
        .sheet(isPresented: $isFocusMusicPresented) {
            // Settings is portrait and no focus runs here, so the sheet is
            // upright and may link to the 「設定」 app (D4.1 applies only
            // while a focus is on screen).
            FocusMusicSheet(controller: focusMusic, allowsLeavingApp: true)
                .modifier(FocusMusicSheetOrientation(isUpsideDown: false))
                .environment(\.dynamicTypeSize, dynamicTypeSize)
        }
        .sheet(isPresented: $showDataExportShareSheet, onDismiss: {
            removePresentedDataExport()
        }) {
            if let dataExportFileURL {
                PomoGemDataExportShareSheet(fileURL: dataExportFileURL) { error in
                    if let error {
                        dataExportError = String(
                            localized: "書き出したファイルを共有できませんでした。\n\(error.localizedDescription)",
                            table: "Settings",
                            comment: "Settings export error; the argument is the system error description"
                        )
                    }
                    showDataExportShareSheet = false
                }
                .systemShareSheetPresentation()
            }
        }
        .sheet(isPresented: $showCompleteDeletionConfirmation) {
            CompleteDataDeletionConfirmationView {
                showCompleteDeletionConfirmation = false
                completeDeletion.startOrRetry()
            }
        }
        .alert(
            String(localized: "テーマを削除", table: "Settings", comment: "Alert title: delete a theme"),
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
            Button(String(
                localized: "「\(subject.safeDisplayName)」を削除",
                table: "Settings",
                comment: "Theme deletion alert button; the argument is the theme name"
            ), role: .destructive) {
                subjectPendingDeletion = nil
                subjectPendingDeletionRecordCount = nil
                deleteSubject(subject)
            }
            Button(String(localized: "キャンセル", table: "Settings", comment: "Alert button"), role: .cancel) {
                subjectPendingDeletion = nil
                subjectPendingDeletionRecordCount = nil
            }
        } message: { subject in
            Text(subjectDeletionMessage(
                for: subject,
                recordCount: subjectPendingDeletionRecordCount ?? 0
            ))
        }
        .alert(String(
            localized: "表示中の記録をリセット",
            table: "Settings",
            comment: "Alert title and Settings button: reset the records shown now (earlier records stay stored)"
        ), isPresented: $showResetData) {
            Button(String(localized: "キャンセル", table: "Settings", comment: "Alert button"), role: .cancel) {}
            Button(String(
                localized: "リセット",
                table: "Settings",
                comment: "Reset confirmation button"
            ), role: .destructive) { resetStudyData() }
        } message: {
            Text(resetDataMessage)
        }
        .alert(String(
            localized: "通知を設定できませんでした",
            table: "Settings",
            comment: "Alert title: a notification setting could not be applied"
        ), isPresented: Binding(
            get: { notificationError != nil },
            set: { if !$0 { notificationError = nil } }
        )) {
            // iOS never asks twice. Once denied, only its Settings can allow it.
            if NotificationManager.shared.authorizationStatus == .denied {
                Button(String(
                    localized: "設定を開く",
                    table: "Settings",
                    comment: "Alert button: open this app's notification settings in iOS"
                )) {
                    openNotificationSettings()
                }
            }
            Button(String(localized: "閉じる", table: "Settings", comment: "Alert button"), role: .cancel) {}
        } message: {
            Text(notificationError ?? "")
        }
        .alert(String(
            localized: "設定を完了できませんでした",
            table: "Settings",
            comment: "Alert title: a setting could not be saved"
        ), isPresented: Binding(
            get: { settingsError != nil },
            set: { if !$0 { settingsError = nil } }
        )) {
            Button(String(localized: "閉じる", table: "Settings", comment: "Alert button"), role: .cancel) {}
        } message: {
            Text(settingsError ?? "")
        }
        .alert(String(
            localized: "データを書き出せませんでした",
            table: "Settings",
            comment: "Alert title and VoiceOver announcement: the data export failed"
        ), isPresented: Binding(
            get: { dataExportError != nil },
            set: { if !$0 { dataExportError = nil } }
        )) {
            Button(String(localized: "閉じる", table: "Settings", comment: "Alert button"), role: .cancel) {}
        } message: {
            Text(dataExportError ?? "")
        }
#if DEBUG
        .overlay(alignment: .topLeading) {
            if LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess {
                Text(verbatim: "Settings render audit probe")
                    .font(.system(size: 1))
                    .foregroundStyle(Color.clear)
                    .frame(width: 1, height: 1)
                    .accessibilityIdentifier("settings.render-audit.probe")
                    .accessibilityLabel(Text(verbatim: "Settings render audit probe"))
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
        .onAppear {
            viewTasks.activate()
            refreshFocusLeaveSwitches()
        }
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
            refreshFocusLeaveSwitches()
            viewTasks.start {
                await refreshViewServices()
            }
        }
        .onChange(of: completionPreviewConfiguration) { _, _ in
            completionPreview.cancel()
        }
        .onChange(of: router.settingsCustomDurationResumeRequested) { _, requested in
            // Set from the paywall sheet's onDismiss, so presenting the
            // editor here never collides with the closing paywall.
            guard requested, router.consumeSettingsCustomDurationResumeRequest(),
                  purchase.isPro else { return }
            showCustomDuration = true
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
            settingsError = String(
                localized: "ランダムなレア粒の設定を\(storageDestination)へ保存できませんでした。しばらく待ってから、もう一度お試しください。",
                table: "Settings",
                comment: "Settings error; the argument is where settings are saved (this iPhone or iCloud)"
            )
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
            settingsError = String(
                localized: "ランダムなレア粒の設定を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)",
                table: "Settings",
                comment: "Settings error; the argument is the system error description"
            )
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
                            Text(
                                "非表示",
                                tableName: "Settings",
                                comment: "Badge on a theme row: the theme is hidden from Home (English: Hidden)"
                            ).font(.caption).foregroundStyle(PomoGemTheme.muted)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(PomoGemTheme.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PomoGemRowButtonStyle())
                .accessibilityHint(
                    subjects.count > 1
                        ? String(
                            localized: "ダブルタップで編集。アクションで順番を変更できます",
                            table: "Settings",
                            comment: "VoiceOver hint of a theme row when it can be reordered with the Move Up/Move Down actions"
                        )
                        : String(localized: "ダブルタップで編集できます", table: "Settings", comment: "VoiceOver hint of a theme row")
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
                    Button(subject.isArchived
                        ? String(
                            localized: "表示",
                            table: "Settings",
                            comment: "Swipe action on a hidden theme: show it on Home again (English: Show)"
                        )
                        : String(
                            localized: "settings.themes.swipe.hide",
                            defaultValue: "非表示",
                            table: "Settings",
                            comment: "Swipe action on a theme: hide it from Home (English: Hide). Same Japanese as the Hidden badge, different English."
                        )) {
                        do {
                            subject.isArchived.toggle()
                            try SubjectSyncPolicy.recordUserMutation(
                                from: subject,
                                among: storedSubjects
                            )
                            try modelContext.save()
                        } catch {
                            modelContext.rollback()
                            settingsError = String(
                                localized: "テーマの表示設定を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)",
                                table: "Settings",
                                comment: "Settings error; the argument is the system error description"
                            )
                        }
                    }
                    .tint(PomoGemTheme.raised)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(String(localized: "削除", table: "Settings", comment: "Swipe action on a theme: delete it"), role: .destructive) {
                        prepareSubjectDeletion(subject)
                    }
                }
            }
            .onMove(perform: moveSubjects)

            Button {
                editingSubjectID = nil
                isSubjectEditorPresented = true
            } label: {
                Label(String(localized: "テーマを追加", table: "Settings", comment: "Button and editor title: add a theme"), systemImage: "plus")
            }
            .disabled(subjects.count >= Constants.App.maximumSubjects)
            .accessibilityHint(
                subjects.count >= Constants.App.maximumSubjects
                    ? String(
                        localized: "最大12件です。不要な項目を削除すると追加できます",
                        table: "Settings",
                        comment: "VoiceOver hint of the disabled Add Theme button: the 12-theme limit is reached"
                    )
                    : String(localized: "新しいテーマを追加します", table: "Settings", comment: "VoiceOver hint of the Add Theme button")
            )
        } header: {
            Text("テーマ", tableName: "Settings", comment: "Settings section header: the person's themes")
        } footer: {
            Text(
                "勉強も仕事も同じ一覧です。最大12件。追加画面には名前のヒントがあります。削除しても過去の質量と記録は残ります。長押しで順番を変更できます。",
                tableName: "Settings",
                comment: "Settings footer under the theme list"
            )
        }
    }

    private var focusSection: some View {
        Section(String(localized: "集中", table: "Settings", comment: "Settings section header: timer settings (English: Focus)")) {
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
                            // settings-08. Buying reopens this editor, as
                            // it does from Home.
                            router.presentPaywall(
                                from: .customTimer,
                                pendingIntent: .settingsCustomDuration
                            )
                        }
                    }
                )

                NavigationLink {
                    TimerDisplayModeSelectionView(selection: timerDisplayModeBinding)
                } label: {
                    SettingLabel(
                        title: String(
                            localized: "集中タイマーの表示",
                            table: "Settings",
                            comment: "Settings row: how the focus timer shows the time left"
                        ),
                        subtitle: resolvedPreferences.timerDisplayMode.title,
                        symbol: "circle.dotted"
                    )
                }
                .accessibilityIdentifier("settings.timer-display-mode")
                .accessibilityHint(Text("4つの見本から、タイマーの見た目を選べます", tableName: "Settings", comment: "VoiceOver hint of the timer display row"))
            }
            NavigationLink {
                TimerDefaultOrientationSettingsView(selection: Binding(
                    get: { TimerDefaultOrientation(rawValue: defaultTimerOrientationRawValue) ?? .automatic },
                    set: { defaultTimerOrientationRawValue = $0.rawValue }
                ))
            } label: {
                SettingLabel(
                    title: String(
                        localized: "タイマーの既定の向き",
                        table: "Settings",
                        comment: "Settings row and page title: the orientation new timers open in"
                    ),
                    subtitle: (TimerDefaultOrientation(rawValue: defaultTimerOrientationRawValue) ?? .automatic).title,
                    symbol: "rotate.right"
                )
            }
            .accessibilityIdentifier("settings.timer-default-orientation")
            .accessibilityHint(Text(
                "新しい集中・休憩タイマーを開く向きを選べます",
                tableName: "Settings",
                comment: "VoiceOver hint of the default timer orientation row"
            ))

            if let resolvedPreferences {
                Toggle(isOn: settingBinding(
                    .keepScreenAwake,
                    currentValue: resolvedPreferences.keepScreenAwake,
                    update: { $0.keepScreenAwake = $1 }
                )) {
                    SettingLabel(
                        title: String(
                            localized: "タイマー中は画面をロックしない",
                            table: "Settings",
                            comment: "Settings switch: keep the screen from auto-locking while a timer is on screen"
                        ),
                        subtitle: String(localized: "集中・休憩のタイマー画面を開いている間だけ有効", table: "Settings", comment: "Settings switch subtitle"),
                        symbol: "sun.max"
                    )
                }
                .accessibilityIdentifier("settings.keep-screen-awake")
            }

            focusMusicRow
        }
    }

    /// F4 (Docs/FocusMusic.md). The same sheet as the timer's music note,
    /// named by the chosen music. No focus runs behind Settings, so the
    /// sheet may offer the 「設定」 app when access was denied. Showing the
    /// row asks nothing and reads no subscription or catalog; the sheet does
    /// that when it opens.
    private var focusMusicRow: some View {
        Button {
            isFocusMusicPresented = true
        } label: {
            HStack(spacing: 8) {
                SettingLabel(
                    title: focusMusicRowTitle,
                    subtitle: focusMusicRowValue,
                    symbol: "music.note"
                )
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PomoGemBareButtonStyle())
        .accessibilityLabel(Text(verbatim: focusMusicRowTitle))
        .accessibilityValue(Text(verbatim: focusMusicRowValue))
        .accessibilityHint(Text(
            "ミュージックアプリで再生する集中用の音楽を選べます",
            tableName: "Settings",
            comment: "VoiceOver hint of the Settings focus music row: it opens the Apple Music list"
        ))
        .accessibilityIdentifier("settings.focus-music")
    }

    private var focusMusicRowTitle: String {
        String(
            localized: "集中用の音楽",
            table: "Settings",
            comment: "Settings row: opens the focus music (Apple Music) list; same name as the timer's music sheet"
        )
    }

    /// The chosen music's catalog title once the sheet has read it, else our
    /// Japanese label (`FocusMusicController.title(for:)`).
    private var focusMusicRowValue: String {
        if let source = FocusMusicCatalog.source(id: focusMusicSourceID) {
            return focusMusic.title(for: source)
        }
        return String(
            localized: "未選択",
            table: "Settings",
            comment: "Settings focus music row value when no music is chosen yet (English: Not selected)"
        )
    }

    /// F1, owner-requested change 2026-09-26: whether leaving the app pauses
    /// a running focus, and the bounded 「集中が切れています」 series that
    /// says so. Both switches are device-local and on by default
    /// (`FocusLeavePolicy.enabledByDefault`). The footer says plainly what a
    /// lock does with and without a passcode, and that only 再開する resumes;
    /// it is worded to stay true with the switch on or off. No header: it
    /// continues 「集中」.
    private var focusLeaveSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { focusLeavePauseEnabled },
                set: { updateFocusLeavePause(enabled: $0) }
            )) {
                SettingLabel(
                    title: String(
                        localized: "アプリを離れたら一時停止",
                        table: "Settings",
                        comment: "Settings switch title: pause a running focus when the person goes to the Home Screen or another app. Suggested English: Pause When You Leave the App"
                    ),
                    subtitle: String(
                        localized: "ホーム画面やほかのアプリへ移ると止めます",
                        table: "Settings",
                        comment: "Settings switch subtitle: what counts as leaving the app. Suggested English: Stops when you go Home or open another app"
                    ),
                    symbol: "pause.circle"
                )
            }
            .accessibilityIdentifier("settings.focus-leave-pause")

            // The series only exists while the leave pause does; with it off,
            // 集中に戻るお知らせ below behaves as before.
            if focusLeavePauseEnabled {
                Toggle(isOn: Binding(
                    get: { focusLeaveNudgesEnabled },
                    set: { updateFocusLeaveNudges(enabled: $0) }
                )) {
                    SettingLabel(
                        title: String(
                            localized: "集中が切れたらお知らせ",
                            table: "Settings",
                            comment: "Settings switch title: the notifications sent while a focus is paused because the person left the app. Suggested English: Notify Me When I Drift Away"
                        ),
                        subtitle: focusLeaveNudgeSubtitle,
                        symbol: "bell.badge"
                    )
                }
                .accessibilityIdentifier("settings.focus-leave-nudges")

                // Like every notification row, the notice answers an intent
                // the person expressed. Under the product default alone the
                // footer says, without a call to action, that nothing arrives
                // without permission.
                if focusLeaveNudgesEnabled, focusLeaveNudgesChosen {
                    notificationPermissionStatus(identifier: "settings.focus-leave-nudges-permission")
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "オンのとき、集中タイマー中にホーム画面やほかのアプリへ移ると、離れた時点でタイマーを一時停止します。\(focusLeaveGraceText)以内に戻れば止まりません。パスコードを設定しているiPhoneでは、画面をロックしても、通常はタイマーが進みます。ただし、ロックを解除した直後にまたロックすると一時停止したり、ほかのアプリへ移ってすぐにロックすると止まらなかったりすることがあります。パスコードがないiPhoneでは、ロックとアプリの切り替えを区別できないため、画面ロックでも一時停止します。",
                    tableName: "Settings",
                    comment: "Settings footer under the leave-pause switch. The argument is the quick-glance grace (20秒). The lock is recognised from a notice iOS sends late right after an unlock, so both lock sentences are hedged; keep them hedged. Suggested English: When on, going Home or to another app during a focus pauses the timer from the moment you left. Coming back within %@ does not pause it. On an iPhone with a passcode, locking the screen usually keeps the timer running. However, locking again right after unlocking can pause it, and locking right after leaving the app can keep it running. Without a passcode, iPhone cannot tell locking from switching apps, so locking also pauses it."
                )
                .accessibilityIdentifier("settings.focus-leave-footer.behavior")
                Text(
                    "自動では再開しません。アプリに戻って「再開する」をタップすると、離れた時点の続きから進みます。休憩中と、終了まで\(focusLeaveFinalStretchText)以内の集中は止めません。オフのときは、アプリを離れてもタイマーは止まりません。",
                    tableName: "Settings",
                    comment: "Settings footer under the leave-pause switch: how the timer resumes, what is never paused, and the off state. The argument is the final stretch that is never paused (1分). Suggested English: The timer never resumes by itself. Go back to the app and tap Resume to continue from where you left. Breaks and the last %@ of a focus are never paused. When off, the timer keeps running after you leave the app."
                )
                .accessibilityIdentifier("settings.focus-leave-footer.resume")
                if focusLeavePauseEnabled {
                    Text(
                        "「集中が切れたらお知らせ」は、タイマーが止まっていることを知らせる通知で、アプリに戻ると残りは届きません。このiPhoneで通知を許可していない場合は届きません。「アプリを離れたら一時停止」がオンのあいだは、「集中に戻るお知らせ」の代わりにこちらを使います。",
                        tableName: "Settings",
                        comment: "Settings footer under the leave-pause notification switch; it replaces the older Return-to-Focus Reminder while the leave pause is on. The switch is on by default, so the permission sentence is a plain fact with no call to action. Suggested English: These notifications say the timer is paused, and the rest are withdrawn when you come back. They do not arrive unless notifications are allowed on this iPhone. While Pause When You Leave the App is on, they replace the Return-to-Focus Reminder."
                    )
                    .accessibilityIdentifier("settings.focus-leave-footer.nudges")
                }
            }
        }
    }

    /// 「離れてから20分までに最大5回」, from the policy's own offsets.
    private var focusLeaveNudgeSubtitle: String {
        let offsets = FocusLeavePolicy.nudgeOffsets
        let lastOffset = DurationText.short(
            seconds: Int(offsets.last ?? 0),
            units: .minutesSeconds
        )
        // The count is its own phrase so English can pluralize it: a
        // two-argument sentence would need a plural substitution.
        let count = String(
            localized: "settings.focus-leave.nudge-count",
            defaultValue: "\(offsets.count)回",
            table: "Settings",
            comment: "How many leave-pause notifications at most (5), inside the switch subtitle. English: '%lld notification' / '%lld notifications'."
        )
        return String(
            localized: "離れてから\(lastOffset)までに最大\(count)",
            table: "Settings",
            comment: "Settings switch subtitle for the leave-pause notifications. The first argument is when the series stops after leaving (20分), the second how many notifications at most (5回). Suggested English: Up to %2$@ within %1$@ of leaving"
        )
    }

    private var focusLeaveGraceText: String {
        DurationText.short(
            seconds: Int(FocusLeavePolicy.lockDetectionWindow),
            units: .minutesSeconds
        )
    }

    private var focusLeaveFinalStretchText: String {
        DurationText.short(
            seconds: Int(FocusLeavePolicy.minimumRemaining),
            units: .minutesSeconds
        )
    }

    /// settings-06. The switches that reach beyond the timer screen, with
    /// their explanations as the card's footer instead of caption rows
    /// between the switches. No header: it continues 「集中」. While the
    /// leave pause is on, 集中に戻るお知らせ is superseded (the host never
    /// books it), so its row and caption are hidden rather than left to
    /// contradict 「集中が切れたらお知らせ」 above.
    private var focusNoticesSection: some View {
        Section {
            Toggle(isOn: $liveActivityEnabled) {
                SettingLabel(
                    title: String(
                        localized: "画面を閉じてもタイマーを表示",
                        table: "Settings",
                        comment: "Settings switch: show the timer as a Live Activity outside the app"
                    ),
                    // Neutral on purpose: most supported iPhones have no Dynamic
                    // Island, and the Live Activity appears there too when one exists.
                    subtitle: String(
                        localized: "ロック画面などに残り時間・進捗を表示",
                        table: "Settings",
                        comment: "Settings row subtitle: where the Live Activity timer appears"
                    ),
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

            if !focusLeavePauseEnabled {
                Toggle(isOn: Binding(
                    get: { focusReturnReminderEnabled },
                    set: { updateFocusReturnReminder(enabled: $0) }
                )) {
                    SettingLabel(
                        title: String(
                            localized: "集中に戻るお知らせ",
                            table: "Settings",
                            comment: "Settings switch: one notification after leaving the app during a focus (glossary: Return-to-Focus Reminder)"
                        ),
                        subtitle: String(localized: "アプリを離れて30秒後に一度通知", table: "Settings", comment: "Settings switch subtitle"),
                        symbol: "bell.badge"
                    )
                }
                .accessibilityIdentifier("settings.focus-return-reminder")

                if focusReturnReminderEnabled {
                    notificationPermissionStatus(identifier: "settings.focus-return-permission")
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                // True with the leave pause on or off: whether the timer
                // stops in the background is the switch above's to say.
                Text(
                    "画面を閉じたときの表示は、iPhoneの設定でライブアクティビティを許可している場合に出ます。アプリを離れたときにタイマーを止めるかどうかは、「アプリを離れたら一時停止」の設定に従います。",
                    tableName: "Settings",
                    comment: "Settings footer: the Live Activity switch. Suggested English: The Lock Screen timer appears when Live Activities are allowed in iPhone Settings. Whether the timer stops when you leave the app follows Pause When You Leave the App."
                )
                .accessibilityIdentifier("settings.live-activity-footer")
                if !focusLeavePauseEnabled {
                    Text(
                        "「集中に戻るお知らせ」は既定でオフです。オンにすると、集中タイマー中にホーム画面や別のアプリへ移ったとき、30秒後に一度通知し、戻ると取り消します。画面をロックしただけなら通知しません（パスコードを使っていないiPhoneなどでは届くことがあります）。一時停止中・休憩中・終了間際も通知しません。",
                        tableName: "Settings",
                        comment: "Settings caption under the return-to-focus reminder switch"
                    )
                }
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
                SettingLabel(
                    title: String(localized: "音", table: "Settings", comment: "Settings switch: sound effects"),
                    subtitle: String(
                        localized: "サイレントスイッチに従います",
                        table: "Settings",
                        comment: "Settings switch subtitle: sound follows the Ring/Silent switch"
                    ),
                    symbol: "speaker.wave.2"
                )
            }

            Picker(selection: timerCompletionSoundBinding) {
                ForEach(TimerCompletionSound.allCases) { style in
                    Text(style.title)
                        .tag(style)
                        .accessibilityLabel(String(
                            localized: "\(style.title)。\(style.detail)",
                            table: "Settings",
                            comment: "VoiceOver label of a picker option: its name, then its description"
                        ))
                        .accessibilityIdentifier(
                            "settings.completion-sound.\(style.rawValue)"
                        )
                }
            } label: {
                SettingLabel(
                    title: String(localized: "タイマー終了音", table: "Settings", comment: "Settings picker: the sound played when a timer ends"),
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
                    title: String(localized: "触覚", table: "Settings", comment: "Settings switch: haptics"),
                    subtitle: RareRewardReleasePolicy.isEnabled
                        ? String(
                            localized: "アプリ内の完了・着地・瓶操作。レア専用は標準モードのみ",
                            table: "Settings",
                            comment: "Haptics subtitle while rare gems exist"
                        )
                        : String(localized: "アプリ内の完了・着地・瓶操作に使います", table: "Settings", comment: "Haptics subtitle"),
                    symbol: "waveform"
                )
            }

            Picker(selection: timerCompletionHapticBinding) {
                ForEach(TimerCompletionHaptic.allCases) { style in
                    Text(style.title)
                        .tag(style)
                        .accessibilityLabel(String(
                            localized: "\(style.title)。\(style.detail)",
                            table: "Settings",
                            comment: "VoiceOver label of a picker option: its name, then its description"
                        ))
                        .accessibilityIdentifier(
                            "settings.completion-haptic.\(style.rawValue)"
                        )
                }
            } label: {
                SettingLabel(
                    title: String(
                        localized: "タイマー終了時の触覚",
                        table: "Settings",
                        comment: "Settings picker: the haptic played when a timer ends"
                    ),
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
            Text("音と触覚", tableName: "Settings", comment: "Settings section header")
        } footer: {
            Text(
                "アプリを開いている間にタイマーが終わったときは、終了音と触覚を停止操作まで繰り返します。通知で知らせたあとや、あとからアプリに戻ったときは繰り返さず、そのまま記録を表示します。音はサイレントモードに従います。通知を許可している場合、ロック中は1回の通知となり、音と触覚はiPhoneの通知設定に従います。",
                tableName: "Settings",
                comment: "Settings footer under Sound & Haptics"
            )
        }
    }

    /// 「20回続けて」: its own phrase so English can pluralize the count.
    private var goldPityMisses: String {
        String(
            localized: "settings.rare.pity-misses",
            defaultValue: "\(Constants.Gacha.pityMissCount)回続けて",
            table: "Settings",
            comment: "How many draws in a row without gold guarantee the next one (20), inside the gold gem detail. English: '%lld miss in a row' / '%lld misses in a row'."
        )
    }

    private var rarePebbleSection: some View {
        Section {
            Text(
                "粒のバリエーション",
                tableName: "Settings",
                comment: "Settings section header: rare gem kinds (feature disabled in shipping builds)"
            )
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
                    title: String(localized: "ランダムなレア粒", table: "Settings", comment: "Settings picker: random rare gems"),
                    subtitle: hasExplicitRareRewardSelection
                        ? rareRewardMode.settingsDescription
                        : String(
                            localized: "未選択のため抽選しません。最初の実測タイマー前にも選べます",
                            table: "Settings",
                            comment: "Rare gem picker subtitle before a choice is saved"
                        ),
                    symbol: rareRewardMode.systemImage
                )
            }
            .pickerStyle(.navigationLink)
            .disabled(resolvedPreferences == nil)
            .accessibilityIdentifier("settings.rare-reward-mode")
            .accessibilityHint(Text(
                "質量、融合、結晶、成果、機能は変わりません。オフでは抽選用の端数と金の保証カウントを停止します",
                tableName: "Settings",
                comment: "VoiceOver hint of the rare gem picker"
            ))

            if !hasExplicitRareRewardSelection {
                Button {
                    updateRareRewardMode(.off)
                } label: {
                    Label {
                        Text(
                            "「\(RareRewardMode.off.title)」を選択として保存",
                            tableName: "Settings",
                            comment: "Button: save the rare gem picker's off option as an explicit choice; the argument is that option's name"
                        )
                    } icon: {
                        Image(systemName: "checkmark.shield.fill")
                            .accessibilityHidden(true)
                    }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(PomoGemBareButtonStyle())
                .foregroundStyle(PomoGemTheme.amber)
                .disabled(resolvedPreferences == nil)
                .accessibilityHint(String(
                    localized: "乱数、抽選用の端数、金の保証カウントを動かさない選択を\(storageDestination)へ保存します",
                    table: "Settings",
                    comment: "VoiceOver hint; the argument is where settings are saved (this iPhone or iCloud)"
                ))
                .accessibilityIdentifier("settings.rare-reward-confirm-off")
            }

            RarePebbleGuideRow(
                kind: .normal,
                title: String(localized: "いつもの粒", table: "Settings", comment: "Rare gem guide row: the regular gem"),
                detail: String(localized: "全モードで同じ質量・結晶進捗", table: "Settings", comment: "Rare gem guide row detail")
            )
            RarePebbleGuideRow(
                kind: .gold,
                title: String(localized: "金の粒", table: "Settings", comment: "Rare gem guide row: the gold gem"),
                detail: rareRewardMode == .off
                    ? String(localized: "オフ中は新しく抽選しません", table: "Settings", comment: "Rare gem guide row detail while draws are off")
                    : String(
                        localized: "自然抽選 \(GachaEngine.probabilityLabel(for: .gold))。\(goldPityMisses)出なければ、次の抽選で保証",
                        table: "Settings",
                        comment: "Gold gem guide row detail. The first argument is the natural odds (5%), the second how many misses in a row guarantee gold (20回続けて)"
                    )
            )
            RarePebbleGuideRow(
                kind: .prism,
                title: String(localized: "虹の粒", table: "Settings", comment: "Rare gem guide row: the rainbow gem"),
                detail: rareRewardMode == .off
                    ? String(localized: "オフ中は新しく抽選しません", table: "Settings", comment: "Rare gem guide row detail while draws are off")
                    : String(
                        localized: "自然抽選 \(GachaEngine.probabilityLabel(for: .prism))",
                        table: "Settings",
                        comment: "Rainbow gem guide row detail; the argument is the natural odds (1%)"
                    )
            )
        } footer: {
            Text(
                "自然確率は、いつもの粒 \(GachaEngine.probabilityLabel(for: .normal))、金 \(GachaEngine.probabilityLabel(for: .gold))、虹 \(GachaEngine.probabilityLabel(for: .prism))。標準と控えめでは、実測タイマーで250g積むごとに1回抽選し、250g未満の端数は次回へ繰り越します。10分を6回、25分を2回と10分を1回、60分を1回はいずれも600gなので、抽選2回と100gの端数で同じです。\(GachaEngine.goldGuaranteeDisclosure) 控えめは種類を履歴に残しますが、追加の発光・専用音・専用触覚を使いません。抽選しない間は乱数を使わず、その間の質量を抽選用に貯めません。既存の端数と金の保証は同じ位置で停止し、標準または控えめに戻すとそこから再開します。どのモードでも質量・融合・結晶・成果・機能は同じで、既に獲得した金・虹、記録、シェアも変わりません。端末の「視差効果を減らす」は抽選を止めず、動きだけを抑えます。",
                tableName: "Settings",
                comment: "Rare gem section footer. Arguments 1-3 are the natural odds of the regular, gold and rainbow gem; argument 4 is the gold guarantee sentence (Models table)"
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
                    SettingLabel(
                        title: String(
                            localized: "毎日のリマインダー",
                            table: "Settings",
                            comment: "Settings switch title: the opt-in daily reminder"
                        ),
                        subtitle: Constants.UIStrings.eveningNotification,
                        symbol: "bell"
                    )
                }
                .accessibilityIdentifier("settings.daily-reminder")

                // The notice sits under the first switch that is on, so it is
                // never read as a note about a switch that is off.
                if resolvedPreferences.reminderEnabled {
                    notificationPermissionStatus(identifier: "settings.notification-permission")
                }

                Toggle(isOn: Binding(
                    get: { wrappedNotifications },
                    set: { enabled in updateWrappedNotification(enabled: enabled) }
                )) {
                    // Wrapped looks back at the month that just ended.
                    SettingLabel(
                        title: String(
                            localized: "先月の瓶のお知らせ",
                            table: "Settings",
                            comment: "Settings switch title: the opt-in monthly look-back notification"
                        ),
                        subtitle: String(
                            localized: "毎月1日に一度だけ",
                            table: "Settings",
                            comment: "Settings switch subtitle: the monthly notification is sent on the 1st"
                        ),
                        symbol: "circle.grid.3x3.fill"
                    )
                }
                .accessibilityIdentifier("settings.wrapped-notification")

                if wrappedNotifications, !resolvedPreferences.reminderEnabled {
                    notificationPermissionStatus(identifier: "settings.notification-permission")
                }

                if resolvedPreferences.reminderEnabled || wrappedNotifications {
                    // One shared time for both notifications, so it stays
                    // visible and editable while either one is on.
                    DatePicker(
                        String(localized: "通知する時刻", table: "Settings", comment: "Settings time picker label for reminders"),
                        selection: reminderTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                    .accessibilityIdentifier("settings.reminder-time")

                    VStack(alignment: .leading, spacing: 6) {
                        if resolvedPreferences.reminderEnabled {
                            Text(
                                "その日に集中を始めたり、時間を手動で積んだりした日は、毎日のリマインダーは届きません。7日間アプリを開かなかったときは、次に開くまでお休みします。",
                                tableName: "Settings",
                                comment: "Settings caption: when the daily reminder is skipped"
                            )
                        }
                        if wrappedNotifications {
                            Text(
                                "先月の瓶のお知らせは、毎月1日のこの時刻に届きます。前の月に記録がなければ届きません。",
                                tableName: "Settings",
                                comment: "Settings caption: when the monthly look-back notification is sent"
                            )
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.reminder-rules")
                }
            }
        } header: {
            Text("通知", tableName: "Settings", comment: "Settings section header: notifications")
        } footer: {
            // Scoped to this card's switches: 「集中が切れたらお知らせ」
            // (F1, above) is on by default.
            Text(
                "「毎日のリマインダー」と「先月の瓶のお知らせ」は既定でオフです。赤いバッジや連続記録の警告は使いません。タイマー終了の通知だけは「即時通知」として送るため、iPhoneの集中モード（おやすみモードなど）で即時通知を許可していれば、その間も届きます。",
                tableName: "Settings",
                comment: "Settings footer under the Notifications card. The default-off sentence names only this card's two switches, because the leave-pause notifications in the Focus card are on by default. Suggested English: Daily Reminder and Last Month's Jar are off by default. The app never uses red badges or streak warnings. Only timer-end alerts are sent as Time Sensitive, so they still arrive during a Focus such as Do Not Disturb if Time Sensitive notifications are allowed there."
            )
            .accessibilityIdentifier("settings.notifications-footer")
        }
    }

    private var shareSection: some View {
        Section(String(localized: "シェア", table: "Settings", comment: "Settings section header: sharing")) {
            if let resolvedPreferences {
                Toggle(isOn: settingBinding(
                    .shareIncludesManual,
                    currentValue: resolvedPreferences.shareIncludesManual,
                    update: { $0.shareIncludesManual = $1 }
                )) {
                    SettingLabel(title: String(localized: "自己申告を含める", table: "Settings", comment: "Settings switch: include self-reported gems in shares"), subtitle: String(localized: "既定は実測のみ", table: "Settings", comment: "Settings switch subtitle: shares include only timed gems by default"), symbol: "square.and.arrow.up")
                }
            }
        }
    }

    private var screenTimeSection: some View {
        Section(String(localized: "アプリの利用時間", table: "Settings", comment: "Settings section header above the Screen Time row")) {
            NavigationLink {
                ScreenTimeSettingsView()
            } label: {
                ScreenTimeSettingsRowLabel()
            }
            .accessibilityIdentifier("settings.screen-time")
        }
    }

    /// settings-06. Right after the timer settings, where its 「カスタム」
    /// tile already points to it. A row, never a banner.
    private var proSection: some View {
        Section {
            Button {
                router.presentPaywall(from: .settings)
            } label: {
                HStack(spacing: 14) {
                    // Decorative: for Pro users the seal would read the row
                    // as 「選択済み」; 「利用中」 already says it.
                    Image(systemName: purchase.isPro ? "checkmark.seal.fill" : "sparkles")
                        .foregroundStyle(PomoGemTheme.amber)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Constants.UIStrings.paywallTitle).font(.headline)
                        Text(proRowSubtitle)
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(PomoGemTheme.muted)
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(PomoGemBareButtonStyle())
            .accessibilityIdentifier("settings.pro")
        } footer: {
            if !purchase.isPro {
                Text(
                    "Proは1回だけの買い切りです。記録・テーマ・iCloud同期・シェアなど、ほかの機能は無料で使えます。",
                    tableName: "Settings",
                    comment: "Settings footer under the Pro row for free users"
                )
            }
        }
    }

    private var proRowSubtitle: String {
        if purchase.isPro { return String(
            localized: "利用中",
            table: "Settings",
            comment: "Pro row subtitle and support mail value: Pro is owned"
        ) }
        // settings-05. A request out for approval (Ask to Buy) is visible
        // here too, not only inside the paywall.
        if purchase.isAwaitingApproval() {
            return String(
                localized: "承認待ち・承認されると自動で使えます",
                table: "Settings",
                comment: "Settings Pro row subtitle while a purchase request awaits approval"
            )
        }
        return String(
            localized: "自由な集中時間・結晶の月刻印・勉強アプリ数の無制限",
            table: "Settings",
            comment: "Settings Pro row subtitle for free users: what Pro adds"
        )
    }

    /// settings-06. The storage row that used to open this section repeated
    /// 「iCloudとデバイス」 above and did nothing when tapped; what it said
    /// is now the footer, in plain words.
    private var privacySection: some View {
        Section {
            // settings-07. Support used to be web pages only, and the site
            // asks people to type their iOS and app versions by hand.
            Button(action: composeSupportMail) {
                SettingLabel(
                    title: String(localized: "メールで問い合わせる", table: "Settings", comment: "Settings row: write to support by mail"),
                    subtitle: String(
                        localized: "アプリのバージョンなどを自動で記入します",
                        table: "Settings",
                        comment: "Settings row subtitle: the mail draft is pre-filled with versions and settings"
                    ),
                    symbol: "envelope"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PomoGemBareButtonStyle())
            .accessibilityIdentifier("settings.support-mail")
            Link(destination: AppLinks.support) {
                SettingLabel(
                    title: String(localized: "サポートページ", table: "Settings", comment: "Settings row: the support web page"),
                    subtitle: String(
                        localized: "購入・返金の案内など（Webで開く）",
                        table: "Settings",
                        comment: "Settings row subtitle: what the support web page covers"
                    ),
                    symbol: "questionmark.circle"
                )
            }
            // product-08. Only ever a row the person chooses; the automatic
            // review prompt keeps its own gate (10 completions over 7 days).
            Link(destination: AppLinks.appStoreWriteReview) {
                SettingLabel(
                    title: String(localized: "App Storeで評価・レビューする", table: "Settings", comment: "Settings row: rate or review the app"),
                    subtitle: String(localized: "App Storeを開きます", table: "Settings", comment: "Settings row subtitle: opens the App Store"),
                    symbol: "star.bubble"
                )
            }
            .accessibilityIdentifier("settings.write-review")
            Link(destination: AppLinks.privacyPolicy) {
                SettingLabel(
                    title: String(localized: "プライバシーポリシー", table: "Settings", comment: "Settings row: the privacy policy web page"),
                    subtitle: String(localized: "Webで開く", table: "Settings", comment: "Settings row subtitle: opens a web page"),
                    symbol: "doc.text"
                )
            }
        } header: {
            Text("サポートとプライバシー", tableName: "Settings", comment: "Settings section header")
        } footer: {
            Text(persistenceMode == .localOnly
                 ? String(
                     localized: "記録はこのiPhoneにだけ保存されます。開発者が記録を受け取ることはありません。",
                     table: "Settings",
                     comment: "Settings privacy footer when records stay on this iPhone"
                 )
                 : String(
                     localized: "記録はあなたのiCloudに保存されます。開発者が記録を受け取ることはありません。",
                     table: "Settings",
                     comment: "Settings privacy footer in iCloud mode"
                 ))
            .accessibilityIdentifier("settings.privacy-footer")
        }
    }

    /// Opens a mail draft; with no mail app to take it (Mail deleted, no
    /// account), the support page, which has the address and the FAQ.
    private func composeSupportMail() {
        let diagnostics = SupportMailDiagnostics.current(
            persistenceMode: persistenceMode,
            isCloudOfflineSession: isCloudOfflineSession,
            purchase: purchase
        )
        guard let mail = SupportMailDraft.url(for: diagnostics) else {
            openURL(AppLinks.support)
            return
        }
        openURL(mail) { accepted in
            if !accepted { openURL(AppLinks.support) }
        }
    }

    private var aboutSection: some View {
        Section {
            NavigationLink {
                AboutAppView()
            } label: {
                SettingLabel(
                    title: String(localized: "このアプリについて", table: "Settings", comment: "Settings row: the About page"),
                    subtitle: String(
                        localized: "バージョン \(AppVersionText.current)・クレジット・ライセンス",
                        table: "Settings",
                        comment: "Settings About row subtitle; the argument is the version, e.g. 1.1.0 (10)"
                    ),
                    symbol: "info.circle"
                )
            }
            .accessibilityIdentifier("settings.about")
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

    private var dataSection: some View {
        Section {
            Button(action: startDataExport) {
                HStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(PomoGemTheme.specular)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("データを書き出す", tableName: "Settings", comment: "Settings row and VoiceOver label: export all records as a file")
                            .font(.headline)
                        Text(dataExportSubtitle)
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
            .accessibilityLabel(Text(
                "データを書き出す",
                tableName: "Settings",
                comment: "Settings row and VoiceOver label: export all records as a file"
            ))
            // The fixed label hides the subtitle from VoiceOver; say it as
            // the value so the no-import fact is heard too (settings-09).
            .accessibilityValue(dataExportSubtitle)
            .accessibilityHint(Text(
                "この端末で利用可能な記録、テーマ、設定をJSONファイルにして、保存先を選びます",
                tableName: "Settings",
                comment: "VoiceOver hint of the export row"
            ))

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

                Button(String(localized: "書き出しをキャンセル", table: "Settings", comment: "Button: cancel a running data export"), role: .cancel) {
                    cancelDataExport(announce: true)
                }
            }

            Button(String(
                localized: "表示中の記録をリセット",
                table: "Settings",
                comment: "Alert title and Settings button: reset the records shown now (earlier records stay stored)"
            ), role: .destructive) { showResetData = true }
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
                            Text(
                                "ユーザー内容を削除",
                                tableName: "Settings",
                                comment: "Complete data deletion: row, sheet title and final button (glossary: Delete Your Content)"
                            )
                                .font(.headline)
                            Text("端末とiCloudの内容（削除世代記録を除く）", tableName: "Settings", comment: "Complete data deletion row subtitle")
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
                .accessibilityHint(Text(
                    "二段階の確認画面を開きます。この操作は取り消せません",
                    tableName: "Settings",
                    comment: "VoiceOver hint of the complete data deletion row"
                ))
            }

            if persistenceMode != .localOnly,
               case let .failed(phase, message) = completeDeletion.status {
                VStack(alignment: .leading, spacing: 8) {
                    Label(String(
                        localized: "削除は未完了です",
                        table: "Settings",
                        comment: "Complete data deletion status: it has not finished"
                    ), systemImage: "exclamationmark.icloud")
                        .font(.headline)
                    if let phase {
                        Text(phase.userFacingTitle)
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                    Button(String(localized: "削除を再試行", table: "Settings", comment: "Button: retry complete data deletion")) {
                        completeDeletion.startOrRetry()
                    }
                }
            }
        } header: {
            Text("記録の書き出しとリセット", tableName: "Settings", comment: "Settings section header: export and reset")
        } footer: {
            Text(dataStorageDisclosure)
        }
    }

    /// settings-09: says it is not a backup that can be read back in, where
    /// people look, instead of only in the local-only footer.
    private var dataExportSubtitle: String {
        isExportingData
            ? String(localized: "JSONファイルを作成中", table: "Settings", comment: "Export row subtitle while the file is being written")
            : String(
                localized: "記録をJSONファイルに書き出す（読み込みには非対応）",
                table: "Settings",
                comment: "Settings export row subtitle: the file cannot be imported back"
            )
    }

    /// settings-06. Plain words for what the reset does and what stays; the
    /// facts are the ones PRIVACY.md states (earlier records remain on the
    /// iPhone, and in iCloud for sync, and can appear in an export).
    private var resetDataMessage: String {
        let message: String
        if persistenceMode == .localOnly {
            message = String(
                localized: "集中の粒・結晶・記念石を表示と集計から外し、0から始めます。テーマと設定は残ります。リセット前の記録はこのiPhoneの中に残り、データの書き出しに含まれることがあります。このiPhoneから完全に消すには、アプリを削除してください。この操作は取り消せません。",
                table: "Settings",
                comment: "Reset confirmation on a local-only iPhone"
            )
        } else {
            message = String(
                localized: "集中の粒・結晶・記念石を表示と集計から外し、0から始めます。同じiCloudを使うほかのiPhoneにも、接続したときに反映されます。オフラインのiPhoneから古い記録が戻らないよう、リセット前の記録は同期のために残り、データの書き出しにも含まれます。このiPhoneから完全に消すにはアプリを削除し、iCloudのデータはiPhoneの「設定」にあるiCloudのストレージ管理から削除してください。この操作は取り消せません。",
                table: "Settings",
                comment: "Reset confirmation in iCloud mode"
            )
        }
        // Said only where Screen Time is set up: the reset starts its ledger's
        // new generation too (ScreenTimeController.bindContext).
        guard ScreenTimeController.shared.hasLocalSetup else { return message }
        let screenTime = String(
            localized: "スクリーンタイムの黒い石、まだ取り込んでいない勉強アプリの記録、10分に満たない途中の利用時間も消えます。アプリの選択と自動記録の設定は残ります。",
            table: "Settings",
            comment: "Reset confirmation: extra paragraph shown only when Screen Time is set up on this iPhone"
        )
        return message + "\n\n" + screenTime
    }

    /// settings-06. The export footer said 「全11種類の出荷対象保存データ」,
    /// 「タイマー整合用のランダムな端末識別子」 and 「以前リセットした旧世代」:
    /// review-notes wording. The privacy facts stay, in plain words: theme
    /// names, memos, settings, every record this iPhone has (in iCloud mode,
    /// what has reached it; PRIVACY.md's 「端末で利用可能な」) including those
    /// from before a reset, and a random device ID for timer sync. It says
    /// 置き場所 rather than 保存先, which on this screen names where the app
    /// keeps its records (iCloud or this iPhone).
    private var dataStorageDisclosure: String {
        if persistenceMode == .localOnly {
            return String(
                localized: "書き出すファイル（JSON）には、テーマ名・成果メモ・設定、このiPhoneにあるすべての記録（リセット前の記録を含む）、タイマーの同期に使うランダムな端末IDが入ります。SNS用のシェア画像とは別のファイルです。書き出したファイルの置き場所や送り先に注意してください。このファイルを読み込んで記録を戻したり、iCloudへ移したりすることはできません。リセットしてもテーマと設定は残ります。このiPhoneのデータは、アプリを削除すると消えます。",
                table: "Settings",
                comment: "Settings export footer on a local-only iPhone"
            )
        }
        return String(
            localized: "書き出すファイル（JSON）には、テーマ名・成果メモ・設定、このiPhoneにあるすべての記録（リセット前の記録を含む）、タイマーの同期に使うランダムな端末IDが入ります。SNS用のシェア画像とは別のファイルです。書き出したファイルの置き場所や送り先に注意してください。このiPhoneのデータはアプリの削除で、iCloudのデータはiPhoneの「設定」にあるiCloudのストレージ管理から削除できます。",
            table: "Settings",
            comment: "Settings export footer in iCloud mode"
        )
    }

    private func startDataExport() {
        guard !isExportingData else { return }
        do {
            if modelContext.hasChanges {
                try modelContext.save()
            }
        } catch {
            dataExportError = String(
                localized: "保存中の変更を確定できませんでした。\n\(error.localizedDescription)",
                table: "Settings",
                comment: "Export error; the argument is the system error description"
            )
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
                    argument: String(
                        localized: "\(result.recordCounts.total)件のデータを書き出しました。保存先を選んでください",
                        table: "Settings",
                        comment: "VoiceOver announcement after an export; the argument is the number of records written"
                    )
                )
            } catch is CancellationError {
                // The explicit cancel control announces immediately. Navigating
                // away cancels silently so VoiceOver is not interrupted.
            } catch {
                guard activeDataExportID == exportID else { return }
                dataExportError = String(
                    localized: "データを書き出せませんでした。\n\(error.localizedDescription)",
                    table: "Settings",
                    comment: "Export error; the argument is the system error description"
                )
                UIAccessibility.post(
                    notification: .announcement,
                    argument: String(
                        localized: "データを書き出せませんでした",
                        table: "Settings",
                        comment: "Alert title and VoiceOver announcement: the data export failed"
                    )
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
            UIAccessibility.post(notification: .announcement, argument: String(
                localized: "データの書き出しをキャンセルしました",
                table: "Settings",
                comment: "VoiceOver announcement: the data export was canceled"
            ))
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
            settingsError = String(
                localized: "タイマー終了音を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)",
                table: "Settings",
                comment: "Settings error; the argument is the system error description"
            )
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
            settingsError = String(
                localized: "タイマー終了時の触覚を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)",
                table: "Settings",
                comment: "Settings error; the argument is the system error description"
            )
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
                    settingsError = String(
                        localized: "通知時刻を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)",
                        table: "Settings",
                        comment: "Settings error; the argument is the system error description"
                    )
                }
            }
        )
    }

    /// a11y-04: a new theme starts on the first palette swatch no theme uses
    /// yet (archived themes count: their gems are still in the jar), so the
    /// editor always opens with a swatch selected. It used to be an HSB hue
    /// step that was never one of the swatches.
    private var nextSubjectColor: String {
        SubjectPalette.suggestedHex(existing: subjects.map(\.colorHex))
    }

    private func addSubject(name: String, colorHex: String, isArchived _: Bool) -> String? {
        guard subjects.count < Constants.App.maximumSubjects else {
            return String(
                localized: "テーマは最大\(Constants.App.maximumSubjects)件までです。",
                table: "Settings",
                comment: "Theme editor error; the argument is the theme limit (12)"
            )
        }
        if let validationError = subjectNameValidationError(name) {
            return validationError
        }
        guard let sanitizedName = SubjectNamePolicy.validated(name) else {
            return SubjectNamePolicy.validationError(for: name)?.message
                ?? String(localized: "テーマ名を入力してください。", table: "Settings", comment: "Theme editor error: the name is empty")
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
        return commitChanges(failureMessage: String(
            localized: "テーマを追加できませんでした。",
            table: "Settings",
            comment: "Theme editor error, followed by a line saying the change was undone"
        ))
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
                ?? String(localized: "テーマ名を入力してください。", table: "Settings", comment: "Theme editor error: the name is empty")
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
            return String(
                localized: "テーマの変更を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)",
                table: "Settings",
                comment: "Theme editor error; the argument is the system error description"
            )
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
        return String(
            localized: "同じ名前のテーマ「\(duplicate.safeDisplayName)」がすでにあります。",
            table: "Settings",
            comment: "Theme editor error; the argument is the existing theme's name"
        )
    }

    private func deleteSubject(_ subject: Subject) {
        // Read before the deletion: the dialog showed the Screen Time
        // paragraph exactly when this held.
        let warnedAboutScreenTime = ScreenTimeThemeDeletionNotice.applies(
            to: subject.id, configuration: ScreenTimeController.shared.configuration,
            isBound: ScreenTimeController.shared.isBoundToContext
        )
        do {
            subject.isArchived = true
            subject.deletedAt = .now
            try SubjectSyncPolicy.recordUserMutation(
                from: subject,
                among: storedSubjects
            )
            try modelContext.save()
            if warnedAboutScreenTime {
                ScreenTimeController.shared.noteLearningThemeDeletionConfirmed(subject.id)
            }
        } catch {
            modelContext.rollback()
            settingsError = String(
                localized: "テーマを削除できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)",
                table: "Settings",
                comment: "Settings error; the argument is the system error description"
            )
        }
    }

    private func subjectDeletionMessage(
        for subject: Subject,
        recordCount: Int
    ) -> String {
        let message: String
        if recordCount == 0 {
            message = String(
                localized: "「\(subject.safeDisplayName)」を削除します。関連する過去の記録はありません。この操作は取り消せません。",
                table: "Settings",
                comment: "Theme deletion alert message; the argument is the theme name"
            )
        } else {
            // The count is its own phrase so English can pluralize it.
            let records = String(
                localized: "settings.theme-deletion.record-count",
                defaultValue: "過去の記録\(recordCount)件",
                table: "Settings",
                comment: "How many past records use the theme being deleted, inside the deletion message. English: '%lld past record' / '%lld past records'."
            )
            message = String(
                localized: "「\(subject.safeDisplayName)」だけを削除します。\(records)と質量は消えず、現在の名前と色も残ります。この操作は取り消せません。",
                table: "Settings",
                comment: "Theme deletion alert message. The first argument is the theme name, the second how many past records use it (過去の記録3件)"
            )
        }
        // Deleting the Screen Time destination also clears the study-app
        // selection (Docs/ScreenTimeGems.md). Say so while the user can still
        // cancel and pick another destination first.
        guard ScreenTimeThemeDeletionNotice.applies(
            to: subject.id, configuration: ScreenTimeController.shared.configuration,
            isBound: ScreenTimeController.shared.isBoundToContext
        ) else { return message }
        return message + "\n\n" + ScreenTimeThemeDeletionNotice.text
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
            settingsError = String(
                localized: "関連する記録を確認できないため、テーマを削除できません。\n\(error.localizedDescription)",
                table: "Settings",
                comment: "Settings error; the argument is the system error description"
            )
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
            settingsError = String(
                localized: "テーマの並び順を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)",
                table: "Settings",
                comment: "Settings error; the argument is the system error description"
            )
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
            router.showToast(String(
                localized: "Proの購入状態を確認してください",
                table: "Settings",
                comment: "Toast: a custom duration needs Pro, and Pro is not confirmed on this device"
            ), symbol: "lock")
            return false
        }
        guard savePreferredFocusSeconds(totalSeconds) else { return false }
        // Home lists recent custom times so a preset never loses this one.
        RecentCustomFocusDurations.record(totalSeconds)
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
            router.showToast(String(
                localized: "既定の集中時間を保存できませんでした",
                table: "Settings",
                comment: "Toast: the default focus length could not be saved"
            ), symbol: "exclamationmark.triangle")
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
            settingsError = String(
                localized: "タイマーの表示を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)",
                table: "Settings",
                comment: "Settings error; the argument is the system error description"
            )
        }
    }

    private func updateReminder(enabled: Bool) {
        updatePassiveNotification(.dailyReminder, enabled: enabled)
    }

    private func updateWrappedNotification(enabled: Bool) {
        updatePassiveNotification(.wrapped, enabled: enabled)
    }

    private func refreshFocusLeaveSwitches() {
        focusLeavePauseEnabled = FocusLeavePreferences.isEnabled()
        focusLeaveNudgesEnabled = FocusLeavePreferences.nudgesAreEnabled()
        focusLeaveNudgesChosen = FocusLeavePreferences.nudgesWereChosen()
    }

    /// No permission is involved: the pause works whether or not
    /// notifications are allowed. Turning it off withdraws a booked series.
    /// The switch shows the value read back, so an explicit launch-argument
    /// value (which outranks this write) is never misreported.
    private func updateFocusLeavePause(enabled: Bool) {
        FocusLeavePreferences.setLeavePauseEnabled(enabled)
        refreshFocusLeaveSwitches()
    }

    /// Same contract as 集中に戻るお知らせ: ON is saved only once this
    /// iPhone allows notifications, and a refused ON saves nothing.
    private func updateFocusLeaveNudges(enabled: Bool) {
        let intent = notificationPreferenceIntents.begin(.focusLeaveNudges)
        let manager = NotificationManager.shared
        if !enabled {
            FocusLeavePreferences.setNudgesEnabled(false)
            refreshFocusLeaveSwitches()
            return
        }

        viewTasks.start {
            guard let granted = await notificationPreferenceIntents.authorizeUpdate(
                .focusLeaveNudges,
                intent: intent,
                enabled: true,
                refreshAuthorization: {
                    await manager.refreshAuthorizationStatus()
                    return manager.isAuthorized
                },
                requestAuthorization: {
                    await manager.requestAuthorization()
                }
            ), notificationPreferenceIntents.isCurrent(.focusLeaveNudges, intent: intent)
            else { return }
            if granted {
                FocusLeavePreferences.setNudgesEnabled(true)
            } else {
                notificationError = notificationPermissionMessage(
                    underlyingError: manager.lastErrorDescription
                )
            }
            refreshFocusLeaveSwitches()
        }
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
                // Only an ON request can be refused, so nothing was saved yet.
                // Writing OFF here could overwrite an ON synced meanwhile.
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
                    settingsError = String(
                        localized: "毎日のリマインダー設定を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)",
                        table: "Settings",
                        comment: "Settings error; the argument is the system error description"
                    )
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
            settingsError = String(
                localized: "リセット情報を安全に保存できませんでした。\n\(error.localizedDescription)",
                table: "Settings",
                comment: "Settings error; the argument is the system error description"
            )
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
            settingsError = String(
                localized: "記録をリセットできませんでした。\n\(error.localizedDescription)",
                table: "Settings",
                comment: "Settings error; the argument is the system error description"
            )
            return
        }
        if let error = commitChanges(failureMessage: String(
            localized: "記録をリセットできませんでした。",
            table: "Settings",
            comment: "Reset error, followed by a line saying the change was undone"
        )) {
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
                ? String(localized: "このiPhone内の記録をリセットしました", table: "Settings", comment: "Toast after a reset on a local-only iPhone")
                : String(
                    localized: "記録をリセットしました。ほかの端末にはiCloud接続後に反映されます",
                    table: "Settings",
                    comment: "Toast after a reset in iCloud mode"
                ),
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
                    ? String(
                        localized: "このiPhone内の記録はリセット済みですが、端末上の補助表示を消去できませんでした。\n\(error.localizedDescription)",
                        table: "Settings",
                        comment: "Reset cleanup error on a local-only iPhone; the argument is the system error description"
                    )
                    : String(
                        localized: "この端末の記録はリセット済みですが、ウィジェットの表示を消去できませんでした。iCloudへの反映には時間がかかる場合があります。\n\(error.localizedDescription)",
                        table: "Settings",
                        comment: "Reset cleanup error in iCloud mode; the argument is the system error description"
                    )
            }
        }
    }

    private var storageDestination: String {
        persistenceMode == .localOnly
            ? String(
                localized: "このiPhone",
                table: "Settings",
                comment: "Where settings are saved, inside a sentence (English: this iPhone)"
            )
            : String(localized: "iCloud", table: "Settings", comment: "Where records or settings are saved: iCloud")
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
            settingsError = String(
                localized: "設定を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)",
                table: "Settings",
                comment: "Settings error; the argument is the system error description"
            )
            return false
        }
    }

    private func commitChanges(failureMessage: String) -> String? {
        do {
            try modelContext.save()
            return nil
        } catch {
            modelContext.rollback()
            return String(
                localized: "\(failureMessage)\n変更前の状態に戻しました。\n\(error.localizedDescription)",
                table: "Settings",
                comment: "Settings error. The first argument is what failed (a full sentence), the second the system error description"
            )
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

    /// The switches keep the person's intent. The daily reminder's is synced,
    /// so this iPhone's permission must never rewrite it: a new or reinstalled
    /// iPhone reads `.notDetermined` and would switch reminders off on every
    /// other device. Scheduling is gated per device instead, and the status
    /// row under an enabled switch offers the one step that fixes it here.
    private func reconcileNotificationAuthorization() async {
        await NotificationManager.shared.refreshAuthorizationStatus()
        guard !Task.isCancelled else { return }
        await synchronizeNotificationsNow()
    }

    private func synchronizeNotificationsNow() async {
        let manager = NotificationManager.shared
        await manager.refreshAuthorizationStatus()
        guard !Task.isCancelled else { return }
        let prefs = resolvedPreferences
        let activity = PassiveReminderActivityReader.read(
            context: modelContext,
            markers: resetSnapshots
        )
        do {
            try await manager.synchronizePassiveNotifications(
                dailyReminderEnabled: (prefs?.reminderEnabled ?? false)
                    && manager.isAuthorized,
                wrappedEnabled: wrappedNotifications && manager.isAuthorized,
                hour: prefs?.reminderHour
                    ?? Constants.Notification.defaultReminderHour,
                minute: prefs?.reminderMinute
                    ?? Constants.Notification.defaultReminderMinute,
                playsSound: prefs?.soundOn ?? false,
                activity: activity
            )
        } catch {
            guard !Task.isCancelled else { return }
            notificationError = String(
                localized: "通知の予定を更新できませんでした。\n\(error.localizedDescription)",
                table: "Settings",
                comment: "Notification error; the argument is the system error description"
            )
        }
    }

    /// Shown under an enabled notification switch while this iPhone cannot
    /// deliver. Hidden until the first permission read so an allowed iPhone
    /// never flashes the notice.
    @ViewBuilder
    private func notificationPermissionStatus(identifier: String) -> some View {
        let manager = NotificationManager.shared
        if manager.hasLoadedAuthorizationStatus, !manager.isAuthorized {
            NotificationPermissionStatusRow(
                status: manager.authorizationStatus,
                identifier: identifier,
                allow: allowNotificationsOnThisDevice,
                openSettings: openNotificationSettings
            )
        }
    }

    private func allowNotificationsOnThisDevice() {
        viewTasks.start {
            let manager = NotificationManager.shared
            await manager.requestAuthorization()
            guard !Task.isCancelled else { return }
            if let error = manager.lastErrorDescription, !manager.isAuthorized {
                notificationError = notificationPermissionMessage(underlyingError: error)
            }
            await synchronizeNotificationsNow()
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func notificationPermissionMessage(underlyingError: String?) -> String {
        let message = String(
            localized: "通知が許可されていません。端末の「設定」から「ポモジェム」の通知を許可してください。",
            table: "Settings",
            comment: "Notification permission error; 設定 is the iOS Settings app"
        )
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
                    Text("残り時間の見え方を選ぶ", tableName: "Settings", comment: "Heading of the timer display page")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(PomoGemTheme.text)
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        "見本は25分タイマーの途中、残り16分15秒です。選んだ表示はすぐに反映されます。",
                        tableName: "Settings",
                        comment: "Timer display page: the samples show a 25-minute timer with 16:15 left"
                    )
                        .font(.subheadline)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(TimerDisplayMode.allCases) { mode in
                        displayOption(mode)
                    }
                }

                Text("どの表示でも、タイマーの時間や集中の記録は変わりません。", tableName: "Settings", comment: "Timer display page footer")
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
        .navigationTitle(Text("タイマーの表示", tableName: "Settings", comment: "Navigation title of the timer display page"))
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
        .accessibilityLabel(String(
            localized: "\(mode.title)。\(mode.detail)",
            table: "Settings",
            comment: "VoiceOver label of a picker option: its name, then its description"
        ))
        .accessibilityValue(isSelected
            ? String(localized: "選択中", table: "Settings", comment: "VoiceOver value: this option is selected")
            : String(localized: "未選択", table: "Settings", comment: "VoiceOver value: this option is not selected"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected
            ? String(localized: "現在のタイマー表示です", table: "Settings", comment: "VoiceOver hint of the selected timer display")
            : String(localized: "選ぶとすぐに反映されます", table: "Settings", comment: "VoiceOver hint of a timer display option"))
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
            accessibleRemainingTime: String(
                localized: "残り16分15秒",
                table: "Settings",
                comment: "VoiceOver text of the hidden timer sample (16 minutes 15 seconds left)"
            ),
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
                            ? String(localized: "プレビューをキャンセル", table: "Settings", comment: "Button: cancel the timer end preview")
                            : String(
                                localized: "3秒後に試す",
                                table: "Settings",
                                comment: "Button: play the timer end sound and haptics in 3 seconds"
                            ))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(PomoGemTheme.text)
                        Text("選んだ終了音と触覚を一緒に確認します", tableName: "Settings", comment: "Preview button subtitle")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                    Spacer(minLength: 8)
                    if let remaining = controller.state.remainingSeconds {
                        Text(verbatim: "\(remaining)")
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
                ? String(localized: "プレビューをキャンセル", table: "Settings", comment: "Button: cancel the timer end preview")
                : String(localized: "3秒後に試す", table: "Settings", comment: "Button: play the timer end sound and haptics in 3 seconds"))
            .accessibilityValue(controller.state.remainingSeconds.map {
                String(
                    localized: "あと\($0)秒",
                    table: "Settings",
                    comment: "Seconds left before the preview plays; the argument is the count"
                )
            } ?? String(localized: "待機中", table: "Settings", comment: "VoiceOver value: the preview is not running"))
            .accessibilityHint(configuration.isSilent
                ? String(localized: "音か触覚をオンにすると試せます", table: "Settings", comment: "VoiceOver hint: the preview needs sound or haptics on")
                : String(localized: "選んだタイマー終了音と触覚を3秒後に再生します", table: "Settings", comment: "VoiceOver hint of the preview button"))

            if let remaining = controller.state.remainingSeconds {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(
                        value: Double(3 - remaining),
                        total: 3
                    )
                    .tint(PomoGemTheme.amber)
                    Text(
                        "あと\(remaining)秒",
                        tableName: "Settings",
                        comment: "Seconds left before the preview plays; the argument is the count"
                    )
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
                .accessibilityLabel(String(
                    localized: "プレビューまであと\(remaining)秒",
                    table: "Settings",
                    comment: "VoiceOver: seconds until the preview plays; the argument is the count"
                ))
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private func togglePreview() {
        if controller.isRunning {
            controller.cancel()
            UIAccessibility.post(
                notification: .announcement,
                argument: String(
                    localized: "プレビューをキャンセルしました",
                    table: "Settings",
                    comment: "VoiceOver announcement: the preview was canceled"
                )
            )
        } else {
            controller.start(configuration)
            UIAccessibility.post(
                notification: .announcement,
                argument: String(
                    localized: "3秒後にプレビューします。もう一度押すとキャンセルできます",
                    table: "Settings",
                    comment: "VoiceOver announcement when the preview starts"
                )
            )
        }
    }
}

/// The word typed on the last step of complete data deletion: ja 削除,
/// en DELETE. One localized value is shown in the prompt and the placeholder
/// and compared with the input, so the check can never drift from what the
/// screen asks for. The comparison stays exact after trimming whitespace.
enum CompleteDataDeletionConfirmationWord {
    static func word(bundle: Bundle = .main, locale: Locale = PomoGemLocale.current) -> String {
        String(
            localized: "settings.complete-deletion.confirmation-word",
            defaultValue: "削除",
            table: "Settings",
            bundle: bundle,
            locale: locale,
            comment: "The word the person types to confirm complete data deletion. It is shown in the prompt and compared exactly with the input. English: DELETE (capital letters)."
        )
    }

    static func accepts(_ input: String, word: String = word()) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines) == word
    }

    /// Whether the keyboard should type capitals: only for a word written in
    /// capital letters and nothing else.
    static func typesCapitals(_ word: String) -> Bool {
        word.contains(where: \.isUppercase) && word.allSatisfy { $0.isUppercase || !$0.isLetter }
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
    /// The prompt, the placeholder and the check all read this one value.
    private let confirmationWord = CompleteDataDeletionConfirmationWord.word()

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
            .navigationTitle(step == .consequences
                ? String(
                    localized: "ユーザー内容を削除",
                    table: "Settings",
                    comment: "Complete data deletion: row, sheet title and final button (glossary: Delete Your Content)"
                )
                : String(localized: "最終確認", table: "Settings", comment: "Complete data deletion: title of the last step"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "キャンセル", table: "Settings", comment: "Toolbar button")) { dismiss() }
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
                Label(String(
                    localized: "テーマと成果メモ",
                    table: "Settings",
                    comment: "Complete data deletion: what is deleted"
                ), systemImage: "tag.slash")
                Label(String(
                    localized: "集中記録・粒・集計",
                    table: "Settings",
                    comment: "Complete data deletion: what is deleted"
                ), systemImage: "clock.badge.xmark")
                Label(String(
                    localized: "設定・タイマー復元情報・ウィジェット",
                    table: "Settings",
                    comment: "Complete data deletion: what is deleted"
                ), systemImage: "gear.badge.xmark")
                Label(String(
                    localized: "このAppのプライベートiCloud上のユーザー内容",
                    table: "Settings",
                    comment: "Complete data deletion: what is deleted"
                ), systemImage: "icloud.slash")
            } header: {
                Text("取り消せない削除対象", tableName: "Settings", comment: "Complete data deletion: section header above what is deleted for good")
            } footer: {
                Text(
                    "テーマ・記録・設定などのユーザー内容を削除します。古い端末からの再流入を検知するため、内容を含まない削除世代記録1件（世代ID・処理ID・連番・状態・日時）はiCloudに残ります。Proの購入履歴はAppleが管理しているため削除されず、同じApple Accountでは復元できます。",
                    tableName: "Settings",
                    comment: "Complete data deletion: what stays (the content-free deletion record, the Pro purchase)"
                )
            }

            Section(String(localized: "削除を始める前に", table: "Settings", comment: "Complete data deletion: section header")) {
                Text(
                    "iCloudへ接続できる状態で実行してください。通信が切れた場合は完了と表示せず、安全な位置から再試行します。",
                    tableName: "Settings",
                    comment: "Complete data deletion precondition"
                )
                Text(
                    "ほかの端末も最新版へ更新し、オンラインで一度起動してください。オフラインのままの端末や、この削除世代に対応していない古いバージョンは、端末内の古い記録を後からiCloudへ再送する可能性があります。",
                    tableName: "Settings",
                    comment: "Complete data deletion precondition"
                )
                Text(
                    "本Appは別端末のローカル保存を遠隔消去できません。削除後も、使わない古いインストールは削除してください。",
                    tableName: "Settings",
                    comment: "Complete data deletion precondition"
                )
            }
        }
    }

    private var finalConfirmation: some View {
        Group {
            Section {
                Toggle(
                    String(
                        localized: "ほかの端末と古いバージョンに関する制約を確認しました",
                        table: "Settings",
                        comment: "Complete data deletion: acknowledgement switch on the last step"
                    ),
                    isOn: $understoodOtherDevices
                )
            }

            Section {
                TextField(confirmationWord, text: $confirmationText)
                    // Capitals only for a word written in them (en DELETE);
                    // Japanese romaji input would turn capitals into letters.
                    .textInputAutocapitalization(
                        CompleteDataDeletionConfirmationWord.typesCapitals(confirmationWord) ? .characters : .never
                    )
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .accessibilityLabel(String(
                        localized: "確認のため\(confirmationWord)と入力",
                        table: "Settings",
                        comment: "VoiceOver label of the confirmation field; the argument is the word to type (削除 / DELETE)"
                    ))
            } header: {
                Text(
                    "「\(confirmationWord)」と入力",
                    tableName: "Settings",
                    comment: "Header above the confirmation field; the argument is the word to type (削除 / DELETE)"
                )
            } footer: {
                Text(
                    "開始後は記録の追加を停止します。iCloudでユーザー内容の削除と、内容を含まない削除世代記録の確定を確認するまで、通常画面には戻りません。",
                    tableName: "Settings",
                    comment: "Complete data deletion: what happens once it starts"
                )
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if step == .consequences {
            Button(String(
                localized: "内容を確認して次へ",
                table: "Settings",
                comment: "Complete data deletion: go from the consequences to the last step"
            )) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    step = .finalConfirmation
                }
            }
            .buttonStyle(PomoGemPrimaryButtonStyle())
        } else {
            Button(String(
                localized: "ユーザー内容を削除",
                table: "Settings",
                comment: "Complete data deletion: row, sheet title and final button (glossary: Delete Your Content)"
            ), role: .destructive) {
                onConfirmed()
            }
            .buttonStyle(PomoGemPrimaryButtonStyle())
            .disabled(
                !understoodOtherDevices
                    || !CompleteDataDeletionConfirmationWord.accepts(confirmationText, word: confirmationWord)
            )
        }
    }
}

struct FontLicenseView: View {
    @Environment(\.dismiss) private var dismiss

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "LICENSE-fonts", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return String(
            localized: "ライセンス文書を読み込めませんでした。",
            table: "Settings",
            comment: "Font licence page: the licence file could not be read"
        ) }
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
            .navigationTitle(Text("フォントライセンス", tableName: "Settings", comment: "Navigation title of the font licence page"))
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
            content.accessibilityAction(named: Text(
                "下へ移動",
                tableName: "Settings",
                comment: "VoiceOver action: move this theme down one row"
            ), moveDown)
        } else if index == count - 1 {
            content.accessibilityAction(named: Text(
                "上へ移動",
                tableName: "Settings",
                comment: "VoiceOver action: move this theme up one row"
            ), moveUp)
        } else {
            content
                .accessibilityAction(named: Text(
                    "上へ移動",
                    tableName: "Settings",
                    comment: "VoiceOver action: move this theme up one row"
                ), moveUp)
                .accessibilityAction(named: Text(
                    "下へ移動",
                    tableName: "Settings",
                    comment: "VoiceOver action: move this theme down one row"
                ), moveDown)
        }
    }
}

/// The Screen Time row, with the feature's status in place of a fixed
/// caption: a stop used to be visible only inside the page. Its own view so
/// that only this row follows the controller, not the whole Settings list.
private struct ScreenTimeSettingsRowLabel: View {
    @ObservedObject private var controller = ScreenTimeController.shared

    private var status: ScreenTimeRowStatus {
        ScreenTimeRowStatus(
            isBound: controller.isBoundToContext,
            enabled: controller.configuration.enabled,
            isMonitoring: controller.isMonitoring,
            monitoringError: controller.monitoringError,
            learningStoppedByFreeLimit: controller.learningStoppedByFreeLimit,
            themeRemoved: controller.learningThemeWasRemoved
        )
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("スクリーンタイム", tableName: "Settings", comment: "Settings row title: Screen Time")
                    .foregroundStyle(PomoGemTheme.text)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if status.isWarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .accessibilityHidden(true)
                    }
                    Text(status.subtitle)
                }
                .font(.caption)
                .foregroundStyle(status.isWarning ? PomoGemTheme.amber : PomoGemTheme.muted)
            }
        } icon: {
            Image(systemName: "hourglass").foregroundStyle(PomoGemTheme.amber).frame(width: 26)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Explains why an enabled notification switch cannot deliver on this
/// iPhone. The switch keeps the person's (possibly synced) intent; this row
/// names what is missing here and offers the one step that fixes it.
private struct NotificationPermissionStatusRow: View {
    let status: UNAuthorizationStatus
    let identifier: String
    let allow: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(PomoGemTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "bell.slash")
                    .foregroundStyle(PomoGemTheme.amber)
                    .frame(width: 26)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)

            Button(action: status == .denied ? openSettings : allow) {
                Text(actionTitle)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(PomoGemTheme.amber)
            .accessibilityIdentifier("\(identifier).action")
        }
        .padding(.vertical, 4)
    }

    private var message: String {
        switch status {
        case .denied:
            String(
                localized: "オンにしている通知は、このiPhoneの設定でオフになっているため届きません。",
                table: "Settings",
                comment: "Settings notice under an enabled notification switch: notifications are turned off for this app in iOS"
            )
        default:
            String(
                localized: "オンにしている通知は、このiPhoneではまだ許可されていないため届きません。",
                table: "Settings",
                comment: "Settings notice under an enabled notification switch: iOS has not asked for notification permission on this device yet"
            )
        }
    }

    private var actionTitle: String {
        status == .denied
            ? String(localized: "設定を開く", table: "Settings", comment: "Button: open this app's notification settings in iOS")
            : String(localized: "許可する", table: "Settings", comment: "Button: show the iOS notification permission prompt")
    }
}

struct SettingLabel: View {
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var name: String
    @State private var colorHex: String
    @State private var isArchived: Bool
    @State private var saveError: String?
    @FocusState private var isNameFocused: Bool

    /// Four narrow columns cut every swatch name to its number at the
    /// accessibility sizes (「2…」); two wider ones keep 「現在の色」 and the
    /// names readable.
    private var colorColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.adaptive(minimum: 140), spacing: 8)]
            : [GridItem(.adaptive(minimum: 64, maximum: 92), spacing: 8)]
    }

    private let palette = SubjectPalette.swatches.map {
        SubjectColorChoice(hex: $0.hex, name: $0.name)
    }

    /// A colour this theme was saved with that is not a palette swatch (the
    /// 1.0.x HSB suggestion made such colours). It is offered as 「現在の色」
    /// so the editor still shows what the theme looks like, and it is kept
    /// unless the person picks a swatch.
    private var currentOffPaletteHex: String? {
        guard let stored = subject?.colorHex,
              !SubjectPalette.contains(stored)
        else { return nil }
        return stored
    }

    private func isSelected(_ hex: String) -> Bool {
        SubjectPalette.normalized(colorHex) == SubjectPalette.normalized(hex)
    }

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
            return String(
                localized: "1〜\(SubjectNamePolicy.maximumCharacters)文字で入力してください。",
                table: "Settings",
                comment: "Theme name field status when empty; the argument is the longest allowed name (20)"
            )
        }
        return String(
            localized: "あと\(SubjectNamePolicy.remainingCharacters(for: name))文字入力できます。",
            table: "Settings",
            comment: "Theme name field status; the argument is how many more characters fit"
        )
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
                        .accessibilityHint(String(
                            localized: "テーマ名は\(SubjectNamePolicy.maximumCharacters)文字までです",
                            table: "Settings",
                            comment: "VoiceOver hint of the theme name field; the argument is the longest allowed name (20)"
                        ))
                } header: {
                    Text("名前", tableName: "Settings", comment: "Theme editor section header: the theme name")
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
                Section(String(
                    localized: "粒の色",
                    table: "Settings",
                    comment: "Theme editor section header: the colour of this theme's gems"
                )) {
                    LazyVGrid(columns: colorColumns, spacing: 12) {
                        if let currentOffPaletteHex {
                            Button {
                                colorHex = currentOffPaletteHex
                            } label: {
                                VStack(spacing: 5) {
                                    Circle()
                                        .fill(Color(hex: currentOffPaletteHex))
                                        .frame(width: 34, height: 34)
                                        .overlay {
                                            if isSelected(currentOffPaletteHex) {
                                                Circle().stroke(.white, lineWidth: 3).padding(-4)
                                            }
                                        }
                                    Text(
                                        "現在の色",
                                        tableName: "Settings",
                                        comment: "A theme's saved colour that is not one of the palette swatches"
                                    )
                                        .font(.caption2)
                                        .foregroundStyle(PomoGemTheme.text)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                }
                                .frame(maxWidth: .infinity, minHeight: 60)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PomoGemBareButtonStyle())
                            .accessibilityAddTraits(isSelected(currentOffPaletteHex) ? .isSelected : [])
                            .accessibilityIdentifier("subject-editor.color.current")
                        }
                        ForEach(Array(palette.enumerated()), id: \.element.id) { index, choice in
                            Button {
                                colorHex = choice.hex
                            } label: {
                                VStack(spacing: 5) {
                                    Circle()
                                        .fill(Color(hex: choice.hex))
                                        .frame(width: 34, height: 34)
                                        .overlay {
                                            if isSelected(choice.hex) {
                                                Circle().stroke(.white, lineWidth: 3).padding(-4)
                                            }
                                        }
                                    // Two-word English names (12 Leaf Green) wrap
                                    // at the accessibility sizes instead of
                                    // truncating; the Japanese names fit one line.
                                    Text(verbatim: "\(index + 1) \(choice.name)")
                                        .font(.caption2)
                                        .foregroundStyle(PomoGemTheme.text)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                                        .minimumScaleFactor(0.75)
                                }
                                .frame(maxWidth: .infinity, minHeight: 60)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PomoGemBareButtonStyle())
                            .accessibilityLabel(String(
                                localized: "色候補\(index + 1)、\(choice.name)",
                                table: "Settings",
                                comment: "VoiceOver label of a colour swatch. The first argument is its number, the second its name"
                            ))
                            .accessibilityAddTraits(isSelected(choice.hex) ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 8)
                }
                if let subject {
                    Section {
                        Toggle(String(
                            localized: "ホームの選択肢に表示",
                            table: "Settings",
                            comment: "Theme editor switch: offer this theme on Home"
                        ), isOn: Binding(
                            get: { !isArchived },
                            set: { isArchived = !$0 }
                        ))
                    } footer: {
                        Text(
                            "非表示にしても、\(subject.safeDisplayName)の過去の粒は瓶に残ります。",
                            tableName: "Settings",
                            comment: "Theme editor footer; the argument is the theme name"
                        )
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(NightBackground())
            .navigationTitle(subject == nil
                ? String(localized: "テーマを追加", table: "Settings", comment: "Button and editor title: add a theme")
                : String(localized: "テーマを編集", table: "Settings", comment: "Theme editor title when editing"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(
                    localized: "キャンセル",
                    table: "Settings",
                    comment: "Toolbar button"
                )) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "保存", table: "Settings", comment: "Toolbar button: save the theme")) {
                        guard let sanitizedName = SubjectNamePolicy.validated(name) else {
                            saveError = nameValidationError?.message
                                ?? String(localized: "テーマ名を入力してください。", table: "Settings", comment: "Theme editor error: the name is empty")
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
            .alert(String(
                localized: "保存できませんでした",
                table: "Settings",
                comment: "Alert title: the theme could not be saved"
            ), isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button(String(localized: "閉じる", table: "Settings", comment: "Alert button"), role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }
}

extension View {
    /// settings-09. A UIActivityViewController wrapped in a SwiftUI `.sheet`
    /// takes the sheet's default full-height detent, so the share options sat
    /// in the top quarter of an otherwise empty screen. The system share
    /// sheet opens at half height and can be pulled up; so does this. Apply
    /// it to the representable inside the sheet's content.
    func systemShareSheetPresentation() -> some View {
        presentationDetents([.medium, .large])
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
