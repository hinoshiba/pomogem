import DeviceActivity
import FamilyControls
import Foundation

/// Public Screen Time APIs only. One dated registration per lane/batch prevents
/// delayed events from being mistaken for another day's usage. A recurring
/// scheduler installs the next dated day even while the app isn't running.
final class ScreenTimeMonitoring {
    static let prefix = "pomogem.screen-time."
    private let store: ScreenTimeStore
    private let center = DeviceActivityCenter()

    init(store: ScreenTimeStore) { self.store = store }

    static var isAuthorized: Bool {
        let status = AuthorizationCenter.shared.authorizationStatus
        if status == .approved { return true }
        if #available(iOS 26.4, *), status == .approvedWithDataAccess { return true }
        return false
    }

    func stop() {
        center.stopMonitoring(center.activities.filter { $0.rawValue.hasPrefix(Self.prefix) })
    }

    func invalidateAuthorizationIfNeeded() throws {
        try store.withMonitoringLock {
            guard !Self.isAuthorized else { return }
            stop()
            try store.update { $0.invalidateAuthorization() }
        }
    }

    @discardableResult
    func synchronize(now: Date = Date()) throws -> Bool {
        try store.withMonitoringLock {
            try synchronizeLocked(now: now)
        }
    }

    private func synchronizeLocked(now: Date) throws -> Bool {
        var state = try store.snapshot()
        if !Self.isAuthorized {
            stop()
            try store.update { $0.invalidateAuthorization() }
            return false
        }
        guard state.configuration.enabled, state.contextKey != nil, state.contextIsActive else {
            stop()
            try store.update { state in
                for index in state.runs.indices { state.runs[index].active = false }
                state.pruneConsumedRuns()
            }
            return false
        }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let installed = Set(center.activities.map(\.rawValue))
        let supportsPastActivity: Bool
        if #available(iOS 17.4, *) { supportsPastActivity = true }
        else { supportsPastActivity = false }
        state = try store.update { state in
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
        let schedulerName = Self.schedulerName(epoch: state.epoch)
        let desiredNames = Set(state.runs.filter(\.active).flatMap { run in
            (0..<ScreenTimePolicy.batchesPerLane).map { run.activityPrefix + String($0) }
        } + [schedulerName])
        center.stopMonitoring(center.activities.filter {
            $0.rawValue.hasPrefix(Self.prefix) && !desiredNames.contains($0.rawValue)
        })
        do {
            if !installed.contains(schedulerName) {
                try center.startMonitoring(DeviceActivityName(schedulerName), during: DeviceActivitySchedule(
                    intervalStart: DateComponents(hour: 0, minute: 0, second: 0),
                    intervalEnd: DateComponents(hour: 23, minute: 59, second: 59), repeats: true
                ))
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
                    guard try store.snapshot().runs.contains(where: { $0.id == run.id && $0.active }) else { return false }
                    try center.startMonitoring(DeviceActivityName(name), during: schedule, events: events)
                }
            }
            return state.runs.contains(where: \.active)
        } catch {
            stop()
            try store.update { state in
                for index in state.runs.indices { state.runs[index].active = false }
                state.monitoringError = "スクリーンタイムの監視を開始できませんでした。もう一度お試しください。"
                state.pruneConsumedRuns()
            }
            throw error
        }
    }

    func handleThreshold(eventName: String, activityName: String, now: Date = Date()) throws {
        guard Self.isAuthorized else {
            try invalidateAuthorizationIfNeeded()
            return
        }
        guard activityName.hasPrefix(Self.prefix), let threshold = Int(eventName) else { return }
        let parts = activityName.dropFirst(Self.prefix.count).split(separator: ".")
        guard parts.count == 2, let runID = UUID(uuidString: String(parts[0])),
              let batch = Int(parts[1]), (0..<ScreenTimePolicy.batchesPerLane).contains(batch),
              ScreenTimePolicy.thresholds(batch: batch).contains(threshold) else { return }
        try store.record(runID: runID, threshold: threshold, now: now)
    }

    func handleInterval(activityName: String, now: Date = Date()) throws {
        let state = try store.snapshot()
        guard state.configuration.enabled, state.contextKey != nil, state.contextIsActive, state.monitoringError == nil,
              activityName == Self.schedulerName(epoch: state.epoch) else { return }
        _ = try synchronize(now: now)
    }

    static func schedulerName(epoch: UUID) -> String { prefix + "scheduler." + epoch.uuidString }
}
