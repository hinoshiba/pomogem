import Foundation
import SwiftData

enum SyncedFocusStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case running
    case paused
    case completionPending
    case completed
    case cancelled

    var isRecoverable: Bool {
        switch self {
        case .running, .paused, .completionPending:
            true
        case .completed, .cancelled:
            false
        }
    }

    var isTerminal: Bool {
        self == .completed || self == .cancelled
    }
}

/// The portable portion of a focus recovery envelope.
///
/// A monotonic clock anchor is deliberately not synchronized: uptime has a
/// meaning only on the device that sampled it. A receiving device establishes
/// a new local anchor when the user explicitly adopts the timer.
struct FocusCloudPayload: Codable, Equatable, Sendable {
    static let currentVersion = 2

    let version: Int
    var engine: PomodoroEngine
    let subject: FocusSubjectSnapshot
    var pendingCompletion: PomodoroCompletion?
    var savedAt: Date
    var dataEpochID: UUID?

    init(envelope: FocusRecoveryEnvelope) throws {
        guard let subject = envelope.subject else {
            throw FocusCloudSyncError.missingSubject
        }
        guard envelope.engine.currentSessionID != nil
                || envelope.pendingCompletion != nil
        else {
            throw FocusCloudSyncError.missingSessionID
        }

        version = Self.currentVersion
        engine = envelope.engine
        self.subject = subject
        pendingCompletion = envelope.pendingCompletion?.portableCopy
        savedAt = envelope.savedAt
        dataEpochID = envelope.dataEpochID
    }

    func recoveryEnvelope(adoptedAt now: Date) -> FocusRecoveryEnvelope {
        FocusRecoveryEnvelope(
            engine: engine,
            subject: subject,
            // Cross-device recovery starts a fresh monotonic comparison. This
            // catches later wall-clock jumps without comparing two devices'
            // unrelated uptime values.
            clockAnchor: engine.containsRecoverableFocus
                ? ClockAnchor(wallDate: now, systemUptime: ContinuousUptime.now())
                : nil,
            pendingCompletion: pendingCompletion,
            savedAt: now,
            dataEpochID: dataEpochID
        )
    }
}

private extension PomodoroCompletion {
    var portableCopy: PomodoroCompletion {
        PomodoroCompletion(
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: endedAt,
            observedAt: observedAt,
            // Process uptime is not comparable on a second device. The source
            // classification has already been frozen at the first completion.
            observedUptime: nil,
            duration: duration,
            seconds: seconds,
            grams: grams,
            source: source
        )
    }
}

enum FocusCloudSyncError: Error, LocalizedError, Equatable {
    case missingSubject
    case missingSessionID
    case missingTimerRecord
    case invalidPayload
    case ownershipLost
    case activityWasReset

    var errorDescription: String? {
        switch self {
        case .missingSubject:
            "同期するタイマーの科目情報がありません。"
        case .missingSessionID:
            "同期するタイマーの識別情報がありません。"
        case .missingTimerRecord:
            "同期するタイマーの保存情報が見つかりません。"
        case .invalidPayload:
            "iCloudのタイマー情報を読み取れませんでした。"
        case .ownershipLost:
            "このタイマーは別の端末へ引き継がれています。"
        case .activityWasReset:
            "このタイマーは記録のリセット以前に開始されたため終了しました。"
        }
    }
}

