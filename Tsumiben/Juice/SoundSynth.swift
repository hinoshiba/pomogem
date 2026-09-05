import AVFoundation
import Observation
import UIKit
import UserNotifications

enum JarSensoryTrigger: Equatable, Sendable {
    case tap
    case shake
    case collision
}

struct JarSensorySample: Equatable, Sendable {
    let radius: Double
    let coupling: Double
}

struct JarClinkEvent: Equatable, Sendable {
    let delay: TimeInterval
    let pitchRate: Float
    let gain: Float
    let variant: Int
}

struct JarHapticPulse: Equatable, Sendable {
    let delay: TimeInterval
    let intensity: Float
    let sharpness: Float
}

struct JarHapticRumble: Equatable, Sendable {
    let duration: TimeInterval
    let intensity: Float
    let sharpness: Float
}

struct JarSensoryPlan: Equatable, Sendable {
    let clinks: [JarClinkEvent]
    let hapticPulses: [JarHapticPulse]
    let rumble: JarHapticRumble?
    let soundCooldown: TimeInterval
    let hapticCooldown: TimeInterval

    static let silent = JarSensoryPlan(
        clinks: [],
        hapticPulses: [],
        rumble: nil,
        soundCooldown: Constants.Sound.secondaryCollisionCooldown,
        hapticCooldown: Constants.Sound.secondaryCollisionCooldown
    )
}

