import Accessibility
import Charts
import SwiftData
import SwiftUI

/// Shared, hard-bounded query contract for history-heavy destinations.
///
/// The active bottle already keeps exact lifetime mass in decimal aggregate
/// roots. History screens must not instantiate every original StudySession to
/// draw a chart or card. Every descriptor below either has a narrow date/ID
/// predicate or a fixed limit; callers disclose whenever the `limit + 1`
/// sentinel proves that a page is partial.
enum BoundedHistoryPolicy {
    static let periodSessionLimit = 2_048
    static let recentSessionLimit = 30
    static let achievementLimit = 60
    static let aggregateRootLimit = 64
    static let legacyAggregateLimit = 16
    static let shareLooseSessionLimit = 256
    static let aggregateMemberSessionLimit = 64

    static func latestResetMarkerDescriptor() -> FetchDescriptor<ActivityResetMarker> {
        var descriptor = FetchDescriptor<ActivityResetMarker>(sortBy: [
            SortDescriptor(\ActivityResetMarker.resetAt, order: .reverse),
            SortDescriptor(\ActivityResetMarker.sequence, order: .reverse),
            SortDescriptor(\ActivityResetMarker.writerDeviceID, order: .reverse),
            SortDescriptor(\ActivityResetMarker.epochID, order: .reverse),
            SortDescriptor(\ActivityResetMarker.id, order: .reverse)
        ])
        descriptor.fetchLimit = 1
        return descriptor
    }

