import CloudKit
import Foundation
import SwiftData
import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferPartialDestinationRecoveryTests: XCTestCase {
    private let account = String(repeating: "a", count: 64)

    private func snapshot() throws -> PomoGemStorageSnapshot {
        let schema = PersistenceStoreTopology.shippingSchema
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(
            "PartialRecoveryTests-\(UUID())", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = container.mainContext
        context.autosaveEnabled = false
        let date = Date(timeIntervalSince1970: 1_700_000_000.125)
        let first = Subject(name: "synthetic first", colorHex: "blue", sortOrder: 0, deletedAt: date)
        let second = Subject(name: "synthetic second", colorHex: "red", sortOrder: 1)
        context.insert(first)
        context.insert(second)
        context.insert(StudySession(subject: first, startAt: date, endAt: date, seconds: 1_800,
                                    source: .manual, deviceDayKey: "synthetic-day"))
        context.insert(AchievementStone(subject: second, kind: .examPass, note: "synthetic", achievedAt: date))
        context.insert(Prefs(keepScreenAwake: false, hasCompletedOnboarding: true, settingsWriterID: "synthetic-writer"))
        context.insert(ActivityResetMarker(sequence: 2, resetAt: date, writerDeviceID: "synthetic-writer"))
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        let timerID = UUID()
        try engine.startFocus(isPro: false, now: date, sessionID: timerID)
        let payload = try FocusCloudPayload(envelope: FocusRecoveryEnvelope(engine: engine,
            subject: FocusSubjectSnapshot(subject: first), clockAnchor: nil, pendingCompletion: nil, savedAt: date))
        context.insert(try SyncedFocusTimer(sessionID: timerID, status: .running, payload: payload,
                                           updatedAt: date, writerDeviceID: "synthetic-writer"))
        context.insert(FocusTimerDeviceClaim(sessionID: timerID, deviceID: "synthetic-writer", sequence: 1,
                                             claimedAt: date, releasedAt: date))
        try context.save()
        return try PomoGemStorageSnapshot.capture(from: ModelContext(container))
    }

    private func recordName(_ reference: Int) -> String { "synthetic-row-\(reference)" }

    private func rawRows(_ snapshot: PomoGemStorageSnapshot, references: Set<Int>? = nil) -> [CloudStorageTransferDecodedRecord] {
        let zone = CKRecordZone.ID(zoneName: StorageTransferCloudSchema.managedZoneName,
                                   ownerName: CKRecordZone.default().zoneID.ownerName)
        return snapshot.records.filter {
            PomoGemStorageSnapshot.cloudModelNames.contains($0.entity) && (references?.contains($0.reference) ?? true)
        }.map { row in
            let subject: CKRecord.ID?
            if case let .toOne(reference)? = row.relationships["subject"], let reference {
                subject = CKRecord.ID(recordName: recordName(reference), zoneID: zone)
            } else { subject = nil }
            return CloudStorageTransferDecodedRecord(id: CKRecord.ID(recordName: recordName(row.reference), zoneID: zone),
                entity: row.entity, fields: row.fields, subject: subject)
        }
    }

    private func observation(_ rows: [CloudStorageTransferDecodedRecord], hasZone: Bool = true,
                             token: Data = Data([1])) throws -> StorageTransferPartialDestinationObservation {
        let zone = CKRecordZone.ID(zoneName: StorageTransferCloudSchema.managedZoneName,
                                   ownerName: CKRecordZone.default().zoneID.ownerName)
        return try StorageTransferPartialDestinationObservation(accountFingerprint: account,
            zones: hasZone ? [.init(zoneID: zone, terminalToken: token, recordCount: rows.count)] : [], records: rows)
    }

    private func changed(_ row: CloudStorageTransferDecodedRecord,
                         fields: [String: PomoGemStorageSnapshot.Scalar]? = nil,
                         name: String? = nil, entity: String? = nil,
                         subject: CKRecord.ID?? = nil) -> CloudStorageTransferDecodedRecord {
        CloudStorageTransferDecodedRecord(id: CKRecord.ID(recordName: name ?? row.id.recordName, zoneID: row.id.zoneID),
            entity: entity ?? row.entity, fields: fields ?? row.fields, subject: subject ?? row.subject)
    }

    func testClosedStrictSubsetsAndFullSevenEntityGraphAreAccepted() throws {
        let original = try snapshot()
        let all = rawRows(original)
        XCTAssertEqual(Set(all.map(\.entity)), PomoGemStorageSnapshot.cloudModelNames)
        let choices = [all, all.filter { $0.entity == "Prefs" },
                       all.filter { $0.entity == "Subject" || $0.entity == "StudySession" }, []]
        for rows in choices {
            let proof = try StorageTransferPartialDestinationSubset.verify(observation(rows), belongsTo: original)
            XCTAssertEqual(proof.matchedRecordCount, rows.count)
        }
        let ordered = try observation(all)
        let shuffled = try observation(Array(all.reversed()))
        XCTAssertEqual(try ordered.digest(), try shuffled.digest())
    }

    func testDanglingOrSilentlyNilForeignKeyNeverBecomesDeletionPermission() throws {
        let original = try snapshot()
        let session = try XCTUnwrap(rawRows(original).first { $0.entity == "StudySession" })
        XCTAssertThrowsError(try StorageTransferPartialDestinationSubset.verify(observation([session]), belongsTo: original)) {
            XCTAssertEqual($0 as? StorageTransferPartialRecoveryError, .danglingRelationship)
        }
        let missing = changed(session, subject: .some(nil))
        XCTAssertThrowsError(try StorageTransferPartialDestinationSubset.verify(observation([missing]), belongsTo: original)) {
            XCTAssertEqual($0 as? StorageTransferPartialRecoveryError, .changedRelationship)
        }
    }

    func testNullableRelationshipIsAcceptedOnlyWhenOriginalAlsoHasNil() throws {
        var original = try snapshot()
        let index = try XCTUnwrap(original.records.firstIndex { $0.entity == "StudySession" })
        let reference = original.records[index].reference
        original.records[index].relationships["subject"] = .toOne(nil)
        for index in original.records.indices where original.records[index].entity == "Subject" {
            if case let .toMany(values)? = original.records[index].relationships["studySessions"] {
                original.records[index].relationships["studySessions"] = .toMany(values?.filter { $0 != reference })
            }
        }
        let rows = rawRows(original, references: [reference])
        XCTAssertNil(rows[0].subject)
        XCTAssertEqual(try StorageTransferPartialDestinationSubset.verify(observation(rows), belongsTo: original).matchedRecordCount, 1)
    }

    func testExistingButDifferentParentIsRejectedEvenWhenBothParentsBelongToBackup() throws {
        let original = try snapshot()
        var rows = rawRows(original)
        let index = try XCTUnwrap(rows.firstIndex { $0.entity == "StudySession" })
        let other = try XCTUnwrap(rows.first { $0.entity == "Subject" && $0.id != rows[index].subject })
        rows[index] = changed(rows[index], subject: .some(other.id))
        XCTAssertThrowsError(try StorageTransferPartialDestinationSubset.verify(observation(rows), belongsTo: original)) {
            XCTAssertEqual($0 as? StorageTransferPartialRecoveryError, .changedRelationship)
        }
    }

    func testTombstonesResetHistorySettingsAndUnknownAttributesMustMatchExactly() throws {
        let original = try snapshot()
        for entity in ["Subject", "ActivityResetMarker", "Prefs", "SyncedFocusTimer", "FocusTimerDeviceClaim", "StudySession"] {
            var rows = rawRows(original)
            let index = try XCTUnwrap(rows.firstIndex {
                $0.entity == entity && (entity != "Subject" || $0.fields["deletedAt"] != .null)
            })
            var fields = rows[index].fields
            switch entity {
            case "Subject": fields["deletedAt"] = .null
            case "ActivityResetMarker": fields["sequence"] = .integer(99)
            case "Prefs": fields["keepScreenAwake"] = .boolean(true)
            case "SyncedFocusTimer": fields["payloadData"] = .data(Data([0xff]))
            case "FocusTimerDeviceClaim": fields["sequence"] = .integer(99)
            default: fields["futureUnknownAttribute"] = .string("unrecognized")
            }
            rows[index] = changed(rows[index], fields: fields)
            XCTAssertThrowsError(try StorageTransferPartialDestinationSubset.verify(observation(rows), belongsTo: original)) {
                XCTAssertEqual($0 as? StorageTransferPartialRecoveryError, .foreignRecord)
            }
        }
        let first = try XCTUnwrap(rawRows(original).first)
        XCTAssertThrowsError(try observation([changed(first, entity: "FutureEntity")]))
    }

    func testNewPhysicalDuplicateCannotConsumeTheSameBackupRecordTwice() throws {
        let original = try snapshot()
        let row = try XCTUnwrap(rawRows(original).first { $0.entity == "Prefs" })
        let duplicate = changed(row, name: "new-foreign-copy")
        XCTAssertThrowsError(try StorageTransferPartialDestinationSubset.verify(observation([row, duplicate]), belongsTo: original)) {
            XCTAssertEqual($0 as? StorageTransferPartialRecoveryError, .duplicateRecord)
        }
    }

    func testAmbiguousOriginalPhysicalDuplicatesStayBlockedInsteadOfGuessing() throws {
        var original = try snapshot()
        let prefs = try XCTUnwrap(original.records.first { $0.entity == "Prefs" })
        let next = (original.records.map(\.reference).max() ?? 0) + 1
        original.records.append(.init(reference: next, entity: prefs.entity, fields: prefs.fields, relationships: [:]))
        let row = try XCTUnwrap(rawRows(original, references: [prefs.reference]).first)
        XCTAssertThrowsError(try StorageTransferPartialDestinationSubset.verify(observation([row]), belongsTo: original)) {
            XCTAssertEqual($0 as? StorageTransferPartialRecoveryError, .ambiguousRecord)
        }
    }

    func testDateTransportInSameMillisecondBucketMatchesWithoutChangingRawValues() throws {
        let original = try snapshot()
        let row = try XCTUnwrap(rawRows(original).first { $0.entity == "Subject" && $0.fields["deletedAt"] != .null })
        guard case let .dateBits(bits)? = row.fields["deletedAt"] else { return XCTFail("Expected date fixture") }
        let quantum = StorageTransferPartialDestinationSubset.dateQuantum
        let center = (Double(bitPattern: bits) / quantum).rounded() * quantum
        var fields = row.fields
        fields["deletedAt"] = .dateBits((center + 0.0002).bitPattern)
        let transported = try observation([changed(row, fields: fields)])
        XCTAssertEqual(try StorageTransferPartialDestinationSubset.verify(transported, belongsTo: original).matchedRecordCount, 1)
        XCTAssertEqual(transported.rows[0].fields["deletedAt"], fields["deletedAt"])
        XCTAssertEqual(row.fields["deletedAt"], .dateBits(bits))
        fields["deletedAt"] = .dateBits((center + 0.002).bitPattern)
        XCTAssertThrowsError(try StorageTransferPartialDestinationSubset.verify(observation([changed(row, fields: fields)]), belongsTo: original))
    }

    func testDateQuantizationCollisionDoesNotResolveAmbiguousOriginalRows() throws {
        var original = try snapshot()
        let originalRow = try XCTUnwrap(original.records.first { $0.entity == "Subject" && $0.fields["deletedAt"] != .null })
        guard case let .dateBits(bits)? = originalRow.fields["deletedAt"] else { return XCTFail("Expected date fixture") }
        let quantum = StorageTransferPartialDestinationSubset.dateQuantum
        let center = (Double(bitPattern: bits) / quantum).rounded() * quantum
        var duplicateFields = originalRow.fields
        duplicateFields["deletedAt"] = .dateBits((center + 0.0002).bitPattern)
        original.records.append(.init(reference: (original.records.map(\.reference).max() ?? 0) + 1,
            entity: "Subject", fields: duplicateFields,
            relationships: ["studySessions": .toMany([]), "achievementStones": .toMany([])]))
        let row = try XCTUnwrap(rawRows(original, references: [originalRow.reference]).first)
        XCTAssertThrowsError(try StorageTransferPartialDestinationSubset.verify(observation([row]), belongsTo: original)) {
            XCTAssertEqual($0 as? StorageTransferPartialRecoveryError, .ambiguousRecord)
        }
    }

    func testDateBucketBoundaryConservativelyRejectsEvenSubMillisecondDifference() throws {
        var original = try snapshot()
        let index = try XCTUnwrap(original.records.firstIndex { $0.entity == "Subject" && $0.fields["deletedAt"] != .null })
        // A small fixed reference-date value avoids unrelated floating point
        // precision at present-day epoch magnitudes in this boundary fixture.
        original.records[index].fields["deletedAt"] = .dateBits(1.00049.bitPattern)
        let row = try XCTUnwrap(rawRows(original, references: [original.records[index].reference]).first)
        var fields = row.fields
        fields["deletedAt"] = .dateBits(1.00051.bitPattern)
        XCTAssertThrowsError(try StorageTransferPartialDestinationSubset.verify(observation([changed(row, fields: fields)]), belongsTo: original))
    }

    private struct Fixture {
        let original: PomoGemStorageSnapshot
        let manifest: StorageTransferRecoveryManifest
        let remote: PartialRecoveryRemoteFake
        let recovery: StorageTransferRemoteRecovery
        let store: PartialRecoveryPlanFake
        let backend: PartialRecoveryDestinationFake
        let coordinator: StorageTransferPartialDestinationRecovery
    }

    private func fixture(replacing: Bool = true) async throws -> Fixture {
        let original = try snapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(original)
        let manifest = try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account, payload: bytes)
        let remote = PartialRecoveryRemoteFake(account: account)
        let recovery = StorageTransferRemoteRecovery(backend: remote, validateAccess: {})
        _ = try await recovery.stage(manifest: manifest, payload: bytes)
        if replacing { _ = try await recovery.authorizeReplacement(manifest: manifest) }
        let rows = rawRows(original).filter { $0.entity == "Subject" || $0.entity == "StudySession" }
        let backend = PartialRecoveryDestinationFake(current: try observation(rows), absent: try observation([], hasZone: false))
        let store = PartialRecoveryPlanFake()
        let coordinator = StorageTransferPartialDestinationRecovery(store: store, backend: backend,
            recovery: recovery, validateGenerationAndQuiescence: {})
        return Fixture(original: original, manifest: manifest, remote: remote, recovery: recovery,
                       store: store, backend: backend, coordinator: coordinator)
    }

    func testExplicitPartialRecoveryPersistsProofBeforeDeletionAndReturnsOnlyAbsence() async throws {
        let f = try await fixture()
        let attempt = UUID()
        let plan = try await f.coordinator.prepare(attemptID: attempt, manifest: f.manifest)
        XCTAssertEqual(plan.phase, .verifiedSubset)
        XCTAssertEqual(f.backend.deleteCount, 0)
        f.backend.beforeDelete = { XCTAssertEqual(f.store.current?.phase, .deletionIntentRecorded) }
        let receipt = try await f.coordinator.resume(attemptID: attempt, manifest: f.manifest)
        XCTAssertEqual(receipt.plan.phase, .absenceVerified)
        XCTAssertEqual(receipt.recoveryReceipt.envelope.control.phase, .replacing)
        XCTAssertEqual(f.backend.deleteCount, 1)
        XCTAssertEqual(f.store.phases, [.verifiedSubset, .deletionIntentRecorded, .absenceVerified])
        XCTAssertEqual(f.remote.control?.control.manifest, f.manifest)
    }

    func testUnresolvedDanglingImportAndWrongRemotePhaseNeverCreateADeletionPlan() async throws {
        let f = try await fixture()
        f.backend.current = try observation(rawRows(f.original).filter { $0.entity == "StudySession" })
        do {
            _ = try await f.coordinator.prepare(attemptID: UUID(), manifest: f.manifest)
            XCTFail("Expected unprovable dangling relation")
        } catch { XCTAssertEqual(error as? StorageTransferPartialRecoveryError, .danglingRelationship) }
        XCTAssertNil(f.store.current)
        XCTAssertEqual(f.backend.deleteCount, 0)
        let notReplacing = try await fixture(replacing: false)
        do {
            _ = try await notReplacing.coordinator.prepare(attemptID: UUID(), manifest: notReplacing.manifest)
            XCTFail("Expected wrong remote phase")
        } catch { XCTAssertEqual(error as? StorageTransferPartialRecoveryError, .wrongRecovery) }
        XCTAssertNil(notReplacing.store.current)
        XCTAssertEqual(notReplacing.backend.readCount, 0)
    }

    func testEvenNewValidSubsetRowsOrChangedTokenStopAnExistingAttempt() async throws {
        for changeRows in [true, false] {
            let f = try await fixture()
            let attempt = UUID()
            let plan = try await f.coordinator.prepare(attemptID: attempt, manifest: f.manifest)
            f.backend.current = try observation(changeRows ? rawRows(f.original) : rawRows(f.original).filter {
                $0.entity == "Subject" || $0.entity == "StudySession"
            }, token: changeRows ? Data([1]) : Data([2]))
            do {
                _ = try await f.coordinator.resume(attemptID: attempt, manifest: f.manifest)
                XCTFail("Expected fixed observation mismatch")
            } catch { XCTAssertEqual(error as? StorageTransferPartialRecoveryError, .changedObservation) }
            XCTAssertEqual(f.backend.deleteCount, 0)
            XCTAssertEqual(f.store.current, plan)
        }
    }

    func testIndeterminateDeleteRetainsIntentAndUsesAbsenceReadOnRetry() async throws {
        let f = try await fixture()
        let attempt = UUID()
        _ = try await f.coordinator.prepare(attemptID: attempt, manifest: f.manifest)
        f.backend.loseAcknowledgment = true
        do {
            _ = try await f.coordinator.resume(attemptID: attempt, manifest: f.manifest)
            XCTFail("Expected lost response")
        } catch { XCTAssertEqual(error as? PartialRecoveryDestinationFake.Failure, .transport) }
        XCTAssertEqual(f.store.current?.phase, .deletionIntentRecorded)
        _ = try await f.coordinator.resume(attemptID: attempt, manifest: f.manifest)
        XCTAssertEqual(f.store.current?.phase, .absenceVerified)
        XCTAssertEqual(f.backend.deleteCount, 1)
    }

    func testCompletedAttemptCannotDeleteFreshDestinationWhenReplayed() async throws {
        let f = try await fixture()
        let attempt = UUID()
        _ = try await f.coordinator.prepare(attemptID: attempt, manifest: f.manifest)
        _ = try await f.coordinator.resume(attemptID: attempt, manifest: f.manifest)
        f.backend.current = try observation(rawRows(f.original), token: Data([3]))
        do {
            _ = try await f.coordinator.resume(attemptID: attempt, manifest: f.manifest)
            XCTFail("Expected destination already started")
        } catch { XCTAssertEqual(error as? StorageTransferPartialRecoveryError, .destinationAlreadyStarted) }
        XCTAssertEqual(f.backend.deleteCount, 1)
    }

    func testAccountOrRecoveryControlChangeAfterDeleteCannotPublishDestination() async throws {
        let f = try await fixture()
        let attempt = UUID()
        _ = try await f.coordinator.prepare(attemptID: attempt, manifest: f.manifest)
        f.backend.beforeDelete = { f.remote.account = String(repeating: "b", count: 64) }
        do {
            _ = try await f.coordinator.resume(attemptID: attempt, manifest: f.manifest)
            XCTFail("Expected account changed")
        } catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .identityMismatch) }
        XCTAssertEqual(f.store.current?.phase, .deletionIntentRecorded)
        XCTAssertEqual(f.backend.deleteCount, 1)
    }

    func testHeldDeleteCanArriveAfterAnotherExecutorCommitsRequiringReleaseContainment() async throws {
        let f = try await fixture()
        // The first executor has finished exporting exactly the chosen graph.
        // A second installation can currently regard that full graph as a
        // valid partial-recovery subset of the same transaction's backup.
        f.backend.current = try observation(rawRows(f.original))
        let attempt = UUID()
        _ = try await f.coordinator.prepare(attemptID: attempt, manifest: f.manifest)
        let gate = PartialRecoveryHeldDelete(started: expectation(description: "second executor submitted delete"))
        f.backend.waitBeforeDelete = { await gate.wait() }
        let deleting = Task { try await f.coordinator.resume(attemptID: attempt, manifest: f.manifest) }
        defer { gate.release(); deleting.cancel() }
        await fulfillment(of: [gate.started], timeout: 3)

        let firstExecutor = StorageTransferRemoteRecovery(backend: f.remote, validateAccess: {})
        XCTAssertEqual(f.backend.current.rows.count, rawRows(f.original).count)
        _ = try await firstExecutor.commitReplacement(manifest: f.manifest,
            verifiedDestinationSHA256: f.manifest.payloadSHA256)
        XCTAssertEqual(f.remote.control?.control.phase, .committed)
        gate.release()
        do {
            _ = try await deleting.value
            XCTFail("The second executor must detect the stale control after its delayed operation")
        } catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .staleControl) }

        // This intentionally documents the unprotected low-level algorithm,
        // using only memory fakes. The post-await rejection cannot undo the
        // delete. Re-enabling the ordinary runtime without resolving this race
        // must fail this containment regression, not imply all-device safety.
        XCTAssertTrue(f.backend.current.confirmsAbsence)
        XCTAssertEqual(f.backend.deleteCount, 1)
        XCTAssertEqual(f.remote.control?.control.phase, .committed)
        XCTAssertFalse(StorageTransferReleasePolicy.standard.allowsCloudReplacement)
    }

    func testQuiescenceFailureAndUnacknowledgedIntentPreventDestructiveCall() async throws {
        let f = try await fixture()
        let attempt = UUID()
        _ = try await f.coordinator.prepare(attemptID: attempt, manifest: f.manifest)
        f.store.discardIntent = true
        do {
            _ = try await f.coordinator.resume(attemptID: attempt, manifest: f.manifest)
            XCTFail("Expected unacknowledged intent")
        } catch { XCTAssertEqual(error as? StorageTransferPartialRecoveryError, .stalePlan) }
        XCTAssertEqual(f.backend.deleteCount, 0)
        let invalid = StorageTransferPartialDestinationRecovery(store: f.store, backend: f.backend,
            recovery: f.recovery, validateGenerationAndQuiescence: { throw StorageTransferPartialRecoveryError.stalePlan })
        do {
            _ = try await invalid.resume(attemptID: attempt, manifest: f.manifest)
            XCTFail("Expected non-quiescent process")
        } catch { XCTAssertEqual(error as? StorageTransferPartialRecoveryError, .stalePlan) }
        XCTAssertEqual(f.backend.deleteCount, 0)
    }
}

