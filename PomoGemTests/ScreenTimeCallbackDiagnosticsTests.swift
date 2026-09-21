import DeviceActivity
import FamilyControls
import Foundation
import XCTest
@testable import PomoGem

/// The device audit (PR #24, 2026-09-20/21) reached "no DeviceActivity
/// threshold callback in either lane" and could not say why: this Mac cannot
/// collect the phone's unified log (`devicectl device sysdiagnose` and
/// `log collect --device-udid` both require host root, and this `log` build has
/// no `--device-udid` at all), so not one `os_log` line was available. These
/// tests cover the durable, root-free record added for the next run: counts and
/// reasons in the App Group ledger, which the app re-emits to `os_log` on every
/// synchronize pass. Nothing here awards, wipes or registers anything.
final class ScreenTimeCallbackDiagnosticsTests: XCTestCase {
    private var now: Date {
        Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
            .addingTimeInterval(43_200)
    }

    // MARK: - ledger compatibility

    /// The phone already holds a ledger written before this field existed. The
    /// synthesized decoder does NOT fall back to a property's default value, so
    /// a non-optional `callbackCounters` would decode as `keyNotFound`, surface
    /// as `ScreenTimeError.corruptedState`, and cost the user their stored
    /// selections' usability on the very build meant to diagnose them.
    func testLedgerWrittenBeforeTheCountersExistedStillDecodes() throws {
        var original = ScreenTimeState()
        original.contextKey = "test-owner"
        original.contextIsActive = true
        original.configuration.enabled = true
        original.negativeGemCount = 3
        let encoded = try JSONEncoder().encode(original)
        var fields = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        fields.removeValue(forKey: "callbackCounters")
        XCTAssertNil(fields["callbackCounters"])

        let decoded = try JSONDecoder().decode(
            ScreenTimeState.self,
            from: JSONSerialization.data(withJSONObject: fields)
        )

        XCTAssertNil(decoded.callbackCounters)
        XCTAssertTrue(decoded.isValid)
        XCTAssertEqual(decoded.negativeGemCount, 3)
        XCTAssertTrue(decoded.configuration.enabled)
    }

    func testCountersSurviveALedgerRoundTrip() throws {
        var state = ScreenTimeState()
        state.countIntervalCallback(kind: .scheduler, phase: .start, now: now)
        state.countThresholdCallback(.unknownAuthorization, now: now)
        let decoded = try JSONDecoder().decode(
            ScreenTimeState.self, from: JSONEncoder().encode(state)
        )
        XCTAssertEqual(decoded.callbackCounters, state.callbackCounters)
    }

    func testNegativeCountersAreRejectedByTheLedgerValidator() {
        var state = ScreenTimeState()
        var counters = ScreenTimeCallbackCounters()
        counters.thresholds = -1
        state.callbackCounters = counters
        XCTAssertFalse(state.isValid)
    }

    // MARK: - activity kind

    func testActivityKindSeparatesTheSchedulerFromALane() {
        let run = ScreenTimeRun(
            lane: .learning, dayStart: now, dayEnd: now.addingTimeInterval(86_400),
            startedAt: now, timeZoneID: "Asia/Tokyo", includesPastActivity: false, themeID: UUID()
        )
        XCTAssertEqual(
            ScreenTimeActivityKind(activityName: ScreenTimeMonitoring.schedulerName(epoch: UUID())),
            .scheduler
        )
        XCTAssertEqual(ScreenTimeActivityKind(activityName: run.activityPrefix + "0"), .lane)
        XCTAssertEqual(
            ScreenTimeActivityKind(
                activityName: run.activityPrefix + String(ScreenTimePolicy.batchesPerLane - 1)
            ),
            .lane
        )
    }

    func testActivityKindRefusesForeignAndMalformedNames() {
        // A batch outside our own range, a non-UUID run, another client's
        // activity and our prefix with nothing after it are all "other": the
        // counter must never claim a lane interval the OS did not deliver.
        for name in [
            "pomogem.screen-time.other.0",
            "pomogem.screen-time." + UUID().uuidString + "." + String(ScreenTimePolicy.batchesPerLane),
            "pomogem.screen-time." + UUID().uuidString,
            "pomogem.screen-time.",
            "com.example.other.activity",
            ""
        ] {
            XCTAssertEqual(ScreenTimeActivityKind(activityName: name), .other, name)
        }
    }

    // MARK: - threshold callbacks