/// CloudKit-backed focus state. All fields have defaults and relationships are
/// avoided so SwiftData can initialize and merge the CloudKit schema safely.
/// Terminal rows are retained as tombstones, preventing a stale offline device
/// from reviving a timer that was already completed or cancelled elsewhere.
@Model
final class SyncedFocusTimer {
    var id: UUID = UUID()
    var dataEpochID: UUID?
    var sessionID: UUID = UUID()
    var statusRaw: String = SyncedFocusStatus.running.rawValue
    var payloadData: Data = Data()
    var startedAt: Date = Date(timeIntervalSince1970: 0)
    var scheduledEndAt: Date?
    var updatedAt: Date = Date(timeIntervalSince1970: 0)
    var terminalAt: Date?
    var revision: Int = 0
    var ownershipSequence: Int = 0
    var writerDeviceID: String = ""

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        status: SyncedFocusStatus,
        payload: FocusCloudPayload,
        updatedAt: Date,
        revision: Int = 1,
        ownershipSequence: Int = 0,
        writerDeviceID: String
    ) throws {
        self.id = id
        dataEpochID = payload.dataEpochID
        self.sessionID = sessionID
        statusRaw = status.rawValue
        payloadData = try JSONEncoder().encode(payload)
        startedAt = Self.startedAt(payload: payload, fallback: updatedAt)
        scheduledEndAt = Self.scheduledEndAt(payload: payload)
        self.updatedAt = updatedAt
        self.revision = max(1, revision)
        self.ownershipSequence = max(0, ownershipSequence)
        self.writerDeviceID = writerDeviceID
        terminalAt = status == .completed
            ? (scheduledEndAt ?? updatedAt)
            : (status == .cancelled ? updatedAt : nil)
    }

    var status: SyncedFocusStatus {
        get { SyncedFocusStatus(rawValue: statusRaw) ?? .cancelled }
        set { statusRaw = newValue.rawValue }
    }

    func decodedPayload() throws -> FocusCloudPayload {
        guard let payload = try? JSONDecoder().decode(
            FocusCloudPayload.self,
            from: payloadData
        ), payload.version <= FocusCloudPayload.currentVersion,
        payload.dataEpochID == dataEpochID else {
            throw FocusCloudSyncError.invalidPayload
        }
        return payload
    }

    func replacePayload(
        _ payload: FocusCloudPayload,
        status: SyncedFocusStatus,
        updatedAt: Date,
        writerDeviceID: String
    ) throws {
        guard !self.status.isTerminal else { return }
        guard payload.dataEpochID == dataEpochID else {
            throw FocusCloudSyncError.activityWasReset
        }
        payloadData = try JSONEncoder().encode(payload)
        self.status = status
        startedAt = Self.startedAt(payload: payload, fallback: startedAt)
        scheduledEndAt = Self.scheduledEndAt(payload: payload)
        self.updatedAt = updatedAt
        revision += 1
        self.writerDeviceID = writerDeviceID
    }

    func markTerminal(
        _ status: SyncedFocusStatus,
        at date: Date,
        writerDeviceID: String
    ) {
        guard status.isTerminal else { return }
        // Completion and cancellation are immutable tombstones. Conflict
        // resolution across duplicate rows is handled by FocusSyncPolicy.
        guard !self.status.isTerminal else { return }
        self.status = status
        terminalAt = status == .completed ? (scheduledEndAt ?? date) : date
        updatedAt = date
        revision += 1
        self.writerDeviceID = writerDeviceID
    }

    var policySnapshot: FocusSyncRecordSnapshot {
        FocusSyncRecordSnapshot(
            recordID: id,
            sessionID: sessionID,
            status: status,
            startedAt: startedAt,
            scheduledEndAt: scheduledEndAt,
            updatedAt: updatedAt,
            terminalAt: terminalAt,
            revision: revision,
            ownershipSequence: ownershipSequence,
            writerDeviceID: writerDeviceID,
            dataEpochID: dataEpochID
        )
    }

    private static func startedAt(
        payload: FocusCloudPayload,
        fallback: Date
    ) -> Date {
        payload.pendingCompletion?.startedAt
            ?? payload.engine.phaseStartedAt
            ?? fallback
    }

    private static func scheduledEndAt(payload: FocusCloudPayload) -> Date? {
        payload.pendingCompletion?.endedAt ?? payload.engine.endDate
    }
}

/// Ownership is append-only instead of a last-writer-wins property on the
/// timer. Concurrent claims therefore remain visible and converge to the same
/// deterministic owner on every device.
@Model
final class FocusTimerDeviceClaim {
    var id: UUID = UUID()
    var dataEpochID: UUID?
    var sessionID: UUID = UUID()
    var deviceID: String = ""
    var sequence: Int = 0
    var claimedAt: Date = Date(timeIntervalSince1970: 0)
    var releasedAt: Date?

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        deviceID: String,
        sequence: Int,
        claimedAt: Date,
        releasedAt: Date? = nil,
        dataEpochID: UUID? = nil
    ) {
        self.id = id
        self.dataEpochID = dataEpochID
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.sequence = max(0, sequence)
        self.claimedAt = claimedAt
        self.releasedAt = releasedAt
    }

    var policySnapshot: FocusOwnershipClaimSnapshot {
        FocusOwnershipClaimSnapshot(
            id: id,
            sessionID: sessionID,
            deviceID: deviceID,
            sequence: sequence,
            claimedAt: claimedAt,
            releasedAt: releasedAt,
            dataEpochID: dataEpochID
        )
    }
}

