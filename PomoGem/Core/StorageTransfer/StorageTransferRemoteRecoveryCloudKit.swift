import CloudKit
import CoreFoundation
import Darwin
import Foundation

/// Transport seam: live saves always use ifServerRecordUnchanged. A proof is
/// the server record's secure system-fields archive, never a fabricated tag.
struct StorageTransferRecoveryCloudRecord: @unchecked Sendable {
    let record: CKRecord
    /// The actual server revision, stable across save/fetch representations.
    let changeTag: String
    let systemFieldsProof: String
}

struct StorageTransferRecoveryCloudCASProof: Equatable, Sendable {
    let changeTag: String
    let systemFieldsProof: String
}

@MainActor
struct StorageTransferRecoveryCloudClient {
    var verifyAccount: (String) async throws -> Void
    var fetch: (CKRecord.ID) async throws -> StorageTransferRecoveryCloudRecord?
    var save: (CKRecord, StorageTransferRecoveryCloudCASProof?) async throws -> StorageTransferRecoveryCloudRecord
    var ensureZone: (CKRecordZone.ID) async throws -> Void
    var delete: (CKRecord.ID) async throws -> Void

    static var live: Self {
        let transport = StorageTransferRecoveryCloudTransport()
        return Self(verifyAccount: { fingerprint in
            let boundary = try await AppleAccountBoundaryResolver().resolve()
            try requireVerifiedAccount(boundary.binding, expectedFingerprint: fingerprint)
        }, fetch: { try await transport.fetch($0) }, save: { try await transport.save($0, proof: $1) },
                    ensureZone: { try await transport.ensureZone($0) }, delete: { try await transport.delete($0) })
    }

    /// This comparison receives a live resolver result. Preserve its positive
    /// account mismatch so the host can revoke offline access durably; record
    /// and transaction identity mismatches are not Apple Account observations.
    static func requireVerifiedAccount(_ binding: ActiveAccountLocalBinding,
                                       expectedFingerprint: String) throws {
        guard StorageTransferRecoverySchema.isDigest(expectedFingerprint) else {
            throw StorageTransferRecoveryError.identityMismatch
        }
        guard binding.accountFingerprint == expectedFingerprint else {
            throw AppleAccountBoundaryResolutionError.blocked(.accountMismatch)
        }
    }
}

/// This adapter never opens a SwiftData store or deletes a zone/control/receipt.
/// Construction makes no CloudKit request. Missing schema/permission is an error;
/// no deployment or administrative schema mutation is attempted here.
@MainActor
final class StorageTransferRemoteRecoveryCloudKit: StorageTransferRecoveryBackend {
    private let client: StorageTransferRecoveryCloudClient
    private let lease: RecoveryCloudAccountLease
    private let validateAccess: () throws -> Void
    private let timeout: TimeInterval
    private let assets: StorageTransferRecoveryAssetFiles
    private var fingerprint: String?

    init(client: StorageTransferRecoveryCloudClient? = nil, timeout: TimeInterval = 45,
         notificationCenter: NotificationCenter = .default,
         temporaryDirectory: URL = FileManager.default.temporaryDirectory,
         validateAccess: @escaping () throws -> Void = {}) {
        self.client = client ?? .live
        self.timeout = timeout.isFinite ? min(max(timeout, 0.01), 60) : 45
        lease = RecoveryCloudAccountLease(center: notificationCenter)
        assets = StorageTransferRecoveryAssetFiles(root: temporaryDirectory)
        self.validateAccess = validateAccess
    }

    func verifyAccount(_ expected: String) async throws {
        guard StorageTransferRecoverySchema.isDigest(expected), fingerprint == nil || fingerprint == expected else {
            throw StorageTransferRecoveryError.identityMismatch
        }
        try check()
        try await bounded { try await self.client.verifyAccount(expected) }
        try check()
        fingerprint = expected
    }

