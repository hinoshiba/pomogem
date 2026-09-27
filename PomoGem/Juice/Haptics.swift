import CoreHaptics
import UIKit

/// In-process signal emitted immediately before this app asks the hardware to
/// play a haptic. Motion input can use the advertised duration to ignore the
/// phone movement produced by our own feedback without persisting sensor data.
enum HapticPlaybackNotification {
    static let willPlay = Notification.Name("com.hinoshiba.pomogem.hapticWillPlay")
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
    /// An asynchronous start is in flight. Its completion is fenced by
    /// `engineStartGeneration`, which every stop advances.
    private var isStartingEngine = false
    private var engineStartGeneration: UInt64 = 0
    /// Cues that arrived while the engine was stopped. They play when the
    /// asynchronous start completes (jar-03).
    private var deferredCues = DeferredHapticCues<Cue>()
    private var timerCompletionPlayer: CHHapticPatternPlayer?
    /// F5: the looping completion pattern playing, or waiting for the
    /// engine to start. Forgotten whenever the engine stops or resets, so
    /// the next `sustainTimerCompletionLoop` starts it again.
    private var timerCompletionLoop: AlarmHapticPattern?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private let lightFallback = UIImpactFeedbackGenerator(style: .light)
    private let mediumFallback = UIImpactFeedbackGenerator(style: .medium)
    private let heavyFallback = UIImpactFeedbackGenerator(style: .heavy)

