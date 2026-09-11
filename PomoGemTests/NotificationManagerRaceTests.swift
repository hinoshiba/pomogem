import UserNotifications
import XCTest
@testable import PomoGem

@MainActor
final class NotificationManagerRaceTests: XCTestCase {
    func testCleanupRetryPreservesRecoveredBreakWithoutRestoredManagerIntent() async throws {
        let recorder = PendingNotificationRecorder()
        let oldManager = recorder.makeManager()
        let oldBreak = UUID()
        let newBreak = UUID()
        _ = try await oldManager.scheduleBreakCompletion(id: oldBreak, endDate: .now.addingTimeInterval(120))
        _ = try await oldManager.scheduleBreakCompletion(id: newBreak, endDate: .now.addingTimeInterval(300))
        let relaunchedManager = recorder.makeManager()
        let cleanup = relaunchedManager.prepareTimerNotificationCleanup(preservingBreak: newBreak)
        await cleanup()
        XCTAssertEqual(recorder.pending.count, 1)
        XCTAssertTrue(recorder.pending.keys.first?.hasSuffix(newBreak.uuidString.lowercased()) == true)

        // A genuinely newer reset must still retire that break.
        await relaunchedManager.cancelAllTimerNotifications()
        XCTAssertTrue(recorder.pending.isEmpty)
    }

    func testAcceptedResetCleanupPreservesTimerCreatedBeforeItsDeferredExecution() async throws {
        let recorder = PendingNotificationRecorder()
        let manager = recorder.makeManager()
        let oldSession = UUID()
        let nextSession = UUID()
        _ = try await manager.scheduleFocusCompletion(sessionID: oldSession, endDate: .now.addingTimeInterval(120))
        let cleanup = manager.prepareTimerNotificationCleanup()
        _ = try await manager.scheduleFocusCompletion(sessionID: nextSession, endDate: .now.addingTimeInterval(300))
        await cleanup()
        XCTAssertEqual(recorder.pending.count, 1)
        XCTAssertTrue(recorder.pending.keys.first?.hasSuffix(nextSession.uuidString.lowercased()) == true)
    }

    func testResetRetryPreservesCurrentEpochTimerEvenBeforeRestoringManagerIntent() async throws {
        let recorder = PendingNotificationRecorder()
        let oldManager = recorder.makeManager()
        let oldSession = UUID()
        let currentSession = UUID()
        _ = try await oldManager.scheduleFocusCompletion(sessionID: oldSession, endDate: .now.addingTimeInterval(120))
        _ = try await oldManager.scheduleFocusCompletion(sessionID: currentSession, endDate: .now.addingTimeInterval(300))
        // Native pending requests survive process termination; process-local
        // registration intents do not. Recovery supplies the durable focus ID.
        let relaunchedManager = recorder.makeManager()
        let cleanup = relaunchedManager.prepareTimerNotificationCleanup(preserving: currentSession)
        await cleanup()
        XCTAssertEqual(recorder.pending.count, 1)
        XCTAssertTrue(recorder.pending.keys.first?.hasSuffix(currentSession.uuidString.lowercased()) == true)
    }

    func testFailedTimerReplacementCannotEscapeDelayedGlobalCancellation() async throws {
        for isBreak in [false, true] {
            let recorder = PendingNotificationRecorder()
            let manager = recorder.makeManager()
            let id = UUID()
            let schedule: (Date) async throws -> TimerCompletionNotificationScheduleResult = { end in
                if isBreak {
                    return try await manager.scheduleBreakCompletion(id: id, endDate: end)
                }
                return try await manager.scheduleFocusCompletion(sessionID: id, endDate: end)
            }
            _ = try await schedule(.now.addingTimeInterval(120))
            recorder.queryStarted = expectation(description: "cleanup query started, break=\(isBreak)")
            let cleanup = Task { await manager.cancelAllTimerNotifications() }
            await fulfillment(of: [recorder.queryStarted!], timeout: 3)
            recorder.failAddNumber = 2
            do {
                _ = try await schedule(.now.addingTimeInterval(300))
                XCTFail("The replacement must fail")
            } catch PendingNotificationRecorder.AddError.injected { }
            recorder.finishQuery()
            await cleanup.value
            XCTAssertTrue(recorder.pending.isEmpty, "A failed replacement cannot protect the old trigger")
        }
    }

