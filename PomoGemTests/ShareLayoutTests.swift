import XCTest
@testable import PomoGem

/// Pins how 記念石 in the drawn share bottle rest on what is under them
/// instead of floating on a fixed shelf.
@MainActor
final class ShareLayoutTests: XCTestCase {
    // MARK: - Stones in the drawn bottle

    func testStonesBesideAFewGemsRestOnTheFloor() {
        // One gem at the far left; the stones are centred, over empty glass.
        let gem = ShareJarPileLayout.Footprint(minX: -100, maxX: -74, top: 7 + 21)
        let bottoms = ShareJarPileLayout.stoneBottoms(
            centerXs: [-54, -18],
            stoneSize: 34,
            stackingHeight: 25,
            floor: 7,
            footprints: [gem]
        )
        XCTAssertEqual(bottoms, [7, 7], "Nothing is under them, so they sit on the floor")
    }

    func testStonesRestOnTheGemsUnderThem() {
        let gems = (0..<8).map { column -> ShareJarPileLayout.Footprint in
            let x = CGFloat(column - 4) * 20
            return ShareJarPileLayout.Footprint(minX: x - 9, maxX: x + 9, top: 7 + 16)
        }
        let taller = ShareJarPileLayout.Footprint(minX: 50, maxX: 70, top: 7 + 32)
        let bottoms = ShareJarPileLayout.stoneBottoms(
            centerXs: [-20, 60],
            stoneSize: 34,
            stackingHeight: 25,
            floor: 7,
            footprints: gems + [taller]
        )
        XCTAssertEqual(bottoms, [23, 39])
    }

    func testLaterStonesStackOnEarlierOnes() {
        let bottoms = ShareJarPileLayout.stoneBottoms(
            centerXs: [0, 13.6, 200],
            stoneSize: 34,
            stackingHeight: 25,
            floor: 7,
            footprints: []
        )
        XCTAssertEqual(bottoms, [7, 32, 7])
    }

    func testAStoneTouchingOnlyAnEdgeIsNotLifted() {
        // The neighbour's edge reaches under the stone's rounded corner but
        // not its middle.
        let neighbour = ShareJarPileLayout.Footprint(minX: -40, maxX: -12, top: 60)
        let bottoms = ShareJarPileLayout.stoneBottoms(
            centerXs: [0],
            stoneSize: 34,
            stackingHeight: 25,
            floor: 7,
            footprints: [neighbour]
        )
        XCTAssertEqual(bottoms, [7])
    }
}
