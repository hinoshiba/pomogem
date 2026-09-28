import AVFoundation
import XCTest
@testable import PomoGem

/// jar-03: the audio hardware is driven only from SoundSynth's serial queue,
/// the engine is warmed before a gem lands, and it stays warm for the jar's
/// interaction window instead of stopping 0.12 s after every sound.
@MainActor
final class SoundSynthOutputTests: XCTestCase {
    func testSoundsNeverTouchTheAudioHardwareOnTheMainThread() {
        let fixture = Fixture()

        // With the audio queue held by a blocked item, the main thread's
        // calls return without having touched the output at all.
        let gate = DispatchSemaphore(value: 0)
        fixture.queue.async { gate.wait() }
        fixture.synth.playThud(impactSpeed: 4)
        fixture.synth.playTimerCompletion(.standard)
        fixture.synth.stopTimerCompletion()
        fixture.synth.prewarm()
        XCTAssertEqual(fixture.output.calls.map(\.description), [])
        gate.signal()
        fixture.drain()

        let calls = fixture.output.calls
        XCTAssertFalse(calls.isEmpty)
        XCTAssertTrue(
            calls.allSatisfy { !$0.onMainThread },
            "Every hardware call must run on the audio queue: \(calls)"
        )
        XCTAssertEqual(calls.first?.name, "ensureRunning")
        XCTAssertTrue(calls.contains { $0.name == "play(voice: 0)" })
        XCTAssertTrue(calls.contains { $0.name == "playTimerCompletion" })
        XCTAssertTrue(calls.contains { $0.name == "stopTimerCompletion" })
    }

    func testAColdStartPlaysTheWaitingSoundBeforePrimingTheOtherVoices() {
        let fixture = Fixture()
        fixture.output.nextStart = .started

        fixture.synth.playThud(impactSpeed: 4)
        fixture.drain()

        let names = fixture.output.calls.map(\.name)
        XCTAssertEqual(Array(names.prefix(2)), ["ensureRunning", "play(voice: 0)"])
        XCTAssertEqual(
            names.filter { $0 == "primeOneIdleVoice" }.count,
            fixture.output.voicesToPrime,
            "Priming continues one node at a time until none is left"
        )
    }

    func testPrewarmStartsTheEngineWithoutPlayingAnything() {
        let fixture = Fixture()

        fixture.synth.prewarm()
        fixture.drain()

        XCTAssertEqual(fixture.output.calls.map(\.name), ["ensureRunning"])
    }

    func testTheEngineOutlivesTheSoundByTheLingerThenReleasesTheSession() throws {
        let checks = ManualIdleChecks()
        let fixture = Fixture(idleLinger: 0.4, idleChecks: checks)

        fixture.synth.playThud(impactSpeed: 4)
        fixture.drain()
        let check = try XCTUnwrap(checks.pending.first)
        XCTAssertGreaterThanOrEqual(
            check.delay,
            0.4,
            "The old 0.12 s grace stopped the engine between every tap"
        )
        XCTAssertFalse(fixture.output.calls.contains { $0.name.hasPrefix("stop(") })

        // The check stops the engine once the thud has finished playing. A
        // check that comes due while it still plays waits for it, so firing
        // late never fails this test; only a check that never stops does.
        for _ in 0 ..< 40 where fixture.output.calls.last?.name.hasPrefix("stop(") != true {
            fixture.wait(seconds: 0.05)
            checks.fireAll()
            fixture.drain()
        }
        XCTAssertEqual(
            fixture.output.calls.last?.name,
            "stop(deactivatingSession: true)"
        )
    }

    func testTheLingerCoversTheJarInteractionWindow() {
        XCTAssertGreaterThanOrEqual(SoundSynth.idleLinger, Constants.Jar.idleWindow)
        XCTAssertLessThanOrEqual(SoundSynth.idleLinger, 5)
    }

    func testANewSoundKeepsTheEngineAlive() {
        let checks = ManualIdleChecks()
        let fixture = Fixture(idleLinger: 0.4, idleChecks: checks)

        fixture.synth.prewarm()
        fixture.synth.playThud(impactSpeed: 4)
        XCTAssertEqual(checks.pending.count, 2)

        // The prewarm's check comes due first. The thud superseded it, so it
        // neither stops the engine nor schedules another check.
        checks.fire(at: 0)
        fixture.drain()
        XCTAssertFalse(fixture.output.calls.contains { $0.name.hasPrefix("stop(") })
        XCTAssertEqual(checks.pending.count, 1, "Only the thud's own check is left")
    }

