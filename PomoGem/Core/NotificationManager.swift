import Foundation
import Observation
import UserNotifications

enum TimerCompletionNotificationTiming {
    static func deliveryDelay(endDate: Date, requestCreatedAt: Date) -> TimeInterval {
        max(
            IntegrationConstants.notificationMinimumDelay,
            endDate.timeIntervalSince(requestCreatedAt)
        )
    }

    /// `UNTimeIntervalNotificationTrigger` starts when Notification Center
    /// accepts the request, not when this process constructs it. Using the
    /// completion side of `await add` gives a conservative witness: it may
    /// cause a harmless duplicate cue, but cannot cancel a still-pending alert
    /// under the mistaken belief that it already fired.
    static func conservativeDeliveryDate(
        delay: TimeInterval,
        registrationCompletedAt: Date
    ) -> Date {
        registrationCompletedAt.addingTimeInterval(delay)
    }
}

enum TimerCompletionNotificationScheduleResult: Equatable, Sendable {
    case accepted(deliveryDate: Date)
    case superseded
}

enum FocusReturnReminderPolicy {
    // This device preference follows Live Activity's local opt-in policy;
    // no account, subject, or study record is stored in the setting.
    static let enabledDefaultsKey = "notifications.focus-return-reminder.enabled"
    static let delay: TimeInterval = 30
    static let completionQuietWindow: TimeInterval = 60

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledDefaultsKey)
    }

    static func shouldSchedule(
        preferenceEnabled: Bool,
        sceneIsBackground: Bool,
        phase: PomodoroPhase,
        endDate: Date?,
        now: Date = .now
    ) -> Bool {
        guard preferenceEnabled, sceneIsBackground, phase == .focusing,
              let endDate else { return false }
        let remaining = endDate.timeIntervalSince(now)
        return remaining.isFinite && remaining > delay + completionQuietWindow
    }
}

/// A narrow notification-center boundary for exercising reminder races
/// without scheduling notifications on a developer's device.
@MainActor
struct FocusReturnReminderNotificationClient {
    var authorizationStatus: () async -> UNAuthorizationStatus
    var add: (UNNotificationRequest) async throws -> Void
    var removePending: ([String]) -> Void
    var removeDelivered: ([String]) -> Void

    static func system(center: UNUserNotificationCenter) -> Self {
        Self(
            authorizationStatus: { await center.notificationSettings().authorizationStatus },
            add: { try await center.add($0) },
            removePending: { center.removePendingNotificationRequests(withIdentifiers: $0) },
            removeDelivered: { center.removeDeliveredNotifications(withIdentifiers: $0) }
        )
    }
}

/// Owns every local notification emitted by the app.
///
/// Passive reminders are materialized as one-shot requests so the monthly
/// Wrapped message can replace (rather than duplicate) that day's reminder.
/// Calling `synchronizePassiveNotifications` on launch keeps the rolling
/// schedule full without ever creating two passive notifications on one day.
@MainActor
@Observable
final class NotificationManager {
    static let shared = NotificationManager()

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var lastErrorDescription: String?

    private let center: UNUserNotificationCenter
    private let focusReturnReminderClient: FocusReturnReminderNotificationClient
    private let focusReturnReminderDefaults: UserDefaults
    private var authorizationRefreshGeneration: UInt64 = 0
    private var latestAuthorizationRefresh: AuthorizationRefreshIntent?
    private var focusNotificationGeneration: UInt64 = 0
    private var focusNotificationIntents: [UUID: UInt64] = [:]
    private var focusNotificationOperations: [UUID: NotificationScheduleOperation] = [:]
    private var focusReturnReminderGeneration: UInt64 = 0
    private var focusReturnReminderSessionID: UUID?
    private var focusReturnReminderOperation: NotificationScheduleOperation?
    private var registeredFocusReturnReminder: FocusReturnReminderCandidate?
    private var breakNotificationGeneration: UInt64 = 0
    private var breakNotificationIntents: [UUID: UInt64] = [:]
    private var breakNotificationOperations: [UUID: NotificationScheduleOperation] = [:]
    private var timerSchedulingIsSuspendedForAccountBoundary = false

    private struct AuthorizationRefreshIntent {
        let generation: UInt64
        let task: Task<UNAuthorizationStatus, Never>
    }

    private struct NotificationScheduleOperation {
        let generation: UInt64
        let task: Task<TimerCompletionNotificationScheduleResult, Error>
    }

