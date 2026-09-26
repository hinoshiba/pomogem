import Foundation
import SwiftUI

/// Read-only values used by the overview so the visual hierarchy does not own
/// SwiftData objects. The live bottle can keep animating while this view shows
/// the same history at a wider scale.
struct AccumulationRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let subjectName: String
    let colorHex: String
    let grams: Int
    let isMeasured: Bool
    /// A focus timer ran to its end. Screen Time chunks are measured but are
    /// not completions (see `SessionSource.isTimerCompletion`).
    let isTimerCompletion: Bool
    /// Derived exclusively from this device's local AggregatePebble/Stratum
    /// membership. It is never copied from StudySession.isBaked.
    let isRepresentedByLocalAggregate: Bool
}

struct AccumulationWeeklySummary: Equatable, Sendable {
    /// Timers that ran to their end this week (the 「戻った回数」).
    let timerCompletionCount: Int
    let measuredGrams: Int
    /// Self-reported mass this week. The weekly headline stays measured-only
    /// (EngagementArchitecture §3.3), but the card must not call a week empty
    /// while the jar below it and 記録 both show this mass.
    let selfReportedGrams: Int
    let dominantColorHex: String

    var cardState: AccumulationWeeklyCardState {
        if measuredGrams > 0 { return .measured }
        return selfReportedGrams > 0 ? .selfReportedOnly : .empty
    }
}

enum AccumulationWeeklyCardState: Equatable, Sendable {
    case measured
    case selfReportedOnly
    case empty
}

enum AccumulationWeeklyPolicy {
    static func summary(records: [AccumulationRecord]) -> AccumulationWeeklySummary {
        let measured = records.filter(\.isMeasured)
        let colorTotals = Dictionary(grouping: measured, by: \.colorHex).map {
            (hex: $0.key, grams: HomeProjectionPolicy.saturatingNonnegativeSum(
                $0.value.map(\.grams)
            ))
        }
        let dominantColor = colorTotals.max { lhs, rhs in
            if lhs.grams == rhs.grams { return lhs.hex < rhs.hex }
            return lhs.grams < rhs.grams
        }?.hex ?? Constants.Color.amberLamp
        return AccumulationWeeklySummary(
            timerCompletionCount: records.filter(\.isTimerCompletion).count,
            measuredGrams: HomeProjectionPolicy.saturatingNonnegativeSum(
                measured.map(\.grams)
            ),
            selfReportedGrams: HomeProjectionPolicy.saturatingNonnegativeSum(
                records.filter { !$0.isMeasured }.map(\.grams)
            ),
            dominantColorHex: dominantColor
        )
    }

    /// This week's measured grams by theme colour, as the shares a crystal
    /// holding them would paint (up to four, largest first).
    static func colorShares(records: [AccumulationRecord]) -> [GemColorShare] {
        let measured = records.filter(\.isMeasured)
        let total = Double(HomeProjectionPolicy.saturatingNonnegativeSum(measured.map(\.grams)))
        guard total > 0 else { return [] }
        let mix = Dictionary(grouping: measured, by: \.colorHex).map {
            StratumColorFraction(
                hex: $0.key,
                fraction: Double(HomeProjectionPolicy.saturatingNonnegativeSum($0.value.map(\.grams))) / total
            )
        }
        return GemArtworkSpec.aggregateColors(mix, fallbackHex: Constants.Color.amberLamp)
    }

    /// The Overview's "いま" gem: the Home jar's own art for this week's
    /// measured grams (the rung a crystal of those grams would take, D8, in
    /// the week's theme colours); an empty week is the clear glass of the
    /// first-run gem (「今週は、まだ透明。」).
    static func gemSpec(records: [AccumulationRecord]) -> GemArtworkSpec {
        let shares = colorShares(records: records)
        let grams = HomeProjectionPolicy.saturatingNonnegativeSum(records.filter(\.isMeasured).map(\.grams))
        guard grams > 0, !shares.isEmpty else {
            return GemArtworkSpec(
                rung: GemCutLadder.standard.tutorial,
                colors: [GemColorShare(hex: "#DCEBFF", fraction: 1)],
                variant: 0,
                isMuted: false,
                showsDashedRing: false
            )
        }
        return GemArtworkStone.aggregateSpec(grams: grams, colors: shares)
    }
}

enum AccumulationClusterStorage: Equatable, Sendable {
    case aggregate(hasStoredLineage: Bool)
    case legacyStratum(hasSessionReferences: Bool)
}

struct AccumulationClusterSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let level: Int
    let pebbleCount: Int
    let grams: Int
    let periodStart: Date
    let periodEnd: Date
    let colorMix: [StratumColorFraction]
    let subjectMix: [AggregateSubjectFraction]
    let childCount: Int
    let sessionIDs: [UUID]
    let measuredPebbleCount: Int
    let manualPebbleCount: Int
    let goldPebbleCount: Int
    let prismPebbleCount: Int
    let storage: AccumulationClusterStorage

    init(
        id: UUID,
        level: Int,
        pebbleCount: Int,
        grams: Int,
        periodStart: Date,
        periodEnd: Date,
        colorMix: [StratumColorFraction],
        subjectMix: [AggregateSubjectFraction],
        childCount: Int,
        sessionIDs: [UUID],
        measuredPebbleCount: Int,
        manualPebbleCount: Int,
        goldPebbleCount: Int,
        prismPebbleCount: Int,
        storage: AccumulationClusterStorage = .aggregate(hasStoredLineage: true)
    ) {
        self.id = id
        self.level = level
        self.pebbleCount = pebbleCount
        self.grams = grams
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.colorMix = Self.normalizedColorMix(colorMix)
        // Compatibility aggregates may contain presentation labels synthesized
        // from a legacy color mix (for example, "過去の集中"). Those labels are
        // not evidence of the user's original themes, so never surface them as
        // a stored theme breakdown.
        switch storage {
        case .aggregate(let hasStoredLineage) where hasStoredLineage:
            self.subjectMix = Self.normalizedSubjectMix(subjectMix)
        case .aggregate, .legacyStratum:
            self.subjectMix = []
        }
        self.childCount = childCount
        self.sessionIDs = sessionIDs
        self.measuredPebbleCount = measuredPebbleCount
        self.manualPebbleCount = manualPebbleCount
        self.goldPebbleCount = goldPebbleCount
        self.prismPebbleCount = prismPebbleCount
        self.storage = storage
    }

    private static func normalizedColorMix(
        _ values: [StratumColorFraction]
    ) -> [StratumColorFraction] {
        var totals: [String: Double] = [:]
        for value in values
        where value.fraction.isFinite && value.fraction > 0 {
            let hex = value.hex.trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard !hex.isEmpty else { continue }
            let combined = totals[hex, default: 0] + value.fraction
            guard combined.isFinite else { continue }
            totals[hex] = combined
        }
        let total = totals.values.reduce(0, +)
        guard total.isFinite, total > 0 else { return [] }
        let ordered = totals.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }
        var accumulated = 0.0
        return ordered.enumerated().map { index, item in
            let fraction: Double
            if index == ordered.indices.last {
                fraction = max(0, 1 - accumulated)
            } else {
                fraction = item.value / total
                accumulated += fraction
            }
            return StratumColorFraction(hex: item.key, fraction: fraction)
        }
    }

    private static func normalizedSubjectMix(
        _ values: [AggregateSubjectFraction]
    ) -> [AggregateSubjectFraction] {
        struct Key: Hashable {
            let name: String
            let colorHex: String
        }

        var counts: [Key: Int] = [:]
        for value in values where value.pebbleCount > 0 {
            let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let colorHex = value.colorHex
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard !name.isEmpty, !colorHex.isEmpty else { continue }
            let key = Key(name: name, colorHex: colorHex)
            counts[key] = NonnegativeIntPolicy.adding(
                counts[key, default: 0],
                value.pebbleCount
            )
        }
        return counts.map {
            AggregateSubjectFraction(
                name: $0.key.name,
                colorHex: $0.key.colorHex,
                pebbleCount: $0.value
            )
        }
        .sorted { lhs, rhs in
            if lhs.pebbleCount == rhs.pebbleCount {
                if lhs.name == rhs.name { return lhs.colorHex < rhs.colorHex }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.pebbleCount > rhs.pebbleCount
        }
    }

    var scaleLabel: String {
        pebbleCount > 1 ? AggregatePresentation.countLabel(pebbleCount) : "一粒"
    }

    var isLegacyStratum: Bool {
        if case .legacyStratum = storage { return true }
        return false
    }

    var usesCompatibilityPresentation: Bool {
        switch storage {
        case .aggregate(let hasStoredLineage):
            return !hasStoredLineage
        case .legacyStratum:
            return true
        }
    }

    var hasStrongPreservationEvidence: Bool {
        guard case .aggregate(let hasStoredLineage) = storage else {
            return false
        }
        return hasStoredLineage
            && hasConsistentColorAndSubjectBreakdowns
            && hasCompleteSourceBreakdown
    }

    var hasCompleteSubjectBreakdown: Bool {
        guard case .aggregate(let hasStoredLineage) = storage,
              hasStoredLineage,
              !subjectMix.isEmpty else {
            return false
        }
        return NonnegativeIntPolicy.sum(subjectMix.map(\.pebbleCount))
            == pebbleCount
    }

    var hasConsistentColorAndSubjectBreakdowns: Bool {
        guard hasCompleteSubjectBreakdown,
              pebbleCount > 0,
              !colorMix.isEmpty else {
            return false
        }
        var expectedByColor: [String: Double] = [:]
        for item in subjectMix {
            expectedByColor[item.colorHex, default: 0] +=
                Double(item.pebbleCount) / Double(pebbleCount)
        }
        let actualByColor = Dictionary(
            uniqueKeysWithValues: colorMix.map { ($0.hex, $0.fraction) }
        )
        guard actualByColor.keys.sorted() == expectedByColor.keys.sorted() else {
            return false
        }
        return actualByColor.allSatisfy { color, fraction in
            guard let expected = expectedByColor[color] else { return false }
            return abs(fraction - expected) <= 0.000_001
        }
    }

    var hasCompleteSourceBreakdown: Bool {
        guard case .aggregate(let hasStoredLineage) = storage,
              hasStoredLineage else {
            return false
        }
        return NonnegativeIntPolicy.adding(
            measuredPebbleCount,
            manualPebbleCount
        ) == pebbleCount
    }

    var canPresentStoredPeriod: Bool {
        switch storage {
        case .aggregate(let hasStoredLineage):
            return hasStoredLineage
        case .legacyStratum:
            return true
        }
    }

    var detailSubtitle: String {
        usesCompatibilityPresentation
            ? "以前の形式で保存されたまとまり粒です。"
            : "瓶の中では、ひとつの粒で表しています。"
    }

    var preservationTitle: String {
        hasStrongPreservationEvidence
            ? "まとまり化で情報は削除されません"
            : "この粒に残っている情報"
    }

    var preservationMessage: String {
        if hasStrongPreservationEvidence {
            return "まとまり化では元の記録を削除せず、この粒にも色・テーマ・質量の内訳と元記録への参照を保存します。記念石はまとまり粒に含めず、別の石として残します。"
        }
        switch storage {
        case .aggregate(let hasStoredLineage) where hasStoredLineage:
            return "まとまり化では元の記録を削除しません。この粒には元記録への参照と、確認できる色・粒数・質量を保存しています。合計が一致しない内訳は表示していません。記念石は別の石として残します。"
        case .aggregate:
            return "以前の形式から引き継いだ粒です。保存済みの粒数・質量と、記録されている内訳を表示します。元記録への参照や一部の内訳がない場合があります。記念石は別の石として残します。"
        case .legacyStratum(let hasSessionReferences):
            let reference = hasSessionReferences
                ? "元記録への参照は残っています。"
                : "この粒には元記録への参照が保存されていません。"
            let retained = colorMix.isEmpty
                ? "粒数・質量と、まとめた日は残っています。"
                : "色・粒数・質量と、まとめた日は残っています。"
            return "\(retained)\(reference)旧形式のため、テーマ・入力方法・レアの内訳はこの粒自体には保存されていません。記念石は別の石として残します。"
        }
    }
}

