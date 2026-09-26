import CoreGraphics
import UIKit
import XCTest
@testable import PomoGem

/// F3: the jar's gravity follows the phone held sideways or upside down
/// (JarGravityMapping, design D3.2–D3.4). Core Motion's gravity is in the
/// phone's axes: +x toward the right edge, +y toward the top edge of a
/// portrait phone, +z out of the screen; an upright portrait phone reads
/// (0, −1, 0). The jar's scene has +y up on screen.
final class JarGravityMappingTests: XCTestCase {
    private typealias Orientation = JarGravityMapping.InterfaceOrientation

    private let strength = JarGravityMapping.strength
    private let root = CGFloat(0.5).squareRoot()

    // MARK: Orientations (D3.1, D3.2)

    func testTheJarGravityStrengthIsTheSceneDefault() {
        XCTAssertEqual(strength, 7.2, accuracy: 1e-12)
        XCTAssertEqual(JarGravityMapping.defaultGravity, Constants.Jar.gravityVector)
        XCTAssertEqual(JarGravityMapping.defaultGravity, CGVector(dx: 0, dy: -7.2))
        XCTAssertEqual(JarGravityMapping.maximumMagnitude, 9.4, accuracy: 1e-12)
    }

    func testEachInterfaceOrientationHeldUprightPullsTowardItsOwnBottom() {
        for orientation in Orientation.allCases {
            let down = negated(interfaceUp(orientation))
            assertVector(
                map(down.dx, down.dy, 0, orientation),
                CGVector(dx: 0, dy: -strength),
                "\(orientation) held upright"
            )
        }
    }

    func testEveryPoseInEveryOrientationFallsTowardThePhysicallyLowestScreenEdge() {
        // The phone held so that `pose`'s interface would be upright; the
        // jar drawn in `drawn`. Expected: world-down expressed in the drawn
        // interface's axes, derived from each interface's up edge
        // (UIInterfaceOrientation documentation), not from the mapping.
        for pose in Orientation.allCases {
            let worldDown = negated(interfaceUp(pose))
            for drawn in Orientation.allCases {
                let expected = CGVector(
                    dx: strength * dot(worldDown, interfaceRight(drawn)),
                    dy: strength * dot(worldDown, interfaceUp(drawn))
                )
                assertVector(
                    map(worldDown.dx, worldDown.dy, 0, drawn),
                    expected,
                    "phone held as \(pose), jar drawn \(drawn)"
                )
            }
        }
    }

    func testPortraitHomeHeldSidewaysPullsTowardTheLowerWall() {
        // Home is portrait-only: turning the phone does not turn the jar.
        // Home button on the right (UIDeviceOrientation.landscapeLeft): the
        // phone's left edge points down, which is the jar's left wall.
        let homeRight = map(-1, 0, 0)
        XCTAssertEqual(homeRight.dx, -strength, accuracy: 1e-9)
        XCTAssertEqual(homeRight.dy, 0, accuracy: 1e-9)
        // Home button on the left: the right wall.
        let homeLeft = map(1, 0, 0)
        XCTAssertEqual(homeLeft.dx, strength, accuracy: 1e-9)
        XCTAssertEqual(homeLeft.dy, 0, accuracy: 1e-9)
        XCTAssertTrue(JarGravityMapping.isUpward(homeRight), "A sideways jar keeps its mouth closed")
        XCTAssertTrue(JarGravityMapping.isUpward(homeLeft))
        assertVector(JarGravityMapping.launchDirection(for: homeRight), CGVector(dx: 1, dy: 0))
        assertVector(JarGravityMapping.launchDirection(for: homeLeft), CGVector(dx: -1, dy: 0))
    }

    func testUpsideDownPullsTheGemsTowardTheMouth() {
        let upsideDown = map(0, 1, 0)
        assertVector(upsideDown, CGVector(dx: 0, dy: strength))
        XCTAssertTrue(JarGravityMapping.isUpward(upsideDown))
        assertVector(JarGravityMapping.launchDirection(for: upsideDown), CGVector(dx: 0, dy: -1))
        // Upside down relative to a portraitUpsideDown interface is upright.
        assertVector(map(0, 1, 0, .portraitUpsideDown), CGVector(dx: 0, dy: -strength))
    }

    func testTheOrientationDefaultsToPortrait() {
        let readings: [(Double, Double, Double)] = [(0.3, -0.8, -0.5), (-1, 0, 0), (0, 1, 0), (0.1, 0.1, -0.99)]
        for (x, y, z) in readings {
            XCTAssertEqual(
                JarGravityMapping.gravity(deviceGravityX: x, deviceGravityY: y, deviceGravityZ: z),
                JarGravityMapping.gravity(deviceGravityX: x, deviceGravityY: y, deviceGravityZ: z, interfaceOrientation: .portrait)
            )
        }
    }

    func testUIKitInterfaceOrientationsBridgeByName() {
        XCTAssertEqual(Orientation(UIInterfaceOrientation.portrait), .portrait)
        XCTAssertEqual(Orientation(UIInterfaceOrientation.portraitUpsideDown), .portraitUpsideDown)
        XCTAssertEqual(Orientation(UIInterfaceOrientation.landscapeLeft), .landscapeLeft)
        XCTAssertEqual(Orientation(UIInterfaceOrientation.landscapeRight), .landscapeRight)
        XCTAssertEqual(Orientation(UIInterfaceOrientation.unknown), .portrait, "No scene yet reads as Home's portrait")
        // The timer's own mapping agrees on which interface a device pose
        // produces (TimerOrientation), so both screens share one convention.
        let poses: [(UIDeviceOrientation, CGVector)] = [
            (.portrait, CGVector(dx: 0, dy: -1)),
            (.portraitUpsideDown, CGVector(dx: 0, dy: 1)),
            (.landscapeLeft, CGVector(dx: -1, dy: 0)),
            (.landscapeRight, CGVector(dx: 1, dy: 0)),
        ]
        for (device, gravity) in poses {
            let interface = TimerOrientation(deviceOrientation: device)!.interfaceOrientation
            assertVector(
                map(gravity.dx, gravity.dy, 0, Orientation(interface)),
                CGVector(dx: 0, dy: -strength),
                "\(device.rawValue) upright in its own interface"
            )
        }
    }

    // MARK: Face up, face down and the flat-phone rule (D3.2)

