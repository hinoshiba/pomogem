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
    @Published private(set) var learningPausedByTimer = false
    @Published private(set) var isMonitoring = false
    @Published private(set) var isSaving = false
    @Published private(set) var isResetting = false
    @Published private(set) var isUpdatingMonitoring = false
    let store: ScreenTimeStore
    private let worker: ScreenTimeMonitoringWorker
    private let currentContextKey: () -> String
    private let authorization: () -> AuthorizationStatus
    private var lease: ScreenTimeContextLease?
    private var bindingTask: Task<Void, Error>?
    private var bindingConfirmed = false
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
        authorization: @escaping () -> AuthorizationStatus = { AuthorizationCenter.shared.authorizationStatus }
    ) {
        self.store = store
        self.currentContextKey = currentContextKey
        self.authorization = authorization
        worker = ScreenTimeMonitoringWorker(store: store, monitoring: monitoring ?? ScreenTimeMonitoring(store: store))
        reload()
    }

    func isBound(contextKey: String, dataEpochID: UUID?) -> Bool {
        !isErasing && bindingConfirmed && lease?.binding == ScreenTimeContextBinding(contextKey: contextKey, dataEpochID: dataEpochID)
            && contextKey == currentContextKey()
    }

    /// A changed owner or activity epoch revokes queued work before the first
    /// await. A new owner always starts with empty opt-in settings.
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
                                    state = ScreenTimeState()
                                    state.contextKey = binding.contextKey
                                    state.dataEpochID = binding.dataEpochID
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
                reload()
            } catch {
                if self.lease === newLease {
                    newLease.invalidate()
                    self.lease = nil
                    bindingConfirmed = false
                    bindingTask = nil
                    clearPublishedState()
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
        do {
            let worker = worker
            try await worker.perform {
                try lease.whileCurrent {
                    guard lease.binding.matches(try worker.store.snapshot()) else { throw ScreenTimeError.unboundContext }
                }
                try worker.monitoring.invalidateAuthorizationIfNeeded()
            }
            try requireCurrent(lease)
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            try requireCurrent(lease)
            reload()
        } catch {
            guard (try? requireCurrent(lease)) != nil else { return }
            reload()
            monitoringError = "スクリーンタイムへのアクセスが許可されませんでした。設定を確認してください。"
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

    func reconcile(isPro: Bool, timerRunning: Bool) async {
        guard let lease = updatePolicy(isPro: isPro, timerRunning: timerRunning) else { return }
        await finishReconciliation(lease)
    }

    /// SwiftUI change handlers call this synchronously so even a rapid
    /// pause/resume closes the old run before another UI event is delivered.
    func reconcileInBackground(contextKey: String, dataEpochID: UUID?, isPro: Bool, timerRunning: Bool) {
        guard isBound(contextKey: contextKey, dataEpochID: dataEpochID),
              let lease = updatePolicy(isPro: isPro, timerRunning: timerRunning) else { return }
        Task { await finishReconciliation(lease) }
    }

    private func updatePolicy(isPro: Bool, timerRunning: Bool) -> ScreenTimeContextLease? {
        guard let lease = try? boundLease() else { reload(); return nil }
        do {
            // Never wait for the monitoring lock to close the receipt gate.
            try store.update { state in
                try validate(state, lease: lease)
                state.learningPausedByTimer = timerRunning
                state.learningAllowedBySubscription = isPro || state.configuration.learningSelection.applicationTokens.count <= ScreenTimePolicy.freeLearningApplicationLimit
                // Keep this retirement even if a later resume arrives before
                // the OS returns. The old run must not count timer usage.
                if timerRunning || !state.learningAllowedBySubscription {
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

    func reload() {
        authorizationStatus = authorization()
        authorizationGranted = Self.isAuthorized(authorizationStatus)
        guard bindingConfirmed, let lease, lease.binding.contextKey == currentContextKey() else {
            clearPublishedState()
            return
        }
        do {
            let state = try store.snapshot()
            guard lease.binding.matches(state), state.contextIsActive else {
                clearPublishedState()
                return
            }
            configuration = state.configuration
            negativeGemCount = state.negativeGemCount
            learningPausedByTimer = state.learningPausedByTimer
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
            state = ScreenTimeState()
            state.contextKey = lease.binding.contextKey
            state.dataEpochID = lease.binding.dataEpochID
            state.contextIsActive = true
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

    private func clearPublishedState() {
        configuration = ScreenTimeConfiguration()
        negativeGemCount = 0
        learningPausedByTimer = false
        monitoringError = nil
        isMonitoring = false
    }
}
