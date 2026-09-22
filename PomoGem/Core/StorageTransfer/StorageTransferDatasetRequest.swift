import Darwin
import Foundation

/// Which dataset the user confirmed should be replaced, recorded from Settings.
///
/// Settings runs inside a mounted cloud session, and by then this process has
/// already opened the CloudKit mirror. Both dataset entry points
/// (`refreshCloudDataset`, `overwriteCloudDataset`) refuse such a process on
/// purpose — `StorageTransferProcessState.cloudMirrorWasOpened` has no reset
/// API, because a mirrored container may still be writing. A Settings door can
/// therefore not execute its own direction; it records this durable request and
/// asks for the deliberate relaunch the rest of the feature already uses. The
/// launch host consumes it before any container exists and runs the SAME entry
/// point the recovery screen runs. One code path, one journal shape, one gate.
enum StorageTransferDatasetRequestDirection: String, Codable, Equatable, Sendable {
    /// Device -> iCloud. Routed to `StorageTransferRuntime.overwriteCloudDataset`.
    case overwriteCloudFromDevice
    /// iCloud -> device. Routed to the EXISTING
    /// `StorageTransferRuntime.refreshCloudDataset`, the exact operation and
    /// journal 「iCloudから再取得」 already performs on the recovery screen. It
    /// introduces no journal shape and no policy bit: it does not replace the
    /// iCloud dataset, so none of the three release bits is its fence.
    case refreshFromCloud
}

/// The read-only evidence the Settings 「最後の確認」 shows before a device -> iCloud
/// overwrite is acknowledged.
///
/// PLAN §3 S14: nobody may authorize deleting contents the app never
/// enumerated, and the launch screen already refuses to arm its door until the
/// server has been read and both sides are on screen. Settings must show the
/// same two facts — what is on each side, and whether another device has
/// written here — BEFORE the acknowledgement, not after it.
struct StorageTransferDatasetPreviewSummary: Equatable, Sendable {
    /// What the server holds. Always present: the door does not open without it.
    let cloud: StorageTransferCloudPreview
    /// This installation's own stores, for the comparison row. nil degrades the
    /// device side to 「確認できませんでした」 and never gates anything: failing to
    /// read this iPhone is not a reason to refuse to describe what would be
    /// destroyed on the server.
    let device: StorageTransferCloudPreview?
    /// W6. False when the server has records but NO transfer control record,
    /// which is the ordinary state of an account that was never transferred.
    /// The comparison then says so instead of printing a 「最終」 row that
    /// implies a lineage the server does not have, and the confirmation adds
    /// the paragraph that describes what each direction does without one.
    var hasCloudLineage = true
}

enum StorageTransferDatasetRequestError: Error, LocalizedError, Equatable {
    /// A transfer is in flight on the server (the control record exists and is
    /// not terminal), so this device may not record a direction of its own:
    /// the launch fence owns that state and will present the recovery screen.
    ///
    /// It no longer covers "the account has no control record at all". W6: most
    /// healthy single-generation accounts have none, and refusing both doors
    /// for that reason made the Settings feature unusable for exactly the
    /// accounts that are FINE. A nil lineage is now carried as nil and
    /// dispatched to the entry point that requires its absence.
    case transferInFlight

    var errorDescription: String? {
        switch self {
        case .transferInFlight:
            "iCloudで未完了のデータ切り替えが進んでいるため、この操作はまだ実行できません。完了してから、もう一度お試しください。どちらの記録も削除していません。"
        }
    }
}

/// A single-shot, durable record of a confirmed Settings direction.
///
/// It authorizes nothing by itself. Everything it carries is re-verified by the
/// runtime entry point that executes it: the account boundary is resolved
/// again, the control record is read twice, and `datasetGenerationID` must
/// still be the committed generation or the request fails the CAS and is
/// refused. Its only job is to survive exactly one deliberate relaunch.
struct StorageTransferDatasetRequest: Codable, Equatable, Sendable {
    static let currentFormatVersion = 2

