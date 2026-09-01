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
    @ScaledMetric(relativeTo: .largeTitle) private var timerFontSize: CGFloat = 72
    @State private var sessionID: UUID
    @State private var endDate: Date?
    @State private var now = Date.now
    @State private var didSignalCompletion = false
    @State private var notifications = NotificationManager.shared
    @State private var notificationScheduleState: BreakNotificationScheduleState = .idle
    @State private var notificationSchedulingTask: Task<Void, Never>?
    @State private var notificationGeneration = 0
    @State private var isBreakActive = true
    @State private var didEnterBackgroundSinceLastActive = false
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(minutes: Int) {
        self.minutes = minutes
        _sessionID = State(initialValue: UUID())
    }

    init(recovery: BreakRecoveryEnvelope) {
        minutes = recovery.minutes
        _sessionID = State(initialValue: recovery.id)
        _endDate = State(initialValue: recovery.endDate)
    }

    private var remaining: Int {
        guard let endDate else { return minutes * Constants.Timer.secondsPerMinute }
        return max(0, Int(ceil(endDate.timeIntervalSince(now))))
    }

    private var prefs: Prefs? { preferences.first }

    private var sensoryPreferenceValues: [Bool] {
        [prefs?.soundOn ?? false, prefs?.hapticsOn ?? false]
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
                            .accessibilityLabel("休憩をスキップ")
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
                            Button("瓶へ戻る") { closeBreak() }
                                .buttonStyle(TsumibenPrimaryButtonStyle())
                                .frame(minHeight: 44)
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
            if remaining == 0, scenePhase == .active {
                signalBreakCompletionIfNeeded(playsSensoryFeedback: true)
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
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                didEnterBackgroundSinceLastActive = true
                return
            }
            guard newPhase == .active, isBreakActive, !didSignalCompletion else { return }
            let returnedFromBackground = didEnterBackgroundSinceLastActive
            didEnterBackgroundSinceLastActive = false
            now = .now
            if remaining == 0 {
                // A background notification may already have announced this end;
                // an inactive-only interruption still deserves the foreground cue.
                let backgroundNotificationMayHaveFired = returnedFromBackground
                    && notificationScheduleState == .scheduled
                signalBreakCompletionIfNeeded(
                    playsSensoryFeedback: !backgroundNotificationMayHaveFired
                )
                return
            }
            Task { await refreshNotificationScheduling() }
        }
        .onDisappear {
            isBreakActive = false
            stopNotificationScheduling(state: .idle)
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
        configureSensoryPreferences()
        let resolvedEndDate = endDate
            ?? Date.now.addingTimeInterval(TimeInterval(minutes * Constants.Timer.secondsPerMinute))
        endDate = resolvedEndDate
        now = .now
        let recovery = BreakRecoveryEnvelope(
            id: sessionID,
            minutes: minutes,
            endDate: resolvedEndDate
        )
        FocusPersistence.saveBreak(recovery)
        guard !Task.isCancelled, isBreakActive else { return }
        if resolvedEndDate <= .now {
            signalBreakCompletionIfNeeded(playsSensoryFeedback: false)
            return
        }
        await refreshNotificationScheduling()
    }

    @MainActor
    private func closeBreak() {
        isBreakActive = false
        FocusPersistence.clearBreak()
        stopNotificationScheduling(state: .idle)
        dismiss()
    }

    @MainActor
    private func signalBreakCompletionIfNeeded(playsSensoryFeedback: Bool) {
        guard !didSignalCompletion else { return }
        didSignalCompletion = true
        isBreakActive = false
        FocusPersistence.clearBreak()
        stopNotificationScheduling(state: .idle)

        let soundOn = prefs?.soundOn ?? false
        let hapticsOn = prefs?.hapticsOn ?? false
        SoundSynth.shared.isEnabled = soundOn
        Haptics.shared.isEnabled = hapticsOn
        if playsSensoryFeedback, soundOn {
            SoundSynth.shared.playCompletionChime()
        }
        if playsSensoryFeedback, hapticsOn {
            Haptics.shared.playTimerCompletion()
        }
        UIAccessibility.post(notification: .announcement, argument: "休憩が終わりました")
    }

    @MainActor
    private func configureSensoryPreferences() {
        SoundSynth.shared.isEnabled = prefs?.soundOn ?? false
        Haptics.shared.isEnabled = prefs?.hapticsOn ?? false
    }

    @MainActor
    private func refreshNotificationScheduling(
        requestAuthorizationIfNeeded: Bool = false
    ) async {
        guard isBreakActive,
              !didSignalCompletion,
              let endDate,
              endDate > .now else {
            stopNotificationScheduling(state: .idle)
            return
        }

        let generationBeforeRefresh = notificationGeneration
        await notifications.refreshAuthorizationStatus()
        guard !Task.isCancelled,
              isBreakActive,
              !didSignalCompletion,
              generationBeforeRefresh == notificationGeneration else { return }

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
        guard isBreakActive, !didSignalCompletion, endDate > .now else {
            stopNotificationScheduling(state: .idle)
            return
        }

        notificationGeneration += 1
        let generation = notificationGeneration
        let scheduledSessionID = sessionID
        let previousTask = notificationSchedulingTask
        previousTask?.cancel()
        notificationScheduleState = .scheduling
        let playsSound = prefs?.soundOn ?? false

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
                notifications.cancelBreakCompletion(id: scheduledSessionID)
                return
            }

            do {
                try await notifications.scheduleBreakCompletion(
                    id: scheduledSessionID,
                    endDate: endDate,
                    playsSound: playsSound
                )
                guard notificationRequestIsCurrent(
                    generation: generation,
                    sessionID: scheduledSessionID,
                    endDate: endDate
                ) else {
                    // UNUserNotificationCenter.add can finish after Task cancellation.
                    // Remove that late request immediately when its generation is stale.
                    notifications.cancelBreakCompletion(id: scheduledSessionID)
                    return
                }
                notificationScheduleState = .scheduled
            } catch {
                await notifications.refreshAuthorizationStatus()
                guard notificationRequestIsCurrent(
                    generation: generation,
                    sessionID: scheduledSessionID,
                    endDate: endDate
                ) else {
                    notifications.cancelBreakCompletion(id: scheduledSessionID)
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
            && endDate > .now
    }

    @MainActor
    private func stopNotificationScheduling(state: BreakNotificationScheduleState) {
        notificationGeneration += 1
        notificationSchedulingTask?.cancel()
        notifications.cancelBreakCompletion(id: sessionID)
        notificationScheduleState = state
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
}
