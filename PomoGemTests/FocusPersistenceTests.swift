import XCTest
@testable import PomoGem

final class FocusPersistenceTests: XCTestCase {
    override func tearDown() {
        FocusPersistence.clear()
        FocusPersistence.clearBreak()
        PendingStratumCelebrationStore.removeAll()
        DeferredFocusCompletionStore.clear()
        super.tearDown()
    }

    func testRewardDropPhaseRoundTripsAndMissingPhaseKeepsLegacySemantics() throws {
        for phase in [PendingRewardDropPhase.awaitingAcknowledgement, .awaitingLanding] {
            let receipt = makeRewardReceipt(phase: phase)
            let data = try JSONEncoder().encode(receipt)
            let decoded = try JSONDecoder().decode(PendingRewardReceipt.self, from: data)
            XCTAssertEqual(decoded, receipt)
            XCTAssertTrue(decoded.requiresDrop)
            XCTAssertEqual(decoded.isAwaitingAcknowledgement, phase == .awaitingAcknowledgement)
        }

        let receipt = makeRewardReceipt(phase: .awaitingAcknowledgement)
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(receipt)
        ) as? [String: Any])
        legacyObject.removeValue(forKey: "dropPhase")
        let legacy = try JSONDecoder().decode(
            PendingRewardReceipt.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        XCTAssertNil(legacy.dropPhase)
        XCTAssertFalse(legacy.requiresDrop)
        XCTAssertFalse(legacy.isAwaitingAcknowledgement)
        XCTAssertEqual(legacy, makeRewardReceipt(id: receipt.id, phase: nil))
    }

    func testRewardDropAcknowledgementPreservesFrozenReceiptAndFIFOWithoutDuplication() throws {
        let suiteName = "PomoGemTests.reward-drop-ack.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let start = Date(timeIntervalSince1970: 1_800_500_000)
        let first = makeRewardReceipt(createdAt: start, phase: nil)
        let target = makeRewardReceipt(
            createdAt: start.addingTimeInterval(1), phase: .awaitingAcknowledgement
        )
        let last = makeRewardReceipt(
            createdAt: start.addingTimeInterval(2), phase: .awaitingAcknowledgement
        )
        for receipt in [last, target, first] {
            XCTAssertTrue(PendingRewardReceiptStore.insert(receipt, defaults: defaults))
        }
        XCTAssertTrue(PendingRewardReceiptStore.acknowledgeDrop(id: target.id, defaults: defaults))
        let acknowledged = makeRewardReceipt(
            id: target.id, createdAt: target.createdAt, phase: .awaitingLanding
        )
        let expected = [first, acknowledged, last]

        // Read through a fresh defaults instance, as a returning Home does.
        let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertEqual(PendingRewardReceiptStore.load(defaults: reopenedDefaults), expected)
        XCTAssertTrue(PendingRewardReceiptStore.acknowledgeDrop(id: target.id, defaults: defaults))
        // A delayed duplicate insertion must not rewind an acknowledged card.
        XCTAssertTrue(PendingRewardReceiptStore.insert(target, defaults: defaults))
        XCTAssertEqual(PendingRewardReceiptStore.load(defaults: defaults), expected)
    }

    func testRewardDropAcknowledgementRejectsLegacyAndMissingReceiptsWithoutWriting() throws {
        let suiteName = "PomoGemTests.reward-drop-legacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = makeRewardReceipt(phase: nil)
        XCTAssertTrue(PendingRewardReceiptStore.insert(legacy, defaults: defaults))
        let key = AccountScopedLocalState.defaultsKey(
            base: PendingRewardReceiptStore.defaultsKey, defaults: defaults
        )
        let originalData = try XCTUnwrap(defaults.data(forKey: key))

        XCTAssertFalse(PendingRewardReceiptStore.acknowledgeDrop(id: legacy.id, defaults: defaults))
        XCTAssertFalse(PendingRewardReceiptStore.acknowledgeDrop(id: UUID(), defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: key), originalData)
        XCTAssertEqual(PendingRewardReceiptStore.load(defaults: defaults), [legacy])
    }

    func testRewardDropAcknowledgementKeepsExistingFourReceiptBound() throws {
        let suiteName = "PomoGemTests.reward-drop-bound.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let start = Date(timeIntervalSince1970: 1_800_500_000)
        let receipts = (0..<5).map { offset in
            makeRewardReceipt(
                createdAt: start.addingTimeInterval(TimeInterval(offset)),
                phase: .awaitingAcknowledgement
            )
        }
        for receipt in receipts {
            XCTAssertTrue(PendingRewardReceiptStore.insert(receipt, defaults: defaults))
        }
        XCTAssertFalse(PendingRewardReceiptStore.acknowledgeDrop(id: receipts[0].id, defaults: defaults))
        XCTAssertTrue(PendingRewardReceiptStore.acknowledgeDrop(id: receipts[2].id, defaults: defaults))
        let saved = PendingRewardReceiptStore.load(defaults: defaults)
        XCTAssertEqual(saved.map(\.id), Array(receipts.dropFirst()).map(\.id))
        XCTAssertEqual(saved.map(\.createdAt), Array(receipts.dropFirst()).map(\.createdAt))
        XCTAssertEqual(saved.filter { $0.dropPhase == .awaitingLanding }.map(\.id), [receipts[2].id])
    }

    func testRewardBreakSelectionSurvivesReopenAndKeepsOriginalDeadline() throws {
        let suite = "PomoGemTests.reward-rest-reopen.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selectedAt = Date(timeIntervalSince1970: 1_800_600_000)
        let receipt = makeRewardReceipt(createdAt: selectedAt, phase: .awaitingAcknowledgement)
        XCTAssertTrue(PendingRewardReceiptStore.insert(receipt, defaults: defaults))

        let started = try XCTUnwrap(FocusPersistence.beginRewardBreak(
            sessionID: receipt.id, defaults: defaults, at: selectedAt, uptime: 10_000
        ))
        XCTAssertNotEqual(started.id, receipt.id, "Stopping the focus alert must not acknowledge the break alert")
        XCTAssertEqual(started.originatingFocusSessionID, receipt.id)
        XCTAssertEqual(started.endDate, selectedAt.addingTimeInterval(900))
        XCTAssertEqual(started.clockAnchor, ClockAnchor(wallDate: selectedAt, systemUptime: 10_000))
        XCTAssertEqual(PendingRewardReceiptStore.load(defaults: defaults).first?.dropPhase, .awaitingLanding)

        // No Home, scene or process-local continuation is retained. Root's
        // ordinary break recovery reads just these durable bytes on remount.
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        let returnedAt = selectedAt.addingTimeInterval(120)
        let restored = try XCTUnwrap(FocusPersistence.loadBreak(defaults: reopened, at: returnedAt))
        XCTAssertEqual(restored, started)
        XCTAssertEqual(BreakRecoveryPolicy.remainingSeconds(
            minutes: restored.minutes, endDate: restored.endDate, at: returnedAt
        ), 780)
        XCTAssertEqual(FocusPersistence.beginRewardBreak(
            sessionID: receipt.id, defaults: reopened, at: returnedAt, uptime: 10_120
        ), started, "A repeated selection must reuse the same timer and deadline")
    }

    func testRewardBreakRecoveryFinishesCrashBetweenTimerSaveAndReceiptAcknowledgement() throws {
        let suite = "PomoGemTests.reward-rest-interrupted-write.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selectedAt = Date(timeIntervalSince1970: 1_800_610_000)
        let receipt = makeRewardReceipt(createdAt: selectedAt, phase: .awaitingAcknowledgement)
        XCTAssertTrue(PendingRewardReceiptStore.insert(receipt, defaults: defaults))
        let selectedBreak = BreakRecoveryEnvelope(
            id: UUID(), minutes: receipt.breakMinutes,
            endDate: selectedAt.addingTimeInterval(900),
            clockAnchor: ClockAnchor(wallDate: selectedAt, systemUptime: 20_000),
            originatingFocusSessionID: receipt.id
        )
        FocusPersistence.saveBreak(selectedBreak, defaults: defaults, at: selectedAt)
        XCTAssertEqual(PendingRewardReceiptStore.load(defaults: defaults).first?.dropPhase, .awaitingAcknowledgement)

        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(FocusPersistence.loadBreak(defaults: reopened, at: selectedAt.addingTimeInterval(30)), selectedBreak)
        XCTAssertEqual(PendingRewardReceiptStore.load(defaults: reopened).first?.dropPhase, .awaitingLanding)
        XCTAssertEqual(FocusPersistence.loadBreak(defaults: reopened, at: selectedAt.addingTimeInterval(60)), selectedBreak)
        XCTAssertEqual(PendingRewardReceiptStore.load(defaults: reopened).count, 1)
    }

    func testConsumedRewardBreakCannotRestartFromUnlandedReceipt() throws {
        let suite = "PomoGemTests.reward-rest-consumed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_620_000)
        let receipt = makeRewardReceipt(createdAt: now, phase: .awaitingAcknowledgement)
        XCTAssertTrue(PendingRewardReceiptStore.insert(receipt, defaults: defaults))
        XCTAssertNotNil(FocusPersistence.beginRewardBreak(
            sessionID: receipt.id, defaults: defaults, at: now, uptime: 30_000
        ))
        // Skip/completion consumes the one durable timer even if the drop has
        // not yet run on the returning Home.
        FocusPersistence.clearBreak(defaults: defaults)
        XCTAssertEqual(PendingRewardReceiptStore.load(defaults: defaults).first?.dropPhase, .awaitingLanding)
        XCTAssertNil(FocusPersistence.beginRewardBreak(
            sessionID: receipt.id, defaults: defaults, at: now.addingTimeInterval(5), uptime: 30_005
        ))
        XCTAssertNil(FocusPersistence.loadBreak(defaults: defaults, at: now.addingTimeInterval(5)))
        PendingRewardReceiptStore.remove(id: receipt.id, defaults: defaults)
        XCTAssertNil(FocusPersistence.beginRewardBreak(
            sessionID: receipt.id, defaults: defaults, at: now.addingTimeInterval(10), uptime: 30_010
        ))
    }

    func testExpiredRewardBreakRecoveryAcknowledgesCardWithoutStartingFreshRest() throws {
        let suite = "PomoGemTests.reward-rest-expired.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selectedAt = Date(timeIntervalSince1970: 1_800_630_000)
        let receipt = makeRewardReceipt(createdAt: selectedAt, phase: .awaitingAcknowledgement)
        XCTAssertTrue(PendingRewardReceiptStore.insert(receipt, defaults: defaults))
        let recovery = BreakRecoveryEnvelope(
            id: UUID(), minutes: receipt.breakMinutes,
            endDate: selectedAt.addingTimeInterval(900),
            clockAnchor: ClockAnchor(wallDate: selectedAt, systemUptime: 40_000),
            originatingFocusSessionID: receipt.id
        )
        FocusPersistence.saveBreak(recovery, defaults: defaults, at: selectedAt)
        // A recent late recovery remains an elapsed timer, not a new duration.
        let justLate = selectedAt.addingTimeInterval(920)
        XCTAssertEqual(FocusPersistence.loadBreak(defaults: defaults, at: justLate), recovery)
        XCTAssertEqual(BreakRecoveryPolicy.remainingSeconds(
            minutes: recovery.minutes, endDate: recovery.endDate, at: justLate
        ), 0)
        // Simulate the unacknowledged crash state again, then return next day.
        PendingRewardReceiptStore.save([receipt], defaults: defaults)
        let nextDay = selectedAt.addingTimeInterval(86_400)
        XCTAssertNil(FocusPersistence.loadBreak(defaults: defaults, at: nextDay))
        XCTAssertEqual(PendingRewardReceiptStore.load(defaults: defaults).first?.dropPhase, .awaitingLanding)
        XCTAssertNil(FocusPersistence.beginRewardBreak(
            sessionID: receipt.id, defaults: defaults, at: nextDay, uptime: 126_400
        ))
    }

    /// notify-06. Launch reads the rest's ID to keep its Live Activity before
    /// break recovery runs; that read must not repair anything on its own.
    func testValidBreakIDReadsWithoutRepairingTheEnvelopeOrTheReceipt() throws {
        let suite = "PomoGemTests.valid-break-id.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selectedAt = Date(timeIntervalSince1970: 1_800_640_000)
        XCTAssertNil(FocusPersistence.validBreakID(defaults: defaults, at: selectedAt))

        let receipt = makeRewardReceipt(createdAt: selectedAt, phase: .awaitingAcknowledgement)
        XCTAssertTrue(PendingRewardReceiptStore.insert(receipt, defaults: defaults))
        let recovery = BreakRecoveryEnvelope(
            id: UUID(), minutes: receipt.breakMinutes,
            endDate: selectedAt.addingTimeInterval(900),
            clockAnchor: ClockAnchor(wallDate: selectedAt, systemUptime: 50_000),
            originatingFocusSessionID: receipt.id
        )
        FocusPersistence.saveBreak(recovery, defaults: defaults, at: selectedAt)
        XCTAssertEqual(
            FocusPersistence.validBreakID(defaults: defaults, at: selectedAt.addingTimeInterval(30)),
            recovery.id
        )
        XCTAssertEqual(
            PendingRewardReceiptStore.load(defaults: defaults).first?.dropPhase,
            .awaitingAcknowledgement,
            "Only loadBreak may finish the crash hand-off of the reward card"
        )

        let key = AccountScopedLocalState.defaultsKey(
            base: "break.persisted-session",
            defaults: defaults
        )
        let nextDay = selectedAt.addingTimeInterval(86_400)
        XCTAssertNil(FocusPersistence.validBreakID(defaults: defaults, at: nextDay))
        XCTAssertNotNil(
            defaults.data(forKey: key),
            "An expired envelope is left for loadBreak to retire in its usual order"
        )
    }

    func testLegacyRewardBreakUsesExistingRecoveryWithoutReplayingDrop() throws {
        let suite = "PomoGemTests.reward-rest-legacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_640_000)
        let legacy = makeRewardReceipt(createdAt: now, phase: nil)
        XCTAssertTrue(PendingRewardReceiptStore.insert(legacy, defaults: defaults))
        let rest = try XCTUnwrap(FocusPersistence.beginRewardBreak(
            sessionID: legacy.id, defaults: defaults, at: now, uptime: 50_000
        ))
        XCTAssertTrue(PendingRewardReceiptStore.load(defaults: defaults).isEmpty)
        XCTAssertEqual(FocusPersistence.loadBreak(defaults: defaults, at: now), rest)
        var oldObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(rest)
        ) as? [String: Any])
        oldObject.removeValue(forKey: "originatingFocusSessionID")
        let decoded = try JSONDecoder().decode(BreakRecoveryEnvelope.self,
            from: JSONSerialization.data(withJSONObject: oldObject))
        XCTAssertNil(decoded.originatingFocusSessionID)
        XCTAssertEqual(decoded.id, rest.id)
        XCTAssertEqual(decoded.endDate, rest.endDate)
    }

    func testRewardBreakSelectionRespectsNamespaceResetAndOtherActiveBreak() throws {
        let suite = "PomoGemTests.reward-rest-boundaries.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstNamespace = AccountDataNamespace()
        let secondNamespace = AccountDataNamespace()
        let now = Date(timeIntervalSince1970: 1_800_650_000)
        AccountScopedLocalState.activateLocalOnly(namespace: firstNamespace, standardDefaults: defaults)
        let receipt = makeRewardReceipt(createdAt: now, phase: .awaitingAcknowledgement)
        XCTAssertTrue(PendingRewardReceiptStore.insert(receipt, defaults: defaults))
        let rest = try XCTUnwrap(FocusPersistence.beginRewardBreak(
            sessionID: receipt.id, defaults: defaults, at: now, uptime: 60_000
        ))
        let otherReceipt = makeRewardReceipt(createdAt: now.addingTimeInterval(1), phase: .awaitingAcknowledgement)
        XCTAssertTrue(PendingRewardReceiptStore.insert(otherReceipt, defaults: defaults))
        XCTAssertNil(FocusPersistence.beginRewardBreak(
            sessionID: otherReceipt.id, defaults: defaults, at: now.addingTimeInterval(1), uptime: 60_001
        ))
        XCTAssertEqual(FocusPersistence.loadBreak(defaults: defaults, at: now), rest)

        AccountScopedLocalState.beginCloudBoundary(standardDefaults: defaults)
        XCTAssertNil(FocusPersistence.loadBreak(defaults: defaults, at: now))
        XCTAssertNil(FocusPersistence.beginRewardBreak(sessionID: receipt.id, defaults: defaults, at: now, uptime: 60_000))
        AccountScopedLocalState.activateLocalOnly(namespace: secondNamespace, standardDefaults: defaults)
        XCTAssertNil(FocusPersistence.loadBreak(defaults: defaults, at: now))
        XCTAssertNil(FocusPersistence.beginRewardBreak(sessionID: receipt.id, defaults: defaults, at: now, uptime: 60_000))
        AccountScopedLocalState.activateLocalOnly(namespace: firstNamespace, standardDefaults: defaults)
        XCTAssertEqual(FocusPersistence.loadBreak(defaults: defaults, at: now), rest)

        // These are the same account-scoped stores cleared by activity reset
        // and full deletion. An old animation callback has no timer to revive.
        FocusPersistence.clearBreak(defaults: defaults)
        PendingRewardReceiptStore.removeAll(defaults: defaults)
        XCTAssertNil(FocusPersistence.beginRewardBreak(sessionID: receipt.id, defaults: defaults, at: now, uptime: 60_000))
        XCTAssertNil(FocusPersistence.loadBreak(defaults: defaults, at: now))
    }

    private func makeRewardReceipt(
        id: UUID = UUID(),
        createdAt: Date = Date(timeIntervalSince1970: 1_800_500_000),
        phase: PendingRewardDropPhase?
    ) -> PendingRewardReceipt {
        PendingRewardReceipt(
            id: id,
            createdAt: createdAt,
            breakMinutes: 15,
            grams: 450,
            subjectName: "資格勉強",
            colorHex: "#3FA57C",
            weeklyCompletionCount: 7,
            weeklyStudyGrams: 2_150,
            kind: .gold,
            rareRewardDrawCount: 2,
            goldRewardCount: 1,
            prismRewardCount: 0,
            totalPebbleCount: 17,
            totalStudyGrams: 5_450,
            projectionIsLowerBound: true,
            projectionWasCloudUnverified: true,
            projectionCacheStamp: AggregateProjectionCacheStamp(
                namespace: UUID(uuidString: "00000000-0000-0000-0000-000000000991")!,
                verificationEpoch: 9
            ),
            dropPhase: phase
        )
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

    func testSixHourFocusRoundTripsLocalAndCloudRecoveryBeforeAndAfterCompletion() throws {
        let start = Date(timeIntervalSince1970: 1_800_005_000)
        let sessionID = UUID()
        let subject = FocusSubjectSnapshot(id: UUID(), name: "仕事", colorHex: "#3FA57C")
        let anchor = ClockAnchor(wallDate: start, systemUptime: 1_000)
        var engine = PomodoroEngine(selectedDuration: .custom(minutes: 360))
        try engine.startFocus(isPro: true, now: start, sessionID: sessionID)
        FocusPersistence.save(FocusRecoveryEnvelope(
            engine: engine, subject: subject, clockAnchor: anchor,
            pendingCompletion: nil, savedAt: start
        ))

        let running = try XCTUnwrap(FocusPersistence.load())
        XCTAssertEqual(running.engine, engine)
        let halfway = start.addingTimeInterval(10_800)
        XCTAssertEqual(
            FocusPersistence.relaunchAction(for: running, at: halfway),
            .resumeFocus(remainingSeconds: 10_800)
        )
        let portableRunning = try JSONDecoder().decode(
            FocusCloudPayload.self,
            from: JSONEncoder().encode(FocusCloudPayload(envelope: running))
        )
        XCTAssertTrue(portableRunning.isCompatible(with: .running))
        let adopted = portableRunning.recoveryEnvelope(adoptedAt: halfway)
        XCTAssertEqual(adopted.engine.currentSessionID, sessionID)
        XCTAssertEqual(adopted.engine.endDate, start.addingTimeInterval(21_600))
        XCTAssertEqual(adopted.engine.snapshot(at: halfway).remainingSeconds, 10_800)

        engine = running.engine
        let end = start.addingTimeInterval(21_600)
        guard case let .focusCompleted(completion) = engine.advance(at: end) else {
            return XCTFail("Expected the restored six-hour timer to complete")
        }
        FocusPersistence.save(FocusRecoveryEnvelope(
            engine: engine, subject: subject, clockAnchor: anchor,
            pendingCompletion: completion, savedAt: end
        ))
        let pending = try XCTUnwrap(FocusPersistence.load())
        XCTAssertEqual(pending.pendingCompletion?.seconds, 21_600)
        XCTAssertEqual(pending.pendingCompletion?.grams, 3_600)
        XCTAssertEqual(
            FocusPersistence.relaunchAction(for: pending, at: end.addingTimeInterval(60)),
            .commitPendingCompletion
        )
        let portablePending = try JSONDecoder().decode(
            FocusCloudPayload.self,
            from: JSONEncoder().encode(FocusCloudPayload(envelope: pending))
        )
        XCTAssertTrue(portablePending.isCompatible(with: .completionPending))
        XCTAssertEqual(portablePending.pendingCompletion, completion)
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

    func testScheduledNotificationWitnessRoundTripsAndRejectsWrongEndDate() throws {
        let start = Date(timeIntervalSince1970: 1_800_015_000)
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start)
        let endDate = try XCTUnwrap(engine.endDate)
        let envelope = FocusRecoveryEnvelope(
            engine: engine,
            subject: FocusSubjectSnapshot(
                id: UUID(),
                name: "読書",
                colorHex: "#4C8CCF"
            ),
            clockAnchor: ClockAnchor(wallDate: start, systemUptime: 10_000),
            pendingCompletion: nil,
            savedAt: start,
            scheduledCompletionNotificationDeliveryDate: endDate
        )

        FocusPersistence.save(envelope)
        XCTAssertEqual(
            FocusPersistence.load()?.scheduledCompletionNotificationDeliveryDate,
            endDate
        )

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(envelope)
            ) as? [String: Any]
        )
        legacyObject.removeValue(
            forKey: "scheduledCompletionNotificationDeliveryDate"
        )
        let legacy = try JSONDecoder().decode(
            FocusRecoveryEnvelope.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        XCTAssertNil(legacy.scheduledCompletionNotificationDeliveryDate)

        let invalid = FocusRecoveryEnvelope(
            engine: engine,
            subject: envelope.subject,
            clockAnchor: envelope.clockAnchor,
            pendingCompletion: nil,
            savedAt: start,
            scheduledCompletionNotificationDeliveryDate:
                endDate.addingTimeInterval(
                    IntegrationConstants.notificationMinimumDelay
                        + IntegrationConstants
                            .notificationWitnessRegistrationAllowance
                        + 1
                )
        )
        FocusPersistence.save(invalid)
        XCTAssertNil(FocusPersistence.load())
    }

    func testAccountBoundaryInvalidatesFocusAndBreakNotificationWitnesses() throws {
        let suiteName = "PomoGemTests.notification-witness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let namespace = AccountDataNamespace()
        let now = Date.now
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: now)
        let focusEndDate = try XCTUnwrap(engine.endDate)
        let focus = FocusRecoveryEnvelope(
            engine: engine,
            subject: FocusSubjectSnapshot(
                id: UUID(),
                name: "設計",
                colorHex: "#4C8CCF"
            ),
            clockAnchor: ClockAnchor(wallDate: now, systemUptime: 10_000),
            pendingCompletion: nil,
            savedAt: now,
            scheduledCompletionNotificationDeliveryDate: focusEndDate
        )
        let breakEndDate = now.addingTimeInterval(
            TimeInterval(Constants.Timer.shortBreakMinutes * 60)
        )
        let rest = BreakRecoveryEnvelope(
            id: UUID(),
            minutes: Constants.Timer.shortBreakMinutes,
            endDate: breakEndDate,
            scheduledCompletionNotificationDeliveryDate: breakEndDate
        )
        let focusKey = AccountScopedLocalState.defaultsKey(
            base: "focus.persisted-engine",
            namespace: namespace
        )
        let breakKey = AccountScopedLocalState.defaultsKey(
            base: "break.persisted-session",
            namespace: namespace
        )
        defaults.set(try JSONEncoder().encode(focus), forKey: focusKey)
        defaults.set(try JSONEncoder().encode(rest), forKey: breakKey)

        FocusPersistence.clearScheduledCompletionNotificationWitness(
            namespace: namespace,
            defaults: defaults
        )

        let clearedFocus = try JSONDecoder().decode(
            FocusRecoveryEnvelope.self,
            from: try XCTUnwrap(defaults.data(forKey: focusKey))
        )
        let clearedBreak = try JSONDecoder().decode(
            BreakRecoveryEnvelope.self,
            from: try XCTUnwrap(defaults.data(forKey: breakKey))
        )
        XCTAssertNil(clearedFocus.scheduledCompletionNotificationDeliveryDate)
        XCTAssertNil(clearedBreak.scheduledCompletionNotificationDeliveryDate)
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

    func testForwardClockRelaunchDemotesBeforeElapsedCompletion() throws {
        let start = Date(timeIntervalSince1970: 1_800_021_000)
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000225")!
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start, sessionID: sessionID)
        let original = FocusRecoveryEnvelope(
            engine: engine,
            subject: FocusSubjectSnapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000115")!,
                name: "英語",
                colorHex: "#4C8CCF"
            ),
            clockAnchor: ClockAnchor(wallDate: start, systemUptime: 50_000),
            pendingCompletion: nil,
            savedAt: start
        )
        let maliciousNow = start.addingTimeInterval(3_600)

        let prepared = FocusPersistence.preparedForLocalRelaunch(
            original,
            at: maliciousNow,
            uptime: 50_010
        )

        XCTAssertEqual(prepared.engine.currentSource, .timerDemoted)
        XCTAssertEqual(
            FocusPersistence.relaunchAction(for: prepared, at: maliciousNow),
            .finishFocus
        )
        var completing = prepared.engine
        let event = try XCTUnwrap(completing.advance(
            at: maliciousNow,
            observedUptime: 50_010
        ))
        guard case let .focusCompleted(completion) = event else {
            return XCTFail("Expected fail-closed completion")
        }
        XCTAssertEqual(completion.sessionID, sessionID)
        XCTAssertEqual(completion.source, .timerDemoted)
    }

    func testUptimeResetRelaunchDemotionSurvivesAnotherProcessRelaunch() throws {
        let start = Date(timeIntervalSince1970: 1_800_022_000)
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start)
        let original = FocusRecoveryEnvelope(
            engine: engine,
            subject: FocusSubjectSnapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000116")!,
                name: "宅建",
                colorHex: "#3FA57C"
            ),
            clockAnchor: ClockAnchor(wallDate: start, systemUptime: 80_000),
            pendingCompletion: nil,
            savedAt: start
        )
        let restoredAt = start.addingTimeInterval(600)
        let prepared = FocusPersistence.preparedForLocalRelaunch(
            original,
            at: restoredAt,
            uptime: 100
        )
        XCTAssertEqual(prepared.engine.currentSource, .timerDemoted)
        XCTAssertEqual(
            FocusPersistence.relaunchAction(for: prepared, at: restoredAt),
            .resumeFocus(remainingSeconds: 900)
        )

        FocusPersistence.save(prepared)
        let afterSecondRelaunch = try XCTUnwrap(FocusPersistence.load())
        XCTAssertEqual(afterSecondRelaunch.engine.currentSource, .timerDemoted)
        XCTAssertEqual(
            FocusPersistence.preparedForLocalRelaunch(
                afterSecondRelaunch,
                at: restoredAt.addingTimeInterval(60),
                uptime: 160
            ).engine.currentSource,
            .timerDemoted
        )
    }

    func testCrossDeviceAdoptionDemotesActiveFocusAndPersistsThatDecision() throws {
        let start = Date(timeIntervalSince1970: 1_800_023_000)
        var remoteEngine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try remoteEngine.startFocus(isPro: false, now: start)
        let adoptedAt = start.addingTimeInterval(300)
        let offered = FocusRecoveryEnvelope(
            engine: remoteEngine,
            subject: FocusSubjectSnapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000117")!,
                name: "英語",
                colorHex: "#4C8CCF"
            ),
            clockAnchor: ClockAnchor(wallDate: adoptedAt, systemUptime: 1_000),
            pendingCompletion: nil,
            savedAt: adoptedAt
        )

        let adopted = FocusPersistence.preparedForCrossDeviceAdoption(
            offered,
            at: adoptedAt,
            uptime: 1_000,
            demotionReason: .adoptedFromOtherDevice
        )
        XCTAssertEqual(adopted.engine.currentSource, .timerDemoted)
        XCTAssertEqual(adopted.demotionReason, .adoptedFromOtherDevice)

        FocusPersistence.save(adopted)
        let recovered = try XCTUnwrap(FocusPersistence.load())
        XCTAssertEqual(recovered.engine.currentSource, .timerDemoted)
        XCTAssertEqual(recovered.demotionReason, .adoptedFromOtherDevice)
        var completing = recovered.engine
        let scheduledEnd = try XCTUnwrap(completing.endDate)
        let event = try XCTUnwrap(completing.advance(
            at: scheduledEnd,
            observedUptime: 2_200
        ))
        guard case let .focusCompleted(completion) = event else {
            return XCTFail("Expected adopted completion")
        }
        XCTAssertEqual(completion.source, .timerDemoted)
    }

    /// In iCloud mode every trip to the background remounts the container and
    /// restores the timer through the local relaunch path. The notice must
    /// keep the cause observed first, not guess 「再起動など」 on each return.
    func testDemotionReasonSurvivesEveryLaterLocalRelaunch() throws {
        let start = Date(timeIntervalSince1970: 1_800_023_500)
        let subject = FocusSubjectSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000119")!,
            name: "英語",
            colorHex: "#4C8CCF"
        )

        // Adopted from another iPhone, then relaunched twice.
        var remoteEngine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try remoteEngine.startFocus(isPro: false, now: start)
        let adoptedAt = start.addingTimeInterval(120)
        let adopted = FocusPersistence.preparedForCrossDeviceAdoption(
            FocusRecoveryEnvelope(
                engine: remoteEngine,
                subject: subject,
                clockAnchor: ClockAnchor(wallDate: adoptedAt, systemUptime: 5_000),
                pendingCompletion: nil,
                savedAt: adoptedAt
            ),
            at: adoptedAt,
            uptime: 5_000,
            demotionReason: .adoptedFromOtherDevice
        )
        FocusPersistence.save(adopted)
        var relaunched = try XCTUnwrap(FocusPersistence.load())
        for offset in [30.0, 90.0] {
            relaunched = FocusPersistence.preparedForLocalRelaunch(
                relaunched,
                at: adoptedAt.addingTimeInterval(offset),
                uptime: 5_000 + offset
            )
            FocusPersistence.save(relaunched)
            relaunched = try XCTUnwrap(FocusPersistence.load())
            XCTAssertEqual(relaunched.engine.currentSource, .timerDemoted)
            XCTAssertEqual(relaunched.demotionReason, .adoptedFromOtherDevice)
        }

        // A wall-clock jump found at relaunch is named as such, and stays so
        // after the next relaunch even though uptime then looks continuous.
        var localEngine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try localEngine.startFocus(isPro: false, now: start)
        let jumped = FocusPersistence.preparedForLocalRelaunch(
            FocusRecoveryEnvelope(
                engine: localEngine,
                subject: subject,
                clockAnchor: ClockAnchor(wallDate: start, systemUptime: 9_000),
                pendingCompletion: nil,
                savedAt: start
            ),
            at: start.addingTimeInterval(3_600),
            uptime: 9_060
        )
        XCTAssertEqual(jumped.engine.currentSource, .timerDemoted)
        XCTAssertEqual(jumped.demotionReason, .clockChanged)
        FocusPersistence.save(jumped)
        let afterJump = FocusPersistence.preparedForLocalRelaunch(
            try XCTUnwrap(FocusPersistence.load()),
            at: start.addingTimeInterval(3_630),
            uptime: 9_090
        )
        XCTAssertEqual(afterJump.demotionReason, .clockChanged)

        // A reboot (uptime reset) is the one case that says so.
        let rebooted = FocusPersistence.preparedForLocalRelaunch(
            FocusRecoveryEnvelope(
                engine: localEngine,
                subject: subject,
                clockAnchor: ClockAnchor(wallDate: start, systemUptime: 9_000),
                pendingCompletion: nil,
                savedAt: start
            ),
            at: start.addingTimeInterval(300),
            uptime: 40
        )
        XCTAssertEqual(rebooted.demotionReason, .continuityLost)
    }

    func testDemotionReasonIsOptionalAndToleratesUnknownValues() throws {
        let start = Date(timeIntervalSince1970: 1_800_023_700)
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start)
        try engine.demoteCurrentFocus()
        let envelope = FocusRecoveryEnvelope(
            engine: engine,
            subject: FocusSubjectSnapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000120")!,
                name: "宅建",
                colorHex: "#3FA57C"
            ),
            clockAnchor: ClockAnchor(wallDate: start, systemUptime: 7_000),
            pendingCompletion: nil,
            savedAt: start,
            demotionReason: .resumedFromSavedState
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(envelope)
        ) as? [String: Any])

        // An envelope from before the field existed still restores the timer.
        object.removeValue(forKey: "demotionReasonRawValue")
        let legacy = try JSONDecoder().decode(
            FocusRecoveryEnvelope.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(legacy.demotionReason)
        XCTAssertEqual(legacy.engine, envelope.engine)

        // A value this version does not know degrades to no reason instead
        // of discarding the whole recovery.
        object["demotionReasonRawValue"] = "someFutureReason"
        let future = try JSONDecoder().decode(
            FocusRecoveryEnvelope.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(future.demotionReason)
        XCTAssertEqual(future.engine, envelope.engine)

        // The reason is device-local and never reaches the iCloud payload.
        let payload = try FocusCloudPayload(envelope: envelope)
        let payloadObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(payload)
        ) as? [String: Any])
        XCTAssertFalse(payloadObject.keys.contains { $0.localizedCaseInsensitiveContains("demotion") })
    }

    func testLegacyClockAnchorDecodesAsUnverifiableAndActiveRecoveryDemotes() throws {
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

        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start)
        let prepared = FocusPersistence.preparedForLocalRelaunch(
            FocusRecoveryEnvelope(
                engine: engine,
                subject: FocusSubjectSnapshot(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000118")!,
                    name: "宅建",
                    colorHex: "#3FA57C"
                ),
                clockAnchor: anchor,
                pendingCompletion: nil,
                savedAt: start
            ),
            at: start.addingTimeInterval(60),
            uptime: 12_060
        )
        XCTAssertEqual(prepared.engine.currentSource, .timerDemoted)
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

    func testLocalRecoveryRejectsHostileEngineBeforeSnapshotAndRemovesBytes() throws {
        let start = Date(timeIntervalSince1970: 1_800_100_100)
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start, sessionID: UUID())
        let envelope = FocusRecoveryEnvelope(
            engine: engine,
            subject: FocusSubjectSnapshot(
                id: UUID(),
                name: "英語",
                colorHex: "#4C8CCF"
            ),
            clockAnchor: ClockAnchor(wallDate: start, systemUptime: 10),
            pendingCompletion: nil,
            savedAt: start
        )
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope))
                as? [String: Any]
        )
        var encodedEngine = try XCTUnwrap(payload["engine"] as? [String: Any])
        encodedEngine["endDate"] = Double.greatestFiniteMagnitude / 4
        payload["engine"] = encodedEngine
        let hostileData = try JSONSerialization.data(withJSONObject: payload)
        let hostileEnvelope = try JSONDecoder().decode(
            FocusRecoveryEnvelope.self,
            from: hostileData
        )

        XCTAssertEqual(
            FocusPersistence.relaunchAction(for: hostileEnvelope, at: start),
            .discard
        )
        UserDefaults.standard.set(hostileData, forKey: FocusPersistence.key)
        XCTAssertNil(FocusPersistence.load())
        XCTAssertNil(UserDefaults.standard.data(forKey: FocusPersistence.key))
    }

    func testBreakRecoveryRoundTripAndClear() throws {
        let now = Date(timeIntervalSince1970: 1_800_199_100)
        let value = BreakRecoveryEnvelope(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000333")!,
            minutes: 15,
            endDate: Date(timeIntervalSince1970: 1_800_200_000),
            clockAnchor: ClockAnchor(
                wallDate: now,
                systemUptime: 42_000
            )
        )
        FocusPersistence.saveBreak(value, at: now)
        XCTAssertEqual(FocusPersistence.loadBreak(at: now), value)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(value)
            ) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "clockAnchor")
        let legacy = try JSONDecoder().decode(
            BreakRecoveryEnvelope.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        XCTAssertNil(legacy.clockAnchor)
        FocusPersistence.clearBreak()
        XCTAssertNil(FocusPersistence.loadBreak())
    }

    func testCorruptBreakRecoveryIsRejectedAndRemovedWithoutIntegerConversion() throws {
        let suiteName = "PomoGemTests.break-corruption.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_800_210_000)
        let key = AccountScopedLocalState.defaultsKey(
            base: "break.persisted-session",
            defaults: defaults
        )
        let corruptValues = [
            BreakRecoveryEnvelope(
                id: UUID(),
                minutes: Int.max,
                endDate: now.addingTimeInterval(300)
            ),
            BreakRecoveryEnvelope(
                id: UUID(),
                minutes: Constants.Timer.shortBreakMinutes,
                endDate: Date(
                    timeIntervalSinceReferenceDate: Double(Int.max) * 2
                )
            )
        ]

        for value in corruptValues {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
            XCTAssertNil(FocusPersistence.loadBreak(defaults: defaults, at: now))
            XCTAssertNil(defaults.data(forKey: key))
        }
        XCTAssertEqual(
            BreakRecoveryPolicy.remainingSeconds(
                minutes: Int.max,
                endDate: nil,
                at: now
            ),
            0
        )
    }

    func testBreakRecoveryCountdownIsFiniteAndBounded() {
        let now = Date(timeIntervalSince1970: 1_800_220_000)
        XCTAssertEqual(
            BreakRecoveryPolicy.remainingSeconds(
                minutes: Constants.Timer.shortBreakMinutes,
                endDate: nil,
                at: now
            ),
            300
        )
        XCTAssertEqual(
            BreakRecoveryPolicy.remainingSeconds(
                minutes: Constants.Timer.shortBreakMinutes,
                endDate: now.addingTimeInterval(301),
                at: now
            ),
            300,
            "A small backward-clock drift must never extend the configured break"
        )
        XCTAssertEqual(
            BreakRecoveryPolicy.remainingSeconds(
                minutes: Constants.Timer.shortBreakMinutes,
                endDate: now.addingTimeInterval(10_000),
                at: now
            ),
            0
        )
    }

    func testPendingStratumCelebrationStoreIsDurableDeduplicatedAndRemovable() throws {
        let suiteName = "PomoGemTests.stratum.\(UUID().uuidString)"
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
        let suiteName = "PomoGemTests.focus-deferral.\(UUID().uuidString)"
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
