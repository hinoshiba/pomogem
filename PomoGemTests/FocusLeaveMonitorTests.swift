import SwiftUI
import UIKit
import XCTest
@testable import PomoGem

/// The host-level absence from a running focus (F1), driven step by step with
/// an injected clock, protected-data state, passcode, background task,
/// notification and Live Activity fakes. Nothing touches Notification Center,
/// UserDefaults or a device.
@MainActor
final class FocusLeaveMonitorTests: XCTestCase {
    private var harness: LeaveHarness!
    private var monitor: FocusLeaveMonitor!

    override func setUp() async throws {
        try await super.setUp()
        harness = try LeaveHarness()
        monitor = FocusLeaveMonitor(dependencies: harness.dependencies)
    }

    override func tearDown() async throws {
        harness.releaseAll()
        monitor = nil
        harness = nil
        try await super.tearDown()
    }

    // MARK: - Leaving

    func testLeavingWritesTheAbsenceAtOnceAndBooksTheSeries() async throws {
        let leftAt = harness.now
        monitor.handle(.background)
        // Synchronously, before any await could let iOS suspend the process.
        XCTAssertEqual(
            harness.saved?.leaveExcursion,
            FocusLeaveExcursion(sessionID: harness.sessionID, leftAt: leftAt)
        )
        XCTAssertEqual(harness.saved?.engine.phase, .focusing)
        XCTAssertEqual(harness.begun.count, 1)
        XCTAssertEqual(harness.observerCount, 1)

        await harness.waitForSleep()
        XCTAssertEqual(harness.bookedSeries.map { $0.leftAt }, [leftAt])
        XCTAssertEqual(harness.pendingSleeps, [FocusLeavePolicy.lockDetectionWindow])
    }

    func testTheEndOfTheWindowWithoutALockPausesAtTheMomentOfLeaving() async throws {
        let leftAt = harness.now
        monitor.handle(.background)
        await harness.waitForSleep()
        let task = try XCTUnwrap(harness.begun.last)

        harness.now = leftAt.addingTimeInterval(20)
        await harness.finishSleep()

        let saved = try XCTUnwrap(harness.saved)
        XCTAssertEqual(saved.engine.phase, .paused)
        // Left one minute in: 24 of the 25 minutes remain, however long
        // the person stays away.
        XCTAssertEqual(saved.engine.snapshot(at: harness.now).remainingSeconds, 1_440)
        XCTAssertEqual(saved.leavePause?.pausedAt, leftAt)
        XCTAssertNil(saved.leaveExcursion)
        XCTAssertEqual(harness.cancelledCompletions, [harness.sessionID])
        XCTAssertEqual(harness.announcements, [harness.sessionID])
        XCTAssertEqual(harness.liveActivityPauses.map { $0.remaining }, [1_440])
        XCTAssertEqual(harness.withdrawals, 0, "The series says the timer is paused; it stays")
        XCTAssertEqual(harness.ended, [task], "Background time ends after the Live Activity update")
        XCTAssertEqual(harness.observerCount, 0)
    }

    func testALockInsideTheWindowKeepsTheTimerRunningAndWithdrawsTheSeries() async throws {
        let running = try XCTUnwrap(harness.saved)
        monitor.handle(.background)
        await harness.waitForSleep()
        let task = try XCTUnwrap(harness.begun.last)

        harness.now = harness.now.addingTimeInterval(10)
        await harness.postLockNotice()

        XCTAssertEqual(harness.saved, running, "Locking the phone to study never pauses")
        XCTAssertEqual(harness.withdrawals, 1)
        XCTAssertEqual(harness.ended, [task])
        XCTAssertEqual(harness.observerCount, 0)
        XCTAssertTrue(harness.cancelledCompletions.isEmpty)

        // The deadline of the closed window changes nothing.
        await harness.finishSleep()
        XCTAssertEqual(harness.saved, running)
        XCTAssertTrue(harness.announcements.isEmpty)
    }

    func testAMissedNoticeIsCaughtByTheProtectedDataStateAtTheEnd() async throws {
        let running = try XCTUnwrap(harness.saved)
        monitor.handle(.background)
        await harness.waitForSleep()
        harness.protectedDataIsAvailable = false
        harness.now = harness.now.addingTimeInterval(20)
        await harness.finishSleep()
        XCTAssertEqual(harness.saved, running)
        XCTAssertEqual(harness.withdrawals, 1)
    }

