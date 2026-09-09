import UIKit
import XCTest
@testable import PomoGem

final class TimerOrientationTests: XCTestCase {
    @MainActor
    func testManualChoiceSurvivesReplacingTheSameTimerViewDuringAccountRevalidation() throws {
        let (defaults, domain) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let selection = TimerOrientationSelection()
        let sessionID = UUID()
        let original = TimerOrientationController(sessionID: sessionID, selection: selection, defaults: defaults)
        original.rotate()
        original.rotate()

        let recovered = TimerOrientationController(sessionID: sessionID, selection: selection, defaults: defaults)
        XCTAssertEqual(recovered.state.direction, .down)
        XCTAssertTrue(recovered.state.isManual)
        recovered.rotate()

        let recoveredAgain = TimerOrientationController(sessionID: sessionID, selection: selection, defaults: defaults)
        XCTAssertEqual(recoveredAgain.state.direction, .left)
        XCTAssertTrue(recoveredAgain.state.isManual)
        recoveredAgain.followDevice()
        let automatic = TimerOrientationController(sessionID: sessionID, selection: selection, defaults: defaults)
        XCTAssertFalse(automatic.state.isManual)

        // The next timer starts from Settings instead of carrying a prior override.
        let fresh = TimerOrientationController(sessionID: UUID(), selection: selection, defaults: defaults)
        XCTAssertEqual(fresh.state.direction, .up)
        XCTAssertFalse(fresh.state.isManual)
    }

    func testEverySavedDefaultCanBeLoadedFromThePersistentPreferences() throws {
        let (defaults, domain) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }

