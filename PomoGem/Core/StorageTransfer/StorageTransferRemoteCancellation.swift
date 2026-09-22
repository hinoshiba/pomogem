import Darwin
import Foundation

enum StorageTransferRemoteCancellationError: Error, LocalizedError, Equatable {
    case invalidIntent, conflictingIntent, unsafeFile, localTransferPending, remoteStateChanged

    var errorDescription: String? {
        "iCloudの切り替え取消を安全に確認できません。保存した取消記録を保護しています。通信状態を確認して再試行してください。"
    }
}

/// One explicit user request, with no payload bytes or model-store paths. The
/// original observed control binds cancellation to a pre-replacement phase.
struct StorageTransferRemoteCancellationIntent: Codable, Equatable, Sendable {
    let formatVersion: Int
    let binding: ActiveAccountLocalBinding
    let transactionID: UUID
    let manifest: StorageTransferRecoveryManifest
    let observedControl: StorageTransferRecoveryControl

    init(binding: ActiveAccountLocalBinding, expectedTransactionID: UUID,
         observedControl: StorageTransferRecoveryControl) throws {
        formatVersion = 1
        self.binding = binding
        transactionID = expectedTransactionID
        manifest = observedControl.manifest
        self.observedControl = observedControl
        try validate()
    }

    func validate() throws {
        try manifest.validate()
        try observedControl.validate()
        guard formatVersion == 1, manifest == observedControl.manifest,
              transactionID == manifest.transactionID,
              binding.accountFingerprint == manifest.accountFingerprint,
              [.staging, .backupVerified, .cancelled].contains(observedControl.phase) else {
            throw StorageTransferRemoteCancellationError.invalidIntent
        }
    }

    func permits(_ control: StorageTransferRecoveryControl) throws -> Bool {
        try validate()
        try control.validate()
        guard control.manifest == manifest else { return false }
        if control == observedControl { return true }
        switch (observedControl.phase, control.phase) {
        case (.staging, .backupVerified), (.staging, .cancelled): return true
        case (.backupVerified, .cancelled): return control.cancelledFrom == .backupVerified
        default: return false
        }
    }
}

/// A single durable local intent closes the process-crash window between a
/// cancelled server receipt and its local cleanup queue entry. Every launch
/// and new transfer must check pendingIntent before mounting/accepting writers.
///
/// Uninstall removes this intent. It cannot rediscover an older remote receipt
/// after another device advances control-v1; no uninstall-proof remote garbage
/// collection is claimed without a separately verified server discovery index.
@MainActor
final class StorageTransferRemoteCancellation {
    nonisolated static let filename = "remote-cancellation-v1.json"
    private static let maximumBytes = 131_072
    private let root: URL
    private let journalStore: StorageTransferJournalStore
    private let cleanup: StorageTransferCleanup
    private var url: URL { root.appendingPathComponent(Self.filename) }

    init(featureRoot: URL, journalStore: StorageTransferJournalStore,
         cleanup: StorageTransferCleanup) throws {
        guard featureRoot.isFileURL, featureRoot.lastPathComponent == "StorageTransfer" else {
            throw StorageTransferRemoteCancellationError.unsafeFile
        }
        root = featureRoot.standardizedFileURL
        self.journalStore = journalStore
        self.cleanup = cleanup
        try requireRoot()
    }

    func pendingIntent() throws -> StorageTransferRemoteCancellationIntent? {
        try requireRoot()
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw StorageTransferRemoteCancellationError.unsafeFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= Self.maximumBytes else {
            throw StorageTransferRemoteCancellationError.unsafeFile
        }
        let bytes = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard bytes.count == info.st_size, bytes.count <= Self.maximumBytes,
              (try handle.read(upToCount: 1) ?? Data()).isEmpty else {
            throw StorageTransferRemoteCancellationError.unsafeFile
        }
        let value = try JSONDecoder().decode(StorageTransferRemoteCancellationIntent.self, from: bytes)
        try value.validate()
        let canonical = try encoder().encode(value)
        guard let actual = try JSONSerialization.jsonObject(with: bytes) as? NSDictionary,
              let known = try JSONSerialization.jsonObject(with: canonical) as? NSDictionary,
              actual == known else { throw StorageTransferRemoteCancellationError.invalidIntent }
        return value
    }

