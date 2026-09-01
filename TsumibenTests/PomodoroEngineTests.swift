import XCTest
@testable import Tsumiben

final class PomodoroEngineTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_788_000_000)

    func testTwentyFiveMinuteFocusUsesAbsoluteEndDate() throws {
        let sessionID = UUID()
        var engine = PomodoroEngine()

        try engine.startFocus(
            duration: .twentyFiveMinutes,
            isPro: false,
            now: referenceDate,
            sessionID: sessionID
        )

        XCTAssertEqual(
            engine.endDate,
            referenceDate.addingTimeInterval(TimeInterval(Constants.Timer.twentyFiveMinutes * 60))
        )
        XCTAssertEqual(engine.snapshot(at: referenceDate).remainingSeconds, 1_500)
        XCTAssertEqual(
            engine.snapshot(at: referenceDate.addingTimeInterval(750)).progress,
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(engine.snapshot(at: referenceDate).sessionID, sessionID)
    }

    func testSixtyMinutesIsFreeAndCustomRequiresPro() throws {
        var sixtyMinuteEngine = PomodoroEngine()
        XCTAssertNoThrow(
            try sixtyMinuteEngine.startFocus(
                duration: .sixtyMinutes,
                isPro: false,
                now: referenceDate
            )
        )
        XCTAssertEqual(sixtyMinuteEngine.snapshot(at: referenceDate).remainingSeconds, 3_600)

        var freeEngine = PomodoroEngine()
        XCTAssertThrowsError(
            try freeEngine.startFocus(
                duration: .custom(minutes: 40),
                isPro: false,
                now: referenceDate
            )
        ) { error in
            XCTAssertEqual(error as? PomodoroEngineError, .customDurationRequiresPro)
        }

        var proEngine = PomodoroEngine()
        XCTAssertNoThrow(
            try proEngine.startFocus(
                duration: .custom(minutes: 40),
                isPro: true,
                now: referenceDate
            )
        )
        XCTAssertEqual(proEngine.snapshot(at: referenceDate).remainingSeconds, 2_400)
    }

    func testCustomValuesMatchingFreePresetsAreNormalizedAndFree() throws {
        for minutes in [Constants.Timer.twentyFiveMinutes, Constants.Timer.sixtyMinutes] {
            var engine = PomodoroEngine()
            try engine.startFocus(
                duration: .custom(minutes: minutes),
                isPro: false,
                now: referenceDate
            )
            XCTAssertFalse(engine.selectedDuration.requiresPro)
            XCTAssertEqual(engine.selectedDuration, PomodoroDuration(minutes: minutes))
        }
    }

    func testFocusTimerRingSizeIsAlwaysFiniteAndPositive() {
        let invalidContainers: [CGSize] = [
            .zero,
            CGSize(width: -1, height: 874),
            CGSize(width: 402, height: -1),
            CGSize(width: CGFloat.nan, height: 874),
            CGSize(width: 402, height: CGFloat.infinity)
        ]

        for container in invalidContainers {
            let value = FocusTimerLayoutPolicy.ringSize(in: container)
            XCTAssertTrue(value.isFinite)
            XCTAssertGreaterThan(value, 0)
        }
        XCTAssertEqual(FocusTimerLayoutPolicy.ringSize(in: CGSize(width: 63, height: 640)), 1)
        XCTAssertEqual(FocusTimerLayoutPolicy.ringSize(in: CGSize(width: 64, height: 640)), 1)
        XCTAssertEqual(FocusTimerLayoutPolicy.ringSize(in: CGSize(width: 320, height: 640)), 214)
        XCTAssertEqual(FocusTimerLayoutPolicy.ringSize(in: CGSize(width: 402, height: 874)), 286)
    }

    func testInvalidCustomDurationsAreRejected() {
        for minutes in [
            Constants.Timer.customMinimumMinutes - 1,
            Constants.Timer.customMaximumMinutes + 1
        ] {
            var engine = PomodoroEngine()
            XCTAssertThrowsError(
                try engine.startFocus(
                    duration: .custom(minutes: minutes),
                    isPro: true,
                    now: referenceDate
                )
            ) { error in
                XCTAssertEqual(error as? PomodoroEngineError, .invalidCustomDuration)
            }
        }
    }

    func testLateTicksCompleteExactlyOnceWithScheduledEnd() throws {
        let sessionID = UUID()
        var engine = PomodoroEngine()
        try engine.startFocus(
            duration: .twentyFiveMinutes,
            isPro: false,
            now: referenceDate,
            sessionID: sessionID
        )
        let scheduledEnd = referenceDate.addingTimeInterval(1_500)

        XCTAssertNil(engine.advance(at: scheduledEnd.addingTimeInterval(-0.001)))
        let event = engine.advance(
            at: scheduledEnd.addingTimeInterval(42),
            observedUptime: 12_345.5
        )

        guard case let .focusCompleted(completion) = event else {
            return XCTFail("Expected one focus completion")
        }
        XCTAssertEqual(completion.sessionID, sessionID)
        XCTAssertEqual(completion.endedAt, scheduledEnd)
        XCTAssertEqual(completion.observedAt, scheduledEnd.addingTimeInterval(42))
        XCTAssertEqual(completion.observedUptime, 12_345.5)
        XCTAssertEqual(completion.seconds, 1_500)
        XCTAssertEqual(completion.grams, 250)
        XCTAssertNil(engine.advance(at: scheduledEnd.addingTimeInterval(43)))
        XCTAssertNil(engine.advance(at: scheduledEnd.addingTimeInterval(1_000)))
    }

    func testLegacyCompletionPayloadDecodesWithoutMonotonicObservation() throws {
        var engine = PomodoroEngine()
        try engine.startFocus(
            duration: .twentyFiveMinutes,
            isPro: false,
            now: referenceDate
        )
        guard case let .focusCompleted(completion) = engine.advance(
            at: referenceDate.addingTimeInterval(1_500),
            observedUptime: 8_000
        ) else {
            return XCTFail("Expected focus completion")
        }

        let encoded = try JSONEncoder().encode(completion)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "observedUptime")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PomodoroCompletion.self, from: legacyData)

        XCTAssertNil(decoded.observedUptime)
        XCTAssertEqual(decoded.sessionID, completion.sessionID)
        XCTAssertEqual(decoded.source, completion.source)
    }

    func testPauseAndResumePreserveExactRemainingDuration() throws {
        var engine = PomodoroEngine()
        try engine.startFocus(
            duration: .twentyFiveMinutes,
            isPro: false,
            now: referenceDate
        )
        let pausedAt = referenceDate.addingTimeInterval(321.25)
        try engine.pause(at: pausedAt)

        let paused = engine.snapshot(at: referenceDate.addingTimeInterval(20_000))
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertEqual(paused.remainingSeconds, 1_179)

        let resumedAt = referenceDate.addingTimeInterval(40_000)
        try engine.resume(at: resumedAt)
        let expectedEnd = resumedAt.addingTimeInterval(1_178.75)
        let actualEnd = try XCTUnwrap(engine.endDate)
        XCTAssertEqual(
            actualEnd.timeIntervalSince1970,
            expectedEnd.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertNil(engine.advance(at: expectedEnd.addingTimeInterval(-0.001)))
        XCTAssertNotNil(engine.advance(at: expectedEnd))
    }

    func testDateLineAndDSTDoNotChangeAbsoluteCountdown() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let springForwardStart = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 8,
            hour: 1,
            minute: 55
        )))
        var engine = PomodoroEngine()
        try engine.startFocus(
            duration: .twentyFiveMinutes,
            isPro: false,
            now: springForwardStart
        )

        // Local wall time jumps from 01:59 to 03:00, but ten real minutes are
        // still ten elapsed minutes.
        let tenMinutesLater = springForwardStart.addingTimeInterval(600)
        XCTAssertEqual(engine.snapshot(at: tenMinutesLater).remainingSeconds, 900)
        XCTAssertEqual(
            engine.endDate,
            springForwardStart.addingTimeInterval(1_500)
        )
    }

    func testEveryFourthCompletionGetsLongBreak() throws {
        var engine = PomodoroEngine(completedFocusCount: 3)
        try engine.startFocus(
            duration: .twentyFiveMinutes,
            isPro: false,
            now: referenceDate
        )
        _ = engine.advance(at: referenceDate.addingTimeInterval(1_500))
        try engine.startBreak(now: referenceDate.addingTimeInterval(1_501))

        XCTAssertEqual(engine.phase, .longBreak)
        XCTAssertEqual(
            engine.snapshot(at: referenceDate.addingTimeInterval(1_501)).remainingSeconds,
            Constants.Timer.longBreakMinutes * Constants.Timer.secondsPerMinute
        )
    }

    func testDemotedFocusStillCompletesButIsSelfReported() throws {
        var engine = PomodoroEngine()
        try engine.startFocus(
            isPro: false,
            now: referenceDate
        )
        try engine.demoteCurrentFocus()

        guard case let .focusCompleted(completion) = engine.advance(
            at: referenceDate.addingTimeInterval(1_500)
        ) else {
            return XCTFail("Demoted effort must still complete")
        }
        XCTAssertEqual(completion.source, .timerDemoted)
        XCTAssertEqual(completion.grams, 250)
    }

    func testRelaunchDiscardsRunningFocusWithoutCompletion() throws {
        let sessionID = UUID()
        var engine = PomodoroEngine()
        try engine.startFocus(
            isPro: false,
            now: referenceDate,
            sessionID: sessionID
        )

        XCTAssertEqual(
            engine.recoverAfterProcessRelaunch(),
            .interruptedFocus(sessionID: sessionID)
        )
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertNil(engine.advance(at: referenceDate.addingTimeInterval(10_000)))
    }

    func testCodableRoundTripPreservesEndDateAndCompletionIdempotence() throws {
        let sessionID = UUID()
        var engine = PomodoroEngine()
        try engine.startFocus(
            isPro: false,
            now: referenceDate,
            sessionID: sessionID
        )
        let encodedRunning = try JSONEncoder().encode(engine)
        var restoredRunning = try JSONDecoder().decode(
            PomodoroEngine.self,
            from: encodedRunning
        )
        let end = try XCTUnwrap(restoredRunning.endDate)
        XCTAssertNotNil(restoredRunning.advance(at: end))

        let encodedCompleted = try JSONEncoder().encode(restoredRunning)
        var restoredCompleted = try JSONDecoder().decode(
            PomodoroEngine.self,
            from: encodedCompleted
        )
        XCTAssertNil(restoredCompleted.advance(at: end.addingTimeInterval(1)))
        XCTAssertEqual(restoredCompleted.phase, .focusCompleted)
    }

#if DEBUG
    func testDebugDemoAwardsOneMeasuredPebbleWorthOfMass() throws {
        var engine = PomodoroEngine()
        try engine.startFocus(duration: .demo, isPro: false, now: referenceDate)

        guard case let .focusCompleted(completion) = engine.advance(
            at: referenceDate.addingTimeInterval(TimeInterval(Constants.Timer.demoSeconds))
        ) else {
            return XCTFail("Expected demo completion")
        }
        XCTAssertEqual(completion.seconds, Constants.Timer.demoSeconds)
        XCTAssertEqual(completion.grams, Constants.Mass.measuredPebbleGrams)
    }
#endif
}
