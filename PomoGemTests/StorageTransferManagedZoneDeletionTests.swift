import CloudKit
import Foundation
import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferManagedZoneDeletionTests: XCTestCase {
    private let account = String(repeating: "a", count: 64)
    private let otherDigest = String(repeating: "b", count: 64)

    private struct Fixture {
        let manifest: StorageTransferRecoveryManifest
        let plan: StorageTransferManagedZoneDeletionPlan
        let receipt: StorageTransferRecoveryReceipt
        let recovery: StorageTransferRemoteRecovery
        let remote: ZoneRecoveryFake
        let store: ZonePlanFake
        let backend: ZoneDeletionFake
        let coordinator: StorageTransferManagedZoneDeletion
    }

    private func observation(hasZone: Bool = true, token: Data = Data([1])) throws -> StorageTransferManagedZoneObservation {
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: account))
        let zone = CKRecordZone.ID(zoneName: StorageTransferCloudSchema.managedZoneName,
                                   ownerName: CKRecordZone.default().zoneID.ownerName)
        return try StorageTransferManagedZoneObservation(snapshot: CloudStorageTransferSnapshot(
            snapshot: PomoGemStorageSnapshot(records: []), binding: binding,
            zones: hasZone ? [CloudStorageTransferZoneManifest(zoneID: zone, terminalToken: token, recordCount: 0)] : []))
    }

    private func fixture(hasZone: Bool = true) async throws -> Fixture {
        let payload = Data("synthetic authoritative snapshot".utf8)
        let manifest = try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account, payload: payload)
        let remote = ZoneRecoveryFake(account: account)
        let recovery = StorageTransferRemoteRecovery(backend: remote, validateAccess: {})
        _ = try await recovery.stage(manifest: manifest, payload: payload)
        let receipt = try await recovery.authorizeReplacement(manifest: manifest)
        let baseline = try observation(hasZone: hasZone)
        let plan = try StorageTransferManagedZoneDeletionPlan(manifest: manifest, baseline: baseline)
        let store = ZonePlanFake()
        let backend = ZoneDeletionFake(current: baseline, absent: try observation(hasZone: false))
        let coordinator = StorageTransferManagedZoneDeletion(store: store, backend: backend,
            recovery: recovery, validateGenerationAndQuiescence: {})
        return Fixture(manifest: manifest, plan: plan, receipt: receipt, recovery: recovery,
                       remote: remote, store: store, backend: backend, coordinator: coordinator)
    }

    private func expect(_ failure: StorageTransferManagedZoneDeletionError,
                        file: StaticString = #filePath, line: UInt = #line,
                        _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected a closed deletion gate", file: file, line: line)
        } catch { XCTAssertEqual(error as? StorageTransferManagedZoneDeletionError, failure, file: file, line: line) }
    }

    private func altered<T: Codable>(_ value: T, _ mutate: (inout [String: Any]) -> Void) throws -> T {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        mutate(&object)
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testOnlyExactCurrentOwnerFrameworkZoneCanEnterAPlan() throws {
        let owner = CKRecordZone.default().zoneID.ownerName
        XCTAssertNoThrow(try StorageTransferManagedZoneID(CKRecordZone.ID(
            zoneName: StorageTransferCloudSchema.managedZoneName, ownerName: owner)))
        for id in [CKRecordZone.default().zoneID,
                   CKRecordZone.ID(zoneName: StorageTransferCloudSchema.zoneName, ownerName: owner),
                   CKRecordZone.ID(zoneName: "unknown-zone", ownerName: owner),
                   CKRecordZone.ID(zoneName: StorageTransferCloudSchema.managedZoneName, ownerName: "foreign-owner")] {
            XCTAssertThrowsError(try StorageTransferManagedZoneID(id))
        }
        XCTAssertThrowsError(try observation(token: Data()))
        XCTAssertThrowsError(try observation(token: Data(repeating: 1, count: 65_537)))
    }

    func testPlanRoundTripBindsAccountTransactionPayloadAndImmutableBaseline() async throws {
        let f = try await fixture()
        let decoded = try JSONDecoder().decode(StorageTransferManagedZoneDeletionPlan.self,
                                               from: JSONEncoder().encode(f.plan))
        XCTAssertEqual(decoded, f.plan)
        try decoded.validate()
        XCTAssertThrowsError(try altered(decoded) { $0["accountFingerprint"] = otherDigest }.validate())
        XCTAssertThrowsError(try altered(decoded) { $0["sourcePayloadSHA256"] = "wrong" }.validate())
        XCTAssertThrowsError(try altered(decoded) { $0["revision"] = 1 }.validate())
        XCTAssertThrowsError(try decoded.advancing(to: .absenceVerified))
    }

    func testDurableIntentAndExactReadbackPrecedeSingleDeletionAndAdmission() async throws {
        let f = try await fixture()
        try f.coordinator.persistPlan(f.plan)
        f.backend.beforeDelete = {
            XCTAssertEqual(f.store.current?.phase, .deletionIntentRecorded)
            XCTAssertEqual(f.remote.control, f.receipt.envelope)
        }
        let receipt = try await f.coordinator.run(transactionID: f.plan.transactionID, recoveryReceipt: f.receipt)
        XCTAssertEqual(f.store.savedPhases, [.prepared, .deletionIntentRecorded, .absenceVerified])
        XCTAssertEqual(f.backend.deletedIDs, [try XCTUnwrap(f.plan.baseline.zones.first?.id)])
        XCTAssertEqual(receipt.plan.phase, .absenceVerified)
        try await f.coordinator.revalidateAdmission(receipt, recoveryReceipt: f.receipt)
        // Repeating plan persistence cannot rewind a completed checkpoint.
        try f.coordinator.persistPlan(f.plan)
        XCTAssertEqual(f.store.current?.phase, .absenceVerified)
        _ = try await f.coordinator.run(transactionID: f.plan.transactionID, recoveryReceipt: f.receipt)
        XCTAssertEqual(f.backend.deletedIDs.count, 1)
    }

    func testNoPersistedPlanOrUnacknowledgedIntentNeverDeletes() async throws {
        let f = try await fixture()
        await expect(.stalePlan) { _ = try await f.coordinator.run(transactionID: f.plan.transactionID, recoveryReceipt: f.receipt) }
        try f.coordinator.persistPlan(f.plan)
        f.store.discardWriteAt = .deletionIntentRecorded
        await expect(.stalePlan) { _ = try await f.coordinator.run(transactionID: f.plan.transactionID, recoveryReceipt: f.receipt) }
        XCTAssertTrue(f.backend.deletedIDs.isEmpty)
        XCTAssertEqual(f.store.current?.phase, .prepared)
    }

    func testChangedGraphOrTerminalTokenBeforeFirstDeletionNeverRebasesPlan() async throws {
        for changeGraph in [true, false] {
            let f = try await fixture()
            try f.coordinator.persistPlan(f.plan)
            f.backend.current = changeGraph
                ? try altered(f.plan.baseline) { $0["snapshotSHA256"] = otherDigest }
                : try observation(token: Data([2]))
            await expect(.changedCloudData) {
                _ = try await f.coordinator.run(transactionID: f.plan.transactionID, recoveryReceipt: f.receipt)
            }
            XCTAssertTrue(f.backend.deletedIDs.isEmpty)
            XCTAssertEqual(f.store.current, f.plan)
        }
    }

    func testAbsentZoneWithoutLoggedIntentFailsButLoggedIntentResolvesAuthoritativeAbsence() async throws {
        let f = try await fixture()
        try f.coordinator.persistPlan(f.plan)
        f.backend.current = f.backend.absent
        await expect(.changedCloudData) { _ = try await f.coordinator.run(transactionID: f.plan.transactionID, recoveryReceipt: f.receipt) }
        let intent = try f.plan.advancing(to: .deletionIntentRecorded)
        try f.store.save(intent, replacing: f.plan)
        let completed = try await f.coordinator.run(transactionID: f.plan.transactionID, recoveryReceipt: f.receipt)
        XCTAssertEqual(completed.plan.phase, .absenceVerified)
        XCTAssertTrue(f.backend.deletedIDs.isEmpty)
    }

    func testLostDeletionResponseResolvesByInspectionWithoutRepeatingDestruction() async throws {
        let f = try await fixture()
        try f.coordinator.persistPlan(f.plan)
        f.backend.loseDeleteAcknowledgment = true
        do {
            _ = try await f.coordinator.run(transactionID: f.plan.transactionID, recoveryReceipt: f.receipt)
            XCTFail("Expected indeterminate network response")
        } catch { XCTAssertEqual(error as? ZoneDeletionFake.Failure, .transport) }
        XCTAssertEqual(f.store.current?.phase, .deletionIntentRecorded)
        XCTAssertEqual(f.backend.deletedIDs.count, 1)
        _ = try await f.coordinator.run(transactionID: f.plan.transactionID, recoveryReceipt: f.receipt)
        XCTAssertEqual(f.backend.deletedIDs.count, 1)
        XCTAssertEqual(f.store.current?.phase, .absenceVerified)
    }

    func testIntentRetryStopsOnChangedOrRecreatedZoneInsteadOfBroadeningDeletion() async throws {
        let f = try await fixture()
        try f.coordinator.persistPlan(f.plan)
        try f.store.save(f.plan.advancing(to: .deletionIntentRecorded), replacing: f.plan)
        f.backend.current = try observation(token: Data([9]))
        await expect(.changedCloudData) { _ = try await f.coordinator.run(transactionID: f.plan.transactionID, recoveryReceipt: f.receipt) }
        XCTAssertTrue(f.backend.deletedIDs.isEmpty)
        XCTAssertEqual(f.store.current?.baseline, f.plan.baseline)
    }

    func testPerZoneAcknowledgmentDoesNotReplaceIndependentAbsenceProof() async throws {
        let f = try await fixture()
        try f.coordinator.persistPlan(f.plan)
        f.backend.pretendDeletionOnly = true
        await expect(.changedCloudData) { _ = try await f.coordinator.run(transactionID: f.plan.transactionID, recoveryReceipt: f.receipt) }
        XCTAssertEqual(f.store.current?.phase, .deletionIntentRecorded)
        XCTAssertEqual(f.backend.deletedIDs.count, 1)
    }

    func testGenerationInvalidationDuringReadStopsBeforeDeletion() async throws {
        let f = try await fixture()
        var valid = true
        let coordinator = StorageTransferManagedZoneDeletion(store: f.store, backend: f.backend, recovery: f.recovery,
            validateGenerationAndQuiescence: { if !valid { throw StorageTransferManagedZoneDeletionError.stalePlan } })
        try coordinator.persistPlan(f.plan)
        f.backend.onRead = { valid = false }
        await expect(.stalePlan) { _ = try await coordinator.run(transactionID: f.plan.transactionID, recoveryReceipt: f.receipt) }
        XCTAssertTrue(f.backend.deletedIDs.isEmpty)
    }

    func testRemoteRecoveryFenceChangeAfterDeletionKeepsIntentForExplicitRecovery() async throws {
        let f = try await fixture()
        try f.coordinator.persistPlan(f.plan)
        f.backend.beforeDelete = { f.remote.control = nil }
        do {
            _ = try await f.coordinator.run(transactionID: f.plan.transactionID, recoveryReceipt: f.receipt)
            XCTFail("Expected stale recovery fence")
        } catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .staleControl) }
        XCTAssertEqual(f.store.current?.phase, .deletionIntentRecorded)
        XCTAssertEqual(f.backend.deletedIDs.count, 1)
    }

    func testCompletedPlanCannotDeletePartiallyExportedNewDestinationOnReplay() async throws {
        let f = try await fixture()
        try f.coordinator.persistPlan(f.plan)
        let done = try await f.coordinator.run(transactionID: f.plan.transactionID, recoveryReceipt: f.receipt)
        f.backend.current = try observation(token: Data([7]))
        await expect(.destinationAlreadyStarted) {
            _ = try await f.coordinator.run(transactionID: f.plan.transactionID, recoveryReceipt: f.receipt)
        }
        await expect(.destinationAlreadyStarted) {
            try await f.coordinator.revalidateAdmission(done, recoveryReceipt: f.receipt)
        }
        XCTAssertEqual(f.backend.deletedIDs.count, 1)
    }

    func testInitiallyAbsentManagedZoneStillRequiresPersistedPlanAndRecoveryFenceWithoutDeletion() async throws {
        let f = try await fixture(hasZone: false)
        try f.coordinator.persistPlan(f.plan)
        let receipt = try await f.coordinator.run(transactionID: f.plan.transactionID, recoveryReceipt: f.receipt)
        XCTAssertEqual(receipt.plan.phase, .absenceVerified)
        XCTAssertTrue(f.backend.deletedIDs.isEmpty)
        f.remote.account = otherDigest
        do {
            try await f.coordinator.revalidateAdmission(receipt, recoveryReceipt: f.receipt)
            XCTFail("Expected account rejection")
        } catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .identityMismatch) }
    }
}

