import CloudKit
import Observation
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
    case resumeAfterContainerRetirement
    case revalidateOfflineSession
    case retireCloudSession
    case none
}

enum PersistenceOfflineResumeAction: Equatable {
    case keepOffline, retryConnection, retireSession
}

/// Invalidating an expired attempt also changes SwiftUI's task ID. That ID
/// change cancels old work; it must not implicitly request another launch if
/// container cleanup finishes before SwiftUI starts the replacement task.
struct PersistenceLaunchAttemptGate {
    private var suppressedAutomaticAttempt: Int?

    mutating func suppressAutomaticStart(for attempt: Int) {
        suppressedAutomaticAttempt = attempt
    }

    func allowsPreparation(for attempt: Int) -> Bool {
        suppressedAutomaticAttempt != attempt
    }
}

/// Keeps first presentation independent from the CloudKit account boundary.
/// SwiftUI can run a view task while the initial scene is still inactive; the
/// following active transition must always retry an unloaded launch, including
/// before the user has selected a storage mode.
enum PersistenceLaunchScenePolicy {
    /// Inactivity and superseded work are lifecycle interruptions, not failed
    /// account verification. Keep the preparation screen until activation
    /// starts a fresh attempt, without offering recovery for a normal launch.
    static func requireActiveAttempt(
        generationMatches: Bool,
        phase: ScenePhase,
        applicationState: UIApplication.State
    ) throws {
        try Task.checkCancellation()
        guard generationMatches, phase == .active, applicationState == .active else {
            throw CancellationError()
        }
    }

    static func shouldResumeDeferredPreparation(
        phase: ScenePhase,
        isWaitingForActivation: Bool,
        hasSession: Bool,
        isPreparing: Bool
    ) -> Bool {
        isWaitingForActivation && phase == .active && !hasSession && !isPreparing
    }

    static func action(
        phase: ScenePhase,
        hasSession: Bool,
        isPreparing: Bool,
        isQuiescingAccountChange: Bool,
        usesCloudAccountBoundary: Bool,
        didTimeOutContainerRetirement: Bool = false,
        hasRetiringContainers: Bool = false,
        isCloudOfflineSession: Bool = false
    ) -> PersistenceSceneTransitionAction {
        if phase == .active {
            if hasSession, isCloudOfflineSession, !isQuiescingAccountChange {
                return .revalidateOfflineSession
            }
            if !hasSession, isQuiescingAccountChange,
               didTimeOutContainerRetirement, !hasRetiringContainers {
                return .resumeAfterContainerRetirement
            }
            return !hasSession && !isQuiescingAccountChange
                ? .preparePersistence
                : .none
        }
        guard !isQuiescingAccountChange,
              usesCloudAccountBoundary,
              hasSession || isPreparing else {
            return .none
        }
        // An already-admitted .none session has no CloudKit transport to
        // retire. Keep its Root identity and local timer/record state, then
        // revalidate local admission before foreground use can continue.
        if hasSession, isCloudOfflineSession { return .none }
        // Permission panels and Control Center temporarily deactivate the
        // foreground scene. Preserve its verified session and view-owned
        // operations; RootView already pauses foreground maintenance. An
        // unpublished launch still loses authorization on any deactivation.
        if phase == .inactive, hasSession {
            return .none
        }
        return .retireCloudSession
    }

    /// Reuses only the already-published local copy; this never authorizes a
    /// constructor or clears an account revocation. Failed reads arrive as nil
    /// observations and cannot be treated as an absent pending operation.
    static func offlineResumeAction(
        sessionNamespace: AccountDataNamespace?,
        activeBinding: ActiveAccountLocalBinding?,
        conditions: CloudOfflineAccessConditions?,
        receipt: CloudOfflineAccessReceipt?,
        revocationWriteFailed: Bool,
        networkIsOffline: Bool?
    ) -> PersistenceOfflineResumeAction {
        guard !revocationWriteFailed, let conditions,
              case let .selected(.cloud(binding)) = conditions.selection,
              sessionNamespace == binding.namespace, activeBinding == binding,
              CloudOfflineAccessPolicy.blockReason(conditions: conditions, receipt: receipt) == nil else {
            return .retireSession
        }
        return networkIsOffline == true ? .keepOffline : .retryConnection
    }
}

private struct PomoGemReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    /// Test dependency seam. Production never supplies a value and continues
    /// to follow SwiftUI's live accessibility environment.
    var pomogemReduceMotionOverride: Bool? {
        get { self[PomoGemReduceMotionOverrideKey.self] }
        set { self[PomoGemReduceMotionOverrideKey.self] = newValue }
    }
}

enum LocalPreviewLaunchPolicy {
#if DEBUG
    static let environmentKey = "POMOGEM_LOCAL_PREVIEW"
    static let uiTestEnvironmentKey = "POMOGEM_UI_TEST_MODE"
    static let persistentUITestStoreEnvironmentKey = "POMOGEM_UI_TEST_PERSISTENT_STORE"
    static let accessibility5EnvironmentKey = "POMOGEM_UI_TEST_AX5"
    static let reduceMotionEnvironmentKey = "POMOGEM_UI_TEST_REDUCE_MOTION"
    static let unselectedRareRewardUITestEnvironmentKey = "POMOGEM_UI_TEST_RARE_REWARD_UNSELECTED"
    static let rareRewardOnboardingUITestEnvironmentKey = "POMOGEM_UI_TEST_RARE_REWARD_ONBOARDING"
#else
    // Keep the policy API available to ordinary production code while making
    // the test protocol and its environment tokens absent from Release output.
    static let environmentKey = ""
    static let uiTestEnvironmentKey = ""
    static let persistentUITestStoreEnvironmentKey = ""
    static let accessibility5EnvironmentKey = ""
    static let reduceMotionEnvironmentKey = ""
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

    /// Overrides the real SwiftUI accessibility environment only for an
    /// explicitly opted-in Debug UI-test process. This exercises the same
    /// production path as the device setting instead of mutating JarScene from
    /// a test probe after the view has already appeared.
    static func forcedReduceMotion(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> Bool? {
        guard isUITestMode(
            environment: environment,
            isDebugBuild: isDebugBuild
        ) else { return nil }
        switch environment[reduceMotionEnvironmentKey] {
        case "1": return true
        case "0": return false
        default: return nil
        }
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
struct PomoGemApp: App {
    @UIApplicationDelegateAdaptor(PomoGemAppDelegate.self) private var appDelegate

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

        // A return reminder belongs only to the preceding absence. Cancel it
        // before any asynchronous storage/account recovery on a cold launch.
        NotificationManager.shared.cancelFocusReturnReminder()

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
            PomoGemPersistenceLaunchHost()
                .preferredColorScheme(.dark)
                .tint(PomoGemTheme.amber)
        }
    }
}

@MainActor
private final class PomoGemPersistenceSession: Identifiable {
    let id = UUID()
    let container: ModelContainer
    let viewLifetime: PersistenceViewContainerLifetime
    let mode: PersistenceLaunchMode
    let startupError: String?
    let safetyNotice: String?
    let persistentFixtureActionRawValue: String?
    let accountNamespace: AccountDataNamespace?
    let isCloudOffline: Bool

    init(
        container: ModelContainer,
        mode: PersistenceLaunchMode,
        startupError: String? = nil,
        safetyNotice: String? = nil,
        persistentFixtureActionRawValue: String? = nil,
        accountNamespace: AccountDataNamespace? = nil,
        isCloudOffline: Bool = false
    ) {
        self.container = container
        self.viewLifetime = PersistenceViewContainerLifetime(container: container)
        self.mode = mode
        self.startupError = startupError
        self.safetyNotice = safetyNotice
        self.persistentFixtureActionRawValue = persistentFixtureActionRawValue
        self.accountNamespace = accountNamespace
        self.isCloudOffline = isCloudOffline
    }
}

/// Retains only the store owner while SwiftUI finishes using the old view
/// graph. A ModelContext in the environment does not keep its container alive
/// through every Query update during full-screen presentation teardown.
///
/// This lifetime grants no session authority and holds no Host callbacks.
/// Clearing the active session rejects old transfer requests; the inherited
/// environment keeps Query consumers safe until their graph is released.
final class PersistenceViewContainerLifetime {
    let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }
}

private struct PersistenceViewContainerLifetimeKey: EnvironmentKey {
    static let defaultValue: PersistenceViewContainerLifetime? = nil
}

extension EnvironmentValues {
    var persistenceViewContainerLifetime: PersistenceViewContainerLifetime? {
        get { self[PersistenceViewContainerLifetimeKey.self] }
        set { self[PersistenceViewContainerLifetimeKey.self] = newValue }
    }
}

enum PersistenceContainerRetirementError: LocalizedError, Equatable {
    case previousContainerStillActive

    var errorDescription: String? {
        "以前の保存領域がまだ閉じていません。しばらく待って再試行するか、アプリを終了して再起動してください。記録は削除されません。"
    }
}

/// Tracks candidates as soon as their stores open, before the asynchronous
/// post-mount account check can suspend. Cancelling that check does not promise
/// immediate release, so every live candidate must retire alongside the
/// published session before another generation can open the same stores.
@MainActor
final class PersistenceContainerLifetimeTracker<Container: AnyObject> {
    private final class Reference {
        weak var value: Container?

        init(_ value: Container) {
            self.value = value
        }
    }

    private var references: [Reference] = []

    func track(_ container: Container) {
        references.removeAll { $0.value == nil }
        guard !references.contains(where: { $0.value === container }) else {
            return
        }
        references.append(Reference(container))
    }

    var hasLiveContainers: Bool {
        references.removeAll { $0.value == nil }
        return !references.isEmpty
    }

    func requireAllReleased() throws {
        guard !hasLiveContainers else {
            throw PersistenceContainerRetirementError.previousContainerStillActive
        }
    }
}

/// A captured SwiftUI view value can keep State's previous value alive after
/// its location changes. All Host copies must instead share this reference so
/// clearing the session also clears it from in-flight retirement callbacks.
@MainActor
@Observable
final class PersistenceSessionHolder<Session: AnyObject & Identifiable> {
    var session: Session?

    func resolve(_ id: Session.ID) -> Session? {
        guard let session, session.id == id else { return nil }
        return session
    }
}

@MainActor
private struct PomoGemPersistenceLaunchHost: View {
    private static let persistenceLogger = Logger(
        subsystem: "com.hinoshiba.pomogem",
        category: "PersistenceLaunch"
    )

    fileprivate enum LaunchState: Equatable {
        case choosingStorage
        case preparing(String)
        case blocked(String)
        case failed(String)
        case relaunchRequired(String)
        case offlineRelaunchRequired(String)
        case cloudVerificationTimedOut(String)
        case remoteRecovery(String, canCancel: Bool)
        /// `claimsReplacement` is false for `localLedgerMissing`: the doors on
        /// this screen are the same, but the server's dataset was not
        /// necessarily replaced by anybody, and the title may not say it was.
        case datasetRefresh(String, claimsReplacement: Bool)
        /// P0-2. The server has no transfer ledger at all, so there is nothing
        /// to refresh FROM. Two consented choices, no automatic action.
        case cloudLineageUnavailable(String)
        /// Explanation only: no destructive control, the offline route when it
        /// is eligible, and the support link. Reached by the stop reasons whose
        /// honest remedy is outside this app.
        case datasetExplanation(DatasetExplanation, String)
    }

