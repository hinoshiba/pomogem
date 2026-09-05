import Foundation
import Observation

/// The direct two-container deletion transaction is intentionally not exposed
/// in 1.0. Cross-account binding and single-owner leasing must be completed
/// before this can safely mutate a user's private CloudKit zones.
enum CompleteDataDeletionReleasePolicy {
    static let isEnabled = false
}

/// The only CloudKit state intentionally retained after erasure.
///
/// It contains no study content or device identifier. Keeping one monotonic
/// generation is necessary to stop an offline device from treating its old
/// mirrored store as current after another device has erased the account.
struct CompleteDataDeletionFence: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case pending
        case committed
    }

    static let formatVersion = 1

    let formatVersion: Int
    let generationID: UUID
    let transactionID: UUID
    let sequence: Int64
    let state: State
    let createdAt: Date
    let updatedAt: Date

    init(
        generationID: UUID,
        transactionID: UUID,
        sequence: Int64,
        state: State,
        createdAt: Date,
        updatedAt: Date
    ) {
        formatVersion = Self.formatVersion
        self.generationID = generationID
        self.transactionID = transactionID
        self.sequence = max(0, sequence)
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func committed(at date: Date) -> Self {
        Self(
            generationID: generationID,
            transactionID: transactionID,
            sequence: sequence,
            state: .committed,
            createdAt: createdAt,
            updatedAt: date
        )
    }
}

/// A device-local acknowledgement that the local SwiftData store belongs to a
/// committed remote generation. This is an operational UUID, not user data.
struct CompleteDataDeletionGenerationReceipt: Codable, Equatable, Sendable {
    static let formatVersion = 1

    let formatVersion: Int
    let generationID: UUID
    let sequence: Int64
    let acknowledgedAt: Date

    init(fence: CompleteDataDeletionFence, acknowledgedAt: Date) {
        formatVersion = Self.formatVersion
        generationID = fence.generationID
        sequence = fence.sequence
        self.acknowledgedAt = acknowledgedAt
    }

    func matches(_ fence: CompleteDataDeletionFence) -> Bool {
        fence.state == .committed
            && generationID == fence.generationID
            && sequence == fence.sequence
    }
}

enum CompleteDataDeletionPhase: Int, Codable, CaseIterable, Comparable, Sendable {
    case establishRemoteFence
    case quiesceApplication
    case clearDeviceState
    case deleteLocalModels
    case deletePrivateCloudData
    case commitRemoteFence
    case persistGenerationReceipt
    case finish

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension CompleteDataDeletionPhase {
    var userFacingTitle: String {
        switch self {
        case .establishRemoteFence:
            "iCloudに削除要求を保護しています"
        case .quiesceApplication:
            "タイマーと保存処理を停止しています"
        case .clearDeviceState:
            "この端末の設定と一時ファイルを消去しています"
        case .deleteLocalModels:
            "この端末の記録を消去しています"
        case .deletePrivateCloudData:
            "iCloudの記録を消去しています"
        case .commitRemoteFence:
            "iCloudで削除完了を確認しています"
        case .persistGenerationReceipt:
            "この端末に削除世代を記録しています"
        case .finish:
            "削除結果を検証しています"
        }
    }

    var progressFraction: Double {
        Double(rawValue + 1) / Double(Self.allCases.count)
    }
}

/// Shared UI state for the irreversible deletion transaction. The actual
/// operation is installed by RootView because it alone owns every writer and
/// the current ModelContainer.
@MainActor
@Observable
final class CompleteDataDeletionController {
    enum Status: Equatable {
        case idle
        case running(CompleteDataDeletionPhase)
        case failed(CompleteDataDeletionPhase?, String)
        case rebuildingPersistence
    }

    typealias Operation = @MainActor @Sendable () async throws -> Void

    private(set) var status: Status = .idle
    private var operation: Operation?
    private var task: Task<Void, Never>?

    var hasStarted: Bool {
        switch status {
        case .idle:
            false
        case .running, .failed, .rebuildingPersistence:
            true
        }
    }

