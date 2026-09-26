import XCTest
@testable import PomoGem

/// The AlarmKit wrapper's state machine, driven through a fake client.
@MainActor
final class FocusEndAlarmSchedulerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var client: FakeFocusEndAlarmClient!
    private var clock: Date!
    private var scheduler: FocusEndAlarmScheduler!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "focus-end-alarm-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        client = FakeFocusEndAlarmClient()
        clock = Date(timeIntervalSinceReferenceDate: 10_000)
        scheduler = makeScheduler()
    }

    override func tearDown() async throws {
        client.releaseSchedules()
        defaults.removePersistentDomain(forName: suiteName)
        scheduler = nil
        client = nil
        defaults = nil
        try await super.tearDown()
    }

    private func makeScheduler() -> FocusEndAlarmScheduler {
        FocusEndAlarmScheduler(
            client: client,
            store: FocusEndAlarmBookingStore(defaults: defaults),
            now: { [unowned self] in self.clock }
        )
    }

    private var store: FocusEndAlarmBookingStore { FocusEndAlarmBookingStore(defaults: defaults) }

    // MARK: Booking

    func testBooksOneAlertOnlyAlarmAtTheEndAndPersistsIt() async throws {
        let session = UUID()
        let end = clock.addingTimeInterval(1_500)
        let result = await scheduler.schedule(sessionID: session, phase: .focus, endDate: end, soundFileName: "pomogem-alarm-bell-v1.caf")
        guard case let .booked(booking) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(booking.sessionID, session)
        XCTAssertEqual(booking.fireDate, end)
        XCTAssertTrue(booking.isConfirmed, "AlarmKit accepted it")
        XCTAssertEqual(client.scheduled.count, 1)
        XCTAssertEqual(client.scheduled[booking.alarmID]?.soundFileName, "pomogem-alarm-bell-v1.caf")
        XCTAssertEqual(client.scheduled[booking.alarmID]?.phase, .focus)
        XCTAssertEqual(store.load(), booking)
        XCTAssertNil(scheduler.deliveryWitnessFireDate(sessionID: session), "nothing has rung before the end")
        XCTAssertEqual(makeScheduler().booking, booking, "the booking survives a relaunch")
    }

    func testNothingIsBookedOrAskedWithoutPermission() async {
        for authorization in [AlarmKitAuthorization.unsupported, .notDetermined, .denied] {
            client.authorization = authorization
            let result = await scheduler.schedule(sessionID: UUID(), phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil)
            XCTAssertEqual(result, authorization == .unsupported ? .unsupported : .notAuthorized)
        }
        XCTAssertTrue(client.scheduled.isEmpty)
        XCTAssertEqual(client.authorizationRequests, 0, "a timer start never prompts")
        XCTAssertNil(store.load())
    }

    func testAnEndTooCloseIsLeftToTheInAppAlarm() async {
        let result = await scheduler.schedule(sessionID: UUID(), phase: .breakTime, endDate: clock.addingTimeInterval(3), soundFileName: nil)
        XCTAssertEqual(result, .tooSoon)
        XCTAssertTrue(client.scheduled.isEmpty)
    }

    /// `schedule` replaces any earlier booking even when it books nothing:
    /// a stale loud alarm must never ring at an old end.
    func testASchedulingCallThatBooksNothingStillSilencesTheEarlierAlarm() async throws {
        let refusals: [(AlarmKitAuthorization, TimeInterval, FocusEndAlarmScheduleResult)] = [
            (.denied, 900, .notAuthorized),
            (.notDetermined, 900, .notAuthorized),
            (.unsupported, 900, .unsupported),
            (.authorized, 3, .tooSoon)
        ]
        for (authorization, lead, expected) in refusals {
            client = FakeFocusEndAlarmClient()
            defaults.removePersistentDomain(forName: suiteName)
            scheduler = makeScheduler()
            let session = UUID()
            guard case let .booked(first) = await scheduler.schedule(sessionID: session, phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil) else { return XCTFail() }

            client.authorization = authorization
            let result = await scheduler.schedule(sessionID: session, phase: .focus, endDate: clock.addingTimeInterval(lead), soundFileName: nil)
            XCTAssertEqual(result, expected, "\(authorization)")
            XCTAssertTrue(client.cancelled.contains(first.alarmID), "\(authorization) lead \(lead)")
            XCTAssertTrue(client.scheduled.isEmpty, "\(authorization) lead \(lead)")
            XCTAssertNil(store.load(), "\(authorization) lead \(lead)")
        }
    }

    func testRebookingReplacesTheEarlierAlarm() async throws {
        let session = UUID()
        guard case let .booked(first) = await scheduler.schedule(sessionID: session, phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil) else { return XCTFail() }
        guard case let .booked(second) = await scheduler.schedule(sessionID: session, phase: .focus, endDate: clock.addingTimeInterval(900), soundFileName: nil) else { return XCTFail() }
        XCTAssertNotEqual(first.alarmID, second.alarmID)
        XCTAssertEqual(Array(client.scheduled.keys), [second.alarmID], "exactly one alarm per device")
        XCTAssertEqual(store.load(), second)
    }

    func testACancelDuringAnInFlightBookingRemovesTheLateAlarm() async {
        client.holdsSchedules = true
        let session = UUID()
        let booking = Task { await scheduler.schedule(sessionID: session, phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil) }
        await client.waitForPendingSchedule()
        XCTAssertNotNil(store.load(), "the booking is written before the system call")
        XCTAssertEqual(store.load()?.isConfirmed, false, "and is not confirmed yet")

        scheduler.cancel(sessionID: session)
        XCTAssertNil(store.load())
        client.releaseSchedules()
        let result = await booking.value

        XCTAssertEqual(result, .superseded)
        XCTAssertTrue(client.scheduled.isEmpty, "a paused or abandoned timer must never ring later")
        XCTAssertNil(store.load())
    }

    func testABookingThatFailsAfterACancelIsSupersededNotFailed() async {
        client.holdsSchedules = true
        let session = UUID()
        let booking = Task { await scheduler.schedule(sessionID: session, phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil) }
        await client.waitForPendingSchedule()
        scheduler.cancel(sessionID: session)
        client.scheduleError = FakeFocusEndAlarmClient.Failure()
        client.releaseSchedules()

        let result = await booking.value
        XCTAssertEqual(result, .superseded, "the cancel owns the end: no notification fallback for a paused timer")
        XCTAssertTrue(client.scheduled.isEmpty)
        XCTAssertNil(store.load())
    }

    func testANewerBookingWinsOverAnInFlightOne() async {
        client.holdsSchedules = true
        let session = UUID()
        let older = Task { await scheduler.schedule(sessionID: session, phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil) }
        await client.waitForPendingSchedule()
        let newer = Task { await scheduler.schedule(sessionID: session, phase: .focus, endDate: clock.addingTimeInterval(700), soundFileName: nil) }
        await client.waitForPendingSchedule(count: 2)
        client.releaseSchedules()

        let olderResult = await older.value
        let newerResult = await newer.value
        XCTAssertEqual(olderResult, .superseded)
        guard case let .booked(booking) = newerResult else { return XCTFail("\(newerResult)") }
        XCTAssertEqual(Array(client.scheduled.keys), [booking.alarmID])
        XCTAssertEqual(booking.fireDate, clock.addingTimeInterval(700))
        XCTAssertEqual(store.load(), booking)
    }

    func testAFailedBookingLeavesNoRecordOrAlarm() async {
        client.scheduleError = FakeFocusEndAlarmClient.Failure()
        let result = await scheduler.schedule(sessionID: UUID(), phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil)
        XCTAssertEqual(result, .failed)
        XCTAssertNil(store.load())
        XCTAssertTrue(client.scheduled.isEmpty)
    }

    func testAReconcileWhileABookingIsInFlightLeavesItToTheBooking() async throws {
        client.holdsSchedules = true
        let session = UUID()
        let end = clock.addingTimeInterval(600)
        let booking = Task { await scheduler.schedule(sessionID: session, phase: .focus, endDate: end, soundFileName: nil) }
        await client.waitForPendingSchedule()

        // The host has not decoded the timer yet, and the system does not
        // list the alarm yet: neither makes the booking stale.
        let decision = scheduler.reconcile(owner: nil)
        XCTAssertEqual(decision, FocusEndAlarmReconciliation())
        XCTAssertNotNil(store.load())

        client.releaseSchedules()
        let result = await booking.value
        guard case let .booked(booked) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(Array(client.scheduled.keys), [booked.alarmID])
        XCTAssertEqual(store.load(), booked)
        XCTAssertTrue(client.cancelled.isEmpty)
    }

    // MARK: Cancel, hand-off, acknowledge, erase

    func testCancelOnlyTouchesTheNamedSession() async {
        let session = UUID()
        _ = await scheduler.schedule(sessionID: session, phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil)
        scheduler.cancel(sessionID: UUID())
        XCTAssertEqual(client.scheduled.count, 1)
        scheduler.cancel(sessionID: session)
        XCTAssertTrue(client.scheduled.isEmpty)
        XCTAssertNil(store.load())
    }

    func testCancelWithoutASessionCancelsWhateverIsBooked() async throws {
        guard case let .booked(booking) = await scheduler.schedule(sessionID: UUID(), phase: .breakTime, endDate: clock.addingTimeInterval(600), soundFileName: nil) else { return XCTFail() }
        XCTAssertTrue(scheduler.cancel())
        XCTAssertEqual(client.cancelled, [booking.alarmID])
        XCTAssertTrue(client.scheduled.isEmpty)
        XCTAssertNil(store.load())
        XCTAssertTrue(scheduler.cancel(), "nothing booked is nothing to fail")
    }

    func testAFailedCancelIsRememberedAndRetriedUntilTheAlarmIsGone() async throws {
        let session = UUID()
        guard case let .booked(booking) = await scheduler.schedule(sessionID: session, phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil) else { return XCTFail() }
        client.cancelError = FakeFocusEndAlarmClient.Failure()

        XCTAssertFalse(scheduler.cancel(sessionID: session), "the system still lists it")
        XCTAssertNil(store.load(), "the paused timer no longer owns it")
        XCTAssertEqual(store.pendingCancelIDs, [booking.alarmID])
        XCTAssertNotNil(client.scheduled[booking.alarmID])

        scheduler.retryPendingCancels()
        XCTAssertEqual(store.pendingCancelIDs, [booking.alarmID], "still failing, still pending")

        client.cancelError = nil
        _ = await scheduler.schedule(sessionID: UUID(), phase: .breakTime, endDate: clock.addingTimeInterval(300), soundFileName: nil)
        XCTAssertNil(client.scheduled[booking.alarmID], "the next scheduler call retries it first")
        XCTAssertTrue(store.pendingCancelIDs.isEmpty)
    }

    func testACancelThatFailsForAnAlarmTheSystemNoLongerListsIsDone() async throws {
        let session = UUID()
        guard case let .booked(booking) = await scheduler.schedule(sessionID: session, phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil) else { return XCTFail() }
        client.remove(booking.alarmID)
        XCTAssertTrue(scheduler.cancel(sessionID: session), "not found means nothing can ring")
        XCTAssertTrue(store.pendingCancelIDs.isEmpty)
    }

    func testTheAppActiveJustBeforeTheEndTakesOverFromTheSystemAlarm() async throws {
        let session = UUID()
        let end = clock.addingTimeInterval(600)
        guard case let .booked(booking) = await scheduler.schedule(sessionID: session, phase: .focus, endDate: end, soundFileName: nil) else { return XCTFail() }

        clock = end.addingTimeInterval(-1)
        XCTAssertNil(scheduler.handOffToForeground(sessionID: UUID()), "another session's end stays booked")
        XCTAssertEqual(scheduler.handOffToForeground(sessionID: session), end)
        XCTAssertEqual(client.cancelled, [booking.alarmID])
        XCTAssertTrue(client.scheduled.isEmpty)
        XCTAssertNil(store.load())
        XCTAssertNil(scheduler.deliveryWitnessFireDate(sessionID: session), "it never rang")
    }

    /// Finding: a return after the end must never erase the witness of an
    /// alarm that rang, or the in-app cue plays again over it.
    func testAReturnAfterTheEndNeverHandsOffAndTheWitnessOutlivesTheStop() async throws {
        for returnDelay in [0.0, 0.5, 30] {
            client = FakeFocusEndAlarmClient()
            defaults.removePersistentDomain(forName: suiteName)
            scheduler = makeScheduler()
            let session = UUID()
            let end = clock.addingTimeInterval(600)
            guard case let .booked(booking) = await scheduler.schedule(sessionID: session, phase: .focus, endDate: end, soundFileName: nil) else { return XCTFail() }
            client.states[booking.alarmID] = .alerting
            let now = end.addingTimeInterval(returnDelay)
            clock = now

            XCTAssertNil(scheduler.handOffToForeground(sessionID: session), "+\(returnDelay) s")
            XCTAssertTrue(client.cancelled.isEmpty, "+\(returnDelay) s")
            XCTAssertEqual(scheduler.deliveryWitnessFireDate(sessionID: session), end, "+\(returnDelay) s")

            scheduler.acknowledge(sessionID: session)
            XCTAssertEqual(client.stopped, [booking.alarmID], "returning while it rings is Stop")
            XCTAssertEqual(scheduler.deliveryWitnessFireDate(sessionID: session), end, "the witness survives the Stop")
            let cue = TimerCompletionForegroundFeedbackPolicy.cue(
                recoveredAfterExpiration: false,
                returnedFromBackground: true,
                notificationMayHaveDelivered: AlarmChannelPolicy.externalAlertMayHaveFired(
                    notificationAuthorized: false,
                    notificationDeliveryDate: nil,
                    systemAlarmAuthorized: scheduler.authorization == .authorized,
                    systemAlarmFireDate: scheduler.deliveryWitnessFireDate(sessionID: session),
                    now: now
                ),
                endedAt: end,
                now: now
            )
            XCTAssertEqual(cue, .none, "the system alarm already announced the end (+\(returnDelay) s)")
            clock = end.addingTimeInterval(-600)
        }
    }

    func testTheWitnessNeedsAConfirmedAlarmThatCouldRing() async throws {
        let session = UUID()
        let end = clock.addingTimeInterval(600)
        guard case let .booked(booking) = await scheduler.schedule(sessionID: session, phase: .focus, endDate: end, soundFileName: nil) else { return XCTFail() }

        clock = end.addingTimeInterval(0.2)
        XCTAssertNil(scheduler.deliveryWitnessFireDate(sessionID: session), "still listed as scheduled: it has not rung yet")

        client.remove(booking.alarmID)
        clock = end.addingTimeInterval(20)
        XCTAssertEqual(scheduler.deliveryWitnessFireDate(sessionID: session), end, "rang and was dismissed")
        XCTAssertNil(scheduler.deliveryWitnessFireDate(sessionID: UUID()))

        client.authorization = .denied
        XCTAssertNil(scheduler.deliveryWitnessFireDate(sessionID: session), "alarms turned off in Settings: nothing rang")

        client.authorization = .authorized
        client.alarmsError = FakeFocusEndAlarmClient.Failure()
        XCTAssertNil(scheduler.deliveryWitnessFireDate(sessionID: session), "unknown counts as not rung")
        client.alarmsError = nil

        // The write-ahead record of a process that died inside `schedule`.
        store.save(FocusEndAlarmBooking(alarmID: UUID(), sessionID: session, phase: .focus, fireDate: end))
        XCTAssertNil(scheduler.deliveryWitnessFireDate(sessionID: session), "never confirmed, never a witness")
    }

    func testAReturnWithinAMinuteAfterAlarmsWereTurnedOffIsMarkedOnce() async throws {
        // A break at maximum: AlarmKit booked, no notification. Alarms are
        // turned off in Settings while away; iOS removes the alarm.
        let session = UUID()
        let end = clock.addingTimeInterval(300)
        guard case let .booked(booking) = await scheduler.schedule(sessionID: session, phase: .breakTime, endDate: end, soundFileName: nil) else { return XCTFail() }
        client.authorization = .denied
        client.remove(booking.alarmID)
        clock = end.addingTimeInterval(20)

        let cue = TimerCompletionForegroundFeedbackPolicy.cue(
            recoveredAfterExpiration: false,
            returnedFromBackground: true,
            notificationMayHaveDelivered: AlarmChannelPolicy.externalAlertMayHaveFired(
                notificationAuthorized: true,
                notificationDeliveryDate: nil,
                systemAlarmAuthorized: scheduler.authorization == .authorized,
                systemAlarmFireDate: scheduler.deliveryWitnessFireDate(sessionID: session),
                now: clock
            ),
            endedAt: end,
            now: clock
        )
        XCTAssertEqual(cue, .single)
    }

    func testRecoveryAfterTheEndKeepsTheWitnessOfAnAlarmThatRang() async throws {
        let session = UUID()
        let end = clock.addingTimeInterval(600)
        guard case let .booked(booking) = await scheduler.schedule(sessionID: session, phase: .focus, endDate: end, soundFileName: nil) else { return XCTFail() }
        client.remove(booking.alarmID)
        clock = end.addingTimeInterval(10)

        let result = await scheduler.schedule(sessionID: session, phase: .focus, endDate: end, soundFileName: nil)
        XCTAssertEqual(result, .tooSoon)
        XCTAssertEqual(scheduler.deliveryWitnessFireDate(sessionID: session), end)

        let other = await scheduler.schedule(sessionID: UUID(), phase: .breakTime, endDate: clock.addingTimeInterval(2), soundFileName: nil)
        XCTAssertEqual(other, .tooSoon)
        XCTAssertNil(store.load(), "another session's schedule replaces the old witness")
    }

    func testReturningWhileItRingsStopsItAsStop() async throws {
        let session = UUID()
        let end = clock.addingTimeInterval(600)
        guard case let .booked(booking) = await scheduler.schedule(sessionID: session, phase: .focus, endDate: end, soundFileName: nil) else { return XCTFail() }
        client.states[booking.alarmID] = .alerting
        clock = end.addingTimeInterval(4)
        scheduler.acknowledge(sessionID: session)
        XCTAssertEqual(client.stopped, [booking.alarmID])
        XCTAssertTrue(client.cancelled.isEmpty)
        XCTAssertTrue(client.scheduled.isEmpty)
        XCTAssertEqual(store.load()?.alarmID, booking.alarmID, "kept only as the delivery witness")
    }

    func testAStopThatFailsWhileRingingFallsBackToCancel() async throws {
        let session = UUID()
        let end = clock.addingTimeInterval(600)
        guard case let .booked(booking) = await scheduler.schedule(sessionID: session, phase: .focus, endDate: end, soundFileName: nil) else { return XCTFail() }
        client.states[booking.alarmID] = .alerting
        client.stopError = FakeFocusEndAlarmClient.Failure()
        clock = end.addingTimeInterval(4)

        scheduler.acknowledge(sessionID: session)
        XCTAssertTrue(client.stopped.isEmpty)
        XCTAssertEqual(client.cancelled, [booking.alarmID])
        XCTAssertNil(client.states[booking.alarmID], "nothing is left ringing")
        XCTAssertTrue(store.pendingCancelIDs.isEmpty)
        XCTAssertEqual(scheduler.deliveryWitnessFireDate(sessionID: session), end)
    }

    func testAnEndHandledInTheAppCancelsTheAlarmThatHasNotRung() async throws {
        let session = UUID()
        guard case let .booked(booking) = await scheduler.schedule(sessionID: session, phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil) else { return XCTFail() }
        scheduler.acknowledge(sessionID: UUID())
        XCTAssertEqual(client.scheduled.count, 1, "another session's completion leaves it alone")
        scheduler.acknowledge(sessionID: session)
        XCTAssertEqual(client.cancelled, [booking.alarmID])
        XCTAssertTrue(client.stopped.isEmpty)
        XCTAssertNil(store.load())
    }

    func testCancelAllRemovesEveryAlarmIncludingOrphans() async {
        _ = await scheduler.schedule(sessionID: UUID(), phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil)
        let orphan = UUID()
        client.insert(orphan, state: .alerting)
        let pending = UUID()
        store.setPendingCancelIDs([pending])
        scheduler.cancelAll()
        XCTAssertTrue(client.scheduled.isEmpty)
        XCTAssertTrue(client.cancelled.contains(orphan))
        XCTAssertTrue(client.cancelled.contains(pending))
        XCTAssertNil(store.load())
        XCTAssertTrue(store.pendingCancelIDs.isEmpty)
    }

    func testPermissionIsRequestedOnlyWhileUndecided() async {
        client.authorization = .notDetermined
        client.authorizationAfterRequest = .authorized
        let granted = await scheduler.requestAuthorization()
        XCTAssertEqual(granted, .authorized)
        XCTAssertEqual(client.authorizationRequests, 1)
        client.authorization = .denied
        let denied = await scheduler.requestAuthorization()
        XCTAssertEqual(denied, .denied)
        XCTAssertEqual(client.authorizationRequests, 1, "a denial is respected; Settings is the way back")
    }

    // MARK: Reconcile

    func testAProcessDeathMidBookingIsCleanedUpAtTheNextLaunch() {
        // What a process that died inside `schedule` leaves behind: the
        // write-ahead record and the alarm the system had already registered.
        // The timer did not survive, so nothing owns the end any more.
        let written = FocusEndAlarmBooking(
            alarmID: UUID(),
            sessionID: UUID(),
            phase: .focus,
            fireDate: clock.addingTimeInterval(600)
        )
        store.save(written)
        client.insert(written.alarmID, state: .scheduled)

        let decision = makeScheduler().reconcile(owner: nil)
        XCTAssertEqual(decision.cancelIDs, [written.alarmID])
        XCTAssertTrue(decision.clearsBooking)
        XCTAssertTrue(client.scheduled.isEmpty, "a stale loud alarm must never ring")
        XCTAssertNil(store.load())
    }

    func testAnUnregisteredWriteAheadRecordIsNeverKeptAsAWitness() {
        // The process died before AlarmKit registered anything and came back
        // after the end, still owning the same timer.
        let session = UUID()
        let written = FocusEndAlarmBooking(alarmID: UUID(), sessionID: session, phase: .focus, fireDate: clock.addingTimeInterval(-30))
        store.save(written)

        let decision = makeScheduler().reconcile(owner: FocusEndAlarmOwner(sessionID: session, phase: .focus, endDate: written.fireDate))
        XCTAssertTrue(decision.clearsBooking)
        XCTAssertNil(store.load())
        XCTAssertNil(scheduler.deliveryWitnessFireDate(sessionID: session))
    }

    func testARegisteredButUnconfirmedAlarmIsConfirmedByReconcile() {
        let session = UUID()
        let written = FocusEndAlarmBooking(alarmID: UUID(), sessionID: session, phase: .focus, fireDate: clock.addingTimeInterval(600))
        store.save(written)
        client.insert(written.alarmID, state: .scheduled)

        let decision = makeScheduler().reconcile(owner: FocusEndAlarmOwner(sessionID: session, phase: .focus, endDate: written.fireDate))
        XCTAssertEqual(decision, FocusEndAlarmReconciliation(confirmsBooking: true))
        XCTAssertEqual(store.load()?.isConfirmed, true)
        XCTAssertNotNil(client.scheduled[written.alarmID])
    }

    func testReconcileDecidesNothingWhenTheSystemListCannotBeRead() async throws {
        let session = UUID()
        guard case let .booked(booking) = await scheduler.schedule(sessionID: session, phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil) else { return XCTFail() }
        client.alarmsError = FakeFocusEndAlarmClient.Failure()

        let decision = scheduler.reconcile(owner: FocusEndAlarmOwner(sessionID: session, phase: .focus, endDate: booking.fireDate))
        XCTAssertEqual(decision, FocusEndAlarmReconciliation(), "no rebooking on top of an alarm that may still exist")
        XCTAssertEqual(store.load(), booking)
        XCTAssertTrue(client.cancelled.isEmpty)
    }

    func testReconcileRules() {
        let now = Date(timeIntervalSinceReferenceDate: 50_000)
        let session = UUID()
        let alarmID = UUID()
        let booking = FocusEndAlarmBooking(alarmID: alarmID, sessionID: session, phase: .focus, fireDate: now.addingTimeInterval(300), isConfirmed: true)
        let running = FocusEndAlarmOwner(sessionID: session, phase: .focus, endDate: booking.fireDate)
        let scheduled = [FocusEndAlarmSnapshot(id: alarmID, state: .scheduled)]
        func decide(
            _ booking: FocusEndAlarmBooking?,
            _ alarms: [FocusEndAlarmSnapshot],
            _ owner: FocusEndAlarmOwner?,
            inFlight: Set<UUID> = []
        ) -> FocusEndAlarmReconciliation {
            FocusEndAlarmReconcilePolicy.reconcile(booking: booking, alarms: alarms, owner: owner, now: now, inFlightAlarmIDs: inFlight)
        }

        XCTAssertEqual(decide(booking, scheduled, running), FocusEndAlarmReconciliation(), "the matching alarm stays")
        XCTAssertEqual(
            decide(booking, scheduled, FocusEndAlarmOwner(sessionID: session, phase: .focus, endDate: booking.fireDate.addingTimeInterval(0.5))),
            FocusEndAlarmReconciliation(),
            "sub-second drift is the same end"
        )

        let stale = FocusEndAlarmReconciliation(cancelIDs: [alarmID], clearsBooking: true, ownerNeedsBooking: false)
        XCTAssertEqual(decide(booking, scheduled, nil), stale, "abandoned or adopted elsewhere")
        XCTAssertEqual(decide(booking, scheduled, FocusEndAlarmOwner(sessionID: session, phase: .focus, endDate: nil)), stale, "paused")

        let rebook = FocusEndAlarmReconciliation(cancelIDs: [alarmID], clearsBooking: true, ownerNeedsBooking: true)
        XCTAssertEqual(decide(booking, scheduled, FocusEndAlarmOwner(sessionID: session, phase: .focus, endDate: booking.fireDate.addingTimeInterval(60))), rebook, "re-timed")
        XCTAssertEqual(decide(booking, scheduled, FocusEndAlarmOwner(sessionID: UUID(), phase: .focus, endDate: booking.fireDate)), rebook, "another session")
        XCTAssertEqual(decide(booking, scheduled, FocusEndAlarmOwner(sessionID: session, phase: .breakTime, endDate: booking.fireDate)), rebook, "another phase")

        let alerting = [FocusEndAlarmSnapshot(id: alarmID, state: .alerting)]
        XCTAssertEqual(decide(booking, alerting, nil), FocusEndAlarmReconciliation(), "a ringing alarm is the person's to stop")

        let fired = FocusEndAlarmBooking(alarmID: alarmID, sessionID: session, phase: .focus, fireDate: now.addingTimeInterval(-30), isConfirmed: true)
        XCTAssertEqual(decide(fired, [], nil), FocusEndAlarmReconciliation(), "a dismissed alarm stays as the delivery witness")
        XCTAssertEqual(
            decide(fired, [], FocusEndAlarmOwner(sessionID: session, phase: .focus, endDate: fired.fireDate)),
            FocusEndAlarmReconciliation(),
            "the same, still unresolved session keeps its witness"
        )
        XCTAssertEqual(
            decide(fired, [FocusEndAlarmSnapshot(id: alarmID, state: .scheduled)], FocusEndAlarmOwner(sessionID: session, phase: .focus, endDate: nil)),
            FocusEndAlarmReconciliation(),
            "past its time but not rung yet: the same session's completion resolves it"
        )
        XCTAssertEqual(
            decide(fired, [], FocusEndAlarmOwner(sessionID: UUID(), phase: .breakTime, endDate: now.addingTimeInterval(300))),
            FocusEndAlarmReconciliation(cancelIDs: [alarmID], clearsBooking: true, ownerNeedsBooking: true),
            "a witness for a replaced session is never read again"
        )
        XCTAssertEqual(
            decide(fired, [], FocusEndAlarmOwner(sessionID: UUID(), phase: .focus, endDate: nil)),
            FocusEndAlarmReconciliation(cancelIDs: [alarmID], clearsBooking: true, ownerNeedsBooking: false),
            "a paused newer session needs no alarm"
        )
        var unconfirmedFired = fired
        unconfirmedFired.isConfirmed = false
        XCTAssertEqual(
            decide(unconfirmedFired, [], nil),
            FocusEndAlarmReconciliation(cancelIDs: [alarmID], clearsBooking: true),
            "a write-ahead record AlarmKit never confirmed proves nothing rang"
        )
        XCTAssertEqual(
            decide(booking, [], running),
            FocusEndAlarmReconciliation(cancelIDs: [alarmID], clearsBooking: true, ownerNeedsBooking: true),
            "vanished before its time (permission revoked); cancelling its ID is harmless"
        )

        var unconfirmed = booking
        unconfirmed.isConfirmed = false
        XCTAssertEqual(decide(unconfirmed, scheduled, running), FocusEndAlarmReconciliation(confirmsBooking: true), "listed, so it was registered")
        XCTAssertEqual(decide(unconfirmed, alerting, nil), FocusEndAlarmReconciliation(confirmsBooking: true), "ringing, so it was registered")
        XCTAssertEqual(decide(unconfirmed, [], nil, inFlight: [alarmID]), FocusEndAlarmReconciliation(), "still being booked in this process")

        let orphan = UUID()
        let ringingOrphan = UUID()
        let inFlightOrphan = UUID()
        XCTAssertEqual(
            decide(booking, scheduled + [
                FocusEndAlarmSnapshot(id: orphan, state: .scheduled),
                FocusEndAlarmSnapshot(id: ringingOrphan, state: .alerting),
                FocusEndAlarmSnapshot(id: inFlightOrphan, state: .scheduled)
            ], running, inFlight: [inFlightOrphan]),
            FocusEndAlarmReconciliation(cancelIDs: [orphan]),
            "orphans are cancelled unless they ring or are still being booked"
        )
        XCTAssertEqual(decide(nil, [], running), FocusEndAlarmReconciliation(ownerNeedsBooking: true))
        XCTAssertEqual(decide(nil, [], FocusEndAlarmOwner(sessionID: session, phase: .focus, endDate: nil)), FocusEndAlarmReconciliation())
    }

    func testReconcileAppliesTheDecision() async {
        let session = UUID()
        guard case let .booked(booking) = await scheduler.schedule(sessionID: session, phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil) else { return XCTFail() }
        let decision = scheduler.reconcile(owner: FocusEndAlarmOwner(sessionID: session, phase: .focus, endDate: nil))
        XCTAssertEqual(decision.cancelIDs, [booking.alarmID])
        XCTAssertTrue(client.scheduled.isEmpty)
        XCTAssertNil(store.load())
    }

    func testTheLiveClientIsAlarmKitOnIOS26AndReadingItNeverPrompts() {
        let live = FocusEndAlarmClientFactory.live()
        if #available(iOS 26.0, *) {
            #if canImport(AlarmKit)
            XCTAssertTrue(live is AlarmKitFocusEndAlarmClient)
            XCTAssertNotEqual(live.authorization, .unsupported)
            #endif
        } else {
            XCTAssertEqual(live.authorization, .unsupported)
        }
        XCTAssertTrue(UnsupportedFocusEndAlarmClient().authorization == .unsupported)
        XCTAssertNotNil(
            Bundle.main.object(forInfoDictionaryKey: "NSAlarmKitUsageDescription") as? String,
            "AlarmKit refuses to schedule without its usage description"
        )
    }

    func testTheBookingRecordIsDeviceLocalJSONUnderTheAlarmPrefix() throws {
        XCTAssertEqual(FocusEndAlarmBookingStore.defaultsKey, "alarm.focus-end.booking.v1")
        XCTAssertEqual(FocusEndAlarmBookingStore.pendingCancelsKey, "alarm.focus-end.pending-cancels.v1")
        store.save(FocusEndAlarmBooking(alarmID: UUID(), sessionID: UUID(), phase: .breakTime, fireDate: clock))
        store.setPendingCancelIDs([UUID()])
        XCTAssertNotNil(store.load())
        try CompleteDataDeletionDefaultsCleaner.clear(defaults: defaults, persistentDomainName: suiteName)
        XCTAssertNil(store.load(), "complete data deletion clears the record with the standard domain")
        XCTAssertTrue(store.pendingCancelIDs.isEmpty)
        defaults.set(Data("garbage".utf8), forKey: FocusEndAlarmBookingStore.defaultsKey)
        XCTAssertNil(store.load(), "a corrupt record reads as none")
        XCTAssertEqual(FocusEndAlarmPhase.breakTime.rawValue, "break")

        // A record written before the confirmation flag existed decodes as
        // unconfirmed: never a witness until the system lists it.
        let legacy = #"{"alarmID":"\#(UUID().uuidString)","sessionID":"\#(UUID().uuidString)","phase":"focus","fireDate":0}"#
        defaults.set(Data(legacy.utf8), forKey: FocusEndAlarmBookingStore.defaultsKey)
        XCTAssertEqual(store.load()?.isConfirmed, false)
    }
}

