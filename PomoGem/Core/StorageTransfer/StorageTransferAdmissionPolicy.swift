import Darwin
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
    ///   - otherScopeReceipts: receipts filed for this same namespace under a
    ///     DIFFERENT environment's file name. They are the only evidence this
    ///     build has that the namespace's lineage belongs somewhere else: the
    ///     receipt a build reads is chosen by file name, so without this the
    ///     other environment is simply invisible and `decide` would enrol.
    static func decide(found: StorageTransferDatasetAdmission?,
                       binding: ActiveAccountLocalBinding,
                       scope: StorageTransferCloudScope,
                       serverGenerationID: UUID?,
                       otherScopeReceipts: [StorageTransferDatasetAdmission] = [])
        -> StorageTransferAdmissionDecision {
        // Consulted only while this build has no environment-proven receipt of
        // its own. A receipt that already names THIS scope is authoritative for
        // this database, and a leftover receipt from another environment must
        // not block a device that is correctly enrolled here.
        if (found?.cloudScope?.isKnown ?? false) == false,
           otherScopeReceipts.contains(where: {
               ($0.cloudScope ?? .unknown).isProvenDifferent(from: scope)
           }) {
            // Enrolling here would mirror every row this device holds into a
            // database that never held them, with no prompt - the same effect
            // as `startCloudLineageFromDevice`, which is fenced behind an
            // explicit choice and a closed policy bit. Refuse and explain.
            return .refuse(.cloudEnvironmentMismatch)
        }
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

/// What this device remembers about its own cloud store, read by the launch
/// host just before the preflight. The adoption rule below is pure; this value
/// is the only thing it knows about the device.
///
/// 1.0 and 1.0.1 never wrote an admission receipt, but they did mount this
/// very Production mirror at this very store path and recorded that mount.
/// These three facts are how such a store is told apart from one that never
/// mirrored this zone.
struct StorageTransferLegacyCloudMountEvidence: Equatable, Sendable {
    /// The selection is `.cloud(binding)` AND a previous build recorded a
    /// successful mount of exactly that selection.
    let recordedCloudMountOfThisBinding: Bool
    /// The exact, complete store pair for `.cloud(binding)` is on disk.
    let hasExactCompleteStorePair: Bool
    /// The offline receipt shows that a receipt-writing build (1.0.2 or
    /// later) already verified this installation online, or recorded a known
    /// dataset generation. Such an installation must hold an admission
    /// receipt; its absence is then NOT the pre-receipt shape. A receipt that
    /// cannot be read counts as true, so an unreadable file fails closed.
    let offlineReceiptPostdatesAdmissionReceipts: Bool

    /// What every caller that does not explicitly gather evidence passes, so
    /// the adoption rule can never apply by default.
    static let none = Self(recordedCloudMountOfThisBinding: false,
                           hasExactCompleteStorePair: false,
                           offlineReceiptPostdatesAdmissionReceipts: false)
}

/// The one narrow exception to "enrolment always requires an empty store
/// path" (Docs/MultiDeviceCloudSafety.md). It restores 1.0.2's behaviour for
/// installations that 1.0 / 1.0.1 set up in iCloud mode and that never ran a
/// receipt-writing build online: 1.0.2 enrolled them with a nil generation;
/// 1.1.0 before this rule sent them to the lineage stop screen on every online
/// launch, with no enabled way back to sync.
///
/// Joining the zone publishes nothing new for such a store: it has only ever
/// mirrored this binding's Production zone. Every condition below must hold;
/// any other enrolment keeps the store-artifact precondition.
enum StorageTransferLegacyCloudAdoptionPolicy {
    /// - Parameters:
    ///   - scope: the environment THIS build talks to. Only Production: 1.0 and
    ///     1.0.1 were only ever distributed as Production builds, and a
    ///     Development build on a developer's phone keeps failing closed.
    ///   - hasAdmissionReceiptUnderAnyName: a receipt exists for this namespace
    ///     under the scoped, the unscoped legacy or another environment's name.
    ///     Any receipt means a receipt-writing build has been here.
    ///   - serverControl: the control record as read. It must be ABSENT, not
    ///     merely terminal with a nil generation: a terminal control proves a
    ///     transfer happened on this account after 1.0.1.
    ///   - evidence: the device's own record of having mirrored this binding.
    static func adoptsPreReceiptStore(scope: StorageTransferCloudScope,
                                      hasAdmissionReceiptUnderAnyName: Bool,
                                      serverControl: StorageTransferRecoveryControl?,
                                      evidence: StorageTransferLegacyCloudMountEvidence) -> Bool {
        guard scope.isKnown, scope.environment == .production,
              !hasAdmissionReceiptUnderAnyName,
              serverControl == nil else { return false }
        return evidence.recordedCloudMountOfThisBinding
            && evidence.hasExactCompleteStorePair
            && !evidence.offlineReceiptPostdatesAdmissionReceipts
    }
}

/// The "no store files may exist here" precondition, extracted from the
/// runtime so each call site's meaning is separately expressible and testable.
///
/// It used to raise `datasetRefreshRequired` everywhere, which is how merely
/// enabling iCloud from Settings - with an old cloud store left over from a
/// previous stint on this same device - could tell the user that another
/// device had replaced their iCloud data while the server was untouched.
@MainActor
enum StorageTransferStoreArtifactPrecondition {
    static func requireNone(selection: PersistenceDeploymentSelection,
                            error: StorageTransferRuntimeError) throws {
        let urls = try PersistenceStoreTopology.persistentStoreURLs(for: selection.storageLaunchMode,
            accountNamespace: selection.storageNamespace)
        for url in urls.flatMap({ PersistenceStoreArtifactLayout.artifacts(for: $0) }) {
            var info = stat()
            guard lstat(url.path, &info) != 0, errno == ENOENT else { throw error }
        }
    }
}

extension StorageTransferLegacyCloudMountEvidence {
    /// The live reading, taken by the launch host immediately before a cloud
    /// preflight. Every input is this device's own record of a PREVIOUS launch
    /// and none of them authorizes anything alone: the policy above still
    /// requires a Production build, no receipt under any name and an absent
    /// control record, and the preflight still re-reads that control record.
    @MainActor
    static func live(binding: ActiveAccountLocalBinding) -> Self {
        read(binding: binding, defaults: .standard,
             artifactHistory: { PersistenceStoreTopology.persistenceArtifactHistory() },
             offlineReceipt: { try CloudOfflineAccessState().load() })
    }

    /// `live` with its three sources injected, so the rescue of real 1.0 /
    /// 1.0.1 installations can be checked against the exact on-disk shape
    /// those builds left: their `UserDefaults` keys, their store files and no
    /// offline receipt at all. An injected `UserDefaults` suite never consults
    /// the installation's committed-transfer receipt
    /// (`PersistenceDeploymentState.transferredSelection`).
    @MainActor
    static func read(binding: ActiveAccountLocalBinding,
                     defaults: UserDefaults,
                     artifactHistory: () -> PersistenceArtifactHistory,
                     offlineReceipt: () throws -> CloudOfflineAccessReceipt?) -> Self {
        let selection = PersistenceDeploymentSelection.cloud(binding: binding)
        let recordedMount = PersistenceDeploymentState.load(defaults: defaults) == .selected(selection)
            && PersistenceDeploymentState.loadMountState(defaults: defaults) == .mounted(selection)
        let hasPair = artifactHistory().hasExactCompleteStorePair(for: selection)
        let postdates: Bool
        do {
            postdates = try offlineReceipt().map(offlineReceiptPostdatesAdmissionReceipts) ?? false
        } catch {
            postdates = true
        }
        return Self(recordedCloudMountOfThisBinding: recordedMount,
                    hasExactCompleteStorePair: hasPair,
                    offlineReceiptPostdatesAdmissionReceipts: postdates)
    }

    /// A `.verifiedOnline` receipt is only ever written after an online mount
    /// that itself wrote an admission receipt (1.0.2 and later), and a known
    /// generation means an admission receipt was read when it was recorded.
    /// Either one means this installation is past the pre-receipt shape.
    /// 1.0 / 1.0.1 wrote no offline receipt at all; 1.1.0's offline door on
    /// such a store adopts it as `.legacySuccessfulMount` with an unknown
    /// generation, which does not count.
    static func offlineReceiptPostdatesAdmissionReceipts(_ receipt: CloudOfflineAccessReceipt) -> Bool {
        receipt.hasVerifiedOnlineBaseline || receipt.isDatasetGenerationKnown
    }
}
