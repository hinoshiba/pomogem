import Foundation
import Observation
import UserNotifications

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

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Schedules the background completion alert. Reusing a session ID is
    /// idempotent because Notification Center replaces the existing request.
    func scheduleFocusCompletion(
        sessionID: UUID,
        subjectName: String,
        showsSubjectName: Bool,
        endDate: Date,
        playsSound: Bool = true,
        now: Date = .now
    ) async throws {
        let safeSubjectName = SubjectNamePolicy.displayName(subjectName)
        let content = notificationContent(
            body: showsSubjectName
                ? "\(safeSubjectName)の集中時間が終わりました。アプリを開いて状態を確認してください。"
                : "集中時間が終わりました。アプリを開いて状態を確認してください。",
            playsSound: playsSound
        )
        let delay = max(
            IntegrationConstants.notificationMinimumDelay,
            endDate.timeIntervalSince(now)
        )
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: delay,
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: Identifier.completion(sessionID: sessionID),
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func cancelFocusCompletion(sessionID: UUID) {
        center.removePendingNotificationRequests(
            withIdentifiers: [Identifier.completion(sessionID: sessionID)]
        )
    }

    func scheduleBreakCompletion(
        id: UUID,
        endDate: Date,
        playsSound: Bool = true,
        now: Date = .now
    ) async throws {
        let content = notificationContent(
            body: "休憩はここまで。次の一粒へ、ゆっくり戻りましょう。",
            playsSound: playsSound
        )
        let delay = max(
            IntegrationConstants.notificationMinimumDelay,
            endDate.timeIntervalSince(now)
        )
        let request = UNNotificationRequest(
            identifier: Identifier.breakCompletion(id: id),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        )
        do {
            try await center.add(request)
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func cancelBreakCompletion(id: UUID) {
        center.removePendingNotificationRequests(
            withIdentifiers: [Identifier.breakCompletion(id: id)]
        )
    }

    /// Reset recovery cannot rely on synchronized timer rows still being
    /// present, so it removes every locally scheduled transient request by the
    /// app-owned identifier prefixes.
    func cancelAllTimerNotifications() async {
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
        playsSound: Bool
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "つみべん"
        content.body = body
        content.sound = playsSound ? .default : nil
        content.badge = nil
        return content
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
