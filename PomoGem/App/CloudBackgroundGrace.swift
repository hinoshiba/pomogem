import OSLog
import SwiftUI
import UIKit

/// quality-01 / launch-01. The short background grace window of an iCloud
/// session (owner-approved rule change, 2026-09-24; amends
/// Docs/SyncMaintenanceArchitecture.md §3.2 and Docs/OfflineCloudMode.md).
///
/// The documented fence is about SUSPENSION, not about backgrounding: a
/// CloudKit-mirrored store must never stay mounted while this process can be
/// suspended, because an Apple Account can change before a suspended process
/// receives `.CKAccountChanged`. Until now the host honoured that by tearing
/// the whole app down on every `.background`, without even holding a
/// background task, so every screen lock during a pomodoro destroyed Root, its
/// sheets and the jar, and the process could still be suspended half-way
/// through the teardown.
///
/// Instead, `.background` now begins a `UIApplication` background task and
/// schedules the same retirement a short grace later. While that task is held
/// the process is running, not suspended, so account notifications are still
/// delivered and the fence holds. The session retires immediately — never
/// after the grace — when:
/// - iOS grants no background task, or too little time to retire safely;
/// - the task's expiration handler fires;
/// - `.CKAccountChanged`, a storage transfer or complete deletion retires it
///   through any other path (`sessionRetiredElsewhere`).
/// The task is ended only after every retired container has been released, so
/// the retirement always completes before iOS may suspend the process. If the
/// scene becomes active again first, the hold is cancelled and the same Root,
/// sheets and jar stay on screen.
enum CloudBackgroundGracePolicy {
    /// About as long as a glance at another app, a notification, Control
    /// Center plus a lock, or a round trip to iOS Settings.
    static let graceInterval: TimeInterval = 15
    /// Time left for the retirement itself (the bounded 2 s container release
    /// plus scheduling) before the system would end the background task.
    static let suspensionMargin: TimeInterval = 5
    /// Below this, holding the session is not worth a second retirement path.
    static let minimumGrace: TimeInterval = 1
    /// `backgroundTimeRemaining` reports `greatestFiniteMagnitude` when iOS is
    /// not counting background time at all; any value this large means "not
    /// bounded yet", never "thousands of seconds granted".
    static let unboundedBackgroundTimeThreshold: TimeInterval = 600
    /// How long a retirement may take to release its containers before the
    /// background task is ended anyway. The expiration handler still retires
    /// synchronously if iOS runs out of time first.
    static let releaseWaitLimit: TimeInterval = 10
    static let releasePollInterval: TimeInterval = 0.025

    enum Start: Equatable, Sendable {
        case retireNow
        case retireAfter(TimeInterval)
    }

    /// When a `.background` hold must retire the session.
    static func start(backgroundTaskGranted: Bool, backgroundTimeRemaining: TimeInterval) -> Start {
        guard backgroundTaskGranted, !backgroundTimeRemaining.isNaN else { return .retireNow }
        guard backgroundTimeRemaining < unboundedBackgroundTimeThreshold else {
            // Not counted yet. The expiration handler still retires the
            // session synchronously if iOS later grants less than this.
            return .retireAfter(graceInterval)
        }
        let budget = backgroundTimeRemaining - suspensionMargin
        guard budget >= minimumGrace else { return .retireNow }
        return .retireAfter(min(graceInterval, budget))
    }

    /// What the elapsed grace does. The session retires only while the scene
    /// is still in the background: a scene that came back to the foreground
    /// (even one that is only inactive, behind Notification Center) is not
    /// about to be suspended, and its next `.background` starts a new hold.
    static func retiresWhenGraceElapses(sceneIsInBackground: Bool) -> Bool {
        sceneIsInBackground
    }

    enum RecheckReaction: Equatable, Sendable {
        case keepSession, quiesce
    }

    /// The identity check a retained session gets when the person comes back
    /// within the grace. The process was never suspended, so an account change
    /// would normally have arrived as `.CKAccountChanged`; this is the second,
    /// independent look Apple's delivery guarantees leave room for. Only an
    /// identity verdict closes the session. Transport failures keep it, exactly
    /// like a normal iCloud screen that loses its connection
    /// (Docs/OfflineCloudMode.md, 「通常のiCloud画面を使っている最中に通信が切れた」).
    static func retainedSessionRecheckReaction(after error: Error) -> RecheckReaction {
        if error is CancellationError { return .keepSession }
        if case AppleAccountBoundaryResolutionError.blocked = error { return .quiesce }
        return CloudOfflineHostPolicy.revocationReason(for: error) == nil ? .keepSession : .quiesce
    }
}

/// Owns the background task and the grace timer. The host supplies what to
/// retire and how to tell that the retired containers are gone; everything
/// else — when to retire, when the task may end — is decided here, so the
/// ordering can be tested with the real type rather than a model of it.
@MainActor
final class CloudBackgroundGraceController {
    struct Environment {
        var beginBackgroundTask: @MainActor (_ name: String, _ expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
        var endBackgroundTask: @MainActor (UIBackgroundTaskIdentifier) -> Void
        var backgroundTimeRemaining: @MainActor () -> TimeInterval
        var sleep: @Sendable (TimeInterval) async throws -> Void

        static var live: Self {
            Self(beginBackgroundTask: { name, expiration in
                UIApplication.shared.beginBackgroundTask(withName: name) {
                    // UIKit calls the handler on the main thread.
                    MainActor.assumeIsolated { expiration() }
                }
            }, endBackgroundTask: { identifier in
                UIApplication.shared.endBackgroundTask(identifier)
            }, backgroundTimeRemaining: {
                UIApplication.shared.backgroundTimeRemaining
            }, sleep: { seconds in
                try await Task.sleep(for: .seconds(seconds))
            })
        }
    }