    // MARK: - JarScene hook and session contract

    /// The hook itself (jar-03): queuing a gem warms the audio before the gem
    /// can land, and restoring the jar, which lands silently, warms nothing.
    func testQueuingAGemWarmsTheAudioAndRestoringTheJarDoesNot() {
        let fixture = Fixture()
        let scene = JarScene(soundSynth: fixture.synth)

        scene.restore(pebbles: gems(count: Constants.Jar.maxPhysicsBodies + 5))
        fixture.drain()
        XCTAssertEqual(
            fixture.output.calls.map(\.name),
            [],
            "Restoring, including its overflow queue, plays nothing and warms nothing"
        )

        scene.dropFromAbove(gems(count: 1)[0])
        fixture.drain()
        XCTAssertEqual(
            fixture.output.calls.map(\.name),
            ["ensureRunning"],
            "The engine starts while the gem is queued, before any landing"
        )
    }

    func testTheCompletionDropWarmsTheAudioBeforeItsChime() {
        let fixture = Fixture()
        let scene = JarScene(soundSynth: fixture.synth)

        scene.performCompletionDrop(gems(count: 1)[0])
        fixture.drain()

        let names = fixture.output.calls.map(\.name)
        XCTAssertEqual(names.first, "ensureRunning")
        XCTAssertTrue(names.contains { $0.hasPrefix("play(") }, "\(names)")
    }

    /// Our sounds mix with the person's music, obey the Ring/Silent switch
    /// and never ask for background audio (AppStore review notes).
    func testTheAudioSessionIsAmbientWithNoOptions() {
        XCTAssertEqual(AVSoundSynthOutput.sessionCategory, .ambient)
        XCTAssertEqual(AVSoundSynthOutput.sessionMode, .default)
        XCTAssertEqual(AVSoundSynthOutput.sessionCategoryOptions, [])
    }

    // MARK: - F5 alarm loop and session

    func testTheStandardLoopPlaysSeamlesslyAndStaysAmbient() async {
        let fixture = Fixture()
        await fixture.synth.prepareAlarmSoundAndWait(.bell)
        fixture.synth.sustainTimerCompletionLoop(.bell, session: .ambient)
        fixture.synth.sustainTimerCompletionLoop(.bell, session: .ambient)
        fixture.drain()
        XCTAssertEqual(
            fixture.output.calls.map(\.name),
            ["ensureRunning", "playTimerCompletionLoop"],
            "One loop, however often a cycle asks; no session switch for .ambient"
        )
        XCTAssertTrue(fixture.synth.isTimerCompletionLoopRequested)
        XCTAssertTrue(fixture.output.calls.allSatisfy { !$0.onMainThread })

        fixture.synth.stopTimerCompletion()
        fixture.drain()
        XCTAssertEqual(fixture.output.calls.last?.name, "stopTimerCompletion")
        XCTAssertFalse(fixture.synth.isTimerCompletionLoopRequested)
        XCTAssertEqual(fixture.synth.currentAlarmSessionMode, .ambient)
    }

    func testTheMaximumLoopOverridesTheSilentSwitchAndGivesTheMusicBack() async {
        let fixture = Fixture()
        await fixture.synth.prepareAlarmSoundAndWait(.digital)
        fixture.synth.sustainTimerCompletionLoop(.digital, session: .playbackDuckingOthers)
        fixture.drain()
        XCTAssertEqual(fixture.output.calls.map(\.name), [
            "useSessionMode(playbackDuckingOthers)",
            "ensureRunning",
            "playTimerCompletionLoop"
        ], "The category changes before the engine starts, so ducking starts with it")
        XCTAssertEqual(fixture.synth.currentAlarmSessionMode, .playbackDuckingOthers)

        fixture.synth.stopTimerCompletion()
        fixture.drain()
        XCTAssertEqual(Array(fixture.output.calls.map(\.name).suffix(2)), [
            "stop(deactivatingSession: true)",
            "useSessionMode(ambient)"
        ], "Released at once with notifyOthersOnDeactivation, then back to .ambient")
        XCTAssertEqual(fixture.synth.currentAlarmSessionMode, .ambient)

        // The next jar sound plays .ambient without another switch.
        fixture.synth.playThud(impactSpeed: 4)
        fixture.drain()
        XCTAssertEqual(
            fixture.output.calls.filter { $0.name.hasPrefix("useSessionMode") }.count,
            2
        )
    }

