import FamilyControls
import Foundation
import ManagedSettings
import SwiftUI
import UIKit
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

    /// Revoking access (iOS Settings → スクリーンタイム → アクセス, or
    /// AuthorizationCenter.revokeAuthorization) returns the status to
    /// .notDetermined, not .denied, and a revocation performed while the app
    /// was not running gives reconcile no transition to react to.
    func testSettledNotDeterminedAuthorizationClearsTheSelectionsAndExplainsWhy() async throws {
        let store = try makeStore()
        let driver = Driver(store: store)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: driver, authorization: { .notDetermined },
                                              authorizationSettlingWindow: 0,
                                              authorizationSettlingObservations: 1)
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)

        // The first observation is the cold-launch window: nothing is touched.
        await controller.invalidateAuthorizationIfRevoked()
        XCTAssertTrue(try store.snapshot().configuration.enabled)
        XCTAssertTrue(try store.snapshot().runs.contains(where: \.active))
        XCTAssertFalse(driver.events.contains("stop"))

        await controller.invalidateAuthorizationIfRevoked()
        try await controller.waitForPendingOperations()
        let state = try store.snapshot()
        XCTAssertFalse(state.configuration.enabled)
        XCTAssertFalse(state.runs.contains(where: \.active))
        XCTAssertTrue(state.monitoringError?.contains("選び直して") == true)
        XCTAssertEqual(controller.monitoringError, state.monitoringError)
        XCTAssertTrue(driver.events.contains("stop"),
                      "Registrations carrying voided tokens must not stay armed")

        // The cleared configuration is not re-invalidated on every later pass.
        await controller.invalidateAuthorizationIfRevoked()
        await controller.invalidateAuthorizationIfRevoked()
        try await controller.waitForPendingOperations()
        XCTAssertEqual(driver.events.filter { $0 == "stop" }.count, 1)
    }

    /// `now` is injectable precisely so the window never depends on how fast
    /// the machine runs the test. Every pass below states its own time, and
    /// the companion test pins the production 10 s constant from the other
    /// side, so neither the default window nor this case is left unmeasured.
    func testTransientNotDeterminedAtColdLaunchKeepsTheSelections() async throws {
        let store = try makeStore()
        let driver = Driver(store: store)
        var status = AuthorizationStatus.notDetermined
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: driver, authorization: { status })
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        // The foreground cadence is 3 s, so a cold launch inside the default
        // 10 s window is four passes. None of them may touch the selections.
        for offset in [0.0, 3, 6, 9] {
            await controller.invalidateAuthorizationIfRevoked(now: base.addingTimeInterval(offset))
            XCTAssertTrue(try store.snapshot().configuration.enabled,
                          "A cold launch must survive the whole settling window (t+\(offset) s)")
        }

        status = .approved
        await controller.invalidateAuthorizationIfRevoked(now: base.addingTimeInterval(12))
        try await controller.waitForPendingOperations()
        let state = try store.snapshot()
        XCTAssertTrue(state.configuration.enabled)
        XCTAssertNil(state.monitoringError)
        XCTAssertTrue(state.runs.contains(where: \.active))
        XCTAssertFalse(driver.events.contains("stop"))
    }

    /// The production default is the one value no other test exercises: the
    /// siblings inject 0. Pin it, so shortening or lengthening the window is a
    /// deliberate edit rather than a silent change to what a revoked
    /// authorization costs the user.
    func testTheDefaultSettlingWindowInvalidatesAfterTenSecondsOfObservation() async throws {
        let store = try makeStore()
        let driver = Driver(store: store)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: driver, authorization: { .notDetermined })
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        for offset in [0.0, 3, 6, 9] {
            await controller.invalidateAuthorizationIfRevoked(now: base.addingTimeInterval(offset))
        }
        try await controller.waitForPendingOperations()
        XCTAssertTrue(try store.snapshot().configuration.enabled,
                      "Nine seconds of observation is inside the 10 s window")

        await controller.invalidateAuthorizationIfRevoked(now: base.addingTimeInterval(12))
        try await controller.waitForPendingOperations()
        let state = try store.snapshot()
        XCTAssertFalse(state.configuration.enabled)
        XCTAssertFalse(state.runs.contains(where: \.active))
        XCTAssertTrue(state.monitoringError?.contains("選び直して") == true)
        XCTAssertTrue(driver.events.contains("stop"))
    }

    /// F5 removed the `.onDisappear` retirement and `taskKey` carries
    /// `scenePhase == .active`, so the 3 s refresh loop is torn down on every
    /// deactivation while `ScreenTimeController.shared` — and the settling
    /// stamp it holds — survives. A stamp left by one interrupted pass must
    /// not let a single post-resume `.notDetermined` read wipe the opaque
    /// selections: that read is exactly the transient value the window exists
    /// to tolerate, and only a new FamilyActivityPicker session could undo it.
    func testAStaleSettlingStampCannotBeSettledByOneObservationAfterAGap() async throws {
        let store = try makeStore()
        let driver = Driver(store: store)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: driver, authorization: { .notDetermined })
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        // One pass, then the scene deactivates and the loop is cancelled.
        await controller.invalidateAuthorizationIfRevoked(now: base)
        XCTAssertTrue(try store.snapshot().configuration.enabled)

        // Two minutes later `.task(id:)` restarts and observes once.
        controller.beginAuthorizationObservation()
        await controller.invalidateAuthorizationIfRevoked(now: base.addingTimeInterval(120))
        try await controller.waitForPendingOperations()
        XCTAssertTrue(try store.snapshot().configuration.enabled,
                      "One post-resume .notDetermined sample must not void the opaque selections")
        XCTAssertTrue(try store.snapshot().runs.contains(where: \.active))
        XCTAssertNil(try store.snapshot().monitoringError)
        XCTAssertFalse(driver.events.contains("stop"))
    }

    /// Even without a restart announcement the window must not be satisfiable
    /// by elapsed wall clock alone: the process can be suspended between two
    /// passes, so the decision needs several consecutive observations too.
    func testTheSettlingWindowNeedsConsecutiveObservationsNotOnlyElapsedTime() async throws {
        let store = try makeStore()
        let driver = Driver(store: store)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: driver, authorization: { .notDetermined })
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        await controller.invalidateAuthorizationIfRevoked(now: base)
        await controller.invalidateAuthorizationIfRevoked(now: base.addingTimeInterval(600))
        try await controller.waitForPendingOperations()
        XCTAssertTrue(try store.snapshot().configuration.enabled,
                      "Ten minutes of wall clock across two samples is not ten seconds of observation")
        XCTAssertFalse(driver.events.contains("stop"))

        // The 3 s foreground cadence supplies the missing observations.
        await controller.invalidateAuthorizationIfRevoked(now: base.addingTimeInterval(603))
        XCTAssertTrue(try store.snapshot().configuration.enabled)
        await controller.invalidateAuthorizationIfRevoked(now: base.addingTimeInterval(606))
        try await controller.waitForPendingOperations()
        XCTAssertFalse(try store.snapshot().configuration.enabled)
        XCTAssertTrue(driver.events.contains("stop"))
    }

    func testDeniedAuthorizationDoesNotWaitForTheSettlingWindow() async throws {
        let store = try makeStore()
        let driver = Driver(store: store)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: driver, authorization: { .denied })
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)

        await controller.invalidateAuthorizationIfRevoked()
        try await controller.waitForPendingOperations()
        let state = try store.snapshot()
        XCTAssertFalse(state.configuration.enabled)
        XCTAssertTrue(state.monitoringError?.contains("選び直して") == true)
        XCTAssertTrue(driver.events.contains("stop"))
    }

    /// Docs/ScreenTimeGems.md promises that a confirmed revocation clears the
    /// stale selections on BOTH lanes. The check used to require
    /// `configuration.enabled`, so a user who had merely switched recording
    /// off kept opaque tokens the OS had already voided: re-allowing access
    /// and turning recording back on then registered events that could never
    /// fire, and no gem would ever arrive again.
    func testARevocationWhileRecordingIsOffStillClearsTheVoidedSelections() async throws {
        let store = try makeStore()
        // Synthetic opaque values stay in this test's temporary ledger; no OS
        // app selection is fabricated and nothing reaches Family Controls.
        let token = try JSONDecoder().decode(
            ApplicationToken.self, from: JSONEncoder().encode(["data": Data([7])]))
        try store.update { state in
            state.configuration.enabled = false
            state.configuration.learningSelection.applicationTokens = [token]
            for index in state.runs.indices { state.runs[index].active = false }
        }
        let driver = Driver(store: store)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: driver, authorization: { .notDetermined },
                                              authorizationSettlingWindow: 0,
                                              authorizationSettlingObservations: 1)
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)

        await controller.invalidateAuthorizationIfRevoked()
        await controller.invalidateAuthorizationIfRevoked()
        try await controller.waitForPendingOperations()
        let state = try store.snapshot()
        XCTAssertTrue(state.configuration.learningSelection.applicationTokens.isEmpty,
                      "A revocation voids the tokens whether or not recording was on")
        XCTAssertTrue(state.monitoringError?.contains("選び直して") == true)
        XCTAssertTrue(driver.events.contains("stop"))
    }

    /// A user who never granted access has the same .notDetermined status. The
    /// ledger has nothing an approval could have written, so nothing is wiped
    /// and no 解除 message is shown.
    func testANeverEnabledLedgerIsNotTreatedAsARevocation() async throws {
        let store = try makeStore()
        try store.update { $0.configuration.enabled = false }
        let driver = Driver(store: store)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: driver, authorization: { .notDetermined },
                                              authorizationSettlingWindow: 0,
                                              authorizationSettlingObservations: 1)
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)

        await controller.invalidateAuthorizationIfRevoked()
        await controller.invalidateAuthorizationIfRevoked()
        try await controller.waitForPendingOperations()
        XCTAssertNil(try store.snapshot().monitoringError)
        XCTAssertNil(controller.monitoringError)
        XCTAssertFalse(driver.events.contains("stop"))
    }

    /// PomoGemApp declares an owner boundary — an Apple Account change
    /// (accountIdentityDidChange) or an accepted storage transfer
    /// (requireStorageTransferRelaunch) — and drops RootView in the same turn,
    /// with no new session mounting afterwards. The no-argument retirement is
    /// what those two paths call; ordinary backgrounding must not use it.
    func testOwnerBoundaryRetirementFencesTheLedgerAndStopsTheRegistrations() async throws {
        let store = try makeStore()
        let driver = Driver(store: store)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: driver, authorization: { .approved })
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        let runID = try XCTUnwrap(store.snapshot().runs.first?.id)

        controller.suspendForContextRetirement()
        try await controller.waitForPendingOperations()

        let state = try store.snapshot()
        XCTAssertFalse(state.contextIsActive, "The extension must stop recording for a retired owner")
        XCTAssertFalse(state.runs.contains(where: \.active))
        XCTAssertFalse(controller.isBoundToContext)
        XCTAssertTrue(driver.events.contains("stop"),
                      "The activities of a retired owner must not stay registered")
        try store.record(runID: runID, threshold: 1, now: start.addingTimeInterval(601))
        XCTAssertTrue(try store.pendingLearningReceipts().isEmpty)
        XCTAssertEqual(try store.snapshot().negativeGemCount, 9)
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

