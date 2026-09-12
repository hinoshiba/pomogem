import CryptoKit
import Foundation

/// The adapter must use the private database of the synchronized container,
/// and this exact current-owner zone. Neither this API nor its coordinator has
/// a model-store or zone-deletion operation. Only explicitly cancelled or
/// committed transactions can authorize deletion of their exact backup chunks.
enum StorageTransferRecoverySchema {
    static let zoneName = StorageTransferCloudSchema.zoneName
    static let controlRecordType = "PomoGemStorageTransferControl"
    static let chunkRecordType = "PomoGemStorageTransferChunk"
    static let controlRecordName = "control-v1"
    static let maximumChunkBytes = 8 * 1_024 * 1_024
    static let maximumPayloadBytes = 128 * 1_024 * 1_024
    static let maximumChunks = 256

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

enum StorageTransferRecoveryError: Error, LocalizedError, Equatable {
    case invalidManifest, invalidControl, limitExceeded, identityMismatch
    case conflictingTransaction, staleControl, missingChunk, corruptChunk
    case incompleteBackup, destinationMismatch

    var errorDescription: String? {
        "iCloudの復旧用コピーを安全に確認できません。接続状態を確認して、保存先の切り替えを再試行してください。"
    }
}

/// Immutable, canonical ordering of the exact frozen snapshot bytes. Account
/// identity is independent of an installation's local storage namespace, so a
/// fresh installation can recover the original transaction without rebinding it.
struct StorageTransferRecoveryManifest: Codable, Equatable, Sendable {
    struct Chunk: Codable, Equatable, Sendable {
        let index: Int
        let byteCount: Int
        let sha256: String
    }

    let formatVersion: Int
    let payloadFormat: String
    let transactionID: UUID
    let accountFingerprint: String
    /// The last committed dataset survives a later cancelled transaction.
    let previousDatasetGenerationID: UUID?
    let payloadByteCount: Int
    let payloadSHA256: String
    let chunkByteLimit: Int
    let chunks: [Chunk]

    init(transactionID: UUID, accountFingerprint: String, payload: Data,
         chunkByteLimit: Int = StorageTransferRecoverySchema.maximumChunkBytes,
         previousDatasetGenerationID: UUID? = nil) throws {
        guard !payload.isEmpty,
              payload.count <= StorageTransferRecoverySchema.maximumPayloadBytes,
              chunkByteLimit > 0,
              chunkByteLimit <= StorageTransferRecoverySchema.maximumChunkBytes else {
            throw StorageTransferRecoveryError.limitExceeded
        }
        let count = (payload.count - 1) / chunkByteLimit + 1
        guard count <= StorageTransferRecoverySchema.maximumChunks else {
            throw StorageTransferRecoveryError.limitExceeded
        }
        formatVersion = 1
        payloadFormat = "PomoGemStorageSnapshot-v1"
        self.transactionID = transactionID
        self.accountFingerprint = accountFingerprint
        self.previousDatasetGenerationID = previousDatasetGenerationID
        payloadByteCount = payload.count
        payloadSHA256 = StorageTransferRecoverySchema.digest(payload)
        self.chunkByteLimit = chunkByteLimit
        chunks = (0..<count).map { index in
            let start = index * chunkByteLimit
            let bytes = payload.subdata(in: start..<min(start + chunkByteLimit, payload.count))
            return Chunk(index: index, byteCount: bytes.count,
                         sha256: StorageTransferRecoverySchema.digest(bytes))
        }
        try validate()
    }