    func testTheSessionConfigurationsArePinned() {
        let ambient = AVSoundSynthOutput.sessionConfiguration(for: .ambient)
        XCTAssertEqual(ambient.category, .ambient)
        XCTAssertEqual(ambient.options, [])
        let maximum = AVSoundSynthOutput.sessionConfiguration(for: .playbackDuckingOthers)
        XCTAssertEqual(maximum.category, .playback, "Plays with the Ring/Silent switch on")
        XCTAssertTrue(maximum.options.contains(.duckOthers), "Music is lowered")
        XCTAssertTrue(maximum.options.contains(.mixWithOthers), "Music is never stopped")
        XCTAssertFalse(maximum.options.contains(.defaultToSpeaker))
    }

    /// Both sustain calls are idempotent, so without `.loops` the standard
    /// and maximum presets would play one cycle and go quiet while the
    /// screen stays on for three minutes.
    func testTheAlarmBufferLoops() {
        XCTAssertTrue(AVSoundSynthOutput.alarmLoopBufferOptions.contains(.loops))
        XCTAssertTrue(AVSoundSynthOutput.alarmLoopBufferOptions.contains(.interrupts))
    }

    func testTheHapticLoopUsesALoopingAdvancedPlayer() throws {
        for strength in [AlarmStrength.standard, .maximum] {
            let pattern = AlarmHapticPattern.completion(strength: strength, style: .standard)
            let loopDuration = try XCTUnwrap(pattern.loopDuration)
            let cue = try XCTUnwrap(Haptics.timerCompletionLoopCue(pattern))
            XCTAssertEqual(cue.playerConfiguration, .advanced(loopEnd: loopDuration), "\(strength)")
        }
        let gentle = AlarmHapticPattern.completion(strength: .gentle, style: .standard)
        XCTAssertNil(Haptics.timerCompletionLoopCue(gentle), "控えめ never loops")
    }

    // MARK: - F5 the production player

    private func request(
        strength: AlarmStrength,
        cue: TimerCompletionForegroundFeedbackPolicy.Cue
    ) -> TimerCompletionAlarmRequest {
        TimerCompletionAlarmRequest.resolve(
            configuration: TimerCompletionAlertConfiguration(sessionID: UUID(), sound: .standard, haptic: nil),
            cue: cue,
            strength: strength,
            sound: .bell
        )
    }

    /// Stop must give the session back: after a silent-switch override
    /// the person's music would otherwise stay ducked.
    func testTheLivePlayerOverridesTheSilentSwitchAtMaximumAndStopGivesTheMusicBack() async {
        let fixture = Fixture()
        await fixture.synth.prepareAlarmSoundAndWait(.bell)
        let player = LiveTimerCompletionAlarmPlayer(sound: fixture.synth)
        let maximum = request(strength: .maximum, cue: .repeating)
        XCTAssertEqual(maximum.plan.audioSession, .playbackDuckingOthers)

        player.sustainLoop(maximum)
        fixture.drain()
        XCTAssertEqual(fixture.output.calls.map(\.name), [
            "useSessionMode(playbackDuckingOthers)",
            "ensureRunning",
            "playTimerCompletionLoop"
        ])
        XCTAssertTrue(fixture.synth.isTimerCompletionLoopRequested)

        player.stop()
        fixture.drain()
        XCTAssertEqual(Array(fixture.output.calls.map(\.name).suffix(2)), [
            "stop(deactivatingSession: true)",
            "useSessionMode(ambient)"
        ])
        XCTAssertFalse(fixture.synth.isTimerCompletionLoopRequested)
        XCTAssertEqual(fixture.synth.currentAlarmSessionMode, .ambient)
    }

