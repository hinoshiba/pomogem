import Accelerate
import AVFoundation
import XCTest
@testable import PomoGem

/// Numeric checks that the alarm sounds are loud, clean and speaker-friendly.
///
/// Set `POMOGEM_ALARM_PREVIEW_DIR` (with xcodebuild:
/// `TEST_RUNNER_POMOGEM_ALARM_PREVIEW_DIR=/some/dir`) to also write every
/// rendering as a 16-bit WAV there for listening; the files are read back and
/// measured again. Nothing is written into the repository.
@MainActor
final class AlarmSoundSynthesisTests: XCTestCase {
    private struct Rendering {
        let source: AlarmSoundSource
        let loop: [Float]
        let ringtone: [Float]
        let preview: [Float]
    }

    private static var cache: [AlarmSoundChoice: Rendering] = [:]

    private func rendering(_ choice: AlarmSoundChoice) -> Rendering {
        if let cached = Self.cache[choice] { return cached }
        let source = AlarmSoundLibrary.source(for: choice)
        let value = Rendering(
            source: source,
            loop: AlarmSoundSynthesis.loop(source),
            ringtone: AlarmSoundSynthesis.ringtone(source),
            preview: AlarmSoundSynthesis.preview(source)
        )
        Self.cache[choice] = value
        return value
    }

    // MARK: Loudness and cleanliness

    func testEveryChoiceIsPeakNormalisedToAboutMinusOneDBFSWithoutClipping() {
        for choice in AlarmSoundChoice.allCases {
            let rendered = rendering(choice)
            for (name, samples) in [("loop", rendered.loop), ("ringtone", rendered.ringtone), ("preview", rendered.preview)] {
                let measured = SoundMeasurement(samples)
                XCTAssertEqual(measured.peakDecibels, -1, accuracy: 0.3, "\(choice.rawValue) \(name) peak")
                XCTAssertEqual(measured.clippedRuns, 0, "\(choice.rawValue) \(name) must not clip")
                XCTAssertLessThan(abs(measured.mean), 0.01, "\(choice.rawValue) \(name) DC offset")
                XCTAssertFalse(samples.contains { !$0.isFinite }, "\(choice.rawValue) \(name) finite")
            }
        }
    }

    func testTheFiveAlarmSoundsAreLoudAndSitInThePhoneSpeakerBand() {
        for sound in AlarmSynthesizedSound.allCases {
            let rendered = rendering(AlarmSoundChoice(rawValue: sound.rawValue)!)
            let loop = rendered.loop
            let measured = SoundMeasurement(loop)
            // Commercial alarm tones sit around −8 to −14 dBFS RMS; today's
            // chime every 1.3 s is about −20 dBFS. These all sit at the loud
            // end (−7 to −10.5 dBFS as rendered today).
            XCTAssertGreaterThan(measured.rmsDecibels, -11.5, "\(sound.rawValue) loop RMS")
            XCTAssertGreaterThan(measured.loudestWindowRMSDecibels(window: 0.4), -10, "\(sound.rawValue) 400 ms RMS")
            // The lock-screen ringtone keeps most of that loudness despite
            // the gaps between cycles.
            XCTAssertGreaterThan(SoundMeasurement(rendered.ringtone).rmsDecibels, -12, "\(sound.rawValue) ringtone RMS")
            XCTAssertGreaterThan(measured.bandFraction(800...3_000), 0.70, "\(sound.rawValue) energy in 800 Hz–3 kHz")
            XCTAssertLessThan(measured.bandFraction(5_000...22_050), 0.10, "\(sound.rawValue) shrill energy above 5 kHz")
            XCTAssertLessThan(measured.bandFraction(20...500), 0.05, "\(sound.rawValue) energy a phone speaker cannot play")
        }
    }