    func validate() throws {
        guard formatVersion == 1, payloadFormat == "PomoGemStorageSnapshot-v1",
              previousDatasetGenerationID != transactionID,
              StorageTransferRecoverySchema.isDigest(accountFingerprint),
              StorageTransferRecoverySchema.isDigest(payloadSHA256),
              payloadByteCount > 0,
              payloadByteCount <= StorageTransferRecoverySchema.maximumPayloadBytes,
              chunkByteLimit > 0,
              chunkByteLimit <= StorageTransferRecoverySchema.maximumChunkBytes,
              !chunks.isEmpty, chunks.count <= StorageTransferRecoverySchema.maximumChunks,
              chunks.count == (payloadByteCount - 1) / chunkByteLimit + 1 else {
            throw StorageTransferRecoveryError.invalidManifest
        }
        var total = 0
        for (index, chunk) in chunks.enumerated() {
            let expected = min(chunkByteLimit, payloadByteCount - total)
            guard chunk.index == index, chunk.byteCount == expected,
                  chunk.byteCount > 0,
                  StorageTransferRecoverySchema.isDigest(chunk.sha256) else {
                throw StorageTransferRecoveryError.invalidManifest
            }
            total += chunk.byteCount
        }
        guard total == payloadByteCount else { throw StorageTransferRecoveryError.invalidManifest }
    }

    func validate(payload: Data) throws {
        try validate()
        guard payload.count == payloadByteCount,
              StorageTransferRecoverySchema.digest(payload) == payloadSHA256 else {
            throw StorageTransferRecoveryError.incompleteBackup
        }
        for descriptor in chunks { _ = try chunk(descriptor.index, from: payload) }
    }

    func chunk(_ index: Int, from payload: Data) throws -> StorageTransferRecoveryChunk {
        try validate()
        guard chunks.indices.contains(index), payload.count == payloadByteCount else {
            throw StorageTransferRecoveryError.invalidManifest
        }
        let start = index * chunkByteLimit
        let descriptor = chunks[index]
        let result = StorageTransferRecoveryChunk(transactionID: transactionID,
            accountFingerprint: accountFingerprint, payloadSHA256: payloadSHA256,
            index: index, bytes: payload.subdata(in: start..<(start + descriptor.byteCount)))
        try result.validate(manifest: self, index: index)
        return result
    }
}

struct StorageTransferRecoveryChunk: Equatable, Sendable {
    let transactionID: UUID
    let accountFingerprint: String
    let payloadSHA256: String
    let index: Int
    /// A live adapter stores these bytes only in a private CKAsset. Its bounded
    /// file reader must reject missing, oversized, or nonregular asset files.
    let bytes: Data

    var recordName: String { "chunk-\(transactionID.uuidString.lowercased())-\(index)" }

    func validate(manifest: StorageTransferRecoveryManifest, index expectedIndex: Int) throws {
        try manifest.validate()
        guard transactionID == manifest.transactionID,
              accountFingerprint == manifest.accountFingerprint,
              payloadSHA256 == manifest.payloadSHA256, index == expectedIndex,
              manifest.chunks.indices.contains(index) else {
            throw StorageTransferRecoveryError.identityMismatch
        }
        let descriptor = manifest.chunks[index]
        guard bytes.count == descriptor.byteCount,
              bytes.count <= StorageTransferRecoverySchema.maximumChunkBytes,
              StorageTransferRecoverySchema.digest(bytes) == descriptor.sha256 else {
            throw StorageTransferRecoveryError.corruptChunk
        }
    }
}

struct StorageTransferRecoveryControl: Codable, Equatable, Sendable {
    enum Phase: Int, Codable, CaseIterable, Comparable, Sendable {
        case staging, backupVerified, replacing, committed, cancelled
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let formatVersion: Int
    let manifest: StorageTransferRecoveryManifest
    private(set) var phase: Phase
    private(set) var revision: Int
    private(set) var verifiedDestinationSHA256: String?
    private(set) var cancelledFrom: Phase?

    init(manifest: StorageTransferRecoveryManifest) throws {
        formatVersion = 1
        self.manifest = manifest
        phase = .staging
        revision = 0
        try validate()
    }

    var isTerminal: Bool { phase == .committed || phase == .cancelled }
    var blocksWriters: Bool { !isTerminal }
    var datasetGenerationID: UUID? {
        phase == .committed ? manifest.transactionID : manifest.previousDatasetGenerationID
    }
    var terminalReceiptRecordName: String {
        "receipt-\(manifest.transactionID.uuidString.lowercased())"
    }

