import CryptoKit
import Darwin
import Foundation
import SwiftData

/// An internal transfer format, separate from the user-facing archival export.
/// Capture requires an already quiesced, frozen .none store. This API neither
/// proves cloud hydration nor authorizes account replacement. The caller owns
/// those gates and must keep the source until the staged target is verified.
/// All physical rows survive, including duplicates and quarantined values.
struct PomoGemStorageSnapshot: Codable, Sendable, Equatable {
    enum Scalar: Codable, Sendable, Equatable, Hashable {
        enum Kind: String, Codable, Sendable { case string, integer, boolean, double, date, uuid, data }
        case null, string(String), integer(Int), boolean(Bool)
        case doubleBits(UInt64), dateBits(UInt64), uuid(UUID), data(Data)
    }
    struct FieldDescriptor: Codable, Sendable, Equatable {
        let name: String
        let kind: Scalar.Kind
        let isOptional: Bool
    }
    enum Relationship: Codable, Sendable, Equatable {
        case toOne(Int?)
        case toMany([Int]?)
    }
    struct Record: Codable, Sendable, Equatable {
        let reference: Int
        let entity: String
        var fields: [String: Scalar]
        var relationships: [String: Relationship]
    }
    struct Limits: Sendable {
        // A bounded in-memory transfer, not an unbounded full-account array.
        // Exceeding any limit leaves the original store authoritative. 100,000
        // physical records accommodate decades of ordinary daily use.
        var maximumRecords = 100_000
        var maximumEncodedBytes = 128 * 1_024 * 1_024
        var maximumValueBytes = 4 * 1_024 * 1_024
        var maximumRelationshipReferences = 500_000
        static let standard = Self()
    }
    struct Receipt: Codable, Sendable, Equatable {
        let sha256: String
        let encodedBytes: Int
        let recordCounts: [String: Int]
    }
    enum Failure: Error, LocalizedError, Equatable {
        case schemaMismatch, invalidSnapshot, limitExceeded, dirtySource
        case cloudStoreNotFrozen, destinationNotEmpty, digestMismatch, unsafeFile
        case relationshipMismatch, verificationFailed
        var errorDescription: String? {
            "保存データを安全に移せませんでした。元のデータを保持しています。"
        }
    }

    var formatVersion = 1
    var records: [Record]

    var recordCounts: [String: Int] {
        var result = Dictionary(uniqueKeysWithValues: Self.modelNames.map { ($0, 0) })
        for row in records { result[row.entity, default: 0] += 1 }
        return result
    }

    static let modelNames = ["Subject", "StudySession", "AchievementStone", "Prefs",
                             "ActivityResetMarker", "SyncedFocusTimer", "FocusTimerDeviceClaim",
                             "AggregatePebble", "Stratum", "Bedrock", "GachaState"]
    static let cloudModelNames = Set(modelNames.prefix(7))
    static let relationshipDestinations: [String: [String: String]] = [
        "Subject": ["studySessions": "StudySession", "achievementStones": "AchievementStone"],
        "StudySession": ["subject": "Subject"], "AchievementStone": ["subject": "Subject"]
    ]

    @MainActor static var fieldDescriptors: [String: [FieldDescriptor]] {
        Dictionary(uniqueKeysWithValues: entities.map { ($0.name, $0.descriptors) })
    }

    /// Only this known additive pair may be absent from an older format-1
    /// payload. Keep the original dictionary/encoded bytes for receipt hashes;
    /// use nil defaults only when validating, importing or comparing its graph.
    /// Missing one member, any other missing field, and unknown fields still
    /// fail schema validation instead of being silently filled or discarded.
    nonisolated private static func fieldsIncludingLegacyDefaults(
        entity: String, fields: [String: Scalar]
    ) -> [String: Scalar] {
        guard entity == "Prefs",
              fields["preferredFocusSeconds"] == nil,
              fields["preferredFocusSecondsMutationID"] == nil else { return fields }
        var result = fields
        result["preferredFocusSeconds"] = .null
        result["preferredFocusSecondsMutationID"] = .null
        return result
    }

    @MainActor static func validateSchema(_ schema: Schema) throws {
        guard Set(schema.entities.map(\.name)) == Set(modelNames) else { throw Failure.schemaMismatch }
        for entity in schema.entities {
            guard let descriptor = entities.first(where: { $0.name == entity.name }),
                  Set(entity.attributes.map(\.name)) == Set(descriptor.descriptors.map(\.name)),
                  Set(entity.relationships.map(\.name)) == Set(relationshipDestinations[entity.name, default: [:]].keys)
            else { throw Failure.schemaMismatch }
        }
    }

    @MainActor static func capture(from context: ModelContext, limits: Limits = .standard) throws -> Self {
        try captureRows(from: context, permitsObservedCloudReplica: false, limits: limits)
    }

    /// A read-only import-progress observation, never a frozen-copy receipt.
    /// The coordinator must compare repeated complete server observations,
    /// retire this mirror, then verify a separate frozen source before commit.
    @MainActor static func observeCloudReplica(from context: ModelContext, limits: Limits = .standard) throws -> Self {
        try captureRows(from: context, permitsObservedCloudReplica: true, limits: limits)
    }

