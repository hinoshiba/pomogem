import Foundation
import OSLog
import SwiftUI
import UIKit

/// Owns the few seconds after a running focus goes to the background: it books
/// the return reminder, then listens for the notice that tells locking the
/// phone apart from going to the Home Screen or another app.
///
/// Both arrive as `.background`, but only leaving is the drift this opt-in
/// reminder exists for; locking the phone to study is what the app wants. iOS
/// tells a passcode-protected phone's app that protected data is going away
/// about 10 seconds after a lock, so a notice inside the window withdraws the
/// reminder. Every edge is injectable so the window's races can be tested
/// without a device, a lock or Notification Center.
@MainActor
final class FocusReturnReminderLockWindow {
    struct Dependencies {
        /// Books the registered reminder. True only when Notification Center
        /// accepted it; a superseded or failed add books nothing.
        var schedule: @MainActor () async -> Bool
        var withdraw: @MainActor () -> Void
        var protectedDataIsAvailable: @MainActor () -> Bool
        /// Returns early when the waiting task is cancelled.
        var sleep: @MainActor (TimeInterval) async -> Void
        var beginBackgroundTask: @MainActor (
            _ expiration: @escaping @MainActor () -> Void
        ) -> UIBackgroundTaskIdentifier
        var endBackgroundTask: @MainActor (UIBackgroundTaskIdentifier) -> Void
        var notificationCenter: NotificationCenter

        static var live: Self {
            Self(
                schedule: {
                    guard case .accepted = try? await NotificationManager.shared
                        .scheduleRegisteredFocusReturnReminder()
                    else { return false }
                    return true
                },
                withdraw: { NotificationManager.shared.cancelFocusReturnReminder() },
                protectedDataIsAvailable: { UIApplication.shared.isProtectedDataAvailable },
                sleep: { try? await Task.sleep(for: .seconds($0)) },
                beginBackgroundTask: { expiration in
                    UIApplication.shared.beginBackgroundTask(
                        withName: "Schedule focus return reminder"
                    ) {
                        MainActor.assumeIsolated { expiration() }
                    }
                },
                endBackgroundTask: { UIApplication.shared.endBackgroundTask($0) },
                notificationCenter: .default
            )
        }
    }

    private static let logger = Logger(
        subsystem: "com.hinoshiba.pomogem",
        category: "FocusReturnReminder"
    )

    private let dependencies: Dependencies
    /// Bumped whenever a window closes. Every callback carries the value it
    /// was created with, so nothing left over from an earlier absence (a
    /// queued notice, a late add, a sleeping deadline, an expiry) can
    /// withdraw a newer reminder or end a newer window's background task.
    private var generation: UInt64 = 0
    private var acceptedGeneration: UInt64?
    private var task: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lockObserver: NSObjectProtocol?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Call for every scene phase. Any phase withdraws the previous absence's
    /// reminder; only `.background` opens a new window. Never reserve for a
    /// permission sheet or Control Center's temporary inactive state.
    func handle(_ phase: ScenePhase) {
        cancel()
        guard phase == .background else { return }
        open()
    }

    /// Closes any window and withdraws its reminder.
    func cancel() {
        closeWindow()
        dependencies.withdraw()
    }

    private func open() {
        let generation = self.generation
        // Keep execution for the short Notification Center add and the lock
        // window, not for the 30-second grace; the OS owns the delivery timer.
        backgroundTask = dependencies.beginBackgroundTask { [weak self] in
            self?.backgroundTimeExpired(generation)
        }
        // Observe from the start: a lock during a slow add must also win.
        lockObserver = dependencies.notificationCenter.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deviceWillLock(generation) }
        }
        task = Task { [weak self] in
            await self?.run(generation)
        }
    }

    private func run(_ generation: UInt64) async {
        defer {
            if generation == self.generation { endBackgroundTask() }
        }
        guard isCurrent(generation) else { return }
        let accepted = await dependencies.schedule()
        guard accepted, isCurrent(generation) else { return }
        acceptedGeneration = generation
        // Wait for a lock notice without cancelling at the deadline: going to
        // the Home Screen or another app, or a phone without a passcode,
        // never gets one.
        await dependencies.sleep(FocusReturnReminderPolicy.lockDetectionWindow)
        guard isCurrent(generation) else { return }
        if FocusReturnReminderPolicy.shouldWithdrawAtLockWindowEnd(
            protectedDataIsAvailable: dependencies.protectedDataIsAvailable()
        ) {
            dependencies.withdraw()
        }
    }

    private func deviceWillLock(_ generation: UInt64) {
        guard generation == self.generation else { return }
        Self.logger.info("Focus return reminder withdrawn: the device locked while backgrounded")
        cancel()
    }

    private func backgroundTimeExpired(_ generation: UInt64) {
        // A later phase already ended this window's background task.
        guard generation == self.generation else { return }
        let addWasAccepted = acceptedGeneration == generation
        closeWindow()
        if FocusReturnReminderPolicy.shouldWithdrawOnBackgroundExpiry(
            addWasAccepted: addWasAccepted
        ) {
            dependencies.withdraw()
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        !Task.isCancelled && generation == self.generation
    }

    private func closeWindow() {
        generation &+= 1
        task?.cancel()
        task = nil
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        if let lockObserver {
            dependencies.notificationCenter.removeObserver(lockObserver)
            self.lockObserver = nil
        }
        let identifier = backgroundTask
        backgroundTask = .invalid
        if identifier != .invalid {
            dependencies.endBackgroundTask(identifier)
        }
    }
}
