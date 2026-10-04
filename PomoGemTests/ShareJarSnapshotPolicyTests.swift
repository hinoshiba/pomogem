import SpriteKit
import XCTest
@testable import PomoGem

/// Pins the geometry helpers retained for internal jar rendering. External
/// shares now draw from public records and reject a live personal snapshot.
@MainActor
final class ShareJarSnapshotPolicyTests: XCTestCase {
    private let measuredOnly = JarSnapshotOptions.share(includesSelfReported: false)
    private let withSelfReported = JarSnapshotOptions.share(includesSelfReported: true)

    func testExternalHideRuleKeepsStonesAndTimerFocusAndDropsPrivateScreenTime() {
        XCTAssertFalse(measuredOnly.hides(descriptor(source: .timer)))
        XCTAssertTrue(measuredOnly.hides(descriptor(source: .screenTime)))
        XCTAssertTrue(measuredOnly.hides(descriptor(source: .manual)))
        XCTAssertTrue(measuredOnly.hides(descriptor(source: .timerDemoted)))
        XCTAssertFalse(
            measuredOnly.hides(descriptor(source: .manual, achievement: .examPass)),
            "Every card lists its 記念石, so the jar keeps showing them"
        )
        XCTAssertTrue(measuredOnly.hides(obstacle()))

        XCTAssertFalse(withSelfReported.hides(descriptor(source: .manual)))
        XCTAssertTrue(withSelfReported.hides(descriptor(source: .screenTime)))
        XCTAssertTrue(withSelfReported.hides(obstacle()))
        XCTAssertFalse(JarSnapshotOptions.widget.hides(descriptor(source: .manual)))
        XCTAssertTrue(JarSnapshotOptions.widget.hides(obstacle()))
    }

    func testGemRestingOnAHiddenSelfReportedPebbleRejectsTheLiveJar() {
        let scene = scene(with: [
            (descriptor(source: .manual), CGPoint(x: 100, y: 40)),
            (descriptor(source: .timer), CGPoint(x: 104, y: 62))
        ])
        XCTAssertTrue(ShareJarSnapshotPolicy.hidingLeavesUnsupportedBody(in: scene, options: measuredOnly))
        XCTAssertFalse(
            ShareJarSnapshotPolicy.hidingLeavesUnsupportedBody(in: scene, options: withSelfReported),
            "Nothing is hidden once self-reported focus is included"
        )
    }

    func testStoneUnderAGemNoLongerLeavesAHole() {
        let scene = scene(with: [
            (descriptor(source: .manual, achievement: .perfectScore), CGPoint(x: 100, y: 40)),
            (descriptor(source: .timer), CGPoint(x: 100, y: 64))
        ])
        XCTAssertFalse(ShareJarSnapshotPolicy.hidingLeavesUnsupportedBody(in: scene, options: measuredOnly))
    }

    func testBlackStoneOnTopOfThePileKeepsTheLiveJarButOneUnderAGemDoesNot() {
        let onTop = scene(with: [
            (descriptor(source: .timer), CGPoint(x: 100, y: 40)),
            (obstacle(), CGPoint(x: 102, y: 70))
        ])
        XCTAssertFalse(ShareJarSnapshotPolicy.hidingLeavesUnsupportedBody(in: onTop, options: withSelfReported))

        let underneath = scene(with: [
            (obstacle(), CGPoint(x: 100, y: 40)),
            (descriptor(source: .timer), CGPoint(x: 100, y: 62))
        ])
        XCTAssertTrue(ShareJarSnapshotPolicy.hidingLeavesUnsupportedBody(in: underneath, options: withSelfReported))
    }

