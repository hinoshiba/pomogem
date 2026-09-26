import CoreGraphics
import Foundation
import UIKit

/// Where the jar's gravity points for a real phone pose (F3: the jar follows
/// the phone held sideways or upside down).
///
/// Core Motion reports gravity in the phone's own axes, in g: +x toward the
/// right edge and +y toward the top edge of a portrait phone, +z out of the
/// screen, so an upright portrait phone reads (0, −1, 0). The jar's scene
/// has +y up on screen. This type turns one reading into the jar's gravity:
///
/// 1. The in-screen part (x, y) is rotated into the interface's axes, so the
///    gems fall toward whichever screen edge is physically lowest. Home is
///    portrait-only today (`PomoGemAppDelegate`), so callers pass
///    `.portrait`; the other orientations keep a rotating jar correct later.
/// 2. It is scaled by the jar's gravity strength (|`Constants.Jar.gravity`|,
///    7.2), in every direction. Unlike the retired "some downward pull always
///    remains" clamp (`Constants.Jar.tiltGravityMinimumDownward`), sideways
///    and upward gravity are allowed: an upside-down phone pulls the gems
///    toward the mouth, which must then act as closed (`isUpward(_:)`).
/// 3. A phone lying flat has almost no in-screen gravity, and its direction is
///    only sensor noise. The result blends from the jar's default downward
///    gravity (flat) to the sensed gravity (upright) with a smoothstep of the
///    in-screen fraction `s` between `flatInPlaneFraction` and
///    `uprightInPlaneFraction`. A phone on a desk behaves like the jar with
///    motion off, and tilting it up follows real gravity continuously.
///
/// Everything here is pure and nonisolated: the resting jar's tilt check runs
/// it on Core Motion's background queue.
enum JarGravityMapping {
    /// The interface orientation the jar is drawn in. Named after
    /// `UIInterfaceOrientation`; the jar never sees `.unknown`.
    enum InterfaceOrientation: CaseIterable, Equatable, Sendable {
        case portrait
        case portraitUpsideDown
        /// The top of the interface at the phone's left edge (Home button,
        /// where there is one, on the left).
        case landscapeLeft
        /// The top of the interface at the phone's right edge (Home button,
        /// where there is one, on the right).
        case landscapeRight

        /// `.unknown` (no scene yet) reads as portrait, like Home.
        init(_ orientation: UIInterfaceOrientation) {
            switch orientation {
            case .portraitUpsideDown: self = .portraitUpsideDown
            case .landscapeLeft: self = .landscapeLeft
            case .landscapeRight: self = .landscapeRight
            default: self = .portrait
            }
        }

        /// A vector in the phone's axes (x toward the right edge, y toward
        /// the top edge of a portrait phone), in this interface's axes
        /// (x right on screen, y up on screen). Also usable for user
        /// acceleration once the jar rotates with the interface.
        func interfaceVector(deviceX x: CGFloat, deviceY y: CGFloat) -> CGVector {
            switch self {
            case .portrait: CGVector(dx: x, dy: y)
            case .portraitUpsideDown: CGVector(dx: -x, dy: -y)
            case .landscapeLeft: CGVector(dx: y, dy: -x)
            case .landscapeRight: CGVector(dx: -y, dy: x)
            }
        }
    }

    // MARK: Tuning

    /// The jar's gravity when the phone lies flat, and the gravity it keeps
    /// while motion is off.
    static let defaultGravity = Constants.Jar.gravityVector

    /// How hard real gravity pulls the gems, in scene units per g (7.2).
    static var strength: CGFloat { abs(Constants.Jar.gravity) }

    /// At or below this in-screen fraction of gravity (about 11.5° from
    /// flat) the phone counts as lying flat: the jar keeps `defaultGravity`.
    static let flatInPlaneFraction: CGFloat = 0.20

    /// At or above this in-screen fraction (30° from flat) the jar follows
    /// the sensed gravity alone.
    static let uprightInPlaneFraction: CGFloat = 0.50

