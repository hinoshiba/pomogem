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
            if index == 3 { XCTAssertTrue(scene.shakePebbles(strength: 1, horizontal: 1), "the shake is accepted") }
            if index == 6 { XCTAssertTrue(scene.bouncePebbles(), "the tap is accepted") }
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
        // Under the entry field a completion drop falls exactly as a body
        // under the physics world's own gravity (0, −7.2) until the collar,
        // however the phone is held.
        var tracks: [Pose: [CGFloat]] = [:]
        for pose in [Pose.portrait, .upsideDown, .landscapeLeft] {
            let scene = makeScene()
            scene.restore(pebbles: [])
            let driver = try Driver(scene: scene)
            defer { driver.finish() }
            scene.setGravityReading(pose.reading, smoothing: false)
            let drop = loose(902)
            scene.dropFromAbove(drop)
            driver.step(frames: 1)
            let gem = try node(scene, drop.id)
            let body = try XCTUnwrap(gem.physicsBody)
            XCTAssertEqual(scene.entryPhaseNameForTesting(drop.id), "throughMouth", "\(pose)")
            // A control body beside it under the world's gravity, with the
            // same damping, mass and velocity; it collides with nothing and
            // feels no field. Only upright is the world's gravity the jar's
            // own.
            var control: SKNode?
            if pose == .portrait {
                let node = SKNode()
                node.position = gem.position
                let controlBody = SKPhysicsBody(circleOfRadius: gem.radius)
                controlBody.mass = body.mass
                controlBody.linearDamping = body.linearDamping
                controlBody.angularDamping = body.angularDamping
                controlBody.allowsRotation = false
                controlBody.affectedByGravity = true
                controlBody.fieldBitMask = 0
                controlBody.categoryBitMask = 0
                controlBody.collisionBitMask = 0
                controlBody.contactTestBitMask = 0
                controlBody.velocity = CGVector(dx: 0, dy: body.velocity.dy)
                node.physicsBody = controlBody
                try XCTUnwrap(gem.parent).addChild(node)
                control = node
            }
            var track: [CGFloat] = []
            let interior = JarScene.interiorRect(sceneSize: scene.size)
            driver.step(frames: 60) {
                guard let entering = scene.childNode(withName: "//pebble.\(drop.id.uuidString)") as? PebbleNode,
                      entering.position.y + entering.radius > interior.maxY
                else { return }
                track.append(entering.position.y)
                if let control {
                    XCTAssertEqual(entering.position.y, control.position.y, accuracy: 0.05, "the jar's own gravity, frame \(track.count)")
                    XCTAssertEqual(
                        entering.physicsBody?.velocity.dy ?? .nan,
                        control.physicsBody?.velocity.dy ?? 0,
                        accuracy: 0.05,
                        "frame \(track.count)"
                    )
                }
            }
            tracks[pose] = track
        }
        let portrait = try XCTUnwrap(tracks[.portrait])
        XCTAssertGreaterThan(portrait.count, 5)
        XCTAssertGreaterThan((portrait.first ?? 0) - (portrait.last ?? 0), 20, "It falls through the neck")
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

    func testTheUpsideDownJarTakesANewGemFreeOrThroughItsCapPile() throws {
        // Free: an interior drop into an empty jar held upside down spawns
        // clear of everything and joins the jar at once. Crowded: eight gems
        // and the Screen Time stones lie against the cap under the mouth, so
        // a completion drop and an interior drop at the mouth's centre both
        // pass them first (`clearingPile`). Each gem is checked to have
        // spawned before its landing is judged; the queue runs on the
        // frames' clock.
        for crowded in [false, true] {
            let scene = makeScene()
            // Eight study gems: with ten, the queue would wait for a fusion
            // (no persistence owner here).
            scene.restore(pebbles: crowded ? looseSeries(8) : [])
            if crowded { scene.setScreenTimeObstacles(totalUnits: 9_999) }
            scene.interiorDropHorizontalUnitForTesting = 0
            let driver = try Driver(scene: scene)
            defer { driver.finish() }
            settle(scene, driver, holding: Pose.upsideDown.reading)
            var landings: [UUID] = []
            scene.onLanding = { landings.append($0.pebble.id) }
            let drops = crowded ? [loose(905), loose(906, minutes: 90)] : [loose(906, minutes: 90)]
            for drop in drops {
                let isCompletion = crowded && drop.id == loose(905).id
                if isCompletion { scene.dropFromAbove(drop) } else { scene.drop(drop) }
                driver.step(frames: 1) { scene.setGravityReading(Pose.upsideDown.reading) }
                let context = "\(crowded ? "crowded" : "free"), \(isCompletion ? "completion" : "interior") drop"
                XCTAssertEqual(scene.queuedDropCount, 0, "\(context): spawned")
                XCTAssertNoThrow(try node(scene, drop.id), context)
                if !isCompletion {
                    XCTAssertEqual(
                        scene.entryPhaseNameForTesting(drop.id),
                        crowded ? "clearingPile" : nil,
                        "\(context): passes the cap pile only when it spawns into it"
                    )
                }
                driver.step(frames: 240) {
                    scene.setGravityReading(Pose.upsideDown.reading)
                    self.assertContained(scene, context)
                }
                XCTAssertTrue(landings.contains(drop.id), "\(context): landed")
                XCTAssertNil(scene.entryPhaseNameForTesting(drop.id), context)
            }
            XCTAssertEqual(Set(landings), Set(drops.map(\.id)))
            XCTAssertEqual(scene.entryClearingTimeoutCount, 0, "Both cleared the pile on their own")
            assertContainedWithRadius(scene, "upside down, settled")
        }
    }

#if DEBUG && targetEnvironment(simulator)
    func testANewGemThatCannotClearTheCapPileJoinsItAfterTheTimeoutContained() throws {
        // A crowded jar held upside down leaves less room under its pile
        // than the entering body is wide (a ×10万 crystal, as restore
        // overflow can drop): it falls to the floor still inside the pile
        // and joins it there after `clearingTimeout`.
        let scene = makeCrowdedJar()
        let driver = try Driver(scene: scene)
        defer { driver.finish() }
        settle(scene, driver, holding: Pose.upsideDown.reading) { self.assertContained(scene, "crowded, turning") }
        XCTAssertTrue(scene.isIdlePaused)
        // Aim the entry (across the mouth) at the pile's lowest body.
        let interior = JarScene.interiorRect(sceneSize: scene.size)
        let xRange = interior.width * Constants.Jar.dropHorizontalRangeFraction
        let lowest = try XCTUnwrap(
            pebbles(scene)
                .filter { abs($0.position.x - interior.midX) <= xRange }
                .min { $0.position.y - $0.radius < $1.position.y - $1.radius }
        )
        scene.interiorDropHorizontalUnitForTesting = (lowest.position.x - interior.midX) / xRange
        let gap = lowest.position.y - lowest.radius - interior.minY
        XCTAssertLessThan(gap, 48, "Less room under the pile than the crystal is wide")
        let drop = crystal(911, level: 5)
        scene.drop(drop)
        driver.step(frames: 1) { scene.setGravityReading(Pose.upsideDown.reading) }
        let gem = try node(scene, drop.id)
        print(String(format: "F3 crowded cap: room under the pile %.1f pt, entering crystal %.1f pt wide", gap, gem.radius * 2))
        XCTAssertEqual(scene.entryPhaseNameForTesting(drop.id), "clearingPile")
        var joinedAfter: Int?
        var frames = 1
        driver.step(frames: 300) {
            scene.setGravityReading(Pose.upsideDown.reading)
            frames += 1
            if joinedAfter == nil, scene.entryPhaseNameForTesting(drop.id) == nil { joinedAfter = frames }
            self.assertContained(scene, "crowded cap, frame \(frames)")
        }
        XCTAssertEqual(scene.entryClearingTimeoutCount, 1, "It could not clear the pile: the timeout joined it")
        XCTAssertEqual(Double(joinedAfter ?? 0) / 60, 1.5, accuracy: 0.05)
        XCTAssertTrue(scene.hasLandedPebble(withID: drop.id), "Landed (a crystal reports no landing to Home)")
        assertContainedWithRadius(scene, "crowded cap, settled")
    }

    func testUnderDownwardGravityAGemEnteringIntoThePileJoinsItAtOnceAsBeforeF3() throws {
        // The pass-through is for a pile the gravity presses against the
        // cap only: under the jar's own down (and held sideways) a new gem
        // that spawns into a pile reaching the mouth joins it at once. A
        // supported jar keeps more room under the mouth than a gem is wide
        // (the §7.5 headroom), so the pile's highest body is held right
        // under the mouth, where the gem enters, to stand for such a pile.
        for pose in [Pose.portrait, .landscapeLeft] {
            let scene = makeCrowdedJar()
            let driver = try Driver(scene: scene)
            defer { driver.finish() }
            settle(scene, driver, holding: pose.reading)
            let interior = JarScene.interiorRect(sceneSize: scene.size)
            let highest = try XCTUnwrap(pebbles(scene).max { $0.position.y + $0.radius < $1.position.y + $1.radius })
            highest.physicsBody?.isDynamic = false
            highest.position = CGPoint(x: interior.midX, y: interior.maxY - highest.radius - 2)
            scene.interiorDropHorizontalUnitForTesting = 0
            var landings: [UUID] = []
            scene.onLanding = { landings.append($0.pebble.id) }
            let drop = loose(912, minutes: 120)
            scene.drop(drop)
            driver.step(frames: 1) { scene.setGravityReading(pose.reading) }
            XCTAssertEqual(scene.queuedDropCount, 0, "\(pose): spawned into the held body")
            XCTAssertNil(scene.entryPhaseNameForTesting(drop.id), "\(pose)")
            driver.step(frames: 240) {
                scene.setGravityReading(pose.reading)
                self.assertContained(scene, "crowded \(pose)")
            }
            XCTAssertEqual(landings, [drop.id], "\(pose)")
            XCTAssertEqual(scene.entryClearingTimeoutCount, 0, "\(pose)")
        }
    }
