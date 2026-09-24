import Foundation
import Observation
import SwiftData
import UserNotifications

/// Releases a cancelled view's waiter while the manager keeps ownership of an
/// already accepted system request. Native notification callbacks may ignore
/// task cancellation; an awaiting view must not keep its retired store alive.
final class CancellationResponsiveTaskWaiter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    private func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    static func value(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let waiter = CancellationResponsiveTaskWaiter()
        let value = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                Task {
                    do { waiter.finish(.success(try await operation())) }
                    catch { waiter.finish(.failure(error)) }
                }
            }
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
        }
        try Task.checkCancellation()
        return value
    }
}

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
    /// How long the app keeps running after an accepted reminder to learn
    /// whether the person only locked the phone. With a passcode, iOS posts
    /// `protectedDataWillBecomeUnavailable` about 10 seconds after locking.
    /// The window ends well before the 30-second trigger and inside the short
    /// background-task budget; at its end the reminder simply stays booked.
    static let lockDetectionWindow: TimeInterval = 20

    /// Background time running out says nothing about a lock. Only an add
    /// that never finished is withdrawn; an accepted reminder must still reach
    /// the person who switched apps.
    static func shouldWithdrawOnBackgroundExpiry(addWasAccepted: Bool) -> Bool {
        !addWasAccepted
    }

    /// A missed notification (for example, the lock happened while the add was
    /// still in flight) is caught by reading the protected-data state at the end.
    static func shouldWithdrawAtLockWindowEnd(protectedDataIsAvailable: Bool) -> Bool {
        !protectedDataIsAvailable
    }

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

/// What the person has already done, as far as the passive reminders care.
/// It is read on this device right before each schedule and never leaves
/// it: nothing here is synced, and only the booked requests reflect it.
struct PassiveReminderActivity: Equatable, Sendable {
    /// 04:00-boundary study days (`FairnessPolicy.deviceDayKey`) on which a
    /// focus was started or ran, or time was added by hand. Screen Time gems
    /// arrive by themselves and do not count. The daily reminder asks
    /// 「今日のひと粒、積んでいく？」, so it stays quiet on those days.
    var answeredStudyDayKeys: Set<String> = []
    /// Months holding at least one record (`monthKey`), or nil when records
    /// could not be read. Wrapped says 「先月の瓶ができた」, so the 1st of a
    /// month carries it only when the month before has a jar to look at.
    var monthsWithRecords: Set<String>?

    /// Nothing is known: the daily reminder and Wrapped keep their slots.
    static let unknown = PassiveReminderActivity()

    static func monthKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.era, .year, .month], from: date)
        return "\(components.era ?? 0)-\(components.year ?? 0)-\(components.month ?? 0)"
    }

    func answersDailyReminder(at slot: Date, calendar: Calendar) -> Bool {
        answeredStudyDayKeys.contains(
            FairnessPolicy.deviceDayKey(for: slot, timeZone: calendar.timeZone)
        )
    }

    /// The Wrapped slot on the 1st looks back at the month that just ended.
    func hasRecordsInMonthEnding(before slot: Date, calendar: Calendar) -> Bool {
        guard let monthsWithRecords else { return true }
        guard let lastDay = calendar.date(byAdding: .day, value: -1, to: slot) else {
            return true
        }
        return monthsWithRecords.contains(Self.monthKey(for: lastDay, calendar: calendar))
    }
}

/// Decides what, if anything, one passive slot carries. Pure so the rules
/// can be pinned without Notification Center.
enum PassiveReminderSchedulePolicy {
    enum Kind: Equatable {
        case dailyReminder
        case wrapped
    }

