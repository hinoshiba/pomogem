import CoreGraphics
import CoreMotion
import Foundation
import os

/// One device-motion sample, copied off `CMDeviceMotion` so it can cross
/// from Core Motion's queue to the main actor. Gravity is in g (the phone's
/// axes: +x toward the right edge, +y toward the top edge of a portrait
/// phone, +z out of the screen), user acceleration in g with gravity
/// removed, and the timestamp is Core Motion's (seconds of system uptime).
struct JarMotionSample: Equatable, Sendable {
    var gravityX: Double
    var gravityY: Double
    /// Out of the screen: −1 for a phone lying face up. It tells a phone
    /// lying flat (whose in-screen gravity is only noise) from one held up.
    var gravityZ: Double = 0
    var accelerationX: Double = 0
    var accelerationY: Double = 0
    var accelerationZ: Double = 0
    var timestamp: TimeInterval

    init(
        gravityX: Double,
        gravityY: Double,
        gravityZ: Double = 0,
        accelerationX: Double = 0,
        accelerationY: Double = 0,
        accelerationZ: Double = 0,
        timestamp: TimeInterval
    ) {
        self.gravityX = gravityX
        self.gravityY = gravityY
        self.gravityZ = gravityZ
        self.accelerationX = accelerationX
        self.accelerationY = accelerationY
        self.accelerationZ = accelerationZ
        self.timestamp = timestamp
    }

    init(motion: CMDeviceMotion) {
        self.init(
            gravityX: motion.gravity.x,
            gravityY: motion.gravity.y,
            gravityZ: motion.gravity.z,
            accelerationX: motion.userAcceleration.x,
            accelerationY: motion.userAcceleration.y,
            accelerationZ: motion.userAcceleration.z,
            timestamp: motion.timestamp
        )
    }

    /// The sensed gravity in the jar's interface, or nil when the sample is
    /// not finite (it is ignored). Home and the jar are portrait-only
    /// (`PomoGemAppDelegate`), so the phone's axes are the jar's.
    var gravityReading: JarGravityMapping.Reading? {
        JarGravityMapping.Reading(
            deviceGravityX: gravityX,
            deviceGravityY: gravityY,
            deviceGravityZ: gravityZ,
            interfaceOrientation: .portrait
        )
    }

    /// The gravity this sample asks of the jar (before smoothing), or nil
    /// when the sample is not finite.
    var proposedGravity: CGVector? {
        JarTiltMath.proposedGravity(gravityX: gravityX, gravityY: gravityY, gravityZ: gravityZ)
    }

    var accelerationMagnitude: Double {
        let magnitude = sqrt(
            accelerationX * accelerationX
                + accelerationY * accelerationY
                + accelerationZ * accelerationZ
        )
        return magnitude.isFinite ? magnitude : 0
    }
}

/// The tilt arithmetic shared by the scene (main actor) and the resting
/// jar's tilt check (Core Motion's background queue), so both hold the
/// same smoothed gravity and the same light.
enum JarTiltMath {
    /// The idle light step (Docs/GemExperienceDesign.md §7.13): a resting
    /// jar redraws its light only when the smoothed tilt moves it by more
    /// than this (on the −1…1 light scale). The sensor noise of a phone held
    /// still (about ±0.012) stays below it.
    static let idleLightThreshold: CGFloat = 0.015

    /// F3: how far the phone must turn from the pose the resting pile
    /// settled under (`JarGravityMapping.wakeDelta`, in g) before the pile
    /// re-settles under the new gravity (`JarGravityMapping.needsResettle`).
    /// About 6°: well above the tremor of a phone held still (±0.012 g) and
    /// the few degrees a hand drifts while reading, so a held phone does
    /// not keep waking the physics, while any deliberate turn toward
    /// sideways or upside down passes it within an idle sample or two.
    /// Smaller tilts move only the light, as before.
    static let reorientationWakeThreshold: CGFloat = 0.1

