import Foundation
import XCTest
@testable import PomoGem

final class ScreenTimeMonitoringTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeState(lane: ScreenTimeLane = .learning) -> ScreenTimeState {
        var state = ScreenTimeState()
        state.contextKey = "test-owner"
        state.contextIsActive = true
        state.configuration.enabled = true
        state.configuration.themeID = UUID()
        state.runs = [ScreenTimeRun(
            lane: lane, dayStart: start, dayEnd: start.addingTimeInterval(86_400),
            startedAt: start, timeZoneID: "UTC", includesPastActivity: false,
            themeID: state.configuration.themeID
        )]
        return state
    }

    func testTenMinutePlanStaysBelowActivityLimitAndCoversEachThresholdOnce() {
        XCTAssertLessThanOrEqual(ScreenTimePolicy.maximumActivities, 20)
        let thresholds = (0..<ScreenTimePolicy.batchesPerLane).flatMap { Array(ScreenTimePolicy.thresholds(batch: $0)) }
        XCTAssertEqual(thresholds, Array(1...144))
        XCTAssertEqual(ScreenTimePolicy.minutesPerGem, 10)
        XCTAssertEqual(ScreenTimePolicy.eventsPerActivity, 18)
    }

    func testFreeLimitIsFiveAndProHasNoProductLimit() {
        XCTAssertNoThrow(try ScreenTimePolicy.validateLearningCount(5, isPro: false))
        XCTAssertThrowsError(try ScreenTimePolicy.validateLearningCount(6, isPro: false))
        XCTAssertNoThrow(try ScreenTimePolicy.validateLearningCount(1_000, isPro: true))
        XCTAssertNoThrow(try ScreenTimePolicy.validate(ScreenTimeConfiguration(), isPro: false))
    }

    func testOutOfOrderRepeatedAndMissingCallbacksAwardOnlyNewTenMinuteChunks() {
        var state = makeState()
        let runID = state.runs[0].id
        state.record(runID: runID, threshold: 3, now: start.addingTimeInterval(1_801))
        state.record(runID: runID, threshold: 1, now: start.addingTimeInterval(1_802))
        state.record(runID: runID, threshold: 3, now: start.addingTimeInterval(1_803))
        let receipts = state.pendingLearningReceipts(limit: 64)
        XCTAssertEqual(receipts.count, 3)
        XCTAssertEqual(Set(receipts.map(\.id)).count, 3)
        XCTAssertEqual(receipts.map(\.minutes), [10, 10, 10])
        XCTAssertEqual(state.negativeGemCount, 0)
    }

    func testImpossibleEarlyCallbackIsRejectedButLaterHigherThresholdCatchesUp() {
        var state = makeState()
        let id = state.runs[0].id
        state.record(runID: id, threshold: 1, now: start.addingTimeInterval(1))
        XCTAssertTrue(state.pendingLearningReceipts(limit: 64).isEmpty)
        state.record(runID: id, threshold: 2, now: start.addingTimeInterval(1_201))
        XCTAssertEqual(state.pendingLearningReceipts(limit: 64).count, 2)
    }

    func testOldDayRetiredGenerationAndOutOfRangeEventsCannotAward() {
        var state = makeState()
        let id = state.runs[0].id
        for threshold in [-1, 0, 145, Int.max] {
            state.record(runID: id, threshold: threshold, now: start.addingTimeInterval(3_600))
        }
        state.record(runID: id, threshold: 1, now: start.addingTimeInterval(86_401))
        state.record(runID: UUID(), threshold: 1, now: start.addingTimeInterval(601))
        state.runs[0].active = false
        state.record(runID: id, threshold: 1, now: start.addingTimeInterval(601))
        XCTAssertTrue(state.pendingLearningReceipts(limit: 64).isEmpty)
    }

    func testPausingTimerAndDowngradeSuppressOnlyLearning() {
        for timerPaused in [true, false] {
            var learning = makeState()
            learning.learningPausedByTimer = timerPaused
            learning.learningAllowedBySubscription = timerPaused
            learning.record(runID: learning.runs[0].id, threshold: 1, now: start.addingTimeInterval(601))
            XCTAssertTrue(learning.pendingLearningReceipts(limit: 64).isEmpty)
            var distraction = makeState(lane: .distraction)
            distraction.learningPausedByTimer = timerPaused
            distraction.learningAllowedBySubscription = timerPaused
            distraction.record(runID: distraction.runs[0].id, threshold: 2, now: start.addingTimeInterval(1_201))
            distraction.record(runID: distraction.runs[0].id, threshold: 2, now: start.addingTimeInterval(1_202))
            XCTAssertEqual(distraction.negativeGemCount, 2)
            XCTAssertTrue(distraction.pendingLearningReceipts(limit: 64).isEmpty)
        }
    }

    func testReceiptIdentityAndThemeSurviveReplayUntilAcknowledgedAfterAppSave() throws {
        var state = makeState()
        let theme = state.configuration.themeID!
        state.record(runID: state.runs[0].id, threshold: 3, now: start.addingTimeInterval(1_801))
        let first = state.pendingLearningReceipts(limit: 2)
        state.configuration.themeID = UUID()
        state = try JSONDecoder().decode(ScreenTimeState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(state.pendingLearningReceipts(limit: 2), first)
        XCTAssertEqual(first.first?.themeID, theme)
        state.acknowledge(Set(first.map(\.id)))
        state.acknowledge(Set(first.map(\.id)))
        let remaining = state.pendingLearningReceipts(limit: 64)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertFalse(first.map(\.id).contains(remaining[0].id))
    }

    func testOutOfOrderAcknowledgementDoesNotDiscardUncommittedEarlierReceipt() {
        var state = makeState()
        state.record(runID: state.runs[0].id, threshold: 2, now: start.addingTimeInterval(1_201))
        let receipts = state.pendingLearningReceipts(limit: 64)
        state.acknowledge([receipts[1].id])
        XCTAssertEqual(state.pendingLearningReceipts(limit: 64).count, 2)
    }

    func testNewResetEpochProducesDifferentReceiptIDs() {
        var state = makeState()
        state.record(runID: state.runs[0].id, threshold: 1, now: start.addingTimeInterval(601))
        let before = state.pendingLearningReceipts(limit: 1)[0].id
        state.epoch = UUID()
        XCTAssertNotEqual(before, state.pendingLearningReceipts(limit: 1)[0].id)
    }

    func testDisabledOrRetiredContextCannotReceiveQueuedAwards() {
        for disabled in [true, false] {
            var state = makeState()
            state.configuration.enabled = !disabled
            state.contextIsActive = disabled
            state.record(runID: state.runs[0].id, threshold: 1, now: start.addingTimeInterval(601))
            XCTAssertTrue(state.pendingLearningReceipts(limit: 64).isEmpty)
        }
    }

    func testRevocationRequiresFreshOptInAndPreservesConfirmedLearningAndBlackStones() {
        var state = makeState()
        state.negativeGemCount = 23
        let themeID = state.configuration.themeID
        let runID = state.runs[0].id
        state.record(runID: runID, threshold: 2, now: start.addingTimeInterval(1_201))
        let receipts = state.pendingLearningReceipts(limit: 64)
        XCTAssertTrue(state.invalidateAuthorization())
        XCTAssertFalse(state.configuration.enabled)
        XCTAssertEqual(state.configuration.themeID, themeID)
        XCTAssertTrue(state.configuration.learningSelection.applicationTokens.isEmpty)
        XCTAssertTrue(state.configuration.distractionSelection.applicationTokens.isEmpty)
        XCTAssertEqual(state.negativeGemCount, 23)
        XCTAssertEqual(state.pendingLearningReceipts(limit: 64), receipts)
        XCTAssertTrue(state.contextIsActive)
        XCTAssertTrue(state.monitoringError?.contains("選び直して") == true)
        state.record(runID: runID, threshold: 3, now: start.addingTimeInterval(1_801))
        XCTAssertEqual(state.pendingLearningReceipts(limit: 64), receipts)
        XCTAssertFalse(state.invalidateAuthorization())
        XCTAssertTrue(state.isValid)
    }

    func testUnconfiguredAppDoesNotShowARevocationError() {
        var state = ScreenTimeState()
        XCTAssertFalse(state.invalidateAuthorization())
        XCTAssertNil(state.monitoringError)
    }

    func testInvalidDecodedCountersFailValidation() {
        var state = makeState()
        XCTAssertTrue(state.isValid)
        state.negativeGemCount = -1
        XCTAssertFalse(state.isValid)
        state.negativeGemCount = 0
        state.runs[0].highestThreshold = Int.max
        XCTAssertFalse(state.isValid)
    }

    func testAtomicLedgerSurvivesReopenAndConcurrentCallbacksWithoutLostIncrements() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreenTimeStore(directory: directory)
        let initial = makeState(lane: .distraction)
        let runID = initial.runs[0].id
        try store.update { $0 = initial }
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            // Each writer opens a separate descriptor, as app and extension do.
            let anotherProcess = ScreenTimeStore(directory: directory)
            do {
                try anotherProcess.record(runID: runID, threshold: index + 1,
                                          now: self.start.addingTimeInterval(60_001))
            } catch { XCTFail("Concurrent receipt failed: \(error)") }
        }
        let reopened = try ScreenTimeStore(directory: directory).snapshot()
        XCTAssertEqual(reopened.negativeGemCount, 100)
        XCTAssertEqual(reopened.runs[0].highestThreshold, 100)
    }

    func testMissingAppGroupFailsClosedAndCorruptionIsNeverOverwritten() throws {
        XCTAssertThrowsError(try ScreenTimeStore(directory: nil).snapshot())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreenTimeStore(directory: directory)
        try store.update { $0 = makeState() }
        let file = directory.appendingPathComponent("ScreenTime/ledger.json")
        let corrupt = Data("invalid ledger".utf8)
        try corrupt.write(to: file)
        XCTAssertThrowsError(try store.update { $0.negativeGemCount = 10 })
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    @MainActor
    func testControllerPublishesNothingBeforeThePersistenceOwnerIsBound() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreenTimeStore(directory: directory)
        var state = makeState()
        state.negativeGemCount = 42
        try store.update { $0 = state }
        let controller = ScreenTimeController(store: store, currentContextKey: { "test-owner" })
        XCTAssertFalse(controller.configuration.enabled)
        XCTAssertNil(controller.configuration.themeID)
        XCTAssertEqual(controller.negativeGemCount, 0)
        XCTAssertFalse(controller.isMonitoring)
        try await controller.bindContext(contextKey: "test-owner", dataEpochID: nil)
        XCTAssertEqual(controller.negativeGemCount, 42)
        XCTAssertEqual(controller.configuration.themeID, state.configuration.themeID)
    }

    @MainActor
    func testControllerRejectsLedgerFromAnotherOwnerOrEpochOnReload() async throws {
        for changesOwner in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = ScreenTimeStore(directory: directory)
            var state = makeState()
            state.negativeGemCount = 12
            try store.update { $0 = state }
            let controller = ScreenTimeController(store: store, currentContextKey: { "test-owner" })
            try await controller.bindContext(contextKey: "test-owner", dataEpochID: nil)
            XCTAssertEqual(controller.negativeGemCount, 12)
            try store.update {
                if changesOwner { $0.contextKey = "another-owner" }
                else { $0.dataEpochID = UUID() }
                $0.negativeGemCount = 99
            }
            controller.reload()
            XCTAssertEqual(controller.negativeGemCount, 0)
            XCTAssertFalse(controller.configuration.enabled)
            XCTAssertNil(controller.configuration.themeID)
            XCTAssertFalse(controller.isMonitoring)
        }
    }

    @MainActor
    func testRetiredHostsCleanupCannotSuspendTheNewOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreenTimeStore(directory: directory)
        var state = makeState()
        state.contextKey = "new-owner"
        state.negativeGemCount = 27
        try store.update { $0 = state }
        let controller = ScreenTimeController(store: store, currentContextKey: { "new-owner" })
        try await controller.bindContext(contextKey: "new-owner", dataEpochID: nil)
        controller.suspendForContextRetirement(contextKey: "old-owner", dataEpochID: nil)
        XCTAssertEqual(controller.negativeGemCount, 27)
        XCTAssertTrue(try store.snapshot().contextIsActive)
        controller.suspendForContextRetirement(contextKey: "new-owner", dataEpochID: nil)
        XCTAssertEqual(controller.negativeGemCount, 0)
        XCTAssertNil(controller.configuration.themeID)
        XCTAssertFalse(controller.configuration.enabled)
        XCTAssertFalse(try store.snapshot().contextIsActive)
        controller.reload()
        XCTAssertEqual(controller.negativeGemCount, 0)
        XCTAssertNil(controller.configuration.themeID)
        try await controller.waitForPendingOperations()
    }

    @MainActor
    func testGlobalOwnerChangeImmediatelyHidesOldDataAndRejectsOldMutationsBeforeRebind() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreenTimeStore(directory: directory)
        var state = makeState()
        state.negativeGemCount = 31
        try store.update { $0 = state }
        var currentOwner = "test-owner"
        let controller = ScreenTimeController(store: store, currentContextKey: { currentOwner })
        try await controller.bindContext(contextKey: "test-owner", dataEpochID: nil)
        XCTAssertEqual(controller.negativeGemCount, 31)
        currentOwner = "next-owner"
        controller.reload()
        XCTAssertEqual(controller.negativeGemCount, 0)
        XCTAssertNil(controller.configuration.themeID)
        XCTAssertFalse(controller.configuration.enabled)
        do { try await controller.resetActivityData(); XCTFail("Retired owner must not reset") } catch {}
        do { try await controller.save(configuration: ScreenTimeConfiguration(), isPro: false); XCTFail("Retired owner must not save") } catch {}
        do { try await controller.bindContext(contextKey: "test-owner", dataEpochID: nil); XCTFail("Retired owner must not bind") } catch {}
        await controller.reconcile(isPro: false, timerRunning: true)
        let untouched = try store.snapshot()
        XCTAssertEqual(untouched.contextKey, "test-owner")
        XCTAssertEqual(untouched.negativeGemCount, 31)
        XCTAssertFalse(untouched.learningPausedByTimer)
        XCTAssertTrue(untouched.configuration.enabled)
        controller.suspendForContextRetirement(contextKey: "test-owner", dataEpochID: nil)
        let retired = try store.snapshot()
        XCTAssertFalse(retired.contextIsActive)
        XCTAssertFalse(retired.runs.contains(where: \.active))
        XCTAssertEqual(retired.negativeGemCount, 31)
        try await controller.waitForPendingOperations()
    }
}
