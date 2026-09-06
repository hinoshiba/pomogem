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
        let engineSessionID = envelope.engine.currentSessionID
        let completionSessionID = envelope.pendingCompletion?.sessionID
        guard engineSessionID != nil || completionSessionID != nil else {
            throw FocusCloudSyncError.missingSessionID
        }
        if let engineSessionID, let completionSessionID,
           engineSessionID != completionSessionID {
            throw FocusCloudSyncError.invalidPayload
        }
        guard (envelope.pendingCompletion?.startedAt
                ?? envelope.engine.phaseStartedAt) != nil else {
            throw FocusCloudSyncError.invalidPayload
        }

        version = Self.currentVersion
        engine = envelope.engine
        self.subject = subject
        pendingCompletion = envelope.pendingCompletion?.portableCopy
        savedAt = envelope.savedAt
        dataEpochID = envelope.dataEpochID
    }

    func validatedSessionID() throws -> UUID {
        let engineSessionID = engine.currentSessionID
        let completionSessionID = pendingCompletion?.sessionID
        guard let sessionID = completionSessionID ?? engineSessionID else {
            throw FocusCloudSyncError.invalidPayload
        }
        if let engineSessionID, let completionSessionID,
           engineSessionID != completionSessionID {
            throw FocusCloudSyncError.invalidPayload
        }
        return sessionID
    }

    var indexedStartedAt: Date? {
        pendingCompletion?.startedAt ?? engine.phaseStartedAt
    }

    var indexedScheduledEndAt: Date? {
        pendingCompletion?.endedAt ?? engine.endDate
    }

    func isCompatible(with status: SyncedFocusStatus) -> Bool {
        guard PomodoroEngine.isSafePersistedDate(savedAt) else { return false }
        switch status {
        case .running:
            return pendingCompletion == nil
                && engine.hasValidRunningFocusPayloadState
        case .paused:
            return pendingCompletion == nil
                && engine.hasValidPausedFocusPayloadState
        case .completionPending, .completed:
            return hasValidPendingCompletion
        case .cancelled:
            // Cancellation may race either an active payload or a completion
            // that had not yet been materialized.
            return engine.hasValidRunningFocusPayloadState
                || engine.hasValidPausedFocusPayloadState
                || (pendingCompletion != nil && hasValidPendingCompletion)
        }
    }

    /// Completion fields are persisted into StudySession and therefore cannot
    /// be trusted merely because JSON decoding succeeded. Validate the frozen
    /// award against the selected duration and the engine state that produced
    /// it. A legacy payload may have cleared `currentSessionID`; in that case
    /// the self-contained completion invariants still provide a safe migration
    /// path for pre-release recovery bytes.
    private var hasValidPendingCompletion: Bool {
        guard let completion = pendingCompletion else { return false }
        return engine.hasValidPersistedCompletion(completion)
    }

    /// A non-owner may publish only the completion witness derived from its
    /// own earlier recoverable revision. This is needed when CloudKit delivers
    /// a foreign handoff plus a cancellation after the scheduled finish before
    /// it delivers this device's already-earned completion.
    func isCompletionSuccessor(of ancestor: FocusCloudPayload) -> Bool {
        guard hasValidPendingCompletion,
              let completion = pendingCompletion,
              (try? validatedSessionID()) == (try? ancestor.validatedSessionID()),
              dataEpochID == ancestor.dataEpochID,
              subject == ancestor.subject,
              ancestor.indexedStartedAt == completion.startedAt,
              ancestor.indexedScheduledEndAt == completion.endedAt,
              ancestor.engine.selectedDuration.normalized
                == completion.duration.normalized,
              ancestor.engine.currentSource == completion.source
        else { return false }
        return true
    }

    func hasSameSynchronizedState(as other: FocusCloudPayload) -> Bool {
        version == other.version
            && engine == other.engine
            && subject == other.subject
            && pendingCompletion == other.pendingCompletion
            && dataEpochID == other.dataEpochID
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
    case timerAlreadyTerminal
    case timerHistoryRequiresMaintenance
    case ownershipSequenceExhausted
    case recoveryOfferChanged
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
            "保存領域のタイマー情報を読み取れませんでした。"
        case .ownershipLost:
            "このタイマーは別の端末へ引き継がれています。"
        case .timerAlreadyTerminal:
            "このタイマーはすでに完了または終了しています。"
        case .timerHistoryRequiresMaintenance:
            "タイマーの同期履歴を整理してから、もう一度お試しください。"
        case .ownershipSequenceExhausted:
            "タイマーの引き継ぎ履歴が上限に達しました。サポートへお問い合わせください。"
        case .recoveryOfferChanged:
            "表示後にタイマーの状態が変わりました。最新状態を確認してください。"
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
        guard try payload.validatedSessionID() == sessionID else {
            throw FocusCloudSyncError.invalidPayload
        }
        guard let indexedStartedAt = payload.indexedStartedAt else {
            throw FocusCloudSyncError.invalidPayload
        }
        guard payload.isCompatible(with: status) else {
            throw FocusCloudSyncError.invalidPayload
        }
        guard !writerDeviceID.isEmpty else {
            throw FocusCloudSyncError.invalidPayload
        }
        self.id = id
        dataEpochID = payload.dataEpochID
        self.sessionID = sessionID
        statusRaw = status.rawValue
        payloadData = try JSONEncoder().encode(payload)
        startedAt = indexedStartedAt
        scheduledEndAt = payload.indexedScheduledEndAt
        self.updatedAt = updatedAt
        self.revision = min(
            max(1, revision),
            FocusSyncPolicy.maximumSupportedRevision
        )
        self.ownershipSequence = min(
            max(0, ownershipSequence),
            FocusSyncPolicy.maximumSupportedOwnershipSequence
        )
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
        guard let status = SyncedFocusStatus(rawValue: statusRaw),
              let payload = try? JSONDecoder().decode(
            FocusCloudPayload.self,
            from: payloadData
        ), (1 ... FocusCloudPayload.currentVersion).contains(payload.version),
        payload.dataEpochID == dataEpochID,
        (try? payload.validatedSessionID()) == sessionID,
        payload.indexedStartedAt == startedAt,
        payload.indexedScheduledEndAt == scheduledEndAt,
        payload.isCompatible(with: status),
        (1 ... FocusSyncPolicy.maximumSupportedRevision).contains(revision),
        (0 ... FocusSyncPolicy.maximumSupportedOwnershipSequence)
            .contains(ownershipSequence),
        !writerDeviceID.isEmpty,
        terminalMetadataIsValid(for: status) else {
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
        guard try payload.validatedSessionID() == sessionID else {
            throw FocusCloudSyncError.invalidPayload
        }
        guard let indexedStartedAt = payload.indexedStartedAt else {
            throw FocusCloudSyncError.invalidPayload
        }
        guard payload.isCompatible(with: status) else {
            throw FocusCloudSyncError.invalidPayload
        }
        guard !writerDeviceID.isEmpty else {
            throw FocusCloudSyncError.invalidPayload
        }
        payloadData = try JSONEncoder().encode(payload)
        self.status = status
        startedAt = indexedStartedAt
        scheduledEndAt = payload.indexedScheduledEndAt
        self.updatedAt = updatedAt
        revision = revision >= FocusSyncPolicy.maximumSupportedRevision
            ? FocusSyncPolicy.maximumSupportedRevision
            : max(1, revision) + 1
        self.writerDeviceID = writerDeviceID
    }

    func markTerminal(
        _ status: SyncedFocusStatus,
        at date: Date,
        writerDeviceID: String
    ) {
        guard status.isTerminal else { return }
        guard !writerDeviceID.isEmpty else { return }
        // Completion and cancellation are immutable tombstones. Conflict
        // resolution across duplicate rows is handled by FocusSyncPolicy.
        guard !self.status.isTerminal else { return }
        self.status = status
        terminalAt = status == .completed ? (scheduledEndAt ?? date) : date
        updatedAt = date
        revision = revision >= FocusSyncPolicy.maximumSupportedRevision
            ? FocusSyncPolicy.maximumSupportedRevision
            : max(1, revision) + 1
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

    private func terminalMetadataIsValid(
        for status: SyncedFocusStatus
    ) -> Bool {
        switch status {
        case .running, .paused, .completionPending:
            terminalAt == nil
        case .completed:
            terminalAt == (scheduledEndAt ?? updatedAt)
        case .cancelled:
            terminalAt == updatedAt
        }
    }
}

/// Ownership is append-only instead of a last-writer-wins property on the
/// timer. Concurrent claims therefore remain visible and converge to the same
/// deterministic owner on every device.
@Model
final class FocusTimerDeviceClaim {
    var id: UUID = UUID()
    /// Immutable physical-copy identity synchronized through CloudKit. The
    /// append event's logical identity remains `id`; maintenance never uses
    /// this field to destructively discard another source row.
    var syncRecordID: UUID = UUID()
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
        dataEpochID: UUID? = nil,
        syncRecordID: UUID = UUID()
    ) {
        self.id = id
        self.syncRecordID = syncRecordID
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
            syncRecordID: syncRecordID,
            sessionID: sessionID,
            deviceID: deviceID,
            sequence: sequence,
            claimedAt: claimedAt,
            releasedAt: releasedAt,
            dataEpochID: dataEpochID
        )
    }
}