@MainActor
private final class ZonePlanFake: StorageTransferManagedZoneDeletionStore {
    var current: StorageTransferManagedZoneDeletionPlan?
    var savedPhases: [StorageTransferManagedZoneDeletionPlan.Phase] = []
    var discardWriteAt: StorageTransferManagedZoneDeletionPlan.Phase?
    func load() throws -> StorageTransferManagedZoneDeletionPlan? { current }
    func save(_ plan: StorageTransferManagedZoneDeletionPlan,
              replacing previous: StorageTransferManagedZoneDeletionPlan?) throws {
        guard current == previous else { throw StorageTransferManagedZoneDeletionError.stalePlan }
        try plan.validate()
        if discardWriteAt != plan.phase { current = plan }
        savedPhases.append(plan.phase)
    }
}

@MainActor
private final class ZoneDeletionFake: StorageTransferManagedZoneDeletionBackend {
    enum Failure: Error, Equatable { case transport }
    var current: StorageTransferManagedZoneObservation
    let absent: StorageTransferManagedZoneObservation
    var deletedIDs: [StorageTransferManagedZoneID] = []
    var loseDeleteAcknowledgment = false
    var pretendDeletionOnly = false
    var beforeDelete: (() -> Void)?
    var onRead: (() -> Void)?
    init(current: StorageTransferManagedZoneObservation, absent: StorageTransferManagedZoneObservation) {
        self.current = current
        self.absent = absent
    }
    func readSnapshot() async throws -> StorageTransferManagedZoneObservation {
        let callback = onRead
        onRead = nil
        callback?()
        return current
    }
    func deleteZone(_ id: StorageTransferManagedZoneID) async throws -> StorageTransferManagedZoneDeleteAcknowledgment {
        try id.validate()
        beforeDelete?()
        deletedIDs.append(id)
        if !pretendDeletionOnly { current = absent }
        if loseDeleteAcknowledgment {
            loseDeleteAcknowledgment = false
            throw Failure.transport
        }
        return .deleted(id)
    }
}

