import UserNotifications
import XCTest
@testable import PomoGem

/// F5: how FocusView and BreakTimerView wire `TimerEndAnnouncementBooker`
/// (`TimerEndAnnouncementWiring`, `TimerEndHandoff`, `BreakEndAlertPolicy`),
/// the idle-timer decision while the alarm rings, and F2's notice line on
/// the focus screen (`FocusTimerNoticeLine`). Whether an end rings in the
/// app stays #49's `TimerForegroundResolution`; these tests drive it only to
/// show a settled booking never leaves it waiting.
@MainActor
final class TimerEndAnnouncementWiringTests: XCTestCase {
    private typealias Wiring = TimerEndAnnouncementWiring

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var preferences: AlarmPreferences!
    private var client: FakeFocusEndAlarmClient!
    private var scheduler: FocusEndAlarmScheduler!
    private var clock: Date!
    private var pending: [String: UNNotificationRequest] = [:]

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "timer-end-wiring-\(UUID().uuidString)"
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
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeManager() -> NotificationManager {
        let requests = NotificationRequestClient(
            add: { [unowned self] in self.pending[$0.identifier] = $0 },
            pending: { [unowned self] in Array(self.pending.values) },
            removePending: { [unowned self] ids in
                for id in ids { self.pending.removeValue(forKey: id) }
            }
        )
        let preferences = self.preferences!
        return NotificationManager(
            requestClient: requests,
            focusReturnReminderClient: FocusReturnReminderNotificationClient(
                authorizationStatus: { .authorized },
                add: requests.add,
                removePending: requests.removePending,
                removeDelivered: { _ in }
            ),
            timerEndSounds: TimerEndNotificationSounds(
                strength: { preferences.strength },
                choice: { preferences.sound(legacy: $0) },
                file: { _ in nil }
            ),
            systemAlarms: scheduler
        )
    }

    private func makeBooker(
        _ manager: NotificationManager,
        ringtone: HeldAlarmSoundFile? = nil
    ) -> TimerEndAnnouncementBooker {
        TimerEndAnnouncementBooker(
            notifications: manager,
            systemAlarms: scheduler,
            preferences: preferences,
            ringtoneFileName: { choice in
                if let ringtone { return await ringtone.provide() }
                return AlarmSoundLibrary.fileName(for: choice)
            }
        )
    }

    private var focusRequest: UNNotificationRequest? {
        pending.values.first { $0.identifier.hasPrefix("pomogem.focus.complete.") }
    }

    // MARK: Settling the screen's end-alert state

    func testEveryBookerOutcomeLeavesTheSchedulingState() throws {
        let date = clock.addingTimeInterval(600)
        let booking = FocusEndAlarmBooking(
            alarmID: UUID(), sessionID: UUID(), phase: .focus, fireDate: date, soundFileName: nil
        )
        XCTAssertEqual(Wiring.settlement(for: .notification(.accepted(deliveryDate: date))),
                       .notification(deliveryDate: date), "Today's witness")
        XCTAssertEqual(Wiring.settlement(for: .systemAlarm(booking)), .systemAlarm,
                       "No notification delivery date: the alarm keeps its own witness")
        XCTAssertEqual(Wiring.settlement(for: .notification(.deferredToSystemAlarm)), .systemAlarm)
        XCTAssertEqual(Wiring.settlement(for: .noChannel), .noChannel)
        XCTAssertEqual(Wiring.settlement(for: .notification(.superseded)), .superseded)

        XCTAssertTrue(Wiring.settlesSupersededAsIdle(generationIsCurrent: true, isScheduling: true),
                      "Nothing newer took the state (an account boundary): never wait forever")
        XCTAssertFalse(Wiring.settlesSupersededAsIdle(generationIsCurrent: false, isScheduling: true),
                       "A newer booking owns the state")
        XCTAssertFalse(Wiring.settlesSupersededAsIdle(generationIsCurrent: true, isScheduling: false),
                       "A pause already settled it")
    }

    func testOnlyAChannelThatBooksSomethingShowsTheSpinner() {
        XCTAssertTrue(Wiring.showsScheduling(for: .systemAlarm))
        XCTAssertTrue(Wiring.showsScheduling(for: .timeSensitiveNotification(.ringtone)))
        XCTAssertTrue(Wiring.showsScheduling(for: .timeSensitiveNotification(.silent)))
        XCTAssertFalse(Wiring.showsScheduling(for: .none),
                       "Without permission the permission row stays; the booker only withdraws a leftover alarm")
    }

