import CloudKit
import Foundation

enum StorageTransferPartialRecoveryError: Error, LocalizedError, Equatable {
    case invalidObservation, foreignRecord, ambiguousRecord, duplicateRecord
    case danglingRelationship, changedRelationship, changedObservation
    case invalidPlan, stalePlan, wrongRecovery, destinationAlreadyStarted

    var errorDescription: String? {
        "iCloudの途中データが復旧用コピーの一部であると確認できないため、復旧を停止しています。"
    }
}

/// A strict decoder's raw rows, before graph assembly. An absent foreign key
/// stays nil; a key pointing to a missing record stays a dangling reference.
/// Neither case is repaired or converted to the other for deletion approval.
struct StorageTransferPartialDestinationObservation: Codable, Equatable, Sendable {
    struct Row: Codable, Equatable, Sendable {
        let recordName: String
        let entity: String
        let fields: [String: PomoGemStorageSnapshot.Scalar]
        let subjectRecordName: String?
    }

    let accountFingerprint: String
    let zone: StorageTransferManagedZoneID?
    let terminalToken: Data?
    let rows: [Row]

    init(accountFingerprint: String, zones: [CloudStorageTransferZoneManifest],
         records: [CloudStorageTransferDecodedRecord]) throws {
        guard zones.count <= 1, records.count <= CloudStorageTransferZoneAccumulator.maximumRows else {
            throw StorageTransferPartialRecoveryError.invalidObservation
        }
        self.accountFingerprint = accountFingerprint
        let selectedZone = try zones.first.map { try StorageTransferManagedZoneID($0.zoneID) }
        zone = selectedZone
        terminalToken = zones.first?.terminalToken
        guard (zones.first?.recordCount ?? 0) == records.count else {
            throw StorageTransferPartialRecoveryError.invalidObservation
        }
        rows = try records.map { record in
            guard let zone = selectedZone, record.id.zoneID == zone.cloudKitID,
                  record.subject == nil || record.subject?.zoneID == zone.cloudKitID else {
                throw StorageTransferPartialRecoveryError.invalidObservation
            }
            return Row(recordName: record.id.recordName, entity: record.entity,
                       fields: record.fields, subjectRecordName: record.subject?.recordName)
        }.sorted { $0.recordName < $1.recordName }
        try validate()
    }

    func validate() throws {
        guard StorageTransferRecoverySchema.isDigest(accountFingerprint),
              rows.count <= CloudStorageTransferZoneAccumulator.maximumRows,
              rows == rows.sorted(by: { $0.recordName < $1.recordName }),
              Set(rows.map(\.recordName)).count == rows.count else {
            throw StorageTransferPartialRecoveryError.invalidObservation
        }
        if let zone {
            try zone.validate()
            guard let terminalToken, !terminalToken.isEmpty, terminalToken.count <= 65_536 else {
                throw StorageTransferPartialRecoveryError.invalidObservation
            }
        } else if terminalToken != nil || !rows.isEmpty {
            throw StorageTransferPartialRecoveryError.invalidObservation
        }
        var estimatedBytes = 0
        for row in rows {
            guard Self.validName(row.recordName),
                  PomoGemStorageSnapshot.cloudModelNames.contains(row.entity),
                  row.subjectRecordName.map(Self.validName) ?? true,
                  row.subjectRecordName == nil || ["StudySession", "AchievementStone"].contains(row.entity) else {
                throw StorageTransferPartialRecoveryError.invalidObservation
            }
            estimatedBytes += row.recordName.utf8.count + (row.subjectRecordName?.utf8.count ?? 0) + 128
            for (name, scalar) in row.fields {
                guard name.utf8.count <= 256 else { throw StorageTransferPartialRecoveryError.invalidObservation }
                let count: Int
                switch scalar {
                case .string(let value): count = value.utf8.count
                case .data(let value): count = value.count
                default: count = 32
                }
                guard count <= CloudStorageTransferRecordDecoder.maximumFieldBytes else {
                    throw StorageTransferPartialRecoveryError.invalidObservation
                }
                estimatedBytes += count + name.utf8.count
                guard estimatedBytes <= CloudStorageTransferZoneAccumulator.maximumBytes else {
                    throw StorageTransferPartialRecoveryError.invalidObservation
                }
            }
            guard estimatedBytes <= CloudStorageTransferZoneAccumulator.maximumBytes else {
                throw StorageTransferPartialRecoveryError.invalidObservation
            }
        }
    }

