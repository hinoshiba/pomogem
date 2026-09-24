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

    /// What a `CancellationError` caught by the launch attempt must do. The
    /// two resume paths both need a signal that a fully active app has already
    /// spent: `.onChange(of: scenePhase)` needs a transition, and the
    /// `didBecomeActiveNotification` receiver needs `isWaitingForActivation`,
    /// which it reads before this catch can set it. Deriving only a flag from
    /// the lifecycle state — as the catch used to — therefore strands the
    /// launch whenever the throw propagates across an await and the app
    /// becomes active in between.
    enum DeferredLaunchResolution: Equatable {
        /// Not active yet: record the wait and let activation restart it.
        case waitForActivation
        /// Already fully active: no resume trigger is left, restart now.
        case restartImmediately
    }

    static func deferredLaunchResolution(
        phase: ScenePhase,
        applicationState: UIApplication.State
    ) -> DeferredLaunchResolution {
        phase == .active && applicationState == .active ? .restartImmediately : .waitForActivation
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
    /// Seeds this many deleted themes (tombstones) next to the fixture theme.
    static let deletedThemeHistoryUITestEnvironmentKey = "POMOGEM_UI_TEST_DELETED_THEMES"
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
    static let deletedThemeHistoryUITestEnvironmentKey = ""
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
        /// `retryOffersDatasetChoice` is true only on the one route whose retry
        /// leads to the dataset-refresh screen: `presentDatasetRefresh`
        /// failed to READ iCloud. transfer-06 / launch-05: every other
        /// producer (account errors, leftover stores, retirement timeouts,
        /// the activation watchdog…) used to inherit a caption promising that
        /// 「もう一度試す」 would re-fetch iCloud data.
        case blocked(String, retryOffersDatasetChoice: Bool = false)
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
    // Sticky for the process: a later attempt cannot undo a storage mode an
    // earlier one already recorded, so the watchdog screen must not promise it.
    @State private var didCommitStorageSelection = false
    // The user's own iCloud choice in this process. A retry may resume that
    // choice; no interruption of any kind may manufacture it.
    @State private var didConfirmCloudSelection = false
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
    @State private var launchActivationWatchdog = LaunchActivationWatchdog()
    @State private var offlineFallbackRequested = false
    /// device-01. The user chose 「端末のデータでオフライン利用」 on a
    /// storage-transfer stop screen. The offline session that opens next must
    /// not promise that a restored connection resumes sync — it meets the same
    /// stop — so it gets the transfer recovery notice and its honest message.
    /// Consumed by the next `openOfflineSession`.
    @State private var offlineSessionFollowsTransferStop = false
    @State private var requestedOnlineCloudLaunch = false
    @State private var offlineRecovery = CloudOfflineRecoveryPresentation()
    @State private var canContinueOffline = false
    @State private var isCheckingOfflineConnection = false
    @State private var offlineRevocationWriteFailed = false
    /// This process was told the account state moved and has not completed a
    /// boundary resolution since. Deliberately in-process only: it is not
    /// evidence about the account, so it must not outlive the process the way
    /// a receipt revocation does. A relaunch starts over from the receipt, and
    /// the cold-launch case — the account changed while the app was not
    /// running, so no notification was ever delivered — is not covered by it.
    @State private var hasUnresolvedAccountStateMovement = false
    @State private var offlineConnectionTask: Task<Void, Never>?
    @State private var offlineConnectionAttempt: UUID?
    @State private var offlineMessage = PomoGemPersistenceLaunchHost.defaultOfflineMessage
    /// The ordinary offline session's banner message: a restored connection
    /// is re-checked and sync resumes.
    private static let defaultOfflineMessage = "タイマーや記録を利用できます。接続回復後に同期を再開します。"
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
    /// transfer-04. The durable phase of the transfer this launch is
    /// continuing, for EVERY choice (it used to exist for the unpublished
    /// overwrite only), updated as the coordinator advances.
    @State private var transferInProgress: StorageTransferProgress?
    /// transfer-04. The relaunch screen says 「次に開くと…完了します」 only when
    /// the durable checkpoint shows the next launch is the last one.
    @State private var relaunchCompletesTransfer = false
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
            quiesceForPossibleAccountChange()
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
            cancelLaunchActivationDeadline()
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
            onRefreshWithoutLineage: cloudLineageRefreshAction,
            onExportDeviceData: deviceDataExportAction,
            onRetryCloudPreview: datasetPreviewRetryAction,
            cloudPreview: cloudDatasetPreview,
            devicePreview: deviceDatasetPreview,
            cloudPreviewFailed: cloudDatasetPreviewFailed,
            transferProgress: transferInProgress,
            relaunchCompletesTransfer: relaunchCompletesTransfer,
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
        guard screenArmsItsDoorWithAPreflight, !isExportingDeviceData,
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
        } else if ScreenTimeSettingsUITestFixture.isActiveForCurrentProcess {
            ScreenTimeSettingsUITestFixtureLaunchView()
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
        cancelLaunchActivationDeadline()
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
                requireStorageTransferRelaunch(message: "切り替えを取り消しました。元の記録を保護したまま、アプリを終了して開き直してください。",
                                               afterCancellation: true)
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
                   let dispatch = request.dispatch(for: requestBinding, cloudScope: .current()) {
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
                var cancelled = false
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
                    cancelled = true
                case let .refresh(generation):
                    guard let binding = storageTransferRecoveryBinding else { throw StorageTransferError.staleTransaction }
                    try await transferRuntime.refreshCloudDataset(binding: binding,
                        expectedGenerationID: generation, validateAccess: {
                        try requireActiveLaunchAttempt(attempt, checkpoint: "during-dataset-refresh")
                    })
                    completionMessage = StorageTransferProgressCopy.refreshReady
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
                    completionMessage = StorageTransferProgressCopy.refreshReady
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
                    cancelled = true
                }
                try requireActiveLaunchAttempt(attempt, checkpoint: "after-transfer-recovery")
                requireStorageTransferRelaunch(message: completionMessage, afterCancellation: cancelled)
                return
            }
            // A journal can describe moved/promoted stores that intentionally
            // do not satisfy the ordinary artifact policy until recovery ends.
            // Inspect it before that policy and before either storage mode opens.
            let pendingTransfer = try transferRuntime.pendingLocalJournal()
            cancellableLocalTransferID = pendingTransfer?.permitsCancellation == true
                ? pendingTransfer?.transactionID : nil
            retainsTransferCopyOnCancellation = pendingTransfer?.retainsImportOnCancellation == true
            transferInProgress = pendingTransfer.map {
                StorageTransferProgress(choice: $0.choice, phase: $0.phase)
            }
            if pendingTransfer != nil {
                canChooseLocalOnly = false
                guard scenePhase == .active else {
                    launchState = .preparing("保存先の切り替えを再開する準備をしています")
                    return
                }
                // transfer-04. A planned continuation is not an interruption.
                launchState = .preparing(StorageTransferProgressCopy.continuing)
                var cancelledRetainedImport = false
                // The mirror wait can take minutes, and auto-lock would end
                // this launch attempt (the scene stops being active) and cost
                // the user another relaunch. Only the launch host is on
                // screen here; no focus view owns the idle timer.
                UIApplication.shared.isIdleTimerDisabled = true
                defer { UIApplication.shared.isIdleTimerDisabled = false }
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
                        }, progress: { phase in
                            if let current = transferInProgress {
                                transferInProgress = StorageTransferProgress(choice: current.choice, phase: phase)
                            }
                        })
                        cancelledRetainedImport = outcome == .cancelledRetainingImport
                    }
                )
                if cancelledRetainedImport {
                    requireStorageTransferRelaunch(message: "中断された取り込みの取消しを完了しました。元の保存先とiCloudの記録、途中までのコピーを保持しています。アプリを終了して開き直してください。",
                                                   afterCancellation: true)
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
                   requestedOfflineFallback: offlineFallbackRequested, networkIsOffline: networkPath.isOffline,
                   hasUnresolvedAccountStateMovement: hasUnresolvedAccountStateMovement) {
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
            // A complete resolution is the only thing that answers the
            // question a quiescence asked. Until one arrives, no route may
            // reopen the local copy on the receipt alone.
            hasUnresolvedAccountStateMovement = false
            try requireActiveLaunchAttempt(
                attempt,
                checkpoint: "before-profile-commit"
            )
            storageTransferRecoveryBinding = resolvedBoundary.binding
            try PersistenceDeploymentState.select(.cloud(
                binding: resolvedBoundary.binding
            ))
            didCommitStorageSelection = true
            try requireCloudMountAuthorization(
                expectedBinding: resolvedBoundary.binding,
                verifiedBinding: resolvedBoundary.binding,
                attempt: attempt,
                checkpoint: "after-initial-identity"
            )
            // The live identity has now been verified and resolved to exactly
            // the stored binding. That is the comparison a revocation written
            // without one was always missing, so retract it here — before the
            // transfer/lineage preflights, which can block this launch long
            // before any mount could clear it.
            if expectedCloudBinding != nil {
                recordLaunchRecovery(CloudOfflineLaunchRecovery(
                    expectedBinding: expectedCloudBinding,
                    resolvedBinding: resolvedBoundary.binding
                ).run(state: try? CloudOfflineAccessState(),
                      isEligible: { offlineCopyIsEligible(binding: $0) }))
            }
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
            var resolution = PersistenceLaunchScenePolicy.DeferredLaunchResolution.waitForActivation
            if launchAttempt == attempt, !Task.isCancelled, !isQuiescingAccountChange {
                resolution = PersistenceLaunchScenePolicy.deferredLaunchResolution(
                    phase: scenePhase,
                    applicationState: UIApplication.shared.applicationState
                )
                isWaitingForLaunchActivation = resolution == .waitForActivation
                // iOS can hold its own modal without delivering activation.
                // Keep that wait bounded while a fully active catch restarts now.
                if isWaitingForLaunchActivation { armLaunchActivationDeadline(attempt: attempt) }
            }
            // Record lifecycle values only; never account identifiers, model
            // contents or store paths. Cancellation must be distinguishable
            // from a watchdog expiry when diagnosing a retained loading view.
            Self.persistenceLogger.info(
                "Launch cancelled attempt=\(attempt) current=\(launchAttempt) taskCancelled=\(Task.isCancelled) active=\(scenePhase == .active) quiescing=\(isQuiescingAccountChange) ownsDeadline=\(ownedDeadline != nil && cloudLaunchDeadline === ownedDeadline) resolution=\(String(describing: resolution))"
            )
            // A cancellation raised deep inside awaited CloudKit work is
            // observed after actor hops, so the activation this attempt was
            // waiting for may already have arrived: `.onChange(of: scenePhase)`
            // has no transition left to report and the didBecomeActive receiver
            // has already run against a false waiting flag. Restart here rather
            // than leave the launch on a 「準備中」 spinner with no control.
            if resolution == .restartImmediately { handleScenePhaseChange(.active) }
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
            launchState = .blocked(launchFailureMessage(for: error))
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
                ? .blocked(launchFailureMessage(for: error))
                : .failed(launchFailureMessage(for: error))
        }
    }

    /// The message a blocked or failed launch shows. When the only thing
    /// keeping the local copy off the screen is an account-state movement this
    /// process could not resolve, say that instead of reporting the transport
    /// failure alone: 「もう一度試す」 is then the entire recovery, and the
    /// previous wording would have promised an offline door that is shut.
    private func launchFailureMessage(for error: Error) -> String {
        guard case let .selected(.cloud(binding)) = PersistenceDeploymentState.load() else {
            return error.localizedDescription
        }
        return CloudOfflineHostPolicy.unresolvedAccountMovementMessage(
            after: error,
            hasUnresolvedAccountStateMovement: hasUnresolvedAccountStateMovement,
            offlineCopyWouldOtherwiseBeEligible: receiptPermitsOfflineUse(binding: binding)
        ) ?? error.localizedDescription
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
        // The device's own mount record is offered for the one pre-receipt
        // adoption rule (1.0 / 1.0.1 stores); the runtime reads it only when
        // that rule could apply, and the later preflights of this mount find
        // the receipt this one wrote.
        try await StorageTransferRuntime.live().preflightCloudMount(
            binding: binding,
            legacyCloudMountEvidence: { .live(binding: binding) },
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
                        sceneIsActive: scenePhase == .active,
                        hasUnresolvedAccountStateMovement: hasUnresolvedAccountStateMovement)
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
        let followsTransferStop = offlineSessionFollowsTransferStop
        offlineSessionFollowsTransferStop = false
        try requireActiveLaunchAttempt(attempt, checkpoint: "before-offline-copy")
        guard !offlineRevocationWriteFailed else { return false }
        // Nothing below compares an identity: the receipt, the store pair and
        // the transfer gates are all local records of a PREVIOUS check. While
        // an account-state movement is unresolved they cannot say who is
        // signed in, so this route stays closed until a resolution reopens it.
        guard !hasUnresolvedAccountStateMovement else { return false }
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
        let offlineSession = PomoGemPersistenceSession(container: container, mode: .cloudKit,
            accountNamespace: binding.namespace, isCloudOffline: true)
        session = offlineSession
        if followsTransferStop {
            // The banner's 「復旧手順」 returns to the stop screen that sent the
            // user here; 「同期を再開」 would only meet the same stop.
            offlineRecovery.notice = .init(kind: .storageTransfer,
                sessionID: offlineSession.id, binding: binding)
            offlineMessage = StorageTransferLineageCopy.offlineSessionMessage
        } else {
            offlineRecovery.notice = nil
            // A transfer-stop session earlier in this process left its own
            // wording behind. Without the notice it would promise a 「復旧手順」
            // the banner no longer carries, beside a 「同期を再開」 it
            // contradicts. A message a caller set for THIS session is kept.
            if offlineMessage == StorageTransferLineageCopy.offlineSessionMessage {
                offlineMessage = Self.defaultOfflineMessage
            }
        }
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
                    let boundary = try await AppleAccountBoundaryResolver().resolve(expectedBinding: binding)
                    try validate()
                    hasUnresolvedAccountStateMovement = false
                    // The retraction is ordered before the preflight by the
                    // recovery step itself, not by the order of these lines.
                    let runtime = try await CloudOfflineLaunchRecovery(
                        expectedBinding: binding, resolvedBinding: boundary.binding
                    ).run(state: try? CloudOfflineAccessState(),
                          isEligible: { offlineCopyIsEligible(binding: $0) },
                          record: { recordLaunchRecovery($0) }) { () -> StorageTransferRuntime in
                        let runtime = try StorageTransferRuntime.live()
                        // An offline session opened on a 1.0 / 1.0.1 store is
                        // the other way such a store first meets this build
                        // online, so it carries the same device evidence.
                        try await runtime.preflightCloudMount(binding: binding,
                            legacyCloudMountEvidence: { .live(binding: binding) },
                            validateAccess: validate)
                        return runtime
                    }
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
        offlineSessionFollowsTransferStop = false
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
        guard !hasUnresolvedAccountStateMovement,
              CloudOfflineHostPolicy.allowsOfflineFallback(after: error), launchAttempt == attempt,
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

    /// The offline door as the user sees it. An account-state movement this
    /// process has not resolved withdraws the door even from a receipt that
    /// is otherwise perfectly eligible: the receipt says which account the
    /// local copy belongs to, never which account is signed in now.
    private func offlineCopyIsEligible(binding: ActiveAccountLocalBinding) -> Bool {
        !hasUnresolvedAccountStateMovement && receiptPermitsOfflineUse(binding: binding)
    }

    private func receiptPermitsOfflineUse(binding: ActiveAccountLocalBinding) -> Bool {
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
        offlineSessionFollowsTransferStop = launchStateIsStorageTransferStop
        offlineFallbackRequested = true
        launchAttempt += 1
    }

    /// The stop screens whose state a restored connection does not clear by
    /// itself: each needs a decision on the stop screen (or the other device)
    /// before sync can resume.
    private var launchStateIsStorageTransferStop: Bool {
        switch launchState {
        case .datasetRefresh, .cloudLineageUnavailable, .datasetExplanation: true
        default: false
        }
    }

    /// Apply what `CloudOfflineLaunchRecovery` decided: the offline door is
    /// reopened in this same launch attempt, so a launch that is blocked later
    /// by a lineage or transfer preflight still offers the local copy. A
    /// failed write is not fatal — the receipt simply stays as it was.
    private func recordLaunchRecovery(_ outcome: CloudOfflineLaunchRecovery.Outcome) {
        canContinueOffline = outcome.offlineCopyIsEligible
        if let retracted = outcome.retractedReason {
            Self.persistenceLogger.notice(
                "Offline receipt revocation retracted reason=\(retracted.rawValue, privacy: .public)"
            )
        }
        if outcome.failed {
            Self.persistenceLogger.notice(
                "Offline receipt revocation retraction failed"
            )
        }
    }

    private func revokeOfflineForAccountError(_ error: Error, binding: ActiveAccountLocalBinding) {
        guard let reason = CloudOfflineHostPolicy.revocationReason(for: error) else { return }
        canContinueOffline = false
        do { try CloudOfflineAccessState().revoke(binding: binding, reason: reason) }
        catch {
            offlineRevocationWriteFailed = true
            Self.persistenceLogger.notice(
                "Offline receipt revocation write failed reason=\(reason.rawValue, privacy: .public)"
            )
        }
        if session != nil { quiesceForPossibleAccountChange() }
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

    /// The documented launch budget for the recorded storage selection: 12 s
    /// once this device established a cloud store, 30 s otherwise. Reading it
    /// touches only local selection files, never the account or the network.
    private func selectedCloudLaunchTimeout() -> TimeInterval {
        let selection = PersistenceDeploymentState.load()
        let hasExactCompleteStorePair: Bool
        if case let .selected(.cloud(binding)) = selection {
            hasExactCompleteStorePair = PersistenceStoreTopology.persistenceArtifactHistory()
                .hasExactCompleteStorePair(for: .cloud(binding: binding))
        } else {
            hasExactCompleteStorePair = false
        }
        return CloudOfflineHostPolicy.launchTimeout(selection: selection,
            mountState: PersistenceDeploymentState.loadMountState(),
            hasExactCompleteStorePair: hasExactCompleteStorePair)
    }

    /// The state every watchdog decision reads, sampled now. The generation is
    /// the attempt currently on screen, so a superseded expiry is discarded.
    private var launchActivationFrame: LaunchActivationWatchdog.Frame {
        LaunchActivationWatchdog.Frame(
            generation: launchAttempt,
            hasSession: session != nil,
            isWaitingForActivation: isWaitingForLaunchActivation,
            isPreparing: isPreparing,
            isQuiescingAccountChange: isQuiescingAccountChange,
            requiresStorageTransferRelaunch: requiresStorageTransferRelaunch,
            phase: scenePhase,
            applicationState: UIApplication.shared.applicationState
        )
    }

    private var endsLaunchActivationWait: LaunchActivationWatchdog.Expiry {
        { attempt in endLaunchActivationWait(attempt: attempt) }
    }

    /// Covers the window between the first lifecycle checkpoint and the
    /// account deadline, where a deferred attempt has already returned and
    /// nothing else is armed. Storage-transfer recovery keeps running outside
    /// any launch budget: it is progressing work with its own relaunch
    /// contract, and interrupting it would change transfer semantics.
    private func armLaunchActivationDeadline(attempt: Int) {
        guard launchActivationWatchdog.armForDeferredAttempt(
            frame: launchActivationFrame,
            timeout: selectedCloudLaunchTimeout(),
            expire: endsLaunchActivationWait
        ) else { return }
        Self.persistenceLogger.info(
            "Launch activation wait armed attempt=\(attempt) timeout=\(launchActivationWatchdog.armedTimeout ?? 0)"
        )
    }

    private func cancelLaunchActivationDeadline() {
        launchActivationWatchdog.cancel()
    }

    /// Expiry is a lifecycle observation, not an account or storage result:
    /// it selects no storage mode, opens nothing and revokes nothing itself.
    /// The launch it interrupts may already have done so, which is what the
    /// message reports. The offline affordance still has to pass the ordinary
    /// eligibility gate, and taking it revalidates every condition again.
    private func endLaunchActivationWait(attempt: Int) {
        guard launchActivationWatchdog.settleExpiry(
            generation: attempt,
            frame: launchActivationFrame
        ) else { return }
        isWaitingForLaunchActivation = false
        if case let .selected(.cloud(binding)) = PersistenceDeploymentState.load() {
            canContinueOffline = offlineCopyIsEligible(binding: binding)
        }
        let progress = LaunchActivationWatchdogPolicy.launchProgress(
            didCommitStorageSelection: didCommitStorageSelection,
            cloudMirrorWasOpened: StorageTransferProcessState.cloudMirrorWasOpened
        )
        Self.persistenceLogger.info(
            "Launch activation wait expired attempt=\(attempt) offlineOffered=\(canContinueOffline) progress=\(String(describing: progress))"
        )
        launchState = .blocked(
            LaunchActivationWatchdogPolicy.blockedMessage(progress: progress)
        )
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
            direction: direction, binding: binding, cloudScope: .current(), datasetGenerationID: generation,
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
        guard case let .selected(source) = PersistenceDeploymentState.load() else {
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
        guard case let .cloud(binding) = source else {
            return try await previewLocalEnableCloud(sourceSession: sourceSession, runtime: runtime,
                                                     deviceID: deviceID, validate: validate)
        }
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
        // holds. transfer-03: always read, because 「iCloudから再取得」 ships in
        // every build and THIS iPhone is the side it deletes. The session is
        // mounted, so its own container is read through a fresh, unsaved
        // context and reduced by the same per-row reduction as the iCloud
        // side — no byte copy of a live store, and no full snapshot.
        let device = try? Self.mountedDevicePreview(container: sourceSession.container,
                                                    localDeviceID: deviceID)
        try validate()
        return StorageTransferDatasetPreviewSummary(cloud: cloud, device: device,
                                                    hasCloudLineage: lineage)
    }

    /// transfer-02. The pre-flight behind 「iCloudのデータを使う」, the one door a
    /// local-only user has into iCloud, which deletes this device's jar. It
    /// resolves which Apple Account iCloud would mean (read-only: the
    /// resolution is never persisted here), reads that account's iCloud side
    /// and counts this iPhone. It opens no mirror, writes no journal or
    /// request and authorizes nothing: `begin` re-resolves and re-reads
    /// everything it relies on.
    ///
    /// The account is re-checked around the read by fingerprint, not by
    /// namespace: a local-only install has no cloud namespace to compare, and
    /// what the user is shown must simply be this account's iCloud.
    private func previewLocalEnableCloud(
        sourceSession: PomoGemPersistenceSession,
        runtime: StorageTransferRuntime,
        deviceID: String,
        validate: @escaping @MainActor () throws -> Void
    ) async throws -> StorageTransferDatasetPreviewSummary {
        let binding = try await AppleAccountBoundaryResolver().resolve().binding
        try validate()
        let live = CloudStorageTransferCloudClient.live
        let client = CloudStorageTransferCloudClient(verifyAccount: { expected in
            let current = try await AppleAccountBoundaryResolver().resolve().binding
            guard current.accountFingerprint == expected.accountFingerprint else {
                throw StorageTransferRecoveryError.identityMismatch
            }
        }, readDatabase: live.readDatabase)
        let cloud = try await runtime.previewCloudDataset(localDeviceID: deviceID, readSnapshot: {
            try await CloudStorageTransferCloudKit(client: client,
                timeout: StorageTransferCloudPreviewPolicy.timeout)
                .readSnapshot(expectedBinding: binding, validateTransfer: validate).snapshot
        }, validateAccess: validate)
        try validate()
        let device = try? Self.mountedDevicePreview(container: sourceSession.container,
                                                    localDeviceID: deviceID)
        try validate()
        return StorageTransferDatasetPreviewSummary(cloud: cloud, device: device)
    }

    /// The device side of a Settings comparison, read from the session that is
    /// already mounted, through a fresh context that holds no changes and
    /// writes nothing. `StorageTransferCloudPreview.make(context:)` walks the
    /// mirrored models' scalar fields once — not a full snapshot of every
    /// field and relationship of every entity — and reduces them with the
    /// same per-row reduction as the iCloud side.
    @MainActor
    static func mountedDevicePreview(container: ModelContainer,
                                     localDeviceID: String) throws -> StorageTransferCloudPreview {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return try StorageTransferCloudPreview.make(context: context, localDeviceID: localDeviceID)
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

    /// - Parameter afterCancellation: the relaunch follows a cancellation. The
    ///   screen then never says 「次に開くと、保存先の切り替えが完了します」:
    ///   a retained cancellation can leave a journal that is past saving the
    ///   destination, and the next launch does not complete THAT transfer.
    private func requireStorageTransferRelaunch(message: String? = nil, afterCancellation: Bool = false) {
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
        // The user is told to quit and reopen the app; no session mounts again
        // in this process, so nothing else would retire the Screen Time lease.
        ScreenTimeOwnerBoundaryPolicy.retire(for: .storageTransferRelaunch)
        NotificationManager.shared.cancelFocusReturnReminder()
        beginContainerRetirement()
        isQuiescingAccountChange = false
        isPreparing = false
        relaunchCompletesTransfer = !afterCancellation
            && ((try? StorageTransferRuntime.live())?.pendingTransferCompletesOnNextLaunch() ?? false)
        launchState = .relaunchRequired(message ?? "保存先の切り替えを受け付けました。Appスイッチャーでポモジェムを終了し、もう一度開いてください。元の記録を保護したまま切り替えを続けます。")
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
              // S14, as on the lineage screen: this deletes the DEVICE side,
              // and nobody is asked to do that on the strength of an iCloud
              // read that never happened. The door is disabled until then;
              // this guard keeps a tap from outrunning that.
              cloudDatasetPreview != nil,
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

    /// device-01. 「iCloudから再取得」 on the `.cloudLineageUnavailable` screen:
    /// the policy-free `refreshCloudDatasetWithoutLineage`, the SAME entry
    /// point Settings dispatches for an account with no ledger. It writes
    /// nothing to iCloud and deletes this device's side only after the
    /// 「最後の確認」 sheet's own acknowledgement. nil until the read-only
    /// pre-flight has enumerated the iCloud side (S14), so the screen can
    /// never offer it on an unread server; the runtime re-reads the control
    /// record and refuses the moment any lineage exists.
    private var cloudLineageRefreshAction: (() -> Void)? {
        guard case .cloudLineageUnavailable = launchState, !isPreparing,
              !requiresStorageTransferRelaunch,
              storageTransferRecoveryBinding != nil,
              storageTransferRefreshGenerationID == nil else { return nil }
        return { requestDatasetRefreshWithoutLineage() }
    }

    private func requestDatasetRefreshWithoutLineage() {
        guard case .cloudLineageUnavailable = launchState, !isPreparing,
              !requiresStorageTransferRelaunch,
              storageTransferRecoveryBinding != nil,
              cloudDatasetPreview != nil,
              storageTransferRefreshGenerationID == nil else { return }
        datasetPreviewRequest = nil
        remoteRecoveryAction = .refreshWithoutLineage
        launchState = .preparing("iCloudからの再取得を準備しています")
        launchAttempt += 1
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
        let cloud: StorageTransferCloudPreview
        do {
            cloud = try await StorageTransferRuntime.live().previewCloudDataset(
                binding: binding, localDeviceID: deviceID,
                validateAccess: { try requireDatasetPreviewRequest(request) })
        } catch {
            guard datasetPreviewRequest == request else { return }
            cloudDatasetPreview = nil
            deviceDatasetPreview = nil
            cloudDatasetPreviewFailed = true
            return
        }
        guard datasetPreviewRequest == request else { return }
        // Always read: both screens that run this pre-flight carry
        // 「iCloudから再取得」, which ships in every build and deletes THIS
        // side, so its counts are part of what the user consents to
        // (transfer-03 / device-01). The read byte-copies both stores and
        // mounts the copy, then walks only the mirrored models' scalar fields
        // once (`StorageTransferCloudPreview.make(context:)`), not a full
        // snapshot. It stays on the main actor: the disposable container is
        // tracked by `StorageTransferPersistence`, and one still alive when a
        // 「もう一度試す」 reaches `requireAllReleased()` would turn a retry into
        // a forced relaunch.
        var device: StorageTransferCloudPreview?
        if case let .selected(selection) = PersistenceDeploymentState.load() {
            // Best effort. An unreadable device side degrades the comparison
            // to 「確認できませんでした」; it never gates the destructive door,
            // which is about what the SERVER holds.
            device = try? StorageTransferLaunchReader.captureDevicePreview(
                selection: selection, localDeviceID: deviceID)
        }
        guard datasetPreviewRequest == request else { return }
        // Published together, so the comparison never shows one side counted
        // and the other 「確認できませんでした」 merely because it is still read.
        cloudDatasetPreview = cloud
        deviceDatasetPreview = device
        cloudDatasetPreviewFailed = false
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
            transferInProgress = journal.map { StorageTransferProgress(choice: $0.choice, phase: $0.phase) }
        } catch {
            cancellableLocalTransferID = nil
            retainsTransferCopyOnCancellation = false
            transferInProgress = nil
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
            launchState = .blocked(StorageTransferLineageCopy.refreshScreenUnavailable,
                                   retryOffersDatasetChoice: true)
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
        offlineSessionFollowsTransferStop = false
        cancelLaunchActivationDeadline()
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
        let storageModeIsUnselected: Bool
        if case .unselected = PersistenceDeploymentState.load() {
            storageModeIsUnselected = true
        } else {
            storageModeIsUnselected = false
        }
        if LaunchRetryConsentPolicy.restoresPendingCloudSelection(
            storageModeIsUnselected: storageModeIsUnselected,
            didConfirmCloudSelection: didConfirmCloudSelection
        ) {
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
        didConfirmCloudSelection = true
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
            didCommitStorageSelection = true
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

    /// Close the live account boundary because the account MIGHT have changed,
    /// and start a fresh launch that will resolve the identity again.
    ///
    /// `.CKAccountChanged` is posted for every movement of account state —
    /// signing in or out, iCloud being switched on or off for this app, a
    /// token refresh, an availability transition. It carries no identity, so
    /// it compares nothing against the stored binding and is not evidence that
    /// another Apple Account is signed in. Quiescing here stays fail-closed:
    /// scheduling is suspended, the cross-process binding is cleared, the
    /// containers are retired and nothing reopens until a complete boundary
    /// resolution succeeds. The durable receipt is deliberately left alone;
    /// when the account really did change, that resolution returns
    /// `.blocked(.accountMismatch)` and `revokeOfflineForAccountError` records
    /// it with the reason that a comparison actually produced.
    ///
    /// What replaces the revocation on the offline route is
    /// `hasUnresolvedAccountStateMovement`: until a resolution completes, the
    /// local copy cannot be reopened on the receipt alone, so the launch fails
    /// closed without writing anything that outlives the process.
    private func quiesceForPossibleAccountChange() {
        // Which of the two paths fired, and when, could previously only be
        // guessed from the receipt file's timestamp.
        Self.persistenceLogger.notice(
            "Account boundary quiesced for a possible account change; the offline receipt is unchanged"
        )
        switch CloudOfflineHostPolicy.reactionToAccountStateNotification(
            selection: PersistenceDeploymentState.load()
        ) {
        case .quiesceOnly:
            break
        case let .revokeThenQuiesce(binding, reason):
            do { try CloudOfflineAccessState().revoke(binding: binding, reason: reason) }
            catch { offlineRevocationWriteFailed = true }
        }
        hasUnresolvedAccountStateMovement = true
        canContinueOffline = false
        cancelOfflineConnectionCheck()
        cloudLaunchDeadline?.cancel()
        cloudLaunchDeadline = nil
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
        // The Screen Time ledger lives outside the container, so it does not
        // follow. RootView — and with it the modifier that would notice a
        // changed owner — is removed in this same turn and nothing mounts
        // afterwards, so retire the lease here: otherwise the ledger keeps
        // contextIsActive = true and the extension keeps recording receipts
        // and black gems under an owner this app has already deactivated.
        ScreenTimeOwnerBoundaryPolicy.retire(for: .accountIdentityChange)
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
        if phase == .background {
            // Leaving while the completion alarm repeats counts as Stop.
            // Record it before any container retirement below, while the
            // defaults key is still scoped to this timer's account.
            TimerCompletionAlertController.shared.acknowledgeOnLeavingApp()
        }
        if phase != .active {
            cancelOfflineConnectionCheck()
            cloudLaunchDeadline?.cancel()
            cloudLaunchDeadline = nil
        }
        // The OS owns a suspended process and must not be blamed for a wait
        // the user never saw; returning to the foreground behind the same
        // system modal never reaches .active, so the inactive transition is
        // the only chance to re-arm. An armed budget is never restarted.
        launchActivationWatchdog.handleScenePhaseChange(
            phase,
            frame: launchActivationFrame,
            timeout: selectedCloudLaunchTimeout(),
            expire: endsLaunchActivationWait
        )
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
        // Cloud-backed RootView is absent while the account is revalidated,
        // so no Stop control would be on screen. A retirement on the way to
        // the background finds the alarm already acknowledged and stopped
        // (handleScenePhaseChange). One while the app stays on screen, such
        // as CKAccountChanged, only suspends it: the timer's next view in
        // this process restores it (resumeSuspendedAlert). A relaunch never
        // re-arms a loop.
        TimerCompletionAlertController.shared.suspendForContainerRetirement()
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
        // Keep a suspended alarm's memory: if the account turns out unchanged,
        // the same timer remounts and restores it; otherwise its session never
        // comes back in the new account's namespace.
        TimerCompletionAlertController.shared.suspendForContainerRetirement()
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
    /// device-01. 「iCloudから再取得」 on the `.cloudLineageUnavailable` screen,
    /// from its own 「最後の確認」 sheet. nil while the host cannot run it.
    var onRefreshWithoutLineage: (() -> Void)?
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
    /// Non-nil while a transfer this installation started is durably in
    /// flight; drives the phase-aware progress copy for every choice.
    var transferProgress: StorageTransferProgress?
    /// transfer-04. The next launch completes the transfer.
    var relaunchCompletesTransfer = false
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
    @State private var storageChoiceViewportHeight: CGFloat = 0
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
    /// The lineage screen's 「iCloudから再取得」 sheet. It owns its own
    /// acknowledgement (inside the shared Settings confirmation view), so no
    /// other consent on this screen can arm it.
    @State private var presentsLineageRefreshConfirmation = false

    var body: some View {
        ZStack {
            NightBackground()
            ScrollView {
                VStack(spacing: 18) {
                    if isChoosingStorage {
                        storageChoiceHeader
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(PomoGemTheme.amber)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(PomoGemTheme.brand(24))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(isChoosingStorage ? .isHeader : [])
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
                        if let transferProgress {
                            // Derived from the durable journal phase, never
                            // from an optimistic guess about an in-flight
                            // effect, so a relaunch shows the same sentence.
                            Text(StorageTransferProgressCopy.progress(transferProgress))
                                .foregroundStyle(PomoGemTheme.muted)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier(transferProgress.choice.replacesCloud
                                    ? "storage-overwrite-progress" : "storage-transfer-progress")
                            if transferProgress.choice.replacesCloud {
                                Text(StorageTransferOverwriteCopy.notCancellable)
                                    .font(.caption)
                                    .foregroundStyle(PomoGemTheme.muted)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("storage-overwrite-not-cancellable")
                            }
                        }
                    } else if isChoosingStorage {
                        // launch-03 / product-01. Two equal cards, one plain
                        // line each (configuration.yml
                        // `equal_neither_recommended`): same shape, same
                        // style, no default. Each card is only the choice;
                        // its full caveats are in its own confirmation alert
                        // below, which stays the step that commits it. The
                        // card title stays the button's exact accessibility
                        // label because the real-device tests and the review
                        // notes name these buttons by it.
                        storageChoiceButton(
                            symbol: "icloud.fill",
                            title: String(localized: "iCloudに保存して同期", table: "Launch",
                                          comment: "First-run storage choice: iCloud option (button label)"),
                            detail: String(localized: "同じApple AccountのiPhone間で、記録を同期します。", table: "Launch",
                                           comment: "First-run storage choice: the iCloud option's one line"),
                            identifier: "storage-choice.cloud"
                        ) {
                            storageConfirmation = .cloud
                        }
                        storageChoiceButton(
                            symbol: "iphone",
                            title: String(localized: "このiPhoneだけに保存", table: "Launch",
                                          comment: "First-run storage choice: local-only option (button label)"),
                            detail: String(localized: "記録はこのiPhoneだけに保存し、iCloudへは送信しません。", table: "Launch",
                                           comment: "First-run storage choice: the local-only option's one line"),
                            identifier: "storage-choice.local"
                        ) {
                            storageConfirmation = .localOnly
                        }

                        Link(destination: AppLinks.privacyPolicy) {
                            Label(
                                "プライバシーポリシー",
                                systemImage: "hand.raised"
                            )
                            .font(.footnote.weight(.semibold))
                            .frame(minHeight: 44)
                        }
                        .foregroundStyle(PomoGemTheme.amber)
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
                        // No stop screen may be a dead end: in a shipping build
                        // the resume door is closed, and past `.backupVerified`
                        // nothing here can be cancelled either. Re-checking
                        // clears the screen once the other device finishes.
                        Button("もう一度試す", action: onRetry)
                            .buttonStyle(PomoGemSecondaryButtonStyle())
                            .accessibilityIdentifier("storage-transfer-recovery-retry")
                        supportLink
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
                        if relaunchCompletesTransfer {
                            Text(StorageTransferProgressCopy.nextLaunchCompletes)
                                .font(.headline)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("storage-transfer-relaunch-final")
                        }
                        // transfer-04. How to do it, not only that it must be
                        // done: this screen deliberately has no button. It is
                        // the one thing the user must act on here, so it is
                        // body text, and it never repeats a sentence the
                        // message above already says.
                        Text(StorageTransferProgressCopy.relaunchInstructions(after: message))
                            .foregroundStyle(PomoGemTheme.text)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("storage-transfer-relaunch-required")
                        supportLink
                    } else {
                        if case .blocked(_, true) = state {
                            // Only the dataset-refresh read failure: a retry
                            // there can actually reach the refresh choice. It
                            // carries NO destructive affordance of its own.
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
                        supportLink
                    }
                    if onCancelLocalTransfer != nil, showsLocalTransferCancellation {
                        Text(localTransferCancellationCaption)
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("storage-transfer-cancel-local-explanation")
                        Button("この端末の切り替えを取り消す") {
                            storageConfirmation = .cancelPendingTransfer
                        }
                        .buttonStyle(PomoGemSecondaryButtonStyle())
                        .accessibilityIdentifier("storage-transfer-cancel-local")
                    }
                }
                .frame(maxWidth: 520)
                .padding(24)
                // launch-03. The first-run choice sits in the middle of the
                // screen when it fits, instead of hanging from the top of
                // an otherwise empty first frame. Taller content (AX sizes)
                // scrolls exactly as before; every other state is unchanged.
                .frame(minHeight: isChoosingStorage ? storageChoiceViewportHeight : nil)
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { storageChoiceViewportHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in
                            storageChoiceViewportHeight = height
                        }
                }
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
                // launch-04. This alert is the step that commits local-only,
                // so it states the consequences plainly and in the order a
                // person meets them. Switching to iCloud later is possible,
                // but it REPLACES this iPhone's records with the iCloud
                // ones: `StorageTransferReleasePolicy.standard` keeps every
                // device -> iCloud path closed, so nothing here merges or
                // uploads. The old copy said 「後で…切り替えられます」 first
                // and the loss last, in engineering terms.
                Alert(
                    title: Text("このiPhoneだけに保存しますか？"),
                    message: Text("記録はこのiPhoneだけに保存し、iCloudへは送信しません。アプリを削除すると、記録は失われます。あとでiCloud同期に切り替えると、このiPhoneの記録はiCloudの記録に置き換わります。このiPhoneの記録をiCloudへ移すことは、現在できません。",
                                  tableName: "Launch",
                                  comment: "First-run storage choice: local-only confirmation message (full caveats)"),
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
        .sheet(isPresented: $presentsLineageRefreshConfirmation) {
            lineageRefreshConfirmationSheet
        }
        .onChange(of: state) { _, _ in
            understandsRefreshDataLoss = false
            understandsOverwriteDataLoss = false
            understandsLineageStart = false
            presentsOverwriteConfirmation = false
            presentsLineageConfirmation = false
            presentsLineageRefreshConfirmation = false
            confirmsTransferCancellation = false
        }
    }

    /// The `.datasetRefresh` screen a device that was fenced out of the current
    /// iCloud generation lands on. It offers both directions, each with its own
    /// unchecked acknowledgement on its own `@State`, plus the non-destructive
    /// doors. Reading either explanation is never consent, and consenting to
    /// one direction never arms the other.
    ///
    /// transfer-03. 「iCloudから再取得」 deletes THIS iPhone's side and ships in
    /// every build, so it gets the same evidence as the Settings and lineage
    /// doors before its toggle can arm it: both sides counted, the empty-iCloud
    /// warning, the export, and the Screen Time reset. What each side holds is
    /// stated once, above both doors, because both act on the same two
    /// datasets. The offline door comes before the device -> iCloud door, and
    /// a build that keeps that door shut states only its reason.
    @ViewBuilder
    private var datasetRefreshDoors: some View {
        Text(datasetComparison)
            .foregroundStyle(PomoGemTheme.muted)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("storage-dataset-comparison")
        if cloudPreviewFailed, let onRetryCloudPreview {
            // Non-destructive: it re-arms the read-only pre-flight and nothing
            // else. The failure sentence above names this control.
            Button(StorageTransferOverwriteCopy.retryPreviewTitle, action: onRetryCloudPreview)
                .buttonStyle(PomoGemSecondaryButtonStyle())
                .accessibilityIdentifier("storage-dataset-retry-preview")
        }

        doorHeader("iCloudのデータを使う")
        // One text, quoted by every surface that offers this direction.
        Text(StorageTransferRefreshCopy.dataLossWarning)
            .foregroundStyle(PomoGemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("storage-refresh-data-loss-warning")
        if StorageTransferRefreshCopy.cloudSideIsEmpty(cloudPreview) {
            Text(StorageTransferRefreshCopy.cloudSideEmpty(device: devicePreview))
                .foregroundStyle(PomoGemTheme.amber)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("storage-refresh-empty-cloud")
        }
        // transfer-07. No Screen Time owner is mounted on this screen, so the
        // sentence is conditional rather than an assertion about this user.
        Text(StorageTransferScreenTimeCopy.switchResetsIfInUse)
            .foregroundStyle(PomoGemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("storage-refresh-screen-time")
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
        Toggle("端末データの削除を確認しました", isOn: $understandsRefreshDataLoss)
            .accessibilityIdentifier("storage-refresh-confirm-data-loss")
        let refresh = Button(StorageTransferRefreshCopy.confirmTitle, role: .destructive, action: onRefreshDataset)
            // S14: nobody is asked to discard this device's side on the
            // strength of an iCloud read that never happened.
            .disabled(!understandsRefreshDataLoss || cloudPreview == nil)
            .accessibilityIdentifier("storage-refresh-confirm")
        if StorageTransferRefreshCopy.cloudSideIsEmpty(cloudPreview) {
            // The warning above ends 「中止して…」; the next thing on screen
            // must not be the brightest control on it doing the opposite.
            refresh.buttonStyle(PomoGemSecondaryButtonStyle())
        } else {
            refresh.buttonStyle(PomoGemPrimaryButtonStyle())
        }

        // No stop screen may leave a destructive door as the only way on, and
        // the one that deletes nothing comes before the one that is closed.
        if let onContinueOffline {
            doorHeader(StorageTransferLineageCopy.offlineDoorTitle)
            Text(StorageTransferLineageCopy.offlineExplanation(offersLineageStart: false))
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("storage-refresh-offline-explanation")
            Button("端末のデータでオフライン利用", action: onContinueOffline)
                .buttonStyle(PomoGemSecondaryButtonStyle())
                .accessibilityIdentifier("cloud-offline-continue")
        }

        doorHeader("このiPhoneのデータを使う")
        if releasePolicy.allowsDatasetOverwriteFromDevice {
            Text(overwriteOtherDeviceEvidence)
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("storage-overwrite-other-devices")
            Text(StorageTransferOverwriteCopy.dataLossWarning)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("storage-overwrite-data-loss-warning")
        } else {
            // transfer-08, as in Settings: the long irreversible-deletion
            // warning belongs to a door that can open. A closed one states
            // only its reason.
            Text(StorageTransferOverwriteCopy.doorUnavailable)
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("storage-overwrite-unavailable")
        }
        Button(StorageTransferOverwriteCopy.confirmTitle, role: .destructive) {
            // Never acts on tap. It opens the second screen, whose own
            // acknowledgement starts unchecked on every presentation.
            understandsOverwriteDataLoss = false
            presentsOverwriteConfirmation = true
        }
        .buttonStyle(PomoGemSecondaryButtonStyle())
        .disabled(!canRequestOverwrite)
        .accessibilityIdentifier("storage-overwrite-confirm")

        Button("もう一度試す", action: onRetry)
            .buttonStyle(PomoGemSecondaryButtonStyle())
            .accessibilityIdentifier("storage-refresh-retry")
        supportLink
    }

    private var supportLink: some View {
        Link(destination: AppLinks.support) {
            Label("サポートを見る", systemImage: "questionmark.circle")
        }
        .buttonStyle(PomoGemSecondaryButtonStyle())
    }

    /// P0-2 / device-01. The `.cloudLineageUnavailable` screen. It leads with
    /// what THIS build can actually do, in order of how much each one changes:
    ///
    /// 1. keep using this iPhone's records offline (nothing is deleted);
    /// 2. take iCloud's data back with 「iCloudから再取得」 — the policy-free
    ///    `refreshCloudDatasetWithoutLineage`, behind the read-only pre-flight,
    ///    both sides' counts, the empty-iCloud warning, an export and its own
    ///    unchecked acknowledgement — which is the only way back to sync a
    ///    shipping build has;
    /// 3. retry, support.
    ///
    /// Starting a lineage from this device is rendered only by a build that
    /// publishes `allowsDatasetOverwriteFromDevice`: a stop screen may not
    /// lead with, or even show, a door the running build keeps shut.
    ///
    /// The visual weight follows the same order. The one amber, primary
    /// control is the door that deletes nothing — offline use, or
    /// 「もう一度試す」 when this device has no eligible offline copy — and
    /// both doors that delete a side are secondary: an empty-iCloud warning
    /// that ends 「中止して…」 must not be followed by the brightest control on
    /// the screen doing the opposite.
    @ViewBuilder
    private var cloudLineageDoors: some View {
        doorHeader(StorageTransferLineageCopy.offlineDoorTitle)
        Text(onContinueOffline == nil
             ? StorageTransferLineageCopy.offlineUnavailable
             : StorageTransferLineageCopy.offlineExplanation(
                offersLineageStart: releasePolicy.allowsDatasetOverwriteFromDevice))
            .foregroundStyle(PomoGemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("storage-lineage-offline-explanation")
        if let onContinueOffline {
            // The EXISTING offline continuation, with no second implementation:
            // the same action and the same identifier the other screens use.
            Button("端末のデータでオフライン利用", action: onContinueOffline)
                .buttonStyle(PomoGemPrimaryButtonStyle())
                .accessibilityIdentifier("cloud-offline-continue")
        }

        if onRefreshWithoutLineage != nil {
            doorHeader(StorageTransferLineageCopy.refreshDoorTitle)
            Text(StorageTransferLineageCopy.refreshExplanation)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("storage-lineage-refresh-explanation")
            // review-1-1 / review-2-2. Both counted sides, before any consent
            // is possible: 「no control record」 is not 「no records」.
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
            if StorageTransferRefreshCopy.cloudSideIsEmpty(cloudPreview) {
                Text(StorageTransferRefreshCopy.cloudSideEmpty(device: devicePreview))
                    .foregroundStyle(PomoGemTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("storage-lineage-refresh-empty-cloud")
            }
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
            Button(StorageTransferRefreshCopy.confirmTitle, role: .destructive) {
                // Never acts on tap. It opens 「最後の確認」, whose own
                // acknowledgement starts unchecked on every presentation.
                presentsLineageRefreshConfirmation = true
            }
            .buttonStyle(PomoGemSecondaryButtonStyle())
            // S14: nobody is asked to discard this device's side on the
            // strength of an iCloud read that never happened.
            .disabled(cloudPreview == nil)
            .accessibilityIdentifier("storage-lineage-refresh")
        }

        if releasePolicy.allowsDatasetOverwriteFromDevice {
            doorHeader(StorageTransferLineageCopy.startDoorTitle)
            Text(StorageTransferLineageCopy.startExplanation)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("storage-lineage-start-explanation")
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
            .buttonStyle(PomoGemSecondaryButtonStyle())
            .disabled(!canStartCloudLineage)
            .accessibilityIdentifier("storage-lineage-start")
        }

        // review-1-3 / review-2-1. Before this branch existed the same stop
        // reason fell through to `.blocked`, which always carries 「もう一度試す」.
        // Without it a device whose offline copy is ineligible has no way to
        // re-attempt inside the app — and then it is the primary control.
        let retry = Button("もう一度試す", action: onRetry)
            .accessibilityIdentifier("storage-lineage-retry")
        if onContinueOffline == nil {
            retry.buttonStyle(PomoGemPrimaryButtonStyle())
        } else {
            retry.buttonStyle(PomoGemSecondaryButtonStyle())
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

    /// Both sides of this screen, rendered by the same functions as the
    /// Settings comparison so the two surfaces cannot disagree about one
    /// dataset. The iCloud row never prints a 「最終」 date here: there is no
    /// control record, so a lineage row would imply one that does not exist.
    private var lineageComparison: String {
        if cloudPreviewFailed { return StorageTransferOverwriteCopy.comparisonUnavailable }
        guard let cloudPreview else { return StorageTransferOverwriteCopy.comparisonReading }
        return StorageTransferOverwriteCopy.side("このiPhone", preview: devicePreview) + "\n"
            + StorageTransferOverwriteCopy.cloudSideWithoutLineage(preview: cloudPreview)
    }

    /// 「最後の確認」 for 「iCloudから再取得」 on this screen: the SAME view the
    /// Settings door presents, so the dataset-loss paragraph, the counted
    /// comparison, the empty-iCloud warning and the acknowledgement are one
    /// text on both surfaces.
    ///
    /// transfer-07. The switch moves to a new storage namespace and so resets
    /// the Screen Time selection, unimported usage and black gems. No Screen
    /// Time owner is mounted on the launch host, so whether the feature is in
    /// use cannot be read here: the sheet always carries the conditional
    /// sentence, before the acknowledgement.
    private var lineageRefreshConfirmationSheet: some View {
        StorageTransferDatasetConfirmationView(
            direction: .refreshFromCloud,
            preview: cloudPreview.map {
                StorageTransferDatasetPreviewSummary(cloud: $0, device: devicePreview,
                                                     hasCloudLineage: false)
            },
            screenTimeDisclosure: StorageTransferScreenTimeCopy.switchResetsIfInUse
        ) {
            presentsLineageRefreshConfirmation = false
            onRefreshWithoutLineage?()
        }
        .dynamicTypeSize(dynamicTypeSize)
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

    /// A heading for VoiceOver's rotor as well as for the eye: at AX5 these
    /// screens are many pages long, and each door section must be reachable
    /// without swiping through every paragraph of the one before it.
    private func doorHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }

    /// S14. The destructive door is closed until the iCloud side has actually
    /// been enumerated, and while the feature is unpublished. The device side
    /// only degrades the comparison: failing to read this iPhone is not a
    /// reason to refuse to describe what would be destroyed on the server.
    private var canRequestOverwrite: Bool {
        releasePolicy.allowsDatasetOverwriteFromDevice && cloudPreview != nil
    }

    /// What each side of `.datasetRefresh` holds, stated once above both
    /// doors. transfer-03: the host reads this iPhone in every build now, so
    /// the device row is a counted fact — or, after a look that actually
    /// failed, 「確認できませんでした」. Published together with the iCloud side.
    private var datasetComparison: String {
        if cloudPreviewFailed { return StorageTransferOverwriteCopy.comparisonUnavailable }
        guard cloudPreview != nil else { return StorageTransferOverwriteCopy.comparisonReading }
        return StorageTransferOverwriteCopy.side("このiPhone", preview: devicePreview)
            + "\n" + StorageTransferOverwriteCopy.side("iCloud", preview: cloudPreview)
    }

    private var overwriteOtherDeviceEvidence: String {
        guard let cloudPreview else { return StorageTransferOverwriteCopy.otherDevicesUnknown }
        return StorageTransferOverwriteCopy.otherDevices(cloudPreview.otherDeviceIDs)
    }

    /// transfer-04. On the screen, the explanation also says WHEN to use the
    /// control. Every screen that shows it carries 「もう一度試す」, and the
    /// verify-step mismatch (`cloudCopyStillPending`) asks the user to retry
    /// first; this is the way out when retrying does not help. The alert keeps
    /// the plain explanation: by then the user has already chosen to cancel.
    private var localTransferCancellationCaption: String {
        "「もう一度試す」で先へ進めない場合は、ここで取り消せます。" + localTransferCancellationExplanation
    }

    private var localTransferCancellationExplanation: String {
        if retainsTransferCopyOnCancellation {
            return "元の保存先とiCloudの記録を残して、取り込みを取り消せます。途中までのコピーも保護のため端末に保持します。取り消した後はアプリを終了して開き直し、改めて切り替えを開始してください。"
        }
        return "置き換えが始まる前なので、この端末の切り替えを取り消して元の保存先へ戻れます。取り消した後はアプリを終了して開き直してください。"
    }

    /// launch-03 / product-01. The first frame of every new install used to be
    /// this generic status layout with a drive symbol, which read like a
    /// system error. The brand and one sentence of what the app does come
    /// first; the storage question follows.
    private var storageChoiceHeader: some View {
        VStack(spacing: 12) {
            // Branding, not content: capped so AX5 does not wrap the name.
            PomoGemLogo()
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            Text("集中した時間が、粒になって瓶にたまっていきます。", tableName: "Launch",
                 comment: "First-run storage choice: the app's one-line promise under the logo")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PomoGemTheme.amber)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("storage-choice.value")
        }
    }

    /// One storage option. Both options are drawn by this one function so
    /// they cannot drift apart in weight: neither is filled, neither is first
    /// by style, and each carries exactly one line.
    private func storageChoiceButton(
        symbol: String,
        title: String,
        detail: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        // At accessibility sizes the text needs the card's whole width: the
        // symbol and chevron are decoration, and beside AX5 text they left a
        // column a few characters wide.
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        return Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                if !isAccessibilitySize {
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(PomoGemTheme.amber)
                        .frame(width: 28)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(PomoGemTheme.text)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if !isAccessibilitySize {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(PomoGemTheme.muted)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(PomoGemTheme.glassEdge.opacity(0.22), lineWidth: 1)
            }
        }
        .buttonStyle(PomoGemRowButtonStyle(cornerRadius: 16))
        // The exact label is the one the real-device tests and the review
        // notes name; the line under it is what choosing it does.
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .accessibilityIdentifier(identifier)
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
            // A neutral question: 「iCloudを有効にしますか？」 framed the
            // local-only option as the "no" answer to a default.
            String(localized: "記録の保存先を選んでください", table: "Launch",
                   comment: "First-run storage choice: screen title")
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
            String(localized: "どちらを選んでも、タイマーと瓶は同じように使えます。", table: "Launch",
                   comment: "First-run storage choice: one-sentence message under the title")
        case let .preparing(message), let .blocked(message, _), let .failed(message),
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
/// launch-03 / launch-04. The shipping first-run storage choice with a call
/// recorder in place of the host: no selection is recorded, no account is
/// resolved and no container exists, so a test can open and cancel both
/// confirmations and read what each one commits to.
struct FirstRunStorageChoiceUITestFixtureView: View {
    @State private var cloudCalls = 0
    @State private var localCalls = 0

    var body: some View {
        PersistenceLaunchStatusView(
            state: .choosingStorage,
            onRetry: {}, onRetryOnline: {}, canRetryOnline: false,
            onChooseCloud: { cloudCalls += 1 },
            onChooseLocalOnly: { localCalls += 1 },
            onRecoverTransfer: {}, onCancelTransfer: {}, onRefreshDataset: {},
            onCancelLocalTransfer: nil, retainsTransferCopyOnCancellation: false,
            onContinueOffline: nil)
            .safeAreaInset(edge: .bottom) {
                VStack {
                    Text(verbatim: "calls=0;choice=none;starting=false")
                        .accessibilityIdentifier("storage-switch.fixture-state")
                    Text(verbatim: "cloud=\(cloudCalls);local=\(localCalls)")
                        .accessibilityIdentifier("storage-choice.fixture-state")
                }
                .font(.caption)
                // Test plumbing, not the screen under test: keep it from
                // covering the AX5 layout being measured.
                .dynamicTypeSize(.large)
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
    /// and the device -> iCloud door is present, DISABLED and states only its
    /// reason because `StorageTransferReleasePolicy.standard` still publishes
    /// nothing. The offline copy is eligible, so the offline door is there too.
    case choice
    /// transfer-03, the shipping `.datasetRefresh` whose iCloud side holds
    /// none of the user's records: 「iCloudから再取得」 must say so, with this
    /// iPhone's counts, before its acknowledgement can arm it.
    case refreshEmptyCloud
    /// The published screen with two witnessed other devices.
    case otherDevices
    /// The published screen whose server read failed: nobody may authorize
    /// deleting contents the app never enumerated, so the door stays closed.
    case previewFailed
    /// The dataset-refresh read failed. Explanation, no destructive
    /// affordance of any kind.
    case blocked
    /// transfer-06. The same generic screen from any other producer: it must
    /// not inherit the refresh caption.
    case blockedGeneric
    /// A durable device -> iCloud replacement past the point of no return.
    case inProgress
    /// transfer-04. A planned continuation of 「iCloudから再取得」 while the
    /// mirror is received: progress copy, not 「中断」.
    case refreshInProgress
    /// transfer-04. The relaunch after the mirror was verified: the next
    /// launch completes the transfer, and the screen says how to relaunch.
    case relaunchFinal
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
    /// device-01, the shipping build on the account whose iCloud side holds
    /// none of the user's records — app data deleted from iOS Settings. The
    /// way back (「iCloudから再取得」) must say before any consent that it would
    /// leave this iPhone with nothing.
    case lineageUnavailableEmptyCloud
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
             .lineageUnavailableUnreadable, .lineageUnavailableEmptyCloud, .environmentMismatch,
             .localLedgerMissingExplain: true
        case .choice, .refreshEmptyCloud, .otherDevices, .previewFailed, .blocked, .blockedGeneric,
             .inProgress, .refreshInProgress, .relaunchFinal, .remoteResumeClosed, .remoteResumeOpen: false
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
    @State private var lineageRefreshCalls = 0

    var body: some View {
        PersistenceLaunchStatusView(
            state: state,
            onRetry: {}, onRetryOnline: {}, canRetryOnline: true,
            onChooseCloud: {}, onChooseLocalOnly: nil,
            onRecoverTransfer: { recoverCalls += 1 }, onCancelTransfer: {},
            onRefreshDataset: { refreshCalls += 1 },
            onOverwriteDataset: { overwriteCalls += 1 },
            onStartCloudLineage: offersLineageStart ? { lineageCalls += 1 } : nil,
            onRefreshWithoutLineage: offersLineageStart ? { lineageRefreshCalls += 1 } : nil,
            onExportDeviceData: offersExport ? { exportCalls += 1 } : nil,
            onRetryCloudPreview: offersPreviewRetry ? { previewRetries += 1 } : nil,
            cloudPreview: cloudPreview,
            devicePreview: devicePreview,
            cloudPreviewFailed: cloudPreviewFailed,
            transferProgress: transferProgress,
            relaunchCompletesTransfer: scenario == .relaunchFinal,
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
                        Text(verbatim: "lineage=\(lineageCalls);offline=\(offlineCalls);refresh=\(lineageRefreshCalls)")
                            .accessibilityIdentifier("storage-lineage.fixture-state")
                    }
                    // PLAN Step 6 asks for the RAW and the FILTERED witness
                    // count, so a reviewer can see that the ignore list moved a
                    // writer rather than that a writer was absent.
                    Text(verbatim: "others=\(cloudPreview?.otherDeviceIDs ?? -1);ignored=\(cloudPreview?.ignoredWriterIDs ?? -1)")
                        .accessibilityIdentifier("storage-overwrite.writer-fixture-state")
                }
                .font(.caption)
                // The recorder is test plumbing, not the screen under test: at
                // AX5 it would otherwise cover half the scroll view the AX5
                // tests are measuring.
                .dynamicTypeSize(.large)
            }
    }

    /// A failed read is offered a re-read; a successful or absent one is not.
    private var offersPreviewRetry: Bool {
        scenario == .previewFailed || scenario == .lineageUnavailableUnreadable
    }

    /// The host passes nil when the action cannot run at all. Only the lineage
    /// screen ever has it, and nothing else in this fixture may receive it.
    private var offersLineageStart: Bool {
        isLineageScreen
    }

    private var isLineageScreen: Bool {
        switch scenario {
        case .lineageUnavailable, .lineageUnavailableEnabled, .lineageUnavailableClosed,
             .lineageUnavailableUnreadable, .lineageUnavailableEmptyCloud: true
        default: false
        }
    }

    /// Eligibility for the offline continuation is a property of the device's
    /// verified local copy, not of the stop reason, so both shapes appear.
    private var offersOffline: Bool {
        scenario == .lineageUnavailable || scenario == .lineageUnavailableEmptyCloud
            || scenario == .environmentMismatch || scenario == .choice
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
            // The one route whose retry can reach the refresh choice.
            .blocked(StorageTransferLineageCopy.refreshScreenUnavailable, retryOffersDatasetChoice: true)
        case .blockedGeneric:
            // transfer-06. Any other producer, e.g. an account mismatch.
            .blocked(AppleAccountBoundaryResolutionError.blocked(.accountMismatch).localizedDescription)
        case .inProgress, .refreshInProgress:
            .preparing(StorageTransferProgressCopy.continuing)
        case .relaunchFinal:
            .relaunchRequired(StorageTransferRuntimeError.relaunchRequired.localizedDescription)
        case .remoteResumeClosed, .remoteResumeOpen:
            .remoteRecovery(StorageTransferRuntimeError.remoteRecoveryRequired.localizedDescription,
                            canCancel: true)
        case .choice, .refreshEmptyCloud, .otherDevices, .previewFailed:
            .datasetRefresh(StorageTransferRuntimeError.datasetRefreshRequired.localizedDescription,
                            claimsReplacement: true)
        case .lineageUnavailable, .lineageUnavailableEnabled, .lineageUnavailableClosed,
             .lineageUnavailableUnreadable, .lineageUnavailableEmptyCloud:
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
        scenario == .choice || scenario == .refreshEmptyCloud || scenario == .otherDevices
            || scenario == .previewFailed || isLineageScreen
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
        case .choice, .refreshEmptyCloud, .blocked, .blockedGeneric, .inProgress, .refreshInProgress,
             .relaunchFinal, .remoteResumeClosed, .lineageUnavailable,
             .lineageUnavailableClosed, .lineageUnavailableEmptyCloud, .environmentMismatch,
             .localLedgerMissingExplain:
            .standard
        }
    }

    private var cloudPreview: StorageTransferCloudPreview? {
        switch scenario {
        case .choice:
            Self.preview(subjects: 9, sessions: 312, stones: 28,
                         latest: Self.date(2026, 9, 18), otherDeviceIDs: 0, ignoredWriterIDs: 1)
        case .refreshEmptyCloud:
            // Only what every onboarded device mirrors: preset themes.
            Self.preview(subjects: 5, sessions: 0, stones: 0,
                         latest: Self.date(2026, 9, 23), otherDeviceIDs: 0)
        case .otherDevices:
            Self.preview(subjects: 9, sessions: 312, stones: 28,
                         latest: Self.date(2026, 9, 18), otherDeviceIDs: 2)
        case .previewFailed:
            // The re-read succeeds. Nobody may authorize deleting contents the
            // app never enumerated, so this is the ONLY way the door opens.
            // It witnesses no other writer, so the published screen's
            // absence-of-evidence wording is exercised here too.
            previewRetries == 0 ? nil
                : Self.preview(subjects: 9, sessions: 312, stones: 28,
                               latest: Self.date(2026, 9, 18), otherDeviceIDs: 0)
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
        case .lineageUnavailableEmptyCloud:
            // Only what every onboarded device mirrors: preset themes.
            Self.preview(subjects: 5, sessions: 0, stones: 0,
                         latest: Self.date(2026, 9, 23), otherDeviceIDs: 0)
        case .blocked, .blockedGeneric, .inProgress, .refreshInProgress, .relaunchFinal,
             .remoteResumeClosed, .remoteResumeOpen,
             .environmentMismatch, .localLedgerMissingExplain:
            // There is nothing to enumerate on these screens, and none of them
            // carries a control that a pre-flight could gate.
            nil
        }
    }

    private var devicePreview: StorageTransferCloudPreview? {
        switch scenario {
        case .lineageUnavailableUnreadable:
            // Published together with the iCloud side, never ahead of it.
            previewRetries == 0 ? nil
                : Self.preview(subjects: 12, sessions: 480, stones: 36,
                               latest: Self.date(2026, 9, 20), otherDeviceIDs: 0)
        case .choice, .refreshEmptyCloud, .otherDevices, .previewFailed, .lineageUnavailable,
             .lineageUnavailableEnabled, .lineageUnavailableClosed, .lineageUnavailableEmptyCloud:
            // device-01 / transfer-03: both screens read this iPhone in every
            // build, because their 「iCloudから再取得」 deletes this side.
            Self.preview(subjects: 12, sessions: 480, stones: 36,
                         latest: Self.date(2026, 9, 20), otherDeviceIDs: 0)
        case .blocked, .blockedGeneric, .inProgress, .refreshInProgress, .relaunchFinal,
             .remoteResumeClosed, .remoteResumeOpen,
             .environmentMismatch, .localLedgerMissingExplain:
            nil
        }
    }

    private var transferProgress: StorageTransferProgress? {
        switch scenario {
        case .inProgress:
            StorageTransferProgress(choice: .overwriteCloudFromDevice, phase: .preparingDestination)
        case .refreshInProgress:
            StorageTransferProgress(choice: .enableCloudKeepingCloud, phase: .preparingDestination)
        default:
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
