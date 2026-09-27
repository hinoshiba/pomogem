import Foundation

/// Decides what Home does with a focus start asked for from outside the app
/// (a widget, a `pomogem://` link, Siri or a Shortcut).
///
/// The request may start a focus only where Home's own start button could:
/// never over a running or recovering timer (no second session), never while
/// the reward card still waits for the rest choice, and never without a theme.
/// Root has already brought the jar forward. Home closes only its read-only
/// sheets for the request: a form the person may be typing in, a stratum
/// celebration and a break whose time is up all stay theirs to close, and the
/// request waits for them.
enum FocusStartEntryPolicy {
    struct Snapshot: Equatable {
        let requestID: UUID
        let isFresh: Bool
        let homeIsVisible: Bool
        /// A focus, or a break still counting down, is on screen, or Root is
        /// presenting a recovered focus.
        let timerIsPresented: Bool
        /// A break whose time is up is on screen. Its one action,
        /// 「瓶へ戻る」, leads back to the jar, so the request waits for it
        /// instead of being lost behind a screen that has nothing left to time.
        let endedBreakIsPresented: Bool
        /// A completion waiting for 「再試行」, or another iPhone's running
        /// timer offered for adoption.
        let focusRecoveryIsPending: Bool
        /// The reward card, or its delayed appearance, waits for the rest
        /// choice.
        let rewardChoiceIsPending: Bool
        /// The rest choice is made but its gem has not landed yet (or a
        /// receipt is still being put back on screen). Home decides again
        /// when it lands: a chosen rest then opens, and 「閉じる」 leaves Home
        /// free.
        let rewardDropIsInProgress: Bool
        /// Root's paywall or share sheet. Root closes both when it takes the
        /// request, so one seen here was opened afterwards by the person (for
        /// example from the celebration's month-label link).
        let otherSurfaceIsPresented: Bool
        /// Manual entry, the achievement memo or the custom length: forms that
        /// may hold what the person has typed. Never closed for them.
        let entryFormIsPresented: Bool
        /// Menu, overview, detail or plan sheets: read-only, so closing them
        /// loses nothing. An iCloud session drops them on every return from
        /// the background anyway.
        let closableSurfaceIsPresented: Bool
        /// The fusion celebration sheet. It is never closed for the person:
        /// closing it marks it seen and may present the next one. Only
        /// 「続ける」 (or a swipe down) lets the waiting request start; its
        /// other actions drop the request (HomeView).
        let celebrationIsPresented: Bool
        let hasTheme: Bool
        /// Whether the length the start would use is final. A request without
        /// a preset uses Home's selected length, which is only a free
        /// placeholder until StoreKit has said whether a saved Pro length
        /// may be restored (`PurchaseManager.hasResolvedEntitlements`).
        let lengthIsSettled: Bool
    }

    enum DeclineReason: Equatable {
        case expired
        case timerOnScreen
        case focusRecoveryPending
        case rewardChoicePending
        case otherSurfaceChosen
        case noTheme
    }

    enum Decision: Equatable {
        /// Keep the request and decide again when Home changes.
        case wait
        /// Close the read-only sheets, then decide again.
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
        // The person went somewhere else after the request was taken.
        // Starting a focus over their choice, or when they close it, would
        // not be what they asked for.
        if snapshot.otherSurfaceIsPresented {
            return .decline(.otherSurfaceChosen)
        }
        if snapshot.endedBreakIsPresented { return .wait }
        guard snapshot.homeIsVisible else { return .wait }
        if snapshot.rewardChoiceIsPending {
            return .decline(.rewardChoicePending)
        }
        if snapshot.rewardDropIsInProgress { return .wait }
        if snapshot.celebrationIsPresented { return .wait }
        if snapshot.entryFormIsPresented { return .wait }
        if snapshot.closableSurfaceIsPresented { return .closeSurfaces }
        guard snapshot.hasTheme else { return .decline(.noTheme) }
        guard snapshot.lengthIsSettled else { return .wait }
        return .start
    }

    /// What Home says when it does not start. nil stays silent: an expired
    /// request is simply dropped, a timer on screen already answers, and a
    /// surface the person opened is their own answer.
    static func message(for reason: DeclineReason) -> String? {
        switch reason {
        case .expired, .timerOnScreen, .otherSurfaceChosen:
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
