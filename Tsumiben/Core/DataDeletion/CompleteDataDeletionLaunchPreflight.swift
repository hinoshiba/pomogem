import Foundation

/// Fetches the local journal/receipt and the authoritative CloudKit fence for
/// the bootstrap layer that runs before a persistent ModelContainer exists.
struct CompleteDataDeletionLaunchPreflight: Sendable {
    private let stateStore: any CompleteDataDeletionStateStoring
    private let remoteStore: any CompleteDataDeletionRemoteStoring
    private let availabilityPolicy: CompleteDataDeletionAvailabilityPolicy

    init(
        stateStore: any CompleteDataDeletionStateStoring,
        remoteStore: any CompleteDataDeletionRemoteStoring,
        availabilityPolicy: CompleteDataDeletionAvailabilityPolicy = .strictAntiResurrection
    ) {
        self.stateStore = stateStore
        self.remoteStore = remoteStore
        self.availabilityPolicy = availabilityPolicy
    }

    func evaluate() async throws -> CompleteDataDeletionLaunchDecision {
        if let pending = try await stateStore.loadPendingMarker() {
            return .resumeDeletion(pending)
        }
        let receipt = try await stateStore.loadGenerationReceipt()
        let remote = await remoteStore.fetchFence()
        let decision = CompleteDataDeletionLaunchGate.evaluate(
            pendingMarker: nil,
            localReceipt: receipt,
            remoteFence: remote,
            availabilityPolicy: availabilityPolicy
        )
        // When another device established a pending fence and then stopped,
        // adopt its exact transaction in the same crash-safe local journal used
        // by an originating device before the launch host destroys any store.
        if case let .resumeDeletion(adoptedMarker) = decision {
            try await stateStore.savePendingMarker(adoptedMarker)
        }
        return decision
    }

    /// Call only after the bootstrap layer has physically destroyed the stale
    /// SwiftData store and cleared this device's non-model state. The fence is
    /// fetched again so a concurrent, newer deletion cannot be acknowledged by
    /// mistake between the first decision and local erasure.
    func acknowledgeErasedStore(
        for expectedFence: CompleteDataDeletionFence,
        at date: Date = .now
    ) async throws {
        let lookup = await remoteStore.fetchFence()
        guard case let .found(current) = lookup,
              current.state == .committed,
              current.generationID == expectedFence.generationID,
              current.transactionID == expectedFence.transactionID,
              current.sequence == expectedFence.sequence
        else {
            throw CompleteDataDeletionError.invalidState(
                "ローカル削除中にiCloudのgeneration fenceが変更されました"
            )
        }
        try await stateStore.saveGenerationReceipt(
            CompleteDataDeletionGenerationReceipt(
                fence: current,
                acknowledgedAt: date
            )
        )
    }
}