    func testLeavingSettingsDoesNotEraseEnabledPassiveNotifications() async throws {
        let recorder = PendingNotificationRecorder()
        let manager = recorder.makeManager()
        try await schedulePassive(manager, hour: 21)
        recorder.addStarted = expectation(description: "cancelled add started")
        let old = Task { try await self.schedulePassive(manager, hour: 9) }
        await fulfillment(of: [recorder.addStarted!], timeout: 3)
        let waiterFinished = expectation(description: "cancelled Settings waiter released")
        let waiter = Task {
            _ = try? await old.value
            waiterFinished.fulfill()
        }
        old.cancel()
        await fulfillment(of: [waiterFinished], timeout: 2)
        recorder.scheduleCompleted = expectation(description: "accepted passive schedule finishes")
        recorder.targetAddCount = 2 * IntegrationConstants.passiveNotificationHorizonDays
        recorder.finishAdd()
        await fulfillment(of: [recorder.scheduleCompleted!], timeout: 3)
        await waiter.value
        XCTAssertEqual(recorder.pending.count, IntegrationConstants.passiveNotificationHorizonDays)
        XCTAssertTrue(recorder.pending.values.allSatisfy {
            ($0.trigger as? UNCalendarNotificationTrigger)?.dateComponents.hour == 9
        })
    }

    func testDelayedPassiveCleanupCannotDeleteTheNewSchedule() async throws {
        let recorder = PendingNotificationRecorder()
        let manager = recorder.makeManager()
        try await schedulePassive(manager, hour: 9)
        recorder.queryStarted = expectation(description: "old passive cleanup query started")
        let cleanup = Task { await manager.cancelPassiveNotifications() }
        await fulfillment(of: [recorder.queryStarted!], timeout: 3)
        try await schedulePassive(manager, hour: 21)
        recorder.finishQuery()
        await cleanup.value
        XCTAssertEqual(recorder.pending.count, IntegrationConstants.passiveNotificationHorizonDays)
        XCTAssertTrue(recorder.pending.values.allSatisfy {
            ($0.trigger as? UNCalendarNotificationTrigger)?.dateComponents.hour == 21
        })
    }

    func testPassiveAddFailureRollsBackOnlyItsPartialSchedule() async throws {
        let recorder = PendingNotificationRecorder()
        let manager = recorder.makeManager()
        recorder.failAddNumber = 2
        do {
            try await schedulePassive(manager, hour: 9)
            XCTFail("The injected add failure must be reported")
        } catch PendingNotificationRecorder.AddError.injected { }
        XCTAssertTrue(recorder.pending.isEmpty)
        try await schedulePassive(manager, hour: 21)
        XCTAssertEqual(recorder.pending.count, IntegrationConstants.passiveNotificationHorizonDays)
    }

    func testPassiveCancellationRemovesAnAddThatFinishesLate() async throws {
        let recorder = PendingNotificationRecorder()
        let manager = recorder.makeManager()
        recorder.addStarted = expectation(description: "old add started")
        let old = Task { try await self.schedulePassive(manager, hour: 9) }
        await fulfillment(of: [recorder.addStarted!], timeout: 3)
        await manager.cancelPassiveNotifications()
        recorder.finishAdd()
        try await old.value
        XCTAssertTrue(recorder.pending.isEmpty, "An old add must not restore disabled notifications")
    }

    func testLatestPassiveScheduleWinsWhenOldAddFinishesLast() async throws {
        let recorder = PendingNotificationRecorder()
        let manager = recorder.makeManager()
        recorder.addStarted = expectation(description: "old add started")
        let old = Task { try await self.schedulePassive(manager, hour: 9) }
        await fulfillment(of: [recorder.addStarted!], timeout: 3)
        let newerStarted = expectation(description: "new schedule started")
        let newer = Task {
            newerStarted.fulfill()
            try await self.schedulePassive(manager, hour: 21)
        }
        await fulfillment(of: [newerStarted], timeout: 3)
        recorder.finishAdd()
        try await old.value
        try await newer.value
        XCTAssertEqual(recorder.pending.count, IntegrationConstants.passiveNotificationHorizonDays)
        for request in recorder.pending.values {
            XCTAssertEqual((request.trigger as? UNCalendarNotificationTrigger)?.dateComponents.hour, 21)
        }
        XCTAssertEqual(recorder.maximumConcurrentAdds, 1)
    }