    func testAPhoneAlreadyLockedAtBackgroundNeverBooksTheSeries() async throws {
        let running = try XCTUnwrap(harness.saved)
        harness.protectedDataIsAvailable = false
        monitor.handle(.background)
        await harness.settle()
        XCTAssertEqual(harness.saved, running)
        XCTAssertTrue(harness.bookedSeries.isEmpty)
        XCTAssertEqual(harness.ended.count, 1)
    }

    func testWithoutAPasscodeALockCountsAsLeaving() async throws {
        harness.deviceHasPasscode = false
        let leftAt = harness.now
        monitor.handle(.background)
        await harness.waitForSleep()
        // Even a notice (impossible without a passcode) cannot tell them apart.
        harness.protectedDataIsAvailable = false
        harness.now = leftAt.addingTimeInterval(20)
        await harness.finishSleep()
        XCTAssertEqual(harness.saved?.engine.phase, .paused)
        XCTAssertEqual(harness.saved?.leavePause?.pausedAt, leftAt)
    }

    func testBackgroundExpiryPausesAndEndsItsTaskAtOnce() async throws {
        let leftAt = harness.now
        monitor.handle(.background)
        await harness.waitForSleep()
        let task = try XCTUnwrap(harness.begun.last)

        harness.now = leftAt.addingTimeInterval(8)
        try XCTUnwrap(harness.expirations[task])()

        XCTAssertEqual(harness.ended, [task], "The expiration handler must end its task")
        XCTAssertEqual(harness.saved?.engine.phase, .paused)
        XCTAssertEqual(harness.saved?.leavePause?.pausedAt, leftAt)
        await harness.settle()
        XCTAssertEqual(harness.liveActivityPauses.count, 1)
        XCTAssertEqual(harness.ended, [task])
    }

    // MARK: - Returning

    func testReturningWithinTheWindowIsAQuickGlance() async throws {
        let running = try XCTUnwrap(harness.saved)
        monitor.handle(.background)
        await harness.waitForSleep()
        let task = try XCTUnwrap(harness.begun.last)

        harness.now = harness.now.addingTimeInterval(12)
        monitor.handle(.active)

        XCTAssertEqual(harness.saved, running)
        XCTAssertEqual(harness.withdrawals, 1, "Returning withdraws the series before anything else")
        XCTAssertEqual(harness.ended, [task])
        XCTAssertEqual(harness.observerCount, 0)
        XCTAssertTrue(harness.cancelledCompletions.isEmpty)

        // Leftovers of that absence decide nothing.
        await harness.finishSleep()
        await harness.postLockNotice()
        XCTAssertEqual(harness.saved, running)
        XCTAssertTrue(harness.announcements.isEmpty)
    }

    func testReturningAfterASuspendedWindowPausesRetroactively() async throws {
        let leftAt = harness.now
        monitor.handle(.background)
        await harness.waitForSleep()
        // iOS suspended the process before the deadline ran; the person
        // comes back after the planned end.
        harness.now = leftAt.addingTimeInterval(3_600)
        monitor.handle(.active)

        let saved = try XCTUnwrap(harness.saved)
        XCTAssertEqual(saved.engine.phase, .paused, "Never finished and awarded")
        XCTAssertEqual(saved.engine.snapshot(at: harness.now).remainingSeconds, 1_500 - 60)
        XCTAssertEqual(saved.leavePause?.pausedAt, leftAt)
        XCTAssertEqual(harness.withdrawals, 1)
        XCTAssertEqual(harness.cancelledCompletions, [harness.sessionID])
        XCTAssertEqual(harness.announcements, [harness.sessionID])
        await harness.settle()
        XCTAssertEqual(harness.liveActivityPauses.count, 1)
    }

    func testARelaunchedProcessSettlesTheAbsenceItFindsOnReturn() async throws {
        let leftAt = harness.now
        monitor.handle(.background)
        XCTAssertNotNil(harness.saved?.leaveExcursion)

        // The process is killed; a new one starts with no window.
        harness.releaseAll()
        monitor = FocusLeaveMonitor(dependencies: harness.dependencies)
        harness.now = leftAt.addingTimeInterval(600)
        monitor.handle(.active)

        XCTAssertEqual(harness.saved?.engine.phase, .paused)
        XCTAssertEqual(harness.saved?.leavePause?.pausedAt, leftAt)
    }

