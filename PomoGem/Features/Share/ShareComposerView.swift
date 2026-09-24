import Photos
import SwiftData
import SwiftUI
import UIKit

struct ShareComposerView: View {
    let scope: ShareScope

    enum Format: String, CaseIterable, Identifiable {
        case feed = "フィード 4:5"
        case story = "ストーリー 9:16"
        var id: Self { self }
    }

    enum MediaKind: String, CaseIterable, Identifiable {
        case animatedGIF = "動くGIF"
        case stillImage = "静止画"

        var id: Self { self }

        var symbol: String {
            switch self {
            case .animatedGIF: "play.rectangle.on.rectangle.fill"
            case .stillImage: "photo.fill"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPlayAnimatedImages) private var playAnimatedImages
    @Environment(AppRouter.self) private var router
    @Environment(\.aggregateProjectionPresentation)
    private var aggregateProjectionPresentation
    @Query private var activityResetMarkers: [ActivityResetMarker]
    @Query private var preferences: [Prefs]
    @State private var format: Format = .feed
    @State private var mediaKind: MediaKind = .animatedGIF
    @State private var includeManual = false
    @State private var adjustmentsAreExpanded = false
    @State private var selectedHashtags = Set(ShareCopy.hashtags)
    @State private var customHashtagInput = ""
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var isRendering = false
    @State private var isSaving = false
    @State private var shareCompleted = false
    @State private var statusMessage: String?
    @State private var jarSnapshot: UIImage?
    @State private var temporaryShareURL: URL?
    @State private var exportTask: Task<Void, Never>?
    @State private var activeExportID: UUID?
    @State private var photoSaveTask: Task<Void, Never>?
    @State private var activePhotoSaveID: UUID?
    @State private var storedSessions: [StudySession] = []
    @State private var looseSessions: [StudySession] = []
    @State private var storedAchievementStones: [AchievementStone] = []
    @State private var storedAggregatePebbles: [AggregatePebble] = []
    @State private var storedStrata: [Stratum] = []
    @State private var aggregateProjectionCacheStamp:
        AggregateProjectionCacheStamp?
    @State private var historyPageIsPartial = false
    @State private var loosePageIsPartial = false
    @State private var achievementPageIsPartial = false
    @State private var aggregatePageIsPartial = false
    @State private var aggregateValidationIsIncomplete = false
    @State private var acceptedAggregateRootIDs = Set<UUID>()
    @State private var localRepresentedSessionIDs = Set<UUID>()
    @State private var localMembershipProjectionIsComplete = true
    @State private var allSessionRowCount = 0
    @State private var dataLoadError: String?
    @State private var isLoadingData = true
#if DEBUG
    @State private var debugGIFShareLifecycle = DebugGIFShareLifecycle()
#endif

    init(scope: ShareScope) {
        self.scope = scope
        _activityResetMarkers = Query(BoundedHistoryPolicy.latestResetMarkerDescriptor())
        _preferences = Query(PrefsConsumerPolicy.descriptor())
    }

    private var resetSnapshots: [ActivityResetSnapshot] {
        activityResetMarkers.map(\.policySnapshot)
    }
    private var resolvedPreferences: PrefsSyncPolicy.ResolvedState? {
        PrefsConsumerPolicy.resolvedState(
            in: preferences,
            markers: resetSnapshots
        )
    }
    private var resolvedSharePreference: Bool {
        resolvedPreferences?.shareIncludesManual ?? false
    }
    private var sessions: [StudySession] {
        storedSessions.filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetSnapshots)
                && StudySessionIntegrityPolicy.isSupported($0)
        }
    }
    private var achievementStones: [AchievementStone] {
        storedAchievementStones.filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetSnapshots)
        }
    }
    private var aggregatePebbles: [AggregatePebble] {
        guard aggregateProjectionPresentation
            .acceptsVerifiedAggregateCache(aggregateProjectionCacheStamp)
        else { return [] }
        return storedAggregatePebbles.filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetSnapshots)
        }
    }
    private var strata: [Stratum] {
        guard aggregateProjectionPresentation
            .acceptsVerifiedAggregateCache(aggregateProjectionCacheStamp)
        else { return [] }
        return storedStrata.filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetSnapshots)
        }
    }
    private var uniqueSessions: [StudySession] {
        StudySessionSyncPolicy.canonicalSessions(from: sessions)
        .sorted { $0.endAt < $1.endAt }
    }
    private var uniqueLooseSessions: [StudySession] {
        StudySessionSyncPolicy.canonicalSessions(from: looseSessions)
        .sorted { $0.endAt < $1.endAt }
    }
    private var compactLooseSessions: [StudySession] {
        uniqueLooseSessions.filter { !localRepresentedSessionIDs.contains($0.id) }
    }
    private var uniqueAggregates: [AggregatePebble] {
        Dictionary(grouping: aggregatePebbles, by: \.id).values.compactMap { duplicates in
            duplicates.max { lhs, rhs in
                if lhs.level == rhs.level { return lhs.createdAt < rhs.createdAt }
                return lhs.level < rhs.level
            }
        }
        .sorted { $0.createdAt < $1.createdAt }
    }
    private var uniqueAchievements: [AchievementStone] {
        AchievementStonePolicy.canonicalStones(from: achievementStones)
        .filter { $0.deletedAt == nil }
        .sorted { $0.achievedAt < $1.achievedAt }
    }
    private var uniqueStrata: [Stratum] {
        Dictionary(grouping: strata, by: \.id).values.compactMap { duplicates in
            duplicates.min { lhs, rhs in lhs.bakedAt < rhs.bakedAt }
        }
        .sorted { $0.bakedAt < $1.bakedAt }
    }
    private var scopedSessions: [StudySession] {
        switch scope {
        case .all:
            return uniqueSessions
        case .month:
            return uniqueSessions.filter { scope.contains($0.endAt) }
        case let .aggregate(id, _):
            guard aggregateProjectionPresentation.allowsAggregateSummaries else {
                return []
            }
            if let aggregate = uniqueAggregates.first(where: { $0.id == id }) {
                let membership = Set(AggregatePebblePolicy.descendantSessionIDs(
                    of: aggregate,
                    in: uniqueAggregates
                ))
                return uniqueSessions.filter { membership.contains($0.id) }
            }
            guard let layer = uniqueStrata.first(where: { $0.id == id }) else { return [] }
            let membership = Set(layer.sessionIDs)
            return uniqueSessions.filter { membership.contains($0.id) }
        }
    }
    private var scopedAggregates: [AggregatePebble] {
        guard aggregateProjectionPresentation.allowsAggregateSummaries else {
            return []
        }
        switch scope {
        case .all:
            let trusted = uniqueAggregates.filter {
                acceptedAggregateRootIDs.contains($0.id)
            }
            return AggregatePebblePolicy.disjointRootSummaries(from: trusted)
        case .month:
            let scopedIDs = Set(scopedSessions.map(\.id))
            return AggregatePebblePolicy.activeRoots(from: uniqueAggregates).filter {
                let membership = AggregatePebblePolicy.descendantSessionIDs(
                    of: $0,
                    in: uniqueAggregates
                )
                return !membership.isEmpty && !scopedIDs.isDisjoint(with: membership)
            }
        case let .aggregate(id, _):
            return uniqueAggregates.filter { $0.id == id }
        }
    }
    private var scopedAchievements: [AchievementStone] {
        switch scope {
        case .all:
            return uniqueAchievements
        case .month:
            return uniqueAchievements.filter { scope.contains($0.achievedAt) }
        case .aggregate:
            return []
        }
    }
    private var selectedSessions: [StudySession] {
        var selected: [StudySession]
        if scopedAggregateProjection == .authoritativeSummary {
            // A scoped aggregate summary already owns the exact mass/counts.
            // Passing its descendants as loose rows would count every reward
            // twice in the preview, export, caption, and accessibility value.
            selected = []
        } else if usesCompactRootProjection {
            // Compact roots are local projections. Only exact local leaf or
            // legacy membership can remove a synchronized session candidate.
            selected = compactLooseSessions
        } else {
            selected = includeManual ? scopedSessions : scopedSessions.filter { $0.source.isMeasured }
        }
        return selected
    }
    private var scopedAggregateProjection: ScopedAggregateShareProjection? {
        guard case .aggregate = scope,
              let aggregate = scopedAggregates.first
        else { return nil }
        return .mode(
            for: aggregate,
            includesSelfReportedFocus: includeManual
        )
    }
    private var selectedAggregates: [ShareAggregateVisual] {
        if usesCompactRootProjection {
            let modern = scopedAggregates.map(ShareAggregateVisual.init(aggregateSummary:))
            let modernIDs = Set(uniqueAggregates.map(\.id))
            let legacy = scopedLegacyStrata
                .filter { !modernIDs.contains($0.id) }
                .map(ShareAggregateVisual.init(legacySummary:))
            return (modern + legacy).sorted { $0.createdAt < $1.createdAt }
        }

        if scopedAggregateProjection == .authoritativeSummary,
           let aggregate = scopedAggregates.first {
            return [ShareAggregateVisual(aggregateSummary: aggregate)]
        }

        let modern = scopedAggregates.compactMap { aggregate -> ShareAggregateVisual? in
            let resolvedMembership = AggregatePebblePolicy.descendantSessionIDs(
                of: aggregate,
                in: uniqueAggregates
            )
            let membership = Set(resolvedMembership)
            if membership.isEmpty {
                // A compact parent arriving before its children is not a
                // membership-less legacy summary. Omitting that transient
                // visual prevents its full mass being added on top of sessions.
                guard AggregatePebblePolicy.isUnattributedCompatibility(aggregate) else {
                    return nil
                }
                let isExplicitlyAllMeasured = aggregate.manualPebbleCount == 0
                    && aggregate.measuredPebbleCount == aggregate.pebbleCount
                    && aggregate.pebbleCount > 0
                return includeManual || isExplicitlyAllMeasured
                    ? ShareAggregateVisual(aggregate: aggregate)
                    : nil
            }
            return ShareAggregateVisual(
                reconstructing: aggregate,
                resolvedSessionIDs: resolvedMembership,
                allMemberSessions: uniqueSessions.filter { membership.contains($0.id) },
                includedMemberSessions: selectedSessions.filter { membership.contains($0.id) }
            )
        }

        let modernIDs = Set(uniqueAggregates.map(\.id))
        let legacy = scopedLegacyStrata
            .filter { !modernIDs.contains($0.id) }
            .compactMap { layer -> ShareAggregateVisual? in
                let membership = Set(layer.sessionIDs)
                if membership.isEmpty {
                    return includeManual ? ShareAggregateVisual(legacy: layer) : nil
                }
                return ShareAggregateVisual(
                    reconstructing: layer,
                    allMemberSessions: uniqueSessions.filter { membership.contains($0.id) },
                    includedMemberSessions: selectedSessions.filter { membership.contains($0.id) }
                )
            }
        return (modern + legacy).sorted { $0.createdAt < $1.createdAt }
    }

    /// Aggregate visuals index the sessions they contain, so only compatibility
    /// aggregates without membership contribute additional mass.
    private var selectedTotalGrams: Int {
        NonnegativeIntPolicy.sum(
            selectedSessions.map(\.grams)
                + selectedAggregates
                    .filter(\.contributesStandaloneTotals)
                    .map(\.grams)
        )
    }

    /// Disclose what is actually present in the selected card, rather than the
    /// state of the toggle itself. Membership-less compatibility aggregates are
    /// conservative: they are only included when self-reporting is enabled, so
    /// their unknown composition is disclosed as self-reported.
    private var selectedIncludesSelfReportedFocus: Bool {
        selectedSessions.contains { $0.source.isSelfReported }
            || selectedAggregates.contains { $0.manualPebbleCount > 0 }
            || selectedHasUnknownSelfReportComposition
    }

    private var selectedHasUnknownSelfReportComposition: Bool {
        guard includeManual else { return false }
        let unknownModernIDs = Set(scopedAggregates
            .filter(AggregatePebblePolicy.isUnattributedCompatibility)
            .map(\.id))
        let modernIDs = Set(scopedAggregates.map(\.id))
        let unknownLegacyIDs = Set(scopedLegacyStrata
            .filter { !modernIDs.contains($0.id) && $0.sessionIDs.isEmpty }
            .map(\.id))
        let unknownIDs = unknownModernIDs.union(unknownLegacyIDs)
        return selectedAggregates.contains { unknownIDs.contains($0.id) }
    }

    private var shareCaption: String {
        let semantics = shareRewardSemantics(
            sessions: selectedSessions.map(ShareSessionVisual.init),
            aggregates: selectedAggregates,
            achievements: scopedAchievements.map(ShareAchievementVisual.init)
        )
        let hiddenContent = shareHiddenContent(
            sessions: selectedSessions.map(ShareSessionVisual.init),
            aggregates: selectedAggregates,
            achievements: scopedAchievements.map(ShareAchievementVisual.init),
            format: format
        )
        return ShareCopy.caption(
            subject: shareCaptionSubject,
            grams: ShareMassFormatter.visual(selectedTotalGrams),
            includesSelfReportedFocus: selectedIncludesSelfReportedFocus,
            achievementCount: scopedAchievements.count,
            rewardDetail: semantics.captionDetail,
            visualDisclosure: hiddenContent.captionDisclosure,
            hashtags: activeHashtags
        )
    }

    private var activeHashtags: [String] {
        var values = ShareCopy.hashtags.filter(selectedHashtags.contains)
        if let custom = ShareHashtagPolicy.normalized(customHashtagInput),
           !values.contains(where: {
               $0.compare(custom, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
           }) {
            values.append(custom)
        }
        return values
    }

    private var shareCaptionSubject: String {
        if aggregateProjectionPresentation.isCloudVerificationPending {
            return includeManual
                ? "この端末で確認済みの記録"
                : "この端末で確認済みの実測記録"
        }
        switch scope {
        case .all:
            if historyPageIsPartial && !usesCompactRootProjection {
                return includeManual
                    ? "最近の記録から選んだ集中"
                    : "最近の記録から選んだ実測集中"
            }
            if compactProjectionIsIncomplete {
                return "読み込めた結晶と最新層の集中"
            }
            return achievementPageIsPartial
                ? "これまでの集中（記念石は最新\(BoundedHistoryPolicy.achievementLimit)個）"
                : "これまでの集中"
        case .month:
            return historyPageIsPartial
                ? "\(scope.periodLabel)の表示分"
                : "\(scope.periodLabel)の集中"
        case .aggregate: return "\(scope.periodLabel)の積み重ね"
        }
    }

    private var effectivePeriodLabel: String {
        if aggregateProjectionPresentation.isCloudVerificationPending {
            return "この端末で確認済み・iCloud再集計中"
        }
        switch scope {
        case .all where historyPageIsPartial && !includeManual && !usesCompactRootProjection:
            return "最近の実測・最新\(BoundedHistoryPolicy.periodSessionLimit)件の記録内"
        case .all where historyPageIsPartial && !usesCompactRootProjection:
            return "最近の記録・最新\(BoundedHistoryPolicy.periodSessionLimit)件"
        case .all where compactProjectionIsIncomplete:
            return "これまで・読み込み分"
        case .month where historyPageIsPartial:
            return "\(scope.periodLabel)・表示分"
        default:
            return scope.periodLabel
        }
    }

    private var usesCompactRootProjection: Bool {
        guard aggregateProjectionPresentation.allowsAggregateSummaries else {
            return false
        }
        guard scope == .all, historyPageIsPartial else { return false }
        let modernIDs = Set(uniqueAggregates.map(\.id))
        let hasDistinctLegacySummaries = scopedLegacyStrata.contains {
            !modernIDs.contains($0.id)
        }
        guard !scopedAggregates.isEmpty || hasDistinctLegacySummaries else {
            return false
        }
        return CompactShareProjectionPolicy.canUseLifetimeRoots(
            includesSelfReportedFocus: includeManual,
            modernSummaryComposition: scopedAggregates.map {
                .init(
                    pebbleCount: $0.pebbleCount,
                    measuredPebbleCount: $0.measuredPebbleCount,
                    manualPebbleCount: $0.manualPebbleCount
                )
            },
            hasLegacySummaries: hasDistinctLegacySummaries,
            looseSources: compactLooseSessions.map(\.source)
        )
    }

    private var compactProjectionIsIncomplete: Bool {
        guard usesCompactRootProjection else { return false }
        if aggregatePageIsPartial
            || aggregateValidationIsIncomplete
            || loosePageIsPartial {
            return true
        }
        let modernIDs = Set(scopedAggregates.map(\.id))
        let represented = NonnegativeIntPolicy.sum(
            scopedAggregates.map(\.pebbleCount)
                + scopedLegacyStrata
                    .filter { !modernIDs.contains($0.id) }
                    .map(\.pebbleCount)
                + [compactLooseSessions.count]
        )
        // Logical CloudKit duplicates make this conservative ("読み込み分")
        // rather than allowing a partial compact projection to claim lifetime.
        return represented != allSessionRowCount
    }

    private var hasShareableContent: Bool {
        !selectedSessions.isEmpty
            || !selectedAggregates.isEmpty
            || !scopedAchievements.isEmpty
            || selectedTotalGrams > 0
    }

    private var hasExcludedSelfReportedContent: Bool {
        guard !includeManual else { return false }
        if scopedSessions.contains(where: { $0.source.isSelfReported }) {
            return true
        }
        return scopedAggregates.contains {
            $0.manualPebbleCount > 0 || AggregatePebblePolicy.isUnattributedCompatibility($0)
        }
            || scopedLegacyStrata.contains { $0.sessionIDs.isEmpty }
    }

    private var settingsSummary: String {
        let medium = mediaKind == .animatedGIF ? "GIF" : "静止画"
        let shape = format == .feed ? "4:5" : "9:16"
        let scopeLabel: String
        if selectedIncludesSelfReportedFocus || !scopedAchievements.isEmpty {
            scopeLabel = "自己申告あり"
        } else if hasExcludedSelfReportedContent {
            scopeLabel = "実測のみ（自己申告は除外）"
        } else {
            scopeLabel = "実測のみ"
        }
        let hashtagLabel = activeHashtags.isEmpty
            ? "タグなし"
            : "タグ\(activeHashtags.count)個"
        return "\(medium)・\(shape)・\(scopeLabel)・\(hashtagLabel)"
    }

    private var scopedLegacyStrata: [Stratum] {
        guard aggregateProjectionPresentation.allowsAggregateSummaries else {
            return []
        }
        switch scope {
        case .all:
            return uniqueStrata
        case .month:
            let scopedIDs = Set(scopedSessions.map(\.id))
            return uniqueStrata.filter {
                !$0.sessionIDs.isEmpty && !scopedIDs.isDisjoint(with: $0.sessionIDs)
            }
        case let .aggregate(id, _):
            return uniqueStrata.filter { $0.id == id }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    shareStudioHeader

                    if let coverageNotice {
                        Label(coverageNotice, systemImage: "rectangle.stack.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 14))
                            .accessibilityIdentifier("share.partial-coverage-notice")
                    }

                    if let dataLoadError {
                        Label(dataLoadError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if isLoadingData {
                        ProgressView("カードの記録を読み込み中")
                            .frame(maxWidth: .infinity, minHeight: 280)
                    } else if hasShareableContent {
                        AnimatedShareCardPreview(
                            sessions: selectedSessions.map(ShareSessionVisual.init),
                            aggregates: selectedAggregates,
                            achievements: scopedAchievements.map(ShareAchievementVisual.init),
                            includesSelfReportedFocus: selectedIncludesSelfReportedFocus,
                            format: format,
                            jarSnapshot: jarSnapshot,
                            periodLabel: effectivePeriodLabel,
                            hashtags: activeHashtags,
                            usesAnimatedArtwork: mediaKind == .animatedGIF,
                            animates: mediaKind == .animatedGIF && !reduceMotion && playAnimatedImages
                        )
                        .aspectRatio(format == .feed ? 4 / 5 : 9 / 16, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [PomoGemTheme.amber.opacity(0.48), .white.opacity(0.08), .clear],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        }
                        .shadow(color: PomoGemTheme.amber.opacity(0.10), radius: 34, y: 16)
                        .shadow(color: .black.opacity(0.38), radius: 28, y: 16)
                        .padding(.horizontal, format == .feed ? 26 : 72)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: format)
                    } else {
                        emptyShareState
                    }

                    shareSettingsSummary
                    shareAdjustments

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .transition(.opacity)
                            .accessibilityAddTraits(.isStaticText)
                            .accessibilityIdentifier("share.status")
                    }

#if DEBUG
                    if LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess {
                        Text("GIF share lifecycle probe")
                            .font(.system(size: 1))
                            .foregroundStyle(Color.clear)
                            .frame(width: 1, height: 1)
                            .accessibilityIdentifier("share.debug.gif-lifecycle")
                            .accessibilityLabel("GIF share lifecycle probe")
                            .accessibilityValue(Text(verbatim: debugGIFShareLifecycle.accessibilityValue))
                            .allowsHitTesting(false)
                    }
#endif

                    if shareCompleted {
                        shareSuccessBanner
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }

                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    Button {
                        startShareExport()
                    } label: {
                        shareLaunchLabel
                    }
                    .buttonStyle(PomoGemPrimaryButtonStyle())
                    .disabled(isRendering || !hasShareableContent)
                    .accessibilityIdentifier("share.primary-action")
                    .accessibilityHint(
                        mediaKind == .animatedGIF
                            ? "瓶と質量の短いGIF、公式サイトURL、選択中のハッシュタグをシステム共有画面に渡します"
                            : "瓶と質量の画像、公式サイトURL、選択中のハッシュタグをシステム共有画面に渡します"
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Divider().overlay(PomoGemTheme.glassEdge.opacity(0.16))
                }
            }
            .background(NightBackground())
            .navigationTitle("カードにする")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isRendering {
                        Button("生成を中止", role: .destructive) {
                            cancelExport()
                        }
                        .accessibilityHint("この画面は閉じず、共有データの生成だけを中止します")
                    }
                    PomoGemSheetCloseButton(
                        accessibilityIdentifier: "share.close"
                    ) {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            Task(priority: .utility) {
                AnimatedShareExporter.removeStaleTemporaryFiles()
            }
            includeManual = resolvedPreferences?.shareIncludesManual ?? false
            refreshJarSnapshot()
        }
        .task(id: loadKey) {
            loadBoundedShareData()
        }
        .onChange(of: includeManual) { oldValue, value in
            persistSharePreference(from: oldValue, to: value)
        }
        .onChange(of: resolvedSharePreference) { _, value in
            guard includeManual != value else { return }
            includeManual = value
            refreshJarSnapshot()
        }
        .onChange(of: aggregateProjectionPresentation) { _, presentation in
            invalidateLoadedShareDataForProjectionTransition()
            guard presentation.isCloudVerificationPending else {
                refreshJarSnapshot()
                return
            }
            // A verified aggregate snapshot can become untrusted while GIF
            // frames are rendering or while the system sheet is open. Revoke
            // that export immediately; a new export may still use the bounded
            // individual records explicitly labelled as device-confirmed.
            cancelExport()
            cancelPhotoSave()
            showShareSheet = false
            cleanUpTemporaryShareFile()
            jarSnapshot = nil
            aggregateProjectionCacheStamp = nil
            updateStatus("iCloudを再集計中です。確認済みの記録でカードを作り直してください。")
        }
        .onDisappear {
            cancelExport()
            cancelPhotoSave()
            cleanUpTemporaryShareFile()
        }
        .sheet(isPresented: $showShareSheet, onDismiss: cleanUpTemporaryShareFile) {
            ActivityShareSheet(
                items: shareItems,
                didCreateController: {
#if DEBUG
                    if LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess {
                        debugGIFShareLifecycle.didCreateSystemController = true
                    }
#endif
                },
                completion: { completed, _, error in
                    handleShareCompletion(completed: completed, error: error)
                }
            )
        }
    }

    private var shareStudioHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [PomoGemTheme.amber, .pink.opacity(0.86), .purple.opacity(0.82), PomoGemTheme.amber],
                            center: .center
                        )
                    )
                Circle()
                    .fill(.black.opacity(0.24))
                    .padding(3)
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)
            .shadow(color: PomoGemTheme.amber.opacity(0.28), radius: 18, y: 8)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("SHARE STUDIO")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(PomoGemTheme.amber)
                Text("積み重ねを、動く一枚に")
                    .font(PomoGemTheme.brand(22))
                    .foregroundStyle(PomoGemTheme.text)
                Text("約2秒・端末の中だけで生成")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var mediaKindPicker: some View {
        HStack(spacing: 8) {
            ForEach(MediaKind.allCases) { kind in
                Button {
                    mediaKind = kind
                    shareCompleted = false
                    statusMessage = nil
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 14, weight: .bold))
                        Text(kind.rawValue)
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                        if kind == .animatedGIF {
                            Text("NEW")
                                .font(.system(size: 8, weight: .black, design: .rounded))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(.white.opacity(mediaKind == kind ? 0.18 : 0.08), in: Capsule())
                        }
                    }
                    .foregroundStyle(mediaKind == kind ? PomoGemTheme.background : PomoGemTheme.text)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(mediaKind == kind ? PomoGemTheme.amber : PomoGemTheme.raised)
                    )
                }
                .buttonStyle(PomoGemBareButtonStyle())
                .disabled(isRendering || isSaving)
                .accessibilityAddTraits(mediaKind == kind ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var shareFormatPicker: some View {
        Picker("カードの形", selection: $format) {
            ForEach(Format.allCases) { item in Text(item.rawValue).tag(item) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("share.format")
        .disabled(isRendering || isSaving)
        .padding(5)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var shareSettingsSummary: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist.checked")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(PomoGemTheme.amber)
                .accessibilityHidden(true)
            Text(settingsSummary)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(PomoGemTheme.text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .background(PomoGemTheme.card.opacity(0.88), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("現在の共有設定、\(settingsSummary)")
        .accessibilityIdentifier("share.settings-summary")
    }

    private var shareAdjustments: some View {
        DisclosureGroup(isExpanded: $adjustmentsAreExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 9) {
                    adjustmentHeading("ファイルと形", symbol: "rectangle.on.rectangle.angled")
                    mediaKindPicker
                    shareFormatPicker
                }

                if mediaKind == .animatedGIF && (reduceMotion || !playAnimatedImages) {
                    Label(
                        "プレビューの自動再生は停止中です。GIFを選んでシェアすると、動くファイルを書き出します。",
                        systemImage: "accessibility"
                    )
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }

                shareInclusionControl
                shareHashtagStrip
                shareBrandingNotice

                Label {
                    Text(SubjectSuggestionCatalog.privacyGuidance)
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(PomoGemTheme.amber)
                }
                .padding(14)
                .background(PomoGemTheme.raised, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .combine)

                sharePhotoSaveButton
            }
            .padding(.top, 16)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(PomoGemTheme.amber)
                    .accessibilityHidden(true)
                Text("調整")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                Spacer(minLength: 0)
            }
        }
        .tint(PomoGemTheme.text)
        .padding(16)
        .background(PomoGemTheme.card.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func adjustmentHeading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(PomoGemTheme.muted)
    }

    private var shareInclusionControl: some View {
        Toggle(isOn: $includeManual) {
            VStack(alignment: .leading, spacing: 3) {
                Text("自己申告を含める")
                    .font(.subheadline.weight(.semibold))
                Text("集中の自己申告を切替。記念石は常に「自己申告」と表示します")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
            }
        }
        .disabled(isRendering || isSaving)
        .tint(PomoGemTheme.amber)
        .accessibilityIdentifier("share.include-self-reported")
        .padding(16)
        .background(PomoGemTheme.raised, in: RoundedRectangle(cornerRadius: 16))
    }

    private var sharePhotoSaveButton: some View {
        Button {
            renderAndSave()
        } label: {
            if isSaving {
                ProgressView().tint(PomoGemTheme.text)
            } else {
                Label("写真に2サイズ保存", systemImage: "photo.badge.arrow.down")
            }
        }
        .buttonStyle(PomoGemSecondaryButtonStyle())
        .disabled(isRendering || isSaving || !hasShareableContent)
    }

    private var shareHashtagStrip: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "number")
                    .font(.caption.weight(.black))
                    .foregroundStyle(PomoGemTheme.amber)
                    .accessibilityHidden(true)
                Text("一緒に渡すハッシュタグ")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PomoGemTheme.muted)
                Spacer()
                Button {
                    UIPasteboard.general.string = shareCaption
                    updateStatus(
                        activeHashtags.isEmpty
                            ? "本文をコピーしました。"
                            : "本文とハッシュタグをコピーしました。"
                    )
                } label: {
                    Label("本文をコピー", systemImage: "doc.on.doc")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PomoGemTheme.amber)
                        .frame(minHeight: 44)
                }
                .buttonStyle(PomoGemBareButtonStyle())
                .accessibilityIdentifier("share.copy-caption")
                .accessibilityLabel(
                    activeHashtags.isEmpty
                        ? "本文をコピー"
                        : "本文とハッシュタグをコピー"
                )
                .accessibilityHint(
                    activeHashtags.isEmpty
                        ? "瓶の質量と固定の公式サイトURLを含む本文をコピーします"
                        : "瓶の質量、固定の公式サイトURL、選択中のハッシュタグをコピーします"
                )
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ShareCopy.hashtags, id: \.self) { hashtag in
                        Button {
                            if selectedHashtags.contains(hashtag) {
                                selectedHashtags.remove(hashtag)
                            } else {
                                selectedHashtags.insert(hashtag)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: selectedHashtags.contains(hashtag) ? "checkmark" : "plus")
                                    .font(.system(size: 9, weight: .black))
                                Text(hashtag)
                            }
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(
                                selectedHashtags.contains(hashtag)
                                    ? PomoGemTheme.background
                                    : PomoGemTheme.text
                            )
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .frame(minHeight: 44)
                            .background(
                                selectedHashtags.contains(hashtag)
                                    ? AnyShapeStyle(PomoGemTheme.amber)
                                    : AnyShapeStyle(
                                        LinearGradient(
                                            colors: [.white.opacity(0.09), PomoGemTheme.amber.opacity(0.08)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    ),
                                in: Capsule()
                            )
                            .overlay { Capsule().stroke(.white.opacity(0.10), lineWidth: 1) }
                        }
                        .buttonStyle(PomoGemBareButtonStyle())
                        .disabled(isRendering || isSaving)
                        .accessibilityAddTraits(
                            selectedHashtags.contains(hashtag) ? .isSelected : []
                        )
                    }
                }
            }

            TextField("追加タグ（任意）", text: $customHashtagInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .disabled(isRendering || isSaving)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(PomoGemTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            customHashtagInput.isEmpty
                                || ShareHashtagPolicy.normalized(customHashtagInput) != nil
                                ? Color.white.opacity(0.10)
                                : Color.red.opacity(0.62),
                            lineWidth: 1
                        )
                }
                .accessibilityIdentifier("share.custom-hashtag")

            if !customHashtagInput.isEmpty,
               ShareHashtagPolicy.normalized(customHashtagInput) == nil {
                Text("文字・数字・_ のみ、30文字まで。本文やURLは追加しません。")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.red.opacity(0.86))
            } else {
                Text(activeHashtags.isEmpty
                    ? "ハッシュタグなしで共有します"
                    : "選択中：\(activeHashtags.joined(separator: " "))")
                    .font(.caption2)
                    .foregroundStyle(PomoGemTheme.muted)
            }
            Text("保存済みのテーマ名・成果メモ・顧客名は自動で含めません。追加タグへ入力した内容は共有されます")
                .font(.caption2)
                .foregroundStyle(PomoGemTheme.muted)
        }
        .padding(14)
        .background(PomoGemTheme.card.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Keep the copy CTA as its own VoiceOver element. Combining this
        // container would flatten the nested Button into non-actionable text.
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var shareLaunchLabel: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(.white.opacity(0.18))
                Image(systemName: mediaKind == .animatedGIF ? "play.fill" : "photo.fill")
                    .font(.system(size: 15, weight: .black))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    isRendering
                        ? (mediaKind == .animatedGIF ? "GIFを生成中…" : "画像を生成中…")
                        : (mediaKind == .animatedGIF ? "GIF + ハッシュタグをシェア" : "画像 + ハッシュタグをシェア")
                )
                .font(.system(.body, design: .rounded, weight: .black))
                Text(mediaKind == .animatedGIF ? "粒がきらめく短いループ" : "高解像度の一枚")
                    .font(.caption.weight(.semibold))
                    .opacity(0.72)
            }
            Spacer(minLength: 4)
            if isRendering {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 15, weight: .black))
                    .padding(9)
                    .background(.white.opacity(0.14), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var shareSuccessBanner: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(Color.green.opacity(0.18))
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(Color.green)
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("共有できました")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                Text("次の集中も、また一粒ずつ。")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("share.success.message")
            .accessibilityLabel("共有できました。次の集中も、また一粒ずつ。")
            Spacer()
            Button("完了") { dismiss() }
                .font(.caption.weight(.bold))
                .foregroundStyle(PomoGemTheme.amber)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("share.success.done")
                .accessibilityLabel("共有を完了して閉じる")
                .accessibilityHint("カード作成画面を閉じて瓶に戻ります")
        }
        .padding(14)
        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color.green.opacity(0.24), lineWidth: 1)
        }
        // Preserve the message and completion CTA as two independent
        // VoiceOver stops instead of swallowing the nested Button.
        .accessibilityElement(children: .contain)
    }

    private var emptyShareState: some View {
        PomoGemCard {
            VStack(spacing: 14) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 36))
                    .foregroundStyle(PomoGemTheme.amber)
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text(
                        aggregateProjectionPresentation.isCloudVerificationPending
                            ? "iCloudを再集計中"
                            : hasExcludedSelfReportedContent
                            ? "自己申告の粒があります"
                            : "カードにする粒が、まだありません"
                    )
                        .font(PomoGemTheme.brand(21))
                        .multilineTextAlignment(.center)
                    Text(emptyShareMessage)
                        .font(.subheadline)
                        .foregroundStyle(PomoGemTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if aggregateProjectionPresentation.isCloudVerificationPending {
                    ProgressView()
                        .tint(PomoGemTheme.amber)
                        .accessibilityLabel("iCloudの集計を確認中")
                } else if hasExcludedSelfReportedContent {
                    Button("自己申告を含めてカードにする") {
                        includeManual = true
                    }
                    .buttonStyle(PomoGemSecondaryButtonStyle())
                    .accessibilityIdentifier("share.include-self-reported-direct")
                    .accessibilityHint("自己申告として明記したうえで、この記録をカードに含めます")
                } else {
                    Button("最初の一粒へ") {
                        dismiss()
                        router.selectedTab = .jar
                    }
                    .buttonStyle(PomoGemSecondaryButtonStyle())
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private var shareBrandingNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "signature")
                .foregroundStyle(PomoGemTheme.amber)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("ポモジェムロゴと公式サイト")
                    .font(.subheadline.weight(.semibold))
                Text("すべてのカードと共有本文に表示します")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
            }
            Spacer()
            Text("常に表示")
                .font(.caption.weight(.bold))
                .foregroundStyle(PomoGemTheme.amber)
        }
        .padding(16)
        .frame(minHeight: 58)
        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("share.branding")
    }

    private var emptyShareMessage: String {
        if aggregateProjectionPresentation.isCloudVerificationPending {
            if case .aggregate = scope {
                return "このまとまりは確認後にカードへできます。"
            }
            return "古い集計値は使わず、この端末で確認できる個別記録だけを確認しています。"
        }
        if case .aggregate = scope,
           !includeManual,
           scopedAggregates.contains(where: { $0.manualPebbleCount > 0 }) {
            return "この結晶には自己申告が含まれます。「自己申告を含める」をオンにすると、結晶全体の正確な質量をカードにできます。"
        }
        if !includeManual, scopedSessions.contains(where: { $0.source.isSelfReported }) {
            return "自己申告を含めると、この期間の瓶をカードにできます。"
        }
        return "集中を完走すると、瓶の画像とグラム数を一緒に残せます。"
    }

    private var coverageNotice: String? {
        if aggregateProjectionPresentation.isCloudVerificationPending {
            return "iCloudの集計を再確認中です。古い結晶集計は使わず、この端末で確認できた個別記録だけをカードにします。"
        }
        if historyPageIsPartial {
            switch scope {
            case .all where usesCompactRootProjection:
                if compactProjectionIsIncomplete {
                    return "全履歴を一括展開せず、取得できた結晶集計と最新層だけで構成しています。カードは「読み込み分」と明記されます。"
                }
                if achievementPageIsPartial {
                    return "集中の質量は結晶集計から構成し、記念石は最新\(BoundedHistoryPolicy.achievementLimit)個を載せます。"
                }
                return "40年分でも全履歴を展開せず、結晶集計と現在の粒から正確な質量を構成します。"
            case .all:
                return "全履歴を一括展開しないため、最新\(BoundedHistoryPolicy.periodSessionLimit)件の記録から選んだ表示分です。カードにも範囲を明記します。"
            case .month:
                return "この月は記録が多いため、最新\(BoundedHistoryPolicy.periodSessionLimit)件の表示分です。カードにも「表示分」と明記します。"
            case .aggregate:
                return "この結晶は集計値で表示しています。元の全セッションはこの画面では展開しません。"
            }
        }
        if achievementPageIsPartial {
            return "記念石は最新\(BoundedHistoryPolicy.achievementLimit)個をカードに載せます。記録画面で削除した石は共有にも含まれません。"
        }
        return nil
    }

    private var loadKey: String {
        let epoch = ActivityResetPolicy.currentEpochID(from: resetSnapshots)?.uuidString ?? "pre-reset"
        let scopeKey: String
        switch scope {
        case .all:
            scopeKey = "all"
        case let .month(start):
            scopeKey = "month:\(start.timeIntervalSinceReferenceDate)"
        case let .aggregate(id, _):
            scopeKey = "aggregate:\(id.uuidString)"
        }
        let verification = [
            aggregateProjectionPresentation.cacheNamespace.uuidString,
            String(aggregateProjectionPresentation.verificationEpoch),
            aggregateProjectionPresentation.isCloudVerificationPending
                ? "cloud-pending"
                : "verified"
        ].joined(separator: ":")
        return "\(epoch)|\(scopeKey)|\(verification)|\(scenePhase == .active)"
    }

    @MainActor
    private func loadBoundedShareData() {
        guard scenePhase == .active else { return }
        isLoadingData = true
        dataLoadError = nil
        historyPageIsPartial = false
        loosePageIsPartial = false
        achievementPageIsPartial = false
        aggregatePageIsPartial = false
        aggregateValidationIsIncomplete = false
        acceptedAggregateRootIDs = []
        localRepresentedSessionIDs = []
        localMembershipProjectionIsComplete = true
        allSessionRowCount = 0
        storedSessions = []
        looseSessions = []
        storedAchievementStones = []
        storedAggregatePebbles = []
        storedStrata = []
        aggregateProjectionCacheStamp = nil

        let epochID = ActivityResetPolicy.currentEpochID(from: resetSnapshots)
        let verifiedProjectionStamp = aggregateProjectionPresentation
            .verifiedCacheStamp
        do {
            switch scope {
            case .all:
                allSessionRowCount = try modelContext.fetchCount(
                    BoundedHistoryPolicy.sessionCountDescriptor(epochID: epochID)
                )
                let sessionPage = try BoundedHistoryPolicy.resolvedSessionPage(
                    context: modelContext,
                    epochID: epochID,
                    order: .reverse,
                    logicalLimit: BoundedHistoryPolicy.periodSessionLimit
                )
                historyPageIsPartial = sessionPage.isPartial
                storedSessions = sessionPage.sessions

                let loosePage = try BoundedHistoryPolicy.resolvedSessionPage(
                    context: modelContext,
                    epochID: epochID,
                    onlyUnbaked: true,
                    order: .reverse,
                    logicalLimit: BoundedHistoryPolicy.shareLooseSessionLimit
                )
                loosePageIsPartial = loosePage.isPartial
                looseSessions = loosePage.sessions

                let achievementRaw = try modelContext.fetch(BoundedHistoryPolicy.achievementCandidateDescriptor(
                    epochID: epochID,
                    order: .reverse,
                    limit: BoundedHistoryPolicy.achievementLimit + 1
                ))
                achievementPageIsPartial = achievementRaw.count > BoundedHistoryPolicy.achievementLimit
                storedAchievementStones = try AchievementStonePolicy.resolvedVisibleCandidates(
                    from: Array(achievementRaw.prefix(BoundedHistoryPolicy.achievementLimit)),
                    context: modelContext
                )

                if verifiedProjectionStamp != nil {
                    let aggregateRaw = try modelContext.fetch(BoundedHistoryPolicy.rootAggregateDescriptor(
                        epochID: epochID,
                        limit: BoundedHistoryPolicy.aggregateRootLimit + 1
                    ))
                    aggregatePageIsPartial = aggregateRaw.count > BoundedHistoryPolicy.aggregateRootLimit
                    storedAggregatePebbles = Array(aggregateRaw.prefix(BoundedHistoryPolicy.aggregateRootLimit))
                    let activeRootIDs = Set(AggregatePebblePolicy.activeRoots(
                        from: storedAggregatePebbles
                    ).map(\.id))
                    acceptedAggregateRootIDs = try HomeProjectionPolicy.acceptedRootSummaryIDs(
                        roots: storedAggregatePebbles,
                        context: modelContext,
                        resetMarkers: resetSnapshots
                    )
                    aggregateValidationIsIncomplete = acceptedAggregateRootIDs != activeRootIDs

                    let legacyRaw = try modelContext.fetch(BoundedHistoryPolicy.legacyAggregateDescriptor(
                        epochID: epochID,
                        limit: BoundedHistoryPolicy.legacyAggregateLimit + 1
                    ))
                    aggregatePageIsPartial = aggregatePageIsPartial
                        || legacyRaw.count > BoundedHistoryPolicy.legacyAggregateLimit
                    storedStrata = Array(legacyRaw.prefix(BoundedHistoryPolicy.legacyAggregateLimit))
                }

            case let .month(monthStart):
                let calendar = Calendar.autoupdatingCurrent
                guard let interval = calendar.dateInterval(of: .month, for: monthStart) else {
                    throw BoundedShareLoadError.invalidMonth
                }
                let sessionPage = try BoundedHistoryPolicy.resolvedSessionPage(
                    context: modelContext,
                    epochID: epochID,
                    start: interval.start,
                    end: interval.end,
                    order: .forward,
                    logicalLimit: BoundedHistoryPolicy.periodSessionLimit
                )
                historyPageIsPartial = sessionPage.isPartial
                storedSessions = sessionPage.sessions

                let achievementRaw = try modelContext.fetch(BoundedHistoryPolicy.achievementCandidateDescriptor(
                    epochID: epochID,
                    start: interval.start,
                    end: interval.end,
                    order: .forward,
                    limit: BoundedHistoryPolicy.achievementLimit + 1
                ))
                achievementPageIsPartial = achievementRaw.count > BoundedHistoryPolicy.achievementLimit
                storedAchievementStones = try AchievementStonePolicy.resolvedVisibleCandidates(
                    from: Array(achievementRaw.prefix(BoundedHistoryPolicy.achievementLimit)),
                    context: modelContext
                )

            case let .aggregate(id, _):
                if verifiedProjectionStamp != nil {
                    storedAggregatePebbles = try modelContext.fetch(
                        BoundedHistoryPolicy.aggregateDescriptor(id: id, epochID: epochID)
                    )
                    storedStrata = try modelContext.fetch(
                        BoundedHistoryPolicy.legacyAggregateDescriptor(id: id, epochID: epochID)
                    )
                }

                let memberIDs = storedAggregatePebbles.first?.sessionIDs
                    ?? storedStrata.first?.sessionIDs
                    ?? []
                let boundedMemberIDs = Array(memberIDs.prefix(
                    BoundedHistoryPolicy.aggregateMemberSessionLimit
                ))
                var members: [StudySession] = []
                members.reserveCapacity(min(
                    boundedMemberIDs.count,
                    BoundedHistoryPolicy.aggregateMemberSessionLimit
                ))
                for memberID in boundedMemberIDs {
                    if let member = try BoundedHistoryPolicy.resolvedSession(
                        id: memberID,
                        epochID: epochID,
                        context: modelContext
                    ) {
                        members.append(member)
                    }
                }
                storedSessions = members
                historyPageIsPartial = memberIDs.count > BoundedHistoryPolicy.aggregateMemberSessionLimit
                    || (storedAggregatePebbles.first?.childAggregateCount ?? 0) > 0
            }
            // Publish the aggregate page lease only after every bounded fetch
            // and structural validation above succeeded. This assignment is
            // needed for `scopedAggregates` in the membership projection and
            // is revoked again by the catch path below.
            if let verifiedProjectionStamp,
               aggregateProjectionPresentation.acceptsVerifiedAggregateCache(
                   verifiedProjectionStamp
               ) {
                aggregateProjectionCacheStamp = verifiedProjectionStamp
            }
            let membership = try HomeProjectionPolicy.localMembershipProjection(
                for: looseSessions,
                representedAggregateRoots: scopedAggregates,
                legacyStrata: scopedLegacyStrata,
                context: modelContext,
                resetMarkers: resetSnapshots
            )
            localRepresentedSessionIDs = membership.representedSessionIDs
            localMembershipProjectionIsComplete = membership.isCompleteForCandidates
            acceptedAggregateRootIDs.subtract(membership.conflictedRootIDs)
            aggregateValidationIsIncomplete = aggregateValidationIsIncomplete
                || !localMembershipProjectionIsComplete
            isLoadingData = false
            refreshJarSnapshot()
        } catch {
            aggregateProjectionCacheStamp = nil
            isLoadingData = false
            dataLoadError = "記録を安全な範囲で読み込めませんでした。もう一度この画面を開いてください。"
        }
    }

    @MainActor
    private func invalidateLoadedShareDataForProjectionTransition() {
        // The transition callback runs synchronously before `.task(id:)`
        // starts the next bounded read. Clear the prior page now so neither a
        // pre-import aggregate nor its stale individual-membership decisions
        // can flash during a pending -> verified render.
        isLoadingData = true
        dataLoadError = nil
        acceptedAggregateRootIDs = []
        localRepresentedSessionIDs = []
        aggregateProjectionCacheStamp = nil
        storedSessions = []
        looseSessions = []
        storedAchievementStones = []
        storedAggregatePebbles = []
        storedStrata = []
    }

    private func persistSharePreference(from oldValue: Bool, to value: Bool) {
        guard let resolvedPreferences else {
            includeManual = false
            updateStatus("共有設定を安全に確認できないため、自己申告は含めません。")
            refreshJarSnapshot()
            return
        }
        guard resolvedPreferences.shareIncludesManual != value else {
            refreshJarSnapshot()
            return
        }
        do {
            try PrefsConsumerPolicy.mutate(
                .shareIncludesManual,
                context: modelContext,
                markers: resetSnapshots
            ) {
                $0.shareIncludesManual = value
            }
            try modelContext.save()
            refreshJarSnapshot()
        } catch {
            modelContext.rollback()
            includeManual = oldValue
            updateStatus("共有の設定を保存できませんでした。変更前の状態に戻しました。")
        }
    }

    @MainActor
    private func renderCards(snapshot: ShareExportSnapshot) -> [UIImage] {
        isRendering = true
        defer { isRendering = false }

        let feed = render(
            snapshot: snapshot,
            format: .feed,
            logicalSize: ShareCardLayoutPolicy.canvasSize(for: .feed)
        )
        let story = render(
            snapshot: snapshot,
            format: .story,
            logicalSize: ShareCardLayoutPolicy.canvasSize(for: .story)
        )
        return [feed, story].compactMap { $0 }
    }

    @MainActor
    private func render(
        snapshot: ShareExportSnapshot,
        format: Format? = nil,
        logicalSize: CGSize,
        scale: CGFloat = 3,
        animationPhase: Double = 0.18
    ) -> UIImage? {
        let renderedFormat = format ?? snapshot.format
        let card = ShareCardView(
            sessions: snapshot.sessions,
            aggregates: snapshot.aggregates,
            achievements: snapshot.achievements,
            includesSelfReportedFocus: snapshot.includesSelfReportedFocus,
            format: renderedFormat,
            jarSnapshot: snapshot.jarSnapshot,
            periodLabel: snapshot.periodLabel,
            hashtags: snapshot.hashtags,
            usesAnimatedArtwork: snapshot.mediaKind == .animatedGIF,
            animationPhase: animationPhase
        )
        .frame(width: logicalSize.width, height: logicalSize.height)

        let renderer = ImageRenderer(content: card)
        renderer.proposedSize = ProposedViewSize(logicalSize)
        renderer.scale = scale
        return renderer.uiImage
    }

    @MainActor
    private func refreshJarSnapshot() {
        jarSnapshot = capturedJarSnapshot(includesSelfReportedFocus: includeManual)
    }

    @MainActor
    private func capturedJarSnapshot(includesSelfReportedFocus: Bool) -> UIImage? {
        guard !aggregateProjectionPresentation.isCloudVerificationPending,
              aggregateProjectionPresentation.acceptsVerifiedAggregateCache(
                  aggregateProjectionCacheStamp
              ),
              scope == .all,
              let scene = router.jarScene else {
            return nil
        }
        return try? JarSnapshotter.shared.image(
            of: scene,
            options: .share(includesSelfReported: includesSelfReportedFocus)
        )
    }

    @MainActor
    private func captureExportSnapshot() -> ShareExportSnapshot {
        let capturedSessions = selectedSessions.map(ShareSessionVisual.init)
        let capturedAchievements = scopedAchievements.map(ShareAchievementVisual.init)
        let capturedAggregates = selectedAggregates
        let capturedGrams = selectedTotalGrams
        let capturedIncludesSelfReportedFocus = capturedSessions.contains { $0.source.isSelfReported }
            || capturedAggregates.contains { $0.manualPebbleCount > 0 }
            || selectedHasUnknownSelfReportComposition
        let capturedPeriod = effectivePeriodLabel
        let capturedHashtags = activeHashtags
        let capturedRewardSemantics = shareRewardSemantics(
            sessions: capturedSessions,
            aggregates: capturedAggregates,
            achievements: capturedAchievements
        )
        let capturedHiddenContent = shareHiddenContent(
            sessions: capturedSessions,
            aggregates: capturedAggregates,
            achievements: capturedAchievements,
            format: format
        )
        let caption = ShareCopy.caption(
            subject: shareCaptionSubject,
            grams: ShareMassFormatter.visual(capturedGrams),
            includesSelfReportedFocus: capturedIncludesSelfReportedFocus,
            achievementCount: capturedAchievements.count,
            rewardDetail: capturedRewardSemantics.captionDetail,
            visualDisclosure: capturedHiddenContent.captionDisclosure,
            hashtags: capturedHashtags
        )
        return ShareExportSnapshot(
            id: UUID(),
            mediaKind: mediaKind,
            format: format,
            sessions: capturedSessions,
            aggregates: capturedAggregates,
            achievements: capturedAchievements,
            includesSelfReportedFocus: capturedIncludesSelfReportedFocus,
            jarSnapshot: capturedJarSnapshot(includesSelfReportedFocus: capturedIncludesSelfReportedFocus),
            periodLabel: capturedPeriod,
            totalGrams: capturedGrams,
            hashtags: capturedHashtags,
            caption: caption,
            projectionWasCloudUnverified:
                aggregateProjectionPresentation.isCloudVerificationPending,
            projectionCacheStamp:
                aggregateProjectionPresentation.verifiedCacheStamp
        )
    }

    @MainActor
    private func startShareExport() {
        guard hasShareableContent else {
            updateStatus("最初の一粒を積むと、カードにできます。")
            return
        }
        guard exportTask == nil else { return }

        let snapshot = captureExportSnapshot()
        isRendering = true
        shareCompleted = false
#if DEBUG
        if LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess {
            debugGIFShareLifecycle = DebugGIFShareLifecycle()
            debugGIFShareLifecycle.recordSnapshot(
                hashtags: snapshot.hashtags,
                caption: snapshot.caption
            )
        }
#endif
        cleanUpTemporaryShareFile()
        activeExportID = snapshot.id
        exportTask = Task { @MainActor in
            await renderAndShare(snapshot: snapshot)
        }
    }

    @MainActor
    private func cancelExport() {
        activeExportID = nil
        exportTask?.cancel()
        exportTask = nil
        isRendering = false
    }

    @MainActor
    private func renderAndShare(snapshot: ShareExportSnapshot) async {
        defer {
            if activeExportID == snapshot.id {
                activeExportID = nil
                exportTask = nil
                isRendering = false
            }
        }

        let logicalSize = ShareCardLayoutPolicy.canvasSize(for: snapshot.format)
        var producedURL: URL?

        do {
            let preparedItems: [Any]
            let status: String
            switch snapshot.mediaKind {
            case .animatedGIF:
                let export = try await renderAnimatedGIF(
                    snapshot: snapshot,
                    logicalSize: logicalSize
                )
                producedURL = export.url
                try Task.checkCancellation()
                let source = AnimatedGIFActivityItemSource(
                    url: export.url,
                    previewImage: export.cover,
                    title: "瓶に積んだ集中 \(ShareMassFormatter.visual(snapshot.totalGrams))"
                )
                preparedItems = [source, snapshot.caption]
                status = snapshot.hashtags.isEmpty
                    ? "GIFと公式サイトURL入りの本文を準備しました。共有先によっては本文の貼り付けが必要です。"
                    : "GIF、公式サイトURL、ハッシュタグを準備しました。共有先によっては本文の貼り付けが必要です。"
            case .stillImage:
                guard let image = render(snapshot: snapshot, logicalSize: logicalSize) else {
                    throw AnimatedShareExportError.noFrames
                }
                preparedItems = [image, snapshot.caption]
                status = snapshot.hashtags.isEmpty
                    ? "画像と公式サイトURL入りの本文を準備しました。共有先を選んでください。"
                    : "画像、公式サイトURL、ハッシュタグを準備しました。共有先を選んでください。"
            }

            try Task.checkCancellation()
            guard activeExportID == snapshot.id else { throw CancellationError() }
            guard snapshot.projectionWasCloudUnverified
                    || aggregateProjectionPresentation
                        .acceptsVerifiedAggregateCache(
                            snapshot.projectionCacheStamp
                        )
            else { throw CancellationError() }

            // No suspension after this guard: the file lease, items, and sheet
            // presentation become visible atomically on the main actor.
            temporaryShareURL = producedURL
#if DEBUG
            if LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess,
               let temporaryShareURL {
                debugGIFShareLifecycle.recordPreparedFile(at: temporaryShareURL)
            }
#endif
            producedURL = nil
            shareItems = preparedItems
            updateStatus(status)
            showShareSheet = true
            Analytics.shared.track(.shareCreated)
        } catch is CancellationError {
            if let producedURL { try? FileManager.default.removeItem(at: producedURL) }
            if activeExportID == snapshot.id { cleanUpTemporaryShareFile() }
        } catch {
            if let producedURL { try? FileManager.default.removeItem(at: producedURL) }
            if activeExportID == snapshot.id {
                cleanUpTemporaryShareFile()
                updateStatus("共有データを生成できませんでした。\(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func renderAnimatedGIF(
        snapshot: ShareExportSnapshot,
        logicalSize: CGSize
    ) async throws -> (url: URL, cover: UIImage) {
        var ownedURL: URL?
        var returned = false
        defer {
            if !returned, let ownedURL { try? FileManager.default.removeItem(at: ownedURL) }
        }

        let preferred = try await writeAnimatedGIF(
            snapshot: snapshot,
            logicalSize: logicalSize,
            scale: 1.25
        )
        ownedURL = preferred.url
        try Task.checkCancellation()
        guard AnimatedShareExporter.fileSize(at: preferred.url) > AnimatedShareExporter.maximumShareBytes else {
            returned = true
            return preferred
        }

        try? FileManager.default.removeItem(at: preferred.url)
        ownedURL = nil
        try Task.checkCancellation()
        let compact = try await writeAnimatedGIF(
            snapshot: snapshot,
            logicalSize: logicalSize,
            scale: 1
        )
        ownedURL = compact.url
        try Task.checkCancellation()
        guard AnimatedShareExporter.fileSize(at: compact.url) <= AnimatedShareExporter.maximumShareBytes else {
            try? FileManager.default.removeItem(at: compact.url)
            ownedURL = nil
            throw AnimatedShareExportError.fileTooLarge
        }
        returned = true
        return compact
    }

    @MainActor
    private func writeAnimatedGIF(
        snapshot: ShareExportSnapshot,
        logicalSize: CGSize,
        scale: CGFloat
    ) async throws -> (url: URL, cover: UIImage) {
        let url = AnimatedShareExporter.makeTemporaryURL()
        let writer = try AnimatedShareExporter.Writer(
            url: url,
            frameCount: AnimatedShareExporter.frameCount
        )
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: url) }
        }
        var renderedPoses: [(image: UIImage, cgImage: CGImage)] = []
        renderedPoses.reserveCapacity(AnimatedShareExporter.renderedPoseCount)
        for index in 0..<AnimatedShareExporter.renderedPoseCount {
            try Task.checkCancellation()
            let phase = Double(index) / Double(AnimatedShareExporter.renderedPoseCount)
            let rendered: (image: UIImage, cgImage: CGImage)? = autoreleasepool {
                guard let image = render(
                    snapshot: snapshot,
                    logicalSize: logicalSize,
                    scale: scale,
                    animationPhase: phase
                ), let cgImage = image.cgImage else {
                    return nil
                }
                return (image, cgImage)
            }
            guard let rendered else {
                try? FileManager.default.removeItem(at: url)
                throw AnimatedShareExportError.noFrames
            }
            renderedPoses.append(rendered)
            await Task.yield()
        }

        guard renderedPoses.count == AnimatedShareExporter.renderedPoseCount else {
            try? FileManager.default.removeItem(at: url)
            throw AnimatedShareExportError.noFrames
        }
        let cover = renderedPoses[0].image
        for poseIndex in 0..<AnimatedShareExporter.renderedPoseCount {
            try Task.checkCancellation()
            let pose = renderedPoses[poseIndex].cgImage
            let nextPose = renderedPoses[
                (poseIndex + 1) % AnimatedShareExporter.renderedPoseCount
            ].cgImage
            try writer.add(pose)
            guard let intermediate = AnimatedShareExporter.intermediateFrame(
                from: pose,
                to: nextPose
            ) else {
                throw AnimatedShareExportError.noFrames
            }
            try writer.add(intermediate)
            await Task.yield()
        }
        try writer.finalize()
        try Task.checkCancellation()
        completed = true
        return (url, cover)
    }

    @MainActor
    private func handleShareCompletion(completed: Bool, error: Error?) {
        if let error {
            shareCompleted = false
            updateStatus("共有を完了できませんでした。\(error.localizedDescription)")
            return
        }
        guard completed else {
            shareCompleted = false
            updateStatus("共有はキャンセルされました。カードはこの画面に残っています。")
            return
        }
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.8)) {
            shareCompleted = true
            statusMessage = nil
        }
        UIAccessibility.post(notification: .announcement, argument: "共有できました")
    }

    @MainActor
    private func cleanUpTemporaryShareFile() {
        let leasedURL = temporaryShareURL
        if let leasedURL {
            // The lease is only ever created by `AnimatedShareExporter`, but
            // retain the ownership check at the destructive boundary.
            if AnimatedShareExporter.isOwnedTemporaryGIF(leasedURL) {
                try? FileManager.default.removeItem(at: leasedURL)
            }
#if DEBUG
            if LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess {
                debugGIFShareLifecycle.recordCleanup(of: leasedURL)
            }
#endif
        }
        self.temporaryShareURL = nil
        shareItems = []
    }

    @MainActor
    private func renderAndSave() {
        guard hasShareableContent else {
            updateStatus("最初の一粒を積むと、カードにできます。")
            return
        }
        guard photoSaveTask == nil else { return }
        let snapshot = captureExportSnapshot()
        let images = renderCards(snapshot: snapshot)
        guard images.count == 2 else {
            updateStatus("カードを生成できませんでした。")
            return
        }
        isSaving = true
        activePhotoSaveID = snapshot.id
        photoSaveTask = Task { @MainActor in
            await saveToPhotoLibrary(images, snapshot: snapshot)
        }
    }

    @MainActor
    private func cancelPhotoSave() {
        activePhotoSaveID = nil
        photoSaveTask?.cancel()
        photoSaveTask = nil
        isSaving = false
    }

    @MainActor
    private func saveToPhotoLibrary(
        _ images: [UIImage],
        snapshot: ShareExportSnapshot
    ) async {
        defer {
            if activePhotoSaveID == snapshot.id {
                activePhotoSaveID = nil
                photoSaveTask = nil
                isSaving = false
            }
        }
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard activePhotoSaveID == snapshot.id, !Task.isCancelled else { return }
        guard authorization == .authorized || authorization == .limited else {
            updateStatus("写真への追加が許可されていません。端末の設定から変更できます。")
            return
        }
        // The authorization prompt can outlive aggregate trust. Revalidate at
        // the last MainActor instruction before starting the Photos mutation;
        // a snapshot captured while already pending contains only explicitly
        // labelled, device-confirmed individual records.
        guard snapshot.projectionWasCloudUnverified
                || aggregateProjectionPresentation
                    .acceptsVerifiedAggregateCache(
                        snapshot.projectionCacheStamp
                    )
        else { return }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                images.forEach { PHAssetChangeRequest.creationRequestForAsset(from: $0) }
            }
            guard activePhotoSaveID == snapshot.id, !Task.isCancelled else {
                return
            }
            updateStatus("フィード用とストーリー用を写真に保存しました。")
            Analytics.shared.track(.shareCreated)
        } catch is CancellationError {
            return
        } catch {
            guard activePhotoSaveID == snapshot.id else { return }
            updateStatus("写真に保存できませんでした。\(error.localizedDescription)")
        }
    }

    @MainActor
    private func updateStatus(_ message: String) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            statusMessage = message
        }
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