    var formatVersion = Self.currentFormatVersion
    let direction: StorageTransferDatasetRequestDirection
    /// The cloud binding Settings was mounted against. A request is ignored
    /// unless the next launch selects exactly this binding.
    let binding: ActiveAccountLocalBinding
    /// A relaunch can also install a different build of the same bundle. The
    /// account and namespace survive that install, but Development and
    /// Production contain unrelated datasets. Consent names this database too.
    let cloudScope: StorageTransferCloudScope
    /// The committed generation the user was shown, or nil when the account
    /// had no transfer ledger at all and the screen said so. A dataset that
    /// moved on between the confirmation and the relaunch fails the CAS rather
    /// than replacing something nobody saw; a nil is likewise re-proved by the
    /// entry point it dispatches to (`startCloudLineageFromDevice` /
    /// `refreshCloudDatasetWithoutLineage`), both of which refuse the moment
    /// any committed generation exists.
    let datasetGenerationID: UUID?
    let requestedAt: Date
    /// Diagnostic only. The executing process is deliberately a different one.
    let requestingProcessID: UUID

    init(formatVersion: Int = Self.currentFormatVersion,
         direction: StorageTransferDatasetRequestDirection,
         binding: ActiveAccountLocalBinding,
         cloudScope: StorageTransferCloudScope,
         datasetGenerationID: UUID?,
         requestedAt: Date,
         requestingProcessID: UUID) {
        self.formatVersion = formatVersion
        self.direction = direction
        self.binding = binding
        self.cloudScope = cloudScope
        self.datasetGenerationID = datasetGenerationID
        self.requestedAt = requestedAt
        self.requestingProcessID = requestingProcessID
    }

    func validate() throws {
        guard formatVersion == Self.currentFormatVersion, cloudScope.isKnown,
              AppleAccountFingerprint.isValid(binding.accountFingerprint) else {
            throw StorageTransferError.invalidJournal
        }
    }

    /// The launch host must be mounting this exact account, namespace and
    /// CloudKit database. A request for another scope is dropped, never
    /// translated; legacy requests cannot establish that scope either.
    func authorizes(binding candidate: ActiveAccountLocalBinding,
                    cloudScope candidateScope: StorageTransferCloudScope) -> Bool {
        formatVersion == Self.currentFormatVersion && binding == candidate
            && cloudScope.isKnown && cloudScope == candidateScope
    }
}

/// Which runtime entry point a consumed request runs. Pure and exhaustive, so
/// the nil-lineage dispatch — the whole point of W6 — is provable without a
/// container, an account or a CloudKit call.
enum StorageTransferDatasetDispatch: Equatable, Sendable {
    case overwriteCloudDataset(expectedGenerationID: UUID)
    /// Device → iCloud with no ledger to fence against. Same policy bit.
    case startCloudLineageFromDevice
    case refreshCloudDataset(expectedGenerationID: UUID)
    /// iCloud → device with no ledger to fence against. No policy bit, for
    /// the same reason the generation-fenced refresh has none.
    case refreshCloudDatasetWithoutLineage
}

extension StorageTransferDatasetRequest {
    /// nil when this request does not authorize `binding`. A request written
    /// for another binding is dropped, never translated.
    ///
    /// The generation is carried, not trusted: each entry point re-reads the
    /// control record and refuses — a `.some` that no longer matches fails the
    /// CAS, and a `.none` that has since become a lineage is refused outright.
    func dispatch(for binding: ActiveAccountLocalBinding,
                  cloudScope: StorageTransferCloudScope) -> StorageTransferDatasetDispatch? {
        guard authorizes(binding: binding, cloudScope: cloudScope) else { return nil }
        switch (direction, datasetGenerationID) {
        case let (.overwriteCloudFromDevice, .some(generation)):
            return .overwriteCloudDataset(expectedGenerationID: generation)
        case (.overwriteCloudFromDevice, .none):
            return .startCloudLineageFromDevice
        case let (.refreshFromCloud, .some(generation)):
            return .refreshCloudDataset(expectedGenerationID: generation)
        case (.refreshFromCloud, .none):
            return .refreshCloudDatasetWithoutLineage
        }
    }
}

