import FamilyControls
import Foundation
import ManagedSettings
import UIKit

// F2 (app side). Decides from the saved timer, the Screen Time ledger and the
// authorization whether the distraction apps should be shielded right now,
// and hands the decision to `FocusShieldEngine` (Shared/ScreenTimeFocusShield.swift),
// which the monitor extension also runs. Driven by the same choke point as the
// learning lane's timer hold: `ScreenTimeIntegrationModifier` on every
// `FocusPersistence.didChange`, every foreground pass and every settings save.

// MARK: - Inputs

enum FocusShieldAuthorization: Equatable {
    case approved
    /// The user answered 「許可しない」: tokens are void, lift at once.
    case denied
    /// `.notDetermined`, which a cold launch reads before Family Controls
    /// answers and a revocation also reads. Nothing new is shielded; a shield
    /// already up for the same focus stays until the controller's settling
    /// window turns a lasting unknown into a revocation (which wipes the
    /// configuration, and with it the shield).
    case unknown

    init(_ status: AuthorizationStatus) {
        if status == .approved { self = .approved; return }
        if #available(iOS 26.4, *), status == .approvedWithDataAccess { self = .approved; return }
        self = status == .denied ? .denied : .unknown
    }
}

/// What the saved timer says about a focus on THIS iPhone. Breaks, the
/// completion screen, a pending completion and a timer frozen under another
/// reset generation are all `.none`: the shield follows the focus phase only.
enum FocusShieldFocusState: Equatable {
    case none
    case running(sessionID: UUID, plannedEnd: Date)
    case paused(sessionID: UUID)

    var sessionID: UUID? {
        switch self {
        case .none: nil
        case let .running(sessionID, _), let .paused(sessionID): sessionID
        }
    }

    init(envelope: FocusRecoveryEnvelope?, dataEpochID: UUID?) {
        guard let envelope, envelope.dataEpochID == dataEpochID,
              envelope.pendingCompletion == nil,
              envelope.engine.containsRecoverableFocus,
              let sessionID = envelope.engine.currentSessionID else {
            self = .none
            return
        }
        switch envelope.engine.phase {
        case .focusing:
            guard let end = envelope.engine.endDate else { self = .none; return }
            self = .running(sessionID: sessionID, plannedEnd: end)
        case .paused:
            self = .paused(sessionID: sessionID)
        default:
            self = .none
        }
    }
}

// MARK: - Decision

enum FocusShieldDecision: Equatable {
    /// Nothing is shielded and nothing should be.
    case idle
    /// Shield until `deadline` (planned end + 60 s at the latest running state).
    case apply(sessionID: UUID, deadline: Date)
    /// A paused focus: keep the shield with the deadline it already has.
    case keep
    /// Lift the shield that is up.
    case clear(FocusShieldClearReason)
}

enum FocusShieldReconcilePolicy {
    static func decide(
        enabled: Bool,
        applicationCount: Int,
        authorization: FocusShieldAuthorization,
        focus: FocusShieldFocusState,
        record: FocusShieldRecord?,
        now: Date
    ) -> FocusShieldDecision {
        let active = record.flatMap { $0.active ? $0 : nil }
        func lift(_ reason: FocusShieldClearReason) -> FocusShieldDecision {
            active == nil ? .idle : .clear(reason)
        }
        // An expired record is over whatever else is true: a pause long past
        // its deadline, a focus that ended while PomoGem was closed.
        if let active, now >= active.deadline { return .clear(.deadlinePassed) }
        guard enabled else { return lift(.featureOff) }
        guard applicationCount > 0 else { return lift(.noApplications) }
        guard applicationCount <= FocusShieldPolicy.maximumApplications else { return lift(.tooManyApplications) }
        guard authorization != .denied else { return lift(.authorizationDenied) }
        switch focus {
        case .none:
            return lift(.focusEnded)
        case let .paused(sessionID):
            // Manual and automatic pauses keep the shield (leaving PomoGem
            // must not be the way out), but never extend it: a pause without
            // a shield of its own session has nothing to keep.
            guard let active, active.sessionID == sessionID else { return lift(.focusEnded) }
            return .keep
        case let .running(sessionID, plannedEnd):
            let deadline = FocusShieldPolicy.deadline(forPlannedEnd: plannedEnd)
            guard now < deadline else { return lift(.deadlinePassed) }
            if let record, record.sessionID == sessionID, record.liftedAt != nil {
                return lift(.liftedByUser)
            }
            guard authorization == .approved else {
                if let active, active.sessionID == sessionID { return .keep }
                return lift(.focusEnded)
            }
            return .apply(sessionID: sessionID, deadline: deadline)
        }
    }
}

