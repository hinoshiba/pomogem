import UserNotifications
import XCTest
@testable import PomoGem

/// The 「集中が切れています」 series (F1) in NotificationManager: bounded
/// one-shot requests, `.active` like every nudge, gated on permission and
/// both device switches, and withdrawn by every path that ends the absence.
@MainActor
final class FocusLeaveNudgeSchedulingTests: XCTestCase {
    private var fixture: NudgeFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try NudgeFixture()
    }

    override func tearDown() async throws {
        fixture.releaseHeldAdd()
        fixture.tearDown()
        fixture = nil
        try await super.tearDown()
    }

    func testTheSeriesIsFiveActiveOneShotsOnOneThread() async throws {
        let sessionID = UUID()
        let leftAt = Date.now
        let accepted = try await fixture.manager.scheduleFocusLeaveNudges(
            sessionID: sessionID,
            leftAt: leftAt,
            playsSound: true,
            completionSound: .soft
        )
        XCTAssertEqual(accepted, 5)
        let requests = FocusLeavePolicy.nudgeIdentifiers.compactMap { fixture.pending[$0] }
        XCTAssertEqual(requests.count, 5)
        for (index, request) in requests.enumerated() {
            XCTAssertEqual(request.content.interruptionLevel, .active, "A nudge is never Time Sensitive")
            XCTAssertEqual(request.content.threadIdentifier, FocusLeavePolicy.nudgeThreadIdentifier)
            XCTAssertEqual(request.content.title, "集中が切れています")
            XCTAssertEqual(request.content.body, FocusLeaveNudgeCopy.body(forNudgeAt: index))
            XCTAssertNil(request.content.badge)
            XCTAssertNotNil(request.content.sound)
            let trigger = try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger)
            XCTAssertFalse(trigger.repeats, "One-shots: the series stops by itself")
            XCTAssertEqual(
                trigger.timeInterval,
                FocusLeavePolicy.nudgeOffsets[index],
                accuracy: 2
            )
        }
    }

    func testSoundOffLeavesTheSeriesSilent() async throws {
        _ = try await fixture.manager.scheduleFocusLeaveNudges(
            sessionID: UUID(), leftAt: .now, playsSound: false
        )
        XCTAssertFalse(fixture.pending.isEmpty)
        XCTAssertTrue(fixture.pending.values.allSatisfy { $0.content.sound == nil })
    }

    func testLeaveNudgesStayActiveWhileOnlyTimerEndsAreTimeSensitive() async throws {
        let sessionID = UUID()
        _ = try await fixture.manager.scheduleFocusCompletion(
            sessionID: sessionID, endDate: .now.addingTimeInterval(600)
        )
        _ = try await fixture.manager.scheduleFocusLeaveNudges(
            sessionID: sessionID, leftAt: .now, playsSound: true
        )
        for request in fixture.pending.values {
            if request.identifier.hasPrefix("pomogem.focus.complete.") {
                XCTAssertEqual(request.content.interruptionLevel, .timeSensitive)
            } else {
                XCTAssertTrue(request.identifier.hasPrefix(FocusLeavePolicy.nudgeIdentifierPrefix))
                XCTAssertEqual(request.content.interruptionLevel, .active)
            }
        }
        XCTAssertEqual(fixture.pending.count, 6)
    }

    func testTheSeriesNeedsPermissionAndBothSwitches() async throws {
        for status in [UNAuthorizationStatus.denied, .notDetermined] {
            fixture.authorizationStatus = status
            let booked = try await fixture.manager.scheduleFocusLeaveNudges(
                sessionID: UUID(), leftAt: .now, playsSound: true
            )
            XCTAssertEqual(booked, 0)
            XCTAssertTrue(fixture.pending.isEmpty)
        }
        fixture.authorizationStatus = .authorized

        fixture.defaults.set(false, forKey: FocusLeavePolicy.nudgesEnabledDefaultsKey)
        var booked = try await fixture.manager.scheduleFocusLeaveNudges(
            sessionID: UUID(), leftAt: .now, playsSound: true
        )
        XCTAssertEqual(booked, 0)
        XCTAssertTrue(fixture.pending.isEmpty)

        fixture.defaults.set(true, forKey: FocusLeavePolicy.nudgesEnabledDefaultsKey)
        fixture.defaults.set(false, forKey: FocusLeavePolicy.enabledDefaultsKey)
        booked = try await fixture.manager.scheduleFocusLeaveNudges(
            sessionID: UUID(), leftAt: .now, playsSound: true
        )
        XCTAssertEqual(booked, 0, "The series says the timer paused; without the pause it would lie")
        XCTAssertTrue(fixture.pending.isEmpty)
    }

    func testAnOverdueRequestIsSkippedRatherThanSentInABurst() async throws {
        let booked = try await fixture.manager.scheduleFocusLeaveNudges(
            sessionID: UUID(),
            leftAt: .now.addingTimeInterval(-150),
            playsSound: true
        )
        XCTAssertEqual(booked, 3)
        XCTAssertNil(fixture.pending[FocusLeavePolicy.nudgeIdentifiers[0]])
        XCTAssertNil(fixture.pending[FocusLeavePolicy.nudgeIdentifiers[1]])
    }

    func testWithdrawalRemovesPendingAndDelivered() async throws {
        _ = try await fixture.manager.scheduleFocusLeaveNudges(
            sessionID: UUID(), leftAt: .now, playsSound: true
        )
        fixture.manager.cancelFocusLeaveNudges()
        XCTAssertTrue(fixture.pending.isEmpty)
        XCTAssertEqual(Set(fixture.removedDelivered), Set(FocusLeavePolicy.nudgeIdentifiers))
    }

    func testTheLeavePauseKeepsTheSeriesButEndingTheFocusWithdrawsIt() async throws {
        let sessionID = UUID()
        _ = try await fixture.manager.scheduleFocusCompletion(
            sessionID: sessionID, endDate: .now.addingTimeInterval(600)
        )
        _ = try await fixture.manager.scheduleFocusLeaveNudges(
            sessionID: sessionID, leftAt: .now, playsSound: true
        )
        // Pausing because the person left removes only the end alert.
        fixture.manager.cancelFocusCompletion(sessionID: sessionID, withdrawingLeaveNudges: false)
        XCTAssertEqual(Set(fixture.pending.keys), Set(FocusLeavePolicy.nudgeIdentifiers))

        // Another session's end does not touch this series.
        fixture.manager.cancelFocusCompletion(sessionID: UUID())
        XCTAssertEqual(fixture.pending.count, 5)

        // Abort, completion or ownership loss of this session does.
        fixture.manager.cancelFocusCompletion(sessionID: sessionID)
        XCTAssertTrue(fixture.pending.isEmpty)
    }

    func testAccountBoundaryAndResetCleanupWithdrawTheSeries() async throws {
        let sessionID = UUID()
        _ = try await fixture.manager.scheduleFocusLeaveNudges(
            sessionID: sessionID, leftAt: .now, playsSound: true
        )
        let cleanup = fixture.manager.prepareTimerNotificationCleanup()
        XCTAssertTrue(fixture.pending.isEmpty, "Reset and complete deletion")
        await cleanup()

        _ = try await fixture.manager.scheduleFocusLeaveNudges(
            sessionID: sessionID, leftAt: .now, playsSound: true
        )
        // A recovery that preserves this focus keeps its series.
        let preserving = fixture.manager.prepareTimerNotificationCleanup(preserving: sessionID)
        await preserving()
        XCTAssertEqual(fixture.pending.count, 5)

        fixture.manager.suspendTimerSchedulingForAccountBoundary()
        XCTAssertTrue(fixture.pending.isEmpty)
        let afterBoundary = try await fixture.manager.scheduleFocusLeaveNudges(
            sessionID: sessionID, leftAt: .now, playsSound: true
        )
        XCTAssertEqual(afterBoundary, 0)
        XCTAssertTrue(fixture.pending.isEmpty)
    }

    func testTurningEitherSwitchOffWithdrawsABookedSeries() async throws {
        _ = try await fixture.manager.scheduleFocusLeaveNudges(
            sessionID: UUID(), leftAt: .now, playsSound: true
        )
        FocusLeavePreferences.setNudgesEnabled(
            false, defaults: fixture.defaults, notifications: fixture.manager
        )
        XCTAssertTrue(fixture.pending.isEmpty)
        XCTAssertEqual(fixture.defaults.object(forKey: FocusLeavePolicy.nudgesEnabledDefaultsKey) as? Bool, false)

        FocusLeavePreferences.setNudgesEnabled(
            true, defaults: fixture.defaults, notifications: fixture.manager
        )
        _ = try await fixture.manager.scheduleFocusLeaveNudges(
            sessionID: UUID(), leftAt: .now, playsSound: true
        )
        XCTAssertEqual(fixture.pending.count, 5)
        FocusLeavePreferences.setLeavePauseEnabled(
            false, defaults: fixture.defaults, notifications: fixture.manager
        )
        XCTAssertTrue(fixture.pending.isEmpty)
    }

    /// The host treats the registered running focus as proof that this
    /// device owns the timer it may pause, so the registration must end
    /// with the running state: a second background while leave-paused is
    /// not a new absence.
    func testTheRegisteredRunningFocusIsTheLeaveCandidateOnlyWhileItRuns() {
        let sessionID = UUID()
        let endDate = Date.now.addingTimeInterval(600)
        XCTAssertNil(fixture.manager.registeredRunningFocus)
        fixture.manager.registerFocusReturnReminder(
            sessionID: sessionID,
            endDate: endDate,
            playsSound: false,
            completionSound: .soft
        )
        XCTAssertEqual(
            fixture.manager.registeredRunningFocus,
            FocusLeaveCandidate(
                sessionID: sessionID,
                endDate: endDate,
                playsSound: false,
                completionSound: .soft
            )
        )

        // Another session's end leaves it alone.
        fixture.manager.cancelFocusCompletion(sessionID: UUID())
        XCTAssertEqual(fixture.manager.registeredRunningFocus?.sessionID, sessionID)

        // The leave pause keeps its series but ends the running timer.
        fixture.manager.cancelFocusCompletion(sessionID: sessionID, withdrawingLeaveNudges: false)
        XCTAssertNil(fixture.manager.registeredRunningFocus)

        // An account boundary forgets it and refuses new registrations
        // until the next account's container has mounted.
        fixture.manager.registerFocusReturnReminder(
            sessionID: sessionID, endDate: endDate, playsSound: true
        )
        fixture.manager.suspendTimerSchedulingForAccountBoundary()
        XCTAssertNil(fixture.manager.registeredRunningFocus)
        fixture.manager.registerFocusReturnReminder(
            sessionID: sessionID, endDate: endDate, playsSound: true
        )
        XCTAssertNil(fixture.manager.registeredRunningFocus)
        fixture.manager.resumeTimerSchedulingAfterAccountBoundary()
    }

    func testALateAddCannotOutliveAWithdrawal() async throws {
        let held = fixture.holdNextAdd()
        let schedule = Task {
            try await fixture.manager.scheduleFocusLeaveNudges(
                sessionID: UUID(), leftAt: .now, playsSound: true
            )
        }
        await fulfillment(of: [held], timeout: 2)
        // The person came back (or locked the phone) while the add waited.
        fixture.manager.cancelFocusLeaveNudges()
        fixture.releaseHeldAdd()
        let booked = try await schedule.value
        XCTAssertEqual(booked, 0)
        XCTAssertTrue(fixture.pending.isEmpty)
    }
}