/// An in-memory AlarmKit stand-in. Held schedules model the system call
/// being in flight; an alarm exists only once its schedule completes.
@MainActor
final class FakeFocusEndAlarmClient: FocusEndAlarmClient {
    struct Failure: Error {}
    struct NotFound: Error {}

    var authorization: AlarmKitAuthorization = .authorized
    var authorizationAfterRequest: AlarmKitAuthorization = .authorized
    private(set) var authorizationRequests = 0
    var scheduled: [UUID: FocusEndAlarmRequest] = [:]
    var states: [UUID: FocusEndAlarmSnapshot.State] = [:]
    private(set) var cancelled: [UUID] = []
    private(set) var stopped: [UUID] = []
    var scheduleError: Error?
    /// Cancel fails while the alarm stays registered.
    var cancelError: Error?
    var stopError: Error?
    var alarmsError: Error?
    var holdsSchedules = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var pendingWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func requestAuthorization() async -> AlarmKitAuthorization {
        authorizationRequests += 1
        authorization = authorizationAfterRequest
        return authorization
    }

    func schedule(_ request: FocusEndAlarmRequest) async throws {
        if holdsSchedules {
            await withCheckedContinuation { continuation in
                pending.append(continuation)
                notifyWaiters()
            }
        }
        if let scheduleError { throw scheduleError }
        scheduled[request.alarmID] = request
        states[request.alarmID] = .scheduled
    }