    var isRunning: Bool {
        switch status {
        case .running, .rebuildingPersistence:
            true
        case .idle, .failed:
            false
        }
    }

    func install(operation: @escaping Operation) {
        self.operation = operation
    }

    func startOrRetry() {
        guard task == nil, let operation else { return }
        let lastPhase: CompleteDataDeletionPhase?
        if case let .failed(phase, _) = status {
            lastPhase = phase
        } else {
            lastPhase = nil
        }
        status = .running(lastPhase ?? .establishRemoteFence)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await operation()
            } catch is CancellationError {
                // Once the journal exists, cancellation is not a successful or
                // idle state. Keep the retry affordance visible.
                let phase = currentPhase
                status = .failed(
                    phase,
                    "削除処理が中断されました。再試行すると安全な位置から続けます。"
                )
            } catch {
                let phase = currentPhase
                status = .failed(phase, error.localizedDescription)
            }
            task = nil
        }
    }

    func report(phase: CompleteDataDeletionPhase) {
        guard hasStarted else { return }
        status = .running(phase)
    }

    func reportPersistenceRebuild() {
        status = .rebuildingPersistence
    }

    private var currentPhase: CompleteDataDeletionPhase? {
        switch status {
        case let .running(phase), let .failed(phase?, _):
            phase
        case .idle, .failed(nil, _), .rebuildingPersistence:
            nil
        }
    }
}

/// Crash-safe journal stored outside UserDefaults and the SwiftData store.
/// It remains present until every required phase, including CloudKit's server
/// acknowledgement, has completed. A failed phase is therefore retryable and
/// can never be presented as successful deletion.
struct CompleteDataDeletionPendingMarker: Codable, Equatable, Sendable {
    static let formatVersion = 1

    let formatVersion: Int
    let transactionID: UUID
    let requestedGenerationID: UUID
    let startedAt: Date
    var updatedAt: Date
    var phase: CompleteDataDeletionPhase
    var fence: CompleteDataDeletionFence?
    var deletedCloudZoneCount: Int
    var failureCount: Int

    init(
        transactionID: UUID,
        requestedGenerationID: UUID,
        startedAt: Date
    ) {
        formatVersion = Self.formatVersion
        self.transactionID = transactionID
        self.requestedGenerationID = requestedGenerationID
        self.startedAt = startedAt
        updatedAt = startedAt
        phase = .establishRemoteFence
        fence = nil
        deletedCloudZoneCount = 0
        failureCount = 0
    }
}

struct CompleteDataDeletionModelCounts: Codable, Equatable, Sendable {
    let subjects: Int
    let studySessions: Int
    let achievementStones: Int
    let aggregatePebbles: Int
    let legacyStrata: Int
    let legacyBedrocks: Int
    let gachaStates: Int
    let preferences: Int
    let activityResetMarkers: Int
    let syncedFocusTimers: Int
    let focusTimerDeviceClaims: Int
    let rareRewardPendingCommits: Int
    let rareRewardLedgerCursors: Int

    var total: Int {
        subjects
            + studySessions
            + achievementStones
            + aggregatePebbles
            + legacyStrata
            + legacyBedrocks
            + gachaStates
            + preferences
            + activityResetMarkers
            + syncedFocusTimers
            + focusTimerDeviceClaims
            + rareRewardPendingCommits
            + rareRewardLedgerCursors
    }

    var cloudStoreTotal: Int {
        subjects
            + studySessions
            + achievementStones
            + preferences
            + activityResetMarkers
            + syncedFocusTimers
            + focusTimerDeviceClaims
            + rareRewardPendingCommits
            + rareRewardLedgerCursors
    }

    var localProjectionStoreTotal: Int {
        aggregatePebbles
            + legacyStrata
            + legacyBedrocks
            + gachaStates
    }

    static let zero = Self(
        subjects: 0,
        studySessions: 0,
        achievementStones: 0,
        aggregatePebbles: 0,
        legacyStrata: 0,
        legacyBedrocks: 0,
        gachaStates: 0,
        preferences: 0,
        activityResetMarkers: 0,
        syncedFocusTimers: 0,
        focusTimerDeviceClaims: 0,
        rareRewardPendingCommits: 0,
        rareRewardLedgerCursors: 0
    )
}

