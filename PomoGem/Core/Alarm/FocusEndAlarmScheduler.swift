import Foundation

/// Which phase's end an alarm announces.
enum FocusEndAlarmPhase: String, Codable, Sendable {
    case focus
    case breakTime = "break"
}

/// The one AlarmKit alarm this device has booked, persisted device-locally
/// before the booking starts (write-ahead) so a process that dies mid-booking
/// still knows which alarm to cancel at the next launch.
struct FocusEndAlarmBooking: Codable, Equatable, Sendable {
    let alarmID: UUID
    let sessionID: UUID
    let phase: FocusEndAlarmPhase
    let fireDate: Date
    /// The Library/Sounds file the alarm plays, or nil for the system alarm
    /// sound. A later booking for the same end with the same sound keeps
    /// this alarm instead of replacing it.
    let soundFileName: String?
    /// True once AlarmKit accepted the alarm, or later listed it. A
    /// write-ahead record that was never confirmed proves nothing could
    /// ring, so it is never a delivery witness.
    var isConfirmed: Bool

    init(
        alarmID: UUID,
        sessionID: UUID,
        phase: FocusEndAlarmPhase,
        fireDate: Date,
        soundFileName: String? = nil,
        isConfirmed: Bool = false
    ) {
        self.alarmID = alarmID
        self.sessionID = sessionID
        self.phase = phase
        self.fireDate = fireDate
        self.soundFileName = soundFileName
        self.isConfirmed = isConfirmed
    }

    private enum CodingKeys: String, CodingKey {
        case alarmID, sessionID, phase, fireDate, soundFileName, isConfirmed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alarmID = try container.decode(UUID.self, forKey: .alarmID)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        phase = try container.decode(FocusEndAlarmPhase.self, forKey: .phase)
        fireDate = try container.decode(Date.self, forKey: .fireDate)
        soundFileName = try container.decodeIfPresent(String.self, forKey: .soundFileName)
        isConfirmed = try container.decodeIfPresent(Bool.self, forKey: .isConfirmed) ?? false
    }
}

/// What the system reports about one of this app's alarms.
struct FocusEndAlarmSnapshot: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case scheduled
        case alerting
        /// Countdown or paused: never used by this app (alert-only alarms).
        case other
    }

    let id: UUID
    let state: State
}

/// Everything the system alarm shows and plays.
struct FocusEndAlarmRequest: Equatable, Sendable {
    let alarmID: UUID
    let phase: FocusEndAlarmPhase
    let fireDate: Date
    /// A file in Library/Sounds (`AlarmSoundLibrary`), or nil for the system
    /// alarm sound.
    let soundFileName: String?
}

/// The AlarmKit boundary. The live client exists on iOS 26+ only; tests use
/// a fake, so the scheduler's state machine never touches the system.
@MainActor
protocol FocusEndAlarmClient: AnyObject {
    var authorization: AlarmKitAuthorization { get }
    func requestAuthorization() async -> AlarmKitAuthorization
    func schedule(_ request: FocusEndAlarmRequest) async throws
    func cancel(id: UUID) throws
    func stop(id: UUID) throws
    func alarms() throws -> [FocusEndAlarmSnapshot]
}

/// iOS 17–25, or a build without AlarmKit.
@MainActor
final class UnsupportedFocusEndAlarmClient: FocusEndAlarmClient {
    struct Unsupported: Error {}

    var authorization: AlarmKitAuthorization { .unsupported }
    func requestAuthorization() async -> AlarmKitAuthorization { .unsupported }
    func schedule(_ request: FocusEndAlarmRequest) async throws { throw Unsupported() }
    func cancel(id: UUID) throws {}
    func stop(id: UUID) throws {}
    func alarms() throws -> [FocusEndAlarmSnapshot] { [] }
}

