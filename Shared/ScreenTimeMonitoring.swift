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
    static let prefix = "pomogem.screen-time."
    private let store: ScreenTimeStore
    private let center: ScreenTimeActivityCenterDriving
    private let authorizationStatus: () -> AuthorizationStatus
    /// nil waits for the monitoring lock forever, which only the app may do.
    private let lockTimeout: TimeInterval?

    init(
        store: ScreenTimeStore,
        center: ScreenTimeActivityCenterDriving = DeviceActivityCenter(),
        lockTimeout: TimeInterval? = nil,
        authorizationStatus: @escaping () -> AuthorizationStatus = { AuthorizationCenter.shared.authorizationStatus }
    ) {
        self.store = store
        self.center = center
        self.lockTimeout = lockTimeout
        self.authorizationStatus = authorizationStatus
    }

    /// For callers that only distinguish "approved" from "revoked".
    convenience init(
        store: ScreenTimeStore,
        center: ScreenTimeActivityCenterDriving = DeviceActivityCenter(),
        lockTimeout: TimeInterval? = nil,
        authorization: @escaping () -> Bool
    ) {
        self.init(store: store, center: center, lockTimeout: lockTimeout,
                  authorizationStatus: { authorization() ? .approved : .denied })
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
        let initialGeneration = ScreenTimeMonitoringGeneration(state)
        let status = authorizationStatus()
        if !Self.isAuthorized(status) {
            // Skip the pass while the status is still unknown; never register
            // and never invalidate on anything but a denial.
            ScreenTimeLog.monitoring.notice(
                "synchronize skipped authorization=\(status == .denied ? "denied" : "unknown", privacy: .public)")
            guard status == .denied else { return false }
            stop()
            try store.update {
                try initialGeneration.requireCurrent($0)
                $0.invalidateAuthorization()
            }
            return false
        }
        guard state.configuration.enabled, state.contextKey != nil, state.contextIsActive else {
            ScreenTimeLog.monitoring.notice("synchronize stopping reason=inactive")
            stop()
            try store.update { state in
                try initialGeneration.requireCurrent(state)
                for index in state.runs.indices { state.runs[index].active = false }
                state.pruneConsumedRuns()
            }
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
                    try generation.requireCurrent(store.snapshot())
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

    /// Every exit logs a reason, so the Console evidence on a device tells an
    /// awarded gem from a silently discarded callback. Reasons only: never a
    /// run identifier, event name, threshold or gem count.
    func handleThreshold(eventName: String, activityName: String, now: Date = Date()) throws {
        let status = authorizationStatus()
        guard Self.isAuthorized(status) else {
            ScreenTimeLog.monitoring.notice(
                "threshold skipped authorization=\(status == .denied ? "denied" : "unknown", privacy: .public)")
            // An unknown status means "ask again later": no award, no wipe.
            if status == .denied { try invalidateAuthorizationIfNeeded() }
            return
        }
        guard activityName.hasPrefix(Self.prefix), let threshold = Int(eventName) else {
            ScreenTimeLog.monitoring.notice("threshold ignored reason=name")
            return
        }
        let parts = activityName.dropFirst(Self.prefix.count).split(separator: ".")
        guard parts.count == 2, let runID = UUID(uuidString: String(parts[0])),
              let batch = Int(parts[1]), (0..<ScreenTimePolicy.batchesPerLane).contains(batch),
              ScreenTimePolicy.thresholds(batch: batch).contains(threshold) else {
            ScreenTimeLog.monitoring.notice("threshold ignored reason=name")
            return
        }
        let recorded = try store.record(runID: runID, threshold: threshold, now: now)
        ScreenTimeLog.monitoring.notice(
            "threshold \(recorded ? "recorded" : "ignored reason=ledger", privacy: .public)")
        repairMissingRunIfNeeded(now: now)
    }

    func handleInterval(activityName: String, now: Date = Date()) throws {
        let state = try store.snapshot()
        guard state.configuration.enabled, state.contextKey != nil, state.contextIsActive,
              state.monitoringError == nil else { return }
        guard activityName == Self.schedulerName(epoch: state.epoch) else {
            // A lane's own interval boundary is another chance to repair a day
            // whose scheduler pass was skipped.
            repairMissingRunIfNeeded(now: now)
            return
        }
        _ = try synchronize(now: now)
    }

    /// A bounded monitoring-lock wait turns a contended pass into a skipped one,
    /// and the daily scheduler only calls back at 00:00:00 and 23:59:59 — so a
    /// midnight pass lost to the app's own registration would otherwise leave
    /// the whole day uncollected. Any later callback that finds no active run
    /// for today repairs it with one bounded pass. A day in which no callback
    /// arrives at all has no trigger and still waits for the next scheduler
    /// interval or for the user to open the app.
    private func repairMissingRunIfNeeded(now: Date) {
        guard let state = try? store.snapshot(), state.configuration.enabled,
              state.contextKey != nil, state.contextIsActive,
              state.monitoringError == nil else { return }
        let dayStart = Calendar.current.startOfDay(for: now)
        guard !state.runs.contains(where: { $0.active && $0.dayStart == dayStart }) else { return }
        ScreenTimeLog.monitoring.notice("repair pass reason=no-active-run")
        _ = try? synchronize(now: now)
    }

    static func schedulerName(epoch: UUID) -> String { prefix + "scheduler." + epoch.uuidString }

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
