import CoreHaptics
import XCTest
@testable import PomoGem

/// The completion vibration as data. No haptic engine is created here.
final class AlarmHapticPatternTests: XCTestCase {
    func testLegacyRawValuesAndUnknownValueFallbackStayCompatible() {
        XCTAssertEqual(Array(TimerCompletionHaptic.allCases.prefix(3)).map(\.rawValue), ["standard", "gentle", "strong"])
        XCTAssertEqual(TimerCompletionHaptic.allCases.count, 8)
        for style in TimerCompletionHaptic.allCases {
            XCTAssertEqual(TimerCompletionHaptic.resolved(style.rawValue), style)
        }
        XCTAssertEqual(TimerCompletionHaptic.resolved("future-pattern"), .standard)
        XCTAssertEqual(TimerCompletionHaptic.resolved(""), .standard)
    }

    @MainActor
    func testEveryStyleSurvivesStoredPreferencesAndSensoryResolution() {
        for style in TimerCompletionHaptic.allCases {
            let prefs = Prefs(timerCompletionHapticRawValue: style.rawValue)
            XCTAssertEqual(prefs.timerCompletionHapticRawValue, style.rawValue)
            XCTAssertEqual(PrefsSyncPolicy.resolvedSensoryState(in: [prefs]).timerCompletionHaptic, style)
        }
        let future = Prefs()
        // Model decoding and cloud sync can supply raw values after init.
        future.timerCompletionHapticRawValue = "future-pattern"
        XCTAssertEqual(PrefsSyncPolicy.resolvedSensoryState(in: [future]).timerCompletionHaptic, .standard)
        XCTAssertEqual(future.timerCompletionHapticRawValue, "future-pattern", "reading a fallback must not rewrite synced data")
    }

    func testGentlePreservesTheThreeOriginalTransientCues() {
        let legacy: [TimerCompletionHaptic: [(TimeInterval, Float, Float)]] = [
            .standard: [(0, 0.72, 0.82), (0.14, 0.92, 0.48)],
            .gentle: [(0, 0.42, 0.30)],
            .strong: [(0, 0.78, 0.74), (0.11, 0.94, 0.54), (0.24, 1.00, 0.36)]
        ]
        for (style, expected) in legacy {
            let pattern = AlarmHapticPattern.completion(strength: .gentle, style: style)
            XCTAssertNil(pattern.loopDuration)
            XCTAssertEqual(pattern.events.count, expected.count, style.rawValue)
            for (event, values) in zip(pattern.events, expected) {
                XCTAssertEqual(event.kind, .transient)
                XCTAssertEqual(event.time, values.0, accuracy: 1e-9)
                XCTAssertEqual(event.intensity, values.1, accuracy: 1e-6)
                XCTAssertEqual(event.sharpness, values.2, accuracy: 1e-6)
            }
        }
    }

    func testEveryOneShotFinishesBeforeTheNextGentleCue() {
        for style in TimerCompletionHaptic.allCases {
            let pattern = AlarmHapticPattern.completion(strength: .gentle, style: style)
            XCTAssertNil(pattern.loopDuration)
            XCTAssertEqual(pattern.events, AlarmHapticPattern.cueEvents(for: style))
            XCTAssertLessThanOrEqual(pattern.duration, 1.2, style.rawValue)
            XCTAssertLessThan(pattern.duration + 0.06, AlarmChannelPolicy.gentleRepeatInterval, style.rawValue)
        }
    }