/// Device-local persistence (`UserDefaults.standard`, never synced). Complete
/// data deletion clears it with the rest of the standard domain.
struct FocusEndAlarmBookingStore {
    static let defaultsKey = "alarm.focus-end.booking.v1"
    /// Alarms whose cancel failed while the system still listed them. They
    /// are stale by definition and retried until they are gone.
    static let pendingCancelsKey = "alarm.focus-end.pending-cancels.v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> FocusEndAlarmBooking? {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(FocusEndAlarmBooking.self, from: data)
    }

    func save(_ booking: FocusEndAlarmBooking) {
        guard let data = try? JSONEncoder().encode(booking) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    var pendingCancelIDs: [UUID] {
        (defaults.stringArray(forKey: Self.pendingCancelsKey) ?? []).compactMap(UUID.init(uuidString:))
    }

    func setPendingCancelIDs(_ ids: [UUID]) {
        if ids.isEmpty {
            defaults.removeObject(forKey: Self.pendingCancelsKey)
        } else {
            defaults.set(ids.map(\.uuidString), forKey: Self.pendingCancelsKey)
        }
    }
}

/// The running phase this device owns, as the launch host sees it.
struct FocusEndAlarmOwner: Equatable, Sendable {
    let sessionID: UUID
    let phase: FocusEndAlarmPhase
    /// Nil while paused: a paused timer has no end to announce.
    let endDate: Date?
}

/// What a reconcile found.
struct FocusEndAlarmReconciliation: Equatable, Sendable {
    /// Alarms to cancel: orphans and stale bookings, never one that is
    /// alerting right now. Cancelling an ID the system no longer lists is
    /// harmless, so a forgotten booking's ID is always included.
    var cancelIDs: [UUID] = []
    /// Forget the persisted booking.
    var clearsBooking = false
    /// The system lists the booked alarm that was not confirmed yet (the
    /// process ended before `schedule` returned): record it as confirmed.
    var confirmsBooking = false
    /// The owner is running without a matching alarm; the caller books one
    /// if the channel policy still wants a system alarm.
    var ownerNeedsBooking = false
}

/// Pure reconcile rules for the one booked alarm (at launch and whenever the
/// app becomes active).
enum FocusEndAlarmReconcilePolicy {
    /// A fire date this far from the owner's end still counts as the same end.
    static let fireDateTolerance: TimeInterval = 1

    /// `inFlightAlarmIDs` are alarms a `schedule` in this process is still
    /// booking, or replacing (it cancels those once the new alarm is
    /// booked). The system may not list a new one yet, and the newest one
    /// is the booking itself: they are neither orphans nor vanished, so
    /// reconcile leaves them to `schedule`.
    static func reconcile(
        booking: FocusEndAlarmBooking?,
        alarms: [FocusEndAlarmSnapshot],
        owner: FocusEndAlarmOwner?,
        now: Date,
        inFlightAlarmIDs: Set<UUID> = []
    ) -> FocusEndAlarmReconciliation {
        var result = FocusEndAlarmReconciliation()
        // Anything that is not the booked alarm is an orphan (for example a
        // booking lost to a crash). Leave an alerting one to the person.
        result.cancelIDs = alarms
            .filter {
                $0.id != booking?.alarmID
                    && !inFlightAlarmIDs.contains($0.id)
                    && $0.state != .alerting
            }
            .map(\.id)

        let ownerIsRunning = owner?.endDate != nil
        guard let booking else {
            result.ownerNeedsBooking = ownerIsRunning
            return result
        }
        if inFlightAlarmIDs.contains(booking.alarmID) {
            // Still being booked: `schedule` decides, and a cancel or a newer
            // booking already supersedes it through the generation fence.
            return result
        }

        let snapshot = alarms.first { $0.id == booking.alarmID }
        if snapshot?.state == .alerting {
            // Ringing now, so it is real. Returning to the app is what stops
            // it (as Stop): the completion flow acknowledges it. Never cancel
            // it here.
            result.confirmsBooking = !booking.isConfirmed
            return result
        }
        let hasFired = booking.fireDate <= now
        if snapshot == nil {
            // Gone from the system. Only a confirmed alarm whose time came
            // can have rung and been dismissed; it stays as the delivery
            // witness until another session owns the timer.
            if hasFired,
               booking.isConfirmed,
               owner == nil || owner?.sessionID == booking.sessionID {
                return result
            }
            // Vanished before its time (alarms turned off in Settings), never
            // registered (a write-ahead record from a process that died), or
            // a witness for a replaced session.
            result.cancelIDs.append(booking.alarmID)
            result.clearsBooking = true
            result.ownerNeedsBooking = ownerIsRunning
            return result
        }

        let matchesOwner: Bool = {
            guard let owner, owner.sessionID == booking.sessionID,
                  owner.phase == booking.phase,
                  let endDate = owner.endDate else { return false }
            return abs(endDate.timeIntervalSince(booking.fireDate)) <= fireDateTolerance
        }()
        // Past its time but not rung yet for the same session: the system is
        // about to ring, and the completion flow of that session resolves it.
        if matchesOwner || (hasFired && owner?.sessionID == booking.sessionID) {
            result.confirmsBooking = !booking.isConfirmed
            return result
        }
        // Abandoned, paused, adopted by another device, or re-timed: a stale
        // alarm must never ring later.
        result.cancelIDs.append(booking.alarmID)
        result.clearsBooking = true
        result.ownerNeedsBooking = ownerIsRunning
        return result
    }
}