    func validate() throws {
        try manifest.validate()
        let validRevision: Bool
        if phase == .cancelled {
            validRevision = (cancelledFrom == .staging || cancelledFrom == .backupVerified)
                && revision == (cancelledFrom?.rawValue ?? -2) + 1
        } else {
            validRevision = cancelledFrom == nil && revision == phase.rawValue
        }
        guard formatVersion == 1, validRevision,
              (phase == .committed) == (verifiedDestinationSHA256 != nil),
              verifiedDestinationSHA256.map({ $0 == manifest.payloadSHA256 }) ?? true else {
            throw StorageTransferRecoveryError.invalidControl
        }
    }

    func advancing(to next: Phase, verifiedDestinationSHA256: String? = nil) throws -> Self {
        try validate()
        guard next != .cancelled, !isTerminal,
              next.rawValue == phase.rawValue + 1 else { throw StorageTransferRecoveryError.staleControl }
        var value = self
        value.phase = next
        value.revision += 1
        value.verifiedDestinationSHA256 = verifiedDestinationSHA256
        try value.validate()
        return value
    }

    func cancelling() throws -> Self {
        try validate()
        guard phase == .staging || phase == .backupVerified else {
            throw StorageTransferRecoveryError.staleControl
        }
        var value = self
        value.cancelledFrom = phase
        value.phase = .cancelled
        value.revision += 1
        try value.validate()
        return value
    }
}

struct StorageTransferRecoveryEnvelope: Equatable, Sendable {
    let control: StorageTransferRecoveryControl
    /// The server's stable record revision, never a local sequence or lease.
    let changeTag: String
    /// A public CKRecord system-fields archive used only to reconstruct the
    /// server CAS token. Two archives of the same server revision need not have
    /// identical bytes. The live backend must verify their embedded change tag.
    let systemFieldsProof: String?

    init(control: StorageTransferRecoveryControl, changeTag: String, systemFieldsProof: String? = nil) {
        self.control = control
        self.changeTag = changeTag
        self.systemFieldsProof = systemFieldsProof
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.control == rhs.control && lhs.changeTag == rhs.changeTag
    }

    func validate() throws {
        try control.validate()
        guard !changeTag.isEmpty, changeTag.utf8.count <= 4_096,
              systemFieldsProof.map({ !$0.isEmpty && $0.utf8.count <= 4_096 }) ?? true else {
            throw StorageTransferRecoveryError.invalidControl
        }
    }
}

/// Required live semantics: all operations are bounded/cancellable; nil means
/// an authoritative record-not-found response (never permission/network errors).
/// Control writes use CKModifyRecordsOperation.savePolicy.ifServerRecordUnchanged,
/// including create-if-absent. Chunk and receipt saves are create-if-absent and
/// idempotent only when every field/byte matches; they must never overwrite a
/// conflicting existing record. Preserve receipts outside the framework zone.
/// Chunk deletion is an explicit operation requiring an immutable terminal
/// receipt and an exact chunk match; there is no timed lease takeover.
@MainActor
protocol StorageTransferRecoveryBackend {
    func verifyAccount(_ fingerprint: String) async throws
    func readControl() async throws -> StorageTransferRecoveryEnvelope?
    func compareAndSwapControl(_ control: StorageTransferRecoveryControl,
                               replacing: StorageTransferRecoveryEnvelope?) async throws -> StorageTransferRecoveryEnvelope
    func readChunk(manifest: StorageTransferRecoveryManifest, index: Int) async throws -> StorageTransferRecoveryChunk?
    func saveChunkIfAbsent(_ chunk: StorageTransferRecoveryChunk) async throws
    func retainTerminalReceipt(_ control: StorageTransferRecoveryControl) async throws
    func readTerminalReceipt(transactionID: UUID) async throws -> StorageTransferRecoveryControl?
    func deleteChunkIfMatches(_ chunk: StorageTransferRecoveryChunk,
                              terminalReceipt: StorageTransferRecoveryControl) async throws
}

/// An ephemeral proof from this coordinator. It authorizes only the separate
/// caller's exact, account-bound replacement transaction. It is not a lock
/// against old clients, a framework-zone deletion API, or a server manifest of
/// the replacement destination. Revalidate immediately before every effect.
struct StorageTransferRecoveryReceipt: Equatable, Sendable {
    let envelope: StorageTransferRecoveryEnvelope
    fileprivate init(_ envelope: StorageTransferRecoveryEnvelope) { self.envelope = envelope }
}

struct StorageTransferRecoveredPayload: Sendable {
    let envelope: StorageTransferRecoveryEnvelope
    let bytes: Data
}

@MainActor
struct StorageTransferRemoteRecovery {
    private let backend: any StorageTransferRecoveryBackend
    /// The caller must synchronously validate its monotonic account-change
    /// lease, active scene, and exact local journal after every suspension.
    private let validateAccess: () throws -> Void

