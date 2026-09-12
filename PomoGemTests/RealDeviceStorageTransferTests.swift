import CloudKit
import Foundation
import SwiftData
import XCTest
@testable import PomoGem

/// Operator-only, physical Release-host audit. The test makes read-only
/// CloudKit requests; ordinary host-app startup can still perform its normal
/// mirroring/maintenance. Do not describe the entire process as read-only.
/// The runner independently verifies the actual signed Production entitlement.
/// POMOGEM_REAL_STORAGE_TRANSFER=1 enables the test; all ordinary runs skip.
/// POMOGEM_REAL_STORAGE_TRANSFER_IMPORT=1 additionally saves a copy into a
/// unique private .none test store, never into the application's normal stores.
@MainActor
final class RealDeviceStorageTransferTests: XCTestCase {
    func testActualCloudManifestAndPrivateLocalRoundTrip() async throws {
        #if targetEnvironment(simulator) || DEBUG
        throw XCTSkip("Storage transfer evidence requires a physical Release host")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["POMOGEM_REAL_STORAGE_TRANSFER"] == "1" else {
            throw XCTSkip("Actual CloudKit storage transfer evidence is explicitly opt-in")
        }
        guard !environment.keys.contains(where: {
            $0.hasPrefix("POMOGEM_UI_TEST") || $0 == "POMOGEM_LOCAL_PREVIEW"
                || $0 == "POMOGEM_REAL_CLOUD_DELETE" || $0 == "POMOGEM_REAL_SWIFTDATA_LIFECYCLE"
        }) else { return XCTFail("Conflicting audit configuration") }
        executionTimeAllowance = 480
        var report = StorageTransferPhysicalReport()
        report.buildLabel = environment["POMOGEM_STORAGE_TRANSFER_BUILD_LABEL"] ?? "unlabelled-WIP"
        let initialSelection = PersistenceDeploymentState.load()
        var verifiedBinding: ActiveAccountLocalBinding?
        var stage = "account"
        do {
            let expectedBinding: ActiveAccountLocalBinding?
            if case .selected(.cloud(let binding)) = initialSelection { expectedBinding = binding }
            else { expectedBinding = nil }
            let resolved = try await AppleAccountBoundaryResolver().resolve(expectedBinding: expectedBinding)
            verifiedBinding = resolved.binding
            let validate = {
                try Task.checkCancellation()
                guard PersistenceDeploymentState.load() == initialSelection else {
                    throw StorageTransferPhysicalFailure.selectionChanged
                }
            }
            try validate()
            stage = "firstCompleteServerRead"
            let first = try await CloudStorageTransferCloudKit().readSnapshot(expectedBinding: resolved.binding, validateTransfer: validate)
            report.fullSchemaReadSucceeded = true
            report.zoneCount = first.zones.count
            report.recordCounts = first.snapshot.recordCounts.filter { PomoGemStorageSnapshot.cloudModelNames.contains($0.key) }
            report.fieldCounts = PomoGemStorageSnapshot.fieldDescriptors
                .filter { PomoGemStorageSnapshot.cloudModelNames.contains($0.key) }.mapValues(\.count)
            report.allRelationshipGraphsValidated = true

            stage = "secondCompleteServerRead"
            let second = try await CloudStorageTransferCloudKit().readSnapshot(expectedBinding: resolved.binding, validateTransfer: validate)
            report.observedStableSource = try first.snapshot.isEquivalent(to: second.snapshot,
                entities: PomoGemStorageSnapshot.cloudModelNames, normalizeEmptyRelationships: true)
            guard report.observedStableSource else { throw StorageTransferPhysicalFailure.sourceChangedBetweenReads }

            if environment["POMOGEM_REAL_STORAGE_TRANSFER_IMPORT"] == "1" {
                stage = "privateLocalImport"
                let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let directory = documents.appendingPathComponent("StorageTransferReadAudit", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                let schema = PersistenceStoreTopology.shippingSchema
                let configuration = ModelConfiguration("StorageTransferPrivateAudit", schema: schema,
                    url: directory.appendingPathComponent("copy.store"), cloudKitDatabase: .none)
                let container = try ModelContainer(for: schema, configurations: [configuration])
                container.mainContext.autosaveEnabled = false
                _ = try second.snapshot.importIntoEmpty(container.mainContext)
                let readback = try PomoGemStorageSnapshot.capture(from: ModelContext(container))
                report.privateNoneStoreRoundTripVerified = try second.snapshot.isEquivalent(to: readback,
                    normalizeEmptyRelationships: true)
                guard report.privateNoneStoreRoundTripVerified else { throw StorageTransferPhysicalFailure.roundTripMismatch }
                report.privateProjectionCounts = readback.recordCounts.filter { !PomoGemStorageSnapshot.cloudModelNames.contains($0.key) }
            }
            stage = "finalAccount"
            _ = try await AppleAccountBoundaryResolver().resolve(expectedBinding: resolved.binding)
            try validate()
            report.accountVerifiedBeforeAndAfter = true
            report.succeeded = true
        } catch {
            report.failureStage = stage
            if let failure = error as? CloudStorageTransferCloudError {
                switch failure {
                case .timedOut: report.failureKind = "timedOut"
                case .incomplete: report.failureKind = "incomplete"
                case .malformedRecord: report.failureKind = "malformedRecord"
                case .unsupportedSchema: report.failureKind = "unsupportedSchema"
                case .unsupportedZone: report.failureKind = "unsupportedZone"
                case .missingRelationship: report.failureKind = "missingRelationship"
                case .changedDuringRead: report.failureKind = "changedDuringRead"
                case .limitExceeded: report.failureKind = "limitExceeded"
                case .cloud(let typed):
                    report.failureKind = "cloud"
                    report.cloudKitErrorCode = typed.cloudKitCode
                }
            } else if let failure = error as? StorageTransferPhysicalFailure {
                report.failureKind = failure.rawValue
            } else { report.failureKind = error is CancellationError ? "cancelled" : "frameworkFailure" }
            if environment["POMOGEM_REAL_STORAGE_TRANSFER_DIAGNOSTICS"] == "1", let verifiedBinding {
                do {
                    _ = try await AppleAccountBoundaryResolver().resolve(expectedBinding: verifiedBinding)
                    report.fieldDiagnostics = try await StorageTransferCloudDiagnostic.read(decoder: CloudStorageTransferRecordDecoder())
                    _ = try await AppleAccountBoundaryResolver().resolve(expectedBinding: verifiedBinding)
                    report.diagnosticAccountVerified = true
                } catch { report.diagnosticFailed = true }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Storage transfer actual CloudKit evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try data.write(to: documents.appendingPathComponent("StorageTransferPhysicalEvidence.json"), options: [.atomic, .completeFileProtection])
        XCTAssertTrue(report.succeeded, "Actual server manifest/readback failed; inspect sanitized evidence attachment")
        #endif
    }
}

private enum StorageTransferPhysicalFailure: String, Error {
    case selectionChanged, sourceChangedBetweenReads, roundTripMismatch, diagnosticLimit
}

private struct StorageTransferPhysicalReport: Encodable {
    let evidenceVersion = 1
    let auditedAt = Date()
    let testIssuesCloudWrites = false
    let ordinaryHostStartupMayWriteCloud = true
    let isAppStoreReleaseCandidate = false
    var buildLabel = ""
    var succeeded = false
    var fullSchemaReadSucceeded = false
    var allRelationshipGraphsValidated = false
    var observedStableSource = false
    var privateNoneStoreRoundTripVerified = false
    var accountVerifiedBeforeAndAfter = false
    var zoneCount = 0
    var recordCounts: [String: Int] = [:]
    var fieldCounts: [String: Int] = [:]
    var privateProjectionCounts: [String: Int] = [:]
    var failureStage: String?
    var failureKind: String?
    var cloudKitErrorCode: Int?
    var fieldDiagnostics: [StorageTransferDiagnosticField] = []
    var diagnosticAccountVerified = false
    var diagnosticFailed = false
}

private struct StorageTransferDiagnosticField: Codable, Sendable, Hashable {
    let entity: String
    let field: String
    let transportType: String
    let numberType: String?
    let byteCount: Int?
    let assetPresent: Bool
    let secureArchiveRootType: String?
    let archivePropertyType: String?
    let archiveHasOnlyMatchingProperty: Bool?
    let archivePropertyIsSingleKnownCaseDictionary: Bool?
}

/// Diagnostics contain only trusted schema names, transport types and sizes.
/// They never serialize record/account IDs, raw values, or asset contents.
private enum StorageTransferCloudDiagnostic {
    static func read(decoder: CloudStorageTransferRecordDecoder) async throws -> [StorageTransferDiagnosticField] {
        let database = CKContainer(identifier: CloudSyncConfiguration.synchronizedDataContainerIdentifier).privateCloudDatabase
        let zones: [CKRecordZone] = try await run { completion in
            let operation = CKFetchRecordZonesOperation.fetchAllRecordZonesOperation()
            let state = TransferDiagnosticLock((zones: [CKRecordZone](), failure: Optional<Error>.none))
            operation.perRecordZoneResultBlock = { _, result in
                state.use { state in
                    switch result {
                    case .success(let zone): state.zones.append(zone)
                    case .failure(let error): state.failure = error
                    }
                }
            }
            operation.fetchRecordZonesResultBlock = { result in
                let state = state.use { $0 }
                if let error = state.failure { completion(.failure(error)) }
                else { completion(result.map { state.zones }) }
            }
            configure(operation)
            database.add(operation)
            return operation
        }
        guard zones.count <= 128 else { throw StorageTransferPhysicalFailure.diagnosticLimit }
        var report = Set<StorageTransferDiagnosticField>()
        for zone in zones where try StorageTransferCloudSchema.isSourceZone(zone.zoneID) {
            let diagnostics: [StorageTransferDiagnosticField] = try await run { completion in
                let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
                configuration.resultsLimit = 200
                let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zone.zoneID], configurationsByRecordZoneID: [zone.zoneID: configuration])
                operation.fetchAllChanges = true
                let state = TransferDiagnosticLock((rows: 0, fields: Set<StorageTransferDiagnosticField>(), complete: false, failure: Optional<Error>.none))
                operation.recordWasChangedBlock = { _, result in
                    state.use { state in
                        do {
                            state.rows += 1
                            guard state.rows <= 100_000 else { throw StorageTransferPhysicalFailure.diagnosticLimit }
                            state.fields.formUnion(try diagnose(result.get(), decoder: decoder))
                        } catch { state.failure = error }
                    }
                }
                operation.recordZoneFetchResultBlock = { _, result in
                    state.use { state in
                        switch result {
                        case .success(let page): state.complete = !page.moreComing
                        case .failure(let error): state.failure = error
                        }
                    }
                }
                operation.fetchRecordZoneChangesResultBlock = { result in
                    let state = state.use { $0 }
                    if let error = state.failure { completion(.failure(error)) }
                    else if !state.complete { completion(.failure(StorageTransferPhysicalFailure.diagnosticLimit)) }
                    else { completion(result.map { Array(state.fields) }) }
                }
                configure(operation)
                database.add(operation)
                return operation
            }
            report.formUnion(diagnostics)
        }
        return report.sorted { ($0.entity + $0.field + $0.transportType) < ($1.entity + $1.field + $1.transportType) }
    }

    private static func diagnose(_ record: CKRecord, decoder: CloudStorageTransferRecordDecoder) throws -> [StorageTransferDiagnosticField] {
        guard let entity = record["CD_entityName"] as? String, let fields = decoder.fieldsByEntity[entity] else { return [] }
        var report: [StorageTransferDiagnosticField] = []
        for field in fields {
            let probe = CKRecord(recordType: "CD_" + entity)
            probe["CD_entityName"] = entity as NSString
            for other in fields where !other.isOptional {
                let value: CKRecordValue
                switch other.kind {
                case .string:
                    let string = ["source": "manual", "pebbleKind": "normal", "kind": "perfectScore"][other.name] ?? ""
                    value = string as NSString
                case .integer: value = NSNumber(value: 0)
                case .boolean: value = NSNumber(value: false)
                case .double: value = NSNumber(value: 0.0)
                case .date: value = NSDate(timeIntervalSince1970: 0)
                case .uuid: value = UUID().uuidString as NSString
                case .data: value = NSData()
                }
                probe["CD_" + other.name] = value
            }
            let key = "CD_" + field.name
            let value = record[key]
            probe[key] = value
            probe[key + "_ckAsset"] = record[key + "_ckAsset"]
            do { _ = try decoder.decode(probe) }
            catch {
                var archiveRoot: String?
                var propertyType: String?
                var onlyProperty: Bool?
                var caseDictionary: Bool?
                if let data = value as? Data, data.count <= 4 * 1024 * 1024,
                   let object = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSArray.self, NSString.self, NSNumber.self], from: data) {
                    archiveRoot = kind(object)
                    if let dictionary = object as? NSDictionary {
                        let property = dictionary[field.name]
                        propertyType = kind(property)
                        onlyProperty = dictionary.count == 1 && property != nil
                        if let nested = property as? NSDictionary {
                            let knownCases = Set(["timer", "manual", "timerDemoted", "normal", "gold", "prism", "perfectScore", "examPass", "workMilestone"])
                            caseDictionary = nested.count == 1 && nested.allKeys.compactMap { $0 as? String }.allSatisfy(knownCases.contains)
                        }
                    }
                }
                report.append(StorageTransferDiagnosticField(entity: entity, field: field.name,
                    transportType: kind(value), numberType: (value as? NSNumber).map { String(cString: $0.objCType) },
                    byteCount: (value as? Data)?.count, assetPresent: record[key + "_ckAsset"] != nil,
                    secureArchiveRootType: archiveRoot, archivePropertyType: propertyType,
                    archiveHasOnlyMatchingProperty: onlyProperty, archivePropertyIsSingleKnownCaseDictionary: caseDictionary))
            }
        }
        return report
    }

    private static func kind(_ value: Any?) -> String {
        guard let value else { return "absent" }
        switch value {
        case is NSString: return "string"
        case is NSNumber: return "number"
        case is NSDate: return "date"
        case is NSData: return "data"
        case is NSDictionary: return "dictionary"
        case is NSArray: return "array"
        case is CKAsset: return "asset"
        default: return "other"
        }
    }

    private static func configure(_ operation: CKOperation) {
        operation.configuration.timeoutIntervalForRequest = 15
        operation.configuration.timeoutIntervalForResource = 30
    }

    private static func run<Value>(start: (@escaping (Result<Value, Error>) -> Void) -> CKOperation) async throws -> Value {
        let state = TransferDiagnosticCompletion<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                let operation = start { state.finish($0) }
                let timer = Task {
                    do {
                        try await Task.sleep(for: .seconds(35))
                        state.finish(.failure(StorageTransferPhysicalFailure.diagnosticLimit))
                    } catch { }
                }
                state.cancellation { operation.cancel(); timer.cancel() }
            }
        } onCancel: { state.finish(.failure(CancellationError())) }
    }
}

private final class TransferDiagnosticLock<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func use<Result>(_ action: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        return action(&value)
    }
}

private final class TransferDiagnosticCompletion<Value>: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, Error>?
        var result: Result<Value, Error>?
        var cancel: (() -> Void)?
    }
    private let state = TransferDiagnosticLock(State())
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let result = state.use { state -> Result<Value, Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }
    func cancellation(_ cancel: @escaping () -> Void) {
        let finished = state.use { state in
            if state.result != nil { return true }
            state.cancel = cancel
            return false
        }
        if finished { cancel() }
    }
    func finish(_ result: Result<Value, Error>) {
        let value = state.use { state -> (CheckedContinuation<Value, Error>?, (() -> Void)?) in
            guard state.result == nil else { return (nil, nil) }
            state.result = result
            let value = (state.continuation, state.cancel)
            state.continuation = nil; state.cancel = nil
            return value
        }
        value.1?(); value.0?.resume(with: result)
    }
}
