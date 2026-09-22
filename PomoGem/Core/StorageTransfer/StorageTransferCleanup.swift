import Darwin
import Foundation

enum StorageTransferCleanupError: Error, LocalizedError, Equatable {
    case invalidReceipt, unsafePath, unknownArtifact, limitExceeded, staleReceipt, journalStillPending

    var errorDescription: String? {
        switch self {
        case .limitExceeded:
            "安全に保持できる復旧処理の上限に達したため、新しい保存先の切り替えを開始できません。現在のデータは保護されています。"
        default:
            "保存先の切り替えに使った一時データを安全に確認できません。削除を保留しています。"
        }
    }
}

/// Minimal durable retry information. No model rows, snapshot bytes, user text,
/// asset bytes or absolute paths are stored here. This file lives beside, not
/// inside, the transaction directory that it authorizes for cleanup.
struct StorageTransferCleanupReceipt: Codable, Equatable, Sendable {
    enum Authorization: Codable, Equatable, Sendable {
        case committed
        case cancelled(journal: StorageTransferJournal, control: StorageTransferRecoveryControl?)
        case cancelledRetainingImport(journal: StorageTransferJournal)
        case remoteCancelled(control: StorageTransferRecoveryControl)
    }
    let formatVersion: Int
    let authorization: Authorization
    let transactionID: UUID
    let source: PersistenceDeploymentSelection?
    let committedSelection: StorageTransferCommittedSelection?
    let sourceDigest: String?
    let cloudBinding: ActiveAccountLocalBinding
    let recoveryManifest: StorageTransferRecoveryManifest?
    let ownedDirectories: [String]
    private(set) var localRemoved: Bool
    private(set) var remoteRemoved: Bool
    /// A successful absence check is historical evidence, not proof that an
    /// already submitted chunk create cannot arrive later. Keep the manifest
    /// and schedule another exact-ID check on subsequent same-account launches.
    private(set) var remoteAttemptOrdinal: Int?
    private(set) var remoteAttemptCount: Int
    private(set) var revision: Int

    init(journal: StorageTransferJournal, committedSelection: StorageTransferCommittedSelection,
         recoveryManifest: StorageTransferRecoveryManifest?, ownedDirectories: [String]) throws {
        try journal.validate()
        guard journal.phase == .sourceRetired,
              committedSelection == (try StorageTransferCommittedSelection(journal: journal)),
              let sourceDigest = journal.sourceDigest,
              journal.choice.replacesCloud == (recoveryManifest != nil) else {
            throw StorageTransferCleanupError.invalidReceipt
        }
        formatVersion = 1
        authorization = .committed
        transactionID = journal.transactionID
        source = journal.source
        self.committedSelection = committedSelection
        self.sourceDigest = sourceDigest
        cloudBinding = journal.cloudBinding
        self.recoveryManifest = recoveryManifest
        self.ownedDirectories = ownedDirectories
        localRemoved = false
        remoteRemoved = recoveryManifest == nil
        remoteAttemptOrdinal = nil
        remoteAttemptCount = 0
        revision = 0
        try validate()
    }

    init(cancelledJournal journal: StorageTransferJournal, control: StorageTransferRecoveryControl?,
         ownedDirectories: [String]) throws {
        formatVersion = 1
        if journal.retainsImportOnCancellation {
            guard control == nil else { throw StorageTransferCleanupError.invalidReceipt }
            authorization = .cancelledRetainingImport(journal: journal)
        } else {
            authorization = .cancelled(journal: journal, control: control)
        }
        transactionID = journal.transactionID
        source = journal.source
        committedSelection = nil
        sourceDigest = journal.sourceDigest
        cloudBinding = journal.cloudBinding
        recoveryManifest = control?.manifest
        self.ownedDirectories = ownedDirectories
        localRemoved = false
        remoteRemoved = control == nil
        remoteAttemptOrdinal = nil
        remoteAttemptCount = 0
        revision = 0
        try validate()
    }