    func testAPhoneLyingFlatFaceUpOrFaceDownKeepsTheDefaultGravity() {
        for orientation in Orientation.allCases {
            XCTAssertEqual(map(0, 0, -1, orientation), JarGravityMapping.defaultGravity, "face up, \(orientation)")
            XCTAssertEqual(map(0, 0, 1, orientation), JarGravityMapping.defaultGravity, "face down, \(orientation)")
            // A desk is never perfectly level; its tilt is only noise.
            XCTAssertEqual(map(0.03, 0.05, -0.998, orientation), JarGravityMapping.defaultGravity)
            XCTAssertEqual(map(-0.12, 0.12, 0.985, orientation), JarGravityMapping.defaultGravity)
        }
        XCTAssertEqual(map(0, 0, 0), JarGravityMapping.defaultGravity, "No reading at all")
        XCTAssertEqual(reading(0, 0, -1).inPlaneFraction, 0)
        XCTAssertEqual(reading(0, 0, 0), .flat)
        XCTAssertEqual(JarGravityMapping.gravity(for: .flat), JarGravityMapping.defaultGravity)
    }

    func testAMissingZDoesNotTurnAFlatPhonesNoiseIntoFullGravity() {
        // A source that never fills z (today's JarMotionSample) still reads a
        // flat phone as flat: short readings keep their length.
        XCTAssertEqual(map(0.01, -0.02, 0), JarGravityMapping.defaultGravity)
        XCTAssertEqual(reading(0.03, 0.04, 0).inPlaneFraction, 0.05, accuracy: 1e-12)
    }

    func testTheBlendEndsExactlyAtTheDefaultAndAtTheSensedGravity() {
        XCTAssertEqual(JarGravityMapping.followWeight(inPlaneFraction: 0), 0)
        XCTAssertEqual(JarGravityMapping.followWeight(inPlaneFraction: JarGravityMapping.flatInPlaneFraction), 0)
        XCTAssertEqual(JarGravityMapping.followWeight(inPlaneFraction: 0.35), 0.5, accuracy: 1e-12)
        XCTAssertEqual(JarGravityMapping.followWeight(inPlaneFraction: JarGravityMapping.uprightInPlaneFraction), 1)
        XCTAssertEqual(JarGravityMapping.followWeight(inPlaneFraction: 1), 1)
        XCTAssertEqual(JarGravityMapping.followWeight(inPlaneFraction: .nan), 0)
        var previous: CGFloat = 0
        for step in 0 ... 1000 {
            let weight = JarGravityMapping.followWeight(inPlaneFraction: CGFloat(step) / 1000)
            XCTAssertGreaterThanOrEqual(weight, previous, "The weight never falls as the phone rises")
            previous = weight
        }

        // s = 0.2 and 0.5 with the phone tipped top-down (the case furthest
        // from the default): exactly the default, then exactly the sensed.
        let atFlat = tippedTopDown(inPlaneFraction: 0.2)
        assertVector(map(atFlat.x, atFlat.y, atFlat.z), JarGravityMapping.defaultGravity)
        let atUpright = tippedTopDown(inPlaneFraction: 0.5)
        assertVector(map(atUpright.x, atUpright.y, atUpright.z), CGVector(dx: 0, dy: 0.5 * strength))
    }

    func testTheBlendIsASmoothstepOfTheInPlaneFractionMixingTheTwoVectors() {
        // D3.2: w = smoothstep(0.20, 0.50, s); result = w·sensed + (1−w)·default.
        // Off the midpoint, where a linear ramp or an angle blend would differ.
        XCTAssertEqual(JarGravityMapping.followWeight(inPlaneFraction: 0.25), 2.0 / 27.0, accuracy: 1e-12)
        XCTAssertEqual(JarGravityMapping.followWeight(inPlaneFraction: 0.45), 25.0 / 27.0, accuracy: 1e-12)
        // Tipped top-down at s = 0.25: 7.2·(w·1.25 − 1).
        let tipped = tippedTopDown(inPlaneFraction: 0.25)
        assertVector(map(tipped.x, tipped.y, tipped.z), CGVector(dx: 0, dy: -6.533_333_333_333), accuracy: 1e-9)
        // Rolled onto its right edge at s = 0.35: half of (2.52, 0) plus
        // half of (0, −7.2), the plain vector mean.
        assertVector(map(0.35, 0, -(1 - 0.35 * 0.35).squareRoot()), CGVector(dx: 1.26, dy: -3.6))
        // Leaned back at s = 0.45: sensed (0, −3.24).
        let leaned = map(0, -0.45, -(1 - 0.45 * 0.45).squareRoot())
        XCTAssertEqual(leaned.dx, 0, accuracy: 1e-12)
        XCTAssertEqual(leaned.dy, -(25.0 / 27.0 * 3.24 + 2.0 / 27.0 * 7.2), accuracy: 1e-9)
    }

    func testTheGravityChangesContinuouslyWhateverWayThePhoneTurns() {
        // 0.1° steps round full circles through flat, upright, face down and
        // upside down. The steepest part is the blend band with the phone
        // tipped top-down: about 52 per unit of s, so under 0.1 per step.
        // A hard flat cut-off would jump by several units.
        let steps = 3600
        let sweeps: [(String, (Double) -> (Double, Double, Double))] = [
            ("pitch", { angle in (0, -sin(angle), -cos(angle)) }),
            ("roll", { angle in (sin(angle), 0, -cos(angle)) }),
            ("skewed tilt", { angle in (sin(angle) * sin(0.65), -sin(angle) * cos(0.65), -cos(angle)) }),
            ("turn in the screen plane", { angle in (sin(angle), -cos(angle), 0) }),
        ]
        for orientation in Orientation.allCases {
            for (name, reading) in sweeps {
                var previous: CGVector?
                var largestStep: CGFloat = 0
                for step in 0 ... steps {
                    let angle = Double(step) / Double(steps) * 2 * .pi
                    let (x, y, z) = reading(angle)
                    let gravity = map(x, y, z, orientation)
                    if let previous {
                        largestStep = max(largestStep, hypot(gravity.dx - previous.dx, gravity.dy - previous.dy))
                    }
                    previous = gravity
                }
                XCTAssertLessThan(largestStep, 0.1, "\(name), \(orientation)")
            }
        }
    }