extension AccumulationClusterSummary {
    /// Keeps Home's direct jar inspection and the overview backed by the exact
    /// same aggregate projection. Callers explicitly choose the locally trusted
    /// descendant IDs because cloud reconciliation owns membership separately.
    init(aggregate: AggregatePebble, sessionIDs: [UUID]) {
        let directSessionCount = Set(aggregate.sessionIDs).count
        let childAggregateCount = Set(aggregate.childAggregateIDs).count
        let hasStoredLineage = aggregate.projectionValidationVersion
            == AggregateProjectionValidation.currentVersion && (
                (
                    aggregate.level == 1
                        && directSessionCount == aggregate.pebbleCount
                        && directSessionCount > 0
                ) || (
                    aggregate.level > 1
                        && directSessionCount == 0
                        && childAggregateCount == aggregate.childAggregateCount
                        && (1...Constants.Jar.aggregateFanIn).contains(childAggregateCount)
                )
            )
        self.init(
            id: aggregate.id,
            level: aggregate.level,
            pebbleCount: aggregate.pebbleCount,
            grams: aggregate.grams,
            periodStart: aggregate.periodStart,
            periodEnd: aggregate.periodEnd,
            colorMix: aggregate.colorMix,
            subjectMix: hasStoredLineage ? aggregate.subjectMix : [],
            childCount: aggregate.childAggregateCount,
            sessionIDs: sessionIDs,
            measuredPebbleCount: aggregate.measuredPebbleCount,
            manualPebbleCount: aggregate.manualPebbleCount,
            goldPebbleCount: aggregate.goldPebbleCount,
            prismPebbleCount: aggregate.prismPebbleCount,
            storage: .aggregate(hasStoredLineage: hasStoredLineage)
        )
    }

    /// A retired Stratum stores a trustworthy color mix and mass, but it never
    /// stored subject/source/rare composition or the represented time range.
    /// Keep those fields empty instead of turning rendering-only labels such as
    /// "過去の集中" into user data.
    init(legacyStratum: JarStratumVisual) {
        self.init(
            id: legacyStratum.id,
            level: max(
                1,
                StrataMath.decimalAggregateLevel(
                    forPebbleCount: legacyStratum.pebbleCount
                )
            ),
            pebbleCount: legacyStratum.pebbleCount,
            grams: legacyStratum.grams,
            periodStart: legacyStratum.bakedAt,
            periodEnd: legacyStratum.bakedAt,
            colorMix: legacyStratum.colorMix,
            subjectMix: [],
            childCount: 0,
            sessionIDs: legacyStratum.sessionIDs,
            measuredPebbleCount: 0,
            manualPebbleCount: 0,
            goldPebbleCount: 0,
            prismPebbleCount: 0,
            storage: .legacyStratum(
                hasSessionReferences: !legacyStratum.sessionIDs.isEmpty
            )
        )
    }
}

struct AccumulationMilestoneSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let title: String
    let subjectName: String
    let colorHex: String
    let mark: String
}

struct AccumulationOverviewLayoutPolicy: Equatable {
    let usesMenuLensPicker: Bool
    let stacksSummaryCards: Bool
    let shelfColumnCount: Int

    static func resolve(isAccessibilitySize: Bool) -> Self {
        if isAccessibilitySize {
            return Self(
                usesMenuLensPicker: true,
                stacksSummaryCards: true,
                shelfColumnCount: 1
            )
        }
        return Self(
            usesMenuLensPicker: false,
            stacksSummaryCards: false,
            shelfColumnCount: 2
        )
    }
}

/// Describes current-epoch totals separately from the bounded rows this screen
/// renders. Achievement totals may deliberately be a lower bound when the
/// active candidate page is full, because claiming an exact database row count
/// could count a late stale duplicate whose tombstone is outside that page.
struct AccumulationOverviewPageScope: Equatable, Sendable {
    let totalSessionCount: Int
    let displayedSessionCount: Int
    let totalSessionCountIsLowerBound: Bool
    let totalSessionCountIsCloudUnverified: Bool
    let totalAchievementCount: Int
    let displayedAchievementCount: Int
    let totalAchievementCountIsLowerBound: Bool

    init(
        totalSessionCount: Int,
        displayedSessionCount: Int,
        totalSessionCountIsLowerBound: Bool = false,
        totalSessionCountIsCloudUnverified: Bool = false,
        totalAchievementCount: Int,
        displayedAchievementCount: Int,
        totalAchievementCountIsLowerBound: Bool = false
    ) {
        let visibleSessions = max(0, displayedSessionCount)
        let visibleAchievements = max(0, displayedAchievementCount)
        self.displayedSessionCount = visibleSessions
        self.totalSessionCount = max(visibleSessions, totalSessionCount)
        self.totalSessionCountIsLowerBound = totalSessionCountIsLowerBound
        self.totalSessionCountIsCloudUnverified =
            totalSessionCountIsCloudUnverified
        self.displayedAchievementCount = visibleAchievements
        self.totalAchievementCount = max(visibleAchievements, totalAchievementCount)
        self.totalAchievementCountIsLowerBound = totalAchievementCountIsLowerBound
    }

    var historyPageIsPartial: Bool {
        totalSessionCountIsCloudUnverified
            || totalSessionCountIsLowerBound
            || displayedSessionCount < totalSessionCount
    }

    var achievementPageIsPartial: Bool {
        totalAchievementCountIsLowerBound
            || displayedAchievementCount < totalAchievementCount
    }

    var timelineDetail: String {
        timelineDetail(isCloudOfflineSession: false)
    }

    func timelineDetail(isCloudOfflineSession: Bool) -> String {
        if totalSessionCountIsCloudUnverified {
            let status = isCloudOfflineSession ? "このiPhoneの集計を確認中です" : "iCloudを再集計中です"
            return "\(status)。年と月の表示には、この端末で確認できた記録だけを使います。"
        }
        return "生涯瓶は代表表示のまま、年と月を選ぶと、この端末に届いた範囲を正確に集計します。"
    }

    var shelfScopeLabel: String {
        shelfScopeLabel(isCloudOfflineSession: false)
    }

    func shelfScopeLabel(isCloudOfflineSession: Bool) -> String {
        if totalSessionCountIsCloudUnverified {
            let status = isCloudOfflineSession ? "このiPhoneの集計を確認中" : "iCloudを再集計中"
            guard displayedSessionCount > 0 else {
                return "\(status)・確認済み記録なし"
            }
            return "\(status)・この端末で確認済みの直近\(displayedSessionCount.formatted())件"
        }
        guard historyPageIsPartial else { return "月ごと・全\(totalSessionCount.formatted())件" }
        guard displayedSessionCount > 0 else { return "月別履歴は未読み込み" }
        if totalSessionCountIsLowerBound {
            return "\(totalSessionCount.formatted())件以上のうち直近\(displayedSessionCount.formatted())件から"
        }
        return "全\(totalSessionCount.formatted())件のうち直近\(displayedSessionCount.formatted())件から"
    }

    var emptyShelfMessage: String {
        emptyShelfMessage(isCloudOfflineSession: false)
    }

