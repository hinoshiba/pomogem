import Foundation
import UserNotifications

/// F5: the decisions FocusView and BreakTimerView make around
/// `TimerEndAnnouncementBooker`, kept out of the views so each is unit tested
/// (TimerEndAnnouncementWiringTests). The views keep only the calls.
///
/// Whether an end rings in the app stays #49's `TimerForegroundResolution`
/// and `TimerCompletionForegroundFeedbackPolicy`; these only settle how the
/// end is announced while the app is away.
enum TimerEndAnnouncementWiring {
    /// How a booker outcome settles a timer screen's end-alert state. Every
    /// case leaves "scheduling": `TimerForegroundResolution` waits while a
    /// booking is in flight, so a state left there would keep an end that
    /// comes on screen from ever resolving.
    enum Settlement: Equatable, Sendable {
        /// The Time Sensitive notification; its delivery date is the witness.
        case notification(deliveryDate: Date)
        /// A system alarm announces the end. There is no notification
        /// witness: the alarm's own is
        /// `FocusEndAlarmScheduler.deliveryWitnessFireDate`.
        case systemAlarm
        /// Nothing can announce the end while the app is away: the screen
        /// shows its notification-permission row.
        case noChannel
        /// A pause, cancel, hand-off or newer booking replaced this call.
        /// Whatever replaced it owns the state; a screen whose own booking is
        /// still the newest (only an account boundary does that) settles as
        /// not scheduled (`settlesSupersededAsIdle`).
        case superseded
    }

    static func settlement(
        for outcome: TimerEndAnnouncementBooker.Outcome
    ) -> Settlement {
        switch outcome {
        case let .notification(.accepted(deliveryDate)):
            .notification(deliveryDate: deliveryDate)
        case .notification(.superseded):
            .superseded
        case .notification(.deferredToSystemAlarm), .systemAlarm:
            .systemAlarm
        case .noChannel:
            .noChannel
        }
    }

    /// A superseded booking whose screen state nothing newer replaced (the
    /// screen's own booking generation is unchanged and it still shows
    /// "scheduling") settles as not scheduled instead of waiting forever.
    static func settlesSupersededAsIdle(
        generationIsCurrent: Bool,
        isScheduling: Bool
    ) -> Bool {
        generationIsCurrent && isScheduling
    }

    /// Whether the screen shows its "setting up" row while the booker runs.
    /// Only a channel that books something: with no channel the booker only
    /// withdraws a leftover alarm, so the permission row stays where it is
    /// instead of flickering on every activation.
    static func showsScheduling(for channel: AlarmBackgroundChannel) -> Bool {
        channel != .none
    }
}

/// The end a timer screen took over from its system alarm just before it
/// (`TimerEndAnnouncementBooker.handOffToForegroundIfDue`: one audible
/// channel, the in-app alarm). If the scene stops being active before that
/// end, nothing else would announce it, so the screen books the notification
/// at once (`book…EndAfterLeavingDuringHandoff`). Only for the same timer,
/// still running toward the same end: a pause, a completion or a new end in
/// between books nothing.
struct TimerEndHandoff: Equatable, Sendable {
    private(set) var sessionID: UUID?
    private(set) var endDate: Date?

    /// The ticker's hand-off returned `endDate` for `sessionID`.
    mutating func record(sessionID: UUID, endDate: Date) {
        self.sessionID = sessionID
        self.endDate = endDate
    }

    /// The scene stopped being active. Returns the end to book the
    /// notification for, at most once; the record is gone afterwards.
    mutating func endToRebookOnLeaving(
        sessionID currentSessionID: UUID?,
        endDate currentEndDate: Date?,
        isRunning: Bool,
        now: Date
    ) -> Date? {
        defer { self = TimerEndHandoff() }
        guard let sessionID, let endDate,
              isRunning,
              currentSessionID == sessionID,
              currentEndDate == endDate,
              endDate > now
        else { return nil }
        return endDate
    }
}

/// What BreakTimerView does with its end alert once it has read the
/// notification permission (F5). An alarm the person allowed announces the
/// end whatever the notification permission, so the break books it even when
/// notifications are declined or not asked yet; the notification rows only
/// show that state.
enum BreakEndAlertPolicy {
    enum Action: Equatable, Sendable {
        /// Book through `TimerEndAnnouncementBooker.bookBreakEnd`.
        case book
        /// Ask for notification permission first (the retry button).
        case requestAuthorization
        case showDenied
        case showPermissionNotDetermined
        case showFailed
    }

    static func action(
        notificationStatus: UNAuthorizationStatus,
        channel: AlarmBackgroundChannel,
        requestsAuthorization: Bool
    ) -> Action {
        if channel == .systemAlarm { return .book }
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            return .book
        case .denied:
            return .showDenied
        case .notDetermined:
            return requestsAuthorization
                ? .requestAuthorization
                : .showPermissionNotDetermined
        @unknown default:
            return .showFailed
        }
    }

    /// The row a break shows when the booker found no channel (no
    /// notification permission, and no system alarm could be booked).
    static func actionWithoutChannel(
        notificationStatus: UNAuthorizationStatus
    ) -> Action {
        switch notificationStatus {
        case .denied: .showDenied
        case .notDetermined: .showPermissionNotDetermined
        default: .showFailed
        }
    }
}
