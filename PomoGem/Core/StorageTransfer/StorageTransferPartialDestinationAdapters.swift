import CloudKit
import Darwin
import Foundation

@MainActor
final class StorageTransferPartialDestinationFileStore: StorageTransferPartialDestinationPlanStore {
    static let filename = "partial-destination-recovery-v1.json"
    static let maximumBytes = 256 * 1_024
    private let directory: URL
    private let transactionID: UUID
    private var url: URL { directory.appendingPathComponent(Self.filename) }

    init(transactionDirectory: URL, transactionID: UUID) throws {
        guard transactionDirectory.isFileURL else { throw StorageTransferManagedZoneAdapterError.unsafeFile }
        directory = transactionDirectory.standardizedFileURL
        self.transactionID = transactionID
        try requireDirectory()
    }

    func load() throws -> StorageTransferPartialDestinationPlan? {
        try requireDirectory()
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw StorageTransferManagedZoneAdapterError.unsafeFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= Self.maximumBytes else {
            throw StorageTransferManagedZoneAdapterError.unsafeFile
        }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes, data.count == info.st_size,
              (try handle.read(upToCount: 1) ?? Data()).isEmpty else {
            throw StorageTransferManagedZoneAdapterError.oversizedPlan
        }
        let value = try JSONDecoder().decode(StorageTransferPartialDestinationPlan.self, from: data)
        try validate(value)
        let canonical = try encoder().encode(value)
        guard let original = try JSONSerialization.jsonObject(with: data) as? NSDictionary,
              let known = try JSONSerialization.jsonObject(with: canonical) as? NSDictionary,
              original == known else { throw StorageTransferPartialRecoveryError.invalidPlan }
        return value
    }

    func save(_ plan: StorageTransferPartialDestinationPlan,
              replacing previous: StorageTransferPartialDestinationPlan?) throws {
        try validate(plan)
        guard try load() == previous else { throw StorageTransferPartialRecoveryError.stalePlan }
        if let previous {
            try validate(previous)
            guard plan.attemptID == previous.attemptID, plan.transactionID == previous.transactionID,
                  plan.accountFingerprint == previous.accountFingerprint,
                  plan.sourcePayloadSHA256 == previous.sourcePayloadSHA256,
                  plan.observedSHA256 == previous.observedSHA256,
                  plan.observedRecordCount == previous.observedRecordCount,
                  plan.zone == previous.zone, plan.terminalToken == previous.terminalToken,
                  plan.revision == previous.revision + 1 else {
                throw StorageTransferPartialRecoveryError.stalePlan
            }
        } else if plan.phase != .verifiedSubset {
            throw StorageTransferPartialRecoveryError.invalidPlan
        }
        let data = try encoder().encode(plan)
        guard data.count <= Self.maximumBytes else { throw StorageTransferManagedZoneAdapterError.oversizedPlan }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try synchronize(url, directory: false)
        try synchronize(directory, directory: true)
        guard try load() == plan else { throw StorageTransferPartialRecoveryError.stalePlan }
    }

    private func validate(_ plan: StorageTransferPartialDestinationPlan) throws {
        try plan.validate()
        guard plan.transactionID == transactionID else { throw StorageTransferPartialRecoveryError.stalePlan }
    }