/// The root Screen Time modifier lives inside the cloud persistence session,
/// which PomoGemApp drops on every ordinary backgrounding. Collection itself
/// belongs to the OS extension, so view teardown must not retire the context.
@MainActor
final class ScreenTimeIntegrationLifecycleTests: XCTestCase {
    private final class Driver: ScreenTimeMonitoringDriving {
        let store: ScreenTimeStore
        private let lock = NSLock()
        private var stops = 0

        init(store: ScreenTimeStore) { self.store = store }
        var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
        func stop() { lock.lock(); stops += 1; lock.unlock() }
        func invalidateAuthorizationIfNeeded() throws {}
        func synchronize(now: Date) throws -> Bool {
            try store.withMonitoringLock { try store.snapshot().runs.contains(where: \.active) }
        }
    }

    private final class MountProbe: ObservableObject {
        @Published var isMounted = true
        var onUnmounted: (() -> Void)?
    }

    private struct Host: View {
        @ObservedObject var probe: MountProbe
        let controller: ScreenTimeController
        let contextKey: String
        let dataEpochID: UUID?

        var body: some View {
            Group {
                if probe.isMounted {
                    Color.clear
                        .modifier(ScreenTimeIntegrationModifier(
                            isReady: true, timerPresented: false,
                            contextKey: contextKey, dataEpochID: dataEpochID,
                            controller: controller
                        ))
                        .onDisappear { probe.onUnmounted?() }
                } else {
                    Color.clear
                }
            }
            .environment(\.scenePhase, .active)
        }
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        super.tearDown()
    }

