import CoreHaptics
import Foundation

/// A pure description of a completion vibration, so the pattern can be
/// tested without a haptic engine. `makeHapticPattern()` converts it to a
/// `CHHapticPattern`; playing it (with `loopEnabled` and `loopEnd` for a
/// looping pattern) belongs to `Haptics`.
struct AlarmHapticPattern: Equatable, Sendable {
    struct Event: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case transient
            case continuous(duration: TimeInterval)
        }

        let kind: Kind
        let time: TimeInterval
        let intensity: Float
        let sharpness: Float

        var end: TimeInterval {
            switch kind {
            case .transient: time
            case let .continuous(duration): time + duration
            }
        }
    }

    let events: [Event]
    /// For a looping pattern, the cycle length (`CHHapticAdvancedPatternPlayer.loopEnd`).
    /// Nil for a pattern played once per cue.
    let loopDuration: TimeInterval?

    /// Core Haptics rejects a continuous event longer than this.
    static let maximumContinuousDuration: TimeInterval = 30

    /// The vibration for one completion at `strength`.
    ///
    /// The three original styles keep their gentle transient cues exactly.
    /// Stronger presets sustain full-intensity pulses with real gaps, so
    /// each rhythm remains recognizable while an alarm is looping.
    static func completion(
        strength: AlarmStrength,
        style: TimerCompletionHaptic
    ) -> AlarmHapticPattern {
        switch strength {
        case .gentle:
            return AlarmHapticPattern(events: cueEvents(for: style), loopDuration: nil)
        case .standard:
            return rhythmicPattern(for: style, pulseScale: 1, pauseScale: 1, intensity: 1, loops: true)
        case .maximum:
            return rhythmicPattern(for: style, pulseScale: 1.4, pauseScale: 0.65, intensity: 1, loops: true)
        }
    }

    /// A short cue shared by single completions, gentle repeating alarms,
    /// and `Haptics.playTimerCompletion`. Every cue finishes before the
    /// gentle alarm's next 1.3-second tick, including sustained new styles.
    static func cueEvents(for style: TimerCompletionHaptic) -> [Event] {
        switch style {
        case .standard:
            [
                Event(kind: .transient, time: 0, intensity: 0.72, sharpness: 0.82),
                Event(kind: .transient, time: 0.14, intensity: 0.92, sharpness: 0.48)
            ]
        case .gentle:
            [Event(kind: .transient, time: 0, intensity: 0.42, sharpness: 0.30)]
        case .strong:
            [
                Event(kind: .transient, time: 0, intensity: 0.78, sharpness: 0.74),
                Event(kind: .transient, time: 0.11, intensity: 0.94, sharpness: 0.54),
                Event(kind: .transient, time: 0.24, intensity: 1.00, sharpness: 0.36)
            ]
        case .heartbeat, .rapid, .longBuzz, .wave, .insist:
            rhythmicPattern(for: style, pulseScale: 0.65, pauseScale: 0.65, intensity: 0.9, loops: false).events
        }
    }

    private struct Pulse {
        let duration: TimeInterval
        let pauseAfter: TimeInterval
        let sharpness: Float

        init(_ duration: TimeInterval, pause: TimeInterval = 0, sharpness: Float = 0.55) {
            self.duration = duration
            pauseAfter = pause
            self.sharpness = sharpness
        }
    }

    /// Silence between pulses is part of each style, not merely an accent
    /// over the same continuous buzz. The last pause is supplied separately
    /// so every looping rhythm has a clear boundary.
    private static func rhythm(for style: TimerCompletionHaptic) -> [Pulse] {
        switch style {
        case .standard:
            [Pulse(0.45, pause: 0.16), Pulse(0.45)]
        case .gentle:
            [Pulse(0.90, sharpness: 0.28)]
        case .strong:
            [Pulse(0.30, pause: 0.12), Pulse(0.30, pause: 0.12), Pulse(0.30)]
        case .heartbeat:
            [
                Pulse(0.20, pause: 0.09, sharpness: 0.35), Pulse(0.32, pause: 0.30, sharpness: 0.45),
                Pulse(0.20, pause: 0.09, sharpness: 0.35), Pulse(0.32, sharpness: 0.45)
            ]
        case .rapid:
            (0..<6).map { Pulse(0.12, pause: $0 == 5 ? 0 : 0.11, sharpness: 0.85) }
        case .longBuzz:
            [Pulse(1.25, sharpness: 0.65)]
        case .wave:
            [
                Pulse(0.13, pause: 0.14, sharpness: 0.25), Pulse(0.22, pause: 0.14, sharpness: 0.40),
                Pulse(0.35, pause: 0.14, sharpness: 0.60), Pulse(0.50, sharpness: 0.80)
            ]
        case .insist:
            [Pulse(0.18, pause: 0.12, sharpness: 0.80), Pulse(0.18, pause: 0.28, sharpness: 0.80), Pulse(0.70)]
        }
    }

    private static func rhythmicPattern(
        for style: TimerCompletionHaptic,
        pulseScale: Double,
        pauseScale: Double,
        intensity: Float,
        loops: Bool
    ) -> AlarmHapticPattern {
        var events: [Event] = []
        var time: TimeInterval = 0
        for pulse in rhythm(for: style) {
            let duration = pulse.duration * pulseScale
            events.append(Event(kind: .transient, time: time, intensity: intensity, sharpness: max(pulse.sharpness, 0.65)))
            events.append(Event(kind: .continuous(duration: duration), time: time, intensity: intensity, sharpness: pulse.sharpness))
            time += duration + pulse.pauseAfter * pauseScale
        }
        return AlarmHapticPattern(
            events: events,
            loopDuration: loops ? time + 0.4 * pauseScale : nil
        )
    }

    /// The last moment any event is felt.
    var duration: TimeInterval {
        events.map(\.end).max() ?? 0
    }

    func makeHapticPattern() throws -> CHHapticPattern {
        try CHHapticPattern(events: makeHapticEvents(), parameters: [])
    }

    /// The events of `makeHapticPattern()`, for players that build their
    /// own pattern (`Haptics` defers a cue until its engine has started).
    func makeHapticEvents() -> [CHHapticEvent] {
        events.map { event -> CHHapticEvent in
            let parameters = [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: event.intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: event.sharpness)
            ]
            switch event.kind {
            case .transient:
                return CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: parameters,
                    relativeTime: event.time
                )
            case let .continuous(duration):
                return CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: parameters,
                    relativeTime: event.time,
                    duration: duration
                )
            }
        }
    }
}