#endif

    func testTurningUprightWhileANewGemPassesTheCapPileJoinsItAtOnce() throws {
        let scene = makeScene()
        scene.restore(pebbles: looseSeries(8))
        scene.setScreenTimeObstacles(totalUnits: 9_999)
        scene.interiorDropHorizontalUnitForTesting = 0
        let driver = try Driver(scene: scene)
        defer { driver.finish() }
        settle(scene, driver, holding: Pose.upsideDown.reading)
        var landings: [UUID] = []
        scene.onLanding = { landings.append($0.pebble.id) }
        let drop = loose(913)
        scene.drop(drop)
        driver.step(frames: 1) { scene.setGravityReading(Pose.upsideDown.reading) }
        XCTAssertEqual(scene.entryPhaseNameForTesting(drop.id), "clearingPile")
        // Upright again: the cap pile falls to the floor, and the gem stops
        // passing it and joins at once.
        driver.step(frames: 2) { scene.setGravityReading(Pose.portrait.reading, smoothing: false) }
        XCTAssertNil(scene.entryPhaseNameForTesting(drop.id))
        driver.step(frames: 240) {
            scene.setGravityReading(Pose.portrait.reading)
            self.assertContained(scene, "turned upright mid-pass")
        }
        XCTAssertEqual(landings, [drop.id])
        XCTAssertEqual(scene.entryClearingTimeoutCount, 0)
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

    func testATurnReSettlesTheRestingPileOnTheFramesAndItRestsAgainUnderTheNewPose() throws {
        // The whole energy path on SpriteKit's own frames: an upright pile
        // rests, the phone turns once and is held, the pile moves to the new
        // wall or the cap, rests again within its bounded window and records
        // the pose it settled in; held there, nothing wakes it.
        for turn in [Pose.landscapeRight, .upsideDown] {
            let scene = makeScene()
            scene.restore(pebbles: looseSeries(9))
            let driver = try Driver(scene: scene)
            defer { driver.finish() }
            settle(scene, driver, holding: Pose.portrait.reading)
            XCTAssertTrue(scene.isIdlePaused, "\(turn)")
            let before = centroid(scene)
            let took = settle(scene, driver, holding: turn.reading) {
                self.assertContained(scene, "turned \(turn)")
            }
            XCTAssertTrue(scene.isIdlePaused, "\(turn): rests again")
            XCTAssertGreaterThan(took, 1, "\(turn): the pile moved first")
            XCTAssertLessThanOrEqual(
                took,
                Constants.Jar.interactionHardStopDelay + 1,
                "\(turn): within the window the turn opened"
            )
            let after = centroid(scene)
            switch turn {
            case .landscapeRight: XCTAssertGreaterThan(after.x, before.x + 30, "Toward the right wall")
            default: XCTAssertGreaterThan(after.y, before.y + 60, "Toward the cap")
            }
            XCTAssertEqual(scene.settledReading.x, turn.reading.x, accuracy: 1e-3, "\(turn)")
            XCTAssertEqual(scene.settledReading.y, turn.reading.y, accuracy: 1e-3, "\(turn)")
            assertContainedWithRadius(scene, "turned \(turn), settled")
            for _ in 0 ..< 60 {
                driver.step(frames: 2) { scene.setGravityReading(turn.reading) }
                XCTAssertTrue(scene.isIdlePaused, "\(turn): held still, it keeps resting")
                XCTAssertFalse(scene.isInteractionMotionActive, "\(turn)")
            }
        }
    }

    func testATurnLateInTheInteractionWindowStillLetsThePileFollowIt() throws {
        // A turn while the jar is awake opens the window again from that
        // moment. Before, the window kept its deadlines: flipping back
        // upright 0.7 s before its hard stop froze the pile in mid-flight,
        // recorded the new pose as settled, and nothing woke it again.
        let scene = makeScene()
        scene.restore(pebbles: looseSeries(24))
        let driver = try Driver(scene: scene)
        defer { driver.finish() }
        settle(scene, driver, holding: Pose.portrait.reading)
        XCTAssertTrue(scene.isIdlePaused)
        let upright = centroid(scene)
        let uprightTop = highestTop(scene)
        // Turned onto its left edge and held until 0.7 s before the stop.
        scene.setGravityReading(Pose.landscapeLeft.reading)
        XCTAssertFalse(scene.isIdlePaused)
        var frame = 0
        while let stop = scene.interactionHardStopForTesting, driver.now < stop - 0.7 {
            driver.step(frames: 1) {
                if frame.isMultiple(of: 2) { scene.setGravityReading(Pose.landscapeLeft.reading) }
                frame += 1
            }
        }
        XCTAssertFalse(scene.isIdlePaused, "Still awake late in the window")
        let originalStop = try XCTUnwrap(scene.interactionHardStopForTesting)
        XCTAssertLessThan(centroid(scene).x, upright.x - 30, "The pile lies against the left wall")
        // Flipped upright: the pile falls back and rests on the floor.
        settle(scene, driver, holding: Pose.portrait.reading) {
            self.assertContained(scene, "late flip")
        }
        XCTAssertTrue(scene.isIdlePaused)
        XCTAssertGreaterThan(driver.now, originalStop + 1, "The stop moved with the turn")
        XCTAssertEqual(centroid(scene).y, upright.y, accuracy: 20, "Back on the floor, not frozen in mid-flight")
        XCTAssertLessThanOrEqual(highestTop(scene), uprightTop + 30)
        XCTAssertEqual(scene.settledReading.y, -1, accuracy: 1e-3)
        assertContainedWithRadius(scene, "late flip, settled")
        for _ in 0 ..< 30 {
            driver.step(frames: 2) { scene.setGravityReading(Pose.portrait.reading) }
        }
        XCTAssertTrue(scene.isIdlePaused)
    }

    func testTheFormerIdleTiltNowReSettlesThePileThroughOneBoundedWindow() {
        // Docs/GemExperienceDesign.md §7.13 measured a deliberate tilt of
        // 0.3 g sideways (about 17°) as a light-only redraw. Past the re-settle
        // turn (about 6°) it now also wakes the physics, with or without
        // Reduce Motion, through one bounded window; once the pile rests
        // again under that pose, holding it wakes nothing.
        func tilted(_ gravityX: Double, tremor: Double = 0) -> JarMotionSample {
            JarMotionSample(
                gravityX: gravityX + tremor,
                gravityY: -(1 - gravityX * gravityX).squareRoot() - tremor,
                timestamp: 0
            )
        }
        for reduceMotion in [false, true] {
            let (scene, clock) = makeClockScene()
            scene.reduceMotion = reduceMotion
            scene.restore(pebbles: [loose(1)])
            let source = FakeMotionSource()
            let observer = JarMotionObserver(scene: scene, source: source)
            observer.start(scene: scene)
            defer { observer.stop() }
            source.deliver(tilted(0))
            rest(scene, clock: clock)
            XCTAssertEqual(observer.rate, .idle)

            source.deliver(tilted(0.3))
            drainMainQueue()
            XCTAssertEqual(observer.rate, .full, "Reduce Motion \(reduceMotion)")
            XCTAssertFalse(scene.isIdlePaused, "Reduce Motion \(reduceMotion): the physics wakes")
            let stop = scene.interactionHardStopForTesting
            XCTAssertNotNil(stop, "Reduce Motion \(reduceMotion): a window is open")
            XCTAssertLessThanOrEqual(
                (stop ?? .infinity) - ProcessInfo.processInfo.systemUptime,
                Constants.Jar.interactionHardStopDelay,
                "One bounded window"
            )
            if reduceMotion {
                XCTAssertEqual(scene.opticalTiltFraction, 0, "Reduce Motion keeps the light still")
            } else {
                XCTAssertGreaterThan(scene.opticalTiltFraction, 0.15)
            }
            for _ in 0 ..< 20 { source.deliver(tilted(0.3)) }
            forceRest(scene, clock: clock)
            XCTAssertTrue(scene.isIdlePaused)
            XCTAssertEqual(observer.rate, .idle)
            for index in 0 ..< 10 {
                source.deliver(tilted(0.3, tremor: index.isMultiple(of: 2) ? 0.012 : -0.012))
            }
            drainMainQueue()
            XCTAssertTrue(scene.isIdlePaused, "Reduce Motion \(reduceMotion): held there, nothing wakes")
            XCTAssertFalse(scene.isInteractionMotionActive)
        }
    }

    // MARK: Reduce Motion: the calm re-settle (owner ruling 2026-09-27)

    func testUnderReduceMotionATurnReSettlesCalmlyWithoutBounceTumbleOrLight() throws {
        // Owner ruling: a deliberate turn re-settles the pile with or
        // without Reduce Motion. Under Reduce Motion the physics is kept —
        // the pile still goes to the new wall or the cap — but the
        // re-settle is calm: for the window the resting pile's damping is
        // raised (no bounce) and its friction taken away (no tumble: a
        // round gem turns only through friction), and it adds no light or
        // effect. Without Reduce Motion the same turn keeps the ordinary
        // damping and friction, as before. After the window the pile rests
        // with the resting damping and its friction back, and the next wake
        // (a tap) is an ordinary one.
        //
        // The window's hard stop (5 s) freezes whatever still moves, and
        // the idle check (3 s of stillness) cannot end a window whose pile
        // moved in its first 3 s, so every re-settle here rests at the hard
        // stop. The calm pile must therefore have reached the new wall or
        // the cap, and stopped, before it: its settled bounds meet that
        // boundary, and on the last frame before it rests every gem is
        // slower than the pile profile's resting speed.
        //
        // Bounce and tumble are measured over 0.1 s (six frames), so a
        // single frame's contact impulse does not count: the rebound is the
        // pile as a whole (its mean depth) springing back against the new
        // gravity, the push-back any one gem moving back against it, and a
        // tumble a gem turning about itself (its node's rotation, as the
        // eye sees it). While the frictionless calm pile levels, a gem can
        // still be pushed back slowly by a neighbour sliding deeper (under
        // the cap, up to about 57 pt/s); the pile itself never springs back.
        struct Motion {
            var rebound: CGFloat = 0
            var bounce: CGFloat = 0
            var tumble: CGFloat = 0
            var lastFrameSpeed: CGFloat = 0
            /// The settled pile's depth along the new gravity.
            var depth: CGFloat = 0
        }
        let window = 6
        for turn in [Pose.upsideDown, .landscapeRight, .landscapeLeft] {
            var motions: [Bool: Motion] = [:]
            for reduceMotion in [false, true] {
                let context = "\(turn), Reduce Motion \(reduceMotion)"
                let scene = makeScene()
                scene.reduceMotion = reduceMotion
                scene.restore(pebbles: looseSeries(9))
                let driver = try Driver(scene: scene)
                defer { driver.finish() }
                settle(scene, driver, holding: Pose.portrait.reading)
                XCTAssertTrue(scene.isIdlePaused, context)
                XCTAssertFalse(scene.isCalmResettleActive, context)
                let before = centroid(scene)
                let light = lightState(scene)
                let finalGravity = JarGravityMapping.gravity(for: turn.reading)
                let finalLength = max(hypot(finalGravity.dx, finalGravity.dy), 1e-9)
                let down = CGVector(dx: finalGravity.dx / finalLength, dy: finalGravity.dy / finalLength)
                // Per body: its depth along the new gravity and how far it
                // has turned, frame by frame, once the gravity has turned.
                var depths: [ObjectIdentifier: [CGFloat]] = [:]
                var pileDepths: [CGFloat] = []
                var turns: [ObjectIdentifier: [CGFloat]] = [:]
                var rotations: [ObjectIdentifier: CGFloat] = [:]
                var motion = Motion()
                var sawWindow = false
                let took = settle(scene, driver, holding: turn.reading) {
                    guard !scene.isIdlePaused else { return }
                    sawWindow = true
                    self.assertContained(scene, context)
                    XCTAssertEqual(scene.isCalmResettleActive, reduceMotion, context)
                    let gravity = scene.physicsWorld.gravity
                    let turned = (gravity.dx * down.dx + gravity.dy * down.dy)
                        / max(hypot(gravity.dx, gravity.dy), 1e-9) > cos(5 * .pi / 180)
                    var fastest: CGFloat = 0
                    var pileDepth: CGFloat = 0
                    var landed = 0
                    for pebble in self.pebbles(scene) where pebble.hasLanded {
                        guard let body = pebble.physicsBody else { continue }
                        fastest = max(fastest, hypot(body.velocity.dx, body.velocity.dy))
                        if reduceMotion {
                            XCTAssertEqual(body.linearDamping, Constants.Jar.calmResettleLinearDamping, accuracy: 1e-6, context)
                            XCTAssertEqual(body.angularDamping, Constants.Jar.calmResettleAngularDamping, accuracy: 1e-6, context)
                            XCTAssertEqual(body.friction, Constants.Jar.calmResettleFriction, accuracy: 1e-6, "\(context): the calm pile slides without friction")
                        } else {
                            XCTAssertLessThanOrEqual(body.linearDamping, Constants.Jar.interactionSettlingDamping + 1e-6, context)
                            XCTAssertLessThanOrEqual(body.angularDamping, Constants.Jar.interactionSettlingDamping + 1e-6, context)
                            XCTAssertEqual(body.friction, Constants.Jar.friction, accuracy: 1e-6, context)
                        }
                        let id = ObjectIdentifier(pebble)
                        let rotation = pebble.zRotation
                        let step = rotations[id].map { abs((rotation - $0).remainder(dividingBy: 2 * .pi)) } ?? 0
                        rotations[id] = rotation
                        guard turned else { continue }
                        let depth = pebble.position.x * down.dx + pebble.position.y * down.dy
                        depths[id, default: []].append(depth)
                        turns[id, default: []].append((turns[id]?.last ?? 0) + step)
                        pileDepth += depth
                        landed += 1
                    }
                    if landed > 0 { pileDepths.append(pileDepth / CGFloat(landed)) }
                    // The frame before the pile rests is the last one seen.
                    motion.lastFrameSpeed = fastest
                    if reduceMotion {
                        // No light and no effect: the light rig, the glints
                        // and the pile light's swell stay as they were, and
                        // no dust, spark, landing light or twinkle appears.
                        XCTAssertEqual(self.lightState(scene), light, context)
                        XCTAssertEqual(self.effectNodeCount(scene), 0, context)
                        XCTAssertFalse(self.pebbles(scene).contains(where: \.isGemTwinkling), context)
                    }
                }
                XCTAssertTrue(sawWindow, "\(context): the turn woke the pile")
                XCTAssertTrue(scene.isIdlePaused, "\(context): rests again")
                XCTAssertLessThanOrEqual(took, Constants.Jar.interactionHardStopDelay + 1, context)
                XCTAssertFalse(scene.isCalmResettleActive, context)
                // The pile went all the way: it rests against the new wall
                // or the cap (the same check as the HUD's bounds test).
                let interior = JarScene.interiorRect(sceneSize: scene.size)
                let bounds = try XCTUnwrap(scene.settledPileBounds, context)
                switch turn {
                case .landscapeRight:
                    XCTAssertEqual(bounds.maxX, interior.maxX, accuracy: 8, "\(context): against the right wall")
                    motion.depth = bounds.width
                case .landscapeLeft:
                    XCTAssertEqual(bounds.minX, interior.minX, accuracy: 8, "\(context): against the left wall")
                    motion.depth = bounds.width
                default:
                    XCTAssertEqual(bounds.maxY, interior.maxY, accuracy: 8, "\(context): against the cap")
                    motion.depth = bounds.height
                }
                // Secondary: the pile as a whole moved that way.
                let after = centroid(scene)
                switch turn {
                case .landscapeRight: XCTAssertGreaterThan(after.x, before.x + 30, "\(context): toward the right wall")
                case .landscapeLeft: XCTAssertLessThan(after.x, before.x - 30, "\(context): toward the left wall")
                default: XCTAssertGreaterThan(after.y, before.y + 60, "\(context): toward the cap")
                }
                assertContainedWithRadius(scene, "\(context), settled")
                for pebble in pebbles(scene) {
                    XCTAssertEqual(pebble.physicsBody?.linearDamping ?? -1, Constants.Jar.restingDamping, accuracy: 1e-6, context)
                    XCTAssertEqual(pebble.physicsBody?.angularDamping ?? -1, Constants.Jar.restingDamping, accuracy: 1e-6, context)
                    XCTAssertEqual(pebble.physicsBody?.friction ?? -1, Constants.Jar.friction, accuracy: 1e-6, "\(context): friction back once it rests")
                }
                for series in depths.values where series.count > window {
                    for index in window ..< series.count {
                        motion.bounce = max(motion.bounce, series[index - window] - series[index])
                    }
                }
                if pileDepths.count > window {
                    for index in window ..< pileDepths.count {
                        motion.rebound = max(motion.rebound, pileDepths[index - window] - pileDepths[index])
                    }
                }
                for series in turns.values where series.count > window {
                    for index in window ..< series.count {
                        motion.tumble = max(motion.tumble, series[index] - series[index - window])
                    }
                }
                motions[reduceMotion] = motion
                print("F3 re-settle \(context): rebound \(motion.rebound) pt, push-back \(motion.bounce) pt and tumble \(motion.tumble) rad per 0.1 s, fastest gem \(motion.lastFrameSpeed) pt/s on the last frame, depth \(motion.depth) pt, bounds \(bounds) in \(interior), rested after \(took) s")
                if reduceMotion {
                    // The hard stop never freezes a calm pile still sliding.
                    XCTAssertLessThan(motion.lastFrameSpeed, JarScene.pileProfileRestingSpeed, "\(context): at rest before the hard stop")
                }

                // The next wake is an ordinary one: a tap under Reduce
                // Motion behaves as it always has.
                let tapped = try XCTUnwrap(pebbles(scene).first)
                XCTAssertTrue(scene.bouncePebbles(at: tapped.position), context)
                XCTAssertFalse(scene.isCalmResettleActive, context)
                for pebble in pebbles(scene) where pebble !== tapped {
                    XCTAssertEqual(pebble.physicsBody?.linearDamping ?? -1, Constants.Jar.linearDamping, accuracy: 1e-6, context)
                    XCTAssertEqual(pebble.physicsBody?.angularDamping ?? -1, Constants.Jar.angularDamping, accuracy: 1e-6, context)
                    XCTAssertEqual(pebble.physicsBody?.friction ?? -1, Constants.Jar.friction, accuracy: 1e-6, context)
                }
                scene.cancelInteractionPresentation()
            }
            let calm = try XCTUnwrap(motions[true])
            let ordinary = try XCTUnwrap(motions[false])
            // Measured (iPhone 17 Pro Simulator), per 0.1 s: calm rebound
            // 0.04–0.34 pt, push-back 1.2–5.7 pt, tumble below 2e-6 rad;
            // ordinary push-back 4.2–16 pt (the upside-down pile slams into
            // the cap and springs back) and tumble 0.77–1.4 rad.
            XCTAssertLessThan(calm.rebound, 1, "\(turn): no bounce")
            XCTAssertLessThan(calm.bounce, 7, "\(turn): no gem springs back")
            XCTAssertLessThan(calm.bounce, ordinary.bounce, "\(turn)")
            XCTAssertLessThan(calm.tumble, 0.02, "\(turn): no tumble")
            XCTAssertLessThan(calm.tumble, ordinary.tumble, "\(turn)")
            // The calm pile piles up against the new boundary as tightly as
            // the ordinary one: no gem hangs across the jar, held by its
            // neighbours (a pile that can neither roll nor slip jams).
            XCTAssertLessThanOrEqual(calm.depth, ordinary.depth + 40, "\(turn): piled at the boundary")
        }
    }

    func testTheCalmReSettleEndsWhenATapTakesOverOrReduceMotionTurnsOff() throws {
        let scene = makeScene()
        scene.reduceMotion = true
        scene.restore(pebbles: looseSeries(9))
        let driver = try Driver(scene: scene)
        defer { driver.finish() }
        settle(scene, driver, holding: Pose.portrait.reading)
        XCTAssertTrue(scene.isIdlePaused)

        // Reduce Motion turned off mid-window: the pile keeps following the
        // turn with its ordinary damping.
        for _ in 0 ..< 12 {
            driver.step(frames: 2) { scene.setGravityReading(Pose.landscapeLeft.reading) }
        }
        XCTAssertFalse(scene.isIdlePaused)
        XCTAssertTrue(scene.isCalmResettleActive)
        XCTAssertTrue(pebbles(scene).allSatisfy {
            $0.physicsBody?.linearDamping == Constants.Jar.calmResettleLinearDamping
                && $0.physicsBody?.friction == Constants.Jar.calmResettleFriction
        })
        scene.reduceMotion = false
        XCTAssertFalse(scene.isCalmResettleActive)
        XCTAssertTrue(scene.isInteractionMotionActive, "The re-settle itself goes on")
        for pebble in pebbles(scene) {
            XCTAssertEqual(pebble.physicsBody?.linearDamping ?? -1, Constants.Jar.linearDamping, accuracy: 1e-6)
            XCTAssertEqual(pebble.physicsBody?.angularDamping ?? -1, Constants.Jar.angularDamping, accuracy: 1e-6)
            XCTAssertEqual(pebble.physicsBody?.friction ?? -1, Constants.Jar.friction, accuracy: 1e-6)
        }
        settle(scene, driver, holding: Pose.landscapeLeft.reading)
        XCTAssertTrue(scene.isIdlePaused)

        // A tap mid-window takes the jar over: its gem flies with the tap's
        // damping and the rest of the pile gets the ordinary damping back.
        scene.reduceMotion = true
        for _ in 0 ..< 12 {
            driver.step(frames: 2) { scene.setGravityReading(Pose.portrait.reading) }
        }
        XCTAssertTrue(scene.isCalmResettleActive)
        let tapped = try XCTUnwrap(pebbles(scene).min { $0.position.y < $1.position.y })
        XCTAssertTrue(scene.bouncePebbles(at: tapped.position))
        XCTAssertFalse(scene.isCalmResettleActive)
        let flying = pebbles(scene).filter { ($0.physicsBody?.linearDamping ?? 1) < Constants.Jar.linearDamping - 1e-6 }
        XCTAssertEqual(flying.count, 1, "Only the tapped gem flies with the tap's damping")
        for pebble in pebbles(scene) where !flying.contains(where: { $0 === pebble }) {
            XCTAssertEqual(pebble.physicsBody?.linearDamping ?? -1, Constants.Jar.linearDamping, accuracy: 1e-6)
            XCTAssertEqual(pebble.physicsBody?.angularDamping ?? -1, Constants.Jar.angularDamping, accuracy: 1e-6)
        }
        XCTAssertTrue(
            pebbles(scene).allSatisfy { $0.physicsBody?.friction == Constants.Jar.friction },
            "The tapped gem and the pile have their friction back"
        )

        // A turn while the tapped gem flies re-settles the rest calmly and
        // leaves the tap's own damping alone.
        let flyingDamping = try XCTUnwrap(flying.first?.physicsBody?.linearDamping)
        driver.step(frames: 2) { scene.setGravityReading(Pose.landscapeRight.reading, smoothing: false) }
        XCTAssertTrue(scene.isCalmResettleActive)
        XCTAssertEqual(flying.first?.physicsBody?.linearDamping ?? -1, flyingDamping, accuracy: 1e-6)
        XCTAssertEqual(flying.first?.physicsBody?.friction ?? -1, Constants.Jar.friction, accuracy: 1e-6, "The tap owns its gem")
        XCTAssertTrue(pebbles(scene).filter { pebble in
            pebble.hasLanded && !flying.contains { $0 === pebble }
        }.allSatisfy {
            $0.physicsBody?.linearDamping == Constants.Jar.calmResettleLinearDamping
                && $0.physicsBody?.friction == Constants.Jar.calmResettleFriction
        })
        settle(scene, driver, holding: Pose.landscapeRight.reading) {
            self.assertContained(scene, "tap, then turn")
        }
        XCTAssertTrue(scene.isIdlePaused)
        XCTAssertFalse(scene.isCalmResettleActive)
        for pebble in pebbles(scene) {
            XCTAssertEqual(pebble.physicsBody?.linearDamping ?? -1, Constants.Jar.restingDamping, accuracy: 1e-6)
            XCTAssertEqual(pebble.physicsBody?.friction ?? -1, Constants.Jar.friction, accuracy: 1e-6)
        }
    }

    func testUnderReduceMotionATurnDuringAShakeLeavesTheShakenPileItsOrdinaryDamping() throws {
        // A shake throws the pile as it always has, Reduce Motion or not,
        // and a shaking wrist turns the phone too. A turn inside the
        // shake's window still re-settles the pile under the new gravity
        // (the window follows it), but it never calms the shaken pile:
        // until that pile rests, its gems keep the ordinary damping and
        // their spin. Once it rests, the next turn re-settles calmly again.
        let scene = makeScene()
        scene.reduceMotion = true
        scene.restore(pebbles: looseSeries(9))
        let driver = try Driver(scene: scene)
        defer { driver.finish() }
        settle(scene, driver, holding: Pose.portrait.reading)
        XCTAssertTrue(scene.isIdlePaused)

        func assertOrdinary(_ context: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertFalse(scene.isCalmResettleActive, context, file: file, line: line)
            for pebble in pebbles(scene) {
                XCTAssertLessThanOrEqual(pebble.physicsBody?.linearDamping ?? .infinity, Constants.Jar.interactionSettlingDamping + 1e-6, context, file: file, line: line)
                XCTAssertLessThanOrEqual(pebble.physicsBody?.angularDamping ?? .infinity, Constants.Jar.interactionSettlingDamping + 1e-6, context, file: file, line: line)
                XCTAssertEqual(pebble.physicsBody?.friction ?? -1, Constants.Jar.friction, accuracy: 1e-6, context, file: file, line: line)
            }
        }

        // From rest: a shake, then a turn while the gems still fly.
        XCTAssertTrue(scene.shakePebbles(strength: 1, horizontal: 1))
        driver.step(frames: 6)
        let shakeStop = try XCTUnwrap(scene.interactionHardStopForTesting)
        for _ in 0 ..< 12 {
            driver.step(frames: 2) { scene.setGravityReading(Pose.landscapeLeft.reading) }
        }
        XCTAssertFalse(scene.isIdlePaused)
        XCTAssertGreaterThan(try XCTUnwrap(scene.interactionHardStopForTesting), shakeStop, "The window follows the turn")
        assertOrdinary("shake, then turn")
        settle(scene, driver, holding: Pose.landscapeLeft.reading) {
            guard !scene.isIdlePaused else { return }
            self.assertContained(scene, "shake, then turn")
            assertOrdinary("shake, then turn, settling")
        }
        XCTAssertTrue(scene.isIdlePaused)

        // A calm re-settle a shake takes over stays ordinary through a
        // later turn in the shake's window.
        for _ in 0 ..< 12 {
            driver.step(frames: 2) { scene.setGravityReading(Pose.portrait.reading) }
        }
        XCTAssertTrue(scene.isCalmResettleActive, "The shaken pile rested: a turn is calm again")
        XCTAssertTrue(scene.shakePebbles(strength: 1, horizontal: -1))
        assertOrdinary("calm, then shake")
        for _ in 0 ..< 12 {
            driver.step(frames: 2) { scene.setGravityReading(Pose.landscapeRight.reading) }
        }
        assertOrdinary("calm, then shake, then turn")
        settle(scene, driver, holding: Pose.landscapeRight.reading) {
            guard !scene.isIdlePaused else { return }
            self.assertContained(scene, "calm, then shake, then turn")
            assertOrdinary("calm, then shake, then turn, settling")
        }
        XCTAssertTrue(scene.isIdlePaused)
        assertContainedWithRadius(scene, "calm, then shake, then turn, settled")
    }

    // MARK: The HUD over an upside-down pile (owner ruling 2026-09-27)

    func testTheSettledPileBoundsMeetTheHUDOnlyWhenThePileRestsAtTheCap() throws {
        // Home keeps its metric HUD on top and strengthens its ink scrim
        // while the settled pile's bounds meet the HUD's measured frame
        // (`JarHUDScrimPolicy`). Upright the pile rests on the floor, clear
        // of the HUD; held upside down it rests against the cap, behind it.
        let scene = makeScene()
        scene.restore(pebbles: looseSeries(9))
        let driver = try Driver(scene: scene)
        defer { driver.finish() }
        // Home's stage (the jar card inset 4 pt) and its readout below the
        // mouth (`HomeView.jarMetricHUDTopInset`; the laid-out readout is
        // about 100 pt tall and 170 pt wide at the default text size).
        let stage = CGRect(x: 4, y: 0, width: scene.size.width, height: scene.size.height)
        let outer = JarScene.outerJarRect(sceneSize: scene.size)
        let hudTop = 88 + max(0, scene.size.height - outer.maxY)
        let hud = CGRect(x: stage.midX - 85, y: hudTop, width: 170, height: 100)

        settle(scene, driver, holding: Pose.portrait.reading)
        XCTAssertTrue(scene.isIdlePaused)
        let upright = try XCTUnwrap(scene.settledPileBounds)
        XCTAssertEqual(upright.minY, JarScene.interiorRect(sceneSize: scene.size).minY, accuracy: 8, "On the floor")
        XCTAssertEqual(
            JarHUDScrimPolicy.strength(
                pileBounds: JarHUDScrimPolicy.stageRect(ofScene: upright, stageFrame: stage),
                hudFrame: hud
            ),
            .standard
        )

        settle(scene, driver, holding: Pose.upsideDown.reading)
        XCTAssertTrue(scene.isIdlePaused)
        let capped = try XCTUnwrap(scene.settledPileBounds)
        XCTAssertEqual(capped.maxY, JarScene.interiorRect(sceneSize: scene.size).maxY, accuracy: 8, "Against the cap")
        for pebble in pebbles(scene) {
            let body = CGRect(
                x: pebble.position.x - pebble.radius,
                y: pebble.position.y - pebble.radius,
                width: pebble.radius * 2,
                height: pebble.radius * 2
            )
            XCTAssertTrue(capped.insetBy(dx: -1, dy: -1).contains(body), "Bounds hold every resting body")
        }
        XCTAssertEqual(
            JarHUDScrimPolicy.strength(
                pileBounds: JarHUDScrimPolicy.stageRect(ofScene: capped, stageFrame: stage),
                hudFrame: hud
            ),
            .strengthened
        )

        settle(scene, driver, holding: Pose.portrait.reading)
        XCTAssertEqual(
            JarHUDScrimPolicy.strength(
                pileBounds: JarHUDScrimPolicy.stageRect(ofScene: scene.settledPileBounds, stageFrame: stage),
                hudFrame: hud
            ),
            .standard,
            "Back on the floor, the standard scrim"
        )
    }

    // MARK: Reduce Motion and 控えめ parity

    func testReduceMotionAndSubtleEffectsKeepTheSamePhysicsThroughTurnsAndDrops() throws {
        // SpriteKit does not reproduce a tumbling pile body for body across
        // two scenes (its solver order is not fixed), so parity is checked
        // on what the jar feeds the physics — the gravity every frame, each
        // body's physical setup — and on the outcome: contained, resting on
        // the gravity's side, the completion drop landed. The one physical
        // difference, the calm re-settle's damping and friction under
        // Reduce Motion (owner ruling 2026-09-27), is pinned by
        // `testUnderReduceMotionATurnReSettlesCalmlyWithoutBounceTumbleOrLight`;
        // the setups compared here leave damping and friction out.
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
                    "\(body?.restitution ?? -1)"
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

    func testAShakeTurnsTheGemsMomentumIntoTheGravityFrame() throws {
        // The shake's velocity policy works in the gravity frame (across,
        // up): the gems' current velocity is taken into that frame, the
        // impulse added, the sideways ceiling applied across gravity and the
        // vertical one along it, and the result turned back. Two identical
        // jars are shaken, one at rest and one already moving; the first
        // gives each gem's impulse per mass (these heavy gems stay under
        // both ceilings), the second must equal the policy applied in the
        // frame to its own velocity.
        let horizontalLimit = Constants.Jar.shakeMaximumHorizontalVelocity
        let verticalLimit = Constants.Jar.shakeMaximumVerticalVelocity
        let descriptors = (0 ..< 6).map { loose(20 + $0, minutes: 120) }
        for pose in [Pose.upsideDown, .landscapeLeft, .landscapeRight] {
            func shaken(from initial: (Int) -> CGVector) throws -> (velocities: [CGVector], frame: JarGestureFrame) {
                let scene = makeScene()
                scene.restore(pebbles: descriptors)
                scene.setGravityReading(pose.reading, smoothing: false)
                let bodies = try descriptors.map { try XCTUnwrap(try node(scene, $0.id).physicsBody) }
                for (index, body) in bodies.enumerated() { body.velocity = initial(index) }
                XCTAssertTrue(scene.shakePebbles(strength: 1, horizontal: 0.5), "\(pose)")
                return (bodies.map(\.velocity), JarGestureFrame(gravity: scene.appliedGravityVector))
            }
            let resting = try shaken { _ in .zero }
            let frame = resting.frame
            let impulses = resting.velocities.map { frame.components(of: $0) }
            for impulse in impulses {
                XCTAssertGreaterThan(impulse.dy, 0, "\(pose): thrown against gravity")
                XCTAssertLessThan(abs(impulse.dx), horizontalLimit, "\(pose): under the ceiling")
                XCTAssertLessThan(impulse.dy, verticalLimit, "\(pose): under the ceiling")
            }
            // Three gems already moving fast with the throw (both ceilings
            // bind), three falling along gravity (neither binds).
            let initialComponents = impulses.enumerated().map { index, impulse -> CGVector in
                let side: CGFloat = impulse.dx >= 0 ? 1 : -1
                return index < 3
                    ? CGVector(dx: side * 110, dy: 130)
                    : CGVector(dx: -side * 40, dy: -90)
            }
            let moving = try shaken { frame.vector(from: initialComponents[$0]) }
            XCTAssertEqual(moving.frame, frame)
            for index in descriptors.indices {
                let sum = CGVector(
                    dx: initialComponents[index].dx + impulses[index].dx,
                    dy: initialComponents[index].dy + impulses[index].dy
                )
                let expected = frame.vector(from: CGVector(
                    dx: min(max(sum.dx, -horizontalLimit), horizontalLimit),
                    dy: min(max(sum.dy, -verticalLimit), verticalLimit)
                ))
                let velocity = moving.velocities[index]
                XCTAssertEqual(velocity.dx, expected.dx, accuracy: 1e-3, "\(pose) gem \(index)")
                XCTAssertEqual(velocity.dy, expected.dy, accuracy: 1e-3, "\(pose) gem \(index)")
                let components = frame.components(of: velocity)
                if index < 3 {
                    XCTAssertEqual(abs(components.dx), horizontalLimit, accuracy: 1e-3, "\(pose) gem \(index): the ceiling across gravity")
                    XCTAssertEqual(components.dy, verticalLimit, accuracy: 1e-3, "\(pose) gem \(index): the ceiling along it")
                } else {
                    XCTAssertLessThan(abs(components.dx), horizontalLimit, "\(pose) gem \(index)")
                    XCTAssertLessThan(abs(components.dy), verticalLimit, "\(pose) gem \(index)")
                }
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
        // A pile rests on the floor while its gravity is within 30° of the
        // jar's own down; further over it leans on a wall or lies at the
        // cap, and the share card draws its own bottle
        // (`ShareJarSnapshotPolicy.livePileNeedsDrawnBottle` asks
        // `pileRestsOnTheFloor(in:)`; `hidingLeavesUnsupportedBody` answers
        // only for hidden bodies, and nothing is hidden here).
        let scene = makeScene()
        scene.restore(pebbles: looseSeries(4))
        let options = JarSnapshotOptions.share(includesSelfReported: true)
        XCTAssertTrue(ShareJarSnapshotPolicy.pileRestsOnTheFloor(in: scene))
        XCTAssertFalse(ShareJarSnapshotPolicy.hidingLeavesUnsupportedBody(in: scene, options: options))
        for (degrees, onTheFloor) in [(0.0, true), (10, true), (25, true), (35, false), (60, false), (75, false), (85, false), (90, false), (180, false)] {
            scene.setGravityReading(rolled(degrees), smoothing: false)
            XCTAssertEqual(scene.pileRestsOnTheFloor, onTheFloor, "\(degrees)°")
            XCTAssertEqual(ShareJarSnapshotPolicy.pileRestsOnTheFloor(in: scene), onTheFloor, "\(degrees)°")
            XCTAssertFalse(
                ShareJarSnapshotPolicy.hidingLeavesUnsupportedBody(in: scene, options: options),
                "\(degrees)°: nothing is hidden, so only the floor decides"
            )
            XCTAssertEqual(
                ShareJarSnapshotPolicy.livePileNeedsDrawnBottle(in: scene, options: options),
                !onTheFloor,
                "\(degrees)°: the drawn bottle"
            )
        }
        XCTAssertTrue(ShareJarSnapshotPolicy.pileRestsOnTheFloor(in: SKScene(size: CGSize(width: 10, height: 10))))
    }

    func testThePileComingToRestTellsItsOwnerWhetherItRestsOnTheFloor() throws {
        // Home skips the widget's snapshot while the pile rests off the
        // floor and publishes it from `onIdlePauseChanged` once the pile
        // rests on the floor again: the callback must fire for that rest,
        // with the floor rule already reading the new pose.
        let scene = makeScene()
        scene.restore(pebbles: looseSeries(6))
        let driver = try Driver(scene: scene)
        defer { driver.finish() }
        var rests: [Bool] = []
        scene.onIdlePauseChanged = { [unowned scene] resting in
            if resting { rests.append(scene.pileRestsOnTheFloor) }
        }
        settle(scene, driver, holding: Pose.landscapeLeft.reading)
        XCTAssertEqual(rests, [false], "At rest against the wall: the widget waits")
        settle(scene, driver, holding: Pose.portrait.reading)
        XCTAssertEqual(rests, [false, true], "Back on the floor: the waiting snapshot is published")
        scene.onIdlePauseChanged = nil
    }

    func testATiltedPileNeverStepsTheJarScaleOrLowersItsCap() throws {
        // The core's and the HUD's clearances measure an upright pile's
        // height per screen column. A young jar's pile settles under the
        // HUD's band; the phone then turns slowly onto its side, resting at
        // each angle. Past 15° the heap against the lower wall reads taller
        // per column, and would step the scale down if it were judged; it
        // is not, so the scale, its change count and the cap stay put. The
        // share card and the pile light follow the 30° floor rule.
        let scene = makeScene()
        scene.restore(pebbles: looseSeries(9))
        let driver = try Driver(scene: scene)
        defer { driver.finish() }
        settle(scene, driver, holding: rolled(0))
        XCTAssertTrue(scene.isIdlePaused)
        XCTAssertGreaterThan(scene.jarScale, 1.2, "A young jar")
        let interior = JarScene.interiorRect(sceneSize: scene.size)
        let band = (
            minX: scene.size.width / 2 - JarPileClearance.hudHalfWidth,
            maxX: scene.size.width / 2 + JarPileClearance.hudHalfWidth
        )
        let uprightTop = highestTop(scene, minX: band.minX, maxX: band.maxX)
        let clearance = JarPileClearance(
            minX: band.minX,
            maxX: band.maxX,
            ceiling: uprightTop + 20,
            minimumScale: JarScalePolicy.minimumScale
        )
        scene.pileClearances = [clearance]
        XCTAssertNil(clearance.steppedScale(current: scene.jarScale, top: uprightTop, floor: interior.minY), "The upright pile fits")
        let scale = scene.jarScale
        let changes = scene.jarScaleChangeCount
        let cap = scene.pileHeightCap
        var heapWouldStep = false
        for degrees in [20.0, 40, 60, 75, 85, 90] {
            let took = settle(scene, driver, holding: rolled(degrees)) {
                self.assertContained(scene, "rolled \(degrees)°")
            }
            XCTAssertTrue(scene.isIdlePaused, "\(degrees)°: rests again (after \(took) s)")
            let top = highestTop(scene, minX: band.minX, maxX: band.maxX)
            if clearance.steppedScale(current: scene.jarScale, top: top, floor: interior.minY) != nil {
                heapWouldStep = true
            }
            XCTAssertEqual(scene.jarScale, scale, "\(degrees)°")
            XCTAssertEqual(scene.jarScaleChangeCount, changes, "\(degrees)°")
            XCTAssertEqual(scene.pileHeightCap, cap, "\(degrees)°")
            XCTAssertEqual(scene.pileRestsOnTheFloor, degrees <= 30, "\(degrees)°: the share card and the pile light")
        }
        XCTAssertTrue(heapWouldStep, "Judged per column, a tilted heap would have stepped the scale")
        // The pile light stays on the floor band while the pile rests on
        // the floor, and follows a heap on the wall.
        let outer = JarScene.outerJarRect(sceneSize: scene.size)
        let heap = CGRect(x: interior.maxX - 90, y: interior.minY, width: 90, height: interior.height * 0.8)
        let onWall = JarScene.pileLightFrame(bodies: heap, jar: outer, interior: interior, bedTop: interior.minY + 20, seatedOnFloor: false)
        let onFloor = JarScene.pileLightFrame(bodies: heap, jar: outer, interior: interior, bedTop: interior.minY + 20)
        XCTAssertGreaterThan(onWall.midY, onFloor.midY)
    }

    func testRestoreRowsAreJudgedByTheGravityTheyWillSettleUnder() throws {
        // The pile last rested at the cap; a sheet then covered Home, which
        // resets the gravity without moving the frozen pile. A restore lays
        // new rows on the floor, and they settle under the default gravity:
        // the clearance steps them down before the first draw.
        let scene = makeScene()
        scene.restore(pebbles: looseSeries(9))
        let driver = try Driver(scene: scene)
        defer { driver.finish() }
        settle(scene, driver, holding: Pose.upsideDown.reading)
        XCTAssertTrue(scene.isIdlePaused)
        XCTAssertFalse(scene.pileRestsOnTheFloor)
        scene.resetGravity()
        XCTAssertTrue(scene.isIdlePaused, "The frozen pile stays at the cap")
        let interior = JarScene.interiorRect(sceneSize: scene.size)
        scene.pileClearances = [JarPileClearance(
            minX: 0,
            maxX: scene.size.width,
            ceiling: interior.minY + 30,
            minimumScale: JarScalePolicy.minimumScale
        )]
        XCTAssertEqual(scene.pileHeightCap, JarScalePolicy.maximumScale, "The pile at the cap is not judged")
        scene.restore(pebbles: looseSeries(9))
        XCTAssertLessThan(scene.pileHeightCap, JarScalePolicy.maximumScale, "The rows step before the first draw")
        XCTAssertTrue(scene.pileRestsOnTheFloor)
    }

    // MARK: Landing rules

    func testANewGemHeldAgainstAWallLandsAtItsImpact() throws {
        // Held sideways, a new gem lands the frame gravity presses it
        // against the wall — not later, on the resting fallback (slower
        // than 12 pt/s for 0.2 s).
        for pose in [Pose.landscapeLeft, .landscapeRight] {
            let scene = makeScene()
            scene.restore(pebbles: [])
            scene.interiorDropHorizontalUnitForTesting = pose == .landscapeLeft ? 1 : -1
            let driver = try Driver(scene: scene)
            defer { driver.finish() }
            scene.setGravityReading(pose.reading, smoothing: false)
            var events: [JarLandingEvent] = []
            var landedAtFrame: Int?
            var frame = 0
            scene.onLanding = { event in
                events.append(event)
                if landedAtFrame == nil { landedAtFrame = frame }
            }
            let drop = loose(914, minutes: 50)
            scene.drop(drop)
            // The impact: the first frame the sideways speed collapses.
            var touchedAtFrame: Int?
            var previousSpeed: CGFloat = 0
            driver.step(frames: 120) {
                frame += 1
                scene.setGravityReading(pose.reading)
                guard touchedAtFrame == nil,
                      let gem = scene.childNode(withName: "//pebble.\(drop.id.uuidString)") as? PebbleNode,
                      let velocity = gem.physicsBody?.velocity
                else { return }
                let speed = abs(velocity.dx)
                if previousSpeed > 100, speed < previousSpeed * 0.5 { touchedAtFrame = frame }
                previousSpeed = speed
            }
            XCTAssertEqual(events.count, 1, "\(pose)")
            let touched = try XCTUnwrap(touchedAtFrame, "\(pose): it reached the wall")
            let landed = try XCTUnwrap(landedAtFrame, "\(pose): it landed")
            XCTAssertLessThanOrEqual(abs(landed - touched), 1, "\(pose): landed on the impact, not 0.2 s later")
            XCTAssertGreaterThan(events[0].impactSpeed, JarScene.restingLandingSpeed, "\(pose)")
            let interior = JarScene.interiorRect(sceneSize: scene.size)
            if pose == .landscapeLeft {
                XCTAssertLessThan(events[0].position.x, interior.midX - 40, "\(pose): at the left wall")
            } else {
                XCTAssertGreaterThan(events[0].position.x, interior.midX + 40, "\(pose): at the right wall")
            }
        }
    }

    func testUprightANewGemThrownAgainstAWallLandsOnlyOnTheFloor() throws {
        // Under the jar's own down a wall contact is sideways (90° from
        // gravity), so it never lands a new gem: only the floor or a landed
        // gem does, as before F3.
        let scene = makeScene()
        scene.restore(pebbles: [])
        scene.interiorDropHorizontalUnitForTesting = 1
        let driver = try Driver(scene: scene)
        defer { driver.finish() }
        scene.setGravityReading(Pose.portrait.reading, smoothing: false)
        var events: [JarLandingEvent] = []
        scene.onLanding = { events.append($0) }
        let drop = loose(915, minutes: 50)
        scene.drop(drop)
        driver.step(frames: 1) { scene.setGravityReading(Pose.portrait.reading) }
        let gem = try node(scene, drop.id)
        let body = try XCTUnwrap(gem.physicsBody)
        body.velocity = CGVector(dx: -900, dy: 0)
        // The impact: the first frame the sideways speed collapses.
        var hitTheWall = false
        var previousSpeed: CGFloat = 900
        driver.step(frames: 150) {
            scene.setGravityReading(Pose.portrait.reading)
            let speed = abs(body.velocity.dx)
            if !hitTheWall, previousSpeed > 100, speed < previousSpeed * 0.5 {
                hitTheWall = true
                XCTAssertTrue(events.isEmpty, "No landing at the wall")
            }
            previousSpeed = speed
        }
        XCTAssertTrue(hitTheWall, "It hit the wall")
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        let interior = JarScene.interiorRect(sceneSize: scene.size)
        XCTAssertEqual(event.position.y, interior.minY, accuracy: 3, "Landed on the floor, not at the wall")
    }

    // MARK: main's rounds 13 and 14 in every pose

    func testAKeepsakeCabochonEntersThroughTheMouthLandsAndStaysContainedInEveryPose() throws {
        // Round 13 redrew 記念石 as moonstone cabochons: no facets, the mark
        // engraved in the dome, the physics circle and mass unchanged. Home
        // drops one from above like a completion gem, after its herald
        // (`showSpecialAnticipation`), so it takes the same entry ritual:
        // through the mouth under the jar's own gravity, then the phone's,
        // landing in every pose and never leaving the jar. Its mark stays
        // upright on the screen, like the rest of the jar's screen-fixed
        // art, whichever way the phone is held.
        for pose in Pose.allCases {
            for filled in [false, true] {
                let scene = makeScene()
                scene.reduceMotion = false
                scene.restore(pebbles: filled ? looseSeries(8) + [keepsake(1, .examPass)] : [])
                if filled { scene.setScreenTimeObstacles(totalUnits: 9_999) }
                let driver = try Driver(scene: scene)
                defer { driver.finish() }
                driver.step(frames: 150) { scene.setGravityReading(pose.reading) }
                var landings: [UUID] = []
                scene.onLanding = { landings.append($0.pebble.id) }
                let stone = keepsake(2, .perfectScore)
                scene.dropFromAbove(stone)
                let context = "記念石, \(pose)\(filled ? ", over a pile" : ", empty jar")"
                var entered = false
                var heraldShown = false
                driver.step(frames: 300) {
                    scene.setGravityReading(pose.reading)
                    self.assertContained(scene, context)
                    self.assertEntersThroughTheNeck(scene, id: stone.id, context)
                    if scene.entryPhaseNameForTesting(stone.id) == "throughMouth" { entered = true }
                    if scene.childNode(withName: "//drop.anticipation") != nil { heraldShown = true }
                }
                XCTAssertTrue(heraldShown, "\(context): its herald first, as before F3")
                XCTAssertTrue(entered, "\(context): a completion entry through the mouth")
                XCTAssertEqual(landings, [stone.id], context)
                XCTAssertTrue(scene.completionDropHasLanded, context)
                XCTAssertFalse(scene.hasCompletionDropInFlight, context)
                assertContainedWithRadius(scene, context)
                let node = try node(scene, stone.id)
                XCTAssertNotNil(node.childNode(withName: ".//achievement.sheen"), "\(context): the round-13 cabochon")
                let mark = try XCTUnwrap(node.childNode(withName: ".//achievement.mark"), context)
                XCTAssertEqual(
                    remainder(Double(mark.zRotation + node.zRotation), 2 * .pi),
                    0,
                    accuracy: 1e-6,
                    "\(context): the mark reads upright on the screen"
                )
                let body = try XCTUnwrap(node.physicsBody)
                XCTAssertEqual(body.categoryBitMask, JarPhysicsCategory.pebble, context)
                XCTAssertTrue(body.affectedByGravity, context)
                XCTAssertEqual(body.fieldBitMask, 0, context)
                guard !filled else { continue }
                let interior = JarScene.interiorRect(sceneSize: scene.size)
                switch pose {
                case .upsideDown:
                    XCTAssertGreaterThan(node.position.y, interior.midY, "\(context): settles toward the cap")
                case .landscapeLeft:
                    XCTAssertLessThan(node.position.x, interior.midX, "\(context): drifts to the left wall")
                case .landscapeRight:
                    XCTAssertGreaterThan(node.position.x, interior.midX, "\(context): drifts to the right wall")
                default:
                    XCTAssertLessThan(node.position.y, interior.midY, "\(context): falls to the floor")
                }
            }
        }

        // A pile holding cabochons stays in the jar while the phone flips.
        let scene = makeScene()
        scene.restore(pebbles: looseSeries(16) + (0 ..< 3).map { keepsake(10 + $0, AchievementKind.allCases[$0 % 3]) })
        let driver = try Driver(scene: scene)
        defer { driver.finish() }
        for pose in [Pose.landscapeLeft, .upsideDown, .landscapeRight, .portrait] {
            driver.step(frames: 90) {
                scene.setGravityReading(pose.reading)
                self.assertContained(scene, "cabochons flipping to \(pose)")
            }
        }
        assertContainedWithRadius(scene, "cabochons, settled upright")
    }

    func testTheSceneEdgeFadeHoldsInEveryPoseAndNeverDimsTheBottle() throws {
        // Round 13 moved the light's fade before the SKView's edge into the
        // scene (`JarLightEdgeFade`: one shader on `gl_FragCoord`). Like the
        // light rig, it is fixed to the screen, not to gravity. Held
        // sideways or upside down, the pile and a ×1万's halo press against
        // a wall or the cap, nearer the view's edge than upright, and the
        // pile light follows them there: every body still carries the
        // fade, nothing is left at the view's edge, and nothing inside the
        // bottle is dimmed.
        let stage = CGSize(width: 402, height: 460)
        let outer = JarScene.outerJarRect(sceneSize: stage)
        var strongestUnfadedEdge = 0
        for pose in [Pose.portrait, .landscapeLeft, .landscapeRight, .upsideDown] {
            let scene = makeScene(size: stage)
            scene.restore(pebbles: [crystal(1, level: 4)] + looseSeries(6) + [keepsake(3, .examPass)])
            let driver = try Driver(scene: scene)
            settle(scene, driver, holding: pose.reading)
            XCTAssertTrue(scene.isIdlePaused, "\(pose): rests")
            XCTAssertEqual(scene.pileRestsOnTheFloor, pose == .portrait, "\(pose)")
            assertContainedWithRadius(scene, "\(pose)")
            driver.finish()

            let view = SKView(frame: CGRect(origin: .zero, size: stage))
            view.allowsTransparency = true
            view.presentScene(scene)
            defer { view.presentScene(nil) }
            let fade = scene.lightEdgeFade
            let pileGlow = try XCTUnwrap(scene.childNode(withName: "//jar.pileGlow") as? SKSpriteNode)
            XCTAssertTrue(pileGlow.shader === fade.shader, "\(pose): the pile light")
            for pebble in pebbles(scene) {
                XCTAssertTrue(pebble.lightEdgeFade === fade, "\(pose)")
                let body = try XCTUnwrap(pebble.childNode(withName: "gem.body") as? SKSpriteNode, "\(pose)")
                XCTAssertTrue(body.shader === fade.shader, "\(pose): \(pebble.descriptor.id)")
                XCTAssertEqual(
                    JarLightEdgeFade.coverage(at: pebble.position, stageSize: stage),
                    1,
                    "\(pose): a resting gem sits where the fade leaves it whole"
                )
            }

            fade.isSuspended = true
            let unfaded = try render(scene, in: view)
            let pixelScale = CGFloat(unfaded.width) / stage.width
            XCTAssertTrue(fade.update(stageSize: stage, pixelScale: pixelScale) || fade.pixelScale == pixelScale)
            fade.isSuspended = false
            let faded = try render(scene, in: view)
            strongestUnfadedEdge = max(strongestUnfadedEdge, edgeAlpha(unfaded))
            XCTAssertLessThanOrEqual(edgeAlpha(faded), 1, "\(pose): the light is gone at the view's edge")
            let inside = outer.insetBy(dx: -JarLightEdgeFade.clearance + 1, dy: -JarLightEdgeFade.clearance + 1)
            var largest = 0
            for row in 0 ..< faded.height {
                let y = stage.height - (CGFloat(row) + 0.5) / pixelScale
                guard y > inside.minY, y < inside.maxY else { continue }
                for column in 0 ..< faded.width {
                    let x = (CGFloat(column) + 0.5) / pixelScale
                    guard x > inside.minX, x < inside.maxX else { continue }
                    let index = (row * faded.width + column) * 4
                    for channel in 0 ..< 4 {
                        largest = max(largest, abs(Int(faded.bytes[index + channel]) - Int(unfaded.bytes[index + channel])))
                    }
                }
            }
            XCTAssertLessThanOrEqual(largest, 1, "\(pose): the bottle is never dimmed")
        }
        XCTAssertGreaterThanOrEqual(strongestUnfadedEdge, 12, "Without the fade some pose's light reaches the view's edge")
    }

    func testOffTheFloorTheTopRungHoldsThroughChurnAndOnlyAnUprightPileIsJudged() {
        // Round 13: the top rung's hysteresis reads the uncapped target
        // (`JarScalePolicy.uncappedTargetScale`), so content churn around
        // it steps the jar off once and holds. F3: the core's and the HUD's
        // clearances judge only a pile that settles upright, so the phone's
        // pose never steps the scale. Both hold together: held sideways or
        // upside down the churn steps off the top once and holds, and a
        // clearance the rows reach is not judged (the cap stays up); held
        // upright again, the same rows are judged and step below it.
        let top = JarScalePolicy.maximumScale
        for pose in [Pose.landscapeLeft, .landscapeRight, .upsideDown] {
            let scene = makeScene()
            let interior = JarScene.interiorRect(sceneSize: scene.size)
            let radius = loose(0).radius
            func target(_ count: Int) -> CGFloat {
                JarScalePolicy.uncappedTargetScale(
                    baseArea: JarScalePolicy.baseArea(radii: Array(repeating: radius, count: count)),
                    interiorArea: interior.width * interior.height
                )
            }
            var count = 1
            while target(count + 1) >= top { count += 1 }
            let fewer = (0 ..< count).map { loose(200 + $0) }
            let more = (0 ... count).map { loose(200 + $0) }
            scene.setGravityReading(pose.reading, smoothing: false)
            scene.pileClearances = [JarPileClearance(
                minX: 0,
                maxX: scene.size.width,
                ceiling: interior.minY + 30,
                minimumScale: JarScalePolicy.minimumScale
            )]
            scene.restore(pebbles: fewer)
            XCTAssertEqual(scene.jarScale, top, "\(pose)")
            XCTAssertFalse(scene.pileRestsOnTheFloor, "\(pose)")
            let changes = scene.jarScaleChangeCount
            var scales: [CGFloat] = []
            for round in 0 ..< 12 {
                scene.restore(pebbles: round.isMultiple(of: 2) ? more : fewer)
                scales.append(scene.jarScale)
            }
            XCTAssertEqual(scene.jarScaleChangeCount, changes + 1, "\(pose): one step off the top: \(scales)")
            XCTAssertEqual(scene.jarScale, top / JarScalePolicy.rungRatio, accuracy: 0.000_1, "\(pose)")
            XCTAssertEqual(scene.pileHeightCap, top, "\(pose): the clearance never judges a pile off the floor")

            scene.setGravityReading(Pose.portrait.reading, smoothing: false)
            scene.restore(pebbles: fewer)
            XCTAssertTrue(scene.pileRestsOnTheFloor, "\(pose), then upright")
            XCTAssertLessThan(scene.pileHeightCap, top, "\(pose), then upright: the rows are judged")
            XCTAssertLessThan(scene.jarScale, top / JarScalePolicy.rungRatio, "\(pose), then upright: they step below the band")
        }
    }

    // MARK: Headroom under the default gravity (D4, §7.5)

#if DEBUG && targetEnvironment(simulator)
    func testTheShowcaseFixturesKeepTheirHeadroomUnderDownwardGravityAsBeforeF3() throws {
        // `JarHeadroomReplica`: the fixture's own scene size, restore and
        // resize, then the settle probe's first settle and ten full shakes,
        // on the frames' clock. The same replica on the base commit
        // (fff5031, with only `interactionClock` added) gave, over six runs
        // per worst case and two per stress jar, a lowest settle of
        // worstcase 0.187–0.214 (17 Pro) and 0.138–0.172 (12 mini), stress
        // 0.211–0.214 and 0.150–0.152. Under the jar's own down F3 changes
        // nothing a restore and a shake reach, so each run must stay within
        // that spread (0.025 below the base's lowest run). The 15 % bound
        // itself is the in-app settle probe's (§7.5): this replica runs
        // every frame at 60 fps from launch and reads 5–6 points lower than
        // the app on the 12 mini, on the base commit as well.
        let cases: [(JarHeadroomReplica.Fixture, CGFloat, CGFloat, Int)] = [
            (.worstcase, 402, 0.187, 2),
            (.worstcase, 375, 0.138, 2),
            (.stress, 402, 0.211, 1),
            (.stress, 375, 0.150, 1)
        ]
        for (fixture, screenWidth, baseLowest, runs) in cases {
            for run in 0 ..< runs {
                let settles = try JarHeadroomReplica.settles(fixture, screenWidth: screenWidth)
                let minimum = settles.map(\.headroom).min() ?? 0
                print(String(
                    format: "HEADROOM-REPLICA tree=f3 fixture=%@ screen=%.0f run=%d min=%.3f series=%@",
                    "\(fixture)",
                    screenWidth,
                    run,
                    minimum,
                    JarHeadroomReplica.describe(settles)
                ))
                XCTAssertGreaterThanOrEqual(
                    minimum,
                    baseLowest - 0.025,
                    "\(fixture) at \(screenWidth) pt, run \(run): \(JarHeadroomReplica.describe(settles))"
                )
                XCTAssertTrue(settles.allSatisfy { $0.scale == 1 }, "\(fixture): s = 1 as shipped")
            }
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
    /// window, at a fixed frame rate. The scene's interaction window, its
    /// gesture cooldowns and its drop queue run on the frames' own clock
    /// (`JarScene.interactionClock`), so a window settles and stops after
    /// the same simulated time however fast the machine steps the frames.
    @MainActor
    private final class Driver {
        let scene: JarScene
        private let renderer: SKRenderer
        private var time: TimeInterval
        /// The frames' clock (seconds of the injected uptime).
        var now: TimeInterval { time }

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
            scene.interactionClock = { [weak self] in
                self?.time ?? ProcessInfo.processInfo.systemUptime
            }
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

    /// Holds the phone in `reading` (delivered at 30 Hz, Core Motion's full
    /// rate: every other 60 fps frame, from the first) until the jar has
    /// rested again, or `limit` seconds of frames pass; returns the seconds
    /// it took. A resting jar is fed the reading until the turn wakes it
    /// (the smoothed reading may need a few samples to turn the gravity,
    /// as through an upside-down flip); one the reading does not turn stays
    /// resting, and the hold ends after a second.
    @discardableResult
    private func settle(
        _ scene: JarScene,
        _ driver: Driver,
        holding reading: JarGravityMapping.Reading,
        limit: TimeInterval = 12,
        each: (() -> Void)? = nil
    ) -> TimeInterval {
        let start = driver.now
        var woke = !scene.isIdlePaused
        var frame = 0
        while driver.now - start < limit {
            if frame.isMultiple(of: 2) { scene.setGravityReading(reading) }
            frame += 1
            driver.step(frames: 1) { each?() }
            if !scene.isIdlePaused {
                woke = true
            } else if woke || driver.now - start > 1 {
                break
            }
        }
        return driver.now - start
    }

    /// An upright phone rolled `degrees` onto its right edge (90 is
    /// landscape-right).
    private func rolled(_ degrees: Double) -> JarGravityMapping.Reading {
        let angle = degrees * .pi / 180
        return JarGravityMapping.Reading(deviceGravityX: sin(angle), deviceGravityY: -cos(angle), deviceGravityZ: 0)!
    }

    private func centroid(_ scene: JarScene) -> CGPoint {
        let bodies = pebbles(scene)
        let count = CGFloat(max(bodies.count, 1))
        return CGPoint(
            x: bodies.map(\.position.x).reduce(0, +) / count,
            y: bodies.map(\.position.y).reduce(0, +) / count
        )
    }

    /// The highest body top over `minX...maxX` (all of the jar by default).
    private func highestTop(_ scene: JarScene, minX: CGFloat = -.infinity, maxX: CGFloat = .infinity) -> CGFloat {
        pebbles(scene)
            .filter { $0.position.x + $0.radius >= minX && $0.position.x - $0.radius <= maxX }
            .map { $0.position.y + $0.radius }
            .max() ?? 0
    }

    /// The worst-case fixture's content in the lowest jar the design
    /// supports (320 pt, the fixture's own scene size) with its Screen Time
    /// stones: a pile that nearly reaches the mouth.
    private func makeCrowdedJar() -> JarScene {
        let scene = makeScene(size: CGSize(width: Constants.Jar.defaultSceneWidth, height: 320))
#if DEBUG && targetEnvironment(simulator)
        scene.restore(pebbles: GemShowcaseUITestFixture.worstCaseDescriptors())
#endif
        scene.setScreenTimeObstacles(totalUnits: 9_999)
        return scene
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

    /// What the jar's light shows: the tilt, the light rig's nodes, the
    /// tap light, the pile light's swell and the camera. A calm re-settle
    /// under Reduce Motion changes none of it (the pile light itself still
    /// follows the resting bodies, as in every setting).
    private struct LightState: Equatable {
        var tilt: CGFloat
        var nodes: [String]
    }

    private func lightState(_ scene: JarScene) -> LightState {
        var nodes: [String] = []
        for name in [
            "jar.glass.highlights", "jar.glass.back", "jar.mouth.depth", "jar.glass.innerRim",
            "jar.collar.center", "jar.collar.left", "jar.collar.right",
            "jar.tap.caustic", "jar.reducedMotion.highlight"
        ] {
            guard let node = scene.childNode(withName: "//\(name)") else {
                nodes.append("\(name) missing")
                continue
            }
            nodes.append("\(name) \(node.position.x),\(node.position.y) alpha \(node.alpha) hidden \(node.isHidden)")
        }
        if let glow = scene.childNode(withName: "//jar.pileGlow") {
            nodes.append("pile light swell \(glow.action(forKey: "jar.pileGlow.pulse") != nil)")
        }
        if let camera = scene.camera {
            nodes.append("camera \(camera.position.x),\(camera.position.y)")
        }
        return LightState(tilt: scene.opticalTiltFraction, nodes: nodes)
    }

    /// Dust, sparks, landing lights, anticipation and twinkles in the jar.
    private func effectNodeCount(_ scene: JarScene) -> Int {
        var count = 0
        for name in ["drop.dust", "drop.spark", "drop.light", "drop.anticipation", "drop.anticipation.rare", "ambient.twinkle"] {
            scene.enumerateChildNodes(withName: "//\(name)") { _, _ in count += 1 }
        }
        return count
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

    /// A 記念石 (round 13: a moonstone cabochon; grams 0, its own radius).
    private func keepsake(_ index: Int, _ kind: AchievementKind) -> PebbleDescriptor {
        PebbleDescriptor(
            id: UUID(uuidString: String(format: "F3000000-0000-4000-A000-%012X", index))!,
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: .manual,
            kind: .normal,
            achievementKind: kind,
            grams: 0,
            createdAt: Date(timeIntervalSince1970: TimeInterval(3_000 + index))
        )
    }

    /// Renders the scene the way its SKView shows it and returns RGBA
    /// bytes (row 0 at the top).
    private func render(_ scene: JarScene, in view: SKView) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        let texture = try XCTUnwrap(view.texture(from: scene, crop: CGRect(origin: .zero, size: scene.size)))
        let image = texture.cgImage()
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (image.width, image.height, bytes)
    }

    /// The largest alpha on the rendered image's outermost pixels.
    private func edgeAlpha(_ pixels: (width: Int, height: Int, bytes: [UInt8])) -> Int {
        var maximum = 0
        for row in 0 ..< pixels.height {
            for column in [0, pixels.width - 1] {
                maximum = max(maximum, Int(pixels.bytes[(row * pixels.width + column) * 4 + 3]))
            }
        }
        for column in 0 ..< pixels.width {
            for row in [0, pixels.height - 1] {
                maximum = max(maximum, Int(pixels.bytes[(row * pixels.width + column) * 4 + 3]))
            }
        }
        return maximum
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

    /// A crystal of `level` (×10^level gems), as a fusion leaves it.
    private func crystal(_ index: Int, level: Int) -> PebbleDescriptor {
        let count = Int(pow(10, Double(level)))
        return PebbleDescriptor(
            id: UUID(uuidString: String(format: "F3000000-0000-4000-9000-%012X", index))!,
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: .timer,
            kind: .normal,
            aggregate: AggregateMetadata(
                level: level,
                pebbleCount: count,
                childAggregateCount: 10,
                colorMix: [StratumColorFraction(hex: Constants.Color.english, fraction: 1)],
                subjectMix: [AggregateSubjectFraction(name: "英語", colorHex: Constants.Color.english, pebbleCount: count)],
                periodStart: Date(timeIntervalSince1970: 0),
                periodEnd: Date(timeIntervalSince1970: 1_000),
                sessionIDs: [],
                measuredPebbleCount: count,
                manualPebbleCount: 0,
                goldPebbleCount: 0,
                prismPebbleCount: 0
            ),
            grams: count * Constants.Mass.measuredPebbleGrams,
            createdAt: Date(timeIntervalSince1970: 2_000)
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

#if DEBUG && targetEnvironment(simulator)
// MARK: - F3 review: the showcase fixtures' headroom, replicated deterministically

/// Replays `GemShowcaseFixtureLaunchView` and the Debug settle probe
/// (`POMOGEM_UI_TEST_SETTLE_PROBE`, Docs/GemExperienceDesign.md §7.5) on
/// SpriteKit's own update cycle: the scene is created at the fixture's
/// size, restored, given its Screen Time stones and only then resized to
/// the stage (as SwiftUI does on appear); then the first settle and full
/// shakes alternating sides (−1 first, as the probe), each measured once
/// the jar rests or after the probe's 21 s. The interaction window, the
/// shake cooldown and the drop queue run on the frames' own clock
/// (`JarScene.interactionClock`), so every settle gets the same simulated
/// time whatever the machine's load.
@MainActor
enum JarHeadroomReplica {
    enum Fixture {
        case worstcase
        case stress

        var jarHeight: CGFloat {
            switch self {
            case .worstcase: 320
            case .stress: Constants.Jar.height
            }
        }

        var descriptors: [PebbleDescriptor] {
            switch self {
            case .worstcase: GemShowcaseUITestFixture.worstCaseDescriptors()
            case .stress: GemShowcaseUITestFixture.stressDescriptors()
            }
        }
    }

    struct Settle {
        let headroom: CGFloat
        let scale: CGFloat
        let rested: Bool
    }

    /// `screenWidth`: the device's (the fixture's stage is 16 pt narrower).
    static func settles(
        _ fixture: Fixture,
        screenWidth: CGFloat,
        shakes: Int = 10,
        fps: Double = 60
    ) throws -> [Settle] {
        let scene = JarScene(size: CGSize(width: Constants.Jar.defaultSceneWidth, height: fixture.jarHeight))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.bakesGemBedInBackground = false
        scene.restore(pebbles: fixture.descriptors)
        scene.setScreenTimeObstacles(totalUnits: 9_999)
        scene.size = CGSize(width: screenWidth - 16, height: fixture.jarHeight + 40)

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = SKRenderer(device: device)
        let stage = scene.size
        scene.scaleMode = .aspectFit
        renderer.scene = scene
        defer { renderer.scene = nil }
        XCTAssertEqual(scene.size, stage)
        var time = ProcessInfo.processInfo.systemUptime
        scene.interactionClock = { time }
        renderer.update(atTime: time)

        var settles: [Settle] = []
        for index in 0 ... shakes {
            if index > 0 {
                XCTAssertTrue(
                    scene.shakePebbles(strength: 1, horizontal: index.isMultiple(of: 2) ? 1 : -1),
                    "shake \(index)"
                )
            }
            var frames = 0
            let limit = Int(21 * fps)
            while !scene.isIdlePaused, frames < limit {
                time += 1 / fps
                renderer.update(atTime: time)
                frames += 1
            }
            settles.append(Settle(
                headroom: scene.pileHeadroomFraction,
                scale: scene.jarScale,
                rested: scene.isIdlePaused
            ))
        }
        scene.interactionClock = { ProcessInfo.processInfo.systemUptime }
        return settles
    }

    static func describe(_ settles: [Settle]) -> String {
        settles.map {
            String(format: "%.3f@%.2f%@", $0.headroom, $0.scale, $0.rested ? "" : "t")
        }.joined(separator: " ")
    }
}
#endif
