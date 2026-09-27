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
    /// The gentle preset is today's cue exactly (the transient taps of
    /// `Haptics.playTimerCompletion`). The stronger presets loop a
    /// continuous full-intensity vibration, with the chosen style's taps as
    /// sharp accents so the choice still means something.
    static func completion(
        strength: AlarmStrength,
        style: TimerCompletionHaptic
    ) -> AlarmHapticPattern {
        switch strength {
        case .gentle:
            return AlarmHapticPattern(events: taps(for: style), loopDuration: nil)
        case .standard:
            return alarm(style: style, buzz: 0.8, accentOffsets: [0, 0.45], loop: 1.5)
        case .maximum:
            return alarm(style: style, buzz: 1.0, accentOffsets: [0, 0.35, 0.70], loop: 1.4)
        }
    }

    /// The legacy transient taps, as `Haptics.playTimerCompletion` plays them.
    static func taps(for style: TimerCompletionHaptic) -> [Event] {
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
        }
    }

    private static func alarm(
        style: TimerCompletionHaptic,
        buzz: TimeInterval,
        accentOffsets: [TimeInterval],
        loop: TimeInterval
    ) -> AlarmHapticPattern {
        var events = [
            Event(kind: .continuous(duration: buzz), time: 0, intensity: 1, sharpness: 0.35)
        ]
        for offset in accentOffsets {
            events += taps(for: style).map { tap in
                Event(
                    kind: .transient,
                    time: offset + tap.time,
                    intensity: 1,
                    sharpness: max(tap.sharpness, 0.6)
                )
            }
        }
        return AlarmHapticPattern(
            events: events.sorted { $0.time < $1.time },
            loopDuration: loop
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