    func testTippingAFlatPhoneTopDownClosesTheMouthOnceAndStaysClosed() {
        // From face up to upside down: the default gravity weakens, passes
        // through zero in the blend band and then pulls toward the mouth.
        // The mouth closes once (weak gravity counts as upward) and never
        // flickers open again on the way.
        var closings = 0
        var wasUpward = false
        for step in 0 ... 900 {
            let angle = Double(step) / 10 * .pi / 180
            let gravity = map(0, sin(angle), -cos(angle))
            let upward = JarGravityMapping.isUpward(gravity)
            if upward, !wasUpward { closings += 1 }
            XCTAssertFalse(wasUpward && !upward, "Reopened at \(Double(step) / 10)°")
            wasUpward = upward
        }
        XCTAssertEqual(closings, 1)
        XCTAssertTrue(wasUpward)
    }

    // MARK: 45° tilts (D3.4)

    func testFortyFiveDegreeTilts() {
        let half = root * strength
        let cases: [(String, (Double, Double, Double), CGVector)] = [
            // Turning the top clockwise swings the right edge (+x) down.
            ("upright, top turned 45° anticlockwise", (-Double(root), -Double(root), 0), CGVector(dx: -half, dy: -half)),
            ("upright, top turned 45° clockwise", (Double(root), -Double(root), 0), CGVector(dx: half, dy: -half)),
            ("leaned back 45° (reading)", (0, -Double(root), -Double(root)), CGVector(dx: 0, dy: -half)),
            ("leaned forward 45°, face down", (0, -Double(root), Double(root)), CGVector(dx: 0, dy: -half)),
            ("tipped top-down 45° from face up", (0, Double(root), -Double(root)), CGVector(dx: 0, dy: half)),
            ("rolled 45° onto its left edge", (-Double(root), 0, -Double(root)), CGVector(dx: -half, dy: 0)),
            ("upside down, turned 45°", (Double(root), Double(root), 0), CGVector(dx: half, dy: half)),
        ]
        for (name, reading, expected) in cases {
            assertVector(map(reading.0, reading.1, reading.2), expected, name)
        }
        XCTAssertFalse(JarGravityMapping.isUpward(CGVector(dx: -half, dy: -half)), "45° off down still has a floor")
        XCTAssertTrue(JarGravityMapping.isUpward(CGVector(dx: half, dy: half)))
    }

    func testUprightUseMatchesTodaysMappingWhereTheOldClampNeverEngaged() {
        // Held upright enough (s ≥ 0.5) and with the top up (today's
        // downward clamp idle), the jar reads exactly as before:
        // (gx, gy) × 7.2.
        for degrees in stride(from: -60.0, through: 60.0, by: 5) {
            let angle = degrees * .pi / 180
            for lean in [0.0, 0.3, 0.6] {
                let x = sin(angle) * cos(lean)
                let y = -cos(angle) * cos(lean)
                let z = -sin(lean)
                let gravity = map(x, y, z)
                XCTAssertEqual(gravity.dx, CGFloat(x) * 7.2, accuracy: 1e-9, "\(degrees)° lean \(lean)")
                XCTAssertEqual(gravity.dy, CGFloat(y) * 7.2, accuracy: 1e-9, "\(degrees)° lean \(lean)")
            }
        }
    }

    // MARK: Magnitude cap and rejection (D3.2)

    func testTheGravityNeverPullsHarderThanTheJarsOwnGravity() {
        // Both ends of the blend are at most `strength` (7.2) long, so the
        // result never is either, and the scene's 9.4 cap never trims it.
        var random = SplitMix64(seed: 0xF3)
        for _ in 0 ..< 5000 {
            let x = random.unit() * 3
            let y = random.unit() * 3
            let z = random.unit() * 3
            for orientation in Orientation.allCases {
                let gravity = map(x, y, z, orientation)
                let magnitude = hypot(gravity.dx, gravity.dy)
                XCTAssertLessThanOrEqual(magnitude, strength + 1e-9)
                XCTAssertEqual(JarTiltMath.clamped(gravity), gravity, "The scene's own cap leaves it unchanged")
            }
        }
        // A reading longer than 1 g is scaled back, not amplified.
        assertVector(map(0, -3, 0), CGVector(dx: 0, dy: -strength))
        assertVector(map(3, -4, 0), CGVector(dx: 0.6 * strength, dy: -0.8 * strength))
        // Huge finite readings neither overflow nor escape the cap.
        let huge = Double.greatestFiniteMagnitude
        for (x, y, z) in [(huge, huge, huge), (-huge, 0, 0), (1e300, -1e300, 0), (0, huge, -huge)] {
            let gravity = map(x, y, z)
            XCTAssertTrue(gravity.dx.isFinite && gravity.dy.isFinite, "\(x), \(y), \(z)")
            XCTAssertLessThanOrEqual(hypot(gravity.dx, gravity.dy), strength + 1e-9)
        }
        assertVector(map(-huge, 0, 0), CGVector(dx: -strength, dy: 0))
        XCTAssertEqual(map(1e-300, 0, -1e-300), JarGravityMapping.defaultGravity, "Tiny readings are flat")
    }

    func testTheCapLimitsAVectorAboveTheJarsStrongestGravityInTheSameDirection() {
        // Defence in depth: unreachable with today's constants (7.2 < 9.4),
        // it engages only if the jar's gravity is ever tuned above the cap.
        XCTAssertLessThan(strength, JarGravityMapping.maximumMagnitude)
        assertVector(JarGravityMapping.capped(CGVector(dx: 0, dy: -20)), CGVector(dx: 0, dy: -9.4))
        assertVector(JarGravityMapping.capped(CGVector(dx: 30, dy: 40)), CGVector(dx: 0.6 * 9.4, dy: 0.8 * 9.4))
        let atCap = CGVector(dx: 0, dy: 9.4)
        XCTAssertEqual(JarGravityMapping.capped(atCap), atCap)
        XCTAssertEqual(JarGravityMapping.capped(JarGravityMapping.defaultGravity), JarGravityMapping.defaultGravity)
        XCTAssertEqual(JarGravityMapping.capped(.zero), .zero)
        // The same cap the scene applies (`JarTiltMath.clamped`).
        var random = SplitMix64(seed: 0xCA9)
        for _ in 0 ..< 500 {
            let vector = CGVector(dx: CGFloat(random.unit()) * 30, dy: CGFloat(random.unit()) * 30)
            let capped = JarGravityMapping.capped(vector)
            XCTAssertLessThanOrEqual(hypot(capped.dx, capped.dy), JarGravityMapping.maximumMagnitude + 1e-9)
            assertVector(capped, JarTiltMath.clamped(vector)!, "\(vector)")
        }
    }

