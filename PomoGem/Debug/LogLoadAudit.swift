#if DEBUG
import Foundation
import Observation
import SwiftUI

/// 記録's loads, timed inside the app for the 40-year UI test.
///
/// XCUI's own intervals include element lookup, synthesized taps and its
/// wait for the app to go idle, which alone take seconds on a 350,640-row
/// store, so they cannot tell a frozen screen from a slow test. The test
/// reads these instead:
/// - `milliseconds`: from the tap that opened 記録 (or picked 今週／今月)
///   until every load that tap started has arrived;
/// - `longestStallMilliseconds`: the longest time the main thread went
///   without turning its run loop in between. That is how long the screen
///   could not scroll, animate or answer a tap.
///
/// Only UI-test launches record anything; Release builds do not contain it.
@MainActor
@Observable
final class LogLoadAudit {
    typealias Part = LogHistoryLoadPolicy.Part

    enum Trigger: String {
        /// Opening 記録 starts every load.
        case open
        /// Picking 今週 or 今月 reloads the period page only.
        case period

        var expectedParts: Set<Part> {
            switch self {
            case .open: Set(Part.allCases)
            case .period: [.period]
            }
        }
    }

    /// `generation=…;trigger=…;state=loading` until every expected part has
    /// arrived, then the timings.
    private(set) var value = "generation=0;state=idle"

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var trigger: Trigger?
    @ObservationIgnored private var startedAt: TimeInterval = 0
    @ObservationIgnored private var partMilliseconds: [Part: Int] = [:]
    @ObservationIgnored private var monitor: MainThreadStallMonitor?

    func begin(_ trigger: Trigger) {
        guard LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess else { return }
        monitor?.stop()
        generation += 1
        self.trigger = trigger
        startedAt = ProcessInfo.processInfo.systemUptime
        partMilliseconds = [:]
        let monitor = MainThreadStallMonitor()
        monitor.start()
        self.monitor = monitor
        value = "generation=\(generation);trigger=\(trigger.rawValue);state=loading"
    }

    func complete(_ part: Part) {
        guard let trigger, let monitor,
              trigger.expectedParts.contains(part),
              partMilliseconds[part] == nil
        else { return }
        partMilliseconds[part] = milliseconds(since: startedAt)
        guard Set(partMilliseconds.keys) == trigger.expectedParts else { return }
        let longestStall = monitor.stop()
        self.monitor = nil
        self.trigger = nil
        var fields = [
            "generation=\(generation)",
            "trigger=\(trigger.rawValue)",
            "state=done",
            "milliseconds=\(partMilliseconds.values.max() ?? 0)",
            "longestStallMilliseconds=\(Int((longestStall * 1_000).rounded()))"
        ]
        for part in Part.allCases {
            if let value = partMilliseconds[part] {
                fields.append("\(part.rawValue)Milliseconds=\(value)")
            }
        }
        value = fields.joined(separator: ";")
    }

    private func milliseconds(since start: TimeInterval) -> Int {
        Int((max(0, ProcessInfo.processInfo.systemUptime - start) * 1_000).rounded())
    }
}

/// The 1-point accessibility element the UI test reads. A view of its own,
/// so a new audit value redraws only this, never 記録 itself.
struct LogLoadAuditProbe: View {
    let audit: LogLoadAudit

    var body: some View {
        Text(verbatim: "Log load audit probe")
            .font(.system(size: 1))
            .foregroundStyle(Color.clear)
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("log.load-audit.probe")
            .accessibilityLabel(Text(verbatim: "Log load audit probe"))
            .accessibilityValue(Text(verbatim: audit.value))
            .allowsHitTesting(false)
    }
}

/// The longest gap between two turns of the main run loop while it runs. A
/// 5 ms timer in the common modes fires on every turn it can; when the main
/// thread is busy (a synchronous fetch, a long layout) the next fire comes
/// late by exactly that long.
@MainActor
final class MainThreadStallMonitor {
    private var timer: Timer?
    private var lastTick: TimeInterval = 0
    private var longestGap: TimeInterval = 0
    private var startedAt: TimeInterval = 0

    /// Stops by itself after this long, so a load that never finishes does
    /// not leave a timer running.
    private static let maximumDuration: TimeInterval = 120

    func start() {
        let now = ProcessInfo.processInfo.systemUptime
        startedAt = now
        lastTick = now
        longestGap = 0
        let timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Returns the longest gap, counting the one that ends now.
    @discardableResult
    func stop() -> TimeInterval {
        if timer != nil { tick() }
        timer?.invalidate()
        timer = nil
        return longestGap
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        longestGap = max(longestGap, now - lastTick)
        lastTick = now
        if now - startedAt > Self.maximumDuration {
            timer?.invalidate()
            timer = nil
        }
    }
}
#endif
