import Combine
import CoreData
import Foundation
import SwiftData
import SwiftUI
import UIKit

/// One presentation and mutation boundary for every interactive Prefs
/// consumer. The extra row is an overflow sentinel; callers deliberately get
/// no resolved state when the physical-row or stamp contract cannot be proven.
enum PrefsConsumerPolicy {
    static var queryLimit: Int { PrefsSyncPolicy.maximumPhysicalRows + 1 }

    static func descriptor() -> FetchDescriptor<Prefs> {
        var descriptor = FetchDescriptor<Prefs>(sortBy: [
            SortDescriptor(\Prefs.syncRecordID)
        ])
        descriptor.fetchLimit = queryLimit
        return descriptor
    }

    static func currentEpochID(
        from markers: [ActivityResetSnapshot]
    ) -> UUID? {
        ActivityResetPolicy.currentEpochID(from: markers)
    }

    static func resolvedState(
        in values: [Prefs],
        markers: [ActivityResetSnapshot],
        currentDay: String = FairnessPolicy.deviceDayKey(for: .now)
    ) -> PrefsSyncPolicy.ResolvedState? {
        try? PrefsSyncPolicy.resolvedState(
            in: values,
            currentEpochID: currentEpochID(from: markers),
            currentDay: currentDay
        )
    }

    static func resolvedSensoryState(
        in values: [Prefs]
    ) -> PrefsSyncPolicy.ResolvedSensoryState {
        PrefsSyncPolicy.resolvedSensoryState(in: values)
    }

    static func rareRewardMode(
        from state: PrefsSyncPolicy.ResolvedState?
    ) -> RareRewardMode {
        guard let state, state.rareRewardModeUpdatedAt != nil else {
            return .off
        }
        return RareRewardMode.resolved(state.rareRewardModeRawValue)
    }

    static func hasExplicitRareRewardSelection(
        in state: PrefsSyncPolicy.ResolvedState?
    ) -> Bool {
        state?.rareRewardModeUpdatedAt != nil
    }

    @MainActor
    @discardableResult
    static func mutate(
        _ group: PrefsSyncPolicy.Group,
        context: ModelContext,
        markers: [ActivityResetSnapshot],
        update: (Prefs) -> Void
    ) throws -> Prefs {
        try PrefsSyncPolicy.mutate(
            group,
            context: context,
            currentEpochID: currentEpochID(from: markers),
            update: update
        )
    }

    @MainActor
    @discardableResult
    static func ensureWriterRow(
        context: ModelContext,
        markers: [ActivityResetSnapshot]
    ) throws -> Prefs {
        try PrefsSyncPolicy.ensureWriterRow(
            context: context,
            currentEpochID: currentEpochID(from: markers)
        )
    }

    /// Includes identity, every field-group stamp, activity-local counters,
    /// payloads and monotone lifecycle flags so an in-place CloudKit import
    /// cannot escape RootView's bounded change sentinel.
    static func fingerprint(for value: Prefs) -> String {
        [
            value.id.uuidString,
            value.syncRecordID.uuidString,
            value.settingsWriterID,
            value.activityEpochID?.uuidString ?? "legacy",
            stamp(value.soundRevision, value.soundMutationID),
            stamp(value.hapticsRevision, value.hapticsMutationID),
            stamp(
                value.timerCompletionSoundRevision,
                value.timerCompletionSoundMutationID
            ),
            stamp(
                value.timerCompletionHapticRevision,
                value.timerCompletionHapticMutationID
            ),
            stamp(value.rareRewardRevision, value.rareRewardMutationID),
            stamp(value.reminderEnabledRevision, value.reminderEnabledMutationID),
            stamp(value.reminderTimeRevision, value.reminderTimeMutationID),
            stamp(value.shareIncludesManualRevision, value.shareIncludesManualMutationID),
            stamp(value.externalThemeRevision, value.externalThemeMutationID),
            stamp(value.keepScreenAwakeRevision, value.keepScreenAwakeMutationID),
            stamp(value.preferredFocusMinutesRevision, value.preferredFocusMinutesMutationID),
            stamp(value.timerDisplayModeRevision, value.timerDisplayModeMutationID),
            stamp(value.usagePurposeRevision, value.usagePurposeMutationID),
            value.manualDayKey,
            String(value.manualUsedToday),
            String(value.soundOn),
            String(value.hapticsOn),
            value.timerCompletionSoundRawValue,
            value.timerCompletionHapticRawValue,
            value.rareRewardModeRawValue,
            String(value.rareRewardModeUpdatedAt?.timeIntervalSince1970 ?? -1),
            String(value.reminderEnabled),
            String(value.reminderHour),
            String(value.reminderMinute),
            String(value.shareIncludesManual),
            String(value.showsThemeNameExternally),
            String(value.isPro),
            String(value.keepScreenAwake),
            String(value.preferredFocusMinutes),
            value.timerDisplayModeRawValue,
            String(value.hasCompletedOnboarding),
            value.usagePurposeRawValue,
            String(value.usagePurposeUpdatedAt?.timeIntervalSince1970 ?? -1),
            String(value.hasEverImportedBedrock),
            String(value.hasCompletedInitialSubjectSeed)
        ].joined(separator: "|")
    }

    private static func stamp(_ revision: Int, _ mutationID: UUID?) -> String {
        "\(revision):\(mutationID?.uuidString ?? "legacy")"
    }
}

enum SyncMaintenanceLaunchPolicy {
    static let foregroundIdleGrace: Duration = .seconds(60)
    static let recurringVerificationInterval: Duration = .seconds(15 * 60)

    static func requiresInitialVerificationSweep(
        for persistenceMode: PersistenceLaunchMode
    ) -> Bool {
        persistenceMode == .cloudKit
    }

    static func permitsForegroundDrain(on selectedTab: AppTab) -> Bool {
        // Once the one-time interaction grace has elapsed, checkpointed
        // maintenance must make progress regardless of which tab stays open.
        _ = selectedTab
        return true
    }

    static func shouldScheduleRecurringVerification(
        for persistenceMode: PersistenceLaunchMode,
        sceneIsActive: Bool
    ) -> Bool {
        persistenceMode == .cloudKit && sceneIsActive
    }

    static func shouldResetForegroundGrace(after phase: ScenePhase) -> Bool {
        phase == .background
    }

    static func shouldRearmForegroundWork(after phase: ScenePhase) -> Bool {
        phase == .active
    }
}

/// Pure routing boundary for Home's process-local repair hint. CloudKit has
/// its own import invalidation and verification flow; only a shipping
/// local-only source store needs this hint translated into durable work.
enum LocalSessionMaintenanceRoutingPolicy {
    static func maintenanceKind(
        requestIsActive: Bool,
        persistenceMode: PersistenceLaunchMode
    ) -> SyncMaintenanceKind? {
        guard requestIsActive, persistenceMode == .localOnly else { return nil }
        return .sessions
    }
}

/// Consumes Home's latched process request only after the first frame. The
/// separate gate makes the onChange-versus-first-frame ordering race explicit:
/// an early observation remains available for the first-frame catch-up, while
/// a later duplicate cannot advance the durable generation twice.
struct LocalSessionMaintenanceRequestGate {
    private(set) var hasConsumedProcessRequest = false

    mutating func consume(
        requestIsActive: Bool,
        firstFrameIsPresented: Bool,
        persistenceMode: PersistenceLaunchMode
    ) -> SyncMaintenanceKind? {
        guard requestIsActive,
              firstFrameIsPresented,
              !hasConsumedProcessRequest else { return nil }
        hasConsumedProcessRequest = true
        return LocalSessionMaintenanceRoutingPolicy.maintenanceKind(
            requestIsActive: true,
            persistenceMode: persistenceMode
        )
    }
}

enum SyncStoreChangeNotificationAdapter {
    static func modelContextDidSaveSignal(
        _ notification: Notification,
        mainContextIdentifier: ObjectIdentifier
    ) -> SyncStoreChangeSignal {
        let sourceContext = notification.object as? ModelContext
        let origin: SyncStoreChangeContextOrigin
        if let sourceContext {
            origin = ObjectIdentifier(sourceContext) == mainContextIdentifier
                ? .mainContext
                : .otherContext
        } else {
            origin = .unavailable
        }

        let author: String?
        if #available(iOS 18.0, *) {
            author = sourceContext?.author
        } else {
            author = nil
        }

        let inserted = identifiers(
            for: .insertedIdentifiers,
            in: notification.userInfo
        )
        let updated = identifiers(
            for: .updatedIdentifiers,
            in: notification.userInfo
        )
        let deleted = identifiers(
            for: .deletedIdentifiers,
            in: notification.userInfo
        )
        let invalidated = identifiers(
            for: .invalidatedAllIdentifiers,
            in: notification.userInfo
        )
        let changedNames = Set((inserted + updated + deleted).map(\.entityName))
        let invalidatedAll = !invalidated.isEmpty
            || booleanValue(
                for: .invalidatedAllIdentifiers,
                in: notification.userInfo
            )
        return SyncStoreChangeSignal(
            source: .modelContextDidSave,
            contextOrigin: origin,
            author: author,
            changedEntityNames: changedNames,
            invalidatedAllIdentifiers: invalidatedAll
        )
    }

    static func persistentStoreRemoteChangeSignal(
        _ notification: Notification
    ) -> SyncStoreChangeSignal {
        let userInfoURL = notification.userInfo?[NSPersistentStoreURLKey]
            as? URL
        let objectURL = (notification.object as? NSPersistentStore)?.url
        return SyncStoreChangeSignal(
            source: .persistentStoreRemoteChange,
            persistentStoreURL: userInfoURL ?? objectURL
        )
    }

    private static func value(
        for key: ModelContext.NotificationKey,
        in userInfo: [AnyHashable: Any]?
    ) -> Any? {
        userInfo?[key] ?? userInfo?[key.rawValue]
    }

    private static func identifiers(
        for key: ModelContext.NotificationKey,
        in userInfo: [AnyHashable: Any]?
    ) -> [PersistentIdentifier] {
        let rawValue = value(for: key, in: userInfo)
        if let values = rawValue as? Set<PersistentIdentifier> {
            return Array(values)
        }
        if let values = rawValue as? [PersistentIdentifier] {
            return values
        }
        if let value = rawValue as? PersistentIdentifier {
            return [value]
        }
        return []
    }

    private static func booleanValue(
        for key: ModelContext.NotificationKey,
        in userInfo: [AnyHashable: Any]?
    ) -> Bool {
        (value(for: key, in: userInfo) as? Bool) == true
    }
}

