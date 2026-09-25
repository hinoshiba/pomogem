import DeviceActivity
import FamilyControls
import ManagedSettings
import Foundation
import XCTest
@testable import PomoGem

/// screentime-01: the focus timer's hold on the learning lane must end by
/// itself when the timer phase ends. It used to be a Bool with no end that
/// only the foreground app cleared, so a focus that ended while PomoGem was in
/// the background (or with the completion screen still up) kept study-app time
/// from counting — for the rest of the day and the days after.
final class ScreenTimeTimerHoldTests: XCTestCase {
    private var now: Date {
        Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
            .addingTimeInterval(43_200)
    }
    private var dayStart: Date { Calendar.current.startOfDay(for: now) }
    private var dayEnd: Date { Calendar.current.date(byAdding: .day, value: 1, to: dayStart)! }
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        super.tearDown()
    }

    // MARK: - the ledger

    func testALedgerWrittenBeforeTheEndDateExistedDecodesAsTheOldOpenEndedHold() throws {
        var state = ScreenTimeState()
        state.learningPausedByTimer = true
        let data = try JSONEncoder().encode(state)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("learningPausedUntil"),
                       "An absent end must not be written, so older ledgers look the same")
        let decoded = try JSONDecoder().decode(ScreenTimeState.self, from: data)
        XCTAssertNil(decoded.learningPausedUntil)
        XCTAssertTrue(decoded.isValid)
        XCTAssertTrue(decoded.isLearningPaused(at: now.addingTimeInterval(86_400 * 30)))
    }

    func testAHoldWithAnEndIsOverAtThatInstantWithoutAnyWrite() {
        var state = ScreenTimeState()
        let end = now.addingTimeInterval(1_500)
        state.applyTimerPause(.until(end), now: now)
        XCTAssertTrue(state.isLearningPaused(at: now))
        XCTAssertTrue(state.isLearningPaused(at: end.addingTimeInterval(-1)))
        XCTAssertFalse(state.isLearningPaused(at: end))
        state.applyTimerPause(.indefinite, now: now)
        XCTAssertTrue(state.isLearningPaused(at: end.addingTimeInterval(86_400)))
        state.applyTimerPause(.none, now: now)
        XCTAssertFalse(state.isLearningPaused(at: now))
        // A phase whose end already passed holds nothing at all.
        state.applyTimerPause(.until(now.addingTimeInterval(-1)), now: now)
        XCTAssertFalse(state.learningPausedByTimer)
        XCTAssertNil(state.learningPausedUntil)
    }

    func testOnlyTheRunPreArmedForThisHoldSurvivesAHoldAndAnEarlyStopRetiresIt() {
        let end = now.addingTimeInterval(1_500)
        var state = learningState()
        let ordinary = state.runs[0].id
        state.applyTimerPause(.until(end), now: now)
        XCTAssertFalse(state.runs.contains { $0.id == ordinary && $0.active },
                       "A run registered before the timer must not count timer time")

        let preArmed = run(startedAt: end)
        state.runs.append(preArmed)
        XCTAssertTrue(state.isPreArmedLearningRun(preArmed))
        state.applyTimerPause(.until(end), now: now.addingTimeInterval(60))
        XCTAssertTrue(state.runs.contains { $0.id == preArmed.id && $0.active },
                      "Repeating the same hold must not churn its registration")

        // Stopped early: the run still waiting for the planned end would skip
        // the minutes in between, so it goes and a fresh pass starts from now.
        var stoppedEarly = state
        stoppedEarly.applyTimerPause(.none, now: now.addingTimeInterval(300))
        XCTAssertFalse(stoppedEarly.runs.contains { $0.id == preArmed.id && $0.active })

        // Ended on time: the pre-armed run is simply today's learning run now.
        var endedOnTime = state
        endedOnTime.applyTimerPause(.none, now: end.addingTimeInterval(5))
        XCTAssertTrue(endedOnTime.runs.contains { $0.id == preArmed.id && $0.active })

        // A new hold (resume after a pause, a break) retires it.
        var resumed = state
        resumed.applyTimerPause(.until(end.addingTimeInterval(120)), now: now.addingTimeInterval(60))
        XCTAssertFalse(resumed.runs.contains { $0.id == preArmed.id && $0.active })
        var paused = state
        paused.applyTimerPause(.indefinite, now: now.addingTimeInterval(60))
        XCTAssertFalse(paused.runs.contains { $0.id == preArmed.id && $0.active })
    }

    func testAPreArmedRunAwardsOnlyTimeAfterTheHoldEnds() {
        let end = now.addingTimeInterval(1_500)
        var state = learningState()
        state.runs = []
        state.applyTimerPause(.until(end), now: now)
        let preArmed = run(startedAt: end)
        state.runs = [preArmed]
        state.record(runID: preArmed.id, threshold: 1, now: end.addingTimeInterval(-1))
        XCTAssertTrue(state.pendingLearningReceipts(limit: 8).isEmpty)
        state.record(runID: preArmed.id, threshold: 1, now: end.addingTimeInterval(599))
        XCTAssertTrue(state.pendingLearningReceipts(limit: 8).isEmpty,
                      "Ten minutes must pass after the timer ends, not after registration")
        state.record(runID: preArmed.id, threshold: 1, now: end.addingTimeInterval(601))
        XCTAssertEqual(state.pendingLearningReceipts(limit: 8).count, 1)
    }

    func testThePreArmedStartNeedsAFullMonitoringIntervalBeforeMidnight() {
        let intervalEnd = dayEnd.addingTimeInterval(-1)
        let latest = intervalEnd.addingTimeInterval(-ScreenTimePolicy.minimumMonitoringInterval)
        XCTAssertEqual(ScreenTimePolicy.preArmedLearningStart(pausedUntil: latest, now: now, dayEnd: dayEnd), latest)
        XCTAssertNil(ScreenTimePolicy.preArmedLearningStart(
            pausedUntil: latest.addingTimeInterval(1), now: now, dayEnd: dayEnd))
        XCTAssertNil(ScreenTimePolicy.preArmedLearningStart(pausedUntil: nil, now: now, dayEnd: dayEnd))
        XCTAssertNil(ScreenTimePolicy.preArmedLearningStart(pausedUntil: now, now: now, dayEnd: dayEnd))
        XCTAssertNil(ScreenTimePolicy.preArmedLearningStart(
            pausedUntil: dayEnd.addingTimeInterval(600), now: now, dayEnd: dayEnd))
    }

    // MARK: - registration (app and extension share this code)

    func testAHeldLaneIsRegisteredToStartByItselfWhenTheTimerEnds() throws {
        let end = now.addingTimeInterval(1_500)
        let (store, center) = try makeFixture { $0.applyTimerPause(.until(end), now: self.now) }
        let monitor = ScreenTimeMonitoring(store: store, center: center, authorization: { true })
        XCTAssertTrue(try monitor.synchronize(now: now))

        let state = try store.snapshot()
        let learning = try XCTUnwrap(state.runs.first { $0.active && $0.lane == .learning })
        XCTAssertEqual(learning.startedAt, end)
        XCTAssertFalse(learning.includesPastActivity)
        let registrations = center.started.filter { $0.name.hasPrefix(learning.activityPrefix) }
        XCTAssertEqual(registrations.count, ScreenTimePolicy.batchesPerLane)
        let calendar = Calendar(identifier: .gregorian)
        for registration in registrations {
            var components = registration.schedule.intervalStart
            components.calendar = calendar
            let start = try XCTUnwrap(components.date)
            XCTAssertEqual(start.timeIntervalSince(end), 0, accuracy: 1,
                           "The OS must start counting when the timer ends, not at midnight")
        }

        // The same pass again (the app's foreground loop) keeps it as it is.
        center.started.removeAll()
        XCTAssertTrue(try monitor.synchronize(now: now.addingTimeInterval(3)))
        XCTAssertTrue(center.started.isEmpty)
        XCTAssertTrue(try store.snapshot().runs.contains { $0.id == learning.id && $0.active })

        // The OS delivers the first threshold ten minutes after the end.
        let name = learning.activityPrefix + "0"
        try monitor.handleThreshold(eventName: "1", activityName: name, now: end.addingTimeInterval(601))
        XCTAssertEqual(try store.snapshot().pendingLearningReceipts(limit: 8).count, 1)
    }

    func testAHoldEndingTooCloseToMidnightLeavesTheLaneToTheNextDay() throws {
        let end = dayEnd.addingTimeInterval(-600)
        let (store, center) = try makeFixture { $0.applyTimerPause(.until(end), now: self.now) }
        let monitor = ScreenTimeMonitoring(store: store, center: center, authorization: { true })
        _ = try monitor.synchronize(now: now)
        XCTAssertFalse(try store.snapshot().runs.contains { $0.active && $0.lane == .learning })
        XCTAssertNil(try store.snapshot().monitoringError,
                     "An interval DeviceActivity would refuse must not be attempted")
    }

    func testTheMidnightSchedulerRegistersTheLaneOnceAnOldHoldHasEnded() throws {
        // The hold was written yesterday and nobody has opened PomoGem since.
        let (store, center) = try makeFixture {
            $0.learningPausedByTimer = true
            $0.learningPausedUntil = self.dayStart.addingTimeInterval(-3_600)
            $0.runs = []
        }
        let monitor = ScreenTimeMonitoring.forMonitorExtension(
            store: store, center: center, lockTimeout: 1, authorizationStatus: { .notDetermined })
        let scheduler = ScreenTimeMonitoring.schedulerName(epoch: try store.snapshot().epoch)
        try monitor.handleInterval(activityName: scheduler, phase: .start, now: dayStart.addingTimeInterval(1))
        let learning = try XCTUnwrap(try store.snapshot().runs.first { $0.active && $0.lane == .learning })
        XCTAssertEqual(learning.dayStart, dayStart)
        XCTAssertFalse(center.started.filter { $0.name.hasPrefix(learning.activityPrefix) }.isEmpty)
    }

    func testTheOtherLanesCallbackRegistersTheLaneAfterAHoldTheAppNeverPreArmed() throws {
        // The app wrote the hold, then was suspended before it could register
        // the pre-armed run. The distraction lane is running normally.
        let distractionRun = ScreenTimeRun(
            lane: .distraction, dayStart: dayStart, dayEnd: dayEnd,
            startedAt: now.addingTimeInterval(-7_200), timeZoneID: Calendar.current.timeZone.identifier,
            includesPastActivity: false, themeID: nil
        )
        let end = now.addingTimeInterval(-60)
        let (store, center) = try makeFixture(distractionApplications: 1) {
            $0.learningPausedByTimer = true
            $0.learningPausedUntil = end
            $0.runs = [distractionRun]
        }
        let installed = (0..<ScreenTimePolicy.batchesPerLane).map { distractionRun.activityPrefix + String($0) }
        center.installed = Set(installed)
        let monitor = ScreenTimeMonitoring.forMonitorExtension(
            store: store, center: center, lockTimeout: 1, authorizationStatus: { .notDetermined })
        try monitor.handleThreshold(eventName: "1", activityName: installed[0], now: now)
        let state = try store.snapshot()
        XCTAssertEqual(state.negativeGemCount, 1)
        let learning = try XCTUnwrap(state.runs.first { $0.active && $0.lane == .learning })
        XCTAssertEqual(learning.startedAt, now)

        // Once registered, ordinary traffic triggers no further passes.
        center.started.removeAll()
        try monitor.handleThreshold(eventName: "2", activityName: installed[0], now: now.addingTimeInterval(600))
        XCTAssertTrue(center.started.isEmpty)
    }

    // MARK: - which timer state holds the lane

    func testTheSavedTimerDecidesTheHoldAndTheCompletionScreenHoldsNothing() throws {
        let epoch = UUID()
        let start = now
        var focusing = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try focusing.startFocus(isPro: false, now: start)
        let end = try XCTUnwrap(focusing.endDate)
        XCTAssertEqual(hold(focusing, epoch: epoch, at: start.addingTimeInterval(60)), .until(end))
        // Not advanced yet, but over: nothing to hold.
        XCTAssertEqual(hold(focusing, epoch: epoch, at: end.addingTimeInterval(1)), .none)
        // A timer frozen under another reset generation holds nothing.
        XCTAssertEqual(hold(focusing, epoch: epoch, currentEpoch: UUID(), at: start.addingTimeInterval(60)), .none)
        XCTAssertEqual(ScreenTimeTimerHold.learningPause(for: nil, dataEpochID: epoch, at: start), .none)

        var paused = focusing
        try paused.pause(at: start.addingTimeInterval(120))
        XCTAssertEqual(hold(paused, epoch: epoch, at: start.addingTimeInterval(86_400)), .indefinite)

        var completed = focusing
        let event = try XCTUnwrap(completed.advance(at: end))
        guard case let .focusCompleted(completion) = event else { return XCTFail("Expected completion") }
        XCTAssertEqual(hold(completed, epoch: epoch, at: end), .none)
        let pending = FocusRecoveryEnvelope(
            engine: completed, subject: nil, clockAnchor: nil,
            pendingCompletion: completion, savedAt: end, dataEpochID: epoch
        )
        XCTAssertEqual(ScreenTimeTimerHold.learningPause(for: pending, dataEpochID: epoch, at: end), .none,
                       "The completion screen must not hold the lane")

        var onBreak = completed
        try onBreak.startBreak(now: end.addingTimeInterval(30))
        let breakEnd = try XCTUnwrap(onBreak.endDate)
        XCTAssertEqual(hold(onBreak, epoch: epoch, at: end.addingTimeInterval(60)), .until(breakEnd))
    }

    // MARK: - helpers

    private func hold(
        _ engine: PomodoroEngine, epoch: UUID, currentEpoch: UUID? = nil, at date: Date
    ) -> ScreenTimeLearningPause {
        ScreenTimeTimerHold.learningPause(
            for: FocusRecoveryEnvelope(engine: engine, subject: nil, clockAnchor: nil,
                                       pendingCompletion: nil, savedAt: now, dataEpochID: epoch),
            dataEpochID: currentEpoch ?? epoch, at: date
        )
    }

    private func run(startedAt: Date, lane: ScreenTimeLane = .learning) -> ScreenTimeRun {
        ScreenTimeRun(
            lane: lane, dayStart: dayStart, dayEnd: dayEnd, startedAt: startedAt,
            timeZoneID: Calendar.current.timeZone.identifier, includesPastActivity: false,
            themeID: lane == .learning ? UUID() : nil
        )
    }

    private func learningState() -> ScreenTimeState {
        var state = ScreenTimeState()
        state.contextKey = "owner"
        state.contextIsActive = true
        state.configuration.enabled = true
        state.configuration.themeID = UUID()
        state.runs = [run(startedAt: now.addingTimeInterval(-1_200))]
        return state
    }

    private func selection(count: Int, seed: UInt8) throws -> FamilyActivitySelection {
        var selection = FamilyActivitySelection(includeEntireCategory: false)
        selection.applicationTokens = Set(try (0..<count).map { index in
            try JSONDecoder().decode(ApplicationToken.self,
                                     from: JSONEncoder().encode(["data": Data([seed, UInt8(index)])]))
        })
        return selection
    }

    private func makeFixture(
        distractionApplications: Int = 0,
        _ adjust: @escaping (inout ScreenTimeState) -> Void
    ) throws -> (ScreenTimeStore, HoldFakeCenter) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        let store = ScreenTimeStore(directory: directory)
        var state = ScreenTimeState()
        state.contextKey = "owner"
        state.contextIsActive = true
        state.configuration.enabled = true
        state.configuration.themeID = UUID()
        state.configuration.learningSelection = try selection(count: 2, seed: 0x31)
        if distractionApplications > 0 {
            state.configuration.distractionSelection = try selection(count: distractionApplications, seed: 0x32)
        }
        adjust(&state)
        try store.update { $0 = state }
        return (store, HoldFakeCenter())
    }
}

private final class HoldFakeCenter: ScreenTimeActivityCenterDriving {
    var installed: Set<String> = []
    var started: [(name: String, schedule: DeviceActivitySchedule)] = []

    var activities: [DeviceActivityName] { installed.map(DeviceActivityName.init(rawValue:)) }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        if activities.isEmpty { installed.removeAll() }
        else { installed.subtract(activities.map(\.rawValue)) }
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        started.append((activity.rawValue, schedule))
        installed.insert(activity.rawValue)
    }
}