private enum BoundedShareLoadError: Error {
    case invalidMonth
}

#if DEBUG
/// Machine-readable evidence for one UI-test-only share lifecycle. The final
/// value retains the pre-cleanup GIF inspection, so XCUITest can assert that
/// the same valid 8-frame file existed before the system sheet and no longer
/// exists after dismissal. It is compiled out of Release and mounted only for
/// the two-key local UI-test launch policy.
private struct DebugGIFShareLifecycle: Equatable {
    private(set) var inspection: AnimatedShareExporter.DebugGIFInspection?
    var didCreateSystemController = false
    private(set) var didAttemptCleanup = false
    private(set) var existsAfterCleanup: Bool?
    private(set) var snapshotHashtags: [String] = []
    private(set) var captionHasExactHashtagSet = false
    private(set) var captionHasExactWebsiteURL = false

    mutating func recordSnapshot(hashtags: [String], caption: String) {
        snapshotHashtags = hashtags
        let captionHashtags = caption
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { $0.hasPrefix("#") }
        captionHasExactHashtagSet = captionHashtags == hashtags
        captionHasExactWebsiteURL = caption.components(
            separatedBy: ShareCopy.websiteURL.absoluteString
        ).count - 1 == 1
    }

    mutating func recordPreparedFile(at url: URL) {
        inspection = AnimatedShareExporter.debugInspection(at: url)
        didCreateSystemController = false
        didAttemptCleanup = false
        existsAfterCleanup = nil
    }