/// Converts physical jar state into one short, bounded audiovisual gesture.
///
/// Only the number of live bodies contributes to abundance: a x10,000
/// aggregate remains one large, heavy stone rather than impersonating ten
/// thousand simultaneous sounds. Keeping this policy platform-independent also
/// lets release tests prove its limits without requiring audio or haptic
/// hardware.
enum JarSensoryPolicy {
    static func plan(
        trigger: JarSensoryTrigger,
        samples rawSamples: [JarSensorySample],
        gestureStrength rawGestureStrength: Double,
        abundanceCount rawAbundanceCount: Int? = nil,
        seed: UInt64
    ) -> JarSensoryPlan {
        guard rawGestureStrength.isFinite else { return .silent }
        let gestureStrength = clamp(rawGestureStrength, lower: 0, upper: 1)
        guard gestureStrength > 0 else { return .silent }

        let samples = rawSamples.compactMap { sample -> JarSensorySample? in
            guard sample.radius.isFinite,
                  sample.radius > 0,
                  sample.coupling.isFinite,
                  sample.coupling > 0
            else { return nil }
            return JarSensorySample(
                radius: clamp(sample.radius, lower: 4, upper: 36),
                coupling: clamp(sample.coupling, lower: 0.04, upper: 1)
            )
        }
        guard !samples.isEmpty else { return .silent }

        var radiusWeight = 0.0
        var weightedRadius = 0.0
        var squaredCoupling = 0.0
        for sample in samples {
            let weight = sample.radius * sample.radius * sample.coupling
            radiusWeight += weight
            weightedRadius += sample.radius * weight
            squaredCoupling += sample.coupling * sample.coupling
        }
        guard radiusWeight > 0 else { return .silent }

        let meanRadius = weightedRadius / radiusWeight
        let heaviness = clamp(
            (log(meanRadius) - log(8)) / (log(30) - log(8)),
            lower: 0,
            upper: 1
        )
        let abundanceCount = min(
            max(rawAbundanceCount ?? samples.count, 1),
            Constants.Jar.maxPhysicsBodies
        )
        let abundance = clamp(
            log2(1 + Double(abundanceCount)) / log2(33),
            lower: 0,
            upper: 1
        )
        let meanCoupling = sqrt(squaredCoupling / Double(samples.count))
        let strength = clamp(
            gestureStrength * meanCoupling,
            lower: 0,
            upper: 1
        )

        let maximumClinks: Int
        switch trigger {
        case .tap: maximumClinks = 4
        case .shake: maximumClinks = 6
        case .collision: maximumClinks = 1
        }
        let requestedClinks = Int((
            1 + Double(maximumClinks - 1) * sqrt(abundance * strength)
        ).rounded())
        let clinkCount = min(abundanceCount, max(1, requestedClinks))
        let totalGain = min(
            0.52,
            0.12 + 0.25 * sqrt(strength) + 0.08 * heaviness + 0.05 * abundance
        )
        let perClinkGain = totalGain / sqrt(Double(clinkCount))
        let targetFrequency = exp(
            log(1_800) + (log(650) - log(1_800)) * heaviness
        )
        let basePitchRate = targetFrequency / Constants.Sound.gemClinkBaseFrequency
        let spacing = 0.045 + (0.018 - 0.045) * abundance
        let clinks = (0 ..< clinkCount).map { index in
            let pitchJitter = (seededUnit(seed, index: index, salt: 0xA1) - 0.5) * 0.08
            let delayJitter = (seededUnit(seed, index: index, salt: 0xB7) - 0.5) * 0.012
            return JarClinkEvent(
                delay: trigger == .collision
                    ? 0
                    : max(0, Double(index) * spacing + delayJitter),
                pitchRate: Float(clamp(
                    basePitchRate * (1 + pitchJitter),
                    lower: 0.50,
                    upper: 1.75
                )),
                gain: Float(clamp(perClinkGain, lower: 0.04, upper: 0.52)),
                variant: Int(seededUnit(seed, index: index, salt: 0xD3) * Double(
                    Constants.Sound.gemClinkVariantCount
                )).clamped(to: 0 ... max(Constants.Sound.gemClinkVariantCount - 1, 0))
            )
        }

        let maximumPulses: Int
        switch trigger {
        case .tap: maximumPulses = 3
        case .shake: maximumPulses = 4
        case .collision: maximumPulses = 1
        }
        let pulseCount = min(clinkCount, maximumPulses)
        let baseIntensity = clamp(
            0.16 + 0.42 * strength + 0.20 * heaviness + 0.08 * abundance,
            lower: 0.16,
            upper: 0.82
        )
        let sharpness = clamp(
            0.88 - 0.58 * heaviness + 0.05 * strength,
            lower: 0.20,
            upper: 0.92
        )
        let pulses = (0 ..< pulseCount).map { index in
            JarHapticPulse(
                delay: trigger == .collision ? 0 : Double(index) * spacing,
                intensity: Float(baseIntensity * pow(0.76, Double(index))),
                sharpness: Float(sharpness)
            )
        }
        let rumble: JarHapticRumble? = heaviness > 0.55 && trigger != .collision
            ? JarHapticRumble(
                duration: 0.06 + 0.08 * heaviness,
                intensity: Float((0.06 + 0.14 * heaviness) * strength),
                sharpness: Float(0.08 + 0.16 * (1 - heaviness))
            )
            : nil

        return JarSensoryPlan(
            clinks: clinks,
            hapticPulses: pulses,
            rumble: rumble,
            soundCooldown: 0.12 - 0.055 * abundance,
            hapticCooldown: 0.16 - 0.03 * abundance
        )
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    /// SplitMix64 gives deterministic timbre/delay variation without relying
    /// on Swift's process-randomized Hasher or persisting any interaction data.
    private static func seededUnit(_ seed: UInt64, index: Int, salt: UInt64) -> Double {
        var value = seed
            &+ UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15
            &+ salt
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) / Double(UInt64(1) << 53)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

struct TimerCompletionAlertConfiguration: Equatable, Sendable {
    let sessionID: UUID
    let sound: TimerCompletionSound?
    let haptic: TimerCompletionHaptic?

    var isSilent: Bool { sound == nil && haptic == nil }
}

/// Repeats a short, bounded completion cue while the app is in the foreground.
///
/// iOS suspends ordinary apps in the background, where the scheduled local
/// notification remains the only supported completion cue. Keeping the
/// logical alert alive while inactive lets it resume after the app becomes
/// active without requesting background audio or bypassing the silent switch.
/// Generation fencing protects a newer timer from a late, non-cooperative
/// cancellation or stop action owned by an older session.
@MainActor
@Observable
final class TimerCompletionAlertController {
    typealias Sleeper = @Sendable () async throws -> Void
    typealias Playback = @MainActor @Sendable (
        TimerCompletionAlertConfiguration
    ) -> Void
    typealias StopPlayback = @MainActor @Sendable () -> Void
    typealias ApplicationIsActive = @MainActor @Sendable () -> Bool

    static let shared = TimerCompletionAlertController()

    private(set) var activeConfiguration: TimerCompletionAlertConfiguration?

    private let sleeper: Sleeper
    private let playback: Playback
    private let stopPlayback: StopPlayback
    private let applicationIsActive: ApplicationIsActive
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(
        sleeper: @escaping Sleeper = {
            try await Task.sleep(for: .milliseconds(1_300))
        },
        playback: @escaping Playback = { configuration in
            if let sound = configuration.sound {
                SoundSynth.shared.playTimerCompletion(sound)
            }
            if let haptic = configuration.haptic {
                Haptics.shared.playTimerCompletion(haptic)
            }
        },
        stopPlayback: @escaping StopPlayback = {
            SoundSynth.shared.stopTimerCompletion()
            Haptics.shared.stopTimerCompletion()
        },
        applicationIsActive: @escaping ApplicationIsActive = {
            UIApplication.shared.applicationState == .active
        }
    ) {
        self.sleeper = sleeper
        self.playback = playback
        self.stopPlayback = stopPlayback
        self.applicationIsActive = applicationIsActive
    }

    func isActive(sessionID: UUID) -> Bool {
        activeConfiguration?.sessionID == sessionID
    }

    func start(
        _ configuration: TimerCompletionAlertConfiguration,
        playsImmediately: Bool = true
    ) {
        guard !configuration.isSilent else {
            // A stale completion whose two channels are disabled must never
            // acknowledge or stop a newer session's audible alert.
            stop(sessionID: configuration.sessionID)
            return
        }
        guard activeConfiguration != configuration else { return }

        generation &+= 1
        let alertGeneration = generation
        task?.cancel()
        if activeConfiguration != nil {
            stopPlayback()
        }
        activeConfiguration = configuration

        if playsImmediately, applicationIsActive() {
            playback(configuration)
        }

        let sleeper = self.sleeper
        let playback = self.playback
        let applicationIsActive = self.applicationIsActive
        task = Task { @MainActor [weak self] in
            while true {
                do {
                    try await sleeper()
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      self.generation == alertGeneration,
                      self.activeConfiguration == configuration
                else { return }
                if applicationIsActive() {
                    playback(configuration)
                }
            }
        }
    }

    func stop(sessionID: UUID? = nil) {
        guard let activeConfiguration else { return }
        if let sessionID, activeConfiguration.sessionID != sessionID { return }

        generation &+= 1
        task?.cancel()
        task = nil
        self.activeConfiguration = nil
        stopPlayback()
    }
}

/// A bounded, account-scoped acknowledgement prevents a recovered failed save
/// from sounding again after the person already pressed Stop. UUIDs contain no
/// activity content, and old entries are harmlessly evicted.
enum TimerCompletionAlertAcknowledgementStore {
    static let defaultsKey = "timer.completion-alert.acknowledged.v1"
    private static let maximumCount = 16

    static func contains(
        sessionID: UUID,
        defaults: UserDefaults = .standard
    ) -> Bool {
        acknowledgedIDs(defaults: defaults).contains(
            sessionID.uuidString.lowercased()
        )
    }

    static func mark(
        sessionID: UUID,
        defaults: UserDefaults = .standard
    ) {
        let value = sessionID.uuidString.lowercased()
        var values = acknowledgedIDs(defaults: defaults)
        values.removeAll { $0 == value }
        values.append(value)
        defaults.set(
            Array(values.suffix(maximumCount)),
            forKey: AccountScopedLocalState.defaultsKey(
                base: defaultsKey,
                defaults: defaults
            )
        )
    }

    static func removeAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: AccountScopedLocalState.defaultsKey(
            base: defaultsKey,
            defaults: defaults
        ))
    }

    private static func acknowledgedIDs(defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: AccountScopedLocalState.defaultsKey(
            base: defaultsKey,
            defaults: defaults
        )) ?? []
    }
}

