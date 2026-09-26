import CoreHaptics
import XCTest
@testable import PomoGem

/// The completion vibration as data. No haptic engine is created here.
final class AlarmHapticPatternTests: XCTestCase {
    func testGentleIsTodaysTransientCueForEveryStyle() {
        let today: [TimerCompletionHaptic: [(TimeInterval, Float, Float)]] = [
            .standard: [(0, 0.72, 0.82), (0.14, 0.92, 0.48)],
            .gentle: [(0, 0.42, 0.30)],
            .strong: [(0, 0.78, 0.74), (0.11, 0.94, 0.54), (0.24, 1.00, 0.36)]
        ]
        for style in TimerCompletionHaptic.allCases {
            let pattern = AlarmHapticPattern.completion(strength: .gentle, style: style)
            XCTAssertNil(pattern.loopDuration, "the gentle cue is repeated by the alert controller")
            let expected = today[style] ?? []
            XCTAssertEqual(pattern.events.count, expected.count, style.rawValue)
            for (event, values) in zip(pattern.events, expected) {
                XCTAssertEqual(event.kind, .transient)
                XCTAssertEqual(event.time, values.0, accuracy: 1e-9)
                XCTAssertEqual(event.intensity, values.1, accuracy: 1e-6)
                XCTAssertEqual(event.sharpness, values.2, accuracy: 1e-6)
            }
        }
    }

    func testStrongerPresetsLoopAFullIntensityBuzzWithAccents() {
        for strength in [AlarmStrength.standard, .maximum] {
            for style in TimerCompletionHaptic.allCases {
                let pattern = AlarmHapticPattern.completion(strength: strength, style: style)
                guard let loop = pattern.loopDuration else {
                    XCTFail("\(strength) \(style) must loop")
                    continue
                }
                XCTAssertTrue((1...2).contains(loop), "\(strength) \(style)")

                let buzz = pattern.events.filter { if case .continuous = $0.kind { true } else { false } }
                XCTAssertEqual(buzz.count, 1)
                XCTAssertEqual(buzz.first?.time, 0)
                XCTAssertEqual(buzz.first?.intensity, 1, "full intensity")
                let accents = pattern.events.filter { $0.kind == .transient }
                XCTAssertGreaterThanOrEqual(accents.count, 2, "\(strength) \(style)")
                XCTAssertTrue(accents.allSatisfy { $0.intensity == 1 && $0.sharpness >= 0.6 })

                // Everything happens inside one cycle, with a pause before
                // the next so the pulse reads as an alarm, not a hum.
                XCTAssertLessThan(pattern.duration, loop - 0.3, "\(strength) \(style)")
                XCTAssertEqual(pattern.events.map(\.time), pattern.events.map(\.time).sorted())
                for event in pattern.events {
                    if case let .continuous(duration) = event.kind {
                        XCTAssertLessThanOrEqual(duration, AlarmHapticPattern.maximumContinuousDuration)
                    }
                    XCTAssertTrue((0...1).contains(event.intensity))
                    XCTAssertTrue((0...1).contains(event.sharpness))
                }
            }
        }
    }

    func testMaximumBuzzesLongerThanStandard() {
        let standard = AlarmHapticPattern.completion(strength: .standard, style: .standard)
        let maximum = AlarmHapticPattern.completion(strength: .maximum, style: .standard)
        XCTAssertGreaterThan(maximum.duration, standard.duration)
        XCTAssertGreaterThan(
            maximum.events.filter { $0.kind == .transient }.count,
            standard.events.filter { $0.kind == .transient }.count
        )
    }

    func testEveryPatternConvertsToACoreHapticsPattern() throws {
        for strength in AlarmStrength.allCases {
            for style in TimerCompletionHaptic.allCases {
                let description = AlarmHapticPattern.completion(strength: strength, style: style)
                let pattern = try description.makeHapticPattern()
                // Core Haptics may add a transient's own short length.
                XCTAssertGreaterThanOrEqual(pattern.duration, description.duration - 0.01, "\(strength) \(style)")
                XCTAssertLessThan(pattern.duration, description.duration + 0.2, "\(strength) \(style)")
            }
        }
    }
}
