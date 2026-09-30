import AVFoundation
import XCTest
@testable import PomoGem

/// F5 part 1 host upkeep: the owner the launch reconcile reads from the saved
/// timer, the activation reconcile, the rendered sound files and complete
/// data deletion.
@MainActor
final class FocusEndAlarmMaintenanceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_300_000)
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var client: FakeFocusEndAlarmClient!
    private var clock: Date!
    private var scheduler: FocusEndAlarmScheduler!
    private var library: URL!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "alarm-maintenance-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        client = FakeFocusEndAlarmClient()
        clock = start.addingTimeInterval(60)
        scheduler = FocusEndAlarmScheduler(
            client: client,
            store: FocusEndAlarmBookingStore(defaults: defaults),
            now: { [unowned self] in self.clock }
        )
        library = FileManager.default.temporaryDirectory
            .appendingPathComponent("alarm-maintenance-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: library)
        try await super.tearDown()
    }

    private func focus(sessionID: UUID = UUID()) throws -> (FocusRecoveryEnvelope, PomodoroEngine) {
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start, sessionID: sessionID)
        let envelope = FocusRecoveryEnvelope(
            engine: engine,
            subject: FocusSubjectSnapshot(id: UUID(), name: "英語", colorHex: "#4C8CCF"),
            clockAnchor: ClockAnchor(wallDate: start, systemUptime: 5_000),
            pendingCompletion: nil,
            savedAt: start
        )
        return (envelope, engine)
    }

    // MARK: The owner

    func testTheOwnerIsTheRunningFocusOrTheSavedBreak() throws {
        let session = UUID()
        let (running, engine) = try focus(sessionID: session)
        XCTAssertEqual(
            FocusEndAlarmOwner.current(focus: running, rest: nil),
            FocusEndAlarmOwner(sessionID: session, phase: .focus, endDate: start.addingTimeInterval(1_500))
        )

        var pausedEngine = engine
        try pausedEngine.pause(at: start.addingTimeInterval(60))
        var paused = running
        paused.engine = pausedEngine
        XCTAssertEqual(
            FocusEndAlarmOwner.current(focus: paused, rest: nil),
            FocusEndAlarmOwner(sessionID: session, phase: .focus, endDate: nil),
            "A paused focus has no end to ring"
        )

        var ended = running
        var endedEngine = engine
        guard case let .focusCompleted(result) = endedEngine.advance(
            at: start.addingTimeInterval(1_500), observedUptime: 6_500
        ) else { return XCTFail("the focus did not end") }
        ended.engine = endedEngine
        ended.pendingCompletion = result
        XCTAssertNil(FocusEndAlarmOwner.current(focus: ended, rest: nil))

        let rest = BreakRecoveryEnvelope(id: UUID(), minutes: 5, endDate: start.addingTimeInterval(300))
        XCTAssertEqual(
            FocusEndAlarmOwner.current(focus: nil, rest: rest),
            FocusEndAlarmOwner(sessionID: rest.id, phase: .breakTime, endDate: rest.endDate)
        )
        XCTAssertEqual(FocusEndAlarmOwner.current(focus: running, rest: rest)?.phase, .focus)
        XCTAssertNil(FocusEndAlarmOwner.current(focus: nil, rest: nil))
    }

    // MARK: Activation reconcile

    func testActivationKeepsTheRunningFocusAlarmAndCancelsAStaleOne() async throws {
        let session = UUID()
        let (running, engine) = try focus(sessionID: session)
        guard case let .booked(booking) = await scheduler.schedule(
            sessionID: session, phase: .focus, endDate: start.addingTimeInterval(1_500), soundFileName: nil
        ) else { return XCTFail() }
        let orphan = UUID()
        client.insert(orphan, state: .scheduled)

        let kept = FocusEndAlarmMaintenance.reconcileOnActivation(
            scheduler: scheduler, focus: running, rest: nil
        )
        XCTAssertEqual(kept.cancelIDs, [orphan])
        XCTAssertFalse(kept.clearsBooking)
        XCTAssertFalse(kept.ownerNeedsBooking)
        XCTAssertEqual(scheduler.booking, booking)

        // Paused while the app was away (a pause another path wrote).
        var pausedEngine = engine
        try pausedEngine.pause(at: clock)
        var paused = running
        paused.engine = pausedEngine
        let stale = FocusEndAlarmMaintenance.reconcileOnActivation(
            scheduler: scheduler, focus: paused, rest: nil
        )
        XCTAssertTrue(stale.clearsBooking)
        XCTAssertNil(scheduler.booking)
        XCTAssertTrue(client.cancelled.contains(booking.alarmID))
    }

    func testActivationNeverCancelsARingingAlarmAndNeverBooks() async throws {
        let session = UUID()
        let (running, _) = try focus(sessionID: session)
        guard case let .booked(booking) = await scheduler.schedule(
            sessionID: session, phase: .focus, endDate: start.addingTimeInterval(1_500), soundFileName: nil
        ) else { return XCTFail() }
        client.states[booking.alarmID] = .alerting
        clock = start.addingTimeInterval(1_501)
        let decision = FocusEndAlarmMaintenance.reconcileOnActivation(
            scheduler: scheduler, focus: nil, rest: nil
        )
        XCTAssertTrue(decision.cancelIDs.isEmpty)
        XCTAssertEqual(scheduler.booking?.alarmID, booking.alarmID)

        // A running focus without an alarm is reported, not booked here.
        scheduler.cancelAll()
        let needs = FocusEndAlarmMaintenance.reconcileOnActivation(
            scheduler: scheduler, focus: running, rest: nil
        )
        XCTAssertTrue(needs.ownerNeedsBooking)
        XCTAssertTrue(client.scheduled.isEmpty)
    }

    /// F1 applies an absence before anything reads the saved timer. A
    /// relaunch after the process died inside the leave window must see the
    /// focus paused through the production loader, never keep its alarm.
    func testARelaunchAfterTheLeaveWindowCancelsTheAlarmOfTheFocusF1Paused() async throws {
        let session = UUID()
        let (running, _) = try focus(sessionID: session)
        let key = "alarm-maintenance-focus-\(UUID().uuidString)"
        let leftAt = start.addingTimeInterval(30)
        var away = running
        away.leaveExcursion = FocusLeaveExcursion(sessionID: session, leftAt: leftAt)
        FocusPersistence.replace(away, key: key, defaults: defaults)
        guard case let .booked(booking) = await scheduler.schedule(
            sessionID: session, phase: .focus, endDate: start.addingTimeInterval(1_500), soundFileName: nil
        ) else { return XCTFail() }
        let savedTimer = FocusEndAlarmSavedTimer(
            defaults: defaults,
            focusKey: key,
            now: { [unowned self] in self.clock },
            returnedAt: { nil }
        )

        // Inside the window nothing is decided yet: the focus still runs.
        clock = leftAt.addingTimeInterval(10)
        let inside = FocusEndAlarmMaintenance.reconcileOnActivation(scheduler: scheduler, savedTimer: savedTimer)
        XCTAssertFalse(inside.clearsBooking)
        XCTAssertEqual(scheduler.booking, booking)

        clock = leftAt.addingTimeInterval(FocusLeavePolicy.lockDetectionWindow + 1)
        let relaunch = FocusEndAlarmMaintenance.reconcileOnActivation(scheduler: scheduler, savedTimer: savedTimer)
        XCTAssertTrue(relaunch.clearsBooking)
        XCTAssertFalse(relaunch.ownerNeedsBooking, "a paused focus has no end to ring")
        XCTAssertNil(scheduler.booking)
        XCTAssertTrue(client.cancelled.contains(booking.alarmID))
        XCTAssertEqual(FocusPersistence.loadStored(key: key, defaults: defaults)?.engine.phase, .paused)
    }

    // MARK: Files

    func testCueFilesAreCurrentAndStaleOnesGo() throws {
        let fileManager = FileManager.default
        let sounds = try AlarmSoundLibrary.soundsDirectory(libraryDirectory: library)
        XCTAssertTrue(AlarmSoundLibrary.currentFileNames.contains("pomogem-alarm-bell-cue-v1.caf"))
        XCTAssertFalse(
            AlarmSoundLibrary.currentFileNames.contains("pomogem-alarm-soft-cue-v1.caf"),
            "The original chimes keep TimerCompletionSoundLibrary's files"
        )
        for name in ["pomogem-alarm-bell-cue-v1.caf", "pomogem-alarm-bell-v0.caf", "pomogem-timer-soft-v1.caf"] {
            fileManager.createFile(atPath: sounds.appendingPathComponent(name).path, contents: Data([1]))
        }
        let removed = try AlarmSoundLibrary.removeStaleRingtoneFiles(libraryDirectory: library)
        XCTAssertEqual(removed.map(\.lastPathComponent), ["pomogem-alarm-bell-v0.caf"])
        XCTAssertTrue(fileManager.fileExists(atPath: sounds.appendingPathComponent("pomogem-alarm-bell-cue-v1.caf").path))
        XCTAssertTrue(fileManager.fileExists(atPath: sounds.appendingPathComponent("pomogem-timer-soft-v1.caf").path))
    }

    func testAPreparedCueIsOneShortCycleWrittenOnceAndOffTheMainThread() async throws {
        async let first = AlarmSoundLibrary.preparedFile(.cue, for: .digital, libraryDirectory: library)
        async let second = AlarmSoundLibrary.preparedFile(.cue, for: .digital, libraryDirectory: library)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.lastPathComponent, "pomogem-alarm-digital-cue-v1.caf")
        let file = try AVAudioFile(forReading: a)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        XCTAssertGreaterThan(seconds, 0.5)
        XCTAssertLessThan(seconds, 6, "One cycle, not the ringtone")
        let values = try a.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)

        do {
            _ = try await AlarmSoundLibrary.preparedFile(.cue, for: .soft, libraryDirectory: library)
            XCTFail("A legacy chime has no cue file here")
        } catch {}
    }

    func testRenderingGivesTheLegacyCueUntouchedAndANewSoundItsPreview() async {
        let chime = await MainActor.run { AlarmSoundLibrary.legacyChime(for: .soft) }
        let legacy = AlarmSoundLibrary.render(.soft, legacyChime: chime)
        XCTAssertEqual(legacy.cue, chime, "控えめ plays today's chime")
        XCTAssertFalse(legacy.loop.isEmpty)
        let bell = AlarmSoundLibrary.render(.bell, legacyChime: nil)
        XCTAssertEqual(bell.cue, AlarmSoundSynthesis.preview(AlarmSoundSynthesis.source(for: .bell)))
        XCTAssertEqual(bell.loop, AlarmSoundSynthesis.loop(AlarmSoundSynthesis.source(for: .bell)))
    }

    // MARK: Complete data deletion

    func testCompleteDeletionCancelsEveryAlarmAndRemovesEveryRenderedSound() async throws {
        let fileManager = FileManager.default
        _ = await scheduler.schedule(
            sessionID: UUID(), phase: .focus, endDate: start.addingTimeInterval(1_500), soundFileName: nil
        )
        let orphan = UUID()
        client.insert(orphan, state: .alerting)
        let sounds = try AlarmSoundLibrary.soundsDirectory(libraryDirectory: library)
        for name in ["pomogem-alarm-bell-v1.caf", "pomogem-alarm-bell-cue-v1.caf", ".pomogem-alarm-bell-v1.caf.writing", "someone-else.caf"] {
            fileManager.createFile(atPath: sounds.appendingPathComponent(name).path, contents: Data([1]))
        }

        await FocusEndAlarmMaintenance.eraseForCompleteDataDeletion(scheduler: scheduler, libraryDirectory: library)

        XCTAssertNil(scheduler.booking)
        XCTAssertTrue(client.states.isEmpty, "Orphans too, even one that is ringing")
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: sounds.path), ["someone-else.caf"])
    }

    func testCompleteDeletionWaitsForARingtoneWriteAlreadyInFlight() async throws {
        let gate = HeldRenderedSoundWrite()
        let sounds = try AlarmSoundLibrary.soundsDirectory(libraryDirectory: library)
        let destination = sounds.appendingPathComponent(AlarmSoundLibrary.fileName(for: .bell))
        let generation = AlarmSoundLibrary.preparationGeneration
        let preparation = Task {
            try await AlarmSoundLibrary.preparedFile(
                .ringtone,
                for: .bell,
                libraryDirectory: library,
                prepareFile: {
                    await gate.waitToWrite()
                    try Data([1]).write(to: destination)
                    return destination
                }
            )
        }
        await gate.waitUntilHeld()

        let erasure = Task {
            await FocusEndAlarmMaintenance.eraseForCompleteDataDeletion(
                scheduler: scheduler,
                libraryDirectory: library
            )
        }
        var turns = 0
        while AlarmSoundLibrary.preparationGeneration == generation, turns < 10_000 {
            turns += 1
            await Task.yield()
        }
        XCTAssertNotEqual(AlarmSoundLibrary.preparationGeneration, generation)

        await gate.release()
        await erasure.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        do {
            _ = try await preparation.value
            XCTFail("A prepared file from before complete deletion must be invalidated")
        } catch is CancellationError {
            // The caller cannot book the file after deletion.
        }
    }

    func testPreparationQueuedBeforeDeletionCannotWriteAfterward() async throws {
        let staleGeneration = AlarmSoundLibrary.preparationGeneration
        await FocusEndAlarmMaintenance.eraseForCompleteDataDeletion(
            scheduler: scheduler,
            libraryDirectory: library
        )
        let sounds = try AlarmSoundLibrary.soundsDirectory(libraryDirectory: library)
        let destination = sounds.appendingPathComponent(AlarmSoundLibrary.fileName(for: .bell))
        do {
            _ = try await AlarmSoundLibrary.preparedFile(
                .ringtone,
                for: .bell,
                libraryDirectory: library,
                generation: staleGeneration,
                prepareFile: {
                    try Data([1]).write(to: destination)
                    return destination
                }
            )
            XCTFail("A queued pre-deletion preparation must be rejected")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    // MARK: Device-local preferences

    func testUITestsStartFromTheDefaultStrengthAndSound() throws {
        let preferences = AlarmPreferences(defaults: defaults)
        preferences.setStrength(.gentle)
        preferences.select(.marimba)
        AlarmPreferences.startUITestProcessFromItsDefault(defaults: defaults, environment: [:])
        XCTAssertEqual(preferences.strength, .gentle, "An ordinary Debug launch keeps the choice")
        AlarmPreferences.startUITestProcessFromItsDefault(
            defaults: defaults,
            environment: [
                LocalPreviewLaunchPolicy.uiTestEnvironmentKey: "1",
                LocalPreviewLaunchPolicy.environmentKey: "1"
            ]
        )
        XCTAssertEqual(preferences.strength, .standard)
        XCTAssertNil(preferences.storedSound)
    }

    func testTheUITestAlarmClientAnswersItsOwnPrompt() async {
        let denied = UITestFocusEndAlarmClient(environment: [:])
        XCTAssertEqual(denied.authorization, .notDetermined)
        let answer = await denied.requestAuthorization()
        XCTAssertEqual(answer, .denied)
        XCTAssertEqual(denied.authorization, .denied)
        let granted = UITestFocusEndAlarmClient(environment: [UITestFocusEndAlarmClient.environmentKey: "granted"])
        let grantedAnswer = await granted.requestAuthorization()
        XCTAssertEqual(grantedAnswer, .authorized)
        XCTAssertEqual(
            UITestFocusEndAlarmClient(environment: [UITestFocusEndAlarmClient.environmentKey: "unsupported"]).authorization,
            .unsupported
        )
    }
}

private actor HeldRenderedSoundWrite {
    private var didStart = false
    private var waiter: CheckedContinuation<Void, Never>?

    func waitToWrite() async {
        didStart = true
        await withCheckedContinuation { waiter = $0 }
    }

    func waitUntilHeld() async {
        var turns = 0
        while !didStart, turns < 10_000 {
            turns += 1
            await Task.yield()
        }
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}