    var confirmsAbsence: Bool { zone == nil && rows.isEmpty && terminalToken == nil }

    func digest() throws -> String {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return StorageTransferRecoverySchema.digest(try encoder.encode(self))
    }

    private static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4_096 && !value.contains("\0")
    }
}

struct StorageTransferPartialSubsetProof: Equatable, Sendable {
    let observationSHA256: String
    let matchedRecordCount: Int
    fileprivate init(observationSHA256: String, matchedRecordCount: Int) {
        self.observationSHA256 = observationSHA256
        self.matchedRecordCount = matchedRecordCount
    }
}

/// Deliberately conservative induced-subgraph membership. Every source scalar,
/// including epochs, tombstones, revision evidence and quarantined payloads,
/// must match exactly except comparison-only 1ms Date quantization, matching
/// PomoGemStorageSnapshot.isEquivalent(dateTolerance: 0.001). This never rewrites
/// raw dates. Crossing a quantization boundary can conservatively reject a
/// smaller difference. Projections are not CloudKit rows. Physical duplicates
/// that cannot be assigned uniquely are blocked rather than guessed away.
enum StorageTransferPartialDestinationSubset {
    static let dateQuantum: TimeInterval = 0.001
    private struct Signature: Encodable {
        let entity: String
        let fields: [String: PomoGemStorageSnapshot.Scalar]
    }
    private struct Candidate {
        let record: PomoGemStorageSnapshot.Record
        let comparisonFields: [String: PomoGemStorageSnapshot.Scalar]
    }

    @MainActor static func verify(_ observation: StorageTransferPartialDestinationObservation,
                                  belongsTo snapshot: PomoGemStorageSnapshot) throws -> StorageTransferPartialSubsetProof {
        try observation.validate()
        try snapshot.validate()
        var candidates: [String: [Candidate]] = [:]
        for record in snapshot.records where PomoGemStorageSnapshot.cloudModelNames.contains(record.entity) {
            try Task.checkCancellation()
            let fields = try comparisonFields(record.fields)
            candidates[try signature(entity: record.entity, fields: fields), default: []]
                .append(Candidate(record: record, comparisonFields: fields))
        }
        var assigned: [String: PomoGemStorageSnapshot.Record] = [:]
        var used: Set<Int> = []
        for row in observation.rows {
            try Task.checkCancellation()
            let fields = try comparisonFields(row.fields)
            let matching = candidates[try signature(entity: row.entity, fields: fields), default: []]
                .filter { $0.record.entity == row.entity && $0.comparisonFields == fields }
            guard !matching.isEmpty else { throw StorageTransferPartialRecoveryError.foreignRecord }
            guard matching.count == 1 else { throw StorageTransferPartialRecoveryError.ambiguousRecord }
            let match = matching[0].record
            guard used.insert(match.reference).inserted else { throw StorageTransferPartialRecoveryError.duplicateRecord }
            assigned[row.recordName] = match
        }
        for row in observation.rows where ["StudySession", "AchievementStone"].contains(row.entity) {
            guard let original = assigned[row.recordName],
                  case let .toOne(expectedParent)? = original.relationships["subject"] else {
                throw StorageTransferPartialRecoveryError.changedRelationship
            }
            if let name = row.subjectRecordName {
                guard let actualParent = assigned[name] else {
                    // A bare CloudKit record name cannot prove which original
                    // Subject a not-yet-uploaded parent would have represented.
                    throw StorageTransferPartialRecoveryError.danglingRelationship
                }
                guard actualParent.entity == "Subject", expectedParent == actualParent.reference else {
                    throw StorageTransferPartialRecoveryError.changedRelationship
                }
            } else {
                guard expectedParent == nil else { throw StorageTransferPartialRecoveryError.changedRelationship }
            }
        }
        return StorageTransferPartialSubsetProof(observationSHA256: try observation.digest(),
                                                 matchedRecordCount: observation.rows.count)
    }

