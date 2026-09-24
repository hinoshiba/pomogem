import Accessibility
import SpriteKit
import StoreKit
import SwiftData
import SwiftUI

struct HomeSceneSessionSnapshotGeneration: Equatable {
    let cacheStamp: AggregateProjectionCacheStamp
    let isCloudVerificationPending: Bool

    init(_ presentation: AggregateProjectionPresentationContext) {
        cacheStamp = presentation.currentCacheStamp
        isCloudVerificationPending = presentation.isCloudVerificationPending
    }
}

enum HomeSceneSessionSnapshotPolicy {
    static func shouldRestoreSilently(
        sceneIsInitialized: Bool,
        appliedGeneration: HomeSceneSessionSnapshotGeneration?,
        acceptedGeneration: HomeSceneSessionSnapshotGeneration
    ) -> Bool {
        !sceneIsInitialized || appliedGeneration != acceptedGeneration
    }
}

enum LegacyStratumPresentationChangeFingerprint {
    static func value(for stratum: Stratum) -> String {
        [
            stratum.id.uuidString,
            stratum.dataEpochID?.uuidString ?? "legacy",
            stratum.bakedAt.timeIntervalSinceReferenceDate.description,
            stratum.sessionIDsJSON,
            String(stratum.pebbleCount),
            String(stratum.heightPt),
            String(stratum.grams),
            stratum.colorMixJSON,
            stratum.monthLabel
        ].joined(separator: "-")
    }
}

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    @Environment(\.requestReview) private var requestReview
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.pomogemReduceMotionOverride) private var reduceMotionOverride
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.isCloudOfflineSession) private var isCloudOfflineSession
    @Environment(\.aggregateProjectionPresentation)
    private var aggregateProjectionPresentation
    @ScaledMetric(relativeTo: .subheadline) private var homeMenuFontSize: CGFloat = 15
    @ScaledMetric(relativeTo: .subheadline) private var atmosphereTitleFontSize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption2) private var atmosphereSubtitleFontSize: CGFloat = 11
    @ScaledMetric(relativeTo: .subheadline) private var atmosphereCardHeight: CGFloat = 102
    /// Live theme rows only; tombstones never count toward the row bound.
    @Query(sort: \Subject.sortOrder) private var storedSubjects: [Subject]
    /// Observed so a deletion delivered as a new physical row refreshes the
    /// list; see `SubjectSyncPolicy.presentationSubjects(live:tombstones:context:)`.
    @Query private var storedSubjectTombstones: [Subject]
    @Query private var storedSessions: [StudySession]
    @Query private var storedAchievementStones: [AchievementStone]
    @Query private var storedAggregates: [AggregatePebble]
    @Query private var storedStrata: [Stratum]
    @Query private var activityResetMarkers: [ActivityResetMarker]
    @Query private var preferences: [Prefs]

    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

    @AppStorage(AccountScopedLocalState.defaultsKey(base: "home.selected-subject"))
    private var selectedSubjectID = ""
    @AppStorage(AccountScopedLocalState.defaultsKey(base: "jar.tap-hint-seen"))
    private var didSeeTapHint = false
    @AppStorage(AccountScopedLocalState.defaultsKey(base: "jar.voiceover-tap-hint-seen"))
    private var didSeeVoiceOverTapHint = false
    @AppStorage(AccountScopedLocalState.defaultsKey(base: HomeAtmosphere.storageKey))
    private var homeAtmosphereRawValue = HomeAtmosphere.aurora.rawValue
    @State private var scene = JarScene()
    @ObservedObject private var screenTime = ScreenTimeController.shared
    @State private var sceneInitialized = false
    @State private var homeIsVisible = false
    @State private var rewardDropRevealIsPending = false
    @State private var rewardDropRevealRequestID: UUID?
    @State private var rewardDropDestination: RewardDropContinuation?
    @State private var rewardSessionBackfill: [StudySession] = []
    @State private var rewardSessionBackfillGeneration: HomeSceneSessionSnapshotGeneration?
    @State private var knownLooseIDs = Set<UUID>()
    @State private var aggregatePresentationPage:
        HomeProjectionPolicy.RefreshedAggregatePresentationPage?
    @State private var supportedSessionBackfill: [StudySession] = []
    @State private var supportedSessionBackfillStamp:
        AggregateProjectionCacheStamp?
    @State private var supportedSessionBackfillVerifiedStamp:
        AggregateProjectionCacheStamp?
    @State private var sessionBackfillTask: Task<Void, Never>?
    @State private var sessionBackfillIsComplete = false
    @State private var hasLoadedSceneSessionSnapshot = false
    @State private var appliedSceneSessionSnapshotGeneration:
        HomeSceneSessionSnapshotGeneration?
    @State private var resolvedAchievementStones: [AchievementStone] = []
    @State private var projectedAchievementCount = 0
    @State private var achievementCountIsLowerBound = false
    /// Refreshed only when aggregate/legacy rows change. Keeping the direct
    /// level-one index avoids rebuilding recursively flattened UUID sets during
    /// ordinary SwiftUI body evaluation.
    @State private var representedSessionIDs = Set<UUID>()
    @State private var localMembershipProjectionIsComplete = true
    @State private var conflictedAggregateRootIDs = Set<UUID>()
    @State private var selectedDuration: PomodoroDuration = .twentyFiveMinutes
    @State private var focusConfiguration: FocusConfiguration?
    @State private var showHomeMenu = false
    @State private var showAccumulationOverview = false
    @State private var overviewInitialClusterID: UUID?
    @State private var aggregateInspectionID: UUID?
    @State private var selectedAggregateDetail: AccumulationClusterSummary?
    @State private var aggregateInspectionTask: Task<Void, Never>?
    @State private var showManualEntry = false
    @State private var screenTimeArrivals = ScreenTimeArrivalAnnouncer()
    @State private var showAchievementEntry = false
    @State private var showCustomDuration = false
    @State private var showAccumulationPlan = false
    @State private var completedStratum: PendingStratumCelebration?
    @State private var isDeferringStratumForCloudVerification = false
    @State private var presentedStratumID: UUID?
    @State private var stratumCelebrationQueue: [PendingStratumCelebration] = []
    @State private var isDeferringCelebrationsForShare = false
    @State private var failedBakeIDs = Set<UUID>()
    @State private var failedAggregateRequest: JarAggregateRequest?
    @State private var capacityRemaining: Int?
    @State private var showShareChip = false
    @State private var widgetRefreshTask: Task<Void, Never>?
    @State private var celebrationRecoveryTask: Task<Void, Never>?
    @State private var capacityCelebrationTask: Task<Void, Never>?
    @State private var breakOfferTask: Task<Void, Never>?
    @State private var reviewRequestTask: Task<Void, Never>?
    @State private var shareChipTask: Task<Void, Never>?
    @State private var tiltHintTask: Task<Void, Never>?
    @State private var showsTiltHint = false
    @State private var pendingCapacityCelebrations: [PendingStratumCelebration] = []
    @State private var breakOffer: BreakOffer?
    @State private var breakConfiguration: BreakRecoveryEnvelope?
    @State private var purchase = PurchaseManager.shared
    @State private var announcedPostDropOfferID: UUID?
    @State private var announcedPostDropShareOfferID: UUID?

    init() {
        _storedSubjects = Query(SubjectSyncPolicy.liveRowsDescriptor(sortBy: [
            SortDescriptor(\Subject.sortOrder),
            SortDescriptor(\Subject.syncRecordID)
        ]))
        _storedSubjectTombstones = Query(SubjectSyncPolicy.tombstoneRowsDescriptor())
        _storedSessions = Query(
            HomeProjectionPolicy.sessionChangeSentinelDescriptor()
        )
        _storedAchievementStones = Query(HomeProjectionPolicy.achievementCandidateDescriptor())
        _storedAggregates = Query(HomeProjectionPolicy.aggregateRootDescriptor())
        _storedStrata = Query(HomeProjectionPolicy.legacyCompatibilityDescriptor())
        _activityResetMarkers = Query(ActivityResetPolicy.currentMarkerDescriptor())
        _preferences = Query(PrefsConsumerPolicy.descriptor())
    }

    private var subjects: [Subject] {
        SubjectSyncPolicy.presentationSubjects(
            live: storedSubjects, tombstones: storedSubjectTombstones, context: modelContext
        )
    }
    private var activeSubjects: [Subject] { subjects.filter { !$0.isArchived } }
    private var resolvedPreferences: PrefsSyncPolicy.ResolvedState? {
        PrefsConsumerPolicy.resolvedState(
            in: preferences,
            markers: resetSnapshots
        )
    }
    private var sensoryPreferences: PrefsSyncPolicy.ResolvedSensoryState {
        PrefsConsumerPolicy.resolvedSensoryState(in: preferences)
    }
    private var rareRewardMode: RareRewardMode {
        guard RareRewardReleasePolicy.isEnabled else { return .off }
        return PrefsConsumerPolicy.rareRewardMode(from: resolvedPreferences)
    }
    private var manualCounterState: ManualCounterState {
        ManualCounterState(
            dayKey: resolvedPreferences?.manualDayKey ?? "",
            usedToday: resolvedPreferences?.manualUsedToday ?? 0
        )
    }
    private var homeAtmosphere: HomeAtmosphere {
        HomeAtmosphere.resolved(homeAtmosphereRawValue)
    }
    private var resetSnapshots: [ActivityResetSnapshot] {
        activityResetMarkers.map(\.policySnapshot)
    }
    private var currentActivityEpochID: UUID? {
        ActivityResetPolicy.currentEpochID(from: resetSnapshots)
    }
    private var sceneSessionSnapshotIsCurrent: Bool {
        guard hasLoadedSceneSessionSnapshot else { return false }
        if aggregateProjectionPresentation.isCloudVerificationPending {
            return aggregateProjectionPresentation.acceptsCurrentGenerationCache(
                supportedSessionBackfillStamp
            )
        }
        return aggregateProjectionPresentation.acceptsVerifiedAggregateCache(
            supportedSessionBackfillVerifiedStamp
        )
    }
    private var sessions: [StudySession] {
        // The raw @Query exists only as a bounded change trigger. Rendering
        // waits for the exact-ID backfill so a losing physical prefix can
        // never become Home mass or a jar body, even transiently.
        guard sceneSessionSnapshotIsCurrent else { return [] }
        return StudySessionSyncPolicy.canonicalSessions(
            from: supportedSessionBackfill + currentRewardSessionBackfill
        ).filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetSnapshots)
                && StudySessionIntegrityPolicy.isSupported($0)
        }
    }
    private var currentRewardSessionBackfill: [StudySession] {
        guard rewardSessionBackfillGeneration == HomeSceneSessionSnapshotGeneration(
            aggregateProjectionPresentation
        ) else { return [] }
        return rewardSessionBackfill.filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetSnapshots)
                && StudySessionIntegrityPolicy.isSupported($0)
        }
    }
    private var achievementCandidates: [AchievementStone] {
        storedAchievementStones.filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetSnapshots)
        }
    }
    private var achievementStones: [AchievementStone] {
        resolvedAchievementStones
    }
    private var currentAggregatePresentationPage:
        HomeProjectionPolicy.RefreshedAggregatePresentationPage? {
        guard let aggregatePresentationPage,
              aggregateProjectionPresentation.acceptsVerifiedAggregateCache(
                  aggregatePresentationPage.cacheStamp
              ) else {
            return nil
        }
        return aggregatePresentationPage
    }
    private var aggregates: [AggregatePebble] {
        currentAggregatePresentationPage?.aggregateRoots ?? []
    }
    private var strata: [Stratum] {
        currentAggregatePresentationPage?.legacyStrata ?? []
    }
    private var acceptedAggregateRootIDs: Set<UUID> {
        currentAggregatePresentationPage?.acceptedAggregateRootIDs ?? []
    }
    private var rootProjectionIsComplete: Bool {
        currentAggregatePresentationPage?.rootProjectionIsComplete ?? false
    }
    private var aggregateProjectionNeedsMaintenance: Bool {
        currentAggregatePresentationPage?
            .aggregateProjectionNeedsMaintenance ?? true
    }
    private var queriedLooseSessions: [StudySession] {
        StudySessionSyncPolicy.canonicalSessions(from: sessions).filter {
            !representedSessionIDs.contains($0.id)
        }
        .sorted { $0.endAt > $1.endAt }
    }
    private var looseSessions: [StudySession] {
        let rewardIDs = Set(currentRewardSessionBackfill.map(\.id))
        let candidates = queriedLooseSessions
        let rewards = candidates.filter { rewardIDs.contains($0.id) }
        let remaining = candidates.filter { !rewardIDs.contains($0.id) }
        return Array((rewards + remaining).prefix(HomeProjectionPolicy.looseSessionLimit))
            .sorted { $0.endAt > $1.endAt }
    }
    private var localProjectionNeedsMaintenance: Bool {
        !rootProjectionIsComplete
            || aggregateProjectionNeedsMaintenance
            || !localMembershipProjectionIsComplete
            || !sessionBackfillIsComplete
            || acceptedAggregateRootIDs.count
                != AggregatePebblePolicy.activeRoots(from: aggregates).count
            || queriedLooseSessions.count != looseSessions.count
    }
    private var projectionNeedsMaintenance: Bool {
        localProjectionNeedsMaintenance
            || aggregateProjectionPresentation.isCloudVerificationPending
    }
    /// Roots whose bounded recursive summary preflight succeeded. Membership
    /// conflicts are applied separately so the exact UUID scan can recover on
    /// the next store change instead of filtering its own input permanently.
    private var validatedAggregateRoots: [AggregatePebble] {
        guard aggregateProjectionPresentation.allowsAggregateSummaries else {
            return []
        }
        return AggregatePebblePolicy.activeRoots(from: aggregates).filter {
            acceptedAggregateRootIDs.contains($0.id)
        }
    }
    /// The newest validated aggregate is a useful large-store suffix horizon,
    /// but it is not proof that every earlier source row was aggregated. Home
    /// therefore keeps any horizon-backed loose projection explicitly
    /// incomplete until a durable maintenance-frontier certificate exists.
    private var verifiedAggregateSessionHorizon: Date? {
        guard aggregateProjectionPresentation.verifiedCacheStamp != nil else {
            return nil
        }
        return validatedAggregateRoots.map(\.periodEnd).max()
    }
    private var acceptedAggregateRoots: [AggregatePebble] {
        validatedAggregateRoots.filter {
            !conflictedAggregateRootIDs.contains($0.id)
        }
    }
    private var projectionTotals: HomeProjectionPolicy.Totals {
        HomeProjectionPolicy.totals(
            roots: acceptedAggregateRoots,
            looseSessions: looseSessions
        )
    }
    private var totalGrams: Int {
        projectionTotals.grams
    }
    private var totalPebbles: Int {
        projectionTotals.pebbleCount
    }
    private var activeAggregateRoots: [AggregatePebble] {
        acceptedAggregateRoots
    }
    private var activeLegacyStrata: [Stratum] {
        strata
    }
    private var activeLegacyStratumVisuals: [JarStratumVisual] {
        let modernIDs = Set(activeAggregateRoots.map(\.id))
        return JarStratumVisual.normalized(
            activeLegacyStrata.map(JarStratumVisual.init(stratum:))
        ).filter { !modernIDs.contains($0.id) }
    }
    private var latestInspectableAggregateID: UUID? {
        let candidates = activeAggregateRoots.map {
            (id: $0.id, date: $0.createdAt)
        } + activeLegacyStratumVisuals.map {
            (id: $0.id, date: $0.bakedAt)
        }
        return candidates.max { lhs, rhs in
            if lhs.date == rhs.date {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.date < rhs.date
        }?.id
    }
    private var aggregateInspectionSummary: AccumulationClusterSummary? {
        guard let aggregateInspectionID else { return nil }
        return inspectionSummary(for: aggregateInspectionID)
    }
    private var visibleGoldPebbleCount: Int {
        guard RareRewardReleasePolicy.isEnabled else { return 0 }
        let loose = RareRewardCounts.total(looseSessions.map(\.rareRewardCounts))
        return HomeProjectionPolicy.saturatingNonnegativeSum([
            HomeProjectionPolicy.saturatingNonnegativeSum(
                activeAggregateRoots.map(\.goldPebbleCount)
            ),
            loose.goldCount
        ])
    }
    private var visiblePrismPebbleCount: Int {
        guard RareRewardReleasePolicy.isEnabled else { return 0 }
        let loose = RareRewardCounts.total(looseSessions.map(\.rareRewardCounts))
        return HomeProjectionPolicy.saturatingNonnegativeSum([
            HomeProjectionPolicy.saturatingNonnegativeSum(
                activeAggregateRoots.map(\.prismPebbleCount)
            ),
            loose.prismCount
        ])
    }
    /// The optical lifetime core uses the exact accounting frontier rather
    /// than the currently selected subject. A long-lived person therefore sees
    /// the colour of their accumulated effort, while the launch button can
    /// still describe the next chosen theme independently.
    private var lifetimeCoreColorHex: String {
        var weights: [String: Double] = [:]

        for aggregate in activeAggregateRoots {
            let grams = Double(max(0, aggregate.grams))
            let mix = aggregate.colorMix.isEmpty
                ? [StratumColorFraction(
                    hex: aggregate.subjectMix.first?.colorHex
                        ?? selectedSubject?.colorHex
                        ?? Constants.Color.amberLamp,
                    fraction: 1
                )]
                : aggregate.colorMix
            for contribution in mix {
                weights[contribution.hex, default: 0] += grams * max(0, contribution.fraction)
            }
        }

        for session in looseSessions {
            weights[session.displaySubjectColorHex, default: 0] += Double(max(0, session.grams))
        }

        return weights.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }.first?.key ?? selectedSubject?.colorHex ?? Constants.Color.amberLamp
    }
    private var visibleAchievementStones: [AchievementStone] {
        AchievementStonePolicy.visibleStones(from: achievementStones)
    }
    private var uniqueAchievementCount: Int {
        max(projectedAchievementCount, Set(achievementStones.map(\.id)).count)
    }
    private var isJarEmpty: Bool {
        looseSessions.isEmpty
            && visibleAchievementStones.isEmpty
            && activeAggregateRoots.isEmpty
            && activeLegacyStrata.isEmpty
    }
    private var sessionChangeTokens: [StudySessionSyncPolicy.ChangeToken] {
        sessions.map(StudySessionSyncPolicy.changeToken(for:))
    }
    private var storedSessionChangeTokens: [StudySessionSyncPolicy.ChangeToken] {
        storedSessions.map(StudySessionSyncPolicy.changeToken(for:))
    }
    private var stratumChangeTokens: [String] {
        storedStrata.map(LegacyStratumPresentationChangeFingerprint.value(for:))
    }
    private var aggregateChangeTokens: [String] {
        storedAggregates.map(AggregateProjectionChangeFingerprint.value(for:))
    }
    private var achievementChangeTokens: [String] {
        storedAchievementStones.map {
            [
                $0.id.uuidString,
                $0.dataEpochID?.uuidString ?? "legacy",
                String($0.revision),
                String($0.deletedAt?.timeIntervalSinceReferenceDate ?? -1),
                String($0.updatedAt.timeIntervalSinceReferenceDate),
                $0.kind.rawValue,
                $0.note,
                $0.achievedAt.timeIntervalSinceReferenceDate.description,
                $0.displaySubjectName,
                $0.displaySubjectColorHex
            ].joined(separator: "-")
        }
    }
    private var sensoryChangeTokens: [String] {
        preferences.map {
            PrefsConsumerPolicy.fingerprint(for: $0)
        }
    }
    private var celebrationPresentationBlockers: [Bool] {
        [
            showHomeMenu,
            showAccumulationOverview,
            selectedAggregateDetail != nil,
            showManualEntry,
            showAchievementEntry,
            showCustomDuration,
            breakOffer != nil,
            breakOfferTask != nil,
            rewardDropDestination != nil,
            hasPendingRewardReceipt,
            focusConfiguration != nil,
            breakConfiguration != nil,
            router.paywallPresented,
            router.sharePresented,
            router.recoveredFocus != nil,
            router.recoveredBreak != nil,
            isDeferringCelebrationsForShare,
            aggregateProjectionPresentation.isCloudVerificationPending,
            isDeferringStratumForCloudVerification
        ]
    }
    private var canPresentStratumCelebration: Bool {
        !celebrationPresentationBlockers.contains(true)
    }
    private var hasPendingRewardReceipt: Bool {
        !PendingRewardReceiptStore.load().isEmpty
    }
    private var rewardDropSurfaceIsObscured: Bool {
        showHomeMenu || showAccumulationOverview || selectedAggregateDetail != nil
            || showManualEntry || showAchievementEntry || showCustomDuration
            || showAccumulationPlan || completedStratum != nil
            || breakConfiguration != nil || router.recoveredBreak != nil
            || router.paywallPresented || router.sharePresented
            || router.selectedTab != .jar
    }
    private var selectedSubject: Subject? {
        activeSubjects.first { $0.id.uuidString == selectedSubjectID } ?? activeSubjects.first
    }

    var body: some View {
        observedContent
    }

    private var mainContent: some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(spacing: 0) {
                    jarCard(height: homeJarHeight(availableHeight: proxy.size.height))
                        .id("home.jar")
                    if latestInspectableAggregateID != nil {
                        aggregateInspectionSlot
                            .padding(.top, 8)
                    }
                    if let state = largeTextFusionProgressState {
                        Spacer(minLength: 12)
                        largeTextFusionProgressCard(state)
                    }
                    Spacer(minLength: 14)
                    if !activeSubjects.isEmpty {
                        focusSelectionControls
                            .padding(.bottom, 10)
                    }
                    focusLauncher
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 20)
                .frame(
                    maxWidth: homeContentMaxWidth,
                    minHeight: dynamicTypeSize.isAccessibilitySize ? nil : proxy.size.height,
                    alignment: .top
                )