    @MainActor private static func captureRows(from context: ModelContext,
                                               permitsObservedCloudReplica: Bool,
                                               limits: Limits) throws -> Self {
        try validateSchema(context.container.schema)
        guard !context.hasChanges else { throw Failure.dirtySource }
        guard permitsObservedCloudReplica || context.container.configurations.allSatisfy({ $0.cloudKitContainerIdentifier == nil }) else {
            throw Failure.cloudStoreNotFrozen
        }
        try validateLimits(limits)
        var count = 0
        for entity in entities {
            let next = try entity.count(context)
            guard next <= limits.maximumRecords - count else { throw Failure.limitExceeded }
            count += next
        }
        var references: [PersistentIdentifier: Int] = [:]
        references.reserveCapacity(count)
        for entity in entities {
            try entity.enumerate(context) { value in
                try Task.checkCancellation()
                guard references.count < limits.maximumRecords,
                      references[value.persistentModelID] == nil else { throw Failure.invalidSnapshot }
                references[value.persistentModelID] = references.count
            }
        }
        var rows: [Record] = []
        rows.reserveCapacity(count)
        var budget = Budget(limits: limits)
        for entity in entities {
            try entity.enumerate(context) { value in
                try Task.checkCancellation()
                guard let reference = references[value.persistentModelID] else { throw Failure.invalidSnapshot }
                let row = Record(reference: reference, entity: entity.name,
                                 fields: entity.capture(value),
                                 relationships: try captureRelationships(value, references: references))
                try budget.consume(row)
                rows.append(row)
            }
        }
        guard rows.count == count, !context.hasChanges else { throw Failure.dirtySource }
        // Imports can change a different entity after its enumeration. This
        // is only an observation: same-count changes still require the final
        // frozen/server comparison owned by the transfer coordinator.
        let capturedCounts = Dictionary(grouping: rows, by: \.entity).mapValues(\.count)
        for entity in entities {
            guard try entity.count(context) == capturedCounts[entity.name, default: 0] else {
                throw Failure.dirtySource
            }
        }
        let result = Self(records: rows)
        try result.validate(limits: limits)
        return result
    }

    @MainActor func validate(limits: Limits = .standard) throws {
        try Self.validateSchema(PersistenceStoreTopology.shippingSchema)
        try Self.validateLimits(limits)
        guard formatVersion == 1, records.count <= limits.maximumRecords else { throw Failure.invalidSnapshot }
        var byReference: [Int: Record] = [:]
        var inverseMembers: [Int: [String: Set<Int>]] = [:]
        var budget = Budget(limits: limits)
        for row in records {
            try Task.checkCancellation()
            guard row.reference >= 0, row.reference < limits.maximumRecords,
                  byReference.updateValue(row, forKey: row.reference) == nil,
                  let entity = Self.entities.first(where: { $0.name == row.entity }) else { throw Failure.invalidSnapshot }
            try entity.validate(row.fields)
            try budget.consume(row)
            if row.entity == "Subject" {
                for (name, relation) in row.relationships {
                    if case let .toMany(values) = relation {
                        inverseMembers[row.reference, default: [:]][name] = Set(values ?? [])
                    }
                }
            }
        }
        for row in records {
            let expected = Self.relationshipDestinations[row.entity, default: [:]]
            guard Set(row.relationships.keys) == Set(expected.keys) else { throw Failure.relationshipMismatch }
            for (name, relation) in row.relationships {
                let ids: [Int]
                switch relation {
                case let .toOne(id):
                    guard name == "subject" else { throw Failure.relationshipMismatch }
                    ids = id.map { [$0] } ?? []
                case let .toMany(values):
                    guard row.entity == "Subject" else { throw Failure.relationshipMismatch }
                    ids = values ?? []
                    guard Set(ids).count == ids.count else { throw Failure.relationshipMismatch }
                }
                for id in ids {
                    guard let other = byReference[id], other.entity == expected[name] else { throw Failure.relationshipMismatch }
                    if row.entity == "Subject" {
                        guard other.relationships["subject"] == .toOne(row.reference) else { throw Failure.relationshipMismatch }
                    } else {
                        let inverse = row.entity == "StudySession" ? "studySessions" : "achievementStones"
                        guard inverseMembers[other.reference]?[inverse]?.contains(row.reference) == true
                        else { throw Failure.relationshipMismatch }
                    }
                }
            }
        }
    }

