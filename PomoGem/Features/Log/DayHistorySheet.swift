import SwiftData
import SwiftUI

enum HistoryDrillDownAccessibilityID {
    static let daySummary = "history.day.summary"
    static let dayThemes = "history.day.themes"
    static let dayLoading = "history.day.loading"
    static let dayClose = "history.day.close"
    static let dayRow = "history.day.session"
    static let pastHistory = "log.past-history"
    static let pastHistoryFromMonths = "log.past-history.from-months"
    static let pastHistoryClose = "log.past-history.close"

    static func day(_ dayStart: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: dayStart)
        return String(
            format: "history.day.%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

/// Identifies one day to open; the day is the calendar's local midnight.
struct HistoryDaySelection: Identifiable, Hashable {
    let dayStart: Date
    var id: Date { dayStart }
}

/// Answers 「あの日、何をした？」: every record of one day, with its time,
/// theme, mass and how it was recorded. Opened from a day in 記録's chart or
/// from a month in 年月. It reads one bounded day through
/// AccumulationTimelineLoader, off the main thread, never the lifetime list.
struct DayHistorySheet: View {
    let dayStart: Date
    let currentEpochID: UUID?
    var calendar: Calendar = PomoGemCalendar.gregorian

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var detail: AccumulationTimelineDayDetail?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let detail {
                        if !detail.coverage.isLocallyStable {
                            Label(
                                String(localized: "読み込み中にこの端末の記録が変わりました。開き直すと確かめられます。", table: "Log"),
                                systemImage: "arrow.triangle.2.circlepath.icloud"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PomoGemTheme.amber)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        summary(detail)
                        if detail.sessions.isEmpty {
                            PomoGemCard {
                                Text("この日の記録は、この端末にはまだ届いていません。", tableName: "Log")
                                    .font(.subheadline)
                                    .foregroundStyle(PomoGemTheme.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            if detail.themes.count > 1 {
                                HistoryThemeBreakdown(
                                    title: String(localized: "テーマ別", table: "Log", comment: "Heading of the per-theme time breakdown of a day"),
                                    themes: detail.themes,
                                    totalSeconds: detail.totalSeconds
                                )
                                .accessibilityIdentifier(HistoryDrillDownAccessibilityID.dayThemes)
                            }
                            sessionList(detail.sessions)
                        }
                    } else if let loadError {
                        ContentUnavailableView(
                            String(localized: "この日の記録を読み込めませんでした", table: "Log"),
                            systemImage: "exclamationmark.triangle",
                            description: Text(loadError)
                        )
                    } else {
                        ProgressView(String(localized: "この日の記録を読み込み中", table: "Log"))
                            .frame(maxWidth: .infinity, minHeight: 160)
                            .accessibilityIdentifier(HistoryDrillDownAccessibilityID.dayLoading)
                    }

                    Label(
                        String(localized: "この端末に届いている記録です。", table: "Log"),
                        systemImage: "icloud.and.arrow.down"
                    )
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(NightBackground())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PomoGemSheetCloseButton(
                        accessibilityIdentifier: HistoryDrillDownAccessibilityID.dayClose
                    ) {
                        dismiss()
                    }
                }
            }
        }
        .task { await load() }
    }

    private var title: String {
        let isThisYear = calendar.isDate(dayStart, equalTo: .now, toGranularity: .year)
        return PomoGemCalendar.text(
            dayStart,
            isThisYear
                ? .dateTime.month().day().weekday(.abbreviated)
                : .dateTime.year().month().day().weekday(.abbreviated),
            calendar: calendar
        )
    }

    private func summary(_ detail: AccumulationTimelineDayDetail) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                timeMetric(detail)
                countMetrics(detail)
            }
            VStack(spacing: 10) {
                timeMetric(detail)
                HStack(spacing: 10) { countMetrics(detail) }
            }
            VStack(spacing: 10) {
                timeMetric(detail)
                countMetrics(detail)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(HistoryDrillDownAccessibilityID.daySummary)
        .accessibilityLabel(
            String(
                localized: "この日の記録、\(DurationPresentation.minutesLabel(seconds: detail.totalSeconds))、\(detail.sessions.count)粒、\(max(0, detail.totalGrams))グラム",
                table: "Log",
                comment: "VoiceOver summary of a day: focus time, gem count, mass in grams"
            )
        )
    }

    private func timeMetric(_ detail: AccumulationTimelineDayDetail) -> some View {
        HistoryMetricTile(
            title: String(localized: "集中した時間", table: "Log", comment: "Day summary tile: total focus time"),
            value: DurationPresentation.minutesLabel(seconds: detail.totalSeconds)
        )
    }