#if targetEnvironment(macCatalyst)
                .frame(maxWidth: .infinity, alignment: .top)
#endif
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: rewardDropRevealRequestID) { _, requestID in
                guard requestID != nil else { return }
                withAnimation(
                    reduceMotion ? nil : .easeOut(duration: 0.3),
                    completionCriteria: .removed
                ) {
                    scrollProxy.scrollTo("home.jar", anchor: .top)
                } completion: {
                    rewardDropRevealIsPending = false
                    syncScene()
                }
            }
            }
        }
        .background {
            HomeAtmosphereBackground(
                atmosphere: homeAtmosphere,
                accent: homeAtmosphere.ambientAccent
            )
            .id(homeAtmosphere.id)
            .transition(.opacity)
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.38),
            value: homeAtmosphere
        )
        .safeAreaInset(edge: .bottom, spacing: 8) {
            if breakOffer != nil || router.deferredFocusRecovery != nil {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        // A bottom inset taller than the viewport grows upward
                        // behind the status bar. Bound it and give the result
                        // its own scroll surface so the heading and all safe
                        // exits begin below the persistent menu.
                        ScrollView {
                            completionInsetContents
                        }
                        .frame(maxHeight: 620)
                        .scrollIndicators(.visible)
                    } else {
                        completionInsetContents
                    }
                }
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity)
                )
            }
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86),
            value: breakOffer?.id
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                homeMenu
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var presentedContent: some View {
        mainContent
        .fullScreenCover(item: $focusConfiguration, onDismiss: {
            router.completeFocusPresentation()
            syncScene()
            continueRewardDropIfPossible()
            recoverPendingRewardReceipt()
        }) { configuration in
            CloudConnectionSessionContent {
                FocusView(
                    subject: configuration.subject,
                    duration: configuration.duration,
                    sessionID: configuration.id,
                    dataEpochID: configuration.dataEpochID
                )
            }
            .environment(\.dynamicTypeSize, dynamicTypeSize)
        }
        .fullScreenCover(item: $breakConfiguration, onDismiss: {
            recoverPendingRewardReceipt()
        }) { configuration in
            CloudConnectionSessionContent { BreakTimerView(recovery: configuration) }
                .environment(\.dynamicTypeSize, dynamicTypeSize)
        }
        .sheet(isPresented: $showHomeMenu) {
            homeMenuSheet
                .presentationDetents(auxiliarySheetDetents)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAccumulationOverview) {
            accumulationOverviewSheet
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedAggregateDetail) { cluster in
            ClusterDetailSheet(cluster: cluster)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showManualEntry) {
            ManualEntrySheet(
                subject: selectedSubject,
                counterState: manualCounterState,
                onAdd: addManualEntry
            )
                .presentationDetents(auxiliarySheetDetents)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAchievementEntry) {
            AchievementEntrySheet(
                initialSubject: selectedSubject,
                subjects: activeSubjects,
                onAdd: addAchievementStone
            )
                .presentationDetents(auxiliarySheetDetents)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCustomDuration) {
            CustomDurationView(
                initialSeconds: selectedDuration.seconds,
                onConfirm: confirmCustomDuration
            )
                .environment(\.dynamicTypeSize, dynamicTypeSize)
                .presentationDetents(customDurationSheetDetents)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAccumulationPlan) {
            AccumulationPlanView()
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $completedStratum, onDismiss: finishPresentedStratumCelebration) { request in
            stratumCelebrationSheet(request)
        }
    }

    @ViewBuilder
    private var accumulationOverviewSheet: some View {
        let content = AccumulationOverviewLoader(
            resetMarkers: resetSnapshots,
            lifetimeGrams: totalGrams,
            lifetimePebbleCount: totalPebbles,
            lifetimeIsLowerBound: localProjectionNeedsMaintenance,
            projectionPresentation: aggregateProjectionPresentation,
            initialClusterID: overviewInitialClusterID
        )
#if DEBUG && targetEnvironment(simulator)
        // A sheet owns a separate presentation host. Forward the pinned AX5
        // UI-test value explicitly so this audit exercises the accessibility
        // layout rather than the ordinary segmented-control layout.
        if LocalPreviewLaunchPolicy.forcesAccessibility5(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: true
        ) {
            content.environment(\.dynamicTypeSize, .accessibility5)
        } else {
            content
        }
#else
        content
#endif
    }

    private var auxiliarySheetDetents: Set<PresentationDetent> {
        if dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact {
            return [.large]
        }
        return [.medium, .large]
    }

    private var customDurationSheetDetents: Set<PresentationDetent> {
        [.large]
    }

    private var lifecycleContent: some View {
        presentedContent
        .onAppear {
            homeIsVisible = true
            rewardDropRevealIsPending = false
            restorePreferredDuration()
            configureScene()
            screenTime.reload()
            scene.setScreenTimeObstacles(totalUnits: screenTime.negativeGemCount)
            noteScreenTimeBlackStones(ScreenTimeController.shared.negativeGemCount)
            refreshAcceptedAggregateRoots()
            refreshAchievementProjection()
            refreshAchievementCount()
            syncScene()
            continueRewardDropIfPossible()
            recoverPendingRewardReceipt()
            recoverPendingStratumCelebrations()
            recoverInterruptionNotice()
            scheduleTiltHintIfNeeded()
            schedulePendingReviewRequestIfPossible()
            refreshSupportedSessionBackfill()
        }
        .onDisappear {
            homeIsVisible = false
            widgetRefreshTask?.cancel()
            celebrationRecoveryTask?.cancel()
            capacityCelebrationTask?.cancel()
            breakOfferTask?.cancel()
            breakOfferTask = nil
            reviewRequestTask?.cancel()
            shareChipTask?.cancel()
            aggregateInspectionTask?.cancel()
            aggregateInspectionTask = nil
            aggregateInspectionID = nil
            pendingCapacityCelebrations.removeAll()
            tiltHintTask?.cancel()
            tiltHintTask = nil
            sessionBackfillTask?.cancel()
            sessionBackfillTask = nil
            showsTiltHint = false
            capacityRemaining = nil
            clearSceneCallbacks()
        }
        .onChange(of: router.focusPresentationIsActive) { _, isActive in
            guard !isActive else { return }
            configureScene()
            syncScene()
            continueRewardDropIfPossible()
            recoverPendingRewardReceipt()
        }
        .onChange(of: rewardDropSurfaceIsObscured) { _, isObscured in
            guard !isObscured else { return }
            syncScene()
            continueRewardDropIfPossible()
            recoverPendingRewardReceipt()
        }
    }

    private var observedContent: some View {
        lifecycleContent
        .onChange(of: screenTime.negativeGemCount) { _, count in
            guard homeIsVisible else { return }
            scene.updateScreenTimeObstacles(totalUnits: count)
            noteScreenTimeBlackStones(count)
        }
        .onChange(of: sessionChangeTokens) { _, _ in
            syncScene()
            scheduleTiltHintIfNeeded()
        }
        .onChange(of: storedSessionChangeTokens) { _, _ in
            refreshSupportedSessionBackfill()
        }
        .onChange(of: achievementChangeTokens) { _, _ in
            refreshAchievementProjection()
            refreshAchievementCount()
            syncScene()
        }
        .onChange(of: aggregateChangeTokens) { _, _ in
            refreshAcceptedAggregateRoots()
            syncScene()
            reconcileAggregateInspection()
            scheduleTiltHintIfNeeded()
        }
        .onChange(of: aggregateProjectionPresentation) { _, presentation in
            if presentation.isCloudVerificationPending {
                invalidateAggregateInspection()
                deferPresentedStratumForCloudVerification()
                discardAggregateCelebrationSnapshotsForInvalidation()
            }
            refreshAcceptedAggregateRoots()
            refreshSupportedSessionBackfill()
            if !presentation.isCloudVerificationPending {
                recoverPendingStratumCelebrations()
            }
            syncScene()
            scheduleTiltHintIfNeeded()
        }
        .onChange(of: stratumChangeTokens) { _, _ in
            refreshAcceptedAggregateRoots()
            syncScene()
            reconcileAggregateInspection()
        }
        .onChange(of: purchase.isPro) { _, isPro in
            if isPro {
                restorePreferredDuration()
            } else if selectedDuration.requiresPro {
                selectedDuration = .twentyFiveMinutes
            }
            syncBaseLayers()
        }
        .onChange(of: router.homeCustomDurationResumeRequested) { _, requested in
            guard requested else { return }
            resumeCustomDurationAfterPurchaseIfNeeded()
        }
        .onChange(of: sensoryChangeTokens) { _, _ in
            applySensoryPreferences()
            restorePreferredDuration()
        }
        .onChange(of: reduceMotion) { _, _ in
            cancelTiltHintPresentation()
            scheduleTiltHintIfNeeded()
        }
        .onChange(of: voiceOverEnabled) { _, enabled in
            cancelTiltHintPresentation()
            scheduleTiltHintIfNeeded()
            guard enabled, let offer = breakOffer else { return }
            announcePostDropOfferIfNeeded(for: offer)
        }
        .onChange(of: breakOffer?.id) { _, offerID in
            guard let offer = breakOffer, offer.id == offerID else { return }
            announcePostDropOfferIfNeeded(for: offer)
        }
        .onChange(of: showShareChip) { _, isVisible in
            guard isVisible, let offer = breakOffer else { return }
            announcePostDropShareIfNeeded(for: offer)
        }
        .onChange(of: celebrationPresentationBlockers) { _, blockers in
            guard !blockers.contains(true) else { return }
            presentNextStratumCelebrationIfNeeded()
            schedulePendingReviewRequestIfPossible()
        }
        .onChange(of: router.sharePresented) { _, isPresented in
            guard !isPresented else { return }
            recoverPendingRewardReceipt()
            if isDeferringCelebrationsForShare {
                isDeferringCelebrationsForShare = false
                presentNextStratumCelebrationIfNeeded()
            }
        }
    }

    private func stratumCelebrationSheet(_ request: PendingStratumCelebration) -> some View {
        StratumCelebrationView(
            request: request,
            showsMonthLabel: purchase.isPro,
            onExplore: exploreCompletedStratum,
            onShare: { shareCompletedStratum(request) },
            onContinue: dismissCompletedStratum
        )
        // A decimal carry is secondary, lossless storage maintenance. Open it
        // at full height so the organization result and mass-preservation
        // promise remain readable; study value advances separately by mass.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func jarCard(height: CGFloat) -> some View {
        ZStack {
            JarSpriteView(
                scene: scene,
                totalGrams: totalGrams,
                pebbleCount: looseSessions.count,
                achievementCount: uniqueAchievementCount,
                aggregateCount: activeAggregateRoots.count,
                legacyAggregateCount: activeLegacyStratumVisuals.count,
                representedPebbleCount: totalPebbles,
                goldPebbleCount: visibleGoldPebbleCount,
                prismPebbleCount: visiblePrismPebbleCount,
                accentHex: selectedSubject?.colorHex ?? Constants.Color.amberLamp,
                lifetimeCoreColorHex: lifetimeCoreColorHex,
                projectionIsLowerBound: localProjectionNeedsMaintenance,
                projectionIsUnverified:
                    aggregateProjectionPresentation.isCloudVerificationPending,
                fusionProgressDescription: fusionAccessibilityDescription,
                isMotionEnabled: homeJarMotionIsEnabled,
                inspectableAggregateID: latestInspectableAggregateID,
                onJarTapAccepted: invalidateAggregateInspectionCard,
                onAggregateTapped: revealAggregateInspection,
                onAggregateAccessibilityAction: presentAggregateDetail
            )
                .padding(.horizontal, 4)

            jarMetricHUD

            if isJarEmpty {
                emptyJarMessage
                .multilineTextAlignment(.center)
                .padding(20)
                .frame(maxWidth: 320)
                // The metrics keep a fixed position below the bottle's rim.
                // On a short canvas, move the empty-state copy below them.
                .offset(y: max(0, 456 - height) / 2)
            }

            if let remaining = capacityRemaining, remaining <= 15 {
                VStack {
                    HStack(spacing: 7) {
                        Image(systemName: "circle.grid.2x2.fill")
                        Text(remaining == 0 ? "まとまり粒をつくっています" : "あと\(remaining)%で、下の粒がひとつにまとまる")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PomoGemTheme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay { Capsule().stroke(PomoGemTheme.amber.opacity(0.28), lineWidth: 1) }
                    .padding(.top, 188)
                    Spacer()
                }
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .top).combined(with: .opacity)
                )
                .allowsHitTesting(false)
            }

            if failedAggregateRequest != nil {
                VStack {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                            .foregroundStyle(PomoGemTheme.amber)
                            .accessibilityHidden(true)
                        Text("まとまり粒は未保存です")
                            .font(.caption.weight(.bold))
                        Spacer(minLength: 4)
                        Button("保存を再試行") {
                            retryFailedAggregatePersistence()
                        }
                        .buttonStyle(PomoGemCompactButtonStyle())
                        .accessibilityIdentifier("jar.aggregate.persistence.retry")
                    }
                    .foregroundStyle(PomoGemTheme.text)
                    .padding(.leading, 13)
                    .padding(.trailing, 7)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule().stroke(PomoGemTheme.amber.opacity(0.38), lineWidth: 1)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 188)
                    Spacer()
                }
                .transition(.opacity)
            }

            if aggregateInspectionSummary == nil, showsTiltHint, !isJarEmpty {
                VStack {
                    Spacer()
                    Label(
                        jarInteractionHintText,
                        systemImage: jarInteractionHintSymbol
                    )
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PomoGemTheme.text)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay {
                            Capsule().stroke(PomoGemTheme.glassEdge.opacity(0.2), lineWidth: 1)
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 18)
                }
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .bottom))
                )
                // `JarSpriteView` exposes the same guidance as a persistent
                // accessibility hint. Keep this transient visual hint out of
                // the VoiceOver order so it is not spoken twice.
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }

#if DEBUG
            if LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess {
                JarUITestPresentationProbe(scene: scene)
            }
#endif
#if DEBUG && targetEnvironment(simulator)
            if FortyYearPersistentUITestFixture.isActiveForCurrentProcess {
                FortyYearPersistentFixtureProbe(
                    scene: scene,
                    grams: totalGrams,
                    rootCount: activeAggregateRoots.count,
                    looseCount: looseSessions.count,
                    // This is the recent local-change sentinel, not a lifetime
                    // row count. Named-store fault scenarios contain at most
                    // ten recent rows, so duplicate inserts remain observable
                    // without forcing the 40-year source table to sort.
                    sessionRowCount: storedSessions.count,
                    uniqueSessionIDCount: Set(storedSessions.map(\.id)).count
                )
            }
            if UITestFaultInjection.isAggregatePersistenceSaveFailureEnabled() {
                AggregatePersistenceRecoveryProbe()
            }
