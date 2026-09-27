import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import XCTest
@testable import PomoGem

/// F2: the focus shield's shared core — the record, the failsafe interval and
/// the three removal paths. Everything here also runs in the monitor
/// extension, which unit tests cannot load, so the extension's rule is
/// exercised through `FocusShieldEngine.handleExtensionInterval`.
final class FocusShieldEngineTests: XCTestCase {
    private var directories: [URL] = []
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        super.tearDown()
    }

    // MARK: - schedule math

    func testEveryFocusGetsAnIntervalThatStartsAtItsPlannedEndRoundedUp() throws {
        let calendar = tokyo
        // A 4-minute focus whose planned end carries a fraction of a second.
        let deadline = now.addingTimeInterval(5 * 60 + 0.7)
        let plannedEnd = FocusShieldPolicy.plannedEnd(forDeadline: deadline)
        let bounds = FocusShieldSchedule.intervalBounds(deadline: deadline)
        XCTAssertEqual(bounds.start, now.addingTimeInterval(4 * 60 + 1),
                       "Whole seconds, rounded UP: the start never comes before the planned end it stands for")
        XCTAssertGreaterThanOrEqual(bounds.start, plannedEnd)
        XCTAssertLessThan(bounds.start.timeIntervalSince(plannedEnd), 1)
        XCTAssertEqual(bounds.end.timeIntervalSince(bounds.start), FocusShieldPolicy.minimumInterval,
                       "Exactly DeviceActivity's minimum, however short the focus")

        let plans = FocusShieldSchedule.plans(deadline: deadline, now: now, calendar: calendar)
        XCTAssertEqual(plans.map(\.form), [.localDate, .utcDate, .timeOfDay],
                       "The dated local form the gem lanes use (and the device saw start) comes first")
        let local = try XCTUnwrap(plans.first)
        XCTAssertFalse(local.schedule.repeats)
        XCTAssertEqual(Set(componentKeys(local.schedule.intervalStart)),
                       ["year", "month", "day", "hour", "minute", "second"])
        XCTAssertEqual(local.schedule.intervalStart.timeZone, calendar.timeZone)
        let timeOfDay = try XCTUnwrap(plans.last)
        XCTAssertEqual(Set(componentKeys(timeOfDay.schedule.intervalStart)), ["hour", "minute", "second"])
        XCTAssertEqual(Set(componentKeys(timeOfDay.schedule.intervalEnd)), ["hour", "minute", "second"])
        for plan in plans {
            let resolved = try XCTUnwrap(Self.resolve(plan.schedule, now: now, calendar: calendar))
            XCTAssertEqual(resolved.start, bounds.start, "\(plan.form) must start at the planned end")
            XCTAssertEqual(resolved.end, bounds.end, "\(plan.form) must end 15 minutes later")
        }
    }

    func testTheLongestFocusStillStartsItsIntervalAtItsPlannedEnd() {
        let plannedEnd = now.addingTimeInterval(TimeInterval(Constants.Timer.customMaximumMinutes * 60))
        let deadline = FocusShieldPolicy.deadline(forPlannedEnd: plannedEnd)
        XCTAssertEqual(FocusShieldSchedule.intervalBounds(deadline: deadline).start, plannedEnd)
        XCTAssertEqual(FocusShieldSchedule.plans(deadline: deadline, now: now, calendar: tokyo).count, 3,
                       "Six hours ahead is still within one day for the time-of-day form")
    }

    func testNothingIsRegisteredOnceThePlannedEndIsNotAhead() {
        for (offset, expected) in [(30.0, false), (60.0, false), (60.5, true), (61.0, true)] {
            let deadline = now.addingTimeInterval(offset)
            XCTAssertEqual(FocusShieldSchedule.canRegister(deadline: deadline, now: now), expected, "\(offset)")
            XCTAssertEqual(FocusShieldSchedule.plans(deadline: deadline, now: now, calendar: tokyo).isEmpty, !expected,
                           "An interval that starts at once would clear at once: \(offset)")
        }
    }

    func testAnIntervalAcrossMidnightNamesTheNextDay() throws {
        let calendar = tokyo
        let midnight = calendar.startOfDay(for: now.addingTimeInterval(86_400))
        // Starts before midnight, ends after it.
        let straddling = FocusShieldPolicy.deadline(forPlannedEnd: midnight.addingTimeInterval(-5 * 60))
        let plans = FocusShieldSchedule.plans(deadline: straddling, now: midnight.addingTimeInterval(-30 * 60),
                                              calendar: calendar)
        XCTAssertEqual(plans.count, 3)
        let timeOfDay = try XCTUnwrap(plans.first { $0.form == .timeOfDay })
        XCTAssertEqual(timeOfDay.schedule.intervalStart.hour, 23)
        XCTAssertEqual(timeOfDay.schedule.intervalEnd.hour, 0)
        let local = try XCTUnwrap(plans.first { $0.form == .localDate })
        XCTAssertEqual(local.schedule.intervalEnd.day, calendar.component(.day, from: midnight),
                       "The dated form names the next day explicitly")

        // Wholly after midnight while the focus runs before it.
        let tomorrow = FocusShieldPolicy.deadline(forPlannedEnd: midnight.addingTimeInterval(10 * 60))
        let focusNow = midnight.addingTimeInterval(-10 * 60)
        for plan in FocusShieldSchedule.plans(deadline: tomorrow, now: focusNow, calendar: calendar) {
            let resolved = try XCTUnwrap(Self.resolve(plan.schedule, now: focusNow, calendar: calendar))
            XCTAssertEqual(resolved.start, midnight.addingTimeInterval(10 * 60),
                           "\(plan.form) must mean tonight's 00:10, not today's")
        }
    }

    func testARepeatedDaylightSavingHourNeverNamesTheWrongOccurrence() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        // 2026-10-25: 03:00 CEST becomes 02:00 CET, so 02:00–02:59 happens twice.
        let first = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T00:35:00Z")) // 02:35 CEST
        let second = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T01:35:00Z")) // 02:35 CET
        var withoutLocalDate = 0
        for plannedEnd in [first, second] {
            let focusNow = plannedEnd.addingTimeInterval(-20 * 60)
            let plans = FocusShieldSchedule.plans(deadline: FocusShieldPolicy.deadline(forPlannedEnd: plannedEnd),
                                                  now: focusNow, calendar: calendar)
            XCTAssertTrue(plans.contains { $0.form == .utcDate }, "The unambiguous form is always available")
            for plan in plans {
                let resolved = try XCTUnwrap(Self.resolve(plan.schedule, now: focusNow, calendar: calendar))
                XCTAssertEqual(resolved.start, plannedEnd, "\(plan.form) must name this occurrence of 02:35")
                XCTAssertEqual(resolved.end, plannedEnd.addingTimeInterval(FocusShieldPolicy.minimumInterval))
            }
            if !plans.contains(where: { $0.form == .localDate }) { withoutLocalDate += 1 }
        }
        XCTAssertEqual(withoutLocalDate, 1,
                       "One local 02:35 cannot name both occurrences; the other falls back")
    }

    func testASkippedDaylightSavingHourIsCrossedByRealTimeNotWallClockTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-08: 02:00 EST jumps to 03:00 EDT. Planned end 01:55 EST, so
        // the interval's 15 minutes end at 03:10 EDT on the wall clock.
        let plannedEnd = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T06:55:00Z"))
        let deadline = FocusShieldPolicy.deadline(forPlannedEnd: plannedEnd)
        let focusNow = plannedEnd.addingTimeInterval(-25 * 60)
        let plans = FocusShieldSchedule.plans(deadline: deadline, now: focusNow, calendar: calendar)
        XCTAssertEqual(plans.map(\.form), [.localDate, .utcDate, .timeOfDay])
        for plan in plans {
            let resolved = try XCTUnwrap(Self.resolve(plan.schedule, now: focusNow, calendar: calendar))
            XCTAssertEqual(resolved.start, plannedEnd, "\(plan.form)")
            XCTAssertEqual(resolved.end.timeIntervalSince(resolved.start), FocusShieldPolicy.minimumInterval,
                           "\(plan.form) must last 15 real minutes across the jump")
        }
        let timeOfDay = try XCTUnwrap(plans.last)
        XCTAssertEqual(timeOfDay.schedule.intervalStart.hour, 1)
        XCTAssertEqual(timeOfDay.schedule.intervalEnd.hour, 3)
        XCTAssertEqual(timeOfDay.schedule.intervalEnd.minute, 10)

        // A framework that reads 01:55–03:10 as 75 real minutes is refused, and
        // with the dated forms refused too, nothing at all is registered.
        let naive = DateInterval(start: plannedEnd, end: plannedEnd.addingTimeInterval(75 * 60))
        XCTAssertFalse(FocusShieldSchedule.accepts(naive, plan: timeOfDay, now: focusNow))
        let center = ShieldFakeCenter()
        XCTAssertThrowsError(try FocusShieldSchedule.register(
            center: center, deadline: deadline, now: focusNow, calendar: calendar,
            resolveInterval: { $0.intervalStart.year == nil ? naive : nil }))
        XCTAssertTrue(center.started.isEmpty)
        XCTAssertEqual(try FocusShieldSchedule.register(
            center: center, deadline: deadline, now: focusNow, calendar: calendar,
            resolveInterval: { schedule in
                schedule.intervalStart.year == nil ? Self.resolve(schedule, now: focusNow, calendar: calendar) : nil
            }), .timeOfDay, "A framework that resolves the jump correctly gets the time-of-day form")
    }

    func testTheFrameworksIntervalMustStartAtThePlannedEnd() throws {
        let deadline = now.addingTimeInterval(20 * 60)
        let plan = try XCTUnwrap(FocusShieldSchedule.plans(deadline: deadline, now: now, calendar: tokyo).first)
        XCTAssertTrue(FocusShieldSchedule.accepts(DateInterval(start: plan.start, end: plan.end), plan: plan, now: now))
        XCTAssertFalse(FocusShieldSchedule.accepts(nil, plan: plan, now: now))
        XCTAssertFalse(FocusShieldSchedule.accepts(
            DateInterval(start: plan.start.addingTimeInterval(86_400), end: plan.end.addingTimeInterval(86_400)),
            plan: plan, now: now), "Tomorrow's interval leaves the shield up all night")
        XCTAssertFalse(FocusShieldSchedule.accepts(DateInterval(start: now, end: plan.end), plan: plan, now: now),
                       "An interval already running starts — and clears — at once")
        XCTAssertFalse(FocusShieldSchedule.accepts(
            DateInterval(start: plan.start, end: plan.end.addingTimeInterval(3_600)), plan: plan, now: now))
        XCTAssertTrue(FocusShieldSchedule.accepts(
            DateInterval(start: plan.start.addingTimeInterval(1), end: plan.end.addingTimeInterval(1)),
            plan: plan, now: now))
    }

    func testRegistrationFallsBackFormByFormAndRefusesWhenNoneIsConfirmed() throws {
        let center = ShieldFakeCenter()
        let deadline = now.addingTimeInterval(20 * 60)
        var asked: [FocusShieldSchedule.Form] = []
        let form = try FocusShieldSchedule.register(
            center: center, deadline: deadline, now: now, calendar: tokyo,
            resolveInterval: { schedule in
                let plan = FocusShieldSchedule.plans(deadline: deadline, now: self.now, calendar: self.tokyo)
                    .first { $0.schedule == schedule }!
                asked.append(plan.form)
                // The framework misreads the local dated form.
                return plan.form == .localDate ? nil : DateInterval(start: plan.start, end: plan.end)
            })
        XCTAssertEqual(form, .utcDate)
        XCTAssertEqual(asked, [.localDate, .utcDate])
        XCTAssertEqual(center.started.map(\.name), [FocusShieldPolicy.activityName.rawValue])

        let refused = ShieldFakeCenter()
        XCTAssertThrowsError(try FocusShieldSchedule.register(
            center: refused, deadline: deadline, now: now, calendar: tokyo, resolveInterval: { _ in nil }))
        XCTAssertTrue(refused.started.isEmpty, "Nothing unconfirmed is ever registered")

        let throwing = ShieldFakeCenter()
        throwing.failuresBeforeSuccess = 1
        XCTAssertEqual(try FocusShieldSchedule.register(
            center: throwing, deadline: deadline, now: now, calendar: tokyo,
            resolveInterval: exactResolver(deadline: deadline)), .utcDate,
            "A form the framework refuses falls through to the next one")

        let late = ShieldFakeCenter()
        XCTAssertThrowsError(try FocusShieldSchedule.register(
            center: late, deadline: now.addingTimeInterval(59), now: now, calendar: tokyo,
            resolveInterval: { _ in
                XCTFail("Nothing is even offered to the framework")
                return nil
            }))
        XCTAssertTrue(late.started.isEmpty, "A planned end already behind registers nothing")
    }

    /// The real `DeviceActivitySchedule.nextInterval`, as the Simulator
    /// computes it. Evidence for the future-start form only; the device check
    /// is listed in Docs/ScreenTimeGems.md.
    func testTheFrameworksNextIntervalConfirmsAnIntervalStartingAtThePlannedEnd() throws {
        let realNow = Date()
        for focus: TimeInterval in [4 * 60, 25 * 60] {
            let deadline = FocusShieldPolicy.deadline(forPlannedEnd: realNow.addingTimeInterval(focus))
            let plans = FocusShieldSchedule.plans(deadline: deadline, now: realNow, calendar: .current)
            let confirmed = plans.filter {
                FocusShieldSchedule.accepts($0.schedule.nextInterval, plan: $0, now: realNow)
            }
            XCTAssertFalse(confirmed.isEmpty, "At least one form must resolve to the interval we meant: "
                           + plans.map { "\($0.form.rawValue)=\(String(describing: $0.schedule.nextInterval))" }
                            .joined(separator: " "))
        }
    }

    // MARK: - record transitions

    func testApplyWritesTheRecordThenTheFailsafeThenTheShieldAndRepeatsNothing() throws {
        let fixture = makeEngine()
        let session = UUID()
        let deadline = now.addingTimeInterval(25 * 60 + 60)
        let apps = try tokens(3)

        XCTAssertEqual(try fixture.engine.apply(sessionID: session, deadline: deadline, applications: apps, now: now),
                       .applied(registered: true))
        let record = try XCTUnwrap(try fixture.engine.records.load())
        XCTAssertEqual(record, FocusShieldRecord(active: true, sessionID: session, deadline: deadline, appliedAt: now,
                                                 failsafeDeadline: deadline))
        XCTAssertEqual(fixture.center.started.map(\.name), [FocusShieldPolicy.activityName.rawValue])
        XCTAssertEqual(fixture.settings.shielded, [apps])
        XCTAssertEqual(fixture.settings.events, ["shield failsafe=armed record=active"],
                       "The shield is written only after its record and its kill-proof end exist")

        // The same focus again (a background save, a 3 s pass): no new registration.
        XCTAssertEqual(try fixture.engine.apply(sessionID: session, deadline: deadline, applications: apps,
                                                now: now.addingTimeInterval(30)), .applied(registered: false))
        XCTAssertEqual(fixture.center.started.count, 1)
        XCTAssertEqual(try fixture.engine.records.load()?.appliedAt, now)

        // Resumed after a pause: a new deadline re-registers the same name in place.
        let later = deadline.addingTimeInterval(300)
        XCTAssertEqual(try fixture.engine.apply(sessionID: session, deadline: later, applications: apps,
                                                now: now.addingTimeInterval(600)), .applied(registered: true))
        XCTAssertEqual(fixture.center.started.map(\.name),
                       Array(repeating: FocusShieldPolicy.activityName.rawValue, count: 2))
        XCTAssertEqual(try fixture.engine.records.load()?.deadline, later)
        XCTAssertEqual(try fixture.engine.records.load()?.failsafeDeadline, later)
    }

    /// `DeviceActivityCenter.activities` keeps listing a name whose interval
    /// has ended. A record written just before a crash (active, but with no
    /// confirmed failsafe for its deadline) must not be trusted because of it.
    func testAListedNameIsNotTakenForAFailsafeTheRecordNeverConfirmed() throws {
        let fixture = makeEngine()
        let session = UUID()
        let deadline = now.addingTimeInterval(1_560)
        let apps = try tokens(2)
        fixture.center.installed = [FocusShieldPolicy.activityName.rawValue] // an earlier focus's, long over
        try fixture.engine.records.update(timeout: 1) {
            $0 = FocusShieldRecord(active: true, sessionID: session, deadline: deadline, appliedAt: now)
        }
        XCTAssertEqual(try fixture.engine.apply(sessionID: session, deadline: deadline, applications: apps,
                                                now: now.addingTimeInterval(5)), .applied(registered: true),
                       "The relaunch re-registers instead of shielding behind an ended interval")
        XCTAssertEqual(fixture.center.started.count, 1)

        // The same gap under a pause: keep repairs it too.
        let paused = makeEngine()
        paused.center.installed = [FocusShieldPolicy.activityName.rawValue]
        try paused.engine.records.update(timeout: 1) {
            $0 = FocusShieldRecord(active: true, sessionID: session, deadline: deadline, appliedAt: now,
                                   failsafeDeadline: deadline.addingTimeInterval(-300))
        }
        XCTAssertEqual(try paused.engine.keep(applications: apps, now: now.addingTimeInterval(5)), .kept)
        XCTAssertEqual(paused.center.started.count, 1)
        XCTAssertEqual(try paused.engine.records.load()?.failsafeDeadline, deadline)
        XCTAssertEqual(paused.settings.events, ["shield failsafe=armed record=active"])
    }

    func testClearLiftsTheShieldMarksTheRecordAndOnlyThenStopsTheFailsafeByName() throws {
        let fixture = makeEngine()
        fixture.center.installed = ["pomogem.screen-time.scheduler.\(UUID().uuidString)"]
        let session = UUID()
        _ = try fixture.engine.apply(sessionID: session, deadline: now.addingTimeInterval(1_560),
                                     applications: try tokens(2), now: now)
        XCTAssertEqual(try fixture.engine.clear(reason: .focusEnded, now: now.addingTimeInterval(60)), .cleared)
        XCTAssertEqual(fixture.settings.clearCount, 1)
        XCTAssertEqual(fixture.settings.events.last, "clear failsafe=armed record=active",
                       "The store is emptied while the record and the failsafe still stand, so dying here leaves a way out")
        let record = try XCTUnwrap(try fixture.engine.records.load())
        XCTAssertFalse(record.active)
        XCTAssertNil(record.failsafeDeadline)
        XCTAssertEqual(record.clearedBy, FocusShieldClearReason.focusEnded.rawValue)
        XCTAssertEqual(fixture.center.stopped, [[FocusShieldPolicy.activityName.rawValue]],
                       "Never stopMonitoring([]): that stops the gem lanes too")
        XCTAssertEqual(fixture.center.installed.count, 1, "The lane scheduler stays installed")

        // Nothing active: a second clear touches nothing.
        XCTAssertEqual(try fixture.engine.clear(reason: .focusEnded, now: now.addingTimeInterval(61)), .unchanged)
        XCTAssertEqual(fixture.settings.clearCount, 1)
        XCTAssertEqual(fixture.center.stopped.count, 1)
    }

    /// The monitor extension can hold the record lock longer than the app
    /// waits. The clear must then fail before stopping anything, so the
    /// failsafe survives to end the shield it guards.
    func testAClearThatCannotTakeTheLockLeavesTheShieldItsFailsafe() throws {
        let fixture = makeEngine()
        let session = UUID()
        _ = try fixture.engine.apply(sessionID: session, deadline: now.addingTimeInterval(1_560),
                                     applications: try tokens(1), now: now)
        let descriptor = try holdLock(in: fixture.directory)
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        XCTAssertThrowsError(try fixture.engine.clear(reason: .focusEnded, now: now.addingTimeInterval(60)))
        XCTAssertThrowsError(try fixture.engine.lift(sessionID: session, now: now.addingTimeInterval(60)))
        XCTAssertTrue(fixture.center.installed.contains(FocusShieldPolicy.activityName.rawValue))
        XCTAssertTrue(fixture.center.stopped.isEmpty)
        XCTAssertEqual(fixture.settings.clearCount, 0)
        XCTAssertEqual(try fixture.engine.records.load()?.active, true)
    }

    func testAFailsafeThatCannotBeRegisteredMeansNoShieldAtAll() throws {
        let fixture = makeEngine(resolve: { _ in nil })
        let outcome = try fixture.engine.apply(sessionID: UUID(), deadline: now.addingTimeInterval(1_560),
                                               applications: try tokens(2), now: now)
        XCTAssertEqual(outcome, .failsafeUnavailable)
        XCTAssertTrue(fixture.settings.shielded.isEmpty)
        XCTAssertEqual(try fixture.engine.records.load()?.active, false)
        XCTAssertEqual(try fixture.engine.records.load()?.clearedBy, FocusShieldClearReason.failsafeUnavailable.rawValue)
    }

    func testNoShieldIsStartedOrReArmedPastItsPlannedEnd() throws {
        let fixture = makeEngine()
        // Inside the 60 s grace: the focus is over, only not advanced yet.
        XCTAssertEqual(try fixture.engine.apply(sessionID: UUID(), deadline: now.addingTimeInterval(30),
                                                applications: try tokens(1), now: now), .cleared)
        XCTAssertTrue(fixture.settings.shielded.isEmpty)
        XCTAssertTrue(fixture.center.started.isEmpty)
        XCTAssertEqual(try fixture.engine.records.load()?.clearedBy, FocusShieldClearReason.deadlinePassed.rawValue)

        // A paused focus whose failsafe went missing after its planned end.
        let paused = makeEngine()
        let deadline = now.addingTimeInterval(1_560)
        _ = try paused.engine.apply(sessionID: UUID(), deadline: deadline, applications: try tokens(1), now: now)
        paused.center.installed.removeAll()
        XCTAssertEqual(try paused.engine.keep(applications: try tokens(1), now: deadline.addingTimeInterval(-30)),
                       .cleared)
        XCTAssertEqual(paused.center.started.count, 1)
    }

    func testLiftingKeepsThatSessionUnshieldedButTheNextFocusIsShieldedAgain() throws {
        let fixture = makeEngine()
        let session = UUID()
        let deadline = now.addingTimeInterval(1_560)
        let apps = try tokens(2)
        _ = try fixture.engine.apply(sessionID: session, deadline: deadline, applications: apps, now: now)
        XCTAssertEqual(try fixture.engine.lift(sessionID: session, now: now.addingTimeInterval(10)), .cleared)
        XCTAssertEqual(fixture.settings.events.last, "clear failsafe=armed record=active")
        XCTAssertEqual(fixture.center.stopped, [[FocusShieldPolicy.activityName.rawValue]])
        XCTAssertEqual(try fixture.engine.records.load()?.liftedAt, now.addingTimeInterval(10))
        XCTAssertEqual(try fixture.engine.apply(sessionID: session, deadline: deadline.addingTimeInterval(60),
                                                applications: apps, now: now.addingTimeInterval(20)), .unchanged,
                       "A resume of the lifted session must not shield again")
        XCTAssertEqual(fixture.settings.shielded.count, 1)

        let next = UUID()
        XCTAssertEqual(try fixture.engine.apply(sessionID: next, deadline: deadline.addingTimeInterval(1_800),
                                                applications: apps, now: now.addingTimeInterval(900)),
                       .applied(registered: true))
        XCTAssertNil(try fixture.engine.records.load()?.liftedAt)
    }

    func testKeepNeverMovesTheDeadlineAndOnlyRepairsAMissingFailsafe() throws {
        let fixture = makeEngine()
        let deadline = now.addingTimeInterval(1_560)
        let apps = try tokens(2)
        _ = try fixture.engine.apply(sessionID: UUID(), deadline: deadline, applications: apps, now: now)
        XCTAssertEqual(try fixture.engine.keep(applications: apps, now: now.addingTimeInterval(600)), .kept)
        XCTAssertEqual(fixture.center.started.count, 1, "A pause does not touch DeviceActivity")
        XCTAssertEqual(try fixture.engine.records.load()?.deadline, deadline)

        fixture.center.installed.removeAll()
        XCTAssertEqual(try fixture.engine.keep(applications: apps, now: now.addingTimeInterval(700)), .kept)
        XCTAssertEqual(fixture.center.started.count, 2)

        XCTAssertEqual(try fixture.engine.keep(applications: apps, now: deadline), .cleared,
                       "A pause past the deadline lifts the shield")
    }

    func testAnUnreadableRecordIsTreatedAsAShieldThatMustComeDown() throws {
        let fixture = makeEngine()
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fixture.directory.appendingPathComponent("focus-shield.json"))
        XCTAssertEqual(fixture.engine.sweepExpired(now: now), .cleared)
        XCTAssertEqual(fixture.settings.clearCount, 1)
        XCTAssertFalse(fixture.engine.records.exists)

        try Data("{}".utf8).write(to: fixture.directory.appendingPathComponent("focus-shield.json"))
        XCTAssertEqual(try fixture.engine.apply(sessionID: UUID(), deadline: now.addingTimeInterval(1_560),
                                                applications: try tokens(1), now: now),
                       .applied(registered: true), "Apply recovers and starts over")
    }

    func testARecordFromBeforeTheFailsafeDeadlineFieldStillDecodes() throws {
        let fixture = makeEngine()
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let old = FocusShieldRecord(active: true, sessionID: UUID(), deadline: now.addingTimeInterval(1_560),
                                    appliedAt: now)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "failsafeDeadline")
        try JSONSerialization.data(withJSONObject: json)
            .write(to: fixture.directory.appendingPathComponent("focus-shield.json"))
        XCTAssertEqual(try fixture.engine.records.load(), old)
    }

    // MARK: - removal paths 2 and 3

    func testTheExtensionClearsAtThePlannedEndAndNeverBefore() throws {
        let fixture = makeEngine()
        let plannedEnd = now.addingTimeInterval(1_500)
        let deadline = FocusShieldPolicy.deadline(forPlannedEnd: plannedEnd)
        _ = try fixture.engine.apply(sessionID: UUID(), deadline: deadline, applications: try tokens(2), now: now)
        XCTAssertEqual(FocusShieldSchedule.intervalBounds(deadline: deadline).start, plannedEnd,
                       "intervalDidStart is due exactly at the planned end")

        // A stale or early callback while the focus runs keeps the shield.
        XCTAssertFalse(fixture.engine.handleExtensionInterval(phase: .start, now: now.addingTimeInterval(1)))
        XCTAssertFalse(fixture.engine.handleExtensionInterval(phase: .start, now: plannedEnd.addingTimeInterval(-0.001)))
        XCTAssertEqual(fixture.settings.clearCount, 0)

        XCTAssertTrue(fixture.engine.handleExtensionInterval(phase: .start, now: plannedEnd))
        XCTAssertEqual(fixture.settings.clearCount, 1)
        let record = try XCTUnwrap(try fixture.engine.records.load())
        XCTAssertFalse(record.active)
        XCTAssertEqual(record.clearedBy, FocusShieldClearReason.extensionStart.rawValue)
        XCTAssertTrue(fixture.center.stopped.isEmpty, "The extension never stops monitoring")

        // intervalDidEnd, 15 minutes later, is the second chance.
        let second = makeEngine()
        _ = try second.engine.apply(sessionID: UUID(), deadline: deadline, applications: try tokens(2), now: now)
        let end = FocusShieldSchedule.intervalBounds(deadline: deadline).end
        XCTAssertTrue(second.engine.handleExtensionInterval(phase: .end, now: end))
        XCTAssertEqual(try second.engine.records.load()?.clearedBy, FocusShieldClearReason.extensionEnd.rawValue)
    }

    func testTheExtensionRuleIsThePlannedEndExactly() {
        let deadline = now.addingTimeInterval(1_560)
        var record = FocusShieldRecord(active: true, sessionID: UUID(), deadline: deadline, appliedAt: now,
                                       failsafeDeadline: deadline)
        XCTAssertEqual(FocusShieldPolicy.extensionClearMargin, FocusShieldPolicy.deadlineGrace,
                       "The extension clears at the planned end, not before and not a minute late")
        XCTAssertTrue(FocusShieldPolicy.extensionShouldClear(record, now: deadline.addingTimeInterval(-60)))
        XCTAssertFalse(FocusShieldPolicy.extensionShouldClear(record, now: deadline.addingTimeInterval(-60.001)))
        XCTAssertTrue(FocusShieldPolicy.extensionShouldClear(nil, now: now), "No record: clear")
        record.active = false
        XCTAssertTrue(FocusShieldPolicy.extensionShouldClear(record, now: now), "Inactive: clear")

        // A resume moved the deadline and registered the new interval: the
        // superseded interval's callback never lifts the resumed focus.
        var resumed = FocusShieldRecord(active: true, sessionID: UUID(), deadline: deadline.addingTimeInterval(600),
                                        appliedAt: now, failsafeDeadline: deadline.addingTimeInterval(600))
        XCTAssertFalse(FocusShieldPolicy.extensionShouldClear(resumed, now: deadline.addingTimeInterval(-60)))
        // Died between writing the new deadline and registering it: the old
        // interval is still the one registered, and it must still clear.
        resumed.failsafeDeadline = deadline
        XCTAssertTrue(FocusShieldPolicy.extensionShouldClear(resumed, now: deadline.addingTimeInterval(-60)))
    }

    func testAFractionalDeadlineClearsOnTheCallbacksItsOwnIntervalProduces() throws {
        let deadline = now.addingTimeInterval(1_560.7)
        let bounds = FocusShieldSchedule.intervalBounds(deadline: deadline)
        XCTAssertEqual(bounds.start, now.addingTimeInterval(1_501))

        let starting = makeEngine()
        _ = try starting.engine.apply(sessionID: UUID(), deadline: deadline, applications: try tokens(1), now: now)
        XCTAssertFalse(starting.engine.handleExtensionInterval(phase: .start, now: bounds.start.addingTimeInterval(-1)))
        XCTAssertTrue(starting.engine.handleExtensionInterval(phase: .start, now: bounds.start),
                      "A start rounded down would arrive before the planned end and keep the shield")

        let ending = makeEngine()
        _ = try ending.engine.apply(sessionID: UUID(), deadline: deadline, applications: try tokens(1), now: now)
        XCTAssertTrue(ending.engine.handleExtensionInterval(phase: .end, now: bounds.end))
    }

    func testTheExtensionClearsForAnInactiveMissingOrUnreadableRecord() throws {
        let inactive = makeEngine()
        _ = try inactive.engine.apply(sessionID: UUID(), deadline: now.addingTimeInterval(1_560),
                                      applications: try tokens(1), now: now)
        _ = try inactive.engine.clear(reason: .focusEnded, now: now)
        XCTAssertTrue(inactive.engine.handleExtensionInterval(phase: .end, now: now.addingTimeInterval(1)))

        let missing = makeEngine()
        XCTAssertTrue(missing.engine.handleExtensionInterval(phase: .start, now: now))
        XCTAssertEqual(missing.settings.clearCount, 1)
        XCTAssertFalse(missing.engine.records.exists, "Clearing must not create a record")

        let unreadable = makeEngine()
        try FileManager.default.createDirectory(at: unreadable.directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: unreadable.directory.appendingPathComponent("focus-shield.json"))
        XCTAssertTrue(unreadable.engine.handleExtensionInterval(phase: .end, now: now))
        XCTAssertEqual(unreadable.settings.clearCount, 1)
    }

    func testTheExtensionDecidesFromAnUnlockedReadWhenTheAppHoldsTheLock() throws {
        let fixture = makeEngine()
        let deadline = now.addingTimeInterval(1_560.4)
        _ = try fixture.engine.apply(sessionID: UUID(), deadline: deadline, applications: try tokens(1), now: now)
        let descriptor = try holdLock(in: fixture.directory)
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        // Another process (the app registering this very interval) holds it.
        let blocked = expectation(description: "extension returns")
        let results = ShieldResultBox()
        let engine = fixture.engine
        let early = now.addingTimeInterval(1)
        let start = FocusShieldSchedule.intervalBounds(deadline: deadline).start
        DispatchQueue.global().async {
            results.early = engine.handleExtensionInterval(phase: .start, now: early)
            results.late = engine.handleExtensionInterval(phase: .start, now: start)
            blocked.fulfill()
        }
        wait(for: [blocked], timeout: 2 * FocusShieldPolicy.extensionLockTimeout + 5)
        XCTAssertEqual(results.early, false, "A running focus keeps its shield even without the lock")
        XCTAssertEqual(results.late, true, "and the planned end clears it without the lock too")
        XCTAssertEqual(fixture.settings.clearCount, 1)
    }

    func testTheLaunchSweepClearsOnlyAnExpiredRecordAndIgnoresAMissingOne() throws {
        let none = makeEngine()
        XCTAssertEqual(none.engine.sweepExpired(now: now), .unchanged)
        XCTAssertEqual(none.settings.clearCount, 0, "No record: ManagedSettings is never touched at launch")

        let fixture = makeEngine()
        let deadline = now.addingTimeInterval(1_560)
        _ = try fixture.engine.apply(sessionID: UUID(), deadline: deadline, applications: try tokens(1), now: now)
        XCTAssertEqual(fixture.engine.sweepExpired(now: deadline.addingTimeInterval(-1)), .unchanged)
        XCTAssertEqual(fixture.settings.clearCount, 0)
        XCTAssertEqual(fixture.engine.sweepExpired(now: deadline), .cleared)
        XCTAssertEqual(fixture.settings.clearCount, 1)
        XCTAssertEqual(try fixture.engine.records.load()?.clearedBy, FocusShieldClearReason.launchSweep.rawValue)
        XCTAssertEqual(fixture.center.stopped, [[FocusShieldPolicy.activityName.rawValue]])
    }

    func testCompleteDeletionClearsTheStoreStopsTheFailsafeAndRemovesTheRecord() throws {
        let fixture = makeEngine()
        _ = try fixture.engine.apply(sessionID: UUID(), deadline: now.addingTimeInterval(1_560),
                                     applications: try tokens(1), now: now)
        try fixture.engine.eraseAll()
        XCTAssertEqual(fixture.settings.clearCount, 1)
        XCTAssertFalse(fixture.engine.records.exists)
        XCTAssertFalse(fixture.center.installed.contains(FocusShieldPolicy.activityName.rawValue))

        // Without an App Group there is no record, and erasing still clears.
        let settings = ShieldFakeSettings()
        let orphan = FocusShieldEngine(records: FocusShieldRecordStore(directory: nil), settings: settings,
                                       center: ShieldFakeCenter())
        XCTAssertNoThrow(try orphan.eraseAll())
        XCTAssertEqual(settings.clearCount, 1)
    }

    // MARK: - budget and isolation from the gem lanes

    func testTheFailsafeFitsTheActivityBudgetAndLivesOutsideTheLanePrefix() {
        XCTAssertEqual(ScreenTimePolicy.maximumActivitiesIncludingFocusShield, 18)
        XCTAssertLessThanOrEqual(ScreenTimePolicy.maximumActivitiesIncludingFocusShield, 20)
        XCTAssertFalse(FocusShieldPolicy.activityName.rawValue.hasPrefix(ScreenTimePolicy.activityPrefix))
        XCTAssertEqual(ScreenTimeActivityKind(activityName: FocusShieldPolicy.activityName.rawValue), .other)
        XCTAssertTrue(FocusShieldPolicy.isFailsafeActivity("pomogem.focus-shield"))
        XCTAssertFalse(FocusShieldPolicy.isFailsafeActivity("pomogem.screen-time.focus-shield"))
    }

    func testTheLaneReconcileAndStopNeverTearDownTheFailsafe() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        let store = ScreenTimeStore(directory: directory)
        try store.update { state in
            state.contextKey = "owner"
            state.contextIsActive = true
            state.configuration.enabled = true
            state.configuration.distractionSelection.applicationTokens = try self.tokens(2)
        }
        let center = ShieldFakeCenter()
        center.installed = [FocusShieldPolicy.activityName.rawValue, "pomogem.screen-time.stale.0"]
        let monitoring = ScreenTimeMonitoring(store: store, center: center, authorization: { true })
        XCTAssertTrue(try monitoring.synchronize(now: now))
        XCTAssertTrue(center.installed.contains(FocusShieldPolicy.activityName.rawValue))
        XCTAssertFalse(center.installed.contains("pomogem.screen-time.stale.0"))
        XCTAssertLessThanOrEqual(center.installed.count, ScreenTimePolicy.maximumActivitiesIncludingFocusShield)

        monitoring.stop()
        XCTAssertEqual(center.installed, [FocusShieldPolicy.activityName.rawValue])
        XCTAssertFalse(center.stopped.contains { $0.isEmpty })
    }

    // MARK: - helpers

    private var tokyo: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func componentKeys(_ components: DateComponents) -> [String] {
        var keys: [String] = []
        if components.year != nil { keys.append("year") }
        if components.month != nil { keys.append("month") }
        if components.day != nil { keys.append("day") }
        if components.hour != nil { keys.append("hour") }
        if components.minute != nil { keys.append("minute") }
        if components.second != nil { keys.append("second") }
        return keys
    }

    /// What each form means to a framework that reads it correctly: dated
    /// components are that instant in their own time zone; a time of day is
    /// its next occurrence after now, and the end its next one after the start.
    static func resolve(_ schedule: DeviceActivitySchedule, now: Date, calendar: Calendar) -> DateInterval? {
        func instant(_ components: DateComponents, after anchor: Date) -> Date? {
            if components.year != nil {
                var zoned = Calendar(identifier: .gregorian)
                zoned.timeZone = components.timeZone ?? calendar.timeZone
                return zoned.date(from: components)
            }
            return calendar.nextDate(after: anchor, matching: components, matchingPolicy: .strict,
                                     repeatedTimePolicy: .first)
        }
        guard let start = instant(schedule.intervalStart, after: now),
              let end = instant(schedule.intervalEnd, after: start), end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    private func holdLock(in directory: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent("focus-shield.lock").path, O_CREAT | O_RDWR,
                              S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        return descriptor
    }

    private func exactResolver(deadline: Date) -> (DeviceActivitySchedule) -> DateInterval? {
        { schedule in
            FocusShieldSchedule.plans(deadline: deadline, now: self.now, calendar: self.tokyo)
                .first { $0.schedule == schedule }
                .map { DateInterval(start: $0.start, end: $0.end) }
        }
    }

    private func tokens(_ count: Int, seed: UInt8 = 0x51) throws -> Set<ApplicationToken> {
        Set(try (0..<count).map { index in
            try JSONDecoder().decode(ApplicationToken.self,
                                     from: JSONEncoder().encode(["data": Data([seed, UInt8(index)])]))
        })
    }

    private struct Fixture {
        let directory: URL
        let engine: FocusShieldEngine
        let settings: ShieldFakeSettings
        let center: ShieldFakeCenter
    }

    /// The default resolver answers exactly what each plan meant, the way
    /// `nextInterval` does for an interval it understands.
    private func makeEngine(resolve: ((DeviceActivitySchedule) -> DateInterval?)? = nil) -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        let center = ShieldFakeCenter()
        let settings = ShieldFakeSettings(center: center, records: FocusShieldRecordStore(directory: directory))
        let calendar = tokyo
        let testNow = now
        let resolver = resolve ?? { schedule in Self.resolve(schedule, now: testNow, calendar: calendar) }
        let engine = FocusShieldEngine(
            records: FocusShieldRecordStore(directory: directory), settings: settings, center: center,
            calendar: { calendar }, resolveInterval: resolver, lockTimeout: 1)
        return Fixture(directory: directory, engine: engine, settings: settings, center: center)
    }
}

