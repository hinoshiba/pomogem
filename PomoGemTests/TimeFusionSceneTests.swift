import Metal
import SpriteKit
import XCTest
@testable import PomoGem

/// Drive actual SpriteKit contacts and actions: a saved completion becomes
/// visible time exactly once, even across acknowledgement and epoch changes.
@MainActor
final class TimeFusionSceneTests: XCTestCase {
    func testLandingAbsorbsExactCreditAndAcknowledgementCannotReplayIt() throws {
        let scene = makeScene()
        scene.reduceMotion = true
        let completion = gem(grams: 100)
        var landings = 0
        var transitions: [TimeFusionTransition] = []
        scene.onLanding = { _ in landings += 1 }
        scene.onTimeFusionFormed = { transitions.append($0) }
        scene.configureTimeFusion(totalGrams: 2_400, colorMix: [],
                                  pendingContributions: [completion.id: 100])
        let driver = try Driver(scene: scene)
        defer { driver.finish() }
        scene.dropFromAbove(completion)
        driver.until { landings == 1 }
        XCTAssertEqual(landings, 1)
        XCTAssertEqual(scene.timeFusionSnapshot?.totalGrams, 2_500)
        XCTAssertTrue(scene.hasLandedPebble(withID: completion.id))

        // Home retires its receipt immediately after the contact callback.
        scene.configureTimeFusion(totalGrams: 2_500, colorMix: [])
        driver.step(60)
        XCTAssertEqual(transitions.count, 1)
        XCTAssertEqual(transitions.first?.beforeGrams, 2_400)
        XCTAssertEqual(transitions.first?.afterGrams, 2_500)
        assertProjection(scene, grams: 2_500)
        XCTAssertNil(scene.childNode(withName: "//pebble.\(completion.id.uuidString)"))

        // A stale receipt replay cannot add or drop the same completion again.
        scene.configureTimeFusion(totalGrams: 2_500, colorMix: [],
                                  pendingContributions: [completion.id: 100])
        scene.dropFromAbove(completion)
        driver.step(60)
        XCTAssertEqual(landings, 1)
        XCTAssertEqual(transitions.count, 1)
        XCTAssertEqual(scene.queuedDropCount, 0)
        assertProjection(scene, grams: 2_500)
    }

    func testAlreadyAccountedManualDropAddsNoTimeAndRestoreAddsNoRawBodies() throws {
        let scene = makeScene()
        let completion = gem(grams: 600, source: .manual)
        var landed = false
        var celebrations = 0
        scene.onLanding = { _ in landed = true }
        scene.onTimeFusionFormed = { _ in celebrations += 1 }
        scene.configureTimeFusion(totalGrams: 2_600, colorMix: [])
        let driver = try Driver(scene: scene)
        defer { driver.finish() }
        scene.drop(completion)
        driver.until { landed }
        XCTAssertTrue(landed)
        driver.step(60)
        assertProjection(scene, grams: 2_600)
        XCTAssertEqual(celebrations, 0)

        scene.restore(pebbles: [completion, gem(grams: 1_000)])
        driver.step(5)
        assertProjection(scene, grams: 2_600)
        XCTAssertTrue(scene.hasLandedPebble(withID: completion.id))
        XCTAssertEqual(celebrations, 0)
    }

    func testPositiveEpochReplacementCancelsOldLandingCelebrationAndIDs() throws {
        let scene = makeScene()
        let oldEpoch = UUID()
        let completion = gem(grams: 100)
        var landed = false
        var celebrations = 0
        scene.onLanding = { _ in landed = true }
        scene.onTimeFusionFormed = { _ in celebrations += 1 }
        scene.configureTimeFusion(totalGrams: 2_400, colorMix: [],
                                  pendingContributions: [completion.id: 100], epochID: oldEpoch)
        let driver = try Driver(scene: scene)
        defer { driver.finish() }
        scene.dropFromAbove(completion)
        driver.until { landed }
        XCTAssertTrue(landed)
        XCTAssertEqual(celebrations, 0, "The delayed birth has not played yet")

        // Replacing the account may increase time, so a total-decrease guard
        // alone cannot invalidate the old epoch's delayed presentation.
        scene.configureTimeFusion(totalGrams: 7_500, colorMix: [], epochID: UUID())
        driver.step(60)
        assertProjection(scene, grams: 7_500)
        XCTAssertEqual(celebrations, 0)
        XCTAssertFalse(scene.hasLandedPebble(withID: completion.id))
        XCTAssertEqual(scene.queuedDropCount, 0)
    }