// MARK: - Settings view-model (Phase B UI)

/// Whether the opt-in can shield anything, for the Screen Time page's toggle
/// footer. The toggle itself is `ScreenTimeConfiguration.shieldsDistractionDuringFocusEnabled`,
/// saved with the rest of the page through `ScreenTimeController.save`.
enum FocusShieldAvailability: Equatable {
    case off
    case needsAuthorization
    case noApplications
    /// `ShieldSettings.applications` shields nothing at all above 50.
    case tooManyApplications(count: Int)
    case ready

    init(configuration: ScreenTimeConfiguration, authorizationGranted: Bool) {
        let count = configuration.distractionSelection.applicationTokens.count
        guard configuration.shieldsDistractionDuringFocusEnabled else { self = .off; return }
        guard authorizationGranted else { self = .needsAuthorization; return }
        guard count > 0 else { self = .noApplications; return }
        guard count <= FocusShieldPolicy.maximumApplications else {
            self = .tooManyApplications(count: count)
            return
        }
        self = .ready
    }

    /// Why a switched-on shield does nothing; nil when it works or is off.
    var message: String? {
        switch self {
        case .off, .ready:
            nil
        case .needsAuthorization:
            String(localized: "スクリーンタイムへのアクセスを許可すると使えます。", table: "ScreenTime",
                   comment: "Focus shield footer: the shield needs Screen Time access")
        case .noApplications:
            String(localized: "控えたいアプリを1つ以上選ぶと使えます。", table: "ScreenTime",
                   comment: "Focus shield footer: the shield needs at least one app to cut down")
        case let .tooManyApplications(count):
            String(localized: "控えたいアプリが\(count)個あります。集中中に開けないようにできるのは50個までなので、いまは制限していません。",
                   table: "ScreenTime",
                   comment: "Focus shield warning. %lld is the number of apps to cut down, always more than 50 (Apple's limit). en needs plural variations.")
        }
    }
}

/// Copy for the Phase B UI (ScreenTimeSettingsView, FocusView). Kept here so
/// the words are reviewed with the behaviour they describe.
enum FocusShieldCopy {
    static var toggleTitle: String {
        String(localized: "集中中は気が散るアプリを開けないようにする", table: "ScreenTime",
               comment: "Toggle: shield the apps to cut down while a PomoGem focus runs")
    }

    static var toggleFooter: String {
        String(localized: "ポモジェムで集中しているあいだ、控えたいアプリを開けなくします。休憩になるか集中が終わると解除します。一時停止中は、予定の終了時刻の1分後まで続きます。",
               table: "ScreenTime", comment: "Footer under the focus shield toggle: when apps are blocked and when they are released")
    }

    static var liftButton: String {
        String(localized: "今すぐ制限を解除", table: "ScreenTime",
               comment: "Button: lift the focus shield now (escape hatch)")
    }

    static var liftFooter: String {
        String(localized: "解除するのはこの集中のあいだだけです。次の集中では、また開けないようにします。",
               table: "ScreenTime", comment: "Footer under the escape hatch: it lifts the shield for this focus only")
    }

    static var focusNotice: String {
        String(localized: "気が散るアプリを制限中", table: "ScreenTime",
               comment: "Focus screen notice line: the apps to cut down are shielded right now")
    }

    /// Shown while `FocusShieldController.failsafeUnavailable` is true, which
    /// is only during the focus whose failsafe could not be registered.
    static var failsafeUnavailable: String {
        String(localized: "制限を自動で解除する準備ができなかったため、今回の集中では制限していません。",
               table: "ScreenTime",
               comment: "Notice: the failsafe that lifts the shield could not be registered, so nothing was shielded")
    }
}

// MARK: - Controller

/// The app's one serial lane for shield side effects, shared by the
/// controller and the launch sweep so they can never interleave a register
/// with a stop. The record's flock guards against the extension only.
enum FocusShieldAppQueue {
    static let queue = DispatchQueue(label: "com.hinoshiba.pomogem.focus-shield", qos: .userInitiated)
}

@MainActor
final class FocusShieldController: ObservableObject {
    private static let assertionName = "com.hinoshiba.pomogem.focus-shield"

    /// A shield written by this iPhone is up: the focus screen's notice line
    /// and the settings page's escape hatch show while it is true.
    @Published private(set) var isShielding = false
    /// The failsafe interval for the CURRENT focus could not be registered,
    /// so that focus runs unshielded. False again as soon as that focus is
    /// over (completed, abandoned, a break, another focus), the shield is no
    /// longer wanted (switched off, no apps, too many, denied), the owner is
    /// retired, or a later attempt for the same focus succeeds.
    @Published private(set) var failsafeUnavailable = false

