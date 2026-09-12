import CloudKit
import Darwin
import Foundation

enum StorageTransferManagedZoneAdapterError: Error, Equatable {
    case unsafeFile, oversizedPlan, incompleteResponse, timedOut
}

/// One transaction-owned file, outside all model-store artifact families.
/// Construction neither creates a directory nor changes an existing plan.
@MainActor
final class StorageTransferManagedZoneDeletionFileStore: StorageTransferManagedZoneDeletionStore {
    static let filename = "managed-zone-deletion-v1.json"
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

    func load() throws -> StorageTransferManagedZoneDeletionPlan? {
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
        let value = try JSONDecoder().decode(StorageTransferManagedZoneDeletionPlan.self, from: data)
        try validate(value)
        // Unknown fields cannot quietly acquire meaning in a later version.
        let canonical = try encoder().encode(value)
        guard let original = try JSONSerialization.jsonObject(with: data) as? NSDictionary,
              let encoded = try JSONSerialization.jsonObject(with: canonical) as? NSDictionary,
              original == encoded else { throw StorageTransferManagedZoneDeletionError.invalidPlan }
        return value
    }

    func save(_ plan: StorageTransferManagedZoneDeletionPlan,
              replacing previous: StorageTransferManagedZoneDeletionPlan?) throws {
        try validate(plan)
        guard try load() == previous else { throw StorageTransferManagedZoneDeletionError.stalePlan }
        if let previous {
            try validate(previous)
            guard plan.transactionID == previous.transactionID,
                  plan.accountFingerprint == previous.accountFingerprint,
                  plan.sourcePayloadSHA256 == previous.sourcePayloadSHA256,
                  plan.baseline == previous.baseline,
                  plan.revision == previous.revision + 1 else {
                throw StorageTransferManagedZoneDeletionError.stalePlan
            }
        } else {
            guard plan.phase == .prepared else { throw StorageTransferManagedZoneDeletionError.invalidPlan }
        }
        let data = try encoder().encode(plan)
        guard data.count <= Self.maximumBytes else { throw StorageTransferManagedZoneAdapterError.oversizedPlan }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try synchronize(url, directory: false)
        try synchronize(directory, directory: true)
        guard try load() == plan else { throw StorageTransferManagedZoneDeletionError.stalePlan }
    }