struct RootView: View {
    let persistenceStartupError: String?
    let persistenceMode: PersistenceLaunchMode
    let persistenceSafetyNotice: String?
    let rebuildPersistenceAfterCompleteDeletion: @MainActor @Sendable () async -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AccountScopedLocalState.defaultsKey(base: "onboarding.completed"))
    private var didCompleteOnboarding = false
    @AppStorage(AccountScopedLocalState.defaultsKey(base: UsagePurpose.storageKey))
    private var usagePurposeRawValue = UsagePurpose.study.rawValue
    @AppStorage(AccountScopedLocalState.defaultsKey(base: "notifications.wrapped"))
    private var wrappedNotifications = false
    @AppStorage(AccountScopedLocalState.defaultsKey(base: "activity.last-applied-reset-epoch")) private var lastAppliedResetEpoch = ""
    @State private var router = AppRouter()
    @State private var isBootstrapped = false
    @State private var isFinishingOnboarding = false
    @State private var bootstrapError: String?
    @State private var bootstrapAttempt = 0
    @State private var lastPassiveNotificationErrorFingerprint: String?
    @State private var dismissedCloudFocusOfferID: UUID?
    @State private var didReportCloudFocusIntegrityIssue = false
    @State private var isReconcilingActivityData = false
    @State private var shouldReconcileActivityDataAgain = false
    @State private var launchHasSyncedUsageEvidence = false
    @State private var isFirstFramePresented = false
    @State private var didScheduleDeferredLaunchMaintenance = false
    @State private var deferredResetCleanupPending = false
    @State private var deferredResetCleanupPreservesFocus = false
    @State private var hasLeftActiveStateAfterFirstFrame = false
    @State private var pendingLaunchMaintenanceReasons = Set<
        BoundedLaunchPreparation.DeferredMaintenanceReason
    >()
    @State private var completeDeletion = CompleteDataDeletionController()
    @State private var isDataDeletionQuiesced = false
    @State private var maintenance = SyncMaintenanceCoordinator()
    @State private var maintenanceDrainTask: Task<Void, Never>?
    @State private var maintenanceDrainToken: UUID?
    @State private var maintenanceIdleGraceTask: Task<Void, Never>?
    @State private var maintenanceIdleGraceToken: UUID?
    @State private var maintenanceGraceHasElapsed = false
    @State private var recurringVerificationTask: Task<Void, Never>?
    @State private var recurringVerificationToken: UUID?
    @State private var localSessionMaintenanceRequestGate =
        LocalSessionMaintenanceRequestGate()
    @State private var projectionVerificationTicket:
        AggregateProjectionVerificationTicket?
    @State private var aggregateProjectionPresentation:
        AggregateProjectionPresentationContext
    @State private var storeChangeDebouncer = SyncStoreChangeDebouncer()
    @State private var storeChangeDebounceTask: Task<Void, Never>?
    @State private var storeChangeDebounceToken: UUID?
    @State private var deferredSourceInvalidationDuringWorker = false
    @State private var activePersistenceSafetyNotice: String?
    @Query private var preferences: [Prefs]
    @Query private var storedStudySessions: [StudySession]
    @Query private var storedAchievementStones: [AchievementStone]
    @Query private var storedSyncedFocusTimers: [SyncedFocusTimer]
    @Query private var storedFocusDeviceClaims: [FocusTimerDeviceClaim]
    @Query private var storedAggregates: [AggregatePebble]
    @Query private var storedStrata: [Stratum]
    @Query private var storedBedrocks: [Bedrock]
    @Query private var storedGachaStates: [GachaState]
    @Query private var activityResetMarkers: [ActivityResetMarker]

    /// RootView only needs small change sentinels and onboarding evidence. The
    /// feature screens perform their own scoped reads; retaining an entire
    /// multi-decade history here made every launch allocate hundreds of
    /// thousands of model objects before the first bottle frame.
    init(
        persistenceStartupError: String?,
        persistenceMode: PersistenceLaunchMode = .inMemoryPreview,
        persistenceSafetyNotice: String? = nil,
        rebuildPersistenceAfterCompleteDeletion: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.persistenceStartupError = persistenceStartupError
        self.persistenceMode = persistenceMode
        self.persistenceSafetyNotice = persistenceSafetyNotice
        self.rebuildPersistenceAfterCompleteDeletion = rebuildPersistenceAfterCompleteDeletion
        _activePersistenceSafetyNotice = State(initialValue: persistenceSafetyNotice)
        _aggregateProjectionPresentation = State(
            initialValue: .initial(for: persistenceMode)
        )

        _preferences = Query(PrefsConsumerPolicy.descriptor())

        _storedStudySessions = Query(
            HomeProjectionPolicy.sessionChangeSentinelDescriptor(limit: 32)
        )

        var achievementSentinel = FetchDescriptor<AchievementStone>(
            sortBy: [SortDescriptor(\AchievementStone.achievedAt, order: .reverse)]
        )
        achievementSentinel.fetchLimit = 32
        _storedAchievementStones = Query(achievementSentinel)

        var timerSentinel = FetchDescriptor<SyncedFocusTimer>(
            sortBy: [SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse)]
        )
        timerSentinel.fetchLimit = 64
        _storedSyncedFocusTimers = Query(timerSentinel)

        var claimSentinel = FetchDescriptor<FocusTimerDeviceClaim>(
            sortBy: [SortDescriptor(\FocusTimerDeviceClaim.claimedAt, order: .reverse)]
        )
        claimSentinel.fetchLimit = 96
        _storedFocusDeviceClaims = Query(claimSentinel)

        var aggregateSentinel = FetchDescriptor<AggregatePebble>(
            sortBy: [SortDescriptor(\AggregatePebble.createdAt, order: .reverse)]
        )
        aggregateSentinel.fetchLimit = 96
        _storedAggregates = Query(aggregateSentinel)

        var legacyStratumSentinel = FetchDescriptor<Stratum>(
            sortBy: [SortDescriptor(\Stratum.bakedAt, order: .reverse)]
        )
        legacyStratumSentinel.fetchLimit = 16
        _storedStrata = Query(legacyStratumSentinel)

        var bedrockSentinel = FetchDescriptor<Bedrock>(
            sortBy: [SortDescriptor(\Bedrock.importedAt, order: .reverse)]
        )
        bedrockSentinel.fetchLimit = 2
        _storedBedrocks = Query(bedrockSentinel)

        var gachaSentinel = FetchDescriptor<GachaState>()
        gachaSentinel.fetchLimit = 4
        _storedGachaStates = Query(gachaSentinel)

        // Sequence ordering is independent of wall-clock changes, and the
        // matching store sort exposes the stable winner with a one-row fetch.
        _activityResetMarkers = Query(ActivityResetPolicy.currentMarkerDescriptor())

    }

    private var resetSnapshots: [ActivityResetSnapshot] {
        activityResetMarkers.map(\.policySnapshot)
    }
    private func isCurrentActivity(_ epochID: UUID?) -> Bool {
        ActivityResetPolicy.isCurrent(epochID, markers: resetSnapshots)
    }
    private var studySessions: [StudySession] {
        storedStudySessions.filter {
            isCurrentActivity($0.dataEpochID)
                && StudySessionIntegrityPolicy.isSupported($0)
        }
    }
    private var syncedFocusTimers: [SyncedFocusTimer] {
        storedSyncedFocusTimers.filter { isCurrentActivity($0.dataEpochID) }
    }
    private var focusDeviceClaims: [FocusTimerDeviceClaim] {
        storedFocusDeviceClaims.filter { isCurrentActivity($0.dataEpochID) }
    }
    private var resolvedPreferences: PrefsSyncPolicy.ResolvedState? {
        PrefsConsumerPolicy.resolvedState(
            in: preferences,
            markers: resetSnapshots
        )
    }

    private var blockingError: String? {
        persistenceStartupError ?? bootstrapError
    }

    private var focusSyncFingerprint: [String] {
        let timers = storedSyncedFocusTimers.map {
            "\($0.sessionID.uuidString)-\($0.dataEpochID?.uuidString ?? "legacy")-\($0.statusRaw)-\($0.revision)-\($0.updatedAt.timeIntervalSince1970)"
        }
        let claims = storedFocusDeviceClaims.map {
            "\($0.id.uuidString)-\($0.syncRecordID.uuidString)-\($0.sessionID.uuidString)-\($0.dataEpochID?.uuidString ?? "legacy")-\($0.deviceID)-\($0.sequence)-\($0.releasedAt?.timeIntervalSince1970 ?? -1)"
        }
        return (timers + claims).sorted()
    }

    private var activityAuxiliaryFingerprint: [String] {
        let achievements = storedAchievementStones.map {
            "achievement-\($0.id.uuidString)-\($0.syncRecordID.uuidString)-\($0.dataEpochID?.uuidString ?? "legacy")-\($0.revision)-\($0.deletedAt?.timeIntervalSince1970 ?? -1)-\($0.deletionRevision)-\($0.deletionMutationID?.uuidString ?? "legacy-delete")-\($0.restoredDeletionMutationID?.uuidString ?? "not-restored")-\($0.updatedAt.timeIntervalSince1970)"
        }
        let bedrocks = storedBedrocks.map {
            "bedrock-\($0.dataEpochID?.uuidString ?? "legacy")-\($0.importedAt.timeIntervalSince1970)"
        }
        let gacha = storedGachaStates.map {
            "gacha-\($0.id.uuidString)-\($0.dataEpochID?.uuidString ?? "legacy")-\($0.sinceLastGold)-\($0.rewardCreditGrams)"
        }
        return (achievements + bedrocks + gacha).sorted()
    }

    private var sessionSourceFingerprint: [String] {
        storedStudySessions.map {
            "session-\(StudySessionSyncPolicy.changeToken(for: $0).stableFingerprint)"
        }
        .sorted()
    }

    private var aggregateProjectionFingerprint: [String] {
        storedAggregates.map {
            "aggregate-\(AggregateProjectionChangeFingerprint.value(for: $0))"
        }
        .sorted()
    }

    private var legacyProjectionFingerprint: [String] {
        storedStrata.map {
            "stratum-\($0.id.uuidString)-\($0.dataEpochID?.uuidString ?? "legacy")-\($0.grams)-\($0.sessionIDsJSON)"
        }
        .sorted()
    }

    private var hasSyncedUsageEvidence: Bool {
        (resolvedPreferences?.hasCompletedOnboarding ?? false)
            || !studySessions.isEmpty
            || launchHasSyncedUsageEvidence
    }

    private var shouldShowMain: Bool {
        if LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess,
           ProcessInfo.processInfo.environment[
               LocalPreviewLaunchPolicy.rareRewardOnboardingUITestEnvironmentKey
           ] == "1",
           !(resolvedPreferences?.hasCompletedOnboarding ?? false) {
            return false
        }
        return LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess
            || didCompleteOnboarding
            || launchHasSyncedUsageEvidence
            || hasSyncedUsageEvidence
    }

    private var preferenceSourceFingerprint: [String] {
        preferences.map {
            PrefsConsumerPolicy.fingerprint(for: $0)
        }
        .sorted()
    }

    private var resetGenerationFingerprint: String {
        guard let marker = ActivityResetPolicy.currentMarker(from: resetSnapshots) else {
            return "legacy"
        }
        return [
            marker.epochID.uuidString,
            String(marker.sequence),
            marker.writerDeviceID,
            String(marker.resetAt.timeIntervalSince1970)
        ].joined(separator: "-")
    }

    @MainActor
    private var activeCloudSourceStoreURL: URL? {
        guard persistenceMode == .cloudKit,
              let namespace = AccountScopedLocalState.activeNamespace()
        else { return nil }
        // The shipping topology always places the user-authored CloudKit
        // source store first and the rebuildable local projection store last.
        return PersistenceStoreTopology.shippingPersistentStoreURLs(
            accountNamespace: namespace
        ).first?.standardizedFileURL
    }

    var body: some View {
        // Capture only the identity of the main context. Save notifications are
        // reduced to a Sendable value on their posting executor before UI work
        // is delivered to the main run loop.
        let mainContextIdentifier = ObjectIdentifier(modelContext)
        ZStack {
            NightBackground()

            if let blockingError {
                StartupErrorView(
                    diagnostic: blockingError,
                    canRetry: persistenceStartupError == nil,
                    persistenceMode: persistenceMode,
                    onRetry: retryBootstrap
                )
            } else if !isBootstrapped {
                ProgressView()
                    .tint(PomoGemTheme.amber)
                    .accessibilityLabel("準備中")
                    .accessibilityIdentifier("root.startup.progress")
            } else if shouldShowMain {
                MainNavigationView(
                    router: router,
                    persistenceMode: persistenceMode
                )
                    .transition(.opacity)
                    .accessibilityIdentifier("root.first-frame.ready")
                    .task { await markFirstFramePresented() }
            } else {
                OnboardingView(persistenceMode: persistenceMode) { selectedSubjectNames, wantsNotifications, rareRewardMode in
                    Task {
                        await finishOnboarding(
                            selectedSubjectNames: selectedSubjectNames,
                            wantsNotifications: wantsNotifications,
                            rareRewardMode: rareRewardMode
                        )
                    }
                }
                .transition(.opacity)
                // Onboarding has no NavigationStack accessibility container.
                // Keep the readiness marker on this group so it cannot replace
                // the identifiers of the step heading and navigation buttons.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("root.first-frame.ready")
                .task { await markFirstFramePresented() }
            }

            if let toast = router.toast {
                VStack {
                    Spacer()
                    ToastOverlay(message: toast)
                        .padding(.bottom, 86)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .zIndex(20)
            }

            if let activePersistenceSafetyNotice,
               isBootstrapped,
               !completeDeletion.hasStarted {
                VStack {
                    Label(activePersistenceSafetyNotice, systemImage: "icloud.slash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PomoGemTheme.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityIdentifier("root.persistence-safety-notice")
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .allowsHitTesting(false)
                .zIndex(30)
            }

            if completeDeletion.hasStarted {
                CompleteDataDeletionBlockingView(controller: completeDeletion)
                    .zIndex(100)
            }
        }
        .environment(router)
        .environment(completeDeletion)
        .environment(
            \.aggregateProjectionPresentation,
            aggregateProjectionPresentation
        )
        .task(id: bootstrapAttempt) {
            await bootstrap()
        }
        .task {
            installCompleteDeletionOperation()
        }
        .alert(
            persistenceMode == .localOnly
                ? "保存済みの進行中タイマーがあります"
                : "iCloudに進行中のタイマーがあります",
            isPresented: Binding(
                get: { router.cloudFocusRecoveryOffer != nil },
                set: {
                    if !$0 {
                        dismissedCloudFocusOfferID = router.cloudFocusRecoveryOffer?.id
                        router.cloudFocusRecoveryOffer = nil
                    }
                }
            ),
            presenting: router.cloudFocusRecoveryOffer
        ) { offer in
            Button("この端末で続ける") {
                Task { await adoptCloudFocus(offer) }
            }
            Button("あとで", role: .cancel) {
                dismissedCloudFocusOfferID = offer.id
                router.cloudFocusRecoveryOffer = nil
            }
        } message: { offer in
            let remaining = offer.request.engine.snapshot(at: .now).remainingSeconds
            Text(persistenceMode == .localOnly
                 ? "\(offer.request.subjectSnapshot.name)・残り約\(max(0, (remaining + 59) / 60))分。保存済みの状態から再開すると、このiPhoneが終了通知を担当します。"
                 : "\(offer.request.subjectSnapshot.name)・残り約\(max(0, (remaining + 59) / 60))分。この端末へ引き継ぐと、この端末が終了通知を担当します。元の端末がオフラインまたはロック中の場合は、古い通知が一度届くことがあります。")
        }
        .onChange(of: focusSyncFingerprint) { _, _ in
            guard isFirstFramePresented, !isDataDeletionQuiesced else { return }
            maintenance.enqueue(.focusFairness)
            startMaintenanceDrain()
            Task { await reconcileIncomingActivityData() }
        }
        .onChange(of: sessionSourceFingerprint) { _, _ in
            guard isFirstFramePresented, !isDataDeletionQuiesced else { return }
            // This recent source-only query is the synchronous fallback for a
            // direct UI completion whose notification payload is missing.
            // Older CloudKit imports use the exact source-store remote signal
            // and the recurring verification sweep, so the fallback never
            // sorts the full lifetime table merely to detect a change.
            enqueueSessionDependentVerification()
            Task { await reconcileIncomingActivityData() }
        }
        .onChange(of: activityAuxiliaryFingerprint) { _, _ in
            guard isFirstFramePresented, !isDataDeletionQuiesced else { return }
            // These models may also be written by maintenance. Keep their
            // query observation presentation-only to avoid self-save loops.
            Task { await reconcileIncomingActivityData() }
        }
        .onChange(of: aggregateProjectionFingerprint) { _, _ in
            // Projection saves are UI refresh hints, never source
            // invalidations. Verification is cleared only by the checkpoint
            // ticket after every dependent generation has drained.
            synchronizeAggregateProjectionVerification()
        }
        .onChange(of: legacyProjectionFingerprint) { _, _ in
            synchronizeAggregateProjectionVerification()
        }
        .onChange(of: preferenceSourceFingerprint) { _, _ in
            guard isFirstFramePresented, !isDataDeletionQuiesced else { return }
            maintenance.enqueue(.preferences)
            startMaintenanceDrain()
            // CloudKit may update an existing Prefs row in place, or deliver a
            // duplicate row created offline. Re-run deterministic field-wise
            // read resolution while a focus is still running. Preference-only
            // writes must not rerun the session/achievement launch probe: even
            // a bounded top-N query can require SQLite to sort a multi-decade
            // source table before an unrelated Settings toggle can go idle.
            Task { @MainActor in
                await Task.yield()
                reconcileCloudUserState()
            }
        }
        .onChange(of: resetGenerationFingerprint) { _, _ in
            guard isFirstFramePresented, !isDataDeletionQuiesced else { return }
            maintenance.enqueueResetDependentWork()
            requestAggregateProjectionVerification()
            startMaintenanceDrain()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: ModelContext.didSave,
                object: nil
            )
            .map { notification in
                SyncStoreChangeNotificationAdapter.modelContextDidSaveSignal(
                    notification,
                    mainContextIdentifier: mainContextIdentifier
                )
            }
            .receive(on: RunLoop.main)
        ) { signal in
            handleStoreChangeSignal(signal)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .NSPersistentStoreRemoteChange,
                object: nil
            )
            .map(
                SyncStoreChangeNotificationAdapter
                    .persistentStoreRemoteChangeSignal
            )
            .receive(on: RunLoop.main)
        ) { signal in
            handleStoreChangeSignal(signal)
        }
        .onChange(of: router.selectedTab) { _, selectedTab in
            guard isFirstFramePresented else { return }
            guard SyncMaintenanceLaunchPolicy.permitsForegroundDrain(
                on: selectedTab
            ) else { return }
            if maintenanceGraceHasElapsed {
                startMaintenanceDrain()
            } else {
                scheduleMaintenanceAfterIdleGrace()
            }
        }
        .onChange(
            of: router.localSessionMaintenanceRequestedThisProcess
        ) { _, requestIsActive in
            routeLocalSessionMaintenanceRequest(requestIsActive)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard isFirstFramePresented else { return }
            guard SyncMaintenanceLaunchPolicy.shouldRearmForegroundWork(
                after: newPhase
            ) else {
                if SyncMaintenanceLaunchPolicy.shouldResetForegroundGrace(
                    after: newPhase
                ) {
                    hasLeftActiveStateAfterFirstFrame = true
                    // Every genuine foreground return receives the same
                    // interaction grace as launch. A temporary inactive phase
                    // (Control Center/system sheet) does not reset it.
                    maintenanceGraceHasElapsed = false
                    aggregateProjectionPresentation.invalidate()
                    projectionVerificationTicket = nil
                }
                maintenanceIdleGraceTask?.cancel()
                maintenanceIdleGraceTask = nil
                maintenanceIdleGraceToken = nil
                maintenanceDrainTask?.cancel()
                maintenanceDrainTask = nil
                maintenanceDrainToken = nil
                recurringVerificationTask?.cancel()
                recurringVerificationTask = nil
                recurringVerificationToken = nil
                return
            }
            guard !isDataDeletionQuiesced else { return }
            // System sheets and Control Center may produce inactive→active
            // without a background phase. Always resume existing work and the
            // recurring timer; only the expensive fence/entitlement refresh
            // below is restricted to a genuine background return.
            scheduleMaintenanceAfterIdleGrace()
            scheduleRecurringVerification()
            // The launch host has already checked the fence before mounting
            // this container. Recheck every genuine foreground return so a
            // deletion performed by another device cannot remain unnoticed
            // merely because this launch initially verified successfully.
            guard hasLeftActiveStateAfterFirstFrame else { return }
            hasLeftActiveStateAfterFirstFrame = false
            // Revoke trust and persist the new sweep before any asynchronous
            // account/deletion checks. The sweep itself still waits for this
            // foreground epoch's 60-second interaction grace.
            requestAggregateProjectionVerification()
            Task {
                await verifyMountedDeletionFence()
                guard !isDataDeletionQuiesced, scenePhase == .active else { return }
                await PurchaseManager.shared.refreshEntitlements()
                await NotificationManager.shared.refreshAuthorizationStatus()
                await NotificationManager.shared.clearDeliveredState()
                await offerCloudFocusIfNeeded()
                await refreshPassiveNotifications()
            }
        }
        .onDisappear {
            maintenanceIdleGraceTask?.cancel()
            maintenanceIdleGraceTask = nil
            maintenanceIdleGraceToken = nil
            maintenanceDrainTask?.cancel()
            maintenanceDrainTask = nil
            maintenanceDrainToken = nil
            recurringVerificationTask?.cancel()
            recurringVerificationTask = nil
            recurringVerificationToken = nil
            storeChangeDebounceTask?.cancel()
            storeChangeDebounceTask = nil
            storeChangeDebounceToken = nil
        }
    }

    @MainActor
    private func bootstrap() async {
        guard persistenceStartupError == nil else {
            await FocusActivityManager.shared.reconcileWithDurableSession(nil)
            return
        }
        guard !isBootstrapped else { return }
        bootstrapError = nil

        if #available(iOS 18.0, *) {
            modelContext.author = SyncMaintenanceNotificationPolicy.uiAuthor
        }

        do {
            // The informed-choice UI test must begin before any local focus.
            // Focus recovery lives in UserDefaults rather than the in-memory
            // SwiftData preview and can otherwise leak from an earlier test
            // process, legitimately bypassing the new-user gate as recovery.
            if LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess,
               ProcessInfo.processInfo.environment[
                   LocalPreviewLaunchPolicy.unselectedRareRewardUITestEnvironmentKey
               ] == "1" {
                FocusPersistence.clear()
                FocusPersistence.clearBreak()
                if ProcessInfo.processInfo.environment[
                    LocalPreviewLaunchPolicy.rareRewardOnboardingUITestEnvironmentKey
                ] == "1" {
                    // @AppStorage outlives the in-memory preview. This fixture
                    // intentionally exercises a true first-use decision.
                    didCompleteOnboarding = false
                }
            }
            let localEnvelope = FocusPersistence.load()
            let preparation = try BoundedLaunchPreparation.prepare(
                context: modelContext,
                localFocusEpochID: localEnvelope?.dataEpochID,
                hasLocalFocus: localEnvelope != nil,
                pendingCompletionID: localEnvelope?.pendingCompletion?.sessionID
            )
            launchHasSyncedUsageEvidence = preparation.hasSyncedUsageEvidence
            pendingLaunchMaintenanceReasons = preparation.deferredMaintenanceReasons
            try seedExplicitUITestStateIfNeeded()
            deferredResetCleanupPending = applyLaunchResetLocallyIfNeeded(
                marker: preparation.currentMarker,
                localFocusEpochState: preparation.localFocusEpochState
            )
            deferredResetCleanupPreservesFocus = localEnvelope != nil
                && preparation.localFocusEpochState != .stale
            await restoreBoundedLocalFocusIfNeeded(
                localEnvelope,
                preparation: preparation
            )
            await recoverBreakTimerIfNeeded()

            // `SeedData.bootstrap` deliberately does not run here. The first
            // bottle/onboarding frame depends only on the bounded preparation
            // above. Full deterministic repair starts from the mounted frame's
            // task after SwiftUI has had an opportunity to present it.
            withAnimation(.easeInOut(duration: 0.25)) {
                isBootstrapped = true
            }
        } catch {
            modelContext.rollback()
            await FocusActivityManager.shared.reconcileWithDurableSession(nil)
            bootstrapError = error.localizedDescription
        }
    }

    /// UI tests intentionally bypass onboarding and use a fresh in-memory
    /// store. Since production cold launch no longer runs the full preset
    /// bootstrap, give that explicitly opted-in fixture one deterministic
    /// subject with a one-row existence check. Release and ordinary preview
    /// launches never enter this path.
    @MainActor
    private func seedExplicitUITestStateIfNeeded() throws {
        guard LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess,
              let preset = SeedData.subjects.first
        else { return }

        // Existing UI journeys predate the informed-choice screen and test
        // unrelated flows. Keep their deterministic standard choice explicit;
        // the dedicated opt-in journey sets this environment flag to exercise
        // the real unselected gate.
        if ProcessInfo.processInfo.environment[
            LocalPreviewLaunchPolicy.unselectedRareRewardUITestEnvironmentKey
        ] != "1",
           !PrefsConsumerPolicy.hasExplicitRareRewardSelection(
               in: resolvedPreferences
           ) {
            let changedAt = Date(timeIntervalSince1970: 1_800_000_000)
            try PrefsConsumerPolicy.mutate(
                .rareReward,
                context: modelContext,
                markers: resetSnapshots
            ) {
                $0.rareRewardModeRawValue = RareRewardMode.standard.rawValue
                $0.rareRewardModeUpdatedAt = changedAt
            }
        }

        var descriptor = FetchDescriptor<Subject>(
            sortBy: [SortDescriptor(\Subject.sortOrder)]
        )
        descriptor.fetchLimit = 1
        if try modelContext.fetch(descriptor).isEmpty {
            modelContext.insert(Subject(
                id: preset.id,
                name: preset.name,
                colorHex: preset.colorHex,
                sortOrder: 0
            ))
        }
        if modelContext.hasChanges { try modelContext.save() }
    }

    /// Called by the actual Home/Onboarding subtree rather than the outer root
    /// task. Waiting one display interval prevents a synchronous MainActor
    /// maintenance sweep from racing the first render after `isBootstrapped`.
    @MainActor
    private func markFirstFramePresented() async {
        guard !isFirstFramePresented else { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(24))
        guard !Task.isCancelled, !isFirstFramePresented else { return }
        isFirstFramePresented = true
        // Home's bounded backfill may finish during the 24 ms render grace,
        // before SwiftUI delivers the router onChange callback. Consume the
        // latched request here as a race-safe catch-up.
        routeLocalSessionMaintenanceRequest(
            router.localSessionMaintenanceRequestedThisProcess
        )
        _ = enqueueDeferredMaintenanceReasons()
        // Bounded preparation has already made launch-critical singleton
        // repairs. Its deeper typed hints and any durable cursor resume only
        // after the same idle grace as verification, so an interrupted sweep
        // cannot monopolize the first interaction merely because a small
        // singleton hint was also observed during this launch.
        if SyncMaintenanceLaunchPolicy.requiresInitialVerificationSweep(
            for: persistenceMode
        ) {
            requestAggregateProjectionVerification()
        }
        scheduleMaintenanceAfterIdleGrace()
        scheduleRecurringVerification()
        scheduleDeferredLaunchMaintenance()
    }

    @MainActor
    private func scheduleDeferredLaunchMaintenance() {
        guard !didScheduleDeferredLaunchMaintenance else { return }
        didScheduleDeferredLaunchMaintenance = true
        Task { @MainActor in
            // Keep the transition interactive before legacy repair temporarily
            // occupies the main model context. A later ModelActor migration can
            // remove this grace interval without changing launch semantics.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await runDeferredLaunchMaintenance()
        }
    }

    @MainActor
    private func runDeferredLaunchMaintenance() async {
        guard !isDataDeletionQuiesced else { return }
        if deferredResetCleanupPending {
            deferredResetCleanupPending = false
            await performExternalActivityResetCleanup(
                preservingLocalFocus: deferredResetCleanupPreservesFocus
            )
        }

        SoundSynth.shared.prepare()
        Haptics.shared.prepare()
        Task { await PurchaseManager.shared.prepare() }

        await NotificationManager.shared.refreshAuthorizationStatus()
        await NotificationManager.shared.clearDeliveredState()
        await refreshPassiveNotifications()

        // Do not consume `pendingLaunchMaintenanceReasons` with the legacy
        // MainActor full sweep here. A clean multi-decade store must remain
        // interactive after its first frame. Fingerprint/import events still
        // request deterministic repair; the pending typed reasons are ready for
        // the chunked ModelActor maintenance worker.
    }

    @MainActor
    private func enqueueDeferredMaintenanceReasons() -> Bool {
        let didEnqueue = !pendingLaunchMaintenanceReasons.isEmpty
        for reason in pendingLaunchMaintenanceReasons {
            switch reason {
            case .prefsSingletonCreated, .prefsSingletonCanonicalized:
                maintenance.enqueue(.preferences)
            case .gachaSingletonCreated, .gachaSingletonCanonicalized:
                maintenance.enqueue(.gacha)
            case .localFocusAwaitingResetMarker:
                maintenance.enqueue(.focusFairness)
            }
        }
        pendingLaunchMaintenanceReasons.removeAll()
        return didEnqueue
    }

    @MainActor
    private func scheduleMaintenanceAfterIdleGrace() {
        guard scenePhase == .active,
              !isDataDeletionQuiesced else { return }
        if maintenanceGraceHasElapsed {
            startMaintenanceDrain()
            return
        }
        guard maintenanceIdleGraceTask == nil else { return }
        let token = UUID()
        maintenanceIdleGraceToken = token
        maintenanceIdleGraceTask = Task { @MainActor in
            do {
                try await Task.sleep(
                    for: SyncMaintenanceLaunchPolicy.foregroundIdleGrace
                )
            } catch {
                return
            }
            guard maintenanceIdleGraceToken == token,
                  scenePhase == .active,
                  !isDataDeletionQuiesced else { return }
            maintenanceIdleGraceTask = nil
            maintenanceIdleGraceToken = nil
            maintenanceGraceHasElapsed = true
            // @Query can already contain a CloudKit delivery before its
            // observers are armed. Re-run bounded preparation once at the end
            // of the launch grace, ahead of the rolling verification work.
            await reconcileIncomingActivityData()
            _ = enqueueDeferredMaintenanceReasons()
            guard scenePhase == .active,
                  !isDataDeletionQuiesced else { return }
            startMaintenanceDrain()
        }
    }

    @MainActor
    private func startMaintenanceDrain() {
        guard isFirstFramePresented,
              scenePhase == .active,
              !isDataDeletionQuiesced,
              maintenanceGraceHasElapsed,
              maintenanceDrainTask == nil else { return }

        // Propagate background QoS into each ModelActor slice. Verification is
        // restartable housekeeping and must yield CPU to direct interaction.
        let token = UUID()
        maintenanceDrainToken = token
        maintenanceDrainTask = Task(priority: .background) { @MainActor in
            defer {
                if maintenanceDrainToken == token {
                    maintenanceDrainTask = nil
                    maintenanceDrainToken = nil
                }
            }
            while !Task.isCancelled,
                  scenePhase == .active,
                  !isDataDeletionQuiesced {
                if SyncDeferredSourceInvalidationPolicy.shouldConsume(
                    isDeferred: deferredSourceInvalidationDuringWorker,
                    maintenanceWorkerIsInFlight: maintenance.isWorkerInFlight
                ) {
                    // Source-store notifications emitted by a maintenance save
                    // are indistinguishable from a simultaneous CloudKit import
                    // on iOS 17. Consume exactly once at the next quiescent
                    // slice boundary. Waiting for the whole checkpoint to drain
                    // would strand a genuine import behind an unrelated kind's
                    // long retry backoff. A stable replay emits no source write
                    // and therefore converges.
                    deferredSourceInvalidationDuringWorker = false
                    enqueueSessionDependentVerification()
                }
                var shouldRefreshActivity = false
                var shouldReevaluateFocus = false
                let didRunSlice = await maintenance.runNextSlice(
                    modelContainer: modelContext.container,
                    isForeground: true
                ) { effect in
                    switch effect {
                    case .refreshActivityProjection:
                        shouldRefreshActivity = true
                    case .reevaluateLocalFocus:
                        shouldReevaluateFocus = true
                    }
                }
                synchronizeAggregateProjectionVerification()
                guard didRunSlice != nil else {
                    if maintenance.isWorkerInFlight {
                        // A cancelled predecessor may still be returning from
                        // its actor slice. Wait for it instead of mistaking the
                        // coordinator's busy state for an empty checkpoint.
                        do {
                            try await Task.sleep(for: .milliseconds(100))
                        } catch {
                            return
                        }
                        continue
                    }
                    // A failed/retry slice persists exponential backoff. No
                    // CloudKit import or scene transition is guaranteed to wake
                    // the app at that deadline, so keep one cancellable timer
                    // in this foreground drain instead of stranding the work.
                    guard let retryAt = maintenance.checkpoint.retryNotBefore else {
                        break
                    }
                    let delay = max(0, retryAt.timeIntervalSinceNow)
                    do {
                        if delay > 0 {
                            try await Task.sleep(for: .seconds(delay))
                        } else {
                            await Task.yield()
                        }
                    } catch {
                        return
                    }
                    continue
                }
                if shouldRefreshActivity {
                    await reconcileIncomingActivityData()
                }
                if shouldReevaluateFocus {
                    await offerCloudFocusIfNeeded()
                }
                // A clean, very large store can require thousands of read-only
                // verification slices. A bare yield lets this foreground task
                // immediately win the executor again and starve SwiftUI/AX.
                // Checkpoints make the drain restartable, so pace slices by one
                // short cancellable interval to preserve interaction latency.
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                // `.retry` writes `retryNotBefore`; the next loop iteration
                // takes the cancellable timer path above.
            }
        }
    }

    @MainActor
    private func routeLocalSessionMaintenanceRequest(
        _ requestIsActive: Bool
    ) {
        guard !isDataDeletionQuiesced,
              localSessionMaintenanceRequestGate.consume(
                  requestIsActive: requestIsActive,
                  firstFrameIsPresented: isFirstFramePresented,
                  persistenceMode: persistenceMode
              ) == .sessions else { return }
        // The specialized merge treats every session-derived projection as one
        // relaunch-resilient pipeline without resetting any active phase.
        _ = maintenance.mergeSessionRepairPipeline()
        // Before the foreground grace expires this is only a durable enqueue;
        // the existing timer starts the worker after the first 60 interactive
        // seconds. A restored active phase remains byte-for-byte intact while
        // any missing session-dependent phases are merged around it, so a
        // relaunch cannot reset its cursor or retry deadline. The pipeline
        // still reuses the same drain entrypoint below.
        scheduleMaintenanceAfterIdleGrace()
    }

    @MainActor
    private func requestAggregateProjectionVerification() {
        guard persistenceMode == .cloudKit,
              !isDataDeletionQuiesced else { return }
        aggregateProjectionPresentation.invalidate()
        maintenance.enqueue(.verificationSweep)
        if let generation = maintenance.checkpoint.generation(
            for: .verificationSweep
        ) {
            projectionVerificationTicket = AggregateProjectionVerificationTicket(
                verificationSweepGeneration: generation
            )
        }
        if maintenanceGraceHasElapsed {
            startMaintenanceDrain()
        }
    }

    @MainActor
    private func synchronizeAggregateProjectionVerification() {
        guard let projectionVerificationTicket,
              projectionVerificationTicket.isSatisfied(
                  by: maintenance.checkpoint
              ) else { return }
        self.projectionVerificationTicket = nil
        aggregateProjectionPresentation.markVerified()
    }

    @MainActor
    private func handleStoreChangeSignal(_ signal: SyncStoreChangeSignal) {
        guard isFirstFramePresented, !isDataDeletionQuiesced else { return }
        let classification = SyncStoreChangeClassifier.classify(
            signal,
            persistenceMode: persistenceMode,
            maintenanceWorkerIsInFlight: maintenance.isWorkerInFlight,
            expectedCloudSourceStoreURL: activeCloudSourceStoreURL
        )
        switch SyncStoreChangeSchedulingPolicy.decision(
            classification: classification,
            source: signal.source,
            maintenanceWorkerIsInFlight: maintenance.isWorkerInFlight
        ) {
        case .ignore:
            return
        case .deferRemoteUntilWorkerQuiesces:
            aggregateProjectionPresentation.invalidate()
            projectionVerificationTicket = nil
            deferredSourceInvalidationDuringWorker = true
            // Persist a verification reason without resetting the active
            // sessions cursor. If the process exits before quiescence, launch
            // resumes this checkpoint and remains unverified.
            maintenance.enqueue(.verificationSweep)
            return
        case .enqueueSessionDependents:
            break
        }
        switch storeChangeDebouncer.decision(for: classification) {
        case .ignore:
            return
        case .acceptNow:
            storeChangeDebounceTask?.cancel()
            storeChangeDebounceTask = nil
            storeChangeDebounceToken = nil
            enqueueSessionDependentVerification()
        case .scheduleTrailing(let deadline):
            // Coalesce only the expensive verification sweep. The source
            // generation itself is bumped durably and trust is revoked now, so
            // an older ticket cannot expose exact values during the window.
            durablyInvalidateSessionDependents()
            scheduleTrailingStoreInvalidation(at: deadline)
        }
    }

    @MainActor
    private func scheduleTrailingStoreInvalidation(at deadline: Date) {
        storeChangeDebounceTask?.cancel()
        let token = UUID()
        storeChangeDebounceToken = token
        storeChangeDebounceTask = Task { @MainActor in
            do {
                let delay = max(0, deadline.timeIntervalSinceNow)
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            } catch {
                return
            }
            guard storeChangeDebounceToken == token,
                  !isDataDeletionQuiesced else { return }
            storeChangeDebounceTask = nil
            storeChangeDebounceToken = nil
            guard storeChangeDebouncer.consumeTrailing() else { return }
            requestAggregateProjectionVerification()
        }
    }

    @MainActor
    private func enqueueSessionDependentVerification() {
        durablyInvalidateSessionDependents()
        requestAggregateProjectionVerification()
    }

    @MainActor
    private func durablyInvalidateSessionDependents() {
        // Checkpoint first: projection suppression is never the only record of
        // an import that still needs repair if the process terminates here.
        maintenance.enqueue(.sessions)
        aggregateProjectionPresentation.invalidate()
        // A ticket created before this source generation cannot prove a
        // verification pass happened after it, even if the pending graph later
        // becomes empty before the trailing coalesced sweep is requested.
        projectionVerificationTicket = nil
        if maintenanceGraceHasElapsed { startMaintenanceDrain() }
    }

    @MainActor
    private func scheduleRecurringVerification() {
        guard SyncMaintenanceLaunchPolicy.shouldScheduleRecurringVerification(
            for: persistenceMode,
            sceneIsActive: scenePhase == .active
        ), recurringVerificationTask == nil else { return }

        let token = UUID()
        recurringVerificationToken = token
        recurringVerificationTask = Task(priority: .background) { @MainActor in
            defer {
                if recurringVerificationToken == token {
                    recurringVerificationTask = nil
                    recurringVerificationToken = nil
                }
            }
            while !Task.isCancelled,
                  scenePhase == .active,
                  !isDataDeletionQuiesced {
                do {
                    try await Task.sleep(
                        for: SyncMaintenanceLaunchPolicy
                            .recurringVerificationInterval
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      scenePhase == .active,
                      !isDataDeletionQuiesced else { return }
                requestAggregateProjectionVerification()
                scheduleMaintenanceAfterIdleGrace()
            }
        }
    }

    @MainActor
    private func installCompleteDeletionOperation() {
        guard CompleteDataDeletionReleasePolicy.isEnabled else { return }
        completeDeletion.install {
            try await performCompleteDataDeletion()
        }
    }

    @MainActor
    private func verifyMountedDeletionFence() async {
        guard CompleteDataDeletionReleasePolicy.isEnabled,
              persistenceMode == .cloudKit,
              !isDataDeletionQuiesced else { return }
        do {
            let stateStore = try CompleteDataDeletionFileStateStore.live()
            let preflight = CompleteDataDeletionLaunchPreflight(
                stateStore: stateStore,
                remoteStore: CloudKitCompleteDataDeletionRemoteStore(),
                availabilityPolicy: .offlineFirst
            )
            let decision = try await preflight.evaluate()
            guard !Task.isCancelled else { return }
            switch decision {
            case .allowLegacyStore, .allowGeneration:
                activePersistenceSafetyNotice = nil
            case .allowUnverifiedOffline:
                activePersistenceSafetyNotice = Self.unverifiedFenceNotice
            case .eraseLocalStoreBeforeUse, .resumeDeletion, .block:
                // A mismatch or pending deletion is now known. Stop every
                // writer before the already-open mirroring stack can be used
                // again, then return to the pre-container launch gate.
                await quiesceForCompleteDataDeletion()
                await rebuildPersistenceAfterCompleteDeletion()
            }
        } catch {
            // Remote availability failures are represented by
            // `.allowUnverifiedOffline` above. A thrown error means the local
            // journal/receipt itself could not be decoded or read, so keeping
            // an already-mounted store writable would fail open.
            await quiesceForCompleteDataDeletion()
            await rebuildPersistenceAfterCompleteDeletion()
        }
    }

    private static let unverifiedFenceNotice =
        "iCloudの削除世代を未確認です。次回オンライン時に再照合します（古い記録の再流入を完全には防げません）"

    @MainActor
    private func performCompleteDataDeletion() async throws {
        guard persistenceMode == .cloudKit else {
            throw CompleteDataDeletionSystemError.cloudPersistenceRequired
        }
        let stateStore = try CompleteDataDeletionFileStateStore.live()
        let remoteStore = CloudKitCompleteDataDeletionRemoteStore()
        let localStore = CompleteDataDeletionModelStore(
            modelContainer: modelContext.container
        )
        let deviceState = SystemCompleteDataDeletionDeviceState {
            await quiesceForCompleteDataDeletion()
        }
        let coordinator = CompleteDataDeletionCoordinator(
            stateStore: stateStore,
            remoteStore: remoteStore,
            localModelStore: localStore,
            deviceState: deviceState,
            phaseObserver: { phase in
                completeDeletion.report(phase: phase)
            }
        )

        // Stop after the durable local journal and remote pending fence exist.
        // The launch host unmounts this CloudKit-backed ModelContainer, removes
        // its exact files, and resumes the remaining phases without an active
        // SwiftData mirroring delegate that could recreate a deleted zone.
        _ = try await coordinator.prepareForPersistenceUnmount()
        await quiesceForCompleteDataDeletion()
        completeDeletion.reportPersistenceRebuild()
        await rebuildPersistenceAfterCompleteDeletion()
    }

    @MainActor
    private func quiesceForCompleteDataDeletion() async {
        TimerCompletionAlertController.shared.stop()
        TimerCompletionAlertAcknowledgementStore.removeAll()
        isDataDeletionQuiesced = true
        maintenanceIdleGraceTask?.cancel()
        maintenanceIdleGraceTask = nil
        maintenanceIdleGraceToken = nil
        recurringVerificationTask?.cancel()
        recurringVerificationTask = nil
        recurringVerificationToken = nil
        storeChangeDebounceTask?.cancel()
        storeChangeDebounceTask = nil
        storeChangeDebounceToken = nil
        deferredSourceInvalidationDuringWorker = false
        projectionVerificationTicket = nil
        let activeMaintenanceTask = maintenanceDrainTask
        activeMaintenanceTask?.cancel()
        if let activeMaintenanceTask {
            await activeMaintenanceTask.value
        }
        maintenanceDrainTask = nil
        maintenanceDrainToken = nil
        modelContext.rollback()

        router.paywallPresented = false
        router.sharePresented = false
        router.cloudFocusRecoveryOffer = nil
        router.deferredFocusRecovery = nil
        router.recoveredFocus = nil
        router.recoveredBreak = nil
        router.toast = nil
        UIApplication.shared.isIdleTimerDisabled = false

        // Scoped SwiftUI tasks owned by the dismissed timer/share surfaces are
        // cancelled as those surfaces leave the hierarchy. Give cancellation a
        // MainActor turn before deleting their backing models.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(40))
    }

    @MainActor
    private func retryBootstrap() {
        guard persistenceStartupError == nil else { return }
        maintenanceIdleGraceTask?.cancel()
        maintenanceIdleGraceTask = nil
        maintenanceIdleGraceToken = nil
        recurringVerificationTask?.cancel()
        recurringVerificationTask = nil
        recurringVerificationToken = nil
        projectionVerificationTicket = nil
        maintenanceGraceHasElapsed = false
        aggregateProjectionPresentation = .initial(for: persistenceMode)
        maintenanceDrainTask?.cancel()
        maintenanceDrainTask = nil
        maintenanceDrainToken = nil
        storeChangeDebounceTask?.cancel()
        storeChangeDebounceTask = nil
        storeChangeDebounceToken = nil
        deferredSourceInvalidationDuringWorker = false
        bootstrapError = nil
        isBootstrapped = false
        isFirstFramePresented = false
        didScheduleDeferredLaunchMaintenance = false
        launchHasSyncedUsageEvidence = false
        deferredResetCleanupPending = false
        deferredResetCleanupPreservesFocus = false
        pendingLaunchMaintenanceReasons.removeAll()
        hasLeftActiveStateAfterFirstFrame = false
        bootstrapAttempt += 1
    }

    @MainActor
    private func reconcileIncomingActivityData() async {
        guard !isDataDeletionQuiesced else { return }
        guard !isReconcilingActivityData else {
            // Do not lose a second CloudKit delivery that lands while the
            // first deterministic merge is saving its result.
            shouldReconcileActivityDataAgain = true
            return
        }
        isReconcilingActivityData = true
        defer { isReconcilingActivityData = false }

        repeat {
            guard !isDataDeletionQuiesced else { return }
            shouldReconcileActivityDataAgain = false
            await applyLatestActivityResetIfNeeded()
            do {
                // A CloudKit delivery or foreground transition must never
                // materialize the complete activity history on MainActor.
                // `SeedData.bootstrap` remains the deterministic small-store
                // repair oracle, but its global sweep is not an interactive
                // event handler. This preparation performs only indexed,
                // single-row/existence reads and hands any deeper work to the
                // deferred maintenance queue.
                let localEnvelope = FocusPersistence.load()
                let preparation = try BoundedLaunchPreparation.prepare(
                    context: modelContext,
                    localFocusEpochID: localEnvelope?.dataEpochID,
                    hasLocalFocus: localEnvelope != nil,
                    pendingCompletionID: localEnvelope?.pendingCompletion?.sessionID
                )
                launchHasSyncedUsageEvidence = launchHasSyncedUsageEvidence
                    || preparation.hasSyncedUsageEvidence
                pendingLaunchMaintenanceReasons.formUnion(
                    preparation.deferredMaintenanceReasons
                )
                reconcileCloudUserState()
                await offerCloudFocusIfNeeded()
            } catch {
                modelContext.rollback()
                router.showToast(
                    persistenceMode == .localOnly
                        ? "端末内の記録を整理できませんでした"
                        : "iCloudから届いた記録を整理できませんでした",
                    symbol: persistenceMode == .localOnly
                        ? "exclamationmark.triangle"
                        : "exclamationmark.icloud"
                )
                return
            }
        } while shouldReconcileActivityDataAgain
    }

    /// Applies each durable reset generation once to device-local state. The
    /// SwiftData marker handles future stale CloudKit rows; this companion step
    /// clears notifications, Live Activities and UserDefaults that never sync.
    @MainActor
    private func applyLatestActivityResetIfNeeded() async {
        guard let marker = ActivityResetPolicy.currentMarker(from: resetSnapshots) else {
            return
        }
        let localEnvelope = FocusPersistence.load()
        let localEpochState = localEnvelope.map {
            localFocusEpochState($0.dataEpochID, currentMarker: marker)
        }
        if applyLaunchResetLocallyIfNeeded(
            marker: marker,
            localFocusEpochState: localEpochState
        ) {
            await performExternalActivityResetCleanup(
                preservingLocalFocus: localEnvelope != nil
                    && localEpochState != .stale
            )
        }
    }

    /// Establishes the reset gate without awaiting system services. Unknown
    /// generations remain quarantined; an exact known-stale local focus is
    /// retired even if this device already applied the winning reset marker.
    @MainActor
    private func applyLaunchResetLocallyIfNeeded(
        marker: ActivityResetSnapshot?,
        localFocusEpochState: ActivityEpochState?
    ) -> Bool {
        guard let marker else { return false }
        let localEnvelope = FocusPersistence.load()
        if localFocusEpochState == .stale, localEnvelope != nil {
            retireInvalidLocalFocus(localEnvelope)
            DeferredFocusCompletionStore.clear()
            UserDefaults.standard.removeObject(
                forKey: FocusPersistence.localCompletionIDKey
            )
        }

        let epochKey = marker.epochID.uuidString.lowercased()
        guard lastAppliedResetEpoch != epochKey else { return false }

        // This is the first local application of this reset generation. A
        // completion already created inside that same generation is valid and
        // must retain its Stop UI contract. An unknown future generation stays
        // quarantined, but keeps a prior acknowledgement so delayed marker
        // delivery cannot make an already-stopped completion sound again.
        let preservesLocalFocus = localEnvelope != nil
            && localFocusEpochState != .stale
        let retainedCompletionID = preservesLocalFocus
            ? localEnvelope?.pendingCompletion?.sessionID
            : nil
        let retainedCompletionWasAcknowledged = retainedCompletionID.map {
            TimerCompletionAlertAcknowledgementStore.contains(sessionID: $0)
        } ?? false
        let retainsActiveCompletionAlert = retainedCompletionID.map {
            localFocusEpochState == .current
                && !retainedCompletionWasAcknowledged
                && TimerCompletionAlertController.shared.isActive(sessionID: $0)
        } ?? false
        if !retainsActiveCompletionAlert {
            TimerCompletionAlertController.shared.stop()
        }
        // Keep the bounded acknowledgement list intact here: deleting and
        // recreating one retained ID would introduce a crash window that could
        // re-alert after Stop. Explicit on-device reset/deletion clears it.

        FocusPersistence.clearBreak()
        DeferredFocusCompletionStore.clear()
        PendingStratumCelebrationStore.removeAll()
        PendingRewardReceiptStore.removeAll()
        FocusRestCadenceStore.removeAll()
        UserDefaults.standard.removeObject(
            forKey: AccountScopedLocalState.defaultsKey(
                base: "review.local-completion-count"
            )
        )
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where AccountScopedLocalState.keyBelongsToActiveNamespace(
            key,
            basePrefix: "share.prompt."
        ) {
            UserDefaults.standard.removeObject(forKey: key)
        }

        if localFocusEpochState == .stale {
            router.recoveredFocus = nil
        }
        router.recoveredBreak = nil
        router.cloudFocusRecoveryOffer = nil
        dismissedCloudFocusOfferID = nil
        lastAppliedResetEpoch = epochKey
        return true
    }

    @MainActor
    private func performExternalActivityResetCleanup(
        preservingLocalFocus: Bool
    ) async {
        if !preservingLocalFocus {
            await NotificationManager.shared.cancelAllTimerNotifications()
            await FocusActivityManager.shared.endAll()
        }
        await NotificationManager.shared.clearDeliveredState()

        do {
            try await WidgetSnapshotStore.shared.clear()
        } catch {
            router.showToast(
                "記録はリセット済みですが、ウィジェットの更新に失敗しました",
                symbol: "exclamationmark.arrow.triangle.2.circlepath"
            )
        }
    }

    /// One exact lookup distinguishes a known stale envelope from an epoch
    /// whose marker has not arrived yet. The latter must never be destroyed.
    @MainActor
    private func localFocusEpochState(
        _ epochID: UUID?,
        currentMarker: ActivityResetSnapshot
    ) -> ActivityEpochState {
        guard let epochID else { return .stale }
        if epochID == currentMarker.epochID { return .current }
        let maximumSupportedSequence = ActivityResetPolicy.maximumSupportedSequence
        var descriptor = FetchDescriptor<ActivityResetMarker>(
            predicate: #Predicate {
                $0.epochID == epochID
                    && $0.sequence >= 0
                    && $0.sequence <= maximumSupportedSequence
            }
        )
        descriptor.fetchLimit = 1
        let isKnown = ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
        return isKnown ? .stale : .awaitingMarker
    }

    @MainActor
    private func finishOnboarding(
        selectedSubjectNames: Set<String>,
        wantsNotifications: Bool,
        rareRewardMode: RareRewardMode
    ) async {
        guard !isFinishingOnboarding else { return }
        isFinishingOnboarding = true
        defer { isFinishingOnboarding = false }

        do {
            let presetIDs = Set(SeedData.subjects.map(\.id))
            let presetNameKeys = Set(SeedData.subjects.map {
                SubjectNamePolicy.comparisonKey($0.name)
            })
            let selectedNames = selectedSubjectNames.compactMap {
                SubjectNamePolicy.validated($0)
            }
            let selectedNameKeys = Set(selectedNames.map(SubjectNamePolicy.comparisonKey))
            var subjectDescriptor = FetchDescriptor<Subject>(sortBy: [
                SortDescriptor(\Subject.syncRecordID)
            ])
            subjectDescriptor.fetchLimit = SubjectSyncPolicy.maximumPhysicalRows + 1
            let storedSubjects = try modelContext.fetch(subjectDescriptor)
            guard storedSubjects.count <= SubjectSyncPolicy.maximumPhysicalRows else {
                throw SubjectSyncPolicy.MutationError.tooManyPhysicalRows
            }
            let subjects = SubjectSyncPolicy.presentationSubjects(
                from: storedSubjects
            )
            var removedSubjectIDs = Set<UUID>()
            for subject in subjects where presetIDs.contains(subject.id) {
                let isSelected = selectedNameKeys.contains(
                    SubjectNamePolicy.comparisonKey(subject.name)
                )
                let logicalCopies = storedSubjects.filter { $0.id == subject.id }
                let hasRelationshipHistory = logicalCopies.contains {
                    !($0.studySessions?.isEmpty ?? true)
                        || !($0.achievementStones?.isEmpty ?? true)
                }
                let targetSubjectID = subject.id
                var snapshotHistoryDescriptor = FetchDescriptor<StudySession>(
                    predicate: #Predicate {
                        $0.subjectIDSnapshot == targetSubjectID
                    }
                )
                snapshotHistoryDescriptor.fetchLimit = 1
                let hasSnapshotHistory = try modelContext.fetch(
                    snapshotHistoryDescriptor
                ).isEmpty == false
                let hasHistory = hasRelationshipHistory || hasSnapshotHistory
                if OnboardingThemePolicy.shouldRetireBuiltInPreset(
                    isSelected: isSelected,
                    hasHistory: hasHistory
                ) {
                    removedSubjectIDs.insert(subject.id)
                    subject.isArchived = true
                    subject.deletedAt = .now
                    try SubjectSyncPolicy.recordUserMutation(
                        from: subject,
                        among: storedSubjects
                    )
                } else {
                    let archived = !isSelected
                    if subject.isArchived != archived {
                        subject.isArchived = archived
                        try SubjectSyncPolicy.recordUserMutation(
                            from: subject,
                            among: storedSubjects
                        )
                    }
                }
            }

            let customNames = selectedNames
                .filter { !presetNameKeys.contains(SubjectNamePolicy.comparisonKey($0)) }
                .sorted {
                    SubjectNamePolicy.comparisonKey($0)
                        < SubjectNamePolicy.comparisonKey($1)
                }
            var retainedSubjects = subjects.filter {
                !removedSubjectIDs.contains($0.id)
            }
            var knownNames = Set(retainedSubjects.map {
                SubjectNamePolicy.comparisonKey($0.name)
            })
            var remainingNewSubjectSlots = max(
                0,
                Constants.App.maximumSubjects - retainedSubjects.count
            )

            // Cold launch intentionally no longer runs SeedData's global
            // subject repair. Create only the presets the user explicitly
            // selected here, so a brand-new install cannot finish onboarding
            // with an empty subject list. This also avoids recreating deleted
            // presets merely because a device is waiting for CloudKit.
            for (index, preset) in SeedData.subjects.enumerated() {
                let normalized = SubjectNamePolicy.comparisonKey(preset.name)
                guard selectedNameKeys.contains(normalized) else { continue }
                if let existing = retainedSubjects.first(where: {
                    $0.id == preset.id
                        || SubjectNamePolicy.comparisonKey($0.name) == normalized
                }) {
                    if existing.isArchived {
                        existing.isArchived = false
                        try SubjectSyncPolicy.recordUserMutation(
                            from: existing,
                            among: storedSubjects
                        )
                    }
                    continue
                }
                guard remainingNewSubjectSlots > 0 else { continue }
                guard knownNames.insert(normalized).inserted else { continue }
                let subject = Subject(
                    id: preset.id,
                    name: preset.name,
                    colorHex: preset.colorHex,
                    sortOrder: index
                )
                modelContext.insert(subject)
                retainedSubjects.append(subject)
                remainingNewSubjectSlots -= 1
            }

            var nextSortOrder = NonnegativeIntPolicy.next(
                after: retainedSubjects.map(\.sortOrder).max()
            )
            for name in customNames {
                let normalized = SubjectNamePolicy.comparisonKey(name)
                if let existing = retainedSubjects.first(where: {
                    SubjectNamePolicy.comparisonKey($0.name) == normalized
                }) {
                    if existing.isArchived {
                        existing.isArchived = false
                        try SubjectSyncPolicy.recordUserMutation(
                            from: existing,
                            among: storedSubjects
                        )
                    }
                    continue
                }
                guard remainingNewSubjectSlots > 0 else { continue }
                guard knownNames.insert(normalized).inserted else { continue }
                modelContext.insert(
                    Subject(
                        name: name,
                        colorHex: onboardingSubjectColor(
                            for: name,
                            at: nextSortOrder
                        ),
                        sortOrder: nextSortOrder
                    )
                )
                nextSortOrder = NonnegativeIntPolicy.next(after: nextSortOrder)
                remainingNewSubjectSlots -= 1
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            router.showToast("初期設定を保存できませんでした。もう一度お試しください", symbol: "exclamationmark.triangle")
            return
        }

        let granted = wantsNotifications
            ? await NotificationManager.shared.requestAuthorization()
            : false
        do {
            let changedAt = Date.now
            try PrefsConsumerPolicy.mutate(
                .reminderEnabled,
                context: modelContext,
                markers: resetSnapshots
            ) {
                $0.reminderEnabled = granted
            }
            try PrefsConsumerPolicy.mutate(
                .reminderTime,
                context: modelContext,
                markers: resetSnapshots
            ) {
                $0.reminderHour = Constants.Notification.defaultReminderHour
                $0.reminderMinute = Constants.Notification.defaultReminderMinute
            }
            try PrefsConsumerPolicy.mutate(
                .usagePurpose,
                context: modelContext,
                markers: resetSnapshots
            ) {
                // Kept only for backward-compatible CloudKit and JSON fields.
                // Runtime UI no longer divides themes into study/work modes.
                $0.usagePurposeRawValue = UsagePurpose.study.rawValue
                $0.usagePurposeUpdatedAt = changedAt
            }
            // This timestamp is the synchronized evidence of informed choice.
            // Without it, reward resolution stays off even when a legacy raw
            // value happens to say `standard`.
            let writer = try PrefsConsumerPolicy.mutate(
                .rareReward,
                context: modelContext,
                markers: resetSnapshots
            ) {
                $0.rareRewardModeRawValue = rareRewardMode.rawValue
                $0.rareRewardModeUpdatedAt = changedAt
            }
            writer.hasCompletedOnboarding = true
            try modelContext.save()
            usagePurposeRawValue = UsagePurpose.study.rawValue
        } catch {
            modelContext.rollback()
            router.showToast(
                persistenceMode == .localOnly
                    ? "初期設定をこのiPhoneへ保存できませんでした。もう一度お試しください"
                    : "初期設定をiCloudへ保存できませんでした。もう一度お試しください",
                symbol: persistenceMode == .localOnly
                    ? "exclamationmark.triangle"
                    : "exclamationmark.icloud"
            )
            return
        }

        // The onboarding switch describes the daily reminder only. Monthly
        // Wrapped remains an explicit, separately explained opt-in in Settings.
        wrappedNotifications = false
        if granted {
            do {
                try await NotificationManager.shared.synchronizePassiveNotifications(
                    dailyReminderEnabled: true,
                    wrappedEnabled: false,
                    hour: Constants.Notification.defaultReminderHour,
                    minute: Constants.Notification.defaultReminderMinute
                )
                lastPassiveNotificationErrorFingerprint = nil
            } catch {
                reportPassiveNotificationFailure(error)
            }
        } else {
            await NotificationManager.shared.cancelPassiveNotifications()
            lastPassiveNotificationErrorFingerprint = nil
        }

        withAnimation(.easeInOut(duration: 0.35)) {
            didCompleteOnboarding = true
        }
    }

    /// Bridges the fast local launch flags to their CloudKit-backed Prefs
    /// equivalents. The retired study/work preference remains synchronized for
    /// data compatibility, but a replacement device never publishes its default
    /// until onboarding or prior records prove this is an established install.
    @MainActor
    private func reconcileCloudUserState() {
        let values: [Prefs]
        let state: PrefsSyncPolicy.ResolvedState
        do {
            values = try PrefsSyncPolicy.fetchBounded(from: modelContext)
            state = try PrefsSyncPolicy.resolvedState(
                in: values,
                currentEpochID: PrefsConsumerPolicy.currentEpochID(
                    from: resetSnapshots
                )
            )
        } catch {
            // Overflow or contradictory stamps leave both local mirrors and
            // synchronized source rows untouched until evidence is complete.
            return
        }

        if state.usagePurposeUpdatedAt != nil,
           UsagePurpose(rawValue: state.usagePurposeRawValue) != nil {
            usagePurposeRawValue = state.usagePurposeRawValue
        }

        let established = didCompleteOnboarding
            || state.hasCompletedOnboarding
            || !studySessions.isEmpty
            || launchHasSyncedUsageEvidence
        guard established else { return }

        didCompleteOnboarding = true
        // Retiring unused built-in presets requires relationship inspection and
        // is maintenance, not foreground reconciliation. Keeping an archived
        // preset is harmless; faulting decades of relationships here is not.
        do {
            let writer = try PrefsConsumerPolicy.ensureWriterRow(
                context: modelContext,
                markers: resetSnapshots
            )
            if !writer.hasCompletedOnboarding {
                writer.hasCompletedOnboarding = true
            }
            if state.usagePurposeUpdatedAt == nil,
               let localPurpose = UsagePurpose(rawValue: usagePurposeRawValue) {
                try PrefsConsumerPolicy.mutate(
                    .usagePurpose,
                    context: modelContext,
                    markers: resetSnapshots
                ) {
                    $0.usagePurposeRawValue = localPurpose.rawValue
                    $0.usagePurposeUpdatedAt = .now
                }
            }
            if modelContext.hasChanges {
                try modelContext.save()
            }
        } catch {
            modelContext.rollback()
        }
    }

    private func onboardingSubjectColor(
        for name: String,
        at index: Int
    ) -> String {
        if let preset = SubjectSuggestionCatalog.preset(named: name) {
            return preset.colorHex
        }
        let palette = [
            Constants.Color.english,
            Constants.Color.mathematics,
            Constants.Color.japanese,
            Constants.Color.science,
            Constants.Color.socialStudies,
            "#D6863A", "#36A7AE", "#D56B82", "#739B45", "#5967C8", "#A76A3F", "#5688A8"
        ]
        return palette[index % palette.count]
    }

    /// Restores only the durable local timer during cold start. No global timer
    /// or ownership history is fetched here. A pending completion is retained
    /// until the bounded preparation finds its exact StudySession UUID.
    @MainActor
    private func restoreBoundedLocalFocusIfNeeded(
        _ envelope: FocusRecoveryEnvelope?,
        preparation: BoundedLaunchPreparation.Result
    ) async {
        guard let envelope else {
            await FocusActivityManager.shared.reconcileWithDurableSession(nil)
            return
        }
        switch preparation.localFocusDisposition {
        case .present:
            await presentLocalRecovery(envelope)
            let durableEnvelope = FocusPersistence.load()
            await FocusActivityManager.shared.reconcileWithDurableSession(
                durableEnvelope?.pendingCompletion?.sessionID
                    ?? durableEnvelope?.engine.currentSessionID
            )
        case let .retireMaterialized(sessionID):
            // Exact current-epoch materialization is the one bounded condition
            // that permits retiring the last local completion envelope, but
            // persistence and acknowledgement are separate events. Until the
            // person presses Stop, keep presenting the recovered completion so
            // a foreground alert can never outlive its only stop control.
            guard TimerCompletionAlertAcknowledgementStore.contains(
                sessionID: sessionID
            ) else {
                await presentLocalRecovery(envelope)
                let durableEnvelope = FocusPersistence.load()
                await FocusActivityManager.shared.reconcileWithDurableSession(
                    durableEnvelope?.pendingCompletion?.sessionID
                        ?? durableEnvelope?.engine.currentSessionID
                )
                return
            }
            TimerCompletionAlertController.shared.stop(sessionID: sessionID)
            NotificationManager.shared.cancelFocusCompletion(sessionID: sessionID)
            FocusPersistence.clear()
            DeferredFocusCompletionStore.clear(sessionID: sessionID)
            router.deferredFocusRecovery = nil
            UserDefaults.standard.removeObject(
                forKey: FocusPersistence.localCompletionIDKey
            )
            await FocusActivityManager.shared.cancel(sessionID: sessionID)
            await FocusActivityManager.shared.reconcileWithDurableSession(nil)
        case .retireStale, .quarantineAwaitingMarker, .none:
            // A known-stale envelope was already retired by the reset gate.
            // Unknown generations keep their bytes but never retain an OS
            // surface until their reset marker proves they are current.
            await FocusActivityManager.shared.reconcileWithDurableSession(nil)
        }
    }

    @MainActor
    private func recoverInterruptedTimerIfNeeded() async {
        let deviceID = FocusDeviceIdentity.current()
        let localEnvelope = FocusPersistence.load().map(
            prepareLocalRecoveryEnvelope
        )

        if let localEnvelope {
            switch ActivityResetPolicy.state(
                of: localEnvelope.dataEpochID,
                markers: resetSnapshots
            ) {
            case .current:
                break
            case .stale:
                retireInvalidLocalFocus(localEnvelope)
                return
            case .awaitingMarker:
                // Preserve the bytes until their reset marker arrives, but do
                // not surface or promote an unknown generation.
                return
            }
        }

        if let localEnvelope,
           FocusPersistence.relaunchAction(for: localEnvelope, at: .now) == .restoreBreak {
            await presentLocalRecovery(localEnvelope)
            return
        }

        if let localEnvelope,
           let sessionID = localEnvelope.pendingCompletion?.sessionID
                ?? localEnvelope.engine.currentSessionID,
           localEnvelope.subject != nil {
            let status: SyncedFocusStatus = localEnvelope.pendingCompletion != nil
                ? .completionPending
                : (localEnvelope.engine.snapshot(at: .now).phase == .paused ? .paused : .running)
            _ = try? FocusCloudSyncStore.upsert(
                envelope: localEnvelope,
                status: status,
                context: modelContext,
                deviceID: deviceID,
                claimIfUnowned: true,
                now: localEnvelope.savedAt
            )
            _ = sessionID
            try? modelContext.save()
        }

        _ = try? FocusCloudSyncStore.reconcileActiveTimers(
            context: modelContext,
            deviceID: deviceID
        )
        try? modelContext.save()

        // A completion envelope is the last durable local copy of an earned
        // focus. CloudKit can deliver the ownership/timer rows before the
        // matching StudySession, so neither a temporarily missing canonical
        // timer nor a foreign owner is proof that the completion is safely in
        // history. Keep presenting the local commit screen until the exact
        // StudySession materializes; FocusView then resolves it idempotently
        // as `alreadyMaterialized` and retires the envelope.
        if let localEnvelope,
           let pendingSessionID = localEnvelope.pendingCompletion?.sessionID,
           !hasMaterializedCompletion(sessionID: pendingSessionID) {
            await presentLocalRecovery(localEnvelope)
            return
        }

        let canonical: SyncedFocusTimer
        do {
            guard let candidate = try FocusCloudSyncStore.canonicalActive(
                context: modelContext
            ) else {
                if let localEnvelope,
                   let sessionID = localEnvelope.pendingCompletion?.sessionID
                        ?? localEnvelope.engine.currentSessionID {
                    // A missing global candidate can be a transient CloudKit
                    // snapshot, or a completed timer whose StudySession has not
                    // arrived yet. Retire local recovery only after an exact,
                    // irreversible closure sentinel says it is safe.
                    do {
                        let gate = try FocusCloudSyncStore.completionGate(
                            sessionID: sessionID,
                            context: modelContext
                        )
                        switch gate {
                        case .cancelledBeforeCompletion, .materialized:
                            retireInvalidLocalFocus(localEnvelope)
                        case .open, .completedAwaitingSession:
                            await presentLocalRecovery(localEnvelope)
                        }
                    } catch {
                        await presentLocalRecovery(localEnvelope)
                    }
                } else if let localEnvelope {
                    await presentLocalRecovery(localEnvelope)
                }
                return
            }
            canonical = candidate
        } catch {
            // Query/maintenance failures are not proof that the local timer is
            // invalid. Keep its durable envelope and suppress handoff until a
            // later maintenance/import pass can establish a safe winner.
            if let localEnvelope {
                await presentLocalRecovery(localEnvelope)
            }
            return
        }
        let claims = (try? FocusCloudSyncStore.claims(
            sessionID: canonical.sessionID,
            context: modelContext
        ))?
            .map(\.policySnapshot) ?? []
        let localSessionID = localEnvelope?.pendingCompletion?.sessionID
            ?? localEnvelope?.engine.currentSessionID
        let recoveryAction = FocusSyncPolicy.recoveryAction(
            canonical: canonical.policySnapshot,
            localSessionID: localSessionID,
            currentDeviceID: deviceID,
            claims: claims
        )

        switch recoveryAction {
        case .resumeLocal:
            guard let localEnvelope else { return }
            await presentLocalRecovery(localEnvelope)
        case .offerCloudRecovery:
            if let localEnvelope {
                retireInvalidLocalFocus(localEnvelope)
            }
            await prepareCloudRecoveryOffer(from: canonical)
        case .none:
            break
        }
    }

    @MainActor
    private func hasMaterializedCompletion(sessionID: UUID) -> Bool {
        var descriptor = FetchDescriptor<StudySession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        descriptor.fetchLimit = 2
        return ((try? modelContext.fetch(descriptor)) ?? []).contains {
            isCurrentActivity($0.dataEpochID)
                && StudySessionIntegrityPolicy.isSupported($0)
        }
    }

    @MainActor
    private func presentLocalRecovery(
        _ originalEnvelope: FocusRecoveryEnvelope
    ) async {
        let envelope = prepareLocalRecoveryEnvelope(originalEnvelope)
        guard let subjectSnapshot = envelope.subject else {
            // Payloads from versions that did not persist a subject cannot be
            // committed into a trustworthy StudySession. Retire only those
            // legacy bytes; current envelopes below retain their session.
            if let sessionID = envelope.pendingCompletion?.sessionID
                ?? envelope.engine.currentSessionID {
                NotificationManager.shared.cancelFocusCompletion(sessionID: sessionID)
                TimerCompletionAlertController.shared.stop(sessionID: sessionID)
                await FocusActivityManager.shared.cancel(sessionID: sessionID)
            }
            FocusPersistence.clear()
            return
        }

        let relaunchAction = FocusPersistence.relaunchAction(for: envelope, at: .now)
        guard relaunchAction.restoresFocusView else {
            if let sessionID = envelope.pendingCompletion?.sessionID
                ?? envelope.engine.currentSessionID {
                NotificationManager.shared.cancelFocusCompletion(sessionID: sessionID)
                TimerCompletionAlertController.shared.stop(sessionID: sessionID)
                await FocusActivityManager.shared.cancel(sessionID: sessionID)
            }
            FocusPersistence.clear()
            return
        }

        let subjectID = subjectSnapshot.id
        let subject = try? SubjectSyncPolicy.presentationSubject(
            id: subjectID,
            context: modelContext
        )
        let request = RecoveredFocusRequest(
            subject: subject,
            subjectSnapshot: subjectSnapshot,
            engine: envelope.engine,
            clockAnchor: envelope.clockAnchor,
            pendingCompletion: envelope.pendingCompletion,
            scheduledCompletionNotificationDeliveryDate:
                envelope.scheduledCompletionNotificationDeliveryDate,
            dataEpochID: envelope.dataEpochID
        )
        if let pendingID = envelope.pendingCompletion?.sessionID,
           DeferredFocusCompletionStore.sessionID() == pendingID {
            router.deferredFocusRecovery = request
            router.recoveredFocus = nil
        } else {
            router.deferredFocusRecovery = nil
            router.recoveredFocus = request
        }
    }

    @MainActor
    private func prepareLocalRecoveryEnvelope(
        _ envelope: FocusRecoveryEnvelope
    ) -> FocusRecoveryEnvelope {
        let prepared = FocusPersistence.preparedForLocalRelaunch(
            envelope,
            at: .now,
            uptime: ContinuousUptime.now()
        )
        if prepared != envelope {
            // Persist the fail-closed source before the recovered view can be
            // interrupted again or publish this device's cloud revision.
            FocusPersistence.save(prepared)
        }
        return prepared
    }

    @MainActor
    private func retireInvalidLocalFocus(_ envelope: FocusRecoveryEnvelope?) {
        if let sessionID = envelope?.pendingCompletion?.sessionID
            ?? envelope?.engine.currentSessionID {
            NotificationManager.shared.cancelFocusCompletion(sessionID: sessionID)
            TimerCompletionAlertController.shared.stop(sessionID: sessionID)
            Task { await FocusActivityManager.shared.cancel(sessionID: sessionID) }
        }
        FocusPersistence.clear()
        DeferredFocusCompletionStore.clear()
        router.deferredFocusRecovery = nil
    }

    @MainActor
    private func offerCloudFocusIfNeeded() async {
        guard didCompleteOnboarding,
              router.recoveredFocus == nil,
              router.recoveredBreak == nil,
              FocusPersistence.load() == nil else { return }
        // The root sentinel is newest-first and hard bounded. Resolving the
        // visible active timer from it avoids faulting every historical timer
        // and ownership tombstone merely because the app entered foreground.
        let canonical: SyncedFocusTimer?
        do {
            canonical = try FocusCloudSyncStore.canonicalActive(
                context: modelContext
            )
            didReportCloudFocusIntegrityIssue = false
        } catch let error as FocusCloudSyncError {
            router.cloudFocusRecoveryOffer = nil
            if !didReportCloudFocusIntegrityIssue,
               (error == .timerHistoryRequiresMaintenance
                    || error == .invalidPayload) {
                didReportCloudFocusIntegrityIssue = true
                router.showToast(
                    persistenceMode == .localOnly
                        ? "端末内のタイマー履歴を安全に確認できません。記録は変更せず保持しています。設定のサポートからお問い合わせください"
                        : "iCloudのタイマー履歴を安全に確認できません。記録は変更せず保持しています。設定のサポートからお問い合わせください",
                    symbol: persistenceMode == .localOnly
                        ? "exclamationmark.triangle"
                        : "exclamationmark.icloud"
                )
            }
            return
        } catch {
            router.cloudFocusRecoveryOffer = nil
            return
        }
        guard let canonical else {
            router.cloudFocusRecoveryOffer = nil
            return
        }
        guard router.cloudFocusRecoveryOffer?.id != canonical.sessionID else { return }
        guard dismissedCloudFocusOfferID != canonical.sessionID else { return }
        await prepareCloudRecoveryOffer(from: canonical)
    }

    @MainActor
    private func prepareCloudRecoveryOffer(from timer: SyncedFocusTimer) async {
        if (try? FocusCloudSyncStore.isSessionClosed(
            sessionID: timer.sessionID,
            context: modelContext
        )) != false {
            router.cloudFocusRecoveryOffer = nil
            return
        }
        guard let payload = try? timer.decodedPayload() else {
            // Keep corrupt cloud history intact for diagnostics and bounded
            // maintenance. Guessing a cancellation here could destroy the
            // valid side of a delayed CloudKit conflict.
            router.cloudFocusRecoveryOffer = nil
            return
        }
        let envelope = payload.recoveryEnvelope(adoptedAt: .now)
        guard FocusPersistence.relaunchAction(for: envelope, at: .now).restoresFocusView
        else { return }

        let subjectID = payload.subject.id
        let subject = try? SubjectSyncPolicy.presentationSubject(
            id: subjectID,
            context: modelContext
        )
        NotificationManager.shared.cancelFocusCompletion(sessionID: timer.sessionID)
        router.cloudFocusRecoveryOffer = CloudFocusRecoveryOffer(
            request: RecoveredFocusRequest(
                subject: subject,
                subjectSnapshot: payload.subject,
                engine: envelope.engine,
                clockAnchor: envelope.clockAnchor,
                pendingCompletion: envelope.pendingCompletion,
                dataEpochID: payload.dataEpochID,
                origin: .iCloud,
                allowsLocalNotifications: false
            ),
            source: timer.policySnapshot
        )
    }

    @MainActor
    private func adoptCloudFocus(_ offer: CloudFocusRecoveryOffer) async {
        let sessionID = offer.id
        do {
            try FocusCloudSyncStore.claimOwnership(
                sessionID: sessionID,
                context: modelContext,
                deviceID: FocusDeviceIdentity.current(),
                expectedRecordID: offer.sourceRecordID,
                expectedRevision: offer.sourceRevision,
                expectedOwnershipSequence: offer.sourceOwnershipSequence
            )
            try modelContext.save()
        } catch {
            router.showToast(
                "タイマーを引き継げませんでした。通信状態を確認して再試行してください",
                symbol: "exclamationmark.icloud"
            )
            return
        }

        let source = offer.request
        let adoptedAt = Date.now
        let adoptionUptime = ContinuousUptime.now()
        let candidateEnvelope = FocusRecoveryEnvelope(
            engine: source.engine,
            subject: source.subjectSnapshot,
            clockAnchor: ClockAnchor(
                wallDate: adoptedAt,
                systemUptime: adoptionUptime
            ),
            pendingCompletion: source.pendingCompletion,
            savedAt: adoptedAt,
            dataEpochID: source.dataEpochID
        )
        let envelope = FocusPersistence.preparedForCrossDeviceAdoption(
            candidateEnvelope,
            at: adoptedAt,
            uptime: adoptionUptime
        )
        FocusPersistence.save(envelope)
        router.cloudFocusRecoveryOffer = nil
        router.recoveredFocus = RecoveredFocusRequest(
            subject: source.subject,
            subjectSnapshot: source.subjectSnapshot,
            engine: envelope.engine,
            clockAnchor: envelope.clockAnchor,
            pendingCompletion: envelope.pendingCompletion,
            dataEpochID: source.dataEpochID,
            origin: .iCloud,
            allowsLocalNotifications: true
        )
    }

    @MainActor
    private func recoverBreakTimerIfNeeded() async {
        guard let recovery = FocusPersistence.loadBreak() else { return }
        if router.recoveredFocus != nil {
            FocusPersistence.clearBreak()
            NotificationManager.shared.cancelBreakCompletion(id: recovery.id)
            return
        }
        // Let BreakTimerView resolve an elapsed recovery. It alone has the
        // notification witness, continuous-clock anchor, and current sensory
        // preference needed to decide whether an in-app cue is still owed.
        router.recoveredBreak = recovery
    }

    @MainActor
    private func refreshPassiveNotifications() async {
        do {
            let values = try PrefsSyncPolicy.fetchBounded(from: modelContext)
            let prefs = try PrefsSyncPolicy.resolvedState(
                in: values,
                currentEpochID: PrefsConsumerPolicy.currentEpochID(
                    from: resetSnapshots
                )
            )
            try await NotificationManager.shared.synchronizePassiveNotifications(
                dailyReminderEnabled: prefs.reminderEnabled,
                wrappedEnabled: wrappedNotifications,
                hour: prefs.reminderHour,
                minute: prefs.reminderMinute,
                playsSound: prefs.soundOn
            )
            lastPassiveNotificationErrorFingerprint = nil
        } catch {
            await NotificationManager.shared.cancelPassiveNotifications()
            reportPassiveNotificationFailure(error)
        }
    }

    @MainActor
    private func reportPassiveNotificationFailure(_ error: Error) {
        let cocoaError = error as NSError
        let fingerprint = "\(cocoaError.domain)#\(cocoaError.code)"
        guard lastPassiveNotificationErrorFingerprint != fingerprint else { return }
        lastPassiveNotificationErrorFingerprint = fingerprint
        router.showToast(
            "通知だけ更新できませんでした。通信状態を確認し、設定で通知時刻をもう一度保存してください",
            symbol: "bell.badge.exclamationmark"
        )
    }
}