    func testTheLivePlayerKeepsTheStandardLoopAmbient() async {
        let fixture = Fixture()
        await fixture.synth.prepareAlarmSoundAndWait(.bell)
        let player = LiveTimerCompletionAlarmPlayer(sound: fixture.synth)
        player.sustainLoop(request(strength: .standard, cue: .repeating))
        fixture.drain()
        player.stop()
        fixture.drain()
        XCTAssertFalse(fixture.output.calls.contains { $0.name.hasPrefix("useSessionMode") })
        XCTAssertEqual(fixture.output.calls.last?.name, "stopTimerCompletion")
    }

    /// The single cue at 最大 (a return shortly after the end, and the
    /// Settings preview) ducks the music too. Only its idle shutdown gives
    /// the music back, so it must release the session and return to
    /// `.ambient`.
    func testASingleCueAtMaximumReleasesTheSessionAfterItPlays() async throws {
        let checks = ManualIdleChecks()
        let fixture = Fixture(idleLinger: 0.4, idleChecks: checks)
        await fixture.synth.prepareAlarmSoundAndWait(.bell)
        let player = LiveTimerCompletionAlarmPlayer(sound: fixture.synth)
        player.playCue(request(strength: .maximum, cue: .single))
        fixture.drain()
        XCTAssertEqual(fixture.output.calls.map(\.name), [
            "useSessionMode(playbackDuckingOthers)",
            "ensureRunning",
            "playTimerCompletion"
        ])
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(checks.pending.last).delay,
            1.0 + 0.25 + 0.01,
            "The cue, then a short linger: ducking lasts no longer than it must"
        )
        for _ in 0 ..< 80 where fixture.output.calls.last?.name != "useSessionMode(ambient)" {
            fixture.wait(seconds: 0.05)
            checks.fireAll()
            fixture.drain()
        }
        XCTAssertEqual(Array(fixture.output.calls.map(\.name).suffix(2)), [
            "stop(deactivatingSession: true)",
            "useSessionMode(ambient)"
        ])
        XCTAssertEqual(fixture.synth.currentAlarmSessionMode, .ambient)
    }

    func testALoopKeepsTheEngineUntilItStopsThenLingersAsUsual() async throws {
        let checks = ManualIdleChecks()
        let fixture = Fixture(idleLinger: 0.4, idleChecks: checks)
        await fixture.synth.prepareAlarmSoundAndWait(.marimba)
        fixture.synth.playThud(impactSpeed: 4)
        fixture.synth.sustainTimerCompletionLoop(.marimba, session: .ambient)
        fixture.drain()
        for _ in 0 ..< 5 {
            fixture.wait(seconds: 0.05)
            checks.fireAll()
            fixture.drain()
        }
        XCTAssertFalse(
            fixture.output.calls.contains { $0.name.hasPrefix("stop(") },
            "An idle check never stops a looping alarm"
        )

        fixture.synth.stopTimerCompletion()
        let check = try XCTUnwrap(checks.pending.last)
        XCTAssertGreaterThanOrEqual(check.delay, 0.4, "Back to the ordinary linger (#41)")
    }

    func testLeavingForgetsTheLoopSoTheNextCycleRestartsIt() async {
        let fixture = Fixture()
        await fixture.synth.prepareAlarmSoundAndWait(.bell)
        fixture.synth.sustainTimerCompletionLoop(.bell, session: .playbackDuckingOthers)
        fixture.synth.applicationWillResignActive()
        XCTAssertFalse(fixture.synth.isTimerCompletionLoopRequested)
        XCTAssertEqual(fixture.synth.currentAlarmSessionMode, .ambient)
        fixture.synth.sustainTimerCompletionLoop(.bell, session: .playbackDuckingOthers)
        XCTAssertFalse(fixture.synth.isTimerCompletionLoopRequested, "Nothing starts while inactive")

        fixture.synth.applicationDidBecomeActive()
        fixture.synth.sustainTimerCompletionLoop(.bell, session: .playbackDuckingOthers)
        fixture.drain()
        XCTAssertTrue(fixture.synth.isTimerCompletionLoopRequested)
        XCTAssertEqual(
            fixture.output.calls.filter { $0.name == "playTimerCompletionLoop" }.count,
            2
        )
    }

    func testAnAlarmWaitingForItsSoundStartsWhenTheRenderingIsDone() async {
        let fixture = Fixture()
        XCTAssertFalse(fixture.synth.hasPreparedAlarmSound(.schoolChime))
        fixture.synth.sustainTimerCompletionLoop(.schoolChime, session: .ambient)
        XCTAssertFalse(fixture.synth.isTimerCompletionLoopRequested)
        await fixture.synth.prepareAlarmSoundAndWait(.schoolChime)
        fixture.drain()
        XCTAssertTrue(fixture.synth.isTimerCompletionLoopRequested)
        XCTAssertTrue(fixture.output.calls.contains { $0.name == "playTimerCompletionLoop" })

        // A stop while rendering drops the request.
        fixture.synth.stopTimerCompletion()
        fixture.synth.sustainTimerCompletionLoop(.alarmClock, session: .ambient)
        fixture.synth.stopTimerCompletion()
        await fixture.synth.prepareAlarmSoundAndWait(.alarmClock)
        XCTAssertFalse(fixture.synth.isTimerCompletionLoopRequested)
    }

    func testACueIsNotCutOffByTheNextCycleButAPreviewIs() async {
        let fixture = Fixture()
        await fixture.synth.prepareAlarmSoundAndWait(.digital)
        fixture.synth.playTimerCompletionCue(.digital, session: .ambient)
        fixture.synth.playTimerCompletionCue(.digital, session: .ambient)
        fixture.drain()
        XCTAssertEqual(fixture.output.calls.filter { $0.name == "playTimerCompletion" }.count, 1)

        fixture.synth.playAlarmPreview(.digital, session: .ambient)
        fixture.drain()
        XCTAssertEqual(fixture.output.calls.filter { $0.name == "playTimerCompletion" }.count, 2)
    }

    func testSoundOffPlaysNoAlarm() async {
        let fixture = Fixture()
        await fixture.synth.prepareAlarmSoundAndWait(.bell)
        fixture.synth.isEnabled = false
        fixture.synth.sustainTimerCompletionLoop(.bell, session: .playbackDuckingOthers)
        fixture.synth.playTimerCompletionCue(.bell, session: .ambient)
        fixture.drain()
        XCTAssertEqual(fixture.output.calls.map(\.name), [])
    }

    private func gems(count: Int) -> [PebbleDescriptor] {
        (0 ..< count).map { index in
            PebbleDescriptor(
                subjectName: "勉強", colorHex: "58A9E4", source: .timer,
                kind: .normal, grams: 250,
                createdAt: Date(timeIntervalSinceReferenceDate: Double(index))
            )
        }
    }

    func testLeavingTheAppStopsAtOnceAndNothingStartsWhileInactive() {
        let fixture = Fixture()
        fixture.synth.playThud(impactSpeed: 4)

        fixture.synth.applicationWillResignActive()
        fixture.synth.playThud(impactSpeed: 4)
        fixture.synth.prewarm()
        fixture.drain()

        XCTAssertEqual(
            fixture.output.calls.map(\.name),
            ["ensureRunning", "play(voice: 0)", "stop(deactivatingSession: true)"]
        )

        fixture.synth.applicationDidBecomeActive()
        fixture.synth.prewarm()
        fixture.drain()
        XCTAssertEqual(fixture.output.calls.last?.name, "ensureRunning")
    }

    func testTurningSoundOffReleasesTheSessionAndPrewarmStaysOff() {
        let fixture = Fixture()
        fixture.synth.prewarm()

        fixture.synth.isEnabled = false
        fixture.synth.prewarm()
        fixture.synth.playThud(impactSpeed: 4)
        fixture.drain()

        XCTAssertEqual(
            fixture.output.calls.map(\.name),
            ["ensureRunning", "stop(deactivatingSession: true)"]
        )
    }

    func testAProcessThatNeverPlaysNeverTouchesTheOutput() {
        let fixture = Fixture()

        fixture.synth.stopTimerCompletion()
        fixture.synth.applicationWillResignActive()
        fixture.synth.isEnabled = false
        fixture.drain()

        XCTAssertTrue(fixture.output.calls.isEmpty)
    }

    func testAnImportantSoundWaitsForASlowStartButALateClinkIsDropped() {
        let fixture = Fixture()
        fixture.output.startDelay = SoundSynth.staleIncidentalSoundLimit + 0.1

        fixture.synth.playClinks(
            [JarClinkEvent(delay: 0, pitchRate: 1, gain: 0.3, variant: 0)],
            userInitiated: false
        )
        fixture.synth.playThud(impactSpeed: 4)
        fixture.drain()

        let plays = fixture.output.calls.filter { $0.name.hasPrefix("play(") }
        XCTAssertEqual(
            plays.map(\.name),
            ["play(voice: 1)"],
            "The collision clink came too late to match its cause; the thud still plays"
        )
    }

    func testTheFirstClinkOfATapStillPlaysAfterASlowStart() {
        let fixture = Fixture()
        fixture.output.startDelay = SoundSynth.staleIncidentalSoundLimit + 0.1

        fixture.synth.playClinks(
            [JarClinkEvent(delay: 0, pitchRate: 1, gain: 0.3, variant: 0)],
            userInitiated: true
        )
        fixture.drain()

        XCTAssertTrue(fixture.output.calls.contains { $0.name == "play(voice: 0)" })
    }
}

