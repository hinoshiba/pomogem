import SwiftData
import SwiftUI
import UIKit

struct RootView: View {
    let persistenceStartupError: String?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboarding.completed") private var didCompleteOnboarding = false
    @AppStorage(UsagePurpose.storageKey) private var usagePurposeRawValue = UsagePurpose.study.rawValue
    @AppStorage("notifications.wrapped") private var wrappedNotifications = false
    @AppStorage("activity.last-applied-reset-epoch") private var lastAppliedResetEpoch = ""
    @State private var router = AppRouter()
    @State private var isBootstrapped = false
    @State private var isFinishingOnboarding = false
    @State private var bootstrapError: String?
    @State private var bootstrapAttempt = 0
    @State private var lastPassiveNotificationErrorFingerprint: String?
    @State private var dismissedCloudFocusOfferID: UUID?
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
    init(persistenceStartupError: String?) {
        self.persistenceStartupError = persistenceStartupError

        var preferencesSentinel = FetchDescriptor<Prefs>(
            sortBy: [SortDescriptor(\Prefs.id)]
        )
        preferencesSentinel.fetchLimit = 16
        _preferences = Query(preferencesSentinel)

        var sessionSentinel = FetchDescriptor<StudySession>(
            sortBy: [SortDescriptor(\StudySession.endAt, order: .reverse)]
        )
        sessionSentinel.fetchLimit = 32
        _storedStudySessions = Query(sessionSentinel)

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

        // This order is intentionally identical to
        // ActivityResetPolicy.markerIsOrderedBefore. Only the winner is needed
        // to quarantine every non-current generation on the first frame.
        var resetMarkerSentinel = FetchDescriptor<ActivityResetMarker>(sortBy: [
            SortDescriptor(\ActivityResetMarker.resetAt, order: .reverse),
            SortDescriptor(\ActivityResetMarker.sequence, order: .reverse),
            SortDescriptor(\ActivityResetMarker.writerDeviceID, order: .reverse),
            SortDescriptor(\ActivityResetMarker.epochID, order: .reverse),
            SortDescriptor(\ActivityResetMarker.id, order: .reverse)
        ])
        resetMarkerSentinel.fetchLimit = 1
        _activityResetMarkers = Query(resetMarkerSentinel)
    }

    private var resetSnapshots: [ActivityResetSnapshot] {
        activityResetMarkers.map(\.policySnapshot)
    }
    private func isCurrentActivity(_ epochID: UUID?) -> Bool {
        ActivityResetPolicy.isCurrent(epochID, markers: resetSnapshots)
    }
    private var studySessions: [StudySession] {
        storedStudySessions.filter { isCurrentActivity($0.dataEpochID) }
    }
    private var syncedFocusTimers: [SyncedFocusTimer] {
        storedSyncedFocusTimers.filter { isCurrentActivity($0.dataEpochID) }
    }
    private var focusDeviceClaims: [FocusTimerDeviceClaim] {
        storedFocusDeviceClaims.filter { isCurrentActivity($0.dataEpochID) }
    }
    private var currentPreferences: [Prefs] {
        preferences.filter {
            ActivityResetPolicy.isCurrent($0.activityEpochID, markers: resetSnapshots)
        }
    }

    private var blockingError: String? {
        persistenceStartupError ?? bootstrapError
    }

    private var focusSyncFingerprint: [String] {
        let timers = storedSyncedFocusTimers.map {
            "\($0.sessionID.uuidString)-\($0.dataEpochID?.uuidString ?? "legacy")-\($0.statusRaw)-\($0.revision)-\($0.updatedAt.timeIntervalSince1970)"
        }
        let claims = storedFocusDeviceClaims.map {
            "\($0.sessionID.uuidString)-\($0.dataEpochID?.uuidString ?? "legacy")-\($0.deviceID)-\($0.sequence)-\($0.releasedAt?.timeIntervalSince1970 ?? -1)"
        }
        return (timers + claims).sorted()
    }