    /// The target must be a disposable, unpublished .none staging store. A save
    /// spanning two stores can fail partway; on *any* error the owner must discard
    /// that entire target. Never retry by appending into a partially saved target.
    @MainActor func importIntoEmpty(_ context: ModelContext, limits: Limits = .standard) throws -> Receipt {
        try validate(limits: limits)
        try Self.validateSchema(context.container.schema)
        guard context.container.configurations.allSatisfy({ $0.cloudKitContainerIdentifier == nil }) else {
            throw Failure.cloudStoreNotFrozen
        }
        guard !context.hasChanges else { throw Failure.destinationNotEmpty }
        for entity in Self.entities where try entity.count(context) != 0 { throw Failure.destinationNotEmpty }
        let data = try encoded(limits: limits)
        let oldAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = oldAutosave }
        do {
            var objects: [Int: any PersistentModel] = [:]
            for row in records {
                try Task.checkCancellation()
                guard let entity = Self.entities.first(where: { $0.name == row.entity }) else { throw Failure.schemaMismatch }
                objects[row.reference] = try entity.insert(row.fields, context)
            }
            // Wire children first, then restore explicit inverse nil/empty state.
            for row in records where row.entity != "Subject" {
                try Self.restoreRelationships(row, objects: objects)
            }
            for row in records where row.entity == "Subject" {
                try Self.restoreRelationships(row, objects: objects)
            }
            let ids = Dictionary(uniqueKeysWithValues: objects.map { ($0.value.persistentModelID, $0.key) })
            for row in records {
                try Task.checkCancellation()
                guard let object = objects[row.reference],
                      let entity = Self.entities.first(where: { $0.name == row.entity }),
                      entity.capture(object) == Self.fieldsIncludingLegacyDefaults(
                        entity: row.entity, fields: row.fields
                      ),
                      try Self.captureRelationships(object, references: ids) == row.relationships
                else { throw Failure.verificationFailed }
            }
            try Task.checkCancellation()
            try context.save()
            return receipt(for: data)
        } catch {
            context.rollback()
            throw error
        }
    }

    @MainActor static func clone(from source: ModelContext, intoEmpty destination: ModelContext,
                                limits: Limits = .standard) throws -> Receipt {
        try capture(from: source, limits: limits).importIntoEmpty(destination, limits: limits)
    }

    /// Compares the physical graph as a multiset, independent of fetch order or
    /// transaction-local references. IDs are ordinary preserved fields, never
    /// dictionary keys that could discard duplicate copies. The only shipping
    /// relationships form Subject/child stars; schema validation rejects any
    /// new relationship until its comparison rule is implemented.
    /// A nonzero dateTolerance conservatively quantizes dates into that width:
    /// equality implies dates differ by at most the tolerance; a bucket boundary
    /// may reject close dates. Exact transfer verification uses the default zero.
    @MainActor func isEquivalent(to other: Self, entities included: Set<String>? = nil,
                                 normalizeEmptyRelationships: Bool = false,
                                 dateTolerance: TimeInterval = 0) throws -> Bool {
        try validate()
        try other.validate()
        guard dateTolerance.isFinite, dateTolerance >= 0, dateTolerance <= 0.01 else {
            throw Failure.invalidSnapshot
        }
        let selected = included ?? Set(Self.modelNames)
        guard selected.isSubset(of: Set(Self.modelNames)) else { throw Failure.schemaMismatch }
        return try graphSignatures(entities: selected, normalizeEmpty: normalizeEmptyRelationships,
                                   dateTolerance: dateTolerance)
            == other.graphSignatures(entities: selected, normalizeEmpty: normalizeEmptyRelationships,
                                     dateTolerance: dateTolerance)
    }

    private enum EdgeSignature: Encodable {
        case one(String?), many([String]?)
    }
    private struct GraphSignature: Encodable {
        let entity: String
        let fields: [String: Scalar]
        let relationships: [String: EdgeSignature]
    }
    private func graphSignatures(entities selected: Set<String>, normalizeEmpty: Bool,
                                 dateTolerance: TimeInterval) throws -> [String: Int] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func fields(_ row: Record) throws -> [String: Scalar] {
            let values = Self.fieldsIncludingLegacyDefaults(entity: row.entity, fields: row.fields)
            guard dateTolerance > 0 else { return values }
            return try values.mapValues { value in
                guard case let .dateBits(bits) = value else { return value }
                let date = Double(bitPattern: bits)
                guard date.isFinite, (date / dateTolerance).isFinite else { throw Failure.invalidSnapshot }
                return .dateBits(((date / dateTolerance).rounded() * dateTolerance).bitPattern)
            }
        }
        var basic: [Int: String] = [:]
        for row in records {
            try Task.checkCancellation()
            basic[row.reference] = Self.digest(try encoder.encode(GraphSignature(
                entity: row.entity, fields: fields(row), relationships: [:]
            )))
        }
        func edges(_ row: Record, targets: [Int: String]) throws -> [String: EdgeSignature] {
            try row.relationships.mapValues { relation in
                func lookup(_ id: Int) throws -> String {
                    guard let result = targets[id] else { throw Failure.relationshipMismatch }; return result
                }
                switch relation {
                case let .toOne(id): return .one(try id.map(lookup))
                case let .toMany(ids):
                    let values = try ids.map { try $0.map(lookup).sorted() }
                    return .many(normalizeEmpty ? (values ?? []) : values)
                }
            }
        }
        var targets = basic
        for row in records where row.entity == "Subject" {
            targets[row.reference] = Self.digest(try encoder.encode(GraphSignature(
                entity: row.entity, fields: fields(row), relationships: edges(row, targets: basic)
            )))
        }
        var result: [String: Int] = [:]
        for row in records where selected.contains(row.entity) {
            try Task.checkCancellation()
            let signature = Self.digest(try encoder.encode(GraphSignature(
                entity: row.entity, fields: fields(row),
                relationships: edges(row, targets: row.entity == "Subject" ? basic : targets)
            )))
            result[signature, default: 0] += 1
        }
        return result
    }

    @MainActor func write(to url: URL, limits: Limits = .standard) throws -> Receipt {
        try validate(limits: limits)
        try Self.requireSafeFile(url, mustExist: false)
        let data = try encoded(limits: limits)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let writer = try FileHandle(forWritingTo: url)
        do { try writer.synchronize(); try writer.close() }
        catch { try? writer.close(); throw error }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let receipt = receipt(for: data)
        // A durable journal may acknowledge this receipt only after the actual
        // persisted bytes have been read back. Hash incrementally to avoid a
        // second full-size snapshot allocation during this check.
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        var hash = SHA256()
        var count = 0
        while let chunk = try reader.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            guard chunk.count <= limits.maximumEncodedBytes - count else { throw Failure.limitExceeded }
            count += chunk.count
            hash.update(data: chunk)
        }
        let readDigest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == receipt.encodedBytes, readDigest == receipt.sha256 else { throw Failure.digestMismatch }
        return receipt
    }

    @MainActor static func read(from url: URL, expectedDigest: String, limits: Limits = .standard) throws -> Self {
        try validateLimits(limits)
        try requireSafeFile(url, mustExist: true)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size > 0, size <= limits.maximumEncodedBytes else { throw Failure.limitExceeded }
        let data = try Data(contentsOf: url)
        guard data.count == size, digest(data) == expectedDigest else { throw Failure.digestMismatch }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate(limits: limits)
        return result
    }

    private func encoded(limits: Limits) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= limits.maximumEncodedBytes else { throw Failure.limitExceeded }
        return data
    }
    private func receipt(for data: Data) -> Receipt {
        Receipt(sha256: Self.digest(data), encodedBytes: data.count, recordCounts: recordCounts)
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func requireSafeFile(_ url: URL, mustExist: Bool) throws {
        guard url.isFileURL, !url.hasDirectoryPath else { throw Failure.unsafeFile }
        let parent = try url.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parent.isDirectory == true, parent.isSymbolicLink != true else { throw Failure.unsafeFile }
        // attributesOfItem inspects the link itself, including a dangling link.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw Failure.unsafeFile }
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.unsafeFile }
        } else if mustExist { throw Failure.unsafeFile }
    }
    private static func validateLimits(_ limits: Limits) throws {
        guard limits.maximumRecords > 0, limits.maximumRecords <= Limits.standard.maximumRecords,
              limits.maximumEncodedBytes > 0, limits.maximumEncodedBytes <= Limits.standard.maximumEncodedBytes,
              limits.maximumValueBytes > 0, limits.maximumValueBytes <= Limits.standard.maximumValueBytes,
              limits.maximumRelationshipReferences > 0,
              limits.maximumRelationshipReferences <= Limits.standard.maximumRelationshipReferences else { throw Failure.limitExceeded }
    }
    private struct Budget {
        let limits: Limits
        var bytes = 0
        var references = 0
        mutating func consume(_ row: Record) throws {
            guard row.fields.count <= 64, row.relationships.count <= 2 else { throw Failure.limitExceeded }
            var added = 128 + row.entity.utf8.count
            for (key, value) in row.fields {
                let size: Int
                switch value {
                case let .string(text): size = text.utf8.count * 6 + 32 // JSON escaping upper bound
                case let .data(data): size = ((data.count + 2) / 3) * 4 + 32
                default: size = 96
                }
                guard size <= limits.maximumValueBytes else { throw Failure.limitExceeded }
                added += key.utf8.count * 6 + size + 32
            }
            for (key, value) in row.relationships {
                let count: Int
                switch value { case let .toOne(id): count = id == nil ? 0 : 1; case let .toMany(ids): count = ids?.count ?? 0 }
                guard count <= limits.maximumRelationshipReferences - references else { throw Failure.limitExceeded }
                references += count
                added += key.utf8.count * 6 + count * 24 + 32
            }
            guard added <= limits.maximumEncodedBytes - bytes else { throw Failure.limitExceeded }
            bytes += added
        }
    }
}

