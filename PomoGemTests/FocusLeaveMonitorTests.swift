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
        XCTAssertEqual(
            harness.events,
            [.liveActivityPaused(1_440), .ended(task)],
            "Background time ends after the Live Activity update"
        )
        XCTAssertEqual(harness.observerCount, 0)
    }

    func testExpiryWhileTheLiveActivityUpdateRunsStillEndsTheTaskOnce() async throws {
        harness.holdsLiveActivityUpdates = true
        let leftAt = harness.now
        monitor.handle(.background)
        await harness.waitForSleep()
        let task = try XCTUnwrap(harness.begun.last)

        harness.now = leftAt.addingTimeInterval(20)
        await harness.finishSleep()
        XCTAssertEqual(harness.saved?.engine.phase, .paused)
        XCTAssertTrue(harness.ended.isEmpty, "Held for the Live Activity update")

        // ActivityKit stalls until iOS takes the background time back.
        try XCTUnwrap(harness.expirations[task])()
        XCTAssertEqual(harness.ended, [task], "An expiration handler must end its own task")

        await harness.releaseLiveActivityUpdates()
        XCTAssertEqual(harness.liveActivityPauses.map { $0.remaining }, [1_440])
        XCTAssertEqual(harness.ended, [task], "Ended exactly once")
        XCTAssertEqual(harness.saved?.leavePause?.pausedAt, leftAt)
    }

    func testAPauseAReaderAppliedFirstStillGetsItsSideEffects() async throws {
        let leftAt = harness.now
        monitor.handle(.background)
        await harness.waitForSleep()
        let task = try XCTUnwrap(harness.begun.last)

        // A relaunch or remount path read the saved timer after the window
        // and paused it before the host's deadline ran.
        let away = try XCTUnwrap(harness.saved)
        harness.saved = FocusLeaveTransition.pausedForLeaving(
            away, decidedAt: leftAt.addingTimeInterval(21)
        )
        harness.now = leftAt.addingTimeInterval(21)
        await harness.finishSleep()

        XCTAssertEqual(harness.saved?.leavePause?.pausedAt, leftAt)
        XCTAssertEqual(harness.cancelledCompletions, [harness.sessionID], "No end alert for a paused focus")
        XCTAssertEqual(harness.announcements, [harness.sessionID])
        XCTAssertEqual(harness.events, [.liveActivityPaused(1_440), .ended(task)])
        XCTAssertEqual(harness.withdrawals, 0)
    }

    func testAReturnAfterAReaderPausedTheWatchedAbsenceAppliesItsSideEffects() async throws {
        let leftAt = harness.now
        monitor.handle(.background)
        await harness.waitForSleep()
        let task = try XCTUnwrap(harness.begun.last)

        // Suspended before the deadline; a reader applied the pause.
        let away = try XCTUnwrap(harness.saved)
        harness.now = leftAt.addingTimeInterval(900)
        harness.saved = FocusLeaveTransition.pausedForLeaving(away, decidedAt: harness.now)
        monitor.handle(.active)

        XCTAssertEqual(harness.saved?.engine.phase, .paused)
        XCTAssertEqual(harness.cancelledCompletions, [harness.sessionID])
        XCTAssertEqual(harness.announcements, [harness.sessionID])
        XCTAssertEqual(harness.ended, [task])
        await harness.settle()
        XCTAssertEqual(harness.liveActivityPauses.map { $0.remaining }, [1_440])
    }

    func testAWindowEndingWithNothingToPauseWithdrawsTheSeries() async throws {
        let replacements: [FocusRecoveryEnvelope?] = [nil, try otherSessionEnvelope()]
        for replacement in replacements {
            harness.releaseAll()
            harness = try LeaveHarness()
            monitor = FocusLeaveMonitor(dependencies: harness.dependencies)
            monitor.handle(.background)
            await harness.waitForSleep()
            let task = try XCTUnwrap(harness.begun.last)

            // Retired or replaced while the person was away.
            harness.saved = replacement
            harness.now = harness.now.addingTimeInterval(20)
            await harness.finishSleep()

            XCTAssertEqual(harness.withdrawals, 1, "「タイマーを一時停止しました」 would be false")
            XCTAssertTrue(harness.announcements.isEmpty)
            XCTAssertTrue(harness.cancelledCompletions.isEmpty)
            XCTAssertTrue(harness.liveActivityPauses.isEmpty)
            XCTAssertEqual(harness.ended, [task])
            XCTAssertEqual(harness.saved, replacement)
        }
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

        // The pending pause is cancelled: no pause written, the marker gone.
        let saved = try XCTUnwrap(harness.saved)
        XCTAssertEqual(saved, running)
        XCTAssertEqual(saved.engine.phase, .focusing)
        XCTAssertNil(saved.leaveExcursion, "The absence marker is cleared")
        XCTAssertNil(saved.leavePause, "No pause is written")
        XCTAssertEqual(harness.withdrawals, 1, "Returning withdraws the series before anything else")
        XCTAssertEqual(harness.ended, [task])
        XCTAssertEqual(harness.observerCount, 0)
        XCTAssertEqual(harness.runningSleeps, 0, "The window's wait ends with it")
        XCTAssertTrue(harness.cancelledCompletions.isEmpty)
        XCTAssertTrue(harness.announcements.isEmpty)
        XCTAssertTrue(harness.liveActivityPauses.isEmpty)

        // Leftovers of that absence decide nothing.
        await harness.finishSleep()
        await harness.postLockNotice()
        XCTAssertEqual(harness.saved, running)
        XCTAssertTrue(harness.announcements.isEmpty)
        XCTAssertTrue(harness.liveActivityPauses.isEmpty)
        XCTAssertEqual(harness.withdrawals, 1)
    }

    /// Pre-PR audit ask: a return inside the 20-second window cancels the
    /// pending pause. Against a real NotificationManager on fake clients: no
    /// pause and no leave marker are written, every request of the series is
    /// removed from both the pending and the delivered lists (none can have
    /// arrived: the first is due after the window), the still-running focus
    /// keeps its end alert, and nothing the window left behind decides later.
    func testAReturnInsideTheWindowWritesNoPauseAndLeavesNoNudge() async throws {
        let notifications = try FocusLeaveNudgeFixture()
        defer { notifications.tearDown() }
        let manager = notifications.manager!
        let endDate = harness.start.addingTimeInterval(1_500)
        _ = try await manager.scheduleFocusCompletion(sessionID: harness.sessionID, endDate: endDate)
        manager.registerFocusReturnReminder(
            sessionID: harness.sessionID, endDate: endDate, playsSound: true
        )
        monitor = FocusLeaveMonitor(
            dependencies: harness.dependencies(notificationsFrom: .live(notifications: manager))
        )
        let running = try XCTUnwrap(harness.saved)
        let completionIdentifiers = Set(notifications.pending.keys.filter {
            $0.hasPrefix("pomogem.focus.complete.")
        })
        XCTAssertEqual(completionIdentifiers.count, 1)
        XCTAssertGreaterThan(
            try XCTUnwrap(FocusLeavePolicy.nudgeOffsets.first),
            FocusLeavePolicy.lockDetectionWindow,
            "No request of the series is due inside the window"
        )

        let leftAt = harness.now
        monitor.handle(.background)
        await harness.waitForSleep()
        let task = try XCTUnwrap(harness.begun.last)
        XCTAssertNotNil(harness.saved?.leaveExcursion)
        XCTAssertEqual(
            Set(notifications.pending.keys),
            Set(FocusLeavePolicy.nudgeIdentifiers).union(completionIdentifiers)
        )

        // Back one second before the window would have decided.
        harness.now = leftAt.addingTimeInterval(FocusLeavePolicy.lockDetectionWindow - 1)
        monitor.handle(.active)

        let saved = try XCTUnwrap(harness.saved)
        XCTAssertEqual(saved, running, "Nothing about the focus changed")
        XCTAssertEqual(saved.engine.phase, .focusing)
        XCTAssertNil(saved.leaveExcursion, "The absence marker is cleared")
        XCTAssertNil(saved.leavePause, "No pause is written")
        XCTAssertEqual(
            Set(notifications.pending.keys),
            completionIdentifiers,
            "No request of the series is left pending; the running focus keeps its end alert"
        )
        XCTAssertTrue(
            Set(notifications.removedDelivered).isSuperset(of: FocusLeavePolicy.nudgeIdentifiers),
            "Every request of the series is also removed from the delivered list"
        )
        XCTAssertTrue(harness.announcements.isEmpty)
        XCTAssertTrue(harness.liveActivityPauses.isEmpty)
        XCTAssertEqual(manager.registeredRunningFocus?.sessionID, harness.sessionID)
        XCTAssertEqual(harness.ended, [task])
        XCTAssertEqual(harness.runningSleeps, 0)
        XCTAssertFalse(monitor.isWatching)

        // The closed window's deadline, a late lock notice and a late expiry
        // decide nothing and book nothing.
        harness.now = leftAt.addingTimeInterval(FocusLeavePolicy.lockDetectionWindow + 1)
        await harness.finishSleep()
        await harness.postLockNotice()
        try XCTUnwrap(harness.expirations[task])()
        await harness.settle()
        XCTAssertEqual(harness.saved, running)
        XCTAssertEqual(Set(notifications.pending.keys), completionIdentifiers)
        XCTAssertTrue(harness.announcements.isEmpty)
        XCTAssertTrue(harness.liveActivityPauses.isEmpty)
        XCTAssertEqual(harness.ended, [task], "Ended exactly once")
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

    func testAConfirmedReturnIsRecordedForReadersOfAnEarlierAbsence() async throws {
        harness.applicationIsActive = false
        monitor.handle(.active)
        XCTAssertTrue(harness.confirmedReturns.isEmpty, "UIKit has not confirmed this activation")

        harness.applicationIsActive = true
        monitor.handleApplicationDidBecomeActive()
        XCTAssertEqual(harness.confirmedReturns, [harness.now])
    }

    // MARK: - Eligibility

    func testTheAppInitiatedMarkCoversOnlyTheTripItStarts() {
        let tappedAt = Date(timeIntervalSince1970: 1_800_300_000)
        FocusLeaveAppInitiatedDeparture.mark(at: tappedAt)
        XCTAssertTrue(FocusLeaveAppInitiatedDeparture.consume(at: tappedAt.addingTimeInterval(1)))
        XCTAssertFalse(
            FocusLeaveAppInitiatedDeparture.consume(at: tappedAt.addingTimeInterval(1)),
            "One mark covers one trip"
        )
        FocusLeaveAppInitiatedDeparture.mark(at: tappedAt)
        XCTAssertFalse(
            FocusLeaveAppInitiatedDeparture.consume(at: tappedAt.addingTimeInterval(6)),
            "A later departure is the person's own"
        )
        XCTAssertFalse(FocusLeaveAppInitiatedDeparture.consume(at: tappedAt))
    }

    func testATripToSettingsTheAppStartedIsNotAnAbsence() async throws {
        let running = try XCTUnwrap(harness.saved)
        harness.appInitiatedDeparture = true
        monitor.handle(.background)
        XCTAssertEqual(harness.saved, running)
        XCTAssertTrue(harness.begun.isEmpty)
        XCTAssertTrue(harness.bookedSeries.isEmpty)
        XCTAssertFalse(harness.appInitiatedDeparture, "The mark is used up by this trip")

        monitor.handle(.active)
        monitor.handle(.background)
        XCTAssertEqual(harness.begun.count, 1, "The next trip away is an absence again")
        XCTAssertNotNil(harness.saved?.leaveExcursion)
        await harness.waitForSleep()
    }

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

    // MARK: - Energy (Docs/FocusLeavePause.md 「電力」)

    /// Every way a window closes gives its background time back exactly
    /// once, removes the lock observer and leaves no wait running, and the
    /// only wait ever asked for is at most the 20-second window. The host
    /// therefore holds one background task for at most the window (plus the
    /// Live Activity update) and keeps no timer afterwards.
    func testEveryWayAWindowClosesEndsItsBackgroundTaskOnceAndKeepsNoTimer() async throws {
        let paths: [(name: String, drive: (LeaveHarness, FocusLeaveMonitor) async throws -> Void)] = [
            ("left: the window ends without a lock", { harness, monitor in
                monitor.handle(.background)
                await harness.waitForSleep()
                harness.now = harness.now.addingTimeInterval(20)
                await harness.finishSleep()
            }),
            ("locked: a lock notice inside the window", { harness, monitor in
                monitor.handle(.background)
                await harness.waitForSleep()
                harness.now = harness.now.addingTimeInterval(10)
                await harness.postLockNotice()
            }),
            ("locked: protected data gone at the end of the window", { harness, monitor in
                monitor.handle(.background)
                await harness.waitForSleep()
                harness.protectedDataIsAvailable = false
                harness.now = harness.now.addingTimeInterval(20)
                await harness.finishSleep()
            }),
            ("locked: already locked at background", { harness, monitor in
                harness.protectedDataIsAvailable = false
                monitor.handle(.background)
                await harness.settle()
            }),
            ("left: no passcode", { harness, monitor in
                harness.deviceHasPasscode = false
                monitor.handle(.background)
                await harness.waitForSleep()
                harness.protectedDataIsAvailable = false
                harness.now = harness.now.addingTimeInterval(20)
                await harness.finishSleep()
            }),
            ("returned inside the window", { harness, monitor in
                monitor.handle(.background)
                await harness.waitForSleep()
                harness.now = harness.now.addingTimeInterval(12)
                monitor.handle(.active)
            }),
            ("returned after a suspended window", { harness, monitor in
                monitor.handle(.background)
                await harness.waitForSleep()
                harness.now = harness.now.addingTimeInterval(3_600)
                monitor.handle(.active)
            }),
            ("expired inside the window", { harness, monitor in
                monitor.handle(.background)
                await harness.waitForSleep()
                let task = try XCTUnwrap(harness.begun.last)
                harness.now = harness.now.addingTimeInterval(8)
                try XCTUnwrap(harness.expirations[task])()
            }),
            ("expired during the Live Activity update", { harness, monitor in
                harness.holdsLiveActivityUpdates = true
                monitor.handle(.background)
                await harness.waitForSleep()
                let task = try XCTUnwrap(harness.begun.last)
                harness.now = harness.now.addingTimeInterval(20)
                await harness.finishSleep()
                try XCTUnwrap(harness.expirations[task])()
                await harness.releaseLiveActivityUpdates()
            }),
            ("nothing left to pause at the end of the window", { harness, monitor in
                monitor.handle(.background)
                await harness.waitForSleep()
                harness.saved = nil
                harness.now = harness.now.addingTimeInterval(20)
                await harness.finishSleep()
            }),
            ("account boundary", { harness, monitor in
                monitor.handle(.background)
                await harness.waitForSleep()
                monitor.cancel()
            })
        ]

        for path in paths {
            harness.releaseAll()
            harness = try LeaveHarness()
            monitor = FocusLeaveMonitor(dependencies: harness.dependencies)
            try await path.drive(harness, monitor)
            await harness.settle()

            XCTAssertEqual(harness.begun.count, 1, path.name)
            XCTAssertEqual(harness.ended, harness.begun, "\(path.name): the background task ends exactly once")
            XCTAssertEqual(harness.observerCount, 0, "\(path.name): the lock observer is removed")
            XCTAssertEqual(harness.runningSleeps, 0, "\(path.name): no wait outlives the window")
            XCTAssertFalse(monitor.isWatching, path.name)
            XCTAssertTrue(
                harness.requestedSleeps.allSatisfy { $0 > 0 && $0 <= FocusLeavePolicy.lockDetectionWindow },
                "\(path.name): the only wait is the bounded window, \(harness.requestedSleeps)"
            )
        }
    }

    /// The production wait is `Task.sleep`, which returns as soon as the
    /// window's task is cancelled, so a closed window keeps no timer.
    func testTheLiveWaitEndsAsSoonAsItsWindowIsCancelled() async throws {
        let notifications = try FocusLeaveNudgeFixture()
        defer { notifications.tearDown() }
        let live = FocusLeaveMonitor.Dependencies.live(notifications: notifications.manager)
        let started = Date()
        let wait = Task { @MainActor in await live.sleep(3_600) }
        await Task.yield()
        wait.cancel()
        await wait.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "A cancelled window keeps no timer")
    }

    // MARK: - Live notification wiring (critic D7)

    /// `Dependencies.live` against a real NotificationManager on fake
    /// clients: the leave pause removes the end alert and keeps the series.
    func testTheLiveWiringRemovesTheEndAlertButKeepsTheSeries() async throws {
        let notifications = try FocusLeaveNudgeFixture()
        defer { notifications.tearDown() }
        let manager = notifications.manager!
        let endDate = harness.start.addingTimeInterval(1_500)
        _ = try await manager.scheduleFocusCompletion(sessionID: harness.sessionID, endDate: endDate)
        manager.registerFocusReturnReminder(
            sessionID: harness.sessionID, endDate: endDate, playsSound: true
        )
        monitor = FocusLeaveMonitor(
            dependencies: harness.dependencies(notificationsFrom: .live(notifications: manager))
        )
        let completionIdentifiers = notifications.pending.keys.filter {
            $0.hasPrefix("pomogem.focus.complete.")
        }
        XCTAssertEqual(completionIdentifiers.count, 1)

        let leftAt = harness.now
        monitor.handle(.background)
        await harness.waitForSleep()
        XCTAssertEqual(
            Set(notifications.pending.keys),
            Set(FocusLeavePolicy.nudgeIdentifiers + completionIdentifiers)
        )

        harness.now = leftAt.addingTimeInterval(20)
        await harness.finishSleep()
        XCTAssertEqual(harness.saved?.leavePause?.pausedAt, leftAt)
        XCTAssertEqual(
            Set(notifications.pending.keys),
            Set(FocusLeavePolicy.nudgeIdentifiers),
            "The end alert is gone; the series saying the timer paused stays"
        )
        XCTAssertNil(manager.registeredRunningFocus, "A paused focus is no longer a leave candidate")

        // Coming back withdraws the series.
        harness.now = leftAt.addingTimeInterval(90)
        monitor.handle(.active)
        XCTAssertTrue(notifications.pending.isEmpty)
    }

    /// F5 part 1: the host's auto-pause (`cancelCompletionKeepingNudges`)
    /// also cancels the session's system alarm, after FocusView is gone,
    /// and keeps the series; an alarm of another session is left alone.
    func testTheLeavePauseCancelsTheSessionsSystemAlarmAndKeepsTheSeries() async throws {
        let alarmSuite = "leave-alarm-\(UUID().uuidString)"
        let alarmDefaults = try XCTUnwrap(UserDefaults(suiteName: alarmSuite))
        defer { alarmDefaults.removePersistentDomain(forName: alarmSuite) }
        let alarmClient = FakeFocusEndAlarmClient()
        let scheduler = FocusEndAlarmScheduler(
            client: alarmClient,
            store: FocusEndAlarmBookingStore(defaults: alarmDefaults),
            now: { [unowned self] in self.harness.now }
        )
        let notifications = try FocusLeaveNudgeFixture(systemAlarms: scheduler)
        defer { notifications.tearDown() }
        let manager = notifications.manager!
        let endDate = harness.start.addingTimeInterval(1_500)
        _ = try await manager.scheduleFocusCompletion(sessionID: harness.sessionID, endDate: endDate)
        manager.registerFocusReturnReminder(
            sessionID: harness.sessionID, endDate: endDate, playsSound: true
        )
        guard case let .booked(booking) = await scheduler.schedule(
            sessionID: harness.sessionID, phase: .focus, endDate: endDate, soundFileName: nil
        ) else { return XCTFail("the alarm was not booked") }
        monitor = FocusLeaveMonitor(
            dependencies: harness.dependencies(notificationsFrom: .live(notifications: manager))
        )

        let leftAt = harness.now
        monitor.handle(.background)
        await harness.waitForSleep()
        XCTAssertEqual(scheduler.booking, booking, "Nothing changes inside the window")

        harness.now = leftAt.addingTimeInterval(20)
        await harness.finishSleep()
        XCTAssertEqual(harness.saved?.leavePause?.pausedAt, leftAt)
        XCTAssertNil(scheduler.booking, "A paused focus has no end to ring")
        XCTAssertEqual(alarmClient.cancelled, [booking.alarmID])
        XCTAssertTrue(alarmClient.scheduled.isEmpty)
        XCTAssertEqual(
            Set(notifications.pending.keys),
            Set(FocusLeavePolicy.nudgeIdentifiers),
            "The series stays; only the end alert and its alarm go"
        )
    }

    private func otherSessionEnvelope() throws -> FocusRecoveryEnvelope {
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: harness.start, sessionID: UUID())
        return FocusRecoveryEnvelope(
            engine: engine,
            subject: FocusSubjectSnapshot(id: UUID(), name: "英語", colorHex: "#4C8CCF"),
            clockAnchor: ClockAnchor(wallDate: harness.start, systemUptime: 5_000),
            pendingCompletion: nil,
            savedAt: harness.start
        )
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
    var appInitiatedDeparture = false
    /// Makes the fake Live Activity update wait until released, like a slow
    /// ActivityKit call.
    var holdsLiveActivityUpdates = false

    enum Event: Equatable {
        case liveActivityPaused(Int)
        case ended(UIBackgroundTaskIdentifier)
    }

    private(set) var bookedSeries: [(sessionID: UUID, leftAt: Date)] = []
    private(set) var withdrawals = 0
    private(set) var cancelledCompletions: [UUID] = []
    private(set) var liveActivityPauses: [(sessionID: UUID, remaining: Int)] = []
    private(set) var announcements: [UUID] = []
    private(set) var begun: [UIBackgroundTaskIdentifier] = []
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private(set) var expirations: [UIBackgroundTaskIdentifier: @MainActor () -> Void] = [:]
    private(set) var observerCount = 0
    private(set) var confirmedReturns: [Date] = []
    /// Background-task ends and Live Activity updates in the order they ran.
    private(set) var events: [Event] = []
    private var heldLiveActivityUpdates: [CheckedContinuation<Void, Never>] = []
    private var nextBackgroundTask = 1
    private var sleeps: [(id: Int, interval: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = []
    private var sleepCalls = 0
    private let cancelledSleeps = LeaveSleepCancellations()
    /// Every wait the monitor asked for, in order.
    private(set) var requestedSleeps: [TimeInterval] = []

    var pendingSleeps: [TimeInterval] { sleeps.map { $0.interval } }

    /// Waits neither finished nor cancelled. The live wait (`Task.sleep`)
    /// returns as soon as its task is cancelled, so this counts the waits a
    /// real process would still keep a timer for.
    var runningSleeps: Int {
        sleeps.filter { !cancelledSleeps.contains($0.id) }.count
    }

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
                let id = sleepCalls
                requestedSleeps.append(interval)
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        sleeps.append((id, interval, continuation))
                        sleepCalls += 1
                    }
                } onCancel: { [cancelledSleeps] in
                    cancelledSleeps.insert(id)
                }
            },
            beginBackgroundTask: { [self] expiration in
                let identifier = UIBackgroundTaskIdentifier(rawValue: nextBackgroundTask)
                nextBackgroundTask += 1
                begun.append(identifier)
                expirations[identifier] = expiration
                return identifier
            },
            endBackgroundTask: { [self] in
                ended.append($0)
                events.append(.ended($0))
            },
            notificationCenter: LeaveCountingNotificationCenter(center: center) { [self] delta in
                observerCount += delta
            },
            scheduleNudges: { [self] candidate, leftAt in
                bookedSeries.append((candidate.sessionID, leftAt))
            },
            withdrawNudges: { [self] in withdrawals += 1 },
            cancelCompletionKeepingNudges: { [self] in cancelledCompletions.append($0) },
            pauseLiveActivity: { [self] sessionID, remaining in
                if holdsLiveActivityUpdates {
                    await withCheckedContinuation { heldLiveActivityUpdates.append($0) }
                }
                liveActivityPauses.append((sessionID, remaining))
                events.append(.liveActivityPaused(remaining))
            },
            announceAutoPause: { [self] in announcements.append($0) },
            recordConfirmedReturn: { [self] in confirmedReturns.append($0) },
            consumeAppInitiatedDeparture: { [self] _ in
                defer { appInitiatedDeparture = false }
                return appInitiatedDeparture
            }
        )
    }

    /// These fakes, except that the notification closures come from `live`.
    func dependencies(
        notificationsFrom live: FocusLeaveMonitor.Dependencies
    ) -> FocusLeaveMonitor.Dependencies {
        var result = dependencies
        result.runningFocus = live.runningFocus
        result.scheduleNudges = live.scheduleNudges
        result.withdrawNudges = live.withdrawNudges
        result.cancelCompletionKeepingNudges = live.cancelCompletionKeepingNudges
        return result
    }

    func releaseLiveActivityUpdates() async {
        holdsLiveActivityUpdates = false
        while !heldLiveActivityUpdates.isEmpty {
            heldLiveActivityUpdates.removeFirst().resume()
        }
        await settle()
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
        holdsLiveActivityUpdates = false
        while !heldLiveActivityUpdates.isEmpty { heldLiveActivityUpdates.removeFirst().resume() }
    }
}

/// Which fake waits were cancelled. Written from a cancellation handler,
/// which may run on any thread.
private final class LeaveSleepCancellations: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<Int> = []

    func insert(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        ids.insert(id)
    }

    func contains(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(id)
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
