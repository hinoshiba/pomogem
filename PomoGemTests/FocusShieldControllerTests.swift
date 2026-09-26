import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
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
        XCTAssertEqual(decide(focus: .running(sessionID: session, plannedEnd: end)),
                       .apply(sessionID: session, deadline: end.addingTimeInterval(60)))
        XCTAssertEqual(decide(focus: .running(sessionID: session, plannedEnd: end), at: end.addingTimeInterval(30)),
                       .apply(sessionID: session, deadline: end.addingTimeInterval(60)),
                       "Not advanced yet but inside the grace: still shielded")
        XCTAssertEqual(decide(focus: .running(sessionID: session, plannedEnd: end), at: end.addingTimeInterval(60)),
                       .idle)
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
        fixture.controller.reconcile(configuration: configuration, authorization: .approved,
                                     focus: .paused(sessionID: session), now: now.addingTimeInterval(600))
        await fixture.controller.waitForPendingOperations()
        XCTAssertTrue(fixture.controller.isShielding)
        XCTAssertEqual(fixture.center.started.count, 1)
        XCTAssertTrue(fixture.center.stopped.isEmpty)

        // Resumed: the deadline moves with the new planned end.
        let resumedEnd = end.addingTimeInterval(900)
        fixture.controller.reconcile(configuration: configuration, authorization: .approved,
                                     focus: .running(sessionID: session, plannedEnd: resumedEnd),
                                     now: now.addingTimeInterval(1_500))
        await fixture.controller.waitForPendingOperations()
        XCTAssertEqual(fixture.center.started.count, 2)
        XCTAssertEqual(try fixture.engine.records.load()?.deadline, resumedEnd.addingTimeInterval(60))

        // Completed: lifted, the failsafe stopped by name.
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

        fixture.controller.liftForCurrentFocus(now: now.addingTimeInterval(60))
        await fixture.controller.waitForPendingOperations()
        XCTAssertFalse(fixture.controller.isShielding)
        fixture.controller.reconcile(configuration: configuration, authorization: .approved, focus: running,
                                     now: now.addingTimeInterval(63), force: true)
        await fixture.controller.waitForPendingOperations()
        XCTAssertFalse(fixture.controller.isShielding, "The forced activation pass must not re-apply it")
        XCTAssertEqual(fixture.settings.shielded.count, 1)
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

    // MARK: - ScreenTimeController paths that must lift a shield

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

    func testTheDefaultShieldRecordLivesNextToTheControllersOwnLedger() throws {
        let directory = makeDirectory()
        let store = ScreenTimeStore(directory: directory)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: NoopMonitoring(), authorization: { .approved },
                                              diagnosticsMirror: ScreenTimeDiagnosticsMirror(directory: makeDirectory()))
        XCTAssertEqual(store.directoryURL, directory.appendingPathComponent("ScreenTime", isDirectory: true))
        XCTAssertFalse(controller.focusShield.isShielding)
        XCTAssertFalse(FocusShieldRecordStore(directory: store.directoryURL).exists)
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
    }

    /// Without an explicit resolver the framework is trusted to resolve each
    /// schedule to the interval it was built for (the schedule math and the
    /// real `nextInterval` have their own tests in FocusShieldEngineTests).
    private func makeController(resolve: ((DeviceActivitySchedule) -> DateInterval?)? = nil) -> Fixture {
        let directory = makeDirectory().appendingPathComponent("ScreenTime", isDirectory: true)
        let center = ShieldFakeCenter()
        let settings = ShieldFakeSettings(center: center)
        let engine = FocusShieldEngine(
            records: FocusShieldRecordStore(directory: directory), settings: settings, center: center,
            resolveInterval: resolve ?? { schedule in Self.plannedInterval(schedule) }, lockTimeout: 1)
        return Fixture(controller: FocusShieldController(engine: engine, queue: DispatchQueue(label: "test.shield")),
                       engine: engine, settings: settings, center: center)
    }

    /// The interval a schedule built by `FocusShieldSchedule` denotes: its
    /// time-only start in the hour before, its end next after the start.
    nonisolated private static func plannedInterval(_ schedule: DeviceActivitySchedule) -> DateInterval? {
        let calendar = Calendar.current
        func resolve(_ components: DateComponents, after anchor: Date) -> Date? {
            if components.year != nil {
                var zoned = Calendar(identifier: .gregorian)
                zoned.timeZone = components.timeZone ?? calendar.timeZone
                return zoned.date(from: components)
            }
            return calendar.nextDate(after: anchor, matching: components, matchingPolicy: .strict)
        }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        guard let start = resolve(schedule.intervalStart, after: base.addingTimeInterval(-3_601)),
              let end = resolve(schedule.intervalEnd, after: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    private func boundScreenTimeController(
        shield: FocusShieldController,
        authorization: @escaping () -> AuthorizationStatus = { .approved }
    ) async throws -> (ScreenTimeController, ScreenTimeStore) {
        let store = ScreenTimeStore(directory: makeDirectory())
        let distraction = try selection(count: 3, seed: 0x72)
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

private final class NoopMonitoring: ScreenTimeMonitoringDriving {
    func stop() {}
    func invalidateAuthorizationIfNeeded() throws {}
    func synchronize(now: Date) throws -> Bool { false }
}
