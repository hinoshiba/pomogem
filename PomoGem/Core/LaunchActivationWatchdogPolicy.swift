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