enum FocusEndAlarmScheduleResult: Equatable, Sendable {
    case booked(FocusEndAlarmBooking)
    /// iOS 17–25 or no AlarmKit.
    case unsupported
    /// Alarms are not allowed (yet). Never asks by itself.
    case notAuthorized
    /// The end is too close for a system alarm to be useful.
    case tooSoon
    /// A cancel, hand-off, erase or newer booking arrived while this one was
    /// in flight; the alarm it created, if any, was cancelled. This is NOT a
    /// failure: whichever call superseded it owns the end now, so the
    /// caller must not fall back to a notification for it.
    case superseded
    /// AlarmKit refused the booking. The caller falls back to
    /// `AlarmChannelPolicy.notificationChannel`.
    case failed
}


/// Owns the single AlarmKit alarm for the end of this device's running focus
/// or break (F5, maximum strength). All mutations are serialized on the main
/// actor and fenced by a generation, like `NotificationManager`: a cancel that
/// arrives while a booking is in flight wins, and the late booking removes
/// its own alarm. The fence starts at the `schedule` call itself, before the
/// ringtone file is ready: a pause during that wait books nothing.
///
/// Phase B wiring, in order of the timer's life:
/// - start, resume, recovery, every activation of a running timer:
///   `schedule` (a result other than `.booked` or `.superseded` falls back
///   to the notification channel). Booking the same end with the same sound
///   again keeps the alarm, so rebooking on activation is free;
/// - pause, abandon, early finish, ownership loss: `cancel(sessionID:)`;
/// - the app active just before the end (`AlarmChannelPolicy
///   .shouldHandOffToForeground`): `handOffToForeground`, and book
///   `AlarmChannelPolicy.channelAfterLeavingDuringHandoff` if the scene stops
///   being active before that end;
/// - the completion resolved in the app: read `deliveryWitnessFireDate` for
///   the cue, and `acknowledge` (Stop while it rings). Both keep an alarm
///   that rang as the witness, so their order does not matter;
/// - launch and every foreground: `reconcile(owner:)`, which also retries
///   failed cancels;
/// - account change, complete data deletion: `cancelAll`; an Apple Account
///   boundary: `abandonBookingsInFlight`.
@MainActor
final class FocusEndAlarmScheduler {
    static let shared = FocusEndAlarmScheduler(client: FocusEndAlarmClientFactory.live())

    /// The newest `schedule` call while it runs. A cancel, hand-off,
    /// acknowledge or erase of its session supersedes it even before its
    /// write-ahead record exists (while the ringtone is still rendering).
    private struct BookingIntent {
        let generation: UInt64
        let sessionID: UUID
        let endDate: Date
    }

    private let client: FocusEndAlarmClient
    private let store: FocusEndAlarmBookingStore
    private let now: () -> Date
    private let makeAlarmID: () -> UUID
    private var generation: UInt64 = 0
    private var pendingIntent: BookingIntent?
    /// Alarms a `schedule` in this process is still booking or replacing:
    /// the new one until `client.schedule` returns, and the one it replaces
    /// until the new one is booked.
    private var inFlightAlarmIDs: Set<UUID> = []

