import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import SwiftUI
import XCTest
@testable import PomoGem

/// F2 (app side): which timer states shield, the reconcile decisions, the
/// settings model, and the paths in `ScreenTimeController` that must lift a
/// shield (owner retirement, revocation, complete deletion).
@MainActor
final class FocusShieldControllerTests: XCTestCase {
    private var directories: [URL] = []
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    // MARK: - which timer state is "in a focus"

    func testOnlyAFocusPhaseOfThisGenerationCounts() throws {
        let epoch = UUID()
        var focusing = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try focusing.startFocus(isPro: false, now: now)
        let session = try XCTUnwrap(focusing.currentSessionID)
        let end = try XCTUnwrap(focusing.endDate)
        XCTAssertEqual(state(focusing, epoch: epoch), .running(sessionID: session, plannedEnd: end))
        XCTAssertEqual(state(focusing, epoch: epoch, currentEpoch: UUID()), .none,
                       "A timer frozen under another reset generation is being retired, not run")
        XCTAssertEqual(FocusShieldFocusState(envelope: nil, dataEpochID: epoch), .none)

        var paused = focusing
        try paused.pause(at: now.addingTimeInterval(120))
        XCTAssertEqual(state(paused, epoch: epoch), .paused(sessionID: session))

        var completed = focusing
        let event = try XCTUnwrap(completed.advance(at: end))
        guard case let .focusCompleted(completion) = event else { return XCTFail("Expected a completion") }
        XCTAssertEqual(state(completed, epoch: epoch), .none)
        let pending = FocusRecoveryEnvelope(engine: completed, subject: nil, clockAnchor: nil,
                                            pendingCompletion: completion, savedAt: end, dataEpochID: epoch)
        XCTAssertEqual(FocusShieldFocusState(envelope: pending, dataEpochID: epoch), .none)

        var onBreak = completed
        try onBreak.startBreak(now: end.addingTimeInterval(10))
        XCTAssertEqual(state(onBreak, epoch: epoch), .none, "Breaks are never shielded")
        var pausedBreak = onBreak
        try pausedBreak.pause(at: end.addingTimeInterval(60))
        XCTAssertEqual(state(pausedBreak, epoch: epoch), .none)
    }

    // MARK: - decisions

    func testARunningFocusShieldsUntilItsPlannedEndPlusOneMinute() {
        let session = UUID()
        let end = now.addingTimeInterval(1_500)
        let running = FocusShieldFocusState.running(sessionID: session, plannedEnd: end)
        XCTAssertEqual(decide(focus: running), .apply(sessionID: session, deadline: end.addingTimeInterval(60)))
        XCTAssertEqual(decide(focus: running, at: end.addingTimeInterval(-1)),
                       .apply(sessionID: session, deadline: end.addingTimeInterval(60)))
        // Past the planned end, not advanced yet: the failsafe lifts the shield
        // at that very moment, so one that is up is kept for the grace and
        // none is started or put back.
        let own = active(session, deadline: end.addingTimeInterval(60))
        XCTAssertEqual(decide(focus: running, record: own, at: end), .keep)
        XCTAssertEqual(decide(focus: running, record: own, at: end.addingTimeInterval(30)), .keep)
        XCTAssertEqual(decide(focus: running, at: end.addingTimeInterval(30)), .idle,
                       "Never re-armed after the extension lifted it at the planned end")
        XCTAssertEqual(decide(focus: running, record: active(UUID(), deadline: end.addingTimeInterval(60)),
                              at: end.addingTimeInterval(30)), .clear(.deadlinePassed))
        XCTAssertEqual(decide(focus: running, record: own, at: end.addingTimeInterval(60)), .clear(.deadlinePassed))
        XCTAssertEqual(decide(focus: running, at: end.addingTimeInterval(60)), .idle)
    }

    func testPausesKeepTheShieldUntilTheDeadlineOfTheLastRunningState() {
        let session = UUID()
        let record = active(session, deadline: now.addingTimeInterval(1_560))
        XCTAssertEqual(decide(focus: .paused(sessionID: session), record: record), .keep)
        XCTAssertEqual(decide(focus: .paused(sessionID: session), record: record, at: now.addingTimeInterval(1_560)),
                       .clear(.deadlinePassed), "An auto-paused focus left overnight lifts at its deadline")
        XCTAssertEqual(decide(focus: .paused(sessionID: session), record: nil), .idle,
                       "A pause never creates a shield of its own")
        XCTAssertEqual(decide(focus: .paused(sessionID: UUID()), record: record), .clear(.focusEnded))
    }

    func testEveryEndOfTheFocusLiftsTheShield() {
        let session = UUID()
        let record = active(session, deadline: now.addingTimeInterval(1_560))
        let running = FocusShieldFocusState.running(sessionID: session, plannedEnd: now.addingTimeInterval(1_500))
        XCTAssertEqual(decide(focus: .none, record: record), .clear(.focusEnded),
                       "Completion, abandon, break start and ownership loss all leave no focus")
        XCTAssertEqual(decide(enabled: false, focus: running, record: record), .clear(.featureOff))
        XCTAssertEqual(decide(apps: 0, focus: running, record: record), .clear(.noApplications))
        XCTAssertEqual(decide(apps: 51, focus: running, record: record), .clear(.tooManyApplications))
        XCTAssertEqual(decide(apps: 50, focus: running, record: record),
                       .apply(sessionID: session, deadline: now.addingTimeInterval(1_560)))
        XCTAssertEqual(decide(authorization: .denied, focus: running, record: record), .clear(.authorizationDenied))
        XCTAssertEqual(decide(focus: .none, record: nil), .idle)
        var expired = record
        expired.deadline = now
        XCTAssertEqual(decide(focus: running, record: expired), .clear(.deadlinePassed),
                       "An expired record is cleared before anything else is considered")
    }

    func testAnUnsettledAuthorizationKeepsAShieldButNeverStartsOne() {
        let session = UUID()
        let running = FocusShieldFocusState.running(sessionID: session, plannedEnd: now.addingTimeInterval(1_500))
        XCTAssertEqual(decide(authorization: .unknown, focus: running, record: nil), .idle)
        XCTAssertEqual(decide(authorization: .unknown, focus: running,
                              record: active(session, deadline: now.addingTimeInterval(1_560))), .keep)
        XCTAssertEqual(decide(authorization: .unknown, focus: running,
                              record: active(UUID(), deadline: now.addingTimeInterval(1_560))), .clear(.focusEnded))
    }

