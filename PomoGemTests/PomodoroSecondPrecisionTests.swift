import XCTest
@testable import PomoGem

final class PomodoroSecondPrecisionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_700_000)
    private let subject = FocusSubjectSnapshot(id: UUID(), name: "秒単位の集中", colorHex: "#3FA57C")

    func testLiteralLegacyDurationJSONKeepsItsMinuteMeaningAndEncoding() throws {
        let fixtures: [(String, PomodoroDuration, Int)] = [
            (#"{"twentyFiveMinutes":{}}"#, .twentyFiveMinutes, 1_500),
            (#"{"sixtyMinutes":{}}"#, .sixtyMinutes, 3_600),
            (#"{"custom":{"minutes":40}}"#, .custom(minutes: 40), 2_400),
            (#"{"custom":{"minutes":360}}"#, .custom(minutes: 360), 21_600)
        ]
        for (literal, expected, seconds) in fixtures {
            let decoded = try JSONDecoder().decode(
                PomodoroDuration.self, from: Data(literal.utf8)
            )
            XCTAssertEqual(decoded, expected)
            XCTAssertEqual(decoded.seconds, seconds)
            XCTAssertEqual(try encodedString(decoded), literal)
        }
    }

    func testWholeSecondsNormalizeToLegacyCasesReadableByTheOldDecoder() throws {
        let fixtures: [(Int, LegacyMinuteDuration)] = [
            (60, .custom(minutes: 1)),
            (1_500, .twentyFiveMinutes),
            (2_700, .custom(minutes: 45)),
            (3_600, .sixtyMinutes),
            (5_400, .custom(minutes: 90)),
            (21_600, .custom(minutes: 360))
        ]
        for (seconds, legacy) in fixtures {
            let duration = PomodoroDuration(totalSeconds: seconds)
            XCTAssertEqual(duration.minutes, seconds / 60)
            XCTAssertEqual(duration, PomodoroDuration.customSeconds(totalSeconds: seconds).normalized)
            XCTAssertEqual(
                try JSONDecoder().decode(LegacyMinuteDuration.self, from: JSONEncoder().encode(duration)),
                legacy
            )
            var engine = PomodoroEngine()
            try engine.startFocus(duration: .customSeconds(totalSeconds: seconds), isPro: true, now: start)
            XCTAssertEqual(engine.selectedDuration, duration)
        }
    }

    func testFractionalMinuteJSONUsesAnAdditiveCaseWithoutPretendingOldClientSupport() throws {
        let literal = #"{"customSeconds":{"totalSeconds":2431}}"#
        let duration = try JSONDecoder().decode(PomodoroDuration.self, from: Data(literal.utf8))
        XCTAssertEqual(duration, PomodoroDuration(totalSeconds: 2_431))
        XCTAssertEqual(duration.seconds, 2_431)
        XCTAssertNil(duration.minutes, "Callers must not silently persist a truncated minute value")
        XCTAssertEqual(try encodedString(duration), literal)
        XCTAssertThrowsError(try JSONDecoder().decode(LegacyMinuteDuration.self, from: Data(literal.utf8)))
    }

    func testSecondBoundariesStartWithExactDeadlinesAndUnchangedWholeMinuteMass() throws {
        for seconds in [60, 61, 119, 120, 1_501, 2_431, 21_599, 21_600] {
            let duration = PomodoroDuration(totalSeconds: seconds)
            XCTAssertTrue(duration.isValid)
            var engine = PomodoroEngine()
            try engine.startFocus(duration: duration, isPro: true, now: start)
            XCTAssertEqual(engine.endDate, start.addingTimeInterval(TimeInterval(seconds)))
            XCTAssertEqual(engine.snapshot(at: start).remainingSeconds, seconds)
            XCTAssertNil(engine.advance(at: start.addingTimeInterval(TimeInterval(seconds) - 0.001)))
            guard case let .focusCompleted(completion) = engine.advance(
                at: start.addingTimeInterval(TimeInterval(seconds))
            ) else { return XCTFail("Expected the exact seconds boundary to complete") }
            XCTAssertEqual(completion.seconds, seconds)
            XCTAssertEqual(completion.grams, seconds / 60 * 10)
            XCTAssertEqual(completion.duration, duration)
            XCTAssertNil(engine.advance(at: start.addingTimeInterval(TimeInterval(seconds + 30))))
        }
    }

    func testInvalidDecodedIntegersCannotOverflowOrBecomeAnAdmittedDuration() throws {
        let invalidSeconds = [Int.min, -60, -1, 0, 59, 21_601, 21_660, Int.max]
        let values = invalidSeconds.flatMap {
            [PomodoroDuration.customSeconds(totalSeconds: $0), PomodoroDuration(totalSeconds: $0)]
        } + [Int.min, -1, 0, 361, Int.max].map { PomodoroDuration.custom(minutes: $0) }
        for value in values {
            let decoded = try JSONDecoder().decode(PomodoroDuration.self, from: JSONEncoder().encode(value))
            XCTAssertFalse(decoded.isValid)
            XCTAssertTrue(decoded.requiresPro)
            XCTAssertEqual(decoded.displayLabel, "設定できない時間")
            _ = decoded.seconds
            _ = decoded.grams
            for isPro in [false, true] {
                var engine = PomodoroEngine()
                let unchanged = engine
                XCTAssertThrowsError(try engine.startFocus(duration: decoded, isPro: isPro, now: start)) {
                    XCTAssertEqual($0 as? PomodoroEngineError, .invalidCustomDuration)
                }
                XCTAssertEqual(engine, unchanged)
            }
        }
        for literal in [
            #"{"customSeconds":{"totalSeconds":60.5}}"#,
            #"{"customSeconds":{"totalSeconds":"61"}}"#,
            #"{"customSeconds":{"totalSeconds":9223372036854775808}}"#,
            #"{"customSeconds":{"seconds":61}}"#
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(PomodoroDuration.self, from: Data(literal.utf8)))
        }
    }

    func testOnlyExactExistingPresetsAreFreeNotTheirAdjacentSeconds() throws {
        let freeSeconds: Set<Int> = [1_500, 2_700, 3_600, 5_400]
        for seconds in [60, 1_499, 1_500, 1_501, 2_699, 2_700, 2_701,
                        3_599, 3_600, 3_601, 5_399, 5_400, 5_401, 21_600] {
            let duration = PomodoroDuration(totalSeconds: seconds)
            XCTAssertEqual(duration.requiresPro, !freeSeconds.contains(seconds))
            var engine = PomodoroEngine()
            if freeSeconds.contains(seconds) {
                try engine.startFocus(duration: duration, isPro: false, now: start)
                XCTAssertEqual(engine.selectedDuration.seconds, seconds)
            } else {
                XCTAssertThrowsError(try engine.startFocus(duration: duration, isPro: false, now: start)) {
                    XCTAssertEqual($0 as? PomodoroEngineError, .customDurationRequiresPro)
                }
                XCTAssertEqual(engine.phase, .idle)
            }
        }
    }

    func testDisplayLabelDoesNotRoundAwaySeconds() {
        for (seconds, label, grams) in [(60, "1分", 10), (61, "1分1秒", 10),
                                        (119, "1分59秒", 10), (1_500, "25分", 250),
                                        (2_430, "40分30秒", 400), (21_599, "359分59秒", 3_590),
                                        (21_600, "360分", 3_600)] {
            let duration = PomodoroDuration(totalSeconds: seconds)
            XCTAssertEqual(duration.displayLabel, label)
            XCTAssertEqual(duration.grams, grams)
        }
#if DEBUG
        XCTAssertEqual(PomodoroDuration.demo.displayLabel, "12秒")
        XCTAssertFalse(PomodoroDuration.demo.requiresPro)
#endif
    }

    func testPreciseTimerSurvivesLocalPauseRelaunchAndPendingCompletion() throws {
        let persistenceKey = FocusPersistence.key
        let priorValue = UserDefaults.standard.object(forKey: persistenceKey)
        defer {
            if let priorValue { UserDefaults.standard.set(priorValue, forKey: persistenceKey) }
            else { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        }
        let sessionID = UUID()
        let epochID = UUID()
        let anchor = ClockAnchor(wallDate: start, systemUptime: 1_000)
        var engine = PomodoroEngine(selectedDuration: PomodoroDuration(totalSeconds: 2_431))
        try engine.startFocus(isPro: true, now: start, sessionID: sessionID)
        FocusPersistence.save(envelope(engine, at: start, anchor: anchor, epochID: epochID))
        let running = try XCTUnwrap(FocusPersistence.load())
        XCTAssertEqual(running.engine, engine)
        XCTAssertEqual(running.subject, subject)
        XCTAssertEqual(FocusPersistence.relaunchAction(for: running, at: start.addingTimeInterval(17)),
                       .resumeFocus(remainingSeconds: 2_414))

        engine = running.engine
        try engine.pause(at: start.addingTimeInterval(17.25))
        FocusPersistence.save(envelope(engine, at: start.addingTimeInterval(17.25), anchor: anchor, epochID: epochID))
        let paused = try XCTUnwrap(FocusPersistence.load())
        XCTAssertTrue(paused.engine.hasValidPausedFocusPayloadState)
        XCTAssertEqual(paused.engine.currentSessionID, sessionID)
        XCTAssertEqual(paused.dataEpochID, epochID)
        XCTAssertEqual(paused.subject, subject)
        XCTAssertEqual(paused.engine.selectedDuration.seconds, 2_431)
        XCTAssertEqual(FocusPersistence.relaunchAction(for: paused, at: start.addingTimeInterval(100)),
                       .resumeFocus(remainingSeconds: 2_414))
        let restored = FocusPersistence.preparedForLocalRelaunch(
            paused, at: start.addingTimeInterval(130.5), uptime: 1_130.5
        )
        engine = restored.engine
        XCTAssertEqual(engine.currentSource, .timer)
        try engine.resume(at: start.addingTimeInterval(130.5))
        let scheduledEnd = start.addingTimeInterval(2_544.25)
        XCTAssertEqual(engine.endDate, scheduledEnd)
        guard case let .focusCompleted(completion) = engine.advance(
            at: scheduledEnd.addingTimeInterval(30), observedUptime: 3_574.25
        ) else { return XCTFail("Expected a precise completion after the restored pause") }
        XCTAssertEqual(completion.seconds, 2_431)
        XCTAssertEqual(completion.grams, 400)
        XCTAssertEqual(completion.endedAt, scheduledEnd)
        XCTAssertEqual(completion.sessionID, sessionID)
        XCTAssertTrue(engine.hasValidPersistedCompletion(completion))
        FocusPersistence.save(envelope(engine, at: completion.observedAt, completion: completion, epochID: epochID))
        let pending = try XCTUnwrap(FocusPersistence.load())
        XCTAssertEqual(pending.pendingCompletion, completion)
        XCTAssertEqual(pending.subject, subject)
        XCTAssertEqual(pending.engine.selectedDuration.seconds, 2_431)
        XCTAssertEqual(FocusPersistence.relaunchAction(for: pending, at: completion.observedAt), .commitPendingCompletion)
        XCTAssertNil(engine.advance(at: completion.observedAt.addingTimeInterval(60)))
    }

    func testCloudPayloadPreservesPreciseRunningPausedAndAdoptedCompletionStates() throws {
        let sessionID = UUID()
        let epochID = UUID()
        var engine = PomodoroEngine(selectedDuration: PomodoroDuration(totalSeconds: 119))
        try engine.startFocus(isPro: true, now: start, sessionID: sessionID)
        let runningRecord = try record(engine, status: .running, at: start, epochID: epochID)
        let running = try runningRecord.decodedPayload()
        XCTAssertEqual(running.engine.endDate, start.addingTimeInterval(119))
        XCTAssertEqual(running.engine.selectedDuration.seconds, 119)
        XCTAssertEqual(running.engine.currentSessionID, sessionID)
        XCTAssertEqual(running.dataEpochID, epochID)
        XCTAssertEqual(running.subject, subject)
        XCTAssertEqual(running.engine.snapshot(at: start.addingTimeInterval(18)).remainingSeconds, 101)

        engine = running.engine
        try engine.pause(at: start.addingTimeInterval(18.25))
        let pausedRecord = try record(engine, status: .paused, at: start.addingTimeInterval(18.25), epochID: epochID)
        let paused = try pausedRecord.decodedPayload()
        let adoptedAt = start.addingTimeInterval(318.25)
        let adopted = FocusPersistence.preparedForCrossDeviceAdoption(
            paused.recoveryEnvelope(adoptedAt: adoptedAt), at: adoptedAt, uptime: 42,
            demotionReason: .adoptedFromOtherDevice
        )
        XCTAssertEqual(adopted.engine.currentSource, .timerDemoted)
        XCTAssertEqual(adopted.engine.currentSessionID, sessionID)
        XCTAssertEqual(adopted.dataEpochID, epochID)
        XCTAssertEqual(adopted.subject, subject)
        XCTAssertEqual(adopted.engine.selectedDuration, .customSeconds(totalSeconds: 119))
        XCTAssertEqual(adopted.engine.snapshot(at: adoptedAt).remainingSeconds, 101)
        engine = adopted.engine
        try engine.resume(at: adoptedAt)
        let scheduledEnd = start.addingTimeInterval(419)
        XCTAssertEqual(engine.endDate, scheduledEnd)
        guard case let .focusCompleted(completion) = engine.advance(at: scheduledEnd, observedUptime: 142.75) else {
            return XCTFail("Expected the adopted timer to complete at its exact remaining duration")
        }
        let pendingRecord = try record(engine, status: .completionPending, at: scheduledEnd,
                                       completion: completion, epochID: epochID)
        let pending = try pendingRecord.decodedPayload()
        XCTAssertTrue(pending.isCompatible(with: .completed))
        XCTAssertEqual(pending.pendingCompletion?.seconds, 119)
        XCTAssertEqual(pending.pendingCompletion?.grams, 10)
        XCTAssertEqual(pending.pendingCompletion?.duration, .customSeconds(totalSeconds: 119))
        XCTAssertEqual(pending.pendingCompletion?.sessionID, sessionID)
        XCTAssertEqual(pending.pendingCompletion?.endedAt, scheduledEnd)
        XCTAssertEqual(pending.pendingCompletion?.source, .timerDemoted)
        XCTAssertNil(pending.pendingCompletion?.observedUptime)
        XCTAssertEqual(pending.dataEpochID, epochID)
        XCTAssertEqual(pending.subject, subject)
        XCTAssertEqual(FocusPersistence.relaunchAction(
            for: pending.recoveryEnvelope(adoptedAt: scheduledEnd.addingTimeInterval(30)),
            at: scheduledEnd.addingTimeInterval(30)
        ), .commitPendingCompletion)
    }

    func testCloudReaderRejectsInvalidSecondPayloadWithoutMutatingItsBytes() throws {
        var engine = PomodoroEngine(selectedDuration: PomodoroDuration(totalSeconds: 61))
        try engine.startFocus(isPro: true, now: start)
        for seconds in [Int.min, 0, 59, 21_601, Int.max] {
            let timer = try record(engine, status: .running, at: start)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: timer.payloadData) as? [String: Any])
            var encodedEngine = try XCTUnwrap(object["engine"] as? [String: Any])
            encodedEngine["selectedDuration"] = ["customSeconds": ["totalSeconds": seconds]]
            object["engine"] = encodedEngine
            timer.payloadData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let original = timer.payloadData
            XCTAssertThrowsError(try timer.decodedPayload()) {
                XCTAssertEqual($0 as? FocusCloudSyncError, .invalidPayload)
            }
            XCTAssertEqual(timer.payloadData, original)
        }
    }

    func testCloudReaderRejectsRoundedCompletionSecondsAndAward() throws {
        var engine = PomodoroEngine(selectedDuration: PomodoroDuration(totalSeconds: 119))
        try engine.startFocus(isPro: true, now: start)
        guard case let .focusCompleted(completion) = engine.advance(at: start.addingTimeInterval(119)) else {
            return XCTFail("Expected completion")
        }
        for (field, value) in [("seconds", 60), ("grams", 20)] {
            let timer = try record(engine, status: .completionPending, at: completion.endedAt, completion: completion)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: timer.payloadData) as? [String: Any])
            var encodedCompletion = try XCTUnwrap(object["pendingCompletion"] as? [String: Any])
            encodedCompletion[field] = value
            object["pendingCompletion"] = encodedCompletion
            timer.payloadData = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try timer.decodedPayload()) {
                XCTAssertEqual($0 as? FocusCloudSyncError, .invalidPayload)
            }
        }
    }

    private func envelope(
        _ engine: PomodoroEngine, at savedAt: Date, anchor: ClockAnchor? = nil,
        completion: PomodoroCompletion? = nil, epochID: UUID? = nil
    ) -> FocusRecoveryEnvelope {
        FocusRecoveryEnvelope(
            engine: engine,
            subject: subject,
            clockAnchor: anchor, pendingCompletion: completion, savedAt: savedAt, dataEpochID: epochID
        )
    }

    private func record(
        _ engine: PomodoroEngine, status: SyncedFocusStatus, at savedAt: Date,
        completion: PomodoroCompletion? = nil, epochID: UUID? = nil
    ) throws -> SyncedFocusTimer {
        let payload = try FocusCloudPayload(envelope: envelope(
            engine, at: savedAt, completion: completion, epochID: epochID
        ))
        return try SyncedFocusTimer(sessionID: try payload.validatedSessionID(), status: status,
                                    payload: payload, updatedAt: savedAt, writerDeviceID: "seconds-test")
    }

    private func encodedString(_ duration: PomodoroDuration) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(duration), as: UTF8.self)
    }
}

/// The released decoder deliberately has no second-based case. Whole-minute
/// normalization stays compatible; fractional durations require updated clients.
private enum LegacyMinuteDuration: Codable, Equatable {
    case twentyFiveMinutes
    case sixtyMinutes
    case custom(minutes: Int)
}
