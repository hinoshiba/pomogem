import Foundation

/// A row graph alone cannot authorize a mount or promotion: another transfer
/// may publish the same rows under a different dataset generation. The baseline
/// is immutable transaction evidence, including an explicitly observed nil.
enum StorageTransferCloudAuthorityFence {
    static func validate(
        observed: StorageTransferRecoveryControl?,
        journal: StorageTransferJournal,
        checkpoint: StorageTransferRuntimeCheckpoint
    ) throws {
        try checkpoint.validate(journal: journal)
        try observed?.validate()
        if let observed,
           observed.manifest.accountFingerprint != journal.cloudBinding.accountFingerprint {
            throw StorageTransferRuntimeError.remoteRecoveryRequired
        }

        // Disable, cloud-authoritative enable, and stale-cache refresh do not
        // own the control record. They cannot adopt a later transaction merely
        // because it is terminal or has an equivalent data graph.
        guard journal.choice.replacesCloud else {
            guard observed == checkpoint.baselineControl else {
                throw StorageTransferRuntimeError.remoteRecoveryRequired
            }
            return
        }

        guard let manifest = checkpoint.recoveryManifest else {
            guard observed == checkpoint.baselineControl else {
                throw StorageTransferRuntimeError.remoteRecoveryRequired
            }
            return
        }
        // Manifest persistence precedes stage creation. Only this unclaimed
        // window may still observe the original nil/terminal control. A prior
        // cancelled baseline is legitimate and retains its older generation.
        if journal.phase <= .sourceSaved, observed == checkpoint.baselineControl { return }
        guard let observed, observed.manifest == manifest else {
            throw StorageTransferRuntimeError.remoteRecoveryRequired
        }
        switch observed.phase {
        case .staging, .backupVerified, .replacing:
            return
        case .committed:
            guard journal.phase >= .destinationVerified,
                  observed.datasetGenerationID == manifest.transactionID else {
                throw StorageTransferRuntimeError.remoteRecoveryRequired
            }
        case .cancelled:
            throw StorageTransferRuntimeError.remoteRecoveryRequired
        }
    }
}
