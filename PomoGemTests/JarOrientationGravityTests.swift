import Metal
import SpriteKit
import XCTest
@testable import PomoGem

/// F3 (Docs/JarOrientationGravity.md): with the phone held sideways or
/// upside down the jar's gems follow real gravity. These tests drive the
/// real scene through SpriteKit's own update, physics and contact cycle
/// (`SKRenderer`, no window) with the same gravity readings Core Motion
/// delivers, and check the gem session's invariants: nothing ever leaves
/// the jar, a new gem always enters through the mouth and then follows the
/// phone's gravity, every new gem lands (Home's receipts and the onboarding
/// trial wait for it), a turn wakes a resting pile through the bounded
/// interaction window while tremor never does, Reduce Motion and 控えめ
/// keep the same physics, taps and shakes throw against gravity, and the
/// downward-gravity headroom is unchanged.
@MainActor
final class JarOrientationGravityTests: XCTestCase {

    // MARK: Gravity input

    func testEachPoseSetsTheJarsGravityThroughTheReadingPath() {
        let scene = makeScene()
        let expectations: [(Pose, CGVector)] = [
            (.portrait, CGVector(dx: 0, dy: -7.2)),
            (.landscapeLeft, CGVector(dx: -7.2, dy: 0)),
            (.landscapeRight, CGVector(dx: 7.2, dy: 0)),
            (.upsideDown, CGVector(dx: 0, dy: 7.2)),
            (.flat, Constants.Jar.gravityVector),
            (.faceDown, Constants.Jar.gravityVector)
        ]
        for (pose, expected) in expectations {
            scene.setGravityReading(pose.reading, smoothing: false)
            XCTAssertEqual(scene.appliedGravityVector.dx, expected.dx, accuracy: 1e-9, "\(pose)")
            XCTAssertEqual(scene.appliedGravityVector.dy, expected.dy, accuracy: 1e-9, "\(pose)")
            XCTAssertEqual(scene.physicsWorld.gravity.dx, expected.dx, accuracy: 1e-6, "\(pose)")
            XCTAssertEqual(scene.physicsWorld.gravity.dy, expected.dy, accuracy: 1e-6, "\(pose)")
        }
        // The retired clamp: an upright phone's reading maps as before
        // wherever the clamp never engaged, and upside down now pulls up.
        let tilted = JarMotionSample(gravityX: 0.3, gravityY: -(1 - 0.09).squareRoot(), timestamp: 0)
        XCTAssertEqual(tilted.proposedGravity?.dx ?? .nan, 0.3 * 7.2, accuracy: 1e-9)
        XCTAssertEqual(tilted.proposedGravity?.dy ?? .nan, -(1 - 0.09).squareRoot() * 7.2, accuracy: 1e-9)
        XCTAssertNil(JarMotionSample(gravityX: .nan, gravityY: -1, timestamp: 0).proposedGravity)
        XCTAssertNil(JarMotionSample(gravityX: 0, gravityY: -1, gravityZ: .infinity, timestamp: 0).gravityReading)

        // Smoothing follows the reading, and a reset returns exactly to the
        // default gravity and a level light.
        scene.reduceMotion = false
        scene.setGravityReading(Pose.portrait.reading, smoothing: false)
        scene.setGravityReading(Pose.landscapeRight.reading)
        XCTAssertGreaterThan(scene.appliedGravityVector.dx, 0)
        XCTAssertLessThan(scene.appliedGravityVector.dx, 7.2 * 0.2)
        XCTAssertGreaterThan(scene.opticalTiltFraction, 0)
        scene.resetGravity()
        XCTAssertEqual(scene.appliedGravityVector, Constants.Jar.gravityVector)
        XCTAssertEqual(scene.opticalTiltFraction, 0)
        XCTAssertNil(scene.appliedReading)
    }

    func testAPhoneOnADeskKeepsTheDefaultGravityButItsGlintsFollowATilt() {
        let scene = makeScene()
        scene.reduceMotion = false
        let rolled = JarGravityMapping.Reading(deviceGravityX: 0.1, deviceGravityY: 0, deviceGravityZ: -(1 - 0.01).squareRoot())!
        scene.setGravityReading(rolled, smoothing: false)
        XCTAssertEqual(scene.appliedGravityVector, Constants.Jar.gravityVector)
        XCTAssertEqual(scene.opticalTiltFraction, 0.1, accuracy: 1e-9)
    }

    // MARK: Containment

    func testNoBodyEverLeavesTheJarHeldSidewaysOrUpsideDown() throws {
        for fps in [60.0, 30.0] {
            for pose in [Pose.landscapeLeft, .landscapeRight, .upsideDown] {
                let scene = makeScene()
                scene.restore(pebbles: looseSeries(30))
                scene.setScreenTimeObstacles(totalUnits: 9_999)
                let driver = try Driver(scene: scene)
                defer { driver.finish() }
                driver.step(frames: Int(3 * fps), fps: fps) {
                    scene.setGravityReading(pose.reading)
                    self.assertContained(scene, "\(pose) at \(fps) fps")
                }
                assertContainedWithRadius(scene, "\(pose) at \(fps) fps, settled")
                let bodies = pebbles(scene)
                let interior = JarScene.interiorRect(sceneSize: scene.size)
                let meanX = bodies.map(\.position.x).reduce(0, +) / CGFloat(bodies.count)
                let meanY = bodies.map(\.position.y).reduce(0, +) / CGFloat(bodies.count)
                switch pose {
                case .landscapeLeft: XCTAssertLessThan(meanX, interior.midX - 30, "Toward the left wall")
                case .landscapeRight: XCTAssertGreaterThan(meanX, interior.midX + 30, "Toward the right wall")
                case .upsideDown: XCTAssertGreaterThan(meanY, interior.midY + 30, "Toward the cap")
                default: break
                }
            }
        }
    }

    func testNoBodyEverLeavesTheJarWhileThePhoneFlipsBetweenPoses() throws {
        let scene = makeScene()
        scene.restore(pebbles: looseSeries(24))
        scene.setScreenTimeObstacles(totalUnits: 9_999)
        let driver = try Driver(scene: scene)
        defer { driver.finish() }
        let sequence: [Pose] = [
            .portrait, .landscapeLeft, .upsideDown, .landscapeRight, .portrait,
            .upsideDown, .portrait, .landscapeRight, .landscapeLeft, .upsideDown, .faceDown, .portrait
        ]
        for (index, pose) in sequence.enumerated() {
            if index == 3 { _ = scene.shakePebbles(strength: 1, horizontal: 1) }
            if index == 6 { _ = scene.bouncePebbles() }
            driver.step(frames: 40) {
                scene.setGravityReading(pose.reading)
                self.assertContained(scene, "flipping to \(pose)")
            }
        }
        driver.step(frames: 180) {
            scene.setGravityReading(Pose.portrait.reading)
            self.assertContained(scene, "back upright")
        }
        assertContainedWithRadius(scene, "back upright, settled")
    }

