import Foundation

/// Books the one channel that announces a focus or break end while the app
/// is not in the foreground (F5): the AlarmKit alarm at the maximum preset
/// (iOS 26+, alarms allowed, the app's sound on), otherwise the Time
/// Sensitive notification. Exactly one is booked; switching channel
/// withdraws the other. The booker decides every permission itself, so the
/// timer screens call it whether or not notifications are allowed: someone
/// who allowed alarms but declined notifications still gets the alarm.
///
/// How the timer screens use it (FocusView, BreakTimerView and
/// `RewardBreakNotificationHandoff`; #49's `TimerForegroundResolution` still
/// decides whether an end rings in the app, this only books how it is
/// announced while away). The screens' decisions are in
/// `TimerEndAnnouncementWiring` and tested there.
///
/// 1. Booking. Every end a timer screen books goes through `bookFocusEnd` /
///    `bookBreakEnd`: FocusView start, resume, activation, recovery,
///    adoption and the 「終了通知を設定」 retry; BreakTimerView prepare,
///    activation, the sensory-preference change and the permission request;
///    and the 「N分休憩」 tap (`RewardBreakNotificationHandoff`), which
///    stores a delivery date only for `.notification(.accepted)`. The calls
///    are not gated on notification permission; the first-focus
///    notification ask stays as it is (once, never on recovery).
/// 2. The outcome. While a call is in flight the screen shows "scheduling"
///    only when `channel(playsSound:)` books something, and #49 waits for
///    it. Every outcome leaves that state
///    (`TimerEndAnnouncementWiring.settlement`): `.systemAlarm` settles with
///    no notification delivery date and an alarm version of the running
///    row, `.noChannel` as not scheduled.
/// 3. Cancels: `NotificationManager.cancelFocusCompletion` and
///    `cancelBreakCompletion` (pause, F1's auto-pause, abandon, ownership
///    loss, skip) also cancel the alarm, including a booking still preparing
///    its sound, and stop one that is ringing while keeping it as the
///    witness. Reset recovery, iCloud retirement, the account boundary and
///    complete deletion are wired in `NotificationManager` and
///    `FocusEndAlarmMaintenance`.
/// 4. The end. The ticker calls `handOffToForegroundIfDue`; when the scene
///    stops being active after a hand-off returned an end, the screen calls
///    `book…EndAfterLeavingDuringHandoff` (`TimerEndHandoff`). The cue reads
///    `externalAlertMayHaveFired` (the notification date still passes the
///    trustworthy-timing gate first). A completion resolved on screen calls
///    `acknowledgeEnd`. While the in-app alarm rings,
///    `TimerCompletionAlertController.keepsScreenAwake(sessionID:)` joins the
///    idle-timer decision through `TimerCompletionAlarmScreenAwakePolicy`.
/// 5. Activation. Both screens rebook a running timer's end on every
///    activation and remount; the same end and sound keep the booked alarm
///    (`FocusEndAlarmScheduler.schedule`), so this also covers
///    `FocusEndAlarmReconciliation.ownerNeedsBooking` and an Alarms
///    permission changed in the Settings app.
@MainActor
final class TimerEndAnnouncementBooker {
    enum Outcome: Equatable, Sendable {
        /// The notification path, with its usual result.
        case notification(TimerCompletionNotificationScheduleResult)
        /// A system alarm announces the end; no notification is booked.
        case systemAlarm(FocusEndAlarmBooking)
        /// Nothing can announce the end while the app is away: notifications
        /// are not allowed and no system alarm could be booked. An earlier
        /// alarm for the session was cancelled.
        case noChannel
    }

    typealias RingtoneFileName = @MainActor (AlarmSoundChoice, UInt64) async -> String?

    static let shared = TimerEndAnnouncementBooker(
        notifications: .shared,
        systemAlarms: .shared,
        preferences: AlarmPreferences(),
        ringtoneFileName: { choice, generation in
            guard AlarmSoundLibrary.systemAlarmUsesRenderedRingtone,
                  let url = try? await AlarmSoundLibrary.preparedFile(
                      .ringtone, for: choice, generation: generation
                  )
            else { return nil }
            return url.lastPathComponent
        }
    )

    private let notifications: NotificationManager
    private let systemAlarms: FocusEndAlarmScheduler
    private let preferences: AlarmPreferences
    private let ringtoneFileName: RingtoneFileName