    func testAccountBoundaryInvalidatesPassiveWorkAndRejectsNewRequests() async throws {
        let recorder = PendingNotificationRecorder()
        let manager = recorder.makeManager()
        recorder.addStarted = expectation(description: "old account add started")
        let old = Task { try await self.schedulePassive(manager, hour: 9) }
        await fulfillment(of: [recorder.addStarted!], timeout: 3)
        manager.suspendTimerSchedulingForAccountBoundary()
        recorder.finishAdd()
        try await old.value
        try await schedulePassive(manager, hour: 21)
        XCTAssertTrue(recorder.pending.isEmpty)
        manager.resumeTimerSchedulingAfterAccountBoundary()
        try await schedulePassive(manager, hour: 21)
        XCTAssertEqual(recorder.pending.count, IntegrationConstants.passiveNotificationHorizonDays)
    }

    func testDelayedTimerCleanupDoesNotDeleteARescheduledCompletion() async throws {
        let recorder = PendingNotificationRecorder()
        let manager = recorder.makeManager()
        let session = UUID()
        _ = try await manager.scheduleFocusCompletion(sessionID: session, endDate: .now.addingTimeInterval(120))
        recorder.queryStarted = expectation(description: "old cleanup query started")
        let cleanup = Task { await manager.cancelAllTimerNotifications() }
        await fulfillment(of: [recorder.queryStarted!], timeout: 3)
        _ = try await manager.scheduleFocusCompletion(sessionID: session, endDate: .now.addingTimeInterval(300))
        recorder.finishQuery()
        await cleanup.value
        XCTAssertEqual(recorder.pending.count, 1, "A stale identifier snapshot cannot erase its replacement")
        let request = try XCTUnwrap(recorder.pending.values.first)
        XCTAssertGreaterThan(try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger).timeInterval, 250)
    }

    func testCancelledAuthorizationWaiterReturnsBeforeCallbackAndCannotOverwriteNewStatus() async {
        let started = expectation(description: "authorization query started")
        let finished = expectation(description: "cancelled query waiter returns")
        let lateReturned = expectation(description: "old native query returned")
        let gate = SuspendedNotificationCallback<UNAuthorizationStatus>(started: started)
        var calls = 0
        let client = FocusReturnReminderNotificationClient(
            authorizationStatus: {
                calls += 1
                if calls == 1 {
                    let result = await gate.wait()
                    lateReturned.fulfill()
                    return result
                }
                return .denied
            },
            add: { _ in }, removePending: { _ in }, removeDelivered: { _ in }
        )
        let manager = NotificationManager(focusReturnReminderClient: client)
        let old = Task {
            _ = await manager.refreshAuthorizationStatus()
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        old.cancel()
        await fulfillment(of: [finished], timeout: 2)
        let newest = await manager.refreshAuthorizationStatus()
        XCTAssertEqual(newest, .denied)
        gate.release(.authorized)
        await fulfillment(of: [lateReturned], timeout: 2)
        await old.value
        XCTAssertEqual(manager.authorizationStatus, .denied)
    }

    func testCancelledPermissionRequestDoesNotContinueAfterLateGrant() async {
        let started = expectation(description: "permission request started")
        let finished = expectation(description: "cancelled permission waiter returns")
        let gate = SuspendedNotificationCallback<Bool>(started: started)
        var statusQueries = 0
        let client = FocusReturnReminderNotificationClient(
            authorizationStatus: { statusQueries += 1; return .authorized },
            add: { _ in }, removePending: { _ in }, removeDelivered: { _ in }
        )
        let manager = NotificationManager(
            focusReturnReminderClient: client,
            authorizationRequest: { await gate.wait() }
        )
        let old = Task {
            let granted = await manager.requestAuthorization()
            finished.fulfill()
            return granted
        }
        await fulfillment(of: [started], timeout: 2)
        old.cancel()
        await fulfillment(of: [finished], timeout: 2)
        gate.release(true)
        let granted = await old.value
        XCTAssertFalse(granted)
        XCTAssertEqual(statusQueries, 0)
        XCTAssertEqual(manager.authorizationStatus, .notDetermined)
        XCTAssertNil(manager.lastErrorDescription)
    }

    func testCancelledTimerWaiterKeepsOldAddInReplacementChain() async throws {
        let recorder = PendingNotificationRecorder()
        let manager = recorder.makeManager()
        let id = UUID()
        recorder.addStarted = expectation(description: "first add started")
        let finished = expectation(description: "cancelled timer waiter returns")
        let old = Task {
            defer { finished.fulfill() }
            do {
                _ = try await manager.scheduleFocusCompletion(sessionID: id, endDate: .now.addingTimeInterval(120))
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        await fulfillment(of: [recorder.addStarted!], timeout: 2)
        old.cancel()
        await fulfillment(of: [finished], timeout: 2)
        let racedAdd = expectation(description: "replacement cannot overtake held add")
        racedAdd.isInverted = true
        recorder.additionalAddStarted = racedAdd
        let replacement = Task {
            try await manager.scheduleFocusCompletion(sessionID: id, endDate: .now.addingTimeInterval(300))
        }
        await fulfillment(of: [racedAdd], timeout: 0.1)
        recorder.additionalAddStarted = nil
        recorder.finishAdd()
        let wasCancelled = await old.value
        XCTAssertTrue(wasCancelled)
        _ = try await replacement.value
        XCTAssertEqual(recorder.maximumConcurrentAdds, 1)
        let request = try XCTUnwrap(recorder.pending.values.first)
        XCTAssertGreaterThan(try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger).timeInterval, 250)
    }

    private func schedulePassive(_ manager: NotificationManager, hour: Int) async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        try await manager.synchronizePassiveNotifications(
            dailyReminderEnabled: true, wrappedEnabled: false,
            hour: hour, minute: 0, playsSound: false,
            now: Date(timeIntervalSince1970: 1_788_000_000), calendar: calendar
        )
    }
}