    func readControl() async throws -> StorageTransferRecoveryEnvelope? {
        guard let value = try await fetch(StorageTransferRecoveryCloudCodec.controlID) else { return nil }
        let control = try StorageTransferRecoveryCloudCodec.decodeControl(value.record,
            name: StorageTransferRecoverySchema.controlRecordName, terminal: false)
        try requireAccount(control.manifest.accountFingerprint)
        let result = StorageTransferRecoveryEnvelope(control: control, changeTag: value.changeTag,
            systemFieldsProof: value.systemFieldsProof)
        try result.validate()
        return result
    }

    func compareAndSwapControl(_ control: StorageTransferRecoveryControl,
                               replacing: StorageTransferRecoveryEnvelope?) async throws -> StorageTransferRecoveryEnvelope {
        try control.validate()
        try requireAccount(control.manifest.accountFingerprint)
        if let replacing {
            try replacing.validate()
            try requireAccount(replacing.control.manifest.accountFingerprint)
        }
        let proof: StorageTransferRecoveryCloudCASProof? = try replacing.map {
            guard let systemFieldsProof = $0.systemFieldsProof else { throw StorageTransferRecoveryError.staleControl }
            return StorageTransferRecoveryCloudCASProof(changeTag: $0.changeTag, systemFieldsProof: systemFieldsProof)
        }
        try await io { try await self.client.ensureZone(StorageTransferRecoveryCloudCodec.zoneID) }
        let record = try StorageTransferRecoveryCloudCodec.control(control, name: StorageTransferRecoverySchema.controlRecordName)
        let saved = try await io { try await self.client.save(record, proof) }
        let actual = try StorageTransferRecoveryCloudCodec.decodeControl(saved.record,
            name: StorageTransferRecoverySchema.controlRecordName, terminal: false)
        guard actual == control else { throw StorageTransferRecoveryError.staleControl }
        let result = StorageTransferRecoveryEnvelope(control: actual, changeTag: saved.changeTag,
            systemFieldsProof: saved.systemFieldsProof)
        try result.validate()
        return result
    }

    func readChunk(manifest: StorageTransferRecoveryManifest, index: Int) async throws -> StorageTransferRecoveryChunk? {
        try manifest.validate()
        try requireAccount(manifest.accountFingerprint)
        guard manifest.chunks.indices.contains(index) else { throw StorageTransferRecoveryError.invalidManifest }
        let name = "chunk-\(manifest.transactionID.uuidString.lowercased())-\(index)"
        guard let value = try await fetch(StorageTransferRecoveryCloudCodec.id(name)) else { return nil }
        let chunk = try StorageTransferRecoveryCloudCodec.decodeChunk(value.record)
        try chunk.validate(manifest: manifest, index: index)
        return chunk
    }

    func saveChunkIfAbsent(_ chunk: StorageTransferRecoveryChunk) async throws {
        try StorageTransferRecoveryCloudCodec.validateChunk(chunk)
        try requireAccount(chunk.accountFingerprint)
        let id = StorageTransferRecoveryCloudCodec.id(chunk.recordName)
        if let existing = try await fetch(id) {
            guard try StorageTransferRecoveryCloudCodec.decodeChunk(existing.record) == chunk else {
                throw StorageTransferRecoveryError.corruptChunk
            }
            return
        }
        let file = try assets.write(chunk.bytes)
        defer { try? assets.remove(file) }
        let record = try StorageTransferRecoveryCloudCodec.chunk(chunk, assetURL: file)
        do {
            let saved = try await io { try await self.client.save(record, nil) }
            guard try StorageTransferRecoveryCloudCodec.decodeChunk(saved.record) == chunk else {
                throw StorageTransferRecoveryError.corruptChunk
            }
        } catch {
            // An uncertain acknowledgment is never success. Only an independent
            // exact read can recognize another retry's immutable upload.
            guard StorageTransferRecoveryCloudCodec.isConflict(error),
                  let existing = try await fetch(id),
                  try StorageTransferRecoveryCloudCodec.decodeChunk(existing.record) == chunk else { throw error }
        }
        guard let readback = try await fetch(id),
              try StorageTransferRecoveryCloudCodec.decodeChunk(readback.record) == chunk else {
            throw StorageTransferRecoveryError.missingChunk
        }
    }