    private init() {
        supportsCoreHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        configureEngineIfSupported()
        // Returning from the background finds the engine stopped by the
        // system. Warm it before the first cue (a completion cue plays as
        // the person comes back), so that cue is not the one that waits.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.prewarm()
            }
        }
    }

    deinit {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
    }

    func prepare() {
        guard isEnabled else { return }
        lightFallback.prepare()
        mediumFallback.prepare()
        heavyFallback.prepare()
        prewarm()
    }

    /// Starts the haptic engine without blocking the main thread, ahead of a
    /// cue that is about to happen (a gem entering the jar, the app becoming
    /// active). A cue that finds the engine stopped (idle auto-shutdown after
    /// a few seconds, a return from the background) calls this too and plays
    /// when the start completes. The synchronous `start()` it replaces
    /// measured 46 ms for the first start in a process on an iPhone 12 mini,
    /// paid inside a tap handler or a landing's contact callback (jar-03).
    func prewarm() {
        guard isEnabled,
              supportsCoreHaptics,
              let engine,
              !engineIsRunning,
              !isStartingEngine
        else { return }
        isStartingEngine = true
        let generation = engineStartGeneration
        engine.start { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.engineStartGeneration == generation else { return }
                self.isStartingEngine = false
                if error == nil {
                    self.engineIsRunning = true
                }
                self.playDeferredCues()
            }
        }
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

    /// F5, the standard and maximum presets: loops `pattern` (a continuous
    /// full-intensity vibration with the chosen style's taps as accents)
    /// through `CHHapticAdvancedPatternPlayer` with `loopEnabled`, or leaves
    /// it looping. Like every cue it waits for the asynchronous engine start
    /// (jar-03) instead of starting the engine on the main thread; a looping
    /// player keeps the engine from its idle auto-shutdown until
    /// `stopTimerCompletion`. Without Core Haptics each call is one UIKit
    /// impact, so the caller's cycle still reaches the hand.
    func sustainTimerCompletionLoop(_ pattern: AlarmHapticPattern) {
        guard isEnabled, let loopDuration = pattern.loopDuration, loopDuration > 0 else { return }
        let events = pattern.makeHapticEvents()
        guard !events.isEmpty else { return }
        let cue = Cue(
            events: events,
            duration: loopDuration,
            fallbackIntensity: 1,
            fallbackSharpness: 0.5,
            loopDuration: loopDuration
        )
        guard supportsCoreHaptics, engine != nil else {
            playFallback(cue)
            return
        }
        guard timerCompletionLoop != pattern else { return }
        timerCompletionLoop = pattern
        deliver(cue, kind: .timerCompletion)
    }

    /// Whether a completion loop plays or waits for the engine.
    var isTimerCompletionLoopRequested: Bool { timerCompletionLoop != nil }

    /// Stops only the retained completion pattern. Jar/drop haptics use their
    /// own short players and must not be interrupted by acknowledging a timer.
    func stopTimerCompletion() {
        deferredCues.cancelTimerCompletion()
        try? timerCompletionPlayer?.stop(atTime: CHHapticTimeImmediate)
        timerCompletionPlayer = nil
        timerCompletionLoop = nil
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
        deliver(
            Cue(
                events: events,
                duration: playbackDuration(for: events),
                fallbackIntensity: fallbackIntensity,
                fallbackSharpness: fallbackSharpness
            ),
            kind: .feedback
        )
    }

    private func playTimerCompletion(
        events: [CHHapticEvent],
        fallbackIntensity: CGFloat,
        fallbackSharpness: CGFloat = 0.5
    ) {
        guard isEnabled, !events.isEmpty else { return }
        deliver(
            Cue(
                events: events,
                duration: playbackDuration(for: events),
                fallbackIntensity: fallbackIntensity,
                fallbackSharpness: fallbackSharpness
            ),
            kind: .timerCompletion
        )
    }

    private func deliver(_ cue: Cue, kind: DeferredHapticCues<Cue>.Kind) {
        guard supportsCoreHaptics, engine != nil else {
            playFallback(cue)
            return
        }
        guard engineIsRunning else {
            // jar-03, after review of PR #41: never start the engine
            // synchronously here. A tap after the engine's idle
            // auto-shutdown used to block the main thread inside the tap
            // handler; the cue now waits a few milliseconds for the
            // asynchronous start instead.
            deferredCues.enqueue(cue, kind: kind, at: ProcessInfo.processInfo.systemUptime)
            prewarm()
            return
        }
        playOnRunningEngine(cue, kind: kind)
    }

    private func playDeferredCues() {
        for entry in deferredCues.drain(at: ProcessInfo.processInfo.systemUptime) {
            guard isEnabled else { return }
            if engineIsRunning {
                playOnRunningEngine(entry.cue, kind: entry.kind)
            } else {
                // The start failed: a UIKit impact remains available when
                // the haptic server is interrupted or reset. A loop that
                // could not start is forgotten, so the next cycle retries.
                if entry.kind == .timerCompletion { timerCompletionLoop = nil }
                playFallback(entry.cue)
            }
        }
    }

    private func playOnRunningEngine(_ cue: Cue, kind: DeferredHapticCues<Cue>.Kind) {
        guard let engine else {
            playFallback(cue)
            return
        }
        do {
            let pattern = try CHHapticPattern(events: cue.events, parameters: [])
            let player: CHHapticPatternPlayer
            if let loopDuration = cue.loopDuration {
                let looping = try engine.makeAdvancedPlayer(with: pattern)
                looping.loopEnabled = true
                looping.loopEnd = loopDuration
                player = looping
            } else {
                player = try engine.makePlayer(with: pattern)
            }
            if kind == .timerCompletion {
                try? timerCompletionPlayer?.stop(atTime: CHHapticTimeImmediate)
                timerCompletionPlayer = player
                if cue.loopDuration == nil { timerCompletionLoop = nil }
            }
            postWillPlay(duration: cue.duration)
            do {
                try player.start(atTime: CHHapticTimeImmediate)
            } catch {
                // The notification was already emitted for this physical
                // attempt, so the fallback must not emit a duplicate.
                if kind == .timerCompletion {
                    timerCompletionPlayer = nil
                    timerCompletionLoop = nil
                }
                engineIsRunning = false
                playFallbackImpact(cue)
            }
        } catch {
            // Pattern/player construction did not reach hardware. Fall
            // through to one announced UIKit impact.
            if kind == .timerCompletion {
                timerCompletionPlayer = nil
                timerCompletionLoop = nil
            }
            engineIsRunning = false
            playFallback(cue)
        }
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
                    self?.engineStartGeneration &+= 1
                    self?.isStartingEngine = false
                    self?.engineIsRunning = false
                    self?.timerCompletionPlayer = nil
                    self?.timerCompletionLoop = nil
                    self?.deferredCues.removeAll()
                }
            }
            hapticEngine.stoppedHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    // In particular, do not defeat idle auto-shutdown or try
                    // to restart while suspended/interrupted. Every stopped
                    // reason is safely retried by the next play/prewarm call.
                    self?.engineStartGeneration &+= 1
                    self?.isStartingEngine = false
                    self?.engineIsRunning = false
                    self?.timerCompletionPlayer = nil
                    self?.timerCompletionLoop = nil
                    self?.deferredCues.removeAll()
                }
            }
            engine = hapticEngine
        } catch {
            engine = nil
        }
    }

    private func stopEngine() {
        engineStartGeneration &+= 1
        isStartingEngine = false
        engineIsRunning = false
        deferredCues.removeAll()
        timerCompletionPlayer = nil
        timerCompletionLoop = nil
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

    /// One announced UIKit impact in place of a Core Haptics pattern.
    private func playFallback(_ cue: Cue) {
        postWillPlay(duration: cue.duration)
        playFallbackImpact(cue)
    }

    private func playFallbackImpact(_ cue: Cue) {
        playFallback(intensity: cue.fallbackIntensity, sharpness: cue.fallbackSharpness)
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

extension Haptics {
    /// One pattern and the UIKit impact that stands in for it.
    fileprivate struct Cue {
        let events: [CHHapticEvent]
        let duration: TimeInterval
        let fallbackIntensity: CGFloat
        let fallbackSharpness: CGFloat
        /// Set for the F5 completion loop: played through an advanced player
        /// with `loopEnabled` and this `loopEnd`.
        var loopDuration: TimeInterval? = nil
    }
}

/// jar-03, after review of PR #41. Cues that arrive while the haptic engine is
/// stopped wait for its asynchronous start instead of starting it
/// synchronously on the main thread. Plain bookkeeping, so its rules are
/// tested without haptic hardware (the simulator has none).
struct DeferredHapticCues<Cue> {
    enum Kind: Equatable {
        /// A jar, drop or reward cue tied to what the person just did or saw.
        case feedback
        /// The timer-complete cue, which is acknowledged separately.
        case timerCompletion
    }

    struct Entry {
        let cue: Cue
        let kind: Kind
        let requestedUptime: TimeInterval
    }

    /// A feedback cue that could not play within this long of its cause is
    /// dropped rather than felt detached from it. A normal start takes tens of
    /// milliseconds. The timer cue always plays.
    static var staleFeedbackLimit: TimeInterval { 0.25 }

    private var feedback: Entry?
    private var timerCompletion: Entry?

    var isEmpty: Bool { feedback == nil && timerCompletion == nil }

    /// Only the newest feedback cue waits, so cues that pile up during one
    /// start do not all fire together when it completes.
    mutating func enqueue(_ cue: Cue, kind: Kind, at uptime: TimeInterval) {
        let entry = Entry(cue: cue, kind: kind, requestedUptime: uptime)
        switch kind {
        case .feedback: feedback = entry
        case .timerCompletion: timerCompletion = entry
        }
    }

    /// The timer was acknowledged before its cue could play.
    mutating func cancelTimerCompletion() {
        timerCompletion = nil
    }

    mutating func removeAll() {
        feedback = nil
        timerCompletion = nil
    }

    /// Empties the queue and returns what should still play, timer cue first.
    mutating func drain(at uptime: TimeInterval) -> [Entry] {
        defer { removeAll() }
        var due: [Entry] = []
        if let timerCompletion {
            due.append(timerCompletion)
        }
        if let feedback, uptime - feedback.requestedUptime <= Self.staleFeedbackLimit {
            due.append(feedback)
        }
        return due
    }
}