    /// H1 in the diagnosis: a freshly spawned extension process reading
    /// `.notDetermined` drops the whole callback, silently. The drop is
    /// deliberate and stays (only `.denied` may wipe anything), but it must
    /// leave a count behind, because it is indistinguishable from "the OS never
    /// delivered a threshold at all" in every artefact the audit could collect.
    func testUnknownAuthorizationIsCountedAndStillAwardsNothing() throws {
        try withLedger { store, initial in
            let monitor = ScreenTimeMonitoring(store: store, center: FakeCenter(),
                                               authorizationStatus: { .notDetermined })

            try monitor.handleThreshold(
                eventName: "1", activityName: initial.runs[0].activityPrefix + "0", now: now
            )

            let counters = try XCTUnwrap(try store.snapshot().callbackCounters)
            XCTAssertEqual(counters.thresholds, 1)
            XCTAssertEqual(counters.thresholdsUnknownAuthorization, 1)
            XCTAssertEqual(counters.thresholdsRecorded, 0)
            XCTAssertEqual(counters.lastCallbackAt, now)
            // Behaviour is unchanged: no award, no wipe, no teardown.
            let state = try store.snapshot()
            XCTAssertEqual(state.runs[0].highestThreshold, 0)
            XCTAssertTrue(state.configuration.enabled)
            XCTAssertNil(state.monitoringError)
        }
    }

    func testDeniedAuthorizationIsCountedApartFromAnUnknownOne() throws {
        try withLedger { store, initial in
            let monitor = ScreenTimeMonitoring(store: store, center: FakeCenter(),
                                               authorizationStatus: { .denied })

            try monitor.handleThreshold(
                eventName: "1", activityName: initial.runs[0].activityPrefix + "0", now: now
            )

            let counters = try XCTUnwrap(try store.snapshot().callbackCounters)
            XCTAssertEqual(counters.thresholds, 1)
            XCTAssertEqual(counters.thresholdsDenied, 1)
            XCTAssertEqual(counters.thresholdsUnknownAuthorization, 0)
            // The existing revocation behaviour is untouched.
            XCTAssertFalse(try store.snapshot().configuration.enabled)
        }
    }

    func testAnAwardedAndALedgerRefusedThresholdAreCountedApart() throws {
        try withLedger { store, initial in
            let monitor = ScreenTimeMonitoring(store: store, center: FakeCenter(),
                                               authorization: { true })
            let name = initial.runs[0].activityPrefix + "0"

            // startedAt is 1_200 s before `now`, so threshold 1 (600 s) is due
            // and the same callback repeated is refused as already awarded.
            try monitor.handleThreshold(eventName: "1", activityName: name, now: now)
            try monitor.handleThreshold(eventName: "1", activityName: name, now: now)
            // Threshold 3 needs 1_800 s of the window and is still in the future.
            try monitor.handleThreshold(eventName: "3", activityName: name, now: now)

            let counters = try XCTUnwrap(try store.snapshot().callbackCounters)
            XCTAssertEqual(counters.thresholds, 3)
            XCTAssertEqual(counters.thresholdsRecorded, 1)
            XCTAssertEqual(counters.thresholdsIgnoredByLedger, 2)
            XCTAssertEqual(counters.thresholdsIgnoredByName, 0)
            // No double counting: one award only.
            XCTAssertEqual(try store.snapshot().runs[0].highestThreshold, 1)
        }
    }

    func testAForeignActivityNameIsCountedAsIgnoredByName() throws {
        try withLedger { store, _ in
            let monitor = ScreenTimeMonitoring(store: store, center: FakeCenter(),
                                               authorization: { true })

            try monitor.handleThreshold(eventName: "1", activityName: "com.example.other", now: now)
            try monitor.handleThreshold(eventName: "x", activityName: "pomogem.screen-time.other.0",
                                        now: now)

            let counters = try XCTUnwrap(try store.snapshot().callbackCounters)
            XCTAssertEqual(counters.thresholds, 2)
            XCTAssertEqual(counters.thresholdsIgnoredByName, 2)
            XCTAssertEqual(counters.thresholdsRecorded, 0)
        }
    }

    // MARK: - interval callbacks

    /// H2(b) in the diagnosis: whether a dated, non-repeating schedule whose
    /// `intervalStart` is already past ever starts its interval. Nothing in the
    /// app could tell, because `DeviceActivityCenter.activities` keeps listing
    /// the name either way. These two counters decide it on the next device run
    /// without a unified log: a lane start that never arrives while scheduler
    /// starts do is the whole answer.
    func testLaneAndSchedulerIntervalStartsAreCountedApart() throws {
        try withLedger { store, initial in
            let monitor = ScreenTimeMonitoring(store: store, center: FakeCenter(),
                                               authorization: { true })

            try monitor.handleInterval(
                activityName: initial.runs[0].activityPrefix + "0", phase: .start, now: now
            )
            try monitor.handleInterval(
                activityName: initial.runs[0].activityPrefix + "1", phase: .end, now: now
            )
            try monitor.handleInterval(activityName: "com.example.other", phase: .start, now: now)

            let counters = try XCTUnwrap(try store.snapshot().callbackCounters)
            XCTAssertEqual(counters.laneIntervalStarts, 1)
            XCTAssertEqual(counters.laneIntervalEnds, 1)
            XCTAssertEqual(counters.otherIntervalStarts, 1)
            XCTAssertEqual(counters.schedulerIntervalStarts, 0)
            XCTAssertEqual(counters.schedulerIntervalEnds, 0)
        }
    }