    private static func signature(entity: String, fields: [String: PomoGemStorageSnapshot.Scalar]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return StorageTransferRecoverySchema.digest(try encoder.encode(Signature(entity: entity, fields: fields)))
    }

    private static func comparisonFields(_ fields: [String: PomoGemStorageSnapshot.Scalar]) throws -> [String: PomoGemStorageSnapshot.Scalar] {
        try fields.mapValues { value in
            guard case let .dateBits(bits) = value else { return value }
            let date = Double(bitPattern: bits)
            guard date.isFinite, (date / dateQuantum).isFinite else {
                throw StorageTransferPartialRecoveryError.invalidObservation
            }
            return .dateBits(((date / dateQuantum).rounded() * dateQuantum).bitPattern)
        }
    }
}

/// A new, separately authorized recovery attempt, never the initial cloud
/// deletion plan. The exact partial read is immutable once intent is persisted.
struct StorageTransferPartialDestinationPlan: Codable, Equatable, Sendable {
    enum Phase: Int, Codable, Sendable { case verifiedSubset, deletionIntentRecorded, absenceVerified }
    let formatVersion: Int
    let attemptID: UUID
    let transactionID: UUID
    let accountFingerprint: String
    let sourcePayloadSHA256: String
    let observedSHA256: String
    let observedRecordCount: Int
    let zone: StorageTransferManagedZoneID?
    let terminalToken: Data?
    private(set) var phase: Phase
    private(set) var revision: Int

    init(attemptID: UUID, manifest: StorageTransferRecoveryManifest,
         observation: StorageTransferPartialDestinationObservation,
         proof: StorageTransferPartialSubsetProof) throws {
        try manifest.validate()
        try observation.validate()
        guard observation.accountFingerprint == manifest.accountFingerprint,
              proof.observationSHA256 == (try observation.digest()),
              proof.matchedRecordCount == observation.rows.count else {
            throw StorageTransferPartialRecoveryError.invalidPlan
        }
        formatVersion = 1
        self.attemptID = attemptID
        transactionID = manifest.transactionID
        accountFingerprint = manifest.accountFingerprint
        sourcePayloadSHA256 = manifest.payloadSHA256
        observedSHA256 = proof.observationSHA256
        observedRecordCount = proof.matchedRecordCount
        zone = observation.zone
        terminalToken = observation.terminalToken
        phase = .verifiedSubset
        revision = 0
        try validate()
    }

    func validate() throws {
        guard formatVersion == 1, revision == phase.rawValue,
              StorageTransferRecoverySchema.isDigest(accountFingerprint),
              StorageTransferRecoverySchema.isDigest(sourcePayloadSHA256),
              StorageTransferRecoverySchema.isDigest(observedSHA256),
              (0...CloudStorageTransferZoneAccumulator.maximumRows).contains(observedRecordCount) else {
            throw StorageTransferPartialRecoveryError.invalidPlan
        }
        if let zone {
            try zone.validate()
            guard let terminalToken, !terminalToken.isEmpty, terminalToken.count <= 65_536 else {
                throw StorageTransferPartialRecoveryError.invalidPlan
            }
        } else if terminalToken != nil || observedRecordCount != 0 {
            throw StorageTransferPartialRecoveryError.invalidPlan
        }
    }

    func advancing(to next: Phase) throws -> Self {
        try validate()
        guard next.rawValue == phase.rawValue + 1 else { throw StorageTransferPartialRecoveryError.stalePlan }
        var result = self
        result.phase = next
        result.revision += 1
        return result
    }
}

@MainActor
protocol StorageTransferPartialDestinationPlanStore {
    func load() throws -> StorageTransferPartialDestinationPlan?
    /// Exact immutable attempt/transaction/account/payload/observation CAS,
    /// consecutive phase, atomic file + directory fsync + independent readback.
    func save(_ plan: StorageTransferPartialDestinationPlan,
              replacing previous: StorageTransferPartialDestinationPlan?) throws
}

@MainActor
protocol StorageTransferPartialDestinationBackend {
    /// All pages, all raw attributes, exact current-owner zone, no unknown
    /// fields/types; no graph conversion that discards a dangling foreign key.
    /// Errors and incomplete responses must never be represented as empty data.
    /// Live reads/deletes must be bounded and cancellation-responsive, with a
    /// monotonic account-change lease spanning the entire attempt.
    func readRawDestination() async throws -> StorageTransferPartialDestinationObservation
    /// The same exact allowlisted per-zone + terminal-ack adapter as initial
    /// deletion. No broad zone cleanup or record mutation is permitted.
    func deleteZone(_ id: StorageTransferManagedZoneID) async throws -> StorageTransferManagedZoneDeleteAcknowledgment
}

