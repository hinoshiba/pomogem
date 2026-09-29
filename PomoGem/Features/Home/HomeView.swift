import Accessibility
import OSLog
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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
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
    /// home-11. Set once a crystal's detail has been opened. Until then a
    /// tip under the jar says crystals can be tapped; afterwards the tip and
    /// its 72 pt row go away and the jar keeps its full height.
    @AppStorage(AccountScopedLocalState.defaultsKey(base: HomeView.aggregateDetailSeenStorageBase))
    private var didSeeAggregateDetail = false
    /// Also forgotten by a new UI test's first launch
    /// (`UITestLocalStateIsolation`), so one test's opened detail does not
    /// take the tip row away from the next test's jar.
    static let aggregateDetailSeenStorageBase = "jar.aggregate-detail-seen"
    @AppStorage(AccountScopedLocalState.defaultsKey(base: HomeAtmosphere.storageKey))
    private var homeAtmosphereRawValue = HomeAtmosphere.aurora.rawValue
    @AppStorage(AccountScopedLocalState.defaultsKey(base: RecentCustomFocusDurations.storageKey))
    private var recentCustomFocusSecondsRawValue = ""
    /// settings-04. The fusion sheet's one quiet 「Proなら…」 link is offered
    /// once, ever, on this device (see `MonthLabelHintPolicy`).
    @AppStorage(AccountScopedLocalState.defaultsKey(base: MonthLabelHintPolicy.offeredStorageKey))
    private var didOfferMonthLabelHint = false
    /// The celebration that showed the link keeps it while it is open.
    @State private var monthLabelHintCelebrationID: UUID?
    /// Tapped: the paywall opens only once the fusion sheet has closed, since
    /// a root sheet cannot present over Home's sheet.
    @State private var opensMonthLabelPaywallAfterCelebration = false
    @State private var scene = JarScene()
    /// Bumped whenever PendingRewardReceiptStore writes. The receipts live in
    /// UserDefaults, which SwiftUI does not observe, so clearing the last one
    /// must re-evaluate Home explicitly: otherwise the start button stays
    /// disabled and a queued fusion celebration waits until some unrelated
    /// state change (formerly the three-second Screen Time pass) re-renders.
    @State private var pendingRewardReceiptRevision = 0
    /// Screen Time drops retired, manual gems still falling (dev-D7), timer
    /// gems landed while Home still holds their receipt, and the stage's
    /// measured geometry. Only the jar's stage observes it, so a landing no
    /// longer re-renders all of Home (device-verify-2 P4).
    @State private var jarStageState = JarStageState()
    /// Home's own follow-up to a landing, run once the jar has settled.
    @State private var landingSettle = LandingSettleScheduler()
    @State private var sceneInitialized = false
    /// Room for a tapped crystal's card under the bottle
    /// (`AggregateCardPlacementPolicy`), in the Home content's coordinates.
    @State private var measuredPickerRowTop: CGFloat?
    @State private var measuredLauncherTop: CGFloat?
    @State private var measuredAggregateCardHeight: CGFloat?
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
    /// device-verify-2 P2. A read is retiring a complete page: until it lands,
    /// the page on screen no longer proves its completeness, and the readout
    /// derived from it would change for the read alone. A read of a page that
    /// was not complete changes nothing before it lands and is not flagged,
    /// which would cost Home a body pass on every refresh of a long history.
    @State private var sessionPageIsRereading = false
    /// device-verify-2 P2 (review). The latest read of the page failed and no
    /// other has started: nothing in flight will replace a held readout.
    @State private var sessionPageReadFailed = false
    /// device-verify-2 P2. The lifetime readout this Home last presented from
    /// settled inputs, kept on screen while it re-derives them
    /// (`LifetimeReadoutContinuityPolicy`). A box, not observed state:
    /// recording what is already on screen must not cost another body pass.
    @State private var lastSettledLifetimeReadout = SettledLifetimeReadoutBox()
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
    /// sync-03. The last lifetime total this Home presented as verified, for
    /// the next pending phase (`PendingMassPresentationPolicy`).
    @State private var lastVerifiedMass = VerifiedMassRecordStore.load()
    /// sync-03. The completion card's weekly heading, re-derived once
    /// verification completes after its receipt froze.
    @State private var restampedWeekly: RestampedWeeklyMetrics?
    @State private var selectedDuration: PomodoroDuration = .twentyFiveMinutes
    @State private var focusConfiguration: FocusConfiguration?
    @State private var showHomeMenu = false
    /// The menu's height, bound so that picking a background can lower a
    /// fully raised menu back to half height, where the new background shows.
    @State private var homeMenuDetent: PresentationDetent = .medium
    @State private var showAccumulationOverview = false
    @State private var overviewInitialClusterID: UUID?
    @State private var aggregateInspectionID: UUID?
    @State private var selectedAggregateDetail: AccumulationClusterSummary?
    @State private var aggregateInspectionTask: Task<Void, Never>?
    @State private var showManualEntry = false
    /// history-02. Confirmed but not yet written; see `PendingManualEntry`.
    @State private var pendingManualEntry: PendingManualEntry?
    @State private var pendingManualCommitTask: Task<Void, Never>?
    /// VoiceOver focus for the banner's 「元に戻す」, moved there once the
    /// manual-entry sheet has gone (see `manualUndoBanner`).
    @AccessibilityFocusState private var manualUndoHasFocus: Bool
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
    /// The completion card's 「しくみ」 is closed for every new card.
    @State private var postDropMechanicsExpanded = false
    /// The completion card's layout, measured so that opening 「しくみ」
    /// scrolls inside the card instead of growing up over the jar's HUD:
    /// Home's safe viewport, the whole bottom inset, and the card body's
    /// visible, natural and collapsed heights.
    @State private var homeViewportHeight: CGFloat = 0
    @State private var postDropInsetHeight: CGFloat = 0
    @State private var postDropBodyVisibleHeight: CGFloat = 0
    @State private var postDropBodyNaturalHeight: CGFloat = 0
    @State private var postDropCollapsedBodyHeight: CGFloat = 0
    /// D18: the first completion's 「明日もこの時間に？」, for that card only.
    @State private var reminderOffer: CompletionReminderOffer?
    /// D18: the receipt whose offer was closed with ✕, so a relaunch that
    /// restores the same card does not offer it again. Device-local only.
    @AppStorage(AccountScopedLocalState.defaultsKey(base: "reward.reminder-offer.dismissed"))
    private var dismissedReminderOfferID = ""
    /// product-05: the card just acknowledged made the first ×10 and the
    /// time core together, so that crystal's fusion sheet says so, once.
    /// In memory only; it lasts until that sheet finishes.
    @State private var coreBirthTeaching: CoreBirthTeachingPending?
    /// Whether the fusion sheet on screen is the one that teaches.
    @State private var presentedStratumTeachesCoreBirth = false
    /// Read to keep 先月の瓶のお知らせ as it is when the card's reminder
    /// offer books the daily reminder (Settings owns the switch), and to
    /// leave its shared time alone.
    @AppStorage(AccountScopedLocalState.defaultsKey(base: "notifications.wrapped"))
    private var wrappedNotifications = false
    @State private var announcedPostDropShareOfferID: UUID?
    /// The short settle before an outside focus start (FocusStartEntryPolicy).
    @State private var focusStartEntryTask: Task<Void, Never>?

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

    private static let manualEntryLogger = Logger(
        subsystem: "com.hinoshiba.pomogem",
        category: "ManualEntry"
    )

    private static let receiptLogger = Logger(
        subsystem: "com.hinoshiba.pomogem",
        category: "RewardReceipt"
    )

    /// Delivered on the main queue: the store may be written off-main, and a
    /// write made during a view update must not mutate state inside it. Not
    /// `RunLoop.main`, whose Combine scheduler runs only in the default mode:
    /// a change posted while the AX5 Home scroll view or a sheet is being
    /// dragged would wait until the finger lifts, and with it the start
    /// button and the queued celebration.
    private static let pendingRewardReceiptChanges = NotificationCenter.default
        .publisher(for: PendingRewardReceiptStore.didChangeNotification)
        .receive(on: DispatchQueue.main)

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
        looseSessions(from: queriedLooseSessions)
    }
    private func looseSessions(from candidates: [StudySession]) -> [StudySession] {
        let rewardIDs = Set(currentRewardSessionBackfill.map(\.id))
        let rewards = candidates.filter { rewardIDs.contains($0.id) }
        let remaining = candidates.filter { !rewardIDs.contains($0.id) }
        return Array((rewards + remaining).prefix(HomeProjectionPolicy.looseSessionLimit))
            .sorted { $0.endAt > $1.endAt }
    }
    private var localProjectionNeedsMaintenance: Bool {
        let candidates = queriedLooseSessions
        return localProjectionNeedsMaintenance(
            candidateCount: candidates.count,
            presentedCount: looseSessions(from: candidates).count
        )
    }
    private func localProjectionNeedsMaintenance(candidateCount: Int, presentedCount: Int) -> Bool {
        !rootProjectionIsComplete
            || aggregateProjectionNeedsMaintenance
            || !localMembershipProjectionIsComplete
            || !sessionBackfillIsComplete
            || acceptedAggregateRootIDs.count
                != AggregatePebblePolicy.activeRoots(from: aggregates).count
            || candidateCount != presentedCount
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
    /// Saved sessions whose gem has not landed in the jar yet because of a
    /// timer completion: behind its card or falling (its receipt, or the
    /// completion marker before the receipt exists). Queued Screen Time gems
    /// and falling manual entries are added by the jar's stage from
    /// `jarStageState` (`HomeProjectionPolicy.unlandedSessionIDs`).
    private var receiptUnlandedSessionIDs: Set<UUID> {
        _ = pendingRewardReceiptRevision
        return HomeProjectionPolicy.unlandedSessionIDs(
            rewardReceipts: PendingRewardReceiptStore.load(),
            completionMarker: UserDefaults.standard.string(
                forKey: FocusPersistence.localCompletionIDKey
            ),
            screenTimeDrops: [],
            fallingManualEntries: []
        )
    }
    /// What the jar's readout, core and large-text card need to count a gem
    /// when it lands, not when its session is saved (dev-D7,
    /// `HomeProjectionPolicy.landedTotals`). Resolved on Home's own passes,
    /// with the rest of the readout (`liveLifetimeReadout`);
    /// `JarStageReader` applies `jarStageState` to it, so a landing re-runs
    /// only the reader (device-verify-2 P4). Each read decodes the receipts,
    /// so a pass reads it once.
    private func landedTotalsInputs(
        roots: [AggregatePebble],
        looseSessions: [StudySession],
        savedTotals: HomeProjectionPolicy.Totals
    ) -> JarLandedTotalsInputs {
        JarLandedTotalsInputs(
            roots: roots,
            looseSessions: looseSessions,
            pendingOnHomePass: receiptUnlandedSessionIDs,
            savedTotals: savedTotals
        )
    }
    /// sync-03 after review. What the headline says while iCloud is checked.
    private var pendingMassHeadline: PendingMassPresentationPolicy.Headline {
        let candidates = queriedLooseSessions
        let loose = looseSessions(from: candidates)
        let roots = acceptedAggregateRoots
        return pendingMassHeadline(
            looseSessions: loose,
            candidateCount: candidates.count,
            roots: roots,
            totals: HomeProjectionPolicy.totals(roots: roots, looseSessions: loose)
        )
    }
    private func pendingMassHeadline(
        looseSessions loose: [StudySession],
        candidateCount: Int,
        roots: [AggregatePebble],
        totals: HomeProjectionPolicy.Totals
    ) -> PendingMassPresentationPolicy.Headline {
        PendingMassPresentationPolicy.headline(
            lastVerified: lastVerifiedMass,
            currentEpochID: currentActivityEpochID,
            deviceSessions: loose.map { .init(id: $0.id, endAt: $0.endAt, grams: $0.grams) },
            deviceTotals: totals,
            // While pending no aggregate is accepted, so Home's own sum is the
            // whole lifetime only when its complete candidate page fits in the
            // jar's cap.
            deviceCoversEverySession: PendingMassPresentationPolicy.deviceCoversEverySession(
                pageIsCurrent: sceneSessionSnapshotIsCurrent,
                pageIsComplete: sessionBackfillIsComplete,
                membershipIsComplete: localMembershipProjectionIsComplete,
                acceptedAggregateCount: roots.count,
                candidateCount: candidateCount,
                presentedCount: loose.count
            )
        )
    }
    /// device-verify-2 P2. Home's page belongs to the current presentation
    /// generation and no read is retiring a complete one.
    private var lifetimeInputsAreSettled: Bool {
        sceneSessionSnapshotIsCurrent && !sessionPageIsRereading
    }
    /// Where this pass takes the lifetime readout from
    /// (`LifetimeReadoutContinuityPolicy`).
    private var lifetimeReadoutSource: LifetimeReadoutContinuityPolicy.Source {
        LifetimeReadoutContinuityPolicy.source(
            inputsAreSettled: lifetimeInputsAreSettled,
            lastReadFailed: sessionPageReadFailed,
            lastSettled: lastSettledLifetimeReadout.value,
            currentEpochID: currentActivityEpochID,
            isCloudVerificationPending: aggregateProjectionPresentation.isCloudVerificationPending
        )
    }
    /// Everything the jar and the menu say about the lifetime total. A pass
    /// derives it once and hands it down (`jarStageSnapshot`, the menu's
    /// strip): an observer of the readout re-derived all of it on every pass
    /// (review of #56).
    private func presentedLifetimeReadout() -> LifetimeReadoutContinuityPolicy.Readout {
        presentedLifetime().readout
    }
    /// The readout this pass presents, and for live inputs what the jar's
    /// stage completes it with as gems land (device-verify-2 P4). A held or
    /// loading readout stays as it is. A settled one is remembered by the
    /// jar's stage, which presents it with the gems landed since this pass
    /// (`JarStageReader`), so what is kept is what was on screen.
    private func presentedLifetime() -> (
        readout: LifetimeReadoutContinuityPolicy.Readout,
        landing: JarLandedTotalsInputs?,
        isSettled: Bool
    ) {
        switch lifetimeReadoutSource {
        case let .held(readout):
            return (readout, nil, false)
        case .loading:
            return (.loading(
                isCloudVerificationPending: aggregateProjectionPresentation.isCloudVerificationPending,
                coreColorHex: selectedSubject?.colorHex ?? Constants.Color.amberLamp
            ), nil, false)
        case .live:
            let live = liveLifetimeReadout()
            return (live.readout, live.landing, false)
        case .settled:
            let live = liveLifetimeReadout()
            return (live.readout, live.landing, true)
        }
    }
    /// The readout Home's inputs give now. The jar shows the pending headline
    /// while iCloud is checked (sync-03); otherwise the landed totals
    /// (dev-D7), so a completed focus joins when its gem lands. The menu
    /// counts saved sessions at once, like widgets and share. Every input
    /// below re-runs the page's canonicalisation, filters and sort, so each
    /// is read once.
    ///
    /// The landed totals here are those Home's own pass knows (the timer
    /// gems its receipts hold back); the jar's stage completes the readout
    /// with the gems that have landed or started falling since
    /// (`JarLandedTotalsInputs.completing`).
    private func liveLifetimeReadout() -> (
        readout: LifetimeReadoutContinuityPolicy.Readout,
        landing: JarLandedTotalsInputs
    ) {
        let isPending = aggregateProjectionPresentation.isCloudVerificationPending
        let candidates = queriedLooseSessions
        let loose = looseSessions(from: candidates)
        let roots = acceptedAggregateRoots
        let totals = HomeProjectionPolicy.totals(roots: roots, looseSessions: loose)
        let landing = landedTotalsInputs(roots: roots, looseSessions: loose, savedTotals: totals)
        let landed = landing.landedTotalsOnHomePass
        let weights = lifetimeCoreColorWeights(roots: roots, looseSessions: loose)
        let jarGrams: Int?
        let jarPebbles: Int
        let menuGrams: Int?
        let menuPebbles: Int
        let isLowerBound: Bool
        if isPending {
            let headline = pendingMassHeadline(
                looseSessions: loose, candidateCount: candidates.count, roots: roots, totals: totals
            )
            jarGrams = headline.grams
            jarPebbles = headline.pebbleCount ?? totals.pebbleCount
            menuGrams = jarGrams
            menuPebbles = jarPebbles
            isLowerBound = headline.isLowerBound
        } else {
            jarGrams = landed.grams
            jarPebbles = landed.pebbleCount
            menuGrams = totals.grams
            menuPebbles = totals.pebbleCount
            isLowerBound = localProjectionNeedsMaintenance(
                candidateCount: candidates.count, presentedCount: loose.count
            )
        }
        let readout = LifetimeReadoutContinuityPolicy.Readout(
            isCloudVerificationPending: isPending,
            jarGrams: jarGrams,
            // The device's own sum draws the core while the headline says
            // 「再集計中」.
            jarCoreGrams: jarGrams ?? totals.grams,
            jarPebbles: jarPebbles,
            // The landed loose sessions (瓶の整理).
            jarLoosePebbles: landing.landedLoosePebbleCount(landed),
            menuGrams: menuGrams,
            menuPebbles: menuPebbles,
            isLowerBound: isLowerBound,
            jarIsEmpty: isJarEmpty(roots: roots, looseSessions: loose),
            coreColorHex: coreColorHex(weights),
            coreColorShares: JarLifetimeCorePresentation.colorShares(weights: weights),
            aggregateCount: roots.count,
            legacyAggregateCount: activeLegacyStratumVisuals.count,
            goldPebbleCount: visibleGoldPebbleCount(roots: roots, looseSessions: loose),
            prismPebbleCount: visiblePrismPebbleCount(roots: roots, looseSessions: loose)
        )
        return (readout, landing)
    }
    /// The wording a readout is presented under: one recorded while iCloud
    /// was checked keeps 「iCloudを確認中」 until the new page is read.
    private func presentationContext(
        for readout: LifetimeReadoutContinuityPolicy.Readout
    ) -> AggregateProjectionPresentationContext {
        var context = aggregateProjectionPresentation
        if readout.isCloudVerificationPending { context.isVerified = false }
        return context
    }
    /// What a verified Home leaves for the next pending phase. Only a total
    /// that is actually on screen as verified is ever recorded. Observed on
    /// every pass, so each input is read once.
    private var verifiedMassRecordCandidate: VerifiedMassRecord? {
        guard aggregateProjectionPresentation.usesCloudPersistence,
              !aggregateProjectionPresentation.isCloudVerificationPending,
              currentAggregatePresentationPage != nil,
              lifetimeInputsAreSettled else { return nil }
        let candidates = queriedLooseSessions
        let loose = looseSessions(from: candidates)
        let roots = acceptedAggregateRoots
        let totals = HomeProjectionPolicy.totals(roots: roots, looseSessions: loose)
        return PendingMassPresentationPolicy.record(
            grams: totals.grams,
            pebbleCount: totals.pebbleCount,
            isLowerBound: localProjectionNeedsMaintenance(
                candidateCount: candidates.count, presentedCount: loose.count
            ),
            epochID: currentActivityEpochID,
            countedSessions: verifiedCountedSessions(looseSessions: loose),
            newestAggregatedEnd: roots.map(\.periodEnd).max()
        )
    }
    /// The sessions a verified total counts: loose, or represented by an
    /// accepted aggregate. The newest of them anchors the record even when a
    /// decimal fusion has just folded it into an aggregate.
    private func verifiedCountedSessions(
        looseSessions: [StudySession]
    ) -> [PendingMassPresentationPolicy.Session] {
        let looseIDs = Set(looseSessions.map(\.id))
        return sessions
            .filter { looseIDs.contains($0.id) || representedSessionIDs.contains($0.id) }
            .map { .init(id: $0.id, endAt: $0.endAt, grams: $0.grams) }
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
    private func visibleGoldPebbleCount(
        roots: [AggregatePebble],
        looseSessions: [StudySession]
    ) -> Int {
        guard RareRewardReleasePolicy.isEnabled else { return 0 }
        let loose = RareRewardCounts.total(looseSessions.map(\.rareRewardCounts))
        return HomeProjectionPolicy.saturatingNonnegativeSum([
            HomeProjectionPolicy.saturatingNonnegativeSum(
                roots.map(\.goldPebbleCount)
            ),
            loose.goldCount
        ])
    }
    private func visiblePrismPebbleCount(
        roots: [AggregatePebble],
        looseSessions: [StudySession]
    ) -> Int {
        guard RareRewardReleasePolicy.isEnabled else { return 0 }
        let loose = RareRewardCounts.total(looseSessions.map(\.rareRewardCounts))
        return HomeProjectionPolicy.saturatingNonnegativeSum([
            HomeProjectionPolicy.saturatingNonnegativeSum(
                roots.map(\.prismPebbleCount)
            ),
            loose.prismCount
        ])
    }
    /// The optical lifetime core uses the exact accounting frontier rather
    /// than the currently selected subject. A long-lived person therefore sees
    /// the colour of their accumulated effort, while the launch button can
    /// still describe the next chosen theme independently.
    private func coreColorHex(_ weights: [String: Double]) -> String {
        weights.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }.first?.key ?? selectedSubject?.colorHex ?? Constants.Color.amberLamp
    }

    /// The same fan the Overview draws (`JarLifetimeCorePresentation`). Its
    /// approximate theme shares (root grams × colour mix + loose grams) are
    /// count-weighted for aggregates, so they are called "おおよそ" and never
    /// a mass breakdown.
    private func lifetimeCoreColorWeights(
        roots: [AggregatePebble],
        looseSessions: [StudySession]
    ) -> [String: Double] {
        JarLifetimeCorePresentation.colorWeights(
            roots.map { aggregate in
                JarLifetimeCorePresentation.ColorContribution(
                    grams: aggregate.grams,
                    colorMix: aggregate.colorMix.isEmpty
                        ? [StratumColorFraction(
                            hex: aggregate.subjectMix.first?.colorHex
                                ?? selectedSubject?.colorHex
                                ?? Constants.Color.amberLamp,
                            fraction: 1
                        )]
                        : aggregate.colorMix
                )
            }
            + looseSessions.map {
                JarLifetimeCorePresentation.ColorContribution(grams: $0.grams, hex: $0.displaySubjectColorHex)
            }
        )
    }
    private var visibleAchievementStones: [AchievementStone] {
        AchievementStonePolicy.visibleStones(from: achievementStones)
    }
    private var uniqueAchievementCount: Int {
        max(projectedAchievementCount, Set(achievementStones.map(\.id)).count)
    }
    /// Whether the jar holds anything now, for the one-time hint; the jar
    /// card reads its readout's (`presentedLifetimeReadout`).
    private var isJarEmpty: Bool {
        isJarEmpty(roots: activeAggregateRoots, looseSessions: looseSessions)
    }
    private func isJarEmpty(roots: [AggregatePebble], looseSessions: [StudySession]) -> Bool {
        looseSessions.isEmpty
            && visibleAchievementStones.isEmpty
            && roots.isEmpty
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
        _ = pendingRewardReceiptRevision
        return !PendingRewardReceiptStore.load().isEmpty
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
#if DEBUG
        let _ = HomeRenderDiagnostics.recordBodyEvaluation()
#endif
        focusStartEntryContent
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let jarHeight = homeJarHeight(availableHeight: proxy.size.height)
                let cardPlacement = aggregateCardPlacement(jarHeight: jarHeight)
                // One readout for the jar and its large-text companion; both
                // readers take their values from it.
                let stage = jarStageSnapshot
                ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 0) {
                        jarCard(height: jarHeight, cardPlacement: cardPlacement, stage: stage)
                            .id("home.jar")
                        if showsAggregateInspectionSlot(cardPlacement) {
                            aggregateInspectionSlot
                                .padding(.top, 8)
                                .id(Self.aggregateInspectionSlotID)
                        }
                        if showsLargeTextFusionProgress(stage.readout) {
                            // Counts a gem when it lands, like the readout it
                            // repeats; a landing re-runs only this reader,
                            // which reads nothing but the snapshot.
                            JarStageReader(state: jarStageState, stage: stage) { readout in
                                if let state = largeTextFusionProgressState(readout) {
                                    Spacer(minLength: 12)
                                    largeTextFusionProgressCard(state, colorHex: readout.coreColorHex)
                                }
                            }
                        }
                        Spacer(minLength: 14)
                        if !activeSubjects.isEmpty {
                            // The crystal's card under the bottle takes this
                            // row for its few seconds when it reaches it
                            // (`AggregateCardPlacementPolicy`).
                            let givesWayToCard = aggregateInspectionSummary != nil
                                && cardPlacement == .underBottle(hidesPickers: true)
                            focusSelectionControls
                                .onGeometryChange(for: CGFloat.self) { geometry in
                                    geometry.frame(in: .named(Self.homeContentCoordinateSpace)).minY
                                } action: { top in
                                    recordAggregateCardRoom(pickerTop: top, placement: cardPlacement)
                                }
                                .onDisappear { measuredPickerRowTop = nil }
                                .opacity(givesWayToCard ? 0 : 1)
                                .allowsHitTesting(!givesWayToCard)
                                .accessibilityHidden(givesWayToCard)
                                .padding(.bottom, 10)
                        }
                        if !pinsFocusLauncher {
                            // While a completion card is up, its start button is
                            // disabled and sits behind the card; a shorter card left
                            // it half showing above the reward, sliced mid-glyph.
                            focusLauncher
                                .onGeometryChange(for: CGFloat.self) { geometry in
                                    geometry.frame(in: .named(Self.homeContentCoordinateSpace)).minY
                                } action: { top in
                                    recordAggregateCardRoom(launcherTop: top, placement: cardPlacement)
                                }
                                .opacity(breakOffer == nil ? 1 : 0)
                                .allowsHitTesting(breakOffer == nil)
                                .accessibilityHidden(breakOffer != nil)
                        }
                    }
                    // home-11 (#50 follow-up): under the bottle, in front of
                    // the rows below it; the jar card starts at this stack's top.
                    .overlay(alignment: .top) {
                        aggregateCardUnderBottle(jarHeight: jarHeight, placement: cardPlacement)
                    }
                    .coordinateSpace(.named(Self.homeContentCoordinateSpace))
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
                .onChange(of: aggregateInspectionID) { oldID, id in
                    followAggregateInspectionCard(
                        from: oldID,
                        to: id,
                        inRow: cardPlacement == .row,
                        with: scrollProxy
                    )
                }
                }
            }
            // history-02. Over the scroll area only: at accessibility sizes
            // the start button pinned below it stays uncovered.
            .overlay(alignment: .top) {
                if let pendingManualEntry {
                    manualUndoBanner(pendingManualEntry)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .top).combined(with: .opacity)
                        )
                }
            }
            // home-03. Below the scroll view, not over it: content never
            // slides under the button, and the jar is sized to what is left.
            if pinsFocusLauncher {
                pinnedFocusLauncher
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
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                postDropInsetHeight = $0
                            }
                    }
                }
                // Whatever scrolls behind the card's top edge (the theme and
                // duration row) fades out instead of showing half its text.
                .background(alignment: .top) {
                    LinearGradient(
                        colors: [PomoGemTheme.background.opacity(0), PomoGemTheme.background.opacity(0.92)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 30)
                    .offset(y: -30)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
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
        .animation(
            reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.88),
            value: pendingManualEntry?.id
        )
        // The whole safe viewport (the inset does not shrink it), for the
        // completion card's height budget.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
            homeViewportHeight = $0
        }
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
                .environment(\.dynamicTypeSize, dynamicTypeSize)
                .presentationDetents(auxiliarySheetDetents, selection: homeMenuDetentSelection)
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
        // Both entry forms end in a commit button, so they open at full
        // height; a half sheet hid the confirmation below its fold.
        .sheet(isPresented: $showManualEntry) {
            ManualEntrySheet(
                initialSubject: selectedSubject,
                subjects: activeSubjects,
                counterState: manualCounterState,
                onAdd: addManualEntry
            )
                .environment(\.dynamicTypeSize, dynamicTypeSize)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAchievementEntry) {
            AchievementEntrySheet(
                initialSubject: selectedSubject,
                subjects: activeSubjects,
                onAdd: addAchievementStone
            )
                .environment(\.dynamicTypeSize, dynamicTypeSize)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCustomDuration) {
            CustomDurationView(
                initialSeconds: customDurationEditorInitialSeconds,
                onConfirm: confirmCustomDuration
            )
                .environment(\.dynamicTypeSize, dynamicTypeSize)
                .presentationDetents(customDurationSheetDetents)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAccumulationPlan) {
            AccumulationPlanView(start: accumulationPlanStart)
                .environment(\.dynamicTypeSize, dynamicTypeSize)
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $completedStratum, onDismiss: {
            // First, so the open paywall blocks the next queued celebration.
            presentMonthLabelPaywallIfRequested()
            finishPresentedStratumCelebration()
        }) { request in
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

    /// Always one of `auxiliarySheetDetents`: at accessibility sizes and in
    /// landscape the menu only has the full height.
    private var homeMenuDetentSelection: Binding<PresentationDetent> {
        Binding(
            get: {
                auxiliarySheetDetents.contains(homeMenuDetent) ? homeMenuDetent : .large
            },
            set: { homeMenuDetent = $0 }
        )
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
            ScreenTimeController.shared.reload()
            scene.setScreenTimeObstacles(
                totalUnits: ScreenTimeController.shared.negativeGemCount
            )
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
            commitPendingManualEntry()
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
        .onChange(of: scenePhase) { _, phase in
            // Never keep an unsaved entry in memory while iOS may suspend or
            // end the app.
            if phase != .active { commitPendingManualEntry() }
        }
        .onChange(of: router.focusPresentationIsActive) { _, isActive in
            guard !isActive else {
                commitPendingManualEntry()
                return
            }
            configureScene()
            syncScene()
            continueRewardDropIfPossible()
            recoverPendingRewardReceipt()
        }
        .onChange(of: rewardDropSurfaceIsObscured) { _, isObscured in
            guard !isObscured else {
                // Another screen or sheet (the menu, 記録, a second manual
                // add, share) must see the entry as saved, and 元に戻す is only
                // offered here on Home.
                commitPendingManualEntry()
                return
            }
            syncScene()
            continueRewardDropIfPossible()
            recoverPendingRewardReceipt()
        }
    }

    /// sync-03 (review of PR #40), kept out of the long modifier chains below
    /// so each stays within the type checker's budget.
    private var verificationContent: some View {
        lifecycleContent
        // Remember the verified total this Home presents, for the next time
        // iCloud is checked (`PendingMassPresentationPolicy`).
        .onChange(of: verifiedMassRecordCandidate) { _, record in
            guard let record, record != lastVerifiedMass else { return }
            lastVerifiedMass = record
            VerifiedMassRecordStore.save(record)
        }
        .onChange(of: weeklyRestampRequest, initial: true) { _, request in
            rederiveWeeklyMetrics(for: request)
        }
    }

    /// The store and projection observers. `observedContent` used to chain
    /// these with every other observer below and came close to the type
    /// checker's "unable to type-check in reasonable time" limit under load;
    /// three shorter chains are each checked on their own.
    private var storeObservedContent: some View {
        verificationContent
        // Subscribe to the one value the jar needs instead of observing the
        // whole controller: its foreground loop re-reads authorization and
        // monitoring state every three seconds, and each of those passes
        // would otherwise re-evaluate this entire view while Home sits idle.
        .onReceive(ScreenTimeController.shared.negativeGemCountChanges) { count in
            guard homeIsVisible else { return }
            scene.updateScreenTimeObstacles(totalUnits: count)
            noteScreenTimeBlackStones(count)
        }
        .onReceive(Self.pendingRewardReceiptChanges) { _ in
            pendingRewardReceiptRevision &+= 1
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
    }

    /// Purchase, preference and motion observers.
    private var preferenceObservedContent: some View {
        storeObservedContent
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
    }

    /// Announcement and celebration observers.
    private var observedContent: some View {
        preferenceObservedContent
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

    /// Starts asked for from widgets, links and App Shortcuts
    /// (FocusStartEntryPolicy). A separate layer keeps `observedContent`'s
    /// long modifier chain within the type checker's time limit.
    private var focusStartEntryContent: some View {
        observedContent
            .onChange(of: focusStartEntrySnapshot, initial: true) { _, _ in
                handlePendingFocusStart()
            }
            .onDisappear { cancelFocusStartEntrySettle() }
    }

    private func stratumCelebrationSheet(_ request: PendingStratumCelebration) -> some View {
        let sheet = StratumCelebrationView(
            request: request,
            // The crystal's own colour mix, as the jar paints the same ×10
            // (the receipt keeps only its dominant colour).
            colorShares: storedAggregates.first { $0.id == request.id }.map {
                GemArtworkSpec.aggregateColors(
                    $0.colorMix,
                    fallbackHex: request.colorHex ?? Constants.Color.amberLamp
                )
            } ?? [],
            showsMonthLabel: purchase.isPro,
            teachesCoreBirth: presentedStratumTeachesCoreBirth,
            onExplore: exploreCompletedStratum,
            onShare: { shareCompletedStratum(request) },
            onContinue: dismissCompletedStratum,
            monthLabelHint: MonthLabelHintPolicy.offersHint(
                isPro: purchase.isPro,
                entitlementsResolved: purchase.hasResolvedEntitlements,
                alreadyOffered: didOfferMonthLabelHint,
                hintCelebrationID: monthLabelHintCelebrationID,
                celebrationID: request.id
            ) ? MonthLabelHint(
                onShown: {
                    monthLabelHintCelebrationID = request.id
                    didOfferMonthLabelHint = true
                },
                onOpen: {
                    dropFocusStartWaitingOnCelebration()
                    opensMonthLabelPaywallAfterCelebration = true
                    dismissCompletedStratum()
                }
            ) : nil
        )
        // A decimal carry is secondary, lossless storage maintenance. Open it
        // at full height so the organization result and mass-preservation
        // promise remain readable; study value advances separately by mass.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
#if DEBUG && targetEnvironment(simulator)
        // A sheet owns a separate presentation host: forward the pinned AX5
        // UI-test value, as the Overview sheet does.
        return sheet.forwardingUITestAccessibility5()
#else
        return sheet
#endif
    }

    /// Everything the jar's stage shows, resolved once on Home's own pass
    /// (device-verify-2 P4): the lifetime readout (`presentedLifetime`) and
    /// the few other values the stage reads. The stage runs inside
    /// `JarStageReader`, which re-runs it on a landing, so it reads these
    /// values instead of Home's projections, each of which re-derives the
    /// sessions when it is read.
    private var jarStageSnapshot: JarStageSnapshot {
        let lifetime = presentedLifetime()
        return JarStageSnapshot(
            readout: lifetime.readout,
            landing: lifetime.landing,
            settledRecord: lifetime.isSettled
                ? .init(box: lastSettledLifetimeReadout, epochID: currentActivityEpochID)
                : nil,
            uniqueAchievementCount: uniqueAchievementCount,
            accentHex: selectedSubject?.colorHex ?? Constants.Color.amberLamp,
            inspectableAggregateID: latestInspectableAggregateID,
            aggregateInspectionSummary: aggregateInspectionSummary
        )
    }

    /// The reader completes Home's readout with the gems landed since its
    /// pass, remembers a settled one, and re-runs only this stage when a gem
    /// lands.
    private func jarCard(
        height: CGFloat,
        cardPlacement: AggregateCardPlacementPolicy.Placement,
        stage: JarStageSnapshot
    ) -> some View {
        JarStageReader(state: jarStageState, stage: stage, recordsSettledReadout: true) { readout in
            jarStage(height: height, cardPlacement: cardPlacement, stage: stage, readout: readout)
        }
    }

    private func jarStage(
        height: CGFloat,
        cardPlacement: AggregateCardPlacementPolicy.Placement,
        stage: JarStageSnapshot,
        readout: LifetimeReadoutContinuityPolicy.Readout
    ) -> some View {
        ZStack {
            // sync-03 (review of PR #40). While iCloud is checked the jar's
            // lifetime core describes the same total as the headline above,
            // not the newest sessions Home happens to hold. dev-D7: otherwise
            // its core, light and VoiceOver count a gem when it lands, like
            // the readout above. device-verify-2 P2: all of it from one
            // readout, so a held one is never mixed with the page Home is
            // re-reading.
            JarSpriteView(
                scene: scene,
                totalGrams: readout.jarCoreGrams,
                pebbleCount: readout.jarLoosePebbles,
                achievementCount: stage.uniqueAchievementCount,
                aggregateCount: readout.aggregateCount,
                legacyAggregateCount: readout.legacyAggregateCount,
                representedPebbleCount: readout.jarPebbles,
                goldPebbleCount: readout.goldPebbleCount,
                prismPebbleCount: readout.prismPebbleCount,
                accentHex: stage.accentHex,
                lifetimeCoreColorHex: readout.coreColorHex,
                lifetimeCoreColorShares: readout.coreColorShares,
                coreTopClearance: Self.previewsHUDAboveJar ? nil : jarMetricHUDClearance(readout),
                projectionIsLowerBound: readout.jarGrams == nil || readout.isLowerBound,
                projectionIsUnverified: readout.isCloudVerificationPending,
                pendingMass: readout.jarGrams.map {
                    .init(grams: $0, isLowerBound: readout.isLowerBound)
                },
                fusionProgressDescription: fusionAccessibilityDescription(readout),
                isLoadingRecords: readout.isLoading,
                isMotionEnabled: homeJarMotionIsEnabled,
                inspectableAggregateID: stage.inspectableAggregateID,
                onJarTapAccepted: invalidateAggregateInspectionCard,
                onAggregateTapped: revealAggregateInspection,
                onAggregateAccessibilityAction: presentAggregateDetail
            )
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.frame(in: .named(Self.jarCardCoordinateSpace)).minY
                } action: { top in
                    jarStageState.measuredStageTop = top
                }
                .padding(.horizontal, 4)
                .padding(.top, Self.previewsHUDAboveJar ? Self.hudAboveJarHeight : 0)

            jarMetricHUD(stageHeight: height, readout: readout, stage: stage)

            if readout.jarIsEmpty, !showsEmptyJarMessageUnderReadout(readout) {
                emptyJarMessage(readout)
                .multilineTextAlignment(.center)
                .padding(20)
                .frame(maxWidth: 320)
                // The metrics keep a fixed position below the bottle's rim.
                // On a short canvas, move the empty-state copy below them.
                .offset(y: max(0, 456 - height) / 2)
            }

            if let remaining = capacityRemaining, remaining <= 15 {
                // Right under the bottle (round 12), never over the HUD or
                // the time core: the fusion happens in the jar, and the chip
                // only names it. It takes the place of the quiet 内訳 hint
                // below the jar while it shows, and fades in place (sliding
                // from the top edge crossed the value and settled on the
                // core).
                HStack(spacing: 7) {
                    Image(systemName: "circle.grid.2x2.fill")
                    Text(remaining == 0
                        ? String(localized: "結晶をつくっています", table: "Home", comment: "Jar capsule while ten gems fuse")
                        : String(localized: "あと\(remaining)%で、下の粒がひとつの結晶に", table: "Home", comment: "Jar capsule before a fusion; the argument is the remaining capacity percent"))
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(PomoGemTheme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().stroke(PomoGemTheme.amber.opacity(0.28), lineWidth: 1) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // Placed by offset, so the card's layout never changes.
                .offset(y: Self.capacityChipTopInset(stageHeight: height))
                // A tapped crystal's card hangs in the same place for its
                // few seconds; the chip steps aside meanwhile.
                .opacity(stage.aggregateInspectionSummary != nil && cardPlacement != .row ? 0 : 1)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .offset(y: 6))
                )
                .allowsHitTesting(false)
            }

            if failedAggregateRequest != nil {
                VStack {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                            .foregroundStyle(PomoGemTheme.amber)
                            .accessibilityHidden(true)
                        Text("結晶は未保存です", tableName: "Home")
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
        .coordinateSpace(.named(Self.jarCardCoordinateSpace))
    }

    /// The capacity chip hangs 6 pt under the bottle's base, over the 内訳
    /// hint's row when the stage has no room below the bottle.
    private static func capacityChipTopInset(stageHeight: CGFloat) -> CGFloat {
        bottleBaseInset(stageHeight: stageHeight) + 6
    }

    /// The bottle's base, from the top of the jar card: the bottle is centred
    /// in the stage and at most `Constants.Jar.height` tall.
    private static func bottleBaseInset(stageHeight: CGFloat) -> CGFloat {
        let top: CGFloat = previewsHUDAboveJar ? hudAboveJarHeight : 0
        let sceneHeight = max(0, stageHeight - top)
        let outer = JarScene.outerJarRect(sceneSize: CGSize(width: 1, height: sceneHeight))
        return top + sceneHeight - outer.minY
    }

    /// The chip above is showing (the 内訳 hint under the jar steps aside).
    private var showsCapacityChip: Bool {
        capacityRemaining.map { $0 <= 15 } ?? false
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

    /// D5 (owner decision pending, Docs/GemExperienceDesign.md §8.1): a
    /// Simulator-only preview that moves the metric HUD above the jar mouth
    /// so the jar holds only the core and the gems. Requires the in-memory
    /// UI-test launch plus `POMOGEM_UI_TEST_HUD=outside`; never in release.
    private static let previewsHUDAboveJar: Bool = {
#if DEBUG && targetEnvironment(simulator)
        return LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess
            && LocalPreviewLaunchPolicy.persistenceModeForCurrentProcess == .inMemoryPreview
            && ProcessInfo.processInfo.environment["POMOGEM_UI_TEST_HUD"] == "outside"
#else
        return false
#endif
    }()
    private static let hudAboveJarHeight: CGFloat = 104

    private static let jarCardCoordinateSpace = "home.jarCard"

    /// Bottom edge of the metric HUD in the jar stage's own coordinates,
    /// measured from the laid-out HUD (every Dynamic Type size, the cloud
    /// status line and the pre-fusion rail included), so the time core's
    /// orbit is placed below what is actually drawn. Before the first
    /// layout pass it falls back to the HUD's nominal rows: the 39 pt value
    /// (28 pt only for an empty jar at accessibility sizes, home-04) and
    /// the two-line rail (walk-std-10).
    private func jarMetricHUDClearance(_ readout: LifetimeReadoutContinuityPolicy.Readout) -> CGFloat {
        if let measuredHUDBottom = jarStageState.measuredHUDBottom {
            return max(0, measuredHUDBottom - jarStageState.measuredStageTop)
        }
        let valueRow: CGFloat = dynamicTypeSize.isAccessibilitySize && readout.jarIsEmpty ? 36 : 47
        let rail: CGFloat = showsPreFusionRail(readout) ? 52 : 0
        return 88 + 15 + 3 + valueRow + 3 + 24 + rail
    }

    /// The bottle is at most `Constants.Jar.height` tall and centred in a
    /// taller stage (accessibility sizes, large phones); the HUD follows its
    /// mouth instead of the stage top, so it never meets the neck or the
    /// 「瓶N杯」 pill.
    static func jarMetricHUDTopInset(stageHeight: CGFloat) -> CGFloat {
        let outer = JarScene.outerJarRect(sceneSize: CGSize(width: 1, height: stageHeight))
        return 88 + max(0, stageHeight - outer.maxY)
    }

    private func jarMetricHUD(
        stageHeight: CGFloat,
        readout: LifetimeReadoutContinuityPolicy.Readout,
        stage: JarStageSnapshot
    ) -> some View {
        // At accessibility sizes the jar can be as short as 300 pt (the
        // pinned start button takes the rest, home-03). There the one-time
        // hint sits closer to the readout and is capped lower, and at
        // accessibility sizes it is one short line (`jarInteractionHint`),
        // so it still ends above the first gem resting on the floor.
        let isShortJar = stageHeight < 380
        return VStack(spacing: isShortJar ? 8 : 14) {
            jarMetricReadout(readout, stage)
            if readout.jarIsEmpty, showsEmptyJarMessageUnderReadout(readout) {
                accessibilitySizeEmptyJarMessage
            }
            // The one-time hint hangs under the readout, in the jar's empty
            // middle. On the floor it covered the first gem — the very
            // pebble it asks people to tap.
            if stage.aggregateInspectionSummary == nil, showsTiltHint, !readout.jarIsEmpty, !readout.isLoading {
                jarInteractionHint(compact: isShortJar && dynamicTypeSize.isAccessibilitySize)
                    .dynamicTypeSize(...(isShortJar ? DynamicTypeSize.xLarge : .xxxLarge))
                    // A short settle, not a slide from the edge: sliding in
                    // from above would pass over the readout.
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .offset(y: -8))
                    )
            }
        }
        // Keep every glyph behind the mouth instead of straddling its bright
        // rim; the occlusion cue is what makes the glass depth believable.
        .padding(.top, Self.previewsHUDAboveJar ? 0 : Self.jarMetricHUDTopInset(stageHeight: stageHeight))
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    /// `compact`: a short jar at accessibility sizes. The hint is then one
    /// line at the default text size. Since #47 a young jar's first gem is
    /// about 57 pt across, and on an iPhone SE at AX5 the two-line hint
    /// covered its top. The tilt half of the tip is left to the jar's
    /// VoiceOver hint there; the tap is the one people need first.
    private func jarInteractionHint(compact: Bool) -> some View {
        Label(
            compact ? jarInteractionShortHintText : jarInteractionHintText,
            systemImage: jarInteractionHintSymbol
        )
            .font(.caption.weight(.bold))
            // Like the readout above it, the hint lives inside the jar's
            // fixed canvas. At accessibility sizes it grew past the jar and
            // back over the gem; VoiceOver reads the same guidance from the
            // jar itself.
            .dynamicTypeSize(...(compact ? DynamicTypeSize.large : .xxxLarge))
            .foregroundStyle(PomoGemTheme.text)
            .multilineTextAlignment(.center)
            .lineLimit(compact ? 1 : nil)
            .minimumScaleFactor(compact ? 0.85 : 1)
            .padding(.horizontal, 13)
            .padding(.vertical, compact ? 7 : 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().stroke(PomoGemTheme.glassEdge.opacity(0.2), lineWidth: 1)
            }
            .padding(.horizontal, 24)
            // `JarSpriteView` exposes the same guidance as a persistent
            // accessibility hint. Keep this transient visual hint out of
            // the VoiceOver order so it is not spoken twice.
            .accessibilityHidden(true)
#if DEBUG
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                HomeRenderDiagnostics.jarHintWindowFrame = $0
            }
            .onDisappear { HomeRenderDiagnostics.jarHintWindowFrame = nil }
#endif
    }

    private func jarMetricReadout(
        _ readout: LifetimeReadoutContinuityPolicy.Readout,
        _ stage: JarStageSnapshot
    ) -> some View {
        // Before this Home's first settled readout the rows keep their place
        // but show nothing: no 「再集計中」, no 0粒 (device-verify-2 P2).
        let lifetimeGrams = readout.isLoading ? 0 : readout.jarGrams
        return VStack(spacing: 3) {
            Text("積み上げた集中")
                // This HUD is excluded from VoiceOver; the jar's accessibility
                // value carries the same information. Its captions follow
                // Dynamic Type up to the readout's xxxLarge cap below, so they
                // grow with the user's size but stay inside the jar's canvas;
                // at accessibility sizes the scrollable card under the jar
                // repeats the progress in full-size text (home-04).
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .tracking(1.1)
                .textCase(.uppercase)
                .foregroundStyle(Color.white.opacity(0.74))

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(homeMassValue(lifetimeGrams))
                    // Never smaller for a larger text size: the 28 pt value
                    // only makes room for the empty jar's message.
                    .font(.system(size: dynamicTypeSize.isAccessibilitySize && readout.jarIsEmpty ? 28 : 39, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(homeMassUnit(lifetimeGrams, readout: readout))
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.76))
            }

            VStack(spacing: 4) {
                jarMetricPill(jarMetricSummary(readout, stage: stage))
                // sync-03. While iCloud is checked the mass above is one this
                // device can stand behind (`PendingMassPresentationPolicy`);
                // the caption says so. Hidden while the in-jar pending message
                // says the same.
                if !readout.jarIsEmpty, let caption = AggregateProjectionPresentationPolicy.verificationCaption(
                    context: presentationContext(for: readout),
                    isCloudOfflineSession: isCloudOfflineSession
                ) {
                    // The only visible qualifier of the number above: readable
                    // at 11 pt and scaled with Dynamic Type up to the HUD's
                    // xxxLarge cap (a fixed 9 pt caption was too small).
                    Text(caption)
                        .font(.system(size: verificationCaptionSize, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.78))
                        .accessibilityIdentifier("home.mass.verification-caption")
                }
                if showsPreFusionRail(readout) {
                    preFusionRail(readout)
                }
            }
        }
        .opacity(readout.isLoading ? 0 : 1)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        // Only the readout counts: the one-time hint below it is transient,
        // and the core must not move when it comes and goes.
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.frame(in: .named(Self.jarCardCoordinateSpace)).maxY
        } action: { bottom in
            jarStageState.measuredHUDBottom = bottom
        }
#if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            HomeRenderDiagnostics.jarHUDWindowFrame = $0
        }
#endif
        .shadow(color: .black.opacity(0.52), radius: 3, y: 1)
        // A soft ink scrim keeps the value legible over the brighter core,
        // orbit markers and glowing gems behind the glass. The text shadow
        // is applied first, so the blurred scrim is not shadowed again.
        .background {
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [Color.black.opacity(0.34), Color.black.opacity(0.14), .clear],
                        center: .center,
                        startRadius: 4,
                        endRadius: 120
                    )
                )
                .frame(width: 250, height: 150)
                .blur(radius: 8)
        }
        .accessibilityHidden(true)
    }

    private var verificationCaptionSize: CGFloat {
        let scale: CGFloat = switch dynamicTypeSize {
        case .xSmall, .small, .medium, .large: 1
        case .xLarge: 1.1
        case .xxLarge: 1.2
        default: 1.3
        }
        return 11 * scale
    }

    private func homeMassValue(_ lifetimeGrams: Int?) -> String {
        guard let grams = lifetimeGrams else {
            return AggregateProjectionPresentationPolicy.homeMassValue(
                deviceValue: nil,
                context: aggregateProjectionPresentation
            )
        }
        return AggregateProjectionPresentationPolicy.homeMassValue(
            deviceValue: HomeLifetimeMassText.readoutNumber(grams),
            context: aggregateProjectionPresentation
        )
    }

    private func homeMassUnit(
        _ lifetimeGrams: Int?,
        readout: LifetimeReadoutContinuityPolicy.Readout
    ) -> String {
        guard let grams = lifetimeGrams else { return "" }
        return AggregateProjectionPresentationPolicy.homeMassUnit(
            verifiedUnit: grams < 1_000 ? "g" : "kg",
            hasLocalLowerBound: readout.isLowerBound,
            context: presentationContext(for: readout)
        )
    }

    private func jarMetricSummary(
        _ readout: LifetimeReadoutContinuityPolicy.Readout,
        stage: JarStageSnapshot
    ) -> String {
        let milestones = stage.uniqueAchievementCount > 0
            ? " ・ 記念石 \(achievementCountLabel(stage.uniqueAchievementCount))"
            : ""
        return AggregateProjectionPresentationPolicy.homeCountSummary(
            count: readout.jarPebbles,
            milestoneSuffix: milestones,
            hasLocalLowerBound: readout.isLowerBound,
            context: presentationContext(for: readout)
        )
    }

    /// The lifetime mass the menu presents, qualified like the headline; nil
    /// while pending with nothing this device can stand behind.
    private func presentedLifetimeMassLabel(_ readout: LifetimeReadoutContinuityPolicy.Readout) -> String? {
        readout.menuGrams.map {
            formattedMass($0) + (readout.isLowerBound ? "以上" : "")
        }
    }

    private func homeMenuMassValue(_ readout: LifetimeReadoutContinuityPolicy.Readout) -> String {
        guard !readout.isLoading else { return "—" }
        return AggregateProjectionPresentationPolicy.menuMassValue(
            formattedMass: presentedLifetimeMassLabel(readout),
            context: presentationContext(for: readout)
        )
    }

    /// home-07: the planning sheet continues from the lifetime mass this
    /// screen presents, qualified the same way: 「以上」 for a lower bound,
    /// still being checked while iCloud is verified, and no mass at all only
    /// when Home itself shows 「再集計中」.
    private var accumulationPlanStart: AccumulationPlanStart {
        let readout = presentedLifetimeReadout()
        return .homeHeadline(
            presentedGrams: readout.menuGrams,
            isLowerBound: readout.isLowerBound,
            isBeingChecked: readout.isCloudVerificationPending
        )
    }

    private func homeMenuCountValue(_ readout: LifetimeReadoutContinuityPolicy.Readout) -> String {
        guard !readout.isLoading else { return "—" }
        guard readout.isCloudVerificationPending else {
            return "\(readout.menuPebbles)粒"
        }
        // 「再集計中」 beside a bare device count would read as the total.
        return readout.menuGrams == nil
            ? "確認済み \(readout.menuPebbles)粒"
            : "\(readout.menuPebbles)粒"
    }

    /// Says what the strip shows, held readouts included.
    private func homeMenuAccessibilitySummary(_ readout: LifetimeReadoutContinuityPolicy.Readout) -> String {
        if readout.isLoading {
            return String(localized: "これまでの記録を読み込み中。記念石\(achievementCountLabel)個",
                          table: "Home",
                          comment: "VoiceOver, menu metrics before Home has read its records: achievement stone count")
        }
        let mass = presentedLifetimeMassLabel(readout)
        if readout.isCloudVerificationPending {
            guard let mass else {
                return String(localized: "\(projectionVerificationTitle)。累計は確認が済むと表示します。この端末で確認済みの集中\(readout.menuPebbles)粒、記念石\(achievementCountLabel)個",
                              table: "Home",
                              comment: "VoiceOver, menu metrics while iCloud is checked and no lifetime total can be shown: status, focus count, achievement stone count")
            }
            return String(localized: "\(projectionVerificationTitle)。累計\(mass)、集中\(readout.menuPebbles)粒、記念石\(achievementCountLabel)個",
                          table: "Home",
                          comment: "VoiceOver, menu metrics while iCloud is checked: status, lifetime mass, focus count, achievement stone count")
        }
        return String(
            localized: "累計\(mass ?? formattedMass(0))、集中\(readout.menuPebbles)粒、記念石\(achievementCountLabel)個",
            table: "Home",
            comment: "VoiceOver, menu metrics: lifetime mass, focus count, achievement stone count"
        )
    }

    private var projectionVerificationTitle: String {
        isCloudOfflineSession ? "このiPhoneの集計を確認中" : "iCloudを確認中"
    }

    /// The small rail inside the jar. At accessibility sizes the card under
    /// the jar shows the same progress in full-size text instead.
    /// Only for an exact, verified readout: its landed totals
    /// (`fusionProgressTotals`), held with the headline while Home re-reads.
    private func showsPreFusionRail(_ readout: LifetimeReadoutContinuityPolicy.Readout) -> Bool {
        guard let totals = readout.fusionProgressTotals else { return false }
        return !readout.isLowerBound
            && !dynamicTypeSize.isAccessibilitySize
            && totals.pebbleCount > 0
            && !JarLifetimeCorePresentation.shouldShowCore(
                totalPebbleCount: totals.pebbleCount,
                totalGrams: totals.grams
            )
    }

    /// Names what 「4時間10分」 leads to (walk-std-10): without a name the
    /// target read like a daily quota. The explanation of 標準単位 and 10→1
    /// lives in 積み上がり, not in the jar.
    private func preFusionRail(_ readout: LifetimeReadoutContinuityPolicy.Readout) -> some View {
        let state = EffortProgressPolicy.snapshot(totalGrams: readout.fusionProgressTotals?.grams ?? 0)
        return VStack(spacing: 4) {
            ProgressView(value: state.progressFraction)
                .tint(Color(hex: readout.coreColorHex))
                .frame(width: 118)
            Text(
                "\(EffortProgressPresentation.targetTitle(level: state.displayedTargetLevel))まで",
                tableName: "Home",
                comment: "Jar rail caption; the argument is 最初の時間の核 or 時間の核・N段目"
            )
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.78))
            Text(
                "\(EffortProgressPresentation.formattedDuration(grams: state.displayedProgressGrams)) / \(EffortProgressPresentation.formattedDuration(grams: state.displayedTargetGrams))",
                tableName: "Home",
                comment: "Jar rail: focus time so far / time the next time core needs"
            )
                .font(.system(.caption2, design: .rounded, weight: .black))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.92))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(PomoGemTheme.raised.opacity(0.72), in: Capsule())
        .overlay {
            Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.7)
        }
        .accessibilityHidden(true)
    }

    /// The time core's progress for the jar's VoiceOver value, from the same
    /// snapshot as its headline (`fusionProgressTotals`).
    private func fusionAccessibilityDescription(_ readout: LifetimeReadoutContinuityPolicy.Readout) -> String? {
        guard let totals = readout.fusionProgressTotals,
              totals.pebbleCount > 0 || readout.isLowerBound
        else { return nil }
        guard let state = JarLifetimeCorePresentation.state(
            totalPebbleCount: totals.pebbleCount,
            totalGrams: totals.grams,
            projectionIsLowerBound: readout.isLowerBound
        ) else { return nil }
        var components = [state.progressLabel, state.nextFusionLabel]
            .compactMap { $0 }
        if let physicalState = JarLifetimeCorePresentation.state(
            totalPebbleCount: totals.pebbleCount,
            projectionIsLowerBound: readout.isLowerBound
        ) {
            // The count toward the next crystal, after the time value. It was
            // prefixed 「瓶の物理整理：」, an accounting term.
            components.append(contentsOf: [physicalState.progressLabel, physicalState.nextFusionLabel]
                .compactMap { $0 })
        }
        let filledJarCount = JarAccumulationPresencePresentation
            .state(totalGrams: totals.grams).completedCycleCount
        if filledJarCount > 0 {
            // The 「瓶N杯」 chip behind the glass is hidden from VoiceOver.
            components.append(String(
                localized: "瓶\(filledJarCount)杯ぶん満ちました",
                table: "Home",
                comment: "VoiceOver, jar value: how many times the jar has filled (2.5 kg each)"
            ))
        }
        return components.joined(separator: "、")
    }

    /// The documented large-text companion of the jar's fixed HUD
    /// (EngagementArchitecture 大きい文字). It used to wait for the first
    /// time core (2.5 kg), so the first ~10 focuses, when the rail is the only
    /// progress on Home, had no readable version at accessibility sizes.
    ///
    /// Home places the card's reader from its own pass: a landing changes a
    /// readout's count, never whether it is verified or loaded.
    private func showsLargeTextFusionProgress(_ readout: LifetimeReadoutContinuityPolicy.Readout) -> Bool {
        dynamicTypeSize.isAccessibilitySize && readout.fusionProgressTotals != nil
    }

    private func largeTextFusionProgressState(
        _ readout: LifetimeReadoutContinuityPolicy.Readout
    ) -> JarLifetimeCoreState? {
        guard dynamicTypeSize.isAccessibilitySize,
              let totals = readout.fusionProgressTotals,
              totals.pebbleCount > 0
        else { return nil }
        return JarLifetimeCorePresentation.state(
            totalPebbleCount: totals.pebbleCount,
            totalGrams: totals.grams,
            projectionIsLowerBound: readout.isLowerBound
        )
    }

    /// Runs inside `JarStageReader`, so its colour comes from the readout
    /// Home resolved on its own pass, not from Home's projections, which
    /// re-derive the sessions on each read.
    private func largeTextFusionProgressCard(
        _ state: JarLifetimeCoreState,
        colorHex: String
    ) -> some View {
        PomoGemCard {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "hourglass.bottomhalf.filled")
                    .font(.title2.weight(.black))
                    .foregroundStyle(Color(hex: colorHex))
                    .frame(width: 44, height: 44)
                    .background(
                        Color(hex: colorHex).opacity(0.13),
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
            // Scales with the readout's Dynamic Type cap instead of a fixed
            // 11 pt that could shrink to 8 pt.
            .font(.system(.caption2, design: .rounded, weight: .semibold))
            .foregroundStyle(PomoGemTheme.text.opacity(0.9))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(PomoGemTheme.raised.opacity(0.72), in: Capsule())
            .overlay {
                Capsule().stroke(PomoGemTheme.glassEdge.opacity(0.15), lineWidth: 1)
            }
    }

    private var achievementCountLabel: String {
        achievementCountLabel(uniqueAchievementCount)
    }

    private func achievementCountLabel(_ count: Int) -> String {
        "\(count)\(achievementCountIsLowerBound ? "+" : "")"
    }

    @ViewBuilder
    private func emptyJarMessage(_ readout: LifetimeReadoutContinuityPolicy.Readout) -> some View {
        if readout.isCloudVerificationPending {
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
            // sync-03. The bottle is a fixed canvas and its readout above now
            // stays visible while iCloud is checked; at accessibility sizes
            // this message grew over it. VoiceOver reads the label below.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(projectionVerificationTitle)。この端末で確認できた記録だけを表示しています"
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

    /// At accessibility sizes the empty jar's message hangs under the
    /// readout instead of being centred in the jar. The jar now shrinks to
    /// what the pinned start button leaves (home-03, as little as 300 pt),
    /// and centred there the message covered 「0g」 and ran off the jar's
    /// lower edge on an iPhone SE.
    private func showsEmptyJarMessageUnderReadout(_ readout: LifetimeReadoutContinuityPolicy.Readout) -> Bool {
        dynamicTypeSize.isAccessibilitySize
            && !readout.isCloudVerificationPending
    }

    /// The bottle is a fixed visual canvas. At accessibility text sizes its
    /// message stays short, and the start button it points to is pinned
    /// below in full-size text. Like the readout above, the message is
    /// capped (here at the first accessibility size) so it fits the room
    /// left under the readout in the shortest jar; VoiceOver reads the
    /// label below.
    private var accessibilitySizeEmptyJarMessage: some View {
        VStack(spacing: 6) {
            Text("まだ空っぽ", tableName: "Home", comment: "Empty jar at accessibility text sizes: title")
                .font(.title3.weight(.bold))
            Label {
                Text("下のボタンへ", tableName: "Home", comment: "Empty jar at accessibility text sizes: points to the start button below")
            } icon: {
                Image(systemName: "arrow.down")
                    .accessibilityHidden(true)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(PomoGemTheme.amber)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .multilineTextAlignment(.center)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            selectedSubject == nil
                ? String(localized: "瓶はまだ空です。下のボタンからテーマを追加できます", table: "Home",
                         comment: "VoiceOver, empty jar at accessibility text sizes, no theme yet")
                : String(localized: "瓶はまだ空です。下のボタンから最初の集中を始められます", table: "Home",
                         comment: "VoiceOver, empty jar at accessibility text sizes")
        )
    }

    private func homeJarHeight(availableHeight: CGFloat) -> CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            // home-03. The launcher sits below the scroll view
            // (`pinnedFocusLauncher`), so this height already excludes it.
            // Leave the top of the theme picker in view so the scrollable
            // controls are discoverable; 300 pt still holds the HUD and the
            // short empty message without overlap.
            return min(520, max(300, availableHeight - 72))
        }
        // Reserve room for the visible theme/time controls and start button,
        // including on compact iPhones, and for the crystal tip's row while
        // it shows. A tapped crystal's card never resizes the jar.
        let tipRowHeight: CGFloat = showsAggregateTipRow ? 72 : 0
        return min(520, max(320, availableHeight - 216 - tipRowHeight))
    }

    /// home-11. Until the first crystal detail has been opened, the row
    /// under the jar holds a tip that crystals can be tapped, and a tapped
    /// crystal's card in its place. Afterwards the tip's 72 pt row goes away
    /// and the jar keeps its full height.
    private var showsAggregateTipRow: Bool {
        latestInspectableAggregateID != nil && !didSeeAggregateDetail
    }

    /// The row under the jar: the tip's, or a tapped crystal's card that
    /// `AggregateCardPlacementPolicy` puts in a row of its own. That row is
    /// inserted only while the card is up (`followAggregateInspectionCard`).
    private func showsAggregateInspectionSlot(
        _ placement: AggregateCardPlacementPolicy.Placement
    ) -> Bool {
        showsAggregateTipRow
            || (placement == .row
                && latestInspectableAggregateID != nil
                && aggregateInspectionSummary != nil)
    }

    /// Where a tapped crystal's card shows over a jar `jarHeight` tall. The
    /// tip's row holds it while that row is there.
    private func aggregateCardPlacement(
        jarHeight: CGFloat
    ) -> AggregateCardPlacementPolicy.Placement {
        guard !showsAggregateTipRow else { return .row }
        return AggregateCardPlacementPolicy.placement(
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
            bottleBase: Self.bottleBaseInset(stageHeight: jarHeight),
            cardHeight: measuredAggregateCardHeight ?? AggregateCardPlacementPolicy.estimatedCardHeight,
            // Controls not measured yet count as right under the jar.
            pickerTop: activeSubjects.isEmpty ? nil : (measuredPickerRowTop ?? 0),
            launcherTop: pinsFocusLauncher ? nil : measuredLauncherTop
        )
    }

    /// The controls' tops in the Home content, for the card's room. Not
    /// while the card's own row is inserted: it pushes them down, and
    /// measured then the room would look big enough to take the card back
    /// under the bottle, so the row would come and go.
    private func recordAggregateCardRoom(
        pickerTop: CGFloat? = nil,
        launcherTop: CGFloat? = nil,
        placement: AggregateCardPlacementPolicy.Placement
    ) {
        guard !(placement == .row && !showsAggregateTipRow && aggregateInspectionSummary != nil)
        else { return }
        if let pickerTop { measuredPickerRowTop = pickerTop }
        if let launcherTop { measuredLauncherTop = launcherTop }
    }

    /// home-11 (#50 follow-up). At default sizes, once the tip's row has
    /// gone, a tapped crystal's card hangs under the bottle's base, like the
    /// capacity chip: in the room above the start button, never over the
    /// readout, the time core or the pile, and nothing on the screen moves.
    /// Over the upper jar (#47's lower, mouth-following readout, the time
    /// core under it and a taller pile) it covered the core and the gems.
    /// The card stays laid out, hidden, while a crystal can be tapped, so its
    /// measured height places it before it first shows.
    @ViewBuilder
    private func aggregateCardUnderBottle(
        jarHeight: CGFloat,
        placement: AggregateCardPlacementPolicy.Placement
    ) -> some View {
        if !dynamicTypeSize.isAccessibilitySize, !showsAggregateTipRow,
           let aggregateID = latestInspectableAggregateID,
           let restingSummary = inspectionSummary(for: aggregateID) {
            let isPresented = aggregateInspectionSummary != nil && placement != .row
            aggregateInspectionButton(aggregateInspectionSummary ?? restingSummary)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    measuredAggregateCardHeight = height
                }
                .opacity(isPresented ? 1 : 0)
                .allowsHitTesting(isPresented)
                .accessibilityHidden(!isPresented)
                .frame(maxWidth: .infinity)
                .padding(.top, Self.bottleBaseInset(stageHeight: jarHeight) + AggregateCardPlacementPolicy.gap)
        }
    }

    private static let aggregateInspectionSlotID = "home.aggregate-inspection"
    private static let homeContentCoordinateSpace = "home.content"

    /// When the card is in a row of its own (at accessibility sizes, or at
    /// default sizes on a screen without room above the start button), that
    /// row is under the jar, mostly below the first screen, so a tap brings
    /// the whole card into view. On a 4.7-inch phone that moves the jar up
    /// out of sight, so once the card closes (after six seconds, on another
    /// jar tap or for its detail) Home scrolls back to the jar.
    private func followAggregateInspectionCard(
        from oldID: UUID?,
        to id: UUID?,
        inRow: Bool,
        with scrollProxy: ScrollViewProxy
    ) {
        guard dynamicTypeSize.isAccessibilitySize || (inRow && !showsAggregateTipRow) else { return }
        let animation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.3)
        if id != nil {
            // The row is inserted in this same update; scroll once it is
            // laid out.
            DispatchQueue.main.async {
                guard aggregateInspectionID != nil else { return }
                withAnimation(animation) {
                    scrollProxy.scrollTo(Self.aggregateInspectionSlotID, anchor: .bottom)
                }
            }
        } else if oldID != nil {
            withAnimation(animation) {
                scrollProxy.scrollTo("home.jar", anchor: .top)
            }
        }
    }

    /// home-03. At accessibility sizes the start button stays in the first
    /// viewport on every iPhone instead of below a 520 pt jar and two
    /// stacked pickers. The completion card takes this place while it is up
    /// (the button is disabled then anyway).
    private var pinsFocusLauncher: Bool {
        dynamicTypeSize.isAccessibilitySize
            && breakOffer == nil
            && router.deferredFocusRecovery == nil
    }

    private var pinnedFocusLauncher: some View {
        focusLauncher
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .frame(maxWidth: homeContentMaxWidth)
            .frame(maxWidth: .infinity)
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
            Section(purchase.isPro ? "定番の時間" : "無料の集中タイマー") {
                ForEach(PomodoroDuration.freePresets, id: \.self) { duration in
                    homeDurationOption(duration)
                }
            }
            // A preset replaces the preferred duration, so without this a
            // Pro user switching 50分 -> 25分 had to retype 50分 to go back.
            if purchase.isPro, !recentCustomDurations.isEmpty {
                Section("最近のカスタム時間") {
                    ForEach(recentCustomDurations, id: \.self) { duration in
                        homeDurationOption(duration)
                    }
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
            if selectedDuration.seconds == duration.seconds {
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
                // At accessibility sizes the title and subtitle get the full
                // width instead (home-03): with the 48 pt circle they wrapped
                // to four lines and the pinned button grew to ~240 pt.
                if !dynamicTypeSize.isAccessibilitySize {
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
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedSubject == nil ? "テーマを選んではじめる" : "\(focusDurationLabel)、集中する")
                        .font(.system(.title3, design: .rounded, weight: .black))
                        .lineLimit(2)
                    Text(
                        selectedSubject == nil
                            ? "勉強も仕事も、同じ一覧で"
                            : "\(selectedSubject?.safeDisplayName ?? "選択中のテーマ") ・ 完走で\(MassText.addedGrams(selectedDuration.grams))"
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

    private var recentCustomDurations: [PomodoroDuration] {
        RecentCustomFocusDurations.decode(recentCustomFocusSecondsRawValue)
            .map(PomodoroDuration.init(totalSeconds:))
    }

    /// The editor opens at the custom time in use, or else at the most
    /// recent one, not at a preset the user would have to retype over.
    private var customDurationEditorInitialSeconds: Int {
        if selectedDuration.requiresPro { return selectedDuration.seconds }
        return recentCustomDurations.first?.seconds ?? selectedDuration.seconds
    }

    private func rememberCustomDuration(_ duration: PomodoroDuration) {
        let updated = RecentCustomFocusDurations.recording(
            duration.seconds,
            in: recentCustomFocusSecondsRawValue
        )
        if updated != recentCustomFocusSecondsRawValue {
            recentCustomFocusSecondsRawValue = updated
        }
    }

    private var focusDurationLabel: String {
#if DEBUG
        if selectedDuration == .demo { return "12秒" }
#endif
        return selectedDuration.displayLabel
    }

    private var homeMenu: some View {
        Button {
            homeMenuDetent = .medium
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
        .accessibilityHint("記録、設定、手動での追加、背景などを開きます")
    }

    private var homeMenuSheet: some View {
        NavigationStack {
            ScrollViewReader { menuScrollProxy in
            ScrollView {
                // The menu is Home's only way to 記録 and 設定, so the
                // destinations people open it for come first and fit in the
                // half-height sheet even on a 4.7-inch phone. The decorative
                // background picker comes last.
                VStack(spacing: 14) {
                    menuDestinationActions
                    menuAccumulationActions
                    menuAccumulationPlanAction
                    menuAtmospherePicker(scrollProxy: menuScrollProxy)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollBounceBehavior(.basedOnSize)
            }
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

    private func menuAtmospherePicker(scrollProxy: ScrollViewProxy) -> some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        SectionEyebrow(text: String(localized: "背景", table: "Home", comment: "Eyebrow over the menu card 集中する空間 (Home background)"))
                        Text("集中する空間")
                            .pomogemSectionTitle(size: 21)
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
                        atmosphereButton(atmosphere, scrollProxy: scrollProxy)
                            .id(Self.atmosphereScrollID(atmosphere))
                    }
                }
            }
        }
    }

    private static func atmosphereScrollID(_ atmosphere: HomeAtmosphere) -> String {
        "home.menu.atmosphere.\(atmosphere.rawValue)"
    }

    private func atmosphereButton(
        _ atmosphere: HomeAtmosphere,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        let isSelected = homeAtmosphere == atmosphere

        return Button {
            guard homeAtmosphere != atmosphere else { return }
            homeAtmosphereRawValue = atmosphere.rawValue
            if sensoryPreferences.hapticsOn {
                Haptics.shared.playSecondaryCollision()
            }
            revealChosenAtmosphere(atmosphere, scrollProxy: scrollProxy)
        } label: {
            HStack(alignment: .bottom, spacing: 8) {
                Image(systemName: atmosphere.systemImage)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.ultraThinMaterial, in: Circle())

                // Short Japanese names must never break mid-word
                // (「オーロ／ラ」); shrink slightly before wrapping.
                VStack(alignment: .leading, spacing: 1) {
                    Text(atmosphere.title)
                        .font(.system(size: atmosphereTitleFontSize, weight: .bold, design: .rounded))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .minimumScaleFactor(0.8)
                        .accessibilityHidden(true)
                    Text(atmosphere.subtitle)
                        .font(.system(size: atmosphereSubtitleFontSize))
                        .foregroundStyle(.white)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .minimumScaleFactor(0.85)
                        .accessibilityHidden(true)
                }

                Spacer(minLength: 2)
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
            // The badge sits in the empty artwork corner, outside the text
            // row, so selecting a card never narrows or re-wraps its title.
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(PomoGemTheme.amber)
                        .padding(8)
                        .accessibilityHidden(true)
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

    /// The background picker sits last in the menu, so reaching it usually
    /// raises the sheet to full height, over Home. Lower it to half height
    /// and keep the chosen card in view, so the new background shows behind
    /// the sheet the moment it is picked.
    private func revealChosenAtmosphere(
        _ atmosphere: HomeAtmosphere,
        scrollProxy: ScrollViewProxy
    ) {
        guard homeMenuDetent != .medium,
              auxiliarySheetDetents.contains(.medium) else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
            homeMenuDetent = .medium
        }
        Task { @MainActor in
            // Scroll once the sheet has its half-height frame; before that
            // the card is still inside the taller visible area.
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 50 : 360))
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                scrollProxy.scrollTo(Self.atmosphereScrollID(atmosphere), anchor: .center)
            }
        }
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
            // The running totals sit with the two actions that add to them.
            menuMetricsStrip
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
                    detail: String(localized: "勉強アプリ10分ごとに1粒", table: "Home",
                                   comment: "Home menu row detail: every 10 minutes in the chosen study apps adds one pebble"),
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

    private var menuMetricsStrip: some View {
        // The jar's own readout, held or live, derived once for the strip.
        let readout = presentedLifetimeReadout()
        return VStack(spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) {
                    menuMetric(value: homeMenuMassValue(readout), label: "累計")
                    menuMetric(value: homeMenuCountValue(readout), label: "集中")
                    menuMetric(value: "\(achievementCountLabel)個", label: String(localized: "記念石", table: "Home", comment: "Home menu metric caption: achievement stone count"))
                }
            } else {
                HStack(spacing: 0) {
                    menuMetric(value: homeMenuMassValue(readout), label: "累計")
                    Divider().frame(height: 34)
                    menuMetric(value: homeMenuCountValue(readout), label: "集中")
                    Divider().frame(height: 34)
                    menuMetric(value: "\(achievementCountLabel)個", label: String(localized: "記念石", table: "Home", comment: "Home menu metric caption: achievement stone count"))
                }
            }
            // sync-03. The same caption as the jar's headline, instead of a
            // 「確認済み」 prefix that read as a verified lifetime total.
            if let caption = AggregateProjectionPresentationPolicy.verificationCaption(
                context: presentationContext(for: readout),
                isCloudOfflineSession: isCloudOfflineSession
            ) {
                Label(caption, systemImage: isCloudOfflineSession ? "checklist" : "icloud")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PomoGemTheme.muted)
            }
        }
        .padding(.vertical, 12)
        .background(PomoGemTheme.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(homeMenuAccessibilitySummary(readout))
    }

    private var menuDestinationActions: some View {
        VStack(spacing: 2) {
            // The two subtitles name what only that screen holds (history-11):
            // 記録 is where records and 記念石 are read and corrected;
            // 積み上がり is the zoomable view of the jar.
            menuActionButton(
                title: "記録を見る",
                detail: String(localized: "推移・履歴・記念石・月の振り返り", table: "Home", comment: "Home menu row detail: what 記録 holds"),
                symbol: "chart.bar.fill"
            ) {
                showHomeMenu = false
                router.selectedTab = .log
            }
            menuActionButton(
                title: "積み上がりを見る",
                detail: String(localized: "今週・時間の核・結晶・年月の瓶", table: "Home", comment: "Home menu row detail: what 積み上がり holds"),
                symbol: "circle.hexagongrid.fill"
            ) {
                showHomeMenu = false
                overviewInitialClusterID = nil
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    showAccumulationOverview = true
                }
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
            menuActionButton(title: "設定", detail: "テーマ・通知・サウンド・Pro", symbol: "gearshape.fill") {
                showHomeMenu = false
                router.selectedTab = .settings
            }
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
                    // The symbol sits in a fixed 28 pt column so the titles
                    // line up. At accessibility sizes it grew past that
                    // column and the row's rounded clip cut its left side
                    // off (the ▶ and ⚙ glyphs on an iPhone SE at AX5); the
                    // title and detail beside it keep growing.
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)
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

    /// The completion card (Docs/GemExperienceDesign.md §8.3): this focus's
    /// own gem, 「集中を記録しました」, one line with the time first and the
    /// grams second, this week's honest figure, and the mechanics behind
    /// 「しくみ」. [5分休憩] is primary and [閉じる] secondary. At
    /// accessibility sizes the actions come right after the two lines, before
    /// the gem and 「しくみ」, so every safe exit is in the first viewport.
    /// Otherwise the actions stay pinned under a body that, with 「しくみ」
    /// open, scrolls inside the card rather than growing over the HUD.
    private func postDropCard(_ offer: BreakOffer) -> some View {
        let shown = presentedOffer(offer)
        return PomoGemCard {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    postDropHeading(shown)
                    postDropActions(offer)
                    postDropCoreBirthLine(shown)
                    postDropAwaitingDropNote(offer)
                    HStack(alignment: .center, spacing: 12) {
                        CompletionCardHero(
                            sessionID: offer.id,
                            colorHex: offer.heroColorHex(for: rareRewardMode)
                        )
                        .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 5) {
                            postDropWeekLine(shown)
                            postDropRareLine(shown)
                        }
                    }
                    postDropReminderOffer(shown)
                    postDropMechanics(offer)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    postDropScrollingBody(offer, shown: shown)
                    postDropActions(offer)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reward.bridge")
    }

    private static let postDropMechanicsScrollID = "reward.mechanics.scroll"

    /// Everything above the actions. Collapsed, it takes its own height, as
    /// before. With 「しくみ」 open it may grow only until the card's top (and
    /// its 30 pt fade) would reach the jar's HUD; past that the body scrolls,
    /// and it scrolls to the opened mechanics. It never shrinks below its
    /// collapsed height, so a card that already fills the room keeps its
    /// size and scrolls.
    private func postDropScrollingBody(_ offer: BreakOffer, shown: BreakOffer) -> some View {
        let limit = postDropBodyLimit
        return ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 14) {
                        CompletionCardHero(
                            sessionID: offer.id,
                            colorHex: offer.heroColorHex(for: rareRewardMode)
                        )
                        .frame(width: 96, height: 96)
                        VStack(alignment: .leading, spacing: 5) {
                            postDropHeading(shown)
                            postDropWeekLine(shown)
                            postDropRareLine(shown)
                        }
                        .layoutPriority(1)
                    }
                    postDropCoreBirthLine(shown)
                    postDropAwaitingDropNote(offer)
                    postDropReminderOffer(shown)
                    postDropMechanics(offer)
                        .id(Self.postDropMechanicsScrollID)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    postDropBodyNaturalHeight = height
                    if !postDropMechanicsExpanded {
                        postDropCollapsedBodyHeight = height
                    }
                }
            }
            .scrollDisabled(limit == nil)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(limit == nil ? .hidden : .automatic)
            .frame(height: limit)
            .fixedSize(horizontal: false, vertical: limit == nil)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                postDropBodyVisibleHeight = $0
            }
            .onChange(of: limit) { _, newLimit in
                guard newLimit != nil, postDropMechanicsExpanded else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                    reader.scrollTo(Self.postDropMechanicsScrollID, anchor: .bottom)
                }
            }
        }
    }

    /// The body's height while 「しくみ」 is open and the body would reach
    /// the HUD; nil sizes it to its content.
    private var postDropBodyLimit: CGFloat? {
        guard !dynamicTypeSize.isAccessibilitySize,
              postDropMechanicsExpanded,
              homeViewportHeight > 0,
              postDropBodyNaturalHeight > 0
        else { return nil }
        // The actions, the card's padding and anything else in the inset.
        let chrome = max(0, postDropInsetHeight - postDropBodyVisibleHeight)
        // The HUD's bottom in the viewport: the jar card starts 8 pt down.
        // The measured geometry lives in `jarStageState` (device-verify-2
        // P4); reading it here subscribes Home to it only while 「しくみ」 is
        // open. Before the HUD's first layout, estimate it as the stage does.
        let hudBottom = 8 + (jarStageState.measuredHUDBottom ?? {
            let readout = jarStageSnapshot.presentedReadout(with: jarStageState)
            return jarStageState.measuredStageTop + jarMetricHUDClearance(readout)
        }())
        // The card's 30 pt top fade and a little air stay clear of it.
        let room = (homeViewportHeight - hudBottom - 34 - chrome).rounded(.down)
        let limit = max(postDropCollapsedBodyHeight, room)
        return postDropBodyNaturalHeight > limit + 0.5 ? limit : nil
    }

    @ViewBuilder
    private func postDropAwaitingDropNote(_ offer: BreakOffer) -> some View {
        if offer.isAwaitingDrop {
            Text("閉じると、一粒が瓶に落ちます。")
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
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
            // The primary break is as wide as 閉じる. The share button comes
            // last and only once it is offered: a reserved slot left a blank
            // gap between the two exits, and inserting it between them later
            // would move 閉じる under a finger.
            VStack(spacing: 8) {
                startBreakButton(offer, fillsWidth: true)
                dismissBreakOfferButton(offer, showsText: true)
                if showShareChip {
                    postDropShareButton
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
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

    /// 「集中を記録しました」 and the one main line, time first and grams
    /// second (「英語 25分 → +250gの一粒」). VoiceOver reads the same two
    /// lines, this week's figure, a rare or multi-draw outcome and the break
    /// that is available.
    private func postDropHeading(_ offer: BreakOffer) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // The "you did it" beat, in the lamp's amber; the main line
            // below stays the largest text.
            Text("集中を記録しました", tableName: "Home",
                 comment: "Completion card headline, shown after every finished focus. en: 'Focus recorded'")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(PomoGemTheme.amber)
                .fixedSize(horizontal: false, vertical: true)
            Text(CompletionCardPresentation.mainLine(subjectName: offer.subjectName, grams: offer.grams))
                .font(.system(.title3, design: .rounded, weight: .black))
                .foregroundStyle(PomoGemTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("reward.heading")
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(Text("集中を記録しました", tableName: "Home",
                                 comment: "Completion card headline, shown after every finished focus. en: 'Focus recorded'"))
        .accessibilityValue(SentenceText.join([
            CompletionCardPresentation.spokenMainLine(subjectName: offer.subjectName, grams: offer.grams),
            offer.weeklySpokenTitle,
            CompletionCardPresentation.spokenRareLine(kind: offer.kind, counts: offer.rareRewardCounts),
            CompletionCardPresentation.spokenBreakAvailability(minutes: offer.minutes)
        ].compactMap { $0 }))
        .accessibilityHint(
            showShareChip
                ? String(localized: "休憩、共有、または閉じるを選べます。しくみで時間の核と結晶の進みを確認できます", table: "Home",
                         comment: "VoiceOver hint on the completion card heading while the share button shows")
                : String(localized: "休憩または閉じるを選べます。しくみで時間の核と結晶の進みを確認できます", table: "Home",
                         comment: "VoiceOver hint on the completion card heading")
        )
    }

    /// walk-std-07. 「今週の実測 1時間15分」, with 「・自己申告 30分」 in the same
    /// sentence when the week has self-reported focus: the calendar week and
    /// query that Overview and 記録 use (`WeeklyProgressPolicy.week`).
    @ViewBuilder
    private func postDropWeekLine(_ offer: BreakOffer) -> some View {
        if let line = offer.weeklyTitle {
            Text(line)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PomoGemTheme.muted)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("reward.week")
                // The heading already reads it.
                .accessibilityHidden(true)
        }
    }

    /// A gold or rainbow gem, or a focus long enough for more than one
    /// 250 g draw, said in words (quiet mode paints the theme colour, and
    /// VoiceOver cannot see a colour). Nothing for an ordinary single gem.
    @ViewBuilder
    private func postDropRareLine(_ offer: BreakOffer) -> some View {
        if let line = CompletionCardPresentation.rareLine(kind: offer.kind, counts: offer.rareRewardCounts) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if offer.kind != .normal, rareRewardMode.usesEnhancedPresentation {
                    Image(systemName: "sparkles")
                        .foregroundStyle(
                            offer.kind == .gold
                                ? Color(hex: Constants.Color.pebbleGold)
                                : Color(hex: Constants.Color.auroraViolet)
                        )
                }
                Text(line)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("reward.rare")
            // The heading reads it.
            .accessibilityHidden(true)
        }
    }

    /// product-05. The time core arrived with this focus but not with the
    /// first ×10 (a 50-minute fifth gem, a 15-minute seventeenth): the card
    /// says it once, on its face. When the two coincide the fusion sheet
    /// says it instead (`CompletionCardPresentation.coreBirthMoment`).
    @ViewBuilder
    private func postDropCoreBirthLine(_ offer: BreakOffer) -> some View {
        if CompletionCardPresentation.coreBirthMoment(
            effortProgress: offer.effortProgress,
            fusionState: offer.fusionState,
            projectionIsLowerBound: offer.projectionIsLowerBound
        ) == .card {
            Text(CompletionCardPresentation.coreBirthOnCard)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PomoGemTheme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Color(hex: offer.colorHex).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(hex: offer.colorHex).opacity(0.26), lineWidth: 0.8)
                }
                .accessibilityIdentifier("reward.core-birth")
        }
    }

    /// The daily reminder or 先月の瓶のお知らせ is on: the person has already
    /// chosen a notification time, which both share.
    private var reminderTimeIsChosen: Bool {
        (resolvedPreferences?.reminderEnabled ?? false) || wrappedNotifications
    }

    /// D18. Only on the very first completion, and only while no reminder
    /// time has been chosen: one quiet, dismissible row. A tap writes the
    /// existing daily reminder (at this completion's local time) and asks
    /// for notification permission only then; when iOS has already said no
    /// it points to Settings instead of asking. It never turns anything on
    /// by itself and says nothing about streaks.
    @ViewBuilder
    private func postDropReminderOffer(_ offer: BreakOffer) -> some View {
        let time = CompletionCardPresentation.reminderTimeLabel(offer.createdAt)
        let recorded = reminderOffer?.offerID == offer.id ? reminderOffer?.phase : nil
        let offered = CompletionCardPresentation.offersReminder(
            fusionState: offer.fusionState,
            projectionIsLowerBound: offer.projectionIsLowerBound,
            reminderTimeIsChosen: reminderTimeIsChosen
        ) && dismissedReminderOfferID != offer.id.uuidString
        let phase: CompletionReminderOffer.Phase? = switch recorded {
        case nil, .offered?: offered ? .offered : nil
        case .dismissed?: nil
        case let other?: other
        }
        if let phase {
            reminderOfferRow(offer, phase: phase, time: time)
                .padding(.leading, 11)
                .padding(.trailing, 2)
                .background(PomoGemTheme.raised.opacity(0.62), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder
    private func reminderOfferRow(
        _ offer: BreakOffer,
        phase: CompletionReminderOffer.Phase,
        time: String
    ) -> some View {
        switch phase {
        case .offered, .working:
            HStack(alignment: .center, spacing: 6) {
                Button {
                    acceptReminderOffer(offer)
                } label: {
                    reminderOfferLabel(phase: phase, time: time)
                }
                .buttonStyle(PomoGemBareButtonStyle())
                .disabled(phase == .working)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("明日もこの時間に？", tableName: "Home",
                                         comment: "First completion card: optional offer of a daily reminder at this time. en: 'Same time tomorrow?'"))
                .accessibilityValue(CompletionCardPresentation.spokenReminderOfferDetail(time: time))
                .accessibilityHint(Text("タップすると、毎日のリマインダーをこの時刻でオンにします。通知の許可を求めることがあります", tableName: "Home",
                                        comment: "VoiceOver hint on the first completion card's reminder offer"))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("reward.reminder-offer")
                reminderOfferDismissButton(offer)
            }
        case .scheduled:
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PomoGemTheme.amber)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("オンにしました", tableName: "Home",
                         comment: "First completion card: the daily reminder was just turned on. en: 'Turned on'")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PomoGemTheme.text)
                    Text(CompletionCardPresentation.reminderScheduled(time: time))
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.trailing, 9)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("reward.reminder-offer.scheduled")
        case .needsSettings:
            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(CompletionCardPresentation.reminderNeedsPermission)
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(String(localized: "設定を開く", table: "Home",
                                  comment: "Opens the iOS notification settings for PomoGem. en: 'Open Settings'")) {
                        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                    .buttonStyle(PomoGemCompactButtonStyle(
                        tint: PomoGemTheme.text,
                        foreground: PomoGemTheme.background,
                        isProminent: false
                    ))
                    .accessibilityIdentifier("reward.reminder-offer.settings")
                }
                .padding(.vertical, 10)
                reminderOfferDismissButton(offer)
            }
            // Back from Settings with notifications allowed, the offer is
            // there again; the person taps it once more (nothing is turned
            // on for them).
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                reofferReminderIfAllowed(offer)
            }
        case .alreadyOn, .scheduleFailed, .failed:
            HStack(alignment: .center, spacing: 6) {
                Text(CompletionCardPresentation.reminderOutcome(phase))
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.vertical, 6)
                reminderOfferDismissButton(offer)
            }
            .accessibilityIdentifier("reward.reminder-offer.outcome")
        case .dismissed:
            EmptyView()
        }
    }

    /// 「明日もこの時間に？」 over 「毎日 10:22 のリマインダー」, with a
    /// trailing 「オンにする」 so the row reads as a choice, not as a
    /// reminder already set. At accessibility sizes the pill goes below.
    private func reminderOfferLabel(phase: CompletionReminderOffer.Phase, time: String) -> some View {
        let texts = VStack(alignment: .leading, spacing: 1) {
            Text("明日もこの時間に？", tableName: "Home",
                 comment: "First completion card: optional offer of a daily reminder at this time. en: 'Same time tomorrow?'")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PomoGemTheme.text)
            Text(CompletionCardPresentation.reminderOfferDetail(time: time))
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .monospacedDigit()
        }
        .fixedSize(horizontal: false, vertical: true)
        let pill = Group {
            if phase == .working {
                ProgressView()
                    .controlSize(.small)
                    .tint(PomoGemTheme.amber)
                    .frame(minWidth: 44)
            } else {
                Text("オンにする", tableName: "Home",
                     comment: "First completion card: the pill that turns the offered daily reminder on. en: 'Turn on'")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PomoGemTheme.background)
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .frame(minHeight: 30)
                    .background(PomoGemTheme.amber, in: Capsule())
            }
        }
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    texts
                    pill
                }
                .padding(.vertical, 10)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "bell")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PomoGemTheme.amber)
                        .accessibilityHidden(true)
                    texts
                    Spacer(minLength: 0)
                    pill
                }
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func reminderOfferDismissButton(_ offer: BreakOffer) -> some View {
        Button {
            reminderOffer = .init(offerID: offer.id, phase: .dismissed)
            dismissedReminderOfferID = offer.id.uuidString
        } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(PomoGemTheme.muted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PomoGemBareButtonStyle())
        .accessibilityLabel(Text("リマインダーの提案を閉じる", tableName: "Home",
                                 comment: "VoiceOver: dismisses the first completion card's reminder offer"))
        .accessibilityIdentifier("reward.reminder-offer.dismiss")
    }

    private func reofferReminderIfAllowed(_ offer: BreakOffer) {
        Task { @MainActor in
            let status = await NotificationManager.shared.refreshAuthorizationStatus()
            guard reminderOffer?.offerID == offer.id,
                  reminderOffer?.phase == .needsSettings
            else { return }
            switch status {
            case .authorized, .provisional, .ephemeral:
                reminderOffer = .init(offerID: offer.id, phase: .offered)
            default:
                break
            }
        }
    }

    private func acceptReminderOffer(_ offer: BreakOffer) {
        guard reminderOffer?.offerID != offer.id || reminderOffer?.phase == .offered else { return }
        // Turned on meanwhile (Settings, another device): leave its time.
        guard !reminderTimeIsChosen else {
            reminderOffer = .init(offerID: offer.id, phase: .alreadyOn)
            return
        }
        reminderOffer = .init(offerID: offer.id, phase: .working)
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: offer.createdAt)
        let hour = components.hour ?? Constants.Notification.defaultReminderHour
        let minute = components.minute ?? Constants.Notification.defaultReminderMinute
        Task { @MainActor in
            let manager = NotificationManager.shared
            let status = await manager.refreshAuthorizationStatus()
            guard reminderOffer?.offerID == offer.id else { return }
            switch status {
            case .denied:
                // Asked before: iOS will not ask again, so point to Settings.
                reminderOffer = .init(offerID: offer.id, phase: .needsSettings)
                return
            case .notDetermined:
                let granted = await manager.requestAuthorization()
                guard reminderOffer?.offerID == offer.id else { return }
                guard granted else {
                    reminderOffer = .init(offerID: offer.id, phase: .needsSettings)
                    return
                }
            default:
                break
            }
            guard !reminderTimeIsChosen else {
                reminderOffer = .init(offerID: offer.id, phase: .alreadyOn)
                return
            }
            // The existing daily reminder (a synced preference) at this
            // completion's local time; no new field.
            do {
                try PrefsConsumerPolicy.mutate(.reminderEnabled, context: modelContext, markers: resetSnapshots) {
                    $0.reminderEnabled = true
                }
                try PrefsConsumerPolicy.mutate(.reminderTime, context: modelContext, markers: resetSnapshots) {
                    $0.reminderHour = hour
                    $0.reminderMinute = minute
                }
                try modelContext.save()
            } catch {
                modelContext.rollback()
                reminderOffer = .init(offerID: offer.id, phase: .failed)
                return
            }
            let activity = PassiveReminderActivityReader.read(context: modelContext, markers: resetSnapshots)
            do {
                try await manager.synchronizePassiveNotifications(
                    dailyReminderEnabled: manager.isAuthorized,
                    wrappedEnabled: wrappedNotifications && manager.isAuthorized,
                    hour: hour,
                    minute: minute,
                    playsSound: resolvedPreferences?.soundOn ?? false,
                    activity: activity
                )
            } catch {
                // The switch is on (the app's next notification refresh retries
                // the booking); the card does not claim it is booked.
                guard reminderOffer?.offerID == offer.id else { return }
                reminderOffer = .init(offerID: offer.id, phase: .scheduleFailed)
                return
            }
            guard reminderOffer?.offerID == offer.id else { return }
            reminderOffer = .init(offerID: offer.id, phase: .scheduled)
        }
    }

    /// sync-03. Which projection this card shows (`PostDropProjectionPolicy`).
    /// A re-stamp waits until the weekly heading has been re-derived too, so
    /// the card never mixes verified progress with a pre-verification week.
    private func postDropSource(_ offer: BreakOffer) -> PostDropProjectionPolicy.Source {
        PostDropProjectionPolicy.source(
            usesCloudPersistence: aggregateProjectionPresentation.usesCloudPersistence,
            isVerificationPending: aggregateProjectionPresentation.isCloudVerificationPending,
            receiptWasCloudUnverified: offer.projectionWasCloudUnverified,
            receiptStampIsCurrentVerified: aggregateProjectionPresentation
                .acceptsVerifiedAggregateCache(offer.projectionCacheStamp),
            verifiedProjectionIsLoaded: verifiedProjectionIsLoadedForRestamp
                && restampedWeekly?.matches(offer: offer.id,
                                            stamp: aggregateProjectionPresentation.verifiedCacheStamp) == true
        )
    }

    private var verifiedProjectionIsLoadedForRestamp: Bool {
        sceneSessionSnapshotIsCurrent && currentAggregatePresentationPage != nil
    }

    /// The open card whose weekly heading needs re-deriving from the verified
    /// projection, if any.
    private var weeklyRestampRequest: RestampedWeeklyMetrics.Request? {
        guard let offer = breakOffer,
              let stamp = aggregateProjectionPresentation.verifiedCacheStamp,
              PostDropProjectionPolicy.source(
                usesCloudPersistence: aggregateProjectionPresentation.usesCloudPersistence,
                isVerificationPending: aggregateProjectionPresentation.isCloudVerificationPending,
                receiptWasCloudUnverified: offer.projectionWasCloudUnverified,
                receiptStampIsCurrentVerified: aggregateProjectionPresentation
                    .acceptsVerifiedAggregateCache(offer.projectionCacheStamp),
                verifiedProjectionIsLoaded: verifiedProjectionIsLoadedForRestamp
              ) == .verifiedProjection
        else { return nil }
        return .init(offerID: offer.id, stamp: stamp)
    }

    /// Re-derives the week the same way the receipt froze it, now from the
    /// verified projection, which may hold other devices' sessions of the week.
    private func rederiveWeeklyMetrics(for request: RestampedWeeklyMetrics.Request?) {
        guard let request, let offer = breakOffer, offer.id == request.offerID else { return }
        guard restampedWeekly?.matches(offer: request.offerID, stamp: request.stamp) != true else { return }
        guard let metrics = try? HomeProjectionPolicy.completionMetrics(
            context: modelContext,
            resetMarkers: resetSnapshots,
            roots: acceptedAggregateRoots,
            looseSessions: looseSessions,
            at: offer.createdAt
        ) else {
            // A failed bounded read keeps the frozen week; the progress still
            // re-stamps rather than waiting forever.
            restampedWeekly = .init(request: request, completionCount: offer.weeklyCompletionCount,
                                    studyGrams: offer.weeklyStudyGrams,
                                    selfReportedGrams: offer.weeklySelfReportedGrams)
            return
        }
        var dates = metrics.weeklyTimerCompletionDates
        if !metrics.weeklyTimerCompletionSessionIDs.contains(offer.id) {
            dates.append(offer.createdAt)
        }
        var grams = metrics.weeklyMeasuredGrams
        if !metrics.weeklyMeasuredSessionIDs.contains(offer.id),
           !metrics.weeklySelfReportedSessionIDs.contains(offer.id) {
            grams = HomeProjectionPolicy.saturatingNonnegativeSum([grams, offer.grams])
        }
        restampedWeekly = .init(
            request: request,
            completionCount: max(1, WeeklyProgressPolicy.completionCount(dates: dates, at: offer.createdAt)),
            studyGrams: grams,
            selfReportedGrams: metrics.weeklySelfReportedGrams
        )
    }

    /// The offer as the card shows it: re-stamped from the verified projection
    /// once verification completed after the receipt froze, otherwise as saved.
    private func presentedOffer(_ offer: BreakOffer) -> BreakOffer {
        guard postDropSource(offer) == .verifiedProjection else { return offer }
        return offer.restamped(
            totalGrams: totalGrams,
            totalPebbles: totalPebbles,
            projectionIsLowerBound: localProjectionNeedsMaintenance,
            stamp: aggregateProjectionPresentation.verifiedCacheStamp,
            weekly: restampedWeekly
        )
    }

    /// The card's mechanics, collapsed behind 「しくみ」 (walk-std-08,
    /// product-05): how far the time core is, what a standard unit is, the
    /// jar's 10→1 and this week's timer count. VoiceOver keeps the card's
    /// full accounting on this one element whether it is open or not. While
    /// iCloud is checked the caption (or the pending note) stays visible.
    @ViewBuilder
    private func postDropMechanics(_ offer: BreakOffer) -> some View {
        switch postDropSource(offer) {
        case .receipt, .verifiedProjection:
            postDropMechanicsDisclosure(presentedOffer(offer))
        case .receiptWhileVerifying:
            // Only a receipt that froze a total this device can stand behind
            // (`PendingMassPresentationPolicy`) shows a position. A lower
            // bound would only say 「時間の核を整理中」 next to the cloud
            // caption — two waiting indicators and no progress.
            if offer.effortProgress != nil, !offer.projectionIsLowerBound {
                VStack(alignment: .leading, spacing: 8) {
                    postDropVerificationCaption
                    postDropMechanicsDisclosure(offer)
                }
            } else {
                postDropCloudVerificationPending(offer)
            }
        }
    }

    private func postDropMechanicsDisclosure(_ offer: BreakOffer) -> some View {
        let mechanics = CompletionCardPresentation.mechanics(
            effortProgress: offer.effortProgress,
            fusionState: offer.fusionState,
            projectionIsLowerBound: offer.projectionIsLowerBound,
            grams: offer.grams,
            weeklyTimerCompletionCount: offer.weeklyCompletionCount
        )
        return MechanicsDisclosure(
            isExpanded: $postDropMechanicsExpanded,
            accessibilityAccounting: SentenceText.join([
                CompletionCardPresentation.sentence(PostDropProgressAccessibilityPresentation.description(
                    effortProgress: offer.effortProgress,
                    fusionState: offer.fusionState,
                    projectionIsLowerBound: offer.projectionIsLowerBound
                )),
                mechanics.unitLine,
                mechanics.weekCountLine
            ].compactMap { $0 }),
            accentHex: offer.colorHex
        ) {
            if let coreLine = mechanics.coreLine {
                VStack(alignment: .leading, spacing: 6) {
                    Text(coreLine)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PomoGemTheme.text)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    if let fraction = mechanics.coreFraction {
                        ProgressView(value: fraction)
                            .tint(Color(hex: offer.colorHex))
                    }
                }
            }
            // The weekly timer count stays in VoiceOver's accounting only:
            // on the card's face it read as the count the card no longer shows.
            ForEach([mechanics.unitLine, mechanics.jarLine].compactMap { $0 }, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("reward.fusion-progress")
    }

    /// One line under the frozen, device-confirmed progress while iCloud is
    /// checked. The card re-stamps itself when verification completes.
    private var postDropVerificationCaption: some View {
        Label {
            Text(projectionVerificationTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PomoGemTheme.muted)
        } icon: {
            Image(systemName: isCloudOfflineSession ? "checklist" : "icloud")
                .font(.caption)
                .foregroundStyle(PomoGemTheme.amber)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reward.projection-verification-caption")
    }

    /// A receipt from a build before mass was captured has no frozen
    /// progress to show while iCloud is checked.
    private func postDropCloudVerificationPending(_ offer: BreakOffer) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(projectionVerificationTitle)
                    .font(.headline.weight(.black))
                Text(
                    "今回の \(MassText.addedGrams(offer.grams)) は保存済みです。これまでの合計は確認が済むと表示します。",
                    tableName: "Home",
                    comment: "Completion card for an old receipt while iCloud is checked: %@ is the mass this focus added (+250g)"
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
            "\(projectionVerificationTitle)。今回の\(offer.grams)グラムは保存済みです。これまでの合計は確認が済むと表示します"
        )
    }

    private func startBreakButton(_ offer: BreakOffer, fillsWidth: Bool = false) -> some View {
        Button {
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
        } label: {
            Text("\(offer.minutes)分休憩", tableName: "Home",
                 comment: "Completion card: the primary action that starts the break. %lld is minutes. en: '%lld-min break'")
                .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(PomoGemCompactButtonStyle())
        // One line: at xxxL on a 12 mini the third of the row is narrower
        // than 「5分休憩」 and the word broke mid-way (round 14).
        .lineLimit(1)
        .minimumScaleFactor(0.7)
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
        let shown = presentedOffer(offer)
        if CompletionCardPresentation.coreBirthMoment(
            effortProgress: shown.effortProgress,
            fusionState: shown.fusionState,
            projectionIsLowerBound: shown.projectionIsLowerBound
        ) == .fusionSheet {
            coreBirthTeaching = CoreBirthTeachingPending(
                receiptID: offer.id,
                acknowledgedAt: .now,
                epochID: currentActivityEpochID
            )
        }
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
#if DEBUG
            HomeRenderDiagnostics.recordLanding()
#endif
            Task { @MainActor in
                handleLanding(event)
                // Off the landing's frames (device-verify-2 P4): the
                // snapshot follows the settled jar a moment later.
                scheduleWidgetSnapshot()
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
        // Bodies bake at this view's scale; set it before the first restore
        // so a 2× device never bakes (and keeps) 3× textures.
        scene.artworkScale = displayScale
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
            jarStageState.screenTimeDropRevision &+= 1
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
        let orphanedReceiptIDs: [UUID]
        do {
            var resolved = try HomeProjectionPolicy.pendingRewardSessionCandidates(
                for: receipts,
                context: modelContext,
                resetMarkers: resetSnapshots
            )
            orphanedReceiptIDs = try HomeProjectionPolicy
                .orphanedPendingRewardReceiptIDs(
                    in: receipts,
                    resolvedSessionIDs: Set(resolved.map(\.id)),
                    storeReadIsVerified:
                        !aggregateProjectionPresentation.isCloudVerificationPending,
                    presentedCardIsPending:
                        breakOffer != nil || breakOfferTask != nil,
                    sessionExists: {
                        try HomeProjectionPolicy.physicalSessionExists(
                            id: $0,
                            context: modelContext
                        )
                    }
                )
            for id in screenTimeIDs {
                if let session = try BoundedHistoryPolicy.resolvedSession(
                    id: id, epochID: currentActivityEpochID, context: modelContext
                ), session.effectiveSource == .screenTime, StudySessionIntegrityPolicy.isSupported(session) {
                    resolved.append(session)
                } else {
                    ScreenTimeGemDropStore.remove(id)
                    jarStageState.screenTimeDropRevision &+= 1
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
        } catch {
            // A failed bounded lookup is not proof that a saved reward is gone.
            // Leave the durable receipt intact until the next accepted refresh.
            return false
        }
        retireOrphanedRewardReceipts(orphanedReceiptIDs)
        return true
    }

    /// A receipt whose session is gone from the verified store can never
    /// land, and would keep the start button disabled for good
    /// (`HomeProjectionPolicy.orphanedPendingRewardReceiptIDs`). Finish it as
    /// if its gem had landed, so whatever the card's 「閉じる」 chose (rest,
    /// share or Home) still continues.
    private func retireOrphanedRewardReceipts(_ ids: [UUID]) {
        for id in ids {
            let phase = PendingRewardReceiptStore.load()
                .first { $0.id == id }?.dropPhase
            Self.receiptLogger.notice(
                "Retired a reward receipt whose session is absent from the verified store phase=\(phase?.rawValue ?? "none", privacy: .public)"
            )
            finishRewardDrop(sessionID: id)
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
        // Only retiring a complete page changes what Home shows before the
        // read lands (`sessionPageIsRereading`); a cancelled read's flag stays.
        sessionPageIsRereading = sessionPageIsRereading || sessionBackfillIsComplete
        sessionBackfillIsComplete = false
        sessionPageReadFailed = false
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
#if DEBUG
            // sync-03 UI fixture only: a slower read, like the phone's right
            // after a return to the app (device-verify-2 P2).
            if let delay = CloudVerificationUITestFixture.sessionRereadDelay {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
            }
#endif
            do {
                let page = try HomeProjectionPolicy.supportedLooseSessionPage(
                    context: modelContext,
                    resetMarkers: markers,
                    startingAt: queryPlan.lowerBound
                )
                try Task.checkCancellation()
                guard aggregateProjectionPresentation
                    .acceptsCurrentGenerationCache(cacheStamp) else {
                    // The presentation has moved on and reads again for it.
                    sessionPageIsRereading = false
                    return
                }
                supportedSessionBackfill = page.sessions
                supportedSessionBackfillStamp = cacheStamp
                supportedSessionBackfillVerifiedStamp = verifiedCacheStamp
                sessionBackfillIsComplete = page.isCompleteForHomeCandidates
                hasLoadedSceneSessionSnapshot = true
                sessionPageIsRereading = false
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
                // foreground transition, or relaunch retries the scan. Until
                // then nothing will replace a held readout, so Home presents
                // what its inputs prove: a lower bound for a current page
                // whose completeness is now unproven, 「再集計中」 or a lower
                // bound for one of an earlier generation.
                sessionPageIsRereading = false
                sessionPageReadFailed = true
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
            // Also catches a custom time chosen on another device.
            if purchase.isPro { rememberCustomDuration(restored) }
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
        rememberCustomDuration(duration)
        showCustomDuration = false
        return true
    }

    private func shareCompletedStratum(_ request: PendingStratumCelebration) {
        dropFocusStartWaitingOnCelebration()
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
        dropFocusStartWaitingOnCelebration()
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

    private func presentMonthLabelPaywallIfRequested() {
        guard opensMonthLabelPaywallAfterCelebration else { return }
        opensMonthLabelPaywallAfterCelebration = false
        guard !purchase.isPro else { return }
        router.presentPaywall(from: .aggregateLabels)
    }

    private func selectDuration(_ duration: PomodoroDuration) {
        selectedDuration = duration
#if DEBUG
        if duration == .demo { return }
#endif
        rememberCustomDuration(duration)
        _ = persistPreferredFocusSeconds(
            duration.seconds,
            failureMessage: "集中時間を保存できませんでした"
        )
    }

    private func startFocus(duration: PomodoroDuration) {
        commitPendingManualEntry()
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
        // Starting a focus answers today's daily reminder. Record it before
        // the cover opens, so the reminder is re-read with it (RootView).
        PassiveReminderActivityReader.recordFocusStarted()
        focusConfiguration = FocusConfiguration(
            subject: subject,
            duration: duration,
            dataEpochID: currentActivityEpochID
        )
    }

    // MARK: Focus starts from widgets, links and App Shortcuts

    private var focusStartEntrySnapshot: FocusStartEntryPolicy.Snapshot? {
        guard let request = router.pendingFocusStart else { return nil }
        let presentedBreak = breakConfiguration ?? router.recoveredBreak
        let presentedBreakHasEnded = presentedBreak.map {
            BreakRecoveryPolicy.remainingSeconds(
                minutes: $0.minutes,
                endDate: $0.endDate,
                at: .now
            ) == 0
        } ?? false
        return FocusStartEntryPolicy.Snapshot(
            requestID: request.id,
            isFresh: AppEntryInbox.isFresh(
                request.receivedAtUptime,
                at: ContinuousUptime.now()
            ),
            homeIsVisible: homeIsVisible && router.selectedTab == .jar,
            timerIsPresented: focusConfiguration != nil
                || router.recoveredFocus != nil
                || router.focusPresentationIsActive
                || (presentedBreak != nil && !presentedBreakHasEnded),
            endedBreakIsPresented: presentedBreak != nil && presentedBreakHasEnded,
            focusRecoveryIsPending: router.deferredFocusRecovery != nil
                || router.cloudFocusRecoveryOffer != nil,
            rewardChoiceIsPending: breakOffer != nil || breakOfferTask != nil,
            rewardDropIsInProgress: hasPendingRewardReceipt
                || rewardDropDestination != nil
                || rewardDropRevealIsPending,
            otherSurfaceIsPresented: router.paywallPresented || router.sharePresented,
            entryFormIsPresented: showManualEntry
                || showAchievementEntry
                || showCustomDuration,
            closableSurfaceIsPresented: showHomeMenu
                || showAccumulationOverview
                || selectedAggregateDetail != nil
                || showAccumulationPlan,
            celebrationIsPresented: completedStratum != nil,
            hasTheme: selectedSubject != nil,
            lengthIsSettled: request.preset != nil
                || purchase.hasResolvedEntitlements
                || !savedFocusLengthNeedsPro
        )
    }

    /// The saved length is a Pro one, so until StoreKit answers, Home's
    /// selected length is only the free fallback `restorePreferredDuration`
    /// put there. A start with it would also save 25 over the custom length.
    private var savedFocusLengthNeedsPro: Bool {
        guard let seconds = resolvedPreferences?.preferredFocusSeconds else {
            return false
        }
        let saved = PomodoroDuration(totalSeconds: seconds)
        return saved.isValid && saved.requiresPro
    }

    private func handlePendingFocusStart() {
        guard let snapshot = focusStartEntrySnapshot else {
            cancelFocusStartEntrySettle()
            return
        }
        switch FocusStartEntryPolicy.decide(snapshot) {
        case .wait:
            cancelFocusStartEntrySettle()
        case .closeSurfaces:
            // Read-only sheets only. The entry forms keep what the person
            // typed; the policy waits for them instead.
            cancelFocusStartEntrySettle()
            showHomeMenu = false
            showAccumulationOverview = false
            selectedAggregateDetail = nil
            showAccumulationPlan = false
        case let .decline(reason):
            cancelFocusStartEntrySettle()
            router.pendingFocusStart = nil
            if let message = FocusStartEntryPolicy.message(for: reason) {
                router.showToast(message, symbol: "timer")
            }
        case .start:
            guard focusStartEntryTask == nil else { return }
            let requestID = snapshot.requestID
            focusStartEntryTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                focusStartEntryTask = nil
                // Someone who left again before the start is not surprised
                // by a timer on their return.
                guard UIApplication.shared.applicationState != .background else {
                    router.pendingFocusStart = nil
                    return
                }
                guard let current = focusStartEntrySnapshot,
                      current.requestID == requestID,
                      FocusStartEntryPolicy.decide(current) == .start,
                      let request = router.pendingFocusStart else {
                    handlePendingFocusStart()
                    return
                }
                router.pendingFocusStart = nil
                // Exactly the start button: the selected theme, and the
                // selected length unless a free preset was asked for.
                let preset = request.preset.flatMap { preset in
                    PomodoroDuration.freePresets.first { $0.seconds == preset.seconds }
                }
                startFocus(duration: preset ?? selectedDuration)
            }
        }
    }

    private func cancelFocusStartEntrySettle() {
        focusStartEntryTask?.cancel()
        focusStartEntryTask = nil
    }

    /// A start waiting behind the fusion celebration belongs to 「続ける」.
    /// The sheet's other actions (the breakdown, the card, the month-label
    /// link) are the person choosing where to go next, so the request is
    /// dropped rather than fired over, or after, what they chose.
    private func dropFocusStartWaitingOnCelebration() {
        guard router.pendingFocusStart != nil else { return }
        cancelFocusStartEntrySettle()
        router.pendingFocusStart = nil
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
            presentedStratumTeachesCoreBirth = stratumTeachesCoreBirth(request)
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
        let next = stratumCelebrationQueue.removeFirst()
        presentedStratumTeachesCoreBirth = stratumTeachesCoreBirth(next)
        completedStratum = next
        presentedStratumID = next.id
    }

    /// product-05. The crystal the acknowledged card made: its ten sources
    /// include that card's session. A crystal already carried into a ×100
    /// is no root any more; then it is the first ten-gem crystal baked
    /// after that acknowledgement.
    private func stratumTeachesCoreBirth(_ request: PendingStratumCelebration) -> Bool {
        guard let pending = coreBirthTeaching,
              pending.epochID == currentActivityEpochID,
              StratumCelebrationTeaching.isTenGemCrystal(request)
        else { return false }
        if let root = storedAggregates.first(where: { $0.id == request.id }) {
            return root.sessionIDs.contains(pending.receiptID)
        }
        return request.createdAt >= pending.acknowledgedAt.addingTimeInterval(-1)
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
        // The teaching line belongs to that crystal's sheet alone.
        if presentedStratumTeachesCoreBirth {
            coreBirthTeaching = nil
            presentedStratumTeachesCoreBirth = false
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

    /// Accepts the entry chosen in the sheet (history-02). Home's own
    /// selection is left alone: back-filling time for another theme must not
    /// change what the next timer starts with. Nothing is written yet: the
    /// entry waits a few seconds (`ManualEntryUndoPolicy`) under a 「元に戻す」
    /// banner and is then saved by `commitPendingManualEntry`. Returns nil
    /// once accepted, otherwise the reason, which the still-open sheet shows
    /// beside its button (a toast would sit behind the full-height sheet).
    private func addManualEntry(_ subject: Subject, _ duration: ManualDuration) -> String? {
        // A second add never stacks two unsaved entries.
        commitPendingManualEntry()
        guard let resolvedPreferences else {
            return "設定情報を読み込めませんでした。もう一度お試しください。"
        }
        guard !activeSubjects.isEmpty else {
            showManualEntry = false
            router.selectedTab = .settings
            router.showToast("先にテーマを追加してください", symbol: "books.vertical.fill")
            return "先にテーマを追加してください。"
        }
        // The sheet's list is a snapshot; the theme may have been archived
        // or removed (for example from another device) while it was open.
        guard activeSubjects.contains(where: { $0.id == subject.id }) else {
            return "選んだテーマが見つかりません。テーマを選び直してください。"
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
            return "\(Constants.UIStrings.manualCapToast)です。"
        }

        let pending = PendingManualEntry(
            subjectID: subject.id,
            subjectName: subject.safeDisplayName,
            colorHex: subject.colorHex,
            duration: duration,
            confirmedAt: now,
            dataEpochID: currentActivityEpochID,
            accountScope: .current()
        )
        pendingManualEntry = pending
        showManualEntry = false
        schedulePendingManualCommit(pending)
        // VoiceOver hears about the entry from the banner once the sheet has
        // gone (`announcePendingManualEntry`): an announcement posted while
        // the sheet is dismissing is often dropped.
        return nil
    }

    /// VoiceOver only. The banner is an overlay read after the jar, the
    /// pickers and the start button, so focus moves to its 「元に戻す」 once
    /// the sheet has dismissed, and a queued announcement says what waits.
    private func announcePendingManualEntry(_ pending: PendingManualEntry) async {
        guard UIAccessibility.isVoiceOverRunning else { return }
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled, pendingManualEntry?.id == pending.id else { return }
        manualUndoHasFocus = true
        let message = String(
            localized: "\(pending.subjectName)に\(DurationText.spoken(minutes: pending.duration.minutes))、\(MassText.spoken(grams: pending.duration.grams))を積みます。「元に戻す」で取り消せます",
            table: "Home",
            comment: "VoiceOver, once the Undo banner of a manual entry has focus: theme, duration, grams"
        )
        // Queued, so it follows the focused button's own label instead of
        // cutting it off.
        UIAccessibility.post(
            notification: .announcement,
            argument: NSAttributedString(
                string: message,
                attributes: [.accessibilitySpeechQueueAnnouncement: true]
            )
        )
    }

    private func schedulePendingManualCommit(_ pending: PendingManualEntry) {
        pendingManualCommitTask?.cancel()
        let window = ManualEntryUndoPolicy.window(
            assistiveTechnologyIsRunning: UIAccessibility.isVoiceOverRunning
                || UIAccessibility.isSwitchControlRunning
        )
        pendingManualCommitTask = Task { @MainActor in
            do {
                try await Task.sleep(for: window)
            } catch {
                return
            }
            guard pendingManualEntry?.id == pending.id else { return }
            commitPendingManualEntry()
        }
    }

    /// 「元に戻す」: nothing was written, so nothing is deleted.
    private func undoPendingManualEntry() {
        guard pendingManualEntry != nil else { return }
        pendingManualCommitTask?.cancel()
        pendingManualCommitTask = nil
        pendingManualEntry = nil
        router.showToast(
            String(localized: "取り消しました。瓶には積んでいません", table: "Home", comment: "Toast after undoing a manual entry"),
            symbol: "arrow.uturn.backward"
        )
    }

    /// Writes the pending entry: the allowance and the session in one
    /// SwiftData transaction, exactly as a direct save did before. Called when
    /// the window ends, and at once when Home stops being the frontmost,
    /// undisturbed surface (another sheet or screen, a timer, the app leaving
    /// the foreground, a second add).
    private func commitPendingManualEntry() {
        guard let pending = pendingManualEntry else { return }
        pendingManualCommitTask?.cancel()
        pendingManualCommitTask = nil
        pendingManualEntry = nil

        let failure = String(
            localized: "\(pending.subjectName)の自己申告を保存できませんでした。もう一度積んでください",
            table: "Home",
            comment: "Toast when a confirmed manual entry could not be saved; the argument is the theme"
        )
        // The account boundary may have closed since confirming: Home's
        // teardown commits too (`onDisappear`), and an account change tears
        // Home down after closing it. Nothing may reach a retiring store.
        guard ManualEntryUndoPolicy.mayCommit(
            confirmedUnder: pending.accountScope,
            now: .current()
        ) else {
            Self.manualEntryLogger.notice(
                "Dropped a pending manual entry: the account boundary changed before it was saved"
            )
            router.showToast(failure, symbol: "exclamationmark.triangle")
            return
        }
        // A reset or a removed theme in the few seconds since confirming
        // leaves nothing to attach the entry to.
        guard pending.dataEpochID == currentActivityEpochID,
              let subject = activeSubjects.first(where: { $0.id == pending.subjectID }),
              let resolvedPreferences else {
            router.showToast(failure, symbol: "exclamationmark.triangle")
            return
        }
        let decision = FairnessPolicy.consumeManualEntry(
            state: ManualCounterState(
                dayKey: resolvedPreferences.manualDayKey,
                usedToday: resolvedPreferences.manualUsedToday
            ),
            at: pending.confirmedAt
        )
        guard decision.isAllowed else {
            router.showToast(Constants.UIStrings.manualCapToast, symbol: "clock.badge.xmark")
            return
        }
        let writer: Prefs
        do {
            writer = try PrefsSyncPolicy.ensureWriterRow(
                context: modelContext,
                currentEpochID: currentActivityEpochID
            )
        } catch {
            modelContext.rollback()
            router.showToast(failure, symbol: "exclamationmark.triangle")
            return
        }
        writer.manualDayKey = decision.state.dayKey
        writer.manualUsedToday = decision.state.usedToday
        let session = StudySession(
            subject: subject,
            startAt: pending.confirmedAt.addingTimeInterval(-TimeInterval(pending.duration.seconds)),
            endAt: pending.confirmedAt,
            seconds: pending.duration.seconds,
            source: .manual,
            grams: pending.duration.grams,
            deviceDayKey: FairnessPolicy.deviceDayKey(for: pending.confirmedAt),
            dataEpochID: currentActivityEpochID
        )
        modelContext.insert(session)
        // Counted by the jar's readout when its gem lands (dev-D7). Only
        // while Home is on screen: otherwise the gem falls whenever Home
        // returns, and nothing reports its landing to this view.
        if homeIsVisible {
            noteFallingManualEntry(session.id)
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            jarStageState.fallingManualSessionIDs.remove(session.id)
            router.showToast(failure, symbol: "exclamationmark.triangle")
        }
    }

    /// How long a just-written manual gem may stay out of the readout if its
    /// landing is never reported (for example when the jar is restored
    /// instead of dropping it). A fall takes about a second.
    private static let manualLandingGrace: Duration = .seconds(4)

    private func noteFallingManualEntry(_ sessionID: UUID) {
        jarStageState.fallingManualSessionIDs.insert(sessionID)
        Task { @MainActor in
            try? await Task.sleep(for: Self.manualLandingGrace)
            if jarStageState.fallingManualSessionIDs.contains(sessionID) {
                jarStageState.fallingManualSessionIDs.remove(sessionID)
            }
        }
    }

    /// history-02. A short strip over the top of the scroll area, never
    /// over the start button pinned below it at accessibility sizes (home-03).
    /// There the undo button moves under the text and the text is capped at
    /// the first accessibility size: side by side at AX5 the text column was
    /// ~150 pt wide, broke every three or four characters and made the banner
    /// 456 pt tall, over the whole jar and half the start button for the
    /// entire Undo window.
    @ViewBuilder
    private func manualUndoBanner(_ pending: PendingManualEntry) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        manualUndoDot(pending)
                        manualUndoText(pending, titleLineLimit: 3, subtitleLineLimit: 2)
                    }
                    manualUndoButton(fillsWidth: true)
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .padding(12)
            } else {
                HStack(spacing: 12) {
                    manualUndoDot(pending)
                    manualUndoText(pending, titleLineLimit: nil, subtitleLineLimit: nil)
                    manualUndoButton(fillsWidth: false)
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
            }
        }
        .background(PomoGemTheme.raised.opacity(0.97), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(PomoGemTheme.amber.opacity(0.34), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("manual.pending")
        .task(id: pending.id) {
            await announcePendingManualEntry(pending)
        }
    }

    private func manualUndoDot(_ pending: PendingManualEntry) -> some View {
        Circle()
            .fill(Color(hex: pending.colorHex))
            .frame(width: 12, height: 12)
            .overlay { Circle().stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2])) }
            .accessibilityHidden(true)
    }

    private func manualUndoText(
        _ pending: PendingManualEntry,
        titleLineLimit: Int?,
        subtitleLineLimit: Int?
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Time first, like every other record; the grams follow.
            Text(
                "\(pending.subjectName)に\(DurationText.short(minutes: pending.duration.minutes))を積みます",
                tableName: "Home",
                comment: "Undo banner after a manual entry: theme, then the self-reported time about to be added"
            )
                .font(.subheadline.weight(.bold))
                .lineLimit(titleLineLimit)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "\(MassText.addedGrams(pending.duration.grams)) ・ まもなく瓶に入ります",
                tableName: "Home",
                comment: "Undo banner subtitle: the mass added (+300g), and that the entry is saved shortly"
            )
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .lineLimit(subtitleLineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Full width under the text at accessibility sizes, so the whole row
    /// is the target.
    private func manualUndoButton(fillsWidth: Bool) -> some View {
        Button {
            undoPendingManualEntry()
        } label: {
            Text(String(localized: "元に戻す", table: "Home", comment: "Undo button for a manual entry that is not saved yet"))
                .frame(minWidth: 44, maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
                .background {
                    if fillsWidth {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(PomoGemTheme.amber.opacity(0.14))
                    }
                }
        }
        .font(.subheadline.weight(.bold))
        .foregroundStyle(PomoGemTheme.amber)
        .contentShape(Rectangle())
        .buttonStyle(PomoGemRowButtonStyle())
        .accessibilityFocused($manualUndoHasFocus)
        .accessibilityIdentifier("manual.undo")
    }

    /// Returns nil once saved, otherwise the reason for the open sheet.
    private func addAchievementStone(
        subject: Subject,
        draft: AchievementDraft
    ) -> String? {
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
            return nil
        } catch {
            modelContext.rollback()
            return "記念石を保存できませんでした。もう一度お試しください。"
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
            router.showToast(String(localized: "結晶は未保存です。再試行してください", table: "Home"), symbol: "exclamationmark.triangle")
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
        router.showToast(String(localized: "結晶の保存を再試行します", table: "Home"), symbol: "arrow.clockwise")
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
            // The fusion sheet is the celebration. The toast is only the
            // immediate notice when the sheet had to wait (rest, share, a
            // sheet already up); fired together, the sheet covered it and
            // VoiceOver announced both.
            guard completedStratum?.id != finalCelebration.id else { return }
            let message = completedSteps > 1
                ? String(localized: "小さな粒が\(completedSteps)段階で結晶になり、瓶に余白ができた", table: "Home",
                         comment: "Toast after a cascade of fusions; the argument is how many levels formed")
                : String(localized: "\(finalCelebration.pebbleCount)粒が、ひとつの結晶になった", table: "Home",
                         comment: "Toast after ten gems fuse; the argument is the gem count")
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
        if jarStageState.fallingManualSessionIDs.contains(descriptor.id) {
            // Now in the jar: the readout counts it (dev-D7).
            jarStageState.fallingManualSessionIDs.remove(descriptor.id)
        }
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
            jarStageState.screenTimeDropRevision &+= 1
            scheduleLandingSettle()
            return
        }
        var message: String
        let presentationKind = RareRewardPresentationPolicy.kind(descriptor.kind)
        switch presentationKind {
        case .gold:
            message = rareRewardMode.usesEnhancedPresentation
                ? Constants.UIStrings.goldToast(grams: descriptor.grams)
                : "\(descriptor.subjectName) 金の粒 \(MassText.addedGrams(descriptor.grams))"
        case .prism:
            message = rareRewardMode.usesEnhancedPresentation
                ? Constants.UIStrings.prismToast(grams: descriptor.grams)
                : "\(descriptor.subjectName) 虹の粒 \(MassText.addedGrams(descriptor.grams))"
        case .normal:
            message = descriptor.grams == Constants.Mass.measuredPebbleGrams
                ? Constants.UIStrings.dropToast(subject: descriptor.subjectName)
                : "\(descriptor.subjectName) \(MassText.addedGrams(descriptor.grams)) 積んだ"
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
            // In the readout at once. The receipt is released once the
            // landing has settled: removing it writes UserDefaults, and any
            // UserDefaults write re-renders Home through its `@AppStorage`
            // properties (`_printChanges` lists them all as changed).
            jarStageState.landedReceiptIDs.insert(descriptor.id)
            scheduleLandingSettle()
            return
        }
        guard descriptor.source != .manual,
              hasLocalCompletionMarker(descriptor.id)
        else { return }
        if let receipt = prepareRewardReceipt(for: descriptor, dropPhase: nil) {
            scheduleRewardReceipt(receipt, delay: .milliseconds(1_650))
        }
    }

    /// device-verify-2 P4, after review. What a landing sets off in Home
    /// itself re-renders all of Home and re-derives its sessions: releasing
    /// a timer gem's receipt enables the start button and continues to Home,
    /// rest or share, and `syncScene` re-reads the jar's page. Run inside
    /// the landing callback, that is the full Home pass the device trace
    /// caught as a 33 ms hitch on an iPhone 12 mini (there on a manual gem),
    /// at the moment every completed focus ends on. The readout already
    /// counts the gem (`JarStageState`); the rest waits until the landing has
    /// settled, and a run of landings (a Screen Time import) settles once,
    /// after the last. A process that ends within that moment keeps the
    /// receipt, and the next launch drops the gem again, as it does for one
    /// that ends during the fall.
    /// Long enough for the landing's quick motion to be over (its camera
    /// shake has decayed to about 5 % and its sparks have travelled most of
    /// their way, `JarEffectsIntensity.landing`), short enough that the start
    /// button and the card's rest or share follow without a felt pause.
    private static let landingSettleDelay: Duration = .milliseconds(300)

    private func scheduleLandingSettle() {
        landingSettle.schedule(after: Self.landingSettleDelay) {
            settleLandings()
        }
    }

    private func settleLandings() {
#if DEBUG
        HomeRenderDiagnostics.recordLandingSettle()
#endif
        let receipts = PendingRewardReceiptStore.load()
        // Released on an earlier settle (or by `syncScene`), and Home has
        // re-read the receipts since: the readout no longer needs them.
        let held = Set(receipts.map(\.id))
        if !jarStageState.landedReceiptIDs.isSubset(of: held) {
            jarStageState.landedReceiptIDs.formIntersection(held)
        }
        for receipt in receipts
        where receipt.dropPhase == .awaitingLanding
            && jarStageState.landedReceiptIDs.contains(receipt.id) {
            finishRewardDrop(sessionID: receipt.id)
        }
        syncScene()
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
        var measuredCompletionDates = historyMetrics?.weeklyTimerCompletionDates ?? []
        if historyMetrics?.weeklyTimerCompletionSessionIDs.contains(descriptor.id) != true {
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
        let frozenLifetime = receiptLifetime(includingSessionID: descriptor.id, grams: descriptor.grams)
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
            totalPebbleCount: max(1, frozenLifetime.pebbles),
            totalStudyGrams: max(descriptor.grams, frozenLifetime.grams),
            projectionIsLowerBound: frozenLifetime.isLowerBound,
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

    /// sync-03 after review. The lifetime values a completion freezes. While
    /// iCloud is checked they are the pending headline's
    /// (`PendingMassPresentationPolicy`), so the card can show a real position
    /// whenever this device can stand behind a total; otherwise the receipt
    /// stays a lower bound, as before, and re-stamps after verification.
    private func receiptLifetime(
        includingSessionID sessionID: UUID,
        grams: Int
    ) -> (grams: Int, pebbles: Int, isLowerBound: Bool) {
        guard aggregateProjectionPresentation.isCloudVerificationPending else {
            return (totalGrams, totalPebbles, localProjectionNeedsMaintenance)
        }
        let headline = pendingMassHeadline
        guard let headlineGrams = headline.grams, let pebbles = headline.pebbleCount else {
            return (totalGrams, totalPebbles, true)
        }
        // The session was just saved; Home's page may not hold it yet.
        guard !looseSessions.contains(where: { $0.id == sessionID }) else {
            return (headlineGrams, pebbles, headline.isLowerBound)
        }
        return (HomeProjectionPolicy.saturatingNonnegativeSum([headlineGrams, grams]),
                HomeProjectionPolicy.saturatingNonnegativeSum([pebbles, 1]),
                headline.isLowerBound)
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
            // The teaching moment waits for its own crystal's sheet, which
            // is held while receipts drain (EngagementArchitecture §3.1),
            // so a newer card leaves it alone.
            postDropMechanicsExpanded = false
            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.86)) {
                breakOffer = withWeeklySelfReport(BreakOffer(receipt: receipt))
            }
            breakOfferTask = nil
        }
    }

    /// walk-std-07. The receipt froze the week's measured figure; the card
    /// adds the same week's self-reported focus, read from the same query
    /// (`HomeProjectionPolicy.completionMetrics`). A failed read shows the
    /// measured figure alone.
    private func withWeeklySelfReport(_ offer: BreakOffer) -> BreakOffer {
        guard let metrics = try? HomeProjectionPolicy.completionMetrics(
            context: modelContext,
            resetMarkers: resetSnapshots,
            roots: acceptedAggregateRoots,
            looseSessions: looseSessions,
            at: offer.createdAt
        ) else { return offer }
        var copy = offer
        copy.applyWeeklySelfReport(
            grams: metrics.weeklySelfReportedGrams,
            includesThisCompletion: metrics.weeklySelfReportedSessionIDs.contains(offer.id)
        )
        return copy
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
        // Widgets are account-neutral in this release (PRIVACY.md) and
        // `JarSnapshotter` publishes nothing, so do not build the metadata:
        // it re-derived every session on the main thread after each landing
        // and store change for nothing (device-verify-2 P4).
        guard ReleaseExternalSurfacePolicy.showsAccountDataInWidgets else { return }
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
            // One message at a time: the first gem's toast goes first. A
            // manual entry is saved when its Undo window ends and its toast
            // comes when the gem lands, so wait for the landing too; before
            // it, there is no toast yet to wait for (history-02).
            var waitedForToast = 0
            while router.toast != nil || newestGemIsStillFalling, waitedForToast < 40 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                waitedForToast += 1
            }
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

    /// The newest gem is still queued or falling. Its landing brings the drop
    /// toast, which the one-time jar hint must not talk over. The hint's
    /// wait is bounded, so a gem that never shows in the scene only delays it.
    private var newestGemIsStillFalling: Bool {
        if scene.queuedDropCount > 0 { return true }
        guard let newest = looseSessions.first else { return false }
        return !scene.hasLandedPebble(withID: newest.id)
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

    private var jarInteractionShortHintText: String {
        voiceOverEnabled
            ? String(localized: "瓶をダブルタップすると粒が跳ねます", table: "Home",
                     comment: "One-line jar tip in a short jar at accessibility text sizes, with VoiceOver on")
            : String(localized: "瓶をタップすると粒が跳ねます", table: "Home",
                     comment: "One-line jar tip in a short jar at accessibility text sizes")
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
        // Covers the card button and the jar's VoiceOver custom action.
        didSeeAggregateDetail = true
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
            String(
                localized: "\(summary.pebbleCount)粒の結晶、\(aggregateInspectionSubtitle(summary))",
                table: "Home",
                comment: "VoiceOver, crystal inspection card: gems inside, then what its detail shows"
            )
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

                // Once a detail has been opened the row holds only the card
                // (`showsAggregateInspectionSlot`).
                if !didSeeAggregateDetail {
                    Label(
                        String(localized: "結晶をタップすると、内訳を見られます", table: "Home", comment: "Hint under the jar until a crystal's detail has been opened once"),
                        systemImage: "hand.tap"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PomoGemTheme.muted)
                    .multilineTextAlignment(.center)
                    // The capacity chip takes this row while a fusion nears.
                    .opacity(isPresented || showsCapacityChip ? 0 : 1)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                }
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
                    Text("結晶を見つけました", tableName: "Home")
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
                    Text("結晶を見つけました", tableName: "Home")
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
            // Decorative, in a fixed 32 pt circle: past xxxLarge the glyph
            // outgrew it and ran into the card's title.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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

        let source = postDropSource(offer)
        let shown = presentedOffer(offer)
        let progressMessage: String
        if source == .receiptWhileVerifying, offer.effortProgress == nil || offer.projectionIsLowerBound {
            progressMessage = SentenceText.join([
                CompletionCardPresentation.sentence(projectionVerificationTitle),
                String(localized: "今回の記録は保存済みです。これまでの合計は確認が済むと表示します。", table: "Home",
                       comment: "VoiceOver announcement while iCloud is checked: this focus is saved; the totals follow")
            ])
        } else {
            let progress = CompletionCardPresentation.sentence(PostDropProgressAccessibilityPresentation.description(
                effortProgress: shown.effortProgress,
                fusionState: shown.fusionState,
                projectionIsLowerBound: shown.projectionIsLowerBound
            ))
            progressMessage = source == .receiptWhileVerifying
                ? SentenceText.join([progress, CompletionCardPresentation.sentence(projectionVerificationTitle)])
                : progress
        }
        // The card's own order: the headline, time then grams, the week, a
        // rare outcome, then the full accounting that 「しくみ」 holds.
        var sentences: [String?] = [
            String(localized: "集中を記録しました。", table: "Home",
                   comment: "VoiceOver announcement: the completion card's headline, as a sentence"),
            CompletionCardPresentation.spokenMainLine(subjectName: offer.subjectName, grams: offer.grams),
            shown.weeklySpokenTitle,
            CompletionCardPresentation.spokenRareLine(kind: offer.kind, counts: offer.rareRewardCounts),
            progressMessage,
            CompletionCardPresentation.spokenBreakAvailability(minutes: offer.minutes)
        ]
        if showShareChip {
            sentences.append(String(localized: "今の瓶をカードにして共有できます。", table: "Home",
                                    comment: "VoiceOver announcement: the completion card's share button is available"))
            announcedPostDropShareOfferID = offer.id
        }
        postLowPriorityAccessibilityAnnouncement(SentenceText.join(sentences.compactMap { $0 }))
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

    /// The menu's lifetime mass, as the jar's readout shows it
    /// (`HomeLifetimeMassText`).
    private func formattedMass(_ grams: Int) -> String {
        HomeLifetimeMassText.text(grams)
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

/// State that only the jar's stage observes (device-verify-2 P4): the part of
/// dev-D7's "not landed yet" bookkeeping that changes when a gem lands, and
/// the stage's own measured geometry.
///
/// A manual entry's landing used to remove its ID from a `@State` set on
/// HomeView, a Screen Time landing bumped a `@State` revision, and a readout
/// that grew with the new gem (the first gem's rail) wrote its new bottom to
/// another. Each change re-ran all of Home's body — its session projection,
/// canonical sessions and integrity checks, the change tokens, every card —
/// to add one gem to the readout: 103 ms of main-thread work in 210 ms and a
/// 33 ms hitch on an iPhone 12 mini, right on the landing. Kept in this
/// observable object, the same changes re-run only the views that read it
/// (`JarStageReader`). Home's own body must never read these
/// properties, or it subscribes to them again.
///
/// Receipts stay in Home's own state: removing one enables the start button
/// and may present a queued celebration, which is Home's to re-render. A
/// timer gem's landing is marked here instead (`landedReceiptIDs`), and Home
/// releases the receipt once the landing has settled
/// (`HomeView.landingSettleDelay`).
@MainActor
@Observable
final class JarStageState {
    /// Manual entries written a moment ago whose gem is still falling. The
    /// readout counts them when they land, or after `manualLandingGrace` if
    /// the landing is never reported.
    var fallingManualSessionIDs = Set<UUID>()
    /// Timer gems that have landed while Home still holds their receipt
    /// (review of #58): the readout counts them at once, although Home's
    /// pass still lists them as pending until it releases the receipt after
    /// the landing. An ID stays until a later settle finds its receipt gone,
    /// by which time Home has re-read the receipts.
    var landedReceiptIDs = Set<UUID>()
    /// Bumped when a Screen Time gem's drop is retired from
    /// `ScreenTimeGemDropStore`, which lives in UserDefaults and is not
    /// observed: readers re-read the store when it changes.
    var screenTimeDropRevision = 0
    /// Measured HUD bottom and jar stage top in the jar card's coordinate
    /// space; the time core's orbit is laid out below the HUD.
    var measuredHUDBottom: CGFloat?
    var measuredStageTop: CGFloat = 0

    /// Everything not landed yet: the pending receipts and completion marker
    /// Home resolved on its own pass, less the timer gems that have landed
    /// since, plus the falling manual entries and queued Screen Time gems.
    func unlandedSessionIDs(pendingOnHomePass: Set<UUID>) -> Set<UUID> {
        _ = screenTimeDropRevision
        return pendingOnHomePass.subtracting(landedReceiptIDs).union(HomeProjectionPolicy.unlandedSessionIDs(
            rewardReceipts: [],
            completionMarker: nil,
            screenTimeDrops: ScreenTimeGemDropStore.load(),
            fallingManualEntries: fallingManualSessionIDs
        ))
    }
}

/// What `JarStageReader` needs from Home's own pass to count a gem once it
/// has landed (dev-D7, device-verify-2 P4): the accepted crystals, the loose
/// sessions, every saved session's totals, and the timer gems a receipt or
/// the completion marker still holds back. Falling manual entries and queued
/// Screen Time gems come from `JarStageState` when the reader runs.
struct JarLandedTotalsInputs {
    let roots: [AggregatePebble]
    let looseSessions: [StudySession]
    let pendingOnHomePass: Set<UUID>
    /// Every saved session counted (`HomeProjectionPolicy.totals`), landed or
    /// not.
    let savedTotals: HomeProjectionPolicy.Totals

    /// The landed totals as Home's own pass knows them, before the stage
    /// applies what has landed or started falling since.
    var landedTotalsOnHomePass: HomeProjectionPolicy.Totals {
        HomeProjectionPolicy.landedTotals(
            roots: roots,
            looseSessions: looseSessions,
            unlandedSessionIDs: pendingOnHomePass
        )
    }

    @MainActor
    func landedTotals(with state: JarStageState) -> HomeProjectionPolicy.Totals {
        HomeProjectionPolicy.landedTotals(
            roots: roots,
            looseSessions: looseSessions,
            unlandedSessionIDs: state.unlandedSessionIDs(pendingOnHomePass: pendingOnHomePass)
        )
    }

    /// The landed loose sessions the jar's VoiceOver value counts (瓶の整理).
    func landedLoosePebbleCount(_ landed: HomeProjectionPolicy.Totals) -> Int {
        max(0, looseSessions.count - (savedTotals.pebbleCount - landed.pebbleCount))
    }

    /// A readout of these inputs with `landed` applied: the landed loose
    /// gems, and while verified the jar's headline, core and count
    /// (`HomeView.liveLifetimeReadout`). While iCloud is checked the headline
    /// is the pending one (sync-03), which no landing changes.
    func completing(
        _ readout: LifetimeReadoutContinuityPolicy.Readout,
        landed: HomeProjectionPolicy.Totals
    ) -> LifetimeReadoutContinuityPolicy.Readout {
        var readout = readout
        readout.jarLoosePebbles = landedLoosePebbleCount(landed)
        guard !readout.isCloudVerificationPending else { return readout }
        readout.jarGrams = landed.grams
        readout.jarCoreGrams = landed.grams
        readout.jarPebbles = landed.pebbleCount
        return readout
    }
}

/// The only views that observe `JarStageState`. Its body reads that state,
/// so a landing re-runs this reader and its content, never Home's body: the
/// content must take everything else from values Home resolved on its own
/// pass (`JarStageSnapshot`), not from Home's session projections, which
/// would re-derive every session on each landing.
///
/// The jar's own reader also remembers a readout of settled inputs
/// (`LifetimeReadoutContinuityPolicy`, device-verify-2 P2) as it presents
/// it, gems landed since Home's pass included, so a held readout is what
/// was on screen.
private struct JarStageReader<Content: View>: View {
    let state: JarStageState
    let stage: JarStageSnapshot
    var recordsSettledReadout = false
    @ViewBuilder let content: (LifetimeReadoutContinuityPolicy.Readout) -> Content

    var body: some View {
        let readout = stage.presentedReadout(with: state)
        if recordsSettledReadout {
            // Unobserved: what is on screen now, kept for a later pass.
            stage.settledRecord?.record(readout)
        }
        return content(readout)
    }
}

/// The lifetime mass on Home. The jar's readout sets the number apart from
/// its unit (「2.6」 kg) and the menu's 累計 reads them as one (「2.6kg」); one
/// rule for both, so the menu no longer says 「2.60kg」 or 「3kg」 under a
/// readout of 2.6 or 3.0 kg (device-verify-2 P7, after review). Grams below
/// a kilogram; above, one decimal, or two when the second is not zero.
enum HomeLifetimeMassText {
    static let kilogramFractionDigits = 1 ... 2

    /// The readout's number: 「250」「2.6」「3.0」「2.63」.
    static func readoutNumber(_ grams: Int, locale: Locale = PomoGemLocale.current) -> String {
        grams < 1_000
            ? PomoGemLocale.grouped(grams, locale: locale)
            : MassText.kilogramsNumber(fromGrams: grams, fractionDigits: kilogramFractionDigits, locale: locale)
    }

    /// The menu's 累計: 「250g」「2.6kg」「3.0kg」「2.63kg」.
    static func text(_ grams: Int, locale: Locale = PomoGemLocale.current) -> String {
        grams < 1_000
            ? MassText.grams(value: grams, locale: locale)
            : MassText.kilograms(fromGrams: grams, fractionDigits: kilogramFractionDigits, locale: locale)
    }
}

/// Runs Home's follow-up to a landing once the jar has settled
/// (`HomeView.scheduleLandingSettle`). A plain reference kept in `@State`, so
/// scheduling from the landing callback never invalidates Home. Each landing
/// restarts the wait, so a run of gems settles once.
@MainActor
final class LandingSettleScheduler {
    private var task: Task<Void, Never>?

    func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            do { try await Task.sleep(for: delay) } catch { return }
            work()
        }
    }
}

/// Home's jar values, resolved once per Home pass for the stage inside
/// `JarStageReader` (device-verify-2 P4).
private struct JarStageSnapshot {
    /// The lifetime readout Home's pass presents (`presentedLifetime`).
    let readout: LifetimeReadoutContinuityPolicy.Readout
    /// For a readout of live inputs, what the stage completes it with as
    /// gems land; nil for a held or loading readout, which stays as it is.
    let landing: JarLandedTotalsInputs?
    /// Where the stage remembers a readout of settled inputs; nil otherwise.
    let settledRecord: SettledRecord?
    let uniqueAchievementCount: Int
    let accentHex: String
    let inspectableAggregateID: UUID?
    let aggregateInspectionSummary: AccumulationClusterSummary?

    /// Home's `lastSettledLifetimeReadout` and the reset epoch its readout
    /// describes.
    struct SettledRecord {
        let box: SettledLifetimeReadoutBox
        let epochID: UUID?

        @MainActor
        func record(_ readout: LifetimeReadoutContinuityPolicy.Readout) {
            box.value = .init(readout: readout, epochID: epochID)
        }
    }

    /// The readout with the gems that have landed, or started falling, since
    /// Home's pass. Reads `state` only for live inputs, so a held readout's
    /// stage does not re-run on a landing.
    @MainActor
    func presentedReadout(with state: JarStageState) -> LifetimeReadoutContinuityPolicy.Readout {
        guard let landing else { return readout }
        return landing.completing(readout, landed: landing.landedTotals(with: state))
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

/// Copy for the completion card (Docs/GemExperienceDesign.md §8.3,
/// walk-std-07/08, product-05): time first and grams second, one localized
/// sentence per line, and the mechanics kept for 「しくみ」.
enum CompletionCardPresentation {
    /// 「英語 25分 → +250gの一粒」. The theme name is the person's own text.
    static func mainLine(subjectName: String, grams: Int) -> String {
        String(
            localized: "\(subjectName) \(focusDuration(grams: grams)) → +\(mass(grams: grams))の一粒",
            table: "Home",
            comment: "Completion card main line. %1$@ is the theme name (user data, never translated), %2$@ the focus time (25分), %3$@ the gem's mass (250g). en: '%1$@ %2$@ → a +%3$@ gem'"
        )
    }

    /// VoiceOver: 「英語、25分、250グラムの一粒。」 (one sentence).
    static func spokenMainLine(subjectName: String, grams: Int) -> String {
        String(
            localized: "\(subjectName)、\(DurationText.spoken(minutes: DurationPresentation.focusMinutes(grams: grams)))、\(MassText.spoken(grams: max(0, grams)))の一粒。",
            table: "Home",
            comment: "VoiceOver: the completion card main line. %1$@ theme name (user data), %2$@ spoken focus time, %3$@ spoken mass. en: '%1$@, %2$@, a %3$@ gem'"
        )
    }

    /// 「今週の実測 1時間15分」, or 「今週の実測 1時間15分・自己申告 30分」
    /// when the week holds self-reported focus.
    static func weekLine(measuredGrams: Int, selfReportedGrams: Int) -> String {
        let measured = focusDuration(grams: measuredGrams)
        guard selfReportedGrams > 0 else {
            return String(
                localized: "今週の実測 \(measured)",
                table: "Home",
                comment: "Completion card: this calendar week's measured focus time (timer and Screen Time). en: 'This week, measured: %@'"
            )
        }
        return String(
            localized: "今週の実測 \(measured)・自己申告 \(focusDuration(grams: selfReportedGrams))",
            table: "Home",
            comment: "Completion card: this calendar week's measured focus time, then its self-reported focus time. en: 'This week, measured: %1$@ · self-reported: %2$@'"
        )
    }

    /// VoiceOver form of `weekLine`, one sentence.
    static func spokenWeekLine(measuredGrams: Int, selfReportedGrams: Int) -> String {
        let measured = DurationText.spoken(minutes: DurationPresentation.focusMinutes(grams: measuredGrams))
        guard selfReportedGrams > 0 else {
            return String(
                localized: "今週の実測は\(measured)。",
                table: "Home",
                comment: "VoiceOver: this week's measured focus time on the completion card"
            )
        }
        return String(
            localized: "今週の実測は\(measured)、自己申告は\(DurationText.spoken(minutes: DurationPresentation.focusMinutes(grams: selfReportedGrams)))。",
            table: "Home",
            comment: "VoiceOver: this week's measured, then self-reported, focus time on the completion card"
        )
    }

    static func spokenBreakAvailability(minutes: Int) -> String {
        String(
            localized: "\(minutes)分休憩を利用できます。",
            table: "Home",
            comment: "VoiceOver: the break the completion card offers. %lld is minutes"
        )
    }

    /// The focus time a mass stands for (「25分」, 「1時間15分」).
    static func focusDuration(grams: Int) -> String {
        DurationText.short(minutes: DurationPresentation.focusMinutes(grams: grams))
    }

    /// 「250g」, 「1.8kg」, 「2.5kg」: grams below a kilogram, otherwise up to
    /// two decimals without trailing zeros.
    static func mass(grams rawGrams: Int) -> String {
        let grams = max(0, rawGrams)
        guard grams >= 1_000 else { return MassText.grams(String(grams)) }
        var kilograms = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(grams) / 1_000)
        while kilograms.hasSuffix("0") { kilograms.removeLast() }
        if kilograms.hasSuffix(".") { kilograms.removeLast() }
        return MassText.kilograms(kilograms)
    }

    // MARK: Rare and multi-draw outcomes

    /// 「250gごとの抽選2回（通常1・金1）」 for a focus with more than one
    /// 250 g draw, 「この一粒は金の粒」 for a single rare gem, nil for an
    /// ordinary single gem. The card names what the colour alone would
    /// only hint at (quiet mode paints the theme colour).
    static func rareLine(kind: PebbleKind, counts: RareRewardCounts) -> String? {
        if counts.drawCount > 1 {
            return String(
                localized: "\(MassText.grams(String(Constants.Mass.measuredPebbleGrams)))ごとの抽選\(counts.drawCount)回（\(ListText.compact(drawParts(counts)))）",
                table: "Home",
                comment: "Completion card: a long focus drew once per 250 g. %1$@ is 250g, %2$lld the draws, %3$@ the outcomes (通常1・金1). en: 'One draw per %1$@: %2$lld (%3$@)'"
            )
        }
        switch kind {
        case .normal:
            return nil
        case .gold:
            return String(localized: "この一粒は金の粒", table: "Home",
                          comment: "Completion card: this focus's gem is a gold gem. en: 'This gem is a gold gem'")
        case .prism:
            return String(localized: "この一粒は虹の粒", table: "Home",
                          comment: "Completion card: this focus's gem is a rainbow gem. en: 'This gem is a rainbow gem'")
        }
    }

    /// VoiceOver form of `rareLine`, one sentence.
    static func spokenRareLine(kind: PebbleKind, counts: RareRewardCounts) -> String? {
        if counts.drawCount > 1 {
            return String(
                localized: "\(MassText.spoken(grams: Constants.Mass.measuredPebbleGrams))ごとの抽選が\(counts.drawCount)回あり、内訳は\(ListText.inSentence(drawParts(counts)))です。",
                table: "Home",
                comment: "VoiceOver: the draws of a long focus. %1$@ is 250 grams (spoken), %2$lld the draws, %3$@ the outcomes as a list"
            )
        }
        switch kind {
        case .normal:
            return nil
        case .gold:
            return String(localized: "この一粒は金の粒です。", table: "Home",
                          comment: "VoiceOver: this focus's gem is a gold gem")
        case .prism:
            return String(localized: "この一粒は虹の粒です。", table: "Home",
                          comment: "VoiceOver: this focus's gem is a rainbow gem")
        }
    }

    private static func drawParts(_ counts: RareRewardCounts) -> [String] {
        [
            counts.normalCount > 0
                ? String(localized: "通常\(counts.normalCount)", table: "Home",
                         comment: "Completion card: ordinary gems among a long focus's draws. %lld is the count. en: 'Standard %lld'")
                : nil,
            counts.goldCount > 0
                ? String(localized: "金\(counts.goldCount)", table: "Home",
                         comment: "Completion card: gold gems among a long focus's draws. %lld is the count. en: 'Gold %lld'")
                : nil,
            counts.prismCount > 0
                ? String(localized: "虹\(counts.prismCount)", table: "Home",
                         comment: "Completion card: rainbow gems among a long focus's draws. %lld is the count. en: 'Rainbow %lld'")
                : nil
        ].compactMap { $0 }
    }

    // MARK: 「明日もこの時間に？」 (D18)

    /// Only the jar's very first completion offers the reminder, only when
    /// that is certain (a lower-bound projection may hide earlier gems), and
    /// only while no reminder time has been chosen: neither the daily
    /// reminder nor 先月の瓶のお知らせ (which shares its time) is on
    /// (Docs/GemExperienceDesign.md §4.2: 「既存のリマインダーがあれば出さない」).
    static func offersReminder(
        fusionState: FusionRewardBridgeState,
        projectionIsLowerBound: Bool,
        reminderTimeIsChosen: Bool
    ) -> Bool {
        !reminderTimeIsChosen && !projectionIsLowerBound && fusionState.totalPebbleCount == 1
    }

    /// 「7:30」 in the person's locale.
    static func reminderTimeLabel(_ date: Date, locale: Locale = PomoGemLocale.current) -> String {
        date.formatted(.dateTime.hour().minute().locale(locale))
    }

    /// What the row offers, as a thing rather than a promise: nothing is
    /// on until the person taps 「オンにする」.
    static func reminderOfferDetail(time: String) -> String {
        String(
            localized: "毎日 \(time) のリマインダー",
            table: "Home",
            comment: "First completion card, under 「明日もこの時間に？」: the reminder a tap would turn on (it is off). %@ is a time of day (7:30). en: 'Daily reminder at %@'"
        )
    }

    static func spokenReminderOfferDetail(time: String) -> String {
        String(
            localized: "毎日 \(time) のリマインダー。今はオフです",
            table: "Home",
            comment: "VoiceOver value of the first completion card's reminder offer. %@ is a time of day"
        )
    }

    static func reminderScheduled(time: String) -> String {
        String(
            localized: "毎日 \(time) にお知らせします。設定でいつでも変えられます。",
            table: "Home",
            comment: "First completion card after the reminder was turned on. %@ is a time of day. en: 'I'll remind you daily at %@. You can change this in Settings.'"
        )
    }

    /// iOS has notifications off: nothing was turned on, and the row comes
    /// back as an offer once they are allowed.
    static var reminderNeedsPermission: String {
        String(
            localized: "通知がオフになっています。設定で許可したあと、ここでもう一度「オンにする」を押せます。",
            table: "Home",
            comment: "First completion card when iOS notifications are off for PomoGem; after allowing them the offer returns"
        )
    }

    static func reminderOutcome(_ phase: CompletionReminderOffer.Phase) -> String {
        switch phase {
        case .alreadyOn:
            String(localized: "毎日のリマインダーは、すでにオンです。時刻は設定で変えられます。", table: "Home",
                   comment: "First completion card: the daily reminder was already on, so the offer changed nothing")
        case .scheduleFailed:
            String(localized: "リマインダーはオンにしましたが、通知を予約できませんでした。設定で確かめてください。", table: "Home",
                   comment: "First completion card: the reminder switch was saved but iOS did not book the notification")
        default:
            String(localized: "リマインダーを保存できませんでした。設定からも選べます。", table: "Home",
                   comment: "First completion card: the reminder could not be saved")
        }
    }

    // MARK: 「しくみ」

    struct Mechanics: Equatable {
        /// 「時間の核まで あと3時間45分」, or nil for a receipt without mass.
        let coreLine: String?
        let coreFraction: Double?
        let unitLine: String?
        let jarLine: String
        let weekCountLine: String?
    }

    static func mechanics(
        effortProgress: EffortProgressSnapshot?,
        fusionState: FusionRewardBridgeState,
        projectionIsLowerBound: Bool,
        grams: Int,
        weeklyTimerCompletionCount: Int
    ) -> Mechanics {
        Mechanics(
            coreLine: effortProgress.map { coreLine($0, projectionIsLowerBound: projectionIsLowerBound) },
            coreFraction: projectionIsLowerBound ? nil : effortProgress.map {
                $0.crossedMilestoneGrams == nil ? $0.progressFraction : 1
            },
            unitLine: effortProgress == nil ? nil : String(
                localized: "時間の核は、粒の数ではなく集中した時間で進みます。25分が1.0標準単位で、今回は\(standardUnits(grams: grams))標準単位です。",
                table: "Home",
                comment: "Completion card 「しくみ」: the time core counts time, not gems; 25 minutes is one standard unit. %@ is this focus in standard units (1.0)"
            ),
            jarLine: jarLine(fusionState, projectionIsLowerBound: projectionIsLowerBound),
            weekCountLine: weeklyTimerCompletionCount > 0 ? String(
                localized: "今週のタイマー完走は\(weeklyTimerCompletionCount)回です。回数は時間の価値とは別です。",
                table: "Home",
                comment: "Completion card 「しくみ」: timer completions this calendar week, a frequency cue only. %lld is the count"
            ) : nil
        )
    }

    /// The core's progress in plain words. The birth of the first core is
    /// never said here: the card's face or the fusion sheet says it, once
    /// (`coreBirthMoment`), so this line only says how far its next growth is.
    private static func coreLine(_ snapshot: EffortProgressSnapshot, projectionIsLowerBound: Bool) -> String {
        guard !projectionIsLowerBound else {
            return String(localized: "時間の核の進みを確認しています", table: "Home",
                          comment: "Completion card 「しくみ」 while the lifetime total is being checked")
        }
        if snapshot.crossedMilestoneGrams != nil {
            let next = remainingDuration(grams: snapshot.nextTargetGrams - snapshot.totalGrams)
            if snapshot.displayedTargetLevel <= 1 {
                return String(localized: "集中した時間があと\(next)たまると、時間の核はさらに育ちます", table: "Home",
                              comment: "Completion card 「しくみ」 when this focus brought the first time core (the card's face or the fusion sheet says so). %@ is the focus time until the core grows again. en: 'After %@ more of focus, your time core grows again'")
            }
            return String(localized: "時間の核が育ち、\(snapshot.displayedTargetLevel)段目になりました。集中した時間があと\(next)たまると、さらに育ちます", table: "Home",
                          comment: "Completion card 「しくみ」: this focus grew the time core. %1$lld is its new level (the jar labels it 時間の核・二段目…), %2$@ the focus time until it grows again. en: 'Your time core grew to level %1$lld. After %2$@ more of focus, it grows again'")
        }
        let remaining = remainingDuration(grams: snapshot.remainingGrams)
        if snapshot.displayedTargetLevel <= 1 {
            return String(localized: "時間の核まで あと\(remaining)", table: "Home",
                          comment: "Completion card 「しくみ」: focus time left until the first time core. %@ is a duration")
        }
        return String(localized: "時間の核の\(snapshot.displayedTargetLevel)段目まで あと\(remaining)", table: "Home",
                      comment: "Completion card 「しくみ」: focus time left until the time core's next level. %1$lld is the level, %2$@ a duration")
    }

    private static func jarLine(_ state: FusionRewardBridgeState, projectionIsLowerBound: Bool) -> String {
        guard !projectionIsLowerBound else {
            return String(localized: "粒は1回の完走につき1つです。結晶までの数は、確認が済むと表示します。", table: "Home",
                          comment: "Completion card 「しくみ」 while the gem count is being checked")
        }
        if state.isFusionComplete {
            return String(localized: "粒は1回の完走につき1つです。この一粒で10粒がそろい、瓶の中でひとつの結晶になります。記録と重さはそのままです。", table: "Home",
                          comment: "Completion card 「しくみ」: this gem completes ten, which fuse into one crystal; nothing is lost")
        }
        let remaining = max(1, state.immediateHorizon.remainingPebbleCount)
        return String(localized: "粒は1回の完走につき1つです。10粒そろうと、瓶の中でひとつの結晶にまとまります（記録と重さはそのまま）。次の結晶まで あと\(remaining)粒。", table: "Home",
                      comment: "Completion card 「しくみ」: ten gems fuse into one crystal; %lld gems to the next crystal")
    }

    /// Minutes rounded up, so 「あと」 never claims less than is left.
    private static func remainingDuration(grams: Int) -> String {
        let minutes = (max(0, grams) + Constants.Mass.gramsPerMinute - 1) / Constants.Mass.gramsPerMinute
        return DurationText.short(minutes: minutes)
    }

    /// 「1.0」, 「0.4」, 「2.4」 (at least one decimal, at most two).
    static func standardUnits(grams: Int) -> String {
        var value = String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            EffortProgressPolicy.standardUnitEquivalent(totalGrams: grams)
        )
        while value.hasSuffix("0"), !value.hasSuffix(".0") { value.removeLast() }
        return value
    }

    // MARK: The time core's one teaching moment (product-05)

    enum CoreBirthMoment: Equatable {
        /// This completion did not bring the first time core.
        case none
        /// It brought the core but not together with the first ×10 (a
        /// 50-minute fifth gem, a 15-minute seventeenth): the card says so.
        case card
        /// It made the first ×10 and the core together (ten 25-minute gems):
        /// that crystal's fusion sheet says so.
        case fusionSheet
    }

    /// Where the birth of the first time core is taught: once, on the card
    /// of the completion that crossed it, or on the fusion sheet when the
    /// same completion made the first ×10. A lower bound never claims it.
    static func coreBirthMoment(
        effortProgress: EffortProgressSnapshot?,
        fusionState: FusionRewardBridgeState,
        projectionIsLowerBound: Bool
    ) -> CoreBirthMoment {
        guard !projectionIsLowerBound,
              let effortProgress,
              effortProgress.crossedMilestoneGrams == EffortProgressPolicy.firstMilestoneGrams
        else { return .none }
        let madeFirstCrystal = fusionState.totalPebbleCount == FusionHierarchyPresentation.fanIn
            && fusionState.completedFusionLevels == [1]
        return madeFirstCrystal ? .fusionSheet : .card
    }

    /// The card's form of the fusion sheet's line (no 「10粒で」: the core
    /// came from time, however many gems carried it).
    static var coreBirthOnCard: String {
        String(
            localized: "時間の核が生まれました。これからは核が、積み上げた時間の重さを表します。",
            table: "Home",
            comment: "Completion card, once: this focus brought the first time core (without a fusion). en: 'Your time core is born. From now on it shows the weight of the time you have built up.'"
        )
    }

    /// Ends a sentence that was composed elsewhere (VoiceOver accounting),
    /// with the language's own full stop.
    static func sentence(_ text: String) -> String {
        String(
            localized: "\(text)。",
            table: "Home",
            comment: "VoiceOver: ends a sentence built elsewhere. %@ is the sentence without its final punctuation. en: '%@.'"
        )
    }
}

/// product-05: the card of the completion that made the first ×10 and the
/// time core together was acknowledged; that crystal's sheet teaches, once.
private struct CoreBirthTeachingPending: Equatable {
    let receiptID: UUID
    let acknowledgedAt: Date
    let epochID: UUID?
}

/// D18: where the first completion card's 「明日もこの時間に？」 stands.
struct CompletionReminderOffer: Equatable {
    enum Phase: Equatable {
        case offered
        case working
        case scheduled
        /// The daily reminder was on by the time of the tap: nothing moved.
        case alreadyOn
        /// iOS has notifications off; the offer returns once they are allowed.
        case needsSettings
        /// The switch was saved but the notification could not be booked.
        case scheduleFailed
        case failed
        case dismissed
    }

    let offerID: UUID
    let phase: Phase
}

/// The completion card's hero (§8.3): this focus's own gem in the jar's art,
/// the same theme tone, loose cut and UUID variant as the gem that drops,
/// with its halo. 標準 adds one glint as the card arrives (never a loop);
/// Reduce Motion and 演出の強さ＝控えめ keep it still.
private struct CompletionCardHero: View {
    let sessionID: UUID
    let colorHex: String

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.pomogemReduceMotionOverride) private var reduceMotionOverride
    @AppStorage(JarEffectsIntensity.defaultsKey) private var effectsIntensity: JarEffectsIntensity = .standard
    @State private var glintIsLit = false

    private var effects: JarEffectsIntensity {
        .resolved(preference: effectsIntensity, reduceMotion: reduceMotionOverride ?? systemReduceMotion)
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                // The halo reaches 1.4× the stone: stone and halo fill the frame.
                GemArtworkStone(
                    spec: GemArtworkStone.looseSpec(hex: colorHex, variant: GemArtworkSpec.variant(for: sessionID)),
                    glowHex: colorHex,
                    glowOpacity: 0.5 * Double(effects.haloScale)
                )
                .frame(width: side * 0.7, height: side * 0.7)
                if !effects.isSubtle {
                    Image(uiImage: GemArtwork.glintImage)
                        .resizable()
                        .frame(width: side * 0.46, height: side * 0.46)
                        .blendMode(.plusLighter)
                        .scaleEffect(glintIsLit ? 1 : 0.2)
                        .rotationEffect(.degrees(glintIsLit ? 18 : -12))
                        .opacity(glintIsLit ? 0.95 : 0)
                        .offset(x: -side * 0.13, y: -side * 0.14)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .task(id: sessionID) { await playGlint() }
    }

    /// One glint, once: it catches the light and goes.
    @MainActor
    private func playGlint() async {
        glintIsLit = false
        guard !effects.isSubtle else { return }
        try? await Task.sleep(for: .milliseconds(520))
        guard !Task.isCancelled, !effects.isSubtle else { return }
        withAnimation(.easeOut(duration: 0.32)) { glintIsLit = true }
        try? await Task.sleep(for: .milliseconds(360))
        guard !Task.isCancelled else { return }
        withAnimation(.easeIn(duration: 0.62)) { glintIsLit = false }
    }
}

/// 「しくみ」 (walk-std-08, product-05): the mechanics of gems, crystals and
/// the time core, collapsed under one quiet row on the completion card and
/// the fusion sheet. It is one accessibility element that always carries
/// the full accounting, open or not.
private struct MechanicsDisclosure<Content: View>: View {
    @Binding var isExpanded: Bool
    let accessibilityAccounting: String
    var accentHex: String?
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.pomogemReduceMotionOverride) private var reduceMotionOverride

    var body: some View {
        Button {
            withAnimation((reduceMotionOverride ?? systemReduceMotion) ? nil : .easeInOut(duration: 0.22)) {
                isExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accentHex.map { Color(hex: $0) } ?? PomoGemTheme.amber)
                    Text("しくみ", tableName: "Home",
                         comment: "Disclosure that opens how gems, crystals and the time core work. en: 'How it works'")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PomoGemTheme.text)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PomoGemTheme.muted)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .frame(minHeight: 44)
                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        content()
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PomoGemTheme.raised.opacity(0.62), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PomoGemBareButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            localized: "しくみ。\(accessibilityAccounting)",
            table: "Home",
            comment: "VoiceOver label of the 「しくみ」 disclosure; %@ is its full accounting, read whether it is open or not"
        ))
        .accessibilityValue(isExpanded
            ? String(localized: "開いています", table: "Home", comment: "VoiceOver value: the 「しくみ」 disclosure is open")
            : String(localized: "閉じています", table: "Home", comment: "VoiceOver value: the 「しくみ」 disclosure is closed"))
        .accessibilityHint(Text("説明の表示を切り替えます", tableName: "Home",
                                comment: "VoiceOver hint: toggles the 「しくみ」 disclosure"))
        .accessibilityAddTraits(.isButton)
    }
}

/// product-05: the fusion sheet's one teaching line is for a ×10 made of
/// ten gems (which one is decided by the acknowledged card's session).
enum StratumCelebrationTeaching {
    static func isTenGemCrystal(_ request: PendingStratumCelebration) -> Bool {
        request.pebbleCount == FusionHierarchyPresentation.fanIn && max(1, request.level ?? 1) == 1
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

/// sync-03. The completion card's weekly heading re-derived from a verified
/// projection, for one offer and one verified epoch.
private struct RestampedWeeklyMetrics: Equatable {
    struct Request: Equatable {
        let offerID: UUID
        let stamp: AggregateProjectionCacheStamp
    }

    let request: Request
    let completionCount: Int
    let studyGrams: Int?
    let selfReportedGrams: Int

    func matches(offer id: UUID, stamp: AggregateProjectionCacheStamp?) -> Bool {
        request.offerID == id && request.stamp == stamp
    }
}

private struct BreakOffer: Identifiable {
    let id: UUID
    let createdAt: Date
    let minutes: Int
    let grams: Int
    let subjectName: String
    let colorHex: String
    private(set) var weeklyCompletionCount: Int
    private(set) var weeklyStudyGrams: Int?
    /// walk-std-07. Read live from the completion's calendar week when the
    /// card opens (the receipt predates it); never persisted.
    private(set) var weeklySelfReportedGrams = 0
    let kind: PebbleKind
    let rareRewardCounts: RareRewardCounts
    private(set) var fusionState: FusionRewardBridgeState
    private(set) var effortProgress: EffortProgressSnapshot?
    private(set) var projectionIsLowerBound: Bool
    private(set) var projectionWasCloudUnverified: Bool
    private(set) var projectionCacheStamp: AggregateProjectionCacheStamp?
    let isAwaitingDrop: Bool

    /// sync-03. The same offer re-derived from a verified projection that
    /// already contains this focus's session; the saved receipt is unchanged.
    func restamped(
        totalGrams: Int,
        totalPebbles: Int,
        projectionIsLowerBound: Bool,
        stamp: AggregateProjectionCacheStamp?,
        weekly: RestampedWeeklyMetrics? = nil
    ) -> BreakOffer {
        var copy = self
        if let weekly, weekly.request.offerID == id {
            copy.weeklyCompletionCount = weekly.completionCount
            copy.weeklyStudyGrams = weekly.studyGrams
            copy.weeklySelfReportedGrams = weekly.selfReportedGrams
        }
        copy.fusionState = FusionRewardBridgePresentation.state(totalPebbleCount: max(1, totalPebbles))
        copy.effortProgress = EffortProgressPolicy.snapshot(
            totalGrams: max(grams, totalGrams),
            latestContributionGrams: grams
        )
        copy.projectionIsLowerBound = projectionIsLowerBound
        copy.projectionWasCloudUnverified = false
        copy.projectionCacheStamp = stamp
        return copy
    }

    init(receipt: PendingRewardReceipt) {
        isAwaitingDrop = receipt.requiresDrop
        id = receipt.id
        createdAt = receipt.createdAt
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

    /// walk-std-07. The week's self-reported focus from the same calendar
    /// week and query as the frozen measured figure. A timer completion that
    /// was demoted to self-reported leaves the measured figure, which the
    /// receipt counted it in, and is named as self-reported instead.
    mutating func applyWeeklySelfReport(grams: Int, includesThisCompletion: Bool) {
        weeklySelfReportedGrams = max(0, grams)
        if includesThisCompletion, let measured = weeklyStudyGrams {
            weeklyStudyGrams = max(0, measured - self.grams)
        }
    }

    /// 「今週の実測 1時間15分・自己申告 30分」. A receipt from a build
    /// before the weekly mass was saved has no line.
    var weeklyTitle: String? {
        weeklyStudyGrams.map {
            CompletionCardPresentation.weekLine(measuredGrams: $0, selfReportedGrams: weeklySelfReportedGrams)
        }
    }

    var weeklySpokenTitle: String? {
        weeklyStudyGrams.map {
            CompletionCardPresentation.spokenWeekLine(measuredGrams: $0, selfReportedGrams: weeklySelfReportedGrams)
        }
    }
}

/// settings-04. The fusion sheet's quiet link to Pro's month label, for a
/// free user who has just made the kind of crystal it applies to.
struct MonthLabelHint {
    let onShown: () -> Void
    let onOpen: () -> Void
}

/// The fusion sheet (Docs/GemExperienceDesign.md §8.3, D8): 「10粒ぶんの時間
/// が、ひとつの結晶に。」 over the new crystal with its ten sources in a
/// shallow bowl beneath it, 「重さはそのまま 2.50kg」, and the mechanics
/// behind 「しくみ」. Nothing covers the art. The first ×10 that also made the
/// time core says so, once (product-05). On a short screen the art shrinks
/// so the actions stay in the first viewport; at accessibility sizes the
/// actions come right after the two lines and the art follows them.
private struct StratumCelebrationView: View {
    let request: PendingStratumCelebration
    /// The crystal's colour shares; empty uses the receipt's colour.
    let colorShares: [GemColorShare]
    let showsMonthLabel: Bool
    /// product-05: this is the first ×10 and the same completion made the
    /// time core.
    var teachesCoreBirth = false
    let onExplore: () -> Void
    let onShare: () -> Void
    let onContinue: () -> Void
    var monthLabelHint: MonthLabelHint?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var mechanicsExpanded = false
    /// The height of what shares the first viewport with the art.
    @State private var leadHeight: CGFloat = 0

    private static let largestArt: CGFloat = 256
    private static let smallestArt: CGFloat = 120

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
            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: sectionSpacing) {
                        if dynamicTypeSize.isAccessibilitySize {
                            // A small crystal leads, whole, in the room the
                            // lines and the actions leave on the first screen
                            // (the 4.7-inch SE at AX5 included); the teaching
                            // line follows the actions directly.
                            celebrationStage(
                                side: artSide(viewportHeight: viewport.size.height, minimum: 52, maximum: 120),
                                framed: false
                            )
                            VStack(spacing: sectionSpacing) {
                                celebrationLines
                                celebrationActions
                            }
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { leadHeight = $0 }
                            coreBirthLine
                        } else {
                            celebrationStage(side: artSide(viewportHeight: viewport.size.height))
                            VStack(spacing: 18) {
                                celebrationLines
                                coreBirthLine
                                celebrationActions
                            }
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { leadHeight = $0 }
                        }
                        celebrationStats
                        celebrationMechanics
                        // settings-04: last, small and muted, below every
                        // celebration action. Layout owned by the gem session;
                        // this adds one row and restyles nothing above it.
                        if let monthLabelHint {
                            monthLabelHintLink(monthLabelHint)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .padding(.top, topPadding)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .background(NightBackground())
            // Scrolled content passes under a solid bar, not under the bare
            // 閉じる. Opaque: iOS 26 let a 0.94 bar show the headline and the
            // source gems legibly through it.
            .toolbarBackground(PomoGemTheme.background, for: .navigationBar)
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

    /// Accessibility sizes keep the gaps tight: on the 4.7-inch SE at AX5
    /// the art, both lines and all three actions share one screen.
    private var sectionSpacing: CGFloat { dynamicTypeSize.isAccessibilitySize ? 12 : 18 }
    private var topPadding: CGFloat { dynamicTypeSize.isAccessibilitySize ? 8 : 24 }

    /// The art takes what the first viewport has left after the lines and
    /// the actions, within `minimum`…`maximum`.
    private func artSide(
        viewportHeight: CGFloat,
        minimum: CGFloat = smallestArt,
        maximum: CGFloat = largestArt
    ) -> CGFloat {
        // Top padding, the gap under the art and a little air at the bottom.
        let room = viewportHeight - leadHeight - topPadding - sectionSpacing - 10
        return min(maximum, max(minimum, room.rounded(.down)))
    }

    /// The new crystal in the jar's art with its ten sources in a shallow
    /// bowl beneath it (no ring, no spokes, nothing over the gems). Small
    /// (accessibility sizes) it drops the framed stage for a soft glow, so
    /// a short frame never reads as a cut-off panel.
    private func celebrationStage(side: CGFloat, framed: Bool = true) -> some View {
        ZStack {
            if framed {
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
                            endRadius: side * 0.66
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color(hex: colorHex).opacity(0.30), lineWidth: 1)
                    }
            } else {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: colorHex).opacity(0.24), .clear],
                            center: .center,
                            startRadius: 2,
                            endRadius: side * 0.62
                        )
                    )
                    .frame(width: side * 1.3, height: side * 1.3)
            }

            FusionOrbitStage(
                state: orbitState,
                colorHex: colorHex,
                scale: .hero,
                destinationGrams: request.grams,
                colorShares: colorShares
            )
            .frame(width: side * (framed ? 0.86 : 1), height: side * (framed ? 0.86 : 1))
            // The bowl hangs low in the stage; keep it clear of the edge.
            .offset(y: framed ? -side * 0.02 : 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level == 1
            ? String(localized: "新しい結晶。その下に、もとになった\(FusionHierarchyPresentation.fanIn)粒", table: "Home",
                     comment: "VoiceOver: the fusion sheet art, a new ×10 crystal over its source gems. %lld is 10")
            : String(localized: "新しい結晶。その下に、もとになった\(FusionHierarchyPresentation.fanIn)個の結晶", table: "Home",
                     comment: "VoiceOver: the fusion sheet art, a larger crystal over its source crystals. %lld is 10"))
    }

    private var celebrationLines: some View {
        VStack(spacing: 6) {
            // The line break keeps 「結晶」 whole on a phone.
            Text("\(request.pebbleCount)粒ぶんの時間が、\nひとつの結晶に。", tableName: "Home",
                 comment: "Fusion sheet headline, two lines. %lld is the gems the new crystal holds (10). en: 'The time of %lld gems,\\nin one crystal.'")
                .font(PomoGemTheme.brand(24))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("fusion.celebration.title")
            Text(String(
                localized: "重さはそのまま \(Self.massLabel(grams: request.grams))",
                table: "Home",
                comment: "Fusion sheet subline: the crystal weighs what its gems did. %@ is a mass (2.50kg). en: 'Same weight: %@'"
            ))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PomoGemTheme.muted)
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .accessibilityIdentifier("fusion.celebration.mass")
        }
        .frame(maxWidth: .infinity)
    }

    /// product-05. The one teaching moment: said on this sheet and no other.
    @ViewBuilder
    private var coreBirthLine: some View {
        if teachesCoreBirth {
            Text("10粒で、時間の核が生まれました。これからは核が、積み上げた時間の重さを表します。", tableName: "Home",
                 comment: "Fusion sheet, only when the first crystal and the first time core arrive together")
                .font(.callout.weight(.semibold))
                .foregroundStyle(PomoGemTheme.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                // The headline's ceiling: never larger than what it explains.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    Color(hex: colorHex).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(hex: colorHex).opacity(0.26), lineWidth: 0.8)
                }
                .accessibilityIdentifier("fusion.celebration.core-birth")
        }
    }

    private var celebrationActions: some View {
        VStack(spacing: 12) {
            Button(action: onExplore) {
                celebrationActionLabel(Text("この結晶の内訳を見る", tableName: "Home",
                                            comment: "Fusion sheet primary action: opens the new crystal's breakdown"))
            }
            .buttonStyle(PomoGemPrimaryButtonStyle())
            Button(action: onShare) {
                celebrationActionLabel(Text("この結晶をカードにする", tableName: "Home",
                                            comment: "Fusion sheet action: makes a share card of the new crystal"))
            }
            .buttonStyle(PomoGemSecondaryButtonStyle())
            Button("ここで休む", action: onContinue)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(PomoGemTheme.muted)
                .frame(minHeight: 44)
                .buttonStyle(PomoGemBareButtonStyle())
        }
    }

    /// Wrapped lines stay centred and clear of the button's edges at
    /// accessibility sizes, in both styles alike.
    private func celebrationActionLabel(_ text: Text) -> some View {
        text
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
    }

    private var celebrationMechanics: some View {
        let lines = [
            String(localized: "10粒がそろうと、瓶の中でひとつの結晶にまとまります。瓶を軽く保つための整理で、一粒ずつの時間も、\(Self.massLabel(grams: request.grams))の重さも、記録にそのまま残ります。", table: "Home",
                   comment: "Fusion sheet 「しくみ」: fusing ten gems keeps the jar light and loses nothing. %@ is the crystal's mass"),
            String(localized: "時間の核は、粒の数ではなく積み上げた時間で進みます。次へ急ぐ必要はありません。", table: "Home",
                   comment: "Fusion sheet 「しくみ」: the time core counts time, not gems; no need to hurry"),
            String(localized: "×10の結晶が10個そろうと、×100の結晶になります。", table: "Home",
                   comment: "Fusion sheet 「しくみ」: ten ×10 crystals make a ×100 crystal")
        ]
        return MechanicsDisclosure(
            isExpanded: $mechanicsExpanded,
            accessibilityAccounting: SentenceText.join(lines),
            accentHex: colorHex
        ) {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("fusion.celebration.mechanics")
    }

    private func monthLabelHintLink(_ hint: MonthLabelHint) -> some View {
        Button(action: hint.onOpen) {
            HStack(spacing: 4) {
                Text(
                    "Proなら、この\(AggregatePresentation.title(level: level))に「\(DateText.yearMonth(request.createdAt))」と刻めます",
                    tableName: "Home",
                    comment: "Fusion sheet link for free users; arguments: the crystal's name (結晶…), the month it was made (2026年9月)"
                )
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(.footnote)
            .foregroundStyle(PomoGemTheme.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PomoGemBareButtonStyle())
        .accessibilityHint(Text("ポモジェムProの説明を開きます", tableName: "Home", comment: "VoiceOver hint on the fusion sheet's Pro month-label link"))
        .accessibilityIdentifier("fusion.celebration.month-label-hint")
        .onAppear(perform: hint.onShown)
    }

    /// Time first, then the gems (or Pro's engraved month), then the size:
    /// 「時間 4時間10分」「粒 10粒」「結晶 ×10」.
    private var celebrationStats: some View {
        let tiles: [CelebrationTile] = [
            CelebrationTile(title: String(localized: "時間", table: "Home", comment: "Fusion sheet tile title: the focus time the crystal holds. en: 'Time'"),
                            value: DurationText.short(minutes: DurationPresentation.focusMinutes(grams: request.grams))),
            showsMonthLabel
                ? CelebrationTile(title: String(localized: "刻印", table: "Home", comment: "Fusion sheet tile title for Pro: the month engraved on the crystal. en: 'Engraving'"),
                                  value: request.monthLabel)
                : CelebrationTile(title: String(localized: "粒", table: "Home", comment: "Fusion sheet tile title: how many gems the crystal holds. en: 'Gems'"),
                                  value: CountText.gems(request.pebbleCount)),
            // The size, not the noun: the tile is titled 結晶 (round 12).
            CelebrationTile(title: String(localized: "結晶", table: "Home", comment: "Fusion sheet tile title: the crystal's size (×10). en: 'Crystal'"),
                            value: AggregatePresentation.countLabel(request.pebbleCount))
        ]
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    ForEach(tiles) { StatPill(title: $0.title, value: $0.value) }
                }
            } else {
                HStack(spacing: 10) {
                    ForEach(tiles) { StatPill(title: $0.title, value: $0.value) }
                }
            }
        }
    }

    /// 「2.50kg」 (two decimals: the crystal weighs exactly what its gems
    /// did), or 「100g」 under a kilogram.
    static func massLabel(grams rawGrams: Int) -> String {
        let grams = max(0, rawGrams)
        guard grams >= 1_000 else { return MassText.grams(String(grams)) }
        return MassText.kilograms(String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            Double(grams) / 1_000
        ))
    }
}

