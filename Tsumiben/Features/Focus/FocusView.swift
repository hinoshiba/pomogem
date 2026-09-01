import Combine
import SwiftData
import SwiftUI
import UIKit

enum FocusCompletionPersistenceResult: Equatable, Sendable {
    case inserted(PebbleKind)
    case alreadyMaterialized
    case rejectedOwnership

    /// A remote owner can still be materializing the same logical completion.
    /// Only outcomes that prove a StudySession exists may retire recovery data.
    var mayRetireRecovery: Bool {
        switch self {
        case .inserted, .alreadyMaterialized:
            true
        case .rejectedOwnership:
            false
        }
    }
}

struct FocusView: View {
    private let subject: Subject?
    private let subjectSnapshot: FocusSubjectSnapshot
    private let recoveryOrigin: FocusRecoveryOrigin
    private let allowsLocalNotifications: Bool
    private let deviceID: String
    let duration: PomodoroDuration

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppRouter.self) private var router
    @Query private var preferences: [Prefs]
    @Query private var gachaStates: [GachaState]
    @Query private var syncedFocusTimers: [SyncedFocusTimer]
    @Query private var focusDeviceClaims: [FocusTimerDeviceClaim]
    @Query private var activityResetMarkers: [ActivityResetMarker]

    @State private var engine: PomodoroEngine
    @State private var displayNow = Date.now
    @State private var didStart = false
    @State private var didActivate = false
    @State private var didSignalCompletion = false
    @State private var clockAnchor: ClockAnchor?
    @State private var completion: CompletedDrop?
    @State private var pendingCompletion: PomodoroCompletion?
    @State private var completionSaveError: String?
    @State private var completionWasRejectedForOwnership = false
    @State private var isCommittingCompletion = false
    @State private var breakFinished = false
    @State private var showGiveUpConfirmation = false
    @State private var fairnessNotice = false
    @State private var setupErrorMessage: String?
    @State private var operationErrorMessage: String?
    @State private var rareRewardChoice: RareRewardMode?
    @State private var rareRewardChoiceError: String?
    @State private var isSavingRareRewardChoice = false
    @State private var dataEpochID: UUID?
    @State private var notifications = NotificationManager.shared
    @State private var notificationScheduleState: FocusNotificationScheduleState = .idle
    @AccessibilityFocusState private var completionSaveRetryFocused: Bool

    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    init(subject: Subject, duration: PomodoroDuration) {
        self.subject = subject
        self.subjectSnapshot = FocusSubjectSnapshot(subject: subject)
        self.recoveryOrigin = .local
        self.allowsLocalNotifications = true
        self.deviceID = FocusDeviceIdentity.current()
        self.duration = duration
        _engine = State(initialValue: PomodoroEngine(selectedDuration: duration))
        _dataEpochID = State(initialValue: nil)
        _preferences = Query(Self.preferencesDescriptor())
        _gachaStates = Query(Self.gachaDescriptor())
        _syncedFocusTimers = Query(Self.timerDescriptor(sessionID: nil))
        _focusDeviceClaims = Query(Self.claimDescriptor(sessionID: nil))
        _activityResetMarkers = Query(Self.resetMarkerDescriptor())
    }

    init(recovery request: RecoveredFocusRequest) {
        subject = request.subject
        subjectSnapshot = request.subjectSnapshot
        recoveryOrigin = request.origin
        allowsLocalNotifications = request.allowsLocalNotifications
        deviceID = FocusDeviceIdentity.current()
        duration = request.engine.selectedDuration
        _engine = State(initialValue: request.engine)
        _didStart = State(initialValue: true)
        _clockAnchor = State(initialValue: request.clockAnchor)
        _pendingCompletion = State(initialValue: request.pendingCompletion)
        _dataEpochID = State(initialValue: request.dataEpochID)
        _didSignalCompletion = State(initialValue: request.pendingCompletion != nil)
        _fairnessNotice = State(initialValue: request.engine.currentSource == .timerDemoted)
        let sessionID = request.pendingCompletion?.sessionID
            ?? request.engine.currentSessionID
        _preferences = Query(Self.preferencesDescriptor())
        _gachaStates = Query(Self.gachaDescriptor())
        _syncedFocusTimers = Query(Self.timerDescriptor(sessionID: sessionID))
        _focusDeviceClaims = Query(Self.claimDescriptor(sessionID: sessionID))
        _activityResetMarkers = Query(Self.resetMarkerDescriptor())
    }

    private static func preferencesDescriptor() -> FetchDescriptor<Prefs> {
        var descriptor = FetchDescriptor<Prefs>(
            sortBy: [SortDescriptor(\Prefs.id)]
        )
        descriptor.fetchLimit = 16
        return descriptor
    }

    private static func gachaDescriptor() -> FetchDescriptor<GachaState> {
        var descriptor = FetchDescriptor<GachaState>()
        descriptor.fetchLimit = 4
        return descriptor
    }

    private static func timerDescriptor(
        sessionID: UUID?
    ) -> FetchDescriptor<SyncedFocusTimer> {
        var descriptor: FetchDescriptor<SyncedFocusTimer>
        if let sessionID {
            let targetID = sessionID
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.sessionID == targetID },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse)
                ]
            )
        } else {
            descriptor = FetchDescriptor(sortBy: [
                SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                SortDescriptor(\SyncedFocusTimer.revision, order: .reverse)
            ])
        }
        descriptor.fetchLimit = FocusCloudSyncStore.QueryContract
            .matchingSessionRecordLimit
        return descriptor
    }

    private static func claimDescriptor(
        sessionID: UUID?
    ) -> FetchDescriptor<FocusTimerDeviceClaim> {
        var descriptor: FetchDescriptor<FocusTimerDeviceClaim>
        if let sessionID {
            let targetID = sessionID
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.sessionID == targetID },
                sortBy: [
                    SortDescriptor(\FocusTimerDeviceClaim.sequence, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.claimedAt, order: .reverse)
                ]
            )
        } else {
            descriptor = FetchDescriptor(sortBy: [
                SortDescriptor(\FocusTimerDeviceClaim.claimedAt, order: .reverse),
                SortDescriptor(\FocusTimerDeviceClaim.sequence, order: .reverse)
            ])
        }
        descriptor.fetchLimit = FocusCloudSyncStore.QueryContract
            .matchingSessionClaimLimit
        return descriptor
    }

    private static func resetMarkerDescriptor() -> FetchDescriptor<ActivityResetMarker> {
        var descriptor = FetchDescriptor<ActivityResetMarker>(sortBy: [
            SortDescriptor(\ActivityResetMarker.resetAt, order: .reverse),
            SortDescriptor(\ActivityResetMarker.sequence, order: .reverse),
            SortDescriptor(\ActivityResetMarker.writerDeviceID, order: .reverse),
            SortDescriptor(\ActivityResetMarker.epochID, order: .reverse),
            SortDescriptor(\ActivityResetMarker.id, order: .reverse)
        ])
        descriptor.fetchLimit = 1
        return descriptor
    }

    private var prefs: Prefs? {
        currentPreferences.first
    }
    private var currentPreferences: [Prefs] {
        preferences.filter {
            ActivityResetPolicy.isCurrent($0.activityEpochID, markers: resetSnapshots)
        }
    }
    private var rareRewardMode: RareRewardMode {
        RareRewardMode.resolved(preferences: currentPreferences)
    }
    private var needsRareRewardChoice: Bool {
        recoveryOrigin == .local
            && !didStart
            && !RareRewardMode.hasExplicitSelection(preferences: currentPreferences)
    }
    private var showsThemeNameExternally: Bool {
        prefs?.showsThemeNameExternally ?? false
    }
    private var externalSubjectName: String {
        showsThemeNameExternally ? subjectSnapshot.name : "集中"
    }
    private var snapshot: PomodoroSnapshot { engine.snapshot(at: displayNow) }
    private var accent: Color { Color(hex: subjectSnapshot.colorHex) }
    private var resetSnapshots: [ActivityResetSnapshot] {
        activityResetMarkers.map(\.policySnapshot)
    }
    private var currentSyncedFocusTimers: [SyncedFocusTimer] {
        syncedFocusTimers.filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetSnapshots)
        }
    }
    private var currentFocusDeviceClaims: [FocusTimerDeviceClaim] {
        focusDeviceClaims.filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetSnapshots)
        }
    }
    private var currentGachaStates: [GachaState] {
        gachaStates.filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetSnapshots)
        }
    }
    private var currentGachaState: GachaState? {
        currentGachaStates.max { lhs, rhs in
            if lhs.rewardCreditGrams != rhs.rewardCreditGrams {
                return lhs.rewardCreditGrams < rhs.rewardCreditGrams
            }
            let lhsIsCanonical = lhs.id == BoundedLaunchPreparation.canonicalGachaID
            let rhsIsCanonical = rhs.id == BoundedLaunchPreparation.canonicalGachaID
            if lhsIsCanonical != rhsIsCanonical {
                return !lhsIsCanonical && rhsIsCanonical
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
    private var currentSessionID: UUID? {
        pendingCompletion?.sessionID ?? engine.currentSessionID
    }
    private var focusSyncFingerprint: [String] {
        let timerValues = syncedFocusTimers.map {
            "timer-\($0.sessionID.uuidString)-\($0.statusRaw)-\($0.revision)-\($0.updatedAt.timeIntervalSince1970)"
        }
        let claimValues = focusDeviceClaims.map {
            "claim-\($0.sessionID.uuidString)-\($0.deviceID)-\($0.sequence)-\($0.releasedAt?.timeIntervalSince1970 ?? -1)"
        }
        return (timerValues + claimValues).sorted()
    }
    private var ownsCurrentTimer: Bool {
        guard allowsLocalNotifications, let currentSessionID else { return false }
        let claims = currentFocusDeviceClaims.map(\.policySnapshot)
        guard let owner = FocusSyncPolicy.notificationOwner(
            for: currentSessionID,
            claims: claims
        ) else {
            // A just-created local timer can render before its inserted claim
            // reaches @Query. Cloud recoveries never enter FocusView until the
            // explicit adoption transaction has inserted a claim.
            return recoveryOrigin == .local
        }
        return owner == deviceID
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(
                colors: [accent.opacity(0.10), .clear],
                center: .center,
                startRadius: 10,
                endRadius: 330
            )
            .ignoresSafeArea()

            if needsRareRewardChoice {
                RareRewardPreFocusChoiceView(
                    selection: $rareRewardChoice,
                    errorMessage: rareRewardChoiceError,
                    isSaving: isSavingRareRewardChoice,
                    onConfirm: saveRareRewardChoiceAndStart,
                    onCancel: { dismiss() }
                )
                .transition(.opacity)
            } else if let completion {
                FocusCompletionView(
                    completion: completion,
                    subjectColor: accent,
                    reduceMotion: reduceMotion,
                    onStartBreak: startBreak,
                    onReturnToJar: { dismiss() }
                )
                .transition(.opacity)
            } else if let pendingCompletion {
                completionCommitView(pendingCompletion)
                    .transition(.opacity)
            } else if breakFinished {
                BreakFinishedView { dismiss() }
                    .transition(.opacity)
            } else {
                timerContent
            }
        }
        .foregroundStyle(TsumibenTheme.text)
        .interactiveDismissDisabled()
        .statusBarHidden()
        .task { await activate() }
        .onReceive(ticker) { date in
            displayNow = date
            // Absolute end dates keep advancing while locked/backgrounded. Do
            // not consume completion in the brief inactive run-loop window:
            // doing so can cancel the already-scheduled OS notification before
            // it is delivered. The active transition resolves the same end date.
            guard scenePhase == .active else { return }
            advanceIfNeeded(
                at: date,
                uptime: ContinuousUptime.now()
            )
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhase(to: newPhase)
            if newPhase == .active {
                Task { await synchronizeCompletionNotificationIfNeeded() }
            }
        }
        .onChange(of: focusSyncFingerprint) { _, _ in
            if ownsCurrentTimer {
                Task { await refreshExternalTimerPresentation() }
            } else {
                enforceCloudOwnership()
            }
        }
        .onChange(of: showsThemeNameExternally) { _, _ in
            guard ownsCurrentTimer else { return }
            Task { await refreshExternalTimerPresentation() }
        }
        .onChange(of: resetSnapshots) { _, _ in
            enforceActivityReset()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .alert("今日はここまで", isPresented: $showGiveUpConfirmation) {
            Button("続ける", role: .cancel) {}
            Button(Constants.UIStrings.giveUp, role: .destructive) { giveUp() }
        } message: {
            Text("この回の粒は積まれません。これまでの瓶はそのままです。")
        }
        .alert("タイマーを開始できませんでした", isPresented: Binding(
            get: { setupErrorMessage != nil },
            set: { if !$0 { setupErrorMessage = nil } }
        )) {
            Button("閉じる", role: .cancel) { dismiss() }
        } message: {
            Text(setupErrorMessage ?? "")
        }
        .alert("操作を完了できませんでした", isPresented: Binding(
            get: { operationErrorMessage != nil },
            set: { if !$0 { operationErrorMessage = nil } }
        )) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(operationErrorMessage ?? "")
        }
    }

    private var timerContent: some View {
        GeometryReader { proxy in
            let ringSize = FocusTimerLayoutPolicy.ringSize(in: proxy.size)
            ScrollView {
                VStack(spacing: 0) {
            HStack {
                Color.clear
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)

                Spacer()

                VStack(spacing: 2) {
                    HStack(spacing: 7) {
                        Circle().fill(accent).frame(width: 8, height: 8)
                        Text(subjectSnapshot.name)
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                    }
                    Text(phaseLabel)
                        .font(.caption2)
                        .foregroundStyle(TsumibenTheme.muted)
                }

                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Spacer(minLength: 18)

            FocusTimerRing(
                size: ringSize,
                progress: snapshot.progress,
                remainingTime: formattedTime(snapshot.remainingSeconds),
                accessibleRemainingTime: accessibleTime(snapshot.remainingSeconds),
                modeLabel: timerModeLabel,
                isBreakMode: snapshot.phase.isBreak || engine.containsRecoverableBreak,
                isPaused: snapshot.phase == .paused,
                accent: accent,
                reduceMotion: reduceMotion
            )

            if fairnessNotice {
                Label("端末時刻の大きな変化を検出。この回だけ自己申告あつかいです", systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(TsumibenTheme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .transition(.opacity)
            } else {
                completionNotificationStatus
                    .padding(.top, 24)
            }

            Spacer(minLength: 18)

            VStack(spacing: 12) {
                Button(action: togglePause) {
                    Label(
                        snapshot.phase == .paused ? Constants.UIStrings.resume : Constants.UIStrings.pause,
                        systemImage: snapshot.phase == .paused ? "play.fill" : "pause.fill"
                    )
                }
                .buttonStyle(TsumibenPrimaryButtonStyle(tintHex: subjectSnapshot.colorHex))

                if snapshot.phase.isBreak || engine.containsRecoverableBreak {
                    Button("休憩をスキップ", action: skipBreak)
                        .buttonStyle(TsumibenSecondaryButtonStyle())
                } else {
                    Button(Constants.UIStrings.giveUp) { showGiveUpConfirmation = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TsumibenTheme.muted)
                        .frame(minHeight: 44)
                        .buttonStyle(TsumibenBareButtonStyle())
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var phaseLabel: String {
        switch snapshot.phase {
        case .shortBreak: "5分休憩"
        case .longBreak: "15分休憩"
        case .paused where completion == nil: engine.currentSource == .timerDemoted ? "自己申告あつかい・一時停止" : "一時停止"
        default: durationTitle
        }
    }

    private var durationTitle: String {
#if DEBUG
        if duration == .demo { return "12秒デモ" }
#endif
        return "\(duration.minutes ?? 0)分集中"
    }

    private var timerModeLabel: String {
        switch snapshot.phase {
        case .shortBreak, .longBreak:
            "BREAK"
        case .paused:
            "一時停止"
        default:
            "FOCUS"
        }
    }

    @ViewBuilder
    private var completionNotificationStatus: some View {
        switch notificationScheduleState {
        case .scheduled where notifications.isAuthorized:
            Label("ロック中もタイマーは進み、終了時に通知します", systemImage: "bell.badge.fill")
                .font(.caption)
                .foregroundStyle(TsumibenTheme.muted)
        case .scheduling:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("終了通知を設定しています")
                    .font(.caption)
            }
            .foregroundStyle(TsumibenTheme.muted)
        case let .failed(message):
            VStack(spacing: 7) {
                Button {
                    Task { await synchronizeCompletionNotificationIfNeeded() }
                } label: {
                    Label("通知を予約できませんでした。もう一度試す", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(TsumibenBareButtonStyle())
                .frame(minHeight: 44)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(TsumibenTheme.muted)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(TsumibenTheme.amber)
            .padding(.horizontal, 24)
        default:
            notificationPermissionAction
        }
    }

    @ViewBuilder
    private var notificationPermissionAction: some View {
        if notifications.authorizationStatus == .denied {
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            } label: {
                Label("ロック中も進みます。終了通知は端末の設定から", systemImage: "bell.slash")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(TsumibenBareButtonStyle())
            .frame(minHeight: 44)
            .foregroundStyle(TsumibenTheme.amber)
        } else if notifications.isAuthorized {
            Button {
                Task { await scheduleCurrentCompletionNotification() }
            } label: {
                Label("終了通知を設定", systemImage: "bell")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(TsumibenBareButtonStyle())
            .frame(minHeight: 44)
            .foregroundStyle(TsumibenTheme.amber)
        } else {
            Button {
                Task { await enableCompletionNotification() }
            } label: {
                Label("ロック中も進みます。終了通知を許可", systemImage: "bell")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(TsumibenBareButtonStyle())
            .frame(minHeight: 44)
            .foregroundStyle(TsumibenTheme.amber)
        }
    }

    @MainActor
    private func activate() async {
        guard !didActivate else { return }
        // No local timer begins until an informed choice is synchronized.
        // Recovery must continue even for a legacy envelope; its completion is
        // deterministically normal because unresolved preferences resolve off.
        guard !needsRareRewardChoice else { return }
        didActivate = true
        configureSensoryPreferences()
        await notifications.refreshAuthorizationStatus()

        if didStart {
            guard ActivityResetPolicy.state(
                of: dataEpochID,
                markers: resetSnapshots
            ) == .current else {
                enforceActivityReset()
                return
            }
            let now = Date.now
            displayNow = now
            UIApplication.shared.isIdleTimerDisabled = snapshot.phase == .focusing
                && (prefs?.keepScreenAwake ?? true)

            if let pendingCompletion {
                await commitCompletion(pendingCompletion)
                return
            }

            saveRecoveryState()
            advanceIfNeeded(
                at: now,
                uptime: ContinuousUptime.now()
            )
            if pendingCompletion == nil {
                await refreshExternalTimerPresentation()
            }
            return
        }

        didStart = true
        let now = Date.now
        let sessionID = UUID()
        do {
            dataEpochID = try ActivityResetStore.currentEpochID(context: modelContext)
            try engine.startFocus(
                duration: duration,
                isPro: PurchaseManager.shared.isPro,
                now: now,
                sessionID: sessionID
            )
            displayNow = now
            clockAnchor = ClockAnchor(
                wallDate: now,
                systemUptime: ContinuousUptime.now()
            )
            saveRecoveryState()
            UIApplication.shared.isIdleTimerDisabled = prefs?.keepScreenAwake ?? true

            if let endDate = engine.endDate {
                if notifications.isAuthorized {
                    await scheduleCurrentCompletionNotification()
                }
                _ = try? await FocusActivityManager.shared.start(
                    sessionID: sessionID,
                    subjectName: externalSubjectName,
                    subjectColorHex: subjectSnapshot.colorHex,
                    durationSeconds: duration.seconds,
                    endDate: endDate
                )
            }
        } catch {
            setupErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func saveRareRewardChoiceAndStart() {
        guard let rareRewardChoice, !isSavingRareRewardChoice else { return }
        guard !currentPreferences.isEmpty else {
            rareRewardChoiceError = "設定の保存先を準備できませんでした。いったん戻り、もう一度お試しください。"
            return
        }

        isSavingRareRewardChoice = true
        rareRewardChoiceError = nil
        let changedAt = Date.now
        for preference in currentPreferences {
            preference.rareRewardModeRawValue = rareRewardChoice.rawValue
            preference.rareRewardModeUpdatedAt = changedAt
        }
        do {
            try modelContext.save()
            isSavingRareRewardChoice = false
            Task { await activate() }
        } catch {
            modelContext.rollback()
            isSavingRareRewardChoice = false
            rareRewardChoiceError = "レア粒の選択を保存できませんでした。タイマーはまだ始まっていません。\n\(error.localizedDescription)"
        }
    }

    @MainActor
    private func enableCompletionNotification() async {
        let granted = await notifications.requestAuthorization()
        guard granted else {
            if let error = notifications.lastErrorDescription {
                notificationScheduleState = .failed(message: error)
            } else {
                notificationScheduleState = .idle
            }
            return
        }
        await scheduleCurrentCompletionNotification()
    }

    @MainActor
    private func synchronizeCompletionNotificationIfNeeded() async {
        await notifications.refreshAuthorizationStatus()
        await scheduleCurrentCompletionNotification()
    }

    @MainActor
    private func scheduleCurrentCompletionNotification() async {
        guard ownsCurrentTimer,
              notifications.isAuthorized,
              engine.snapshot(at: .now).phase == .focusing,
              let sessionID = engine.currentSessionID,
              let endDate = engine.endDate,
              endDate > .now
        else {
            notificationScheduleState = .idle
            return
        }

        notificationScheduleState = .scheduling
        do {
            try await notifications.scheduleFocusCompletion(
                sessionID: sessionID,
                subjectName: subjectSnapshot.name,
                showsSubjectName: showsThemeNameExternally,
                endDate: endDate,
                playsSound: prefs?.soundOn ?? true
            )
            notificationScheduleState = .scheduled
        } catch {
            notificationScheduleState = .failed(message: error.localizedDescription)
        }
    }

    @MainActor
    private func refreshExternalTimerPresentation() async {
        // Both local notifications and Live Activities belong only to the
        // winning device claim. This guard also covers the narrow handoff race
        // where ownership changes after RootView creates this screen but before
        // its first activation task runs.
        guard ownsCurrentTimer else {
            enforceCloudOwnership()
            return
        }
        await synchronizeCompletionNotificationIfNeeded()
        guard engine.snapshot(at: .now).phase == .focusing,
              let sessionID = engine.currentSessionID,
              let endDate = engine.endDate,
              endDate > .now
        else { return }

        // Activity attributes are immutable. Replacing the one active Live
        // Activity is the only way to apply an opt-out immediately when the
        // setting arrives from this device or iCloud.
        _ = try? await FocusActivityManager.shared.start(
            sessionID: sessionID,
            subjectName: externalSubjectName,
            subjectColorHex: subjectSnapshot.colorHex,
            durationSeconds: duration.seconds,
            endDate: endDate
        )
    }

    private func configureSensoryPreferences() {
        SoundSynth.shared.isEnabled = prefs?.soundOn ?? true
        Haptics.shared.isEnabled = prefs?.hapticsOn ?? true
    }

    private func advanceIfNeeded(
        at now: Date,
        uptime: TimeInterval
    ) {
        // Breaks are local sensory intervals and have no focus session ID.
        // Ownership gates only the shared focus award/notification path.
        if engine.containsRecoverableFocus {
            guard ownsCurrentTimer else { return }
        }
        reconcileClockIntegrity(at: now, uptime: uptime)
        guard let event = engine.advance(at: now, observedUptime: uptime) else { return }
        switch event {
        case let .focusCompleted(result):
            notificationScheduleState = .idle
            let finalized = FairnessPolicy.finalizedCompletion(
                result,
                clockAnchor: clockAnchor
            )
            fairnessNotice = finalized.source == .timerDemoted
            handleFocusCompletion(finalized)
        case .breakCompleted:
            FocusPersistence.clear()
            withAnimation { breakFinished = true }
        }
    }

    /// Backgrounding is not a fairness event. Wall time continues against the
    /// saved absolute end date. The continuous clock is consulted separately
    /// only to catch a clear wall-clock jump while preserving normal lock,
    /// phone-call and Control Center behavior.
    private func reconcileClockIntegrity(
        at now: Date,
        uptime: TimeInterval
    ) {
        guard engine.snapshot(at: now).phase == .focusing,
              let clockAnchor
        else { return }

        let integrity = FairnessPolicy.clockIntegrity(
            from: clockAnchor,
            completionDate: now,
            completionUptime: uptime
        )

        switch integrity {
        case .valid:
            break
        case .changed:
            guard engine.currentSource == .timer else { return }
            do {
                try engine.demoteCurrentFocus()
                fairnessNotice = true
                saveRecoveryState()
            } catch {
                operationErrorMessage = error.localizedDescription
            }
        case .uptimeReset, .unverifiable:
            // A reboot or an anchor written by an older app version is not
            // evidence of manipulation. Re-anchor so subsequent changes in
            // this boot can still be checked.
            self.clockAnchor = ClockAnchor(
                wallDate: now,
                systemUptime: uptime
            )
            saveRecoveryState()
        }
    }

    private func handleFocusCompletion(_ result: PomodoroCompletion) {
        guard pendingCompletion == nil else { return }
        pendingCompletion = result
        saveRecoveryState(pendingCompletion: result)
        signalCompletionIfNeeded(result)
        Task { await commitCompletion(result) }
    }

    @MainActor
    private func commitCompletion(_ result: PomodoroCompletion) async {
        guard !isCommittingCompletion else { return }
        isCommittingCompletion = true
        defer { isCommittingCompletion = false }
        completionSaveError = nil
        completionWasRejectedForOwnership = false
        let persistenceResult: FocusCompletionPersistenceResult
        do {
            persistenceResult = try persistCompletion(result)
        } catch {
            modelContext.rollback()
            saveRecoveryState(pendingCompletion: result)
            completionSaveError = error.localizedDescription
            announceCompletionSaveFailure()
            return
        }

        if !persistenceResult.mayRetireRecovery {
            // Another device may still be committing the same logical focus.
            // Keep the local envelope until its StudySession arrives and a retry
            // can resolve as `alreadyMaterialized`; never present rejection as a
            // successful local save.
            saveRecoveryState(pendingCompletion: result)
            completionWasRejectedForOwnership = true
            completionSaveError = "この完走は別の端末が保存を担当しています。iCloudの記録が届くまで、この端末の復元情報を保持します。しばらく待ってから保存状態を確認してください。"
            announceCompletionSaveFailure()
            return
        }

        FocusPersistence.clear()
        DeferredFocusCompletionStore.clear(sessionID: result.sessionID)
        if router.deferredFocusRecovery?.id == result.sessionID {
            router.deferredFocusRecovery = nil
        }
        UserDefaults.standard.set(
            result.sessionID.uuidString.lowercased(),
            forKey: FocusPersistence.localCompletionIDKey
        )

        if case let .inserted(awardedKind) = persistenceResult {
            Analytics.shared.track(.pomodoroComplete)
            Analytics.shared.track(.drop)
            if awardedKind == .gold { Analytics.shared.track(.gold) }
        }

        await FocusActivityManager.shared.complete(
            sessionID: result.sessionID,
            grams: result.grams
        )
        try? await Task.sleep(for: .seconds(Constants.Jar.completionDropDelay))
        // Home is still mounted behind this cover. Dismissing now reveals the
        // real SpriteKit drop; its contact callback owns the synchronized
        // thud, landing haptic, dust and camera shake.
        dismiss()
    }

    @MainActor
    private func persistCompletion(
        _ result: PomodoroCompletion
    ) throws -> FocusCompletionPersistenceResult {
        guard ActivityResetPolicy.state(
            of: dataEpochID,
            markers: resetSnapshots
        ) == .current else {
            throw FocusCloudSyncError.activityWasReset
        }
        let source = result.source

        let completionID = result.sessionID
        let descriptor = FetchDescriptor<StudySession>(
            predicate: #Predicate { $0.id == completionID }
        )
        let existingSessionIDs = Set(try modelContext.fetch(descriptor)
            .filter {
                ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetSnapshots)
            }
            .map(\.id))
        if existingSessionIDs.contains(completionID) {
            return .alreadyMaterialized
        }

        var claims = try FocusCloudSyncStore.claims(
            sessionID: completionID,
            context: modelContext
        )
            .map(\.policySnapshot)
        var owner = FocusSyncPolicy.notificationOwner(
            for: completionID,
            claims: claims
        )
        if owner == nil, recoveryOrigin == .local {
            let claim = try FocusCloudSyncStore.claimOwnership(
                sessionID: completionID,
                context: modelContext,
                deviceID: deviceID
            )
            claims.append(claim.policySnapshot)
            owner = deviceID
        }

        let materializationDecision = FocusSyncPolicy.completionMaterializationDecision(
            sessionID: completionID,
            existingSessionIDs: existingSessionIDs,
            currentDeviceID: deviceID,
            claims: claims
        )
        guard materializationDecision == .insert, owner == deviceID else {
            return .rejectedOwnership
        }

        let gacha = currentGachaState ?? {
            let value = GachaState(dataEpochID: dataEpochID)
            modelContext.insert(value)
            return value
        }()
        var generator = SystemRandomNumberGenerator()
        let roll = RareRewardPolicy.draw(
            source: source,
            completedSeconds: result.seconds,
            completedGrams: result.grams,
            mode: rareRewardMode,
            state: gacha,
            using: &generator
        )
        let session = StudySession(
            id: result.sessionID,
            subject: subject,
            startAt: result.startedAt,
            endAt: result.endedAt,
            seconds: result.seconds,
            source: source,
            pebbleKind: roll.kind,
            grams: result.grams,
            deviceDayKey: FairnessPolicy.deviceDayKey(for: result.endedAt),
            subjectNameSnapshot: subjectSnapshot.name,
            subjectColorHexSnapshot: subjectSnapshot.colorHex,
            subjectIDSnapshot: subjectSnapshot.id,
            rareRewardRuleVersion: Constants.Gacha.creditRuleVersion,
            rareRewardParticipated: roll.participated,
            rareRewardCreditedGrams: roll.acceptedContributionGrams,
            rareRewardOutcomesRawValue: RareRewardOutcomeCodec.encode(
                roll.creditOutcomes
            ),
            dataEpochID: dataEpochID
        )
        modelContext.insert(session)
        try FocusCloudSyncStore.markTerminal(
            sessionID: result.sessionID,
            status: .completed,
            context: modelContext,
            deviceID: deviceID,
            at: result.observedAt
        )
#if DEBUG && targetEnvironment(simulator)
        if UITestFaultInjection.consumeFocusCompletionSaveFailure() {
            throw UITestInjectedPersistenceError.focusCompletionSaveOnce
        }
#endif
        try modelContext.save()
        return .inserted(roll.kind)
    }

    private func signalCompletionIfNeeded(_ result: PomodoroCompletion) {
        guard !didSignalCompletion else { return }
        didSignalCompletion = true
        NotificationManager.shared.cancelFocusCompletion(sessionID: result.sessionID)
        notificationScheduleState = .idle
        SoundSynth.shared.playCompletionChime()
        Haptics.shared.playTimerCompletion()
        UIApplication.shared.isIdleTimerDisabled = false
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(
                notification: .announcement,
                argument: "集中が完了しました。\(subjectSnapshot.name)、\(result.grams)グラムを保存しています"
            )
        }
    }

    /// A failed commit replaces a passive progress state with recovery
    /// controls. Move VoiceOver to the retry action after SwiftUI has mounted
    /// it, while leaving sighted keyboard/switch users' focus untouched.
    private func announceCompletionSaveFailure() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        Task { @MainActor in
            await Task.yield()
            completionSaveRetryFocused = true
            UIAccessibility.post(
                notification: .announcement,
                argument: "記録をまだ安全に保存できていません。完走は端末に保護されています"
            )
        }
    }

    private func saveRecoveryState(pendingCompletion: PomodoroCompletion? = nil) {
        let resolvedPendingCompletion = pendingCompletion ?? self.pendingCompletion
        let envelope = FocusRecoveryEnvelope(
            engine: engine,
            subject: subjectSnapshot,
            clockAnchor: clockAnchor,
            pendingCompletion: resolvedPendingCompletion,
            savedAt: .now,
            dataEpochID: dataEpochID
        )
        FocusPersistence.save(envelope)

        let status: SyncedFocusStatus
        if resolvedPendingCompletion != nil {
            status = .completionPending
        } else {
            switch engine.snapshot(at: .now).phase {
            case .focusing:
                status = .running
            case .paused:
                status = .paused
            default:
                return
            }
        }

        do {
            _ = try FocusCloudSyncStore.upsert(
                envelope: envelope,
                status: status,
                context: modelContext,
                deviceID: deviceID,
                claimIfUnowned: allowsLocalNotifications,
                now: envelope.savedAt
            )
            try modelContext.save()
        } catch {
            // Local recovery remains authoritative while offline. SwiftData
            // retries CloudKit transport after the local transaction succeeds;
            // serialization/store failures surface through the existing timer
            // retry path rather than discarding a running focus.
        }
    }

    private func completionCommitView(_ result: PomodoroCompletion) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 70)
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.16))
                        .frame(width: 116, height: 116)
                    Image(systemName: completionSaveError == nil ? "arrow.down.to.line.compact" : "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(completionSaveError == nil ? accent : TsumibenTheme.amber)
                }
                VStack(spacing: 8) {
                    Text(completionSaveError == nil ? "粒を瓶へ運んでいます" : "記録をまだ安全に保存できていません")
                        .font(TsumibenTheme.brand(25))
                        .multilineTextAlignment(.center)
                    Text("\(subjectSnapshot.name)  +\(result.grams)g")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(TsumibenTheme.muted)
                }

                if let completionSaveError {
                    Text(completionSaveError)
                        .font(.caption)
                        .foregroundStyle(TsumibenTheme.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .accessibilityIdentifier("focus.completion-save.error")
                    Button {
                        Task { await commitCompletion(result) }
                    } label: {
                        Label(
                            completionWasRejectedForOwnership
                                ? "保存状態を確認する"
                                : "もう一度保存する",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(TsumibenPrimaryButtonStyle(tintHex: subjectSnapshot.colorHex))
                    .padding(.horizontal, 24)
                    .disabled(isCommittingCompletion)
                    .accessibilityFocused($completionSaveRetryFocused)
                    .accessibilityIdentifier("focus.completion-save.retry")

                    Button {
                        returnHomeKeepingCompletion(result)
                    } label: {
                        Label("完走を保護してホームへ戻る", systemImage: "house.fill")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(TsumibenBareButtonStyle())
                    .foregroundStyle(TsumibenTheme.text)
                    .padding(.horizontal, 24)
                    .accessibilityHint("完走は端末に残り、ホームから保存を再試行できます")
                    .accessibilityIdentifier("focus.completion-save.protect")
                } else {
                    ProgressView()
                        .tint(accent)
                        .controlSize(.large)
                        .accessibilityLabel("記録を保存中")
                }
                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: UIScreen.main.bounds.height)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func returnHomeKeepingCompletion(_ result: PomodoroCompletion) {
        saveRecoveryState(pendingCompletion: result)
        DeferredFocusCompletionStore.mark(sessionID: result.sessionID)
        router.deferredFocusRecovery = RecoveredFocusRequest(
            subject: subject,
            subjectSnapshot: subjectSnapshot,
            engine: engine,
            clockAnchor: clockAnchor,
            pendingCompletion: result,
            dataEpochID: dataEpochID,
            origin: recoveryOrigin,
            allowsLocalNotifications: allowsLocalNotifications
        )
        UIApplication.shared.isIdleTimerDisabled = false
        router.showToast(
            "完走は端末に保護されています。ホームから保存を再試行できます",
            symbol: "checkmark.shield.fill",
            duration: .seconds(6)
        )
        dismiss()
    }

    private func togglePause() {
        let now = Date.now
        do {
            if snapshot.phase == .paused {
                try engine.resume(at: now)
                if let sessionID = engine.currentSessionID, let endDate = engine.endDate {
                    Task {
                        if notifications.isAuthorized {
                            await scheduleCurrentCompletionNotification()
                        }
                        await FocusActivityManager.shared.resume(sessionID: sessionID, endDate: endDate)
                    }
                }
            } else {
                try engine.pause(at: now)
                if let sessionID = engine.currentSessionID {
                    NotificationManager.shared.cancelFocusCompletion(sessionID: sessionID)
                    notificationScheduleState = .idle
                    Task {
                        await FocusActivityManager.shared.pause(
                            sessionID: sessionID,
                            remainingSeconds: engine.snapshot(at: now).remainingSeconds
                        )
                    }
                }
            }
            UIApplication.shared.isIdleTimerDisabled = engine.snapshot(at: now).phase == .focusing
                && (prefs?.keepScreenAwake ?? true)
            saveRecoveryState()
            displayNow = now
        } catch {
            operationErrorMessage = error.localizedDescription
        }
    }

    private func startBreak() {
        do {
            try engine.startBreak(now: .now)
            completion = nil
            displayNow = .now
            saveRecoveryState()
            UIApplication.shared.isIdleTimerDisabled = false
        } catch {
            operationErrorMessage = error.localizedDescription
        }
    }

    private func skipBreak() {
        try? engine.skipBreak()
        FocusPersistence.clear()
        breakFinished = true
    }

    private func giveUp() {
        operationErrorMessage = nil
        let sessionID = engine.currentSessionID
        if let sessionID {
            do {
                // Persist the shared cancellation before mutating the local
                // engine or clearing its recovery envelope. If the local store
                // cannot commit the tombstone, the visible timer, notification
                // and recovery state all remain live and retryable.
                try FocusCloudSyncStore.markTerminal(
                    sessionID: sessionID,
                    status: .cancelled,
                    context: modelContext,
                    deviceID: deviceID
                )
                try modelContext.save()
            } catch {
                modelContext.rollback()
                operationErrorMessage = "終了状態を安全に保存できませんでした。タイマーは継続しています。もう一度お試しください。"
                return
            }
        }
        _ = engine.cancel()
        FocusPersistence.clear()
        UIApplication.shared.isIdleTimerDisabled = false
        if let sessionID {
            NotificationManager.shared.cancelFocusCompletion(sessionID: sessionID)
            Task { await FocusActivityManager.shared.cancel(sessionID: sessionID) }
        }
        dismiss()
    }

    private func enforceCloudOwnership() {
        guard pendingCompletion == nil,
              completion == nil,
              let sessionID = engine.currentSessionID else { return }

        let owner = FocusSyncPolicy.notificationOwner(
            for: sessionID,
            claims: currentFocusDeviceClaims.map(\.policySnapshot)
        )
        let canonicalSessionID = FocusSyncPolicy.canonicalActive(
            from: currentSyncedFocusTimers.map(\.policySnapshot)
        )?.sessionID
        let lostOwnership = owner != nil && owner != deviceID
        let superseded = !currentSyncedFocusTimers.isEmpty
            && canonicalSessionID != sessionID
        guard lostOwnership || superseded else { return }

        NotificationManager.shared.cancelFocusCompletion(sessionID: sessionID)
        notificationScheduleState = .idle
        FocusPersistence.clear()
        UIApplication.shared.isIdleTimerDisabled = false
        Task { await FocusActivityManager.shared.cancel(sessionID: sessionID) }
        router.showToast(
            lostOwnership
                ? "タイマーは別の端末へ引き継がれました"
                : "先に始めた別端末のタイマーを残しました",
            symbol: "icloud.and.arrow.up"
        )
        dismiss()
    }

    private func enforceActivityReset() {
        guard ActivityResetPolicy.state(
            of: dataEpochID,
            markers: resetSnapshots
        ) != .current else { return }
        if let sessionID = currentSessionID {
            NotificationManager.shared.cancelFocusCompletion(sessionID: sessionID)
            Task { await FocusActivityManager.shared.cancel(sessionID: sessionID) }
        }
        notificationScheduleState = .idle
        FocusPersistence.clear()
        UIApplication.shared.isIdleTimerDisabled = false
        router.showToast(
            "別の端末で記録がリセットされたため、このタイマーを終了しました",
            symbol: "trash"
        )
        dismiss()
    }

    private func handleScenePhase(to newPhase: ScenePhase) {
        if newPhase == .inactive || newPhase == .background {
            saveRecoveryState()
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }

        guard newPhase == .active else { return }

        let returnDate = Date.now
        let returnUptime = ContinuousUptime.now()
        displayNow = returnDate
        UIApplication.shared.isIdleTimerDisabled = engine.snapshot(at: returnDate).phase == .focusing
            && (prefs?.keepScreenAwake ?? true)
        advanceIfNeeded(
            at: returnDate,
            uptime: returnUptime
        )
    }

    private func formattedTime(_ total: Int) -> String {
        let safe = max(0, total)
        return String(format: "%02d:%02d", safe / 60, safe % 60)
    }

    private func accessibleTime(_ total: Int) -> String {
        let safe = max(0, total)
        return "残り\(safe / 60)分\(safe % 60)秒"
    }
}

private struct RareRewardPreFocusChoiceView: View {
    @Binding var selection: RareRewardMode?
    let errorMessage: String?
    let isSaving: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                RareRewardChoicePanel(
                    selection: $selection,
                    eyebrow: "BEFORE YOUR FIRST FOCUS",
                    title: "タイマーの前に、1つだけ。",
                    introduction: "まだレア粒の扱いを選んでいません。説明なしで抽選creditを貯め始めないため、最初の実測タイマーより前に確認します。"
                )

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("focus.rare-reward-choice.error")
                }

                Button(action: onConfirm) {
                    if isSaving {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Text("この選択でタイマーへ")
                    }
                }
                .buttonStyle(TsumibenPrimaryButtonStyle())
                .disabled(selection == nil || isSaving)
                .accessibilityHint(
                    selection == nil
                        ? "3つの選択肢から1つ選んでください"
                        : "選択をiCloudへ保存してからタイマーを開始します"
                )
                .accessibilityIdentifier("focus.rare-reward-choice.confirm")

                Button("今は戻る", action: onCancel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TsumibenTheme.muted)
                    .frame(minHeight: 44)
                    .buttonStyle(TsumibenBareButtonStyle())
                    .disabled(isSaving)
                    .accessibilityHint("選択やタイマーを開始せず瓶へ戻ります")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.black.ignoresSafeArea())
        .accessibilityIdentifier("focus.rare-reward-choice")
    }
}

enum FocusTimerLayoutPolicy {
    static func ringSize(in container: CGSize) -> CGFloat {
        guard container.width.isFinite,
              container.height.isFinite,
              container.width > 0,
              container.height > 0
        else { return 1 }

        let heightCap: CGFloat = container.height < 650 ? 214 : 286
        return max(1, min(container.width - 64, heightCap))
    }
}

/// A clockwise elapsed-time dial. The quiet full-circle track communicates the
/// total interval, while the colored arc grows from twelve o'clock and its
/// bright head marks the current position even in a still screenshot.
private struct FocusTimerRing: View {
    let size: CGFloat
    let progress: Double
    let remainingTime: String
    let accessibleRemainingTime: String
    let modeLabel: String
    let isBreakMode: Bool
    let isPaused: Bool
    let accent: Color
    let reduceMotion: Bool

    @ScaledMetric(relativeTo: .largeTitle) private var scaledTimerSize = Constants.Typography.timerSize
    @ScaledMetric(relativeTo: .body) private var scaledLineWidth: CGFloat = 9

    private var normalizedProgress: Double {
        min(1, max(0, progress))
    }

    private var elapsedPercent: Int {
        Int((normalizedProgress * 100).rounded())
    }

    private var lineWidth: CGFloat {
        min(14, max(8, scaledLineWidth))
    }

    private var timerSize: CGFloat {
        min(scaledTimerSize, size * 0.33)
    }

    private var arcHeadOffset: CGSize {
        let radius = max(0, Double((size - lineWidth) / 2))
        let angle = normalizedProgress * 2 * Double.pi
        return CGSize(
            width: CGFloat(sin(angle) * radius),
            height: CGFloat(-cos(angle) * radius)
        )
    }

    private var accessibleMode: String {
        isBreakMode ? "休憩タイマー" : "集中タイマー"
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.09), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: normalizedProgress)
                .stroke(
                    accent,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: accent.opacity(0.38), radius: 14)
                .animation(
                    reduceMotion ? nil : .linear(duration: 0.25),
                    value: normalizedProgress
                )

            // A fixed origin and a moving head make direction unambiguous.
            Circle()
                .fill(accent.opacity(normalizedProgress == 0 ? 0.58 : 0.9))
                .frame(width: max(5, lineWidth * 0.58), height: max(5, lineWidth * 0.58))
                .offset(y: -(size - lineWidth) / 2)
                .accessibilityHidden(true)

            if normalizedProgress > 0, normalizedProgress < 1 {
                Circle()
                    .fill(isPaused ? TsumibenTheme.amber : .white)
                    .overlay {
                        Circle().stroke(accent, lineWidth: 2)
                    }
                    .frame(width: lineWidth, height: lineWidth)
                    .shadow(color: accent.opacity(0.72), radius: 7)
                    .offset(arcHeadOffset)
                    .animation(
                        reduceMotion ? nil : .linear(duration: 0.25),
                        value: normalizedProgress
                    )
                    .accessibilityHidden(true)
            }

            VStack(spacing: 9) {
                Text(remainingTime)
                    .font(.system(size: timerSize, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.62)
                    .lineLimit(1)
                    .contentTransition(
                        reduceMotion ? .identity : .numericText(countsDown: true)
                    )
                Text("\(modeLabel)  ·  \(elapsedPercent)% 経過")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(isPaused ? TsumibenTheme.amber : TsumibenTheme.muted)
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
            }
            .padding(max(24, lineWidth * 2.5))
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleMode)
        .accessibilityValue(
            "\(accessibleRemainingTime)、\(elapsedPercent)パーセント経過"
                + (isPaused ? "、一時停止中" : "")
        )
        .accessibilityHint(isPaused ? "再開ボタンでタイマーを再開できます" : "一時停止ボタンでタイマーを止められます")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private enum FocusNotificationScheduleState: Equatable {
    case idle
    case scheduling
    case scheduled
    case failed(message: String)
}

private struct CompletedDrop: Equatable {
    let kind: PebbleKind
    let grams: Int
    let message: String
    let isDemoted: Bool
}

private struct FocusCompletionView: View {
    let completion: CompletedDrop
    let subjectColor: Color
    let reduceMotion: Bool
    let onStartBreak: () -> Void
    let onReturnToJar: () -> Void

    @State private var landed = false

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            SectionEyebrow(text: "THE DROP")
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(.white.opacity(0.025))
                    .overlay {
                        RoundedRectangle(cornerRadius: 34, style: .continuous)
                            .stroke(TsumibenTheme.glassEdge, lineWidth: 2)
                    }
                Circle()
                    .fill(pebbleFill)
                    .overlay {
                        if completion.isDemoted {
                            Circle().stroke(.white.opacity(0.72), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                        } else {
                            Circle().fill(
                                RadialGradient(colors: [.white.opacity(0.62), .clear], center: .topLeading, startRadius: 0, endRadius: 20)
                            )
                        }
                    }
                    .frame(width: 46, height: 46)
                    .shadow(color: completion.kind == .normal ? .clear : TsumibenTheme.amber.opacity(0.55), radius: 20)
                    .offset(y: landed ? -16 : -300)
                    .animation(
                        reduceMotion ? .none : .interpolatingSpring(stiffness: 125, damping: 13),
                        value: landed
                    )
            }
            .frame(width: 230, height: 330)

            VStack(spacing: 8) {
                Text(completion.message)
                    .font(TsumibenTheme.brand(22))
                    .multilineTextAlignment(.center)
                if completion.isDemoted {
                    Text(Constants.UIStrings.interruptionNote)
                        .font(.caption)
                        .foregroundStyle(TsumibenTheme.muted)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()
            VStack(spacing: 11) {
                Button("休憩をはじめる", action: onStartBreak)
                    .buttonStyle(TsumibenPrimaryButtonStyle())
                Button("瓶を見る", action: onReturnToJar)
                    .buttonStyle(TsumibenSecondaryButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .task {
            if reduceMotion {
                landed = true
            } else {
                try? await Task.sleep(for: .milliseconds(120))
                landed = true
            }
        }
    }

    private var pebbleFill: AnyShapeStyle {
        switch completion.kind {
        case .normal:
            AnyShapeStyle(subjectColor)
        case .gold:
            AnyShapeStyle(RadialGradient(colors: [.white, Color("pebble.gold"), .orange], center: .topLeading, startRadius: 0, endRadius: 46))
        case .prism:
            AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
        }
    }
}

private struct BreakFinishedView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 44))
                .foregroundStyle(TsumibenTheme.amber)
            Text("休憩はここまで")
                .font(TsumibenTheme.brand(30))
            Text("瓶の粒は、そのまま待っています。")
                .foregroundStyle(TsumibenTheme.muted)
            Spacer()
            Button("瓶へ戻る", action: onClose)
                .buttonStyle(TsumibenPrimaryButtonStyle())
                .padding(24)
        }
    }
}