    init(remoteCancellation control: StorageTransferRecoveryControl, binding: ActiveAccountLocalBinding) throws {
        formatVersion = 1
        authorization = .remoteCancelled(control: control)
        transactionID = control.manifest.transactionID
        source = nil
        committedSelection = nil
        sourceDigest = control.manifest.payloadSHA256
        cloudBinding = binding
        recoveryManifest = control.manifest
        ownedDirectories = []
        localRemoved = true
        remoteRemoved = false
        remoteAttemptOrdinal = nil
        remoteAttemptCount = 0
        revision = 0
        try validate()
    }

    var destination: PersistenceDeploymentSelection? {
        switch authorization {
        case .committed: committedSelection?.selection
        case let .cancelled(journal, _): journal.destination
        case let .cancelledRetainingImport(journal): journal.destination
        case .remoteCancelled: nil
        }
    }

    var retainsLocalCopies: Bool {
        if case .cancelledRetainingImport = authorization { return true }
        return false
    }

    func validate() throws {
        try committedSelection?.validate()
        try recoveryManifest?.validate()
        guard formatVersion == 1,
              ownedDirectories == ownedDirectories.sorted(),
              Set(ownedDirectories).count == ownedDirectories.count,
              ownedDirectories.count <= 4_100,
              ownedDirectories.allSatisfy(Self.isOwnedDirectory),
              remoteAttemptCount >= 0, remoteAttemptCount <= Int.max - 2,
              (remoteAttemptCount == 0) == (remoteAttemptOrdinal == nil),
              remoteAttemptOrdinal.map({ $0 >= remoteAttemptCount && $0 > 0 }) ?? true,
              recoveryManifest != nil || remoteAttemptCount == 0,
              revision == (localRemoved && source != nil ? 1 : 0) + (recoveryManifest != nil && remoteRemoved ? 1 : 0) + remoteAttemptCount,
              recoveryManifest != nil || remoteRemoved else { throw StorageTransferCleanupError.invalidReceipt }
        switch authorization {
        case .committed:
            try validateCommittedAuthorization()
        case let .cancelled(journal, control):
            try journal.validate()
            try control?.validate()
            guard journal.permitsCancellation, !journal.retainsImportOnCancellation,
                  transactionID == journal.transactionID,
                  source == journal.source, committedSelection == nil,
                  sourceDigest == journal.sourceDigest, cloudBinding == journal.cloudBinding,
                  recoveryManifest == control?.manifest else { throw StorageTransferCleanupError.invalidReceipt }
            if let control {
                guard journal.choice.replacesCloud, control.phase == .cancelled,
                      control.manifest.transactionID == transactionID,
                      control.manifest.accountFingerprint == cloudBinding.accountFingerprint,
                      control.manifest.payloadSHA256 == sourceDigest else { throw StorageTransferCleanupError.invalidReceipt }
            } else {
                // After sourceSaved an unacknowledged staging CAS may still
                // arrive. A single absent-control read cannot authorize losing
                // the local journal; require a cancelled remote fence first.
                guard !journal.choice.replacesCloud || journal.phase == .requested else {
                    throw StorageTransferCleanupError.invalidReceipt
                }
            }
        case let .cancelledRetainingImport(journal):
            try journal.validate()
            guard journal.retainsImportOnCancellation,
                  transactionID == journal.transactionID, source == journal.source,
                  committedSelection == nil, sourceDigest == journal.sourceDigest,
                  cloudBinding == journal.cloudBinding, recoveryManifest == nil,
                  !localRemoved, remoteRemoved, remoteAttemptCount == 0, revision == 0 else {
                throw StorageTransferCleanupError.invalidReceipt
            }
        case let .remoteCancelled(control):
            try control.validate()
            guard control.phase == .cancelled, source == nil, committedSelection == nil,
                  transactionID == control.manifest.transactionID,
                  recoveryManifest == control.manifest,
                  sourceDigest == control.manifest.payloadSHA256,
                  cloudBinding.accountFingerprint == control.manifest.accountFingerprint,
                  ownedDirectories.isEmpty, localRemoved else { throw StorageTransferCleanupError.invalidReceipt }
        }
    }