    private func makeStore(owner: String, epoch: UUID) throws -> ScreenTimeStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        let store = ScreenTimeStore(directory: directory)
        var state = ScreenTimeState()
        state.contextKey = owner
        state.dataEpochID = epoch
        state.contextIsActive = true
        state.configuration.enabled = true
        state.configuration.themeID = UUID()
        state.runs = [ScreenTimeRun(
            lane: .learning, dayStart: start, dayEnd: start.addingTimeInterval(86_400),
            startedAt: start, timeZoneID: "UTC", includesPastActivity: false,
            themeID: state.configuration.themeID
        )]
        try store.update { $0 = state }
        return store
    }

    private func waitUntil(
        timeout: TimeInterval = 10, _ description: String, _ condition: () throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting: \(description)")
    }

    func testOrdinaryUnmountKeepsTheContextArmedWhileTheAppIsNotRunning() async throws {
        let owner = AccountScopedLocalState.defaultsKey(base: "screen-time-owner")
        let epoch = UUID()
        let store = try makeStore(owner: owner, epoch: epoch)
        let driver = Driver(store: store)
        let controller = ScreenTimeController(
            store: store, currentContextKey: { owner }, monitoring: driver, authorization: { .approved }
        )
        let runID = try XCTUnwrap(store.snapshot().runs.first?.id)
        let probe = MountProbe()
        let unmounted = expectation(description: "SwiftUI removed the Screen Time host view")
        unmounted.assertForOverFulfill = false
        probe.onUnmounted = { unmounted.fulfill() }

        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Host(
            probe: probe, controller: controller, contextKey: owner, dataEpochID: epoch
        ))
        window.isHidden = false
        defer {
            probe.onUnmounted = nil
            window.isHidden = true
            window.rootViewController = nil
        }

        try await waitUntil("the modifier binds the context") {
            controller.isBound(contextKey: owner, dataEpochID: epoch)
        }
        try await controller.waitForPendingOperations()
        XCTAssertTrue(try store.snapshot().runs.contains { $0.id == runID && $0.active })

        // PomoGemApp sets session = nil on .background, which removes RootView.
        probe.isMounted = false
        await fulfillment(of: [unmounted], timeout: 5)
        try await Task.sleep(for: .milliseconds(300))
        try await controller.waitForPendingOperations()

        let state = try store.snapshot()
        XCTAssertTrue(state.contextIsActive, "Background collection must survive the view leaving the screen")
        XCTAssertTrue(state.runs.contains { $0.id == runID && $0.active })
        XCTAssertEqual(driver.stopCount, 0, "Leaving the foreground must not stop the registered activities")
        XCTAssertTrue(controller.isBound(contextKey: owner, dataEpochID: epoch))

        // A threshold that arrives in the extension while the app is away.
        try store.record(runID: runID, threshold: 1, now: start.addingTimeInterval(601))
        XCTAssertEqual(try store.pendingLearningReceipts().count, 1)

        probe.isMounted = true
        try await waitUntil("the same binding is restored on the next foreground") {
            controller.isBound(contextKey: owner, dataEpochID: epoch)
        }
        try await controller.waitForPendingOperations()
        let resumed = try store.snapshot()
        XCTAssertEqual(resumed.runs.first?.id, runID, "The foreground must reuse the run the extension counted against")
        XCTAssertTrue(resumed.contextIsActive)
        XCTAssertEqual(driver.stopCount, 0)
    }

    /// 147da0d compensated for the removed `.onDisappear` retirement with two
    /// explicit call sites in PomoGemApp (accountIdentityDidChange and
    /// requireStorageTransferRelaunch). Nothing pinned the rule those sites
    /// encode, so the F5 removal could fail closed→open without any test
    /// noticing. Both now go through ScreenTimeOwnerBoundaryPolicy, and this
    /// drives it against a mounted host and a real temporary ledger — both
    /// directions, since the harmful mistake is retiring on an ordinary
    /// backgrounding just as much as not retiring on an owner boundary.
    func testOnlyAnOwnerBoundaryRetiresTheLeaseOfAMountedHost() async throws {
        let owner = AccountScopedLocalState.defaultsKey(base: "screen-time-owner")
        let epoch = UUID()
        let store = try makeStore(owner: owner, epoch: epoch)
        let driver = Driver(store: store)
        let controller = ScreenTimeController(
            store: store, currentContextKey: { owner }, monitoring: driver, authorization: { .approved }
        )
        let runID = try XCTUnwrap(store.snapshot().runs.first?.id)
        let probe = MountProbe()
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Host(
            probe: probe, controller: controller, contextKey: owner, dataEpochID: epoch
        ))
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitUntil("the modifier binds the context") {
            controller.isBound(contextKey: owner, dataEpochID: epoch)
        }
        try await controller.waitForPendingOperations()

        for transition in ScreenTimeOwnerBoundaryPolicy.HostTransition.allCases
        where !ScreenTimeOwnerBoundaryPolicy.retiresLease(for: transition) {
            ScreenTimeOwnerBoundaryPolicy.retire(for: transition, on: controller)
            try await controller.waitForPendingOperations()
            XCTAssertTrue(try store.snapshot().contextIsActive,
                          "\(transition) leaves the OS collecting; the lease must stay armed")
            XCTAssertTrue(try store.snapshot().runs.contains { $0.id == runID && $0.active })
            XCTAssertEqual(driver.stopCount, 0)
            XCTAssertTrue(controller.isBound(contextKey: owner, dataEpochID: epoch))
        }

        ScreenTimeOwnerBoundaryPolicy.retire(for: .accountIdentityChange, on: controller)
        try await controller.waitForPendingOperations()
        let state = try store.snapshot()
        XCTAssertFalse(state.contextIsActive,
                       "A changed owner must fence the ledger before RootView disappears")
        XCTAssertFalse(state.runs.contains(where: \.active))
        XCTAssertFalse(controller.isBound(contextKey: owner, dataEpochID: epoch))
        XCTAssertTrue(ScreenTimeOwnerBoundaryPolicy.retiresLease(for: .storageTransferRelaunch),
                      "The other call site relies on the same rule")
    }
}