    func testTheNewSoundsAreMuchLouderThanTodaysChime() {
        // Today's alarm: the standard chime (gain 0.72) once every 1.3 s.
        let chime = AlarmSoundLibrary.samples(of: SoundSynth.makeTimerCompletionBuffer(for: .standard))
        var today = [Float](repeating: 0, count: AlarmSoundSynthesis.frames(1.3))
        for index in 0..<min(chime.count, today.count) { today[index] = chime[index] }
        let todayRMS = SoundMeasurement(today).rmsDecibels
        for sound in AlarmSynthesizedSound.allCases {
            let loop = rendering(AlarmSoundChoice(rawValue: sound.rawValue)!).loop
            XCTAssertGreaterThan(SoundMeasurement(loop).rmsDecibels, todayRMS + 6, sound.rawValue)
        }
    }

    // MARK: Structure

    func testLoopsAreOnePeriodLong() {
        for choice in AlarmSoundChoice.allCases {
            let rendered = rendering(choice)
            XCTAssertEqual(rendered.loop.count, AlarmSoundSynthesis.frames(rendered.source.period), choice.rawValue)
            XCTAssertGreaterThanOrEqual(rendered.source.period, 1.5, choice.rawValue)
            XCTAssertLessThanOrEqual(rendered.source.period, 4, choice.rawValue)
        }
    }

    /// No click at the loop point, checked against what a seamless loop is:
    /// the cycles laid end to end with every tail ringing into the next.
    /// Cutting the tail off instead of folding it changes the period by 5–42%
    /// of its peak for every sound whose tail outlasts the period.
    func testTheFoldedPeriodIsTheSteadyStateOfTheCyclesLaidEndToEnd() {
        for choice in AlarmSoundChoice.allCases {
            let source = rendering(choice).source
            let period = AlarmSoundSynthesis.frames(source.period)
            let settled = (source.oneShot.count + period - 1) / period
            var laidOut = [Float](repeating: 0, count: (settled + 1) * period)
            for cycle in 0...settled {
                let start = cycle * period
                for index in source.oneShot.indices where start + index < laidOut.count {
                    laidOut[start + index] += source.oneShot[index]
                }
            }
            let reference = Array(laidOut[(settled * period)..<((settled + 1) * period)])
            let folded = AlarmSoundSynthesis.fold(source)
            XCTAssertEqual(folded.count, period, choice.rawValue)
            let peak = AlarmSoundSynthesis.peak(of: reference)
            var worst: Float = 0
            for index in 0..<min(folded.count, reference.count) {
                worst = max(worst, abs(folded[index] - reference[index]))
            }
            XCTAssertLessThan(worst, peak * 1e-5, choice.rawValue)
        }
    }

    /// The mastering treats the loop point like any other sample: mastering
    /// the folded period rotated by half a period gives the loop rotated by
    /// half a period. A limiter that restarted at the loop point would give
    /// a different gain on both sides of it (a step of up to 0.06 here).
    func testTheLoopIsMasteredAsACircleWithoutASeam() {
        for choice in AlarmSoundChoice.allCases {
            let rendered = rendering(choice)
            let folded = AlarmSoundSynthesis.fold(rendered.source)
            for shift in [0, folded.count / 2] {
                let rotatedFold = Array(folded[shift...] + folded[..<shift])
                let expected = Array(rendered.loop[shift...] + rendered.loop[..<shift])
                let mastered = AlarmSoundSynthesis.master(rotatedFold, driveDecibels: rendered.source.limiterDrive, circular: true)
                var worst: Float = 0
                for index in 0..<min(mastered.count, expected.count) {
                    worst = max(worst, abs(mastered[index] - expected[index]))
                }
                XCTAssertLessThan(worst, 1e-5, "\(choice.rawValue) shifted by \(shift)")
            }
        }
    }