    /// Persist/fsync before the caller performs any cancellation CAS. A second
    /// request cannot replace this intent, even for another terminal control.
    @discardableResult
    func accept(binding: ActiveAccountLocalBinding, expectedTransactionID: UUID,
                observedControl: StorageTransferRecoveryControl,
                validateAccess: () throws -> Void) throws -> StorageTransferRemoteCancellationIntent {
        try Task.checkCancellation()
        try validateAccess()
        guard try journalStore.load() == nil else { throw StorageTransferRemoteCancellationError.localTransferPending }
        let intent = try StorageTransferRemoteCancellationIntent(binding: binding,
            expectedTransactionID: expectedTransactionID, observedControl: observedControl)
        if let existing = try pendingIntent() {
            guard existing == intent else { throw StorageTransferRemoteCancellationError.conflictingIntent }
            return existing
        }
        try cleanup.requireCapacityForNewTransfer(transactionID: expectedTransactionID, mayCreateRemotePayload: true)
        try validateAccess()
        guard try journalStore.load() == nil, try pendingIntent() == nil else {
            throw StorageTransferRemoteCancellationError.conflictingIntent
        }
        let bytes = try encoder().encode(intent)
        guard bytes.count <= Self.maximumBytes else { throw StorageTransferRemoteCancellationError.unsafeFile }
        try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try synchronizeFile()
        try synchronizeRoot()
        guard try pendingIntent() == intent else { throw StorageTransferRemoteCancellationError.conflictingIntent }
        return intent
    }

    /// Resume only the persisted request. An archived cancelled receipt is
    /// enough to enqueue exact cleanup after a newer transaction has started;
    /// absent that receipt, only this original still-pending control may be
    /// cancelled. This API never creates or replaces a different control.
    func resume(expectedBinding: ActiveAccountLocalBinding, recovery: StorageTransferRemoteRecovery,
                validateAccess: @escaping @MainActor () throws -> Void) async throws {
        try Task.checkCancellation()
        try validateAccess()
        guard let intent = try pendingIntent() else { return }
        guard intent.binding == expectedBinding else { throw StorageTransferRecoveryError.identityMismatch }
        let validate: @MainActor () throws -> Void = {
            try Task.checkCancellation()
            try validateAccess()
            guard try self.journalStore.load() == nil else { throw StorageTransferRemoteCancellationError.localTransferPending }
            guard try self.pendingIntent() == intent else { throw StorageTransferRemoteCancellationError.conflictingIntent }
        }
        try validate()
        let remote = recovery.withAdditionalValidation(validate)
        let cancelled: StorageTransferRecoveryControl
        if let archived = try await remote.archivedCancelledControl(manifest: intent.manifest) {
            guard try intent.permits(archived) else { throw StorageTransferRemoteCancellationError.remoteStateChanged }
            cancelled = archived
        } else {
            guard let current = try await remote.inspect(accountFingerprint: intent.manifest.accountFingerprint),
                  try intent.permits(current.control) else { throw StorageTransferRemoteCancellationError.remoteStateChanged }
            cancelled = try await remote.cancelBeforeReplacement(manifest: intent.manifest).envelope.control
            guard try intent.permits(cancelled) else { throw StorageTransferRemoteCancellationError.remoteStateChanged }
        }
        try validate()
        try cleanup.enqueueRemoteCancellation(binding: intent.binding, cancelledControl: cancelled)
        try validate()
        try clear(intent)
    }

    private func clear(_ expected: StorageTransferRemoteCancellationIntent) throws {
        guard try pendingIntent() == expected else { throw StorageTransferRemoteCancellationError.conflictingIntent }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw StorageTransferRemoteCancellationError.unsafeFile }
        defer { close(directory) }
        var info = stat()
        guard fstatat(directory, Self.filename, &info, AT_SYMLINK_NOFOLLOW) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else { throw StorageTransferRemoteCancellationError.unsafeFile }
        guard unlinkat(directory, Self.filename, 0) == 0, fsync(directory) == 0 else {
            throw StorageTransferRemoteCancellationError.unsafeFile
        }
    }

    private func requireRoot() throws {
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw StorageTransferRemoteCancellationError.unsafeFile
        }
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func synchronizeFile() throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw StorageTransferRemoteCancellationError.unsafeFile }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, fsync(descriptor) == 0 else {
            throw StorageTransferRemoteCancellationError.unsafeFile
        }
    }

    private func synchronizeRoot() throws {
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StorageTransferRemoteCancellationError.unsafeFile }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw StorageTransferRemoteCancellationError.unsafeFile }
    }
}