    private struct FocusReturnReminderCandidate: Equatable {
        let sessionID: UUID
        let endDate: Date
        let playsSound: Bool
    }

    private enum Identifier {
        static let completionPrefix = "pomogem.focus.complete."
        static let focusReturnReminder = "pomogem.focus.return-reminder"
        static let breakPrefix = "pomogem.break.complete."
        static let passivePrefix = "pomogem.passive."

        static func completion(sessionID: UUID) -> String {
            completionPrefix + sessionID.uuidString.lowercased()
        }

        static func breakCompletion(id: UUID) -> String {
            breakPrefix + id.uuidString.lowercased()
        }

        static func passive(date: Date, calendar: Calendar) -> String {
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            return passivePrefix + [
                components.year ?? 0,
                components.month ?? 0,
                components.day ?? 0
            ]
            .map(String.init)
            .joined(separator: ".")
        }
    }

    init(
        center: UNUserNotificationCenter = .current(),
        focusReturnReminderClient: FocusReturnReminderNotificationClient? = nil,
        focusReturnReminderDefaults: UserDefaults = .standard
    ) {
        self.center = center
        self.focusReturnReminderClient = focusReturnReminderClient ?? .system(center: center)
        self.focusReturnReminderDefaults = focusReturnReminderDefaults
    }

