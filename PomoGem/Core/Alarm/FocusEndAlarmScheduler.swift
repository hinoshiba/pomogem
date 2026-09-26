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
}

/// The running phase this device owns, as the launch host sees it.
struct FocusEndAlarmOwner: Equatable, Sendable {
    let sessionID: UUID
    let phase: FocusEndAlarmPhase
    /// Nil while paused: a paused timer has no end to announce.
    let endDate: Date?
}

/// What a launch-time reconcile found.
struct FocusEndAlarmReconciliation: Equatable, Sendable {
    /// Alarms to cancel: orphans and stale bookings, never one that is
    /// alerting right now.
    var cancelIDs: [UUID] = []
    /// Forget the persisted booking.
    var clearsBooking = false
    /// The owner is running without a matching alarm; the caller books one
    /// if the channel policy still wants a system alarm.
    var ownerNeedsBooking = false
}

/// Pure launch-time reconcile rules for the one booked alarm.
enum FocusEndAlarmReconcilePolicy {
    /// A fire date this far from the owner's end still counts as the same end.
    static let fireDateTolerance: TimeInterval = 1

    static func reconcile(
        booking: FocusEndAlarmBooking?,
        alarms: [FocusEndAlarmSnapshot],
        owner: FocusEndAlarmOwner?,
        now: Date
    ) -> FocusEndAlarmReconciliation {
        var result = FocusEndAlarmReconciliation()
        // Anything that is not the booked alarm is an orphan (for example a
        // booking lost to a crash). Leave an alerting one to the person.
        result.cancelIDs = alarms
            .filter { $0.id != booking?.alarmID && $0.state != .alerting }
            .map(\.id)

        let ownerIsRunning = owner?.endDate != nil
        guard let booking else {
            result.ownerNeedsBooking = ownerIsRunning
            return result
        }

        let snapshot = alarms.first { $0.id == booking.alarmID }
        if snapshot?.state == .alerting {
            // Ringing now. Returning to the app is what stops it (as Stop);
            // the completion flow acknowledges it. Never cancel it here.
            return result
        }
        let hasFired = booking.fireDate <= now
        if snapshot == nil {
            if !hasFired {
                // Disappeared before its time (permission revoked).
                result.clearsBooking = true
                result.ownerNeedsBooking = ownerIsRunning
            } else if let owner, owner.sessionID != booking.sessionID {
                // Rang for a session that has since been replaced: its
                // completion was resolved, so the witness is no longer read.
                result.clearsBooking = true
                result.ownerNeedsBooking = ownerIsRunning
            }
            // Otherwise it already rang and was dismissed: keep it, because
            // it is the delivery witness until the completion flow
            // acknowledges it.
            return result
        }

        let matchesOwner: Bool = {
            guard let owner, owner.sessionID == booking.sessionID,
                  owner.phase == booking.phase,
                  let endDate = owner.endDate else { return false }
            return abs(endDate.timeIntervalSince(booking.fireDate)) <= fireDateTolerance
        }()
        if matchesOwner || (hasFired && owner?.sessionID == booking.sessionID) {
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
    /// A cancel or a newer booking arrived while this one was in flight; the
    /// alarm it created, if any, was cancelled.
    case superseded
    case failed
}

/// Owns the single AlarmKit alarm for the end of this device's running focus
/// or break (F5, maximum strength). All mutations are serialized on the main
/// actor and fenced by a generation, like `NotificationManager`: a cancel that
/// arrives while a booking is in flight wins, and the late booking removes
/// its own alarm.
///
/// Callers (Phase B) cancel on pause, abandon, early finish, ownership loss,
/// account change and complete data deletion, and reconcile at launch.
@MainActor
final class FocusEndAlarmScheduler {
    static let shared = FocusEndAlarmScheduler(client: FocusEndAlarmClientFactory.live())

    private let client: FocusEndAlarmClient
    private let store: FocusEndAlarmBookingStore
    private let now: () -> Date
    private let makeAlarmID: () -> UUID
    private var generation: UInt64 = 0

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

    /// The fire date of the alarm booked for `sessionID`, used as a delivery
    /// witness once it has passed (`AlarmChannelPolicy.externalAlertMayHaveFired`).
    func bookedFireDate(sessionID: UUID) -> Date? {
        guard let booking = store.load(), booking.sessionID == sessionID else { return nil }
        return booking.fireDate
    }

    /// Books the one alarm for `endDate`, replacing any earlier booking.
    func schedule(
        sessionID: UUID,
        phase: FocusEndAlarmPhase,
        endDate: Date,
        soundFileName: String?
    ) async -> FocusEndAlarmScheduleResult {
        generation &+= 1
        let bookingGeneration = generation

        switch client.authorization {
        case .authorized: break
        case .unsupported:
            cancelBookedAlarm()
            return .unsupported
        case .notDetermined, .denied:
            cancelBookedAlarm()
            return .notAuthorized
        }
        guard AlarmChannelPolicy.systemAlarmLeadIsSufficient(endDate: endDate, now: now()) else {
            cancelBookedAlarm()
            return .tooSoon
        }

        cancelBookedAlarm()
        let booking = FocusEndAlarmBooking(
            alarmID: makeAlarmID(),
            sessionID: sessionID,
            phase: phase,
            fireDate: endDate
        )
        store.save(booking)

        do {
            try await client.schedule(FocusEndAlarmRequest(
                alarmID: booking.alarmID,
                phase: phase,
                fireDate: endDate,
                soundFileName: soundFileName
            ))
        } catch {
            try? client.cancel(id: booking.alarmID)
            clearBooking(ifAlarmID: booking.alarmID)
            return generation == bookingGeneration ? .failed : .superseded
        }

        guard generation == bookingGeneration,
              store.load()?.alarmID == booking.alarmID else {
            try? client.cancel(id: booking.alarmID)
            clearBooking(ifAlarmID: booking.alarmID)
            return .superseded
        }
        return .booked(booking)
    }

    /// Cancels the booked alarm (any session, or only `sessionID`'s). For a
    /// pause, abandon, early finish or ownership loss.
    func cancel(sessionID: UUID? = nil) {
        guard let booking = store.load() else { return }
        if let sessionID, booking.sessionID != sessionID { return }
        generation &+= 1
        try? client.cancel(id: booking.alarmID)
        store.clear()
    }

    /// The completion for `sessionID` was handled in the app (the person is
    /// looking at it): stop the alarm if it is ringing, as Stop, or cancel it
    /// if it has not rung yet, and forget the booking.
    func acknowledge(sessionID: UUID) {
        guard let booking = store.load(), booking.sessionID == sessionID else { return }
        generation &+= 1
        let state = (try? client.alarms())?.first { $0.id == booking.alarmID }?.state
        if state == .alerting {
            do {
                try client.stop(id: booking.alarmID)
            } catch {
                try? client.cancel(id: booking.alarmID)
            }
        } else {
            try? client.cancel(id: booking.alarmID)
        }
        store.clear()
    }

    /// Account change and complete data deletion: nothing of this app may
    /// ring afterwards.
    func cancelAll() {
        generation &+= 1
        var ids = Set((try? client.alarms())?.map(\.id) ?? [])
        if let booking = store.load() {
            ids.insert(booking.alarmID)
        }
        for id in ids {
            try? client.cancel(id: id)
        }
        store.clear()
    }

    /// Launch-time cleanup. Returns the decision so the caller can book a
    /// replacement when the owner needs one.
    @discardableResult
    func reconcile(owner: FocusEndAlarmOwner?) -> FocusEndAlarmReconciliation {
        let alarms = (try? client.alarms()) ?? []
        let decision = FocusEndAlarmReconcilePolicy.reconcile(
            booking: store.load(),
            alarms: alarms,
            owner: owner,
            now: now()
        )
        if !decision.cancelIDs.isEmpty || decision.clearsBooking {
            generation &+= 1
        }
        for id in decision.cancelIDs {
            try? client.cancel(id: id)
        }
        if decision.clearsBooking {
            store.clear()
        }
        return decision
    }

    private func cancelBookedAlarm() {
        guard let booking = store.load() else { return }
        try? client.cancel(id: booking.alarmID)
        store.clear()
    }

    private func clearBooking(ifAlarmID alarmID: UUID) {
        if store.load()?.alarmID == alarmID {
            store.clear()
        }
    }
}