    init(backend: any StorageTransferRecoveryBackend, validateAccess: @escaping () throws -> Void) {
        self.backend = backend
        self.validateAccess = validateAccess
    }

    /// Preserve the original account/scene lease while adding a caller's
    /// narrower journal generation check at every existing suspension guard.
    func withAdditionalValidation(_ additional: @escaping () throws -> Void) -> Self {
        Self(backend: backend) {
            try validateAccess()
            try additional()
        }
    }

    /// Run before constructing any mirrored ModelContainer. Every pending
    /// phase blocks normal writers, including on a fresh installation. A
    /// committed result still requires the caller's local receipt/import gate.
    /// A cancelled result permits mounting the unchanged old cloud data only
    /// after the caller reconciles its local pre-destructive transfer journal.
    func inspect(accountFingerprint: String) async throws -> StorageTransferRecoveryEnvelope? {
        try await verifyAccount(accountFingerprint)
        let result = try await checked { try await backend.readControl() }
        if let result {
            try result.validate()
            guard result.control.manifest.accountFingerprint == accountFingerprint else {
                throw StorageTransferRecoveryError.identityMismatch
            }
        }
        try await verifyAccount(accountFingerprint)
        return result
    }

    /// Repeating this call uses the original transaction ID and frozen bytes.
    /// A different pending transaction is never displaced. An explicitly named
    /// terminal predecessor can be replaced only after its separate immutable
    /// receipt has been acknowledged and read back.
    func stage(manifest: StorageTransferRecoveryManifest, payload: Data,
               replacingTerminalTransactionID: UUID? = nil) async throws -> StorageTransferRecoveryReceipt {
        try manifest.validate(payload: payload)
        var envelope = try await inspect(accountFingerprint: manifest.accountFingerprint)
        if let existing = envelope, existing.control.manifest != manifest {
            guard existing.control.isTerminal,
                  replacingTerminalTransactionID == existing.control.manifest.transactionID,
                  existing.control.manifest.transactionID != manifest.transactionID,
                  manifest.previousDatasetGenerationID == existing.control.datasetGenerationID else {
                throw StorageTransferRecoveryError.conflictingTransaction
            }
            try await retainReceipt(existing.control)
            try await requireUnusedTransaction(manifest)
            envelope = try await save(try StorageTransferRecoveryControl(manifest: manifest), replacing: existing)
        } else if envelope == nil {
            guard replacingTerminalTransactionID == nil, manifest.previousDatasetGenerationID == nil else {
                throw StorageTransferRecoveryError.staleControl
            }
            try await requireUnusedTransaction(manifest)
            envelope = try await save(try StorageTransferRecoveryControl(manifest: manifest), replacing: nil)
        }
        guard var current = envelope else { throw StorageTransferRecoveryError.invalidControl }
        try requireIdentity(current, manifest: manifest)
        // A terminal transaction cannot become a new upload, even after its
        // chunks were cleaned up. Retrying uses a new explicit transaction ID.
        guard !current.control.isTerminal else { throw StorageTransferRecoveryError.staleControl }
        if current.control.phase == .staging {
            for descriptor in manifest.chunks {
                try await requireCurrent(current)
                let expected = try manifest.chunk(descriptor.index, from: payload)
                if let found = try await checked({ try await backend.readChunk(manifest: manifest, index: descriptor.index) }) {
                    try found.validate(manifest: manifest, index: descriptor.index)
                } else {
                    try await verifyAccount(manifest.accountFingerprint)
                    try await checked { try await backend.saveChunkIfAbsent(expected) }
                }
            }
            _ = try await readPayload(current)
            current = try await save(current.control.advancing(to: .backupVerified), replacing: current)
        } else {
            _ = try await readPayload(current)
        }
        return StorageTransferRecoveryReceipt(current)
    }