    func emptyShelfMessage(isCloudOfflineSession: Bool) -> String {
        if totalSessionCountIsCloudUnverified {
            let status = isCloudOfflineSession ? "このiPhoneの集計を確認中です" : "iCloudを再集計中です"
            return "\(status)。この端末で確認できた月別記録だけを表示しています。"
        }
        if totalSessionCount > 0 {
            return "生涯記録は保存されていますが、この表示では月別履歴を読み込んでいません。"
        }
        return "最初の一粒を積むと、ここに今月の瓶が現れます。"
    }

    var achievementSectionSubtitle: String {
        if totalAchievementCountIsLowerBound {
            return "記念石\(totalAchievementCount.formatted())個以上・最新\(displayedAchievementCount.formatted())個を表示"
        }
        if achievementPageIsPartial {
            return "全\(totalAchievementCount.formatted())個のうち最新\(displayedAchievementCount.formatted())個を表示"
        }
        return "質量とは別の記念・全\(totalAchievementCount.formatted())個"
    }

    var achievementAccessibilitySummary: String {
        if totalAchievementCountIsLowerBound {
            return "記念石\(totalAchievementCount.formatted())個以上、最新\(displayedAchievementCount.formatted())個を表示"
        }
        if achievementPageIsPartial {
            return "記念石\(totalAchievementCount.formatted())個、最新\(displayedAchievementCount.formatted())個を表示"
        }
        return "記念石\(totalAchievementCount.formatted())個"
    }

    func bottleRepresentativeDisclosure(
        displayedRecordCount: Int,
        displayedClusterCount: Int,
        displayedAchievementCount: Int
    ) -> String {
        "瓶の中は、粒\(max(0, displayedRecordCount).formatted())個・表示中のまとまり\(max(0, displayedClusterCount).formatted())個・記念石\(max(0, displayedAchievementCount).formatted())個の代表表示です。"
    }

    func constellationRepresentativeDisclosure(
        displayedClusterCount: Int,
        representativeCount: Int
    ) -> String {
        "まとまり結晶は、表示中の\(max(0, displayedClusterCount).formatted())個のうち代表\(max(0, representativeCount).formatted())個を配置しています。"
    }
}

