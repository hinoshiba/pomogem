import Combine
import FamilyControls
import Foundation

@MainActor
final class ScreenTimeController: ObservableObject {
    static let shared = ScreenTimeController()
    @Published private(set) var configuration = ScreenTimeConfiguration()
    @Published private(set) var authorizationStatus = AuthorizationStatus.notDetermined
    @Published private(set) var authorizationGranted = false
    @Published private(set) var monitoringError: String?
    @Published private(set) var negativeGemCount = 0
    /// The timer's hold on the learning lane as of the last reload, already
    /// evaluated against its end date (`ScreenTimeState.isLearningPaused(at:)`).
    @Published private(set) var learningPausedByTimer = false
    @Published private(set) var isMonitoring = false
    @Published private(set) var isSaving = false
    @Published private(set) var isResetting = false
    @Published private(set) var isUpdatingMonitoring = false
    /// The published configuration is empty until the ledger admits this
    /// owner. The settings screen must not seed a draft — or offer 保存 —
    /// from that empty state, or a save would erase the opaque selections.
    @Published private(set) var isBoundToContext = false
    /// Why the last bind failed, for a context that can never bind: a missing
    /// App Group entitlement or an unreadable ledger leaves `isBoundToContext`
    /// false forever, and `monitoringError` is cleared with the rest of the
    /// published state. Without this the settings screen would show a greyed
    /// 保存 and no reason at all.
    @Published private(set) var bindingError: String?
    /// Why the last 「アクセスを許可」 ended without an approval, kept apart from
    /// `monitoringError` because `reload()` rewrites that from the ledger
    /// every three seconds: the user needs time to read what to fix. Cleared
    /// by the next request and once access is granted.
    @Published private(set) var authorizationFailure: ScreenTimeAuthorizationFailure?
    /// The learning destination theme was deleted (here or on another device)
    /// and the study-app selection was cleared with it, as documented. Kept
    /// per owner on this iPhone until the user saves the Screen Time settings
    /// again, so the settings screen and its row can say why learning stopped
    /// instead of looking like a feature that was never set up.
    @Published private(set) var learningThemeWasRemoved = false
    let store: ScreenTimeStore
    private let worker: ScreenTimeMonitoringWorker
    /// A read-only copy of the callback diagnostics into the app's own
    /// container. The monitor extension counts the callbacks but cannot write
    /// there — `Library/Application Support` resolves inside whichever bundle
    /// asks for it — and the App Group ledger it does write cannot be pulled
    /// off a phone, so the app mirrors on its own passes. See
    /// `ScreenTimeDiagnosticsMirror`.
    private let diagnosticsMirror: ScreenTimeDiagnosticsMirror
    private let currentContextKey: () -> String
    private let authorization: () -> AuthorizationStatus
    private let requestIndividualAuthorization: () async throws -> Void
    private let noticeDefaults: UserDefaults
    /// FamilyControls reports a REVOKED authorization as `.notDetermined` — the
    /// same value a process reads before the framework has answered and the one
    /// a user who never opted in has. Treat `.notDetermined` as settled only
    /// after it has survived this window, so a cold launch cannot throw away
    /// opaque selections that only a new picker session could restore.
    private let authorizationSettlingWindow: TimeInterval
    /// The window must measure CONTINUOUS observation, never wall clock. This
    /// controller is a singleton that outlives the foreground refresh loop, so
    /// a stamp left behind by an interrupted pass would otherwise let a single
    /// post-resume sample satisfy a window that spans the whole background gap.
    /// Requiring several consecutive not-approved passes as well keeps the
    /// decision independent of how often the loop happens to run.
    private let authorizationSettlingObservations: Int
    private var unsettledAuthorizationSince: Date?
    private var unsettledAuthorizationObservations = 0
    private var lease: ScreenTimeContextLease? { didSet { publishBindingState() } }
    private var bindingTask: Task<Void, Error>?
    private var bindingConfirmed = false { didSet { publishBindingState() } }
    private var operationIDs: Set<UUID> = []
    private var isErasing = false

    enum OperationError: LocalizedError {
        case busy
        var errorDescription: String? { "スクリーンタイムの設定を反映中です。完了するまでお待ちください。" }
    }