/// jar-03, after review of PR #41: a haptic cue that finds the engine
/// stopped waits for the asynchronous start instead of starting it on the
/// main thread. The simulator has no haptic hardware, so the waiting rules
/// are tested on their own.
final class DeferredHapticCuesTests: XCTestCase {
    func testAWaitingCuePlaysWhenTheStartCompletes() {
        var cues = DeferredHapticCues<String>()
        XCTAssertTrue(cues.isEmpty)

        cues.enqueue("tap", kind: .feedback, at: 10)
        XCTAssertFalse(cues.isEmpty)
        XCTAssertEqual(cues.drain(at: 10.04).map(\.cue), ["tap"])
        XCTAssertTrue(cues.isEmpty, "Draining empties the queue")
        XCTAssertEqual(cues.drain(at: 10.05).map(\.cue), [])
    }

    func testOnlyTheNewestFeedbackWaitsAndTheTimerCuePlaysFirst() {
        var cues = DeferredHapticCues<String>()
        cues.enqueue("landing", kind: .feedback, at: 10)
        cues.enqueue("timer", kind: .timerCompletion, at: 10.01)
        cues.enqueue("tap", kind: .feedback, at: 10.02)

        let due = cues.drain(at: 10.05)
        XCTAssertEqual(due.map(\.cue), ["timer", "tap"])
        XCTAssertEqual(due.map(\.kind), [.timerCompletion, .feedback])
    }