struct StorageTransferPartialDestinationAbsenceReceipt: Sendable {
    let plan: StorageTransferPartialDestinationPlan
    let recoveryReceipt: StorageTransferRecoveryReceipt
    fileprivate init(plan: StorageTransferPartialDestinationPlan, recoveryReceipt: StorageTransferRecoveryReceipt) {
        self.plan = plan
        self.recoveryReceipt = recoveryReceipt
    }
}

/// Explicit reinstall recovery only, before any writable cloud mirror opens.
/// CloudKit cannot compare-and-delete a zone by token: unknown old clients can
/// still race the last read. This component therefore makes no all-device
/// atomicity claim, and refuses every uncertainty visible in the complete read.
@MainActor
struct StorageTransferPartialDestinationRecovery {
    private let store: any StorageTransferPartialDestinationPlanStore
    private let backend: any StorageTransferPartialDestinationBackend
    private let recovery: StorageTransferRemoteRecovery
    private let validateGenerationAndQuiescence: () throws -> Void

    init(store: any StorageTransferPartialDestinationPlanStore,
         backend: any StorageTransferPartialDestinationBackend,
         recovery: StorageTransferRemoteRecovery,
         validateGenerationAndQuiescence: @escaping () throws -> Void) {
        self.store = store
        self.backend = backend
        self.recovery = recovery
        self.validateGenerationAndQuiescence = validateGenerationAndQuiescence
    }

    /// This call follows explicit recovery authorization. It only reads the
    /// server and persists a new attempt; it never deletes a zone.
    func prepare(attemptID: UUID, manifest: StorageTransferRecoveryManifest) async throws -> StorageTransferPartialDestinationPlan {
        try check()
        if let previous = try store.load() {
            try requireIdentity(previous, manifest: manifest)
            guard previous.attemptID == attemptID else { throw StorageTransferPartialRecoveryError.stalePlan }
            return previous
        }
        let original = try await recoveredSnapshot(manifest)
        let observed = try await read(manifest: manifest)
        let proof = try StorageTransferPartialDestinationSubset.verify(observed, belongsTo: original)
        let plan = try StorageTransferPartialDestinationPlan(attemptID: attemptID, manifest: manifest,
                                                             observation: observed, proof: proof)
        _ = try await recovery.authorizeReplacement(manifest: manifest)
        try check()
        guard try store.load() == nil else { throw StorageTransferPartialRecoveryError.stalePlan }
        try store.save(plan, replacing: nil)
        guard try store.load() == plan else { throw StorageTransferPartialRecoveryError.stalePlan }
        return plan
    }

    func resume(attemptID: UUID, manifest: StorageTransferRecoveryManifest) async throws -> StorageTransferPartialDestinationAbsenceReceipt {
        guard var plan = try store.load(), plan.attemptID == attemptID else { throw StorageTransferPartialRecoveryError.stalePlan }
        try requireIdentity(plan, manifest: manifest)
        let original = try await recoveredSnapshot(manifest)
        try localCheck(plan)
        if plan.phase == .verifiedSubset {
            try await verifyUnchangedSubset(plan, manifest: manifest, original: original)
            plan = try save(plan.advancing(to: .deletionIntentRecorded), replacing: plan)
        }
        if plan.phase == .deletionIntentRecorded {
            let observed = try await read(manifest: manifest)
            try localCheck(plan)
            if !observed.confirmsAbsence {
                try verifyObserved(observed, against: plan, original: original)
                guard let zone = plan.zone else { throw StorageTransferPartialRecoveryError.changedObservation }
                // Full chunk readback and the exact current replacing fence
                // are required again immediately before the destructive call.
                let authorization = try await recovery.authorizeReplacement(manifest: manifest)
                try localCheck(plan)
                try await recovery.revalidateReplacement(authorization)
                try localCheck(plan)
                let acknowledgment = try await backend.deleteZone(zone)
                try await recovery.revalidateReplacement(authorization)
                try localCheck(plan)
                guard acknowledgment.zoneID == zone else { throw StorageTransferManagedZoneAdapterError.incompleteResponse }
                let after = try await read(manifest: manifest)
                try localCheck(plan)
                guard after.confirmsAbsence else { throw StorageTransferPartialRecoveryError.changedObservation }
            }
            plan = try save(plan.advancing(to: .absenceVerified), replacing: plan)
        }
        let final = try await read(manifest: manifest)
        try localCheck(plan)
        guard final.confirmsAbsence else { throw StorageTransferPartialRecoveryError.destinationAlreadyStarted }
        let receipt = try await recovery.authorizeReplacement(manifest: manifest)
        try localCheck(plan)
        return StorageTransferPartialDestinationAbsenceReceipt(plan: plan, recoveryReceipt: receipt)
    }

