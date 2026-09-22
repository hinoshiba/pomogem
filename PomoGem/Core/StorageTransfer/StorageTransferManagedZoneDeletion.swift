import CloudKit
import Foundation

enum StorageTransferManagedZoneDeletionError: Error, Equatable {
    case invalidPlan, unsupportedZone, stalePlan, changedCloudData
    case invalidRecoveryReceipt, missingAcknowledgment, destinationAlreadyStarted
}

/// This is an exact allowlist, not a discovery predicate for deletion. The
/// framework currently has one managed custom zone in the current owner's
/// private database. Default, transfer-control and unknown zones are excluded.
struct StorageTransferManagedZoneID: Codable, Equatable, Sendable {
    let zoneName: String
    let ownerName: String

    init(_ id: CKRecordZone.ID) throws {
        zoneName = id.zoneName
        ownerName = id.ownerName
        try validate()
    }

    func validate() throws {
        guard zoneName == StorageTransferCloudSchema.managedZoneName,
              ownerName == CKRecordZone.default().zoneID.ownerName else {
            throw StorageTransferManagedZoneDeletionError.unsupportedZone
        }
    }

    var cloudKitID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName) }
}

/// A complete read from the strict source reader, whose output has stable
/// record-name ordering. Both graph bytes and terminal tokens must match before
/// deletion. This is read evidence, not an all-device transaction lock.
struct StorageTransferManagedZoneObservation: Codable, Equatable, Sendable {
    struct Zone: Codable, Equatable, Sendable {
        let id: StorageTransferManagedZoneID
        let terminalToken: Data
        let recordCount: Int
    }

    let accountFingerprint: String
    let snapshotSHA256: String
    let recordCount: Int
    let zones: [Zone]

    @MainActor init(snapshot: CloudStorageTransferSnapshot) throws {
        try snapshot.snapshot.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(snapshot.snapshot)
        guard bytes.count <= StorageTransferRecoverySchema.maximumPayloadBytes else {
            throw StorageTransferManagedZoneDeletionError.invalidPlan
        }
        accountFingerprint = snapshot.binding.accountFingerprint
        snapshotSHA256 = StorageTransferRecoverySchema.digest(bytes)
        recordCount = snapshot.snapshot.records.count
        zones = try snapshot.zones.map {
            Zone(id: try StorageTransferManagedZoneID($0.zoneID),
                 terminalToken: $0.terminalToken, recordCount: $0.recordCount)
        }
        try validate()
    }

    func validate() throws {
        guard StorageTransferRecoverySchema.isDigest(accountFingerprint),
              StorageTransferRecoverySchema.isDigest(snapshotSHA256),
              (0...100_000).contains(recordCount), zones.count <= 1 else {
            throw StorageTransferManagedZoneDeletionError.invalidPlan
        }
        for zone in zones {
            try zone.id.validate()
            guard !zone.terminalToken.isEmpty, zone.terminalToken.count <= 65_536,
                  zone.recordCount == recordCount else { throw StorageTransferManagedZoneDeletionError.invalidPlan }
        }
        guard !zones.isEmpty || recordCount == 0 else { throw StorageTransferManagedZoneDeletionError.invalidPlan }
    }

    var confirmsNoManagedZone: Bool { zones.isEmpty && recordCount == 0 }
}

/// Persist before the first delete. The baseline never changes on retry, and
/// an absent zone counts as completed only after intent was durably recorded.
/// A completed plan never authorizes deleting a newly created destination.
struct StorageTransferManagedZoneDeletionPlan: Codable, Equatable, Sendable {
    enum Phase: Int, Codable, Sendable { case prepared, deletionIntentRecorded, absenceVerified }
    let formatVersion: Int
    let transactionID: UUID
    let accountFingerprint: String
    let sourcePayloadSHA256: String
    let baseline: StorageTransferManagedZoneObservation
    private(set) var phase: Phase
    private(set) var revision: Int

    init(manifest: StorageTransferRecoveryManifest, baseline: StorageTransferManagedZoneObservation) throws {
        try manifest.validate()
        formatVersion = 1
        transactionID = manifest.transactionID
        accountFingerprint = manifest.accountFingerprint
        sourcePayloadSHA256 = manifest.payloadSHA256
        self.baseline = baseline
        phase = .prepared
        revision = 0
        try validate()
    }

    func validate() throws {
        try baseline.validate()
        guard formatVersion == 1,
              StorageTransferRecoverySchema.isDigest(accountFingerprint),
              StorageTransferRecoverySchema.isDigest(sourcePayloadSHA256),
              baseline.accountFingerprint == accountFingerprint,
              revision == phase.rawValue else { throw StorageTransferManagedZoneDeletionError.invalidPlan }
    }

