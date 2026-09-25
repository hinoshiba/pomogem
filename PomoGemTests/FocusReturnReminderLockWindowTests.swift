import SwiftUI
import UIKit
import XCTest
@testable import PomoGem

/// The window after a focus goes to the background, driven step by step: the
/// add, the lock notice, the deadline and background expiry are all fakes the
/// test releases in a chosen order.
@MainActor
final class FocusReturnReminderLockWindowTests: XCTestCase {
    private var harness: Harness!
    private var window: FocusReturnReminderLockWindow!

    override func setUp() async throws {
        try await super.setUp()
        harness = Harness()
        window = FocusReturnReminderLockWindow(dependencies: harness.dependencies)
    }

    override func tearDown() async throws {
        // Release anything still suspended so no task outlives the test.
        harness.releaseAll()
        window = nil
        harness = nil
        try await super.tearDown()
    }

    func testALockDuringTheAddWithdrawsTheReminder() async throws {
        let add = harness.expectAdd()
        window.handle(.background)
        await fulfillment(of: [add], timeout: 2)
        let backgroundTask = try XCTUnwrap(harness.begun.last)
        let before = harness.withdrawals

        await postLockNotice()

        XCTAssertEqual(harness.withdrawals, before + 1)
        XCTAssertEqual(harness.ended, [backgroundTask])
        XCTAssertEqual(harness.observerCount, 0)

        // Notification Center accepts the add only after the lock. The window
        // is already closed, so it neither waits nor withdraws again; the
        // manager's own generation removes the late request.
        let sleep = harness.expectSleep(inverted: true)
        harness.finishAdd(accepted: true)
        await fulfillment(of: [sleep], timeout: 0.3)
        XCTAssertEqual(harness.withdrawals, before + 1)
        XCTAssertEqual(harness.ended, [backgroundTask])
    }

    func testALockInsideTheWindowWithdrawsTheReminder() async throws {
        let backgroundTask = try await openAcceptedWindow()
        let before = harness.withdrawals

        await postLockNotice()

        XCTAssertEqual(harness.withdrawals, before + 1)
        XCTAssertEqual(harness.ended, [backgroundTask])
        XCTAssertEqual(harness.observerCount, 0)

        // The deadline of the closed window changes nothing.
        harness.protectedDataIsAvailable = false
        await finishSleepAndSettle()
        XCTAssertEqual(harness.withdrawals, before + 1)
        XCTAssertEqual(harness.ended, [backgroundTask])
    }

    func testTheDeadlineKeepsTheReminderWhileDataIsAvailable() async throws {
        // Going to the Home Screen or another app never sends a lock notice.
        let backgroundTask = try await openAcceptedWindow()
        let before = harness.withdrawals

        harness.protectedDataIsAvailable = true
        await finishSleepAndSettle()

        XCTAssertEqual(harness.withdrawals, before, "The reminder must stay booked")
        XCTAssertEqual(harness.ended, [backgroundTask])
        XCTAssertEqual(harness.observerCount, 0)
        // A notice after the window is not this absence's lock.
        await postLockNotice()
        XCTAssertEqual(harness.withdrawals, before)
    }

    func testTheDeadlineWithdrawsWhenTheLockNoticeWasMissed() async throws {
        let backgroundTask = try await openAcceptedWindow()
        let before = harness.withdrawals

        harness.protectedDataIsAvailable = false
        await finishSleepAndSettle()

        XCTAssertEqual(harness.withdrawals, before + 1)
        XCTAssertEqual(harness.ended, [backgroundTask])
    }

    func testAnEarlierAbsenceCannotWithdrawANewerReminder() async throws {
        let first = try await openAcceptedWindow()
        let firstExpiry = try XCTUnwrap(harness.expirations[first])

        // Back to the app, then away again.
        window.handle(.active)
        XCTAssertEqual(harness.ended, [first])
        XCTAssertEqual(harness.observerCount, 0)
        let second = try await openAcceptedWindow()
        XCTAssertEqual(harness.observerCount, 1)
        let before = harness.withdrawals

        // Every leftover of the first absence fires now.
        firstExpiry()
        harness.protectedDataIsAvailable = false
        harness.finishSleep(at: 0)
        await settle()

        XCTAssertEqual(harness.withdrawals, before, "The first absence must not touch the second")
        XCTAssertEqual(harness.ended, [first], "The second window must keep its background time")
        XCTAssertEqual(harness.observerCount, 1)

        harness.protectedDataIsAvailable = true
        await finishSleepAndSettle()
        XCTAssertEqual(harness.withdrawals, before)
        XCTAssertEqual(harness.ended, [first, second])
    }

    func testANoticeAfterReturningIsIgnored() async throws {
        let backgroundTask = try await openAcceptedWindow()
        window.handle(.active)
        let afterReturn = harness.withdrawals
        XCTAssertEqual(harness.ended, [backgroundTask])

        await postLockNotice()
        XCTAssertEqual(harness.withdrawals, afterReturn)
    }