    func testRingtonesFitTheNotificationLimitAndStartAndEndSilently() {
        for choice in AlarmSoundChoice.allCases {
            let rendered = rendering(choice)
            let duration = Double(rendered.ringtone.count) / AlarmSoundSynthesis.sampleRate
            XCTAssertLessThanOrEqual(duration, AlarmSoundSynthesis.ringtoneMaximumDuration, choice.rawValue)
            XCTAssertGreaterThan(duration, 20, "\(choice.rawValue) should ring for most of the allowed time")
            XCTAssertEqual(rendered.ringtone.first ?? 1, 0, accuracy: 1e-4, choice.rawValue)
            XCTAssertEqual(rendered.ringtone.last ?? 1, 0, accuracy: 1e-4, choice.rawValue)
            XCTAssertEqual(rendered.preview.first ?? 1, 0, accuracy: 1e-4, choice.rawValue)
            XCTAssertEqual(rendered.preview.last ?? 1, 0, accuracy: 1e-4, choice.rawValue)
            // Several cycles, not one long tone.
            let cycles = Int(duration / (rendered.source.period + AlarmSoundSynthesis.ringtoneGap))
            XCTAssertGreaterThanOrEqual(cycles, 4, choice.rawValue)
        }
    }

    func testRenderingIsDeterministicAndEverySoundIsDistinct() {
        for sound in AlarmSynthesizedSound.allCases {
            XCTAssertEqual(AlarmSoundSynthesis.source(for: sound), AlarmSoundSynthesis.source(for: sound), sound.rawValue)
        }
        let loops = AlarmSoundChoice.allCases.map { rendering($0).loop }
        XCTAssertEqual(Set(loops.map { $0.map(\.bitPattern) }).count, AlarmSoundChoice.allCases.count)
    }

    func testLegacyChimesKeepTheirTimbreAndOnlyGetLouder() {
        for legacy in TimerCompletionSound.allCases {
            let chime = AlarmSoundLibrary.samples(of: SoundSynth.makeTimerCompletionBuffer(for: legacy))
            let loop = rendering(AlarmSoundChoice(legacy: legacy)).loop
            let chimePeak = AlarmSoundSynthesis.peak(of: chime)
            let scale = AlarmSoundSynthesis.peak(of: loop) / chimePeak
            XCTAssertGreaterThanOrEqual(scale, 1, "\(legacy.rawValue) is never quieter than today")
            // Twice per cycle and peak-normalised: louder than today's single
            // chime every 1.3 s.
            var today = [Float](repeating: 0, count: AlarmSoundSynthesis.frames(1.3))
            for index in 0..<min(chime.count, today.count) { today[index] = chime[index] }
            XCTAssertGreaterThan(
                SoundMeasurement(loop).rmsDecibels,
                SoundMeasurement(today).rmsDecibels + 2,
                legacy.rawValue
            )
            // The first strike is the original waveform, scaled: no limiting,
            // no change of character.
            var worst: Float = 0
            for index in 0..<chime.count {
                worst = max(worst, abs(loop[index] - chime[index] * scale))
            }
            XCTAssertLessThan(worst, 1e-4, legacy.rawValue)
        }
    }

    func testTheLimiterNeverExceedsItsCeilingAndLeavesQuietSignalsAlone() {
        let loud = (0..<44_100).map { Float(1.8 * sin(2 * Double.pi * 1_000 * Double($0) / 44_100)) }
        let limited = AlarmSoundSynthesis.limit(loud, ceiling: 1)
        XCTAssertLessThanOrEqual(AlarmSoundSynthesis.peak(of: limited), 1.000_1)
        XCTAssertEqual(SoundMeasurement(limited).clippedRuns, 0)
        let quiet = loud.map { $0 * 0.3 }
        XCTAssertEqual(AlarmSoundSynthesis.limit(quiet, ceiling: 1), quiet)
    }