    /// Recover only the exact transaction selected by the user/launch gate.
    /// Staging is readable only if all its chunks actually reached the server;
    /// otherwise the old cloud data remains intact and replacement stays closed.
    func recover(manifest: StorageTransferRecoveryManifest) async throws -> StorageTransferRecoveredPayload {
        let current = try await exactControl(manifest)
        guard !current.control.isTerminal else { throw StorageTransferRecoveryError.staleControl }
        return try await readPayload(current)
    }

    /// Explicit user cancellation needs no complete payload: an uninstall may
    /// have lost chunks that were never uploaded. The server CAS proves this
    /// transaction never crossed the replacement boundary. No data is deleted.
    func cancelBeforeReplacement(manifest: StorageTransferRecoveryManifest) async throws -> StorageTransferRecoveryReceipt {
        var current = try await exactControl(manifest)
        guard current.control.phase == .staging || current.control.phase == .backupVerified
                || current.control.phase == .cancelled else {
            throw StorageTransferRecoveryError.staleControl
        }
        if current.control.phase != .cancelled {
            current = try await save(current.control.cancelling(), replacing: current)
        }
        try await retainReceipt(current.control)
        try await requireCurrent(current)
        return StorageTransferRecoveryReceipt(current)
    }

    /// An absent control read alone cannot cancel an earlier unacknowledged
    /// create. Install an exact cancelled CAS fence without uploading payload
    /// bytes; any late staging create using that old baseline must conflict.
    /// Only an explicitly named terminal predecessor with the same dataset
    /// lineage may be displaced. This never takes over a different pending
    /// transaction or crosses an acknowledged replacement boundary.
    func cancelUnclaimed(manifest: StorageTransferRecoveryManifest,
                         replacingTerminalTransactionID: UUID? = nil) async throws -> StorageTransferRecoveryReceipt {
        try manifest.validate()
        let previous = try await inspect(accountFingerprint: manifest.accountFingerprint)
        if let previous, previous.control.manifest == manifest {
            return try await cancelBeforeReplacement(manifest: manifest)
        }
        if let previous {
            guard previous.control.isTerminal,
                  replacingTerminalTransactionID == previous.control.manifest.transactionID,
                  previous.control.manifest.transactionID != manifest.transactionID,
                  manifest.previousDatasetGenerationID == previous.control.datasetGenerationID else {
                throw StorageTransferRecoveryError.conflictingTransaction
            }
            try await retainReceipt(previous.control)
        } else {
            guard replacingTerminalTransactionID == nil, manifest.previousDatasetGenerationID == nil else {
                throw StorageTransferRecoveryError.staleControl
            }
        }
        try await requireUnusedTransaction(manifest)
        let cancelled = try StorageTransferRecoveryControl(manifest: manifest).cancelling()
        let result = try await save(cancelled, replacing: previous)
        try await retainReceipt(result.control)
        try await requireCurrent(result)
        return StorageTransferRecoveryReceipt(result)
    }

