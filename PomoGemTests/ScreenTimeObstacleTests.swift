import SpriteKit
import XCTest
@testable import PomoGem

final class ScreenTimeObstacleTests: XCTestCase {
    func testEveryDecimalCarryConservesBlackUnits() {
        let fixtures: [(Int, [Int])] = [
            (0, []), (9, Array(repeating: 1, count: 9)), (10, [10]),
            (19, Array(repeating: 1, count: 9) + [10]), (20, [10, 10]),
            (99, Array(repeating: 1, count: 9) + Array(repeating: 10, count: 9)),
            (100, [100]), (1_000, [1_000])
        ]
        for (total, expected) in fixtures {
            let roots = ScreenTimeObstacleProjection.decimalRoots(totalUnits: total)
            XCTAssertEqual(roots.map(\.representedUnits), expected)
            XCTAssertEqual(roots.reduce(0) { $0 + $1.representedUnits }, total)
            XCTAssertTrue(Dictionary(grouping: roots, by: \.level).values.allSatisfy { $0.count < 10 })
        }
    }

    func testLargeHistoryIsExactAndBoundedThroughIntMax() {
        let totals = Array(stride(from: 0, through: 20_000, by: 137)) + [
            999_999, 99_999_999, 999_999_999_999_999_999, Int.max - 1, Int.max
        ]
        for total in totals {
            let roots = ScreenTimeObstacleProjection.decimalRoots(totalUnits: total)
            let visible = ScreenTimeObstacleProjection.visibleDescriptors(totalUnits: total)
            XCTAssertLessThanOrEqual(roots.count, ScreenTimeObstacleProjection.maximumDecimalRoots)
            XCTAssertLessThanOrEqual(visible.count, ScreenTimeObstacleProjection.maximumVisibleBodies)
            XCTAssertEqual(visible.reduce(0) { $0 + $1.representedUnits }, total)
            XCTAssertEqual(Set(visible.map(\.id)).count, visible.count)
            XCTAssertEqual(visible, ScreenTimeObstacleProjection.visibleDescriptors(totalUnits: total))
            XCTAssertTrue(visible.allSatisfy { $0.radius.isFinite && $0.radius > 0 && $0.radius <= 26 })
        }
    }

    func testStableRootIdentitySurvivesUnrelatedArrivals() {
        let before = ScreenTimeObstacleProjection.decimalRoots(totalUnits: 21)
        let after = ScreenTimeObstacleProjection.decimalRoots(totalUnits: 22)
        XCTAssertTrue(Set(before.map(\.id)).isSubset(of: Set(after.map(\.id))))
        let afterCarry = ScreenTimeObstacleProjection.decimalRoots(totalUnits: 30)
        XCTAssertTrue(Set(before.filter { $0.level == 1 }.map(\.id))
            .isSubset(of: Set(afterCarry.map(\.id))))
    }

    func testHistoryIdentityIncludesFullWidthUnitCount() {
        let first = ScreenTimeObstacleDescriptor(level: 5, slot: 0, representedUnits: 123, isHistoryPile: true)
        let distant = ScreenTimeObstacleDescriptor(level: 5, slot: 0, representedUnits: 123 + (1 << 48), isHistoryPile: true)
        XCTAssertNotEqual(first.id, distant.id)
        XCTAssertTrue(ScreenTimeObstacleProjection.visibleDescriptors(totalUnits: Int.min).isEmpty)
        XCTAssertTrue(ScreenTimeObstacleProjection.decimalRoots(totalUnits: -1).isEmpty)
    }

    @MainActor
    func testMixedStudyAndBlackInputsCannotCreateStudyFusion() throws {
        let obstacle = try XCTUnwrap(ScreenTimeObstacleProjection.decimalRoots(totalUnits: 1).first)
        let black = PebbleDescriptor(screenTimeObstacle: obstacle)
        let normal = studyDescriptors(count: 10)
        XCTAssertFalse(black.participatesInAggregation)
        XCTAssertFalse(black.participatesInBake)
        XCTAssertFalse(black.isMeasured)
        XCTAssertFalse(black.isAchievement)
        XCTAssertFalse(black.isAggregate)
        XCTAssertEqual(black.grams, 0)
        XCTAssertNil(JarAggregateRequest(pebbles: Array(normal.prefix(9)) + [black], innerWidth: 300))
        XCTAssertNil(JarAggregateRequest(pebbles: Array(repeating: black, count: 10), innerWidth: 300))
        XCTAssertEqual(JarAggregateRequest(pebbles: normal, innerWidth: 300)?.grams, 1_000)
    }