    /// F3: the smallest change of the jar's gravity direction (radians, 3°)
    /// that re-settles a resting pile. A change of strength alone (putting
    /// the phone down, leaning it back) leaves the pile where it is.
    static let reorientationMinimumTurn: CGFloat = 3 * .pi / 180

    /// F3: the smallest change of the jar's gravity direction (radians, 15°)
    /// from the pose an awake pile has been following that opens its
    /// interaction window again (`JarGravityMapping.needsRefollow`). A
    /// resting pile measures a turn from the fixed pose it settled in; an
    /// awake one would measure it from the last swing that reopened the
    /// window, so a hand swaying a few degrees each way while reading (or
    /// walking) would pass the ~6° wake on every swing and keep the physics
    /// awake indefinitely. Past 15° a turn is deliberate (a lean, sideways,
    /// upside down): reopenings are bounded by how far the phone turns.
    /// Smaller turns while awake move the pile within the open window, as
    /// any tilt did before F3.
    static let refollowMinimumTurn: CGFloat = 15 * .pi / 180

    /// The jar's gravity for one Core Motion gravity reading (F3,
    /// `JarGravityMapping`): toward the physically lowest screen edge,
    /// sideways and upward included, blended to the default downward
    /// gravity for a phone lying flat. Nil when the reading is not finite
    /// (the sample is ignored).
    static func proposedGravity(
        gravityX: Double,
        gravityY: Double,
        gravityZ: Double
    ) -> CGVector? {
        JarGravityMapping.acceptedGravity(
            deviceGravityX: gravityX,
            deviceGravityY: gravityY,
            deviceGravityZ: gravityZ,
            interfaceOrientation: .portrait
        )
    }

    /// `proposed` limited to the jar's strongest gravity; nil when it is
    /// not finite.
    static func clamped(_ proposed: CGVector) -> CGVector? {
        guard proposed.dx.isFinite, proposed.dy.isFinite else { return nil }
        let magnitude = hypot(proposed.dx, proposed.dy)
        let maximum = max(Constants.Jar.maximumExternalGravityMagnitude, 0.1)
        let scale = magnitude > maximum ? maximum / magnitude : 1
        return CGVector(dx: proposed.dx * scale, dy: proposed.dy * scale)
    }

    /// One smoothing step from `current` toward `target`.
    static func smoothed(
        from current: CGVector,
        toward target: CGVector,
        fraction: CGFloat
    ) -> CGVector {
        let step = min(max(fraction, 0), 1)
        return CGVector(
            dx: current.dx + (target.dx - current.dx) * step,
            dy: current.dy + (target.dy - current.dy) * step
        )
    }

    /// The per-sample smoothing at `updatesPerSecond` that follows the
    /// sensor as fast (per second) as the scene's smoothing at
    /// `Constants.Jar.tiltUpdatesPerSecond`.
    static func smoothingFraction(updatesPerSecond: Double) -> CGFloat {
        let base = min(max(Constants.Jar.gravitySmoothingFactor, 0), 1)
        guard updatesPerSecond.isFinite, updatesPerSecond > 0 else { return base }
        let steps = Double(Constants.Jar.tiltUpdatesPerSecond) / updatesPerSecond
        return 1 - CGFloat(pow(Double(1 - base), steps))
    }

    /// Where the jar's light sits for a light horizontal (−1…1): the
    /// sensed sideways reading (`JarGravityMapping.lightHorizontal`), or a
    /// directly set gravity's dx.
    static func lightFraction(horizontal: CGFloat) -> CGFloat {
        guard horizontal.isFinite else { return 0 }
        return min(max(horizontal / Constants.Jar.tiltLightHorizontalScale, -1), 1)
    }
}

