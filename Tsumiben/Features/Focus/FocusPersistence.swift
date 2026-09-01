import Foundation

struct FocusSubjectSnapshot: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let colorHex: String

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case colorHex
    }

    init(id: UUID, name: String, colorHex: String) {
        self.id = id
        self.name = SubjectNamePolicy.displayName(name)
        self.colorHex = colorHex
    }

    init(subject: Subject) {
        self.init(id: subject.id, name: subject.name, colorHex: subject.colorHex)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = SubjectNamePolicy.displayName(
            try values.decode(String.self, forKey: .name)
        )
        colorHex = try values.decode(String.self, forKey: .colorHex)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(colorHex, forKey: .colorHex)
    }
}

struct FocusRecoveryEnvelope: Codable, Equatable, Sendable {
    var engine: PomodoroEngine
    let subject: FocusSubjectSnapshot?
    let clockAnchor: ClockAnchor?
    var pendingCompletion: PomodoroCompletion?
    var savedAt: Date
    /// Generation is frozen when focus starts. A reset received while the
    /// timer is offline must cancel it, never silently promote it into the new
    /// activity generation.
    var dataEpochID: UUID?

    init(
        engine: PomodoroEngine,
        subject: FocusSubjectSnapshot?,
        clockAnchor: ClockAnchor?,
        pendingCompletion: PomodoroCompletion?,
        savedAt: Date,
        dataEpochID: UUID? = nil
    ) {
        self.engine = engine
        self.subject = subject
        self.clockAnchor = clockAnchor
        self.pendingCompletion = pendingCompletion
        self.savedAt = savedAt
        self.dataEpochID = dataEpochID
    }
}

enum FocusRelaunchAction: Equatable, Sendable {
    case resumeFocus(remainingSeconds: Int)
    case finishFocus
    case commitPendingCompletion
    case restoreBreak
    case discard

    var restoresFocusView: Bool {
        switch self {
        case .resumeFocus, .finishFocus, .commitPendingCompletion, .restoreBreak:
            true
        case .discard:
            false
        }
    }
}

struct BreakRecoveryEnvelope: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let minutes: Int
    let endDate: Date
}

struct PendingStratumCelebration: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let pebbleCount: Int
    let grams: Int
    let monthLabel: String
    /// Optional so receipts written by earlier builds remain decodable. New
    /// fusion receipts keep the aggregate's real dominant subject colour and
    /// tier, allowing the celebration to look like the crystal that actually
    /// landed instead of a generic amber badge.
    let colorHex: String?
    let level: Int?

    init(
        id: UUID,
        createdAt: Date,
        pebbleCount: Int,
        grams: Int,
        monthLabel: String,
        colorHex: String? = nil,
        level: Int? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.pebbleCount = max(0, pebbleCount)
        self.grams = max(0, grams)
        self.monthLabel = monthLabel
        self.colorHex = colorHex
        self.level = level.map { max(1, $0) }
    }
}

