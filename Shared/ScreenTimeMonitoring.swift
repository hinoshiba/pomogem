import DeviceActivity
import FamilyControls
import Foundation
import os

/// Console evidence for registration on a real device (filter by this
/// subsystem). Counts, durations and framework error cases only: never run or
/// event identifiers, opaque tokens, thresholds or gem counts.
enum ScreenTimeLog {
    static let subsystem = "com.hinoshiba.pomogem"
    static let category = "screen-time"
    static let monitoring = Logger(subsystem: subsystem, category: category)
}

protocol ScreenTimeActivityCenterDriving {
    var activities: [DeviceActivityName] { get }
    func stopMonitoring(_ activities: [DeviceActivityName])
    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws
}

extension DeviceActivityCenter: ScreenTimeActivityCenterDriving {}

/// Which process a `ScreenTimeMonitoring` runs in — and therefore what a
/// Family Controls status of "neither approved nor denied" is allowed to mean
/// there.
///
/// In the APP it is an answer. The app is the process the user authorized, it
/// reads `AuthorizationCenter` on the main run loop with FamilyControls fully
/// loaded, and `ScreenTimeController` already watches that status across a
/// settling window to tell a real revocation from a transient value.
///
/// In the monitor extension it is not an answer at all. The OS spawns that
/// process on demand to deliver one callback and tears it down again; on the
/// 2026-09-21 device run it read `.notDetermined` for EVERY threshold — 2 of 2,
/// both lanes — while the app read 許可済み at the same minute, so every gem the
/// OS had measured was discarded by a process that simply could not see the
/// approval. Inside the extension the status therefore gates nothing but an
/// explicit `.denied`: the OS only delivers callbacks for a registration an
/// authorized app made, and `ScreenTimeState.record` still owns every award.
enum ScreenTimeMonitoringHost {
    case app
    case monitorExtension
}

/// Identifies registration inputs without including concurrently arriving
/// receipts. The main app can retire a run or reset its owner while an OS call
/// holds the separate monitoring lock, so every later write must revalidate.
private struct ScreenTimeMonitoringGeneration: Equatable {
    let epoch: UUID
    let contextKey: String?
    let dataEpochID: UUID?
    let contextIsActive: Bool
    let configuration: ScreenTimeConfiguration
    let learningPausedByTimer: Bool
    let learningAllowedBySubscription: Bool
    let activeRunIDs: Set<UUID>

    init(_ state: ScreenTimeState) {
        epoch = state.epoch
        contextKey = state.contextKey
        dataEpochID = state.dataEpochID
        contextIsActive = state.contextIsActive
        configuration = state.configuration
        learningPausedByTimer = state.learningPausedByTimer
        learningAllowedBySubscription = state.learningAllowedBySubscription
        activeRunIDs = Set(state.runs.filter(\.active).map(\.id))
    }

    func requireCurrent(_ state: ScreenTimeState) throws {
        guard self == Self(state) else { throw ScreenTimeMonitoringSuperseded() }
    }
}

private struct ScreenTimeMonitoringSuperseded: Error {}

/// Public Screen Time APIs only. One dated registration per lane/batch prevents
/// delayed events from being mistaken for another day's usage. A recurring
/// scheduler installs the next dated day even while the app isn't running.
final class ScreenTimeMonitoring {
    static let prefix = ScreenTimePolicy.activityPrefix
    private let store: ScreenTimeStore
    private let center: ScreenTimeActivityCenterDriving
    private let authorizationStatus: () -> AuthorizationStatus
    /// nil waits for the monitoring lock forever, which only the app may do.
    private let lockTimeout: TimeInterval?
    /// Readable so a test can pin it. `synchronizeLocked` is the only reader,
    /// and the value it reads decides whether a whole day gets registered, so
    /// "which host was this built for" has to be observable without inferring
    /// it from that one branch.
    let host: ScreenTimeMonitoringHost

