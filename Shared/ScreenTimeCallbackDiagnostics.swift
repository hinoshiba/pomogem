import Foundation

/// Which of our registrations a DeviceActivity callback names. The shape of the
/// name is all that is inspected; this is a label for evidence, never an
/// authorization to award anything — `ScreenTimeState.record` still owns that.
enum ScreenTimeActivityKind: String {
    case scheduler, lane, other

    init(activityName: String) {
        guard activityName.hasPrefix(ScreenTimePolicy.activityPrefix) else {
            self = .other
            return
        }
        let remainder = activityName.dropFirst(ScreenTimePolicy.activityPrefix.count)
        if remainder.hasPrefix(ScreenTimePolicy.schedulerInfix) {
            self = .scheduler
            return
        }
        let parts = remainder.split(separator: ".")
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
              let batch = Int(parts[1]), (0..<ScreenTimePolicy.batchesPerLane).contains(batch)
        else {
            self = .other
            return
        }
        self = .lane
    }
}

/// Seconds for a diagnostics line, and the one place that turns a `Date`
/// difference into an `Int`.
///
/// `Int.init(_: Double)` TRAPS on NaN and on anything outside Int64, while
/// `ScreenTimeState.isValid` only requires a stored date to be finite —
/// `Double.greatestFiniteMagnitude` passes it. A ledger that a device audit
/// copied, hand-edited or wrote partially can therefore hold a finite but
/// absurd date, and a diagnostics-only log line must never be the thing that
/// crashes the app on every launch and the extension on every callback.
enum ScreenTimeDiagnosticSeconds {
    /// `Int.min` / `Int.max` mean "the stored date is not a real instant"; they
    /// are deliberately unmistakable next to an ordinary offset.
    static func clamped(_ seconds: Double) -> Int {
        let rounded = seconds.rounded()
        if let exact = Int(exactly: rounded) { return exact }
        // NaN compares false against everything, so it reads as `Int.max`.
        return rounded < 0 ? Int.min : Int.max
    }

    static func between(_ later: Date, _ earlier: Date) -> Int {
        clamped(later.timeIntervalSince(earlier))
    }
}

/// How many callbacks the OS delivered to the monitor extension, and what each
/// one did. Counts and reasons only: no run or event identifier, no threshold,
/// no gem count, no theme and no opaque token ever enters this — the same rule
/// `ScreenTimeLog` already states for the device Console evidence.
///
/// It exists because the Console evidence is not always reachable. On the audit
/// Mac, `devicectl device sysdiagnose` and `log collect --device-udid` both
/// require host root and `log stream` has no device option at all, so a device
/// run can end with no record whatsoever of whether DeviceActivity delivered
/// anything. These counts live in the App Group ledger instead, survive the
/// short-lived extension process, and are re-emitted to `os_log` by the app on
/// every synchronize pass — so one live Console session, or one glance at the
/// ledger, reads the whole history after the fact.
///
/// A count means nothing without the thing it was counted under, so the set is
/// stamped with the ledger `epoch` and the device day and RESTARTS whenever
/// either changes (`generation` then increments). Without that, "laneStart=1"
/// could mean a lane interval that started today or one that started three
/// weeks ago, and an in-app reset would silently return every counter to zero —
/// which reads exactly like "the extension has never run". `generation > 0`
/// says the counts describe a later window than the ledger's whole lifetime.
///
/// Two callbacks cannot be counted, by construction: one whose ledger is
/// unreadable (nothing can be written then either) and one that arrives before
/// the app has ever bound a ledger (counting must not be what creates one).
struct ScreenTimeCallbackCounters: Codable, Equatable {
    enum IntervalPhase: String {
        case start, end
    }

    enum ThresholdOutcome: String {
        /// The ledger advanced and a gem is owed.
        case recorded
        /// Every fence in `ScreenTimeState.record` is a possible reason: an
        /// already-awarded threshold, a retired run, a paused learning lane.
        case ignoredByLedger
        /// The activity or event name is not one of ours.
        case ignoredByName
        /// Family Controls says the user revoked access. The ONLY authorization
        /// outcome, because it is the only authorization answer: a status that
        /// is neither approved nor denied is not a decision and no longer
        /// decides anything — it is counted apart, as
        /// `statusUnknownAtCallback`, beside whatever the ledger then did.
        case denied
    }

