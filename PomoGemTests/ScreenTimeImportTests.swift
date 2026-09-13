import Foundation
import SwiftData
import XCTest
@testable import PomoGem

@MainActor
final class ScreenTimeImportTests: XCTestCase {
    private func container() throws -> ModelContainer {
        let schema = Schema([Subject.self, StudySession.self, ActivityResetMarker.self])
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }
    private func receipt(id: UUID = UUID(), epoch: UUID? = nil, owner: String = "local", themeID: UUID? = nil) -> ScreenTimeLearningImport {
        let now = Date.now
        return .init(id: id, themeID: themeID, startedAt: now.addingTimeInterval(-1_200),
                     endedAt: now, contextKey: owner, dataEpochID: epoch)
    }
    func testTenMinuteReceiptsAreSavedOnceAcrossAcknowledgementRetry() throws {
        let store = try container()
        let values = [receipt(), receipt(), receipt()]
        let first = try ScreenTimeImportCoordinator.insert(values, container: store, contextKey: "local", dataEpochID: nil)
        XCTAssertEqual(first.count, 3)
        XCTAssertTrue(try ScreenTimeImportCoordinator.insert(values, container: store, contextKey: "local", dataEpochID: nil).isEmpty)
        let sessions = try ModelContext(store).fetch(FetchDescriptor<StudySession>())
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.seconds }, 1_800)
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.grams }, 300)
        XCTAssertTrue(sessions.allSatisfy { $0.source.isMeasured && $0.source == .screenTime && $0.rareRewardParticipated == false && $0.rareRewardCreditedGrams == 0 })
    }
    func testAccountAndResetMismatchesCannotImportOrRebindOldReceipts() throws {
        let store = try container()
        XCTAssertThrowsError(try ScreenTimeImportCoordinator.insert([receipt(owner: "another")], container: store, contextKey: "local", dataEpochID: nil))
        let epoch = UUID()
        let context = store.mainContext
        context.insert(ActivityResetMarker(epochID: epoch, sequence: 1, resetAt: .now, writerDeviceID: "test"))
        try context.save()
        XCTAssertThrowsError(try ScreenTimeImportCoordinator.insert([receipt()], container: store, contextKey: "local", dataEpochID: nil))
        XCTAssertThrowsError(try ScreenTimeImportCoordinator.insert([receipt()], container: store, contextKey: "local", dataEpochID: epoch))
        XCTAssertEqual(try ScreenTimeImportCoordinator.insert([receipt(epoch: epoch)], container: store, contextKey: "local", dataEpochID: epoch).count, 1)
    }
    func testInvalidReceiptRollsBackEntireBatch() throws {
        let store = try container()
        let now = Date.now
        let invalid = ScreenTimeLearningImport(id: UUID(), themeID: nil, startedAt: now, endedAt: now, contextKey: "local", dataEpochID: nil)
        XCTAssertThrowsError(try ScreenTimeImportCoordinator.insert([receipt(), invalid], container: store, contextKey: "local", dataEpochID: nil))
        XCTAssertEqual(try ModelContext(store).fetchCount(FetchDescriptor<StudySession>()), 0)
    }
    func testThemeIsFrozenInReceiptAndDeletedThemeKeepsLearning() throws {
        let store = try container()
        let missingTheme = UUID()
        _ = try ScreenTimeImportCoordinator.insert([receipt(themeID: missingTheme)], container: store, contextKey: "local", dataEpochID: nil)
        let session = try XCTUnwrap(ModelContext(store).fetch(FetchDescriptor<StudySession>()).first)
        XCTAssertEqual(session.subjectIDSnapshot, missingTheme)
        XCTAssertEqual(session.displaySubjectName, "Screen Timeの学習")
    }
    func testSourceParticipatesInMeasuredTotalsAndShareButOnlyExactChunksAreValid() {
        XCTAssertTrue(SessionSource.screenTime.isMeasured)
        XCTAssertFalse(SessionSource.screenTime.isSelfReported)
        XCTAssertTrue(FairnessPolicy.isIncludedInShareByDefault(source: .screenTime))
        for seconds in [60, 599, 601, 1_200] {
            XCTAssertFalse(StudySessionIntegrityPolicy.isSupported(startAt: .now.addingTimeInterval(-3_600), endAt: .now, seconds: seconds, source: .screenTime, grams: StudySession.grams(for: seconds)))
        }
    }
    func testAnimationQueueDeduplicatesAndRemovesWithoutChangingStudyData() throws {
        let suite = "ScreenTimeImportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ids = [UUID(), UUID()]
        ScreenTimeGemDropStore.append(ids + ids, defaults: defaults)
        XCTAssertEqual(ScreenTimeGemDropStore.load(defaults: defaults), ids)
        ScreenTimeGemDropStore.remove(ids[0], defaults: defaults)
        XCTAssertEqual(ScreenTimeGemDropStore.load(defaults: defaults), [ids[1]])
        ScreenTimeGemDropStore.removeAll(defaults: defaults)
        XCTAssertTrue(ScreenTimeGemDropStore.load(defaults: defaults).isEmpty)
    }

    func testCompleteErasureRemovesLedgerAndCannotReviveDelayedAwards() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreenTimeStore(directory: directory)
        try store.update { state in
            state.contextKey = "old-owner"
            state.contextIsActive = true
            state.configuration.enabled = true
            state.negativeGemCount = 12
        }
        let oldEpoch = try store.snapshot().epoch
        var stopCount = 0
        try store.eraseAllData { stopCount += 1 }
        let erased = try store.snapshot()
        XCTAssertEqual(stopCount, 1)
        XCTAssertNotEqual(erased.epoch, oldEpoch)
        XCTAssertNil(erased.contextKey)
        XCTAssertFalse(erased.contextIsActive)
        XCTAssertFalse(erased.configuration.enabled)
        XCTAssertEqual(erased.negativeGemCount, 0)
        try store.record(runID: UUID(), threshold: 12, now: .now)
        XCTAssertEqual(try store.snapshot().negativeGemCount, 0)

        let ledger = directory.appendingPathComponent("ScreenTime/ledger.json")
        try Data("invalid ledger".utf8).write(to: ledger)
        XCTAssertThrowsError(try store.snapshot())
        try store.eraseAllData { stopCount += 1 }
        XCTAssertTrue(try store.snapshot().isValid)
        try ScreenTimeStore(directory: nil).eraseAllData { stopCount += 1 }
        XCTAssertEqual(stopCount, 3)
    }
}
