import SwiftUI

/// An explicitly simulated, non-persistent time-travel view of a study plan.
/// All state in this screen is ordinary SwiftUI `@State`; leaving the sheet
/// discards it. No model context or cloud-backed value crosses this boundary:
/// the only input is today's jar mass, a plain value Home already shows.
struct AccumulationPlanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Where the plan starts: the person's jar today (home-07), so the answer
    /// is "where my jar will be", not "what a stranger would collect".
    private let start: AccumulationPlanStart

    @State private var years = AccumulationPlanProjection.Plan.suggested.years
    @State private var sessionsPerWeek = AccumulationPlanProjection.Plan.suggested.sessionsPerWeek
    @State private var minutesPerSession = AccumulationPlanProjection.Plan.suggested.minutesPerSession
    @State private var previewMonth = Double(
        AccumulationPlanProjection.Plan.suggested.years * 12
    )
    @State private var previewScene = JarScene()
    @State private var sceneRefreshTask: Task<Void, Never>?

    /// The free timer presets the person can actually run (25/45/60/90).
    private let minuteChoices = PomodoroDuration.freePresets.compactMap(\.minutes)
    private let productSessionsPerWeekRange = 1 ... 21
    /// jar-05: the preview jar is rebuilt once the slider or a stepper has
    /// rested this long, not on every one-month step of a drag.
    private static let sceneRefreshDelay: Duration = .milliseconds(120)

    init(start: AccumulationPlanStart = .empty) {
        self.start = start
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    simulationNotice
                    planControls
                    timeTravelCard
                    massMilestoneCard
                    projectionVisual
                    totalsGrid
                    calculationNote
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 36)
            }
            .background(NightBackground())
            .navigationTitle(Text("積み上がり計画", tableName: "Planning", comment: "Title of the plan screen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("積み上がり計画", tableName: "Planning", comment: "Title of the plan screen")
                            .font(.headline)
                        Label(String(localized: "予測・保存なし", table: "Planning", comment: "Badge under the plan screen's title: a projection that is never saved"), systemImage: "icloud.slash.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color(hex: "#5DE0BD"))
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PomoGemSheetCloseButton(
                        accessibilityIdentifier: "planning.accumulation.close"
                    ) {
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("planning.accumulation.view")
        .onAppear(perform: refreshScene)
        .onDisappear { sceneRefreshTask?.cancel() }
        .onChange(of: previewMonth) { _, _ in scheduleSceneRefresh() }
        .onChange(of: sessionsPerWeek) { _, _ in scheduleSceneRefresh() }
        .onChange(of: minutesPerSession) { _, _ in scheduleSceneRefresh() }
        .onChange(of: years) { _, newValue in
            previewMonth = Double(newValue * 12)
        }
    }

    private var plan: AccumulationPlanProjection.Plan {
        AccumulationPlanProjection.Plan(
            years: years,
            sessionsPerWeek: sessionsPerWeek,
            minutesPerSession: minutesPerSession
        )
    }

    private var projection: AccumulationPlanProjection {
        AccumulationPlanProjection.make(
            plan: plan,
            elapsedMonths: Int(previewMonth.rounded())
        )
    }

    /// Today's jar plus what the plan adds by the previewed month. The bottle
    /// cycle and the long-term milestones continue from the person's real jar.
    private var jarGrams: Int {
        start.jarGrams(adding: projection.grams)
    }

    /// Where the jar stands in its bottle cycle and long-term milestones.
    /// Nil while Home re-counts today's jar: a position computed from the
    /// plan alone would read as an empty jar (「最初の2.50kgへ」, 0段階).
    private var jarPosition: JarAccumulationPresenceState? {
        guard start.certainty != .recounting else { return nil }
        return JarAccumulationPresencePresentation.state(totalGrams: jarGrams)
    }

    private var simulationNotice: some View {
        PomoGemCard {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.title2)
                    .foregroundStyle(Color(hex: "#5DE0BD"))
                    .frame(width: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    SectionEyebrow(text: "SIMULATED · READ ONLY")
                    Text("これは予測です", tableName: "Planning")
                        .pomogemSectionTitle(size: 21)
                    Text("ここで動かす瓶や数値は、実際の学習記録・保存領域・ウィジェットには保存されません。画面を閉じると入力も消えます。", tableName: "Planning")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("planning.accumulation.disclosure")
    }

    private var planControls: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionEyebrow(text: "YOUR ROUTINE")
                    Text("続け方を選ぶ", tableName: "Planning", comment: "Plan section title: pick the routine to project")
                        .pomogemSectionTitle(size: 21)
                    Text("1回の集中を完走する想定で、週あたりの回数から試算します。", tableName: "Planning")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                }

                controlRow(
                    title: String(localized: "計画期間", table: "Planning", comment: "Plan control: how many years the plan runs"),
                    value: Self.yearCount(years),
                    symbol: "calendar"
                ) {
                    Stepper(
                        String(localized: "計画期間 \(years)年", table: "Planning", comment: "VoiceOver: the plan-length stepper; the argument is a number of years"),
                        value: $years,
                        in: AccumulationPlanProjection.Plan.yearRange
                    )
                    .labelsHidden()
                }

                Divider().overlay(PomoGemTheme.glassEdge.opacity(0.12))

                controlRow(
                    title: String(localized: "週の集中回数", table: "Planning", comment: "Plan control: focus sessions per week"),
                    value: String(localized: "週\(sessionsPerWeek)回", table: "Planning", comment: "Plan value: focus sessions per week"),
                    symbol: "repeat"
                ) {
                    Stepper(
                        String(localized: "週の集中回数 \(sessionsPerWeek)回", table: "Planning", comment: "VoiceOver: the sessions-per-week stepper; the argument is the count"),
                        value: $sessionsPerWeek,
                        in: productSessionsPerWeekRange
                    )
                    .labelsHidden()
                }

                Divider().overlay(PomoGemTheme.glassEdge.opacity(0.12))

                VStack(alignment: .leading, spacing: 9) {
                    Label(String(localized: "1回の集中時間", table: "Planning", comment: "Plan control: the length of one focus session"), systemImage: "timer")
                        .font(.subheadline.weight(.semibold))
                    Picker(String(localized: "1回の集中時間", table: "Planning", comment: "Plan control: the length of one focus session"), selection: $minutesPerSession) {
                        ForEach(minuteChoices, id: \.self) { minutes in
                            // A timer length: 「90分」, never 「1時間30分」.
                            Text(DurationText.short(seconds: minutes * 60, units: .minutesSeconds)).tag(minutes)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("planning.accumulation.minutes")
                }
            }
        }
        .accessibilityIdentifier("planning.accumulation.controls")
    }

    private func controlRow<Control: View>(
        title: String,
        value: String,
        symbol: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(.subheadline, design: .rounded, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(PomoGemTheme.amber)
                control()
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(title, systemImage: symbol)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(value)
                        .font(.system(.subheadline, design: .rounded, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(PomoGemTheme.amber)
                }
                control()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var timeTravelCard: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        SectionEyebrow(text: "TIME TRAVEL PREVIEW")
                        Text(previewPeriodTitle)
                            .pomogemSectionTitle(size: 23)
                    }
                    Spacer()
                    Text("予測", tableName: "Planning", comment: "Small badge beside the previewed month: this is a projection")
                        .font(.caption2.weight(.black))
                        .tracking(0.8)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .foregroundStyle(Color(hex: "#5DE0BD"))
                        .background(
                            Color(hex: "#5DE0BD").opacity(0.13),
                            in: Capsule()
                        )
                }

                Slider(
                    value: $previewMonth,
                    in: 0 ... Double(years * 12),
                    step: 1
                )
                .tint(PomoGemTheme.amber)
                .accessibilityLabel(Text("計画の経過期間", tableName: "Planning", comment: "VoiceOver: the slider that picks how far into the plan to preview"))
                .accessibilityValue(previewPeriodTitle)
                .accessibilityIdentifier("planning.accumulation.timeline")

                HStack {
                    Text("今日", tableName: "Planning", comment: "The start of the plan's timeline: today")
                    Spacer()
                    Text(Self.laterTitle(years: years, months: 0))
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PomoGemTheme.muted)

                Text("スライダーを動かすと、その時点までに積み上がる想定の瓶・時間・質量へ巻き戻せます。", tableName: "Planning")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var massMilestoneCard: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 13) {
                    ZStack {
                        Circle()
                            .stroke(PomoGemTheme.glassEdge.opacity(0.18), lineWidth: 7)
                        Circle()
                            .trim(from: 0, to: jarPosition?.cycleProgressFraction ?? 0)
                            .stroke(
                                PomoGemTheme.amber,
                                style: StrokeStyle(lineWidth: 7, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "hourglass.bottomhalf.filled")
                            .foregroundStyle(PomoGemTheme.amber)
                    }
                    .frame(width: 58, height: 58)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        // English in Japanese too; English says "jar", never "bottle".
                        SectionEyebrow(text: String(localized: "BOTTLE CYCLE", table: "Planning", comment: "Eyebrow above the jar-cycle title (shown uppercased). en: 'Jar Cycle', never 'bottle'."))
                        Text(bottleCycleTitle)
                            .pomogemSectionTitle()
                        Text(bottleCycleStatus)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                }

                if let jarPosition {
                    ProgressView(value: jarPosition.cycleProgressFraction)
                        .tint(PomoGemTheme.amber)
                        .accessibilityLabel(Text("その時点の瓶が満ちるまで", tableName: "Planning", comment: "VoiceOver: progress of the bottle cycle at the previewed month"))
                        .accessibilityValue(Self.percentValue(jarPosition.cycleProgressFraction))
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("瓶の合計", tableName: "Planning", comment: "Label: today's jar mass plus the mass the plan adds")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                        Spacer()
                        Text(jarTotalValue)
                            .font(.system(.title2, design: .rounded, weight: .heavy))
                            .monospacedDigit()
                            .foregroundStyle(PomoGemTheme.amber)
                    }
                    .accessibilityElement(children: .combine)
                    if let startBreakdown {
                        Text(startBreakdown)
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider().overlay(PomoGemTheme.glassEdge.opacity(0.12))

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(String(localized: "長期の時間の核", table: "Planning", comment: "Plan: the long-term time core milestones (2.5 kg, 25 kg, 250 kg…)"), systemImage: "sparkles")
                            .font(.caption.weight(.bold))
                        Spacer()
                        Text(majorMilestoneStatus)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color(hex: "#5DE0BD"))
                    }

                    if let jarPosition {
                        ProgressView(value: jarPosition.majorMilestoneProgressFraction)
                            .tint(Color(hex: "#5DE0BD"))
                            .accessibilityLabel(majorMilestoneAccessibilityLabel(jarPosition))
                            .accessibilityValue(Self.percentValue(jarPosition.majorMilestoneProgressFraction))
                    }
                }

                Text("瓶は2.50kg（集中250分相当）ごとに必ず満ち、満杯の光を見届けてから次の1杯へ進みます。累計は消えず、2.50kg → 25kg → 250kg…の長期段階として別に残ります。回数ではなく、集中1分＝\(Constants.Mass.gramsPerMinute)gで両方が進みます。", tableName: "Planning", comment: "Plan: how the jar fills; the argument is grams per minute")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Label(
                    String(localized: "60分 = 600g = 25分×2 + 10分 = 10分×6", table: "Planning", comment: "Formula: 60 minutes are 600 g however they are split"),
                    systemImage: "equal.circle.fill"
                )
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color(hex: "#5DE0BD"))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Color(hex: "#5DE0BD").opacity(0.10),
                    in: Capsule()
                )
                .accessibilityLabel(Text("同じ60分なら、分け方にかかわらず600グラムです", tableName: "Planning", comment: "VoiceOver reading of the 60分 = 600g formula"))
            }
        }
        .accessibilityIdentifier("planning.accumulation.mass-milestone")
    }

    private var projectionVisual: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        SectionEyebrow(text: "SIMULATED ACCUMULATION")
                        Text("この計画で積む分", tableName: "Planning", comment: "Title of the card that previews only what the plan adds")
                            .pomogemSectionTitle(size: 21)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formattedMass(projection.grams))
                            .font(.system(.headline, design: .rounded, weight: .heavy))
                            .foregroundStyle(PomoGemTheme.amber)
                        Text(DurationPresentation.minutesLabel(projection.focusMinutes))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                }

                Group {
                    // At month zero the plan has added nothing yet. The empty
                    // constellation's own core label would sit under this
                    // text, so the text replaces it instead of covering it.
                    if projection.completionCount == 0 {
                        ContentUnavailableView {
                            Label {
                                Text("今日", tableName: "Planning", comment: "The start of the plan's timeline: today")
                            } icon: {
                                Image(systemName: "circle.dotted")
                            }
                        } description: {
                            Text("スライダーを右へ動かすと、この計画で積む分が現れます", tableName: "Planning")
                        }
                    } else {
                        EffortConstellationView(
                            nodes: projection.constellationNodes,
                            totalGrams: projection.grams,
                            totalPebbleCount: projection.completionCount
                        )
                    }
                }
                .frame(height: 245)

                JarSpriteView(
                    scene: previewScene,
                    totalGrams: projection.grams,
                    pebbleCount: projection.studyBodyCount,
                    achievementCount: 0,
                    aggregateCount: projection.aggregateBodyCount,
                    representedPebbleCount: projection.completionCount,
                    accentHex: Constants.Color.auroraWarm
                )
                .frame(height: 260)
                .accessibilityIdentifier("planning.accumulation.jar")

                Text("星図と瓶は、今日からこの計画で積む分の見え方の予測です。今日までの瓶は含めません。粒と結晶は予定した完走リズムを、上の時間・質量は集中時間の累計を表します。記念石・実際の休止日は含めません。", tableName: "Planning")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var totalsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(previewPeriodTitle)の予測", tableName: "Planning", comment: "Plan results title; the argument is 今日 or a time from now such as 3年後")
                .pomogemSectionTitle()
            // An eager Grid, not a LazyVGrid: `.combine` below does not
            // reach into a lazy container, so VoiceOver heard only the title
            // (and, before home-02, the test string) instead of the metrics.
            // At accessibility sizes one metric per row, so a value such as
            // 「3.68t以上」 or 「6,087時間30分」 wraps instead of losing its end.
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                if dynamicTypeSize.isAccessibilitySize {
                    GridRow { focusMetric }
                    GridRow { addedMassMetric }
                    GridRow { rhythmMetric }
                    GridRow { jarTotalMetric }
                } else {
                    GridRow {
                        focusMetric
                        addedMassMetric
                    }
                    GridRow {
                        rhythmMetric
                        jarTotalMetric
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("planning.accumulation.result")
        .modifier(PlanResultUITestValue(projection: projection, start: start))
    }

    private var calculationNote: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 8) {
                Label(String(localized: "試算の前提", table: "Planning", comment: "Plan card title: the assumptions behind the numbers"), systemImage: "info.circle.fill")
                    .font(.subheadline.weight(.bold))
                Text("1年を平均365.25日として週回数を換算し、1回の完走を1粒、集中1分を\(Constants.Mass.gramsPerMinute)gとして計算します。2.50kgごとの瓶の満杯、長期の質量段階、瓶の光は実画面と同じ計算です。10個ずつまとめるため、長期間でも描画する可動体は\(Constants.Jar.maxPhysicsBodies)体以内です。", tableName: "Planning", comment: "Plan: calculation assumptions; the arguments are grams per minute and the physics body limit")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Label(String(localized: "保存領域・実績への反映はありません", table: "Planning"), systemImage: "externaldrive.badge.xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(hex: "#5DE0BD"))
            }
        }
    }

    private var focusMetric: some View {
        metric(
            title: String(localized: "集中時間", table: "Planning", comment: "Plan results: focus time the plan adds"),
            value: DurationPresentation.minutesLabel(projection.focusMinutes)
        )
    }

    private var addedMassMetric: some View {
        metric(
            title: String(localized: "増える質量", table: "Planning", comment: "Mass the plan adds, in the results grid"),
            value: formattedMass(projection.grams)
        )
    }

    private var rhythmMetric: some View {
        metric(
            title: String(localized: "予定リズム", table: "Planning", comment: "Plan results: how many sessions the plan completes"),
            value: String(localized: "\(projection.completionCount)回", table: "Planning", comment: "Plan results: number of completed focus sessions")
        )
    }

    private var jarTotalMetric: some View {
        metric(
            title: String(localized: "瓶の合計", table: "Planning", comment: "Label: today's jar mass plus the mass the plan adds"),
            value: jarTotalValue
        )
    }

    private func metric(title: String, value: String) -> some View {
        let wraps = dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(PomoGemTheme.muted)
            Text(value)
                .font(.system(.headline, design: .rounded, weight: .heavy))
                .monospacedDigit()
                .minimumScaleFactor(0.72)
                .lineLimit(wraps ? nil : 1)
                .fixedSize(horizontal: false, vertical: wraps)
        }
        .padding(.vertical, wraps ? 10 : 0)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .padding(.horizontal, 13)
        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 15))
    }

    private var previewPeriodTitle: String {
        let months = Int(previewMonth.rounded())
        guard months > 0 else {
            return String(localized: "今日", table: "Planning", comment: "The start of the plan's timeline: today")
        }
        return Self.laterTitle(years: months / 12, months: months % 12)
    }

    /// 「3か月後」「2年後」「1年6か月後」: a time from today. Counts, not
    /// calendar years, so the Int is interpolated (English plurals).
    static func laterTitle(years: Int, months: Int) -> String {
        if years == 0 {
            return String(localized: "\(months)か月後", table: "Planning", comment: "A time from today in months")
        }
        if months == 0 {
            return String(localized: "\(years)年後", table: "Planning", comment: "A time from today in years")
        }
        // Two counts, each its own plural phrase: 「1年」「6か月」.
        return String(
            localized: "\(yearCount(years))\(monthCount(months))後",
            table: "Planning",
            comment: "A time from today: a number of years (1年), then of months (6か月)"
        )
    }

    /// 「3年」, "3 years": a count of years, not a calendar year.
    static func yearCount(_ years: Int) -> String {
        String(localized: "\(years)年", table: "Planning", comment: "Plan length in years (a count, not a calendar year)")
    }

    /// 「6か月」, "6 months".
    static func monthCount(_ months: Int) -> String {
        String(localized: "\(months)か月", table: "Planning", comment: "A number of months")
    }

    /// VoiceOver value of a progress bar: 「42パーセント」, "42 percent".
    static func percentValue(_ fraction: Double) -> String {
        String(
            localized: "\(Int((fraction * 100).rounded()))パーセント",
            table: "Planning",
            comment: "VoiceOver: a progress bar's value in percent"
        )
    }

    private var bottleCycleTitle: String {
        guard let jarPosition else {
            return String(localized: "今日の瓶を確認中", table: "Planning", comment: "Bottle-cycle title while Home re-counts today's jar, so the jar's position is not shown")
        }
        if jarPosition.isCycleBoundary {
            return String(
                localized: "瓶\(jarPosition.completedCycleCount)杯目が満ちた",
                table: "Planning",
                comment: "Plan preview: the jar filled for the Nth time"
            )
        }
        let percent = Int((jarPosition.cycleProgressFraction * 100).rounded())
        return jarGrams == 0
            ? String(localized: "最初の2.50kgへ", table: "Planning", comment: "Jar-cycle title before anything is added: heading to the first full jar (2.50 kg)")
            : String(localized: "瓶の\(percent)%まで積んだ", table: "Planning", comment: "Jar-cycle title: how full the jar is, in percent")
    }

    private var bottleCycleStatus: String {
        guard let jarPosition else {
            return String(localized: "確認が済むと、今日の瓶の続きから表示します", table: "Planning", comment: "Bottle-cycle caption while Home re-counts today's jar")
        }
        if jarPosition.isCycleBoundary {
            return String(localized: "満杯を確認 · 累計はそのまま次の1杯へ", table: "Planning")
        }
        guard let next = jarPosition.nextCycleBoundaryGrams else {
            return String(localized: "瓶1杯 2.50kg · 集中250分相当", table: "Planning")
        }
        return String(
            localized: "あと\(formattedMass(max(0, next - jarGrams))) · 瓶1杯は集中250分相当",
            table: "Planning",
            comment: "Plan preview: mass left until the jar fills; the argument is a mass"
        )
    }

    /// Today's jar plus the plan. While Home shows 「再集計中」, it shows no
    /// mass, so neither does the plan.
    private var jarTotalValue: String {
        switch start.certainty {
        case .exact:
            return formattedMass(jarGrams)
        case .atLeast:
            return String(
                localized: "\(formattedMass(jarGrams))以上",
                table: "Planning",
                comment: "Jar total when today's jar is a lower bound; the argument is a mass such as 3.68t"
            )
        case .recounting:
            return Self.recountingValue
        }
    }

    /// In place of a mass or a milestone while Home re-counts today's jar.
    private static var recountingValue: String {
        String(localized: "確認中", table: "Planning", comment: "Shown instead of the jar total and its long-term milestone while Home re-counts today's jar")
    }

    /// How the total splits into today's jar and the plan. Hidden for an
    /// empty, verified jar, where the total is the plan alone. While iCloud
    /// is checked, today's jar carries the same caveat as Home's caption.
    private var startBreakdown: String? {
        let plan = formattedMass(projection.grams)
        let today = formattedMass(start.grams)
        switch (start.certainty, start.isBeingChecked) {
        case (.exact, false):
            guard start.grams > 0 else { return nil }
            return String(
                localized: "今日の瓶 \(today) ＋ この計画 \(plan)",
                table: "Planning",
                comment: "Breakdown of the jar total: today's jar mass, then the mass the plan adds"
            )
        case (.exact, true):
            return String(
                localized: "今日の瓶 \(today)（集計を確認中）＋ この計画 \(plan)",
                table: "Planning",
                comment: "Breakdown while Home still checks today's jar (iCloud or this iPhone): today's jar mass, then the mass the plan adds"
            )
        case (.atLeast, false):
            return String(
                localized: "今日の瓶 \(today)以上 ＋ この計画 \(plan)",
                table: "Planning",
                comment: "Breakdown when today's jar is a lower bound: today's jar mass, then the mass the plan adds"
            )
        case (.atLeast, true):
            return String(
                localized: "今日の瓶 \(today)以上（集計を確認中）＋ この計画 \(plan)",
                table: "Planning",
                comment: "Breakdown when today's jar is a lower bound still being checked (iCloud or this iPhone): today's jar mass, then the mass the plan adds"
            )
        case (.recounting, _):
            return String(
                localized: "今日の瓶の合計を確認しているあいだは、この計画で積む分だけを表示します。",
                table: "Planning",
                comment: "Shown while Home re-counts today's jar (iCloud or this iPhone)"
            )
        }
    }

    private var majorMilestoneStatus: String {
        guard let jarPosition else { return Self.recountingValue }
        let reached = jarPosition.completedMajorMilestoneCount
        if jarPosition.isMajorMilestoneBoundary,
           let next = jarPosition.nextMajorMilestoneGrams {
            return String(
                localized: "\(reached)段階到達 · 次 \(formattedMass(next))",
                table: "Planning",
                comment: "Long-term milestones: the stage just reached, then the next milestone's mass"
            )
        }
        guard let next = jarPosition.nextMajorMilestoneGrams else {
            return String(localized: "\(reached)段階到達", table: "Planning", comment: "Long-term milestones: how many stages are reached (no next one)")
        }
        return String(
            localized: "\(reached)段階 · 次 \(formattedMass(next))",
            table: "Planning",
            comment: "Long-term milestones: how many stages are reached, then the next milestone's mass"
        )
    }

    private func majorMilestoneAccessibilityLabel(_ position: JarAccumulationPresenceState) -> String {
        position.isMajorMilestoneBoundary
            ? String(localized: "到達した長期の質量段階", table: "Planning", comment: "VoiceOver: the long-term milestone bar when a stage was just reached")
            : String(localized: "次の長期の質量段階まで", table: "Planning", comment: "VoiceOver: the long-term milestone bar, progress to the next stage")
    }

    private func formattedMass(_ grams: Int) -> String {
        if grams >= 1_000_000 {
            return String(
                localized: "\(String(format: "%.2f", Double(grams) / 1_000_000))t",
                table: "Planning",
                comment: "Mass in metric tonnes; the argument is the number, already formatted (e.g. 3.68). en: '%@ t'."
            )
        }
        if grams >= 1_000 {
            return MassText.kilograms(String(format: "%.1f", Double(grams) / 1_000))
        }
        return MassText.grams("\(grams)")
    }

    @MainActor
    private func refreshScene() {
        sceneRefreshTask?.cancel()
        sceneRefreshTask = nil
        // `restore` is intentionally used here rather than the live drop API:
        // it triggers no landing feedback or persistence callback. Avoid
        // mutating `soundEnabled` / `hapticsEnabled` here because JarScene's
        // default dependencies are app-wide shared instances.
        previewScene.restore(pebbles: projection.descriptors)
    }

    /// jar-05: a drag across the timeline changes `previewMonth` on every
    /// one-month step, and each restore rebuilt every preview gem (about
    /// 11 ms on the main thread). The numbers above follow the slider live;
    /// the jar, below the fold during a drag, catches up once it rests.
    @MainActor
    private func scheduleSceneRefresh() {
        sceneRefreshTask?.cancel()
        sceneRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: Self.sceneRefreshDelay)
            guard !Task.isCancelled else { return }
            refreshScene()
        }
    }
}

/// home-02: the machine-readable projection summary exists for the planning
/// UI test only. It used to be the grid's accessibility value in every build,
/// so VoiceOver read "months=…;consistent=true" after the Japanese metrics.
private struct PlanResultUITestValue: ViewModifier {
    let projection: AccumulationPlanProjection
    let start: AccumulationPlanStart

    func body(content: Content) -> some View {
#if DEBUG
        if LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess {
            content.accessibilityValue(Text(verbatim:
                "months=\(projection.elapsedMonths);sessions=\(projection.completionCount);minutes=\(projection.focusMinutes);grams=\(projection.grams);bodies=\(projection.studyBodyCount);consistent=\(projection.isInternallyConsistent);start=\(start.grams);jar=\(start.jarGrams(adding: projection.grams))"
            ))
        } else {
            content
        }
#else
        content
#endif
    }
}