    init(
        store: ScreenTimeStore,
        center: ScreenTimeActivityCenterDriving = DeviceActivityCenter(),
        lockTimeout: TimeInterval? = nil,
        host: ScreenTimeMonitoringHost = .app,
        authorizationStatus: @escaping () -> AuthorizationStatus = { AuthorizationCenter.shared.authorizationStatus }
    ) {
        self.store = store
        self.center = center
        self.lockTimeout = lockTimeout
        self.host = host
        self.authorizationStatus = authorizationStatus
    }

    /// For callers that only distinguish "approved" from "revoked".
    convenience init(
        store: ScreenTimeStore,
        center: ScreenTimeActivityCenterDriving = DeviceActivityCenter(),
        lockTimeout: TimeInterval? = nil,
        host: ScreenTimeMonitoringHost = .app,
        authorization: @escaping () -> Bool
    ) {
        self.init(store: store, center: center, lockTimeout: lockTimeout, host: host,
                  authorizationStatus: { authorization() ? .approved : .denied })
    }

    /// The monitor extension's one construction, written HERE rather than at
    /// its call site in `PomoGemScreenTimeMonitor` so that it can be tested.
    /// That target is not linked into `PomoGemTests` — `project.yml` gives the
    /// unit tests only their own sources and the app host — so a `host:`
    /// argument written over there is invisible to every test in the
    /// repository, and deleting it silently returns the extension to app
    /// semantics: `synchronizeLocked` would again skip the daily
    /// re-registration whenever it reads a status it cannot read, which on the
    /// 2026-09-21 device run was every callback.
    static func forMonitorExtension(
        store: ScreenTimeStore,
        center: ScreenTimeActivityCenterDriving = DeviceActivityCenter(),
        lockTimeout: TimeInterval,
        authorizationStatus: @escaping () -> AuthorizationStatus = { AuthorizationCenter.shared.authorizationStatus }
    ) -> ScreenTimeMonitoring {
        ScreenTimeMonitoring(store: store, center: center, lockTimeout: lockTimeout,
                             host: .monitorExtension, authorizationStatus: authorizationStatus)
    }

    static func isAuthorized(_ status: AuthorizationStatus) -> Bool {
        if status == .approved { return true }
        if #available(iOS 26.4, *), status == .approvedWithDataAccess { return true }
        return false
    }

    /// Never call stopMonitoring with an empty array: the framework treats that
    /// as "stop every activity", including other clients' and our own healthy
    /// registration.
    /// https://developer.apple.com/documentation/deviceactivity/deviceactivitycenter/stopmonitoring(_:)
    func stop() {
        let ours = center.activities.filter { $0.rawValue.hasPrefix(Self.prefix) }
        guard !ours.isEmpty else { return }
        ScreenTimeLog.monitoring.notice("stop activities=\(ours.count, privacy: .public)")
        center.stopMonitoring(ours)
    }

    /// Only an explicit denial invalidates. A monitor extension process that has
    /// just been launched to deliver a callback can still read .notDetermined,
    /// and wiping the opaque selections then would cost the user a new picker
    /// session for usage they already opted into.
    func invalidateAuthorizationIfNeeded() throws {
        do {
            try store.withMonitoringLock(timeout: lockTimeout) {
                guard authorizationStatus() == .denied else { return }
                let generation = ScreenTimeMonitoringGeneration(try store.snapshot())
                stop()
                try store.update {
                    try generation.requireCurrent($0)
                    $0.invalidateAuthorization()
                }
            }
        } catch is ScreenTimeMonitoringSuperseded {
            // A newer opt-in/reset owns the ledger now.
        }
    }