    /// Alarms allowed, notifications declined, 最大: the start books exactly
    /// one alarm and no notification, settles as the alarm, and #49's
    /// resolver finishes the end on screen instead of waiting for a
    /// notification that will never be added.
    func testAnAlarmOnlyStartSettlesSoTheEndResolvesOnScreen() async throws {
        let manager = makeManager()
        XCTAssertFalse(manager.isAuthorized)
        preferences.setStrength(.maximum)
        let booker = makeBooker(manager)
        let channel = booker.channel(playsSound: true)
        XCTAssertEqual(channel, .systemAlarm)
        XCTAssertTrue(Wiring.showsScheduling(for: channel))

        let session = UUID()
        let end = clock.addingTimeInterval(1_500)
        let outcome = try await booker.bookFocusEnd(
            sessionID: session, endDate: end, playsSound: true, completionSound: .standard
        )
        XCTAssertEqual(Wiring.settlement(for: outcome), .systemAlarm)
        XCTAssertEqual(client.scheduled.count, 1)
        XCTAssertNil(focusRequest)

        var resolution = TimerForegroundResolution(isRecovery: false)
        resolution.observeAppearance(sceneIsActive: true)
        resolution.finishAuthorizationRefresh(startedIn: resolution.generation)
        XCTAssertEqual(
            resolution.tick(isElapsed: true, scenePhaseIsActive: true, isSchedulingNotification: false),
            .resolve(recoveredAfterExpiration: false),
            "A settled alarm booking lets the end on screen ring"
        )
    }

    /// Turning the app's sound off at 最大 without notification permission:
    /// the screens still call the booker, which withdraws the alarm (最大
    /// never books AlarmKit with the sound off) and settles as no channel.
    func testNoChannelStillWithdrawsALeftoverAlarm() async throws {
        let manager = makeManager()
        preferences.setStrength(.maximum)
        let booker = makeBooker(manager)
        let session = UUID()
        let end = clock.addingTimeInterval(1_500)
        _ = try await booker.bookFocusEnd(sessionID: session, endDate: end, playsSound: true, completionSound: .standard)
        XCTAssertNotNil(scheduler.booking)

        XCTAssertEqual(booker.channel(playsSound: false), AlarmBackgroundChannel.none)
        let muted = try await booker.bookFocusEnd(
            sessionID: session, endDate: end, playsSound: false, completionSound: .standard
        )
        XCTAssertEqual(Wiring.settlement(for: muted), .noChannel)
        XCTAssertNil(scheduler.booking)
        XCTAssertTrue(client.scheduled.isEmpty)
    }

    // MARK: The hand-off just before the end

    func testLeavingAfterTheHandOffRebooksOnlyTheSameRunningEndOnce() {
        let session = UUID()
        let end = clock.addingTimeInterval(1)
        var handoff = TimerEndHandoff()
        XCTAssertNil(handoff.endToRebookOnLeaving(
            sessionID: session, endDate: end, isRunning: true, now: clock
        ), "Nothing was handed off")

        handoff.record(sessionID: session, endDate: end)
        XCTAssertEqual(handoff.endToRebookOnLeaving(
            sessionID: session, endDate: end, isRunning: true, now: clock
        ), end)
        XCTAssertNil(handoff.endToRebookOnLeaving(
            sessionID: session, endDate: end, isRunning: true, now: clock
        ), "Once: .inactive then .background books one notification")

        let refusals: [(String, UUID, Date, Bool, Date)] = [
            ("paused in between", session, end, false, clock),
            ("another session", UUID(), end, true, clock),
            ("a new end (resumed)", session, end.addingTimeInterval(30), true, clock),
            ("the end has passed: the in-app alarm rings, leaving is Stop", session, end, true, end)
        ]
        for (name, current, currentEnd, isRunning, now) in refusals {
            handoff.record(sessionID: session, endDate: end)
            XCTAssertNil(handoff.endToRebookOnLeaving(
                sessionID: current, endDate: currentEnd, isRunning: isRunning, now: now
            ), name)
            XCTAssertEqual(handoff, TimerEndHandoff(), "\(name): the record is gone")
        }
    }