    private func requireDirectory() throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw StorageTransferManagedZoneAdapterError.unsafeFile
        }
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func synchronize(_ url: URL, directory: Bool) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | (directory ? O_DIRECTORY : O_NONBLOCK))
        guard descriptor >= 0 else { throw StorageTransferManagedZoneAdapterError.unsafeFile }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG) else {
            throw StorageTransferManagedZoneAdapterError.unsafeFile
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// Adapt only a successfully validated strict graph. The existing reader
/// rejects dangling foreign keys before this conversion; no missing parent is
/// fabricated. Synthetic names retain physical graph references, not original
/// CKRecord names. Fixed-attempt equality therefore also requires the actual
/// server terminal token, which is retained unchanged in the observation.
enum StorageTransferPartialStrictGraphAdapter {
    @MainActor static func observation(_ snapshot: CloudStorageTransferSnapshot) throws -> StorageTransferPartialDestinationObservation {
        try snapshot.snapshot.validate()
        _ = try StorageTransferManagedZoneObservation(snapshot: snapshot)
        guard snapshot.snapshot.records.allSatisfy({ PomoGemStorageSnapshot.cloudModelNames.contains($0.entity) }) else {
            throw StorageTransferPartialRecoveryError.invalidObservation
        }
        func name(_ reference: Int) -> String { "strict-physical-row-\(reference)" }
        let zone = snapshot.zones.first?.zoneID
        let rows = try snapshot.snapshot.records.map { record -> CloudStorageTransferDecodedRecord in
            guard let zone else { throw StorageTransferPartialRecoveryError.invalidObservation }
            let subject: CKRecord.ID?
            if case let .toOne(reference)? = record.relationships["subject"], let reference {
                subject = CKRecord.ID(recordName: name(reference), zoneID: zone)
            } else { subject = nil }
            return CloudStorageTransferDecodedRecord(id: CKRecord.ID(recordName: name(record.reference), zoneID: zone),
                entity: record.entity, fields: record.fields, subject: subject)
        }
        return try StorageTransferPartialDestinationObservation(accountFingerprint: snapshot.binding.accountFingerprint,
                                                                zones: snapshot.zones, records: rows)
    }
}

/// Composes the already bounded, account-leased exact-zone adapter. The capture
/// is scoped to one strict read and cleared after success/failure; stale late
/// callbacks cannot publish it after cancellation. No unfiltered CloudKit read
/// or independent deletion transport is introduced here.
@MainActor
final class StorageTransferPartialDestinationCloudKit: StorageTransferPartialDestinationBackend {
    private final class ReadCapture { var snapshot: CloudStorageTransferSnapshot? }
    private let capture: ReadCapture
    private let transport: StorageTransferManagedZoneDeletionCloudKit
    private var reading = false

    init(expectedBinding: ActiveAccountLocalBinding,
         client: StorageTransferManagedZoneCloudClient? = nil,
         timeout: TimeInterval = 180,
         notificationCenter: NotificationCenter = .default,
         validateAccess: @escaping () throws -> Void) {
        let capture = ReadCapture()
        self.capture = capture
        let source = client ?? .live(validateAccess: validateAccess)
        let wrapped = StorageTransferManagedZoneCloudClient(verifyAccount: source.verifyAccount,
            readSnapshot: { binding in
                let snapshot = try await source.readSnapshot(binding)
                try Task.checkCancellation()
                capture.snapshot = snapshot
                return snapshot
            }, deleteZone: source.deleteZone)
        transport = StorageTransferManagedZoneDeletionCloudKit(expectedBinding: expectedBinding, client: wrapped,
            timeout: timeout, notificationCenter: notificationCenter, validateAccess: validateAccess)
    }

    func readRawDestination() async throws -> StorageTransferPartialDestinationObservation {
        guard !reading else { throw StorageTransferPartialRecoveryError.stalePlan }
        reading = true
        capture.snapshot = nil
        defer { reading = false; capture.snapshot = nil }
        let observed: StorageTransferManagedZoneObservation
        do { observed = try await transport.readSnapshot() }
        catch CloudStorageTransferCloudError.missingRelationship {
            throw StorageTransferPartialRecoveryError.danglingRelationship
        }
        guard let snapshot = capture.snapshot,
              try StorageTransferManagedZoneObservation(snapshot: snapshot) == observed else {
            throw StorageTransferPartialRecoveryError.invalidObservation
        }
        return try StorageTransferPartialStrictGraphAdapter.observation(snapshot)
    }

    func deleteZone(_ id: StorageTransferManagedZoneID) async throws -> StorageTransferManagedZoneDeleteAcknowledgment {
        try await transport.deleteZone(id)
    }
}