    func testAnActivationUIKitHasNotConfirmedIsNotAReturn() async throws {
        let running = try XCTUnwrap(harness.saved)
        monitor.handle(.background)
        await harness.waitForSleep()
        let task = try XCTUnwrap(harness.begun.last)

        // iOS 26 can report a brief activation around a Lock press.
        harness.applicationIsActive = false
        monitor.handle(.active)
        XCTAssertEqual(harness.withdrawals, 0)
        XCTAssertTrue(harness.ended.isEmpty)
        XCTAssertNotNil(harness.saved?.leaveExcursion)

        harness.applicationIsActive = true
        harness.now = harness.now.addingTimeInterval(5)
        monitor.handleApplicationDidBecomeActive()
        XCTAssertEqual(harness.saved, running)
        XCTAssertEqual(harness.ended, [task])
    }

    func testInactiveIsNeverAnAbsence() async throws {
        let running = try XCTUnwrap(harness.saved)
        monitor.handle(.inactive)
        await harness.settle()
        XCTAssertEqual(harness.saved, running)
        XCTAssertTrue(harness.begun.isEmpty)
    }

    func testAnEarlierAbsenceCannotDecideANewerOne() async throws {
        monitor.handle(.background)
        await harness.waitForSleep()
        let first = try XCTUnwrap(harness.begun.last)
        let firstExpiry = try XCTUnwrap(harness.expirations[first])

        harness.now = harness.now.addingTimeInterval(5)
        monitor.handle(.active)
        let running = try XCTUnwrap(harness.saved)

        harness.now = harness.now.addingTimeInterval(60)
        let secondLeftAt = harness.now
        monitor.handle(.background)
        await harness.waitForSleep(calls: 2)
        let second = try XCTUnwrap(harness.begun.last)
        XCTAssertNotEqual(first, second)

        // Every leftover of the first absence fires now.
        firstExpiry()
        await harness.finishSleep(at: 0)
        XCTAssertEqual(harness.saved?.engine, running.engine)
        XCTAssertEqual(harness.saved?.leaveExcursion?.leftAt, secondLeftAt)
        XCTAssertEqual(harness.ended, [first])

        harness.now = secondLeftAt.addingTimeInterval(20)
        await harness.finishSleep()
        XCTAssertEqual(harness.saved?.leavePause?.pausedAt, secondLeftAt)
        XCTAssertEqual(harness.ended, [first, second])
    }

    // MARK: - Eligibility

    func testOnlyAnOwnedRunningFocusWithMoreThanAMinuteLeftIsWatched() async throws {
        // Feature off: the older return reminder keeps its behaviour instead.
        harness.isEnabled = false
        monitor.handle(.background)
        XCTAssertTrue(harness.begun.isEmpty)
        monitor.handle(.active)
        harness.isEnabled = true

        // Not this device's timer: nothing registered as the owner.
        let candidate = harness.candidate
        harness.candidate = nil
        monitor.handle(.background)
        XCTAssertTrue(harness.begun.isEmpty)
        harness.candidate = candidate

        // The last minute is left to finish.
        let now = harness.now
        harness.now = harness.start.addingTimeInterval(1_440)
        monitor.handle(.background)
        XCTAssertTrue(harness.begun.isEmpty)
        harness.now = now

        // A manual pause is never touched.
        var paused = try XCTUnwrap(harness.saved)
        try paused.engine.pause(at: now)
        harness.saved = paused
        monitor.handle(.background)
        XCTAssertTrue(harness.begun.isEmpty)
        XCTAssertNil(harness.saved?.leaveExcursion)
        XCTAssertTrue(harness.bookedSeries.isEmpty)
    }

    func testAnAccountBoundaryStopsWatchingButKeepsTheMarker() async throws {
        monitor.handle(.background)
        await harness.waitForSleep()
        let task = try XCTUnwrap(harness.begun.last)
        monitor.cancel()
        XCTAssertEqual(harness.withdrawals, 1)
        XCTAssertEqual(harness.ended, [task])
        XCTAssertEqual(harness.observerCount, 0)
        XCTAssertNotNil(
            harness.saved?.leaveExcursion,
            "If the same account comes back, a reader applies the absence"
        )
        await harness.finishSleep()
        XCTAssertEqual(harness.saved?.engine.phase, .focusing)
    }

    func testASecondBackgroundContinuesTheFirstAbsence() async throws {
        let leftAt = harness.now
        monitor.handle(.background)
        await harness.waitForSleep()
        harness.now = leftAt.addingTimeInterval(4)
        monitor.handle(.inactive)
        monitor.handle(.background)
        XCTAssertEqual(harness.begun.count, 1)
        XCTAssertEqual(harness.saved?.leaveExcursion?.leftAt, leftAt)
    }
}

@MainActor
private final class LeaveHarness {
    let start = Date(timeIntervalSince1970: 1_800_200_000)
    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-00000000F1B0")!
    let key = "test.focus.persisted-engine"
    let center = NotificationCenter()