struct FocusSyncRecordSnapshot: Equatable, Hashable, Sendable {
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
    let syncRecordID: UUID
    let sessionID: UUID
    let deviceID: String
    let sequence: Int
    let claimedAt: Date
    let releasedAt: Date?
    let dataEpochID: UUID?

    init(
        id: UUID,
        syncRecordID: UUID? = nil,
        sessionID: UUID,
        deviceID: String,
        sequence: Int,
        claimedAt: Date,
        releasedAt: Date?,
        dataEpochID: UUID? = nil
    ) {
        self.id = id
        self.syncRecordID = syncRecordID ?? id
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

enum FocusCompletionGate: Equatable, Sendable {
    case open
    case cancelledBeforeCompletion
    case completedAwaitingSession
    case materialized
}

enum FocusSyncPolicy {
    static let maximumSupportedRevision = 1_000_000
    static let maximumSupportedOwnershipSequence = 1_000_000

    /// Resolves duplicate CloudKit rows for each logical session, then keeps
    /// the oldest still-active focus. This protects already-invested effort if
    /// two offline devices start different timers before either can sync.
    static func canonicalActive(
        from values: [FocusSyncRecordSnapshot]
    ) -> FocusSyncRecordSnapshot? {
        logicalSessionWinners(values)
            .filter { $0.status.isRecoverable }
            .min(by: activeTimerIsOrderedBefore)
    }

    /// Logical *active recovery* is serialized for one iCloud account. If two
    /// offline devices start overlapping timers, the later start is superseded
    /// only for notification and recovery UI. Distinct completion UUIDs remain
    /// measured StudySessions; SeedData deliberately does not retroactively
    /// demote either completion after CloudKit delivery.
    static func supersededSessionIDs(
        from values: [FocusSyncRecordSnapshot]
    ) -> Set<UUID> {
        let active = logicalSessionWinners(values)
            .filter { $0.status.isRecoverable }
            .sorted(by: activeTimerIsOrderedBefore)
        return Set(active.dropFirst().map(\.sessionID))
    }

    static func resolveSameSession(
        _ values: [FocusSyncRecordSnapshot]
    ) -> FocusSyncRecordSnapshot? {
        guard !values.isEmpty else { return nil }

        // Resolve the semantic terminal race as a set, rather than through a
        // pairwise reduce. The old pairwise comparator was not transitive when
        // running, completion-pending, and cancellation rows were all present,
        // so CloudKit delivery order could change the winner.
        let completion = preferredCompletion(in: values)
        let cancellation = earliestCancellation(in: values)

        if let completion, let cancellation {
            // A completed row is written atomically with the StudySession. The
            // materialized completion is irreversible; a delayed cancellation
            // must never leave a counted StudySession paired with a cancelled
            // timer. Only completion-pending still participates in the
            // before/after-scheduled-end race.
            if completion.status == .completed { return completion }
            let cancelledAt = terminalBoundary(of: cancellation)
            let scheduledEnd = completion.scheduledEndAt
                ?? completion.terminalAt
                ?? completion.updatedAt
            // Cancellation before the scheduled finish wins. At or after the
            // finish, the already-earned completion remains authoritative.
            return cancelledAt < scheduledEnd ? cancellation : completion
        }
        if let completion { return completion }
        if let cancellation { return cancellation }

        return values.reduce(nil as FocusSyncRecordSnapshot?) { winner, candidate in
            guard let winner else { return candidate }
            return preferredVersion(winner, candidate)
        }
    }

    /// Minimal witnesses for pure resolution proofs and legacy tests only.
    /// They are never authority to delete or rewrite CloudKit source rows: a
    /// future partial delivery can still contain information not represented by
    /// the currently observed set.
    static func compactionWitnesses(
        from values: [FocusSyncRecordSnapshot]
    ) -> [FocusSyncRecordSnapshot] {
        let completed = values
            .filter({ $0.status == .completed })
            .reduce(nil as FocusSyncRecordSnapshot?) { winner, candidate in
                guard let winner else { return candidate }
                return preferredVersion(winner, candidate)
            }
        if let completed {
            return [completed]
        }

        let completion = preferredCompletion(in: values)
        let cancellation = earliestCancellation(in: values)
        let witnesses = [completion, cancellation].compactMap { $0 }
        if !witnesses.isEmpty { return witnesses }
        return resolveSameSession(values).map { [$0] } ?? []
    }

    /// One append-only ownership claim wins. Sequence is primary; timestamp
    /// and stable identifiers only break genuinely concurrent ties.
    static func notificationOwner(
        for sessionID: UUID,
        claims: [FocusOwnershipClaimSnapshot]
    ) -> String? {
        notificationOwnerClaim(for: sessionID, claims: claims)?.deviceID
    }

    static func notificationOwnerClaim(
        for sessionID: UUID,
        claims: [FocusOwnershipClaimSnapshot]
    ) -> FocusOwnershipClaimSnapshot? {
        logicalActiveOwnershipClaims(claims)
            .filter {
                $0.sessionID == sessionID
                    && (0 ... maximumSupportedOwnershipSequence).contains($0.sequence)
            }
            .max(by: claimIsOrderedBefore)
    }

    static func nextOwnershipSequence(
        for sessionID: UUID,
        claims: [FocusOwnershipClaimSnapshot]
    ) -> Int {
        let maximum = claims
            .filter {
                $0.sessionID == sessionID
                    && (0 ... maximumSupportedOwnershipSequence).contains($0.sequence)
            }
            .map(\.sequence)
            .max() ?? -1
        return maximum >= maximumSupportedOwnershipSequence
            ? maximumSupportedOwnershipSequence
            : maximum + 1
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
    /// devices complete while partitioned; startup reads resolve transient
    /// duplicate SwiftData rows logically without deleting source evidence.
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

    private static func preferredVersion(
        _ lhs: FocusSyncRecordSnapshot,
        _ rhs: FocusSyncRecordSnapshot
    ) -> FocusSyncRecordSnapshot {
        if lhs.ownershipSequence != rhs.ownershipSequence {
            return lhs.ownershipSequence > rhs.ownershipSequence ? lhs : rhs
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

    private static func preferredCompletion(
        in values: [FocusSyncRecordSnapshot]
    ) -> FocusSyncRecordSnapshot? {
        values
            .filter { $0.status == .completed || $0.status == .completionPending }
            .reduce(nil as FocusSyncRecordSnapshot?) { winner, candidate in
                guard let winner else { return candidate }
                if winner.status != candidate.status {
                    return winner.status == .completed ? winner : candidate
                }
                return preferredVersion(winner, candidate)
            }
    }

    private static func earliestCancellation(
        in values: [FocusSyncRecordSnapshot]
    ) -> FocusSyncRecordSnapshot? {
        values
            .filter { $0.status == .cancelled }
            .reduce(nil as FocusSyncRecordSnapshot?) { winner, candidate in
                guard let winner else { return candidate }
                let winnerDate = terminalBoundary(of: winner)
                let candidateDate = terminalBoundary(of: candidate)
                if winnerDate != candidateDate {
                    return winnerDate < candidateDate ? winner : candidate
                }
                return preferredVersion(winner, candidate)
            }
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
        if lhs.sessionID != rhs.sessionID {
            return lhs.sessionID.uuidString < rhs.sessionID.uuidString
        }
        if lhs.id != rhs.id { return lhs.id.uuidString < rhs.id.uuidString }
        return lhs.syncRecordID.uuidString < rhs.syncRecordID.uuidString
    }

    /// Physical CloudKit duplicates share one application-level claim ID. A
    /// release is an append-event tombstone: if any copy carries it, an older
    /// unreleased copy must never revive ownership during logical resolution.
    /// Maintenance retains every physical source copy.
    private static func logicalActiveOwnershipClaims(
        _ claims: [FocusOwnershipClaimSnapshot]
    ) -> [FocusOwnershipClaimSnapshot] {
        let validClaims = claims.filter {
            !$0.deviceID.isEmpty
                && (0 ... maximumSupportedOwnershipSequence).contains($0.sequence)
        }
        return Dictionary(grouping: validClaims, by: \.id).values.compactMap { copies in
            guard copies.allSatisfy({ $0.releasedAt == nil }) else {
                return nil
            }
            return copies.max(by: claimIsOrderedBefore)
        }
    }

    private static func terminalBoundary(
        of value: FocusSyncRecordSnapshot
    ) -> Date {
        if value.status == .completed {
            return value.scheduledEndAt ?? value.terminalAt ?? value.updatedAt
        }
        return value.terminalAt ?? value.updatedAt
    }

    private static func logicalSessionWinners(
        _ values: [FocusSyncRecordSnapshot]
    ) -> [FocusSyncRecordSnapshot] {
        Dictionary(grouping: values, by: \.sessionID)
            .values
            .compactMap(resolveSameSession)
    }

    private static func activeTimerIsOrderedBefore(
        _ lhs: FocusSyncRecordSnapshot,
        _ rhs: FocusSyncRecordSnapshot
    ) -> Bool {
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt < rhs.startedAt
        }
        return lhs.sessionID.uuidString < rhs.sessionID.uuidString
    }
}

enum FocusDeviceIdentity {
    static let defaultsKey = "focus.device-identity.v1"

    static func current(defaults: UserDefaults = .standard) -> String {
        let scopedKey = AccountScopedLocalState.defaultsKey(
            base: defaultsKey,
            defaults: defaults
        )
        if let existing = defaults.string(forKey: scopedKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: scopedKey)
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
        static let logicalTimerScanLimit = 256
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
        let sessionID = try payload.validatedSessionID()
        var admitsForeignCompletionWitness = false
        if status == .completionPending {
            // A cancellation can arrive before the portable completion under
            // CloudKit partitioning. Compare it with the candidate's frozen
            // scheduled end; treating every cancellation as already closed
            // would make delivery order erase an earned completion.
            if try hasMaterializedStudySession(
                sessionID: sessionID,
                context: context
            ) || (try completedTimerRecord(
                sessionID: sessionID,
                context: context
            )) != nil {
                throw FocusCloudSyncError.timerAlreadyTerminal
            }
            if let cancellation = try cancellationTimerRecord(
                sessionID: sessionID,
                context: context
            ) {
                guard let scheduledEnd = payload.indexedScheduledEndAt else {
                    throw FocusCloudSyncError.invalidPayload
                }
                let cancelledAt = cancellation.terminalAt
                    ?? cancellation.updatedAt
                if cancelledAt < scheduledEnd {
                    throw FocusCloudSyncError.timerAlreadyTerminal
                }
                admitsForeignCompletionWitness = true
            }
        } else if status.isRecoverable,
                  try isSessionClosed(
                    sessionID: sessionID,
                    context: context
                  ) {
            throw FocusCloudSyncError.timerAlreadyTerminal
        }

        let records = try timerRecords(sessionID: sessionID, context: context)
        var ownerClaim = try activeOwnershipClaim(
            sessionID: sessionID,
            context: context
        )
        if ownerClaim == nil, claimIfUnowned {
            let claim = FocusTimerDeviceClaim(
                sessionID: sessionID,
                deviceID: deviceID,
                sequence: try nextOwnershipSequence(
                    sessionID: sessionID,
                    context: context
                ),
                claimedAt: now,
                dataEpochID: payload.dataEpochID
            )
            context.insert(claim)
            ownerClaim = claim
        }
        let recordOwnershipSequence: Int
        if let ownerClaim, ownerClaim.deviceID != deviceID {
            guard admitsForeignCompletionWitness,
                  let lineage = try completionWitnessLineageRecord(
                    for: payload,
                    writerDeviceID: deviceID,
                    in: records
                  ) else {
                throw FocusCloudSyncError.ownershipLost
            }
            // Never borrow the foreign winner's claim sequence: the row is
            // evidence for deterministic completion/cancellation resolution,
            // not a transfer of notification or materialization ownership.
            recordOwnershipSequence = lineage.ownershipSequence
        } else {
            recordOwnershipSequence = ownerClaim?.sequence ?? 0
        }

        if let winner = FocusSyncPolicy.resolveSameSession(records.map(\.policySnapshot)),
           let existing = try storedTimerRecord(matching: winner, in: records),
           existing.writerDeviceID == deviceID,
           existing.status == status,
           try existing.decodedPayload().hasSameSynchronizedState(as: payload) {
            return existing
        }

        let record = try SyncedFocusTimer(
            sessionID: sessionID,
            status: status,
            payload: payload,
            updatedAt: now,
            revision: nextRevision(after: records.map(\.revision).max()),
            ownershipSequence: recordOwnershipSequence,
            writerDeviceID: deviceID
        )
        // State changes are append-only. CloudKit therefore preserves both
        // sides of a partitioned pause/cancel/complete race for deterministic
        // reconciliation instead of hiding one behind last-writer-wins.
        context.insert(record)
        return record
    }

    private static func completionWitnessLineageRecord(
        for payload: FocusCloudPayload,
        writerDeviceID: String,
        in records: [SyncedFocusTimer]
    ) throws -> SyncedFocusTimer? {
        var candidates: [SyncedFocusTimer] = []
        for record in records where record.writerDeviceID == writerDeviceID
            && record.status.isRecoverable {
            let ancestor = try record.decodedPayload()
            if payload.isCompletionSuccessor(of: ancestor) {
                candidates.append(record)
            }
        }
        return candidates.max { lhs, rhs in
            if lhs.ownershipSequence != rhs.ownershipSequence {
                return lhs.ownershipSequence < rhs.ownershipSequence
            }
            if lhs.revision != rhs.revision {
                return lhs.revision < rhs.revision
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    @discardableResult
    static func claimOwnership(
        sessionID: UUID,
        context: ModelContext,
        deviceID: String,
        expectedRecordID: UUID? = nil,
        expectedRevision: Int? = nil,
        expectedOwnershipSequence: Int? = nil,
        now: Date = .now
    ) throws -> FocusTimerDeviceClaim {
        let resetMarkers = try ActivityResetStore.snapshots(context: context)
        let currentEpochID = ActivityResetPolicy.currentEpochID(from: resetMarkers)
        guard try !isSessionClosed(sessionID: sessionID, context: context) else {
            throw FocusCloudSyncError.timerAlreadyTerminal
        }
        let records = try timerRecords(sessionID: sessionID, context: context)
        guard let winner = FocusSyncPolicy.resolveSameSession(
            records.map(\.policySnapshot)
        ), winner.status.isRecoverable else {
            throw FocusCloudSyncError.missingTimerRecord
        }
        if let expectedRecordID,
           winner.recordID != expectedRecordID
            || expectedRevision.map({ winner.revision != $0 }) == true
            || expectedOwnershipSequence.map({ winner.ownershipSequence != $0 }) == true {
            throw FocusCloudSyncError.recoveryOfferChanged
        }
        if let current = try activeOwnershipClaim(
            sessionID: sessionID,
            context: context
        ), current.deviceID == deviceID {
            return current
        }

        let claim = FocusTimerDeviceClaim(
            sessionID: sessionID,
            deviceID: deviceID,
            sequence: try nextOwnershipSequence(
                sessionID: sessionID,
                context: context
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
        if let existingTerminal = try terminalTimerRecord(
            sessionID: sessionID,
            context: context
        ), existingTerminal.status == status
            || existingTerminal.status == .completed
            || status == .cancelled {
            return
        }
        let records = try timerRecords(sessionID: sessionID, context: context)
        guard let winner = FocusSyncPolicy.resolveSameSession(records.map(\.policySnapshot)),
              let source = try storedTimerRecord(matching: winner, in: records)
        else {
            // A cancellation is only durable when it can be appended to the
            // same logical CloudKit history. Silently succeeding here lets the
            // caller discard local recovery while a delayed running row can
            // still arrive and revive the focus on another device.
            throw FocusCloudSyncError.missingTimerRecord
        }
        let ownerClaim = try activeOwnershipClaim(
            sessionID: sessionID,
            context: context
        )
        if enforceOwnership, let ownerClaim, ownerClaim.deviceID != deviceID {
            throw FocusCloudSyncError.ownershipLost
        }
        let ownerSequence: Int
        if enforceOwnership {
            ownerSequence = ownerClaim?.sequence ?? winner.ownershipSequence
        } else {
            let winnerSuccessor = winner.ownershipSequence
                >= FocusSyncPolicy.maximumSupportedOwnershipSequence
                ? FocusSyncPolicy.maximumSupportedOwnershipSequence
                : max(0, winner.ownershipSequence) + 1
            ownerSequence = max(
                winnerSuccessor,
                try nextOwnershipSequence(
                    sessionID: sessionID,
                    context: context
                )
            )
        }
        if winner.status == status,
           winner.ownershipSequence >= ownerSequence { return }
        let terminal = try SyncedFocusTimer(
            sessionID: sessionID,
            status: status,
            payload: source.decodedPayload(),
            updatedAt: date,
            revision: nextRevision(after: records.map(\.revision).max()),
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
        try notificationOwner(
            sessionID: sessionID,
            context: context
        ) == deviceID
    }

    static func notificationOwner(
        sessionID: UUID,
        context: ModelContext
    ) throws -> String? {
        try activeOwnershipClaim(
            sessionID: sessionID,
            context: context
        )?.deviceID
    }

    static func canonicalActive(
        context: ModelContext
    ) throws -> SyncedFocusTimer? {
        try oldestOpenTimer(context: context)
    }

    /// Selects one visible timer without destructively cancelling other logical
    /// sessions. CloudKit delivery is incremental: a timer that looks secondary
    /// now can become the correct next recovery after an earlier session closes
    /// or an older row arrives. Duplicate revisions of the *same* session are
    /// resolved in memory and retained as physical CloudKit source evidence.
    @discardableResult
    static func reconcileActiveTimers(
        context: ModelContext,
        deviceID: String,
        now: Date = .now
    ) throws -> SyncedFocusTimer? {
        _ = deviceID
        _ = now
        return try oldestOpenTimer(context: context)
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

    /// A materialized StudySession or any terminal timer tombstone closes the
    /// logical focus ID. These exact one-row sentinels run before bounded
    /// revision fetches so 129 delayed active revisions cannot push an older
    /// completion out of an interactive query and revive it.
    static func isSessionClosed(
        sessionID: UUID,
        context: ModelContext
    ) throws -> Bool {
        try completionGate(sessionID: sessionID, context: context) != .open
    }

    static func completionGate(
        sessionID: UUID,
        context: ModelContext
    ) throws -> FocusCompletionGate {
        if try hasMaterializedStudySession(sessionID: sessionID, context: context) {
            return .materialized
        }
        if try completedTimerRecord(sessionID: sessionID, context: context) != nil {
            return .completedAwaitingSession
        }
        guard let cancellation = try cancellationTimerRecord(
            sessionID: sessionID,
            context: context
        ) else { return .open }
        guard let pending = try preferredPendingCompletionRecord(
            sessionID: sessionID,
            context: context
        ) else { return .cancelledBeforeCompletion }
        let cancelledAt = cancellation.terminalAt ?? cancellation.updatedAt
        let scheduledEnd = pending.scheduledEndAt
            ?? pending.terminalAt
            ?? pending.updatedAt
        return cancelledAt < scheduledEnd ? .cancelledBeforeCompletion : .open
    }

    private static func hasMaterializedStudySession(
        sessionID: UUID,
        context: ModelContext
    ) throws -> Bool {
        let targetID = sessionID
        let currentEpochID = try ActivityResetStore.latestEpochID(context: context)
        var descriptor: FetchDescriptor<StudySession>
        if let currentEpochID {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.id == targetID && $0.dataEpochID == currentEpochID
                }
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.id == targetID && $0.dataEpochID == nil
                }
            )
        }
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).contains {
            StudySessionIntegrityPolicy.isSupported($0)
        }
    }

    private static func terminalTimerRecord(
        sessionID: UUID,
        context: ModelContext
    ) throws -> SyncedFocusTimer? {
        if let completed = try completedTimerRecord(
            sessionID: sessionID,
            context: context
        ) {
            return completed
        }
        return try cancellationTimerRecord(sessionID: sessionID, context: context)
    }

    private static func completedTimerRecord(
        sessionID: UUID,
        context: ModelContext
    ) throws -> SyncedFocusTimer? {
        let targetID = sessionID
        let completed = SyncedFocusStatus.completed.rawValue
        let currentEpochID = try ActivityResetStore.latestEpochID(context: context)
        var descriptor: FetchDescriptor<SyncedFocusTimer>
        if let currentEpochID {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == targetID
                        && $0.dataEpochID == currentEpochID
                        && $0.statusRaw == completed
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
                    $0.sessionID == targetID
                        && $0.dataEpochID == nil
                        && $0.statusRaw == completed
                },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.id, order: .reverse)
                ]
            )
        }
        descriptor.fetchLimit = 1
        let record = try context.fetch(descriptor).first
        if let record { _ = try record.decodedPayload() }
        return record
    }

    private static func cancellationTimerRecord(
        sessionID: UUID,
        context: ModelContext
    ) throws -> SyncedFocusTimer? {
        let targetID = sessionID
        let cancelled = SyncedFocusStatus.cancelled.rawValue
        let currentEpochID = try ActivityResetStore.latestEpochID(context: context)
        var descriptor: FetchDescriptor<SyncedFocusTimer>
        if let currentEpochID {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == targetID
                        && $0.dataEpochID == currentEpochID
                        && $0.statusRaw == cancelled
                },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.terminalAt),
                    SortDescriptor(\SyncedFocusTimer.ownershipSequence, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.writerDeviceID, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.id, order: .reverse)
                ]
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == targetID
                        && $0.dataEpochID == nil
                        && $0.statusRaw == cancelled
                },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.terminalAt),
                    SortDescriptor(\SyncedFocusTimer.ownershipSequence, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.writerDeviceID, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.id, order: .reverse)
                ]
            )
        }
        descriptor.fetchLimit = 1
        let record = try context.fetch(descriptor).first
        if let record { _ = try record.decodedPayload() }
        return record
    }

    private static func preferredPendingCompletionRecord(
        sessionID: UUID,
        context: ModelContext
    ) throws -> SyncedFocusTimer? {
        let targetID = sessionID
        let pending = SyncedFocusStatus.completionPending.rawValue
        let currentEpochID = try ActivityResetStore.latestEpochID(context: context)
        var descriptor: FetchDescriptor<SyncedFocusTimer>
        if let currentEpochID {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == targetID
                        && $0.dataEpochID == currentEpochID
                        && $0.statusRaw == pending
                },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.ownershipSequence, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.writerDeviceID, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.id, order: .reverse)
                ]
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == targetID
                        && $0.dataEpochID == nil
                        && $0.statusRaw == pending
                },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.ownershipSequence, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.writerDeviceID, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.id, order: .reverse)
                ]
            )
        }
        descriptor.fetchLimit = 1
        let record = try context.fetch(descriptor).first
        if let record { _ = try record.decodedPayload() }
        return record
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
        guard try context.fetchCount(descriptor) <= QueryContract.matchingSessionRecordLimit else {
            throw FocusCloudSyncError.timerHistoryRequiresMaintenance
        }
        descriptor.fetchLimit = QueryContract.matchingSessionRecordLimit
        let records = try context.fetch(descriptor)

        // CloudKit can briefly materialize physical duplicates with the same
        // application-level identity. Identical policy snapshots must also
        // carry semantically identical payloads. Check every snapshot, not
        // only the eventual policy winner, while accepting harmless JSON key
        // order differences. This ensures an unrelated later save
        // cannot change fetch order and make recovery pick arbitrary content.
        var payloadBySnapshot: [FocusSyncRecordSnapshot: FocusCloudPayload] = [:]
        for record in records {
            let snapshot = record.policySnapshot
            let payload = try record.decodedPayload()
            if let knownPayload = payloadBySnapshot[snapshot],
               knownPayload != payload {
                throw FocusCloudSyncError.invalidPayload
            }
            payloadBySnapshot[snapshot] = payload
        }
        return records
    }

    /// Walks logical active timers rather than taking a raw-row prefix. A
    /// closed session can legitimately retain hundreds of delayed active
    /// revisions. Only an exact, materialized StudySession permits maintenance
    /// to remove that closed active tail; a fixed raw-row prefix would let the
    /// retained revisions hide the next independent timer forever.
    private static func oldestOpenTimer(
        context: ModelContext
    ) throws -> SyncedFocusTimer? {
        var cursor: (startedAt: Date, sessionID: UUID)?
        var visitedSessionIDs = Set<UUID>()

        for _ in 0..<QueryContract.logicalTimerScanLimit {
            guard let candidate = try nextActiveTimerCandidate(
                after: cursor,
                context: context
            ) else {
                return nil
            }
            cursor = (candidate.startedAt, candidate.sessionID)
            guard visitedSessionIDs.insert(candidate.sessionID).inserted else {
                continue
            }
            // Exact closure sentinels are deliberately checked before loading
            // the bounded revision group. That makes a 300-row stale active
            // tail harmless when an older cancellation/completion exists.
            do {
                if try isSessionClosed(
                    sessionID: candidate.sessionID,
                    context: context
                ) {
                    continue
                }
            } catch FocusCloudSyncError.invalidPayload {
                // Direct operations on this logical ID fail closed. The
                // account-wide recovery scan may still advance to an
                // independent valid timer without mutating the corrupt row.
                continue
            }

            do {
                let records = try timerRecords(
                    sessionID: candidate.sessionID,
                    context: context
                )
                guard let winner = FocusSyncPolicy.resolveSameSession(
                    records.map(\.policySnapshot)
                ), winner.status.isRecoverable else {
                    continue
                }
                guard let storedWinner = try storedTimerRecord(
                    matching: winner,
                    in: records
                ) else {
                    throw FocusCloudSyncError.missingTimerRecord
                }
                // A corrupt logical group is preserved for diagnostics and
                // maintenance, but must not permanently hide an independent
                // valid timer later in the ordered scan.
                _ = try storedWinner.decodedPayload()
                return storedWinner
            } catch FocusCloudSyncError.invalidPayload {
                continue
            }
        }

        // Only a materialized StudySession permits maintenance to remove a
        // closed active tail. Other duplicate source revisions are retained;
        // failing closed is safer than silently overlooking an active timer
        // beyond this adversarial ceiling.
        throw FocusCloudSyncError.timerHistoryRequiresMaintenance
    }

    private static func nextActiveTimerCandidate(
        after cursor: (startedAt: Date, sessionID: UUID)?,
        context: ModelContext
    ) throws -> SyncedFocusTimer? {
        let running = SyncedFocusStatus.running.rawValue
        let paused = SyncedFocusStatus.paused.rawValue
        let completionPending = SyncedFocusStatus.completionPending.rawValue
        let currentEpochID = try ActivityResetStore.latestEpochID(context: context)
        let cursorStart = cursor?.startedAt
        let cursorSessionID = cursor?.sessionID
        var descriptor: FetchDescriptor<SyncedFocusTimer>
        switch (currentEpochID, cursorStart, cursorSessionID) {
        case let (epochID?, start?, sessionID?):
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.dataEpochID == epochID
                        && ($0.statusRaw == running
                            || $0.statusRaw == paused
                            || $0.statusRaw == completionPending)
                        && ($0.startedAt > start
                            || ($0.startedAt == start
                                && $0.sessionID > sessionID))
                },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.startedAt),
                    SortDescriptor(\SyncedFocusTimer.sessionID),
                    SortDescriptor(\SyncedFocusTimer.ownershipSequence, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.writerDeviceID, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.id, order: .reverse)
                ]
            )
        case let (epochID?, nil, nil):
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.dataEpochID == epochID
                        && ($0.statusRaw == running
                            || $0.statusRaw == paused
                            || $0.statusRaw == completionPending)
                },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.startedAt),
                    SortDescriptor(\SyncedFocusTimer.sessionID),
                    SortDescriptor(\SyncedFocusTimer.ownershipSequence, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.writerDeviceID, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.id, order: .reverse)
                ]
            )
        case let (nil, start?, sessionID?):
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.dataEpochID == nil
                        && ($0.statusRaw == running
                            || $0.statusRaw == paused
                            || $0.statusRaw == completionPending)
                        && ($0.startedAt > start
                            || ($0.startedAt == start
                                && $0.sessionID > sessionID))
                },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.startedAt),
                    SortDescriptor(\SyncedFocusTimer.sessionID),
                    SortDescriptor(\SyncedFocusTimer.ownershipSequence, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.writerDeviceID, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.id, order: .reverse)
                ]
            )
        case (nil, nil, nil):
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.dataEpochID == nil
                        && ($0.statusRaw == running
                            || $0.statusRaw == paused
                            || $0.statusRaw == completionPending)
                },
                sortBy: [
                    SortDescriptor(\SyncedFocusTimer.startedAt),
                    SortDescriptor(\SyncedFocusTimer.sessionID),
                    SortDescriptor(\SyncedFocusTimer.ownershipSequence, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.revision, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.writerDeviceID, order: .reverse),
                    SortDescriptor(\SyncedFocusTimer.id, order: .reverse)
                ]
            )
        default:
            throw FocusCloudSyncError.invalidPayload
        }
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// A CloudKit merge can temporarily materialize physical duplicates with
    /// the same application-level UUID. Match the entire policy snapshot, not
    /// only that UUID; otherwise fetch order can return a different status than
    /// the deterministic resolver selected. Identical policy snapshots with
    /// semantically divergent payloads are corrupt and must not be guessed
    /// between; harmless JSON key-order differences remain equivalent.
    private static func storedTimerRecord(
        matching snapshot: FocusSyncRecordSnapshot,
        in records: [SyncedFocusTimer]
    ) throws -> SyncedFocusTimer? {
        let matches = records.filter { $0.policySnapshot == snapshot }
        guard let first = matches.first else { return nil }
        let firstPayload = try first.decodedPayload()
        guard try matches.dropFirst().allSatisfy({
            try $0.decodedPayload() == firstPayload
        }) else {
            throw FocusCloudSyncError.invalidPayload
        }
        return first
    }

    private static func nextRevision(after current: Int?) -> Int {
        let current = max(0, current ?? 0)
        return current >= FocusSyncPolicy.maximumSupportedRevision
            ? FocusSyncPolicy.maximumSupportedRevision
            : current + 1
    }

    private static func currentOwnershipClaims(
        context: ModelContext
    ) throws -> [FocusTimerDeviceClaim] {
        let maximumSequence = FocusSyncPolicy.maximumSupportedOwnershipSequence
        let currentEpochID = try ActivityResetStore.latestEpochID(context: context)
        var descriptor: FetchDescriptor<FocusTimerDeviceClaim>
        if let currentEpochID {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.dataEpochID == currentEpochID
                        && $0.sequence >= 0
                        && $0.sequence <= maximumSequence
                },
                sortBy: [
                    SortDescriptor(\FocusTimerDeviceClaim.sequence, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.claimedAt, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.deviceID, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.id, order: .reverse)
                ]
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.dataEpochID == nil
                        && $0.sequence >= 0
                        && $0.sequence <= maximumSequence
                },
                sortBy: [
                    SortDescriptor(\FocusTimerDeviceClaim.sequence, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.claimedAt, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.deviceID, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.id, order: .reverse)
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
        let maximumSequence = FocusSyncPolicy.maximumSupportedOwnershipSequence
        let currentEpochID = try ActivityResetStore.latestEpochID(context: context)
        var descriptor: FetchDescriptor<FocusTimerDeviceClaim>
        if let currentEpochID {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == targetID
                        && $0.dataEpochID == currentEpochID
                        && $0.sequence >= 0
                        && $0.sequence <= maximumSequence
                },
                sortBy: [
                    SortDescriptor(\FocusTimerDeviceClaim.sequence, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.claimedAt, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.deviceID, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.id, order: .reverse)
                ]
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.sessionID == targetID
                        && $0.dataEpochID == nil
                        && $0.sequence >= 0
                        && $0.sequence <= maximumSequence
                },
                sortBy: [
                    SortDescriptor(\FocusTimerDeviceClaim.sequence, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.claimedAt, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.deviceID, order: .reverse),
                    SortDescriptor(\FocusTimerDeviceClaim.id, order: .reverse)
                ]
            )
        }
        descriptor.fetchLimit = QueryContract.matchingSessionClaimLimit
        return try context.fetch(descriptor)
    }

    private static func activeOwnershipClaim(
        sessionID: UUID,
        context: ModelContext
    ) throws -> FocusTimerDeviceClaim? {
        var candidates = try ownershipClaims(
            sessionID: sessionID,
            context: context
        )
        let currentEpochID = try ActivityResetStore.latestEpochID(context: context)

        for _ in 0..<QueryContract.matchingSessionClaimLimit {
            guard let provisional = FocusSyncPolicy.notificationOwnerClaim(
                for: sessionID,
                claims: candidates.map(\.policySnapshot)
            ) else {
                // If a full bounded page consisted only of released duplicate
                // groups, a later active claim may exist beyond it. Physical
                // source claims are retained, so exact verification must fail
                // closed at the bounded history ceiling.
                if candidates.count == QueryContract.matchingSessionClaimLimit {
                    throw FocusCloudSyncError.timerHistoryRequiresMaintenance
                }
                return nil
            }

            var exactDescriptor = ownershipClaimCopiesDescriptor(
                id: provisional.id,
                currentEpochID: currentEpochID
            )
            guard try context.fetchCount(exactDescriptor)
                    <= QueryContract.matchingSessionClaimLimit else {
                throw FocusCloudSyncError.timerHistoryRequiresMaintenance
            }
            exactDescriptor.fetchLimit = QueryContract.matchingSessionClaimLimit
            let exactCopies = try context.fetch(exactDescriptor)
            let combinedSnapshots = candidates.map(\.policySnapshot)
                + exactCopies.map(\.policySnapshot)
            guard let verified = FocusSyncPolicy.notificationOwnerClaim(
                for: sessionID,
                claims: combinedSnapshots
            ) else { return nil }
            if verified.id != provisional.id {
                candidates.removeAll { $0.id == provisional.id }
                continue
            }
            return (exactCopies + candidates).first {
                $0.releasedAt == nil && $0.policySnapshot == verified
            }
        }
        throw FocusCloudSyncError.timerHistoryRequiresMaintenance
    }

    private static func ownershipClaimCopiesDescriptor(
        id: UUID,
        currentEpochID: UUID?
    ) -> FetchDescriptor<FocusTimerDeviceClaim> {
        let targetID = id
        let predicate: Predicate<FocusTimerDeviceClaim>
        if let currentEpochID {
            predicate = #Predicate {
                $0.id == targetID && $0.dataEpochID == currentEpochID
            }
        } else {
            predicate = #Predicate {
                $0.id == targetID && $0.dataEpochID == nil
            }
        }
        return FetchDescriptor(
            predicate: predicate,
            sortBy: [SortDescriptor(\FocusTimerDeviceClaim.releasedAt, order: .reverse)]
        )
    }

    private static func nextOwnershipSequence(
        sessionID: UUID,
        context: ModelContext
    ) throws -> Int {
        var descriptor = try ownershipClaimDescriptor(
            sessionID: sessionID,
            context: context,
            activeOnly: false
        )
        descriptor.fetchLimit = 1
        let maximum = try context.fetch(descriptor).first?.sequence ?? -1
        guard maximum < FocusSyncPolicy.maximumSupportedOwnershipSequence else {
            throw FocusCloudSyncError.ownershipSequenceExhausted
        }
        return maximum + 1
    }

    private static func ownershipClaimDescriptor(
        sessionID: UUID,
        context: ModelContext,
        activeOnly: Bool
    ) throws -> FetchDescriptor<FocusTimerDeviceClaim> {
        let targetID = sessionID
        let maximumSequence = FocusSyncPolicy.maximumSupportedOwnershipSequence
        let currentEpochID = try ActivityResetStore.latestEpochID(context: context)
        let predicate: Predicate<FocusTimerDeviceClaim>
        switch (currentEpochID, activeOnly) {
        case let (epochID?, true):
            predicate = #Predicate {
                $0.sessionID == targetID
                    && $0.dataEpochID == epochID
                    && $0.releasedAt == nil
                    && $0.sequence >= 0
                    && $0.sequence <= maximumSequence
            }
        case let (epochID?, false):
            predicate = #Predicate {
                $0.sessionID == targetID
                    && $0.dataEpochID == epochID
                    && $0.sequence >= 0
                    && $0.sequence <= maximumSequence
            }
        case (nil, true):
            predicate = #Predicate {
                $0.sessionID == targetID
                    && $0.dataEpochID == nil
                    && $0.releasedAt == nil
                    && $0.sequence >= 0
                    && $0.sequence <= maximumSequence
            }
        case (nil, false):
            predicate = #Predicate {
                $0.sessionID == targetID
                    && $0.dataEpochID == nil
                    && $0.sequence >= 0
                    && $0.sequence <= maximumSequence
            }
        }
        return FetchDescriptor(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\FocusTimerDeviceClaim.sequence, order: .reverse),
                SortDescriptor(\FocusTimerDeviceClaim.claimedAt, order: .reverse),
                SortDescriptor(\FocusTimerDeviceClaim.deviceID, order: .reverse),
                SortDescriptor(\FocusTimerDeviceClaim.id, order: .reverse)
            ]
        )
    }
}