    /// A cancelled transaction may no longer own control-v1 when another
    /// device starts the next transfer before this device clears its journal.
    /// Read only that transaction's immutable receipt. The returned control
    /// authorizes local cancellation bookkeeping/temporary-copy cleanup only;
    /// it is deliberately not a current-control replacement receipt. Normal
    /// cloud admission must still independently inspect the current control.
    /// Nil means the backend acknowledged that exact receipt is absent; all
    /// account, schema, phase and payload mismatches remain errors.
    func archivedCancelledControl(manifest: StorageTransferRecoveryManifest) async throws -> StorageTransferRecoveryControl? {
        try manifest.validate()
        try await verifyAccount(manifest.accountFingerprint)
        let result = try await checked { try await backend.readTerminalReceipt(transactionID: manifest.transactionID) }
        try await verifyAccount(manifest.accountFingerprint)
        guard let control = result else { return nil }
        try control.validate()
        guard control.manifest == manifest else { throw StorageTransferRecoveryError.identityMismatch }
        guard control.phase == .cancelled else { throw StorageTransferRecoveryError.staleControl }
        return control
    }

    /// Separately requested cleanup of exact immutable chunks, never a prefix
    /// scan or a zone clear. Archived receipts survive later transactions, so a
    /// partial/uncertain cleanup can resume. Already submitted saves may arrive
    /// late after cancellation; retain the receipt and retry cleanup as needed.
    func cleanupPayload(manifest: StorageTransferRecoveryManifest) async throws {
        try manifest.validate()
        let current = try await inspect(accountFingerprint: manifest.accountFingerprint)
        if let current, current.control.manifest == manifest {
            guard current.control.isTerminal else { throw StorageTransferRecoveryError.staleControl }
            try await retainReceipt(current.control)
        }
        guard let receipt = try await checked({ try await backend.readTerminalReceipt(transactionID: manifest.transactionID) }) else {
            throw StorageTransferRecoveryError.staleControl
        }
        try receipt.validate()
        guard receipt.isTerminal, receipt.manifest == manifest else {
            throw StorageTransferRecoveryError.identityMismatch
        }
        for descriptor in manifest.chunks {
            try await verifyAccount(manifest.accountFingerprint)
            if let chunk = try await checked({ try await backend.readChunk(manifest: manifest, index: descriptor.index) }) {
                try chunk.validate(manifest: manifest, index: descriptor.index)
                try await verifyAccount(manifest.accountFingerprint)
                try await checked { try await backend.deleteChunkIfMatches(chunk, terminalReceipt: receipt) }
            }
            let remaining = try await checked { try await backend.readChunk(manifest: manifest, index: descriptor.index) }
            guard remaining == nil else { throw StorageTransferRecoveryError.incompleteBackup }
        }
        try await verifyAccount(manifest.accountFingerprint)
    }

    /// Full remote readback is required again immediately before recording the
    /// irreversible boundary. A lost response must be resolved by retrying this
    /// same transaction, never by assuming the server write did not happen.
    func authorizeReplacement(manifest: StorageTransferRecoveryManifest) async throws -> StorageTransferRecoveryReceipt {
        var current = try await exactControl(manifest)
        guard current.control.phase == .backupVerified || current.control.phase == .replacing else {
            throw StorageTransferRecoveryError.incompleteBackup
        }
        _ = try await readPayload(current)
        if current.control.phase == .backupVerified {
            current = try await save(current.control.advancing(to: .replacing), replacing: current)
        }
        return StorageTransferRecoveryReceipt(current)
    }

    func revalidateReplacement(_ receipt: StorageTransferRecoveryReceipt) async throws {
        guard receipt.envelope.control.phase == .replacing else { throw StorageTransferRecoveryError.staleControl }
        try await requireCurrent(receipt.envelope)
    }

    /// The caller supplies this digest only after an independent complete
    /// destination comparison with the recovered snapshot. Upload completion
    /// alone is not this proof. The receipt and backup remain on the server.
    func commitReplacement(manifest: StorageTransferRecoveryManifest,
                           verifiedDestinationSHA256: String) async throws -> StorageTransferRecoveryReceipt {
        guard verifiedDestinationSHA256 == manifest.payloadSHA256 else {
            throw StorageTransferRecoveryError.destinationMismatch
        }
        var current = try await exactControl(manifest)
        guard current.control.phase == .replacing || current.control.phase == .committed else {
            throw StorageTransferRecoveryError.staleControl
        }
        if current.control.phase == .replacing {
            _ = try await readPayload(current)
            current = try await save(current.control.advancing(to: .committed,
                verifiedDestinationSHA256: verifiedDestinationSHA256), replacing: current)
        }
        try await retainReceipt(current.control)
        try await requireCurrent(current)
        return StorageTransferRecoveryReceipt(current)
    }

