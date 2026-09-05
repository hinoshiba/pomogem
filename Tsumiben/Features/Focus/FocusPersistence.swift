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
    /// Device-local evidence that Notification Center accepted the request for
    /// this exact end date. It is deliberately omitted from FocusCloudPayload:
    /// notification ownership and delivery cannot be transferred as evidence
    /// between devices.
    var scheduledCompletionNotificationDeliveryDate: Date?
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
        scheduledCompletionNotificationDeliveryDate: Date? = nil,
        dataEpochID: UUID? = nil
    ) {
        self.engine = engine
        self.subject = subject
        self.clockAnchor = clockAnchor
        self.pendingCompletion = pendingCompletion
        self.savedAt = savedAt
        self.scheduledCompletionNotificationDeliveryDate =
            scheduledCompletionNotificationDeliveryDate
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
    /// Local monotonic/wall-time pairing used only to decide whether a
    /// persisted notification delivery Date is still safe to trust.
    let clockAnchor: ClockAnchor?
    var scheduledCompletionNotificationDeliveryDate: Date?

    init(
        id: UUID,
        minutes: Int,
        endDate: Date,
        clockAnchor: ClockAnchor? = nil,
        scheduledCompletionNotificationDeliveryDate: Date? = nil
    ) {
        self.id = id
        self.minutes = minutes
        self.endDate = endDate
        self.clockAnchor = clockAnchor
        self.scheduledCompletionNotificationDeliveryDate =
            scheduledCompletionNotificationDeliveryDate
    }
}

enum BreakRecoveryPolicy {
    private static let allowedMinutes: Set<Int> = [
        Constants.Timer.shortBreakMinutes,
        Constants.Timer.longBreakMinutes
    ]

    static func durationSeconds(minutes: Int) -> Int? {
        guard allowedMinutes.contains(minutes) else { return nil }
        let result = minutes.multipliedReportingOverflow(
            by: Constants.Timer.secondsPerMinute
        )
        guard !result.overflow, result.partialValue > 0 else { return nil }
        return result.partialValue
    }

    static func isValid(
        _ envelope: BreakRecoveryEnvelope,
        at now: Date
    ) -> Bool {
        guard validatedInterval(
            minutes: envelope.minutes,
            endDate: envelope.endDate,
            at: now
        ) != nil else { return false }
        if let anchor = envelope.clockAnchor {
            guard PomodoroEngine.isSafePersistedDate(anchor.wallDate),
                  anchor.systemUptime.isFinite,
                  anchor.systemUptime >= 0
            else { return false }
        }
        guard let notificationDeliveryDate =
            envelope.scheduledCompletionNotificationDeliveryDate else {
            return true
        }
        return notificationDeliveryDate
                >= envelope.endDate.addingTimeInterval(-0.01)
            && notificationDeliveryDate
                <= envelope.endDate.addingTimeInterval(
                    IntegrationConstants.notificationMinimumDelay
                        + IntegrationConstants
                            .notificationWitnessRegistrationAllowance
                )
    }

    /// Returns a bounded countdown for both a fresh break and validated local
    /// recovery. Invalid inputs resolve to zero, never integer overflow.
    static func remainingSeconds(
        minutes: Int,
        endDate: Date?,
        at now: Date
    ) -> Int {
        guard let duration = durationSeconds(minutes: minutes) else { return 0 }
        guard let endDate else { return duration }
        guard let interval = validatedInterval(
            minutes: minutes,
            endDate: endDate,
            at: now
        ) else { return 0 }
        guard interval > 0 else { return 0 }
        return min(duration, Int(interval.rounded(.up)))
    }

    private static func validatedInterval(
        minutes: Int,
        endDate: Date,
        at now: Date
    ) -> TimeInterval? {
        guard let duration = durationSeconds(minutes: minutes) else {
            return nil
        }
        let interval = endDate.timeIntervalSince(now)
        guard interval.isFinite else { return nil }
        // A recovery timestamp should remain near the break it describes.
        // Permit the same clock tolerance used by focus fairness, then reject
        // hostile far-future/far-past dates before any integer conversion.
        let maximumInterval = TimeInterval(duration)
            + Constants.Fairness.clockTolerance
        guard abs(interval) <= maximumInterval else { return nil }
        return interval
    }
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
    /// Aggregate presentation values are only reusable in the exact
    /// verification epoch that produced them. Optional preserves decoding of
    /// receipts written by earlier builds; cloud mode treats a missing stamp
    /// conservatively while local-only mode has no asynchronous importer.
    let projectionCacheStamp: AggregateProjectionCacheStamp?