struct FocusSyncRecordSnapshot: Equatable, Sendable {
    let recordID: UUID
    let sessionID: UUID
    let status: SyncedFocusStatus
    let startedAt: Date
    let scheduledEndAt: Date?
    let updatedAt: Date
    let terminalAt: Date?
    let revision: Int
    let ownershipSequence: Int
    let writerDeviceID: String
    let dataEpochID: UUID?

    init(
        recordID: UUID,
        sessionID: UUID,
        status: SyncedFocusStatus,
        startedAt: Date,
        scheduledEndAt: Date?,
        updatedAt: Date,
        terminalAt: Date?,
        revision: Int,
        ownershipSequence: Int,
        writerDeviceID: String,
        dataEpochID: UUID? = nil
    ) {
        self.recordID = recordID
        self.sessionID = sessionID
        self.status = status
        self.startedAt = startedAt
        self.scheduledEndAt = scheduledEndAt
        self.updatedAt = updatedAt
        self.terminalAt = terminalAt
        self.revision = revision
        self.ownershipSequence = ownershipSequence
        self.writerDeviceID = writerDeviceID
        self.dataEpochID = dataEpochID
    }
}

struct FocusOwnershipClaimSnapshot: Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let deviceID: String
    let sequence: Int
    let claimedAt: Date
    let releasedAt: Date?
    let dataEpochID: UUID?

    init(
        id: UUID,
        sessionID: UUID,
        deviceID: String,
        sequence: Int,
        claimedAt: Date,
        releasedAt: Date?,
        dataEpochID: UUID? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.sequence = sequence
        self.claimedAt = claimedAt
        self.releasedAt = releasedAt
        self.dataEpochID = dataEpochID
    }
}

enum FocusSyncRecoveryAction: Equatable, Sendable {
    case resumeLocal
    case offerCloudRecovery
    case none
}

enum FocusCompletionMaterializationDecision: Equatable, Sendable {
    case insert
    case alreadyMaterialized
    case rejectedOwnership
}

enum FocusSyncPolicy {
    /// Resolves duplicate CloudKit rows for each logical session, then keeps
    /// the oldest still-active focus. This protects already-invested effort if
    /// two offline devices start different timers before either can sync.
    static func canonicalActive(
        from values: [FocusSyncRecordSnapshot]
    ) -> FocusSyncRecordSnapshot? {
        let resolution = resolveLogicalTimeline(values)
        return resolution.accepted.first(where: { $0.status.isRecoverable })
    }

    /// Logical timers are globally serialized for one iCloud account. If two
    /// offline devices complete overlapping, different UUIDs, the later start
    /// is superseded for ownership/recovery purposes. Its earned StudySession
    /// is still user history and is preserved as self-reported by SeedData.
    static func supersededSessionIDs(
        from values: [FocusSyncRecordSnapshot]
    ) -> Set<UUID> {
        resolveLogicalTimeline(values).superseded
    }

    static func resolveSameSession(
        _ values: [FocusSyncRecordSnapshot]
    ) -> FocusSyncRecordSnapshot? {
        values.reduce(nil as FocusSyncRecordSnapshot?) { winner, candidate in
            guard let winner else { return candidate }
            return preferred(winner, candidate)
        }
    }

    /// One append-only ownership claim wins. Sequence is primary; timestamp
    /// and stable identifiers only break genuinely concurrent ties.
    static func notificationOwner(
        for sessionID: UUID,
        claims: [FocusOwnershipClaimSnapshot]
    ) -> String? {
        claims
            .filter { $0.sessionID == sessionID && $0.releasedAt == nil }
            .max(by: claimIsOrderedBefore)?
            .deviceID
    }

    static func nextOwnershipSequence(
        for sessionID: UUID,
        claims: [FocusOwnershipClaimSnapshot]
    ) -> Int {
        (claims
            .filter { $0.sessionID == sessionID }
            .map(\.sequence)
            .max() ?? -1) + 1
    }