    func testALiftedSessionStaysLifted() {
        let session = UUID()
        var record = active(session, deadline: now.addingTimeInterval(1_560))
        record.active = false
        record.liftedAt = now
        XCTAssertEqual(decide(focus: .running(sessionID: session, plannedEnd: now.addingTimeInterval(1_800)),
                              record: record), .idle)
        let next = UUID()
        XCTAssertEqual(decide(focus: .running(sessionID: next, plannedEnd: now.addingTimeInterval(1_800)),
                              record: record), .apply(sessionID: next, deadline: now.addingTimeInterval(1_860)))
    }

    func testAuthorizationMapping() {
        XCTAssertEqual(FocusShieldAuthorization(.approved), .approved)
        XCTAssertEqual(FocusShieldAuthorization(.denied), .denied)
        XCTAssertEqual(FocusShieldAuthorization(.notDetermined), .unknown)
        if #available(iOS 26.4, *) {
            XCTAssertEqual(FocusShieldAuthorization(.approvedWithDataAccess), .approved,
                           "Otherwise nobody with that status could ever start a shield")
        }
    }

    // MARK: - settings model

    func testTheOptInIsOffByDefaultDecodesFromOldLedgersAndNeverStoresFalse() throws {
        XCTAssertFalse(ScreenTimeConfiguration().shieldsDistractionDuringFocusEnabled)
        var state = ScreenTimeState()
        state.configuration.enabled = true
        let old = try JSONEncoder().encode(state)
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("shieldsDistractionDuringFocus"),
                       "Off must be written exactly as a build without the field wrote it")
        let decoded = try JSONDecoder().decode(ScreenTimeState.self, from: old)
        XCTAssertFalse(decoded.configuration.shieldsDistractionDuringFocusEnabled)

        var configuration = ScreenTimeConfiguration()
        configuration.shieldsDistractionDuringFocusEnabled = true
        XCTAssertEqual(configuration.shieldsDistractionDuringFocus, true)
        configuration.shieldsDistractionDuringFocusEnabled = false
        XCTAssertNil(configuration.shieldsDistractionDuringFocus)
        XCTAssertEqual(configuration, ScreenTimeConfiguration(),
                       "Toggled on and off again, the draft equals the saved configuration")

        state.configuration.shieldsDistractionDuringFocusEnabled = true
        let roundTrip = try JSONDecoder().decode(ScreenTimeState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(roundTrip.configuration.shieldsDistractionDuringFocusEnabled)
    }

    func testAShieldOnlyConfigurationValidatesTheDistractionAppsAlone() throws {
        var configuration = ScreenTimeConfiguration()
        configuration.shieldsDistractionDuringFocusEnabled = true
        configuration.distractionSelection = try selection(count: 60, seed: 0x61)
        XCTAssertNoThrow(try ScreenTimePolicy.validate(configuration, isPro: false),
                         "More than 50 apps is a warning on the page, never a refused save")
        configuration.learningSelection = try selection(count: 9, seed: 0x62)
        XCTAssertNoThrow(try ScreenTimePolicy.validate(configuration, isPro: false),
                         "With recording off the free study-app limit does not apply")
        configuration.learningSelection.applicationTokens.formUnion(
            configuration.distractionSelection.applicationTokens.prefix(1))
        XCTAssertThrowsError(try ScreenTimePolicy.validate(configuration, isPro: false))
    }

    func testAvailabilityExplainsASwitchedOnShieldThatCannotWork() throws {
        var configuration = ScreenTimeConfiguration()
        XCTAssertEqual(FocusShieldAvailability(configuration: configuration, authorizationGranted: true), .off)
        configuration.shieldsDistractionDuringFocusEnabled = true
        XCTAssertEqual(FocusShieldAvailability(configuration: configuration, authorizationGranted: false),
                       .needsAuthorization)
        XCTAssertEqual(FocusShieldAvailability(configuration: configuration, authorizationGranted: true),
                       .noApplications)
        configuration.distractionSelection = try selection(count: 51, seed: 0x63)
        let tooMany = FocusShieldAvailability(configuration: configuration, authorizationGranted: true)
        XCTAssertEqual(tooMany, .tooManyApplications(count: 51))
        XCTAssertEqual(tooMany.message, "控えたいアプリが51個あります。集中中に開けないようにできるのは50個までなので、いまは制限していません。")
        configuration.distractionSelection = try selection(count: 50, seed: 0x63)
        XCTAssertEqual(FocusShieldAvailability(configuration: configuration, authorizationGranted: true), .ready)
        XCTAssertNil(FocusShieldAvailability.ready.message)
        XCTAssertNotNil(FocusShieldAvailability.needsAuthorization.message)
        XCTAssertNotNil(FocusShieldAvailability.noApplications.message)
        XCTAssertEqual(FocusShieldCopy.toggleTitle, "集中中は気が散るアプリを開けないようにする")
        XCTAssertEqual(FocusShieldCopy.liftButton, "今すぐ制限を解除")
        XCTAssertEqual(FocusShieldCopy.focusNotice, "気が散るアプリを制限中")
    }

    /// Planner decision 2026-09-26: the settings footer warns that picking
    /// the Music apps blocks focus music too, and that blocked time earns no
    /// black stones.
    func testTheSettingsFooterWarnsAboutMusicAppsAndBlackStones() {
        XCTAssertTrue(FocusShieldCopy.musicNote.contains("「ミュージック」"), FocusShieldCopy.musicNote)
        XCTAssertTrue(FocusShieldCopy.musicNote.contains("Apple Music Classical"), FocusShieldCopy.musicNote)
        XCTAssertTrue(FocusShieldCopy.musicNote.contains("音楽も再生できなくなります"), FocusShieldCopy.musicNote)
        XCTAssertTrue(FocusShieldCopy.blackStoneNote.contains("黒い石になりません"), FocusShieldCopy.blackStoneNote)
        // The failsafe starts at the planned end and lifts the shield there,
        // so the footer promises the planned end and nothing past it.
        XCTAssertTrue(FocusShieldCopy.toggleFooter.contains("一時停止中も、予定の終了時刻まで続きます"),
                      FocusShieldCopy.toggleFooter)
        XCTAssertFalse(FocusShieldCopy.toggleFooter.contains("1分後"), FocusShieldCopy.toggleFooter)
        XCTAssertEqual(FocusShieldCopy.sectionHeader, "集中中のアプリ制限")
        XCTAssertEqual(FocusShieldCopy.liftedToast, "制限を解除しました")
    }

    // MARK: - controller

    func testTheControllerAppliesKeepsAndClearsAcrossAFocusWithoutRepeatingWork() async throws {
        let fixture = makeController()
        let configuration = try shieldConfiguration()
        let session = UUID()
        let end = now.addingTimeInterval(1_500)

        fixture.controller.reconcile(configuration: configuration, authorization: .approved,
                                     focus: .running(sessionID: session, plannedEnd: end), now: now)
        await fixture.controller.waitForPendingOperations()
        XCTAssertTrue(fixture.controller.isShielding)
        XCTAssertEqual(fixture.settings.shielded.count, 1)
        XCTAssertEqual(fixture.center.started.count, 1)

        // A background save of the same running focus, then the 3 s pass.
        for offset in [1.0, 4, 7] {
            fixture.controller.reconcile(configuration: configuration, authorization: .approved,
                                         focus: .running(sessionID: session, plannedEnd: end),
                                         now: now.addingTimeInterval(offset))
        }
        await fixture.controller.waitForPendingOperations()
        XCTAssertEqual(fixture.settings.shielded.count, 1, "An unchanged decision does no work")

        // Auto-pause on leaving: kept, with no DeviceActivity call.
        fixture.clock.now = now.addingTimeInterval(600)
        fixture.controller.reconcile(configuration: configuration, authorization: .approved,
                                     focus: .paused(sessionID: session), now: now.addingTimeInterval(600))
        await fixture.controller.waitForPendingOperations()
        XCTAssertTrue(fixture.controller.isShielding)
        XCTAssertEqual(fixture.center.started.count, 1)
        XCTAssertTrue(fixture.center.stopped.isEmpty)

        // Resumed: the deadline moves with the new planned end.
        let resumedEnd = end.addingTimeInterval(900)
        fixture.clock.now = now.addingTimeInterval(1_500)
        fixture.controller.reconcile(configuration: configuration, authorization: .approved,
                                     focus: .running(sessionID: session, plannedEnd: resumedEnd),
                                     now: now.addingTimeInterval(1_500))
        await fixture.controller.waitForPendingOperations()
        XCTAssertEqual(fixture.center.started.count, 2)
        XCTAssertEqual(try fixture.engine.records.load()?.deadline, resumedEnd.addingTimeInterval(60))

        // Completed: lifted, the failsafe stopped by name.
        fixture.clock.now = resumedEnd
        fixture.controller.reconcile(configuration: configuration, authorization: .approved,
                                     focus: .none, now: resumedEnd)
        await fixture.controller.waitForPendingOperations()
        XCTAssertFalse(fixture.controller.isShielding)
        XCTAssertEqual(fixture.settings.clearCount, 1)
        XCTAssertEqual(fixture.center.stopped, [[FocusShieldPolicy.activityName.rawValue]])
    }

    func testTheEscapeHatchLiftsTheShieldForThisFocusOnly() async throws {
        let fixture = makeController()
        let configuration = try shieldConfiguration()
        let session = UUID()
        let running = FocusShieldFocusState.running(sessionID: session, plannedEnd: now.addingTimeInterval(1_500))
        fixture.controller.reconcile(configuration: configuration, authorization: .approved, focus: running, now: now)
        await fixture.controller.waitForPendingOperations()
        XCTAssertTrue(fixture.controller.isShielding)

        let lifted = await fixture.controller.liftForCurrentFocus(now: now.addingTimeInterval(60))
        XCTAssertEqual(lifted, .lifted)
        XCTAssertFalse(fixture.controller.isShielding)
        fixture.controller.reconcile(configuration: configuration, authorization: .approved, focus: running,
                                     now: now.addingTimeInterval(63), force: true)
        await fixture.controller.waitForPendingOperations()
        XCTAssertFalse(fixture.controller.isShielding, "The forced activation pass must not re-apply it")
        XCTAssertEqual(fixture.settings.shielded.count, 1)
    }

    /// The page confirms 制限を解除しました only for a lift that ran. With the
    /// record lock held (the monitor extension mid-callback) the shield stays
    /// up, the button comes back, and a retry then lifts it.
    func testTheEscapeHatchReportsWhetherTheLiftRan() async throws {
        let fixture = makeController()
        let configuration = try shieldConfiguration()
        let nothing = await fixture.controller.liftForCurrentFocus(now: now)
        XCTAssertEqual(nothing, .nothingToLift)

        let running = FocusShieldFocusState.running(sessionID: UUID(), plannedEnd: now.addingTimeInterval(1_500))
        fixture.controller.reconcile(configuration: configuration, authorization: .approved, focus: running, now: now)
        await fixture.controller.waitForPendingOperations()
        XCTAssertTrue(fixture.controller.isShielding)

        let descriptor = try holdLock(in: fixture.directory)
        let failed = await fixture.controller.liftForCurrentFocus(now: now.addingTimeInterval(60))
        flock(descriptor, LOCK_UN)
        close(descriptor)
        XCTAssertEqual(failed, .failed)
        XCTAssertTrue(fixture.controller.isShielding, "Still up, so the button comes back for a retry")
        XCTAssertEqual(fixture.settings.clearCount, 0)
        XCTAssertEqual(try fixture.engine.records.load()?.active, true)

        let retried = await fixture.controller.liftForCurrentFocus(now: now.addingTimeInterval(61))
        XCTAssertEqual(retried, .lifted)
        XCTAssertFalse(fixture.controller.isShielding)
        XCTAssertNotNil(try fixture.engine.records.load()?.liftedAt)
    }

    func testAFailsafeThatCannotBeArmedIsReportedAndNotRetriedEveryPass() async throws {
        let fixture = makeController(resolve: { _ in nil })
        let configuration = try shieldConfiguration()
        let running = FocusShieldFocusState.running(sessionID: UUID(), plannedEnd: now.addingTimeInterval(1_500))
        fixture.controller.reconcile(configuration: configuration, authorization: .approved, focus: running, now: now)
        await fixture.controller.waitForPendingOperations()
        XCTAssertTrue(fixture.controller.failsafeUnavailable)
        XCTAssertFalse(fixture.controller.isShielding)
        XCTAssertTrue(fixture.settings.shielded.isEmpty)
        let recordAfterFirst = try fixture.engine.records.load()
        fixture.controller.reconcile(configuration: configuration, authorization: .approved, focus: running,
                                     now: now.addingTimeInterval(3))
        await fixture.controller.waitForPendingOperations()
        XCTAssertEqual(try fixture.engine.records.load(), recordAfterFirst)
    }

    /// The fixed test dates lie in 2027. A finished operation publishes
    /// `isShielding` by the controller's clock, so these tests keep passing
    /// after those dates, and the clock — not the wall clock — decides.
    func testAFinishedOperationPublishesByTheControllersClock() async throws {
        let fixture = makeController()
        let configuration = try shieldConfiguration()
        let running = FocusShieldFocusState.running(sessionID: UUID(), plannedEnd: now.addingTimeInterval(1_500))
        fixture.controller.reconcile(configuration: configuration, authorization: .approved, focus: running, now: now)
        await fixture.controller.waitForPendingOperations()
        XCTAssertTrue(fixture.controller.isShielding)

        fixture.clock.now = now.addingTimeInterval(1_560) // the record's deadline
        fixture.controller.reconcile(configuration: configuration, authorization: .approved, focus: running,
                                     now: now, force: true)
        await fixture.controller.waitForPendingOperations()
        XCTAssertFalse(fixture.controller.isShielding,
                       "Published by the injected clock; today's wall clock would still say true")
    }

    // MARK: - operations still queued

    func testAFocusThatEndsWhileItsApplyIsQueuedIsNotLeftShielded() async throws {
        let fixture = makeController()
        let configuration = try shieldConfiguration()
        let session = UUID()
        fixture.controller.reconcile(configuration: configuration, authorization: .approved,
                                     focus: .running(sessionID: session, plannedEnd: now.addingTimeInterval(1_500)),
                                     now: now)
        // No await: the apply has not run, so the record on disk says nothing.
        fixture.controller.reconcile(configuration: configuration, authorization: .approved, focus: .none,
                                     now: now.addingTimeInterval(1))
        await fixture.controller.waitForPendingOperations()
        XCTAssertFalse(fixture.controller.isShielding)
        let record = try XCTUnwrap(try fixture.engine.records.load())
        XCTAssertFalse(record.active)
        XCTAssertEqual(record.clearedBy, FocusShieldClearReason.focusEnded.rawValue)
        XCTAssertEqual(fixture.center.stopped, [[FocusShieldPolicy.activityName.rawValue]])
    }

    func testAPauseOfANewFocusWhoseApplyIsQueuedKeepsItsShield() async throws {
        let fixture = makeController()
        let configuration = try shieldConfiguration()
        let first = UUID()
        fixture.controller.reconcile(configuration: configuration, authorization: .approved,
                                     focus: .running(sessionID: first, plannedEnd: now.addingTimeInterval(1_500)),
                                     now: now)
        await fixture.controller.waitForPendingOperations()
        // `first` was abandoned; `next` starts while `first`'s record is up.
        let next = UUID()
        fixture.controller.reconcile(configuration: configuration, authorization: .approved,
                                     focus: .running(sessionID: next, plannedEnd: now.addingTimeInterval(2_400)),
                                     now: now.addingTimeInterval(600))
        // Read from disk, the pause of `next` meets `first`'s record and would
        // clear; decided again on the queue, it meets `next`'s and keeps it.
        fixture.controller.reconcile(configuration: configuration, authorization: .approved,
                                     focus: .paused(sessionID: next), now: now.addingTimeInterval(601))
        await fixture.controller.waitForPendingOperations()
        let record = try XCTUnwrap(try fixture.engine.records.load())
        XCTAssertTrue(record.active)
        XCTAssertEqual(record.sessionID, next)
        XCTAssertTrue(fixture.controller.isShielding)
    }

    func testARetirementRightAfterAReconcileStillLiftsTheQueuedShield() async throws {
        let fixture = makeController()
        let (controller, _) = try await boundScreenTimeController(shield: fixture.controller)
        controller.reconcileFocusShield(
            contextKey: "owner", dataEpochID: nil,
            focus: .running(sessionID: UUID(), plannedEnd: now.addingTimeInterval(1_500)), now: now)
        // No await in between.
        controller.suspendForContextRetirement()
        await fixture.controller.waitForPendingOperations()
        XCTAssertFalse(fixture.controller.isShielding)
        let record = try XCTUnwrap(try fixture.engine.records.load())
        XCTAssertFalse(record.active)
        XCTAssertEqual(record.clearedBy, FocusShieldClearReason.ownerRetired.rawValue)
    }

    // MARK: - the failsafe notice

    func testTheFailsafeNoticeBelongsOnlyToTheFocusItFailedFor() async throws {
        let fixture = makeController(resolve: { _ in nil })
        let configuration = try shieldConfiguration()
        let session = UUID()
        let running = FocusShieldFocusState.running(sessionID: session, plannedEnd: now.addingTimeInterval(1_500))
        func reconcile(_ focus: FocusShieldFocusState, _ configuration: ScreenTimeConfiguration, at offset: TimeInterval,
                       force: Bool = false) async {
            fixture.controller.reconcile(configuration: configuration, authorization: .approved, focus: focus,
                                         now: now.addingTimeInterval(offset), force: force)
            await fixture.controller.waitForPendingOperations()
        }

        await reconcile(running, configuration, at: 0)
        XCTAssertTrue(fixture.controller.failsafeUnavailable)
        await reconcile(.paused(sessionID: session), configuration, at: 60)
        XCTAssertTrue(fixture.controller.failsafeUnavailable, "Still the focus it failed for")
        await reconcile(.none, configuration, at: 120)
        XCTAssertFalse(fixture.controller.failsafeUnavailable, "Not on the break or at Home afterwards")

        await reconcile(running, configuration, at: 130, force: true)
        XCTAssertTrue(fixture.controller.failsafeUnavailable)
        var off = configuration
        off.shieldsDistractionDuringFocusEnabled = false
        await reconcile(running, off, at: 140)
        XCTAssertFalse(fixture.controller.failsafeUnavailable, "Switched off: nothing is meant to be shielded")

        await reconcile(running, configuration, at: 150, force: true)
        XCTAssertTrue(fixture.controller.failsafeUnavailable)
        fixture.controller.retire(reason: .ownerRetired)
        await fixture.controller.waitForPendingOperations()
        XCTAssertFalse(fixture.controller.failsafeUnavailable)

        // A failure that arrives after its focus already ended says nothing.
        fixture.controller.reconcile(configuration: configuration, authorization: .approved, focus: running,
                                     now: now.addingTimeInterval(160), force: true)
        fixture.controller.reconcile(configuration: configuration, authorization: .approved, focus: .none,
                                     now: now.addingTimeInterval(161))
        await fixture.controller.waitForPendingOperations()
        XCTAssertFalse(fixture.controller.failsafeUnavailable)
    }

    /// The settings page cannot be open during a focus (the focus screen is
    /// a full-screen cover), so `failsafeUnavailable` never reaches it. The
    /// record keeps why the latest focus ran unshielded, and the controller
    /// publishes that after the focus too, until a focus is shielded again
    /// or everything is erased.
    func testTheLastFocusThatRanUnshieldedIsStillKnownAfterItEnds() async throws {
        let resolvable = ShieldTestFlag()
        let testNow = now
        let fixture = makeController(resolve: { schedule in
            resolvable.value ? FocusShieldEngineTests.resolve(schedule, now: testNow, calendar: .current) : nil
        })
        let configuration = try shieldConfiguration()
        func reconcile(_ focus: FocusShieldFocusState, at offset: TimeInterval) async {
            fixture.controller.reconcile(configuration: configuration, authorization: .approved, focus: focus,
                                         now: now.addingTimeInterval(offset), force: true)
            await fixture.controller.waitForPendingOperations()
        }
        XCTAssertFalse(fixture.controller.lastFocusWentUnshielded)

        await reconcile(.running(sessionID: UUID(), plannedEnd: now.addingTimeInterval(1_500)), at: 0)
        XCTAssertTrue(fixture.controller.failsafeUnavailable)
        XCTAssertTrue(fixture.controller.lastFocusWentUnshielded)
        await reconcile(.none, at: 60)
        XCTAssertFalse(fixture.controller.failsafeUnavailable, "The present-tense notice ends with its focus")
        XCTAssertTrue(fixture.controller.lastFocusWentUnshielded, "The record still says why it ran unshielded")

        // A later focus that is shielded replaces it, and so does its end.
        resolvable.value = true
        await reconcile(.running(sessionID: UUID(), plannedEnd: now.addingTimeInterval(3_000)), at: 120)
        XCTAssertTrue(fixture.controller.isShielding)
        XCTAssertFalse(fixture.controller.lastFocusWentUnshielded)
        await reconcile(.none, at: 180)
        XCTAssertFalse(fixture.controller.lastFocusWentUnshielded)

        // Complete deletion forgets it with the record.
        resolvable.value = false
        await reconcile(.running(sessionID: UUID(), plannedEnd: now.addingTimeInterval(4_500)), at: 240)
        XCTAssertTrue(fixture.controller.lastFocusWentUnshielded)
        try await fixture.controller.eraseAllData()
        XCTAssertFalse(fixture.controller.lastFocusWentUnshielded)
    }

    // MARK: - ScreenTimeController paths that must lift a shield

    /// Switching the shield off is the way out that always works, even when
    /// the rest of the setup would fail a save today: recording on with six
    /// study apps on the free plan after a refund, and access not settled.
    /// `save` refuses that configuration; `switchFocusShieldOff` changes the
    /// one field and lifts the shield.
    func testSwitchingOnlyTheShieldOffSkipsEveryRecordingCheck() async throws {
        let fixture = makeController()
        var status = AuthorizationStatus.approved
        let (controller, store) = try await boundScreenTimeController(shield: fixture.controller,
                                                                      authorization: { status })
        let learning = try selection(count: 6, seed: 0x76)
        try store.update { state in
            state.configuration.enabled = true
            state.configuration.learningSelection = learning
            state.learningAllowedBySubscription = false
        }
        controller.reload()
        controller.reconcileFocusShield(
            contextKey: "owner", dataEpochID: nil,
            focus: .running(sessionID: UUID(), plannedEnd: now.addingTimeInterval(1_500)), now: now)
        await fixture.controller.waitForPendingOperations()
        XCTAssertTrue(fixture.controller.isShielding)

        status = .notDetermined
        let saved = controller.configuration
        var off = saved
        off.shieldsDistractionDuringFocusEnabled = false
        XCTAssertTrue(ScreenTimeDraftPolicy.onlySwitchesFocusShieldOff(draft: off, saved: saved))
        do {
            try await controller.save(configuration: off, isPro: false)
            XCTFail("An ordinary save still holds recording to today's rules")
        } catch {}
        XCTAssertTrue(controller.configuration.shieldsDistractionDuringFocusEnabled)

        let before = try store.snapshot()
        try controller.switchFocusShieldOff()
        try await controller.waitForPendingOperations()
        let after = try store.snapshot()
        XCTAssertEqual(after.configuration, off, "Only the shield's switch changes")
        XCTAssertEqual(after.runs, before.runs, "No lane run is retired or registered")
        XCTAssertEqual(after.learningAllowedBySubscription, before.learningAllowedBySubscription)
        XCTAssertFalse(controller.configuration.shieldsDistractionDuringFocusEnabled)
        XCTAssertFalse(fixture.controller.isShielding)
        XCTAssertEqual(try fixture.engine.records.load()?.clearedBy, FocusShieldClearReason.featureOff.rawValue)
        XCTAssertEqual(fixture.center.stopped.last, [FocusShieldPolicy.activityName.rawValue])
    }

    func testTheShieldFollowsTheBoundOwnerOnlyAndLeavesWithIt() async throws {
        let fixture = makeController()
        let (controller, _) = try await boundScreenTimeController(shield: fixture.controller)
        let session = UUID()
        let running = FocusShieldFocusState.running(sessionID: session, plannedEnd: now.addingTimeInterval(1_500))

        controller.reconcileFocusShield(contextKey: "another-owner", dataEpochID: nil, focus: running, now: now)
        await fixture.controller.waitForPendingOperations()
        XCTAssertTrue(fixture.settings.shielded.isEmpty, "An unbound owner decides nothing")

        controller.reconcileFocusShield(contextKey: "owner", dataEpochID: nil, focus: running, now: now)
        await fixture.controller.waitForPendingOperations()
        XCTAssertTrue(fixture.controller.isShielding)

        // Account change / storage relaunch.
        controller.suspendForContextRetirement()
        await fixture.controller.waitForPendingOperations()
        XCTAssertFalse(fixture.controller.isShielding)
        XCTAssertEqual(try fixture.engine.records.load()?.clearedBy, FocusShieldClearReason.ownerRetired.rawValue)
    }

    func testARevokedAuthorizationLiftsTheShieldWithTheVoidedTokens() async throws {
        let fixture = makeController()
        var status = AuthorizationStatus.approved
        let (controller, _) = try await boundScreenTimeController(shield: fixture.controller,
                                                                  authorization: { status })
        controller.reconcileFocusShield(
            contextKey: "owner", dataEpochID: nil,
            focus: .running(sessionID: UUID(), plannedEnd: now.addingTimeInterval(1_500)), now: now)
        await fixture.controller.waitForPendingOperations()
        XCTAssertTrue(fixture.controller.isShielding)

        status = .denied
        await controller.invalidateAuthorizationIfRevoked(now: now.addingTimeInterval(10))
        await fixture.controller.waitForPendingOperations()
        XCTAssertFalse(fixture.controller.isShielding)
        XCTAssertEqual(try fixture.engine.records.load()?.clearedBy,
                       FocusShieldClearReason.authorizationRevoked.rawValue)
    }

    func testSwitchingTheShieldOnNeedsScreenTimeAccessButSwitchingOffNeverDoes() async throws {
        let fixture = makeController()
        var status = AuthorizationStatus.approved
        let (controller, _) = try await boundScreenTimeController(shield: fixture.controller,
                                                                  authorization: { status })
        var configuration = controller.configuration
        configuration.shieldsDistractionDuringFocusEnabled = true
        status = .notDetermined
        do {
            try await controller.save(configuration: configuration, isPro: false)
            XCTFail("An unapproved shield must not be saved")
        } catch ScreenTimeError.unauthorized {}
        status = .approved
        try await controller.save(configuration: configuration, isPro: false)
        XCTAssertTrue(controller.configuration.shieldsDistractionDuringFocusEnabled)

        status = .notDetermined
        configuration.shieldsDistractionDuringFocusEnabled = false
        configuration.enabled = false
        try await controller.save(configuration: configuration, isPro: false)
        XCTAssertFalse(controller.configuration.shieldsDistractionDuringFocusEnabled)
    }

    func testSwitchingTheShieldOffAlwaysEmptiesTheNamedStoreAndStopsTheFailsafe() async throws {
        let fixture = makeController()
        let (controller, _) = try await boundScreenTimeController(shield: fixture.controller)
        // What an interrupted run can leave behind: a failsafe and a store
        // with no record saying a shield is up.
        fixture.center.installed = [FocusShieldPolicy.activityName.rawValue]
        XCTAssertFalse(fixture.engine.records.exists)

        var configuration = controller.configuration
        configuration.distractionSelection = try selection(count: 4, seed: 0x73)
        try await controller.save(configuration: configuration, isPro: false)
        try await controller.waitForPendingOperations()
        XCTAssertEqual(fixture.settings.clearCount, 0, "A save that keeps the shield on clears nothing")

        configuration.shieldsDistractionDuringFocusEnabled = false
        try await controller.save(configuration: configuration, isPro: false)
        try await controller.waitForPendingOperations()
        XCTAssertEqual(fixture.settings.clearCount, 1, "Switching it off is the way out that always works")
        XCTAssertEqual(fixture.center.stopped, [[FocusShieldPolicy.activityName.rawValue]])
        XCTAssertFalse(fixture.engine.records.exists, "Nothing is recorded for a shield that was not up")

        try await controller.save(configuration: configuration, isPro: false)
        try await controller.waitForPendingOperations()
        XCTAssertEqual(fixture.settings.clearCount, 1, "Saving it off again does not touch the store")
    }

    func testARevocationAlsoWipesAShieldOnlyOptInWithoutApps() async throws {
        var state = ScreenTimeState()
        state.configuration.shieldsDistractionDuringFocusEnabled = true
        XCTAssertTrue(state.recordsAnApproval, "Saving the opt-in needs an approval, so it proves one")
        XCTAssertTrue(state.invalidateAuthorization())
        XCTAssertFalse(state.configuration.shieldsDistractionDuringFocusEnabled)
        var empty = ScreenTimeState()
        XCTAssertFalse(empty.recordsAnApproval)
        XCTAssertFalse(empty.invalidateAuthorization(), "An empty setup has nothing to invalidate")

        // Through the real detector: a revocation reads `.notDetermined`, and
        // only a ledger that records an approval gets past the settling window.
        let fixture = makeController()
        var status = AuthorizationStatus.approved
        let (controller, store) = try await boundScreenTimeController(
            shield: fixture.controller, authorization: { status }, distractionApps: 0)
        XCTAssertTrue(controller.configuration.shieldsDistractionDuringFocusEnabled)
        status = .notDetermined
        controller.beginAuthorizationObservation()
        for second in stride(from: 0.0, through: 16, by: 4) {
            await controller.invalidateAuthorizationIfRevoked(now: now.addingTimeInterval(second))
        }
        XCTAssertFalse(try store.snapshot().configuration.shieldsDistractionDuringFocusEnabled,
                       "The opt-in goes with the revoked approval")
        XCTAssertFalse(controller.configuration.shieldsDistractionDuringFocusEnabled)
    }

    func testAnAccountChangeLiftsTheShieldEvenWithNoBoundOwner() async throws {
        let fixture = makeController()
        let controller = ScreenTimeController(
            store: ScreenTimeStore(directory: makeDirectory()), currentContextKey: { "owner" },
            monitoring: NoopMonitoring(), authorization: { .approved },
            diagnosticsMirror: ScreenTimeDiagnosticsMirror(directory: makeDirectory()),
            noticeDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            focusShield: fixture.controller)
        // A shield from before the change; this process never bound an owner
        // (a cold launch whose persistence was never admitted).
        _ = try fixture.engine.apply(sessionID: UUID(), deadline: now.addingTimeInterval(1_560),
                                     applications: try selection(count: 2, seed: 0x74).applicationTokens, now: now)
        XCTAssertFalse(controller.isBound(contextKey: "owner", dataEpochID: nil))

        ScreenTimeOwnerBoundaryPolicy.retire(for: .backgroundedSession, on: controller)
        await fixture.controller.waitForPendingOperations()
        XCTAssertEqual(try fixture.engine.records.load()?.active, true, "An ordinary backgrounding keeps it")

        ScreenTimeOwnerBoundaryPolicy.retire(for: .accountIdentityChange, on: controller)
        await fixture.controller.waitForPendingOperations()
        let record = try XCTUnwrap(try fixture.engine.records.load())
        XCTAssertFalse(record.active)
        XCTAssertEqual(record.clearedBy, FocusShieldClearReason.ownerRetired.rawValue)
    }

    func testCompleteDeletionErasesTheShieldRecordAndStore() async throws {
        let fixture = makeController()
        let (controller, _) = try await boundScreenTimeController(shield: fixture.controller)
        controller.reconcileFocusShield(
            contextKey: "owner", dataEpochID: nil,
            focus: .running(sessionID: UUID(), plannedEnd: now.addingTimeInterval(1_500)), now: now)
        await fixture.controller.waitForPendingOperations()
        XCTAssertTrue(fixture.engine.records.exists)

        try await controller.eraseAllData()
        XCTAssertFalse(fixture.engine.records.exists)
        XCTAssertGreaterThanOrEqual(fixture.settings.clearCount, 1)
        XCTAssertFalse(fixture.center.installed.contains(FocusShieldPolicy.activityName.rawValue))
        XCTAssertFalse(fixture.controller.isShielding)
    }

    func testTheDefaultShieldRecordLivesNextToTheControllersOwnLedgerAndTouchesNoRealState() async throws {
        let store = ScreenTimeStore(directory: makeDirectory())
        let distraction = try selection(count: 2, seed: 0x75)
        try store.update { state in
            state.contextKey = "owner"
            state.contextIsActive = true
            state.configuration.distractionSelection = distraction
            state.configuration.shieldsDistractionDuringFocusEnabled = true
        }
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: NoopMonitoring(), authorization: { .approved },
                                              diagnosticsMirror: ScreenTimeDiagnosticsMirror(directory: makeDirectory()),
                                              noticeDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        // A temporary ledger never drives the process-wide store or center.
        XCTAssertTrue(controller.focusShield.engine.settings is DetachedFocusShieldSettings)
        XCTAssertTrue(controller.focusShield.engine.center is DetachedFocusShieldCenter)

        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        controller.reconcileFocusShield(
            contextKey: "owner", dataEpochID: nil,
            focus: .running(sessionID: UUID(), plannedEnd: Date().addingTimeInterval(1_500)))
        try await controller.waitForPendingOperations()
        let record = try XCTUnwrap(try FocusShieldRecordStore(directory: store.directoryURL).load(),
                                   "The default controller writes its record next to its own ledger")
        XCTAssertFalse(record.active, "The detached center registers nothing, so nothing is shielded")
        XCTAssertEqual(record.clearedBy, FocusShieldClearReason.failsafeUnavailable.rawValue)
        XCTAssertTrue(controller.focusShield.failsafeUnavailable)

        try await controller.eraseAllData()
        XCTAssertFalse(FocusShieldRecordStore(directory: store.directoryURL).exists)

        // The App Group's ledger, and only it, gets the real drivers, and the
        // extension and the launch sweep look in that same folder.
        XCTAssertEqual(FocusShieldRecordStore.appGroupDirectory(), ScreenTimeStore().directoryURL)
        let live = FocusShieldEngine.forLedger(directory: ScreenTimeStore().directoryURL)
        XCTAssertTrue(live.settings is ManagedSettingsFocusShield)
        XCTAssertTrue(live.center is DeviceActivityCenter)
    }

    // MARK: - helpers

    private func decide(
        enabled: Bool = true,
        apps: Int = 3,
        authorization: FocusShieldAuthorization = .approved,
        focus: FocusShieldFocusState,
        record: FocusShieldRecord? = nil,
        at date: Date? = nil
    ) -> FocusShieldDecision {
        FocusShieldReconcilePolicy.decide(enabled: enabled, applicationCount: apps, authorization: authorization,
                                          focus: focus, record: record, now: date ?? now)
    }

    private func active(_ session: UUID, deadline: Date) -> FocusShieldRecord {
        FocusShieldRecord(active: true, sessionID: session, deadline: deadline, appliedAt: now)
    }

    private func state(_ engine: PomodoroEngine, epoch: UUID, currentEpoch: UUID? = nil) -> FocusShieldFocusState {
        FocusShieldFocusState(
            envelope: FocusRecoveryEnvelope(engine: engine, subject: nil, clockAnchor: nil,
                                            pendingCompletion: nil, savedAt: now, dataEpochID: epoch),
            dataEpochID: currentEpoch ?? epoch)
    }

    private func selection(count: Int, seed: UInt8) throws -> FamilyActivitySelection {
        var selection = FamilyActivitySelection(includeEntireCategory: false)
        selection.applicationTokens = Set(try (0..<count).map { index in
            try JSONDecoder().decode(ApplicationToken.self,
                                     from: JSONEncoder().encode(["data": Data([seed, UInt8(index)])]))
        })
        return selection
    }

    private func shieldConfiguration() throws -> ScreenTimeConfiguration {
        var configuration = ScreenTimeConfiguration()
        configuration.shieldsDistractionDuringFocusEnabled = true
        configuration.distractionSelection = try selection(count: 3, seed: 0x71)
        return configuration
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        return directory
    }

    private struct Fixture {
        let controller: FocusShieldController
        let engine: FocusShieldEngine
        let settings: ShieldFakeSettings
        let center: ShieldFakeCenter
        let clock: ShieldTestClock
        /// The ScreenTime folder the record and its lock live in.
        let directory: URL
    }

    /// Without an explicit resolver the framework is trusted to resolve each
    /// schedule to the interval it was built for (the schedule math and the
    /// real `nextInterval` have their own tests in FocusShieldEngineTests).
    private func makeController(resolve: ((DeviceActivitySchedule) -> DateInterval?)? = nil) -> Fixture {
        let directory = makeDirectory().appendingPathComponent("ScreenTime", isDirectory: true)
        let records = FocusShieldRecordStore(directory: directory)
        let center = ShieldFakeCenter()
        let settings = ShieldFakeSettings(center: center, records: records)
        let testNow = now
        let engine = FocusShieldEngine(
            records: records, settings: settings, center: center,
            resolveInterval: resolve ?? { schedule in
                FocusShieldEngineTests.resolve(schedule, now: testNow, calendar: .current)
            },
            lockTimeout: 1)
        let clock = ShieldTestClock(now)
        let controller = FocusShieldController(engine: engine, queue: DispatchQueue(label: "test.shield"),
                                               clock: { clock.now })
        return Fixture(controller: controller, engine: engine, settings: settings, center: center, clock: clock,
                       directory: directory)
    }

    /// What the monitor extension does while it handles a callback.
    private func holdLock(in directory: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent("focus-shield.lock").path, O_CREAT | O_RDWR,
                              S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        return descriptor
    }

    private func boundScreenTimeController(
        shield: FocusShieldController,
        authorization: @escaping () -> AuthorizationStatus = { .approved },
        distractionApps: Int = 3
    ) async throws -> (ScreenTimeController, ScreenTimeStore) {
        let store = ScreenTimeStore(directory: makeDirectory())
        let distraction = try selection(count: distractionApps, seed: 0x72)
        try store.update { state in
            state.contextKey = "owner"
            state.contextIsActive = true
            state.configuration.distractionSelection = distraction
            state.configuration.shieldsDistractionDuringFocusEnabled = true
        }
        let controller = ScreenTimeController(
            store: store, currentContextKey: { "owner" }, monitoring: NoopMonitoring(),
            authorization: authorization,
            diagnosticsMirror: ScreenTimeDiagnosticsMirror(directory: makeDirectory()),
            noticeDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            focusShield: shield)
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        return (controller, store)
    }
}