@MainActor
private final class PartialRecoveryPlanFake: StorageTransferPartialDestinationPlanStore {
    var current: StorageTransferPartialDestinationPlan?
    var phases: [StorageTransferPartialDestinationPlan.Phase] = []
    var discardIntent = false
    func load() throws -> StorageTransferPartialDestinationPlan? { current }
    func save(_ plan: StorageTransferPartialDestinationPlan, replacing previous: StorageTransferPartialDestinationPlan?) throws {
        guard current == previous else { throw StorageTransferPartialRecoveryError.stalePlan }
        try plan.validate()
        if let previous {
            guard plan.attemptID == previous.attemptID, plan.transactionID == previous.transactionID,
                  plan.accountFingerprint == previous.accountFingerprint, plan.sourcePayloadSHA256 == previous.sourcePayloadSHA256,
                  plan.observedSHA256 == previous.observedSHA256, plan.zone == previous.zone,
                  plan.terminalToken == previous.terminalToken, plan.revision == previous.revision + 1 else {
                throw StorageTransferPartialRecoveryError.stalePlan
            }
        }
        if !(discardIntent && plan.phase == .deletionIntentRecorded) { current = plan }
        phases.append(plan.phase)
    }
}

@MainActor
private final class PartialRecoveryDestinationFake: StorageTransferPartialDestinationBackend {
    enum Failure: Error, Equatable { case transport }
    var current: StorageTransferPartialDestinationObservation
    let absent: StorageTransferPartialDestinationObservation
    var readCount = 0
    var deleteCount = 0
    var loseAcknowledgment = false
    var beforeDelete: (() -> Void)?
    var waitBeforeDelete: (() async -> Void)?
    init(current: StorageTransferPartialDestinationObservation, absent: StorageTransferPartialDestinationObservation) {
        self.current = current
        self.absent = absent
    }
    func readRawDestination() async throws -> StorageTransferPartialDestinationObservation { readCount += 1; return current }
    func deleteZone(_ id: StorageTransferManagedZoneID) async throws -> StorageTransferManagedZoneDeleteAcknowledgment {
        try id.validate()
        beforeDelete?()
        await waitBeforeDelete?()
        deleteCount += 1
        current = absent
        if loseAcknowledgment { loseAcknowledgment = false; throw Failure.transport }
        return .deleted(id)
    }
}