/// The settings screen seeds its draft from the controller. While the context
/// is not bound the controller publishes an EMPTY configuration, and saving
/// that would destroy opaque application tokens only a new picker session can
/// restore.
@MainActor
final class ScreenTimeSettingsDraftTests: XCTestCase {
    private final class Driver: ScreenTimeMonitoringDriving {
        let store: ScreenTimeStore
        init(store: ScreenTimeStore) { self.store = store }
        func stop() {}
        func invalidateAuthorizationIfNeeded() throws {}
        func synchronize(now: Date) throws -> Bool {
            try store.withMonitoringLock { try store.snapshot().runs.contains(where: \.active) }
        }
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        super.tearDown()
    }

    private func makeStore(owner: String = "owner") throws -> ScreenTimeStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        let store = ScreenTimeStore(directory: directory)
        var state = ScreenTimeState()
        state.contextKey = owner
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

    func testDraftIsNeverSeededFromAnUnboundController() {
        for hasUserEdits in [false, true] {
            for draftIsEmpty in [false, true] {
                XCTAssertFalse(ScreenTimeDraftPolicy.shouldReseed(
                    bound: false, hasUserEdits: hasUserEdits, draftIsEmpty: draftIsEmpty
                ), "An unbound controller publishes an empty configuration")
            }
        }
    }