/// The controller's "now" in tests, so what is published never depends on
/// the real date.
final class ShieldTestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// A switch a test flips between operations the shield queue runs later.
final class ShieldTestFlag: @unchecked Sendable {
    var value = false
}

private final class NoopMonitoring: ScreenTimeMonitoringDriving {
    func stop() {}
    func invalidateAuthorizationIfNeeded() throws {}
    func synchronize(now: Date) throws -> Bool { false }
}

/// The wiring: the saved timer reaches the shield through the Screen Time
/// host (`ScreenTimeIntegrationModifier`), the same choke point as the
/// learning lane's hold, with the framework replaced by fakes.
@MainActor
final class FocusShieldIntegrationTests: XCTestCase {
    private struct Host: View {
        let controller: ScreenTimeController
        let contextKey: String
        let dataEpochID: UUID?

        var body: some View {
            Color.clear
                .modifier(ScreenTimeIntegrationModifier(
                    isReady: true, timerPresented: false,
                    contextKey: contextKey, dataEpochID: dataEpochID,
                    controller: controller
                ))
                .environment(\.scenePhase, .active)
        }
    }

    private var directories: [URL] = []

    override func setUp() {
        super.setUp()
        FocusPersistence.clear()
    }

    override func tearDown() {
        FocusPersistence.clear()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        super.tearDown()
    }

