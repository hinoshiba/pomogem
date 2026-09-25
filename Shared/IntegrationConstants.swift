import Foundation

/// Version 1 deliberately keeps every OS-owned surface account-neutral.
///
/// WidgetKit and ActivityKit may continue showing an already-rendered view while
/// the application process is terminated, so neither surface may contain a
/// category name, account identifier, or other user-authored content. The Live
/// Activity is allowed because it renders only the timer and app-owned labels.
enum ReleaseExternalSurfacePolicy {
    static let showsAccountDataInWidgets = false
    static let supportsLiveActivities = true
}

/// Stable identifiers and tuning values retained by the host application.
/// The version 1 Widget intentionally has no dependency on this source file.
public enum IntegrationConstants {
    public static let homeWidgetKind = "PomoGemJarWidget"
    public static let lockScreenWidgetKind = "PomoGemMassWidget"
    public static let widgetSnapshotImageFileName = "jar-widget.png"
    public static let widgetSnapshotMetadataFileName = "jar-widget.json"
    public static let widgetTimelineRefreshInterval: TimeInterval = 15 * 60

    public static let secondsPerMinute = 60
    public static let gramsPerMinute = 10
    public static let notificationMinimumDelay: TimeInterval = 1
    /// A delivery witness suppresses the in-app cue only while wall time and
    /// the continuous clock remain this closely aligned. False negatives can
    /// duplicate a cue; false positives can make completion entirely silent.
    public static let notificationClockDriftTolerance: TimeInterval = 1
    /// Notification Center registration is asynchronous. A later witness is
    /// harmless (the app may replay the cue), while an implausibly late value
    /// is discarded instead of suppressing feedback indefinitely.
    public static let notificationWitnessRegistrationAllowance: TimeInterval = 30
    /// The rolling window of one-shot passive requests. It is long enough to
    /// reach the next 1st of the month, so monthly Wrapped always has a slot.
    public static let passiveNotificationHorizonDays = 35
    /// The generic daily reminder is booked only this far past the last time
    /// the app was open. Someone who stepped away is not pursued for weeks;
    /// opening the app again quietly re-arms it.
    public static let passiveDailyReminderHorizonDays = 7

    public static let freeFocusDurations: Set<Int> = [
        25 * secondsPerMinute,
        45 * secondsPerMinute,
        60 * secondsPerMinute,
        90 * secondsPerMinute
    ]

    /// The only paid product offered by the app.
    ///
    /// Keep this identifier stable: non-consumable purchases are restored by
    /// matching the App Store transaction to this exact product identifier.
    public static let proProductID = "com.hinoshiba.pomogem.pro.lifetime"
    public static let proProductIDs: Set<String> = [proProductID]

    public static func isFreeFocusDuration(_ seconds: Int) -> Bool {
        freeFocusDurations.contains(seconds)
    }
}
