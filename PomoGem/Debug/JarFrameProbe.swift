#if DEBUG && targetEnvironment(simulator)
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
/// and the main-thread time of the awake frames (`medMs`, `p95Ms`: from
/// the scene's update until the frame has been encoded, i.e. update +
/// physics + render submission), then the gem atlas: generation, packed
/// names, kept image MB, page pixels and stand-alone textures.
///
/// `POMOGEM_UI_TEST_TILT_SWEEP=<start>-<end>[:<amplitude>]` (seconds after
/// the jar appears) feeds a Core Motion-like tilt at 30 Hz through the
/// scene's normal gravity input, so idle tilt rendering can be observed
/// without a device: by default a hand-held rock of ±0.42 of full tilt over
/// four seconds; an amplitude below 0.05 is a fast tremor instead (a phone
/// held still).
@MainActor
final class JarFrameProbe {
    static let shared: JarFrameProbe? = {
        let environment = ProcessInfo.processInfo.environment
        guard LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess,
              environment["POMOGEM_UI_TEST_SPRITE_STATS"] == "1"
        else { return nil }
        return JarFrameProbe()
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
    private var updates = 0
    private var lastTiltSteps = 0
    private var frameStart: CFTimeInterval?
    private var workMilliseconds: [Double] = []
    private weak var scene: JarScene?
    private var timer: Timer?
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("jar-frames.log")

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

    /// Called at the end of the scene's update; the async block runs after
    /// SpriteKit has finished this frame's run-loop turn (render included).
    func sceneFinishedUpdate() {
        guard let start = frameStart else { return }
        frameStart = nil
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                JarFrameProbe.shared?.workMilliseconds.append((CACurrentMediaTime() - start) * 1_000)
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

    private func flush() {
        let now = CACurrentMediaTime()
        let atlas = GemTextureAtlas.shared.statistics
        let sorted = workMilliseconds.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
        }
        let line = String(
            format: "t=%.0f frames=%d tilt=%d idle=%d medMs=%.2f p95Ms=%.2f atlas=g%d/%d names/%.1fMB kept/%.0fx%.0f page/%d loose\n",
            now - launch,
            updates,
            (scene?.idleTiltFrameCount ?? 0) - lastTiltSteps,
            (scene?.isIdlePaused ?? false) ? 1 : 0,
            percentile(0.5),
            percentile(0.95),
            atlas.generation,
            atlas.packedNames,
            Double(atlas.keptImageBytes) / 1_048_576,
            atlas.pageSize.width,
            atlas.pageSize.height,
            atlas.standaloneTextures
        )
        lastTiltSteps = scene?.idleTiltFrameCount ?? 0
        updates = 0
        workMilliseconds.removeAll(keepingCapacity: true)
        append(line)
    }

    private func startTiltSweepIfRequested(for scene: JarScene) {
        guard let value = ProcessInfo.processInfo.environment["POMOGEM_UI_TEST_TILT_SWEEP"] else { return }
        let parts = value.split(separator: ":")
        let range = parts[0].split(separator: "-").compactMap { Double($0) }
        guard range.count == 2 else { return }
        let amplitude = parts.count > 1 ? Double(parts[1]) ?? 0.42 : 0.42
        let period: Double = amplitude < 0.05 ? 0.35 : 4
        let start = CACurrentMediaTime() + range[0]
        let end = CACurrentMediaTime() + range[1]
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak scene] timer in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                guard let scene, now < end else {
                    scene?.resetGravity()
                    timer.invalidate()
                    return
                }
                guard now >= start else { return }
                let phase = (now - start) / period * 2 * .pi
                let wobble = amplitude < 0.05 ? (sin(phase) + sin(phase * 2.7)) / 2 : sin(phase)
                scene.setGravityVector(CGVector(
                    dx: CGFloat(wobble * amplitude) * Constants.Jar.tiltGravityHorizontalScale,
                    dy: Constants.Jar.gravity
                ))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
#endif