private protocol StorageSnapshotScalarConvertible {
    static var storageKind: PomoGemStorageSnapshot.Scalar.Kind { get }
    static var storageOptional: Bool { get }
    var storageScalar: PomoGemStorageSnapshot.Scalar { get }
    static func fromStorageScalar(_ value: PomoGemStorageSnapshot.Scalar) throws -> Self
}
private extension StorageSnapshotScalarConvertible { static var storageOptional: Bool { false } }

// Explicit typed key paths below make field additions fail the runtime schema
// check, and make unsupported type changes fail at compilation. No private
// SwiftData backing-store or CloudKit metadata APIs participate in transfer.
@MainActor private extension PomoGemStorageSnapshot {
    struct Field<Model: PersistentModel> {
        let descriptor: FieldDescriptor
        let capture: (Model) -> Scalar
        let restore: (Model, Scalar) throws -> Void
        let validate: (Scalar) throws -> Void
        init<Value: StorageSnapshotScalarConvertible>(_ name: String, _ path: ReferenceWritableKeyPath<Model, Value>) {
            descriptor = FieldDescriptor(name: name, kind: Value.storageKind, isOptional: Value.storageOptional)
            capture = { $0[keyPath: path].storageScalar }
            restore = { $0[keyPath: path] = try Value.fromStorageScalar($1) }
            validate = { _ = try Value.fromStorageScalar($0) }
        }
    }
    struct Entity {
        let name: String
        let descriptors: [FieldDescriptor]
        let count: (ModelContext) throws -> Int
        let enumerate: (ModelContext, (any PersistentModel) throws -> Void) throws -> Void
        let capture: (any PersistentModel) -> [String: Scalar]
        let validate: ([String: Scalar]) throws -> Void
        let insert: ([String: Scalar], ModelContext) throws -> any PersistentModel
        init<Model: PersistentModel>(_ type: Model.Type, _ fields: [Field<Model>], factory: @escaping () throws -> Model) {
            name = String(describing: type)
            descriptors = fields.map(\.descriptor)
            count = { try $0.fetchCount(FetchDescriptor<Model>()) }
            enumerate = { context, visit in try context.enumerate(FetchDescriptor<Model>(), batchSize: 256) { try visit($0) } }
            capture = { value in Dictionary(uniqueKeysWithValues: fields.map { ($0.descriptor.name, $0.capture(value as! Model)) }) }
            validate = { rawValues in
                let values = PomoGemStorageSnapshot.fieldsIncludingLegacyDefaults(
                    entity: String(describing: type), fields: rawValues
                )
                guard Set(values.keys) == Set(fields.map { $0.descriptor.name }) else { throw Failure.schemaMismatch }
                for field in fields { try field.validate(values[field.descriptor.name]!) }
            }
            insert = { rawValues, context in
                let values = PomoGemStorageSnapshot.fieldsIncludingLegacyDefaults(
                    entity: String(describing: type), fields: rawValues
                )
                let model = try factory()
                for field in fields { try field.restore(model, values[field.descriptor.name]!) }
                context.insert(model)
                return model
            }
        }
    }