    mutating func recordCleanup(of url: URL) {
        didAttemptCleanup = true
        existsAfterCleanup = FileManager.default.fileExists(atPath: url.path)
    }

    var accessibilityValue: String {
        let inspection = inspection
        return [
            "prepared=\(bit(inspection != nil))",
            "valid=\(bit(inspection?.isValidExport == true))",
            "owned=\(bit(inspection?.isOwnedTemporaryFile == true))",
            "gif=\(bit(inspection?.isGIF == true))",
            "frames=\(inspection?.frameCount ?? 0)",
            "bytes=\(inspection?.byteCount ?? 0)",
            "controller=\(bit(didCreateSystemController))",
            "cleanup=\(bit(didAttemptCleanup))",
            "existsAfter=\(existsAfterCleanup.map(bit) ?? "pending")",
            "hashtags=\(snapshotHashtags.joined(separator: ","))",
            "captionTagsExact=\(bit(captionHasExactHashtagSet))",
            "captionURLExact=\(bit(captionHasExactWebsiteURL))"
        ].joined(separator: ";")
    }

    private func bit(_ value: Bool) -> String { value ? "1" : "0" }
}
#endif

enum ShareColorPolicy {
    static let fallbackHex = Constants.Color.textMute
        .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        .uppercased()

    static func resolvedHex(_ value: String) -> String {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("#") {
            candidate.removeFirst()
        }
        let hexadecimalCharacters = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")
        guard candidate.count == 6,
              candidate.unicodeScalars.allSatisfy({ hexadecimalCharacters.contains($0) })
        else {
            return fallbackHex
        }
        return candidate.uppercased()
    }

