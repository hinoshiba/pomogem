#if DEBUG && targetEnvironment(simulator)
import Foundation

/// `POMOGEM_UI_TEST_IDLE_ENERGY=0` (with the in-memory UI-test launch): a
/// resting jar keeps its render loop running and its motion at the full
/// rate, as before jar-01 and the idle motion rate, for A/B measurements.
enum JarIdleEnergyDebug {
    static let keepsRestingJarAwake: Bool = LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess
        && ProcessInfo.processInfo.environment["POMOGEM_UI_TEST_IDLE_ENERGY"] == "0"
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
/// directly.
@MainActor
final class SyntheticJarMotionSource: JarMotionSource {
    static let isRequested: Bool = LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess
        && ProcessInfo.processInfo.environment["POMOGEM_UI_TEST_MOTION"] == "synthetic"

    static func forCurrentProcess() -> SyntheticJarMotionSource? {
        isRequested ? SyntheticJarMotionSource(sweep: JarTiltSweep.forCurrentProcess) : nil
    }

    private let sweep: JarTiltSweep?
    private let timerQueue = DispatchQueue(label: "PomoGem.SyntheticJarMotion", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// When the jar first sampled motion (the sweep's time origin).
    private var firstStart: TimeInterval?

    init(sweep: JarTiltSweep?) {
        self.sweep = sweep
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
        let interval = 1 / max(updatesPerSecond, 1)
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(2)
        )
        timer.setEventHandler {
            let now = ProcessInfo.processInfo.systemUptime
            let gravityX = sweep?.gravityX(elapsed: now - origin) ?? 0
            let sample = JarMotionSample(
                gravityX: gravityX,
                gravityY: -(1 - gravityX * gravityX).squareRoot(),
                timestamp: now
            )
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