    func testTheSavedTimerShieldsKeepsThroughAPauseMovesOnResumeAndLiftsWhenCleared() async throws {
        let owner = AccountScopedLocalState.defaultsKey(base: "screen-time-owner")
        let epoch = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        let store = ScreenTimeStore(directory: directory)
        let apps = Set(try (0..<3).map { index in
            try JSONDecoder().decode(ApplicationToken.self,
                                     from: JSONEncoder().encode(["data": Data([0x81, UInt8(index)])]))
        })
        try store.update { state in
            state.contextKey = owner
            state.dataEpochID = epoch
            state.contextIsActive = true
            state.configuration.distractionSelection.applicationTokens = apps
            state.configuration.shieldsDistractionDuringFocusEnabled = true
        }
        let center = ShieldFakeCenter()
        let settings = ShieldFakeSettings(center: center)
        let engine = FocusShieldEngine(
            records: FocusShieldRecordStore(directory: store.directoryURL), settings: settings, center: center,
            resolveInterval: { schedule in
                // What `nextInterval` answers for a form it reads correctly.
                FocusShieldEngineTests.resolve(schedule, now: Date(), calendar: .current)
            },
            lockTimeout: 1)
        let shield = FocusShieldController(engine: engine, queue: DispatchQueue(label: "test.shield.host"))
        let controller = ScreenTimeController(
            store: store, currentContextKey: { owner }, monitoring: NoopMonitoring(),
            authorization: { .approved },
            diagnosticsMirror: ScreenTimeDiagnosticsMirror(directory: directory.appendingPathComponent("mirror")),
            noticeDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            focusShield: shield)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Host(
            controller: controller, contextKey: owner, dataEpochID: epoch))
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitUntil("the host binds the owner") { controller.isBound(contextKey: owner, dataEpochID: epoch) }
        try await controller.waitForPendingOperations()
        XCTAssertTrue(settings.shielded.isEmpty, "No focus, no shield")