    private var activityDataFingerprint: [String] {
        let markers = activityResetMarkers.map {
            "reset-\($0.epochID.uuidString)-\($0.sequence)-\($0.resetAt.timeIntervalSince1970)"
        }
        let sessions = storedStudySessions.map {
            "session-\($0.id.uuidString)-\($0.dataEpochID?.uuidString ?? "legacy")-\($0.grams)-\($0.isBaked)-\($0.rareRewardRuleVersion ?? 0)-\($0.rareRewardParticipated.map { String($0) } ?? "legacy")-\($0.rareRewardCreditedGrams ?? -1)-\($0.rareRewardOutcomesRawValue ?? "legacy")"
        }
        let achievements = storedAchievementStones.map {
            "achievement-\($0.id.uuidString)-\($0.dataEpochID?.uuidString ?? "legacy")-\($0.revision)-\($0.deletedAt?.timeIntervalSince1970 ?? -1)-\($0.updatedAt.timeIntervalSince1970)"
        }
        let aggregates = storedAggregates.map {
            "aggregate-\($0.id.uuidString)-\($0.dataEpochID?.uuidString ?? "legacy")-\($0.level)-\($0.grams)-\($0.sessionIDsJSON)-\($0.childAggregateIDsJSON)-\($0.parentAggregateID?.uuidString ?? "root")"
        }
        let strata = storedStrata.map {
            "stratum-\($0.id.uuidString)-\($0.dataEpochID?.uuidString ?? "legacy")-\($0.grams)-\($0.sessionIDsJSON)"
        }
        let bedrocks = storedBedrocks.map {
            "bedrock-\($0.dataEpochID?.uuidString ?? "legacy")-\($0.importedAt.timeIntervalSince1970)"
        }
        let gacha = storedGachaStates.map {
            "gacha-\($0.id.uuidString)-\($0.dataEpochID?.uuidString ?? "legacy")-\($0.sinceLastGold)-\($0.rewardCreditGrams)"
        }
        return (markers + sessions + achievements + aggregates + strata + bedrocks + gacha)
            .sorted()
    }

    private var hasSyncedUsageEvidence: Bool {
        currentPreferences.contains(where: \.hasCompletedOnboarding)
            || !studySessions.isEmpty
            || launchHasSyncedUsageEvidence
    }

    private var shouldShowMain: Bool {
        if LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess,
           ProcessInfo.processInfo.environment[
               LocalPreviewLaunchPolicy.rareRewardOnboardingUITestEnvironmentKey
           ] == "1",
           !currentPreferences.contains(where: \.hasCompletedOnboarding) {
            return false
        }
        return LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess
            || didCompleteOnboarding
            || launchHasSyncedUsageEvidence
            || hasSyncedUsageEvidence
    }

    private var cloudUserStateFingerprint: [String] {
        let prefsValues = preferences.map {
            [
                $0.id.uuidString,
                $0.activityEpochID?.uuidString ?? "legacy",
                String($0.soundOn),
                String($0.hapticsOn),
                $0.rareRewardModeRawValue,
                String($0.rareRewardModeUpdatedAt?.timeIntervalSince1970 ?? -1),
                String($0.reminderEnabled),
                String($0.reminderHour),
                String($0.reminderMinute),
                String($0.shareIncludesManual),
                String($0.showsThemeNameExternally),
                String($0.keepScreenAwake),
                String($0.preferredFocusMinutes),
                String($0.hasCompletedOnboarding),
                $0.usagePurposeRawValue,
                String($0.usagePurposeUpdatedAt?.timeIntervalSince1970 ?? -1)
            ].joined(separator: "-")
        }
        return (prefsValues + [
            "sessions-\(studySessions.count)",
            // This is only a bounded sync-change token. Whether an
            // achievement is valid usage evidence is decided by the
            // tombstone-inclusive launch resolver, never by this raw page.
            "achievement-candidates-\(storedAchievementStones.count)"
        ]).sorted()
    }

