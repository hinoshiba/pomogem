import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

// F2: while this iPhone runs a PomoGem focus, the apps the user picked as
// 控えたいアプリ can be shielded. Opt-in, free, device-local. Everything the
// monitor extension needs to REMOVE a shield lives here, because a shield
// written through ManagedSettings outlives the process that wrote it: the app
// can be killed, suspended or deleted mid-focus, and the shield would stay.
//
// Three independent removal paths, none of which trusts the others:
// 1. the app clears it when the focus ends (ScreenTimeIntegrationModifier,
//    through `FocusShieldController`);
// 2. a DeviceActivity interval ending at the record's deadline, whose
//    callbacks in PomoGemScreenTimeMonitor clear it
//    (`FocusShieldEngine.handleExtensionInterval`);
// 3. a sweep at every launch and activation that clears an expired record
//    without waiting for persistence (`FocusShieldLaunchSweep`).
//
// This file is compiled into the app AND the monitor extension (project.yml),
// so it holds no user-facing text: the monitor bundle has no string tables.

// MARK: - Policy

enum FocusShieldPolicy {
    /// A dedicated named store: clearing it can never touch another store,
    /// and the most restrictive store wins, so nothing else loosens it.
    static let storeName = ManagedSettingsStore.Name("pomogem.focus-shield")
    /// Deliberately NOT under `ScreenTimePolicy.activityPrefix`: every lane
    /// synchronize stops each prefixed activity it did not ask for
    /// (`ScreenTimeMonitoring.stop()` and the stale teardown), including the
    /// pass triggered by the very timer change that registers this one.
    static let activityName = DeviceActivityName("pomogem.focus-shield")
    /// `ShieldSettings.applications` takes at most 50 tokens; with more, the
    /// system shields nothing at all and reports no error.
    static let maximumApplications = 50
    /// The shield outlives the planned end by this much, so a focus that
    /// completes a moment late (the app advancing its timer, a relaunch) is
    /// never already unshielded, and the failsafe never races the app.
    static let deadlineGrace: TimeInterval = 60
    /// The extension clears when the record's planned end has passed:
    /// `deadline - extensionClearMargin` is the planned end at the last
    /// running state.
    static let extensionClearMargin: TimeInterval = 60
    /// DeviceActivity refuses a shorter interval (`intervalTooShort`).
    static let minimumInterval = ScreenTimePolicy.minimumMonitoringInterval
    /// DeviceActivity refuses a longer one (`intervalTooLong`).
    static let maximumInterval: TimeInterval = 7 * 24 * 60 * 60
    /// How far the interval the framework resolves may sit from the one we
    /// meant. Components carry whole seconds, so the planned end is truncated.
    static let intervalTolerance: TimeInterval = 2
    /// The app gives up on the record lock after this and retries on its
    /// next pass instead of blocking.
    static let appLockTimeout: TimeInterval = 2
    /// The monitor extension is killed for running too long; past this it
    /// decides from an unlocked read of the atomically written record.
    static let extensionLockTimeout: TimeInterval = 3

    /// The deadline is fixed at the most recent RUNNING state: a pause keeps
    /// it, a resume moves it. Leaving PomoGem therefore never needs a
    /// DeviceActivity call, and a paused focus cannot hold a shield forever.
    static func deadline(forPlannedEnd plannedEnd: Date) -> Date {
        plannedEnd.addingTimeInterval(deadlineGrace)
    }

    /// The instant the extension clears from: the planned end at the last
    /// running state.
    static func plannedEnd(forDeadline deadline: Date) -> Date {
        deadline.addingTimeInterval(-extensionClearMargin)
    }

    static func isFailsafeActivity(_ rawName: String) -> Bool {
        rawName == activityName.rawValue
    }