    // MARK: Entry ritual and landing

    func testACompletionDropEntersThroughTheMouthAndLandsInEveryPose() throws {
        for pose in Pose.allCases {
            for filled in [false, true] {
                let scene = makeScene()
                scene.restore(pebbles: filled ? looseSeries(8) : [])
                if filled { scene.setScreenTimeObstacles(totalUnits: 9_999) }
                let driver = try Driver(scene: scene)
                defer { driver.finish() }
                // The pile first rests the way the phone is held.
                driver.step(frames: 150) { scene.setGravityReading(pose.reading) }
                var landings: [UUID] = []
                scene.onLanding = { landings.append($0.pebble.id) }
                let drop = loose(900, minutes: 50)
                scene.dropFromAbove(drop)
                let context = "\(pose)\(filled ? ", over a pile" : ", empty jar")"
                var frames = 0
                driver.step(frames: 240) {
                    scene.setGravityReading(pose.reading)
                    self.assertContained(scene, context)
                    self.assertEntersThroughTheNeck(scene, id: drop.id, context)
                    if landings.isEmpty { frames += 1 }
                }
                XCTAssertEqual(landings, [drop.id], context)
                XCTAssertLessThan(Double(frames) / 60, 2.5, "\(context): lands within the onboarding's 2.5 s")
                XCTAssertTrue(scene.completionDropHasLanded, context)
                XCTAssertFalse(scene.hasCompletionDropInFlight, context)
                XCTAssertTrue(scene.hasLandedPebble(withID: drop.id), context)
                let body = try XCTUnwrap(try node(scene, drop.id).physicsBody)
                XCTAssertEqual(body.categoryBitMask, JarPhysicsCategory.pebble, context)
                XCTAssertTrue(body.affectedByGravity, context)
                XCTAssertEqual(body.fieldBitMask, 0, context)
                // After the collar it follows the phone's gravity (checked in
                // the empty jar; over a pile it rests on the pile's side).
                let interior = JarScene.interiorRect(sceneSize: scene.size)
                let resting = try node(scene, drop.id).position
                guard !filled else { continue }
                switch pose {
                case .upsideDown:
                    XCTAssertGreaterThan(resting.y, interior.midY, "\(context): settles toward the cap")
                case .landscapeLeft:
                    XCTAssertLessThan(resting.x, interior.midX, "\(context): drifts to the left wall")
                case .landscapeRight:
                    XCTAssertGreaterThan(resting.x, interior.midX, "\(context): drifts to the right wall")
                default:
                    XCTAssertLessThan(resting.y, interior.midY, "\(context): falls to the floor")
                }
            }
        }
    }

    func testTheOnboardingTrialDropLandsInEveryPoseWithinItsWait() throws {
        // OnboardingView: a 240 × 320 jar, emptied, then one tutorial gem
        // from above; its motion starts only once the gem is in the scene.
        for pose in Pose.allCases {
            let scene = JarScene(size: CGSize(width: 240, height: 320))
            scene.soundEnabled = false
            scene.hapticsEnabled = false
            scene.bakesGemBedInBackground = false
            let driver = try Driver(scene: scene)
            defer { driver.finish() }
            var landed = false
            scene.onLanding = { if $0.pebble.isTutorial { landed = true } }
            scene.restore(pebbles: [])
            scene.dropFromAbove(loose(1, isTutorial: true))
            var frames = 0
            driver.step(frames: 150) {
                if frames > 0 { scene.setGravityReading(pose.reading) }
                self.assertContained(scene, "onboarding \(pose)")
                if !landed { frames += 1 }
            }
            XCTAssertTrue(landed, "onboarding \(pose): 着地 within 2.5 s")
            XCTAssertLessThan(frames, 150, "onboarding \(pose)")
        }
    }

    func testADropInFlightStaysInTheNeckWhenThePhoneTurnsDuringItsEntry() throws {
        // The masked-wall escape (critic D10): walls are off above the
        // collar, so a sideways gravity used to carry the entering gem past
        // the neck and out of the bottle, where it never landed.
        for turn in [Pose.landscapeLeft, .landscapeRight, .upsideDown] {
            let scene = makeScene()
            scene.restore(pebbles: [])
            let driver = try Driver(scene: scene)
            defer { driver.finish() }
            scene.setGravityReading(Pose.portrait.reading, smoothing: false)
            var landings: [UUID] = []
            scene.onLanding = { landings.append($0.pebble.id) }
            let drop = loose(901, minutes: 120)
            scene.dropFromAbove(drop)
            driver.step(frames: 2)
            driver.step(frames: 240) {
                scene.setGravityReading(turn.reading, smoothing: false)
                self.assertContained(scene, "turned \(turn) mid-entry")
                self.assertEntersThroughTheNeck(scene, id: drop.id, "turned \(turn) mid-entry")
            }
            XCTAssertEqual(landings, [drop.id], "turned \(turn) mid-entry")
            XCTAssertFalse(scene.hasCompletionDropInFlight)
        }
    }

    func testTheEntryRitualFallsLikeTheJarsOwnGravityWhateverThePose() throws {
        // Under the entry field a completion drop falls exactly as under the
        // default gravity until the collar, however the phone is held.
        var tracks: [Pose: [CGFloat]] = [:]
        for pose in [Pose.portrait, .upsideDown, .landscapeLeft] {
            let scene = makeScene()
            scene.restore(pebbles: [])
            let driver = try Driver(scene: scene)
            defer { driver.finish() }
            scene.setGravityReading(pose.reading, smoothing: false)
            let drop = loose(902)
            scene.dropFromAbove(drop)
            var track: [CGFloat] = []
            let interior = JarScene.interiorRect(sceneSize: scene.size)
            driver.step(frames: 60) {
                guard let body = scene.childNode(withName: "//pebble.\(drop.id.uuidString)") as? PebbleNode else { return }
                if body.position.y + body.radius > interior.maxY { track.append(body.position.y) }
            }
            tracks[pose] = track
        }
        let portrait = try XCTUnwrap(tracks[.portrait])
        XCTAssertGreaterThan(portrait.count, 5)
        for pose in [Pose.upsideDown, .landscapeLeft] {
            let track = try XCTUnwrap(tracks[pose])
            XCTAssertEqual(track.count, portrait.count, "\(pose)")
            for (a, b) in zip(track, portrait) {
                XCTAssertEqual(a, b, accuracy: 0.01, "\(pose)")
            }
        }
    }