    /// Changing the synthesis must change `AlarmSoundLibrary.fileVersion`:
    /// an existing Library/Sounds file with the current name is reused, so a
    /// silent change would leave the old sound on the lock screen and in the
    /// system alarm while the app plays the new one. The pins are hashes of
    /// the 16-bit ringtone as it is written to disk, so a retune (even
    /// 2,048 → 2,000 Hz, which peak normalisation hides from any loudness
    /// figure) fails here. This covers the three original chimes too, whose
    /// synthesis lives in SoundSynth.swift. When it fails: bump the version,
    /// then paste the new hashes from the failure messages. (A toolchain whose
    /// maths library rounds differently can also move them; bumping is then
    /// merely a harmless re-render on devices.)
    func testRenderingFingerprintMatchesTheFileVersion() {
        XCTAssertEqual(AlarmSoundLibrary.fileVersion, 1)
        let pinned: [AlarmSoundChoice: String] = [
            .standard: "7aa1ec5ddd2418e",
            .soft: "e46ed513e65fc39b",
            .bright: "cbfcd1180018e83",
            .bell: "841af180b6517f20",
            .digital: "14f3bbc54820941b",
            .marimba: "7a3c079005c96ddd",
            .schoolChime: "c3642732e60783",
            .alarmClock: "7abdbe65138e0696"
        ]
        for choice in AlarmSoundChoice.allCases {
            let fingerprint = SoundMeasurement.pcm16Fingerprint(rendering(choice).ringtone)
            XCTAssertEqual(
                fingerprint,
                pinned[choice],
                "\(choice.rawValue): the ringtone changed; bump AlarmSoundLibrary.fileVersion and pin \(fingerprint)"
            )
        }
    }

    func testTheFingerprintSeesARetuneThatLoudnessCannot() {
        let tone: (Double) -> [Float] = { frequency in
            (0..<44_100).map { Float(0.9 * sin(2 * Double.pi * frequency * Double($0) / 44_100)) }
        }
        let original = tone(2_048)
        let retuned = tone(2_000)
        XCTAssertEqual(SoundMeasurement(original).rmsDecibels, SoundMeasurement(retuned).rmsDecibels, accuracy: 0.05)
        XCTAssertNotEqual(SoundMeasurement.pcm16Fingerprint(original), SoundMeasurement.pcm16Fingerprint(retuned))
        XCTAssertEqual(SoundMeasurement.pcm16Fingerprint(original), SoundMeasurement.pcm16Fingerprint(tone(2_048)))
    }

    // MARK: Listening copies

    func testPreviewsRenderToWAVForListeningWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["POMOGEM_ALARM_PREVIEW_DIR"],
              !path.isEmpty else {
            throw XCTSkip("Set POMOGEM_ALARM_PREVIEW_DIR to write listening copies")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report = ["choice\tfile\tseconds\tpeak_dBFS\trms_dBFS\tloudest400ms_dBFS\tband800_3k"]
        for choice in AlarmSoundChoice.allCases {
            let rendered = rendering(choice)
            let files: [(String, [Float])] = [
                ("preview", rendered.preview),
                ("loop-x3", rendered.loop + rendered.loop + rendered.loop),
                ("ringtone", rendered.ringtone)
            ]
            for (kind, samples) in files {
                let url = directory.appendingPathComponent("\(choice.rawValue)-\(kind).wav")
                try? FileManager.default.removeItem(at: url)
                try AlarmSoundLibrary.writeWAV(samples, to: url)
                let file = try AVAudioFile(forReading: url)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(file.length)
                ))
                try file.read(into: buffer)
                let readBack = AlarmSoundLibrary.samples(of: buffer)
                XCTAssertEqual(readBack.count, samples.count, url.lastPathComponent)
                let measured = SoundMeasurement(readBack)
                XCTAssertEqual(measured.peakDecibels, -1, accuracy: 0.3, url.lastPathComponent)
                XCTAssertGreaterThan(measured.rmsDecibels, -24, url.lastPathComponent)
                report.append([
                    choice.rawValue, url.lastPathComponent,
                    String(format: "%.2f", Double(readBack.count) / AlarmSoundSynthesis.sampleRate),
                    String(format: "%.2f", measured.peakDecibels),
                    String(format: "%.2f", measured.rmsDecibels),
                    String(format: "%.2f", measured.loudestWindowRMSDecibels(window: 0.4)),
                    String(format: "%.3f", measured.bandFraction(800...3_000))
                ].joined(separator: "\t"))
            }
        }
        try report.joined(separator: "\n").appending("\n").write(
            to: directory.appendingPathComponent("measurements.tsv"),
            atomically: true,
            encoding: .utf8
        )
    }
}