    @discardableResult
    func synchronize(now: Date = Date()) throws -> Bool {
        do {
            return try store.withMonitoringLock(timeout: lockTimeout) {
                try synchronizeLocked(now: now)
            }
        } catch is ScreenTimeMonitoringSuperseded {
            return false
        } catch ScreenTimeError.unavailable {
            // Usually the other process holding the monitoring lock. The next
            // callback or the daily scheduler retries.
            ScreenTimeLog.monitoring.notice("synchronize skipped reason=unavailable")
            throw ScreenTimeError.unavailable
        }
    }

    private func synchronizeLocked(now: Date) throws -> Bool {
        let began = Date()
        var state = try store.snapshot()
        // Re-emitted on every pass — save, foreground and the daily scheduler —
        // so a single live Console session reads the whole callback history
        // after the fact. Collecting a past window of a device's unified log
        // needs host root, which a device audit may not have.
        ScreenTimeLog.monitoring.notice("""
            \((state.callbackCounters ?? ScreenTimeCallbackCounters()).logDescription(now: now), privacy: .public)
            """)
        let initialGeneration = ScreenTimeMonitoringGeneration(state)
        let status = authorizationStatus()
        let ledgerWantsMonitoring = state.configuration.enabled
            && state.contextKey != nil && state.contextIsActive
        if status == .denied {
            // The one authorization answer that decides anything. Apple voids
            // the opaque selections on a revocation, so the ledger has to be
            // told, and our activities have to come down.
            ScreenTimeLog.monitoring.notice("synchronize skipped authorization=denied")
            stop()
            try store.update {
                try initialGeneration.requireCurrent($0)
                $0.invalidateAuthorization()
            }
            return false
        }
        if !Self.isAuthorized(status), host == .app {
            // The app CAN read the status, so an unknown one here is a real
            // observation: registering would need an approval this process did
            // not see, and `ScreenTimeController`'s settling window is what
            // turns a persistent unknown into a revocation. Never invalidate
            // from here — a revoked authorization also reads .notDetermined,
            // and one transient read would cost the user a picker session.
            // The teardown half still runs: this is the ONLY stop path for a
            // save that turns recording off and for the timer pausing the
            // learning lane, and a ledger that says "off" must not leave our
            // activities installed — they keep the OS watching the user's apps
            // and hold the shared 20-activity budget.
            ScreenTimeLog.monitoring.notice("synchronize skipped authorization=unknown")
            if !ledgerWantsMonitoring { try stopAndDeactivate(initialGeneration) }
            return false
        }
        if !Self.isAuthorized(status) {
            // The extension cannot read the status (see
            // `ScreenTimeMonitoringHost`), so an unknown one says nothing and
            // must not skip the daily re-registration the scheduler callback
            // exists to perform: skipping it left a whole day with no
            // registration whenever the extension, and only the extension, was
            // awake for the rollover. Proceed and let the framework answer —
            // if DeviceActivityCenter refuses, .unauthorized like any other
            // error, the catch below stops monitoring, deactivates every run
            // and shows 監視エラー.
            ScreenTimeLog.monitoring.notice("synchronize authorization=unknown reason=proceed")
        }
        guard ledgerWantsMonitoring else {
            try stopAndDeactivate(initialGeneration)
            return false
        }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        var installed = Set(center.activities.map(\.rawValue))
        let supportsPastActivity: Bool
        if #available(iOS 17.4, *) { supportsPastActivity = true }
        else { supportsPastActivity = false }
        state = try store.update { state in
            try initialGeneration.requireCurrent(state)
            // Capture continuity before retiring yesterday's dated run. The
            // foreground app and the extension must reach the same decision.
            let previousRuns = state.runs
            for index in state.runs.indices {
                let run = state.runs[index]
                let allowed = run.lane == .distraction || (!state.learningPausedByTimer && state.learningAllowedBySubscription)
                let allInstalled = (0..<ScreenTimePolicy.batchesPerLane).allSatisfy {
                    installed.contains(run.activityPrefix + String($0))
                }
                if run.dayStart != dayStart || !allowed || !allInstalled { state.runs[index].active = false }
            }
            for lane in ScreenTimeLane.allCases {
                let selection = lane == .learning ? state.configuration.learningSelection : state.configuration.distractionSelection
                guard !selection.applicationTokens.isEmpty,
                      lane == .distraction || (!state.learningPausedByTimer && state.learningAllowedBySubscription),
                      !state.runs.contains(where: { $0.active && $0.lane == lane }) else { continue }
                // A continuing prior-day registration includes this day's
                // midnight usage even when the app beats a delayed scheduler.
                // Retired/edited runs and same-day registration repair do not.
                let includesPast = ScreenTimeRolloverPolicy.includesPastActivity(
                    lane: lane,
                    previousRuns: previousRuns,
                    dayStart: dayStart,
                    timeZoneID: calendar.timeZone.identifier,
                    learningPausedByTimer: state.learningPausedByTimer,
                    learningAllowedBySubscription: state.learningAllowedBySubscription,
                    supportsPastActivity: supportsPastActivity
                )
                state.runs.append(ScreenTimeRun(
                    lane: lane, dayStart: dayStart, dayEnd: dayEnd,
                    startedAt: includesPast ? dayStart : now,
                    timeZoneID: calendar.timeZone.identifier,
                    includesPastActivity: includesPast,
                    themeID: state.configuration.themeID
                ))
            }
            state.pruneConsumedRuns()
            state.monitoringError = nil
            return state
        }
        let generation = ScreenTimeMonitoringGeneration(state)
        let schedulerName = Self.schedulerName(epoch: state.epoch)
        let desiredNames = Set(state.runs.filter(\.active).flatMap { run in
            (0..<ScreenTimePolicy.batchesPerLane).map { run.activityPrefix + String($0) }
        } + [schedulerName])
        try generation.requireCurrent(store.snapshot())
        let stale = center.activities.filter {
            $0.rawValue.hasPrefix(Self.prefix) && !desiredNames.contains($0.rawValue)
        }
        let stoppedCount = stale.count
        var startedCount = 0
        if !stale.isEmpty {
            center.stopMonitoring(stale)
            // The teardown changes what the OS holds, so the re-registration
            // guards below must not trust the pre-teardown snapshot.
            installed = Set(center.activities.map(\.rawValue))
        }
        do {
            try generation.requireCurrent(store.snapshot())
            if !installed.contains(schedulerName) {
                try center.startMonitoring(DeviceActivityName(schedulerName), during: DeviceActivitySchedule(
                    intervalStart: DateComponents(hour: 0, minute: 0, second: 0),
                    intervalEnd: DateComponents(hour: 23, minute: 59, second: 59), repeats: true
                ), events: [:])
                startedCount += 1
                try generation.requireCurrent(store.snapshot())
            }
            for run in state.runs where run.active {
                let selection = run.lane == .learning ? state.configuration.learningSelection : state.configuration.distractionSelection
                var scheduleCalendar = Calendar(identifier: .gregorian)
                scheduleCalendar.timeZone = TimeZone(identifier: run.timeZoneID) ?? .current
                var start = scheduleCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: run.dayStart)
                var end = scheduleCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: run.dayEnd.addingTimeInterval(-1))
                start.timeZone = scheduleCalendar.timeZone
                end.timeZone = scheduleCalendar.timeZone
                let schedule = DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: false)
                var startedForRun = 0
                for batch in 0..<ScreenTimePolicy.batchesPerLane {
                    let name = run.activityPrefix + String(batch)
                    guard !installed.contains(name) else { continue }
                    var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
                    for threshold in ScreenTimePolicy.thresholds(batch: batch) {
                        let duration = DateComponents(minute: threshold * ScreenTimePolicy.minutesPerGem)
                        let event: DeviceActivityEvent
                        if #available(iOS 17.4, *) {
                            event = DeviceActivityEvent(applications: selection.applicationTokens, threshold: duration,
                                                        includesPastActivity: run.includesPastActivity)
                        } else {
                            event = DeviceActivityEvent(applications: selection.applicationTokens, threshold: duration)
                        }
                        events[DeviceActivityEvent.Name(String(threshold))] = event
                    }
                    // Recheck the generation after each framework call; callbacks
                    // from stopped/changed configurations cannot award receipts.
                    try generation.requireCurrent(store.snapshot())
                    try center.startMonitoring(DeviceActivityName(name), during: schedule, events: events)
                    startedCount += 1
                    startedForRun += 1
                    try generation.requireCurrent(store.snapshot())
                }
                if let notice = Self.laneScheduleNotice(
                    started: startedForRun, now: now,
                    intervalStart: scheduleCalendar.date(from: start) ?? run.dayStart,
                    intervalEnd: scheduleCalendar.date(from: end) ?? run.dayEnd,
                    includesPastActivity: run.includesPastActivity
                ) {
                    ScreenTimeLog.monitoring.notice("\(notice, privacy: .public)")
                }
            }
            try generation.requireCurrent(store.snapshot())
            Self.log("synchronize finished", stopped: stoppedCount, started: startedCount, since: began)
            return state.runs.contains(where: \.active)
        } catch is ScreenTimeMonitoringSuperseded {
            Self.log("synchronize superseded", stopped: stoppedCount, started: startedCount, since: began)
            return false
        } catch {
            // DeviceActivityCenter.MonitoringError describes only the framework
            // refusal (excessiveActivities, intervalTooLong, ...).
            ScreenTimeLog.monitoring.error("""
                synchronize failed stopped=\(stoppedCount, privacy: .public) \
                started=\(startedCount, privacy: .public) \
                ms=\(Self.elapsedMilliseconds(since: began), privacy: .public) \
                error=\(String(describing: error), privacy: .public)
                """)
            stop()
            try store.update { state in
                try generation.requireCurrent(state)
                for index in state.runs.indices { state.runs[index].active = false }
                state.monitoringError = "スクリーンタイムの監視を開始できませんでした。もう一度お試しください。"
                state.pruneConsumedRuns()
            }
            throw error
        }
    }

    /// Takes our registrations down and closes the receipt gate. Reached both
    /// from an approved pass whose ledger says the feature is off and from a
    /// pass with an unknown status, which may register nothing but must still
    /// honour a save that switched recording off.
    private func stopAndDeactivate(_ generation: ScreenTimeMonitoringGeneration) throws {
        ScreenTimeLog.monitoring.notice("synchronize stopping reason=inactive")
        stop()
        try store.update { state in
            try generation.requireCurrent(state)
            for index in state.runs.indices { state.runs[index].active = false }
            state.pruneConsumedRuns()
        }
    }

    /// Every exit logs a reason, so the Console evidence on a device tells an
    /// awarded gem from a silently discarded callback. Reasons only: never a
    /// run identifier, event name, threshold or gem count.
    ///
    /// Only an explicit `.denied` stops the award. This runs in the on-demand
    /// monitor extension, where the status a synchronous read returns is not
    /// evidence about the user's authorization at all (see
    /// `ScreenTimeMonitoringHost`): on 2026-09-21 the phone answered
    /// `.notDetermined` for every single threshold while the app read 許可済み,
    /// and gating the award on it discarded every gem the OS had measured,
    /// silently, with the settings screen still saying 自動記録中.
    ///
    /// Nothing is loosened by proceeding. The OS delivers a threshold only for
    /// an activity an authorized app registered, a revoked authorization voids
    /// the opaque selections so no registration of ours survives it, and every
    /// fence that decides an award still belongs to `ScreenTimeState.record`:
    /// an active run, a bound and active context, recording enabled, enough
    /// elapsed time in the run's own window, a strictly higher threshold, and
    /// the learning lane's timer/subscription conditions.
    func handleThreshold(eventName: String, activityName: String, now: Date = Date()) throws {
        let kind = ScreenTimeActivityKind(activityName: activityName)
        let status = authorizationStatus()
        // Observation, not a gate: it says which process could read the
        // authorization, beside whatever the ledger then decided.
        let statusUnknown = !Self.isAuthorized(status) && status != .denied
        guard status != .denied else {
            count(threshold: .denied, statusUnknown: false, now: now)
            ScreenTimeLog.monitoring.notice("""
                threshold skipped kind=\(kind.rawValue, privacy: .public) \
                authorization=denied
                """)
            try invalidateAuthorizationIfNeeded()
            return
        }
        guard activityName.hasPrefix(Self.prefix), let threshold = Int(eventName) else {
            count(threshold: .ignoredByName, statusUnknown: statusUnknown, now: now)
            ScreenTimeLog.monitoring.notice(
                "threshold ignored kind=\(kind.rawValue, privacy: .public) reason=name")
            return
        }
        let parts = activityName.dropFirst(Self.prefix.count).split(separator: ".")
        guard parts.count == 2, let runID = UUID(uuidString: String(parts[0])),
              let batch = Int(parts[1]), (0..<ScreenTimePolicy.batchesPerLane).contains(batch),
              ScreenTimePolicy.thresholds(batch: batch).contains(threshold) else {
            count(threshold: .ignoredByName, statusUnknown: statusUnknown, now: now)
            ScreenTimeLog.monitoring.notice(
                "threshold ignored kind=\(kind.rawValue, privacy: .public) reason=name")
            return
        }
        let recorded = try store.record(runID: runID, threshold: threshold, now: now)
        count(threshold: recorded ? .recorded : .ignoredByLedger,
              statusUnknown: statusUnknown, now: now)
        ScreenTimeLog.monitoring.notice("""
            threshold \(recorded ? "recorded" : "ignored reason=ledger", privacy: .public) \
            kind=\(kind.rawValue, privacy: .public) \
            authorization=\(statusUnknown ? "unknown" : "approved", privacy: .public)
            """)
        repairMissingRunIfNeeded(now: now)
    }

    func handleInterval(
        activityName: String,
        phase: ScreenTimeCallbackCounters.IntervalPhase = .start,
        now: Date = Date()
    ) throws {
        // Counted before any fence, and by kind: whether the OS ever starts a
        // lane's dated, non-repeating interval — as opposed to the recurring
        // scheduler's — is invisible from inside the app, because
        // `DeviceActivityCenter.activities` keeps listing the name either way.
        let kind = ScreenTimeActivityKind(activityName: activityName)
        count(interval: kind, phase: phase, now: now)
        let state = try store.snapshot()
        // Deliberately NOT gated on `state.monitoringError`: nothing inside the
        // extension ever clears that field, and the daily scheduler pass is
        // precisely the retry that would. Gating it here latched a single
        // failed registration into a whole day with no collection at all.
        guard state.configuration.enabled, state.contextKey != nil, state.contextIsActive else {
            ScreenTimeLog.monitoring.notice("""
                interval ignored kind=\(kind.rawValue, privacy: .public) \
                phase=\(phase.rawValue, privacy: .public) reason=ledger
                """)
            return
        }
        guard activityName == Self.schedulerName(epoch: state.epoch) else {
            // A lane's own interval boundary is another chance to repair a day
            // whose scheduler pass was skipped.
            ScreenTimeLog.monitoring.notice("""
                interval kind=\(kind.rawValue, privacy: .public) \
                phase=\(phase.rawValue, privacy: .public) reason=repair-check
                """)
            repairMissingRunIfNeeded(now: now)
            return
        }
        ScreenTimeLog.monitoring.notice("""
            interval kind=scheduler phase=\(phase.rawValue, privacy: .public) reason=synchronize
            """)
        _ = try synchronize(now: now)
    }

    private func count(interval kind: ScreenTimeActivityKind,
                       phase: ScreenTimeCallbackCounters.IntervalPhase, now: Date) {
        store.countCallback { $0.countIntervalCallback(kind: kind, phase: phase, now: now) }
    }

    private func count(threshold outcome: ScreenTimeCallbackCounters.ThresholdOutcome,
                       statusUnknown: Bool, now: Date) {
        store.countCallback {
            $0.countThresholdCallback(outcome, statusUnknown: statusUnknown, now: now)
        }
    }

    /// A bounded monitoring-lock wait turns a contended pass into a skipped one,
    /// and the daily scheduler only calls back at 00:00:00 and 23:59:59 — so a
    /// midnight pass lost to the app's own registration would otherwise leave
    /// the whole day uncollected. Any later callback that finds no active run
    /// for today repairs it with one bounded pass. A day in which no callback
    /// arrives at all has no trigger and still waits for the next scheduler
    /// interval or for the user to open the app.
    private func repairMissingRunIfNeeded(now: Date) {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        guard let state = try? store.snapshot(), state.configuration.enabled,
              state.contextKey != nil, state.contextIsActive,
              !state.runs.contains(where: { $0.active && $0.dayStart == dayStart }),
              // At most one REFUSED attempt per device day. This runs on every
              // threshold and on every lane interval boundary, so a framework
              // refusal (excessiveActivities and friends) would otherwise be
              // retried on ordinary traffic all day. A pass skipped for lock
              // contention is not an attempt and does not consume the day.
              state.lastRepairAttemptAt.map { calendar.startOfDay(for: $0) != dayStart } ?? true
        else { return }
        ScreenTimeLog.monitoring.notice("repair pass reason=no-active-run")
        do {
            _ = try synchronize(now: now)
        } catch ScreenTimeError.unavailable {
            // The other process holds the monitoring lock; the next callback
            // or the daily scheduler retries.
        } catch {
            try? store.update { $0.lastRepairAttemptAt = now }
        }
    }

    static func schedulerName(epoch: UUID) -> String {
        prefix + ScreenTimePolicy.schedulerInfix + epoch.uuidString
    }

    /// The one line that describes a lane registration the way the framework
    /// received it — and `nil` for a pass that handed the framework nothing.
    ///
    /// The distinction is the whole point. Almost every synchronize pass finds
    /// all eight batches already installed and calls `startMonitoring` zero
    /// times; a line printed on those passes would still carry an offset
    /// measured against THIS pass, so a registration made at midnight at
    /// offset 0 would print `startOffsetSec=43200` at noon and read as "we
    /// registered half a day into the interval" — the exact hypothesis this
    /// evidence exists to decide. A positive offset beside a non-zero
    /// `started` is the real thing. Offsets and counts only: never a name, a
    /// run, a threshold or a token.
    static func laneScheduleNotice(
        started: Int,
        now: Date,
        intervalStart: Date,
        intervalEnd: Date,
        includesPastActivity: Bool
    ) -> String? {
        guard started > 0 else { return nil }
        return """
            schedule kind=lane started=\(started) \
            startOffsetSec=\(ScreenTimeDiagnosticSeconds.between(now, intervalStart)) \
            endOffsetSec=\(ScreenTimeDiagnosticSeconds.between(now, intervalEnd)) \
            repeats=0 pastActivity=\(includesPastActivity ? 1 : 0)
            """
    }

    private static func log(_ message: String, stopped: Int, started: Int, since: Date) {
        ScreenTimeLog.monitoring.notice("""
            \(message, privacy: .public) stopped=\(stopped, privacy: .public) \
            started=\(started, privacy: .public) ms=\(elapsedMilliseconds(since: since), privacy: .public)
            """)
    }

    private static func elapsedMilliseconds(since: Date) -> Int {
        Int((Date().timeIntervalSince(since) * 1_000).rounded())
    }
}