/// The Settings surface gate.
///
/// It is NOT a second safety fence for direction (A): `overwriteCloudDataset`
/// validates `.overwriteCloudFromDevice` against the release policy as its very
/// first statement, and that remains the fence. This gate exists so a closed
/// feature cannot record a durable request at all, and so the Settings screen
/// and the host agree on one answer about what is published.
enum StorageTransferDatasetRequestPolicy {
    static func validate(_ direction: StorageTransferDatasetRequestDirection,
                         policy: StorageTransferReleasePolicy) throws {
        switch direction {
        case .overwriteCloudFromDevice:
            try policy.validate(.overwriteCloudFromDevice)
        case .refreshFromCloud:
            // No bit. PLAN Step 12: this direction discards the DEVICE side and
            // replaces nothing on the server, so none of the three release bits
            // is its fence — and the recovery screen already runs the identical
            // `refreshCloudDataset` with no release check at all. Coupling it
            // to `allowsDatasetOverwriteFromDevice` would make a non-destructive
            // operation unusable in Settings purely because its destructive
            // opposite is unpublished, which is the one direction the user must
            // always be able to take on a device they want to re-sync.
            return
        }
    }
}

/// Owns the one request file. It lives beside `admission-*.json` in the feature
/// root and is deliberately NOT namespaced: the launch host consumes it before
/// it has resolved an account namespace, so the request has to name its own.
@MainActor
struct StorageTransferDatasetRequestStore {
    static let fileName = "dataset-request.json"

    private let file: StorageTransferStateFile<StorageTransferDatasetRequest>

    init(root: URL) throws {
        file = try StorageTransferStateFile(url: root.appendingPathComponent(Self.fileName))
    }

    /// Throws for a request this build cannot understand, so a caller that
    /// wants to display one is never given a guess.
    func load() throws -> StorageTransferDatasetRequest? {
        guard let request = try file.load() else { return nil }
        try request.validate()
        return request
    }

    func record(_ request: StorageTransferDatasetRequest) throws {
        try request.validate()
        let previous: StorageTransferDatasetRequest?
        do {
            previous = try file.load()
        } catch {
            // An unreadable leftover is removed rather than reinterpreted. It
            // can only ever have been another confirmed request of ours, and
            // the newest confirmation is the one the user just gave.
            try file.removeReceipt()
            previous = nil
        }
        try file.save(request, replacing: previous)
    }

    /// Reads the request and deletes it in the same breath, whatever it held.
    /// Single-shot by construction: a crash while executing one can never
    /// replay it, and a malformed one can never be retried forever. Nothing
    /// destructive has happened at this point, so dropping is always safe.
    func consume() throws -> StorageTransferDatasetRequest? {
        let loaded: StorageTransferDatasetRequest?
        do { loaded = try file.load() } catch { loaded = nil }
        try? file.removeReceipt()
        guard let loaded, (try? loaded.validate()) != nil else { return nil }
        return loaded
    }
}

extension StorageTransferRuntime {
    func datasetRequestStore() throws -> StorageTransferDatasetRequestStore {
        try StorageTransferDatasetRequestStore(root: featureRoot)
    }

    func pendingDatasetRequest() throws -> StorageTransferDatasetRequest? {
        try datasetRequestStore().load()
    }

    func recordDatasetRequest(_ request: StorageTransferDatasetRequest) throws {
        try datasetRequestStore().record(request)
    }

    func consumeDatasetRequest() throws -> StorageTransferDatasetRequest? {
        try datasetRequestStore().consume()
    }
}
