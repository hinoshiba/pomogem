import DeviceActivity
import FamilyControls
import Foundation
import XCTest
@testable import PomoGem

final class ScreenTimeMonitoringInterleavingTests: XCTestCase {
    private var now: Date {
        Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
            .addingTimeInterval(43_200)
    }

    func testOldRegistrationFailureCannotWriteIntoResetLedger() throws {
        try withFixture { store, center, original, ledgerURL in
            var replacement = ScreenTimeState()
            replacement.contextKey = original.contextKey
            replacement.dataEpochID = original.dataEpochID
            replacement.contextIsActive = true
            var replacementBytes: Data?
            center.onStart = {
                try store.update { $0 = replacement }
                replacementBytes = try Data(contentsOf: ledgerURL)
                throw RegistrationFailure()
            }
            let monitor = ScreenTimeMonitoring(store: store, center: center, authorization: { true })

            XCTAssertFalse(try monitor.synchronize(now: now))
            XCTAssertEqual(try Data(contentsOf: ledgerURL), try XCTUnwrap(replacementBytes))
            let result = try store.snapshot()
            XCTAssertEqual(result.epoch, replacement.epoch)
            XCTAssertNil(result.monitoringError)
            XCTAssertTrue(result.runs.isEmpty)
            XCTAssertFalse(result.configuration.enabled)
        }
    }

    func testOwnerEpochOrRetirementDuringPlanningRejectsOldRunMutation() throws {
        for change in 0..<3 {
            try withFixture { store, center, original, ledgerURL in
                var replacement = original
                if change == 0 { replacement.contextKey = "replacement-owner" }
                if change == 1 { replacement.dataEpochID = UUID() }
                if change == 2 { replacement.contextIsActive = false }
                replacement.negativeGemCount = 27
                replacement.monitoringError = "New context status"
                var replacementBytes: Data?
                center.onActivities = {
                    do {
                        try store.update { $0 = replacement }
                        replacementBytes = try Data(contentsOf: ledgerURL)
                    } catch { XCTFail("Fixture replacement failed: \(error)") }
                }
                let monitor = ScreenTimeMonitoring(store: store, center: center, authorization: { true })

                XCTAssertFalse(try monitor.synchronize(now: now))
                XCTAssertEqual(try Data(contentsOf: ledgerURL), try XCTUnwrap(replacementBytes))
                XCTAssertEqual(center.startCount, 0)
                XCTAssertEqual(center.stopCount, 0)
            }
        }
    }

    func testAuthorizationInvalidationDoesNotClearNewOptInAfterSlowStop() throws {
        for explicitInvalidation in [false, true] {
            try withFixture { store, center, original, ledgerURL in
                var replacement = original
                replacement.epoch = UUID()
                replacement.contextKey = "new-opt-in-owner"
                replacement.configuration.themeID = UUID()
                replacement.negativeGemCount = 14
                var replacementBytes: Data?
                center.onStop = {
                    do {
                        try store.update { $0 = replacement }
                        replacementBytes = try Data(contentsOf: ledgerURL)
                    } catch { XCTFail("Fixture replacement failed: \(error)") }
                }
                let monitor = ScreenTimeMonitoring(store: store, center: center, authorization: { false })

                if explicitInvalidation {
                    XCTAssertNoThrow(try monitor.invalidateAuthorizationIfNeeded())
                } else {
                    XCTAssertFalse(try monitor.synchronize(now: now))
                }
                XCTAssertEqual(try Data(contentsOf: ledgerURL), try XCTUnwrap(replacementBytes))
                XCTAssertTrue(try store.snapshot().configuration.enabled)
                XCTAssertEqual(center.startCount, 0)
            }
        }
    }

    func testDisabledContextCleanupDoesNotRetireReplacementAfterSlowStop() throws {
        try withFixture { store, center, original, ledgerURL in
            try store.update { $0.configuration.enabled = false }
            var replacement = original
            replacement.epoch = UUID()
            replacement.contextKey = "replacement-owner"
            var replacementBytes: Data?
            center.onStop = {
                do {
                    try store.update { $0 = replacement }
                    replacementBytes = try Data(contentsOf: ledgerURL)
                } catch { XCTFail("Fixture replacement failed: \(error)") }
            }
            let monitor = ScreenTimeMonitoring(store: store, center: center, authorization: { true })

            XCTAssertFalse(try monitor.synchronize(now: now))
            XCTAssertEqual(try Data(contentsOf: ledgerURL), try XCTUnwrap(replacementBytes))
            XCTAssertTrue(try store.snapshot().runs[0].active)
            XCTAssertEqual(center.startCount, 0)
        }
    }

