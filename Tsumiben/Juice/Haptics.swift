import CoreHaptics
import UIKit

/// In-process signal emitted immediately before this app asks the hardware to
/// play a haptic. Motion input can use the advertised duration to ignore the
/// phone movement produced by our own feedback without persisting sensor data.
enum HapticPlaybackNotification {
    static let willPlay = Notification.Name("com.hinoshiba.tumiben.hapticWillPlay")
    static let durationKey = "duration"
}

/// Core Haptics patterns for the drop, with a UIKit fallback on unsupported hardware.
@MainActor
final class Haptics {
    static let shared = Haptics()

    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue, !isEnabled else { return }
            stopEngine()
        }
    }

    private let supportsCoreHaptics: Bool
    private var engine: CHHapticEngine?
    private var engineIsRunning = false
    private var timerCompletionPlayer: CHHapticPatternPlayer?
    private let lightFallback = UIImpactFeedbackGenerator(style: .light)
    private let mediumFallback = UIImpactFeedbackGenerator(style: .medium)
    private let heavyFallback = UIImpactFeedbackGenerator(style: .heavy)

    private init() {
        supportsCoreHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        configureEngineIfSupported()
    }

    func prepare() {
        guard isEnabled else { return }
        lightFallback.prepare()
        mediumFallback.prepare()
        heavyFallback.prepare()
        startEngine()
    }

    func playLanding(impactSpeed: CGFloat) {
        let raw = Constants.Haptics.landingIntensityBase
            + Float(abs(impactSpeed)) / Float(Constants.Haptics.landingVelocityDivisor)
        let intensity = min(
            max(raw, Constants.Haptics.landingIntensityMin),
            Constants.Haptics.landingIntensityMax
        )
        play(
            events: [
                transient(
                    intensity: intensity,
                    sharpness: Constants.Haptics.landingSharpness
                )
            ],
            fallbackIntensity: CGFloat(intensity)
        )
    }

    func playSecondaryCollision() {
        play(
            events: [
                transient(
                    intensity: Constants.Haptics.secondaryIntensity,
                    sharpness: Constants.Haptics.secondarySharpness
                )
            ],
            fallbackIntensity: CGFloat(Constants.Haptics.secondaryIntensity)
        )
    }

    /// Plays the exact bounded pulse plan shared with the procedural clinks.
    /// A large gem adds a short, soft rumble while a pile produces at most four
    /// decaying taps, avoiding one haptic event per physics body/contact.
    func playJarFeedback(_ plan: JarSensoryPlan) {
        guard isEnabled, !plan.hapticPulses.isEmpty else { return }
        var events = plan.hapticPulses.map { pulse in
            transient(
                intensity: min(max(pulse.intensity, 0), 1),
                sharpness: min(max(pulse.sharpness, 0), 1),
                relativeTime: max(pulse.delay, 0)
            )
        }
        if let rumble = plan.rumble,
           rumble.duration > 0,
           rumble.intensity > 0 {
            events.append(CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(
                        parameterID: .hapticIntensity,
                        value: min(max(rumble.intensity, 0), 1)
                    ),
                    CHHapticEventParameter(
                        parameterID: .hapticSharpness,
                        value: min(max(rumble.sharpness, 0), 1)
                    )
                ],
                relativeTime: 0,
                duration: min(max(rumble.duration, 0.01), 0.20)
            ))
        }
        let strongest = plan.hapticPulses.max { $0.intensity < $1.intensity }
        play(
            events: events,
            fallbackIntensity: CGFloat(strongest?.intensity ?? 0.2),
            fallbackSharpness: CGFloat(strongest?.sharpness ?? 0.5)
        )
    }

    /// A bounded timer-only cue. Jar landing feedback remains separate so the
    /// completion and the physical drop are distinguishable without looking.
    func playTimerCompletion(_ style: TimerCompletionHaptic = .standard) {
        switch style {
        case .standard:
            playTimerCompletion(
                events: [
                    transient(intensity: 0.72, sharpness: 0.82),
                    transient(intensity: 0.92, sharpness: 0.48, relativeTime: 0.14)
                ],
                fallbackIntensity: 0.9
            )
        case .gentle:
            playTimerCompletion(
                events: [transient(intensity: 0.42, sharpness: 0.30)],
                fallbackIntensity: 0.42,
                fallbackSharpness: 0.30
            )
        case .strong:
            playTimerCompletion(
                events: [
                    transient(intensity: 0.78, sharpness: 0.74),
                    transient(intensity: 0.94, sharpness: 0.54, relativeTime: 0.11),
                    transient(intensity: 1.00, sharpness: 0.36, relativeTime: 0.24)
                ],
                fallbackIntensity: 1,
                fallbackSharpness: 0.45
            )
        }
    }

    /// Stops only the retained completion pattern. Jar/drop haptics use their
    /// own short players and must not be interrupted by acknowledging a timer.
    func stopTimerCompletion() {
        try? timerCompletionPlayer?.stop(atTime: CHHapticTimeImmediate)
        timerCompletionPlayer = nil
    }

    func playGold() {
        let transientEvent = transient(
            intensity: Constants.Haptics.goldTransientIntensity,
            sharpness: Constants.Haptics.goldTransientSharpness
        )
        let continuous = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(
                    parameterID: .hapticIntensity,
                    value: Constants.Haptics.goldContinuousIntensity
                ),
                CHHapticEventParameter(
                    parameterID: .hapticSharpness,
                    value: Constants.Haptics.goldContinuousSharpness
                )
            ],
            relativeTime: .zero,
            duration: Constants.Haptics.goldContinuousDuration
        )
        play(events: [transientEvent, continuous], fallbackIntensity: 1)
    }

    /// A short rising triplet mirrors the prism arpeggio. It remains distinct
    /// from both the timer-complete double beat and the gold shimmer without
    /// extending the reward moment.
    func playPrism() {
        let events = zip(
            Constants.Haptics.prismBeatIntensities,
            Constants.Haptics.prismBeatSharpness
        ).enumerated().map { index, values in
            transient(
                intensity: values.0,
                sharpness: values.1,
                relativeTime: Double(index) * Constants.Haptics.prismBeatInterval
            )
        }
        play(events: events, fallbackIntensity: 1)
    }

    func playShake() {
        let continuous = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(
                    parameterID: .hapticIntensity,
                    value: Constants.Haptics.shakeIntensity
                ),
                CHHapticEventParameter(
                    parameterID: .hapticSharpness,
                    value: Constants.Haptics.shakeSharpness
                )
            ],
            relativeTime: .zero,
            duration: Constants.Haptics.shakeDuration
        )
        play(events: [continuous], fallbackIntensity: 1)
    }

    private func transient(
        intensity: Float,
        sharpness: Float,
        relativeTime: TimeInterval = .zero
    ) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: relativeTime
        )
    }

    private func play(
        events: [CHHapticEvent],
        fallbackIntensity: CGFloat,
        fallbackSharpness: CGFloat = 0.5
    ) {
        guard isEnabled, !events.isEmpty else { return }
        let duration = playbackDuration(for: events)
        guard supportsCoreHaptics else {
            postWillPlay(duration: duration)
            playFallback(intensity: fallbackIntensity, sharpness: fallbackSharpness)
            return
        }

        if startEngine(), let engine {
            do {
                let pattern = try CHHapticPattern(events: events, parameters: [])
                let player = try engine.makePlayer(with: pattern)
                postWillPlay(duration: duration)
                do {
                    try player.start(atTime: CHHapticTimeImmediate)
                } catch {
                    // The notification was already emitted for this physical
                    // attempt, so the fallback must not emit a duplicate.
                    engineIsRunning = false
                    playFallback(intensity: fallbackIntensity, sharpness: fallbackSharpness)
                }
                return
            } catch {
                // Pattern/player construction did not reach hardware. Fall
                // through to one announced UIKit impact.
                engineIsRunning = false
            }
        }

        postWillPlay(duration: duration)
        playFallback(intensity: fallbackIntensity, sharpness: fallbackSharpness)
    }

    private func playTimerCompletion(
        events: [CHHapticEvent],
        fallbackIntensity: CGFloat,
        fallbackSharpness: CGFloat = 0.5
    ) {
        guard isEnabled, !events.isEmpty else { return }
        let duration = playbackDuration(for: events)
        guard supportsCoreHaptics else {
            postWillPlay(duration: duration)
            playFallback(intensity: fallbackIntensity, sharpness: fallbackSharpness)
            return
        }

        if startEngine(), let engine {
            do {
                let pattern = try CHHapticPattern(events: events, parameters: [])
                let player = try engine.makePlayer(with: pattern)
                try? timerCompletionPlayer?.stop(atTime: CHHapticTimeImmediate)
                timerCompletionPlayer = player
                postWillPlay(duration: duration)
                do {
                    try player.start(atTime: CHHapticTimeImmediate)
                } catch {
                    timerCompletionPlayer = nil
                    engineIsRunning = false
                    playFallback(
                        intensity: fallbackIntensity,
                        sharpness: fallbackSharpness
                    )
                }
                return
            } catch {
                timerCompletionPlayer = nil
                engineIsRunning = false
            }
        }

        postWillPlay(duration: duration)
        playFallback(intensity: fallbackIntensity, sharpness: fallbackSharpness)
    }

    private func configureEngineIfSupported() {
        guard supportsCoreHaptics else { return }
        do {
            let hapticEngine = try CHHapticEngine()
            hapticEngine.playsHapticsOnly = true
            hapticEngine.isAutoShutdownEnabled = true
            hapticEngine.resetHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    // A reset invalidates the prior running state. Retrying
                    // here can form a reset/start loop; the next play/prepare
                    // is the intentional, on-demand retry boundary.
                    self?.engineIsRunning = false
                    self?.timerCompletionPlayer = nil
                }
            }
            hapticEngine.stoppedHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    // In particular, do not defeat idle auto-shutdown or try
                    // to restart while suspended/interrupted. Every stopped
                    // reason is safely retried by the next play/prepare call.
                    self?.engineIsRunning = false
                    self?.timerCompletionPlayer = nil
                }
            }
            engine = hapticEngine
        } catch {
            engine = nil
        }
    }

    @discardableResult
    private func startEngine() -> Bool {
        guard isEnabled, supportsCoreHaptics, let engine else { return false }
        if engineIsRunning { return true }
        do {
            try engine.start()
            engineIsRunning = true
            return true
        } catch {
            // A UIKit impact remains available when the server is interrupted or reset.
            engineIsRunning = false
            return false
        }
    }

    private func stopEngine() {
        engineIsRunning = false
        timerCompletionPlayer = nil
        engine?.stop(completionHandler: nil)
    }

    private func playbackDuration(for events: [CHHapticEvent]) -> TimeInterval {
        events.reduce(0.06) { duration, event in
            max(
                duration,
                max(event.relativeTime, 0) + max(event.duration, 0.06)
            )
        }
    }

    private func postWillPlay(duration: TimeInterval) {
        NotificationCenter.default.post(
            name: HapticPlaybackNotification.willPlay,
            object: nil,
            userInfo: [
                HapticPlaybackNotification.durationKey: max(duration, 0.06)
            ]
        )
    }

    private func playFallback(intensity: CGFloat, sharpness: CGFloat) {
        let generator: UIImpactFeedbackGenerator
        if intensity >= 0.68 {
            generator = heavyFallback
        } else if sharpness >= 0.68 {
            generator = lightFallback
        } else {
            generator = mediumFallback
        }
        generator.prepare()
        generator.impactOccurred(intensity: min(max(intensity, 0), 1))
    }
}
