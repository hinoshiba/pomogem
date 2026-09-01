import Foundation

/// Identifiers and tuning values shared by the app and its widget extension.
///
/// Keeping these in the shared target prevents either process from silently
/// drifting to a different App Group path or WidgetKit kind.
public enum IntegrationConstants {
    public static let appGroupIdentifier = "group.com.hinoshiba.tsumiben"

    public static let homeWidgetKind = "TsumibenJarWidget"
    public static let lockScreenWidgetKind = "TsumibenMassWidget"
    public static let liveActivityWidgetKind = "TsumibenFocusLiveActivity"

    public static let widgetSnapshotImageFileName = "jar-widget.png"
    public static let widgetSnapshotMetadataFileName = "jar-widget.json"
    public static let widgetTimelineRefreshInterval: TimeInterval = 15 * 60

    public static let defaultCompletedGrams = 250
    public static let secondsPerMinute = 60
    public static let gramsPerMinute = 10
    public static let liveActivityDismissalDelay: TimeInterval = 2 * 60
    public static let notificationMinimumDelay: TimeInterval = 1
    public static let passiveNotificationHorizonDays = 35

    public static let freeFocusDurations: Set<Int> = [1_500, 3_600]

    /// The only paid product offered by the app.
    ///
    /// Keep this identifier stable: non-consumable purchases are restored by
    /// matching the App Store transaction to this exact product identifier.
    public static let proProductID = "com.hinoshiba.tsumiben.pro.lifetime"
    public static let proProductIDs: Set<String> = [proProductID]

    public static func appGroupContainerURL(
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
    }

    public static func isFreeFocusDuration(_ seconds: Int) -> Bool {
        freeFocusDurations.contains(seconds)
    }

    public static func grams(forFocusDuration seconds: Int) -> Int {
        max(0, seconds) / secondsPerMinute * gramsPerMinute
    }
}