    /// The whole hand-off as the screens run it: the ticker takes the end
    /// over 1 s before it (the alarm is cancelled), the scene goes inactive,
    /// and the notification is booked in its place.
    func testTheHandOffAndTheRebookKeepExactlyOneChannel() async throws {
        let manager = makeManager()
        await manager.refreshAuthorizationStatus()
        preferences.setStrength(.maximum)
        let booker = makeBooker(manager)
        let session = UUID()
        let end = clock.addingTimeInterval(600)
        guard case let .systemAlarm(booking) = try await booker.bookFocusEnd(
            sessionID: session, endDate: end, playsSound: true, completionSound: .standard
        ) else { return XCTFail("the alarm was not booked") }

        var handoff = TimerEndHandoff()
        let now = end.addingTimeInterval(-1)
        let handedOff = try XCTUnwrap(booker.handOffToForegroundIfDue(
            sessionID: session, endDate: end, applicationIsActive: true, now: now
        ))
        handoff.record(sessionID: session, endDate: handedOff)
        XCTAssertEqual(client.cancelled, [booking.alarmID], "Only the in-app alarm will ring")
        XCTAssertNil(booker.handOffToForegroundIfDue(
            sessionID: session, endDate: end, applicationIsActive: true, now: now.addingTimeInterval(0.25)
        ), "Later ticks hand off nothing and must not clear the record")

        let rebook = try XCTUnwrap(handoff.endToRebookOnLeaving(
            sessionID: session, endDate: end, isRunning: true, now: now.addingTimeInterval(0.5)
        ))
        let left = try await booker.bookFocusEndAfterLeavingDuringHandoff(
            sessionID: session, endDate: rebook, playsSound: true, completionSound: .standard,
            now: now.addingTimeInterval(0.5)
        )
        guard case .accepted = left else { return XCTFail("\(String(describing: left))") }
        XCTAssertNotNil(focusRequest)
        XCTAssertTrue(client.scheduled.isEmpty, "Never AlarmKit again this close to the end")
    }

    /// A hand-off while the booking is still preparing its ringtone: the
    /// booking books nothing (the screen ignores its superseded answer and
    /// shows the end as its own), and the hand-off still reports the end so
    /// leaving can rebook it.
    func testAHandOffDuringAnInFlightBookingStillReportsTheEnd() async throws {
        let manager = makeManager()
        await manager.refreshAuthorizationStatus()
        preferences.setStrength(.maximum)
        let ringtone = HeldAlarmSoundFile()
        let booker = makeBooker(manager, ringtone: ringtone)
        let session = UUID()
        let end = clock.addingTimeInterval(600)
        let booking = Task {
            try await booker.bookFocusEnd(sessionID: session, endDate: end, playsSound: true, completionSound: .standard)
        }
        await ringtone.waitUntilHeld()
        XCTAssertEqual(booker.handOffToForegroundIfDue(
            sessionID: session, endDate: end, applicationIsActive: true, now: end.addingTimeInterval(-1)
        ), end)
        ringtone.release()
        let outcome = try await booking.value
        XCTAssertEqual(Wiring.settlement(for: outcome), .superseded)
        XCTAssertTrue(client.scheduled.isEmpty)
    }

    // MARK: The cue and the acknowledgement

    /// The cue's witness: an alarm whose time came counts even when the
    /// notification date is dropped for untrustworthy timing, and a
    /// completion resolved on screen stops a ringing alarm while keeping it
    /// as the witness.
    func testTheAlarmWitnessSurvivesTheAcknowledgementThatStopsIt() async throws {
        let manager = makeManager()
        let booker = makeBooker(manager)
        let session = UUID()
        let end = clock.addingTimeInterval(600)
        guard case let .booked(booking) = await scheduler.schedule(
            sessionID: session, phase: .focus, endDate: end, soundFileName: nil
        ) else { return XCTFail("the alarm was not booked") }
        clock = end.addingTimeInterval(5)
        client.states[booking.alarmID] = .alerting

        func fired() -> Bool {
            booker.externalAlertMayHaveFired(
                sessionID: session, notificationAuthorized: true,
                notificationDeliveryDate: nil, now: clock
            )
        }
        XCTAssertTrue(fired(), "Untrusted notification timing does not hide the alarm")
        let cue = TimerCompletionForegroundFeedbackPolicy.cue(
            recoveredAfterExpiration: false, returnedFromBackground: true,
            notificationMayHaveDelivered: fired(), endedAt: end, now: clock
        )
        XCTAssertEqual(cue, TimerCompletionForegroundFeedbackPolicy.Cue.none,
                       "The alarm announced the end: a return opens the result without a cue")

        booker.acknowledgeEnd(sessionID: session)
        XCTAssertEqual(client.stopped, [booking.alarmID], "Returning while it rings is Stop")
        XCTAssertTrue(fired(), "The alarm that rang stays the witness")
        booker.acknowledgeEnd(sessionID: session)
        XCTAssertEqual(client.stopped, [booking.alarmID], "Repeated resolutions change nothing")
    }

    // MARK: Keeping the screen awake while the alarm rings

