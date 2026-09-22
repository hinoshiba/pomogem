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
    let store: ScreenTimeStore
    private let monitoring: ScreenTimeMonitoring
    private let currentContextKey: () -> String
    private var isPro = false
    private struct ContextBinding: Equatable {
        let contextKey: String
        let dataEpochID: UUID?

        func matches(_ state: ScreenTimeState) -> Bool {
            state.contextKey == contextKey && state.dataEpochID == dataEpochID
        }
    }
    private var contextBinding: ContextBinding?
    private var isBound: Bool { contextBinding?.contextKey == currentContextKey() }

    init(
        store: ScreenTimeStore = ScreenTimeStore(),
        currentContextKey: @escaping () -> String = {
            AccountScopedLocalState.defaultsKey(base: "screen-time-owner")
        }
    ) {
        self.store = store
        self.currentContextKey = currentContextKey
        self.monitoring = ScreenTimeMonitoring(store: store)
        reload()
    }

    /// Call when the app has resolved its account and activity reset epoch.
    /// A new owner must explicitly opt in; previous owners' tokens are erased.
    func bindContext(contextKey: String, dataEpochID: UUID?) throws {
        guard contextKey == currentContextKey() else { throw ScreenTimeError.unboundContext }
        let binding = ContextBinding(contextKey: contextKey, dataEpochID: dataEpochID)
        if contextBinding != binding {
            contextBinding = nil
            clearPublishedState()
        }
        try store.withMonitoringLock {
            let previous = try store.snapshot()
            if previous.contextKey != contextKey || previous.dataEpochID != dataEpochID {
                monitoring.stop()
                try store.update { state in
                    state = ScreenTimeState()
                    state.contextKey = contextKey
                    state.dataEpochID = dataEpochID
                }
            }
            try store.update { $0.contextIsActive = true }
        }
        contextBinding = binding
        reload()
    }

    func requestAuthorization() async {
        do {
            guard isBound, contextBinding?.matches(try store.snapshot()) == true else {
                throw ScreenTimeError.unboundContext
            }
            // A renewed grant does not make previously issued tokens valid.
            try monitoring.invalidateAuthorizationIfNeeded()
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            reload()
        } catch {
            reload()
            monitoringError = "スクリーンタイムへのアクセスが許可されませんでした。設定を確認してください。"
        }
    }

    func save(configuration newConfiguration: ScreenTimeConfiguration, isPro: Bool) throws {
        try ScreenTimePolicy.validate(newConfiguration, isPro: isPro)
        if newConfiguration.enabled {
            guard isBound else { throw ScreenTimeError.unboundContext }
            guard ScreenTimeMonitoring.isAuthorized else { throw ScreenTimeError.unauthorized }
        }
        self.isPro = isPro
        try store.withMonitoringLock { try store.update { state in
            guard isBound, contextBinding?.matches(state) == true, state.contextIsActive else {
                throw ScreenTimeError.unboundContext
            }
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
        } }
        do { isMonitoring = try monitoring.synchronize() }
        catch { reload(); throw error }
        reload()
    }

    func reconcile(isPro: Bool, timerRunning: Bool) {
        self.isPro = isPro
        guard isBound else { reload(); return }
        do {
            try store.withMonitoringLock { try store.update { state in
                guard isBound, contextBinding?.matches(state) == true, state.contextIsActive else {
                    throw ScreenTimeError.unboundContext
                }
                state.learningPausedByTimer = timerRunning
                state.learningAllowedBySubscription = isPro || state.configuration.learningSelection.applicationTokens.count <= ScreenTimePolicy.freeLearningApplicationLimit
                if !ScreenTimeMonitoring.isAuthorized {
                    state.invalidateAuthorization()
                }
            } }
            isMonitoring = try monitoring.synchronize()
            reload()
        } catch {
            isMonitoring = false
            monitoringError = error.localizedDescription
        }
    }

    func reload() {
        authorizationStatus = AuthorizationCenter.shared.authorizationStatus
        authorizationGranted = ScreenTimeMonitoring.isAuthorized
        guard let contextBinding, contextBinding.contextKey == currentContextKey() else {
            clearPublishedState()
            return
        }
        do {
            let state = try store.snapshot()
            guard contextBinding.matches(state), state.contextIsActive else {
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

    func resetActivityData() throws {
        try store.withMonitoringLock {
            guard isBound, contextBinding?.matches(try store.snapshot()) == true else {
                throw ScreenTimeError.unboundContext
            }
            monitoring.stop()
            try store.update { state in
                let contextKey = state.contextKey
                let dataEpochID = state.dataEpochID
                let contextIsActive = state.contextIsActive
                state = ScreenTimeState()
                state.contextKey = contextKey
                state.dataEpochID = dataEpochID
                state.contextIsActive = contextIsActive
            }
        }
        reload()
    }

    func suspendForContextRetirement(contextKey expectedContextKey: String? = nil) {
        guard let retiringBinding = contextBinding,
              expectedContextKey == nil || expectedContextKey == retiringBinding.contextKey else { return }
        contextBinding = nil
        // Clear synchronously, before disk or framework work. A retiring host
        // must never leave its selected apps or stones in a new host's first frame.
        clearPublishedState()
        do {
            try store.withMonitoringLock {
                // The namespace may already have advanced before the next host
                // binds. Retire the old ledger when it still matches; a new
                // owner's ledger is protected by the stored owner+epoch check.
                guard retiringBinding.matches(try store.snapshot()) else { return }
                monitoring.stop()
                try store.update { state in
                    state.contextIsActive = false
                    for index in state.runs.indices { state.runs[index].active = false }
                    state.pruneConsumedRuns()
                }
            }
        } catch {
            // Ownership could not be confirmed. Keep presentation empty; do not
            // stop another host's registrations using an unverified old cleanup.
        }
    }

    private func clearPublishedState() {
        configuration = ScreenTimeConfiguration()
        negativeGemCount = 0
        learningPausedByTimer = false
        monitoringError = nil
        isMonitoring = false
    }
}
