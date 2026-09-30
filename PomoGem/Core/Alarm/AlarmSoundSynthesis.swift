import Accelerate
import Foundation

/// The five alarm-grade timer sounds that are synthesized here, from source
/// code only. Raw values name the device-local `alarm.sound` choice, so keep
/// them stable.
enum AlarmSynthesizedSound: String, CaseIterable, Sendable {
    /// A small struck bell (two-operator FM with an inharmonic ratio),
    /// struck three times.
    case bell
    /// The classic four-beep digital alarm clock.
    case digital
    /// A rising marimba arpeggio, played twice.
    case marimba
    /// The Westminster Quarters as Japanese schools play them, in a chime
    /// timbre. The melody (1793) is in the public domain.
    case schoolChime
    /// A mechanical twin-bell alarm clock: a hammer alternating between two
    /// small bells about 25 times a second.
    case alarmClock
}

/// One alarm pattern before mastering: a single cycle rendered linearly with
/// its ringing tail, and the period after which the next cycle starts.
struct AlarmSoundSource: Equatable, Sendable {
    /// Mono samples at `AlarmSoundSynthesis.sampleRate`, one cycle plus tail.
    let oneShot: [Float]
    /// A loop repeats every `period` seconds; the tail rings into the next cycle.
    let period: TimeInterval
    /// How far transients are pushed into the limiter, in dB. Gentle by
    /// design (0–6 dB): enough to lift the body of a struck sound without
    /// audibly squashing it.
    let limiterDrive: Float
}

/// Deterministic, dependency-free synthesis and mastering for the alarm
/// sounds. No recording, sample library, AHAP file or generated-audio service
/// is involved: every sound is plain arithmetic in this file, so it is
/// original work under the project's MIT license (Docs/LICENSE_AUDIT.md) and
/// no audio file ever enters the repository.
///
/// Loudness: phone speakers reproduce roughly 800 Hz–3 kHz loudly and little
/// below 500 Hz, so every fundamental sits at or above G5 (784 Hz). Each
/// rendering is limited gently and peak-normalised to about −1 dBFS.
/// The functions are nonisolated and pure, so callers may render off the main
/// actor.
enum AlarmSoundSynthesis {
    static let sampleRate = 44_100.0
    /// −1 dBFS.
    static let targetPeak: Float = 0.891_250_9
    /// Notification sounds must stay under 30 s or iOS plays the default
    /// sound instead; AlarmKit is documented against the same envelope.
    static let ringtoneMaximumDuration: TimeInterval = 28
    /// The short breath between cycles of the long ringtone.
    static let ringtoneGap: TimeInterval = 0.35
    /// Ringing longer than this after a cycle is faded out of the one-shot.
    static let tailDuration: TimeInterval = 2.0
    static let tailFade: TimeInterval = 0.25
    static let edgeFade: TimeInterval = 0.03

    // MARK: Public rendering

    static func source(for sound: AlarmSynthesizedSound) -> AlarmSoundSource {
        switch sound {
        case .bell: bell()
        case .digital: digital()
        case .marimba: marimba()
        case .schoolChime: schoolChime()
        case .alarmClock: alarmClock()
        }
    }

    /// Turns one of the three legacy completion chimes into a pattern: the
    /// chime twice, then a pause, in its original timbre. Only the level
    /// changes (peak-normalised, no limiting).
    static func legacySource(chime: [Float]) -> AlarmSoundSource {
        let chimeDuration = Double(chime.count) / sampleRate
        let repeatOffset = chimeDuration + 0.12
        let period = max(1.5, 2 * repeatOffset + 0.45)
        var buffer = [Float](repeating: 0, count: frames(period + 0.05))
        mix(chime, into: &buffer, at: 0)
        mix(chime, into: &buffer, at: frames(repeatOffset))
        return AlarmSoundSource(oneShot: buffer, period: period, limiterDrive: 0)
    }

    /// One seamless cycle for foreground looping (`AVAudioPlayerNode` with
    /// `.loops`): `fold`, mastered as one period of a loop, so the loop
    /// point needs no fade and never clicks.
    static func loop(_ source: AlarmSoundSource) -> [Float] {
        master(fold(source), driveDecibels: source.limiterDrive, circular: true)
    }

