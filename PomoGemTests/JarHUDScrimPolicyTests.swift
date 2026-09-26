import CoreGraphics
import XCTest
@testable import PomoGem

/// F3 (Docs/JarOrientationGravity.md, owner ruling 2026-09-27): Home's metric
/// HUD stays on top of an upside-down pile and legible. Its ink scrim is a
/// pure function of the settled pile's bounds and the HUD's measured frame:
/// stronger while they overlap, the standard scrim otherwise.
final class JarHUDScrimPolicyTests: XCTestCase {
    private let hud = CGRect(x: 110, y: 88, width: 170, height: 100)

    func testTheScrimStrengthensOnlyWhileThePileMeetsTheHUD() {
        // An upside-down pile against the cap, reaching into the readout.
        XCTAssertEqual(
            JarHUDScrimPolicy.strength(pileBounds: CGRect(x: 40, y: 40, width: 300, height: 90), hudFrame: hud),
            .strengthened
        )
        // A single corner of a gem behind the readout's corner is enough.
        XCTAssertEqual(
            JarHUDScrimPolicy.strength(pileBounds: CGRect(x: 270, y: 180, width: 40, height: 40), hudFrame: hud),
            .strengthened
        )
        // A pile resting on the floor, below the readout.
        XCTAssertEqual(
            JarHUDScrimPolicy.strength(pileBounds: CGRect(x: 40, y: 300, width: 300, height: 90), hudFrame: hud),
            .standard
        )
        // Beside the readout (a sideways pile against a wall).
        XCTAssertEqual(
            JarHUDScrimPolicy.strength(pileBounds: CGRect(x: 300, y: 60, width: 70, height: 300), hudFrame: hud),
            .standard
        )
        // Touching edges do not overlap.
        XCTAssertEqual(
            JarHUDScrimPolicy.strength(pileBounds: CGRect(x: 40, y: 188, width: 300, height: 90), hudFrame: hud),
            .standard
        )
        XCTAssertEqual(
            JarHUDScrimPolicy.strength(pileBounds: CGRect(x: 280, y: 88, width: 40, height: 40), hudFrame: hud),
            .standard
        )
    }

    func testWithoutAPileOrAMeasuredHUDTheScrimStaysStandard() {
        let pile = CGRect(x: 40, y: 40, width: 300, height: 90)
        XCTAssertEqual(JarHUDScrimPolicy.strength(pileBounds: nil, hudFrame: hud), .standard)
        XCTAssertEqual(JarHUDScrimPolicy.strength(pileBounds: pile, hudFrame: nil), .standard)
        XCTAssertEqual(JarHUDScrimPolicy.strength(pileBounds: .null, hudFrame: hud), .standard)
        XCTAssertEqual(JarHUDScrimPolicy.strength(pileBounds: .infinite, hudFrame: hud), .standard)
        XCTAssertEqual(JarHUDScrimPolicy.strength(pileBounds: pile, hudFrame: .zero), .standard)
        XCTAssertEqual(
            JarHUDScrimPolicy.strength(pileBounds: CGRect(x: 120, y: 100, width: 0, height: 20), hudFrame: hud),
            .standard,
            "A degenerate rectangle"
        )
        XCTAssertEqual(
            JarHUDScrimPolicy.strength(pileBounds: CGRect(x: CGFloat.nan, y: 100, width: 20, height: 20), hudFrame: hud),
            .standard
        )
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
    }
}