    func testNonFiniteReadingsAreRejected() {
        let bad: [Double] = [.nan, .infinity, -.infinity, .signalingNaN]
        for value in bad {
            for reading in [(value, -1.0, 0.0), (0.0, value, 0.0), (0.0, -1.0, value), (value, value, value)] {
                for orientation in Orientation.allCases {
                    XCTAssertNil(
                        JarGravityMapping.acceptedGravity(
                            deviceGravityX: reading.0,
                            deviceGravityY: reading.1,
                            deviceGravityZ: reading.2,
                            interfaceOrientation: orientation
                        ),
                        "\(reading), \(orientation): the sample is ignored"
                    )
                    XCTAssertEqual(
                        map(reading.0, reading.1, reading.2, orientation),
                        JarGravityMapping.defaultGravity,
                        "The non-optional form falls back to the default gravity"
                    )
                }
                XCTAssertNil(
                    JarGravityMapping.Reading(
                        deviceGravityX: reading.0,
                        deviceGravityY: reading.1,
                        deviceGravityZ: reading.2
                    )
                )
                XCTAssertNil(
                    JarGravityMapping.lightHorizontal(
                        deviceGravityX: reading.0,
                        deviceGravityY: reading.1,
                        deviceGravityZ: reading.2
                    ),
                    "The light keeps its place"
                )
            }
        }
    }

    func testFiniteReadingsAreAcceptedAsTheyMap() {
        var random = SplitMix64(seed: 0x51DE)
        for _ in 0 ..< 500 {
            let (x, y, z) = (random.unit(), random.unit(), random.unit())
            XCTAssertEqual(
                JarGravityMapping.acceptedGravity(deviceGravityX: x, deviceGravityY: y, deviceGravityZ: z),
                map(x, y, z)
            )
            for orientation in Orientation.allCases {
                XCTAssertEqual(
                    JarGravityMapping.gravity(for: reading(x, y, z, orientation)),
                    map(x, y, z, orientation)
                )
            }
        }
    }

    // MARK: Helpers for the scene (D3.3)

    func testIsUpwardClosesTheMouthUnlessGravityClearlyPointsDown() {
        XCTAssertFalse(JarGravityMapping.isUpward(JarGravityMapping.defaultGravity))
        XCTAssertFalse(JarGravityMapping.isUpward(CGVector(dx: 0, dy: -2.2)), "Today's flattest pull")
        XCTAssertFalse(JarGravityMapping.isUpward(vector(degreesBelowHorizontal: 60)))
        XCTAssertFalse(JarGravityMapping.isUpward(vector(degreesBelowHorizontal: 8)))
        // Around a sideways hold, noise must not flip the mouth open.
        XCTAssertTrue(JarGravityMapping.isUpward(vector(degreesBelowHorizontal: 4)))
        XCTAssertTrue(JarGravityMapping.isUpward(vector(degreesBelowHorizontal: 0)))
        XCTAssertTrue(JarGravityMapping.isUpward(vector(degreesBelowHorizontal: -4)))
        XCTAssertTrue(JarGravityMapping.isUpward(CGVector(dx: 0, dy: 0.01)))
        XCTAssertTrue(JarGravityMapping.isUpward(CGVector(dx: 0, dy: strength)))
        // Too weak or undefined to hold the gems on the floor.
        XCTAssertTrue(JarGravityMapping.isUpward(.zero))
        XCTAssertTrue(JarGravityMapping.isUpward(CGVector(dx: 0, dy: -0.5)))
        XCTAssertFalse(JarGravityMapping.isUpward(CGVector(dx: 0, dy: -0.8)))
        XCTAssertTrue(JarGravityMapping.isUpward(CGVector(dx: CGFloat.nan, dy: -7.2)))
        XCTAssertTrue(JarGravityMapping.isUpward(CGVector(dx: 0, dy: -CGFloat.infinity)))
    }

    func testLaunchDirectionThrowsStraightAgainstGravity() {
        assertVector(JarGravityMapping.launchDirection(for: JarGravityMapping.defaultGravity), CGVector(dx: 0, dy: 1))
        assertVector(JarGravityMapping.launchDirection(for: CGVector(dx: 0, dy: -2.2)), CGVector(dx: 0, dy: 1))
        assertVector(
            JarGravityMapping.launchDirection(for: CGVector(dx: -3, dy: -4)),
            CGVector(dx: 0.6, dy: 0.8)
        )
        let weak = JarGravityMapping.weakGravityMagnitude
        var random = SplitMix64(seed: 0x1A)
        for _ in 0 ..< 500 {
            let gravity = CGVector(dx: CGFloat(random.unit()) * 9, dy: CGFloat(random.unit()) * 9)
            let direction = JarGravityMapping.launchDirection(for: gravity)
            XCTAssertEqual(hypot(direction.dx, direction.dy), 1, accuracy: 1e-9)
            guard hypot(gravity.dx, gravity.dy) >= weak else {
                assertVector(direction, CGVector(dx: 0, dy: 1), "Too weak to trust: the jar's own up")
                continue
            }
            XCTAssertLessThan(dot(direction, gravity), 0, "Always against gravity")
            XCTAssertEqual(direction.dx * gravity.dy - direction.dy * gravity.dx, 0, accuracy: 1e-9, "Along its line")
        }
        // No trustworthy direction (the same line `isUpward` draws): the
        // jar's own up, whichever way the weak gravity points.
        let undefined: [CGVector] = [
            .zero,
            CGVector(dx: 0.0001, dy: 0),
            CGVector(dx: 0, dy: 0.99 * weak),
            CGVector(dx: 0, dy: -0.99 * weak),
            CGVector(dx: -0.99 * weak, dy: 0),
            CGVector(dx: CGFloat.nan, dy: 1),
            CGVector(dx: 0, dy: CGFloat.infinity),
        ]
        for gravity in undefined {
            assertVector(JarGravityMapping.launchDirection(for: gravity), CGVector(dx: 0, dy: 1), "\(gravity)")
            XCTAssertTrue(JarGravityMapping.isUpward(gravity), "\(gravity): the mouth is closed too")
        }
        assertVector(JarGravityMapping.launchDirection(for: CGVector(dx: 0, dy: weak)), CGVector(dx: 0, dy: -1))
    }