    private func validateCommittedAuthorization() throws {
        guard let source, let committedSelection, let sourceDigest,
              transactionID == committedSelection.transactionID,
              StorageTransferRecoverySchema.isDigest(sourceDigest),
              source.storageNamespace != committedSelection.selection.storageNamespace else {
            throw StorageTransferCleanupError.invalidReceipt
        }
        if let manifest = recoveryManifest {
            guard manifest.transactionID == transactionID,
                  manifest.accountFingerprint == cloudBinding.accountFingerprint,
                  manifest.payloadSHA256 == sourceDigest,
                  case let .cloud(binding) = committedSelection.selection,
                  binding == cloudBinding,
                  case .localOnly = source else { throw StorageTransferCleanupError.invalidReceipt }
        }
        switch (source, committedSelection.selection) {
        case let (.cloud(binding), .localOnly):
            guard binding == cloudBinding, recoveryManifest == nil else { throw StorageTransferCleanupError.invalidReceipt }
        case let (.localOnly, .cloud(binding)):
            guard binding == cloudBinding else { throw StorageTransferCleanupError.invalidReceipt }
        case let (.cloud(previous), .cloud(destination)):
            // A stale-generation refresh retires only the old local cache.
            // It neither replaces the remote data nor owns a recovery payload.
            guard destination == cloudBinding,
                  previous.accountFingerprint == destination.accountFingerprint,
                  recoveryManifest == nil else { throw StorageTransferCleanupError.invalidReceipt }
        default: throw StorageTransferCleanupError.invalidReceipt
        }
    }

    var isComplete: Bool { localRemoved && remoteRemoved }

    func recordingLocalRemoval() throws -> Self {
        try validate()
        guard !retainsLocalCopies else { throw StorageTransferCleanupError.invalidReceipt }
        guard !localRemoved else { return self }
        var next = self
        next.localRemoved = true
        next.revision += 1
        try next.validate()
        return next
    }

    func recordingRemoteRemoval() throws -> Self {
        try validate()
        guard !remoteRemoved else { return self }
        var next = self
        next.remoteRemoved = true
        next.revision += 1
        try next.validate()
        return next
    }

    func recordingRemoteAttempt(ordinal: Int) throws -> Self {
        try validate()
        guard recoveryManifest != nil, ordinal > (remoteAttemptOrdinal ?? 0),
              remoteAttemptCount < Int.max - 2 else { throw StorageTransferCleanupError.limitExceeded }
        var next = self
        next.remoteAttemptOrdinal = ordinal
        next.remoteAttemptCount += 1
        next.revision += 1
        try next.validate()
        return next
    }

    func hasSameAuthorization(as other: Self) -> Bool {
        formatVersion == other.formatVersion && authorization == other.authorization && transactionID == other.transactionID
            && source == other.source && committedSelection == other.committedSelection
            && sourceDigest == other.sourceDigest && cloudBinding == other.cloudBinding
            && recoveryManifest == other.recoveryManifest && ownedDirectories == other.ownedDirectories
    }

    static func isOwnedDirectory(_ path: String) -> Bool {
        if ["frozen", "staged", "copy-pending", "reader"].contains(path) { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0] == "reader" && canonicalUUID(String(parts[1])) != nil
    }

    static func canonicalUUID(_ value: String) -> UUID? {
        guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value else { return nil }
        return id
    }
}

struct StorageTransferCleanupRetryResult: Equatable, Sendable {
    var completed = 0
    var failed = 0
    var skippedOtherAccount = 0
    var deferred = 0
}

@MainActor
final class StorageTransferCleanup {
    // There is no safe age after which an unacknowledged remote create can be
    // assumed impossible. Apply admission backpressure instead of discarding
    // terminal identities. The extra slot permits non-replacing local cleanup.
    static let maximumRetainedRemoteReceipts = 1_024
    static let maximumReceipts = maximumRetainedRemoteReceipts + 1
    nonisolated static let maximumRemoteTransactionsPerPass = 2
    private static let maximumReceiptBytes = 256 * 1_024
    private static let maximumEntries = 250_000
    private static let maximumTemporaryBytes: Int64 = 8 * 1_024 * 1_024 * 1_024
    private static let metadataFiles: Set<String> = [
        "payload-v1.json", "payload-receipt-v1.json", "runtime-v1.json", "destination-payload-v1.json",
        "frozen-manifest-v1.json", "staged-manifest-v1.json", "managed-zone-deletion-v1.json",
        "partial-destination-recovery-v1.json", "source-retirement-v1.json", "staged-discard-v1.json"
    ]
    private let root: URL
    private let journalStore: StorageTransferJournalStore
    private let validateLocalCleanup: () throws -> Void

