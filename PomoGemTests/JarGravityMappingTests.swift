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
        XCTAssertEqual(JarGravityMapping.inPlaneFraction(deviceGravityX: 0, deviceGravityY: 0, deviceGravityZ: -1), 0)
    }

    func testAMissingZDoesNotTurnAFlatPhonesNoiseIntoFullGravity() {
        // A source that never fills z (today's JarMotionSample) still reads a
        // flat phone as flat: short readings keep their length.
        XCTAssertEqual(map(0.01, -0.02, 0), JarGravityMapping.defaultGravity)
        XCTAssertEqual(
            JarGravityMapping.inPlaneFraction(deviceGravityX: 0.03, deviceGravityY: 0.04, deviceGravityZ: 0) ?? -1,
            0.05,
            accuracy: 1e-12
        )
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

    func testTheGravityNeverPullsHarderThanTheJarsOwnGravityOrTheCap() {
        var random = SplitMix64(seed: 0xF3)
        for _ in 0 ..< 5000 {
            let x = random.unit() * 3
            let y = random.unit() * 3
            let z = random.unit() * 3
            for orientation in Orientation.allCases {
                let gravity = map(x, y, z, orientation)
                let magnitude = hypot(gravity.dx, gravity.dy)
                XCTAssertLessThanOrEqual(magnitude, strength + 1e-9)
                XCTAssertLessThanOrEqual(magnitude, JarGravityMapping.maximumMagnitude)
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
                    JarGravityMapping.inPlaneFraction(
                        deviceGravityX: reading.0,
                        deviceGravityY: reading.1,
                        deviceGravityZ: reading.2
                    )
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
        var random = SplitMix64(seed: 0x1A)
        for _ in 0 ..< 500 {
            let gravity = CGVector(dx: CGFloat(random.unit()) * 9, dy: CGFloat(random.unit()) * 9)
            guard hypot(gravity.dx, gravity.dy) > 0.01 else { continue }
            let direction = JarGravityMapping.launchDirection(for: gravity)
            XCTAssertEqual(hypot(direction.dx, direction.dy), 1, accuracy: 1e-9)
            XCTAssertLessThan(dot(direction, gravity), 0, "Always against gravity")
            XCTAssertEqual(direction.dx * gravity.dy - direction.dy * gravity.dx, 0, accuracy: 1e-9, "Along its line")
        }
        // No usable direction: today's scene-up.
        for gravity in [CGVector.zero, CGVector(dx: 0.0001, dy: 0), CGVector(dx: CGFloat.nan, dy: 1), CGVector(dx: 0, dy: CGFloat.infinity)] {
            assertVector(JarGravityMapping.launchDirection(for: gravity), CGVector(dx: 0, dy: 1), "\(gravity)")
        }
    }

    func testWakeDeltaReadsASidewaysChangeLikeTheLightAndCountsAnUpsideDownFlip() {
        let down = JarGravityMapping.defaultGravity
        // Sideways: exactly the light's change, so the idle light threshold
        // keeps its meaning.
        for fraction in [0.01, 0.015, 0.2, -0.4, 1] as [CGFloat] {
            let tilted = CGVector(dx: fraction * strength, dy: down.dy)
            let lightChange = abs(
                JarTiltMath.lightFraction(horizontal: tilted.dx) - JarTiltMath.lightFraction(horizontal: down.dx)
            )
            XCTAssertEqual(JarGravityMapping.wakeDelta(from: down, to: tilted), lightChange, accuracy: 1e-12)
        }
        // A flip with no sideways part moves no light but must count.
        let upsideDown = CGVector(dx: 0, dy: strength)
        XCTAssertEqual(
            JarTiltMath.lightFraction(horizontal: upsideDown.dx),
            JarTiltMath.lightFraction(horizontal: down.dx)
        )
        XCTAssertEqual(JarGravityMapping.wakeDelta(from: down, to: upsideDown), 2, accuracy: 1e-12)
        XCTAssertGreaterThan(
            JarGravityMapping.wakeDelta(from: down, to: CGVector(dx: 0, dy: -0.9 * strength)),
            JarTiltMath.idleLightThreshold
        )
        // Tremor just under the threshold on both axes at once stays under
        // it (a diagonal measure would read 0.012·√2 ≈ 0.017 and wake).
        let tremor = 0.012 * strength
        XCTAssertLessThan(
            JarGravityMapping.wakeDelta(from: down, to: CGVector(dx: tremor, dy: down.dy + tremor)),
            JarTiltMath.idleLightThreshold
        )
        // Symmetric, zero for no change, and a rejected sample moves nothing.
        let a = CGVector(dx: 1.3, dy: -5.5)
        let b = CGVector(dx: -2.1, dy: 3.4)
        XCTAssertEqual(JarGravityMapping.wakeDelta(from: a, to: b), JarGravityMapping.wakeDelta(from: b, to: a))
        XCTAssertEqual(JarGravityMapping.wakeDelta(from: a, to: a), 0)
        XCTAssertEqual(JarGravityMapping.wakeDelta(from: a, to: CGVector(dx: CGFloat.nan, dy: 0)), 0)
        XCTAssertEqual(JarGravityMapping.wakeDelta(from: CGVector(dx: 0, dy: -CGFloat.infinity), to: a), 0)
    }

    // MARK: Helpers

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
}
