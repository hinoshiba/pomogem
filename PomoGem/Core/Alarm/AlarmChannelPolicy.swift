import Foundation

/// AlarmKit's permission as this app sees it. `unsupported` covers iOS 17–25
/// and builds without AlarmKit.
enum AlarmKitAuthorization: String, Codable, Sendable {
    case unsupported
    case notDetermined
    case denied
    case authorized
}

/// The audio session the in-app alarm plays through.
enum AlarmAudioSessionMode: Equatable, Sendable {
    /// `.ambient`: mixes with other audio and obeys the silent switch.
    case ambient
    /// `.playback` with `.duckOthers`, deactivated afterwards with
    /// `.notifyOthersOnDeactivation` so music comes back: plays with the
    /// silent switch on, for an alarm the person chose to make loudest.
    case playbackDuckingOthers
}

/// What a timer end is announced with while the app is not in the
/// foreground. Exactly one audible channel is booked per phase end.
enum AlarmBackgroundChannel: Equatable, Sendable {
    enum NotificationSound: Equatable, Sendable {
        case silent
        /// Today's short chime (`TimerCompletionSoundLibrary`).
        case shortChime
        /// The ≤ 28 s ringtone (`AlarmSoundLibrary`).
        case ringtone
    }

    /// An AlarmKit alarm at the end date; no notification is booked.
    case systemAlarm
    /// The existing Time Sensitive completion notification.
    case timeSensitiveNotification(NotificationSound)
    /// Nothing can be booked (no notification permission).
    case none
}

/// Everything the in-app alarm needs to know for one resolved completion.
struct AlarmForegroundPlan: Equatable, Sendable {
    enum Playback: Equatable, Sendable {
        case none
        /// Mark the moment once (a return shortly after the end).
        case once
        /// Repeat a short cue every `interval` seconds until Stop (the
        /// gentle preset: today's alarm).
        case repeating(interval: TimeInterval)
        /// Loop the pattern seamlessly until Stop.
        case loop
    }

    let playback: Playback
    let playsSound: Bool
    let playsHaptics: Bool
    let audioSession: AlarmAudioSessionMode
    let keepsScreenAwake: Bool
    let automaticStopInterval: TimeInterval?
    let haptic: AlarmHapticPattern?

    static let silent = AlarmForegroundPlan(
        playback: .none,
        playsSound: false,
        playsHaptics: false,
        audioSession: .ambient,
        keepsScreenAwake: false,
        automaticStopInterval: nil,
        haptic: nil
    )
}

/// Pure decisions about which channel announces the end of a focus or break.
/// It only chooses; the timer screens, `NotificationManager` and
/// `FocusEndAlarmScheduler` act. All #32 completion rules stay intact: the
/// alarm repeats only for a timer that ended on screen, a return or recovery
/// never loops, and leaving while it rings counts as Stop.
enum AlarmChannelPolicy {
    /// Today's repeat interval for the short cue.
    static let gentleRepeatInterval: TimeInterval = 1.3
    /// When the app is active this close to the end, the in-app alarm takes
    /// over and the AlarmKit alarm is cancelled, so only one channel rings.
    static let foregroundHandoffLead: TimeInterval = 1.5
    /// An end sooner than this is not booked with AlarmKit: the person is
    /// looking at the timer they just started or resumed.
    static let minimumSystemAlarmLead: TimeInterval = 5

    // MARK: Booking (at start, resume, recovery)

    /// The single background channel for a phase end.
    ///
    /// AlarmKit needs the maximum preset, iOS 26+, the person's permission
    /// and sound on (an alarm always sounds, so it is never used for someone
    /// who turned the app's sound off). Otherwise the Time Sensitive
    /// notification remains, with the long ringtone for the stronger presets.
    static func backgroundChannel(
        strength: AlarmStrength,
        soundEnabled: Bool,
        systemAlarm: AlarmKitAuthorization,
        notificationsAuthorized: Bool
    ) -> AlarmBackgroundChannel {
        if strength.usesSystemAlarmWhenAway,
           soundEnabled,
           systemAlarm == .authorized {
            return .systemAlarm
        }
        return notificationChannel(
            strength: strength,
            soundEnabled: soundEnabled,
            notificationsAuthorized: notificationsAuthorized
        )
    }

