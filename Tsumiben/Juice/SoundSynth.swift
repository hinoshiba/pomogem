import AVFoundation

/// Runtime-only sound design for the jar. No bundled audio files are used.
@MainActor
final class SoundSynth {
    static let shared = SoundSynth()

    var isEnabled = true
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

    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private var voices: [Voice] = []
    private var nextImportantVoice = 0
    private var interruptionObserver: NSObjectProtocol?
    private var configurationObserver: NSObjectProtocol?
    private var lastTickUptime = -Double.greatestFiniteMagnitude

    private let thuds: [AVAudioPCMBuffer]
    private let tick: AVAudioPCMBuffer
    private let chime: AVAudioPCMBuffer
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
        chime = Self.makeChime()
        gold = Self.makeGold(frequency: Constants.Sound.goldCarrier)
        prism = Self.makePrism()

        configureSession()
        configureEngine()
        observeAudioLifecycle()
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    func prepare() {
        guard isEnabled else { return }
        startEngineIfNeeded()
        voices.forEach { $0.player.prepare(withFrameCount: AVAudioFrameCount(format.sampleRate)) }
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

    func playCompletionChime() {
        guard isEnabled else { return }
        play(chime, volume: 1, priority: .important)
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
        startEngineIfNeeded()
        guard engine.isRunning, !voices.isEmpty else { return }

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
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setPreferredSampleRate(Constants.Sound.sampleRate)
            try session.setActive(true)
        } catch {
            // Sound is enhancement-only; physics, haptics and persistence must remain usable.
        }
    }

    private func configureEngine() {
        guard voices.isEmpty else { return }
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
        startEngineIfNeeded()
    }

    private func startEngineIfNeeded() {
        guard isEnabled, !engine.isRunning else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        } catch {
            // The next user event retries. Silent mode and audio interruptions never block a drop.
        }
    }

    private func observeAudioLifecycle() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self,
                      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw),
                      type == .ended else { return }
                self.startEngineIfNeeded()
            }
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.startEngineIfNeeded() }
        }
    }
}

private extension SoundSynth {
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
