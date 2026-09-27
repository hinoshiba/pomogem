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
                    return self.fileAvailable ? UNNotificationSound(named: UNNotificationSoundName("fake.caf")) : nil
                }
            ) : nil,
            systemAlarms: scheduler
        )
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
        XCTAssertNotNil(focusRequest?.content.sound)
        XCTAssertNotNil(breakRequest?.content.sound)
        // The Time Sensitive invariant is unchanged.
        XCTAssertEqual(focusRequest?.content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(breakRequest?.content.interruptionLevel, .timeSensitive)
    }

    func testEachStrengthAndChoiceGetsItsOwnFile() async throws {
        let manager = makeManager()
        preferences.select(.alarmClock)
        _ = try await manager.scheduleFocusCompletion(sessionID: UUID(), endDate: clock.addingTimeInterval(600))
        preferences.setStrength(.gentle)
        _ = try await manager.scheduleFocusCompletion(sessionID: UUID(), endDate: clock.addingTimeInterval(600))
        preferences.select(.bright)
        _ = try await manager.scheduleFocusCompletion(
            sessionID: UUID(), endDate: clock.addingTimeInterval(600), completionSound: .bright
        )
        XCTAssertEqual(requestedFiles, [.ringtone(.alarmClock), .alarmCue(.alarmClock)],
                       "控えめ with an original chime keeps today's file and asks for nothing")
        XCTAssertEqual(pending.count, 3)
        XCTAssertTrue(pending.values.allSatisfy { $0.content.sound != nil })
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
        XCTAssertNotNil(focusRequest?.content.sound, "The short chime stands in")
    }

    func testAManagerWithoutAlarmSoundsKeepsTodaysChime() async throws {
        let manager = makeManager(sounds: false)
        _ = try await manager.scheduleFocusCompletion(sessionID: UUID(), endDate: clock.addingTimeInterval(600))
        XCTAssertNotNil(focusRequest?.content.sound)
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
}