    static func kind(
        for slot: Date,
        now: Date,
        dailyReminderEnabled: Bool,
        wrappedEnabled: Bool,
        activity: PassiveReminderActivity,
        calendar: Calendar
    ) -> Kind? {
        // Wrapped keeps its monthly slot even on a day already focused and
        // beyond the daily back-off: it is a once-a-month look back, not a nudge.
        if wrappedEnabled,
           calendar.component(.day, from: slot) == 1,
           activity.hasRecordsInMonthEnding(before: slot, calendar: calendar) {
            return .wrapped
        }
        guard dailyReminderEnabled,
              let dailyDeadline = calendar.date(
                  byAdding: .day,
                  value: IntegrationConstants.passiveDailyReminderHorizonDays,
                  to: now
              ),
              slot < dailyDeadline,
              !activity.answersDailyReminder(at: slot, calendar: calendar)
        else { return nil }
        return .dailyReminder
    }
}

/// Reads `PassiveReminderActivity` from this device's store and local state.
/// Every failure falls back to "unknown", which books what 1.0.2 booked: a
/// redundant reminder is better than a silently missing one.
@MainActor
enum PassiveReminderActivityReader {
    /// The study day on which this device last opened a focus. Device-local
    /// and account-scoped: a date key only, never synced or exported.
    static var focusStartedStudyDayDefaultsKey: String {
        AccountScopedLocalState.defaultsKey(base: "notifications.passive.focus-started-study-day")
    }

    /// Home calls this when the person starts a new focus. Opening one
    /// answers today's reminder even when it is stopped with 「今日はここまで」:
    /// asking again an hour later would be a nag.
    static func recordFocusStarted(
        at now: Date = .now,
        timeZone: TimeZone = .current,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(
            FairnessPolicy.deviceDayKey(for: now, timeZone: timeZone),
            forKey: focusStartedStudyDayDefaultsKey
        )
    }

    /// Reopening a focus is not starting one. A recovered focus answers today
    /// only when it began today: one that ran late last night and is only
    /// committed this morning belongs to last night, and a focus paused days
    /// ago answers nothing new each time it is shown again.
    static func recordRecoveredFocus(
        engine: PomodoroEngine,
        pendingCompletion: PomodoroCompletion?,
        at now: Date = .now,
        timeZone: TimeZone = .current,
        defaults: UserDefaults = .standard
    ) {
        let todayKey = FairnessPolicy.deviceDayKey(for: now, timeZone: timeZone)
        guard let startedAt = focusStartDate(engine: engine, pendingCompletion: pendingCompletion),
              FairnessPolicy.deviceDayKey(for: startedAt, timeZone: timeZone) == todayKey
        else { return }
        defaults.set(todayKey, forKey: focusStartedStudyDayDefaultsKey)
    }

    static func read(
        context: ModelContext,
        markers: [ActivityResetSnapshot],
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        defaults: UserDefaults = .standard
    ) -> PassiveReminderActivity {
        let todayKey = FairnessPolicy.deviceDayKey(for: now, timeZone: calendar.timeZone)
        let epochID = ActivityResetPolicy.currentEpochID(from: markers, now: now)
        var activity = PassiveReminderActivity()

        // A focus still in this device's recovery data (running, paused or
        // awaiting its save) answers the days it belongs to, never simply
        // today: a paused focus can linger for days.
        activity.answeredStudyDayKeys = studyDayKeys(
            ofPersistedFocus: defaults.data(forKey: FocusPersistence.key),
            timeZone: calendar.timeZone
        )
        if defaults.string(forKey: focusStartedStudyDayDefaultsKey) == todayKey
            || hasFocusRecord(
                studyDayKey: todayKey,
                context: context,
                epochID: epochID,
                now: now
            ) {
            activity.answeredStudyDayKeys.insert(todayKey)
        }
        activity.monthsWithRecords = monthsWithRecords(
            context: context,
            epochID: epochID,
            now: now,
            calendar: calendar
        )
        return activity
    }

    /// A timer or hand-added record already answers 「今日のひと粒」. Screen
    /// Time chunks do not: they arrive by themselves and include black gems.
    private static func hasFocusRecord(
        studyDayKey: String,
        context: ModelContext,
        epochID: UUID?,
        now: Date
    ) -> Bool {
        // A study day is at most 25 hours long, so its records ended within
        // this window. The page is bounded; a miss only books a reminder.
        let descriptor = BoundedHistoryPolicy.sessionDescriptor(
            epochID: epochID,
            start: now.addingTimeInterval(-26 * 60 * 60),
            limit: 256
        )
        guard let rows = try? context.fetch(descriptor) else { return false }
        return rows.contains { row in
            row.deviceDayKey == studyDayKey
                && row.effectiveSource != .screenTime
                && StudySessionIntegrityPolicy.isSupported(row, relativeTo: now)
        }
    }

