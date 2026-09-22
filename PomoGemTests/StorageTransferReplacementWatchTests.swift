import Foundation
import XCTest
@testable import PomoGem

/// PLAN Step 9 — a bounded, one-shot, read-only late-arrival DETECTOR. It is
/// not a fence: a device that flushes days later is not caught. Nothing it
/// does is destructive, and it deletes exactly one file: its own receipt.
@MainActor
final class StorageTransferReplacementWatchTests: XCTestCase {
    private func fixture() throws -> (URL, AccountDataNamespace, StorageTransferReplacementWatchStore) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ReplacementWatch-\(UUID())", isDirectory: true)
        let root = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let namespace = AccountDataNamespace()
        return (root, namespace, try StorageTransferReplacementWatchStore(root: root, namespace: namespace))
    }

    private func entries(_ root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }

    private var counts: [String: Int] {
        ["Subject": 3, "StudySession": 12, "AchievementStone": 1, "Prefs": 1,
         "ActivityResetMarker": 0, "SyncedFocusTimer": 0, "FocusTimerDeviceClaim": 0]
    }

    // MARK: - The receipt

    func testReceiptIsNamedForTheNamespaceAndKeepsOnlyMirroredModelCounts() throws {
        let (root, namespace, store) = try fixture()
        let generation = UUID()
        let committedAt = Date(timeIntervalSinceReferenceDate: 12_345)
        var committed = counts
        // A local-only model can never appear in a server count comparison.
        committed["AggregatePebble"] = 9
        try store.record(datasetGenerationID: generation, committedCounts: committed, committedAt: committedAt)
        XCTAssertEqual(try entries(root), ["replacement-watch-\(namespace.rawValue).json"])
        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded.datasetGenerationID, generation)
        XCTAssertEqual(loaded.committedAt, committedAt)
        XCTAssertEqual(loaded.committedCounts, counts)
        XCTAssertEqual(loaded.readFailures, 0)
    }

    func testRecordingRefusesNegativeCountsAndLeavesNoReceipt() throws {
        let (root, _, store) = try fixture()
        XCTAssertThrowsError(try store.record(datasetGenerationID: UUID(),
            committedCounts: ["Subject": -1], committedAt: Date()))
        XCTAssertEqual(try entries(root), [])
        XCTAssertNil(try store.load())
    }

    func testRewritingTheReceiptForANewerCommitReplacesTheOlderOne() throws {
        let (_, _, store) = try fixture()
        try store.record(datasetGenerationID: UUID(), committedCounts: counts, committedAt: Date())
        let generation = UUID()
        try store.record(datasetGenerationID: generation, committedCounts: counts, committedAt: Date())
        XCTAssertEqual(try store.load()?.datasetGenerationID, generation)
    }

    // MARK: - The one comparison

    func testNoReceiptMeansNoOutcomeAndNoServerRead() async throws {
        let (_, _, store) = try fixture()
        var reads = 0
        let outcome = await store.evaluate(currentGenerationID: UUID()) { reads += 1; return [:] }
        XCTAssertEqual(outcome, .noReceipt)
        XCTAssertEqual(reads, 0)
    }

    func testEqualServerCountsClearTheReceiptAfterExactlyOneRead() async throws {
        let (root, _, store) = try fixture()
        let generation = UUID()
        try store.record(datasetGenerationID: generation, committedCounts: counts, committedAt: Date())
        var reads = 0
        let outcome = await store.evaluate(currentGenerationID: generation) { reads += 1; return self.counts }
        XCTAssertEqual(outcome, .cleared)
        XCTAssertEqual(reads, 1)
        XCTAssertNil(try store.load())
        XCTAssertEqual(try entries(root), [])
        // One shot: a second evaluation never reads again.
        let again = await store.evaluate(currentGenerationID: generation) { reads += 1; return self.counts }
        XCTAssertEqual(again, .noReceipt)
        XCTAssertEqual(reads, 1)
    }

    func testServerRowsTheCommittedPayloadDidNotHoldAreFlaggedOnceThenTheReceiptIsDeleted() async throws {
        let (root, _, store) = try fixture()
        let generation = UUID()
        try store.record(datasetGenerationID: generation, committedCounts: counts, committedAt: Date())
        var server = counts
        server["StudySession"] = 14
        server["Subject"] = 4
        let outcome = await store.evaluate(currentGenerationID: generation) { server }
        XCTAssertEqual(outcome, .lateArrival(models: ["StudySession", "Subject"]))
        XCTAssertNil(try store.load())
        XCTAssertEqual(try entries(root), [])
    }

    func testFewerServerRowsThanCommittedAreNotALateArrival() async throws {
        let (_, _, store) = try fixture()
        let generation = UUID()
        try store.record(datasetGenerationID: generation, committedCounts: counts, committedAt: Date())
        var server = counts
        server["StudySession"] = 2
        let outcome = await store.evaluate(currentGenerationID: generation) { server }
        XCTAssertEqual(outcome, .cleared)
    }

    func testGrowthThisDeviceAuthoredAfterTheCommitIsNotFlagged() async throws {
        let (root, _, store) = try fixture()
        let generation = UUID()
        try store.record(datasetGenerationID: generation, committedCounts: counts, committedAt: Date())
        var server = counts
        server["StudySession"] = 15
        let outcome = await store.evaluate(currentGenerationID: generation,
                                           locallyAuthoredSinceCommit: ["StudySession": 3]) { server }
        XCTAssertEqual(outcome, .cleared)
        let stricter = try StorageTransferReplacementWatchStore(root: root, namespace: AccountDataNamespace())
        try stricter.record(datasetGenerationID: generation, committedCounts: counts, committedAt: Date())
        let flagged = await stricter.evaluate(currentGenerationID: generation,
                                              locallyAuthoredSinceCommit: ["StudySession": 2]) { server }
        XCTAssertEqual(flagged, .lateArrival(models: ["StudySession"]))
    }

    func testAReceiptForASupersededGenerationIsDroppedWithoutReading() async throws {
        let (root, _, store) = try fixture()
        try store.record(datasetGenerationID: UUID(), committedCounts: counts, committedAt: Date())
        var reads = 0
        let outcome = await store.evaluate(currentGenerationID: UUID()) { reads += 1; return self.counts }
        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(try entries(root), [])
    }

    func testAReceiptWithNoReadableGenerationIsDroppedWithoutReading() async throws {
        let (_, _, store) = try fixture()
        try store.record(datasetGenerationID: UUID(), committedCounts: counts, committedAt: Date())
        var reads = 0
        let outcome = await store.evaluate(currentGenerationID: nil) { reads += 1; return self.counts }
        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(reads, 0)
        XCTAssertNil(try store.load())
    }

    // MARK: - Bounded failure handling

    func testAReadFailureIsRetainedForExactlyOneMoreLaunchThenDropped() async throws {
        let (root, _, store) = try fixture()
        let generation = UUID()
        try store.record(datasetGenerationID: generation, committedCounts: counts, committedAt: Date())
        let failing: () async throws -> [String: Int] = { throw CloudStorageTransferCloudError.timedOut }
        let first = await store.evaluate(currentGenerationID: generation, read: failing)
        XCTAssertEqual(first, .deferred)
        XCTAssertEqual(try store.load()?.readFailures, 1)
        XCTAssertEqual(StorageTransferReplacementWatchStore.maximumReadFailures, 1)
        let second = await store.evaluate(currentGenerationID: generation, read: failing)
        XCTAssertEqual(second, .dropped)
        XCTAssertNil(try store.load())
        XCTAssertEqual(try entries(root), [])
    }

    func testADeferredReceiptStillClearsNormallyOnItsSecondChance() async throws {
        let (_, _, store) = try fixture()
        let generation = UUID()
        try store.record(datasetGenerationID: generation, committedCounts: counts, committedAt: Date())
        _ = await store.evaluate(currentGenerationID: generation) { throw CloudStorageTransferCloudError.timedOut }
        let outcome = await store.evaluate(currentGenerationID: generation) { self.counts }
        XCTAssertEqual(outcome, .cleared)
        XCTAssertNil(try store.load())
    }

    // MARK: - Never destructive

    func testEvaluationRemovesNothingButItsOwnReceipt() async throws {
        let (root, namespace, store) = try fixture()
        let neighbours = ["admission-\(AccountDataNamespace().rawValue).json", "pending-v1.json", "selection-v1.json"]
        for name in neighbours {
            try Data("{}".utf8).write(to: root.appendingPathComponent(name))
        }
        let generation = UUID()
        try store.record(datasetGenerationID: generation, committedCounts: counts, committedAt: Date())
        var server = counts
        server["Subject"] = 99
        let outcome = await store.evaluate(currentGenerationID: generation) { server }
        XCTAssertEqual(outcome, .lateArrival(models: ["Subject"]))
        XCTAssertEqual(try entries(root), neighbours.sorted())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("replacement-watch-\(namespace.rawValue).json").path))
    }

    func testAnotherNamespacesReceiptIsNeverReadOrRemoved() async throws {
        let (root, namespace, store) = try fixture()
        let other = AccountDataNamespace()
        let otherStore = try StorageTransferReplacementWatchStore(root: root, namespace: other)
        let generation = UUID()
        try store.record(datasetGenerationID: generation, committedCounts: counts, committedAt: Date())
        try otherStore.record(datasetGenerationID: UUID(), committedCounts: counts, committedAt: Date())
        let outcome = await store.evaluate(currentGenerationID: generation) { self.counts }
        XCTAssertEqual(outcome, .cleared)
        XCTAssertNil(try store.load())
        XCTAssertNotNil(try otherStore.load())
        XCTAssertEqual(try entries(root), ["replacement-watch-\(other.rawValue).json"])
        XCTAssertNotEqual(namespace.rawValue, other.rawValue)
    }

    // MARK: - What the banner is allowed to say (review-1-3 / 2-3 / 3-3)

    func testOnlyUserRecognizableModelsCanRaiseTheBanner() {
        XCTAssertEqual(StorageTransferLateArrivalPolicy.reportableModels,
                       ["AchievementStone", "StudySession", "Subject"])
        XCTAssertTrue(StorageTransferLateArrivalPolicy.deviceBookkeepingModels
            .isSubset(of: PomoGemStorageSnapshot.cloudModelNames))
    }

    /// A single-device account claims its own timer and writes its own mirrored
    /// timer row on the very mount that evaluates the receipt. Reporting that
    /// growth would make the account accuse itself on every overwrite.
    func testThisDevicesOwnBookkeepingGrowthNeverRaisesTheBanner() {
        XCTAssertNil(StorageTransferLateArrivalPolicy.reportable(
            .lateArrival(models: ["FocusTimerDeviceClaim", "SyncedFocusTimer", "Prefs"])))
        XCTAssertNil(StorageTransferLateArrivalPolicy.reportable(.cleared))
        XCTAssertNil(StorageTransferLateArrivalPolicy.reportable(.noReceipt))
        XCTAssertNil(StorageTransferLateArrivalPolicy.reportable(.superseded))
        XCTAssertNil(StorageTransferLateArrivalPolicy.reportable(.deferred))
        XCTAssertNil(StorageTransferLateArrivalPolicy.reportable(.dropped))
    }

    func testRecordGrowthIsReportedSortedAndWithoutTheBookkeepingModels() {
        XCTAssertEqual(StorageTransferLateArrivalPolicy.reportable(
            .lateArrival(models: ["StudySession", "FocusTimerDeviceClaim", "Subject"])),
                       ["StudySession", "Subject"])
        XCTAssertEqual(StorageTransferLateArrivalPolicy.reportable(
            .lateArrival(models: ["AchievementStone"])), ["AchievementStone"])
    }
}