    /// One period of the pattern in its steady state, unmastered: the tail
    /// of each cycle is folded into the start of the next, exactly as when
    /// the cycles are laid end to end.
    static func fold(_ source: AlarmSoundSource) -> [Float] {
        let length = max(frames(source.period), 1)
        var folded = [Float](repeating: 0, count: length)
        var start = 0
        while start < source.oneShot.count {
            mix(Array(source.oneShot[start..<min(start + length, source.oneShot.count)]), into: &folded, at: 0)
            start += length
        }
        return folded
    }

    /// The long sound for Library/Sounds (notifications and AlarmKit): the
    /// cycle repeated with a short gap for as long as fits in
    /// `ringtoneMaximumDuration`, ending on the last cycle's natural decay.
    static func ringtone(_ source: AlarmSoundSource) -> [Float] {
        let stride = source.period + ringtoneGap
        let available = ringtoneMaximumDuration
            - Double(source.oneShot.count) / sampleRate
        let repetitions = max(1, Int((available / stride).rounded(.down)) + 1)
        let length = min(
            frames(Double(repetitions - 1) * stride) + source.oneShot.count,
            frames(ringtoneMaximumDuration)
        )
        var buffer = [Float](repeating: 0, count: length)
        for repetition in 0..<repetitions {
            mix(source.oneShot, into: &buffer, at: frames(Double(repetition) * stride))
        }
        var mastered = master(buffer, driveDecibels: source.limiterDrive, circular: false)
        fadeEdges(&mastered)
        return mastered
    }

    /// A single cycle with its natural decay, for the Settings preview. The
    /// silence after the decay is trimmed so the preview ends when it
    /// stops being audible.
    static func preview(_ source: AlarmSoundSource) -> [Float] {
        var mastered = master(source.oneShot, driveDecibels: source.limiterDrive, circular: false)
        let audibleThreshold: Float = 0.001 // −60 dBFS
        if let lastAudible = mastered.lastIndex(where: { abs($0) > audibleThreshold }) {
            let end = min(mastered.count, lastAudible + 1 + frames(edgeFade))
            mastered.removeSubrange(end...)
        }
        fadeEdges(&mastered)
        return mastered
    }

    // MARK: Mastering

    /// Gentle look-ahead peak limiting followed by peak normalisation to
    /// `targetPeak`. The input is first normalised to a unit peak, so
    /// `driveDecibels` states how far the loudest transient is pushed into
    /// the limiter. With `circular`, the signal is treated as one period of a
    /// loop, so the gain at the loop point matches its steady state.
    static func master(
        _ input: [Float],
        driveDecibels: Float,
        circular: Bool
    ) -> [Float] {
        guard !input.isEmpty else { return input }
        let inputPeak = peak(of: input)
        guard inputPeak > 0, inputPeak.isFinite else {
            return [Float](repeating: 0, count: input.count)
        }
        let gain = pow(10, max(driveDecibels, 0) / 20) / inputPeak
        let count = input.count
        let scaled = vDSP.multiply(gain, input)
        let working = circular ? scaled + scaled + scaled : scaled
        let limited = limit(working, ceiling: 1)
        let body = circular ? Array(limited[count..<(2 * count)]) : limited
        let limitedPeak = peak(of: body)
        guard limitedPeak > 0 else { return body }
        return vDSP.multiply(targetPeak / limitedPeak, body)
    }