    init(
        notifications: NotificationManager,
        systemAlarms: FocusEndAlarmScheduler,
        preferences: AlarmPreferences,
        ringtoneFileName: @escaping RingtoneFileName
    ) {
        self.notifications = notifications
        self.systemAlarms = systemAlarms
        self.preferences = preferences
        self.ringtoneFileName = ringtoneFileName
    }

    /// The channel `book…End` will use right now.
    func channel(playsSound: Bool) -> AlarmBackgroundChannel {
        AlarmChannelPolicy.backgroundChannel(
            strength: preferences.strength,
            soundEnabled: playsSound,
            systemAlarm: systemAlarms.authorization,
            notificationsAuthorized: notifications.isAuthorized
        )
    }

    func bookFocusEnd(
        sessionID: UUID,
        endDate: Date,
        playsSound: Bool,
        completionSound: TimerCompletionSound
    ) async throws -> Outcome {
        try await book(
            sessionID: sessionID,
            phase: .focus,
            endDate: endDate,
            playsSound: playsSound,
            completionSound: completionSound
        )
    }

    func bookBreakEnd(
        id: UUID,
        endDate: Date,
        playsSound: Bool,
        completionSound: TimerCompletionSound
    ) async throws -> Outcome {
        try await book(
            sessionID: id,
            phase: .breakTime,
            endDate: endDate,
            playsSound: playsSound,
            completionSound: completionSound
        )
    }

    // MARK: The end (the timer screens call these)

    /// The app is active at most `AlarmChannelPolicy.foregroundHandoffLead`
    /// before `endDate`: the session's system alarm that has not rung is
    /// cancelled, so the in-app alarm is the only one that rings. Returns
    /// the end the app now announces alone, or nil when nothing was handed
    /// off (not due yet, the app is not active, the end has passed, or no
    /// alarm is booked for the session). Call it from the timer's ticker;
    /// repeated calls are harmless.
    @discardableResult
    func handOffToForegroundIfDue(
        sessionID: UUID,
        endDate: Date,
        applicationIsActive: Bool,
        now: Date = .now
    ) -> Date? {
        guard AlarmChannelPolicy.shouldHandOffToForeground(
            applicationIsActive: applicationIsActive,
            notificationsAuthorized: notifications.isAuthorized,
            endDate: endDate,
            now: now
        ) else { return nil }
        return systemAlarms.handOffToForeground(sessionID: sessionID)
    }

    /// After `handOffToForegroundIfDue` returned `endDate`, the scene stopped
    /// being active before that end (locked, the app switcher): nothing else
    /// would announce it, so the notification is booked at once
    /// (`AlarmChannelPolicy.channelAfterLeavingDuringHandoff`). Nil when
    /// nothing is booked: the end has passed (the in-app alarm has started,
    /// and leaving it counts as Stop), or notifications are not allowed.
    func bookFocusEndAfterLeavingDuringHandoff(
        sessionID: UUID,
        endDate: Date,
        playsSound: Bool,
        completionSound: TimerCompletionSound,
        now: Date = .now
    ) async throws -> TimerCompletionNotificationScheduleResult? {
        try await bookAfterLeavingDuringHandoff(
            sessionID: sessionID,
            phase: .focus,
            endDate: endDate,
            playsSound: playsSound,
            completionSound: completionSound,
            now: now
        )
    }

    /// `bookFocusEndAfterLeavingDuringHandoff` for a break.
    func bookBreakEndAfterLeavingDuringHandoff(
        id: UUID,
        endDate: Date,
        playsSound: Bool,
        completionSound: TimerCompletionSound,
        now: Date = .now
    ) async throws -> TimerCompletionNotificationScheduleResult? {
        try await bookAfterLeavingDuringHandoff(
            sessionID: id,
            phase: .breakTime,
            endDate: endDate,
            playsSound: playsSound,
            completionSound: completionSound,
            now: now
        )
    }

    /// The delivery witness for the in-app cue at a resolved end: an
    /// accepted notification whose delivery date passed, or a system alarm
    /// AlarmKit confirmed whose time came (while alarms are still allowed).
    /// The timer screens hand this to the foreground cue decision in place
    /// of the notification-only witness. Reading it changes nothing.
    func externalAlertMayHaveFired(
        sessionID: UUID,
        notificationAuthorized: Bool,
        notificationDeliveryDate: Date?,
        now: Date = .now
    ) -> Bool {
        AlarmChannelPolicy.externalAlertMayHaveFired(
            notificationAuthorized: notificationAuthorized,
            notificationDeliveryDate: notificationDeliveryDate,
            systemAlarmAuthorized: systemAlarms.authorization == .authorized,
            systemAlarmFireDate: systemAlarms.deliveryWitnessFireDate(sessionID: sessionID),
            now: now
        )
    }

