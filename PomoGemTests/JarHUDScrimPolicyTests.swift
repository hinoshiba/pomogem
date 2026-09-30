import CoreGraphics
import XCTest
@testable import PomoGem

/// F3 (Docs/JarOrientationGravity.md, owner ruling 2026-09-27): Home's metric
/// HUD stays on top of an upside-down pile and legible. Its ink scrim is a
/// pure function of the settled pile's bodies and the HUD's measured frame:
/// stronger while a gem lies behind it (gem by gem, review F2), the standard
/// scrim otherwise.
final class JarHUDScrimPolicyTests: XCTestCase {
    private let hud = CGRect(x: 110, y: 88, width: 170, height: 100)

    private typealias Body = JarHUDScrimPolicy.Body

    private func body(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> Body {
        Body(center: CGPoint(x: x, y: y), radius: radius)
    }

    func testTheScrimStrengthensOnlyWhileAGemLiesBehindTheHUD() {
        // An upside-down pile against the cap, a gem reaching into the
        // readout.
        XCTAssertEqual(
            JarHUDScrimPolicy.strength(pileBodies: [body(60, 60, 20), body(195, 110, 22), body(330, 60, 20)], hudFrame: hud),
            .strengthened
        )
        // A single gem's edge behind the readout's corner is enough.
        XCTAssertEqual(JarHUDScrimPolicy.strength(pileBodies: [body(288, 194, 12)], hudFrame: hud), .strengthened)
        // A pile resting on the floor, below the readout.
        XCTAssertEqual(
            JarHUDScrimPolicy.strength(pileBodies: [body(100, 330, 20), body(195, 340, 20), body(290, 330, 20)], hudFrame: hud),
            .standard
        )
        // Beside the readout (a sideways pile against a wall).
        XCTAssertEqual(
            JarHUDScrimPolicy.strength(pileBodies: [body(335, 100, 25), body(335, 150, 25), body(335, 200, 25)], hudFrame: hud),
            .standard
        )
        // Touching does not overlap.
        XCTAssertEqual(JarHUDScrimPolicy.strength(pileBodies: [body(195, 208, 20)], hudFrame: hud), .standard)
        XCTAssertEqual(JarHUDScrimPolicy.strength(pileBodies: [body(300, 120, 20)], hudFrame: hud), .standard)
    }

    func testTheScrimJudgesTheGemsNotTheBoxAroundThem() {
        // Review F2: an L-shaped pile in the floor–wall corner (landscape
        // right, a calm Reduce Motion re-settle) and a corner heap settled
        // 45° over: their bounding boxes reach into the readout's frame over
        // empty glass, but no gem lies behind it.
        let corner = [
            body(340, 320, 22), body(340, 276, 22), body(340, 232, 22), body(340, 190, 20),
            body(340, 152, 18), body(300, 330, 20), body(258, 334, 18)
        ]
        let heap = [
            body(345, 170, 16), body(310, 220, 18), body(345, 215, 18), body(280, 260, 18),
            body(320, 262, 18), body(250, 300, 18), body(215, 334, 16), body(290, 310, 20)
        ]
        for (name, pile) in [("corner", corner), ("45° heap", heap)] {
            let box = pile.reduce(CGRect.null) {
                $0.union(CGRect(x: $1.center.x - $1.radius, y: $1.center.y - $1.radius, width: $1.radius * 2, height: $1.radius * 2))
            }
            XCTAssertTrue(box.intersects(hud), "\(name): the box meets the HUD")
            XCTAssertEqual(JarHUDScrimPolicy.strength(pileBodies: pile, hudFrame: hud), .standard, name)
        }
        // A gem a few points into the frame is behind it; one whose box
        // corner only reaches past the frame's corner is not.
        XCTAssertEqual(JarHUDScrimPolicy.strength(pileBodies: [body(285, 180, 10)], hudFrame: hud), .strengthened)
        XCTAssertEqual(JarHUDScrimPolicy.strength(pileBodies: [body(288, 196, 10)], hudFrame: hud), .standard, "Only its box corner")
        // The 「N巡」 pill (review F1) is lifted by the same test.
        let pill = CGRect(x: 171, y: 32, width: 48, height: 22)
        XCTAssertTrue(JarHUDScrimPolicy.liftsCyclePill(pileBodies: [body(195, 20, 18)], pillFrame: pill))
        XCTAssertFalse(JarHUDScrimPolicy.liftsCyclePill(pileBodies: [body(195, 300, 18)], pillFrame: pill))
        XCTAssertFalse(JarHUDScrimPolicy.liftsCyclePill(pileBodies: [body(195, 20, 18)], pillFrame: nil))
    }

    func testWithoutAPileOrAMeasuredHUDTheScrimStaysStandard() {
        let pile = [body(195, 110, 22)]
        XCTAssertEqual(JarHUDScrimPolicy.strength(pileBodies: [], hudFrame: hud), .standard)
        XCTAssertEqual(JarHUDScrimPolicy.strength(pileBodies: pile, hudFrame: nil), .standard)
        XCTAssertEqual(JarHUDScrimPolicy.strength(pileBodies: pile, hudFrame: .null), .standard)
        XCTAssertEqual(JarHUDScrimPolicy.strength(pileBodies: pile, hudFrame: .infinite), .standard)
        XCTAssertEqual(JarHUDScrimPolicy.strength(pileBodies: pile, hudFrame: .zero), .standard)
        XCTAssertEqual(
            JarHUDScrimPolicy.strength(pileBodies: pile, hudFrame: CGRect(x: 120, y: 100, width: 0, height: 20)),
            .standard,
            "A degenerate frame"
        )
        XCTAssertEqual(JarHUDScrimPolicy.strength(pileBodies: [body(.nan, 110, 22)], hudFrame: hud), .standard)
        XCTAssertEqual(JarHUDScrimPolicy.strength(pileBodies: [body(195, 110, 0)], hudFrame: hud), .standard)
    }

    func testTheStrengthenedScrimIsTheSameScrimInAStrongerInk() {
        let standard = JarHUDScrimPolicy.ink(for: .standard)
        let strengthened = JarHUDScrimPolicy.ink(for: .strengthened)
        // The HUD's scrim before F3, unchanged.
        XCTAssertEqual(standard, JarHUDScrimPolicy.Ink(center: 0.34, middle: 0.14))
        XCTAssertGreaterThan(strengthened.center, standard.center)
        XCTAssertGreaterThan(strengthened.middle, standard.middle)
        // Still a soft scrim fading out, not an opaque plate over the gems.
        XCTAssertLessThan(strengthened.center, 0.75)
        XCTAssertLessThan(strengthened.middle, strengthened.center)
    }

    func testSceneRectsTurnIntoTheStagesCoordinateSpace() {
        // SpriteKit's y runs up from the stage's bottom; SwiftUI's frames
        // run down from the jar card's top. The scene is the stage's size.
        let stage = CGRect(x: 4, y: 20, width: 390, height: 420)
        let converted = JarHUDScrimPolicy.stageRect(
            ofScene: CGRect(x: 10, y: 300, width: 50, height: 60),
            stageFrame: stage
        )
        XCTAssertEqual(converted, CGRect(x: 14, y: 80, width: 50, height: 60))
        // A pile on the floor stays at the stage's bottom.
        XCTAssertEqual(
            JarHUDScrimPolicy.stageRect(ofScene: CGRect(x: 0, y: 0, width: 390, height: 40), stageFrame: stage),
            CGRect(x: 4, y: 400, width: 390, height: 40)
        )
        XCTAssertNil(JarHUDScrimPolicy.stageRect(ofScene: nil, stageFrame: stage))
        XCTAssertNil(JarHUDScrimPolicy.stageRect(ofScene: CGRect(x: 0, y: 0, width: 10, height: 10), stageFrame: .zero))
        XCTAssertNil(JarHUDScrimPolicy.stageRect(ofScene: .null, stageFrame: stage))
        // Bodies turn the same way; the radius stays.
        XCTAssertEqual(
            JarHUDScrimPolicy.stageBodies(ofScene: [body(35, 330, 12)], stageFrame: stage),
            [body(39, 110, 12)]
        )
        XCTAssertEqual(JarHUDScrimPolicy.stageBodies(ofScene: [body(35, 330, 12)], stageFrame: nil), [])
        XCTAssertEqual(JarHUDScrimPolicy.stageBodies(ofScene: [body(35, 330, 12)], stageFrame: .zero), [])
    }
}
