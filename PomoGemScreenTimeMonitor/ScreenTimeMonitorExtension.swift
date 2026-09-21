import DeviceActivity
import Foundation

final class ScreenTimeMonitorExtension: DeviceActivityMonitor {
    /// The app can be suspended while it holds the monitoring lock. Give up
    /// after this bound and let the next callback retry instead of being killed
    /// for blocking in flock.
    private static let monitoringLockTimeout: TimeInterval = 5
    /// `host: .monitorExtension` is what tells `ScreenTimeMonitoring` that a
    /// Family Controls status read HERE is not evidence about the user's
    /// authorization: this process is spawned on demand to deliver one
    /// callback, and on a real device it answered `.notDetermined` for every
    /// threshold while the app read 許可済み. Only an explicit `.denied` is
    /// acted on; the ledger still owns every award.
    private let monitoring = ScreenTimeMonitoring(store: ScreenTimeStore(),
                                                  lockTimeout: monitoringLockTimeout,
                                                  host: .monitorExtension)

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
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
        log("intervalDidEnd", activity)
        try? monitoring.handleInterval(activityName: activity.rawValue, phase: .end)
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        log("threshold", activity)
        try? monitoring.handleThreshold(eventName: event.rawValue, activityName: activity.rawValue)
    }

    private func log(_ callback: String, _ activity: DeviceActivityName) {
        ScreenTimeLog.monitoring.notice("""
            extension callback=\(callback, privacy: .public) \
            kind=\(ScreenTimeActivityKind(activityName: activity.rawValue).rawValue, privacy: .public)
            """)
    }
}
