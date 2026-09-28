import UserNotifications
import XCTest
@testable import PomoGem

/// F5 part 1: the focus- and break-end channel. The notification's sound per
/// strength, one channel per end (a system alarm books no notification, and
/// cancelling an end cancels both), and the booker part 2 will call.
@MainActor
final class TimerEndAlarmChannelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var preferences: AlarmPreferences!
    private var client: FakeFocusEndAlarmClient!
    private var scheduler: FocusEndAlarmScheduler!
    private var clock: Date!
    private var pending: [String: UNNotificationRequest] = [:]
    private var requestedFiles: [TimerEndNotificationSound] = []
    private var fileAvailable = true

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "timer-end-alarm-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        preferences = AlarmPreferences(defaults: defaults)
        client = FakeFocusEndAlarmClient()
        clock = Date()
        scheduler = FocusEndAlarmScheduler(
            client: client,
            store: FocusEndAlarmBookingStore(defaults: defaults),
            now: { [unowned self] in self.clock }
        )
        pending = [:]
        requestedFiles = []
        fileAvailable = true
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeManager(sounds: Bool = true) -> NotificationManager {
        let client = NotificationRequestClient(
            add: { [unowned self] in self.pending[$0.identifier] = $0 },
            pending: { [unowned self] in Array(self.pending.values) },
            removePending: { [unowned self] ids in
                for id in ids { self.pending.removeValue(forKey: id) }
            }
        )
        let preferences = self.preferences!
        return NotificationManager(
            requestClient: client,
            focusReturnReminderClient: FocusReturnReminderNotificationClient(
                authorizationStatus: { .authorized },
                add: client.add,
                removePending: client.removePending,
                removeDelivered: { _ in }
            ),
            timerEndSounds: sounds ? TimerEndNotificationSounds(
                strength: { preferences.strength },
                choice: { preferences.sound(legacy: $0) },
                file: { [unowned self] selection in
                    self.requestedFiles.append(selection)
                    return self.fileAvailable ? Self.fakeSound(selection) : nil
                }
            ) : nil,
            systemAlarms: scheduler
        )
    }

    /// A distinct sound per file, so a test sees which one the request
    /// plays (`UNNotificationSound` compares by name).
    private static func fakeSound(_ selection: TimerEndNotificationSound) -> UNNotificationSound {
        let name: String
        switch selection {
        case let .ringtone(choice): name = "fake-ringtone-\(choice.rawValue).caf"
        case let .alarmCue(choice): name = "fake-cue-\(choice.rawValue).caf"
        case .silent, .legacyChime: name = "fake-unexpected.caf"
        }
        return UNNotificationSound(named: UNNotificationSoundName(name))
    }

    private func focusRequest(_ sessionID: UUID) -> UNNotificationRequest? {
        pending["pomogem.focus.complete.\(sessionID.uuidString.lowercased())"]
    }

    private var focusRequest: UNNotificationRequest? {
        pending.values.first { $0.identifier.hasPrefix("pomogem.focus.complete.") }
    }

    private var breakRequest: UNNotificationRequest? {
        pending.values.first { $0.identifier.hasPrefix("pomogem.break.complete.") }
    }

    // MARK: The notification's sound

    func testTheSoundSelectionMatrix() {
        let ringtone = AlarmBackgroundChannel.timeSensitiveNotification(.ringtone)
        let short = AlarmBackgroundChannel.timeSensitiveNotification(.shortChime)
        XCTAssertEqual(TimerEndNotificationSound.selection(channel: ringtone, choice: .bell), .ringtone(.bell))
        XCTAssertEqual(TimerEndNotificationSound.selection(channel: ringtone, choice: .soft), .ringtone(.soft))
        XCTAssertEqual(TimerEndNotificationSound.selection(channel: short, choice: .soft), .legacyChime(.soft))
        XCTAssertEqual(TimerEndNotificationSound.selection(channel: short, choice: .digital), .alarmCue(.digital))
        XCTAssertEqual(TimerEndNotificationSound.selection(channel: .timeSensitiveNotification(.silent), choice: .bell), .silent)
        XCTAssertEqual(TimerEndNotificationSound.selection(channel: .systemAlarm, choice: .bell), .silent)
    }

    func testTheDefaultStrengthRingsTheLongRingtoneForFocusAndBreak() async throws {
        let manager = makeManager()
        _ = try await manager.scheduleFocusCompletion(sessionID: UUID(), endDate: clock.addingTimeInterval(600))
        _ = try await manager.scheduleBreakCompletion(id: UUID(), endDate: clock.addingTimeInterval(300))
        XCTAssertEqual(requestedFiles, [.ringtone(.standard), .ringtone(.standard)],
                       "標準 by default; the break uses the same sound and strength")
        XCTAssertEqual(focusRequest?.content.sound, Self.fakeSound(.ringtone(.standard)), "the ringtone it asked for")
        XCTAssertEqual(breakRequest?.content.sound, Self.fakeSound(.ringtone(.standard)))
        // The Time Sensitive invariant is unchanged.
        XCTAssertEqual(focusRequest?.content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(breakRequest?.content.interruptionLevel, .timeSensitive)
    }

    func testEachStrengthAndChoiceGetsItsOwnFile() async throws {
        let manager = makeManager()
        let (ringtone, cue, chime) = (UUID(), UUID(), UUID())
        preferences.select(.alarmClock)
        _ = try await manager.scheduleFocusCompletion(sessionID: ringtone, endDate: clock.addingTimeInterval(600))
        preferences.setStrength(.gentle)
        _ = try await manager.scheduleFocusCompletion(sessionID: cue, endDate: clock.addingTimeInterval(600))
        preferences.select(.bright)
        _ = try await manager.scheduleFocusCompletion(
            sessionID: chime, endDate: clock.addingTimeInterval(600), completionSound: .bright
        )
        XCTAssertEqual(requestedFiles, [.ringtone(.alarmClock), .alarmCue(.alarmClock)],
                       "控えめ with an original chime keeps today's file and asks for nothing")
        XCTAssertEqual(pending.count, 3)
        XCTAssertEqual(focusRequest(ringtone)?.content.sound, Self.fakeSound(.ringtone(.alarmClock)))
        XCTAssertEqual(focusRequest(cue)?.content.sound, Self.fakeSound(.alarmCue(.alarmClock)))
        XCTAssertEqual(
            focusRequest(chime)?.content.sound,
            TimerCompletionSoundLibrary.notificationSound(for: .bright),
            "today's short chime"
        )
    }

    /// The live closure asks the library for the file kind each selection
    /// plays: the ≤ 28 s ringtone or one cycle.
    func testEachSelectionPlaysItsOwnKindOfFile() {
        XCTAssertEqual(TimerEndNotificationSound.ringtone(.bell).alarmSoundFile?.kind, .ringtone)
        XCTAssertEqual(TimerEndNotificationSound.ringtone(.bell).alarmSoundFile?.choice, .bell)
        XCTAssertEqual(TimerEndNotificationSound.alarmCue(.digital).alarmSoundFile?.kind, .cue)
        XCTAssertEqual(TimerEndNotificationSound.alarmCue(.digital).alarmSoundFile?.choice, .digital)
        XCTAssertNil(TimerEndNotificationSound.legacyChime(.soft).alarmSoundFile)
        XCTAssertNil(TimerEndNotificationSound.silent.alarmSoundFile)
    }

    func testSoundOffStaysSilentAndAMissingFileFallsBackToTheChime() async throws {
        let manager = makeManager()
        _ = try await manager.scheduleFocusCompletion(
            sessionID: UUID(), endDate: clock.addingTimeInterval(600), playsSound: false
        )
        XCTAssertNil(focusRequest?.content.sound)
        XCTAssertTrue(requestedFiles.isEmpty)

        pending.removeAll()
        fileAvailable = false
        _ = try await manager.scheduleFocusCompletion(sessionID: UUID(), endDate: clock.addingTimeInterval(600))
        XCTAssertEqual(
            focusRequest?.content.sound,
            TimerCompletionSoundLibrary.notificationSound(for: .standard),
            "The short chime stands in"
        )
    }

    func testAManagerWithoutAlarmSoundsKeepsTodaysChime() async throws {
        let manager = makeManager(sounds: false)
        _ = try await manager.scheduleFocusCompletion(sessionID: UUID(), endDate: clock.addingTimeInterval(600))
        XCTAssertEqual(focusRequest?.content.sound, TimerCompletionSoundLibrary.notificationSound(for: .standard))
        XCTAssertTrue(requestedFiles.isEmpty)
    }

    // MARK: One channel per end

    func testASystemAlarmChannelBooksNoNotificationAndWithdrawsTheEarlierOne() async throws {
        let manager = makeManager()
        let session = UUID()
        let rest = UUID()
        _ = try await manager.scheduleFocusCompletion(sessionID: session, endDate: clock.addingTimeInterval(600))
        _ = try await manager.scheduleBreakCompletion(id: rest, endDate: clock.addingTimeInterval(600))
        _ = await scheduler.schedule(sessionID: session, phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil)
        XCTAssertEqual(pending.count, 2)

        let focus = try await manager.scheduleFocusCompletion(
            sessionID: session, endDate: clock.addingTimeInterval(600), channel: .systemAlarm
        )
        let rested = try await manager.scheduleBreakCompletion(
            id: rest, endDate: clock.addingTimeInterval(600), channel: .systemAlarm
        )
        XCTAssertEqual(focus, .deferredToSystemAlarm)
        XCTAssertEqual(rested, .deferredToSystemAlarm)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(scheduler.booking?.sessionID, session, "Withdrawing the notification keeps the alarm")
    }

    func testCancellingAnEndCancelsItsSystemAlarmToo() async throws {
        let manager = makeManager()
        let session = UUID()
        guard case let .booked(focusAlarm) = await scheduler.schedule(
            sessionID: session, phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil
        ) else { return XCTFail() }
        manager.cancelFocusCompletion(sessionID: UUID())
        XCTAssertNotNil(scheduler.booking, "Another session's cancel leaves it")
        manager.cancelFocusCompletion(sessionID: session)
        XCTAssertNil(scheduler.booking)
        XCTAssertTrue(client.cancelled.contains(focusAlarm.alarmID))

        let rest = UUID()
        guard case let .booked(breakAlarm) = await scheduler.schedule(
            sessionID: rest, phase: .breakTime, endDate: clock.addingTimeInterval(300), soundFileName: nil
        ) else { return XCTFail() }
        manager.cancelBreakCompletionRequest(id: rest)
        XCTAssertNotNil(scheduler.booking, "The notification-only removal keeps the alarm")
        manager.cancelBreakCompletion(id: rest)
        XCTAssertNil(scheduler.booking)
        XCTAssertTrue(client.cancelled.contains(breakAlarm.alarmID))
    }

    func testRetirementCancelsEveryAlarmAndResetRecoveryKeepsThePreservedOne() async throws {
        let manager = makeManager()
        let kept = UUID()
        guard case let .booked(keptAlarm) = await scheduler.schedule(
            sessionID: kept, phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil
        ) else { return XCTFail() }
        let orphan = UUID()
        client.insert(orphan, state: .scheduled)

        await manager.prepareTimerNotificationCleanup(preserving: kept)()
        XCTAssertEqual(scheduler.booking?.alarmID, keptAlarm.alarmID)
        XCTAssertTrue(client.cancelled.contains(orphan))
        XCTAssertFalse(client.cancelled.contains(keptAlarm.alarmID))

        // iCloud retirement, an account change and complete deletion.
        await manager.cancelAllTimerNotifications()
        XCTAssertNil(scheduler.booking)
        XCTAssertTrue(client.cancelled.contains(keptAlarm.alarmID))
    }

    // MARK: The booker (part 2 calls it)

    private func makeBooker(_ manager: NotificationManager) -> TimerEndAnnouncementBooker {
        TimerEndAnnouncementBooker(
            notifications: manager,
            systemAlarms: scheduler,
            preferences: preferences,
            ringtoneFileName: { AlarmSoundLibrary.fileName(for: $0) }
        )
    }

    func testTheMaximumPresetBooksTheSystemAlarmInsteadOfTheNotification() async throws {
        let manager = makeManager()
        await manager.refreshAuthorizationStatus()
        preferences.setStrength(.maximum)
        preferences.select(.bell)
        let booker = makeBooker(manager)
        let session = UUID()
        let end = clock.addingTimeInterval(1_500)
        _ = try await manager.scheduleFocusCompletion(sessionID: session, endDate: end)
        XCTAssertNotNil(focusRequest)

        let outcome = try await booker.bookFocusEnd(
            sessionID: session, endDate: end, playsSound: true, completionSound: .standard
        )
        guard case let .systemAlarm(booking) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(booking.fireDate, end)
        XCTAssertEqual(client.scheduled[booking.alarmID]?.soundFileName, "pomogem-alarm-bell-v1.caf")
        XCTAssertNil(focusRequest, "One channel: the notification is withdrawn")

        let rest = try await booker.bookBreakEnd(
            id: UUID(), endDate: clock.addingTimeInterval(300), playsSound: true, completionSound: .standard
        )
        guard case let .systemAlarm(breakBooking) = rest else { return XCTFail("\(rest)") }
        XCTAssertEqual(breakBooking.phase, .breakTime, "The break end rings the same way")
    }

    func testAFailedAlarmFallsBackToTheRingtoneNotification() async throws {
        let manager = makeManager()
        await manager.refreshAuthorizationStatus()
        preferences.setStrength(.maximum)
        client.scheduleError = FakeFocusEndAlarmClient.Failure()
        let outcome = try await makeBooker(manager).bookFocusEnd(
            sessionID: UUID(), endDate: clock.addingTimeInterval(600), playsSound: true, completionSound: .standard
        )
        guard case .notification(.accepted) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNotNil(focusRequest)
        XCTAssertEqual(requestedFiles, [.ringtone(.standard)])
        XCTAssertNil(scheduler.booking)
    }

    func testSoundOffOrNoPermissionNeverBooksAnAlarm() async throws {
        let manager = makeManager()
        await manager.refreshAuthorizationStatus()
        preferences.setStrength(.maximum)
        let booker = makeBooker(manager)

        let muted = try await booker.bookFocusEnd(
            sessionID: UUID(), endDate: clock.addingTimeInterval(600), playsSound: false, completionSound: .standard
        )
        guard case .notification = muted else { return XCTFail("\(muted)") }
        XCTAssertTrue(client.scheduled.isEmpty, "最大 never books AlarmKit with the app's sound off")

        client.authorization = .denied
        let session = UUID()
        let denied = try await booker.bookFocusEnd(
            sessionID: session, endDate: clock.addingTimeInterval(600), playsSound: true, completionSound: .standard
        )
        guard case .notification(.accepted) = denied else { return XCTFail("\(denied)") }
        XCTAssertTrue(client.scheduled.isEmpty)
    }

    func testAStrengthBelowMaximumCancelsALeftoverAlarm() async throws {
        let manager = makeManager()
        await manager.refreshAuthorizationStatus()
        let session = UUID()
        _ = await scheduler.schedule(sessionID: session, phase: .focus, endDate: clock.addingTimeInterval(600), soundFileName: nil)
        preferences.setStrength(.standard)
        let outcome = try await makeBooker(manager).bookFocusEnd(
            sessionID: session, endDate: clock.addingTimeInterval(600), playsSound: true, completionSound: .standard
        )
        guard case .notification(.accepted) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNil(scheduler.booking)
        XCTAssertTrue(client.scheduled.isEmpty)
    }

    func testAnAccountBoundaryBooksNothing() async throws {
        let manager = makeManager()
        await manager.refreshAuthorizationStatus()
        preferences.setStrength(.maximum)
        manager.suspendTimerSchedulingForAccountBoundary()
        XCTAssertFalse(manager.acceptsTimerScheduling)
        let outcome = try await makeBooker(manager).bookFocusEnd(
            sessionID: UUID(), endDate: clock.addingTimeInterval(600), playsSound: true, completionSound: .standard
        )
        XCTAssertEqual(outcome, .notification(.superseded))
        XCTAssertTrue(client.scheduled.isEmpty)
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: A cancel while the ringtone is prepared

    private func makeBooker(_ manager: NotificationManager, ringtone: HeldAlarmSoundFile) -> TimerEndAnnouncementBooker {
        TimerEndAnnouncementBooker(
            notifications: manager,
            systemAlarms: scheduler,
            preferences: preferences,
            ringtoneFileName: { _ in await ringtone.provide() }
        )
    }

    /// The ringtone may still be rendering when the person pauses (its
    /// first use, after complete deletion, after a file version bump). Every
    /// way a timer stops owning its end must reach that booking.
    func testEveryCancelWhileTheRingtoneIsPreparedBooksNothing() async throws {
        let manager = makeManager()
        await manager.refreshAuthorizationStatus()
        preferences.setStrength(.maximum)
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("timer-end-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: library) }
        let scheduler = self.scheduler!
        let cancels: [(String, FocusEndAlarmPhase, @MainActor (NotificationManager, UUID) async -> Void)] = [
            ("pause", .focus, { $0.cancelFocusCompletion(sessionID: $1) }),
            ("F1 auto-pause", .focus, { $0.cancelFocusCompletion(sessionID: $1, withdrawingLeaveNudges: false) }),
            ("skip the break", .breakTime, { $0.cancelBreakCompletion(id: $1) }),
            ("reset recovery", .focus, { manager, _ in await manager.prepareTimerNotificationCleanup()() }),
            ("account boundary", .focus, { manager, _ in manager.suspendTimerSchedulingForAccountBoundary() }),
            ("complete deletion", .breakTime, { _, _ in
                FocusEndAlarmMaintenance.eraseForCompleteDataDeletion(scheduler: scheduler, libraryDirectory: library)
            })
        ]
        for (name, phase, cancel) in cancels {
            let ringtone = HeldAlarmSoundFile()
            let booker = makeBooker(manager, ringtone: ringtone)
            let session = UUID()
            let end = clock.addingTimeInterval(1_500)
            let booking = Task {
                switch phase {
                case .focus:
                    try await booker.bookFocusEnd(sessionID: session, endDate: end, playsSound: true, completionSound: .standard)
                case .breakTime:
                    try await booker.bookBreakEnd(id: session, endDate: end, playsSound: true, completionSound: .standard)
                }
            }
            await ringtone.waitUntilHeld()
            await cancel(manager, session)
            ringtone.release()
            let outcome = try await booking.value

            XCTAssertEqual(outcome, .notification(.superseded), name)
            XCTAssertTrue(client.scheduled.isEmpty, "\(name): nothing may ring for a timer that stopped")
            XCTAssertNil(scheduler.booking, name)
            XCTAssertTrue(pending.isEmpty, name)
            manager.resumeTimerSchedulingAfterAccountBoundary()
        }
    }

    /// Start, then a quick pause and resume: the resumed end wins whichever
    /// ringtone call finishes first.
    func testTheNewerOfTwoOverlappingBookingsWins() async throws {
        let manager = makeManager()
        await manager.refreshAuthorizationStatus()
        preferences.setStrength(.maximum)
        let ringtone = HeldAlarmSoundFile()
        let booker = makeBooker(manager, ringtone: ringtone)
        let session = UUID()
        let started = clock.addingTimeInterval(1_500)
        let resumed = clock.addingTimeInterval(1_530)
        let first = Task {
            try await booker.bookFocusEnd(sessionID: session, endDate: started, playsSound: true, completionSound: .standard)
        }
        await ringtone.waitUntilHeld()
        let second = Task {
            try await booker.bookFocusEnd(sessionID: session, endDate: resumed, playsSound: true, completionSound: .standard)
        }
        await ringtone.waitUntilHeld(count: 2)

        ringtone.releaseLast("pomogem-alarm-standard-v1.caf")
        let newer = try await second.value
        ringtone.release()
        let older = try await first.value

        guard case let .systemAlarm(booking) = newer else { return XCTFail("\(newer)") }
        XCTAssertEqual(older, .notification(.superseded))
        XCTAssertEqual(booking.fireDate, resumed)
        XCTAssertEqual(client.scheduled.values.map(\.fireDate), [resumed])
        XCTAssertEqual(scheduler.booking, booking)
    }

    /// A caller cancelled after AlarmKit accepted the alarm still withdraws
    /// the earlier notification: the end is never announced twice.
    func testABookedAlarmWithdrawsTheNotificationEvenForACancelledCaller() async throws {
        let manager = makeManager()
        await manager.refreshAuthorizationStatus()
        let session = UUID()
        let end = clock.addingTimeInterval(1_500)
        _ = try await manager.scheduleFocusCompletion(sessionID: session, endDate: end)
        XCTAssertNotNil(focusRequest)

        preferences.setStrength(.maximum)
        let booker = makeBooker(manager)
        client.holdsSchedules = true
        let booking = Task {
            try await booker.bookFocusEnd(sessionID: session, endDate: end, playsSound: true, completionSound: .standard)
        }
        await client.waitForPendingSchedule()
        booking.cancel()
        client.releaseSchedules()
        let outcome = try await booking.value

        guard case .systemAlarm = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(client.scheduled.count, 1)
        XCTAssertNil(focusRequest, "one channel per end")
    }

    // MARK: Alarms without notification permission

    /// Someone who allowed alarms but declined notifications still gets the
    /// alarm the Settings status promises; the booker decides, so the timer
    /// screens call it whatever the notification permission.
    func testAlarmsAllowedWithNotificationsDeclinedBookExactlyOneAlarm() async throws {
        let manager = makeManager()
        XCTAssertFalse(manager.isAuthorized)
        preferences.setStrength(.maximum)
        let booker = makeBooker(manager)
        XCTAssertEqual(booker.channel(playsSound: true), .systemAlarm)
        let session = UUID()
        let end = clock.addingTimeInterval(1_500)
        guard case let .systemAlarm(booking) = try await booker.bookFocusEnd(
            sessionID: session, endDate: end, playsSound: true, completionSound: .standard
        ) else { return XCTFail("the alarm was not booked") }
        // The activation reschedule books the same end again.
        guard case let .systemAlarm(again) = try await booker.bookFocusEnd(
            sessionID: session, endDate: end, playsSound: true, completionSound: .standard
        ) else { return XCTFail("the alarm was not kept") }
        XCTAssertEqual(again, booking)
        XCTAssertEqual(Array(client.scheduled.keys), [booking.alarmID], "exactly one alarm")
        XCTAssertTrue(client.cancelled.isEmpty)
        XCTAssertTrue(pending.isEmpty, "no notification")
    }

    func testNothingCanAnnounceTheEndWithoutEitherPermission() async throws {
        let manager = makeManager()
        preferences.setStrength(.maximum)
        let booker = makeBooker(manager)
        let session = UUID()
        guard case .systemAlarm = try await booker.bookFocusEnd(
            sessionID: session, endDate: clock.addingTimeInterval(1_500), playsSound: true, completionSound: .standard
        ) else { return XCTFail("the alarm was not booked") }

        // Alarms turned off later: the leftover alarm goes, nothing replaces it.
        client.authorization = .denied
        XCTAssertEqual(booker.channel(playsSound: true), AlarmBackgroundChannel.none)
        let none = try await booker.bookFocusEnd(
            sessionID: session, endDate: clock.addingTimeInterval(1_500), playsSound: true, completionSound: .standard
        )
        XCTAssertEqual(none, .noChannel)
        XCTAssertNil(scheduler.booking)
        XCTAssertTrue(client.scheduled.isEmpty)
        XCTAssertTrue(pending.isEmpty)

        // AlarmKit refuses the booking and notifications are declined.
        client.authorization = .authorized
        client.scheduleError = FakeFocusEndAlarmClient.Failure()
        let failed = try await booker.bookBreakEnd(
            id: UUID(), endDate: clock.addingTimeInterval(300), playsSound: true, completionSound: .standard
        )
        XCTAssertEqual(failed, .noChannel)
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: The end (part 2 calls these too)

    func testTheHandOffCancelsTheAlarmOnlyWhenTheAppIsActiveJustBeforeTheEnd() async throws {
        let manager = makeManager()
        await manager.refreshAuthorizationStatus()
        preferences.setStrength(.maximum)
        let booker = makeBooker(manager)
        let session = UUID()
        let end = clock.addingTimeInterval(600)
        guard case let .systemAlarm(booking) = try await booker.bookFocusEnd(
            sessionID: session, endDate: end, playsSound: true, completionSound: .standard
        ) else { return XCTFail("the alarm was not booked") }

        XCTAssertNil(booker.handOffToForegroundIfDue(
            sessionID: session, endDate: end, applicationIsActive: true, now: end.addingTimeInterval(-10)
        ), "Too early")
        XCTAssertNil(booker.handOffToForegroundIfDue(
            sessionID: session, endDate: end, applicationIsActive: false, now: end.addingTimeInterval(-1)
        ), "Not looking at the timer")
        XCTAssertNil(booker.handOffToForegroundIfDue(
            sessionID: session, endDate: end, applicationIsActive: true, now: end
        ), "At the end the system alarm may already ring: resolve it instead")
        XCTAssertEqual(scheduler.booking, booking)
        XCTAssertTrue(client.cancelled.isEmpty)

        XCTAssertEqual(booker.handOffToForegroundIfDue(
            sessionID: session, endDate: end, applicationIsActive: true, now: end.addingTimeInterval(-1)
        ), end)
        XCTAssertNil(scheduler.booking, "The in-app alarm is the only one now")
        XCTAssertEqual(client.cancelled, [booking.alarmID])
        XCTAssertNil(focusRequest)

        // Locked before the end: the notification is booked at once, never
        // AlarmKit again, with this iPhone's long sound.
        let left = try await booker.bookFocusEndAfterLeavingDuringHandoff(
            sessionID: session, endDate: end, playsSound: true, completionSound: .standard,
            now: end.addingTimeInterval(-0.5)
        )
        guard case .accepted = left else { return XCTFail("\(String(describing: left))") }
        XCTAssertEqual(focusRequest?.content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(requestedFiles.last, .ringtone(.standard))
        XCTAssertEqual(client.scheduled.count, 0)

        // After the end the in-app alarm has started: leaving it is Stop.
        pending.removeAll()
        let late = try await booker.bookFocusEndAfterLeavingDuringHandoff(
            sessionID: session, endDate: end, playsSound: true, completionSound: .standard,
            now: end.addingTimeInterval(0.1)
        )
        XCTAssertNil(late)
        XCTAssertNil(focusRequest)

        let rest = try await booker.bookBreakEndAfterLeavingDuringHandoff(
            id: UUID(), endDate: end, playsSound: true, completionSound: .standard,
            now: end.addingTimeInterval(-0.5)
        )
        guard case .accepted = rest else { return XCTFail("\(String(describing: rest))") }
        XCTAssertNotNil(breakRequest)
    }

    func testLeavingDuringAHandOffBooksNothingWithoutNotificationPermission() async throws {
        let manager = makeManager()
        let booker = makeBooker(manager)
        XCTAssertFalse(manager.isAuthorized)
        let end = clock.addingTimeInterval(600)
        let left = try await booker.bookFocusEndAfterLeavingDuringHandoff(
            sessionID: UUID(), endDate: end, playsSound: true, completionSound: .standard,
            now: end.addingTimeInterval(-1)
        )
        XCTAssertNil(left)
        XCTAssertTrue(pending.isEmpty)
    }

    func testTheAlarmIsADeliveryWitnessOnceItsTimeCame() async throws {
        let manager = makeManager()
        let booker = makeBooker(manager)
        let session = UUID()
        let end = clock.addingTimeInterval(600)
        guard case let .booked(booking) = await scheduler.schedule(
            sessionID: session, phase: .focus, endDate: end, soundFileName: nil
        ) else { return XCTFail("the alarm was not booked") }
        func witnessed(_ now: Date) -> Bool {
            booker.externalAlertMayHaveFired(
                sessionID: session, notificationAuthorized: false, notificationDeliveryDate: nil, now: now
            )
        }
        XCTAssertFalse(witnessed(clock), "Nothing rang yet")

        clock = end.addingTimeInterval(1)
        client.states[booking.alarmID] = .alerting
        XCTAssertTrue(witnessed(clock), "Ringing now")
        XCTAssertFalse(booker.externalAlertMayHaveFired(
            sessionID: UUID(), notificationAuthorized: false, notificationDeliveryDate: nil, now: clock
        ), "Another session's alarm proves nothing")

        client.authorization = .denied
        XCTAssertFalse(witnessed(clock), "Alarms turned off: nothing announced the end")
        XCTAssertTrue(booker.externalAlertMayHaveFired(
            sessionID: session, notificationAuthorized: true,
            notificationDeliveryDate: end, now: clock
        ), "The notification witness still counts")
        XCTAssertEqual(scheduler.booking, booking, "Reading the witness changes nothing")
    }
}
