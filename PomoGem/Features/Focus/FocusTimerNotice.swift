import Foundation

/// The single line under the focus timer (FocusView's `timerNotice`, one
/// 44 pt row so the ring never moves). Several features want it; exactly one
/// line shows, in this order:
///
/// 1. `leavePause`: F1's 「アプリを離れていたので一時停止しました」. It
///    explains a pause the person did not tap, and 再開 continues from the
///    moment they left.
/// 2. `endAlertFailure`: 「通知を予約できませんでした。もう一度試す」. The end
///    will not be announced unless they retry, and it is new.
/// 3. `shield`: F2's 「気が散るアプリを制限中」 while this iPhone's shield is
///    up, running or paused (a pause keeps the shield). The person opted in,
///    and it is what they meet when a shielded app will not open.
/// 4. `endAlert`: the end-alert row as before: the running promise (a
///    notification or an alarm), the paused note, the spinner, and the
///    permission and Settings buttons. Those buttons stay reachable whenever
///    no shield is up, and from Settings.
enum FocusTimerNoticeLine: Equatable, Sendable {
    case none
    case leavePause
    case endAlertFailure
    case shield
    case endAlert

    static func resolve(
        timerIsRunningOrPaused: Bool,
        showsLeavePause: Bool,
        endAlertFailed: Bool,
        isShielding: Bool
    ) -> FocusTimerNoticeLine {
        guard timerIsRunningOrPaused else { return .none }
        if showsLeavePause { return .leavePause }
        if endAlertFailed { return .endAlertFailure }
        if isShielding { return .shield }
        return .endAlert
    }
}

extension FocusShieldController {
    /// The shield the focus screen's notice line follows: the one this
    /// iPhone's Screen Time owner writes. A Simulator can never bind that
    /// owner (no App Group), so a UI test that opts in follows the fixture's
    /// shield instead (`FocusScreenShieldUITestFixture`).
    @MainActor
    static var focusScreen: FocusShieldController {
#if DEBUG && targetEnvironment(simulator)
        if let fixture = FocusScreenShieldUITestFixture.controller {
            return fixture
        }
#endif
        return ScreenTimeController.shared.focusShield
    }
}
