import SpriteKit
import XCTest
@testable import PomoGem

/// The resting jar's energy rules (Docs/GemExperienceDesign.md §7.13):
/// jar-01 stops SpriteKit's render loop itself once the jar rests. Every
/// way the jar can change must bring the render loop back in the same turn.
final class JarIdleEnergyTests: XCTestCase {

    // MARK: Render loop (jar-01)

    @MainActor
    func testRestingJarDrawsItsSettledFrameThenStopsTheSKViewRenderLoop() {
        let (scene, clock) = makeScene()
        let view = SKView(frame: CGRect(origin: .zero, size: scene.size))
        view.presentScene(scene)
        defer { view.presentScene(nil) }
        XCTAssertTrue(scene.view === view)
        scene.restore(pebbles: [loose(1), loose(2)])
        XCTAssertFalse(scene.isRenderLoopPaused)
        XCTAssertFalse(view.isPaused)

        settle(scene)
        XCTAssertTrue(scene.isIdlePaused)
        XCTAssertTrue(scene.isPaused, "The physics freezes at once")
        XCTAssertFalse(view.isPaused, "The settled frame is drawn first")

        clock.advance(by: JarScene.redrawHold)
        scene.evaluateRenderLoopForTesting()
        XCTAssertTrue(scene.isRenderLoopPaused)
        XCTAssertTrue(view.isPaused, "The display link itself stops, not only the scene")
        XCTAssertTrue(scene.isPaused)
    }

    @MainActor
    func testLightOnlyRedrawRunsTheRenderLoopButKeepsThePhysicsFrozen() {
        let (scene, clock) = makeScene()
        let view = SKView(frame: CGRect(origin: .zero, size: scene.size))
        view.presentScene(scene)
        defer { view.presentScene(nil) }
        scene.restore(pebbles: [loose(1)])
        rest(scene, clock: clock)
        XCTAssertTrue(view.isPaused)

        // SKView un-pauses its scene together with itself; the resting
        // physics must stay frozen while the frame is redrawn.
        scene.requestRedraw()
        XCTAssertFalse(scene.isRenderLoopPaused)
        XCTAssertFalse(view.isPaused)
        XCTAssertTrue(scene.isPaused)
        XCTAssertTrue(scene.isIdlePaused)

        clock.advance(by: JarScene.redrawHold / 2)
        scene.evaluateRenderLoopForTesting()
        XCTAssertFalse(view.isPaused, "Still inside the redraw hold")
        clock.advance(by: JarScene.redrawHold / 2)
        scene.evaluateRenderLoopForTesting()
        XCTAssertTrue(view.isPaused)
        XCTAssertTrue(scene.isPaused)
    }

    // MARK: Wake triggers

    @MainActor
    func testLandingWakesTheRenderLoopInTheSameTurn() {
        let (scene, clock) = makeScene()
        let view = SKView(frame: CGRect(origin: .zero, size: scene.size))
        view.presentScene(scene)
        defer { view.presentScene(nil) }
        scene.restore(pebbles: [loose(1)])
        rest(scene, clock: clock)

        scene.performCompletionDrop(loose(2))
        assertAwake(scene)
        XCTAssertFalse(view.isPaused)
        XCTAssertFalse(scene.isPaused)
    }

    @MainActor
    func testContentChangesWakeTheRestingJar() {
        let (scene, clock) = makeScene()
        scene.restore(pebbles: [loose(1), loose(2)])

        rest(scene, clock: clock)
        scene.restore(pebbles: [loose(1), loose(2), loose(4)])
        assertAwake(scene, "history sync")

        rest(scene, clock: clock)
        scene.removePebbles(withIDs: [loose(4).id])
        assertAwake(scene, "rotation out of the jar")

        rest(scene, clock: clock)
        scene.updateScreenTimeObstacles(totalUnits: 2, animated: false)
        assertAwake(scene, "Screen Time")

        // Last: a queued drop keeps the jar awake until it lands.
        rest(scene, clock: clock)
        scene.drop(loose(3))
        assertAwake(scene, "drop")
    }