/// Runtime-only sound design for the jar and timer. No third-party or bundled
/// audio samples are used.
@MainActor
final class SoundSynth {
    static let shared = SoundSynth()

    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue, !isEnabled else { return }
            stopEngine(clearRunRequest: true, deactivateSession: true)
        }
    }
    var masterVolume: Float = 1 {
        didSet { masterVolume = min(max(masterVolume, 0), 1) }
    }

    private enum Priority {
        case incidental
        case important
    }

    private final class Voice {
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitVarispeed()
        var busyUntilUptime = -Double.greatestFiniteMagnitude
    }

    private var engine = AVAudioEngine()
    private var timerCompletionPlayer = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var voices: [Voice] = []
    private var isEngineConfigured = false
    private var nextImportantVoice = 0
    private var interruptionObserver: NSObjectProtocol?
    private var configurationObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var resignActiveObserver: NSObjectProtocol?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var lastTickUptime = -Double.greatestFiniteMagnitude
    private var engineRunRequested = false
    private var resumeAfterInterruption = false
    private var isAudioInterrupted = false
    private var isApplicationInactive = true
    private var isSessionActive = false
    private var playbackGeneration: UInt64 = 0
    private var idleShutdownGeneration: UInt64 = 0
    private var latestScheduledClinkUptime = -Double.greatestFiniteMagnitude
    private var timerCompletionBusyUntilUptime = -Double.greatestFiniteMagnitude

    /// Leave a little room for the output render pipeline to consume the final
    /// scheduled frame, then release the audio session. Jar sounds are short
    /// enhancements, so keeping the engine active for the whole foreground
    /// lifetime would waste power without improving later interactions.
    private static let idleShutdownGrace: TimeInterval = 0.120

    private let thuds: [AVAudioPCMBuffer]
    private let tick: AVAudioPCMBuffer
    private let gemClinks: [AVAudioPCMBuffer]
    private let timerCompletionSounds: [TimerCompletionSound: AVAudioPCMBuffer]
    private let gold: AVAudioPCMBuffer
    private let prism: AVAudioPCMBuffer

    private init() {
        format = AVAudioFormat(
            standardFormatWithSampleRate: Constants.Sound.sampleRate,
            channels: 1
        )!
        thuds = Constants.Sound.thudBaseFrequencies.map {
            Self.makeThud(startFrequency: $0)
        }
        tick = Self.makeTick()
        gemClinks = (0 ..< Constants.Sound.gemClinkVariantCount).map {
            Self.makeGemClink(seed: UInt64($0 + 1))
        }
        timerCompletionSounds = Dictionary(uniqueKeysWithValues:
            TimerCompletionSound.allCases.map { style in
                (style, Self.makeTimerCompletionBuffer(for: style))
            }
        )
        gold = Self.makeGold(frequency: Constants.Sound.goldCarrier)
        prism = Self.makePrism()

        isApplicationInactive = UIApplication.shared.applicationState != .active
        observeAudioLifecycle()
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        if let mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(mediaServicesResetObserver)
        }
        if let resignActiveObserver { NotificationCenter.default.removeObserver(resignActiveObserver) }
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
    }

    func prepare() {
        // PCM buffers are generated in `init`, but touching `mainMixerNode`
        // constructs and connects the hardware output node. Keep that graph
        // lazy so merely opening Home cannot fail on an unavailable audio
        // service; the first explicit play request owns activation and setup.
    }

    func playThud(impactSpeed: CGFloat) {
        guard isEnabled, let buffer = thuds.randomElement() else { return }
        let normalized = Constants.Sound.thudMinVolume
            + Float(abs(impactSpeed)) / Float(Constants.Sound.thudVelocityDivisor)
        let volume = min(max(normalized, Constants.Sound.thudMinVolume), 1)
        let variation = Float.random(
            in: -Float(Constants.Sound.thudPitchVariation) ... Float(Constants.Sound.thudPitchVariation)
        )
        play(
            buffer,
            volume: volume,
            pitchRate: 1 + variation,
            priority: .important
        )
    }

    func playTick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard isEnabled,
              now - lastTickUptime >= Constants.Sound.secondaryCollisionCooldown else { return }
        lastTickUptime = now
        play(
            tick,
            volume: Float(Constants.Sound.tickVolume),
            priority: .incidental
        )
    }

    func playClinks(_ events: [JarClinkEvent], userInitiated: Bool) {
        guard isEnabled, !events.isEmpty, !gemClinks.isEmpty else { return }
        let generation = playbackGeneration
        let schedulingUptime = ProcessInfo.processInfo.systemUptime
        for (index, event) in events.enumerated() {
            guard event.delay.isFinite else { continue }
            let safeDelay = max(event.delay, 0)
            let playEvent = { [weak self] in
                guard let self,
                      self.isEnabled,
                      self.playbackGeneration == generation,
                      !self.gemClinks.isEmpty
                else { return }
                let variant = event.variant.clamped(to: 0 ... self.gemClinks.count - 1)
                self.play(
                    self.gemClinks[variant],
                    volume: event.gain,
                    pitchRate: event.pitchRate,
                    priority: userInitiated && index == 0 ? .important : .incidental
                )
            }
            if safeDelay <= 0 {
                playEvent()
            } else {
                latestScheduledClinkUptime = max(
                    latestScheduledClinkUptime,
                    schedulingUptime + safeDelay
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + safeDelay) {
                    playEvent()
                }
            }
        }
    }

    func playCompletionChime() {
        guard let buffer = timerCompletionSounds[.standard] else { return }
        // Reward/Jar chimes use the ordinary voice pool. The dedicated timer
        // player is reserved for the repeat-until-acknowledged alert so the
        // Stop button cannot cut off an unrelated achievement sound.
        play(buffer, volume: 1, priority: .important)
    }

    func playTimerCompletion(_ style: TimerCompletionSound) {
        guard isEnabled, let buffer = timerCompletionSounds[style] else { return }
        requestEngineStart()
        guard isEngineConfigured, engine.isRunning else { return }

        timerCompletionPlayer.stop()
        timerCompletionPlayer.volume = masterVolume
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        timerCompletionBusyUntilUptime = ProcessInfo.processInfo.systemUptime
            + duration
        timerCompletionPlayer.scheduleBuffer(buffer, at: nil, options: .interrupts)
        timerCompletionPlayer.play()
        scheduleIdleShutdown(after: duration)
    }

    /// Stops an in-app completion cue without mutating the person's sound
    /// preference or interrupting a gem/drop sound that happens to overlap it.
    func stopTimerCompletion() {
        timerCompletionPlayer.stop()
        timerCompletionBusyUntilUptime = -Double.greatestFiniteMagnitude
        scheduleIdleShutdown(after: 0)
    }

    /// Shared deterministic source for foreground playback and the short CAF
    /// copied into Library/Sounds for notifications delivered while suspended.
    static func makeTimerCompletionBuffer(
        for style: TimerCompletionSound
    ) -> AVAudioPCMBuffer {
        switch style {
        case .standard:
            makeChime()
        case .soft:
            makeTimerTone(
                notes: [
                    (frequency: 523.25, start: 0, duration: 0.28),
                    (frequency: 659.25, start: 0.16, duration: 0.34)
                ],
                gain: 0.50,
                timbre: .soft
            )
        case .bright:
            makeTimerTone(
                notes: [
                    (frequency: 880.00, start: 0, duration: 0.16),
                    (frequency: 1_108.73, start: 0.09, duration: 0.18),
                    (frequency: 1_318.51, start: 0.18, duration: 0.24)
                ],
                gain: 0.38,
                timbre: .bright
            )
        }
    }

    func playGold() {
        guard isEnabled else { return }
        play(
            gold,
            volume: Float(Constants.Sound.goldVolume),
            priority: .important
        )
    }

    func playPrism() {
        guard isEnabled else { return }
        play(
            prism,
            volume: Float(Constants.Sound.goldVolume),
            priority: .important
        )
    }

    private func play(
        _ buffer: AVAudioPCMBuffer,
        volume: Float,
        pitchRate: Float = 1,
        priority: Priority
    ) {
        guard isEnabled else { return }
        requestEngineStart()
        guard isEngineConfigured, engine.isRunning, !voices.isEmpty else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let voice: Voice
        if let idle = voices.first(where: { $0.busyUntilUptime <= now }) {
            voice = idle
        } else {
            guard priority == .important else { return }
            voice = voices[nextImportantVoice % voices.count]
            nextImportantVoice = (nextImportantVoice + 1) % voices.count
            voice.player.stop()
        }

        voice.pitch.rate = min(max(pitchRate, 0.25), 4)
        voice.player.volume = min(max(volume * masterVolume, 0), 1)
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
            / Double(voice.pitch.rate)
        voice.busyUntilUptime = now + duration
        voice.player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        voice.player.play()
        scheduleIdleShutdown(after: duration)
    }

    private func configureSession() {
        guard audioOutputIsAllowed else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, mode: .default, options: [])
            try session.setPreferredSampleRate(Constants.Sound.sampleRate)
        } catch {
            // Sound is enhancement-only; physics, haptics and persistence must remain usable.
        }
    }

    private func configureEngine() {
        guard !isEngineConfigured else { return }
        engine.attach(timerCompletionPlayer)
        engine.connect(
            timerCompletionPlayer,
            to: engine.mainMixerNode,
            format: format
        )
        for _ in 0..<Constants.Sound.maxVoices {
            let voice = Voice()
            engine.attach(voice.player)
            engine.attach(voice.pitch)
            engine.connect(voice.player, to: voice.pitch, format: format)
            engine.connect(voice.pitch, to: engine.mainMixerNode, format: format)
            voices.append(voice)
        }
        engine.mainMixerNode.outputVolume = 1
        engine.prepare()
        isEngineConfigured = true
    }

    private func requestEngineStart() {
        guard audioOutputIsAllowed,
              isEnabled,
              !isAudioInterrupted,
              !isApplicationInactive else {
            // Enhancement requests that arrive while inactive/interrupted are
            // dropped, not queued for an unsolicited sound or engine start.
            engineRunRequested = false
            return
        }
        engineRunRequested = true
        startEngineIfNeeded()
    }

    private func startEngineIfNeeded() {
        guard audioOutputIsAllowed,
              isEnabled,
              engineRunRequested,
              !isAudioInterrupted,
              !isApplicationInactive,
              (!isEngineConfigured || !engine.isRunning)
        else { return }
        let session = AVAudioSession.sharedInstance()
        var sessionWasActivated = false
        do {
            configureSession()
            try session.setActive(true)
            sessionWasActivated = true
            isSessionActive = true
            configureEngine()
            try engine.start()
        } catch {
            // Activation can succeed before the engine fails. Roll it back so
            // a failed enhancement never leaves the shared audio session live;
            // the next explicit user event retries from a clean boundary.
            engineRunRequested = false
            if sessionWasActivated {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                isSessionActive = false
            }
        }
    }

    private func stopEngine(clearRunRequest: Bool, deactivateSession: Bool) {
        playbackGeneration &+= 1
        idleShutdownGeneration &+= 1
        latestScheduledClinkUptime = -Double.greatestFiniteMagnitude
        if clearRunRequest {
            engineRunRequested = false
        }
        for voice in voices {
            voice.player.stop()
            voice.busyUntilUptime = -Double.greatestFiniteMagnitude
        }
        timerCompletionPlayer.stop()
        timerCompletionBusyUntilUptime = -Double.greatestFiniteMagnitude
        if isEngineConfigured, engine.isRunning {
            engine.stop()
        }
        guard deactivateSession, isSessionActive else { return }
        isSessionActive = false
        guard audioOutputIsAllowed else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            // An interruption may already own/deactivate the shared session.
        }
    }

    private func scheduleIdleShutdown(after playbackDuration: TimeInterval) {
        guard playbackDuration.isFinite else { return }
        idleShutdownGeneration &+= 1
        let generation = idleShutdownGeneration
        scheduleIdleShutdownCheck(
            generation: generation,
            after: max(playbackDuration, 0) + Self.idleShutdownGrace
        )
    }

    private func scheduleIdleShutdownCheck(
        generation: UInt64,
        after delay: TimeInterval
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0)) { [weak self] in
            guard let self,
                  self.idleShutdownGeneration == generation,
                  self.engineRunRequested
            else { return }

            let now = ProcessInfo.processInfo.systemUptime
            let remainingPlayback = self.voices.reduce(0.0) { remaining, voice in
                max(remaining, voice.busyUntilUptime - now)
            }
            let remainingScheduledClinks = self.latestScheduledClinkUptime - now
            let remainingActivity = max(
                remainingPlayback,
                remainingScheduledClinks,
                self.timerCompletionBusyUntilUptime - now
            )
            if remainingActivity > 0 {
                self.scheduleIdleShutdownCheck(
                    generation: generation,
                    after: remainingActivity + Self.idleShutdownGrace
                )
                return
            }
            self.stopEngine(clearRunRequest: true, deactivateSession: true)
        }
    }

    private func rebuildAfterMediaServicesReset() {
        // Apple's media-server reset contract invalidates engines, players and
        // audio units. Cancel queued clinks and replace those objects, but do
        // not activate or replay anything until the next explicit user action.
        playbackGeneration &+= 1
        idleShutdownGeneration &+= 1
        latestScheduledClinkUptime = -Double.greatestFiniteMagnitude
        engineRunRequested = false
        resumeAfterInterruption = false
        isAudioInterrupted = false
        isSessionActive = false
        isApplicationInactive = UIApplication.shared.applicationState != .active
        for voice in voices {
            voice.player.stop()
        }
        timerCompletionPlayer.stop()
        if isEngineConfigured, engine.isRunning {
            engine.stop()
        }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        voices.removeAll(keepingCapacity: false)
        timerCompletionPlayer = AVAudioPlayerNode()
        timerCompletionBusyUntilUptime = -Double.greatestFiniteMagnitude
        nextImportantVoice = 0
        lastTickUptime = -Double.greatestFiniteMagnitude
        engine = AVAudioEngine()
        isEngineConfigured = false
        observeEngineConfigurationChanges()
    }

    private func observeAudioLifecycle() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { [weak self] in
                guard let self,
                      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw)
                else { return }
                switch type {
                case .began:
                    self.isAudioInterrupted = true
                    self.isSessionActive = false
                    self.resumeAfterInterruption = self.engineRunRequested
                        && self.isEngineConfigured
                        && self.engine.isRunning
                    self.stopEngine(clearRunRequest: false, deactivateSession: false)
                case .ended:
                    self.isAudioInterrupted = false
                    let optionRaw = notification.userInfo?[
                        AVAudioSessionInterruptionOptionKey
                    ] as? UInt ?? 0
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionRaw)
                    let shouldResume = self.resumeAfterInterruption
                        && options.contains(.shouldResume)
                        && self.isEnabled
                        && !self.isApplicationInactive
                    self.resumeAfterInterruption = false
                    guard shouldResume else {
                        self.engineRunRequested = false
                        return
                    }
                    self.startEngineIfNeeded()
                    if self.isEngineConfigured, self.engine.isRunning {
                        // Stopped voices aren't replayed after an interruption;
                        // release the otherwise empty resumed engine promptly.
                        self.scheduleIdleShutdown(after: 0)
                    }
                @unknown default:
                    self.resumeAfterInterruption = false
                    self.engineRunRequested = false
                }
            }
        }
        observeEngineConfigurationChanges()
        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.rebuildAfterMediaServicesReset()
            }
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                self.isApplicationInactive = true
                self.resumeAfterInterruption = false
                self.stopEngine(clearRunRequest: true, deactivateSession: true)
            }
        }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                // Becoming active alone never activates audio. The next
                // explicit play request does so on demand.
                self?.isApplicationInactive = false
            }
        }
    }

    private func observeEngineConfigurationChanges() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self,
                      self.engineRunRequested,
                      self.isEnabled,
                      !self.isAudioInterrupted,
                      !self.isApplicationInactive
                else { return }
                self.startEngineIfNeeded()
            }
        }
    }

    private var audioOutputIsAllowed: Bool {
#if DEBUG && targetEnvironment(simulator)
        // UI automation validates state and accessibility, not acoustic output.
        // Avoid coupling deterministic tests to the host Mac's CoreAudio RPC.
        return !LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess
#else
        return true
#endif
    }
}