        var timer = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try timer.startFocus(isPro: false, now: Date())
        save(timer, epoch: epoch)
        try await waitUntil("a started focus is shielded") { shield.isShielding }
        try await controller.waitForPendingOperations()
        XCTAssertEqual(settings.shielded, [apps])
        XCTAssertEqual(center.started.count, 1)
        let firstDeadline = try XCTUnwrap(engine.records.load()?.deadline)
        XCTAssertEqual(firstDeadline, try XCTUnwrap(timer.endDate).addingTimeInterval(FocusShieldPolicy.deadlineGrace))

        try timer.pause(at: Date())
        save(timer, epoch: epoch)
        try await Task.sleep(for: .milliseconds(300))
        try await controller.waitForPendingOperations()
        XCTAssertTrue(shield.isShielding, "A paused focus keeps its shield")
        XCTAssertEqual(center.started.count, 1, "and needs no DeviceActivity call")
        XCTAssertEqual(try engine.records.load()?.deadline, firstDeadline)

        try await Task.sleep(for: .milliseconds(1_100))
        try timer.resume(at: Date())
        save(timer, epoch: epoch)
        try await Task.sleep(for: .milliseconds(300))
        try await controller.waitForPendingOperations()
        XCTAssertEqual(center.started.count, 2, "A resume moves the deadline and re-registers the failsafe")
        XCTAssertGreaterThan(try XCTUnwrap(engine.records.load()?.deadline), firstDeadline)

        FocusPersistence.clear()
        try await waitUntil("a cleared timer lifts the shield") { !shield.isShielding }
        try await controller.waitForPendingOperations()
        XCTAssertEqual(settings.clearCount, 1)
        XCTAssertEqual(center.stopped, [[FocusShieldPolicy.activityName.rawValue]])
        XCTAssertEqual(try engine.records.load()?.clearedBy, FocusShieldClearReason.focusEnded.rawValue)
    }

    private func save(_ engine: PomodoroEngine, epoch: UUID) {
        FocusPersistence.save(FocusRecoveryEnvelope(engine: engine, subject: nil, clockAnchor: nil,
                                                    pendingCompletion: nil, savedAt: Date(), dataEpochID: epoch))
    }

    private func waitUntil(
        timeout: TimeInterval = 10, _ description: String, _ condition: () throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting: \(description)")
    }
}