    init(featureRoot: URL, journalStore: StorageTransferJournalStore,
         validateLocalCleanup: @escaping () throws -> Void) throws {
        guard featureRoot.isFileURL, featureRoot.lastPathComponent == "StorageTransfer" else {
            throw StorageTransferCleanupError.unsafePath
        }
        root = featureRoot.standardizedFileURL
        self.journalStore = journalStore
        self.validateLocalCleanup = validateLocalCleanup
        try requireRoot()
    }

    /// Call at sourceRetired, before StorageTransferJournalStore.finish. The
    /// independent queue write must be durable before the original journal and
    /// any user-data-bearing temporary directory can be removed.
    @discardableResult
    func enqueue(journal: StorageTransferJournal,
                 recoveryManifest: StorageTransferRecoveryManifest?) throws -> StorageTransferCleanupReceipt {
        try Task.checkCancellation()
        guard try journalStore.load() == journal,
              let selection = try journalStore.committedSelection() else { throw StorageTransferCleanupError.invalidReceipt }
        if let existing = try load(transactionID: journal.transactionID) {
            let same = try StorageTransferCleanupReceipt(journal: journal, committedSelection: selection,
                recoveryManifest: recoveryManifest, ownedDirectories: existing.ownedDirectories)
            guard same.hasSameAuthorization(as: existing) else { throw StorageTransferCleanupError.staleReceipt }
            return existing
        }
        try requireCapacityForNewTransfer(transactionID: journal.transactionID,
                                          mayCreateRemotePayload: recoveryManifest != nil)
        let owned = try ownedDirectories(transactionID: journal.transactionID)
        let receipt = try StorageTransferCleanupReceipt(journal: journal, committedSelection: selection,
            recoveryManifest: recoveryManifest, ownedDirectories: owned)
        _ = try inventory(receipt)
        try write(receipt, replacing: nil)
        return receipt
    }

    /// Runtime must call this before accepting a new transaction or submitting
    /// any remote backup. Enqueue repeats it defensively; it never evicts an old
    /// receipt to make a later destructive transfer fit the local bound.
    func requireCapacityForNewTransfer(transactionID: UUID, mayCreateRemotePayload: Bool) throws {
        let receipts = try pendingReceipts()
        if receipts.contains(where: { $0.transactionID == transactionID }) { return }
        guard receipts.count < Self.maximumReceipts,
              !mayCreateRemotePayload || receipts.filter({ $0.recoveryManifest != nil }).count < Self.maximumRetainedRemoteReceipts else {
            throw StorageTransferCleanupError.limitExceeded
        }
    }

    /// Persist before JournalStore.cancel. Early cancellation authorizes only
    /// temporary-copy cleanup; late nonreplacement cancellation retains its
    /// entire tree indefinitely. Source and destination model-root files are
    /// untouched. A possible backup upload requires the acknowledged exact
    /// cancelled control returned by RemoteRecovery's cancellation operation.
    @discardableResult
    func enqueueCancellation(journal: StorageTransferJournal,
                             cancelledControl: StorageTransferRecoveryControl?) throws -> StorageTransferCleanupReceipt {
        try Task.checkCancellation()
        guard journal.permitsCancellation, try journalStore.load() == journal else {
            throw StorageTransferCleanupError.invalidReceipt
        }
        if let existing = try load(transactionID: journal.transactionID) {
            let same = try StorageTransferCleanupReceipt(cancelledJournal: journal, control: cancelledControl,
                                                         ownedDirectories: existing.ownedDirectories)
            guard same.hasSameAuthorization(as: existing) else { throw StorageTransferCleanupError.staleReceipt }
            return existing
        }
        try requireCapacityForNewTransfer(transactionID: journal.transactionID,
                                          mayCreateRemotePayload: cancelledControl != nil)
        let owned = try ownedDirectories(transactionID: journal.transactionID)
        let receipt = try StorageTransferCleanupReceipt(cancelledJournal: journal, control: cancelledControl,
                                                        ownedDirectories: owned)
        _ = try inventory(receipt)
        try write(receipt, replacing: nil)
        return receipt
    }

