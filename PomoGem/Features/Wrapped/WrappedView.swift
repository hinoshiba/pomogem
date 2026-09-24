import SwiftData
import SwiftUI

struct WrappedMonth: Identifiable, Hashable {
    let start: Date
    var id: Date { start }

    init(containing date: Date, calendar: Calendar = .autoupdatingCurrent) {
        start = calendar.dateInterval(of: .month, for: date)?.start ?? date
    }

    var title: String { StrataMath.monthLabel(for: start) }
}

/// Where 「この月の瓶をカードにする」 opens the card.
enum WrappedShareRoute {
    /// Close Wrapped, then open Home's share sheet. For 記録, which is a
    /// page under Home rather than a sheet.
    case router
    /// Open the card over Wrapped. For months opened from 年月, which sits in
    /// a sheet that Home's share sheet cannot present over.
    case inline
}

struct WrappedView: View {
    let month: WrappedMonth
    let shareRoute: WrappedShareRoute

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppRouter.self) private var router
    @Environment(\.aggregateProjectionPresentation)
    private var aggregateProjectionPresentation
    @Query private var activityResetMarkers: [ActivityResetMarker]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var revealed = false
    @State private var monthSessions: [StudySession] = []
    @State private var pageIsPartial = false
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var presentsInlineShare = false

    init(month: WrappedMonth, shareRoute: WrappedShareRoute = .router) {
        self.month = month
        self.shareRoute = shareRoute
        _activityResetMarkers = Query(BoundedHistoryPolicy.latestResetMarkerDescriptor())
    }

    private var totalMinutes: Int {
        NonnegativeIntPolicy.sum(monthSessions.map(\.seconds)) / 60
    }
    /// Where the month's focus time went, from the records already loaded.
    /// Deliberately no count of active days: that would read like a streak.
    private var themeTimes: [AccumulationTimelineThemeSummary] {
        AccumulationTimelineBreakdownPolicy.themes(
            StudySessionSyncPolicy.canonicalSessions(from: monthSessions)
                .map(AccumulationTimelineBreakdownPolicy.Entry.init(session:))
        )
    }

    private var topSubject: String {
        let groups = Dictionary(grouping: monthSessions, by: \.displaySubjectName)
        return groups.max { lhs, rhs in
            NonnegativeIntPolicy.sum(lhs.value.map(\.grams))
                < NonnegativeIntPolicy.sum(rhs.value.map(\.grams))
        }?.key ?? "—"
    }

    var body: some View {
        ZStack {
            Color(hex: Constants.Color.inkNight).ignoresSafeArea()
            RadialGradient(colors: [PomoGemTheme.amber.opacity(0.12), .clear], center: .top, startRadius: 0, endRadius: 500).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                HStack {
                    PomoGemLogo(compact: true)
                    Spacer()
                    PomoGemSheetCloseButton(
                        accessibilityIdentifier: "wrapped.close"
                    ) {
                        dismiss()
                    }
                }
                .padding(.horizontal, 22)

                Spacer(minLength: 4)
                SectionEyebrow(text: "MONTHLY WRAPPED")
                Text("\(month.title)の瓶")
                    .font(PomoGemTheme.brand(36))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Text("ひと粒ずつの手応えを、ひと月のまとまりでも眺める。")
                    .font(.subheadline)
                    .foregroundStyle(PomoGemTheme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if aggregateProjectionPresentation.isCloudVerificationPending {
                    Label(
                        "iCloudを再集計中です。この端末で確認できた記録だけを表示しています。",
                        systemImage: "arrow.triangle.2.circlepath.icloud"
                    )
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .accessibilityIdentifier("wrapped.cloud-verification-notice")
                } else if pageIsPartial {
                    Label(
                        "この月は記録が多いため、最新\(BoundedHistoryPolicy.periodSessionLimit)件の表示分です。",
                        systemImage: "rectangle.stack.badge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .accessibilityIdentifier("wrapped.partial-notice")
                }

                if let loadError {
                    ContentUnavailableView(
                        "月の瓶を読み込めませんでした",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                    .frame(minHeight: 300)
                } else if isLoading {
                    ProgressView("月の瓶を読み込み中")
                        .frame(width: 230, height: 300)
                } else {
                    WrappedJar(
                        sessions: monthSessions,
                        monthTitle: month.title,
                        revealed: revealed,
                        reduceMotion: reduceMotion,
                        isPartial: pageIsPartial
                            || aggregateProjectionPresentation
                                .isCloudVerificationPending
                    )
                        .frame(width: 230, height: 300)
                }

                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 9) {
                            wrappedStats
                        }
                    } else {
                        HStack(spacing: 9) {
                            wrappedStats
                        }
                    }
                }
                .padding(.horizontal, 18)

                if !isLoading, loadError == nil, !themeTimes.isEmpty {
                    WrappedThemeTimes(themes: themeTimes)
                        .padding(.horizontal, 18)
                }

                Spacer(minLength: 12)
                VStack(spacing: 10) {
                    Button(wrappedShareButtonTitle) {
                        switch shareRoute {
                        case .router:
                            dismiss()
                            Task {
                                try? await Task.sleep(for: .milliseconds(320))
                                router.presentShare(scope: .month(month.start))
                            }
                        case .inline:
                            presentsInlineShare = true
                        }
                    }
                    .buttonStyle(PomoGemPrimaryButtonStyle())
                    .accessibilityIdentifier("wrapped.share")
                    Button("瓶へ戻る") { dismiss() }
                        .buttonStyle(PomoGemSecondaryButtonStyle())
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .sheet(isPresented: $presentsInlineShare) {
            ShareComposerView(scope: .month(month.start))
                .environment(\.dynamicTypeSize, dynamicTypeSize)
        }
        .task(id: loadKey) {
            loadMonth()
            guard loadError == nil else { return }
            if reduceMotion { revealed = true }
            else {
                try? await Task.sleep(for: .milliseconds(240))
                withAnimation(.easeInOut(duration: 1.1)) { revealed = true }
            }
        }
    }

    private var resetSnapshots: [ActivityResetSnapshot] {
        activityResetMarkers.map(\.policySnapshot)
    }

    private var loadKey: String {
        let epoch = ActivityResetPolicy.currentEpochID(from: resetSnapshots)?.uuidString ?? "pre-reset"
        let verification = aggregateProjectionPresentation
            .isCloudVerificationPending ? "cloud-pending" : "verified"
        // Same rule as 記録: an inactive flip (Control Center) is not a
        // reason to re-read the month; returning from the background is.
        return "\(epoch)|\(month.start.timeIntervalSinceReferenceDate)|\(verification)|\(LogHistoryLoadPolicy.isVisible(scenePhase))"
    }

    @MainActor
    private func loadMonth() {
        guard LogHistoryLoadPolicy.isVisible(scenePhase) else { return }
        isLoading = true
        loadError = nil
        let calendar = Calendar.autoupdatingCurrent
        guard let interval = calendar.dateInterval(of: .month, for: month.start) else {
            monthSessions = []
            pageIsPartial = false
            isLoading = false
            loadError = "月の範囲を確認できませんでした。"
            return
        }
        do {
            let epochID = ActivityResetPolicy.currentEpochID(from: resetSnapshots)
            let page = try BoundedHistoryPolicy.resolvedSessionPage(
                context: modelContext,
                epochID: epochID,
                start: interval.start,
                end: interval.end,
                order: .forward,
                logicalLimit: BoundedHistoryPolicy.periodSessionLimit
            )
            pageIsPartial = page.isPartial
            monthSessions = page.sessions
            isLoading = false
        } catch {
            monthSessions = []
            pageIsPartial = false
            isLoading = false
            loadError = "もう一度この画面を開いてください。"
        }
    }

    private func formatMinutes(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes)分" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)時間" : "\(hours)時間\(remainder)分"
    }

    @ViewBuilder
    private var wrappedStats: some View {
        let scoped = pageIsPartial
            || aggregateProjectionPresentation.isCloudVerificationPending
        WrappedStat(title: scoped ? "確認済み時間" : "時間", value: formatMinutes(totalMinutes))
        WrappedStat(title: scoped ? "確認済み粒" : "元の粒", value: "\(monthSessions.count)")
        WrappedStat(title: scoped ? "確認済みトップ" : "いちばん積んだ", value: topSubject)
    }

    private var wrappedShareButtonTitle: String {
        if aggregateProjectionPresentation.isCloudVerificationPending {
            return "確認済み分をカードにする"
        }
        return pageIsPartial ? "表示分をカードにする" : "この月の瓶をカードにする"
    }
}

