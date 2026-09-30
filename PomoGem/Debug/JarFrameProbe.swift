#if DEBUG && targetEnvironment(simulator)
import Darwin
import Foundation
import QuartzCore
import SpriteKit

/// Debug-only frame counters for jar performance reviews in the Simulator.
/// Active only with the in-memory UI-test launch and
/// `POMOGEM_UI_TEST_SPRITE_STATS=1` (the same switch as SpriteKit's own
/// FPS/node/draw overlay). Once a second it appends one line to
/// `tmp/jar-frames.log` in the app container:
///
/// `t` seconds since launch, `frames` awake frames (scene updates; a
/// paused, unchanged jar draws none), `tilt` frames a paused jar drew for
/// tilt (light changes while idle), `idle` whether the physics is idle-paused,
/// `loop` whether the render loop is stopped (jar-01: the SKView's own
/// `isPaused`), `motion` the device-motion rate (stopped, full, idle; §7.13),
/// and the main-thread time of the awake frames (`medMs`, `p95Ms`: from
/// the scene's update until the frame has been encoded, i.e. update +
/// physics + render submission), then the gem atlas: generation, packed
/// names, kept image MB, page pixels and stand-alone textures.
///
/// `POMOGEM_UI_TEST_SETTLE_PROBE=<n>` (also enough on its own to start the
/// probe) reviews the headroom under the mouth (D4, Docs/GemExperienceDesign.md
/// §7.5): each time the jar idles it appends `settle i=… headroom=…
/// scale=… bodies=… interior=…`, then shakes it (full strength,
/// alternating sides) and waits for the next settle, `n` times after the
/// first; the last line is `settle-min headroom=…`. A settle that takes
/// longer than 20 s is logged as `timeout` and counted as is.
///
/// `POMOGEM_UI_TEST_TILT_SWEEP=<start>-<end>[:<amplitude>]` (seconds after
/// the jar appears) feeds a Core Motion-like tilt at 30 Hz through the
/// scene's normal gravity input, so idle tilt rendering can be observed
/// without a device: by default a hand-held rock of ±0.42 of full tilt over
/// four seconds; an amplitude below 0.05 is a fast tremor instead (a phone
/// held still). With `POMOGEM_UI_TEST_MOTION=synthetic` the same tilt is
/// played through `SyntheticJarMotionSource` instead, i.e. through the jar's
/// motion observer and its rates.
///
/// F3: `POMOGEM_UI_TEST_GRAVITY=<pose>[,<pose>@<seconds>…]`
/// (`JarGravitySchedule`: portrait, landscape-left, landscape-right,
/// upside-down, flat, face-down) holds the phone in fixed poses. Without
/// the synthetic source the probe feeds the scene's gravity reading at
/// 30 Hz (`JarScene.setGravityReading`, so a turn re-settles a resting
/// pile); each line then also shows the applied gravity (`g=dx,dy`) and
/// whether the pile rests on the floor (`floor=1`; the settle probe's
/// headroom means the space under the mouth only then).
@MainActor
final class JarFrameProbe {
    static let shared: JarFrameProbe? = {
        let environment = ProcessInfo.processInfo.environment
        guard LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess,
              environment["POMOGEM_UI_TEST_SPRITE_STATS"] == "1" || settleProbeCount != nil
        else { return nil }
        return JarFrameProbe()
    }()

    /// `POMOGEM_UI_TEST_SETTLE_PROBE=<n>`: shaken settles after the first.
    static let settleProbeCount: Int? = {
        guard let value = ProcessInfo.processInfo.environment["POMOGEM_UI_TEST_SETTLE_PROBE"],
              let count = Int(value), count >= 0
        else { return nil }
        return count
    }()

    /// `POMOGEM_UI_TEST_IDLE_TILT_GATE=0`: an idle jar follows every tilt
    /// sample again (the behaviour before the gate), for A/B measurements.
    static let disablesIdleTiltGate: Bool = shared != nil
        && ProcessInfo.processInfo.environment["POMOGEM_UI_TEST_IDLE_TILT_GATE"] == "0"

    /// `POMOGEM_UI_TEST_PREBAKE=0`: no launch pre-bake and no parallel
    /// bake of a restore's misses (every body bakes serially on first use,
    /// the behaviour before), for A/B measurements.
    static let disablesPrebake: Bool = shared != nil
        && ProcessInfo.processInfo.environment["POMOGEM_UI_TEST_PREBAKE"] == "0"

    private let launch = CACurrentMediaTime()
    /// Reported by the jar's motion observer.
    var motionRate: JarMotionRate = .stopped
    private var updates = 0
    private var lastTiltSteps = 0
    private var frameStart: CFTimeInterval?
    private var workMilliseconds: [Double] = []
    private weak var scene: JarScene?
    private var timer: Timer?
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("jar-frames.log")
    private var settleIndex = 0
    private var settleMinimum = CGFloat.greatestFiniteMagnitude
    private var settleWaitStarted: CFTimeInterval?
    private var settleFinished = false
    /// Settles so far whose pile did not rest on the floor.
    private var settlesOffTheFloor = 0
    /// F3 (review nit, 2026-09-29): the settle probe's state for a UI test
    /// (`GemShowcaseFixtureLaunchView` shows it as `jar.settle-probe`):
    /// `settle-min headroom=… settles=… offFloor=…` once finished, the
    /// running minimum before.
    private(set) var settleProbeSummary = "settle running"
    /// The pose `POMOGEM_UI_TEST_GRAVITY` holds now (logged when it changes).
    private var lastGravityPose: JarGravityPose?

