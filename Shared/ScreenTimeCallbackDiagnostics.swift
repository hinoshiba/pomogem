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
        /// `AuthorizationStatus` was not approved and not `.denied`. A freshly
        /// spawned extension process can read this before Family Controls has
        /// answered, and the callback is dropped without an award or a wipe.
        case unknownAuthorization
        /// Family Controls says the user revoked access.
        case denied
    }

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
    var thresholdsUnknownAuthorization = 0
    var thresholdsDenied = 0
    var lastCallbackAt: Date?

    mutating func countInterval(kind: ScreenTimeActivityKind, phase: IntervalPhase, at now: Date) {
        switch (kind, phase) {
        case (.scheduler, .start): Self.increment(&schedulerIntervalStarts)
        case (.scheduler, .end): Self.increment(&schedulerIntervalEnds)
        case (.lane, .start): Self.increment(&laneIntervalStarts)
        case (.lane, .end): Self.increment(&laneIntervalEnds)
        case (.other, .start): Self.increment(&otherIntervalStarts)
        case (.other, .end): Self.increment(&otherIntervalEnds)
        }
        lastCallbackAt = now
    }

    mutating func countThreshold(_ outcome: ThresholdOutcome, at now: Date) {
        Self.increment(&thresholds)
        switch outcome {
        case .recorded: Self.increment(&thresholdsRecorded)
        case .ignoredByLedger: Self.increment(&thresholdsIgnoredByLedger)
        case .ignoredByName: Self.increment(&thresholdsIgnoredByName)
        case .unknownAuthorization: Self.increment(&thresholdsUnknownAuthorization)
        case .denied: Self.increment(&thresholdsDenied)
        }
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
        [schedulerIntervalStarts, laneIntervalStarts, otherIntervalStarts,
         schedulerIntervalEnds, laneIntervalEnds, otherIntervalEnds,
         thresholds, thresholdsRecorded, thresholdsIgnoredByLedger,
         thresholdsIgnoredByName, thresholdsUnknownAuthorization, thresholdsDenied]
    }

    var isValid: Bool {
        allCounts.allSatisfy { $0 >= 0 }
            && lastCallbackAt?.timeIntervalSince1970.isFinite != false
    }

    /// One line, counts and reasons only, safe to read straight off a device.
    /// `lastAgeSec=-1` means no callback has ever been counted.
    func logDescription(now: Date) -> String {
        let age = lastCallbackAt.map { Int(now.timeIntervalSince($0).rounded()) } ?? -1
        return """
            callbacks schedulerStart=\(schedulerIntervalStarts) laneStart=\(laneIntervalStarts) \
            otherStart=\(otherIntervalStarts) schedulerEnd=\(schedulerIntervalEnds) \
            laneEnd=\(laneIntervalEnds) otherEnd=\(otherIntervalEnds) \
            threshold=\(thresholds) recorded=\(thresholdsRecorded) \
            ignoredLedger=\(thresholdsIgnoredByLedger) ignoredName=\(thresholdsIgnoredByName) \
            unknownAuth=\(thresholdsUnknownAuthorization) denied=\(thresholdsDenied) \
            lastAgeSec=\(age)
            """
    }
}
