import CloudKit
import SwiftData
import XCTest
@testable import PomoGem

@MainActor
final class CloudStorageTransferCloudKitTests: XCTestCase {
    func testDecoderCoversEveryCloudScalarFromTheSharedSchemaRegistry() throws {
        let decoder = CloudStorageTransferRecordDecoder()
        let schema = PersistenceStoreTopology.cloudSchema
        XCTAssertEqual(Set(decoder.fieldsByEntity.keys), Set(schema.entities.map(\.name)))
        for entity in schema.entities {
            XCTAssertEqual(Set(decoder.fieldsByEntity[entity.name, default: []].map(\.name)), Set(entity.attributes.map(\.name)))
            let source = record(entity.name)
            let decoded = try decoder.decode(source)
            XCTAssertEqual(Set(decoded.fields.keys), Set(entity.attributes.map(\.name)))
            for field in decoder.fieldsByEntity[entity.name, default: []] where field.isOptional {
                XCTAssertEqual(decoded.fields[field.name], .null)
            }
        }
    }

    func testEveryRequiredFieldAndUnknownSchemaFailClosed() throws {
        let decoder = CloudStorageTransferRecordDecoder()
        for (entity, fields) in decoder.fieldsByEntity {
            for field in fields where !field.isOptional {
                let incomplete = record(entity)
                incomplete["CD_" + field.name] = nil
                XCTAssertThrowsError(try decoder.decode(incomplete), entity + "." + field.name)
            }
            let unknown = record(entity)
            unknown["CD_futureProperty"] = "future" as CKRecordValue
            XCTAssertThrowsError(try decoder.decode(unknown))
        }
        let unknown = CKRecord(recordType: "CD_UnknownModel")
        unknown["CD_entityName"] = "UnknownModel" as CKRecordValue
        XCTAssertThrowsError(try decoder.decode(unknown))
        let mismatched = record("Subject")
        mismatched["CD_entityName"] = "Prefs" as CKRecordValue
        XCTAssertThrowsError(try decoder.decode(mismatched))
    }

    func testScalarTransportPreservesLargeIntegerAndRejectsInvalidNumbers() throws {
        let decoder = CloudStorageTransferRecordDecoder()
        let source = record("ActivityResetMarker")
        source["CD_sequence"] = NSNumber(value: Int.max)
        XCTAssertEqual(try decoder.decode(source).fields["sequence"], .integer(Int.max))
        for invalid in [NSNumber(value: true), NSNumber(value: 1.5), NSNumber(value: Double.infinity)] {
            source["CD_sequence"] = invalid
            XCTAssertThrowsError(try decoder.decode(source))
        }
        let prefs = record("Prefs")
        prefs["CD_soundOn"] = NSNumber(value: 2)
        XCTAssertThrowsError(try decoder.decode(prefs))
        prefs["CD_soundOn"] = NSNumber(value: 1)
        XCTAssertEqual(try decoder.decode(prefs).fields["soundOn"], .boolean(true))
    }

    func testObservedSecureTransformableDictionaryUsesExactPropertyName() throws {
        for (property, value) in [("source", "manual"), ("pebbleKind", "prism"), ("kind", "examPass")] {
            let data = try NSKeyedArchiver.archivedData(withRootObject: [property: value] as NSDictionary, requiringSecureCoding: true)
            XCTAssertEqual(try CloudStorageTransferRecordDecoder.enumValue(data as NSData, property: property), value)
            let wrongKey = try NSKeyedArchiver.archivedData(withRootObject: ["rawValue": value] as NSDictionary, requiringSecureCoding: true)
            XCTAssertThrowsError(try CloudStorageTransferRecordDecoder.enumValue(wrongKey as NSData, property: property))
        }
        let unknown = try NSKeyedArchiver.archivedData(withRootObject: ["source": "futureSource"] as NSDictionary, requiringSecureCoding: true)
        XCTAssertThrowsError(try CloudStorageTransferRecordDecoder.enumValue(unknown as NSData, property: "source"))
        let decoder = CloudStorageTransferRecordDecoder()
        let source = record("StudySession")
        source["CD_source"] = try NSKeyedArchiver.archivedData(withRootObject: ["source": "manual"] as NSDictionary, requiringSecureCoding: true) as NSData
        XCTAssertEqual(try decoder.decode(source).fields["source"], .string("manual"))
    }