    var now: Date
    var saved: FocusRecoveryEnvelope?
    var isEnabled = true
    var candidate: FocusLeaveCandidate?
    var deviceHasPasscode = true
    var protectedDataIsAvailable = true
    var applicationIsActive = true

    private(set) var bookedSeries: [(sessionID: UUID, leftAt: Date)] = []
    private(set) var withdrawals = 0
    private(set) var cancelledCompletions: [UUID] = []
    private(set) var liveActivityPauses: [(sessionID: UUID, remaining: Int)] = []
    private(set) var announcements: [UUID] = []
    private(set) var begun: [UIBackgroundTaskIdentifier] = []
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private(set) var expirations: [UIBackgroundTaskIdentifier: @MainActor () -> Void] = [:]
    private(set) var observerCount = 0
    private var nextBackgroundTask = 1
    private var sleeps: [(interval: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = []
    private var sleepCalls = 0

    var pendingSleeps: [TimeInterval] { sleeps.map { $0.interval } }

    init() throws {
        now = start.addingTimeInterval(60)
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start, sessionID: sessionID)
        saved = FocusRecoveryEnvelope(
            engine: engine,
            subject: FocusSubjectSnapshot(id: UUID(), name: "数学", colorHex: "#4C8CCF"),
            clockAnchor: ClockAnchor(wallDate: start, systemUptime: 5_000),
            pendingCompletion: nil,
            savedAt: start
        )
        candidate = FocusLeaveCandidate(
            sessionID: sessionID,
            endDate: start.addingTimeInterval(1_500),
            playsSound: true,
            completionSound: .standard
        )
    }

    var dependencies: FocusLeaveMonitor.Dependencies {
        FocusLeaveMonitor.Dependencies(
            now: { [self] in now },
            isEnabled: { [self] in isEnabled },
            runningFocus: { [self] in candidate },
            persistenceKey: { [self] in key },
            loadEnvelope: { [self] requested in
                requested == key ? saved?.normalizingLeaveMarkers() : nil
            },
            replaceEnvelope: { [self] envelope, requested in
                XCTAssertEqual(requested, key)
                saved = envelope.normalizingLeaveMarkers()
            },
            deviceHasPasscode: { [self] in deviceHasPasscode },
            protectedDataIsAvailable: { [self] in protectedDataIsAvailable },
            applicationIsActive: { [self] in applicationIsActive },
            sleep: { [self] interval in
                await withCheckedContinuation { continuation in
                    sleeps.append((interval, continuation))
                    sleepCalls += 1
                }
            },
            beginBackgroundTask: { [self] expiration in
                let identifier = UIBackgroundTaskIdentifier(rawValue: nextBackgroundTask)
                nextBackgroundTask += 1
                begun.append(identifier)
                expirations[identifier] = expiration
                return identifier
            },
            endBackgroundTask: { [self] in ended.append($0) },
            notificationCenter: LeaveCountingNotificationCenter(center: center) { [self] delta in
                observerCount += delta
            },
            scheduleNudges: { [self] candidate, leftAt in
                bookedSeries.append((candidate.sessionID, leftAt))
            },
            withdrawNudges: { [self] in withdrawals += 1 },
            cancelCompletionKeepingNudges: { [self] in cancelledCompletions.append($0) },
            pauseLiveActivity: { [self] sessionID, remaining in
                liveActivityPauses.append((sessionID, remaining))
            },
            announceAutoPause: { [self] in announcements.append($0) }
        )
    }

    /// Waits until the window has started waiting `calls` times in total.
    func waitForSleep(calls: Int = 1) async {
        for _ in 0 ..< 100 where sleepCalls < calls {
            await settle()
        }
        XCTAssertGreaterThanOrEqual(sleepCalls, calls, "The lock window never started")
    }

    func finishSleep(at index: Int? = nil) async {
        let position = index ?? sleeps.count - 1
        if sleeps.indices.contains(position) {
            sleeps.remove(at: position).continuation.resume()
        }
        await settle()
    }

    func postLockNotice() async {
        center.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
        await settle()
    }

    func settle() async {
        for _ in 0 ..< 20 { await Task.yield() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        for _ in 0 ..< 20 { await Task.yield() }
    }

    func releaseAll() {
        while !sleeps.isEmpty { sleeps.removeFirst().continuation.resume() }
    }
}

/// Forwards to a private center and counts installed observers, so a test
/// can tell a removed observer from one that merely ignored a notice.
private final class LeaveCountingNotificationCenter: NotificationCenter, @unchecked Sendable {
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