    init(
        client: FocusEndAlarmClient,
        store: FocusEndAlarmBookingStore = FocusEndAlarmBookingStore(),
        now: @escaping () -> Date = Date.init,
        makeAlarmID: @escaping () -> UUID = UUID.init
    ) {
        self.client = client
        self.store = store
        self.now = now
        self.makeAlarmID = makeAlarmID
    }

    var authorization: AlarmKitAuthorization { client.authorization }

    /// Asks for permission. Call only from an explicit choice of the maximum
    /// preset, never from a timer start.
    func requestAuthorization() async -> AlarmKitAuthorization {
        guard client.authorization == .notDetermined else { return client.authorization }
        return await client.requestAuthorization()
    }

    var booking: FocusEndAlarmBooking? { store.load() }

    /// The fire date of `sessionID`'s alarm once it may have rung: a delivery
    /// witness, like an accepted notification
    /// (`AlarmChannelPolicy.externalAlertMayHaveFired`). Nil unless AlarmKit
    /// confirmed the alarm, alarms are still allowed, the fire date has
    /// passed, and the system is ringing it or no longer lists it (a system
    /// that still lists it as scheduled has not rung it yet). Reading it
    /// changes nothing.
    func deliveryWitnessFireDate(sessionID: UUID) -> Date? {
        guard let booking = store.load(),
              booking.sessionID == sessionID,
              booking.isConfirmed,
              booking.fireDate <= now(),
              client.authorization == .authorized,
              let alarms = try? client.alarms()
        else { return nil }
        let state = alarms.first { $0.id == booking.alarmID }?.state
        guard state == nil || state == .alerting else { return nil }
        return booking.fireDate
    }

    /// `schedule(sessionID:phase:endDate:soundFile:)` with a file name that
    /// is already known.
    func schedule(
        sessionID: UUID,
        phase: FocusEndAlarmPhase,
        endDate: Date,
        soundFileName: String?
    ) async -> FocusEndAlarmScheduleResult {
        await schedule(sessionID: sessionID, phase: phase, endDate: endDate) { soundFileName }
    }

    /// Books the one alarm for `endDate`, replacing any earlier booking. A
    /// call that books nothing (no permission, too soon) still silences the
    /// earlier alarm; only an alarm of the same session that has already
    /// rung stays, as that session's delivery witness.
    ///
    /// `soundFile` gives the Library/Sounds file name (nil: the system alarm
    /// sound). It is awaited only once AlarmKit will be asked, and it may
    /// render the ringtone first. The call is fenced from its first line: a
    /// cancel, hand-off or acknowledge of `sessionID`, an erase, an account
    /// boundary or a newer booking that arrives while the file is prepared
    /// or while AlarmKit books makes this call book nothing
    /// (`.superseded`).
    ///
    /// The same end (within `FocusEndAlarmReconcilePolicy.fireDateTolerance`)
    /// with the same sound keeps the confirmed alarm the system still lists
    /// as scheduled. Otherwise the new alarm is booked before the one it
    /// replaces is cancelled, so the end never goes without an alarm.
    func schedule(
        sessionID: UUID,
        phase: FocusEndAlarmPhase,
        endDate: Date,
        soundFile: @MainActor () async -> String?
    ) async -> FocusEndAlarmScheduleResult {
        generation &+= 1
        let bookingGeneration = generation
        pendingIntent = BookingIntent(generation: bookingGeneration, sessionID: sessionID, endDate: endDate)
        defer {
            if pendingIntent?.generation == bookingGeneration {
                pendingIntent = nil
            }
        }
        retryPendingCancels()

        if let refusal = refusal(endDate: endDate) {
            releaseBooking(keepingWitnessOf: sessionID)
            return refusal
        }
        let soundFileName = await soundFile()
        guard generation == bookingGeneration else { return .superseded }
        // Preparing the file may have taken a while.
        if let refusal = refusal(endDate: endDate) {
            releaseBooking(keepingWitnessOf: sessionID)
            return refusal
        }

        let listed = try? client.alarms()
        if let existing = store.load(),
           existing.isConfirmed,
           existing.sessionID == sessionID,
           existing.phase == phase,
           abs(existing.fireDate.timeIntervalSince(endDate))
            <= FocusEndAlarmReconcilePolicy.fireDateTolerance,
           existing.soundFileName == soundFileName,
           listed?.first(where: { $0.id == existing.alarmID })?.state == .scheduled {
            return .booked(existing)
        }

        let replaced = store.load()
        let booking = FocusEndAlarmBooking(
            alarmID: makeAlarmID(),
            sessionID: sessionID,
            phase: phase,
            fireDate: endDate,
            soundFileName: soundFileName
        )
        store.save(booking)
        inFlightAlarmIDs.insert(booking.alarmID)
        if let replaced { inFlightAlarmIDs.insert(replaced.alarmID) }
        defer {
            inFlightAlarmIDs.remove(booking.alarmID)
            if let replaced { inFlightAlarmIDs.remove(replaced.alarmID) }
        }

        let result: FocusEndAlarmScheduleResult
        do {
            try await client.schedule(FocusEndAlarmRequest(
                alarmID: booking.alarmID,
                phase: phase,
                fireDate: endDate,
                soundFileName: soundFileName
            ))
            if generation == bookingGeneration, store.load()?.alarmID == booking.alarmID {
                var confirmed = booking
                confirmed.isConfirmed = true
                store.save(confirmed)
                result = .booked(confirmed)
            } else {
                silence(booking.alarmID, alerting: false)
                clearBooking(ifAlarmID: booking.alarmID)
                result = .superseded
            }
        } catch {
            silence(booking.alarmID, alerting: false)
            clearBooking(ifAlarmID: booking.alarmID)
            result = generation == bookingGeneration ? .failed : .superseded
        }
        // The alarm this booking replaced (another end, sound or session)
        // goes whatever happened: the store forgot it at the write-ahead, so
        // no cancel in between could reach it.
        if let replaced {
            silence(replaced.alarmID, alerting: isAlerting(replaced.alarmID))
        }
        return result
    }

