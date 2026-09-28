import XCTest
@testable import PomoGem

/// F5 part 1: HOW the in-app alarm rings, per strength. Whether it rings is
/// the timer screens' decision and is not exercised here.
@MainActor
final class TimerCompletionAlarmPlaybackTests: XCTestCase {
    private var gate: AlarmSleepGate!
    private var player: RecordingAlarmPlayer!
    private var uptime: TimeInterval = 1_000
    private var isActive = true

    override func setUp() async throws {
        try await super.setUp()
        gate = AlarmSleepGate()
        player = RecordingAlarmPlayer()
        uptime = 1_000
        isActive = true
    }

    private func makeController(
        strength: AlarmStrength,
        sound: AlarmSoundChoice? = .bell
    ) -> TimerCompletionAlertController {
        let gate = self.gate!
        return TimerCompletionAlertController(
            sleeper: { try await gate.sleep() },
            player: player,
            planner: { configuration, cue in
                TimerCompletionAlarmRequest.resolve(
                    configuration: configuration,
                    cue: cue,
                    strength: strength,
                    sound: configuration.sound == nil ? nil : sound
                )
            },
            applicationIsActive: { [unowned self] in self.isActive },
            uptime: { [unowned self] in self.uptime }
        )
    }

    private func configuration(
        sound: TimerCompletionSound? = .standard,
        haptic: TimerCompletionHaptic? = .standard
    ) -> TimerCompletionAlertConfiguration {
        TimerCompletionAlertConfiguration(sessionID: UUID(), sound: sound, haptic: haptic)
    }

    private func tick() async {
        await gate.waitForSleep()
        await gate.resumeNext()
        await gate.waitForSleep()
    }

    // MARK: Standard and maximum: a loop that stops by itself

    func testTheStandardPresetLoopsAndKeepsTheScreenAwakeWhileRinging() async {
        let controller = makeController(strength: .standard)
        let alarm = configuration()
        controller.start(alarm)

        XCTAssertEqual(player.events, [.sustain(.bell)])
        let request = try? XCTUnwrap(controller.activeRequest)
        XCTAssertEqual(request?.plan.playback, .loop)
        XCTAssertEqual(request?.plan.audioSession, .ambient, "Standard follows the silent switch")
        XCTAssertEqual(request?.plan.haptic?.loopDuration, 1.5, "A continuous vibration loops")
        XCTAssertTrue(controller.isRinging(sessionID: alarm.sessionID))
        XCTAssertTrue(controller.keepsScreenAwake(sessionID: alarm.sessionID))
        XCTAssertFalse(controller.keepsScreenAwake(sessionID: UUID()))

        // Every cycle keeps the loop going; a loop the system stopped comes back.
        await tick()
        await tick()
        XCTAssertEqual(player.events, [.sustain(.bell), .sustain(.bell), .sustain(.bell)])
        controller.stop(sessionID: alarm.sessionID)
        XCTAssertEqual(player.events.last, .stop)
        XCTAssertFalse(controller.keepsScreenAwake(sessionID: alarm.sessionID))
    }

    func testTheRingingAlarmHoldsTheScreenOnlyWhileTheSceneIsActive() {
        typealias Policy = TimerCompletionAlarmScreenAwakePolicy
        XCTAssertTrue(Policy.shouldKeepScreenAwake(
            runningTimerKeepsScreenAwake: false, sceneIsActive: true, alarmKeepsScreenAwake: true
        ), "Whatever the keep-awake preference, a ringing alarm holds the display")
        XCTAssertFalse(Policy.shouldKeepScreenAwake(
            runningTimerKeepsScreenAwake: false, sceneIsActive: false, alarmKeepsScreenAwake: true
        ))
        XCTAssertFalse(Policy.shouldKeepScreenAwake(
            runningTimerKeepsScreenAwake: false, sceneIsActive: true, alarmKeepsScreenAwake: false
        ), "Gentle, or quiet after the automatic stop")
        XCTAssertTrue(Policy.shouldKeepScreenAwake(
            runningTimerKeepsScreenAwake: true, sceneIsActive: true, alarmKeepsScreenAwake: false
        ), "The running timer's own rule is unchanged")
    }

