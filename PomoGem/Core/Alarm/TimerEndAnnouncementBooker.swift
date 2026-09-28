import Foundation

/// Books the one channel that announces a focus or break end while the app
/// is not in the foreground (F5): the AlarmKit alarm at the maximum preset
/// (iOS 26+, alarms allowed, the app's sound on), otherwise the Time
/// Sensitive notification. Exactly one is booked; switching channel
/// withdraws the other. The booker decides every permission itself, so the
/// timer screens call it whether or not notifications are allowed: someone
/// who allowed alarms but declined notifications still gets the alarm.
///
/// Part 2 wiring (the timer screens; #49's `TimerForegroundResolution`
/// decides whether an end rings in the app, this only books how it is
/// announced while away):
///
/// 1. Booking. Replace every `NotificationManager.scheduleFocusCompletion`
///    / `scheduleBreakCompletion` call of a timer screen with
///    `bookFocusEnd` / `bookBreakEnd`: FocusView start, resume, activation
///    reschedule, recovery, adoption and the 「終了通知を設定」 retry;
///    BreakTimerView prepare, the sensory-preference reschedule and the
///    reschedule after the permission request; and
///    `RewardBreakNotificationHandoff.begin` (the 「N分休憩」 tap in
///    HomeView), which must store the delivery date only for
///    `.notification(.accepted)`.
/// 2. The permission gate. Gate those calls on
///    `channel(playsSound:) != .none` instead of
///    `notifications.isAuthorized` (FocusView's
///    `scheduleCurrentCompletionNotification` guard, its resume and
///    running-row gates; BreakTimerView's sensory `onChange` and
///    `requestNotificationAuthorizationAndSchedule`). BreakTimerView's
///    `.denied` / `.permissionNotDetermined` paths must still call the
///    booker when the channel is `.systemAlarm`; only the notification UI
///    shows the denied state. The first-focus notification ask stays as it
///    is (once, never on recovery).
/// 3. The outcome. Before the call the screen sets its scheduling state;
///    `TimerForegroundResolution` returns `.wait` while
///    `isSchedulingNotification` (`notificationScheduleState.isScheduling`),
///    so a booker call in flight must count as scheduling and every outcome
///    must leave that state:
///    `.notification(.accepted(date))` as today; `.systemAlarm` settles it
///    with no notification delivery date (for example `.scheduled` with a
///    nil date, then save recovery state) and shows an alarm variant of the
///    running notice (today's notice needs `notifications.isAuthorized`);
///    `.notification(.superseded)` leaves it to the call that superseded it;
///    `.noChannel` settles it as not scheduled. Today's
///    `guard case .accepted = result else { return }` would leave
///    `.scheduling` for `.systemAlarm`, and #49 would never resolve the end
///    on screen.
/// 4. Cancels need no change: `NotificationManager.cancelFocusCompletion`
///    and `cancelBreakCompletion` (pause, F1's auto-pause, abandon,
///    ownership loss, skip) also cancel the alarm, including a booking
///    still preparing its sound, and stop one that is ringing while keeping
///    it as the witness. Reset recovery, iCloud retirement, the account
///    boundary and complete deletion are wired in `NotificationManager` and
///    `FocusEndAlarmMaintenance`.
/// 5. The end. From the ticker, `handOffToForegroundIfDue`; when the scene
///    stops being active after a hand-off returned an end,
///    `book…EndAfterLeavingDuringHandoff`. For the cue decision,
///    `externalAlertMayHaveFired` in place of the notification-only witness
///    (FocusView's `completionCueForElapsedTimer` and BreakTimerView's
///    `notificationMayHaveDelivered(at:uptime:)` call
///    `TimerCompletionForegroundFeedbackPolicy.notificationMayHaveDelivered`
///    today; keep their trustworthy-timing gate on the notification date).
///    When the completion resolves on screen,
///    `FocusEndAlarmScheduler.shared.acknowledge(sessionID:)` (Stop while
///    the system alarm rings). While the in-app alarm rings,
///    `TimerCompletionAlertController.keepsScreenAwake(sessionID:)` joins
///    the idle-timer decision through
///    `TimerCompletionAlarmScreenAwakePolicy`.
/// 6. Activation. Rebooking a running timer's end on every activation (as
///    FocusView does today) is free: the same end and sound keep the booked
///    alarm (`FocusEndAlarmScheduler.schedule`). That rebooking also covers
///    `FocusEndAlarmReconciliation.ownerNeedsBooking` and a change of the
///    Alarms permission in the Settings app, so the host needs no extra
///    booking. BreakTimerView has no activation reschedule today; add one
///    for a running break (or book on `ownerNeedsBooking`).
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

    typealias RingtoneFileName = @MainActor (AlarmSoundChoice) async -> String?

    static let shared = TimerEndAnnouncementBooker(
        notifications: .shared,
        systemAlarms: .shared,
        preferences: AlarmPreferences(),
        ringtoneFileName: { choice in
            guard AlarmSoundLibrary.systemAlarmUsesRenderedRingtone,
                  let url = try? await AlarmSoundLibrary.preparedFile(.ringtone, for: choice)
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

    // MARK: The end (part 2 calls these from the timer screens)

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
    /// Part 2 hands this to the foreground cue decision (#49's resolver) in
    /// place of the notification-only witness. Reading it changes nothing.
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
            let result = await systemAlarms.schedule(
                sessionID: sessionID,
                phase: phase,
                endDate: endDate
            ) {
                await ringtoneFileName(choice)
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
