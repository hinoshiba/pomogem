import CloudKit
import Foundation
import XCTest
@testable import PomoGem

/// Destructive, opt-in operator integration test. Requires explicit authorization
/// to delete ALL data in PomoGem's synchronized private CloudKit container:
/// POMOGEM_REAL_CLOUD_DELETE=1
/// POMOGEM_REAL_CLOUD_DELETE_ALL_CONFIRMED=1
/// POMOGEM_CLOUD_DELETE_TIMEOUT_SECONDS=180 (30...300)
///
/// Run only this test in a freshly installed physical Release host, left at its
/// initial storage chooser. Independently verify that exact host's signed iCloud
/// environment is Production. Public CloudKit APIs do not expose that entitlement.
/// No ModelContainer is opened. The operations container, default zone, schemas,
/// local preferences, and Apple Settings UI are never modified by this test.
/// Terminate the host after this attempt, including after timeout/partial failure.
@MainActor
final class RealDeviceCloudDeletionTests: XCTestCase {
    func testDeleteAuthorizedPrivateCloudData() async throws {
        #if targetEnvironment(simulator) || DEBUG
        throw XCTSkip("Cloud deletion requires a signed Release host on a physical iPhone")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["POMOGEM_REAL_CLOUD_DELETE"] == "1" else {
            throw XCTSkip("Real CloudKit deletion is explicitly opt-in")
        }
        var report = CloudDeletionReport()
        var stage = "configuration"
        let acknowledgments = CloudDeletionAcknowledgments()
        let accountLease = CloudDeletionAccountLease()
        defer { accountLease.stopObserving() }
        do {
            guard environment["POMOGEM_REAL_CLOUD_DELETE_ALL_CONFIRMED"] == "1",
                  !environment.keys.contains(where: {
                      $0.hasPrefix("POMOGEM_UI_TEST") || $0 == "POMOGEM_LOCAL_PREVIEW"
                          || $0 == "XCODE_RUNNING_FOR_PREVIEWS"
                  }),
                  environment["POMOGEM_REAL_SWIFTDATA_LIFECYCLE"] != "1" else {
                throw CloudDeletionFailure.invalidConfiguration
            }
            let timeout = Double(environment["POMOGEM_CLOUD_DELETE_TIMEOUT_SECONDS"] ?? "180") ?? .nan
            guard timeout.isFinite, (30 ... 300).contains(timeout) else {
                throw CloudDeletionFailure.invalidConfiguration
            }
            executionTimeAllowance = 360
            let deadline = ContinuousClock().now.advanced(by: .seconds(timeout))
            let container = CKContainer(identifier: CloudSyncConfiguration.synchronizedDataContainerIdentifier)
            let database = container.privateCloudDatabase

            stage = "initialChooserAndAccount"
            try requireUnusedInstallation(accountLease)
            let identity = try await verifiedAccount(deadline: deadline)
            try requireUnusedInstallation(accountLease)

            stage = "enumerateBeforeDeletion"
            let before = try await fetchZones(database: database, deadline: deadline, accountLease: accountLease)
            report.zoneCountBefore = before.count
            let defaultZoneID = CKRecordZone.default().zoneID
            // A private database should expose only its current user's zones.
            // Never interpret an unexpected owner or alternate default zone as
            // permission to delete it, even with the all-data confirmation.
            guard before.allSatisfy({ $0.ownerName == defaultZoneID.ownerName }),
                  before.allSatisfy({ $0.zoneName != defaultZoneID.zoneName || $0 == defaultZoneID }) else {
                throw CloudDeletionFailure.unsupportedZoneIdentity
            }
            let targets = before.filter { $0 != defaultZoneID }
            report.defaultZoneObservedBefore = before.contains(defaultZoneID)
            report.customZoneCountBefore = targets.count
            report.requestedDeletionCount = targets.count

            stage = "accountBeforeDeletion"
            guard try await verifiedAccount(deadline: deadline) == identity else {
                throw CloudDeletionFailure.accountChanged
            }
            try requireUnusedInstallation(accountLease)
            if !targets.isEmpty {
                stage = "deleteEnumeratedCustomZones"
                acknowledgments.expect(targets)
                let operation = CKModifyRecordZonesOperation(recordZonesToSave: nil, recordZoneIDsToDelete: targets)
                operation.perRecordZoneDeleteBlock = { id, result in
                    acknowledgments.receive(id: id, result: result)
                }
                let completion = CloudDeletionCompletion()
                operation.modifyRecordZonesResultBlock = { result in
                    completion.finish(acknowledgments.validate(result))
                }
                try await execute(operation, database: database, completion: completion,
                                  deadline: deadline, accountLease: accountLease,
                                  onSubmit: { report.deletionOperationSubmitted = true })
                report.allRequestedDeletionsAcknowledged = true
            } else {
                report.allRequestedDeletionsAcknowledged = true
            }

            stage = "accountAfterDeletion"
            guard try await verifiedAccount(deadline: deadline) == identity else {
                throw CloudDeletionFailure.accountChanged
            }
            try requireUnusedInstallation(accountLease)

            stage = "verifyCustomZonesAbsent"
            let after = try await fetchZones(database: database, deadline: deadline, accountLease: accountLease)
            report.zoneCountAfter = after.count
            report.customZoneCountAfter = after.filter { $0 != defaultZoneID }.count
            report.defaultZoneObservedAfter = after.contains(defaultZoneID)
            // A recreated/new zone is an explicit failed verification. Do not
            // silently broaden the original deletion plan or retry new targets.
            guard after.allSatisfy({ $0 == defaultZoneID }) else {
                throw CloudDeletionFailure.customZonesRemain
            }
            stage = "finalAccount"
            guard try await verifiedAccount(deadline: deadline) == identity else {
                throw CloudDeletionFailure.accountChanged
            }
            try requireUnusedInstallation(accountLease)
            report.accountStable = true
            report.emptyCustomZonesVerified = true
            report.succeeded = true
            report.deletionOutcome = targets.isEmpty ? "noCustomZones" : "acknowledgedAndVerified"
        } catch {
            report.failureStage = stage
            report.failureKind = (error as? CloudDeletionFailure)?.rawValue
                ?? (error is CancellationError ? "cancelled" : "frameworkError")
            let nsError = error as NSError
            if [CKErrorDomain, NSCocoaErrorDomain, NSURLErrorDomain].contains(nsError.domain) {
                report.frameworkErrorCode = nsError.code
            }
            report.deletionMayHavePartiallyApplied = report.deletionOperationSubmitted
            report.deletionOutcome = report.deletionOperationSubmitted ? "indeterminateOrPartial" : "notStarted"
        }
        report.acknowledgedDeletionCountAtReport = acknowledgments.successCount
        report.failedDeletionCountAtReport = acknowledgments.failureCount
        try publish(report)
        XCTAssertTrue(report.succeeded, "Cloud deletion failed or is indeterminate; inspect sanitized JSON before another attempt")
        #endif
    }