    static func captureRelationships(_ model: any PersistentModel, references: [PersistentIdentifier: Int]) throws -> [String: Relationship] {
        func ref(_ model: any PersistentModel) throws -> Int {
            guard let value = references[model.persistentModelID] else { throw Failure.relationshipMismatch }
            return value
        }
        if let subject = model as? Subject {
            return ["studySessions": .toMany(try subject.studySessions.map { try $0.map { try ref($0) } }),
                    "achievementStones": .toMany(try subject.achievementStones.map { try $0.map { try ref($0) } })]
        }
        if let session = model as? StudySession { return ["subject": .toOne(try session.subject.map { try ref($0) })] }
        if let stone = model as? AchievementStone { return ["subject": .toOne(try stone.subject.map { try ref($0) })] }
        return [:]
    }
    static func restoreRelationships(_ row: Record, objects: [Int: any PersistentModel]) throws {
        guard let model = objects[row.reference] else { throw Failure.relationshipMismatch }
        if let subject = model as? Subject {
            guard case let .toMany(sessions) = row.relationships["studySessions"],
                  case let .toMany(stones) = row.relationships["achievementStones"] else { throw Failure.relationshipMismatch }
            subject.studySessions = try sessions.map { try $0.map { id in
                guard let value = objects[id] as? StudySession else { throw Failure.relationshipMismatch }; return value
            } }
            subject.achievementStones = try stones.map { try $0.map { id in
                guard let value = objects[id] as? AchievementStone else { throw Failure.relationshipMismatch }; return value
            } }
        } else if row.entity == "StudySession" || row.entity == "AchievementStone" {
            guard case let .toOne(reference) = row.relationships["subject"] else { throw Failure.relationshipMismatch }
            let subject = try reference.map { id in
                guard let value = objects[id] as? Subject else { throw Failure.relationshipMismatch }; return value
            }
            if let session = model as? StudySession { session.subject = subject }
            else if let stone = model as? AchievementStone { stone.subject = subject }
        }
    }