#endif

        }
        .frame(height: height)
    }

    /// SwiftUI keeps presenting views mounted behind sheets. The jar owns the
    /// device sensor only while Home is actually frontmost so a hidden bottle
    /// cannot answer the same shake as a planning preview (or make noise under
    /// an unrelated sheet).
    private var homeJarMotionIsEnabled: Bool {
        router.selectedTab == .jar
            && focusConfiguration == nil
            && breakConfiguration == nil
            && !showHomeMenu
            && !showAccumulationOverview
            && selectedAggregateDetail == nil
            && !showManualEntry
            && !showAchievementEntry
            && !showCustomDuration
            && !showAccumulationPlan
            && completedStratum == nil
            && !router.paywallPresented
            && !router.sharePresented
            && router.recoveredFocus == nil
            && router.recoveredBreak == nil
            && router.cloudFocusRecoveryOffer == nil
    }

    private var jarMetricHUD: some View {
        VStack(spacing: 3) {
            Text("積み上げた集中")
                // This HUD is decorative and excluded from VoiceOver. Keep it
                // inside the fixed SpriteKit canvas at accessibility sizes;
                // the jar's accessibility value carries the same information.
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.1)
                .textCase(.uppercase)
                .foregroundStyle(Color.white.opacity(0.68))

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(homeMassValue)
                    .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 28 : 39, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(homeMassUnit)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
            }

            VStack(spacing: 4) {
                jarMetricPill(jarMetricSummary)
                if aggregateProjectionPresentation.isCloudVerificationPending {
                    Text(isCloudOfflineSession ? "このiPhoneの集計を確認中" : "iCloudを再確認中")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.68))
                }
                if showsPreFusionRail {
                    preFusionRail
                }
            }
        }
        // Keep every glyph behind the mouth instead of straddling its bright
        // rim; the occlusion cue is what makes the glass depth believable.
        .padding(.top, 88)
        .frame(maxHeight: .infinity, alignment: .top)
        .shadow(color: .black.opacity(0.52), radius: 3, y: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var homeMassValue: String {
        let verifiedValue: String
        if totalGrams < 1_000 {
            verifiedValue = totalGrams.formatted()
        } else {
            verifiedValue = (Double(totalGrams) / 1_000).formatted(
                .number.precision(.fractionLength(1 ... 2))
            )
        }
        return AggregateProjectionPresentationPolicy.homeMassValue(
            verifiedValue: verifiedValue,
            context: aggregateProjectionPresentation
        )
    }

    private var homeMassUnit: String {
        let unit = totalGrams < 1_000 ? "g" : "kg"
        return AggregateProjectionPresentationPolicy.homeMassUnit(
            verifiedUnit: unit,
            hasLocalLowerBound: localProjectionNeedsMaintenance,
            context: aggregateProjectionPresentation
        )
    }

    private var jarMetricSummary: String {
        let milestones = uniqueAchievementCount > 0 ? " ・ 記念石 \(achievementCountLabel)" : ""
        return AggregateProjectionPresentationPolicy.homeCountSummary(
            count: totalPebbles,
            milestoneSuffix: milestones,
            hasLocalLowerBound: localProjectionNeedsMaintenance,
            context: aggregateProjectionPresentation
        )
    }

    private var homeMenuMassValue: String {
        aggregateProjectionPresentation.isCloudVerificationPending
            ? "再集計中"
            : formattedMass(totalGrams)
    }

    private var homeMenuCountValue: String {
        aggregateProjectionPresentation.isCloudVerificationPending
            ? "確認済み \(totalPebbles)粒"
            : "\(totalPebbles)粒"
    }

    private var homeMenuAccessibilitySummary: String {
        if aggregateProjectionPresentation.isCloudVerificationPending {
            let status = isCloudOfflineSession ? "このiPhoneの累計を確認中" : "iCloudの累計を再集計中"
            return "\(status)。この端末で確認済みの集中\(totalPebbles)粒、成果\(achievementCountLabel)個"
        }
        return "累計\(formattedMass(totalGrams))、集中\(totalPebbles)粒、成果\(achievementCountLabel)個"
    }

    private var projectionVerificationTitle: String {
        isCloudOfflineSession ? "このiPhoneの集計を確認中" : "iCloudを再集計中"
    }

    private var effortProgressSnapshot: EffortProgressSnapshot {
        EffortProgressPolicy.snapshot(totalGrams: totalGrams)
    }

    private var showsPreFusionRail: Bool {
        !projectionNeedsMaintenance
            && totalPebbles > 0
            && !JarLifetimeCorePresentation.shouldShowCore(
                totalPebbleCount: totalPebbles,
                totalGrams: totalGrams
            )
    }

    private var preFusionRail: some View {
        let state = effortProgressSnapshot
        return VStack(spacing: 5) {
            ProgressView(value: state.progressFraction)
                .tint(Color(hex: lifetimeCoreColorHex))
                .frame(width: 118)
            Text(
                "時間 \(EffortProgressPresentation.formattedDuration(grams: state.displayedProgressGrams)) / \(EffortProgressPresentation.formattedDuration(grams: state.displayedTargetGrams))"
            )
                .font(.system(size: 9, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.72))
            Text("25分 = 1.0標準単位")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.58))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(PomoGemTheme.raised.opacity(0.62), in: Capsule())
        .overlay {
            Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.7)
        }
        .accessibilityHidden(true)
    }

    private var fusionAccessibilityDescription: String? {
        guard !aggregateProjectionPresentation.isCloudVerificationPending,
              totalPebbles > 0 || localProjectionNeedsMaintenance
        else { return nil }
        guard let state = JarLifetimeCorePresentation.state(
            totalPebbleCount: totalPebbles,
            totalGrams: totalGrams,
            projectionIsLowerBound: localProjectionNeedsMaintenance
        ) else { return nil }
        var components = [state.progressLabel, state.nextFusionLabel]
            .compactMap { $0 }
        if let physicalState = JarLifetimeCorePresentation.state(
            totalPebbleCount: totalPebbles,
            projectionIsLowerBound: localProjectionNeedsMaintenance
        ) {
            let physical = [physicalState.progressLabel, physicalState.nextFusionLabel]
                .compactMap { $0 }
                .joined(separator: "、")
            components.append("瓶の物理整理：\(physical)")
        }
        return components.joined(separator: "、")
    }

    private var largeTextFusionProgressState: JarLifetimeCoreState? {
        guard dynamicTypeSize.isAccessibilitySize,
              !aggregateProjectionPresentation.isCloudVerificationPending,
              JarLifetimeCorePresentation.shouldShowCore(
                totalPebbleCount: totalPebbles,
                totalGrams: totalGrams
              )
        else { return nil }
        return JarLifetimeCorePresentation.state(
            totalPebbleCount: totalPebbles,
            totalGrams: totalGrams,
            projectionIsLowerBound: localProjectionNeedsMaintenance
        )
    }

    private func largeTextFusionProgressCard(
        _ state: JarLifetimeCoreState
    ) -> some View {
        PomoGemCard {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "hourglass.bottomhalf.filled")
                    .font(.title2.weight(.black))
                    .foregroundStyle(Color(hex: lifetimeCoreColorHex))
                    .frame(width: 44, height: 44)
                    .background(
                        Color(hex: lifetimeCoreColorHex).opacity(0.13),
                        in: Circle()
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("時間の核の進み")
                        .font(.headline)
                        .foregroundStyle(PomoGemTheme.text)
                    Text(state.progressLabel)
                        .font(.system(.title3, design: .rounded, weight: .black))
                        .monospacedDigit()
                        .foregroundStyle(PomoGemTheme.text)
                    if let nextFusionLabel = state.nextFusionLabel {
                        Text(nextFusionLabel)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("home.fusion-progress.large-text")
        .accessibilityLabel(
            ["時間の核の進み", state.progressLabel, state.nextFusionLabel]
                .compactMap { $0 }
                .joined(separator: "、")
        )
    }

    private func jarMetricPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(PomoGemTheme.text.opacity(0.86))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(PomoGemTheme.raised.opacity(0.72), in: Capsule())
            .overlay {
                Capsule().stroke(PomoGemTheme.glassEdge.opacity(0.15), lineWidth: 1)
            }
    }

    private var achievementCountLabel: String {
        "\(uniqueAchievementCount)\(achievementCountIsLowerBound ? "+" : "")"
    }

    @ViewBuilder
    private var emptyJarMessage: some View {
        if aggregateProjectionPresentation.isCloudVerificationPending {
            VStack(spacing: 8) {
                ProgressView()
                    .tint(PomoGemTheme.amber)
                    .accessibilityHidden(true)
                Text(projectionVerificationTitle)
                    .font(.headline.weight(.bold))
                Text("この端末で確認できた記録だけを表示しています。")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(projectionVerificationTitle)。この端末で確認できた記録だけを表示しています"
            )
        } else if dynamicTypeSize.isAccessibilitySize {
            // The bottle is a fixed visual canvas. At accessibility text sizes,
            // keep its message short and move the actionable detail to the
            // scrollable launcher immediately below it.
            VStack(spacing: 10) {
                Text("まだ空っぽ")
                    .font(.title3.weight(.bold))
                Image(systemName: "arrow.down")
                    .font(.title3.weight(.bold))
                    .accessibilityHidden(true)
                Text("下のボタンへ")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PomoGemTheme.amber)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                selectedSubject == nil
                    ? "瓶はまだ空です。下のボタンからテーマを追加できます"
                    : "瓶はまだ空です。下のボタンから最初の集中を始められます"
            )
        } else {
            VStack(spacing: 7) {
                Text(Constants.UIStrings.jarEmptyTitle)
                    .font(PomoGemTheme.brand(21))
                Text(
                    selectedSubject == nil
                        ? "下のボタンから、最初のテーマを追加しよう。"
                        : "\(focusDurationLabel)の集中で、ここにひと粒落ちる。"
                )
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
            }
        }
    }

    private func homeJarHeight(availableHeight: CGFloat) -> CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return 520
        }
        // Reserve room for the visible theme/time controls and start button,
        // including on compact iPhones. Larger text keeps a scrollable canvas.
        let inspectionHeight: CGFloat = latestInspectableAggregateID == nil ? 0 : 72
        return min(520, max(320, availableHeight - 216 - inspectionHeight))
    }

    private var homeContentMaxWidth: CGFloat {
#if targetEnvironment(macCatalyst)
        return 720
#else
        return .infinity
#endif
    }

    private var focusSelectionControls: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    homeSubjectPicker
                    homeDurationPicker
                }
            } else {
                HStack(spacing: 10) {
                    homeSubjectPicker
                    homeDurationPicker
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    private var homeSubjectPicker: some View {
        Menu {
            subjectSelectionActions
            Divider()
            Button {
                router.selectedTab = .settings
            } label: {
                Label("テーマを管理", systemImage: "slider.horizontal.3")
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: selectedSubject?.colorHex ?? Constants.Color.amberLamp))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(selectedSubject?.safeDisplayName ?? "テーマを選ぶ")
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .accessibilityHidden(true)
            }
            .font(.system(.subheadline, design: .rounded, weight: .bold))
            .foregroundStyle(PomoGemTheme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(PomoGemTheme.raised.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityLabel("テーマ、\(selectedSubject?.safeDisplayName ?? "未選択")")
        .accessibilityHint("テーマを変更できます。タイマーは開始しません")
        .accessibilityIdentifier("home.subject-picker")
    }

    private var homeDurationPicker: some View {
        Menu {
            Section("無料の集中タイマー") {
                ForEach(PomodoroDuration.freePresets, id: \.self) { duration in
                    homeDurationOption(duration)
                }
            }
            Button(action: requestCustomDuration) {
                Label(
                    purchase.isPro ? "自由な時間を設定" : "自由な時間を設定（Pro）",
                    systemImage: purchase.isPro ? "slider.horizontal.3" : "lock"
                )
            }
#if DEBUG
            if LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess {
                Button("12秒、DEMO") {
                    selectDuration(.demo)
                }
            }
#endif
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .accessibilityHidden(true)
                Text(focusDurationLabel)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .accessibilityHidden(true)
            }
            .font(.system(.subheadline, design: .rounded, weight: .bold))
            .foregroundStyle(PomoGemTheme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(PomoGemTheme.raised.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityLabel("集中時間、\(focusDurationLabel)")
        .accessibilityHint("時間を変更できます。25分、45分、60分、90分は無料です")
        .accessibilityIdentifier("home.duration-picker")
    }

    private func homeDurationOption(_ duration: PomodoroDuration) -> some View {
        Button {
            selectDuration(duration)
        } label: {
            let title = duration.displayLabel
            if selectedDuration == duration {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var focusLauncher: some View {
        Button {
            if selectedSubject == nil {
                router.selectedTab = .settings
            } else {
                startFocus(duration: selectedDuration)
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.22))
                    Circle()
                        .stroke(.white.opacity(0.28), lineWidth: 1)
                    Image(systemName: selectedSubject == nil ? "plus" : "play.fill")
                        .font(.system(size: 18, weight: .black))
                        .offset(x: selectedSubject == nil ? 0 : 1)
                }
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedSubject == nil ? "テーマを選んではじめる" : "\(focusDurationLabel)、集中する")
                        .font(.system(.title3, design: .rounded, weight: .black))
                        .lineLimit(2)
                    Text(
                        selectedSubject == nil
                            ? "勉強も仕事も、同じ一覧で"
                            : "\(selectedSubject?.safeDisplayName ?? "選択中のテーマ") ・ 完走で+\(selectedDuration.grams)g"
                    )
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .lineLimit(2)
                }

                Spacer(minLength: 4)

                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "arrow.right")
                        .font(.system(.body, design: .rounded, weight: .black))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.18), in: Circle())
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(
            PomoGemHeroButtonStyle(
                tintHex: selectedSubject?.colorHex ?? Constants.Color.amberLamp
            )
        )
        .accessibilityLabel(
            selectedSubject == nil
                ? "テーマを選んではじめる"
                : "\(selectedSubject?.safeDisplayName ?? "選択中のテーマ")を\(focusDurationLabel)集中する、完走で\(selectedDuration.grams)グラム"
        )
        .accessibilityHint(focusActionAccessibilityHint)
        .accessibilityIdentifier("home.focus-launcher")
        .disabled(breakOffer != nil || breakOfferTask != nil || hasPendingRewardReceipt)
        .padding(.bottom, 8)
    }

    private var focusActionAccessibilityHint: String {
        if breakOffer != nil || breakOfferTask != nil {
            return "休憩の選択を終えると使えます"
        }
        if hasPendingRewardReceipt {
            return "積み上げ結果を閉じると使えます"
        }
        return selectedSubject == nil
            ? "設定画面を開きます"
            : "タイマーを開始します。上のテーマと時間のボタンで内容を変更できます"
    }

    private var focusDurationLabel: String {
#if DEBUG
        if selectedDuration == .demo { return "12秒" }
#endif
        return selectedDuration.displayLabel
    }

    private var homeMenu: some View {
        Button {
            showHomeMenu = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                Text("メニュー")
            }
                // Make the scaling contract explicit. XCTest's Dynamic Type
                // audit treats a compound Label-style Button conservatively;
                // ScaledMetric proves this text changes with the user's size.
                .font(.system(size: homeMenuFontSize, weight: .bold, design: .rounded))
                .frame(minHeight: 44)
                .foregroundStyle(PomoGemTheme.amber)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("メニュー")
        .accessibilityHint("記録、設定、背景、手動追加などを開きます")
    }

    private var homeMenuSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    menuAtmospherePicker
                    menuAccumulationActions
                    menuAccumulationPlanAction
                    menuHistoryActions
                    menuSettingsAction
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(NightBackground())
            .navigationTitle("メニュー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PomoGemSheetCloseButton(
                        accessibilityLabel: "メニューを閉じる",
                        accessibilityIdentifier: "home.menu.close"
                    ) {
                        showHomeMenu = false
                    }
                }
            }
        }
    }

    private var menuAtmospherePicker: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        SectionEyebrow(text: "SPACE")
                        Text("集中する空間")
                            .font(PomoGemTheme.brand(21))
                    }
                    Spacer()
                }

                Text(
                    dynamicTypeSize.isAccessibilitySize
                        ? "テーマの色はそのままに、\n背景の空気だけを変えます。"
                        : "テーマの色はそのままに、背景の空気だけを変えます。"
                )
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, dynamicTypeSize.isAccessibilitySize ? 8 : 0)

                LazyVGrid(
                    columns: dynamicTypeSize.isAccessibilitySize
                        ? [GridItem(.flexible())]
                        : [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 10
                ) {
                    ForEach(HomeAtmosphere.allCases) { atmosphere in
                        atmosphereButton(atmosphere)
                    }
                }
            }
        }
    }

    private func atmosphereButton(_ atmosphere: HomeAtmosphere) -> some View {
        let isSelected = homeAtmosphere == atmosphere

        return Button {
            guard homeAtmosphere != atmosphere else { return }
            homeAtmosphereRawValue = atmosphere.rawValue
            if sensoryPreferences.hapticsOn {
                Haptics.shared.playSecondaryCollision()
            }
        } label: {
            HStack(alignment: .bottom, spacing: 8) {
                Image(systemName: atmosphere.systemImage)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.ultraThinMaterial, in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(atmosphere.title)
                        .font(.system(size: atmosphereTitleFontSize, weight: .bold, design: .rounded))
                        .accessibilityHidden(true)
                    Text(atmosphere.subtitle)
                        .font(.system(size: atmosphereSubtitleFontSize))
                        .foregroundStyle(.white)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .accessibilityHidden(true)
                }

                Spacer(minLength: 2)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(PomoGemTheme.amber)
                        .accessibilityHidden(true)
                }
            }
            .padding(10)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            .frame(height: atmosphereCardHeight, alignment: .bottomLeading)
            .background {
                // Artwork decorates the common card size without contributing
                // its intrinsic image dimensions to the grid's row height.
                atmospherePreview(atmosphere)
                    .overlay {
                        LinearGradient(
                            colors: [.clear, Color.black.opacity(0.74)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(
                        isSelected ? PomoGemTheme.amber.opacity(0.72) : PomoGemTheme.glassEdge.opacity(0.12),
                        lineWidth: isSelected ? 1.4 : 1
                    )
            }
            .shadow(
                color: Color(hex: atmosphere.paletteHexes.last ?? "FFFFFF").opacity(isSelected ? 0.24 : 0.08),
                radius: isSelected ? 12 : 6,
                y: 5
            )
            .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(PomoGemRowButtonStyle(cornerRadius: 17))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(atmosphere.title)、\(atmosphere.subtitle)")
        .accessibilityIdentifier("home.atmosphere.\(atmosphere.rawValue)")
        // `.ignore` consolidates the decorative preview into one VoiceOver
        // target, so restore the interactive role that SwiftUI otherwise drops.
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func atmospherePreview(_ atmosphere: HomeAtmosphere) -> some View {
        ZStack {
            LinearGradient(
                colors: atmosphere.paletteHexes.map { Color(hex: $0) },
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if atmosphere == .aurora {
                Image("focus.aurora")
                    .resizable()
                    .scaledToFill()
                    .opacity(0.82)
            } else {
                RadialGradient(
                    colors: [.white.opacity(0.22), .clear],
                    center: UnitPoint(x: 0.78, y: 0.12),
                    startRadius: 1,
                    endRadius: 95
                )
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var subjectSelectionActions: some View {
        ForEach(activeSubjects) { subject in
            Button {
                selectSubject(subject)
            } label: {
                if selectedSubject?.id == subject.id {
                    Label(subject.safeDisplayName, systemImage: "checkmark")
                } else {
                    Text(subject.safeDisplayName)
                }
            }
        }
    }

    private func selectSubject(_ subject: Subject) {
        selectedSubjectID = subject.id.uuidString
    }

    private var menuAccumulationActions: some View {
        VStack(spacing: 2) {
            menuActionButton(
                title: "時間を手動で積む",
                detail: "30分・1時間・2時間",
                symbol: "plus.circle"
            ) {
                guard selectedSubject != nil else {
                    showHomeMenu = false
                    router.selectedTab = .settings
                    return
                }
                showHomeMenu = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    showManualEntry = true
                }
            }
            menuActionButton(
                title: "成果を積む",
                detail: "100点・試験合格・仕事の節目",
                symbol: "medal.fill"
            ) {
                guard selectedSubject != nil else {
                    showHomeMenu = false
                    router.selectedTab = .settings
                    return
                }
                showHomeMenu = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    showAchievementEntry = true
                }
            }
            // screentime-10: the third way to add to the jar, next to the
            // other two, instead of three levels down in Settings.
            if ScreenTimeReleasePolicy.showsHomeEntry {
                menuActionButton(
                    title: String(localized: "アプリの時間を積む", table: "Home",
                                  comment: "Home menu row: open the Screen Time settings"),
                    detail: String(localized: "スクリーンタイムで選んだ勉強アプリを10分ごとに粒に", table: "Home",
                                   comment: "Home menu row detail: Screen Time"),
                    symbol: "hourglass"
                ) {
                    showHomeMenu = false
                    router.selectedTab = .screenTime
                }
                .accessibilityIdentifier("home.menu.screen-time")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var menuHistoryActions: some View {
        VStack(spacing: 2) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 12) {
                        menuMetric(value: homeMenuMassValue, label: "累計")
                        menuMetric(value: homeMenuCountValue, label: "集中")
                        menuMetric(value: "\(achievementCountLabel)個", label: "成果")
                    }
                } else {
                    HStack(spacing: 0) {
                        menuMetric(value: homeMenuMassValue, label: "累計")
                        Divider().frame(height: 34)
                        menuMetric(value: homeMenuCountValue, label: "集中")
                        Divider().frame(height: 34)
                        menuMetric(value: "\(achievementCountLabel)個", label: "成果")
                    }
                }
            }
            .padding(.vertical, 12)
            .background(PomoGemTheme.card)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(homeMenuAccessibilitySummary)

            menuActionButton(
                title: "積み上がりを見る",
                detail: "まとまり粒・生涯の瓶・月ごとの瓶",
                symbol: "circle.hexagongrid.fill"
            ) {
                showHomeMenu = false
                overviewInitialClusterID = nil
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    showAccumulationOverview = true
                }
            }
            menuActionButton(title: "記録を見る", detail: "推移・内訳・履歴", symbol: "chart.bar.fill") {
                showHomeMenu = false
                router.selectedTab = .log
            }
            menuActionButton(
                title: "動く瓶をシェア",
                detail: "GIF・質量・#ポモジェム をSNSへ",
                symbol: "play.rectangle.fill"
            ) {
                showHomeMenu = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    router.presentShare()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var menuSettingsAction: some View {
        menuActionButton(title: "設定", detail: "テーマ・通知・サウンド・Pro", symbol: "gearshape.fill") {
            showHomeMenu = false
            router.selectedTab = .settings
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var menuAccumulationPlanAction: some View {
        menuActionButton(
            title: "積み上がり計画",
            detail: "続けた先の瓶と質量を予測",
            symbol: "calendar.badge.clock"
        ) {
            showHomeMenu = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                showAccumulationPlan = true
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("planning.accumulation.open")
    }

    private func menuMetric(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.72)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(PomoGemTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private func menuActionButton(
        title: String,
        detail: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PomoGemTheme.amber)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.body, design: .rounded, weight: .bold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PomoGemTheme.muted)
            }
            .foregroundStyle(PomoGemTheme.text)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(PomoGemTheme.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(PomoGemRowButtonStyle(cornerRadius: 16))
    }

    private func postDropCard(_ offer: BreakOffer) -> some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 12) {
                postDropHeading(offer)
                if offer.isAwaitingDrop {
                    Text("閉じると、一粒が瓶に落ちます。")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                }
                if dynamicTypeSize.isAccessibilitySize {
                    // Keep every safe exit in the initial viewport at the
                    // largest text sizes. The detailed crystal evidence stays
                    // available immediately below the action group.
                    postDropActions(offer)
                    postDropFusionProgress(offer)
                } else {
                    postDropFusionProgress(offer)
                    postDropActions(offer)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reward.bridge")
    }

    private var completionInsetContents: some View {
        VStack(spacing: 8) {
            if router.deferredFocusRecovery != nil {
                deferredCompletionCard
            }
            if let breakOffer {
                postDropCard(breakOffer)
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func postDropActions(_ offer: BreakOffer) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                startBreakButton(offer)
                    .frame(maxWidth: .infinity)
                postDropShareButton
                    .frame(maxWidth: .infinity)
                    .opacity(showShareChip ? 1 : 0)
                    .allowsHitTesting(showShareChip)
                    .accessibilityHidden(!showShareChip)
                dismissBreakOfferButton(offer, showsText: true)
            }
        } else {
            HStack(spacing: 10) {
                dismissBreakOfferButton(offer, showsText: true)
                    .frame(maxWidth: .infinity)
                postDropShareButton
                    .frame(maxWidth: .infinity)
                    .opacity(showShareChip ? 1 : 0)
                    .allowsHitTesting(showShareChip)
                    .accessibilityHidden(!showShareChip)
                startBreakButton(offer)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var deferredCompletionCard: some View {
        PomoGemCard {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(PomoGemTheme.amber)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("完走は保護されています")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                    Text("記録の保存を安全に再試行できます")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                }
                Spacer(minLength: 6)
                Button("再試行") {
                    guard let request = router.deferredFocusRecovery else { return }
                    router.deferredFocusRecovery = nil
                    router.recoveredFocus = request
                }
                .buttonStyle(PomoGemCompactButtonStyle())
                .accessibilityIdentifier("home.pending-completion.retry")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func postDropHeading(_ offer: BreakOffer) -> some View {
        let canPublishHistory = !offer.projectionWasCloudUnverified
            && canPublishBreakOfferProjection(offer)
        let historyTitle = canPublishHistory
            ? offer.weeklyTitle
            : "今回の記録を保存"
        let historySpokenTitle = canPublishHistory
            ? offer.weeklySpokenTitle
            : "今回の記録は保存済みです"
        return HStack(spacing: 11) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34, weight: .black))
                .foregroundStyle(Color(hex: offer.heroColorHex(for: rareRewardMode)))
                .frame(width: 48, height: 48)
                .background(
                    Color(hex: offer.heroColorHex(for: rareRewardMode)).opacity(0.12),
                    in: Circle()
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(offer.dropTitle(for: rareRewardMode))
                    .font(.system(.headline, design: .rounded, weight: .black))
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    "\(offer.subjectName) +\(offer.grams)g（\(EffortProgressPresentation.formattedStandardUnits(grams: offer.grams))） ・ \(historyTitle)\(offer.rareRewardCounts.multiDrawSummary.map { " ・ \($0)" } ?? "")"
                )
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            Spacer(minLength: 4)
            if offer.kind != .normal, rareRewardMode.usesEnhancedPresentation {
                Image(systemName: "sparkles")
                    .font(.title3.weight(.black))
                    .foregroundStyle(
                        offer.kind == .gold
                            ? Color(hex: Constants.Color.pebbleGold)
                            : Color(hex: Constants.Color.auroraViolet)
                    )
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("reward.heading")
        .accessibilityLabel(offer.dropTitle(for: rareRewardMode))
        .accessibilityValue(
            "テーマは\(offer.subjectName)です。今回は\(offer.grams)グラム、標準換算は\(EffortProgressPresentation.formattedStandardUnits(grams: offer.grams))です。\(historySpokenTitle)。\(offer.rareRewardCounts.multiDrawSummary.map { "\($0)。" } ?? "")\(offer.minutes)分休憩を利用できます"
        )
        .accessibilityHint(
            showShareChip
                ? "結晶の進みを確認し、休憩、共有、または閉じるを選べます"
                : "結晶の進みを確認し、休憩または閉じるを選べます"
        )
    }

    @ViewBuilder
    private func postDropFusionProgress(_ offer: BreakOffer) -> some View {
        if aggregateProjectionPresentation.isCloudVerificationPending
            || offer.projectionWasCloudUnverified
            || !canPublishBreakOfferProjection(offer) {
            postDropCloudVerificationPending(offer)
        } else if let effortProgress = offer.effortProgress {
            postDropEffortProgress(effortProgress, offer: offer)
        } else {
            postDropLegacyFusionProgress(offer)
        }
    }

    private func postDropCloudVerificationPending(_ offer: BreakOffer) -> some View {
        let isStillVerifying = aggregateProjectionPresentation
            .isCloudVerificationPending
        return Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(isStillVerifying ? projectionVerificationTitle : "集計を更新しました")
                    .font(.headline.weight(.black))
                Text(
                    isStillVerifying
                        ? "今回の +\(offer.grams)g は保存済みです。生涯合計は確認後に表示します。"
                        : "今回の +\(offer.grams)g は保存済みです。更新前の生涯合計は再利用しません。"
                )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PomoGemTheme.muted)
            }
        } icon: {
            Image(systemName: isCloudOfflineSession ? "checklist" : "icloud.and.arrow.down")
                .foregroundStyle(PomoGemTheme.amber)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(PomoGemTheme.raised.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("reward.projection-verification-pending")
        .accessibilityLabel(
            isStillVerifying
                ? "\(projectionVerificationTitle)。今回の\(offer.grams)グラムは保存済みです。生涯合計は確認後に表示します"
                : "集計を更新しました。今回の\(offer.grams)グラムは保存済みです。更新前の生涯合計は再利用しません"
        )
    }

    private func canPublishBreakOfferProjection(_ offer: BreakOffer) -> Bool {
        !aggregateProjectionPresentation.usesCloudPersistence
            || aggregateProjectionPresentation.acceptsVerifiedAggregateCache(
                offer.projectionCacheStamp
            )
    }

    private func postDropEffortProgress(
        _ state: EffortProgressSnapshot,
        offer: BreakOffer
    ) -> some View {
        let display = EffortProgressPresentation.display(
            snapshot: state,
            projectionIsLowerBound: offer.projectionIsLowerBound
        )
        // Keep the exact physical-compaction statement in accessibility. It is
        // explicitly secondary to time value, but preserves the meaning of a
        // recovered flow and existing UI automation while count aggregation
        // continues to protect jar capacity.
        let physicalDisplay = FusionRewardBridgePresentation.display(
            state: offer.fusionState,
            projectionIsLowerBound: offer.projectionIsLowerBound
        )

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hourglass.bottomhalf.filled")
                    .font(.headline.weight(.black))
                    .foregroundStyle(Color(hex: offer.colorHex))
                    .frame(width: 32, height: 32)
                    .background(Color(hex: offer.colorHex).opacity(0.13), in: Circle())
                    .accessibilityHidden(true)
                Text(display.eyebrow)
                    .font(.caption2.weight(.black))
                    .tracking(1.05)
                    .foregroundStyle(PomoGemTheme.amber)
            }

            if let progressFraction = display.progressFraction {
                ProgressView(value: progressFraction)
                    .tint(Color(hex: offer.colorHex))
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(PomoGemTheme.amber)
                    .accessibilityHidden(true)
            }

            Text(display.progressLabel)
                .font(.system(.headline, design: .rounded, weight: .black))
                .monospacedDigit()
                .foregroundStyle(PomoGemTheme.text)
                .fixedSize(horizontal: false, vertical: true)

            Text(display.nextStepLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if let context = display.longTermContextLabel {
                Text(context)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(PomoGemTheme.amber.opacity(0.9))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("25分 = 1.0標準単位 ・ 粒の10→1は瓶の整理")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .tracking(0.15)
                .foregroundStyle(PomoGemTheme.text.opacity(0.82))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(PomoGemTheme.card.opacity(0.72), in: Capsule())
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [
                    Color(hex: offer.colorHex).opacity(0.12),
                    PomoGemTheme.raised.opacity(0.78)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(hex: offer.colorHex).opacity(0.24), lineWidth: 0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("reward.fusion-progress")
        .accessibilityLabel(
            "\(display.accessibilityLabel)。瓶の物理整理：\(physicalDisplay.accessibilityLabel)"
        )
    }

    private func postDropLegacyFusionProgress(_ offer: BreakOffer) -> some View {
        let state = offer.fusionState
        let display = FusionRewardBridgePresentation.display(
            state: state,
            projectionIsLowerBound: offer.projectionIsLowerBound
        )
        let orbitState = FusionOrbitStagePresentation.bridge(
            state: state,
            projectionIsLowerBound: offer.projectionIsLowerBound
        )

        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    FusionOrbitStage(
                        state: orbitState,
                        colorHex: offer.colorHex,
                        scale: .compact
                    )
                    .frame(width: 88, height: 88)
                    .frame(maxWidth: .infinity)
                    postDropFusionCopy(display, isSyncing: display.litSlotCount == nil)
                }
            } else {
                HStack(spacing: 13) {
                    FusionOrbitStage(
                        state: orbitState,
                        colorHex: offer.colorHex,
                        scale: .compact
                    )
                    .frame(width: 108, height: 108)
                    postDropFusionCopy(display, isSyncing: display.litSlotCount == nil)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [
                    Color(hex: offer.colorHex).opacity(0.12),
                    PomoGemTheme.raised.opacity(0.78)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(hex: offer.colorHex).opacity(0.24), lineWidth: 0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("reward.fusion-progress")
        .accessibilityLabel(display.accessibilityLabel)
    }

    private func postDropFusionCopy(
        _ display: FusionRewardBridgeDisplayState,
        isSyncing: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(display.eyebrow)
                .font(.caption2.weight(.black))
                .tracking(1.05)
                .foregroundStyle(PomoGemTheme.amber)

            Text(display.progressLabel)
                .font(.system(.headline, design: .rounded, weight: .black))
                .monospacedDigit()
                .foregroundStyle(PomoGemTheme.text)
                .fixedSize(horizontal: false, vertical: true)

            if isSyncing {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PomoGemTheme.amber)
                    Text(display.nextStepLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
            } else {
                Text(display.nextStepLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let context = display.longTermContextLabel {
                Text(context)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(PomoGemTheme.amber.opacity(0.9))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("10 → 1 ・記録と質量は保持")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .tracking(0.25)
                .foregroundStyle(PomoGemTheme.text.opacity(0.82))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(PomoGemTheme.card.opacity(0.72), in: Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func startBreakButton(_ offer: BreakOffer) -> some View {
        Button("\(offer.minutes)分休憩") {
            guard !rewardDropRevealIsPending, rewardDropDestination == nil else { return }
            guard let recovery = FocusPersistence.beginRewardBreak(sessionID: offer.id) else {
                router.showToast("休憩を開始できませんでした。もう一度お試しください", symbol: "arrow.clockwise")
                return
            }
            RewardBreakNotificationHandoff.begin(
                recovery,
                playsSound: sensoryPreferences.soundOn,
                completionSound: sensoryPreferences.timerCompletionSound
            )
            acknowledgeRewardOffer(offer, destination: .rest(recovery))
        }
        .buttonStyle(PomoGemCompactButtonStyle())
        .accessibilityLabel("\(offer.minutes)分休憩する")
    }

    private var postDropShareButton: some View {
        Button {
            guard let offer = breakOffer else { return }
            acknowledgeRewardOffer(offer, destination: .share)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "play.rectangle.fill")
                Text("GIF")
                    .font(.caption2.weight(.black))
            }
            .frame(minWidth: 58, minHeight: 44)
        }
        .buttonStyle(
            PomoGemCompactButtonStyle(
                tint: PomoGemTheme.text,
                foreground: PomoGemTheme.background,
                isProminent: false
            )
        )
        .accessibilityLabel("今の瓶をGIFでシェアする")
    }

    private func dismissBreakOfferButton(_ offer: BreakOffer, showsText: Bool) -> some View {
        Button {
            acknowledgeRewardOffer(offer, destination: .home)
        } label: {
            HStack(spacing: showsText ? 6 : 0) {
                Image(systemName: "xmark")
                    .accessibilityHidden(true)
                if showsText {
                    Text("閉じる")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(PomoGemTheme.text.opacity(0.92))
            .padding(.horizontal, showsText ? 12 : 0)
            .frame(
                minWidth: showsText ? 72 : 44,
                maxWidth: dynamicTypeSize.isAccessibilitySize && showsText ? .infinity : nil,
                minHeight: 44
            )
            .background(PomoGemTheme.raised.opacity(0.78), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(PomoGemTheme.text.opacity(0.28), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PomoGemBareButtonStyle())
        .accessibilityLabel("休憩の提案を閉じる")
        .accessibilityIdentifier("reward.dismiss")
    }

    private func acknowledgeRewardOffer(
        _ offer: BreakOffer,
        destination: RewardDropContinuation.Destination
    ) {
        guard !rewardDropRevealIsPending, rewardDropDestination == nil else { return }
        if offer.isAwaitingDrop,
           !PendingRewardReceiptStore.acknowledgeDrop(id: offer.id) {
            router.showToast("もう一度「閉じる」を押してください", symbol: "arrow.clockwise")
            return
        }
        TimerCompletionAlertAcknowledgementStore.mark(sessionID: offer.id)
        TimerCompletionAlertController.shared.stop(sessionID: offer.id)
        breakOfferTask?.cancel()
        breakOfferTask = nil
        shareChipTask?.cancel()
        shareChipTask = nil
        if case .share = destination {
            isDeferringCelebrationsForShare = true
        }

        guard offer.isAwaitingDrop else {
            // Receipts from older versions have already landed.
            retireRewardReceipt(offer)
            breakOffer = nil
            showShareChip = false
            continueAfterRewardDrop(destination)
            return
        }

        rewardDropDestination = RewardDropContinuation(
            sessionID: offer.id,
            destination: destination
        )
        rewardDropRevealIsPending = true
        withAnimation(
            reduceMotion ? nil : .easeOut(duration: 0.3),
            completionCriteria: .removed
        ) {
            breakOffer = nil
            showShareChip = false
        } completion: {
            // The card changes the bottle's available height. Finish that
            // layout, then reveal the bottle before starting actual physics.
            rewardDropRevealRequestID = offer.id
        }
    }

    private func finishRewardDrop(sessionID: UUID) {
        PendingRewardReceiptStore.remove(id: sessionID)
        if rewardDropDestination?.sessionID == sessionID {
            rewardDropDestination?.hasLanded = true
            rewardDropRevealRequestID = nil
            continueRewardDropIfPossible()
        } else {
            recoverPendingRewardReceipt()
        }
    }

    private func continueRewardDropIfPossible() {
        guard let continuation = rewardDropDestination,
              continuation.hasLanded,
              homeIsVisible,
              !router.focusPresentationIsActive,
              focusConfiguration == nil,
              router.recoveredFocus == nil,
              !rewardDropSurfaceIsObscured
        else { return }
        rewardDropDestination = nil
        continueAfterRewardDrop(continuation.destination)
    }

    private func continueAfterRewardDrop(_ destination: RewardDropContinuation.Destination) {
        switch destination {
        case .home:
            recoverPendingRewardReceipt()
            presentNextStratumCelebrationIfNeeded()
            schedulePendingReviewRequestIfPossible()
        case let .rest(recovery):
            // The clock starts when Rest is selected, including the drop and
            // any time away. Never recreate a consumed or expired timer from
            // this process-local animation callback.
            if let saved = FocusPersistence.loadBreak(), saved.id == recovery.id {
                breakConfiguration = saved
            } else {
                recoverPendingRewardReceipt()
                presentNextStratumCelebrationIfNeeded()
            }
        case .share:
            router.presentShare()
        }
    }

    private func requestCustomDuration() {
        showHomeMenu = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            if purchase.isPro {
                showCustomDuration = true
            } else {
                router.presentPaywall(
                    from: .customTimer,
                    pendingIntent: .homeCustomDuration
                )
            }
        }
    }

    private func configureScene() {
        router.jarScene = scene
        scene.onAggregateRequested = { request in
            Task { @MainActor in persistAggregate(request) }
        }
        scene.onCapacityEvent = { event in
            Task { @MainActor in handleCapacity(event) }
        }
        scene.onLanding = { event in
            Task { @MainActor in
                publishWidgetSnapshot()
                handleLanding(event)
            }
        }
        applySensoryPreferences()
    }

    private func clearSceneCallbacks() {
        scene.onAggregateRequested = nil
        scene.onBakeRequested = nil
        scene.onCapacityEvent = nil
        scene.onLanding = nil
    }

    private func syncScene() {
        // `supportedSessionBackfill` is loaded asynchronously. Never initialize
        // or diff the jar against its temporary empty/stale value: doing so
        // makes restored sessions look newly inserted when the refresh lands and
        // replays their drop, sound, haptic, and "+ng 積んだ" toast.
        // Keep the last valid app/widget presentation until the accepted page
        // arrives instead of transiently publishing an empty history.
        guard sceneSessionSnapshotIsCurrent,
              homeIsVisible,
              !router.focusPresentationIsActive,
              focusConfiguration == nil,
              router.recoveredFocus == nil
        else { return }
        // A projection refresh must not shelf-pack a gem halfway through its
        // first visible descent. The landing callback applies the latest page.
        guard !scene.hasCompletionDropInFlight else { return }
        guard refreshRewardSessionBackfill() else { return }
        syncBaseLayers()

        let localCompletions = looseSessions.filter(hasLocalCompletionMarker)
        for session in localCompletions {
            _ = prepareRewardReceipt(
                for: PebbleDescriptor(session: session),
                dropPhase: .awaitingAcknowledgement
            )
        }
        if !localCompletions.isEmpty {
            scheduleShareChipIfNeeded(for: localCompletions)
        }

        // If Home was navigated away from during the short fall, the physical
        // contact may precede callback reattachment. Retire that presentation
        // without dropping the same saved gem again.
        for receipt in PendingRewardReceiptStore.load()
        where receipt.dropPhase == .awaitingLanding {
            if scene.hasLandedPebble(withID: receipt.id)
                || representedSessionIDs.contains(receipt.id) {
                finishRewardDrop(sessionID: receipt.id)
            }
        }
        let pendingReceipts = PendingRewardReceiptStore.load()
        let canRevealDrop = !rewardDropRevealIsPending
            && breakOffer == nil
            && !rewardDropSurfaceIsObscured
        for id in ScreenTimeGemDropStore.load()
        where scene.hasLandedPebble(withID: id) || representedSessionIDs.contains(id) {
            ScreenTimeGemDropStore.remove(id)
        }
        let awaitingDropIDs = Set(pendingReceipts.filter {
            $0.dropPhase == .awaitingLanding
        }.map(\.id)).union(ScreenTimeGemDropStore.load())
        let heldIDs = Set(pendingReceipts.filter {
            $0.isAwaitingAcknowledgement || ($0.requiresDrop && !canRevealDrop)
        }.map(\.id)).union(looseSessions.filter(hasLocalCompletionMarker).map(\.id))
        let current = (
            looseSessions.map(PebbleDescriptor.init(session:))
                + visibleAchievementStones.map(PebbleDescriptor.init(achievement:))
        ).filter { !heldIDs.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
        let currentIDs = Set(current.map(\.id))
        recoverPendingRewardReceipt()

        let snapshotGeneration = HomeSceneSessionSnapshotGeneration(
            aggregateProjectionPresentation
        )
        if HomeSceneSessionSnapshotPolicy.shouldRestoreSilently(
            sceneIsInitialized: sceneInitialized,
            appliedGeneration: appliedSceneSessionSnapshotGeneration,
            acceptedGeneration: snapshotGeneration
        ) {
            let restored = current.filter { !awaitingDropIDs.contains($0.id) }
            scene.restore(pebbles: restored)
            knownLooseIDs = currentIDs
            sceneInitialized = true
            appliedSceneSessionSnapshotGeneration = snapshotGeneration
            for descriptor in current where awaitingDropIDs.contains(descriptor.id) {
                scene.dropFromAbove(descriptor)
            }
            scheduleWidgetSnapshot()
            return
        }

        let newDescriptors = current.filter { !knownLooseIDs.contains($0.id) }
        let newSessionIDs = Set(newDescriptors.filter { !$0.isAchievement }.map(\.id))
        let newSessions = looseSessions.filter { newSessionIDs.contains($0.id) }
        let removedIDs = knownLooseIDs.subtracting(currentIDs)
        if !removedIDs.isEmpty {
            let allAchievementIDs = Set(achievementStones.map(\.id))
            if removedIDs.isSubset(of: allAchievementIDs) {
                scene.removePebbles(withIDs: removedIDs)
            } else {
                scene.restore(pebbles: current.filter { !awaitingDropIDs.contains($0.id) })
                for descriptor in current where awaitingDropIDs.contains(descriptor.id) {
                    scene.dropFromAbove(descriptor)
                }
                knownLooseIDs = currentIDs
                scheduleWidgetSnapshot()
                return
            }
        }
        let newStudyDescriptors = newDescriptors.filter { !$0.isAchievement }
        let newAchievementDescriptors = newDescriptors.filter(\.isAchievement)
        if !newStudyDescriptors.isEmpty {
            for descriptor in newStudyDescriptors {
                if awaitingDropIDs.contains(descriptor.id) {
                    scene.dropFromAbove(descriptor)
                } else {
                    scene.drop(descriptor)
                }
            }
            scheduleShareChipIfNeeded(for: newSessions)
        }
        if !newAchievementDescriptors.isEmpty {
            scene.performCompletionDrop(newAchievementDescriptors)
        }
        knownLooseIDs = currentIDs
        scheduleWidgetSnapshot()
    }

    private func refreshRewardSessionBackfill() -> Bool {
        let receipts = PendingRewardReceiptStore.load().filter(\.requiresDrop)
        let screenTimeIDs = ScreenTimeGemDropStore.load()
        guard !receipts.isEmpty || !screenTimeIDs.isEmpty else { return true }
        do {
            var resolved = try HomeProjectionPolicy.pendingRewardSessionCandidates(
                for: receipts,
                context: modelContext,
                resetMarkers: resetSnapshots
            )
            for id in screenTimeIDs {
                if let session = try BoundedHistoryPolicy.resolvedSession(
                    id: id, epochID: currentActivityEpochID, context: modelContext
                ), session.effectiveSource == .screenTime, StudySessionIntegrityPolicy.isSupported(session) {
                    resolved.append(session)
                } else {
                    ScreenTimeGemDropStore.remove(id)
                }
            }
            let resolvedIDs = Set(resolved.map(\.id))
            // Keep a just-landed older reward visible for this Home generation.
            // Removing its receipt must not immediately remove its jar body.
            let retained = currentRewardSessionBackfill.filter {
                !resolvedIDs.contains($0.id)
            }
            rewardSessionBackfill = Array(
                (resolved + retained).prefix(PendingRewardReceiptStore.maximumPendingCount + ScreenTimeGemDropStore.maximumCount)
            )
            rewardSessionBackfillGeneration = HomeSceneSessionSnapshotGeneration(
                aggregateProjectionPresentation
            )
            return true
        } catch {
            // A failed bounded lookup is not proof that a saved reward is gone.
            // Leave the durable receipt intact until the next accepted refresh.
            return false
        }
    }

    private func syncBaseLayers() {
        do {
            let membership = try HomeProjectionPolicy.localMembershipProjection(
                for: sessions,
                representedAggregateRoots: validatedAggregateRoots,
                legacyStrata: activeLegacyStrata,
                context: modelContext,
                resetMarkers: resetSnapshots
            )
            representedSessionIDs = membership.representedSessionIDs
            localMembershipProjectionIsComplete = membership.isCompleteForCandidates
            conflictedAggregateRootIDs = membership.conflictedRootIDs
        } catch {
            // A failed membership read keeps candidates loose and removes every
            // possibly overlapping root. This is a conservative lower bound;
            // keeping both layers would overstate synchronized activity.
            representedSessionIDs = []
            localMembershipProjectionIsComplete = false
            conflictedAggregateRootIDs = Set(validatedAggregateRoots.map(\.id))
        }
        scene.showsMonthLabels = purchase.isPro
        scene.configureAggregates(
            acceptedAggregateRoots,
            legacyStrata: activeLegacyStrata.map(
                JarStratumVisual.init(stratum:)
            )
        )
        scheduleWidgetSnapshot()
    }

    private func refreshSupportedSessionBackfill() {
        sessionBackfillTask?.cancel()
        sessionBackfillIsComplete = false
        let markers = resetSnapshots
        let cacheStamp = aggregateProjectionPresentation.currentCacheStamp
        let verifiedCacheStamp = aggregateProjectionPresentation.verifiedCacheStamp
        let currentEpochID = ActivityResetPolicy.currentEpochID(from: markers)
        let physicalSessionRowCount = try? modelContext.fetchCount(
            BoundedHistoryPolicy.sessionCountDescriptor(epochID: currentEpochID)
        )
        let trustedAggregateHorizon = verifiedAggregateSessionHorizon
        let queryPlan = HomeProjectionPolicy.initialLooseSessionQueryPlan(
            physicalSessionRowCount: physicalSessionRowCount,
            verifiedAggregateEnd: trustedAggregateHorizon
        )
        sessionBackfillTask = Task { @MainActor in
            await Task.yield()
            do {
                let page = try HomeProjectionPolicy.supportedLooseSessionPage(
                    context: modelContext,
                    resetMarkers: markers,
                    startingAt: queryPlan.lowerBound
                )
                try Task.checkCancellation()
                guard aggregateProjectionPresentation
                    .acceptsCurrentGenerationCache(cacheStamp) else { return }
                supportedSessionBackfill = page.sessions
                supportedSessionBackfillStamp = cacheStamp
                supportedSessionBackfillVerifiedStamp = verifiedCacheStamp
                sessionBackfillIsComplete = page.isCompleteForHomeCandidates
                hasLoadedSceneSessionSnapshot = true
                // An empty successful page does not change sessionChangeTokens,
                // so complete the initial scene sync explicitly as part of the
                // same accepted snapshot.
                syncScene()
                if HomeProjectionPolicy.shouldRequestLocalSessionMaintenance(
                    trustedAggregateHorizon: trustedAggregateHorizon,
                    requestedLowerBound: queryPlan.lowerBound,
                    pageIsComplete: page.isCompleteForHomeCandidates
                ) {
                    router.requestLocalSessionMaintenanceOnce()
                }
            } catch is CancellationError {
                return
            } catch {
                // Keep the already loaded bounded page. A later store change,
                // foreground transition, or relaunch retries the scan.
            }
        }
    }

    private func refreshAcceptedAggregateRoots() {
        guard let cacheStamp = aggregateProjectionPresentation
            .verifiedCacheStamp else {
            aggregatePresentationPage = nil
            return
        }
        do {
            let page = try HomeProjectionPolicy
                .refreshedAggregatePresentationPage(
                    context: modelContext,
                    resetMarkers: resetSnapshots,
                    cacheStamp: cacheStamp
                )
            guard aggregateProjectionPresentation
                .acceptsVerifiedAggregateCache(page.cacheStamp) else {
                aggregatePresentationPage = nil
                return
            }
            // Publish one atomic page only after the explicit payload fetches,
            // validation, and generation recheck have all succeeded.
            aggregatePresentationPage = page
        } catch {
            // A parent that cannot be verified during a transient store read is
            // omitted for this frame. The query change/relaunch retries without
            // risking duplicated mass or a phantom jar body.
            aggregatePresentationPage = nil
        }
    }

    private func refreshAchievementCount() {
        do {
            let projection = try HomeProjectionPolicy.currentAchievementCount(
                context: modelContext,
                resetMarkers: resetSnapshots,
                resolvedCandidates: achievementStones,
                loadedCandidateRowCount: achievementCandidates.count
            )
            projectedAchievementCount = projection.count
            achievementCountIsLowerBound = projection.isLowerBound
        } catch {
            projectedAchievementCount = Set(achievementStones.map(\.id)).count
            achievementCountIsLowerBound = true
        }
    }

    private func refreshAchievementProjection() {
        do {
            resolvedAchievementStones = try AchievementStonePolicy.resolvedVisibleCandidates(
                from: achievementCandidates,
                context: modelContext
            )
        } catch {
            // Fail closed: a transient read error must not revive a stale
            // active duplicate whose tombstone could not be inspected.
            resolvedAchievementStones = []
            achievementCountIsLowerBound = true
        }
    }

    private func applySensoryPreferences() {
        scene.soundEnabled = sensoryPreferences.soundOn
        scene.hapticsEnabled = sensoryPreferences.hapticsOn
        scene.rareRewardMode = rareRewardMode
    }

    private func restorePreferredDuration() {
        guard let preferred = resolvedPreferences?.preferredFocusSeconds else {
            return
        }
        let restored = PomodoroDuration(totalSeconds: preferred)
        guard restored.isValid else { return }
        if restored.requiresPro {
            selectedDuration = purchase.isPro ? restored : .twentyFiveMinutes
        } else {
            selectedDuration = restored
        }
    }

    private func resumeCustomDurationAfterPurchaseIfNeeded() {
        guard router.consumeHomeCustomDurationResumeRequest() else { return }
        guard purchase.isPro else { return }
        showCustomDuration = true
    }

    private func confirmCustomDuration(_ totalSeconds: Int) -> Bool {
        guard purchase.isPro else {
            router.showToast("Proの購入状態を確認してください", symbol: "lock")
            return false
        }
        let duration = PomodoroDuration(totalSeconds: totalSeconds)
        guard duration.isValid else { return false }
        guard persistPreferredFocusSeconds(
            totalSeconds,
            failureMessage: "集中時間を保存できませんでした"
        ) else { return false }
        selectedDuration = duration
        showCustomDuration = false
        return true
    }

    private func shareCompletedStratum(_ request: PendingStratumCelebration) {
        isDeferringCelebrationsForShare = true
        completedStratum = nil
        Task { @MainActor in
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(360))
            }
            guard !Task.isCancelled else { return }
            router.presentShare(
                scope: .aggregate(id: request.id, monthLabel: request.monthLabel)
            )
        }
    }

    private func exploreCompletedStratum() {
        overviewInitialClusterID = completedStratum?.id
        completedStratum = nil
        Task { @MainActor in
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(360))
            }
            guard !Task.isCancelled else { return }
            showAccumulationOverview = true
        }
    }

    private func dismissCompletedStratum() {
        completedStratum = nil
    }

    private func selectDuration(_ duration: PomodoroDuration) {
        selectedDuration = duration
#if DEBUG
        if duration == .demo { return }
#endif
        _ = persistPreferredFocusSeconds(
            duration.seconds,
            failureMessage: "集中時間を保存できませんでした"
        )
    }

    private func startFocus(duration: PomodoroDuration) {
        guard let subject = selectedSubject else {
            router.selectedTab = .settings
            return
        }
        selectedDuration = duration
        if duration.isValid,
           duration.seconds >= Constants.Timer.customMinimumMinutes * Constants.Timer.secondsPerMinute {
            _ = persistPreferredFocusSeconds(
                duration.seconds,
                failureMessage: "前回使った時間として保存できませんでした"
            )
        }
        focusConfiguration = FocusConfiguration(
            subject: subject,
            duration: duration,
            dataEpochID: currentActivityEpochID
        )
    }

    private func persistPreferredFocusSeconds(
        _ totalSeconds: Int,
        failureMessage: String
    ) -> Bool {
        guard let resolvedPreferences else {
            router.showToast(failureMessage, symbol: "exclamationmark.triangle")
            return false
        }
        guard resolvedPreferences.preferredFocusSeconds != totalSeconds else {
            return true
        }
        do {
            try PrefsConsumerPolicy.setPreferredFocusSeconds(
                totalSeconds,
                context: modelContext,
                markers: resetSnapshots
            )
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            router.showToast(failureMessage, symbol: "exclamationmark.triangle")
            return false
        }
    }

    private func enqueueStratumCelebration(_ request: JarBakeRequest) {
        enqueueStratumCelebration(PendingStratumCelebration(
            request: request,
            projectionCacheStamp:
                aggregateProjectionPresentation.verifiedCacheStamp
        ))
    }

    private func enqueueStratumCelebration(_ request: PendingStratumCelebration) {
        guard canPublishCelebrationSnapshot(request) else {
            PendingStratumCelebrationStore.remove(id: request.id)
            return
        }
        guard completedStratum?.id != request.id,
              !stratumCelebrationQueue.contains(where: { $0.id == request.id })
        else { return }
        if completedStratum == nil, canPresentStratumCelebration {
            completedStratum = request
            presentedStratumID = request.id
        } else {
            // A full bottle can create several aggregate levels in one relief
            // cascade. Keep only the newest result so loyal users never have to
            // dismiss a stack of near-identical celebration sheets.
            stratumCelebrationQueue.forEach {
                PendingStratumCelebrationStore.remove(id: $0.id)
            }
            stratumCelebrationQueue = [request]
        }
    }

    private func presentNextStratumCelebrationIfNeeded() {
        discardUnpublishableCelebrationSnapshots()
        guard completedStratum == nil,
              canPresentStratumCelebration,
              !stratumCelebrationQueue.isEmpty
        else { return }
        completedStratum = stratumCelebrationQueue.removeFirst()
        presentedStratumID = completedStratum?.id
    }

    private func finishPresentedStratumCelebration() {
        if isDeferringStratumForCloudVerification {
            isDeferringStratumForCloudVerification = false
            presentedStratumID = nil
            presentNextStratumCelebrationIfNeeded()
            return
        }
        if let presentedStratumID {
            PendingStratumCelebrationStore.remove(id: presentedStratumID)
            self.presentedStratumID = nil
        }
        presentNextStratumCelebrationIfNeeded()
    }

    private func deferPresentedStratumForCloudVerification() {
        guard let active = completedStratum else { return }
        if !stratumCelebrationQueue.contains(where: { $0.id == active.id }) {
            stratumCelebrationQueue.insert(active, at: 0)
        }
        isDeferringStratumForCloudVerification = true
        completedStratum = nil
    }

    /// Revokes every aggregate-derived emotional receipt synchronously with
    /// Root's projection trust. The aggregate/session source rows remain
    /// untouched; only UI snapshots that could otherwise reappear when the
    /// pending boolean flips back to false are discarded.
    private func discardAggregateCelebrationSnapshotsForInvalidation() {
        capacityCelebrationTask?.cancel()
        capacityCelebrationTask = nil
        celebrationRecoveryTask?.cancel()
        celebrationRecoveryTask = nil
        let ids = Set(
            ([completedStratum].compactMap { $0 }
                + stratumCelebrationQueue
                + pendingCapacityCelebrations)
                .map(\.id)
        )
        ids.forEach { PendingStratumCelebrationStore.remove(id: $0) }
        completedStratum = nil
        presentedStratumID = nil
        stratumCelebrationQueue.removeAll()
        pendingCapacityCelebrations.removeAll()
        isDeferringStratumForCloudVerification = false
    }

    private func canPublishCelebrationSnapshot(
        _ request: PendingStratumCelebration
    ) -> Bool {
        !aggregateProjectionPresentation.usesCloudPersistence
            || aggregateProjectionPresentation.acceptsVerifiedAggregateCache(
                request.projectionCacheStamp
            )
    }

    private func discardUnpublishableCelebrationSnapshots() {
        let rejected = ([completedStratum].compactMap { $0 }
            + stratumCelebrationQueue
            + pendingCapacityCelebrations).filter {
                !canPublishCelebrationSnapshot($0)
            }
        rejected.forEach {
            PendingStratumCelebrationStore.remove(id: $0.id)
        }
        let rejectedIDs = Set(rejected.map(\.id))
        if let completedStratum,
           rejectedIDs.contains(completedStratum.id) {
            self.completedStratum = nil
            presentedStratumID = nil
        }
        stratumCelebrationQueue.removeAll { rejectedIDs.contains($0.id) }
        pendingCapacityCelebrations.removeAll { rejectedIDs.contains($0.id) }
    }

    private func recoverPendingStratumCelebrations() {
        // Initial cloud launch is pending. Preserve the durable queue until a
        // ticket is verified, then accept only snapshots from that exact
        // process/epoch (normally a same-run interrupted animation).
        guard !aggregateProjectionPresentation.isCloudVerificationPending else {
            return
        }
        capacityRemaining = nil
        let persistedIDs = Set(aggregates.map(\.id)).union(strata.map(\.id))
        let pending = PendingStratumCelebrationStore.load()
        let now = Date.now
        let recoverable = pending.filter {
            canPublishCelebrationSnapshot($0)
                && persistedIDs.contains($0.id)
                && !scene.isBakeInProgress
        }
        let latestRecoverable = PendingStratumCelebrationSelection.latest(in: recoverable)
        let recoverableIDs = Set(recoverable.map(\.id))
        let waiting = pending.filter {
            guard canPublishCelebrationSnapshot($0) else { return false }
            if recoverableIDs.contains($0.id) {
                return $0.id == latestRecoverable?.id
            }
            return scene.isBakeInProgress
                || persistedIDs.contains($0.id)
                || now.timeIntervalSince($0.createdAt) < 10
        }
        PendingStratumCelebrationStore.save(waiting)
        if let latestRecoverable {
            enqueueStratumCelebration(latestRecoverable)
        }
        celebrationRecoveryTask?.cancel()
        if waiting.contains(where: { !persistedIDs.contains($0.id) || scene.isBakeInProgress }) {
            celebrationRecoveryTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }
                recoverPendingStratumCelebrations()
            }
        }
    }

    private func addManualEntry(_ duration: ManualDuration) -> Bool {
        guard let resolvedPreferences else {
            router.showToast("設定情報を読み込めませんでした", symbol: "exclamationmark.triangle")
            return false
        }
        guard let subject = selectedSubject else {
            showManualEntry = false
            router.selectedTab = .settings
            router.showToast("先にテーマを追加してください", symbol: "books.vertical.fill")
            return false
        }
        let now = Date.now
        let decision = FairnessPolicy.consumeManualEntry(
            state: ManualCounterState(
                dayKey: resolvedPreferences.manualDayKey,
                usedToday: resolvedPreferences.manualUsedToday
            ),
            at: now
        )
        guard decision.isAllowed else {
            router.showToast(Constants.UIStrings.manualCapToast, symbol: "info.circle")
            return false
        }

        // Apply the quota and session in the same SwiftData transaction. Merely
        // selecting a duration in the confirmation sheet never mutates Prefs.
        let writer: Prefs
        do {
            writer = try PrefsSyncPolicy.ensureWriterRow(
                context: modelContext,
                currentEpochID: currentActivityEpochID
            )
        } catch {
            modelContext.rollback()
            router.showToast("設定情報を安全に保存できませんでした", symbol: "exclamationmark.triangle")
            return false
        }
        writer.manualDayKey = decision.state.dayKey
        writer.manualUsedToday = decision.state.usedToday
        let session = StudySession(
            subject: subject,
            startAt: now.addingTimeInterval(-TimeInterval(duration.seconds)),
            endAt: now,
            seconds: duration.seconds,
            source: .manual,
            grams: duration.grams,
            deviceDayKey: FairnessPolicy.deviceDayKey(for: now),
            dataEpochID: currentActivityEpochID
        )
        modelContext.insert(session)
        do {
            try modelContext.save()
            showManualEntry = false
            router.showToast(
                Constants.UIStrings.manualToast(subject: subject.safeDisplayName, grams: duration.grams),
                symbol: "plus.circle.fill"
            )
            return true
        } catch {
            modelContext.rollback()
            router.showToast(error.localizedDescription, symbol: "exclamationmark.triangle")
            return false
        }
    }

    private func addAchievementStone(
        subject: Subject,
        draft: AchievementDraft
    ) -> Bool {
        let stone = AchievementStone(
            subject: subject,
            kind: draft.kind,
            note: draft.note,
            achievedAt: draft.achievedAt,
            dataEpochID: currentActivityEpochID
        )
        modelContext.insert(stone)
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            router.showToast("記念石を保存できませんでした", symbol: "exclamationmark.triangle")
            return false
        }
    }

    private func persistAggregate(_ request: JarAggregateRequest) {
        let sessionIDs = Set(request.calculation.sessionIDs)
        do {
            try HomeAggregatePersistence.persist(
                request,
                context: modelContext,
                dataEpochID: currentActivityEpochID,
                resetMarkers: resetSnapshots
            )
            failedBakeIDs.remove(request.id)
            if failedAggregateRequest?.id == request.id {
                failedAggregateRequest = nil
            }
            knownLooseIDs.subtract(sessionIDs)
        } catch {
            failedBakeIDs.insert(request.id)
            failedAggregateRequest = request
            // Install the deterministic-id gate before restoring the sources.
            // Otherwise the next SpriteKit update immediately repeats the same
            // animation and failing save forever.
            scene.suspendAggregateAfterPersistenceFailure(id: request.id)
            PendingStratumCelebrationStore.remove(id: request.id)
            pendingCapacityCelebrations.removeAll { $0.id == request.id }
            stratumCelebrationQueue.removeAll { $0.id == request.id }
            if completedStratum?.id == request.id {
                completedStratum = nil
            }
            capacityRemaining = nil
            modelContext.rollback()
            syncBaseLayers()
            let heldRewardIDs = Set(PendingRewardReceiptStore.load().filter(\.requiresDrop).map(\.id))
            let restored = (
                looseSessions.map(PebbleDescriptor.init(session:))
                    + visibleAchievementStones.map(PebbleDescriptor.init(achievement:))
            ).filter { !heldRewardIDs.contains($0.id) }
                .sorted { $0.createdAt < $1.createdAt }
            scene.restore(pebbles: restored)
            knownLooseIDs = Set(restored.map(\.id))
            sceneInitialized = true
            router.showToast("まとまり粒は未保存です。再試行してください", symbol: "exclamationmark.triangle")
        }
    }

    private func retryFailedAggregatePersistence() {
        guard let request = failedAggregateRequest else { return }
        failedAggregateRequest = nil
        failedBakeIDs.remove(request.id)
        capacityRemaining = 0
        guard scene.retryAggregatePersistence(id: request.id) else {
            failedAggregateRequest = request
            capacityRemaining = nil
            router.showToast("再試行の準備ができませんでした", symbol: "exclamationmark.triangle")
            return
        }
        router.showToast("まとまり粒の保存を再試行します", symbol: "arrow.clockwise")
    }

    private func handleCapacity(_ event: JarCapacityEvent) {
        switch event {
        case let .approachingBake(_, _, remaining):
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                capacityRemaining = remaining
            }
        case let .bakeStarted(request):
            failedBakeIDs.remove(request.id)
            PendingStratumCelebrationStore.insert(PendingStratumCelebration(
                request: request,
                projectionCacheStamp:
                    aggregateProjectionPresentation.verifiedCacheStamp
            ))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                capacityRemaining = 0
            }
        case let .bakeCompleted(request):
            capacityRemaining = nil
            guard failedBakeIDs.remove(request.id) == nil else { return }
            let celebration = PendingStratumCelebration(
                request: request,
                projectionCacheStamp:
                    aggregateProjectionPresentation.verifiedCacheStamp
            )
            if !pendingCapacityCelebrations.contains(where: { $0.id == celebration.id }) {
                pendingCapacityCelebrations.append(celebration)
            }
            scheduleCapacityCelebrationAfterRelief()
        case .hardLimitReached:
            router.showToast("瓶の粒をまとめています", symbol: "hourglass")
        case .layersCompacted:
            capacityRemaining = nil
        }
    }

    private func scheduleCapacityCelebrationAfterRelief() {
        capacityCelebrationTask?.cancel()
        capacityCelebrationTask = Task { @MainActor in
            // Aggregation can immediately trigger another level. Wait until the
            // chamber is stable, then celebrate the final visible result once.
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                if !scene.isBakeInProgress, !scene.isCapacityReliefActive {
                    try? await Task.sleep(for: .milliseconds(650))
                    guard !Task.isCancelled else { return }
                    if !scene.isBakeInProgress, !scene.isCapacityReliefActive { break }
                }
            }

            guard !Task.isCancelled,
                  let finalCelebration = PendingStratumCelebrationSelection.latest(
                    in: pendingCapacityCelebrations
                  )
            else { return }

            let completedSteps = pendingCapacityCelebrations.count
            pendingCapacityCelebrations
                .filter { $0.id != finalCelebration.id }
                .forEach { PendingStratumCelebrationStore.remove(id: $0.id) }
            pendingCapacityCelebrations.removeAll()
            enqueueStratumCelebration(finalCelebration)
            let message = completedSteps > 1
                ? "小さな粒が\(completedSteps)段階でまとまり、瓶に余白ができた"
                : "\(finalCelebration.pebbleCount)粒が、ひとつのまとまり粒になった"
            router.showToast(message, symbol: "circle.grid.2x2.fill")
        }
    }

    /// Screen Time black stones arrive silently in the jar; say how many
    /// once, neutrally (see `ScreenTimeArrivalAnnouncer`).
    private func noteScreenTimeBlackStones(_ count: Int) {
        screenTimeArrivals.noteBlackStoneCount(
            count, isBound: ScreenTimeController.shared.isBoundToContext
        ) { text, symbol in
            router.showToast(text, symbol: symbol)
        }
    }

    private func handleLanding(_ event: JarLandingEvent) {
        let descriptor = event.pebble
        if let achievementKind = descriptor.achievementKind {
            let suffix = uniqueAchievementCount > Constants.Jar.maximumVisibleAchievementStones
                ? "。前の記念石も成果の記録に残っています"
                : ""
            router.showToast(
                "\(descriptor.subjectName)の\(achievementKind.title)を記念石にした\(suffix)",
                symbol: achievementKind.systemImage
            )
            return
        }
        // Fusion has its own completion beat in `handleCapacity`. Treating the
        // resulting overview pebble as a fresh study session would announce a
        // misleading second “+2500g” reward.
        if descriptor.isAggregate { return }
        if descriptor.source == .screenTime {
            // One attributed summary per import (「スクリーンタイム：英語 +30分
            // （3粒）」) instead of a generic toast per 10-minute pebble.
            screenTimeArrivals.noteLearningLanding(subjectName: descriptor.subjectName) { text, symbol in
                router.showToast(text, symbol: symbol)
            }
            ScreenTimeGemDropStore.remove(descriptor.id)
            syncScene()
            return
        }
        var message: String
        let presentationKind = RareRewardPresentationPolicy.kind(descriptor.kind)
        switch presentationKind {
        case .gold:
            message = rareRewardMode.usesEnhancedPresentation
                ? Constants.UIStrings.goldToast(grams: descriptor.grams)
                : "\(descriptor.subjectName) 金の粒 +\(descriptor.grams)g"
        case .prism:
            message = rareRewardMode.usesEnhancedPresentation
                ? Constants.UIStrings.prismToast(grams: descriptor.grams)
                : "\(descriptor.subjectName) 虹の粒 +\(descriptor.grams)g"
        case .normal:
            message = descriptor.grams == Constants.Mass.measuredPebbleGrams
                ? Constants.UIStrings.dropToast(subject: descriptor.subjectName)
                : "\(descriptor.subjectName) +\(descriptor.grams)g 積んだ"
        }
        if let batch = descriptor.presentationRewardBatchSummary {
            message += " ・ \(batch)"
        }
        let usesRareSymbol = presentationKind != .normal
            && rareRewardMode.usesEnhancedPresentation
        router.showToast(message, symbol: usesRareSymbol ? "sparkles" : "scalemass")

        if PendingRewardReceiptStore.load().contains(where: {
            $0.id == descriptor.id && $0.dropPhase == .awaitingLanding
        }) {
            finishRewardDrop(sessionID: descriptor.id)
            syncScene()
            return
        }
        guard descriptor.source != .manual,
              hasLocalCompletionMarker(descriptor.id)
        else { return }
        if let receipt = prepareRewardReceipt(for: descriptor, dropPhase: nil) {
            scheduleRewardReceipt(receipt, delay: .milliseconds(1_650))
        }
    }

    @discardableResult
    private func prepareRewardReceipt(
        for descriptor: PebbleDescriptor,
        dropPhase: PendingRewardDropPhase?
    ) -> PendingRewardReceipt? {
        if let existing = PendingRewardReceiptStore.load().first(where: { $0.id == descriptor.id }) {
            if hasLocalCompletionMarker(descriptor.id) {
                UserDefaults.standard.removeObject(forKey: FocusPersistence.localCompletionIDKey)
            }
            return existing
        }
        let historyMetrics = try? HomeProjectionPolicy.completionMetrics(
            context: modelContext,
            resetMarkers: resetSnapshots,
            roots: acceptedAggregateRoots,
            looseSessions: looseSessions,
            at: descriptor.createdAt
        )
        var measuredCompletionDates = historyMetrics?.weeklyMeasuredDates ?? []
        if historyMetrics?.weeklyMeasuredSessionIDs.contains(descriptor.id) != true {
            // SwiftData query delivery can trail completion preparation.
            // Include the locally committed
            // timer exactly once so the completion card never says “0”.
            measuredCompletionDates.append(descriptor.createdAt)
        }
        let weeklyCompletionCount = WeeklyProgressPolicy.completionCount(
            dates: measuredCompletionDates,
            at: descriptor.createdAt
        )
        var weeklyStudyGrams = historyMetrics?.weeklyMeasuredGrams ?? 0
        if historyMetrics?.weeklyMeasuredSessionIDs.contains(descriptor.id) != true {
            weeklyStudyGrams = HomeProjectionPolicy.saturatingNonnegativeSum([
                weeklyStudyGrams,
                descriptor.grams
            ])
        }
        let minutes = FocusRestCadenceStore.record(
            sessionID: descriptor.id,
            contributionGrams: descriptor.grams
        )
        // Freeze the projection when preparing the completion message. A delayed live read
        // can change underneath the user while CloudKit or a decimal fusion is
        // being applied, making the receipt claim a precision it does not have.
        let receipt = PendingRewardReceipt(
            id: descriptor.id,
            createdAt: descriptor.createdAt,
            breakMinutes: minutes,
            grams: descriptor.grams,
            subjectName: descriptor.subjectName,
            colorHex: descriptor.colorHex,
            weeklyCompletionCount: max(1, weeklyCompletionCount),
            weeklyStudyGrams: weeklyStudyGrams,
            kind: descriptor.kind,
            rareRewardDrawCount: descriptor.rareRewardCounts.drawCount,
            goldRewardCount: descriptor.rareRewardCounts.goldCount,
            prismRewardCount: descriptor.rareRewardCounts.prismCount,
            totalPebbleCount: max(1, totalPebbles),
            totalStudyGrams: max(descriptor.grams, totalGrams),
            projectionIsLowerBound: localProjectionNeedsMaintenance,
            projectionWasCloudUnverified:
                aggregateProjectionPresentation.isCloudVerificationPending,
            projectionCacheStamp:
                aggregateProjectionPresentation.verifiedCacheStamp,
            dropPhase: dropPhase
        )
        // Persist before consuming the one-shot completion marker. If the process
        // dies at any later instruction, Home can still recover this exact
        // receipt once without awarding or saving the session again.
        guard PendingRewardReceiptStore.insert(receipt) else { return nil }
        UserDefaults.standard.removeObject(forKey: FocusPersistence.localCompletionIDKey)
        scheduleReviewRequestIfEarned()
        return receipt
    }

    private func recoverPendingRewardReceipt() {
        let receipts = PendingRewardReceiptStore.load()
        guard breakOffer == nil,
              breakOfferTask == nil,
              homeIsVisible,
              !router.focusPresentationIsActive,
              !rewardDropRevealIsPending,
              rewardDropDestination == nil,
              focusConfiguration == nil,
              router.recoveredFocus == nil,
              breakConfiguration == nil,
              router.recoveredBreak == nil,
              router.selectedTab == .jar,
              !router.sharePresented,
              !receipts.contains(where: { $0.dropPhase == .awaitingLanding }),
              let receipt = receipts.first(where: {
                  $0.dropPhase != .awaitingLanding
              })
        else { return }
        // New receipts precede the first fall; legacy receipts have already
        // landed. Neither may be presented behind the active timer.
        scheduleRewardReceipt(receipt, delay: .milliseconds(280))
    }

    private func scheduleRewardReceipt(
        _ receipt: PendingRewardReceipt,
        delay: Duration
    ) {
        // Receipts form a tiny FIFO. Never cancel or overwrite a visible
        // earlier completion; acknowledging it drains the next durable item.
        guard breakOffer == nil, breakOfferTask == nil else { return }
        breakOfferTask = Task { @MainActor in
            // New receipts precede the fall. The legacy landing path leaves
            // room for its existing thud and mass toast before the card.
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            guard homeIsVisible,
                  !router.focusPresentationIsActive,
                  focusConfiguration == nil,
                  router.recoveredFocus == nil
            else {
                breakOfferTask = nil
                return
            }
            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.86)) {
                breakOffer = BreakOffer(receipt: receipt)
            }
            breakOfferTask = nil
        }
    }

    private func hasLocalCompletionMarker(_ sessionID: UUID) -> Bool {
        guard let value = UserDefaults.standard.string(
            forKey: FocusPersistence.localCompletionIDKey
        ) else { return false }
        return value.caseInsensitiveCompare(sessionID.uuidString) == .orderedSame
    }

    private func retireRewardReceipt(_ offer: BreakOffer) {
        PendingRewardReceiptStore.remove(id: offer.id)
        if hasLocalCompletionMarker(offer.id) {
            UserDefaults.standard.removeObject(forKey: FocusPersistence.localCompletionIDKey)
        }
    }

    private func hasLocalCompletionMarker(_ session: StudySession) -> Bool {
        guard let value = UserDefaults.standard.string(forKey: FocusPersistence.localCompletionIDKey)
        else { return false }
        return value.caseInsensitiveCompare(session.id.uuidString) == .orderedSame
    }

    private func scheduleReviewRequestIfEarned() {
        // System review UI is outside the app's accessibility tree and can
        // intercept the next spatial interaction in deterministic UI audits.
        // Keep the production milestone unchanged, but never mutate or consume
        // review state in an explicitly opted-in local UI-test process.
        guard !LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess else { return }
        let defaults = UserDefaults.standard
        let countKey = AccountScopedLocalState.defaultsKey(
            base: "review.local-completion-count"
        )
        let firstCompletionKey = AccountScopedLocalState.defaultsKey(
            base: "review.first-local-completion-date"
        )
        let now = Date.now
        let storedCount = max(0, defaults.integer(forKey: countKey))
        let count = storedCount == Int.max ? Int.max : storedCount + 1
        defaults.set(count, forKey: countKey)
        let firstCompletionDate: Date
        if let stored = defaults.object(forKey: firstCompletionKey) as? Date {
            firstCompletionDate = stored
        } else {
            firstCompletionDate = now
            defaults.set(now, forKey: firstCompletionKey)
        }
        guard ReviewRequestPolicy.isEarned(
            completionCount: count,
            firstCompletionDate: firstCompletionDate,
            now: now
        ),
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return }
        let versionKey = AccountScopedLocalState.defaultsKey(
            base: "review.requested-version"
        )
        guard defaults.string(forKey: versionKey) != version else { return }
        // Defer the request until the rest offer or any aggregation celebration
        // has been dismissed. `celebrationPresentationBlockers` will retry at
        // the next genuinely quiet home state.
        defaults.set(
            version,
            forKey: AccountScopedLocalState.defaultsKey(
                base: "review.pending-version"
            )
        )
    }

    private func schedulePendingReviewRequestIfPossible() {
        // Also quarantine a pending value left by an earlier Simulator launch;
        // guarding only the earning path would still allow that modal to appear.
        guard !LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess else { return }
        let defaults = UserDefaults.standard
        let pendingVersionKey = AccountScopedLocalState.defaultsKey(
            base: "review.pending-version"
        )
        let requestedVersionKey = AccountScopedLocalState.defaultsKey(
            base: "review.requested-version"
        )
        guard let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
              defaults.string(forKey: pendingVersionKey) == currentVersion,
              defaults.string(forKey: requestedVersionKey) != currentVersion
        else { return }

        reviewRequestTask?.cancel()
        reviewRequestTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled,
                  !celebrationPresentationBlockers.contains(true),
                  completedStratum == nil,
                  stratumCelebrationQueue.isEmpty
            else { return }
            defaults.set(currentVersion, forKey: requestedVersionKey)
            defaults.removeObject(forKey: pendingVersionKey)
            requestReview()
        }
    }

    private func scheduleShareChipIfNeeded(for newSessions: [StudySession]) {
        guard newSessions.contains(where: { $0.effectiveSource == .timer }) else { return }
        let dayKey = FairnessPolicy.deviceDayKey(for: .now)
        let promptKey = AccountScopedLocalState.defaultsKey(
            base: "share.prompt.\(dayKey)"
        )
        guard !UserDefaults.standard.bool(forKey: promptKey), shareChipTask == nil else { return }
        shareChipTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Constants.Share.completionChipDelay))
            guard !Task.isCancelled else { return }
            UserDefaults.standard.set(true, forKey: promptKey)
            withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.82)) {
                showShareChip = true
            }
            shareChipTask = nil
        }
    }

    private func publishWidgetSnapshot() {
        let acceptedRoots = activeAggregateRoots
        let fullyMeasuredRoots = acceptedRoots.filter {
            $0.manualPebbleCount == 0
                && $0.measuredPebbleCount == $0.pebbleCount
        }
        let uniqueSessions = StudySessionSyncPolicy.canonicalSessions(from: sessions)
        let looseMeasured = uniqueSessions.filter {
            $0.effectiveSource.isMeasured
                && !representedSessionIDs.contains($0.id)
        }
        let measuredSessionGrams = uniqueSessions
            .filter { $0.effectiveSource.isMeasured }
            .map(\.grams)
        let aggregateMeasuredGrams = HomeProjectionPolicy.saturatingNonnegativeSum([
            HomeProjectionPolicy.saturatingNonnegativeSum(
                fullyMeasuredRoots.map(\.grams)
            ),
            HomeProjectionPolicy.saturatingNonnegativeSum(looseMeasured.map(\.grams))
        ])
        let sessionRewards = RareRewardCounts.total(
            uniqueSessions.map(\.rareRewardCounts)
        )
        let looseRewards = RareRewardCounts.total(uniqueSessions.filter {
            !representedSessionIDs.contains($0.id)
        }.map(\.rareRewardCounts))
        let aggregateGoldCount = HomeProjectionPolicy.saturatingNonnegativeSum(
            acceptedRoots.map(\.goldPebbleCount)
        )
        let aggregatePrismCount = HomeProjectionPolicy.saturatingNonnegativeSum(
            acceptedRoots.map(\.prismPebbleCount)
        )
        let metadata = WidgetSnapshotMetadata(
            totalGrams: totalGrams,
            measuredGrams: max(
                HomeProjectionPolicy.saturatingNonnegativeSum(measuredSessionGrams),
                aggregateMeasuredGrams
            ),
            pebbleCount: totalPebbles,
            goldCount: max(
                sessionRewards.goldCount,
                HomeProjectionPolicy.saturatingNonnegativeSum([
                    aggregateGoldCount,
                    looseRewards.goldCount
                ])
            ),
            prismCount: max(
                sessionRewards.prismCount,
                HomeProjectionPolicy.saturatingNonnegativeSum([
                    aggregatePrismCount,
                    looseRewards.prismCount
                ])
            )
        )
        Task {
            try? await JarSnapshotter.shared.publishWidgetSnapshot(of: scene, metadata: metadata)
        }
    }

    private func scheduleWidgetSnapshot() {
        widgetRefreshTask?.cancel()
        widgetRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            publishWidgetSnapshot()
        }
    }

    private func scheduleTiltHintIfNeeded() {
        let isVoiceOverHint = voiceOverEnabled
        let hasSeenCurrentHint = isVoiceOverHint ? didSeeVoiceOverTapHint : didSeeTapHint
        guard !hasSeenCurrentHint,
              !isJarEmpty,
              tiltHintTask == nil
        else { return }
        tiltHintTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                showsTiltHint = true
            }
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) {
                showsTiltHint = false
            }
            if isVoiceOverHint {
                didSeeVoiceOverTapHint = true
            } else {
                didSeeTapHint = true
            }
            tiltHintTask = nil
        }
    }

    private var jarInteractionHintText: String {
        if voiceOverEnabled {
            return "瓶をダブルタップすると粒が跳ねます。VoiceOverのカスタムアクションで左右にも動かせます"
        }
#if targetEnvironment(macCatalyst)
        return "瓶をタップすると粒が跳ね、左右にドラッグすると転がります"
#else
        return "瓶をタップすると粒が跳ね、iPhoneを傾けると転がります"
#endif
    }

    private var jarInteractionHintSymbol: String {
        "hand.tap"
    }

    private func revealAggregateInspection(_ aggregateID: UUID) {
        guard inspectionSummary(for: aggregateID) != nil else { return }
        cancelTiltHintPresentation()
        aggregateInspectionTask?.cancel()
        aggregateInspectionTask = nil

        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)) {
            aggregateInspectionID = aggregateID
        }
        aggregateInspectionTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(6))
            } catch {
                return
            }
            guard aggregateInspectionID == aggregateID else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                aggregateInspectionID = nil
            }
            aggregateInspectionTask = nil
        }
    }

    private func presentAggregateDetail(_ summary: AccumulationClusterSummary) {
        cancelTiltHintPresentation()
        aggregateInspectionTask?.cancel()
        aggregateInspectionTask = nil
        aggregateInspectionID = nil
        selectedAggregateDetail = summary
    }

    private func presentAggregateDetail(_ aggregateID: UUID) {
        guard let summary = inspectionSummary(for: aggregateID) else { return }
        presentAggregateDetail(summary)
    }

    private func reconcileAggregateInspection() {
        if let selectedAggregateDetail {
            guard let refreshed = inspectionSummary(
                for: selectedAggregateDetail.id
            ) else {
                self.selectedAggregateDetail = nil
                invalidateAggregateInspectionCard()
                return
            }
            if refreshed != selectedAggregateDetail {
                self.selectedAggregateDetail = refreshed
            }
        }

        guard let aggregateInspectionID,
              inspectionSummary(for: aggregateInspectionID) == nil
        else { return }
        invalidateAggregateInspectionCard()
    }

    private func inspectionSummary(
        for aggregateID: UUID
    ) -> AccumulationClusterSummary? {
        if let aggregate = activeAggregateRoots.first(where: {
            $0.id == aggregateID
        }) {
            return AccumulationClusterSummary(
                aggregate: aggregate,
                sessionIDs: []
            )
        }
        guard let legacy = activeLegacyStratumVisuals.first(where: {
            $0.id == aggregateID
        }) else { return nil }
        return AccumulationClusterSummary(legacyStratum: legacy)
    }

    private func invalidateAggregateInspection() {
        selectedAggregateDetail = nil
        invalidateAggregateInspectionCard()
    }

    private func invalidateAggregateInspectionCard() {
        aggregateInspectionTask?.cancel()
        aggregateInspectionTask = nil
        aggregateInspectionID = nil
    }

    private func aggregateInspectionButton(
        _ summary: AccumulationClusterSummary
    ) -> some View {
        Button {
            presentAggregateDetail(summary)
        } label: {
            aggregateInspectionCardLabel
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .frame(maxWidth: 350, minHeight: 52)
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 18)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(PomoGemTheme.amber.opacity(0.34), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(summary.pebbleCount.formatted())粒のまとまり、\(aggregateInspectionSubtitle(summary))"
        )
        .accessibilityHint(
            summary.hasStrongPreservationEvidence
                ? "色、テーマ、期間などの内訳を表示します"
                : (summary.colorMix.isEmpty
                    ? "保存されている粒数、質量などを表示します"
                    : "保存されている色、粒数、質量などを表示します")
        )
        .accessibilityIdentifier("jar.aggregate.inspect")
    }

    @ViewBuilder
    private var aggregateInspectionSlot: some View {
        if let aggregateID = latestInspectableAggregateID,
           let restingSummary = inspectionSummary(for: aggregateID) {
            let presentedSummary = aggregateInspectionSummary ?? restingSummary
            let isPresented = aggregateInspectionSummary != nil

            ZStack {
                // Keep the larger state in the layout even while hidden. That
                // makes the launcher below the jar stay put without clipping
                // this card at accessibility Dynamic Type sizes.
                aggregateInspectionButton(presentedSummary)
                    .opacity(isPresented ? 1 : 0)
                    .allowsHitTesting(isPresented)
                    .accessibilityHidden(!isPresented)

                Label(
                    "まとまり粒をタップすると、内訳を見られます",
                    systemImage: "hand.tap"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PomoGemTheme.muted)
                .multilineTextAlignment(.center)
                .opacity(isPresented ? 0 : 1)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var aggregateInspectionCardLabel: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    aggregateInspectionIcon
                    Text("まとまり粒を見つけました")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PomoGemTheme.text)
                }
                Text("保存されている粒数・質量などの内訳")
                    .font(.caption2)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Text("内訳を見る")
                    Image(systemName: "chevron.right")
                        .accessibilityHidden(true)
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(PomoGemTheme.amber)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 11) {
                aggregateInspectionIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text("まとまり粒を見つけました")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PomoGemTheme.text)
                    Text("保存されている粒数・質量などの内訳")
                        .font(.caption2)
                        .foregroundStyle(PomoGemTheme.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Text("内訳を見る")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PomoGemTheme.amber)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PomoGemTheme.amber)
                    .accessibilityHidden(true)
            }
        }
    }

    private var aggregateInspectionIcon: some View {
        Image(systemName: "circle.grid.3x3.fill")
            .font(.title3.weight(.bold))
            .foregroundStyle(PomoGemTheme.amber)
            .frame(width: 32, height: 32)
            .background(
                PomoGemTheme.amber.opacity(0.12),
                in: Circle()
            )
            .accessibilityHidden(true)
    }

    private func aggregateInspectionSubtitle(
        _ summary: AccumulationClusterSummary
    ) -> String {
        if !summary.hasStrongPreservationEvidence {
            return summary.colorMix.isEmpty
                ? "粒数・質量など、保存済みの内訳"
                : "色・粒数・質量など、保存済みの内訳"
        }
        let subjects = summary.subjectMix
            .filter { $0.pebbleCount > 0 }
            .sorted { lhs, rhs in
                if lhs.pebbleCount == rhs.pebbleCount {
                    return lhs.name.localizedStandardCompare(rhs.name)
                        == .orderedAscending
                }
                return lhs.pebbleCount > rhs.pebbleCount
            }
        guard !subjects.isEmpty else {
            return "色・粒数・質量など、保存済みの内訳"
        }
        var parts = subjects.prefix(2).map {
            "\($0.name)\($0.pebbleCount.formatted())粒"
        }
        if subjects.count > 2 {
            parts.append("ほか\(subjects.count - 2)件")
        }
        return parts.joined(separator: "・")
    }

    private func cancelTiltHintPresentation() {
        tiltHintTask?.cancel()
        tiltHintTask = nil
        showsTiltHint = false
    }

    private func announcePostDropOfferIfNeeded(for offer: BreakOffer) {
        guard voiceOverEnabled,
              breakOffer?.id == offer.id,
              announcedPostDropOfferID != offer.id
        else { return }
        announcedPostDropOfferID = offer.id

        let progressMessage = (
            aggregateProjectionPresentation.isCloudVerificationPending
                || offer.projectionWasCloudUnverified
                || !canPublishBreakOfferProjection(offer)
        )
            ? (aggregateProjectionPresentation.isCloudVerificationPending
                ? "\(projectionVerificationTitle)。今回の記録は保存済みです。生涯合計は確認後に表示します"
                : "集計を更新しました。今回の記録は保存済みです。更新前の生涯合計は再利用しません")
            : PostDropProgressAccessibilityPresentation.description(
                effortProgress: offer.effortProgress,
                fusionState: offer.fusionState,
                projectionIsLowerBound: offer.projectionIsLowerBound
            )
        let historyMessage = offer.projectionWasCloudUnverified
                || !canPublishBreakOfferProjection(offer)
            ? "今回の記録は保存済みです"
            : offer.weeklySpokenTitle
        var message = "\(offer.dropTitle(for: rareRewardMode))\(offer.subjectName)、\(offer.grams)グラム、\(EffortProgressPresentation.formattedStandardUnits(grams: offer.grams))。\(historyMessage)。\(offer.rareRewardCounts.multiDrawSummary.map { "\($0)。" } ?? "")\(progressMessage)。\(offer.minutes)分休憩できます"
        if showShareChip {
            message += "。今の瓶をカードにして共有できます"
            announcedPostDropShareOfferID = offer.id
        }
        postLowPriorityAccessibilityAnnouncement(message)
    }

    private func announcePostDropShareIfNeeded(for offer: BreakOffer) {
        guard voiceOverEnabled,
              showShareChip,
              breakOffer?.id == offer.id,
              announcedPostDropShareOfferID != offer.id
        else { return }
        announcedPostDropShareOfferID = offer.id
        postLowPriorityAccessibilityAnnouncement("今の瓶をカードにする共有ボタンが利用できます")
    }

    private func postLowPriorityAccessibilityAnnouncement(_ message: String) {
        var announcement = AttributedString(message)
        announcement.accessibilitySpeechAnnouncementPriority = .low
        AccessibilityNotification.Announcement(announcement).post()
    }

    private func recoverInterruptionNotice() {
        guard UserDefaults.standard.bool(forKey: FocusPersistence.interruptedFlagKey) else { return }
        UserDefaults.standard.removeObject(forKey: FocusPersistence.interruptedFlagKey)
        router.showToast(Constants.UIStrings.processTerminatedNote, symbol: "exclamationmark.circle")
    }

    private func formattedMass(_ grams: Int) -> String {
        guard grams >= 1_000 else { return "\(grams) g" }
        let value = Double(grams) / 1_000
        return grams.isMultiple(of: 1_000)
            ? "\(grams / 1_000) kg"
            : String(format: "%.2f kg", value)
    }
}

