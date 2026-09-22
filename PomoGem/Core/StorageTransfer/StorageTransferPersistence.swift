import CryptoKit
import Darwin
import Foundation
import SwiftData

/// Creates explicit split stores for an unpublished transfer session. The
/// caller owns account authorization, container lifetime and cloud admission.
/// The frozen byte backup is never opened by SwiftData: readers get a separate
/// disposable copy because even a .none mount may checkpoint SQLite metadata.
@MainActor
enum StorageTransferPersistence {
    private static let lifetimes = PersistenceContainerLifetimeTracker<ModelContainer>()

    static func requireAllReleased() throws {
        do { try lifetimes.requireAllReleased() }
        catch { throw StorageTransferRuntimeError.relaunchRequired }
    }

    static func makeContainer(selection: PersistenceDeploymentSelection,
                              urls: [URL], cloudEnabled: Bool) throws -> ModelContainer {
        guard urls.count == 2, urls[0] != urls[1],
              urls[0].deletingLastPathComponent() == urls[1].deletingLastPathComponent() else {
            throw StorageTransferError.unsafePath
        }
        let directory = urls[0].deletingLastPathComponent()
        try requireDirectory(directory)
        for url in urls {
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFREG else { throw StorageTransferError.unsafePath }
            } else if errno != ENOENT {
                throw StorageTransferError.unsafePath
            }
        }
        let sourceName: String
        let projectionName: String
        let cloud: ModelConfiguration.CloudKitDatabase
        switch selection {
        case .cloud:
            sourceName = PersistenceStoreTopology.cloudStoreName
            projectionName = PersistenceStoreTopology.localProjectionStoreName
            cloud = cloudEnabled ? .private(CloudSyncConfiguration.synchronizedDataContainerIdentifier) : .none
        case .localOnly:
            guard !cloudEnabled else { throw StorageTransferError.invalidJournal }
            sourceName = PersistenceStoreTopology.localOnlySourceStoreName
            projectionName = PersistenceStoreTopology.localOnlyProjectionStoreName
            cloud = .none
        }
        try requireAllReleased()
        let container = try ModelContainer(for: PersistenceStoreTopology.shippingSchema, configurations: [
            ModelConfiguration(sourceName, schema: PersistenceStoreTopology.cloudSchema,
                               url: urls[0], cloudKitDatabase: cloud),
            ModelConfiguration(projectionName, schema: PersistenceStoreTopology.localProjectionSchema,
                               url: urls[1], cloudKitDatabase: .none)
        ])
        lifetimes.track(container)
        return container
    }

    static func snapshotFrozenSource(journal: StorageTransferJournal,
                                     files: StorageTransferStoreFiles) throws -> PomoGemStorageSnapshot {
        try requireAllReleased()
        let urls = try files.makeFrozenReaderCopy(selection: journal.source)
        return try autoreleasepool {
            let container = try makeContainer(selection: journal.source, urls: urls, cloudEnabled: false)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            // The same check is repeated after cloud hydration. A timer that
            // arrived while leaving Settings must not silently migrate owners.
            if !discardsObsoleteCloudCache(journal: journal),
               try FocusCloudSyncStore.canonicalActive(context: context) != nil {
                throw StorageTransferError.activeTimer
            }
            return try PomoGemStorageSnapshot.capture(from: context)
        }
    }

    /// A cloud-sourced `enableCloudKeepingCloud` is the one transfer that
    /// throws the old cache away, so a canonical timer inside it is not a
    /// reason to abort. Every other choice - including both directions of a
    /// device -> iCloud overwrite - KEEPS that cache as the payload it is about
    /// to publish, so an active or paused canonical timer still aborts before
    /// any remote call is made.
    static func discardsObsoleteCloudCache(journal: StorageTransferJournal) -> Bool {
        if case .cloud = journal.source, journal.choice == .enableCloudKeepingCloud { return true }
        return false
    }

    private static func requireDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw StorageTransferError.unsafePath }
        } else if errno == ENOENT {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        } else { throw StorageTransferError.unsafePath }
    }
}

/// An immutable payload plus an atomic acknowledgement. Losing the response
/// after the payload write does not permit a retry to substitute different
/// data. The receipt is durable only after the exact file bytes are verified.
@MainActor
struct StorageTransferPayloadStore {
    let files: StorageTransferStoreFiles
    private var receiptURL: URL { files.transactionDirectory.appendingPathComponent("payload-receipt-v1.json") }