        for orientation in TimerDefaultOrientation.allCases {
            defaults.set(orientation.rawValue, forKey: TimerOrientationPreference.defaultsKey)
            let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            XCTAssertEqual(TimerOrientationPreference.load(defaults: reopenedDefaults), orientation)
            XCTAssertEqual(
                reopenedDefaults.persistentDomain(forName: domain)?[TimerOrientationPreference.defaultsKey] as? String,
                orientation.rawValue
            )
        }
    }

    func testMissingOrUnrecognizedPreferenceFallsBackToAutomatic() throws {
        let (defaults, domain) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }

        XCTAssertEqual(TimerOrientationPreference.load(defaults: defaults), .automatic)
        XCTAssertNil(defaults.object(forKey: TimerOrientationPreference.defaultsKey))
        for unsupportedValue in ["", "diagonal", "RIGHT"] {
            defaults.set(unsupportedValue, forKey: TimerOrientationPreference.defaultsKey)
            XCTAssertEqual(TimerOrientationPreference.load(defaults: defaults), .automatic)
        }
    }

    func testEveryDefaultSetsTheInitialDirectionAndSensorMode() {
        let expectations: [(TimerDefaultOrientation, TimerOrientation, Bool)] = [
            (.automatic, .up, false),
            (.up, .up, true),
            (.right, .right, true),
            (.down, .down, true),
            (.left, .left, true)
        ]

        for (preference, expectedDirection, expectedManual) in expectations {
            let state = TimerOrientationState(defaultOrientation: preference)
            XCTAssertEqual(state.direction, expectedDirection)
            XCTAssertEqual(state.rotationDegrees, expectedDirection.degrees)
            XCTAssertEqual(state.isManual, expectedManual)
        }
    }

    func testFixedDefaultsIgnoreSensorSamplesUntilAutomaticIsSelected() {
        for preference in [TimerDefaultOrientation.up, .right, .down, .left] {
            var state = TimerOrientationState(defaultOrientation: preference)
            let initialDirection = state.direction
            for device in [UIDeviceOrientation.portrait, .landscapeLeft,
                           .portraitUpsideDown, .landscapeRight] {
                state.receive(device, isLocked: false)
                XCTAssertEqual(state.direction, initialDirection)
                XCTAssertTrue(state.isManual)
            }

            state.followDevice(.portrait, isLocked: false)
            XCTAssertEqual(state.direction, .up)
            XCTAssertFalse(state.isManual)
            state.receive(.landscapeLeft, isLocked: false)
            XCTAssertEqual(state.direction, .right)
        }
    }

    @MainActor
    func testNewSessionsUseEverySavedDefaultWithoutPersistingTimerOverrides() throws {
        let (defaults, domain) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let selection = TimerOrientationSelection()

        for preference in TimerDefaultOrientation.allCases {
            defaults.set(preference.rawValue, forKey: TimerOrientationPreference.defaultsKey)
            let original = TimerOrientationController(sessionID: UUID(), selection: selection, defaults: defaults)
            original.rotate()
            original.rotate()
            XCTAssertEqual(TimerOrientationPreference.load(defaults: defaults), preference)
            original.followDevice()
            XCTAssertEqual(TimerOrientationPreference.load(defaults: defaults), preference)

            let next = TimerOrientationController(sessionID: UUID(), selection: selection, defaults: defaults)
            XCTAssertEqual(next.state.direction, preference.direction ?? .up)
            XCTAssertEqual(next.state.isManual, preference != .automatic)
            XCTAssertEqual(TimerOrientationPreference.load(defaults: defaults), preference)
        }
    }

    @MainActor
    func testChangedDefaultAppliesToNewSessionsWhileTheRunningSessionKeepsItsOverride() throws {
        let (defaults, domain) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let selection = TimerOrientationSelection()
        let sessionID = UUID()
        defaults.set(TimerDefaultOrientation.right.rawValue, forKey: TimerOrientationPreference.defaultsKey)
        let running = TimerOrientationController(sessionID: sessionID, selection: selection, defaults: defaults)
        running.rotate()
        XCTAssertEqual(running.state.direction, .down)

        defaults.set(TimerDefaultOrientation.left.rawValue, forKey: TimerOrientationPreference.defaultsKey)
        let recovered = TimerOrientationController(sessionID: sessionID, selection: selection, defaults: defaults)
        XCTAssertEqual(recovered.state.direction, .down)
        XCTAssertTrue(recovered.state.isManual)
        let next = TimerOrientationController(sessionID: UUID(), selection: selection, defaults: defaults)
        XCTAssertEqual(next.state.direction, .left)
        XCTAssertTrue(next.state.isManual)

        defaults.set(TimerDefaultOrientation.automatic.rawValue, forKey: TimerOrientationPreference.defaultsKey)
        let automatic = TimerOrientationController(sessionID: UUID(), selection: selection, defaults: defaults)
        XCTAssertEqual(automatic.state.direction, .up)
        XCTAssertFalse(automatic.state.isManual)
    }

    @MainActor
    func testCompleteDataDeletionRestoresAutomaticForTheNextTimerForEveryDefault() throws {
        let (defaults, domain) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        let selection = TimerOrientationSelection()

        for preference in TimerDefaultOrientation.allCases {
            defaults.set(preference.rawValue, forKey: TimerOrientationPreference.defaultsKey)
            let previous = TimerOrientationController(sessionID: UUID(), selection: selection, defaults: defaults)
            previous.rotate()

            try CompleteDataDeletionDefaultsCleaner.clear(defaults: defaults, persistentDomainName: domain)

            XCTAssertNil(defaults.object(forKey: TimerOrientationPreference.defaultsKey))
            XCTAssertEqual(TimerOrientationPreference.load(defaults: defaults), .automatic)
            let next = TimerOrientationController(sessionID: UUID(), selection: selection, defaults: defaults)
            XCTAssertEqual(next.state.direction, .up)
            XCTAssertFalse(next.state.isManual)
        }
    }

    @MainActor
    func testSelectionRetainsRecentSessionOverridesWithoutKeepingUnlimitedHistory() {
        let selection = TimerOrientationSelection()
        let oldestSessionID = UUID()
        var oldest = selection.state(for: oldestSessionID, defaultOrientation: .automatic)
        oldest.rotate()
        selection.update(oldest, for: oldestSessionID)
        let recentSessionIDs = (0..<8).map { _ in UUID() }
        for sessionID in recentSessionIDs {
            var state = selection.state(for: sessionID, defaultOrientation: .automatic)
            state.rotate()
            state.rotate()
            selection.update(state, for: sessionID)
        }

        for sessionID in recentSessionIDs {
            let retained = selection.state(for: sessionID, defaultOrientation: .left)
            XCTAssertEqual(retained.direction, .down)
            XCTAssertTrue(retained.isManual)
        }
        let expired = selection.state(for: oldestSessionID, defaultOrientation: .left)
        XCTAssertEqual(expired.direction, .left)
        XCTAssertTrue(expired.isManual)
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

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let domain = "TimerOrientationTests-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: domain)), domain)
    }
}