private struct WrappedJar: View {
    let sessions: [StudySession]
    let monthTitle: String
    let revealed: Bool
    let reduceMotion: Bool
    let isPartial: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(.white.opacity(0.025))
                .overlay { RoundedRectangle(cornerRadius: 36, style: .continuous).stroke(PomoGemTheme.glassEdge, lineWidth: 2) }
            if revealed {
                VStack(spacing: 10) {
                    Text("ひと月のまとまり")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(PomoGemTheme.muted)
                    MonthlyAggregatePebble(sessions: sessions)
                        .frame(width: 112, height: 112)
                    Text("×\(sessions.count)")
                        .font(.system(.caption, design: .rounded, weight: .heavy))
                        .foregroundStyle(PomoGemTheme.muted)
                }
                .padding(.bottom, 64)
                .transition(
                    .scale(scale: 0.42, anchor: .bottom)
                        .combined(with: .opacity)
                )
            } else {
                ForEach(Array(sessions.prefix(32).enumerated()), id: \.element.id) { index, session in
                    Circle()
                        .fill(Color(hex: session.displaySubjectColorHex))
                        .frame(width: 24, height: 24)
                        .offset(
                            x: CGFloat(index % 8 - 4) * 25 + 12,
                            y: -CGFloat(index / 8) * 22 - (reduceMotion ? 12 : 250)
                        )
                }
            }
        }
        .shadow(color: Color(hex: Constants.Color.mathematics).opacity(0.14), radius: 35)
        .accessibilityLabel(
            "\(monthTitle)の瓶。\(isPartial ? "表示分の" : "")\(sessions.count)粒をひとつのまとまりで俯瞰する演出"
        )
    }
}

