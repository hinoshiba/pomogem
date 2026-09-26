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
///    remains" clamp (`tiltGravityMinimumDownward`, removed), sideways
///    and upward gravity are allowed: an upside-down phone pulls the gems
///    toward the mouth, which must then act as closed (`isUpward(_:)`).
/// 3. A phone lying flat has almost no in-screen gravity, and its direction is
///    only sensor noise. The result blends from the jar's default downward
///    gravity (flat) to the sensed gravity (upright) with a smoothstep of the
///    in-screen fraction `s` between `flatInPlaneFraction` and
///    `uprightInPlaneFraction`. A phone on a desk behaves like the jar with
///    motion off, and tilting it up follows real gravity continuously.
///
/// The blend makes the jar's gravity move up to about 7 times faster than
/// the reading inside its band, so nothing that must ignore sensor noise
/// reads the blended gravity. How the scene uses this:
/// - `JarScene.setGravityReading` smooths the sensed `Reading`
///   (`Reading.smoothed`), not the mapped gravity, and maps the smoothed
///   reading with `gravity(for:)`.
/// - The light (`applyOpticalTilt`, and the resting jar's light check in
///   `JarIdleTiltFilter`) is drawn from `lightHorizontal(for:)`, never from
///   the gravity's dx: a phone on a desk keeps exactly the default gravity,
///   but its glints still follow it.
/// - A resting jar wakes for a turn when `needsResettle(from:to:)` between
///   the reading the pile settled under and the smoothed reading: the
///   phone turned by more than `JarTiltMath.reorientationWakeThreshold`
///   (`wakeDelta`, about 6°, well above the light's `idleLightThreshold`)
///   and the jar's gravity changed direction, through the bounded
///   interaction window.
/// - Taps and shakes throw along `launchDirection(for:)` of the applied
///   gravity.
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

    /// The in-screen part of one finite Core Motion gravity reading, in g,
    /// in the interface's axes, before any blending: what the sensor says.
    /// A reading longer than 1 g is scaled back to unit length (Core
    /// Motion's gravity is a unit vector; a synthetic source or rounding can
    /// exceed it), so the jar never pulls harder than `strength`. A shorter
    /// reading keeps its length: a missing z must not turn the noise of a
    /// flat phone into full gravity. Only the length uses z, so the reading
    /// keeps x and y, and |(x, y)| ≤ 1 always holds.
    struct Reading: Equatable, Sendable {
        /// Toward the interface's right edge.
        let x: CGFloat
        /// Toward the interface's top edge.
        let y: CGFloat

        /// A phone lying flat: no in-screen gravity. The jar keeps
        /// `defaultGravity` and a level light, as with motion off.
        static let flat = Reading(x: 0, y: 0)

        /// Nil when the reading is not finite (the sample is ignored).
        init?(
            deviceGravityX: Double,
            deviceGravityY: Double,
            deviceGravityZ: Double,
            interfaceOrientation: InterfaceOrientation = .portrait
        ) {
            guard deviceGravityX.isFinite, deviceGravityY.isFinite, deviceGravityZ.isFinite else {
                return nil
            }
            // Scaled by the largest component first, so huge finite readings
            // do not overflow.
            let largest = max(abs(deviceGravityX), abs(deviceGravityY), abs(deviceGravityZ))
            guard largest > 0 else {
                self = .flat
                return
            }
            let sx = deviceGravityX / largest
            let sy = deviceGravityY / largest
            let sz = deviceGravityZ / largest
            let scaledLength = (sx * sx + sy * sy + sz * sz).squareRoot()
            // `largest * scaledLength` may overflow to infinity; it is only
            // compared, and the unit vector comes from the scaled parts.
            let isLongerThanUnit = largest * scaledLength > 1
            let unitX = isLongerThanUnit ? sx / scaledLength : deviceGravityX
            let unitY = isLongerThanUnit ? sy / scaledLength : deviceGravityY
            let inScreen = interfaceOrientation.interfaceVector(deviceX: CGFloat(unitX), deviceY: CGFloat(unitY))
            self.init(x: inScreen.dx, y: inScreen.dy)
        }

        private init(x: CGFloat, y: CGFloat) {
            self.x = x
            self.y = y
        }

        /// The share of gravity lying in the screen's plane (0 flat … 1
        /// upright).
        var inPlaneFraction: CGFloat {
            min(hypot(x, y), 1)
        }

        /// One smoothing step toward `target`, as `JarTiltMath.smoothed`
        /// steps the scene's gravity. The step is a weighted mean of two
        /// readings, so a smoothed reading that starts at a pose stays
        /// within any per-axis distance of it that every sample keeps.
        /// A fraction that is not finite keeps this reading.
        func smoothed(toward target: Reading, fraction: CGFloat) -> Reading {
            guard fraction.isFinite else { return self }
            let step = min(max(fraction, 0), 1)
            return Reading(
                x: x * (1 - step) + target.x * step,
                y: y * (1 - step) + target.y * step
            )
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

    /// Gravity weaker than this (10% of `strength`) has no direction to
    /// trust, as while the flat-phone blend passes through zero on a phone
    /// tipping top-down from flat. It counts as upward (`isUpward(_:)`), and
    /// taps and shakes throw toward the jar's own up (`launchDirection`).
    static var weakGravityMagnitude: CGFloat { 0.1 * strength }

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
    /// finite (the sample is ignored).
    static func acceptedGravity(
        deviceGravityX: Double,
        deviceGravityY: Double,
        deviceGravityZ: Double,
        interfaceOrientation: InterfaceOrientation = .portrait
    ) -> CGVector? {
        Reading(
            deviceGravityX: deviceGravityX,
            deviceGravityY: deviceGravityY,
            deviceGravityZ: deviceGravityZ,
            interfaceOrientation: interfaceOrientation
        ).map(gravity(for:))
    }

    /// The jar's gravity for a (possibly smoothed) reading: the sensed
    /// gravity blended with `defaultGravity` by `followWeight`. Never longer
    /// than `strength`, since both ends of the blend are at most that long.
    static func gravity(for reading: Reading) -> CGVector {
        let weight = followWeight(inPlaneFraction: reading.inPlaneFraction)
        guard weight > 0 else { return defaultGravity }
        let sensed = CGVector(dx: reading.x * strength, dy: reading.y * strength)
        let blended = CGVector(
            dx: weight * sensed.dx + (1 - weight) * defaultGravity.dx,
            dy: weight * sensed.dy + (1 - weight) * defaultGravity.dy
        )
        return capped(blended)
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

    /// `vector` limited to `maximumMagnitude`, in the same direction; for
    /// finite vectors. Defence in depth: with today's constants the blend
    /// never exceeds `strength` (7.2 < 9.4), so this engages only if the
    /// jar's gravity is ever tuned above the cap.
    static func capped(_ vector: CGVector) -> CGVector {
        let magnitude = hypot(vector.dx, vector.dy)
        guard magnitude > maximumMagnitude else { return vector }
        let scale = maximumMagnitude / magnitude
        return CGVector(dx: vector.dx * scale, dy: vector.dy * scale)
    }

    // MARK: Helpers for the scene (D3.3)

    /// The horizontal the jar's light follows (scene units, for
    /// `JarTiltMath.lightFraction`): the sensed sideways gravity, never
    /// blended. In portrait it is the former `gx × 7.2`
    /// (`Constants.Jar.tiltLightHorizontalScale`), so a phone lying on a
    /// desk still moves its glints when tilted although its gravity stays
    /// exactly `defaultGravity`.
    static func lightHorizontal(for reading: Reading) -> CGFloat {
        reading.x * Constants.Jar.tiltLightHorizontalScale
    }

    /// `lightHorizontal(for:)` of one reading, or nil when the reading is
    /// not finite (the light keeps its place).
    static func lightHorizontal(
        deviceGravityX: Double,
        deviceGravityY: Double,
        deviceGravityZ: Double,
        interfaceOrientation: InterfaceOrientation = .portrait
    ) -> CGFloat? {
        Reading(
            deviceGravityX: deviceGravityX,
            deviceGravityY: deviceGravityY,
            deviceGravityZ: deviceGravityZ,
            interfaceOrientation: interfaceOrientation
        ).map(lightHorizontal(for:))
    }

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
    /// gravity. Gravity too weak to trust (`weakGravityMagnitude`, the same
    /// line `isUpward` draws) or undefined throws toward the jar's own up,
    /// (0, 1), as the default gravity does: while the blend passes through
    /// zero the gems still lie on the floor. On a phone tipping top-down
    /// from flat the throw therefore reverses once, where gravity first
    /// pulls toward the mouth at `weakGravityMagnitude`, not where it
    /// crosses zero.
    static func launchDirection(for gravity: CGVector) -> CGVector {
        let up = CGVector(dx: 0, dy: 1)
        guard gravity.dx.isFinite, gravity.dy.isFinite else { return up }
        let magnitude = hypot(gravity.dx, gravity.dy)
        guard magnitude >= weakGravityMagnitude else { return up }
        return CGVector(dx: -gravity.dx / magnitude, dy: -gravity.dy / magnitude)
    }

    /// F3: whether a resting pile that settled under the reading `settled`
    /// must re-settle for `current` (the smoothed reading). Both must hold:
    /// - the phone turned: `wakeDelta` exceeds
    ///   `JarTiltMath.reorientationWakeThreshold` (measured on the sensor,
    ///   so a phone held still never passes it, at any pose);
    /// - the jar's gravity turned, not only grew or weakened: its direction
    ///   moved by more than `JarTiltMath.reorientationMinimumTurn`. Putting
    ///   the phone down, picking it up or leaning it back moves the gravity
    ///   through the flat-phone blend without turning it, and the pile has
    ///   nothing to redo.
    /// A current gravity too weak to have a direction
    /// (`weakGravityMagnitude`) waits; a pile that settled in such a weak
    /// gravity re-settles for any real one.
    static func needsResettle(from settled: Reading, to current: Reading) -> Bool {
        guard wakeDelta(from: settled, to: current) > JarTiltMath.reorientationWakeThreshold else {
            return false
        }
        let old = gravity(for: settled)
        let new = gravity(for: current)
        let newMagnitude = hypot(new.dx, new.dy)
        guard newMagnitude >= weakGravityMagnitude else { return false }
        let oldMagnitude = hypot(old.dx, old.dy)
        guard oldMagnitude >= weakGravityMagnitude else { return true }
        let cosine = (old.dx * new.dx + old.dy * new.dy) / (oldMagnitude * newMagnitude)
        return cosine < cos(JarTiltMath.reorientationMinimumTurn)
    }

    /// How far the phone turned from `old` to `new`, for the resting jar's
    /// wake check, on the light's scale so `JarTiltMath.idleLightThreshold`
    /// keeps its meaning. It is the smaller of two changes:
    /// - the sensed in-screen gravity's larger per-axis change, in g. For a
    ///   sideways turn that is exactly the light's change. Measured on the
    ///   sensor, not on the blended gravity (which moves up to about 7 times
    ///   faster inside the blend band), so tremor that keeps every sample
    ///   within the threshold of the settled reading on each axis never
    ///   wakes the jar, at any pose;
    /// - the jar's gravity's larger per-axis change, as a fraction of
    ///   `strength`. A turn that leaves the jar's gravity alone (a phone
    ///   tilting on a desk, below the blend) wakes nothing; its light has
    ///   its own check (`lightHorizontal`).
    /// Held upright both are equal. An upside-down flip reads 2.
    static func wakeDelta(from old: Reading, to new: Reading) -> CGFloat {
        let sensorChange = max(abs(new.x - old.x), abs(new.y - old.y))
        let oldGravity = gravity(for: old)
        let newGravity = gravity(for: new)
        let gravityChange = max(
            abs(newGravity.dx - oldGravity.dx),
            abs(newGravity.dy - oldGravity.dy)
        ) / strength
        return min(sensorChange, gravityChange)
    }
}
