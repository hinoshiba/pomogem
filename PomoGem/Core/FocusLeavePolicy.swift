import Foundation
import os

/// Owner-requested change 2026-09-26 (F1): leaving the app during a running
/// focus pauses the timer, and a short, bounded series of 「集中が切れています」
/// notifications says so. Locking the phone to study is still what the app
/// wants, so only an absence that is not a lock pauses.
///
/// Everything here is pure: the host's `FocusLeaveMonitor` feeds it the
/// observations (scene phase, protected-data notice, clock) and applies the
/// outcome. See `Docs/FocusLeavePause.md`.
enum FocusLeavePolicy {
    // MARK: Device-local preferences

    /// Device-local, like the Live Activity and return-reminder switches: no
    /// account, subject or study record is stored in either setting, and
    /// neither is synced, exported or part of a Prefs stamp.
    static let enabledDefaultsKey = "focus.leave-pause.enabled"
    static let nudgesEnabledDefaultsKey = "focus.leave-pause.nudges.enabled"

    /// Owner-approved (2026-09-26): both switches are on by default. One
    /// constant for both, so the default can change in one place.
    static let enabledByDefault = true

    /// The switch the person set, or the default when they never touched it.
    static func isEnabled(
        defaults: UserDefaults = .standard,
        defaultValue: Bool = enabledByDefault
    ) -> Bool {
        explicitSwitch(enabledDefaultsKey, in: defaults) ?? defaultValue
    }

    /// Someone who opted into the older 集中に戻るお知らせ asked to be told
    /// when they drift, so they keep a nudge even if the default turns off.
    static func nudgesAreEnabled(
        defaults: UserDefaults = .standard,
        defaultValue: Bool = enabledByDefault
    ) -> Bool {
        if let explicit = explicitSwitch(nudgesEnabledDefaultsKey, in: defaults) {
            return explicit
        }
        return defaultValue || FocusReturnReminderPolicy.isEnabled(defaults: defaults)
    }

    /// Whether the series is on because the person chose it: an explicit ON,
    /// or, with no explicit value, the older 集中に戻るお知らせ they opted
    /// into. The product default alone is not a choice, so Settings raises no
    /// permission notice (with its call to action) under a switch nobody
    /// turned on; like every other notification row, the notice belongs to
    /// an intent the person expressed. Always implies `nudgesAreEnabled`.
    static func nudgesWereChosen(defaults: UserDefaults = .standard) -> Bool {
        if let explicit = explicitSwitch(nudgesEnabledDefaultsKey, in: defaults) {
            return explicit
        }
        return FocusReturnReminderPolicy.isEnabled(defaults: defaults)
    }

    /// Any value stored for `key` is an explicit choice. A launch argument
    /// (`-focus.leave-pause.enabled NO`) reaches the argument domain as the
    /// string "NO", which `as? Bool` does not read; `bool(forKey:)` reads
    /// a Bool, a number and the strings YES/NO/true/false/1/0 alike.
    private static func explicitSwitch(_ key: String, in defaults: UserDefaults) -> Bool? {
        defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
    }

    // MARK: Timing

    /// How long the app watches for the lock notice before deciding that the
    /// person left. With a passcode, iOS posts
    /// `protectedDataWillBecomeUnavailable` about 10 seconds after a lock.
    /// It is also the quick-glance grace: coming back within it never pauses.
    static let lockDetectionWindow: TimeInterval = FocusReturnReminderPolicy.lockDetectionWindow

    /// The existing ≤ 60 s cut-off: a focus this close to its end is left to
    /// finish, so the end notification is never traded for a pause.
    static let minimumRemaining: TimeInterval = FocusReturnReminderPolicy.completionQuietWindow

    /// Offsets from leaving, then the series stops. The first is later than
    /// the lock window so a detected lock withdraws the series before any of
    /// it is delivered.
    static let nudgeOffsets: [TimeInterval] = [30, 120, 300, 600, 1200]

    static let nudgeIdentifierPrefix = "pomogem.focus.leave-nudge."
    /// One thread so Notification Center stacks the series.
    static let nudgeThreadIdentifier = "pomogem.focus.leave-nudge"

    static var nudgeIdentifiers: [String] {
        nudgeOffsets.indices.map { nudgeIdentifierPrefix + String($0 + 1) }
    }

    // MARK: Decisions

    /// Whether this `.background` starts an absence that may pause the timer.
    /// Breaks, a manual pause and the last minute are never touched.
    static func shouldBeginExcursion(
        featureEnabled: Bool,
        phase: PomodoroPhase,
        hasPendingCompletion: Bool,
        endDate: Date?,
        now: Date
    ) -> Bool {
        guard featureEnabled, phase == .focusing, !hasPendingCompletion,
              let endDate else { return false }
        let remaining = endDate.timeIntervalSince(now)
        return remaining.isFinite && remaining > minimumRemaining
    }