    @MainActor
    func testTapShakeAndVoiceOverActionsWakeTheRestingJar() {
        let (scene, clock) = makeScene()
        scene.restore(pebbles: [loose(1), loose(2), loose(3)])

        rest(scene, clock: clock)
        XCTAssertTrue(scene.bouncePebbles())
        assertAwake(scene, "tap")

        rest(scene, clock: clock)
        XCTAssertTrue(scene.shakePebbles(strength: 0.8, horizontal: 1))
        assertAwake(scene, "shake")

        rest(scene, clock: clock)
        scene.nudge(horizontal: -1, uptime: ProcessInfo.processInfo.systemUptime + 10)
        assertAwake(scene, "VoiceOver nudge")
    }

    @MainActor
    func testTiltAboveTheThresholdRedrawsTheLightWithoutWakingThePhysics() {
        let (scene, clock) = makeScene()
        scene.reduceMotion = false
        scene.restore(pebbles: [loose(1)])
        rest(scene, clock: clock)
        let scale = Constants.Jar.tiltGravityHorizontalScale

        // Sensor noise of a phone held still: nothing is drawn.
        scene.setGravityVector(CGVector(dx: 0.012 * scale, dy: Constants.Jar.gravity), smoothing: false)
        XCTAssertTrue(scene.isRenderLoopPaused)

        // A deliberate tilt moves the light: the render loop comes back,
        // the physics keeps resting.
        scene.setGravityVector(CGVector(dx: 0.2 * scale, dy: Constants.Jar.gravity), smoothing: false)
        XCTAssertFalse(scene.isRenderLoopPaused)
        XCTAssertTrue(scene.isIdlePaused)
        XCTAssertTrue(scene.isPaused)

        // Held at the new angle: the loop stops again after the hold.
        clock.advance(by: JarScene.motionWakeHold)
        scene.evaluateRenderLoopForTesting()
        XCTAssertTrue(scene.isRenderLoopPaused)
    }

    @MainActor
    func testReduceMotionKeepsTheLightStillAndItsToggleRedraws() {
        let (scene, clock) = makeScene()
        scene.reduceMotion = true
        scene.restore(pebbles: [loose(1)])
        rest(scene, clock: clock)
        let scale = Constants.Jar.tiltGravityHorizontalScale

        scene.setGravityVector(CGVector(dx: 0.4 * scale, dy: Constants.Jar.gravity), smoothing: false)
        XCTAssertEqual(scene.opticalTiltFraction, 0)
        XCTAssertTrue(scene.isRenderLoopPaused, "Reduce Motion: tilt never moves the light")

        // Toggling Reduce Motion redraws the resting jar.
        scene.reduceMotion = false
        XCTAssertFalse(scene.isRenderLoopPaused)
        clock.advance(by: JarScene.redrawHold)
        scene.evaluateRenderLoopForTesting()
        XCTAssertTrue(scene.isRenderLoopPaused)

        // And the tap still wakes the jar under Reduce Motion.
        scene.reduceMotion = true
        rest(scene, clock: clock)
        XCTAssertTrue(scene.bouncePebbles())
        assertAwake(scene, "tap under Reduce Motion")
    }

