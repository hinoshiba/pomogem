import Combine
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

struct BreakTimerView: View {
    let minutes: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
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
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(minutes: Int) {
        self.minutes = minutes
        _sessionID = State(initialValue: UUID())
        _clockAnchor = State(initialValue: nil)
        _preferences = Query(PrefsConsumerPolicy.descriptor())
        _activityResetMarkers = Query(
            ActivityResetPolicy.currentMarkerDescriptor()
        )
    }

    init(recovery: BreakRecoveryEnvelope) {
        minutes = recovery.minutes
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
            RadialGradient(colors: [TsumibenTheme.amber.opacity(0.08), .clear], center: .center, startRadius: 0, endRadius: 340).ignoresSafeArea()
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        HStack {
                            Spacer()
                            Button { closeBreak() } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(TsumibenIconButtonStyle())
                            .accessibilityLabel(
                                remaining == 0
                                    ? "終了アラートを停止して瓶へ戻る"
                                    : "休憩をスキップ"
                            )
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(TsumibenTheme.amber)
                            .accessibilityHidden(true)
                        Text("休憩")
                            .font(TsumibenTheme.brand(28))
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
                        Text("瓶の粒は、そのまま待っています。")
                            .font(.caption)
                            .foregroundStyle(TsumibenTheme.muted)
                            .multilineTextAlignment(.center)

                        if remaining > 0 {
                            completionNotificationStatus
                        }

                        Spacer(minLength: 8)

                        if remaining == 0 {
                            if completionAlert.isActive(sessionID: sessionID) {
                                VStack(spacing: 7) {
                                    Label(
                                        "休憩終了のアラート中",
                                        systemImage: "bell.and.waves.left.and.right.fill"
                                    )
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(TsumibenTheme.amber)
                                    Text("アプリが前面にある間、有効な音と触覚を停止するまで繰り返します")
                                        .font(.caption)
                                        .foregroundStyle(TsumibenTheme.muted)
                                        .multilineTextAlignment(.center)
                                }
                            }
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
                                .buttonStyle(TsumibenPrimaryButtonStyle())
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("break.completion-alert.stop")
                        } else {
                            Button("休憩をスキップ") { closeBreak() }
                                .buttonStyle(TsumibenSecondaryButtonStyle())
                                .frame(minHeight: 44)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .statusBarHidden()
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
                    playsSensoryFeedback:
                        TimerCompletionForegroundFeedbackPolicy.shouldPlay(
                            recoveredAfterExpiration: false,
                            returnedFromBackground: returnedFromBackground,
                            notificationMayHaveDelivered:
                                notificationMayHaveDelivered(
                                    at: date,
                                    uptime: completionUptime
                                )
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
            .buttonStyle(TsumibenSecondaryButtonStyle())
            .frame(minHeight: 44)

        case .denied:
            VStack(spacing: 8) {
                Label("通知は許可されていません", systemImage: "bell.slash")
                    .font(.caption.weight(.semibold))
                Text("休憩はこの画面で続いています。許可は端末の設定から変更できます。")
                    .font(.caption2)
                    .foregroundStyle(TsumibenTheme.muted)
                    .multilineTextAlignment(.center)
                Button("設定を開く") {
                    openNotificationSettings()
                }
                .buttonStyle(TsumibenSecondaryButtonStyle())
            }
            .foregroundStyle(TsumibenTheme.amber)
            .accessibilityElement(children: .contain)

        case .scheduling:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("終了通知を設定しています")
                    .font(.caption)
            }
            .foregroundStyle(TsumibenTheme.muted)
            .accessibilityElement(children: .combine)

        case .scheduled:
            Label("画面を閉じても、休憩終了時に通知します", systemImage: "bell.badge.fill")
                .font(.caption)
                .foregroundStyle(TsumibenTheme.muted)
                .accessibilityElement(children: .combine)

        case .failed:
            VStack(spacing: 8) {
                Label("終了通知を予約できませんでした", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                Text("休憩タイマーはこの画面で続いています。少し待ってから再試行できます。")
                    .font(.caption2)
                    .foregroundStyle(TsumibenTheme.muted)
                    .multilineTextAlignment(.center)
                Button("通知予約を再試行") {
                    Task { await refreshNotificationScheduling(requestAuthorizationIfNeeded: true) }
                }
                .buttonStyle(TsumibenSecondaryButtonStyle())
            }
            .foregroundStyle(TsumibenTheme.amber)
            .accessibilityElement(children: .contain)
        }
    }

    @MainActor
    private func prepareBreak() async {
        guard !Task.isCancelled, isBreakActive else { return }
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
                currentNotificationDeliveryWitness
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
                playsSensoryFeedback: !notificationMayHaveDelivered(
                    at: completionDate,
                    uptime: completionUptime
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
                playsSensoryFeedback:
                    TimerCompletionForegroundFeedbackPolicy.shouldPlay(
                        recoveredAfterExpiration: false,
                        returnedFromBackground: returnedFromBackground,
                        notificationMayHaveDelivered:
                            notificationMayHaveDelivered(
                                at: now,
                                uptime: completionUptime
                            )
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
    private func signalBreakCompletionIfNeeded(playsSensoryFeedback: Bool) {
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
            completionAlert.start(
                TimerCompletionAlertConfiguration(
                    sessionID: sessionID,
                    sound: soundOn
                        ? sensoryPreferences.timerCompletionSound
                        : nil,
                    haptic: hapticsOn
                        ? sensoryPreferences.timerCompletionHaptic
                        : nil
                ),
                playsImmediately: playsSensoryFeedback
            )
        }
        UIAccessibility.post(notification: .announcement, argument: "休憩が終わりました")
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
                currentNotificationDeliveryWitness
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
