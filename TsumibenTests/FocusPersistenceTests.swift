import XCTest
@testable import Tsumiben

final class FocusPersistenceTests: XCTestCase {
    override func tearDown() {
        FocusPersistence.clear()
        FocusPersistence.clearBreak()
        PendingStratumCelebrationStore.removeAll()
        DeferredFocusCompletionStore.clear()
        super.tearDown()
    }

    func testRecoveryEnvelopeRoundTripPreservesSubjectClockAndPendingCompletion() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let subject = FocusSubjectSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            name: "宅建",
            colorHex: "#3FA57C"
        )
        let anchor = ClockAnchor(wallDate: start, systemUptime: 42)
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(
            isPro: false,
            now: start,
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000222")!
        )
        let event = try XCTUnwrap(engine.advance(
            at: start.addingTimeInterval(1_500),
            observedUptime: 1_542
        ))
        guard case let .focusCompleted(completion) = event else {
            return XCTFail("Expected a focus completion")
        }

        FocusPersistence.save(
            engine,
            subject: subject,
            clockAnchor: anchor,
            pendingCompletion: completion
        )

        let recovered = try XCTUnwrap(FocusPersistence.load())
        XCTAssertEqual(recovered.engine, engine)
        XCTAssertEqual(recovered.subject, subject)
        XCTAssertEqual(recovered.clockAnchor, anchor)
        XCTAssertEqual(recovered.pendingCompletion, completion)
        XCTAssertEqual(recovered.pendingCompletion?.observedUptime, 1_542)
    }

    func testRelaunchResumesSameSessionAtOneTwelveAndTwentyFourMinutes() throws {
        let start = Date(timeIntervalSince1970: 1_800_010_000)
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000223")!
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(
            isPro: false,
            now: start,
            sessionID: sessionID
        )
        let envelope = FocusRecoveryEnvelope(
            engine: engine,
            subject: FocusSubjectSnapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000112")!,
                name: "英語",
                colorHex: "#4C8CCF"
            ),
            clockAnchor: ClockAnchor(wallDate: start, systemUptime: 5_000),
            pendingCompletion: nil,
            savedAt: start
        )

        for elapsed in [60, 12 * 60, 24 * 60] {
            XCTAssertEqual(
                FocusPersistence.relaunchAction(
                    for: envelope,
                    at: start.addingTimeInterval(TimeInterval(elapsed))
                ),
                .resumeFocus(remainingSeconds: 1_500 - elapsed)
            )
            XCTAssertEqual(envelope.engine.currentSessionID, sessionID)
            XCTAssertEqual(envelope.engine.currentSource, .timer)
        }
    }

    func testKillAfterScheduledEndRestoresStableIdempotentCompletionID() throws {
        let start = Date(timeIntervalSince1970: 1_800_020_000)
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000224")!
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(
            isPro: false,
            now: start,
            sessionID: sessionID
        )
        FocusPersistence.save(
            engine,
            subject: FocusSubjectSnapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000113")!,
                name: "宅建",
                colorHex: "#3FA57C"
            ),
            clockAnchor: ClockAnchor(wallDate: start, systemUptime: 8_000)
        )

        let recovered = try XCTUnwrap(FocusPersistence.load())
        let observedAt = start.addingTimeInterval(1_505)
        XCTAssertEqual(
            FocusPersistence.relaunchAction(for: recovered, at: observedAt),
            .finishFocus
        )

        var firstAttempt = recovered.engine
        var retryAttempt = recovered.engine
        let firstEvent = try XCTUnwrap(firstAttempt.advance(
            at: observedAt,
            observedUptime: 9_505
        ))
        let retryEvent = try XCTUnwrap(retryAttempt.advance(
            at: observedAt,
            observedUptime: 9_505
        ))
        guard case let .focusCompleted(firstCompletion) = firstEvent,
              case let .focusCompleted(retryCompletion) = retryEvent
        else { return XCTFail("Expected focus completions") }

        XCTAssertEqual(firstCompletion.sessionID, sessionID)
        XCTAssertEqual(retryCompletion.sessionID, sessionID)
        XCTAssertEqual(firstCompletion, retryCompletion)

        var pendingEnvelope = recovered
        pendingEnvelope.engine = firstAttempt
        pendingEnvelope.pendingCompletion = firstCompletion
        XCTAssertEqual(
            FocusPersistence.relaunchAction(for: pendingEnvelope, at: observedAt),
            .commitPendingCompletion
        )
    }

    func testLegacyClockAnchorDecodesAsUnverifiableInsteadOfFalseTamper() throws {
        struct LegacyClockAnchor: Encodable {
            let wallDate: Date
            let systemUptime: TimeInterval
        }

        let start = Date(timeIntervalSince1970: 1_800_030_000)
        let data = try JSONEncoder().encode(
            LegacyClockAnchor(wallDate: start, systemUptime: 12_000)
        )
        let anchor = try JSONDecoder().decode(ClockAnchor.self, from: data)
        XCTAssertEqual(anchor.basis, .legacySystemUptime)
        XCTAssertEqual(
            FairnessPolicy.clockIntegrity(
                from: anchor,
                completionDate: start.addingTimeInterval(1_500),
                completionUptime: 13_500
            ),
            .unverifiable
        )
    }

    func testLegacyEnginePayloadRemainsDetectableAndDoesNotInventSubject() throws {
        let start = Date(timeIntervalSince1970: 1_800_100_000)
        var engine = PomodoroEngine(selectedDuration: .sixtyMinutes)
        try engine.startFocus(isPro: false, now: start)
        UserDefaults.standard.set(
            try JSONEncoder().encode(engine),
            forKey: FocusPersistence.key
        )

        let recovered = try XCTUnwrap(FocusPersistence.load())
        XCTAssertEqual(recovered.engine, engine)
        XCTAssertNil(recovered.subject)
        XCTAssertNil(recovered.pendingCompletion)
    }

    func testBreakRecoveryRoundTripAndClear() throws {
        let value = BreakRecoveryEnvelope(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000333")!,
            minutes: 15,
            endDate: Date(timeIntervalSince1970: 1_800_200_000)
        )
        FocusPersistence.saveBreak(value)
        XCTAssertEqual(FocusPersistence.loadBreak(), value)
        FocusPersistence.clearBreak()
        XCTAssertNil(FocusPersistence.loadBreak())
    }

    func testPendingStratumCelebrationStoreIsDurableDeduplicatedAndRemovable() throws {
        let suiteName = "TsumibenTests.stratum.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000444")!
        let value = PendingStratumCelebration(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_800_300_000),
            pebbleCount: 48,
            grams: 12_000,
            monthLabel: "2026年8月",
            colorHex: "#5DE0BD",
            level: 2
        )

        PendingStratumCelebrationStore.insert(value, defaults: defaults)
        PendingStratumCelebrationStore.insert(value, defaults: defaults)
        XCTAssertEqual(PendingStratumCelebrationStore.load(defaults: defaults), [value])

        PendingStratumCelebrationStore.remove(id: id, defaults: defaults)
        XCTAssertTrue(PendingStratumCelebrationStore.load(defaults: defaults).isEmpty)
        XCTAssertNil(defaults.data(forKey: PendingStratumCelebrationStore.defaultsKey))
    }

    func testPendingStratumCelebrationDecodesReceiptFromEarlierBuild() throws {
        struct LegacyReceipt: Codable {
            let id: UUID
            let createdAt: Date
            let pebbleCount: Int
            let grams: Int
            let monthLabel: String
        }

        let legacy = LegacyReceipt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000445")!,
            createdAt: Date(timeIntervalSince1970: 1_800_300_001),
            pebbleCount: 10,
            grams: 2_500,
            monthLabel: "2026年8月"
        )
        let decoded = try JSONDecoder().decode(
            PendingStratumCelebration.self,
            from: JSONEncoder().encode(legacy)
        )

        XCTAssertEqual(decoded.id, legacy.id)
        XCTAssertEqual(decoded.pebbleCount, 10)
        XCTAssertEqual(decoded.grams, 2_500)
        XCTAssertNil(decoded.colorHex)
        XCTAssertNil(decoded.level)
    }

    func testPendingStratumCelebrationSelectionPicksTimesHundredRegardlessOfInsertionOrder() {
        let createdAt = Date(timeIntervalSince1970: 1_800_300_100)
        let timesTen = PendingStratumCelebration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            createdAt: createdAt,
            pebbleCount: 10,
            grams: 2_500,
            monthLabel: "2026年8月"
        )
        let timesHundred = PendingStratumCelebration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000100")!,
            createdAt: createdAt,
            pebbleCount: 100,
            grams: 25_000,
            monthLabel: "2026年8月"
        )

        XCTAssertEqual(
            PendingStratumCelebrationSelection.latest(in: [timesTen, timesHundred]),
            timesHundred
        )
        XCTAssertEqual(
            PendingStratumCelebrationSelection.latest(in: [timesHundred, timesTen]),
            timesHundred
        )
    }

    func testPendingStratumCelebrationSelectionPrefersNewerCreationOverPebbleCount() {
        let olderTimesHundred = PendingStratumCelebration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000200")!,
            createdAt: Date(timeIntervalSince1970: 1_800_300_200),
            pebbleCount: 100,
            grams: 25_000,
            monthLabel: "2026年8月"
        )
        let newerTimesTen = PendingStratumCelebration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            createdAt: Date(timeIntervalSince1970: 1_800_300_201),
            pebbleCount: 10,
            grams: 2_500,
            monthLabel: "2026年8月"
        )

        XCTAssertEqual(
            PendingStratumCelebrationSelection.latest(in: [newerTimesTen, olderTimesHundred]),
            newerTimesTen
        )
    }

    func testPendingStratumCelebrationSelectionUsesUUIDAsStableFinalTieBreak() {
        let createdAt = Date(timeIntervalSince1970: 1_800_300_300)
        let lowerID = PendingStratumCelebration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
            createdAt: createdAt,
            pebbleCount: 100,
            grams: 25_000,
            monthLabel: "2026年8月"
        )
        let higherID = PendingStratumCelebration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
            createdAt: createdAt,
            pebbleCount: 100,
            grams: 25_000,
            monthLabel: "2026年8月"
        )

        XCTAssertEqual(
            PendingStratumCelebrationSelection.latest(in: [lowerID, higherID]),
            higherID
        )
        XCTAssertEqual(
            PendingStratumCelebrationSelection.latest(in: [higherID, lowerID]),
            higherID
        )
        XCTAssertNil(PendingStratumCelebrationSelection.latest(in: []))
    }

    func testDeferredCompletionPresentationFlagIsScopedToExactSession() throws {
        let suiteName = "TsumibenTests.focus-deferral.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000551")!
        let other = UUID(uuidString: "00000000-0000-0000-0000-000000000552")!

        DeferredFocusCompletionStore.mark(sessionID: first, defaults: defaults)
        XCTAssertEqual(
            DeferredFocusCompletionStore.sessionID(defaults: defaults),
            first
        )
        DeferredFocusCompletionStore.clear(sessionID: other, defaults: defaults)
        XCTAssertEqual(
            DeferredFocusCompletionStore.sessionID(defaults: defaults),
            first
        )
        DeferredFocusCompletionStore.clear(sessionID: first, defaults: defaults)
        XCTAssertNil(DeferredFocusCompletionStore.sessionID(defaults: defaults))
    }
}