    func retainTerminalReceipt(_ control: StorageTransferRecoveryControl) async throws {
        try control.validate()
        guard control.isTerminal else { throw StorageTransferRecoveryError.invalidControl }
        try requireAccount(control.manifest.accountFingerprint)
        if let prior = try await readTerminalReceipt(transactionID: control.manifest.transactionID) {
            guard prior == control else { throw StorageTransferRecoveryError.conflictingTransaction }
            return
        }
        let record = try StorageTransferRecoveryCloudCodec.control(control, name: control.terminalReceiptRecordName)
        do {
            let saved = try await io { try await self.client.save(record, nil) }
            guard try StorageTransferRecoveryCloudCodec.decodeControl(saved.record,
                name: control.terminalReceiptRecordName, terminal: true) == control else {
                throw StorageTransferRecoveryError.invalidControl
            }
        } catch {
            guard StorageTransferRecoveryCloudCodec.isConflict(error),
                  try await readTerminalReceipt(transactionID: control.manifest.transactionID) == control else { throw error }
        }
        guard try await readTerminalReceipt(transactionID: control.manifest.transactionID) == control else {
            throw StorageTransferRecoveryError.invalidControl
        }
    }

    func readTerminalReceipt(transactionID: UUID) async throws -> StorageTransferRecoveryControl? {
        let name = "receipt-\(transactionID.uuidString.lowercased())"
        guard let value = try await fetch(StorageTransferRecoveryCloudCodec.id(name)) else { return nil }
        let control = try StorageTransferRecoveryCloudCodec.decodeControl(value.record, name: name, terminal: true)
        guard control.manifest.transactionID == transactionID else { throw StorageTransferRecoveryError.identityMismatch }
        try requireAccount(control.manifest.accountFingerprint)
        return control
    }

    func deleteChunkIfMatches(_ chunk: StorageTransferRecoveryChunk,
                              terminalReceipt: StorageTransferRecoveryControl) async throws {
        try terminalReceipt.validate()
        guard terminalReceipt.isTerminal else { throw StorageTransferRecoveryError.invalidControl }
        try chunk.validate(manifest: terminalReceipt.manifest, index: chunk.index)
        try requireAccount(chunk.accountFingerprint)
        guard try await readTerminalReceipt(transactionID: chunk.transactionID) == terminalReceipt else {
            throw StorageTransferRecoveryError.invalidControl
        }
        let id = StorageTransferRecoveryCloudCodec.id(chunk.recordName)
        guard let value = try await fetch(id) else { return }
        guard try StorageTransferRecoveryCloudCodec.decodeChunk(value.record) == chunk else {
            throw StorageTransferRecoveryError.corruptChunk
        }
        // CloudKit has no conditional-delete change-tag API. Under this
        // immutable-record protocol only this exact transaction's chunk ID can
        // be removed. Retain terminal receipts for retries after late uploads.
        try await io { try await self.client.delete(id) }
    }

    func cleanStaleTemporaryAssets(now: Date = .now) throws { try assets.cleanStale(now: now) }

    private func requireAccount(_ expected: String) throws {
        try check()
        guard fingerprint == expected else { throw StorageTransferRecoveryError.identityMismatch }
    }
    private func check() throws { try Task.checkCancellation(); try lease.check(); try validateAccess() }
    private func fetch(_ id: CKRecord.ID) async throws -> StorageTransferRecoveryCloudRecord? {
        try await io { try await self.client.fetch(id) }
    }
    private func io<Value>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        guard let fingerprint else { throw StorageTransferRecoveryError.identityMismatch }
        try await verifyAccount(fingerprint)
        let result = try await bounded(operation)
        try check()
        try await verifyAccount(fingerprint)
        return result
    }
    private func bounded<Value>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try check()
        let result = try await recoveryCloudDeadline(timeout: timeout, lease: lease, operation: operation)
        try check()
        return result
    }
}