private extension PendingStratumCelebration {
    init(
        request: JarBakeRequest,
        projectionCacheStamp: AggregateProjectionCacheStamp?
    ) {
        self.init(
            id: request.id,
            createdAt: request.createdAt,
            pebbleCount: request.pebbleCount,
            grams: request.grams,
            monthLabel: request.monthLabel,
            colorHex: request.outputDescriptor.colorHex,
            level: request.outputLevel,
            projectionCacheStamp: projectionCacheStamp
        )
    }
}

/// Keeps the automatic VoiceOver announcement on the same value hierarchy as
/// the visible completion card. Count-based fusion remains available as a
/// secondary storage explanation and as a compatibility path for old receipts.
enum PostDropProgressAccessibilityPresentation {
    static func description(
        effortProgress: EffortProgressSnapshot?,
        fusionState: FusionRewardBridgeState,
        projectionIsLowerBound: Bool
    ) -> String {
        let physicalDisplay = FusionRewardBridgePresentation.display(
            state: fusionState,
            projectionIsLowerBound: projectionIsLowerBound
        )
        if let effortProgress {
            let effortDisplay = EffortProgressPresentation.display(
                snapshot: effortProgress,
                projectionIsLowerBound: projectionIsLowerBound
            )
            return "\(effortDisplay.accessibilityLabel)。瓶の整理：\(physicalDisplay.accessibilityLabel)"
        }

        // Receipts from builds before mass was captured keep their original,
        // internally consistent count presentation for this one replay.
        var legacyProgress = "\(physicalDisplay.progressLabel)。\(physicalDisplay.nextStepLabel)"
        if let longTermContextLabel = physicalDisplay.longTermContextLabel {
            legacyProgress += "。\(longTermContextLabel)"
        }
        return legacyProgress
    }
}