    func advancing(to next: Phase) throws -> Self {
        try validate()
        guard next.rawValue == phase.rawValue + 1 else { throw StorageTransferManagedZoneDeletionError.stalePlan }
        var value = self
        value.phase = next
        value.revision += 1
        try value.validate()
        return value
    }
}

/// save is a durable compare-and-swap: success requires atomic persistence,
/// file and parent-directory synchronization, and independent readback. A
/// missing or corrupt file must not silently authorize creating a new plan.
@MainActor
protocol StorageTransferManagedZoneDeletionStore {
    func load() throws -> StorageTransferManagedZoneDeletionPlan?
    func save(_ plan: StorageTransferManagedZoneDeletionPlan,
              replacing previous: StorageTransferManagedZoneDeletionPlan?) throws
}

enum StorageTransferManagedZoneDeleteAcknowledgment: Equatable, Sendable {
    case deleted(StorageTransferManagedZoneID)
    case alreadyAbsent(StorageTransferManagedZoneID)

    var zoneID: StorageTransferManagedZoneID {
        switch self { case .deleted(let id), .alreadyAbsent(let id): id }
    }
}

/// Only the same synchronized container's private database is permitted. The
/// live adapter must use the strict complete source reader, reject unknown
/// zones/records, bound and cancel operations, and require per-zone deletion
/// acknowledgments. Only authoritative zone-not-found can mean alreadyAbsent;
/// an overall operation callback with missing item results is an error.
@MainActor
protocol StorageTransferManagedZoneDeletionBackend {
    func readSnapshot() async throws -> StorageTransferManagedZoneObservation
    func deleteZone(_ id: StorageTransferManagedZoneID) async throws -> StorageTransferManagedZoneDeleteAcknowledgment
}

struct StorageTransferManagedZoneAbsenceReceipt: Equatable, Sendable {
    let plan: StorageTransferManagedZoneDeletionPlan
    fileprivate init(plan: StorageTransferManagedZoneDeletionPlan) { self.plan = plan }
}

/// Initial destination preparation only. No ModelContainer construction,
/// record writes, partial-destination cleanup, broad zone clear, or operations
/// container access is part of this coordinator. CloudKit offers no conditional
/// zone deletion based on a change token; an old client can race the final read
/// and delete. The remote fence protects cooperating clients, not all releases.
@MainActor
struct StorageTransferManagedZoneDeletion {
    private let store: any StorageTransferManagedZoneDeletionStore
    private let backend: any StorageTransferManagedZoneDeletionBackend
    private let recovery: StorageTransferRemoteRecovery
    /// Must prove the exact local generation/journal and that no CloudKit
    /// mirror has been opened in this process. Retirement alone is insufficient.
    private let validateGenerationAndQuiescence: () throws -> Void

    init(store: any StorageTransferManagedZoneDeletionStore,
         backend: any StorageTransferManagedZoneDeletionBackend,
         recovery: StorageTransferRemoteRecovery,
         validateGenerationAndQuiescence: @escaping () throws -> Void) {
        self.store = store
        self.backend = backend
        self.recovery = recovery
        self.validateGenerationAndQuiescence = validateGenerationAndQuiescence
    }

    /// The caller retains this transaction-owned plan alongside the original
    /// payload. Retrying preparation never recaptures an altered cloud baseline.
    func persistPlan(_ plan: StorageTransferManagedZoneDeletionPlan) throws {
        try plan.validate()
        try Task.checkCancellation()
        try validateGenerationAndQuiescence()
        if let existing = try store.load() {
            try existing.validate()
            guard existing.transactionID == plan.transactionID,
                  existing.accountFingerprint == plan.accountFingerprint,
                  existing.sourcePayloadSHA256 == plan.sourcePayloadSHA256,
                  existing.baseline == plan.baseline,
                  plan.phase == .prepared || existing == plan else {
                throw StorageTransferManagedZoneDeletionError.stalePlan
            }
            return
        }
        guard plan.phase == .prepared else { throw StorageTransferManagedZoneDeletionError.invalidPlan }
        try store.save(plan, replacing: nil)
        guard try store.load() == plan else { throw StorageTransferManagedZoneDeletionError.stalePlan }
    }