/// Three scales of the same effort: individual sessions, movable aggregate
/// pebbles, and a shelf of monthly bottles. Aggregation never replaces the
/// record list; it only changes how far away the user is looking from.
struct AccumulationOverviewView: View {
    let records: [AccumulationRecord]
    let clusters: [AccumulationClusterSummary]
    let milestones: [AccumulationMilestoneSummary]
    let lifetimeGrams: Int
    let lifetimePebbleCount: Int
    let pageScope: AccumulationOverviewPageScope
    let lifetimeIsLowerBound: Bool
    let lifetimeIsCloudUnverified: Bool
    let initialClusterID: UUID?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isCloudOfflineSession) private var isCloudOfflineSession
    @State private var selectedCluster: AccumulationClusterSummary?
    @State private var selectedLens = AccumulationLens.now
    @State private var didApplyInitialFocus = false

    private let calendar = Calendar.autoupdatingCurrent

    private var projectionVerificationTitle: String {
        isCloudOfflineSession ? "このiPhoneの集計を確認中" : "iCloudを再集計中"
    }

    private var projectionVerificationNotice: String {
        isCloudOfflineSession
            ? "このiPhoneの集計を確認中です。確認できた記録だけを表示しています。"
            : AggregateProjectionPresentationPolicy.cloudPendingNotice
    }

    private var layoutPolicy: AccumulationOverviewLayoutPolicy {
        .resolve(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }

    private var lifetimePresentationContext:
        AggregateProjectionPresentationContext {
        AggregateProjectionPresentationContext(
            usesCloudPersistence: lifetimeIsCloudUnverified,
            isVerified: !lifetimeIsCloudUnverified
        )
    }

    private var bottleShelfColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 12),
            count: layoutPolicy.shelfColumnCount
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // These are only three bounded sections. A lazy outer stack can
                // enter a LazyLayout cache-update loop after changing lenses
                // and then scrolling, leaving the app's main thread busy.
                VStack(alignment: .leading, spacing: 24) {
                    introduction
                    scaleGuide
                    lensContent
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 40)
            }
            .background(NightBackground())
            .navigationTitle("積み上がり")
            .navigationBarTitleDisplayMode(.inline)
            // The scroll view extends beneath navigation chrome. Keep that
            // chrome opaque so large Dynamic Type rows cannot remain legible
            // through the sheet header and create a real contrast collision.
            .toolbarBackground(PomoGemTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PomoGemSheetCloseButton(
                        accessibilityLabel: "積み上がりを閉じる",
                        accessibilityIdentifier: "overview.close"
                    ) {
                        dismiss()
                    }
                }
            }
            .sheet(item: $selectedCluster) { cluster in
                ClusterDetailSheet(cluster: cluster)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .onChange(of: lifetimeIsCloudUnverified) { _, isUnverified in
                if isUnverified { selectedCluster = nil }
            }
            .onAppear { applyInitialFocusIfNeeded() }
        }
    }

    private func applyInitialFocusIfNeeded() {
        guard !didApplyInitialFocus else { return }
        didApplyInitialFocus = true
        selectedLens = OverviewInitialLensPolicy.selection(
            hasInitialCluster: initialClusterID != nil,
            currentWeekMeasuredCount: currentWeekRecords.filter(\.isMeasured).count,
            currentRecordCount: currentRecords.count,
            clusterCount: clusters.count,
            lifetimePebbleCount: lifetimePebbleCount
        )
        guard let initialClusterID else { return }
        selectedCluster = clusters.first { $0.id == initialClusterID }
    }

    private var uniqueRecords: [AccumulationRecord] {
        Dictionary(grouping: records, by: \.id).values.compactMap { duplicates in
            duplicates.max { $0.date < $1.date }
        }
        .sorted { $0.date < $1.date }
    }

    private var currentRecords: [AccumulationRecord] {
        let representedIDs = Set(clusters.flatMap(\.sessionIDs))
        return uniqueRecords.filter {
            !representedIDs.contains($0.id) && !$0.isRepresentedByLocalAggregate
        }
    }

    private var currentWeekRecords: [AccumulationRecord] {
        guard let interval = WeeklyProgressPolicy.week(calendar: calendar) else {
            return []
        }
        return uniqueRecords.filter { interval.contains($0.date) }
    }

    private var currentWeekTimerCompletionCount: Int {
        currentWeekSummary.timerCompletionCount
    }

    private var currentWeekGrams: Int {
        currentWeekSummary.measuredGrams
    }

    private var currentWeekSelfReportedGrams: Int {
        currentWeekSummary.selfReportedGrams
    }

    private var currentWeekColorHex: String {
        currentWeekSummary.dominantColorHex
    }

    private var currentWeekSummary: AccumulationWeeklySummary {
        AccumulationWeeklyPolicy.summary(records: currentWeekRecords)
    }

    private var monthlyBottles: [MonthBottleSummary] {
        Dictionary(grouping: uniqueRecords) { record in
            calendar.dateInterval(of: .month, for: record.date)?.start ?? record.date
        }
        .map { month, values in
            MonthBottleSummary(
                month: month,
                records: values.sorted { $0.date < $1.date }
            )
        }
        .sorted { $0.month > $1.month }
    }

    private var bottleGraphicRecords: [AccumulationRecord] {
        Array(currentRecords.suffix(28))
    }

    private var bottleGraphicClusters: [AccumulationClusterSummary] {
        Array(clusters.sorted { $0.periodEnd < $1.periodEnd }.suffix(16))
    }

    private var bottleGraphicMilestones: [AccumulationMilestoneSummary] {
        Array(milestones.sorted { $0.date < $1.date }.suffix(8))
    }

    /// The same persisted aggregate roots, translated into a bounded
    /// long-range camera. The constellation never invents sessions: each node
    /// is selectable back to its aggregate summary and the centre uses the
    /// exact lifetime counters.
    private var constellationNodes: [EffortConstellationNode] {
        clusters.map { cluster in
            let dominantColor = cluster.colorMix.max { lhs, rhs in
                if lhs.fraction == rhs.fraction { return lhs.hex > rhs.hex }
                return lhs.fraction < rhs.fraction
            }?.hex ?? Constants.Color.amberLamp

            return EffortConstellationNode(
                id: cluster.id,
                level: cluster.level,
                pebbleCount: cluster.pebbleCount,
                grams: cluster.grams,
                colorHex: dominantColor,
                colorMix: cluster.colorMix,
                periodEnd: cluster.periodEnd,
                containsRare: RareRewardPresentationPolicy.containsRare(
                    goldCount: cluster.goldPebbleCount,
                    prismCount: cluster.prismPebbleCount
                )
            )
        }
    }

    /// The time core's theme fan, computed as Home computes it (the same
    /// root crystals and loose gems), so the core is the same colours here
    /// as in the jar.
    private var lifetimeCoreColorShares: [GemColorShare] {
        JarLifetimeCorePresentation.colorShares(
            clusters.map { cluster in
                JarLifetimeCorePresentation.ColorContribution(
                    grams: cluster.grams,
                    colorMix: cluster.colorMix.isEmpty
                        ? [StratumColorFraction(
                            hex: cluster.subjectMix.first?.colorHex ?? Constants.Color.amberLamp,
                            fraction: 1
                        )]
                        : cluster.colorMix
                )
            }
            + currentRecords.map {
                JarLifetimeCorePresentation.ColorContribution(grams: $0.grams, hex: $0.colorHex)
            }
        )
    }

    /// Active decimal roots rendered without another bottle metaphor. Each
    /// aggregate is a digit in a base-ten hierarchy: ten roots at one level
    /// become one root at the next level, while their exact particles and mass
    /// remain available here. Loose values are recovered from the lifetime
    /// counters rather than the bounded history page, so a long-lived account
    /// does not appear to lose its oldest ungrouped effort.
    private var fusionHierarchyLevels: [FusionHierarchyLevelSummary] {
        let clusteredPebbles = NonnegativeIntPolicy.sum(clusters.map(\.pebbleCount))
        let clusteredGrams = NonnegativeIntPolicy.sum(clusters.map(\.grams))
        let loosePebbles = max(0, lifetimePebbleCount - clusteredPebbles)
        let looseGrams = max(0, lifetimeGrams - clusteredGrams)

        var levels: [FusionHierarchyLevelSummary] = []
        if loosePebbles > 0 {
            levels.append(FusionHierarchyLevelSummary(
                level: 0,
                unitCount: loosePebbles,
                unitPebbleCount: 1,
                representedPebbleCount: loosePebbles,
                grams: looseGrams,
                containsRare: false
            ))
        }

        for (level, values) in Dictionary(grouping: clusters, by: { max(1, $0.level) }) {
            let representedPebbles = NonnegativeIntPolicy.sum(
                values.map(\.pebbleCount)
            )
            let fallbackUnit = values.map(\.pebbleCount).filter { $0 > 0 }.min() ?? 1
            levels.append(FusionHierarchyLevelSummary(
                level: level,
                unitCount: values.count,
                unitPebbleCount: decimalUnit(for: level, fallback: fallbackUnit),
                representedPebbleCount: representedPebbles,
                grams: NonnegativeIntPolicy.sum(values.map(\.grams)),
                containsRare: values.contains {
                    RareRewardPresentationPolicy.containsRare(
                        goldCount: $0.goldPebbleCount,
                        prismCount: $0.prismPebbleCount
                    )
                }
            ))
        }

        return levels.sorted { lhs, rhs in
            if lhs.level == rhs.level {
                return lhs.representedPebbleCount > rhs.representedPebbleCount
            }
            return lhs.level > rhs.level
        }
    }

    private func decimalUnit(for level: Int, fallback: Int) -> Int {
        guard level > 0 else { return 1 }
        var unit = 1
        for _ in 0 ..< level {
            let (next, overflow) = unit.multipliedReportingOverflow(by: 10)
            guard !overflow else { return max(1, fallback) }
            unit = next
        }
        return unit
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionEyebrow(text: "FOCUS CONSTELLATION")
            Text("一粒は消えず、\n時間の景色に変わる。")
                .font(PomoGemTheme.brand(32))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Text(lifetimeIsCloudUnverified
                ? projectionVerificationNotice
                : (pageScope.historyPageIsPartial
                    ? "今週育つ結晶、瓶で動くまとまり、直近の年月。古い一回ごとの記録も消えず、必要な範囲だけ読み込みます。"
                    : "今週育つ結晶、瓶で動くまとまり、年月の棚。距離を変えても、一回ごとの集中と質量はそのまま残ります。"))
                .font(.subheadline)
                .foregroundStyle(PomoGemTheme.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    PomoGemTheme.card,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .accessibilityIdentifier("overview.introduction")
        }
    }

    @ViewBuilder
    private var lensContent: some View {
        switch selectedLens {
        case .now:
            currentWeekCrystal
            currentJar
            milestoneSection
        case .crystals:
            lifetimeConstellation
            fusionHierarchyCard
            clusterSection
            milestoneSection
        case .timeline:
            lifetimeBottle
            AccumulationTimelineBrowser()
        }
    }

    private var currentWeekCrystal: some View {
        PomoGemCard {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { currentWeekCrystalContents }
                VStack(alignment: .leading, spacing: 16) { currentWeekCrystalContents }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("overview.weekly-crystal")
        .accessibilityLabel(currentWeekAccessibilityLabel)
    }

    private var currentWeekAccessibilityLabel: String {
        switch currentWeekSummary.cardState {
        case .measured where currentWeekSelfReportedGrams > 0:
            return String(
                localized: "今週の積み上げ、\(DurationPresentation.focusLabel(grams: currentWeekGrams))、実測\(formattedMass(currentWeekGrams))、タイマー完走\(currentWeekTimerCompletionCount)回。このほか自己申告\(formattedMass(currentWeekSelfReportedGrams))。回数は戻った文脈で、時間価値とは別です",
                table: "Overview",
                comment: "VoiceOver weekly card: focus time, measured mass, timer completions, self-reported mass"
            )
        case .measured:
            return String(
                localized: "今週の積み上げ、\(DurationPresentation.focusLabel(grams: currentWeekGrams))、実測\(formattedMass(currentWeekGrams))、タイマー完走\(currentWeekTimerCompletionCount)回。回数は戻った文脈で、時間価値とは別です",
                table: "Overview",
                comment: "VoiceOver weekly card: focus time, measured mass, timer completions"
            )
        case .selfReportedOnly:
            return String(
                localized: "今週の積み上げ。タイマーの完走はまだありません。自己申告の\(formattedMass(currentWeekSelfReportedGrams))は、瓶とこれまでの記録に入っています",
                table: "Overview",
                comment: "VoiceOver weekly card when the week has only self-reported mass"
            )
        case .empty:
            return String(
                localized: "今週の積み上げ。今週のタイマー完走はまだありません。休んでも、以前の記録は減りません",
                table: "Overview",
                comment: "VoiceOver weekly card for an empty week"
            )
        }
    }

    private var currentWeekHeadline: String {
        switch currentWeekSummary.cardState {
        case .measured: String(localized: "今週の時間が積み上がっている。", table: "Overview")
        case .selfReportedOnly: String(localized: "今週は、自己申告で積んでいる。", table: "Overview")
        case .empty: String(localized: "今週は、まだ透明。", table: "Overview")
        }
    }

    private var currentWeekCaption: String {
        switch currentWeekSummary.cardState {
        case .measured:
            String(localized: "価値は集中時間で加算。完走回数は、戻ってきた文脈として別に残します。", table: "Overview")
        case .selfReportedOnly:
            String(
                localized: "タイマーの完走はまだありません。自己申告の\(formattedMass(currentWeekSelfReportedGrams))も、瓶とこれまでの記録に入っています。",
                table: "Overview",
                comment: "Weekly card caption when the week has only self-reported mass; the argument is a mass"
            )
        case .empty:
            String(localized: "次の完走から時間と質量を加えます。休んでも、これまでの瓶は減りません。", table: "Overview")
        }
    }

    @ViewBuilder
    private var currentWeekCrystalContents: some View {
        ZStack {
            Circle()
                .fill(Color(hex: currentWeekColorHex).opacity(0.13))
            Circle()
                .stroke(Color(hex: currentWeekColorHex).opacity(0.34), lineWidth: 1)
            VStack(spacing: 4) {
                // This week's grams as the jar's own gem art (the same
                // baked stone as Home), above the same time as the 時間 stat
                // beside it; 標準単位 here gave the one week a second unit
                // (history-08). At accessibility sizes the time would break
                // mid-number inside the 112 pt crystal, and the stat under it
                // already says it.
                GemArtworkStone(
                    spec: AccumulationWeeklyPolicy.gemSpec(records: currentWeekRecords),
                    glowHex: currentWeekSummary.cardState == .measured ? currentWeekColorHex : nil,
                    glowOpacity: 0.36
                )
                .frame(width: 50, height: 50)
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(DurationPresentation.focusLabel(grams: currentWeekGrams))
                        .font(.caption2.weight(.black))
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
            }
            .foregroundStyle(Color(hex: currentWeekColorHex))
            .padding(8)
        }
        .frame(width: 112, height: 112)
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 9) {
            SectionEyebrow(text: "THIS WEEK")
            Text(currentWeekHeadline)
                .font(PomoGemTheme.brand(22))
            Text(currentWeekCaption)
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        currentWeekStats
                    }
                } else {
                    HStack(spacing: 8) {
                        currentWeekStats
                    }
                }
            }
            if currentWeekSummary.cardState == .measured,
               currentWeekSelfReportedGrams > 0 {
                // The tiles are measured-only; say where the rest of the
                // week's mass is instead of letting it look lost.
                Text(
                    "このほか自己申告 \(formattedMass(currentWeekSelfReportedGrams))",
                    tableName: "Overview",
                    comment: "Weekly card: self-reported mass outside the measured tiles; the argument is a mass"
                )
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("overview.weekly-self-reported")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var currentWeekStats: some View {
        OverviewStat(
            title: String(localized: "時間", table: "Overview", comment: "This week's focus time stat title"),
            value: DurationPresentation.focusLabel(grams: currentWeekGrams)
        )
        OverviewStat(title: "戻った回数", value: "\(currentWeekTimerCompletionCount)回")
        OverviewStat(
            title: String(localized: "今週の実測", table: "Overview", comment: "Weekly card tile: measured mass this week"),
            value: formattedMass(currentWeekGrams)
        )
    }

    private var currentJar: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 14) {
                currentJarHeader
                OverviewBottleGraphic(
                    records: Array(currentRecords.suffix(40)),
                    clusters: [],
                    milestones: []
                )
                .frame(height: 240)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("overview.current-jar")
        .accessibilityLabel("いま瓶で動く粒、\(currentRecords.count)粒")
    }

    @ViewBuilder
    private var currentJarHeader: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                currentJarHeading
                Text("\(currentRecords.count)粒")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PomoGemTheme.muted)
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                currentJarHeading
                Spacer()
                Text("\(currentRecords.count)粒")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PomoGemTheme.muted)
            }
        }
    }

    private var currentJarHeading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("いま、瓶で動く粒")
                .font(PomoGemTheme.brand(20))
            Text("最新の粒を近くで見る")
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
        }
    }

    private var lifetimeBottle: some View {
        PomoGemCard {
            VStack(spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("生涯の瓶")
                            .font(PomoGemTheme.brand(22))
                        Text("すべての積み重ねを、一歩引いて見る")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                    Spacer(minLength: 12)
                    Image(systemName: "scope")
                        .font(.title2)
                        .foregroundStyle(PomoGemTheme.amber)
                        .accessibilityHidden(true)
                }

                OverviewBottleGraphic(
                    records: bottleGraphicRecords,
                    clusters: bottleGraphicClusters,
                    milestones: bottleGraphicMilestones
                )
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 330 : 290)

                Text(pageScope.bottleRepresentativeDisclosure(
                    displayedRecordCount: bottleGraphicRecords.count,
                    displayedClusterCount: bottleGraphicClusters.count,
                    displayedAchievementCount: bottleGraphicMilestones.count
                ))
                .font(.caption2)
                .foregroundStyle(PomoGemTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { lifetimeStats }
                    VStack(spacing: 10) { lifetimeStats }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("生涯の瓶")
        .accessibilityValue(lifetimeBottleAccessibilityValue)
    }

    private var lifetimeConstellation: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("時間の核")
                            .font(PomoGemTheme.brand(22))
                        Text("価値は集中時間、粒の階層は瓶を整理する形として見る")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                    Spacer(minLength: 12)
                    Image(systemName: "sparkles")
                        .font(.title2)
                        .foregroundStyle(PomoGemTheme.amber)
                        .accessibilityHidden(true)
                }

                if lifetimeIsCloudUnverified {
                    Label(
                        isCloudOfflineSession ? "このiPhoneの集計を確認中です" : "iCloudの集計を再確認中です",
                        systemImage: isCloudOfflineSession ? "checklist" : "arrow.triangle.2.circlepath.icloud"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PomoGemTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    EffortConstellationView(
                        nodes: constellationNodes,
                        totalGrams: lifetimeGrams,
                        totalPebbleCount: lifetimePebbleCount,
                        projectionIsLowerBound: lifetimeIsLowerBound,
                        coreColorShares: lifetimeCoreColorShares
                    ) { id in
                        selectedCluster = clusters.first { $0.id == id }
                    }
                    .frame(height: dynamicTypeSize.isAccessibilitySize ? 360 : 320)
                }

                Text(pageScope.constellationRepresentativeDisclosure(
                    displayedClusterCount: clusters.count,
                    representativeCount: EffortConstellationPresentation
                        .representativeNodes(constellationNodes).count
                ))
                .font(.caption2)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { lifetimeStats }
                    VStack(spacing: 10) { lifetimeStats }
                }

                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 7) {
                            fusionStep("10分 = 0.4")
                            fusionArrow
                            fusionStep("25分 = 1.0")
                            fusionArrow
                            fusionStep("60分 = 2.4")
                            fusionArrow
                            fusionStep("時間の核")
                        }
                    } else {
                        HStack(spacing: 7) {
                            fusionStep("10分 = 0.4")
                            fusionArrow
                            fusionStep("25分 = 1.0")
                            fusionArrow
                            fusionStep("60分 = 2.4")
                            fusionArrow
                            fusionStep("時間の核")
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("時間の核は集中時間で進みます。10分は0.4標準単位、25分は1.0標準単位、60分は2.4標準単位です")
                .accessibilityIdentifier("overview.fusion-legend")

                Text("1完走につき粒は1つ。10粒→1の階層は瓶の整理で、時間の価値は変えません。まとまりをタップすると内訳を確認できます。")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("overview.fusion-disclosure")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.lifetime-constellation")
    }

    private var fusionHierarchyCard: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 12) {
                            fusionHierarchyHeading
                            fusionHierarchyLevelCount
                        }
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            fusionHierarchyHeading
                            Spacer(minLength: 8)
                            fusionHierarchyLevelCount
                        }
                    }
                }

                if fusionHierarchyLevels.isEmpty {
                    Text(lifetimeIsCloudUnverified
                        ? "\(projectionVerificationTitle)です。確認が終わるまで古い階層は表示しません。"
                        : "最初の一粒から、ここに結晶の階段が育ちます。")
                        .font(.subheadline)
                        .foregroundStyle(PomoGemTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(fusionHierarchyLevels) { level in
                            FusionHierarchyLevelRow(summary: level)
                        }
                    }
                }

                Text(lifetimeIsCloudUnverified
                    ? (isCloudOfflineSession
                        ? "このiPhoneの集計の確認が終わるまで、古い階層は表示しません。確認できた記録だけを年月の棚に表示します。"
                        : "iCloudの再集計が終わるまで、古い階層は表示しません。この端末で確認できた記録だけを年月の棚に表示します。")
                    : (lifetimeIsLowerBound
                        ? "保存領域から確認できた範囲の階層です。整理が終わるまで、生涯値は減らさず「以上」で扱います。"
                        : "段の個数は保存上のまとまりです。10個そろうと次へ圧縮しますが、時間の核はグラムから独立に計算します。"))
                    .font(.caption2)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.fusion-hierarchy")
    }

    private var fusionHierarchyHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionEyebrow(text: "STORAGE HIERARCHY")
            Text("瓶の整理階層")
                .font(PomoGemTheme.brand(22))
            Text("10粒をひとつの表示へ圧縮します。これは価値の段階ではなく、記録と質量を失わず瓶を保つ仕組みです。")
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("overview.fusion-hierarchy.explanation")
        }
    }

    private var fusionHierarchyLevelCount: some View {
        Text("\(fusionHierarchyLevels.count)段")
            .font(.caption.weight(.black))
            .monospacedDigit()
            .foregroundStyle(PomoGemTheme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(PomoGemTheme.raised, in: Capsule())
            .accessibilityIdentifier("overview.fusion-hierarchy.level-count")
    }

    private func fusionStep(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.black))
            .foregroundStyle(PomoGemTheme.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(PomoGemTheme.card)
                    .overlay(Capsule().stroke(PomoGemTheme.glassEdge.opacity(0.22)))
            )
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("overview.fusion-step.\(title)")
    }

    private var fusionArrow: some View {
        Image(systemName: dynamicTypeSize.isAccessibilitySize
            ? "chevron.down"
            : "chevron.right")
            .font(.caption2.weight(.black))
            .foregroundStyle(PomoGemTheme.amber)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var lifetimeStats: some View {
        OverviewStat(
            title: lifetimeIsCloudUnverified
                ? (isCloudOfflineSession ? "集中（端末の集計を確認中）" : "集中（iCloud再集計中）")
                : (lifetimeIsLowerBound ? "集中（集計整理中）" : "集中"),
            value: AggregateProjectionPresentationPolicy.overviewLifetimeValue(
                verifiedValue: formattedMass(lifetimeGrams),
                isLocalLowerBound: lifetimeIsLowerBound,
                context: lifetimePresentationContext
            )
        )
        OverviewStat(
            title: "標準換算",
            value: AggregateProjectionPresentationPolicy.overviewLifetimeValue(
                verifiedValue: EffortProgressPresentation.formattedStandardUnits(
                    grams: lifetimeGrams
                ),
                isLocalLowerBound: lifetimeIsLowerBound,
                context: lifetimePresentationContext
            )
        )
        OverviewStat(
            title: lifetimeIsCloudUnverified
                ? "この端末で確認済み"
                : "物理粒（履歴）",
            value: lifetimeIsCloudUnverified
                ? "\(lifetimePebbleCount.formatted(.number.grouping(.automatic)))粒"
                : lifetimePebbleCount.formatted(.number.grouping(.automatic))
        )
        OverviewStat(
            title: "表示中のまとまり",
            value: clusters.count.formatted(.number.grouping(.automatic))
        )
    }

    private var lifetimeBottleAccessibilityValue: String {
        if lifetimeIsCloudUnverified {
            let status = isCloudOfflineSession ? "このiPhoneの集計を確認中" : "iCloudの集計を再確認中"
            return "\(status)。この端末で確認済みの記録は\(lifetimePebbleCount)粒。古いまとまりは表示していません。\(pageScope.achievementAccessibilitySummary)"
        }
        return "集中\(formattedMass(lifetimeGrams))\(lifetimeIsLowerBound ? "以上" : "")、\(EffortProgressPresentation.formattedStandardUnits(grams: lifetimeGrams))、物理履歴\(lifetimePebbleCount)粒、表示中のまとまり粒\(clusters.count)個、\(pageScope.achievementAccessibilitySummary)。\(pageScope.bottleRepresentativeDisclosure(displayedRecordCount: bottleGraphicRecords.count, displayedClusterCount: bottleGraphicClusters.count, displayedAchievementCount: bottleGraphicMilestones.count))"
    }

    private var scaleGuide: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("時間をズームする")
                .font(PomoGemTheme.brand(20))
            if layoutPolicy.usesMenuLensPicker {
                Picker("表示の距離", selection: $selectedLens) {
                    ForEach(AccumulationLens.allCases) { lens in
                        Label(lens.title, systemImage: lens.symbol).tag(lens)
                    }
                }
                .pickerStyle(.menu)
                .tint(PomoGemTheme.amber)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("overview.lens")
            } else {
                Picker("表示の距離", selection: $selectedLens) {
                    ForEach(AccumulationLens.allCases) { lens in
                        Label(lens.title, systemImage: lens.symbol).tag(lens)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("overview.lens")
            }
            Text(selectedLens == .timeline
                ? pageScope.timelineDetail(isCloudOfflineSession: isCloudOfflineSession)
                : selectedLens.detail)
                .font(.caption.weight(.semibold))
                // This sentence is operational scope disclosure, not tertiary
                // decoration. Keep it readable at Increase Contrast / AX5.
                .foregroundStyle(PomoGemTheme.text)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    PomoGemTheme.card,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
    }

    @ViewBuilder
    private var milestoneSection: some View {
        if !milestones.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                if layoutPolicy.stacksSummaryCards {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("成果の星")
                            .font(PomoGemTheme.brand(20))
                        Text(pageScope.achievementSectionSubtitle)
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text("成果の星")
                            .font(PomoGemTheme.brand(20))
                        Spacer()
                        Text(pageScope.achievementSectionSubtitle)
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                }

                if layoutPolicy.stacksSummaryCards {
                    LazyVStack(spacing: 12) {
                        ForEach(milestones.sorted { $0.date > $1.date }) { milestone in
                            MilestoneSummaryCard(milestone: milestone)
                        }
                    }
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 12) {
                            ForEach(milestones.sorted { $0.date > $1.date }) { milestone in
                                MilestoneSummaryCard(milestone: milestone)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned)
                }
            }
        }
    }

    @ViewBuilder
    private var clusterSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if layoutPolicy.stacksSummaryCards {
                VStack(alignment: .leading, spacing: 3) {
                    Text("まとまり粒")
                        .font(PomoGemTheme.brand(20))
                    Text("表示中 \(clusters.count)個")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PomoGemTheme.muted)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("まとまり粒")
                        .font(PomoGemTheme.brand(20))
                    Spacer()
                    Text("表示中 \(clusters.count)個")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PomoGemTheme.muted)
                }
            }

            if clusters.isEmpty {
                PomoGemCard {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(lifetimeIsCloudUnverified
                                ? projectionVerificationTitle
                                : "10粒ごとに生まれます")
                                .font(.subheadline.weight(.bold))
                            Text(lifetimeIsCloudUnverified
                                ? "確認が終わるまで古いまとまり粒は表示しません。"
                                : "粒の色と数を内側に残したまま、大きな一粒になります。")
                                .font(.caption)
                                .foregroundStyle(PomoGemTheme.muted)
                        }
                    } icon: {
                        Image(systemName: "circle.hexagongrid.fill")
                            .foregroundStyle(PomoGemTheme.amber)
                    }
                }
            } else if layoutPolicy.stacksSummaryCards {
                LazyVStack(spacing: 12) {
                    ForEach(clusters.sorted { $0.periodEnd > $1.periodEnd }) { cluster in
                        Button {
                            selectedCluster = cluster
                        } label: {
                            ClusterSummaryCard(cluster: cluster)
                        }
                        .buttonStyle(PomoGemBareButtonStyle())
                        .frame(maxWidth: .infinity)
                    }
                }
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(clusters.sorted { $0.periodEnd > $1.periodEnd }) { cluster in
                            Button {
                                selectedCluster = cluster
                            } label: {
                                ClusterSummaryCard(cluster: cluster)
                            }
                            .buttonStyle(PomoGemBareButtonStyle())
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    @ViewBuilder
    private var bottleShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            if layoutPolicy.stacksSummaryCards {
                VStack(alignment: .leading, spacing: 3) {
                    Text("瓶の棚")
                        .font(PomoGemTheme.brand(20))
                    Text(pageScope.shelfScopeLabel(isCloudOfflineSession: isCloudOfflineSession))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PomoGemTheme.muted)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("瓶の棚")
                        .font(PomoGemTheme.brand(20))
                    Spacer()
                    Text(pageScope.shelfScopeLabel(isCloudOfflineSession: isCloudOfflineSession))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PomoGemTheme.muted)
                }
            }

            if monthlyBottles.isEmpty {
                PomoGemCard {
                    Text(pageScope.emptyShelfMessage(isCloudOfflineSession: isCloudOfflineSession))
                        .font(.subheadline)
                        .foregroundStyle(PomoGemTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                LazyVGrid(
                    columns: bottleShelfColumns,
                    spacing: 12
                ) {
                    ForEach(monthlyBottles) { month in
                        MonthBottleCard(
                            summary: month,
                            isFromPartialHistoryPage: pageScope.historyPageIsPartial
                                && month.id == monthlyBottles.last?.id
                        )
                    }
                }
            }
        }
    }

    private func formattedMass(_ grams: Int) -> String {
        EffortConstellationPresentation.formattedMass(grams)
    }
}

