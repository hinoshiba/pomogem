import Foundation
import OSLog

/// device-02 / launch-02. Counts the private-database operations the launch
/// path starts, so time-to-Home can be explained by round trips on a real
/// device (Instruments' os_signpost track or the unified log).
///
/// A plain process-wide counter: no record, zone, account or payload data is
/// kept, only how many operations of each kind were added to a database.
/// The count is diagnostic and gates nothing.
enum CloudKitRoundTripLedger {
    enum Kind: String, CaseIterable, Sendable {
        /// `fetchAllRecordZones` probe inside an account proof.
        case accountProbe
        /// The storage-transfer control record (also the probe of its proof).
        case controlFetch
        /// Reset-marker history: the zone list and each zone-changes page set.
        case historyZoneList, historyZoneChanges
    }

    struct Snapshot: Equatable, Sendable {
        var counts: [Kind: Int] = [:]

        var total: Int { counts.values.reduce(0, +) }

        static func - (lhs: Self, rhs: Self) -> Self {
            var result = Self()
            for kind in Kind.allCases {
                result.counts[kind] = (lhs.counts[kind] ?? 0) - (rhs.counts[kind] ?? 0)
            }
            return result
        }

        /// e.g. `accountProbe=1 controlFetch=6 historyZoneList=2 historyZoneChanges=2`
        var summary: String {
            Kind.allCases.map { "\($0.rawValue)=\(counts[$0] ?? 0)" }.joined(separator: " ")
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current = Snapshot()

    static func record(_ kind: Kind) {
        lock.lock()
        current.counts[kind, default: 0] += 1
        lock.unlock()
    }

    static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

/// One cloud launch attempt, from the start of its deadline to the moment its
/// session is published (or the attempt ends). Emits an os_signpost interval
/// named `CloudLaunch` with an event per stage, and one public log line with
/// the elapsed time and the round-trip counts. Values are lifecycle numbers
/// only — never account identifiers, namespaces or store paths.
@MainActor
final class CloudLaunchMeasurement {
    enum Outcome: String {
        case published, failed, cancelled
    }

    nonisolated static let signposter = OSSignposter(subsystem: "com.hinoshiba.pomogem", category: "CloudLaunch")
    private static let logger = Logger(subsystem: "com.hinoshiba.pomogem", category: "PersistenceLaunch")

    let attempt: Int
    private let started = ContinuousClock.now
    private let startCounts = CloudKitRoundTripLedger.snapshot()
    private var interval: OSSignpostIntervalState?

    init(attempt: Int, existingStore: Bool) {
        self.attempt = attempt
        interval = Self.signposter.beginInterval("CloudLaunch", id: Self.signposter.makeSignpostID(),
            "attempt=\(attempt) existingStore=\(existingStore)")
    }

    func stage(_ name: StaticString) {
        guard interval != nil else { return }
        Self.signposter.emitEvent(name)
    }

    var elapsedMilliseconds: Int {
        let elapsed = ContinuousClock.now - started
        return Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    var roundTrips: CloudKitRoundTripLedger.Snapshot {
        CloudKitRoundTripLedger.snapshot() - startCounts
    }

    func finish(_ outcome: Outcome) {
        guard let interval else { return }
        self.interval = nil
        let trips = roundTrips
        Self.signposter.endInterval("CloudLaunch", interval,
            "outcome=\(outcome.rawValue) roundTrips=\(trips.total)")
        Self.logger.info(
            "Cloud session \(outcome.rawValue, privacy: .public) attempt=\(self.attempt, privacy: .public) elapsed=\(self.elapsedMilliseconds, privacy: .public)ms roundTrips=\(trips.total, privacy: .public) \(trips.summary, privacy: .public)"
        )
    }
}

/// The process's own start time, from the kernel. Used only to log how long
/// after launch the first session was published.
enum ProcessLaunchClock {
    static func millisecondsSinceProcessStart() -> Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let started = TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
        let elapsed = Date().timeIntervalSince1970 - started
        guard elapsed.isFinite, elapsed >= 0 else { return nil }
        return Int(elapsed * 1_000)
    }
}