    /// How many times this set has been restarted — by a day rollover, by a new
    /// ledger epoch, or by the in-app reset. Monotonic, and the only way to
    /// tell "nothing has ever been delivered" from "the window was reset".
    var generation = 0
    /// The ledger epoch these counts were accumulated under. `nil` on a set
    /// written before this field existed; the next callback adopts the current
    /// one rather than discarding evidence the device already holds.
    var epoch: UUID?
    /// The device day these counts were accumulated under, same rule as `epoch`.
    var dayStart: Date?

    var schedulerIntervalStarts = 0
    var laneIntervalStarts = 0
    var otherIntervalStarts = 0
    var schedulerIntervalEnds = 0
    var laneIntervalEnds = 0
    var otherIntervalEnds = 0
    var thresholds = 0
    var thresholdsRecorded = 0
    var thresholdsIgnoredByLedger = 0
    var thresholdsIgnoredByName = 0
    var thresholdsDenied = 0
    /// How many threshold callbacks arrived in a process that could not read
    /// its own Family Controls authorization — the status was neither approved
    /// nor denied. An OBSERVATION, not an outcome: the callback went on to be
    /// recorded or refused by the ledger like any other, and is counted there
    /// too. On the 2026-09-21 device run this was true of every threshold
    /// while the app itself read 許可済み, which is why it is worth a number of
    /// its own — and why it is no longer allowed to be a verdict.
    var statusUnknownAtCallback = 0
    /// Any callback. The three below are per kind, because one shared instant
    /// cannot say whether it was a scheduler interval (which fires at 00:00
    /// whatever else happens) or the lane interval the audit is looking for.
    var lastCallbackAt: Date?
    var lastLaneIntervalStartAt: Date?
    var lastSchedulerIntervalStartAt: Date?
    var lastThresholdAt: Date?

    init() {}

