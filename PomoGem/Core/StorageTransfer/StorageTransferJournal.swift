import Foundation
import Darwin

/// Explicitly chosen data ownership for a storage change. No case merges the
/// two histories, and disabling CloudKit never requests a remote deletion.
enum StorageTransferChoice: String, Codable, CaseIterable, Sendable {
    case disableCloudKeepingCopy
    case enableCloudKeepingCloud
    case enableCloudReplacingCloud

    var replacesCloud: Bool { self == .enableCloudReplacingCloud }
}

enum StorageTransferError: Error, LocalizedError, Equatable {
    case invalidJournal, staleTransaction, unsafePath, snapshotMismatch
    case activeTimer, incompleteCloudCopy, recoveryCopyRequired

    var errorDescription: String? {
        switch self {
        case .invalidJournal, .staleTransaction, .unsafePath:
            "保存先の切り替え状況を安全に確認できません。元のデータを保護しています。"
        case .snapshotMismatch:
            "コピーしたデータが元のデータと一致しません。保存先はまだ切り替えていません。"
        case .activeTimer:
            "実行中・一時停止中のタイマーを終了してから、保存先を切り替えてください。"
        case .incompleteCloudCopy:
            "iCloudの全データを確認できませんでした。通信状態を確認して再試行してください。"
        case .recoveryCopyRequired:
            "iCloudに復旧用コピーを保存できていないため、データの置き換えは開始していません。"
        }
    }
}

extension PersistenceDeploymentSelection {
    var storageNamespace: AccountDataNamespace {
        switch self {
        case let .cloud(binding): binding.namespace
        case let .localOnly(namespace): namespace
        }
    }

    var storageLaunchMode: PersistenceLaunchMode {
        switch self {
        case .cloud: .cloudKit
        case .localOnly: .localOnly
        }
    }
}

/// This journal lives outside both model stores. A phase is an acknowledged
/// checkpoint, never an optimistic indication that an async effect succeeded.
struct StorageTransferJournal: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    enum Phase: Int, Codable, CaseIterable, Comparable, Sendable {
        case requested
        case sourceSaved
        case recoveryCopySaved
        case preparingDestination
        case destinationSaved
        case destinationVerified
        case selectionCommitted
        case sourceRetired

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let formatVersion: Int
    let transactionID: UUID
    let choice: StorageTransferChoice
    let source: PersistenceDeploymentSelection
    let destination: PersistenceDeploymentSelection
    /// The exact verified account participates even when the destination is
    /// local. A later Apple Account must never authorize resuming this work.
    let cloudBinding: ActiveAccountLocalBinding
    let startedAt: Date
    private(set) var phase: Phase
    private(set) var revision: Int
    private(set) var sourceDigest: String?
    private(set) var destinationDigest: String?
    private(set) var remoteRecoveryTransactionID: UUID?

    init(transactionID: UUID = UUID(), choice: StorageTransferChoice,
         source: PersistenceDeploymentSelection,
         destination: PersistenceDeploymentSelection,
         cloudBinding: ActiveAccountLocalBinding, startedAt: Date = .now) throws {
        formatVersion = Self.currentFormatVersion
        self.transactionID = transactionID
        self.choice = choice
        self.source = source
        self.destination = destination
        self.cloudBinding = cloudBinding
        self.startedAt = startedAt
        phase = .requested
        revision = 0
        try validate()
    }

    var permitsCancellation: Bool {
        // A remote recovery copy is not a request to delete. Once destination
        // preparation is durably authorized, replacement must resume instead
        // of falling back to a writable old cloud mirror.
        phase < .preparingDestination || retainsImportOnCancellation
    }

    /// Copying from iCloud never erases remote data. Before promotion starts,
    /// a stale imported snapshot can be abandoned only by retaining every
    /// local copy. Replacement and promotion never acquire this right.
    var retainsImportOnCancellation: Bool {
        !choice.replacesCloud
            && phase >= .preparingDestination && phase < .destinationVerified
    }