enum StorageTransferRecoveryCloudCodec {
    static let maximumControlBytes = 65_536
    static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: StorageTransferRecoverySchema.zoneName, ownerName: CKRecordZone.default().zoneID.ownerName)
    }
    static var controlID: CKRecord.ID { id(StorageTransferRecoverySchema.controlRecordName) }
    static func id(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }
    static let controlKeys: Set<String> = ["formatVersion", "controlJSON", "controlSHA256"]
    static let chunkKeys: Set<String> = ["formatVersion", "transactionID", "accountFingerprint", "payloadSHA256", "index", "byteCount", "chunkSHA256", "asset"]

    static func control(_ value: StorageTransferRecoveryControl, name: String) throws -> CKRecord {
        try value.validate()
        guard name == StorageTransferRecoverySchema.controlRecordName || (value.isTerminal && name == value.terminalReceiptRecordName) else {
            throw StorageTransferRecoveryError.invalidControl
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumControlBytes else { throw StorageTransferRecoveryError.limitExceeded }
        let record = CKRecord(recordType: StorageTransferRecoverySchema.controlRecordType, recordID: id(name))
        record["formatVersion"] = 1 as NSNumber
        record["controlJSON"] = data as NSData
        record["controlSHA256"] = StorageTransferRecoverySchema.digest(data) as NSString
        return record
    }
    static func decodeControl(_ record: CKRecord, name: String, terminal: Bool) throws -> StorageTransferRecoveryControl {
        guard record.recordID == id(name), record.recordType == StorageTransferRecoverySchema.controlRecordType,
              Set(record.allKeys()) == controlKeys, try integer(record["formatVersion"]) == 1,
              let data = record["controlJSON"] as? Data, !data.isEmpty, data.count <= maximumControlBytes,
              let digest = record["controlSHA256"] as? String,
              StorageTransferRecoverySchema.digest(data) == digest else { throw StorageTransferRecoveryError.invalidControl }
        let value = try JSONDecoder().decode(StorageTransferRecoveryControl.self, from: data)
        try value.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Reject unknown nested metadata rather than ignoring future fields.
        guard let original = try JSONSerialization.jsonObject(with: data) as? NSDictionary,
              let canonical = try JSONSerialization.jsonObject(with: encoder.encode(value)) as? NSDictionary,
              original == canonical,
              !terminal || (value.isTerminal && name == value.terminalReceiptRecordName) else {
            throw StorageTransferRecoveryError.invalidControl
        }
        return value
    }
    static func validateChunk(_ value: StorageTransferRecoveryChunk) throws {
        guard StorageTransferRecoverySchema.isDigest(value.accountFingerprint),
              StorageTransferRecoverySchema.isDigest(value.payloadSHA256),
              (0..<StorageTransferRecoverySchema.maximumChunks).contains(value.index),
              !value.bytes.isEmpty, value.bytes.count <= StorageTransferRecoverySchema.maximumChunkBytes else {
            throw StorageTransferRecoveryError.corruptChunk
        }
    }
    static func chunk(_ value: StorageTransferRecoveryChunk, assetURL: URL) throws -> CKRecord {
        try validateChunk(value)
        let record = CKRecord(recordType: StorageTransferRecoverySchema.chunkRecordType, recordID: id(value.recordName))
        record["formatVersion"] = 1 as NSNumber
        record["transactionID"] = value.transactionID.uuidString.lowercased() as NSString
        record["accountFingerprint"] = value.accountFingerprint as NSString
        record["payloadSHA256"] = value.payloadSHA256 as NSString
        record["index"] = value.index as NSNumber
        record["byteCount"] = value.bytes.count as NSNumber
        record["chunkSHA256"] = StorageTransferRecoverySchema.digest(value.bytes) as NSString
        record["asset"] = CKAsset(fileURL: assetURL)
        return record
    }
    static func decodeChunk(_ record: CKRecord) throws -> StorageTransferRecoveryChunk {
        guard record.recordType == StorageTransferRecoverySchema.chunkRecordType,
              record.recordID.zoneID == zoneID, Set(record.allKeys()) == chunkKeys,
              try integer(record["formatVersion"]) == 1,
              let rawID = record["transactionID"] as? String, let transaction = UUID(uuidString: rawID),
              rawID == transaction.uuidString.lowercased(),
              let account = record["accountFingerprint"] as? String,
              let payload = record["payloadSHA256"] as? String,
              let sha = record["chunkSHA256"] as? String,
              let asset = record["asset"] as? CKAsset, let url = asset.fileURL else { throw StorageTransferRecoveryError.corruptChunk }
        let index = try integer(record["index"])
        let count = try integer(record["byteCount"])
        guard count > 0, count <= StorageTransferRecoverySchema.maximumChunkBytes else { throw StorageTransferRecoveryError.limitExceeded }
        let bytes = try StorageTransferRecoveryAssetFiles.read(url, expectedCount: count)
        let value = StorageTransferRecoveryChunk(transactionID: transaction, accountFingerprint: account,
            payloadSHA256: payload, index: index, bytes: bytes)
        try validateChunk(value)
        guard record.recordID == id(value.recordName), StorageTransferRecoverySchema.digest(bytes) == sha else {
            throw StorageTransferRecoveryError.corruptChunk
        }
        return value
    }
    static func integer(_ value: CKRecordValue?) throws -> Int {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              let result = Int(value.stringValue) else { throw StorageTransferRecoveryError.invalidControl }
        return result
    }
    static func isConflict(_ error: Error) -> Bool {
        if error as? StorageTransferRecoveryCloudTransportError == .conflict { return true }
        guard let error = error as? CKError else { return false }
        if error.code == .serverRecordChanged { return true }
        return error.code == .partialFailure && error.partialErrorsByItemID?.values.contains(where: { ($0 as? CKError)?.code == .serverRecordChanged }) == true
    }
    static func systemFields(_ record: CKRecord) throws -> String {
        guard let tag = record.recordChangeTag, !tag.isEmpty else { throw StorageTransferRecoveryError.invalidControl }
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder); coder.finishEncoding()
        let proof = coder.encodedData.base64EncodedString()
        guard proof.utf8.count <= 4096 else { throw StorageTransferRecoveryError.limitExceeded }
        return proof
    }
    static func restoring(_ proof: String, prototype: CKRecord, expectedChangeTag: String) throws -> CKRecord {
        guard !proof.isEmpty, proof.utf8.count <= 4096, let data = Data(base64Encoded: proof) else {
            throw StorageTransferRecoveryError.staleControl
        }
        let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
        decoder.requiresSecureCoding = true; decoder.decodingFailurePolicy = .setErrorAndReturn
        defer { decoder.finishDecoding() }
        guard let record = CKRecord(coder: decoder), decoder.error == nil,
              record.recordID == prototype.recordID, record.recordType == prototype.recordType,
              !expectedChangeTag.isEmpty, record.recordChangeTag == expectedChangeTag,
              record.allKeys().isEmpty else {
            throw StorageTransferRecoveryError.staleControl
        }
        for key in prototype.allKeys() { record[key] = prototype[key] }
        return record
    }
}

