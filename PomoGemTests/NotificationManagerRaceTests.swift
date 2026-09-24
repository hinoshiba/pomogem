import SwiftData
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

    func testOnlyTimerEndAlertsAreTimeSensitive() async throws {
        let recorder = PendingNotificationRecorder()
        let manager = recorder.makeManager()
        let focusID = UUID()
        let breakID = UUID()
        _ = try await manager.scheduleFocusCompletion(
            sessionID: focusID, endDate: .now.addingTimeInterval(120)
        )
        _ = try await manager.scheduleBreakCompletion(
            id: breakID, endDate: .now.addingTimeInterval(300)
        )
        let focus = try XCTUnwrap(recorder.pending.values.first {
            $0.identifier.hasPrefix("pomogem.focus.complete.")
        })
        let rest = try XCTUnwrap(recorder.pending.values.first {
            $0.identifier.hasPrefix("pomogem.break.complete.")
        })
        XCTAssertEqual(focus.content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(rest.content.interruptionLevel, .timeSensitive)
        // Account-neutral, and never a promise that a gem is already saved.
        XCTAssertEqual(focus.content.body, "集中時間が終わりました。おつかれさまでした。")
        XCTAssertEqual(rest.content.body, "休憩はここまで。次の一粒へ、ゆっくり戻りましょう。")

        try await schedulePassive(manager, hour: 9)
        let passive = recorder.pending.values.filter {
            $0.identifier.hasPrefix("pomogem.passive.")
        }
        XCTAssertFalse(passive.isEmpty)
        XCTAssertTrue(
            passive.allSatisfy { $0.content.interruptionLevel == .active },
            "Daily reminders and Wrapped must stay ordinary notifications"
        )
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
        recorder.targetAddCount = 2 * IntegrationConstants.passiveDailyReminderHorizonDays
        recorder.finishAdd()
        await fulfillment(of: [recorder.scheduleCompleted!], timeout: 3)
        await waiter.value
        XCTAssertEqual(recorder.pending.count, IntegrationConstants.passiveDailyReminderHorizonDays)
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
        XCTAssertEqual(recorder.pending.count, IntegrationConstants.passiveDailyReminderHorizonDays)
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
        XCTAssertEqual(recorder.pending.count, IntegrationConstants.passiveDailyReminderHorizonDays)
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
        XCTAssertEqual(recorder.pending.count, IntegrationConstants.passiveDailyReminderHorizonDays)
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
        XCTAssertEqual(recorder.pending.count, IntegrationConstants.passiveDailyReminderHorizonDays)
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

    // MARK: - What the passive schedule books

    func testPassiveTriggersFloatInTheLocalTimeZone() async throws {
        let recorder = PendingNotificationRecorder()
        let manager = recorder.makeManager()
        try await manager.synchronizePassiveNotifications(
            dailyReminderEnabled: true, wrappedEnabled: true,
            hour: 20, minute: 15, playsSound: false,
            now: date("2026-09-25T09:00"), calendar: Self.tokyo
        )
        XCTAssertFalse(recorder.pending.isEmpty)
        for request in recorder.pending.values {
            let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
            // A pinned zone travels with the archived trigger: a Tokyo 20:15
            // would ring at 01:15 in Honolulu until the app is opened again.
            XCTAssertNil(trigger.dateComponents.timeZone, request.identifier)
            XCTAssertNil(trigger.dateComponents.calendar, request.identifier)
            XCTAssertEqual(trigger.dateComponents.hour, 20)
            XCTAssertEqual(trigger.dateComponents.minute, 15)
            XCTAssertEqual(trigger.dateComponents.second, 0)
            XCTAssertFalse(trigger.repeats)
        }
    }

    func testDailyReminderStopsSevenDaysAfterTheLastOpen() async throws {
        for (now, hour) in [("2026-09-25T09:00", 20), ("2026-09-25T21:00", 20)] {
            let recorder = PendingNotificationRecorder()
            try await recorder.makeManager().synchronizePassiveNotifications(
                dailyReminderEnabled: true, wrappedEnabled: false,
                hour: hour, minute: 0, playsSound: false,
                now: date(now), calendar: Self.tokyo
            )
            XCTAssertEqual(recorder.pending.count, 7, now)
            let latest = try XCTUnwrap(recorder.fireDates(calendar: Self.tokyo).max())
            XCTAssertLessThan(latest, date(now).addingTimeInterval(7 * 86_400), now)
        }
    }

    func testAnsweredTodaySkipsOnlyTodaysDailyReminder() async throws {
        let recorder = PendingNotificationRecorder()
        let now = date("2026-09-25T09:00")
        try await recorder.makeManager().synchronizePassiveNotifications(
            dailyReminderEnabled: true, wrappedEnabled: false,
            hour: 20, minute: 0, playsSound: false,
            activity: PassiveReminderActivity(answeredStudyDayKeys: ["2026-09-25"]),
            now: now, calendar: Self.tokyo
        )
        let identifiers = Set(recorder.pending.keys)
        XCTAssertFalse(identifiers.contains("pomogem.passive.2026.9.25"))
        XCTAssertTrue(identifiers.contains("pomogem.passive.2026.9.26"))
        XCTAssertEqual(identifiers.count, 6)
        XCTAssertTrue(recorder.pending.values.allSatisfy {
            $0.content.body == "瓶が待ってる。今日のひと粒、積んでいく？"
        })
    }

    func testEarlyMorningReminderBelongsToThePreviousStudyDay() async throws {
        // 02:00 is before the 04:00 study-day boundary, so the 02:00 slot
        // after a Friday-night focus still belongs to Friday.
        let recorder = PendingNotificationRecorder()
        try await recorder.makeManager().synchronizePassiveNotifications(
            dailyReminderEnabled: true, wrappedEnabled: false,
            hour: 2, minute: 0, playsSound: false,
            activity: PassiveReminderActivity(answeredStudyDayKeys: ["2026-09-25"]),
            now: date("2026-09-25T23:30"), calendar: Self.tokyo
        )
        let identifiers = Set(recorder.pending.keys)
        XCTAssertFalse(identifiers.contains("pomogem.passive.2026.9.26"))
        XCTAssertTrue(identifiers.contains("pomogem.passive.2026.9.27"))
    }

    func testWrappedKeepsItsSlotOnAnAnsweredDayAndBeyondTheDailyWindow() async throws {
        let recorder = PendingNotificationRecorder()
        try await recorder.makeManager().synchronizePassiveNotifications(
            dailyReminderEnabled: true, wrappedEnabled: true,
            hour: 20, minute: 0, playsSound: false,
            activity: PassiveReminderActivity(
                answeredStudyDayKeys: ["2026-10-01"],
                monthsWithRecords: [PassiveReminderActivity.monthKey(for: date("2026-09-10T12:00"), calendar: Self.tokyo)]
            ),
            now: date("2026-10-01T08:00"), calendar: Self.tokyo
        )
        XCTAssertEqual(
            recorder.pending["pomogem.passive.2026.10.1"]?.content.body,
            "先月の瓶ができた。積み上がりを眺めよう。"
        )
        XCTAssertEqual(recorder.pending.count, 7, "Oct 1 Wrapped plus six daily reminders")

        // Twenty days after the last open only Wrapped is still booked.
        let later = PendingNotificationRecorder()
        try await later.makeManager().synchronizePassiveNotifications(
            dailyReminderEnabled: true, wrappedEnabled: true,
            hour: 20, minute: 0, playsSound: false,
            activity: PassiveReminderActivity(
                monthsWithRecords: [PassiveReminderActivity.monthKey(for: date("2026-09-10T12:00"), calendar: Self.tokyo)]
            ),
            now: date("2026-09-11T08:00"), calendar: Self.tokyo
        )
        XCTAssertNotNil(later.pending["pomogem.passive.2026.10.1"])
        XCTAssertEqual(later.pending.count, 8, "Seven daily reminders and the Oct 1 Wrapped")
    }

    func testWrappedOnlyAtItsOwnTimeAndOnlyForAMonthWithAJar() async throws {
        let september = PassiveReminderActivity.monthKey(for: date("2026-09-10T12:00"), calendar: Self.tokyo)
        let recorder = PendingNotificationRecorder()
        // Now in September: Oct 1 looks back at September (has records) and
        // Nov 1 at October, which has nothing yet.
        try await recorder.makeManager().synchronizePassiveNotifications(
            dailyReminderEnabled: false, wrappedEnabled: true,
            hour: 6, minute: 30, playsSound: false,
            activity: PassiveReminderActivity(monthsWithRecords: [september]),
            now: date("2026-09-28T12:00"), calendar: Self.tokyo
        )
        XCTAssertEqual(Array(recorder.pending.keys), ["pomogem.passive.2026.10.1"])
        let trigger = try XCTUnwrap(recorder.pending.values.first?.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(trigger.dateComponents.hour, 6)
        XCTAssertEqual(trigger.dateComponents.minute, 30)

        let empty = PendingNotificationRecorder()
        try await empty.makeManager().synchronizePassiveNotifications(
            dailyReminderEnabled: false, wrappedEnabled: true,
            hour: 6, minute: 30, playsSound: false,
            activity: PassiveReminderActivity(monthsWithRecords: []),
            now: date("2026-09-28T12:00"), calendar: Self.tokyo
        )
        XCTAssertTrue(empty.pending.isEmpty, "No jar last month, so no 「先月の瓶ができた」")

        // With the daily reminder on, an empty month's 1st is an ordinary day.
        let daily = PendingNotificationRecorder()
        try await daily.makeManager().synchronizePassiveNotifications(
            dailyReminderEnabled: true, wrappedEnabled: true,
            hour: 20, minute: 0, playsSound: false,
            activity: PassiveReminderActivity(monthsWithRecords: []),
            now: date("2026-09-28T12:00"), calendar: Self.tokyo
        )
        XCTAssertEqual(
            daily.pending["pomogem.passive.2026.10.1"]?.content.body,
            "瓶が待ってる。今日のひと粒、積んでいく？"
        )
    }

    func testUnreadableRecordsKeepWrappedAsBefore() async throws {
        let recorder = PendingNotificationRecorder()
        try await recorder.makeManager().synchronizePassiveNotifications(
            dailyReminderEnabled: false, wrappedEnabled: true,
            hour: 20, minute: 0, playsSound: false,
            activity: .unknown,
            now: date("2026-09-28T12:00"), calendar: Self.tokyo
        )
        XCTAssertEqual(
            Set(recorder.pending.keys),
            ["pomogem.passive.2026.10.1", "pomogem.passive.2026.11.1"]
        )
    }

    func testFocusAnsweringTodayWinsOverAnInFlightSchedule() async throws {
        let recorder = PendingNotificationRecorder()
        let manager = recorder.makeManager()
        let now = date("2026-09-25T09:00")
        recorder.addStarted = expectation(description: "unanswered schedule add started")
        let old = Task {
            try await manager.synchronizePassiveNotifications(
                dailyReminderEnabled: true, wrappedEnabled: false,
                hour: 20, minute: 0, playsSound: false,
                now: now, calendar: Self.tokyo
            )
        }
        await fulfillment(of: [recorder.addStarted!], timeout: 3)
        // A focus opens while the older schedule is still adding today's slot.
        let answered = Task {
            try await manager.synchronizePassiveNotifications(
                dailyReminderEnabled: true, wrappedEnabled: false,
                hour: 20, minute: 0, playsSound: false,
                activity: PassiveReminderActivity(answeredStudyDayKeys: ["2026-09-25"]),
                now: now, calendar: Self.tokyo
            )
        }
        recorder.finishAdd()
        try await old.value
        try await answered.value
        XCTAssertNil(recorder.pending["pomogem.passive.2026.9.25"])
        XCTAssertEqual(recorder.pending.count, 6)
    }

    func testThisDevicesPermissionGatesBookingWithoutTouchingTheIntent() async throws {
        for status in [UNAuthorizationStatus.notDetermined, .denied] {
            let recorder = PendingNotificationRecorder()
            let manager = recorder.makeManager()
            try await schedulePassive(manager, hour: 20)
            let booked = recorder.pending.count
            XCTAssertGreaterThan(booked, 0)

            // Permission is revoked on this iPhone (or never granted after a
            // reinstall): nothing is booked that iOS would silently drop, and
            // the stale requests are removed.
            recorder.authorizationStatus = status
            try await schedulePassive(manager, hour: 20)
            XCTAssertTrue(recorder.pending.isEmpty, "\(status.rawValue)")
            XCTAssertEqual(manager.authorizationStatus, status)
            XCTAssertTrue(manager.hasLoadedAuthorizationStatus)
            XCTAssertNil(manager.lastErrorDescription)

            recorder.authorizationStatus = .authorized
            try await schedulePassive(manager, hour: 20)
            XCTAssertEqual(recorder.pending.count, booked)
        }
    }

    func testFreshManagerHasNotLoadedPermissionYet() async {
        let recorder = PendingNotificationRecorder()
        recorder.authorizationStatus = .authorized
        let manager = recorder.makeManager()
        // The initial `.notDetermined` is a placeholder; Settings must not
        // show 「まだ通知を許可していない」 for it.
        XCTAssertFalse(manager.hasLoadedAuthorizationStatus)
        await manager.refreshAuthorizationStatus()
        XCTAssertTrue(manager.hasLoadedAuthorizationStatus)
        XCTAssertTrue(manager.isAuthorized)
    }

    private static let tokyo: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Self.tokyo
        formatter.timeZone = Self.tokyo.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.date(from: value)!
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
    var authorizationStatus: UNAuthorizationStatus = .authorized
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
                authorizationStatus: { self.authorizationStatus }, add: client.add,
                removePending: client.removePending, removeDelivered: { _ in }
            )
        )
    }

    /// Resolves each floating trigger in `calendar`'s zone.
    func fireDates(calendar: Calendar) -> [Date] {
        pending.values.compactMap { request in
            guard let trigger = request.trigger as? UNCalendarNotificationTrigger else { return nil }
            return calendar.date(from: trigger.dateComponents)
        }
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

/// What counts as "today already answered" and "last month has a jar".
///
/// Every read uses a fixed instant in a fixed zone: a record placed "a minute
/// ago" would cross the 04:00 study-day boundary or the 1st of a month when
/// CI happens to run at those times.
@MainActor
final class PassiveReminderActivityReaderTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    private static let tokyo: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    /// Mid-day in the middle of a month, well away from both boundaries.
    private let now = PassiveReminderActivityReaderTests.date("2026-09-15T13:00")

    override func setUp() {
        super.setUp()
        suiteName = "PassiveReminderActivityReaderTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private static func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = tokyo
        formatter.timeZone = tokyo.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.date(from: value)!
    }

    private func date(_ value: String) -> Date { Self.date(value) }

    private func dayKey(_ date: Date) -> String {
        FairnessPolicy.deviceDayKey(for: date, timeZone: Self.tokyo.timeZone)
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Subject.self, StudySession.self, ActivityResetMarker.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        return ModelContext(container)
    }

    private func read(
        _ context: ModelContext,
        markers: [ActivityResetSnapshot] = [],
        at instant: Date? = nil
    ) -> PassiveReminderActivity {
        PassiveReminderActivityReader.read(
            context: context,
            markers: markers,
            now: instant ?? now,
            calendar: Self.tokyo,
            defaults: defaults
        )
    }

    private func insert(
        _ source: SessionSource,
        seconds: Int,
        endingAt end: Date,
        epoch: UUID? = nil,
        in context: ModelContext
    ) throws {
        context.insert(StudySession(
            startAt: end.addingTimeInterval(-TimeInterval(seconds)),
            endAt: end,
            seconds: seconds,
            source: source,
            grams: source == .manual
                ? ManualDuration.thirtyMinutes.grams
                : nil,
            deviceDayKey: dayKey(end),
            dataEpochID: epoch
        ))
        try context.save()
    }

    private var todayKey: String { dayKey(now) }
    private var thisMonth: String {
        PassiveReminderActivity.monthKey(for: now, calendar: Self.tokyo)
    }

    private func persist(_ envelope: FocusRecoveryEnvelope) throws {
        defaults.set(try JSONEncoder().encode(envelope), forKey: FocusPersistence.key)
    }

    private func envelope(
        _ engine: PomodoroEngine,
        pendingCompletion: PomodoroCompletion? = nil
    ) -> FocusRecoveryEnvelope {
        FocusRecoveryEnvelope(
            engine: engine,
            subject: nil,
            clockAnchor: nil,
            pendingCompletion: pendingCompletion,
            savedAt: now
        )
    }

    private func runningFocus(startedAt start: Date) throws -> PomodoroEngine {
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start)
        return engine
    }

    /// A 25-minute focus that ended while the app was not running, waiting to
    /// be saved on the next launch.
    private func finishedFocus(startedAt start: Date) throws -> (PomodoroEngine, PomodoroCompletion) {
        struct FocusDidNotComplete: Error {}
        var engine = try runningFocus(startedAt: start)
        guard case let .focusCompleted(completion)? = engine.advance(
            at: start.addingTimeInterval(25 * 60)
        ) else {
            XCTFail("The engine did not complete the focus")
            throw FocusDidNotComplete()
        }
        return (engine, completion)
    }

    func testNothingDoneLeavesTheReminderAndNoJar() throws {
        let activity = read(try makeContext())
        XCTAssertTrue(activity.answeredStudyDayKeys.isEmpty)
        XCTAssertEqual(activity.monthsWithRecords, [])
    }

    func testTimerAndHandAddedRecordsAnswerToday() throws {
        for (source, seconds) in [
            (SessionSource.timer, 25 * 60),
            (.timerDemoted, 25 * 60),
            (.manual, ManualDuration.thirtyMinutes.seconds)
        ] {
            let context = try makeContext()
            try insert(source, seconds: seconds, endingAt: now.addingTimeInterval(-60), in: context)
            let activity = read(context)
            XCTAssertEqual(activity.answeredStudyDayKeys, [todayKey], "\(source)")
            XCTAssertEqual(activity.monthsWithRecords?.contains(thisMonth), true)
        }
    }

    func testScreenTimeChunksFillTheJarButDoNotAnswerToday() throws {
        let context = try makeContext()
        try insert(.screenTime, seconds: SessionSource.screenTimeSeconds, endingAt: now.addingTimeInterval(-60), in: context)
        let activity = read(context)
        XCTAssertTrue(activity.answeredStudyDayKeys.isEmpty)
        XCTAssertEqual(activity.monthsWithRecords?.contains(thisMonth), true)
    }

    /// Both records are inside the 26-hour fetch window, so only the study-day
    /// key keeps them from answering today.
    func testARecordFromThePreviousStudyDayDoesNotAnswerToday() throws {
        for (end, readAt) in [
            ("2026-09-25T03:30", "2026-09-25T10:00"),
            ("2026-09-24T23:30", "2026-09-25T08:00"),
            ("2026-09-25T03:50", "2026-09-25T04:10")
        ] {
            let context = try makeContext()
            try insert(.timer, seconds: 25 * 60, endingAt: date(end), in: context)
            XCTAssertLessThan(date(readAt).timeIntervalSince(date(end)), 26 * 60 * 60)
            XCTAssertTrue(
                read(context, at: date(readAt)).answeredStudyDayKeys.isEmpty,
                "\(end) read at \(readAt)"
            )
        }

        // The same window does answer today for a record after 04:00.
        let context = try makeContext()
        try insert(.timer, seconds: 25 * 60, endingAt: date("2026-09-25T04:30"), in: context)
        XCTAssertEqual(
            read(context, at: date("2026-09-25T10:00")).answeredStudyDayKeys,
            ["2026-09-25"]
        )
    }

    func testAFocusStartedTodayAnswersOnlyToday() throws {
        let context = try makeContext()
        // Stopped with 「今日はここまで」: nothing saved, but the day is answered.
        PassiveReminderActivityReader.recordFocusStarted(
            at: now,
            timeZone: Self.tokyo.timeZone,
            defaults: defaults
        )
        XCTAssertEqual(read(context).answeredStudyDayKeys, [todayKey])
        XCTAssertTrue(
            read(context, at: now.addingTimeInterval(86_400)).answeredStudyDayKeys.isEmpty,
            "Yesterday's start must not answer the next day"
        )
    }

    /// A focus late on day D that finished overnight is committed through a
    /// recovery the next morning; that must not silence D+1.
    func testReopeningAFocusFromAnEarlierDayDoesNotAnswerToday() throws {
        let context = try makeContext()
        let morning = date("2026-09-25T08:00")
        let (engine, completion) = try finishedFocus(startedAt: date("2026-09-24T23:30"))
        PassiveReminderActivityReader.recordRecoveredFocus(
            engine: engine,
            pendingCompletion: completion,
            at: morning,
            timeZone: Self.tokyo.timeZone,
            defaults: defaults
        )
        XCTAssertNil(defaults.string(forKey: PassiveReminderActivityReader.focusStartedStudyDayDefaultsKey))
        try persist(envelope(engine, pendingCompletion: completion))
        XCTAssertEqual(read(context, at: morning).answeredStudyDayKeys, ["2026-09-24"])

        // A focus paused days ago and shown again answers nothing new.
        var paused = try runningFocus(startedAt: date("2026-09-21T19:00"))
        try paused.pause(at: date("2026-09-21T19:10"))
        PassiveReminderActivityReader.recordRecoveredFocus(
            engine: paused,
            pendingCompletion: nil,
            at: morning,
            timeZone: Self.tokyo.timeZone,
            defaults: defaults
        )
        try persist(envelope(paused))
        XCTAssertEqual(read(context, at: morning).answeredStudyDayKeys, ["2026-09-21"])
        XCTAssertFalse(read(context, at: morning).answeredStudyDayKeys.contains("2026-09-25"))
    }

    func testReopeningAFocusThatBeganTodayAnswersToday() throws {
        let context = try makeContext()
        // For example, a focus started on another iPhone and continued here.
        var paused = try runningFocus(startedAt: now.addingTimeInterval(-15 * 60))
        try paused.pause(at: now.addingTimeInterval(-5 * 60))
        PassiveReminderActivityReader.recordRecoveredFocus(
            engine: paused,
            pendingCompletion: nil,
            at: now,
            timeZone: Self.tokyo.timeZone,
            defaults: defaults
        )
        XCTAssertEqual(read(context).answeredStudyDayKeys, [todayKey])
    }

    func testAFocusInThisDevicesRecoveryDataAnswersTheDaysItRuns() throws {
        let context = try makeContext()
        try persist(envelope(try runningFocus(startedAt: now.addingTimeInterval(-10 * 60))))
        XCTAssertEqual(read(context).answeredStudyDayKeys, [todayKey])

        // Started before 04:00 and ending after it: the record will carry
        // the day it ends, so both days are answered.
        let early = date("2026-09-25T03:50")
        try persist(envelope(try runningFocus(startedAt: early)))
        XCTAssertEqual(
            read(context, at: date("2026-09-25T04:05")).answeredStudyDayKeys,
            ["2026-09-24", "2026-09-25"]
        )
    }

    func testABreakOrUnreadableRecoveryDataAnswersNothing() throws {
        let context = try makeContext()
        var engine = try finishedFocus(startedAt: now.addingTimeInterval(-40 * 60)).0
        try engine.startBreak(now: now.addingTimeInterval(-10 * 60))
        try persist(envelope(engine))
        XCTAssertTrue(read(context).answeredStudyDayKeys.isEmpty)

        defaults.set(Data([1]), forKey: FocusPersistence.key)
        XCTAssertTrue(read(context).answeredStudyDayKeys.isEmpty)
    }

    func testRecordsOutsideTheCurrentResetGenerationAreIgnored() throws {
        let context = try makeContext()
        let marker = ActivityResetMarker(epochID: UUID(), sequence: 1, resetAt: now.addingTimeInterval(-120), writerDeviceID: "test")
        context.insert(marker)
        try context.save()
        try insert(.timer, seconds: 25 * 60, endingAt: now.addingTimeInterval(-60), epoch: nil, in: context)
        let activity = read(context, markers: [marker.policySnapshot])
        XCTAssertTrue(activity.answeredStudyDayKeys.isEmpty)
        XCTAssertEqual(activity.monthsWithRecords, [])
    }
}

final class FocusReturnReminderLockPolicyTests: XCTestCase {
    func testLockWindowEndsBeforeTheReminderAndAfterTheLockNotice() {
        // iOS posts the protected-data notice about 10 s after a passcode lock.
        XCTAssertGreaterThan(FocusReturnReminderPolicy.lockDetectionWindow, 12)
        XCTAssertLessThanOrEqual(
            FocusReturnReminderPolicy.lockDetectionWindow,
            FocusReturnReminderPolicy.delay - 5
        )
    }

    func testOnlyALockOrAnUnfinishedAddWithdrawsTheReminder() {
        XCTAssertFalse(FocusReturnReminderPolicy.shouldWithdrawOnBackgroundExpiry(addWasAccepted: true))
        XCTAssertTrue(FocusReturnReminderPolicy.shouldWithdrawOnBackgroundExpiry(addWasAccepted: false))
        XCTAssertFalse(FocusReturnReminderPolicy.shouldWithdrawAtLockWindowEnd(protectedDataIsAvailable: true))
        XCTAssertTrue(FocusReturnReminderPolicy.shouldWithdrawAtLockWindowEnd(protectedDataIsAvailable: false))
    }
}