    func validate() throws {
        guard formatVersion == Self.currentFormatVersion,
              startedAt.timeIntervalSince1970.isFinite,
              revision == phase.rawValue,
              source.storageNamespace != destination.storageNamespace else {
            throw StorageTransferError.invalidJournal
        }
        switch (choice, source, destination) {
        case let (.disableCloudKeepingCopy, .cloud(binding), .localOnly):
            guard binding == cloudBinding else { throw StorageTransferError.invalidJournal }
        case let (.enableCloudKeepingCloud, .localOnly, .cloud(binding)),
             let (.enableCloudReplacingCloud, .localOnly, .cloud(binding)):
            guard binding == cloudBinding else { throw StorageTransferError.invalidJournal }
        case let (.enableCloudKeepingCloud, .cloud(previous), .cloud(destinationBinding)):
            guard destinationBinding == cloudBinding,
                  previous.accountFingerprint == destinationBinding.accountFingerprint else {
                throw StorageTransferError.invalidJournal
            }
        default:
            throw StorageTransferError.invalidJournal
        }
        guard (phase >= .sourceSaved) == (sourceDigest != nil),
              sourceDigest.map(AppleAccountFingerprint.isValid) ?? true,
              (phase >= .destinationSaved) == (destinationDigest != nil),
              destinationDigest.map(AppleAccountFingerprint.isValid) ?? true else {
            throw StorageTransferError.invalidJournal
        }
        if choice.replacesCloud, phase >= .recoveryCopySaved {
            guard remoteRecoveryTransactionID == transactionID else {
                throw StorageTransferError.recoveryCopyRequired
            }
        } else if remoteRecoveryTransactionID != nil {
            throw StorageTransferError.invalidJournal
        }
        if phase >= .destinationVerified, choice != .enableCloudKeepingCloud {
            guard destinationDigest == sourceDigest else {
                throw StorageTransferError.snapshotMismatch
            }
        }
    }

    /// Call only after the corresponding effect and independent readback have
    /// completed. Persist the returned value before starting the next effect.
    func advancing(to next: Phase, sourceDigest: String? = nil,
                   destinationDigest: String? = nil,
                   remoteRecoveryTransactionID: UUID? = nil) throws -> Self {
        try validate()
        guard next.rawValue == phase.rawValue + 1 else {
            throw StorageTransferError.staleTransaction
        }
        var result = self
        result.phase = next
        result.revision += 1
        if let sourceDigest { result.sourceDigest = sourceDigest }
        if let destinationDigest { result.destinationDigest = destinationDigest }
        if let remoteRecoveryTransactionID {
            result.remoteRecoveryTransactionID = remoteRecoveryTransactionID
        }
        // Proofs are write-once; retrying a phase cannot substitute new data.
        guard self.sourceDigest == nil || result.sourceDigest == self.sourceDigest,
              self.destinationDigest == nil || result.destinationDigest == self.destinationDigest,
              self.remoteRecoveryTransactionID == nil
                || result.remoteRecoveryTransactionID == self.remoteRecoveryTransactionID else {
            throw StorageTransferError.staleTransaction
        }
        try result.validate()
        return result
    }
}

/// A single atomic selection record prevents a crash between updates of the
/// old UserDefaults selection and mount marker from authorizing the wrong store.
struct StorageTransferCommittedSelection: Codable, Equatable, Sendable {
    let formatVersion: Int
    let transactionID: UUID
    let selection: PersistenceDeploymentSelection
    let verifiedSnapshotDigest: String

    init(journal: StorageTransferJournal) throws {
        try journal.validate()
        guard journal.phase >= .destinationVerified,
              let digest = journal.destinationDigest else {
            throw StorageTransferError.invalidJournal
        }
        formatVersion = 1
        transactionID = journal.transactionID
        selection = journal.destination
        verifiedSnapshotDigest = digest
    }

    func validate() throws {
        guard formatVersion == 1,
              AppleAccountFingerprint.isValid(verifiedSnapshotDigest) else {
            throw StorageTransferError.invalidJournal
        }
    }
}

/// Synchronous, process-local serialization also works on the launch path,
/// before a ModelContainer or a SwiftUI task is allowed to touch either store.
/// Callers use transaction/revision CAS; stale async callbacks cannot progress
/// a different transaction. No API deletes a model store or a CloudKit zone.
@MainActor
final class StorageTransferJournalStore {
    private let directory: URL
    private static let maximumStateBytes = 32_768

    init(directory: URL) { self.directory = directory.standardizedFileURL }

    static func live() throws -> StorageTransferJournalStore {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        return Self(directory: root.appendingPathComponent("StorageTransfer", isDirectory: true))
    }

    func load() throws -> StorageTransferJournal? {
        let journal: StorageTransferJournal? = try read("pending-v1.json")
        try journal?.validate()
        if let journal, journal.phase >= .selectionCommitted {
            guard try committedSelection() == StorageTransferCommittedSelection(journal: journal) else {
                throw StorageTransferError.invalidJournal
            }
        }
        return journal
    }

