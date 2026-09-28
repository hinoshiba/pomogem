import XCTest
@testable import PomoGem

/// home-11 (the #50 follow-up): a tapped crystal's card stays under the jar.
/// The numbers are Home's measured layout at the default text size with the
/// `midload` showcase (jar card top = 0): the bottle's base, the pickers' and
/// the start button's tops, and the card's height.
final class AggregateCardPlacementPolicyTests: XCTestCase {
    private typealias Policy = AggregateCardPlacementPolicy

    func testTheCardHangsUnderTheBottleInTheFreeRoomOfTallPhones() {
        // iPhone 17 Pro: a 500 pt stage around the 420 pt bottle.
        XCTAssertEqual(
            Policy.placement(isAccessibilitySize: false, bottleBase: 460, cardHeight: 64, pickerTop: 543.5, launcherTop: 601.5),
            .underBottle(hidesPickers: false)
        )
        // iPhone 17 Pro Max: the jar stops at 520 pt, and the card is one line shorter.
        XCTAssertEqual(
            Policy.placement(isAccessibilitySize: false, bottleBase: 470, cardHeight: 53, pickerTop: 625.5, launcherTop: 683.5),
            .underBottle(hidesPickers: false)
        )
    }

    func testThePickersGiveWayWhereTheCardReachesThem() {
        // iPhone SE: the bottle fills its 369 pt stage.
        XCTAssertEqual(
            Policy.placement(isAccessibilitySize: false, bottleBase: 369, cardHeight: 64, pickerTop: 413, launcherTop: 470.5),
            .underBottle(hidesPickers: true)
        )
        // iPhone 12 mini.
        XCTAssertEqual(
            Policy.placement(isAccessibilitySize: false, bottleBase: 435, cardHeight: 64, pickerTop: 493.5, launcherTop: 551.5),
            .underBottle(hidesPickers: true)
        )
        // Without pickers (no theme left), only the start button bounds it.
        XCTAssertEqual(
            Policy.placement(isAccessibilitySize: false, bottleBase: 369, cardHeight: 64, pickerTop: nil, launcherTop: 470.5),
            .underBottle(hidesPickers: false)
        )
    }

    func testTheStartButtonIsNeverCovered() {
        // Exactly the gap above the start button still fits…
        XCTAssertEqual(
            Policy.placement(isAccessibilitySize: false, bottleBase: 369, cardHeight: 64, pickerTop: 413, launcherTop: 445),
            .underBottle(hidesPickers: true)
        )
        // …one point less does not: the card takes a row of its own.
        XCTAssertEqual(
            Policy.placement(isAccessibilitySize: false, bottleBase: 369, cardHeight: 64, pickerTop: 413, launcherTop: 444),
            .row
        )
        // Large (not accessibility) text on an iPhone SE: a taller card, and
        // no spare room left between the jar and the controls.
        XCTAssertEqual(
            Policy.placement(isAccessibilitySize: false, bottleBase: 369, cardHeight: 90, pickerTop: 383, launcherTop: 441),
            .row
        )
        // Before the start button has been measured.
        XCTAssertEqual(
            Policy.placement(isAccessibilitySize: false, bottleBase: 460, cardHeight: 64, pickerTop: 543.5, launcherTop: nil),
            .row
        )
    }

    func testAccessibilitySizesKeepTheRowUnderTheJar() {
        XCTAssertEqual(
            Policy.placement(isAccessibilitySize: true, bottleBase: 460, cardHeight: 64, pickerTop: 543.5, launcherTop: 601.5),
            .row
        )
    }
}
