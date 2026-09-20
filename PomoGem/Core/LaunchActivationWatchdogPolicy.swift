import Foundation
import SwiftUI
import UIKit

/// A launch that is not yet activated defers instead of reporting an account
/// failure. iOS can own the foreground indefinitely with a modal of its own —
/// an Apple Account sign-in alert keeps the app `.inactive` for as long as it
/// stays up — so neither `scenePhase` nor `didBecomeActiveNotification` ever
/// reports activation, and nothing is armed to end that wait: the account
/// deadline is armed far later, after the deferred attempt has already
/// returned. Bound the wait with the same absolute launch budget and end in
/// the ordinary retry screen instead of an endless preparation spinner.
///
/// The budget covers the wait for activation only. Storage-transfer recovery
/// keeps running without a launch deadline: it is progressing work with its
/// own relaunch contract, and interrupting it would change transfer semantics.
/// Expiry is a lifecycle observation, never an account or storage result.
enum LaunchActivationWatchdogPolicy {
    enum WaitOutcome: Equatable, Sendable {
        /// On screen without activation. Bound the wait; the user is looking
        /// at the preparation spinner and can act once the retry screen shows.
        case bounded(timeout: TimeInterval)
        /// Activated, or suspended by the OS. Nothing to bound: an activated
        /// launch owns itself, and a suspended process must not be blamed for
        /// a wait nobody could see.
        case unbounded
    }

    /// Claims no account result and reports no change to the stored records or
    /// the selected storage mode, because expiry proves neither.
    static let blockedMessage = """
        起動を続けられませんでした。iPhoneの画面にiOSの確認（Apple Accountのサインインなど）が出ている場合は、\
        先にそれを完了するか閉じてから「もう一度試す」を押してください。記録や保存先の設定は変更していません。
        """

    static func waitOutcome(
        phase: ScenePhase,
        applicationState: UIApplication.State,
        timeout: TimeInterval
    ) -> WaitOutcome {
        guard timeout.isFinite, timeout > 0 else { return .unbounded }
        guard phase != .background, applicationState != .background else { return .unbounded }
        guard phase != .active || applicationState != .active else { return .unbounded }
        return .bounded(timeout: timeout)
    }

    /// Only a still-deferred, still-unpublished launch of the same generation
    /// may present the retry screen, and only while the app is still on screen
    /// without activation. A published session, a superseded generation, a
    /// running preparation, account quiescence and a pending storage-transfer
    /// relaunch all own the screen instead.
    static func presentsRetryScreen(
        generationMatches: Bool,
        hasSession: Bool,
        isWaitingForActivation: Bool,
        isPreparing: Bool,
        isQuiescingAccountChange: Bool,
        requiresStorageTransferRelaunch: Bool,
        phase: ScenePhase,
        applicationState: UIApplication.State
    ) -> Bool {
        guard generationMatches, !hasSession, isWaitingForActivation, !isPreparing,
              !isQuiescingAccountChange, !requiresStorageTransferRelaunch else { return false }
        guard phase != .background, applicationState != .background else { return false }
        return phase != .active || applicationState != .active
    }
}

/// The host wiring for that wait, kept out of the SwiftUI view so the arm /
/// disarm / expiry order is ordinary product code the tests drive directly.
/// `LaunchActivationWatchdogPolicy` stays the pure decision table; this type
/// owns the single budget and the sequence the host applies it in.
@MainActor
final class LaunchActivationWatchdog {
    /// Everything the decisions read, sampled by the host at the call site.
    /// `generation` is the launch attempt the host is currently running.
    struct Frame: Equatable, Sendable {
        var generation: Int
        var hasSession: Bool
        var isWaitingForActivation: Bool
        var isPreparing: Bool
        var isQuiescingAccountChange: Bool
        var requiresStorageTransferRelaunch: Bool
        var phase: ScenePhase
        var applicationState: UIApplication.State

        init(
            generation: Int,
            hasSession: Bool,
            isWaitingForActivation: Bool,
            isPreparing: Bool,
            isQuiescingAccountChange: Bool,
            requiresStorageTransferRelaunch: Bool,
            phase: ScenePhase,
            applicationState: UIApplication.State
        ) {
            self.generation = generation
            self.hasSession = hasSession
            self.isWaitingForActivation = isWaitingForActivation
            self.isPreparing = isPreparing
            self.isQuiescingAccountChange = isQuiescingAccountChange
            self.requiresStorageTransferRelaunch = requiresStorageTransferRelaunch
            self.phase = phase
            self.applicationState = applicationState
        }
    }