    init(
        store: ScreenTimeStore = ScreenTimeStore(),
        currentContextKey: @escaping () -> String = {
            AccountScopedLocalState.defaultsKey(base: "screen-time-owner")
        },
        monitoring: ScreenTimeMonitoringDriving? = nil,
        authorization: @escaping () -> AuthorizationStatus = { AuthorizationCenter.shared.authorizationStatus },
        requestIndividualAuthorization: @escaping () async throws -> Void = {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        },
        authorizationSettlingWindow: TimeInterval = 10,
        authorizationSettlingObservations: Int = 4,
        diagnosticsMirror: ScreenTimeDiagnosticsMirror = ScreenTimeDiagnosticsMirror(),
        noticeDefaults: UserDefaults = .standard
    ) {
        self.store = store
        self.noticeDefaults = noticeDefaults
        self.currentContextKey = currentContextKey
        self.authorization = authorization
        self.requestIndividualAuthorization = requestIndividualAuthorization
        self.diagnosticsMirror = diagnosticsMirror
        self.authorizationSettlingWindow = authorizationSettlingWindow
        self.authorizationSettlingObservations = max(1, authorizationSettlingObservations)
        worker = ScreenTimeMonitoringWorker(store: store, monitoring: monitoring ?? ScreenTimeMonitoring(store: store))
        reload()
    }

    /// Whether this iPhone holds anything of the Screen Time feature that a
    /// user could lose or be surprised by: a switched-on recording, an app
    /// selection, or black stones. Explanations elsewhere in Settings use it
    /// to mention Screen Time only to people who set it up.
    var hasLocalSetup: Bool {
        isBoundToContext && (configuration.enabled || negativeGemCount > 0
            || !configuration.learningSelection.applicationTokens.isEmpty
            || !configuration.distractionSelection.applicationTokens.isEmpty)
    }

    func isBound(contextKey: String, dataEpochID: UUID?) -> Bool {
        !isErasing && bindingConfirmed && lease?.binding == ScreenTimeContextBinding(contextKey: contextKey, dataEpochID: dataEpochID)
            && contextKey == currentContextKey()
    }

    /// A changed owner or activity epoch revokes queued work before the first
    /// await. A new owner always starts with empty opt-in settings. A new
    /// reset generation under the SAME owner keeps them — the app selections,
    /// the theme and the recording switch — and drops everything the old
    /// generation produced: runs, black stones, unimported receipts and errors.
    /// Retiring the runs is what keeps old callbacks from awarding (event names
    /// carry the run UUID); wiping the setup as well contradicted the reset's
    /// own promise that app settings survive it, and only Apple's picker could
    /// rebuild the selections.
    func bindContext(contextKey: String, dataEpochID: UUID?) async throws {
        guard !isErasing, contextKey == currentContextKey() else { throw ScreenTimeError.unboundContext }
        let binding = ScreenTimeContextBinding(contextKey: contextKey, dataEpochID: dataEpochID)
        if lease?.binding == binding {
            if let bindingTask { try await bindingTask.value }
            guard isBound(contextKey: contextKey, dataEpochID: dataEpochID) else { throw ScreenTimeError.unboundContext }
            reload()
            return
        }
        suspendForContextRetirement()
        let newLease = ScreenTimeContextLease(binding: binding)
        lease = newLease
        bindingConfirmed = false
        let operation = beginOperation()
        let worker = worker
        let task = Task { @MainActor in
            defer { endOperation(operation) }
            do {
                try await worker.perform {
                    try worker.store.withMonitoringLock {
                        let previous = try newLease.whileCurrent { try worker.store.snapshot() }
                        if !binding.matches(previous) {
                            worker.monitoring.stop()
                            try newLease.whileCurrent {
                                try worker.store.update { state in
                                    state = ScreenTimeState.rebound(from: state, to: binding)
                                }
                            }
                        }
                        try newLease.whileCurrent { try worker.store.update { $0.contextIsActive = true } }
                    }
                }
                guard self.lease === newLease, !isErasing, contextKey == currentContextKey() else {
                    throw ScreenTimeError.unboundContext
                }
                bindingConfirmed = true
                bindingTask = nil
                bindingError = nil
                reload()
            } catch {
                if self.lease === newLease {
                    newLease.invalidate()
                    self.lease = nil
                    bindingConfirmed = false
                    bindingTask = nil
                    clearPublishedState()
                    // After clearPublishedState, which nils monitoringError.
                    bindingError = error.localizedDescription
                }
                throw error
            }
        }
        bindingTask = task
        try await task.value
    }