private extension SoundSynth {
    enum TimerToneTimbre {
        case soft
        case bright
    }

    static func makeBuffer(
        duration: TimeInterval,
        sample: (_ time: Double, _ progress: Double) -> Float
    ) -> AVAudioPCMBuffer {
        let sampleRate = Constants.Sound.sampleRate
        let frameCount = AVAudioFrameCount((duration * sampleRate).rounded(.up))
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        guard let channel = buffer.floatChannelData?[0] else { return buffer }

        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            let progress = min(max(time / max(duration, .leastNonzeroMagnitude), 0), 1)
            channel[frame] = min(max(sample(time, progress), -1), 1)
        }
        return buffer
    }

    static func makeThud(startFrequency: Double) -> AVAudioPCMBuffer {
        var brown = Double.zero
        var lowPassed = Double.zero
        let cutoff = Constants.Sound.thudNoiseLowPass
        let dt = 1 / Constants.Sound.sampleRate
        let rc = 1 / (2 * Double.pi * cutoff)
        let lowPassAlpha = dt / (rc + dt)

        return makeBuffer(duration: Constants.Sound.thudDuration) { time, progress in
            let frequencyRatio = Constants.Sound.thudEndFrequency / startFrequency
            let logarithmicRatio = log(frequencyRatio)
            let phase = 2 * Double.pi * startFrequency * Constants.Sound.thudDuration
                / logarithmicRatio * (pow(frequencyRatio, progress) - 1)
            let envelope = exp(-time / Constants.Sound.thudDecay) * (1 - progress)

            let white = Double.random(in: -1 ... 1)
            brown = min(max(brown + white * Constants.Sound.brownNoiseStep, -1), 1)
            lowPassed += lowPassAlpha * (brown - lowPassed)
            let noiseEnvelope = time < Constants.Sound.thudNoiseDuration
                ? 1 - time / Constants.Sound.thudNoiseDuration
                : 0
            let noise = lowPassed * noiseEnvelope * Constants.Sound.brownNoiseMix
            return Float(sin(phase) * envelope + noise)
        }
    }

    static func makeTick() -> AVAudioPCMBuffer {
        makeBuffer(duration: Constants.Sound.tickDuration) { time, progress in
            let wave = sin(2 * Double.pi * Constants.Sound.tickFrequency * time)
            let envelope = exp(-progress * Constants.Sound.tickDecayRate) * (1 - progress)
            return Float(wave * envelope)
        }
    }

    /// A deterministic struck-gem model: inharmonic modes provide the glassy
    /// body and a 2.5 ms seeded strike adds enough variation that a cluster
    /// reads as multiple stones. It is generated directly into PCM and has no
    /// source recording, stock sample, AHAP file, or network dependency.
    static func makeGemClink(seed: UInt64) -> AVAudioPCMBuffer {
        var noiseState = seed &+ 0x9E37_79B9_7F4A_7C15
        let ratios = Constants.Sound.gemClinkModalRatios
        let amplitudes = Constants.Sound.gemClinkModalAmplitudes
        let variantOffset = (Double(seed % 7) - 3) * 0.004

        return makeBuffer(duration: Constants.Sound.gemClinkDuration) { time, progress in
            let attack = min(time / 0.0015, 1)
            let release = max(1 - progress, 0)
            var resonances = 0.0
            for index in ratios.indices {
                guard amplitudes.indices.contains(index) else { continue }
                let frequency = Constants.Sound.gemClinkBaseFrequency
                    * ratios[index] * (1 + variantOffset * Double(index + 1))
                let decay = 0.052 / (1 + Double(index) * 0.52)
                resonances += amplitudes[index]
                    * exp(-time / decay)
                    * sin(2 * Double.pi * frequency * time + Double(index) * 0.37)
            }

            noiseState = noiseState &* 6_364_136_223_846_793_005 &+ 1
            let unitNoise = Double((noiseState >> 40) & 0xFF_FFFF)
                / Double(0xFF_FFFF) * 2 - 1
            let strikeEnvelope = time < Constants.Sound.gemClinkStrikeNoiseDuration
                ? 1 - time / Constants.Sound.gemClinkStrikeNoiseDuration
                : 0
            let signal = attack * release * resonances * 0.46
                + unitNoise * strikeEnvelope * 0.15
            return Float(tanh(signal) * 0.78)
        }
    }

    static func makeChime() -> AVAudioPCMBuffer {
        let secondStart = Constants.Sound.chimeGap
        let duration = max(
            Constants.Sound.chimeFirstDuration,
            secondStart + Constants.Sound.chimeSecondDuration
        )
        return makeBuffer(duration: duration) { time, _ in
            var value = Double.zero
            if time < Constants.Sound.chimeFirstDuration {
                value += triangle(frequency: Constants.Sound.chimeE5, time: time)
                    * noteEnvelope(time: time, duration: Constants.Sound.chimeFirstDuration)
            }
            if time >= secondStart {
                let localTime = time - secondStart
                value += triangle(frequency: Constants.Sound.chimeA5, time: localTime)
                    * noteEnvelope(time: localTime, duration: Constants.Sound.chimeSecondDuration)
            }
            return Float(value * Constants.Sound.chimeGain)
        }
    }

    static func makeTimerTone(
        notes: [(frequency: Double, start: TimeInterval, duration: TimeInterval)],
        gain: Double,
        timbre: TimerToneTimbre
    ) -> AVAudioPCMBuffer {
        let duration = notes.map { $0.start + $0.duration }.max() ?? 0.25
        return makeBuffer(duration: duration) { time, _ in
            var value = Double.zero
            for note in notes where time >= note.start {
                let localTime = time - note.start
                guard localTime <= note.duration else { continue }
                let progress = localTime / note.duration
                let attack = min(localTime / 0.008, 1)
                let release = pow(max(1 - progress, 0), timbre == .soft ? 1.8 : 2.7)
                let phase = 2 * Double.pi * note.frequency * localTime
                let wave: Double
                switch timbre {
                case .soft:
                    wave = sin(phase) + 0.16 * sin(phase * 2)
                case .bright:
                    wave = triangle(frequency: note.frequency, time: localTime)
                        + 0.12 * sin(phase * 3)
                }
                value += wave * attack * release
            }
            return Float(tanh(value * gain))
        }
    }

    static func makeGold(frequency: Double) -> AVAudioPCMBuffer {
        makeBuffer(duration: Constants.Sound.goldModulationDuration) { time, progress in
            let modulationFrequency = frequency * Constants.Sound.goldRatio
            let index = Constants.Sound.goldModulationIndex * (1 - progress)
            let phase = 2 * Double.pi * frequency * time
                + index * sin(2 * Double.pi * modulationFrequency * time)
            let envelope = pow(1 - progress, 2)
            return Float(sin(phase) * envelope)
        }
    }

    static func makePrism() -> AVAudioPCMBuffer {
        let frequencies = Constants.Sound.prismFrequencies
        let lastStart = Double(max(frequencies.count - 1, 0))
            * Constants.Sound.prismArpeggioInterval
        let duration = lastStart + Constants.Sound.goldModulationDuration
        return makeBuffer(duration: duration) { time, _ in
            guard !frequencies.isEmpty else { return .zero }
            var sum = Double.zero
            for (index, frequency) in frequencies.enumerated() {
                let start = Double(index) * Constants.Sound.prismArpeggioInterval
                guard time >= start else { continue }
                let localTime = time - start
                guard localTime <= Constants.Sound.goldModulationDuration else { continue }
                let progress = localTime / Constants.Sound.goldModulationDuration
                let modulationFrequency = frequency * Constants.Sound.goldRatio
                let modulation = Constants.Sound.goldModulationIndex * (1 - progress)
                let phase = 2 * Double.pi * frequency * localTime
                    + modulation * sin(2 * Double.pi * modulationFrequency * localTime)
                sum += sin(phase) * pow(1 - progress, 2)
            }
            return Float(sum / sqrt(Double(frequencies.count)))
        }
    }

    static func triangle(frequency: Double, time: Double) -> Double {
        2 / Double.pi * asin(sin(2 * Double.pi * frequency * time))
    }

    static func noteEnvelope(time: Double, duration: TimeInterval) -> Double {
        guard time >= .zero, time <= duration else { return .zero }
        let attack = min(time / Constants.Sound.attack, 1)
        let decayTime = max(time - Constants.Sound.attack, 0)
        let decay = exp(-decayTime / Constants.Sound.decay)
        let release = max(1 - time / duration, 0)
        return attack * decay * release
    }
}

