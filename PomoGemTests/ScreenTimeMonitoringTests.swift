import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
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
        // The focus shield's failsafe shares the same 20 (F2).
        XCTAssertLessThanOrEqual(ScreenTimePolicy.maximumActivitiesIncludingFocusShield, 20)
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

    /// The device runbook filters Console by this subsystem and category; keep
    /// them in step with Docs/ScreenTimeGems.md.
    func testDiagnosticsChannelMatchesTheDocumentedConsoleFilter() {
        XCTAssertEqual(ScreenTimeLog.subsystem, "com.hinoshiba.pomogem")
        XCTAssertEqual(ScreenTimeLog.category, "screen-time")
    }

    /// The extension logs "threshold recorded" only when the ledger actually
    /// advanced. Without a reported outcome a discarded callback and an awarded
    /// gem look identical in Console, which is the one evidence channel the
    /// device phase has for a delivery it cannot otherwise observe.
    func testRecordReportsWhetherTheLedgerAdvanced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreenTimeStore(directory: directory)
        let state = makeState()
        let runID = state.runs[0].id
        try store.update { $0 = state }

        XCTAssertTrue(try store.record(runID: runID, threshold: 1, now: start.addingTimeInterval(601)))
        // A repeated or lower threshold is a duplicate delivery, not an award.
        XCTAssertFalse(try store.record(runID: runID, threshold: 1, now: start.addingTimeInterval(602)))
        // An impossibly early callback is refused by the ledger fences.
        XCTAssertFalse(try store.record(runID: runID, threshold: 9, now: start.addingTimeInterval(603)))
        // A run the ledger no longer holds (reset, retirement, another day).
        XCTAssertFalse(try store.record(runID: UUID(), threshold: 1, now: start.addingTimeInterval(601)))
        XCTAssertEqual(try store.snapshot().runs[0].highestThreshold, 1)
    }

    /// The monitor extension shares the monitoring lock with an app that iOS can
    /// suspend while it holds it. An unbounded flock(LOCK_EX) there ends with the
    /// extension killed for running too long, so it must be able to give up.
    func testBoundedMonitoringLockWaitGivesUpWhileAnotherProcessHoldsIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let holder = ScreenTimeStore(directory: directory)
        let held = expectation(description: "Another process holds the monitoring lock")
        let release = DispatchSemaphore(value: 0)
        var releasedOnce = false
        defer { if !releasedOnce { release.signal() } }
        DispatchQueue.global().async {
            try? holder.withMonitoringLock {
                held.fulfill()
                _ = release.wait(timeout: .now() + 30)
            }
        }
        wait(for: [held], timeout: 10)

        // A separate descriptor, exactly as the extension process opens it.
        let waiting = ScreenTimeStore(directory: directory)
        let began = Date()
        XCTAssertThrowsError(try waiting.withMonitoringLock(timeout: 0.3) { XCTFail("Must not enter") }) { error in
            guard case ScreenTimeError.unavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(began)
        // Pin the elapsed time against the bound that was asked for, not just
        // against "not infinite": the extension's real bound is 5 s, and an
        // implementation that ignored `timeout` for a hard-coded 8 s deadline
        // would be killed on device while a 10 s ceiling stayed green.
        XCTAssertGreaterThanOrEqual(elapsed, 0.3, "A timeout of 0 must not pass either")
        XCTAssertLessThan(elapsed, 2)

        release.signal()
        releasedOnce = true
        // The bounded wait still takes the lock once the holder is done.
        var entered = false
        for _ in 0..<50 where !entered {
            _ = try? waiting.withMonitoringLock(timeout: 1) { entered = true }
        }
        XCTAssertTrue(entered)
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
        await controller.reconcile(isPro: false, learningPause: .indefinite)
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


/// The app picker exposes opaque tokens. These tests keep them opaque while
/// exercising migration, event attribution, and the shared OS activity budget.
final class ScreenTimePerApplicationThemeTests: XCTestCase {
    private let now = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        .addingTimeInterval(43_200)
    private var directories: [URL] = []
    private let noticeSuite = "ScreenTimePerApplicationThemes-" + UUID().uuidString
    private var noticeDefaults: UserDefaults { UserDefaults(suiteName: noticeSuite)! }

    override func tearDown() {
        noticeDefaults.removePersistentDomain(forName: noticeSuite)
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testLegacyLedgerAssignsEverySelectedAppToItsExistingThemeWithoutRewritingIt() throws {
        var configuration = try configuration(applications: 2)
        let originalTheme = UUID()
        configuration.themeID = originalTheme
        let encoded = try JSONEncoder().encode(configuration)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["learningApplicationThemes"])
        var restored = try JSONDecoder().decode(ScreenTimeConfiguration.self, from: encoded)
        for token in restored.learningSelection.applicationTokens {
            XCTAssertEqual(restored.learningThemeID(for: token), originalTheme)
        }
        XCTAssertEqual(restored, configuration)
        restored.reconcileLearningThemeAssignments()
        XCTAssertTrue(restored.hasSameLearningDestinations(as: configuration))
        let once = restored
        restored.reconcileLearningThemeAssignments()
        XCTAssertEqual(restored, once, "Repeated reconciliation must not dirty a settings draft")
        XCTAssertEqual(try JSONDecoder().decode(ScreenTimeConfiguration.self,
                                              from: JSONEncoder().encode(restored)), restored)
    }

    func testChangingOneLegacyAppPreservesTheOthersAndExplicitMissingDestinationDoesNotFallBack() throws {
        var configuration = try configuration(applications: 2)
        let original = UUID(), reading = UUID()
        configuration.themeID = original
        let tokens = Array(configuration.learningSelection.applicationTokens)
        configuration.setLearningThemeID(reading, for: tokens[0])
        XCTAssertEqual(configuration.learningThemeID(for: tokens[0]), reading)
        XCTAssertEqual(configuration.learningThemeID(for: tokens[1]), original)
        configuration.setLearningThemeID(nil, for: tokens[0])
        configuration.reconcileLearningThemeAssignments()
        XCTAssertNil(configuration.learningThemeID(for: tokens[0]))
        XCTAssertThrowsError(try ScreenTimePolicy.validate(configuration, isPro: false)) {
            guard case ScreenTimeError.missingTheme = $0 else { return XCTFail("Wrong validation error") }
        }
        configuration.setLearningThemeID(reading, for: tokens[0])
        XCTAssertNoThrow(try ScreenTimePolicy.validate(configuration, isPro: false))
    }

    func testRemovedAppAssignmentIsPrunedAndNewAppsNeedAnExplicitDestination() throws {
        var configuration = try configuration(applications: 2)
        let theme = UUID()
        configuration.reconcileLearningThemeAssignments(defaultThemeID: theme)
        let removed = try XCTUnwrap(configuration.learningSelection.applicationTokens.first)
        configuration.learningSelection.applicationTokens.remove(removed)
        configuration.reconcileLearningThemeAssignments()
        XCTAssertEqual(configuration.learningApplicationThemes?.count, 1)
        configuration.learningSelection.applicationTokens.insert(removed)
        XCTAssertNil(configuration.learningThemeID(for: removed))
        configuration.reconcileLearningThemeAssignments(defaultThemeID: theme)
        XCTAssertEqual(configuration.learningThemeID(for: removed), theme)
    }

    func testManyDestinationsShareEightActivitiesAndEveryEventContainsOnlyItsOwnApps() throws {
        var configuration = try configuration(applications: 12)
        for token in configuration.learningSelection.applicationTokens {
            configuration.setLearningThemeID(UUID(), for: token)
        }
        configuration.distractionSelection.applicationTokens = [try token(200)]
        let (store, center, monitor) = try fixture(configuration)
        XCTAssertTrue(try monitor.synchronize(now: now))
        let state = try store.snapshot()
        XCTAssertTrue(state.isValid)
        XCTAssertEqual(state.runs.filter { $0.active && $0.lane == .learning }.count, 12)
        XCTAssertEqual(center.activities.count, ScreenTimePolicy.maximumActivities)
        XCTAssertLessThanOrEqual(center.activities.count + ScreenTimePolicy.focusShieldActivities, 20)
        for run in state.runs where run.active {
            for batch in 0..<ScreenTimePolicy.batchesPerLane {
                let events = try XCTUnwrap(center.events[run.activityPrefix + String(batch)])
                for threshold in ScreenTimePolicy.thresholds(batch: batch) {
                    let event = try XCTUnwrap(events[DeviceActivityEvent.Name(run.eventName(threshold: threshold))])
                    let expected = run.lane == .learning
                        ? configuration.learningApplications(for: try XCTUnwrap(run.themeID))
                        : configuration.distractionSelection.applicationTokens
                    XCTAssertEqual(event.applications, expected)
                    XCTAssertEqual(event.threshold.minute, threshold * 10)
                }
            }
        }
        let before = center.startCount
        XCTAssertTrue(try monitor.synchronize(now: now.addingTimeInterval(60)))
        XCTAssertEqual(center.startCount, before, "An unchanged settings pass must preserve event baselines")
    }

    func testAppsSharingADestinationContributeToTheSameTenMinuteEvent() throws {
        var configuration = try configuration(applications: 3)
        let tokens = Array(configuration.learningSelection.applicationTokens)
        let news = UUID(), reading = UUID()
        configuration.setLearningThemeID(news, for: tokens[0])
        configuration.setLearningThemeID(news, for: tokens[1])
        configuration.setLearningThemeID(reading, for: tokens[2])
        let (store, center, monitor) = try fixture(configuration)
        XCTAssertTrue(try monitor.synchronize(now: now))
        let runs = try store.snapshot().runs
        XCTAssertEqual(runs.count, 2)
        let newsRun = try XCTUnwrap(runs.first { $0.themeID == news })
        let event = try XCTUnwrap(center.events[newsRun.activityPrefix + "0"]?[
            DeviceActivityEvent.Name(newsRun.eventName(threshold: 1))])
        XCTAssertEqual(event.applications, Set([tokens[0], tokens[1]]))
    }

    func testSharedActivityCallbacksAttributeIndependentlyAndRejectAnotherRegistration() throws {
        var configuration = try configuration(applications: 2)
        for token in configuration.learningSelection.applicationTokens {
            configuration.setLearningThemeID(UUID(), for: token)
        }
        let (store, _, monitor) = try fixture(configuration)
        XCTAssertTrue(try monitor.synchronize(now: now))
        let runs = try store.snapshot().runs
        let first = runs[0], second = runs[1]
        try monitor.handleThreshold(eventName: first.eventName(threshold: 2), activityName: first.activityPrefix + "0",
                                    now: now.addingTimeInterval(1_201))
        try monitor.handleThreshold(eventName: second.eventName(threshold: 1), activityName: second.activityPrefix + "0",
                                    now: now.addingTimeInterval(1_202))
        try monitor.handleThreshold(eventName: first.eventName(threshold: 1), activityName: first.activityPrefix + "0",
                                    now: now.addingTimeInterval(1_203))
        try monitor.handleThreshold(eventName: first.eventName(threshold: 3),
                                    activityName: ScreenTimePolicy.activityPrefix + UUID().uuidString + ".0",
                                    now: now.addingTimeInterval(1_801))
        let receipts = try store.pendingLearningReceipts()
        XCTAssertEqual(receipts.filter { $0.themeID == first.themeID }.count, 2)
        XCTAssertEqual(receipts.filter { $0.themeID == second.themeID }.count, 1)
        XCTAssertEqual(Set(receipts.map(\.id)).count, 3)
    }

    @MainActor
    func testReassigningPodcastAndAudibleKeepsCompletedEnglishReceiptsAndStartsNewDestinations() async throws {
        var configuration = try configuration(applications: 2)
        let english = UUID(), news = UUID(), reading = UUID()
        configuration.themeID = english
        let tokens = Array(configuration.learningSelection.applicationTokens)
        let (store, center, monitor) = try fixture(configuration)
        let driver = FixedMonitor(monitor, now: now)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: driver, authorization: { .approved },
                                              noticeDefaults: noticeDefaults)
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        XCTAssertTrue(try monitor.synchronize(now: now))
        let oldRun = try XCTUnwrap(try store.snapshot().runs.first)
        try monitor.handleThreshold(eventName: "2", activityName: oldRun.activityPrefix + "0",
                                    now: now.addingTimeInterval(1_201))
        let oldReceipts = try store.pendingLearningReceipts()
        XCTAssertEqual(oldReceipts.count, 2)
        configuration.setLearningThemeID(news, for: tokens[0])
        configuration.setLearningThemeID(reading, for: tokens[1])
        driver.now = now.addingTimeInterval(1_800)
        try await controller.save(configuration: configuration, isPro: false)
        let saved = try store.snapshot()
        XCTAssertEqual(saved.pendingLearningReceipts(limit: 64), oldReceipts)
        XCTAssertEqual(Set(oldReceipts.map(\.themeID)), [english])
        XCTAssertFalse(try XCTUnwrap(saved.runs.first { $0.id == oldRun.id }).active)
        XCTAssertEqual(Set(saved.runs.filter(\.active).compactMap(\.themeID)), [news, reading])
        XCTAssertFalse(center.activities.contains { $0.rawValue.hasPrefix(oldRun.activityPrefix) })
        try monitor.handleThreshold(eventName: "3", activityName: oldRun.activityPrefix + "0",
                                    now: now.addingTimeInterval(2_401))
        XCTAssertEqual(try store.pendingLearningReceipts(), oldReceipts)
        for run in saved.runs where run.active {
            try monitor.handleThreshold(eventName: run.eventName(threshold: 1), activityName: run.activityPrefix + "0",
                                        now: now.addingTimeInterval(2_401))
        }
        let receipts = try store.pendingLearningReceipts()
        XCTAssertEqual(receipts.filter { $0.themeID == english }.count, 2)
        XCTAssertEqual(receipts.filter { $0.themeID == news }.count, 1)
        XCTAssertEqual(receipts.filter { $0.themeID == reading }.count, 1)
    }

    @MainActor
    func testDeletingOneThemeKeepsOtherAppsAndRecordingEnabled() async throws {
        var configuration = try configuration(applications: 2)
        let tokens = Array(configuration.learningSelection.applicationTokens)
        let removed = UUID(), remaining = UUID()
        configuration.setLearningThemeID(removed, for: tokens[0])
        configuration.setLearningThemeID(remaining, for: tokens[1])
        let (store, _, monitor) = try fixture(configuration)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: FixedMonitor(monitor, now: now), authorization: { .approved },
                                              noticeDefaults: noticeDefaults)
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        let outcome = await controller.retireLearningSelection(ofRemovedTheme: removed, isPro: false)
        XCTAssertTrue(outcome.cleared)
        XCTAssertNil(outcome.failure)
        let saved = try store.snapshot().configuration
        XCTAssertTrue(saved.enabled)
        XCTAssertEqual(saved.learningSelection.applicationTokens, [tokens[1]])
        XCTAssertEqual(saved.learningThemeID(for: tokens[1]), remaining)
        XCTAssertTrue(ScreenTimeThemeDeletionNotice.applies(to: remaining, configuration: saved, isBound: true))
        XCTAssertFalse(ScreenTimeThemeDeletionNotice.applies(to: removed, configuration: saved, isBound: true))
    }

    @MainActor
    func testDeletingAThemeOverTheFreeLimitStillRemovesItsAppsWithoutChangingAnUnresolvedEntitlement() async throws {
        for entitlement in [false, nil, true] as [Bool?] {
            var configuration = try configuration(applications: 8)
            let tokens = Array(configuration.learningSelection.applicationTokens)
            let removed = UUID(), remaining = UUID()
            configuration.reconcileLearningThemeAssignments(defaultThemeID: remaining)
            configuration.setLearningThemeID(removed, for: tokens[0])
            let (store, _, monitor) = try fixture(configuration)
            let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                                  monitoring: FixedMonitor(monitor, now: now), authorization: { .approved },
                                              noticeDefaults: noticeDefaults)
            try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
            let outcome = await controller.retireLearningSelection(ofRemovedTheme: removed, isPro: entitlement)
            XCTAssertTrue(outcome.cleared)
            XCTAssertNil(outcome.failure)
            let state = try store.snapshot()
            XCTAssertEqual(state.configuration.learningSelection.applicationTokens.count, 7)
            XCTAssertFalse(state.configuration.learningSelection.applicationTokens.contains(tokens[0]))
            XCTAssertEqual(state.configuration.learningThemeIDs, [remaining])
            XCTAssertEqual(state.learningAllowedBySubscription, entitlement != false,
                           "A real downgrade closes the gate; no StoreKit answer preserves it")
            XCTAssertEqual(state.runs.contains { $0.active && $0.lane == .learning }, entitlement != false)
        }
    }

    func testTimerPrearmsAllDestinationsWithoutIncreasingActivityCountAndRetiresAllOnIndefinitePause() throws {
        var configuration = try configuration(applications: 2)
        for token in configuration.learningSelection.applicationTokens {
            configuration.setLearningThemeID(UUID(), for: token)
        }
        let (store, center, monitor) = try fixture(configuration)
        let end = now.addingTimeInterval(1_500)
        try store.update { $0.applyTimerPause(.until(end), now: now) }
        XCTAssertTrue(try monitor.synchronize(now: now))
        let runs = try store.snapshot().runs.filter(\.active)
        XCTAssertEqual(runs.count, 2)
        XCTAssertTrue(runs.allSatisfy { $0.startedAt == end && !$0.includesPastActivity })
        XCTAssertEqual(center.activities.count, 1 + ScreenTimePolicy.batchesPerLane)
        for run in runs {
            try monitor.handleThreshold(eventName: run.eventName(threshold: 1), activityName: run.activityPrefix + "0",
                                        now: end.addingTimeInterval(601))
        }
        XCTAssertEqual(try store.pendingLearningReceipts().count, 2)
        try store.update { $0.applyTimerPause(.indefinite, now: end.addingTimeInterval(602)) }
        XCTAssertFalse(try monitor.synchronize(now: end.addingTimeInterval(602)))
        XCTAssertTrue(try store.snapshot().runs.allSatisfy { !$0.active })
        XCTAssertEqual(center.activities.count, 1)
    }

    func testRolloverOnlyReplaysMidnightUsageForTheDestinationThatWasAlreadyActive() throws {
        var configuration = try configuration(applications: 2)
        let tokens = Array(configuration.learningSelection.applicationTokens)
        let continuing = UUID(), added = UUID()
        configuration.setLearningThemeID(continuing, for: tokens[0])
        configuration.setLearningThemeID(added, for: tokens[1])
        let (store, _, monitor) = try fixture(configuration)
        let dayStart = Calendar.current.startOfDay(for: now)
        let previousDay = Calendar.current.date(byAdding: .day, value: -1, to: dayStart)!
        try store.update {
            $0.runs = [ScreenTimeRun(lane: .learning, dayStart: previousDay, dayEnd: dayStart,
                                    startedAt: previousDay, timeZoneID: Calendar.current.timeZone.identifier,
                                    includesPastActivity: false, themeID: continuing)]
        }
        XCTAssertTrue(try monitor.synchronize(now: now))
        let state = try store.snapshot()
        XCTAssertTrue(state.isValid)
        let continued = try XCTUnwrap(state.runs.first { $0.active && $0.themeID == continuing })
        let newlyAdded = try XCTUnwrap(state.runs.first { $0.active && $0.themeID == added })
        XCTAssertTrue(continued.includesPastActivity)
        XCTAssertEqual(continued.startedAt, dayStart)
        XCTAssertFalse(newlyAdded.includesPastActivity)
        XCTAssertEqual(newlyAdded.startedAt, now)
        XCTAssertEqual(continued.activityPrefix, newlyAdded.activityPrefix)
        let report = ScreenTimeDiagnosticsReport(state: state, now: now)
        XCTAssertEqual(report.schemaVersion, 4)
        XCTAssertEqual(report.learning.activeRuns, 2)
        XCTAssertNil(report.learning.includesPastActivity, "Mixed destinations cannot be reported as a single Boolean")
        XCTAssertNil(report.learning.runStartedAtOffsetSec)
        XCTAssertNotNil(report.learning.intervalStartOffsetSec)
    }

    @MainActor
    func testMigratingTheLegacyMapWithoutChangingDestinationsPreservesAnActiveRun() async throws {
        var configuration = try configuration(applications: 2)
        configuration.themeID = UUID()
        let (store, center, monitor) = try fixture(configuration)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: FixedMonitor(monitor, now: now), authorization: { .approved },
                                              noticeDefaults: noticeDefaults)
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        XCTAssertTrue(try monitor.synchronize(now: now))
        let run = try XCTUnwrap(try store.snapshot().runs.first)
        let starts = center.startCount
        configuration.reconcileLearningThemeAssignments()
        try await controller.save(configuration: configuration, isPro: false)
        XCTAssertEqual(try store.snapshot().runs.first?.id, run.id)
        XCTAssertEqual(center.startCount, starts)
    }

    private func token(_ index: UInt8) throws -> ApplicationToken {
        try JSONDecoder().decode(ApplicationToken.self,
                                 from: JSONEncoder().encode(["data": Data([0xD3, index])]))
    }

    private func configuration(applications: Int) throws -> ScreenTimeConfiguration {
        var configuration = ScreenTimeConfiguration()
        configuration.enabled = true
        configuration.learningSelection.applicationTokens = Set(try (0..<applications).map { try token(UInt8($0)) })
        return configuration
    }

    private func fixture(_ configuration: ScreenTimeConfiguration) throws
        -> (ScreenTimeStore, PerApplicationCenter, ScreenTimeMonitoring) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        let store = ScreenTimeStore(directory: directory)
        try store.update {
            $0.contextKey = "owner"
            $0.contextIsActive = true
            $0.configuration = configuration
        }
        let center = PerApplicationCenter()
        let monitor = ScreenTimeMonitoring(store: store, center: center, authorization: { true })
        return (store, center, monitor)
    }

    private final class FixedMonitor: ScreenTimeMonitoringDriving {
        let monitor: ScreenTimeMonitoring
        var now: Date
        init(_ monitor: ScreenTimeMonitoring, now: Date) { self.monitor = monitor; self.now = now }
        func stop() { monitor.stop() }
        func invalidateAuthorizationIfNeeded() throws { try monitor.invalidateAuthorizationIfNeeded() }
        func synchronize(now: Date) throws -> Bool { try monitor.synchronize(now: self.now) }
    }

    private final class PerApplicationCenter: ScreenTimeActivityCenterDriving {
        var events: [String: [DeviceActivityEvent.Name: DeviceActivityEvent]] = [:]
        var startCount = 0
        var activities: [DeviceActivityName] { events.keys.map(DeviceActivityName.init(rawValue:)) }
        func stopMonitoring(_ activities: [DeviceActivityName]) {
            XCTAssertFalse(activities.isEmpty)
            for activity in activities { events.removeValue(forKey: activity.rawValue) }
        }
        func startMonitoring(_ activity: DeviceActivityName, during schedule: DeviceActivitySchedule,
                             events: [DeviceActivityEvent.Name: DeviceActivityEvent]) throws {
            self.events[activity.rawValue] = events
            startCount += 1
            XCTAssertLessThanOrEqual(self.events.count + ScreenTimePolicy.focusShieldActivities, 20)
        }
    }
}