    func testTheThrowHoldsStillWhileTheBlendPassesThroughZeroOnATopDownTip() {
        // Tipping a flat phone top-down, the blended gravity crosses zero
        // near 23°, where ±0.3° of tremor swings it by about ±0.25. The
        // throw stays the jar's own up across that whole weak band and
        // reverses exactly once, where gravity first pulls toward the mouth
        // at `weakGravityMagnitude`.
        let weak = JarGravityMapping.weakGravityMagnitude
        var reversals: [Double] = []
        var previous = CGVector(dx: 0, dy: 1)
        var weakSamples = 0
        for step in 0 ... 9000 {
            let degrees = Double(step) / 100
            let angle = degrees * .pi / 180
            let gravity = map(0, sin(angle), -cos(angle))
            let direction = JarGravityMapping.launchDirection(for: gravity)
            if hypot(gravity.dx, gravity.dy) < weak {
                weakSamples += 1
                assertVector(direction, CGVector(dx: 0, dy: 1), "\(degrees)° in the weak band")
            }
            if dot(direction, previous) < 0 {
                reversals.append(degrees)
                XCTAssertGreaterThanOrEqual(gravity.dy, weak - 1e-9, "Reverses only once gravity pulls toward the mouth")
                XCTAssertLessThan(gravity.dy, weak + 0.1)
            }
            previous = direction
        }
        XCTAssertGreaterThan(weakSamples, 100, "The sweep crosses the weak band")
        XCTAssertEqual(reversals.count, 1, "\(reversals)")
        assertVector(previous, CGVector(dx: 0, dy: -1), "Upside down throws toward the floor")

        // Tremor around the zero crossing never reverses the throw.
        let crossing = zeroCrossingDegreesTippingTopDown()
        var random = SplitMix64(seed: 0x23)
        for _ in 0 ..< 1000 {
            let angle = (crossing + random.unit() * 0.3) * .pi / 180
            let gravity = map(0, sin(angle), -cos(angle))
            XCTAssertLessThan(hypot(gravity.dx, gravity.dy), weak)
            assertVector(JarGravityMapping.launchDirection(for: gravity), CGVector(dx: 0, dy: 1))
        }
    }

    // MARK: The light (D3.3)

    func testAFlatPhoneKeepsTheDefaultGravityButItsLightStillFollowsATilt() {
        // Today's light rule is gx × 7.2 with no flat cut-off, so a tilt on a
        // desk still sparkles at once. The blended gravity stays exactly the
        // default there; the light reads the unblended sensor instead.
        let angle = 5.0 * .pi / 180
        let rolled = reading(sin(angle), 0, -cos(angle))
        XCTAssertEqual(JarGravityMapping.gravity(for: rolled), JarGravityMapping.defaultGravity)
        let light = JarTiltMath.lightFraction(horizontal: JarGravityMapping.lightHorizontal(for: rolled))
        XCTAssertEqual(light, 0.0872, accuracy: 0.0001)
        XCTAssertGreaterThan(light, JarTiltMath.idleLightThreshold, "The resting jar's light check still sees it")
        XCTAssertEqual(JarGravityMapping.lightHorizontal(for: .flat), 0)
        XCTAssertEqual(JarGravityMapping.wakeDelta(from: .flat, to: rolled), 0, "Nothing for the physics to redo")
    }

    func testPortraitLightIsTodaysSidewaysGravityAndTurnsWithTheInterface() {
        let scale = Constants.Jar.tiltLightHorizontalScale
        var random = SplitMix64(seed: 0x11)
        for _ in 0 ..< 500 {
            // Unit readings, as Core Motion reports them.
            var (x, y, z) = (random.unit(), random.unit(), random.unit())
            let length = (x * x + y * y + z * z).squareRoot()
            guard length > 0.01 else { continue }
            (x, y, z) = (x / length, y / length, z / length)
            let portrait = JarGravityMapping.lightHorizontal(deviceGravityX: x, deviceGravityY: y, deviceGravityZ: z)
            XCTAssertEqual(portrait ?? .nan, CGFloat(x) * scale, accuracy: 1e-9, "Today's gx × 7.2")
            for orientation in Orientation.allCases {
                let inScreenX = orientation.interfaceVector(deviceX: CGFloat(x), deviceY: CGFloat(y)).dx
                XCTAssertEqual(
                    JarGravityMapping.lightHorizontal(for: reading(x, y, z, orientation)),
                    inScreenX * scale,
                    accuracy: 1e-9,
                    "\(orientation)"
                )
            }
        }
        // Held upright, the light and the gravity agree sideways.
        let held = reading(0.3, -(1 - 0.09).squareRoot(), 0)
        XCTAssertEqual(JarGravityMapping.lightHorizontal(for: held), JarGravityMapping.gravity(for: held).dx, accuracy: 1e-9)
    }

    // MARK: The resting jar's wake (D3.3)

    func testWakeDeltaReadsASidewaysChangeLikeTheLightAndCountsAnUpsideDownFlip() {
        let upright = reading(0, -1, 0)
        // A turn in the screen plane: exactly the light's change, so the
        // idle light threshold keeps its meaning.
        for fraction in [0.01, 0.015, 0.2, -0.4, 1] {
            let turned = reading(fraction, -(1 - fraction * fraction).squareRoot(), 0)
            let lightChange = abs(
                JarTiltMath.lightFraction(horizontal: JarGravityMapping.lightHorizontal(for: turned))
                    - JarTiltMath.lightFraction(horizontal: JarGravityMapping.lightHorizontal(for: upright))
            )
            XCTAssertEqual(JarGravityMapping.wakeDelta(from: upright, to: turned), lightChange, accuracy: 1e-12)
        }
        // A flip with no sideways part moves no light but must count.
        let upsideDown = reading(0, 1, 0)
        XCTAssertEqual(
            JarGravityMapping.lightHorizontal(for: upsideDown),
            JarGravityMapping.lightHorizontal(for: upright)
        )
        XCTAssertEqual(JarGravityMapping.wakeDelta(from: upright, to: upsideDown), 2, accuracy: 1e-12)
        XCTAssertGreaterThan(
            JarGravityMapping.wakeDelta(from: upright, to: reading(0, -0.9, -(1 - 0.81).squareRoot())),
            JarTiltMath.idleLightThreshold,
            "Leaning back"
        )
        // Tremor just under the threshold on both axes at once stays under
        // it (a diagonal measure would read 0.012·√2 ≈ 0.017 and wake).
        let tremor = unitReading(0.012, -0.988, 0)
        XCTAssertEqual(JarGravityMapping.wakeDelta(from: upright, to: tremor), 0.012, accuracy: 1e-12)
        // Symmetric, and zero for no change.
        let a = reading(0.2, -0.5, -0.84)
        let b = reading(-0.3, 0.6, 0.74)
        XCTAssertEqual(JarGravityMapping.wakeDelta(from: a, to: b), JarGravityMapping.wakeDelta(from: b, to: a))
        XCTAssertEqual(JarGravityMapping.wakeDelta(from: a, to: a), 0)
        // A jar reset to the flat reading keeps the default gravity; an
        // upright phone asks the same gravity of it, so it has nothing to
        // redo. An upside-down phone does: the reading moved by 1 g (its
        // gravity by 2 strengths), the smaller of the two.
        XCTAssertEqual(JarGravityMapping.wakeDelta(from: .flat, to: upright), 0)
        XCTAssertEqual(JarGravityMapping.wakeDelta(from: .flat, to: upsideDown), 1)
    }