    func run(transactionID: UUID, recoveryReceipt: StorageTransferRecoveryReceipt) async throws -> StorageTransferManagedZoneAbsenceReceipt {
        guard var plan = try store.load(), plan.transactionID == transactionID else {
            throw StorageTransferManagedZoneDeletionError.stalePlan
        }
        try await validate(plan, recoveryReceipt: recoveryReceipt)
        if plan.phase == .prepared {
            let observed = try await observe(plan, recoveryReceipt: recoveryReceipt)
            guard observed == plan.baseline else { throw StorageTransferManagedZoneDeletionError.changedCloudData }
            plan = try save(plan.advancing(to: .deletionIntentRecorded), replacing: plan)
        }
        if plan.phase == .deletionIntentRecorded {
            let observed = try await observe(plan, recoveryReceipt: recoveryReceipt)
            if !observed.confirmsNoManagedZone {
                guard observed == plan.baseline, let zone = plan.baseline.zones.first else {
                    throw StorageTransferManagedZoneDeletionError.changedCloudData
                }
                try await validate(plan, recoveryReceipt: recoveryReceipt)
                let acknowledgment = try await backend.deleteZone(zone.id)
                // Cancellation or an uncertain response retains the durable
                // intent. A later run must inspect, never guess success.
                try await validate(plan, recoveryReceipt: recoveryReceipt)
                guard acknowledgment.zoneID == zone.id else {
                    throw StorageTransferManagedZoneDeletionError.missingAcknowledgment
                }
                let after = try await observe(plan, recoveryReceipt: recoveryReceipt)
                guard after.confirmsNoManagedZone else {
                    throw StorageTransferManagedZoneDeletionError.changedCloudData
                }
            }
            plan = try save(plan.advancing(to: .absenceVerified), replacing: plan)
        }
        // This prevents replay of the old deletion plan after a destination
        // started exporting, including after an uninstall lost local staging.
        let final = try await observe(plan, recoveryReceipt: recoveryReceipt)
        guard final.confirmsNoManagedZone else {
            throw StorageTransferManagedZoneDeletionError.destinationAlreadyStarted
        }
        return StorageTransferManagedZoneAbsenceReceipt(plan: plan)
    }

    /// Use immediately before initial fresh destination admission. Once its
    /// mirror has started, recovery must reconcile that same destination rather
    /// than calling this original deletion plan to delete it again.
    func revalidateAdmission(_ receipt: StorageTransferManagedZoneAbsenceReceipt,
                             recoveryReceipt: StorageTransferRecoveryReceipt) async throws {
        guard receipt.plan.phase == .absenceVerified else { throw StorageTransferManagedZoneDeletionError.stalePlan }
        let observed = try await observe(receipt.plan, recoveryReceipt: recoveryReceipt)
        guard observed.confirmsNoManagedZone else { throw StorageTransferManagedZoneDeletionError.destinationAlreadyStarted }
    }

    private func observe(_ plan: StorageTransferManagedZoneDeletionPlan,
                         recoveryReceipt: StorageTransferRecoveryReceipt) async throws -> StorageTransferManagedZoneObservation {
        try await validate(plan, recoveryReceipt: recoveryReceipt)
        let result = try await backend.readSnapshot()
        try await validate(plan, recoveryReceipt: recoveryReceipt)
        try result.validate()
        guard result.accountFingerprint == plan.accountFingerprint else {
            throw StorageTransferManagedZoneDeletionError.invalidRecoveryReceipt
        }
        return result
    }

    private func validate(_ plan: StorageTransferManagedZoneDeletionPlan,
                          recoveryReceipt: StorageTransferRecoveryReceipt) async throws {
        try plan.validate()
        let control = recoveryReceipt.envelope.control
        guard control.phase == .replacing,
              control.manifest.transactionID == plan.transactionID,
              control.manifest.accountFingerprint == plan.accountFingerprint,
              control.manifest.payloadSHA256 == plan.sourcePayloadSHA256 else {
            throw StorageTransferManagedZoneDeletionError.invalidRecoveryReceipt
        }
        try localValidation(plan)
        try await recovery.revalidateReplacement(recoveryReceipt)
        try localValidation(plan)
    }

    private func localValidation(_ plan: StorageTransferManagedZoneDeletionPlan) throws {
        try Task.checkCancellation()
        try validateGenerationAndQuiescence()
        guard try store.load() == plan else { throw StorageTransferManagedZoneDeletionError.stalePlan }
    }

    private func save(_ next: StorageTransferManagedZoneDeletionPlan,
                      replacing previous: StorageTransferManagedZoneDeletionPlan) throws -> StorageTransferManagedZoneDeletionPlan {
        try localValidation(previous)
        try next.validate()
        try store.save(next, replacing: previous)
        guard try store.load() == next else { throw StorageTransferManagedZoneDeletionError.stalePlan }
        return next
    }
}