    /// A fresh installation can cancel a remote upload without a local journal
    /// or payload. This variant grants no local directory deletion authority.
    @discardableResult
    func enqueueRemoteCancellation(binding: ActiveAccountLocalBinding,
                                   cancelledControl: StorageTransferRecoveryControl) throws -> StorageTransferCleanupReceipt {
        try Task.checkCancellation()
        guard try journalStore.load() == nil else { throw StorageTransferCleanupError.journalStillPending }
        let receipt = try StorageTransferCleanupReceipt(remoteCancellation: cancelledControl, binding: binding)
        if let existing = try load(transactionID: receipt.transactionID) {
            guard existing.hasSameAuthorization(as: receipt) else { throw StorageTransferCleanupError.staleReceipt }
            return existing
        }
        guard try statEntry(receipt.transactionID.uuidString.lowercased()) == nil else {
            throw StorageTransferCleanupError.unsafePath
        }
        try requireCapacityForNewTransfer(transactionID: receipt.transactionID, mayCreateRemotePayload: true)
        try write(receipt, replacing: nil)
        return receipt
    }

    func pendingReceipts() throws -> [StorageTransferCleanupReceipt] {
        try requireRoot()
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard children.count <= 16_384 else { throw StorageTransferCleanupError.limitExceeded }
        var result: [StorageTransferCleanupReceipt] = []
        for child in children where child.lastPathComponent.hasPrefix("cleanup-") {
            let name = child.lastPathComponent
            guard name.hasSuffix(".json"),
                  let id = StorageTransferCleanupReceipt.canonicalUUID(String(name.dropFirst(8).dropLast(5))),
                  let receipt = try load(transactionID: id) else { throw StorageTransferCleanupError.invalidReceipt }
            result.append(receipt)
            guard result.count <= Self.maximumReceipts else { throw StorageTransferCleanupError.limitExceeded }
        }
        return result.sorted { $0.transactionID.uuidString < $1.transactionID.uuidString }
    }

    /// The whole allowed tree is validated before the first unlink. Each unlink
    /// is descriptor-relative with NOFOLLOW ancestry; a crash leaves a valid
    /// subset of the authorized temporary tree for the next attempt.
    func runLocal(transactionID: UUID) throws {
        guard let receipt = try load(transactionID: transactionID) else { return }
        // A cancelled import may contain changes absent from its old snapshot
        // or from the server. This receipt grants retention, never deletion.
        guard !receipt.retainsLocalCopies else { return }
        try localGate()
        if !receipt.localRemoved {
            let entries = try inventory(receipt)
            for entry in entries.sorted(by: { $0.path.split(separator: "/").count > $1.path.split(separator: "/").count }) {
                try localGate()
                try unlink(entry)
            }
            guard try statEntry(transactionID.uuidString.lowercased()) == nil else { throw StorageTransferCleanupError.staleReceipt }
            try write(receipt.recordingLocalRemoval(), replacing: receipt)
        }
        try removeCompleted(transactionID: transactionID)
    }

    func retainedCancellationJournal(transactionID: UUID) throws -> StorageTransferJournal? {
        guard let receipt = try load(transactionID: transactionID),
              case let .cancelledRetainingImport(journal) = receipt.authorization else { return nil }
        return journal
    }