    private func readPayload(_ current: StorageTransferRecoveryEnvelope) async throws -> StorageTransferRecoveredPayload {
        try await requireCurrent(current)
        let manifest = current.control.manifest
        var payload = Data()
        payload.reserveCapacity(manifest.payloadByteCount)
        for descriptor in manifest.chunks {
            guard let chunk = try await checked({ try await backend.readChunk(manifest: manifest, index: descriptor.index) }) else {
                throw StorageTransferRecoveryError.missingChunk
            }
            try chunk.validate(manifest: manifest, index: descriptor.index)
            payload.append(chunk.bytes)
        }
        try manifest.validate(payload: payload)
        try await requireCurrent(current)
        return StorageTransferRecoveredPayload(envelope: current, bytes: payload)
    }

    private func exactControl(_ manifest: StorageTransferRecoveryManifest) async throws -> StorageTransferRecoveryEnvelope {
        try manifest.validate()
        guard let current = try await inspect(accountFingerprint: manifest.accountFingerprint) else {
            throw StorageTransferRecoveryError.staleControl
        }
        try requireIdentity(current, manifest: manifest)
        return current
    }

    private func requireIdentity(_ envelope: StorageTransferRecoveryEnvelope,
                                 manifest: StorageTransferRecoveryManifest) throws {
        try envelope.validate()
        guard envelope.control.manifest == manifest else { throw StorageTransferRecoveryError.identityMismatch }
    }

    private func requireCurrent(_ expected: StorageTransferRecoveryEnvelope) async throws {
        let found = try await inspect(accountFingerprint: expected.control.manifest.accountFingerprint)
        guard found == expected else { throw StorageTransferRecoveryError.staleControl }
    }

    private func save(_ value: StorageTransferRecoveryControl,
                      replacing previous: StorageTransferRecoveryEnvelope?) async throws -> StorageTransferRecoveryEnvelope {
        try value.validate()
        try await verifyAccount(value.manifest.accountFingerprint)
        let result = try await checked { try await backend.compareAndSwapControl(value, replacing: previous) }
        try result.validate()
        guard result.control == value,
              previous.map({ $0.changeTag != result.changeTag }) ?? true else {
            throw StorageTransferRecoveryError.staleControl
        }
        try await requireCurrent(result)
        return result
    }

    private func retainReceipt(_ control: StorageTransferRecoveryControl) async throws {
        guard control.isTerminal else { throw StorageTransferRecoveryError.invalidControl }
        try await verifyAccount(control.manifest.accountFingerprint)
        try await checked { try await backend.retainTerminalReceipt(control) }
        let result = try await checked { try await backend.readTerminalReceipt(transactionID: control.manifest.transactionID) }
        guard result == control else { throw StorageTransferRecoveryError.staleControl }
        try await verifyAccount(control.manifest.accountFingerprint)
    }

    private func requireUnusedTransaction(_ manifest: StorageTransferRecoveryManifest) async throws {
        try await verifyAccount(manifest.accountFingerprint)
        let previous = try await checked { try await backend.readTerminalReceipt(transactionID: manifest.transactionID) }
        guard previous == nil else { throw StorageTransferRecoveryError.conflictingTransaction }
    }

    private func verifyAccount(_ fingerprint: String) async throws {
        guard StorageTransferRecoverySchema.isDigest(fingerprint) else { throw StorageTransferRecoveryError.identityMismatch }
        try await checked { try await backend.verifyAccount(fingerprint) }
    }

    private func checked<T>(_ operation: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        try validateAccess()
        let result = try await operation()
        try Task.checkCancellation()
        try validateAccess()
        return result
    }
}
