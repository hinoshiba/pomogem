import Foundation
import LocalAuthentication
import OSLog
import SwiftUI
import UIKit

/// The running focus this device owns, as its screen registered it with
/// `NotificationManager` (only the ownership-claim device registers).
struct FocusLeaveCandidate: Equatable, Sendable {
    let sessionID: UUID
    let endDate: Date
    let playsSound: Bool
    let completionSound: TimerCompletionSound
}

/// The live reading of the two device-local F1 switches. Settings rows are a
/// later phase; they call `setLeavePauseEnabled` / `setNudgesEnabled` so that
/// turning either off also withdraws a series already booked.
@MainActor
enum FocusLeavePreferences {
    /// UI tests start and background many focuses on shared simulators, which
    /// have no passcode; only a test that opts in meets the leave pause, the
    /// same way only an opted-in test meets the notification permission
    /// dialog. An explicit switch still wins. Release builds always use the
    /// product default.
    nonisolated static let uiTestOptInEnvironmentKey = "POMOGEM_UI_TEST_FOCUS_LEAVE_PAUSE"

    nonisolated static var defaultValue: Bool {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if LocalPreviewLaunchPolicy.isUITestMode(environment: environment, isDebugBuild: true) {
            return environment[uiTestOptInEnvironmentKey] == "1"
        }
#endif
        return FocusLeavePolicy.enabledByDefault
    }

    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        FocusLeavePolicy.isEnabled(defaults: defaults, defaultValue: defaultValue)
    }

    nonisolated static func nudgesAreEnabled(defaults: UserDefaults = .standard) -> Bool {
        FocusLeavePolicy.nudgesAreEnabled(defaults: defaults, defaultValue: defaultValue)
    }

    static func setLeavePauseEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard,
        notifications: NotificationManager? = nil
    ) {
        defaults.set(enabled, forKey: FocusLeavePolicy.enabledDefaultsKey)
        if !enabled { (notifications ?? .shared).cancelFocusLeaveNudges() }
    }

    static func setNudgesEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard,
        notifications: NotificationManager? = nil
    ) {
        defaults.set(enabled, forKey: FocusLeavePolicy.nudgesEnabledDefaultsKey)
        if !enabled { (notifications ?? .shared).cancelFocusLeaveNudges() }
    }
}

/// Whether this iPhone has a passcode. Without one iOS never reports a lock,
/// so a lock cannot be told from leaving the app. Only the yes/no answer is
/// read; no biometric or passcode prompt is ever shown.
enum FocusLeaveDeviceSecurity {
    static func deviceHasPasscode() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
}

/// Owns an absence from a running focus (F1). It lives on the launch host,
/// which survives the iCloud background grace retiring RootView and
/// FocusView, so it acts on the saved timer, Notification Center and the Live
/// Activity directly. It generalises `FocusReturnReminderLockWindow`: the
/// lock-versus-leave decision runs whether or not notifications are allowed.
///
/// At `.background` the absence is written into the saved timer at once, so
/// a relaunch or any later reader applies it even if this process never gets
/// another turn. Within the 20-second window a lock notice keeps the timer
/// running; the end of the window, or iOS taking the background time back,
/// pauses it retroactively at the moment the person left. Coming back within
/// the window changes nothing.
@MainActor
final class FocusLeaveMonitor {
    /// Posted on the main thread after the host paused a focus because the
    /// person left. A mounted focus screen adopts the saved pause at once so
    /// it can never write its stale running state back.
    static let didAutoPause = Notification.Name("PomoGem.FocusLeaveMonitor.didAutoPause")
    static let sessionIDUserInfoKey = "sessionID"

    struct Dependencies {
        var now: @MainActor () -> Date
        var isEnabled: @MainActor () -> Bool
        var runningFocus: @MainActor () -> FocusLeaveCandidate?
        /// The saved timer's key for the account active right now. Captured
        /// when an absence starts, so a later account boundary cannot
        /// redirect its writes to another account's timer.
        var persistenceKey: @MainActor () -> String?
        /// The stored envelope, with no absence applied.
        var loadEnvelope: @MainActor (String) -> FocusRecoveryEnvelope?
        /// Writes exactly this envelope.
        var replaceEnvelope: @MainActor (FocusRecoveryEnvelope, String) -> Void
        var deviceHasPasscode: @MainActor () -> Bool
        var protectedDataIsAvailable: @MainActor () -> Bool
        var applicationIsActive: @MainActor () -> Bool
        /// Returns early when the waiting task is cancelled.
        var sleep: @MainActor (TimeInterval) async -> Void
        var beginBackgroundTask: @MainActor (
            _ expiration: @escaping @MainActor () -> Void
        ) -> UIBackgroundTaskIdentifier
        var endBackgroundTask: @MainActor (UIBackgroundTaskIdentifier) -> Void
        var notificationCenter: NotificationCenter
        var scheduleNudges: @MainActor (FocusLeaveCandidate, Date) async -> Void
        var withdrawNudges: @MainActor () -> Void
        /// Removes the end alert of a paused focus, keeping the series.
        var cancelCompletionKeepingNudges: @MainActor (UUID) -> Void
        var pauseLiveActivity: @MainActor (UUID, Int) async -> Void
        var announceAutoPause: @MainActor (UUID) -> Void