    func testActualSyntheticCoreDataKnownKeysArchiveRetainsStrictEnumValidation() throws {
        // The framework-created synthetic fixture already used by the device
        // evidence reader contains no account, record, user, or signing data.
        let encoded = """
        YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8Q
        D05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGrCwwXHSIjKS4vMzRVJG51bGzVDQ4PEBESExQVFlZ2
        YWx1ZXNWJGNsYXNzXXNlYXJjaE1hcHBpbmdaZW1wdHlUb2tlbld2ZXJzaW9ugAiACoACgAcQAdQO
        GBkRGhscFlZsZW5ndGhUa2V5c4AGEAGAA9IeDh8hWk5TLm9iamVjdHOhIIAEgAVWc291cmNl0iQl
        JidaJGNsYXNzbmFtZVgkY2xhc3Nlc1dOU0FycmF5oiYoWE5TT2JqZWN00iQlKitfEBtOU0tub3du
        S2V5c01hcHBpbmdTdHJhdGVneTGjLC0oXxAbTlNLbm93bktleXNNYXBwaW5nU3RyYXRlZ3kxXxAa
        TlNLbm93bktleXNNYXBwaW5nU3RyYXRlZ3lfEChfX2VtcHR5X3Nsb3RfdG9rZW5fNGMyNF85OGRj
        X2FjMWVfYjc3M19f0h4OMCGhMYAJgAVWbWFudWFs0iQlNTZfEBZOU0tub3duS2V5c0RpY3Rpb25h
        cnkxpTc4OTooXxAWTlNLbm93bktleXNEaWN0aW9uYXJ5MV8QFU5TS25vd25LZXlzRGljdGlvbmFy
        eV8QE05TTXV0YWJsZURpY3Rpb25hcnlcTlNEaWN0aW9uYXJ5AAgAEQAaACQAKQAyADcASQBMAFEA
        UwBfAGUAcAB3AH4AjACXAJ8AoQCjAKUApwCpALIAuQC+AMAAwgDEAMkA1ADWANgA2gDhAOYA8QD6
        AQIBBQEOARMBMQE1AVMBcAGbAaABogGkAaYBrQGyAcsB0QHqAgICGAAAAAAAAAIBAAAAAAAAADsA
        AAAAAAAAAAAAAAAAAAIl
        """
        let data = try XCTUnwrap(Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]))
        XCTAssertEqual(data.count, 699)
        XCTAssertEqual(try CloudStorageTransferRecordDecoder.enumValue(data as NSData, property: "source"), "manual")
        XCTAssertThrowsError(try CloudStorageTransferRecordDecoder.enumValue(data as NSData, property: "pebbleKind"))
    }

    func testExternalAssetFallbackIsIncludedAndUnreadableAssetCannotBecomeEmpty() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("value")
        try Data("synthetic full text".utf8).write(to: url)
        let decoder = CloudStorageTransferRecordDecoder()
        let subject = record("Subject")
        subject["CD_name"] = "" as CKRecordValue
        subject["CD_name_ckAsset"] = CKAsset(fileURL: url)
        XCTAssertEqual(try decoder.decode(subject).fields["name"], .string("synthetic full text"))
        let timer = record("SyncedFocusTimer")
        timer["CD_payloadData"] = Data() as NSData
        timer["CD_payloadData_ckAsset"] = CKAsset(fileURL: url)
        XCTAssertEqual(try decoder.decode(timer).fields["payloadData"], .data(Data("synthetic full text".utf8)))
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try decoder.decode(subject))
        XCTAssertThrowsError(try decoder.decode(timer))
    }

    func testGraphResolvesStringForeignKeysAndPreservesPhysicalDuplicates() throws {
        let decoder = CloudStorageTransferRecordDecoder()
        let first = record("Subject", name: "parent-a")
        let second = record("Subject", name: "parent-b")
        for key in first.allKeys() { second[key] = first[key] }
        let study = record("StudySession", name: "child")
        study["CD_subject"] = second.recordID.recordName as CKRecordValue
        let snapshot = try CloudStorageTransferGraph.snapshot([first, second, study].map(decoder.decode))
        XCTAssertEqual(snapshot.records.filter { $0.entity == "Subject" }.count, 2)
        let child = try XCTUnwrap(snapshot.records.first { $0.entity == "StudySession" })
        guard case .toOne(let parentRef) = child.relationships["subject"], let parentRef else {
            return XCTFail("Expected resolved foreign key")
        }
        let parent = try XCTUnwrap(snapshot.records.first { $0.reference == parentRef })
        XCTAssertEqual(parent.relationships["studySessions"], .toMany([child.reference]))
        try snapshot.validate()
        XCTAssertThrowsError(try CloudStorageTransferGraph.snapshot([decoder.decode(study)]))
        study["CD_subject"] = CKRecord.Reference(recordID: second.recordID, action: .none)
        XCTAssertThrowsError(try decoder.decode(study))
    }

    func testOnlyExactCurrentOwnerControlAndDefaultZonesAreExcluded() throws {
        let defaultID = CKRecordZone.default().zoneID
        XCTAssertFalse(try StorageTransferCloudSchema.isSourceZone(defaultID))
        XCTAssertFalse(try StorageTransferCloudSchema.isSourceZone(CKRecordZone.ID(zoneName: StorageTransferCloudSchema.zoneName, ownerName: defaultID.ownerName)))
        XCTAssertTrue(try StorageTransferCloudSchema.isSourceZone(CKRecordZone.ID(zoneName: StorageTransferCloudSchema.managedZoneName, ownerName: defaultID.ownerName)))
        for name in ["unknown-zone", StorageTransferCloudSchema.zoneName + "-other", StorageTransferCloudSchema.managedZoneName + "-other"] {
            XCTAssertThrowsError(try StorageTransferCloudSchema.isSourceZone(CKRecordZone.ID(zoneName: name, ownerName: defaultID.ownerName)))
        }
        XCTAssertThrowsError(try StorageTransferCloudSchema.isSourceZone(CKRecordZone.ID(zoneName: StorageTransferCloudSchema.zoneName, ownerName: "not-current-owner")))
    }

    func testAllPagesRequiredAndUpdatesAndDeletionsReduceFinalRows() throws {
        let decoder = CloudStorageTransferRecordDecoder()
        var state = CloudStorageTransferZoneAccumulator()
        let subject = record("Subject")
        state.changed(subject.recordID, result: .success(subject), decoder: decoder)
        state.page(.success((Data([1]), true)))
        XCTAssertThrowsError(try state.complete(.success(())))
        subject["CD_name"] = "updated" as CKRecordValue
        state.changed(subject.recordID, result: .success(subject), decoder: decoder)
        state.page(.success((Data([2]), false)))
        XCTAssertEqual(try state.complete(.success(())).rows.first?.fields["name"], .string("updated"))
        state.deleted(subject.recordID)
        XCTAssertTrue(try state.complete(.success(())).rows.isEmpty)
        var missingFinal = CloudStorageTransferZoneAccumulator()
        XCTAssertThrowsError(try missingFinal.complete(.success(())))
        missingFinal.page(.success((Data(), false)))
        XCTAssertThrowsError(try missingFinal.complete(.success(())))
    }

    func testPartialRecordZoneAndTerminalErrorsRemainFailuresAfterSuccessCallbacks() {
        let decoder = CloudStorageTransferRecordDecoder()
        let error = CKError(.networkFailure, userInfo: [NSLocalizedDescriptionKey: "PRIVATE_VALUE_NEVER_DISPLAY"])
        for failurePosition in 0 ..< 3 {
            var state = CloudStorageTransferZoneAccumulator()
            let subject = record("Subject")
            state.changed(subject.recordID, result: .success(subject), decoder: decoder)
            if failurePosition == 0 { state.changed(subject.recordID, result: .failure(error), decoder: decoder) }
            if failurePosition == 1 { state.page(.failure(error)) }
            state.page(.success((Data([1]), false)))
            XCTAssertThrowsError(try state.complete(failurePosition == 2 ? .failure(error) : .success(()))) { failure in
                XCTAssertFalse(failure.localizedDescription.contains("PRIVATE_VALUE_NEVER_DISPLAY"))
            }
        }
    }

    func testReadRequiresMatchingAccountAndTransferLeaseBeforeReturning() async throws {
        let state = TransferCloudTestState()
        let expected = binding()
        let client = CloudStorageTransferCloudClient(verifyAccount: { value in
            XCTAssertEqual(value, expected)
            state.accountChecks += 1
        }, readDatabase: { Self.emptyDatabase })
        let result = try await CloudStorageTransferCloudKit(client: client)
            .readSnapshot(expectedBinding: expected) { state.leaseChecks += 1 }
        XCTAssertEqual(result.binding, expected)
        XCTAssertEqual(state.accountChecks, 2)
        XCTAssertEqual(state.leaseChecks, 4)
        let mismatch = CloudStorageTransferCloudClient(verifyAccount: { _ in
            state.accountChecks += 1
            if state.accountChecks == 4 { throw AppleAccountBoundaryResolutionError.blocked(.accountMismatch) }
        }, readDatabase: { Self.emptyDatabase })
        do {
            _ = try await CloudStorageTransferCloudKit(client: mismatch).readSnapshot(expectedBinding: expected) {}
            XCTFail("Changed account cannot produce a transfer snapshot")
        } catch { XCTAssertEqual(error as? AppleAccountBoundaryResolutionError, .blocked(.accountMismatch)) }
        state.leaseChecks = 0
        do {
            _ = try await CloudStorageTransferCloudKit(client: client).readSnapshot(expectedBinding: expected) {
                state.leaseChecks += 1
                if state.leaseChecks == 4 { throw TransferCloudTestFailure.invalidated }
            }
            XCTFail("Late transfer invalidation cannot publish a snapshot")
        } catch { XCTAssertEqual(error as? TransferCloudTestFailure, .invalidated) }
    }

    func testTransientAccountChangeCannotHideBehindEqualBeforeAndAfterChecks() async {
        let center = NotificationCenter()
        let client = CloudStorageTransferCloudClient(verifyAccount: { _ in }, readDatabase: {
            center.post(name: .CKAccountChanged, object: nil)
            return Self.emptyDatabase
        })
        do {
            _ = try await CloudStorageTransferCloudKit(client: client, notificationCenter: center)
                .readSnapshot(expectedBinding: binding()) {}
            XCTFail("Any account-change notification invalidates this attempt")
        } catch { XCTAssertEqual(error as? AppleAccountBoundaryResolutionError, .blocked(.accountMismatch)) }
    }

    func testDeadlineAndCancellationReturnBeforeUncooperativeClientFinishes() async {
        for cancel in [false, true] {
            let gate = TransferCloudReadGate()
            let started = expectation(description: "read started")
            let finished = expectation(description: "request completed")
            let workerFinished = expectation(description: "late worker completed")
            let state = TransferCloudTestState()
            let client = CloudStorageTransferCloudClient(verifyAccount: { _ in }, readDatabase: {
                started.fulfill()
                await gate.wait()
                workerFinished.fulfill()
                return Self.emptyDatabase
            })
            let task = Task { @MainActor in
                defer { state.finished = true; finished.fulfill() }
                do {
                    _ = try await CloudStorageTransferCloudKit(client: client, timeout: cancel ? 10 : 0.2)
                        .readSnapshot(expectedBinding: binding()) {}
                    XCTFail("Interrupted request cannot return a snapshot")
                } catch {
                    if cancel { XCTAssertTrue(error is CancellationError) }
                    else { XCTAssertEqual(error as? CloudStorageTransferCloudError, .timedOut) }
                }
            }
            await fulfillment(of: [started], timeout: 1)
            if cancel { task.cancel() }
            await fulfillment(of: [finished], timeout: 1)
            let finishedBeforeRelease = state.finished
            await gate.release()
            await task.value
            await fulfillment(of: [workerFinished], timeout: 1)
            XCTAssertTrue(finishedBeforeRelease)
        }
    }

    nonisolated private static var emptyDatabase: CloudStorageTransferDatabaseSnapshot {
        CloudStorageTransferDatabaseSnapshot(snapshot: PomoGemStorageSnapshot(records: []), zones: [])
    }

    private func binding() -> ActiveAccountLocalBinding {
        ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: String(repeating: "a", count: 64))!
    }

    private func record(_ entity: String, name: String = UUID().uuidString) -> CKRecord {
        let zone = CKRecordZone.ID(zoneName: StorageTransferCloudSchema.managedZoneName, ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: "CD_" + entity, recordID: CKRecord.ID(recordName: name, zoneID: zone))
        record["CD_entityName"] = entity as CKRecordValue
        for field in PomoGemStorageSnapshot.fieldDescriptors[entity, default: []] where !field.isOptional {
            let value: CKRecordValue
            switch field.kind {
            case .string:
                let raw: String
                switch field.name {
                case "source": raw = "manual"
                case "pebbleKind": raw = "normal"
                case "kind": raw = "perfectScore"
                default: raw = "synthetic"
                }
                value = raw as NSString
            case .integer: value = NSNumber(value: 1)
            case .boolean: value = NSNumber(value: false)
            case .double: value = NSNumber(value: 1.25)
            case .date: value = Date(timeIntervalSinceReferenceDate: 1_000) as NSDate
            case .uuid: value = UUID().uuidString as NSString
            case .data: value = Data([1, 2, 3]) as NSData
            }
            record["CD_" + field.name] = value
        }
        return record
    }
}

private enum TransferCloudTestFailure: Error, Equatable { case invalidated }
@MainActor private final class TransferCloudTestState {
    var accountChecks = 0
    var leaseChecks = 0
    var finished = false
}
private actor TransferCloudReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