    /// Cancels the booked alarm (any session, or only `sessionID`'s), and a
    /// booking of that session still in flight. For a pause, abandon, early
    /// finish or ownership loss. An alarm that has already rung is stopped
    /// but kept as its session's delivery witness. Returns false when the
    /// system still lists the alarm after a failed cancel; it is then
    /// retried by `retryPendingCancels`.
    @discardableResult
    func cancel(sessionID: UUID? = nil) -> Bool {
        retryPendingCancels()
        supersedeBookingInFlight(of: sessionID)
        guard let booking = store.load() else { return true }
        if let sessionID, booking.sessionID != sessionID { return true }
        supersedeBookings(of: booking)
        return releaseBooking(keepingWitnessOf: booking.sessionID)
    }

    /// The app is active just before the end
    /// (`AlarmChannelPolicy.shouldHandOffToForeground`): cancels the alarm
    /// that has not rung yet, and a booking of the session still in flight,
    /// so the in-app alarm is the only one. Returns the end the app now
    /// announces alone, or nil when nothing was handed off: no alarm is
    /// booked or being booked for the session, or its fire date has passed
    /// and the system may be ringing (resolve that through
    /// `deliveryWitnessFireDate` and `acknowledge`). If the scene stops being
    /// active before the returned end, book
    /// `AlarmChannelPolicy.channelAfterLeavingDuringHandoff` at once.
    @discardableResult
    func handOffToForeground(sessionID: UUID) -> Date? {
        retryPendingCancels()
        var handedOff: Date?
        if let intent = pendingIntent, intent.sessionID == sessionID, intent.endDate > now() {
            handedOff = intent.endDate
        }
        supersedeBookingInFlight(of: sessionID)
        if let booking = store.load(),
           booking.sessionID == sessionID,
           booking.fireDate > now() {
            supersedeBookings(of: booking)
            releaseBooking(keepingWitnessOf: nil)
            handedOff = handedOff ?? booking.fireDate
        }
        return handedOff
    }