private struct FusionHierarchyLevelSummary: Identifiable, Equatable {
    let level: Int
    let unitCount: Int
    let unitPebbleCount: Int
    let representedPebbleCount: Int
    let grams: Int
    let containsRare: Bool

    var id: Int { level }

    var scaleLabel: String {
        "×\(max(1, unitPebbleCount).formatted(.number.grouping(.automatic)))"
    }

    var formTitle: String {
        level == 0 ? "一粒" : AggregatePresentation.title(level: level)
    }

    var quantityLabel: String {
        level == 0 ? "\(unitCount.formatted())粒" : "\(unitCount.formatted())個"
    }

    /// One accent per decimal form. No gold: a ×10 must not read as a
    /// medal or a coin (Docs/GemExperienceDesign.md §7.14).
    var accentHex: String {
        let palette = [
            Constants.Color.auroraWarm,
            "#D56B82",
            Constants.Color.auroraCool,
            Constants.Color.auroraViolet,
            "#E96DDB",
            "#55E2C5",
            "#FF799C"
        ]
        return palette[min(max(0, level), palette.count - 1)]
    }

    var symbol: String {
        switch level {
        case 0: "circle.fill"
        case 1: "diamond.fill"
        case 2: "sparkle"
        case 3: "hexagon.fill"
        case 4: "star.fill"
        default: "sparkles"
        }
    }
}