@MainActor
private final class PartialRecoveryHeldDelete {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    init(started: XCTestExpectation) { self.started = started }

    func wait() async {
        guard !isReleased else { started.fulfill(); return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func release() {
        isReleased = true
        let held = continuation
        continuation = nil
        held?.resume()
    }
}

@MainActor
private final class PartialRecoveryRemoteFake: StorageTransferRecoveryBackend {
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
        let result = StorageTransferRecoveryEnvelope(control: value, changeTag: "synthetic-version-\(version)")
        control = result
        return result
    }
    func readChunk(manifest: StorageTransferRecoveryManifest, index: Int) async throws -> StorageTransferRecoveryChunk? {
        chunks["chunk-\(manifest.transactionID.uuidString.lowercased())-\(index)"]
    }
    func saveChunkIfAbsent(_ chunk: StorageTransferRecoveryChunk) async throws {
        if let prior = chunks[chunk.recordName], prior != chunk { throw StorageTransferRecoveryError.corruptChunk }
        chunks[chunk.recordName] = chunk
    }
    func retainTerminalReceipt(_ control: StorageTransferRecoveryControl) async throws {
        guard control.isTerminal else { throw StorageTransferRecoveryError.invalidControl }
        receipts[control.manifest.transactionID] = control
    }
    func readTerminalReceipt(transactionID: UUID) async throws -> StorageTransferRecoveryControl? { receipts[transactionID] }
    func deleteChunkIfMatches(_ chunk: StorageTransferRecoveryChunk,
                              terminalReceipt: StorageTransferRecoveryControl) async throws {
        guard terminalReceipt.isTerminal, receipts[terminalReceipt.manifest.transactionID] == terminalReceipt,
              chunks[chunk.recordName] == chunk else { throw StorageTransferRecoveryError.staleControl }
        chunks.removeValue(forKey: chunk.recordName)
    }
}
