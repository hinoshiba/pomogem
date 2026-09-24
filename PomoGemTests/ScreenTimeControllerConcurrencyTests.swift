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

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        return directory
    }

    private func makeStore(owner: String = "owner", epoch: UUID? = nil, in directory: URL? = nil) throws -> ScreenTimeStore {
        let directory = directory ?? makeDirectory()
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

        await controller.reconcile(isPro: false, learningPause: .none)
        try await controller.waitForPendingOperations()
        var state = try store.snapshot()
        XCTAssertTrue(state.configuration.enabled)
        XCTAssertNil(state.monitoringError)
        XCTAssertTrue(state.runs.contains { $0.id == runID && $0.active })

        status = .denied
        await controller.reconcile(isPro: false, learningPause: .none)
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
        // Recording is now off, and the Settings row still says it stopped.
        XCTAssertEqual(ScreenTimeRowStatus(
            isBound: controller.isBoundToContext, enabled: controller.configuration.enabled,
            isMonitoring: controller.isMonitoring, monitoringError: controller.monitoringError,
            learningStoppedByFreeLimit: controller.learningStoppedByFreeLimit,
            themeRemoved: controller.learningThemeWasRemoved
        ), .needsAttention)

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
        controller.reconcileInBackground(contextKey: "owner", dataEpochID: nil, isPro: false, learningPause: .indefinite)
        controller.reconcileInBackground(contextKey: "owner", dataEpochID: nil, isPro: false, learningPause: .none)
        XCTAssertFalse(try store.snapshot().learningPausedByTimer)
        XCTAssertFalse(try store.snapshot().runs.contains { $0.id == runID && $0.active })
        try store.record(runID: runID, threshold: 2, now: start.addingTimeInterval(1_201))
        XCTAssertEqual(try store.pendingLearningReceipts(), receipts)
        release.signal()
        try await save.value
        await controller.reconcile(isPro: false, learningPause: .none)
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

    /// screentime-06: 「表示中の記録をリセット」 moves the same owner to a new
    /// reset generation. The runs, black stones and unimported receipts belong
    /// to the old one and go; the app selections, theme and recording switch
    /// are the user's setup and stay, as the reset dialog promises.
    func testANewResetGenerationForTheSameOwnerKeepsTheSetupButNothingItProduced() async throws {
        let oldEpoch = UUID()
        let newEpoch = UUID()
        let store = try makeStore(epoch: oldEpoch)
        let tokens = try (0..<2).map { index in
            try JSONDecoder().decode(ApplicationToken.self, from: JSONEncoder().encode(["data": Data([0x44, UInt8(index)])]))
        }
        try store.update { $0.configuration.learningSelection.applicationTokens = Set(tokens) }
        let old = try store.snapshot()
        let oldRunID = try XCTUnwrap(old.runs.first?.id)
        try store.record(runID: oldRunID, threshold: 1, now: start.addingTimeInterval(601))
        XCTAssertFalse(try store.pendingLearningReceipts().isEmpty)
        let driver = Driver(store: store)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" }, monitoring: driver, authorization: { .approved })

        try await controller.bindContext(contextKey: "owner", dataEpochID: newEpoch)
        let rebound = try store.snapshot()
        XCTAssertEqual(rebound.configuration, old.configuration)
        XCTAssertTrue(rebound.configuration.enabled)
        XCTAssertEqual(rebound.dataEpochID, newEpoch)
        XCTAssertNotEqual(rebound.epoch, old.epoch, "Receipts of the new generation need new identities")
        XCTAssertTrue(rebound.runs.isEmpty)
        XCTAssertEqual(rebound.negativeGemCount, 0)
        XCTAssertTrue(try store.pendingLearningReceipts().isEmpty)
        XCTAssertEqual(driver.events.filter { $0 == "stop" }.count, 1, "Old registrations must come down")
        XCTAssertEqual(controller.configuration, old.configuration)

        // A late callback for the old generation's run awards nothing.
        XCTAssertFalse(try store.record(runID: oldRunID, threshold: 2, now: start.addingTimeInterval(1_201)))
    }

    func testADifferentOwnerStillStartsWithAnEmptySetup() async throws {
        let store = try makeStore(owner: "previous-owner")
        let driver = Driver(store: store)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" }, monitoring: driver, authorization: { .approved })
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        let state = try store.snapshot()
        XCTAssertEqual(state.contextKey, "owner")
        XCTAssertEqual(state.configuration, ScreenTimeConfiguration())
        XCTAssertTrue(state.runs.isEmpty)
        XCTAssertEqual(state.negativeGemCount, 0)
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
        controller.reconcileInBackground(contextKey: "owner", dataEpochID: nil, isPro: false, learningPause: .none)
        controller.reconcileInBackground(contextKey: "owner", dataEpochID: nil, isPro: true, learningPause: .none)
        XCTAssertTrue(try store.snapshot().learningAllowedBySubscription)
        XCTAssertFalse(try store.snapshot().runs.contains { $0.id == runID && $0.active })
        try store.record(runID: runID, threshold: 2, now: start.addingTimeInterval(1_201))
        XCTAssertEqual(try store.pendingLearningReceipts(), receipts)
        release.signal()
        try await save.value
        await controller.reconcile(isPro: true, learningPause: .none)
        try await controller.waitForPendingOperations()
        XCTAssertFalse(try store.snapshot().runs.contains { $0.id == runID && $0.active })
    }

    /// settings-01: at a cold launch the forced first pass can run before
    /// StoreKit has answered. "Not known yet" used to read as "free", which
    /// retired a Pro user's learning run and lost its unfinished 10 minutes.
    /// An unknown entitlement now keeps the gate; the real answer still
    /// decides, so a genuine downgrade retires exactly as before.
    func testUnresolvedProEntitlementNeverRetiresTheLearningRunButARealDowngradeDoes() async throws {
        let store = try makeStore()
        let tokens = try (0..<6).map { index in
            try JSONDecoder().decode(ApplicationToken.self, from: JSONEncoder().encode(["data": Data([UInt8(index)])]))
        }
        try store.update { $0.configuration.learningSelection.applicationTokens = Set(tokens) }
        let driver = Driver(store: store)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" }, monitoring: driver, authorization: { .approved })
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        let runID = try XCTUnwrap(store.snapshot().runs.first?.id)

        await controller.reconcile(isPro: nil, learningPause: .none)
        try await controller.waitForPendingOperations()
        var state = try store.snapshot()
        XCTAssertTrue(state.learningAllowedBySubscription)
        XCTAssertTrue(state.runs.contains { $0.id == runID && $0.active })
        XCTAssertNil(controller.monitoringError, "A Pro user must not be shown the free-plan limit")
        XCTAssertFalse(controller.learningStoppedByFreeLimit)

        await controller.reconcile(isPro: false, learningPause: .none)
        try await controller.waitForPendingOperations()
        state = try store.snapshot()
        XCTAssertFalse(state.learningAllowedBySubscription)
        XCTAssertFalse(state.runs.contains { $0.id == runID && $0.active })
        XCTAssertTrue(controller.learningStoppedByFreeLimit,
                      "The page and the Settings row read the stop from the ledger's gate")
        XCTAssertEqual(controller.monitoringError, ScreenTimeError.freeApplicationLimit.localizedDescription)
        XCTAssertTrue(controller.monitoringError?.contains("勉強アプリ") == true)

        // Unknown again (a later process before StoreKit answers) keeps the
        // closed gate closed: nil can only keep or relax, never grant Pro.
        await controller.reconcile(isPro: nil, learningPause: .none)
        XCTAssertFalse(try store.snapshot().learningAllowedBySubscription)
    }

    func testTheUnresolvedSubscriptionGateOnlyKeepsOrRelaxes() {
        typealias Policy = ScreenTimePolicy
        for previous in [true, false] {
            XCTAssertTrue(Policy.learningAllowedBySubscription(isPro: true, learningApplicationCount: 50, previouslyAllowed: previous))
            XCTAssertFalse(Policy.learningAllowedBySubscription(isPro: false, learningApplicationCount: 6, previouslyAllowed: previous))
            XCTAssertTrue(Policy.learningAllowedBySubscription(isPro: false, learningApplicationCount: 5, previouslyAllowed: previous))
            XCTAssertTrue(Policy.learningAllowedBySubscription(isPro: nil, learningApplicationCount: 5, previouslyAllowed: previous))
            XCTAssertEqual(Policy.learningAllowedBySubscription(isPro: nil, learningApplicationCount: 6, previouslyAllowed: previous), previous)
        }
    }

    /// screentime-08: the black stones could only be cleared by the full
    /// reset, which also deletes both app selections. Clearing them alone
    /// keeps the setup and the runs, so nothing is re-registered and the next
    /// threshold of the same run counts only the minutes after it.
    func testClearingBlackStonesKeepsTheSetupAndCountsOnlyNewMinutesAfterwards() async throws {
        let store = try makeStore()
        let distraction = ScreenTimeRun(
            lane: .distraction, dayStart: start, dayEnd: start.addingTimeInterval(86_400),
            startedAt: start, timeZoneID: "UTC", includesPastActivity: false, themeID: nil
        )
        try store.update { $0.runs.append(distraction) }
        try store.record(runID: distraction.id, threshold: 3, now: start.addingTimeInterval(1_801))
        let before = try store.snapshot()
        XCTAssertEqual(before.negativeGemCount, 12)
        let driver = Driver(store: store)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" }, monitoring: driver, authorization: { .approved })
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)

        try controller.clearBlackStones()
        let cleared = try store.snapshot()
        XCTAssertEqual(cleared.negativeGemCount, 0)
        XCTAssertEqual(controller.negativeGemCount, 0)
        XCTAssertEqual(cleared.configuration, before.configuration)
        XCTAssertEqual(cleared.runs, before.runs, "Runs and their counted thresholds stay as they were")
        XCTAssertEqual(cleared.epoch, before.epoch)
        XCTAssertTrue(driver.events.isEmpty, "Clearing must not touch the OS registration")

        try store.record(runID: distraction.id, threshold: 4, now: start.addingTimeInterval(2_401))
        controller.reload()
        XCTAssertEqual(controller.negativeGemCount, 1, "Only the ten minutes after the clear count")
    }

    // MARK: - the diagnostics mirror

    /// The monitor extension counts the callbacks, but it cannot write into
    /// the app's container and the App Group ledger it does write cannot be
    /// pulled off a phone — the 2026-09-20/21 audit read none of it. So the
    /// app mirrors on its own passes: a save (which synchronizes) and every
    /// foreground reload.
    func testEveryReloadAndSynchronizePassMirrorsTheDiagnosticsForADeviceAudit() async throws {
        let store = try makeStore()
        let driver = Driver(store: store)
        let mirror = ScreenTimeDiagnosticsMirror(directory: makeDirectory(), heartbeat: 0)
        let controller = ScreenTimeController(
            store: store, currentContextKey: { "owner" }, monitoring: driver,
            authorization: { .approved }, diagnosticsMirror: mirror
        )
        let url = try XCTUnwrap(mirror.fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "Nothing is mirrored before an owner is admitted")

        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)

        var report = try Self.mirroredReport(at: url)
        XCTAssertTrue(report.configurationEnabled)
        XCTAssertTrue(report.contextIsActive)
        XCTAssertEqual(report.learning.activeRuns, 1)
        XCTAssertEqual(report.distraction.activeRuns, 0)
        XCTAssertNil(report.counters, "This ledger has never counted a callback")

        // What the extension writes into the ledger while the app is away
        // reaches the mirror on the app's next reload, not before.
        try store.update { $0.countIntervalCallback(kind: .lane, phase: .start, now: Date()) }
        controller.reload()
        report = try Self.mirroredReport(at: url)
        XCTAssertEqual(report.counters?.laneIntervalStarts, 1)
        XCTAssertEqual(report.counters?.thresholds, 0)
        XCTAssertEqual(report.counters?.generation, 0)

        // A save goes through synchronize, which ends in the same reload.
        var configuration = controller.configuration
        configuration.enabled = false
        try await controller.save(configuration: configuration, isPro: false)
        report = try Self.mirroredReport(at: url)
        XCTAssertFalse(report.configurationEnabled)
        XCTAssertEqual(report.learning.activeRuns, 0)
        XCTAssertEqual(report.counters?.laneIntervalStarts, 1)
    }

    /// Mirroring must not be what creates evidence, the same rule the
    /// extension's counting follows: with no ledger on disk there is nothing
    /// to copy, and an empty file would read as "the ledger says nothing".
    func testTheMirrorWritesNothingWhenTheLedgerIsMissing() async throws {
        let ledgerDirectory = makeDirectory()
        let store = try makeStore(in: ledgerDirectory)
        let driver = Driver(store: store)
        let mirror = ScreenTimeDiagnosticsMirror(directory: makeDirectory(), heartbeat: 0)
        let controller = ScreenTimeController(
            store: store, currentContextKey: { "owner" }, monitoring: driver,
            authorization: { .approved }, diagnosticsMirror: mirror
        )
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        let url = try XCTUnwrap(mirror.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // `ScreenTimeStore` keeps its ledger in a `ScreenTime` subdirectory.
        try FileManager.default.removeItem(
            at: ledgerDirectory.appendingPathComponent("ScreenTime/ledger.json")
        )
        try FileManager.default.removeItem(at: url)
        controller.reload()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(store.ledgerExists, "A read-only mirror never creates a ledger either")
    }

    private static func mirroredReport(at url: URL) throws -> ScreenTimeDiagnosticsReport {
        try JSONDecoder().decode(ScreenTimeDiagnosticsReport.self, from: Data(contentsOf: url))
    }

    func testCompleteDeletionRemovesTheAppContainerDiagnosticsUntilANewOwnerBinds() async throws {
        let store = try makeStore()
        try store.update { $0.countThresholdCallback(.recorded, now: start) }
        let mirror = ScreenTimeDiagnosticsMirror(directory: makeDirectory())
        let controller = ScreenTimeController(
            store: store, currentContextKey: { "owner" }, monitoring: Driver(store: store),
            authorization: { .approved }, diagnosticsMirror: mirror
        )
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        let url = try XCTUnwrap(mirror.fileURL)
        XCTAssertEqual(try Self.mirroredReport(at: url).counters?.thresholdsRecorded, 1)

        try await controller.eraseAllData()
        controller.reload()
        try await controller.waitForPendingOperations()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "Complete deletion must erase callback times and counts in both containers")
        XCTAssertNil(try store.snapshot().callbackCounters)
        XCTAssertFalse(controller.isBoundToContext)

        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        XCTAssertNil(try Self.mirroredReport(at: url).counters,
                     "Rebinding must not restore the deleted usage history")
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

    /// critic-02: each Family Controls refusal names what to fix, the message
    /// outlives the three-second reload, and closing Apple's sheet says nothing.
    func testEachAuthorizationRefusalExplainsItsOwnFixAndSurvivesReload() async throws {
        let cases: [(FamilyControlsError, ScreenTimeAuthorizationFailure?)] = [
            (.authorizationCanceled, nil),
            (.authenticationMethodUnavailable, .passcodeRequired),
            (.invalidAccountType, .accountNotSupported),
            (.networkError, .offline),
            (.authorizationConflict, .conflictingApp),
            (.restricted, .restricted),
            (.unavailable, .other),
            (.invalidArgument, .other)
        ]
        for (error, expected) in cases {
            let store = try makeStore()
            let driver = Driver(store: store)
            let controller = ScreenTimeController(
                store: store, currentContextKey: { "owner" }, monitoring: driver,
                authorization: { .notDetermined },
                requestIndividualAuthorization: { throw error }
            )
            try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
            await controller.requestAuthorization()
            XCTAssertEqual(controller.authorizationFailure, expected, "\(error)")
            controller.reload()
            XCTAssertEqual(controller.authorizationFailure, expected, "The reload loop must not erase it")
            XCTAssertFalse(controller.isUpdatingMonitoring)
        }
        XCTAssertEqual(ScreenTimeAuthorizationFailure(CancellationError()), .other)
        for failure in [ScreenTimeAuthorizationFailure.passcodeRequired, .accountNotSupported, .offline,
                        .conflictingApp, .restricted, .other] {
            XCTAssertFalse(failure.message.isEmpty)
        }
        XCTAssertTrue(ScreenTimeAuthorizationFailure.passcodeRequired.message.contains("パスコード"))
        XCTAssertTrue(ScreenTimeAuthorizationFailure.accountNotSupported.message.contains("Apple Account"))
        XCTAssertTrue(ScreenTimeAuthorizationFailure.offline.message.contains("インターネット"))
        XCTAssertTrue(ScreenTimeAuthorizationFailure.passcodeRequired.fixIsInSettingsApp)
        XCTAssertFalse(ScreenTimeAuthorizationFailure.offline.fixIsInSettingsApp)
    }

    func testAGrantedRequestClearsTheEarlierRefusal() async throws {
        let store = try makeStore()
        let driver = Driver(store: store)
        var status = AuthorizationStatus.notDetermined
        var answer: Error? = FamilyControlsError.networkError
        let controller = ScreenTimeController(
            store: store, currentContextKey: { "owner" }, monitoring: driver,
            authorization: { status },
            requestIndividualAuthorization: {
                if let answer { throw answer }
                status = .approved
            }
        )
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        await controller.requestAuthorization()
        XCTAssertEqual(controller.authorizationFailure, .offline)
        answer = nil
        await controller.requestAuthorization()
        XCTAssertNil(controller.authorizationFailure)
        XCTAssertTrue(controller.authorizationGranted)
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
    private enum DriverError: Error { case refused }

    private final class Driver: ScreenTimeMonitoringDriving {
        let store: ScreenTimeStore
        /// Stands in for DeviceActivity refusing the registration.
        var refusesRegistration = false
        init(store: ScreenTimeStore) { self.store = store }
        func stop() {}
        func invalidateAuthorizationIfNeeded() throws {}
        func synchronize(now: Date) throws -> Bool {
            if refusesRegistration { throw DriverError.refused }
            return try store.withMonitoringLock { try store.snapshot().runs.contains(where: \.active) }
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

    /// screentime-02: the switch is off by default, and a first setup saved
    /// with it off stored everything and recorded nothing behind a success
    /// toast. Picking apps on a first setup switches it on; nothing else does.
    func testAFirstPickSwitchesRecordingOnButNeverOverridesAnExistingChoice() throws {
        let theme = UUID()
        let two = selection(count: 2, seed: 0x61)
        let empty = FamilyActivitySelection(includeEntireCategory: false)

        let first = ScreenTimeDraftPolicy.applying(two, toLearningLane: true, in: ScreenTimeConfiguration(),
                                                   authorized: true, onlyThemeID: theme)
        XCTAssertTrue(first.enabled)
        XCTAssertEqual(first.learningSelection, two)
        XCTAssertEqual(first.themeID, theme, "With one theme there is only one sensible destination")

        let distractionFirst = ScreenTimeDraftPolicy.applying(two, toLearningLane: false, in: ScreenTimeConfiguration(),
                                                              authorized: true, onlyThemeID: theme)
        XCTAssertTrue(distractionFirst.enabled)
        XCTAssertNil(distractionFirst.themeID, "The black-stone lane has no destination theme")

        // Someone who already chose apps and switched recording off keeps it off.
        var paused = first
        paused.enabled = false
        let edited = ScreenTimeDraftPolicy.applying(selection(count: 1, seed: 0x62), toLearningLane: false,
                                                    in: paused, authorized: true, onlyThemeID: nil)
        XCTAssertFalse(edited.enabled)

        // Nothing picked, no permission, or a theme already chosen: untouched.
        XCTAssertFalse(ScreenTimeDraftPolicy.applying(empty, toLearningLane: true, in: ScreenTimeConfiguration(),
                                                      authorized: true, onlyThemeID: theme).enabled)
        XCTAssertFalse(ScreenTimeDraftPolicy.applying(two, toLearningLane: true, in: ScreenTimeConfiguration(),
                                                      authorized: false, onlyThemeID: nil).enabled)
        var chosen = ScreenTimeConfiguration()
        let other = UUID()
        chosen.themeID = other
        XCTAssertEqual(ScreenTimeDraftPolicy.applying(two, toLearningLane: true, in: chosen,
                                                      authorized: true, onlyThemeID: theme).themeID, other)
    }

    func testTheSaveToastStatesWhetherRecordingIsOn() {
        var configuration = ScreenTimeConfiguration()
        configuration.enabled = true
        XCTAssertEqual(ScreenTimeDraftPolicy.savedToast(for: configuration, isMonitoring: true).text,
                       "保存しました。自動記録中です")
        XCTAssertEqual(ScreenTimeDraftPolicy.savedToast(for: configuration, isMonitoring: false).text,
                       "保存しました", "Switched on is not yet recording; do not claim it")
        configuration.enabled = false
        XCTAssertEqual(ScreenTimeDraftPolicy.savedToast(for: configuration, isMonitoring: false).text,
                       "保存しました。自動記録はオフです")
        XCTAssertEqual(ScreenTimeDraftPolicy.savedToast(for: configuration, isMonitoring: false).symbol, "checkmark")
        configuration.learningSelection = selection(count: 1, seed: 0x63)
        XCTAssertEqual(ScreenTimeDraftPolicy.savedToast(for: configuration, isMonitoring: false).symbol,
                       "exclamationmark.circle", "Apps chosen but recording off is worth a second look")
    }

    private func selection(count: Int, seed: UInt8) -> FamilyActivitySelection {
        var selection = FamilyActivitySelection(includeEntireCategory: false)
        selection.applicationTokens = Set((0..<count).compactMap { index in
            try? JSONDecoder().decode(ApplicationToken.self, from: JSONEncoder().encode(["data": Data([seed, UInt8(index)])]))
        })
        return selection
    }

    /// 「スクリーンタイムの内容をリセット」 replaces the whole ledger, which used
    /// to drop the callback counters without a word. That is the one reading
    /// that exonerates the app — "every counter 0, nothing ever delivered" —
    /// so the reset must not be able to manufacture it. The counts start over
    /// (they describe a ledger that no longer exists) but say how many windows
    /// came before.
    func testResetStartsTheCallbackCountersOverInsteadOfErasingThatTheyExisted() async throws {
        let store = try makeStore()
        try store.update { state in
            state.countIntervalCallback(kind: .lane, phase: .start, now: Date())
            state.countThresholdCallback(.recorded, now: Date())
        }
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                              monitoring: Driver(store: store), authorization: { .approved })
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)

        try await controller.resetActivityData()

        let counters = try XCTUnwrap(try store.snapshot().callbackCounters,
                                     "The reset must not erase that counting ever happened")
        XCTAssertEqual(counters.generation, 1)
        XCTAssertEqual(counters.laneIntervalStarts, 0)
        XCTAssertEqual(counters.thresholds, 0)
        XCTAssertEqual(counters.epoch, try store.snapshot().epoch)
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

    // MARK: - screentime-03: a stop is visible outside the page

    func testTheSettingsRowSaysWhenRecordingStoppedButNeverForTheTimerHold() {
        func status(
            bound: Bool = true, enabled: Bool, monitoring: Bool = false, error: String? = nil,
            freeLimit: Bool = false, themeRemoved: Bool = false
        ) -> ScreenTimeRowStatus {
            ScreenTimeRowStatus(isBound: bound, enabled: enabled, isMonitoring: monitoring, monitoringError: error,
                                learningStoppedByFreeLimit: freeLimit, themeRemoved: themeRemoved)
        }
        XCTAssertEqual(status(bound: false, enabled: true, monitoring: true, error: "x", themeRemoved: true),
                       .feature, "An unbound owner has nothing it can report")
        XCTAssertEqual(status(enabled: false), .feature)
        XCTAssertEqual(status(enabled: true, monitoring: true), .recording)
        XCTAssertEqual(status(enabled: true, error: "監視エラー"), .needsAttention)
        // A revoked permission switches recording off and leaves only its
        // error; that stop is what the row exists to show.
        XCTAssertEqual(status(enabled: false, error: "スクリーンタイムの許可が解除されました。"), .needsAttention)
        // Over the free limit only the study apps stop; black stones go on.
        XCTAssertEqual(status(enabled: true, monitoring: true, error: "無料で登録できる勉強アプリは5つまでです。",
                              freeLimit: true), .learningStopped)
        XCTAssertEqual(status(enabled: true, error: "無料で登録できる勉強アプリは5つまでです。", freeLimit: true),
                       .learningStopped)
        // Registering, or the timer holding the learning lane: no error, no alarm.
        XCTAssertEqual(status(enabled: true), .feature)
        // The destination went away; even with the black-stone lane still on.
        XCTAssertEqual(status(enabled: true, monitoring: true, themeRemoved: true), .themeRemoved)
        XCTAssertEqual(status(enabled: false, themeRemoved: true), .themeRemoved)
        XCTAssertTrue(ScreenTimeRowStatus.needsAttention.isWarning)
        XCTAssertTrue(ScreenTimeRowStatus.learningStopped.isWarning)
        XCTAssertTrue(ScreenTimeRowStatus.themeRemoved.isWarning)
        XCTAssertFalse(ScreenTimeRowStatus.recording.isWarning)
        XCTAssertEqual(ScreenTimeRowStatus.recording.subtitle, "自動記録中")
        XCTAssertTrue(ScreenTimeRowStatus.needsAttention.subtitle.hasPrefix("要確認"))
        XCTAssertEqual(ScreenTimeRowStatus.learningStopped.subtitle, "要確認：勉強アプリの記録が止まっています")
    }

    /// settings-01 on the Screen Time page: until StoreKit answers, a Pro
    /// user reads as free. Saving over the free limit then would store a
    /// closed gate and retire the study-app run, so 保存 waits for the answer;
    /// anything the free plan allows anyway saves at once.
    func testSavingOverTheFreeLimitWaitsForThePurchaseStatus() {
        let limit = ScreenTimePolicy.freeLearningApplicationLimit
        XCTAssertTrue(ScreenTimeDraftPolicy.waitsForPurchaseStatus(
            draftEnabled: true, learningCount: limit + 1, entitlementsResolved: false))
        XCTAssertFalse(ScreenTimeDraftPolicy.waitsForPurchaseStatus(
            draftEnabled: true, learningCount: limit + 1, entitlementsResolved: true))
        XCTAssertFalse(ScreenTimeDraftPolicy.waitsForPurchaseStatus(
            draftEnabled: true, learningCount: limit, entitlementsResolved: false))
        XCTAssertFalse(ScreenTimeDraftPolicy.waitsForPurchaseStatus(
            draftEnabled: false, learningCount: limit + 1, entitlementsResolved: false),
                       "Switching recording off is never held up")
    }

    func testTheThemeDeleteWarningAppliesOnlyToTheScreenTimeDestination() {
        let theme = UUID()
        var configuration = ScreenTimeConfiguration()
        configuration.themeID = theme
        XCTAssertFalse(ScreenTimeThemeDeletionNotice.applies(to: theme, configuration: configuration, isBound: true),
                       "No study apps chosen: nothing is lost")
        configuration.learningSelection = selection(count: 2, seed: 0x71)
        XCTAssertTrue(ScreenTimeThemeDeletionNotice.applies(to: theme, configuration: configuration, isBound: true))
        XCTAssertFalse(ScreenTimeThemeDeletionNotice.applies(to: UUID(), configuration: configuration, isBound: true))
        XCTAssertFalse(ScreenTimeThemeDeletionNotice.applies(to: theme, configuration: configuration, isBound: false))
        XCTAssertTrue(ScreenTimeThemeDeletionNotice.text.contains("選び直す"))
    }

    func testTheRemovedThemeNoticeLastsUntilTheUserSavesAndStaysWithItsOwner() async throws {
        let suite = "ScreenTimeNoticeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try makeStore()
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" }, monitoring: Driver(store: store),
                                              authorization: { .approved }, noticeDefaults: defaults)
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        XCTAssertFalse(controller.learningThemeWasRemoved)
        controller.noteLearningThemeRemoved()
        XCTAssertTrue(controller.learningThemeWasRemoved)

        // A later launch reads it back for the same owner only.
        let relaunched = ScreenTimeController(store: store, currentContextKey: { "owner" }, monitoring: Driver(store: store),
                                              authorization: { .approved }, noticeDefaults: defaults)
        try await relaunched.bindContext(contextKey: "owner", dataEpochID: nil)
        XCTAssertTrue(relaunched.learningThemeWasRemoved)
        let otherStore = try makeStore(owner: "someone-else")
        let other = ScreenTimeController(store: otherStore, currentContextKey: { "someone-else" },
                                         monitoring: Driver(store: otherStore), authorization: { .approved },
                                         noticeDefaults: defaults)
        try await other.bindContext(contextKey: "someone-else", dataEpochID: nil)
        XCTAssertFalse(other.learningThemeWasRemoved)

        relaunched.clearLearningThemeRemovalNotice()
        XCTAssertFalse(relaunched.learningThemeWasRemoved)
        controller.reload()
        XCTAssertFalse(controller.learningThemeWasRemoved)
    }

    private func storeWithStudyApps(theme: UUID) throws -> ScreenTimeStore {
        let store = try makeStore()
        try store.update {
            $0.configuration.themeID = theme
            $0.configuration.learningSelection = selection(count: 2, seed: 0x81)
            $0.configuration.distractionSelection = selection(count: 1, seed: 0x82)
        }
        return store
    }

    /// `save` commits the cleared configuration before it registers what is
    /// left. When DeviceActivity then refused, the study apps were already
    /// gone, nothing retried (no study apps left to retire), and neither the
    /// toast nor the notice appeared: the silent loss screentime-03 is about.
    func testARemovedThemeIsExplainedEvenWhenRegisteringTheRestFails() async throws {
        let suite = "ScreenTimeNoticeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let theme = UUID()
        let store = try storeWithStudyApps(theme: theme)
        let driver = Driver(store: store)
        let controller = ScreenTimeController(store: store, currentContextKey: { "owner" }, monitoring: driver,
                                              authorization: { .approved }, noticeDefaults: defaults)
        try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
        driver.refusesRegistration = true

        let outcome = await controller.retireLearningSelection(ofRemovedTheme: theme, isPro: false)
        XCTAssertTrue(outcome.cleared)
        XCTAssertNotNil(outcome.failure, "The refusal is still reported to the caller")
        let state = try store.snapshot()
        XCTAssertTrue(state.configuration.learningSelection.applicationTokens.isEmpty)
        XCTAssertNil(state.configuration.themeID)
        XCTAssertTrue(state.configuration.enabled, "The black-stone lane stays on")
        XCTAssertTrue(controller.learningThemeWasRemoved)

        // The next pass finds nothing to retire: this was the only chance.
        let again = await controller.retireLearningSelection(ofRemovedTheme: theme, isPro: false)
        XCTAssertFalse(again.cleared)
        XCTAssertNil(again.failure)
    }

    /// The delete dialog on this iPhone already said what deleting the theme
    /// does, so only a deletion it did not confirm leaves a lasting notice.
    func testOnlyADeletionThisIPhoneDidNotConfirmLeavesALastingNotice() async throws {
        for confirmedHere in [true, false] {
            let suite = "ScreenTimeNoticeTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let theme = UUID()
            let store = try storeWithStudyApps(theme: theme)
            let controller = ScreenTimeController(store: store, currentContextKey: { "owner" },
                                                  monitoring: Driver(store: store),
                                                  authorization: { .approved }, noticeDefaults: defaults)
            try await controller.bindContext(contextKey: "owner", dataEpochID: nil)
            controller.noteLearningThemeDeletionConfirmed(confirmedHere ? theme : UUID())

            let outcome = await controller.retireLearningSelection(ofRemovedTheme: theme, isPro: false)
            XCTAssertTrue(outcome.cleared)
            XCTAssertNil(outcome.failure)
            XCTAssertEqual(controller.learningThemeWasRemoved, !confirmedHere,
                           "confirmedHere=\(confirmedHere)")
        }
    }
}