    func testALateFeedbackCueIsDroppedButTheTimerCueStillPlays() {
        let limit = DeferredHapticCues<String>.staleFeedbackLimit
        XCTAssertGreaterThan(limit, 0.046, "A first engine start measured 46 ms on an iPhone 12 mini")
        XCTAssertLessThanOrEqual(limit, 0.3)

        var cues = DeferredHapticCues<String>()
        cues.enqueue("tap", kind: .feedback, at: 10)
        cues.enqueue("timer", kind: .timerCompletion, at: 10)
        XCTAssertEqual(cues.drain(at: 10 + limit + 0.01).map(\.cue), ["timer"])

        cues.enqueue("tap", kind: .feedback, at: 20)
        XCTAssertEqual(cues.drain(at: 20 + limit).map(\.cue), ["tap"])
    }

    func testAcknowledgingTheTimerOrStoppingCancelsWaitingCues() {
        var cues = DeferredHapticCues<String>()
        cues.enqueue("timer", kind: .timerCompletion, at: 10)
        cues.enqueue("tap", kind: .feedback, at: 10)
        cues.cancelTimerCompletion()
        XCTAssertEqual(cues.drain(at: 10.01).map(\.cue), ["tap"])

        cues.enqueue("timer", kind: .timerCompletion, at: 11)
        cues.enqueue("tap", kind: .feedback, at: 11)
        cues.removeAll()
        XCTAssertTrue(cues.isEmpty)
        XCTAssertEqual(cues.drain(at: 11.01).map(\.cue), [])
    }
}

@MainActor
private struct Fixture {
    let output = RecordingSoundSynthOutput()
    let queue = DispatchQueue(label: "SoundSynthOutputTests.audio")
    let synth: SoundSynth