    /// The study days a focus in this device's recovery data belongs to: the
    /// day it began and the day its record will carry (records are keyed by
    /// their end). A break, or bytes that cannot be read, answer nothing.
    /// Decoding here has no side effects; restoring owns clearing bad bytes.
    static func studyDayKeys(ofPersistedFocus data: Data?, timeZone: TimeZone) -> Set<String> {
        guard let data else { return [] }
        let decoder = JSONDecoder()
        let engine: PomodoroEngine
        let pendingCompletion: PomodoroCompletion?
        if let envelope = try? decoder.decode(FocusRecoveryEnvelope.self, from: data) {
            engine = envelope.engine
            pendingCompletion = envelope.pendingCompletion
        } else if let legacyEngine = try? decoder.decode(PomodoroEngine.self, from: data) {
            engine = legacyEngine
            pendingCompletion = nil
        } else {
            return []
        }

        let dates: [Date]
        if let pendingCompletion {
            dates = [pendingCompletion.startedAt, pendingCompletion.endedAt]
        } else if engine.containsRecoverableFocus, let startedAt = engine.phaseStartedAt {
            // A paused focus has no end yet; a running one ends at `endDate`.
            dates = [startedAt] + (engine.endDate.map { [$0] } ?? [])
        } else {
            return []
        }
        return Set(dates.filter(PomodoroEngine.isSafePersistedDate).map {
            FairnessPolicy.deviceDayKey(for: $0, timeZone: timeZone)
        })
    }

    /// Pause and resume keep `phaseStartedAt` (it moves only when the clock
    /// ran backwards while paused), so it is the focus's start.
    private static func focusStartDate(
        engine: PomodoroEngine,
        pendingCompletion: PomodoroCompletion?
    ) -> Date? {
        let startedAt = pendingCompletion?.startedAt
            ?? (engine.containsRecoverableFocus ? engine.phaseStartedAt : nil)
        guard let startedAt, PomodoroEngine.isSafePersistedDate(startedAt) else { return nil }
        return startedAt
    }

    /// Only this month and the previous one can end before a Wrapped slot in
    /// the 35-day window while already holding records.
    private static func monthsWithRecords(
        context: ModelContext,
        epochID: UUID?,
        now: Date,
        calendar: Calendar
    ) -> Set<String>? {
        guard let currentStart = calendar.dateInterval(of: .month, for: now)?.start else {
            return nil
        }
        var months = Set<String>()
        for offset in [-1, 0] {
            guard let start = calendar.date(byAdding: .month, value: offset, to: currentStart),
                  let end = calendar.date(byAdding: .month, value: 1, to: start)
            else { return nil }
            // The Log lists a month's jar when it holds any supported record.
            // Existence needs no replica resolution; a small page is enough,
            // and a page of only unreadable rows keeps Wrapped as before.
            let limit = 16
            guard let rows = try? context.fetch(BoundedHistoryPolicy.sessionDescriptor(
                epochID: epochID,
                start: start,
                end: end,
                limit: limit
            )) else { return nil }
            if rows.contains(where: { StudySessionIntegrityPolicy.isSupported($0, relativeTo: now) })
                || rows.count == limit {
                months.insert(PassiveReminderActivity.monthKey(for: start, calendar: calendar))
            }
        }
        return months
    }
}

/// Injectable boundary for pending requests shared by timer and passive
/// scheduling. Tests can delay system callbacks without touching device state.
@MainActor
struct NotificationRequestClient {
    var add: (UNNotificationRequest) async throws -> Void
    var pending: () async -> [UNNotificationRequest]
    var removePending: ([String]) -> Void