    func requestAuthorization() async {
        guard let lease = try? boundLease() else {
            monitoringError = ScreenTimeError.unboundContext.localizedDescription
            return
        }
        let operation = beginOperation()
        defer { endOperation(operation) }
        authorizationFailure = nil
        do {
            let worker = worker
            try await worker.perform {
                try lease.whileCurrent {
                    guard lease.binding.matches(try worker.store.snapshot()) else { throw ScreenTimeError.unboundContext }
                }
                try worker.monitoring.invalidateAuthorizationIfNeeded()
            }
            try requireCurrent(lease)
            try await requestIndividualAuthorization()
            try requireCurrent(lease)
            reload()
        } catch {
            guard (try? requireCurrent(lease)) != nil else { return }
            reload()
            // One generic sentence and a retry button left people retrying
            // in a loop for causes a retry cannot fix. Closing Apple's sheet
            // is the user's own answer and needs no message at all.
            authorizationFailure = ScreenTimeAuthorizationFailure(error)
        }
    }

    func save(configuration newConfiguration: ScreenTimeConfiguration, isPro: Bool) async throws {
        guard !isSaving, !isResetting, !isErasing else { throw OperationError.busy }
        try ScreenTimePolicy.validate(newConfiguration, isPro: isPro)
        let lease = try boundLease()
        if newConfiguration.enabled, !Self.isAuthorized(authorization()) { throw ScreenTimeError.unauthorized }
        isSaving = true
        let operation = beginOperation()
        defer {
            if self.lease === lease { isSaving = false }
            endOperation(operation)
        }
        // Only the short receipt lock is taken here. Mark changed runs inactive
        // before yielding so callbacks cannot award against superseded settings.
        try store.update { state in
            try validate(state, lease: lease)
            let old = state.configuration
            for index in state.runs.indices {
                let lane = state.runs[index].lane
                let changed = lane == .learning
                    ? old.learningSelection != newConfiguration.learningSelection || old.themeID != newConfiguration.themeID
                    : old.distractionSelection != newConfiguration.distractionSelection
                if changed || old.enabled != newConfiguration.enabled { state.runs[index].active = false }
            }
            state.configuration = newConfiguration
            state.learningAllowedBySubscription = isPro || newConfiguration.learningSelection.applicationTokens.count <= ScreenTimePolicy.freeLearningApplicationLimit
            state.monitoringError = nil
            state.pruneConsumedRuns()
        }
        reload()
        do { try await synchronize(lease) }
        catch {
            if self.lease === lease { reload() }
            throw error
        }
    }

    /// `isPro` is nil while StoreKit has not answered yet
    /// (`PurchaseManager.hasResolvedEntitlements`). An unknown entitlement may
    /// keep or relax the learning gate the ledger already holds, but never
    /// tighten it: treating "not known yet" as a refund retired Pro users'
    /// learning runs at cold launches and threw away their unfinished 10
    /// minutes. A real downgrade still arrives as `false` and still retires.
    ///
    /// `learningPause` is how long the focus timer holds the learning lane.
    /// It is stored with its end, so the hold ends by itself when the phase
    /// ends — even if PomoGem is closed by then — and the next synchronize
    /// pre-arms the learning run to start at that moment.
    func reconcile(isPro: Bool?, learningPause: ScreenTimeLearningPause, now: Date = .now) async {
        guard let lease = updatePolicy(isPro: isPro, learningPause: learningPause, now: now) else { return }
        await finishReconciliation(lease)
    }

    /// SwiftUI change handlers call this synchronously so even a rapid
    /// pause/resume closes the old run before another UI event is delivered.
    func reconcileInBackground(
        contextKey: String,
        dataEpochID: UUID?,
        isPro: Bool?,
        learningPause: ScreenTimeLearningPause,
        now: Date = .now
    ) {
        guard isBound(contextKey: contextKey, dataEpochID: dataEpochID),
              let lease = updatePolicy(isPro: isPro, learningPause: learningPause, now: now) else { return }
        Task { await finishReconciliation(lease) }
    }

