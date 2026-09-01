import Foundation
import Observation

#if targetEnvironment(macCatalyst)
/// Live Activities are unavailable in Mac Catalyst. Keeping this no-op facade
/// lets the focus engine share its lifecycle code without promising a Mac UI
/// surface that ActivityKit does not provide.
@MainActor
@Observable
final class FocusActivityManager {
    static let shared = FocusActivityManager()

    private(set) var currentActivityID: String?
    private(set) var currentSessionID: UUID?
    private(set) var activitiesEnabled = false
    private(set) var lastErrorDescription: String?

    private init() {}

    func refreshAuthorization() {
        activitiesEnabled = false
    }

    @discardableResult
    func start(
        sessionID: UUID,
        subjectName: String,
        subjectColorHex: String,
        durationSeconds: Int,
        endDate: Date
    ) async throws -> String? {
        nil
    }

    func pause(sessionID: UUID, remainingSeconds: Int) async {}

    func resume(sessionID: UUID, endDate: Date) async {}

    func complete(
        sessionID: UUID,
        grams: Int? = nil,
        now: Date = .now
    ) async {}

    func cancel(sessionID: UUID) async {}

    func endAll() async {}

    func restoreCurrentActivity(for sessionID: UUID? = nil) {}
}
#else
import ActivityKit

/// App-side lifecycle controller for the focus Live Activity.
@MainActor
@Observable
final class FocusActivityManager {
    static let shared = FocusActivityManager()

    private(set) var currentActivityID: String?
    private(set) var currentSessionID: UUID?
    private(set) var activitiesEnabled: Bool
    private(set) var lastErrorDescription: String?

    private init() {
        activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        restoreCurrentActivity()
    }

    func refreshAuthorization() {
        activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Starts one Live Activity and closes any orphan left by an interrupted
    /// session. A disabled Live Activity setting is a supported no-op.
    @discardableResult
    func start(
        sessionID: UUID,
        subjectName: String,
        subjectColorHex: String,
        durationSeconds: Int,
        endDate: Date
    ) async throws -> String? {
        refreshAuthorization()
        guard activitiesEnabled else {
            currentActivityID = nil
            currentSessionID = nil
            return nil
        }

        await endAll(dismissalPolicy: .immediate)

        let attributes = FocusActivityAttributes(
            sessionID: sessionID,
            subjectName: SubjectNamePolicy.displayName(subjectName),
            subjectColorHex: subjectColorHex,
            durationSeconds: max(0, durationSeconds)
        )
        let state = FocusActivityAttributes.ContentState.running(until: endDate)
        let content = ActivityContent(state: state, staleDate: endDate)

        do {
            let activity = try Activity<FocusActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            currentActivityID = activity.id
            currentSessionID = sessionID
            lastErrorDescription = nil
            return activity.id
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func pause(sessionID: UUID, remainingSeconds: Int) async {
        guard let activity = activity(for: sessionID) else { return }
        let state = FocusActivityAttributes.ContentState.paused(
            remainingSeconds: remainingSeconds
        )
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    func resume(sessionID: UUID, endDate: Date) async {
        guard let activity = activity(for: sessionID) else { return }
        let state = FocusActivityAttributes.ContentState.running(until: endDate)
        await activity.update(ActivityContent(state: state, staleDate: endDate))
    }

    /// Ends with a final state so the Lock Screen and Dynamic Island show the
    /// exact completion copy before dismissing themselves shortly afterward.
    func complete(
        sessionID: UUID,
        grams: Int? = nil,
        now: Date = .now
    ) async {
        guard let activity = activity(for: sessionID) else { return }
        let completedGrams = grams ?? IntegrationConstants.grams(
            forFocusDuration: activity.attributes.durationSeconds
        )
        let state = FocusActivityAttributes.ContentState.completed(
            grams: completedGrams
        )
        let content = ActivityContent(state: state, staleDate: nil)
        let dismissalDate = now.addingTimeInterval(
            IntegrationConstants.liveActivityDismissalDelay
        )
        await activity.end(content, dismissalPolicy: .after(dismissalDate))
        clearCurrentIfMatching(activity)
    }

    func cancel(sessionID: UUID) async {
        guard let activity = activity(for: sessionID) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        clearCurrentIfMatching(activity)
    }

    func endAll(
        dismissalPolicy: ActivityUIDismissalPolicy = .immediate
    ) async {
        let activities = Activity<FocusActivityAttributes>.activities
        for activity in activities {
            await activity.end(nil, dismissalPolicy: dismissalPolicy)
        }
        currentActivityID = nil
        currentSessionID = nil
    }

    /// Reconnects UI state to a Live Activity after process recreation.
    func restoreCurrentActivity(for sessionID: UUID? = nil) {
        let activities = Activity<FocusActivityAttributes>.activities
        let activity: Activity<FocusActivityAttributes>?
        if let sessionID {
            activity = activities.first { $0.attributes.sessionID == sessionID }
        } else {
            activity = activities.first
        }

        currentActivityID = activity?.id
        currentSessionID = activity?.attributes.sessionID
    }

    private func activity(
        for sessionID: UUID
    ) -> Activity<FocusActivityAttributes>? {
        let activities = Activity<FocusActivityAttributes>.activities
        if let currentActivityID,
           let current = activities.first(where: { $0.id == currentActivityID }),
           current.attributes.sessionID == sessionID {
            return current
        }
        return activities.first { $0.attributes.sessionID == sessionID }
    }

    private func clearCurrentIfMatching(
        _ activity: Activity<FocusActivityAttributes>
    ) {
        guard currentActivityID == activity.id else { return }
        currentActivityID = nil
        currentSessionID = nil
    }
}
#endif
