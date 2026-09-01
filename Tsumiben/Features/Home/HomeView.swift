import Accessibility
import SpriteKit
import StoreKit
import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    @Environment(\.requestReview) private var requestReview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ScaledMetric(relativeTo: .subheadline) private var homeMenuFontSize: CGFloat = 15
    @ScaledMetric(relativeTo: .subheadline) private var atmosphereTitleFontSize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption2) private var atmosphereSubtitleFontSize: CGFloat = 11
    @Query(sort: \Subject.sortOrder) private var subjects: [Subject]
    @Query private var storedSessions: [StudySession]
    @Query private var storedAchievementStones: [AchievementStone]
    @Query private var storedAggregates: [AggregatePebble]
    @Query private var storedStrata: [Stratum]
    @Query private var activityResetMarkers: [ActivityResetMarker]
    @Query private var preferences: [Prefs]

    @AppStorage("home.selected-subject") private var selectedSubjectID = ""
    @AppStorage("jar.tap-hint-seen") private var didSeeTapHint = false
    @AppStorage("jar.voiceover-tap-hint-seen") private var didSeeVoiceOverTapHint = false
    @AppStorage(UsagePurpose.storageKey) private var usagePurposeRawValue = UsagePurpose.study.rawValue
    @AppStorage(HomeAtmosphere.storageKey) private var homeAtmosphereRawValue = HomeAtmosphere.aurora.rawValue
    @State private var scene = JarScene()
    @State private var sceneInitialized = false
    @State private var knownLooseIDs = Set<UUID>()
    @State private var acceptedAggregateRootIDs = Set<UUID>()
    @State private var rootProjectionIsComplete = true
    @State private var resolvedAchievementStones: [AchievementStone] = []
    @State private var projectedAchievementCount = 0
    @State private var achievementCountIsLowerBound = false
    /// Refreshed only when aggregate/legacy rows change. Keeping the direct
    /// level-one index avoids rebuilding recursively flattened UUID sets during
    /// ordinary SwiftUI body evaluation.
    @State private var representedSessionIDs = Set<UUID>()
    @State private var selectedDuration: PomodoroDuration = .twentyFiveMinutes
    @State private var customMinutes = 40
    @State private var focusConfiguration: FocusConfiguration?
    @State private var showHomeMenu = false
    @State private var showAccumulationOverview = false
    @State private var overviewInitialClusterID: UUID?
    @State private var showManualEntry = false
    @State private var showAchievementEntry = false
    @State private var showCustomDuration = false
    @State private var showAccumulationPlan = false
    @State private var completedStratum: PendingStratumCelebration?
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
    @State private var breakConfiguration: BreakConfiguration?
    @State private var purchase = PurchaseManager.shared
    @State private var announcedPostDropOfferID: UUID?
    @State private var announcedPostDropShareOfferID: UUID?

    init() {
        _storedSessions = Query(HomeProjectionPolicy.looseSessionDescriptor())
        _storedAchievementStones = Query(HomeProjectionPolicy.achievementCandidateDescriptor())
        _storedAggregates = Query(HomeProjectionPolicy.aggregateRootDescriptor())
        _storedStrata = Query(HomeProjectionPolicy.legacyCompatibilityDescriptor())
    }

    private var activeSubjects: [Subject] { subjects.filter { !$0.isArchived } }
    private var prefs: Prefs? {
        currentPreferences.first
    }
    private var currentPreferences: [Prefs] {
        preferences.filter {
            ActivityResetPolicy.isCurrent($0.activityEpochID, markers: resetSnapshots)
        }
    }
    private var rareRewardMode: RareRewardMode {
        RareRewardMode.resolved(preferences: currentPreferences)
    }
    private var manualCounterState: ManualCounterState {
        ManualCounterState(
            dayKey: prefs?.manualDayKey ?? "",
            usedToday: prefs?.manualUsedToday ?? 0
        )
    }
    private var usagePurpose: UsagePurpose {
        UsagePurpose(
            rawValue: prefs?.usagePurposeRawValue ?? usagePurposeRawValue
        ) ?? .study
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
    private var sessions: [StudySession] {
        storedSessions.filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetSnapshots)
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
    private var aggregates: [AggregatePebble] {
        storedAggregates.filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetSnapshots)
        }
    }
    private var strata: [Stratum] {
        storedStrata.filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetSnapshots)
        }
    }
    private var queriedLooseSessions: [StudySession] {
        Dictionary(grouping: sessions, by: \.id).values.compactMap { duplicates -> StudySession? in
            guard let id = duplicates.first?.id,
                  !representedSessionIDs.contains(id),
                  !duplicates.contains(where: \.isBaked)
            else { return nil }
            return duplicates.max { lhs, rhs in lhs.grams < rhs.grams }
        }
        .sorted { $0.endAt > $1.endAt }
    }
    private var looseSessions: [StudySession] {
        let newestRootEnd = acceptedAggregateRoots.map(\.periodEnd).max()
        let accepted = queriedLooseSessions.filter { session in
            guard let newestRootEnd else { return true }
            return session.endAt > newestRootEnd
        }
        return Array(accepted.prefix(HomeProjectionPolicy.looseSessionLimit))
    }
    private var projectionNeedsMaintenance: Bool {
        !rootProjectionIsComplete
            || acceptedAggregateRootIDs.count
                != AggregatePebblePolicy.activeRoots(from: aggregates).count
            || queriedLooseSessions.count != looseSessions.count
            || (storedSessions.count == HomeProjectionPolicy.looseSessionQueryLimit
                && sessions.count < storedSessions.count)
    }
    private var acceptedAggregateRoots: [AggregatePebble] {
        AggregatePebblePolicy.activeRoots(from: aggregates).filter {
            acceptedAggregateRootIDs.contains($0.id)
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
    private var visibleGoldPebbleCount: Int {
        let loose = RareRewardCounts.total(looseSessions.map(\.rareRewardCounts))
        return HomeProjectionPolicy.saturatingNonnegativeSum([
            HomeProjectionPolicy.saturatingNonnegativeSum(
                activeAggregateRoots.map(\.goldPebbleCount)
            ),
            loose.goldCount
        ])
    }
    private var visiblePrismPebbleCount: Int {
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
            && strata.isEmpty
    }
    private var sessionChangeTokens: [String] {
        sessions.map { "\($0.id.uuidString)-\($0.isBaked)" }
    }
    private var stratumChangeTokens: [String] {
        strata.map { stratum in
            [
                stratum.id.uuidString,
                stratum.sessionIDsJSON,
                String(stratum.pebbleCount),
                String(stratum.heightPt),
                stratum.colorMixJSON,
                stratum.monthLabel
            ].joined(separator: "-")
        }
    }
    private var aggregateChangeTokens: [String] {
        aggregates.map { aggregate in
            [
                aggregate.id.uuidString,
                String(aggregate.level),
                String(aggregate.pebbleCount),
                String(aggregate.grams),
                aggregate.colorMixJSON,
                aggregate.subjectMixJSON,
                aggregate.sessionIDsJSON,
                aggregate.childAggregateIDsJSON,
                aggregate.parentAggregateID?.uuidString ?? "root"
            ].joined(separator: "-")
        }
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
            "\($0.soundOn)-\($0.hapticsOn)-\($0.rareRewardModeRawValue)-\($0.rareRewardModeUpdatedAt?.timeIntervalSince1970 ?? -1)"
        }
    }
    private var celebrationPresentationBlockers: [Bool] {
        [
            showHomeMenu,
            showAccumulationOverview,
            showManualEntry,
            showAchievementEntry,
            showCustomDuration,
            breakOffer != nil,
            breakOfferTask != nil,
            hasPendingRewardReceipt,
            focusConfiguration != nil,
            breakConfiguration != nil,
            router.paywallPresented,
            router.sharePresented,
            router.recoveredFocus != nil,
            router.recoveredBreak != nil,
            isDeferringCelebrationsForShare
        ]
    }
    private var canPresentStratumCelebration: Bool {
        !celebrationPresentationBlockers.contains(true)
    }
    private var hasPendingRewardReceipt: Bool {
        !PendingRewardReceiptStore.load().isEmpty
    }
    private var selectedSubject: Subject? {
        activeSubjects.first { $0.id.uuidString == selectedSubjectID } ?? activeSubjects.first
    }

    var body: some View {
        observedContent
    }

    private var mainContent: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    jarCard(height: homeJarHeight(availableHeight: proxy.size.height))
                    if let state = largeTextFusionProgressState {
                        Spacer(minLength: 12)
                        largeTextFusionProgressCard(state)
                    }
                    Spacer(minLength: 14)
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
        .fullScreenCover(item: $focusConfiguration) { configuration in
            FocusView(subject: configuration.subject, duration: configuration.duration)
        }
        .fullScreenCover(item: $breakConfiguration, onDismiss: {
            recoverPendingRewardReceipt()
        }) { configuration in
            BreakTimerView(minutes: configuration.minutes)
        }
        .sheet(isPresented: $showHomeMenu) {
            homeMenuSheet
                .presentationDetents(auxiliarySheetDetents)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAccumulationOverview) {
            AccumulationOverviewLoader(
                resetMarkers: resetSnapshots,
                lifetimeGrams: totalGrams,
                lifetimePebbleCount: totalPebbles,
                lifetimeIsLowerBound: projectionNeedsMaintenance,
                initialClusterID: overviewInitialClusterID
            )
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
                usagePurpose: usagePurpose,
                onAdd: addAchievementStone
            )
                .presentationDetents(auxiliarySheetDetents)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCustomDuration) {
            CustomDurationView(minutes: $customMinutes, onConfirm: confirmCustomDuration)
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

    private var auxiliarySheetDetents: Set<PresentationDetent> {
        if dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact {
            return [.large]
        }
        return [.medium, .large]
    }

    private var customDurationSheetDetents: Set<PresentationDetent> {
        if dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact {
            return [.large]
        }
        return [.height(390), .large]
    }

    private var observedContent: some View {
        presentedContent
        .onAppear {
            restorePreferredDuration()
            configureScene()
            refreshAcceptedAggregateRoots()
            refreshAchievementProjection()
            refreshAchievementCount()
            syncScene()
            recoverPendingRewardReceipt()
            recoverPendingStratumCelebrations()
            recoverInterruptionNotice()
            scheduleTiltHintIfNeeded()
            schedulePendingReviewRequestIfPossible()
        }
        .onDisappear {
            widgetRefreshTask?.cancel()
            celebrationRecoveryTask?.cancel()
            capacityCelebrationTask?.cancel()
            breakOfferTask?.cancel()
            reviewRequestTask?.cancel()
            shareChipTask?.cancel()
            pendingCapacityCelebrations.removeAll()
            tiltHintTask?.cancel()
            tiltHintTask = nil
            showsTiltHint = false
            capacityRemaining = nil
            clearSceneCallbacks()
        }
        .onChange(of: sessionChangeTokens) { _, _ in
            syncScene()
            scheduleTiltHintIfNeeded()
        }
        .onChange(of: achievementChangeTokens) { _, _ in
            refreshAchievementProjection()
            refreshAchievementCount()
            syncScene()
        }
        .onChange(of: aggregateChangeTokens) { _, _ in
            refreshAcceptedAggregateRoots()
            syncScene()
            scheduleTiltHintIfNeeded()
        }
        .onChange(of: stratumChangeTokens) { _, _ in
            syncScene()
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
        }
        .onChange(of: reduceMotion) { _, enabled in
            cancelTiltHintPresentation()
            if !enabled || voiceOverEnabled {
                scheduleTiltHintIfNeeded()
            }
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
                representedPebbleCount: totalPebbles,
                goldPebbleCount: visibleGoldPebbleCount,
                prismPebbleCount: visiblePrismPebbleCount,
                accentHex: selectedSubject?.colorHex ?? Constants.Color.amberLamp,
                lifetimeCoreColorHex: lifetimeCoreColorHex,
                projectionIsLowerBound: projectionNeedsMaintenance,
                fusionProgressDescription: fusionAccessibilityDescription
            )
                .padding(.horizontal, 4)

            jarMetricHUD

            if isJarEmpty {
                emptyJarMessage
                .multilineTextAlignment(.center)
                .padding(20)
                .frame(maxWidth: 320)
            }

            if let remaining = capacityRemaining, remaining <= 15 {
                VStack {
                    HStack(spacing: 7) {
                        Image(systemName: "circle.grid.2x2.fill")
                        Text(remaining == 0 ? "まとまり粒をつくっています" : "あと\(remaining)%で、下の粒がひとつにまとまる")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TsumibenTheme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay { Capsule().stroke(TsumibenTheme.amber.opacity(0.28), lineWidth: 1) }
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
                            .foregroundStyle(TsumibenTheme.amber)
                            .accessibilityHidden(true)
                        Text("まとまり粒は未保存です")
                            .font(.caption.weight(.bold))
                        Spacer(minLength: 4)
                        Button("保存を再試行") {
                            retryFailedAggregatePersistence()
                        }
                        .buttonStyle(TsumibenCompactButtonStyle())
                        .accessibilityIdentifier("jar.aggregate.persistence.retry")
                    }
                    .foregroundStyle(TsumibenTheme.text)
                    .padding(.leading, 13)
                    .padding(.trailing, 7)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule().stroke(TsumibenTheme.amber.opacity(0.38), lineWidth: 1)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 188)
                    Spacer()
                }
                .transition(.opacity)
            }

            if showsTiltHint, !isJarEmpty {
                VStack {
                    Spacer()
                    Label(
                        jarInteractionHintText,
                        systemImage: jarInteractionHintSymbol
                    )
                        .font(.caption.weight(.bold))
                        .foregroundStyle(TsumibenTheme.text)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay {
                            Capsule().stroke(TsumibenTheme.glassEdge.opacity(0.2), lineWidth: 1)
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
                    // The named-store fault scenarios contain at most ten
                    // loose rows, well below the bounded Home query limit.
                    // Exposing both raw rows and unique IDs catches a duplicate
                    // SwiftData insert that the canonical jar projection would
                    // otherwise deliberately hide.
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

    private var jarMetricHUD: some View {
        VStack(spacing: 3) {
            Text(usagePurpose == .work ? "積み上げた仕事の集中" : "積み上げた集中")
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
        if totalGrams < 1_000 { return totalGrams.formatted() }
        return (Double(totalGrams) / 1_000).formatted(.number.precision(.fractionLength(1 ... 2)))
    }

    private var homeMassUnit: String {
        let unit = totalGrams < 1_000 ? "g" : "kg"
        return projectionNeedsMaintenance ? "\(unit)以上" : unit
    }

    private var jarMetricSummary: String {
        let milestones = uniqueAchievementCount > 0 ? " ・ 記念石 \(achievementCountLabel)" : ""
        let lowerBound = projectionNeedsMaintenance ? "+" : ""
        return "\(totalPebbles.formatted())\(lowerBound)粒\(milestones)"
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
        .background(TsumibenTheme.raised.opacity(0.62), in: Capsule())
        .overlay {
            Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.7)
        }
        .accessibilityHidden(true)
    }

    private var fusionAccessibilityDescription: String? {
        guard totalPebbles > 0 || projectionNeedsMaintenance else { return nil }
        guard let state = JarLifetimeCorePresentation.state(
            totalPebbleCount: totalPebbles,
            totalGrams: totalGrams,
            projectionIsLowerBound: projectionNeedsMaintenance
        ) else { return nil }
        var components = [state.progressLabel, state.nextFusionLabel]
            .compactMap { $0 }
        if let physicalState = JarLifetimeCorePresentation.state(
            totalPebbleCount: totalPebbles,
            projectionIsLowerBound: projectionNeedsMaintenance
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
              JarLifetimeCorePresentation.shouldShowCore(
                totalPebbleCount: totalPebbles,
                totalGrams: totalGrams
              )
        else { return nil }
        return JarLifetimeCorePresentation.state(
            totalPebbleCount: totalPebbles,
            totalGrams: totalGrams,
            projectionIsLowerBound: projectionNeedsMaintenance
        )
    }

    private func largeTextFusionProgressCard(
        _ state: JarLifetimeCoreState
    ) -> some View {
        TsumibenCard {
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
                        .foregroundStyle(TsumibenTheme.text)
                    Text(state.progressLabel)
                        .font(.system(.title3, design: .rounded, weight: .black))
                        .monospacedDigit()
                        .foregroundStyle(TsumibenTheme.text)
                    if let nextFusionLabel = state.nextFusionLabel {
                        Text(nextFusionLabel)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(TsumibenTheme.muted)
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
            .foregroundStyle(TsumibenTheme.text.opacity(0.86))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(TsumibenTheme.raised.opacity(0.72), in: Capsule())
            .overlay {
                Capsule().stroke(TsumibenTheme.glassEdge.opacity(0.15), lineWidth: 1)
            }
    }

    private var achievementCountLabel: String {
        "\(uniqueAchievementCount)\(achievementCountIsLowerBound ? "+" : "")"
    }

    @ViewBuilder
    private var emptyJarMessage: some View {
        if dynamicTypeSize.isAccessibilitySize {
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
                    .foregroundStyle(TsumibenTheme.amber)
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
                    .font(TsumibenTheme.brand(21))
                Text(
                    selectedSubject == nil
                        ? "メニューでテーマを決めると、ここから始まる。"
                        : Constants.UIStrings.jarEmptyBody
                )
                    .font(.caption)
                    .foregroundStyle(TsumibenTheme.muted)
            }
        }
    }

    private func homeJarHeight(availableHeight: CGFloat) -> CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return 520
        }
        // iPhone 15 is the reference canvas. Keep the launch control visible on
        // the first screen while letting the bottle breathe on Pro-sized phones.
        return min(520, max(Constants.Jar.height, availableHeight - 126))
    }

    private var homeContentMaxWidth: CGFloat {
#if targetEnvironment(macCatalyst)
        return 720
#else
        return .infinity
#endif
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
                            ? "勉強にも、仕事にも"
                            : "\(selectedSubject?.safeDisplayName ?? "選択中のテーマ") ・ 完走で +\(selectedDuration.grams)g"
                    )
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
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
            TsumibenHeroButtonStyle(
                tintHex: selectedSubject?.colorHex ?? Constants.Color.amberLamp
            )
        )
        .accessibilityLabel(
            selectedSubject == nil
                ? "テーマを選んではじめる"
                : "\(selectedSubject?.safeDisplayName ?? "選択中のテーマ")を\(focusDurationLabel)集中する、完走で\(selectedDuration.grams)グラム"
        )
        .accessibilityHint(focusActionAccessibilityHint)
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
        return selectedSubject == nil ? "設定画面を開きます" : "タイマーを開始します"
    }

    private var focusDurationLabel: String {
        if selectedDuration == .twentyFiveMinutes { return "25分" }
        if selectedDuration == .sixtyMinutes { return "60分" }
#if DEBUG
        if selectedDuration == .demo { return "12秒" }
#endif
        return "\(customMinutes)分"
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
                .foregroundStyle(TsumibenTheme.amber)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("メニュー")
        .accessibilityHint("記録、設定、集中時間、背景、手動追加などを開きます")
    }

    private var homeMenuSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    menuFocusSettings
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
                    TsumibenSheetCloseButton(
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
        TsumibenCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        SectionEyebrow(text: "SPACE")
                        Text("集中する空間")
                            .font(TsumibenTheme.brand(21))
                    }
                    Spacer()
                }

                Text(
                    dynamicTypeSize.isAccessibilitySize
                        ? "教科・仕事の色はそのままに、\n背景の空気だけを変えます。"
                        : "教科・仕事の色はそのままに、背景の空気だけを変えます。"
                )
                    .font(.caption)
                    .foregroundStyle(TsumibenTheme.muted)
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
            if prefs?.hapticsOn ?? true {
                Haptics.shared.playSecondaryCollision()
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                atmospherePreview(atmosphere)

                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.74)],
                    startPoint: .top,
                    endPoint: .bottom
                )

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
                            .foregroundStyle(TsumibenTheme.amber)
                            .accessibilityHidden(true)
                    }
                }
                .padding(10)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 92 : 102, alignment: .bottomLeading)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(
                        isSelected ? TsumibenTheme.amber.opacity(0.72) : TsumibenTheme.glassEdge.opacity(0.12),
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
        .buttonStyle(TsumibenRowButtonStyle(cornerRadius: 17))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(atmosphere.title)、\(atmosphere.subtitle)")
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

    private var menuFocusSettings: some View {
        TsumibenCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        SectionEyebrow(text: "FOCUS")
                        Text("集中設定")
                            .font(TsumibenTheme.brand(21))
                    }
                    Spacer()
                    Text(focusDurationLabel)
                        .font(.system(.headline, design: .rounded, weight: .heavy))
                        .foregroundStyle(TsumibenTheme.amber)
                }

                if activeSubjects.isEmpty {
                    Text("テーマを追加するとタイマーを始められます。")
                        .font(.subheadline)
                        .foregroundStyle(TsumibenTheme.muted)
                    Button {
                        showHomeMenu = false
                        router.selectedTab = .settings
                    } label: {
                        Label("テーマを追加", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(TsumibenPrimaryButtonStyle())
                } else {
                    Menu {
                        ForEach(activeSubjects) { subject in
                            Button {
                                selectedSubjectID = subject.id.uuidString
                            } label: {
                                if selectedSubject?.id == subject.id {
                                    Label(subject.safeDisplayName, systemImage: "checkmark")
                                } else {
                                    Text(subject.safeDisplayName)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(hex: selectedSubject?.colorHex ?? Constants.Color.amberLamp))
                                .frame(width: 12, height: 12)
                            Text(selectedSubject?.safeDisplayName ?? "テーマ")
                                .font(.system(.body, design: .rounded, weight: .bold))
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(TsumibenTheme.muted)
                        }
                        .foregroundStyle(TsumibenTheme.text)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 48)
                        .background(TsumibenTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .accessibilityLabel("テーマ、\(selectedSubject?.safeDisplayName ?? "未選択")")

                    durationPicker
                }
            }
        }
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
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var menuHistoryActions: some View {
        VStack(spacing: 2) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 12) {
                        menuMetric(value: formattedMass(totalGrams), label: "累計")
                        menuMetric(value: "\(totalPebbles)粒", label: "集中")
                        menuMetric(value: "\(achievementCountLabel)個", label: "成果")
                    }
                } else {
                    HStack(spacing: 0) {
                        menuMetric(value: formattedMass(totalGrams), label: "累計")
                        Divider().frame(height: 34)
                        menuMetric(value: "\(totalPebbles)粒", label: "集中")
                        Divider().frame(height: 34)
                        menuMetric(value: "\(achievementCountLabel)個", label: "成果")
                    }
                }
            }
            .padding(.vertical, 12)
            .background(TsumibenTheme.card)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("累計\(formattedMass(totalGrams))、集中\(totalPebbles)粒、成果\(achievementCountLabel)個")

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
                detail: "GIF・質量・#つみべん をSNSへ",
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
                .foregroundStyle(TsumibenTheme.muted)
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
                    .foregroundStyle(TsumibenTheme.amber)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.body, design: .rounded, weight: .bold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(TsumibenTheme.muted)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TsumibenTheme.muted)
            }
            .foregroundStyle(TsumibenTheme.text)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(TsumibenTheme.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(TsumibenRowButtonStyle(cornerRadius: 16))
    }

    private func postDropCard(_ offer: BreakOffer) -> some View {
        TsumibenCard {
            VStack(alignment: .leading, spacing: 12) {
                postDropHeading(offer)
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
                if showShareChip {
                    postDropShareButton
                        .frame(maxWidth: .infinity)
                }
                dismissBreakOfferButton(offer, showsText: true)
            }
        } else {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                dismissBreakOfferButton(offer, showsText: true)
                if showShareChip { postDropShareButton }
                startBreakButton(offer)
            }
        }
    }

    private var deferredCompletionCard: some View {
        TsumibenCard {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(TsumibenTheme.amber)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("完走は保護されています")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                    Text("記録の保存を安全に再試行できます")
                        .font(.caption)
                        .foregroundStyle(TsumibenTheme.muted)
                }
                Spacer(minLength: 6)
                Button("再試行") {
                    guard let request = router.deferredFocusRecovery else { return }
                    router.deferredFocusRecovery = nil
                    router.recoveredFocus = request
                }
                .buttonStyle(TsumibenCompactButtonStyle())
                .accessibilityIdentifier("home.pending-completion.retry")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func postDropHeading(_ offer: BreakOffer) -> some View {
        HStack(spacing: 11) {
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
                    "\(offer.subjectName) +\(offer.grams)g（\(EffortProgressPresentation.formattedStandardUnits(grams: offer.grams))） ・ \(offer.weeklyTitle)\(offer.rareRewardCounts.multiDrawSummary.map { " ・ \($0)" } ?? "")"
                )
                    .font(.caption)
                    .foregroundStyle(TsumibenTheme.muted)
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
            "テーマは\(offer.subjectName)です。今回は\(offer.grams)グラム、標準換算は\(EffortProgressPresentation.formattedStandardUnits(grams: offer.grams))です。\(offer.weeklySpokenTitle)。\(offer.rareRewardCounts.multiDrawSummary.map { "\($0)。" } ?? "")\(offer.minutes)分休憩を利用できます"
        )
        .accessibilityHint(
            showShareChip
                ? "結晶の進みを確認し、休憩、共有、または閉じるを選べます"
                : "結晶の進みを確認し、休憩または閉じるを選べます"
        )
    }

    @ViewBuilder
    private func postDropFusionProgress(_ offer: BreakOffer) -> some View {
        if let effortProgress = offer.effortProgress {
            postDropEffortProgress(effortProgress, offer: offer)
        } else {
            postDropLegacyFusionProgress(offer)
        }
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
                    .foregroundStyle(TsumibenTheme.amber)
            }

            if let progressFraction = display.progressFraction {
                ProgressView(value: progressFraction)
                    .tint(Color(hex: offer.colorHex))
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(TsumibenTheme.amber)
                    .accessibilityHidden(true)
            }

            Text(display.progressLabel)
                .font(.system(.headline, design: .rounded, weight: .black))
                .monospacedDigit()
                .foregroundStyle(TsumibenTheme.text)
                .fixedSize(horizontal: false, vertical: true)

            Text(display.nextStepLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(TsumibenTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if let context = display.longTermContextLabel {
                Text(context)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(TsumibenTheme.amber.opacity(0.9))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("25分 = 1.0標準単位 ・ 粒の10→1は瓶の整理")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .tracking(0.15)
                .foregroundStyle(TsumibenTheme.text.opacity(0.82))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(TsumibenTheme.card.opacity(0.72), in: Capsule())
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [
                    Color(hex: offer.colorHex).opacity(0.12),
                    TsumibenTheme.raised.opacity(0.78)
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
                    TsumibenTheme.raised.opacity(0.78)
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
                .foregroundStyle(TsumibenTheme.amber)

            Text(display.progressLabel)
                .font(.system(.headline, design: .rounded, weight: .black))
                .monospacedDigit()
                .foregroundStyle(TsumibenTheme.text)
                .fixedSize(horizontal: false, vertical: true)

            if isSyncing {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(TsumibenTheme.amber)
                    Text(display.nextStepLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(TsumibenTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
            } else {
                Text(display.nextStepLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(TsumibenTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let context = display.longTermContextLabel {
                Text(context)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(TsumibenTheme.amber.opacity(0.9))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("10 → 1 ・記録と質量は保持")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .tracking(0.25)
                .foregroundStyle(TsumibenTheme.text.opacity(0.82))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(TsumibenTheme.card.opacity(0.72), in: Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func startBreakButton(_ offer: BreakOffer) -> some View {
        Button("\(offer.minutes)分休憩") {
            breakOfferTask?.cancel()
            shareChipTask?.cancel()
            shareChipTask = nil
            retireRewardReceipt(offer)
            breakOffer = nil
            showShareChip = false
            breakConfiguration = BreakConfiguration(minutes: offer.minutes)
        }
        .buttonStyle(TsumibenCompactButtonStyle())
        .accessibilityLabel("\(offer.minutes)分休憩する")
    }

    private var postDropShareButton: some View {
        Button {
            breakOfferTask?.cancel()
            shareChipTask?.cancel()
            shareChipTask = nil
            // Keep a queued fusion beat behind the share composer. Without
            // this blocker, the 180ms hand-off can let a celebration sheet win
            // the presentation race before the GIF studio opens.
            isDeferringCelebrationsForShare = true
            if let offer = breakOffer { retireRewardReceipt(offer) }
            breakOffer = nil
            showShareChip = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                router.presentShare()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "play.rectangle.fill")
                Text("GIF")
                    .font(.caption2.weight(.black))
            }
            .frame(minWidth: 58, minHeight: 44)
        }
        .buttonStyle(
            TsumibenCompactButtonStyle(
                tint: TsumibenTheme.text,
                foreground: TsumibenTheme.background,
                isProminent: false
            )
        )
        .accessibilityLabel("今の瓶をGIFでシェアする")
    }

    private func dismissBreakOfferButton(_ offer: BreakOffer, showsText: Bool) -> some View {
        Button {
            breakOfferTask?.cancel()
            shareChipTask?.cancel()
            shareChipTask = nil
            retireRewardReceipt(offer)
            breakOffer = nil
            showShareChip = false
            recoverPendingRewardReceipt()
        } label: {
            HStack(spacing: showsText ? 6 : 0) {
                Image(systemName: "xmark")
                    .accessibilityHidden(true)
                if showsText {
                    Text("閉じる")
                }
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(TsumibenTheme.text.opacity(0.92))
            .padding(.horizontal, showsText ? 12 : 0)
            .frame(
                minWidth: showsText ? 72 : 44,
                maxWidth: dynamicTypeSize.isAccessibilitySize && showsText ? .infinity : nil,
                minHeight: 44
            )
            .background(TsumibenTheme.raised.opacity(0.78), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(TsumibenTheme.text.opacity(0.28), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(TsumibenBareButtonStyle())
        .accessibilityLabel("休憩の提案を閉じる")
        .accessibilityIdentifier("reward.dismiss")
    }

    private var durationPicker: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    durationChips
                }
            } else {
                HStack(spacing: 8) {
                    durationChips
                }
            }
        }
    }

    @ViewBuilder
    private var durationChips: some View {
            DurationChip(title: "25分", subtitle: "+250g", selected: selectedDuration == .twentyFiveMinutes) {
                selectDuration(.twentyFiveMinutes)
            }
            DurationChip(title: "60分", subtitle: "+600g", selected: selectedDuration == .sixtyMinutes) {
                selectDuration(.sixtyMinutes)
            }
            DurationChip(
                title: customDurationTitle,
                subtitle: purchase.isPro ? "+\(customMinutes * Constants.Mass.gramsPerMinute)g" : "Pro",
                selected: selectedDuration.requiresPro
            ) {
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
#if DEBUG
            if LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess {
                DurationChip(title: "12秒", subtitle: "DEMO", selected: selectedDuration == .demo) {
                    selectDuration(.demo)
                }
            }
#endif
    }

    private var customDurationTitle: String {
        selectedDuration.requiresPro ? "\(customMinutes)分" : "自由"
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
        syncBaseLayers()
        let current = (
            looseSessions.map(PebbleDescriptor.init(session:))
                + visibleAchievementStones.map(PebbleDescriptor.init(achievement:))
        ).sorted { $0.createdAt < $1.createdAt }
        let currentIDs = Set(current.map(\.id))

        if !sceneInitialized {
            let pendingCompletion = looseSessions.first(where: hasLocalCompletionMarker)
            let restored = current.filter { $0.id != pendingCompletion?.id }
            scene.restore(pebbles: restored)
            knownLooseIDs = currentIDs
            sceneInitialized = true
            if let pendingCompletion {
                scene.drop([PebbleDescriptor(session: pendingCompletion)])
                scheduleShareChipIfNeeded(for: [pendingCompletion])
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
                scene.restore(pebbles: current)
                knownLooseIDs = currentIDs
                scheduleWidgetSnapshot()
                return
            }
        }
        let newStudyDescriptors = newDescriptors.filter { !$0.isAchievement }
        let newAchievementDescriptors = newDescriptors.filter(\.isAchievement)
        if !newStudyDescriptors.isEmpty {
            scene.drop(newStudyDescriptors)
            scheduleShareChipIfNeeded(for: newSessions)
        }
        if !newAchievementDescriptors.isEmpty {
            scene.performCompletionDrop(newAchievementDescriptors)
        }
        knownLooseIDs = currentIDs
        scheduleWidgetSnapshot()
    }

    private func syncBaseLayers() {
        representedSessionIDs = AggregatePebblePolicy.directSessionIDs(from: acceptedAggregateRoots)
            .union(strata.flatMap(\.sessionIDs))
        scene.showsMonthLabels = purchase.isPro
        scene.configureAggregates(
            acceptedAggregateRoots,
            legacyStrata: strata.map(JarStratumVisual.init(stratum:))
        )
        scheduleWidgetSnapshot()
    }

    private func refreshAcceptedAggregateRoots() {
        do {
            let persistedRootCount = try modelContext.fetchCount(
                FetchDescriptor<AggregatePebble>(
                    predicate: #Predicate { aggregate in
                        aggregate.parentAggregateID == nil
                    }
                )
            )
            rootProjectionIsComplete = persistedRootCount
                <= HomeProjectionPolicy.aggregateRootLimit
                && (storedAggregates.count < HomeProjectionPolicy.aggregateRootLimit
                    || aggregates.count == storedAggregates.count)
            acceptedAggregateRootIDs = try HomeProjectionPolicy.acceptedRootSummaryIDs(
                roots: aggregates,
                context: modelContext,
                resetMarkers: resetSnapshots
            )
        } catch {
            // A parent that cannot be verified during a transient store read is
            // omitted for this frame. The query change/relaunch retries without
            // risking duplicated mass or a phantom jar body.
            acceptedAggregateRootIDs = []
            rootProjectionIsComplete = false
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
        scene.soundEnabled = prefs?.soundOn ?? true
        scene.hapticsEnabled = prefs?.hapticsOn ?? true
        scene.rareRewardMode = rareRewardMode
    }

    private func restorePreferredDuration() {
        guard let preferred = prefs?.preferredFocusMinutes else { return }
        let restored = PomodoroDuration(minutes: preferred)
        if restored.requiresPro {
            customMinutes = min(
                max(preferred, Constants.Timer.customMinimumMinutes),
                Constants.Timer.customMaximumMinutes
            )
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

    private func confirmCustomDuration() {
        selectedDuration = PomodoroDuration(minutes: customMinutes)
        prefs?.preferredFocusMinutes = customMinutes
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            router.showToast("集中時間を保存できませんでした", symbol: "exclamationmark.triangle")
        }
        showCustomDuration = false
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
        guard let minutes = duration.minutes else { return }
        prefs?.preferredFocusMinutes = minutes
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            router.showToast("集中時間を保存できませんでした", symbol: "exclamationmark.triangle")
        }
    }

    private func startFocus(duration: PomodoroDuration) {
        guard let subject = selectedSubject else {
            router.selectedTab = .settings
            return
        }
        selectedDuration = duration
        prefs?.preferredFocusMinutes = duration.minutes ?? Constants.Timer.twentyFiveMinutes
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            router.showToast("前回使った時間として保存できませんでした", symbol: "exclamationmark.triangle")
        }
        focusConfiguration = FocusConfiguration(subject: subject, duration: duration)
    }

    private func enqueueStratumCelebration(_ request: JarBakeRequest) {
        enqueueStratumCelebration(PendingStratumCelebration(request: request))
    }

    private func enqueueStratumCelebration(_ request: PendingStratumCelebration) {
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
        guard completedStratum == nil,
              canPresentStratumCelebration,
              !stratumCelebrationQueue.isEmpty
        else { return }
        completedStratum = stratumCelebrationQueue.removeFirst()
        presentedStratumID = completedStratum?.id
    }

    private func finishPresentedStratumCelebration() {
        if let presentedStratumID {
            PendingStratumCelebrationStore.remove(id: presentedStratumID)
            self.presentedStratumID = nil
        }
        presentNextStratumCelebrationIfNeeded()
    }

    private func recoverPendingStratumCelebrations() {
        capacityRemaining = nil
        let persistedIDs = Set(aggregates.map(\.id)).union(strata.map(\.id))
        let pending = PendingStratumCelebrationStore.load()
        let now = Date.now
        let recoverable = pending.filter {
            persistedIDs.contains($0.id) && !scene.isBakeInProgress
        }
        let latestRecoverable = PendingStratumCelebrationSelection.latest(in: recoverable)
        let recoverableIDs = Set(recoverable.map(\.id))
        let waiting = pending.filter {
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
        guard let prefs else {
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
                dayKey: prefs.manualDayKey,
                usedToday: prefs.manualUsedToday
            ),
            at: now
        )
        guard decision.isAllowed else {
            router.showToast(Constants.UIStrings.manualCapToast, symbol: "info.circle")
            return false
        }

        // Apply the quota and session in the same SwiftData transaction. Merely
        // selecting a duration in the confirmation sheet never mutates Prefs.
        prefs.activityEpochID = currentActivityEpochID
        prefs.manualDayKey = decision.state.dayKey
        prefs.manualUsedToday = decision.state.usedToday
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
            let restored = (
                looseSessions.map(PebbleDescriptor.init(session:))
                    + visibleAchievementStones.map(PebbleDescriptor.init(achievement:))
            ).sorted { $0.createdAt < $1.createdAt }
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
            PendingStratumCelebrationStore.insert(PendingStratumCelebration(request: request))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                capacityRemaining = 0
            }
        case let .bakeCompleted(request):
            capacityRemaining = nil
            guard failedBakeIDs.remove(request.id) == nil else { return }
            let celebration = PendingStratumCelebration(request: request)
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
        var message: String
        switch descriptor.kind {
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
        if let batch = descriptor.rewardBatchSummary {
            message += " ・ \(batch)"
        }
        let usesRareSymbol = descriptor.kind != .normal
            && rareRewardMode.usesEnhancedPresentation
        router.showToast(message, symbol: usesRareSymbol ? "sparkles" : "scalemass")

        guard descriptor.source != .manual,
              hasLocalCompletionMarker(descriptor.id)
        else { return }
        let historyMetrics = try? HomeProjectionPolicy.completionMetrics(
            context: modelContext,
            resetMarkers: resetSnapshots,
            roots: acceptedAggregateRoots,
            looseSessions: looseSessions,
            at: descriptor.createdAt
        )
        var measuredCompletionDates = historyMetrics?.weeklyMeasuredDates ?? []
        if historyMetrics?.weeklyMeasuredSessionIDs.contains(descriptor.id) != true {
            // SwiftData query delivery can trail SpriteKit's landing callback
            // by one render pass. Include the just-landed, locally committed
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
        // Freeze the projection at the landing boundary. A delayed live read
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
            projectionIsLowerBound: projectionNeedsMaintenance
        )
        // Persist before consuming the one-shot landing marker. If the process
        // dies at any later instruction, Home can still recover this exact
        // receipt once without awarding or saving the session again.
        if PendingRewardReceiptStore.insert(receipt) {
            UserDefaults.standard.removeObject(forKey: FocusPersistence.localCompletionIDKey)
        }
        scheduleRewardReceipt(receipt, delay: .milliseconds(1_650))
        scheduleReviewRequestIfEarned()
    }

    private func recoverPendingRewardReceipt() {
        guard breakOffer == nil,
              breakOfferTask == nil,
              focusConfiguration == nil,
              breakConfiguration == nil,
              !router.sharePresented,
              let receipt = PendingRewardReceiptStore.load().first
        else { return }
        // A recovered receipt is already detached from the physical impact, so
        // a short settling delay is enough to avoid covering the first frame.
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
            // Fresh receipts leave room for the thud and mass toast. Recovered
            // receipts use the shorter delay above and contain no replayed FX.
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
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
        let countKey = "review.local-completion-count"
        let firstCompletionKey = "review.first-local-completion-date"
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
        let versionKey = "review.requested-version"
        guard defaults.string(forKey: versionKey) != version else { return }
        // Defer the request until the rest offer or any aggregation celebration
        // has been dismissed. `celebrationPresentationBlockers` will retry at
        // the next genuinely quiet home state.
        defaults.set(version, forKey: "review.pending-version")
    }

    private func schedulePendingReviewRequestIfPossible() {
        // Also quarantine a pending value left by an earlier Simulator launch;
        // guarding only the earning path would still allow that modal to appear.
        guard !LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess else { return }
        let defaults = UserDefaults.standard
        guard let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
              defaults.string(forKey: "review.pending-version") == currentVersion,
              defaults.string(forKey: "review.requested-version") != currentVersion
        else { return }

        reviewRequestTask?.cancel()
        reviewRequestTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled,
                  !celebrationPresentationBlockers.contains(true),
                  completedStratum == nil,
                  stratumCelebrationQueue.isEmpty
            else { return }
            defaults.set(currentVersion, forKey: "review.requested-version")
            defaults.removeObject(forKey: "review.pending-version")
            requestReview()
        }
    }

    private func scheduleShareChipIfNeeded(for newSessions: [StudySession]) {
        guard newSessions.contains(where: { $0.source == .timer }) else { return }
        let dayKey = FairnessPolicy.deviceDayKey(for: .now)
        let promptKey = "share.prompt.\(dayKey)"
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
        let uniqueSessions = Dictionary(grouping: sessions, by: \.id).values.compactMap {
            $0.max { lhs, rhs in lhs.grams < rhs.grams }
        }
        let looseMeasured = uniqueSessions.filter {
            $0.source == .timer
                && !representedSessionIDs.contains($0.id)
                && !$0.isBaked
        }
        let measuredSessionGrams = uniqueSessions
            .filter { $0.source == .timer }
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
                && !$0.isBaked
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
              tiltHintTask == nil,
              isVoiceOverHint || !reduceMotion
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

        let progressMessage = PostDropProgressAccessibilityPresentation.description(
            effortProgress: offer.effortProgress,
            fusionState: offer.fusionState,
            projectionIsLowerBound: offer.projectionIsLowerBound
        )
        var message = "\(offer.dropTitle(for: rareRewardMode))\(offer.subjectName)、\(offer.grams)グラム、\(EffortProgressPresentation.formattedStandardUnits(grams: offer.grams))。\(offer.weeklySpokenTitle)。\(offer.rareRewardCounts.multiDrawSummary.map { "\($0)。" } ?? "")\(progressMessage)。\(offer.minutes)分休憩できます"
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
    init(request: JarBakeRequest) {
        self.init(
            id: request.id,
            createdAt: request.createdAt,
            pebbleCount: request.pebbleCount,
            grams: request.grams,
            monthLabel: request.monthLabel,
            colorHex: request.outputDescriptor.colorHex,
            level: request.outputLevel
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

private struct FocusConfiguration: Identifiable {
    let id = UUID()
    let subject: Subject
    let duration: PomodoroDuration
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

    init(receipt: PendingRewardReceipt) {
        id = receipt.id
        minutes = receipt.breakMinutes
        grams = receipt.grams
        subjectName = receipt.subjectName
        colorHex = receipt.colorHex
        weeklyCompletionCount = receipt.weeklyCompletionCount
        weeklyStudyGrams = receipt.weeklyStudyGrams
        kind = receipt.kind
        if let drawCount = receipt.rareRewardDrawCount,
           let goldCount = receipt.goldRewardCount,
           let prismCount = receipt.prismRewardCount {
            rareRewardCounts = RareRewardCounts(
                drawCount: drawCount,
                goldCount: goldCount,
                prismCount: prismCount
            )
        } else {
            rareRewardCounts = RareRewardCounts(
                outcomes: receipt.kind == .normal ? [] : [receipt.kind]
            )
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

private struct BreakConfiguration: Identifiable {
    let id = UUID()
    let minutes: Int
}

private struct DurationChip: View {
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title).font(.system(.subheadline, design: .rounded, weight: .bold))
                Text(subtitle).font(.caption2).foregroundStyle(selected ? TsumibenTheme.background.opacity(0.72) : TsumibenTheme.muted)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .foregroundStyle(selected ? TsumibenTheme.background : TsumibenTheme.text)
            .background(selected ? TsumibenTheme.amber : TsumibenTheme.raised, in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(TsumibenBareButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AchievementDraft {
    let kind: AchievementKind
    let note: String
    let achievedAt: Date
}

private struct AchievementEntrySheet: View {
    let subjects: [Subject]
    let usagePurpose: UsagePurpose
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
        usagePurpose: UsagePurpose,
        onAdd: @escaping (Subject, AchievementDraft) -> Bool
    ) {
        self.subjects = subjects
        self.usagePurpose = usagePurpose
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
                    TsumibenSheetCloseButton(
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
                    .font(TsumibenTheme.brand(26))
                Text(achievementIntroduction)
                    .font(.subheadline)
                    .foregroundStyle(TsumibenTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(usagePurpose.achievementKindsInDisplayOrder) { kind in
                Button {
                    selectedKind = kind
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: kind.systemImage)
                            .font(.title2)
                            .foregroundStyle(TsumibenTheme.amber)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.title)
                                .font(.system(.headline, design: .rounded, weight: .bold))
                            Text(kind.detail)
                                .font(.caption)
                                .foregroundStyle(TsumibenTheme.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(TsumibenTheme.muted)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                    .background(TsumibenTheme.card, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(TsumibenBareButtonStyle())
            }
        }
    }

    private var achievementIntroduction: String {
        usagePurpose == .work
            ? "納品・公開・案件完了などの節目を、集中時間とは別のひとまわり大きな記念石として残せます。"
            : "100点や試験合格を、集中時間とは別のひとまわり大きな記念石として残せます。"
    }

    private func detailsStep(kind: AchievementKind) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: kind.systemImage)
                    .font(.title)
                    .foregroundStyle(TsumibenTheme.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .font(TsumibenTheme.brand(24))
                    Text(selectedSubject?.safeDisplayName ?? "テーマを選んでください")
                        .font(.subheadline)
                        .foregroundStyle(TsumibenTheme.muted)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(usagePurpose.categoryTitle)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TsumibenTheme.muted)
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
                            .foregroundStyle(TsumibenTheme.muted)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(TsumibenTheme.text)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(TsumibenTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("\(usagePurpose.categoryTitle)、\(selectedSubject?.safeDisplayName ?? "未選択")")
                .accessibilityHint("成果を結びつけるテーマを変更できます")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("成果名（任意）")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TsumibenTheme.muted)
                TextField(kind.notePlaceholder, text: $note)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .background(TsumibenTheme.raised, in: RoundedRectangle(cornerRadius: 12))
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
            .foregroundStyle(TsumibenTheme.muted)
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
                    ProgressView().tint(TsumibenTheme.background)
                } else {
                    Label("この成果を積む", systemImage: "medal.fill")
                }
            }
            .buttonStyle(TsumibenPrimaryButtonStyle())
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
                    TsumibenSheetCloseButton { dismiss() }
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
                .font(TsumibenTheme.brand(26))
            Text(subject?.safeDisplayName ?? "テーマを選んでください")
                .foregroundStyle(TsumibenTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func remainingCount(_ availability: ManualEntryAvailability) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: availability.isAllowed ? "checkmark.circle.fill" : "clock.badge.xmark")
                .font(.title3)
                .foregroundStyle(availability.isAllowed ? TsumibenTheme.amber : TsumibenTheme.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("本日あと\(availability.remainingEntries)回")
                    .font(.headline)
                    .accessibilityIdentifier("manual.remaining-count")
                Text(
                    availability.isAllowed
                        ? "選んだだけでは保存されません。次の画面で内容を確認できます。"
                        : "本日の上限です。朝4:00に3回へ切り替わります。"
                )
                .font(.caption)
                .foregroundStyle(TsumibenTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TsumibenTheme.raised, in: RoundedRectangle(cornerRadius: 13))
    }

    private var fairnessCopy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(Constants.UIStrings.fairnessNote, systemImage: "circle.dashed")
                .font(.caption)
                .foregroundStyle(TsumibenTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("1日3回まで・朝4:00に回数が切り替わります")
                .font(.caption2)
                .foregroundStyle(TsumibenTheme.muted)
        }
    }

    private func confirmationCard(
        duration: ManualDuration,
        availability: ManualEntryAvailability
    ) -> some View {
        TsumibenCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionEyebrow(text: "CONFIRM")
                    Text("この内容で積みますか？")
                        .font(TsumibenTheme.brand(21))
                }

                VStack(spacing: 10) {
                    confirmationRow(title: "テーマ", value: subject?.safeDisplayName ?? "未選択")
                    confirmationRow(title: "時間", value: durationTitle(duration))
                    confirmationRow(title: "加算", value: "+\(duration.grams)g")
                    confirmationRow(
                        title: "保存後",
                        value: "本日あと\(availability.remainingEntriesAfterSaving)回"
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
                        ProgressView().tint(TsumibenTheme.background)
                    } else {
                        Label("確認して積む", systemImage: "plus.circle.fill")
                    }
                }
                .buttonStyle(TsumibenPrimaryButtonStyle())
                .disabled(subject == nil || !availability.isAllowed || isSubmitting)
                .accessibilityIdentifier("manual.confirm")
            }
        }
    }

    private func confirmationRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(TsumibenTheme.muted)
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
                            ? TsumibenTheme.background.opacity(0.72)
                            : TsumibenTheme.muted
                    )
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 78)
            .foregroundStyle(selected ? TsumibenTheme.background : TsumibenTheme.text)
            .background(
                selected ? TsumibenTheme.amber : TsumibenTheme.raised,
                in: RoundedRectangle(cornerRadius: 13)
            )
        }
        .buttonStyle(TsumibenBareButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel("\(title)、\(grams)グラム加算")
        .accessibilityHint(isEnabled ? "内容の確認へ進みます" : "本日の手動追加上限です")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct CustomDurationView: View {
    @Binding var minutes: Int
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        SectionEyebrow(text: "TSUMIBEN PRO")
                        Text("集中時間を選ぶ").font(TsumibenTheme.brand(26))
                    }
                    Text("\(minutes):00")
                        .font(.system(size: 54, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Slider(
                        value: Binding(get: { Double(minutes) }, set: { minutes = Int($0.rounded()) }),
                        in: Double(Constants.Timer.customMinimumMinutes)...Double(Constants.Timer.customMaximumMinutes),
                        step: 1
                    )
                    .tint(TsumibenTheme.amber)
                    .accessibilityLabel("集中時間")
                    .accessibilityValue("\(minutes)分")
                    Button("この時間にする", action: onConfirm)
                        .buttonStyle(TsumibenPrimaryButtonStyle())
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(NightBackground())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    TsumibenSheetCloseButton(
                        accessibilityIdentifier: "custom-timer.close"
                    ) {
                        dismiss()
                    }
                }
            }
        }
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
                                        TsumibenTheme.auroraViolet.opacity(0.10),
                                        TsumibenTheme.raised.opacity(0.58)
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
                                .foregroundStyle(TsumibenTheme.muted)
                            Text("10")
                            Image(systemName: "arrow.right")
                                .accessibilityHidden(true)
                            Text("1")
                            Text("・ 記録 100% 保持")
                                .foregroundStyle(TsumibenTheme.muted)
                        }
                        .font(.system(.caption, design: .rounded, weight: .black))
                        .monospacedDigit()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(TsumibenTheme.card.opacity(0.92), in: Capsule())
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
                            .font(TsumibenTheme.brand(24))
                            .multilineTextAlignment(.center)
                        Text("これは瓶を軽く保つための二次的な整理です。保存表示だけを圧縮し、一粒ずつの時間も、\(formattedMass(request.grams))の質量も100%保持します。時間の核は回数でなく質量から進みます。")
                            .font(.subheadline)
                            .foregroundStyle(TsumibenTheme.muted)
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
                        .buttonStyle(TsumibenPrimaryButtonStyle())
                    Button("この結晶をカードにする", action: onShare)
                        .buttonStyle(TsumibenSecondaryButtonStyle())
                    Button("ここで休む", action: onContinue)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(TsumibenTheme.muted)
                        .frame(minHeight: 44)
                        .buttonStyle(TsumibenBareButtonStyle())
                }
                .padding(24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(NightBackground())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    TsumibenSheetCloseButton(
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
            Text(title).font(.caption2).foregroundStyle(TsumibenTheme.muted)
            Text(value).font(.system(.subheadline, design: .rounded, weight: .bold))
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(TsumibenTheme.card, in: RoundedRectangle(cornerRadius: 12))
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
            let loose = sessions.filter { !$0.isBaked }
            let rootRows = aggregates.filter(\.isRoot).sorted {
                if $0.id == $1.id { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            let root = rootRows.first
            let sourceIDs = root?.sessionIDs.map(\.uuidString).sorted() ?? []
            let rootIDs = rootRows.map { $0.id.uuidString }.sorted()
            let logicalGrams = loose.reduce(0) { $0 + $1.grams }
                + rootRows.reduce(0) { $0 + $1.grams }

            auditValue = [
                "sessionRows=\(sessions.count)",
                "uniqueSessionIDs=\(Set(sessions.map(\.id)).count)",
                "bakedSessionRows=\(sessions.filter(\.isBaked).count)",
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
/// has already settled. This probe therefore retains the rise observed by the
/// app's render loop. A no-op bounce cannot advance the sequence or its rise.
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
    @State private var bounceRise: CGFloat = 0
    @State private var bounceStartY: CGFloat?
    @State private var bounceLeaderID: UUID?
    @State private var isTrackingBounce = false
    @State private var targetX: CGFloat = 0.5
    @State private var targetY: CGFloat = 0.88

    private static let bounceVelocityThreshold: CGFloat = 30

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
            format: "count=%d;maxY=%.3f;records=%@;bounceSequence=%d;bounceRise=%.3f;targetX=%.5f;targetY=%.5f",
            count,
            Double(maximumY),
            records,
            bounceSequence,
            Double(bounceRise),
            Double(targetX),
            Double(targetY)
        )
    }

    private func samplePresentation() {
        // This test exercises the ordinary spatial response. The explicit
        // two-flag test process must not inherit a host Simulator's Reduce
        // Motion preference; the probe itself is compiled out of Release.
        if scene.reduceMotion {
            scene.reduceMotion = false
        }

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
            bounceRise = 0
            bounceStartY = nil
            bounceLeaderID = nil
            isTrackingBounce = false
        }

        let upwardLeader = pebbles.max { lhs, rhs in
            (lhs.physicsBody?.velocity.dy ?? 0) < (rhs.physicsBody?.velocity.dy ?? 0)
        }
        let maximumUpwardVelocity = upwardLeader?.physicsBody?.velocity.dy ?? 0

        if !isTrackingBounce,
           maximumUpwardVelocity >= Self.bounceVelocityThreshold,
           let upwardLeader {
            bounceSequence += 1
            bounceStartY = upwardLeader.position.y
            bounceLeaderID = upwardLeader.descriptor.id
            bounceRise = 0
            isTrackingBounce = true
        }

        guard isTrackingBounce,
              let bounceStartY,
              let bounceLeaderID,
              let leader = pebbles.first(where: { $0.descriptor.id == bounceLeaderID })
        else { return }

        bounceRise = max(bounceRise, leader.position.y - bounceStartY)
        if (leader.physicsBody?.velocity.dy ?? 0) <= 0 {
            isTrackingBounce = false
            self.bounceStartY = nil
            self.bounceLeaderID = nil
        }
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