    private func updatePolicy(
        isPro: Bool?,
        learningPause: ScreenTimeLearningPause,
        now: Date
    ) -> ScreenTimeContextLease? {
        guard let lease = try? boundLease() else { reload(); return nil }
        do {
            // Never wait for the monitoring lock to close the receipt gate.
            try store.update { state in
                try validate(state, lease: lease)
                state.learningAllowedBySubscription = ScreenTimePolicy.learningAllowedBySubscription(
                    isPro: isPro,
                    learningApplicationCount: state.configuration.learningSelection.applicationTokens.count,
                    previouslyAllowed: state.learningAllowedBySubscription
                )
                // Keep this retirement even if a later resume arrives before
                // the OS returns. The old run must not count timer usage.
                state.applyTimerPause(learningPause, now: now)
                if !state.learningAllowedBySubscription {
                    for index in state.runs.indices where state.runs[index].lane == .learning {
                        state.runs[index].active = false
                    }
                    state.pruneConsumedRuns()
                }
                // Only an explicit denial voids the selections: the status can
                // read .notDetermined before Family Controls answers at a cold
                // launch, and a wipe there costs a new picker session.
                if authorization() == .denied { state.invalidateAuthorization() }
            }
            reload()
            return lease
        } catch {
            monitoringError = error.localizedDescription
            return nil
        }
    }

    private func finishReconciliation(_ lease: ScreenTimeContextLease) async {
        guard (try? requireCurrent(lease)) != nil else { return }
        let operation = beginOperation()
        defer { endOperation(operation) }
        do { try await synchronize(lease) }
        catch {
            guard self.lease === lease else { return }
            isMonitoring = false
            monitoringError = error.localizedDescription
        }
    }

    /// Starts a new authorization-observation session. SwiftUI tears the
    /// foreground refresh loop down on every deactivation while this controller
    /// is a singleton that survives it, so the loop must announce its restart:
    /// otherwise a stamp recorded by one interrupted pass makes the settling
    /// window measure the whole background gap, and the very first
    /// `.notDetermined` read after a resume — exactly when the transient value
    /// is expected — would destroy the opaque selections.
    func beginAuthorizationObservation() {
        resetAuthorizationSettling()
    }

    /// The foreground refresh loop calls this on every pass. `reconcile` only
    /// reacts to an approved → not-approved transition inside one process run,
    /// so a revocation performed while the app was not running (iOS Settings →
    /// スクリーンタイム → アクセス, or `AuthorizationCenter.revokeAuthorization`)
    /// would otherwise never be noticed: the status simply reads
    /// `.notDetermined` from the first tick, the stored opaque tokens are dead,
    /// and every re-registration would arm events that match no application.
    ///
    /// `.denied` is the user answering 「許可しない」 and is settled at once.
    /// `.notDetermined` needs the settling window AND a ledger that could not
    /// exist without an approval (`ScreenTimeState.recordsAnApproval`): an
    /// enabled configuration, or a saved application token the picker could
    /// only have produced under an approval. Recording being switched off does
    /// not protect the stored tokens — the OS voids them either way, and a
    /// ledger left holding them would arm a re-registration that matches no
    /// application the next time the user turns recording back on.
    ///
    /// The window is only meaningful while the refresh loop is actually
    /// observing. Call `beginAuthorizationObservation()` whenever that loop
    /// starts, so the elapsed time cannot include a gap the app spent away.
    func invalidateAuthorizationIfRevoked(now: Date = .now) async {
        guard let lease = try? boundLease() else { return }
        let status = authorization()
        guard !Self.isAuthorized(status) else {
            resetAuthorizationSettling()
            return
        }
        guard let state = try? store.snapshot(), lease.binding.matches(state),
              state.contextIsActive, state.recordsAnApproval else {
            resetAuthorizationSettling()
            return
        }
        if status != .denied {
            unsettledAuthorizationObservations += 1
            guard let since = unsettledAuthorizationSince else {
                unsettledAuthorizationSince = now
                return
            }
            guard now.timeIntervalSince(since) >= authorizationSettlingWindow,
                  unsettledAuthorizationObservations >= authorizationSettlingObservations else { return }
        }
        resetAuthorizationSettling()
        let operation = beginOperation()
        defer { endOperation(operation) }
        do {
            try store.update { state in
                try validate(state, lease: lease)
                state.invalidateAuthorization()
            }
            // The registrations carry tokens the OS has already voided. Stop
            // them so a later re-approval registers a fresh selection instead
            // of reviving events that can never fire.
            let worker = worker
            try await worker.perform {
                try worker.store.withMonitoringLock {
                    try lease.whileCurrent {
                        guard lease.binding.matches(try worker.store.snapshot()) else {
                            throw ScreenTimeError.unboundContext
                        }
                    }
                    worker.monitoring.stop()
                }
            }
        } catch {
            // A retired or replaced owner owns the ledger now; reload reports.
        }
        guard (try? requireCurrent(lease)) != nil else { return }
        reload()
    }