    init(
        id: UUID,
        createdAt: Date,
        pebbleCount: Int,
        grams: Int,
        monthLabel: String,
        colorHex: String? = nil,
        level: Int? = nil,
        projectionCacheStamp: AggregateProjectionCacheStamp? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.pebbleCount = max(0, pebbleCount)
        self.grams = max(0, grams)
        self.monthLabel = monthLabel
        self.colorHex = colorHex
        self.level = level.map { max(1, $0) }
        self.projectionCacheStamp = projectionCacheStamp
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
        let key = AccountScopedLocalState.defaultsKey(
            base: defaultsKey,
            defaults: defaults
        )
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([PendingStratumCelebration].self, from: data)
        else { return [] }
        var seen = Set<UUID>()
        return values.filter { seen.insert($0.id).inserted }
    }

    static func save(
        _ values: [PendingStratumCelebration],
        defaults: UserDefaults = .standard
    ) {
        let key = AccountScopedLocalState.defaultsKey(
            base: defaultsKey,
            defaults: defaults
        )
        guard !values.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: key)
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
        defaults.removeObject(forKey: AccountScopedLocalState.defaultsKey(
            base: defaultsKey,
            defaults: defaults
        ))
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
    /// A cloud-unverified snapshot is not a lower bound: a later canonical
    /// rebuild may move the displayed lifetime value either direction.
    /// Optional preserves backward decoding of already queued receipts.
    let projectionWasCloudUnverified: Bool?
    /// Lease for the frozen lifetime effort/fusion values. This stamp is
    /// intentionally process-local in cloud mode, so a durable completion
    /// receipt can survive relaunch without reviving an old aggregate total.
    let projectionCacheStamp: AggregateProjectionCacheStamp?

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
        projectionIsLowerBound: Bool,
        projectionWasCloudUnverified: Bool = false,
        projectionCacheStamp: AggregateProjectionCacheStamp? = nil
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
        self.projectionWasCloudUnverified = projectionWasCloudUnverified
        self.projectionCacheStamp = projectionCacheStamp
    }
}

enum PendingRewardReceiptStore {
    static let defaultsKey = "home.pending-reward-receipts.v1"
    private static let maximumPendingCount = 4

    static func load(defaults: UserDefaults = .standard) -> [PendingRewardReceipt] {
        let key = AccountScopedLocalState.defaultsKey(
            base: defaultsKey,
            defaults: defaults
        )
        guard let data = defaults.data(forKey: key),
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
        let key = AccountScopedLocalState.defaultsKey(
            base: defaultsKey,
            defaults: defaults
        )
        let bounded = Array(values
            .sorted { $0.createdAt < $1.createdAt }
            .suffix(maximumPendingCount))
        guard !bounded.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        defaults.set(data, forKey: key)
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
        defaults.removeObject(forKey: AccountScopedLocalState.defaultsKey(
            base: defaultsKey,
            defaults: defaults
        ))
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
        let key = AccountScopedLocalState.defaultsKey(
            base: defaultsKey,
            defaults: defaults
        )
        guard let data = defaults.data(forKey: key),
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
            defaults.set(data, forKey: AccountScopedLocalState.defaultsKey(
                base: defaultsKey,
                defaults: defaults
            ))
        }
        return breakMinutes
    }

    static func removeAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: AccountScopedLocalState.defaultsKey(
            base: defaultsKey,
            defaults: defaults
        ))
    }
}

enum FocusPersistence {
    private static let baseKey = "focus.persisted-engine"
    private static let baseInterruptedFlagKey = "focus.recovered-interruption"
    private static let baseLocalCompletionIDKey = "focus.last-local-completion-id"
    private static let baseBreakKey = "break.persisted-session"

    static var key: String {
        AccountScopedLocalState.defaultsKey(base: baseKey)
    }

    static var interruptedFlagKey: String {
        AccountScopedLocalState.defaultsKey(base: baseInterruptedFlagKey)
    }

    static var localCompletionIDKey: String {
        AccountScopedLocalState.defaultsKey(base: baseLocalCompletionIDKey)
    }