    /// Decoded field by field so that a ledger written by an earlier build —
    /// the phone already holds one — keeps decoding as new fields are added.
    /// The synthesized decoder does not fall back to a property's default, and
    /// a `keyNotFound` here surfaces as `ScreenTimeError.corruptedState`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) throws -> Int {
            try container.decodeIfPresent(Int.self, forKey: key) ?? 0
        }
        func date(_ key: CodingKeys) throws -> Date? {
            try container.decodeIfPresent(Date.self, forKey: key)
        }
        generation = try count(.generation)
        epoch = try container.decodeIfPresent(UUID.self, forKey: .epoch)
        dayStart = try date(.dayStart)
        schedulerIntervalStarts = try count(.schedulerIntervalStarts)
        laneIntervalStarts = try count(.laneIntervalStarts)
        otherIntervalStarts = try count(.otherIntervalStarts)
        schedulerIntervalEnds = try count(.schedulerIntervalEnds)
        laneIntervalEnds = try count(.laneIntervalEnds)
        otherIntervalEnds = try count(.otherIntervalEnds)
        thresholds = try count(.thresholds)
        thresholdsRecorded = try count(.thresholdsRecorded)
        thresholdsIgnoredByLedger = try count(.thresholdsIgnoredByLedger)
        thresholdsIgnoredByName = try count(.thresholdsIgnoredByName)
        thresholdsDenied = try count(.thresholdsDenied)
        statusUnknownAtCallback = try count(.statusUnknownAtCallback)
        lastCallbackAt = try date(.lastCallbackAt)
        lastLaneIntervalStartAt = try date(.lastLaneIntervalStartAt)
        lastSchedulerIntervalStartAt = try date(.lastSchedulerIntervalStartAt)
        lastThresholdAt = try date(.lastThresholdAt)
    }

    /// A zeroed set that says how many windows preceded it. Used when the day
    /// or the epoch the counts belong to changes, and by the in-app reset, so
    /// that "all zero" is never mistaken for "the extension never ran".
    func restarted(epoch: UUID?, dayStart: Date?) -> Self {
        var fresh = ScreenTimeCallbackCounters()
        fresh.generation = generation
        Self.increment(&fresh.generation)
        fresh.epoch = epoch
        fresh.dayStart = dayStart
        return fresh
    }

    mutating func countInterval(kind: ScreenTimeActivityKind, phase: IntervalPhase, at now: Date) {
        switch (kind, phase) {
        case (.scheduler, .start):
            Self.increment(&schedulerIntervalStarts)
            lastSchedulerIntervalStartAt = now
        case (.scheduler, .end): Self.increment(&schedulerIntervalEnds)
        case (.lane, .start):
            Self.increment(&laneIntervalStarts)
            lastLaneIntervalStartAt = now
        case (.lane, .end): Self.increment(&laneIntervalEnds)
        case (.other, .start): Self.increment(&otherIntervalStarts)
        case (.other, .end): Self.increment(&otherIntervalEnds)
        }
        lastCallbackAt = now
    }

    /// `statusUnknown` is counted BESIDE the outcome, never instead of it: a
    /// process that cannot read its own authorization has said nothing about
    /// the callback, so the callback still has whatever outcome the ledger
    /// gave it.
    mutating func countThreshold(
        _ outcome: ThresholdOutcome, statusUnknown: Bool = false, at now: Date
    ) {
        Self.increment(&thresholds)
        switch outcome {
        case .recorded: Self.increment(&thresholdsRecorded)
        case .ignoredByLedger: Self.increment(&thresholdsIgnoredByLedger)
        case .ignoredByName: Self.increment(&thresholdsIgnoredByName)
        case .denied: Self.increment(&thresholdsDenied)
        }
        if statusUnknown { Self.increment(&statusUnknownAtCallback) }
        lastThresholdAt = now
        lastCallbackAt = now
    }

    /// A saturating bump. A counter that wrapped negative would make the whole
    /// ledger invalid and cost the user their selections; stopping at `Int.max`
    /// loses only evidence.
    private static func increment(_ value: inout Int) {
        let (next, overflow) = value.addingReportingOverflow(1)
        if !overflow { value = next }
    }

    private var allCounts: [Int] {
        [generation, schedulerIntervalStarts, laneIntervalStarts, otherIntervalStarts,
         schedulerIntervalEnds, laneIntervalEnds, otherIntervalEnds,
         thresholds, thresholdsRecorded, thresholdsIgnoredByLedger,
         thresholdsIgnoredByName, thresholdsDenied, statusUnknownAtCallback]
    }

    private var allDates: [Date?] {
        [dayStart, lastCallbackAt, lastLaneIntervalStartAt,
         lastSchedulerIntervalStartAt, lastThresholdAt]
    }

    var isValid: Bool {
        allCounts.allSatisfy { $0 >= 0 }
            && allDates.allSatisfy { $0?.timeIntervalSince1970.isFinite != false }
    }

    /// One line, counts and reasons only, safe to read straight off a device.
    /// An age of `-1` means that kind of callback has never been counted;
    /// `generation` says how many windows of counting came before this one.
    func logDescription(now: Date) -> String {
        func age(_ instant: Date?) -> Int {
            instant.map { ScreenTimeDiagnosticSeconds.between(now, $0) } ?? -1
        }
        return """
            callbacks generation=\(generation) schedulerStart=\(schedulerIntervalStarts) \
            laneStart=\(laneIntervalStarts) \
            otherStart=\(otherIntervalStarts) schedulerEnd=\(schedulerIntervalEnds) \
            laneEnd=\(laneIntervalEnds) otherEnd=\(otherIntervalEnds) \
            threshold=\(thresholds) recorded=\(thresholdsRecorded) \
            ignoredLedger=\(thresholdsIgnoredByLedger) ignoredName=\(thresholdsIgnoredByName) \
            denied=\(thresholdsDenied) statusUnknown=\(statusUnknownAtCallback) \
            lastAgeSec=\(age(lastCallbackAt)) laneStartAgeSec=\(age(lastLaneIntervalStartAt)) \
            schedulerStartAgeSec=\(age(lastSchedulerIntervalStartAt)) \
            thresholdAgeSec=\(age(lastThresholdAt))
            """
    }
}