struct StorageTransferRecoveryAssetFiles {
    private static let prefix = "pomogem-transfer-asset-"
    let root: URL
    func write(_ bytes: Data) throws -> URL {
        guard !bytes.isEmpty, bytes.count <= StorageTransferRecoverySchema.maximumChunkBytes else { throw StorageTransferRecoveryError.limitExceeded }
        let directory = root.appendingPathComponent(Self.prefix + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let file = directory.appendingPathComponent("chunk.asset")
        do { try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); return file }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func remove(_ file: URL) throws {
        let directory = file.deletingLastPathComponent()
        guard file.lastPathComponent == "chunk.asset", directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              Self.owned(directory.lastPathComponent) else { throw StorageTransferRecoveryError.corruptChunk }
        try validateDirectory(directory)
        try FileManager.default.removeItem(at: directory)
    }
    func cleanStale(now: Date, age: TimeInterval = 86_400) throws {
        for directory in try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
        where Self.owned(directory.lastPathComponent) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  let date = values.contentModificationDate, now.timeIntervalSince(date) > max(3600, age) else { continue }
            try validateDirectory(directory)
            try FileManager.default.removeItem(at: directory)
        }
    }
    private func validateDirectory(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw StorageTransferRecoveryError.corruptChunk }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard file.lastPathComponent == "chunk.asset", values.isRegularFile == true, values.isSymbolicLink != true else {
                throw StorageTransferRecoveryError.corruptChunk
            }
        }
    }
    private static func owned(_ name: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = String(name.dropFirst(prefix.count))
        return UUID(uuidString: suffix)?.uuidString.lowercased() == suffix
    }
    static func read(_ url: URL, expectedCount: Int) throws -> Data {
        guard url.isFileURL, expectedCount > 0, expectedCount <= StorageTransferRecoverySchema.maximumChunkBytes else {
            throw StorageTransferRecoveryError.corruptChunk
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StorageTransferRecoveryError.missingChunk }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size == expectedCount else { throw StorageTransferRecoveryError.corruptChunk }
        let bytes = try handle.read(upToCount: expectedCount + 1) ?? Data()
        guard bytes.count == expectedCount else { throw StorageTransferRecoveryError.corruptChunk }
        return bytes
    }
}