    func testRetirementDuringLastStartIsObservedBeforeReportingSuccess() throws {
        try withFixture { store, center, _, ledgerURL in
            var retiredBytes: Data?
            center.onStart = {
                try store.update { state in
                    state.learningPausedByTimer = true
                    state.runs[0].active = false
                }
                retiredBytes = try Data(contentsOf: ledgerURL)
            }
            let monitor = ScreenTimeMonitoring(store: store, center: center, authorization: { true })

            XCTAssertFalse(try monitor.synchronize(now: now))
            XCTAssertEqual(try Data(contentsOf: ledgerURL), try XCTUnwrap(retiredBytes))
            XCTAssertNil(try store.snapshot().monitoringError)
            XCTAssertEqual(center.startCount, 1)
        }
    }

    func testConcurrentReceiptDoesNotCancelTheCurrentRegistrationPlan() throws {
        try withFixture { store, center, original, _ in
            center.onStart = {
                try store.record(runID: original.runs[0].id, threshold: 1, now: self.now)
            }
            let monitor = ScreenTimeMonitoring(store: store, center: center, authorization: { true })

            XCTAssertTrue(try monitor.synchronize(now: now))
            let result = try store.snapshot()
            XCTAssertEqual(result.pendingLearningReceipts(limit: 10).count, 1)
            XCTAssertTrue(result.runs[0].active)
            XCTAssertNil(result.monitoringError)
        }
    }

    func testCurrentGenerationFailureStillRetiresRunsAndReportsFailure() throws {
        try withFixture { store, center, original, _ in
            try store.record(runID: original.runs[0].id, threshold: 1, now: now)
            center.onStart = { throw RegistrationFailure() }
            let monitor = ScreenTimeMonitoring(store: store, center: center, authorization: { true })

            XCTAssertThrowsError(try monitor.synchronize(now: now)) { error in
                XCTAssertTrue(error is RegistrationFailure)
            }
            let result = try store.snapshot()
            XCTAssertEqual(result.epoch, original.epoch)
            XCTAssertFalse(result.runs.contains(where: \.active))
            XCTAssertNotNil(result.monitoringError)
            XCTAssertEqual(result.pendingLearningReceipts(limit: 10).count, 1)
        }
    }