    static func color(_ value: String, vivid: Bool = false) -> Color {
        let resolved = resolvedHex(value)
        let number = UInt64(resolved, radix: 16) ?? UInt64(fallbackHex, radix: 16) ?? 0
        let base = UIColor(
            red: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: 1
        )
        guard vivid else { return Color(uiColor: base) }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard base.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ) else {
            return Color(uiColor: base)
        }
        // A malformed legacy value intentionally resolves to the neutral mute
        // token. Do not invent an arbitrary red hue when boosting a grayscale
        // fallback (UIKit reports hue zero for zero saturation).
        guard saturation >= 0.05 else { return Color(uiColor: base) }
        return Color(
            uiColor: UIColor(
                hue: hue,
                saturation: max(saturation, 0.72),
                brightness: max(brightness, 0.88),
                alpha: alpha
            )
        )
    }
}

struct ShareHiddenContent: Equatable {
    let loosePebbleCount: Int
    let aggregateCount: Int
    let achievementCount: Int

    var totalCount: Int {
        NonnegativeIntPolicy.sum([
            loosePebbleCount,
            aggregateCount,
            achievementCount
        ])
    }

    var compactLabel: String? {
        totalCount > 0 ? "代表表示 +\(totalCount)" : nil
    }

    var captionDisclosure: String? {
        let details = [
            loosePebbleCount > 0 ? "集中粒\(loosePebbleCount)粒" : nil,
            aggregateCount > 0 ? "まとまり\(aggregateCount)個" : nil,
            achievementCount > 0 ? "記念石\(achievementCount)個" : nil
        ].compactMap { $0 }
        guard !details.isEmpty else { return nil }
        return "瓶は代表表示（ほか\(details.joined(separator: "・"))）"
    }
}