    private let engine: FocusShieldEngine
    private let queue: DispatchQueue
    private let clock: () -> Date
    private var lastRequest: Request?
    private var tail: Task<Void, Never>?
    /// Operations submitted but not finished. While any is queued, the
    /// record on disk may not show it yet, so a decision read from the disk
    /// can be stale and must be re-made on the queue.
    private var pendingOperations = 0
    /// The focus (running or paused) the latest reconcile saw.
    private var currentFocusSession: UUID?
    /// The focus whose failsafe could not be registered.
    private var unarmedSession: UUID? {
        didSet {
            let unavailable = unarmedSession != nil
            if failsafeUnavailable != unavailable { failsafeUnavailable = unavailable }
        }
    }

    private struct Request: Equatable {
        let decision: FocusShieldDecision
        let applications: Set<ApplicationToken>
    }

    /// `clock` stands for "now" wherever no caller passed one, including
    /// when a finished operation re-publishes `isShielding`.
    init(engine: FocusShieldEngine, queue: DispatchQueue = FocusShieldAppQueue.queue,
         clock: @escaping () -> Date = { Date() }) {
        self.engine = engine
        self.queue = queue
        self.clock = clock
    }

    /// Cheap when nothing changed: the decision is pure and an identical
    /// request is not repeated unless `force` (every activation) asks for it.
    ///
    /// The decision made here from the record on disk only decides whether
    /// to act. The queued operation makes it again from the record as it is
    /// when it runs, after every operation queued before it, so an apply
    /// still waiting in the queue can never outlive a later "the focus is
    /// over" (or turn a pause of the new focus into a clear).
    func reconcile(
        configuration: ScreenTimeConfiguration,
        authorization: FocusShieldAuthorization,
        focus: FocusShieldFocusState,
        now: Date? = nil,
        force: Bool = false
    ) {
        let now = now ?? clock()
        let record = currentRecord()
        let enabled = configuration.shieldsDistractionDuringFocusEnabled
        let applications = configuration.distractionSelection.applicationTokens
        let decision = FocusShieldReconcilePolicy.decide(
            enabled: enabled,
            applicationCount: applications.count,
            authorization: authorization,
            focus: focus,
            record: record,
            now: now
        )
        currentFocusSession = focus.sessionID
        let wantsShield = enabled && authorization != .denied
            && (1...FocusShieldPolicy.maximumApplications).contains(applications.count)
        if unarmedSession != nil, !wantsShield || unarmedSession != focus.sessionID { unarmedSession = nil }
        publishShielding(record, now: now)
        let request = Request(decision: decision, applications: applications)
        guard force || request != lastRequest else { return }
        lastRequest = request
        // Nothing to do only when nothing of ours is still in flight.
        if decision == .idle, pendingOperations == 0 { return }
        let session = focus.sessionID
        submit(session: session) { engine in
            let record = Self.record(in: engine)
            let decision = FocusShieldReconcilePolicy.decide(
                enabled: enabled, applicationCount: applications.count, authorization: authorization,
                focus: focus, record: record, now: now)
            switch decision {
            case .idle:
                return .unchanged
            case let .apply(sessionID, deadline):
                return try engine.apply(sessionID: sessionID, deadline: deadline, applications: applications, now: now)
            case .keep:
                return try engine.keep(applications: applications, now: now)
            case let .clear(reason):
                return try engine.clear(reason: reason, now: now)
            }
        }
    }

    /// 「今すぐ制限を解除」: lifts the shield for the focus it belongs to. The
    /// same session is not shielded again, even after a pause and resume.
    func liftForCurrentFocus(now: Date? = nil) {
        guard let record = currentRecord(), record.active else { return }
        let now = now ?? clock()
        lastRequest = nil
        isShielding = false
        let sessionID = record.sessionID
        submit(session: nil) { try $0.lift(sessionID: sessionID, now: now) }
    }

    /// An owner boundary (account change, storage relaunch, a reset of the
    /// Screen Time owner) or a revoked authorization: lift whatever is up.
    /// Free when nothing is up and nothing is queued; otherwise the clear is
    /// queued behind whatever is, and the engine re-checks the record under
    /// its lock, so a queued apply can never shield for a retired owner.
    ///
    /// `unconditional` (switching the setting off) also empties the named
    /// store and stops the failsafe when no record says a shield is up, so
    /// turning the setting off always works as the way out, whatever state
    /// an interrupted run left behind.
    func retire(reason: FocusShieldClearReason, now: Date? = nil, unconditional: Bool = false) {
        lastRequest = nil
        currentFocusSession = nil
        unarmedSession = nil
        guard unconditional || pendingOperations > 0 || currentRecord()?.active == true else { return }
        let now = now ?? clock()
        isShielding = false
        submit(session: nil) { try $0.clear(reason: reason, now: now, unconditional: unconditional) }
    }

