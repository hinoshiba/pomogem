import DeviceActivity
import Foundation

final class ScreenTimeMonitorExtension: DeviceActivityMonitor {
    /// The app can be suspended while it holds the monitoring lock. Give up
    /// after this bound and let the next callback retry instead of being killed
    /// for blocking in flock.
    private static let monitoringLockTimeout: TimeInterval = 5
    /// `forMonitorExtension` is what tells `ScreenTimeMonitoring` that a
    /// Family Controls status read HERE is not evidence about the user's
    /// authorization: this process is spawned on demand to deliver one
    /// callback, and on a real device it answered `.notDetermined` for every
    /// threshold while the app read 許可済み. Only an explicit `.denied` is
    /// acted on; the ledger still owns every award.
    ///
    /// It is a factory rather than a `host:` argument because this file is not
    /// linked into `PomoGemTests`: nothing here can be observed by a test, so
    /// the choice lives in `Shared/ScreenTimeMonitoring.swift`, where
    /// `testTheMonitorExtensionIsBuiltForTheExtensionHost` pins it.
    private let monitoring = ScreenTimeMonitoring.forMonitorExtension(
        store: ScreenTimeStore(), lockTimeout: monitoringLockTimeout)

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        if FocusShieldPolicy.isFailsafeActivity(activity.rawValue) {
            handleFocusShield(activity, phase: .start)
            return
        }
        // The extension deliberately does no networking, model-container work,
        // application launching, or token logging. Only the callback kind is
        // logged: activity and event names carry the run and the threshold.
        // `kind` says which registration of ours the OS named — a lane's dated,
        // non-repeating interval or the one recurring scheduler — which the
        // bare callback name never did.
        log("intervalDidStart", activity)
        try? monitoring.handleInterval(activityName: activity.rawValue, phase: .start)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        if FocusShieldPolicy.isFailsafeActivity(activity.rawValue) {
            handleFocusShield(activity, phase: .end)
            return
        }
        log("intervalDidEnd", activity)
        try? monitoring.handleInterval(activityName: activity.rawValue, phase: .end)
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        log("threshold", activity)
        try? monitoring.handleThreshold(eventName: event.rawValue, activityName: activity.rawValue)
    }

    /// The focus shield's failsafe interval. Kept apart from the gem lanes:
    /// it clears the named ManagedSettings store when the record says the
    /// focus is over (or says nothing readable), never looks at Family
    /// Controls authorization, and never loads SwiftData, CloudKit or the
    /// selections. The rule lives in `FocusShieldEngine.handleExtensionInterval`,
    /// where the unit tests can reach it. Counted as an `other` interval in the
    /// ledger's callback diagnostics, so a device audit can tell whether the
    /// OS ever delivered it.
    private func handleFocusShield(_ activity: DeviceActivityName, phase: ScreenTimeCallbackCounters.IntervalPhase) {
        log(phase == .start ? "intervalDidStart" : "intervalDidEnd", activity)
        let now = Date()
        let cleared = FocusShieldEngine.live(lockTimeout: FocusShieldPolicy.extensionLockTimeout)
            .handleExtensionInterval(phase: phase, now: now)
        ScreenTimeLog.monitoring.notice("""
            focus-shield interval phase=\(phase.rawValue, privacy: .public) \
            cleared=\(cleared ? 1 : 0, privacy: .public)
            """)
        ScreenTimeStore().countCallback { $0.countIntervalCallback(kind: .other, phase: phase, now: now) }
    }

    private func log(_ callback: String, _ activity: DeviceActivityName) {
        ScreenTimeLog.monitoring.notice("""
            extension callback=\(callback, privacy: .public) \
            kind=\(ScreenTimeActivityKind(activityName: activity.rawValue).rawValue, privacy: .public)
            """)
    }
}