    /// The completion path used to set `isIdleTimerDisabled = false`, so
    /// auto-lock ended the alarm (leaving counts as Stop). The screens now
    /// ask the same policy on completion: at 標準 the ringing alarm holds
    /// the display over a finished timer, and lets it go at Stop.
    func testTheRingingAlarmHoldsTheDisplayOverAFinishedTimerUntilStop() {
        for (strength, holds) in [(AlarmStrength.standard, true), (.maximum, true), (.gentle, false)] {
            let player = SilentAlarmPlayer()
            let controller = TimerCompletionAlertController(
                sleeper: { try await Task.sleep(for: .seconds(3_600)) },
                player: player,
                planner: { configuration, cue in
                    TimerCompletionAlarmRequest.resolve(
                        configuration: configuration, cue: cue, strength: strength, sound: .bell
                    )
                },
                applicationIsActive: { true }
            )
            let alarm = TimerCompletionAlertConfiguration(sessionID: UUID(), sound: .standard, haptic: .standard)
            controller.start(alarm)
            func keepsAwake(sceneIsActive: Bool = true) -> Bool {
                TimerCompletionAlarmScreenAwakePolicy.shouldKeepScreenAwake(
                    runningTimerKeepsScreenAwake: TimerScreenAwakePolicy.shouldKeepScreenAwake(
                        preferenceEnabled: true, sceneIsActive: sceneIsActive,
                        timerIsRunning: false, remainingSeconds: 0
                    ),
                    sceneIsActive: sceneIsActive,
                    alarmKeepsScreenAwake: controller.keepsScreenAwake(sessionID: alarm.sessionID)
                )
            }
            XCTAssertEqual(keepsAwake(), holds, "\(strength) while ringing")
            XCTAssertFalse(keepsAwake(sceneIsActive: false), "\(strength): never while inactive")
            controller.stop(sessionID: alarm.sessionID)
            XCTAssertFalse(keepsAwake(), "\(strength) after Stop")
            XCTAssertEqual(player.stops, 1)
        }
    }

    // MARK: BreakTimerView

    func testTheBreakBooksAnAllowedAlarmWhateverTheNotificationPermission() {
        typealias Policy = BreakEndAlertPolicy
        let ringtone = AlarmBackgroundChannel.timeSensitiveNotification(.ringtone)
        for status in [UNAuthorizationStatus.denied, .notDetermined, .authorized] {
            XCTAssertEqual(
                Policy.action(notificationStatus: status, channel: .systemAlarm, requestsAuthorization: false),
                .book, "\(status.rawValue): alarms need no notification permission"
            )
        }
        XCTAssertEqual(Policy.action(notificationStatus: .authorized, channel: ringtone, requestsAuthorization: false), .book)
        XCTAssertEqual(Policy.action(notificationStatus: .provisional, channel: ringtone, requestsAuthorization: false), .book)
        XCTAssertEqual(Policy.action(notificationStatus: .denied, channel: .none, requestsAuthorization: true), .showDenied,
                       "The denied row, which also withdraws a leftover alarm")
        XCTAssertEqual(Policy.action(notificationStatus: .notDetermined, channel: .none, requestsAuthorization: false),
                       .showPermissionNotDetermined)
        XCTAssertEqual(Policy.action(notificationStatus: .notDetermined, channel: .none, requestsAuthorization: true),
                       .requestAuthorization, "The retry button asks")

        XCTAssertEqual(Policy.actionWithoutChannel(notificationStatus: .denied), .showDenied)
        XCTAssertEqual(Policy.actionWithoutChannel(notificationStatus: .notDetermined), .showPermissionNotDetermined)
        XCTAssertEqual(Policy.actionWithoutChannel(notificationStatus: .authorized), .showFailed)
    }

    // MARK: F2's notice line on the focus screen

    func testTheNoticeLineOrderIsLeavePauseFailureShieldThenTheEndAlert() {
        typealias Line = FocusTimerNoticeLine
        func line(_ running: Bool = true, leave: Bool = false, failed: Bool = false, shield: Bool = false) -> Line {
            Line.resolve(
                timerIsRunningOrPaused: running, showsLeavePause: leave,
                endAlertFailed: failed, isShielding: shield
            )
        }
        XCTAssertEqual(line(false, shield: true), .none, "Only a running or paused focus has the line")
        XCTAssertEqual(line(leave: true, failed: true, shield: true), .leavePause,
                       "F1 explains a pause the person did not tap")
        XCTAssertEqual(line(failed: true, shield: true), .endAlertFailure,
                       "An end that will not be announced unless they retry")
        XCTAssertEqual(line(shield: true), .shield,
                       "Over the running promise, the paused note and the permission rows")
        XCTAssertEqual(line(), .endAlert)
    }
}

/// Counts what the alarm controller asks of its player; plays nothing.
@MainActor
private final class SilentAlarmPlayer: TimerCompletionAlarmPlayer {
    private(set) var stops = 0
    func playCue(_ request: TimerCompletionAlarmRequest) {}
    func sustainLoop(_ request: TimerCompletionAlarmRequest) {}
    func stop() { stops += 1 }
}