    func testInteriorDropsEnterUnderTheMouthAndLandInEveryPose() throws {
        for pose in Pose.allCases {
            let scene = makeScene()
            scene.restore(pebbles: looseSeries(4))
            scene.setScreenTimeObstacles(totalUnits: 9_999)
            let driver = try Driver(scene: scene)
            defer { driver.finish() }
            driver.step(frames: 150) { scene.setGravityReading(pose.reading) }
            var landings: [UUID] = []
            scene.onLanding = { landings.append($0.pebble.id) }
            let drop = loose(903)
            scene.drop(drop)
            driver.step(frames: 1)
            let interior = JarScene.interiorRect(sceneSize: scene.size)
            let spawned = try node(scene, drop.id)
            XCTAssertEqual(spawned.position.y, interior.maxY - spawned.radius, accuracy: 1, "\(pose): under the mouth")
            driver.step(frames: 240) {
                scene.setGravityReading(pose.reading)
                self.assertContained(scene, "interior drop \(pose)")
            }
            XCTAssertEqual(landings, [drop.id], "\(pose)")
        }
    }

    func testAGemFloatingInNearlyZeroGravityStillLands() throws {
        // Tipping a phone top-down from flat passes the jar's gravity
        // through zero (the flat-phone blend). A gem that comes to rest
        // without a landing contact lands on the velocity fallback.
        let scene = makeScene()
        scene.restore(pebbles: [])
        let driver = try Driver(scene: scene)
        defer { driver.finish() }
        let weak = try XCTUnwrap(weakestGravityReading())
        scene.setGravityReading(weak, smoothing: false)
        XCTAssertLessThan(hypot(scene.appliedGravityVector.dx, scene.appliedGravityVector.dy), JarGravityMapping.weakGravityMagnitude)
        var landings: [UUID] = []
        scene.onLanding = { landings.append($0.pebble.id) }
        let drop = loose(904)
        scene.drop(drop)
        driver.step(frames: 90) { self.assertContained(scene, "weightless") }
        XCTAssertEqual(landings, [drop.id])
    }

    func testTheUpsideDownPileTakesANewGemAtTheCapWithoutEscapes() throws {
        let scene = makeScene()
        // Eight study gems: with ten, the queue would wait for a fusion
        // (no persistence owner here).
        scene.restore(pebbles: looseSeries(8))
        scene.setScreenTimeObstacles(totalUnits: 9_999)
        let driver = try Driver(scene: scene)
        defer { driver.finish() }
        driver.step(frames: 240) { scene.setGravityReading(Pose.upsideDown.reading) }
        var landings: [UUID] = []
        scene.onLanding = { landings.append($0.pebble.id) }
        for (index, drop) in [loose(905), loose(906, minutes: 90)].enumerated() {
            // The queue spaces spawns by `dropInterval` of real time, which a
            // fast run of simulated frames may not cover.
            Thread.sleep(forTimeInterval: Constants.Jar.dropInterval + 0.05)
            if index == 0 { scene.dropFromAbove(drop) } else { scene.drop(drop) }
            driver.step(frames: 240) {
                scene.setGravityReading(Pose.upsideDown.reading)
                self.assertContained(scene, "upside-down pile, drop \(index)")
            }
        }
        XCTAssertEqual(Set(landings), [loose(905).id, loose(906).id])
        assertContainedWithRadius(scene, "upside-down pile, settled")
    }

    // MARK: Planning preview

    func testThePlanningPreviewRestoresContainedInEveryPose() throws {
        // AccumulationPlanView restores (never drops); nothing waits on a
        // landing there, but the restored rows fall toward the phone's
        // gravity and must stay in.
        for pose in [Pose.landscapeLeft, .upsideDown, .landscapeRight] {
            let scene = makeScene(size: CGSize(width: 360, height: 260))
            let driver = try Driver(scene: scene)
            defer { driver.finish() }
            scene.setGravityReading(pose.reading, smoothing: false)
            scene.restore(pebbles: looseSeries(20))
            driver.step(frames: 180) {
                scene.setGravityReading(pose.reading)
                self.assertContained(scene, "planning \(pose)")
            }
            scene.restore(pebbles: looseSeries(30))
            driver.step(frames: 180) {
                scene.setGravityReading(pose.reading)
                self.assertContained(scene, "planning \(pose), refreshed")
            }
        }
    }

    // MARK: Waking a resting jar (energy path)

    func testATurnWakesTheRestingPileThroughTheIdleCheckWithOrWithoutReduceMotion() {
        for reduceMotion in [false, true] {
            let (scene, clock) = makeClockScene()
            scene.reduceMotion = reduceMotion
            scene.restore(pebbles: [loose(1), loose(2)])
            let source = FakeMotionSource()
            let observer = JarMotionObserver(scene: scene, source: source)
            observer.start(scene: scene)
            defer { observer.stop() }
            // Held upright while awake, then the pile rests.
            source.deliver(sample(.portrait))
            rest(scene, clock: clock)
            XCTAssertEqual(observer.rate, .idle)
            XCTAssertEqual(source.currentRun?.isMainQueue, false)
            XCTAssertEqual(scene.settledReading, Pose.portrait.reading)

            // Turned sideways: one hop to main wakes the physics through
            // the bounded interaction window, whatever Reduce Motion says.
            source.deliver(sample(.landscapeLeft))
            drainMainQueue()
            XCTAssertEqual(observer.rate, .full, "Reduce Motion \(reduceMotion)")
            XCTAssertFalse(scene.isIdlePaused, "Reduce Motion \(reduceMotion)")
            XCTAssertTrue(scene.isInteractionMotionActive, "Bounded window, Reduce Motion \(reduceMotion)")
            XCTAssertFalse(scene.isRenderLoopPaused)
            XCTAssertLessThan(scene.appliedGravityVector.dx, -3)
            if reduceMotion {
                XCTAssertEqual(scene.opticalTiltFraction, 0, "Reduce Motion keeps the light still")
            }

            // Held there until the window's hard stop: the pile rests again
            // under the new pose.
            for _ in 0 ..< 20 { source.deliver(sample(.landscapeLeft)) }
            forceRest(scene, clock: clock)
            XCTAssertTrue(scene.isIdlePaused)
            XCTAssertEqual(observer.rate, .idle)
            XCTAssertLessThan(scene.settledReading.x, -0.5)
            XCTAssertLessThan(scene.pileGravityVector.dx, -3)
            XCTAssertFalse(scene.pileRestsOnTheFloor)

            // Held there, it stays resting; turned upside down it wakes again.
            for index in 0 ..< 10 {
                source.deliver(sample(.landscapeLeft, tremor: index.isMultiple(of: 2) ? 0.012 : -0.012))
            }
            drainMainQueue()
            XCTAssertTrue(scene.isIdlePaused)
            XCTAssertEqual(observer.rate, .idle)
            source.deliver(sample(.upsideDown))
            drainMainQueue()
            XCTAssertFalse(scene.isIdlePaused)
            XCTAssertTrue(scene.isInteractionMotionActive)
        }
    }