    static func placeholderTimer() throws -> SyncedFocusTimer {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let id = UUID()
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: date, sessionID: id)
        let payload = try FocusCloudPayload(envelope: FocusRecoveryEnvelope(
            engine: engine, subject: FocusSubjectSnapshot(id: UUID(), name: "", colorHex: ""),
            clockAnchor: nil, pendingCompletion: nil, savedAt: date
        ))
        return try SyncedFocusTimer(sessionID: id, status: .running, payload: payload,
                                    updatedAt: date, writerDeviceID: "storage-transfer-placeholder")
    }

    static var entities: [Entity] { [subjectEntity, studySessionEntity, achievementStoneEntity, prefsEntity, activityResetMarkerEntity, syncedFocusTimerEntity, focusTimerDeviceClaimEntity, aggregatePebbleEntity, stratumEntity, bedrockEntity, gachaStateEntity] }

    static var subjectEntity: Entity {
        Entity(Subject.self, [
            Field<Subject>("id", \.id),
            Field<Subject>("syncRecordID", \.syncRecordID),
            Field<Subject>("contentRevision", \.contentRevision),
            Field<Subject>("contentMutationID", \.contentMutationID),
            Field<Subject>("name", \.name),
            Field<Subject>("colorHex", \.colorHex),
            Field<Subject>("sortOrder", \.sortOrder),
            Field<Subject>("isArchived", \.isArchived),
            Field<Subject>("deletedAt", \.deletedAt),
            Field<Subject>("createdAt", \.createdAt)
        ], factory: { Subject(name: "", colorHex: "", sortOrder: 0) })
    }

    static var studySessionEntity: Entity {
        Entity(StudySession.self, [
            Field<StudySession>("id", \.id),
            Field<StudySession>("syncRecordID", \.syncRecordID),
            Field<StudySession>("dataEpochID", \.dataEpochID),
            Field<StudySession>("subjectIDSnapshot", \.subjectIDSnapshot),
            Field<StudySession>("subjectNameSnapshot", \.subjectNameSnapshot),
            Field<StudySession>("subjectColorHexSnapshot", \.subjectColorHexSnapshot),
            Field<StudySession>("startAt", \.startAt),
            Field<StudySession>("endAt", \.endAt),
            Field<StudySession>("seconds", \.seconds),
            Field<StudySession>("source", \.source),
            Field<StudySession>("pebbleKind", \.pebbleKind),
            Field<StudySession>("grams", \.grams),
            Field<StudySession>("deviceDayKey", \.deviceDayKey),
            Field<StudySession>("rareRewardRuleVersion", \.rareRewardRuleVersion),
            Field<StudySession>("rareRewardParticipated", \.rareRewardParticipated),
            Field<StudySession>("rareRewardCreditedGrams", \.rareRewardCreditedGrams),
            Field<StudySession>("rareRewardOutcomesRawValue", \.rareRewardOutcomesRawValue),
            Field<StudySession>("isBaked", \.isBaked)
        ], factory: { StudySession(startAt: .distantPast, endAt: .distantPast, seconds: 0, source: .manual, deviceDayKey: "") })
    }

    static var achievementStoneEntity: Entity {
        Entity(AchievementStone.self, [
            Field<AchievementStone>("id", \.id),
            Field<AchievementStone>("syncRecordID", \.syncRecordID),
            Field<AchievementStone>("dataEpochID", \.dataEpochID),
            Field<AchievementStone>("subjectNameSnapshot", \.subjectNameSnapshot),
            Field<AchievementStone>("subjectColorHexSnapshot", \.subjectColorHexSnapshot),
            Field<AchievementStone>("kind", \.kind),
            Field<AchievementStone>("note", \.note),
            Field<AchievementStone>("achievedAt", \.achievedAt),
            Field<AchievementStone>("createdAt", \.createdAt),
            Field<AchievementStone>("revision", \.revision),
            Field<AchievementStone>("deletedAt", \.deletedAt),
            Field<AchievementStone>("deletionMutationID", \.deletionMutationID),
            Field<AchievementStone>("deletionRevision", \.deletionRevision),
            Field<AchievementStone>("restoredDeletionMutationID", \.restoredDeletionMutationID),
            Field<AchievementStone>("updatedAt", \.updatedAt)
        ], factory: { AchievementStone(kind: .perfectScore) })
    }

    static var prefsEntity: Entity {
        Entity(Prefs.self, [
            Field<Prefs>("id", \.id),
            Field<Prefs>("syncRecordID", \.syncRecordID),
            Field<Prefs>("settingsWriterID", \.settingsWriterID),
            Field<Prefs>("soundRevision", \.soundRevision),
            Field<Prefs>("soundMutationID", \.soundMutationID),
            Field<Prefs>("hapticsRevision", \.hapticsRevision),
            Field<Prefs>("hapticsMutationID", \.hapticsMutationID),
            Field<Prefs>("timerCompletionSoundRevision", \.timerCompletionSoundRevision),
            Field<Prefs>("timerCompletionSoundMutationID", \.timerCompletionSoundMutationID),
            Field<Prefs>("timerCompletionHapticRevision", \.timerCompletionHapticRevision),
            Field<Prefs>("timerCompletionHapticMutationID", \.timerCompletionHapticMutationID),
            Field<Prefs>("rareRewardRevision", \.rareRewardRevision),
            Field<Prefs>("rareRewardMutationID", \.rareRewardMutationID),
            Field<Prefs>("reminderEnabledRevision", \.reminderEnabledRevision),
            Field<Prefs>("reminderEnabledMutationID", \.reminderEnabledMutationID),
            Field<Prefs>("reminderTimeRevision", \.reminderTimeRevision),
            Field<Prefs>("reminderTimeMutationID", \.reminderTimeMutationID),
            Field<Prefs>("shareIncludesManualRevision", \.shareIncludesManualRevision),
            Field<Prefs>("shareIncludesManualMutationID", \.shareIncludesManualMutationID),
            Field<Prefs>("externalThemeRevision", \.externalThemeRevision),
            Field<Prefs>("externalThemeMutationID", \.externalThemeMutationID),
            Field<Prefs>("keepScreenAwakeRevision", \.keepScreenAwakeRevision),
            Field<Prefs>("keepScreenAwakeMutationID", \.keepScreenAwakeMutationID),
            Field<Prefs>("preferredFocusMinutesRevision", \.preferredFocusMinutesRevision),
            Field<Prefs>("preferredFocusMinutesMutationID", \.preferredFocusMinutesMutationID),
            Field<Prefs>("timerDisplayModeRevision", \.timerDisplayModeRevision),
            Field<Prefs>("timerDisplayModeMutationID", \.timerDisplayModeMutationID),
            Field<Prefs>("usagePurposeRevision", \.usagePurposeRevision),
            Field<Prefs>("usagePurposeMutationID", \.usagePurposeMutationID),
            Field<Prefs>("activityEpochID", \.activityEpochID),
            Field<Prefs>("manualDayKey", \.manualDayKey),
            Field<Prefs>("manualUsedToday", \.manualUsedToday),
            Field<Prefs>("soundOn", \.soundOn),
            Field<Prefs>("hapticsOn", \.hapticsOn),
            Field<Prefs>("timerCompletionSoundRawValue", \.timerCompletionSoundRawValue),
            Field<Prefs>("timerCompletionHapticRawValue", \.timerCompletionHapticRawValue),
            Field<Prefs>("rareRewardModeRawValue", \.rareRewardModeRawValue),
            Field<Prefs>("rareRewardModeUpdatedAt", \.rareRewardModeUpdatedAt),
            Field<Prefs>("reminderEnabled", \.reminderEnabled),
            Field<Prefs>("reminderHour", \.reminderHour),
            Field<Prefs>("reminderMinute", \.reminderMinute),
            Field<Prefs>("shareIncludesManual", \.shareIncludesManual),
            Field<Prefs>("showsThemeNameExternally", \.showsThemeNameExternally),
            Field<Prefs>("isPro", \.isPro),
            Field<Prefs>("keepScreenAwake", \.keepScreenAwake),
            Field<Prefs>("preferredFocusMinutes", \.preferredFocusMinutes),
            Field<Prefs>("preferredFocusSeconds", \.preferredFocusSeconds),
            Field<Prefs>("preferredFocusSecondsMutationID", \.preferredFocusSecondsMutationID),
            Field<Prefs>("timerDisplayModeRawValue", \.timerDisplayModeRawValue),
            Field<Prefs>("hasCompletedOnboarding", \.hasCompletedOnboarding),
            Field<Prefs>("usagePurposeRawValue", \.usagePurposeRawValue),
            Field<Prefs>("usagePurposeUpdatedAt", \.usagePurposeUpdatedAt),
            Field<Prefs>("hasEverImportedBedrock", \.hasEverImportedBedrock),
            Field<Prefs>("hasCompletedInitialSubjectSeed", \.hasCompletedInitialSubjectSeed)
        ], factory: { Prefs() })
    }

    static var activityResetMarkerEntity: Entity {
        Entity(ActivityResetMarker.self, [
            Field<ActivityResetMarker>("id", \.id),
            Field<ActivityResetMarker>("epochID", \.epochID),
            Field<ActivityResetMarker>("sequence", \.sequence),
            Field<ActivityResetMarker>("resetAt", \.resetAt),
            Field<ActivityResetMarker>("writerDeviceID", \.writerDeviceID)
        ], factory: { ActivityResetMarker(sequence: 0, resetAt: .distantPast, writerDeviceID: "") })
    }

    static var syncedFocusTimerEntity: Entity {
        Entity(SyncedFocusTimer.self, [
            Field<SyncedFocusTimer>("id", \.id),
            Field<SyncedFocusTimer>("dataEpochID", \.dataEpochID),
            Field<SyncedFocusTimer>("sessionID", \.sessionID),
            Field<SyncedFocusTimer>("statusRaw", \.statusRaw),
            Field<SyncedFocusTimer>("payloadData", \.payloadData),
            Field<SyncedFocusTimer>("startedAt", \.startedAt),
            Field<SyncedFocusTimer>("scheduledEndAt", \.scheduledEndAt),
            Field<SyncedFocusTimer>("updatedAt", \.updatedAt),
            Field<SyncedFocusTimer>("terminalAt", \.terminalAt),
            Field<SyncedFocusTimer>("revision", \.revision),
            Field<SyncedFocusTimer>("ownershipSequence", \.ownershipSequence),
            Field<SyncedFocusTimer>("writerDeviceID", \.writerDeviceID)
        ], factory: { try placeholderTimer() })
    }

    static var focusTimerDeviceClaimEntity: Entity {
        Entity(FocusTimerDeviceClaim.self, [
            Field<FocusTimerDeviceClaim>("id", \.id),
            Field<FocusTimerDeviceClaim>("syncRecordID", \.syncRecordID),
            Field<FocusTimerDeviceClaim>("dataEpochID", \.dataEpochID),
            Field<FocusTimerDeviceClaim>("sessionID", \.sessionID),
            Field<FocusTimerDeviceClaim>("deviceID", \.deviceID),
            Field<FocusTimerDeviceClaim>("sequence", \.sequence),
            Field<FocusTimerDeviceClaim>("claimedAt", \.claimedAt),
            Field<FocusTimerDeviceClaim>("releasedAt", \.releasedAt)
        ], factory: { FocusTimerDeviceClaim(sessionID: UUID(), deviceID: "", sequence: 0, claimedAt: .distantPast) })
    }

    static var aggregatePebbleEntity: Entity {
        Entity(AggregatePebble.self, [
            Field<AggregatePebble>("id", \.id),
            Field<AggregatePebble>("dataEpochID", \.dataEpochID),
            Field<AggregatePebble>("createdAt", \.createdAt),
            Field<AggregatePebble>("level", \.level),
            Field<AggregatePebble>("pebbleCount", \.pebbleCount),
            Field<AggregatePebble>("childAggregateCount", \.childAggregateCount),
            Field<AggregatePebble>("grams", \.grams),
            Field<AggregatePebble>("measuredPebbleCount", \.measuredPebbleCount),
            Field<AggregatePebble>("manualPebbleCount", \.manualPebbleCount),
            Field<AggregatePebble>("goldPebbleCount", \.goldPebbleCount),
            Field<AggregatePebble>("prismPebbleCount", \.prismPebbleCount),
            Field<AggregatePebble>("colorMixJSON", \.colorMixJSON),
            Field<AggregatePebble>("subjectMixJSON", \.subjectMixJSON),
            Field<AggregatePebble>("periodStart", \.periodStart),
            Field<AggregatePebble>("periodEnd", \.periodEnd),
            Field<AggregatePebble>("sessionIDsJSON", \.sessionIDsJSON),
            Field<AggregatePebble>("childAggregateIDsJSON", \.childAggregateIDsJSON),
            Field<AggregatePebble>("parentAggregateID", \.parentAggregateID),
            Field<AggregatePebble>("projectionValidationVersion", \.projectionValidationVersion)
        ], factory: { AggregatePebble(level: 1, pebbleCount: 0, grams: 0, colorMixJSON: "[]", periodStart: .distantPast, periodEnd: .distantPast) })
    }

    static var stratumEntity: Entity {
        Entity(Stratum.self, [
            Field<Stratum>("id", \.id),
            Field<Stratum>("dataEpochID", \.dataEpochID),
            Field<Stratum>("bakedAt", \.bakedAt),
            Field<Stratum>("pebbleCount", \.pebbleCount),
            Field<Stratum>("heightPt", \.heightPt),
            Field<Stratum>("colorMixJSON", \.colorMixJSON),
            Field<Stratum>("monthLabel", \.monthLabel),
            Field<Stratum>("sessionIDsJSON", \.sessionIDsJSON),
            Field<Stratum>("grams", \.grams)
        ], factory: { Stratum(pebbleCount: 0, heightPt: 0, colorMixJSON: "[]", monthLabel: "") })
    }

    static var bedrockEntity: Entity {
        Entity(Bedrock.self, [
            Field<Bedrock>("dataEpochID", \.dataEpochID),
            Field<Bedrock>("hours", \.hours),
            Field<Bedrock>("importedAt", \.importedAt)
        ], factory: { Bedrock(hours: 0) })
    }

    static var gachaStateEntity: Entity {
        Entity(GachaState.self, [
            Field<GachaState>("id", \.id),
            Field<GachaState>("dataEpochID", \.dataEpochID),
            Field<GachaState>("sinceLastGold", \.sinceLastGold),
            Field<GachaState>("rewardCreditGrams", \.rewardCreditGrams)
        ], factory: { GachaState() })
    }

}