    /// The completion for `sessionID` was resolved in the app (the person is
    /// looking at it): Stop the alarm if it is ringing, cancel it if it has
    /// not rung, and drop a booking still in flight. An alarm that rang stays
    /// recorded as the delivery witness, so reading `deliveryWitnessFireDate`
    /// before or after this call gives the same answer.
    func acknowledge(sessionID: UUID) {
        retryPendingCancels()
        supersedeBookingInFlight(of: sessionID)
        guard let booking = store.load(), booking.sessionID == sessionID else { return }
        supersedeBookings(of: booking)
        releaseBooking(keepingWitnessOf: sessionID)
    }

    /// An Apple Account boundary blocks timer requests
    /// (`NotificationManager.suspendTimerSchedulingForAccountBoundary`): a
    /// booking still in flight books nothing. The booked alarm stays until
    /// the cleanup that follows (`cancelAll`).
    func abandonBookingsInFlight() {
        generation &+= 1
        pendingIntent = nil
    }

    /// Account change and complete data deletion: nothing of this app may
    /// ring afterwards. An alarm that is ringing now is stopped.
    func cancelAll() {
        generation &+= 1
        pendingIntent = nil
        let listed = listedAlarms()
        var ids = Set(listed.map(\.id))
        ids.formUnion(store.pendingCancelIDs)
        store.setPendingCancelIDs([])
        if let booking = store.load() {
            ids.insert(booking.alarmID)
        }
        for id in ids {
            silence(id, alerting: listed.contains { $0.id == id && $0.state == .alerting })
        }
        store.clear()
    }

    /// iCloud retirement and reset recovery
    /// (`NotificationManager.prepareTimerNotificationCleanup`): cancels every
    /// alarm except the booked one of a session in `sessionIDs` (or the one
    /// such a session is booking now), which the caller keeps running. With
    /// no such booking this is `cancelAll`.
    func cancelAll(preserving sessionIDs: Set<UUID>) {
        let stored = store.load()
        let kept = stored.flatMap { sessionIDs.contains($0.sessionID) ? $0 : nil }
        let keepsIntent = pendingIntent.map { sessionIDs.contains($0.sessionID) } ?? false
        guard kept != nil || keepsIntent else {
            cancelAll()
            return
        }
        retryPendingCancels()
        if !keepsIntent, pendingIntent != nil {
            generation &+= 1
            pendingIntent = nil
        }
        let listed = listedAlarms()
        for snapshot in listed
        where snapshot.id != kept?.alarmID && !inFlightAlarmIDs.contains(snapshot.id) {
            silence(snapshot.id, alerting: snapshot.state == .alerting)
        }
        if kept == nil, let stored {
            silence(stored.alarmID, alerting: listed.contains { $0.id == stored.alarmID && $0.state == .alerting })
            clearBooking(ifAlarmID: stored.alarmID)
        }
    }

    /// Reconciles the booking with the system at launch and whenever the app
    /// becomes active. Returns the decision so the caller can book a
    /// replacement when the owner needs one. When the system's list cannot
    /// be read nothing is decided (and nothing is booked); the next call
    /// tries again.
    /// An app that was never allowed alarms has none, so AlarmKit is not
    /// asked (this runs at every activation, for everyone).
    @discardableResult
    func reconcile(owner: FocusEndAlarmOwner?) -> FocusEndAlarmReconciliation {
        retryPendingCancels()
        let alarms: [FocusEndAlarmSnapshot]
        if systemMayListAlarms {
            guard let listed = try? client.alarms() else {
                return FocusEndAlarmReconciliation()
            }
            alarms = listed
        } else {
            alarms = []
        }
        let decision = FocusEndAlarmReconcilePolicy.reconcile(
            booking: store.load(),
            alarms: alarms,
            owner: owner,
            now: now(),
            inFlightAlarmIDs: inFlightAlarmIDs
        )
        for id in decision.cancelIDs {
            silence(id, alerting: false)
        }
        if decision.clearsBooking {
            store.clear()
        } else if decision.confirmsBooking, var booking = store.load() {
            booking.isConfirmed = true
            store.save(booking)
        }
        return decision
    }

    /// Silences again every alarm whose cancel (or Stop) failed earlier:
    /// Stop for one that is ringing now, cancel otherwise. Every other entry
    /// point runs this first.
    func retryPendingCancels() {
        let pending = store.pendingCancelIDs
        guard !pending.isEmpty else { return }
        store.setPendingCancelIDs([])
        let listed = listedAlarms()
        for id in pending {
            silence(id, alerting: listed.contains { $0.id == id && $0.state == .alerting })
        }
    }

