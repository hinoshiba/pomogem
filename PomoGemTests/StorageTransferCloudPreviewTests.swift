import Foundation
import SwiftData
import XCTest
@testable import PomoGem

/// PLAN Step 6 — the read-only pre-flight that has to succeed before anybody
/// may authorize destroying the iCloud dataset (safety statement S14). Every
/// test here proves the preview observes and never mutates.
@MainActor
final class StorageTransferCloudPreviewTests: XCTestCase {
    private let fingerprint = String(repeating: "b", count: 64)
    private let localDeviceID = "11111111-1111-1111-1111-111111111111"

    // MARK: - Fixtures

    private func record(_ entity: String, _ fields: [String: PomoGemStorageSnapshot.Scalar]) -> PomoGemStorageSnapshot.Record {
        PomoGemStorageSnapshot.Record(reference: 0, entity: entity, fields: fields, relationships: [:])
    }

    private func snapshot(_ records: [PomoGemStorageSnapshot.Record]) -> PomoGemStorageSnapshot {
        var numbered: [PomoGemStorageSnapshot.Record] = []
        for (index, row) in records.enumerated() {
            numbered.append(PomoGemStorageSnapshot.Record(reference: index, entity: row.entity,
                                                          fields: row.fields, relationships: row.relationships))
        }
        return PomoGemStorageSnapshot(records: numbered)
    }

    private func claim(_ deviceID: String) -> PomoGemStorageSnapshot.Record {
        record("FocusTimerDeviceClaim", ["deviceID": .string(deviceID)])
    }

    private func marker(_ writerDeviceID: String) -> PomoGemStorageSnapshot.Record {
        record("ActivityResetMarker", ["writerDeviceID": .string(writerDeviceID)])
    }

    private func date(_ value: Date) -> PomoGemStorageSnapshot.Scalar {
        .dateBits(value.timeIntervalSinceReferenceDate.bitPattern)
    }