    /// A cloud-discovered timer is never auto-adopted. Only a local envelope
    /// already owned by this device may resume without an explicit prompt.
    static func recoveryAction(
        canonical: FocusSyncRecordSnapshot?,
        localSessionID: UUID?,
        currentDeviceID: String,
        claims: [FocusOwnershipClaimSnapshot]
    ) -> FocusSyncRecoveryAction {
        guard let canonical else { return .none }
        let owner = notificationOwner(for: canonical.sessionID, claims: claims)
        guard canonical.sessionID == localSessionID,
              owner == currentDeviceID else {
            return .offerCloudRecovery
        }
        return .resumeLocal
    }

    /// The same ownership gate is used immediately before materializing a
    /// StudySession. The shared session UUID provides eventual idempotence if
    /// devices complete while partitioned; startup reconciliation removes any
    /// transient duplicate SwiftData rows after CloudKit merges them.
    static func mayMaterializeCompletion(
        sessionID: UUID,
        existingSessionIDs: Set<UUID>,
        currentDeviceID: String,
        claims: [FocusOwnershipClaimSnapshot]
    ) -> Bool {
        completionMaterializationDecision(
            sessionID: sessionID,
            existingSessionIDs: existingSessionIDs,
            currentDeviceID: currentDeviceID,
            claims: claims
        ) == .insert
    }

    /// Separates an idempotent, already-synced completion from a true ownership
    /// rejection. Callers must never erase a pending completion for the latter.
    static func completionMaterializationDecision(
        sessionID: UUID,
        existingSessionIDs: Set<UUID>,
        currentDeviceID: String,
        claims: [FocusOwnershipClaimSnapshot]
    ) -> FocusCompletionMaterializationDecision {
        if existingSessionIDs.contains(sessionID) {
            return .alreadyMaterialized
        }
        guard notificationOwner(for: sessionID, claims: claims) == currentDeviceID else {
            return .rejectedOwnership
        }
        return .insert
    }

    private static func preferred(
        _ lhs: FocusSyncRecordSnapshot,
        _ rhs: FocusSyncRecordSnapshot
    ) -> FocusSyncRecordSnapshot {
        if lhs.ownershipSequence != rhs.ownershipSequence {
            return lhs.ownershipSequence > rhs.ownershipSequence ? lhs : rhs
        }
        let statuses = Set([lhs.status, rhs.status])
        if statuses.contains(.cancelled),
           statuses.contains(.completed) || statuses.contains(.completionPending) {
            let cancellation = lhs.status == .cancelled ? lhs : rhs
            let completion = lhs.status == .cancelled ? rhs : lhs
            let cancelledAt = cancellation.terminalAt ?? cancellation.updatedAt
            let scheduledEnd = completion.scheduledEndAt
                ?? completion.terminalAt
                ?? completion.updatedAt
            // A user cancellation before the scheduled finish wins. A stale or
            // late cancellation cannot erase an already-earned completion.
            return cancelledAt < scheduledEnd ? cancellation : completion
        }

        if lhs.status.isTerminal != rhs.status.isTerminal {
            return lhs.status.isTerminal ? lhs : rhs
        }
        if lhs.revision != rhs.revision {
            return lhs.revision > rhs.revision ? lhs : rhs
        }
        let lhsRank = statusRank(lhs.status)
        let rhsRank = statusRank(rhs.status)
        if lhsRank != rhsRank { return lhsRank > rhsRank ? lhs : rhs }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt ? lhs : rhs
        }
        if lhs.writerDeviceID != rhs.writerDeviceID {
            return lhs.writerDeviceID > rhs.writerDeviceID ? lhs : rhs
        }
        return lhs.recordID.uuidString > rhs.recordID.uuidString ? lhs : rhs
    }

    private static func statusRank(_ status: SyncedFocusStatus) -> Int {
        switch status {
        case .running: 0
        case .paused: 1
        case .completionPending: 2
        case .cancelled: 3
        case .completed: 4
        }
    }

    private static func claimIsOrderedBefore(
        _ lhs: FocusOwnershipClaimSnapshot,
        _ rhs: FocusOwnershipClaimSnapshot
    ) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        if lhs.claimedAt != rhs.claimedAt { return lhs.claimedAt < rhs.claimedAt }
        if lhs.deviceID != rhs.deviceID { return lhs.deviceID < rhs.deviceID }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func terminalBoundary(
        of value: FocusSyncRecordSnapshot
    ) -> Date {
        if value.status == .completed {
            return value.scheduledEndAt ?? value.terminalAt ?? value.updatedAt
        }
        return value.terminalAt ?? value.updatedAt
    }

    private static func occupancyBoundary(
        of value: FocusSyncRecordSnapshot
    ) -> Date {
        if value.status.isTerminal { return terminalBoundary(of: value) }
        return value.scheduledEndAt ?? .distantFuture
    }

    private static func resolveLogicalTimeline(
        _ values: [FocusSyncRecordSnapshot]
    ) -> (accepted: [FocusSyncRecordSnapshot], superseded: Set<UUID>) {
        let resolved = Dictionary(grouping: values, by: \.sessionID)
            .values
            .compactMap(resolveSameSession)
            .sorted { lhs, rhs in
                if lhs.startedAt == rhs.startedAt {
                    return lhs.sessionID.uuidString < rhs.sessionID.uuidString
                }
                return lhs.startedAt < rhs.startedAt
            }

        var occupiedUntil: Date?
        var accepted: [FocusSyncRecordSnapshot] = []
        var superseded = Set<UUID>()
        for candidate in resolved {
            if let occupiedUntil, candidate.startedAt < occupiedUntil {
                superseded.insert(candidate.sessionID)
                continue
            }
            accepted.append(candidate)
            occupiedUntil = occupancyBoundary(of: candidate)
        }
        return (accepted, superseded)
    }
}