    static var breakKey: String {
        AccountScopedLocalState.defaultsKey(base: baseBreakKey)
    }

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
            guard hasValidPersistedStructure(envelope) else {
                clear()
                return nil
            }
            return envelope
        }
        // Versions prior to the recovery envelope persisted only the state
        // machine. Keep that state detectable so the caller can retire it
        // safely instead of silently treating corrupt bytes as no session.
        guard let legacyEngine = try? JSONDecoder().decode(PomodoroEngine.self, from: data) else {
            clear()
            return nil
        }
        let envelope = FocusRecoveryEnvelope(
            engine: legacyEngine,
            subject: nil,
            clockAnchor: nil,
            pendingCompletion: nil,
            savedAt: .distantPast,
            dataEpochID: nil
        )
        guard hasValidPersistedStructure(envelope) else {
            clear()
            return nil
        }
        return envelope
    }

    /// UserDefaults is local, but its bytes survive crashes, partial legacy
    /// migrations and device restores. Validate all arithmetic-sensitive state
    /// before relaunch planning calls snapshot, resume or advance.
    private static func hasValidPersistedStructure(
        _ envelope: FocusRecoveryEnvelope
    ) -> Bool {
        guard PomodoroEngine.isSafePersistedDate(envelope.savedAt) else {
            return false
        }
        if let notificationDeliveryDate =
            envelope.scheduledCompletionNotificationDeliveryDate {
            guard PomodoroEngine.isSafePersistedDate(notificationDeliveryDate),
                  envelope.pendingCompletion == nil,
                  envelope.engine.hasValidRunningFocusPayloadState,
                  let endDate = envelope.engine.endDate,
                  notificationDeliveryDate
                    >= endDate.addingTimeInterval(-0.01),
                  notificationDeliveryDate
                    <= endDate.addingTimeInterval(
                        IntegrationConstants.notificationMinimumDelay
                            + IntegrationConstants
                                .notificationWitnessRegistrationAllowance
                    )
            else { return false }
        }
        if let anchor = envelope.clockAnchor {
            guard PomodoroEngine.isSafePersistedDate(anchor.wallDate),
                  anchor.systemUptime.isFinite,
                  anchor.systemUptime >= 0
            else { return false }
        }

        if let completion = envelope.pendingCompletion {
            return envelope.engine.hasValidPersistedCompletion(completion)
        }
        return envelope.engine.hasValidRunningFocusPayloadState
            || envelope.engine.hasValidPausedFocusPayloadState
            || envelope.engine.hasValidRecoverableBreakPayloadState
    }

    /// Revalidates a locally persisted active focus against the wall and
    /// continuous clocks sampled by the restoring process. Once monotonic
    /// continuity is lost (for example after a reboot), elapsed wall time is
    /// not sufficient proof of measured focus, so the same session continues
    /// as `timerDemoted` instead of receiving measured-only rewards.
    static func preparedForLocalRelaunch(
        _ envelope: FocusRecoveryEnvelope,
        at now: Date,
        uptime: TimeInterval
    ) -> FocusRecoveryEnvelope {
        preparedActiveFocus(
            envelope,
            at: now,
            uptime: uptime,
            requiresLocalContinuityProof: true
        )
    }

    /// Uptime is device-local. An active timer adopted from iCloud can retain
    /// its duration and stable session ID, but cannot inherit proof that the
    /// remote interval was continuously measured on this device.
    static func preparedForCrossDeviceAdoption(
        _ envelope: FocusRecoveryEnvelope,
        at now: Date,
        uptime: TimeInterval
    ) -> FocusRecoveryEnvelope {
        preparedActiveFocus(
            envelope,
            at: now,
            uptime: uptime,
            requiresLocalContinuityProof: false
        )
    }

    private static func preparedActiveFocus(
        _ envelope: FocusRecoveryEnvelope,
        at now: Date,
        uptime: TimeInterval,
        requiresLocalContinuityProof: Bool
    ) -> FocusRecoveryEnvelope {
        // A pending completion froze its classification at the actual end
        // boundary. Replaying its persistence must not reclassify it using a
        // different process or device's uptime.
        guard envelope.pendingCompletion == nil,
              envelope.engine.containsRecoverableFocus,
              envelope.engine.currentSource == .timer
        else { return envelope }

        let shouldDemote: Bool
        if requiresLocalContinuityProof, let anchor = envelope.clockAnchor {
            shouldDemote = FairnessPolicy.clockIntegrity(
                from: anchor,
                completionDate: now,
                completionUptime: uptime
            ).shouldDemote
        } else {
            shouldDemote = true
        }
        guard shouldDemote else { return envelope }

        var engine = envelope.engine
        do {
            try engine.demoteCurrentFocus()
        } catch {
            return envelope
        }
        let replacementAnchor: ClockAnchor? = {
            guard now.timeIntervalSinceReferenceDate.isFinite,
                  uptime.isFinite,
                  uptime >= 0 else { return nil }
            return ClockAnchor(wallDate: now, systemUptime: uptime)
        }()
        return FocusRecoveryEnvelope(
            engine: engine,
            subject: envelope.subject,
            clockAnchor: replacementAnchor,
            pendingCompletion: nil,
            savedAt: now,
            scheduledCompletionNotificationDeliveryDate:
                envelope.scheduledCompletionNotificationDeliveryDate,
            dataEpochID: envelope.dataEpochID
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
        guard hasValidPersistedStructure(envelope),
              PomodoroEngine.isSafePersistedDate(now)
        else { return .discard }
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

    /// Notification Center is global to the app, while recovery is namespaced
    /// per Apple Account. When an account boundary retires all timer requests,
    /// invalidate only the prior namespace's delivery witness so returning to
    /// that account cannot mistake an explicitly cancelled request for one that
    /// may have fired.
    static func clearScheduledCompletionNotificationWitness(
        namespace: AccountDataNamespace,
        defaults: UserDefaults = .standard
    ) {
        let focusKey = AccountScopedLocalState.defaultsKey(
            base: baseKey,
            namespace: namespace
        )
        if let data = defaults.data(forKey: focusKey),
           var envelope = try? JSONDecoder().decode(
               FocusRecoveryEnvelope.self,
               from: data
           ),
           hasValidPersistedStructure(envelope),
           envelope.scheduledCompletionNotificationDeliveryDate != nil {
            envelope.scheduledCompletionNotificationDeliveryDate = nil
            if let replacement = try? JSONEncoder().encode(envelope) {
                defaults.set(replacement, forKey: focusKey)
            }
        }

        let breakKey = AccountScopedLocalState.defaultsKey(
            base: baseBreakKey,
            namespace: namespace
        )
        if let data = defaults.data(forKey: breakKey),
           var envelope = try? JSONDecoder().decode(
               BreakRecoveryEnvelope.self,
               from: data
           ),
           BreakRecoveryPolicy.isValid(envelope, at: .now),
           envelope.scheduledCompletionNotificationDeliveryDate != nil {
            envelope.scheduledCompletionNotificationDeliveryDate = nil
            if let replacement = try? JSONEncoder().encode(envelope) {
                defaults.set(replacement, forKey: breakKey)
            }
        }
    }

    static func saveBreak(
        _ value: BreakRecoveryEnvelope,
        defaults: UserDefaults = .standard,
        at now: Date = .now
    ) {
        let key = AccountScopedLocalState.defaultsKey(
            base: baseBreakKey,
            defaults: defaults
        )
        guard BreakRecoveryPolicy.isValid(value, at: now) else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    static func loadBreak(
        defaults: UserDefaults = .standard,
        at now: Date = .now
    ) -> BreakRecoveryEnvelope? {
        let key = AccountScopedLocalState.defaultsKey(
            base: baseBreakKey,
            defaults: defaults
        )
        guard let data = defaults.data(forKey: key) else { return nil }
        guard let value = try? JSONDecoder().decode(
            BreakRecoveryEnvelope.self,
            from: data
        ), BreakRecoveryPolicy.isValid(value, at: now) else {
            defaults.removeObject(forKey: key)
            return nil
        }
        return value
    }

    static func clearBreak(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: AccountScopedLocalState.defaultsKey(
            base: baseBreakKey,
            defaults: defaults
        ))
    }
}

/// Records only the user's presentation choice. The earned completion itself
/// remains in `FocusPersistence`; this flag prevents a relaunch from trapping
/// the user back in the commit cover before they explicitly retry.
enum DeferredFocusCompletionStore {
    static let defaultsKey = "focus.pending-completion.deferred-home-id"

    static func sessionID(defaults: UserDefaults = .standard) -> UUID? {
        let key = AccountScopedLocalState.defaultsKey(
            base: defaultsKey,
            defaults: defaults
        )
        guard let raw = defaults.string(forKey: key) else { return nil }
        return UUID(uuidString: raw)
    }

    static func mark(
        sessionID: UUID,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(
            sessionID.uuidString.lowercased(),
            forKey: AccountScopedLocalState.defaultsKey(
                base: defaultsKey,
                defaults: defaults
            )
        )
    }

    static func clear(
        sessionID: UUID? = nil,
        defaults: UserDefaults = .standard
    ) {
        if let sessionID,
           self.sessionID(defaults: defaults) != sessionID { return }
        defaults.removeObject(forKey: AccountScopedLocalState.defaultsKey(
            base: defaultsKey,
            defaults: defaults
        ))
    }
}