    /// Complete data deletion: the store, the failsafe interval and the
    /// record, whatever state they are in.
    func eraseAllData() async throws {
        lastRequest = nil
        currentFocusSession = nil
        unarmedSession = nil
        isShielding = false
        let result = await run {
            try $0.eraseAll()
            return .cleared
        }
        if case let .failure(error) = result { throw error }
    }

    /// A barrier for lifecycle cleanup and tests.
    func waitForPendingOperations() async {
        await tail?.value
    }

    private func submit(
        session: UUID?,
        _ operation: @escaping (FocusShieldEngine) throws -> FocusShieldEngine.Outcome
    ) {
        let previous = tail
        let assertion = ScreenTimeBackgroundAssertion(name: Self.assertionName)
        pendingOperations += 1
        tail = Task { @MainActor in
            await previous?.value
            let result = await perform(operation)
            assertion.end()
            finish(result, session: session)
        }
    }

    private func run(
        _ operation: @escaping (FocusShieldEngine) throws -> FocusShieldEngine.Outcome
    ) async -> Result<FocusShieldEngine.Outcome, Error> {
        let previous = tail
        let assertion = ScreenTimeBackgroundAssertion(name: Self.assertionName)
        pendingOperations += 1
        let task = Task { @MainActor () -> Result<FocusShieldEngine.Outcome, Error> in
            await previous?.value
            let result = await perform(operation)
            assertion.end()
            finish(result, session: nil)
            return result
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func perform(
        _ operation: @escaping (FocusShieldEngine) throws -> FocusShieldEngine.Outcome
    ) async -> Result<FocusShieldEngine.Outcome, Error> {
        let engine = engine
        let queue = queue
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Result { try operation(engine) })
            }
        }
    }

    private func finish(_ result: Result<FocusShieldEngine.Outcome, Error>, session: UUID?) {
        pendingOperations -= 1
        // Only the focus the controller is still looking at: a result for a
        // focus that has since ended, or arriving after a retire, says
        // nothing about the focus on screen now.
        let current = session != nil && session == currentFocusSession
        switch result {
        case .success(.failsafeUnavailable):
            // Not retried every three seconds; the next activation or a
            // changed timer tries again.
            if current { unarmedSession = session }
        case .success(.applied), .success(.kept):
            if current, unarmedSession == session { unarmedSession = nil }
        case .success:
            break
        case let .failure(error):
            // Usually the extension holding the record lock: retry on the
            // next pass instead of waiting for the inputs to change.
            lastRequest = nil
            ScreenTimeLog.monitoring.error(
                "focus-shield operation failed error=\(String(describing: error), privacy: .public)")
        }
        publishShielding(currentRecord(), now: clock())
    }

    private func currentRecord() -> FocusShieldRecord? {
        Self.record(in: engine)
    }

    /// An unreadable record is treated as an active one that has expired,
    /// so the next decision clears it (and the engine removes the file).
    nonisolated private static func record(in engine: FocusShieldEngine) -> FocusShieldRecord? {
        do {
            return try engine.records.load()
        } catch ScreenTimeError.corruptedState {
            return FocusShieldRecord(active: true, sessionID: UUID(), deadline: .distantPast,
                                     appliedAt: .distantPast)
        } catch {
            return nil
        }
    }

    private func publishShielding(_ record: FocusShieldRecord?, now: Date) {
        let shielding = record.map { $0.active && now < $0.deadline } ?? false
        if isShielding != shielding { isShielding = shielding }
    }
}

// MARK: - Launch sweep

/// Removal path 3: before persistence is admitted (a launch can wait a long
/// time on iCloud or a storage screen, and RootView — with the modifier that
/// reconciles — only mounts afterwards), clear a record whose deadline has
/// passed. Runs at launch and on every activation, reads only the record and
/// the clock, and touches ManagedSettings only when a record exists.
@MainActor
enum FocusShieldLaunchSweep {
    private static var observer: NSObjectProtocol?

    static func start(engine: @escaping () -> FocusShieldEngine = { .live() }) {
        run(engine)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { run(engine) }
        }
    }

    private static func run(_ engine: @escaping () -> FocusShieldEngine) {
        FocusShieldAppQueue.queue.async {
            _ = engine().sweepExpired(now: Date())
        }
    }
}

extension PomoGemAppDelegate {
    /// Only the focus shield's launch sweep. Kept in this file so the shield's
    /// three removal paths are read together.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FocusShieldLaunchSweep.start()
        return true
    }
}
