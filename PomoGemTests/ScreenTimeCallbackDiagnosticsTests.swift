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
        state.countThresholdCallback(.recorded, statusUnknown: true, now: now)
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

    /// H1, confirmed on the phone and then fixed: a freshly spawned extension
    /// process reading `.notDetermined` used to drop the whole callback,
    /// silently. It no longer does — the award is recorded — but the reading is
    /// still worth a number, because it is the one thing the counters could say
    /// and no other artefact the audit could collect could. It is an
    /// OBSERVATION beside the outcome, never an outcome of its own: the same
    /// callback is counted as `recorded` too, and the two do not sum.
    func testAnUnknownStatusIsObservedBesideTheOutcomeItDoesNotDecide() throws {
        try withLedger { store, initial in
            let monitor = ScreenTimeMonitoring(store: store, center: FakeCenter(),
                                               host: .monitorExtension,
                                               authorizationStatus: { .notDetermined })

            try monitor.handleThreshold(
                eventName: "1", activityName: initial.runs[0].activityPrefix + "0", now: now
            )

            let counters = try XCTUnwrap(try store.snapshot().callbackCounters)
            XCTAssertEqual(counters.thresholds, 1)
            XCTAssertEqual(counters.statusUnknownAtCallback, 1)
            XCTAssertEqual(counters.thresholdsRecorded, 1)
            XCTAssertEqual(counters.thresholdsIgnoredByLedger, 0)
            XCTAssertEqual(counters.thresholdsDenied, 0)
            XCTAssertEqual(counters.lastCallbackAt, now)
            // The gem the OS measured is awarded, and nothing is wiped.
            let state = try store.snapshot()
            XCTAssertEqual(state.runs[0].highestThreshold, 1)
            XCTAssertTrue(state.configuration.enabled)
            XCTAssertNil(state.monitoringError)
        }
    }

    /// An approved process is the other side of the same observation: the
    /// count must stay at zero, or "the extension cannot read the approval"
    /// would read as true on every device.
    func testAnApprovedStatusIsNotCountedAsUnknown() throws {
        try withLedger { store, initial in
            let monitor = ScreenTimeMonitoring(store: store, center: FakeCenter(),
                                               host: .monitorExtension,
                                               authorization: { true })

            try monitor.handleThreshold(
                eventName: "1", activityName: initial.runs[0].activityPrefix + "0", now: now
            )

            let counters = try XCTUnwrap(try store.snapshot().callbackCounters)
            XCTAssertEqual(counters.thresholdsRecorded, 1)
            XCTAssertEqual(counters.statusUnknownAtCallback, 0)
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
            XCTAssertEqual(counters.statusUnknownAtCallback, 0,
                           "A denial is an answer, not an unreadable status")
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
            // The day-boundary activity is a clock: it must carry no threshold
            // event, or a gem could be owed to a registration nobody selected.
            XCTAssertTrue(center.startedSchedules.allSatisfy { $0.events.isEmpty })
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
        counters.countThreshold(.recorded, statusUnknown: true, at: now.addingTimeInterval(-30))
        let line = counters.logDescription(now: now)

        XCTAssertTrue(line.hasPrefix("callbacks "), line)
        XCTAssertTrue(line.contains("schedulerStart=1"), line)
        XCTAssertTrue(line.contains("laneStart=0"), line)
        XCTAssertTrue(line.contains("threshold=1"), line)
        XCTAssertTrue(line.contains("statusUnknown=1"), line)
        XCTAssertFalse(line.contains("unknownAuth="),
                       "The bucket that used to read as a verdict is gone: \(line)")
        XCTAssertTrue(line.contains("lastAgeSec=30"), line)
        XCTAssertEqual(ScreenTimeCallbackCounters().logDescription(now: now).contains("lastAgeSec=-1"),
                       true)
        for forbidden in [String(UUID().uuidString.prefix(8)), "gem", "token", "theme", "run"] {
            XCTAssertFalse(line.lowercased().contains(forbidden.lowercased()), line)
        }
    }

    // MARK: - what the counts are counted under

    /// A total with nothing to scope it cannot answer the question it was
    /// added for. A lane interval that started YESTERDAY would otherwise read
    /// as "the lane interval is starting" on a day when it never did, and
    /// refute the leading hypothesis on the strength of the previous day.
    func testCountersRestartOnANewDeviceDayInsteadOfAddingToYesterdaysTotals() throws {
        var state = ScreenTimeState()
        state.countIntervalCallback(kind: .lane, phase: .start, now: now)
        state.countThresholdCallback(.recorded, now: now)
        XCTAssertEqual(state.callbackCounters?.generation, 0)
        XCTAssertEqual(state.callbackCounters?.laneIntervalStarts, 1)

        let tomorrow = now.addingTimeInterval(86_400)
        state.countIntervalCallback(kind: .scheduler, phase: .start, now: tomorrow)

        let counters = try XCTUnwrap(state.callbackCounters)
        XCTAssertEqual(counters.generation, 1, "A restart has to be visible")
        XCTAssertEqual(counters.laneIntervalStarts, 0)
        XCTAssertEqual(counters.thresholds, 0)
        XCTAssertNil(counters.lastLaneIntervalStartAt)
        XCTAssertEqual(counters.schedulerIntervalStarts, 1)
        XCTAssertEqual(counters.dayStart, Calendar.current.startOfDay(for: tomorrow))
    }

    func testCountersRestartWhenTheLedgerEpochChanges() throws {
        var state = ScreenTimeState()
        state.countIntervalCallback(kind: .lane, phase: .start, now: now)

        state.epoch = UUID()
        state.countThresholdCallback(.denied, now: now)

        let counters = try XCTUnwrap(state.callbackCounters)
        XCTAssertEqual(counters.generation, 1)
        XCTAssertEqual(counters.laneIntervalStarts, 0)
        XCTAssertEqual(counters.thresholdsDenied, 1)
        XCTAssertEqual(counters.epoch, state.epoch)
    }

    /// The phone already holds counts written before the stamps existed.
    /// Adopting them costs nothing; restarting would throw away the only
    /// device evidence the audit has.
    func testCountersFromAnEarlierBuildAdoptTheStampsAndKeepTheirCounts() throws {
        var state = ScreenTimeState()
        var legacy = ScreenTimeCallbackCounters()
        legacy.laneIntervalStarts = 4
        state.callbackCounters = legacy

        state.countThresholdCallback(.recorded, now: now)

        let counters = try XCTUnwrap(state.callbackCounters)
        XCTAssertEqual(counters.generation, 0)
        XCTAssertEqual(counters.laneIntervalStarts, 4)
        XCTAssertEqual(counters.thresholdsRecorded, 1)
        XCTAssertEqual(counters.epoch, state.epoch)
        XCTAssertEqual(counters.dayStart, Calendar.current.startOfDay(for: now))
    }

    /// Same rule as `callbackCounters` itself: the synthesized decoder does
    /// not fall back to a property's default, so every field added here has to
    /// decode from a ledger that predates it or the phone's ledger becomes
    /// `corruptedState` on the very build meant to read it.
    func testCountersDecodeFromALedgerWrittenBeforeTheseFieldsExisted() throws {
        let legacy = """
            {"schedulerIntervalStarts":2,"laneIntervalStarts":0,"otherIntervalStarts":0,\
            "schedulerIntervalEnds":0,"laneIntervalEnds":0,"otherIntervalEnds":0,\
            "thresholds":1,"thresholdsRecorded":0,"thresholdsIgnoredByLedger":0,\
            "thresholdsIgnoredByName":0,"thresholdsUnknownAuthorization":1,\
            "thresholdsDenied":0,"statusUnknownAtCallback":3}
            """
        let decoded = try JSONDecoder().decode(
            ScreenTimeCallbackCounters.self, from: Data(legacy.utf8)
        )
        XCTAssertEqual(decoded.schedulerIntervalStarts, 2)
        XCTAssertEqual(decoded.thresholds, 1)
        XCTAssertEqual(decoded.statusUnknownAtCallback, 3)
        XCTAssertEqual(decoded.generation, 0)
        XCTAssertNil(decoded.epoch)
        XCTAssertNil(decoded.dayStart)
        XCTAssertTrue(decoded.isValid)
        XCTAssertEqual(
            try JSONDecoder().decode(ScreenTimeCallbackCounters.self, from: Data("{}".utf8)),
            ScreenTimeCallbackCounters()
        )

        // And the same counters inside a whole ledger.
        var fields = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(ScreenTimeState()))
                as? [String: Any]
        )
        fields["callbackCounters"] = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(legacy.utf8)) as? [String: Any]
        )
        let state = try JSONDecoder().decode(
            ScreenTimeState.self, from: JSONSerialization.data(withJSONObject: fields)
        )
        XCTAssertEqual(state.callbackCounters?.schedulerIntervalStarts, 2)
        XCTAssertTrue(state.isValid)
    }

    func testEachKindOfCallbackCarriesItsOwnAge() {
        var counters = ScreenTimeCallbackCounters()
        counters.countInterval(kind: .scheduler, phase: .start, at: now.addingTimeInterval(-3_600))
        counters.countInterval(kind: .lane, phase: .start, at: now.addingTimeInterval(-600))
        counters.countThreshold(.recorded, at: now.addingTimeInterval(-60))
        let line = counters.logDescription(now: now)

        XCTAssertTrue(line.contains("generation=0"), line)
        XCTAssertTrue(line.contains("schedulerStartAgeSec=3600"), line)
        XCTAssertTrue(line.contains("laneStartAgeSec=600"), line)
        XCTAssertTrue(line.contains("thresholdAgeSec=60"), line)
        XCTAssertTrue(line.contains("lastAgeSec=60"), line)

        // One shared instant could not say this: a scheduler interval fires at
        // 00:00 whatever else happens, so a small shared age would read as
        // "something was delivered recently" on a day with no lane start.
        var schedulerOnly = ScreenTimeCallbackCounters()
        schedulerOnly.countInterval(kind: .scheduler, phase: .start, at: now.addingTimeInterval(-41))
        let quiet = schedulerOnly.logDescription(now: now)
        XCTAssertTrue(quiet.contains("lastAgeSec=41"), quiet)
        XCTAssertTrue(quiet.contains("laneStartAgeSec=-1"), quiet)
        XCTAssertTrue(quiet.contains("thresholdAgeSec=-1"), quiet)
    }

    /// `Int(_: Double)` traps outside Int64 and on NaN, and `isValid` only
    /// asks a stored date to be finite — `greatestFiniteMagnitude` passes. A
    /// diagnostics line must not be what crashes the app on every launch and
    /// the extension on every callback.
    func testAnAbsurdLedgerDateIsClampedInsteadOfTrapping() {
        var counters = ScreenTimeCallbackCounters()
        counters.lastCallbackAt = Date(timeIntervalSinceReferenceDate: .greatestFiniteMagnitude)
        counters.lastThresholdAt = Date(timeIntervalSinceReferenceDate: -.greatestFiniteMagnitude)
        var state = ScreenTimeState()
        state.callbackCounters = counters
        XCTAssertTrue(state.isValid, "Finiteness is all the validator asks for — hence the clamp")

        let line = counters.logDescription(now: now)
        XCTAssertTrue(line.contains("lastAgeSec=\(Int.min)"), line)
        XCTAssertTrue(line.contains("thresholdAgeSec=\(Int.max)"), line)

        XCTAssertEqual(ScreenTimeDiagnosticSeconds.clamped(.nan), Int.max)
        XCTAssertEqual(ScreenTimeDiagnosticSeconds.clamped(.infinity), Int.max)
        XCTAssertEqual(ScreenTimeDiagnosticSeconds.clamped(-.infinity), Int.min)
        XCTAssertEqual(ScreenTimeDiagnosticSeconds.clamped(2.4), 2)
        XCTAssertEqual(ScreenTimeDiagnosticSeconds.clamped(-2.6), -3)
    }

    // MARK: - the mirror a device audit can actually read

    /// The counters live in the App Group ledger because that is the only
    /// directory the monitor extension shares with the app — and that is why
    /// the 2026-09-20/21 audit could not read a single one of them. The mirror
    /// copies them into the app's OWN container, which
    /// `devicectl device copy from --domain-type appDataContainer` can pull
    /// with no host root and no unified log.
    func testTheMirrorCopiesTheCountersAndTheLaneScheduleIntoTheAppContainer() throws {
        try withMirror { mirror, directory in
            var state = mirroredState()
            state.countIntervalCallback(kind: .lane, phase: .start, now: now.addingTimeInterval(-600))
            state.countThresholdCallback(.ignoredByLedger, now: now.addingTimeInterval(-120))

            mirror.write(state, now: now)

            let url = directory
                .appendingPathComponent(ScreenTimeDiagnosticsMirror.fileName)
            XCTAssertEqual(try XCTUnwrap(mirror.fileURL), url)
            XCTAssertEqual(url.lastPathComponent, "counters.json")
            XCTAssertEqual(directory.lastPathComponent, "ScreenTimeDiagnostics")
            let report = try JSONDecoder().decode(
                ScreenTimeDiagnosticsReport.self, from: Data(contentsOf: url)
            )

            XCTAssertEqual(report.schemaVersion, ScreenTimeDiagnosticsReport.schemaVersion)
            XCTAssertEqual(Self.instantFormatter.date(from: try XCTUnwrap(report.writtenAt)), now,
                           "writtenAt says which pass this file describes")
            XCTAssertTrue(report.configurationEnabled)
            XCTAssertTrue(report.contextIsActive)
            let counters = try XCTUnwrap(report.counters)
            XCTAssertEqual(counters.laneIntervalStarts, 1)
            XCTAssertEqual(counters.thresholds, 1)
            XCTAssertEqual(counters.thresholdsIgnoredByLedger, 1)
            XCTAssertEqual(counters.thresholdsRecorded, 0)
            XCTAssertEqual(counters.generation, 0)
            // The ages are what a reader compares against the usage window,
            // without having to do date arithmetic on the instants.
            XCTAssertEqual(counters.laneIntervalStartAgeSec, 600)
            XCTAssertEqual(counters.thresholdAgeSec, 120)
            XCTAssertEqual(counters.lastCallbackAgeSec, 120)
            XCTAssertEqual(counters.schedulerIntervalStartAgeSec, -1,
                           "-1 means that kind of callback was never counted")
            XCTAssertNil(counters.lastSchedulerIntervalStartAt)

            // The lane's registration, as the ledger holds it: the interval
            // covers the device day, and a run continued across midnight starts
            // at 00:00 with past activity included.
            let run = state.runs[0]
            XCTAssertEqual(report.learning.activeRuns, 1)
            XCTAssertEqual(report.learning.intervalStartOffsetSec,
                           Int(now.timeIntervalSince(run.dayStart)))
            XCTAssertEqual(report.learning.intervalEndOffsetSec,
                           Int(now.timeIntervalSince(run.dayEnd)) + 1)
            XCTAssertEqual(report.learning.runStartedAtOffsetSec, 0,
                           "0 means the run counts from midnight, i.e. a continued day rollover")
            XCTAssertEqual(report.learning.includesPastActivity, true)
            XCTAssertEqual(report.learning.repeats, false)
            // A lane with no active run says so and carries no schedule.
            XCTAssertEqual(report.distraction, .inactive)
            XCTAssertEqual(report.distraction.activeRuns, 0)
            XCTAssertNil(report.distraction.intervalStartOffsetSec)
        }
    }

    /// Unlike the ledger it copies, this file is meant to leave the device.
    /// Counts, booleans, ISO-8601 instants and second offsets — and nothing
    /// else. The key set is asserted exactly, so a field added to the ledger
    /// cannot reach the mirror without this test being updated on purpose.
    func testTheMirroredFileCarriesCountsBooleansAndInstantsOnly() throws {
        try withMirror { mirror, directory in
            var state = mirroredState()
            state.negativeGemCount = 7
            state.runs.append(ScreenTimeRun(
                lane: .distraction, dayStart: state.runs[0].dayStart,
                dayEnd: state.runs[0].dayEnd, startedAt: now.addingTimeInterval(-3_600),
                timeZoneID: state.runs[0].timeZoneID, includesPastActivity: false
            ))
            state.countIntervalCallback(kind: .scheduler, phase: .start, now: now)
            state.countIntervalCallback(kind: .lane, phase: .start, now: now)
            state.countThresholdCallback(.recorded, now: now)
            XCTAssertTrue(state.isValid)

            mirror.write(state, now: now)

            let data = try Data(contentsOf: try XCTUnwrap(mirror.fileURL))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(root.keys), [
                "schemaVersion", "writtenAt", "configurationEnabled", "contextIsActive",
                "learning", "distraction", "counters"
            ])
            for lane in ["learning", "distraction"] {
                let schedule = try XCTUnwrap(root[lane] as? [String: Any], lane)
                XCTAssertEqual(Set(schedule.keys), [
                    "activeRuns", "intervalStartOffsetSec", "intervalEndOffsetSec",
                    "runStartedAtOffsetSec", "includesPastActivity", "repeats"
                ], lane)
            }
            let counters = try XCTUnwrap(root["counters"] as? [String: Any])
            XCTAssertEqual(Set(counters.keys), [
                "generation", "dayStart",
                "schedulerIntervalStarts", "laneIntervalStarts", "otherIntervalStarts",
                "schedulerIntervalEnds", "laneIntervalEnds", "otherIntervalEnds",
                "thresholds", "thresholdsRecorded", "thresholdsIgnoredByLedger",
                "thresholdsIgnoredByName", "thresholdsDenied", "statusUnknownAtCallback",
                "lastCallbackAt", "lastLaneIntervalStartAt", "lastSchedulerIntervalStartAt",
                "lastThresholdAt", "lastCallbackAgeSec", "laneIntervalStartAgeSec",
                "schedulerIntervalStartAgeSec", "thresholdAgeSec"
            ])
            XCTAssertFalse(counters.keys.contains("epoch"),
                           "The ledger epoch is an identifier and stays on the device")

            // Every string in the file is an instant, so no identifier can be
            // hiding in a value either.
            for (path, value) in Self.scalars(in: root) {
                if let text = value as? String {
                    XCTAssertNotNil(Self.instantFormatter.date(from: text), "\(path) = \(text)")
                } else {
                    XCTAssertTrue(value is NSNumber, "\(path) is neither a number nor an instant")
                }
                XCTAssertFalse(path.lowercased().contains("token"), path)
                XCTAssertFalse(path.lowercased().contains("gem"), path)
            }

            // And the identifiers this ledger actually holds are not in the
            // bytes at all, under any key.
            let text = try XCTUnwrap(String(data: data, encoding: .utf8)).lowercased()
            for identifier in [
                state.epoch.uuidString, state.callbackCounters?.epoch?.uuidString ?? "",
                try XCTUnwrap(state.configuration.themeID).uuidString,
                try XCTUnwrap(state.dataEpochID).uuidString,
                state.runs[0].id.uuidString, state.runs[1].id.uuidString,
                try XCTUnwrap(state.contextKey)
            ] where !identifier.isEmpty {
                XCTAssertFalse(text.contains(identifier.lowercased()), identifier)
            }
            // "contextIsActive" is a boolean about the ledger, not the key
            // itself, so the context KEY is covered by the identifier loop.
            for forbidden in ["theme", "token", "gem", "receipt", "epoch", "monitoringerror"] {
                XCTAssertFalse(text.contains(forbidden), forbidden)
            }
        }
    }

    /// The mirror reads the same ledger dates the log line does, so it needs
    /// the same guard: a finite but absurd instant must not trap, and must not
    /// be rendered as if it were a real one.
    func testTheMirrorSurvivesALedgerDateThatIsNotARealInstant() throws {
        try withMirror { mirror, _ in
            var state = mirroredState()
            var counters = ScreenTimeCallbackCounters()
            counters.laneIntervalStarts = 1
            counters.lastLaneIntervalStartAt = Date(timeIntervalSince1970: 1e300)
            counters.lastCallbackAt = Date(timeIntervalSince1970: -1e300)
            state.callbackCounters = counters
            XCTAssertTrue(state.isValid, "isValid only asks a stored date to be finite")

            mirror.write(state, now: now)

            let report = try JSONDecoder().decode(
                ScreenTimeDiagnosticsReport.self,
                from: Data(contentsOf: try XCTUnwrap(mirror.fileURL))
            )
            let mirrored = try XCTUnwrap(report.counters)
            XCTAssertNil(mirrored.lastLaneIntervalStartAt)
            XCTAssertNil(mirrored.lastCallbackAt)
            XCTAssertEqual(mirrored.laneIntervalStartAgeSec, Int.min)
            XCTAssertEqual(mirrored.lastCallbackAgeSec, Int.max)
            XCTAssertEqual(mirrored.laneIntervalStarts, 1)
        }
    }

    /// The foreground refresh loop reloads every three seconds and almost
    /// every pass reads an unchanged ledger. Write when something changed, and
    /// otherwise on the heartbeat, so the file still proves the app ran.
    func testTheMirrorRewritesOnAChangeOrOnTheHeartbeat() throws {
        try withMirror(heartbeat: 60) { mirror, _ in
            let url = try XCTUnwrap(mirror.fileURL)
            func writtenAt() throws -> String? {
                try JSONDecoder().decode(
                    ScreenTimeDiagnosticsReport.self, from: Data(contentsOf: url)
                ).writtenAt
            }
            var state = mirroredState()
            mirror.write(state, now: now)
            let first = try writtenAt()

            mirror.write(state, now: now.addingTimeInterval(3))
            XCTAssertEqual(try writtenAt(), first, "An unchanged ledger does not rewrite the file")

            state.countIntervalCallback(kind: .lane, phase: .start, now: now.addingTimeInterval(6))
            mirror.write(state, now: now.addingTimeInterval(6))
            let second = try writtenAt()
            XCTAssertNotEqual(second, first, "A counted callback is written through at once")

            mirror.write(state, now: now.addingTimeInterval(66))
            XCTAssertNotEqual(try writtenAt(), second, "The heartbeat proves the app is still running")
        }
    }

    // MARK: - fixture

    static let instantFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// A ledger with everything the mirror must NOT copy: a context key, a
    /// data epoch, a theme, run identifiers and a black-gem count.
    private func mirroredState() -> ScreenTimeState {
        var state = ScreenTimeState()
        state.contextKey = "test-owner"
        state.dataEpochID = UUID()
        state.contextIsActive = true
        state.configuration.enabled = true
        state.configuration.themeID = UUID()
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        state.runs = [ScreenTimeRun(
            lane: .learning, dayStart: dayStart,
            dayEnd: calendar.date(byAdding: .day, value: 1, to: dayStart)!,
            // A run that continued across midnight starts at 00:00.
            startedAt: dayStart,
            timeZoneID: calendar.timeZone.identifier,
            includesPastActivity: true,
            themeID: state.configuration.themeID
        )]
        return state
    }

    /// The mirror writes into the app's own container; a temporary directory
    /// stands in for it so the tests never touch the test host's.
    private func withMirror(
        heartbeat: TimeInterval = 0,
        _ body: (ScreenTimeDiagnosticsMirror, URL) throws -> Void
    ) rethrows {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(ScreenTimeDiagnosticsMirror.directoryName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try body(ScreenTimeDiagnosticsMirror(directory: directory, heartbeat: heartbeat), directory)
    }

    /// Every leaf of the decoded file, with the key path that reaches it.
    private static func scalars(in object: [String: Any], at prefix: String = "") -> [(String, Any)] {
        object.flatMap { key, value -> [(String, Any)] in
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = value as? [String: Any] { return scalars(in: nested, at: path) }
            return [(path, value)]
        }
    }

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

/// Accepts every registration and remembers what it was handed. No
/// DeviceActivity, Family Controls or App Group call is made.
private final class FakeCenter: ScreenTimeActivityCenterDriving {
    private var installed: [DeviceActivityName] = []
    private(set) var startedNames: [String] = []
    /// Both `during schedule:` and `events:`, so a registration's shape is
    /// something a test can assert on rather than something the fake drops.
    private(set) var startedSchedules: [(
        name: String,
        schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    )] = []

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
        startedSchedules.append((activity.rawValue, schedule, events))
        if !installed.contains(activity) { installed.append(activity) }
    }
}