    func reload() {
        authorizationStatus = authorization()
        authorizationGranted = Self.isAuthorized(authorizationStatus)
        if authorizationGranted, authorizationFailure != nil { authorizationFailure = nil }
        guard bindingConfirmed, let lease, lease.binding.contextKey == currentContextKey() else {
            clearPublishedState()
            return
        }
        do {
            let state = try store.snapshot()
            // Before the owner guard below, not after: the two fields that
            // explain a ledger which counts nothing — `enabled` and
            // `contextIsActive` — are exactly the ones a mirror written only
            // on the happy path could never show as false.
            mirrorDiagnostics(state)
            guard lease.binding.matches(state), state.contextIsActive else {
                clearPublishedState()
                return
            }
            configuration = state.configuration
            let themeRemoved = noticeDefaults.bool(forKey: Self.themeRemovalNoticeKey(lease.binding.contextKey))
            if learningThemeWasRemoved != themeRemoved { learningThemeWasRemoved = themeRemoved }
            negativeGemCount = state.negativeGemCount
            learningPausedByTimer = state.isLearningPaused(at: .now)
            monitoringError = state.monitoringError
            isMonitoring = authorizationGranted && state.runs.contains(where: \.active)
            if !authorizationGranted && configuration.enabled {
                monitoringError = ScreenTimeError.unauthorized.localizedDescription
            } else if !state.learningAllowedBySubscription && configuration.enabled {
                monitoringError = ScreenTimeError.freeApplicationLimit.localizedDescription
            }
        } catch {
            clearPublishedState()
            monitoringError = error.localizedDescription
        }
    }

    /// Copies the callback diagnostics out of the App Group ledger and into the
    /// app's own container, where a device audit can fetch them without host
    /// root and without the unified log. Called from `reload()`, which every
    /// synchronize pass ends with, so a save, a foreground pass and the
    /// three-second refresh loop all mirror; the monitor extension never can.
    ///
    /// Counting must not be what creates a ledger, and neither must mirroring:
    /// with no ledger on disk there is nothing to copy and nothing is written,
    /// the same rule as `ScreenTimeStore.countCallback`.
    private func mirrorDiagnostics(_ state: ScreenTimeState) {
        guard store.ledgerExists else { return }
        diagnosticsMirror.write(state)
    }

    func resetActivityData() async throws {
        guard !isResetting, !isErasing else { throw OperationError.busy }
        let oldLease = try boundLease()
        oldLease.invalidate()
        let lease = ScreenTimeContextLease(binding: oldLease.binding)
        self.lease = lease
        clearPublishedState()
        isSaving = false
        isResetting = true
        let operation = beginOperation()
        defer {
            if self.lease === lease { isResetting = false }
            endOperation(operation)
        }
        // Close the receipt gate now; stopping registrations may take time.
        try store.update { state in
            try validate(state, lease: lease)
            // Diagnostics survive the reset as a restarted, zeroed set. Wiping
            // them outright would make "every counter 0, nothing ever
            // delivered" — the reading that exonerates the app — a thing the
            // reset itself can produce. A higher `generation` says the counts
            // describe the window after a reset, not the ledger's lifetime.
            let counters = state.callbackCounters
            state = ScreenTimeState()
            state.contextKey = lease.binding.contextKey
            state.dataEpochID = lease.binding.dataEpochID
            state.contextIsActive = true
            state.callbackCounters = counters?.restarted(epoch: state.epoch, dayStart: nil)
        }
        let worker = worker
        try await worker.perform {
            try worker.store.withMonitoringLock {
                try lease.whileCurrent {
                    guard lease.binding.matches(try worker.store.snapshot()) else { throw ScreenTimeError.unboundContext }
                }
                worker.monitoring.stop()
            }
        }
        try requireCurrent(lease)
        reload()
    }