/// One presentation of the focus cover. `id` doubles as the focus session ID,
/// and the reset epoch is captured with it, so every re-render of Home rebuilds
/// FocusView against the same session-scoped queries.
private struct FocusConfiguration: Identifiable {
    let id = UUID()
    let subject: Subject
    let duration: PomodoroDuration
    let dataEpochID: UUID?
}

private struct RewardDropContinuation {
    enum Destination {
        case home
        case rest(BreakRecoveryEnvelope)
        case share
    }

    let sessionID: UUID
    let destination: Destination
    var hasLanded = false
}

private struct BreakOffer: Identifiable {
    let id: UUID
    let minutes: Int
    let grams: Int
    let subjectName: String
    let colorHex: String
    let weeklyCompletionCount: Int
    let weeklyStudyGrams: Int?
    let kind: PebbleKind
    let rareRewardCounts: RareRewardCounts
    let fusionState: FusionRewardBridgeState
    let effortProgress: EffortProgressSnapshot?
    let projectionIsLowerBound: Bool
    let projectionWasCloudUnverified: Bool
    let projectionCacheStamp: AggregateProjectionCacheStamp?
    let isAwaitingDrop: Bool

    init(receipt: PendingRewardReceipt) {
        isAwaitingDrop = receipt.requiresDrop
        id = receipt.id
        minutes = receipt.breakMinutes
        grams = receipt.grams
        subjectName = receipt.subjectName
        colorHex = receipt.colorHex
        weeklyCompletionCount = receipt.weeklyCompletionCount
        weeklyStudyGrams = receipt.weeklyStudyGrams
        kind = RareRewardPresentationPolicy.kind(receipt.kind)
        if let drawCount = receipt.rareRewardDrawCount,
           let goldCount = receipt.goldRewardCount,
           let prismCount = receipt.prismRewardCount {
            rareRewardCounts = RareRewardPresentationPolicy.counts(RareRewardCounts(
                drawCount: drawCount,
                goldCount: goldCount,
                prismCount: prismCount
            ))
        } else {
            rareRewardCounts = RareRewardPresentationPolicy.counts(RareRewardCounts(
                outcomes: receipt.kind == .normal ? [] : [receipt.kind]
            ))
        }
        fusionState = FusionRewardBridgePresentation.state(
            totalPebbleCount: receipt.totalPebbleCount
        )
        effortProgress = receipt.totalStudyGrams.map {
            EffortProgressPolicy.snapshot(
                totalGrams: $0,
                latestContributionGrams: receipt.grams
            )
        }
        projectionIsLowerBound = receipt.projectionIsLowerBound
        projectionWasCloudUnverified =
            receipt.projectionWasCloudUnverified ?? false
        projectionCacheStamp = receipt.projectionCacheStamp
    }