enum FocusDeviceIdentity {
    static let defaultsKey = "focus.device-identity.v1"

    static func current(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: defaultsKey)
        return generated
    }
}

@MainActor
enum FocusCloudSyncStore {
    enum QueryContract {
        /// One focus normally produces only a handful of revisions. These
        /// defensive ceilings prevent corrupt/hostile CloudKit history from
        /// allocating an account's lifetime of tombstones on MainActor.
        static let recentTimerRecordLimit = 256
        static let recentOwnershipClaimLimit = 256
        static let matchingSessionRecordLimit = 128
        static let matchingSessionClaimLimit = 128
    }

    static func upsert(
        envelope: FocusRecoveryEnvelope,
        status: SyncedFocusStatus,
        context: ModelContext,
        deviceID: String,
        claimIfUnowned: Bool,
        now: Date = .now
    ) throws -> SyncedFocusTimer {
        let payload = try FocusCloudPayload(envelope: envelope)
        let resetMarkers = try ActivityResetStore.snapshots(context: context)
        guard ActivityResetPolicy.state(
            of: payload.dataEpochID,
            markers: resetMarkers
        ) == .current else {
            throw FocusCloudSyncError.activityWasReset
        }
        guard let sessionID = payload.pendingCompletion?.sessionID
                ?? payload.engine.currentSessionID else {
            throw FocusCloudSyncError.missingSessionID
        }

        let records = try timerRecords(sessionID: sessionID, context: context)
        var claims = try ownershipClaims(sessionID: sessionID, context: context)
            .map(\.policySnapshot)
        var owner = FocusSyncPolicy.notificationOwner(for: sessionID, claims: claims)
        if owner == nil, claimIfUnowned {
            let claim = FocusTimerDeviceClaim(
                sessionID: sessionID,
                deviceID: deviceID,
                sequence: FocusSyncPolicy.nextOwnershipSequence(
                    for: sessionID,
                    claims: claims
                ),
                claimedAt: now,
                dataEpochID: payload.dataEpochID
            )
            context.insert(claim)
            claims.append(claim.policySnapshot)
            owner = deviceID
        }
        if let owner, owner != deviceID {
            throw FocusCloudSyncError.ownershipLost
        }

        if let winner = FocusSyncPolicy.resolveSameSession(records.map(\.policySnapshot)),
           let existing = records.first(where: { $0.id == winner.recordID }),
           existing.writerDeviceID == deviceID,
           now <= existing.updatedAt {
            return existing
        }

        let record = try SyncedFocusTimer(
            sessionID: sessionID,
            status: status,
            payload: payload,
            updatedAt: now,
            revision: (records.map(\.revision).max() ?? 0) + 1,
            ownershipSequence: claims
                .filter { $0.deviceID == deviceID && $0.releasedAt == nil }
                .map(\.sequence)
                .max() ?? 0,
            writerDeviceID: deviceID
        )
        // State changes are append-only. CloudKit therefore preserves both
        // sides of a partitioned pause/cancel/complete race for deterministic
        // reconciliation instead of hiding one behind last-writer-wins.
        context.insert(record)
        return record
    }

