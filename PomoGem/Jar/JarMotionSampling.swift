import CoreGraphics
import CoreMotion
import Foundation
import os

/// One device-motion sample, copied off `CMDeviceMotion` so it can cross
/// from Core Motion's queue to the main actor. Gravity is in g (the phone's
/// axes), user acceleration in g with gravity removed, and the timestamp is
/// Core Motion's (seconds of system uptime).
struct JarMotionSample: Equatable, Sendable {
    var gravityX: Double
    var gravityY: Double
    var accelerationX: Double = 0
    var accelerationY: Double = 0
    var accelerationZ: Double = 0
    var timestamp: TimeInterval

    init(
        gravityX: Double,
        gravityY: Double,
        accelerationX: Double = 0,
        accelerationY: Double = 0,
        accelerationZ: Double = 0,
        timestamp: TimeInterval
    ) {
        self.gravityX = gravityX
        self.gravityY = gravityY
        self.accelerationX = accelerationX
        self.accelerationY = accelerationY
        self.accelerationZ = accelerationZ
        self.timestamp = timestamp
    }

    init(motion: CMDeviceMotion) {
        self.init(
            gravityX: motion.gravity.x,
            gravityY: motion.gravity.y,
            accelerationX: motion.userAcceleration.x,
            accelerationY: motion.userAcceleration.y,
            accelerationZ: motion.userAcceleration.z,
            timestamp: motion.timestamp
        )
    }

    /// The gravity this sample asks of the jar (before smoothing).
    var proposedGravity: CGVector {
        JarTiltMath.proposedGravity(gravityX: gravityX, gravityY: gravityY)
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

    /// Sideways tilt pushes the gems sideways; some downward pull always
    /// remains, however flat the phone lies.
    static func proposedGravity(gravityX: Double, gravityY: Double) -> CGVector {
        let horizontal = CGFloat(gravityX) * Constants.Jar.tiltGravityHorizontalScale
        let sensedVertical = CGFloat(gravityY) * abs(Constants.Jar.gravity)
        let vertical = min(-Constants.Jar.tiltGravityMinimumDownward, sensedVertical)
        return CGVector(dx: horizontal, dy: vertical)
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

    /// Where the jar's light sits for a horizontal gravity (−1…1).
    static func lightFraction(horizontal: CGFloat) -> CGFloat {
        guard horizontal.isFinite else { return 0 }
        return min(max(horizontal / Constants.Jar.tiltGravityHorizontalScale, -1), 1)
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
    /// a tilt that would move the light, or a shake peak, reaches main.
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
/// at the idle rate, keeps the smoothed gravity the scene would keep (its
/// smoothing rescaled to the idle rate) and asks the main actor to wake the
/// jar only when that smoothed tilt would move the drawn light by more than
/// `JarTiltMath.idleLightThreshold`, or when a shake peak arrives. A phone
/// on a desk or held still never reaches main.
struct JarIdleTiltFilter: Equatable, Sendable {
    enum Wake: Equatable, Sendable {
        case tilt
        case shake
    }

    /// Smoothed gravity (scene units), as the scene would hold it.
    private(set) var gravity: CGVector
    /// The light on screen (−1…1).
    var drawnLight: CGFloat
    /// Reduce Motion keeps the light still, so only a shake peak wakes the
    /// jar then (its gravity is still tracked for the next wake).
    var followsTilt: Bool
    let smoothing: CGFloat

    init(
        gravity: CGVector,
        drawnLight: CGFloat,
        followsTilt: Bool,
        updatesPerSecond: Double = JarMotionRate.idleUpdatesPerSecond
    ) {
        self.gravity = JarTiltMath.clamped(gravity) ?? Constants.Jar.gravityVector
        self.drawnLight = drawnLight.isFinite ? drawnLight : 0
        self.followsTilt = followsTilt
        smoothing = JarTiltMath.smoothingFraction(updatesPerSecond: updatesPerSecond)
    }

    mutating func ingest(_ sample: JarMotionSample) -> Wake? {
        if let target = JarTiltMath.clamped(sample.proposedGravity) {
            gravity = JarTiltMath.smoothed(from: gravity, toward: target, fraction: smoothing)
        }
        if sample.accelerationMagnitude >= Constants.Jar.deviceShakeThreshold {
            return .shake
        }
        guard followsTilt else { return nil }
        let light = JarTiltMath.lightFraction(horizontal: gravity.dx)
        return abs(light - drawnLight) > JarTiltMath.idleLightThreshold ? .tilt : nil
    }
}

/// What the idle tilt check hands to the main actor.
struct JarIdleWake: Equatable, Sendable {
    let reason: JarIdleTiltFilter.Wake
    /// The smoothed gravity when the wake was decided.
    let gravity: CGVector
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

    /// Ends the run and returns its latest smoothed gravity, if it had one.
    @discardableResult
    func disarm() -> CGVector? {
        state.withLock { state in
            let gravity = state.filter?.gravity
            state = State()
            return gravity
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
            return JarIdleWake(reason: reason, gravity: filter.gravity, sample: sample)
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
