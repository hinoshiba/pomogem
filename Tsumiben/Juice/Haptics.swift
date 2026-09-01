import CoreHaptics
import UIKit

/// Core Haptics patterns for the drop, with a UIKit fallback on unsupported hardware.
@MainActor
final class Haptics {
    static let shared = Haptics()

    var isEnabled = true

    private let supportsCoreHaptics: Bool
    private var engine: CHHapticEngine?
    private let fallback = UIImpactFeedbackGenerator(style: .heavy)

    private init() {
        supportsCoreHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        configureEngineIfSupported()
    }

    func prepare() {
        guard isEnabled else { return }
        fallback.prepare()
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

    /// A crisp two-beat cue at the exact timer boundary. The heavier jar
    /// landing remains separate so the completion and the physical drop are
    /// distinguishable even when the screen is not being watched.
    func playTimerCompletion() {
        let first = transient(intensity: 0.72, sharpness: 0.82)
        let second = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.92),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.48)
            ],
            relativeTime: 0.14
        )
        play(events: [first, second], fallbackIntensity: 0.9)
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

    private func play(events: [CHHapticEvent], fallbackIntensity: CGFloat) {
        guard isEnabled else { return }
        guard supportsCoreHaptics else {
            playFallback(intensity: fallbackIntensity)
            return
        }

        do {
            startEngine()
            guard let engine else {
                playFallback(intensity: fallbackIntensity)
                return
            }
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            playFallback(intensity: fallbackIntensity)
        }
    }

    private func configureEngineIfSupported() {
        guard supportsCoreHaptics else { return }
        do {
            let hapticEngine = try CHHapticEngine()
            hapticEngine.playsHapticsOnly = true
            hapticEngine.isAutoShutdownEnabled = true
            hapticEngine.resetHandler = { [weak self] in
                Task { @MainActor [weak self] in self?.startEngine() }
            }
            hapticEngine.stoppedHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard self?.isEnabled == true else { return }
                    self?.startEngine()
                }
            }
            engine = hapticEngine
            startEngine()
        } catch {
            engine = nil
        }
    }

    private func startEngine() {
        guard isEnabled, supportsCoreHaptics, let engine else { return }
        do {
            try engine.start()
        } catch {
            // A UIKit impact remains available when the server is interrupted or reset.
        }
    }

    private func playFallback(intensity: CGFloat) {
        fallback.prepare()
        fallback.impactOccurred(intensity: min(max(intensity, 0), 1))
    }
}