    private init() {
        try? FileManager.default.removeItem(at: url)
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                JarFrameProbe.shared?.flush()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func attach(_ scene: JarScene) {
        guard self.scene !== scene else { return }
        self.scene = scene
        startTiltSweepIfRequested(for: scene)
    }

    func sceneUpdated() {
        updates += 1
        frameStart = CACurrentMediaTime()
    }

    // MARK: Home start to the first jar frame (launch-perf, 2026-09-29)

    /// Where Home began (the first `HomeView` or `JarScene` init, whichever
    /// comes first): wall time and the main thread's CPU time.
    private var homeStart: (wall: CFTimeInterval, cpu: Double)?
    private var loggedFirstFrame = false
    private var loggedGlassReady = false

    /// Idempotent: only the first call marks Home's start.
    func markHomeStart() {
        guard homeStart == nil else { return }
        homeStart = (CACurrentMediaTime(), Self.currentThreadCPUMilliseconds())
        note("home-start")
    }

    /// `first-jar-frame` once, after the first frame the jar rendered:
    /// wall time and main-thread CPU time since Home's start.
    private func noteFirstFrameIfNeeded() {
        guard !loggedFirstFrame, let start = homeStart else { return }
        loggedFirstFrame = true
        note(String(
            format: "first-jar-frame wallMs=%.1f mainCpuMs=%.1f",
            (CACurrentMediaTime() - start.wall) * 1_000,
            Self.currentThreadCPUMilliseconds() - start.cpu
        ))
    }

    /// `glass-ready` once, when the jar first shows its final glass.
    func noteGlassReady() {
        guard !loggedGlassReady, let start = homeStart else { return }
        loggedGlassReady = true
        note(String(
            format: "glass-ready wallMs=%.1f mainCpuMs=%.1f",
            (CACurrentMediaTime() - start.wall) * 1_000,
            Self.currentThreadCPUMilliseconds() - start.cpu
        ))
    }

    /// CPU time (user + system) of the calling thread, in milliseconds.
    nonisolated static func currentThreadCPUMilliseconds() -> Double {
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let seconds = Double(info.user_time.seconds + info.system_time.seconds)
        let micros = Double(info.user_time.microseconds + info.system_time.microseconds)
        return seconds * 1_000 + micros / 1_000
    }

    /// Called at the end of the scene's update; the async block runs after
    /// SpriteKit has finished this frame's run-loop turn (render included).
    func sceneFinishedUpdate() {
        guard let start = frameStart else { return }
        frameStart = nil
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                JarFrameProbe.shared?.workMilliseconds.append((CACurrentMediaTime() - start) * 1_000)
                JarFrameProbe.shared?.noteFirstFrameIfNeeded()
            }
        }
    }

    /// Appends one event line (e.g. a restore's duration) at once.
    func note(_ text: String) {
        append(String(format: "t=%.1f %@\n", CACurrentMediaTime() - launch, text))
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// One step of the settle probe (called once a second).
    private func advanceSettleProbe(now: CFTimeInterval) {
        guard let total = Self.settleProbeCount, !settleFinished, let scene else { return }
        let started = settleWaitStarted ?? now
        if settleWaitStarted == nil { settleWaitStarted = now }
        let timedOut = now - started > 20
        guard scene.isIdlePaused || timedOut else { return }
        let headroom = scene.pileHeadroomFraction
        settleMinimum = min(settleMinimum, headroom)
        if !scene.pileRestsOnTheFloor { settlesOffTheFloor += 1 }
        let interior = JarScene.interiorRect(sceneSize: scene.size)
        append(String(
            format: "settle i=%d headroom=%.3f scale=%.3f bodies=%d interior=%.0fx%.0f floor=%d%@\n",
            settleIndex,
            headroom,
            scene.jarScale,
            scene.physicalPebbleCount,
            interior.width,
            interior.height,
            scene.pileRestsOnTheFloor ? 1 : 0,
            timedOut ? " timeout" : ""
        ))
        guard settleIndex < total else {
            settleFinished = true
            append(String(format: "settle-min headroom=%.3f settles=%d\n", settleMinimum, settleIndex + 1))
            settleProbeSummary = String(
                format: "settle-min headroom=%.3f settles=%d offFloor=%d",
                settleMinimum,
                settleIndex + 1,
                settlesOffTheFloor
            )
            return
        }
        settleProbeSummary = String(format: "settle running i=%d min=%.3f", settleIndex, settleMinimum)
        settleIndex += 1
        settleWaitStarted = now + 1
        _ = scene.shakePebbles(strength: 1, horizontal: settleIndex.isMultiple(of: 2) ? 1 : -1)
    }

    private func flush() {
        let now = CACurrentMediaTime()
        advanceSettleProbe(now: now)
        let atlas = GemTextureAtlas.shared.statistics
        let sorted = workMilliseconds.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
        }
        let motion = switch motionRate {
        case .stopped: "stopped"
        case .full: "full"
        case .idle: "idle"
        }
        let gravity = scene?.appliedGravityVector ?? Constants.Jar.gravityVector
        let line = String(
            format: "t=%.0f frames=%d tilt=%d idle=%d loop=%@ motion=%@ g=%.1f,%.1f floor=%d medMs=%.2f p95Ms=%.2f atlas=g%d/%d names/%.1fMB kept/%.0fx%.0f page/%d loose/%.1fMB resident/%d live\n",
            now - launch,
            updates,
            (scene?.idleTiltFrameCount ?? 0) - lastTiltSteps,
            (scene?.isIdlePaused ?? false) ? 1 : 0,
            (scene?.view?.isPaused ?? false) ? "paused" : "running",
            motion,
            gravity.dx,
            gravity.dy,
            (scene?.pileRestsOnTheFloor ?? true) ? 1 : 0,
            percentile(0.5),
            percentile(0.95),
            atlas.generation,
            atlas.packedNames,
            Double(atlas.keptImageBytes) / 1_048_576,
            atlas.pageSize.width,
            atlas.pageSize.height,
            atlas.standaloneTextures,
            Double(atlas.residentBytes) / 1_048_576,
            atlas.liveNames
        )
        lastTiltSteps = scene?.idleTiltFrameCount ?? 0
        updates = 0
        workMilliseconds.removeAll(keepingCapacity: true)
        append(line)
    }

    private func startTiltSweepIfRequested(for scene: JarScene) {
        // The synthetic motion source plays the sweep through the observer.
        guard SyntheticJarMotionSource.isRequested == false else { return }
        if let poses = JarGravitySchedule.forCurrentProcess {
            startGravityPoses(poses, for: scene)
            return
        }
        guard let sweep = JarTiltSweep.forCurrentProcess else { return }
        let appeared = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak scene] timer in
            MainActor.assumeIsolated {
                let elapsed = CACurrentMediaTime() - appeared
                guard let scene, elapsed < sweep.end else {
                    scene?.resetGravity()
                    timer.invalidate()
                    return
                }
                guard let gravityX = sweep.gravityX(elapsed: elapsed) else { return }
                // A direct gravity: the light-only idle tilt measurement.
                scene.setGravityVector(CGVector(
                    dx: CGFloat(gravityX) * JarGravityMapping.strength,
                    dy: Constants.Jar.gravity
                ))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// F3: holds the phone in `poses` by feeding the scene's gravity
    /// reading at 30 Hz, as the motion observer would at its full rate.
    private func startGravityPoses(_ poses: JarGravitySchedule, for scene: JarScene) {
        let appeared = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak scene] timer in
            MainActor.assumeIsolated {
                guard let scene else {
                    timer.invalidate()
                    return
                }
                let pose = poses.pose(elapsed: CACurrentMediaTime() - appeared)
                if let probe = JarFrameProbe.shared, probe.lastGravityPose != pose {
                    probe.lastGravityPose = pose
                    probe.note("pose \(pose.rawValue)")
                }
                let gravity = pose.gravity
                guard let reading = JarGravityMapping.Reading(
                    deviceGravityX: gravity.x,
                    deviceGravityY: gravity.y,
                    deviceGravityZ: gravity.z
                ) else { return }
                scene.setGravityReading(reading)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// `POMOGEM_UI_TEST_TILT_SWEEP=<start>-<end>[:<amplitude>]`: a scripted
/// sideways tilt (in g) between `start` and `end` seconds after the jar
/// appears. By default a hand-held rock of ±0.42 over four seconds; an
/// amplitude below 0.05 is a fast tremor (a phone held still).
struct JarTiltSweep: Sendable {
    let start: Double
    let end: Double
    let amplitude: Double

    static let forCurrentProcess: JarTiltSweep? = {
        guard let value = ProcessInfo.processInfo.environment["POMOGEM_UI_TEST_TILT_SWEEP"] else { return nil }
        let parts = value.split(separator: ":")
        let range = parts[0].split(separator: "-").compactMap { Double($0) }
        guard range.count == 2 else { return nil }
        let amplitude = parts.count > 1 ? Double(parts[1]) ?? 0.42 : 0.42
        return JarTiltSweep(start: range[0], end: range[1], amplitude: amplitude)
    }()

    /// The sideways gravity at `elapsed` seconds, or nil outside the sweep.
    func gravityX(elapsed: Double) -> Double? {
        guard elapsed >= start, elapsed < end else { return nil }
        let period: Double = amplitude < 0.05 ? 0.35 : 4
        let phase = (elapsed - start) / period * 2 * .pi
        let wobble = amplitude < 0.05 ? (sin(phase) + sin(phase * 2.7)) / 2 : sin(phase)
        return wobble * amplitude
    }
}
#endif
