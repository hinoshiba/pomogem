import Foundation

/// Executes complete deletion as an idempotent, crash-resumable transaction.
///
/// The coordinator intentionally has no view dependencies. A Settings surface
/// supplies a quiescence implementation, presents progress from the persisted
/// phase and terminates the persistence session after success.
@MainActor
final class CompleteDataDeletionCoordinator {
    typealias PhaseObserver = @MainActor @Sendable (
        CompleteDataDeletionPhase
    ) -> Void

    private let stateStore: any CompleteDataDeletionStateStoring
    private let remoteStore: any CompleteDataDeletionRemoteStoring
    private let localModelStore: any CompleteDataDeletionLocalModelStoring
    private let deviceState: any CompleteDataDeletionDeviceStateClearing
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    private let phaseObserver: PhaseObserver

    private var isRunning = false

    init(
        stateStore: any CompleteDataDeletionStateStoring,
        remoteStore: any CompleteDataDeletionRemoteStoring,
        localModelStore: any CompleteDataDeletionLocalModelStoring,
        deviceState: any CompleteDataDeletionDeviceStateClearing,
        now: @escaping @Sendable () -> Date = { .now },
        makeID: @escaping @Sendable () -> UUID = { UUID() },
        phaseObserver: @escaping PhaseObserver = { _ in }
    ) {
        self.stateStore = stateStore
        self.remoteStore = remoteStore
        self.localModelStore = localModelStore
        self.deviceState = deviceState
        self.now = now
        self.makeID = makeID
        self.phaseObserver = phaseObserver
    }

    /// Persists the irreversible intent and obtains the server-side pending
    /// fence, then stops before touching local models or CloudKit zones. The
    /// caller must unmount the shipping ModelContainer and let the launch host
    /// resume `deleteAllData()`. SwiftData's mirroring delegate otherwise stays
    /// alive long enough to recreate the zone this transaction just deleted.
    func prepareForPersistenceUnmount() async throws
        -> CompleteDataDeletionPendingMarker {
        guard !isRunning else { throw CompleteDataDeletionError.alreadyRunning }
        isRunning = true
        defer { isRunning = false }

        var marker = try await loadOrCreatePendingMarker()
        phaseObserver(marker.phase)
        guard marker.phase == .establishRemoteFence else { return marker }

        do {
            let fence = try await remoteStore.establishPendingFence(
                transactionID: marker.transactionID,
                requestedGenerationID: marker.requestedGenerationID,
                requestedAt: marker.startedAt
            )
            guard fence.transactionID == marker.transactionID,
                  fence.generationID == marker.requestedGenerationID else {
                throw CompleteDataDeletionError.invalidState(
                    "iCloudの削除世代がローカルの削除要求と一致しません"
                )
            }
            marker.fence = fence
            try await advance(&marker, to: .quiesceApplication)
            return marker
        } catch let error as CompleteDataDeletionError {
            try? await recordFailure(&marker)
            throw error
        } catch {
            try? await recordFailure(&marker)
            throw CompleteDataDeletionError.phaseFailed(
                .establishRemoteFence,
                error
            )
        }
    }