enum PendingStratumCelebrationSelection {
    static func latest(
        in values: [PendingStratumCelebration]
    ) -> PendingStratumCelebration? {
        values.max { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            if lhs.pebbleCount != rhs.pebbleCount {
                return lhs.pebbleCount < rhs.pebbleCount
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

enum PendingStratumCelebrationStore {
    static let defaultsKey = "jar.pending-stratum-celebrations.v1"

    static func load(defaults: UserDefaults = .standard) -> [PendingStratumCelebration] {
        guard let data = defaults.data(forKey: defaultsKey),
              let values = try? JSONDecoder().decode([PendingStratumCelebration].self, from: data)
        else { return [] }
        var seen = Set<UUID>()
        return values.filter { seen.insert($0.id).inserted }
    }

    static func save(
        _ values: [PendingStratumCelebration],
        defaults: UserDefaults = .standard
    ) {
        guard !values.isEmpty else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func insert(
        _ value: PendingStratumCelebration,
        defaults: UserDefaults = .standard
    ) {
        var values = load(defaults: defaults)
        guard !values.contains(where: { $0.id == value.id }) else { return }
        values.append(value)
        save(values, defaults: defaults)
    }

    static func remove(id: UUID, defaults: UserDefaults = .standard) {
        save(load(defaults: defaults).filter { $0.id != id }, defaults: defaults)
    }

    static func removeAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// A local, durable receipt for the emotional hand-off from a committed timer
/// to Home. The StudySession remains the source of truth; this small snapshot
/// only guarantees that a process termination cannot permanently swallow the
/// one-time “what your effort became” presentation.
struct PendingRewardReceipt: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let breakMinutes: Int
    let grams: Int
    let subjectName: String
    let colorHex: String
    let weeklyCompletionCount: Int
    /// Added after the original return-count card. Optional keeps receipts
    /// written by older builds decodable while letting new cards lead with
    /// duration-normalized weekly mass.
    let weeklyStudyGrams: Int?
    let kind: PebbleKind
    /// Optional for backward decoding. New receipts retain the complete
    /// per-250g batch even though the jar renders one representative body.
    let rareRewardDrawCount: Int?
    let goldRewardCount: Int?
    let prismRewardCount: Int?
    let totalPebbleCount: Int
    /// Added after the original count-based Reward Bridge shipped. Optional so
    /// receipts written by older builds decode unchanged and can use the legacy
    /// count presentation as a compatibility fallback.
    let totalStudyGrams: Int?
    let projectionIsLowerBound: Bool

    init(
        id: UUID,
        createdAt: Date,
        breakMinutes: Int,
        grams: Int,
        subjectName: String,
        colorHex: String,
        weeklyCompletionCount: Int,
        weeklyStudyGrams: Int? = nil,
        kind: PebbleKind,
        rareRewardDrawCount: Int? = nil,
        goldRewardCount: Int? = nil,
        prismRewardCount: Int? = nil,
        totalPebbleCount: Int,
        totalStudyGrams: Int? = nil,
        projectionIsLowerBound: Bool
    ) {
        self.id = id
        self.createdAt = createdAt
        self.breakMinutes = max(1, breakMinutes)
        self.grams = max(0, grams)
        self.subjectName = SubjectNamePolicy.displayName(subjectName)
        self.colorHex = colorHex
        self.weeklyCompletionCount = max(1, weeklyCompletionCount)
        self.weeklyStudyGrams = weeklyStudyGrams.map { max(0, $0) }
        self.kind = kind
        self.rareRewardDrawCount = rareRewardDrawCount.map { max(0, $0) }
        self.goldRewardCount = goldRewardCount.map { max(0, $0) }
        self.prismRewardCount = prismRewardCount.map { max(0, $0) }
        self.totalPebbleCount = max(1, totalPebbleCount)
        self.totalStudyGrams = totalStudyGrams.map { max(0, $0) }
        self.projectionIsLowerBound = projectionIsLowerBound
    }
}

enum PendingRewardReceiptStore {
    static let defaultsKey = "home.pending-reward-receipts.v1"
    private static let maximumPendingCount = 4

    static func load(defaults: UserDefaults = .standard) -> [PendingRewardReceipt] {
        guard let data = defaults.data(forKey: defaultsKey),
              let values = try? JSONDecoder().decode([PendingRewardReceipt].self, from: data)
        else { return [] }
        var seen = Set<UUID>()
        return Array(values
            .sorted { $0.createdAt < $1.createdAt }
            .filter { seen.insert($0.id).inserted }
            .suffix(maximumPendingCount))
    }

    static func save(
        _ values: [PendingRewardReceipt],
        defaults: UserDefaults = .standard
    ) {
        let bounded = Array(values
            .sorted { $0.createdAt < $1.createdAt }
            .suffix(maximumPendingCount))
        guard !bounded.isEmpty else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    @discardableResult
    static func insert(
        _ value: PendingRewardReceipt,
        defaults: UserDefaults = .standard
    ) -> Bool {
        var values = load(defaults: defaults)
        if values.contains(where: { $0.id == value.id }) { return true }
        values.append(value)
        save(values, defaults: defaults)
        return load(defaults: defaults).contains { $0.id == value.id }
    }

    static func remove(id: UUID, defaults: UserDefaults = .standard) {
        save(load(defaults: defaults).filter { $0.id != id }, defaults: defaults)
    }

    static func removeAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// Duration-normalized rest cadence for variable-length focus sessions.
///
/// Four 25-minute sessions historically produced a long-break suggestion.
/// Counting completions made six 10-minute sessions advance that cadence six
/// times faster than one 60-minute session. We instead accumulate measured
/// mass (10g/minute) and cross the same 100-minute boundary regardless of how
/// that time was split. Recent session IDs make crash/replay handling
/// idempotent; accepting the suggested break is always optional.
struct FocusRestCadenceSnapshot: Codable, Equatable, Sendable {
    struct Record: Codable, Equatable, Sendable {
        let sessionID: UUID
        let breakMinutes: Int
    }

    var creditedGrams: Int
    var recentRecords: [Record]
}

enum FocusRestCadenceStore {
    static let defaultsKey = "focus.rest-cadence.v2"
    static let longBreakIntervalGrams = 100 * Constants.Mass.gramsPerMinute
    private static let maximumRecentRecordCount = 32

    static func load(defaults: UserDefaults = .standard) -> FocusRestCadenceSnapshot {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(
                FocusRestCadenceSnapshot.self,
                from: data
              )
        else {
            return FocusRestCadenceSnapshot(creditedGrams: 0, recentRecords: [])
        }
        return FocusRestCadenceSnapshot(
            creditedGrams: max(0, decoded.creditedGrams) % longBreakIntervalGrams,
            recentRecords: Array(decoded.recentRecords.suffix(maximumRecentRecordCount))
        )
    }

    /// Records one committed timer completion and returns the rest suggestion
    /// frozen for that session. Replaying the same completion never advances
    /// the cadence twice.
    @discardableResult
    static func record(
        sessionID: UUID,
        contributionGrams rawContributionGrams: Int,
        defaults: UserDefaults = .standard
    ) -> Int {
        var state = load(defaults: defaults)
        if let existing = state.recentRecords.last(where: { $0.sessionID == sessionID }) {
            return existing.breakMinutes
        }

        let contributionGrams = max(0, rawContributionGrams)
        // Keep only quotient/remainder facts so even a corrupt Int.max input
        // cannot overflow or change the mathematical remainder.
        let contributionCrossesBoundary = contributionGrams >= longBreakIntervalGrams
        let contributionRemainder = contributionGrams % longBreakIntervalGrams
        let remainderTotal = state.creditedGrams + contributionRemainder
        let crossedLongBreakBoundary = contributionCrossesBoundary
            || remainderTotal >= longBreakIntervalGrams
        state.creditedGrams = remainderTotal % longBreakIntervalGrams
        let breakMinutes = crossedLongBreakBoundary
            ? Constants.Timer.longBreakMinutes
            : Constants.Timer.shortBreakMinutes
        state.recentRecords.append(FocusRestCadenceSnapshot.Record(
            sessionID: sessionID,
            breakMinutes: breakMinutes
        ))
        state.recentRecords = Array(
            state.recentRecords.suffix(maximumRecentRecordCount)
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: defaultsKey)
        }
        return breakMinutes
    }

    static func removeAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

enum FocusPersistence {
    static let key = "focus.persisted-engine"
    static let interruptedFlagKey = "focus.recovered-interruption"
    static let localCompletionIDKey = "focus.last-local-completion-id"
    static let breakKey = "break.persisted-session"

    static func save(
        _ engine: PomodoroEngine,
        subject: FocusSubjectSnapshot,
        clockAnchor: ClockAnchor?,
        pendingCompletion: PomodoroCompletion? = nil
    ) {
        save(
            FocusRecoveryEnvelope(
                engine: engine,
                subject: subject,
                clockAnchor: clockAnchor,
                pendingCompletion: pendingCompletion,
                savedAt: .now,
                dataEpochID: nil
            )
        )
    }

    static func save(_ envelope: FocusRecoveryEnvelope) {
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> FocusRecoveryEnvelope? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        if let envelope = try? JSONDecoder().decode(FocusRecoveryEnvelope.self, from: data) {
            return envelope
        }
        // Versions prior to the recovery envelope persisted only the state
        // machine. Keep that state detectable so the caller can retire it
        // safely instead of silently treating corrupt bytes as no session.
        guard let legacyEngine = try? JSONDecoder().decode(PomodoroEngine.self, from: data) else {
            return nil
        }
        return FocusRecoveryEnvelope(
            engine: legacyEngine,
            subject: nil,
            clockAnchor: nil,
            pendingCompletion: nil,
            savedAt: .distantPast,
            dataEpochID: nil
        )
    }

    /// Produces a deterministic relaunch plan without changing the saved
    /// engine. A running focus keeps its absolute scheduled end and session ID:
    /// `FocusView` can therefore either display the remaining interval or
    /// advance the exact same session into its idempotent completion commit.
    static func relaunchAction(
        for envelope: FocusRecoveryEnvelope,
        at now: Date
    ) -> FocusRelaunchAction {
        let engine = envelope.engine

        if let pendingCompletion = envelope.pendingCompletion {
            guard engine.currentSessionID == nil
                    || engine.currentSessionID == pendingCompletion.sessionID
            else { return .discard }
            return .commitPendingCompletion
        }

        if engine.containsRecoverableFocus {
            guard engine.currentSessionID != nil else { return .discard }
            let snapshot = engine.snapshot(at: now)
            if snapshot.phase == .paused {
                return .resumeFocus(remainingSeconds: snapshot.remainingSeconds)
            }
            guard let scheduledEnd = engine.endDate else { return .discard }
            if scheduledEnd <= now {
                return .finishFocus
            }
            return .resumeFocus(remainingSeconds: snapshot.remainingSeconds)
        }

        if engine.containsRecoverableBreak {
            return .restoreBreak
        }

        return .discard
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        DeferredFocusCompletionStore.clear()
    }

    static func saveBreak(_ value: BreakRecoveryEnvelope) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: breakKey)
    }

    static func loadBreak() -> BreakRecoveryEnvelope? {
        guard let data = UserDefaults.standard.data(forKey: breakKey) else { return nil }
        return try? JSONDecoder().decode(BreakRecoveryEnvelope.self, from: data)
    }

    static func clearBreak() {
        UserDefaults.standard.removeObject(forKey: breakKey)
    }
}

/// Records only the user's presentation choice. The earned completion itself
/// remains in `FocusPersistence`; this flag prevents a relaunch from trapping
/// the user back in the commit cover before they explicitly retry.
enum DeferredFocusCompletionStore {
    static let defaultsKey = "focus.pending-completion.deferred-home-id"

    static func sessionID(defaults: UserDefaults = .standard) -> UUID? {
        guard let raw = defaults.string(forKey: defaultsKey) else { return nil }
        return UUID(uuidString: raw)
    }

    static func mark(
        sessionID: UUID,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(sessionID.uuidString.lowercased(), forKey: defaultsKey)
    }

    static func clear(
        sessionID: UUID? = nil,
        defaults: UserDefaults = .standard
    ) {
        if let sessionID,
           self.sessionID(defaults: defaults) != sessionID { return }
        defaults.removeObject(forKey: defaultsKey)
    }
}