    /// The completion of `sessionID` resolved on screen (the person is
    /// looking at it): Stop its system alarm if it rings, cancel it if it
    /// has not rung, and keep one that rang as the delivery witness
    /// (`FocusEndAlarmScheduler.acknowledge`). Read
    /// `externalAlertMayHaveFired` before or after; the answer is the same.
    func acknowledgeEnd(sessionID: UUID) {
        systemAlarms.acknowledge(sessionID: sessionID)
    }

    private func bookAfterLeavingDuringHandoff(
        sessionID: UUID,
        phase: FocusEndAlarmPhase,
        endDate: Date,
        playsSound: Bool,
        completionSound: TimerCompletionSound,
        now: Date
    ) async throws -> TimerCompletionNotificationScheduleResult? {
        guard notifications.isAuthorized,
              let channel = AlarmChannelPolicy.channelAfterLeavingDuringHandoff(
                  endDate: endDate,
                  now: now,
                  strength: preferences.strength,
                  soundEnabled: playsSound,
                  notificationsAuthorized: true
              )
        else { return nil }
        return try await schedule(
            sessionID: sessionID,
            phase: phase,
            endDate: endDate,
            playsSound: playsSound,
            completionSound: completionSound,
            channel: channel
        )
    }

    private func book(
        sessionID: UUID,
        phase: FocusEndAlarmPhase,
        endDate: Date,
        playsSound: Bool,
        completionSound: TimerCompletionSound
    ) async throws -> Outcome {
        guard !Task.isCancelled, notifications.acceptsTimerScheduling else {
            return .notification(.superseded)
        }
        var notificationChannel: AlarmBackgroundChannel?
        switch channel(playsSound: playsSound) {
        case .systemAlarm:
            // The scheduler is fenced from this call on: a pause or cancel
            // while the ringtone is prepared books nothing.
            let choice = preferences.sound(legacy: completionSound)
            let ringtoneFileName = ringtoneFileName
            let soundGeneration = AlarmSoundLibrary.preparationGeneration
            let result = await systemAlarms.schedule(
                sessionID: sessionID,
                phase: phase,
                endDate: endDate
            ) {
                await ringtoneFileName(choice, soundGeneration)
            }
            switch result {
            case let .booked(booking):
                // Booked first, withdrawn second: the end is never left
                // without a channel in between.
                _ = try await schedule(
                    sessionID: sessionID,
                    phase: phase,
                    endDate: endDate,
                    playsSound: playsSound,
                    completionSound: completionSound,
                    channel: .systemAlarm
                )
                return .systemAlarm(booking)
            case .superseded:
                return .notification(.superseded)
            case .unsupported, .notAuthorized, .tooSoon, .failed:
                notificationChannel = AlarmChannelPolicy.notificationChannel(
                    strength: preferences.strength,
                    soundEnabled: playsSound,
                    notificationsAuthorized: notifications.isAuthorized
                )
                guard notificationChannel != AlarmBackgroundChannel.none else {
                    return .noChannel
                }
            }
        case .none:
            systemAlarms.cancel(sessionID: sessionID)
            return .noChannel
        case .timeSensitiveNotification:
            // A booking left from an earlier choice (the strength changed,
            // alarms were turned off) must not ring next to the notification.
            systemAlarms.cancel(sessionID: sessionID)
        }
        return .notification(try await schedule(
            sessionID: sessionID,
            phase: phase,
            endDate: endDate,
            playsSound: playsSound,
            completionSound: completionSound,
            channel: notificationChannel
        ))
    }

    private func schedule(
        sessionID: UUID,
        phase: FocusEndAlarmPhase,
        endDate: Date,
        playsSound: Bool,
        completionSound: TimerCompletionSound,
        channel: AlarmBackgroundChannel?
    ) async throws -> TimerCompletionNotificationScheduleResult {
        switch phase {
        case .focus:
            return try await notifications.scheduleFocusCompletion(
                sessionID: sessionID,
                endDate: endDate,
                playsSound: playsSound,
                completionSound: completionSound,
                channel: channel
            )
        case .breakTime:
            return try await notifications.scheduleBreakCompletion(
                id: sessionID,
                endDate: endDate,
                playsSound: playsSound,
                completionSound: completionSound,
                channel: channel
            )
        }
    }
}