    func testAfterThreeMinutesItGoesQuietButKeepsItsStopControl() async {
        let controller = makeController(strength: .standard)
        let alarm = configuration()
        controller.start(alarm)
        await tick()

        uptime += AlarmStrength.automaticStopDuration - 1
        await tick()
        XCTAssertTrue(controller.isRinging(sessionID: alarm.sessionID), "Not yet")

        uptime += 1
        await gate.waitForSleep()
        await gate.resumeNext()
        await waitUntil { controller.isSilenced }
        XCTAssertTrue(controller.isActive(sessionID: alarm.sessionID), "The Stop control stays")
        XCTAssertTrue(controller.isSilenced)
        XCTAssertFalse(controller.isRinging(sessionID: alarm.sessionID))
        XCTAssertFalse(
            controller.keepsScreenAwake(sessionID: alarm.sessionID),
            "Released: a later auto-lock counts as Stop"
        )
        XCTAssertEqual(player.events.last, .stop)
        let pending = await gate.pendingCount
        XCTAssertEqual(pending, 0, "Nothing rings after the automatic stop")

        // Leaving afterwards is still recorded as Stop.
        let suite = "alarm-quiet-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        controller.acknowledgeOnLeavingApp(defaults: defaults)
        XCTAssertTrue(TimerCompletionAlertAcknowledgementStore.contains(
            sessionID: alarm.sessionID, defaults: defaults
        ))
        XCTAssertFalse(controller.isActive(sessionID: alarm.sessionID))
    }

    func testTheMaximumPresetPlaysThroughTheSilentSwitchOnlyWithSoundOn() {
        let loud = makeController(strength: .maximum)
        loud.start(configuration())
        XCTAssertEqual(loud.activeRequest?.plan.audioSession, .playbackDuckingOthers)
        XCTAssertEqual(loud.activeRequest?.plan.haptic?.loopDuration, 1.4)
        loud.stop()

        let hapticOnly = makeController(strength: .maximum)
        hapticOnly.start(configuration(sound: nil))
        XCTAssertEqual(hapticOnly.activeRequest?.plan.audioSession, .ambient)
        XCTAssertNil(hapticOnly.activeRequest?.sound)
        XCTAssertFalse(hapticOnly.activeRequest?.plan.playsSound ?? true)
        hapticOnly.stop()
    }

    func testHapticsOffMeansNoVibrationAndSoundOffNoSound() {
        let controller = makeController(strength: .standard)
        controller.start(configuration(haptic: nil))
        XCTAssertNil(controller.activeRequest?.plan.haptic)
        XCTAssertFalse(controller.activeRequest?.plan.playsHaptics ?? true)
        XCTAssertEqual(controller.activeRequest?.sound, .bell)
        controller.stop()

        controller.start(configuration(sound: nil))
        XCTAssertNil(controller.activeRequest?.sound)
        XCTAssertTrue(controller.activeRequest?.plan.playsHaptics ?? false)
        controller.stop()
    }

    func testAnInactiveSceneSilencesTheLoopUntilTheAppIsActiveAgain() async {
        let controller = makeController(strength: .standard)
        let alarm = configuration()
        controller.start(alarm)
        isActive = false
        await tick()
        await tick()
        XCTAssertEqual(player.events, [.sustain(.bell), .stop], "Stopped once, not every cycle")
        XCTAssertTrue(controller.isRinging(sessionID: alarm.sessionID), "Still the same alarm")

        isActive = true
        await tick()
        XCTAssertEqual(player.events, [.sustain(.bell), .stop, .sustain(.bell)])
        controller.stop()
    }

    // MARK: Gentle: today's repeat

    func testTheGentlePresetRepeatsTheShortCueWithoutALimitOrTheScreen() async {
        let controller = makeController(strength: .gentle)
        let alarm = configuration()
        controller.start(alarm)
        XCTAssertEqual(controller.activeRequest?.plan.playback, .repeating(interval: 1.3))
        XCTAssertFalse(controller.keepsScreenAwake(sessionID: alarm.sessionID))
        XCTAssertNil(controller.activeRequest?.plan.automaticStopInterval)

        uptime += 3_600
        await tick()
        XCTAssertEqual(player.events, [.cue(.bell), .cue(.bell)])
        XCTAssertTrue(controller.isRinging(sessionID: alarm.sessionID), "Gentle never stops by itself")
        controller.stop()
    }

    // MARK: The single cue and restoring