private struct FusionHierarchyLevelRow: View {
    let summary: FusionHierarchyLevelSummary

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var glyphDimension: CGFloat {
        min(116, 78 + CGFloat(min(max(summary.level, 0), 6)) * 7)
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    FusionHierarchyGlyph(summary: summary)
                        .frame(width: glyphDimension, height: glyphDimension)
                        .frame(maxWidth: .infinity, alignment: .center)
                    levelDetails
                }
            } else {
                HStack(spacing: 14) {
                    FusionHierarchyGlyph(summary: summary)
                        .frame(width: glyphDimension, height: glyphDimension)
                    levelDetails
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color(hex: summary.accentHex).opacity(0.18),
                    PomoGemTheme.raised.opacity(0.84)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(hex: summary.accentHex).opacity(0.36), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("overview.fusion-level.\(summary.level)")
        .accessibilityLabel(
            "\(summary.scaleLabel)の\(summary.formTitle)、\(summary.quantityLabel)、\(summary.representedPebbleCount)粒を保持、\(summary.grams)グラム"
        )
    }

    private var levelDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            levelHeader

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { exactMetrics }
                VStack(alignment: .leading, spacing: 8) { exactMetrics }
            }

            if summary.containsRare {
                Label("レア粒の光も内側に保持", systemImage: "sparkles")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(PomoGemTheme.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var levelHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                scaleBadge
                formTitle
                quantityLabel
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 6) {
                scaleBadge
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    formTitle
                    Spacer(minLength: 4)
                    quantityLabel
                }
            }
        }
    }

    private var scaleBadge: some View {
        Text(summary.scaleLabel)
            .font(.caption.weight(.black))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Color(hex: summary.accentHex))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(hex: summary.accentHex).opacity(0.12), in: Capsule())
    }

    private var formTitle: some View {
        Text(summary.formTitle)
            .font(PomoGemTheme.brand(19))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var quantityLabel: some View {
        Text(summary.quantityLabel)
            .font(.system(.headline, design: .rounded, weight: .black))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var exactMetrics: some View {
        FusionHierarchyMetric(
            title: "保持する粒",
            value: "\(summary.representedPebbleCount.formatted(.number.grouping(.automatic)))粒"
        )
        FusionHierarchyMetric(
            title: "保持する質量",
            value: "\(summary.grams.formatted(.number.grouping(.automatic)))g"
        )
    }
}

private struct FusionHierarchyGlyph: View {
    let summary: FusionHierarchyLevelSummary

    private var ringCount: Int {
        min(max(summary.level, 0), 5)
    }

    var body: some View {
        ZStack {
            ForEach(0 ..< ringCount, id: \.self) { index in
                Circle()
                    .trim(
                        from: CGFloat(index) * 0.07,
                        to: min(1, 0.62 + CGFloat(index) * 0.065)
                    )
                    .stroke(
                        Color(hex: summary.accentHex).opacity(0.26 + Double(index) * 0.08),
                        style: StrokeStyle(
                            lineWidth: index == ringCount - 1 ? 1.8 : 1,
                            lineCap: .round,
                            dash: index.isMultiple(of: 2) ? [] : [3, 5]
                        )
                    )
                    .rotationEffect(.degrees(Double(index) * 43 - 62))
                    .padding(CGFloat(index) * 5 + 1)
            }

            ProgressCrystalGlyph(
                completionCount: max(1, summary.unitPebbleCount),
                colorHex: summary.accentHex,
                level: max(1, summary.level),
                grams: summary.grams / max(1, summary.unitCount)
            )
            .padding(CGFloat(ringCount) * 3 + 5)

            VStack {
                Spacer()
                Label(summary.scaleLabel, systemImage: summary.symbol)
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.52), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.24), lineWidth: 0.5))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct FusionHierarchyMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PomoGemTheme.text)
            Text(value)
                .font(.system(.caption, design: .rounded, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(PomoGemTheme.text)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PomoGemTheme.card.opacity(0.76), in: RoundedRectangle(cornerRadius: 11))
    }
}

enum AccumulationLens: String, CaseIterable, Identifiable {
    case now
    case crystals
    case timeline

    var id: Self { self }

    var title: String {
        switch self {
        case .now: "いま"
        case .crystals: "結晶"
        case .timeline: "年月"
        }
    }

    var symbol: String {
        switch self {
        case .now: "circle.fill"
        case .crystals: "sparkles"
        case .timeline: "square.grid.2x2.fill"
        }
    }

