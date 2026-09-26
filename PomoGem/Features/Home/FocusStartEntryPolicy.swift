import Foundation

/// Decides what Home does with a focus start asked for from outside the app
/// (a widget, a `pomogem://` link, Siri or a Shortcut).
///
/// The request may start a focus only where Home's own start button could:
/// never over a running or recovering timer (no second session), never while
/// the reward card still waits for the rest choice, and never without a theme.
/// Root has already brought the jar forward; Home's own sheets are closed
/// first, except a stratum celebration, which the person closes themselves.
enum FocusStartEntryPolicy {
    struct Snapshot: Equatable {
        let requestID: UUID
        let isFresh: Bool
        let homeIsVisible: Bool
        /// A focus or break is on screen, or Root is presenting a recovered one.
        let timerIsPresented: Bool
        /// A completion waiting for 「再試行」, or another iPhone's running
        /// timer offered for adoption.
        let focusRecoveryIsPending: Bool
        /// The reward card, its delayed appearance, or an unlanded gem.
        let rewardChoiceIsPending: Bool
        /// Menu, overview, detail, manual entry, achievement, custom length
        /// or plan sheets: all closable without losing a saved record. An
        /// iCloud session drops them on every return from the background
        /// anyway, so closing them here matches what most people already see.
        let closableSurfaceIsPresented: Bool
        /// The fusion celebration sheet. It is never closed for the person:
        /// closing it marks it seen and may present the next one.
        let celebrationIsPresented: Bool
        let hasTheme: Bool
    }

    enum DeclineReason: Equatable {
        case expired
        case timerOnScreen
        case focusRecoveryPending
        case rewardChoicePending
        case noTheme
    }

    enum Decision: Equatable {
        /// Keep the request and decide again when Home changes.
        case wait
        /// Close the closable sheets, then decide again.
        case closeSurfaces
        case decline(DeclineReason)
        /// Start after a short settle (HomeView), deciding once more first:
        /// a sheet or page may still be animating away, and SwiftUI can drop
        /// a cover presented during that animation.
        case start
    }

    static func decide(_ snapshot: Snapshot) -> Decision {
        guard snapshot.isFresh else { return .decline(.expired) }
        // The running or recovered timer is already the screen this request
        // leads to. Starting another would be a second session.
        if snapshot.timerIsPresented { return .decline(.timerOnScreen) }
        if snapshot.focusRecoveryIsPending {
            return .decline(.focusRecoveryPending)
        }
        guard snapshot.homeIsVisible else { return .wait }
        if snapshot.rewardChoiceIsPending {
            return .decline(.rewardChoicePending)
        }
        if snapshot.celebrationIsPresented { return .wait }
        if snapshot.closableSurfaceIsPresented { return .closeSurfaces }
        guard snapshot.hasTheme else { return .decline(.noTheme) }
        return .start
    }

    /// What Home says when it does not start. nil stays silent: an expired
    /// request is simply dropped, and a timer on screen already answers.
    static func message(for reason: DeclineReason) -> String? {
        switch reason {
        case .expired, .timerOnScreen:
            return nil
        case .focusRecoveryPending:
            return String(
                localized: "進行中の集中があるため、新しい集中は始めませんでした",
                table: "Home",
                comment: "Toast: a widget, link or Siri asked to start a focus while another one still needs attention"
            )
        case .rewardChoicePending:
            return String(
                localized: "休憩の選択を終えると、集中を始められます",
                table: "Home",
                comment: "Toast: a widget, link or Siri asked to start a focus while the reward card waits for the rest choice"
            )
        case .noTheme:
            return String(
                localized: "テーマを選ぶと、集中を始められます",
                table: "Home",
                comment: "Toast: a widget, link or Siri asked to start a focus before any theme exists"
            )
        }
    }
}