    func testAuthoritativeCorrectionCancelsDelayedBirthWithoutLosingRemainder() throws {
        let scene = makeScene()
        let completion = gem(grams: 3_600)
        var landed = false
        var celebrations = 0
        scene.onLanding = { _ in landed = true }
        scene.onTimeFusionFormed = { _ in celebrations += 1 }
        scene.configureTimeFusion(totalGrams: 2_400, colorMix: [],
                                  pendingContributions: [completion.id: 3_600])
        let driver = try Driver(scene: scene)
        defer { driver.finish() }
        scene.dropFromAbove(completion)
        driver.until { landed }
        XCTAssertTrue(landed)
        XCTAssertEqual(scene.timeFusionSnapshot?.totalGrams, 6_000)
        XCTAssertEqual(scene.timeFusionSnapshot?.remainderGrams, 1_000)
        scene.configureTimeFusion(totalGrams: 1_230, colorMix: [])
        driver.step(60)
        assertProjection(scene, grams: 1_230)
        XCTAssertEqual(celebrations, 0)
        scene.configureTimeFusion(totalGrams: 6_000, colorMix: [])
        driver.step(30)
        assertProjection(scene, grams: 6_000)
        XCTAssertEqual(celebrations, 0, "A later restore never recreates the cancelled reward")
    }

    private func makeScene() -> JarScene {
        let scene = JarScene(size: CGSize(width: 390, height: 420))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = false
        scene.bakesGemBedInBackground = false
        return scene
    }

    private func gem(grams: Int, source: SessionSource = .timer) -> PebbleDescriptor {
        PebbleDescriptor(subjectName: "Time fusion test", colorHex: TimeFusionPolicy.colorHex,
                         source: source, kind: .normal, grams: grams)
    }

    private func assertProjection(_ scene: JarScene, grams: Int,
                                  file: StaticString = #filePath, line: UInt = #line) {
        var bodies: [PebbleDescriptor] = []
        scene.enumerateChildNodes(withName: "//*") { node, _ in
            if let pebble = node as? PebbleNode { bodies.append(pebble.descriptor) }
        }
        XCTAssertTrue(bodies.allSatisfy(\.isTimeProjection), file: file, line: line)
        XCTAssertEqual(bodies.map(\.grams).reduce(0, +), grams, file: file, line: line)
        XCTAssertEqual(scene.timeFusionSnapshot, TimeFusionPolicy.snapshot(totalGrams: grams), file: file, line: line)
        XCTAssertEqual(scene.physicalAggregateCount,
                       TimeFusionPolicy.snapshot(totalGrams: grams).visibleCrystals.count,
                       file: file, line: line)
    }

    @MainActor
    private final class Driver {
        private let renderer: SKRenderer
        private let scene: JarScene
        private var time = ProcessInfo.processInfo.systemUptime

        init(scene: JarScene) throws {
            self.scene = scene
            renderer = SKRenderer(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
            scene.scaleMode = .aspectFit
            renderer.scene = scene
            scene.didChangeSize(.zero)
            scene.interactionClock = { [weak self] in self?.time ?? 0 }
            renderer.update(atTime: time)
        }

        func step(_ frames: Int) {
            for _ in 0..<frames {
                time += 1.0 / 60
                renderer.update(atTime: time)
            }
        }

        func until(_ condition: () -> Bool) {
            for _ in 0..<600 {
                if condition() { return }
                step(1)
            }
        }

        func finish() {
            scene.onLanding = nil
            scene.onTimeFusionFormed = nil
            renderer.scene = nil
        }
    }
}