    @MainActor
    func testNineStudyStonesAndNineBlackStonesDoNotFuseTogether() {
        let scene = makeScene()
        var requests: [JarAggregateRequest] = []
        scene.onAggregateRequested = { requests.append($0) }
        scene.setScreenTimeObstacles(totalUnits: 9)
        scene.restore(pebbles: studyDescriptors(count: 9))
        scene.update(0)
        XCTAssertEqual(scene.physicalPebbleCount, 18)
        XCTAssertEqual(scene.screenTimeObstaclePhysicalCount, 9)
        XCTAssertEqual(scene.representedPebbleCount, 9)
        XCTAssertEqual(scene.physicalAggregateCount, 0)
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    func testPositiveFusionLeavesBlackHierarchyUntouched() throws {
        let scene = makeScene()
        let normal = studyDescriptors(count: 10)
        var requests: [JarAggregateRequest] = []
        scene.onAggregateRequested = { requests.append($0) }
        scene.setScreenTimeObstacles(totalUnits: 19)
        scene.restore(pebbles: normal)
        scene.update(0)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(Set(request.pebbleIDs), Set(normal.map(\.id)))
        XCTAssertEqual(request.grams, 1_000)
        XCTAssertEqual(scene.screenTimeObstacleUnitCount, 19)
        XCTAssertEqual(scene.screenTimeObstaclePhysicalCount, 10)
        XCTAssertEqual(scene.representedPebbleCount, 10)
    }

    @MainActor
    func testStudyRestoreAndCloudHistoryRefreshPreserveObstaclesQuietly() {
        let scene = makeScene()
        var landings = 0
        scene.onLanding = { _ in landings += 1 }
        scene.setScreenTimeObstacles(totalUnits: 123)
        for _ in 0..<3 {
            scene.restore(pebbles: studyDescriptors(count: 2))
            scene.configureAggregates([])
            scene.configureBase(strata: [], bedrock: nil, showsMonthLabels: false)
            XCTAssertEqual(scene.screenTimeObstacleUnitCount, 123)
            XCTAssertEqual(scene.screenTimeObstaclePhysicalCount, 6)
            XCTAssertEqual(scene.representedPebbleCount, 2)
            XCTAssertEqual(scene.queuedDropCount, 0)
        }
        XCTAssertEqual(landings, 0)
        XCTAssertTrue(scene.screenTimeObstacleAccessibilityDescription?.contains("123") == true)
        scene.setScreenTimeObstacles(totalUnits: 0)
        XCTAssertEqual(scene.screenTimeObstaclePhysicalCount, 0)
        XCTAssertEqual(scene.physicalPebbleCount, 2)
        XCTAssertNil(scene.screenTimeObstacleAccessibilityDescription)
    }

    @MainActor
    func testRepeatedUpdateDoesNotDuplicateQueuedDropsAndResetCancelsThem() {
        let scene = makeScene()
        scene.setScreenTimeObstacles(totalUnits: 0)
        scene.updateScreenTimeObstacles(totalUnits: 2)
        scene.updateScreenTimeObstacles(totalUnits: 2)
        XCTAssertEqual(scene.queuedDropCount, 2)
        XCTAssertEqual(scene.screenTimeObstacleUnitCount, 2)
        scene.setScreenTimeObstacles(totalUnits: 0)
        XCTAssertEqual(scene.queuedDropCount, 0)
        scene.update(0)
        XCTAssertEqual(scene.physicalPebbleCount, 0)
    }

    @MainActor
    func testBlackCarryNeverChangesPositiveProgress() {
        let scene = makeScene()
        scene.restore(pebbles: studyDescriptors(count: 3))
        scene.setScreenTimeObstacles(totalUnits: 99)
        scene.updateScreenTimeObstacles(totalUnits: 100, animated: false)
        XCTAssertEqual(scene.screenTimeObstaclePhysicalCount, 1)
        XCTAssertEqual(scene.screenTimeObstacleUnitCount, 100)
        XCTAssertEqual(scene.representedPebbleCount, 3)
        XCTAssertEqual(scene.physicalAggregateCount, 0)
    }

    @MainActor
    func testQuietBaselineConsumesPendingObstacleAnimations() {
        let scene = makeScene()
        scene.updateScreenTimeObstacles(totalUnits: 3)
        XCTAssertEqual(scene.queuedDropCount, 3)
        scene.setScreenTimeObstacles(totalUnits: 3)
        XCTAssertEqual(scene.queuedDropCount, 0)
        XCTAssertEqual(scene.screenTimeObstaclePhysicalCount, 3)
        for descriptor in ScreenTimeObstacleProjection.visibleDescriptors(totalUnits: 3) {
            XCTAssertTrue(scene.hasLandedPebble(withID: descriptor.id))
        }
    }

    @MainActor
    func testObstacleCountCannotBlockEarnedStudyDropAtSharedPhysicsLimit() {
        let scene = makeScene()
        let stationary = (0..<100).map { _ in
            PebbleDescriptor(subjectName: "", colorHex: "FFFFFF", source: .timer,
                kind: .normal, grams: 0, isTutorial: true)
        }
        scene.restore(pebbles: stationary)
        scene.setScreenTimeObstacles(totalUnits: Int.max)
        XCTAssertGreaterThan(scene.physicalPebbleCount, Constants.Jar.maxPhysicsBodies)
        let earned = studyDescriptors(count: 1)[0]
        scene.drop(earned)
        scene.update(0)
        XCTAssertEqual(scene.queuedDropCount, 0)
        XCTAssertNotNil(scene.childNode(withName: "//pebble.\(earned.id.uuidString)"))
        XCTAssertEqual(scene.screenTimeObstaclePhysicalCount, ScreenTimeObstacleProjection.maximumVisibleBodies)
    }

    @MainActor
    func testBlackRubbleUsesRealPebbleCollisionsAndNoStudyAura() throws {
        let scene = makeScene()
        scene.setScreenTimeObstacles(totalUnits: 10)
        let descriptor = try XCTUnwrap(ScreenTimeObstacleProjection.decimalRoots(totalUnits: 10).first)
        let node = try XCTUnwrap(scene.childNode(withName: "//pebble.\(descriptor.id.uuidString)") as? PebbleNode)
        let body = try XCTUnwrap(node.physicsBody)
        XCTAssertEqual(body.categoryBitMask, JarPhysicsCategory.pebble)
        XCTAssertNotEqual(body.collisionBitMask & JarPhysicsCategory.pebble, 0)
        XCTAssertNotEqual(body.collisionBitMask & JarPhysicsCategory.floor, 0)
        XCTAssertTrue(node.hasLanded)
        XCTAssertEqual(node.glowWidth, 0)
        // Outline, facets and crack are one baked rubble sprite now.
        let rubble = try XCTUnwrap(node.childNode(withName: "obstacle.body") as? SKSpriteNode)
        XCTAssertNotNil(rubble.texture)
        XCTAssertEqual(rubble.blendMode, .alpha)
        XCTAssertFalse(node.children.contains { $0 is SKShapeNode })
        XCTAssertTrue(scene.bouncePebbles(at: node.position))
        XCTAssertEqual(scene.activeTapMotionPebbleID, descriptor.id)
        XCTAssertNil(scene.lastAcceptedTapSelection?.inspectableAggregateID)
    }

    @MainActor
    private func makeScene() -> JarScene {
        let scene = JarScene()
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = true
        return scene
    }

    private func studyDescriptors(count: Int) -> [PebbleDescriptor] {
        (0..<count).map { index in
            PebbleDescriptor(
                subjectName: "勉強", colorHex: "58A9E4", source: .timer,
                kind: .normal, grams: 100,
                createdAt: Date(timeIntervalSinceReferenceDate: Double(index))
            )
        }
    }
}