    func testAPhoneHeldStillInTheBlendBandNeverWakesTheRestingJar() {
        // The flat-phone blend moves the jar's gravity up to about 7 times
        // faster than the reading between s = 0.2 and 0.5 (about 12° to 30°
        // from flat). Sensor noise of a phone held still (the repo's model:
        // within ±0.012 g on each axis, JarTiltMath.idleLightThreshold) fed
        // through the resting jar's smoothing must still never wake it.
        let smoothing = JarTiltMath.smoothingFraction(updatesPerSecond: JarMotionRate.idleUpdatesPerSecond)
        let threshold = JarTiltMath.idleLightThreshold
        let bound = 0.012
        var random = SplitMix64(seed: 0x5EED)
        for orientation in Orientation.allCases {
            for step in 0 ... 30 {
                let s = 0.2 + Double(step) / 100
                for pose in HeldPose.allCases {
                    let still = pose.gravity(inPlaneFraction: s)
                    let settled = unitReading(still.x, still.y, still.z, orientation)
                    // Alternating worst case on all three axes (the reading
                    // then leaves unit length and is rescaled), and a
                    // seeded Gaussian (σ 0.006 g, within the bound) on the
                    // in-screen axes of a unit reading, like Core Motion's.
                    var alternating = settled
                    var gaussian = settled
                    var largestWake: CGFloat = 0
                    var largestGravityMove: CGFloat = 0
                    for index in 0 ..< 120 {
                        let sign = index.isMultiple(of: 2) ? 1.0 : -1.0
                        let shaken = reading(
                            still.x + sign * bound,
                            still.y - sign * bound,
                            still.z + sign * bound,
                            orientation
                        )
                        alternating = alternating.smoothed(toward: shaken, fraction: smoothing)
                        let noisy = unitReading(
                            still.x + random.clippedGaussian(sigma: 0.006, bound: bound),
                            still.y + random.clippedGaussian(sigma: 0.006, bound: bound),
                            still.z,
                            orientation
                        )
                        gaussian = gaussian.smoothed(toward: noisy, fraction: smoothing)
                        for smoothed in [alternating, gaussian] {
                            largestWake = max(largestWake, JarGravityMapping.wakeDelta(from: settled, to: smoothed))
                            let moved = JarGravityMapping.gravity(for: smoothed)
                            let rested = JarGravityMapping.gravity(for: settled)
                            largestGravityMove = max(
                                largestGravityMove,
                                max(abs(moved.dx - rested.dx), abs(moved.dy - rested.dy)) / strength
                            )
                        }
                    }
                    XCTAssertLessThan(largestWake, threshold, "\(pose) at s = \(s), \(orientation)")
                    if abs(s - 0.35) < 1e-9 {
                        // The jar's gravity itself jitters past the threshold
                        // here: a wake measured on it would fire.
                        XCTAssertGreaterThan(largestGravityMove, threshold, "\(pose) at s = 0.35, \(orientation)")
                    }
                }
            }
        }
    }