    func testTremorAndHandDriftNeverWakeTheRestingPile() {
        for reduceMotion in [false, true] {
            let (scene, clock) = makeClockScene()
            scene.reduceMotion = reduceMotion
            scene.restore(pebbles: [loose(1), loose(2), loose(3)])
            let source = FakeMotionSource()
            let observer = JarMotionObserver(scene: scene, source: source)
            observer.start(scene: scene)
            defer { observer.stop() }
            source.deliver(sample(.portrait))
            rest(scene, clock: clock)

            // Tremor within ±0.012 g on every axis, then a slow 4° drift
            // (hand drift while reading) with the tremor on top.
            for index in 0 ..< 40 {
                let sign = index.isMultiple(of: 2) ? 1.0 : -1.0
                let drift = 4.0 * .pi / 180 * Double(index) / 39
                source.deliver(JarMotionSample(
                    gravityX: sin(drift) + 0.012 * sign,
                    gravityY: -cos(drift) - 0.012 * sign,
                    gravityZ: 0.012 * sign,
                    timestamp: Double(index) / 5
                ))
                drainMainQueue()
                clock.advance(by: 0.2)
                XCTAssertTrue(scene.isIdlePaused, "Reduce Motion \(reduceMotion), sample \(index)")
                XCTAssertFalse(scene.isInteractionMotionActive, "Reduce Motion \(reduceMotion), sample \(index)")
            }
            if reduceMotion {
                XCTAssertEqual(observer.rate, .idle, "Reduce Motion: the light stays still, nothing reaches main")
            }
        }
    }

    func testMotionStartingOnAResetJarDoesNotWakeAnUprightPile() {
        // Home shown again: the motion observer restarts on a resting jar
        // whose gravity was reset (the pile settled under the default).
        let (scene, clock) = makeClockScene()
        scene.reduceMotion = false
        scene.restore(pebbles: [loose(1), loose(2)])
        rest(scene, clock: clock)
        XCTAssertEqual(scene.settledReading, .flat)
        let source = FakeMotionSource()
        let observer = JarMotionObserver(scene: scene, source: source)
        observer.start(scene: scene)
        defer { observer.stop() }
        XCTAssertEqual(observer.rate, .idle)
        // Upright, put down face up or face down, picked up again: the
        // gravity only weakens and recovers through the flat-phone blend.
        for pose in [Pose.portrait, .flat, .faceDown, .portrait] {
            source.deliver(sample(pose))
            drainMainQueue()
            XCTAssertTrue(scene.isIdlePaused, "\(pose)")
            XCTAssertFalse(scene.isInteractionMotionActive, "\(pose)")
        }
        // Upside down: once the smoothed gravity points up, the pile goes.
        for _ in 0 ..< 3 {
            source.deliver(sample(.upsideDown))
            drainMainQueue()
        }
        XCTAssertFalse(scene.isIdlePaused, "Upside down re-settles the pile")
        XCTAssertTrue(scene.isInteractionMotionActive)
    }

    func testTheResettleRuleNeedsATurnOfThePhoneAndOfTheGravity() {
        func reading(_ x: Double, _ y: Double, _ z: Double) -> JarGravityMapping.Reading {
            JarGravityMapping.Reading(deviceGravityX: x, deviceGravityY: y, deviceGravityZ: z)!
        }
        let smoothing = JarTiltMath.smoothingFraction(updatesPerSecond: JarMotionRate.idleUpdatesPerSecond)
        func wakes(from settled: JarGravityMapping.Reading, toward target: JarGravityMapping.Reading, samples: Int = 30) -> Bool {
            var smoothed = settled
            for _ in 0 ..< samples {
                smoothed = smoothed.smoothed(toward: target, fraction: smoothing)
                if JarGravityMapping.needsResettle(from: settled, to: smoothed) { return true }
            }
            return false
        }
        let upright = reading(0, -1, 0)
        XCTAssertTrue(wakes(from: upright, toward: reading(-1, 0, 0), samples: 1), "Landscape: the first idle sample")
        XCTAssertTrue(wakes(from: upright, toward: reading(0, 1, 0), samples: 2), "Upside down: the second")
        let turn = 10.0 * .pi / 180
        XCTAssertTrue(wakes(from: upright, toward: reading(sin(turn), -cos(turn), 0), samples: 1))
        let drift = 4.0 * .pi / 180
        XCTAssertFalse(wakes(from: upright, toward: reading(sin(drift), -cos(drift), 0)), "Hand drift")
        // Strength alone: put down, picked up, leaned back to 40° from flat.
        XCTAssertFalse(wakes(from: upright, toward: reading(0, 0, -1)), "Put down")
        XCTAssertFalse(wakes(from: .flat, toward: upright), "Picked up")
        let lean = 40.0 * .pi / 180
        XCTAssertFalse(wakes(from: upright, toward: reading(0, -sin(lean), -cos(lean))), "Leaned back")
        // Half-way down the gravity only weakens, yet the turn alone
        // (`wakeDelta`) would have woken the pile there.
        let halfway = reading(0, -0.35, -(1 - 0.35 * 0.35).squareRoot())
        XCTAssertGreaterThan(JarGravityMapping.wakeDelta(from: upright, to: halfway), JarTiltMath.reorientationWakeThreshold)
        XCTAssertFalse(JarGravityMapping.needsResettle(from: upright, to: halfway))
        // A settled pile never wakes for tremor at any pose in or above the
        // blend band (±0.012 g on every axis, alternating).
        for s in stride(from: 0.2, through: 1.0, by: 0.05) {
            let angle = asin(min(s, 1))
            for still in [(0.0, -sin(angle), -cos(angle)), (0.0, sin(angle), -cos(angle)), (sin(angle), 0.0, -cos(angle))] {
                let settled = reading(still.0, still.1, still.2)
                var smoothed = settled
                for index in 0 ..< 60 {
                    let sign = index.isMultiple(of: 2) ? 1.0 : -1.0
                    let shaken = reading(still.0 + 0.012 * sign, still.1 - 0.012 * sign, still.2 + 0.012 * sign)
                    smoothed = smoothed.smoothed(toward: shaken, fraction: smoothing)
                    XCTAssertFalse(JarGravityMapping.needsResettle(from: settled, to: smoothed), "s \(s), \(still)")
                }
            }
        }
        // A pile that settled in nearly zero gravity re-settles for a real
        // one; a nearly zero current gravity has no direction to follow.
        let weak = weakestGravityReading()!
        XCTAssertTrue(JarGravityMapping.needsResettle(from: weak, to: reading(0, 1, 0)))
        XCTAssertFalse(JarGravityMapping.needsResettle(from: upright, to: weak))
    }