    /// Gravity within this angle of horizontal counts as upward, so sensor
    /// noise around a sideways hold never flips the mouth between open and
    /// closed (sin 5°).
    static let upwardMargin: CGFloat = 0.087

    /// Gravity weaker than this cannot be trusted to hold the gems down (10%
    /// of `strength`), as while the flat-phone blend passes through zero on
    /// a phone tipping top-down from flat; it counts as upward.
    static var weakGravityMagnitude: CGFloat { 0.1 * strength }

    /// Below this magnitude gravity has no usable direction.
    static let directionlessMagnitude: CGFloat = 0.001

    /// The jar's strongest gravity, as `JarTiltMath.clamped` keeps it.
    static var maximumMagnitude: CGFloat {
        max(Constants.Jar.maximumExternalGravityMagnitude, 0.1)
    }

    // MARK: Mapping

    /// The jar's gravity for one Core Motion gravity reading (D3.2). A
    /// reading that is not finite is rejected and yields `defaultGravity`;
    /// callers that would rather keep their current gravity on such a
    /// sample (the scene and the idle tilt check, as `JarTiltMath.clamped`
    /// does today) use `acceptedGravity`.
    static func gravity(
        deviceGravityX: Double,
        deviceGravityY: Double,
        deviceGravityZ: Double,
        interfaceOrientation: InterfaceOrientation = .portrait
    ) -> CGVector {
        acceptedGravity(
            deviceGravityX: deviceGravityX,
            deviceGravityY: deviceGravityY,
            deviceGravityZ: deviceGravityZ,
            interfaceOrientation: interfaceOrientation
        ) ?? defaultGravity
    }

    /// The jar's gravity for one reading, or nil when the reading is not
    /// finite (the sample is ignored). Never longer than `strength` for a
    /// finite reading, and never longer than `maximumMagnitude`.
    static func acceptedGravity(
        deviceGravityX: Double,
        deviceGravityY: Double,
        deviceGravityZ: Double,
        interfaceOrientation: InterfaceOrientation = .portrait
    ) -> CGVector? {
        guard let reading = UnitReading(x: deviceGravityX, y: deviceGravityY, z: deviceGravityZ) else {
            return nil
        }
        let weight = followWeight(inPlaneFraction: reading.inPlaneFraction)
        guard weight > 0 else { return defaultGravity }
        let inScreen = interfaceOrientation.interfaceVector(deviceX: reading.x, deviceY: reading.y)
        let sensed = CGVector(dx: inScreen.dx * strength, dy: inScreen.dy * strength)
        let blended = CGVector(
            dx: weight * sensed.dx + (1 - weight) * defaultGravity.dx,
            dy: weight * sensed.dy + (1 - weight) * defaultGravity.dy
        )
        return capped(blended)
    }

    /// The share of gravity lying in the screen's plane (0 flat … 1
    /// upright), or nil when the reading is not finite.
    static func inPlaneFraction(
        deviceGravityX: Double,
        deviceGravityY: Double,
        deviceGravityZ: Double
    ) -> CGFloat? {
        UnitReading(x: deviceGravityX, y: deviceGravityY, z: deviceGravityZ)?.inPlaneFraction
    }