    /// 「黒い石を片付ける」: sets the black-stone count back to 0 and nothing
    /// else. The app selections, recording, runs and their `highestThreshold`
    /// stay, so monitoring is not re-registered and a later threshold of the
    /// same run still adds only the minutes after the one already counted —
    /// nothing is counted twice. The only other way to clear the stones was
    /// the full reset, which also throws away both app selections.
    func clearBlackStones() throws {
        guard !isSaving, !isResetting, !isErasing else { throw OperationError.busy }
        let lease = try boundLease()
        try store.update { state in
            try validate(state, lease: lease)
            state.negativeGemCount = 0
        }
        reload()
    }

    func suspendForContextRetirement(contextKey: String, dataEpochID: UUID?) {
        guard lease?.binding == ScreenTimeContextBinding(contextKey: contextKey, dataEpochID: dataEpochID) else { return }
        suspendForContextRetirement()
    }

    func suspendForContextRetirement() {
        guard let retiring = lease else { return }
        retiring.invalidate()
        lease = nil
        bindingTask = nil
        bindingConfirmed = false
        clearPublishedState()
        isSaving = false
        isResetting = false
        operationIDs.removeAll()
        isUpdatingMonitoring = false
        resetAuthorizationSettling()
        bindingError = nil
        authorizationFailure = nil
        // Fence delayed callbacks immediately without waiting for registration.
        try? store.update { state in
            guard retiring.binding.matches(state) else { return }
            state.contextIsActive = false
            for index in state.runs.indices { state.runs[index].active = false }
            state.pruneConsumedRuns()
        }
        worker.retire(retiring.binding)
    }

    /// Awaited by complete deletion before other device state is erased. No
    /// suspended save/bind can re-create registrations after this barrier.
    func eraseAllData() async throws {
        guard !isErasing else { throw OperationError.busy }
        isErasing = true
        defer { isErasing = false }
        suspendForContextRetirement()
        let worker = worker
        try await worker.perform {
            try worker.store.eraseAllData { worker.monitoring.stop() }
        }
        // The lease is retired and queued writers have drained. A reload
        // cannot recreate this app-container copy until a new owner binds.
        try diagnosticsMirror.eraseAllData()
    }

    /// A barrier for lifecycle cleanup and deterministic regression tests.
    func waitForPendingOperations() async throws {
        try await worker.perform {}
    }

    private func synchronize(_ lease: ScreenTimeContextLease) async throws {
        let worker = worker
        try await worker.perform {
            try lease.whileCurrent {
                let state = try worker.store.snapshot()
                guard lease.binding.matches(state), state.contextIsActive else { throw ScreenTimeError.unboundContext }
            }
            _ = try worker.monitoring.synchronize(now: .now)
        }
        try requireCurrent(lease)
        // Read the current ledger instead of publishing an old command snapshot.
        reload()
    }

    private func boundLease() throws -> ScreenTimeContextLease {
        guard let lease else { throw ScreenTimeError.unboundContext }
        try requireCurrent(lease)
        return lease
    }

    private func requireCurrent(_ lease: ScreenTimeContextLease) throws {
        guard !isErasing, bindingConfirmed, self.lease === lease, lease.binding.contextKey == currentContextKey() else {
            throw ScreenTimeError.unboundContext
        }
    }

    private func validate(_ state: ScreenTimeState, lease: ScreenTimeContextLease) throws {
        try requireCurrent(lease)
        guard lease.binding.matches(state), state.contextIsActive else { throw ScreenTimeError.unboundContext }
    }

    private static func isAuthorized(_ status: AuthorizationStatus) -> Bool {
        if status == .approved { return true }
        if #available(iOS 26.4, *), status == .approvedWithDataAccess { return true }
        return false
    }

    private func beginOperation() -> UUID {
        let id = UUID()
        operationIDs.insert(id)
        isUpdatingMonitoring = true
        return id
    }

    private func endOperation(_ id: UUID) {
        operationIDs.remove(id)
        isUpdatingMonitoring = !operationIDs.isEmpty
    }

    private func resetAuthorizationSettling() {
        unsettledAuthorizationSince = nil
        unsettledAuthorizationObservations = 0
    }

    private func publishBindingState() {
        let bound = bindingConfirmed && lease != nil
        if isBoundToContext != bound { isBoundToContext = bound }
    }