struct CompleteDataDeletionCloudReceipt: Equatable, Sendable {
    let deletedZoneCount: Int
}

struct CompleteDataDeletionResult: Equatable, Sendable {
    let fence: CompleteDataDeletionFence
    let startedAt: Date
    let completedAt: Date
    let deletedCloudZoneCount: Int

    /// The caller must terminate the current persistence session and relaunch.
    /// Continuing to use the pre-erasure CloudKit-backed container can recreate
    /// its deleted mirroring zone before the launch generation gate runs.
    let requiresRelaunch: Bool
}

enum CompleteDataDeletionRemoteFenceLookup: Equatable, Sendable {
    case absent
    case found(CompleteDataDeletionFence)
    case unavailable
    case invalid
}

enum CompleteDataDeletionLaunchBlockReason: Equatable, Sendable {
    case localDeletionPending
    case cloudUnavailable
    case remoteDeletionPending
    case remoteFenceMissing
    case remoteFenceInvalid
}

enum CompleteDataDeletionAvailabilityPolicy: Equatable, Sendable {
    /// Strongest anti-resurrection posture, at the cost of making an iCloud
    /// outage or signed-out account unable to launch the data store.
    case strictAntiResurrection
    /// Preserves offline timers when no deletion is pending on this device.
    /// Automatic SwiftData/CloudKit mirroring means an offline or old binary can
    /// still upload stale rows before a later fence check; UI and policy must
    /// disclose that residual limitation rather than promise absolute erasure.
    case offlineFirst
}

/// Decision required before constructing the CloudKit-backed ModelContainer.
/// `.eraseLocalStoreBeforeUse` is deliberately not an allow state: the old
/// local store must be physically discarded and a receipt written first.
enum CompleteDataDeletionLaunchDecision: Equatable, Sendable {
    case allowLegacyStore
    case allowGeneration(CompleteDataDeletionFence)
    case allowUnverifiedOffline(CompleteDataDeletionGenerationReceipt?)
    case eraseLocalStoreBeforeUse(CompleteDataDeletionFence)
    case resumeDeletion(CompleteDataDeletionPendingMarker)
    case block(CompleteDataDeletionLaunchBlockReason)

    /// True only when it is safe for the bootstrap layer to mount the
    /// pre-existing persistent store. Erasure and resume decisions must remain
    /// on blocking UI until their recovery work has finished.
    var permitsExistingPersistentStoreMount: Bool {
        switch self {
        case .allowLegacyStore, .allowGeneration, .allowUnverifiedOffline:
            true
        case .eraseLocalStoreBeforeUse, .resumeDeletion, .block:
            false
        }
    }

    var requiresBlockingRecovery: Bool {
        !permitsExistingPersistentStoreMount
    }
}