    @MainActor
    func testScenePhaseSnapshotAndSettingsRedrawTheRestingJar() {
        let (scene, clock) = makeScene()
        let view = SKView(frame: CGRect(origin: .zero, size: scene.size))
        view.presentScene(scene)
        defer { view.presentScene(nil) }
        scene.restore(pebbles: [loose(1)])

        // Return to the foreground (JarSpriteView asks on `.active`).
        rest(scene, clock: clock)
        scene.requestRedraw()
        assertRedrawing(scene, "scene phase")

        // Share and widget snapshots.
        rest(scene, clock: clock)
        let restore = scene.prepareForSnapshot()
        restore()
        assertRedrawing(scene, "snapshot")

        // Settings that change the resting jar's look.
        rest(scene, clock: clock)
        scene.showsMonthLabels.toggle()
        assertRedrawing(scene, "month labels")

        rest(scene, clock: clock)
        scene.rareRewardMode = scene.rareRewardMode == .standard ? .quiet : .standard
        assertRedrawing(scene, "rare reward mode")

        rest(scene, clock: clock)
        scene.milestoneTraceCount = 3
        assertRedrawing(scene, "collar traces")

        // (A wider stage: a narrower one may shrink the pile, which wakes it.)
        rest(scene, clock: clock)
        scene.size = CGSize(width: scene.size.width + 20, height: scene.size.height)
        assertRedrawing(scene, "stage size")
    }

    // MARK: Helpers

    /// Starts at the real uptime: the scene's own clock ran before the
    /// test injected this one (its geometry asks for a redraw in `init`).
    @MainActor
    private final class TestClock {
        var now: TimeInterval = ProcessInfo.processInfo.systemUptime + 1
        func advance(by seconds: TimeInterval) { now += seconds }
    }

    @MainActor
    private func makeScene() -> (scene: JarScene, clock: TestClock) {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = true
        let clock = TestClock()
        scene.tiltClock = { clock.now }
        return (scene, clock)
    }

    private var settleTime: TimeInterval = 100

    /// Two idle observations `idleWindow` apart with no movement: the jar
    /// idle-pauses (the same seam the idle-tilt tests use).
    @MainActor
    private func settle(_ scene: JarScene) {
        let uptime = ProcessInfo.processInfo.systemUptime + settleTime
        scene.evaluateInteractionMotionForTesting(currentTime: settleTime, uptime: uptime)
        settleTime += Constants.Jar.idleWindow + 1
        scene.evaluateInteractionMotionForTesting(
            currentTime: settleTime,
            uptime: uptime + Constants.Jar.interactionHardStopDelay + 1
        )
        settleTime += 1
    }

    /// Settles the jar and lets its redraw hold run out.
    @MainActor
    private func rest(_ scene: JarScene, clock: TestClock) {
        settle(scene)
        clock.advance(by: JarScene.motionWakeHold + JarScene.redrawHold)
        scene.evaluateRenderLoopForTesting()
        XCTAssertTrue(scene.isIdlePaused, "rests")
        XCTAssertTrue(scene.isRenderLoopPaused, "render loop stopped")
    }

    @MainActor
    private func assertAwake(_ scene: JarScene, _ trigger: String = "", line: UInt = #line) {
        XCTAssertFalse(scene.isIdlePaused, trigger, line: line)
        XCTAssertFalse(scene.isRenderLoopPaused, trigger, line: line)
        if let view = scene.view {
            XCTAssertFalse(view.isPaused, trigger, line: line)
        }
    }

    @MainActor
    private func assertRedrawing(_ scene: JarScene, _ trigger: String, line: UInt = #line) {
        XCTAssertFalse(scene.isRenderLoopPaused, trigger, line: line)
        XCTAssertTrue(scene.isIdlePaused, "\(trigger): physics keeps resting", line: line)
        XCTAssertTrue(scene.isPaused, "\(trigger): physics keeps resting", line: line)
        if let view = scene.view {
            XCTAssertFalse(view.isPaused, trigger, line: line)
        }
    }

    private func loose(_ index: Int) -> PebbleDescriptor {
        PebbleDescriptor(
            id: UUID(uuidString: String(format: "E1000000-0000-4000-8000-%012X", index))!,
            subjectName: "英語",
            colorHex: [Constants.Color.english, Constants.Color.science, Constants.Color.japanese][index % 3],
            source: .timer,
            kind: .normal,
            grams: Constants.Mass.measuredPebbleGrams,
            createdAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index))
        )
    }
}