        static var live: Self {
            Self(
                now: { .now },
                isEnabled: { FocusLeavePreferences.isEnabled() },
                runningFocus: { NotificationManager.shared.registeredRunningFocus },
                persistenceKey: { FocusPersistence.key },
                loadEnvelope: { FocusPersistence.loadStored(key: $0) },
                replaceEnvelope: { FocusPersistence.replace($0, key: $1) },
                deviceHasPasscode: { FocusLeaveDeviceSecurity.deviceHasPasscode() },
                protectedDataIsAvailable: { UIApplication.shared.isProtectedDataAvailable },
                applicationIsActive: { UIApplication.shared.applicationState == .active },
                sleep: { try? await Task.sleep(for: .seconds($0)) },
                beginBackgroundTask: { expiration in
                    UIApplication.shared.beginBackgroundTask(
                        withName: "Classify leaving a focus"
                    ) {
                        MainActor.assumeIsolated { expiration() }
                    }
                },
                endBackgroundTask: { UIApplication.shared.endBackgroundTask($0) },
                notificationCenter: .default,
                scheduleNudges: { candidate, leftAt in
                    _ = try? await NotificationManager.shared.scheduleFocusLeaveNudges(
                        sessionID: candidate.sessionID,
                        leftAt: leftAt,
                        playsSound: candidate.playsSound,
                        completionSound: candidate.completionSound
                    )
                },
                withdrawNudges: { NotificationManager.shared.cancelFocusLeaveNudges() },
                cancelCompletionKeepingNudges: {
                    NotificationManager.shared.cancelFocusCompletion(
                        sessionID: $0,
                        withdrawingLeaveNudges: false
                    )
                },
                pauseLiveActivity: {
                    await FocusActivityManager.shared.pause(sessionID: $0, remainingSeconds: $1)
                },
                announceAutoPause: { sessionID in
                    NotificationCenter.default.post(
                        name: FocusLeaveMonitor.didAutoPause,
                        object: nil,
                        userInfo: [FocusLeaveMonitor.sessionIDUserInfoKey: sessionID]
                    )
                }
            )
        }
    }

    private struct Window {
        let generation: UInt64
        let sessionID: UUID
        let leftAt: Date
        let key: String
        let candidate: FocusLeaveCandidate
        let deviceHasPasscode: Bool
    }

    private static let logger = Logger(
        subsystem: "com.hinoshiba.pomogem",
        category: "FocusLeave"
    )

    private let dependencies: Dependencies
    /// Bumped whenever a window closes; every callback carries the value it
    /// was created with, so nothing left over from an earlier absence (a
    /// queued notice, a late add, a sleeping deadline, an expiry) can decide
    /// a newer one or end a newer window's background task.
    private var generation: UInt64 = 0
    private var window: Window?
    private var task: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lockObserver: NSObjectProtocol?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// True while an absence is being watched in this process.
    var isWatching: Bool { window != nil }

    /// Call for every scene phase. Only `.background` opens an absence; only
    /// `.active` (with UIKit also active) ends one. `.inactive` — Control
    /// Center, a permission sheet, Face ID — is never an absence.
    func handle(_ phase: ScenePhase) {
        switch phase {
        case .background:
            beginIfEligible()
        case .active:
            handleReturn()
        default:
            break
        }
    }

    /// SwiftUI and UIKit can report activation in either order; the second
    /// signal finishes a return the first one could not yet confirm.
    func handleApplicationDidBecomeActive() {
        handleReturn()
    }

    /// An account boundary or a storage relaunch: stop watching without
    /// deciding. A marker left in the saved timer is applied by the next
    /// reader once its window has certainly ended.
    func cancel() {
        let identifier = closeWindow()
        dependencies.withdrawNudges()
        endBackgroundTask(identifier)
    }

    // MARK: - Leaving