    private func recoveredSnapshot(_ manifest: StorageTransferRecoveryManifest) async throws -> PomoGemStorageSnapshot {
        try check()
        let restored = try await recovery.recover(manifest: manifest)
        try check()
        guard restored.envelope.control.phase == .replacing else { throw StorageTransferPartialRecoveryError.wrongRecovery }
        try manifest.validate(payload: restored.bytes)
        let snapshot = try JSONDecoder().decode(PomoGemStorageSnapshot.self, from: restored.bytes)
        try snapshot.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let actual = try JSONSerialization.jsonObject(with: restored.bytes) as? NSDictionary,
              let known = try JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? NSDictionary,
              actual == known else { throw StorageTransferPartialRecoveryError.wrongRecovery }
        return snapshot
    }

    private func read(manifest: StorageTransferRecoveryManifest) async throws -> StorageTransferPartialDestinationObservation {
        try check()
        let receipt = try await recovery.authorizeReplacement(manifest: manifest)
        try check()
        let result = try await backend.readRawDestination()
        try await recovery.revalidateReplacement(receipt)
        try check()
        try result.validate()
        guard result.accountFingerprint == manifest.accountFingerprint else { throw StorageTransferPartialRecoveryError.wrongRecovery }
        return result
    }

    private func verifyUnchangedSubset(_ plan: StorageTransferPartialDestinationPlan,
                                      manifest: StorageTransferRecoveryManifest,
                                      original: PomoGemStorageSnapshot) async throws {
        let observed = try await read(manifest: manifest)
        try localCheck(plan)
        try verifyObserved(observed, against: plan, original: original)
    }

    private func verifyObserved(_ observed: StorageTransferPartialDestinationObservation,
                                against plan: StorageTransferPartialDestinationPlan,
                                original: PomoGemStorageSnapshot) throws {
        let proof = try StorageTransferPartialDestinationSubset.verify(observed, belongsTo: original)
        guard proof.observationSHA256 == plan.observedSHA256,
              proof.matchedRecordCount == plan.observedRecordCount,
              observed.zone == plan.zone, observed.terminalToken == plan.terminalToken else {
            throw StorageTransferPartialRecoveryError.changedObservation
        }
    }

    private func requireIdentity(_ plan: StorageTransferPartialDestinationPlan, manifest: StorageTransferRecoveryManifest) throws {
        try plan.validate()
        try manifest.validate()
        guard plan.transactionID == manifest.transactionID,
              plan.accountFingerprint == manifest.accountFingerprint,
              plan.sourcePayloadSHA256 == manifest.payloadSHA256 else { throw StorageTransferPartialRecoveryError.wrongRecovery }
    }

    private func check() throws {
        try Task.checkCancellation()
        try validateGenerationAndQuiescence()
    }

    private func localCheck(_ plan: StorageTransferPartialDestinationPlan) throws {
        try check()
        guard try store.load() == plan else { throw StorageTransferPartialRecoveryError.stalePlan }
    }

    private func save(_ next: StorageTransferPartialDestinationPlan,
                      replacing previous: StorageTransferPartialDestinationPlan) throws -> StorageTransferPartialDestinationPlan {
        try localCheck(previous)
        try store.save(next, replacing: previous)
        guard try store.load() == next else { throw StorageTransferPartialRecoveryError.stalePlan }
        return next
    }
}
