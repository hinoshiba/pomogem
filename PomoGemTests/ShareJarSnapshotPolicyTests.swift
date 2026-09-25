import SpriteKit
import XCTest
@testable import PomoGem

/// jar-04 / screentime-11: a share image hides some pebbles of the live,
/// settled pile. It may only use the live jar when no visible gem was
/// resting on a hidden one; otherwise the card draws its own bottle.
@MainActor
final class ShareJarSnapshotPolicyTests: XCTestCase {
    private let measuredOnly = JarSnapshotOptions.share(includesSelfReported: false)
    private let withSelfReported = JarSnapshotOptions.share(includesSelfReported: true)

    func testHideRuleKeepsStonesAndMeasuredFocusAndDropsBlackStones() {
        XCTAssertFalse(measuredOnly.hides(descriptor(source: .timer)))
        XCTAssertFalse(measuredOnly.hides(descriptor(source: .screenTime)))
        XCTAssertTrue(measuredOnly.hides(descriptor(source: .manual)))
        XCTAssertTrue(measuredOnly.hides(descriptor(source: .timerDemoted)))
        XCTAssertFalse(
            measuredOnly.hides(descriptor(source: .manual, achievement: .examPass)),
            "Every card lists its 記念石, so the jar keeps showing them"
        )
        XCTAssertTrue(measuredOnly.hides(obstacle()))

        XCTAssertFalse(withSelfReported.hides(descriptor(source: .manual)))
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

    // MARK: - Fixtures

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