    /// The monitor extension's whole rule. A missing or unreadable record
    /// clears (a stuck shield is worse than a lost one), and so does an
    /// inactive one. It never reads Family Controls authorization: inside the
    /// extension that reads `.notDetermined` on a real device.
    ///
    /// Both callbacks apply it to the record as it is when they run, so a
    /// stale callback — from an interval a resume has since replaced, or one
    /// delivered for an earlier focus — never lifts a live shield whose
    /// planned end is still ahead. The one exception is deliberate: while a
    /// resume is moving the deadline, the record briefly names the new
    /// deadline before `startMonitoring` has accepted it (`failsafeDeadline`
    /// still names the old one). The earlier of the two decides, so the
    /// interval that is actually registered can always clear the shield it
    /// was registered for, even if the app dies in that gap.
    static func extensionShouldClear(_ record: FocusShieldRecord?, now: Date) -> Bool {
        guard let record, record.isValid else { return true }
        guard record.active else { return true }
        let deadline = min(record.deadline, record.failsafeDeadline ?? record.deadline)
        return now >= plannedEnd(forDeadline: deadline)
    }
}

/// Why a shield was removed. Stored in the record and logged, as evidence
/// for device audits: which of the three removal paths actually ran.
enum FocusShieldClearReason: String, Codable, Equatable {
    case focusEnded = "focus-ended"
    case deadlinePassed = "deadline"
    case featureOff = "feature-off"
    case noApplications = "no-apps"
    case tooManyApplications = "too-many-apps"
    case authorizationDenied = "authorization-denied"
    case authorizationRevoked = "authorization-revoked"
    case ownerRetired = "owner-retired"
    case liftedByUser = "user"
    case failsafeUnavailable = "failsafe-unavailable"
    case unreadableRecord = "unreadable-record"
    case launchSweep = "launch-sweep"
    case extensionStart = "extension-start"
    case extensionEnd = "extension-end"
    case erased = "erased"
}

// MARK: - Record

/// What the app and the monitor extension agree on. No tokens: clearing
/// needs none, and the selection stays in the ledger.
struct FocusShieldRecord: Codable, Equatable {
    /// True from just before the shield is written until it is cleared.
    var active: Bool
    /// The focus session the shield belongs to (`PomodoroEngine.currentSessionID`).
    var sessionID: UUID
    /// Planned end at the last running state plus `deadlineGrace`.
    var deadline: Date
    var appliedAt: Date
    /// The user lifted the shield for this session (「今すぐ制限を解除」).
    /// The same session is never shielded again; the next focus is.
    var liftedAt: Date?
    var clearedAt: Date?
    /// A `FocusShieldClearReason` raw value, kept as a string so a value
    /// from a newer build still decodes.
    var clearedBy: String?
    /// The deadline the registered failsafe interval was built for, written
    /// only after `startMonitoring` accepted it and reset whenever the shield
    /// comes down. Whether the interval still has to be registered is decided
    /// from this, not from `DeviceActivityCenter.activities`, which keeps
    /// listing a name whose non-repeating interval has already ended.
    var failsafeDeadline: Date?

    var isValid: Bool {
        [deadline, appliedAt, liftedAt, clearedAt, failsafeDeadline].allSatisfy {
            $0?.timeIntervalSince1970.isFinite != false
        }
    }
}

/// `ScreenTime/focus-shield.json` in the App Group, next to the ledger but in
/// its own file under its own lock: the ledger is owner-bound and is replaced
/// on rebind and reset, while a shield must be removable whoever owns it, and
/// the extension must be able to read it without decoding the whole ledger.
/// Same discipline as `ScreenTimeStore`: flock on a stable inode, atomic
/// replacement, protected until first unlock, excluded from backup.
final class FocusShieldRecordStore {
    private let directory: URL?

    /// `directory` is the ScreenTime folder itself (`ScreenTimeStore.directoryURL`).
    init(directory: URL?) {
        self.directory = directory
    }