enum CompleteDataDeletionLaunchGate {
    static func evaluate(
        pendingMarker: CompleteDataDeletionPendingMarker?,
        localReceipt: CompleteDataDeletionGenerationReceipt?,
        remoteFence: CompleteDataDeletionRemoteFenceLookup,
        availabilityPolicy: CompleteDataDeletionAvailabilityPolicy = .strictAntiResurrection
    ) -> CompleteDataDeletionLaunchDecision {
        if let pendingMarker {
            return .resumeDeletion(pendingMarker)
        }

        switch remoteFence {
        case .unavailable:
            switch availabilityPolicy {
            case .strictAntiResurrection:
                return .block(.cloudUnavailable)
            case .offlineFirst:
                // A receipt proves that this installation previously joined a
                // committed generation. With no receipt, an offline fresh
                // install is indistinguishable from an old store created before
                // a deletion on another device. Quarantine that ambiguous case
                // so new offline work is never accepted and then erased when the
                // fence becomes reachable.
                guard localReceipt != nil else {
                    return .block(.cloudUnavailable)
                }
                // There is no local deletion journal (handled above). Allowing
                // a previously verified store is an explicit availability
                // tradeoff, not evidence that the remote generation is current.
                return .allowUnverifiedOffline(localReceipt)
            }

        case .invalid:
            // A server response was received but its retained safety record
            // could not be authenticated structurally. This is not an offline
            // availability event and must never open the old store.
            return .block(.remoteFenceInvalid)

        case .absent:
            // No receipt is the one supported pre-deletion generation. Once a
            // receipt exists, a missing server fence is an integrity failure.
            return localReceipt == nil
                ? .allowLegacyStore
                : .block(.remoteFenceMissing)

        case let .found(fence):
            guard fence.state == .committed else {
                // A pending fence is proof that a user already authorized the
                // irreversible operation on another device. Adopt that exact
                // transaction so a crash or uninstall of the initiating device
                // cannot leave every other device permanently blocked.
                var marker = CompleteDataDeletionPendingMarker(
                    transactionID: fence.transactionID,
                    requestedGenerationID: fence.generationID,
                    startedAt: fence.createdAt
                )
                marker.updatedAt = fence.updatedAt
                marker.phase = .quiesceApplication
                marker.fence = fence
                return .resumeDeletion(marker)
            }
            guard localReceipt?.matches(fence) == true else {
                return .eraseLocalStoreBeforeUse(fence)
            }
            return .allowGeneration(fence)
        }
    }
}

enum CompleteDataDeletionWriteGate {
    /// New writes are legal only for a launch generation that was verified
    /// against the committed server fence. The legacy case is allowed solely
    /// after the launch gate has verified that no remote fence exists.
    static func permitsWrite(
        localReceipt: CompleteDataDeletionGenerationReceipt?,
        verifiedRemoteFence: CompleteDataDeletionRemoteFenceLookup
    ) -> Bool {
        switch verifiedRemoteFence {
        case .absent:
            return localReceipt == nil
        case let .found(fence):
            return localReceipt?.matches(fence) == true
        case .unavailable, .invalid:
            return false
        }
    }
}

protocol CompleteDataDeletionStateStoring: Sendable {
    func loadPendingMarker() async throws -> CompleteDataDeletionPendingMarker?
    func savePendingMarker(_ marker: CompleteDataDeletionPendingMarker) async throws
    func removePendingMarker() async throws
    func loadGenerationReceipt() async throws -> CompleteDataDeletionGenerationReceipt?
    func saveGenerationReceipt(_ receipt: CompleteDataDeletionGenerationReceipt) async throws
}

protocol CompleteDataDeletionRemoteStoring: Sendable {
    func establishPendingFence(
        transactionID: UUID,
        requestedGenerationID: UUID,
        requestedAt: Date
    ) async throws -> CompleteDataDeletionFence

    func deletePrivateCloudData(
        preserving fence: CompleteDataDeletionFence
    ) async throws -> CompleteDataDeletionCloudReceipt

    func commitFence(
        _ fence: CompleteDataDeletionFence,
        committedAt: Date
    ) async throws -> CompleteDataDeletionFence

    func fetchFence() async -> CompleteDataDeletionRemoteFenceLookup
}

protocol CompleteDataDeletionLocalModelStoring: Sendable {
    func deleteAllModels() async throws -> CompleteDataDeletionModelCounts
    func counts() async throws -> CompleteDataDeletionModelCounts
}

@MainActor
protocol CompleteDataDeletionDeviceStateClearing: Sendable {
    /// Stop timers, navigation mutations and every writer that owns the current
    /// ModelContainer. This must finish before any deletion starts.
    func quiesceApplication() async throws

    /// Clear UserDefaults, App Group files, notifications, Live Activities and
    /// app-owned export/GIF temporary files.
    func clearDeviceState() async throws
}

enum CompleteDataDeletionError: LocalizedError {
    case alreadyRunning
    case invalidState(String)
    case phaseFailed(CompleteDataDeletionPhase, any Error)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "データ削除はすでに実行中です。"
        case let .invalidState(reason):
            return "データ削除の再開情報が不正です: \(reason)"
        case let .phaseFailed(phase, error):
            return "データ削除を完了できませんでした（\(phase)）: \(error.localizedDescription)"
        }
    }
}