private struct CelebrationTile: Identifiable {
    let title: String
    let value: String
    var id: String { title }
}

private struct StatPill: View {
    let title: String
    let value: String
    var body: some View {
        VStack(spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(PomoGemTheme.muted)
            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG && targetEnvironment(simulator)
private extension View {
    /// The pinned AX5 of an explicit Debug UI-test launch, for a sheet
    /// (which does not inherit it from the root).
    @ViewBuilder
    func forwardingUITestAccessibility5() -> some View {
        if LocalPreviewLaunchPolicy.forcesAccessibility5(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: true
        ) {
            environment(\.dynamicTypeSize, .accessibility5)
        } else {
            self
        }
    }
}
#endif

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
/// Counts `HomeView.body` evaluations so a UI test can hold Home to its idle
/// budget: nothing re-renders it while nobody touches the phone. Observing a
/// periodically publishing object (as Home once did with the Screen Time
/// controller, re-rendering every three seconds) shows up here as a count
/// that keeps climbing. Debug builds only.
/// It also keeps the one-time jar hint's window frame: the hint is hidden
/// from accessibility (the jar speaks the same guidance), so a test cannot
/// otherwise check that it stays clear of the gem it describes. For the same
/// reason it keeps the readout's and the time core's window frames: both are
/// inside the jar's one accessibility element, and a test pins the tapped
/// crystal's card clear of them.
@MainActor
enum HomeRenderDiagnostics {
    private(set) static var bodyEvaluationCount = 0
    /// Gems that reported a landing to Home, and Home's body count at the
    /// last of them, so a UI test can tell how many re-renders a landing
    /// itself caused (device-verify-2 P4).
    private(set) static var landingCount = 0
    private(set) static var bodyEvaluationCountAtLastLanding = 0
    static var jarHintWindowFrame: CGRect?
    static var jarHUDWindowFrame: CGRect?
    /// The stone (or, before the core, its vessel) and the label block under it.
    static var jarCoreWindowFrame: CGRect?

    static func recordBodyEvaluation() {
        bodyEvaluationCount &+= 1
    }

    static func recordLanding() {
        landingCount &+= 1
        bodyEvaluationCountAtLastLanding = bodyEvaluationCount
    }

    /// Home's deferred follow-up to the landings (`settleLandings`) and
    /// Home's body count as it starts: equal to the count at the landing
    /// when the landing's own frames did not re-render Home.
    private(set) static var landingSettleCount = 0
    private(set) static var bodyEvaluationCountAtLastLandingSettle = 0

    static func recordLandingSettle() {
        landingSettleCount &+= 1
        bodyEvaluationCountAtLastLandingSettle = bodyEvaluationCount
    }
}

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
    /// The same target in window points. The jar's accessibility frame is
    /// wider than the SpriteKit view (its glow overflows), so a tap placed by
    /// normalized offset in that frame drifts right of the gem.
    @State private var targetWindowX: CGFloat = -1
    @State private var targetWindowY: CGFloat = -1
    @State private var dropSequence = 0
    @State private var dropFall: CGFloat = 0
    @State private var dropLanded = false
    /// Sampled from `HomeRenderDiagnostics`. Only this probe re-renders when
    /// it changes, so reading it cannot inflate the count it reports.
    @State private var homeBodyEvaluations = 0
    @State private var homeLandings = 0
    @State private var homeBodyEvaluationsAtLanding = 0
    @State private var homeLandingSettles = 0
    @State private var homeBodyEvaluationsAtSettle = 0
    @State private var jarHintFrame: CGRect?
    /// A resting crystal (×10 or larger) in window points, for a test that
    /// taps one to show its card; -1 while the jar holds none.
    @State private var crystalWindowX: CGFloat = -1
    @State private var crystalWindowY: CGFloat = -1
    @State private var hudFrame: CGRect?
    @State private var coreFrame: CGRect?
    /// The bottle (`JarScene.outerJarRect`): every gem rests inside it.
    @State private var bottleFrame: CGRect?

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
            format: "count=%d;maxY=%.3f;records=%@;bounceSequence=%d;bounceRise=%.3f;targetX=%.5f;targetY=%.5f;dropSequence=%d;dropFall=%.3f;dropLanded=%d;targetWindowX=%.1f;targetWindowY=%.1f;homeBodyEvaluations=%d;homeLandings=%d;homeBodyAtLanding=%d;homeSettles=%d;homeBodyAtSettle=%d;jarHint=%@;crystalWindowX=%.1f;crystalWindowY=%.1f;hud=%@;core=%@;bottle=%@",
            count,
            Double(maximumY),
            records,
            bounceSequence,
            Double(bounceRise),
            Double(targetX),
            Double(targetY),
            dropSequence,
            Double(dropFall),
            dropLanded ? 1 : 0,
            Double(targetWindowX),
            Double(targetWindowY),
            homeBodyEvaluations,
            homeLandings,
            homeBodyEvaluationsAtLanding,
            homeLandingSettles,
            homeBodyEvaluationsAtSettle,
            Self.corners(jarHintFrame),
            Double(crystalWindowX),
            Double(crystalWindowY),
            Self.corners(hudFrame),
            Self.corners(coreFrame),
            Self.corners(bottleFrame)
        )
    }