    var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            await refreshAuthorizationStatus()
            lastErrorDescription = nil
            return granted
        } catch {
            lastErrorDescription = error.localizedDescription
            await refreshAuthorizationStatus()
            return false
        }
    }

    @discardableResult
    func refreshAuthorizationStatus() async -> UNAuthorizationStatus {
        authorizationRefreshGeneration &+= 1
        let generation = authorizationRefreshGeneration
        let authorizationQuery = focusReturnReminderClient.authorizationStatus
        var intent = AuthorizationRefreshIntent(
            generation: generation,
            task: Task { @MainActor in
                await authorizationQuery()
            }
        )
        latestAuthorizationRefresh = intent

        // An older query is allowed to finish, but every waiter follows the
        // newest in-flight query before returning. Thus a late `authorized`
        // result can never overwrite a newer `denied` snapshot.
        while true {
            let status = await intent.task.value
            guard let latestAuthorizationRefresh else {
                authorizationStatus = status
                return status
            }
            guard latestAuthorizationRefresh.generation
                    == intent.generation else {
                intent = latestAuthorizationRefresh
                continue
            }
            authorizationStatus = status
            return status
        }
    }

    /// Schedules the background completion alert. Reusing a session ID is
    /// idempotent because Notification Center replaces the existing request.
    func scheduleFocusCompletion(
        sessionID: UUID,
        endDate: Date,
        playsSound: Bool = true,
        completionSound: TimerCompletionSound = .standard
    ) async throws -> TimerCompletionNotificationScheduleResult {
        guard !timerSchedulingIsSuspendedForAccountBoundary else {
            return .superseded
        }
        let content = notificationContent(
            // Notification Center can deliver a request while this process is
            // suspended and therefore cannot re-check the active iCloud
            // account. Keep the immutable payload account-neutral. Live
            // Activity content is gated independently by account identity.
            body: "集中時間が終わりました。アプリを開いて状態を確認してください。",
            playsSound: playsSound,
            timerCompletionSound: completionSound
        )
        focusNotificationGeneration &+= 1
        let generation = focusNotificationGeneration
        focusNotificationIntents[sessionID] = generation
        let previousTask = focusNotificationOperations[sessionID]?.task
        let operationTask = Task<TimerCompletionNotificationScheduleResult, Error> {
            @MainActor [self] in
            if let previousTask {
                _ = try? await previousTask.value
            }
            guard focusNotificationIntents[sessionID] == generation else {
                return .superseded
            }
            return try await performTimerNotificationAdd(
                identifier: Identifier.completion(sessionID: sessionID),
                endDate: endDate,
                content: content,
                intentIsCurrent: {
                    self.focusNotificationIntents[sessionID] == generation
                }
            )
        }
        focusNotificationOperations[sessionID] = NotificationScheduleOperation(
            generation: generation,
            task: operationTask
        )
        defer {
            if focusNotificationOperations[sessionID]?.generation == generation {
                focusNotificationOperations.removeValue(forKey: sessionID)
            }
        }
        return try await operationTask.value
    }

    func cancelFocusCompletion(sessionID: UUID) {
        focusNotificationIntents.removeValue(forKey: sessionID)
        center.removePendingNotificationRequests(
            withIdentifiers: [Identifier.completion(sessionID: sessionID)]
        )
        if registeredFocusReturnReminder?.sessionID == sessionID {
            registeredFocusReturnReminder = nil
        }
        if focusReturnReminderSessionID == sessionID {
            cancelFocusReturnReminder()
        }
    }

    /// The owning Focus view registers its running timer before a temporary
    /// inactive-state unmount. The persistent launch host consumes this
    /// process-local snapshot only upon an actual background transition.
    func registerFocusReturnReminder(
        sessionID: UUID,
        endDate: Date,
        playsSound: Bool
    ) {
        guard !timerSchedulingIsSuspendedForAccountBoundary else { return }
        let candidate = FocusReturnReminderCandidate(
            sessionID: sessionID,
            endDate: endDate,
            playsSound: playsSound
        )
        guard registeredFocusReturnReminder != candidate else { return }
        cancelFocusReturnReminder()
        registeredFocusReturnReminder = candidate
    }

    func scheduleRegisteredFocusReturnReminder() async throws
        -> TimerCompletionNotificationScheduleResult {
        guard let candidate = registeredFocusReturnReminder else {
            cancelFocusReturnReminder()
            return .superseded
        }
        return try await scheduleFocusReturnReminder(
            sessionID: candidate.sessionID,
            endDate: candidate.endDate,
            playsSound: candidate.playsSound
        )
    }

    /// Call only for an actual background transition of a running focus.
    /// One identifier and one operation chain cover all sessions so cleanup
    /// from an older add cannot remove a newer timer's reminder.
    func scheduleFocusReturnReminder(
        sessionID: UUID,
        endDate: Date,
        playsSound: Bool
    ) async throws -> TimerCompletionNotificationScheduleResult {
        guard !Task.isCancelled else { return .superseded }
        guard !timerSchedulingIsSuspendedForAccountBoundary,
              focusReturnReminderTimeIsEligible(endDate: endDate) else {
            cancelFocusReturnReminder()
            return .superseded
        }
        focusReturnReminderGeneration &+= 1
        let generation = focusReturnReminderGeneration
        focusReturnReminderSessionID = sessionID
        removeFocusReturnReminderRequests()
        let requestedAt = Date.now
        let previousTask = focusReturnReminderOperation?.task
        let operationTask = Task<TimerCompletionNotificationScheduleResult, Error> {
            @MainActor [self] in
            if let previousTask {
                _ = try? await previousTask.value
            }
            guard focusReturnReminderIntentIsCurrent(generation, sessionID: sessionID) else {
                return .superseded
            }
            await refreshAuthorizationStatus()
            guard focusReturnReminderIntentIsCurrent(generation, sessionID: sessionID) else {
                return .superseded
            }
            guard isAuthorized, focusReturnReminderTimeIsEligible(endDate: endDate) else {
                removeFocusReturnReminderRequests()
                return .superseded
            }
            // Preserve the background transition's deadline if authorization
            // refresh or an earlier add took time to finish.
            let delay = TimerCompletionNotificationTiming.deliveryDelay(
                endDate: requestedAt.addingTimeInterval(FocusReturnReminderPolicy.delay),
                requestCreatedAt: .now
            )
            let content = notificationContent(
                body: "集中時間が続いています。タイマーに戻って続けましょう。",
                playsSound: playsSound
            )
            let request = UNNotificationRequest(
                identifier: Identifier.focusReturnReminder,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            )
            do {
                try await focusReturnReminderClient.add(request)
            } catch {
                guard focusReturnReminderIntentIsCurrent(generation, sessionID: sessionID) else {
                    removeFocusReturnReminderRequests()
                    return .superseded
                }
                lastErrorDescription = error.localizedDescription
                throw error
            }
            guard focusReturnReminderIntentIsCurrent(generation, sessionID: sessionID),
                  isAuthorized, focusReturnReminderTimeIsEligible(endDate: endDate) else {
                removeFocusReturnReminderRequests()
                return .superseded
            }
            lastErrorDescription = nil
            return .accepted(deliveryDate: TimerCompletionNotificationTiming
                .conservativeDeliveryDate(delay: delay, registrationCompletedAt: .now))
        }
        focusReturnReminderOperation = NotificationScheduleOperation(
            generation: generation,
            task: operationTask
        )
        defer {
            if focusReturnReminderOperation?.generation == generation {
                focusReturnReminderOperation = nil
            }
        }
        return try await operationTask.value
    }

    /// Foregrounding cancels the pending/delivered cue while retaining the
    /// registered running timer for its next actual background transition.
    func cancelFocusReturnReminder() {
        focusReturnReminderGeneration &+= 1
        focusReturnReminderSessionID = nil
        removeFocusReturnReminderRequests()
        // Keep the in-flight operation in the chain until its late add has
        // finished and removed itself; a newer add must wait for that cleanup.
    }

    private func focusReturnReminderIntentIsCurrent(
        _ generation: UInt64,
        sessionID: UUID
    ) -> Bool {
        !timerSchedulingIsSuspendedForAccountBoundary
            && focusReturnReminderGeneration == generation
            && focusReturnReminderSessionID == sessionID
    }

    private func focusReturnReminderTimeIsEligible(endDate: Date) -> Bool {
        FocusReturnReminderPolicy.shouldSchedule(
            preferenceEnabled: FocusReturnReminderPolicy.isEnabled(defaults: focusReturnReminderDefaults),
            sceneIsBackground: true,
            phase: .focusing,
            endDate: endDate
        )
    }

    private func removeFocusReturnReminderRequests() {
        focusReturnReminderClient.removePending([Identifier.focusReturnReminder])
        focusReturnReminderClient.removeDelivered([Identifier.focusReturnReminder])
    }

    func scheduleBreakCompletion(
        id: UUID,
        endDate: Date,
        playsSound: Bool = true,
        completionSound: TimerCompletionSound = .standard
    ) async throws -> TimerCompletionNotificationScheduleResult {
        guard !timerSchedulingIsSuspendedForAccountBoundary else {
            return .superseded
        }
        let content = notificationContent(
            body: "休憩はここまで。次の一粒へ、ゆっくり戻りましょう。",
            playsSound: playsSound,
            timerCompletionSound: completionSound
        )
        breakNotificationGeneration &+= 1
        let generation = breakNotificationGeneration
        breakNotificationIntents[id] = generation
        let previousTask = breakNotificationOperations[id]?.task
        let operationTask = Task<TimerCompletionNotificationScheduleResult, Error> {
            @MainActor [self] in
            if let previousTask {
                _ = try? await previousTask.value
            }
            guard breakNotificationIntents[id] == generation else {
                return .superseded
            }
            return try await performTimerNotificationAdd(
                identifier: Identifier.breakCompletion(id: id),
                endDate: endDate,
                content: content,
                intentIsCurrent: {
                    self.breakNotificationIntents[id] == generation
                }
            )
        }
        breakNotificationOperations[id] = NotificationScheduleOperation(
            generation: generation,
            task: operationTask
        )
        defer {
            if breakNotificationOperations[id]?.generation == generation {
                breakNotificationOperations.removeValue(forKey: id)
            }
        }
        return try await operationTask.value
    }

    func cancelBreakCompletion(id: UUID) {
        breakNotificationIntents.removeValue(forKey: id)
        center.removePendingNotificationRequests(
            withIdentifiers: [Identifier.breakCompletion(id: id)]
        )
    }

    /// Blocks timer requests from views owned by an Apple Account that is
    /// being retired. Normal backgrounding deliberately does not call this:
    /// its accepted lock-screen notifications must remain scheduled.
    func suspendTimerSchedulingForAccountBoundary() {
        timerSchedulingIsSuspendedForAccountBoundary = true
        registeredFocusReturnReminder = nil
        cancelFocusReturnReminder()
        focusNotificationIntents.removeAll()
        focusNotificationGeneration &+= 1
        breakNotificationIntents.removeAll()
        breakNotificationGeneration &+= 1
    }

    func resumeTimerSchedulingAfterAccountBoundary() {
        timerSchedulingIsSuspendedForAccountBoundary = false
    }

    /// Reset recovery cannot rely on synchronized timer rows still being
    /// present, so it removes every locally scheduled transient request by the
    /// app-owned identifier prefixes.
    func cancelAllTimerNotifications() async {
        registeredFocusReturnReminder = nil
        cancelFocusReturnReminder()
        focusNotificationIntents.removeAll()
        focusNotificationGeneration &+= 1
        breakNotificationIntents.removeAll()
        breakNotificationGeneration &+= 1
        await removePendingRequests(withPrefix: Identifier.completionPrefix)
        await removePendingRequests(withPrefix: Identifier.breakPrefix)
    }

    /// Refreshes the next 35 days of engagement notifications.
    ///
    /// On the first of a month, Wrapped takes the daily reminder's slot. Both
    /// notification types remain opt-in and no request ever carries a badge.
    func synchronizePassiveNotifications(
        dailyReminderEnabled: Bool,
        wrappedEnabled: Bool,
        hour: Int,
        minute: Int,
        playsSound: Bool = true,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) async throws {
        await removePendingRequests(withPrefix: Identifier.passivePrefix)

        guard dailyReminderEnabled || wrappedEnabled else {
            lastErrorDescription = nil
            return
        }

        var matchingComponents = DateComponents()
        matchingComponents.hour = min(max(hour, 0), 23)
        matchingComponents.minute = min(max(minute, 0), 59)

        guard let firstDate = calendar.nextDate(
            after: now,
            matching: matchingComponents,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else {
            return
        }

        do {
            for offset in 0..<IntegrationConstants.passiveNotificationHorizonDays {
                guard let date = calendar.date(
                    byAdding: .day,
                    value: offset,
                    to: firstDate
                ) else { continue }

                let isFirstOfMonth = calendar.component(.day, from: date) == 1
                let body: String
                if isFirstOfMonth && wrappedEnabled {
                    body = "先月の瓶ができた。積み上がりを眺めよう。"
                } else if dailyReminderEnabled {
                    body = "瓶が待ってる。今日のひと粒、積んでいく？"
                } else {
                    continue
                }

                let content = notificationContent(
                    body: body,
                    playsSound: playsSound
                )
                var triggerComponents = calendar.dateComponents(
                    [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
                    from: date
                )
                triggerComponents.second = 0
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: triggerComponents,
                    repeats: false
                )
                let request = UNNotificationRequest(
                    identifier: Identifier.passive(date: date, calendar: calendar),
                    content: content,
                    trigger: trigger
                )
                try await center.add(request)
            }
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func cancelPassiveNotifications() async {
        await removePendingRequests(withPrefix: Identifier.passivePrefix)
    }

    /// Keeps the home screen free from red badge counts even if an older build
    /// or restored notification setting left one behind.
    func clearDeliveredState() async {
        center.removeAllDeliveredNotifications()
        do {
            try await center.setBadgeCount(0)
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    private func notificationContent(
        body: String,
        playsSound: Bool,
        timerCompletionSound: TimerCompletionSound? = nil
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "ポモジェム"
        content.body = body
        if playsSound {
            content.sound = timerCompletionSound.map {
                TimerCompletionSoundLibrary.notificationSound(for: $0)
            } ?? .default
        } else {
            content.sound = nil
        }
        content.badge = nil
        return content
    }

    /// Adds for one logical timer are chained by the caller before entering
    /// here. Consequently an older relative trigger can never complete after a
    /// newer one and restart its interval. If cancellation/rescheduling wins
    /// during `await add`, this operation removes only its own just-added
    /// request before the next serialized operation begins.
    private func performTimerNotificationAdd(
        identifier: String,
        endDate: Date,
        content: UNNotificationContent,
        intentIsCurrent: @MainActor () -> Bool
    ) async throws -> TimerCompletionNotificationScheduleResult {
        guard intentIsCurrent() else { return .superseded }
        let requestCreatedAt = Date.now
        let delay = TimerCompletionNotificationTiming.deliveryDelay(
            endDate: endDate,
            requestCreatedAt: requestCreatedAt
        )
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: delay,
                repeats: false
            )
        )
        do {
            try await center.add(request)
        } catch {
            guard intentIsCurrent() else {
                center.removePendingNotificationRequests(
                    withIdentifiers: [identifier]
                )
                return .superseded
            }
            lastErrorDescription = error.localizedDescription
            throw error
        }
        guard intentIsCurrent() else {
            center.removePendingNotificationRequests(
                withIdentifiers: [identifier]
            )
            return .superseded
        }
        lastErrorDescription = nil
        return .accepted(
            deliveryDate: TimerCompletionNotificationTiming
                .conservativeDeliveryDate(
                    delay: delay,
                    registrationCompletedAt: .now
                )
        )
    }

    private func removePendingRequests(withPrefix prefix: String) async {
        let pending = await pendingNotificationRequests()
        let identifiers = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(prefix) }
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
    }
}