    private func fixture() throws -> (URL, StorageTransferJournalStore, StorageTransferRuntime, ActiveAccountLocalBinding) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("TransferCloudPreview-\(UUID())", isDirectory: true)
        // The runtime's cancellation/cleanup workers require the exact feature
        // root name; a random root would fail path validation first.
        let root = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let store = StorageTransferJournalStore(directory: root)
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: fingerprint))
        return (root, store, StorageTransferRuntime(store: store, root: root), binding)
    }

    // MARK: - Writer evidence

    func testCountsEveryDistinctOtherWriterAcrossBothModelsExactlyOnce() {
        let preview = StorageTransferCloudPreview.make(snapshot: snapshot([
            claim("device-a"), claim("device-a"), marker("device-a"),
            marker("device-b"), claim("device-b"),
            marker("device-c")
        ]), localDeviceID: localDeviceID)
        XCTAssertEqual(preview.otherDeviceIDs, 3)
        XCTAssertEqual(preview.ignoredWriterIDs, 0)
    }

    func testExcludesThisDeviceAndEmptyOrBlankWriterIdentifiers() {
        let preview = StorageTransferCloudPreview.make(snapshot: snapshot([
            claim(localDeviceID), marker(localDeviceID),
            claim(localDeviceID.uppercased()), marker("  \(localDeviceID)  "),
            claim(""), marker("   "),
            marker("device-b")
        ]), localDeviceID: localDeviceID)
        XCTAssertEqual(preview.otherDeviceIDs, 1)
    }

    /// INVESTIGATION-STATE L2: this repository's own audits left
    /// `writerDeviceID == "audit-synthetic"` in LIVE device state. Counting it
    /// would tell a genuinely single-device phone that another device exists.
    func testIgnoresTheRepositorysOwnSyntheticAuditWriterIdentifiers() {
        for ignored in StorageTransferCloudPreviewPolicy.ignoredWriterIDs {
            let preview = StorageTransferCloudPreview.make(snapshot: snapshot([
                marker(ignored), claim(ignored.uppercased()), claim(localDeviceID)
            ]), localDeviceID: localDeviceID)
            XCTAssertEqual(preview.otherDeviceIDs, 0, ignored)
            XCTAssertEqual(preview.ignoredWriterIDs, 1, ignored)
        }
        XCTAssertTrue(StorageTransferCloudPreviewPolicy.ignoredWriterIDs.contains("audit-synthetic"))
    }

    func testOnlyTheTwoDocumentedWriterFieldsAreCounted() {
        // SyncedFocusTimer.writerDeviceID is deliberately NOT a witness: a
        // timer row is rewritten by whichever device owns it.
        let preview = StorageTransferCloudPreview.make(snapshot: snapshot([
            record("SyncedFocusTimer", ["writerDeviceID": .string("device-z")]),
            record("Prefs", ["settingsWriterID": .string("device-y")])
        ]), localDeviceID: localDeviceID)
        XCTAssertEqual(preview.otherDeviceIDs, 0)
        XCTAssertEqual(StorageTransferCloudPreview.witnessFields, [
            "ActivityResetMarker": "writerDeviceID", "FocusTimerDeviceClaim": "deviceID"
        ])
    }

    func testANonStringOrAbsentWriterFieldIsNeverCountedAsAWitness() {
        let preview = StorageTransferCloudPreview.make(snapshot: snapshot([
            record("FocusTimerDeviceClaim", ["deviceID": .null]),
            record("FocusTimerDeviceClaim", ["sequence": .integer(1)]),
            record("ActivityResetMarker", ["writerDeviceID": .integer(7)])
        ]), localDeviceID: localDeviceID)
        XCTAssertEqual(preview.otherDeviceIDs, 0)
    }

    // MARK: - Counts and dates

    func testReportsEveryMirroredModelIncludingAbsentOnesAndNoLocalOnlyModel() {
        let preview = StorageTransferCloudPreview.make(snapshot: snapshot([
            record("Subject", [:]), record("Subject", [:]), record("StudySession", [:])
        ]), localDeviceID: localDeviceID)
        XCTAssertEqual(Set(preview.recordCounts.keys), PomoGemStorageSnapshot.cloudModelNames)
        XCTAssertEqual(preview.recordCounts["Subject"], 2)
        XCTAssertEqual(preview.recordCounts["StudySession"], 1)
        XCTAssertEqual(preview.recordCounts["AchievementStone"], 0)
        XCTAssertNil(preview.recordCounts["AggregatePebble"])
    }

    func testLatestRecordDateIsTheNewestDatedFieldAndNilWhenTheDatasetIsUndated() {
        let older = Date(timeIntervalSinceReferenceDate: 1_000)
        let newer = Date(timeIntervalSinceReferenceDate: 9_000)
        let preview = StorageTransferCloudPreview.make(snapshot: snapshot([
            record("StudySession", ["endAt": date(older), "startAt": date(newer)]),
            record("Subject", ["createdAt": date(older)])
        ]), localDeviceID: localDeviceID)
        XCTAssertEqual(preview.latestRecordAt, newer)
        XCTAssertNil(StorageTransferCloudPreview.make(snapshot: snapshot([record("Subject", [:])]),
                                                      localDeviceID: localDeviceID).latestRecordAt)
        XCTAssertNil(StorageTransferCloudPreview.make(snapshot: snapshot([]), localDeviceID: localDeviceID).latestRecordAt)
    }

    /// review-1-2 / review-2-1. The iCloud side of the comparison can only
    /// ever contain the 7 mirrored models; the device side is captured from
    /// BOTH stores and therefore also holds the four local-only projection
    /// models, whose timestamps (`Stratum.bakedAt`, `Bedrock.importedAt`,
    /// `AggregatePebble.createdAt/periodStart/periodEnd`) are rewritten
    /// whenever the projection is rebuilt — effectively "now". Deriving
    /// 「最終」 from them would render a stale device as the newer side on the
    /// one screen where an irreversible deletion is chosen.
    func testLatestRecordDateIgnoresLocalOnlyModelsTheServerCanNeverHold() {
        let mirrored = Date(timeIntervalSinceReferenceDate: 1_000)
        let localOnly = Date(timeIntervalSinceReferenceDate: 9_000)
        let preview = StorageTransferCloudPreview.make(snapshot: snapshot([
            record("StudySession", ["endAt": date(mirrored)]),
            record("Stratum", ["bakedAt": date(localOnly)]),
            record("Bedrock", ["importedAt": date(localOnly)]),
            record("AggregatePebble", ["createdAt": date(localOnly),
                                       "periodStart": date(localOnly),
                                       "periodEnd": date(localOnly)]),
            record("GachaState", ["updatedAt": date(localOnly)])
        ]), localDeviceID: localDeviceID)
        XCTAssertEqual(preview.latestRecordAt, mirrored,
            "Both sides of the comparison must be reduced over the same mirrored models")
        for name in ["Stratum", "Bedrock", "AggregatePebble", "GachaState"] {
            XCTAssertFalse(PomoGemStorageSnapshot.cloudModelNames.contains(name), name)
        }
    }

    /// review-3-5. `AggregatePebble.periodEnd` is the END of the covered
    /// period and `SyncedFocusTimer.scheduledEndAt` is a future deadline, so a
    /// raw maximum is not a 「最終記録」 at all. A timestamp the clock has not
    /// reached cannot be evidence about which dataset is newer.
    func testLatestRecordDateIgnoresTimestampsInTheFuture() {
        let now = Date(timeIntervalSinceReferenceDate: 5_000)
        let past = Date(timeIntervalSinceReferenceDate: 4_000)
        let future = Date(timeIntervalSinceReferenceDate: 90_000)
        let preview = StorageTransferCloudPreview.make(snapshot: snapshot([
            record("StudySession", ["endAt": date(past)]),
            record("SyncedFocusTimer", ["scheduledEndAt": date(future)])
        ]), localDeviceID: localDeviceID, now: now)
        XCTAssertEqual(preview.latestRecordAt, past)
        // Exactly `now` is not in the future and stays eligible.
        XCTAssertEqual(StorageTransferCloudPreview.make(snapshot: snapshot([
            record("StudySession", ["endAt": date(now)])
        ]), localDeviceID: localDeviceID, now: now).latestRecordAt, now)
    }

    func testANonFiniteDateIsIgnoredInsteadOfBecomingTheLatestRecordDate() {
        let real = Date(timeIntervalSinceReferenceDate: 5_000)
        let preview = StorageTransferCloudPreview.make(snapshot: snapshot([
            record("Subject", ["createdAt": .dateBits(Double.infinity.bitPattern),
                               "deletedAt": .dateBits(Double.nan.bitPattern)]),
            record("Subject", ["createdAt": date(real)])
        ]), localDeviceID: localDeviceID)
        XCTAssertEqual(preview.latestRecordAt, real)
    }

    // MARK: - The runtime entry point

    // MARK: - The device side, read straight from a context

    /// The device side of a comparison is no longer a full snapshot (every
    /// field and relationship of all eleven entities): it walks the mirrored
    /// models' scalar fields once. It must still reduce to EXACTLY what the
    /// snapshot path reduces to — counts, the newest non-future date, other
    /// writers — or the two rows a deletion is chosen from drift apart.
    /// Local-only rows stamped "now" must stay out of both.
    func testTheDirectDeviceReadReducesExactlyAsTheSnapshotPathDoes() throws {
        let schema = PersistenceStoreTopology.shippingSchema
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(
            "CloudPreviewDirectRead-\(UUID())", schema: schema,
            isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = container.mainContext
        context.autosaveEnabled = false
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let sessions = 2_000
        let subject = Subject(name: "数学", colorHex: "blue", sortOrder: 0, createdAt: base)
        context.insert(subject)
        for index in 0..<sessions {
            let start = base.addingTimeInterval(Double(index) * 3_600)
            context.insert(StudySession(subject: subject, startAt: start, endAt: start.addingTimeInterval(1_500),
                                        seconds: 1_500, source: .timer, deviceDayKey: "day-\(index)"))
        }
        context.insert(AchievementStone(subject: subject, kind: .examPass, note: "note",
                                        achievedAt: base, createdAt: base))
        context.insert(Prefs(keepScreenAwake: false, hasCompletedOnboarding: true, settingsWriterID: "writer-a"))
        context.insert(ActivityResetMarker(sequence: 1, resetAt: base,
                                           writerDeviceID: "22222222-2222-2222-2222-222222222222"))
        context.insert(FocusTimerDeviceClaim(sessionID: UUID(), deviceID: localDeviceID, sequence: 1,
                                             claimedAt: base, releasedAt: base))
        let now = base.addingTimeInterval(Double(sessions + 24) * 3_600)
        context.insert(AggregatePebble(level: 1, pebbleCount: 1, grams: 250, colorMixJSON: "[]",
                                       periodStart: now, periodEnd: now))
        context.insert(Bedrock(hours: 1, importedAt: now))
        try context.save()

        var started = Date()
        let viaSnapshot = StorageTransferCloudPreview.make(
            snapshot: try PomoGemStorageSnapshot.capture(from: ModelContext(container)),
            localDeviceID: localDeviceID, now: now)
        let snapshotSeconds = Date().timeIntervalSince(started)
        started = Date()
        let direct = try StorageTransferCloudPreview.make(context: ModelContext(container),
                                                          localDeviceID: localDeviceID, now: now)
        let directSeconds = Date().timeIntervalSince(started)

        XCTAssertEqual(direct, viaSnapshot)
        XCTAssertEqual(direct.recordCounts["StudySession"], sessions)
        XCTAssertEqual(direct.recordCounts["Subject"], 1)
        XCTAssertNil(direct.recordCounts["AggregatePebble"], "Local-only models are never counted")
        XCTAssertEqual(direct.otherDeviceIDs, 1)
        XCTAssertEqual(direct.latestRecordAt,
                       base.addingTimeInterval(Double(sessions - 1) * 3_600 + 1_500),
                       "The newest mirrored date, not a local-only row stamped at `now`")
        // Evidence for the review, not a gate: timings vary by host.
        print("device-preview rows=\(sessions) snapshot=\(snapshotSeconds)s direct=\(directSeconds)s")
    }

    func testPreviewReadsOnceAndCreatesNoJournalCheckpointOrDirectoryEntry() async throws {
        let (root, store, runtime, _) = try fixture()
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        var reads = 0
        let preview = try await runtime.previewCloudDataset(localDeviceID: localDeviceID,
            readSnapshot: {
                reads += 1
                return self.snapshot([self.claim("device-b"), self.record("Subject", [:])])
            }, validateAccess: {})
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(preview.otherDeviceIDs, 1)
        XCTAssertEqual(preview.recordCounts["Subject"], 1)
        XCTAssertNil(try store.load())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
    }

    func testPreviewSurfacesAReadFailureInsteadOfSwallowingIt() async throws {
        let (root, store, runtime, _) = try fixture()
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        do {
            _ = try await runtime.previewCloudDataset(localDeviceID: localDeviceID,
                readSnapshot: { throw CloudStorageTransferCloudError.timedOut }, validateAccess: {})
            XCTFail("A failed pre-flight read must never be reported as an empty dataset")
        } catch {
            XCTAssertEqual(error as? CloudStorageTransferCloudError, .timedOut)
        }
        XCTAssertNil(try store.load())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
    }

    func testPreviewRefusesBeforeReadingWhenAccessValidationFails() async throws {
        let (_, _, runtime, _) = try fixture()
        var reads = 0
        do {
            _ = try await runtime.previewCloudDataset(localDeviceID: localDeviceID,
                readSnapshot: { reads += 1; return self.snapshot([]) },
                validateAccess: { throw StorageTransferError.staleTransaction })
            XCTFail("The caller's access gate must be honoured before any server read")
        } catch {
            XCTAssertEqual(error as? StorageTransferError, .staleTransaction)
        }
        XCTAssertEqual(reads, 0)
    }

    func testPreviewTimeoutIsBoundedWellBelowTheVerificationRead() {
        XCTAssertGreaterThan(StorageTransferCloudPreviewPolicy.timeout, 0)
        XCTAssertLessThan(StorageTransferCloudPreviewPolicy.timeout, CloudStorageTransferCloudKit.defaultTimeout)
    }
}