    func testStrongerPresetsSustainFullIntensityWithGapsBetweenPulses() throws {
        for strength in [AlarmStrength.standard, .maximum] {
            for style in TimerCompletionHaptic.allCases {
                let pattern = AlarmHapticPattern.completion(strength: strength, style: style)
                let loop = try XCTUnwrap(pattern.loopDuration)
                let pulses = continuousEvents(in: pattern)
                XCTAssertFalse(pulses.isEmpty)
                XCTAssertEqual(pulses.first?.time, 0)
                XCTAssertGreaterThanOrEqual(sustainedDuration(of: pattern), 0.7, "\(strength) \(style)")
                XCTAssertTrue(pattern.events.allSatisfy { $0.intensity == 1 }, "\(strength) \(style)")
                for (previous, next) in zip(pulses, pulses.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(next.time - previous.end, 0.05, "the rhythm needs real silence")
                }
                XCTAssertGreaterThanOrEqual(loop - pattern.duration, 0.2, "pause before the next cycle")
                XCTAssertLessThanOrEqual(loop, 2.5, "responsive, recognizable alarm cycles")
            }
        }
    }

    func testMaximumSustainsLongerAndHasLessSilenceForEveryStyle() throws {
        for style in TimerCompletionHaptic.allCases {
            let standard = AlarmHapticPattern.completion(strength: .standard, style: style)
            let maximum = AlarmHapticPattern.completion(strength: .maximum, style: style)
            let standardLoop = try XCTUnwrap(standard.loopDuration)
            let maximumLoop = try XCTUnwrap(maximum.loopDuration)
            let standardSustain = sustainedDuration(of: standard)
            let maximumSustain = sustainedDuration(of: maximum)
            XCTAssertGreaterThan(maximumSustain, standardSustain, style.rawValue)
            XCTAssertGreaterThan(maximumSustain / maximumLoop, standardSustain / standardLoop, style.rawValue)
            XCTAssertLessThan(maximumLoop - maximumSustain, standardLoop - standardSustain, style.rawValue)
        }
    }

    func testRhythmsStayDistinctAtEveryStrength() {
        for strength in AlarmStrength.allCases {
            let patterns = TimerCompletionHaptic.allCases.map {
                AlarmHapticPattern.completion(strength: strength, style: $0)
            }
            for index in patterns.indices {
                for other in patterns.indices where other > index {
                    // A different accent or sharpness alone is not enough:
                    // the actual on/off timing must distinguish the styles.
                    let first = patterns[index].events.map { ($0.time, $0.end) }
                    let second = patterns[other].events.map { ($0.time, $0.end) }
                    XCTAssertFalse(first.elementsEqual(second, by: ==), "\(strength): styles \(index), \(other)")
                }
            }
        }
    }

    func testEveryPatternUsesValidHardwareParametersAndConvertsToCoreHaptics() throws {
        for strength in AlarmStrength.allCases {
            for style in TimerCompletionHaptic.allCases {
                let description = AlarmHapticPattern.completion(strength: strength, style: style)
                XCTAssertFalse(description.events.isEmpty)
                XCTAssertEqual(description.events.map(\.time), description.events.map(\.time).sorted())
                for event in description.events {
                    XCTAssertTrue(event.time.isFinite && event.time >= 0)
                    XCTAssertTrue(event.intensity.isFinite && (0...1).contains(event.intensity))
                    XCTAssertTrue(event.sharpness.isFinite && (0...1).contains(event.sharpness))
                    if case let .continuous(duration) = event.kind {
                        XCTAssertTrue(duration.isFinite && duration > 0)
                        XCTAssertLessThanOrEqual(duration, AlarmHapticPattern.maximumContinuousDuration)
                    }
                }
                let pattern = try description.makeHapticPattern()
                // Core Haptics may add a transient's own short length.
                XCTAssertGreaterThanOrEqual(pattern.duration, description.duration - 0.01, "\(strength) \(style)")
                XCTAssertLessThan(pattern.duration, description.duration + 0.2, "\(strength) \(style)")
            }
        }
    }

    private func continuousEvents(in pattern: AlarmHapticPattern) -> [AlarmHapticPattern.Event] {
        pattern.events.filter { if case .continuous = $0.kind { true } else { false } }
    }

    private func sustainedDuration(of pattern: AlarmHapticPattern) -> TimeInterval {
        continuousEvents(in: pattern).reduce(0) { $0 + $1.end - $1.time }
    }
}