    func testBackgroundExpiryWithdrawsOnlyAnUnfinishedAdd() async throws {
        let add = harness.expectAdd()
        window.handle(.background)
        await fulfillment(of: [add], timeout: 2)
        let unfinished = try XCTUnwrap(harness.begun.last)
        var before = harness.withdrawals
        try XCTUnwrap(harness.expirations[unfinished])()
        XCTAssertEqual(harness.withdrawals, before + 1)
        XCTAssertEqual(harness.ended, [unfinished])
        harness.finishAdd(accepted: true)
        await settle()

        window.handle(.active)
        let accepted = try await openAcceptedWindow()
        before = harness.withdrawals
        try XCTUnwrap(harness.expirations[accepted])()
        XCTAssertEqual(harness.withdrawals, before, "An accepted reminder must still reach someone who left")
        XCTAssertEqual(harness.ended, [unfinished, accepted])
    }

    // MARK: - Steps

    /// Opens a window whose add was accepted and which is now waiting for a
    /// lock notice. Returns its background task.
    private func openAcceptedWindow() async throws -> UIBackgroundTaskIdentifier {
        let add = harness.expectAdd()
        window.handle(.background)
        await fulfillment(of: [add], timeout: 2)
        let sleep = harness.expectSleep()
        harness.finishAdd(accepted: true)
        await fulfillment(of: [sleep], timeout: 2)
        return try XCTUnwrap(harness.begun.last)
    }

    private func postLockNotice() async {
        harness.center.post(
            name: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil
        )
        // An observer on the main queue may run after this turn.
        await settle()
    }

    private func finishSleepAndSettle() async {
        harness.finishSleep(at: harness.pendingSleepCount - 1)
        await settle()
    }

    private func settle() async {
        for _ in 0 ..< 20 { await Task.yield() }
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        for _ in 0 ..< 20 { await Task.yield() }
    }
}

@MainActor
private final class Harness {
    let center = NotificationCenter()
    var protectedDataIsAvailable = true
    private(set) var withdrawals = 0
    private(set) var begun: [UIBackgroundTaskIdentifier] = []
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private(set) var expirations: [UIBackgroundTaskIdentifier: @MainActor () -> Void] = [:]
    private var nextBackgroundTask = 1
    private var addContinuations: [CheckedContinuation<Bool, Never>] = []
    private var sleepContinuations: [CheckedContinuation<Void, Never>] = []
    private var addStarted: XCTestExpectation?
    private var sleepStarted: XCTestExpectation?
    private var observers = 0

    var pendingSleepCount: Int { sleepContinuations.count }
    /// Lock observers currently installed on `center`.
    var observerCount: Int { observers }

    var dependencies: FocusReturnReminderLockWindow.Dependencies {
        FocusReturnReminderLockWindow.Dependencies(
            schedule: { [self] in
                await withCheckedContinuation { continuation in
                    addContinuations.append(continuation)
                    addStarted?.fulfill()
                    addStarted = nil
                }
            },
            withdraw: { [self] in withdrawals += 1 },
            protectedDataIsAvailable: { [self] in protectedDataIsAvailable },
            sleep: { [self] _ in
                await withCheckedContinuation { continuation in
                    sleepContinuations.append(continuation)
                    sleepStarted?.fulfill()
                    sleepStarted = nil
                }
            },
            beginBackgroundTask: { [self] expiration in
                let identifier = UIBackgroundTaskIdentifier(rawValue: nextBackgroundTask)
                nextBackgroundTask += 1
                begun.append(identifier)
                expirations[identifier] = expiration
                return identifier
            },
            endBackgroundTask: { [self] identifier in ended.append(identifier) },
            notificationCenter: CountingNotificationCenter(center: center) { [self] delta in
                observers += delta
            }
        )
    }

    func expectAdd() -> XCTestExpectation {
        let started = XCTestExpectation(description: "add started")
        addStarted = started
        return started
    }

    func expectSleep(inverted: Bool = false) -> XCTestExpectation {
        let started = XCTestExpectation(description: "lock window started")
        started.isInverted = inverted
        sleepStarted = started
        return started
    }

    func finishAdd(accepted: Bool) {
        guard !addContinuations.isEmpty else { return }
        addContinuations.removeFirst().resume(returning: accepted)
    }

    func finishSleep(at index: Int) {
        guard sleepContinuations.indices.contains(index) else { return }
        sleepContinuations.remove(at: index).resume()
    }

    func releaseAll() {
        addStarted = nil
        sleepStarted = nil
        while !addContinuations.isEmpty { finishAdd(accepted: false) }
        while !sleepContinuations.isEmpty { finishSleep(at: 0) }
    }
}

/// Forwards to a private center and counts installed observers, so a test can
/// tell a removed observer from one that merely ignored a notice.
private final class CountingNotificationCenter: NotificationCenter, @unchecked Sendable {
    private let center: NotificationCenter
    private let count: @MainActor (Int) -> Void

    init(center: NotificationCenter, count: @escaping @MainActor (Int) -> Void) {
        self.center = center
        self.count = count
        super.init()
    }

    override func addObserver(
        forName name: NSNotification.Name?,
        object obj: Any?,
        queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> NSObjectProtocol {
        MainActor.assumeIsolated { count(1) }
        return center.addObserver(forName: name, object: obj, queue: queue, using: block)
    }

    override func removeObserver(_ observer: Any) {
        MainActor.assumeIsolated { count(-1) }
        center.removeObserver(observer)
    }
}
