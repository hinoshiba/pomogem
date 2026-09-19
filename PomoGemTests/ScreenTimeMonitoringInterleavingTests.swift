import DeviceActivity
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

    private func withFixture(
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
        let center = FakeActivityCenter(activities: (0..<ScreenTimePolicy.batchesPerLane).map {
            DeviceActivityName(initial.runs[0].activityPrefix + String($0))
        })
        try body(store, center, initial, directory.appendingPathComponent("ScreenTime/ledger.json"))
    }
}

private struct RegistrationFailure: Error {}

private final class FakeActivityCenter: ScreenTimeActivityCenterDriving {
    private let installed: [DeviceActivityName]
    var onActivities: (() -> Void)?
    var onStop: (() -> Void)?
    var onStart: (() throws -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(activities: [DeviceActivityName]) { installed = activities }

    var activities: [DeviceActivityName] {
        let callback = onActivities
        onActivities = nil
        callback?()
        return installed
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        stopCount += 1
        let callback = onStop
        onStop = nil
        callback?()
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        startCount += 1
        try onStart?()
    }
}