    /// A look-ahead limiter: the gain needed at every sample is the minimum
    /// over ±`lookAhead`, smoothed with a moving average no wider than that
    /// window (so it still reaches the required gain at each peak) and
    /// allowed to recover only exponentially. Nothing is clipped.
    static func limit(
        _ signal: [Float],
        ceiling: Float,
        lookAhead: TimeInterval = 0.0015,
        release: TimeInterval = 0.080
    ) -> [Float] {
        let count = signal.count
        guard count > 0 else { return signal }
        let window = max(1, frames(lookAhead))
        var required = [Float](repeating: 1, count: count)
        signal.withUnsafeBufferPointer { input in
            required.withUnsafeMutableBufferPointer { gains in
                for index in 0..<count {
                    let magnitude = abs(input[index])
                    if magnitude > ceiling { gains[index] = ceiling / magnitude }
                }
            }
        }
        let held = slidingMinimum(required, radius: window)
        // Moving average of width `window` (radius window/2): every sample in
        // it lies within `window` of the centre, so the average never exceeds
        // the requirement at the centre.
        let halfWidth = max(window / 2, 0)
        let recovery = Float(1 - exp(-1 / (release * sampleRate)))
        var output = [Float](repeating: 0, count: count)
        var prefix = [Double](repeating: 0, count: count + 1)
        held.withUnsafeBufferPointer { held in
            prefix.withUnsafeMutableBufferPointer { prefix in
                for index in 0..<count {
                    prefix[index + 1] = prefix[index] + Double(held[index])
                }
            }
        }
        prefix.withUnsafeBufferPointer { prefix in
            signal.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { output in
                    var previous: Float = 1
                    for index in 0..<count {
                        let lower = max(0, index - halfWidth)
                        let upper = min(count - 1, index + halfWidth)
                        let average = Float(
                            (prefix[upper + 1] - prefix[lower]) / Double(upper - lower + 1)
                        )
                        let smoothed = min(average, previous + (1 - previous) * recovery)
                        previous = smoothed
                        output[index] = input[index] * smoothed
                    }
                }
            }
        }
        return output
    }

    // MARK: Sounds

    /// Three strikes of a small bell. Voice A is the bell: Chowning's FM bell
    /// with an inharmonic 1:1.76 ratio instead of 1:1.4, so the first
    /// sidebands of a 1,083 Hz carrier land at about 820 Hz and 3 kHz, inside
    /// the speaker band, and an index decaying from 2.4 lets the clang of the
    /// strike settle into a clear tone. Voice B, an octave up, is the short
    /// metallic shimmer of the strike.
    static func bell() -> AlarmSoundSource {
        let period = 2.0
        var buffer = makeBuffer(period: period)
        let strikes: [(time: Double, amplitude: Double)] = [
            (0.00, 1.00), (0.34, 0.90), (0.68, 1.00)
        ]
        for strike in strikes {
            addFMStrike(
                into: &buffer,
                start: strike.time,
                amplitude: strike.amplitude,
                carrier: 1_083,
                ratio: 1.76,
                peakIndex: 2.4,
                indexDecay: 0.12,
                residualIndex: 0.30,
                decay: 0.60
            )
            addFMStrike(
                into: &buffer,
                start: strike.time,
                amplitude: strike.amplitude * 0.16,
                carrier: 2_166,
                ratio: 1.76,
                peakIndex: 1.2,
                indexDecay: 0.06,
                residualIndex: 0,
                decay: 0.14
            )
        }
        fadeTail(&buffer, period: period)
        return AlarmSoundSource(oneShot: buffer, period: period, limiterDrive: 5)
    }

    /// Four short beeps at 2,048 Hz (the classic piezo pitch), twice per
    /// loop. A soft square (odd harmonics 1, 3, 5) keeps the edge of the
    /// original without shrill energy above the speaker's sweet spot.
    static func digital() -> AlarmSoundSource {
        let period = 2.0
        var buffer = makeBuffer(period: period)
        let frequency = 2_048.0
        let beepDuration = 0.085
        let ramp = 0.004
        for group in [0.0, 1.0] {
            for beep in 0..<4 {
                let start = group + Double(beep) * 0.14
                let first = frames(start)
                let length = frames(beepDuration)
                for offset in 0..<length where first + offset < buffer.count {
                    let time = Double(offset) / sampleRate
                    let envelope = raisedRamp(time, ramp)
                        * raisedRamp(beepDuration - time, ramp)
                    let phase = 2 * Double.pi * frequency * time
                    let wave = sin(phase) + 0.28 * sin(3 * phase) + 0.10 * sin(5 * phase)
                    buffer[first + offset] += Float(envelope * wave)
                }
            }
        }
        fadeTail(&buffer, period: period)
        return AlarmSoundSource(oneShot: buffer, period: period, limiterDrive: 2)
    }

    /// C6–E6–G6–C7 rising, twice. Marimba bars are tuned so the first
    /// overtone is about four times the fundamental; higher bars ring shorter.
    static func marimba() -> AlarmSoundSource {
        let period = 1.8
        var buffer = makeBuffer(period: period)
        let arpeggio = [1_046.50, 1_318.51, 1_567.98, 2_093.00]
        for phrase in [0.0, 0.72] {
            for (index, frequency) in arpeggio.enumerated() {
                let decay = 0.42 * pow(1_046.50 / frequency, 0.6)
                addStruckModes(
                    into: &buffer,
                    start: phrase + Double(index) * 0.12,
                    amplitude: index == arpeggio.count - 1 ? 1.0 : 0.86,
                    modes: [
                        Mode(frequency: frequency, amplitude: 1.00, decay: decay),
                        Mode(frequency: frequency * 3.93, amplitude: 0.34, decay: decay * 0.25),
                        Mode(frequency: frequency * 9.20, amplitude: 0.05, decay: decay * 0.10)
                    ],
                    pulseWidth: 0.00025
                )
            }
        }
        fadeTail(&buffer, period: period)
        return AlarmSoundSource(oneShot: buffer, period: period, limiterDrive: 5)
    }

    /// ミ・ド・レ・ソ／ソ・レ・ミ・ド: the Westminster Quarters as heard in
    /// Japanese schools, raised an octave into the speaker's range. A
    /// slightly detuned second fundamental gives the slow shimmer of a real
    /// chime; 2.76× is the inharmonic tubular-bell partial.
    static func schoolChime() -> AlarmSoundSource {
        let period = 4.0
        var buffer = makeBuffer(period: period)
        let e6 = 1_318.51, c6 = 1_046.50, d6 = 1_174.66, g5 = 783.99
        let melody: [(time: Double, frequency: Double, amplitude: Double)] = [
            (0.00, e6, 1.00), (0.45, c6, 0.90), (0.90, d6, 0.90), (1.35, g5, 1.00),
            (2.00, g5, 1.00), (2.45, d6, 0.90), (2.90, e6, 0.90), (3.35, c6, 1.00)
        ]
        for note in melody {
            let f = note.frequency
            addStruckModes(
                into: &buffer,
                start: note.time,
                amplitude: note.amplitude,
                modes: [
                    Mode(frequency: f, amplitude: 1.00, decay: 1.10),
                    Mode(frequency: f * 1.0035, amplitude: 0.35, decay: 1.10),
                    Mode(frequency: f * 2.00, amplitude: 0.42, decay: 0.55),
                    Mode(frequency: f * 2.76, amplitude: 0.22, decay: 0.32),
                    Mode(frequency: f * 3.00, amplitude: 0.15, decay: 0.30),
                    Mode(frequency: f * 5.40, amplitude: 0.06, decay: 0.12)
                ],
                pulseWidth: 0.0003
            )
        }
        fadeTail(&buffer, period: period)
        return AlarmSoundSource(oneShot: buffer, period: period, limiterDrive: 4)
    }

    /// A 1.5 s burst of a hammer alternating between two small bells at
    /// 25 strikes a second, then a breath. Deterministic jitter in timing
    /// and force, plus a little hammer rattle, keeps it mechanical. The
    /// strikes come every 40 ms, faster than the limiter recovers, so the
    /// full 6 dB drive acts as a steady gain on the burst rather than
    /// pumping: this is the densest, loudest-feeling of the alarm sounds.
    static func alarmClock() -> AlarmSoundSource {
        let period = 2.0
        var buffer = makeBuffer(period: period)
        let strikeRate = 25.0
        let burst = 1.5
        var random = SeededRandom(seed: 0x5EED_A1A2)
        var bellA: [(time: Double, amplitude: Double)] = []
        var bellB: [(time: Double, amplitude: Double)] = []
        var strike = 0
        while Double(strike) / strikeRate < burst {
            let time = max(0, Double(strike) / strikeRate + random.symmetric() * 0.002)
            let amplitude = 0.85 + 0.15 * random.unit()
            if strike.isMultiple(of: 2) {
                bellA.append((time, amplitude))
            } else {
                bellB.append((time, amplitude))
            }
            strike += 1
        }
        addResonantStrikes(
            into: &buffer,
            strikes: bellA,
            modes: [
                Mode(frequency: 1_720, amplitude: 1.00, decay: 0.22),
                Mode(frequency: 3_950, amplitude: 0.50, decay: 0.08),
                Mode(frequency: 5_870, amplitude: 0.24, decay: 0.04)
            ],
            pulseWidth: 0.00012
        )
        addResonantStrikes(
            into: &buffer,
            strikes: bellB,
            modes: [
                Mode(frequency: 2_080, amplitude: 1.00, decay: 0.22),
                Mode(frequency: 4_620, amplitude: 0.48, decay: 0.08),
                Mode(frequency: 7_010, amplitude: 0.22, decay: 0.04)
            ],
            pulseWidth: 0.00012
        )
        // The hammer's rattle: a 3 ms burst of noise on every strike.
        let rattleLength = frames(0.003)
        for hit in bellA + bellB {
            let first = frames(hit.time)
            for offset in 0..<rattleLength where first + offset < buffer.count {
                let fade = 1 - Double(offset) / Double(rattleLength)
                buffer[first + offset] += Float(random.symmetric() * 0.10 * fade * hit.amplitude)
            }
        }
        fadeTail(&buffer, period: period)
        return AlarmSoundSource(oneShot: buffer, period: period, limiterDrive: 6)
    }

    // MARK: Building blocks

    struct Mode {
        let frequency: Double
        let amplitude: Double
        /// Time constant of the exponential decay, in seconds.
        let decay: TimeInterval
    }

    /// Two-operator FM (Chowning 1973): a carrier phase-modulated by a
    /// modulator at `ratio` × the carrier, with an index that decays from
    /// `peakIndex` toward `residualIndex`, under an exponential envelope.
    static func addFMStrike(
        into buffer: inout [Float],
        start: TimeInterval,
        amplitude: Double,
        carrier: Double,
        ratio: Double,
        peakIndex: Double,
        indexDecay: TimeInterval,
        residualIndex: Double,
        decay: TimeInterval
    ) {
        let first = frames(start)
        guard first < buffer.count else { return }
        let length = min(buffer.count - first, frames(decay * log(10_000)))
        let modulator = carrier * ratio
        buffer.withUnsafeMutableBufferPointer { samples in
            for offset in 0..<length {
                let time = Double(offset) / sampleRate
                let index = (peakIndex - residualIndex) * exp(-time / indexDecay)
                    + residualIndex
                let envelope = raisedRamp(time, 0.0015) * exp(-time / decay)
                let phase = 2 * Double.pi * carrier * time
                    + index * sin(2 * Double.pi * modulator * time)
                samples[first + offset] += Float(amplitude * envelope * sin(phase))
            }
        }
    }

    /// One strike exciting a set of modes (a single note).
    static func addStruckModes(
        into buffer: inout [Float],
        start: TimeInterval,
        amplitude: Double,
        modes: [Mode],
        pulseWidth: TimeInterval
    ) {
        addResonantStrikes(
            into: &buffer,
            strikes: [(start, amplitude)],
            modes: modes,
            pulseWidth: pulseWidth
        )
    }

    /// Modal synthesis: a train of unit-area raised-cosine strikes drives
    /// one two-pole resonator per mode. A narrower pulse is a harder hammer
    /// and excites high modes more. Linear, so strikes may overlap freely.
    static func addResonantStrikes(
        into buffer: inout [Float],
        strikes: [(time: Double, amplitude: Double)],
        modes: [Mode],
        pulseWidth: TimeInterval
    ) {
        guard let firstStrike = strikes.map({ $0.time }).min() else { return }
        let first = frames(firstStrike)
        guard first < buffer.count else { return }
        let count = buffer.count
        var excitation = [Double](repeating: 0, count: count)
        let pulseLength = max(2, frames(pulseWidth))
        var pulse = (0..<pulseLength).map { index in
            0.5 * (1 - cos(2 * Double.pi * Double(index) / Double(pulseLength - 1)))
        }
        let area = pulse.reduce(0, +)
        pulse = pulse.map { $0 / area }
        for strike in strikes {
            let position = frames(strike.time)
            for (index, value) in pulse.enumerated() where position + index < count {
                excitation[position + index] += value * strike.amplitude
            }
        }
        excitation.withUnsafeBufferPointer { excitation in
            buffer.withUnsafeMutableBufferPointer { samples in
                for mode in modes {
                    let omega = 2 * Double.pi * mode.frequency / sampleRate
                    guard omega > 0, omega < Double.pi else { continue }
                    let radius = exp(-1 / (mode.decay * sampleRate))
                    let a1 = 2 * radius * cos(omega)
                    let a2 = radius * radius
                    let inputGain = mode.amplitude * sin(omega)
                    var y1 = 0.0
                    var y2 = 0.0
                    for index in first..<count {
                        let y = a1 * y1 - a2 * y2 + inputGain * excitation[index]
                        samples[index] += Float(y)
                        y2 = y1
                        y1 = y
                    }
                }
            }
        }
    }

    // MARK: Utilities

    static func frames(_ seconds: TimeInterval) -> Int {
        max(0, Int((seconds * sampleRate).rounded()))
    }

    static func peak(of samples: [Float]) -> Float {
        samples.isEmpty ? 0 : vDSP.maximumMagnitude(samples)
    }

    private static func makeBuffer(period: TimeInterval) -> [Float] {
        [Float](repeating: 0, count: frames(period + tailDuration))
    }

    /// Fades the end of the tail so truncating it cannot click.
    private static func fadeTail(_ buffer: inout [Float], period: TimeInterval) {
        let length = min(frames(tailFade), buffer.count)
        guard length > 1 else { return }
        let start = buffer.count - length
        for offset in 0..<length {
            let progress = Double(offset) / Double(length - 1)
            buffer[start + offset] *= Float(0.5 * (1 + cos(Double.pi * progress)))
        }
    }

    /// A 30 ms fade at both ends of a linear rendering.
    private static func fadeEdges(_ buffer: inout [Float]) {
        let length = min(frames(edgeFade), buffer.count / 2)
        guard length > 1 else { return }
        for offset in 0..<length {
            let gain = Float(0.5 * (1 - cos(Double.pi * Double(offset) / Double(length - 1))))
            buffer[offset] *= gain
            buffer[buffer.count - 1 - offset] *= gain
        }
    }

    private static func mix(_ source: [Float], into buffer: inout [Float], at start: Int) {
        guard start < buffer.count else { return }
        let length = min(source.count, buffer.count - start)
        source.withUnsafeBufferPointer { source in
            buffer.withUnsafeMutableBufferPointer { buffer in
                for index in 0..<length {
                    buffer[start + index] += source[index]
                }
            }
        }
    }

    /// 0 → 1 over `duration` with a raised-cosine shape.
    private static func raisedRamp(_ time: Double, _ duration: Double) -> Double {
        guard time > 0 else { return 0 }
        guard time < duration else { return 1 }
        return 0.5 * (1 - cos(Double.pi * time / duration))
    }

    /// Monotonic-deque sliding minimum over [index − radius, index + radius].
    private static func slidingMinimum(_ values: [Float], radius: Int) -> [Float] {
        let count = values.count
        var result = [Float](repeating: 1, count: count)
        // A ring-free deque: indices only ever advance, so a flat array with
        // a moving head suffices.
        var deque = [Int](repeating: 0, count: count)
        values.withUnsafeBufferPointer { values in
            result.withUnsafeMutableBufferPointer { result in
                deque.withUnsafeMutableBufferPointer { deque in
                    var head = 0
                    var tail = 0
                    var next = 0
                    for index in 0..<count {
                        let upper = min(count - 1, index + radius)
                        while next <= upper {
                            while tail > head, values[deque[tail - 1]] >= values[next] {
                                tail -= 1
                            }
                            deque[tail] = next
                            tail += 1
                            next += 1
                        }
                        while deque[head] < index - radius {
                            head += 1
                        }
                        result[index] = values[deque[head]]
                    }
                }
            }
        }
        return result
    }
}

/// A small deterministic generator (64-bit LCG) so every rendering is
/// byte-identical across launches and devices.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }

    /// Uniform in [−1, 1).
    mutating func symmetric() -> Double {
        unit() * 2 - 1
    }
}
