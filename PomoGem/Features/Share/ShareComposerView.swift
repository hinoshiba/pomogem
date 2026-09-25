import Photos
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
    /// Bumped whenever the loaded records or their page flags change, which
    /// is the only time the cached selection must be rebuilt for them.
    @State private var shareRecordsGeneration = 0
    @State private var selectionCache = ShareSelectionCache()
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
    /// The card's content, resolved once per change of its inputs rather
    /// than on every body pass (history-10). Keystrokes, chips, format and
    /// media changes reuse the cached value.
    private var selection: ShareSelectionModel {
        selectionCache.model(for: selectionKey) {
            ShareSelectionModel.make(selectionInput)
        }
    }

    private var selectionKey: ShareSelectionInput.Key {
        ShareSelectionInput.Key(
            recordsGeneration: shareRecordsGeneration,
            scope: scope,
            includeManual: includeManual,
            resetSnapshots: resetSnapshots,
            allowsAggregateSummaries: aggregateProjectionPresentation.allowsAggregateSummaries,
            acceptsVerifiedAggregateCache: aggregateProjectionPresentation
                .acceptsVerifiedAggregateCache(aggregateProjectionCacheStamp)
        )
    }

    private var selectionInput: ShareSelectionInput {
        ShareSelectionInput(
            scope: scope,
            includeManual: includeManual,
            resetSnapshots: resetSnapshots,
            allowsAggregateSummaries: aggregateProjectionPresentation.allowsAggregateSummaries,
            acceptsVerifiedAggregateCache: aggregateProjectionPresentation
                .acceptsVerifiedAggregateCache(aggregateProjectionCacheStamp),
            storedSessions: storedSessions,
            looseSessions: looseSessions,
            storedAchievementStones: storedAchievementStones,
            storedAggregatePebbles: storedAggregatePebbles,
            storedStrata: storedStrata,
            acceptedAggregateRootIDs: acceptedAggregateRootIDs,
            localRepresentedSessionIDs: localRepresentedSessionIDs,
            historyPageIsPartial: historyPageIsPartial,
            loosePageIsPartial: loosePageIsPartial,
            aggregatePageIsPartial: aggregatePageIsPartial,
            aggregateValidationIsIncomplete: aggregateValidationIsIncomplete,
            allSessionRowCount: allSessionRowCount
        )
    }

    private var shareCaption: String {
        let selection = selection
        let semantics = shareRewardSemantics(
            sessions: selection.sessions,
            aggregates: selection.aggregates,
            achievements: selection.achievements
        )
        let hiddenContent = shareHiddenContent(
            sessions: selection.sessions,
            aggregates: selection.aggregates,
            achievements: selection.achievements,
            format: format
        )
        return ShareCopy.caption(
            subject: shareCaptionSubject,
            grams: ShareMassFormatter.visual(selection.totalGrams),
            focusTime: ShareMassFormatter.focusTime(selection.totalGrams),
            includesSelfReportedFocus: selection.includesSelfReportedFocus,
            achievementCount: selection.achievements.count,
            rewardDetail: semantics.captionDetail,
            visualDisclosure: hiddenContent.captionDisclosure,
            hashtags: activeHashtags
        )
    }

    private var activeHashtags: [String] {
        var values = ShareCopy.hashtagChoices.filter(selectedHashtags.contains)
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
            let selection = selection
            if historyPageIsPartial && !selection.usesCompactRootProjection {
                return includeManual
                    ? "最近の記録から選んだ集中"
                    : "最近の記録から選んだ実測集中"
            }
            if selection.compactProjectionIsIncomplete {
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
        let selection = selection
        switch scope {
        case .all where historyPageIsPartial && !includeManual && !selection.usesCompactRootProjection:
            return "最近の実測・最新\(BoundedHistoryPolicy.periodSessionLimit)件の記録内"
        case .all where historyPageIsPartial && !selection.usesCompactRootProjection:
            return "最近の記録・最新\(BoundedHistoryPolicy.periodSessionLimit)件"
        case .all where selection.compactProjectionIsIncomplete:
            return "これまで・読み込み分"
        case .month where historyPageIsPartial:
            return "\(scope.periodLabel)・表示分"
        default:
            return scope.periodLabel
        }
    }

    private var settingsSummary: String {
        let selection = selection
        let medium = mediaKind == .animatedGIF ? "GIF" : "静止画"
        let shape = format == .feed ? "4:5" : "9:16"
        // Describe the focus on the card first, then any 記念石 separately.
        // A stone used to turn the whole label into 「自己申告あり」 even while
        // self-reported focus was left out (walk-std-04).
        let focusLabel: String
        if selection.includesSelfReportedFocus {
            focusLabel = "自己申告あり"
        } else if selection.hasExcludedSelfReportedContent {
            focusLabel = "実測のみ（自己申告は除外）"
        } else {
            focusLabel = "実測のみ"
        }
        let scopeLabel = selection.achievements.isEmpty
            ? focusLabel
            : String(
                localized: "\(focusLabel)・記念石は自己申告",
                table: "Share",
                comment: "Share settings summary: focus scope, then the note that stones are self-reported"
            )
        let hashtagLabel = activeHashtags.isEmpty
            ? "タグなし"
            : "タグ\(activeHashtags.count)個"
        return "\(medium)・\(shape)・\(scopeLabel)・\(hashtagLabel)"
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
                    } else if selection.hasShareableContent {
                        AnimatedShareCardPreview(
                            sessions: selection.sessions,
                            aggregates: selection.aggregates,
                            achievements: selection.achievements,
                            includesSelfReportedFocus: selection.includesSelfReportedFocus,
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

                    if showsExcludedSelfReportedNotice {
                        excludedSelfReportedNotice
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
                            // How often this process resolved the card
                            // selection versus reused it; typing a tag must
                            // only reuse it. An overlay, so the probe adds no
                            // height the UI tests' scrolling would notice.
                            .overlay {
                                Text("Share selection probe")
                                    .font(.system(size: 1))
                                    .foregroundStyle(Color.clear)
                                    .frame(width: 1, height: 1)
                                    .accessibilityIdentifier("share.debug.selection")
                                    .accessibilityLabel("Share selection probe")
                                    .accessibilityValue(Text(verbatim: "builds=\(ShareSelectionCache.debugBuildCount);lookups=\(ShareSelectionCache.debugLookupCount)"))
                                    .allowsHitTesting(false)
                            }
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
                    // Keep the pinned bar well under half of a 667 pt screen
                    // at AX5, as the timer's pinned controls do.
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    // One render at a time: a photo save renders the same
                    // cards on the main actor.
                    .disabled(isRendering || isSaving || !selection.hasShareableContent)
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
                // No duration: 720-pixel GIFs take several seconds on a
                // small iPhone, and a photo save renders two of them.
                Text("端末の中だけで生成", tableName: "Share")
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
            // No line cap: the scope can now name both the excluded focus and
            // the stones, which needs more lines at accessibility sizes.
            Text(settingsSummary)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(PomoGemTheme.text)
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
                ProgressView()
                    .tint(PomoGemTheme.text)
                    .accessibilityLabel(Text("写真に保存しています", tableName: "Share"))
            } else {
                Label("写真に2サイズ保存", systemImage: "photo.badge.arrow.down")
            }
        }
        .buttonStyle(PomoGemSecondaryButtonStyle())
        .disabled(isRendering || isSaving || !selection.hasShareableContent)
    }

    private var shareHashtagStrip: some View {
        // At accessibility sizes the heading and the copy button stack, so
        // neither is squeezed into a one-character column.
        let headerLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 7))
        return VStack(alignment: .leading, spacing: 9) {
            headerLayout {
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "number")
                        .font(.caption.weight(.black))
                        .foregroundStyle(PomoGemTheme.amber)
                        .accessibilityHidden(true)
                }
                Text("一緒に渡すハッシュタグ")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PomoGemTheme.muted)
                Spacer(minLength: 0)
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
            // Wrapping, not a sideways scroll: the study tags used to start
            // off-screen on a 375 pt iPhone, and at AX5 only the first chip
            // was visible (product-06).
            ShareFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(ShareCopy.hashtagChoices, id: \.self) { hashtag in
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
        // At accessibility sizes the pinned bar keeps only the action: the
        // icons and the one-line description (also in the hint) used to grow
        // it over half of the screen, above the card it shares.
        let isCompact = dynamicTypeSize.isAccessibilitySize
        HStack(spacing: 13) {
            if !isCompact {
                ZStack {
                    Circle().fill(.white.opacity(0.18))
                    Image(systemName: mediaKind == .animatedGIF ? "play.fill" : "photo.fill")
                        .font(.system(size: 15, weight: .black))
                }
                .frame(width: 38, height: 38)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    isRendering
                        ? (mediaKind == .animatedGIF ? "GIFを生成中…" : "画像を生成中…")
                        : (mediaKind == .animatedGIF ? "GIF + ハッシュタグをシェア" : "画像 + ハッシュタグをシェア")
                )
                .font(.system(.body, design: .rounded, weight: .black))
                if !isCompact {
                    Text(mediaKind == .animatedGIF ? "粒がきらめく短いループ" : "高解像度の一枚")
                        .font(.caption.weight(.semibold))
                        .opacity(0.72)
                }
            }
            Spacer(minLength: 4)
            if isRendering {
                ProgressView().tint(.white)
            } else if !isCompact {
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
                            : selection.hasExcludedSelfReportedContent
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
                } else if selection.hasExcludedSelfReportedContent {
                    Button("自己申告を含めてカードにする") {
                        includeSelfReportedFocusHere()
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

    /// A card is on screen but self-reported focus is left out of it. Without
    /// this, a month of manual records plus one 記念石 read as an unexplained
    /// 0g, and the only way to include the focus sat in the collapsed 調整
    /// (walk-std-04). Tapping includes it the same way the toggle does; the
    /// saved preference only changes because the person asked here.
    private var showsExcludedSelfReportedNotice: Bool {
        !isLoadingData
            && !aggregateProjectionPresentation.isCloudVerificationPending
            && selection.hasShareableContent
            && selection.hasExcludedSelfReportedContent
    }

    private var excludedSelfReportedMessage: String {
        if let grams = selection.excludedSelfReportedGrams,
           DurationPresentation.focusMinutes(grams: grams) > 0 {
            return String(
                localized: "自己申告の\(DurationPresentation.focusLabel(grams: grams))は、カードに含めていません。",
                table: "Share",
                comment: "Share composer: amount of self-reported focus left out of the card, e.g. 1時間30分"
            )
        }
        return String(
            localized: "自己申告の集中は、カードに含めていません。",
            table: "Share",
            comment: "Share composer: self-reported focus is left out of the card"
        )
    }

    /// Includes self-reported focus from the notice or the empty state, the
    /// same way the toggle does. The notice and the button that had focus
    /// leave the screen, so VoiceOver is told what the card now holds.
    @MainActor
    private func includeSelfReportedFocusHere() {
        includeManual = true
        guard UIAccessibility.isVoiceOverRunning else { return }
        Task { @MainActor in
            // Read the card after the selection has been resolved for the
            // new toggle, and after the removed button's focus change.
            try? await Task.sleep(for: .milliseconds(350))
            let grams = selection.totalGrams
            let message: String
            if let time = ShareMassFormatter.focusTime(grams) {
                message = String(
                    localized: "自己申告を含めました。カードは\(ShareMassFormatter.spoken(grams))、\(time)です。",
                    table: "Share",
                    comment: "VoiceOver after including self-reported focus. Arguments: spoken mass (300グラム), focus time (30分)"
                )
            } else {
                message = String(
                    localized: "自己申告を含めました。カードは\(ShareMassFormatter.spoken(grams))です。",
                    table: "Share",
                    comment: "VoiceOver after including self-reported focus when the card holds under a minute. Argument: spoken mass"
                )
            }
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    /// The boxed notice with its large button is for a card that would
    /// otherwise read as an unexplained 0g (walk-std-04). When measured
    /// focus is already on the card, leaving self-reported time out may be
    /// the saved choice (既定は実測のみ), so the fact stays as one quiet line
    /// with an inline 含める rather than a box on every share.
    @ViewBuilder
    private var excludedSelfReportedNotice: some View {
        if selection.totalGrams == 0 {
            prominentExcludedSelfReportedNotice
        } else {
            compactExcludedSelfReportedNote
        }
    }

    private var compactExcludedSelfReportedNote: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        return layout {
            Text(excludedSelfReportedMessage)
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("share.excluded-self-reported")
            Button {
                includeSelfReportedFocusHere()
            } label: {
                Text("含める", tableName: "Share")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PomoGemTheme.amber)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(PomoGemBareButtonStyle())
            .disabled(isRendering || isSaving)
            .accessibilityIdentifier("share.include-self-reported-inline")
            .accessibilityLabel(Text("自己申告を含める", tableName: "Share"))
            .accessibilityHint(Text("自己申告として明記したうえで、この記録をカードに含めます", tableName: "Share"))
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .contain)
    }

    private var prominentExcludedSelfReportedNotice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(excludedSelfReportedMessage)
                    .font(.subheadline)
                    .foregroundStyle(PomoGemTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(PomoGemTheme.amber)
            }
            // The sentence gets the full width at accessibility sizes.
            .labelStyle(AccessibilitySizeTitleOnlyLabelStyle())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("share.excluded-self-reported")

            Button {
                includeSelfReportedFocusHere()
            } label: {
                Text("自己申告を含める", tableName: "Share")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PomoGemSecondaryButtonStyle())
            .disabled(isRendering || isSaving)
            .accessibilityIdentifier("share.include-self-reported-inline")
            .accessibilityHint(Text("自己申告として明記したうえで、この記録をカードに含めます", tableName: "Share"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(PomoGemTheme.card.opacity(0.88), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
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
           selection.scopedAggregateHasSelfReportedPebbles {
            return "この結晶には自己申告が含まれます。「自己申告を含める」をオンにすると、結晶全体の正確な質量をカードにできます。"
        }
        if !includeManual, selection.scopeHasSelfReportedSessions {
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
            case .all where selection.usesCompactRootProjection:
                if selection.compactProjectionIsIncomplete {
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
            // needed for the scoped aggregates in the membership projection
            // and is revoked again by the catch path below.
            if let verifiedProjectionStamp,
               aggregateProjectionPresentation.acceptsVerifiedAggregateCache(
                   verifiedProjectionStamp
               ) {
                aggregateProjectionCacheStamp = verifiedProjectionStamp
            }
            // Resolved directly, not through the cache: the page is still
            // being assembled and its generation has not been published.
            let loadedSelection = ShareSelectionModel.make(selectionInput)
            let membership = try HomeProjectionPolicy.localMembershipProjection(
                for: looseSessions,
                representedAggregateRoots: loadedSelection.scopedAggregates,
                legacyStrata: loadedSelection.scopedLegacyStrata,
                context: modelContext,
                resetMarkers: resetSnapshots
            )
            localRepresentedSessionIDs = membership.representedSessionIDs
            localMembershipProjectionIsComplete = membership.isCompleteForCandidates
            acceptedAggregateRootIDs.subtract(membership.conflictedRootIDs)
            aggregateValidationIsIncomplete = aggregateValidationIsIncomplete
                || !localMembershipProjectionIsComplete
            shareRecordsGeneration &+= 1
            isLoadingData = false
            refreshJarSnapshot()
        } catch {
            aggregateProjectionCacheStamp = nil
            shareRecordsGeneration &+= 1
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
        shareRecordsGeneration &+= 1
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
        // The same inclusion the export uses: whether the card actually
        // carries self-reported focus, not the toggle. They used to differ,
        // so the preview could show stones the exported image then hid.
        jarSnapshot = capturedJarSnapshot(
            includesSelfReportedFocus: selection.includesSelfReportedFocus
        )
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
        let options = JarSnapshotOptions.share(includesSelfReported: includesSelfReportedFocus)
        // Hiding a pebble another gem rests on would leave that gem floating
        // over a hole. The card then draws its own bottle from the shared
        // records instead (jar-04, screentime-11).
        guard !ShareJarSnapshotPolicy.hidingLeavesUnsupportedBody(in: scene, options: options) else {
            return nil
        }
        return try? JarSnapshotter.shared.image(of: scene, options: options)
    }

    @MainActor
    private func captureExportSnapshot() -> ShareExportSnapshot {
        // The same resolved selection the preview shows, so the exported card,
        // its caption, and the on-screen card cannot disagree.
        let selection = selection
        let capturedSessions = selection.sessions
        let capturedAchievements = selection.achievements
        let capturedAggregates = selection.aggregates
        let capturedGrams = selection.totalGrams
        let capturedIncludesSelfReportedFocus = selection.includesSelfReportedFocus
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
            focusTime: ShareMassFormatter.focusTime(capturedGrams),
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
        guard selection.hasShareableContent else {
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
                    title: ShareMassFormatter.focusTime(snapshot.totalGrams).map {
                        String(
                            localized: "瓶に積んだ集中 \(ShareMassFormatter.visual(snapshot.totalGrams))（\($0)）",
                            table: "Share",
                            comment: "Share sheet title for the GIF. Arguments: mass, focus time"
                        )
                    } ?? "瓶に積んだ集中 \(ShareMassFormatter.visual(snapshot.totalGrams))"
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
        format: Format? = nil,
        logicalSize: CGSize
    ) async throws -> (url: URL, cover: UIImage) {
        var ownedURL: URL?
        var returned = false
        defer {
            if !returned, let ownedURL { try? FileManager.default.removeItem(at: ownedURL) }
        }

        // Sharpest first; step down only when a file exceeds the share cap.
        for scale in AnimatedShareExporter.renderScaleLadder {
            try Task.checkCancellation()
            let candidate = try await writeAnimatedGIF(
                snapshot: snapshot,
                format: format,
                logicalSize: logicalSize,
                scale: scale
            )
            ownedURL = candidate.url
            try Task.checkCancellation()
            if AnimatedShareExporter.fileSize(at: candidate.url) <= AnimatedShareExporter.maximumShareBytes {
                returned = true
                return candidate
            }
            try? FileManager.default.removeItem(at: candidate.url)
            ownedURL = nil
        }
        throw AnimatedShareExportError.fileTooLarge
    }

    @MainActor
    private func writeAnimatedGIF(
        snapshot: ShareExportSnapshot,
        format: Format? = nil,
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
                    format: format,
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
        guard selection.hasShareableContent else {
            updateStatus("最初の一粒を積むと、カードにできます。")
            return
        }
        guard photoSaveTask == nil else { return }
        let snapshot = captureExportSnapshot()
        // Show progress before any rendering: the cards used to render on the
        // main actor first, so the button froze and only then showed its
        // spinner (history-07).
        isSaving = true
        activePhotoSaveID = snapshot.id
        photoSaveTask = Task { @MainActor in
            await renderAndSaveToPhotoLibrary(snapshot: snapshot)
        }
    }

    @MainActor
    private func cancelPhotoSave() {
        activePhotoSaveID = nil
        photoSaveTask?.cancel()
        photoSaveTask = nil
        isSaving = false
    }

    /// What the photo save writes: two stills, or, when 動くGIF is chosen,
    /// the two GIF files themselves so Photos keeps them animated.
    private enum PhotoSaveMedia {
        case stills([UIImage])
        case animatedGIFs([URL])
    }

    @MainActor
    private func renderAndSaveToPhotoLibrary(snapshot: ShareExportSnapshot) async {
        var temporaryGIFs: [URL] = []
        let progressMessage = snapshot.mediaKind == .animatedGIF
            ? String(
                localized: "写真用のGIFを作っています…",
                table: "Share",
                comment: "Share composer: status while the two GIFs for Photos are rendered"
            )
            : String(
                localized: "写真用の画像を作っています…",
                table: "Share",
                comment: "Share composer: status while the two still images for Photos are rendered"
            )
        defer {
            temporaryGIFs.forEach { try? FileManager.default.removeItem(at: $0) }
            // A save that stops without a result must not leave the
            // progress line behind.
            if statusMessage == progressMessage {
                statusMessage = nil
            }
            if activePhotoSaveID == snapshot.id {
                activePhotoSaveID = nil
                photoSaveTask = nil
                isSaving = false
            }
        }

        // Ask for Photos access before rendering: two 720-pixel GIFs take
        // several seconds, and a first-time person used to wait through them,
        // then see the permission prompt, and lose the render on a denial.
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard activePhotoSaveID == snapshot.id, !Task.isCancelled else { return }
        guard authorization == .authorized || authorization == .limited else {
            updateStatus("写真への追加が許可されていません。端末の設定から変更できます。")
            return
        }

        updateStatus(progressMessage)
        // Let the spinner and the progress line commit before main-actor
        // rendering starts.
        try? await Task.sleep(for: .milliseconds(50))
        guard activePhotoSaveID == snapshot.id, !Task.isCancelled else { return }

        let media: PhotoSaveMedia
        do {
            switch snapshot.mediaKind {
            case .stillImage:
                let images = renderCards(snapshot: snapshot)
                guard images.count == 2 else { throw AnimatedShareExportError.noFrames }
                media = .stills(images)
            case .animatedGIF:
                for format in Format.allCases {
                    let export = try await renderAnimatedGIF(
                        snapshot: snapshot,
                        format: format,
                        logicalSize: ShareCardLayoutPolicy.canvasSize(for: format)
                    )
                    temporaryGIFs.append(export.url)
                }
                media = .animatedGIFs(temporaryGIFs)
            }
        } catch {
            guard activePhotoSaveID == snapshot.id, !Task.isCancelled,
                  !(error is CancellationError) else { return }
            updateStatus("カードを生成できませんでした。")
            return
        }
        guard activePhotoSaveID == snapshot.id, !Task.isCancelled else { return }

        // The authorization prompt and the render can outlive aggregate trust.
        // Revalidate at the last MainActor instruction before starting the
        // Photos mutation; a snapshot captured while already pending contains
        // only explicitly labelled, device-confirmed individual records.
        guard snapshot.projectionWasCloudUnverified
                || aggregateProjectionPresentation
                    .acceptsVerifiedAggregateCache(
                        snapshot.projectionCacheStamp
                    )
        else { return }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                switch media {
                case let .stills(images):
                    images.forEach { PHAssetChangeRequest.creationRequestForAsset(from: $0) }
                case let .animatedGIFs(urls):
                    // A GIF added as the photo resource stays animated in
                    // Photos; `creationRequestForAsset(from: UIImage)` would
                    // flatten it to one frame.
                    for url in urls {
                        let options = PHAssetResourceCreationOptions()
                        options.shouldMoveFile = false
                        options.uniformTypeIdentifier = UTType.gif.identifier
                        PHAssetCreationRequest.forAsset()
                            .addResource(with: .photo, fileURL: url, options: options)
                    }
                }
            }
            guard activePhotoSaveID == snapshot.id, !Task.isCancelled else {
                return
            }
            switch media {
            case .stills:
                updateStatus("フィード用とストーリー用を写真に保存しました。")
            case .animatedGIFs:
                updateStatus(String(
                    localized: "動くGIFをフィード用とストーリー用で写真に保存しました。",
                    table: "Share",
                    comment: "Share composer: both animated GIF sizes were saved to Photos"
                ))
            }
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
            source: session.effectiveSource,
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
                        ShareCardHashtagRow(hashtags: hashtags, story: story)
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
            "ポモジェムシェアカード。\(periodLabel)。瓶に積んだ集中、\(ShareMassFormatter.spoken(totalGrams))\(ShareMassFormatter.focusTime(totalGrams).map { "、\($0)" } ?? "")。\(pebbleCount)粒、実測\(measuredCount)回、まとまり粒\(aggregates.count)個、記念石\(achievements.count)個。\(rewardSemantics.accessibilityDetail)。\(hiddenContent.captionDisclosure ?? "すべての石を表示")。\(disclosure.accessibilityDisclosure)。公式サイト、\(ShareCopy.websiteDisplayName)。\(hashtags.isEmpty ? "ハッシュタグなし" : "ハッシュタグ、\(hashtags.joined(separator: "、"))")"
        )
        .accessibilityIdentifier("share.card")
    }
}

/// The card's hashtags. They wrap instead of scaling one line: four chips
/// and a 30-character custom tag were cut with 「…」 in the image while the
/// caption kept them. A single tag wider than the card still shrinks to fit
/// its own line.
struct ShareCardHashtagRow: View {
    let hashtags: [String]
    let story: Bool

    var body: some View {
        ShareFlowLayout(
            horizontalSpacing: story ? 10 : 7,
            verticalSpacing: story ? 4 : 3,
            alignment: .center
        ) {
            ForEach(hashtags, id: \.self) { hashtag in
                Text(hashtag)
            }
        }
        .font(.system(size: story ? 11 : 8, weight: .bold, design: .rounded))
        .tracking(story ? 0.7 : 0.25)
        .foregroundStyle(PomoGemTheme.amber)
        .minimumScaleFactor(0.72)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
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
            // Grams stay the headline (EngagementArchitecture §5); the time
            // underneath is what a follower can actually read (history-08).
            if let focusTime = ShareMassFormatter.focusTime(grams) {
                Text("\(focusTime)の集中", tableName: "Share", comment: "Share card: focus time under the mass, e.g. 4時間10分の集中")
                    .font(.system(size: story ? 12 : 10, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(PomoGemTheme.text.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
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

    /// The focus time a card's mass stands for, or nil when it holds less
    /// than a minute (a stones-only card): 「0分」 would read as nothing done.
    static func focusTime(_ grams: Int) -> String? {
        DurationPresentation.focusMinutes(grams: grams) > 0
            ? DurationPresentation.focusLabel(grams: grams)
            : nil
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
        let highlightsSingleAggregate = visibleAggregates.count == 1
            && visibleSessions.isEmpty
            && visibleAchievements.isEmpty
        let stoneSize: CGFloat = min(size.width / 7.2, 34)
        let stoneBottoms = achievementBottoms(
            availableWidth: size.width,
            stoneSize: stoneSize,
            sessionColumnCount: sessionColumnCount,
            sessionSize: sessionSize,
            story: story
        )

        return ZStack(alignment: .bottom) {
            bottleBackground(size: size)
            bottomGlow(size: size)
            aggregateLayer(
                availableWidth: size.width,
                highlightsSingleAggregate: highlightsSingleAggregate,
                story: story
            )
            sessionLayer(columnCount: sessionColumnCount, sessionSize: sessionSize)
            achievementLayer(stoneSize: stoneSize, bottoms: stoneBottoms)
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
        let pebbleSize = aggregateSize(
            for: aggregate,
            availableWidth: availableWidth,
            highlightsSingleAggregate: highlightsSingleAggregate,
            story: story
        )
        let x = highlightsSingleAggregate
            ? CGFloat.zero
            : aggregateCenterX(index: index, availableWidth: availableWidth)
        let y: CGFloat = highlightsSingleAggregate
            ? -(story ? 25 : 18)
            : -aggregateBottom(index: index)
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
        let x = sessionCenterX(index: index, columnCount: columnCount, size: size)
        let y = -sessionBottom(index: index, columnCount: columnCount, size: size)
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
    private func achievementLayer(stoneSize: CGFloat, bottoms: [CGFloat]) -> some View {
        ForEach(Array(visibleAchievements.enumerated()), id: \.element.id) { index, stone in
            achievementView(
                stone,
                index: index,
                stoneSize: stoneSize,
                bottom: index < bottoms.count ? bottoms[index] : aggregateBandHeight
            )
        }
    }

    private func achievementView(
        _ stone: ShareAchievementVisual,
        index: Int,
        stoneSize: CGFloat,
        bottom: CGFloat
    ) -> some View {
        let glowPhase = animationPhase * .pi * 2 + Double(index) * 0.74
        let glow = (sin(glowPhase) + 1) / 2

        return ShareAchievementGem(
            stone: stone,
            variant: stableShareVariant(stone.id),
            glow: glow
        )
        .frame(width: stoneSize, height: stoneSize)
        .offset(x: achievementCenterX(index: index, stoneSize: stoneSize), y: -bottom)
    }

    /// Where each 記念石 rests: on the gems, crystals or earlier stones under
    /// its middle, or on the floor. A fixed shelf above the highest gem row
    /// left stones hovering over empty glass beside a few gems.
    private func achievementBottoms(
        availableWidth: CGFloat,
        stoneSize: CGFloat,
        sessionColumnCount: Int,
        sessionSize: CGFloat,
        story: Bool
    ) -> [CGFloat] {
        guard !visibleAchievements.isEmpty else { return [] }
        let crystals = visibleAggregates.indices.map { index in
            let pebbleSize = aggregateSize(
                for: visibleAggregates[index],
                availableWidth: availableWidth,
                highlightsSingleAggregate: false,
                story: story
            )
            let x = aggregateCenterX(index: index, availableWidth: availableWidth)
            return ShareJarPileLayout.Footprint(
                minX: x - pebbleSize / 2,
                maxX: x + pebbleSize / 2,
                top: aggregateBottom(index: index) + pebbleSize * 0.85
            )
        }
        let gems = visibleSessions.indices.map { index in
            let x = sessionCenterX(index: index, columnCount: sessionColumnCount, size: sessionSize)
            return ShareJarPileLayout.Footprint(
                minX: x - sessionSize * 0.46,
                maxX: x + sessionSize * 0.46,
                top: sessionBottom(index: index, columnCount: sessionColumnCount, size: sessionSize)
                    + sessionSize * 0.78
            )
        }
        return ShareJarPileLayout.stoneBottoms(
            centerXs: visibleAchievements.indices.map {
                achievementCenterX(index: $0, stoneSize: stoneSize)
            },
            stoneSize: stoneSize,
            stackingHeight: stoneSize * 0.74,
            floor: Self.floorHeight,
            footprints: crystals + gems
        )
    }

    /// The bottle's inner floor, where the first gem row rests when there
    /// are no crystals.
    private static let floorHeight: CGFloat = 7

    private func achievementCenterX(index: Int, stoneSize: CGFloat) -> CGFloat {
        let columnCount = 4
        let column = index % columnCount
        let row = index / columnCount
        let centeredColumn = CGFloat(column) - CGFloat(columnCount - 1) * 0.5
        let rowOffset: CGFloat = row.isMultiple(of: 2) ? 0 : stoneSize * 0.4
        return centeredColumn * stoneSize * 1.05 + rowOffset
    }

    private func sessionCenterX(index: Int, columnCount: Int, size: CGFloat) -> CGFloat {
        let column = index % columnCount
        let row = index / columnCount
        let rowAdjustment: CGFloat = row.isMultiple(of: 2) ? 0 : size * 0.42
        return (CGFloat(column) - CGFloat(columnCount - 1) / 2) * size * 0.92 + rowAdjustment
    }

    private func sessionBottom(index: Int, columnCount: Int, size: CGFloat) -> CGFloat {
        CGFloat(index / columnCount) * size * 0.78 + aggregateBandHeight
    }

    private func aggregateCenterX(index: Int, availableWidth: CGFloat) -> CGFloat {
        let columnCount = 4
        let column = index % columnCount
        let row = index / columnCount
        let xStep = availableWidth / CGFloat(columnCount + 1)
        let rowAdjustment: CGFloat = row.isMultiple(of: 2) ? -2 : 3
        return CGFloat(column + 1) * xStep - availableWidth / 2 + rowAdjustment
    }

    private func aggregateBottom(index: Int) -> CGFloat {
        CGFloat(index / 4) * 39 + 12
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
        guard !visibleAggregates.isEmpty else { return Self.floorHeight }
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
            .shadow(
                color: session.presentationKind == .normal
                    ? ShareColorPolicy.color(session.colorHex, vivid: true).opacity(0.24)
                    : .white.opacity(0.28 + glow * 0.26),
                radius: session.presentationKind == .normal
                    ? 3 + glow * 1.5
                    : 5 + glow * 4
            )
            .overlay(alignment: .topTrailing) {
                if session.presentationKind != .normal {
                    Image(systemName: "sparkle")
                        .font(.system(size: 6 + glow * 3, weight: .black))
                        .foregroundStyle(.white)
                        .shadow(color: .white.opacity(0.72), radius: 3)
                        .opacity(0.28 + glow * 0.72)
                        .offset(x: 2, y: -2)
                }
            }
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
                ShareGemShape(variant: variant)
                    .fill(AngularGradient(colors: colors + [colors[0]], center: .center))
                ShareGemShape(variant: variant)
                    .fill(.black.opacity(0.15))
                ShareGemFacetLines(variant: variant)
                    .stroke(.white.opacity(0.34), lineWidth: max(0.8, size * 0.018))
                    .clipShape(ShareGemShape(variant: variant))
                ForEach(0..<min(aggregate.pebbleCount, 8), id: \.self) { index in
                    let dotColor = colors[index % colors.count].opacity(0.92)
                    let xOffset = CGFloat(index % 3 - 1) * size * 0.2
                    let yOffset = CGFloat(index / 3 - 1) * size * 0.18
                    Circle()
                        .fill(dotColor)
                        .frame(width: size * 0.16, height: size * 0.16)
                        .offset(x: xOffset, y: yOffset)
                }
                ForEach(0..<min(aggregate.level, 3), id: \.self) { ring in
                    ShareGemShape(variant: variant + ring * 11)
                        .stroke(.white.opacity(0.24), lineWidth: 0.9)
                        .padding(CGFloat(ring) * 3 + 2)
                }
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
                .shadow(color: .black.opacity(0.88), radius: 2)
                .padding(3)
            }
            .frame(width: size, height: size)
            .shadow(color: colors[0].opacity(0.52), radius: size * 0.16)
            .overlay {
                ShareGemShape(variant: variant)
                    .stroke(.white.opacity(0.54), lineWidth: max(1, size * 0.022))
            }
        }
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