    func testAStoppedObserverLeavesTheSettledPoseForShareAndTheNextWake() {
        let (scene, clock) = makeClockScene()
        scene.restore(pebbles: [loose(1), loose(2)])
        let source = FakeMotionSource()
        let observer = JarMotionObserver(scene: scene, source: source)
        observer.start(scene: scene)
        for _ in 0 ..< 3 { source.deliver(sample(.landscapeRight)) }
        rest(scene, clock: clock)
        XCTAssertGreaterThan(scene.pileGravityVector.dx, 3)

        // A sheet covers Home: gravity resets, the frozen pile does not move.
        observer.stop()
        XCTAssertEqual(scene.appliedGravityVector, Constants.Jar.gravityVector)
        XCTAssertGreaterThan(scene.pileGravityVector.dx, 3, "Support is judged by the pose the pile rests in")
        XCTAssertFalse(ShareJarSnapshotPolicy.pileRestsOnTheFloor(in: scene))

        // Back on Home, held upright: the pile falls back to the floor.
        observer.start(scene: scene)
        defer { observer.stop() }
        source.deliver(sample(.portrait))
        drainMainQueue()
        XCTAssertFalse(scene.isIdlePaused)
        XCTAssertTrue(scene.isInteractionMotionActive)
    }

    // MARK: Reduce Motion and 控えめ parity

    func testReduceMotionAndSubtleEffectsKeepTheSamePhysicsThroughTurnsAndDrops() throws {
        // SpriteKit does not reproduce a tumbling pile body for body across
        // two scenes (its solver order is not fixed), so parity is checked
        // on what the jar feeds the physics — the gravity every frame, each
        // body's physical setup — and on the outcome: contained, resting on
        // the gravity's side, the completion drop landed.
        struct Run {
            var gravities: [CGVector] = []
            var setups: [String] = []
            var centroid = CGPoint.zero
            var landed = false
        }
        var runs: [Run] = []
        for (reduceMotion, effects) in [(false, JarEffectsIntensity.standard), (true, .standard), (false, .subtle)] {
            let scene = makeScene()
            scene.reduceMotion = reduceMotion
            scene.effectsIntensity = effects
            scene.restore(pebbles: looseSeries(8))
            scene.setScreenTimeObstacles(totalUnits: 30)
            let driver = try Driver(scene: scene)
            defer { driver.finish() }
            var run = Run()
            for pose in [Pose.landscapeLeft, .upsideDown, .landscapeRight, .portrait, .upsideDown] {
                driver.step(frames: 60) {
                    scene.setGravityReading(pose.reading)
                    run.gravities.append(scene.physicsWorld.gravity)
                    self.assertContained(scene, "RM \(reduceMotion) \(effects)")
                }
            }
            var landed = false
            scene.onLanding = { _ in landed = true }
            scene.dropFromAbove(loose(907))
            driver.step(frames: 180) {
                scene.setGravityReading(Pose.upsideDown.reading)
                run.gravities.append(scene.physicsWorld.gravity)
                self.assertContained(scene, "RM \(reduceMotion) \(effects)")
            }
            run.landed = landed
            let bodies = pebbles(scene).sorted { $0.descriptor.id.uuidString < $1.descriptor.id.uuidString }
            run.setups = bodies.map { pebble in
                let body = pebble.physicsBody
                return [
                    pebble.descriptor.id.uuidString,
                    "\(pebble.radius)",
                    "\(body?.mass ?? -1)",
                    "\(body?.categoryBitMask ?? 0)/\(body?.collisionBitMask ?? 0)/\(body?.fieldBitMask ?? 0)",
                    "\(body?.affectedByGravity ?? false)",
                    "\(body?.friction ?? -1)/\(body?.restitution ?? -1)"
                ].joined(separator: " ")
            }
            let count = CGFloat(max(bodies.count, 1))
            run.centroid = CGPoint(
                x: bodies.map(\.position.x).reduce(0, +) / count,
                y: bodies.map(\.position.y).reduce(0, +) / count
            )
            runs.append(run)
        }
        let reference = try XCTUnwrap(runs.first)
        let interior = JarScene.interiorRect(sceneSize: CGSize(width: 390, height: Constants.Jar.height))
        for (index, run) in runs.enumerated() {
            XCTAssertTrue(run.landed, "run \(index)")
            XCTAssertEqual(run.gravities, reference.gravities, "run \(index): the same gravity, frame by frame")
            XCTAssertEqual(run.setups, reference.setups, "run \(index): the same bodies")
            XCTAssertGreaterThan(run.centroid.y, interior.midY, "run \(index): resting toward the cap")
        }
    }

    func testTheLightUnderEachEffectsSettingFollowsTiltAsBefore() {
        // Reduce Motion keeps the light still; 控えめ and 標準 follow the
        // sensed sideways reading (控えめ only never lights a glint, in
        // PebbleNode). The gravity is the same in all three.
        for (reduceMotion, effects, followsLight) in [
            (false, JarEffectsIntensity.standard, true),
            (false, .subtle, true),
            (true, .standard, false)
        ] {
            let scene = makeScene()
            scene.reduceMotion = reduceMotion
            scene.effectsIntensity = effects
            scene.setGravityReading(Pose.landscapeRight.reading, smoothing: false)
            XCTAssertEqual(scene.appliedGravityVector.dx, 7.2, accuracy: 1e-9)
            XCTAssertEqual(scene.opticalTiltFraction, followsLight ? 1 : 0, accuracy: 1e-9, "\(effects) RM \(reduceMotion)")
        }
    }

    // MARK: Taps and shakes against gravity