    typealias Expiry = @MainActor (Int) -> Void
    typealias DeadlineFactory =
        @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> CloudLaunchDeadline

    private let makeDeadline: DeadlineFactory
    private var deadline: CloudLaunchDeadline?
    private(set) var armedGeneration: Int?
    private(set) var armedTimeout: TimeInterval?

    init(makeDeadline: @escaping DeadlineFactory = { timeout, expire in
        CloudLaunchDeadline(timeout: timeout, invalidateAttempt: {}, onExpiry: expire)
    }) {
        self.makeDeadline = makeDeadline
    }

    var isArmed: Bool { deadline != nil }

    /// Identity of the running budget. One wait keeps one absolute budget, so
    /// a test can prove a transition did not silently restart it.
    var armedDeadline: CloudLaunchDeadline? { deadline }

    /// The generic cancellation catch: this attempt deferred and returned, so
    /// its wait starts now. Any earlier budget belonged to an earlier wait.
    @discardableResult
    func armForDeferredAttempt(
        frame: Frame,
        timeout: @autoclosure () -> TimeInterval,
        expire: @escaping Expiry
    ) -> Bool {
        cancel()
        return arm(frame: frame, timeout: timeout(), expire: expire)
    }

    /// Returning from the background behind the same system modal never
    /// reaches `.active`, so a foreground-inactive transition is the only
    /// chance to re-arm a disarmed wait. A running budget is never restarted,
    /// and a launch something else already owns is never bounded.
    @discardableResult
    func armIfStillDeferred(
        frame: Frame,
        timeout: @autoclosure () -> TimeInterval,
        expire: @escaping Expiry
    ) -> Bool {
        guard deadline == nil, frame.isWaitingForActivation, !frame.hasSession,
              !frame.isPreparing, !frame.isQuiescingAccountChange,
              !frame.requiresStorageTransferRelaunch else { return false }
        return arm(frame: frame, timeout: timeout(), expire: expire)
    }

    /// `.background` hands the process to the OS and must not be blamed for a
    /// wait nobody saw. `.active` is disarmed by the host's own activation
    /// handling, which starts a fresh attempt.
    func handleScenePhaseChange(
        _ phase: ScenePhase,
        frame: Frame,
        timeout: @autoclosure () -> TimeInterval,
        expire: @escaping Expiry
    ) {
        if phase == .background {
            cancel()
        } else if phase == .inactive {
            armIfStillDeferred(frame: frame, timeout: timeout(), expire: expire)
        }
    }

    func cancel() {
        deadline?.cancel()
        clearArmedState()
    }

    /// The budget fired. Only a still-deferred, still-unpublished launch of
    /// the same generation may take the screen; everything else already owns
    /// it. The budget is spent either way and is never re-armed here.
    func settleExpiry(generation: Int, frame: Frame) -> Bool {
        clearArmedState()
        return LaunchActivationWatchdogPolicy.presentsRetryScreen(
            generationMatches: frame.generation == generation,
            hasSession: frame.hasSession,
            isWaitingForActivation: frame.isWaitingForActivation,
            isPreparing: frame.isPreparing,
            isQuiescingAccountChange: frame.isQuiescingAccountChange,
            requiresStorageTransferRelaunch: frame.requiresStorageTransferRelaunch,
            phase: frame.phase,
            applicationState: frame.applicationState
        )
    }

    private func arm(frame: Frame, timeout: TimeInterval, expire: @escaping Expiry) -> Bool {
        guard case let .bounded(bounded) = LaunchActivationWatchdogPolicy.waitOutcome(
            phase: frame.phase,
            applicationState: frame.applicationState,
            timeout: timeout
        ) else { return false }
        let generation = frame.generation
        armedGeneration = generation
        armedTimeout = bounded
        deadline = makeDeadline(bounded) { expire(generation) }
        return true
    }

    private func clearArmedState() {
        deadline = nil
        armedGeneration = nil
        armedTimeout = nil
    }
}
