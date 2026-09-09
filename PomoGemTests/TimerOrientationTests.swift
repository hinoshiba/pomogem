import UIKit
import XCTest
@testable import PomoGem

final class TimerOrientationTests: XCTestCase {
    @MainActor
    func testManualChoiceSurvivesReplacingTheTimerViewDuringAccountRevalidation() {
        let selection = TimerOrientationSelection()
        let original = TimerOrientationController(selection: selection)
        original.rotate()
        original.rotate()

        let recovered = TimerOrientationController(selection: selection)
        XCTAssertEqual(recovered.state.direction, .down)
        XCTAssertTrue(recovered.state.isManual)
        recovered.rotate()

        let breakTimer = TimerOrientationController(selection: selection)
        XCTAssertEqual(breakTimer.state.direction, .left)
        XCTAssertTrue(breakTimer.state.isManual)
        breakTimer.followDevice()
        XCTAssertFalse(TimerOrientationController(selection: selection).state.isManual)

        // An unrelated process starts with its own default automatic choice.
        let fresh = TimerOrientationController(selection: TimerOrientationSelection())
        XCTAssertEqual(fresh.state.direction, .up)
        XCTAssertFalse(fresh.state.isManual)
    }

    func testPhysicalDeviceDirectionsKeepTheTimerUpright() {
        // UIDevice's landscape name describes the camera edge. The timer
        // therefore turns the opposite way inside the upright app scene.
        let expectations: [(UIDeviceOrientation, TimerOrientation)] = [
            (.portrait, .up),
            (.landscapeLeft, .right),
            (.portraitUpsideDown, .down),
            (.landscapeRight, .left)
        ]

        for (device, expected) in expectations {
            var state = TimerOrientationState()
            state.receive(device, isLocked: false)
            XCTAssertEqual(state.direction, expected)
            XCTAssertFalse(state.isManual)
        }
    }

    func testFlatAndUnknownSamplesPreserveTheLastReadableDirection() {
        var state = TimerOrientationState()
        state.receive(.landscapeRight, isLocked: false)

        for device in [UIDeviceOrientation.faceUp, .faceDown, .unknown] {
            XCTAssertNil(TimerOrientation(deviceOrientation: device))
            state.receive(device, isLocked: false)
            XCTAssertEqual(state.direction, .left)
            XCTAssertFalse(state.isManual)
        }
    }

    func testManualRotationCyclesThroughAllFourDirectionsAndHoldsItsSelection() {
        var state = TimerOrientationState()

        for expected in [TimerOrientation.right, .down, .left, .up] {
            state.rotate()
            XCTAssertEqual(state.direction, expected)
            XCTAssertTrue(state.isManual)

            for locked in [false, true] {
                for device in [UIDeviceOrientation.portrait, .landscapeLeft,
                               .portraitUpsideDown, .landscapeRight] {
                    state.receive(device, isLocked: locked)
                    XCTAssertEqual(state.direction, expected)
                    XCTAssertTrue(state.isManual)
                }
            }
        }
    }

    func testManualRotationCrossesUprightWithoutReversingTheAnimation() {
        var state = TimerOrientationState()

        for step in 1...8 {
            let previousAngle = state.rotationDegrees
            state.rotate()
            XCTAssertEqual(state.rotationDegrees - previousAngle, 90)
            XCTAssertEqual(state.rotationDegrees, Double(step * 90))
        }
        XCTAssertEqual(state.direction, .up)
    }

    func testAutomaticRotationTakesTheShortPathAcrossUpright() {
        var state = TimerOrientationState()
        state.receive(.landscapeRight, isLocked: false)
        XCTAssertEqual(state.rotationDegrees, -90)
        state.receive(.portrait, isLocked: false)
        XCTAssertEqual(state.rotationDegrees, 0)

        for device in [UIDeviceOrientation.landscapeLeft, .portraitUpsideDown,
                       .landscapeRight, .portrait] {
            let previousAngle = state.rotationDegrees
            state.receive(device, isLocked: false)
            XCTAssertEqual(state.rotationDegrees - previousAngle, 90)
        }
        XCTAssertEqual(state.direction, .up)
        XCTAssertEqual(state.rotationDegrees, 360)

        state.receive(.portrait, isLocked: false)
        XCTAssertEqual(state.rotationDegrees, 360,
                       "Repeated sensor samples must not restart the animation")
    }