    static func appGroupDirectory() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ScreenTimeStore.appGroupID)?
            .appendingPathComponent("ScreenTime", isDirectory: true)
    }

    private var recordURL: URL? { directory?.appendingPathComponent("focus-shield.json") }

    /// Whether a record file exists. Checked before anything touches
    /// ManagedSettings on a path every launch runs, so people who never used
    /// the shield never reach the framework.
    var exists: Bool {
        guard let recordURL else { return false }
        return FileManager.default.fileExists(atPath: recordURL.path)
    }

    /// An unlocked read. Safe because every write replaces the file
    /// atomically. nil when there is no record; throws `corruptedState` for
    /// one that cannot be decoded or holds non-finite dates.
    func load() throws -> FocusShieldRecord? {
        guard let recordURL else { throw ScreenTimeError.unavailable }
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
        do {
            let record = try JSONDecoder().decode(FocusShieldRecord.self, from: Data(contentsOf: recordURL))
            guard record.isValid else { throw ScreenTimeError.corruptedState }
            return record
        } catch {
            throw ScreenTimeError.corruptedState
        }
    }

    /// Read-modify-write under the record lock. Setting the record to nil
    /// removes the file. `timeout` bounds the wait (`unavailable` after it).
    @discardableResult
    func update<T>(timeout: TimeInterval?, _ operation: (inout FocusShieldRecord?) throws -> T) throws -> T {
        try withLock(timeout: timeout) {
            var record = try load()
            let before = record
            let result = try operation(&record)
            if record != before { try write(record) }
            return result
        }
    }

    /// Removes the record whatever it holds, readable or not.
    func remove(timeout: TimeInterval?) throws {
        try withLock(timeout: timeout) { try write(nil) }
    }

    private func write(_ record: FocusShieldRecord?) throws {
        guard let recordURL else { throw ScreenTimeError.unavailable }
        guard let record else {
            if FileManager.default.fileExists(atPath: recordURL.path) {
                try FileManager.default.removeItem(at: recordURL)
            }
            return
        }
        guard record.isValid else { throw ScreenTimeError.corruptedState }
        try JSONEncoder().encode(record).write(
            to: recordURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func withLock<T>(timeout: TimeInterval?, _ operation: () throws -> T) throws -> T {
        guard let directory else { throw ScreenTimeError.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var localDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try localDirectory.setResourceValues(values)
        let path = directory.appendingPathComponent("focus-shield.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ScreenTimeError.unavailable }
        defer { close(descriptor) }
        try ScreenTimeStore.lockExclusively(descriptor, timeout: timeout)
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

// MARK: - ManagedSettings

protocol FocusShieldSettingsDriving: AnyObject {
    func shield(applications: Set<ApplicationToken>)
    func clear()
}

/// The one place PomoGem writes ManagedSettings. The store is created per
/// call, so a process that never shields never touches the framework.
final class ManagedSettingsFocusShield: FocusShieldSettingsDriving {
    func shield(applications: Set<ApplicationToken>) {
        let store = ManagedSettingsStore(named: FocusShieldPolicy.storeName)
        store.shield.applications = applications.isEmpty ? nil : applications
    }

    func clear() {
        ManagedSettingsStore(named: FocusShieldPolicy.storeName).clearAllSettings()
    }
}

// MARK: - Failsafe schedule

/// The kill-proof removal: one non-repeating DeviceActivity interval that
/// ends at the record's deadline. Its callbacks reach the monitor extension
/// even if PomoGem is never opened again.
///
/// DeviceActivity refuses intervals shorter than 15 minutes, so the start is
/// `min(now, deadline - 15 min)`: a short focus gets an interval that started
/// in the past and still ends exactly at its deadline. The framework's own
/// `nextInterval` must confirm the interval contains now and ends at the
/// deadline before anything is registered; a form it resolves differently
/// (midnight, a daylight-saving change) falls through to the next form.
enum FocusShieldSchedule {
    enum Form: String, CaseIterable {
        /// Hour/minute/second on both ends, as the design asks: community
        /// reports say mixing date and time-only components suppresses
        /// callbacks, and time-only ones are what most apps register.
        case timeOfDay = "time-of-day"
        /// Full local date components with the time zone, the form the gem
        /// lanes register and the device audit saw start.
        case localDate = "local-date"
        /// Full UTC date components: unambiguous in a repeated DST hour.
        case utcDate = "utc-date"
    }

    struct Plan {
        let form: Form
        let schedule: DeviceActivitySchedule
        /// The instants the components are meant to denote.
        let start: Date
        let end: Date
    }

    enum RegistrationError: Error, Equatable {
        /// No form was both representable and confirmed by the framework,
        /// or the framework refused every one that was.
        case noAcceptableInterval
    }

    /// Whole seconds, because the components carry nothing finer.
    static func truncated(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
    }

    static func intervalBounds(deadline: Date, now: Date) -> (start: Date, end: Date) {
        let end = truncated(deadline)
        let start = truncated(min(now, end.addingTimeInterval(-FocusShieldPolicy.minimumInterval)))
        return (start, end)
    }

    /// Every candidate, in the order they are tried, each already checked to
    /// denote exactly `start...end` in `calendar` (so a nonexistent or
    /// repeated local time never reaches the framework).
    static func plans(deadline: Date, now: Date, calendar: Calendar) -> [Plan] {
        let (start, end) = intervalBounds(deadline: deadline, now: now)
        guard end > now, end.timeIntervalSince(start) >= FocusShieldPolicy.minimumInterval,
              end.timeIntervalSince(start) <= FocusShieldPolicy.maximumInterval else { return [] }
        return Form.allCases.compactMap { plan(form: $0, start: start, end: end, calendar: calendar) }
    }

    static func plan(form: Form, start: Date, end: Date, calendar: Calendar) -> Plan? {
        switch form {
        case .timeOfDay:
            let units: Set<Calendar.Component> = [.hour, .minute, .second]
            let startComponents = calendar.dateComponents(units, from: start)
            let endComponents = calendar.dateComponents(units, from: end)
            // The time of day must name `start` itself and then, as its next
            // occurrence, `end` — never a repeated or skipped DST hour, and
            // never a day later.
            guard calendar.nextDate(after: start.addingTimeInterval(-1), matching: startComponents,
                                    matchingPolicy: .strict, repeatedTimePolicy: .first) == start,
                  calendar.nextDate(after: start, matching: endComponents,
                                    matchingPolicy: .strict, repeatedTimePolicy: .first) == end
            else { return nil }
            return Plan(form: form, schedule: DeviceActivitySchedule(
                intervalStart: startComponents, intervalEnd: endComponents, repeats: false
            ), start: start, end: end)
        case .localDate, .utcDate:
            var zoned = Calendar(identifier: .gregorian)
            zoned.timeZone = form == .utcDate ? TimeZone(identifier: "UTC")! : calendar.timeZone
            let units: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
            var startComponents = zoned.dateComponents(units, from: start)
            var endComponents = zoned.dateComponents(units, from: end)
            startComponents.timeZone = zoned.timeZone
            endComponents.timeZone = zoned.timeZone
            guard zoned.date(from: startComponents) == start, zoned.date(from: endComponents) == end
            else { return nil }
            return Plan(form: form, schedule: DeviceActivitySchedule(
                intervalStart: startComponents, intervalEnd: endComponents, repeats: false
            ), start: start, end: end)
        }
    }

    /// Whether the interval the framework resolved is the one we meant: it
    /// contains now and ends at the deadline.
    static func accepts(_ interval: DateInterval?, plan: Plan, now: Date) -> Bool {
        guard let interval else { return false }
        let tolerance = FocusShieldPolicy.intervalTolerance
        return interval.start <= now.addingTimeInterval(tolerance)
            && interval.end > now
            && abs(interval.end.timeIntervalSince(plan.end)) <= tolerance
            && abs(interval.start.timeIntervalSince(plan.start)) <= tolerance
    }

    /// Registers the failsafe under its one fixed name (`startMonitoring`
    /// replaces an earlier schedule of that name). Returns the form used.
    @discardableResult
    static func register(
        center: ScreenTimeActivityCenterDriving,
        deadline: Date,
        now: Date,
        calendar: Calendar,
        resolveInterval: (DeviceActivitySchedule) -> DateInterval?
    ) throws -> Form {
        var lastError: Error = RegistrationError.noAcceptableInterval
        for plan in plans(deadline: deadline, now: now, calendar: calendar) {
            guard accepts(resolveInterval(plan.schedule), plan: plan, now: now) else {
                ScreenTimeLog.monitoring.notice(
                    "focus-shield schedule rejected form=\(plan.form.rawValue, privacy: .public)")
                continue
            }
            do {
                try center.startMonitoring(FocusShieldPolicy.activityName, during: plan.schedule, events: [:])
                return plan.form
            } catch {
                ScreenTimeLog.monitoring.error("""
                    focus-shield schedule refused form=\(plan.form.rawValue, privacy: .public) \
                    error=\(String(describing: error), privacy: .public)
                    """)
                lastError = error
            }
        }
        throw lastError
    }
}

// MARK: - Engine

/// Applies and removes the shield. Every step re-reads the record under its
/// lock, so repeated or stale requests converge instead of fighting, and the
/// app and the extension can never interleave a clear with an apply.
///
/// Ordering is what makes it safe to die at any point:
/// - apply: record (active) → failsafe interval → shield. A shield never
///   exists without a record that says when it ends and an interval that
///   ends it.
/// - clear: shield → record (inactive) → stop the interval by its name.
///
/// Unchecked because all storage is immutable and every call is serialized:
/// in the app on `FocusShieldAppQueue`, in the extension on the one callback
/// thread; the record's flock orders the two processes.
final class FocusShieldEngine: @unchecked Sendable {
    enum Outcome: Equatable {
        case applied(registered: Bool)
        case kept
        case cleared
        case unchanged
        /// The failsafe interval could not be registered, so nothing is
        /// shielded: a shield without a kill-proof end is never written.
        case failsafeUnavailable
    }

    let records: FocusShieldRecordStore
    private let settings: FocusShieldSettingsDriving
    private let center: ScreenTimeActivityCenterDriving
    private let calendar: () -> Calendar
    private let resolveInterval: (DeviceActivitySchedule) -> DateInterval?
    private let lockTimeout: TimeInterval?

    init(
        records: FocusShieldRecordStore,
        settings: FocusShieldSettingsDriving,
        center: ScreenTimeActivityCenterDriving,
        calendar: @escaping () -> Calendar = { Calendar.current },
        resolveInterval: @escaping (DeviceActivitySchedule) -> DateInterval? = { $0.nextInterval },
        lockTimeout: TimeInterval? = FocusShieldPolicy.appLockTimeout
    ) {
        self.records = records
        self.settings = settings
        self.center = center
        self.calendar = calendar
        self.resolveInterval = resolveInterval
        self.lockTimeout = lockTimeout
    }

    static func live(
        directory: URL? = FocusShieldRecordStore.appGroupDirectory(),
        lockTimeout: TimeInterval? = FocusShieldPolicy.appLockTimeout
    ) -> FocusShieldEngine {
        FocusShieldEngine(records: FocusShieldRecordStore(directory: directory),
                          settings: ManagedSettingsFocusShield(), center: DeviceActivityCenter(),
                          lockTimeout: lockTimeout)
    }

    /// Shields `applications` for `sessionID` until `deadline`, registering
    /// the failsafe unless the record says this very deadline already has one.
    func apply(sessionID: UUID, deadline: Date, applications: Set<ApplicationToken>, now: Date) throws -> Outcome {
        // The controller never asks for these; they are refused here too so
        // no caller can write a shield that ends in the past or shields
        // nothing at all (more than 50 tokens silently shields nothing).
        if let refusal = Self.refusal(deadline: deadline, applications: applications, now: now) {
            return try clear(reason: refusal, now: now)
        }
        let previous: FocusShieldRecord?
        do {
            previous = try records.update(timeout: lockTimeout) { record -> FocusShieldRecord? in
                let old = record
                // A session the user lifted stays lifted.
                if old?.sessionID == sessionID, old?.liftedAt != nil { return old }
                let continuing = old?.active == true && old?.sessionID == sessionID
                record = FocusShieldRecord(active: true, sessionID: sessionID, deadline: deadline,
                                           appliedAt: continuing ? old!.appliedAt : now,
                                           failsafeDeadline: continuing ? old?.failsafeDeadline : nil)
                return old
            }
        } catch ScreenTimeError.corruptedState {
            try recoverUnreadableRecord(now: now)
            return try apply(sessionID: sessionID, deadline: deadline, applications: applications, now: now)
        }
        if previous?.sessionID == sessionID, previous?.liftedAt != nil { return .unchanged }
        // Only a registration this record confirmed for this deadline counts:
        // a name still listed by `activities` may belong to an interval that
        // has already ended (an earlier focus, or a run that died between
        // writing the record and registering).
        let armed = previous?.active == true && previous?.sessionID == sessionID
            && previous?.failsafeDeadline == deadline
        var registered = false
        if !armed || !center.activities.contains(FocusShieldPolicy.activityName) {
            do {
                let form = try FocusShieldSchedule.register(
                    center: center, deadline: deadline, now: now,
                    calendar: calendar(), resolveInterval: resolveInterval)
                registered = true
                ScreenTimeLog.monitoring.notice("""
                    focus-shield failsafe registered form=\(form.rawValue, privacy: .public) \
                    endOffsetSec=\(ScreenTimeDiagnosticSeconds.between(deadline, now), privacy: .public)
                    """)
            } catch {
                _ = try? clear(reason: .failsafeUnavailable, now: now)
                return .failsafeUnavailable
            }
        }
        let shielded = try records.update(timeout: lockTimeout) { record -> Bool in
            guard var current = record, current.active, current.sessionID == sessionID,
                  current.deadline == deadline else { return false }
            current.failsafeDeadline = deadline
            record = current
            settings.shield(applications: applications)
            return true
        }
        guard shielded else { return .unchanged }
        ScreenTimeLog.monitoring.notice("""
            focus-shield applied apps=\(applications.count, privacy: .public) \
            registered=\(registered ? 1 : 0, privacy: .public)
            """)
        return .applied(registered: registered)
    }

    /// A paused focus: the shield stays with the deadline it already has.
    /// Registers nothing unless the record has no confirmed failsafe for
    /// that deadline or the interval has disappeared.
    func keep(applications: Set<ApplicationToken>, now: Date) throws -> Outcome {
        let record: FocusShieldRecord?
        do { record = try records.load() } catch ScreenTimeError.corruptedState {
            try recoverUnreadableRecord(now: now)
            return .cleared
        }
        guard let record, record.active else { return .unchanged }
        if let refusal = Self.refusal(deadline: record.deadline, applications: applications, now: now) {
            return try clear(reason: refusal, now: now)
        }
        if record.failsafeDeadline != record.deadline || !center.activities.contains(FocusShieldPolicy.activityName) {
            do {
                try FocusShieldSchedule.register(center: center, deadline: record.deadline, now: now,
                                                 calendar: calendar(), resolveInterval: resolveInterval)
            } catch {
                _ = try? clear(reason: .failsafeUnavailable, now: now)
                return .failsafeUnavailable
            }
        }
        let kept = try records.update(timeout: lockTimeout) { current -> Bool in
            guard var same = current, same.active, same.sessionID == record.sessionID,
                  same.deadline == record.deadline else { return false }
            same.failsafeDeadline = record.deadline
            current = same
            settings.shield(applications: applications)
            return true
        }
        return kept ? .kept : .unchanged
    }

    /// Removes an active shield. `unconditional` also clears the store and
    /// stops the interval when the record says nothing is active.
    @discardableResult
    func clear(reason: FocusShieldClearReason, now: Date, unconditional: Bool = false) throws -> Outcome {
        let cleared: Bool
        do {
            cleared = try records.update(timeout: lockTimeout) { record -> Bool in
                guard record?.active == true || unconditional else { return false }
                settings.clear()
                if var active = record, active.active {
                    active.active = false
                    active.clearedAt = now
                    active.clearedBy = reason.rawValue
                    active.failsafeDeadline = nil
                    record = active
                }
                return true
            }
        } catch ScreenTimeError.corruptedState {
            try recoverUnreadableRecord(now: now)
            return .cleared
        }
        guard cleared else { return .unchanged }
        stopFailsafe()
        ScreenTimeLog.monitoring.notice("focus-shield cleared reason=\(reason.rawValue, privacy: .public)")
        return .cleared
    }

    /// 「今すぐ制限を解除」: lifts the shield for this session only.
    func lift(sessionID: UUID, now: Date) throws -> Outcome {
        let lifted = try records.update(timeout: lockTimeout) { record -> Bool in
            guard var active = record, active.active, active.sessionID == sessionID else { return false }
            settings.clear()
            active.active = false
            active.failsafeDeadline = nil
            active.liftedAt = now
            active.clearedAt = now
            active.clearedBy = FocusShieldClearReason.liftedByUser.rawValue
            record = active
            return true
        }
        guard lifted else { return .unchanged }
        stopFailsafe()
        ScreenTimeLog.monitoring.notice("focus-shield cleared reason=user")
        return .cleared
    }

    /// Complete data deletion: clear the store, stop the interval and remove
    /// the record, whatever state any of them is in.
    func eraseAll() throws {
        settings.clear()
        stopFailsafe()
        do {
            // Longer than an ordinary pass: deletion must not fail because
            // the extension was mid-callback.
            try records.remove(timeout: lockTimeout.map { max($0, FocusShieldPolicy.extensionLockTimeout + 2) })
        } catch ScreenTimeError.unavailable where !records.exists {
            // No App Group: there was never a record to remove.
        }
        ScreenTimeLog.monitoring.notice("focus-shield cleared reason=erased")
    }

    private static func refusal(
        deadline: Date, applications: Set<ApplicationToken>, now: Date
    ) -> FocusShieldClearReason? {
        if now >= deadline { return .deadlinePassed }
        if applications.isEmpty { return .noApplications }
        if applications.count > FocusShieldPolicy.maximumApplications { return .tooManyApplications }
        return nil
    }

    /// Launch and activation, before any persistence is admitted: only the
    /// record and the clock decide. No record means nothing to do, and the
    /// framework is not touched.
    @discardableResult
    func sweepExpired(now: Date) -> Outcome {
        guard records.exists else { return .unchanged }
        do {
            let record = try records.load()
            guard let record, record.active, now >= record.deadline else { return .unchanged }
            return try clear(reason: .launchSweep, now: now)
        } catch ScreenTimeError.corruptedState {
            try? recoverUnreadableRecord(now: now)
            return .cleared
        } catch {
            return .unchanged
        }
    }

    /// PomoGemScreenTimeMonitor's `intervalDidStart`/`intervalDidEnd` for
    /// `FocusShieldPolicy.activityName`. Clears when the record is inactive,
    /// missing, unreadable or at its planned end. Returns whether it cleared.
    ///
    /// Under the record lock when it can get it, so an apply for a new
    /// session is never wiped by a callback for the old one. If the app holds
    /// the lock past the timeout (typically while it registers this very
    /// interval), the atomically written record is read without the lock and
    /// the same rule applies.
    @discardableResult
    func handleExtensionInterval(phase: ScreenTimeCallbackCounters.IntervalPhase, now: Date) -> Bool {
        let reason: FocusShieldClearReason = phase == .start ? .extensionStart : .extensionEnd
        do {
            return try records.update(timeout: FocusShieldPolicy.extensionLockTimeout) { record -> Bool in
                guard FocusShieldPolicy.extensionShouldClear(record, now: now) else { return false }
                settings.clear()
                if var active = record, active.active {
                    active.active = false
                    active.clearedAt = now
                    active.clearedBy = reason.rawValue
                    active.failsafeDeadline = nil
                    record = active
                }
                return true
            }
        } catch {
            // `try?` flattens: nil for a missing and for an unreadable record.
            let record: FocusShieldRecord? = try? records.load()
            guard FocusShieldPolicy.extensionShouldClear(record, now: now) else { return false }
            settings.clear()
            return true
        }
    }

    /// An unreadable record cannot say whether a shield is up, so assume one
    /// is: clear, stop the interval, and start over without a record.
    private func recoverUnreadableRecord(now: Date) throws {
        settings.clear()
        stopFailsafe()
        try records.remove(timeout: lockTimeout)
        ScreenTimeLog.monitoring.notice("focus-shield cleared reason=unreadable-record")
    }

    /// Only ever by name: `stopMonitoring([])` stops every activity,
    /// including the gem lanes.
    private func stopFailsafe() {
        guard center.activities.contains(FocusShieldPolicy.activityName) else { return }
        center.stopMonitoring([FocusShieldPolicy.activityName])
    }
}
