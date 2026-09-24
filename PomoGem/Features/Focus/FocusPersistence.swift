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

/// Why a running focus became self-reported. The engine keeps only the
/// demoted source, so this device records the cause it observed in its local
/// recovery envelope, where it survives a relaunch or an iCloud remount.
/// Telling someone who continued their own timer on another iPhone, or
/// restarted the phone, that its clock jumped would be false and sounds like
/// blame.
enum FocusDemotionNoticeReason: String, Equatable, Sendable {
    case clockChanged
    case adoptedFromOtherDevice
    /// Continued from a saved timer record that no other iPhone wrote, such as
    /// the local-only 「保存済みの進行中タイマー」 offer. Nothing proves the
    /// interval was measured continuously, but no other device was involved.
    case resumedFromSavedState
    case continuityLost
    /// A timer demoted before the cause was recorded (an older envelope).
    /// Its notice asserts no cause rather than guessing one.
    case unexplained

    /// A demotion caught while this device measures the timer, whether on the
    /// running screen or when a relaunch checks the saved clock anchor.
    static func detected(_ integrity: ClockIntegrity) -> Self? {
        switch integrity {
        case .valid: nil
        case .changed: .clockChanged
        case .uptimeReset, .unverifiable: .continuityLost
        }
    }

    /// Continuing a saved timer record always demotes it. Only a record that
    /// another iPhone wrote, in an iCloud-backed store, is a handoff; the
    /// local-only offer and this iPhone's own record resume saved state.
    static func adopted(
        isCloudBacked: Bool,
        sourceWriterDeviceID: String,
        currentDeviceID: String
    ) -> Self {
        isCloudBacked && sourceWriterDeviceID != currentDeviceID
            ? .adoptedFromOtherDevice
            : .resumedFromSavedState
    }

    var message: String {
        switch self {
        case .clockChanged:
            "端末時刻の大きな変化を検出。この回だけ自己申告あつかいです"
        case .adoptedFromOtherDevice:
            "別の端末から引き継いだため、この回は自己申告あつかいです"
        case .resumedFromSavedState:
            "保存済みの状態から再開したため、この回は自己申告あつかいです"
        case .continuityLost:
            "再起動などで計測が途切れたため、この回は自己申告あつかいです"
        case .unexplained:
            "この回は自己申告あつかいです"
        }
    }

    var systemImage: String {
        switch self {
        case .clockChanged: "clock.badge.exclamationmark"
        case .adoptedFromOtherDevice: "iphone.and.arrow.forward"
        case .resumedFromSavedState: "clock.arrow.circlepath"
        case .continuityLost: "arrow.clockwise.circle"
        case .unexplained: "info.circle"
        }
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
    /// Device-local, like the delivery witness above, and never part of
    /// FocusCloudPayload: what this device observed when the timer became
    /// self-reported. Kept as a raw string (absent in older envelopes) so an
    /// unrecognised value degrades to the neutral notice instead of failing
    /// to decode, and so discarding, the whole recovery.
    private var demotionReasonRawValue: String?

    var demotionReason: FocusDemotionNoticeReason? {
        get { demotionReasonRawValue.flatMap(FocusDemotionNoticeReason.init(rawValue:)) }
        set { demotionReasonRawValue = newValue?.rawValue }
    }

    init(
        engine: PomodoroEngine,
        subject: FocusSubjectSnapshot?,
        clockAnchor: ClockAnchor?,
        pendingCompletion: PomodoroCompletion?,
        savedAt: Date,
        scheduledCompletionNotificationDeliveryDate: Date? = nil,
        dataEpochID: UUID? = nil,
        demotionReason: FocusDemotionNoticeReason? = nil
    ) {
        self.engine = engine
        self.subject = subject
        self.clockAnchor = clockAnchor
        self.pendingCompletion = pendingCompletion
        self.savedAt = savedAt
        self.scheduledCompletionNotificationDeliveryDate =
            scheduledCompletionNotificationDeliveryDate
        self.dataEpochID = dataEpochID
        demotionReasonRawValue = demotionReason?.rawValue
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
    /// A reward-card selection starts its break before the visual drop. This
    /// optional link reconciles a crash between saving the timer and advancing
    /// the card, without recreating a break after its recovery is consumed.
    let originatingFocusSessionID: UUID?

    init(
        id: UUID,
        minutes: Int,
        endDate: Date,
        clockAnchor: ClockAnchor? = nil,
        scheduledCompletionNotificationDeliveryDate: Date? = nil,
        originatingFocusSessionID: UUID? = nil
    ) {
        self.id = id
        self.minutes = minutes
        self.endDate = endDate
        self.clockAnchor = clockAnchor
        self.scheduledCompletionNotificationDeliveryDate =
            scheduledCompletionNotificationDeliveryDate
        self.originatingFocusSessionID = originatingFocusSessionID
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

/// The durable hand-off from a result card to its first visible jar drop.
enum PendingRewardDropPhase: String, Codable, Sendable {
    case awaitingAcknowledgement
    case awaitingLanding
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
    /// Missing in older receipts, whose physical drop already happened before
    /// the card appeared. Keep nil distinct so upgrading never replays them.
    fileprivate(set) var dropPhase: PendingRewardDropPhase?

    var requiresDrop: Bool { dropPhase != nil }
    var isAwaitingAcknowledgement: Bool {
        dropPhase == .awaitingAcknowledgement
    }

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
        projectionCacheStamp: AggregateProjectionCacheStamp? = nil,
        dropPhase: PendingRewardDropPhase? = nil
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
        self.dropPhase = dropPhase
    }
}

enum PendingRewardReceiptStore {
    static let defaultsKey = "home.pending-reward-receipts.v1"
    static let maximumPendingCount = 4
    /// Posted after every write. Home derives what it shows (the start
    /// button, queued celebrations) from these receipts, and SwiftUI does not
    /// observe UserDefaults.
    static let didChangeNotification = Notification.Name("PendingRewardReceiptStore.didChange")

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
            NotificationCenter.default.post(name: didChangeNotification, object: defaults)
            return
        }
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        defaults.set(data, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: defaults)
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

    /// Persist the acknowledgement with one replacement of the existing
    /// receipt array. Keep its frozen metrics and FIFO position intact; never
    /// remove/reinsert it or turn a legacy, already-landed card into a new drop.
    @discardableResult
    static func acknowledgeDrop(
        id: UUID,
        defaults: UserDefaults = .standard
    ) -> Bool {
        var values = load(defaults: defaults)
        guard let index = values.firstIndex(where: { $0.id == id }) else {
            return false
        }
        switch values[index].dropPhase {
        case .awaitingAcknowledgement:
            values[index].dropPhase = .awaitingLanding
            save(values, defaults: defaults)
            return load(defaults: defaults).contains(values[index])
        case .awaitingLanding:
            return true
        case nil:
            return false
        }
    }

    static func remove(id: UUID, defaults: UserDefaults = .standard) {
        save(load(defaults: defaults).filter { $0.id != id }, defaults: defaults)
    }

    static func removeAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: AccountScopedLocalState.defaultsKey(
            base: defaultsKey,
            defaults: defaults
        ))
        NotificationCenter.default.post(name: didChangeNotification, object: defaults)
    }
}