    func heroColorHex(for mode: RareRewardMode) -> String {
        guard mode.usesEnhancedPresentation else { return colorHex }
        return switch kind {
        case .normal: colorHex
        case .gold: Constants.Color.pebbleGold
        case .prism: Constants.Color.auroraViolet
        }
    }

    func dropTitle(for mode: RareRewardMode) -> String {
        if isAwaitingDrop { return "集中を記録しました。" }
        if !mode.usesEnhancedPresentation {
            return switch kind {
            case .normal: "一粒、着地。"
            case .gold: "金の粒を積みました。"
            case .prism: "虹の粒を積みました。"
            }
        }
        return switch kind {
        case .normal: "一粒、着地。"
        case .gold: "金の粒、着地。"
        case .prism: "虹の粒、着地。"
        }
    }

    var weeklyTitle: String {
        if let weeklyStudyGrams {
            return "今週 \(formattedWeeklyMass(weeklyStudyGrams)) ・ 戻った\(weeklyCompletionCount)回"
        }
        return "今週戻った\(weeklyCompletionCount)回（時間価値とは別）"
    }

    var weeklySpokenTitle: String {
        if let weeklyStudyGrams {
            return "今週記録した集中時間の質量\(formattedWeeklyMass(weeklyStudyGrams))。戻った回数\(weeklyCompletionCount)回。回数は時間価値とは別です"
        }
        return "今週戻った回数\(weeklyCompletionCount)回。回数は時間価値とは別です"
    }