// MARK: - fakes

final class ShieldFakeSettings: FocusShieldSettingsDriving {
    private weak var center: ShieldFakeCenter?
    private let records: FocusShieldRecordStore?
    private(set) var shielded: [Set<ApplicationToken>] = []
    private(set) var clearCount = 0
    /// Ordering evidence for every write to the store: whether the failsafe
    /// was registered and what the record on disk said at that moment
    /// ("shield failsafe=armed record=active").
    private(set) var events: [String] = []

    init(center: ShieldFakeCenter? = nil, records: FocusShieldRecordStore? = nil) {
        self.center = center
        self.records = records
    }

    func shield(applications: Set<ApplicationToken>) {
        shielded.append(applications)
        events.append("shield \(evidence)")
    }

    func clear() {
        clearCount += 1
        events.append("clear \(evidence)")
    }

    private var evidence: String {
        let failsafe = center.map {
            $0.installed.contains(FocusShieldPolicy.activityName.rawValue) ? "armed" : "none"
        } ?? "?"
        // An unlocked read: the engine calls in while it holds the lock, and
        // every write replaces the file atomically.
        let record: String
        if let records {
            switch try? records.load() {
            case .some(let current): record = current.active ? "active" : "inactive"
            case .none: record = "none"
            }
        } else {
            record = "?"
        }
        return "failsafe=\(failsafe) record=\(record)"
    }
}

final class ShieldFakeCenter: ScreenTimeActivityCenterDriving {
    var installed: Set<String> = []
    var started: [(name: String, schedule: DeviceActivitySchedule)] = []
    var stopped: [[String]] = []
    var failuresBeforeSuccess = 0

    var activities: [DeviceActivityName] { installed.map(DeviceActivityName.init(rawValue:)) }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        stopped.append(activities.map(\.rawValue))
        if activities.isEmpty { installed.removeAll() } else { installed.subtract(activities.map(\.rawValue)) }
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw DeviceActivityCenter.MonitoringError.intervalTooShort
        }
        started.append((activity.rawValue, schedule))
        installed.insert(activity.rawValue)
    }
}

final class ShieldResultBox: @unchecked Sendable {
    var early: Bool?
    var late: Bool?
}
