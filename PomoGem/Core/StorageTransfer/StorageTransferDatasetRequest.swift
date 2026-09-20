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
}

enum StorageTransferDatasetRequestError: Error, LocalizedError, Equatable {
    /// The account has no terminal control record, so there is no committed
    /// generation to compare against. Without one the CAS that protects a
    /// dataset from being replaced out from under a newer generation cannot be
    /// formed, and nothing may be recorded.
    case noCommittedGeneration

    var errorDescription: String? {
        switch self {
        case .noCommittedGeneration:
            "iCloudのデータの世代を確認できないため、この操作はまだ実行できません。通信を確認してからもう一度お試しください。どちらの記録も削除していません。"
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
    static let currentFormatVersion = 1

    var formatVersion = Self.currentFormatVersion
    let direction: StorageTransferDatasetRequestDirection
    /// The cloud binding Settings was mounted against. A request is ignored
    /// unless the next launch selects exactly this binding.
    let binding: ActiveAccountLocalBinding
    /// The committed generation the user was shown. A dataset that moved on
    /// between the confirmation and the relaunch fails the CAS rather than
    /// replacing something nobody saw.
    let datasetGenerationID: UUID
    let requestedAt: Date
    /// Diagnostic only. The executing process is deliberately a different one.
    let requestingProcessID: UUID

    init(formatVersion: Int = Self.currentFormatVersion,
         direction: StorageTransferDatasetRequestDirection,
         binding: ActiveAccountLocalBinding,
         datasetGenerationID: UUID,
         requestedAt: Date,
         requestingProcessID: UUID) {
        self.formatVersion = formatVersion
        self.direction = direction
        self.binding = binding
        self.datasetGenerationID = datasetGenerationID
        self.requestedAt = requestedAt
        self.requestingProcessID = requestingProcessID
    }

    func validate() throws {
        guard formatVersion == Self.currentFormatVersion,
              AppleAccountFingerprint.isValid(binding.accountFingerprint) else {
            throw StorageTransferError.invalidJournal
        }
    }

    /// The launch host must be mounting this exact account and namespace. A
    /// request written for another binding is dropped, never translated.
    func authorizes(binding candidate: ActiveAccountLocalBinding) -> Bool {
        binding == candidate
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
