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
        XCTAssertEqual(client.scheduled.count, 1)
        XCTAssertEqual(client.scheduled[booking.alarmID]?.soundFileName, "pomogem-alarm-bell-v1.caf")
        XCTAssertEqual(client.scheduled[booking.alarmID]?.phase, .focus)
        XCTAssertEqual(store.load(), booking)
        XCTAssertEqual(scheduler.bookedFireDate(sessionID: session), end)
        XCTAssertNil(scheduler.bookedFireDate(sessionID: UUID()))
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

        scheduler.cancel(sessionID: session)
        XCTAssertNil(store.load())
        client.releaseSchedules()
        let result = await booking.value

        XCTAssertEqual(result, .superseded)
        XCTAssertTrue(client.scheduled.isEmpty, "a paused or abandoned timer must never ring later")
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

    // MARK: Cancel, acknowledge, erase

    func testCancelOnlyTouchesTheNamedSession() async {
        let session = UUID()
        _ = await scheduler.schedule(sessionID: session, phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil)
        scheduler.cancel(sessionID: UUID())
        XCTAssertEqual(client.scheduled.count, 1)
        scheduler.cancel(sessionID: session)
        XCTAssertTrue(client.scheduled.isEmpty)
        XCTAssertNil(store.load())
    }

    func testReturningWhileItRingsStopsItAsStop() async throws {
        let session = UUID()
        guard case let .booked(booking) = await scheduler.schedule(sessionID: session, phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil) else { return XCTFail() }
        client.states[booking.alarmID] = .alerting
        scheduler.acknowledge(sessionID: session)
        XCTAssertEqual(client.stopped, [booking.alarmID])
        XCTAssertTrue(client.cancelled.isEmpty)
        XCTAssertNil(store.load())
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
        scheduler.cancelAll()
        XCTAssertTrue(client.scheduled.isEmpty)
        XCTAssertTrue(client.cancelled.contains(orphan))
        XCTAssertNil(store.load())
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

    // MARK: Launch reconcile

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

    func testReconcileRules() {
        let now = Date(timeIntervalSinceReferenceDate: 50_000)
        let session = UUID()
        let alarmID = UUID()
        let booking = FocusEndAlarmBooking(alarmID: alarmID, sessionID: session, phase: .focus, fireDate: now.addingTimeInterval(300))
        let running = FocusEndAlarmOwner(sessionID: session, phase: .focus, endDate: booking.fireDate)
        let scheduled = [FocusEndAlarmSnapshot(id: alarmID, state: .scheduled)]
        func decide(
            _ booking: FocusEndAlarmBooking?,
            _ alarms: [FocusEndAlarmSnapshot],
            _ owner: FocusEndAlarmOwner?
        ) -> FocusEndAlarmReconciliation {
            FocusEndAlarmReconcilePolicy.reconcile(booking: booking, alarms: alarms, owner: owner, now: now)
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

        let fired = FocusEndAlarmBooking(alarmID: alarmID, sessionID: session, phase: .focus, fireDate: now.addingTimeInterval(-30))
        XCTAssertEqual(decide(fired, [], nil), FocusEndAlarmReconciliation(), "a dismissed alarm stays as the delivery witness")
        XCTAssertEqual(
            decide(booking, [], running),
            FocusEndAlarmReconciliation(cancelIDs: [], clearsBooking: true, ownerNeedsBooking: true),
            "vanished before its time (permission revoked)"
        )

        let orphan = UUID()
        let ringingOrphan = UUID()
        XCTAssertEqual(
            decide(booking, scheduled + [FocusEndAlarmSnapshot(id: orphan, state: .scheduled), FocusEndAlarmSnapshot(id: ringingOrphan, state: .alerting)], running),
            FocusEndAlarmReconciliation(cancelIDs: [orphan]),
            "orphans are cancelled unless they ring"
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
        store.save(FocusEndAlarmBooking(alarmID: UUID(), sessionID: UUID(), phase: .breakTime, fireDate: clock))
        XCTAssertNotNil(store.load())
        try CompleteDataDeletionDefaultsCleaner.clear(defaults: defaults, persistentDomainName: suiteName)
        XCTAssertNil(store.load(), "complete data deletion clears the record with the standard domain")
        defaults.set(Data("garbage".utf8), forKey: FocusEndAlarmBookingStore.defaultsKey)
        XCTAssertNil(store.load(), "a corrupt record reads as none")
        XCTAssertEqual(FocusEndAlarmPhase.breakTime.rawValue, "break")
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
        cancelled.append(id)
        guard states.removeValue(forKey: id) != nil else { throw NotFound() }
        scheduled.removeValue(forKey: id)
    }

    func stop(id: UUID) throws {
        guard states[id] == .alerting else { throw NotFound() }
        stopped.append(id)
        states.removeValue(forKey: id)
        scheduled.removeValue(forKey: id)
    }

    func alarms() throws -> [FocusEndAlarmSnapshot] {
        states.map { FocusEndAlarmSnapshot(id: $0.key, state: $0.value) }
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