enum ShareJarVisibilityPolicy {
    static func loosePebbleLimit(for format: ShareComposerView.Format) -> Int {
        format == .story ? 64 : 32
    }

    static func aggregateLimit(for format: ShareComposerView.Format) -> Int {
        format == .story ? 12 : 8
    }

    static func achievementLimit(for format: ShareComposerView.Format) -> Int {
        format == .story ? 8 : 6
    }

    static func hiddenContent(
        loosePebbleCount: Int,
        aggregateCount: Int,
        achievementCount: Int,
        format: ShareComposerView.Format
    ) -> ShareHiddenContent {
        ShareHiddenContent(
            loosePebbleCount: max(0, loosePebbleCount - loosePebbleLimit(for: format)),
            aggregateCount: max(0, aggregateCount - aggregateLimit(for: format)),
            achievementCount: max(0, achievementCount - achievementLimit(for: format))
        )
    }

    static func unrepresentedLoosePebbleCount(
        sessionIDs: [UUID],
        representedSessionIDs: [UUID]
    ) -> Int {
        Set(sessionIDs).subtracting(Set(representedSessionIDs)).count
    }
}

/// Bounded lifetime-card composition rules. Production membership exclusion
/// is resolved from the local aggregate store before these values are built;
/// the date helper remains only for decoding old exported snapshots.
enum CompactShareProjectionPolicy {
    struct SummaryComposition: Equatable {
        let pebbleCount: Int
        let measuredPebbleCount: Int
        let manualPebbleCount: Int
    }

    /// A measured-only lifetime card may use compact roots without expanding
    /// every original session only when the persisted summaries prove that no
    /// self-reported focus is hidden inside them. Legacy summaries do not carry
    /// that composition contract, so they deliberately fall back to the honest
    /// bounded-history card.
    static func canUseLifetimeRoots(
        includesSelfReportedFocus: Bool,
        modernSummaryComposition: [SummaryComposition],
        hasLegacySummaries: Bool,
        looseSources: [SessionSource]
    ) -> Bool {
        if includesSelfReportedFocus { return true }
        guard !hasLegacySummaries else { return false }
        guard modernSummaryComposition.allSatisfy({ summary in
            summary.pebbleCount > 0
                && summary.manualPebbleCount == 0
                && summary.measuredPebbleCount == summary.pebbleCount
        }) else { return false }
        return looseSources.allSatisfy(\.isMeasured)
    }

    static func includesLooseSession(
        endingAt: Date,
        summaryEnds: [Date]
    ) -> Bool {
        guard let newestSummaryEnd = summaryEnds.max() else { return true }
        return endingAt > newestSummaryEnd
    }
}

struct SharePebbleRewardIdentity: Equatable {
    let mark: String?
    let accessibilityName: String

    init(
        kind: PebbleKind,
        rewardCounts: RareRewardCounts? = nil,
        presentsRareRewards: Bool = RareRewardReleasePolicy.isEnabled
    ) {
        let presentsRareRewards = RareRewardReleasePolicy
            .permitsInternalTestOverride(presentsRareRewards)
        let kind = presentsRareRewards ? kind : .normal
        let rewardCounts = presentsRareRewards ? rewardCounts : nil
        let baseAccessibilityName: String
        switch kind {
        case .normal:
            mark = nil
            baseAccessibilityName = "通常の集中粒"
        case .gold:
            mark = "✦"
            baseAccessibilityName = "金のレア粒"
        case .prism:
            mark = "◇"
            baseAccessibilityName = "虹のレア粒"
        }
        accessibilityName = baseAccessibilityName
            + (rewardCounts?.multiDrawSummary.map { "、\($0)" } ?? "")
    }
}

struct ShareAchievementIdentity: Equatable {
    let title: String
    let mark: String
    let baseHex: String
    let edgeHex: String
    let glowHex: String

    init(kind: AchievementKind) {
        title = kind.title
        mark = kind.shortMark
        baseHex = kind.gemBaseHex
        edgeHex = kind.gemEdgeHex
        glowHex = kind.gemGlowHex
    }
}

struct ShareAggregateRewardIdentity: Equatable {
    let goldCount: Int
    let prismCount: Int

    init(
        goldCount: Int,
        prismCount: Int,
        presentsRareRewards: Bool = RareRewardReleasePolicy.isEnabled
    ) {
        let presentsRareRewards = RareRewardReleasePolicy
            .permitsInternalTestOverride(presentsRareRewards)
        self.goldCount = presentsRareRewards ? max(0, goldCount) : 0
        self.prismCount = presentsRareRewards ? max(0, prismCount) : 0
    }

