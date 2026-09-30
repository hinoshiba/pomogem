import SpriteKit
import XCTest
@testable import PomoGem

/// The resting jar's energy rules (Docs/GemExperienceDesign.md §7.13):
/// jar-01 stops SpriteKit's render loop itself once the jar rests, and the
/// idle motion rate drops device motion to a few samples a second on a background queue,
/// stopping it whenever Home is hidden or holds no study gem. Every way the
/// jar can change must bring the render loop (and, for gestures, the full
/// motion rate) back in the same turn.
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
        XCTAssertFalse(scene.wantsFullRateMotion, "Motion drops to the idle rate at once")

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
        XCTAssertFalse(scene.wantsFullRateMotion, "A redraw alone keeps the idle motion rate")

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
    func testLandingWakesTheRenderLoopAndMotionInTheSameTurn() {
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

    /// launch-perf (b). Home re-applies its aggregate roots whenever a menu
    /// or a sheet opens or closes. The same roots, grams and presentation
    /// leave a resting jar asleep (each needless wake cost ~0.4 s of main
    /// thread and ~180 GPU frames on an iPhone 12 mini); a real change
    /// wakes it.
    @MainActor
    func testUnchangedAggregatesKeepTheRestingJarAsleepAndARealChangeWakesIt() {
        let (scene, clock) = makeScene()
        let view = SKView(frame: CGRect(origin: .zero, size: scene.size))
        view.presentScene(scene)
        defer { view.presentScene(nil) }
        let root = aggregateRow(index: 1, grams: 2_500)
        let other = aggregateRow(index: 2, grams: 2_500)
        scene.showsMonthLabels = false
        scene.configureAggregates([root])
        scene.restore(pebbles: [loose(1)])

        // Home's syncBaseLayers after a menu or sheet: the same inputs.
        rest(scene, clock: clock)
        for _ in 0 ..< 3 {
            scene.showsMonthLabels = false
            scene.configureAggregates([root])
            XCTAssertTrue(scene.isIdlePaused, "unchanged roots keep the physics asleep")
            XCTAssertTrue(scene.isRenderLoopPaused, "and the render loop stopped")
            XCTAssertTrue(view.isPaused)
            XCTAssertFalse(scene.wantsFullRateMotion)
        }

        root.grams = 3_200
        scene.configureAggregates([root])
        assertAwake(scene, "grams")

        rest(scene, clock: clock)
        scene.configureAggregates([root, other])
        assertAwake(scene, "a new root")

        rest(scene, clock: clock)
        scene.configureAggregates([other])
        assertAwake(scene, "a root gone")

        rest(scene, clock: clock)
        other.colorMixJSON = StrataMath.encodeColorMix([
            StratumColorFraction(hex: Constants.Color.science, fraction: 1)
        ])
        scene.configureAggregates([other])
        assertAwake(scene, "presentation")

        rest(scene, clock: clock)
        scene.showsMonthLabels = true
        assertRedrawing(scene, "month labels still redraw on a change")
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
        let scale = Constants.Jar.tiltLightHorizontalScale

        // Sensor noise of a phone held still: nothing is drawn.
        scene.setGravityVector(CGVector(dx: 0.012 * scale, dy: Constants.Jar.gravity), smoothing: false)
        XCTAssertTrue(scene.isRenderLoopPaused)
        XCTAssertFalse(scene.wantsFullRateMotion)

        // A deliberate tilt moves the light: the render loop and the full
        // motion rate come back, the physics keeps resting.
        scene.setGravityVector(CGVector(dx: 0.2 * scale, dy: Constants.Jar.gravity), smoothing: false)
        XCTAssertFalse(scene.isRenderLoopPaused)
        XCTAssertTrue(scene.wantsFullRateMotion)
        XCTAssertTrue(scene.isIdlePaused)
        XCTAssertTrue(scene.isPaused)

        // Held at the new angle: both stop again after the hold.
        clock.advance(by: JarScene.motionWakeHold)
        scene.evaluateRenderLoopForTesting()
        XCTAssertTrue(scene.isRenderLoopPaused)
        XCTAssertFalse(scene.wantsFullRateMotion)
    }

    @MainActor
    func testReduceMotionKeepsTheLightStillAndItsToggleRedraws() {
        let (scene, clock) = makeScene()
        scene.reduceMotion = true
        scene.restore(pebbles: [loose(1)])
        rest(scene, clock: clock)
        let scale = Constants.Jar.tiltLightHorizontalScale

        scene.setGravityVector(CGVector(dx: 0.4 * scale, dy: Constants.Jar.gravity), smoothing: false)
        XCTAssertEqual(scene.opticalTiltFraction, 0)
        XCTAssertTrue(scene.isRenderLoopPaused, "Reduce Motion: tilt never moves the light")
        XCTAssertFalse(scene.wantsFullRateMotion)

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
        scene.effectsIntensity = scene.effectsIntensity == .standard ? .subtle : .standard
        assertRedrawing(scene, "effects intensity")

        rest(scene, clock: clock)
        scene.milestoneTraceCount = 3
        assertRedrawing(scene, "collar traces")

        // (A wider stage: a narrower one may shrink the pile, which wakes it.)
        rest(scene, clock: clock)
        scene.size = CGSize(width: scene.size.width + 20, height: scene.size.height)
        assertRedrawing(scene, "stage size")
    }

    // MARK: Motion rates

    func testMotionRateResolvesFromVisibilityAndTheJarsDemand() {
        XCTAssertEqual(JarMotionRate.resolve(sampling: .stopped, jarWantsFullRate: true), .stopped)
        XCTAssertEqual(JarMotionRate.resolve(sampling: .stopped, jarWantsFullRate: false), .stopped)
        XCTAssertEqual(JarMotionRate.resolve(sampling: .tiltAndShake, jarWantsFullRate: true), .full)
        XCTAssertEqual(JarMotionRate.resolve(sampling: .tiltAndShake, jarWantsFullRate: false), .idle)
        XCTAssertEqual(JarMotionRate.full.updatesPerSecond, Double(Constants.Jar.tiltUpdatesPerSecond))
        XCTAssertEqual(JarMotionRate.idle.updatesPerSecond, 5)
        XCTAssertNil(JarMotionRate.stopped.updatesPerSecond)
    }

    func testIdleTiltFilterIgnoresAPhoneHeldStillAndWakesOnADeliberateTilt() {
        var filter = JarIdleTiltFilter(
            reading: reading(0),
            settledReading: reading(0),
            drawnLight: 0,
            followsTilt: true
        )
        // Same per-second smoothing as the scene's 30 Hz.
        XCTAssertEqual(
            filter.smoothing,
            1 - pow(1 - Constants.Jar.gravitySmoothingFactor, 6),
            accuracy: 0.0001
        )
        for index in 0 ..< 50 {
            let noise = index.isMultiple(of: 2) ? 0.012 : -0.012
            XCTAssertNil(filter.ingest(sample(noise)), "Tremor below the light step")
        }
        // A small deliberate tilt (below the pile's re-settle turn) moves
        // the light only.
        XCTAssertEqual(filter.ingest(sample(0.06)), .tilt)
        XCTAssertEqual(
            JarTiltMath.lightFraction(horizontal: JarGravityMapping.lightHorizontal(for: filter.reading ?? .flat)),
            0.06 * filter.smoothing,
            accuracy: 0.005
        )

        // Levelling back to the drawn light wakes nothing once it is there.
        var levelled = JarIdleTiltFilter(
            reading: reading(0.06),
            settledReading: reading(0.06),
            drawnLight: 0.06,
            followsTilt: true
        )
        XCTAssertNil(levelled.ingest(sample(0.065)))
        XCTAssertEqual(levelled.ingest(sample(0.0)), .tilt)
    }

    func testIdleTiltFilterUnderReduceMotionWakesOnlyForATurnOrAShakePeak() {
        var filter = JarIdleTiltFilter(
            reading: reading(0),
            settledReading: reading(0),
            drawnLight: 0,
            followsTilt: false
        )
        // A tilt that would move the light: nothing, the light stays still.
        XCTAssertNil(filter.ingest(sample(0.08)))
        XCTAssertNil(filter.ingest(sample(0.08)))
        XCTAssertGreaterThan(filter.gravity.dx, 0.06 * JarGravityMapping.strength, "Gravity is still tracked")
        var peak = sample(0.08)
        peak.accelerationX = 1.1
        XCTAssertEqual(filter.ingest(peak), .shake)

        // F3: a turn the pile must re-settle for wakes the jar with or
        // without Reduce Motion (the gems keep the same physics), once the
        // slow pose average has turned (review S1: the second idle sample
        // here).
        for followsTilt in [false, true] {
            var turned = JarIdleTiltFilter(
                reading: reading(0),
                settledReading: reading(0),
                drawnLight: 0,
                followsTilt: followsTilt
            )
            let first = turned.ingest(sample(0.6))
            XCTAssertNotEqual(first, .reorient, "followsTilt \(followsTilt)")
            XCTAssertEqual(turned.ingest(sample(0.6)), .reorient, "followsTilt \(followsTilt)")
        }
    }

    func testTheIdleCheckJudgesTheSlowPoseAverageSoASwayNeverWakesTheRestingPile() {
        // Review S1: the resting pile once recorded the pose it settled
        // under at whatever instant of a sway it stopped, so a ±5° sway
        // reached 10° from it on the other side and woke the jar. The pose
        // it settles under is now the slow pose average (τ 1.5 s), and the
        // idle check compares that average with it: held upright or leaned
        // back 30° or 45°, swayed ±5° at 0.25 and 0.5 Hz, from whatever
        // phase the pile settled at, a minute of the sway never wakes it.
        // A deliberate turn still does: past 30° at once, on the gravity's
        // own smoothing (`JarTiltMath.immediateResettleTurn`): sideways at
        // the first idle sample, upside down within two.
        XCTAssertEqual(JarTiltMath.poseTimeConstant, 1.5)
        XCTAssertEqual(
            JarTiltMath.poseFraction(updatesPerSecond: JarMotionRate.idleUpdatesPerSecond),
            CGFloat(1 - exp(-0.2 / 1.5)),
            accuracy: 1e-9
        )
        XCTAssertEqual(
            JarTiltMath.poseFraction(updatesPerSecond: JarMotionRate.fullUpdatesPerSecond),
            CGFloat(1 - exp(-1.0 / 45)),
            accuracy: 1e-9
        )
        func swayed(_ elevation: Double, _ amplitude: Double, _ hertz: Double, _ time: Double) -> JarMotionSample {
            let e = elevation * .pi / 180
            let r = amplitude * sin(2 * .pi * hertz * time) * .pi / 180
            if elevation >= 90 {
                // Upright: a twist in the screen's plane.
                return JarMotionSample(gravityX: sin(r), gravityY: -cos(r), gravityZ: 0, timestamp: time)
            }
            // Leaned back: a roll about the long axis.
            return JarMotionSample(gravityX: cos(e) * sin(r), gravityY: -sin(e), gravityZ: -cos(e) * cos(r), timestamp: time)
        }
        let rate = JarMotionRate.idleUpdatesPerSecond
        for elevation in [90.0, 30.0, 45.0] {
            for hertz in [0.25, 0.5] {
                for settlePhase in 0 ..< 10 {
                    let context = "\(elevation)°, ±5° at \(hertz) Hz, settled at phase \(settlePhase)"
                    // The awake jar's pose average through 8 s of the sway
                    // (at the idle rate: the same time constant), then the
                    // pile rests under it.
                    let steady = swayed(elevation, 0, hertz, 0).gravityReading!
                    var warmup = JarIdleTiltFilter(reading: steady, settledReading: steady, drawnLight: 0, followsTilt: false)
                    let settleSample = 40 + settlePhase
                    for index in 0 ..< settleSample {
                        _ = warmup.ingest(swayed(elevation, 5, hertz, Double(index) / rate))
                    }
                    let settled = warmup.poseReading!
                    var filter = JarIdleTiltFilter(
                        reading: warmup.reading,
                        poseReading: settled,
                        settledReading: settled,
                        drawnLight: 0,
                        followsTilt: false
                    )
                    for index in settleSample ..< settleSample + 300 {
                        XCTAssertNil(filter.ingest(swayed(elevation, 5, hertz, Double(index) / rate)), context)
                    }
                }
            }
        }
        // A deliberate turn wakes it.
        let upright = reading(0)
        var sideways = JarIdleTiltFilter(reading: upright, settledReading: upright, drawnLight: 0, followsTilt: false)
        XCTAssertEqual(sideways.ingest(JarMotionSample(gravityX: 1, gravityY: 0, timestamp: 0)), .reorient, "Sideways: the first idle sample")
        var flipped = JarIdleTiltFilter(reading: upright, settledReading: upright, drawnLight: 0, followsTilt: false)
        var samples = 0
        var woke = false
        while samples < 2, !woke {
            samples += 1
            woke = flipped.ingest(JarMotionSample(gravityX: 0, gravityY: 1, timestamp: Double(samples) / rate)) == .reorient
        }
        XCTAssertTrue(woke, "Upside down within two idle samples")
    }

    func testIdleTiltMonitorWakesMainAtMostOncePerRunFromAnyThread() {
        let monitor = JarIdleTiltMonitor()
        monitor.arm(
            JarIdleTiltFilter(reading: nil, drawnLight: 0, followsTilt: true),
            generation: 7
        )
        XCTAssertNil(monitor.ingest(sample(0.5), generation: 6), "A superseded run changes nothing")

        let wakes = WakeCounter()
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            if monitor.ingest(sample(0.5 + Double(index) * 0.001), generation: 7) != nil {
                wakes.increment()
            }
        }
        XCTAssertEqual(wakes.count, 1)
        let latest = monitor.disarm()
        XCTAssertNotNil(latest)
        XCTAssertGreaterThan(latest?.reading.x ?? 0, 0.49)
        XCTAssertNotNil(latest?.poseReading, "The slow pose average goes with it")
        XCTAssertFalse(monitor.isArmed)
        XCTAssertNil(monitor.ingest(sample(0.9), generation: 7), "Disarmed")
    }

    @MainActor
    func testMotionObserverRunsFullWhileAwakeAndIdleOffMainWhileResting() {
        let (scene, clock) = makeScene()
        scene.reduceMotion = false
        scene.restore(pebbles: [loose(1), loose(2)])
        let source = FakeMotionSource()
        let observer = JarMotionObserver(scene: scene, source: source)
        observer.start(scene: scene)
        defer { observer.stop() }

        XCTAssertEqual(observer.rate, .full)
        XCTAssertEqual(source.currentRun?.updatesPerSecond, 30)
        XCTAssertEqual(source.currentRun?.isMainQueue, true)

        rest(scene, clock: clock)
        XCTAssertEqual(observer.rate, .idle)
        XCTAssertEqual(source.currentRun?.updatesPerSecond, 5)
        XCTAssertEqual(source.currentRun?.isMainQueue, false, "The idle rate is delivered off the main thread")
        XCTAssertTrue(observer.isIdleCheckArmedForTesting)

        // A phone held still never reaches main.
        for index in 0 ..< 20 {
            source.deliver(sample(index.isMultiple(of: 2) ? 0.012 : -0.012))
        }
        drainMainQueue()
        XCTAssertEqual(observer.rate, .idle)
        XCTAssertTrue(scene.isRenderLoopPaused)
        XCTAssertEqual(scene.opticalTiltFraction, 0)

        // A deliberate tilt (below the pile's re-settle turn, F3) hops to
        // main: full rate, the light moves and the render loop runs, while
        // the physics keeps resting.
        let runsBefore = source.runs.count
        source.deliver(sample(0.1))
        drainMainQueue()
        XCTAssertEqual(observer.rate, .full)
        XCTAssertEqual(source.runs.count, runsBefore + 1)
        XCTAssertEqual(source.currentRun?.isMainQueue, true)
        XCTAssertFalse(scene.isRenderLoopPaused)
        XCTAssertTrue(scene.isIdlePaused)
        XCTAssertGreaterThan(scene.opticalTiltFraction, 0.05)

        // At the full rate the light keeps following the phone.
        let light = scene.opticalTiltFraction
        clock.advance(by: 0.05)
        source.deliver(sample(0.2))
        XCTAssertGreaterThan(scene.opticalTiltFraction, light)
        XCTAssertTrue(scene.isIdlePaused, "Still below the re-settle turn")

        // Held still: the hold runs out, the loop stops, the rate drops.
        clock.advance(by: JarScene.motionWakeHold)
        scene.evaluateRenderLoopForTesting()
        XCTAssertTrue(scene.isRenderLoopPaused)
        XCTAssertEqual(observer.rate, .idle)
        XCTAssertEqual(source.currentRun?.isMainQueue, false)

        // A tap wakes both at once.
        XCTAssertTrue(scene.bouncePebbles())
        XCTAssertEqual(observer.rate, .full)
        XCTAssertFalse(scene.isRenderLoopPaused)
    }

    @MainActor
    func testTapAfterAnIdleTiltUnderReduceMotionStartsFromTheCurrentGravity() {
        let (scene, clock) = makeScene()
        scene.reduceMotion = true
        scene.restore(pebbles: [loose(1), loose(2)])
        let source = FakeMotionSource()
        let observer = JarMotionObserver(scene: scene, source: source)
        observer.start(scene: scene)
        defer { observer.stop() }
        rest(scene, clock: clock)
        XCTAssertEqual(observer.rate, .idle)

        // Reduce Motion: a tilt (below the pile's re-settle turn, F3) never
        // reaches main while the jar rests...
        for _ in 0 ..< 6 { source.deliver(sample(0.08)) }
        drainMainQueue()
        XCTAssertEqual(observer.rate, .idle)
        XCTAssertEqual(scene.appliedGravityVector.dx, 0)

        // ...but the jar woken by a tap starts from the tilt the idle check saw.
        XCTAssertTrue(scene.bouncePebbles())
        XCTAssertEqual(observer.rate, .full)
        XCTAssertEqual(
            scene.appliedGravityVector.dx,
            0.08 * JarGravityMapping.strength,
            accuracy: 0.05
        )
    }

    @MainActor
    func testShakePeakWhileRestingRestoresTheFullRateInTimeForTheReversal() {
        let (scene, clock) = makeScene()
        scene.restore(pebbles: [loose(1), loose(2)])
        let source = FakeMotionSource()
        let observer = JarMotionObserver(scene: scene, source: source)
        observer.start(scene: scene)
        defer { observer.stop() }
        rest(scene, clock: clock)

        var first = sample(0, timestamp: 50)
        first.accelerationX = 1.3
        source.deliver(first)
        drainMainQueue()
        XCTAssertEqual(observer.rate, .full)
        XCTAssertTrue(scene.wantsFullRateMotion, "Held for the reversal")
        XCTAssertTrue(scene.isIdlePaused)

        var reversal = sample(0, timestamp: 50.2)
        reversal.accelerationX = -1.3
        source.deliver(reversal)
        assertAwake(scene, "shake from rest")
    }

    @MainActor
    func testStoppedObserverIgnoresLateSamplesAndTheJarsDemand() {
        let (scene, clock) = makeScene()
        scene.reduceMotion = false
        scene.restore(pebbles: [loose(1)])
        let source = FakeMotionSource()
        let observer = JarMotionObserver(scene: scene, source: source)
        observer.start(scene: scene)
        rest(scene, clock: clock)
        XCTAssertEqual(observer.rate, .idle)
        let lateIdleHandler = source.handler

        // Home covered by a sheet, the Focus screen, or the app inactive.
        observer.stop()
        XCTAssertEqual(observer.rate, .stopped)
        XCTAssertFalse(source.isRunning)
        XCTAssertEqual(scene.appliedGravityVector, Constants.Jar.gravityVector)

        DispatchQueue.global().sync { lateIdleHandler?(sample(0.8)) }
        drainMainQueue()
        XCTAssertEqual(observer.rate, .stopped)
        XCTAssertEqual(scene.opticalTiltFraction, 0)

        XCTAssertTrue(scene.bouncePebbles())
        XCTAssertEqual(observer.rate, .stopped, "A stopped observer does not follow the jar")
        XCTAssertFalse(source.isRunning)
    }

    func testMotionStopsWhenHomeIsHiddenInactiveOrWithoutStudyGems() {
        func mode(enabled: Bool = true, active: Bool = true, studyGems: Bool = true) -> JarMotionSamplingMode {
            JarMotionActivationPolicy.mode(
                isMotionEnabled: enabled,
                reduceMotion: false,
                sceneIsActive: active,
                hasStudyGems: studyGems
            )
        }
        XCTAssertEqual(mode(), .tiltAndShake)
        XCTAssertEqual(mode(enabled: false), .stopped, "A sheet or the Focus screen covers Home")
        XCTAssertEqual(mode(active: false), .stopped, "Inactive or background")
        XCTAssertEqual(mode(studyGems: false), .stopped, "No study gem")
    }

    @MainActor
    func testOnlyStudyGemsKeepTheSensorOn() {
        let (scene, _) = makeScene()
        XCTAssertFalse(scene.hasStudyGems)

        scene.setScreenTimeObstacles(totalUnits: 3)
        XCTAssertGreaterThan(scene.physicalPebbleCount, 0)
        XCTAssertFalse(scene.hasStudyGems, "Black stones alone")

        scene.restore(pebbles: [achievement()])
        XCTAssertFalse(scene.hasStudyGems, "Milestone stones alone")

        let revision = scene.physicalContentRevision
        scene.restore(pebbles: [achievement(), loose(1)])
        XCTAssertTrue(scene.hasStudyGems)
        XCTAssertNotEqual(scene.physicalContentRevision, revision, "Home re-evaluates the sensor")

        let tutorial = makeScene().scene
        tutorial.restore(pebbles: [loose(9, isTutorial: true)])
        XCTAssertTrue(tutorial.hasStudyGems, "The tutorial's stand-in gem")
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
        XCTAssertFalse(scene.wantsFullRateMotion, "idle motion rate")
    }

    @MainActor
    private func assertAwake(_ scene: JarScene, _ trigger: String = "", line: UInt = #line) {
        XCTAssertFalse(scene.isIdlePaused, trigger, line: line)
        XCTAssertFalse(scene.isRenderLoopPaused, trigger, line: line)
        XCTAssertTrue(scene.wantsFullRateMotion, trigger, line: line)
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

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func sample(_ gravityX: Double, timestamp: TimeInterval = 0) -> JarMotionSample {
        JarMotionSample(
            gravityX: gravityX,
            gravityY: -(1 - gravityX * gravityX).squareRoot(),
            timestamp: timestamp
        )
    }

    /// The sensed reading of an upright phone tilted `gravityX` sideways.
    private func reading(_ gravityX: Double) -> JarGravityMapping.Reading {
        sample(gravityX).gravityReading ?? .flat
    }

    private func loose(_ index: Int, isTutorial: Bool = false) -> PebbleDescriptor {
        PebbleDescriptor(
            id: UUID(uuidString: String(format: "E1000000-0000-4000-8000-%012X", index))!,
            subjectName: "英語",
            colorHex: [Constants.Color.english, Constants.Color.science, Constants.Color.japanese][index % 3],
            source: .timer,
            kind: .normal,
            grams: Constants.Mass.measuredPebbleGrams,
            createdAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index)),
            isTutorial: isTutorial
        )
    }

    private func aggregateRow(index: Int, grams: Int) -> AggregatePebble {
        let date = Date(timeIntervalSince1970: TimeInterval(1_750_000_000 + index))
        return AggregatePebble(
            id: UUID(uuidString: String(format: "E1A00000-0000-4000-8000-%012X", index))!,
            createdAt: date,
            level: 1,
            pebbleCount: 10,
            grams: grams,
            measuredPebbleCount: 10,
            colorMixJSON: StrataMath.encodeColorMix([
                StratumColorFraction(hex: Constants.Color.english, fraction: 1)
            ]),
            subjectMixJSON: StrataMath.encodeSubjectMix([
                AggregateSubjectFraction(name: "英語", colorHex: Constants.Color.english, pebbleCount: 10)
            ]),
            periodStart: date,
            periodEnd: date
        )
    }

    private func achievement() -> PebbleDescriptor {
        PebbleDescriptor(
            id: UUID(uuidString: "E1000000-0000-4000-8000-0000000000AC")!,
            subjectName: "資格",
            colorHex: Constants.Color.science,
            source: .manual,
            kind: .normal,
            achievementKind: .examPass,
            grams: 0,
            createdAt: Date(timeIntervalSince1970: 1_500)
        )
    }

    private final class WakeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func increment() {
            lock.lock(); storage += 1; lock.unlock()
        }
    }
}

/// Records the runs the observer asks for and delivers samples like Core
/// Motion: on the main thread for a main-queue run, on a background thread
/// otherwise.
@MainActor
private final class FakeMotionSource: JarMotionSource {
    struct Run: Equatable {
        let updatesPerSecond: Double
        let isMainQueue: Bool
    }

    var isAvailable = true
    private(set) var runs: [Run] = []
    private(set) var handler: (@Sendable (JarMotionSample) -> Void)?
    var isRunning: Bool { handler != nil }
    var currentRun: Run? { handler == nil ? nil : runs.last }

    func start(
        updatesPerSecond: Double,
        queue: OperationQueue,
        handler: @escaping @Sendable (JarMotionSample) -> Void
    ) {
        runs.append(Run(updatesPerSecond: updatesPerSecond, isMainQueue: queue === OperationQueue.main))
        self.handler = handler
    }

    func stop() {
        handler = nil
    }

    func deliver(_ sample: JarMotionSample) {
        guard let handler, let run = runs.last else { return }
        if run.isMainQueue {
            handler(sample)
        } else {
            DispatchQueue.global().sync { handler(sample) }
        }
    }
}