@MainActor
private final class ZoneRecoveryFake: StorageTransferRecoveryBackend {
    var account: String
    var control: StorageTransferRecoveryEnvelope?
    private var version = 0
    private var chunks: [String: StorageTransferRecoveryChunk] = [:]
    private var receipts: [UUID: StorageTransferRecoveryControl] = [:]
    init(account: String) { self.account = account }
    func verifyAccount(_ fingerprint: String) async throws {
        guard fingerprint == account else { throw StorageTransferRecoveryError.identityMismatch }
    }
    func readControl() async throws -> StorageTransferRecoveryEnvelope? { control }
    func compareAndSwapControl(_ value: StorageTransferRecoveryControl,
                               replacing previous: StorageTransferRecoveryEnvelope?) async throws -> StorageTransferRecoveryEnvelope {
        guard control == previous else { throw StorageTransferRecoveryError.staleControl }
        version += 1
        let result = StorageTransferRecoveryEnvelope(control: value, changeTag: "synthetic-server-tag-\(version)")
        control = result
        return result
    }
    func readChunk(manifest: StorageTransferRecoveryManifest, index: Int) async throws -> StorageTransferRecoveryChunk? {
        chunks["chunk-\(manifest.transactionID.uuidString.lowercased())-\(index)"]
    }
    func saveChunkIfAbsent(_ chunk: StorageTransferRecoveryChunk) async throws {
        if let existing = chunks[chunk.recordName], existing != chunk { throw StorageTransferRecoveryError.corruptChunk }
        chunks[chunk.recordName] = chunk
    }
    func retainTerminalReceipt(_ control: StorageTransferRecoveryControl) async throws {
        guard control.isTerminal else { throw StorageTransferRecoveryError.invalidControl }
        receipts[control.manifest.transactionID] = control
    }
    func readTerminalReceipt(transactionID: UUID) async throws -> StorageTransferRecoveryControl? { receipts[transactionID] }
    func deleteChunkIfMatches(_ chunk: StorageTransferRecoveryChunk,
                              terminalReceipt: StorageTransferRecoveryControl) async throws {
        guard terminalReceipt.isTerminal,
              receipts[terminalReceipt.manifest.transactionID] == terminalReceipt,
              chunks[chunk.recordName] == chunk else { throw StorageTransferRecoveryError.staleControl }
        chunks.removeValue(forKey: chunk.recordName)
    }
}
