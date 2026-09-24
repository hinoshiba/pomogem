import SwiftUI

/// quality-01 / launch-01. What the launch host may say about a timer while no
/// iCloud session is mounted: after a lock that outlasted the background grace
/// window, while waiting for a connection, or while a slow check runs.
///
/// Before this, every one of those screens hid a running or finished focus
/// completely, so locking the phone during a pomodoro and coming back offline
/// looked like the timer was gone. The status is account-neutral on purpose:
/// a time and a phase, nothing else — no theme, memo, mass or record — which
/// is exactly what the Live Activity already shows on the lock screen. It is
/// read without writing anything (`FocusPersistence.peekTimerEnvelopes`), and
/// it grants nothing: the timer itself is still recovered, recorded and
/// dropped into the jar only by the verified session that mounts afterwards.
enum LaunchTimerStatus: Equatable, Sendable {
    case focusRunning(endDate: Date)
    case focusPaused(remainingSeconds: Int)
    /// The focus reached its end (or its completion is waiting to be saved).
    case focusFinished
    case breakRunning(endDate: Date)

    static func resolve(
        focus: FocusRecoveryEnvelope?,
        rest: BreakRecoveryEnvelope?,
        now: Date
    ) -> Self? {
        if let focus {
            if focus.pendingCompletion != nil { return .focusFinished }
            let engine = focus.engine
            if engine.hasValidRunningFocusPayloadState, let endDate = engine.endDate {
                return endDate > now ? .focusRunning(endDate: endDate) : .focusFinished
            }
            if engine.hasValidPausedFocusPayloadState {
                let remaining = engine.snapshot(at: now).remainingSeconds
                if remaining > 0 { return .focusPaused(remainingSeconds: remaining) }
            }
            if engine.hasValidRecoverableBreakPayloadState, engine.phase.isBreak,
               let endDate = engine.endDate, endDate > now {
                return .breakRunning(endDate: endDate)
            }
        }
        if let rest, rest.endDate > now {
            return .breakRunning(endDate: rest.endDate)
        }
        return nil
    }

    /// The same status a moment later: a focus that reaches its end becomes
    /// finished, and a break that ends is no longer worth a card.
    func advanced(to now: Date) -> Self? {
        switch self {
        case let .focusRunning(endDate):
            endDate > now ? self : .focusFinished
        case let .breakRunning(endDate):
            endDate > now ? self : nil
        case .focusPaused, .focusFinished:
            self
        }
    }

    func remainingSeconds(at now: Date) -> Int? {
        switch self {
        case let .focusRunning(endDate), let .breakRunning(endDate):
            let interval = endDate.timeIntervalSince(now)
            guard interval.isFinite, interval > 0 else { return 0 }
            return Int(min(interval.rounded(.up), Double(PomodoroEngine.maximumSupportedRemainingSeconds)))
        case let .focusPaused(remainingSeconds):
            return max(0, remainingSeconds)
        case .focusFinished:
            return nil
        }
    }
}

/// Which launch screens carry the card. Only the waiting screens of an iCloud
/// launch: the storage choice, the transfer and deletion screens and the
/// relaunch instructions each have one job, and a timer would distract from
/// it. The host additionally requires the suspended account binding (so an
/// identity verdict, which clears it, also removes the card) and no
/// unresolved account-state movement (so a possible account change never
/// shows the previous account's timer).
enum LaunchTimerStatusPolicy {
    enum Screen: Equatable, Sendable {
        case preparing, offlineWall, verificationTimedOut, other
    }

    static func showsTimerStatus(
        on screen: Screen,
        hasSuspendedAccountBinding: Bool,
        hasUnresolvedAccountStateMovement: Bool,
        transferIsInProgress: Bool,
        requiresRelaunch: Bool
    ) -> Bool {
        guard hasSuspendedAccountBinding, !hasUnresolvedAccountStateMovement,
              !transferIsInProgress, !requiresRelaunch else { return false }
        return screen != .other
    }
}

/// The card itself. It advances once a second on its own, so a focus that
/// ends while the person waits turns into 「集中が終わりました」 without the
/// host doing anything.
struct LaunchTimerStatusCard: View {
    let status: LaunchTimerStatus

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let current = status.advanced(to: context.date) {
                card(current, now: context.date)
            }
        }
    }

    private func card(_ status: LaunchTimerStatus, now: Date) -> some View {
        let remaining = status.remainingSeconds(at: now)
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol(status))
                .font(.title2.weight(.semibold))
                .foregroundStyle(PomoGemTheme.amber)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title(status))
                    .font(.headline)
                    .foregroundStyle(PomoGemTheme.text)
                if let remaining {
                    Text(remainingText(remaining))
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(PomoGemTheme.text)
                }
                if status == .focusFinished {
                    Text("確認が済むと、この集中を瓶に積みます。", tableName: "Launch")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(status, remaining: remaining))
        .accessibilityIdentifier("launch-timer-status")
    }

    private func symbol(_ status: LaunchTimerStatus) -> String {
        switch status {
        case .focusRunning: "timer"
        case .focusPaused: "pause.circle"
        case .focusFinished: "checkmark.circle"
        case .breakRunning: "cup.and.saucer"
        }
    }

    private func title(_ status: LaunchTimerStatus) -> String {
        switch status {
        case .focusRunning:
            String(localized: "集中は続いています", table: "Launch",
                   comment: "Launch waiting screen: a focus timer is still running")
        case .focusPaused:
            String(localized: "集中は一時停止中です", table: "Launch",
                   comment: "Launch waiting screen: a focus timer is paused")
        case .focusFinished:
            String(localized: "集中が終わりました", table: "Launch",
                   comment: "Launch waiting screen: a focus timer reached its end")
        case .breakRunning:
            String(localized: "休憩中です", table: "Launch",
                   comment: "Launch waiting screen: a break timer is running")
        }
    }

    private func clock(_ seconds: Int) -> String {
        let duration = Duration.seconds(seconds)
        return seconds >= 3_600
            ? duration.formatted(.time(pattern: .hourMinuteSecond))
            : duration.formatted(.time(pattern: .minuteSecond))
    }

    private func remainingText(_ seconds: Int) -> String {
        String(localized: "残り \(clock(seconds))", table: "Launch",
               comment: "Launch waiting screen: remaining time of the timer, e.g. 残り 12:34")
    }

    private func accessibilityLabel(_ status: LaunchTimerStatus, remaining: Int?) -> String {
        guard let remaining else {
            return String(localized: "集中が終わりました。確認が済むと、この集中を瓶に積みます。", table: "Launch",
                          comment: "VoiceOver: the focus timer ended while the app waits for iCloud")
        }
        let minutes = remaining / 60
        let seconds = remaining % 60
        switch status {
        case .focusPaused:
            return String(localized: "集中は一時停止中です。残り\(minutes)分\(seconds)秒", table: "Launch",
                          comment: "VoiceOver: paused focus with remaining minutes and seconds")
        case .breakRunning:
            return String(localized: "休憩中です。残り\(minutes)分\(seconds)秒", table: "Launch",
                          comment: "VoiceOver: running break with remaining minutes and seconds")
        case .focusRunning, .focusFinished:
            return String(localized: "集中は続いています。残り\(minutes)分\(seconds)秒", table: "Launch",
                          comment: "VoiceOver: running focus with remaining minutes and seconds")
        }
    }
}
