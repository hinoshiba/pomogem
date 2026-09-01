import SwiftData
import SwiftUI

enum AccumulationTimelineAccessibilityID {
    static let coverageNotice = "overview.timeline.coverage-notice"
    static let loadingExtent = "overview.timeline.loading-extent"
    static let yearList = "overview.timeline.year-list"
    static let yearLoading = "overview.timeline.year.loading"
    static let yearSummary = "overview.timeline.year.summary"
    static let refresh = "overview.timeline.refresh"
    static let monthLoading = "overview.timeline.month.loading"
    static let monthSummary = "overview.timeline.month.summary"
    static let monthPreview = "overview.timeline.month.preview"
    static let monthClose = "overview.timeline.month.close"

    static func year(_ value: Int) -> String {
        "overview.timeline.year.\(value)"
    }

    static func month(_ start: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month], from: start)
        return String(
            format: "overview.timeline.month.%04d-%02d",
            components.year ?? 0,
            components.month ?? 0
        )
    }
}

/// A bounded, on-demand view over the complete local SwiftData timeline.
/// The lifetime bottle above this browser intentionally remains a compact
/// representative graphic; selecting a year/month is what performs exact
/// UUID-deduplicated local aggregation.
struct AccumulationTimelineBrowser: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query private var activityResetMarkers: [ActivityResetMarker]

    @State private var extent: AccumulationTimelineExtent?
    @State private var years: [AccumulationTimelineYear] = []
    @State private var selectedYear: AccumulationTimelineYear?
    @State private var yearSummary: AccumulationTimelineYearSummary?
    @State private var selectedMonth: AccumulationTimelineMonthSummary?
    @State private var extentError: String?
    @State private var yearError: String?
    @State private var isLoadingExtent = true
    @State private var isLoadingYear = false
    @State private var refreshGeneration = UUID()
    @State private var extentGeneration = UUID()
    @State private var yearGeneration = UUID()

    init() {
        _activityResetMarkers = Query(
            AccumulationTimelineQueryPolicy.latestResetMarkerDescriptor()
        )
    }

    private var calendar: Calendar {
        Calendar.autoupdatingCurrent
    }

    private var currentEpochID: UUID? {
        ActivityResetPolicy.currentEpochID(
            from: activityResetMarkers.map(\.policySnapshot)
        )
    }

    private var extentLoadKey: ExtentLoadKey {
        ExtentLoadKey(
            epochID: currentEpochID,
            refreshGeneration: refreshGeneration,
            isSceneActive: scenePhase == .active,
            timeZoneIdentifier: calendar.timeZone.identifier
        )
    }

    private var yearLoadKey: YearLoadKey {
        YearLoadKey(
            epochID: currentEpochID,
            year: selectedYear?.year,
            refreshGeneration: refreshGeneration,
            isSceneActive: scenePhase == .active,
            timeZoneIdentifier: calendar.timeZone.identifier
        )
    }

    private var monthColumns: [GridItem] {
        [GridItem(
            .adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 230 : 142),
            spacing: 12
        )]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            localCoverageNotice
            extentContents
        }
        .task(id: extentLoadKey) {
            await loadExtent(for: extentLoadKey)
        }
        .task(id: yearLoadKey) {
            await loadSelectedYear(for: yearLoadKey)
        }
        .onChange(of: currentEpochID) { _, _ in
            selectedMonth = nil
            selectedYear = nil
            yearSummary = nil
            years = []
        }
        .sheet(item: $selectedMonth) { month in
            AccumulationTimelineMonthSheet(
                month: month,
                currentEpochID: currentEpochID,
                calendar: calendar
            )
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                SectionEyebrow(text: "TIME ARCHIVE")
                Text("年月をたどる")
                    .font(TsumibenTheme.brand(20))
            }
            Spacer(minLength: 8)
            Button {
                refreshGeneration = UUID()
            } label: {
                Label("再読み込み", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TsumibenBareButtonStyle())
            .foregroundStyle(TsumibenTheme.amber)
            .accessibilityIdentifier(AccumulationTimelineAccessibilityID.refresh)
            .accessibilityLabel("年月を再読み込み")
            .accessibilityHint("この端末に届いた最新の記録で集計し直します")
        }
    }

    private var localCoverageNotice: some View {
        Label(
            "この端末に届いている範囲を表示しています。iCloud同期中は年や合計が増えることがあります。",
            systemImage: "icloud.and.arrow.down"
        )
        .font(.caption)
        .foregroundStyle(TsumibenTheme.text)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TsumibenTheme.raised.opacity(0.64), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccumulationTimelineAccessibilityID.coverageNotice)
    }

    @ViewBuilder
    private var extentContents: some View {
        if isLoadingExtent, extent == nil {
            TsumibenCard {
                ProgressView("この端末の年月を確認中")
                    .frame(maxWidth: .infinity, minHeight: 112)
                    .accessibilityIdentifier(AccumulationTimelineAccessibilityID.loadingExtent)
            }
        } else if let extentError, extent == nil {
            timelineErrorCard(message: extentError)
        } else if years.isEmpty {
            TsumibenCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label("年月の記録はまだありません", systemImage: "calendar.badge.plus")
                        .font(.subheadline.weight(.bold))
                    Text("この端末に最初の一粒が届くと、ここから年と月をたどれます。")
                        .font(.caption)
                        .foregroundStyle(TsumibenTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            yearPicker
            selectedYearContents
        }
    }

    private var yearPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("年を選ぶ")
                .font(.caption.weight(.bold))
                .foregroundStyle(TsumibenTheme.muted)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(years) { year in
                        let isSelected = selectedYear?.id == year.id
                        Button {
                            selectedYear = year
                        } label: {
                            Text(year.title)
                                .font(.system(.subheadline, design: .rounded, weight: .bold))
                                .foregroundStyle(isSelected ? TsumibenTheme.background : TsumibenTheme.text)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 44)
                                .background(
                                    isSelected ? TsumibenTheme.amber : TsumibenTheme.card,
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule().stroke(
                                        isSelected
                                            ? TsumibenTheme.amber
                                            : TsumibenTheme.glassEdge.opacity(0.18),
                                        lineWidth: 1
                                    )
                                }
                        }
                        .buttonStyle(TsumibenRowButtonStyle(cornerRadius: 22))
                        .accessibilityIdentifier(
                            AccumulationTimelineAccessibilityID.year(year.year)
                        )
                        .accessibilityLabel(Text(verbatim: "\(year.year)年"))
                        .accessibilityValue(isSelected ? "選択中" : "")
                        .accessibilityHint("この端末に届いた月別合計を読み込みます")
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier(AccumulationTimelineAccessibilityID.yearList)
        }
    }

    @ViewBuilder
    private var selectedYearContents: some View {
        if isLoadingYear, yearSummary == nil {
            TsumibenCard {
                ProgressView("月ごとの合計を集計中")
                    .frame(maxWidth: .infinity, minHeight: 112)
                    .accessibilityIdentifier(AccumulationTimelineAccessibilityID.yearLoading)
            }
        } else if let yearError, yearSummary == nil {
            timelineErrorCard(message: yearError)
        } else if let yearSummary {
            if !yearSummary.coverage.isLocallyStable {
                changedDuringLoadNotice
            }
            yearSummaryHeader(yearSummary)
            if yearSummary.months.isEmpty {
                TsumibenCard {
                    Text("この端末には、この年の記録がまだ届いていません。")
                        .font(.subheadline)
                        .foregroundStyle(TsumibenTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                LazyVGrid(columns: monthColumns, spacing: 12) {
                    ForEach(yearSummary.months) { month in
                        monthButton(month)
                    }
                }
            }
        }
    }

    private var changedDuringLoadNotice: some View {
        Label(
            "読み込み中にこの端末の記録が変わりました。表示値は再確認できます。",
            systemImage: "arrow.triangle.2.circlepath.icloud"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(TsumibenTheme.amber)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("overview.timeline.changed-during-load")
    }

    private func yearSummaryHeader(
        _ summary: AccumulationTimelineYearSummary
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                timelineMetric(title: "\(summary.year.year)年", value: "\(summary.exactLocalCount.formatted())粒")
                timelineMetric(title: "この端末の質量", value: formattedMass(summary.exactLocalGrams))
            }
            VStack(spacing: 10) {
                timelineMetric(title: "\(summary.year.year)年", value: "\(summary.exactLocalCount.formatted())粒")
                timelineMetric(title: "この端末の質量", value: formattedMass(summary.exactLocalGrams))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(AccumulationTimelineAccessibilityID.yearSummary)
        .accessibilityLabel(
            Text(
                verbatim: "この端末に届いている\(summary.year.year)年の記録、\(summary.exactLocalCount)粒、\(spokenMass(summary.exactLocalGrams))"
            )
        )
    }

    private func monthButton(
        _ month: AccumulationTimelineMonthSummary
    ) -> some View {
        Button {
            selectedMonth = month
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Image(systemName: "shippingbox.and.arrow.backward.fill")
                        .foregroundStyle(TsumibenTheme.amber)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(TsumibenTheme.muted)
                }
                Text(month.monthStart.formatted(.dateTime.month(.wide)))
                    .font(TsumibenTheme.brand(18))
                    .foregroundStyle(TsumibenTheme.text)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(month.exactLocalCount.formatted())粒")
                    Text(formattedMass(month.exactLocalGrams))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(TsumibenTheme.muted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
            .background(TsumibenTheme.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(TsumibenTheme.glassEdge.opacity(0.14), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(TsumibenBareButtonStyle())
        .accessibilityIdentifier(
            AccumulationTimelineAccessibilityID.month(month.monthStart, calendar: calendar)
        )
        .accessibilityLabel(
            "\(month.monthStart.formatted(.dateTime.year().month()))、この端末に届いている\(month.exactLocalCount)粒、\(spokenMass(month.exactLocalGrams))"
        )
        .accessibilityHint("最新96粒までの代表瓶を開きます")
    }

    private func timelineMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(TsumibenTheme.muted)
            Text(value)
                .font(.system(.headline, design: .rounded, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(TsumibenTheme.text)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TsumibenTheme.raised.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
    }

    private func timelineErrorCard(message: String) -> some View {
        TsumibenCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("年月を読み込めませんでした", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(TsumibenTheme.amber)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(TsumibenTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @MainActor
    private func loadExtent(for key: ExtentLoadKey) async {
        guard key.isSceneActive else { return }
        let generation = UUID()
        extentGeneration = generation
        isLoadingExtent = true
        extentError = nil
        let repository = AccumulationTimelineRepository(
            modelContainer: modelContext.container
        )
        do {
            let loadedExtent = try await repository.extent(
                currentEpochID: key.epochID
            )
            let loadedYears = try AccumulationTimelineYearPolicy.years(
                in: loadedExtent,
                calendar: calendar
            )
            try Task.checkCancellation()
            guard generation == extentGeneration,
                  key == extentLoadKey
            else { return }

            extent = loadedExtent
            years = loadedYears
            if let priorYear = selectedYear?.year,
               let retained = loadedYears.first(where: { $0.year == priorYear }) {
                selectedYear = retained
            } else {
                selectedYear = loadedYears.first
            }
            isLoadingExtent = false
        } catch is CancellationError {
            return
        } catch {
            guard generation == extentGeneration,
                  key == extentLoadKey
            else { return }
            extentError = error.localizedDescription
            isLoadingExtent = false
        }
    }

    @MainActor
    private func loadSelectedYear(for key: YearLoadKey) async {
        guard key.isSceneActive,
              let selectedYear,
              key.year == selectedYear.year
        else { return }
        let generation = UUID()
        yearGeneration = generation
        isLoadingYear = true
        yearError = nil
        yearSummary = nil
        let repository = AccumulationTimelineRepository(
            modelContainer: modelContext.container
        )
        do {
            let loaded = try await repository.yearSummary(
                for: selectedYear,
                currentEpochID: key.epochID,
                calendar: calendar
            )
            try Task.checkCancellation()
            guard generation == yearGeneration,
                  key == yearLoadKey
            else { return }
            yearSummary = loaded
            isLoadingYear = false
        } catch is CancellationError {
            return
        } catch {
            guard generation == yearGeneration,
                  key == yearLoadKey
            else { return }
            yearError = error.localizedDescription
            isLoadingYear = false
        }
    }

    private func formattedMass(_ grams: Int64) -> String {
        if grams >= 1_000_000 {
            return String(format: "%.1ft", Double(grams) / 1_000_000)
        }
        if grams >= 1_000 {
            return String(format: "%.1fkg", Double(grams) / 1_000)
        }
        return "\(grams)g"
    }

    private func spokenMass(_ grams: Int64) -> String {
        "\(max(0, grams).formatted())グラム"
    }

    private struct ExtentLoadKey: Hashable {
        let epochID: UUID?
        let refreshGeneration: UUID
        let isSceneActive: Bool
        let timeZoneIdentifier: String
    }

    private struct YearLoadKey: Hashable {
        let epochID: UUID?
        let year: Int?
        let refreshGeneration: UUID
        let isSceneActive: Bool
        let timeZoneIdentifier: String
    }
}

private struct AccumulationTimelineMonthSheet: View {
    let month: AccumulationTimelineMonthSummary
    let currentEpochID: UUID?
    let calendar: Calendar

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var detail: AccumulationTimelineMonthDetail?
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var refreshGeneration = UUID()
    @State private var loadGeneration = UUID()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(
                        "この端末に届いている範囲です。iCloud同期中は合計が増えることがあります。",
                        systemImage: "icloud.and.arrow.down"
                    )
                    .font(.caption)
                    .foregroundStyle(TsumibenTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TsumibenTheme.card, in: RoundedRectangle(cornerRadius: 14))

                    exactSummary

                    if isLoading, detail == nil {
                        ProgressView("最新の代表粒を読み込み中")
                            .frame(maxWidth: .infinity, minHeight: 210)
                            .accessibilityIdentifier(
                                AccumulationTimelineAccessibilityID.monthLoading
                            )
                    } else if let loadError, detail == nil {
                        ContentUnavailableView(
                            "代表瓶を読み込めませんでした",
                            systemImage: "exclamationmark.triangle",
                            description: Text(loadError)
                        )
                    } else if let detail {
                        if !detail.coverage.isLocallyStable {
                            Label(
                                "読み込み中にこの端末の記録が変わりました。再読み込みで確かめられます。",
                                systemImage: "arrow.triangle.2.circlepath.icloud"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(TsumibenTheme.amber)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        representativeBottle(detail)
                    }
                }
                .padding(20)
            }
            .background(NightBackground())
            .navigationTitle(month.monthStart.formatted(.dateTime.year().month(.wide)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        refreshGeneration = UUID()
                    } label: {
                        Label("再読み込み", systemImage: "arrow.clockwise")
                    }
                    .accessibilityLabel("この月を再読み込み")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    TsumibenSheetCloseButton(
                        accessibilityIdentifier: AccumulationTimelineAccessibilityID.monthClose
                    ) {
                        dismiss()
                    }
                }
            }
        }
        .task(id: refreshGeneration) {
            await loadMonth()
        }
    }

    private var displayedSummary: AccumulationTimelineMonthSummary {
        detail?.summary ?? month
    }

    private var exactSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { exactMetrics }
            VStack(spacing: 10) { exactMetrics }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(AccumulationTimelineAccessibilityID.monthSummary)
        .accessibilityLabel(
            "この端末に届いている\(displayedSummary.exactLocalCount)粒、\(spokenMass(displayedSummary.exactLocalGrams))"
        )
    }

    @ViewBuilder
    private var exactMetrics: some View {
        monthMetric(title: "この端末の粒", value: "\(displayedSummary.exactLocalCount.formatted())粒")
        monthMetric(title: "この端末の質量", value: formattedMass(displayedSummary.exactLocalGrams))
    }

    private func monthMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(TsumibenTheme.muted)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(TsumibenTheme.text)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TsumibenTheme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func representativeBottle(
        _ detail: AccumulationTimelineMonthDetail
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                Text("この月の代表瓶")
                    .font(TsumibenTheme.brand(20))
                Text(representativeDisclosure(detail))
                    .font(.caption)
                    .foregroundStyle(TsumibenTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AccumulationTimelineRepresentativeBottle(
                records: detail.representativeRecords
            )
            .frame(height: 260)
            .accessibilityIdentifier(AccumulationTimelineAccessibilityID.monthPreview)
            .accessibilityLabel(
                "最新\(detail.representativeRecords.count)粒の代表瓶"
            )
        }
        .padding(16)
        .background(TsumibenTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func representativeDisclosure(
        _ detail: AccumulationTimelineMonthDetail
    ) -> String {
        if detail.previewIsRepresentative {
            return "全\(detail.summary.exactLocalCount.formatted())粒・\(formattedMass(detail.summary.exactLocalGrams))。瓶は最新\(detail.representativeRecords.count.formatted())粒の代表表示です。"
        }
        return "この端末に届いている全\(detail.summary.exactLocalCount.formatted())粒・\(formattedMass(detail.summary.exactLocalGrams))を表示しています。"
    }

    @MainActor
    private func loadMonth() async {
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        loadError = nil
        let repository = AccumulationTimelineRepository(
            modelContainer: modelContext.container
        )
        do {
            let loaded = try await repository.monthDetail(
                monthStart: month.monthStart,
                currentEpochID: currentEpochID,
                calendar: calendar
            )
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            detail = loaded
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    private func formattedMass(_ grams: Int64) -> String {
        if grams >= 1_000_000 {
            return String(format: "%.1ft", Double(grams) / 1_000_000)
        }
        if grams >= 1_000 {
            return String(format: "%.1fkg", Double(grams) / 1_000)
        }
        return "\(grams)g"
    }

    private func spokenMass(_ grams: Int64) -> String {
        "\(max(0, grams).formatted())グラム"
    }
}

/// Draws all bounded preview records (up to 96), while keeping the exact
/// count in text. Geometry is deterministic so relaunches do not reshuffle a
/// person's recent effort.
private struct AccumulationTimelineRepresentativeBottle: View {
    let records: [AccumulationRecord]

    var body: some View {
        Canvas { context, size in
            let neckWidth = size.width * 0.34
            let bodyRect = CGRect(
                x: size.width * 0.08,
                y: size.height * 0.18,
                width: size.width * 0.84,
                height: size.height * 0.78
            )
            let neckRect = CGRect(
                x: (size.width - neckWidth) / 2,
                y: size.height * 0.035,
                width: neckWidth,
                height: size.height * 0.22
            )
            let neck = RoundedRectangle(cornerRadius: 12, style: .continuous)
                .path(in: neckRect)
            let bottle = RoundedRectangle(cornerRadius: 38, style: .continuous)
                .path(in: bodyRect)
            context.fill(neck, with: .color(TsumibenTheme.raised.opacity(0.30)))
            context.fill(bottle, with: .color(TsumibenTheme.raised.opacity(0.34)))
            context.stroke(neck, with: .color(TsumibenTheme.glassEdge.opacity(0.48)), lineWidth: 1.5)
            context.stroke(bottle, with: .color(TsumibenTheme.glassEdge.opacity(0.58)), lineWidth: 1.8)

            let visible = Array(records.suffix(
                AccumulationTimelineQueryPolicy.representativeRecordLimit
            ))
            let columns = 12
            let horizontalInset: CGFloat = 18
            let usableWidth = max(1, bodyRect.width - horizontalInset * 2)
            let spacing = usableWidth / CGFloat(columns - 1)
            let diameter = min(13, max(6, spacing * 0.72))
            for (index, record) in visible.enumerated() {
                let column = index % columns
                let row = index / columns
                let stagger = row.isMultiple(of: 2) ? CGFloat.zero : spacing * 0.26
                let x = min(
                    bodyRect.maxX - horizontalInset,
                    bodyRect.minX + horizontalInset + CGFloat(column) * spacing + stagger
                )
                let y = bodyRect.maxY - 18 - CGFloat(row) * diameter * 0.82
                let pebbleRect = CGRect(
                    x: x - diameter / 2,
                    y: y - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                context.fill(
                    Path(ellipseIn: pebbleRect),
                    with: .color(Color(hex: record.colorHex).opacity(0.94))
                )
                context.stroke(
                    Path(ellipseIn: pebbleRect),
                    with: .color(.white.opacity(0.20)),
                    lineWidth: 0.5
                )
            }
        }
    }
}