    /// Every remote manifest survives successful cleanup. An in-flight create
    /// can arrive after an absence check and after control-v1 moves to another
    /// transaction. Only this retained identity makes that late chunk findable.
    /// Each pass visits a bounded least-recently-attempted batch. The ordinal is
    /// durable before any await, so repeated failures cannot starve other work.
    /// Network failures retain the exact manifest outside removed local data.
    /// Same-account verification is repeated by RemoteRecovery itself. An old
    /// local namespace is not an account identity and does not prevent retry.
    func retryRemoteCleanup(expectedBinding: ActiveAccountLocalBinding,
                            recovery: StorageTransferRemoteRecovery,
                            batchLimit: Int = StorageTransferCleanup.maximumRemoteTransactionsPerPass,
                            validateAccess: () throws -> Void) async throws -> StorageTransferCleanupRetryResult {
        guard (1...Self.maximumRemoteTransactionsPerPass).contains(batchLimit) else {
            throw StorageTransferCleanupError.limitExceeded
        }
        var report = StorageTransferCleanupRetryResult()
        let receipts = try pendingReceipts().filter { $0.recoveryManifest != nil }
        report.skippedOtherAccount = receipts.filter { $0.cloudBinding.accountFingerprint != expectedBinding.accountFingerprint }.count
        let eligible = receipts.filter { $0.cloudBinding.accountFingerprint == expectedBinding.accountFingerprint }
            .sorted {
                let lhs = $0.remoteAttemptOrdinal ?? 0, rhs = $1.remoteAttemptOrdinal ?? 0
                return lhs == rhs ? $0.transactionID.uuidString < $1.transactionID.uuidString : lhs < rhs
            }
        report.deferred = max(0, eligible.count - batchLimit)
        for receipt in eligible.prefix(batchLimit) {
            try Task.checkCancellation()
            try validateAccess()
            guard let manifest = receipt.recoveryManifest else { throw StorageTransferCleanupError.invalidReceipt }
            do {
                guard let latest = try load(transactionID: receipt.transactionID),
                      latest.recoveryManifest == manifest else { throw StorageTransferCleanupError.staleReceipt }
                let largest = try pendingReceipts().compactMap(\.remoteAttemptOrdinal).max() ?? 0
                guard largest < Int.max else { throw StorageTransferCleanupError.limitExceeded }
                try write(latest.recordingRemoteAttempt(ordinal: largest + 1), replacing: latest)
                try await recovery.cleanupPayload(manifest: manifest)
                try Task.checkCancellation()
                try validateAccess()
                guard let current = try load(transactionID: receipt.transactionID),
                      current.recoveryManifest == manifest else { throw StorageTransferCleanupError.staleReceipt }
                if !current.remoteRemoved {
                    try write(current.recordingRemoteRemoval(), replacing: current)
                }
                report.completed += 1
            } catch is CancellationError { throw CancellationError() }
            catch { report.failed += 1 }
        }
        return report
    }

    private struct Entry {
        let path: String
        let directory: Bool
        let inode: ino_t
        let device: dev_t
        let bytes: Int64
    }

