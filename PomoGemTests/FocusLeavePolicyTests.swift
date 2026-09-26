import XCTest
@testable import PomoGem

/// F1 (owner-requested 2026-09-26): the pure rules of the leave pause, the
/// envelope transitions every relaunch/remount path shares, the persistence
/// merge that keeps a stale screen from undoing the host's decision, and the
/// Screen Time learning hold of an automatically paused focus.
final class FocusLeavePolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_100_000)
    private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-00000000F100")!

    override func tearDown() {
        FocusPersistence.clear()
        super.tearDown()
    }

    // MARK: - Preferences

    func testSwitchesAreDeviceLocalWithOneDefaultAndReminderMigration() throws {
        let suite = "FocusLeavePolicy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(FocusLeavePolicy.enabledDefaultsKey, "focus.leave-pause.enabled")
        XCTAssertEqual(FocusLeavePolicy.nudgesEnabledDefaultsKey, "focus.leave-pause.nudges.enabled")
        XCTAssertTrue(FocusLeavePolicy.enabledByDefault)
        XCTAssertTrue(FocusLeavePolicy.isEnabled(defaults: defaults))
        XCTAssertTrue(FocusLeavePolicy.nudgesAreEnabled(defaults: defaults))

        // An explicit choice always wins over the default.
        defaults.set(false, forKey: FocusLeavePolicy.enabledDefaultsKey)
        defaults.set(false, forKey: FocusLeavePolicy.nudgesEnabledDefaultsKey)
        XCTAssertFalse(FocusLeavePolicy.isEnabled(defaults: defaults))
        XCTAssertFalse(FocusLeavePolicy.nudgesAreEnabled(defaults: defaults))

        // If the default turns off, someone who opted into the older
        // 集中に戻るお知らせ still gets a nudge; nobody else does.
        defaults.removeObject(forKey: FocusLeavePolicy.nudgesEnabledDefaultsKey)
        XCTAssertFalse(FocusLeavePolicy.nudgesAreEnabled(defaults: defaults, defaultValue: false))
        defaults.set(true, forKey: FocusReturnReminderPolicy.enabledDefaultsKey)
        XCTAssertTrue(FocusLeavePolicy.nudgesAreEnabled(defaults: defaults, defaultValue: false))
        defaults.set(false, forKey: FocusLeavePolicy.nudgesEnabledDefaultsKey)
        XCTAssertFalse(FocusLeavePolicy.nudgesAreEnabled(defaults: defaults, defaultValue: false))
    }

    /// `-focus.leave-pause.enabled NO` on the command line reaches the
    /// argument domain as the string "NO", not a Bool. It is still an
    /// explicit choice (RealDeviceCoreLoopUITests relies on it).
    func testAStringValueFromALaunchArgumentIsAnExplicitSwitch() throws {
        let suite = "FocusLeavePolicy.arguments.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: FocusReturnReminderPolicy.enabledDefaultsKey)

        for off in ["NO", "no", "false", "0"] {
            defaults.set(off, forKey: FocusLeavePolicy.enabledDefaultsKey)
            defaults.set(off, forKey: FocusLeavePolicy.nudgesEnabledDefaultsKey)
            XCTAssertFalse(FocusLeavePolicy.isEnabled(defaults: defaults), off)
            XCTAssertFalse(
                FocusLeavePolicy.nudgesAreEnabled(defaults: defaults),
                "An explicit \(off) wins over the default and the reminder migration"
            )
        }
        for on in ["YES", "true", "1"] {
            defaults.set(on, forKey: FocusLeavePolicy.enabledDefaultsKey)
            defaults.set(on, forKey: FocusLeavePolicy.nudgesEnabledDefaultsKey)
            XCTAssertTrue(FocusLeavePolicy.isEnabled(defaults: defaults, defaultValue: false), on)
            XCTAssertTrue(FocusLeavePolicy.nudgesAreEnabled(defaults: defaults, defaultValue: false), on)
        }
    }

    @MainActor
    func testCompleteDataDeletionRemovesBothSwitches() throws {
        let suite = "FocusLeavePolicy.deletion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: FocusLeavePolicy.enabledDefaultsKey)
        defaults.set(false, forKey: FocusLeavePolicy.nudgesEnabledDefaultsKey)
        try CompleteDataDeletionDefaultsCleaner.clear(defaults: defaults, persistentDomainName: suite)
        XCTAssertNil(defaults.object(forKey: FocusLeavePolicy.enabledDefaultsKey))
        XCTAssertNil(defaults.object(forKey: FocusLeavePolicy.nudgesEnabledDefaultsKey))
    }

    // MARK: - Thresholds and series

    func testWindowCutOffAndBoundedSeries() {
        XCTAssertEqual(FocusLeavePolicy.lockDetectionWindow, 20)
        XCTAssertEqual(FocusLeavePolicy.minimumRemaining, FocusReturnReminderPolicy.completionQuietWindow)
        XCTAssertEqual(FocusLeavePolicy.minimumRemaining, 60)
        XCTAssertEqual(FocusLeavePolicy.nudgeOffsets, [30, 120, 300, 600, 1200])
        XCTAssertEqual(FocusLeavePolicy.nudgeIdentifiers, [
            "pomogem.focus.leave-nudge.1",
            "pomogem.focus.leave-nudge.2",
            "pomogem.focus.leave-nudge.3",
            "pomogem.focus.leave-nudge.4",
            "pomogem.focus.leave-nudge.5"
        ])
        // A detected lock must be able to withdraw the series before its
        // first request is delivered.
        XCTAssertGreaterThan(
            FocusLeavePolicy.nudgeOffsets[0],
            FocusLeavePolicy.lockDetectionWindow + 5
        )
        XCTAssertEqual(FocusLeavePolicy.nudgeOffsets, FocusLeavePolicy.nudgeOffsets.sorted())
        // The series stops: a small, fixed budget of the 64 pending requests.
        XCTAssertLessThanOrEqual(FocusLeavePolicy.nudgeOffsets.count, 5)
    }

    func testOnlyARunningFocusWithMoreThanAMinuteLeftStartsAnAbsence() {
        let end = start.addingTimeInterval(600)
        func begins(
            enabled: Bool = true,
            phase: PomodoroPhase = .focusing,
            pending: Bool = false,
            endDate: Date? = nil,
            now: Date? = nil
        ) -> Bool {
            FocusLeavePolicy.shouldBeginExcursion(
                featureEnabled: enabled,
                phase: phase,
                hasPendingCompletion: pending,
                endDate: endDate ?? end,
                now: now ?? start
            )
        }
        XCTAssertTrue(begins())
        XCTAssertFalse(begins(enabled: false))
        XCTAssertFalse(begins(phase: .paused), "A manual pause is never touched")
        XCTAssertFalse(begins(phase: .shortBreak), "Breaks are never paused")
        XCTAssertFalse(begins(phase: .longBreak))
        XCTAssertFalse(begins(pending: true))
        XCTAssertFalse(begins(now: end.addingTimeInterval(-60)), "The last minute is left to finish")
        XCTAssertTrue(begins(now: end.addingTimeInterval(-61)))
        XCTAssertFalse(begins(endDate: .distantPast))
    }

    func testClassificationOutcomes() {
        XCTAssertEqual(FocusLeavePolicy.classify(.lockNotice, deviceHasPasscode: true), .locked)
        XCTAssertEqual(
            FocusLeavePolicy.classify(.windowEnded(protectedDataIsAvailable: false), deviceHasPasscode: true),
            .locked,
            "A notice missed during a slow add is caught by the state at the end"
        )
        XCTAssertEqual(
            FocusLeavePolicy.classify(.windowEnded(protectedDataIsAvailable: true), deviceHasPasscode: true),
            .left
        )
        XCTAssertEqual(FocusLeavePolicy.classify(.backgroundTimeExpired, deviceHasPasscode: true), .left)
        // Without a passcode a lock cannot be told from leaving.
        for signal in [
            FocusLeavePolicy.WindowSignal.lockNotice,
            .windowEnded(protectedDataIsAvailable: false),
            .windowEnded(protectedDataIsAvailable: true),
            .backgroundTimeExpired
        ] {
            XCTAssertEqual(FocusLeavePolicy.classify(signal, deviceHasPasscode: false), .left)
        }
    }

    func testReturnWithinTheWindowIsAQuickGlance() {
        XCTAssertEqual(FocusLeavePolicy.outcomeOnReturn(leftAt: start, now: start), .quickGlance)
        XCTAssertEqual(
            FocusLeavePolicy.outcomeOnReturn(leftAt: start, now: start.addingTimeInterval(20)),
            .quickGlance
        )
        XCTAssertEqual(
            FocusLeavePolicy.outcomeOnReturn(leftAt: start, now: start.addingTimeInterval(20.5)),
            .left
        )
        XCTAssertEqual(
            FocusLeavePolicy.outcomeOnReturn(leftAt: start, now: start.addingTimeInterval(-3_600)),
            .quickGlance,
            "A clock moved backwards is no evidence of an absence"
        )
    }

    func testRunningCopySelection() {
        XCTAssertEqual(
            FocusLeavePolicy.runningNotice(featureEnabled: false, deviceHasPasscode: true),
            .keepsRunning
        )
        XCTAssertEqual(
            FocusLeavePolicy.runningNotice(featureEnabled: false, deviceHasPasscode: false),
            .keepsRunning
        )
        XCTAssertEqual(
            FocusLeavePolicy.runningNotice(featureEnabled: true, deviceHasPasscode: true),
            .pausesWhenLeavingButNotWhenLocked
        )
        XCTAssertEqual(
            FocusLeavePolicy.runningNotice(featureEnabled: true, deviceHasPasscode: false),
            .pausesWhenLeavingOrLocking
        )
    }

    func testNudgeCopyIsNeutralAndFactual() {
        XCTAssertEqual(FocusLeaveNudgeCopy.title, "集中が切れています")
        XCTAssertEqual(
            FocusLeaveNudgeCopy.body(forNudgeAt: 0),
            "タイマーを一時停止しました。ポモジェムに戻ると続きから再開できます。"
        )
        XCTAssertEqual(
            FocusLeaveNudgeCopy.body(forNudgeAt: 1),
            "一時停止して2分たちました。戻れば続きから再開できます。"
        )
        XCTAssertEqual(
            FocusLeaveNudgeCopy.body(forNudgeAt: 2),
            "一時停止して5分たちました。戻れば続きから再開できます。"
        )
        XCTAssertEqual(
            FocusLeaveNudgeCopy.body(forNudgeAt: 4),
            "一時停止して20分たちました。戻れば続きから再開できます。"
        )
        let everything = ([FocusLeaveNudgeCopy.title] + FocusLeavePolicy.nudgeOffsets.indices.map {
            FocusLeaveNudgeCopy.body(forNudgeAt: $0)
        }).joined()
        for forbidden in ["連続", "失", "無駄", "残念", "粒", "g"] {
            XCTAssertFalse(everything.contains(forbidden), "No guilt, streak, loss or reward copy: \(forbidden)")
        }
    }

    // MARK: - Transitions

    func testLeavingPausesRetroactivelyAtTheMomentOfLeaving() throws {
        let running = try runningEnvelope(minutes: 25)
        let leftAt = start.addingTimeInterval(300)
        let away = try XCTUnwrap(FocusLeaveTransition.beginningExcursion(
            running, featureEnabled: true, at: leftAt
        ))
        XCTAssertEqual(away.leaveExcursion, FocusLeaveExcursion(sessionID: sessionID, leftAt: leftAt))
        XCTAssertEqual(away.engine, running.engine, "Leaving alone changes nothing yet")

        let decidedAt = leftAt.addingTimeInterval(20)
        let paused = FocusLeaveTransition.pausedForLeaving(away, decidedAt: decidedAt)
        XCTAssertEqual(paused.engine.phase, .paused)
        XCTAssertEqual(paused.engine.currentSessionID, sessionID)
        XCTAssertEqual(paused.engine.currentSource, .timer, "A pause is not a fairness event")
        // Away time never counts, however long the person stays away.
        for later in [decidedAt, decidedAt.addingTimeInterval(3_600)] {
            XCTAssertEqual(paused.engine.snapshot(at: later).remainingSeconds, 1_200)
        }
        XCTAssertNil(paused.leaveExcursion)
        XCTAssertEqual(paused.leavePause, FocusLeavePauseMarker(
            sessionID: sessionID,
            pausedAt: leftAt,
            plannedEndDate: start.addingTimeInterval(1_500)
        ))
        XCTAssertNil(paused.scheduledCompletionNotificationDeliveryDate)
        XCTAssertEqual(paused.savedAt, decidedAt, "The row carries the time of this write")
        XCTAssertEqual(
            FocusPersistence.relaunchAction(for: paused, at: decidedAt.addingTimeInterval(7_200)),
            .resumeFocus(remainingSeconds: 1_200)
        )
    }

    func testTheEndWitnessOfTheRunningFocusDoesNotInvalidateThePause() throws {
        var running = try runningEnvelope(minutes: 25)
        running.scheduledCompletionNotificationDeliveryDate = start.addingTimeInterval(1_500.5)
        let away = try XCTUnwrap(FocusLeaveTransition.beginningExcursion(
            running, featureEnabled: true, at: start.addingTimeInterval(60)
        ))
        let paused = FocusLeaveTransition.pausedForLeaving(away, decidedAt: start.addingTimeInterval(90))
        FocusPersistence.save(paused)
        let restored = try XCTUnwrap(FocusPersistence.load(at: start.addingTimeInterval(90)))
        XCTAssertEqual(restored.engine.phase, .paused, "A stale witness must not discard the timer")
        XCTAssertEqual(restored.leavePause?.sessionID, sessionID)
    }

    func testQuickGlanceAndLockKeepTheTimerRunning() throws {
        let running = try runningEnvelope(minutes: 25)
        let leftAt = start.addingTimeInterval(60)
        let away = try XCTUnwrap(FocusLeaveTransition.beginningExcursion(
            running, featureEnabled: true, at: leftAt
        ))
        let glance = FocusLeaveTransition.resolvingOnReturn(away, at: leftAt.addingTimeInterval(12))
        XCTAssertNil(glance.leaveExcursion)
        XCTAssertNil(glance.leavePause)
        XCTAssertEqual(glance.engine, running.engine)

        let locked = FocusLeaveTransition.resolvingAsLocked(away)
        XCTAssertEqual(locked.engine, running.engine)
        XCTAssertNil(locked.leaveExcursion)

        let longer = FocusLeaveTransition.resolvingOnReturn(away, at: leftAt.addingTimeInterval(21))
        XCTAssertEqual(longer.engine.phase, .paused)
        XCTAssertEqual(longer.engine.snapshot(at: leftAt.addingTimeInterval(21)).remainingSeconds, 1_440)
    }

    func testIneligibleEnvelopesNeverStartAnAbsence() throws {
        let running = try runningEnvelope(minutes: 25)
        XCTAssertNil(FocusLeaveTransition.beginningExcursion(
            running, featureEnabled: false, at: start.addingTimeInterval(60)
        ))
        XCTAssertNil(FocusLeaveTransition.beginningExcursion(
            running, featureEnabled: true, at: start.addingTimeInterval(1_440)
        ), "60 s or less remain")
        var paused = running
        try paused.engine.pause(at: start.addingTimeInterval(60))
        XCTAssertNil(FocusLeaveTransition.beginningExcursion(
            paused, featureEnabled: true, at: start.addingTimeInterval(120)
        ), "A manual pause is left alone")
    }

    // MARK: - Relaunch and remount (critic A3)

    func testProcessDeathDuringTheWindowNeverFinishesTheLeftFocus() throws {
        let running = try runningEnvelope(minutes: 25)
        let leftAt = start.addingTimeInterval(600)
        let away = try XCTUnwrap(FocusLeaveTransition.beginningExcursion(
            running, featureEnabled: true, at: leftAt
        ))
        // The process died inside the window; the person comes back after
        // the planned end.
        let relaunchAt = start.addingTimeInterval(3_600)
        XCTAssertEqual(
            FocusPersistence.relaunchAction(for: away, at: relaunchAt),
            .resumeFocus(remainingSeconds: 900),
            "Relaunch must not finish (and award) a focus the person left"
        )
        let prepared = FocusPersistence.preparedForLocalRelaunch(away, at: relaunchAt, uptime: 5_000)
        XCTAssertEqual(prepared.engine.phase, .paused)
        XCTAssertEqual(prepared.leavePause?.pausedAt, leftAt)

        FocusPersistence.save(away)
        let loaded = try XCTUnwrap(FocusPersistence.load(at: relaunchAt))
        XCTAssertEqual(loaded.engine.phase, .paused)
        XCTAssertEqual(loaded.engine.snapshot(at: relaunchAt).remainingSeconds, 900)
        XCTAssertEqual(loaded.leavePause?.pausedAt, leftAt)
        XCTAssertNil(loaded.leaveExcursion)
        // The decision was written, so every later reader agrees.
        let stored = try XCTUnwrap(FocusPersistence.loadStored(key: FocusPersistence.key))
        XCTAssertEqual(stored.engine.phase, .paused)
    }

    func testAReaderInsideTheWindowLeavesTheAbsenceToTheHost() throws {
        let running = try runningEnvelope(minutes: 25)
        let leftAt = start.addingTimeInterval(600)
        let away = try XCTUnwrap(FocusLeaveTransition.beginningExcursion(
            running, featureEnabled: true, at: leftAt
        ))
        FocusPersistence.save(away)
        let loaded = try XCTUnwrap(FocusPersistence.load(at: leftAt.addingTimeInterval(10)))
        XCTAssertEqual(loaded.engine.phase, .focusing)
        XCTAssertEqual(loaded.leaveExcursion?.leftAt, leftAt)
    }

    func testLaunchStatusPeekShowsALeftFocusAsPausedWithoutWriting() throws {
        let running = try runningEnvelope(minutes: 25)
        let away = try XCTUnwrap(FocusLeaveTransition.beginningExcursion(
            running, featureEnabled: true, at: start.addingTimeInterval(600)
        ))
        let suite = "FocusLeavePolicy.peek.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let namespace = AccountDataNamespace()
        let key = AccountScopedLocalState.defaultsKey(base: "focus.persisted-engine", namespace: namespace)
        defaults.set(try JSONEncoder().encode(away), forKey: key)

        let peek = FocusPersistence.peekTimerEnvelopes(
            namespace: namespace,
            defaults: defaults,
            at: start.addingTimeInterval(3_600)
        )
        XCTAssertEqual(peek.focus?.engine.phase, .paused)
        let bytes = try XCTUnwrap(defaults.data(forKey: key))
        XCTAssertEqual(
            try JSONDecoder().decode(FocusRecoveryEnvelope.self, from: bytes).engine.phase,
            .focusing,
            "The launch host's peek never writes"
        )
    }

    // MARK: - Persistence merge

    func testAScreenWriteKeepsAnAbsenceTheHostIsWatching() throws {
        let running = try runningEnvelope(minutes: 25)
        let away = try XCTUnwrap(FocusLeaveTransition.beginningExcursion(
            running, featureEnabled: true, at: start.addingTimeInterval(60)
        ))
        let merged = FocusPersistence.mergingLeaveMarkers(into: running, stored: away)
        XCTAssertEqual(merged.leaveExcursion, away.leaveExcursion)

        // Another session's marker never travels.
        var other = try runningEnvelope(minutes: 25, sessionID: UUID())
        other = FocusPersistence.mergingLeaveMarkers(into: other, stored: away)
        XCTAssertNil(other.leaveExcursion)
    }

    func testAStaleRunningWriteCannotUndoTheLeavePause() throws {
        let running = try runningEnvelope(minutes: 25)
        let leftAt = start.addingTimeInterval(60)
        let away = try XCTUnwrap(FocusLeaveTransition.beginningExcursion(
            running, featureEnabled: true, at: leftAt
        ))
        let paused = FocusLeaveTransition.pausedForLeaving(away, decidedAt: leftAt.addingTimeInterval(20))

        // The screen still holds the running engine from before leaving.
        XCTAssertEqual(FocusPersistence.mergingLeaveMarkers(into: running, stored: paused), paused)

        // Its paused writes keep the marker for the notice.
        var screenPaused = running
        screenPaused.engine = paused.engine
        XCTAssertEqual(
            FocusPersistence.mergingLeaveMarkers(into: screenPaused, stored: paused).leavePause,
            paused.leavePause
        )

        // A real 再開 ends later than the planned end and drops the marker.
        var resumed = paused
        try resumed.engine.resume(at: leftAt.addingTimeInterval(600))
        resumed.leavePause = nil
        let afterResume = FocusPersistence.mergingLeaveMarkers(into: resumed, stored: paused)
        XCTAssertEqual(afterResume.engine.phase, .focusing)
        XCTAssertNil(afterResume.leavePause)
        XCTAssertEqual(
            afterResume.engine.endDate,
            leftAt.addingTimeInterval(600 + 1_440)
        )
    }

    /// The focus screen saves its own running state on `.inactive` and
    /// `.background`, in no fixed order with the host's write of the absence.
    /// `FocusPersistence.save` itself must carry the host's markers (critic
    /// A3), not only the merge function.
    func testTheScreenSavePathKeepsTheHostsMarkers() throws {
        let suite = "FocusLeavePolicy.save.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "test.focus.persisted-engine"
        func stored() throws -> FocusRecoveryEnvelope {
            try XCTUnwrap(FocusPersistence.loadStored(key: key, defaults: defaults))
        }

        let running = try runningEnvelope(minutes: 25)
        let leftAt = start.addingTimeInterval(60)
        let away = try XCTUnwrap(FocusLeaveTransition.beginningExcursion(
            running, featureEnabled: true, at: leftAt
        ))

        // (1) The host wrote the absence first; the screen's save follows.
        FocusPersistence.replace(away, key: key, defaults: defaults)
        FocusPersistence.save(running, key: key, defaults: defaults)
        XCTAssertEqual(try stored().leaveExcursion, away.leaveExcursion)
        XCTAssertEqual(try stored().engine, running.engine)

        // (2) The host paused; the screen writes the exact running state from
        // before the person left.
        let paused = FocusLeaveTransition.pausedForLeaving(away, decidedAt: leftAt.addingTimeInterval(20))
        FocusPersistence.replace(paused, key: key, defaults: defaults)
        FocusPersistence.save(running, key: key, defaults: defaults)
        XCTAssertEqual(try stored(), paused)
        var screenPaused = running
        screenPaused.engine = paused.engine
        FocusPersistence.save(screenPaused, key: key, defaults: defaults)
        XCTAssertEqual(try stored().leavePause, paused.leavePause, "The notice survives a paused write")

        // (3) A real 再開 is newer than the pause and drops the marker.
        var resumed = screenPaused
        try resumed.engine.resume(at: leftAt.addingTimeInterval(600))
        FocusPersistence.save(resumed, key: key, defaults: defaults)
        XCTAssertEqual(try stored().engine.phase, .focusing)
        XCTAssertNil(try stored().leavePause)
        XCTAssertNil(try stored().leaveExcursion)
        XCTAssertEqual(try stored().engine.endDate, leftAt.addingTimeInterval(600 + 1_440))

        // (4) Another session never inherits a marker.
        FocusPersistence.replace(away, key: key, defaults: defaults)
        let other = try runningEnvelope(minutes: 25, sessionID: UUID())
        FocusPersistence.save(other, key: key, defaults: defaults)
        XCTAssertEqual(try stored().engine, other.engine)
        XCTAssertNil(try stored().leaveExcursion)
        XCTAssertNil(try stored().leavePause)
    }

    func testMarkersThatDoNotDescribeTheTimerAreDropped() throws {
        var running = try runningEnvelope(minutes: 25)
        running.leavePause = FocusLeavePauseMarker(
            sessionID: sessionID, pausedAt: start, plannedEndDate: start
        )
        XCTAssertNil(running.normalizingLeaveMarkers().leavePause, "A running focus is not leave-paused")

        var paused = try runningEnvelope(minutes: 25)
        try paused.engine.pause(at: start.addingTimeInterval(60))
        paused.leaveExcursion = FocusLeaveExcursion(sessionID: sessionID, leftAt: start)
        XCTAssertNil(paused.normalizingLeaveMarkers().leaveExcursion, "A paused focus has no absence")
        paused.leavePause = FocusLeavePauseMarker(
            sessionID: UUID(), pausedAt: start, plannedEndDate: start
        )
        XCTAssertNil(paused.normalizingLeaveMarkers().leavePause, "Another session's marker")
    }

    func testMarkersAreOptionalDeviceLocalAndNeverSynced() throws {
        let running = try runningEnvelope(minutes: 25)
        let away = try XCTUnwrap(FocusLeaveTransition.beginningExcursion(
            running, featureEnabled: true, at: start.addingTimeInterval(60)
        ))
        let paused = FocusLeaveTransition.pausedForLeaving(away, decidedAt: start.addingTimeInterval(90))

        // Round trip.
        let decoded = try JSONDecoder().decode(
            FocusRecoveryEnvelope.self,
            from: JSONEncoder().encode(paused)
        )
        XCTAssertEqual(decoded, paused)

        // An envelope written before F1 decodes with no markers.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(running)
        ) as? [String: Any])
        legacy.removeValue(forKey: "leaveExcursion")
        legacy.removeValue(forKey: "leavePause")
        let old = try JSONDecoder().decode(
            FocusRecoveryEnvelope.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertNil(old.leaveExcursion)
        XCTAssertNil(old.leavePause)

        // CloudKit carries no new field: the portable payload omits both.
        for envelope in [away, paused] {
            let payload = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(FocusCloudPayload(envelope: envelope))
            ) as? [String: Any]
            XCTAssertNil(payload?["leaveExcursion"])
            XCTAssertNil(payload?["leavePause"])
        }
    }

    // MARK: - Screen Time learning hold (D1.10)

    func testAnAutoPausedFocusHoldsTheLearningLaneUntilItsPlannedEnd() throws {
        let epoch = UUID()
        var running = try runningEnvelope(minutes: 25)
        running.dataEpochID = epoch
        let leftAt = start.addingTimeInterval(300)
        let away = try XCTUnwrap(FocusLeaveTransition.beginningExcursion(
            running, featureEnabled: true, at: leftAt
        ))
        let paused = FocusLeaveTransition.pausedForLeaving(away, decidedAt: leftAt.addingTimeInterval(20))
        let plannedEnd = start.addingTimeInterval(1_500)

        XCTAssertEqual(
            ScreenTimeTimerHold.learningPause(for: paused, dataEpochID: epoch, at: leftAt.addingTimeInterval(20)),
            .until(plannedEnd)
        )
        XCTAssertEqual(
            ScreenTimeTimerHold.learningPause(for: paused, dataEpochID: epoch, at: plannedEnd),
            ScreenTimeLearningPause.none,
            "Study-app time counts again after the planned end, even if they never return"
        )

        // A pause the person chose still holds the lane with no end.
        var manual = running
        try manual.engine.pause(at: leftAt)
        XCTAssertEqual(
            ScreenTimeTimerHold.learningPause(for: manual, dataEpochID: epoch, at: leftAt),
            .indefinite
        )
        // While the absence is still undecided, the running hold applies.
        XCTAssertEqual(
            ScreenTimeTimerHold.learningPause(for: away, dataEpochID: epoch, at: leftAt),
            .until(plannedEnd)
        )
    }

    // MARK: - Helpers

    private func runningEnvelope(
        minutes: Int,
        sessionID: UUID? = nil
    ) throws -> FocusRecoveryEnvelope {
        XCTAssertEqual(minutes, 25)
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start, sessionID: sessionID ?? self.sessionID)
        return FocusRecoveryEnvelope(
            engine: engine,
            subject: FocusSubjectSnapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000F1AA")!,
                name: "英語",
                colorHex: "#4C8CCF"
            ),
            clockAnchor: ClockAnchor(wallDate: start, systemUptime: 5_000),
            pendingCompletion: nil,
            savedAt: start
        )
    }
}
