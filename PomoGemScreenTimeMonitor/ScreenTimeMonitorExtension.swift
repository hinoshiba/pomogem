import DeviceActivity
import Foundation

final class ScreenTimeMonitorExtension: DeviceActivityMonitor {
    /// The app can be suspended while it holds the monitoring lock. Give up
    /// after this bound and let the next callback retry instead of being killed
    /// for blocking in flock.
    private static let monitoringLockTimeout: TimeInterval = 5
    private let monitoring = ScreenTimeMonitoring(store: ScreenTimeStore(),
                                                  lockTimeout: monitoringLockTimeout)

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        // The extension deliberately does no networking, model-container work,
        // application launching, or token logging. Only the callback kind is
        // logged: activity and event names carry the run and the threshold.
        ScreenTimeLog.monitoring.info("extension callback=intervalDidStart")
        try? monitoring.handleInterval(activityName: activity.rawValue)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        ScreenTimeLog.monitoring.info("extension callback=intervalDidEnd")
        try? monitoring.handleInterval(activityName: activity.rawValue)
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        ScreenTimeLog.monitoring.info("extension callback=threshold")
        try? monitoring.handleThreshold(eventName: event.rawValue, activityName: activity.rawValue)
    }
}