    func committedSelection() throws -> StorageTransferCommittedSelection? {
        let value: StorageTransferCommittedSelection? = try read("selection-v1.json")
        try value?.validate()
        return value
    }

    func begin(_ journal: StorageTransferJournal) throws {
        try journal.validate()
        guard journal.phase == .requested, try load() == nil else {
            throw StorageTransferError.staleTransaction
        }
        if let existing = try committedSelection(), existing.selection != journal.source {
            throw StorageTransferError.staleTransaction
        }
        try write(journal, name: "pending-v1.json")
    }

    func save(_ journal: StorageTransferJournal, replacing previous: StorageTransferJournal) throws {
        try journal.validate()
        guard try load() == previous,
              journal.transactionID == previous.transactionID,
              journal.choice == previous.choice,
              journal.source == previous.source,
              journal.destination == previous.destination,
              journal.cloudBinding == previous.cloudBinding,
              journal.startedAt == previous.startedAt,
              journal.revision == previous.revision + 1,
              journal.sourceDigest == previous.sourceDigest || previous.sourceDigest == nil,
              journal.destinationDigest == previous.destinationDigest || previous.destinationDigest == nil,
              journal.remoteRecoveryTransactionID == previous.remoteRecoveryTransactionID
                || previous.remoteRecoveryTransactionID == nil else {
            throw StorageTransferError.staleTransaction
        }
        if journal.phase >= .selectionCommitted {
            guard try committedSelection() == StorageTransferCommittedSelection(journal: journal) else {
                throw StorageTransferError.invalidJournal
            }
        }
        try write(journal, name: "pending-v1.json")
    }

    func commitSelection(for journal: StorageTransferJournal) throws {
        guard try load() == journal, journal.phase == .destinationVerified else {
            throw StorageTransferError.staleTransaction
        }
        let value = try StorageTransferCommittedSelection(journal: journal)
        if let existing = try committedSelection() {
            if existing == value { return }
            guard existing.selection == journal.source else {
                throw StorageTransferError.staleTransaction
            }
        }
        try write(value, name: "selection-v1.json")
        guard try committedSelection() == value else { throw StorageTransferError.invalidJournal }
    }

    func finish(_ journal: StorageTransferJournal) throws {
        guard try load() == journal, journal.phase == .sourceRetired,
              try committedSelection() == StorageTransferCommittedSelection(journal: journal) else {
            throw StorageTransferError.staleTransaction
        }
        try remove("pending-v1.json")
    }

    func cancel(_ journal: StorageTransferJournal) throws {
        guard journal.permitsCancellation, try load() == journal else {
            throw StorageTransferError.staleTransaction
        }
        // The caller must first acknowledge an exact cancelled remote fence
        // when staging was possible, and durably queue temporary-copy cleanup.
        // Clearing this journal never grants remote or model-store deletion.
        try remove("pending-v1.json")
    }

    private func prepareDirectory() throws {
        let manager = FileManager.default
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw StorageTransferError.unsafePath
            }
        } else if errno == ENOENT {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        } else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func checkedURL(_ name: String) throws -> URL {
        try prepareDirectory()
        let url = directory.appendingPathComponent(name)
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size >= 0, info.st_size <= Self.maximumStateBytes else {
                throw StorageTransferError.unsafePath
            }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return url
    }

    private func read<T: Codable>(_ name: String) throws -> T? {
        let url = try checkedURL(name)
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= Self.maximumStateBytes else { throw StorageTransferError.invalidJournal }
            let value = try JSONDecoder().decode(T.self, from: data)
            let canonical = try JSONEncoder().encode(value)
            guard let supplied = try JSONSerialization.jsonObject(with: data) as? NSDictionary,
                  let encoded = try JSONSerialization.jsonObject(with: canonical) as? NSDictionary,
                  supplied == encoded else { throw StorageTransferError.invalidJournal }
            return value
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private func write<T: Encodable>(_ value: T, name: String) throws {
        let url = try checkedURL(name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumStateBytes else { throw StorageTransferError.invalidJournal }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        try synchronizeDirectory()
    }

    private func remove(_ name: String) throws {
        try FileManager.default.removeItem(at: checkedURL(name))
        try synchronizeDirectory()
    }

    private func synchronizeDirectory() throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