    private func formattedWeeklyMass(_ grams: Int) -> String {
        let value = max(0, grams)
        guard value >= 1_000 else { return "\(value)g" }
        let kilograms = Double(value) / 1_000
        return kilograms.rounded() == kilograms
            ? "\(Int(kilograms))kg"
            : String(format: "%.2fkg", kilograms)
    }
}

private struct AchievementDraft {
    let kind: AchievementKind
    let note: String
    let achievedAt: Date
}

private struct AchievementEntrySheet: View {
    let subjects: [Subject]
    let onAdd: (Subject, AchievementDraft) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var selectedKind: AchievementKind?
    @State private var selectedSubjectID: UUID?
    @State private var note = ""
    @State private var achievedAt = Date.now
    @State private var isSubmitting = false

    init(
        initialSubject: Subject?,
        subjects: [Subject],
        onAdd: @escaping (Subject, AchievementDraft) -> Bool
    ) {
        self.subjects = subjects
        self.onAdd = onAdd
        let initialID = initialSubject.flatMap { initial in
            subjects.contains(where: { $0.id == initial.id }) ? initial.id : nil
        } ?? subjects.first?.id
        _selectedSubjectID = State(initialValue: initialID)
    }

    private var selectedSubject: Subject? {
        subjects.first { $0.id == selectedSubjectID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let selectedKind {
                        detailsStep(kind: selectedKind)
                    } else {
                        kindStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(NightBackground())
            .navigationTitle(selectedKind == nil ? "成果を選ぶ" : "記念石にする")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if selectedKind != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("戻る") { selectedKind = nil }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PomoGemSheetCloseButton(
                        accessibilityIdentifier: "achievement.create.close"
                    ) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var kindStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                SectionEyebrow(text: "MILESTONE")
                Text("どんな成果だった？")
                    .font(PomoGemTheme.brand(26))
                Text(achievementIntroduction)
                    .font(.subheadline)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(AchievementKind.allCases) { kind in
                Button {
                    selectedKind = kind
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: kind.systemImage)
                            .font(.title2)
                            .foregroundStyle(PomoGemTheme.amber)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.title)
                                .font(.system(.headline, design: .rounded, weight: .bold))
                            Text(kind.detail)
                                .font(.caption)
                                .foregroundStyle(PomoGemTheme.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                    .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(PomoGemBareButtonStyle())
            }
        }
    }

    private var achievementIntroduction: String {
        "満点・試験合格・納品・公開などの節目を、集中時間とは別のひとまわり大きな記念石として残せます。"
    }

    private func detailsStep(kind: AchievementKind) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: kind.systemImage)
                    .font(.title)
                    .foregroundStyle(PomoGemTheme.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .font(PomoGemTheme.brand(24))
                    Text(selectedSubject?.safeDisplayName ?? "テーマを選んでください")
                        .font(.subheadline)
                        .foregroundStyle(PomoGemTheme.muted)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("テーマ")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PomoGemTheme.muted)
                Menu {
                    ForEach(subjects) { subject in
                        Button {
                            selectedSubjectID = subject.id
                        } label: {
                            if selectedSubjectID == subject.id {
                                Label(subject.safeDisplayName, systemImage: "checkmark")
                            } else {
                                Text(subject.safeDisplayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(hex: selectedSubject?.colorHex ?? Constants.Color.textMute))
                            .frame(width: 12, height: 12)
                            .accessibilityHidden(true)
                        Text(selectedSubject?.safeDisplayName ?? "選択してください")
                            .font(.system(.body, design: .rounded, weight: .bold))
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(PomoGemTheme.text)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(PomoGemTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("テーマ、\(selectedSubject?.safeDisplayName ?? "未選択")")
                .accessibilityHint("成果を結びつけるテーマを変更できます")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("成果名（任意）")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PomoGemTheme.muted)
                TextField(kind.notePlaceholder, text: $note)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .background(PomoGemTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: note) { _, value in
                        note = AchievementStone.sanitizedNote(value)
                    }
            }

            DatePicker(
                "達成した日",
                selection: $achievedAt,
                in: ...Date.now,
                displayedComponents: .date
            )
            .datePickerStyle(.compact)

            Label(
                "記念石は0gで、集中時間・質量・通常の粒数には加わりません。瓶では新しい12個が動き、前の石も記録棚にずっと残ります。",
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(PomoGemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                guard !isSubmitting else { return }
                guard let selectedSubject else { return }
                isSubmitting = true
                let saved = onAdd(
                    selectedSubject,
                    AchievementDraft(kind: kind, note: note, achievedAt: achievedAt)
                )
                if saved {
                    dismiss()
                } else {
                    isSubmitting = false
                }
            } label: {
                if isSubmitting {
                    ProgressView().tint(PomoGemTheme.background)
                } else {
                    Label("この成果を積む", systemImage: "medal.fill")
                }
            }
            .buttonStyle(PomoGemPrimaryButtonStyle())
            .disabled(selectedSubject == nil || isSubmitting)
        }
    }
}

private struct ManualEntrySheet: View {
    let subject: Subject?
    let counterState: ManualCounterState
    let onAdd: (ManualDuration) -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var selectedDuration: ManualDuration?
    @State private var isSubmitting = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(at: context.date)
        }
    }