    private func beginIfEligible() {
        // A second `.background` without a confirmed return continues the
        // first absence; its start time stays the moment the person left.
        guard window == nil else { return }
        guard dependencies.isEnabled(),
              let key = dependencies.persistenceKey(),
              let candidate = dependencies.runningFocus(),
              var envelope = dependencies.loadEnvelope(key),
              envelope.engine.currentSessionID == candidate.sessionID
        else { return }
        let now = dependencies.now()

        if let earlier = envelope.leaveExcursion {
            // An earlier absence nobody decided. One whose window has ended
            // is applied first and can only leave the focus paused.
            if FocusLeavePolicy.isStale(leftAt: earlier.leftAt, now: now) {
                updateLiveActivity(
                    applyLeft(
                        sessionID: earlier.sessionID,
                        leftAt: earlier.leftAt,
                        key: key,
                        decidedAt: now
                    ),
                    thenEnd: .invalid
                )
                return
            }
        } else {
            guard let started = FocusLeaveTransition.beginningExcursion(
                envelope,
                featureEnabled: true,
                at: now
            ) else { return }
            envelope = started
            // Synchronously, before the process can be suspended or killed.
            dependencies.replaceEnvelope(envelope, key)
        }
        guard let excursion = envelope.leaveExcursion else { return }
        open(Window(
            generation: generation,
            sessionID: excursion.sessionID,
            leftAt: excursion.leftAt,
            key: key,
            candidate: candidate,
            deviceHasPasscode: dependencies.deviceHasPasscode()
        ))
    }