    /// How much of the sensed gravity the jar follows for an in-screen
    /// fraction `s`: 0 at or below `flatInPlaneFraction`, 1 at or above
    /// `uprightInPlaneFraction`, smoothstep between (no kink at either end).
    static func followWeight(inPlaneFraction s: CGFloat) -> CGFloat {
        guard s.isFinite else { return 0 }
        let span = uprightInPlaneFraction - flatInPlaneFraction
        let t = min(max((s - flatInPlaneFraction) / span, 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: Helpers for the scene (D3.3)

    /// Whether the mouth must act as closed under `gravity`: it points
    /// toward the mouth, or lies within `upwardMargin` of horizontal, or is
    /// too weak or undefined to hold the gems on the floor. Only a clearly
    /// downward gravity answers false.
    static func isUpward(_ gravity: CGVector) -> Bool {
        guard gravity.dx.isFinite, gravity.dy.isFinite else { return true }
        let magnitude = hypot(gravity.dx, gravity.dy)
        guard magnitude >= weakGravityMagnitude else { return true }
        return gravity.dy > -upwardMargin * magnitude
    }

    /// The unit direction a tap or shake throws the gems: straight against
    /// gravity. The default gravity gives (0, 1), today's scene-up; gravity
    /// without a usable direction also gives (0, 1).
    static func launchDirection(for gravity: CGVector) -> CGVector {
        let up = CGVector(dx: 0, dy: 1)
        guard gravity.dx.isFinite, gravity.dy.isFinite else { return up }
        let magnitude = hypot(gravity.dx, gravity.dy)
        guard magnitude >= directionlessMagnitude else { return up }
        return CGVector(dx: -gravity.dx / magnitude, dy: -gravity.dy / magnitude)
    }

    /// How far gravity moved from `old` to `new`, for the resting jar's wake
    /// check: the larger change of the two axes, as a fraction of `strength`.
    /// A sideways change reads exactly like the light's change
    /// (`JarTiltMath.lightFraction`), so `JarTiltMath.idleLightThreshold`
    /// keeps its meaning, and a turn with no sideways part (an upside-down
    /// flip) now counts too. Taking the larger axis, not the diagonal, keeps
    /// the promise that tremor below the threshold on each axis never wakes
    /// the jar. A non-finite vector is a rejected sample and moves nothing.
    static func wakeDelta(from old: CGVector, to new: CGVector) -> CGFloat {
        guard old.dx.isFinite, old.dy.isFinite, new.dx.isFinite, new.dy.isFinite else { return 0 }
        let change = max(abs(new.dx - old.dx), abs(new.dy - old.dy))
        return change / strength
    }

    // MARK: Private

    /// `vector` limited to `maximumMagnitude`.
    private static func capped(_ vector: CGVector) -> CGVector {
        let magnitude = hypot(vector.dx, vector.dy)
        guard magnitude > maximumMagnitude else { return vector }
        let scale = maximumMagnitude / magnitude
        return CGVector(dx: vector.dx * scale, dy: vector.dy * scale)
    }

    /// One finite gravity reading, scaled down to unit length when it is
    /// longer (Core Motion's gravity is a unit vector; a synthetic source or
    /// rounding can exceed it), so the jar never pulls harder than
    /// `strength`. A shorter reading keeps its length: a missing z must not
    /// turn the noise of a flat phone into full gravity.
    private struct UnitReading {
        let x: CGFloat
        let y: CGFloat
        let inPlaneFraction: CGFloat

        init?(x rawX: Double, y rawY: Double, z rawZ: Double) {
            guard rawX.isFinite, rawY.isFinite, rawZ.isFinite else { return nil }
            // Scaled by the largest component first, so huge finite readings
            // do not overflow.
            let largest = max(abs(rawX), abs(rawY), abs(rawZ))
            guard largest > 0 else {
                x = 0
                y = 0
                inPlaneFraction = 0
                return
            }
            let sx = rawX / largest
            let sy = rawY / largest
            let sz = rawZ / largest
            let scaledLength = (sx * sx + sy * sy + sz * sz).squareRoot()
            // `largest * scaledLength` may overflow to infinity; it is only
            // compared, and the unit vector comes from the scaled parts.
            let isLongerThanUnit = largest * scaledLength > 1
            let unitX = isLongerThanUnit ? sx / scaledLength : rawX
            let unitY = isLongerThanUnit ? sy / scaledLength : rawY
            x = CGFloat(unitX)
            y = CGFloat(unitY)
            inPlaneFraction = CGFloat(min(hypot(unitX, unitY), 1))
        }
    }
}
