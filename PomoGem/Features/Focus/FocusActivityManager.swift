import Foundation
import Observation

enum FocusActivityPreference {
    static let enabledDefaultsKey = "live-activity.enabled"

    static func isEnabled(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: enabledDefaultsKey) == nil
            || defaults.bool(forKey: enabledDefaultsKey)
    }
}

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
        durationSeconds: Int,
        endDate: Date
    ) async throws -> String? {
        nil
    }

    @discardableResult
    func startPaused(
        sessionID: UUID,
        durationSeconds: Int,
        remainingSeconds: Int
    ) async throws -> String? {
        nil
    }

    func updateIfPresent(
        sessionID: UUID,
        endDate: Date
    ) async {}

    func pause(sessionID: UUID, remainingSeconds: Int) async {}

    func resume(sessionID: UUID, endDate: Date) async {}

    func complete(
        sessionID: UUID,
        now: Date = .now
    ) async {}

    func cancel(sessionID: UUID) async {}

    func endAll() async {}

    func reconcileWithDurableSession(_ sessionID: UUID?) async {}

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
    private var lifecycleGeneration: UInt64 = 0

    private init() {
        activitiesEnabled = Self.releaseAndLocalPolicyAllowsActivities
            && ActivityAuthorizationInfo().areActivitiesEnabled
        if activitiesEnabled {
            restoreCurrentActivity()
        }
    }

    func refreshAuthorization() {
        activitiesEnabled = Self.releaseAndLocalPolicyAllowsActivities
            && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Starts one Live Activity and closes any orphan left by a previous
    /// session. Rechecking after awaited cleanup keeps concurrent activation
    /// tasks from creating duplicate activities for the same session.
    @discardableResult
    func start(
        sessionID: UUID,
        durationSeconds: Int,
        endDate: Date
    ) async throws -> String? {
        let state = FocusActivityAttributes.ContentState.running(until: endDate)
        return try await startActivity(
            sessionID: sessionID,
            durationSeconds: durationSeconds,
            content: ActivityContent(state: state, staleDate: endDate)
        )
    }

    /// Creates a paused surface only for the same explicit start/handoff
    /// boundary as `start`. Ordinary recovery calls `pause` and never recreates
    /// a surface the person dismissed.
    @discardableResult
    func startPaused(
        sessionID: UUID,
        durationSeconds: Int,
        remainingSeconds: Int
    ) async throws -> String? {
        let state = FocusActivityAttributes.ContentState.paused(
            remainingSeconds: remainingSeconds
        )
        return try await startActivity(
            sessionID: sessionID,
            durationSeconds: durationSeconds,
            content: ActivityContent(state: state, staleDate: nil)
        )
    }

    private func startActivity(
        sessionID: UUID,
        durationSeconds: Int,
        content: ActivityContent<FocusActivityAttributes.ContentState>
    ) async throws -> String? {
        let generation = beginLifecycleMutation()
        guard Self.releaseAndLocalPolicyAllowsActivities else {
            await endAll(dismissalPolicy: .immediate)
            return nil
        }
        refreshAuthorization()
        guard activitiesEnabled else {
            await endAll(dismissalPolicy: .immediate)
            return nil
        }

        var retainedActivity: Activity<FocusActivityAttributes>?
        for activity in Activity<FocusActivityAttributes>.activities {
            if activity.attributes.sessionID == sessionID,
               retainedActivity == nil {
                retainedActivity = activity
            } else {
                // End both foreign sessions and any duplicate from an older
                // re-entrant start implementation.
                await activity.end(nil, dismissalPolicy: .immediate)
                guard lifecycleGeneration == generation else { return nil }
            }
        }

        if let activity = retainedActivity {
            await activity.update(content)
            guard lifecycleGeneration == generation else { return nil }
            currentActivityID = activity.id
            currentSessionID = sessionID
            lastErrorDescription = nil
            return activity.id
        }

        let attributes = FocusActivityAttributes(
            sessionID: sessionID,
            durationSeconds: durationSeconds
        )

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

    /// Updates a still-present activity without recreating one the person or
    /// the system dismissed. New activities are created only for an explicit
    /// timer start or an explicit iCloud handoff.
    func updateIfPresent(
        sessionID: UUID,
        endDate: Date
    ) async {
        let generation = beginLifecycleMutation()
        refreshAuthorization()
        guard activitiesEnabled,
              let activity = activity(for: sessionID) else { return }
        let state = FocusActivityAttributes.ContentState.running(until: endDate)
        await activity.update(ActivityContent(state: state, staleDate: endDate))
        guard lifecycleGeneration == generation else { return }
        currentActivityID = activity.id
        currentSessionID = sessionID
    }

    func pause(sessionID: UUID, remainingSeconds: Int) async {
        _ = beginLifecycleMutation()
        guard Self.releaseAndLocalPolicyAllowsActivities else {
            await cancel(sessionID: sessionID)
            return
        }
        guard let activity = activity(for: sessionID) else { return }
        let state = FocusActivityAttributes.ContentState.paused(
            remainingSeconds: remainingSeconds
        )
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    func resume(sessionID: UUID, endDate: Date) async {
        _ = beginLifecycleMutation()
        guard Self.releaseAndLocalPolicyAllowsActivities else {
            await cancel(sessionID: sessionID)
            return
        }
        guard let activity = activity(for: sessionID) else { return }
        let state = FocusActivityAttributes.ContentState.running(until: endDate)
        await activity.update(ActivityContent(state: state, staleDate: endDate))
    }

    /// Ends with a final state so the Lock Screen and Dynamic Island show the
    /// exact completion copy before dismissing themselves shortly afterward.
    func complete(
        sessionID: UUID,
        now: Date = .now
    ) async {
        let generation = beginLifecycleMutation()
        guard Self.releaseAndLocalPolicyAllowsActivities else {
            await cancel(sessionID: sessionID)
            return
        }
        guard let activity = activity(for: sessionID) else { return }
        let state = FocusActivityAttributes.ContentState.completed()
        let content = ActivityContent(state: state, staleDate: nil)
        let dismissalDate = now.addingTimeInterval(
            FocusActivityConstants.dismissalDelay
        )
        await activity.end(content, dismissalPolicy: .after(dismissalDate))
        guard lifecycleGeneration == generation else { return }
        clearCurrentIfMatching(activity)
    }

    func cancel(sessionID: UUID) async {
        let generation = beginLifecycleMutation()
        guard let activity = activity(for: sessionID) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        guard lifecycleGeneration == generation else { return }
        clearCurrentIfMatching(activity)
    }

    func endAll(
        dismissalPolicy: ActivityUIDismissalPolicy = .immediate
    ) async {
        let generation = beginLifecycleMutation()
        let activities = Activity<FocusActivityAttributes>.activities
        for activity in activities {
            await activity.end(nil, dismissalPolicy: dismissalPolicy)
            guard lifecycleGeneration == generation else { return }
        }
        currentActivityID = nil
        currentSessionID = nil
    }

    /// Reconciles OS-owned state only after the launch path has validated the
    /// durable local focus envelope. This removes an orphan left by a process
    /// termination between clearing persistence and awaiting ActivityKit,
    /// while deliberately not recreating an activity dismissed by the user.
    func reconcileWithDurableSession(_ sessionID: UUID?) async {
        guard Self.releaseAndLocalPolicyAllowsActivities,
              let sessionID else {
            await endAll(dismissalPolicy: .immediate)
            return
        }

        let generation = beginLifecycleMutation()
        let activities = Activity<FocusActivityAttributes>.activities
        var retained: Activity<FocusActivityAttributes>?
        for activity in activities {
            if activity.attributes.sessionID == sessionID, retained == nil {
                retained = activity
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
                guard lifecycleGeneration == generation else { return }
            }
        }

        currentActivityID = retained?.id
        currentSessionID = retained?.attributes.sessionID
    }

    /// Reconnects UI state to a Live Activity after process recreation.
    func restoreCurrentActivity(for sessionID: UUID? = nil) {
        guard ReleaseExternalSurfacePolicy.supportsLiveActivities else {
            currentActivityID = nil
            currentSessionID = nil
            return
        }
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

    @discardableResult
    private func beginLifecycleMutation() -> UInt64 {
        lifecycleGeneration &+= 1
        return lifecycleGeneration
    }

    /// UI tests exercise timer behavior, not OS-owned surfaces. Suppressing
    /// ActivityKit in that explicitly opted-in Debug process prevents a failed
    /// test from leaving a Live Activity behind for the next test or launch.
    private static var releaseAndLocalPolicyAllowsActivities: Bool {
        ReleaseExternalSurfacePolicy.supportsLiveActivities
            && FocusActivityPreference.isEnabled()
            && !LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess
    }
}
#endif