    /// The channel to fall back to when booking AlarmKit failed.
    static func notificationChannel(
        strength: AlarmStrength,
        soundEnabled: Bool,
        notificationsAuthorized: Bool
    ) -> AlarmBackgroundChannel {
        guard notificationsAuthorized else { return .none }
        guard soundEnabled else { return .timeSensitiveNotification(.silent) }
        return .timeSensitiveNotification(
            strength.usesLongNotificationSound ? .ringtone : .shortChime
        )
    }

    /// Whether a system alarm may be booked for an end this far away.
    static func systemAlarmLeadIsSufficient(endDate: Date, now: Date) -> Bool {
        let lead = endDate.timeIntervalSince(now)
        return lead.isFinite && lead >= minimumSystemAlarmLead
    }

    // MARK: The end

    /// True when the in-app alarm should take over from a booked AlarmKit
    /// alarm: the app is active and the end is at most
    /// `foregroundHandoffLead` away (or has just passed).
    static func shouldHandOffToForeground(
        applicationIsActive: Bool,
        endDate: Date,
        now: Date
    ) -> Bool {
        guard applicationIsActive else { return false }
        let remaining = endDate.timeIntervalSince(now)
        return remaining.isFinite && remaining <= foregroundHandoffLead
    }

    /// A booked AlarmKit alarm is a delivery witness, like an accepted
    /// notification: once its fire date has passed, the end was announced,
    /// so a later return plays no cue.
    static func externalAlertMayHaveFired(
        notificationAuthorized: Bool,
        notificationDeliveryDate: Date?,
        systemAlarmFireDate: Date?,
        now: Date
    ) -> Bool {
        if let systemAlarmFireDate, systemAlarmFireDate <= now {
            return true
        }
        return TimerCompletionForegroundFeedbackPolicy.notificationMayHaveDelivered(
            isAuthorized: notificationAuthorized,
            expectedDeliveryDate: notificationDeliveryDate,
            now: now
        )
    }

    /// The in-app plan for a completion whose cue
    /// `TimerCompletionForegroundFeedbackPolicy` already decided.
    static func foregroundPlan(
        cue: TimerCompletionForegroundFeedbackPolicy.Cue,
        strength: AlarmStrength,
        soundEnabled: Bool,
        hapticsEnabled: Bool,
        hapticStyle: TimerCompletionHaptic
    ) -> AlarmForegroundPlan {
        guard soundEnabled || hapticsEnabled else { return .silent }
        let session: AlarmAudioSessionMode = strength.overridesSilentSwitch && soundEnabled
            ? .playbackDuckingOthers
            : .ambient
        switch cue {
        case .none:
            return .silent
        case .single:
            return AlarmForegroundPlan(
                playback: .once,
                playsSound: soundEnabled,
                playsHaptics: hapticsEnabled,
                audioSession: session,
                keepsScreenAwake: false,
                automaticStopInterval: nil,
                haptic: hapticsEnabled
                    ? AlarmHapticPattern(events: AlarmHapticPattern.taps(for: hapticStyle), loopDuration: nil)
                    : nil
            )
        case .repeating:
            return AlarmForegroundPlan(
                playback: strength.loopsPattern
                    ? .loop
                    : .repeating(interval: gentleRepeatInterval),
                playsSound: soundEnabled,
                playsHaptics: hapticsEnabled,
                audioSession: session,
                keepsScreenAwake: strength.keepsScreenAwakeWhileRinging,
                automaticStopInterval: strength.automaticStopInterval,
                haptic: hapticsEnabled
                    ? AlarmHapticPattern.completion(strength: strength, style: hapticStyle)
                    : nil
            )
        }
    }
}
