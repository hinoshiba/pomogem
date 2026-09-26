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

    func testAShortFocusGetsAnIntervalThatStartedInThePastAndEndsAtTheDeadline() throws {
        let calendar = tokyo
        let deadline = now.addingTimeInterval(5 * 60 + 0.7)
        let bounds = FocusShieldSchedule.intervalBounds(deadline: deadline, now: now)
        XCTAssertEqual(bounds.end, FocusShieldSchedule.truncated(deadline))
        XCTAssertEqual(bounds.end.timeIntervalSince(bounds.start), FocusShieldPolicy.minimumInterval,
                       "A focus shorter than 15 minutes must still satisfy DeviceActivity's minimum")
        XCTAssertLessThan(bounds.start, now)

        let plans = FocusShieldSchedule.plans(deadline: deadline, now: now, calendar: calendar)
        XCTAssertEqual(plans.map(\.form), [.timeOfDay, .localDate, .utcDate])
        let timeOfDay = try XCTUnwrap(plans.first)
        XCTAssertFalse(timeOfDay.schedule.repeats)
        XCTAssertEqual(Set(componentKeys(timeOfDay.schedule.intervalStart)), ["hour", "minute", "second"])
        XCTAssertEqual(Set(componentKeys(timeOfDay.schedule.intervalEnd)), ["hour", "minute", "second"],
                       "Both ends carry hour/minute/second only")
        let end = calendar.dateComponents([.hour, .minute, .second], from: bounds.end)
        XCTAssertEqual(timeOfDay.schedule.intervalEnd.hour, end.hour)
        XCTAssertEqual(timeOfDay.schedule.intervalEnd.minute, end.minute)
        XCTAssertEqual(timeOfDay.schedule.intervalEnd.second, end.second)
    }

    func testALongFocusStartsItsIntervalNow() {
        let deadline = now.addingTimeInterval(50 * 60)
        let bounds = FocusShieldSchedule.intervalBounds(deadline: deadline, now: now)
        XCTAssertEqual(bounds.start, now)
        XCTAssertEqual(bounds.end, deadline)
        let longest = now.addingTimeInterval(TimeInterval(Constants.Timer.customMaximumMinutes * 60)
                                             + FocusShieldPolicy.deadlineGrace)
        XCTAssertEqual(FocusShieldSchedule.plans(deadline: longest, now: now, calendar: tokyo).count, 3,
                       "The longest focus stays far below DeviceActivity's one-week maximum")
    }

    func testAFocusAcrossMidnightNamesTheNextDaysEndTime() throws {
        var calendar = tokyo
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let midnight = calendar.startOfDay(for: now.addingTimeInterval(86_400))
        let start = midnight.addingTimeInterval(-10 * 60)
        let deadline = midnight.addingTimeInterval(16 * 60)
        let plans = FocusShieldSchedule.plans(deadline: deadline, now: start, calendar: calendar)
        let timeOfDay = try XCTUnwrap(plans.first { $0.form == .timeOfDay })
        XCTAssertEqual(timeOfDay.schedule.intervalStart.hour, 23)
        XCTAssertEqual(timeOfDay.schedule.intervalEnd.hour, 0)
        XCTAssertEqual(timeOfDay.end, deadline)
        XCTAssertEqual(timeOfDay.start, start)
        let local = try XCTUnwrap(plans.first { $0.form == .localDate })
        XCTAssertEqual(local.schedule.intervalEnd.day, calendar.component(.day, from: deadline),
                       "The dated fallback names the next day explicitly")
    }

    func testARepeatedDaylightSavingHourNeverNamesTheWrongOccurrence() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        // 2026-10-25: 03:00 CEST becomes 02:00 CET, so 02:00–02:59 happens twice.
        let first = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T00:35:00Z")) // 02:35 CEST
        let second = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T01:35:00Z")) // 02:35 CET
        var withoutLocalDate = 0
        for deadline in [first, second] {
            let plans = FocusShieldSchedule.plans(deadline: deadline, now: deadline.addingTimeInterval(-20 * 60),
                                                  calendar: calendar)
            let utc = try XCTUnwrap(plans.last)
            XCTAssertEqual(utc.form, .utcDate, "The unambiguous form is always available")
            XCTAssertEqual(utc.schedule.intervalEnd.timeZone, TimeZone(identifier: "UTC"))
            for plan in plans where plan.form != .timeOfDay {
                var zoned = Calendar(identifier: .gregorian)
                zoned.timeZone = try XCTUnwrap(plan.schedule.intervalEnd.timeZone)
                XCTAssertEqual(zoned.date(from: plan.schedule.intervalEnd), deadline,
                               "\(plan.form) must name this occurrence of 02:35, not the other")
            }
            for plan in plans where plan.form == .timeOfDay {
                XCTAssertEqual(calendar.nextDate(after: plan.start, matching: plan.schedule.intervalEnd,
                                                 matchingPolicy: .strict, repeatedTimePolicy: .first), deadline)
            }
            if !plans.contains(where: { $0.form == .localDate }) { withoutLocalDate += 1 }
        }
        XCTAssertEqual(withoutLocalDate, 1,
                       "One local 02:35 cannot name both occurrences; the other falls back")
    }

    func testASkippedDaylightSavingHourNeverReachesTheFramework() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-08: 02:00 EST jumps to 03:00 EDT.
        let jump = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T07:00:00Z"))
        let deadline = jump.addingTimeInterval(5 * 60) // 03:05 EDT
        let focusNow = jump.addingTimeInterval(-2 * 60) // 01:58 EST
        let plans = FocusShieldSchedule.plans(deadline: deadline, now: focusNow, calendar: calendar)
        XCTAssertFalse(plans.isEmpty)
        for plan in plans {
            XCTAssertEqual(plan.end, deadline, "\(plan.form) must denote the real deadline")
            XCTAssertEqual(plan.end.timeIntervalSince(plan.start), FocusShieldPolicy.minimumInterval, accuracy: 0.5)
        }
    }

    func testTheFrameworksIntervalMustContainNowAndEndAtTheDeadline() throws {
        let deadline = now.addingTimeInterval(20 * 60)
        let plan = try XCTUnwrap(FocusShieldSchedule.plans(deadline: deadline, now: now, calendar: tokyo).first)
        XCTAssertTrue(FocusShieldSchedule.accepts(DateInterval(start: plan.start, end: plan.end), plan: plan, now: now))
        XCTAssertFalse(FocusShieldSchedule.accepts(nil, plan: plan, now: now))
        XCTAssertFalse(FocusShieldSchedule.accepts(
            DateInterval(start: plan.start.addingTimeInterval(86_400), end: plan.end.addingTimeInterval(86_400)),
            plan: plan, now: now), "Tomorrow's interval leaves the shield up all night")
        XCTAssertFalse(FocusShieldSchedule.accepts(
            DateInterval(start: plan.start, end: plan.end.addingTimeInterval(3_600)), plan: plan, now: now),
            "An interval ending an hour late is a stuck shield")
        XCTAssertTrue(FocusShieldSchedule.accepts(
            DateInterval(start: plan.start, end: plan.end.addingTimeInterval(1)), plan: plan, now: now))
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
                // The framework misreads the time-only form.
                return plan.form == .timeOfDay ? nil : DateInterval(start: plan.start, end: plan.end)
            })
        XCTAssertEqual(form, .localDate)
        XCTAssertEqual(asked, [.timeOfDay, .localDate])
        XCTAssertEqual(center.started.map(\.name), [FocusShieldPolicy.activityName.rawValue])

        let refused = ShieldFakeCenter()
        XCTAssertThrowsError(try FocusShieldSchedule.register(
            center: refused, deadline: deadline, now: now, calendar: tokyo, resolveInterval: { _ in nil }))
        XCTAssertTrue(refused.started.isEmpty, "Nothing unconfirmed is ever registered")

        let throwing = ShieldFakeCenter()
        throwing.failuresBeforeSuccess = 1
        XCTAssertEqual(try FocusShieldSchedule.register(
            center: throwing, deadline: deadline, now: now, calendar: tokyo,
            resolveInterval: exactResolver(deadline: deadline)), .localDate,
            "A form the framework refuses falls through to the next one")
    }

    /// The real `DeviceActivitySchedule.nextInterval`, as the Simulator
    /// computes it. Evidence for the past-start form only; the device check
    /// is listed in Docs/ScreenTimeGems.md.
    func testTheFrameworksNextIntervalConfirmsAnOngoingPastStartedInterval() throws {
        let realNow = Date()
        let deadline = realNow.addingTimeInterval(5 * 60)
        let plans = FocusShieldSchedule.plans(deadline: deadline, now: realNow, calendar: .current)
        let confirmed = plans.filter { FocusShieldSchedule.accepts($0.schedule.nextInterval, plan: $0, now: realNow) }
        XCTAssertFalse(confirmed.isEmpty, "At least one form must resolve to the interval we meant: "
                       + plans.map { "\($0.form.rawValue)=\(String(describing: $0.schedule.nextInterval))" }
                        .joined(separator: " "))
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
        XCTAssertEqual(record, FocusShieldRecord(active: true, sessionID: session, deadline: deadline, appliedAt: now))
        XCTAssertEqual(fixture.center.started.map(\.name), [FocusShieldPolicy.activityName.rawValue])
        XCTAssertEqual(fixture.settings.shielded, [apps])
        XCTAssertEqual(fixture.settings.events, ["registered-before-shield"],
                       "The shield is written only after its kill-proof end exists")

        // The same focus again (a background save, a 3 s pass): no new registration.
        XCTAssertEqual(try fixture.engine.apply(sessionID: session, deadline: deadline, applications: apps,
                                                now: now.addingTimeInterval(30)), .applied(registered: false))
        XCTAssertEqual(fixture.center.started.count, 1)
        XCTAssertEqual(try fixture.engine.records.load()?.appliedAt, now)

        // Resumed after a pause: a new deadline re-registers the same name in place.
        let later = deadline.addingTimeInterval(300)
        XCTAssertEqual(try fixture.engine.apply(sessionID: session, deadline: later, applications: apps,
                                                now: now.addingTimeInterval(600)), .applied(registered: true))
        XCTAssertEqual(fixture.center.started.map(\.name), Array(repeating: FocusShieldPolicy.activityName.rawValue, count: 2))
        XCTAssertEqual(try fixture.engine.records.load()?.deadline, later)
    }

    func testClearLiftsTheShieldMarksTheRecordAndStopsOnlyTheFailsafeByName() throws {
        let fixture = makeEngine()
        fixture.center.installed = ["pomogem.screen-time.scheduler.\(UUID().uuidString)"]
        let session = UUID()
        _ = try fixture.engine.apply(sessionID: session, deadline: now.addingTimeInterval(1_560),
                                     applications: try tokens(2), now: now)
        XCTAssertEqual(try fixture.engine.clear(reason: .focusEnded, now: now.addingTimeInterval(60)), .cleared)
        XCTAssertEqual(fixture.settings.clearCount, 1)
        let record = try XCTUnwrap(try fixture.engine.records.load())
        XCTAssertFalse(record.active)
        XCTAssertEqual(record.clearedBy, FocusShieldClearReason.focusEnded.rawValue)
        XCTAssertEqual(fixture.center.stopped, [[FocusShieldPolicy.activityName.rawValue]],
                       "Never stopMonitoring([]): that stops the gem lanes too")
        XCTAssertEqual(fixture.center.installed.count, 1, "The lane scheduler stays installed")

        // Nothing active: a second clear touches nothing.
        XCTAssertEqual(try fixture.engine.clear(reason: .focusEnded, now: now.addingTimeInterval(61)), .unchanged)
        XCTAssertEqual(fixture.settings.clearCount, 1)
        XCTAssertEqual(fixture.center.stopped.count, 1)
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

    func testLiftingKeepsThatSessionUnshieldedButTheNextFocusIsShieldedAgain() throws {
        let fixture = makeEngine()
        let session = UUID()
        let deadline = now.addingTimeInterval(1_560)
        let apps = try tokens(2)
        _ = try fixture.engine.apply(sessionID: session, deadline: deadline, applications: apps, now: now)
        XCTAssertEqual(try fixture.engine.lift(sessionID: session, now: now.addingTimeInterval(10)), .cleared)
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

    // MARK: - removal paths 2 and 3

    func testTheExtensionClearsAtThePlannedEndAndNeverBefore() throws {
        let fixture = makeEngine()
        let plannedEnd = now.addingTimeInterval(1_500)
        let deadline = FocusShieldPolicy.deadline(forPlannedEnd: plannedEnd)
        _ = try fixture.engine.apply(sessionID: UUID(), deadline: deadline, applications: try tokens(2), now: now)

        // intervalDidStart fires as soon as a past-started interval is registered.
        XCTAssertFalse(fixture.engine.handleExtensionInterval(phase: .start, now: now.addingTimeInterval(1)))
        XCTAssertEqual(fixture.settings.clearCount, 0)
        XCTAssertFalse(fixture.engine.handleExtensionInterval(phase: .end, now: plannedEnd.addingTimeInterval(-1)))

        XCTAssertTrue(fixture.engine.handleExtensionInterval(phase: .end, now: deadline))
        XCTAssertEqual(fixture.settings.clearCount, 1)
        let record = try XCTUnwrap(try fixture.engine.records.load())
        XCTAssertFalse(record.active)
        XCTAssertEqual(record.clearedBy, FocusShieldClearReason.extensionEnd.rawValue)
        XCTAssertTrue(fixture.center.stopped.isEmpty, "The extension never stops monitoring")
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
        let deadline = now.addingTimeInterval(1_560)
        _ = try fixture.engine.apply(sessionID: UUID(), deadline: deadline, applications: try tokens(1), now: now)
        let path = fixture.directory.appendingPathComponent("focus-shield.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        defer { flock(descriptor, LOCK_UN) }

        // Another process (the app registering this very interval) holds it.
        let blocked = expectation(description: "extension returns")
        let results = ShieldResultBox()
        let engine = fixture.engine
        let early = now.addingTimeInterval(1)
        DispatchQueue.global().async {
            results.early = engine.handleExtensionInterval(phase: .start, now: early)
            results.late = engine.handleExtensionInterval(phase: .end, now: deadline)
            blocked.fulfill()
        }
        wait(for: [blocked], timeout: 2 * FocusShieldPolicy.extensionLockTimeout + 5)
        XCTAssertEqual(results.early, false, "A running focus keeps its shield even without the lock")
        XCTAssertEqual(results.late, true)
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
        let settings = ShieldFakeSettings(center: center)
        let calendar = tokyo
        let resolver = resolve ?? { schedule in
            // Resolve the way the plan was built: find any plan with this
            // schedule for any deadline the test used, by decoding components.
            let start = Self.date(schedule.intervalStart, calendar: calendar, near: nil)
            let end = Self.date(schedule.intervalEnd, calendar: calendar, near: start)
            guard let start, let end else { return nil }
            return DateInterval(start: start, end: end)
        }
        let engine = FocusShieldEngine(
            records: FocusShieldRecordStore(directory: directory), settings: settings, center: center,
            calendar: { calendar }, resolveInterval: resolver, lockTimeout: 1)
        return Fixture(directory: directory, engine: engine, settings: settings, center: center)
    }

    /// Full components resolve directly; a time-only start resolves to its
    /// first occurrence in the hour before the test's clock, and a time-only
    /// end to its first occurrence after the start.
    private static func date(_ components: DateComponents, calendar: Calendar, near: Date?) -> Date? {
        if components.year != nil {
            var calendar = calendar
            if let zone = components.timeZone { calendar.timeZone = zone }
            return calendar.date(from: components)
        }
        let anchor = near ?? Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(-3_600)
        guard let next = calendar.nextDate(after: anchor.addingTimeInterval(-1), matching: components,
                                           matchingPolicy: .strict) else { return nil }
        return next
    }
}

// MARK: - fakes

final class ShieldFakeSettings: FocusShieldSettingsDriving {
    private weak var center: ShieldFakeCenter?
    private(set) var shielded: [Set<ApplicationToken>] = []
    private(set) var clearCount = 0
    /// Ordering evidence: whether the failsafe existed when the shield was written.
    private(set) var events: [String] = []

    init(center: ShieldFakeCenter? = nil) { self.center = center }

    func shield(applications: Set<ApplicationToken>) {
        shielded.append(applications)
        if let center {
            events.append(center.installed.contains(FocusShieldPolicy.activityName.rawValue)
                          ? "registered-before-shield" : "shield-without-failsafe")
        }
    }

    func clear() { clearCount += 1 }
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