    var compactLabel: String? {
        let parts = [
            goldCount > 0 ? "金\(goldCount)" : nil,
            prismCount > 0 ? "虹\(prismCount)" : nil
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var accessibilityDetail: String? {
        let parts = [
            goldCount > 0 ? "金のレア粒\(goldCount)粒" : nil,
            prismCount > 0 ? "虹のレア粒\(prismCount)粒" : nil
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "、")
    }
}

struct ShareRewardSemantics: Equatable {
    let goldCount: Int
    let prismCount: Int
    let achievementCounts: [AchievementKind: Int]
    let presentsRareRewards: Bool

    init(
        goldCount: Int,
        prismCount: Int,
        achievementKinds: [AchievementKind],
        presentsRareRewards: Bool = RareRewardReleasePolicy.isEnabled
    ) {
        let presentsRareRewards = RareRewardReleasePolicy
            .permitsInternalTestOverride(presentsRareRewards)
        self.presentsRareRewards = presentsRareRewards
        self.goldCount = presentsRareRewards ? max(0, goldCount) : 0
        self.prismCount = presentsRareRewards ? max(0, prismCount) : 0
        achievementCounts = Dictionary(grouping: achievementKinds, by: { $0 })
            .mapValues { $0.count }
    }

    var captionDetail: String? {
        let rareParts = [
            goldCount > 0 ? "金のレア粒\(goldCount)粒" : nil,
            prismCount > 0 ? "虹のレア粒\(prismCount)粒" : nil
        ].compactMap { $0 }
        let achievementParts = AchievementKind.allCases.compactMap { kind -> String? in
            guard let count = achievementCounts[kind], count > 0 else { return nil }
            return "\(kind.title)\(count)個"
        }
        let sections = [
            rareParts.isEmpty ? nil : rareParts.joined(separator: "・"),
            achievementParts.isEmpty ? nil : "記念石：\(achievementParts.joined(separator: "・"))"
        ].compactMap { $0 }
        return sections.isEmpty ? nil : "報酬内訳：\(sections.joined(separator: "／"))"
    }

    var accessibilityDetail: String {
        let rare = [
            goldCount > 0 ? "金のレア粒\(goldCount)粒" : nil,
            prismCount > 0 ? "虹のレア粒\(prismCount)粒" : nil
        ].compactMap { $0 }
        let achievements = AchievementKind.allCases.compactMap { kind -> String? in
            guard let count = achievementCounts[kind], count > 0 else { return nil }
            return "\(kind.title)\(count)個"
        }
        let achievementText = achievements.isEmpty
            ? "記念石なし"
            : "記念石の内訳、\(achievements.joined(separator: "、"))"
        guard presentsRareRewards else { return achievementText }
        let rareText = rare.isEmpty ? "レア粒なし" : rare.joined(separator: "、")
        return "\(rareText)。\(achievementText)"
    }
}

struct ShareSessionVisual: Identifiable, Equatable {
    let id: UUID
    let grams: Int
    let source: SessionSource
    let kind: PebbleKind
    let rewardCounts: RareRewardCounts
    let colorHex: String
    let endAt: Date

    var presentationKind: PebbleKind {
        RareRewardPresentationPolicy.kind(kind)
    }

    var presentationRewardCounts: RareRewardCounts {
        RareRewardPresentationPolicy.counts(rewardCounts)
    }

    init(
        id: UUID,
        grams: Int,
        source: SessionSource,
        kind: PebbleKind,
        rewardCounts: RareRewardCounts,
        colorHex: String,
        endAt: Date
    ) {
        self.id = id
        self.grams = max(0, grams)
        self.source = source
        self.kind = kind
        self.rewardCounts = rewardCounts
        self.colorHex = colorHex
        self.endAt = endAt
    }

    init(_ session: StudySession) {
        self.init(
            id: session.id,
            grams: session.grams,
            source: session.source,
            kind: session.pebbleKind,
            rewardCounts: session.rareRewardCounts,
            colorHex: session.displaySubjectColorHex,
            endAt: session.endAt
        )
    }
}

struct ShareAchievementVisual: Identifiable, Equatable {
    let id: UUID
    let kind: AchievementKind
    let colorHex: String

    init(id: UUID, kind: AchievementKind, colorHex: String) {
        self.id = id
        self.kind = kind
        self.colorHex = colorHex
    }

    init(_ achievement: AchievementStone) {
        self.init(
            id: achievement.id,
            kind: achievement.kind,
            colorHex: achievement.displaySubjectColorHex
        )
    }
}

private func shareDrawableSessions(
    sessions: [ShareSessionVisual],
    aggregates: [ShareAggregateVisual]
) -> [ShareSessionVisual] {
    let representedIDs = Set(aggregates.flatMap(\.sessionIDs))
    return Dictionary(grouping: sessions, by: \.id).values.compactMap { duplicates in
        guard let id = duplicates.first?.id, !representedIDs.contains(id) else { return nil }
        return duplicates.max { lhs, rhs in
            if lhs.grams == rhs.grams { return lhs.endAt < rhs.endAt }
            return lhs.grams < rhs.grams
        }
    }
    .sorted { $0.endAt < $1.endAt }
}

private func shareHiddenContent(
    sessions: [ShareSessionVisual],
    aggregates: [ShareAggregateVisual],
    achievements: [ShareAchievementVisual],
    format: ShareComposerView.Format
) -> ShareHiddenContent {
    ShareJarVisibilityPolicy.hiddenContent(
        loosePebbleCount: shareDrawableSessions(sessions: sessions, aggregates: aggregates).count,
        aggregateCount: aggregates.count,
        achievementCount: achievements.count,
        format: format
    )
}

private func shareRewardSemantics(
    sessions: [ShareSessionVisual],
    aggregates: [ShareAggregateVisual],
    achievements: [ShareAchievementVisual]
) -> ShareRewardSemantics {
    // Membership-backed aggregates index these sessions, so only compact or
    // compatibility summaries without membership contribute extra rare counts.
    let unlinkedAggregates = aggregates.filter(\.contributesStandaloneTotals)
    let sessionRewards = RareRewardCounts.total(sessions.map(\.rewardCounts))
    return ShareRewardSemantics(
        goldCount: RareRewardCounts.saturatedSum([
            sessionRewards.goldCount,
            RareRewardCounts.saturatedSum(unlinkedAggregates.map(\.goldPebbleCount))
        ]),
        prismCount: RareRewardCounts.saturatedSum([
            sessionRewards.prismCount,
            RareRewardCounts.saturatedSum(unlinkedAggregates.map(\.prismPebbleCount))
        ]),
        achievementKinds: achievements.map(\.kind)
    )
}

private struct ShareExportSnapshot {
    let id: UUID
    let mediaKind: ShareComposerView.MediaKind
    let format: ShareComposerView.Format
    let sessions: [ShareSessionVisual]
    let aggregates: [ShareAggregateVisual]
    let achievements: [ShareAchievementVisual]
    let includesSelfReportedFocus: Bool
    let jarSnapshot: UIImage?
    let periodLabel: String
    let totalGrams: Int
    let hashtags: [String]
    let caption: String
    let projectionWasCloudUnverified: Bool
    let projectionCacheStamp: AggregateProjectionCacheStamp?
}

/// Keeps the on-screen preview and the exported image on one canonical canvas.
///
/// ShareCardView contains intentionally art-directed fixed-size elements. If
/// SwiftUI proposes a smaller preview while those elements remain unscaled,
/// the disclosure badge and hashtags are the first content pushed below the
/// 4:5 card edge. Scaling the complete canvas preserves the same composition
/// at preview and export sizes instead of independently reflowing either one.
enum ShareCardLayoutPolicy {
    static func canvasSize(for format: ShareComposerView.Format) -> CGSize {
        switch format {
        case .feed:
            CGSize(width: 360, height: 450)
        case .story:
            CGSize(width: 360, height: 640)
        }
    }

    static func scaleToFit(
        canvas: CGSize,
        in container: CGSize
    ) -> CGFloat {
        guard canvas.width > 0,
              canvas.height > 0,
              container.width > 0,
              container.height > 0 else { return 0 }
        return min(container.width / canvas.width, container.height / canvas.height)
    }

    static func fittedSize(
        for format: ShareComposerView.Format,
        in container: CGSize
    ) -> CGSize {
        let canvas = canvasSize(for: format)
        let scale = scaleToFit(canvas: canvas, in: container)
        return CGSize(width: canvas.width * scale, height: canvas.height * scale)
    }

    /// Keeps the primary claim and attribution clear of common feed/story UI
    /// chrome. The exported canvas itself remains edge-to-edge artwork.
    static func contentInsets(for format: ShareComposerView.Format) -> EdgeInsets {
        switch format {
        case .feed:
            EdgeInsets(top: 24, leading: 26, bottom: 22, trailing: 26)
        case .story:
            EdgeInsets(top: 70, leading: 26, bottom: 78, trailing: 26)
        }
    }
}

struct ShareCardView: View {
    let sessions: [ShareSessionVisual]
    let aggregates: [ShareAggregateVisual]
    let achievements: [ShareAchievementVisual]
    let includesSelfReportedFocus: Bool
    let format: ShareComposerView.Format
    let jarSnapshot: UIImage?
    let periodLabel: String
    let hashtags: [String]
    var usesAnimatedArtwork = false
    let animationPhase: Double

    /// Linked aggregates are a visual index over these sessions, not extra
    /// study. Only a compatibility aggregate with no membership contributes a
    /// supplemental total, which keeps old history visible without doubling it.
    private var unlinkedAggregates: [ShareAggregateVisual] {
        aggregates.filter(\.contributesStandaloneTotals)
    }
    private var totalGrams: Int {
        RareRewardCounts.saturatedSum([
            RareRewardCounts.saturatedSum(sessions.map(\.grams)),
            RareRewardCounts.saturatedSum(unlinkedAggregates.map(\.grams))
        ])
    }
    private var measuredCount: Int {
        NonnegativeIntPolicy.sum(
            [sessions.filter { $0.source.isMeasured }.count]
                + unlinkedAggregates.map(\.measuredPebbleCount)
        )
    }
    private var goldCount: Int {
        rewardSemantics.goldCount
    }
    private var prismCount: Int {
        rewardSemantics.prismCount
    }
    private var pebbleCount: Int {
        NonnegativeIntPolicy.sum(
            [sessions.count] + unlinkedAggregates.map(\.pebbleCount)
        )
    }
    private var disclosure: ShareDisclosurePolicy {
        ShareDisclosurePolicy(
            includesSelfReportedFocus: includesSelfReportedFocus,
            achievementCount: achievements.count
        )
    }
    private var rewardSemantics: ShareRewardSemantics {
        shareRewardSemantics(
            sessions: sessions,
            aggregates: aggregates,
            achievements: achievements
        )
    }
    private var hiddenContent: ShareHiddenContent {
        shareHiddenContent(
            sessions: sessions,
            aggregates: aggregates,
            achievements: achievements,
            format: format
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let story = format == .story
            let canvasSize = ShareCardLayoutPolicy.canvasSize(for: format)
            let canvasScale = ShareCardLayoutPolicy.scaleToFit(
                canvas: canvasSize,
                in: proxy.size
            )
            ZStack {
                ShareCardAtmosphere(
                    phase: animationPhase,
                    story: story,
                    usesAnimatedArtwork: usesAnimatedArtwork
                )

                VStack(spacing: 9) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("ポモジェム")
                            .font(PomoGemTheme.brand(story ? 25 : 21))
                            .tracking(1)
                            .foregroundStyle(PomoGemTheme.amber)
                        Spacer()
                        Text(periodLabel)
                            .font(.system(size: story ? 11 : 9, weight: .bold, design: .rounded))
                            .foregroundStyle(PomoGemTheme.muted)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.white.opacity(0.05), in: Capsule())
                    }

                    // Keep the claim outside the glass. A single first gem sits
                    // at the bottle floor, so a bottom overlay would hide the
                    // most important early reward.
                    ShareMassBadge(
                        grams: totalGrams,
                        story: story,
                        animationPhase: animationPhase
                    )

                    ZStack(alignment: .bottom) {
                        ShareJarPedestal(
                            story: story,
                            phase: animationPhase
                        )

                        Group {
                            if let jarSnapshot {
                                Image(uiImage: jarSnapshot)
                                    .resizable()
                                    .scaledToFit()
                                    .accessibilityHidden(true)
                            } else {
                                ShareJarGraphic(
                                    sessions: sessions,
                                    aggregates: aggregates,
                                    achievements: achievements,
                                    format: format,
                                    animationPhase: animationPhase
                                )
                            }
                        }
                        .shadow(color: PomoGemTheme.auroraBlue.opacity(0.22), radius: 15, y: 5)
                    }
                    .frame(maxWidth: story ? 270 : 258)
                    .frame(height: story ? 250 : 216)
                    .overlay(alignment: .topTrailing) {
                        if let compactLabel = hiddenContent.compactLabel {
                            Label(compactLabel, systemImage: "rectangle.stack.fill")
                                .font(.system(size: story ? 9 : 7, weight: .bold, design: .rounded))
                                .foregroundStyle(PomoGemTheme.text)
                                .padding(.horizontal, story ? 8 : 6)
                                .padding(.vertical, story ? 5 : 4)
                                .background(Color(hex: Constants.Color.inkNight).opacity(0.88), in: Capsule())
                                .overlay { Capsule().stroke(.white.opacity(0.16), lineWidth: 0.8) }
                                .padding(story ? 10 : 8)
                        }
                    }

                    VStack(spacing: story ? 8 : 5) {
                        Text(
                            pebbleCount > 0
                                ? "\(pebbleCount)粒の積み重ね"
                                : "\(achievements.count)個の記念石"
                        )
                            .font(.system(size: story ? 13 : 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(PomoGemTheme.text)
                        HStack(spacing: 6) {
                            Text("実測 \(measuredCount)回")
                            Text("・")
                            Text("まとまり \(aggregates.count)")
                            if goldCount > 0 {
                                Text("・")
                                Label("金 \(goldCount)", systemImage: "sparkles")
                            }
                            if prismCount > 0 {
                                Text("・")
                                Label("虹 \(prismCount)", systemImage: "diamond.fill")
                            }
                            if !achievements.isEmpty {
                                Text("・")
                                Label("記念石 \(achievements.count)", systemImage: "medal.fill")
                            }
                        }
                        .font(.system(size: story ? 11 : 9, weight: .bold, design: .rounded))
                        .foregroundStyle(PomoGemTheme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.56)
                        if let hiddenDisclosure = hiddenContent.captionDisclosure {
                            Text(hiddenDisclosure)
                                .font(.system(size: story ? 9 : 7, weight: .semibold, design: .rounded))
                                .foregroundStyle(PomoGemTheme.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.68)
                        }
                        if let cardBadge = disclosure.cardBadge {
                            Text(cardBadge)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(PomoGemTheme.muted)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .overlay { Capsule().stroke(PomoGemTheme.muted.opacity(0.42), lineWidth: 1) }
                        }
                    }

                    Spacer(minLength: 0)
                    if !hashtags.isEmpty {
                        HStack(spacing: story ? 10 : 7) {
                            ForEach(hashtags, id: \.self) { hashtag in
                                Text(hashtag)
                            }
                        }
                        .font(.system(size: story ? 11 : 8, weight: .bold, design: .rounded))
                        .tracking(story ? 0.7 : 0.25)
                        .foregroundStyle(PomoGemTheme.amber)
                        .minimumScaleFactor(0.72)
                        .lineLimit(1)
                    }
                }
                .padding(ShareCardLayoutPolicy.contentInsets(for: format))

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        HStack(spacing: 5) {
                            Text(ShareCopy.wordmark)
                                .tracking(1.1)
                            Text("·")
                                .foregroundStyle(.white.opacity(0.34))
                            Text(ShareCopy.websiteURL.absoluteString)
                        }
                        .font(.system(size: story ? 7.5 : 7, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                        .padding(.horizontal, 13)
                        .padding(.vertical, story ? 19 : 12)
                    }
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .scaleEffect(canvasScale, anchor: .center)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "ポモジェムシェアカード。\(periodLabel)。瓶に積んだ集中、\(ShareMassFormatter.spoken(totalGrams))。\(pebbleCount)粒、実測\(measuredCount)回、まとまり粒\(aggregates.count)個、記念石\(achievements.count)個。\(rewardSemantics.accessibilityDetail)。\(hiddenContent.captionDisclosure ?? "すべての石を表示")。\(disclosure.accessibilityDisclosure)。公式サイト、\(ShareCopy.websiteDisplayName)。\(hashtags.isEmpty ? "ハッシュタグなし" : "ハッシュタグ、\(hashtags.joined(separator: "、"))")"
        )
        .accessibilityIdentifier("share.card")
    }
}

/// The exported card uses the same Aurora world as Home instead of placing a
/// flat social template behind the bottle. Text remains code-native and the
/// artwork is darkened so the mass claim survives platform recompression.
private struct ShareCardAtmosphere: View {
    let phase: Double
    let story: Bool
    let usesAnimatedArtwork: Bool

    var body: some View {
        GeometryReader { proxy in
            let resolvedPhase = usesAnimatedArtwork ? phase : 0.18
            let pulse = (sin(resolvedPhase * .pi * 2) + 1) / 2
            ZStack {
                Color(hex: "050B1B")

                Image("focus.aurora")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .saturation(1.12)
                    .contrast(1.04)
                    .opacity(story ? 0.76 : 0.68)

                LinearGradient(
                    colors: [
                        Color.black.opacity(story ? 0.14 : 0.20),
                        Color(hex: Constants.Color.inkNight).opacity(0.08),
                        Color.black.opacity(story ? 0.34 : 0.42)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                RadialGradient(
                    colors: [
                        PomoGemTheme.auroraBlue.opacity(0.15 + pulse * 0.09),
                        PomoGemTheme.auroraViolet.opacity(0.08),
                        .clear
                    ],
                    center: UnitPoint(x: 0.50, y: story ? 0.55 : 0.52),
                    startRadius: 2,
                    endRadius: proxy.size.width * 0.58
                )

                ShareAmbientSparkles(phase: resolvedPhase, story: story)

                Rectangle()
                    .fill(
                        RadialGradient(
                            colors: [.clear, Color.black.opacity(0.44)],
                            center: .center,
                            startRadius: proxy.size.width * 0.30,
                            endRadius: max(proxy.size.width, proxy.size.height) * 0.72
                        )
                    )
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// A contact shadow plus a cool reflected highlight makes the transparent
/// bottle occupy the same physical stage as the generated Aurora background.
private struct ShareJarPedestal: View {
    let story: Bool
    let phase: Double

    var body: some View {
        let pulse = CGFloat((sin(phase * .pi * 2) + 1) / 2)
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(0.48))
                .frame(width: story ? 218 : 200, height: story ? 41 : 32)

            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            PomoGemTheme.auroraBlue.opacity(0.30 + Double(pulse) * 0.10),
                            PomoGemTheme.auroraViolet.opacity(0.12),
                            .clear
                        ],
                        center: .center,
                        startRadius: 1,
                        endRadius: story ? 112 : 102
                    )
                )
                .frame(width: story ? 238 : 214, height: story ? 36 : 29)
                .blendMode(.screen)
        }
        .offset(y: story ? 7 : 5)
        .accessibilityHidden(true)
    }
}

private struct ShareMassBadge: View {
    let grams: Int
    let story: Bool
    let animationPhase: Double

    var body: some View {
        VStack(spacing: 1) {
            // A user can change the primary purpose without rewriting history.
            // Keep the exported claim accurate even when one bottle spans study
            // and professional phases of life.
            Text("瓶に積んだ集中")
                .font(.system(size: story ? 10 : 8, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(PomoGemTheme.muted)
            Text(ShareMassFormatter.visual(grams))
                .font(.system(size: story ? 40 : 31, weight: .black, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.72)
                .lineLimit(1)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color(hex: "DDF3FF"), PomoGemTheme.auroraBlue],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: PomoGemTheme.auroraBlue.opacity(0.24), radius: 5, y: 2)
        }
        .padding(.horizontal, story ? 22 : 17)
        .padding(.vertical, story ? 7 : 5)
        .background {
            RoundedRectangle(cornerRadius: story ? 18 : 15, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: Constants.Color.inkRaised).opacity(0.94),
                            Color(hex: Constants.Color.inkNight).opacity(0.90),
                            PomoGemTheme.auroraViolet.opacity(0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: story ? 18 : 15, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            PomoGemTheme.auroraWarm.opacity(0.70),
                            .white.opacity(0.28),
                            PomoGemTheme.auroraBlue.opacity(0.50)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.42), radius: 10, y: 5)
        .overlay {
            RoundedRectangle(cornerRadius: story ? 18 : 15, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.22), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .mask(RoundedRectangle(cornerRadius: story ? 18 : 15, style: .continuous))
                .offset(x: CGFloat(sin(animationPhase * .pi * 2)) * (story ? 26 : 20))
                .allowsHitTesting(false)
        }
    }
}

private enum ShareMassFormatter {
    static func visual(_ grams: Int) -> String {
        "\(max(0, grams).formatted(.number.grouping(.automatic)))g"
    }

    static func spoken(_ grams: Int) -> String {
        "\(max(0, grams).formatted(.number.grouping(.automatic)))グラム"
    }
}

private struct ShareJarGraphic: View {
    let sessions: [ShareSessionVisual]
    let aggregates: [ShareAggregateVisual]
    let achievements: [ShareAchievementVisual]
    let format: ShareComposerView.Format
    let animationPhase: Double

    private var visibleSessions: [ShareSessionVisual] {
        Array(shareDrawableSessions(sessions: sessions, aggregates: aggregates).suffix(
            ShareJarVisibilityPolicy.loosePebbleLimit(for: format)
        ))
    }

    private var visibleAggregates: [ShareAggregateVisual] {
        Array(aggregates.suffix(ShareJarVisibilityPolicy.aggregateLimit(for: format)))
    }

    private var visibleAchievements: [ShareAchievementVisual] {
        Array(achievements.suffix(ShareJarVisibilityPolicy.achievementLimit(for: format)))
    }

    var body: some View {
        GeometryReader { proxy in
            jar(size: proxy.size)
        }
        .accessibilityHidden(true)
    }

    private func jar(size: CGSize) -> some View {
        let story = format == .story
        let sessionColumnCount = story ? 9 : 8
        let compactSessionSize: CGFloat = min(
            size.width / CGFloat(sessionColumnCount + 2),
            story ? 23.0 : 20.0
        )
        let expandedSessionSize: CGFloat = min(
            story ? 31.0 : 27.0,
            compactSessionSize * 1.34
        )
        let sessionSize = visibleSessions.count <= 3 ? expandedSessionSize : compactSessionSize
        let sessionRows = visibleSessions.isEmpty
            ? 0
            : Int(ceil(Double(visibleSessions.count) / Double(sessionColumnCount)))
        let sessionBandHeight = CGFloat(sessionRows) * sessionSize * 0.78
        let highlightsSingleAggregate = visibleAggregates.count == 1
            && visibleSessions.isEmpty
            && visibleAchievements.isEmpty

        return ZStack(alignment: .bottom) {
            bottleBackground(size: size)
            bottomGlow(size: size)
            aggregateLayer(
                availableWidth: size.width,
                highlightsSingleAggregate: highlightsSingleAggregate,
                story: story
            )
            sessionLayer(columnCount: sessionColumnCount, sessionSize: sessionSize)
            achievementLayer(
                availableWidth: size.width,
                sessionBandHeight: sessionBandHeight
            )
            leadingGlassHighlight(size: size)
            trailingGlassHighlight(size: size)
            movingGlassHighlight(size: size)
        }
        .clipShape(ShareBottleShape())
        .overlay { bottleOutline }
        .overlay(alignment: .top) { bottleRim(size: size) }
        .shadow(color: PomoGemTheme.auroraBlue.opacity(0.22), radius: 5, y: 2)
    }

    private func bottleBackground(size: CGSize) -> some View {
        ZStack {
            ShareBottleShape()
                .fill(
                    LinearGradient(
                        colors: [
                            PomoGemTheme.auroraBlue.opacity(0.11),
                            Color(hex: Constants.Color.glassAbsorption).opacity(0.18),
                            .white.opacity(0.025),
                            PomoGemTheme.auroraViolet.opacity(0.09)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            ShareBottleShape()
                .stroke(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.34),
                            PomoGemTheme.auroraBlue.opacity(0.05),
                            .white.opacity(0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .padding(max(2.0, size.width * 0.012))
        }
    }

    private func bottomGlow(size: CGSize) -> some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [
                        PomoGemTheme.auroraBlue.opacity(0.22),
                        PomoGemTheme.auroraViolet.opacity(0.08),
                        .clear
                    ],
                    center: .center,
                    startRadius: 1,
                    endRadius: size.width * 0.39
                )
            )
            .frame(width: size.width * 0.78, height: size.height * 0.11)
            .blur(radius: 3)
            .padding(.bottom, size.height * 0.012)
    }

    @ViewBuilder
    private func aggregateLayer(
        availableWidth: CGFloat,
        highlightsSingleAggregate: Bool,
        story: Bool
    ) -> some View {
        ForEach(Array(visibleAggregates.enumerated()), id: \.element.id) { index, aggregate in
            aggregateView(
                aggregate,
                index: index,
                availableWidth: availableWidth,
                highlightsSingleAggregate: highlightsSingleAggregate,
                story: story
            )
        }
    }

    private func aggregateView(
        _ aggregate: ShareAggregateVisual,
        index: Int,
        availableWidth: CGFloat,
        highlightsSingleAggregate: Bool,
        story: Bool
    ) -> some View {
        let columnCount = 4
        let pebbleSize = aggregateSize(
            for: aggregate,
            availableWidth: availableWidth,
            highlightsSingleAggregate: highlightsSingleAggregate,
            story: story
        )
        let column = index % columnCount
        let row = index / columnCount
        let xStep = availableWidth / CGFloat(columnCount + 1)
        let rowAdjustment: CGFloat = row.isMultiple(of: 2) ? -2 : 3
        let regularX = CGFloat(column + 1) * xStep - availableWidth / 2 + rowAdjustment
        let x = highlightsSingleAggregate ? CGFloat.zero : regularX
        let y: CGFloat = highlightsSingleAggregate
            ? -(story ? 25 : 18)
            : -CGFloat(row) * 39 - 12
        let wave = sin(animationPhase * .pi * 2 + Double(index) * 1.19)

        return ZStack {
            if highlightsSingleAggregate {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                aggregateHeroColor(aggregate).opacity(0.42),
                                aggregateHeroColor(aggregate).opacity(0.12),
                                .clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: pebbleSize * 0.86
                        )
                    )
                    .frame(width: pebbleSize * 1.7, height: pebbleSize * 1.7)
                    .scaleEffect(1 + CGFloat(max(0, wave)) * 0.05)
                Image(systemName: "sparkles")
                    .font(.system(size: pebbleSize * 0.22, weight: .bold))
                    .foregroundStyle(.white.opacity(0.78))
                    .offset(x: pebbleSize * 0.66, y: -pebbleSize * 0.55)
            }
            ShareAggregatePebble(aggregate: aggregate)
                .frame(width: pebbleSize, height: pebbleSize)
        }
        .frame(
            width: highlightsSingleAggregate ? pebbleSize * 1.7 : pebbleSize,
            height: highlightsSingleAggregate ? pebbleSize * 1.7 : pebbleSize
        )
        .rotationEffect(.degrees(wave * 3.2))
        .offset(x: x + CGFloat(wave) * 1.7, y: y - CGFloat(max(0, wave)) * 2.2)
    }

    @ViewBuilder
    private func sessionLayer(columnCount: Int, sessionSize: CGFloat) -> some View {
        ForEach(Array(visibleSessions.enumerated()), id: \.element.id) { index, session in
            sessionView(session, index: index, columnCount: columnCount, size: sessionSize)
        }
    }

    private func sessionView(
        _ session: ShareSessionVisual,
        index: Int,
        columnCount: Int,
        size: CGFloat
    ) -> some View {
        let column = index % columnCount
        let row = index / columnCount
        let rowAdjustment: CGFloat = row.isMultiple(of: 2) ? 0 : size * 0.42
        let x = (CGFloat(column) - CGFloat(columnCount - 1) / 2) * size * 0.92 + rowAdjustment
        let y = -CGFloat(row) * size * 0.78 - aggregateBandHeight
        let wave = sin(animationPhase * .pi * 2 + Double(index) * 0.91)

        return ShareSessionGem(
            session: session,
            variant: stableShareVariant(session.id),
            glow: (wave + 1) / 2
        )
        .frame(width: size, height: size)
        .scaleEffect(1 + CGFloat(max(0, wave)) * 0.035)
        .offset(x: x + CGFloat(wave) * 1.3, y: y - CGFloat(max(0, wave)) * 2.8)
    }

    @ViewBuilder
    private func achievementLayer(availableWidth: CGFloat, sessionBandHeight: CGFloat) -> some View {
        ForEach(Array(visibleAchievements.enumerated()), id: \.element.id) { index, stone in
            achievementView(
                stone,
                index: index,
                availableWidth: availableWidth,
                sessionBandHeight: sessionBandHeight
            )
        }
    }

    private func achievementView(
        _ stone: ShareAchievementVisual,
        index: Int,
        availableWidth: CGFloat,
        sessionBandHeight: CGFloat
    ) -> some View {
        let columnCount = 4
        let stoneSize: CGFloat = min(availableWidth / 7.2, 34)
        let column = index % columnCount
        let row = index / columnCount
        let centeredColumn = CGFloat(column) - CGFloat(columnCount - 1) * 0.5
        let rowOffset: CGFloat = row.isMultiple(of: 2) ? 0 : stoneSize * 0.4
        let x = centeredColumn * stoneSize * 1.05 + rowOffset
        let y = -CGFloat(row) * stoneSize * 0.74 - aggregateBandHeight - sessionBandHeight - 7
        let glowPhase = animationPhase * .pi * 2 + Double(index) * 0.74
        let glow = (sin(glowPhase) + 1) / 2

        return ShareAchievementGem(
            stone: stone,
            variant: stableShareVariant(stone.id),
            glow: glow
        )
        .frame(width: stoneSize, height: stoneSize)
        .offset(x: x, y: y)
    }

    private func leadingGlassHighlight(size: CGSize) -> some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [.white.opacity(0.34), .white.opacity(0.05), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: max(5, size.width * 0.024), height: size.height * 0.56)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, size.width * 0.14)
    }

    private func trailingGlassHighlight(size: CGSize) -> some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [.white.opacity(0.17), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: max(2, size.width * 0.010), height: size.height * 0.34)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, size.width * 0.13)
            .padding(.bottom, size.height * 0.13)
    }