    private static func corners(_ frame: CGRect?) -> String {
        frame.map {
            String(format: "%.1f,%.1f,%.1f,%.1f", $0.minX, $0.minY, $0.maxX, $0.maxY)
        } ?? "none"
    }

    private func samplePresentation() {
        homeBodyEvaluations = HomeRenderDiagnostics.bodyEvaluationCount
        homeLandings = HomeRenderDiagnostics.landingCount
        homeBodyEvaluationsAtLanding = HomeRenderDiagnostics.bodyEvaluationCountAtLastLanding
        homeLandingSettles = HomeRenderDiagnostics.landingSettleCount
        homeBodyEvaluationsAtSettle = HomeRenderDiagnostics.bodyEvaluationCountAtLastLandingSettle
        jarHintFrame = HomeRenderDiagnostics.jarHintWindowFrame
        hudFrame = HomeRenderDiagnostics.jarHUDWindowFrame
        coreFrame = HomeRenderDiagnostics.jarCoreWindowFrame
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
            if let view = scene.view, let window = view.window {
                let point = view.convert(scene.convertPoint(toView: target.position), to: window)
                targetWindowX = point.x
                targetWindowY = point.y
            }
        }

        if let crystal = pebbles.filter({ $0.descriptor.isAggregate }).min(by: {
            $0.descriptor.id.uuidString < $1.descriptor.id.uuidString
        }), let view = scene.view, let window = view.window {
            let point = view.convert(scene.convertPoint(toView: crystal.position), to: window)
            crystalWindowX = point.x
            crystalWindowY = point.y
        } else {
            crystalWindowX = -1
            crystalWindowY = -1
        }
        if let view = scene.view, let window = view.window,
           scene.size.width > 0, scene.size.height > 0 {
            let outer = JarScene.outerJarRect(sceneSize: scene.size)
            let topLeft = view.convert(
                scene.convertPoint(toView: CGPoint(x: outer.minX, y: outer.maxY)),
                to: window
            )
            let bottomRight = view.convert(
                scene.convertPoint(toView: CGPoint(x: outer.maxX, y: outer.minY)),
                to: window
            )
            bottleFrame = CGRect(
                x: topLeft.x,
                y: topLeft.y,
                width: bottomRight.x - topLeft.x,
                height: bottomRight.y - topLeft.y
            )
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