    enum Classification: Equatable, Sendable {
        /// The phone was locked: studying away from the screen. The timer runs.
        case locked
        /// The person went to the Home Screen or another app.
        case left
    }

    enum WindowSignal: Equatable, Sendable {
        /// `protectedDataWillBecomeUnavailable` arrived inside the window.
        case lockNotice
        /// The window ended; protected data was or was not still available.
        case windowEnded(protectedDataIsAvailable: Bool)
        /// iOS took the background time back before the window ended.
        case backgroundTimeExpired
    }

    /// Without a passcode iOS never reports a lock, so a lock and leaving the
    /// app look the same; both count as leaving (Settings says so).
    static func classify(
        _ signal: WindowSignal,
        deviceHasPasscode: Bool
    ) -> Classification {
        guard deviceHasPasscode else { return .left }
        switch signal {
        case .lockNotice:
            return .locked
        case let .windowEnded(protectedDataIsAvailable):
            return protectedDataIsAvailable ? .left : .locked
        case .backgroundTimeExpired:
            return .left
        }
    }

    enum ReturnOutcome: Equatable, Sendable {
        /// Back within the window: a quick glance never pauses.
        case quickGlance
        /// Away longer than the window without a lock: pause at `leftAt`.
        case left
    }

    /// Decides an absence nobody classified in time, for example because the
    /// process was suspended or relaunched. A clock that moved backwards is
    /// not evidence of an absence.
    static func outcomeOnReturn(leftAt: Date, now: Date) -> ReturnOutcome {
        isStale(leftAt: leftAt, now: now) ? .left : .quickGlance
    }

    /// True once the window has certainly ended. Every path that could finish
    /// an elapsed focus must apply such an absence first.
    static func isStale(leftAt: Date, now: Date) -> Bool {
        let away = now.timeIntervalSince(leftAt)
        return away.isFinite && away > lockDetectionWindow
    }

    /// Whether a confirmed return (UIKit `.active`) settled an absence as a
    /// quick glance, however late a reader looks at it. A return from before
    /// the person left is no evidence about this absence.
    static func returnedWithinWindow(leftAt: Date, returnedAt: Date) -> Bool {
        let away = returnedAt.timeIntervalSince(leftAt)
        return away.isFinite && away >= 0 && away <= lockDetectionWindow
    }

    /// How soon after the app itself opened iOS Settings (the focus screen's
    /// 「終了通知は端末の設定から」) a `.background` counts as that trip.
    /// The person is following the app's own call to action, not leaving the
    /// focus, so the trip starts no absence.
    static let appInitiatedDepartureWindow: TimeInterval = 5

    static func isAppInitiatedDeparture(markedAt: Date?, now: Date) -> Bool {
        guard let markedAt else { return false }
        let elapsed = now.timeIntervalSince(markedAt)
        return elapsed.isFinite && elapsed >= 0 && elapsed <= appInitiatedDepartureWindow
    }

    /// What the running timer promises about the background.
    enum RunningNotice: Equatable, Sendable {
        /// The feature is off: the timer runs with the screen closed.
        case keepsRunning
        /// A passcode lets the app tell a lock from leaving.
        case pausesWhenLeavingButNotWhenLocked
        /// Without a passcode a lock also pauses.
        case pausesWhenLeavingOrLocking
    }

    static func runningNotice(
        featureEnabled: Bool,
        deviceHasPasscode: Bool
    ) -> RunningNotice {
        guard featureEnabled else { return .keepsRunning }
        return deviceHasPasscode
            ? .pausesWhenLeavingButNotWhenLocked
            : .pausesWhenLeavingOrLocking
    }
}

/// Process-local: the first time this process was confirmed on screen
/// (UIKit `.active`, recorded by `FocusLeaveMonitor`). It is the return from
/// an absence that an earlier process wrote and could not decide because it
/// ended inside the window. An absence this process writes itself always
/// starts later, so the witness never settles it (`returnedWithinWindow`).
enum FocusLeaveReturnWitness {
    private static let firstConfirmedActivation = OSAllocatedUnfairLock<Date?>(initialState: nil)

    static var confirmedReturn: Date? {
        firstConfirmedActivation.withLock { $0 }
    }

    static func recordConfirmedActivation(at date: Date) {
        firstConfirmedActivation.withLock { stored in
            if stored == nil { stored = date }
        }
    }
}

/// Device-local record, written synchronously at `.background`, of an absence
/// not classified yet. Never part of `FocusCloudPayload`.
struct FocusLeaveExcursion: Codable, Equatable, Sendable {
    let sessionID: UUID
    let leftAt: Date
}