/// How often the jar samples device motion, and where the samples go
/// (Docs/GemExperienceDesign.md §7.13).
enum JarMotionRate: Equatable, Sendable {
    /// No updates: Home hidden or covered, the app not active, no study
    /// gem in the jar, or motion switched off.
    case stopped
    /// The awake jar (and a tilt that is moving the light): every sample on
    /// the main queue, applied to gravity, light and the shake detector.
    case full
    /// The resting jar: a few samples a second on a background queue. Only
    /// a tilt that would move the light, a turn the pile must re-settle for
    /// (F3), or a shake peak reaches main.
    case idle

    static let idleUpdatesPerSecond: Double = 5
    static var fullUpdatesPerSecond: Double { Double(Constants.Jar.tiltUpdatesPerSecond) }

    static func resolve(
        sampling: JarMotionSamplingMode,
        jarWantsFullRate: Bool
    ) -> JarMotionRate {
        guard sampling != .stopped else { return .stopped }
        return jarWantsFullRate ? .full : .idle
    }

    var updatesPerSecond: Double? {
        switch self {
        case .stopped: nil
        case .full: Self.fullUpdatesPerSecond
        case .idle: Self.idleUpdatesPerSecond
        }
    }
}

/// The resting jar's tilt check. It runs on Core Motion's background queue
/// at the idle rate, keeps the smoothed reading the scene would keep (its
/// smoothing rescaled to the idle rate) and asks the main actor to wake the
/// jar only when
/// - the phone turned from the pose the pile settled under and the jar's
///   gravity turned with it (`JarGravityMapping.needsResettle`; F3: the
///   pile re-settles under the new gravity; not gated by `followsTilt`, so
///   Reduce Motion keeps the same physics), or
/// - the smoothed tilt would move the drawn light by more than
///   `JarTiltMath.idleLightThreshold` (only while the light follows tilt),
///   or
/// - a shake peak arrives.
/// A phone on a desk or held still never reaches main.
struct JarIdleTiltFilter: Equatable, Sendable {
    enum Wake: Equatable, Sendable {
        /// The light would move: redraw it, the physics keeps resting.
        case tilt
        case shake
        /// The phone turned from the pose the pile settled under: the pile
        /// re-settles (a bounded interaction window).
        case reorient
    }

    /// The smoothed sensed reading, as the scene would hold it; nil until
    /// the first finite sample when the scene had none (motion just started
    /// on a reset jar), which then stands as it is: smoothing from "flat"
    /// toward an upright phone would pass through the blend band and fake
    /// a turn.
    private(set) var reading: JarGravityMapping.Reading?
    /// The reading the resting pile settled under (`.flat` for the jar's
    /// default gravity).
    let settledReading: JarGravityMapping.Reading
    /// The light on screen (−1…1).
    var drawnLight: CGFloat
    /// Reduce Motion keeps the light still, so no light wake then (the
    /// reading is still tracked, and a turn still re-settles the pile).
    var followsTilt: Bool
    let smoothing: CGFloat

    /// The jar's gravity for the smoothed reading (its default gravity
    /// before any reading).
    var gravity: CGVector {
        reading.map(JarGravityMapping.gravity(for:)) ?? JarGravityMapping.defaultGravity
    }

    init(
        reading: JarGravityMapping.Reading?,
        settledReading: JarGravityMapping.Reading = .flat,
        drawnLight: CGFloat,
        followsTilt: Bool,
        updatesPerSecond: Double = JarMotionRate.idleUpdatesPerSecond
    ) {
        self.reading = reading
        self.settledReading = settledReading
        self.drawnLight = drawnLight.isFinite ? drawnLight : 0
        self.followsTilt = followsTilt
        smoothing = JarTiltMath.smoothingFraction(updatesPerSecond: updatesPerSecond)
    }

