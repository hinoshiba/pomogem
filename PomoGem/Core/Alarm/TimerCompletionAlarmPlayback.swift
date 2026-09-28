import Foundation

/// Everything the in-app alarm needs for one resolved completion: the
/// timer's configuration (which channels are on), the strength and sound
/// this iPhone chose, and the plan `AlarmChannelPolicy.foregroundPlan`
/// derived from them.
///
/// WHETHER a completion rings, and whether it repeats, is decided before
/// this (`TimerCompletionForegroundFeedbackPolicy.Cue`, by the timer
/// screens). This only decides HOW it rings.
struct TimerCompletionAlarmRequest: Equatable, Sendable {
    let configuration: TimerCompletionAlertConfiguration
    let strength: AlarmStrength
    /// The sound to play, or nil when the app's sound is off.
    let sound: AlarmSoundChoice?
    let plan: AlarmForegroundPlan

    var sessionID: UUID { configuration.sessionID }

    /// Pure resolution, for tests and for `live`.
    static func resolve(
        configuration: TimerCompletionAlertConfiguration,
        cue: TimerCompletionForegroundFeedbackPolicy.Cue,
        strength: AlarmStrength,
        sound: AlarmSoundChoice?
    ) -> TimerCompletionAlarmRequest {
        let playsSound = configuration.sound != nil && sound != nil
        let plan = AlarmChannelPolicy.foregroundPlan(
            cue: cue,
            strength: strength,
            soundEnabled: playsSound,
            hapticsEnabled: configuration.haptic != nil,
            hapticStyle: configuration.haptic ?? .standard
        )
        return TimerCompletionAlarmRequest(
            configuration: configuration,
            strength: strength,
            sound: playsSound ? sound : nil,
            plan: plan
        )
    }

    /// Today's behaviour, whatever this iPhone chose: the synced chime every
    /// 1.3 s. Used by controllers built from plain closures (tests).
    static func gentle(
        _ configuration: TimerCompletionAlertConfiguration,
        _ cue: TimerCompletionForegroundFeedbackPolicy.Cue
    ) -> TimerCompletionAlarmRequest {
        resolve(
            configuration: configuration,
            cue: cue,
            strength: .gentle,
            sound: configuration.sound.map(AlarmSoundChoice.init(legacy:))
        )
    }

    /// The device-local strength and sound (`AlarmPreferences`). A
    /// configuration's synced chime stands for "sound on"; the sound played
    /// is this iPhone's choice, which falls back to that chime.
    @MainActor
    static func live(
        _ configuration: TimerCompletionAlertConfiguration,
        _ cue: TimerCompletionForegroundFeedbackPolicy.Cue
    ) -> TimerCompletionAlarmRequest {
        live(configuration, cue, preferences: AlarmPreferences())
    }

    @MainActor
    static func live(
        _ configuration: TimerCompletionAlertConfiguration,
        _ cue: TimerCompletionForegroundFeedbackPolicy.Cue,
        preferences: AlarmPreferences
    ) -> TimerCompletionAlarmRequest {
        resolve(
            configuration: configuration,
            cue: cue,
            strength: preferences.strength,
            sound: configuration.sound.map { preferences.sound(legacy: $0) }
        )
    }
}

/// Whether a timer screen holds the display (F5). The completion alarm at
/// the standard and maximum presets holds it while it rings
/// (`TimerCompletionAlertController.keepsScreenAwake(sessionID:)`), whatever
/// the keep-awake preference, so auto-lock cannot end it: leaving the app
/// counts as Stop. Only while the scene is active, and released once the
/// alarm stops or goes quiet by itself. Part 2 combines this with the
/// running timer's `TimerScreenAwakePolicy`.
enum TimerCompletionAlarmScreenAwakePolicy {
    static func shouldKeepScreenAwake(
        runningTimerKeepsScreenAwake: Bool,
        sceneIsActive: Bool,
        alarmKeepsScreenAwake: Bool
    ) -> Bool {
        runningTimerKeepsScreenAwake || (sceneIsActive && alarmKeepsScreenAwake)
    }
}

/// The hardware side of the in-app alarm. `TimerCompletionAlertController`
/// decides when; this plays.
@MainActor
protocol TimerCompletionAlarmPlayer: AnyObject {
    /// One short cue: the single cue after a return, and each cycle of the
    /// gentle preset's repeat.
    func playCue(_ request: TimerCompletionAlarmRequest)
    /// Starts the seamless loop, or leaves it playing. Called again on
    /// every cycle, so a loop the system stopped (Control Center, an audio
    /// interruption, a haptic engine reset) comes back by itself.
    func sustainLoop(_ request: TimerCompletionAlarmRequest)
    /// Silences everything this player started. After a silent-switch
    /// override it also releases the audio session, so other apps' audio
    /// returns to full volume.
    func stop()
}

/// Adapts the closure-based controller API (tests, previews): every cycle,
/// whether a cue or a loop, is one call of `playback`.
@MainActor
final class ClosureTimerCompletionAlarmPlayer: TimerCompletionAlarmPlayer {
    private let playback: TimerCompletionAlertController.Playback
    private let stopPlayback: TimerCompletionAlertController.StopPlayback

    init(
        playback: @escaping TimerCompletionAlertController.Playback,
        stopPlayback: @escaping TimerCompletionAlertController.StopPlayback
    ) {
        self.playback = playback
        self.stopPlayback = stopPlayback
    }

    func playCue(_ request: TimerCompletionAlarmRequest) {
        playback(request.configuration)
    }

    func sustainLoop(_ request: TimerCompletionAlarmRequest) {
        playback(request.configuration)
    }

    func stop() {
        stopPlayback()
    }
}

/// The production player: `SoundSynth` for sound, `Haptics` for vibration.
/// Both keep their own engine lifetimes (#41): the sound engine is prewarmed
/// and lingers after ordinary sounds, the haptic engine starts
/// asynchronously and a cue waits for it.
@MainActor
final class LiveTimerCompletionAlarmPlayer: TimerCompletionAlarmPlayer {
    private let sound: SoundSynth
    private let haptics: Haptics

    init(sound: SoundSynth? = nil, haptics: Haptics? = nil) {
        self.sound = sound ?? .shared
        self.haptics = haptics ?? .shared
    }

    func playCue(_ request: TimerCompletionAlarmRequest) {
        if request.plan.playsSound, let choice = request.sound {
            if let legacy = choice.legacySound, request.plan.audioSession == .ambient {
                // Exactly today's cue for the three original chimes.
                sound.playTimerCompletion(legacy)
            } else {
                sound.playTimerCompletionCue(choice, session: request.plan.audioSession)
            }
        }
        if request.plan.playsHaptics, let style = request.configuration.haptic {
            // A cue's vibration is the style's taps (`AlarmHapticPattern.taps`),
            // which is what `Haptics.playTimerCompletion` plays.
            haptics.playTimerCompletion(style)
        }
    }

    func sustainLoop(_ request: TimerCompletionAlarmRequest) {
        if request.plan.playsSound, let choice = request.sound {
            sound.sustainTimerCompletionLoop(choice, session: request.plan.audioSession)
        }
        if request.plan.playsHaptics, let pattern = request.plan.haptic {
            haptics.sustainTimerCompletionLoop(pattern)
        }
    }

    func stop() {
        sound.stopTimerCompletion()
        haptics.stopTimerCompletion()
    }
}