    /// Which explanation-only screen. Each one carries its own title and its
    /// own second paragraph; neither offers a dataset operation.
    fileprivate enum DatasetExplanation: Equatable {
        /// `cloudEnvironmentMismatch`: this device's receipt was earned in the
        /// other CloudKit environment, so no dataset operation in THIS build
        /// is meaningful against the database it talks to.
        case environmentMismatch
        /// `localLedgerMissing` whose server turned out to have no committed
        /// generation either, so the 「iCloudから再取得」 screen cannot be built.
        case localLedgerMissing
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var sessionHolder = PersistenceSessionHolder<PomoGemPersistenceSession>()
    private var session: PomoGemPersistenceSession? {
        get { sessionHolder.session }
        nonmutating set { sessionHolder.session = newValue }
    }
    @State private var launchState: LaunchState = .preparing("保存方式を確認しています")
    @State private var launchAttempt = 0
    @State private var launchAttemptGate = PersistenceLaunchAttemptGate()
    @State private var isPreparing = false
    @State private var isWaitingForLaunchActivation = false
    @State private var requestedCloudSelection = false
    @State private var canChooseLocalOnly = false
    @State private var mustDestroyPersistentStores = false
    @State private var pendingDestructionNamespace: AccountDataNamespace?
    @State private var isQuiescingAccountChange = false
    @State private var didTimeOutContainerRetirement = false
    @State private var requiresStorageTransferRelaunch = false
    @State private var storageTransferRecoveryBinding: ActiveAccountLocalBinding?
    @State private var storageTransferRecoveryTransactionID: UUID?
    @State private var storageTransferRefreshGenerationID: UUID?
    @State private var cancellableLocalTransferID: UUID?
    @State private var retainsTransferCopyOnCancellation = false
    @State private var remoteRecoveryAction: RemoteRecoveryAction?
    @State private var cloudLaunchDeadline: CloudLaunchDeadline?
    @State private var offlineFallbackRequested = false
    @State private var requestedOnlineCloudLaunch = false
    @State private var offlineRecovery = CloudOfflineRecoveryPresentation()
    @State private var canContinueOffline = false
    @State private var isCheckingOfflineConnection = false
    @State private var offlineRevocationWriteFailed = false
    @State private var offlineConnectionTask: Task<Void, Never>?
    @State private var offlineConnectionAttempt: UUID?
    @State private var offlineMessage = "タイマーや記録を利用できます。接続回復後に同期を再開します。"
    @State private var networkPath = CloudNetworkPathObserver()
    @State private var focusReturnReminderTask: Task<Void, Never>?
    @State private var focusReturnReminderGeneration: UInt64 = 0
    @State private var focusReturnReminderBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    @State private var containerLifetimes =
        PersistenceContainerLifetimeTracker<ModelContainer>()
    @State private var suspendedAccountBinding = AccountScopedLocalState
        .pendingPreviousBinding()

    /// Read-only pre-flight evidence for the `.datasetRefresh` screen. None of
    /// it authorizes anything: it only decides what the screen may say and
    /// whether the destructive door may be armed at all.
    @State private var datasetPreviewRequest: UUID?
    @State private var cloudDatasetPreview: StorageTransferCloudPreview?
    @State private var deviceDatasetPreview: StorageTransferCloudPreview?
    @State private var cloudDatasetPreviewFailed = false
    @State private var overwriteInProgressPhase: StorageTransferJournal.Phase?
    /// PLAN Step 9. Non-blocking banner state, set once per committed
    /// replacement by the single post-commit comparison and never again: the
    /// receipt is deleted whatever the outcome.
    @State private var lateArrivalNotice: StorageTransferLateArrivalPresentation?
    @State private var evaluatedLateArrivalSessions: Set<UUID> = []
    @State private var isExportingDeviceData = false
    @State private var deviceDataExportURL: URL?
    @State private var deviceDataExportError: String?

    private enum RemoteRecoveryAction {
        case resume, cancel, refresh(UUID), cancelPending(UUID)
        /// Device → iCloud. Carries the exact committed generation the screen
        /// displayed, so a dataset that moved on between reading and tapping
        /// fails the CAS instead of replacing something the user never saw.
        case overwrite(UUID)
        /// Device → iCloud with NO generation to fence against, because the
        /// server has no transfer ledger at all. `startCloudLineageFromDevice`
        /// refuses the moment any committed generation exists, so the absence
        /// is re-proved by the runtime rather than trusted from this value.
        case startLineage
        /// The same shape in the opposite direction (W6): iCloud → device for
        /// an account with no transfer ledger. It replaces nothing on the
        /// server and carries no release bit, exactly like `.refresh`.
        case refreshWithoutLineage
    }

    var body: some View {
        Group {
            if let session {
                sessionContent(session)
            } else {
                launchStatusContent
            }
        }
        .task(id: launchAttempt) {
            networkPath.start()
            await preparePersistenceIfNeeded()
        }
        .onChange(of: networkPath.isOffline) { previous, current in
            if previous == true, current == false, session?.isCloudOffline == true {
                retryOfflineConnection()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .CKAccountChanged)
                .receive(on: RunLoop.main)
        ) { _ in
            accountIdentityDidChange()
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
                .receive(on: RunLoop.main)
        ) { _ in
            // SwiftUI and UIKit can report activation in either order. If the
            // scene callback ran first, retry once UIKit is also ready. A
            // running preparation, published session, or settled choice/error
            // must not restart when the second activation notification arrives.
            guard PersistenceLaunchScenePolicy.shouldResumeDeferredPreparation(
                phase: scenePhase,
                isWaitingForActivation: isWaitingForLaunchActivation,
                hasSession: session != nil,
                isPreparing: isPreparing
            ) else { return }
            isWaitingForLaunchActivation = false
            handleScenePhaseChange(.active)
        }
    }

    private var launchStatusContent: some View {
        PersistenceLaunchStatusView(state: launchState, onRetry: retryLaunch,
            onRetryOnline: requestOnlineCloudRetry,
            canRetryOnline: !isPreparing && !isQuiescingAccountChange,
            onChooseCloud: chooseCloudStorage, onChooseLocalOnly: localOnlySelectionAction,
            onRecoverTransfer: { requestRemoteRecovery(.resume) },
            onCancelTransfer: { requestRemoteRecovery(.cancel) },
            onRefreshDataset: requestDatasetRefresh,
            onOverwriteDataset: requestDatasetOverwrite,
            onStartCloudLineage: cloudLineageStartAction,
            onExportDeviceData: deviceDataExportAction,
            onRetryCloudPreview: datasetPreviewRetryAction,
            cloudPreview: cloudDatasetPreview,
            devicePreview: deviceDatasetPreview,
            cloudPreviewFailed: cloudDatasetPreviewFailed,
            overwritePhase: overwriteInProgressPhase,
            onCancelLocalTransfer: localTransferCancellationAction,
            retainsTransferCopyOnCancellation: retainsTransferCopyOnCancellation,
            onContinueOffline: offlineContinuationAction)
            .task(id: datasetPreviewRequest) { await loadDatasetPreviews() }
            .sheet(isPresented: Binding(
                get: { deviceDataExportURL != nil },
                set: { if !$0 { discardDeviceDataExport() } }
            )) {
                if let deviceDataExportURL {
                    PomoGemDataExportShareSheet(fileURL: deviceDataExportURL) { _ in
                        discardDeviceDataExport()
                    }
                }
            }
            .alert("書き出せませんでした", isPresented: Binding(
                get: { deviceDataExportError != nil },
                set: { if !$0 { deviceDataExportError = nil } }
            )) {
                Button("閉じる", role: .cancel) {}
            } message: {
                Text(deviceDataExportError ?? "")
            }
    }

    /// The rescue door `Docs/MultiDeviceCloudSafety.md` asks for on behalf of
    /// the generation that is about to lose. Offered only on the screen that
    /// offers a replacement, and never while one export is already running.
    private var deviceDataExportAction: (() -> Void)? {
        guard case .datasetRefresh = launchState, !isExportingDeviceData,
              deviceDataExportURL == nil, !requiresStorageTransferRelaunch else { return nil }
        return { startDeviceDataExport() }
    }

    /// Offered only on the screen whose copy names it, and only once a read
    /// has actually failed. Re-reading iCloud deletes nothing on either side.
    private var datasetPreviewRetryAction: (() -> Void)? {
        guard screenArmsItsDoorWithAPreflight, cloudDatasetPreviewFailed,
              !isPreparing, !requiresStorageTransferRelaunch,
              storageTransferRecoveryBinding != nil else { return nil }
        return { retryDatasetPreview() }
    }

    /// The two screens that gate a destructive door on a read-only server
    /// enumeration (PLAN §3 S14). `.cloudLineageUnavailable` joined them with
    /// review-1-1 / review-2-2: 「no control record」 says nothing about what
    /// the account's mirrored zone holds, and starting a lineage deletes it.
    private var screenArmsItsDoorWithAPreflight: Bool {
        switch launchState {
        case .datasetRefresh, .cloudLineageUnavailable: true
        default: false
        }
    }

    private func retryDatasetPreview() {
        guard screenArmsItsDoorWithAPreflight, !isPreparing,
              !requiresStorageTransferRelaunch,
              storageTransferRecoveryBinding != nil else { return }
        cloudDatasetPreview = nil
        cloudDatasetPreviewFailed = false
        // A new identity re-fires `.task(id: datasetPreviewRequest)`; the
        // in-flight read's own staleness check drops whatever it returns.
        datasetPreviewRequest = UUID()
    }

    private var offlineContinuationAction: (() -> Void)? {
        guard canContinueOffline, canStartOfflineContinuation else { return nil }
        return { requestOfflineUse() }
    }

    private var canStartOfflineContinuation: Bool {
        guard session == nil, !isPreparing, !isQuiescingAccountChange,
              !requiresStorageTransferRelaunch else { return false }
        return CloudOfflineHostPolicy.offlineMountDecision(
            cloudMirrorWasOpened: StorageTransferProcessState.cloudMirrorWasOpened,
            hasLiveContainers: containerLifetimes.hasLiveContainers) == .allow
    }

    private func sessionContent(_ current: PomoGemPersistenceSession) -> some View {
        // Cleanup only needs a value lease. Retaining the entire session in
        // its network task would also retain SQLite while foreground return
        // waits for the old container to retire.
        let cleanupID = current.mode == .cloudKit && !current.isCloudOffline && current.startupError == nil
            ? current.id : nil
        let cleanupNamespace = current.accountNamespace
        return CloudConnectionSessionContent { loadedContent(current) }
            .id(current.id)
            .modelContainer(current.container)
            .environment(\.persistenceViewContainerLifetime, current.viewLifetime)
            .environment(\.isCloudOfflineSession, current.isCloudOffline)
            .environment(\.cloudConnectionPresentation, connectionPresentation(for: current))
            .environment(\.storageTransferLateArrival,
                         lateArrivalNotice?.sessionID == current.id ? lateArrivalNotice : nil)
            .task(id: scenePhase) {
                if let cleanupID, let cleanupNamespace {
                    // The first settled cloud mount after a commit is also the
                    // one chance the late-arrival receipt gets. Evaluated after
                    // the cleanup queue so a diagnostic never delays it.
                    await retryStorageTransferCleanup(sessionID: cleanupID, namespace: cleanupNamespace)
                    await evaluateReplacementWatch(sessionID: cleanupID, namespace: cleanupNamespace)
                }
            }
    }

    private func connectionPresentation(for current: PomoGemPersistenceSession) -> CloudConnectionPresentation? {
        if current.isCloudOffline {
            let notice = offlineRecovery.notice?.sessionID == current.id ? offlineRecovery.notice : nil
            return CloudConnectionPresentation(sessionID: current.id,
                isChecking: isCheckingOfflineConnection, message: offlineMessage,
                retry: { retryOfflineConnection() }, recoveryKind: notice?.kind,
                reviewRecovery: notice?.kind == .storageTransfer ? {
                    if let notice { requestOfflineRecoveryReview(expectedNotice: notice) }
                } : nil)
        } else if current.mode == .cloudKit, networkPath.isOffline == true {
            return CloudConnectionPresentation(sessionID: current.id, isChecking: false,
                message: "通信の回復を待っています。端末への記録は続けられます。", retry: nil)
        }
        return nil
    }

    @MainActor
    private func retryStorageTransferCleanup(sessionID: UUID, namespace: AccountDataNamespace) async {
        guard scenePhase == .active, session?.id == sessionID,
              let binding = AccountScopedLocalState.activeBinding(),
              binding.namespace == namespace else { return }
        do {
            let runtime = try StorageTransferRuntime.live()
            _ = try await runtime.retryRemoteCleanup(binding: binding, validateAccess: {
                try Task.checkCancellation()
                guard scenePhase == .active, UIApplication.shared.applicationState == .active,
                      session?.id == sessionID, AccountScopedLocalState.activeBinding() == binding else {
                    throw StorageTransferError.staleTransaction
                }
            })
        } catch {
            // The exact minimal queue survives failure or a scene/account
            // change. The next verified cloud session retries it.
        }
    }

    /// PLAN Step 9, the one read-only comparison a committed device → iCloud
    /// replacement is owed.
    ///
    /// It runs at the first settled cloud mount after that commit and never
    /// again: `evaluateReplacementWatch` deletes the receipt whatever the
    /// outcome, so this can neither repeat nor accumulate a file per namespace.
    /// It is a DETECTOR, not a fence — it changes nothing, refuses nothing,
    /// and a device that flushes days later is never caught. With no receipt
    /// present it costs one `stat` and makes no server call at all.
    private func evaluateReplacementWatch(sessionID: UUID, namespace: AccountDataNamespace) async {
        guard scenePhase == .active, session?.id == sessionID,
              lateArrivalNotice == nil,
              !evaluatedLateArrivalSessions.contains(sessionID),
              let binding = AccountScopedLocalState.activeBinding(),
              binding.namespace == namespace,
              let runtime = try? StorageTransferRuntime.live() else { return }
        evaluatedLateArrivalSessions.insert(sessionID)
        let admitted = try? runtime.localDatasetAdmission(binding: binding)
        let outcome = await runtime.evaluateReplacementWatch(
            binding: binding,
            currentGenerationID: admitted?.datasetGenerationID,
            validateAccess: {
                try Task.checkCancellation()
                guard scenePhase == .active, UIApplication.shared.applicationState == .active,
                      session?.id == sessionID,
                      AccountScopedLocalState.activeBinding() == binding else {
                    throw StorageTransferError.staleTransaction
                }
            })
        guard session?.id == sessionID,
              let models = StorageTransferLateArrivalPolicy.reportable(outcome) else { return }
        lateArrivalNotice = StorageTransferLateArrivalPresentation(
            sessionID: sessionID, models: models,
            dismiss: { lateArrivalNotice = nil },
            openSettings: {
                lateArrivalNotice = nil
                NotificationCenter.default.post(name: .pomogemOpenStorageSettings, object: nil)
            })
    }

    private var localOnlySelectionAction: (() -> Void)? {
        guard canChooseLocalOnly else { return nil }
        return { chooseLocalOnlyStorage() }
    }

    private var localTransferCancellationAction: (() -> Void)? {
        guard !isPreparing, !requiresStorageTransferRelaunch,
              let target = cancellableLocalTransferID else { return nil }
        return { requestLocalTransferCancellation(target) }
    }

    @ViewBuilder
    private func loadedContent(
        _ session: PomoGemPersistenceSession
    ) -> some View {
#if DEBUG && targetEnvironment(simulator)
        if StorageTransferSettingsUITestFixture.isActiveForCurrentProcess {
            StorageTransferSettingsUITestFixtureLaunchView()
        } else if FortyYearPersistentUITestFixture.showsOverviewForCurrentProcess {
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
        _ session: PomoGemPersistenceSession
    ) -> some View {
#if DEBUG && targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        let forcesAccessibility5 = LocalPreviewLaunchPolicy.forcesAccessibility5(
            environment: environment,
            isDebugBuild: true
        )
        let forcedReduceMotion = LocalPreviewLaunchPolicy.forcedReduceMotion(
            environment: environment,
            isDebugBuild: true
        )
        if forcesAccessibility5 {
            if let forcedReduceMotion {
                baseRootContent(session)
                    .environment(\.dynamicTypeSize, .accessibility5)
                    .environment(\.pomogemReduceMotionOverride, forcedReduceMotion)
            } else {
                baseRootContent(session)
                    .environment(\.dynamicTypeSize, .accessibility5)
            }
        } else if let forcedReduceMotion {
            baseRootContent(session)
                .environment(\.pomogemReduceMotionOverride, forcedReduceMotion)
        } else {
            baseRootContent(session)
        }
#else
        baseRootContent(session)
#endif
    }

    private func baseRootContent(
        _ session: PomoGemPersistenceSession
    ) -> some View {
        let sessionID = session.id
        return RootView(
            persistenceStartupError: session.startupError,
            persistenceMode: session.mode,
            persistenceSafetyNotice: session.safetyNotice,
            rebuildPersistenceAfterCompleteDeletion: {
                await rebuildAfterCompleteDeletion()
            },
            prepareStorageTransfer: { choice in
                try await prepareStorageTransfer(choice, sessionID: sessionID)
            },
            requestStorageTransferDataset: { direction in
                try await requestStorageTransferDataset(direction, sessionID: sessionID)
            },
            previewStorageTransferDataset: {
                try await previewStorageTransferDataset(sessionID: sessionID)
            },
            unmountForStorageTransfer: {
                unmountForStorageTransfer(sessionID: sessionID)
            }
        )
    }

    private func preparePersistenceIfNeeded() async {
        let attempt = launchAttempt
        guard session == nil, !isQuiescingAccountChange else { return }
        guard launchAttemptGate.allowsPreparation(for: attempt) else { return }
        guard !requiresStorageTransferRelaunch else { return }
        isWaitingForLaunchActivation = false
        isPreparing = true
        canContinueOffline = false
        var ownedDeadline: CloudLaunchDeadline?
        defer {
            ownedDeadline?.cancel()
            if let ownedDeadline, cloudLaunchDeadline === ownedDeadline {
                cloudLaunchDeadline = nil
            }
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
                session = PomoGemPersistenceSession(
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
            // Even an empty transfer-cleanup queue validates foreground
            // access. Defer before entering it on the initial inactive frame.
            try requireActiveLaunchAttempt(attempt, checkpoint: "before-launch-preparation")
            let transferRuntime = try StorageTransferRuntime.live()
            try transferRuntime.resumeLocalCleanup(validateAccess: {
                try requireActiveLaunchAttempt(attempt, checkpoint: "during-transfer-copy-cleanup")
            })
            if try transferRuntime.pendingRemoteCancellationIntent() != nil {
                canChooseLocalOnly = false
                remoteRecoveryAction = nil
                try containerLifetimes.requireAllReleased()
                launchState = .preparing("中断されたiCloudの切り替え取消を再開しています")
                try await transferRuntime.resumeRemoteCancellation(validateAccess: {
                    try requireActiveLaunchAttempt(attempt, checkpoint: "during-remote-cancellation-resume")
                })
                try requireActiveLaunchAttempt(attempt, checkpoint: "after-remote-cancellation-resume")
                requireStorageTransferRelaunch(message: "切り替えを取り消しました。元の記録を保護したまま、アプリを終了して開き直してください。")
                return
            }
            // A direction confirmed in Settings before the relaunch this host
            // required. Read once and deleted in the same breath, whatever it
            // held: nothing destructive has happened yet, so a request that
            // cannot be honoured is dropped rather than retried.
            if let request = try transferRuntime.consumeDatasetRequest() {
                if remoteRecoveryAction == nil,
                   case let .selected(.cloud(requestBinding)) = PersistenceDeploymentState.load(),
                   // A nil generation is the durable record that Settings
                   // observed an EMPTY ledger, which most healthy accounts
                   // have (W6). Each direction then dispatches to the entry
                   // point that REQUIRES that absence and re-proves it.
                   let dispatch = request.dispatch(for: requestBinding) {
                    storageTransferRecoveryBinding = requestBinding
                    switch dispatch {
                    case let .overwriteCloudDataset(generation):
                        remoteRecoveryAction = .overwrite(generation)
                    case .startCloudLineageFromDevice:
                        remoteRecoveryAction = .startLineage
                    case let .refreshCloudDataset(generation):
                        // The EXISTING refresh, with no second implementation:
                        // the same action the recovery screen's
                        // 「iCloudから再取得」 dispatches.
                        remoteRecoveryAction = .refresh(generation)
                    case .refreshCloudDatasetWithoutLineage:
                        remoteRecoveryAction = .refreshWithoutLineage
                    }
                }
            }
            if let action = remoteRecoveryAction {
                remoteRecoveryAction = nil
                try requireActiveLaunchAttempt(attempt, checkpoint: "before-transfer-recovery")
                try containerLifetimes.requireAllReleased()
                launchState = .preparing("iCloudの切り替え状況を確認しています")
                var completionMessage: String?
                switch action {
                case .resume:
                    guard let binding = storageTransferRecoveryBinding else { throw StorageTransferError.staleTransaction }
                    guard let transactionID = storageTransferRecoveryTransactionID else { throw StorageTransferError.staleTransaction }
                    try await transferRuntime.recoverRemoteTransfer(binding: binding,
                        expectedTransactionID: transactionID, validateAccess: {
                        try requireActiveLaunchAttempt(attempt, checkpoint: "during-transfer-recovery")
                    })
                case .cancel:
                    guard let binding = storageTransferRecoveryBinding else { throw StorageTransferError.staleTransaction }
                    guard let transactionID = storageTransferRecoveryTransactionID else { throw StorageTransferError.staleTransaction }
                    try await transferRuntime.cancelRemoteTransfer(binding: binding,
                        expectedTransactionID: transactionID, validateAccess: {
                        try requireActiveLaunchAttempt(attempt, checkpoint: "during-transfer-cancellation")
                    })
                    completionMessage = "切り替えを取り消しました。iCloudの記録を残しています。アプリを終了して開き直してください。"
                case let .refresh(generation):
                    guard let binding = storageTransferRecoveryBinding else { throw StorageTransferError.staleTransaction }
                    try await transferRuntime.refreshCloudDataset(binding: binding,
                        expectedGenerationID: generation, validateAccess: {
                        try requireActiveLaunchAttempt(attempt, checkpoint: "during-dataset-refresh")
                    })
                case let .overwrite(generation):
                    guard let binding = storageTransferRecoveryBinding else { throw StorageTransferError.staleTransaction }
                    try await transferRuntime.overwriteCloudDataset(binding: binding,
                        expectedGenerationID: generation, validateAccess: {
                        try requireActiveLaunchAttempt(attempt, checkpoint: "during-dataset-overwrite")
                    })
                    completionMessage = StorageTransferOverwriteCopy.requestAccepted
                case .refreshWithoutLineage:
                    guard let binding = storageTransferRecoveryBinding else { throw StorageTransferError.staleTransaction }
                    // Same journal as the generation-fenced refresh, with the
                    // CAS replaced by the requirement that there is nothing to
                    // CAS against. It refuses the moment a lineage appears.
                    try await transferRuntime.refreshCloudDatasetWithoutLineage(binding: binding,
                        validateAccess: {
                        try requireActiveLaunchAttempt(attempt, checkpoint: "during-dataset-refresh-no-lineage")
                    })
                case .startLineage:
                    guard let binding = storageTransferRecoveryBinding else { throw StorageTransferError.staleTransaction }
                    // Same policy bit and same journal shape as the overwrite.
                    // It refuses the moment ANY committed generation exists, so
                    // the absence the screen was built on is re-proved here.
                    try await transferRuntime.startCloudLineageFromDevice(binding: binding,
                        validateAccess: {
                        try requireActiveLaunchAttempt(attempt, checkpoint: "during-cloud-lineage-start")
                    })
                    completionMessage = StorageTransferLineageCopy.requestAccepted
                case let .cancelPending(transactionID):
                    let retainsCopy = try transferRuntime.pendingLocalJournal()?.retainsImportOnCancellation == true
                    try await transferRuntime.cancelPendingTransfer(expectedTransactionID: transactionID,
                        validateAccess: {
                        try requireActiveLaunchAttempt(attempt, checkpoint: "during-local-transfer-cancellation")
                    })
                    completionMessage = retainsCopy
                        ? "取り込みを取り消しました。元の保存先とiCloudの記録、途中までのコピーを保持しています。アプリを終了して開き直すと、元の保存先から改めて切り替えを開始できます。"
                        : "切り替えを取り消しました。元の記録を残しています。アプリを終了して開き直してください。"
                }
                try requireActiveLaunchAttempt(attempt, checkpoint: "after-transfer-recovery")
                requireStorageTransferRelaunch(message: completionMessage)
                return
            }
            // A journal can describe moved/promoted stores that intentionally
            // do not satisfy the ordinary artifact policy until recovery ends.
            // Inspect it before that policy and before either storage mode opens.
            let pendingTransfer = try transferRuntime.pendingLocalJournal()
            cancellableLocalTransferID = pendingTransfer?.permitsCancellation == true
                ? pendingTransfer?.transactionID : nil
            retainsTransferCopyOnCancellation = pendingTransfer?.retainsImportOnCancellation == true
            overwriteInProgressPhase = pendingTransfer?.choice == .overwriteCloudFromDevice
                ? pendingTransfer?.phase : nil
            if pendingTransfer != nil {
                canChooseLocalOnly = false
                guard scenePhase == .active else {
                    launchState = .preparing("保存先の切り替えを再開する準備をしています")
                    return
                }
                launchState = .preparing("中断された保存先の切り替えを再開しています")
                var cancelledRetainedImport = false
                _ = try await StorageTransferHostJournalGate.resumeIfPending(
                    readPending: { try transferRuntime.pendingLocalJournal() != nil },
                    requireReleased: { try containerLifetimes.requireAllReleased() },
                    validateAccess: {
                        try requireActiveLaunchAttempt(attempt, checkpoint: "during-transfer-resume")
                    },
                    resume: {
                        let outcome = try await transferRuntime.resumePendingTransfer(validateAccess: {
                            try requireActiveLaunchAttempt(attempt, checkpoint: "during-transfer-resume")
                        }, trackContainer: { container, cloudEnabled in
                            if cloudEnabled { StorageTransferProcessState.markCloudMirrorOpened() }
                            containerLifetimes.track(container)
                        })
                        cancelledRetainedImport = outcome == .cancelledRetainingImport
                    }
                )
                if cancelledRetainedImport {
                    requireStorageTransferRelaunch(message: "中断された取り込みの取消しを完了しました。元の保存先とiCloudの記録、途中までのコピーを保持しています。アプリを終了して開き直してください。")
                    return
                }
                launchAttempt += 1
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
                hasCloudBindingHistory: hasBindingHistory,
                hasVerifiedTransferReceipt: PersistenceDeploymentState.hasVerifiedTransferReceipt()
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

            // Transfer recovery may have suspended since the entry check.
            // Confirm the foreground again before starting account access.
            guard scenePhase == .active else {
                launchState = .preparing("Apple Accountを確認できるまでお待ちください")
                return
            }

            if let expectedCloudBinding {
                canContinueOffline = offlineCopyIsEligible(binding: expectedCloudBinding)
            }
            let explicitOnlineRetry = requestedOnlineCloudLaunch
            requestedOnlineCloudLaunch = false
            if let expectedCloudBinding,
               CloudOfflineHostPolicy.prefersOfflineLaunch(explicitOnlineRetry: explicitOnlineRetry,
                   requestedOfflineFallback: offlineFallbackRequested, networkIsOffline: networkPath.isOffline) {
                let wasFallback = offlineFallbackRequested
                offlineFallbackRequested = false
                if try await openOfflineSession(binding: expectedCloudBinding, attempt: attempt) { return }
                if wasFallback || networkPath.isOffline == true {
                    launchState = .blocked("オフラインで利用するための確認済みデータがまだありません。通信が使えるときに一度開いてください。記録や保存先の設定は変更していません。")
                    return
                }
            }

            let hasExistingStore = expectedCloudBinding.map { binding in
                CloudOfflineHostPolicy.hasEstablishedCloudStore(selection: PersistenceDeploymentState.load(),
                    mountState: PersistenceDeploymentState.loadMountState(),
                    hasExactCompleteStorePair: PersistenceStoreTopology.persistenceArtifactHistory()
                        .hasExactCompleteStorePair(for: .cloud(binding: binding)))
            } ?? false
            let deadline = beginCloudLaunchDeadline(attempt: attempt, hasExistingStore: hasExistingStore)
            ownedDeadline = deadline

            AccountScopedLocalState.beginCloudBoundary()
            launchState = .preparing("Apple Accountを安全に確認しています")
            let resolvedBoundary = try await deadline.run {
                try await AppleAccountBoundaryResolver().resolve(expectedBinding: expectedCloudBinding)
            }
            try Task.checkCancellation()
            guard launchAttempt == attempt else { return }
            try requireActiveLaunchAttempt(
                attempt,
                checkpoint: "before-profile-commit"
            )
            storageTransferRecoveryBinding = resolvedBoundary.binding
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
                await retireExternalTimerState(generation: attempt)
                try requireCloudMountAuthorization(
                    expectedBinding: resolvedBoundary.binding,
                    verifiedBinding: resolvedBoundary.binding,
                    attempt: attempt,
                    checkpoint: "after-external-state-retirement"
                )
            }
            try AccountScopedLocalState.activate(resolvedBoundary.binding)
            let accountNamespace = resolvedBoundary.binding.namespace
            let accountSafetyNotice: String? = nil

            // Version 1.0 does not ship the experimental cross-container delete
            // transaction. Mount the ordinary offline-capable SwiftData store
            // without introducing a deletion-fence network gate at launch.
            guard CompleteDataDeletionReleasePolicy.isEnabled else {
                session = try await makeCloudSessionWithinDeadline(
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
                session = try await makeCloudSessionWithinDeadline(
                    safetyNotice: accountSafetyNotice,
                    binding: resolvedBoundary.binding,
                    attempt: attempt
                )
                finishVerifiedCloudMount()

            case .allowUnverifiedOffline:
                session = try await makeCloudSessionWithinDeadline(
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
                session = try await makeCloudSessionWithinDeadline(
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
                session = try await makeCloudSessionWithinDeadline(
                    safetyNotice: accountSafetyNotice,
                    binding: resolvedBoundary.binding,
                    attempt: attempt
                )
                finishVerifiedCloudMount()

            case let .block(reason):
                launchState = .blocked(message(for: reason))
            }
        } catch is CancellationError {
            if launchAttempt == attempt, !Task.isCancelled, !isQuiescingAccountChange {
                isWaitingForLaunchActivation = scenePhase != .active
                    || UIApplication.shared.applicationState != .active
            }
            // Record lifecycle values only; never account identifiers, model
            // contents or store paths. Cancellation must be distinguishable
            // from a watchdog expiry when diagnosing a retained loading view.
            Self.persistenceLogger.info(
                "Launch cancelled attempt=\(attempt) current=\(launchAttempt) taskCancelled=\(Task.isCancelled) active=\(scenePhase == .active) quiescing=\(isQuiescingAccountChange) ownsDeadline=\(ownedDeadline != nil && cloudLaunchDeadline === ownedDeadline)"
            )
            return
        } catch let error as CloudOfflineSessionError {
            guard launchAttempt == attempt, !Task.isCancelled else { return }
            canContinueOffline = false
            // Restart is mandatory only to open this copy with .none. A later
            // online .cloud mount may still use all ordinary admission gates.
            AccountScopedLocalState.deactivate()
            launchState = .offlineRelaunchRequired(error.localizedDescription)
        } catch let error as StorageTransferReleaseError {
            guard launchAttempt == attempt, !Task.isCancelled else { return }
            refreshLocalTransferCancellationTarget()
            canContinueOffline = false
            canChooseLocalOnly = false
            requestedCloudSelection = false
            AccountScopedLocalState.deactivate()
            launchState = .blocked(error.localizedDescription)
        } catch let error as StorageTransferRuntimeError {
            guard launchAttempt == attempt, !Task.isCancelled else { return }
            refreshLocalTransferCancellationTarget()
            canChooseLocalOnly = false
            requestedCloudSelection = false
            AccountScopedLocalState.deactivate()
            // One routing table, in `CloudOfflineHostPolicy`, so a stop reason
            // added to the taxonomy cannot quietly inherit the generic blocked
            // screen and lose the remedy its copy names.
            switch CloudOfflineHostPolicy.launchRoute(for: error) {
            case .relaunch:
                canContinueOffline = false
                requireStorageTransferRelaunch(message: error.localizedDescription)
            case .remoteRecovery:
                canContinueOffline = false
                await presentRemoteStorageRecovery(error: error, attempt: attempt)
            case .datasetRefresh:
                await presentDatasetRefresh(error: error, attempt: attempt)
            case .lineageUnavailable:
                presentCloudLineageUnavailable(error: error)
            case .environmentMismatch:
                launchState = .datasetExplanation(.environmentMismatch, error.localizedDescription)
            case .blocked:
                // A different dataset generation must never reopen the stale
                // local mirror while explicit refresh consent is outstanding.
                launchState = .blocked(error.localizedDescription)
            }
        } catch let error as AppleAccountBoundaryResolutionError {
            guard launchAttempt == attempt, !Task.isCancelled else { return }
            if case let .selected(.cloud(binding)) = PersistenceDeploymentState.load() {
                revokeOfflineForAccountError(error, binding: binding)
                guard launchAttempt == attempt else { return }
            }
            if requestOfflineFallback(after: error, attempt: attempt) { return }
            refreshLocalTransferCancellationTarget()
            requestedCloudSelection = false
            canChooseLocalOnly = canOfferLocalOnlySelection
            if suspendedAccountBinding != nil {
                await retireExternalTimerState(generation: attempt)
                guard launchAttempt == attempt, !Task.isCancelled else { return }
                suspendedAccountBinding = nil
                AccountScopedLocalState.clearPendingPreviousBinding()
            }
            AccountScopedLocalState.deactivate()
            launchState = .blocked(error.localizedDescription)
        } catch {
            guard launchAttempt == attempt, !Task.isCancelled else { return }
            if case let .selected(.cloud(binding)) = PersistenceDeploymentState.load() {
                revokeOfflineForAccountError(error, binding: binding)
                guard launchAttempt == attempt else { return }
            }
            if requestOfflineFallback(after: error, attempt: attempt) { return }
            refreshLocalTransferCancellationTarget()
            requestedCloudSelection = false
            canChooseLocalOnly = canOfferLocalOnlySelection
            if suspendedAccountBinding != nil {
                await retireExternalTimerState(generation: attempt)
                guard launchAttempt == attempt, !Task.isCancelled else { return }
                suspendedAccountBinding = nil
                AccountScopedLocalState.clearPendingPreviousBinding()
            }
            launchState = error is PersistenceContainerRetirementError
                ? .blocked(error.localizedDescription)
                : .failed(error.localizedDescription)
        }
    }

    private func makeLocalSession(
        mode: PersistenceLaunchMode
    ) throws -> PomoGemPersistenceSession {
        do {
            return PomoGemPersistenceSession(
                container: try PersistenceStoreTopology.makeContainer(for: mode),
                mode: mode
            )
        } catch {
            let emergency = try PersistenceStoreTopology.makeContainer(
                for: .inMemoryPreview
            )
            return PomoGemPersistenceSession(
                container: emergency,
                mode: mode,
                startupError: error.localizedDescription
            )
        }
    }

    private func makeLocalOnlySession(
        namespace: AccountDataNamespace
    ) throws -> PomoGemPersistenceSession {
        try containerLifetimes.requireAllReleased()
        // A durable user choice must never fall back to an in-memory container:
        // doing so would make successful-looking edits disappear on relaunch.
        let selection = PersistenceDeploymentSelection.localOnly(
            namespace: namespace
        )
        let container = try PersistenceStoreTopology.makeContainer(
            for: .localOnly,
            accountNamespace: namespace
        )
        containerLifetimes.track(container)
        guard PersistenceStoreTopology.persistenceArtifactHistory()
            .hasExactCompleteStorePair(for: selection)
        else {
            throw PersistenceStoreTopologyError.incompleteStorePairAfterMount
        }
        let result = PomoGemPersistenceSession(
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
    ) async throws -> PomoGemPersistenceSession {
        let offlineState = try CloudOfflineAccessState()
        let offlineReceipt = try offlineState.load()
        try containerLifetimes.requireAllReleased()
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

        // Read remote recovery/control and dataset lineage before constructing
        // ANY ordinary mirror. Server-only pending work survives app deletion;
        // an error here is never permission to open the previous cloud store.
        try await StorageTransferRuntime.live().preflightCloudMount(
            binding: binding,
            validateAccess: {
                try requireCloudMountAuthorization(
                    expectedBinding: binding,
                    verifiedBinding: preMountBoundary.binding,
                    attempt: attempt,
                    checkpoint: "during-transfer-preflight"
                )
            }
        )
        try requireCloudMountAuthorization(
            expectedBinding: binding,
            verifiedBinding: preMountBoundary.binding,
            attempt: attempt,
            checkpoint: "after-transfer-preflight"
        )

        let hasExistingCopy = CloudOfflineHostPolicy.hasEstablishedCloudStore(
            selection: PersistenceDeploymentState.load(), mountState: PersistenceDeploymentState.loadMountState(),
            hasExactCompleteStorePair: PersistenceStoreTopology.persistenceArtifactHistory()
                .hasExactCompleteStorePair(for: .cloud(binding: binding)))
        if hasExistingCopy {
            let matchingReceipt = offlineReceipt?.binding == binding ? offlineReceipt : nil
            if let matchingReceipt, matchingReceipt.origin != .revokedWithoutBaseline {
                guard let admission = try StorageTransferRuntime.live().localDatasetAdmission(binding: binding),
                      CloudOfflineAccessPolicy.matchesVerifiedDataset(receipt: matchingReceipt,
                          datasetGenerationID: admission.datasetGenerationID) else {
                    throw StorageTransferRuntimeError.datasetRefreshRequired
                }
            }
            // A successful earlier mount is not an export acknowledgement.
            // Ordinary online sessions can also retain unsent native history
            // after a poor connection or interruption; inspect every cache.
            try await CloudActivityHistoryPreflight().verifyExistingReplicaBeforeMirroring(
                recordedBaseline: CloudActivityHistoryRecordedBaseline(receipt: matchingReceipt),
                expectedBinding: binding,
                readCurrentLocalMarker: {
                    try readLocalHistoryBeforeCloudMount(binding: binding, attempt: attempt)
                }, validateMount: {
                    try requireActiveLaunchAttempt(attempt, checkpoint: "before-cached-history-export")
                })
            guard await waitForContainerRetirement(generation: attempt) == .retired else {
                throw PersistenceContainerRetirementError.previousContainerStillActive
            }
            try requireActiveLaunchAttempt(attempt, checkpoint: "after-cached-history")
            try await StorageTransferRuntime.live().preflightCloudMount(binding: binding,
                validateAccess: { try requireActiveLaunchAttempt(attempt, checkpoint: "after-cached-history-dataset") })
        }

        // SwiftData does not expose a supported switch that pauses CloudKit
        // mirroring between ModelContainer construction and identity checking.
        // iPhone account changes require leaving the foreground, so inspect the
        // two independent lifecycle signals synchronously on both sides of the
        // constructor. Do not publish or retain the candidate on any failure.
        try containerLifetimes.requireAllReleased()
        StorageTransferProcessState.markCloudMirrorOpened()
        let container = try PersistenceStoreTopology.makeContainer(
            for: .cloudKit,
            accountNamespace: binding.namespace
        )
        containerLifetimes.track(container)
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

        // A new or partially hydrated replica can otherwise create activity
        // under an obsolete reset epoch. Keep Root, bootstrap, and all app
        // writers unmounted until the local winner covers the server history.
        launchState = .preparing("iCloudの記録の履歴を確認しています")
        let historyBoundary = try await StorageTransferHostCloudPublicationGate.verify(
            prepareCandidate: {
                try await CloudActivityHistoryPreflight().run(
                    context: container.mainContext,
                    expectedBinding: binding,
                    validateMount: {
                        try requireCloudMountAuthorization(
                            expectedBinding: binding,
                            verifiedBinding: postMountBoundary.binding,
                            attempt: attempt,
                            checkpoint: "during-history-preflight"
                        )
                    }
                )
                let boundary = try await AppleAccountBoundaryResolver()
                    .resolve(expectedBinding: binding)
                try requireCloudMountAuthorization(
                    expectedBinding: binding,
                    verifiedBinding: boundary.binding,
                    attempt: attempt,
                    checkpoint: "after-history-identity"
                )
                return boundary
            },
            verifyLatestDataset: {
                // Another device may begin or finish replacing the dataset
                // while history/identity requests are suspended. Reject this
                // candidate before its ordinary writers can be published.
                try await StorageTransferRuntime.live().preflightCloudMount(
                    binding: binding,
                    validateAccess: {
                        try requireCloudMountAuthorization(
                            expectedBinding: binding,
                            verifiedBinding: postMountBoundary.binding,
                            attempt: attempt,
                            checkpoint: "during-final-transfer-preflight"
                        )
                    }
                )
            },
            validateMount: {
                try requireCloudMountAuthorization(
                    expectedBinding: binding,
                    verifiedBinding: postMountBoundary.binding,
                    attempt: attempt,
                    checkpoint: "before-cloud-publication"
                )
            }
        )

        let selection = PersistenceDeploymentSelection.cloud(binding: binding)
        guard PersistenceStoreTopology.persistenceArtifactHistory()
            .hasExactCompleteStorePair(for: selection)
        else {
            throw PersistenceStoreTopologyError.incompleteStorePairAfterMount
        }
        try requireCloudMountAuthorization(
            expectedBinding: binding,
            verifiedBinding: historyBoundary.binding,
            attempt: attempt,
            checkpoint: "before-session-publication"
        )
        let result = PomoGemPersistenceSession(
            container: container,
            mode: .cloudKit,
            safetyNotice: safetyNotice,
            accountNamespace: binding.namespace
        )
        try PersistenceDeploymentState.recordSuccessfulMount(selection)
        guard let admission = try StorageTransferRuntime.live().localDatasetAdmission(binding: binding) else {
            throw StorageTransferError.staleTransaction
        }
        let marker = try ActivityResetStore.latestSnapshot(context: ModelContext(container))
        try requireActiveLaunchAttempt(attempt, checkpoint: "before-offline-admission-receipt")
        _ = try offlineState.recordVerifiedOnline(binding: binding,
            datasetGenerationID: admission.datasetGenerationID, resetBaseline: marker,
            expectedReceipt: offlineReceipt)
        return result
    }

    private func readLocalHistoryBeforeCloudMount(binding: ActiveAccountLocalBinding,
                                                 attempt: Int) throws -> ActivityResetSnapshot? {
        try requireActiveLaunchAttempt(attempt, checkpoint: "before-read-only-history")
        try containerLifetimes.requireAllReleased()
        guard CloudOfflineHostPolicy.hasEstablishedCloudStore(
            selection: PersistenceDeploymentState.load(), mountState: PersistenceDeploymentState.loadMountState(),
            hasExactCompleteStorePair: PersistenceStoreTopology.persistenceArtifactHistory()
                .hasExactCompleteStorePair(for: .cloud(binding: binding))) else {
            throw CloudActivityHistoryPreflightError.localHistoryUnavailable
        }
        return try autoreleasepool {
            let reader = try PersistenceStoreTopology.makeReadOnlyCloudContainer(accountNamespace: binding.namespace)
            containerLifetimes.track(reader)
            let context = ModelContext(reader)
            context.autosaveEnabled = false
            let marker = try ActivityResetStore.latestSnapshot(context: context)
            try requireActiveLaunchAttempt(attempt, checkpoint: "after-read-only-history")
            return marker
        }
    }

    private func makeCloudSessionWithinDeadline(safetyNotice: String?, binding: ActiveAccountLocalBinding,
                                               attempt: Int) async throws -> PomoGemPersistenceSession {
        guard let deadline = cloudLaunchDeadline else { throw CloudLaunchDeadlineError.finished }
        let candidate = try await deadline.run {
            try await makeCloudSession(safetyNotice: safetyNotice, binding: binding, attempt: attempt)
        }
        try requireActiveLaunchAttempt(attempt, checkpoint: "after-bounded-cloud-mount")
        try deadline.finish()
        return candidate
    }

    private func beginCloudLaunchDeadline(attempt: Int, hasExistingStore: Bool) -> CloudLaunchDeadline {
        cloudLaunchDeadline?.cancel()
        Self.persistenceLogger.info(
            "Launch deadline started attempt=\(attempt) existingStore=\(hasExistingStore) mirrorOpened=\(StorageTransferProcessState.cloudMirrorWasOpened)"
        )
        var expiryGeneration: Int?
        let deadline = CloudLaunchDeadline(timeout: hasExistingStore
            ? CloudLaunchDeadline.existingStoreTimeout : CloudLaunchDeadline.initialStoreTimeout,
            invalidateAttempt: {
                Self.persistenceLogger.info(
                    "Launch deadline expired attempt=\(attempt) current=\(launchAttempt) hasSession=\(session != nil)"
                )
                guard launchAttempt == attempt, session == nil else { return }
                // Cleanup and SwiftUI task replacement can run in either
                // order. Suppress this invalidation generation even after
                // quiescence ends; a retry/fallback requests a new generation.
                isQuiescingAccountChange = true
                isPreparing = false
                launchAttempt += 1
                launchAttemptGate.suppressAutomaticStart(for: launchAttempt)
                expiryGeneration = launchAttempt
            }, onExpiry: {
                guard let expiryGeneration, launchAttempt == expiryGeneration,
                      session == nil, isQuiescingAccountChange else { return }
                let message = CloudLaunchDeadlineError.expired.localizedDescription
                if StorageTransferProcessState.cloudMirrorWasOpened {
                    offlineFallbackRequested = false
                    canContinueOffline = false
                    launchState = .cloudVerificationTimedOut(message)
                } else {
                    launchState = .blocked(message)
                }
                let expiredGeneration = launchAttempt
                Task { @MainActor in
                    let retirement = await waitForContainerRetirement(generation: expiredGeneration)
                    guard launchAttempt == expiredGeneration else { return }
                    isQuiescingAccountChange = false
                    let recovery = CloudOfflineHostPolicy.timeoutRecoveryAction(
                        cloudMirrorWasOpened: StorageTransferProcessState.cloudMirrorWasOpened,
                        hasExistingStore: hasExistingStore,
                        containersRetired: retirement == .retired,
                        sceneIsActive: scenePhase == .active)
                    switch recovery {
                    case .openOfflineCopy:
                        offlineFallbackRequested = true
                        launchAttempt += 1
                    case .retryOnline:
                        offlineFallbackRequested = false
                        canContinueOffline = false
                        launchState = .cloudVerificationTimedOut(message)
                        didTimeOutContainerRetirement = retirement == .timedOut
                    case .remainBlocked:
                        didTimeOutContainerRetirement = retirement == .timedOut
                    }
                }
            })
        cloudLaunchDeadline = deadline
        return deadline
    }

    private func offlineConditions(binding: ActiveAccountLocalBinding) throws -> CloudOfflineAccessConditions {
        let runtime = try StorageTransferRuntime.live()
        try PomoGemStorageSnapshot.validateSchema(PersistenceStoreTopology.shippingSchema)
        return CloudOfflineAccessConditions(selection: PersistenceDeploymentState.load(),
            mountState: PersistenceDeploymentState.loadMountState(),
            hasExactCompleteStorePair: PersistenceStoreTopology.persistenceArtifactHistory()
                .hasExactCompleteStorePair(for: .cloud(binding: binding)),
            hasPendingTransfer: try runtime.pendingLocalJournal() != nil,
            hasPendingRemoteIntent: try runtime.pendingRemoteCancellationIntent() != nil,
            isSchemaValid: true)
    }

    private func openOfflineSession(binding: ActiveAccountLocalBinding, attempt: Int) async throws -> Bool {
        try requireActiveLaunchAttempt(attempt, checkpoint: "before-offline-copy")
        guard !offlineRevocationWriteFailed else { return false }
        let state = try CloudOfflineAccessState()
        let existing = try state.load()
        let conditions = try offlineConditions(binding: binding)
        let block = existing == nil
            ? CloudOfflineAccessPolicy.legacyAdoptionBlockReason(conditions: conditions, receipt: nil)
            : CloudOfflineAccessPolicy.blockReason(conditions: conditions, receipt: existing)
        guard block == nil else { return false }
        guard CloudOfflineHostPolicy.offlineMountDecision(
            cloudMirrorWasOpened: StorageTransferProcessState.cloudMirrorWasOpened,
            hasLiveContainers: containerLifetimes.hasLiveContainers) != .relaunchRequired else {
            throw CloudOfflineSessionError.relaunchRequired
        }
        guard await waitForContainerRetirement(generation: attempt) == .retired else {
            throw PersistenceContainerRetirementError.previousContainerStillActive
        }
        try requireActiveLaunchAttempt(attempt, checkpoint: "before-offline-container")
        try containerLifetimes.requireAllReleased()
        // Write the offline-use fence before even constructing a context. It
        // survives a crash and forces history checks before the next mirror.
        if existing != nil {
            _ = try state.markOfflineOpened(binding: binding, conditions: offlineConditions(binding: binding))
        }
        let container = try PersistenceStoreTopology.makeOfflineCloudContainer(accountNamespace: binding.namespace)
        containerLifetimes.track(container)
        try requireActiveLaunchAttempt(attempt, checkpoint: "after-offline-container")
        if existing == nil {
            let marker = try ActivityResetStore.latestSnapshot(context: ModelContext(container))
            let admission = try StorageTransferRuntime.live().localDatasetAdmission(binding: binding)
            _ = try state.adoptLegacyMountedCopy(binding: binding, resetBaseline: marker,
                datasetGenerationID: admission?.datasetGenerationID, isDatasetGenerationKnown: admission != nil,
                conditions: offlineConditions(binding: binding), expectedReceipt: nil)
        }
        try AccountScopedLocalState.activate(binding)
        session = PomoGemPersistenceSession(container: container, mode: .cloudKit,
            accountNamespace: binding.namespace, isCloudOffline: true)
        offlineRecovery.notice = nil
        requestedCloudSelection = false
        canChooseLocalOnly = false
        // Local device timers are permitted; this is not an account/network
        // verification and must never record another successful cloud mount.
        NotificationManager.shared.resumeTimerSchedulingAfterAccountBoundary()
        return true
    }

    private func retryOfflineConnection() {
        guard let current = session, current.isCloudOffline, !isCheckingOfflineConnection,
              !isQuiescingAccountChange, scenePhase == .active,
              case let .selected(.cloud(binding)) = PersistenceDeploymentState.load() else { return }
        isCheckingOfflineConnection = true
        let attempt = launchAttempt
        let sessionID = current.id
        let retryID = UUID()
        offlineConnectionAttempt = retryID
        offlineConnectionTask = Task { @MainActor in
            defer {
                if offlineConnectionAttempt == retryID {
                    isCheckingOfflineConnection = false
                    offlineConnectionAttempt = nil
                    offlineConnectionTask = nil
                }
            }
            var valid = true
            let deadline = CloudLaunchDeadline(timeout: CloudLaunchDeadline.existingStoreTimeout,
                invalidateAttempt: { valid = false }, onExpiry: {
                    guard offlineConnectionAttempt == retryID, session?.id == sessionID,
                          launchAttempt == attempt else { return }
                    offlineMessage = "接続を確認できませんでした。端末への記録を続けられます。"
                })
            defer { deadline.cancel() }
            let validate: @MainActor () throws -> Void = {
                try Task.checkCancellation()
                guard valid, launchAttempt == attempt, session?.id == sessionID,
                      offlineConnectionAttempt == retryID,
                      scenePhase == .active, UIApplication.shared.applicationState == .active else {
                    throw CancellationError()
                }
            }
            do {
                try await deadline.run(validate: validate) {
                    _ = try await AppleAccountBoundaryResolver().resolve(expectedBinding: binding)
                    try validate()
                    let runtime = try StorageTransferRuntime.live()
                    try await runtime.preflightCloudMount(binding: binding, validateAccess: validate)
                    guard let receipt = try CloudOfflineAccessState().load(), receipt.binding == binding else {
                        throw CloudOfflineAccessStateError.invalidReceipt
                    }
                    guard let admission = try runtime.localDatasetAdmission(binding: binding),
                          CloudOfflineAccessPolicy.matchesVerifiedDataset(receipt: receipt,
                              datasetGenerationID: admission.datasetGenerationID) else {
                        throw StorageTransferRuntimeError.datasetRefreshRequired
                    }
                    try await CloudActivityHistoryPreflight().verifyExistingReplicaBeforeMirroring(
                        recordedBaseline: CloudActivityHistoryRecordedBaseline(receipt: receipt),
                        expectedBinding: binding, readCurrentLocalMarker: {
                            try validate()
                            guard let offlineSession = session, offlineSession.id == sessionID,
                                  offlineSession.isCloudOffline else { throw CancellationError() }
                            let reader = ModelContext(offlineSession.container)
                            reader.autosaveEnabled = false
                            return try ActivityResetStore.latestSnapshot(context: reader)
                        }, validateMount: validate)
                    try validate()
                }
                try deadline.finish()
                try validate()
                // Use the existing bounded session-retirement path. The real
                // mount independently repeats all checks after writers close.
                beginContainerRetirement()
                isQuiescingAccountChange = true
                launchAttempt += 1
                let generation = launchAttempt
                let retirement = await waitForContainerRetirement(generation: generation)
                guard launchAttempt == generation else { return }
                isQuiescingAccountChange = false
                guard retirement == .retired else {
                    didTimeOutContainerRetirement = retirement == .timedOut
                    launchState = .blocked(PersistenceContainerRetirementError.previousContainerStillActive.localizedDescription)
                    return
                }
                launchAttempt += 1
            } catch is CancellationError { return }
            catch {
                guard launchAttempt == attempt, session?.id == sessionID,
                      offlineConnectionAttempt == retryID else { return }
                revokeOfflineForAccountError(error, binding: binding)
                guard launchAttempt == attempt, session?.id == sessionID,
                      offlineConnectionAttempt == retryID else { return }
                if let kind = CloudOfflineHostPolicy.recoveryKind(after: error) {
                    offlineRecovery.notice = .init(kind: kind, sessionID: sessionID, binding: binding)
                }
                offlineMessage = error.localizedDescription
            }
        }
    }

    private func requestOnlineCloudRetry() {
        guard session == nil, !isPreparing, !isQuiescingAccountChange,
              !requiresStorageTransferRelaunch, scenePhase == .active,
              case .selected(.cloud) = PersistenceDeploymentState.load() else { return }
        offlineFallbackRequested = false
        requestedOnlineCloudLaunch = true
        // Claim the action before returning to SwiftUI so a second tap cannot
        // create a competing attempt while the view task is being scheduled.
        isPreparing = true
        launchState = .preparing("オンラインで保存領域を再確認しています")
        launchAttempt += 1
    }

    private func requestOfflineRecoveryReview(expectedNotice: CloudOfflineRecoveryPresentation.Notice) {
        guard let current = session, current.isCloudOffline, !isPreparing,
              !isCheckingOfflineConnection, !isQuiescingAccountChange,
              !requiresStorageTransferRelaunch, scenePhase == .active,
              UIApplication.shared.applicationState == .active,
              case let .selected(.cloud(binding)) = PersistenceDeploymentState.load(),
              current.accountNamespace == binding.namespace,
              offlineRecovery.takeReview(expectedNotice: expectedNotice, sessionID: current.id, binding: binding) else { return }
        cancelOfflineConnectionCheck()
        offlineFallbackRequested = false
        requestedOnlineCloudLaunch = true
        NotificationManager.shared.suspendTimerSchedulingForAccountBoundary()
        beginContainerRetirement()
        launchState = .preparing("記録を保持したままiCloudの復旧手順を確認しています")
        isQuiescingAccountChange = true
        launchAttempt += 1
        let generation = launchAttempt
        Task { @MainActor in
            let retirement = await waitForContainerRetirement(generation: generation)
            guard launchAttempt == generation else { return }
            isQuiescingAccountChange = false
            guard retirement == .retired else {
                didTimeOutContainerRetirement = retirement == .timedOut
                launchState = .blocked(PersistenceContainerRetirementError.previousContainerStillActive.localizedDescription)
                return
            }
            // The complete online launch independently rereads account, remote
            // control and history. Existing recovery/refresh consent follows;
            // reviewing the instructions never approves replacement or erase.
            launchAttempt += 1
        }
    }

    private func requestOfflineFallback(after error: Error, attempt: Int) -> Bool {
        guard CloudOfflineHostPolicy.allowsOfflineFallback(after: error), launchAttempt == attempt,
              case let .selected(.cloud(binding)) = PersistenceDeploymentState.load(),
              let state = try? CloudOfflineAccessState(),
              let conditions = try? offlineConditions(binding: binding) else { return false }
        do {
            let receipt = try state.load()
            let reason = receipt == nil
                ? CloudOfflineAccessPolicy.legacyAdoptionBlockReason(conditions: conditions, receipt: nil)
                : CloudOfflineAccessPolicy.blockReason(conditions: conditions, receipt: receipt)
            guard reason == nil else { return false }
        } catch { return false }
        cloudLaunchDeadline?.cancel()
        cloudLaunchDeadline = nil
        offlineMessage = "通信を確認できないため、端末のデータで利用を続けています。変更は端末に保存されます。"
        offlineFallbackRequested = true
        isPreparing = false
        launchAttempt += 1
        return true
    }

    private func offlineCopyIsEligible(binding: ActiveAccountLocalBinding) -> Bool {
        guard !offlineRevocationWriteFailed else { return false }
        do {
            let conditions = try offlineConditions(binding: binding)
            let receipt = try CloudOfflineAccessState().load()
            let reason = receipt == nil
                ? CloudOfflineAccessPolicy.legacyAdoptionBlockReason(conditions: conditions, receipt: nil)
                : CloudOfflineAccessPolicy.blockReason(conditions: conditions, receipt: receipt)
            return reason == nil
        } catch { return false }
    }

    private func requestOfflineUse() {
        guard canStartOfflineContinuation,
              case let .selected(.cloud(binding)) = PersistenceDeploymentState.load(),
              offlineCopyIsEligible(binding: binding) else { return }
        offlineFallbackRequested = true
        launchAttempt += 1
    }

    private func revokeOfflineForAccountError(_ error: Error, binding: ActiveAccountLocalBinding) {
        guard let reason = CloudOfflineHostPolicy.revocationReason(for: error) else { return }
        canContinueOffline = false
        do { try CloudOfflineAccessState().revoke(binding: binding, reason: reason) }
        catch { offlineRevocationWriteFailed = true }
        if session != nil { accountIdentityDidChange() }
    }

    private func cancelOfflineConnectionCheck() {
        offlineConnectionAttempt = nil
        offlineConnectionTask?.cancel()
        offlineConnectionTask = nil
        isCheckingOfflineConnection = false
    }

    private func requireCloudMountAuthorization(
        expectedBinding: ActiveAccountLocalBinding,
        verifiedBinding: ActiveAccountLocalBinding,
        attempt: Int,
        checkpoint: StaticString
    ) throws {
        try requireActiveLaunchAttempt(attempt, checkpoint: checkpoint)
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
        try cloudLaunchDeadline?.check()
        do {
            try PersistenceLaunchScenePolicy.requireActiveAttempt(
                generationMatches: launchAttempt == attempt,
                phase: scenePhase,
                applicationState: UIApplication.shared.applicationState
            )
        } catch {
            Self.persistenceLogger.info(
                "Cloud launch became inactive at \(String(describing: checkpoint), privacy: .public)"
            )
            throw error
        }
    }

    private func finishVerifiedCloudMount() {
        offlineRevocationWriteFailed = false
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

    private func prepareStorageTransfer(
        _ choice: StorageTransferChoice,
        sessionID: UUID
    ) async throws {
        guard let sourceSession = sessionHolder.resolve(sessionID) else {
            throw StorageTransferError.staleTransaction
        }
        guard !sourceSession.isCloudOffline else {
            throw StorageTransferRuntimeError.cloudCopyStillPending
        }
        let attempt = launchAttempt
        let source: PersistenceDeploymentSelection
        switch PersistenceDeploymentState.load() {
        case let .selected(selection): source = selection
        default: throw StorageTransferError.staleTransaction
        }
        let runtime = try StorageTransferRuntime.live()
        let validate: @MainActor () throws -> Void = {
            try requireActiveLaunchAttempt(attempt, checkpoint: "during-transfer-request")
            guard !requiresStorageTransferRelaunch,
                  session?.id == sourceSession.id,
                  source.storageLaunchMode == sourceSession.mode,
                  source.storageNamespace == sourceSession.accountNamespace,
                  PersistenceDeploymentState.load() == .selected(source) else {
                throw StorageTransferError.staleTransaction
            }
        }
        try validate()
        do {
            try await runtime.begin(choice: choice, source: source,
                sourceContext: sourceSession.container.mainContext, validateAccess: validate)
            try validate()
        } catch {
            // A cancellation or account callback after the durable request is
            // not permission to leave its old Root writable. Quiescing the
            // hierarchy remains safe even if the pending file is malformed.
            let pendingExists: Bool
            do { pendingExists = try runtime.pendingLocalJournal() != nil }
            catch { pendingExists = true }
            if pendingExists, session?.id == sourceSession.id {
                requireStorageTransferRelaunch()
            }
            throw error
        }
    }

    /// PLAN Step 11. Settings cannot run a dataset direction itself: this
    /// process has already opened the CloudKit mirror, and both entry points
    /// refuse such a process on purpose. So the confirmed direction is recorded
    /// durably and a deliberate relaunch is required; the next launch consumes
    /// the request before any container exists and runs the SAME entry point
    /// the recovery screen runs.
    ///
    /// Nothing destructive happens here. No journal, no checkpoint, no zone and
    /// no store is touched; the only write is the request file, and dropping it
    /// at any later point simply means the user repeats the confirmation.
    private func requestStorageTransferDataset(
        _ direction: StorageTransferDatasetRequestDirection,
        sessionID: UUID
    ) async throws {
        guard let sourceSession = sessionHolder.resolve(sessionID) else {
            throw StorageTransferError.staleTransaction
        }
        guard !sourceSession.isCloudOffline else {
            throw StorageTransferRuntimeError.cloudCopyStillPending
        }
        // Closed features record nothing at all. The runtime entry point that
        // finally executes the direction validates the policy again.
        try StorageTransferDatasetRequestPolicy.validate(direction, policy: .standard)
        let attempt = launchAttempt
        guard case let .selected(source) = PersistenceDeploymentState.load(),
              case let .cloud(binding) = source else {
            throw StorageTransferError.staleTransaction
        }
        let runtime = try StorageTransferRuntime.live()
        let validate: @MainActor () throws -> Void = {
            try requireActiveLaunchAttempt(attempt, checkpoint: "during-dataset-request")
            guard !requiresStorageTransferRelaunch,
                  session?.id == sourceSession.id,
                  source.storageLaunchMode == sourceSession.mode,
                  source.storageNamespace == sourceSession.accountNamespace,
                  PersistenceDeploymentState.load() == .selected(source) else {
                throw StorageTransferError.staleTransaction
            }
        }
        try validate()
        let verified = try await AppleAccountBoundaryResolver()
            .resolve(expectedBinding: binding).binding
        try validate()
        guard verified == binding else { throw StorageTransferRecoveryError.identityMismatch }
        let status = try await runtime.remoteRecoveryStatus(binding: binding, validateAccess: validate)
        try validate()
        guard status?.blocksWriters != true else {
            // Another device is mid-replacement. The launch fence owns that
            // state and presents the recovery screen; nothing is recorded here.
            throw StorageTransferDatasetRequestError.transferInFlight
        }
        // W6. nil is a first-class answer, not a refusal: most healthy
        // single-generation accounts have no transfer control record at all,
        // and both directions have an entry point that REQUIRES its absence
        // (`startCloudLineageFromDevice` / `refreshCloudDatasetWithoutLineage`).
        // Recording nil records exactly what was observed; the executing
        // process re-reads the control record and refuses the moment a
        // committed generation exists.
        let generation = status?.datasetGenerationID
        // PLAN §3 S14, host side: never record an intent to delete contents
        // the app could not enumerate, whatever the caller believes it showed.
        // The evidence the user actually READ came from
        // `previewStorageTransferDataset`, before the acknowledgement; this
        // read is the host's own, independent enforcement and opens no
        // container. Both are read-only and bounded at 45 s.
        if direction == .overwriteCloudFromDevice {
            _ = try await runtime.previewCloudDataset(binding: binding, validateAccess: validate)
            try validate()
        }
        try runtime.recordDatasetRequest(StorageTransferDatasetRequest(
            direction: direction, binding: binding, datasetGenerationID: generation,
            requestedAt: .now, requestingProcessID: UUID()))
        requireStorageTransferRelaunch(message: datasetRequestRelaunchMessage(direction))
    }

    /// The read-only pre-flight behind the Settings 「最後の確認」.
    ///
    /// One server snapshot and one read of a disposable copy of this device's
    /// own stores. It opens no container that outlives this call, creates no
    /// journal or checkpoint, writes nothing to either side and authorizes
    /// nothing: `requestStorageTransferDataset` re-resolves the account, re-reads
    /// the control record and re-runs its own S14 read before it records
    /// anything durable. This exists so the screen can SHOW what the next tap
    /// would destroy, which is the part S14 is actually about.
    private func previewStorageTransferDataset(
        sessionID: UUID
    ) async throws -> StorageTransferDatasetPreviewSummary {
        guard let sourceSession = sessionHolder.resolve(sessionID) else {
            throw StorageTransferError.staleTransaction
        }
        guard !sourceSession.isCloudOffline else {
            throw StorageTransferRuntimeError.cloudCopyStillPending
        }
        let attempt = launchAttempt
        guard case let .selected(source) = PersistenceDeploymentState.load(),
              case let .cloud(binding) = source else {
            throw StorageTransferError.staleTransaction
        }
        let validate: @MainActor () throws -> Void = {
            try requireActiveLaunchAttempt(attempt, checkpoint: "during-dataset-preview")
            guard !requiresStorageTransferRelaunch,
                  session?.id == sourceSession.id,
                  PersistenceDeploymentState.load() == .selected(source) else {
                throw StorageTransferError.staleTransaction
            }
        }
        try validate()
        let deviceID = FocusDeviceIdentity.current()
        let runtime = try StorageTransferRuntime.live()
        let cloud = try await runtime.previewCloudDataset(
            binding: binding, localDeviceID: deviceID, validateAccess: validate)
        try validate()
        // W6. One extra single-record read, beside the snapshot that is
        // already being taken: whether the account has a transfer ledger
        // changes what the device → iCloud direction DOES (replace a lineage,
        // or start the first one), so the screen may not omit it. Read-only,
        // and it gates nothing — a missing ledger closes no door.
        let lineage = try await runtime.remoteRecoveryStatus(binding: binding,
            validateAccess: validate)?.datasetGenerationID != nil
        try validate()
        // Best effort, exactly as on the launch screen: an unreadable device
        // side degrades the comparison, it never withholds what the SERVER
        // holds. Skipped while the direction it informs is unpublished, so a
        // build that cannot run the overwrite never pays for its evidence.
        let device = StorageTransferReleasePolicy.standard.allowsDatasetOverwriteFromDevice
            ? try? StorageTransferLaunchReader.captureDevicePreview(
                selection: source, localDeviceID: deviceID)
            : nil
        try validate()
        return StorageTransferDatasetPreviewSummary(cloud: cloud, device: device,
                                                    hasCloudLineage: lineage)
    }

    private func datasetRequestRelaunchMessage(
        _ direction: StorageTransferDatasetRequestDirection
    ) -> String {
        switch direction {
        case .overwriteCloudFromDevice: StorageTransferOverwriteCopy.requestAccepted
        case .refreshFromCloud: StorageTransferRefreshCopy.requestAccepted
        }
    }

    private func unmountForStorageTransfer(sessionID: UUID) {
        guard session?.id == sessionID else { return }
        requireStorageTransferRelaunch()
    }

    private func requireStorageTransferRelaunch(message: String? = nil) {
        requiresStorageTransferRelaunch = true
        canChooseLocalOnly = false
        requestedCloudSelection = false
        remoteRecoveryAction = nil
        storageTransferRecoveryTransactionID = nil
        storageTransferRefreshGenerationID = nil
        cancellableLocalTransferID = nil
        retainsTransferCopyOnCancellation = false
        datasetPreviewRequest = nil
        cloudDatasetPreview = nil
        deviceDatasetPreview = nil
        cloudDatasetPreviewFailed = false
        lateArrivalNotice = nil
        discardDeviceDataExport()
        AccountScopedLocalState.deactivate()
        NotificationManager.shared.cancelFocusReturnReminder()
        beginContainerRetirement()
        isQuiescingAccountChange = false
        isPreparing = false
        launchState = .relaunchRequired(message ?? "保存先の切り替えを受け付けました。アプリスイッチャーでPomoGemを終了し、もう一度開いてください。元の記録を保護したまま切り替えを再開します。")
        launchAttempt += 1
    }

    private func requestRemoteRecovery(_ action: RemoteRecoveryAction) {
        guard !isPreparing, !requiresStorageTransferRelaunch,
              storageTransferRecoveryBinding != nil,
              storageTransferRecoveryTransactionID != nil else { return }
        remoteRecoveryAction = action
        launchState = .preparing("iCloudの切り替え状況を確認しています")
        launchAttempt += 1
    }

    private func requestDatasetRefresh() {
        guard !isPreparing, !requiresStorageTransferRelaunch,
              storageTransferRecoveryBinding != nil,
              let generation = storageTransferRefreshGenerationID else { return }
        datasetPreviewRequest = nil
        remoteRecoveryAction = .refresh(generation)
        launchState = .preparing("iCloudからの再取得を準備しています")
        launchAttempt += 1
    }

    /// The twin of `requestDatasetRefresh` in the opposite direction. Reached
    /// only from the 「最後の確認」 sheet's own acknowledged action, and only once
    /// the read-only pre-flight has enumerated what would be destroyed (S14).
    ///
    /// TODO(ping-pong brake): two fenced devices can overwrite each other in
    /// turn, because after a commit the losing device lands on this same screen
    /// with the same two doors (PLAN §7 window 3). A brake — refusing a new
    /// overwrite when this device's own admission was itself replaced within
    /// the last N minutes — was deliberately NOT added: it would also block a
    /// legitimate retry, and the owner has not chosen N. Until then the loop is
    /// disclosed in the copy and detected once by `evaluateReplacementWatch`,
    /// not prevented. Documented in Docs/MultiDeviceCloudSafety.md (PR 3).
    private func requestDatasetOverwrite() {
        guard !isPreparing, !requiresStorageTransferRelaunch,
              storageTransferRecoveryBinding != nil,
              cloudDatasetPreview != nil,
              let generation = storageTransferRefreshGenerationID else { return }
        datasetPreviewRequest = nil
        remoteRecoveryAction = .overwrite(generation)
        launchState = .preparing("この端末のデータでiCloudを置き換える準備をしています")
        launchAttempt += 1
    }

    /// P0-2. The device → iCloud direction for an account with NO lineage at
    /// all. Reached only from the 「最後の確認」 sheet's own acknowledged action on
    /// the `.cloudLineageUnavailable` screen; the button on that screen opens
    /// the sheet and starts nothing.
    ///
    /// There is deliberately no generation to carry: a CAS needs two lineages
    /// to compare and this account has none. `startCloudLineageFromDevice`
    /// re-reads the control record and refuses the moment one exists, so the
    /// absence is proven by the runtime at execution time rather than trusted
    /// from what this screen read.
    private func requestCloudLineageStart() {
        guard !isPreparing, !requiresStorageTransferRelaunch,
              storageTransferRecoveryBinding != nil,
              // S14, same as `requestDatasetOverwrite`. The absent control
              // record is not evidence about the account's records, and this
              // action deletes them: `.overwriteCloudFromDevice` has
              // `replacesCloud == true`, so `prepareDestination` purges the
              // managed zone, and the staged recovery copy is the SOURCE
              // payload — nothing backs up what is deleted.
              cloudDatasetPreview != nil,
              storageTransferRefreshGenerationID == nil else { return }
        datasetPreviewRequest = nil
        remoteRecoveryAction = .startLineage
        launchState = .preparing("このiPhoneのデータでiCloudを使い始める準備をしています")
        launchAttempt += 1
    }

    /// nil while the action cannot run at all, so the screen can render the
    /// door disabled for the honest reason instead of offering a control that
    /// silently does nothing.
    private var cloudLineageStartAction: (() -> Void)? {
        guard case .cloudLineageUnavailable = launchState, !isPreparing,
              !requiresStorageTransferRelaunch,
              storageTransferRecoveryBinding != nil,
              storageTransferRefreshGenerationID == nil else { return nil }
        // The view keeps the door disabled until `cloudPreview != nil` as
        // well; this closure exists so a tap can never outrun that check.
        return { requestCloudLineageStart() }
    }

    /// One read-only server snapshot plus one read of a disposable copy of this
    /// device's own stores. Opens no container that outlives this call, creates
    /// no journal or checkpoint, and writes nothing to either side. A failure
    /// is surfaced as a failure: "we could not look" and "there is nothing
    /// there" must not be confusable on a screen that offers a deletion.
    private func loadDatasetPreviews() async {
        guard let request = datasetPreviewRequest,
              let binding = storageTransferRecoveryBinding else { return }
        let deviceID = FocusDeviceIdentity.current()
        // The server side runs first: it is the side that gates the
        // destructive door, and it is the side that can be slow for a reason
        // the user can act on. The device side copies and hashes this
        // installation's stores on the main actor, so it must not sit in front
        // of the evidence the screen exists to show.
        do {
            let preview = try await StorageTransferRuntime.live().previewCloudDataset(
                binding: binding, localDeviceID: deviceID,
                validateAccess: { try requireDatasetPreviewRequest(request) })
            guard datasetPreviewRequest == request else { return }
            cloudDatasetPreview = preview
            cloudDatasetPreviewFailed = false
        } catch {
            guard datasetPreviewRequest == request else { return }
            cloudDatasetPreview = nil
            cloudDatasetPreviewFailed = true
        }
        guard datasetPreviewRequest == request else { return }
        // Skipped entirely while the direction it informs is unpublished: the
        // overwrite door is disabled by `canRequestOverwrite` anyway, and this
        // call byte-copies both stores, mounts a container and walks every row
        // of all eleven entities SYNCHRONOUSLY on the main actor — a freeze of
        // seconds on a large account, paid for a control the user cannot use.
        // TODO: move it off the main actor once `PomoGemStorageSnapshot.capture`
        // is no longer `@MainActor`. Both sides of the comparison must keep
        // being reduced by the same function, so a second, off-main reduction
        // written just for this screen is not an acceptable substitute.
        guard StorageTransferReleasePolicy.standard.allowsDatasetOverwriteFromDevice else { return }
        // Both screens that arm a destructive door show the same comparison.
        if case let .selected(selection) = PersistenceDeploymentState.load() {
            // Best effort. An unreadable device side degrades the comparison
            // to 「確認できませんでした」; it never gates the destructive door,
            // which is about what the SERVER holds.
            deviceDatasetPreview = try? StorageTransferLaunchReader.captureDevicePreview(
                selection: selection, localDeviceID: deviceID)
        }
    }

    private func requireDatasetPreviewRequest(_ request: UUID) throws {
        guard datasetPreviewRequest == request, !requiresStorageTransferRelaunch,
              !Task.isCancelled else {
            throw StorageTransferError.staleTransaction
        }
    }

    private func startDeviceDataExport() {
        guard !isExportingDeviceData, deviceDataExportURL == nil else { return }
        guard case let .selected(selection) = PersistenceDeploymentState.load() else {
            deviceDataExportError = StorageTransferLaunchReader.Failure.unavailable.localizedDescription
            return
        }
        isExportingDeviceData = true
        Task { @MainActor in
            defer { isExportingDeviceData = false }
            do {
                deviceDataExportURL = try await StorageTransferLaunchReader
                    .exportDeviceData(selection: selection)
            } catch {
                deviceDataExportError = error.localizedDescription
            }
        }
    }

    private func discardDeviceDataExport() {
        guard let url = deviceDataExportURL else { return }
        deviceDataExportURL = nil
        try? PomoGemDataExporter.removeExport(at: url)
    }

    private func requestLocalTransferCancellation(_ target: UUID) {
        guard !isPreparing, !requiresStorageTransferRelaunch,
              cancellableLocalTransferID == target else { return }
        remoteRecoveryAction = .cancelPending(target)
        launchState = .preparing("この端末の切り替えを取り消しています")
        launchAttempt += 1
    }

    private func refreshLocalTransferCancellationTarget() {
        do {
            let journal = try StorageTransferRuntime.live().pendingLocalJournal()
            cancellableLocalTransferID = journal?.permitsCancellation == true ? journal?.transactionID : nil
            retainsTransferCopyOnCancellation = journal?.retainsImportOnCancellation == true
            overwriteInProgressPhase = journal?.choice == .overwriteCloudFromDevice ? journal?.phase : nil
        } catch {
            cancellableLocalTransferID = nil
            retainsTransferCopyOnCancellation = false
            overwriteInProgressPhase = nil
        }
    }

    private func presentDatasetRefresh(error: StorageTransferRuntimeError, attempt: Int) async {
        datasetPreviewRequest = nil
        cloudDatasetPreview = nil
        deviceDatasetPreview = nil
        cloudDatasetPreviewFailed = false
        guard let binding = storageTransferRecoveryBinding else {
            launchState = .blocked(error.localizedDescription)
            return
        }
        do {
            let status = try await StorageTransferRuntime.live().remoteRecoveryStatus(
                binding: binding,
                validateAccess: {
                    try requireActiveLaunchAttempt(attempt, checkpoint: "during-dataset-refresh-status")
                }
            )
            try requireActiveLaunchAttempt(attempt, checkpoint: "after-dataset-refresh-status")
            storageTransferRefreshGenerationID = nil
            if let status, status.blocksWriters {
                storageTransferRecoveryTransactionID = status.manifest.transactionID
                launchState = .remoteRecovery(StorageTransferRuntimeError.remoteRecoveryRequired.localizedDescription,
                    canCancel: status.phase == .staging || status.phase == .backupVerified)
                return
            }
            guard let status, status.isTerminal, let generation = status.datasetGenerationID else {
                // The remedy this screen exists to offer needs a lineage to
                // refresh FROM, and there is none. Name the state instead of
                // rendering a door that cannot open: `localLedgerMissing` gets
                // its own explanation, and every other route here IS the
                // no-lineage state, which has two consented choices of its own.
                if error == .localLedgerMissing {
                    launchState = .datasetExplanation(.localLedgerMissing, error.localizedDescription)
                } else {
                    presentCloudLineageUnavailable(
                        error: .cloudLineageUnavailable)
                }
                return
            }
            storageTransferRecoveryTransactionID = nil
            storageTransferRefreshGenerationID = generation
            launchState = .datasetRefresh(error.localizedDescription,
                                          claimsReplacement: error != .localLedgerMissing)
            // Started only after the screen exists, so the pre-flight read
            // never delays the non-destructive doors and never runs inside the
            // launch attempt that must end for those doors to be live.
            datasetPreviewRequest = UUID()
        } catch {
            guard launchAttempt == attempt, !Task.isCancelled else { return }
            storageTransferRefreshGenerationID = nil
            // P1-4. The caught error is about READING iCloud, not about the
            // stop reason that sent us here; putting its text on the generic
            // screen hid the fact that the rescue UI could not be built at all.
            launchState = .blocked(StorageTransferLineageCopy.refreshScreenUnavailable)
        }
    }

    /// P0-2. The screen for `cloudLineageUnavailable` — the state the reported
    /// iPhone is actually in.
    ///
    /// review-1-1 / review-2-2. The preflight proved only that the single
    /// record `PomoGemStorageTransfer-v1/control-v1` is absent. That says
    /// nothing about `com.apple.coredata.cloudkit.zone`, which the one action
    /// on this screen deletes, so this screen arms its door exactly the way
    /// `.datasetRefresh` does: with the read-only `previewCloudDataset`
    /// enumeration, rendered on screen before any consent is possible.
    private func presentCloudLineageUnavailable(error: StorageTransferRuntimeError) {
        datasetPreviewRequest = nil
        cloudDatasetPreview = nil
        deviceDatasetPreview = nil
        cloudDatasetPreviewFailed = false
        // Both are nil for this state by construction, and clearing them is
        // what keeps `requestCloudLineageStart`'s own guard meaningful.
        storageTransferRefreshGenerationID = nil
        storageTransferRecoveryTransactionID = nil
        // review-2-5. The closing sentence names a control, so it is built
        // against the bit that decides whether this build carries one.
        launchState = .cloudLineageUnavailable(StorageTransferLineageCopy.screenMessage(
            offersLineageStart: StorageTransferReleasePolicy.standard.allowsDatasetOverwriteFromDevice))
        guard storageTransferRecoveryBinding != nil else { return }
        // Started only after the screen exists, exactly as on `.datasetRefresh`.
        datasetPreviewRequest = UUID()
    }

    private func presentRemoteStorageRecovery(error: StorageTransferRuntimeError, attempt: Int) async {
        guard let binding = storageTransferRecoveryBinding else {
            launchState = .blocked(error.localizedDescription)
            return
        }
        do {
            let status = try await StorageTransferRuntime.live().remoteRecoveryStatus(
                binding: binding,
                validateAccess: {
                    try requireActiveLaunchAttempt(attempt, checkpoint: "during-transfer-status")
                }
            )
            try requireActiveLaunchAttempt(attempt, checkpoint: "after-transfer-status")
            guard let status, status.blocksWriters else { throw StorageTransferError.staleTransaction }
            storageTransferRefreshGenerationID = nil
            storageTransferRecoveryTransactionID = status.manifest.transactionID
            let canCancel = status.phase == .staging || status.phase == .backupVerified
            launchState = .remoteRecovery(error.localizedDescription, canCancel: canCancel)
        } catch {
            guard launchAttempt == attempt, !Task.isCancelled else { return }
            storageTransferRecoveryTransactionID = nil
            launchState = .blocked(error.localizedDescription)
        }
    }

    private func retryLaunch() {
        guard !requiresStorageTransferRelaunch else { return }
        if isQuiescingAccountChange {
            guard !containerLifetimes.hasLiveContainers else {
                launchState = .blocked(
                    "以前の保存領域はまだ閉じていません。二重に開かないため停止中です。アプリを終了して再起動してください。"
                )
                return
            }
            isQuiescingAccountChange = false
            didTimeOutContainerRetirement = false
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
        guard !isPreparing, !requiresStorageTransferRelaunch else { return }
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
        guard !requiresStorageTransferRelaunch,
              let runtime = try? StorageTransferRuntime.live(),
              (try? runtime.pendingLocalJournal() == nil) == true,
              (try? runtime.pendingRemoteCancellationIntent() == nil) == true else { return false }
        return PersistenceDeploymentState.validate(
            selectionState: PersistenceDeploymentState.load(),
            mountState: PersistenceDeploymentState.loadMountState(),
            artifactHistory: PersistenceStoreTopology
                .persistenceArtifactHistory(),
            hasCloudRegistryHistory: AppleAccountBoundaryResolver
                .hasPersistedRegistryHistory(),
            hasCloudBindingHistory: AccountScopedLocalState
                .hasPersistedCloudBindingHistory(),
            hasVerifiedTransferReceipt: PersistenceDeploymentState.hasVerifiedTransferReceipt()
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
        canContinueOffline = false
        cancelOfflineConnectionCheck()
        cloudLaunchDeadline?.cancel()
        cloudLaunchDeadline = nil
        if case let .selected(.cloud(binding)) = PersistenceDeploymentState.load() {
            do { try CloudOfflineAccessState().revoke(binding: binding, reason: .accountChanged) }
            catch { offlineRevocationWriteFailed = true }
        }
        guard !requiresStorageTransferRelaunch else { return }
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
            await retireExternalTimerState(generation: quiescenceAttempt)
            let outcome = await waitForContainerRetirement(
                generation: quiescenceAttempt
            )
            guard launchAttempt == quiescenceAttempt else { return }
            switch outcome {
            case .retired:
                // The first cleanup can race view disappearance. With the
                // global gate still closed, sweep once more after the old
                // container and its view-owned writers are definitively gone.
                await retireExternalTimerState(generation: quiescenceAttempt)
                guard launchAttempt == quiescenceAttempt else { return }
                isPreparing = false
                isQuiescingAccountChange = false
                // Start identity resolution only after every known timer-side
                // effect from the previous account has been retired.
                launchAttempt += 1
            case .timedOut:
                isPreparing = false
                didTimeOutContainerRetirement = true
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
        if phase != .active {
            cancelOfflineConnectionCheck()
            cloudLaunchDeadline?.cancel()
            cloudLaunchDeadline = nil
        }
        guard !requiresStorageTransferRelaunch else {
            NotificationManager.shared.cancelFocusReturnReminder()
            return
        }
        handleFocusReturnReminderScenePhase(phase)
        let action = PersistenceLaunchScenePolicy.action(
            phase: phase,
            hasSession: session != nil,
            isPreparing: isPreparing,
            isQuiescingAccountChange: isQuiescingAccountChange,
            usesCloudAccountBoundary: usesCloudAccountBoundary,
            didTimeOutContainerRetirement: didTimeOutContainerRetirement,
            hasRetiringContainers: containerLifetimes.hasLiveContainers,
            isCloudOfflineSession: session?.isCloudOffline == true
        )
        switch action {
        case .preparePersistence:
            launchState = .preparing("保存方式を確認しています")
            launchAttempt += 1
            return
        case .resumeAfterContainerRetirement:
            // A slow callback may have released the previous store after the
            // bounded wait ended while the app was away. Reuse the explicit
            // retry path only after that release is proved; an in-progress
            // account cleanup must finish its own final sweep first.
            retryLaunch()
            return
        case .none:
            return
        case .revalidateOfflineSession:
            switch offlineSessionResumeAction() {
            case .keepOffline:
                return
            case .retryConnection:
                // The existing bounded task checks its single-flight flag and
                // preserves this same Root on connection failure.
                retryOfflineConnection()
                return
            case .retireSession:
                canContinueOffline = false
                cancelOfflineConnectionCheck()
                // Admission is no longer valid. Stop accepting late scheduling
                // work as Root disappears; recovery reopens it after admission.
                NotificationManager.shared.suspendTimerSchedulingForAccountBoundary()
            }
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
                didTimeOutContainerRetirement = true
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

    private func offlineSessionResumeAction() -> PersistenceOfflineResumeAction {
        guard let current = session, current.isCloudOffline,
              case let .selected(.cloud(binding)) = PersistenceDeploymentState.load() else {
            return .retireSession
        }
        do {
            return PersistenceLaunchScenePolicy.offlineResumeAction(
                sessionNamespace: current.accountNamespace,
                activeBinding: AccountScopedLocalState.activeBinding(),
                conditions: try offlineConditions(binding: binding),
                receipt: try CloudOfflineAccessState().load(),
                revocationWriteFailed: offlineRevocationWriteFailed,
                networkIsOffline: networkPath.isOffline)
        } catch {
            return .retireSession
        }
    }

    /// This host survives background CloudKit container retirement. Reserve the
    /// notification only at background, never for a permission sheet or
    /// Control Center's temporary inactive state.
    private func handleFocusReturnReminderScenePhase(_ phase: ScenePhase) {
        endFocusReturnReminderBackgroundTask()
        focusReturnReminderGeneration &+= 1
        let generation = focusReturnReminderGeneration
        focusReturnReminderTask?.cancel()
        focusReturnReminderTask = nil
        let manager = NotificationManager.shared
        manager.cancelFocusReturnReminder()
        guard phase == .background else { return }

        // Keep execution only for the short Notification Center add, not
        // for the 30-second grace period; the OS owns the delivery timer.
        focusReturnReminderBackgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Schedule focus return reminder"
        ) {
            // A later phase already ended the previous background task.
            guard generation == focusReturnReminderGeneration else { return }
            focusReturnReminderTask?.cancel()
            manager.cancelFocusReturnReminder()
            endFocusReturnReminderBackgroundTask()
        }
        focusReturnReminderTask = Task { @MainActor in
            defer {
                if generation == focusReturnReminderGeneration {
                    endFocusReturnReminderBackgroundTask()
                }
            }
            guard !Task.isCancelled,
                  generation == focusReturnReminderGeneration,
                  scenePhase == .background else { return }
            _ = try? await manager.scheduleRegisteredFocusReturnReminder()
        }
    }

    private func endFocusReturnReminderBackgroundTask() {
        let identifier = focusReturnReminderBackgroundTask
        focusReturnReminderBackgroundTask = .invalid
        if identifier != .invalid {
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }

    private func beginContainerRetirement() {
        didTimeOutContainerRetirement = false
        canContinueOffline = false
        // Cloud-backed RootView is absent while the account is revalidated.
        // Pause any process-local completion loop so it cannot resume on the
        // foreground edge without its Stop UI. Durable recovery restarts an
        // unacknowledged alert after the verified container remounts.
        TimerCompletionAlertController.shared.stop()
        if let container = session?.container {
            containerLifetimes.track(container)
        }
        // Invalidate admission now. The old SwiftUI graph independently owns
        // its container lifetime until Query and presented content disappear.
        // The weak tracker still blocks another mount until actual release.
        session = nil
    }

    private func retireExternalTimerState(generation: Int) async {
        // A superseded launch must not cancel timers created by the next
        // verified session while this cleanup was awaiting the system.
        guard launchAttempt == generation, !Task.isCancelled else { return }
        TimerCompletionAlertController.shared.stop()
        if let namespace = suspendedAccountBinding?.namespace {
            FocusPersistence.clearScheduledCompletionNotificationWitness(
                namespace: namespace
            )
        }
        await NotificationManager.shared.cancelAllTimerNotifications()
        guard launchAttempt == generation, !Task.isCancelled else { return }
        await NotificationManager.shared.cancelPassiveNotifications()
        guard launchAttempt == generation, !Task.isCancelled else { return }
        await NotificationManager.shared.clearDeliveredState()
        guard launchAttempt == generation, !Task.isCancelled else { return }
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
                isReleased: !containerLifetimes.hasLiveContainers,
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
        case cancelPendingTransfer

        var id: String { rawValue }
    }

    let state: PomoGemPersistenceLaunchHost.LaunchState
    let onRetry: () -> Void
    let onRetryOnline: () -> Void
    let canRetryOnline: Bool
    let onChooseCloud: () -> Void
    let onChooseLocalOnly: (() -> Void)?
    let onRecoverTransfer: () -> Void
    let onCancelTransfer: () -> Void
    let onRefreshDataset: () -> Void
    /// Opens the 「最後の確認」 sheet's confirmed request. The button on this
    /// screen never calls it: only the second screen's own acknowledgement can.
    var onOverwriteDataset: () -> Void = {}
    /// The 「このiPhoneのデータでiCloudを使い始める」 request, from the
    /// `.cloudLineageUnavailable` screen's own 「最後の確認」 sheet. nil while the
    /// action cannot run at all (no binding yet, a relaunch outstanding), so
    /// the door renders disabled for the honest reason rather than doing
    /// nothing on tap.
    var onStartCloudLineage: (() -> Void)?
    /// The non-destructive rescue door. nil while it cannot run (no selection
    /// recorded, or an export is already in flight).
    var onExportDeviceData: (() -> Void)?
    /// Re-runs the read-only pre-flight. `comparisonUnavailable` names a
    /// control, and this is it: without it a failed server read leaves the
    /// destructive door disabled for the rest of the launch with no in-app way
    /// to re-read iCloud, and the instruction on screen points at nothing.
    var onRetryCloudPreview: (() -> Void)?
    /// Read-only pre-flight evidence. `cloudPreview == nil` means the iCloud
    /// side was NOT enumerated — either the read is still running or it failed
    /// (`cloudPreviewFailed`). Nobody may authorize deleting contents the app
    /// never enumerated, so the overwrite door stays closed while it is nil.
    var cloudPreview: StorageTransferCloudPreview?
    var devicePreview: StorageTransferCloudPreview?
    var cloudPreviewFailed = false
    /// Non-nil only while a device → iCloud replacement this installation
    /// started is durably in flight; drives the phase-aware progress copy.
    var overwritePhase: StorageTransferJournal.Phase?
    /// Injected so a Debug simulator fixture can render the published screen.
    /// The app always passes `.standard`, where every bit is still false.
    var releasePolicy: StorageTransferReleasePolicy = .standard
    let onCancelLocalTransfer: (() -> Void)?
    let retainsTransferCopyOnCancellation: Bool
    let onContinueOffline: (() -> Void)?

    /// A sheet is presented in its own hosting controller and does not inherit
    /// a `dynamicTypeSize` that an ancestor set explicitly. The last screen
    /// before an irreversible deletion must be readable at the size the user
    /// actually chose, so the current size is read here and re-applied below.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var storageConfirmation: StorageConfirmation?
    @State private var confirmsTransferCancellation = false
    @State private var understandsRefreshDataLoss = false
    /// The two directions must never share a consent. This one lives on the
    /// second screen and is discarded every time that screen opens or closes.
    @State private var understandsOverwriteDataLoss = false
    @State private var presentsOverwriteConfirmation = false
    /// The lineage start has its own acknowledgement and its own sheet, on the
    /// same pattern and sharing nothing with the two above.
    @State private var understandsLineageStart = false
    @State private var presentsLineageConfirmation = false

    var body: some View {
        ZStack {
            NightBackground()
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: symbol)
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(PomoGemTheme.amber)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(PomoGemTheme.brand(24))
                        .multilineTextAlignment(.center)
                    Text(message)
                        .foregroundStyle(PomoGemTheme.muted)
                        .multilineTextAlignment(.center)
                        // review-2-5. The screen's message names a control on
                        // some states, so a test must be able to read it and
                        // check it against what this build actually publishes.
                        .accessibilityIdentifier("storage-launch-message")

                    if isPreparing {
                        ProgressView()
                            .tint(PomoGemTheme.amber)
                            .accessibilityLabel(message)
                        if let overwritePhase {
                            // Derived from the durable journal phase, never
                            // from an optimistic guess about an in-flight
                            // effect, so a relaunch shows the same sentence.
                            Text(StorageTransferOverwriteCopy.progress(overwritePhase))
                                .foregroundStyle(PomoGemTheme.muted)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("storage-overwrite-progress")
                            Text(StorageTransferOverwriteCopy.notCancellable)
                                .font(.caption)
                                .foregroundStyle(PomoGemTheme.muted)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("storage-overwrite-not-cancellable")
                        }
                    } else if isChoosingStorage {
                        storageChoiceDisclosure(
                            symbol: "icloud.fill",
                            title: "iCloudに保存して同期",
                            detail: "テーマ名、成果メモ、集中記録、設定、進行中タイマーを、Apple AccountのプライベートiCloudへ送信します。保存済みの端末データがあればオフラインでも利用できます。初回の取得や同期の再開・保存先の切り替えには通信が必要です。"
                        )
                        Button("iCloudに保存して同期") {
                            storageConfirmation = .cloud
                        }
                        .buttonStyle(PomoGemPrimaryButtonStyle())

                        storageChoiceDisclosure(
                            symbol: "iphone",
                            title: "このiPhoneだけに保存",
                            detail: "iCloudへ送信せず、このiPhoneに保存します。後で設定から保存先を切り替えられます。アプリを削除すると端末内の記録は失われます。"
                        )
                        Button("このiPhoneだけに保存") {
                            storageConfirmation = .localOnly
                        }
                        .buttonStyle(PomoGemSecondaryButtonStyle())

                        Link(destination: AppLinks.privacyPolicy) {
                            Label(
                                "プライバシーポリシー",
                                systemImage: "hand.raised"
                            )
                        }
                        .buttonStyle(PomoGemSecondaryButtonStyle())
                    } else if case .datasetRefresh = state {
                        datasetRefreshDoors
                    } else if case .cloudLineageUnavailable = state {
                        cloudLineageDoors
                    } else if case let .datasetExplanation(kind, _) = state {
                        datasetExplanation(kind)
                    } else if case let .remoteRecovery(_, canCancel) = state {
                        // Resuming a transaction this installation did not
                        // start is fenced by `allowsRemoteResumeBeforeReplacing`
                        // (`recoverRemoteTransfer` gates on exactly that bit),
                        // not by the legacy `allowsCloudReplacement`. Reading
                        // the injected policy, not `.standard`, keeps this
                        // screen and the runtime naming the same prohibition.
                        Button("復旧を続ける", action: onRecoverTransfer)
                            .buttonStyle(PomoGemPrimaryButtonStyle())
                            .disabled(!releasePolicy.allowsRemoteResumeBeforeReplacing)
                            .accessibilityIdentifier("storage-transfer-recover")
                        if !releasePolicy.allowsRemoteResumeBeforeReplacing {
                            Text(StorageTransferReleaseError.remoteReplacementResumeUnavailable.localizedDescription)
                                .foregroundStyle(PomoGemTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("storage-transfer-recover-unavailable")
                        }
                        if canCancel, onCancelLocalTransfer == nil {
                            Button("切り替えを取り消す") { confirmsTransferCancellation = true }
                                .buttonStyle(PomoGemSecondaryButtonStyle())
                                .accessibilityIdentifier("storage-transfer-cancel")
                        }
                    } else if case .cloudVerificationTimedOut = state {
                        Button("オンラインで再試行", action: onRetryOnline)
                            .buttonStyle(PomoGemPrimaryButtonStyle())
                            .disabled(!canRetryOnline)
                            .accessibilityIdentifier("cloud-offline-online-retry")
                        Text("端末の記録は保持しています。この画面からオンラインで確認し直せます。オフラインで端末のデータを使う場合は、アプリを終了して開き直してください。アプリ自体は削除しないでください。")
                            .foregroundStyle(PomoGemTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("cloud-launch-timeout-offline-explanation")
                    } else if case .offlineRelaunchRequired = state {
                        Text("オフラインで開くにはアプリの再起動が必要です。通信が戻った場合は、この画面からオンラインで確認し直せます。")
                            .foregroundStyle(PomoGemTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("オンラインで再試行", action: onRetryOnline)
                            .buttonStyle(PomoGemPrimaryButtonStyle())
                            .disabled(!canRetryOnline)
                            .accessibilityIdentifier("cloud-offline-online-retry")
                    } else if case .relaunchRequired = state {
                        Text("この画面から再試行せず、アプリを終了して開き直してください。")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("storage-transfer-relaunch-required")
                    } else {
                        if case .blocked = state {
                            // `.blocked` means no terminal control record with a
                            // generation id was readable, so a replacement would
                            // have no lineage to act against. This screen
                            // therefore explains what the next attempt offers
                            // and carries NO destructive affordance of its own.
                            Text(StorageTransferOverwriteCopy.blockedExplanation(
                                offersOverwrite: releasePolicy.allowsDatasetOverwriteFromDevice))
                                .font(.caption)
                                .foregroundStyle(PomoGemTheme.muted)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("storage-refresh-blocked-explanation")
                        }
                        Button("もう一度試す", action: onRetry)
                            .buttonStyle(PomoGemPrimaryButtonStyle())
                        if let onContinueOffline {
                            Button("端末のデータでオフライン利用", action: onContinueOffline)
                                .buttonStyle(PomoGemSecondaryButtonStyle())
                                .accessibilityIdentifier("cloud-offline-continue")
                        }
                        if onChooseLocalOnly != nil {
                            Button("このiPhoneだけで始める") {
                                storageConfirmation = .localOnly
                            }
                            .buttonStyle(PomoGemSecondaryButtonStyle())
                        }
                        Link(destination: AppLinks.support) {
                            Label("サポートを見る", systemImage: "questionmark.circle")
                        }
                        .buttonStyle(PomoGemSecondaryButtonStyle())
                    }
                    if onCancelLocalTransfer != nil, showsLocalTransferCancellation {
                        Text(localTransferCancellationExplanation)
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                        Button("この端末の切り替えを取り消す") {
                            storageConfirmation = .cancelPendingTransfer
                        }
                        .buttonStyle(PomoGemSecondaryButtonStyle())
                        .accessibilityIdentifier("storage-transfer-cancel-local")
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
                    message: Text("テーマ名、成果メモ、集中記録、設定、進行中タイマーをApple AccountのプライベートiCloudへ送信します。オンラインでApple Accountを確認した後に保存方式を確定します。後で同期を止めるときは、iCloudの記録をこのiPhoneへコピーし、iCloudの記録も残します。"),
                    primaryButton: .cancel(Text("キャンセル")),
                    secondaryButton: .default(Text("確認して続ける")) {
                        onChooseCloud()
                    }
                )
            case .localOnly:
                Alert(
                    title: Text("このiPhoneだけに保存しますか？"),
                    message: Text("記録をiCloudへ送信せず、このiPhoneに保存します。アプリを削除すると端末内の記録は失われます。後で設定からiCloudの記録を取り込み、端末の記録を置き換えて同期を始められます。端末の記録でiCloudを置き換える操作は現在利用できず、二つの記録も統合されません。"),
                    primaryButton: .cancel(Text("キャンセル")),
                    secondaryButton: .default(Text("このiPhoneだけで始める")) {
                        onChooseLocalOnly?()
                    }
                )
            case .cancelPendingTransfer:
                Alert(
                    title: Text("この端末の切り替えを取り消しますか？"),
                    message: Text(localTransferCancellationExplanation),
                    primaryButton: .cancel(Text("戻る")),
                    secondaryButton: .destructive(Text("切り替えを取り消す")) {
                        onCancelLocalTransfer?()
                    }
                )
            }
        }
        .confirmationDialog("保存先の切り替えを取り消しますか？", isPresented: $confirmsTransferCancellation,
                            titleVisibility: .visible) {
            Button("切り替えを取り消す", role: .destructive, action: onCancelTransfer)
            Button("続けて確認する", role: .cancel) { }
        } message: {
            Text("元のiCloudの記録を残して、この切り替えを取り消します。データの置き換えが始まっている場合は取り消せません。")
        }
        .sheet(isPresented: $presentsOverwriteConfirmation) {
            overwriteConfirmationSheet
        }
        .sheet(isPresented: $presentsLineageConfirmation) {
            lineageConfirmationSheet
        }
        .onChange(of: state) { _, _ in
            understandsRefreshDataLoss = false
            understandsOverwriteDataLoss = false
            understandsLineageStart = false
            presentsOverwriteConfirmation = false
            presentsLineageConfirmation = false
            confirmsTransferCancellation = false
        }
    }

    /// The `.datasetRefresh` screen a device that was fenced out of the current
    /// iCloud generation lands on. It offers both directions, each with its own
    /// unchecked acknowledgement on its own `@State`, plus the non-destructive
    /// rescue door in between. Reading either explanation is never consent, and
    /// consenting to one direction never arms the other.
    @ViewBuilder
    private var datasetRefreshDoors: some View {
        doorHeader("iCloudのデータを使う")
        // One text, quoted by both surfaces that offer this direction.
        Text(StorageTransferRefreshCopy.dataLossWarning)
            .foregroundStyle(PomoGemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("storage-refresh-data-loss-warning")
        Toggle("端末データの削除を確認しました", isOn: $understandsRefreshDataLoss)
            .accessibilityIdentifier("storage-refresh-confirm-data-loss")
        Button("iCloudから再取得", role: .destructive, action: onRefreshDataset)
            .buttonStyle(PomoGemPrimaryButtonStyle())
            .disabled(!understandsRefreshDataLoss)
            .accessibilityIdentifier("storage-refresh-confirm")

        doorHeader("このiPhoneのデータを使う")
        Text(overwriteComparison)
            .foregroundStyle(PomoGemTheme.muted)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("storage-overwrite-comparison")
        if cloudPreviewFailed, let onRetryCloudPreview {
            // Non-destructive: it re-arms the read-only pre-flight and nothing
            // else. `.datasetRefresh` carries no 「もう一度試す」, so this is the
            // control the failure sentence above names.
            Button(StorageTransferOverwriteCopy.retryPreviewTitle, action: onRetryCloudPreview)
                .buttonStyle(PomoGemSecondaryButtonStyle())
                .accessibilityIdentifier("storage-overwrite-retry-preview")
        }
        Text(overwriteOtherDeviceEvidence)
            .font(.caption)
            .foregroundStyle(PomoGemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("storage-overwrite-other-devices")
        Text(StorageTransferOverwriteCopy.dataLossWarning)
            .foregroundStyle(PomoGemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("storage-overwrite-data-loss-warning")
        if let onExportDeviceData {
            Button(StorageTransferOverwriteCopy.exportTitle, action: onExportDeviceData)
                .buttonStyle(PomoGemSecondaryButtonStyle())
                .accessibilityIdentifier("storage-refresh-export")
            Text(StorageTransferOverwriteCopy.exportNote)
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("storage-refresh-export-note")
        }
        Button(StorageTransferOverwriteCopy.confirmTitle, role: .destructive) {
            // Never acts on tap. It opens the second screen, whose own
            // acknowledgement starts unchecked on every presentation.
            understandsOverwriteDataLoss = false
            presentsOverwriteConfirmation = true
        }
        .buttonStyle(PomoGemPrimaryButtonStyle())
        .disabled(!canRequestOverwrite)
        .accessibilityIdentifier("storage-overwrite-confirm")
        if !releasePolicy.allowsDatasetOverwriteFromDevice {
            Text(StorageTransferReleaseError.datasetOverwriteUnavailable.localizedDescription)
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("storage-overwrite-unavailable")
        }
    }

    /// P0-2. The `.cloudLineageUnavailable` screen: the server has no transfer
    /// ledger, so 「iCloudから再取得」 has nothing to refresh FROM and is not
    /// offered here at all. Exactly two choices, each with its own consent
    /// step, and both described as non-destructive to this device's records.
    @ViewBuilder
    private var cloudLineageDoors: some View {
        doorHeader(StorageTransferLineageCopy.startDoorTitle)
        Text(StorageTransferLineageCopy.startExplanation)
            .foregroundStyle(PomoGemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("storage-lineage-start-explanation")
        // review-1-1 / review-2-2. The counted iCloud side, before any consent
        // is possible. 「no control record」 is not 「no records」, and this door
        // deletes the records.
        Text(lineageComparison)
            .foregroundStyle(PomoGemTheme.muted)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("storage-lineage-comparison")
        if cloudPreviewFailed, let onRetryCloudPreview {
            Button(StorageTransferOverwriteCopy.retryPreviewTitle, action: onRetryCloudPreview)
                .buttonStyle(PomoGemSecondaryButtonStyle())
                .accessibilityIdentifier("storage-lineage-retry-preview")
        }
        Text(overwriteOtherDeviceEvidence)
            .font(.caption)
            .foregroundStyle(PomoGemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("storage-lineage-other-devices")
        Button(StorageTransferLineageCopy.startDoorTitle, role: .destructive) {
            // Never acts on tap. It opens the second screen, whose own
            // acknowledgement starts unchecked on every presentation.
            understandsLineageStart = false
            presentsLineageConfirmation = true
        }
        .buttonStyle(PomoGemPrimaryButtonStyle())
        .disabled(!canStartCloudLineage)
        .accessibilityIdentifier("storage-lineage-start")
        if !releasePolicy.allowsDatasetOverwriteFromDevice {
            // review-2-7. Phrased for THIS door: the overwrite error describes
            // a 「置き換え」 and a 復旧用コピー, neither of which this screen
            // is about.
            Text(StorageTransferLineageCopy.startUnavailable)
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("storage-lineage-start-unavailable")
        }

        doorHeader(StorageTransferLineageCopy.offlineDoorTitle)
        Text(onContinueOffline == nil
             ? StorageTransferLineageCopy.offlineUnavailable
             : StorageTransferLineageCopy.offlineExplanation)
            .foregroundStyle(PomoGemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("storage-lineage-offline-explanation")
        if let onContinueOffline {
            // The EXISTING offline continuation, with no second implementation:
            // the same action and the same identifier the other screens use.
            Button("端末のデータでオフライン利用", action: onContinueOffline)
                .buttonStyle(PomoGemSecondaryButtonStyle())
                .accessibilityIdentifier("cloud-offline-continue")
        }
        // review-1-3 / review-2-1. Before this branch existed the same stop
        // reason fell through to `.blocked`, which always carries 「もう一度試す」.
        // Without it a shipping build whose offline copy is ineligible — the
        // `.enrol` + `requireNoArtifacts` path that raises this very error —
        // renders a disabled door and a support link and nothing else, and the
        // only way to re-attempt is to force-quit the app.
        Button("もう一度試す", action: onRetry)
            .buttonStyle(PomoGemSecondaryButtonStyle())
            .accessibilityIdentifier("storage-lineage-retry")
        if onChooseLocalOnly != nil {
            Button("このiPhoneだけで始める") {
                storageConfirmation = .localOnly
            }
            .buttonStyle(PomoGemSecondaryButtonStyle())
        }
        Link(destination: AppLinks.support) {
            Label("サポートを見る", systemImage: "questionmark.circle")
        }
        .buttonStyle(PomoGemSecondaryButtonStyle())
    }

    /// The iCloud side of this screen, rendered by the same functions as the
    /// `.datasetRefresh` comparison so the two surfaces cannot disagree about
    /// one dataset. The iCloud row never prints a 「最終」 date here: there is
    /// no control record, so a lineage row would imply one that does not exist.
    private var lineageComparison: String {
        if cloudPreviewFailed { return StorageTransferOverwriteCopy.comparisonUnavailable }
        guard let cloudPreview else { return StorageTransferOverwriteCopy.comparisonReading }
        let cloud = StorageTransferOverwriteCopy.cloudSideWithoutLineage(preview: cloudPreview)
        guard releasePolicy.allowsDatasetOverwriteFromDevice else { return cloud }
        return StorageTransferOverwriteCopy.side("このiPhone", preview: devicePreview) + "\n" + cloud
    }

    /// The explanation-only screens. No destructive control of any kind: the
    /// offline route when it is eligible, the generic retry, and support.
    @ViewBuilder
    private func datasetExplanation(_ kind: PomoGemPersistenceLaunchHost.DatasetExplanation) -> some View {
        Text(kind == .environmentMismatch
             ? StorageTransferLineageCopy.environmentMismatchExplanation
             : StorageTransferLineageCopy.localLedgerMissingExplanation)
            .foregroundStyle(PomoGemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("storage-dataset-explanation")
        Button("もう一度試す", action: onRetry)
            .buttonStyle(PomoGemPrimaryButtonStyle())
        if let onContinueOffline {
            Button("端末のデータでオフライン利用", action: onContinueOffline)
                .buttonStyle(PomoGemSecondaryButtonStyle())
                .accessibilityIdentifier("cloud-offline-continue")
        }
        Link(destination: AppLinks.support) {
            Label("サポートを見る", systemImage: "questionmark.circle")
        }
        .buttonStyle(PomoGemSecondaryButtonStyle())
    }

    /// 「最後の確認」 for starting a lineage from this device. Same pattern as
    /// the overwrite sheet: everything the action will do, restated in full,
    /// its own unchecked toggle, its own destructive action, and a 「戻る」 that
    /// starts nothing and discards the acknowledgement.
    private var lineageConfirmationSheet: some View {
        NavigationStack {
            ZStack {
                NightBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        overwriteSheetParagraph(StorageTransferLineageCopy.sheetWarning,
                            identifier: "storage-lineage-warning")
                        // The same two facts the overwrite sheet restates: what
                        // is on each side, and whether another device wrote it.
                        overwriteSheetParagraph(lineageComparison,
                            identifier: "storage-lineage-sheet-comparison")
                        overwriteSheetParagraph(overwriteOtherDeviceEvidence,
                            identifier: "storage-lineage-sheet-other-devices")
                        overwriteSheetParagraph(StorageTransferLineageCopy.sheetOtherBuilds,
                            identifier: "storage-lineage-other-builds")
                        overwriteSheetParagraph(StorageTransferLineageCopy.sheetRelaunch,
                            identifier: "storage-lineage-relaunch")
                        overwriteSheetParagraph(StorageTransferLineageCopy.sheetScreenTime,
                            identifier: "storage-lineage-screen-time")
                        Toggle(StorageTransferLineageCopy.acknowledgement,
                               isOn: $understandsLineageStart)
                            .accessibilityIdentifier("storage-lineage-confirm-data-loss")
                        Button(StorageTransferLineageCopy.sheetConfirm, role: .destructive) {
                            presentsLineageConfirmation = false
                            onStartCloudLineage?()
                        }
                        .buttonStyle(PomoGemPrimaryButtonStyle())
                        .disabled(!understandsLineageStart)
                        .accessibilityIdentifier("storage-lineage-sheet-confirm")
                    }
                    .frame(maxWidth: 520)
                    .padding(24)
                }
            }
            .dynamicTypeSize(dynamicTypeSize)
            .navigationTitle(StorageTransferLineageCopy.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("戻る") {
                        understandsLineageStart = false
                        presentsLineageConfirmation = false
                    }
                }
            }
        }
    }

    /// S14, identically to `canRequestOverwrite`. The door is closed while the
    /// feature is unpublished, while the host cannot run it, AND until the
    /// iCloud side has actually been enumerated.
    ///
    /// review-1-1 / review-2-2. The old comment justified skipping the
    /// pre-flight with 「there is no iCloud dataset to enumerate, which is the
    /// whole premise」. The premise was wrong: `cloudLineageUnavailable` means
    /// only that `PomoGemStorageTransfer-v1/control-v1` is absent. The records
    /// under `com.apple.coredata.cloudkit.zone` can be a whole other device's
    /// dataset, and this door deletes them with no recovery copy.
    private var canStartCloudLineage: Bool {
        releasePolicy.allowsDatasetOverwriteFromDevice && onStartCloudLineage != nil
            && cloudPreview != nil
    }

    /// 「最後の確認」. Everything the replacement will do, restated in full, with
    /// its own unchecked toggle and its own destructive action. 「戻る」 starts
    /// nothing and discards the acknowledgement.
    private var overwriteConfirmationSheet: some View {
        NavigationStack {
            ZStack {
                NightBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        overwriteSheetParagraph(StorageTransferOverwriteCopy.sheetWarning,
                            identifier: "storage-overwrite-warning")
                        overwriteSheetParagraph(overwriteOtherDeviceEvidence,
                            identifier: "storage-overwrite-sheet-other-devices")
                        overwriteSheetParagraph(StorageTransferOverwriteCopy.recoveryCopy,
                            identifier: "storage-overwrite-recovery-copy")
                        overwriteSheetParagraph(StorageTransferOverwriteCopy.relaunch,
                            identifier: "storage-overwrite-relaunch")
                        overwriteSheetParagraph(StorageTransferOverwriteCopy.notCancellable,
                            identifier: "storage-overwrite-not-cancellable")
                        overwriteSheetParagraph(StorageTransferOverwriteCopy.screenTime,
                            identifier: "storage-overwrite-screen-time")
                        Toggle(StorageTransferOverwriteCopy.acknowledgement,
                               isOn: $understandsOverwriteDataLoss)
                            .accessibilityIdentifier("storage-overwrite-confirm-data-loss")
                        Button(StorageTransferOverwriteCopy.sheetConfirm, role: .destructive) {
                            presentsOverwriteConfirmation = false
                            onOverwriteDataset()
                        }
                        .buttonStyle(PomoGemPrimaryButtonStyle())
                        .disabled(!understandsOverwriteDataLoss)
                        .accessibilityIdentifier("storage-overwrite-sheet-confirm")
                    }
                    .frame(maxWidth: 520)
                    .padding(24)
                }
            }
            .dynamicTypeSize(dynamicTypeSize)
            .navigationTitle(StorageTransferOverwriteCopy.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("戻る") {
                        understandsOverwriteDataLoss = false
                        presentsOverwriteConfirmation = false
                    }
                }
            }
        }
    }

    private func overwriteSheetParagraph(_ text: String, identifier: String) -> some View {
        Text(text)
            .foregroundStyle(PomoGemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }

    private func doorHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    /// S14. The destructive door is closed until the iCloud side has actually
    /// been enumerated, and while the feature is unpublished. The device side
    /// only degrades the comparison: failing to read this iPhone is not a
    /// reason to refuse to describe what would be destroyed on the server.
    private var canRequestOverwrite: Bool {
        releasePolicy.allowsDatasetOverwriteFromDevice && cloudPreview != nil
    }

    private var overwriteComparison: String {
        if cloudPreviewFailed { return StorageTransferOverwriteCopy.comparisonUnavailable }
        guard cloudPreview != nil else { return StorageTransferOverwriteCopy.comparisonReading }
        // While the device -> iCloud direction is unpublished the host does not
        // read this iPhone's stores at all, so the device row is omitted rather
        // than reported as 「確認できませんでした」 — that sentence claims a look
        // that never happened, on the one screen that must not invent evidence.
        guard releasePolicy.allowsDatasetOverwriteFromDevice else {
            return StorageTransferOverwriteCopy.side("iCloud", preview: cloudPreview)
        }
        return StorageTransferOverwriteCopy.side("このiPhone", preview: devicePreview)
            + "\n" + StorageTransferOverwriteCopy.side("iCloud", preview: cloudPreview)
    }

    private var overwriteOtherDeviceEvidence: String {
        guard let cloudPreview else { return StorageTransferOverwriteCopy.otherDevicesUnknown }
        return StorageTransferOverwriteCopy.otherDevices(cloudPreview.otherDeviceIDs)
    }

    private var localTransferCancellationExplanation: String {
        if retainsTransferCopyOnCancellation {
            return "元の保存先とiCloudの記録を残して、取り込みを取り消せます。途中までのコピーも保護のため端末に保持します。取り消した後はアプリを終了して開き直し、改めて切り替えを開始してください。"
        }
        return "置き換えが始まる前なので、この端末の切り替えを取り消して元の保存先へ戻れます。取り消した後はアプリを終了して開き直してください。"
    }

    private func storageChoiceDisclosure(
        symbol: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(PomoGemTheme.amber)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private var isPreparing: Bool {
        if case .preparing = state { return true }
        return false
    }

    private var isChoosingStorage: Bool {
        state == .choosingStorage
    }

    private var showsLocalTransferCancellation: Bool {
        switch state {
        case .blocked, .failed, .remoteRecovery: true
        case .choosingStorage, .preparing, .relaunchRequired, .offlineRelaunchRequired,
             .cloudVerificationTimedOut, .datasetRefresh,
             .cloudLineageUnavailable, .datasetExplanation: false
        }
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
        case .relaunchRequired:
            "アプリを開き直してください"
        case .offlineRelaunchRequired:
            "オフラインで開くには再起動が必要です"
        case .cloudVerificationTimedOut:
            "iCloudの確認に時間がかかっています"
        case .remoteRecovery:
            "保存先の切り替えを復旧します"
        case let .datasetRefresh(_, claimsReplacement):
            // Only the state that actually observed two different committed
            // generations may say the dataset was replaced. A missing LOCAL
            // ledger is the device's gap, not evidence about the server.
            claimsReplacement
                ? "iCloudのデータが置き換わりました"
                : StorageTransferLineageCopy.localLedgerMissingTitle
        case .cloudLineageUnavailable:
            StorageTransferLineageCopy.title
        case let .datasetExplanation(kind, _):
            kind == .environmentMismatch
                ? StorageTransferLineageCopy.environmentMismatchTitle
                : StorageTransferLineageCopy.localLedgerMissingTitle
        }
    }

    private var message: String {
        switch state {
        case .choosingStorage:
            "有効にすると、同じApple AccountのiPhone間で記録を同期します。利用しない場合は、このiPhoneだけに保存でき、記録はiCloudへ送信されません。"
        case let .preparing(message), let .blocked(message), let .failed(message),
             let .relaunchRequired(message), let .offlineRelaunchRequired(message),
             let .cloudVerificationTimedOut(message),
             let .remoteRecovery(message, _), let .datasetRefresh(message, _),
             let .cloudLineageUnavailable(message), let .datasetExplanation(_, message):
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
        case .relaunchRequired, .offlineRelaunchRequired, .cloudVerificationTimedOut:
            "arrow.clockwise"
        case .remoteRecovery:
            "icloud.and.arrow.down"
        case .datasetRefresh:
            "arrow.triangle.2.circlepath.icloud"
        case .cloudLineageUnavailable:
            "icloud.slash"
        case .datasetExplanation:
            "externaldrive.badge.questionmark"
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Renders the actual launch-status view without an account, store, or mount.
/// Selected only by the existing explicit in-memory settings UI fixture.
struct CloudLaunchTimeoutUITestFixtureView: View {
    @State private var retryCalls = 0

    var body: some View {
        PersistenceLaunchStatusView(
            state: retryCalls == 0
                ? .cloudVerificationTimedOut(CloudLaunchDeadlineError.expired.localizedDescription)
                : .preparing("オンラインで保存領域を再確認しています"),
            onRetry: {}, onRetryOnline: {
                guard retryCalls == 0 else { return }
                retryCalls += 1
            },
            canRetryOnline: true,
            onChooseCloud: {}, onChooseLocalOnly: nil,
            onRecoverTransfer: {}, onCancelTransfer: {}, onRefreshDataset: {},
            onCancelLocalTransfer: nil, retainsTransferCopyOnCancellation: false,
            onContinueOffline: nil)
            .safeAreaInset(edge: .bottom) {
                VStack {
                    Text(verbatim: "calls=0;choice=none;starting=false")
                        .accessibilityIdentifier("storage-switch.fixture-state")
                    Text(verbatim: "retryCalls=\(retryCalls)")
                        .accessibilityIdentifier("cloud-launch-timeout.fixture-state")
                }
                .font(.caption)
            }
    }
}
#endif

#if DEBUG && targetEnvironment(simulator)
/// The five launch-host screens a device that was fenced out of the current
/// iCloud generation can land on, rendered from the shipping
/// `PersistenceLaunchStatusView` with a call recorder in place of the transfer
/// runtime. No journal, checkpoint, container, account or CloudKit call exists
/// in the process, so a passing run is also evidence that reading these
/// screens starts nothing.
enum StorageTransferOverwriteLaunchUITestScenario {
    /// The shipping build: the pre-flight succeeded and found no other writer,
    /// and the device -> iCloud door is present, described and DISABLED because
    /// `StorageTransferReleasePolicy.standard` still publishes nothing.
    case choice
    /// The published screen with two witnessed other devices.
    case otherDevices
    /// The published screen whose server read failed: nobody may authorize
    /// deleting contents the app never enumerated, so the door stays closed.
    case previewFailed
    /// No terminal control record was readable. Explanation, no destructive
    /// affordance of any kind.
    case blocked
    /// A durable device -> iCloud replacement past the point of no return.
    case inProgress
    /// Another installation's transaction is parked before the destructive
    /// phase and this device is offered as its executor. Shipping build: the
    /// resume bit is closed, so the door is refused with its own reason.
    case remoteResumeClosed
    /// The same screen with `allowsRemoteResumeBeforeReplacing` raised, and
    /// ONLY that bit — the door this gate governs is the one that closes
    /// Docs/MultiDeviceCloudSafety.md defect 2.
    case remoteResumeOpen
    /// P0-2, the shipping build. The server has no transfer ledger at all, so
    /// the screen offers starting a lineage from this device or staying
    /// offline — and the first of those is DISABLED with its reason, because
    /// `allowsDatasetOverwriteFromDevice` is still false.
    case lineageUnavailable
    /// The same screen with that one bit raised, so the consent flow behind
    /// the door can actually be exercised. The offline route is deliberately
    /// ineligible here, so the 「otherwise explain」 branch is covered too.
    case lineageUnavailableEnabled
    /// review-1-3 / review-2-1. The shipping build on a device whose offline
    /// copy is ALSO ineligible — the combination neither fixture covered, and
    /// the one that used to render a disabled door and a support link with no
    /// way out of the screen at all.
    case lineageUnavailableClosed
    /// review-1-1 / review-2-2. The published door whose read-only server
    /// enumeration failed. Nobody may authorize deleting contents the app
    /// never enumerated, so the door stays shut and the named re-read appears.
    case lineageUnavailableUnreadable
    /// Explanation only: this device's receipt was earned in the other
    /// CloudKit environment. Nothing destructive is on this screen.
    case environmentMismatch
    /// Explanation only: the local ledger is missing AND the server turned out
    /// to have no committed generation either, so 「iCloudから再取得」 cannot be
    /// built. The offline route is ineligible in this fixture.
    case localLedgerMissingExplain

    /// The four screens this step adds are the only ones whose tests read the
    /// lineage counters, and an extra line in the fixture's bottom inset costs
    /// scrollable height that the AX5 `.datasetRefresh` tests depend on.
    var showsLineageState: Bool {
        switch self {
        case .lineageUnavailable, .lineageUnavailableEnabled, .lineageUnavailableClosed,
             .lineageUnavailableUnreadable, .environmentMismatch,
             .localLedgerMissingExplain: true
        case .choice, .otherDevices, .previewFailed, .blocked, .inProgress,
             .remoteResumeClosed, .remoteResumeOpen: false
        }
    }
}

struct StorageTransferOverwriteLaunchUITestFixtureView: View {
    let scenario: StorageTransferOverwriteLaunchUITestScenario
    @State private var refreshCalls = 0
    @State private var overwriteCalls = 0
    @State private var exportCalls = 0
    /// The `.previewFailed` scenario re-reads on demand, exactly as the host
    /// does, so a test can prove the named control re-arms the closed door
    /// instead of only proving the door is closed.
    @State private var previewRetries = 0
    @State private var recoverCalls = 0
    /// P0-2. The two choices on the `.cloudLineageUnavailable` screen, counted
    /// separately from the two on `.datasetRefresh`: a test that proves one of
    /// them did not fire must not be satisfied by the other's counter.
    @State private var lineageCalls = 0
    @State private var offlineCalls = 0

    var body: some View {
        PersistenceLaunchStatusView(
            state: state,
            onRetry: {}, onRetryOnline: {}, canRetryOnline: true,
            onChooseCloud: {}, onChooseLocalOnly: nil,
            onRecoverTransfer: { recoverCalls += 1 }, onCancelTransfer: {},
            onRefreshDataset: { refreshCalls += 1 },
            onOverwriteDataset: { overwriteCalls += 1 },
            onStartCloudLineage: offersLineageStart ? { lineageCalls += 1 } : nil,
            onExportDeviceData: offersExport ? { exportCalls += 1 } : nil,
            onRetryCloudPreview: offersPreviewRetry ? { previewRetries += 1 } : nil,
            cloudPreview: cloudPreview,
            devicePreview: devicePreview,
            cloudPreviewFailed: cloudPreviewFailed,
            overwritePhase: scenario == .inProgress ? .preparingDestination : nil,
            releasePolicy: releasePolicy,
            onCancelLocalTransfer: nil, retainsTransferCopyOnCancellation: false,
            onContinueOffline: offersOffline ? { offlineCalls += 1 } : nil)
            .safeAreaInset(edge: .bottom) {
                VStack {
                    Text(verbatim: "calls=0;choice=none;starting=false")
                        .accessibilityIdentifier("storage-switch.fixture-state")
                    Text(verbatim: "refresh=\(refreshCalls);overwrite=\(overwriteCalls);export=\(exportCalls);previewRetries=\(previewRetries);recover=\(recoverCalls)")
                        .accessibilityIdentifier("storage-overwrite.fixture-state")
                    // Only on the screens whose tests read it. An extra line
                    // in this inset costs real scrollable height at AX5, and
                    // the `.datasetRefresh` tests must keep the layout they
                    // were written against.
                    if scenario.showsLineageState {
                        Text(verbatim: "lineage=\(lineageCalls);offline=\(offlineCalls)")
                            .accessibilityIdentifier("storage-lineage.fixture-state")
                    }
                    // PLAN Step 6 asks for the RAW and the FILTERED witness
                    // count, so a reviewer can see that the ignore list moved a
                    // writer rather than that a writer was absent.
                    Text(verbatim: "others=\(cloudPreview?.otherDeviceIDs ?? -1);ignored=\(cloudPreview?.ignoredWriterIDs ?? -1)")
                        .accessibilityIdentifier("storage-overwrite.writer-fixture-state")
                }
                .font(.caption)
            }
    }

    /// A failed read is offered a re-read; a successful or absent one is not.
    private var offersPreviewRetry: Bool {
        scenario == .previewFailed || scenario == .lineageUnavailableUnreadable
    }

    /// The host passes nil when the action cannot run at all. Only the lineage
    /// screen ever has it, and nothing else in this fixture may receive it.
    private var offersLineageStart: Bool {
        switch scenario {
        case .lineageUnavailable, .lineageUnavailableEnabled, .lineageUnavailableClosed,
             .lineageUnavailableUnreadable: true
        default: false
        }
    }

    /// Eligibility for the offline continuation is a property of the device's
    /// verified local copy, not of the stop reason, so both shapes appear.
    private var offersOffline: Bool {
        scenario == .lineageUnavailable || scenario == .environmentMismatch
    }

    /// review-1-3 / review-2-1. The screen must never be a dead end, so one
    /// scenario deliberately combines the shipping policy with an ineligible
    /// offline route: `lineageUnavailableClosed` offers neither door.

    private var cloudPreviewFailed: Bool {
        (scenario == .previewFailed || scenario == .lineageUnavailableUnreadable)
            && previewRetries == 0
    }

    private var state: PomoGemPersistenceLaunchHost.LaunchState {
        switch scenario {
        case .blocked:
            .blocked(StorageTransferRuntimeError.remoteRecoveryRequired.localizedDescription)
        case .inProgress:
            .preparing("中断された保存先の切り替えを再開しています")
        case .remoteResumeClosed, .remoteResumeOpen:
            .remoteRecovery(StorageTransferRuntimeError.remoteRecoveryRequired.localizedDescription,
                            canCancel: true)
        case .choice, .otherDevices, .previewFailed:
            .datasetRefresh(StorageTransferRuntimeError.datasetRefreshRequired.localizedDescription,
                            claimsReplacement: true)
        case .lineageUnavailable, .lineageUnavailableEnabled, .lineageUnavailableClosed,
             .lineageUnavailableUnreadable:
            // review-2-5. Built by the same function the host uses, from the
            // same bit, so a fixture cannot show a promise the policy denies.
            .cloudLineageUnavailable(StorageTransferLineageCopy.screenMessage(
                offersLineageStart: releasePolicy.allowsDatasetOverwriteFromDevice))
        case .environmentMismatch:
            .datasetExplanation(.environmentMismatch,
                StorageTransferRuntimeError.cloudEnvironmentMismatch.localizedDescription)
        case .localLedgerMissingExplain:
            .datasetExplanation(.localLedgerMissing,
                StorageTransferRuntimeError.localLedgerMissing.localizedDescription)
        }
    }

    private var offersExport: Bool {
        scenario == .choice || scenario == .otherDevices || scenario == .previewFailed
    }

    /// Only the two published scenarios raise the overwrite bit, and they raise
    /// exactly that one: the legacy `localOnly -> cloud` replacement and the
    /// remote resume stay closed, so a fixture can never widen the shipping
    /// prohibition it is meant to exercise around.
    private var releasePolicy: StorageTransferReleasePolicy {
        switch scenario {
        case .otherDevices, .previewFailed, .lineageUnavailableEnabled,
             .lineageUnavailableUnreadable:
            .isolatedTestingPolicy(allowsDatasetOverwriteFromDevice: true)
        case .remoteResumeOpen:
            .isolatedTestingPolicy(allowsRemoteResumeBeforeReplacing: true)
        case .choice, .blocked, .inProgress, .remoteResumeClosed, .lineageUnavailable,
             .lineageUnavailableClosed, .environmentMismatch, .localLedgerMissingExplain:
            .standard
        }
    }

    private var cloudPreview: StorageTransferCloudPreview? {
        switch scenario {
        case .choice:
            Self.preview(subjects: 9, sessions: 312, stones: 28,
                         latest: Self.date(2026, 9, 18), otherDeviceIDs: 0, ignoredWriterIDs: 1)
        case .otherDevices:
            Self.preview(subjects: 9, sessions: 312, stones: 28,
                         latest: Self.date(2026, 9, 18), otherDeviceIDs: 2)
        case .previewFailed:
            // The re-read succeeds. Nobody may authorize deleting contents the
            // app never enumerated, so this is the ONLY way the door opens.
            previewRetries == 0 ? nil
                : Self.preview(subjects: 9, sessions: 312, stones: 28,
                               latest: Self.date(2026, 9, 18), otherDeviceIDs: 1)
        case .lineageUnavailable, .lineageUnavailableEnabled, .lineageUnavailableClosed:
            // review-1-1 / review-2-2. There IS something to enumerate here:
            // a missing control record says nothing about the account's rows,
            // and the door on this screen deletes them. Same shape as the
            // branch's Settings fixture for a ledger-less account.
            Self.preview(subjects: 9, sessions: 312, stones: 28,
                         latest: Self.date(2026, 9, 18), otherDeviceIDs: 1)
        case .lineageUnavailableUnreadable:
            previewRetries == 0 ? nil
                : Self.preview(subjects: 9, sessions: 312, stones: 28,
                               latest: Self.date(2026, 9, 18), otherDeviceIDs: 1)
        case .blocked, .inProgress, .remoteResumeClosed, .remoteResumeOpen,
             .environmentMismatch, .localLedgerMissingExplain:
            // There is nothing to enumerate on these screens, and none of them
            // carries a control that a pre-flight could gate.
            nil
        }
    }

    private var devicePreview: StorageTransferCloudPreview? {
        switch scenario {
        case .choice, .otherDevices, .previewFailed, .lineageUnavailableEnabled,
             .lineageUnavailableUnreadable:
            Self.preview(subjects: 12, sessions: 480, stones: 36,
                         latest: Self.date(2026, 9, 20), otherDeviceIDs: 0)
        case .blocked, .inProgress, .remoteResumeClosed, .remoteResumeOpen,
             .lineageUnavailable, .lineageUnavailableClosed, .environmentMismatch,
             .localLedgerMissingExplain:
            // The host skips the device side while the direction it informs is
            // unpublished, so the shipping fixtures must not carry one either.
            nil
        }
    }

    private static func preview(subjects: Int, sessions: Int, stones: Int,
                                latest: Date, otherDeviceIDs: Int,
                                ignoredWriterIDs: Int = 0) -> StorageTransferCloudPreview {
        var counts = Dictionary(uniqueKeysWithValues:
            PomoGemStorageSnapshot.cloudModelNames.map { ($0, 0) })
        counts["Subject"] = subjects
        counts["StudySession"] = sessions
        counts["AchievementStone"] = stones
        return StorageTransferCloudPreview(recordCounts: counts, latestRecordAt: latest,
                                           otherDeviceIDs: otherDeviceIDs,
                                           ignoredWriterIDs: ignoredWriterIDs)
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        return calendar.date(from: components) ?? Date(timeIntervalSinceReferenceDate: 0)
    }
}
#endif