    mutating func ingest(_ sample: JarMotionSample) -> Wake? {
        if let sensed = sample.gravityReading {
            reading = reading.map { $0.smoothed(toward: sensed, fraction: smoothing) } ?? sensed
        }
        if sample.accelerationMagnitude >= Constants.Jar.deviceShakeThreshold {
            return .shake
        }
        guard let reading else { return nil }
        if JarGravityMapping.needsResettle(from: settledReading, to: reading) {
            return .reorient
        }
        guard followsTilt else { return nil }
        let light = JarTiltMath.lightFraction(horizontal: JarGravityMapping.lightHorizontal(for: reading))
        return abs(light - drawnLight) > JarTiltMath.idleLightThreshold ? .tilt : nil
    }
}

/// What the idle tilt check hands to the main actor.
struct JarIdleWake: Equatable, Sendable {
    let reason: JarIdleTiltFilter.Wake
    /// The smoothed reading when the wake was decided.
    let reading: JarGravityMapping.Reading?
    let sample: JarMotionSample
}

/// Thread-safe home of the idle tilt check: Core Motion's background queue
/// ingests samples; the main actor arms, adjusts and disarms it. A run is
/// identified by the observer's generation, so a late sample from a
/// stopped or superseded run changes nothing, and one armed run wakes main
/// at most once.
final class JarIdleTiltMonitor: Sendable {
    private struct State: Sendable {
        var generation: UInt64?
        var filter: JarIdleTiltFilter?
        var isWakePending = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func arm(_ filter: JarIdleTiltFilter, generation: UInt64) {
        state.withLock { $0 = State(generation: generation, filter: filter) }
    }

    /// Ends the run and returns its latest smoothed reading, if it had one.
    @discardableResult
    func disarm() -> JarGravityMapping.Reading? {
        state.withLock { state in
            let reading = state.filter?.reading
            state = State()
            return reading
        }
    }

    func setFollowsTilt(_ followsTilt: Bool) {
        state.withLock { $0.filter?.followsTilt = followsTilt }
    }

    var isArmed: Bool {
        state.withLock { $0.filter != nil }
    }

    /// Called on Core Motion's queue. Returns the wake to hand to main, at
    /// most once per armed run.
    func ingest(_ sample: JarMotionSample, generation: UInt64) -> JarIdleWake? {
        state.withLock { state in
            guard state.generation == generation, var filter = state.filter else { return nil }
            let reason = filter.ingest(sample)
            state.filter = filter
            guard let reason, !state.isWakePending else { return nil }
            state.isWakePending = true
            return JarIdleWake(reason: reason, reading: filter.reading, sample: sample)
        }
    }
}

/// Where the jar's device-motion samples come from: Core Motion on a
/// device; a scripted stream in tests and in Debug Simulator runs (the
/// Simulator has no motion hardware).
@MainActor
protocol JarMotionSource: AnyObject {
    var isAvailable: Bool { get }
    /// Starts delivering samples onto `queue` at `updatesPerSecond`,
    /// replacing any earlier run.
    func start(
        updatesPerSecond: Double,
        queue: OperationQueue,
        handler: @escaping @Sendable (JarMotionSample) -> Void
    )
    func stop()
}

@MainActor
final class CoreMotionJarMotionSource: JarMotionSource {
    private let manager = CMMotionManager()

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start(
        updatesPerSecond: Double,
        queue: OperationQueue,
        handler: @escaping @Sendable (JarMotionSample) -> Void
    ) {
        // A new rate or queue needs a new run.
        if manager.isDeviceMotionActive {
            manager.stopDeviceMotionUpdates()
        }
        manager.deviceMotionUpdateInterval = 1 / max(updatesPerSecond, 1)
        manager.startDeviceMotionUpdates(to: queue, withHandler: Self.handler(delivering: handler))
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    /// Made outside the main actor: Core Motion calls it on the run's
    /// queue, which is a background queue at the idle rate.
    nonisolated private static func handler(
        delivering deliver: @escaping @Sendable (JarMotionSample) -> Void
    ) -> CMDeviceMotionHandler {
        { motion, _ in
            guard let motion else { return }
            deliver(JarMotionSample(motion: motion))
        }
    }
}