    func testASingleCueNeverLoopsOrHoldsTheScreen() async {
        let controller = makeController(strength: .maximum)
        controller.playOnce(configuration())
        XCTAssertEqual(player.events, [.cue(.bell)])
        XCTAssertEqual(player.requests.last?.plan.playback, .once)
        XCTAssertEqual(player.requests.last?.plan.keepsScreenAwake, false)
        XCTAssertEqual(player.requests.last?.plan.audioSession, .playbackDuckingOthers)
        await settle()
        let pending = await gate.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testARestoredAlarmKeepsItsOriginalStopTimeAndQuietState() async {
        let controller = makeController(strength: .standard)
        let alarm = configuration()
        controller.start(alarm)
        uptime += 100
        controller.suspendForContainerRetirement()
        XCTAssertTrue(controller.resumeSuspendedAlert(sessionID: alarm.sessionID))
        uptime += AlarmStrength.automaticStopDuration - 100
        // The suspended loop's sleep, then the restored one's.
        await gate.waitForSleeps(count: 2)
        await gate.resumeNext()
        await gate.resumeNext()
        await waitUntil { controller.isSilenced }
        XCTAssertTrue(controller.isSilenced, "Three minutes from the end, not from the remount")

        controller.suspendForContainerRetirement()
        let before = player.events.count
        XCTAssertTrue(controller.resumeSuspendedAlert(sessionID: alarm.sessionID))
        XCTAssertTrue(controller.isActive(sessionID: alarm.sessionID))
        XCTAssertTrue(controller.isSilenced, "An alarm that had gone quiet comes back quiet")
        XCTAssertFalse(player.events[before...].contains(.sustain(.bell)))
        controller.stop()
    }

    /// Suspended at 2:59 by an account check that took longer than the
    /// second left: the restored alarm is already past its automatic stop,
    /// so it must come back quiet instead of sounding for another cycle.
    func testAnAlarmRestoredAfterItsAutomaticStopComesBackQuiet() async {
        let controller = makeController(strength: .maximum)
        let alarm = configuration()
        controller.start(alarm)
        uptime += AlarmStrength.automaticStopDuration - 1
        controller.suspendForContainerRetirement()
        uptime += 5
        let before = player.events.count

        XCTAssertTrue(controller.resumeSuspendedAlert(sessionID: alarm.sessionID))
        XCTAssertTrue(controller.isActive(sessionID: alarm.sessionID), "The Stop control stays")
        XCTAssertTrue(controller.isSilenced)
        XCTAssertFalse(controller.keepsScreenAwake(sessionID: alarm.sessionID))
        XCTAssertFalse(player.events[before...].contains(.sustain(.bell)), "Not one more cycle")
        controller.stop()
    }

    func testAnAlarmRestoredBeforeItsAutomaticStopRingsAtOnce() {
        let controller = makeController(strength: .standard)
        let alarm = configuration()
        controller.start(alarm)
        uptime += 60
        controller.suspendForContainerRetirement()
        let before = player.events.count
        XCTAssertTrue(controller.resumeSuspendedAlert(sessionID: alarm.sessionID))
        XCTAssertFalse(controller.isSilenced)
        XCTAssertEqual(Array(player.events[before...]), [.sustain(.bell)])
        controller.stop()
    }

    func testClosureControllersKeepTodaysGentleBehaviour() {
        let played = PlayedConfigurations()
        let controller = TimerCompletionAlertController(
            sleeper: { try await Task.sleep(for: .seconds(60)) },
            playback: { played.values.append($0) },
            stopPlayback: {},
            applicationIsActive: { true }
        )
        let alarm = configuration(sound: .soft)
        controller.start(alarm)
        XCTAssertEqual(played.values, [alarm])
        XCTAssertEqual(controller.activeRequest?.strength, .gentle)
        XCTAssertEqual(controller.activeRequest?.sound, .soft)
        XCTAssertFalse(controller.keepsScreenAwake(sessionID: alarm.sessionID))
        controller.stop()
    }

    // MARK: The Settings preview

    /// 「3秒後に試す」 must let people who miss alarms feel what 標準 and
    /// 最大 play: the loop and the continuous vibration, bounded.
    func testThePreviewPlaysTheStrengthsLoopForAFewSecondsThenStops() async {
        let sleeps = PreviewSleeps()
        let preview = TimerCompletionAlarmPreview(player: player) { try await sleeps.sleep($0) }
        for strength in [AlarmStrength.standard, .maximum] {
            let before = player.events.count
            let request = TimerCompletionAlarmRequest.resolve(
                configuration: configuration(), cue: .repeating, strength: strength, sound: .bell
            )
            preview.play(request)
            XCTAssertEqual(Array(player.events[before...]), [.sustain(.bell)], "\(strength)")
            XCTAssertEqual(player.requests.last?.plan.haptic?.loopDuration, request.plan.haptic?.loopDuration)
            XCTAssertNotNil(request.plan.haptic?.loopDuration, "the continuous vibration, not the taps")
            XCTAssertTrue(preview.isLooping)
            await sleeps.waitForSleep()
            XCTAssertEqual(sleeps.durations.last, TimerCompletionAlarmPreview.loopDuration)
            sleeps.resume()
            await waitUntil { !preview.isLooping }
            XCTAssertEqual(Array(player.events[before...]), [.sustain(.bell), .stop], "\(strength)")
        }

        let before = player.events.count
        preview.play(TimerCompletionAlarmRequest.resolve(
            configuration: configuration(), cue: .repeating, strength: .gentle, sound: .soft
        ))
        XCTAssertEqual(Array(player.events[before...]), [.cue(.soft)], "控えめ: one cue, as before")
        XCTAssertFalse(preview.isLooping)
    }

    func testCancellingThePreviewStopsTheLoopAtOnce() async {
        let sleeps = PreviewSleeps()
        let preview = TimerCompletionAlarmPreview(player: player) { try await sleeps.sleep($0) }
        preview.play(TimerCompletionAlarmRequest.resolve(
            configuration: configuration(), cue: .repeating, strength: .maximum, sound: .digital
        ))
        await sleeps.waitForSleep()
        preview.cancel()
        XCTAssertEqual(player.events, [.sustain(.digital), .stop])
        sleeps.resume()
        await settle()
        XCTAssertEqual(player.events, [.sustain(.digital), .stop], "one stop only")
        preview.cancel()
        XCTAssertEqual(player.events.count, 2, "nothing to stop")
    }

    // MARK: Resolution

    func testTheLiveRequestUsesThisIPhonesStrengthAndSound() throws {
        let suite = "alarm-request-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AlarmPreferences(defaults: defaults)
        let alarm = configuration(sound: .bright)

        let fresh = TimerCompletionAlarmRequest.live(alarm, .repeating, preferences: preferences)
        XCTAssertEqual(fresh.strength, .standard, "The owner's default")
        XCTAssertEqual(fresh.sound, .bright, "Without a device choice: the synced chime")
        XCTAssertEqual(fresh.plan.playback, .loop)

        preferences.select(.alarmClock)
        preferences.setStrength(.maximum)
        let chosen = TimerCompletionAlarmRequest.live(alarm, .repeating, preferences: preferences)
        XCTAssertEqual(chosen.sound, .alarmClock)
        XCTAssertEqual(chosen.plan.audioSession, .playbackDuckingOthers)

        let muted = TimerCompletionAlarmRequest.live(configuration(sound: nil), .repeating, preferences: preferences)
        XCTAssertNil(muted.sound, "Sound off plays no sound, whatever was chosen")
        XCTAssertEqual(muted.plan.audioSession, .ambient)
    }

    /// A few turns of the main actor, for an assertion that nothing more
    /// happens (a negative cannot be polled).
    private func settle() async {
        for _ in 0 ..< 20 { await Task.yield() }
    }

    /// Yields until `condition` holds (bounded), for an assertion that
    /// something happened: the resumed loop hops off and back onto the main
    /// actor, which may take more than a few turns on a loaded machine.
    private func waitUntil(_ condition: () -> Bool) async {
        var turns = 0
        while !condition(), turns < 10_000 {
            turns += 1
            await Task.yield()
        }
    }
}

@MainActor
private final class RecordingAlarmPlayer: TimerCompletionAlarmPlayer {
    enum Event: Equatable {
        case cue(AlarmSoundChoice?)
        case sustain(AlarmSoundChoice?)
        case stop
    }