    // MARK: Private

    /// Why AlarmKit cannot book `endDate` now, or nil when it can.
    private func refusal(endDate: Date) -> FocusEndAlarmScheduleResult? {
        switch client.authorization {
        case .authorized: break
        case .unsupported: return .unsupported
        case .notDetermined, .denied: return .notAuthorized
        }
        guard AlarmChannelPolicy.systemAlarmLeadIsSufficient(endDate: endDate, now: now()) else {
            return .tooSoon
        }
        return nil
    }

    /// Supersedes the newest `schedule` while it runs when it books
    /// `sessionID`'s end (any session's when nil).
    private func supersedeBookingInFlight(of sessionID: UUID?) {
        guard let intent = pendingIntent,
              sessionID == nil || intent.sessionID == sessionID
        else { return }
        generation &+= 1
        pendingIntent = nil
    }

    /// Before `booking` is released: supersedes a `schedule` still booking
    /// it (its write-ahead record), but never the newest `schedule` of
    /// another session, which replaces `booking` anyway. A break booked
    /// while the focus that preceded it is closed must keep its alarm.
    private func supersedeBookings(of booking: FocusEndAlarmBooking) {
        if let intent = pendingIntent, intent.sessionID != booking.sessionID { return }
        generation &+= 1
    }

    /// The system's list of this app's alarms. An app that was never allowed
    /// alarms (or runs on iOS 17–25) cannot have any, so AlarmKit is not
    /// asked at all: most people never choose the maximum preset.
    private func listedAlarms() -> [FocusEndAlarmSnapshot] {
        guard systemMayListAlarms else { return [] }
        return (try? client.alarms()) ?? []
    }

    private func isAlerting(_ id: UUID) -> Bool {
        listedAlarms().contains { $0.id == id && $0.state == .alerting }
    }

    private var systemMayListAlarms: Bool {
        switch client.authorization {
        case .unsupported, .notDetermined: false
        case .authorized, .denied: true
        }
    }

    /// Silences the booked alarm and forgets it, except that an alarm of
    /// `witnessSessionID` that has rung stays recorded as that session's
    /// delivery witness. Returns whether the alarm is gone from the system.
    @discardableResult
    private func releaseBooking(keepingWitnessOf witnessSessionID: UUID?) -> Bool {
        guard let booking = store.load() else { return true }
        let listed = try? client.alarms()
        let state = listed?.first { $0.id == booking.alarmID }?.state
        let alerting = state == .alerting
        // Rang: ringing now, or confirmed and gone from a readable list after
        // its time. Unknown (the list cannot be read) counts as not rung: a
        // missing witness costs at most one extra cue, a false one silence.
        let rang = alerting
            || (listed != nil && state == nil && booking.isConfirmed && booking.fireDate <= now())
        let silenced = silence(booking.alarmID, alerting: alerting)
        if rang, let witnessSessionID, booking.sessionID == witnessSessionID {
            var witness = booking
            witness.isConfirmed = true
            store.save(witness)
        } else {
            store.clear()
        }
        return silenced
    }

    /// Makes sure `id` can no longer ring: Stop while it alerts, otherwise
    /// (or if Stop fails) cancel. Returns true when it is gone. A cancel that
    /// fails while the system still lists the alarm, or while the list cannot
    /// be read, is remembered and retried by `retryPendingCancels`.
    @discardableResult
    private func silence(_ id: UUID, alerting: Bool) -> Bool {
        if alerting, (try? client.stop(id: id)) != nil {
            return true
        }
        if (try? client.cancel(id: id)) != nil {
            return true
        }
        if let alarms = try? client.alarms(), !alarms.contains(where: { $0.id == id }) {
            return true
        }
        var pending = store.pendingCancelIDs
        if !pending.contains(id) {
            pending.append(id)
            store.setPendingCancelIDs(pending)
        }
        return false
    }

    private func clearBooking(ifAlarmID alarmID: UUID) {
        if store.load()?.alarmID == alarmID {
            store.clear()
        }
    }
}
