import SpriteKit
import XCTest
@testable import PomoGem

/// Rendering-cost invariants of the jar (Docs/GemExperienceDesign.md §7.13).
/// Nothing here may change what the jar shows: these tests pin the per-frame
/// work, the draw order that batching relies on, the idle render gate and
/// the bounded texture caches.
final class JarRenderingPerformanceTests: XCTestCase {
    // MARK: Per-frame lighting pass

    @MainActor
    func testObstacleCountStaysUprightWithoutANameSearch() throws {
        let scene = makeScene()
        scene.setScreenTimeObstacles(totalUnits: 120)
        let obstacles = scene.children.flatMap { $0.children }
            .compactMap { $0 as? PebbleNode }
            .filter { $0.descriptor.isScreenTimeObstacle }
        let counted = try XCTUnwrap(obstacles.first { node in
            node.children.contains { $0.name == "obstacle.count" }
        })
        let label = try XCTUnwrap(counted.children.first { $0.name == "obstacle.count" })

        counted.zRotation = 1.1
        counted.updatePresentationLighting(horizontal: 0.3)
        XCTAssertEqual(label.zRotation, -1.1, accuracy: 0.0001)
        counted.zRotation = -2.4
        counted.updatePresentationLighting(horizontal: -0.3)
        XCTAssertEqual(label.zRotation, 2.4, accuracy: 0.0001)
    }

    // MARK: Helpers

    @MainActor
    private func makeScene() -> JarScene {
        let scene = JarScene()
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = true
        return scene
    }
}