    /// With a bound, a blocked registration pass is skipped instead of holding
    /// the extension in flock until the OS kills it.
    func testBoundedLockWaitSkipsTheRegistrationPassInsteadOfBlocking() throws {
        try withFixture(installed: .none) { store, center, original, ledgerURL in
            let root = ledgerURL.deletingLastPathComponent().deletingLastPathComponent()
            let holder = ScreenTimeStore(directory: root)
            let held = expectation(description: "The app holds the monitoring lock")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            DispatchQueue.global().async {
                try? holder.withMonitoringLock {
                    held.fulfill()
                    _ = release.wait(timeout: .now() + 30)
                }
            }
            wait(for: [held], timeout: 10)
            let monitor = ScreenTimeMonitoring(store: store, center: center, lockTimeout: 0.3,
                                               authorization: { true })

            let began = Date()
            XCTAssertThrowsError(try monitor.synchronize(now: now)) { error in
                guard case ScreenTimeError.unavailable = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertLessThan(Date().timeIntervalSince(began), 10)
            XCTAssertEqual(center.startedNames, [])
            XCTAssertEqual(center.stopCalls, [])
            // The skipped pass leaves the ledger for the next callback.
            XCTAssertEqual(try store.snapshot().runs.map(\.id), original.runs.map(\.id))
        }
    }

    /// A freshly launched monitor extension process can read .notDetermined
    /// before Family Controls has answered. Acting on it would throw the user's
    /// opaque selections away, and only a new picker session can restore them.
    func testNotDeterminedAuthorizationNeitherRecordsNorInvalidates() throws {
        try withFixture(installed: .complete) { store, center, original, _ in
            let monitor = ScreenTimeMonitoring(store: store, center: center,
                                               authorizationStatus: { .notDetermined })

            try monitor.handleThreshold(eventName: "1",
                                        activityName: original.runs[0].activityPrefix + "0", now: now)
            XCTAssertNoThrow(try monitor.invalidateAuthorizationIfNeeded())
            XCTAssertFalse(try monitor.synchronize(now: now))

            let result = try store.snapshot()
            XCTAssertTrue(result.configuration.enabled)
            XCTAssertEqual(result.configuration.themeID, original.configuration.themeID)
            XCTAssertNil(result.monitoringError)
            XCTAssertEqual(result.runs.count, 1)
            XCTAssertTrue(result.runs[0].active)
            // The callback is ignored, not awarded.
            XCTAssertEqual(result.runs[0].highestThreshold, 0)
            // Nothing is torn down while the status is still unknown.
            XCTAssertEqual(center.stopCalls, [])
            XCTAssertEqual(center.startedNames, [])
        }
    }

    func testDeniedAuthorizationStillInvalidatesTheSelections() throws {
        try withFixture(installed: .complete) { store, center, original, _ in
            let monitor = ScreenTimeMonitoring(store: store, center: center,
                                               authorizationStatus: { .denied })

            try monitor.handleThreshold(eventName: "1",
                                        activityName: original.runs[0].activityPrefix + "0", now: now)

            let result = try store.snapshot()
            XCTAssertFalse(result.configuration.enabled)
            XCTAssertTrue(result.configuration.learningSelection.applicationTokens.isEmpty)
            XCTAssertFalse(result.runs.contains(where: \.active))
            XCTAssertTrue(result.monitoringError?.contains("選び直して") == true)
            XCTAssertEqual(center.stopCalls.count, 1)
            XCTAssertFalse(try XCTUnwrap(center.stopCalls.first).isEmpty)
        }
    }

    func testSteadyStateSynchronizeKeepsTheInstalledRegistrationInstalled() throws {
        try withFixture(installed: .complete) { store, center, original, _ in
            let expected = Set((0..<ScreenTimePolicy.batchesPerLane).map {
                original.runs[0].activityPrefix + String($0)
            } + [ScreenTimeMonitoring.schedulerName(epoch: original.epoch)])
            XCTAssertEqual(center.installedNames, expected)
            let monitor = ScreenTimeMonitoring(store: store, center: center, authorization: { true })

            XCTAssertTrue(try monitor.synchronize(now: now))

            // Nothing changed, so nothing may be torn down or re-registered. A
            // stopMonitoring([]) here would stop every activity on the device.
            XCTAssertEqual(center.stopCalls, [])
            XCTAssertEqual(center.startedNames, [])
            XCTAssertEqual(center.installedNames, expected)
            let result = try store.snapshot()
            XCTAssertEqual(result.runs.count, 1)
            XCTAssertEqual(result.runs[0].id, original.runs[0].id)
            XCTAssertTrue(result.runs[0].active)
            XCTAssertNil(result.monitoringError)
        }
    }

    /// Which of our activities the OS already holds when the pass starts.
    fileprivate enum FixtureInstallation {
        /// Today's run is registered, but the daily scheduler is not.
        case runBatches
        /// Steady state: every batch of today's run plus the daily scheduler.
        case complete
        /// A fresh device, or a center that lost our registration.
        case none
    }

    private func withFixture(
        installed: FixtureInstallation = .runBatches,
        _ body: (ScreenTimeStore, FakeActivityCenter, ScreenTimeState, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreenTimeStore(directory: directory)
        var initial = ScreenTimeState()
        initial.contextKey = "test-owner"
        initial.dataEpochID = UUID()
        initial.contextIsActive = true
        initial.configuration.enabled = true
        initial.configuration.themeID = UUID()
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        initial.runs = [ScreenTimeRun(
            lane: .learning,
            dayStart: dayStart,
            dayEnd: calendar.date(byAdding: .day, value: 1, to: dayStart)!,
            startedAt: now.addingTimeInterval(-1_200),
            timeZoneID: calendar.timeZone.identifier,
            includesPastActivity: false,
            themeID: initial.configuration.themeID
        )]
        try store.update { $0 = initial }
        // A pre-existing run needs no manufactured Family Controls tokens. All
        // calls use this fake center; no OS registration or permission is used.
        var names: [String] = []
        if installed != .none {
            names = (0..<ScreenTimePolicy.batchesPerLane).map { initial.runs[0].activityPrefix + String($0) }
        }
        if installed == .complete {
            names.append(ScreenTimeMonitoring.schedulerName(epoch: initial.epoch))
        }
        let center = FakeActivityCenter(activities: names.map(DeviceActivityName.init(rawValue:)))
        try body(store, center, initial, directory.appendingPathComponent("ScreenTime/ledger.json"))
    }
}

private struct RegistrationFailure: Error {}

private final class FakeActivityCenter: ScreenTimeActivityCenterDriving {
    private var installed: [DeviceActivityName]
    var onActivities: (() -> Void)?
    var onStop: (() -> Void)?
    var onStart: (() throws -> Void)?
    /// Called with every started activity name, unlike `onStart` which keeps the
    /// no-argument shape the older interleaving tests rely on.
    var onStartName: ((String) throws -> Void)?
    private(set) var startedNames: [String] = []
    /// Every stopMonitoring argument, so a `[]` teardown is visible to tests.
    private(set) var stopCalls: [[String]] = []
    var startCount: Int { startedNames.count }
    var stopCount: Int { stopCalls.count }
    var installedNames: Set<String> { Set(installed.map(\.rawValue)) }

    init(activities: [DeviceActivityName]) { installed = activities }

    var activities: [DeviceActivityName] {
        let callback = onActivities
        onActivities = nil
        callback?()
        return installed
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        stopCalls.append(activities.map(\.rawValue))
        // Mirrors DeviceActivityCenter: the argument defaults to [] and an empty
        // array stops EVERY activity, not none.
        // https://developer.apple.com/documentation/deviceactivity/deviceactivitycenter/stopmonitoring(_:)
        if activities.isEmpty { installed.removeAll() }
        else { installed.removeAll { activities.contains($0) } }
        let callback = onStop
        onStop = nil
        callback?()
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        startedNames.append(activity.rawValue)
        try onStart?()
        try onStartName?(activity.rawValue)
        if !installed.contains(activity) { installed.append(activity) }
    }
}