    func testBindingSeedsTheDraftOnlyWhileTheUserHasNotEdited() {
        XCTAssertTrue(ScreenTimeDraftPolicy.shouldReseed(bound: true, hasUserEdits: false, draftIsEmpty: true))
        XCTAssertTrue(ScreenTimeDraftPolicy.shouldReseed(bound: true, hasUserEdits: false, draftIsEmpty: false))
        XCTAssertFalse(ScreenTimeDraftPolicy.shouldReseed(bound: true, hasUserEdits: true, draftIsEmpty: false),
                       "Edits the user can see must survive a late binding")
        XCTAssertTrue(ScreenTimeDraftPolicy.shouldReseed(bound: true, hasUserEdits: true, draftIsEmpty: true),
                      "An empty draft has nothing to lose and would otherwise stay empty")
    }

    func testIsBoundToContextFollowsAdmissionRetirementAndErase() async throws {
        let store = try makeStore()
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: Driver(store: store), authorization: { .approved })
        XCTAssertFalse(controller.isBoundToContext, "A freshly created controller has no lease yet")

        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        XCTAssertTrue(controller.isBoundToContext)

        // Reset keeps the same owner bound; 保存 must stay available afterwards.
        try await controller.resetActivityData()
        XCTAssertTrue(controller.isBoundToContext)