    private struct Hold {
        let sessionID: UUID
        let retire: @MainActor () -> Void
    }

    private static let logger = Logger(subsystem: "com.hinoshiba.pomogem", category: "PersistenceLaunch")

    private let environment: Environment
    private var generation: UInt64 = 0
    private var taskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var hold: Hold?
    private var graceTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var isReleased: @MainActor () -> Bool = { true }
    private var isSceneInBackground: @MainActor () -> Bool = { true }

    init(environment: Environment = .live) {
        self.environment = environment
    }

    /// A session is being held open by an unexpired grace.
    var isHoldingSession: Bool { hold != nil }
    /// The background task is still held (grace, or a release in progress).
    var holdsBackgroundTask: Bool { taskIdentifier != .invalid }

    /// `.background` with a published, verified online session. Returns false
    /// when the session was retired immediately instead of being held.
    @discardableResult
    func begin(
        sessionID: UUID,
        retire: @escaping @MainActor () -> Void,
        isReleased: @escaping @MainActor () -> Bool,
        isSceneInBackground: @escaping @MainActor () -> Bool
    ) -> Bool {
        if let hold, hold.sessionID == sessionID { return true }
        cancelPendingWork()
        generation &+= 1
        let generation = generation
        self.isReleased = isReleased
        self.isSceneInBackground = isSceneInBackground
        taskIdentifier = environment.beginBackgroundTask("Retire iCloud session") { [weak self] in
            self?.expire(generation: generation)
        }
        switch CloudBackgroundGracePolicy.start(
            backgroundTaskGranted: taskIdentifier != .invalid,
            backgroundTimeRemaining: environment.backgroundTimeRemaining()
        ) {
        case .retireNow:
            retire()
            waitForReleaseThenEndTask(generation: generation)
            return false
        case let .retireAfter(delay):
            hold = Hold(sessionID: sessionID, retire: retire)
            let sleep = environment.sleep
            graceTask = Task { @MainActor [weak self] in
                do { try await sleep(delay) } catch { return }
                self?.graceElapsed(generation: generation)
            }
            return true
        }
    }

    /// `.active`. Returns true when a held session was kept on screen.
    @discardableResult
    func sceneBecameActive() -> Bool {
        guard hold != nil else { return false }
        hold = nil
        generation &+= 1
        graceTask?.cancel()
        graceTask = nil
        endTask()
        return true
    }

    /// Any other path retired the session (`.CKAccountChanged`, a storage
    /// transfer, complete deletion). The grace ends at once; the background
    /// task stays until that retirement has released its containers.
    func sessionRetiredElsewhere() {
        guard hold != nil else { return }
        hold = nil
        graceTask?.cancel()
        graceTask = nil
        waitForReleaseThenEndTask(generation: generation)
    }

    private func graceElapsed(generation: UInt64) {
        guard generation == self.generation, let hold else { return }
        self.hold = nil
        graceTask = nil
        guard CloudBackgroundGracePolicy.retiresWhenGraceElapses(sceneIsInBackground: isSceneInBackground()) else {
            endTask()
            return
        }
        hold.retire()
        waitForReleaseThenEndTask(generation: generation)
    }

    /// iOS is about to end the task. Retire synchronously — `session = nil`
    /// happens inside `retire` — and end the task, as the handler must.
    private func expire(generation: UInt64) {
        guard generation == self.generation else { return }
        graceTask?.cancel()
        graceTask = nil
        releaseTask?.cancel()
        releaseTask = nil
        if let hold {
            self.hold = nil
            hold.retire()
        }
        if !isReleased() {
            Self.logger.fault("Background time expired before the retired iCloud containers were released")
        }
        endTask()
    }

    private func waitForReleaseThenEndTask(generation: UInt64) {
        releaseTask?.cancel()
        let sleep = environment.sleep
        let polls = Int((CloudBackgroundGracePolicy.releaseWaitLimit
            / CloudBackgroundGracePolicy.releasePollInterval).rounded(.up))
        releaseTask = Task { @MainActor [weak self] in
            for _ in 0..<polls {
                guard let self, generation == self.generation else { return }
                if self.isReleased() { break }
                do { try await sleep(CloudBackgroundGracePolicy.releasePollInterval) } catch { return }
            }
            guard let self, generation == self.generation else { return }
            if !self.isReleased() {
                Self.logger.fault("Retired iCloud containers were not released within the background wait")
            }
            self.releaseTask = nil
            self.endTask()
        }
    }

    private func cancelPendingWork() {
        hold = nil
        graceTask?.cancel()
        graceTask = nil
        releaseTask?.cancel()
        releaseTask = nil
        endTask()
    }

    private func endTask() {
        let identifier = taskIdentifier
        taskIdentifier = .invalid
        if identifier != .invalid {
            environment.endBackgroundTask(identifier)
        }
    }
}