@MainActor
private final class PendingNotificationRecorder {
    enum AddError: Error { case injected }
    var pending: [String: UNNotificationRequest] = [:]
    var failAddNumber: Int?
    var addStarted: XCTestExpectation?
    var additionalAddStarted: XCTestExpectation?
    var queryStarted: XCTestExpectation?
    var scheduleCompleted: XCTestExpectation?
    var targetAddCount: Int?
    private var addContinuation: CheckedContinuation<Void, Never>?
    private var queryContinuation: CheckedContinuation<Void, Never>?
    private var didHoldAdd = false
    private var didHoldQuery = false
    private var concurrentAdds = 0
    private var addCount = 0
    private(set) var maximumConcurrentAdds = 0

    func makeManager() -> NotificationManager {
        let client = NotificationRequestClient(
            add: { request in
                self.addCount += 1
                if self.addCount > 1 { self.additionalAddStarted?.fulfill() }
                self.concurrentAdds += 1
                self.maximumConcurrentAdds = max(self.maximumConcurrentAdds, self.concurrentAdds)
                defer { self.concurrentAdds -= 1 }
                if let started = self.addStarted, !self.didHoldAdd {
                    self.didHoldAdd = true
                    await withCheckedContinuation {
                        self.addContinuation = $0
                        started.fulfill()
                    }
                }
                if self.addCount == self.failAddNumber { throw AddError.injected }
                self.pending[request.identifier] = request
                if self.addCount == self.targetAddCount { self.scheduleCompleted?.fulfill() }
            },
            pending: {
                let snapshot = Array(self.pending.values)
                if let started = self.queryStarted, !self.didHoldQuery {
                    self.didHoldQuery = true
                    await withCheckedContinuation {
                        self.queryContinuation = $0
                        started.fulfill()
                    }
                }
                return snapshot
            },
            removePending: { ids in
                for id in ids { self.pending.removeValue(forKey: id) }
            }
        )
        return NotificationManager(
            requestClient: client,
            focusReturnReminderClient: FocusReturnReminderNotificationClient(
                authorizationStatus: { .authorized }, add: client.add,
                removePending: client.removePending, removeDelivered: { _ in }
            )
        )
    }

    func finishAdd() {
        let continuation = addContinuation
        addContinuation = nil
        continuation?.resume()
    }

    func finishQuery() {
        let continuation = queryContinuation
        queryContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class SuspendedNotificationCallback<Value> {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Value, Never>?
    private var releasedValue: Value?

    init(started: XCTestExpectation) { self.started = started }

    func wait() async -> Value {
        started.fulfill()
        if let releasedValue { return releasedValue }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ value: Value) {
        releasedValue = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}