    /// Called after the learning selection was cleared because its theme is
    /// gone. Device-local and per owner, like the rest of the Screen Time setup.
    func noteLearningThemeRemoved() {
        guard let lease = try? boundLease() else { return }
        noticeDefaults.set(true, forKey: Self.themeRemovalNoticeKey(lease.binding.contextKey))
        learningThemeWasRemoved = true
    }

    /// The user has chosen again (a save) or started over (a reset).
    func clearLearningThemeRemovalNotice() {
        guard let lease else { return }
        noticeDefaults.removeObject(forKey: Self.themeRemovalNoticeKey(lease.binding.contextKey))
        if learningThemeWasRemoved { learningThemeWasRemoved = false }
    }

    /// The owner key is already namespaced per account and storage mode.
    private static func themeRemovalNoticeKey(_ contextKey: String) -> String {
        "screen-time.learning-theme-removed.\(contextKey)"
    }

    private func clearPublishedState() {
        if learningThemeWasRemoved { learningThemeWasRemoved = false }
        configuration = ScreenTimeConfiguration()
        negativeGemCount = 0
        learningPausedByTimer = false
        monitoringError = nil
        isMonitoring = false
    }
}

/// What the Settings row says about Screen Time, so a stop is visible
/// without opening the page. 要確認 is tied to a real failure (an error the
/// ledger or the permission reports, or a removed destination theme) and
/// never to the documented timer hold or a registration still under way.
enum ScreenTimeRowStatus: Equatable {
    /// Off, not yet known, or nothing to report: describe the feature.
    case feature
    case recording
    case needsAttention
    case themeRemoved

    init(isBound: Bool, enabled: Bool, isMonitoring: Bool, monitoringError: String?, themeRemoved: Bool) {
        guard isBound else { self = .feature; return }
        if themeRemoved { self = .themeRemoved; return }
        guard enabled else { self = .feature; return }
        if monitoringError != nil { self = .needsAttention; return }
        self = isMonitoring ? .recording : .feature
    }

    var subtitle: String {
        switch self {
        case .feature:
            String(localized: "勉強アプリの粒と黒い石を10分ごとに積む", table: "ScreenTime",
                   comment: "Settings row subtitle: Screen Time, when there is nothing to report")
        case .recording:
            String(localized: "自動記録中", table: "ScreenTime", comment: "Settings row subtitle: recording")
        case .needsAttention:
            String(localized: "要確認：自動記録が止まっています", table: "ScreenTime",
                   comment: "Settings row subtitle: recording stopped because of an error")
        case .themeRemoved:
            String(localized: "要確認：記録先のテーマが削除されました", table: "ScreenTime",
                   comment: "Settings row subtitle: the study-app destination theme was deleted")
        }
    }

    var isWarning: Bool { self == .needsAttention || self == .themeRemoved }
}

/// The extra paragraph of the theme-delete confirmation when that theme is
/// where Screen Time records study-app time on this iPhone.
enum ScreenTimeThemeDeletionNotice {
    static func applies(to themeID: UUID, configuration: ScreenTimeConfiguration, isBound: Bool) -> Bool {
        isBound && configuration.themeID == themeID
            && !configuration.learningSelection.applicationTokens.isEmpty
    }

    static var text: String {
        String(localized: "このテーマは、スクリーンタイムで選んだ勉強アプリの記録先です。削除すると勉強アプリの選択も解除され、記録を続けるにはアプリと記録先を選び直す必要があります。",
               table: "ScreenTime", comment: "Theme delete confirmation: the theme is the Screen Time destination")
    }
}

/// What the user can do about a Family Controls authorization request that
/// did not end in an approval. Each `FamilyControlsError` names a different
/// fix, and most of them are outside PomoGem, so the message says where.
/// https://developer.apple.com/documentation/familycontrols/familycontrolserror
enum ScreenTimeAuthorizationFailure: Equatable {
    /// No passcode is set, so there is nothing to confirm the request with.
    case passcodeRequired
    /// Not signed in to an Apple Account, or an account type (a child in
    /// Family Sharing, a managed account) that cannot grant individual access.
    case accountNotSupported
    /// The request needs the network.
    case offline
    /// Another app already provides parental controls on this iPhone.
    case conflictingApp
    /// Screen Time restrictions or a management profile forbid it.
    case restricted
    /// Anything else, including an error this version does not know.
    case other