    private(set) var events: [Event] = []
    private(set) var requests: [TimerCompletionAlarmRequest] = []

    func playCue(_ request: TimerCompletionAlarmRequest) {
        requests.append(request)
        events.append(.cue(request.sound))
    }

    func sustainLoop(_ request: TimerCompletionAlarmRequest) {
        requests.append(request)
        events.append(.sustain(request.sound))
    }

    func stop() {
        events.append(.stop)
    }
}

private actor AlarmSleepGate {
    private var continuations: [CheckedContinuation<Void, Error>] = []

    var pendingCount: Int { continuations.count }

    func sleep() async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func waitForSleep() async {
        await waitForSleeps(count: 1)
    }

    func waitForSleeps(count: Int) async {
        for _ in 0 ..< 1_000 where continuations.count < count {
            await Task.yield()
        }
    }
}

@MainActor
private final class PlayedConfigurations {
    var values: [TimerCompletionAlertConfiguration] = []
}

@MainActor
private final class PreviewSleeps {
    private(set) var durations: [TimeInterval] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: TimeInterval) async throws {
        durations.append(duration)
        await withCheckedContinuation { waiting.append($0) }
    }

    func waitForSleep() async {
        var turns = 0
        while waiting.isEmpty, turns < 10_000 {
            turns += 1
            await Task.yield()
        }
    }

    func resume() {
        let continuations = waiting
        waiting.removeAll()
        continuations.forEach { $0.resume() }
    }
}