    func acknowledgedReceipt() throws -> PomoGemStorageSnapshot.Receipt? {
        guard let data = try readRegularFile(receiptURL, maximumBytes: 32_768, optional: true) else { return nil }
        let receipt = try JSONDecoder().decode(PomoGemStorageSnapshot.Receipt.self, from: data)
        guard AppleAccountFingerprint.isValid(receipt.sha256),
              receipt.encodedBytes > 0,
              receipt.encodedBytes <= PomoGemStorageSnapshot.Limits.standard.maximumEncodedBytes,
              Set(receipt.recordCounts.keys) == Set(PomoGemStorageSnapshot.modelNames),
              receipt.recordCounts.values.allSatisfy({ $0 >= 0 && $0 <= PomoGemStorageSnapshot.Limits.standard.maximumRecords }) else {
            throw StorageTransferError.invalidJournal
        }
        let snapshot = try PomoGemStorageSnapshot.read(from: files.snapshotURL, expectedDigest: receipt.sha256)
        let size = try files.snapshotURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard snapshot.recordCounts == receipt.recordCounts, size == receipt.encodedBytes else {
            throw StorageTransferError.snapshotMismatch
        }
        return receipt
    }

    func save(_ snapshot: PomoGemStorageSnapshot) throws -> PomoGemStorageSnapshot.Receipt {
        try snapshot.validate()
        if let receipt = try acknowledgedReceipt() {
            let existing = try PomoGemStorageSnapshot.read(from: files.snapshotURL, expectedDigest: receipt.sha256)
            guard try existing.isEquivalent(to: snapshot) else { throw StorageTransferError.snapshotMismatch }
            return receipt
        }
        let receipt: PomoGemStorageSnapshot.Receipt
        if let data = try readRegularFile(files.snapshotURL,
            maximumBytes: PomoGemStorageSnapshot.Limits.standard.maximumEncodedBytes, optional: true) {
            let existing = try JSONDecoder().decode(PomoGemStorageSnapshot.self, from: data)
            guard try existing.isEquivalent(to: snapshot) else { throw StorageTransferError.snapshotMismatch }
            receipt = PomoGemStorageSnapshot.Receipt(sha256: StorageTransferRecoverySchema.digest(data),
                encodedBytes: data.count, recordCounts: existing.recordCounts)
            try synchronizeFile(files.snapshotURL)
        } else {
            receipt = try snapshot.write(to: files.snapshotURL)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(receipt).write(to: receiptURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try synchronizeFile(receiptURL)
        let descriptor = open(files.transactionDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StorageTransferError.unsafePath }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard try acknowledgedReceipt() == receipt else { throw StorageTransferError.snapshotMismatch }
        return receipt
    }

    /// Reinstallation recovery preserves the exact server-acknowledged bytes;
    /// re-encoding an equivalent graph would produce a different receipt hash.
    func saveRecovered(_ data: Data, manifest: StorageTransferRecoveryManifest) throws -> PomoGemStorageSnapshot.Receipt {
        try manifest.validate(payload: data)
        let snapshot = try JSONDecoder().decode(PomoGemStorageSnapshot.self, from: data)
        try snapshot.validate()
        if let existing = try readRegularFile(files.snapshotURL,
            maximumBytes: PomoGemStorageSnapshot.Limits.standard.maximumEncodedBytes, optional: true) {
            guard existing == data else { throw StorageTransferError.snapshotMismatch }
        } else {
            try data.write(to: files.snapshotURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        let receipt = try save(snapshot)
        guard receipt.sha256 == manifest.payloadSHA256 else { throw StorageTransferError.snapshotMismatch }
        return receipt
    }

    func load(expectedDigest: String) throws -> PomoGemStorageSnapshot {
        guard try acknowledgedReceipt()?.sha256 == expectedDigest else { throw StorageTransferError.snapshotMismatch }
        return try PomoGemStorageSnapshot.read(from: files.snapshotURL, expectedDigest: expectedDigest)
    }

    func bytes(expectedDigest: String) throws -> Data {
        guard let receipt = try acknowledgedReceipt(), receipt.sha256 == expectedDigest,
              let data = try readRegularFile(files.snapshotURL, maximumBytes: receipt.encodedBytes, optional: false),
              data.count == receipt.encodedBytes, StorageTransferRecoverySchema.digest(data) == expectedDigest else {
            throw StorageTransferError.snapshotMismatch
        }
        return data
    }

    private func readRegularFile(_ url: URL, maximumBytes: Int, optional: Bool) throws -> Data? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if optional && errno == ENOENT { return nil }
            throw StorageTransferError.unsafePath
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0, info.st_size <= maximumBytes else {
            throw StorageTransferError.unsafePath
        }
        let data = try Data(contentsOf: url)
        guard data.count == info.st_size, data.count <= maximumBytes else { throw StorageTransferError.unsafePath }
        return data
    }

    private func synchronizeFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