    private func movingGlassHighlight(size: CGSize) -> some View {
        LinearGradient(
            colors: [.clear, .white.opacity(0.12), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: size.width * 0.30)
        .rotationEffect(.degrees(8))
        .offset(x: size.width * CGFloat(sin(animationPhase * .pi * 2)) * 0.42)
        .blendMode(.screen)
    }

    private var bottleOutline: some View {
        ShareBottleShape()
            .stroke(
                LinearGradient(
                    colors: [
                        .white.opacity(0.86),
                        PomoGemTheme.auroraBlue.opacity(0.50),
                        PomoGemTheme.auroraViolet.opacity(0.42),
                        .white.opacity(0.62)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.8
            )
    }

    private func bottleRim(size: CGSize) -> some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        .white.opacity(0.12),
                        Color(hex: Constants.Color.inkNight).opacity(0.92),
                        PomoGemTheme.auroraViolet.opacity(0.12)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.78), PomoGemTheme.auroraBlue.opacity(0.42)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1.5
                    )
            }
            .frame(width: size.width * 0.36, height: max(9, size.height * 0.045))
            .padding(.top, size.height * 0.018)
    }

    private var aggregateBandHeight: CGFloat {
        guard !visibleAggregates.isEmpty else { return 7 }
        let rows = Int(ceil(Double(visibleAggregates.count) / 4.0))
        return CGFloat(rows) * 39 + 12
    }

    private func aggregateSize(
        for aggregate: ShareAggregateVisual,
        availableWidth: CGFloat,
        highlightsSingleAggregate: Bool,
        story: Bool
    ) -> CGFloat {
        if highlightsSingleAggregate {
            return min(story ? 86 : 74, max(48, availableWidth * 0.25))
        }
        return min(48, 34 + CGFloat(max(aggregate.level - 1, 0)) * 5)
    }

    private func aggregateHeroColor(_ aggregate: ShareAggregateVisual) -> Color {
        guard let first = aggregate.colorMix.first else { return PomoGemTheme.amber }
        return ShareColorPolicy.color(first.hex, vivid: true)
    }
}