    func testTheGestureFrameIsExactlyTheScreenForAnUprightPhone() {
        let frame = JarGestureFrame(gravity: Constants.Jar.gravityVector)
        XCTAssertEqual(frame.up, CGVector(dx: 0, dy: 1))
        XCTAssertEqual(frame.across, CGVector(dx: 1, dy: 0))
        var seed: UInt64 = 0x5EED
        for _ in 0 ..< 200 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let vector = CGVector(
                dx: CGFloat(Int64(bitPattern: seed >> 11) % 100_000) / 97,
                dy: CGFloat(Int64(bitPattern: seed >> 23) % 100_000) / -89
            )
            XCTAssertEqual(frame.components(of: vector), vector)
            XCTAssertEqual(frame.vector(from: vector), vector)
        }
        let upsideDown = JarGestureFrame(gravity: CGVector(dx: 0, dy: 7.2))
        XCTAssertEqual(upsideDown.up.dy, -1)
        XCTAssertEqual(upsideDown.across.dx, -1)
        let left = JarGestureFrame(gravity: CGVector(dx: -7.2, dy: 0))
        XCTAssertEqual(left.up.dx, 1)
        XCTAssertEqual(JarScene.velocity(CGVector(dx: 3, dy: 40), withComponent: -130, along: frame.up), CGVector(dx: 3, dy: -130))
    }

    func testATapThrowsAGemAgainstGravityAndReturnsItAlongGravity() async throws {
        for pose in [Pose.upsideDown, .landscapeLeft, .portrait] {
            let scene = makeScene()
            let descriptor = loose(1)
            scene.restore(pebbles: [descriptor])
            scene.setGravityReading(pose.reading, smoothing: false)
            let pebble = try node(scene, descriptor.id)
            let body = try XCTUnwrap(pebble.physicsBody)
            let interior = JarScene.interiorRect(sceneSize: scene.size)
            // Resting where that gravity puts it.
            switch pose {
            case .upsideDown: pebble.position = CGPoint(x: interior.midX, y: interior.maxY - pebble.radius)
            case .landscapeLeft: pebble.position = CGPoint(x: interior.minX + pebble.radius, y: interior.midY)
            default: break
            }
            body.velocity = .zero
            let up = JarGravityMapping.launchDirection(for: scene.appliedGravityVector)
            let start = pebble.position
            XCTAssertTrue(scene.bouncePebbles(at: pebble.position), "\(pose)")
            let along = body.velocity.dx * up.dx + body.velocity.dy * up.dy
            XCTAssertGreaterThan(along, 200, "\(pose): launched against gravity")
            let moved = (pebble.position.x - start.x) * up.dx + (pebble.position.y - start.y) * up.dy
            XCTAssertGreaterThan(moved, 0, "\(pose): the launch clearance is against gravity")

            // No physics frames here: the bounded deferral chooses the return.
            let deadline = Date().addingTimeInterval(3)
            while scene.activeTapDrivenBodyCount > 0, Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            let returning = body.velocity.dx * up.dx + body.velocity.dy * up.dy
            XCTAssertLessThanOrEqual(returning, -130 + 0.001, "\(pose): the return runs along gravity")
        }
    }

    func testAShakeThrowsTheGemsAgainstGravity() {
        for pose in [Pose.upsideDown, .landscapeLeft, .landscapeRight] {
            let scene = makeScene()
            scene.restore(pebbles: looseSeries(6))
            scene.setGravityReading(pose.reading, smoothing: false)
            XCTAssertTrue(scene.shakePebbles(strength: 1, horizontal: 0.5), "\(pose)")
            let up = JarGravityMapping.launchDirection(for: scene.appliedGravityVector)
            for pebble in pebbles(scene) {
                let velocity = pebble.physicsBody?.velocity ?? .zero
                XCTAssertGreaterThan(velocity.dx * up.dx + velocity.dy * up.dy, 0, "\(pose)")
                XCTAssertLessThanOrEqual(abs(velocity.dx * up.dx + velocity.dy * up.dy), Constants.Jar.shakeMaximumVerticalVelocity + 0.001)
            }
        }
    }

    // MARK: Pile light, clearances, share

    func testThePileLightFollowsAPileRestingAgainstTheCap() {
        let size = CGSize(width: 390, height: Constants.Jar.height)
        let interior = JarScene.interiorRect(sceneSize: size)
        let outer = JarScene.outerJarRect(sceneSize: size)
        let atCap = CGRect(x: interior.midX - 60, y: interior.maxY - 70, width: 120, height: 70)
        let floorBand = JarScene.pileLightFrame(bodies: atCap, jar: outer, interior: interior, bedTop: interior.minY + 30)
        XCTAssertLessThanOrEqual(floorBand.midY, interior.minY + 30 + 40 + 0.001, "On the floor, as before")
        let following = JarScene.pileLightFrame(
            bodies: atCap,
            jar: outer,
            interior: interior,
            bedTop: interior.minY + 30,
            seatedOnFloor: false
        )
        XCTAssertGreaterThan(following.midY, interior.midY, "Follows the bodies at the cap")
        XCTAssertLessThanOrEqual(following.maxY, interior.maxY + 0.001)
        XCTAssertEqual(following.size, floorBand.size)
    }

    func testAPileRestingAtTheCapNeverStepsTheJarScaleForTheCore() throws {
        let scene = makeScene()
        scene.restore(pebbles: looseSeries(5))
        let interior = JarScene.interiorRect(sceneSize: scene.size)
        let clearance = JarPileClearance(minX: 0, maxX: scene.size.width, ceiling: interior.midY, minimumScale: 1)
        scene.pileClearances = [clearance]
        let scaleBefore = scene.jarScale
        let changesBefore = scene.jarScaleChangeCount
        let driver = try Driver(scene: scene)
        defer { driver.finish() }
        driver.step(frames: 60 * 8) {
            if !scene.isIdlePaused { scene.setGravityReading(Pose.upsideDown.reading) }
        }
        XCTAssertTrue(scene.isIdlePaused)
        XCTAssertFalse(scene.pileRestsOnTheFloor)
        let top = pebbles(scene).map { $0.position.y + $0.radius }.max() ?? 0
        XCTAssertNotNil(
            clearance.steppedScale(current: scene.jarScale, top: top, floor: interior.minY),
            "Measured from the floor, this pile would step the scale down"
        )
        XCTAssertEqual(scene.jarScale, scaleBefore)
        XCTAssertEqual(scene.jarScaleChangeCount, changesBefore)
    }

    func testShareUsesTheDrawnBottleForAPileRestingOffTheFloor() throws {
        let scene = makeScene()
        scene.restore(pebbles: looseSeries(4))
        XCTAssertTrue(ShareJarSnapshotPolicy.pileRestsOnTheFloor(in: scene))
        scene.setGravityReading(Pose.upsideDown.reading, smoothing: false)
        XCTAssertFalse(ShareJarSnapshotPolicy.pileRestsOnTheFloor(in: scene))
        scene.setGravityReading(Pose.landscapeLeft.reading, smoothing: false)
        XCTAssertFalse(ShareJarSnapshotPolicy.pileRestsOnTheFloor(in: scene))
        let tilted = try XCTUnwrap(JarGravityMapping.Reading(deviceGravityX: 0.5, deviceGravityY: -(0.75).squareRoot(), deviceGravityZ: 0))
        scene.setGravityReading(tilted, smoothing: false)
        XCTAssertTrue(ShareJarSnapshotPolicy.pileRestsOnTheFloor(in: scene), "A 30° tilt still rests on the floor")
        XCTAssertTrue(ShareJarSnapshotPolicy.pileRestsOnTheFloor(in: SKScene(size: CGSize(width: 10, height: 10))))
    }

    // MARK: Headroom under the default gravity (D4, §7.5)