private struct CompleteDataDeletionBlockingView: View {
    @Bindable var controller: CompleteDataDeletionController

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(PomoGemTheme.amber)
                    .accessibilityHidden(true)

                Text(statusTitle)
                    .font(PomoGemTheme.brand(23))
                    .multilineTextAlignment(.center)

                switch controller.status {
                case let .running(phase):
                    ProgressView(value: phase.progressFraction)
                        .tint(PomoGemTheme.amber)
                        .accessibilityLabel(phase.userFacingTitle)
                    Text(phase.userFacingTitle)
                        .foregroundStyle(PomoGemTheme.muted)
                        .multilineTextAlignment(.center)

                case let .failed(_, message):
                    Text(message)
                        .foregroundStyle(PomoGemTheme.muted)
                        .multilineTextAlignment(.center)
                    Text("削除は完了扱いになっていません。記録の追加は停止したままです。iCloudに接続して再試行してください。")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .multilineTextAlignment(.center)
                    Button("削除を再試行") {
                        controller.startOrRetry()
                    }
                    .buttonStyle(PomoGemPrimaryButtonStyle())
                    .accessibilityHint("保存済みの削除工程から再開します")

                case .rebuildingPersistence:
                    ProgressView()
                        .tint(PomoGemTheme.amber)
                        .accessibilityLabel("空の保存領域を準備中")
                    Text("ユーザー内容を削除した保存領域を閉じ、空の状態で作り直しています。古い端末からの再流入検知用に、内容を含まない削除世代記録1件だけをiCloudに残します。")
                        .foregroundStyle(PomoGemTheme.muted)
                        .multilineTextAlignment(.center)

                case .idle:
                    EmptyView()
                }