enum StorageTransferRecoveryCloudTransportError: Error, LocalizedError, Equatable {
    case conflict, incompleteResponse, unsafeOperation
    var errorDescription: String? { "iCloudの復旧用コピーを確定できませんでした。元のデータを保持して再試行してください。" }
}

private func recoveryCloudSanitized(_ error: Error) -> Error {
    if error is CancellationError || error is StorageTransferRecoveryError
        || error is StorageTransferRecoveryCloudTransportError || error is AppleAccountBoundaryResolutionError
        || error is CloudStorageTransferCloudError { return error }
    if StorageTransferRecoveryCloudCodec.isConflict(error) { return StorageTransferRecoveryCloudTransportError.conflict }
    return CloudStorageTransferCloudError.cloud(CloudAccountVerificationFailure.classify(error, stage: .privateDatabase))
}

/// Only the fixed current-owner recovery zone is reachable through this live
/// transport. Per-record acknowledgments and terminal operation success are
/// both required; an empty result is never a successful upload.
@MainActor
struct StorageTransferRecoveryCloudTransport {
    private var database: CKDatabase {
        CKContainer(identifier: CloudSyncConfiguration.synchronizedDataContainerIdentifier).privateCloudDatabase
    }
    nonisolated static func requireID(_ id: CKRecord.ID) throws {
        guard id.zoneID == StorageTransferRecoveryCloudCodec.zoneID else { throw StorageTransferRecoveryCloudTransportError.unsafeOperation }
        let name = id.recordName
        if name == StorageTransferRecoverySchema.controlRecordName { return }
        if name.hasPrefix("receipt-") {
            let raw = String(name.dropFirst(8))
            guard UUID(uuidString: raw)?.uuidString.lowercased() == raw else { throw StorageTransferRecoveryCloudTransportError.unsafeOperation }
            return
        }
        guard name.hasPrefix("chunk-"), let separator = name.lastIndex(of: "-") else { throw StorageTransferRecoveryCloudTransportError.unsafeOperation }
        let raw = String(name[name.index(name.startIndex, offsetBy: 6)..<separator])
        let indexText = String(name[name.index(after: separator)...])
        guard UUID(uuidString: raw)?.uuidString.lowercased() == raw, let index = Int(indexText), String(index) == indexText,
              (0..<StorageTransferRecoverySchema.maximumChunks).contains(index) else { throw StorageTransferRecoveryCloudTransportError.unsafeOperation }
    }
    nonisolated static func saveOperation(_ prototype: CKRecord, proof: StorageTransferRecoveryCloudCASProof?) throws -> CKModifyRecordsOperation {
        try requireID(prototype.recordID)
        let expectedType = prototype.recordID.recordName.hasPrefix("chunk-")
            ? StorageTransferRecoverySchema.chunkRecordType : StorageTransferRecoverySchema.controlRecordType
        guard prototype.recordType == expectedType,
              proof == nil || prototype.recordID == StorageTransferRecoveryCloudCodec.controlID else {
            throw StorageTransferRecoveryCloudTransportError.unsafeOperation
        }
        let record = try proof.map {
            try StorageTransferRecoveryCloudCodec.restoring($0.systemFieldsProof,
                prototype: prototype, expectedChangeTag: $0.changeTag)
        } ?? prototype
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = true
        configure(operation)
        return operation
    }
    func fetch(_ id: CKRecord.ID) async throws -> StorageTransferRecoveryCloudRecord? {
        try Self.requireID(id)
        return try await recoveryCloudOperation { finish in
            let operation = CKFetchRecordsOperation(recordIDs: [id])
            Self.configure(operation)
            let state = RecoveryCloudSingleResult<CKRecord?>()
            operation.perRecordResultBlock = { received, result in
                state.receive(matches: received == id, result: result.map(Optional.some))
            }
            operation.fetchRecordsResultBlock = { result in
                finish(Result {
                    let value: CKRecord?
                    do { value = try state.complete(result) }
                    catch {
                        guard Self.isMissing(error, id: id), !state.hasUnexpectedResponse else { throw error }
                        return nil
                    }
                    guard let value, value.recordID == id else { throw StorageTransferRecoveryCloudTransportError.incompleteResponse }
                    return try Self.response(value)
                })
            }
            database.add(operation)
            return operation
        }
    }
    func save(_ record: CKRecord, proof: StorageTransferRecoveryCloudCASProof?) async throws -> StorageTransferRecoveryCloudRecord {
        let operation = try Self.saveOperation(record, proof: proof)
        return try await recoveryCloudOperation { finish in
            let state = RecoveryCloudSingleResult<CKRecord>()
            operation.perRecordSaveBlock = { id, result in state.receive(matches: id == record.recordID, result: result) }
            operation.modifyRecordsResultBlock = { result in
                finish(Result {
                    let saved = try state.complete(result)
                    guard saved.recordID == record.recordID, saved.recordType == record.recordType else {
                        throw StorageTransferRecoveryCloudTransportError.incompleteResponse
                    }
                    return try Self.response(saved)
                })
            }
            database.add(operation)
            return operation
        }
    }
    nonisolated private static func response(_ record: CKRecord) throws -> StorageTransferRecoveryCloudRecord {
        guard let changeTag = record.recordChangeTag, !changeTag.isEmpty,
              changeTag.utf8.count <= 4096 else { throw StorageTransferRecoveryError.invalidControl }
        return StorageTransferRecoveryCloudRecord(record: record, changeTag: changeTag,
            systemFieldsProof: try StorageTransferRecoveryCloudCodec.systemFields(record))
    }
    func ensureZone(_ id: CKRecordZone.ID) async throws {
        guard id == StorageTransferRecoveryCloudCodec.zoneID else { throw StorageTransferRecoveryCloudTransportError.unsafeOperation }
        let _: CKRecordZone = try await recoveryCloudOperation { finish in
            let operation = CKModifyRecordZonesOperation(recordZonesToSave: [CKRecordZone(zoneID: id)], recordZoneIDsToDelete: nil)
            Self.configure(operation)
            let state = RecoveryCloudSingleResult<CKRecordZone>()
            operation.perRecordZoneSaveBlock = { received, result in state.receive(matches: received == id, result: result) }
            operation.modifyRecordZonesResultBlock = { result in
                finish(Result {
                    let zone = try state.complete(result)
                    guard zone.zoneID == id else { throw StorageTransferRecoveryCloudTransportError.incompleteResponse }
                    return zone
                })
            }
            database.add(operation)
            return operation
        }
    }
    func delete(_ id: CKRecord.ID) async throws {
        try Self.requireID(id)
        guard id.recordName.hasPrefix("chunk-") else { throw StorageTransferRecoveryCloudTransportError.unsafeOperation }
        let _: Void = try await recoveryCloudOperation { finish in
            let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: [id])
            operation.isAtomic = true
            Self.configure(operation)
            let state = RecoveryCloudSingleResult<Void>()
            operation.perRecordDeleteBlock = { received, result in state.receive(matches: received == id, result: result) }
            operation.modifyRecordsResultBlock = { result in
                finish(Result {
                    do { return try state.complete(result) }
                    catch {
                        guard Self.isMissing(error, id: id), !state.hasUnexpectedResponse else { throw error }
                    }
                })
            }
            database.add(operation)
            return operation
        }
    }
    nonisolated static func isMissing(_ error: Error, id: CKRecord.ID) -> Bool {
        guard let error = error as? CKError else { return false }
        if error.code == .unknownItem || error.code == .zoneNotFound { return true }
        guard error.code == .partialFailure, let failures = error.partialErrorsByItemID,
              failures.count == 1, let own = failures[id] as? CKError else { return false }
        return own.code == .unknownItem || own.code == .zoneNotFound
    }
    nonisolated private static func configure(_ operation: CKOperation) {
        operation.configuration.qualityOfService = .userInitiated
        operation.configuration.timeoutIntervalForRequest = 15
        operation.configuration.timeoutIntervalForResource = 45
    }
}

