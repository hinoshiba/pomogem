import Foundation

/// Books the one channel that announces a focus or break end while the app
/// is not in the foreground (F5): the AlarmKit alarm at the maximum preset
/// (iOS 26+, alarms allowed, the app's sound on), otherwise the Time
/// Sensitive notification. Exactly one is booked; switching channel
/// withdraws the other.
///
/// Part 2 wiring: the timer screens call `bookFocusEnd` / `bookBreakEnd`
/// where they call `NotificationManager.scheduleFocusCompletion` /
/// `scheduleBreakCompletion` today (start, resume, recovery, adoption).
/// Every existing cancel keeps working unchanged: `NotificationManager
/// .cancelFocusCompletion` and `cancelBreakCompletion` also cancel the
/// alarm.
@MainActor
final class TimerEndAnnouncementBooker {
    enum Outcome: Equatable, Sendable {
        /// The notification path, with its usual result.
        case notification(TimerCompletionNotificationScheduleResult)
        /// A system alarm announces the end; no notification is booked.
        case systemAlarm(FocusEndAlarmBooking)
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
        if channel(playsSound: playsSound) == .systemAlarm {
            let fileName = await ringtoneFileName(preferences.sound(legacy: completionSound))
            guard !Task.isCancelled, notifications.acceptsTimerScheduling else {
                return .notification(.superseded)
            }
            let result = await systemAlarms.schedule(
                sessionID: sessionID,
                phase: phase,
                endDate: endDate,
                soundFileName: fileName
            )
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
                    notificationsAuthorized: true
                )
            }
        } else {
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
