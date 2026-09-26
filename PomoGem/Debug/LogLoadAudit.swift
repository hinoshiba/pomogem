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
/// - `milliseconds`: from the tap that opened 記録 (or picked 今週／今月,
///   or the return from the background) until every load it started has
///   arrived;
/// - `openingStallMilliseconds`: how long the main thread went without
///   turning its run loop before the first load started. On opening that
///   is the push to 記録 and its first frame, which no read of history
///   takes part in;
/// - `longestStallMilliseconds`: the longest the main thread went without
///   turning its run loop from the first load's start until every load had
///   arrived. That is how long the screen could not scroll, animate or
///   answer a tap while history was being read.
///
/// The test must not query the app while an audit runs (see
/// `finishedNotificationName`).
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
        /// Coming back from the background with 記録 on screen reloads
        /// every part.
        case resume

        var expectedParts: Set<Part> {
            switch self {
            case .open, .resume: Set(Part.allCases)
            case .period: [.period]
            }
        }
    }

    /// Posted (a Darwin notification) when an audit has its timings. The UI
    /// test waits for it instead of polling the probe: every XCUI query
    /// snapshots the app's accessibility tree on the app's main thread, which
    /// takes hundreds of milliseconds over 記録 and would itself read as a
    /// stall.
    static let finishedNotificationName = "com.hinoshiba.pomogem.log-load-audit.finished"

    /// `generation=…;trigger=…;state=loading` until every expected part has
    /// arrived, then the timings.
    private(set) var value = "generation=0;state=idle"

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var trigger: Trigger?
    @ObservationIgnored private var startedAt: TimeInterval = 0
    @ObservationIgnored private var partMilliseconds: [Part: Int] = [:]
    @ObservationIgnored private var openingStall: TimeInterval?
    @ObservationIgnored private var milestoneReadMilliseconds: Int?
    @ObservationIgnored private var monitor: MainThreadStallMonitor?
    @ObservationIgnored private var wasHidden = false

    func begin(_ trigger: Trigger) {
        guard LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess else { return }
        monitor?.stop()
        generation += 1
        self.trigger = trigger
        startedAt = ProcessInfo.processInfo.systemUptime
        partMilliseconds = [:]
        openingStall = nil
        milestoneReadMilliseconds = nil
        let monitor = MainThreadStallMonitor()
        monitor.start()
        self.monitor = monitor
        value = "generation=\(generation);trigger=\(trigger.rawValue);state=loading"
    }

    /// 記録 went to the background.
    func noteHidden() {
        wasHidden = true
    }

    /// Called by the first load after 記録 is visible again, before it reads
    /// anything, so the audit covers the whole reload.
    func beginResumeIfReturning() {
        guard wasHidden else { return }
        wasHidden = false
        begin(.resume)
    }

    /// Called as each load starts, before it reads anything. The first call
    /// closes the opening (see `openingStallMilliseconds`); stalls are
    /// measured afresh from here.
    func loadStarting() {
        guard trigger != nil, openingStall == nil, let monitor else { return }
        openingStall = monitor.restart()
    }

    /// 記録's one read on the main context (the milestones), timed while an
    /// audit runs. It must stay short: the main thread waits for it.
    func noteMilestoneRead(seconds: TimeInterval) {
        guard trigger != nil else { return }
        let milliseconds = Int((max(0, seconds) * 1_000).rounded())
        milestoneReadMilliseconds = max(milestoneReadMilliseconds ?? 0, milliseconds)
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
            "openingStallMilliseconds=\(Self.milliseconds(openingStall ?? 0))",
            "longestStallMilliseconds=\(Self.milliseconds(longestStall))",
            "longestStallStartedAtMilliseconds=\(Self.milliseconds(monitor.longestGapStartedAfter))"
        ]
        for part in Part.allCases {
            if let value = partMilliseconds[part] {
                fields.append("\(part.rawValue)Milliseconds=\(value)")
            }
        }
        if let milestoneReadMilliseconds {
            fields.append("milestonesMilliseconds=\(milestoneReadMilliseconds)")
        }
        value = fields.joined(separator: ";")
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.finishedNotificationName as CFString),
            nil,
            nil,
            true
        )
    }

    private func milliseconds(since start: TimeInterval) -> Int {
        Self.milliseconds(ProcessInfo.processInfo.systemUptime - start)
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int {
        Int((max(0, interval) * 1_000).rounded())
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
    /// When the longest gap began, from `start()`.
    private(set) var longestGapStartedAfter: TimeInterval = 0
    private var startedAt: TimeInterval = 0

    /// Stops by itself after this long, so a load that never finishes does
    /// not leave a timer running.
    private static let maximumDuration: TimeInterval = 120

    func start() {
        let now = ProcessInfo.processInfo.systemUptime
        startedAt = now
        lastTick = now
        longestGap = 0
        longestGapStartedAfter = 0
        let timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Returns the longest gap so far, counting the one still running, and
    /// measures afresh from now.
    func restart() -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        let longest = max(longestGap, now - lastTick)
        lastTick = now
        longestGap = 0
        longestGapStartedAfter = 0
        return longest
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
        if now - lastTick > longestGap {
            longestGap = now - lastTick
            longestGapStartedAfter = lastTick - startedAt
        }
        lastTick = now
        if now - startedAt > Self.maximumDuration {
            timer?.invalidate()
            timer = nil
        }
    }
}
#endif