    @discardableResult
    static func claimOwnership(
        sessionID: UUID,
        context: ModelContext,
        deviceID: String,
        now: Date = .now
    ) throws -> FocusTimerDeviceClaim {
        let resetMarkers = try ActivityResetStore.snapshots(context: context)
        let currentEpochID = ActivityResetPolicy.currentEpochID(from: resetMarkers)
        let claims = try ownershipClaims(sessionID: sessionID, context: context)
        let snapshots = claims.map(\.policySnapshot)
        if FocusSyncPolicy.notificationOwner(for: sessionID, claims: snapshots) == deviceID,
           let current = claims.first(where: {
               $0.deviceID == deviceID && $0.releasedAt == nil
           }) {
            return current
        }

        let claim = FocusTimerDeviceClaim(
            sessionID: sessionID,
            deviceID: deviceID,
            sequence: FocusSyncPolicy.nextOwnershipSequence(
                for: sessionID,
                claims: snapshots
            ),
            claimedAt: now,
            dataEpochID: currentEpochID
        )
        context.insert(claim)
        return claim
    }

    static func markTerminal(
        sessionID: UUID,
        status: SyncedFocusStatus,
        context: ModelContext,
        deviceID: String,
        at date: Date = .now,
        enforceOwnership: Bool = true
    ) throws {
        guard status.isTerminal else { return }
        let records = try timerRecords(sessionID: sessionID, context: context)
        guard let winner = FocusSyncPolicy.resolveSameSession(records.map(\.policySnapshot)),
              let source = records.first(where: { $0.id == winner.recordID })
        else {
            // A cancellation is only durable when it can be appended to the
            // same logical CloudKit history. Silently succeeding here lets the
            // caller discard local recovery while a delayed running row can
            // still arrive and revive the focus on another device.
            throw FocusCloudSyncError.missingTimerRecord
        }
        let claims = try ownershipClaims(sessionID: sessionID, context: context)
            .map(\.policySnapshot)
        let owner = FocusSyncPolicy.notificationOwner(for: sessionID, claims: claims)
        if enforceOwnership, let owner, owner != deviceID {
            throw FocusCloudSyncError.ownershipLost
        }
        let ownerSequence: Int
        if enforceOwnership {
            ownerSequence = claims
                .filter { $0.deviceID == deviceID && $0.releasedAt == nil }
                .map(\.sequence)
                .max() ?? winner.ownershipSequence
        } else {
            ownerSequence = max(
                winner.ownershipSequence + 1,
                (claims.map(\.sequence).max() ?? -1) + 1
            )
        }
        if winner.status == status,
           winner.ownershipSequence >= ownerSequence { return }
        let terminal = try SyncedFocusTimer(
            sessionID: sessionID,
            status: status,
            payload: source.decodedPayload(),
            updatedAt: date,
            revision: (records.map(\.revision).max() ?? 0) + 1,
            ownershipSequence: ownerSequence,
            writerDeviceID: deviceID
        )
        context.insert(terminal)
    }

    static func isNotificationOwner(
        sessionID: UUID,
        context: ModelContext,
        deviceID: String
    ) throws -> Bool {
        let claims = try ownershipClaims(sessionID: sessionID, context: context)
        return FocusSyncPolicy.notificationOwner(
            for: sessionID,
            claims: claims.map(\.policySnapshot)
        ) == deviceID
    }

    static func canonicalActive(
        context: ModelContext
    ) throws -> SyncedFocusTimer? {
        let records = try currentTimerRecords(context: context)
        guard let winner = FocusSyncPolicy.canonicalActive(
            from: records.map(\.policySnapshot)
        ) else { return nil }
        return records.first { $0.id == winner.recordID }
    }