    private func inventory(_ receipt: StorageTransferCleanupReceipt) throws -> [Entry] {
        try receipt.validate()
        let prefix = receipt.transactionID.uuidString.lowercased()
        guard let transaction = try statEntry(prefix) else { return [] }
        guard transaction.directory else { throw StorageTransferCleanupError.unsafePath }
        var result = [transaction]
        var pending = [prefix]
        var bytes: Int64 = 0
        while let parent = pending.popLast() {
            let children = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(parent), includingPropertiesForKeys: nil)
            guard children.count <= Self.maximumEntries - result.count - pending.count else { throw StorageTransferCleanupError.limitExceeded }
            for child in children {
                let path = parent + "/" + child.lastPathComponent
                guard let entry = try statEntry(path) else { throw StorageTransferCleanupError.staleReceipt }
                try validatePath(entry, receipt: receipt)
                guard entry.bytes <= Self.maximumTemporaryBytes - bytes else { throw StorageTransferCleanupError.limitExceeded }
                bytes += entry.bytes
                result.append(entry)
                if entry.directory { pending.append(path) }
            }
        }
        return result
    }

    private func validatePath(_ entry: Entry, receipt: StorageTransferCleanupReceipt) throws {
        let pieces = entry.path.split(separator: "/").map(String.init)
        guard pieces.count >= 2, pieces[0] == receipt.transactionID.uuidString.lowercased() else {
            throw StorageTransferCleanupError.unknownArtifact
        }
        let relative = pieces.dropFirst().joined(separator: "/")
        if pieces.count == 2, Self.metadataFiles.contains(pieces[1]) {
            guard !entry.directory else { throw StorageTransferCleanupError.unknownArtifact }
            return
        }
        if receipt.ownedDirectories.contains(relative) {
            guard entry.directory else { throw StorageTransferCleanupError.unknownArtifact }
            return
        }
        let familyStart: Int
        let selections: [PersistenceDeploymentSelection]
        guard let source = receipt.source, let destination = receipt.destination else {
            throw StorageTransferCleanupError.unknownArtifact
        }
        switch pieces[1] {
        case "frozen", "copy-pending": familyStart = 2; selections = [source]
        case "staged": familyStart = 2; selections = [destination]
        case "reader":
            guard pieces.count >= 4, receipt.ownedDirectories.contains("reader/" + pieces[2]) else {
                throw StorageTransferCleanupError.unknownArtifact
            }
            familyStart = 3; selections = [source, destination]
        default: throw StorageTransferCleanupError.unknownArtifact
        }
        guard pieces.count > familyStart else { throw StorageTransferCleanupError.unknownArtifact }
        let variants = artifactKinds(selections)
        guard let isDirectory = variants[pieces[familyStart]] else { throw StorageTransferCleanupError.unknownArtifact }
        if pieces.count == familyStart + 1 {
            guard entry.directory == isDirectory else { throw StorageTransferCleanupError.unknownArtifact }
        } else {
            guard isDirectory else { throw StorageTransferCleanupError.unknownArtifact }
        }
    }

    private func artifactKinds(_ selections: [PersistenceDeploymentSelection]) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for selection in selections {
            let stores: [URL]
            switch selection {
            case .cloud(let binding): stores = PersistenceStoreTopology.accountStoreURLs(accountNamespace: binding.namespace, directory: root)
            case .localOnly(let namespace): stores = PersistenceStoreTopology.localOnlyPersistentStoreURLs(namespace: namespace, directory: root)
            }
            for store in stores {
                for (url, variant) in zip(PersistenceStoreArtifactLayout.artifacts(for: store), PersistenceStoreArtifactLayout.variants) {
                    result[url.lastPathComponent] = variant.isDirectory
                }
            }
        }
        return result
    }

    private func ownedDirectories(transactionID: UUID) throws -> [String] {
        let path = transactionID.uuidString.lowercased()
        guard let value = try statEntry(path), value.directory else { throw StorageTransferCleanupError.unsafePath }
        var result: [String] = []
        for name in ["frozen", "staged", "copy-pending", "reader"] {
            guard let entry = try statEntry(path + "/" + name) else { continue }
            guard entry.directory else { throw StorageTransferCleanupError.unsafePath }
            result.append(name)
            if name == "reader" {
                let children = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(path + "/reader"), includingPropertiesForKeys: nil)
                guard children.count <= 4_096 else { throw StorageTransferCleanupError.limitExceeded }
                for child in children {
                    guard StorageTransferCleanupReceipt.canonicalUUID(child.lastPathComponent) != nil,
                          try statEntry(path + "/reader/" + child.lastPathComponent)?.directory == true else {
                        throw StorageTransferCleanupError.unknownArtifact
                    }
                    result.append("reader/" + child.lastPathComponent)
                }
            }
        }
        return result.sorted()
    }

    private func localGate() throws {
        try Task.checkCancellation()
        try validateLocalCleanup()
        guard try journalStore.load() == nil else { throw StorageTransferCleanupError.journalStillPending }
        try requireRoot()
    }

    private func queueName(_ id: UUID) -> String { "cleanup-" + id.uuidString.lowercased() + ".json" }

    private func load(transactionID: UUID) throws -> StorageTransferCleanupReceipt? {
        try requireRoot()
        let name = queueName(transactionID)
        guard let entry = try statEntry(name) else { return nil }
        guard !entry.directory, entry.bytes <= Self.maximumReceiptBytes else { throw StorageTransferCleanupError.invalidReceipt }
        let descriptor = open(root.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw StorageTransferCleanupError.unsafePath }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_ino == entry.inode, info.st_dev == entry.device,
              info.st_size == entry.bytes else { throw StorageTransferCleanupError.staleReceipt }
        let data = try handle.read(upToCount: Self.maximumReceiptBytes + 1) ?? Data()
        guard data.count == entry.bytes, data.count <= Self.maximumReceiptBytes,
              (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw StorageTransferCleanupError.invalidReceipt }
        let value = try JSONDecoder().decode(StorageTransferCleanupReceipt.self, from: data)
        try value.validate()
        guard value.transactionID == transactionID else { throw StorageTransferCleanupError.invalidReceipt }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let actual = try JSONSerialization.jsonObject(with: data) as? NSDictionary,
              let known = try JSONSerialization.jsonObject(with: encoder.encode(value)) as? NSDictionary,
              actual == known else { throw StorageTransferCleanupError.invalidReceipt }
        return value
    }

    private func write(_ receipt: StorageTransferCleanupReceipt, replacing previous: StorageTransferCleanupReceipt?) throws {
        try receipt.validate()
        guard try load(transactionID: receipt.transactionID) == previous else { throw StorageTransferCleanupError.staleReceipt }
        if let previous {
            var expected = previous
            if receipt.remoteAttemptCount != previous.remoteAttemptCount {
                guard receipt.remoteAttemptCount == previous.remoteAttemptCount + 1,
                      let ordinal = receipt.remoteAttemptOrdinal else { throw StorageTransferCleanupError.staleReceipt }
                expected = try expected.recordingRemoteAttempt(ordinal: ordinal)
            }
            if !previous.localRemoved && receipt.localRemoved { expected = try expected.recordingLocalRemoval() }
            if !previous.remoteRemoved && receipt.remoteRemoved { expected = try expected.recordingRemoteRemoval() }
            guard expected == receipt, receipt.revision == previous.revision + 1 else { throw StorageTransferCleanupError.staleReceipt }
        } else if receipt.revision != 0 { throw StorageTransferCleanupError.invalidReceipt }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        guard data.count <= Self.maximumReceiptBytes else { throw StorageTransferCleanupError.limitExceeded }
        let url = root.appendingPathComponent(queueName(receipt.transactionID))
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw StorageTransferCleanupError.unsafePath }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size == data.count else { throw StorageTransferCleanupError.staleReceipt }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try synchronizeRoot()
        guard try load(transactionID: receipt.transactionID) == receipt else { throw StorageTransferCleanupError.staleReceipt }
    }

    private func removeCompleted(transactionID: UUID) throws {
        guard let receipt = try load(transactionID: transactionID), receipt.isComplete,
              receipt.recoveryManifest == nil,
              let entry = try statEntry(queueName(transactionID)) else { return }
        try unlink(entry)
    }

    private func statEntry(_ path: String) throws -> Entry? {
        guard validComponents(path) else { throw StorageTransferCleanupError.unsafePath }
        var info = stat()
        guard lstat(root.appendingPathComponent(path).path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw StorageTransferCleanupError.unsafePath
        }
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR, info.st_size >= 0 else { throw StorageTransferCleanupError.unsafePath }
        return Entry(path: path, directory: kind == S_IFDIR, inode: info.st_ino, device: info.st_dev,
                     bytes: kind == S_IFREG ? info.st_size : 0)
    }

    private func unlink(_ expected: Entry) throws {
        guard validComponents(expected.path) else { throw StorageTransferCleanupError.unsafePath }
        let parts = expected.path.split(separator: "/").map(String.init)
        var descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StorageTransferCleanupError.unsafePath }
        defer { close(descriptor) }
        for part in parts.dropLast() {
            let next = openat(descriptor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw StorageTransferCleanupError.unsafePath }
            close(descriptor)
            descriptor = next
        }
        let name = parts.last!
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw StorageTransferCleanupError.unsafePath
        }
        guard info.st_ino == expected.inode, info.st_dev == expected.device,
              (info.st_mode & S_IFMT) == (expected.directory ? S_IFDIR : S_IFREG),
              expected.directory || info.st_size == expected.bytes else { throw StorageTransferCleanupError.staleReceipt }
        guard unlinkat(descriptor, name, expected.directory ? AT_REMOVEDIR : 0) == 0 else { throw StorageTransferCleanupError.unsafePath }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func validComponents(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }
    }

    private func requireRoot() throws {
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw StorageTransferCleanupError.unsafePath }
    }

    private func synchronizeRoot() throws {
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StorageTransferCleanupError.unsafePath }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