private struct MonthlyAggregatePebble: View {
    let sessions: [StudySession]

    private var colors: [Color] {
        let mix = StrataMath.colorMix(hexColors: sessions.map(\.displaySubjectColorHex))
        let values = mix.prefix(6).map { Color(hex: $0.hex) }
        return values.isEmpty ? [PomoGemTheme.raised, PomoGemTheme.card] : values
    }

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: colors + [colors[0]], center: .center))
                Circle()
                    .fill(Color(hex: Constants.Color.inkNight).opacity(0.38))

                ForEach(0..<min(max(sessions.count, 1), 18), id: \.self) { index in
                    let column = index % 5
                    let row = index / 5
                    let dotColor = colors[index % colors.count].opacity(0.9)
                    let xOffset = CGFloat(column - 2) * size * 0.145
                        + (row.isMultiple(of: 2) ? 0 : size * 0.07)
                    let yOffset = CGFloat(row - 2) * size * 0.145
                    Circle()
                        .fill(dotColor)
                        .frame(width: size * 0.115, height: size * 0.115)
                        .offset(x: xOffset, y: yOffset)
                }

                Circle()
                    .stroke(.white.opacity(0.34), lineWidth: 1.4)
                Circle()
                    .stroke(PomoGemTheme.amber.opacity(0.28), lineWidth: 1)
                    .padding(8)
                Text("×\(sessions.count)")
                    .font(.system(size: sessions.count >= 100 ? 15 : 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 4, y: 2)
            }
            .frame(width: size, height: size)
            .shadow(color: colors[0].opacity(0.36), radius: 18, y: 8)
        }
        .accessibilityHidden(true)
    }
}

private struct WrappedThemeTimes: View {
    let themes: [AccumulationTimelineThemeSummary]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var shown: [AccumulationTimelineThemeSummary] { Array(themes.prefix(5)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("テーマ別の時間", tableName: "Log", comment: "Wrapped: heading of the month's time per theme")
                .font(.caption.weight(.bold))
                .foregroundStyle(PomoGemTheme.muted)
            ForEach(shown) { theme in
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 3) {
                            themeName(theme)
                            themeTime(theme)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            themeName(theme)
                            Spacer(minLength: 8)
                            themeTime(theme)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(theme.name)、\(DurationPresentation.minutesLabel(seconds: theme.seconds))"
                )
            }
            if themes.count > shown.count {
                Text("ほか\(themes.count - shown.count)テーマ", tableName: "Log", comment: "Wrapped: how many more themes are not listed")
                    .font(.caption2)
                    .foregroundStyle(PomoGemTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wrapped.theme-times")
    }

    private func themeName(_ theme: AccumulationTimelineThemeSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle()
                .fill(Color(hex: theme.colorHex))
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            Text(theme.name)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func themeTime(_ theme: AccumulationTimelineThemeSummary) -> some View {
        Text(DurationPresentation.minutesLabel(seconds: theme.seconds))
            .font(.system(.subheadline, design: .rounded, weight: .heavy))
            .monospacedDigit()
    }
}

private struct WrappedStat: View {
    let title: String
    let value: String
    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(PomoGemTheme.muted)
                .multilineTextAlignment(.center)
            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .heavy))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
