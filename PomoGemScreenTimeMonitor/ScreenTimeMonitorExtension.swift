import DeviceActivity

final class ScreenTimeMonitorExtension: DeviceActivityMonitor {
    private let monitoring = ScreenTimeMonitoring(store: ScreenTimeStore())

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        // The extension deliberately does no networking, model-container work,
        // application launching, or token logging.
        try? monitoring.handleInterval(activityName: activity.rawValue)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        try? monitoring.handleInterval(activityName: activity.rawValue)
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        try? monitoring.handleThreshold(eventName: event.rawValue, activityName: activity.rawValue)
    }
}
