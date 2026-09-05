import CloudKit
import OSLog
import SwiftData
import SwiftUI
import UIKit

enum PersistenceLaunchMode: Equatable {
    case inMemoryPreview
    case persistentSimulator
    case localOnly
    case cloudKit
}

enum PersistenceSceneTransitionAction: Equatable {
    case preparePersistence
    case retireCloudSession
    case none
}

/// Keeps first presentation independent from the CloudKit account boundary.
/// SwiftUI can run a view task while the initial scene is still inactive; the
/// following active transition must always retry an unloaded launch, including
/// before the user has selected a storage mode.
enum PersistenceLaunchScenePolicy {
    static func action(
        isActive: Bool,
        hasSession: Bool,
        isPreparing: Bool,
        isQuiescingAccountChange: Bool,
        usesCloudAccountBoundary: Bool
    ) -> PersistenceSceneTransitionAction {
        if isActive {
            return !hasSession && !isQuiescingAccountChange
                ? .preparePersistence
                : .none
        }
        guard usesCloudAccountBoundary,
              hasSession || isPreparing else {
            return .none
        }
        return .retireCloudSession
    }
}

enum LocalPreviewLaunchPolicy {
#if DEBUG
    static let environmentKey = "TSUMIBEN_LOCAL_PREVIEW"
    static let uiTestEnvironmentKey = "TSUMIBEN_UI_TEST_MODE"
    static let persistentUITestStoreEnvironmentKey = "TSUMIBEN_UI_TEST_PERSISTENT_STORE"
    static let accessibility5EnvironmentKey = "TSUMIBEN_UI_TEST_AX5"
    static let unselectedRareRewardUITestEnvironmentKey = "TSUMIBEN_UI_TEST_RARE_REWARD_UNSELECTED"
    static let rareRewardOnboardingUITestEnvironmentKey = "TSUMIBEN_UI_TEST_RARE_REWARD_ONBOARDING"
#else
    // Keep the policy API available to ordinary production code while making
    // the test protocol and its environment tokens absent from Release output.
    static let environmentKey = ""
    static let uiTestEnvironmentKey = ""
    static let persistentUITestStoreEnvironmentKey = ""
    static let accessibility5EnvironmentKey = ""
    static let unselectedRareRewardUITestEnvironmentKey = ""
    static let rareRewardOnboardingUITestEnvironmentKey = ""
#endif

