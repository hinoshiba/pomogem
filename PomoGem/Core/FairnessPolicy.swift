import Darwin
import Foundation

struct ManualCounterState: Equatable, Codable, Sendable {
    var dayKey: String
    var usedToday: Int

    init(dayKey: String = "", usedToday: Int = 0) {
        self.dayKey = dayKey
        self.usedToday = max(0, usedToday)
    }
}

struct ManualEntryDecision: Equatable, Sendable {
    let isAllowed: Bool
    let state: ManualCounterState
    let remainingEntries: Int
}

struct ManualEntryAvailability: Equatable, Sendable {
    let state: ManualCounterState
    let remainingEntries: Int

    var isAllowed: Bool {
        remainingEntries > 0
    }

    var remainingEntriesAfterSaving: Int {
        max(0, remainingEntries - 1)
    }
}

/// Monotonic seconds that continue across screen lock and device sleep.
///
/// `ProcessInfo.systemUptime` can represent awake time on some Apple OS
/// versions. `mach_continuous_time` is the appropriate comparison clock for a
/// timer that promises to keep progressing while the screen is locked.
enum ContinuousUptime {
    private static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        _ = mach_timebase_info(&timebase)
        guard timebase.denom != 0 else { return 0 }
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    static func now() -> TimeInterval {
        let converted = Double(mach_continuous_time()) * secondsPerTick
        return converted.isFinite && converted >= 0
            ? converted
            : ProcessInfo.processInfo.systemUptime
    }
}

enum ClockAnchorBasis: String, Codable, Equatable, Sendable {
    case continuousUptime
    case legacySystemUptime
}

struct ClockAnchor: Equatable, Codable, Sendable {
    let wallDate: Date
    let systemUptime: TimeInterval
    let basis: ClockAnchorBasis

    init(
        wallDate: Date = Date(),
        systemUptime: TimeInterval = ContinuousUptime.now(),
        basis: ClockAnchorBasis = .continuousUptime
    ) {
        self.wallDate = wallDate
        self.systemUptime = systemUptime
        self.basis = basis
    }

    private enum CodingKeys: String, CodingKey {
        case wallDate
        case systemUptime
        case basis
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wallDate = try container.decode(Date.self, forKey: .wallDate)
        systemUptime = try container.decode(TimeInterval.self, forKey: .systemUptime)
        // Anchors written before the continuous-clock migration used
        // ProcessInfo uptime. The two clock bases cannot be compared; active
        // recovery therefore treats them as unverifiable and preserves the
        // effort only as a self-reported completion.
        basis = try container.decodeIfPresent(ClockAnchorBasis.self, forKey: .basis)
            ?? .legacySystemUptime
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wallDate, forKey: .wallDate)
        try container.encode(systemUptime, forKey: .systemUptime)
        try container.encode(basis, forKey: .basis)
    }
}

enum ClockIntegrity: Equatable, Sendable {
    case valid(drift: TimeInterval)
    case changed(drift: TimeInterval)
    case uptimeReset
    case unverifiable

    var shouldDemote: Bool {
        switch self {
        case .valid:
            false
        case .changed, .uptimeReset, .unverifiable:
            true
        }
    }
}

