import SwiftData
import SwiftUI

/// A Gregorian month, as its title 「1985年1月」 says. 記録's month list,
/// 年月, Wrapped and the month card all bucket and read months this way, so
/// on an Islamic, Hebrew or Chinese calendar the jar and card cover the month
/// the row was labelled with.
struct WrappedMonth: Identifiable, Hashable {
    let start: Date
    var id: Date { start }

    init(containing date: Date, calendar: Calendar = PomoGemCalendar.gregorian) {
        start = calendar.dateInterval(of: .month, for: date)?.start ?? date
    }

    /// 「2026年9月」, "September 2026". Built from the date on the pinned
    /// Gregorian calendar (DateText), never from the stored `monthLabel`,
    /// which stays Japanese data (Docs/Localization.md).
    var title: String { DateText.yearMonth(start) }
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
        DurationPresentation.creditedFocusMinutes(of: monthSessions)
    }
    private var monthIncludesSelfReportedFocus: Bool {
        monthSessions.contains { $0.effectiveSource.isSelfReported }
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
                // The 36 pt display title stops growing at AX3. Past that, a
                // long English month is wider than an iPhone SE line and
                // breaks inside the word ("Septembe" / "r 2026"); at AX3 it
                // still wraps between words.
                Text("\(month.title)の瓶", tableName: "Log", comment: "Month in Review title; the argument is a month such as 2026年9月")
                    .pomogemSectionTitle(size: 36)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Text("ひと粒ずつの手応えを、ひと月のまとまりでも眺める。", tableName: "Log")
                    .font(.subheadline)
                    .foregroundStyle(PomoGemTheme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if aggregateProjectionPresentation.isCloudVerificationPending {
                    Label(
                        String(localized: "iCloudを再集計中です。この端末で確認できた記録だけを表示しています。", table: "Log"),
                        systemImage: "arrow.triangle.2.circlepath.icloud"
                    )
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .accessibilityIdentifier("wrapped.cloud-verification-notice")
                } else if pageIsPartial {
                    Label(
                        String(
                            localized: "この月は記録が多いため、最新\(BoundedHistoryPolicy.periodSessionLimit)件の表示分です。",
                            table: "Log",
                            comment: "Month in Review: the month has more records than are read; the argument is how many of the newest are shown"
                        ),
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
                        String(localized: "月の瓶を読み込めませんでした", table: "Log", comment: "Month in Review: the month's records could not be read"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                    .frame(minHeight: 300)
                } else if isLoading {
                    ProgressView(String(localized: "月の瓶を読み込み中", table: "Log", comment: "Month in Review: loading the month's records"))
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

                // The card this screen offers defaults to measured focus only.
                // Say that these totals include self-reported time, so the two
                // screens explain each other (walk-std-04).
                if !isLoading, loadError == nil, monthIncludesSelfReportedFocus {
                    Text("時間と粒には、自己申告の記録も含みます。", tableName: "Log")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 28)
                        .accessibilityIdentifier("wrapped.self-reported-note")
                }

                if !isLoading, loadError == nil, !themeTimes.isEmpty {
                    WrappedThemeTimes(themes: themeTimes, isScoped: statsAreScoped)
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
                    Button(dismissButtonTitle) { dismiss() }
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
        let calendar = PomoGemCalendar.gregorian
        guard let interval = calendar.dateInterval(of: .month, for: month.start) else {
            monthSessions = []
            pageIsPartial = false
            isLoading = false
            loadError = String(localized: "月の範囲を確認できませんでした。", table: "Log")
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
            loadError = String(localized: "もう一度この画面を開いてください。", table: "Log")
        }
    }

    private func formatMinutes(_ minutes: Int) -> String {
        DurationPresentation.minutesLabel(minutes)
    }

    /// The numbers cover only the records shown (a capped page, or iCloud
    /// still re-counting), so every figure on the page says 確認済み.
    private var statsAreScoped: Bool {
        pageIsPartial || aggregateProjectionPresentation.isCloudVerificationPending
    }

    /// Opened from a month in 年月, dismissing returns to that month's
    /// sheet, not to a jar. 記録 keeps its existing wording.
    private var dismissButtonTitle: String {
        switch shareRoute {
        case .router:
            String(localized: "瓶へ戻る", table: "Log", comment: "Month in Review button: close and go back to the jar")
        case .inline:
            String(localized: "月の記録へ戻る", table: "Log", comment: "Wrapped opened from a month in 年月: returns to that month's sheet")
        }
    }

    @ViewBuilder
    private var wrappedStats: some View {
        let scoped = statsAreScoped
        WrappedStat(
            title: scoped
                ? String(localized: "確認済み時間", table: "Log", comment: "Month in Review stat: focus time of the records confirmed so far")
                : String(localized: "時間", table: "Log", comment: "Month in Review stat: the month's focus time"),
            value: formatMinutes(totalMinutes)
        )
        WrappedStat(
            title: scoped
                ? String(localized: "確認済み粒", table: "Log", comment: "Month in Review stat: gems among the records confirmed so far")
                : String(localized: "元の粒", table: "Log", comment: "Month in Review stat: how many gems the month's jar was made from"),
            value: "\(monthSessions.count)"
        )
        WrappedStat(
            title: scoped
                ? String(localized: "確認済みトップ", table: "Log", comment: "Month in Review stat: the top theme among the records confirmed so far")
                : String(localized: "いちばん積んだ", table: "Log", comment: "Month in Review stat: the theme with the most mass this month"),
            value: topSubject
        )
    }

    private var wrappedShareButtonTitle: String {
        if aggregateProjectionPresentation.isCloudVerificationPending {
            return String(localized: "確認済み分をカードにする", table: "Log", comment: "Month in Review button while iCloud re-counts: make a share card of the records confirmed so far")
        }
        return pageIsPartial
            ? String(localized: "表示分をカードにする", table: "Log", comment: "Month in Review button when the month is capped: make a share card of the records shown")
            : String(localized: "この月の瓶をカードにする", table: "Log", comment: "Month in Review button: make a share card of this month's jar")
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
                    Text("ひと月のまとまり", tableName: "Log", comment: "Month in Review jar: caption above the month's one combined gem")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(PomoGemTheme.muted)
                        // Wraps inside the jar at large text sizes instead
                        // of ending in 「…」.
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                    MonthlyAggregatePebble(sessions: sessions)
                        .frame(width: 112, height: 112)
                    Text("×\(sessions.count)", tableName: "Log", comment: "How many gems a crystal holds, e.g. ×10")
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
            isPartial
                ? String(
                    localized: "\(monthTitle)の瓶。表示分の\(CountText.gems(sessions.count))をひとつのまとまりで俯瞰する演出",
                    table: "Log",
                    comment: "VoiceOver: the Month in Review animation when only part of the month is shown; the arguments are the month and the gems shown (e.g. 12粒)"
                )
                : String(
                    localized: "\(monthTitle)の瓶。\(CountText.gems(sessions.count))をひとつのまとまりで俯瞰する演出",
                    table: "Log",
                    comment: "VoiceOver: the Month in Review animation; the arguments are the month and its gems (e.g. 12粒)"
                )
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
                Text("×\(sessions.count)", tableName: "Log", comment: "How many gems a crystal holds, e.g. ×10")
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
    /// Built from the same capped records as the stats, so it is titled
    /// the same way they are.
    let isScoped: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var shown: [AccumulationTimelineThemeSummary] { Array(themes.prefix(5)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if isScoped {
                    Text("確認済みのテーマ別の時間", tableName: "Log", comment: "Wrapped: heading of the time per theme when only part of the month is shown or iCloud is re-counting")
                } else {
                    Text("テーマ別の時間", tableName: "Log", comment: "Wrapped: heading of the month's time per theme")
                }
            }
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
                .accessibilityLabel(String(
                    localized: "\(theme.name)、\(DayHistorySheet.spokenFocusTime(grams: theme.grams))",
                    table: "Log",
                    comment: "VoiceOver: two parts read together, e.g. a period and its date range, or a day and its spoken mass"
                ))
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
            HistoryThemeDot(colorHex: theme.colorHex)
            Text(theme.name)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func themeTime(_ theme: AccumulationTimelineThemeSummary) -> some View {
        // From the theme's mass, like the 時間 stat above, so a theme with
        // Pro focuses of 40分30秒 does not read more time than the month
        // (credited time; see DurationPresentation).
        Text(DurationPresentation.focusLabel(grams: theme.grams))
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