    static func sessionDescriptor(
        epochID: UUID?,
        start: Date? = nil,
        end: Date? = nil,
        onlyUnbaked: Bool = false,
        order: SortOrder = .reverse,
        limit: Int
    ) -> FetchDescriptor<StudySession> {
        let predicate: Predicate<StudySession>
        switch (epochID, start, end, onlyUnbaked) {
        case let (.some(epoch), .some(start), .some(end), false):
            predicate = #Predicate {
                $0.dataEpochID == epoch && $0.endAt >= start && $0.endAt < end
            }
        case let (.none, .some(start), .some(end), false):
            predicate = #Predicate {
                $0.dataEpochID == nil && $0.endAt >= start && $0.endAt < end
            }
        case let (.some(epoch), .some(start), .none, false):
            predicate = #Predicate { $0.dataEpochID == epoch && $0.endAt >= start }
        case let (.none, .some(start), .none, false):
            predicate = #Predicate { $0.dataEpochID == nil && $0.endAt >= start }
        case let (.some(epoch), .none, .none, true):
            predicate = #Predicate { $0.dataEpochID == epoch && $0.isBaked == false }
        case (.none, .none, .none, true):
            predicate = #Predicate { $0.dataEpochID == nil && $0.isBaked == false }
        case let (.some(epoch), .none, .none, false):
            predicate = #Predicate { $0.dataEpochID == epoch }
        case (.none, .none, .none, false):
            predicate = #Predicate { $0.dataEpochID == nil }
        default:
            // No current caller needs an end-only or date-bounded unbaked
            // query. Returning an impossible predicate is safer than silently
            // widening a future malformed request to the entire store.
            predicate = #Predicate { _ in false }
        }
        var descriptor = FetchDescriptor<StudySession>(
            predicate: predicate,
            sortBy: [SortDescriptor(\StudySession.endAt, order: order)]
        )
        descriptor.fetchLimit = max(1, limit)
        return descriptor
    }

    /// Count-only descriptor. `ModelContext.fetchCount` executes this in the
    /// store and does not instantiate the matching StudySession objects.
    static func sessionCountDescriptor(epochID: UUID?) -> FetchDescriptor<StudySession> {
        if let epochID {
            return FetchDescriptor<StudySession>(
                predicate: #Predicate { $0.dataEpochID == epochID }
            )
        }
        return FetchDescriptor<StudySession>(
            predicate: #Predicate { $0.dataEpochID == nil }
        )
    }

    static func sessionDescriptor(
        id: UUID,
        epochID: UUID?,
        limit: Int = 4
    ) -> FetchDescriptor<StudySession> {
        let predicate: Predicate<StudySession>
        if let epochID {
            predicate = #Predicate { $0.id == id && $0.dataEpochID == epochID }
        } else {
            predicate = #Predicate { $0.id == id && $0.dataEpochID == nil }
        }
        var descriptor = FetchDescriptor<StudySession>(
            predicate: predicate,
            sortBy: [SortDescriptor(\StudySession.endAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        return descriptor
    }

    /// Returns a bounded page of active candidates. Callers must pass the page
    /// through `AchievementStonePolicy.resolvedVisibleCandidates` before use;
    /// that exact-ID lookup includes tombstones and prevents late stale rows
    /// from resurfacing without loading the lifetime ledger.
    static func achievementCandidateDescriptor(
        epochID: UUID?,
        start: Date? = nil,
        end: Date? = nil,
        order: SortOrder = .reverse,
        limit: Int
    ) -> FetchDescriptor<AchievementStone> {
        let predicate: Predicate<AchievementStone>
        switch (epochID, start, end) {
        case let (.some(epoch), .some(start), .some(end)):
            predicate = #Predicate {
                $0.dataEpochID == epoch
                    && $0.deletedAt == nil
                    && $0.achievedAt >= start
                    && $0.achievedAt < end
            }
        case let (.none, .some(start), .some(end)):
            predicate = #Predicate {
                $0.dataEpochID == nil
                    && $0.deletedAt == nil
                    && $0.achievedAt >= start
                    && $0.achievedAt < end
            }
        case let (.some(epoch), .none, .none):
            predicate = #Predicate { $0.dataEpochID == epoch && $0.deletedAt == nil }
        case (.none, .none, .none):
            predicate = #Predicate { $0.dataEpochID == nil && $0.deletedAt == nil }
        default:
            predicate = #Predicate { _ in false }
        }
        var descriptor = FetchDescriptor<AchievementStone>(
            predicate: predicate,
            sortBy: [SortDescriptor(\AchievementStone.achievedAt, order: order)]
        )
        descriptor.fetchLimit = max(1, limit)
        return descriptor
    }

    /// Includes tombstones so edit/delete/Undo can advance every local logical
    /// duplicate to one revision without widening the read to history.
    static func achievementRevisionDescriptor(
        id: UUID,
        epochID: UUID?,
        limit: Int = 16
    ) -> FetchDescriptor<AchievementStone> {
        let predicate: Predicate<AchievementStone>
        if let epochID {
            predicate = #Predicate { $0.id == id && $0.dataEpochID == epochID }
        } else {
            predicate = #Predicate { $0.id == id && $0.dataEpochID == nil }
        }
        // Always retain the canonical head inside this bounded mutation page.
        // Otherwise an unusually large duplicate set could let an arbitrary
        // fetch omit a newer tombstone and make an edit appear to resurrect it.
        var descriptor = FetchDescriptor<AchievementStone>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\AchievementStone.revision, order: .reverse),
                SortDescriptor(\AchievementStone.deletedAt, order: .reverse),
                SortDescriptor(\AchievementStone.updatedAt, order: .reverse),
                SortDescriptor(\AchievementStone.createdAt, order: .reverse),
                SortDescriptor(\AchievementStone.achievedAt, order: .reverse),
                SortDescriptor(\AchievementStone.note, order: .reverse),
                SortDescriptor(\AchievementStone.subjectNameSnapshot, order: .reverse)
            ]
        )
        descriptor.fetchLimit = max(1, limit)
        return descriptor
    }

    static func rootAggregateDescriptor(
        epochID: UUID?,
        limit: Int
    ) -> FetchDescriptor<AggregatePebble> {
        let predicate: Predicate<AggregatePebble>
        if let epochID {
            predicate = #Predicate {
                $0.dataEpochID == epochID && $0.parentAggregateID == nil
            }
        } else {
            predicate = #Predicate {
                $0.dataEpochID == nil && $0.parentAggregateID == nil
            }
        }
        var descriptor = FetchDescriptor<AggregatePebble>(
            predicate: predicate,
            sortBy: [SortDescriptor(\AggregatePebble.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        return descriptor
    }

    static func aggregateDescriptor(
        id: UUID,
        epochID: UUID?,
        limit: Int = 4
    ) -> FetchDescriptor<AggregatePebble> {
        let predicate: Predicate<AggregatePebble>
        if let epochID {
            predicate = #Predicate { $0.id == id && $0.dataEpochID == epochID }
        } else {
            predicate = #Predicate { $0.id == id && $0.dataEpochID == nil }
        }
        var descriptor = FetchDescriptor<AggregatePebble>(
            predicate: predicate,
            sortBy: [SortDescriptor(\AggregatePebble.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        return descriptor
    }

    static func legacyAggregateDescriptor(
        epochID: UUID?,
        limit: Int
    ) -> FetchDescriptor<Stratum> {
        let predicate: Predicate<Stratum>
        if let epochID {
            predicate = #Predicate { $0.dataEpochID == epochID }
        } else {
            predicate = #Predicate { $0.dataEpochID == nil }
        }
        var descriptor = FetchDescriptor<Stratum>(
            predicate: predicate,
            sortBy: [SortDescriptor(\Stratum.bakedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        return descriptor
    }

    static func legacyAggregateDescriptor(
        id: UUID,
        epochID: UUID?,
        limit: Int = 4
    ) -> FetchDescriptor<Stratum> {
        let predicate: Predicate<Stratum>
        if let epochID {
            predicate = #Predicate { $0.id == id && $0.dataEpochID == epochID }
        } else {
            predicate = #Predicate { $0.id == id && $0.dataEpochID == nil }
        }
        var descriptor = FetchDescriptor<Stratum>(
            predicate: predicate,
            sortBy: [SortDescriptor(\Stratum.bakedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        return descriptor
    }
}

struct LogView: View {
    enum Period: String, CaseIterable, Identifiable {
        case week = "週"
        case month = "月"
        var id: Self { self }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var activityResetMarkers: [ActivityResetMarker]
    @Query(sort: \Subject.sortOrder) private var subjects: [Subject]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var period: Period = .week
    @State private var selectedWrappedMonth: WrappedMonth?
    @State private var periodSessions: [StudySession] = []
    @State private var recentSessions: [StudySession] = []
    @State private var achievementStones: [AchievementStone] = []
    @State private var aggregatePebbles: [AggregatePebble] = []
    @State private var strata: [Stratum] = []
    @State private var monthSummaries: [LogMonthSummary] = []
    @State private var periodPageIsPartial = false
    @State private var achievementPageIsPartial = false
    @State private var aggregatePageIsPartial = false
    @State private var loadError: String?
    @State private var mutationError: String?
    @State private var selectedAchievement: AchievementEditSelection?
    @State private var pendingAchievementUndo: AchievementStoneRevisionSnapshot?

    init() {
        _activityResetMarkers = Query(BoundedHistoryPolicy.latestResetMarkerDescriptor())
    }

    private var resetSnapshots: [ActivityResetSnapshot] {
        activityResetMarkers.map(\.policySnapshot)
    }
    private var filteredSessions: [StudySession] {
        periodSessions
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                Picker("表示期間", selection: $period) {
                    ForEach(Period.allCases) { item in Text(item.rawValue).tag(item) }
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 2)

                achievementUndoNotice

                if periodPageIsPartial {
                    Label(
                        "この期間は記録が多いため、最新\(BoundedHistoryPolicy.periodSessionLimit)件の表示分です。",
                        systemImage: "rectangle.stack.badge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(TsumibenTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("log.partial-period-notice")
                }

                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(TsumibenTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                summaryGrid
                // A chosen, real-world milestone is stronger evidence of
                // progress than charts or a random visual variant. Keep it
                // near the top of the log so a qualification or completed
                // deliverable is visible without hunting below rare stats.
                achievementArchive
                massChart
                subjectComposition
                rarePebbles
                wrappedArchive
                aggregateArchive
                recentHistory
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background(NightBackground())
        .tsumibenNavigationTitle("記録")
        .toolbarTitleDisplayMode(.large)
        .fullScreenCover(item: $selectedWrappedMonth) { month in
            WrappedView(month: month)
        }
        .sheet(item: $selectedAchievement, onDismiss: {
            selectedAchievement = nil
        }) { selection in
            AchievementEditorSheet(
                selection: selection,
                subjects: editableSubjects(for: selection),
                onSave: { draft in
                    saveAchievement(selection: selection, draft: draft)
                },
                onDelete: {
                    deleteAchievement(selection: selection)
                }
            )
        }
        .alert(
            "記念石を変更できません",
            isPresented: Binding(
                get: { mutationError != nil },
                set: { if !$0 { mutationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { mutationError = nil }
        } message: {
            Text(mutationError ?? "もう一度お試しください。")
        }
        .task(id: loadKey) {
            loadBoundedHistory()
        }
    }

    private var summaryGrid: some View {
        let measured = filteredSessions.filter { $0.source == .timer }
        let totalMinutes = filteredSessions.reduce(0) { $0 + $1.seconds } / 60
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    summaryTiles(measuredCount: measured.count, totalMinutes: totalMinutes)
                }
            } else {
                HStack(spacing: 10) {
                    summaryTiles(measuredCount: measured.count, totalMinutes: totalMinutes)
                }
            }
        }
    }

    @ViewBuilder
    private func summaryTiles(measuredCount: Int, totalMinutes: Int) -> some View {
        SummaryTile(label: periodPageIsPartial ? "表示分の時間" : "積んだ時間", value: formatMinutes(totalMinutes), symbol: "hourglass")
        SummaryTile(label: periodPageIsPartial ? "表示分の完走" : "完走ポモ", value: "\(measuredCount)", symbol: "checkmark.circle")
        SummaryTile(
            label: periodPageIsPartial ? "表示分の質量" : "今期の質量",
            value: formatMass(filteredSessions.reduce(0) { $0 + $1.grams }),
            symbol: "scalemass"
        )
    }

    private var massChart: some View {
        let values = dailyMass
        let descriptor = DailyMassChartDescriptor(
            values: values,
            periodTitle: period == .week ? "直近7日" : "今月",
            isPartial: periodPageIsPartial
        )
        return TsumibenCard {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionEyebrow(text: "MASS")
                    Text("質量の推移")
                        .font(TsumibenTheme.brand(20))
                }
                if values.allSatisfy({ $0.grams == 0 }) {
                    EmptyChartMessage(text: "この期間の粒は、まだありません。")
                        .accessibilityChartDescriptor(descriptor)
                } else {
                    Chart(values) { item in
                        BarMark(
                            x: .value("日", item.date, unit: .day),
                            y: .value("グラム", item.grams)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [TsumibenTheme.amber, TsumibenTheme.amber.opacity(0.44)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .cornerRadius(4)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: period == .week ? .day : .weekOfMonth)) { value in
                            AxisValueLabel(format: period == .week ? .dateTime.weekday(.narrow) : .dateTime.day())
                            AxisGridLine().foregroundStyle(.clear)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine().foregroundStyle(TsumibenTheme.glassEdge.opacity(0.08))
                            AxisValueLabel {
                                if let grams = value.as(Int.self) { Text(formatMass(grams)).font(.caption2) }
                            }
                        }
                    }
                    .frame(height: 180)
                    .accessibilityChartDescriptor(descriptor)
                }
            }
        }
    }

    private var subjectComposition: some View {
        TsumibenCard {
            VStack(alignment: .leading, spacing: 17) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionEyebrow(text: "SUBJECTS")
                    Text("テーマの構成")
                        .font(TsumibenTheme.brand(20))
                }
                if subjectMass.isEmpty {
                    EmptyChartMessage(text: "積んだテーマがここに並びます。")
                } else {
                    GeometryReader { proxy in
                        HStack(spacing: 3) {
                            ForEach(subjectMass) { item in
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(hex: item.colorHex))
                                    .frame(width: max(4, proxy.size.width * item.fraction))
                                    .accessibilityLabel("\(item.name)、\(Int(item.fraction * 100))パーセント")
                            }
                        }
                    }
                    .frame(height: 18)

                    VStack(spacing: 9) {
                        ForEach(subjectMass) { item in
                            HStack(spacing: 10) {
                                Circle().fill(Color(hex: item.colorHex)).frame(width: 9, height: 9)
                                Text(item.name).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(formatMass(item.grams))
                                    .font(.system(.caption, design: .rounded, weight: .bold))
                                    .foregroundStyle(TsumibenTheme.muted)
                            }
                        }
                    }
                }
            }
        }
    }

    private var rarePebbles: some View {
        let totals = RareRewardCounts.total(filteredSessions.map(\.rareRewardCounts))
        let rareSessions = filteredSessions.filter { $0.rareRewardCounts.rareCount > 0 }
        return TsumibenCard {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 14) {
                        RareStat(kind: .gold, count: totals.goldCount)
                        RareStat(kind: .prism, count: totals.prismCount)
                        if let latest = rareSessions.max(by: { $0.endAt < $1.endAt }) {
                            LabeledContent(
                                "最後に出た日",
                                value: latest.endAt.formatted(date: .abbreviated, time: .omitted)
                            )
                            .font(.caption)
                            .foregroundStyle(TsumibenTheme.muted)
                        }
                    }
                } else {
                    HStack(spacing: 18) {
                        RareStat(kind: .gold, count: totals.goldCount)
                        Divider().overlay(TsumibenTheme.glassEdge.opacity(0.15))
                        RareStat(kind: .prism, count: totals.prismCount)
                        Spacer()
                        if let latest = rareSessions.max(by: { $0.endAt < $1.endAt }) {
                            VStack(alignment: .trailing, spacing: 3) {
                                Text("最後に出た日").font(.caption2).foregroundStyle(TsumibenTheme.muted)
                                Text(latest.endAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption.weight(.bold))
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var achievementArchive: some View {
        let stones = uniqueAchievementStones
        if !stones.isEmpty {
            TsumibenCard {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionEyebrow(text: "MILESTONES")
                        Text("記念石アーカイブ")
                            .font(TsumibenTheme.brand(20))
                        Text(achievementArchiveDescription(count: stones.count))
                            .font(.caption)
                            .foregroundStyle(TsumibenTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(stones) { stone in
                        Button {
                            selectedAchievement = AchievementEditSelection(stone)
                        } label: {
                            AchievementHistoryRow(stone: stone)
                        }
                        .buttonStyle(TsumibenBareButtonStyle())
                        .accessibilityIdentifier("achievement.history.row")
                        .accessibilityHint("詳細を開いて、種類・テーマ・日付・メモを編集できます")
                        if stone.id != stones.last?.id {
                            Divider().overlay(TsumibenTheme.glassEdge.opacity(0.08))
                        }
                    }
                }
            }
        }
    }

    private var uniqueAchievementStones: [AchievementStone] {
        AchievementStonePolicy.canonicalStones(from: achievementStones)
        .filter { $0.deletedAt == nil }
        .sorted {
            if $0.achievedAt == $1.achievedAt { return $0.id.uuidString > $1.id.uuidString }
            return $0.achievedAt > $1.achievedAt
        }
    }

    @ViewBuilder
    private var achievementUndoNotice: some View {
        if let pendingAchievementUndo {
            TsumibenCard {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.title3)
                        .foregroundStyle(TsumibenTheme.amber)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("記念石を削除しました")
                            .font(.subheadline.weight(.bold))
                        Text("質量は変わりません。記録・瓶・共有から非表示になりました。")
                            .font(.caption)
                            .foregroundStyle(TsumibenTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button("元に戻す") {
                        undoAchievementDeletion(pendingAchievementUndo)
                    }
                    .font(.subheadline.weight(.bold))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .buttonStyle(TsumibenRowButtonStyle())
                    .accessibilityIdentifier("achievement.undo-delete")
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var wrappedArchive: some View {
        if !monthSummaries.isEmpty {
            TsumibenCard {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionEyebrow(text: "MONTHLY WRAPPED")
                        Text("月ごとの瓶")
                            .font(TsumibenTheme.brand(20))
                        Text("直近12か月を、月ごとの瓶で振り返れます。")
                            .font(.caption)
                            .foregroundStyle(TsumibenTheme.muted)
                    }

                    ForEach(monthSummaries) { summary in
                        let month = summary.month
                        Button {
                            selectedWrappedMonth = month
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "sparkles.rectangle.stack.fill")
                                    .foregroundStyle(TsumibenTheme.amber)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(month.title)
                                        .font(.subheadline.weight(.bold))
                                    Text(summary.rowLabel(formatMinutes: formatMinutes))
                                        .font(.caption)
                                        .foregroundStyle(TsumibenTheme.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(TsumibenTheme.muted)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(TsumibenRowButtonStyle())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var aggregateArchive: some View {
        let items = aggregateArchiveItems
        if !items.isEmpty {
            TsumibenCard {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionEyebrow(text: "OVERVIEW PEBBLES")
                        Text("まとまり粒アーカイブ")
                            .font(TsumibenTheme.brand(20))
                        Text("小さな粒は消えません。10粒ずつまとまり、瓶の中で動き続けます。")
                            .font(.caption)
                            .foregroundStyle(TsumibenTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if aggregatePageIsPartial {
                        Text("ここでは最新\(BoundedHistoryPolicy.aggregateRootLimit)個を表示しています。生涯の質量は瓶の俯瞰画面で確認できます。")
                            .font(.caption)
                            .foregroundStyle(TsumibenTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(items) { item in
                        AggregateArchiveRow(item: item)
                        if item.id != items.last?.id {
                            Divider().overlay(TsumibenTheme.glassEdge.opacity(0.08))
                        }
                    }
                }
            }
        }
    }

    /// Only roots are shown. A ×100 parent already contains its ten ×10
    /// children, so showing both as peers would visually double-count history.
    private var aggregateArchiveItems: [AggregateArchiveItem] {
        let roots = AggregatePebblePolicy.disjointRootSummaries(from: aggregatePebbles)
        let allAggregateIDs = Set(aggregatePebbles.map(\.id))
        let modern = roots.map(AggregateArchiveItem.init(aggregate:))

        let legacy = strata
            .filter { !allAggregateIDs.contains($0.id) }
            .map { layer in
                let membership = Set(layer.sessionIDs)
                let members = uniqueSessions.filter { membership.contains($0.id) }
                return AggregateArchiveItem(legacy: layer, members: members)
            }

        return (modern + legacy).sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString > rhs.id.uuidString }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private var uniqueSessions: [StudySession] {
        Dictionary(grouping: periodSessions + recentSessions, by: \.id).values.compactMap { duplicates in
            duplicates.max { lhs, rhs in lhs.grams < rhs.grams }
        }
    }

    private var recentHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近の記録").font(TsumibenTheme.brand(20))
                Spacer()
                Text("最新30件").font(.caption).foregroundStyle(TsumibenTheme.muted)
            }
            if recentSessions.isEmpty {
                TsumibenCard { EmptyChartMessage(text: "一粒積むと、ここに記録が残ります。") }
            } else {
                VStack(spacing: 0) {
                    ForEach(recentSessions.prefix(BoundedHistoryPolicy.recentSessionLimit)) { session in
                        HistoryRow(session: session)
                        if session.id != recentSessions.prefix(BoundedHistoryPolicy.recentSessionLimit).last?.id {
                            Divider().overlay(TsumibenTheme.glassEdge.opacity(0.08)).padding(.leading, 48)
                        }
                    }
                }
                .background(TsumibenTheme.card, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var dailyMass: [DailyMass] {
        let calendar = Calendar.autoupdatingCurrent
        let days: [Date]
        switch period {
        case .week:
            let today = calendar.startOfDay(for: .now)
            days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0 - 6, to: today) }
        case .month:
            guard let interval = calendar.dateInterval(of: .month, for: .now),
                  let range = calendar.range(of: .day, in: .month, for: .now)
            else { return [] }
            days = range.compactMap { day in calendar.date(byAdding: .day, value: day - 1, to: interval.start) }
        }
        return days.map { day in
            DailyMass(
                date: day,
                grams: filteredSessions.filter { calendar.isDate($0.endAt, inSameDayAs: day) }.reduce(0) { $0 + $1.grams }
            )
        }
    }

    private var subjectMass: [SubjectMass] {
        let grouped = Dictionary(grouping: filteredSessions) { session in
            session.subject?.id.uuidString
                ?? "deleted:\(session.subjectNameSnapshot):\(session.subjectColorHexSnapshot)"
        }
        let values = grouped.compactMap { identity, sessions -> (String, String, String, Int)? in
            guard let first = sessions.first else { return nil }
            return (
                identity,
                first.displaySubjectName,
                first.displaySubjectColorHex,
                sessions.reduce(0) { $0 + $1.grams }
            )
        }
        let total = max(1, values.reduce(0) { $0 + $1.3 })
        return values
            .map {
                SubjectMass(
                    id: $0.0,
                    name: $0.1,
                    colorHex: $0.2,
                    grams: $0.3,
                    fraction: Double($0.3) / Double(total)
                )
            }
            .sorted { $0.grams > $1.grams }
    }

    private var loadKey: String {
        let epoch = ActivityResetPolicy.currentEpochID(from: resetSnapshots)?.uuidString ?? "pre-reset"
        return "\(epoch)|\(period.rawValue)|\(scenePhase == .active)"
    }

    @MainActor
    private func loadBoundedHistory() {
        guard scenePhase == .active else { return }
        let epochID = ActivityResetPolicy.currentEpochID(from: resetSnapshots)
        let calendar = Calendar.autoupdatingCurrent
        let now = Date.now
        let periodStart: Date
        switch period {
        case .week:
            periodStart = calendar.date(
                byAdding: .day,
                value: -6,
                to: calendar.startOfDay(for: now)
            ) ?? .distantPast
        case .month:
            periodStart = calendar.dateInterval(of: .month, for: now)?.start ?? .distantPast
        }

        do {
            let periodRaw = try modelContext.fetch(BoundedHistoryPolicy.sessionDescriptor(
                epochID: epochID,
                start: periodStart,
                order: .reverse,
                limit: BoundedHistoryPolicy.periodSessionLimit + 1
            ))
            periodPageIsPartial = periodRaw.count > BoundedHistoryPolicy.periodSessionLimit
            periodSessions = uniqueSessions(
                Array(periodRaw.prefix(BoundedHistoryPolicy.periodSessionLimit))
            )

            let recentRaw = try modelContext.fetch(BoundedHistoryPolicy.sessionDescriptor(
                epochID: epochID,
                order: .reverse,
                limit: BoundedHistoryPolicy.recentSessionLimit * 2
            ))
            recentSessions = Array(uniqueSessions(recentRaw)
                .sorted { $0.endAt > $1.endAt }
                .prefix(BoundedHistoryPolicy.recentSessionLimit))

            let achievementRaw = try modelContext.fetch(BoundedHistoryPolicy.achievementCandidateDescriptor(
                epochID: epochID,
                order: .reverse,
                limit: BoundedHistoryPolicy.achievementLimit + 1
            ))
            achievementPageIsPartial = achievementRaw.count > BoundedHistoryPolicy.achievementLimit
            achievementStones = try AchievementStonePolicy.resolvedVisibleCandidates(
                from: Array(achievementRaw.prefix(BoundedHistoryPolicy.achievementLimit)),
                context: modelContext
            )

            let aggregateRaw = try modelContext.fetch(BoundedHistoryPolicy.rootAggregateDescriptor(
                epochID: epochID,
                limit: BoundedHistoryPolicy.aggregateRootLimit + 1
            ))
            aggregatePageIsPartial = aggregateRaw.count > BoundedHistoryPolicy.aggregateRootLimit
            aggregatePebbles = Array(aggregateRaw.prefix(BoundedHistoryPolicy.aggregateRootLimit))
            strata = try modelContext.fetch(BoundedHistoryPolicy.legacyAggregateDescriptor(
                epochID: epochID,
                limit: BoundedHistoryPolicy.legacyAggregateLimit
            ))

            monthSummaries = try loadMonthSummaries(epochID: epochID, now: now, calendar: calendar)
            loadError = nil
        } catch {
            loadError = "記録の一部を読み込めませんでした。もう一度この画面を開いてください。"
        }
    }

    @MainActor
    private func loadMonthSummaries(
        epochID: UUID?,
        now: Date,
        calendar: Calendar
    ) throws -> [LogMonthSummary] {
        guard let currentStart = calendar.dateInterval(of: .month, for: now)?.start else {
            return []
        }
        var summaries: [LogMonthSummary] = []
        for offset in 0..<12 {
            guard let start = calendar.date(byAdding: .month, value: -offset, to: currentStart),
                  let end = calendar.date(byAdding: .month, value: 1, to: start)
            else { continue }
            let raw = try modelContext.fetch(BoundedHistoryPolicy.sessionDescriptor(
                epochID: epochID,
                start: start,
                end: end,
                order: .reverse,
                limit: BoundedHistoryPolicy.periodSessionLimit + 1
            ))
            guard !raw.isEmpty else { continue }
            let isPartial = raw.count > BoundedHistoryPolicy.periodSessionLimit
            let values = uniqueSessions(Array(raw.prefix(BoundedHistoryPolicy.periodSessionLimit)))
            summaries.append(LogMonthSummary(
                month: WrappedMonth(containing: start, calendar: calendar),
                minutes: values.reduce(0) { $0 + max(0, $1.seconds) } / 60,
                pebbleCount: values.count,
                isPartial: isPartial
            ))
        }
        return summaries
    }

    private func uniqueSessions(_ values: [StudySession]) -> [StudySession] {
        Dictionary(grouping: values, by: \.id).values.compactMap { duplicates in
            duplicates.max { lhs, rhs in
                if lhs.grams == rhs.grams { return lhs.endAt < rhs.endAt }
                return lhs.grams < rhs.grams
            }
        }
    }

    private func editableSubjects(
        for selection: AchievementEditSelection
    ) -> [Subject] {
        Dictionary(grouping: subjects, by: \.id).values.compactMap { duplicates in
            duplicates.min { lhs, rhs in lhs.createdAt < rhs.createdAt }
        }
        .filter { !$0.isArchived || $0.id == selection.subjectID }
        .sorted { lhs, rhs in
            if lhs.sortOrder == rhs.sortOrder { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    @MainActor
    private func saveAchievement(
        selection: AchievementEditSelection,
        draft: AchievementEditDraft
    ) -> String? {
        do {
            let values = try achievementRevisionRows(for: selection.id, epochID: selection.dataEpochID)
            guard let canonical = AchievementStonePolicy.canonicalStone(from: values),
                  canonical.deletedAt == nil else {
                loadBoundedHistory()
                return "この記念石は別の端末ですでに削除されています。"
            }
            guard let subject = subjects.first(where: { $0.id == draft.subjectID }) else {
                return "選んだテーマが見つかりません。テーマを選び直してください。"
            }
            AchievementStoneRevisionPolicy.edit(
                values,
                subject: subject,
                kind: draft.kind,
                note: draft.note,
                achievedAt: draft.achievedAt
            )
            try modelContext.save()
            loadBoundedHistory()
            return nil
        } catch {
            modelContext.rollback()
            loadBoundedHistory()
            return "編集内容を保存できませんでした。通信状態を確認して、もう一度お試しください。"
        }
    }

    @MainActor
    private func deleteAchievement(
        selection: AchievementEditSelection
    ) -> String? {
        do {
            let values = try achievementRevisionRows(for: selection.id, epochID: selection.dataEpochID)
            guard let canonical = AchievementStonePolicy.canonicalStone(from: values) else {
                return "この記念石は見つかりませんでした。"
            }
            guard canonical.deletedAt == nil else {
                loadBoundedHistory()
                return "この記念石は別の端末ですでに削除されています。"
            }
            let snapshot = AchievementStoneRevisionSnapshot(canonical)
            AchievementStoneRevisionPolicy.delete(values)
            try modelContext.save()
            pendingAchievementUndo = snapshot
            loadBoundedHistory()
            return nil
        } catch {
            modelContext.rollback()
            loadBoundedHistory()
            return "記念石を削除できませんでした。通信状態を確認して、もう一度お試しください。"
        }
    }

    @MainActor
    private func undoAchievementDeletion(
        _ snapshot: AchievementStoneRevisionSnapshot
    ) {
        do {
            let values = try achievementRevisionRows(
                for: snapshot.id,
                epochID: snapshot.dataEpochID
            )
            guard let canonical = AchievementStonePolicy.canonicalStone(from: values) else {
                mutationError = "削除した記念石が見つからないため、元に戻せませんでした。"
                return
            }
            if canonical.deletedAt == nil {
                pendingAchievementUndo = nil
                loadBoundedHistory()
                return
            }
            let subject = snapshot.subjectID.flatMap { subjectID in
                subjects.first { $0.id == subjectID }
            }
            AchievementStoneRevisionPolicy.restore(
                values,
                snapshot: snapshot,
                subject: subject
            )
            try modelContext.save()
            pendingAchievementUndo = nil
            loadBoundedHistory()
        } catch {
            modelContext.rollback()
            loadBoundedHistory()
            mutationError = "削除した記念石を元に戻せませんでした。通信状態を確認して、もう一度お試しください。"
        }
    }

    @MainActor
    private func achievementRevisionRows(
        for id: UUID,
        epochID: UUID?
    ) throws -> [AchievementStone] {
        try modelContext.fetch(BoundedHistoryPolicy.achievementRevisionDescriptor(
            id: id,
            epochID: epochID
        ))
    }

    private func achievementArchiveDescription(count: Int) -> String {
        if achievementPageIsPartial {
            return "瓶では新しい12個が動き、ここでは最新\(count)個を表示しています。行をタップすると編集・削除できます。"
        }
        return "瓶では新しい12個が動き、これまでの\(count)個を振り返れます。行をタップすると編集・削除できます。"
    }

    private func formatMass(_ grams: Int) -> String {
        grams >= 1_000 ? String(format: "%.1fkg", Double(grams) / 1_000) : "\(grams)g"
    }

    private func formatMinutes(_ minutes: Int) -> String {
        minutes >= 60 ? String(format: "%.1fh", Double(minutes) / 60) : "\(minutes)m"
    }
}

private struct LogMonthSummary: Identifiable {
    let month: WrappedMonth
    let minutes: Int
    let pebbleCount: Int
    let isPartial: Bool

    var id: Date { month.id }

    func rowLabel(formatMinutes: (Int) -> String) -> String {
        if isPartial {
            return "表示分 \(formatMinutes(minutes))・\(pebbleCount)粒"
        }
        return "\(formatMinutes(minutes))・\(pebbleCount)粒"
    }
}

private struct DailyMass: Identifiable {
    var id: Date { date }
    let date: Date
    let grams: Int
}

private struct DailyMassChartDescriptor: AXChartDescriptorRepresentable {
    let values: [DailyMass]
    let periodTitle: String
    let isPartial: Bool

    var accessibilitySummary: String {
        let safeValues = values.map { max(0, $0.grams) }
        let total = safeValues.reduce(0, +)
        guard !values.isEmpty else {
            return "\(periodTitle)の質量の推移。日ごとのデータはありません。\(totalLabel)0グラム。"
        }
        guard let maximum = safeValues.max(), maximum > 0,
              let maximumIndex = safeValues.firstIndex(of: maximum)
        else {
            return "\(periodTitle)の質量の推移。\(values.count)日分、\(totalLabel)0グラム。記録された質量はありません。"
        }
        let maximumDate = spokenDate(values[maximumIndex].date)
        return "\(periodTitle)の質量の推移。\(values.count)日分、\(totalLabel)\(total)グラム。最大は\(maximumDate)の\(maximum)グラム。"
    }

    private var totalLabel: String {
        isPartial ? "最新記録の表示分合計" : "期間合計"
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        let categories = values.map { spokenDate($0.date) }
        let maximum = values.map { max(0, $0.grams) }.max() ?? 0
        let upperBound = Double(max(1, maximum))
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: "日付",
            categoryOrder: categories
        )
        let yAxis = AXNumericDataAxisDescriptor(
            title: "質量",
            range: 0 ... upperBound,
            gridlinePositions: maximum > 0 ? [0, upperBound] : [0]
        ) { value in
            "\(Int(value.rounded()))グラム"
        }
        let points = values.map { item in
            let date = spokenDate(item.date)
            let grams = max(0, item.grams)
            return AXDataPoint(
                x: date,
                y: Double(grams),
                label: "\(date)、\(grams)グラム"
            )
        }
        let series = AXDataSeriesDescriptor(
            name: "日ごとの質量",
            isContinuous: false,
            dataPoints: points
        )
        return AXChartDescriptor(
            title: "質量の推移",
            summary: accessibilitySummary,
            xAxis: xAxis,
            yAxis: yAxis,
            series: [series]
        )
    }

    private func spokenDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).day().weekday(.wide))
    }
}

private struct SubjectMass: Identifiable {
    let id: String
    let name: String
    let colorHex: String
    let grams: Int
    let fraction: Double
}

private struct AggregateArchiveItem: Identifiable {
    let id: UUID
    let createdAt: Date
    let level: Int
    let pebbleCount: Int
    let grams: Int
    let measuredPebbleCount: Int
    let manualPebbleCount: Int
    let goldPebbleCount: Int
    let prismPebbleCount: Int
    let colorMix: [StratumColorFraction]
    let subjectMix: [AggregateSubjectFraction]
    let periodStart: Date
    let periodEnd: Date

    init(aggregate: AggregatePebble) {
        id = aggregate.id
        createdAt = aggregate.createdAt
        level = aggregate.level
        pebbleCount = aggregate.pebbleCount
        grams = aggregate.grams
        measuredPebbleCount = aggregate.measuredPebbleCount
        manualPebbleCount = aggregate.manualPebbleCount
        goldPebbleCount = aggregate.goldPebbleCount
        prismPebbleCount = aggregate.prismPebbleCount
        colorMix = aggregate.colorMix
        subjectMix = aggregate.subjectMix
        periodStart = aggregate.periodStart
        periodEnd = aggregate.periodEnd
    }

    init(legacy layer: Stratum, members: [StudySession]) {
        id = layer.id
        createdAt = layer.bakedAt
        level = StrataMath.decimalAggregateLevel(forPebbleCount: layer.pebbleCount)
        pebbleCount = layer.pebbleCount
        grams = layer.grams
        measuredPebbleCount = members.isEmpty
            ? layer.pebbleCount
            : members.filter { $0.source.isMeasured }.count
        manualPebbleCount = members.filter { !$0.source.isMeasured }.count
        let rewards = RareRewardCounts.total(members.map(\.rareRewardCounts))
        goldPebbleCount = rewards.goldCount
        prismPebbleCount = rewards.prismCount
        colorMix = StrataMath.decodeColorMix(layer.colorMixJSON)
        subjectMix = StrataMath.mergedSubjectMix(
            members.map {
                [AggregateSubjectFraction(
                    name: $0.displaySubjectName,
                    colorHex: $0.displaySubjectColorHex,
                    pebbleCount: 1
                )]
            }
        )
        periodStart = members.map(\.startAt).min() ?? layer.bakedAt
        periodEnd = members.map(\.endAt).max() ?? layer.bakedAt
    }

    var periodLabel: String {
        let calendar = Calendar.autoupdatingCurrent
        let start = periodStart.formatted(.dateTime.year().month().day())
        guard !calendar.isDate(periodStart, inSameDayAs: periodEnd) else { return start }
        return "\(start) – \(periodEnd.formatted(.dateTime.year().month().day()))"
    }

    var formattedMass: String {
        grams >= 1_000 ? String(format: "%.1fkg", Double(grams) / 1_000) : "\(grams)g"
    }
}

private struct AggregateArchiveRow: View {
    let item: AggregateArchiveItem

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 13) {
                AggregateArchiveSwatch(item: item)

                VStack(alignment: .leading, spacing: 3) {
                    Text("×\(item.pebbleCount) のまとまり")
                        .font(.system(.headline, design: .rounded, weight: .heavy))
                    Text(item.periodLabel)
                        .font(.caption2)
                        .foregroundStyle(TsumibenTheme.muted)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(item.formattedMass)
                        .font(.system(.subheadline, design: .rounded, weight: .heavy))
                    Text("元 \(item.pebbleCount)粒")
                        .font(.caption2)
                        .foregroundStyle(TsumibenTheme.muted)
                }
            }

            AggregateColorBar(mix: item.colorMix)

            if !item.subjectMix.isEmpty {
                VStack(spacing: 5) {
                    ForEach(Array(item.subjectMix.prefix(3).enumerated()), id: \.offset) { _, subject in
                        HStack(spacing: 7) {
                            Circle()
                                .fill(Color(hex: subject.colorHex))
                                .frame(width: 7, height: 7)
                            Text(SubjectNamePolicy.displayName(subject.name))
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Text("\(subject.pebbleCount)粒")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(TsumibenTheme.muted)
                        }
                    }
                    if item.subjectMix.count > 3 {
                        Text("ほか \(item.subjectMix.count - 3)テーマ")
                            .font(.caption2)
                            .foregroundStyle(TsumibenTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) { compositionBadges }
                VStack(alignment: .leading, spacing: 7) { compositionBadges }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(item.pebbleCount)粒のまとまり、\(item.formattedMass)、\(item.periodLabel)、実測\(item.measuredPebbleCount)粒、手動\(item.manualPebbleCount)粒、金\(item.goldPebbleCount)粒、虹\(item.prismPebbleCount)粒"
        )
    }

    @ViewBuilder
    private var compositionBadges: some View {
        AggregateStatBadge(symbol: "timer", text: "実測 \(item.measuredPebbleCount)")
        AggregateStatBadge(symbol: "hand.tap", text: "手動 \(item.manualPebbleCount)")
        AggregateStatBadge(symbol: "sparkles", text: "金 \(item.goldPebbleCount)")
        AggregateStatBadge(symbol: "rainbow", text: "虹 \(item.prismPebbleCount)")
    }
}

private struct AggregateArchiveSwatch: View {
    let item: AggregateArchiveItem

    private var colors: [Color] {
        let values = item.colorMix.prefix(5).map { Color(hex: $0.hex) }
        return values.isEmpty ? [TsumibenTheme.raised, TsumibenTheme.card] : values
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(AngularGradient(colors: colors + [colors[0]], center: .center))
            Circle()
                .fill(.black.opacity(0.22))
            ForEach(0..<min(item.level, 3), id: \.self) { ring in
                Circle()
                    .stroke(.white.opacity(0.18 + Double(ring) * 0.08), lineWidth: 1)
                    .padding(CGFloat(ring) * 4 + 3)
            }
            Text("×\(item.pebbleCount)")
                .font(.system(size: item.pebbleCount >= 1_000 ? 8 : 10, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.65)
                .padding(6)
        }
        .frame(width: 50, height: 50)
        .overlay { Circle().stroke(.white.opacity(0.18), lineWidth: 1) }
        .shadow(color: colors[0].opacity(0.22), radius: 8, y: 4)
        .accessibilityHidden(true)
    }
}

private struct AggregateColorBar: View {
    let mix: [StratumColorFraction]

    var body: some View {
        GeometryReader { proxy in
            if mix.isEmpty {
                Capsule().fill(TsumibenTheme.raised)
            } else {
                HStack(spacing: 1) {
                    ForEach(Array(mix.enumerated()), id: \.offset) { _, fraction in
                        Color(hex: fraction.hex)
                            .frame(width: max(2, proxy.size.width * fraction.fraction))
                    }
                }
            }
        }
        .frame(height: 7)
        .clipShape(Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.08), lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

private struct AggregateStatBadge: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(TsumibenTheme.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(TsumibenTheme.raised.opacity(0.7), in: Capsule())
    }
}

private struct SummaryTile: View {
    let label: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.caption).foregroundStyle(TsumibenTheme.amber)
            Text(value).font(.system(.headline, design: .rounded, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.72)
            Text(label).font(.caption2).foregroundStyle(TsumibenTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(TsumibenTheme.card, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyChartMessage: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(TsumibenTheme.muted)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
    }
}

private struct RareStat: View {
    let kind: PebbleKind
    let count: Int
    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(kind == .gold ? AnyShapeStyle(Color("pebble.gold")) : AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .blue, .purple], center: .center)))
                .frame(width: 28, height: 28)
                .shadow(color: TsumibenTheme.amber.opacity(kind == .gold ? 0.32 : 0.16), radius: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind == .gold ? "金" : "虹").font(.caption2).foregroundStyle(TsumibenTheme.muted)
                Text("×\(count)").font(.system(.headline, design: .rounded, weight: .heavy))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AchievementEditSelection: Identifiable {
    let id: UUID
    let dataEpochID: UUID?
    let subjectID: UUID?
    let subjectName: String
    let subjectColorHex: String
    let kind: AchievementKind
    let note: String
    let achievedAt: Date

    init(_ stone: AchievementStone) {
        id = stone.id
        dataEpochID = stone.dataEpochID
        subjectID = stone.subject?.id
        subjectName = stone.displaySubjectName
        subjectColorHex = stone.displaySubjectColorHex
        kind = stone.kind
        note = stone.note
        achievedAt = stone.achievedAt
    }
}

private struct AchievementEditDraft {
    let subjectID: UUID
    let kind: AchievementKind
    let note: String
    let achievedAt: Date
}

private struct AchievementEditorSheet: View {
    let selection: AchievementEditSelection
    let subjects: [Subject]
    let onSave: (AchievementEditDraft) -> String?
    let onDelete: () -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedSubjectID: UUID?
    @State private var kind: AchievementKind
    @State private var note: String
    @State private var achievedAt: Date
    @State private var errorMessage: String?
    @State private var confirmsDeletion = false
    @State private var isCommitting = false

    init(
        selection: AchievementEditSelection,
        subjects: [Subject],
        onSave: @escaping (AchievementEditDraft) -> String?,
        onDelete: @escaping () -> String?
    ) {
        self.selection = selection
        self.subjects = subjects
        self.onSave = onSave
        self.onDelete = onDelete
        let initialSubjectID = selection.subjectID.flatMap { id in
            subjects.contains(where: { $0.id == id }) ? id : nil
        } ?? subjects.first(where: {
            $0.safeDisplayName == selection.subjectName
                && $0.colorHex.caseInsensitiveCompare(selection.subjectColorHex) == .orderedSame
        })?.id ?? subjects.first?.id
        _selectedSubjectID = State(initialValue: initialSubjectID)
        _kind = State(initialValue: selection.kind)
        _note = State(initialValue: selection.note)
        _achievedAt = State(initialValue: min(selection.achievedAt, .now))
    }

    private var selectedSubject: Subject? {
        subjects.first { $0.id == selectedSubjectID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    editorHeader
                    typeEditor
                    subjectEditor
                    noteEditor
                    dateEditor

                    Label(
                        "記念石は0gです。編集・削除しても、集中時間・質量・通常の粒数は変わりません。",
                        systemImage: "checkmark.shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(TsumibenTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.red.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("achievement.editor.error")
                    }

                    Button {
                        save()
                    } label: {
                        if isCommitting {
                            ProgressView().tint(TsumibenTheme.background)
                        } else {
                            Label("変更を保存", systemImage: "checkmark.circle.fill")
                        }
                    }
                    .buttonStyle(TsumibenPrimaryButtonStyle())
                    .disabled(selectedSubjectID == nil || isCommitting)
                    .accessibilityIdentifier("achievement.editor.save")

                    Button(role: .destructive) {
                        confirmsDeletion = true
                    } label: {
                        Label("この記念石を削除", systemImage: "trash")
                    }
                    .buttonStyle(TsumibenDestructiveButtonStyle())
                    .disabled(isCommitting)
                    .accessibilityIdentifier("achievement.editor.delete")
                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(NightBackground())
            .navigationTitle("成果を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    TsumibenSheetCloseButton(
                        accessibilityIdentifier: "achievement.editor.close"
                    ) {
                        dismiss()
                    }
                    .disabled(isCommitting)
                }
            }
            .alert("この記念石を削除しますか？", isPresented: $confirmsDeletion) {
                Button("削除", role: .destructive) { delete() }
                    .accessibilityIdentifier("achievement.editor.confirm-delete")
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("記録・瓶・共有から非表示になります。質量は変わりません。削除直後は記録画面で元に戻せます。")
            }
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: kind.gemEdgeHex), Color(hex: kind.gemBaseHex)],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 34
                        )
                    )
                Text(kind.shortMark)
                    .font(.system(size: kind == .perfectScore ? 10 : 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)
            .shadow(color: Color(hex: kind.gemGlowHex).opacity(0.4), radius: 10)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                SectionEyebrow(text: "MILESTONE")
                Text(note.isEmpty ? kind.title : note)
                    .font(TsumibenTheme.brand(22))
                    .lineLimit(2)
            }
        }
    }

    private var typeEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            editorLabel("種類")
            Menu {
                ForEach(AchievementKind.allCases) { candidate in
                    Button {
                        kind = candidate
                    } label: {
                        if candidate == kind {
                            Label(candidate.title, systemImage: "checkmark")
                        } else {
                            Text(candidate.title)
                        }
                    }
                }
            } label: {
                editorMenuLabel(
                    title: kind.title,
                    colorHex: kind.gemBaseHex,
                    symbol: kind.systemImage
                )
            }
            .accessibilityLabel("種類、\(kind.title)")
            .accessibilityHint("記念石の種類を変更できます")
            .accessibilityIdentifier("achievement.editor.kind")
        }
    }

    private var subjectEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            editorLabel("テーマ")
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
                editorMenuLabel(
                    title: selectedSubject?.safeDisplayName ?? "テーマを選択",
                    colorHex: selectedSubject?.colorHex ?? Constants.Color.textMute,
                    symbol: "folder.fill"
                )
            }
            .disabled(subjects.isEmpty)
            .accessibilityLabel("テーマ、\(selectedSubject?.safeDisplayName ?? "未選択")")
            .accessibilityHint(
                subjects.isEmpty
                    ? "テーマがないため変更できません"
                    : "成果を結びつけるテーマを変更できます"
            )
            .accessibilityIdentifier("achievement.editor.subject")
        }
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            editorLabel("成果メモ（任意）")
            TextField(kind.notePlaceholder, text: $note)
                .textFieldStyle(.plain)
                .padding(14)
                .background(TsumibenTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: note) { _, value in
                    note = AchievementStone.sanitizedNote(value)
                }
                .accessibilityIdentifier("achievement.editor.note")
        }
    }

    private var dateEditor: some View {
        DatePicker(
            "達成した日",
            selection: $achievedAt,
            in: ...Date.now,
            displayedComponents: .date
        )
        .datePickerStyle(.compact)
        .padding(14)
        .background(TsumibenTheme.raised, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("achievement.editor.date")
    }

    private func editorLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(TsumibenTheme.muted)
    }

    private func editorMenuLabel(
        title: String,
        colorHex: String,
        symbol: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color(hex: colorHex))
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.body, design: .rounded, weight: .bold))
                .foregroundStyle(TsumibenTheme.text)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(TsumibenTheme.muted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(TsumibenTheme.raised, in: RoundedRectangle(cornerRadius: 12))
    }

    private func save() {
        guard !isCommitting, let selectedSubjectID else { return }
        isCommitting = true
        errorMessage = onSave(AchievementEditDraft(
            subjectID: selectedSubjectID,
            kind: kind,
            note: note,
            achievedAt: achievedAt
        ))
        isCommitting = false
        if errorMessage == nil { dismiss() }
    }

    private func delete() {
        guard !isCommitting else { return }
        isCommitting = true
        errorMessage = onDelete()
        isCommitting = false
        if errorMessage == nil { dismiss() }
    }
}

private struct AchievementHistoryRow: View {
    let stone: AchievementStone

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(hex: stone.kind.gemEdgeHex),
                                Color(hex: stone.kind.gemBaseHex)
                            ],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 30
                        )
                    )
                Circle()
                    .stroke(Color(hex: stone.kind.gemEdgeHex), lineWidth: 2)
                Text(stone.kind.shortMark)
                    .font(.system(size: stone.kind == .perfectScore ? 8 : 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            .shadow(color: Color(hex: stone.kind.gemGlowHex).opacity(0.42), radius: 8)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(stone.displayTitle)
                    .font(.subheadline.weight(.semibold))
                Text("\(stone.displaySubjectName)・\(stone.kind.title)")
                    .font(.caption)
                    .foregroundStyle(TsumibenTheme.muted)
            }
            Spacer()
            Text(stone.achievedAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(TsumibenTheme.muted)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(stone.displaySubjectName)、\(stone.kind.title)、\(stone.displayTitle)、\(stone.achievedAt.formatted(date: .long, time: .omitted))"
        )
    }
}

private struct HistoryRow: View {
    let session: StudySession
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(pebbleColor)
                if session.source != .timer {
                    Circle().stroke(.white.opacity(0.72), style: StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
                } else {
                    Circle().fill(RadialGradient(colors: [.white.opacity(0.48), .clear], center: .topLeading, startRadius: 0, endRadius: 15))
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displaySubjectName)
                    .font(.subheadline.weight(.semibold))
                Text(session.endAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(TsumibenTheme.muted)
                if let batch = session.rareRewardCounts.multiDrawSummary {
                    Text(batch)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(TsumibenTheme.muted)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("+\(session.grams)g").font(.system(.subheadline, design: .rounded, weight: .bold))
                Text(session.source == .timer ? "実測" : "自己申告")
                    .font(.caption2)
                    .foregroundStyle(TsumibenTheme.muted)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(historyAccessibilityLabel)
    }

    private var historyAccessibilityLabel: String {
        let source = session.source == .timer ? "実測" : "自己申告"
        let date = session.endAt.formatted(date: .long, time: .shortened)
        let batch = session.rareRewardCounts.multiDrawSummary.map { "、\($0)" } ?? ""
        return "\(session.displaySubjectName)、\(pebbleKindLabel)、\(source)、プラス\(session.grams)グラム\(batch)、\(date)"
    }

    private var pebbleKindLabel: String {
        switch session.pebbleKind {
        case .normal: "通常の粒"
        case .gold: "金の粒"
        case .prism: "虹の粒"
        }
    }

    private var pebbleColor: AnyShapeStyle {
        switch session.pebbleKind {
        case .normal: AnyShapeStyle(Color(hex: session.displaySubjectColorHex))
        case .gold: AnyShapeStyle(Color("pebble.gold"))
        case .prism: AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .blue, .purple], center: .center))
        }
    }
}