    /// Tombstones every visible non-canonical active row. The pure policy also
    /// suppresses a loser that arrives only after the winner is terminal; this
    /// mutation keeps the CloudKit dataset compact and explicit once observed.
    @discardableResult
    static func reconcileActiveTimers(
        context: ModelContext,
        deviceID: String,
        now: Date = .now
    ) throws -> SyncedFocusTimer? {
        let records = try currentTimerRecords(context: context)
        let canonical = FocusSyncPolicy.canonicalActive(
            from: records.map(\.policySnapshot)
        )
        let logicalRecords = Dictionary(grouping: records.map(\.policySnapshot), by: \.sessionID)
            .values
            .compactMap(FocusSyncPolicy.resolveSameSession)
        let losingSessionIDs = Set(logicalRecords.lazy
            .filter { $0.status.isRecoverable }
            .map(\.sessionID))
            .subtracting(canonical.map { [$0.sessionID] } ?? [])
        for sessionID in losingSessionIDs {
            try markTerminal(
                sessionID: sessionID,
                status: .cancelled,
                context: context,
                deviceID: deviceID,
                at: now,
                enforceOwnership: false
            )
        }
        return canonical.flatMap { winner in
            records.first { $0.id == winner.recordID }
        }
    }

    static func allClaims(context: ModelContext) throws -> [FocusTimerDeviceClaim] {
        try currentOwnershipClaims(context: context)
    }

    static func claims(
        sessionID: UUID,
        context: ModelContext
    ) throws -> [FocusTimerDeviceClaim] {
        try ownershipClaims(sessionID: sessionID, context: context)
    }

    private static func timerRecords(
        sessionID: UUID,
        context: ModelContext
    ) throws -> [SyncedFocusTimer] {
        let targetID = sessionID
        let currentEpochID = try ActivityResetStore.latestEpochID(context: context)
        var descriptor: FetchDescriptor<SyncedFocusTimer>
        if let currentEpochID {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == targetID && $0.dataEpochID == currentEpochID
                },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.id, order: .reverse)
                ]
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == targetID && $0.dataEpochID == nil
                },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.id, order: .reverse)
                ]
            )
        }
        descriptor.fetchLimit = QueryContract.matchingSessionRecordLimit
        return try context.fetch(descriptor)
    }

    private static func currentTimerRecords(
        context: ModelContext
    ) throws -> [SyncedFocusTimer] {
        let currentEpochID = try ActivityResetStore.latestEpochID(context: context)
        var descriptor: FetchDescriptor<SyncedFocusTimer>
        if let currentEpochID {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.dataEpochID == currentEpochID },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse)
                ]
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.dataEpochID == nil },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse)
                ]
            )
        }
        descriptor.fetchLimit = QueryContract.recentTimerRecordLimit
        return try context.fetch(descriptor)
    }

    private static func currentOwnershipClaims(
        context: ModelContext
    ) throws -> [FocusTimerDeviceClaim] {
        let currentEpochID = try ActivityResetStore.latestEpochID(context: context)
        var descriptor: FetchDescriptor<FocusTimerDeviceClaim>
        if let currentEpochID {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.dataEpochID == currentEpochID },
                sortBy: [
                    SortDescriptor(\FocusTimerDeviceClaim.claimedAt, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.sequence, order: .reverse)
                ]
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.dataEpochID == nil },
                sortBy: [
                    SortDescriptor(\FocusTimerDeviceClaim.claimedAt, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.sequence, order: .reverse)
                ]
            )
        }
        descriptor.fetchLimit = QueryContract.recentOwnershipClaimLimit
        return try context.fetch(descriptor)
    }

    private static func ownershipClaims(
        sessionID: UUID,
        context: ModelContext
    ) throws -> [FocusTimerDeviceClaim] {
        let targetID = sessionID
        let currentEpochID = try ActivityResetStore.latestEpochID(context: context)
        var descriptor: FetchDescriptor<FocusTimerDeviceClaim>
        if let currentEpochID {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == targetID && $0.dataEpochID == currentEpochID
                },
                sortBy: [
                    SortDescriptor(\FocusTimerDeviceClaim.sequence, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.claimedAt, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.id, order: .reverse)
                ]
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == targetID && $0.dataEpochID == nil
                },
                sortBy: [
                    SortDescriptor(\FocusTimerDeviceClaim.sequence, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.claimedAt, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.id, order: .reverse)
                ]
            )
        }
        descriptor.fetchLimit = QueryContract.matchingSessionClaimLimit
        return try context.fetch(descriptor)
    }
}