        controller.suspendForContextRetirement(contextKey: "owner", dataEpochID: nil)
        XCTAssertFalse(controller.isBoundToContext)

        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        XCTAssertTrue(controller.isBoundToContext)
        try await controller.eraseAllData()
        XCTAssertFalse(controller.isBoundToContext)
    }

    func testFailedBindingLeavesTheContextUnbound() async throws {
        let store = try makeStore()
        let path = try XCTUnwrap(directories.last).appendingPathComponent("ScreenTime/ledger.json")
        let original = try Data(contentsOf: path)
        try Data("corrupt".utf8).write(to: path)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: Driver(store: store), authorization: { .approved })
        do {
            try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
            XCTFail("A corrupt ledger must not bind")
        } catch {}
        XCTAssertFalse(controller.isBoundToContext)
        XCTAssertEqual(controller.configuration, ScreenTimeConfiguration())

        try original.write(to: path)
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        XCTAssertTrue(controller.isBoundToContext)
        XCTAssertTrue(controller.configuration.enabled)
    }

    /// A context that can never bind — no App Group container, an unreadable
    /// ledger — leaves isBoundToContext false forever. reload() clears
    /// monitoringError with the rest of the published state, so without a
    /// separate published reason the settings screen shows a disabled 保存 and
    /// no explanation at all.
    func testAFailedBindingPublishesTheReasonAndASuccessfulOneClearsIt() async throws {
        let store = try makeStore()
        let path = try XCTUnwrap(directories.last).appendingPathComponent("ScreenTime/ledger.json")
        let original = try Data(contentsOf: path)
        try Data("corrupt".utf8).write(to: path)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: Driver(store: store), authorization: { .approved })
        do {
            try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
            XCTFail("A corrupt ledger must not bind")
        } catch {}
        XCTAssertNil(controller.monitoringError, "The published state is cleared for an unbound context")
        XCTAssertEqual(controller.bindingError, ScreenTimeError.corruptedState.localizedDescription)

        try original.write(to: path)
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        XCTAssertNil(controller.bindingError)
    }

    func testAMissingAppGroupContainerPublishesTheUnavailableReason() async throws {
        let store = ScreenTimeStore(directory: nil)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: Driver(store: store), authorization: { .approved })
        do {
            try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
            XCTFail("A missing App Group container must not bind")
        } catch {}
        XCTAssertFalse(controller.isBoundToContext)
        XCTAssertEqual(controller.bindingError, ScreenTimeError.unavailable.localizedDescription)
    }

    /// Revoked permission, a removed theme or a context that can never bind
    /// must never trap the user with the feature switched on.
    func testSwitchingTheFeatureOffIsNeverBlockedByAnUnboundContext() {
        XCTAssertTrue(ScreenTimeDraftPolicy.blocksSave(bound: false, draftEnabled: true),
                      "An enabling save may be built on the controller's empty published configuration")
        XCTAssertFalse(ScreenTimeDraftPolicy.blocksSave(bound: false, draftEnabled: false))
        XCTAssertFalse(ScreenTimeDraftPolicy.blocksSave(bound: true, draftEnabled: true))
        XCTAssertFalse(ScreenTimeDraftPolicy.blocksSave(bound: true, draftEnabled: false))
    }

    /// 保存 staying enabled for an OFF draft is an explanation, not a save that
    /// works: `save()` begins with `boundLease()`, which throws for every save
    /// while unbound. The footer must describe that and not promise otherwise.
    func testTheUnboundFooterDoesNotPromiseASaveTheControllerAlwaysRefuses() async throws {
        XCTAssertFalse(ScreenTimeDraftPolicy.unboundFooterMessage.contains("保存できます"),
                       "No save succeeds while the context is unbound")
        XCTAssertFalse(ScreenTimeDraftPolicy.blocksSave(bound: false, draftEnabled: false),
                       "The button stays pressable so the reason can be shown")

        let store = try makeStore()
        let driver = Driver(store: store)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: driver, authorization: { .approved })
        XCTAssertFalse(controller.isBoundToContext)
        var off = ScreenTimeConfiguration()
        off.enabled = false
        do {
            try await controller.save(configuration: off, isPro: false)
            XCTFail("An unbound save must not succeed, not even one that only turns recording off")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           ScreenTimeError.unboundContext.localizedDescription)
        }
    }
}