    private func validate(_ plan: StorageTransferManagedZoneDeletionPlan) throws {
        try plan.validate()
        guard plan.transactionID == transactionID else { throw StorageTransferManagedZoneDeletionError.stalePlan }
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

@MainActor
struct StorageTransferManagedZoneCloudClient {
    var verifyAccount: (ActiveAccountLocalBinding) async throws -> Void
    var readSnapshot: (ActiveAccountLocalBinding) async throws -> CloudStorageTransferSnapshot
    var deleteZone: (StorageTransferManagedZoneID) async throws -> StorageTransferManagedZoneDeleteAcknowledgment

    static func live(validateAccess: @escaping () throws -> Void) -> Self {
        Self(verifyAccount: { binding in
            _ = try await AppleAccountBoundaryResolver().resolve(expectedBinding: binding)
        }, readSnapshot: { binding in
            try await CloudStorageTransferCloudKit().readSnapshot(expectedBinding: binding,
                                                                  validateTransfer: validateAccess)
        }, deleteZone: { id in
            try await ManagedZoneDeletionTransport.delete(id)
        })
    }
}

/// Construction is side-effect free. The account lease is monotonic for this
/// adapter's lifetime, so switching away and back never revives an old request.
@MainActor
final class StorageTransferManagedZoneDeletionCloudKit: StorageTransferManagedZoneDeletionBackend {
    private let binding: ActiveAccountLocalBinding
    private let client: StorageTransferManagedZoneCloudClient
    private let lease: ManagedZoneAccountLease
    private let timeout: TimeInterval
    private let validateAccess: () throws -> Void

    init(expectedBinding: ActiveAccountLocalBinding,
         client: StorageTransferManagedZoneCloudClient? = nil,
         timeout: TimeInterval = 180,
         notificationCenter: NotificationCenter = .default,
         validateAccess: @escaping () throws -> Void) {
        binding = expectedBinding
        self.client = client ?? .live(validateAccess: validateAccess)
        self.timeout = timeout.isFinite ? min(max(timeout, 0.01), 300) : 180
        lease = ManagedZoneAccountLease(center: notificationCenter)
        self.validateAccess = validateAccess
    }

    func readSnapshot() async throws -> StorageTransferManagedZoneObservation {
        try await bounded(timeout: timeout) {
            try await self.verify()
            let snapshot = try await self.client.readSnapshot(self.binding)
            try self.check()
            guard snapshot.binding == self.binding else {
                throw StorageTransferManagedZoneDeletionError.invalidRecoveryReceipt
            }
            let result = try StorageTransferManagedZoneObservation(snapshot: snapshot)
            try await self.verify()
            return result
        }
    }

    func deleteZone(_ id: StorageTransferManagedZoneID) async throws -> StorageTransferManagedZoneDeleteAcknowledgment {
        try id.validate()
        return try await bounded(timeout: min(timeout, 45)) {
            try await self.verify()
            try id.validate()
            try self.check()
            let result = try await self.client.deleteZone(id)
            try self.check()
            guard result.zoneID == id else { throw StorageTransferManagedZoneAdapterError.incompleteResponse }
            try await self.verify()
            return result
        }
    }

    private func verify() async throws {
        try check()
        try await client.verifyAccount(binding)
        try check()
    }

    private func check() throws {
        try Task.checkCancellation()
        try lease.check()
        try validateAccess()
    }

    private func bounded<Value>(timeout: TimeInterval,
                               operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try check()
        let result = try await managedZoneDeadline(timeout: timeout, lease: lease, operation: operation)
        try check()
        return result
    }
}

/// Shared with deterministic tests: both the exact per-zone callback and the
/// terminal callback are needed. Terminal errors stay errors except an exact
/// zone-not-found result whose per-zone error independently says the same thing.
final class StorageTransferManagedZoneAcknowledgments: @unchecked Sendable {
    private let lock = NSLock()
    private let expected: StorageTransferManagedZoneID
    private var item: Result<Void, Error>?
    private var invalid = false

    init(expected: StorageTransferManagedZoneID) { self.expected = expected }

    func receive(id: CKRecordZone.ID, result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard id == expected.cloudKitID, item == nil else { invalid = true; return }
        item = result
    }

    func complete(_ terminal: Result<Void, Error>) throws -> StorageTransferManagedZoneDeleteAcknowledgment {
        lock.lock()
        defer { lock.unlock() }
        guard !invalid, let item else { throw StorageTransferManagedZoneAdapterError.incompleteResponse }
        switch item {
        case .success:
            try terminal.get()
            return .deleted(expected)
        case .failure(let error):
            guard Self.isDirectMissing(error) else { throw error }
            if case .failure(let terminalError) = terminal {
                guard Self.isExactMissing(terminalError, id: expected.cloudKitID) else { throw terminalError }
            }
            return .alreadyAbsent(expected)
        }
    }

    private static func isDirectMissing(_ error: Error) -> Bool {
        (error as? CKError)?.code == .zoneNotFound
    }

    private static func isExactMissing(_ error: Error, id: CKRecordZone.ID) -> Bool {
        guard let error = error as? CKError else { return false }
        if error.code == .zoneNotFound { return true }
        guard error.code == .partialFailure, let failures = error.partialErrorsByItemID,
              failures.count == 1, let own = failures[id] as? CKError else { return false }
        return own.code == .zoneNotFound
    }
}

@MainActor
private enum ManagedZoneDeletionTransport {
    static func delete(_ id: StorageTransferManagedZoneID) async throws -> StorageTransferManagedZoneDeleteAcknowledgment {
        try id.validate()
        let database = CKContainer(identifier: CloudSyncConfiguration.synchronizedDataContainerIdentifier).privateCloudDatabase
        let completion = ManagedZoneCompletion<StorageTransferManagedZoneDeleteAcknowledgment>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                let operation = CKModifyRecordZonesOperation(recordZonesToSave: nil, recordZoneIDsToDelete: [id.cloudKitID])
                operation.configuration.qualityOfService = .userInitiated
                operation.configuration.timeoutIntervalForRequest = 15
                operation.configuration.timeoutIntervalForResource = 30
                let acknowledgments = StorageTransferManagedZoneAcknowledgments(expected: id)
                operation.perRecordZoneDeleteBlock = { received, result in acknowledgments.receive(id: received, result: result) }
                operation.modifyRecordZonesResultBlock = { result in
                    completion.finish(Result { try acknowledgments.complete(result) })
                }
                completion.cancellation { operation.cancel() }
                database.add(operation)
            }
        } onCancel: { completion.finish(.failure(CancellationError())) }
    }
}

private final class ManagedZoneCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var cancel: (() -> Void)?
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return }
        self.continuation = continuation
        lock.unlock()
    }
    func cancellation(_ action: @escaping () -> Void) {
        lock.lock()
        if result != nil { lock.unlock(); action(); return }
        cancel = action
        lock.unlock()
    }
    func finish(_ incoming: Result<Value, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = incoming
        let continuation = continuation
        self.continuation = nil
        let cancel = cancel
        self.cancel = nil
        lock.unlock()
        cancel?()
        continuation?.resume(with: incoming)
    }
}

private final class ManagedZoneAccountLease: @unchecked Sendable {
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
        lock.lock()
        defer { lock.unlock() }
        if changed { throw StorageTransferRecoveryError.identityMismatch }
    }
    func register(_ cancellation: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        if changed { lock.unlock(); cancellation(); return id }
        cancellations[id] = cancellation
        lock.unlock()
        return id
    }
    func remove(_ id: UUID) { lock.lock(); cancellations[id] = nil; lock.unlock() }
    private func invalidate() {
        lock.lock()
        changed = true
        let actions = Array(cancellations.values)
        cancellations.removeAll()
        lock.unlock()
        actions.forEach { $0() }
    }
    deinit { if let observer { center.removeObserver(observer) } }
}

@MainActor
private func managedZoneDeadline<Value>(timeout: TimeInterval, lease: ManagedZoneAccountLease,
                                       operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
    let completion = ManagedZoneCompletion<Value>()
    let token = lease.register { completion.finish(.failure(StorageTransferRecoveryError.identityMismatch)) }
    defer { lease.remove(token) }
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        try lease.check()
        return try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation)
            let work = Task { @MainActor in
                do { completion.finish(.success(try await operation())) }
                catch { completion.finish(.failure(error)) }
            }
            let timer = Task {
                do {
                    try await Task.sleep(for: .seconds(timeout))
                    completion.finish(.failure(StorageTransferManagedZoneAdapterError.timedOut))
                } catch { }
            }
            completion.cancellation { work.cancel(); timer.cancel() }
        }
    } onCancel: { completion.finish(.failure(CancellationError())) }
}