private func stableShareVariant(_ id: UUID) -> Int {
    id.uuidString.utf8.reduce(2_166_136_261) { hash, byte in
        (hash ^ Int(byte)) &* 16_777_619
    } & 0x7FFF_FFFF
}

private struct ShareGemShape: Shape {
    let variant: Int

    func path(in rect: CGRect) -> Path {
        let count = 8
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let baseRadius = min(rect.width, rect.height) * 0.48
        var path = Path()
        for index in 0..<count {
            let phase = (Double(index) / Double(count)) * Double.pi * 2 - Double.pi / 2
            let stableOffset = ((variant &+ index &* 17) % 9) - 4
            let radiusScale = CGFloat(0.91 + Double(stableOffset) * 0.012)
            let point = CGPoint(
                x: center.x + CGFloat(cos(phase)) * baseRadius * radiusScale,
                y: center.y + CGFloat(sin(phase)) * baseRadius * radiusScale
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

private struct ShareGemFacetLines: Shape {
    let variant: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.43
        for index in stride(from: variant % 2, to: 8, by: 2) {
            let phase = (Double(index) / 8) * Double.pi * 2 - Double.pi / 2
            path.move(to: center)
            path.addLine(to: CGPoint(
                x: center.x + CGFloat(cos(phase)) * radius,
                y: center.y + CGFloat(sin(phase)) * radius
            ))
        }
        return path
    }
}

private struct ShareSessionGem: View {
    let session: ShareSessionVisual
    let variant: Int
    let glow: Double

    private var identity: SharePebbleRewardIdentity {
        SharePebbleRewardIdentity(
            kind: session.presentationKind,
            rewardCounts: session.presentationRewardCounts
        )
    }

    private var material: AnyShapeStyle {
        switch session.presentationKind {
        case .normal:
            let base = ShareColorPolicy.color(session.colorHex, vivid: true)
            return AnyShapeStyle(
                LinearGradient(
                    colors: [.white.opacity(0.82), base, base.opacity(0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .gold:
            return AnyShapeStyle(
                RadialGradient(
                    colors: [.white, Color("pebble.gold"), .orange],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 24
                )
            )
        case .prism:
            return AnyShapeStyle(
                AngularGradient(
                    colors: [.pink, .yellow, .green, .cyan, .blue, .purple, .pink],
                    center: .center
                )
            )
        }
    }

    var body: some View {
        if session.presentationKind == .normal {
            facetedBody
        } else {
            legacyBody
        }
    }

    /// Normal gems reuse the jar's baked faceted artwork so a shared card
    /// and the live jar show the same stone.
    private var facetedBody: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let isMeasured = session.source.isMeasured
            let rung = isMeasured ? GemCutLadder.standard.loose : GemCutLadder.standard.selfReported
            let spec = GemArtworkSpec(
                rung: rung,
                colors: [GemColorShare(hex: session.colorHex, fraction: 1)],
                variant: variant % GemArtworkSpec.variantCount,
                isMuted: !isMeasured,
                showsDashedRing: !isMeasured
            )
            Image(uiImage: GemArtwork.bodyImage(for: spec, radius: side / 2))
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .shadow(
            color: ShareColorPolicy.color(session.colorHex, vivid: true).opacity(0.42 + glow * 0.22),
            radius: 3 + glow * 2.5
        )
    }

    private var legacyBody: some View {
        ShareGemShape(variant: variant)
            .fill(material)
            .overlay {
                ShareGemShape(variant: variant)
                    .fill(
                        RadialGradient(
                            colors: [
                                .white.opacity(0.64),
                                .white.opacity(0.10),
                                .clear
                            ],
                            center: UnitPoint(
                                x: 0.28 + glow * 0.18,
                                y: 0.22 + glow * 0.08
                            ),
                            startRadius: 0,
                            endRadius: 16
                        )
                    )
                    .blendMode(.screen)
            }
            .overlay {
                ShareGemFacetLines(variant: variant)
                    .stroke(.white.opacity(0.32 + glow * 0.22), lineWidth: 0.7)
                    .clipShape(ShareGemShape(variant: variant))
            }
            .overlay {
                ShareGemShape(variant: variant)
                    .stroke(
                        session.source.isMeasured ? .white.opacity(0.54) : .white.opacity(0.82),
                        style: StrokeStyle(
                            lineWidth: session.source.isMeasured ? 0.8 : 1.2,
                            dash: session.source.isMeasured ? [] : [2, 2]
                        )
                    )
            }
            .overlay {
                if let mark = identity.mark {
                    Text(mark)
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.9), radius: 1.5)
                }
            }
            // Only rare kinds reach this legacy body (normal gems use the
            // baked artwork above), so the rare glow applies directly.
            .shadow(color: rareShadowColor, radius: rareShadowRadius)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "sparkle")
                    .font(.system(size: 6 + glow * 3, weight: .black))
                    .foregroundStyle(.white)
                    .shadow(color: .white.opacity(0.72), radius: 3)
                    .opacity(0.28 + glow * 0.72)
                    .offset(x: 2, y: -2)
            }
    }

    private var rareShadowColor: Color {
        .white.opacity(0.28 + glow * 0.26)
    }

    private var rareShadowRadius: CGFloat {
        CGFloat(5 + glow * 4)
    }
}

private struct ShareAchievementGem: View {
    let stone: ShareAchievementVisual
    let variant: Int
    let glow: Double

    private var identity: ShareAchievementIdentity {
        ShareAchievementIdentity(kind: stone.kind)
    }

    var body: some View {
        ShareGemShape(variant: variant)
            .fill(
                RadialGradient(
                    colors: [
                        ShareColorPolicy.color(identity.edgeHex, vivid: true),
                        ShareColorPolicy.color(identity.baseHex, vivid: true),
                        Color(hex: Constants.Color.inkNight).opacity(0.58)
                    ],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 34
                )
            )
            .overlay {
                ShareGemFacetLines(variant: variant)
                    .stroke(.white.opacity(0.30), lineWidth: 0.8)
                    .clipShape(ShareGemShape(variant: variant))
            }
            .overlay {
                ShareGemShape(variant: variant)
                    .stroke(ShareColorPolicy.color(identity.edgeHex, vivid: true), lineWidth: 1.7)
            }
            .overlay {
                Capsule()
                    .fill(Color(hex: Constants.Color.inkNight).opacity(0.78))
                    .frame(
                        width: stone.kind == .perfectScore ? 25 : 18,
                        height: stone.kind == .perfectScore ? 15 : 18
                    )
                    .overlay {
                        Text(identity.mark)
                            .font(.system(
                                size: stone.kind == .perfectScore ? 7 : 11,
                                weight: .black,
                                design: .rounded
                            ))
                            .foregroundStyle(.white)
                    }
            }
            .shadow(
                color: ShareColorPolicy.color(identity.glowHex, vivid: true)
                    .opacity(0.30 + glow * 0.34),
                radius: CGFloat(5 + glow * 4)
            )
    }
}

private struct ShareBottleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + width * 0.36, y: rect.minY + height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + width * 0.36, y: rect.minY + height * 0.14))
        path.addCurve(
            to: CGPoint(x: rect.minX + width * 0.10, y: rect.minY + height * 0.25),
            control1: CGPoint(x: rect.minX + width * 0.34, y: rect.minY + height * 0.18),
            control2: CGPoint(x: rect.minX + width * 0.14, y: rect.minY + height * 0.18)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + width * 0.05, y: rect.minY + height * 0.35),
            control1: CGPoint(x: rect.minX + width * 0.07, y: rect.minY + height * 0.28),
            control2: CGPoint(x: rect.minX + width * 0.05, y: rect.minY + height * 0.31)
        )
        path.addLine(to: CGPoint(x: rect.minX + width * 0.035, y: rect.minY + height * 0.88))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + width * 0.14, y: rect.minY + height * 0.97),
            control: CGPoint(x: rect.minX + width * 0.035, y: rect.minY + height * 0.97)
        )
        path.addLine(to: CGPoint(x: rect.minX + width * 0.86, y: rect.minY + height * 0.97))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + width * 0.965, y: rect.minY + height * 0.88),
            control: CGPoint(x: rect.minX + width * 0.965, y: rect.minY + height * 0.97)
        )
        path.addLine(to: CGPoint(x: rect.minX + width * 0.95, y: rect.minY + height * 0.35))
        path.addCurve(
            to: CGPoint(x: rect.minX + width * 0.90, y: rect.minY + height * 0.25),
            control1: CGPoint(x: rect.minX + width * 0.95, y: rect.minY + height * 0.31),
            control2: CGPoint(x: rect.minX + width * 0.93, y: rect.minY + height * 0.28)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + width * 0.64, y: rect.minY + height * 0.14),
            control1: CGPoint(x: rect.minX + width * 0.86, y: rect.minY + height * 0.18),
            control2: CGPoint(x: rect.minX + width * 0.66, y: rect.minY + height * 0.18)
        )
        path.addLine(to: CGPoint(x: rect.minX + width * 0.64, y: rect.minY + height * 0.05))
        path.closeSubpath()
        return path
    }
}

private struct ShareAggregatePebble: View {
    let aggregate: ShareAggregateVisual

    private var colors: [Color] {
        let values = aggregate.colorMix.prefix(5).map {
            ShareColorPolicy.color($0.hex, vivid: true)
        }
        return values.isEmpty ? [PomoGemTheme.raised, PomoGemTheme.card] : values
    }
    private var rewardIdentity: ShareAggregateRewardIdentity {
        ShareAggregateRewardIdentity(
            goldCount: aggregate.goldPebbleCount,
            prismCount: aggregate.prismPebbleCount
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let variant = stableShareVariant(aggregate.id)
            ZStack {
                Image(uiImage: GemArtwork.bodyImage(for: artworkSpec(variant: variant), radius: size / 2))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                if rewardIdentity.goldCount > 0 {
                    Circle()
                        .trim(from: 0, to: rewardIdentity.prismCount > 0 ? 0.47 : 1)
                        .stroke(
                            LinearGradient(
                                colors: [.white, Color("pebble.gold"), .orange],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                if rewardIdentity.prismCount > 0 {
                    Circle()
                        .trim(from: rewardIdentity.goldCount > 0 ? 0.53 : 0, to: 1)
                        .stroke(
                            AngularGradient(
                                colors: [.pink, .yellow, .green, .cyan, .blue, .purple, .pink],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: -1) {
                    Text("×\(aggregate.pebbleCount)")
                        .font(.system(size: aggregate.pebbleCount >= 100 ? 7 : 8, weight: .heavy, design: .rounded))
                    if let rareLabel = rewardIdentity.compactLabel {
                        Text(rareLabel)
                            .font(.system(size: 5.5, weight: .black, design: .rounded))
                            .minimumScaleFactor(0.65)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(Color(red: 0.035, green: 0.05, blue: 0.11).opacity(0.78), in: Capsule())
                .shadow(color: .black.opacity(0.6), radius: 1.5)
            }
            .frame(width: size, height: size)
            .shadow(color: colors[0].opacity(0.58), radius: size * 0.16)
        }
    }

    /// Same rung (by contained grams) and colour shares as the jar.
    private func artworkSpec(variant: Int) -> GemArtworkSpec {
        GemArtworkSpec(
            rung: GemCutLadder.standard.rung(aggregateGrams: aggregate.grams),
            colors: GemArtworkSpec.aggregateColors(
                aggregate.colorMix,
                fallbackHex: Constants.Color.textMute
            ),
            variant: variant % GemArtworkSpec.variantCount,
            isMuted: aggregate.manualPebbleCount > aggregate.measuredPebbleCount,
            showsDashedRing: aggregate.manualPebbleCount > 0
        )
    }
}

private struct AnimatedShareCardPreview: View {
    let sessions: [ShareSessionVisual]
    let aggregates: [ShareAggregateVisual]
    let achievements: [ShareAchievementVisual]
    let includesSelfReportedFocus: Bool
    let format: ShareComposerView.Format
    let jarSnapshot: UIImage?
    let periodLabel: String
    let hashtags: [String]
    let usesAnimatedArtwork: Bool
    let animates: Bool

    var body: some View {
        if animates {
            TimelineView(.animation(minimumInterval: 1 / 24)) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                card(phase: elapsed.truncatingRemainder(dividingBy: 2) / 2)
            }
        } else {
            card(phase: 0.18)
        }
    }

    private func card(phase: Double) -> some View {
        ShareCardView(
            sessions: sessions,
            aggregates: aggregates,
            achievements: achievements,
            includesSelfReportedFocus: includesSelfReportedFocus,
            format: format,
            jarSnapshot: jarSnapshot,
            periodLabel: periodLabel,
            hashtags: hashtags,
            usesAnimatedArtwork: usesAnimatedArtwork,
            animationPhase: phase
        )
    }
}

private struct ShareAmbientSparkles: View {
    let phase: Double
    let story: Bool

    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<9, id: \.self) { index in
                sparkle(index: index, size: proxy.size)
            }
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func sparkle(index: Int, size: CGSize) -> some View {
        let seed = Double(index) * 0.83
        let wave = (sin(phase * .pi * 2 + seed) + 1) / 2
        let xFraction = 0.10 + CGFloat((index * 37) % 83) / 100.0
        let yBase: CGFloat = story ? 0.16 : 0.09
        let yFraction = yBase + CGFloat((index * 29) % 66) / 100.0
        let symbol = index.isMultiple(of: 3) ? "sparkle" : "circle.fill"
        let fontSize: CGFloat = index.isMultiple(of: 3)
            ? CGFloat(7.0 + wave * 3.0)
            : CGFloat(2.5 + wave * 1.8)
        let color: Color = index.isMultiple(of: 3) ? PomoGemTheme.amber : .white

        return Image(systemName: symbol)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(color)
            .opacity(0.12 + wave * 0.38)
            .position(x: size.width * xFraction, y: size.height * yFraction - CGFloat(wave) * 5)
    }
}


private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let didCreateController: () -> Void
    let completion: (Bool, UIActivity.ActivityType?, Error?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.allowsProminentActivity = true
#if DEBUG
        if LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess {
            controller.view.accessibilityIdentifier = "share.system-sheet"
        }
#endif
        controller.completionWithItemsHandler = { activityType, completed, _, error in
            DispatchQueue.main.async {
                completion(completed, activityType, error)
            }
        }
        // Defer the callback past SwiftUI's representable update transaction.
        // The UI test separately requires a hittable system cancel control,
        // so this records controller creation without overclaiming visibility.
        DispatchQueue.main.async {
            didCreateController()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