    init(idleLinger: TimeInterval = 60, idleChecks: ManualIdleChecks? = nil) {
        synth = SoundSynth(
            output: output,
            audioQueue: queue,
            idleLinger: idleLinger,
            scheduleIdleCheck: idleChecks?.scheduler ?? SoundSynth.mainQueueIdleCheckScheduler,
            observesApplicationLifecycle: false,
            // A few milliseconds of samples: rendering is AlarmSoundSynthesisTests' job.
            renderAlarm: { _, _ in
                RenderedAlarmSound(
                    loop: [Float](repeating: 0.25, count: 4_410),
                    cue: [Float](repeating: 0.25, count: 44_100)
                )
            }
        )
    }

    /// Waits until everything queued so far has run on the audio queue's own
    /// thread, including priming steps that re-queue themselves. (`sync`
    /// could run work on the calling main thread and hide the property under
    /// test.)
    func drain() {
        for _ in 0 ..< 32 {
            let done = DispatchSemaphore(value: 0)
            queue.async { done.signal() }
            done.wait()
        }
    }

    func wait(seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        drain()
    }
}

/// Holds SoundSynth's idle-shutdown checks until the test fires them, so no
/// assertion depends on how late the main run loop wakes up.
@MainActor
private final class ManualIdleChecks {
    struct Check {
        let delay: TimeInterval
        let work: @MainActor () -> Void
    }

    private(set) var pending: [Check] = []

    var scheduler: SoundSynth.IdleCheckScheduler {
        { [weak self] delay, work in
            self?.pending.append(Check(delay: delay, work: work))
        }
    }

    func fire(at index: Int) {
        pending.remove(at: index).work()
    }

    /// Fires the checks pending now; any they schedule stay pending.
    func fireAll() {
        let due = pending
        pending.removeAll()
        due.forEach { $0.work() }
    }
}

private final class RecordingSoundSynthOutput: SoundSynthOutput, @unchecked Sendable {
    struct Call: CustomStringConvertible {
        let name: String
        let onMainThread: Bool

        var description: String { "\(name)\(onMainThread ? " [main]" : "")" }
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var primed = 0
    private var _nextStart: SoundSynthOutputStart = .running
    private var _startDelay: TimeInterval = 0
    let voicesToPrime = 3

    var calls: [Call] { lock.withLock { recorded } }
    var nextStart: SoundSynthOutputStart {
        get { lock.withLock { _nextStart } }
        set { lock.withLock { _nextStart = newValue } }
    }
    var startDelay: TimeInterval {
        get { lock.withLock { _startDelay } }
        set { lock.withLock { _startDelay = newValue } }
    }

    private func record(_ name: String) {
        let call = Call(name: name, onMainThread: Thread.isMainThread)
        lock.withLock { recorded.append(call) }
    }

    func ensureRunning() -> SoundSynthOutputStart {
        record("ensureRunning")
        let (result, delay) = lock.withLock { () -> (SoundSynthOutputStart, TimeInterval) in
            let result = _nextStart
            let delay = _startDelay
            _nextStart = .running
            _startDelay = 0
            return (result, delay)
        }
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        return result
    }

    func primeOneIdleVoice() -> Bool {
        record("primeOneIdleVoice")
        return lock.withLock {
            primed += 1
            return primed < voicesToPrime
        }
    }

    func play(
        _ buffer: AVAudioPCMBuffer,
        voice: Int,
        volume: Float,
        pitchRate: Float,
        interrupting: Bool
    ) {
        record("play(voice: \(voice))")
    }

    func playTimerCompletion(_ buffer: AVAudioPCMBuffer, volume: Float) {
        record("playTimerCompletion")
    }

    func playTimerCompletionLoop(_ buffer: AVAudioPCMBuffer, volume: Float) {
        record("playTimerCompletionLoop")
    }

    func stopTimerCompletion() {
        record("stopTimerCompletion")
    }

    func useSessionMode(_ mode: AlarmAudioSessionMode) {
        record("useSessionMode(\(mode))")
    }

    func stop(deactivatingSession: Bool) {
        record("stop(deactivatingSession: \(deactivatingSession))")
    }

    func stopAfterInterruption() {
        record("stopAfterInterruption")
    }

    func rebuildAfterMediaServicesReset() {
        record("rebuildAfterMediaServicesReset")
    }

    func isCurrentEngine(_ object: AnyObject?) -> Bool {
        true
    }
}