#if DEBUG && targetEnvironment(simulator)
    func testTheWorstCaseFixtureKeepsItsMouthHeadroomUnderDownwardGravity() throws {
        // The settle probe's method (§7.5): the first settle, then ten full
        // shakes alternating sides, each measured once the jar rests. The
        // fixture's stage (GemShowcaseFixtureLaunchView): 320 + 40 pt tall,
        // the screen width less 16 pt — iPhone 17 Pro (402) and 12 mini (375).
        for width: CGFloat in [402 - 16, 375 - 16] {
            let scene = JarScene(size: CGSize(width: width, height: 320 + 40))
            scene.soundEnabled = false
            scene.hapticsEnabled = false
            scene.bakesGemBedInBackground = false
            scene.restore(pebbles: GemShowcaseUITestFixture.worstCaseDescriptors())
            scene.setScreenTimeObstacles(totalUnits: 9_999)
            let driver = try Driver(scene: scene)
            defer { driver.finish() }
            var minimum = CGFloat.greatestFiniteMagnitude
            var series: [String] = []
            for settle in 0 ... 10 {
                if settle > 0 {
                    let shaken = Date()
                    while !scene.shakePebbles(strength: 1, horizontal: settle.isMultiple(of: 2) ? 1 : -1),
                          Date().timeIntervalSince(shaken) < 3 {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                }
                let started = Date()
                while !scene.isIdlePaused, Date().timeIntervalSince(started) < 25 {
                    driver.step(frames: 30) {
                        scene.setGravityReading(Pose.portrait.reading)
                        self.assertContained(scene, "worstcase \(width) settle \(settle)")
                    }
                }
                XCTAssertTrue(scene.isIdlePaused, "width \(width) settle \(settle)")
                minimum = min(minimum, scene.pileHeadroomFraction)
                series.append(String(format: "%.3f@%.2f", scene.pileHeadroomFraction, scene.jarScale))
            }
            print("F3 worstcase \(width) headroom series: \(series.joined(separator: " "))")
            XCTAssertGreaterThanOrEqual(minimum, 0.15, "Width \(width): mouth headroom (min over 11 settles): \(series)")
        }
    }

    func testThePoseScheduleParsesTheSimulatorPoses() {
        let schedule = JarGravitySchedule(parsing: "portrait,landscape-left@4,upside-down@12,flat@20")
        XCTAssertEqual(schedule?.pose(elapsed: 0), .portrait)
        XCTAssertEqual(schedule?.pose(elapsed: 5), .landscapeLeft)
        XCTAssertEqual(schedule?.pose(elapsed: 13), .upsideDown)
        XCTAssertEqual(schedule?.pose(elapsed: 30), .flat)
        XCTAssertEqual(JarGravitySchedule(parsing: "landscape-right")?.pose(elapsed: 9), .landscapeRight)
        XCTAssertNil(JarGravitySchedule(parsing: "sideways"))
        XCTAssertNil(JarGravitySchedule(parsing: "portrait@x"))
        for pose in JarGravityPose.allCases {
            let gravity = pose.gravity
            XCTAssertEqual(gravity.x * gravity.x + gravity.y * gravity.y + gravity.z * gravity.z, 1, accuracy: 1e-12)
        }
    }
#endif

    // MARK: Helpers

    private enum Pose: CaseIterable, CustomStringConvertible {
        case portrait
        case landscapeLeft
        case landscapeRight
        case upsideDown
        case flat
        case faceDown

        var gravity: (x: Double, y: Double, z: Double) {
            switch self {
            case .portrait: (0, -1, 0)
            case .landscapeLeft: (-1, 0, 0)
            case .landscapeRight: (1, 0, 0)
            case .upsideDown: (0, 1, 0)
            case .flat: (0, 0, -1)
            case .faceDown: (0, 0, 1)
            }
        }

        var reading: JarGravityMapping.Reading {
            JarGravityMapping.Reading(deviceGravityX: gravity.x, deviceGravityY: gravity.y, deviceGravityZ: gravity.z)!
        }

        var description: String {
            switch self {
            case .portrait: "portrait"
            case .landscapeLeft: "landscape-left"
            case .landscapeRight: "landscape-right"
            case .upsideDown: "upside-down"
            case .flat: "flat"
            case .faceDown: "face-down"
            }
        }
    }

    /// Drives one scene through SpriteKit's full update cycle without a
    /// window, at a fixed frame rate.
    @MainActor
    private final class Driver {
        let scene: JarScene
        private let renderer: SKRenderer
        private var time: TimeInterval

        init(scene: JarScene) throws {
            let device = try XCTUnwrap(
                MTLCreateSystemDefaultDevice(),
                "The SpriteKit renderer needs a Metal device to drive its scene update cycle"
            )
            self.scene = scene
            renderer = SKRenderer(device: device)
            let size = scene.size
            // A renderer without a viewport must keep the jar's size.
            scene.scaleMode = .aspectFit
            renderer.scene = scene
            scene.didChangeSize(.zero)
            XCTAssertEqual(scene.size, size)
            time = ProcessInfo.processInfo.systemUptime
            renderer.update(atTime: time)
        }

        func step(frames: Int, fps: Double = 60, each: (() -> Void)? = nil) {
            for _ in 0 ..< frames {
                time += 1 / fps
                renderer.update(atTime: time)
                each?()
            }
        }

        func finish() {
            scene.onLanding = nil
            renderer.scene = nil
        }
    }

    private func makeScene(size: CGSize = CGSize(width: 390, height: Constants.Jar.height)) -> JarScene {
        let scene = JarScene(size: size)
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.bakesGemBedInBackground = false
        return scene
    }

    private func pebbles(_ scene: JarScene) -> [PebbleNode] {
        var found: [PebbleNode] = []
        scene.enumerateChildNodes(withName: "//*") { node, _ in
            if let pebble = node as? PebbleNode, !pebble.isRemovedForBake { found.append(pebble) }
        }
        return found
    }

    private func node(_ scene: JarScene, _ id: UUID, file: StaticString = #filePath, line: UInt = #line) throws -> PebbleNode {
        try XCTUnwrap(scene.childNode(withName: "//pebble.\(id.uuidString)") as? PebbleNode, file: file, line: line)
    }

    /// Every body's center stays inside the jar's interior; a body above
    /// the collar must be a gem that has not landed, inside the neck.
    private func assertContained(_ scene: JarScene, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let interior = JarScene.interiorRect(sceneSize: scene.size)
        let outer = JarScene.outerJarRect(sceneSize: scene.size)
        let neckInset = JarScene.neckInset(jarWidth: outer.width)
        for pebble in pebbles(scene) {
            let point = pebble.position
            guard point.x.isFinite, point.y.isFinite else {
                XCTFail("\(context): a body left the simulation", file: file, line: line)
                return
            }
            if point.y > interior.maxY {
                XCTAssertFalse(pebble.hasLanded, "\(context): only an entering gem is above the collar", file: file, line: line)
                XCTAssertGreaterThanOrEqual(point.x, outer.minX + neckInset + Constants.Jar.wallInset - 1, "\(context): in the neck", file: file, line: line)
                XCTAssertLessThanOrEqual(point.x, outer.maxX - neckInset - Constants.Jar.wallInset + 1, "\(context): in the neck", file: file, line: line)
                XCTAssertLessThanOrEqual(point.y, scene.size.height + pebble.radius, "\(context): never back out above the stage", file: file, line: line)
            } else {
                XCTAssertTrue(
                    interior.insetBy(dx: -1, dy: -1).contains(point),
                    "\(context): \(pebble.descriptor.id) at \(point) left the jar",
                    file: file,
                    line: line
                )
            }
        }
    }

    /// Settled bodies lie within the walls, floor and cap with their radius.
    private func assertContainedWithRadius(_ scene: JarScene, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let interior = JarScene.interiorRect(sceneSize: scene.size)
        let tolerance: CGFloat = 3
        for pebble in pebbles(scene) {
            let point = pebble.position
            let radius = pebble.radius
            XCTAssertTrue(
                point.x >= interior.minX + radius - tolerance
                    && point.x <= interior.maxX - radius + tolerance
                    && point.y >= interior.minY + radius - tolerance
                    && point.y <= interior.maxY - radius + tolerance,
                "\(context): \(pebble.descriptor.id) at \(point) (r \(radius)) crosses the containment",
                file: file,
                line: line
            )
        }
    }

    /// While `id` is still above the collar it is held in the neck.
    private func assertEntersThroughTheNeck(_ scene: JarScene, id: UUID, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let pebble = scene.childNode(withName: "//pebble.\(id.uuidString)") as? PebbleNode else { return }
        let interior = JarScene.interiorRect(sceneSize: scene.size)
        guard pebble.position.y + pebble.radius > interior.maxY else { return }
        let outer = JarScene.outerJarRect(sceneSize: scene.size)
        let neckInset = JarScene.neckInset(jarWidth: outer.width)
        let lower = outer.minX + neckInset + Constants.Jar.wallInset + pebble.radius
        let upper = outer.maxX - neckInset - Constants.Jar.wallInset - pebble.radius
        XCTAssertGreaterThanOrEqual(pebble.position.x, lower - 0.5, "\(context): through the mouth", file: file, line: line)
        XCTAssertLessThanOrEqual(pebble.position.x, upper + 0.5, "\(context): through the mouth", file: file, line: line)
        XCTAssertFalse(pebble.hasLanded, "\(context)", file: file, line: line)
    }

    /// The reading of a phone tipping top-down from flat where the jar's
    /// blended gravity is weakest.
    private func weakestGravityReading() -> JarGravityMapping.Reading? {
        var best: (JarGravityMapping.Reading, CGFloat)?
        for step in 0 ... 900 {
            let angle = Double(step) / 10 * .pi / 180
            guard let reading = JarGravityMapping.Reading(
                deviceGravityX: 0,
                deviceGravityY: sin(angle),
                deviceGravityZ: -cos(angle)
            ) else { continue }
            let gravity = JarGravityMapping.gravity(for: reading)
            let magnitude = hypot(gravity.dx, gravity.dy)
            if best == nil || magnitude < best!.1 { best = (reading, magnitude) }
        }
        return best?.0
    }

    // Idle-energy seams (as JarIdleEnergyTests).

    @MainActor
    private final class TestClock {
        var now: TimeInterval = ProcessInfo.processInfo.systemUptime + 1
        func advance(by seconds: TimeInterval) { now += seconds }
    }

    private func makeClockScene() -> (scene: JarScene, clock: TestClock) {
        let scene = makeScene()
        scene.reduceMotion = true
        let clock = TestClock()
        scene.tiltClock = { clock.now }
        return (scene, clock)
    }

    private var settleTime: TimeInterval = 100

    /// Two idle observations `idleWindow` apart with no movement: the jar
    /// idle-pauses; then its redraw and motion holds run out.
    private func rest(_ scene: JarScene, clock: TestClock, file: StaticString = #filePath, line: UInt = #line) {
        let uptime = ProcessInfo.processInfo.systemUptime + settleTime
        scene.evaluateInteractionMotionForTesting(currentTime: settleTime, uptime: uptime)
        settleTime += Constants.Jar.idleWindow + 1
        scene.evaluateInteractionMotionForTesting(
            currentTime: settleTime,
            uptime: uptime + Constants.Jar.interactionHardStopDelay + 1
        )
        settleTime += 1
        clock.advance(by: JarScene.motionWakeHold + JarScene.redrawHold)
        scene.evaluateRenderLoopForTesting()
        XCTAssertTrue(scene.isIdlePaused, "rests", file: file, line: line)
        XCTAssertFalse(scene.wantsFullRateMotion, "idle motion rate", file: file, line: line)
    }

    /// Past the interaction window's hard stop: the jar rests again.
    private func forceRest(_ scene: JarScene, clock: TestClock) {
        rest(scene, clock: clock)
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func sample(_ pose: Pose, tremor: Double = 0) -> JarMotionSample {
        JarMotionSample(
            gravityX: pose.gravity.x + tremor,
            gravityY: pose.gravity.y - tremor,
            gravityZ: pose.gravity.z,
            timestamp: 0
        )
    }

    private func loose(_ index: Int, minutes: Int = 25, isTutorial: Bool = false) -> PebbleDescriptor {
        PebbleDescriptor(
            id: UUID(uuidString: String(format: "F3000000-0000-4000-8000-%012X", index))!,
            subjectName: "英語",
            colorHex: [Constants.Color.english, Constants.Color.science, Constants.Color.japanese][index % 3],
            source: .timer,
            kind: .normal,
            grams: minutes * Constants.Mass.gramsPerMinute,
            createdAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index)),
            isTutorial: isTutorial
        )
    }

    private func looseSeries(_ count: Int) -> [PebbleDescriptor] {
        (0 ..< count).map { loose(10 + $0, minutes: [25, 50, 25, 120, 30][$0 % 5]) }
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
