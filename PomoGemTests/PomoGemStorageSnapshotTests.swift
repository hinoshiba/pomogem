import Foundation
import SwiftData
import XCTest
@testable import PomoGem

@MainActor
final class PomoGemStorageSnapshotTests: XCTestCase {
    private func container() throws -> ModelContainer {
        let schema = PersistenceStoreTopology.shippingSchema
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(
            "StorageSnapshotTests-\(UUID())", schema: schema,
            isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )])
    }

    private func fixture() throws -> ModelContainer {
        let container = try container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let date = Date(timeIntervalSince1970: 1_700_000_000.125)
        let logicalID = UUID()
        let physicalID = UUID()
        let first = Subject(id: logicalID, name: "first physical copy", colorHex: "blue", sortOrder: 0,
                            deletedAt: date, syncRecordID: physicalID)
        let second = Subject(id: logicalID, name: "second physical copy", colorHex: "red", sortOrder: 1,
                             syncRecordID: physicalID)
        context.insert(first)
        context.insert(second)
        let sessionID = UUID()
        let sessionPhysicalID = UUID()
        context.insert(StudySession(id: sessionID, subject: first, startAt: date, endAt: date,
                                    seconds: 1_800, source: .manual, deviceDayKey: "day",
                                    syncRecordID: sessionPhysicalID))
        context.insert(StudySession(id: sessionID, subject: second, startAt: date, endAt: date,
                                    seconds: 1_500, source: .timer, deviceDayKey: "day",
                                    syncRecordID: sessionPhysicalID))
        context.insert(AchievementStone(subject: second, kind: .examPass, note: "evidence", achievedAt: date))
        context.insert(Prefs(keepScreenAwake: false, hasCompletedOnboarding: true, settingsWriterID: "writer-a"))
        context.insert(ActivityResetMarker(sequence: 2, resetAt: date, writerDeviceID: "writer-a"))
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        let timerID = UUID()
        try engine.startFocus(isPro: false, now: date, sessionID: timerID)
        let payload = try FocusCloudPayload(envelope: FocusRecoveryEnvelope(
            engine: engine, subject: FocusSubjectSnapshot(subject: first), clockAnchor: nil,
            pendingCompletion: nil, savedAt: date
        ))
        let timer = try SyncedFocusTimer(sessionID: timerID, status: .running, payload: payload,
                                        updatedAt: date, writerDeviceID: "writer-a")
        timer.statusRaw = "unrecognized-future-status"
        timer.payloadData = Data([0xff, 0x00, 0x81])
        context.insert(timer)
        context.insert(FocusTimerDeviceClaim(sessionID: timerID, deviceID: "writer-a", sequence: 3,
                                             claimedAt: date, releasedAt: date))
        let aggregate = AggregatePebble(level: 2, pebbleCount: 2, grams: 550, colorMixJSON: "[]",
                                         periodStart: date, periodEnd: date)
        aggregate.sessionIDsJSON = "unrecognized retained JSON"
        context.insert(aggregate)
        context.insert(Stratum(pebbleCount: 1, heightPt: 20, colorMixJSON: "[]", monthLabel: "legacy"))
        context.insert(Bedrock(hours: 10, importedAt: date))
        context.insert(GachaState(sinceLastGold: 4, rewardCreditGrams: 321))
        try context.save()
        return container
    }

    func testAllElevenEntitiesAndDuplicatePhysicalRelationshipsSurviveFreshReader() throws {
        let source = try fixture()
        let snapshot = try PomoGemStorageSnapshot.capture(from: ModelContext(source))
        XCTAssertEqual(Set(snapshot.records.map(\.entity)), Set(PomoGemStorageSnapshot.modelNames))
        let target = try container()
        let receipt = try snapshot.importIntoEmpty(target.mainContext)
        let reopened = try PomoGemStorageSnapshot.capture(from: ModelContext(target))
        XCTAssertTrue(try snapshot.isEquivalent(to: reopened))
        XCTAssertEqual(receipt.recordCounts, snapshot.recordCounts)
        let children = try ModelContext(target).fetch(FetchDescriptor<StudySession>())
        XCTAssertEqual(Set(children.compactMap { $0.subject?.name }), ["first physical copy", "second physical copy"])
        XCTAssertEqual(Set(children.map(\.id)).count, 1)
        XCTAssertEqual(Set(children.map(\.syncRecordID)).count, 1)
        XCTAssertEqual(Set(children.compactMap { $0.subject?.persistentModelID }).count, 2)
        XCTAssertFalse(target.mainContext.hasChanges)
        let sourceAgain = try PomoGemStorageSnapshot.capture(from: ModelContext(source))
        XCTAssertTrue(try snapshot.isEquivalent(to: sourceAgain))
    }

    func testEveryRawFieldOverridesConstructorSanitizationAndQuarantineIsRetained() throws {
        let source = try fixture()
        var snapshot = try PomoGemStorageSnapshot.capture(from: ModelContext(source))
        let descriptors = PomoGemStorageSnapshot.fieldDescriptors
        var tested = Set<String>()
        for index in snapshot.records.indices {
            let entity = snapshot.records[index].entity
            for field in try XCTUnwrap(descriptors[entity]) {
                let value: PomoGemStorageSnapshot.Scalar
                switch field.kind {
                case .string:
                    switch (entity, field.name) {
                    case ("StudySession", "source"): value = .string(SessionSource.timerDemoted.rawValue)
                    case ("StudySession", "pebbleKind"): value = .string(PebbleKind.prism.rawValue)
                    case ("AchievementStone", "kind"): value = .string(AchievementKind.workMilestone.rawValue)
                    default: value = .string("  \nretained unknown \(field.name)\t  ")
                    }
                case .integer: value = .integer(-99)
                case .boolean: value = .boolean(true)
                case .double: value = .doubleBits((-123.625).bitPattern)
                case .date: value = .dateBits(9_000_000_000.125.bitPattern)
                case .uuid: value = .uuid(UUID())
                case .data: value = .data(Data([0x00, 0xff, 0x81, 0x20]))
                }
                snapshot.records[index].fields[field.name] = value
                tested.insert("\(entity).\(field.name)")
            }
        }
        XCTAssertEqual(tested.count, descriptors.values.reduce(0) { $0 + $1.count })
        let target = try container()
        _ = try snapshot.importIntoEmpty(target.mainContext)
        let readback = try PomoGemStorageSnapshot.capture(from: ModelContext(target))
        XCTAssertTrue(try snapshot.isEquivalent(to: readback))
        let rawPrefs = try XCTUnwrap(ModelContext(target).fetch(FetchDescriptor<Prefs>()).first)
        XCTAssertTrue(rawPrefs.isPro, "Retain legacy raw evidence; StoreKit remains the entitlement authority")
        XCTAssertEqual(rawPrefs.keepScreenAwakeRevision, -99)
        let rawTimer = try XCTUnwrap(ModelContext(target).fetch(FetchDescriptor<SyncedFocusTimer>()).first)
        XCTAssertEqual(rawTimer.payloadData, Data([0x00, 0xff, 0x81, 0x20]))
        XCTAssertThrowsError(try rawTimer.decodedPayload(), "Transfer must preserve, not silently repair, quarantined payloads")
    }

    func testAllOptionalScalarsPreserveNilAndEmptyRelationships() throws {
        let source = try fixture()
        var snapshot = try PomoGemStorageSnapshot.capture(from: ModelContext(source))
        for index in snapshot.records.indices {
            for descriptor in PomoGemStorageSnapshot.fieldDescriptors[snapshot.records[index].entity, default: []]
            where descriptor.isOptional {
                snapshot.records[index].fields[descriptor.name] = .null
            }
        }
        let target = try container()
        _ = try snapshot.importIntoEmpty(target.mainContext)
        XCTAssertTrue(try snapshot.isEquivalent(to: PomoGemStorageSnapshot.capture(from: ModelContext(target))))
    }

    func testEmptySnapshotClonesWithoutBootstrappingPreferencesOrSubjects() throws {
        let source = try container()
        let target = try container()
        let receipt = try PomoGemStorageSnapshot.clone(from: source.mainContext, intoEmpty: target.mainContext)
        XCTAssertTrue(receipt.recordCounts.values.allSatisfy { $0 == 0 })
        XCTAssertFalse(target.mainContext.hasChanges)
    }

    func testDestinationMustBeEmptyEvenWhenOnlyProjectionContainsData() throws {
        let source = try fixture()
        let snapshot = try PomoGemStorageSnapshot.capture(from: ModelContext(source))
        let target = try container()
        target.mainContext.insert(Bedrock(hours: 5))
        try target.mainContext.save()
        XCTAssertThrowsError(try snapshot.importIntoEmpty(target.mainContext)) { error in
            XCTAssertEqual(error as? PomoGemStorageSnapshot.Failure, .destinationNotEmpty)
        }
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<Bedrock>()), 1)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<Subject>()), 0)
    }

    func testDirtySourceRefusedWithoutSavingOrRollingBackUserChanges() throws {
        let source = try container()
        source.mainContext.autosaveEnabled = false
        source.mainContext.insert(Prefs())
        XCTAssertThrowsError(try PomoGemStorageSnapshot.capture(from: source.mainContext)) { error in
            XCTAssertEqual(error as? PomoGemStorageSnapshot.Failure, .dirtySource)
        }
        XCTAssertTrue(source.mainContext.hasChanges)
    }

    func testUnknownMissingAndWrongTypedFieldsFailBeforeAnyInsertion() throws {
        let source = try fixture()
        let original = try PomoGemStorageSnapshot.capture(from: ModelContext(source))
        for mutation in 0...2 {
            var value = original
            if mutation == 0 { value.records[0].fields["newFutureAttribute"] = .integer(1) }
            if mutation == 1 { value.records[0].fields.removeValue(forKey: "id") }
            if mutation == 2 { value.records[0].fields["id"] = .string("not a UUID") }
            let target = try container()
            XCTAssertThrowsError(try value.importIntoEmpty(target.mainContext))
            XCTAssertFalse(target.mainContext.hasChanges)
            XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<Subject>()), 0)
        }
    }

    func testBrokenOrRewiredPhysicalRelationshipsAreNotEquivalent() throws {
        let source = try fixture()
        let original = try PomoGemStorageSnapshot.capture(from: ModelContext(source))
        var missing = original
        let child = try XCTUnwrap(missing.records.firstIndex { $0.entity == "StudySession" })
        missing.records[child].relationships["subject"] = .toOne(99_999)
        XCTAssertThrowsError(try missing.validate())

        var changed = original
        let subjects = changed.records.indices.filter { changed.records[$0].entity == "Subject" }
        let first = try XCTUnwrap(subjects.first)
        changed.records[first].fields["name"] = .string("different physical parent")
        XCTAssertFalse(try original.isEquivalent(to: changed))

        var reordered = original
        reordered.records.reverse()
        XCTAssertTrue(try original.isEquivalent(to: reordered))
    }

    func testDuplicateRowsCannotDisappearBehindEqualLogicalOrPhysicalIDs() throws {
        let source = try fixture()
        let original = try PomoGemStorageSnapshot.capture(from: ModelContext(source))
        var lost = original
        let index = try XCTUnwrap(lost.records.firstIndex { $0.entity == "GachaState" })
        var duplicate = lost.records[index]
        duplicate = .init(reference: 99_999, entity: duplicate.entity,
                          fields: duplicate.fields, relationships: duplicate.relationships)
        lost.records.append(duplicate)
        XCTAssertFalse(try original.isEquivalent(to: lost))
    }

    func testRowValueAndFileBudgetsRejectWithoutPartialTargetWrites() throws {
        let source = try fixture()
        let snapshot = try PomoGemStorageSnapshot.capture(from: ModelContext(source))
        var rowLimit = PomoGemStorageSnapshot.Limits.standard
        rowLimit.maximumRecords = 1
        XCTAssertThrowsError(try PomoGemStorageSnapshot.capture(from: ModelContext(source), limits: rowLimit))
        let target = try container()
        var valueLimit = PomoGemStorageSnapshot.Limits.standard
        valueLimit.maximumValueBytes = 20
        XCTAssertThrowsError(try snapshot.importIntoEmpty(target.mainContext, limits: valueLimit))
        XCTAssertFalse(target.mainContext.hasChanges)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<Subject>()), 0)
    }

    func testProtectedFileRoundTripRequiresExactDigestAndRejectsTampering() throws {
        let source = try fixture()
        let snapshot = try PomoGemStorageSnapshot.capture(from: ModelContext(source))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")
        let receipt = try snapshot.write(to: url)
        XCTAssertEqual(try PomoGemStorageSnapshot.read(from: url, expectedDigest: receipt.sha256), snapshot)
        var small = PomoGemStorageSnapshot.Limits.standard
        small.maximumEncodedBytes = 10
        XCTAssertThrowsError(try PomoGemStorageSnapshot.read(from: url, expectedDigest: receipt.sha256, limits: small))
        try Data("{}".utf8).write(to: url)
        XCTAssertThrowsError(try PomoGemStorageSnapshot.read(from: url, expectedDigest: receipt.sha256)) { error in
            XCTAssertEqual(error as? PomoGemStorageSnapshot.Failure, .digestMismatch)
        }
    }

    func testRuntimeSchemaRejectsMissingOrAdditionalEntities() throws {
        XCTAssertNoThrow(try PomoGemStorageSnapshot.validateSchema(PersistenceStoreTopology.shippingSchema))
        XCTAssertThrowsError(try PomoGemStorageSnapshot.validateSchema(PersistenceStoreTopology.cloudSchema))
        let extra = Schema([Subject.self, StudySession.self, AchievementStone.self, Prefs.self,
                            ActivityResetMarker.self, SyncedFocusTimer.self, FocusTimerDeviceClaim.self,
                            AggregatePebble.self, Stratum.self, Bedrock.self, GachaState.self,
                            RareRewardPendingCommit.self])
        XCTAssertThrowsError(try PomoGemStorageSnapshot.validateSchema(extra))
    }

    func testGraphComparisonRenumbersReferencesAndIgnoresOnlyRequestedProjection() throws {
        let source = try fixture()
        let snapshot = try PomoGemStorageSnapshot.capture(from: ModelContext(source))
        let renumbered = PomoGemStorageSnapshot(records: snapshot.records.reversed().map { row in
            .init(reference: row.reference + 500, entity: row.entity, fields: row.fields,
                  relationships: row.relationships.mapValues { value in
                switch value {
                case let .toOne(id): return .toOne(id.map { $0 + 500 })
                case let .toMany(ids): return .toMany(ids.map { $0.reversed().map { $0 + 500 } })
                }
            })
        })
        XCTAssertTrue(try snapshot.isEquivalent(to: renumbered))
        let cloud = PomoGemStorageSnapshot(records: renumbered.records.filter {
            PomoGemStorageSnapshot.cloudModelNames.contains($0.entity)
        })
        XCTAssertTrue(try snapshot.isEquivalent(to: cloud, entities: PomoGemStorageSnapshot.cloudModelNames))
        XCTAssertFalse(try snapshot.isEquivalent(to: cloud))
    }

    func testTransportDateToleranceIsExplicitAndCannotHideLargeDifferences() throws {
        let source = try fixture()
        var original = try PomoGemStorageSnapshot.capture(from: ModelContext(source))
        for index in original.records.indices {
            original.records[index].fields = original.records[index].fields.mapValues {
                if case .dateBits = $0 { return .dateBits(1_000_000.0.bitPattern) }; return $0
            }
        }
        var close = original
        close.records[0].fields["createdAt"] = .dateBits(1_000_000.0001.bitPattern)
        XCTAssertFalse(try original.isEquivalent(to: close))
        XCTAssertTrue(try original.isEquivalent(to: close, dateTolerance: 0.001))
        close.records[0].fields["createdAt"] = .dateBits(1_000_000.1.bitPattern)
        XCTAssertFalse(try original.isEquivalent(to: close, dateTolerance: 0.001))
    }

    func testCancelledImportDoesNotInsertAnyTargetRow() async throws {
        let source = try fixture()
        let snapshot = try PomoGemStorageSnapshot.capture(from: ModelContext(source))
        let target = try container()
        let task = Task { @MainActor in try snapshot.importIntoEmpty(target.mainContext) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(target.mainContext.hasChanges)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<Subject>()), 0)
    }

    func testDanglingSnapshotSymlinkIsRefusedBeforeWriting() throws {
        let source = try container()
        let snapshot = try PomoGemStorageSnapshot.capture(from: source.mainContext)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: directory.appendingPathComponent("missing"))
        XCTAssertThrowsError(try snapshot.write(to: url))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType, .typeSymbolicLink)
    }
}
