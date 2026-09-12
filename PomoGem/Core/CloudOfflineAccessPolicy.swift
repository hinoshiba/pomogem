import Foundation

enum CloudOfflineRevocationReason: String, Codable, Equatable, Sendable {
    case accountChanged, noAccount, restricted, accountMismatch
}

enum CloudOfflineAccessBlockReason: Error, Equatable, Sendable {
    case cloudNotSelected, invalidSelection, mountNotRecorded, mountMismatch
    case incompleteStorePair, pendingTransfer, pendingRemoteIntent, invalidSchema
    case missingReceipt, existingReceipt, invalidReceipt, bindingMismatch, onlineBaselineMissing
    case revoked(CloudOfflineRevocationReason)
}

/// These observations must describe the same closed store immediately before
/// admission. Unknown transfer/intent/schema state is a failure, not `false`.
struct CloudOfflineAccessConditions: Equatable, Sendable {
    let selection: PersistenceDeploymentSelectionState
    let mountState: PersistenceDeploymentMountState
    let hasExactCompleteStorePair: Bool
    let hasPendingTransfer: Bool
    let hasPendingRemoteIntent: Bool
    let isSchemaValid: Bool
}

/// Authorizes only an unverified local phone copy opened with CloudKit `.none`.
/// This policy never authenticates the current Apple Account, changes the saved
/// deployment mode, creates a namespace, or authorizes a mirroring container.
enum CloudOfflineAccessPolicy {
    static let accessDescription = "このiPhoneに保存済みのデータを利用しています。現在のiCloudアカウントと最新のデータは未確認です。"

    static func blockReason(
        selection: PersistenceDeploymentSelectionState,
        mountState: PersistenceDeploymentMountState,
        hasExactCompleteStorePair: Bool,
        hasPendingTransfer: Bool,
        hasPendingRemoteIntent: Bool,
        isSchemaValid: Bool,
        receipt: CloudOfflineAccessReceipt?
    ) -> CloudOfflineAccessBlockReason? {
        blockReason(conditions: CloudOfflineAccessConditions(
            selection: selection, mountState: mountState,
            hasExactCompleteStorePair: hasExactCompleteStorePair,
            hasPendingTransfer: hasPendingTransfer,
            hasPendingRemoteIntent: hasPendingRemoteIntent,
            isSchemaValid: isSchemaValid), receipt: receipt)
    }

    static func blockReason(
        conditions: CloudOfflineAccessConditions,
        receipt: CloudOfflineAccessReceipt?
    ) -> CloudOfflineAccessBlockReason? {
        if let reason = storeBlockReason(conditions: conditions) { return reason }
        guard case let .selected(.cloud(binding)) = conditions.selection else { return .cloudNotSelected }
        guard let receipt else { return .missingReceipt }
        guard (try? receipt.validate()) != nil else { return .invalidReceipt }
        guard receipt.binding == binding else { return .bindingMismatch }
        if let reason = receipt.revocation { return .revoked(reason) }
        guard receipt.origin == .verifiedOnline || receipt.origin == .legacySuccessfulMount else {
            return .onlineBaselineMissing
        }
        return nil
    }

    /// An older version's exact successful mount can authorize an unpublished
    /// `.none` reader for migration. Any new-format receipt, including a
    /// revocation, must use the ordinary policy and cannot be adopted again.
    static func legacyAdoptionBlockReason(
        conditions: CloudOfflineAccessConditions,
        receipt: CloudOfflineAccessReceipt?
    ) -> CloudOfflineAccessBlockReason? {
        if let reason = storeBlockReason(conditions: conditions) { return reason }
        guard receipt == nil else { return .existingReceipt }
        return nil
    }

    /// This is only the lineage comparison after a fresh, complete Runtime
    /// server preflight. Account, lease, pending-transfer and reset-history
    /// checks remain mandatory before constructing any mirroring container.
    static func matchesVerifiedDataset(
        receipt: CloudOfflineAccessReceipt,
        datasetGenerationID: UUID?
    ) -> Bool {
        guard (try? receipt.validate()) != nil else { return false }
        if receipt.isDatasetGenerationKnown {
            return receipt.datasetGenerationID == datasetGenerationID
        }
        return receipt.origin == .legacySuccessfulMount && datasetGenerationID == nil
    }

    private static func storeBlockReason(
        conditions: CloudOfflineAccessConditions
    ) -> CloudOfflineAccessBlockReason? {
        if conditions.selection == .invalid { return .invalidSelection }
        guard case let .selected(.cloud(binding)) = conditions.selection else { return .cloudNotSelected }
        guard case let .mounted(mounted) = conditions.mountState else { return .mountNotRecorded }
        guard mounted == .cloud(binding: binding) else { return .mountMismatch }
        guard conditions.hasExactCompleteStorePair else { return .incompleteStorePair }
        guard !conditions.hasPendingTransfer else { return .pendingTransfer }
        guard !conditions.hasPendingRemoteIntent else { return .pendingRemoteIntent }
        guard conditions.isSchemaValid else { return .invalidSchema }
        return nil
    }
}
