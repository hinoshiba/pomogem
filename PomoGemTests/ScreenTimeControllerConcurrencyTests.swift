import FamilyControls
import Foundation
import ManagedSettings
import XCTest
@testable import PomoGem

@MainActor
final class ScreenTimeControllerConcurrencyTests: XCTestCase {
    private enum DriverError: Error { case timeout, failed }

    private final class Driver: ScreenTimeMonitoringDriving {
        let store: ScreenTimeStore
        private let lock = NSLock()
        private var calls: [String] = []
        var onFirstSynchronize: (() throws -> Void)?
        var onFirstStop: (() -> Void)?

        init(store: ScreenTimeStore) { self.store = store }
        var events: [String] { lock.lock(); defer { lock.unlock() }; return calls }
        private func record(_ event: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let first = !calls.contains(event)
            calls.append(event)
            return first
        }
        func stop() {
            XCTAssertFalse(Thread.isMainThread)
            if record("stop") { onFirstStop?() }
        }
        func invalidateAuthorizationIfNeeded() throws {
            XCTAssertFalse(Thread.isMainThread)
        }
        func synchronize(now: Date) throws -> Bool {
            XCTAssertFalse(Thread.isMainThread)
            return try store.withMonitoringLock {
                if record("synchronize") { try onFirstSynchronize?() }
                _ = record("synchronized")
                return try store.snapshot().runs.contains(where: \.active)
            }
        }
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        super.tearDown()
    }