    @ViewBuilder
    private func countMetrics(_ detail: AccumulationTimelineDayDetail) -> some View {
        HistoryMetricTile(
            title: String(localized: "積んだ粒", table: "Log", comment: "Day summary tile: number of gems"),
            value: String(localized: "\(detail.sessions.count)粒", table: "Log", comment: "Gem count")
        )
        HistoryMetricTile(
            title: String(localized: "質量", table: "Log", comment: "Day summary tile: total mass"),
            value: HistoryMassText.text(detail.totalGrams)
        )
    }

    private func sessionList(_ sessions: [HistorySessionSummary]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("この日の記録", tableName: "Log", comment: "Heading of a day's record list")
                .font(PomoGemTheme.brand(20))
            VStack(spacing: 0) {
                ForEach(sessions) { session in
                    HistorySessionRow(item: session, timeStyle: .timeRange)
                        .accessibilityIdentifier(HistoryDrillDownAccessibilityID.dayRow)
                    if session.id != sessions.last?.id {
                        Divider()
                            .overlay(PomoGemTheme.glassEdge.opacity(0.08))
                            .padding(.leading, 48)
                    }
                }
            }
            .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @MainActor
    private func load() async {
        loadError = nil
        let dayStart = self.dayStart
        let currentEpochID = self.currentEpochID
        let calendar = self.calendar
        do {
            let loaded = try await AccumulationTimelineLoader.read(
                from: modelContext.container
            ) { repository in
                try await repository.dayDetail(
                    dayStart: dayStart,
                    currentEpochID: currentEpochID,
                    calendar: calendar
                )
            }
            try Task.checkCancellation()
            detail = loaded
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// 年月 opened from 記録: every year and month, then every day. It is the
/// way back to history older than 記録's newest thirty records.
struct PastHistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                AccumulationTimelineBrowser()
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 40)
            }
            .background(NightBackground())
            .navigationTitle(Text("過去の記録", tableName: "Log", comment: "Title of 年月 opened from Log"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PomoGemTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PomoGemSheetCloseButton(
                        accessibilityIdentifier: HistoryDrillDownAccessibilityID.pastHistoryClose
                    ) {
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Theme rows with a share of the time. Each row is one VoiceOver element.
struct HistoryThemeBreakdown: View {
    let title: String
    let themes: [AccumulationTimelineThemeSummary]
    let totalSeconds: Int

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(PomoGemTheme.brand(20))
                ForEach(themes) { theme in
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            // Name on its own line; the numbers below it.
                            VStack(alignment: .leading, spacing: 4) {
                                themeName(theme)
                                Text(
                                    "\(DurationPresentation.minutesLabel(seconds: theme.seconds))・\(percentage(theme))%",
                                    tableName: "Log",
                                    comment: "Theme row at large text sizes: time, then share of the period in percent"
                                )
                                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                                    .monospacedDigit()
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                themeName(theme)
                                Spacer(minLength: 8)
                                Text(DurationPresentation.minutesLabel(seconds: theme.seconds))
                                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                                    .monospacedDigit()
                                Text(verbatim: "\(percentage(theme))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(PomoGemTheme.muted)
                                    .frame(minWidth: 36, alignment: .trailing)
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(
                        localized: "\(theme.name)、\(DurationPresentation.minutesLabel(seconds: theme.seconds))、\(percentage(theme))パーセント",
                        table: "Log",
                        comment: "VoiceOver theme row: theme name, time, share in percent"
                    ))
                }
            }
        }
    }

    private func themeName(_ theme: AccumulationTimelineThemeSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HistoryThemeDot(colorHex: theme.colorHex)
            Text(theme.name)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func percentage(_ theme: AccumulationTimelineThemeSummary) -> Int {
        guard totalSeconds > 0 else { return 0 }
        return NonnegativeIntPolicy.clamped(
            (Double(theme.seconds) / Double(totalSeconds) * 100).rounded(),
            maximum: 100
        )
    }
}

/// A theme's color beside its name. A symbol rather than a `Circle`: it has
/// a text baseline, so on the name's first line it sits at the middle of the
/// letters instead of on the baseline like a period, and it grows with
/// Dynamic Type instead of staying a 10-point speck at AX5.
struct HistoryThemeDot: View {
    let colorHex: String

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.subheadline)
            .imageScale(.small)
            .foregroundStyle(Color(hex: colorHex))
            .accessibilityHidden(true)
    }
}

struct HistoryMetricTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PomoGemTheme.muted)
            Text(value)
                .font(.system(.headline, design: .rounded, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(PomoGemTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

enum HistoryMassText {
    static func text(_ grams: Int64) -> String {
        let value = max(0, grams)
        if value >= 1_000_000 {
            return String(format: "%.1ft", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fkg", Double(value) / 1_000)
        }
        return "\(value)g"
    }
}

/// One record in a history list: 記録's newest thirty and a day's records.
struct HistorySessionRow: View {
    enum TimeStyle {
        /// 「9月24日 14:30」: the list spans many days.
        case dateAndTime
        /// 「14:05〜14:30」: every row is on the same day.
        case timeRange
    }

    let item: HistorySessionSummary
    var timeStyle: TimeStyle = .dateAndTime

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilitySizeLayout
            } else {
                standardLayout
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Every piece on its own line so a long theme name and the mass never
    /// squeeze each other into single characters.
    private var accessibilitySizeLayout: some View {
        HStack(alignment: .top, spacing: 12) {
            pebble
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.subjectName)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(timeText)
                    .font(.caption2)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let batch = multiDrawSummary {
                    Text(batch)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(
                    "+\(item.grams)g・\(item.source.displayName)",
                    tableName: "Log",
                    comment: "History row at large text sizes: mass added, then how it was recorded"
                )
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    private var pebble: some View {
        ZStack {
            Circle()
                .fill(pebbleColor)
            if item.source.isSelfReported {
                Circle().stroke(.white.opacity(0.72), style: StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
            } else {
                Circle().fill(RadialGradient(colors: [.white.opacity(0.48), .clear], center: .topLeading, startRadius: 0, endRadius: 15))
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    private var standardLayout: some View {
        HStack(spacing: 12) {
            pebble
            VStack(alignment: .leading, spacing: 2) {
                Text(item.subjectName)
                    .font(.subheadline.weight(.semibold))
                Text(timeText)
                    .font(.caption2)
                    .foregroundStyle(PomoGemTheme.muted)
                if let batch = multiDrawSummary {
                    Text(batch)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PomoGemTheme.muted)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("+\(item.grams)g", tableName: "Log", comment: "Grams one record added to the jar")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                Text(item.source.displayName)
                    .font(.caption2)
                    .foregroundStyle(PomoGemTheme.muted)
            }
        }
    }

    /// The rare 金／虹 batch line; shown at every text size.
    private var multiDrawSummary: String? {
        RareRewardPresentationPolicy.counts(item.rareRewardCounts).multiDrawSummary
    }

    private var timeText: String {
        switch timeStyle {
        case .dateAndTime:
            item.endAt.formatted(date: .abbreviated, time: .shortened)
        case .timeRange:
            String(
                localized: "\(item.startAt.formatted(date: .omitted, time: .shortened))〜\(item.endAt.formatted(date: .omitted, time: .shortened))",
                table: "Log",
                comment: "A record's start and end time, e.g. 13:24〜13:49"
            )
        }
    }

    private var accessibilityText: String {
        let source = item.source.displayName
        let date: String = switch timeStyle {
        case .dateAndTime:
            item.endAt.formatted(date: .long, time: .shortened)
        case .timeRange:
            String(
                localized: "\(item.startAt.formatted(date: .omitted, time: .shortened))から\(item.endAt.formatted(date: .omitted, time: .shortened))まで",
                table: "Log",
                comment: "VoiceOver: a record's start and end time"
            )
        }
        let batch = RareRewardPresentationPolicy
            .counts(item.rareRewardCounts)
            .multiDrawSummary
            .map { "、\($0)" } ?? ""
        return String(
            localized: "\(item.subjectName)、\(pebbleKindLabel)、\(source)、プラス\(item.grams)グラム\(batch)、\(date)",
            table: "Log",
            comment: "VoiceOver history row: theme, gem kind, how recorded, grams added, optional rare summary, date"
        )
    }

    private var pebbleKindLabel: String {
        switch RareRewardPresentationPolicy.kind(item.pebbleKind) {
        case .normal: String(localized: "通常の粒", table: "Log", comment: "VoiceOver: a normal gem")
        case .gold: String(localized: "金の粒", table: "Log", comment: "VoiceOver: a gold gem")
        case .prism: String(localized: "虹の粒", table: "Log", comment: "VoiceOver: a rainbow gem")
        }
    }

    private var pebbleColor: AnyShapeStyle {
        switch RareRewardPresentationPolicy.kind(item.pebbleKind) {
        case .normal: AnyShapeStyle(Color(hex: item.colorHex))
        case .gold: AnyShapeStyle(Color("pebble.gold"))
        case .prism: AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .blue, .purple], center: .center))
        }
    }
}