    func testADeliberateTurnWakesTheRestingJarWithinAFewSamples() {
        // Phase B: the resting pile re-settles when `needsResettle` holds —
        // the phone turned past `JarTiltMath.reorientationWakeThreshold`
        // (about 6°; tremor of ±0.012 g is about ±0.7°) and the jar's
        // gravity changed direction by more than 3°. Swept over the blend
        // band and above, for every 10° turn that moves the jar's gravity
        // visibly (≥ 1.5 × the threshold):
        // - rolled onto an edge, the gravity turns sideways: it wakes, within
        //   three idle samples;
        // - leaned back, the gravity only grows or weakens along the jar's
        //   own down: it never wakes (the pile has nothing to redo);
        // - tipped top-down, it wakes only where the gravity flips between
        //   down and up (through the weak band, so a few samples later).
        let smoothing = JarTiltMath.smoothingFraction(updatesPerSecond: JarMotionRate.idleUpdatesPerSecond)
        let threshold = JarTiltMath.reorientationWakeThreshold
        var woke = [HeldPose: Int]()
        var stayed = [HeldPose: Int]()
        for pose in HeldPose.allCases {
            for s in [0.25, 0.35, 0.45, 0.7] {
                for turn in [10.0, -10.0] {
                    let angle = asin(s)
                    let from = pose.gravity(tiltedFromFlat: angle)
                    let to = pose.gravity(tiltedFromFlat: angle + turn * .pi / 180)
                    let settled = unitReading(from.x, from.y, from.z)
                    let target = unitReading(to.x, to.y, to.z)
                    let rested = JarGravityMapping.gravity(for: settled)
                    let asked = JarGravityMapping.gravity(for: target)
                    guard max(abs(asked.dx - rested.dx), abs(asked.dy - rested.dy)) / strength >= 1.5 * threshold else {
                        continue
                    }
                    let weak = JarGravityMapping.weakGravityMagnitude
                    let flips = hypot(rested.dx, rested.dy) >= weak
                        && hypot(asked.dx, asked.dy) >= weak
                        && (rested.dy < 0) != (asked.dy < 0)
                    let expected: Bool
                    switch pose {
                    case .rolled: expected = true
                    case .leanedBack: expected = false
                    case .tippedTopDown: expected = flips
                    }
                    let context = "\(pose) at s = \(s), turned \(turn)°"
                    XCTAssertEqual(
                        resettles(from: settled, toward: target, smoothing: smoothing, within: 20),
                        expected,
                        context
                    )
                    if pose == .rolled {
                        XCTAssertTrue(resettles(from: settled, toward: target, smoothing: smoothing, within: 3), context)
                    }
                    if expected { woke[pose, default: 0] += 1 } else { stayed[pose, default: 0] += 1 }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(woke[.rolled] ?? 0, 5, "Rolled in the blend band and above")
        XCTAssertGreaterThanOrEqual(woke[.tippedTopDown] ?? 0, 2, "Tipped through the flip")
        XCTAssertGreaterThanOrEqual(stayed[.leanedBack] ?? 0, 2, "Leaned back")
        XCTAssertGreaterThanOrEqual(stayed[.tippedTopDown] ?? 0, 1, "Tipped without a flip")
        // Upright, a 10° turn in the screen's plane re-settles at the first
        // sample, and a 4° one (hand drift while reading) never does.
        let turn = 10.0 * .pi / 180
        XCTAssertTrue(
            resettles(from: reading(0, -1, 0), toward: reading(sin(turn), -cos(turn), 0), smoothing: smoothing, within: 1)
        )
        let drift = 4.0 * .pi / 180
        XCTAssertFalse(
            resettles(from: reading(0, -1, 0), toward: reading(sin(drift), -cos(drift), 0), smoothing: smoothing, within: 60)
        )
        // A 2° turn still resolves above the light's step, so it moves the
        // light (JarIdleTiltFilter's `.tilt`, measured by `wakeDelta`)
        // without re-settling the pile.
        let small = 2.0 * .pi / 180
        XCTAssertTrue(
            wakes(
                from: reading(0, -1, 0),
                toward: reading(sin(small), -cos(small), 0),
                smoothing: smoothing,
                within: 1,
                threshold: JarTiltMath.idleLightThreshold
            )
        )
        XCTAssertFalse(
            resettles(from: reading(0, -1, 0), toward: reading(sin(small), -cos(small), 0), smoothing: smoothing, within: 60)
        )
    }

    func testThePileRestsOnTheFloorWithin30DegreesAndStandsUprightWithin15() {
        func gravity(_ degrees: Double, _ magnitude: CGFloat = JarGravityMapping.strength) -> CGVector {
            let angle = degrees * .pi / 180
            return CGVector(dx: magnitude * CGFloat(sin(angle)), dy: -magnitude * CGFloat(cos(angle)))
        }
        for degrees in [0.0, 5, 14.9, -14.9] {
            XCTAssertTrue(JarGravityMapping.standsUpright(gravity(degrees)), "\(degrees)°")
            XCTAssertTrue(JarGravityMapping.restsOnTheFloor(gravity(degrees)), "\(degrees)°")
        }
        for degrees in [15.1, -20, 29.9, -29.9] {
            XCTAssertFalse(JarGravityMapping.standsUpright(gravity(degrees)), "\(degrees)°")
            XCTAssertTrue(JarGravityMapping.restsOnTheFloor(gravity(degrees)), "\(degrees)°")
        }
        for degrees in [30.1, -45, 60, 75, 85, -85, 90, 120, 180] {
            XCTAssertFalse(JarGravityMapping.standsUpright(gravity(degrees)), "\(degrees)°")
            XCTAssertFalse(JarGravityMapping.restsOnTheFloor(gravity(degrees)), "\(degrees)°")
        }
        // Too weak to have a direction, or not finite: neither.
        let weak = JarGravityMapping.weakGravityMagnitude * 0.9
        XCTAssertFalse(JarGravityMapping.restsOnTheFloor(gravity(0, weak)))
        XCTAssertFalse(JarGravityMapping.standsUpright(gravity(0, weak)))
        XCTAssertFalse(JarGravityMapping.restsOnTheFloor(CGVector(dx: .nan, dy: -7.2)))
        // The default gravity rests on the floor and stands upright.
        XCTAssertTrue(JarGravityMapping.standsUpright(JarGravityMapping.defaultGravity))
    }

    func testOnlyAGravityAboveHorizontalPullsTheGemsTowardTheMouth() {
        XCTAssertTrue(JarGravityMapping.pullsTowardTheMouth(CGVector(dx: 0, dy: 7.2)))
        XCTAssertTrue(JarGravityMapping.pullsTowardTheMouth(CGVector(dx: 7.2 * cos(0.2), dy: 7.2 * sin(0.2))))
        // Within `upwardMargin` of horizontal, sideways, downward, weak or
        // undefined: the mouth still counts as closed (`isUpward`), but no
        // pile lies against the cap.
        XCTAssertFalse(JarGravityMapping.pullsTowardTheMouth(CGVector(dx: 7.2, dy: 0.3)))
        XCTAssertTrue(JarGravityMapping.isUpward(CGVector(dx: 7.2, dy: 0.3)))
        XCTAssertFalse(JarGravityMapping.pullsTowardTheMouth(CGVector(dx: -7.2, dy: 0)))
        XCTAssertFalse(JarGravityMapping.pullsTowardTheMouth(JarGravityMapping.defaultGravity))
        XCTAssertFalse(JarGravityMapping.pullsTowardTheMouth(CGVector(dx: 0, dy: 0.5)))
        XCTAssertFalse(JarGravityMapping.pullsTowardTheMouth(CGVector(dx: 0, dy: CGFloat.infinity)))
    }

    func testReadingsSmoothLikeTheScenesGravity() {
        let from = reading(0.2, -0.6, -0.77)
        let to = reading(-0.4, 0.3, -0.86)
        XCTAssertEqual(from.smoothed(toward: to, fraction: 0), from)
        XCTAssertEqual(from.smoothed(toward: to, fraction: 1), to)
        XCTAssertEqual(from.smoothed(toward: to, fraction: 2), to, "Clamped like JarTiltMath.smoothed")
        XCTAssertEqual(from.smoothed(toward: to, fraction: -1), from)
        XCTAssertEqual(from.smoothed(toward: to, fraction: .nan), from)
        let half = from.smoothed(toward: to, fraction: 0.25)
        XCTAssertEqual(half.x, 0.2 + (-0.4 - 0.2) * 0.25, accuracy: 1e-12)
        XCTAssertEqual(half.y, -0.6 + (0.3 + 0.6) * 0.25, accuracy: 1e-12)
        var converging = from
        for _ in 0 ..< 200 {
            converging = converging.smoothed(toward: to, fraction: 0.16)
        }
        XCTAssertEqual(converging.x, to.x, accuracy: 1e-9)
        XCTAssertEqual(converging.y, to.y, accuracy: 1e-9)
    }

    // MARK: Helpers

    private func reading(
        _ x: Double,
        _ y: Double,
        _ z: Double,
        _ orientation: Orientation = .portrait
    ) -> JarGravityMapping.Reading {
        JarGravityMapping.Reading(
            deviceGravityX: x,
            deviceGravityY: y,
            deviceGravityZ: z,
            interfaceOrientation: orientation
        )!
    }

    /// A unit reading, as Core Motion reports gravity, whose in-screen part
    /// is exactly (x, y): z takes the rest of the length on its own side.
    private func unitReading(
        _ x: Double,
        _ y: Double,
        _ z: Double,
        _ orientation: Orientation = .portrait
    ) -> JarGravityMapping.Reading {
        let rest = max(1 - x * x - y * y, 0).squareRoot()
        return reading(x, y, z > 0 ? rest : -rest, orientation)
    }

    /// Whether smoothing from `settled` toward `target` at the idle rate
    /// wakes the resting jar (passes `threshold`) within `samples` samples.
    /// Whether a pile settled under `settled` re-settles within `samples`
    /// idle samples smoothing toward `target` (`needsResettle`).
    private func resettles(
        from settled: JarGravityMapping.Reading,
        toward target: JarGravityMapping.Reading,
        smoothing: CGFloat,
        within samples: Int
    ) -> Bool {
        var smoothed = settled
        for _ in 0 ..< samples {
            smoothed = smoothed.smoothed(toward: target, fraction: smoothing)
            if JarGravityMapping.needsResettle(from: settled, to: smoothed) { return true }
        }
        return false
    }

    private func wakes(
        from settled: JarGravityMapping.Reading,
        toward target: JarGravityMapping.Reading,
        smoothing: CGFloat,
        within samples: Int,
        threshold: CGFloat = JarTiltMath.reorientationWakeThreshold
    ) -> Bool {
        var smoothed = settled
        for _ in 0 ..< samples {
            smoothed = smoothed.smoothed(toward: target, fraction: smoothing)
            if JarGravityMapping.wakeDelta(from: settled, to: smoothed) > threshold {
                return true
            }
        }
        return false
    }

    /// Where the blended gravity crosses zero on a phone tipping top-down
    /// from face up (degrees from flat, by bisection).
    private func zeroCrossingDegreesTippingTopDown() -> Double {
        var low = 0.0
        var high = 90.0
        for _ in 0 ..< 60 {
            let middle = (low + high) / 2
            let angle = middle * .pi / 180
            if map(0, sin(angle), -cos(angle)).dy < 0 {
                low = middle
            } else {
                high = middle
            }
        }
        return low
    }

    private func map(
        _ x: Double,
        _ y: Double,
        _ z: Double,
        _ orientation: Orientation = .portrait
    ) -> CGVector {
        JarGravityMapping.gravity(
            deviceGravityX: x,
            deviceGravityY: y,
            deviceGravityZ: z,
            interfaceOrientation: orientation
        )
    }

    /// The interface's up edge in the phone's axes (UIInterfaceOrientation:
    /// landscapeLeft has its top at the phone's left edge, landscapeRight at
    /// its right edge).
    private func interfaceUp(_ orientation: Orientation) -> CGVector {
        switch orientation {
        case .portrait: CGVector(dx: 0, dy: 1)
        case .portraitUpsideDown: CGVector(dx: 0, dy: -1)
        case .landscapeLeft: CGVector(dx: -1, dy: 0)
        case .landscapeRight: CGVector(dx: 1, dy: 0)
        }
    }

    /// The interface's right edge: its up edge turned a quarter clockwise.
    private func interfaceRight(_ orientation: Orientation) -> CGVector {
        let up = interfaceUp(orientation)
        return CGVector(dx: up.dy, dy: -up.dx)
    }

    /// A gravity reading of a phone tipped top-down from face up, with
    /// `inPlaneFraction` of gravity in the screen's plane.
    private func tippedTopDown(inPlaneFraction s: Double) -> (x: Double, y: Double, z: Double) {
        (0, s, -(1 - s * s).squareRoot())
    }

    /// Full-strength gravity pointing right, `degrees` below horizontal.
    private func vector(degreesBelowHorizontal degrees: CGFloat) -> CGVector {
        let angle = degrees * .pi / 180
        return CGVector(dx: strength * cos(angle), dy: -strength * sin(angle))
    }

    private func negated(_ vector: CGVector) -> CGVector {
        CGVector(dx: -vector.dx, dy: -vector.dy)
    }

    private func dot(_ a: CGVector, _ b: CGVector) -> CGFloat {
        a.dx * b.dx + a.dy * b.dy
    }

    private func assertVector(
        _ actual: CGVector,
        _ expected: CGVector,
        _ message: String = "",
        accuracy: CGFloat = 1e-9,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.dx, expected.dx, accuracy: accuracy, "dx \(message)", file: file, line: line)
        XCTAssertEqual(actual.dy, expected.dy, accuracy: accuracy, "dy \(message)", file: file, line: line)
    }
}

/// Three ways to raise a phone from lying face up, by the angle from flat.
private enum HeldPose: CaseIterable {
    /// Top edge up, screen tilting toward the face (reading in bed).
    case leanedBack
    /// Top edge down, toward upside down.
    case tippedTopDown
    /// Onto its right edge, toward landscape.
    case rolled

    func gravity(tiltedFromFlat angle: Double) -> (x: Double, y: Double, z: Double) {
        switch self {
        case .leanedBack: (0, -sin(angle), -cos(angle))
        case .tippedTopDown: (0, sin(angle), -cos(angle))
        case .rolled: (sin(angle), 0, -cos(angle))
        }
    }

    func gravity(inPlaneFraction s: Double) -> (x: Double, y: Double, z: Double) {
        gravity(tiltedFromFlat: asin(min(max(s, 0), 1)))
    }
}

/// A small deterministic generator, so the property sweeps are repeatable.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in −1…1.
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53) * 2 - 1
    }

    /// Gaussian (Box–Muller) with standard deviation `sigma`, clipped to
    /// ±`bound`.
    mutating func clippedGaussian(sigma: Double, bound: Double) -> Double {
        let u1 = max(Double(next() >> 11) / Double(1 << 53), .leastNormalMagnitude)
        let u2 = Double(next() >> 11) / Double(1 << 53)
        let value = sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        return min(max(value, -bound), bound)
    }
}