    private func requireUnusedInstallation(_ accountLease: CloudDeletionAccountLease) throws {
        try Task.checkCancellation()
        try accountLease.check()
        guard PersistenceDeploymentState.load() == .unselected,
              PersistenceDeploymentState.loadMountState() == .unrecorded,
              AccountScopedLocalState.activeBinding() == nil,
              AccountScopedLocalState.activeNamespace() == nil,
              !AccountScopedLocalState.hasPersistedCloudBindingHistory() else {
            throw CloudDeletionFailure.normalStoreAlreadySelected
        }
        // Also reject a prior hosted SwiftData mount: those containers can be
        // retained by the framework after their test-local references disappear.
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        guard !FileManager.default.fileExists(atPath: documents.appendingPathComponent("RealDeviceSwiftDataAudit").path) else {
            throw CloudDeletionFailure.hostedStoreHistoryPresent
        }
    }

    private func remaining(until deadline: ContinuousClock.Instant) throws -> TimeInterval {
        let parts = ContinuousClock().now.duration(to: deadline).components
        let value = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        guard value > 0 else { throw CloudDeletionFailure.deadline }
        return value
    }

    private func verifiedAccount(deadline: ContinuousClock.Instant) async throws -> CKRecord.ID {
        try Task.checkCancellation()
        return try await CloudAccountIdentityVerifier.verify(
            using: .live(containerIdentifier: CloudSyncConfiguration.synchronizedDataContainerIdentifier),
            timeout: min(45, remaining(until: deadline)), retryDelay: 0.5
        )
    }

    private func fetchZones(database: CKDatabase, deadline: ContinuousClock.Instant,
                            accountLease: CloudDeletionAccountLease) async throws -> [CKRecordZone.ID] {
        let operation = CKFetchRecordZonesOperation.fetchAllRecordZonesOperation()
        let zones = CloudDeletionZoneList()
        let completion = CloudDeletionCompletion()
        operation.perRecordZoneResultBlock = { id, result in zones.receive(id: id, result: result) }
        operation.fetchRecordZonesResultBlock = { result in completion.finish(zones.validate(result)) }
        try await execute(operation, database: database, completion: completion,
                          deadline: deadline, accountLease: accountLease)
        return zones.ids
    }

    private func execute(_ operation: CKDatabaseOperation, database: CKDatabase,
                         completion: CloudDeletionCompletion, deadline: ContinuousClock.Instant,
                         accountLease: CloudDeletionAccountLease, onSubmit: () -> Void = {}) async throws {
        try requireUnusedInstallation(accountLease)
        let timeout = min(45, try remaining(until: deadline))
        operation.qualityOfService = .userInitiated
        operation.configuration.timeoutIntervalForRequest = min(15, timeout)
        operation.configuration.timeoutIntervalForResource = timeout
        let cancellationID = try accountLease.installCancellation {
            completion.finish(.failure(CloudDeletionFailure.accountChanged))
            operation.cancel()
        }
        defer { accountLease.clearCancellation(cancellationID); operation.cancel() }
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(timeout))
            completion.finish(.failure(CloudDeletionFailure.deadline))
            operation.cancel()
        }
        defer { timeoutTask.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                // Cancellation before enqueue is terminal; never submit an
                // already rejected destructive operation.
                guard !completion.isFinished else { return }
                onSubmit()
                database.add(operation)
            }
        } onCancel: {
            completion.finish(.failure(CancellationError()))
            operation.cancel()
        }
        try requireUnusedInstallation(accountLease)
    }

    private func publish(_ report: CloudDeletionReport) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "PomoGemCloudDeletionEvidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try data.write(to: documents.appendingPathComponent("PomoGemCloudDeletionEvidence.json"), options: [.atomic, .completeFileProtection])
        print("POMOGEM_CLOUD_DELETION_EVIDENCE " + String(decoding: data, as: UTF8.self))
    }
}

