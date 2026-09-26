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

    func testTheEngineOutlivesTheSoundByTheLingerThenReleasesTheSession() {
        let fixture = Fixture(idleLinger: 0.4)

        fixture.synth.playThud(impactSpeed: 4)
        fixture.wait(seconds: 0.3)
        XCTAssertFalse(
            fixture.output.calls.contains { $0.name.hasPrefix("stop(") },
            "The old 0.12 s grace stopped the engine between every tap"
        )

        fixture.wait(seconds: 0.6)
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
        let fixture = Fixture(idleLinger: 0.4)

        fixture.synth.prewarm()
        fixture.wait(seconds: 0.3)
        fixture.synth.playThud(impactSpeed: 4)
        fixture.wait(seconds: 0.3)

        XCTAssertFalse(fixture.output.calls.contains { $0.name.hasPrefix("stop(") })
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

@MainActor
private struct Fixture {
    let output = RecordingSoundSynthOutput()
    let queue = DispatchQueue(label: "SoundSynthOutputTests.audio")
    let synth: SoundSynth

    init(idleLinger: TimeInterval = 60) {
        synth = SoundSynth(
            output: output,
            audioQueue: queue,
            idleLinger: idleLinger,
            observesApplicationLifecycle: false
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

    func stopTimerCompletion() {
        record("stopTimerCompletion")
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