enum FairnessPolicy {
    /// Produces the local study-day key using a 04:00 boundary. The Gregorian
    /// calendar is deliberate: changing the user's display calendar must not
    /// silently rewrite persisted `yyyy-MM-dd` keys.
    static func deviceDayKey(
        for date: Date,
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone

        let boundary = calendar.date(
            bySettingHour: Constants.Fairness.dayBoundaryHour,
            minute: 0,
            second: 0,
            of: date
        ) ?? calendar.startOfDay(for: date)

        let studyDay = date < boundary
            ? (calendar.date(byAdding: .day, value: -1, to: date) ?? date)
            : date
        let components = calendar.dateComponents([.year, .month, .day], from: studyDay)

        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    /// Reads the manual-entry allowance without mutating the persisted counter.
    /// A stale counter is normalized against the same 04:00 study-day boundary
    /// used by the eventual consume operation, so confirmation copy cannot show
    /// yesterday's remaining count.
    static func manualEntryAvailability(
        state: ManualCounterState,
        at date: Date,
        timeZone: TimeZone = .current
    ) -> ManualEntryAvailability {
        let currentKey = deviceDayKey(for: date, timeZone: timeZone)
        let normalizedUsage = state.dayKey == currentKey ? max(0, state.usedToday) : 0
        return ManualEntryAvailability(
            state: ManualCounterState(dayKey: currentKey, usedToday: normalizedUsage),
            remainingEntries: max(0, Constants.Fairness.manualEntriesPerDay - normalizedUsage)
        )
    }

    /// Attempts one manual entry, atomically returning the normalized counter
    /// for the current 04:00-based day.
    static func consumeManualEntry(
        state: ManualCounterState,
        at date: Date,
        timeZone: TimeZone = .current
    ) -> ManualEntryDecision {
        let availability = manualEntryAvailability(
            state: state,
            at: date,
            timeZone: timeZone
        )
        let isAllowed = availability.isAllowed
        let updatedUsage = availability.state.usedToday + (isAllowed ? 1 : 0)
        let updatedState = ManualCounterState(
            dayKey: availability.state.dayKey,
            usedToday: updatedUsage
        )

        return ManualEntryDecision(
            isAllowed: isAllowed,
            state: updatedState,
            remainingEntries: isAllowed
                ? availability.remainingEntriesAfterSaving
                : availability.remainingEntries
        )
    }

    /// Convenience overload for the persisted preferences singleton.
    @discardableResult
    static func consumeManualEntry(
        prefs: Prefs,
        at date: Date,
        timeZone: TimeZone = .current
    ) -> Bool {
        let decision = consumeManualEntry(
            state: ManualCounterState(
                dayKey: prefs.manualDayKey,
                usedToday: prefs.manualUsedToday
            ),
            at: date,
            timeZone: timeZone
        )
        prefs.manualDayKey = decision.state.dayKey
        prefs.manualUsedToday = decision.state.usedToday
        return decision.isAllowed
    }

    /// Compares wall-clock and monotonic elapsed time. A timezone or DST change
    /// alone does not affect `Date`, while manually moving the clock does.
    static func clockIntegrity(
        from anchor: ClockAnchor,
        completionDate: Date,
        completionUptime: TimeInterval
    ) -> ClockIntegrity {
        guard anchor.basis == .continuousUptime else { return .unverifiable }
        let monotonicElapsed = completionUptime - anchor.systemUptime
        guard monotonicElapsed.isFinite, monotonicElapsed >= 0 else {
            return .uptimeReset
        }

        let wallElapsed = completionDate.timeIntervalSince(anchor.wallDate)
        guard wallElapsed.isFinite else { return .changed(drift: .infinity) }

        let drift = abs(wallElapsed - monotonicElapsed)
        if drift > Constants.Fairness.clockTolerance {
            return .changed(drift: drift)
        }
        return .valid(drift: drift)
    }

    static func finalSource(
        original: SessionSource,
        clockIntegrity: ClockIntegrity
    ) -> SessionSource {
        guard original == .timer else { return original }
        return clockIntegrity.shouldDemote ? .timerDemoted : .timer
    }

    /// Freezes the final fairness classification at the completion boundary.
    /// Legacy pending completions have no monotonic observation; their stored
    /// source is trusted instead of incorrectly comparing it with a new
    /// process's uptime during a later persistence retry.
    static func finalizedCompletion(
        _ completion: PomodoroCompletion,
        clockAnchor: ClockAnchor?
    ) -> PomodoroCompletion {
        guard let clockAnchor, let observedUptime = completion.observedUptime else {
            return completion
        }
        let integrity = clockIntegrity(
            from: clockAnchor,
            completionDate: completion.observedAt,
            completionUptime: observedUptime
        )
        let source = finalSource(
            original: completion.source,
            clockIntegrity: integrity
        )
        return completion.replacingSource(with: source)
    }

    static func isIncludedInShareByDefault(source: SessionSource) -> Bool {
        source == .timer
    }

    /// Atomically reserves the lifetime-only bedrock import. The preference is
    /// a tombstone and must not be cleared when the visible Bedrock is deleted.
    @discardableResult
    static func consumeBedrockImport(prefs: Prefs, existingBedrockCount: Int) -> Bool {
        guard !prefs.hasEverImportedBedrock, existingBedrockCount == 0 else {
            return false
        }
        prefs.hasEverImportedBedrock = true
        return true
    }
}