    private func open(_ newWindow: Window) {
        let generation = newWindow.generation
        window = newWindow
        backgroundTask = dependencies.beginBackgroundTask { [weak self] in
            self?.decide(.backgroundTimeExpired, generation: generation)
        }
        // Observe from the start: a lock during a slow add must also win.
        lockObserver = dependencies.notificationCenter.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.decide(.lockNotice, generation: generation)
            }
        }
        task = Task { [weak self] in
            await self?.run(generation)
        }
    }

    private func run(_ generation: UInt64) async {
        guard isCurrent(generation), let window else { return }
        // Already locked: protected data went away before `.background`.
        if window.deviceHasPasscode, !dependencies.protectedDataIsAvailable() {
            decide(.windowEnded(protectedDataIsAvailable: false), generation: generation)
            return
        }
        await dependencies.scheduleNudges(window.candidate, window.leftAt)
        guard isCurrent(generation) else { return }
        let deadline = window.leftAt.addingTimeInterval(FocusLeavePolicy.lockDetectionWindow)
        let remaining = deadline.timeIntervalSince(dependencies.now())
        if remaining > 0 {
            await dependencies.sleep(remaining)
        }
        guard isCurrent(generation) else { return }
        decide(
            .windowEnded(protectedDataIsAvailable: dependencies.protectedDataIsAvailable()),
            generation: generation
        )
    }

    private func decide(_ signal: FocusLeavePolicy.WindowSignal, generation: UInt64) {
        guard generation == self.generation, let window else { return }
        let classification = FocusLeavePolicy.classify(
            signal,
            deviceHasPasscode: window.deviceHasPasscode
        )
        let identifier = closeWindow()
        switch classification {
        case .locked:
            Self.logger.info("Focus absence classified as a lock; the timer keeps running")
            if let envelope = dependencies.loadEnvelope(window.key),
               envelope.leaveExcursion?.sessionID == window.sessionID {
                dependencies.replaceEnvelope(
                    FocusLeaveTransition.resolvingAsLocked(envelope),
                    window.key
                )
            }
            dependencies.withdrawNudges()
            endBackgroundTask(identifier)
        case .left:
            Self.logger.info("Focus absence classified as leaving the app; pausing the timer")
            let pause = applyLeft(
                sessionID: window.sessionID,
                leftAt: window.leftAt,
                key: window.key,
                decidedAt: dependencies.now()
            )
            if pause == nil {
                // Nothing is paused (the timer changed meanwhile), so a
                // series saying so would be false.
                dependencies.withdrawNudges()
            }
            if signal == .backgroundTimeExpired {
                // The expiration handler must end its task now.
                endBackgroundTask(identifier)
                updateLiveActivity(pause, thenEnd: .invalid)
            } else {
                // Keep the background time until the Live Activity shows the
                // pause, then give it back.
                updateLiveActivity(pause, thenEnd: identifier)
            }
        }
    }

    private struct AppliedPause {
        let sessionID: UUID
        let remainingSeconds: Int
    }

    private func updateLiveActivity(
        _ pause: AppliedPause?,
        thenEnd identifier: UIBackgroundTaskIdentifier
    ) {
        let dependencies = dependencies
        Task { @MainActor in
            if let pause {
                await dependencies.pauseLiveActivity(pause.sessionID, pause.remainingSeconds)
            }
            if identifier != .invalid {
                dependencies.endBackgroundTask(identifier)
            }
        }
    }

    /// Pauses the saved focus at `leftAt` (unless a reader already did) and
    /// applies the side effects that belong to a paused focus: no end alert,
    /// the screen adopts the pause. The Live Activity update is returned for
    /// the caller to await while it still holds background time.
    @discardableResult
    private func applyLeft(
        sessionID: UUID,
        leftAt: Date,
        key: String,
        decidedAt now: Date
    ) -> AppliedPause? {
        guard var envelope = dependencies.loadEnvelope(key),
              envelope.engine.currentSessionID == sessionID else { return nil }
        if envelope.leaveExcursion?.sessionID == sessionID {
            envelope = FocusLeaveTransition.pausedForLeaving(envelope, decidedAt: now)
            dependencies.replaceEnvelope(envelope, key)
        }
        guard let marker = envelope.currentLeavePause,
              marker.sessionID == sessionID,
              marker.pausedAt == leftAt else { return nil }
        dependencies.cancelCompletionKeepingNudges(sessionID)
        dependencies.announceAutoPause(sessionID)
        return AppliedPause(
            sessionID: sessionID,
            remainingSeconds: envelope.engine.snapshot(at: now).remainingSeconds
        )
    }

    // MARK: - Returning

    private func handleReturn() {
        // The iOS 26 Lock sequence reports a brief activation before
        // `.background`; only UIKit's own `.active` confirms a return.
        guard dependencies.applicationIsActive() else { return }
        // Before any permission check: the person is looking at the app.
        dependencies.withdrawNudges()
        let now = dependencies.now()
        if let window {
            let identifier = closeWindow()
            resolveOnReturn(
                sessionID: window.sessionID,
                watchedLeftAt: window.leftAt,
                key: window.key,
                at: now
            )
            endBackgroundTask(identifier)
        } else if let key = dependencies.persistenceKey(),
                  let sessionID = dependencies.loadEnvelope(key)?.leaveExcursion?.sessionID {
            // An absence from a process that no longer watches it (a
            // relaunch after the process was stopped in the background).
            resolveOnReturn(sessionID: sessionID, watchedLeftAt: nil, key: key, at: now)
        }
    }

    private func resolveOnReturn(
        sessionID: UUID,
        watchedLeftAt: Date?,
        key: String,
        at now: Date
    ) {
        guard let envelope = dependencies.loadEnvelope(key),
              envelope.engine.currentSessionID == sessionID else { return }
        if let excursion = envelope.leaveExcursion {
            switch FocusLeavePolicy.outcomeOnReturn(leftAt: excursion.leftAt, now: now) {
            case .quickGlance:
                dependencies.replaceEnvelope(
                    FocusLeaveTransition.removingExcursion(envelope),
                    key
                )
            case .left:
                updateLiveActivity(
                    applyLeft(
                        sessionID: sessionID,
                        leftAt: excursion.leftAt,
                        key: key,
                        decidedAt: now
                    ),
                    thenEnd: .invalid
                )
            }
        } else if let watchedLeftAt,
                  let marker = envelope.currentLeavePause,
                  marker.sessionID == sessionID,
                  marker.pausedAt == watchedLeftAt {
            // This process watched the absence, but a reader (a relaunch
            // path, the focus screen) applied it first; the side effects
            // still belong to it and are all idempotent.
            updateLiveActivity(
                applyLeft(
                    sessionID: sessionID,
                    leftAt: marker.pausedAt,
                    key: key,
                    decidedAt: now
                ),
                thenEnd: .invalid
            )
        }
    }

    // MARK: - Window plumbing

    private func isCurrent(_ generation: UInt64) -> Bool {
        !Task.isCancelled && generation == self.generation
    }

    /// Ends the window and hands its background task to the caller, which
    /// ends it once any work it still needs the time for is done.
    private func closeWindow() -> UIBackgroundTaskIdentifier {
        generation &+= 1
        window = nil
        task?.cancel()
        task = nil
        if let lockObserver {
            dependencies.notificationCenter.removeObserver(lockObserver)
            self.lockObserver = nil
        }
        let identifier = backgroundTask
        backgroundTask = .invalid
        return identifier
    }

    private func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        guard identifier != .invalid else { return }
        dependencies.endBackgroundTask(identifier)
    }
}