    /// nil for `authorizationCanceled`: the user closed Apple's sheet, which
    /// is an answer, not a failure to explain.
    init?(_ error: Error) {
        guard let error = error as? FamilyControlsError else {
            self = .other
            return
        }
        switch error {
        case .authorizationCanceled: return nil
        case .authenticationMethodUnavailable: self = .passcodeRequired
        case .invalidAccountType: self = .accountNotSupported
        case .networkError: self = .offline
        case .authorizationConflict: self = .conflictingApp
        case .restricted: self = .restricted
        default: self = .other
        }
    }

    var message: String {
        switch self {
        case .passcodeRequired:
            String(localized: "スクリーンタイムの許可には、iPhoneのパスコードが必要です。設定アプリの「Face IDとパスコード」（または「Touch IDとパスコード」）でパスコードを設定してから、もう一度お試しください。",
                   table: "ScreenTime", comment: "Screen Time access failed: no device passcode")
        case .accountNotSupported:
            String(localized: "このiPhoneのApple Accountでは許可できませんでした。設定アプリの一番上で、Apple Accountにサインインしているか確認してください。ファミリー共有で保護者が管理している子どものアカウントでは、この機能を使えないことがあります。",
                   table: "ScreenTime", comment: "Screen Time access failed: not signed in, or a child or managed account")
        case .offline:
            String(localized: "通信できなかったため、許可を確認できませんでした。インターネットにつながる状態で、もう一度お試しください。",
                   table: "ScreenTime", comment: "Screen Time access failed: network error")
        case .conflictingApp:
            String(localized: "ほかのアプリがこのiPhoneで保護者による管理（ペアレンタルコントロール）をすでに行っているため、許可できませんでした。そのアプリでの管理をやめると、許可できるようになります。",
                   table: "ScreenTime", comment: "Screen Time access failed: another parental-control app holds the authorization")
        case .restricted:
            String(localized: "このiPhoneでは、スクリーンタイムの制限や学校・会社などの管理設定によって許可できません。設定アプリの「スクリーンタイム」の制限や、管理プロファイルを確認してください。",
                   table: "ScreenTime", comment: "Screen Time access failed: restricted by Screen Time limits or device management")
        case .other:
            String(localized: "スクリーンタイムへのアクセスを確認できませんでした。少し時間をおいて、もう一度お試しください。",
                   table: "ScreenTime", comment: "Screen Time access failed for another reason")
        }
    }

    /// Whether the fix lives in the Settings app. There is no public link to
    /// the passcode, Apple Account or Screen Time pages, so the shortcut opens
    /// the Settings app and the message names the page.
    var fixIsInSettingsApp: Bool {
        switch self {
        case .passcodeRequired, .accountNotSupported, .restricted: true
        case .offline, .conflictingApp, .other: false
        }
    }
}

/// Where the host must retire the Screen Time lease itself.
///
/// The ledger lives in the App Group, outside the persistence container, so it
/// does not follow an account or storage boundary. F5 removed the
/// `.onDisappear` retirement from the root modifier — collection belongs to the
/// OS extension and has to continue while the app is not running — which leaves
/// exactly two transitions where RootView goes away and nothing mounts
/// afterwards to notice that the owner has changed. Declaring both here keeps
/// the rule and its call sites from drifting apart, and states the other
/// direction too: an ordinary backgrounding must NOT retire.
enum ScreenTimeOwnerBoundaryPolicy {
    enum HostTransition: CaseIterable {
        /// CKAccountChanged: RootView is dropped in the same turn.
        case accountIdentityChange
        /// An accepted storage transfer: the user is told to quit and reopen,
        /// so no session mounts again in this process.
        case storageTransferRelaunch
        /// PomoGemApp drops the cloud session on `.background`, which removes
        /// RootView for an owner that has not changed.
        case backgroundedSession
        /// The same owner remounting on the next foreground.
        case sessionRemount
    }

    static func retiresLease(for transition: HostTransition) -> Bool {
        switch transition {
        case .accountIdentityChange, .storageTransferRelaunch:
            return true
        case .backgroundedSession, .sessionRemount:
            return false
        }
    }

    @MainActor
    static func retire(
        for transition: HostTransition,
        on controller: ScreenTimeController = .shared
    ) {
        guard retiresLease(for: transition) else { return }
        controller.suspendForContextRetirement()
    }
}