    func testSideBySideContactAndDistantBodiesDoNotCount() {
        let radius: CGFloat = 11.5
        let hidden = [ShareJarSnapshotPolicy.Body(center: .zero, radius: radius)]
        XCTAssertFalse(ShareJarSnapshotPolicy.hidingLeavesUnsupportedBody(
            hidden: hidden,
            visible: [.init(center: CGPoint(x: 23, y: 0), radius: radius)]
        ))
        XCTAssertFalse(ShareJarSnapshotPolicy.hidingLeavesUnsupportedBody(
            hidden: hidden,
            visible: [.init(center: CGPoint(x: 0, y: 30), radius: radius)]
        ), "A gap wider than the contact tolerance is not support")
        XCTAssertTrue(ShareJarSnapshotPolicy.hidingLeavesUnsupportedBody(
            hidden: hidden,
            visible: [.init(center: CGPoint(x: 16, y: 16), radius: radius)]
        ), "A gem resting diagonally on the hidden pebble is held up by it")
        XCTAssertFalse(ShareJarSnapshotPolicy.hidingLeavesUnsupportedBody(
            hidden: hidden,
            visible: [.init(center: CGPoint(x: 0, y: -23), radius: radius)]
        ), "A gem below the hidden pebble is not held up by it")
    }

    func testSupportFollowsTheScenesGravity() {
        let radius: CGFloat = 11.5
        let hidden = [ShareJarSnapshotPolicy.Body(center: .zero, radius: radius)]
        let beside = [ShareJarSnapshotPolicy.Body(center: CGPoint(x: 23, y: 0), radius: radius)]
        // Gravity pulling toward -x makes +x "up": the neighbour now rests on it.
        XCTAssertTrue(ShareJarSnapshotPolicy.hidingLeavesUnsupportedBody(
            hidden: hidden,
            visible: beside,
            up: CGVector(dx: 9.8, dy: 0)
        ))
        // No gravity falls back to screen-up.
        XCTAssertFalse(ShareJarSnapshotPolicy.hidingLeavesUnsupportedBody(
            hidden: hidden,
            visible: beside,
            up: .zero
        ))
    }

    // MARK: - The live jar's floor (F3)

    // A pile resting off the jar's floor calls for the drawn bottle on its
    // own (`pileRestsOnTheFloor(in:)`); `hidingLeavesUnsupportedBody` still
    // answers only for hidden bodies. `livePileNeedsDrawnBottle`, the
    // composer's decision, ORs the two.

    func testAPileOffTheFloorWithNothingHiddenGetsTheDrawnBottle() {
        let jar = makeJar()
        jar.restore(pebbles: (0 ..< 4).map { _ in descriptor(source: .timer) })
        for options in [measuredOnly, withSelfReported] {
            XCTAssertFalse(pebbleNodes(jar).isEmpty)
            XCTAssertTrue(pebbleNodes(jar).allSatisfy { !options.hides($0.descriptor) }, "Nothing is hidden")
            XCTAssertFalse(
                ShareJarSnapshotPolicy.livePileNeedsDrawnBottle(in: jar, options: options),
                "Upright: the live snapshot"
            )
        }
        for degrees in [35.0, -35, 90, -90, 180] {
            jar.setGravityReading(rolled(degrees), smoothing: false)
            XCTAssertFalse(ShareJarSnapshotPolicy.pileRestsOnTheFloor(in: jar), "\(degrees)°")
            for options in [measuredOnly, withSelfReported] {
                XCTAssertFalse(
                    ShareJarSnapshotPolicy.hidingLeavesUnsupportedBody(in: jar, options: options),
                    "\(degrees)°: nothing is hidden"
                )
                XCTAssertTrue(
                    ShareJarSnapshotPolicy.livePileNeedsDrawnBottle(in: jar, options: options),
                    "\(degrees)°: the drawn bottle"
                )
            }
        }
    }

