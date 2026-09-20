import Darwin
import Foundation

/// Small transaction/admission receipts. The pathname is owned by this feature;
/// every read rejects links and special files before decoding bounded bytes.
@MainActor
struct StorageTransferStateFile<Value: Codable & Equatable> {
    let url: URL
    let maximumBytes: Int

    init(url: URL, maximumBytes: Int = 131_072) throws {
        guard url.isFileURL, maximumBytes > 0 else { throw StorageTransferError.unsafePath }
        self.url = url.standardizedFileURL
        self.maximumBytes = maximumBytes
        let parent = self.url.deletingLastPathComponent()
        var info = stat()
        if lstat(parent.path, &info) != 0 {
            guard errno == ENOENT else { throw StorageTransferError.unsafePath }
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        guard lstat(parent.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw StorageTransferError.unsafePath
        }
    }

    func load() throws -> Value? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw StorageTransferError.unsafePath
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= maximumBytes else { throw StorageTransferError.unsafePath }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count == info.st_size, data.count <= maximumBytes,
              (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw StorageTransferError.unsafePath }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value, replacing previous: Value?) throws {
        guard try load() == previous else { throw StorageTransferError.staleTransaction }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard !data.isEmpty, data.count <= maximumBytes else { throw StorageTransferError.invalidJournal }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StorageTransferError.unsafePath }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0, try load() == value else { throw StorageTransferError.invalidJournal }
    }
}

struct StorageTransferRuntimeCheckpoint: Codable, Equatable {
    var formatVersion = 1
    let transactionID: UUID
    var requestingProcessID: UUID?
    var didObserveBaselineControl = false
    var baselineControl: StorageTransferRecoveryControl?
    var recoveredFromServer = false
    var partialRecoveryAttemptID: UUID?
    var recoveryManifest: StorageTransferRecoveryManifest?
    var importedPayloadDigest: String?
    var cloudExportIntentRecorded = false
    var verifiedCloudProcessID: UUID?
    var verifiedCloudPayloadDigest: String?

    func validate(journal: StorageTransferJournal) throws {
        try journal.validate()
        guard formatVersion == 1, transactionID == journal.transactionID,
              requestingProcessID != nil, didObserveBaselineControl,
              importedPayloadDigest.map(AppleAccountFingerprint.isValid) ?? true,
              verifiedCloudPayloadDigest.map(AppleAccountFingerprint.isValid) ?? true,
              (verifiedCloudProcessID == nil) == (verifiedCloudPayloadDigest == nil) else {
            throw StorageTransferError.invalidJournal
        }
        try baselineControl?.validate()
        if let baselineControl {
            guard baselineControl.manifest.accountFingerprint == journal.cloudBinding.accountFingerprint else {
                throw StorageTransferError.invalidJournal
            }
            if recoveredFromServer {
                guard baselineControl.manifest.transactionID == transactionID,
                      baselineControl.blocksWriters else { throw StorageTransferError.invalidJournal }
            } else {
                guard baselineControl.isTerminal else { throw StorageTransferError.invalidJournal }
            }
        } else if recoveredFromServer { throw StorageTransferError.invalidJournal }
        // Restoring a server payload must not grant authority over a previous
        // installation's source path. Runtime separately proves that this new
        // local-only namespace has no files before it may skip source retirement.
        // Deliberately NOT relaxed for `.overwriteCloudFromDevice`: its second
        // journal shape `(.localOnly, .cloud)` exists precisely so a reinstall
        // keeps satisfying this rule. A cloud-source overwrite owns a real store
        // and must retire it, so it can never claim a server origin.
        if recoveredFromServer {
            guard journal.choice.replacesCloud,
                  case .localOnly = journal.source else { throw StorageTransferError.invalidJournal }
        }
        if partialRecoveryAttemptID != nil {
            guard recoveredFromServer, journal.choice.replacesCloud,
                  recoveryManifest != nil else { throw StorageTransferError.invalidJournal }
        }
        if let recoveryManifest {
            try recoveryManifest.validate()
            guard journal.choice.replacesCloud, journal.phase >= .sourceSaved,
                  recoveryManifest.transactionID == transactionID,
                  recoveryManifest.accountFingerprint == journal.cloudBinding.accountFingerprint,
                  recoveryManifest.previousDatasetGenerationID == baselineControl?.datasetGenerationID,
                  recoveryManifest.payloadSHA256 == journal.sourceDigest else {
                throw StorageTransferError.invalidJournal
            }
            if recoveredFromServer, baselineControl?.manifest != recoveryManifest {
                throw StorageTransferError.invalidJournal
            }
        }
        if journal.choice.replacesCloud, journal.phase >= .recoveryCopySaved,
           recoveryManifest == nil { throw StorageTransferError.invalidJournal }

        if let importedPayloadDigest {
            guard journal.phase >= .preparingDestination,
                  journal.choice != .enableCloudKeepingCloud,
                  importedPayloadDigest == journal.sourceDigest else { throw StorageTransferError.invalidJournal }
        }
        if cloudExportIntentRecorded {
            guard journal.choice.replacesCloud, journal.phase >= .preparingDestination,
                  importedPayloadDigest == journal.sourceDigest else { throw StorageTransferError.invalidJournal }
        }
        if let verifiedCloudPayloadDigest {
            guard journal.phase >= .preparingDestination,
                  journal.choice != .disableCloudKeepingCopy else { throw StorageTransferError.invalidJournal }
            if journal.choice.replacesCloud {
                guard cloudExportIntentRecorded, importedPayloadDigest == journal.sourceDigest,
                      verifiedCloudPayloadDigest == journal.sourceDigest else { throw StorageTransferError.invalidJournal }
            }
            if let destinationDigest = journal.destinationDigest {
                guard verifiedCloudPayloadDigest == destinationDigest else { throw StorageTransferError.invalidJournal }
            }
        }
        // The main journal cannot acknowledge destinationSaved before its
        // corresponding import/mirroring effect has its own durable receipt.
        if journal.phase >= .destinationSaved {
            switch journal.choice {
            case .disableCloudKeepingCopy:
                guard importedPayloadDigest == journal.sourceDigest else { throw StorageTransferError.invalidJournal }
            case .enableCloudKeepingCloud:
                guard verifiedCloudProcessID != nil else { throw StorageTransferError.invalidJournal }
            // Both replacement kinds destroy the remote dataset, so both need
            // the acknowledged local import AND an independent process's proof
            // that the new namespace was mirrored back out of CloudKit.
            case .enableCloudReplacingCloud, .overwriteCloudFromDevice:
                guard importedPayloadDigest == journal.sourceDigest,
                      verifiedCloudProcessID != nil else { throw StorageTransferError.invalidJournal }
            }
        }
    }
}

struct StorageTransferDatasetAdmission: Codable, Equatable {
    let binding: ActiveAccountLocalBinding
    let datasetGenerationID: UUID?
}
