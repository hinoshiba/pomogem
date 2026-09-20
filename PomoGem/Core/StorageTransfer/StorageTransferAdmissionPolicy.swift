import Foundation

/// The outcome of comparing this installation's dataset admission receipt with
/// the lineage the server actually reports.
///
/// Before this type existed the comparison was a single `Equatable` `!=` over
/// the whole `StorageTransferDatasetAdmission` struct, so four unrelated states
/// - a genuine remote replacement, a server with no transfer ledger at all, a
/// local ledger that never recorded the current generation, and a binding
/// difference - all raised one error whose text claimed another device had
/// replaced the iCloud data. Five of those six code paths could be reached with
/// a single device, and the claim was then simply false.
enum StorageTransferAdmissionDecision: Equatable {
    /// The receipt already matches the observed lineage; nothing is written.
    case admitted
    /// No receipt for this binding: the caller enrols into the current lineage
    /// after proving there is no stale local cache.
    case enrol
    /// The lineage matches but the receipt has to be rewritten, e.g. so it
    /// records which CloudKit environment it was earned in.
    case rescope(StorageTransferDatasetAdmission)
    /// Fail closed. The associated error names WHICH of the states above was
    /// observed, so the copy can stop guessing.
    case refuse(StorageTransferRuntimeError)
}

/// Pure classification, deliberately free of files, CloudKit and the runtime,
/// so every combination can be pinned by a unit test.
enum StorageTransferAdmissionPolicy {
    /// - Parameters:
    ///   - found: the receipt loaded for `binding`, or nil when absent.
    ///   - scope: the container/environment this build actually talks to.
    ///   - serverGenerationID: `StorageTransferRecoveryControl.datasetGenerationID`
    ///     of the observed control, or nil when the server has no committed
    ///     lineage at all - either because the control record is absent, or
    ///     because it is terminal with no predecessor. The caller has already
    ///     refused every non-terminal control with `remoteRecoveryRequired`,
    ///     so nil here always means "this database has no transfer ledger",
    ///     never "the read failed" (the transport throws in that case).
    static func decide(found: StorageTransferDatasetAdmission?,
                       binding: ActiveAccountLocalBinding,
                       scope: StorageTransferCloudScope,
                       serverGenerationID: UUID?) -> StorageTransferAdmissionDecision {
        guard let found else { return .enrol }
        // Structurally unreachable: the receipt is filed under its own
        // namespace and a changed account is blocked by the namespace registry
        // long before any preflight. Kept fail-closed, and kept on the legacy
        // error so it is obvious this arm was never part of the taxonomy.
        guard found.binding == binding else { return .refuse(.datasetRefreshRequired) }
        let recorded = found.cloudScope ?? .unknown
        // A generation identifies a lineage only WITHIN one container
        // environment. Two builds of the same bundle id that talk to different
        // environments hold two unrelated databases, and one's receipt says
        // nothing about the other's ledger.
        if recorded.isProvenDifferent(from: scope) { return .refuse(.cloudEnvironmentMismatch) }
        guard found.datasetGenerationID == serverGenerationID else {
            // Absence of a server ledger is not a replacement: there is no
            // other record to have replaced this one with.
            if serverGenerationID == nil { return .refuse(.cloudLineageUnavailable) }
            return .refuse(.datasetReplacedRemotely)
        }
        guard recorded == scope else {
            // Only a KNOWN scope is ever written; `recorded == scope` already
            // holds when both are unknown, so this arm means "the receipt can
            // finally be pinned to the environment that earned it".
            return .rescope(StorageTransferDatasetAdmission(binding: binding,
                datasetGenerationID: serverGenerationID, cloudScope: scope))
        }
        return .admitted
    }
}