    func deleteAllData() async throws -> CompleteDataDeletionResult {
        guard !isRunning else { throw CompleteDataDeletionError.alreadyRunning }
        isRunning = true
        defer { isRunning = false }

        var marker = try await loadOrCreatePendingMarker()
        phaseObserver(marker.phase)

        // A resumed process has a newly active UI/persistence session even if
        // the previous process already passed this phase. Quiesce again before
        // continuing any later destructive step.
        if marker.phase > .quiesceApplication {
            do {
                try await deviceState.quiesceApplication()
            } catch {
                try? await recordFailure(&marker)
                throw CompleteDataDeletionError.phaseFailed(
                    .quiesceApplication,
                    error
                )
            }
        }

        while true {
            do {
                switch marker.phase {
                case .establishRemoteFence:
                    let fence = try await remoteStore.establishPendingFence(
                        transactionID: marker.transactionID,
                        requestedGenerationID: marker.requestedGenerationID,
                        requestedAt: marker.startedAt
                    )
                    guard fence.transactionID == marker.transactionID,
                          fence.generationID == marker.requestedGenerationID
                    else {
                        throw CompleteDataDeletionError.invalidState(
                            "iCloudの削除世代がローカルの削除要求と一致しません"
                        )
                    }
                    marker.fence = fence
                    try await advance(&marker, to: .quiesceApplication)

                case .quiesceApplication:
                    try await deviceState.quiesceApplication()
                    try await advance(&marker, to: .clearDeviceState)

                case .clearDeviceState:
                    try await deviceState.clearDeviceState()
                    try await advance(&marker, to: .deleteLocalModels)

                case .deleteLocalModels:
                    let remaining = try await localModelStore.deleteAllModels()
                    guard remaining == .zero else {
                        throw CompleteDataDeletionError.invalidState(
                            "SwiftDataに\(remaining.total)件のレコードが残っています"
                        )
                    }
                    try await advance(&marker, to: .deletePrivateCloudData)

                case .deletePrivateCloudData:
                    let fence = try requiredFence(in: marker)
                    let receipt = try await remoteStore.deletePrivateCloudData(
                        preserving: fence
                    )
                    marker.deletedCloudZoneCount += receipt.deletedZoneCount
                    try await advance(&marker, to: .commitRemoteFence)

                case .commitRemoteFence:
                    let fence = try requiredFence(in: marker)
                    let committed = try await remoteStore.commitFence(
                        fence,
                        committedAt: now()
                    )
                    guard committed.state == .committed,
                          committed.transactionID == marker.transactionID,
                          committed.generationID == marker.requestedGenerationID
                    else {
                        throw CompleteDataDeletionError.invalidState(
                            "iCloudが削除完了世代を確定していません"
                        )
                    }
                    marker.fence = committed
                    try await advance(&marker, to: .persistGenerationReceipt)

                case .persistGenerationReceipt:
                    let fence = try requiredFence(in: marker)
                    guard fence.state == .committed else {
                        throw CompleteDataDeletionError.invalidState(
                            "未確定の削除世代は端末へ受領記録できません"
                        )
                    }
                    let receipt = CompleteDataDeletionGenerationReceipt(
                        fence: fence,
                        acknowledgedAt: now()
                    )
                    try await stateStore.saveGenerationReceipt(receipt)
                    try await advance(&marker, to: .finish)

                case .finish:
                    let fence = try requiredFence(in: marker)
                    guard fence.state == .committed else {
                        throw CompleteDataDeletionError.invalidState(
                            "削除完了状態に未確定の世代が残っています"
                        )
                    }
                    let localReceipt = try await stateStore.loadGenerationReceipt()
                    guard localReceipt?.matches(fence) == true else {
                        throw CompleteDataDeletionError.invalidState(
                            "端末の削除世代受領記録を確認できません"
                        )
                    }

                    // Removing the pending journal is itself part of success.
                    // If it fails, the caller receives an error and the next
                    // launch safely resumes the idempotent finish phase.
                    try await stateStore.removePendingMarker()
                    return CompleteDataDeletionResult(
                        fence: fence,
                        startedAt: marker.startedAt,
                        completedAt: now(),
                        deletedCloudZoneCount: marker.deletedCloudZoneCount,
                        requiresRelaunch: true
                    )
                }
            } catch let error as CompleteDataDeletionError {
                try? await recordFailure(&marker)
                throw error
            } catch {
                let failedPhase = marker.phase
                try? await recordFailure(&marker)
                throw CompleteDataDeletionError.phaseFailed(failedPhase, error)
            }
        }
    }

    private func advance(
        _ marker: inout CompleteDataDeletionPendingMarker,
        to nextPhase: CompleteDataDeletionPhase
    ) async throws {
        guard nextPhase > marker.phase else {
            throw CompleteDataDeletionError.invalidState(
                "削除フェーズを逆行できません"
            )
        }
        marker.phase = nextPhase
        marker.updatedAt = now()
        try await stateStore.savePendingMarker(marker)
        phaseObserver(marker.phase)
    }

    private func loadOrCreatePendingMarker() async throws
        -> CompleteDataDeletionPendingMarker {
        if let pending = try await stateStore.loadPendingMarker() {
            try Self.validate(pending)
            return pending
        }

        let startedAt = now()
        let marker = CompleteDataDeletionPendingMarker(
            transactionID: makeID(),
            requestedGenerationID: makeID(),
            startedAt: startedAt
        )
        // Nothing destructive or remote happens until the durable local
        // journal exists. A write failure here is therefore safe to retry.
        try await stateStore.savePendingMarker(marker)
        return marker
    }

    private func recordFailure(
        _ marker: inout CompleteDataDeletionPendingMarker
    ) async throws {
        marker.failureCount += 1
        marker.updatedAt = now()
        try await stateStore.savePendingMarker(marker)
    }

    private func requiredFence(
        in marker: CompleteDataDeletionPendingMarker
    ) throws -> CompleteDataDeletionFence {
        guard let fence = marker.fence else {
            throw CompleteDataDeletionError.invalidState(
                "削除世代fenceがありません"
            )
        }
        return fence
    }

    private static func validate(
        _ marker: CompleteDataDeletionPendingMarker
    ) throws {
        guard marker.formatVersion == CompleteDataDeletionPendingMarker.formatVersion else {
            throw CompleteDataDeletionError.invalidState(
                "未対応のpending marker形式です"
            )
        }
        guard marker.failureCount >= 0, marker.deletedCloudZoneCount >= 0 else {
            throw CompleteDataDeletionError.invalidState(
                "pending markerの件数が不正です"
            )
        }
        if let fence = marker.fence {
            guard fence.formatVersion == CompleteDataDeletionFence.formatVersion,
                  fence.transactionID == marker.transactionID,
                  fence.generationID == marker.requestedGenerationID
            else {
                throw CompleteDataDeletionError.invalidState(
                    "pending markerとgeneration fenceが一致しません"
                )
            }
        } else if marker.phase > .establishRemoteFence {
            throw CompleteDataDeletionError.invalidState(
                "削除再開に必要なgeneration fenceがありません"
            )
        }
    }
}