/// Duration-normalized rest cadence for variable-length focus sessions.
///
/// Four 25-minute sessions historically produced a long-break suggestion.
/// Counting completions made six 10-minute sessions advance that cadence six
/// times faster than one 60-minute session. We instead accumulate measured
/// mass (10g/minute) and cross the same 100-minute boundary regardless of how
/// that time was split. A single uninterrupted block of 60 minutes or more
/// also earns the long break and restarts the cycle: split sessions already
/// had rests between them, one long block had none, and splitting can only
/// delay (never bring forward) that suggestion. Recent session IDs make
/// crash/replay handling idempotent; accepting the suggested break is always
/// optional.
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
    static let singleSessionLongBreakGrams = 60 * Constants.Mass.gramsPerMinute
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
        let breakMinutes: Int
        if contributionGrams >= singleSessionLongBreakGrams {
            // One long block had no rest inside it. Suggest the long break
            // now and start the next cycle from zero, so the following short
            // session does not immediately earn a second long break.
            state.creditedGrams = 0
            breakMinutes = Constants.Timer.longBreakMinutes
        } else {
            // Keep only quotient/remainder facts so even a corrupt Int.max
            // input cannot overflow or change the mathematical remainder.
            let contributionRemainder = contributionGrams % longBreakIntervalGrams
            let remainderTotal = state.creditedGrams + contributionRemainder
            state.creditedGrams = remainderTotal % longBreakIntervalGrams
            breakMinutes = remainderTotal >= longBreakIntervalGrams
                ? Constants.Timer.longBreakMinutes
                : Constants.Timer.shortBreakMinutes
        }
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
            adoptionReason: nil
        )
    }

    /// Uptime is device-local. An active timer adopted from iCloud can retain
    /// its duration and stable session ID, but cannot inherit proof that the
    /// remote interval was continuously measured on this device.
    /// `demotionReason` records why for the notice; it also replaces the
    /// source device's reason on a record that arrives already demoted.
    static func preparedForCrossDeviceAdoption(
        _ envelope: FocusRecoveryEnvelope,
        at now: Date,
        uptime: TimeInterval,
        demotionReason: FocusDemotionNoticeReason
    ) -> FocusRecoveryEnvelope {
        var prepared = preparedActiveFocus(
            envelope,
            at: now,
            uptime: uptime,
            adoptionReason: demotionReason
        )
        if prepared.pendingCompletion == nil,
           prepared.engine.containsRecoverableFocus,
           prepared.engine.currentSource == .timerDemoted {
            prepared.demotionReason = demotionReason
        }
        return prepared
    }

    /// `adoptionReason` is nil for a local relaunch, which must prove its own
    /// continuity from the saved anchor; an adoption always demotes.
    private static func preparedActiveFocus(
        _ envelope: FocusRecoveryEnvelope,
        at now: Date,
        uptime: TimeInterval,
        adoptionReason: FocusDemotionNoticeReason?
    ) -> FocusRecoveryEnvelope {
        // A pending completion froze its classification at the actual end
        // boundary. Replaying its persistence must not reclassify it using a
        // different process or device's uptime.
        guard envelope.pendingCompletion == nil,
              envelope.engine.containsRecoverableFocus,
              envelope.engine.currentSource == .timer
        else { return envelope }

        let demotionReason: FocusDemotionNoticeReason?
        if let adoptionReason {
            demotionReason = adoptionReason
        } else if let anchor = envelope.clockAnchor {
            // The same classification the running screen uses, so a clock
            // change found at relaunch is not reported as a reboot.
            demotionReason = FocusDemotionNoticeReason.detected(
                FairnessPolicy.clockIntegrity(
                    from: anchor,
                    completionDate: now,
                    completionUptime: uptime
                )
            )
        } else {
            demotionReason = .continuityLost
        }
        guard let demotionReason else { return envelope }

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
            dataEpochID: envelope.dataEpochID,
            demotionReason: demotionReason
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

    /// quality-01. A read-only look at one namespace's timer for the launch
    /// host, which shows an account-neutral status card while no iCloud
    /// session is mounted. It decodes and validates exactly like `load()` and
    /// `loadBreak`, but never clears, repairs or migrates anything: the
    /// account behind `namespace` has not been verified again in this launch,
    /// so nothing here may change its state. Only a time and a phase leave
    /// this function's caller (`LaunchTimerStatus`), the same payload the
    /// Live Activity already shows on the lock screen.
    static func peekTimerEnvelopes(
        namespace: AccountDataNamespace,
        defaults: UserDefaults = .standard,
        at now: Date = .now
    ) -> (focus: FocusRecoveryEnvelope?, rest: BreakRecoveryEnvelope?) {
        let focusKey = AccountScopedLocalState.defaultsKey(base: baseKey, namespace: namespace)
        let focus = defaults.data(forKey: focusKey)
            .flatMap { try? JSONDecoder().decode(FocusRecoveryEnvelope.self, from: $0) }
            .flatMap { hasValidPersistedStructure($0) ? $0 : nil }
        let breakKey = AccountScopedLocalState.defaultsKey(base: baseBreakKey, namespace: namespace)
        let rest = defaults.data(forKey: breakKey)
            .flatMap { try? JSONDecoder().decode(BreakRecoveryEnvelope.self, from: $0) }
            .flatMap { BreakRecoveryPolicy.isValid($0, at: now) ? $0 : nil }
        return (focus, rest)
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
        ) else {
            defaults.removeObject(forKey: key)
            return nil
        }
        // Saving a selected break precedes acknowledging its reward. Complete
        // that hand-off after a crash, even when the original break is now too
        // old to show. Its receipt must never offer a fresh five minutes again.
        if let sourceID = value.originatingFocusSessionID,
           let anchor = value.clockAnchor,
           value.id != sourceID,
           BreakRecoveryPolicy.isValid(value, at: anchor.wallDate) {
            if PendingRewardReceiptStore.load(defaults: defaults)
                .first(where: { $0.id == sourceID })?.requiresDrop == true {
                PendingRewardReceiptStore.acknowledgeDrop(id: sourceID, defaults: defaults)
            } else {
                PendingRewardReceiptStore.remove(id: sourceID, defaults: defaults)
            }
        }
        guard BreakRecoveryPolicy.isValid(value, at: now) else {
            defaults.removeObject(forKey: key)
            return nil
        }
        return value
    }

    /// Commits the user's rest choice before Home can disappear. The existing
    /// break envelope is the sole durable timer; the gem receipt never owns a
    /// second timer that could restart after Skip, completion, reset or delete.
    static func beginRewardBreak(
        sessionID: UUID,
        defaults: UserDefaults = .standard,
        at now: Date = .now,
        uptime: TimeInterval = ContinuousUptime.now()
    ) -> BreakRecoveryEnvelope? {
        if let existing = loadBreak(defaults: defaults, at: now) {
            return existing.originatingFocusSessionID == sessionID ? existing : nil
        }
        guard let receipt = PendingRewardReceiptStore.load(defaults: defaults)
            .first(where: { $0.id == sessionID }),
              receipt.dropPhase != .awaitingLanding,
              let seconds = BreakRecoveryPolicy.durationSeconds(minutes: receipt.breakMinutes)
        else { return nil }
        let recovery = BreakRecoveryEnvelope(
            id: UUID(),
            minutes: receipt.breakMinutes,
            endDate: now.addingTimeInterval(TimeInterval(seconds)),
            clockAnchor: ClockAnchor(wallDate: now, systemUptime: uptime),
            originatingFocusSessionID: sessionID
        )
        guard BreakRecoveryPolicy.isValid(recovery, at: now) else { return nil }
        saveBreak(recovery, defaults: defaults, at: now)
        guard let saved = loadBreak(defaults: defaults, at: now),
              saved == recovery else { return nil }
        return saved
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