    func testAHiddenPebbleHoldingNothingUpUnderATiltWithinThirtyDegreesKeepsTheLiveJar() throws {
        // The measured-only card hides a self-reported pebble that touches
        // a gem on its downhill side. The pile rests on the floor under a
        // 25° roll (the floor allows 30°), so the live jar stands.
        let jar = makeJar()
        jar.restore(pebbles: [descriptor(source: .manual), descriptor(source: .timer)])
        let hidden = try XCTUnwrap(pebbleNodes(jar).first { measuredOnly.hides($0.descriptor) })
        let gem = try XCTUnwrap(pebbleNodes(jar).first { !measuredOnly.hides($0.descriptor) })
        // 30° above the screen's horizontal is 5° above the rolled floor's.
        let reach = hidden.radius + gem.radius
        gem.position = CGPoint(
            x: hidden.position.x + reach * cos(.pi / 6),
            y: hidden.position.y + reach * sin(.pi / 6)
        )
        jar.setGravityReading(rolled(25), smoothing: false)
        XCTAssertGreaterThan(jar.pileGravityVector.dx, 0, "The roll pulls toward the gem's side")

        XCTAssertTrue(ShareJarSnapshotPolicy.pileRestsOnTheFloor(in: jar))
        XCTAssertFalse(ShareJarSnapshotPolicy.hidingLeavesUnsupportedBody(in: jar, options: measuredOnly))
        XCTAssertFalse(
            ShareJarSnapshotPolicy.livePileNeedsDrawnBottle(in: jar, options: measuredOnly),
            "The live snapshot"
        )
        XCTAssertTrue(
            ShareJarSnapshotPolicy.hidingLeavesUnsupportedBody(
                hidden: [.init(center: hidden.position, radius: hidden.radius)],
                visible: [.init(center: gem.position, radius: gem.radius)]
            ),
            "Judged by the screen's up, the gem would rest on the hidden pebble"
        )

        // The pile rests in that pose and a sheet resets the live gravity:
        // support is still judged by the pose the pile rests in.
        rest(jar)
        jar.resetGravity()
        assertLiveGravityIsTheDefault(jar)
        XCTAssertTrue(ShareJarSnapshotPolicy.pileRestsOnTheFloor(in: jar))
        XCTAssertFalse(ShareJarSnapshotPolicy.hidingLeavesUnsupportedBody(in: jar, options: measuredOnly))
        XCTAssertFalse(
            ShareJarSnapshotPolicy.livePileNeedsDrawnBottle(in: jar, options: measuredOnly),
            "Still the live snapshot"
        )
    }

    func testASheetResettingTheLiveGravityLeavesAPileSettledOffTheFloorOnTheDrawnBottle() {
        // Sideways both ways and upside down: the pile settles against a
        // wall or the cap, then a sheet covers Home and the motion observer
        // resets the live gravity (`resetGravity`) without moving the pile.
        for degrees in [90.0, -90, 180] {
            let jar = makeJar()
            jar.restore(pebbles: (0 ..< 4).map { _ in descriptor(source: .timer) })
            jar.setGravityReading(rolled(degrees), smoothing: false)
            rest(jar)
            let settled = jar.pileGravityVector
            XCTAssertFalse(JarGravityMapping.restsOnTheFloor(settled), "\(degrees)°")

            jar.resetGravity()
            assertLiveGravityIsTheDefault(jar)
            XCTAssertTrue(jar.isIdlePaused, "\(degrees)°: the pile stays frozen")
            XCTAssertEqual(jar.pileGravityVector, settled, "\(degrees)°: the pose the pile rests in")
            XCTAssertFalse(ShareJarSnapshotPolicy.pileRestsOnTheFloor(in: jar), "\(degrees)°")
            XCTAssertFalse(
                ShareJarSnapshotPolicy.hidingLeavesUnsupportedBody(in: jar, options: withSelfReported),
                "\(degrees)°: nothing is hidden"
            )
            XCTAssertTrue(
                ShareJarSnapshotPolicy.livePileNeedsDrawnBottle(in: jar, options: withSelfReported),
                "\(degrees)°: still the drawn bottle"
            )
        }
    }