    func testReturningToAutomaticPreservesTheAccumulatedAnimationAngle() {
        var state = TimerOrientationState()
        for _ in 0..<5 { state.rotate() }
        XCTAssertEqual(state.rotationDegrees, 450)

        state.followDevice(.portrait, isLocked: false)
        XCTAssertEqual(state.direction, .up)
        XCTAssertEqual(state.rotationDegrees, 360,
                       "Auto must turn back 90 degrees after a manual full turn")
        XCTAssertFalse(state.isManual)
    }

    func testSceneLockFreezesAutomaticDirectionAndManualRotationStillWorks() {
        var state = TimerOrientationState()
        state.receive(.landscapeLeft, isLocked: false)
        state.receive(.portraitUpsideDown, isLocked: true)
        XCTAssertEqual(state.direction, .right)
        XCTAssertFalse(state.isManual)

        state.receive(.portraitUpsideDown, isLocked: false)
        XCTAssertEqual(state.direction, .down)

        state.rotate()
        state.receive(.portrait, isLocked: true)
        XCTAssertEqual(state.direction, .left)
        XCTAssertTrue(state.isManual)
    }

    func testReturningToAutomaticUsesTheCurrentDeviceDirection() {
        var state = TimerOrientationState()
        state.rotate()
        state.followDevice(.landscapeRight, isLocked: false)
        XCTAssertEqual(state.direction, .left)
        XCTAssertFalse(state.isManual)

        state.receive(.portrait, isLocked: false)
        XCTAssertEqual(state.direction, .up)
    }

    func testReturningToAutomaticWhileLockedWaitsForAnUnlockedSample() {
        var state = TimerOrientationState()
        state.rotate()
        state.followDevice(.portraitUpsideDown, isLocked: true)
        XCTAssertEqual(state.direction, .right)
        XCTAssertFalse(state.isManual)

        state.receive(.landscapeRight, isLocked: true)
        XCTAssertEqual(state.direction, .right)
        state.receive(.portraitUpsideDown, isLocked: false)
        XCTAssertEqual(state.direction, .down)
    }

    func testReturningToAutomaticFromAFlatDeviceKeepsDirectionUntilUpright() {
        var state = TimerOrientationState()
        state.rotate()
        state.followDevice(.faceUp, isLocked: false)
        XCTAssertEqual(state.direction, .right)
        XCTAssertFalse(state.isManual)

        state.receive(.landscapeRight, isLocked: false)
        XCTAssertEqual(state.direction, .left)
    }

    func testEveryRotatedLayoutFitsTheSameSafeRectangle() {
        let safeRectangles = [
            CGSize(width: 320, height: 548),
            CGSize(width: 393, height: 759),
            CGSize(width: 430, height: 839)
        ]

        for available in safeRectangles {
            for direction in TimerOrientation.allCases {
                let size = direction.contentSize(in: available)
                XCTAssertEqual(size.width > size.height, direction.isLandscape)
                let transform = CGAffineTransform(
                    rotationAngle: direction.degrees * .pi / 180
                )
                let corners = [
                    CGPoint(x: -size.width / 2, y: -size.height / 2),
                    CGPoint(x: size.width / 2, y: -size.height / 2),
                    CGPoint(x: size.width / 2, y: size.height / 2),
                    CGPoint(x: -size.width / 2, y: size.height / 2)
                ].map { $0.applying(transform) }

                for corner in corners {
                    XCTAssertEqual(abs(corner.x), available.width / 2, accuracy: 0.0001)
                    XCTAssertEqual(abs(corner.y), available.height / 2, accuracy: 0.0001)
                }
            }
        }
    }
}