                Link(destination: AppLinks.support) {
                    Label("サポートを見る", systemImage: "questionmark.circle")
                }
                .buttonStyle(PomoGemSecondaryButtonStyle())
            }
            .frame(maxWidth: 480)
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .padding(20)
        }
        .interactiveDismissDisabled()
        .accessibilityAddTraits(.isModal)
    }

    private var statusTitle: String {
        switch controller.status {
        case .running:
            "ユーザー内容を削除中"
        case .failed:
            "削除を完了できませんでした"
        case .rebuildingPersistence:
            "削除結果を反映中"
        case .idle:
            ""
        }
    }

    private var statusSymbol: String {
        if case .failed = controller.status {
            return "exclamationmark.icloud"
        }
        return "trash.circle"
    }
}

private struct StartupErrorView: View {
    let diagnostic: String
    let canRetry: Bool
    let persistenceMode: PersistenceLaunchMode
    let onRetry: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(PomoGemTheme.amber)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("保存領域を開けませんでした")
                        .font(PomoGemTheme.brand(24))
                        .multilineTextAlignment(.center)
                    Text(persistenceMode == .localOnly
                         ? "記録を保護するため、別の保存先には切り替えていません。このiPhoneの空き容量を確認してください。"
                         : "記録を保護するため、別の保存先には切り替えていません。iCloudと空き容量を確認してください。")
                        .font(.body)
                        .foregroundStyle(PomoGemTheme.muted)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    if canRetry {
                        Button("もう一度試す", action: onRetry)
                            .buttonStyle(PomoGemPrimaryButtonStyle())
                    } else {
                        Button("設定を開く") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            openURL(url)
                        }
                        .buttonStyle(PomoGemPrimaryButtonStyle())
                    }

                    Link(destination: AppLinks.support) {
                        Label("サポートを見る", systemImage: "questionmark.circle")
                    }
                    .buttonStyle(PomoGemSecondaryButtonStyle())
                }

                DisclosureGroup("診断情報") {
                    Text(diagnostic)
                        .font(.caption.monospaced())
                        .foregroundStyle(PomoGemTheme.muted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(PomoGemTheme.muted)
            }
            .frame(maxWidth: 520)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

struct MainNavigationView: View {
    @Bindable var router: AppRouter
    let persistenceMode: PersistenceLaunchMode
    @State private var navigationPath: [AppTab] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            HomeView()
                .navigationDestination(for: AppTab.self) { destination in
                    switch destination {
                    case .jar:
                        HomeView()
                    case .log:
                        LogView()
                    case .settings:
                        SettingsView(persistenceMode: persistenceMode)
                    }
                }
        }
        .tint(PomoGemTheme.amber)
        .onAppear { updateNavigationPath(for: router.selectedTab) }
        .onChange(of: router.selectedTab) { _, selectedTab in
            updateNavigationPath(for: selectedTab)
        }
        .onChange(of: navigationPath) { _, path in
            let visibleDestination = path.last ?? .jar
            if router.selectedTab != visibleDestination {
                router.selectedTab = visibleDestination
            }
        }
        .sheet(isPresented: $router.paywallPresented, onDismiss: {
            router.resolvePaywallDismissal(isPro: PurchaseManager.shared.isPro)
        }) {
            PaywallView(context: router.paywallContext)
        }
        .sheet(isPresented: $router.sharePresented) {
            ShareComposerView(scope: router.shareScope)
        }
        .fullScreenCover(item: $router.recoveredFocus, onDismiss: {
            router.completeFocusPresentation()
        }) { request in
            FocusView(recovery: request)
        }
        .fullScreenCover(item: $router.recoveredBreak) { recovery in
            BreakTimerView(recovery: recovery)
        }
    }

    private func updateNavigationPath(for selectedTab: AppTab) {
        let destinationPath: [AppTab] = selectedTab == .jar ? [] : [selectedTab]
        if navigationPath != destinationPath {
            navigationPath = destinationPath
        }
    }
}