    func cancel(id: UUID) throws {
        if let cancelError { throw cancelError }
        cancelled.append(id)
        guard states.removeValue(forKey: id) != nil else { throw NotFound() }
        scheduled.removeValue(forKey: id)
    }

    func stop(id: UUID) throws {
        if let stopError { throw stopError }
        guard states[id] == .alerting else { throw NotFound() }
        stopped.append(id)
        states.removeValue(forKey: id)
        scheduled.removeValue(forKey: id)
    }

    func alarms() throws -> [FocusEndAlarmSnapshot] {
        if let alarmsError { throw alarmsError }
        return states.map { FocusEndAlarmSnapshot(id: $0.key, state: $0.value) }
    }

    /// The system removed the alarm by itself: it rang and was dismissed, or
    /// alarms were turned off in Settings.
    func remove(_ id: UUID) {
        states.removeValue(forKey: id)
        scheduled.removeValue(forKey: id)
    }

    func insert(_ id: UUID, state: FocusEndAlarmSnapshot.State) {
        states[id] = state
        scheduled[id] = FocusEndAlarmRequest(alarmID: id, phase: .focus, fireDate: .distantFuture, soundFileName: nil)
    }

    func releaseSchedules() {
        let continuations = pending
        pending.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitForPendingSchedule(count: Int = 1) async {
        guard pending.count < count else { return }
        await withCheckedContinuation { continuation in
            pendingWaiters.append((count, continuation))
        }
    }

    private func notifyWaiters() {
        let ready = pendingWaiters.filter { pending.count >= $0.count }
        pendingWaiters.removeAll { pending.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}