    private func makeStore(owner: String = "owner", epoch: UUID? = nil) throws -> ScreenTimeStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        let store = ScreenTimeStore(directory: directory)
        var state = ScreenTimeState()
        state.contextKey = owner
        state.dataEpochID = epoch
        state.contextIsActive = true
        state.configuration.enabled = true
        state.configuration.themeID = UUID()
        state.negativeGemCount = 9
        state.runs = [ScreenTimeRun(
            lane: .learning, dayStart: start, dayEnd: start.addingTimeInterval(86_400),
            startedAt: start, timeZoneID: "UTC", includesPastActivity: false,
            themeID: state.configuration.themeID
        )]
        try store.update { $0 = state }
        return store
    }

    private func blockNextSave(_ driver: Driver) -> (XCTestExpectation, DispatchSemaphore) {
        let entered = expectation(description: "Registration entered the background driver")
        let release = DispatchSemaphore(value: 0)
        driver.onFirstSynchronize = {
            entered.fulfill()
            guard release.wait(timeout: .now() + 15) == .success else { throw DriverError.timeout }
        }
        return (entered, release)
    }

    func testSlowSaveKeepsMainActorResponsiveAndRejectsDuplicateSave() async throws {
        let store = try makeStore()
        let driver = Driver(store: store)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" }, monitoring: driver, authorization: { .approved })
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        let (entered, release) = blockNextSave(driver)
        defer { release.signal() }
        let configuration = controller.configuration
        let save = Task { try await controller.save(configuration: configuration, isPro: false) }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(controller.isSaving)
        XCTAssertTrue(controller.isUpdatingMonitoring)
        let heartbeat = expectation(description: "Main actor remains available during OS registration")
        Task { @MainActor in heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 5)
        do {
            try await controller.save(configuration: configuration, isPro: false)
            XCTFail("A duplicate save must not enter the driver")
        } catch { XCTAssertTrue(error is ScreenTimeController.OperationError) }
        XCTAssertEqual(driver.events.filter { $0 == "synchronize" }.count, 1)
        release.signal()
        try await save.value
        XCTAssertFalse(controller.isSaving)
        XCTAssertFalse(controller.isUpdatingMonitoring)
        XCTAssertEqual(controller.configuration, configuration)
    }

    /// AuthorizationCenter can answer .notDetermined before Family Controls has
    /// loaded at a cold launch. Treating that as a revocation throws away the
    /// saved opaque selections, which only a new picker session can restore.
    func testTransientNotDeterminedStatusDoesNotRevokeSavedSelections() async throws {
        let store = try makeStore()
        let driver = Driver(store: store)
        var status = AuthorizationStatus.notDetermined
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: driver, authorization: { status })
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        let runID = try XCTUnwrap(store.snapshot().runs.first?.id)

        await controller.reconcile(isPro: false, timerRunning: false)
        try await controller.waitForPendingOperations()
        var state = try store.snapshot()
        XCTAssertTrue(state.configuration.enabled)
        XCTAssertNil(state.monitoringError)
        XCTAssertTrue(state.runs.contains { $0.id == runID && $0.active })

        status = .denied
        await controller.reconcile(isPro: false, timerRunning: false)
        try await controller.waitForPendingOperations()
        state = try store.snapshot()
        XCTAssertFalse(state.configuration.enabled)
        XCTAssertFalse(state.runs.contains(where: \.active))
        XCTAssertTrue(state.monitoringError?.contains("選び直して") == true)
    }

    func testRetirementImmediatelyFencesReceiptsAndOldCompletionCannotPublishIntoNewOwner() async throws {
        let store = try makeStore()
        let driver = Driver(store: store)
        var owner = "owner"
        let controller = ScreenTimeController(store: store, currentContextKey: { owner }, monitoring: driver, authorization: { .approved })
        try await controller.bindContext(contextKey: owner, dataEpochID: nil)
        let runID = try XCTUnwrap(store.snapshot().runs.first?.id)
        let (entered, release) = blockNextSave(driver)
        defer { release.signal() }
        let configuration = controller.configuration
        let save = Task { try await controller.save(configuration: configuration, isPro: false) }
        await fulfillment(of: [entered], timeout: 5)
        controller.suspendForContextRetirement(contextKey: owner, dataEpochID: nil)
        XCTAssertEqual(controller.negativeGemCount, 0)
        XCTAssertFalse(controller.configuration.enabled)
        try store.record(runID: runID, threshold: 1, now: start.addingTimeInterval(601))
        XCTAssertTrue(try store.pendingLearningReceipts().isEmpty)
        XCTAssertFalse(try store.snapshot().contextIsActive)
        owner = "new-owner"
        let bind = Task { try await controller.bindContext(contextKey: owner, dataEpochID: nil) }
        release.signal()
        do { try await save.value; XCTFail("Retired save must fail") } catch {}
        try await bind.value
        XCTAssertEqual(try store.snapshot().contextKey, "new-owner")
        XCTAssertTrue(controller.isBound(contextKey: "new-owner", dataEpochID: nil))
        XCTAssertEqual(controller.negativeGemCount, 0)
        XCTAssertFalse(controller.isSaving)
    }

    func testRapidTimerPauseResumeRetiresOldRunWhileRegistrationIsBlocked() async throws {
        let store = try makeStore()
        let driver = Driver(store: store)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" }, monitoring: driver, authorization: { .approved })
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        let runID = try XCTUnwrap(store.snapshot().runs.first?.id)
        try store.record(runID: runID, threshold: 1, now: start.addingTimeInterval(601))
        let receipts = try store.pendingLearningReceipts()
        let (entered, release) = blockNextSave(driver)
        defer { release.signal() }
        let configuration = controller.configuration
        let save = Task { try await controller.save(configuration: configuration, isPro: false) }
        await fulfillment(of: [entered], timeout: 5)
        controller.reconcileInBackground(contextKey: "owner", dataEpochID: nil, isPro: false, timerRunning: true)
        controller.reconcileInBackground(contextKey: "owner", dataEpochID: nil, isPro: false, timerRunning: false)
        XCTAssertFalse(try store.snapshot().learningPausedByTimer)
        XCTAssertFalse(try store.snapshot().runs.contains { $0.id == runID && $0.active })
        try store.record(runID: runID, threshold: 2, now: start.addingTimeInterval(1_201))
        XCTAssertEqual(try store.pendingLearningReceipts(), receipts)
        release.signal()
        try await save.value
        await controller.reconcile(isPro: false, timerRunning: false)
        try await controller.waitForPendingOperations()
        XCTAssertFalse(try store.snapshot().runs.contains { $0.id == runID && $0.active })
    }

    func testResetDuringSlowSaveClearsReceiptGateBeforeAwaitingStop() async throws {
        let store = try makeStore()
        let driver = Driver(store: store)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" }, monitoring: driver, authorization: { .approved })
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        let before = try store.snapshot()
        let (entered, release) = blockNextSave(driver)
        defer { release.signal() }
        let configuration = controller.configuration
        let save = Task { try await controller.save(configuration: configuration, isPro: false) }
        await fulfillment(of: [entered], timeout: 5)
        let resetStarted = expectation(description: "Reset has closed the receipt gate")
        let reset = Task { resetStarted.fulfill(); try await controller.resetActivityData() }
        await fulfillment(of: [resetStarted], timeout: 5)
        XCTAssertTrue(controller.isResetting)
        XCTAssertEqual(controller.negativeGemCount, 0)
        XCTAssertNotEqual(try store.snapshot().epoch, before.epoch)
        try store.record(runID: before.runs[0].id, threshold: 1, now: start.addingTimeInterval(601))
        XCTAssertTrue(try store.pendingLearningReceipts().isEmpty)
        release.signal()
        do { try await save.value; XCTFail("Old save must not survive reset") } catch {}
        try await reset.value
        XCTAssertFalse(controller.configuration.enabled)
        XCTAssertNil(controller.monitoringError)
        XCTAssertFalse(controller.isResetting)
        XCTAssertEqual(driver.events.suffix(2), ["synchronized", "stop"])
    }

    func testCompleteEraseDrainsRegistrationAndRejectsQueuedOldBinding() async throws {
        let store = try makeStore()
        let driver = Driver(store: store)
        var owner = "owner"
        let controller = ScreenTimeController(store: store, currentContextKey: { owner }, monitoring: driver, authorization: { .approved })
        try await controller.bindContext(contextKey: owner, dataEpochID: nil)
        let (entered, release) = blockNextSave(driver)
        defer { release.signal() }
        let configuration = controller.configuration
        let save = Task { try await controller.save(configuration: configuration, isPro: false) }
        await fulfillment(of: [entered], timeout: 5)
        owner = "next-owner"
        let bindStarted = expectation(description: "Replacement binding queued")
        let queuedBind = Task { bindStarted.fulfill(); try await controller.bindContext(contextKey: owner, dataEpochID: nil) }
        await fulfillment(of: [bindStarted], timeout: 5)
        let eraseStarted = expectation(description: "Erase has revoked pending binding")
        let erase = Task { eraseStarted.fulfill(); try await controller.eraseAllData() }
        await fulfillment(of: [eraseStarted], timeout: 5)
        XCTAssertFalse(controller.isBound(contextKey: owner, dataEpochID: nil))
        release.signal()
        do { try await save.value; XCTFail("Erased save must fail") } catch {}
        do { try await queuedBind.value; XCTFail("Erased binding must fail") } catch {}
        try await erase.value
        try await controller.waitForPendingOperations()
        let state = try store.snapshot()
        XCTAssertNil(state.contextKey)
        XCTAssertFalse(state.contextIsActive)
        XCTAssertFalse(state.configuration.enabled)
        XCTAssertTrue(state.runs.isEmpty)
        XCTAssertEqual(state.negativeGemCount, 0)
        XCTAssertEqual(driver.events.last, "stop")
    }

    func testConcurrentBindingWaitsForAdmissionAndOldEpochRetirementCannotRetireNewEpoch() async throws {
        let oldEpoch = UUID()
        let newEpoch = UUID()
        let store = try makeStore(epoch: oldEpoch)
        let driver = Driver(store: store)
        let entered = expectation(description: "Binding waits for an old registration to stop")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        driver.onFirstStop = { entered.fulfill(); _ = release.wait(timeout: .now() + 15) }
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" }, monitoring: driver, authorization: { .approved })
        let first = Task { try await controller.bindContext(contextKey: "owner", dataEpochID: newEpoch) }
        await fulfillment(of: [entered], timeout: 5)
        let secondStarted = expectation(description: "Second caller joined the pending binding")
        let second = Task { secondStarted.fulfill(); try await controller.bindContext(contextKey: "owner", dataEpochID: newEpoch) }
        await fulfillment(of: [secondStarted], timeout: 5)
        controller.reload()
        XCTAssertFalse(controller.isBound(contextKey: "owner", dataEpochID: newEpoch))
        XCTAssertEqual(controller.negativeGemCount, 0)
        release.signal()
        try await first.value
        try await second.value
        XCTAssertTrue(controller.isBound(contextKey: "owner", dataEpochID: newEpoch))
        XCTAssertEqual(driver.events.filter { $0 == "stop" }.count, 1)
        controller.suspendForContextRetirement(contextKey: "owner", dataEpochID: oldEpoch)
        try await controller.waitForPendingOperations()
        XCTAssertTrue(controller.isBound(contextKey: "owner", dataEpochID: newEpoch))
        XCTAssertTrue(try store.snapshot().contextIsActive)
    }

    func testFailedBindingCanBeRetriedAfterLedgerRecovery() async throws {
        let store = try makeStore()
        let driver = Driver(store: store)
        let path = try XCTUnwrap(directories.last).appendingPathComponent("ScreenTime/ledger.json")
        let original = try Data(contentsOf: path)
        try Data("corrupt".utf8).write(to: path)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" }, monitoring: driver, authorization: { .approved })
        do { try await controller.bindContext(contextKey: "owner", dataEpochID: nil); XCTFail("Corrupt ledger must not bind") } catch {}
        XCTAssertFalse(controller.isBound(contextKey: "owner", dataEpochID: nil))
        try original.write(to: path)
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        XCTAssertTrue(controller.isBound(contextKey: "owner", dataEpochID: nil))
        XCTAssertEqual(controller.negativeGemCount, 9)
    }
    func testRapidProDowngradeUpgradeRetiresOldLearningRunBeforeDriverReturns() async throws {
        let store = try makeStore()
        // Synthetic opaque values stay in this test's temporary ledger and are
        // passed only to the fake driver; no OS app selection is fabricated.
        let tokens = try (0..<6).map { index in
            try JSONDecoder().decode(ApplicationToken.self, from: JSONEncoder().encode(["data": Data([UInt8(index)])]))
        }
        try store.update { $0.configuration.learningSelection.applicationTokens = Set(tokens) }
        let driver = Driver(store: store)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" }, monitoring: driver, authorization: { .approved })
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        let runID = try XCTUnwrap(store.snapshot().runs.first?.id)
        try store.record(runID: runID, threshold: 1, now: start.addingTimeInterval(601))
        let receipts = try store.pendingLearningReceipts()
        let (entered, release) = blockNextSave(driver)
        defer { release.signal() }
        let configuration = controller.configuration
        let save = Task { try await controller.save(configuration: configuration, isPro: true) }
        await fulfillment(of: [entered], timeout: 5)
        controller.reconcileInBackground(contextKey: "owner", dataEpochID: nil, isPro: false, timerRunning: false)
        controller.reconcileInBackground(contextKey: "owner", dataEpochID: nil, isPro: true, timerRunning: false)
        XCTAssertTrue(try store.snapshot().learningAllowedBySubscription)
        XCTAssertFalse(try store.snapshot().runs.contains { $0.id == runID && $0.active })
        try store.record(runID: runID, threshold: 2, now: start.addingTimeInterval(1_201))
        XCTAssertEqual(try store.pendingLearningReceipts(), receipts)
        release.signal()
        try await save.value
        await controller.reconcile(isPro: true, timerRunning: false)
        try await controller.waitForPendingOperations()
        XCTAssertFalse(try store.snapshot().runs.contains { $0.id == runID && $0.active })
    }

    func testAuthorizationWithoutAdmittedOwnerReportsActionableError() async throws {
        let store = try makeStore()
        let driver = Driver(store: store)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" }, monitoring: driver, authorization: { .notDetermined })
        await controller.requestAuthorization()
        XCTAssertEqual(controller.monitoringError, ScreenTimeError.unboundContext.localizedDescription)
        XCTAssertFalse(controller.isUpdatingMonitoring)
        XCTAssertTrue(driver.events.isEmpty)
    }

}