    static func isEnabled(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> Bool {
        isDebugBuild && environment[environmentKey] == "1"
    }

    /// UI-test affordances require a second explicit opt-in in addition to the
    /// local in-memory store. This keeps normal Debug previews useful without
    /// changing navigation or accessibility, and Release builds can never
    /// enable the test-only path from an injected process environment.
    static func isUITestMode(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> Bool {
        isDebugBuild
            && environment[uiTestEnvironmentKey] == "1"
            && (isEnabled(environment: environment, isDebugBuild: isDebugBuild)
                || environment[persistentUITestStoreEnvironmentKey] != nil)
    }

    /// Forces the largest Dynamic Type category only inside an explicitly
    /// opted-in Debug UI-test process. Production and ordinary Debug launches
    /// must always continue to follow the user's system text-size setting.
    static func forcesAccessibility5(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> Bool {
        isUITestMode(environment: environment, isDebugBuild: isDebugBuild)
            && environment[accessibility5EnvironmentKey] == "1"
    }

    /// An unsigned Debug simulator app cannot open CloudKit: Core Data starts
    /// that setup asynchronously and CloudKit traps before `ModelContainer`'s
    /// throwing initializer can report an error. Keep explicit previews
    /// in-memory, give ordinary Debug simulator launches their own persistent
    /// local store, and leave device/Release builds on the private iCloud store.
    static func persistenceMode(
        environment: [String: String],
        isDebugBuild: Bool,
        isSimulator: Bool
    ) -> PersistenceLaunchMode {
        if isEnabled(environment: environment, isDebugBuild: isDebugBuild) {
            return .inMemoryPreview
        }
        if isDebugBuild && isSimulator {
            return .persistentSimulator
        }
        return .cloudKit
    }

    static var isEnabledForCurrentProcess: Bool {
#if DEBUG
        isEnabled(environment: ProcessInfo.processInfo.environment, isDebugBuild: true)
#else
        false
#endif
    }

    static var isUITestModeForCurrentProcess: Bool {
#if DEBUG
        isUITestMode(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: true
        )
#else
        false
#endif
    }


    static var persistenceModeForCurrentProcess: PersistenceLaunchMode {
#if DEBUG && targetEnvironment(simulator)
        persistenceMode(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: true,
            isSimulator: true
        )
#elseif DEBUG
        persistenceMode(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: true,
            isSimulator: false
        )
#else
        .cloudKit
#endif
    }
}

@main
@MainActor
struct TsumibenApp: App {
    init() {
        switch LocalPreviewLaunchPolicy.persistenceModeForCurrentProcess {
        case .cloudKit:
            switch PersistenceDeploymentState.load() {
            case .selected(.localOnly):
                // The launch host validates the immutable profile against all
                // persisted artifacts before activating its local namespace.
                break
            case .unselected, .selected(.cloud), .invalid:
                // Fail closed before SwiftUI can instantiate RootView or any
                // CloudKit-backed ModelContainer.
                AccountScopedLocalState.beginCloudBoundary()
            }
        case .inMemoryPreview, .persistentSimulator, .localOnly:
            AccountScopedLocalState.useUnscopedLocalMode()
        }

        // StoreKit delivery must begin before persistence preparation or the
        // first view asks for Pro state. The singleton installs its updates
        // listener, drains unfinished transactions, and reconciles current
        // entitlements as soon as the application object is constructed.
        PurchaseManager.startAtAppLaunch()

        if !ReleaseExternalSurfacePolicy.supportsLiveActivities
            || !FocusActivityPreference.isEnabled()
            || LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess {
            // Apply a persisted opt-out even if the process ended before its
            // previous activity could be retired. UI tests also remove any
            // OS-owned surface left by an interrupted earlier test run.
            Task { @MainActor in
                await FocusActivityManager.shared.endAll()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            TsumibenPersistenceLaunchHost()
                .preferredColorScheme(.dark)
                .tint(TsumibenTheme.amber)
        }
    }
}

@MainActor
private final class TsumibenPersistenceSession: Identifiable {
    let id = UUID()
    let container: ModelContainer
    let mode: PersistenceLaunchMode
    let startupError: String?
    let safetyNotice: String?
    let persistentFixtureActionRawValue: String?
    let accountNamespace: AccountDataNamespace?

    init(
        container: ModelContainer,
        mode: PersistenceLaunchMode,
        startupError: String? = nil,
        safetyNotice: String? = nil,
        persistentFixtureActionRawValue: String? = nil,
        accountNamespace: AccountDataNamespace? = nil
    ) {
        self.container = container
        self.mode = mode
        self.startupError = startupError
        self.safetyNotice = safetyNotice
        self.persistentFixtureActionRawValue = persistentFixtureActionRawValue
        self.accountNamespace = accountNamespace
    }
}

@MainActor
private final class RetiringPersistenceContainerReference {
    weak var value: ModelContainer?

    init(_ value: ModelContainer) {
        self.value = value
    }
}

@MainActor
private struct TsumibenPersistenceLaunchHost: View {
    private static let persistenceLogger = Logger(
        subsystem: "com.hinoshiba.tumiben",
        category: "PersistenceLaunch"
    )

    fileprivate enum LaunchState: Equatable {
        case choosingStorage
        case preparing(String)
        case blocked(String)
        case failed(String)
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var session: TsumibenPersistenceSession?
    @State private var launchState: LaunchState = .preparing("保存方式を確認しています")
    @State private var launchAttempt = 0
    @State private var isPreparing = false
    @State private var requestedCloudSelection = false
    @State private var canChooseLocalOnly = false
    @State private var mustDestroyPersistentStores = false
    @State private var pendingDestructionNamespace: AccountDataNamespace?
    @State private var isQuiescingAccountChange = false
    @State private var retiringContainer: RetiringPersistenceContainerReference?
    @State private var suspendedAccountBinding = AccountScopedLocalState
        .pendingPreviousBinding()

    var body: some View {
        Group {
            if let session {
                loadedContent(session)
                    .id(session.id)
                    .modelContainer(session.container)
            } else {
                PersistenceLaunchStatusView(
                    state: launchState,
                    onRetry: retryLaunch,
                    onChooseCloud: chooseCloudStorage,
                    onChooseLocalOnly: localOnlySelectionAction
                )
            }
        }
        .task(id: launchAttempt) {
            await preparePersistenceIfNeeded()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .CKAccountChanged)
        ) { _ in
            accountIdentityDidChange()
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
        }
    }

    private var localOnlySelectionAction: (() -> Void)? {
        guard canChooseLocalOnly else { return nil }
        return { chooseLocalOnlyStorage() }
    }

    @ViewBuilder
    private func loadedContent(
        _ session: TsumibenPersistenceSession
    ) -> some View {
#if DEBUG && targetEnvironment(simulator)
        if FortyYearPersistentUITestFixture.showsOverviewForCurrentProcess {
            if LocalPreviewLaunchPolicy.forcesAccessibility5(
                environment: ProcessInfo.processInfo.environment,
                isDebugBuild: true
            ) {
                FortyYearOverviewFixtureLaunchView()
                    .environment(\.dynamicTypeSize, .accessibility5)
            } else {
                FortyYearOverviewFixtureLaunchView()
            }
        } else if let rawValue = session.persistentFixtureActionRawValue,
                  let action = FortyYearPersistentUITestFixture.Action(rawValue: rawValue),
                  action != .normal {
            FortyYearPersistentFixtureLaunchView(
                container: session.container,
                action: action
            )
        } else {
            rootContent(session)
        }
#else
        rootContent(session)
#endif
    }

    @ViewBuilder
    private func rootContent(
        _ session: TsumibenPersistenceSession
    ) -> some View {
#if DEBUG && targetEnvironment(simulator)
        if LocalPreviewLaunchPolicy.forcesAccessibility5(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: true
        ) {
            baseRootContent(session)
                .environment(\.dynamicTypeSize, .accessibility5)
        } else {
            baseRootContent(session)
        }
#else
        baseRootContent(session)
#endif
    }

    private func baseRootContent(
        _ session: TsumibenPersistenceSession
    ) -> some View {
        RootView(
            persistenceStartupError: session.startupError,
            persistenceMode: session.mode,
            persistenceSafetyNotice: session.safetyNotice,
            rebuildPersistenceAfterCompleteDeletion: {
                await rebuildAfterCompleteDeletion()
            }
        )
    }

    private func preparePersistenceIfNeeded() async {
        let attempt = launchAttempt
        guard session == nil, !isQuiescingAccountChange else { return }
        isPreparing = true
        defer {
            if launchAttempt == attempt {
                isPreparing = false
            }
        }

        do {
#if DEBUG && targetEnvironment(simulator)
            if let fixtureRequest = FortyYearPersistentUITestFixture.request(
                environment: ProcessInfo.processInfo.environment
            ) {
                let schema = PersistenceStoreTopology.shippingSchema
                let configuration = try FortyYearPersistentUITestFixture.makeConfiguration(
                    schema: schema,
                    request: fixtureRequest
                )
                let container = try ModelContainer(
                    for: schema,
                    configurations: [configuration]
                )
                session = TsumibenPersistenceSession(
                    container: container,
                    mode: .persistentSimulator,
                    persistentFixtureActionRawValue: fixtureRequest.action.rawValue
                )
                return
            }
#endif

            let mode = LocalPreviewLaunchPolicy.persistenceModeForCurrentProcess
            guard mode == .cloudKit else {
                AccountScopedLocalState.useUnscopedLocalMode()
                session = try makeLocalSession(mode: mode)
                return
            }
            let selectionState = PersistenceDeploymentState.load()
            let artifactHistory = PersistenceStoreTopology
                .persistenceArtifactHistory()
            let hasRegistryHistory = AppleAccountBoundaryResolver
                .hasPersistedRegistryHistory()
            let hasBindingHistory = AccountScopedLocalState
                .hasPersistedCloudBindingHistory()
            let validation = PersistenceDeploymentState.validate(
                selectionState: selectionState,
                mountState: PersistenceDeploymentState.loadMountState(),
                artifactHistory: artifactHistory,
                hasCloudRegistryHistory: hasRegistryHistory,
                hasCloudBindingHistory: hasBindingHistory
            )
            guard validation != .recoveryRequired else {
                canChooseLocalOnly = false
                launchState = .blocked(
                    "保存方式の設定と端末内の保存ファイルを安全に対応付けられません。新しい保存方式へ切り替えず、記録を保護しています。"
                )
                return
            }

            let expectedCloudBinding: ActiveAccountLocalBinding?
            switch selectionState {
            case let .selected(.localOnly(namespace)):
                canChooseLocalOnly = false
                AccountScopedLocalState.activateLocalOnly(
                    namespace: namespace
                )
                session = try makeLocalOnlySession(namespace: namespace)
                return

            case let .selected(.cloud(binding)):
                canChooseLocalOnly = false
                expectedCloudBinding = binding

            case .unselected:
                canChooseLocalOnly = true
                expectedCloudBinding = nil
                guard requestedCloudSelection else {
                    launchState = .choosingStorage
                    return
                }

            case .invalid:
                // Invalid selection data is rejected by validation above.
                return
            }

            // Present an unselected storage choice, and mount an already
            // selected local-only store, without waiting for the first active
            // scene callback. Only access to an Apple Account needs an active
            // foreground application.
            guard scenePhase == .active else {
                launchState = .preparing("Apple Accountを確認できるまでお待ちください")
                return
            }

            AccountScopedLocalState.beginCloudBoundary()
            launchState = .preparing("Apple Accountを安全に確認しています")
            let resolvedBoundary = try await AppleAccountBoundaryResolver()
                .resolve(expectedBinding: expectedCloudBinding)
            try Task.checkCancellation()
            guard launchAttempt == attempt else { return }
            try requireActiveLaunchAttempt(
                attempt,
                checkpoint: "before-profile-commit"
            )
            try PersistenceDeploymentState.select(.cloud(
                binding: resolvedBoundary.binding
            ))
            try requireCloudMountAuthorization(
                expectedBinding: resolvedBoundary.binding,
                verifiedBinding: resolvedBoundary.binding,
                attempt: attempt,
                checkpoint: "after-initial-identity"
            )
            requestedCloudSelection = false
            canChooseLocalOnly = false
            if let suspendedAccountBinding,
               suspendedAccountBinding.accountFingerprint
                != resolvedBoundary.binding.accountFingerprint {
                // The process may have been suspended while Settings changed
                // the Apple Account, so neither identity notification is a
                // reliable prerequisite. Retire every OS-owned surface from
                // the prior account before exposing the new namespace.
                await retireExternalTimerState()
            }
            try AccountScopedLocalState.activate(resolvedBoundary.binding)
            let accountNamespace = resolvedBoundary.binding.namespace
            let accountSafetyNotice: String? = nil

            // Version 1.0 does not ship the experimental cross-container delete
            // transaction. Mount the ordinary offline-capable SwiftData store
            // without introducing a deletion-fence network gate at launch.
            guard CompleteDataDeletionReleasePolicy.isEnabled else {
                session = try await makeCloudSession(
                    safetyNotice: accountSafetyNotice,
                    binding: resolvedBoundary.binding,
                    attempt: attempt
                )
                finishVerifiedCloudMount()
                return
            }

            if mustDestroyPersistentStores {
                // Root has already left the hierarchy and quiesced every known
                // writer. The short handoff gives scoped view tasks time to
                // release their SQLite handles before exact-file destruction.
                try? await Task.sleep(for: .milliseconds(180))
                try destroyPersistentArtifacts(
                    for: mode,
                    accountNamespace: pendingDestructionNamespace
                        ?? accountNamespace
                )
                mustDestroyPersistentStores = false
                pendingDestructionNamespace = nil
            }

            let stateStore = try CompleteDataDeletionFileStateStore.live()
            let remoteStore = CloudKitCompleteDataDeletionRemoteStore()
            let preflight = CompleteDataDeletionLaunchPreflight(
                stateStore: stateStore,
                remoteStore: remoteStore,
                availabilityPolicy: .offlineFirst
            )
            let decision = try await preflight.evaluate()
            try Task.checkCancellation()
            guard launchAttempt == attempt else { return }

            switch decision {
            case .allowLegacyStore, .allowGeneration:
                session = try await makeCloudSession(
                    safetyNotice: accountSafetyNotice,
                    binding: resolvedBoundary.binding,
                    attempt: attempt
                )
                finishVerifiedCloudMount()

            case .allowUnverifiedOffline:
                session = try await makeCloudSession(
                    safetyNotice: "iCloudの削除世代を未確認です。次回オンライン時に再照合します（古い記録の再流入を完全には防げません）",
                    binding: resolvedBoundary.binding,
                    attempt: attempt
                )
                finishVerifiedCloudMount()

            case let .eraseLocalStoreBeforeUse(fence):
                launchState = .preparing("別端末の削除をこの端末へ反映しています")
                try destroyPersistentArtifacts(
                    for: mode,
                    accountNamespace: accountNamespace
                )
                try await clearDeviceStateWithoutMountedWriters()
                try await preflight.acknowledgeErasedStore(for: fence)
                try AccountScopedLocalState.activate(resolvedBoundary.binding)
                session = try await makeCloudSession(
                    safetyNotice: accountSafetyNotice,
                    binding: resolvedBoundary.binding,
                    attempt: attempt
                )
                finishVerifiedCloudMount()

            case .resumeDeletion:
                launchState = .preparing("中断された削除を安全な位置から再開しています")
                // No CloudKit-backed ModelContainer is created in this path.
                // Removing the exact old stores first prevents a crash between
                // remote commit and journal removal from reopening stale rows.
                try destroyPersistentArtifacts(
                    for: mode,
                    accountNamespace: accountNamespace
                )
                try await resumePendingDeletion(
                    stateStore: stateStore,
                    remoteStore: remoteStore
                )
                try destroyPersistentArtifacts(
                    for: mode,
                    accountNamespace: accountNamespace
                )
                try AccountScopedLocalState.activate(resolvedBoundary.binding)
                session = try await makeCloudSession(
                    safetyNotice: accountSafetyNotice,
                    binding: resolvedBoundary.binding,
                    attempt: attempt
                )
                finishVerifiedCloudMount()

            case let .block(reason):
                launchState = .blocked(message(for: reason))
            }
        } catch is CancellationError {
            return
        } catch let error as AppleAccountBoundaryResolutionError {
            guard launchAttempt == attempt else { return }
            requestedCloudSelection = false
            canChooseLocalOnly = canOfferLocalOnlySelection
            if suspendedAccountBinding != nil {
                await retireExternalTimerState()
                suspendedAccountBinding = nil
                AccountScopedLocalState.clearPendingPreviousBinding()
            }
            AccountScopedLocalState.deactivate()
            launchState = .blocked(error.localizedDescription)
        } catch {
            guard launchAttempt == attempt else { return }
            requestedCloudSelection = false
            canChooseLocalOnly = canOfferLocalOnlySelection
            if suspendedAccountBinding != nil {
                await retireExternalTimerState()
                suspendedAccountBinding = nil
                AccountScopedLocalState.clearPendingPreviousBinding()
            }
            launchState = .failed(error.localizedDescription)
        }
    }

    private func makeLocalSession(
        mode: PersistenceLaunchMode
    ) throws -> TsumibenPersistenceSession {
        do {
            return TsumibenPersistenceSession(
                container: try PersistenceStoreTopology.makeContainer(for: mode),
                mode: mode
            )
        } catch {
            let emergency = try PersistenceStoreTopology.makeContainer(
                for: .inMemoryPreview
            )
            return TsumibenPersistenceSession(
                container: emergency,
                mode: mode,
                startupError: error.localizedDescription
            )
        }
    }

    private func makeLocalOnlySession(
        namespace: AccountDataNamespace
    ) throws -> TsumibenPersistenceSession {
        // A durable user choice must never fall back to an in-memory container:
        // doing so would make successful-looking edits disappear on relaunch.
        let selection = PersistenceDeploymentSelection.localOnly(
            namespace: namespace
        )
        let container = try PersistenceStoreTopology.makeContainer(
            for: .localOnly,
            accountNamespace: namespace
        )
        guard PersistenceStoreTopology.persistenceArtifactHistory()
            .hasExactCompleteStorePair(for: selection)
        else {
            throw PersistenceStoreTopologyError.incompleteStorePairAfterMount
        }
        let result = TsumibenPersistenceSession(
            container: container,
            mode: .localOnly,
            accountNamespace: namespace
        )
        try PersistenceDeploymentState.recordSuccessfulMount(selection)
        return result
    }

    private func makeCloudSession(
        safetyNotice: String?,
        binding: ActiveAccountLocalBinding,
        attempt: Int
    ) async throws -> TsumibenPersistenceSession {
        // Never substitute a writable in-memory store for a failed shipping
        // store. Even behind an error screen that fallback makes future UI
        // changes dangerously easy to lose. Let the launch host stay blocked
        // with an explicit retry action until durable storage can be opened.
        // Resolve the identity again immediately before constructing the
        // CloudKit stack. The first lookup authorized the immutable profile;
        // this independent lookup authorizes this particular mount attempt.
        let preMountBoundary = try await AppleAccountBoundaryResolver()
            .resolve(expectedBinding: binding)
        try requireCloudMountAuthorization(
            expectedBinding: binding,
            verifiedBinding: preMountBoundary.binding,
            attempt: attempt,
            checkpoint: "before-container"
        )

        // SwiftData does not expose a supported switch that pauses CloudKit
        // mirroring between ModelContainer construction and identity checking.
        // iPhone account changes require leaving the foreground, so inspect the
        // two independent lifecycle signals synchronously on both sides of the
        // constructor. Do not publish or retain the candidate on any failure.
        let container = try PersistenceStoreTopology.makeContainer(
            for: .cloudKit,
            accountNamespace: binding.namespace
        )
        try requireCloudMountAuthorization(
            expectedBinding: binding,
            verifiedBinding: preMountBoundary.binding,
            attempt: attempt,
            checkpoint: "immediately-after-container"
        )

        // Give a queued CKAccountChanged/scene transition an await boundary and
        // independently prove that the account still matches before RootView,
        // writers, or the successful-mount marker become visible.
        let postMountBoundary = try await AppleAccountBoundaryResolver()
            .resolve(expectedBinding: binding)
        try requireCloudMountAuthorization(
            expectedBinding: binding,
            verifiedBinding: postMountBoundary.binding,
            attempt: attempt,
            checkpoint: "after-container-identity"
        )

        let selection = PersistenceDeploymentSelection.cloud(binding: binding)
        guard PersistenceStoreTopology.persistenceArtifactHistory()
            .hasExactCompleteStorePair(for: selection)
        else {
            throw PersistenceStoreTopologyError.incompleteStorePairAfterMount
        }
        try requireCloudMountAuthorization(
            expectedBinding: binding,
            verifiedBinding: postMountBoundary.binding,
            attempt: attempt,
            checkpoint: "before-session-publication"
        )
        let result = TsumibenPersistenceSession(
            container: container,
            mode: .cloudKit,
            safetyNotice: safetyNotice,
            accountNamespace: binding.namespace
        )
        try PersistenceDeploymentState.recordSuccessfulMount(selection)
        return result
    }

    private func requireCloudMountAuthorization(
        expectedBinding: ActiveAccountLocalBinding,
        verifiedBinding: ActiveAccountLocalBinding,
        attempt: Int,
        checkpoint: StaticString
    ) throws {
        try Task.checkCancellation()
        let decision = CloudMountAuthorizationPolicy.evaluate(
            expectedBinding: expectedBinding,
            verifiedBinding: verifiedBinding,
            selectionState: PersistenceDeploymentState.load(),
            generationMatches: launchAttempt == attempt,
            isSceneActive: scenePhase == .active,
            isApplicationActive: UIApplication.shared.applicationState == .active
        )
        guard decision == .allow else {
            Self.persistenceLogger.error(
                "Cloud mount authorization expired at \(String(describing: checkpoint), privacy: .public): \(String(describing: decision), privacy: .public)"
            )
            throw AppleAccountBoundaryResolutionError.blocked(
                .identityUnavailable
            )
        }
    }

    private func requireActiveLaunchAttempt(
        _ attempt: Int,
        checkpoint: StaticString
    ) throws {
        try Task.checkCancellation()
        guard launchAttempt == attempt,
              scenePhase == .active,
              UIApplication.shared.applicationState == .active
        else {
            Self.persistenceLogger.error(
                "Cloud launch became inactive at \(String(describing: checkpoint), privacy: .public)"
            )
            throw AppleAccountBoundaryResolutionError.blocked(
                .identityUnavailable
            )
        }
    }

    private func finishVerifiedCloudMount() {
        NotificationManager.shared
            .resumeTimerSchedulingAfterAccountBoundary()
        suspendedAccountBinding = nil
        AccountScopedLocalState.clearPendingPreviousBinding()
    }

    private func resumePendingDeletion(
        stateStore: CompleteDataDeletionFileStateStore,
        remoteStore: CloudKitCompleteDataDeletionRemoteStore
    ) async throws {
        let temporaryContainer = try PersistenceStoreTopology.makeContainer(
            for: .inMemoryPreview
        )
        let localStore = CompleteDataDeletionModelStore(
            modelContainer: temporaryContainer
        )
        let deviceState = SystemCompleteDataDeletionDeviceState(
            quiescence: {}
        )
        let coordinator = CompleteDataDeletionCoordinator(
            stateStore: stateStore,
            remoteStore: remoteStore,
            localModelStore: localStore,
            deviceState: deviceState,
            phaseObserver: { phase in
                launchState = .preparing(phase.userFacingTitle)
            }
        )
        _ = try await coordinator.deleteAllData()
    }

    private func clearDeviceStateWithoutMountedWriters() async throws {
        let deviceState = SystemCompleteDataDeletionDeviceState(
            quiescence: {}
        )
        try await deviceState.quiesceApplication()
        try await deviceState.clearDeviceState()
    }

    private func destroyPersistentArtifacts(
        for mode: PersistenceLaunchMode,
        accountNamespace: AccountDataNamespace? = nil
    ) throws {
        let storeURLs = try PersistenceStoreTopology.persistentStoreURLs(
            for: mode,
            accountNamespace: accountNamespace
        )
        try CompleteDataDeletionPersistentStoreCleaner.removeStores(at: storeURLs)
        let directArtifacts = try PersistenceStoreTopology
            .deletionArtifactURLs(
                for: mode,
                accountNamespace: accountNamespace
            )
            .filter { !storeURLs.contains($0) }
        try CompleteDataDeletionPersistentStoreCleaner
            .removeExactMigrationArtifacts(at: directArtifacts)
    }

    private func rebuildAfterCompleteDeletion() async {
        pendingDestructionNamespace = session?.accountNamespace
        session = nil
        launchState = .preparing("空の保存領域を準備しています")
        mustDestroyPersistentStores = true
        await Task.yield()
        launchAttempt += 1
    }

    private func retryLaunch() {
        if isQuiescingAccountChange {
            guard retiringContainer?.value == nil else {
                launchState = .blocked(
                    "以前の保存領域はまだ閉じていません。二重に開かないため停止中です。アプリを終了して再起動してください。"
                )
                return
            }
            retiringContainer = nil
            isQuiescingAccountChange = false
            isPreparing = false
        }
        guard !isPreparing else { return }
        if case .unselected = PersistenceDeploymentState.load() {
            requestedCloudSelection = true
        }
        launchState = .preparing("保存領域を再確認しています")
        launchAttempt += 1
    }

    private func chooseCloudStorage() {
        guard !isPreparing else { return }
        guard case .unselected = PersistenceDeploymentState.load() else {
            retryLaunch()
            return
        }
        requestedCloudSelection = true
        launchState = .preparing("Apple Accountを安全に確認しています")
        launchAttempt += 1
    }

    private func chooseLocalOnlyStorage() {
        guard !isPreparing, canOfferLocalOnlySelection else { return }
        do {
            let namespace = AccountDataNamespace()
            try PersistenceDeploymentState.select(
                .localOnly(namespace: namespace)
            )
            AccountScopedLocalState.activateLocalOnly(namespace: namespace)
            requestedCloudSelection = false
            canChooseLocalOnly = false
            launchState = .preparing("このiPhoneの保存領域を準備しています")
            launchAttempt += 1
        } catch {
            canChooseLocalOnly = false
            launchState = .failed(error.localizedDescription)
        }
    }

    private var canOfferLocalOnlySelection: Bool {
        PersistenceDeploymentState.validate(
            selectionState: PersistenceDeploymentState.load(),
            mountState: PersistenceDeploymentState.loadMountState(),
            artifactHistory: PersistenceStoreTopology
                .persistenceArtifactHistory(),
            hasCloudRegistryHistory: AppleAccountBoundaryResolver
                .hasPersistedRegistryHistory(),
            hasCloudBindingHistory: AccountScopedLocalState
                .hasPersistedCloudBindingHistory()
        ) == .needsExplicitChoice
    }

    private var usesCloudAccountBoundary: Bool {
        guard LocalPreviewLaunchPolicy.persistenceModeForCurrentProcess
                == .cloudKit
        else { return false }
        switch PersistenceDeploymentState.load() {
        case .selected(.localOnly), .invalid:
            return false
        case .selected(.cloud):
            return true
        case .unselected:
            return requestedCloudSelection || !canOfferLocalOnlySelection
        }
    }

    private func accountIdentityDidChange() {
        guard usesCloudAccountBoundary else { return }
        // Reject every late request from the old view hierarchy before the
        // first async cleanup yields. A verified replacement account reopens
        // scheduling only after its new container has mounted.
        NotificationManager.shared.suspendTimerSchedulingForAccountBoundary()
        suspendedAccountBinding = suspendedAccountBinding
            ?? AccountScopedLocalState.activeBinding()
        // Clearing the cross-process binding first makes widget/local state
        // fail closed while RootView disappears and its tasks are cancelled.
        AccountScopedLocalState.beginCloudBoundary()
        beginContainerRetirement()
        launchState = .preparing("Apple Accountの変更を確認しています")
        isQuiescingAccountChange = true
        launchAttempt += 1
        let quiescenceAttempt = launchAttempt
        Task { @MainActor in
            await retireExternalTimerState()
            let outcome = await waitForContainerRetirement(
                generation: quiescenceAttempt
            )
            guard launchAttempt == quiescenceAttempt else { return }
            switch outcome {
            case .retired:
                // The first cleanup can race view disappearance. With the
                // global gate still closed, sweep once more after the old
                // container and its view-owned writers are definitively gone.
                await retireExternalTimerState()
                guard launchAttempt == quiescenceAttempt else { return }
                isPreparing = false
                isQuiescingAccountChange = false
                // Start identity resolution only after every known timer-side
                // effect from the previous account has been retired.
                launchAttempt += 1
            case .timedOut:
                isPreparing = false
                Self.persistenceLogger.fault(
                    "Timed out waiting for the prior account container to retire"
                )
                launchState = .blocked(
                    "以前の保存領域が完全に閉じたことを確認できません。二つの保存領域を同時に開かないため停止しました。解放後に再試行するか、アプリを終了して再起動してください。"
                )
            case .cancelled, .continueWaiting:
                return
            }
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        let action = PersistenceLaunchScenePolicy.action(
            isActive: phase == .active,
            hasSession: session != nil,
            isPreparing: isPreparing,
            isQuiescingAccountChange: isQuiescingAccountChange,
            usesCloudAccountBoundary: usesCloudAccountBoundary
        )
        switch action {
        case .preparePersistence:
            launchState = .preparing("保存方式を確認しています")
            launchAttempt += 1
            return
        case .none:
            return
        case .retireCloudSession:
            break
        }

        // Do not leave a CloudKit store mounted while the process is suspended:
        // an account can change before this process receives CKAccountChanged.
        // Timer notifications/Live Activity remain intact for a normal
        // background transition and are retired only on an actual identity
        // notification above.
        suspendedAccountBinding = suspendedAccountBinding
            ?? AccountScopedLocalState.activeBinding()
        beginContainerRetirement()
        launchState = .preparing("Apple Accountを再確認しています")
        isQuiescingAccountChange = true
        launchAttempt += 1
        let quiescenceAttempt = launchAttempt
        Task { @MainActor in
            let outcome = await waitForContainerRetirement(
                generation: quiescenceAttempt
            )
            guard launchAttempt == quiescenceAttempt else { return }
            switch outcome {
            case .retired:
                isPreparing = false
                isQuiescingAccountChange = false
                if scenePhase == .active {
                    launchAttempt += 1
                }
            case .timedOut:
                isPreparing = false
                Self.persistenceLogger.fault(
                    "Timed out waiting for a backgrounded CloudKit container to retire"
                )
                launchState = .blocked(
                    "保存領域が完全に閉じたことを確認できません。二重に開かないため停止しました。解放後に再試行するか、アプリを終了して再起動してください。"
                )
            case .cancelled, .continueWaiting:
                return
            }
        }
    }

    private func beginContainerRetirement() {
        if let container = session?.container {
            retiringContainer = RetiringPersistenceContainerReference(container)
        }
        session = nil
    }

    private func retireExternalTimerState() async {
        if let namespace = suspendedAccountBinding?.namespace {
            FocusPersistence.clearScheduledCompletionNotificationWitness(
                namespace: namespace
            )
        }
        await NotificationManager.shared.cancelAllTimerNotifications()
        await NotificationManager.shared.cancelPassiveNotifications()
        await NotificationManager.shared.clearDeliveredState()
        await FocusActivityManager.shared.endAll()
    }

    private func waitForContainerRetirement(
        generation: Int
    ) async -> PersistenceContainerRetirementPollDecision {
        // 80 × 25 ms = a bounded two-second retirement window. A timeout never
        // authorizes another container; retry may proceed only after the weak
        // reference proves the previous one has subsequently disappeared.
        var budget = PersistenceContainerRetirementPollBudget(maximumPolls: 80)
        while true {
            let outcome = budget.observe(
                isReleased: retiringContainer?.value == nil,
                generationMatches: launchAttempt == generation
            )
            switch outcome {
            case .continueWaiting:
                do {
                    try await Task.sleep(for: .milliseconds(25))
                } catch {
                    return .cancelled
                }
            case .retired:
                retiringContainer = nil
                return .retired
            case .cancelled, .timedOut:
                return outcome
            }
        }
    }

    private func message(
        for reason: CompleteDataDeletionLaunchBlockReason
    ) -> String {
        switch reason {
        case .localDeletionPending:
            "この端末の削除処理を再開する必要があります。"
        case .cloudUnavailable:
            "iCloudへ接続できません。削除処理が始まっているため、接続後に再試行してください。"
        case .remoteDeletionPending:
            "別の端末で削除処理が進行中です。完了後に再試行してください。"
        case .remoteFenceMissing:
            "iCloudの削除世代を確認できません。記録を保護するため、サポートへお問い合わせください。"
        case .remoteFenceInvalid:
            "iCloudの削除世代記録が不正です。古い記録を開かずに保護しています。サポートへお問い合わせください。"
        }
    }
}

private struct PersistenceLaunchStatusView: View {
    private enum StorageConfirmation: String, Identifiable {
        case cloud
        case localOnly

        var id: String { rawValue }
    }

    let state: TsumibenPersistenceLaunchHost.LaunchState
    let onRetry: () -> Void
    let onChooseCloud: () -> Void
    let onChooseLocalOnly: (() -> Void)?

    @State private var storageConfirmation: StorageConfirmation?

    var body: some View {
        ZStack {
            NightBackground()
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: symbol)
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(TsumibenTheme.amber)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(TsumibenTheme.brand(24))
                        .multilineTextAlignment(.center)
                    Text(message)
                        .foregroundStyle(TsumibenTheme.muted)
                        .multilineTextAlignment(.center)

                    if isPreparing {
                        ProgressView()
                            .tint(TsumibenTheme.amber)
                            .accessibilityLabel(message)
                    } else if isChoosingStorage {
                        storageChoiceDisclosure(
                            symbol: "icloud.fill",
                            title: "iCloudに保存して同期",
                            detail: "テーマ名、成果メモ、集中記録、設定、進行中タイマーを、Apple AccountのプライベートiCloudへ送信します。起動・再開時はオンライン確認が必要です。"
                        )
                        Button("iCloudに保存して同期") {
                            storageConfirmation = .cloud
                        }
                        .buttonStyle(TsumibenPrimaryButtonStyle())

                        storageChoiceDisclosure(
                            symbol: "iphone",
                            title: "このiPhoneだけに保存",
                            detail: "iCloudへ送信しません。Version 1では後から自動移行・自動アップロードせず、保存方式も変更できません。"
                        )
                        Button("このiPhoneだけに保存") {
                            storageConfirmation = .localOnly
                        }
                        .buttonStyle(TsumibenSecondaryButtonStyle())

                        Link(destination: AppLinks.privacyPolicy) {
                            Label(
                                "プライバシーポリシー",
                                systemImage: "hand.raised"
                            )
                        }
                        .buttonStyle(TsumibenSecondaryButtonStyle())
                    } else {
                        Button("もう一度試す", action: onRetry)
                            .buttonStyle(TsumibenPrimaryButtonStyle())
                        if onChooseLocalOnly != nil {
                            Button("このiPhoneだけで始める") {
                                storageConfirmation = .localOnly
                            }
                            .buttonStyle(TsumibenSecondaryButtonStyle())
                        }
                        Link(destination: AppLinks.support) {
                            Label("サポートを見る", systemImage: "questionmark.circle")
                        }
                        .buttonStyle(TsumibenSecondaryButtonStyle())
                    }
                }
                .frame(maxWidth: 520)
                .padding(24)
            }
        }
        .alert(item: $storageConfirmation) { confirmation in
            switch confirmation {
            case .cloud:
                Alert(
                    title: Text("iCloudに保存して同期しますか？"),
                    message: Text("テーマ名、成果メモ、集中記録、設定、進行中タイマーをApple AccountのプライベートiCloudへ送信します。オンラインでApple Accountを確認できた後にだけ、この保存方式を確定します。Version 1では後から保存方式を変更できません。"),
                    primaryButton: .cancel(Text("キャンセル")),
                    secondaryButton: .default(Text("確認して続ける")) {
                        onChooseCloud()
                    }
                )
            case .localOnly:
                Alert(
                    title: Text("このiPhoneだけに保存しますか？"),
                    message: Text("この選択はVersion 1では後から変更できず、iCloudへ自動で切り替えたり記録をアップロードしたりしません。後でiCloud同期を始めるには、必要ならJSONを書き出してからアプリを削除・再インストールします。削除するとこのiPhone内の記録は消え、書き出したJSONをアプリへ戻す機能もないため、同期後の記録には引き継げません。"),
                    primaryButton: .cancel(Text("キャンセル")),
                    secondaryButton: .default(Text("このiPhoneだけで始める")) {
                        onChooseLocalOnly?()
                    }
                )
            }
        }
    }

    private func storageChoiceDisclosure(
        symbol: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(TsumibenTheme.amber)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(TsumibenTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(TsumibenTheme.card, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private var isPreparing: Bool {
        if case .preparing = state { return true }
        return false
    }

    private var isChoosingStorage: Bool {
        state == .choosingStorage
    }

    private var title: String {
        switch state {
        case .choosingStorage:
            "iCloud同期を有効にしますか？"
        case .preparing:
            "準備中"
        case .blocked:
            "保存領域を確認できません"
        case .failed:
            "保存領域を準備できませんでした"
        }
    }

    private var message: String {
        switch state {
        case .choosingStorage:
            "有効にすると、同じApple AccountのiPhone間で記録を同期します。利用しない場合は、このiPhoneだけに保存でき、記録はiCloudへ送信されません。"
        case let .preparing(message), let .blocked(message), let .failed(message):
            message
        }
    }

    private var symbol: String {
        switch state {
        case .choosingStorage:
            "externaldrive.badge.icloud"
        case .preparing:
            "hourglass"
        case .blocked:
            "externaldrive.badge.exclamationmark"
        case .failed:
            "externaldrive.badge.exclamationmark"
        }
    }
}