    private func content(at date: Date) -> some View {
        let availability = FairnessPolicy.manualEntryAvailability(
            state: counterState,
            at: date
        )

        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    remainingCount(availability)
                    durationButtons(isEnabled: availability.isAllowed && subject != nil)
                    if let selectedDuration, availability.isAllowed {
                        confirmationCard(
                            duration: selectedDuration,
                            availability: availability
                        )
                    }
                    fairnessCopy
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(NightBackground())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PomoGemSheetCloseButton { dismiss() }
                }
            }
        }
        .onChange(of: availability.isAllowed) { _, isAllowed in
            if !isAllowed {
                selectedDuration = nil
                isSubmitting = false
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionEyebrow(text: "SELF-REPORTED")
            Text("手動で積む")
                .font(PomoGemTheme.brand(26))
            Text(subject?.safeDisplayName ?? "テーマを選んでください")
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func remainingCount(_ availability: ManualEntryAvailability) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: availability.isAllowed ? "checkmark.circle.fill" : "clock.badge.xmark")
                .font(.title3)
                .foregroundStyle(availability.isAllowed ? PomoGemTheme.amber : PomoGemTheme.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("この端末で本日あと\(availability.remainingEntries)回")
                    .font(.headline)
                    .accessibilityIdentifier("manual.remaining-count")
                Text(
                    availability.isAllowed
                        ? "選んだだけでは保存されません。次の画面で内容を確認できます。"
                        : "この端末での本日の上限です。朝4:00に3回へ切り替わります。"
                )
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PomoGemTheme.raised, in: RoundedRectangle(cornerRadius: 13))
    }

    private var fairnessCopy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(Constants.UIStrings.fairnessNote, systemImage: "circle.dashed")
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("この端末で1日3回まで・朝4:00に回数が切り替わります")
                .font(.caption2)
                .foregroundStyle(PomoGemTheme.muted)
        }
    }

    private func confirmationCard(
        duration: ManualDuration,
        availability: ManualEntryAvailability
    ) -> some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionEyebrow(text: "CONFIRM")
                    Text("この内容で積みますか？")
                        .font(PomoGemTheme.brand(21))
                }

                VStack(spacing: 10) {
                    confirmationRow(title: "テーマ", value: subject?.safeDisplayName ?? "未選択")
                    confirmationRow(title: "時間", value: durationTitle(duration))
                    confirmationRow(title: "加算", value: "+\(duration.grams)g")
                    confirmationRow(
                        title: "保存後",
                        value: "この端末で本日あと\(availability.remainingEntriesAfterSaving)回"
                    )
                }

                Button {
                    guard !isSubmitting else { return }
                    isSubmitting = true
                    if !onAdd(duration) {
                        isSubmitting = false
                    }
                } label: {
                    if isSubmitting {
                        ProgressView().tint(PomoGemTheme.background)
                    } else {
                        Label("確認して積む", systemImage: "plus.circle.fill")
                    }
                }
                .buttonStyle(PomoGemPrimaryButtonStyle())
                .disabled(subject == nil || !availability.isAllowed || isSubmitting)
                .accessibilityIdentifier("manual.confirm")
            }
        }
    }

    private func confirmationRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PomoGemTheme.muted)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.bold))
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func durationTitle(_ duration: ManualDuration) -> String {
        switch duration {
        case .thirtyMinutes: "30分"
        case .sixtyMinutes: "1時間"
        case .oneHundredTwentyMinutes: "2時間"
        }
    }

    @ViewBuilder
    private func durationButtons(isEnabled: Bool) -> some View {
        if dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact {
            VStack(spacing: 10) {
                manualButtons(isEnabled: isEnabled)
            }
        } else {
            HStack(spacing: 10) {
                manualButtons(isEnabled: isEnabled)
            }
        }
    }

    @ViewBuilder
    private func manualButtons(isEnabled: Bool) -> some View {
        ManualButton(
            title: "30分",
            grams: 300,
            selected: selectedDuration == .thirtyMinutes,
            isEnabled: isEnabled
        ) { selectedDuration = .thirtyMinutes }
        ManualButton(
            title: "1時間",
            grams: 600,
            selected: selectedDuration == .sixtyMinutes,
            isEnabled: isEnabled
        ) { selectedDuration = .sixtyMinutes }
        ManualButton(
            title: "2時間",
            grams: 1_200,
            selected: selectedDuration == .oneHundredTwentyMinutes,
            isEnabled: isEnabled
        ) { selectedDuration = .oneHundredTwentyMinutes }
    }
}

private struct ManualButton: View {
    let title: String
    let grams: Int
    let selected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(title).font(.system(.headline, design: .rounded, weight: .bold))
                Text("+\(grams)g")
                    .font(.caption)
                    .foregroundStyle(
                        selected
                            ? PomoGemTheme.background.opacity(0.72)
                            : PomoGemTheme.muted
                    )
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 78)
            .foregroundStyle(selected ? PomoGemTheme.background : PomoGemTheme.text)
            .background(
                selected ? PomoGemTheme.amber : PomoGemTheme.raised,
                in: RoundedRectangle(cornerRadius: 13)
            )
        }
        .buttonStyle(PomoGemBareButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel("\(title)、\(grams)グラム加算")
        .accessibilityHint(isEnabled ? "内容の確認へ進みます" : "本日の手動追加上限です")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct StratumCelebrationView: View {
    let request: PendingStratumCelebration
    let showsMonthLabel: Bool
    let onExplore: () -> Void
    let onShare: () -> Void
    let onContinue: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var colorHex: String {
        request.colorHex ?? Constants.Color.amberLamp
    }

    private var level: Int {
        max(
            1,
            request.level ?? StrataMath.decimalAggregateLevel(
                forPebbleCount: request.pebbleCount
            )
        )
    }

    private var orbitState: FusionOrbitStageState {
        FusionOrbitStagePresentation.completedAggregate(
            pebbleCount: request.pebbleCount,
            level: level
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    SectionEyebrow(text: "LOSSLESS STORAGE")

                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(
                                RadialGradient(
                                    colors: [
                                        Color(hex: colorHex).opacity(0.19),
                                        PomoGemTheme.auroraViolet.opacity(0.10),
                                        PomoGemTheme.raised.opacity(0.58)
                                    ],
                                    center: .center,
                                    startRadius: 4,
                                    endRadius: 170
                                )
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 28, style: .continuous)
                                    .stroke(Color(hex: colorHex).opacity(0.30), lineWidth: 1)
                            }

                        FusionOrbitStage(
                            state: orbitState,
                            colorHex: colorHex,
                            scale: .hero
                        )
                        .frame(width: 218, height: 218)

                        HStack(spacing: 8) {
                            Text("瓶の整理")
                                .foregroundStyle(PomoGemTheme.muted)
                            Text("10")
                            Image(systemName: "arrow.right")
                                .accessibilityHidden(true)
                            Text("1")
                            Text("・ 記録 100% 保持")
                                .foregroundStyle(PomoGemTheme.muted)
                        }
                        .font(.system(.caption, design: .rounded, weight: .black))
                        .monospacedDigit()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(PomoGemTheme.card.opacity(0.92), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.7))
                        .padding(.bottom, 10)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 244)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "瓶の整理として、10個の記録を1個の\(AggregatePresentation.title(level: level))へ圧縮。記録と質量は100パーセント保持。時間の価値は変わりません"
                    )

                    VStack(spacing: 8) {
                        Text("\(request.pebbleCount)粒を、ひとつに整理した")
                            .font(PomoGemTheme.brand(24))
                            .multilineTextAlignment(.center)
                        Text("これは瓶を軽く保つための二次的な整理です。保存表示だけを圧縮し、一粒ずつの時間も、\(formattedMass(request.grams))の質量も100%保持します。時間の核は回数でなく質量から進みます。次へ急ぐ必要はありません。")
                            .font(.subheadline)
                            .foregroundStyle(PomoGemTheme.muted)
                            .multilineTextAlignment(.center)
                    }
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(spacing: 10) {
                                celebrationStats
                            }
                        } else {
                            HStack(spacing: 10) {
                                celebrationStats
                            }
                        }
                    }
                    Button("この結晶の内訳を見る", action: onExplore)
                        .buttonStyle(PomoGemPrimaryButtonStyle())
                    Button("この結晶をカードにする", action: onShare)
                        .buttonStyle(PomoGemSecondaryButtonStyle())
                    Button("ここで休む", action: onContinue)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(PomoGemTheme.muted)
                        .frame(minHeight: 44)
                        .buttonStyle(PomoGemBareButtonStyle())
                }
                .padding(24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(NightBackground())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PomoGemSheetCloseButton(
                        accessibilityIdentifier: "fusion.celebration.close",
                        action: onContinue
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var celebrationStats: some View {
        StatPill(
            title: "まとまり",
            value: showsMonthLabel ? request.monthLabel : "\(request.pebbleCount)粒"
        )
        StatPill(title: "積んだ質量", value: formattedMass(request.grams))
        StatPill(title: "結晶", value: AggregatePresentation.title(level: level))
    }

    private func formattedMass(_ grams: Int) -> String {
        grams >= 1_000 ? String(format: "%.1fkg", Double(grams) / 1_000) : "\(grams)g"
    }
}

private struct StatPill: View {
    let title: String
    let value: String
    var body: some View {
        VStack(spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(PomoGemTheme.muted)
            Text(value).font(.system(.subheadline, design: .rounded, weight: .bold))
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Fault-scenario-only raw SwiftData audit. Home deliberately canonicalizes
/// duplicate CloudKit rows before rendering, so the ordinary jar probe cannot
/// prove that a retry created exactly one physical aggregate row. This probe is
/// mounted only behind the aggregate fault's CloudKit-free named-store gate.
@MainActor
private struct AggregatePersistenceRecoveryProbe: View {
    @Environment(\.modelContext) private var modelContext
    @State private var auditValue = "state=loading"

    var body: some View {
        Text("Aggregate persistence recovery probe")
            .font(.system(size: 1))
            .foregroundStyle(Color.clear)
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("aggregate.persistence.probe")
            .accessibilityLabel("Aggregate persistence recovery probe")
            .accessibilityValue(Text(verbatim: auditValue))
            .allowsHitTesting(false)
            .task {
                while !Task.isCancelled {
                    refreshAuditValue()
                    do {
                        try await Task.sleep(for: .milliseconds(100))
                    } catch {
                        return
                    }
                }
            }
    }

    private func refreshAuditValue() {
        do {
            let sessions = try modelContext.fetch(FetchDescriptor<StudySession>())
            let aggregates = try modelContext.fetch(FetchDescriptor<AggregatePebble>())
            let represented = AggregatePebblePolicy.directSessionIDs(from: aggregates)
            let loose = sessions.filter { !represented.contains($0.id) }
            let rootRows = aggregates.filter(\.isRoot).sorted {
                if $0.id == $1.id { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            let root = rootRows.first
            let sourceIDs = root?.sessionIDs.map(\.uuidString).sorted() ?? []
            let rootIDs = rootRows.map { $0.id.uuidString }.sorted()
            let logicalGrams = NonnegativeIntPolicy.sum(
                loose.map(\.grams) + rootRows.map(\.grams)
            )

            auditValue = [
                "sessionRows=\(sessions.count)",
                "uniqueSessionIDs=\(Set(sessions.map(\.id)).count)",
                "legacyBakedSessionRows=\(sessions.filter(\.isBaked).count)",
                "looseSessionRows=\(loose.count)",
                "aggregateRows=\(aggregates.count)",
                "uniqueAggregateIDs=\(Set(aggregates.map(\.id)).count)",
                "rootRows=\(rootRows.count)",
                "uniqueRootIDs=\(Set(rootRows.map(\.id)).count)",
                "rootIDs=\(rootIDs.joined(separator: ","))",
                "rootID=\(root?.id.uuidString ?? "none")",
                "rootGrams=\(root?.grams ?? 0)",
                "rootPebbles=\(root?.pebbleCount ?? 0)",
                "rootMeasured=\(root?.measuredPebbleCount ?? 0)",
                "rootManual=\(root?.manualPebbleCount ?? 0)",
                "rootSourceIDCount=\(sourceIDs.count)",
                "uniqueRootSourceIDs=\(Set(sourceIDs).count)",
                "rootSourceIDs=\(sourceIDs.joined(separator: ","))",
                "logicalGrams=\(logicalGrams)"
            ].joined(separator: ";")
        } catch {
            auditValue = "state=error"
        }
    }
}

@MainActor
private struct FortyYearPersistentFixtureProbe: View {
    let scene: JarScene
    let grams: Int
    let rootCount: Int
    let looseCount: Int
    let sessionRowCount: Int
    let uniqueSessionIDCount: Int

    @State private var bodyCount = 0
    @State private var queueCount = 0

    var body: some View {
        Text("40 year fixture probe")
            .font(.system(size: 1))
            .foregroundStyle(Color.clear)
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("fixture.40y.probe")
            .accessibilityLabel("40 year fixture probe")
            // This is a machine-readable DEBUG probe. `Text(verbatim:)` keeps
            // SwiftUI from applying locale grouping (for example 87,660,000),
            // so the UI test observes the same stable wire value in every locale.
            .accessibilityValue(Text(verbatim:
                "grams=\(grams);roots=\(rootCount);loose=\(looseCount);bodies=\(bodyCount);queue=\(queueCount);sessionRows=\(sessionRowCount);uniqueSessionIDs=\(uniqueSessionIDCount)"
            ))
            .allowsHitTesting(false)
            .task(id: ObjectIdentifier(scene)) {
                while !Task.isCancelled {
                    bodyCount = scene.physicalPebbleCount
                    queueCount = scene.queuedDropCount
                    do {
                        try await Task.sleep(for: .milliseconds(100))
                    } catch {
                        return
                    }
                }
            }
    }
}
#endif

#if DEBUG
/// A stateful, explicit-UI-test-only readout of the live SpriteKit
/// presentation. XCUITest cannot reliably sample a transient position from a
/// `TimelineView`: accessibility snapshots can be delivered after the pebble
/// has already settled. This probe therefore retains the upward travel
/// observed by the app's render loop. A no-op tap cannot advance the sequence
/// or its rise.
///
/// It is compiled out of Release and is mounted only when both local-preview
/// and UI-test launch flags are present, so ordinary VoiceOver users never see
/// this diagnostic accessibility element.
@MainActor
private struct JarUITestPresentationProbe: View {
    let scene: JarScene

    @State private var count = 0
    @State private var maximumY: CGFloat = 0
    @State private var records = ""
    @State private var trackedRecords: String?
    @State private var bounceSequence = 0
    @State private var lastSceneSequence = 0
    @State private var bounceRise: CGFloat = 0
    @State private var targetX: CGFloat = 0.5
    @State private var targetY: CGFloat = 0.88
    @State private var dropSequence = 0
    @State private var dropFall: CGFloat = 0
    @State private var dropLanded = false

    var body: some View {
        Text("Jar presentation probe")
            .font(.system(size: 1))
            .foregroundStyle(Color.clear)
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("jar.presentation.probe")
            .accessibilityLabel("Jar presentation probe")
            .accessibilityValue(presentationValue)
            .allowsHitTesting(false)
            .task(id: ObjectIdentifier(scene)) {
                while !Task.isCancelled {
                    samplePresentation()
                    do {
                        try await Task.sleep(for: .milliseconds(16))
                    } catch {
                        return
                    }
                }
            }
    }

    private var presentationValue: String {
        String(
            format: "count=%d;maxY=%.3f;records=%@;bounceSequence=%d;bounceRise=%.3f;targetX=%.5f;targetY=%.5f;dropSequence=%d;dropFall=%.3f;dropLanded=%d",
            count,
            Double(maximumY),
            records,
            bounceSequence,
            Double(bounceRise),
            Double(targetX),
            Double(targetY),
            dropSequence,
            Double(dropFall),
            dropLanded ? 1 : 0
        )
    }

    private func samplePresentation() {
        dropSequence = Int(truncatingIfNeeded: scene.completionDropSequence)
        dropFall = scene.completionDropMaximumFall
        dropLanded = scene.completionDropHasLanded
        var pebbles: [PebbleNode] = []
        collectPebbles(from: scene, into: &pebbles)

        let currentRecords = pebbles
            .map { "\($0.descriptor.id.uuidString):\($0.descriptor.grams)" }
            .sorted()
            .joined(separator: ",")
        count = pebbles.count
        maximumY = pebbles.map(\.position.y).max() ?? 0
        records = currentRecords
        if let target = pebbles.min(by: {
            $0.descriptor.id.uuidString < $1.descriptor.id.uuidString
        }), scene.size.width > 0, scene.size.height > 0 {
            targetX = min(max(target.position.x / scene.size.width, 0), 1)
            targetY = min(max(1 - target.position.y / scene.size.height, 0), 1)
        }

        if trackedRecords != currentRecords {
            trackedRecords = currentRecords
            lastSceneSequence = Int(
                truncatingIfNeeded: scene.tapPresentationSequence
            )
            bounceRise = 0
        }

        // Upward travel is captured on SpriteKit's own physics frames for both
        // Reduce Motion settings.
        // Polling only from this SwiftUI task can miss the start of a fast arc
        // under UI automation and substantially under-report its rise.
        let sceneSequence = Int(truncatingIfNeeded: scene.tapPresentationSequence)
        if sceneSequence > lastSceneSequence {
            bounceSequence += sceneSequence - lastSceneSequence
            bounceRise = 0
        }
        lastSceneSequence = sceneSequence
        bounceRise = max(bounceRise, scene.tapPresentationMaximumRise)
    }

    private func collectPebbles(from node: SKNode, into pebbles: inout [PebbleNode]) {
        for child in node.children {
            if let pebble = child as? PebbleNode,
               pebble.parent != nil,
               pebble.physicsBody != nil,
               !pebble.isRemovedForBake {
                pebbles.append(pebble)
            }
            collectPebbles(from: child, into: &pebbles)
        }
    }
}
#endif