    var body: some View {
        ZStack {
            NightBackground()

            if let blockingError {
                StartupErrorView(
                    diagnostic: blockingError,
                    canRetry: persistenceStartupError == nil,
                    onRetry: retryBootstrap
                )
            } else if !isBootstrapped {
                ProgressView()
                    .tint(TsumibenTheme.amber)
                    .accessibilityLabel("準備中")
                    .accessibilityIdentifier("root.startup.progress")
            } else if shouldShowMain {
                MainNavigationView(router: router)
                    .transition(.opacity)
                    .accessibilityIdentifier("root.first-frame.ready")
                    .task { await markFirstFramePresented() }
            } else {
                OnboardingView { selectedSubjectNames, wantsNotifications, usagePurpose, rareRewardMode in
                    Task {
                        await finishOnboarding(
                            selectedSubjectNames: selectedSubjectNames,
                            wantsNotifications: wantsNotifications,
                            usagePurpose: usagePurpose,
                            rareRewardMode: rareRewardMode
                        )
                    }
                }
                .transition(.opacity)
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
        }
        .environment(router)
        .task(id: bootstrapAttempt) {
            await bootstrap()
        }
        .alert(
            "iCloudに進行中のタイマーがあります",
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
            Text("\(offer.request.subjectSnapshot.name)・残り約\(max(0, (remaining + 59) / 60))分。この端末へ引き継ぐと、この端末が終了通知を担当します。元の端末がオフラインまたはロック中の場合は、古い通知が一度届くことがあります。")
        }
        .onChange(of: focusSyncFingerprint) { _, _ in
            guard isFirstFramePresented else { return }
            Task { await reconcileIncomingActivityData() }
        }
        .onChange(of: activityDataFingerprint) { _, _ in
            guard isFirstFramePresented else { return }
            Task { await reconcileIncomingActivityData() }
        }
        .onChange(of: cloudUserStateFingerprint) { _, _ in
            guard isFirstFramePresented else { return }
            // CloudKit may update an existing Prefs row in place, or deliver a
            // duplicate row created offline. Re-run the deterministic merge so
            // privacy-sensitive notification/Live Activity settings converge
            // while a focus is still running, rather than only after relaunch.
            Task { await reconcileIncomingActivityData() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard isFirstFramePresented else { return }
            guard newPhase == .active else {
                hasLeftActiveStateAfterFirstFrame = true
                return
            }
            Task {
                // Initial activation is not a repair signal. Only a genuine
                // foreground return after the mounted app left active state may
                // request the legacy reconciliation path.
                if hasLeftActiveStateAfterFirstFrame {
                    hasLeftActiveStateAfterFirstFrame = false
                    await reconcileIncomingActivityData()
                }
                await PurchaseManager.shared.refreshEntitlements()
                await NotificationManager.shared.refreshAuthorizationStatus()
                await NotificationManager.shared.clearDeliveredState()
                await offerCloudFocusIfNeeded()
                await refreshPassiveNotifications()
            }
        }
    }

    @MainActor
    private func bootstrap() async {
        guard persistenceStartupError == nil else { return }
        guard !isBootstrapped else { return }
        bootstrapError = nil

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
            try seedExplicitUITestStateIfNeeded(preferences: preparation.canonicalPrefs)
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
            bootstrapError = error.localizedDescription
        }
    }

    /// UI tests intentionally bypass onboarding and use a fresh in-memory
    /// store. Since production cold launch no longer runs the full preset
    /// bootstrap, give that explicitly opted-in fixture one deterministic
    /// subject with a one-row existence check. Release and ordinary preview
    /// launches never enter this path.
    @MainActor
    private func seedExplicitUITestStateIfNeeded(preferences: Prefs) throws {
        guard LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess,
              let preset = SeedData.subjects.first
        else { return }

        // Existing UI journeys predate the informed-choice screen and test
        // unrelated flows. Keep their deterministic standard choice explicit;
        // the dedicated opt-in journey sets this environment flag to exercise
        // the real unselected gate.
        if ProcessInfo.processInfo.environment[
            LocalPreviewLaunchPolicy.unselectedRareRewardUITestEnvironmentKey
        ] != "1", preferences.rareRewardModeUpdatedAt == nil {
            preferences.rareRewardModeRawValue = RareRewardMode.standard.rawValue
            preferences.rareRewardModeUpdatedAt = Date(timeIntervalSince1970: 1_800_000_000)
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
        scheduleDeferredLaunchMaintenance()
        // @Query can already contain the first CloudKit delivery before any
        // onChange observer is armed. Replaying the bounded reconciliation
        // once after the first frame closes that launch-only blind spot while
        // preserving the interactive render gate above.
        await reconcileIncomingActivityData()
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
    private func retryBootstrap() {
        guard persistenceStartupError == nil else { return }
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
        guard !isReconcilingActivityData else {
            // Do not lose a second CloudKit delivery that lands while the
            // first deterministic merge is saving its result.
            shouldReconcileActivityDataAgain = true
            return
        }
        isReconcilingActivityData = true
        defer { isReconcilingActivityData = false }

        repeat {
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
                reconcileCloudUserState(canonicalPrefs: preparation.canonicalPrefs)
                await offerCloudFocusIfNeeded()
            } catch {
                modelContext.rollback()
                router.showToast(
                    "iCloudから届いた記録を整理できませんでした",
                    symbol: "exclamationmark.icloud"
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

        FocusPersistence.clearBreak()
        DeferredFocusCompletionStore.clear()
        PendingStratumCelebrationStore.removeAll()
        PendingRewardReceiptStore.removeAll()
        FocusRestCadenceStore.removeAll()
        UserDefaults.standard.removeObject(forKey: "review.local-completion-count")
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix("wrapped.") || key.hasPrefix("share.prompt.") {
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
        var descriptor = FetchDescriptor<ActivityResetMarker>(
            predicate: #Predicate { $0.epochID == epochID }
        )
        descriptor.fetchLimit = 1
        let isKnown = ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
        return isKnown ? .stale : .awaitingMarker
    }

    @MainActor
    private func finishOnboarding(
        selectedSubjectNames: Set<String>,
        wantsNotifications: Bool,
        usagePurpose: UsagePurpose,
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
            let subjects = try modelContext.fetch(FetchDescriptor<Subject>())
            var removedSubjectIDs = Set<UUID>()
            for subject in subjects where presetIDs.contains(subject.id) {
                let isSelected = selectedNameKeys.contains(
                    SubjectNamePolicy.comparisonKey(subject.name)
                )
                let hasHistory = !(subject.studySessions?.isEmpty ?? true)
                    || !(subject.achievementStones?.isEmpty ?? true)
                if usagePurpose == .work, !isSelected, !hasHistory {
                    removedSubjectIDs.insert(subject.id)
                    modelContext.delete(subject)
                } else {
                    subject.isArchived = !isSelected
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
                    existing.isArchived = false
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

            var nextSortOrder = (retainedSubjects.map(\.sortOrder).max() ?? -1) + 1
            for name in customNames {
                let normalized = SubjectNamePolicy.comparisonKey(name)
                if let existing = retainedSubjects.first(where: {
                    SubjectNamePolicy.comparisonKey($0.name) == normalized
                }) {
                    existing.isArchived = false
                    continue
                }
                guard remainingNewSubjectSlots > 0 else { continue }
                guard knownNames.insert(normalized).inserted else { continue }
                modelContext.insert(
                    Subject(
                        name: name,
                        colorHex: onboardingSubjectColor(
                            for: name,
                            purpose: usagePurpose,
                            at: nextSortOrder
                        ),
                        sortOrder: nextSortOrder
                    )
                )
                nextSortOrder += 1
                remainingNewSubjectSlots -= 1
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            router.showToast("初期設定を保存できませんでした。もう一度お試しください", symbol: "exclamationmark.triangle")
            return
        }

        usagePurposeRawValue = usagePurpose.rawValue

        let granted = wantsNotifications
            ? await NotificationManager.shared.requestAuthorization()
            : false
        do {
            let descriptor = FetchDescriptor<Prefs>()
            guard let prefs = try modelContext.fetch(descriptor).first(where: {
                ActivityResetPolicy.isCurrent(
                    $0.activityEpochID,
                    markers: resetSnapshots
                )
            }) else {
                router.showToast(
                    "iCloud用の初期設定を保存できませんでした。もう一度お試しください",
                    symbol: "exclamationmark.icloud"
                )
                return
            }
            prefs.reminderEnabled = granted
            prefs.reminderHour = Constants.Notification.defaultReminderHour
            prefs.reminderMinute = Constants.Notification.defaultReminderMinute
            prefs.hasCompletedOnboarding = true
            prefs.usagePurposeRawValue = usagePurpose.rawValue
            prefs.usagePurposeUpdatedAt = .now
            // This timestamp is the synchronized evidence of informed choice.
            // Without it, reward resolution stays off even when a legacy raw
            // value happens to say `standard`.
            prefs.rareRewardModeRawValue = rareRewardMode.rawValue
            prefs.rareRewardModeUpdatedAt = .now
            try modelContext.save()
        } catch {
            modelContext.rollback()
            router.showToast("通知設定を保存できませんでした。もう一度お試しください", symbol: "exclamationmark.triangle")
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
    /// equivalents. A replacement device never publishes its default "study"
    /// value until onboarding or prior synced records prove that it is an
    /// established installation, so it cannot overwrite an existing work mode.
    @MainActor
    private func reconcileCloudUserState(canonicalPrefs: Prefs) {
        // Root already owns a hard-bounded Prefs sentinel. Include the exact
        // canonical singleton returned by BoundedLaunchPreparation without
        // reopening an unbounded store fetch.
        var values = currentPreferences
        if !values.contains(where: { $0.id == canonicalPrefs.id }) {
            values.append(canonicalPrefs)
        }
        guard !values.isEmpty else { return }
        let prefs = canonicalPrefs

        if let newestPurpose = values
            .filter({ UsagePurpose(rawValue: $0.usagePurposeRawValue) != nil })
            .max(by: {
                ($0.usagePurposeUpdatedAt ?? .distantPast)
                    < ($1.usagePurposeUpdatedAt ?? .distantPast)
            }), newestPurpose.usagePurposeUpdatedAt != nil {
            usagePurposeRawValue = newestPurpose.usagePurposeRawValue
        }

        let established = didCompleteOnboarding
            || values.contains(where: \.hasCompletedOnboarding)
            || !studySessions.isEmpty
            || launchHasSyncedUsageEvidence
        guard established else { return }

        didCompleteOnboarding = true
        var changed = false
        if !prefs.hasCompletedOnboarding {
            prefs.hasCompletedOnboarding = true
            changed = true
        }
        if prefs.usagePurposeUpdatedAt == nil,
           let localPurpose = UsagePurpose(rawValue: usagePurposeRawValue) {
            prefs.usagePurposeRawValue = localPurpose.rawValue
            prefs.usagePurposeUpdatedAt = .now
            changed = true
        }
        // Removing unused work-mode presets requires relationship inspection
        // and is maintenance, not foreground reconciliation. Keeping an
        // archived preset is harmless; faulting decades of relationships here
        // is not.
        guard changed else { return }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
        }
    }

    private func onboardingSubjectColor(
        for name: String,
        purpose: UsagePurpose,
        at index: Int
    ) -> String {
        if let preset = purpose.presets.first(where: {
            SubjectNamePolicy.comparisonKey($0.name)
                == SubjectNamePolicy.comparisonKey(name)
        }) {
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
        guard let envelope else { return }
        switch preparation.localFocusDisposition {
        case .present:
            await presentLocalRecovery(envelope)
        case let .retireMaterialized(sessionID):
            // Exact current-epoch materialization is the one bounded condition
            // that permits retiring the last local completion envelope.
            NotificationManager.shared.cancelFocusCompletion(sessionID: sessionID)
            FocusPersistence.clear()
            DeferredFocusCompletionStore.clear(sessionID: sessionID)
            router.deferredFocusRecovery = nil
            UserDefaults.standard.removeObject(
                forKey: FocusPersistence.localCompletionIDKey
            )
            Task { await FocusActivityManager.shared.cancel(sessionID: sessionID) }
        case .retireStale:
            // applyLaunchResetLocallyIfNeeded already retired this envelope.
            return
        case .quarantineAwaitingMarker, .none:
            // Preserve the bytes but do not surface an unknown generation.
            return
        }
    }

    @MainActor
    private func recoverInterruptedTimerIfNeeded() async {
        let deviceID = FocusDeviceIdentity.current()
        let localEnvelope = FocusPersistence.load()

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

        guard let canonical = try? FocusCloudSyncStore.canonicalActive(context: modelContext) else {
            if localEnvelope != nil { retireInvalidLocalFocus(localEnvelope) }
            return
        }
        let claims = (try? FocusCloudSyncStore.allClaims(context: modelContext))?
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
        }
    }

    @MainActor
    private func presentLocalRecovery(_ envelope: FocusRecoveryEnvelope) async {
        guard let subjectSnapshot = envelope.subject else {
            // Payloads from versions that did not persist a subject cannot be
            // committed into a trustworthy StudySession. Retire only those
            // legacy bytes; current envelopes below retain their session.
            if let sessionID = envelope.engine.currentSessionID {
                NotificationManager.shared.cancelFocusCompletion(sessionID: sessionID)
                await FocusActivityManager.shared.cancel(sessionID: sessionID)
            }
            FocusPersistence.clear()
            return
        }

        let relaunchAction = FocusPersistence.relaunchAction(for: envelope, at: .now)
        guard relaunchAction.restoresFocusView else {
            if let sessionID = envelope.engine.currentSessionID {
                NotificationManager.shared.cancelFocusCompletion(sessionID: sessionID)
                await FocusActivityManager.shared.cancel(sessionID: sessionID)
            }
            FocusPersistence.clear()
            return
        }

        let subjectID = subjectSnapshot.id
        var descriptor = FetchDescriptor<Subject>(
            predicate: #Predicate { $0.id == subjectID }
        )
        descriptor.fetchLimit = 1
        let subject = (try? modelContext.fetch(descriptor))?.first
        let request = RecoveredFocusRequest(
            subject: subject,
            subjectSnapshot: subjectSnapshot,
            engine: envelope.engine,
            clockAnchor: envelope.clockAnchor,
            pendingCompletion: envelope.pendingCompletion,
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
    private func retireInvalidLocalFocus(_ envelope: FocusRecoveryEnvelope?) {
        if let sessionID = envelope?.pendingCompletion?.sessionID
            ?? envelope?.engine.currentSessionID {
            NotificationManager.shared.cancelFocusCompletion(sessionID: sessionID)
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
        let records = syncedFocusTimers
        guard let winner = FocusSyncPolicy.canonicalActive(
            from: records.map(\.policySnapshot)
        ), let canonical = records.first(where: { $0.id == winner.recordID }) else {
            router.cloudFocusRecoveryOffer = nil
            return
        }
        guard router.cloudFocusRecoveryOffer?.id != canonical.sessionID else { return }
        guard dismissedCloudFocusOfferID != canonical.sessionID else { return }
        await prepareCloudRecoveryOffer(from: canonical)
    }

    @MainActor
    private func prepareCloudRecoveryOffer(from timer: SyncedFocusTimer) async {
        guard let payload = try? timer.decodedPayload() else {
            timer.markTerminal(
                .cancelled,
                at: .now,
                writerDeviceID: FocusDeviceIdentity.current()
            )
            try? modelContext.save()
            return
        }
        let envelope = payload.recoveryEnvelope(adoptedAt: .now)
        guard FocusPersistence.relaunchAction(for: envelope, at: .now).restoresFocusView
        else { return }

        let subjectID = payload.subject.id
        var descriptor = FetchDescriptor<Subject>(
            predicate: #Predicate { $0.id == subjectID }
        )
        descriptor.fetchLimit = 1
        let subject = (try? modelContext.fetch(descriptor))?.first
        NotificationManager.shared.cancelFocusCompletion(sessionID: timer.sessionID)
        router.cloudFocusRecoveryOffer = CloudFocusRecoveryOffer(request:
            RecoveredFocusRequest(
                subject: subject,
                subjectSnapshot: payload.subject,
                engine: envelope.engine,
                clockAnchor: envelope.clockAnchor,
                pendingCompletion: envelope.pendingCompletion,
                dataEpochID: payload.dataEpochID,
                origin: .iCloud,
                allowsLocalNotifications: false
            )
        )
    }

    @MainActor
    private func adoptCloudFocus(_ offer: CloudFocusRecoveryOffer) async {
        let sessionID = offer.id
        do {
            try FocusCloudSyncStore.claimOwnership(
                sessionID: sessionID,
                context: modelContext,
                deviceID: FocusDeviceIdentity.current()
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
        let envelope = FocusRecoveryEnvelope(
            engine: source.engine,
            subject: source.subjectSnapshot,
            clockAnchor: ClockAnchor(wallDate: .now, systemUptime: ContinuousUptime.now()),
            pendingCompletion: source.pendingCompletion,
            savedAt: .now,
            dataEpochID: source.dataEpochID
        )
        FocusPersistence.save(envelope)
        router.cloudFocusRecoveryOffer = nil
        router.recoveredFocus = RecoveredFocusRequest(
            subject: source.subject,
            subjectSnapshot: source.subjectSnapshot,
            engine: source.engine,
            clockAnchor: envelope.clockAnchor,
            pendingCompletion: source.pendingCompletion,
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
        guard recovery.endDate > .now else {
            FocusPersistence.clearBreak()
            NotificationManager.shared.cancelBreakCompletion(id: recovery.id)
            router.showToast("休憩は終わっています。次の一粒へ戻りましょう", symbol: "cup.and.saucer.fill")
            return
        }
        router.recoveredBreak = recovery
    }

    @MainActor
    private func refreshPassiveNotifications() async {
        let descriptor = FetchDescriptor<Prefs>()
        do {
            guard let prefs = try modelContext.fetch(descriptor).first(where: {
                ActivityResetPolicy.isCurrent(
                    $0.activityEpochID,
                    markers: resetSnapshots
                )
            }) else { return }
            try await NotificationManager.shared.synchronizePassiveNotifications(
                dailyReminderEnabled: prefs.reminderEnabled,
                wrappedEnabled: wrappedNotifications,
                hour: prefs.reminderHour,
                minute: prefs.reminderMinute,
                playsSound: prefs.soundOn
            )
            lastPassiveNotificationErrorFingerprint = nil
        } catch {
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

private struct StartupErrorView: View {
    let diagnostic: String
    let canRetry: Bool
    let onRetry: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(TsumibenTheme.amber)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("保存領域を開けませんでした")
                        .font(TsumibenTheme.brand(24))
                        .multilineTextAlignment(.center)
                    Text("記録を保護するため、別の保存先には切り替えていません。iCloudと空き容量を確認してください。")
                        .font(.body)
                        .foregroundStyle(TsumibenTheme.muted)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    if canRetry {
                        Button("もう一度試す", action: onRetry)
                            .buttonStyle(TsumibenPrimaryButtonStyle())
                    } else {
                        Button("設定を開く") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            openURL(url)
                        }
                        .buttonStyle(TsumibenPrimaryButtonStyle())
                    }

                    Link(destination: AppLinks.support) {
                        Label("サポートを見る", systemImage: "questionmark.circle")
                    }
                    .buttonStyle(TsumibenSecondaryButtonStyle())
                }

                DisclosureGroup("診断情報") {
                    Text(diagnostic)
                        .font(.caption.monospaced())
                        .foregroundStyle(TsumibenTheme.muted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(TsumibenTheme.muted)
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
                        SettingsView()
                    }
                }
        }
        .tint(TsumibenTheme.amber)
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
        .fullScreenCover(item: $router.recoveredFocus) { request in
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