/// Shared by the native callbacks and deterministic acknowledgment tests.
final class RecoveryCloudSingleResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?
    private var invalid = false
    func receive(matches: Bool, result: Result<Value, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard matches, value == nil else { invalid = true; return }
        value = result
    }
    var hasUnexpectedResponse: Bool { lock.lock(); defer { lock.unlock() }; return invalid }
    func complete(_ terminal: Result<Void, Error>) throws -> Value {
        lock.lock(); defer { lock.unlock() }
        guard !invalid else { throw StorageTransferRecoveryCloudTransportError.incompleteResponse }
        try terminal.get()
        guard let value else { throw StorageTransferRecoveryCloudTransportError.incompleteResponse }
        return try value.get()
    }
}

private final class RecoveryCloudCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var cancel: (() -> Void)?
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return }
        self.continuation = continuation; lock.unlock()
    }
    func cancellation(_ action: @escaping () -> Void) {
        lock.lock()
        if result != nil { lock.unlock(); action(); return }
        cancel = action; lock.unlock()
    }
    func finish(_ incoming: Result<Value, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        let incoming = incoming.mapError(recoveryCloudSanitized)
        result = incoming
        let continuation = continuation; self.continuation = nil
        let cancel = cancel; self.cancel = nil
        lock.unlock()
        cancel?(); continuation?.resume(with: incoming)
    }
}

