#if DEBUG && targetEnvironment(simulator)
import Foundation

/// `POMOGEM_UI_TEST_IDLE_ENERGY=0` (with the in-memory UI-test launch): a
/// resting jar keeps its render loop running and its motion at the full
/// rate, as before jar-01 and the idle motion rate, for A/B measurements.
enum JarIdleEnergyDebug {
    static let keepsRestingJarAwake: Bool = LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess
        && ProcessInfo.processInfo.environment["POMOGEM_UI_TEST_IDLE_ENERGY"] == "0"
}

/// F3 (Docs/JarOrientationGravity.md): a fixed phone pose for the
/// Simulator, named after `UIDeviceOrientation`. Its Core Motion gravity is
/// in the phone's axes (+x right edge, +y top edge, +z out of the screen).
enum JarGravityPose: String, CaseIterable, Sendable {
    /// Upright portrait: (0, −1, 0). The jar's default.
    case portrait
    /// Home button (bottom edge) on the right, top edge on the left: the
    /// screen's left edge is lowest, (−1, 0, 0).
    case landscapeLeft = "landscape-left"
    /// Top edge on the right: the screen's right edge is lowest, (1, 0, 0).
    case landscapeRight = "landscape-right"
    /// Upside down: the top edge is lowest, (0, 1, 0).
    case upsideDown = "upside-down"
    /// Lying face up on a desk: (0, 0, −1).
    case flat
    /// Lying face down: (0, 0, 1).
    case faceDown = "face-down"

    var gravity: (x: Double, y: Double, z: Double) {
        switch self {
        case .portrait: (0, -1, 0)
        case .landscapeLeft: (-1, 0, 0)
        case .landscapeRight: (1, 0, 0)
        case .upsideDown: (0, 1, 0)
        case .flat: (0, 0, -1)
        case .faceDown: (0, 0, 1)
        }
    }
}

/// `POMOGEM_UI_TEST_GRAVITY=<pose>[,<pose>@<seconds>…]`: the phone held in
/// fixed poses, each from `seconds` after the jar first samples motion
/// (the first pose from 0), e.g. `portrait,landscape-left@4,upside-down@12`
/// to exercise F3's sideways, upside-down and flipping jar. Poses are
/// `JarGravityPose` raw values. With `POMOGEM_UI_TEST_MOTION=synthetic` it
/// plays through `SyntheticJarMotionSource` (the motion observer and its
/// rates, the idle check's reorientation wake included); without it
/// `JarFrameProbe` feeds the scene's gravity reading directly at 30 Hz.
struct JarGravitySchedule: Sendable {
    let steps: [(start: Double, pose: JarGravityPose)]

    static let forCurrentProcess: JarGravitySchedule? = {
        guard LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess,
              let value = ProcessInfo.processInfo.environment["POMOGEM_UI_TEST_GRAVITY"]
        else { return nil }
        return JarGravitySchedule(parsing: value)
    }()

    init?(parsing value: String) {
        var steps: [(start: Double, pose: JarGravityPose)] = []
        for item in value.split(separator: ",") {
            let parts = item.split(separator: "@")
            guard parts.count <= 2,
                  let name = parts.first,
                  let pose = JarGravityPose(rawValue: name.trimmingCharacters(in: .whitespaces))
            else { return nil }
            var start = 0.0
            if parts.count == 2 {
                guard let seconds = Double(parts[1]), seconds.isFinite, seconds >= 0 else { return nil }
                start = seconds
            }
            steps.append((start, pose))
        }
        guard !steps.isEmpty else { return nil }
        self.steps = steps.sorted { $0.start < $1.start }
    }

    /// The pose at `elapsed` seconds.
    func pose(elapsed: Double) -> JarGravityPose {
        steps.last { $0.start <= elapsed }?.pose ?? steps[0].pose
    }
}

/// Debug-only stand-in for Core Motion in the Simulator, which has no motion
/// hardware (so the jar's motion observer never runs there). Active only
/// with the in-memory UI-test launch and `POMOGEM_UI_TEST_MOTION=synthetic`.
///
/// Like Core Motion it wakes on its own timer thread at the requested rate
/// and delivers onto the requested queue, so the jar's motion rates
/// (Docs/GemExperienceDesign.md §7.13) and the wake-ups they cost can be
/// reviewed without a device. The phone is held upright and still; a
/// `POMOGEM_UI_TEST_TILT_SWEEP` (seconds after the jar first samples motion)
/// is played through this stream instead of being fed to the scene
/// directly, and a `POMOGEM_UI_TEST_GRAVITY` pose schedule (F3) replaces
/// the upright pose.
@MainActor
final class SyntheticJarMotionSource: JarMotionSource {
    static let isRequested: Bool = LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess
        && ProcessInfo.processInfo.environment["POMOGEM_UI_TEST_MOTION"] == "synthetic"

    static func forCurrentProcess() -> SyntheticJarMotionSource? {
        isRequested
            ? SyntheticJarMotionSource(sweep: JarTiltSweep.forCurrentProcess, poses: JarGravitySchedule.forCurrentProcess)
            : nil
    }

    private let sweep: JarTiltSweep?
    private let poses: JarGravitySchedule?
    private let timerQueue = DispatchQueue(label: "PomoGem.SyntheticJarMotion", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// When the jar first sampled motion (the sweep's time origin).
    private var firstStart: TimeInterval?

    init(sweep: JarTiltSweep?, poses: JarGravitySchedule? = nil) {
        self.sweep = sweep
        self.poses = poses
    }

    var isAvailable: Bool { true }

    func start(
        updatesPerSecond: Double,
        queue: OperationQueue,
        handler: @escaping @Sendable (JarMotionSample) -> Void
    ) {
        stop()
        let origin = firstStart ?? ProcessInfo.processInfo.systemUptime
        firstStart = origin
        let sweep = sweep
        let poses = poses
        let interval = 1 / max(updatesPerSecond, 1)
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(2)
        )
        timer.setEventHandler {
            let now = ProcessInfo.processInfo.systemUptime
            let sample: JarMotionSample
            if let poses {
                let gravity = poses.pose(elapsed: now - origin).gravity
                sample = JarMotionSample(
                    gravityX: gravity.x,
                    gravityY: gravity.y,
                    gravityZ: gravity.z,
                    timestamp: now
                )
            } else {
                let gravityX = sweep?.gravityX(elapsed: now - origin) ?? 0
                sample = JarMotionSample(
                    gravityX: gravityX,
                    gravityY: -(1 - gravityX * gravityX).squareRoot(),
                    timestamp: now
                )
            }
            queue.addOperation { handler(sample) }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
#endif