private enum CloudDeletionFailure: String, Error {
    case invalidConfiguration, normalStoreAlreadySelected, hostedStoreHistoryPresent
    case accountChanged, deadline, unsupportedZoneIdentity, tooManyZones
    case invalidZoneResponse, incompleteDeletionAcknowledgments, customZonesRemain
}

private struct CloudDeletionReport: Encodable {
    let formatVersion = 1
    let source = "hostedReleasePrivateCloudKitZoneDeletion"
    let verifiesAppleSettingsUI = false
    let environmentRequiresIndependentSignatureVerification = true
    let defaultZoneExcludedFromDeletion = true
    let modifiesOperationsContainer = false
    var zoneCountBefore: Int?
    var customZoneCountBefore: Int?
    var defaultZoneObservedBefore = false
    var requestedDeletionCount = 0
    var deletionOperationSubmitted = false
    var acknowledgedDeletionCountAtReport = 0
    var failedDeletionCountAtReport = 0
    var allRequestedDeletionsAcknowledged = false
    var zoneCountAfter: Int?
    var customZoneCountAfter: Int?
    var defaultZoneObservedAfter = false
    var emptyCustomZonesVerified = false
    var accountStable = false
    var succeeded = false
    var deletionMayHavePartiallyApplied = false
    var deletionOutcome = "notStarted"
    var failureStage: String?
    var failureKind: String?
    var frameworkErrorCode: Int?
}

private final class CloudDeletionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class CloudDeletionZoneList: @unchecked Sendable {
    private let lock = NSLock()
    private var received: Set<CKRecordZone.ID> = []
    private var failure: Error?
    var ids: [CKRecordZone.ID] { lock.lock(); defer { lock.unlock() }; return Array(received) }

    func receive(id: CKRecordZone.ID, result: Result<CKRecordZone, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        switch result {
        case let .success(zone):
            guard zone.zoneID == id, !received.contains(id) else {
                failure = CloudDeletionFailure.invalidZoneResponse
                return
            }
            guard received.count < 128 else { failure = CloudDeletionFailure.tooManyZones; return }
            received.insert(id)
        case let .failure(error): failure = error
        }
    }

    func validate(_ result: Result<Void, Error>) -> Result<Void, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let failure { return .failure(failure) }
        return result
    }
}

private final class CloudDeletionAcknowledgments: @unchecked Sendable {
    private let lock = NSLock()
    private var expected: Set<CKRecordZone.ID> = []
    private var succeeded: Set<CKRecordZone.ID> = []
    private var failed: Set<CKRecordZone.ID> = []
    private var failure: Error?
    var successCount: Int { lock.lock(); defer { lock.unlock() }; return succeeded.count }
    var failureCount: Int { lock.lock(); defer { lock.unlock() }; return failed.count }

    func expect(_ ids: [CKRecordZone.ID]) {
        lock.lock(); defer { lock.unlock() }
        expected = Set(ids)
    }

    func receive(id: CKRecordZone.ID, result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard expected.contains(id), !succeeded.contains(id), !failed.contains(id) else {
            failure = CloudDeletionFailure.incompleteDeletionAcknowledgments
            return
        }
        switch result {
        case .success: succeeded.insert(id)
        case let .failure(error): failed.insert(id); failure = error
        }
    }

    func validate(_ result: Result<Void, Error>) -> Result<Void, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let failure { return .failure(failure) }
        if case .failure = result { return result }
        guard succeeded == expected else { return .failure(CloudDeletionFailure.incompleteDeletionAcknowledgments) }
        return .success(())
    }
}

/// Invalidates permanently if an account-change notification is observed, even
/// if the account later changes back before a second identity read completes.
private final class CloudDeletionAccountLease: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    private var cancellation: (id: UUID, block: @Sendable () -> Void)?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
            self?.invalidate()
        }
    }

    func stopObserving() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func check() throws {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated else { throw CloudDeletionFailure.accountChanged }
    }

    func installCancellation(_ block: @escaping @Sendable () -> Void) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated else { throw CloudDeletionFailure.accountChanged }
        let id = UUID()
        cancellation = (id, block)
        return id
    }

    func clearCancellation(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if cancellation?.id == id { cancellation = nil }
    }

    private func invalidate() {
        lock.lock()
        invalidated = true
        let block = cancellation?.block
        cancellation = nil
        lock.unlock()
        block?()
    }
}