private final class RecoveryCloudAccountLease: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    private var cancellations: [UUID: () -> Void] = [:]
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?
    init(center: NotificationCenter) {
        self.center = center
        observer = center.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in self?.invalidate() }
    }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if changed { throw StorageTransferRecoveryError.identityMismatch }
    }
    func register(_ cancellation: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        if changed { lock.unlock(); cancellation(); return id }
        cancellations[id] = cancellation; lock.unlock(); return id
    }
    func remove(_ id: UUID) { lock.lock(); cancellations[id] = nil; lock.unlock() }
    private func invalidate() {
        lock.lock(); changed = true; let actions = Array(cancellations.values); cancellations.removeAll(); lock.unlock()
        actions.forEach { $0() }
    }
    deinit { if let observer { center.removeObserver(observer) } }
}

@MainActor
private func recoveryCloudDeadline<Value>(timeout: TimeInterval, lease: RecoveryCloudAccountLease,
    operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
    let completion = RecoveryCloudCompletion<Value>()
    let token = lease.register { completion.finish(.failure(StorageTransferRecoveryError.identityMismatch)) }
    defer { lease.remove(token) }
    return try await withTaskCancellationHandler {
        try Task.checkCancellation(); try lease.check()
        return try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation)
            let work = Task { @MainActor in
                do { completion.finish(.success(try await operation())) }
                catch { completion.finish(.failure(error)) }
            }
            let timer = Task {
                do { try await Task.sleep(for: .seconds(timeout)); completion.finish(.failure(CloudStorageTransferCloudError.timedOut)) }
                catch { }
            }
            completion.cancellation { work.cancel(); timer.cancel() }
        }
    } onCancel: { completion.finish(.failure(CancellationError())) }
}

@MainActor
private func recoveryCloudOperation<Value>(start: (@escaping (Result<Value, Error>) -> Void) -> CKOperation) async throws -> Value {
    let completion = RecoveryCloudCompletion<Value>()
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation)
            let operation = start { completion.finish($0) }
            completion.cancellation { operation.cancel() }
        }
    } onCancel: { completion.finish(.failure(CancellationError())) }
}