/// Peak, RMS and spectral balance of a mono 44.1 kHz rendering.
struct SoundMeasurement {
    let samples: [Float]

    init(_ samples: [Float]) {
        self.samples = samples
    }

    /// FNV-1a (64-bit) over the samples quantised to 16-bit little-endian
    /// PCM, the resolution of the CAF files.
    static func pcm16Fingerprint(_ samples: [Float]) -> String {
        let prime: UInt64 = 0x0000_0100_0000_01b3
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = UInt16(bitPattern: Int16((clamped * 32_767).rounded()))
            hash = (hash ^ UInt64(value & 0xff)) &* prime
            hash = (hash ^ UInt64(value >> 8)) &* prime
        }
        return String(hash, radix: 16)
    }

    var peak: Float { AlarmSoundSynthesis.peak(of: samples) }
    var peakDecibels: Double { Self.decibels(Double(peak)) }
    var mean: Double { samples.isEmpty ? 0 : samples.reduce(0) { $0 + Double($1) } / Double(samples.count) }
    var rmsDecibels: Double { Self.decibels(Self.rms(samples[...])) }

    /// Runs of three or more samples stuck at the peak: the signature of a
    /// clipped (flat-topped) waveform. A smooth waveform touches its peak for
    /// at most a sample or two.
    var clippedRuns: Int {
        let ceiling = peak * 0.999_9
        var runs = 0
        var run = 0
        for sample in samples {
            if abs(sample) >= ceiling {
                run += 1
                if run == 3 { runs += 1 }
            } else {
                run = 0
            }
        }
        return runs
    }

    func loudestWindowRMSDecibels(window: TimeInterval) -> Double {
        let length = max(1, Int(window * AlarmSoundSynthesis.sampleRate))
        guard samples.count >= length else { return rmsDecibels }
        var loudest = 0.0
        var start = 0
        while start + length <= samples.count {
            loudest = max(loudest, Self.rms(samples[start..<(start + length)]))
            start += length / 4
        }
        return Self.decibels(loudest)
    }

    /// Share of the signal's energy between the band's edges (Welch
    /// average of Hann-windowed 4096-point FFTs).
    func bandFraction(_ band: ClosedRange<Double>) -> Double {
        let spectrum = powerSpectrum
        let binWidth = AlarmSoundSynthesis.sampleRate / Double(Self.frameSize)
        var inside = 0.0
        var total = 0.0
        for bin in 1..<spectrum.count {
            total += spectrum[bin]
            if band.contains(Double(bin) * binWidth) { inside += spectrum[bin] }
        }
        return total > 0 ? inside / total : 0
    }

    private static let frameSize = 4_096

    private var powerSpectrum: [Double] {
        let frameSize = Self.frameSize
        let half = frameSize / 2
        let log2n = vDSP_Length(12)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))
        var power = [Double](repeating: 0, count: half)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: frameSize)
        var start = 0
        while start < samples.count {
            for index in 0..<frameSize {
                let position = start + index
                frame[index] = (position < samples.count ? samples[position] : 0) * window[index]
            }
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(
                        realp: realPointer.baseAddress!,
                        imagp: imaginaryPointer.baseAddress!
                    )
                    frame.withUnsafeBufferPointer { framePointer in
                        framePointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    for bin in 1..<half {
                        power[bin] += Double(realPointer[bin] * realPointer[bin]
                            + imaginaryPointer[bin] * imaginaryPointer[bin])
                    }
                }
            }
            start += half
        }
        return power
    }

    private static func rms(_ slice: ArraySlice<Float>) -> Double {
        guard !slice.isEmpty else { return 0 }
        let sum = slice.reduce(0) { $0 + Double($1) * Double($1) }
        return (sum / Double(slice.count)).squareRoot()
    }

    private static func decibels(_ value: Double) -> Double {
        20 * log10(max(value, 1e-12))
    }
}