@MainActor
private final class NudgeFixture {
    let suite = "FocusLeaveNudges.\(UUID().uuidString)"
    let defaults: UserDefaults
    var pending: [String: UNNotificationRequest] = [:]
    private(set) var removedDelivered: [String] = []
    var authorizationStatus: UNAuthorizationStatus = .authorized
    private(set) var manager: NotificationManager!
    private var heldAdd: CheckedContinuation<Void, Never>?
    private var holdStarted: XCTestExpectation?

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: FocusLeavePolicy.enabledDefaultsKey)
        defaults.set(true, forKey: FocusLeavePolicy.nudgesEnabledDefaultsKey)
        let add: (UNNotificationRequest) async throws -> Void = { [self] request in
            if let started = holdStarted {
                holdStarted = nil
                await withCheckedContinuation { continuation in
                    heldAdd = continuation
                    started.fulfill()
                }
            }
            pending[request.identifier] = request
        }
        let removePending: ([String]) -> Void = { [self] identifiers in
            for identifier in identifiers { pending.removeValue(forKey: identifier) }
        }
        manager = NotificationManager(
            requestClient: NotificationRequestClient(
                add: add,
                pending: { [self] in Array(pending.values) },
                removePending: removePending
            ),
            focusReturnReminderClient: FocusReturnReminderNotificationClient(
                authorizationStatus: { [self] in authorizationStatus },
                add: add,
                removePending: removePending,
                removeDelivered: { [self] in removedDelivered.append(contentsOf: $0) }
            ),
            focusReturnReminderDefaults: defaults
        )
    }

    func holdNextAdd() -> XCTestExpectation {
        let started = XCTestExpectation(description: "add held")
        holdStarted = started
        return started
    }

    func releaseHeldAdd() {
        heldAdd?.resume()
        heldAdd = nil
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }
}