    static func system(center: UNUserNotificationCenter) -> Self {
        Self(
            add: { try await center.add($0) },
            pending: { await center.pendingNotificationRequests() },
            removePending: { center.removePendingNotificationRequests(withIdentifiers: $0) }
        )
    }
}

/// Owns every local notification emitted by the app.
///
/// Passive reminders are materialized as one-shot requests so the monthly
/// Wrapped message can replace (rather than duplicate) that day's reminder,
/// and so a day the person already focused can simply have no request.
/// Calling `synchronizePassiveNotifications` on launch and foreground keeps
/// the rolling schedule current without ever creating two passive
/// notifications on one day.
@MainActor
@Observable
final class NotificationManager {
    static let shared = NotificationManager()

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    /// False until iOS has answered once in this process. `.notDetermined`
    /// before that is only the initial value, not a fact about this device.
    private(set) var hasLoadedAuthorizationStatus = false
    private(set) var lastErrorDescription: String?

    private let center: UNUserNotificationCenter
    private let requestClient: NotificationRequestClient
    private let focusReturnReminderClient: FocusReturnReminderNotificationClient
    private let focusReturnReminderDefaults: UserDefaults
    private let authorizationRequest: () async throws -> Bool
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
    private var passiveNotificationGeneration: UInt64 = 0
    private var passiveNotificationTask: Task<Void, Error>?
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
        requestClient: NotificationRequestClient? = nil,
        focusReturnReminderClient: FocusReturnReminderNotificationClient? = nil,
        focusReturnReminderDefaults: UserDefaults = .standard,
        authorizationRequest: (() async throws -> Bool)? = nil
    ) {
        self.center = center
        self.requestClient = requestClient ?? .system(center: center)
        self.focusReturnReminderClient = focusReturnReminderClient ?? .system(center: center)
        self.focusReturnReminderDefaults = focusReturnReminderDefaults
        self.authorizationRequest = authorizationRequest ?? {
            try await center.requestAuthorization(options: [.alert, .sound])
        }
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
        guard !Task.isCancelled else { return false }
        let request = authorizationRequest
        let task = Task { @MainActor in try await request() }
        do {
            let granted = try await CancellationResponsiveTaskWaiter.value { try await task.value }
            guard !Task.isCancelled else { return false }
            await refreshAuthorizationStatus()
            guard !Task.isCancelled else { return false }
            lastErrorDescription = nil
            return granted
        } catch {
            guard !Task.isCancelled else { return false }
            lastErrorDescription = error.localizedDescription
            await refreshAuthorizationStatus()
            return false
        }
    }

    @discardableResult
    func refreshAuthorizationStatus() async -> UNAuthorizationStatus {
        guard !Task.isCancelled else { return authorizationStatus }
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
            let task = intent.task
            let status: UNAuthorizationStatus
            do {
                status = try await CancellationResponsiveTaskWaiter.value { await task.value }
            } catch {
                return authorizationStatus
            }
            guard !Task.isCancelled else { return authorizationStatus }
            guard let latestAuthorizationRefresh else {
                authorizationStatus = status
                hasLoadedAuthorizationStatus = true
                return status
            }
            guard latestAuthorizationRefresh.generation
                    == intent.generation else {
                intent = latestAuthorizationRefresh
                continue
            }
            authorizationStatus = status
            hasLoadedAuthorizationStatus = true
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
        guard !Task.isCancelled, !timerSchedulingIsSuspendedForAccountBoundary else {
            return .superseded
        }
        let content = notificationContent(
            // Notification Center can deliver a request while this process is
            // suspended and therefore cannot re-check the active iCloud
            // account. Keep the immutable payload account-neutral, and never
            // promise a gem: the completion is saved only when the app opens.
            // Live Activity content is gated independently by account identity.
            body: "集中時間が終わりました。おつかれさまでした。",
            playsSound: playsSound,
            timerCompletionSound: completionSound,
            interruptionLevel: .timeSensitive
        )
        focusNotificationGeneration &+= 1
        let generation = focusNotificationGeneration
        focusNotificationIntents[sessionID] = generation
        let previousTask = focusNotificationOperations[sessionID]?.task
        let operationTask = Task<TimerCompletionNotificationScheduleResult, Error> {
            @MainActor [self] in
            defer {
                if focusNotificationOperations[sessionID]?.generation == generation {
                    focusNotificationOperations.removeValue(forKey: sessionID)
                }
            }
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
        return try await CancellationResponsiveTaskWaiter.value {
            try await operationTask.value
        }
    }

    func cancelFocusCompletion(sessionID: UUID) {
        focusNotificationIntents.removeValue(forKey: sessionID)
        requestClient.removePending(
            [Identifier.completion(sessionID: sessionID)]
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
            defer {
                if focusReturnReminderOperation?.generation == generation {
                    focusReturnReminderOperation = nil
                }
            }
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
        return try await CancellationResponsiveTaskWaiter.value {
            try await operationTask.value
        }
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
        guard !Task.isCancelled, !timerSchedulingIsSuspendedForAccountBoundary else {
            return .superseded
        }
        let content = notificationContent(
            body: "休憩はここまで。次の一粒へ、ゆっくり戻りましょう。",
            playsSound: playsSound,
            timerCompletionSound: completionSound,
            interruptionLevel: .timeSensitive
        )
        breakNotificationGeneration &+= 1
        let generation = breakNotificationGeneration
        breakNotificationIntents[id] = generation
        let previousTask = breakNotificationOperations[id]?.task
        let operationTask = Task<TimerCompletionNotificationScheduleResult, Error> {
            @MainActor [self] in
            defer {
                if breakNotificationOperations[id]?.generation == generation {
                    breakNotificationOperations.removeValue(forKey: id)
                }
            }
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
        return try await CancellationResponsiveTaskWaiter.value {
            try await operationTask.value
        }
    }

    func cancelBreakCompletion(id: UUID) {
        breakNotificationIntents.removeValue(forKey: id)
        requestClient.removePending(
            [Identifier.breakCompletion(id: id)]
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
        passiveNotificationGeneration &+= 1
    }

    func resumeTimerSchedulingAfterAccountBoundary() {
        timerSchedulingIsSuspendedForAccountBoundary = false
    }

    /// Reset recovery cannot rely on synchronized timer rows still being
    /// present, so it removes every locally scheduled transient request by the
    /// app-owned identifier prefixes.
    func cancelAllTimerNotifications() async {
        await prepareTimerNotificationCleanup()()
    }

    /// Accept a reset synchronously before its cleanup task can be delayed.
    /// New timer registrations made after acceptance retain their intents;
    /// delayed cleanup can remove only earlier requests. A recovered focus in
    /// the current reset epoch can also preserve its existing OS-only request.
    func prepareTimerNotificationCleanup(
        preserving sessionID: UUID? = nil,
        preservingBreak breakID: UUID? = nil
    ) -> @MainActor () async -> Void {
        if sessionID == nil || registeredFocusReturnReminder?.sessionID != sessionID {
            registeredFocusReturnReminder = nil
        }
        if sessionID == nil || focusReturnReminderSessionID != sessionID {
            cancelFocusReturnReminder()
        }
        focusNotificationIntents = focusNotificationIntents.filter { $0.key == sessionID }
        focusNotificationGeneration &+= 1
        breakNotificationIntents = breakNotificationIntents.filter { $0.key == breakID }
        breakNotificationGeneration &+= 1
        let preservedIdentifier = sessionID.map(Identifier.completion(sessionID:))
        let preservedBreakIdentifier = breakID.map(Identifier.breakCompletion(id:))
        return { [self] in
            await removePendingRequests(withPrefix: Identifier.completionPrefix) { identifier in
                identifier != preservedIdentifier && !self.focusNotificationIntents.keys.contains {
                    Identifier.completion(sessionID: $0) == identifier
                }
            }
            await removePendingRequests(withPrefix: Identifier.breakPrefix) { identifier in
                identifier != preservedBreakIdentifier && !self.breakNotificationIntents.keys.contains {
                    Identifier.breakCompletion(id: $0) == identifier
                }
            }
        }
    }

    /// Refreshes the engagement notifications: the daily reminder for the
    /// next 7 days and Wrapped for the next 35.
    ///
    /// On the first of a month, Wrapped takes the daily reminder's slot. Both
    /// notification types remain opt-in and no request ever carries a badge.
    /// `dailyReminderEnabled` and `wrappedEnabled` are the person's intent;
    /// this device books requests only while iOS allows it to deliver them.
    func synchronizePassiveNotifications(
        dailyReminderEnabled: Bool,
        wrappedEnabled: Bool,
        hour: Int,
        minute: Int,
        playsSound: Bool = true,
        activity: PassiveReminderActivity = .unknown,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) async throws {
        guard !Task.isCancelled, !timerSchedulingIsSuspendedForAccountBoundary else { return }
        passiveNotificationGeneration &+= 1
        let generation = passiveNotificationGeneration
        let previous = passiveNotificationTask
        // All daily identifiers share one chain. An older add must finish its
        // cleanup before the replacement is allowed to reuse those identifiers.
        let task = Task { @MainActor in
            defer {
                if self.passiveNotificationGeneration == generation {
                    self.passiveNotificationTask = nil
                }
            }
            if let previous { _ = try? await previous.value }
            guard self.passiveNotificationIntentIsCurrent(generation) else { return }
            try await self.performPassiveNotificationSync(
                dailyReminderEnabled: dailyReminderEnabled,
                wrappedEnabled: wrappedEnabled,
                hour: hour, minute: minute, playsSound: playsSound,
                activity: activity,
                now: now, calendar: calendar, generation: generation
            )
        }
        passiveNotificationTask = task
        // Once accepted, finish this manager-owned transaction even if its
        // Settings view disappears. View cancellation is not an OFF intent:
        // rolling back here would erase enabled reminders without a successor.
        // A newer schedule, explicit cancellation, or account boundary still
        // invalidates the generation and cleans up its in-flight additions.
        do {
            try await CancellationResponsiveTaskWaiter.value { try await task.value }
        } catch is CancellationError {
            // Disappearance releases only this waiter. The accepted schedule
            // remains in the manager's chain until all system callbacks finish.
            return
        }
    }

    private func passiveNotificationIntentIsCurrent(_ generation: UInt64) -> Bool {
        passiveNotificationGeneration == generation
            && !timerSchedulingIsSuspendedForAccountBoundary && !Task.isCancelled
    }

    private func performPassiveNotificationSync(
        dailyReminderEnabled: Bool,
        wrappedEnabled: Bool,
        hour: Int,
        minute: Int,
        playsSound: Bool,
        activity: PassiveReminderActivity,
        now: Date,
        calendar: Calendar,
        generation: UInt64
    ) async throws {
        await removePendingRequests(withPrefix: Identifier.passivePrefix) { _ in
            self.passiveNotificationIntentIsCurrent(generation)
        }
        guard passiveNotificationIntentIsCurrent(generation) else { return }

        guard dailyReminderEnabled || wrappedEnabled else {
            lastErrorDescription = nil
            return
        }

        // The reminder switch is synced, so on a new or reinstalled iPhone it
        // can be on before this device was ever asked. iOS silently drops
        // requests it may not deliver; book nothing, and leave the intent
        // untouched so Settings can offer to allow it here.
        await refreshAuthorizationStatus()
        guard passiveNotificationIntentIsCurrent(generation) else { return }
        guard isAuthorized else {
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

        var addedIdentifiers: [String] = []
        defer {
            if !passiveNotificationIntentIsCurrent(generation) {
                requestClient.removePending(addedIdentifiers)
            }
        }
        do {
            for offset in 0..<IntegrationConstants.passiveNotificationHorizonDays {
                guard passiveNotificationIntentIsCurrent(generation) else { return }
                guard let date = calendar.date(
                    byAdding: .day,
                    value: offset,
                    to: firstDate
                ) else { continue }

                let body: String
                switch PassiveReminderSchedulePolicy.kind(
                    for: date,
                    now: now,
                    dailyReminderEnabled: dailyReminderEnabled,
                    wrappedEnabled: wrappedEnabled,
                    activity: activity,
                    calendar: calendar
                ) {
                case .wrapped:
                    body = "先月の瓶ができた。積み上がりを眺めよう。"
                case .dailyReminder:
                    body = "瓶が待ってる。今日のひと粒、積んでいく？"
                case nil:
                    continue
                }

                let content = notificationContent(
                    body: body,
                    playsSound: playsSound
                )
                // Floating wall-clock components: no calendar and no time
                // zone. A zone copied in here would travel with the archived
                // trigger, so a 20:00 reminder booked in Tokyo would ring at
                // 01:00 in Honolulu until the app is opened again.
                var triggerComponents = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute],
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
                // Include an in-flight identifier so even a late failed add
                // cannot leave a partial schedule behind.
                addedIdentifiers.append(request.identifier)
                try await requestClient.add(request)
                guard passiveNotificationIntentIsCurrent(generation) else { return }
            }
            lastErrorDescription = nil
        } catch {
            requestClient.removePending(addedIdentifiers)
            guard passiveNotificationIntentIsCurrent(generation) else { return }
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func cancelPassiveNotifications() async {
        passiveNotificationGeneration &+= 1
        let generation = passiveNotificationGeneration
        await removePendingRequests(withPrefix: Identifier.passivePrefix) { _ in
            self.passiveNotificationGeneration == generation
        }
    }

    /// Keeps the home screen free from red badge counts even if an older build
    /// or restored notification setting left one behind.
    func clearDeliveredState() async {
        guard !Task.isCancelled else { return }
        await prepareDeliveredStateCleanup()()
    }

    /// Remove delivered notifications at acceptance, before any delayed reset
    /// work can reach a notification delivered for a newer focus.
    func prepareDeliveredStateCleanup() -> @MainActor () async -> Void {
        center.removeAllDeliveredNotifications()
        let center = center
        return { [self] in
            let task = Task { @MainActor in try await center.setBadgeCount(0) }
            do {
                try await CancellationResponsiveTaskWaiter.value { try await task.value }
            } catch {
                guard !Task.isCancelled else { return }
                lastErrorDescription = error.localizedDescription
            }
        }
    }

    /// Only the end of a timer the person started is Time Sensitive: iOS
    /// Focus, Do Not Disturb and Scheduled Summary would otherwise hold the one
    /// alert a locked-phone timer must deliver. Reminders, Wrapped and the
    /// return reminder are nudges and stay `.active`. People can still turn
    /// Time Sensitive off per app or per Focus in iOS Settings.
    private func notificationContent(
        body: String,
        playsSound: Bool,
        timerCompletionSound: TimerCompletionSound? = nil,
        interruptionLevel: UNNotificationInterruptionLevel = .active
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "ポモジェム"
        content.body = body
        content.interruptionLevel = interruptionLevel
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
            try await requestClient.add(request)
        } catch {
            // A failed replacement must not leave its previous trigger armed
            // at the old deadline. The per-identifier chain guarantees that a
            // newer add has not started yet, so this cleanup cannot erase it.
            requestClient.removePending([identifier])
            guard intentIsCurrent() else {
                return .superseded
            }
            lastErrorDescription = error.localizedDescription
            throw error
        }
        guard intentIsCurrent() else {
            requestClient.removePending(
                [identifier]
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

    private func removePendingRequests(
        withPrefix prefix: String,
        shouldRemove: @MainActor (String) -> Bool = { _ in true }
    ) async {
        let pending = await pendingNotificationRequests()
        let identifiers = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(prefix) && shouldRemove($0) }
        guard !identifiers.isEmpty else { return }
        requestClient.removePending(identifiers)
    }

    private func pendingNotificationRequests() async -> [UNNotificationRequest] {
        guard !Task.isCancelled else { return [] }
        let query = requestClient.pending
        let task = Task { @MainActor in await query() }
        return (try? await CancellationResponsiveTaskWaiter.value { await task.value }) ?? []
    }
}