    var detail: String {
        switch self {
        case .now:
            "一回ずつの手触りと、今週積み上げた時間を見ます。"
        case .crystals:
            "生涯の時間価値と、瓶を整理するまとまりを見ます。"
        case .timeline:
            "月ごとの瓶で、離れていた時期も含む歩みを見ます。"
        }
    }
}

/// Chooses the most honest first distance without turning inactivity into a
/// failure screen. A person with fresh work sees the tactile weekly view. A
/// returning long-term user whose current bottle is empty lands on the durable
/// crystal view, so years of effort are not introduced as “0 this week”.
enum OverviewInitialLensPolicy {
    static func selection(
        hasInitialCluster: Bool,
        currentWeekMeasuredCount: Int,
        currentRecordCount: Int,
        clusterCount: Int,
        lifetimePebbleCount: Int
    ) -> AccumulationLens {
        if hasInitialCluster { return .crystals }
        if currentWeekMeasuredCount > 0 || currentRecordCount > 0 { return .now }
        if clusterCount > 0 || lifetimePebbleCount >= FusionHierarchyPresentation.fanIn {
            return .crystals
        }
        return .now
    }
}

private struct MilestoneSummaryCard: View {
    let milestone: AccumulationMilestoneSummary

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                cardContents
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                cardContents
                    .frame(width: 180, height: 172, alignment: .leading)
            }
        }
        .background(
            LinearGradient(
                colors: [
                    Color(hex: milestone.colorHex).opacity(0.22),
                    PomoGemTheme.card
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color(hex: milestone.colorHex).opacity(0.42), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(milestone.subjectName)、\(milestone.title)の成果の星、\(milestone.date.formatted(.dateTime.year().month().day()))"
        )
    }

    private var cardContents: some View {
        VStack(alignment: .leading, spacing: 11) {
            ZStack {
                ProgressCrystalGlyph(
                    completionCount: 12,
                    colorHex: milestone.colorHex,
                    level: 4,
                    isAchievement: true
                )
                Text(milestone.mark)
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.56), radius: 2, y: 1)
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 3) {
                Text(milestone.title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(milestone.subjectName)
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                Text(milestone.date.formatted(.dateTime.year().month().day()))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PomoGemTheme.muted)
            }
        }
        .padding(15)
    }
}

private struct OverviewStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PomoGemTheme.text)
            Text(value)
                .font(.system(.headline, design: .rounded, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(PomoGemTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(PomoGemTheme.raised, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ScaleStep: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(PomoGemTheme.amber)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.bold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(PomoGemTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.horizontal, 12)
        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 15))
        .accessibilityElement(children: .combine)
    }
}

private struct ClusterSummaryCard: View {
    let cluster: AccumulationClusterSummary

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                cardContents
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                cardContents
                    .frame(width: 176, height: 154, alignment: .leading)
            }
        }
        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(PomoGemTheme.glassEdge.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(cluster.scaleLabel)のまとまり粒、\(cluster.pebbleCount)粒、\(formattedMass(cluster.grams))")
        .accessibilityHint("ダブルタップで内訳を表示します")
    }

    private var cardContents: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                AggregateGlyph(cluster: cluster)
                    .frame(width: 64, height: 64)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PomoGemTheme.muted)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(cluster.scaleLabel)のまとまり")
                    .font(.subheadline.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                if cluster.canPresentStoredPeriod {
                    Text(cluster.periodEnd.formatted(.dateTime.year().month().day()))
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                }
            }
        }
        .padding(15)
    }

    private func formattedMass(_ grams: Int) -> String {
        grams >= 1_000 ? String(format: "%.1fキログラム", Double(grams) / 1_000) : "\(grams)グラム"
    }
}

struct ClusterDetailSheet: View {
    let cluster: AccumulationClusterSummary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsAllSubjects = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    AggregateGlyph(cluster: cluster)
                        .frame(width: 132, height: 132)
                        .padding(.top, 8)
                    VStack(spacing: 6) {
                        Text("\(cluster.pebbleCount.formatted())粒分の積み重ね")
                            .font(PomoGemTheme.brand(24))
                            .multilineTextAlignment(.center)
                        Text(cluster.detailSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(PomoGemTheme.muted)
                            .multilineTextAlignment(.center)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(PomoGemTheme.amber)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cluster.preservationTitle)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(PomoGemTheme.text)
                            Text(cluster.preservationMessage)
                                .font(.caption)
                                .foregroundStyle(PomoGemTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        PomoGemTheme.amber.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 18)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(PomoGemTheme.amber.opacity(0.24), lineWidth: 1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("overview.cluster.preservation")
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(spacing: 10) {
                                clusterStats
                            }
                        } else {
                            HStack(spacing: 10) {
                                clusterStats
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            cluster.hasStrongPreservationEvidence
                                ? "粒数による色の内訳"
                                : "保存されている色の内訳"
                        )
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PomoGemTheme.muted)
                        GeometryReader { proxy in
                            HStack(spacing: 2) {
                                ForEach(Array(cluster.colorMix.enumerated()), id: \.offset) { _, item in
                                    Capsule()
                                        .fill(Color(hex: item.hex))
                                        .frame(width: max(2, proxy.size.width * normalizedFraction(item.fraction)))
                                }
                            }
                        }
                        .frame(height: 12)
                        .accessibilityHidden(true)
                        if cluster.colorMix.isEmpty {
                            Text(
                                cluster.usesCompatibilityPresentation
                                    ? "色の内訳は保存されていません"
                                    : "確認できる色の内訳はありません"
                            )
                                .font(.caption)
                                .foregroundStyle(PomoGemTheme.muted)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(Array(cluster.colorMix.enumerated()), id: \.offset) { index, item in
                                    CompositionBreakdownRow(
                                        colorHex: item.hex,
                                        title: colorName(for: item.hex, index: index),
                                        value: percentageText(item.fraction),
                                        accessibilityDescription: "\(colorName(for: item.hex, index: index))、\(spokenPercentage(item.fraction))"
                                    )
                                }
                            }
                        }
                        if let periodText {
                            Text(periodText)
                                .font(.caption)
                                .foregroundStyle(PomoGemTheme.muted)
                        }
                    }
                    .padding(16)
                    .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 18))

                    if cluster.hasCompleteSubjectBreakdown {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("テーマの内訳")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(PomoGemTheme.muted)
                            ForEach(Array(visibleSubjectMix.enumerated()), id: \.offset) { _, item in
                                let percentage = subjectPercentage(item.pebbleCount)
                                CompositionBreakdownRow(
                                    colorHex: item.colorHex,
                                    title: item.name,
                                    value: "\(item.pebbleCount.formatted())粒・\(percentageText(percentage))",
                                    accessibilityDescription: "\(item.name)、\(item.pebbleCount.formatted())粒、\(spokenPercentage(percentage))"
                                )
                            }
                            if cluster.subjectMix.count > 5 {
                                Button {
                                    showsAllSubjects.toggle()
                                } label: {
                                    Label(
                                        showsAllSubjects
                                            ? "表示を5件に戻す"
                                            : "ほか\(hiddenSubjectCount)件を表示",
                                        systemImage: showsAllSubjects ? "chevron.up" : "chevron.down"
                                    )
                                    .font(.caption.weight(.bold))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(PomoGemBareButtonStyle())
                                .foregroundStyle(PomoGemTheme.amber)
                            }
                        }
                        .padding(16)
                        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 18))
                    }

                    if showsSourceStats {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { sourceStats }
                            VStack(spacing: 10) { sourceStats }
                        }
                    }
                }
                .padding(20)
            }
            .background(NightBackground())
            .navigationTitle("まとまり粒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PomoGemSheetCloseButton(
                        accessibilityIdentifier: "overview.cluster.close"
                    ) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var periodText: String? {
        guard cluster.canPresentStoredPeriod else {
            // Compatibility aggregates can carry either a migration date or
            // a partially reconstructed activity range. Without provenance we
            // cannot label that value truthfully, so omit it.
            return nil
        }
        let start = cluster.periodStart.formatted(.dateTime.year().month().day())
        let end = cluster.periodEnd.formatted(.dateTime.year().month().day())
        if cluster.isLegacyStratum {
            let label = "まとめた日"
            return start == end
                ? "\(label)：\(end)"
                : "\(label)：\(start) 〜 \(end)"
        }
        return start == end ? start : "\(start) 〜 \(end)"
    }

    private func formattedMass(_ grams: Int) -> String {
        if grams >= 1_000 {
            let kilograms = (Double(grams) / 1_000).formatted(
                .number
                    .grouping(.automatic)
                    .precision(.fractionLength(1))
            )
            return "\(kilograms)kg"
        }
        return "\(grams.formatted())g"
    }

    private var visibleSubjectMix: [AggregateSubjectFraction] {
        showsAllSubjects ? cluster.subjectMix : Array(cluster.subjectMix.prefix(5))
    }

    private var hiddenSubjectCount: Int {
        max(0, cluster.subjectMix.count - 5)
    }

    private var subjectPebbleTotal: Int {
        max(1, NonnegativeIntPolicy.sum(cluster.subjectMix.map(\.pebbleCount)))
    }

    private func subjectPercentage(_ count: Int) -> Double {
        Double(max(0, count)) / Double(subjectPebbleTotal)
    }

    private func colorName(for hex: String, index: Int) -> String {
        var seen = Set<String>()
        let subjectNames = cluster.subjectMix
            .filter { $0.colorHex.caseInsensitiveCompare(hex) == .orderedSame }
            .map(\.name)
            .filter { seen.insert($0).inserted }
        if !subjectNames.isEmpty {
            return subjectNames.joined(separator: "・")
        }

        switch hex.uppercased() {
        case Constants.Color.english: return "朱色"
        case Constants.Color.mathematics: return "瑠璃"
        case Constants.Color.japanese: return "紅藤"
        case Constants.Color.science: return "緑青"
        case Constants.Color.socialStudies: return "菫"
        case Constants.Color.pebbleGold: return "金色"
        default: return "色\(index + 1)"
        }
    }

    private func percentageText(_ fraction: Double) -> String {
        let percentage = normalizedFraction(fraction) * 100
        if percentage > 0, percentage < 1 { return "1%未満" }
        return "\(NonnegativeIntPolicy.clamped(percentage.rounded()))%"
    }

    private func spokenPercentage(_ fraction: Double) -> String {
        let percentage = normalizedFraction(fraction) * 100
        if percentage > 0, percentage < 1 { return "1パーセント未満" }
        return "\(NonnegativeIntPolicy.clamped(percentage.rounded()))パーセント"
    }

    private func normalizedFraction(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return min(1, max(0, fraction))
    }

    @ViewBuilder
    private var clusterStats: some View {
        OverviewStat(title: "縮尺", value: cluster.scaleLabel)
        OverviewStat(title: "質量", value: formattedMass(cluster.grams))
    }

    private var showsSourceStats: Bool {
        guard case .aggregate(let hasStoredLineage) = cluster.storage,
              hasStoredLineage else {
            return false
        }
        return cluster.hasCompleteSourceBreakdown
            || RareRewardPresentationPolicy.containsRare(
                goldCount: cluster.goldPebbleCount,
                prismCount: cluster.prismPebbleCount
            )
    }

    @ViewBuilder
    private var sourceStats: some View {
        if cluster.hasCompleteSourceBreakdown {
            OverviewStat(
                title: "タイマー",
                value: "\(cluster.measuredPebbleCount.formatted())粒"
            )
            OverviewStat(
                title: "手動",
                value: "\(cluster.manualPebbleCount.formatted())粒"
            )
        }
        if RareRewardPresentationPolicy.containsRare(
            goldCount: cluster.goldPebbleCount,
            prismCount: cluster.prismPebbleCount
        ) {
            if cluster.goldPebbleCount > 0 {
                OverviewStat(
                    title: "金の粒",
                    value: "\(cluster.goldPebbleCount.formatted())粒"
                )
            }
            if cluster.prismPebbleCount > 0 {
                OverviewStat(
                    title: "虹の粒",
                    value: "\(cluster.prismPebbleCount.formatted())粒"
                )
            }
        }
    }
}