extension String: StorageSnapshotScalarConvertible {
    fileprivate static var storageKind: PomoGemStorageSnapshot.Scalar.Kind { .string }
    fileprivate var storageScalar: PomoGemStorageSnapshot.Scalar { .string(self) }
    fileprivate static func fromStorageScalar(_ scalar: PomoGemStorageSnapshot.Scalar) throws -> Self {
        guard case let .string(value) = scalar else { throw PomoGemStorageSnapshot.Failure.invalidSnapshot }
        return value
    }
}

extension Int: StorageSnapshotScalarConvertible {
    fileprivate static var storageKind: PomoGemStorageSnapshot.Scalar.Kind { .integer }
    fileprivate var storageScalar: PomoGemStorageSnapshot.Scalar { .integer(self) }
    fileprivate static func fromStorageScalar(_ scalar: PomoGemStorageSnapshot.Scalar) throws -> Self {
        guard case let .integer(value) = scalar else { throw PomoGemStorageSnapshot.Failure.invalidSnapshot }
        return value
    }
}

extension Bool: StorageSnapshotScalarConvertible {
    fileprivate static var storageKind: PomoGemStorageSnapshot.Scalar.Kind { .boolean }
    fileprivate var storageScalar: PomoGemStorageSnapshot.Scalar { .boolean(self) }
    fileprivate static func fromStorageScalar(_ scalar: PomoGemStorageSnapshot.Scalar) throws -> Self {
        guard case let .boolean(value) = scalar else { throw PomoGemStorageSnapshot.Failure.invalidSnapshot }
        return value
    }
}