    func testASheetResettingTheLiveGravityLeavesAPileSettledOnTheFloorLive() {
        for degrees in [0.0, 20, -20] {
            let jar = makeJar()
            jar.restore(pebbles: (0 ..< 4).map { _ in descriptor(source: .timer) })
            jar.setGravityReading(rolled(degrees), smoothing: false)
            rest(jar)
            let settled = jar.pileGravityVector
            XCTAssertTrue(JarGravityMapping.restsOnTheFloor(settled), "\(degrees)°")

            jar.resetGravity()
            assertLiveGravityIsTheDefault(jar)
            XCTAssertTrue(jar.isIdlePaused, "\(degrees)°: the pile stays frozen")
            XCTAssertEqual(jar.pileGravityVector, settled, "\(degrees)°: the pose the pile rests in")
            XCTAssertTrue(ShareJarSnapshotPolicy.pileRestsOnTheFloor(in: jar), "\(degrees)°")
            XCTAssertFalse(
                ShareJarSnapshotPolicy.livePileNeedsDrawnBottle(in: jar, options: withSelfReported),
                "\(degrees)°: the live snapshot"
            )
        }
    }

    // MARK: - Fixtures

    private func makeJar() -> JarScene {
        let jar = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        jar.soundEnabled = false
        jar.hapticsEnabled = false
        jar.bakesGemBedInBackground = false
        return jar
    }

    private func pebbleNodes(_ scene: SKScene) -> [PebbleNode] {
        var found: [PebbleNode] = []
        scene.enumerateChildNodes(withName: "//*") { node, _ in
            if let pebble = node as? PebbleNode { found.append(pebble) }
        }
        return found
    }

    /// An upright phone rolled `degrees` onto its right edge (90 is
    /// landscape-right, 180 upside down).
    private func rolled(_ degrees: Double) -> JarGravityMapping.Reading {
        let angle = degrees * .pi / 180
        return JarGravityMapping.Reading(deviceGravityX: sin(angle), deviceGravityY: -cos(angle), deviceGravityZ: 0)!
    }

    /// Two idle observations an idle window apart, past any interaction
    /// window's hard stop: the jar rests in the gravity it has now.
    private func rest(_ jar: JarScene, file: StaticString = #filePath, line: UInt = #line) {
        let uptime = ProcessInfo.processInfo.systemUptime + 100
        jar.evaluateInteractionMotionForTesting(currentTime: 100, uptime: uptime)
        jar.evaluateInteractionMotionForTesting(
            currentTime: 100 + Constants.Jar.idleWindow + 1,
            uptime: uptime + Constants.Jar.interactionHardStopDelay + 1
        )
        XCTAssertTrue(jar.isIdlePaused, "rests", file: file, line: line)
    }

    private func assertLiveGravityIsTheDefault(_ jar: JarScene, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(jar.appliedGravityVector, Constants.Jar.gravityVector, file: file, line: line)
        XCTAssertEqual(
            jar.physicsWorld.gravity.dx, Constants.Jar.gravityVector.dx,
            accuracy: 1e-6, file: file, line: line
        )
        XCTAssertEqual(
            jar.physicsWorld.gravity.dy, Constants.Jar.gravityVector.dy,
            accuracy: 1e-6, file: file, line: line
        )
    }

    private func descriptor(
        source: SessionSource,
        achievement: AchievementKind? = nil
    ) -> PebbleDescriptor {
        PebbleDescriptor(
            subjectName: "英語",
            colorHex: Constants.Color.english,
            source: source,
            kind: .normal,
            achievementKind: achievement,
            grams: achievement == nil ? Constants.Mass.measuredPebbleGrams : 0,
            radius: 11.5
        )
    }

    private func obstacle() -> PebbleDescriptor {
        PebbleDescriptor(
            subjectName: "",
            colorHex: "#111111",
            source: .timer,
            kind: .normal,
            grams: 0,
            radius: 11.5,
            screenTimeObstacle: ScreenTimeObstacleDescriptor(
                level: 0,
                slot: 0,
                representedUnits: 1,
                isHistoryPile: false
            )
        )
    }

    private func scene(with pebbles: [(PebbleDescriptor, CGPoint)]) -> SKScene {
        let scene = SKScene(size: CGSize(width: 200, height: 300))
        scene.physicsWorld.gravity = CGVector(dx: 0, dy: -9.8)
        let world = SKNode()
        scene.addChild(world)
        for (descriptor, position) in pebbles {
            let node = PebbleNode(descriptor: descriptor, reduceMotion: true)
            node.position = position
            world.addChild(node)
        }
        return scene
    }
}
