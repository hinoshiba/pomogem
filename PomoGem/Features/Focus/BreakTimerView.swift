import Combine
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

struct BreakTimerView: View {
    let minutes: Int
    private let originatingFocusSessionID: UUID?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.pomogemReduceMotionOverride) private var reduceMotionOverride
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Query private var preferences: [Prefs]
    @Query private var activityResetMarkers: [ActivityResetMarker]
    @ScaledMetric(relativeTo: .largeTitle) private var timerFontSize: CGFloat = 72
    @State private var sessionID: UUID
    @State private var endDate: Date?
    @State private var clockAnchor: ClockAnchor?
    @State private var now = Date.now
    @State private var didSignalCompletion = false
    @State private var completionAlert = TimerCompletionAlertController.shared
    @State private var notifications = NotificationManager.shared
    @State private var notificationScheduleState: BreakNotificationScheduleState = .idle
    @State private var notificationSchedulingTask: Task<Void, Never>?
    @State private var notificationGeneration = 0
    @State private var isBreakActive = true
    @State private var didEnterBackgroundSinceLastActive = false
    @State private var notificationAuthorizationIsCurrent = false
    @State private var notificationAuthorizationRefreshGeneration = 0
    @State private var scheduledCompletionNotificationDeliveryDate: Date? = nil
    @AccessibilityFocusState private var breakEndButtonFocused: Bool
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(minutes: Int) {
        self.minutes = minutes
        originatingFocusSessionID = nil
        _sessionID = State(initialValue: UUID())
        _clockAnchor = State(initialValue: nil)
        _preferences = Query(PrefsConsumerPolicy.descriptor())
        _activityResetMarkers = Query(
            ActivityResetPolicy.currentMarkerDescriptor()
        )
    }

    init(recovery: BreakRecoveryEnvelope) {
        minutes = recovery.minutes
        originatingFocusSessionID = recovery.originatingFocusSessionID
        _sessionID = State(initialValue: recovery.id)
        _endDate = State(initialValue: recovery.endDate)
        _clockAnchor = State(initialValue: recovery.clockAnchor)
        _scheduledCompletionNotificationDeliveryDate = State(
            initialValue: recovery.scheduledCompletionNotificationDeliveryDate
        )
        _preferences = Query(PrefsConsumerPolicy.descriptor())
        _activityResetMarkers = Query(
            ActivityResetPolicy.currentMarkerDescriptor()
        )
    }

    private var remaining: Int {
        BreakRecoveryPolicy.remainingSeconds(
            minutes: minutes,
            endDate: endDate,
            at: now
        )
    }

    private var resetSnapshots: [ActivityResetSnapshot] {
        activityResetMarkers.map(\.policySnapshot)
    }

    private var resolvedPreferences: PrefsSyncPolicy.ResolvedState? {
        PrefsConsumerPolicy.resolvedState(
            in: preferences,
            markers: resetSnapshots
        )
    }

    private var sensoryPreferences: PrefsSyncPolicy.ResolvedSensoryState {
        PrefsConsumerPolicy.resolvedSensoryState(in: preferences)
    }

    private var sensoryPreferenceValues: [String] {
        [
            String(sensoryPreferences.soundOn),
            String(sensoryPreferences.hapticsOn),
            sensoryPreferences.timerCompletionSound.rawValue,
            sensoryPreferences.timerCompletionHaptic.rawValue
        ]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(colors: [PomoGemTheme.amber.opacity(0.08), .clear], center: .center, startRadius: 0, endRadius: 340).ignoresSafeArea()
            TimerOrientationContainer(sessionID: sessionID) { context in
                VStack(spacing: 0) {
                    GeometryReader { proxy in
                        ScrollView {
                            VStack(spacing: 20) {
                                timerHeader

                                if context.isLandscape && !dynamicTypeSize.isAccessibilitySize {
                                    HStack(spacing: 32) {
                                        VStack(spacing: 16) {
                                            timerFace(spacing: 12)
                                            waitingMessage
                                        }
                                        .frame(maxWidth: .infinity)

                                        VStack(spacing: 20) {
                                            if remaining > 0 {
                                                completionNotificationStatus
                                            }
                                            completionActions
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                    .frame(minHeight: max(0, proxy.size.height - 88))
                                } else {
                                    Spacer(minLength: 8)
                                    timerFace(spacing: 20)
                                    waitingMessage

                                    if remaining > 0 {
                                        completionNotificationStatus
                                    }

                                    Spacer(minLength: 8)
                                    completionActions
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    }

                    if remaining == 0 {
                        // The break-end action (and its alarm's only Stop)
                        // stays pinned on screen at every text size.
                        breakEndButton
                    }
                }
            }
        }
        .statusBarHidden()
        // VoiceOver's two-finger double-tap stops the break-end alarm and
        // returns to the jar, the screen's only action once the break is over.
        .accessibilityAction(.magicTap) {
            guard remaining == 0 else { return }
            closeBreak()
        }
        .task { await prepareBreak() }
        .onReceive(ticker) { date in
            now = date
            updateIdleTimer(at: date)
            if remaining == 0,
               scenePhase == .active,
               notificationAuthorizationIsCurrent {
                guard !notificationScheduleState.isScheduling else { return }
                let completionUptime = ContinuousUptime.now()
                let returnedFromBackground = didEnterBackgroundSinceLastActive
                didEnterBackgroundSinceLastActive = false
                signalBreakCompletionIfNeeded(
                    cue: completionCue(
                        at: date,
                        uptime: completionUptime,
                        recoveredAfterExpiration: false,
                        returnedFromBackground: returnedFromBackground
                    )
                )
            }
        }
        .onChange(of: sensoryPreferenceValues) { _, _ in
            configureSensoryPreferences()
            guard isBreakActive,
                  !didSignalCompletion,
                  let endDate,
                  endDate > .now,
                  notifications.isAuthorized else { return }
            scheduleBreakNotification(endDate: endDate)
        }
        .onChange(of: resolvedPreferences?.keepScreenAwake) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: scenePhase) { _, newPhase in
            updateIdleTimer(sceneIsActive: newPhase == .active)
            if newPhase == .active,
               didEnterBackgroundSinceLastActive,
               completionAlert.isActive(sessionID: sessionID) {
                // Leaving while the break-end alarm repeated counts as Stop.
                // The app-level scene handler records and ends it on the way
                // out (acknowledgeOnLeavingApp); this only covers a loop that
                // is somehow still alive. 「瓶へ戻る」 stays for them to choose.
                TimerCompletionAlertAcknowledgementStore.mark(
                    sessionID: sessionID
                )
                completionAlert.stop(sessionID: sessionID)
            }
            if newPhase == .background {
                didEnterBackgroundSinceLastActive = true
            }
            notificationAuthorizationRefreshGeneration += 1
            let refreshGeneration = notificationAuthorizationRefreshGeneration
            guard newPhase == .active else {
                notificationAuthorizationIsCurrent = false
                return
            }
            notificationAuthorizationIsCurrent = false
            Task { @MainActor in
                await notifications.refreshAuthorizationStatus()
                guard !Task.isCancelled,
                      refreshGeneration
                        == notificationAuthorizationRefreshGeneration,
                      scenePhase == .active,
                      isBreakActive,
                      !didSignalCompletion else { return }
                notificationAuthorizationIsCurrent = true
                handleActiveSceneAfterAuthorizationRefresh()
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            // A CloudKit-backed RootView is intentionally torn down whenever
            // the app backgrounds. Invalidate only this view's async callbacks;
            // the explicit close/completion/account-boundary paths own the OS
            // notification and persisted recovery cleanup.
            isBreakActive = false
            notificationAuthorizationIsCurrent = false
            notificationGeneration += 1
            notificationSchedulingTask?.cancel()
            notificationSchedulingTask = nil
        }
    }

    private var timerHeader: some View {
        HStack {
            TimerRotationControls()
            Spacer()
            Button { closeBreak() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(PomoGemIconButtonStyle())
            .accessibilityLabel(
                remaining == 0
                    ? "終了アラートを停止して瓶へ戻る"
                    : "休憩をスキップ"
            )
        }
    }

    private func timerFace(spacing: CGFloat) -> some View {
        VStack(spacing: spacing) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 38))
                .foregroundStyle(PomoGemTheme.amber)
                .accessibilityHidden(true)
            Text("休憩")
                .font(PomoGemTheme.brand(28))
                .accessibilityAddTraits(.isHeader)
            Text(String(format: "%02d:%02d", remaining / 60, remaining % 60))
                .font(.system(size: timerFontSize, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.65)
                .lineLimit(1)
                .contentTransition(
                    reduceMotion ? .identity : .numericText(countsDown: true)
                )
                .accessibilityLabel("残り\(remaining / 60)分\(remaining % 60)秒")
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var waitingMessage: some View {
        Text("瓶の粒は、そのまま待っています。")
            .font(.caption)
            .foregroundStyle(PomoGemTheme.muted)
            .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var completionActions: some View {
        if remaining == 0 {
            if completionAlert.isActive(sessionID: sessionID) {
                VStack(spacing: 7) {
                    Label(
                        "休憩終了のアラート中",
                        systemImage: "bell.and.waves.left.and.right.fill"
                    )
                    .labelStyle(AccessibilitySizeTitleOnlyLabelStyle())
                    .font(.headline.weight(.bold))
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    .foregroundStyle(PomoGemTheme.amber)
                    Text("止めるまで、音と触覚を繰り返します")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .multilineTextAlignment(.center)
                }
            }
        } else {
            Button("休憩をスキップ") { closeBreak() }
                .buttonStyle(PomoGemSecondaryButtonStyle())
                .frame(minHeight: 44)
        }
    }

    private var breakEndButton: some View {
        Button {
            closeBreak()
        } label: {
            Label(
                completionAlert.isActive(sessionID: sessionID)
                    ? "停止して瓶へ戻る"
                    : "瓶へ戻る",
                systemImage: completionAlert.isActive(sessionID: sessionID)
                    ? "stop.fill"
                    : "arrow.backward"
            )
        }
        .buttonStyle(PomoGemPrimaryButtonStyle())
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .frame(minHeight: 44)
        .accessibilityHint("2本指のダブルタップでも操作できます")
        .accessibilityIdentifier("break.completion-alert.stop")
        .accessibilityFocused($breakEndButtonFocused)
        .modifier(TimerPinnedActionBar())
    }

    @ViewBuilder
    private var completionNotificationStatus: some View {
        switch notificationScheduleState {
        case .idle:
            EmptyView()

        case .permissionNotDetermined:
            Button {
                Task { await requestNotificationAuthorizationAndSchedule() }
            } label: {
                Label("画面を閉じても知らせるため通知を設定", systemImage: "bell")
            }
            .buttonStyle(PomoGemSecondaryButtonStyle())
            .frame(minHeight: 44)

        case .denied:
            VStack(spacing: 8) {
                Label("通知は許可されていません", systemImage: "bell.slash")
                    .font(.caption.weight(.semibold))
                Text("休憩はこの画面で続いています。許可は端末の設定から変更できます。")
                    .font(.caption2)
                    .foregroundStyle(PomoGemTheme.muted)
                    .multilineTextAlignment(.center)
                Button("設定を開く") {
                    openNotificationSettings()
                }
                .buttonStyle(PomoGemSecondaryButtonStyle())
            }
            .foregroundStyle(PomoGemTheme.amber)
            .accessibilityElement(children: .contain)

        case .scheduling:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("終了通知を設定しています")
                    .font(.caption)
            }
            .foregroundStyle(PomoGemTheme.muted)
            .accessibilityElement(children: .combine)

        case .scheduled:
            Label("画面を閉じても、休憩終了時に通知します", systemImage: "bell.badge.fill")
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .accessibilityElement(children: .combine)

        case .failed:
            VStack(spacing: 8) {
                Label("終了通知を予約できませんでした", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                Text("休憩タイマーはこの画面で続いています。少し待ってから再試行できます。")
                    .font(.caption2)
                    .foregroundStyle(PomoGemTheme.muted)
                    .multilineTextAlignment(.center)
                Button("通知予約を再試行") {
                    Task { await refreshNotificationScheduling(requestAuthorizationIfNeeded: true) }
                }
                .buttonStyle(PomoGemSecondaryButtonStyle())
            }
            .foregroundStyle(PomoGemTheme.amber)
            .accessibilityElement(children: .contain)
        }
    }

    @MainActor
    private func prepareBreak() async {
        guard !Task.isCancelled, isBreakActive else { return }
        // Rest may already be counting down while Home reveals the gem. Join
        // its one registration before this view replaces the same OS request.
        await RewardBreakNotificationHandoff.wait(for: sessionID)
        guard !Task.isCancelled, isBreakActive else { return }
        if let saved = FocusPersistence.loadBreak(),
           saved.id == sessionID, saved.endDate == endDate {
            scheduledCompletionNotificationDeliveryDate =
                saved.scheduledCompletionNotificationDeliveryDate
        }
        configureSensoryPreferences()
        guard let durationSeconds = BreakRecoveryPolicy.durationSeconds(
            minutes: minutes
        ) else {
            FocusPersistence.clearBreak()
            isBreakActive = false
            dismiss()
            return
        }
        let startedAt = Date.now
        let startedUptime = ContinuousUptime.now()
        let resolvedEndDate = endDate
            ?? startedAt.addingTimeInterval(TimeInterval(durationSeconds))
        let resolvedClockAnchor = clockAnchor ?? {
            // A missing anchor on a legacy recovery remains untrusted. Only a
            // newly created break can establish this monotonic continuity.
            guard endDate == nil else { return nil }
            return ClockAnchor(
                wallDate: startedAt,
                systemUptime: startedUptime
            )
        }()
        let recovery = BreakRecoveryEnvelope(
            id: sessionID,
            minutes: minutes,
            endDate: resolvedEndDate,
            clockAnchor: resolvedClockAnchor,
            scheduledCompletionNotificationDeliveryDate:
                currentNotificationDeliveryWitness,
            originatingFocusSessionID: originatingFocusSessionID
        )
        guard BreakRecoveryPolicy.isValid(recovery, at: startedAt) else {
            FocusPersistence.clearBreak()
            isBreakActive = false
            dismiss()
            return
        }
        endDate = resolvedEndDate
        clockAnchor = resolvedClockAnchor
        now = startedAt
        updateIdleTimer()
        FocusPersistence.saveBreak(recovery, at: startedAt)
        guard !Task.isCancelled, isBreakActive else { return }
        await notifications.refreshAuthorizationStatus()
        guard !Task.isCancelled, isBreakActive else { return }
        notificationAuthorizationIsCurrent = scenePhase == .active
        if resolvedEndDate <= .now {
            guard scenePhase == .active else { return }
            let completionDate = Date.now
            let completionUptime = ContinuousUptime.now()
            signalBreakCompletionIfNeeded(
                cue: completionCue(
                    at: completionDate,
                    uptime: completionUptime,
                    recoveredAfterExpiration: true,
                    returnedFromBackground: false
                )
            )
            return
        }
        await refreshNotificationScheduling()
    }

    @MainActor
    private func handleActiveSceneAfterAuthorizationRefresh() {
        let returnedFromBackground = didEnterBackgroundSinceLastActive
        didEnterBackgroundSinceLastActive = false
        now = .now
        let completionUptime = ContinuousUptime.now()
        if remaining == 0 {
            if notificationScheduleState.isScheduling {
                // Let the ticker finish after Notification Center returns
                // success/failure, retaining the background-return flag.
                didEnterBackgroundSinceLastActive = returnedFromBackground
                return
            }
            // A background notification may already have announced this end;
            // an inactive-only interruption still deserves the foreground cue.
            signalBreakCompletionIfNeeded(
                cue: completionCue(
                    at: now,
                    uptime: completionUptime,
                    recoveredAfterExpiration: false,
                    returnedFromBackground: returnedFromBackground
                )
            )
            return
        }
        Task { await refreshNotificationScheduling() }
    }

    @MainActor
    private func closeBreak() {
        if didSignalCompletion || completionAlert.isActive(sessionID: sessionID) {
            TimerCompletionAlertAcknowledgementStore.mark(
                sessionID: sessionID
            )
        }
        completionAlert.stop(sessionID: sessionID)
        isBreakActive = false
        UIApplication.shared.isIdleTimerDisabled = false
        FocusPersistence.clearBreak()
        stopNotificationScheduling(state: .idle)
        dismiss()
    }

    @MainActor
    private func signalBreakCompletionIfNeeded(
        cue: TimerCompletionForegroundFeedbackPolicy.Cue
    ) {
        guard !didSignalCompletion else { return }
        didSignalCompletion = true
        UIApplication.shared.isIdleTimerDisabled = false
        stopNotificationScheduling(state: .idle)

        let soundOn = sensoryPreferences.soundOn
        let hapticsOn = sensoryPreferences.hapticsOn
        SoundSynth.shared.isEnabled = soundOn
        Haptics.shared.isEnabled = hapticsOn
        if !TimerCompletionAlertAcknowledgementStore.contains(
            sessionID: sessionID
        ) {
            let configuration = TimerCompletionAlertConfiguration(
                sessionID: sessionID,
                sound: soundOn ? sensoryPreferences.timerCompletionSound : nil,
                haptic: hapticsOn ? sensoryPreferences.timerCompletionHaptic : nil
            )
            if completionAlert.resumeSuspendedAlert(sessionID: sessionID) {
                // An iCloud remount cut this alarm off while the app stayed on
                // screen; restore it with its Stop for whoever stepped away.
            } else {
                switch cue {
                case .repeating:
                    completionAlert.start(configuration)
                case .single:
                    TimerCompletionAlertAcknowledgementStore.mark(sessionID: sessionID)
                    completionAlert.playOnce(configuration)
                case .none:
                    TimerCompletionAlertAcknowledgementStore.mark(sessionID: sessionID)
                }
            }
        }
        guard completionAlert.isActive(sessionID: sessionID),
              UIAccessibility.isVoiceOverRunning else {
            UIAccessibility.post(notification: .announcement, argument: "休憩が終わりました")
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard completionAlert.isActive(sessionID: sessionID) else { return }
            breakEndButtonFocused = true
            UIAccessibility.post(
                notification: .announcement,
                argument: NSAttributedString(
                    string: "休憩が終わりました。2本指でダブルタップすると、アラートを止めて瓶へ戻れます",
                    attributes: [.accessibilitySpeechQueueAnnouncement: true]
                )
            )
        }
    }

    private func completionCue(
        at date: Date,
        uptime: TimeInterval,
        recoveredAfterExpiration: Bool,
        returnedFromBackground: Bool
    ) -> TimerCompletionForegroundFeedbackPolicy.Cue {
        TimerCompletionForegroundFeedbackPolicy.cue(
            recoveredAfterExpiration: recoveredAfterExpiration,
            returnedFromBackground: returnedFromBackground,
            notificationMayHaveDelivered: notificationMayHaveDelivered(
                at: date,
                uptime: uptime
            ),
            endedAt: endDate ?? date,
            now: date
        )
    }

    @MainActor
    private func configureSensoryPreferences() {
        SoundSynth.shared.isEnabled = sensoryPreferences.soundOn
        Haptics.shared.isEnabled = sensoryPreferences.hapticsOn
    }

    @MainActor
    private func updateIdleTimer(
        at date: Date = .now,
        sceneIsActive: Bool? = nil
    ) {
        let currentRemainingSeconds = BreakRecoveryPolicy.remainingSeconds(
            minutes: minutes,
            endDate: endDate,
            at: date
        )
        let shouldKeepScreenAwake =
            TimerScreenAwakePolicy.shouldKeepScreenAwake(
                preferenceEnabled:
                    resolvedPreferences?.keepScreenAwake ?? false,
                sceneIsActive: sceneIsActive ?? (scenePhase == .active),
                timerIsRunning:
                    isBreakActive && !didSignalCompletion,
                remainingSeconds: currentRemainingSeconds
            )
        guard UIApplication.shared.isIdleTimerDisabled != shouldKeepScreenAwake
        else { return }
        UIApplication.shared.isIdleTimerDisabled = shouldKeepScreenAwake
    }

    @MainActor
    private func refreshNotificationScheduling(
        requestAuthorizationIfNeeded: Bool = false
    ) async {
        // View disappearance during CloudKit account revalidation preserves
        // the already accepted OS request. A stale task must be a no-op, not a
        // semantic break cancellation.
        guard !Task.isCancelled,
              isBreakActive,
              !didSignalCompletion else { return }
        guard let endDate else {
            stopNotificationScheduling(state: .idle)
            return
        }
        guard endDate > .now else {
            // Notification Center may be at the delivery boundary. Preserve
            // the request/witness until the active completion policy decides
            // whether an in-app cue is still owed.
            notificationScheduleState = .idle
            return
        }

        let generationBeforeRefresh = notificationGeneration
        await notifications.refreshAuthorizationStatus()
        guard !Task.isCancelled,
              isBreakActive,
              !didSignalCompletion,
              generationBeforeRefresh == notificationGeneration else { return }
        notificationAuthorizationIsCurrent = scenePhase == .active

        switch notifications.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            scheduleBreakNotification(endDate: endDate)
        case .denied:
            stopNotificationScheduling(state: .denied)
        case .notDetermined:
            if requestAuthorizationIfNeeded {
                await requestNotificationAuthorizationAndSchedule()
            } else {
                stopNotificationScheduling(state: .permissionNotDetermined)
            }
        @unknown default:
            stopNotificationScheduling(state: .failed)
        }
    }

    @MainActor
    private func requestNotificationAuthorizationAndSchedule() async {
        guard isBreakActive,
              !didSignalCompletion,
              let endDate,
              endDate > .now else { return }
        let generationBeforeRequest = notificationGeneration
        let granted = await notifications.requestAuthorization()
        guard !Task.isCancelled,
              isBreakActive,
              !didSignalCompletion,
              generationBeforeRequest == notificationGeneration else {
            return
        }

        if granted, notifications.isAuthorized {
            scheduleBreakNotification(endDate: endDate)
            return
        }

        if notifications.authorizationStatus == .denied {
            stopNotificationScheduling(state: .denied)
        } else {
            stopNotificationScheduling(state: .failed)
        }
    }

    @MainActor
    private func scheduleBreakNotification(endDate: Date) {
        guard isBreakActive, !didSignalCompletion else { return }
        guard endDate > .now else {
            notificationScheduleState = .idle
            return
        }

        // A replacement request gets a fresh relative-time origin. Never
        // retain the older, earlier witness while registration is pending.
        if scheduledCompletionNotificationDeliveryDate != nil {
            scheduledCompletionNotificationDeliveryDate = nil
            persistBreakRecovery()
        }

        notificationGeneration += 1
        let generation = notificationGeneration
        let scheduledSessionID = sessionID
        let previousTask = notificationSchedulingTask
        previousTask?.cancel()
        notificationScheduleState = .scheduling
        let playsSound = sensoryPreferences.soundOn
        let completionSound = sensoryPreferences.timerCompletionSound

        notificationSchedulingTask = Task { @MainActor in
            // Serializing generations prevents an old cancellation from removing
            // a newer request that uses the same Notification Center identifier.
            if let previousTask {
                await previousTask.value
            }
            guard notificationRequestIsCurrent(
                generation: generation,
                sessionID: scheduledSessionID,
                endDate: endDate
            ) else {
                return
            }

            do {
                let scheduleResult = try await notifications
                    .scheduleBreakCompletion(
                    id: scheduledSessionID,
                    endDate: endDate,
                    playsSound: playsSound,
                    completionSound: completionSound
                )
                guard case let .accepted(notificationDeliveryDate) = scheduleResult
                else { return }
                guard notificationRequestIsCurrent(
                    generation: generation,
                    sessionID: scheduledSessionID,
                    endDate: endDate
                ) else {
                    return
                }
                notificationScheduleState = .scheduled
                scheduledCompletionNotificationDeliveryDate =
                    notificationDeliveryDate
                persistBreakRecovery()
            } catch {
                await notifications.refreshAuthorizationStatus()
                guard notificationRequestIsCurrent(
                    generation: generation,
                    sessionID: scheduledSessionID,
                    endDate: endDate
                ) else {
                    return
                }
                notificationScheduleState = notifications.authorizationStatus == .denied
                    ? .denied
                    : .failed
            }
        }
    }

    @MainActor
    private func notificationRequestIsCurrent(
        generation: Int,
        sessionID: UUID,
        endDate: Date
    ) -> Bool {
        !Task.isCancelled
            && isBreakActive
            && !didSignalCompletion
            && generation == notificationGeneration
            && sessionID == self.sessionID
            && endDate == self.endDate
    }

    @MainActor
    private func stopNotificationScheduling(state: BreakNotificationScheduleState) {
        notificationGeneration += 1
        notificationSchedulingTask?.cancel()
        notifications.cancelBreakCompletion(id: sessionID)
        let hadScheduledWitness =
            scheduledCompletionNotificationDeliveryDate != nil
        scheduledCompletionNotificationDeliveryDate = nil
        notificationScheduleState = state
        if hadScheduledWitness { persistBreakRecovery() }
    }

    @MainActor
    private func persistBreakRecovery() {
        guard isBreakActive, !didSignalCompletion, let endDate else { return }
        FocusPersistence.saveBreak(BreakRecoveryEnvelope(
            id: sessionID,
            minutes: minutes,
            endDate: endDate,
            clockAnchor: clockAnchor,
            scheduledCompletionNotificationDeliveryDate:
                currentNotificationDeliveryWitness,
            originatingFocusSessionID: originatingFocusSessionID
        ))
    }

    private var currentNotificationDeliveryWitness: Date? {
        guard let deliveryDate = scheduledCompletionNotificationDeliveryDate,
              let endDate,
              deliveryDate >= endDate.addingTimeInterval(-0.01),
              deliveryDate <= endDate.addingTimeInterval(
                IntegrationConstants.notificationMinimumDelay
                    + IntegrationConstants
                        .notificationWitnessRegistrationAllowance
              )
        else { return nil }
        return deliveryDate
    }

    private func notificationMayHaveDelivered(
        at date: Date,
        uptime: TimeInterval
    ) -> Bool {
        let timingIsTrustworthy = TimerCompletionForegroundFeedbackPolicy
            .notificationTimingIsTrustworthy(
                source: .timer,
                clockAnchor: clockAnchor,
                now: date,
                uptime: uptime
            )
        return TimerCompletionForegroundFeedbackPolicy
            .notificationMayHaveDelivered(
                isAuthorized: notifications.isAuthorized,
                expectedDeliveryDate: timingIsTrustworthy
                    ? currentNotificationDeliveryWitness
                    : nil,
                now: date
            )
    }

    @MainActor
    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            notificationScheduleState = .failed
            return
        }
        UIApplication.shared.open(url)
    }
}

/// Registers the already-persisted rest independently of Home's animation and
/// CloudKit view lifetime. This owns only the short Notification Center add;
/// the operating system owns the actual break deadline.
@MainActor
enum RewardBreakNotificationHandoff {
    private struct Operation {
        let token: UUID
        let task: Task<Void, Never>
        var backgroundTask: UIBackgroundTaskIdentifier
    }

    private static var operations: [UUID: Operation] = [:]

    static func begin(
        _ recovery: BreakRecoveryEnvelope,
        playsSound: Bool,
        completionSound: TimerCompletionSound
    ) {
        guard operations[recovery.id] == nil, recovery.endDate > .now else { return }
        let key = FocusPersistence.breakKey
        let token = UUID()
        let backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Schedule selected rest"
        ) {
            guard var operation = operations[recovery.id], operation.token == token else { return }
            operation.task.cancel()
            NotificationManager.shared.cancelBreakCompletion(id: recovery.id)
            let identifier = operation.backgroundTask
            operation.backgroundTask = .invalid
            operations[recovery.id] = operation
            if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) }
        }
        let task = Task { @MainActor in
            defer { finish(id: recovery.id, token: token) }
            guard !Task.isCancelled,
                  key == FocusPersistence.breakKey,
                  let current = FocusPersistence.loadBreak(),
                  current.id == recovery.id, current.endDate == recovery.endDate,
                  current.endDate > .now else { return }
            do {
                let result = try await NotificationManager.shared.scheduleBreakCompletion(
                    id: recovery.id,
                    endDate: recovery.endDate,
                    playsSound: playsSound,
                    completionSound: completionSound
                )
                guard !Task.isCancelled,
                      case let .accepted(deliveryDate) = result,
                      key == FocusPersistence.breakKey,
                      var saved = FocusPersistence.loadBreak(),
                      saved.id == recovery.id, saved.endDate == recovery.endDate
                else { return }
                saved.scheduledCompletionNotificationDeliveryDate = deliveryDate
                FocusPersistence.saveBreak(saved)
            } catch {
                // BreakTimerView provides the existing permission/retry UI.
                // The saved clock remains valid even if registration fails.
            }
        }
        operations[recovery.id] = Operation(
            token: token, task: task, backgroundTask: backgroundTask
        )
    }

    static func wait(for id: UUID) async {
        await operations[id]?.task.value
    }

    private static func finish(id: UUID, token: UUID) {
        guard let operation = operations[id], operation.token == token else { return }
        operations.removeValue(forKey: id)
        if operation.backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(operation.backgroundTask)
        }
    }
}

private enum BreakNotificationScheduleState: Equatable {
    case idle
    case permissionNotDetermined
    case denied
    case scheduling
    case scheduled
    case failed

    var isScheduling: Bool {
        if case .scheduling = self { return true }
        return false
    }
}
