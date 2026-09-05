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
    private var authorizationRefreshGeneration: UInt64 = 0
    private var latestAuthorizationRefresh: AuthorizationRefreshIntent?
    private var focusNotificationGeneration: UInt64 = 0
    private var focusNotificationIntents: [UUID: UInt64] = [:]
    private var focusNotificationOperations: [UUID: NotificationScheduleOperation] = [:]
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

    private enum Identifier {
        static let completionPrefix = "tsumiben.focus.complete."
        static let breakPrefix = "tsumiben.break.complete."
        static let passivePrefix = "tsumiben.passive."

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

    private init(center: UNUserNotificationCenter = .current()) {
        self.center = center
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
        let center = center
        var intent = AuthorizationRefreshIntent(
            generation: generation,
            task: Task { @MainActor in
                await center.notificationSettings().authorizationStatus
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
        content.title = "つみべん"
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