    func testSchedulerIntervalStartIsCountedEvenThoughItAlsoSynchronizes() throws {
        try withLedger { store, initial in
            let center = FakeCenter()
            let monitor = ScreenTimeMonitoring(store: store, center: center,
                                               authorization: { true })

            try monitor.handleInterval(
                activityName: ScreenTimeMonitoring.schedulerName(epoch: initial.epoch),
                phase: .start, now: now
            )

            let counters = try XCTUnwrap(try store.snapshot().callbackCounters)
            XCTAssertEqual(counters.schedulerIntervalStarts, 1)
            XCTAssertEqual(counters.laneIntervalStarts, 0)
            // The counter write must not have been rolled back by the
            // synchronize pass that the same callback performs.
            XCTAssertGreaterThan(center.startedNames.count, 0)
        }
    }

    /// A callback can reach the extension before the app has ever bound a
    /// ledger. Counting it must not be what creates one: an empty ledger with
    /// a fresh epoch is not an owner, and writing one from a short-lived
    /// extension process would invent state no user action asked for.
    func testCallbackCountingNeverCreatesALedger() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreenTimeStore(directory: directory)
        let monitor = ScreenTimeMonitoring(store: store, center: FakeCenter(),
                                           authorizationStatus: { .notDetermined })

        try monitor.handleInterval(activityName: "com.example.other", phase: .start, now: now)
        try monitor.handleThreshold(eventName: "1", activityName: "com.example.other", now: now)

        let ledger = directory.appendingPathComponent("ScreenTime/ledger.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.path))
    }

    // MARK: - log line

    /// The summary the app prints on every synchronize pass is what a single
    /// live Console session reads after the fact. It must carry counts and
    /// reasons only — never a run or event identifier, a threshold, a gem
    /// count or a token.
    func testCounterLogLineCarriesCountsAndReasonsOnly() {
        var counters = ScreenTimeCallbackCounters()
        counters.countInterval(kind: .scheduler, phase: .start, at: now.addingTimeInterval(-90))
        counters.countThreshold(.unknownAuthorization, at: now.addingTimeInterval(-30))
        let line = counters.logDescription(now: now)

        XCTAssertTrue(line.hasPrefix("callbacks "), line)
        XCTAssertTrue(line.contains("schedulerStart=1"), line)
        XCTAssertTrue(line.contains("laneStart=0"), line)
        XCTAssertTrue(line.contains("threshold=1"), line)
        XCTAssertTrue(line.contains("unknownAuth=1"), line)
        XCTAssertTrue(line.contains("lastAgeSec=30"), line)
        XCTAssertEqual(ScreenTimeCallbackCounters().logDescription(now: now).contains("lastAgeSec=-1"),
                       true)
        for forbidden in [String(UUID().uuidString.prefix(8)), "gem", "token", "theme", "run"] {
            XCTAssertFalse(line.lowercased().contains(forbidden.lowercased()), line)
        }
    }

    // MARK: - fixture

    private func withLedger(
        _ body: (ScreenTimeStore, ScreenTimeState) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
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
            lane: .learning, dayStart: dayStart,
            dayEnd: calendar.date(byAdding: .day, value: 1, to: dayStart)!,
            startedAt: now.addingTimeInterval(-1_200),
            timeZoneID: calendar.timeZone.identifier,
            includesPastActivity: false,
            themeID: initial.configuration.themeID
        )]
        try store.update { $0 = initial }
        try body(store, initial)
    }
}

/// Accepts every registration and remembers nothing the tests above assert on.
/// No DeviceActivity, Family Controls or App Group call is made.
private final class FakeCenter: ScreenTimeActivityCenterDriving {
    private var installed: [DeviceActivityName] = []
    private(set) var startedNames: [String] = []

    var activities: [DeviceActivityName] { installed }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        if activities.isEmpty { installed.removeAll() }
        else { installed.removeAll { activities.contains($0) } }
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        startedNames.append(activity.rawValue)
        if !installed.contains(activity) { installed.append(activity) }
    }
}