extension Double: StorageSnapshotScalarConvertible {
    fileprivate static var storageKind: PomoGemStorageSnapshot.Scalar.Kind { .double }
    fileprivate var storageScalar: PomoGemStorageSnapshot.Scalar { .doubleBits(bitPattern) }
    fileprivate static func fromStorageScalar(_ scalar: PomoGemStorageSnapshot.Scalar) throws -> Self {
        guard case let .doubleBits(value) = scalar else { throw PomoGemStorageSnapshot.Failure.invalidSnapshot }
        return Double(bitPattern: value)
    }
}

extension Date: StorageSnapshotScalarConvertible {
    fileprivate static var storageKind: PomoGemStorageSnapshot.Scalar.Kind { .date }
    fileprivate var storageScalar: PomoGemStorageSnapshot.Scalar { .dateBits(timeIntervalSinceReferenceDate.bitPattern) }
    fileprivate static func fromStorageScalar(_ scalar: PomoGemStorageSnapshot.Scalar) throws -> Self {
        guard case let .dateBits(value) = scalar else { throw PomoGemStorageSnapshot.Failure.invalidSnapshot }
        return Date(timeIntervalSinceReferenceDate: Double(bitPattern: value))
    }
}

extension UUID: StorageSnapshotScalarConvertible {
    fileprivate static var storageKind: PomoGemStorageSnapshot.Scalar.Kind { .uuid }
    fileprivate var storageScalar: PomoGemStorageSnapshot.Scalar { .uuid(self) }
    fileprivate static func fromStorageScalar(_ scalar: PomoGemStorageSnapshot.Scalar) throws -> Self {
        guard case let .uuid(value) = scalar else { throw PomoGemStorageSnapshot.Failure.invalidSnapshot }
        return value
    }
}

extension Data: StorageSnapshotScalarConvertible {
    fileprivate static var storageKind: PomoGemStorageSnapshot.Scalar.Kind { .data }
    fileprivate var storageScalar: PomoGemStorageSnapshot.Scalar { .data(self) }
    fileprivate static func fromStorageScalar(_ scalar: PomoGemStorageSnapshot.Scalar) throws -> Self {
        guard case let .data(value) = scalar else { throw PomoGemStorageSnapshot.Failure.invalidSnapshot }
        return value
    }
}

extension SessionSource: StorageSnapshotScalarConvertible {
    fileprivate static var storageKind: PomoGemStorageSnapshot.Scalar.Kind { .string }
    fileprivate var storageScalar: PomoGemStorageSnapshot.Scalar { .string(rawValue) }
    fileprivate static func fromStorageScalar(_ scalar: PomoGemStorageSnapshot.Scalar) throws -> Self {
        guard case let .string(raw) = scalar, let value = Self(rawValue: raw) else { throw PomoGemStorageSnapshot.Failure.invalidSnapshot }
        return value
    }
}

extension PebbleKind: StorageSnapshotScalarConvertible {
    fileprivate static var storageKind: PomoGemStorageSnapshot.Scalar.Kind { .string }
    fileprivate var storageScalar: PomoGemStorageSnapshot.Scalar { .string(rawValue) }
    fileprivate static func fromStorageScalar(_ scalar: PomoGemStorageSnapshot.Scalar) throws -> Self {
        guard case let .string(raw) = scalar, let value = Self(rawValue: raw) else { throw PomoGemStorageSnapshot.Failure.invalidSnapshot }
        return value
    }
}

extension AchievementKind: StorageSnapshotScalarConvertible {
    fileprivate static var storageKind: PomoGemStorageSnapshot.Scalar.Kind { .string }
    fileprivate var storageScalar: PomoGemStorageSnapshot.Scalar { .string(rawValue) }
    fileprivate static func fromStorageScalar(_ scalar: PomoGemStorageSnapshot.Scalar) throws -> Self {
        guard case let .string(raw) = scalar, let value = Self(rawValue: raw) else { throw PomoGemStorageSnapshot.Failure.invalidSnapshot }
        return value
    }
}

extension Optional: StorageSnapshotScalarConvertible where Wrapped: StorageSnapshotScalarConvertible {
    fileprivate static var storageKind: PomoGemStorageSnapshot.Scalar.Kind { Wrapped.storageKind }
    fileprivate static var storageOptional: Bool { true }
    fileprivate var storageScalar: PomoGemStorageSnapshot.Scalar { map(\.storageScalar) ?? .null }
    fileprivate static func fromStorageScalar(_ value: PomoGemStorageSnapshot.Scalar) throws -> Self {
        if value == .null { return nil }
        return try Wrapped.fromStorageScalar(value)
    }
}