/// Device-local record that this device paused the focus because the person
/// left the app. `plannedEndDate` is the end the focus had when they left,
/// which bounds the Screen Time learning hold; never part of
/// `FocusCloudPayload`.
struct FocusLeavePauseMarker: Codable, Equatable, Sendable {
    let sessionID: UUID
    let pausedAt: Date
    let plannedEndDate: Date
}

/// The envelope transitions of an absence. Pure so relaunch, remount and the
/// host's background window all apply exactly the same rule.
enum FocusLeaveTransition {
    /// Adds the absence marker to a running focus this device may pause.
    static func beginningExcursion(
        _ envelope: FocusRecoveryEnvelope,
        featureEnabled: Bool,
        at now: Date
    ) -> FocusRecoveryEnvelope? {
        guard let sessionID = envelope.engine.currentSessionID,
              PomodoroEngine.isSafePersistedDate(now),
              FocusLeavePolicy.shouldBeginExcursion(
                featureEnabled: featureEnabled,
                phase: envelope.engine.phase,
                hasPendingCompletion: envelope.pendingCompletion != nil,
                endDate: envelope.engine.endDate,
                now: now
              ) else { return nil }
        var result = envelope
        result.leaveExcursion = FocusLeaveExcursion(sessionID: sessionID, leftAt: now)
        return result
    }

    static func removingExcursion(_ envelope: FocusRecoveryEnvelope) -> FocusRecoveryEnvelope {
        var result = envelope
        result.leaveExcursion = nil
        return result
    }

    /// Pauses retroactively at the moment the person left, so time away never
    /// counts. `savedAt` stays the time of this write; only the remaining
    /// time derives from `leftAt`. Returns the envelope without its marker if
    /// the focus cannot be paused (it had already ended when they left).
    static func pausedForLeaving(
        _ envelope: FocusRecoveryEnvelope,
        decidedAt now: Date
    ) -> FocusRecoveryEnvelope {
        guard let excursion = envelope.leaveExcursion,
              envelope.pendingCompletion == nil,
              envelope.engine.phase == .focusing,
              envelope.engine.currentSessionID == excursion.sessionID,
              let plannedEnd = envelope.engine.endDate
        else { return removingExcursion(envelope) }
        var engine = envelope.engine
        do {
            try engine.pause(at: excursion.leftAt)
        } catch {
            return removingExcursion(envelope)
        }
        var result = envelope
        result.engine = engine
        result.leaveExcursion = nil
        result.leavePause = FocusLeavePauseMarker(
            sessionID: excursion.sessionID,
            pausedAt: excursion.leftAt,
            plannedEndDate: plannedEnd
        )
        // The delivery witness describes a running end date that no longer
        // exists; a paused envelope carrying one fails validation.
        result.scheduledCompletionNotificationDeliveryDate = nil
        if PomodoroEngine.isSafePersistedDate(now) {
            result.savedAt = now
        }
        return result
    }

    /// Applies an absence whose window has certainly ended. Anything else is
    /// returned unchanged: a window still open belongs to the host.
    ///
    /// `returnedAt` is this process's confirmed return
    /// (`FocusLeaveReturnWitness`). A process that ended inside the window
    /// cannot decide its absence; if the person came back within the window,
    /// that was a quick glance even when the first reader runs later (an
    /// iCloud launch reads the saved timer only once the account's container
    /// has mounted).
    static func resolvingStaleExcursion(
        _ envelope: FocusRecoveryEnvelope,
        at now: Date,
        returnedAt: Date? = nil
    ) -> FocusRecoveryEnvelope {
        guard let excursion = envelope.leaveExcursion else { return envelope }
        if let returnedAt,
           FocusLeavePolicy.returnedWithinWindow(leftAt: excursion.leftAt, returnedAt: returnedAt) {
            return removingExcursion(envelope)
        }
        guard FocusLeavePolicy.isStale(leftAt: excursion.leftAt, now: now) else { return envelope }
        return pausedForLeaving(envelope, decidedAt: now)
    }

    /// The person is back and the app is active: a quick glance removes the
    /// marker, a longer absence pauses at `leftAt`.
    static func resolvingOnReturn(
        _ envelope: FocusRecoveryEnvelope,
        at now: Date
    ) -> FocusRecoveryEnvelope {
        guard let excursion = envelope.leaveExcursion else { return envelope }
        switch FocusLeavePolicy.outcomeOnReturn(leftAt: excursion.leftAt, now: now) {
        case .quickGlance:
            return removingExcursion(envelope)
        case .left:
            return pausedForLeaving(envelope, decidedAt: now)
        }
    }

    /// The lock notice arrived: the timer keeps running.
    static func resolvingAsLocked(_ envelope: FocusRecoveryEnvelope) -> FocusRecoveryEnvelope {
        removingExcursion(envelope)
    }
}