private struct CompositionBreakdownRow: View {
    let colorHex: String
    let title: String
    let value: String
    let accessibilityDescription: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) {
                    identity
                    Text(value)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PomoGemTheme.muted)
                        .padding(.leading, 20)
                }
            } else {
                HStack(spacing: 10) {
                    identity
                    Spacer(minLength: 8)
                    Text(value)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PomoGemTheme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var identity: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(hex: colorHex))
                .frame(width: 10, height: 10)
                .overlay { Circle().stroke(.white.opacity(0.34), lineWidth: 1) }
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AggregateGlyph: View {
    let cluster: AccumulationClusterSummary

    var body: some View {
        ZStack(alignment: .bottom) {
            ProgressCrystalGlyph(
                completionCount: cluster.pebbleCount,
                colorHex: dominantColorHex,
                level: cluster.level,
                showsCount: true,
                grams: cluster.grams,
                colorShares: GemArtworkSpec.aggregateColors(cluster.colorMix, fallbackHex: dominantColorHex)
            )
            HStack(spacing: 2) {
                ForEach(Array(palette.prefix(5).enumerated()), id: \.offset) { _, item in
                    Capsule()
                        .fill(Color(hex: item.hex))
                        .frame(width: 7, height: 3)
                }
            }
            .padding(.bottom, 5)
        }
        .accessibilityHidden(true)
    }

    private var palette: [StratumColorFraction] {
        cluster.colorMix.isEmpty
            ? [StratumColorFraction(hex: Constants.Color.amberLamp, fraction: 1)]
            : cluster.colorMix
    }

    private var dominantColorHex: String {
        palette.first?.hex ?? Constants.Color.amberLamp
    }
}

private struct MonthBottleSummary: Identifiable {
    let month: Date
    let records: [AccumulationRecord]

    var id: Date { month }
    var grams: Int { NonnegativeIntPolicy.sum(records.map(\.grams)) }
}

private struct MonthBottleCard: View {
    let summary: MonthBottleSummary
    let isFromPartialHistoryPage: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MiniBottleGraphic(records: summary.records)
                .frame(height: 128)
            Text(summary.month.formatted(.dateTime.year().month()))
                .font(.caption.weight(.bold))
            if isFromPartialHistoryPage {
                Text("読み込み範囲内")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(PomoGemTheme.amber)
            }
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(summary.records.count)粒")
                        Text(formattedMass(summary.grams))
                    }
                } else {
                    HStack {
                        Text("\(summary.records.count)粒")
                        Spacer()
                        Text(formattedMass(summary.grams))
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(PomoGemTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 19))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(summary.month.formatted(.dateTime.year().month()))の瓶、\(isFromPartialHistoryPage ? "読み込み範囲内、" : "")\(summary.records.count)粒、\(formattedMass(summary.grams))"
        )
    }

    private func formattedMass(_ grams: Int) -> String {
        grams >= 1_000 ? String(format: "%.1fkg", Double(grams) / 1_000) : "\(grams)g"
    }
}

private struct MiniBottleGraphic: View {
    let records: [AccumulationRecord]

    var body: some View {
        Canvas { context, size in
            let bottleRect = CGRect(x: 12, y: 8, width: max(1, size.width - 24), height: max(1, size.height - 14))
            let bottle = RoundedRectangle(cornerRadius: 22, style: .continuous).path(in: bottleRect)
            context.fill(bottle, with: .color(PomoGemTheme.raised.opacity(0.36)))
            context.stroke(bottle, with: .color(PomoGemTheme.glassEdge.opacity(0.42)), lineWidth: 1.5)

            let visible = Array(records.suffix(32))
            let columns = 6
            let dot = min(12, max(6, (bottleRect.width - 20) / CGFloat(columns) * 0.62))
            for (index, record) in visible.enumerated() {
                let column = index % columns
                let row = index / columns
                let x = bottleRect.minX + 15 + CGFloat(column) * ((bottleRect.width - 30) / CGFloat(columns - 1))
                let y = bottleRect.maxY - 14 - CGFloat(row) * dot * 0.82
                context.fill(
                    Path(ellipseIn: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)),
                    with: .color(Color(hex: record.colorHex).opacity(0.94))
                )
            }
        }
        .accessibilityHidden(true)
    }
}

private struct OverviewBottleGraphic: View {
    let records: [AccumulationRecord]
    let clusters: [AccumulationClusterSummary]
    let milestones: [AccumulationMilestoneSummary]

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: size.width * 0.1, y: 5, width: size.width * 0.8, height: size.height - 10)
            let bottle = RoundedRectangle(cornerRadius: min(44, rect.width * 0.18), style: .continuous).path(in: rect)
            context.fill(bottle, with: .color(PomoGemTheme.raised.opacity(0.28)))
            context.stroke(bottle, with: .color(PomoGemTheme.glassEdge.opacity(0.48)), lineWidth: 2)

            let bottom = rect.maxY - 18
            let columns = 8
            for (index, record) in records.enumerated() {
                let dot: CGFloat = 9
                let column = index % columns
                let row = index / columns
                let x = rect.minX + 22 + CGFloat(column) * ((rect.width - 44) / CGFloat(columns - 1))
                let y = bottom - CGFloat(row) * dot * 0.8
                context.fill(
                    Path(ellipseIn: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)),
                    with: .color(Color(hex: record.colorHex).opacity(0.68))
                )
            }

            for (index, cluster) in clusters.enumerated() {
                let diameter = CGFloat(min(34, 22 + cluster.level * 3))
                let column = index % 5
                let row = index / 5
                let x = rect.minX + 34 + CGFloat(column) * ((rect.width - 68) / 4)
                let y = bottom - 42 - CGFloat(row) * 29
                let mix = cluster.colorMix.isEmpty
                    ? [StratumColorFraction(hex: Constants.Color.amberLamp, fraction: 1)]
                    : cluster.colorMix
                let outer = Path(ellipseIn: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter))
                context.fill(outer, with: .color(PomoGemTheme.card))
                context.stroke(outer, with: .color(PomoGemTheme.amber.opacity(0.75)), lineWidth: 1.5)
                for dotIndex in 0..<min(7, max(3, mix.count * 2)) {
                    let angle = Double(dotIndex) * 2.399963229728653
                    let radius = diameter * 0.22
                    let center = CGPoint(
                        x: x + CGFloat(cos(angle)) * radius,
                        y: y + CGFloat(sin(angle)) * radius
                    )
                    let color = mix[dotIndex % mix.count]
                    context.fill(
                        Path(ellipseIn: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)),
                        with: .color(Color(hex: color.hex))
                    )
                }
            }

            for (index, milestone) in milestones.enumerated() {
                let diameter: CGFloat = 22
                let x = rect.minX + 28 + CGFloat(index % 6) * ((rect.width - 56) / 5)
                let y = rect.minY + 34 + CGFloat(index / 6) * 27
                let stone = Path(ellipseIn: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter))
                context.fill(stone, with: .color(Color(hex: milestone.colorHex).opacity(0.94)))
                context.stroke(stone, with: .color(PomoGemTheme.amber), lineWidth: 2)
                context.draw(
                    Text(milestone.mark)
                        .font(.system(size: 7, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white),
                    at: CGPoint(x: x, y: y)
                )
            }
        }
        .accessibilityHidden(true)
    }
}