/// Notification Center can only play files already present in the app bundle
/// or Library/Sounds. We derive these tiny files from the same math as the
/// foreground synthesizer, so the selected cue remains consistent without
/// adding licensed recordings to the repository.
@MainActor
enum TimerCompletionSoundLibrary {
    private static let fileVersion = 1

    static func notificationSound(
        for style: TimerCompletionSound
    ) -> UNNotificationSound {
        do {
            let url = try ensureSoundFile(for: style)
            return UNNotificationSound(
                named: UNNotificationSoundName(rawValue: url.lastPathComponent)
            )
        } catch {
            return .default
        }
    }

    @discardableResult
    static func ensureSoundFile(
        for style: TimerCompletionSound,
        libraryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let library = try libraryDirectory ?? fileManager.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let soundsDirectory = library.appendingPathComponent(
            "Sounds",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: soundsDirectory,
            withIntermediateDirectories: true
        )

        let fileName = "tumiben-timer-\(style.rawValue)-v\(fileVersion).caf"
        let destination = soundsDirectory.appendingPathComponent(fileName)
        if let attributes = try? fileManager.attributesOfItem(
            atPath: destination.path
        ), let size = attributes[.size] as? NSNumber, size.intValue > 64 {
            return destination
        }

        let temporary = soundsDirectory.appendingPathComponent(
            ".\(fileName).writing"
        )
        if fileManager.fileExists(atPath: temporary.path) {
            try fileManager.removeItem(at: temporary)
        }

        do {
            try write(
                SoundSynth.makeTimerCompletionBuffer(for: style),
                to: temporary
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static func write(
        _ buffer: AVAudioPCMBuffer,
        to url: URL
    ) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }
}
