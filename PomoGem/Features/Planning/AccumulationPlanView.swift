import SwiftUI

/// An explicitly simulated, non-persistent time-travel view of a study plan.
/// All state in this screen is ordinary SwiftUI `@State`; leaving the sheet
/// discards it. No model context or cloud-backed value crosses this boundary.
struct AccumulationPlanView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var years = AccumulationPlanProjection.Plan.suggested.years
    @State private var sessionsPerWeek = AccumulationPlanProjection.Plan.suggested.sessionsPerWeek
    @State private var minutesPerSession = AccumulationPlanProjection.Plan.suggested.minutesPerSession
    @State private var previewMonth = Double(
        AccumulationPlanProjection.Plan.suggested.years * 12
    )
    @State private var previewScene = JarScene()

    private let minuteChoices = [10, 25, 60]
    private let productSessionsPerWeekRange = 1 ... 21

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
            .navigationTitle("積み上がり計画")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("積み上がり計画")
                            .font(.headline)
                        Label("予測・保存なし", systemImage: "icloud.slash.fill")
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
        .onChange(of: previewMonth) { _, _ in refreshScene() }
        .onChange(of: sessionsPerWeek) { _, _ in refreshScene() }
        .onChange(of: minutesPerSession) { _, _ in refreshScene() }
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

    private var accumulationPresence: JarAccumulationPresenceState {
        JarAccumulationPresencePresentation.state(totalGrams: projection.grams)
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
                    Text("これは予測です")
                        .font(PomoGemTheme.brand(21))
                    Text("ここで動かす瓶や数値は、実際の学習記録・保存領域・ウィジェットには保存されません。画面を閉じると入力も消えます。")
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
                    Text("続け方を選ぶ")
                        .font(PomoGemTheme.brand(21))
                    Text("1回の集中を完走する想定で、週あたりの回数から試算します。")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                }

                controlRow(
                    title: "計画期間",
                    value: "\(years)年",
                    symbol: "calendar"
                ) {
                    Stepper(
                        "計画期間 \(years)年",
                        value: $years,
                        in: AccumulationPlanProjection.Plan.yearRange
                    )
                    .labelsHidden()
                }

                Divider().overlay(PomoGemTheme.glassEdge.opacity(0.12))

                controlRow(
                    title: "週の集中回数",
                    value: "週\(sessionsPerWeek)回",
                    symbol: "repeat"
                ) {
                    Stepper(
                        "週の集中回数 \(sessionsPerWeek)回",
                        value: $sessionsPerWeek,
                        in: productSessionsPerWeekRange
                    )
                    .labelsHidden()
                }

                Divider().overlay(PomoGemTheme.glassEdge.opacity(0.12))

                VStack(alignment: .leading, spacing: 9) {
                    Label("1回の集中時間", systemImage: "timer")
                        .font(.subheadline.weight(.semibold))
                    Picker("1回の集中時間", selection: $minutesPerSession) {
                        ForEach(minuteChoices, id: \.self) { minutes in
                            Text("\(minutes)分").tag(minutes)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("planning.accumulation.minutes")
                    Text("10分の自由時間を実際に使うにはProが必要です。計画の試算は無料で操作できます。")
                        .font(.caption2)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
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
                            .font(PomoGemTheme.brand(23))
                    }
                    Spacer()
                    Text("予測")
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
                .accessibilityLabel("計画の経過期間")
                .accessibilityValue(previewPeriodTitle)
                .accessibilityIdentifier("planning.accumulation.timeline")

                HStack {
                    Text("現在")
                    Spacer()
                    Text("\(years)年後")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PomoGemTheme.muted)

                Text("スライダーを動かすと、その時点までに積み上がる想定の瓶・時間・質量へ巻き戻せます。")
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
                            .trim(from: 0, to: accumulationPresence.cycleProgressFraction)
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
                        SectionEyebrow(text: "BOTTLE CYCLE")
                        Text(bottleCycleTitle)
                            .font(PomoGemTheme.brand(20))
                        Text(bottleCycleStatus)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                }

                ProgressView(value: accumulationPresence.cycleProgressFraction)
                    .tint(PomoGemTheme.amber)
                    .accessibilityLabel("現在の瓶が満ちるまで")
                    .accessibilityValue(
                        "\(Int((accumulationPresence.cycleProgressFraction * 100).rounded()))パーセント"
                    )

                HStack(alignment: .firstTextBaseline) {
                    Text("累計")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                    Text(DurationPresentation.minutesLabel(projection.focusMinutes))
                        .font(.system(.title2, design: .rounded, weight: .heavy))
                    Spacer()
                    Text(formattedMass(projection.grams))
                        .font(.system(.headline, design: .rounded, weight: .heavy))
                        .foregroundStyle(PomoGemTheme.amber)
                }

                Divider().overlay(PomoGemTheme.glassEdge.opacity(0.12))

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Label("長期の時間の核", systemImage: "sparkles")
                            .font(.caption.weight(.bold))
                        Spacer()
                        Text(majorMilestoneStatus)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color(hex: "#5DE0BD"))
                    }

                    ProgressView(value: accumulationPresence.majorMilestoneProgressFraction)
                        .tint(Color(hex: "#5DE0BD"))
                        .accessibilityLabel(majorMilestoneAccessibilityLabel)
                        .accessibilityValue(
                            "\(Int((accumulationPresence.majorMilestoneProgressFraction * 100).rounded()))パーセント"
                        )
                }

                Text("瓶は2.50kg（集中250分相当）ごとに必ず満ち、満杯の光を見届けてから次の巡へ進みます。累計は消えず、2.50kg → 25kg → 250kg…の長期段階として別に残ります。回数ではなく、集中1分＝\(Constants.Mass.gramsPerMinute)gで両方が進みます。")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Label(
                    "60分 = 600g = 25分×2 + 10分 = 10分×6",
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
                .accessibilityLabel("同じ60分なら、分け方にかかわらず600グラムです")
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
                        Text("その時点の積み上がり")
                            .font(PomoGemTheme.brand(21))
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

                EffortConstellationView(
                    nodes: projection.constellationNodes,
                    totalGrams: projection.grams,
                    totalPebbleCount: projection.completionCount
                )
                .frame(height: 245)
                .overlay {
                    if projection.completionCount == 0 {
                        ContentUnavailableView(
                            "現在地点",
                            systemImage: "circle.dotted",
                            description: Text("右へ動かすと予測が積み上がります")
                        )
                    }
                }

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

                Text("星図と瓶は見え方の予測です。粒のまとまりは予定した完走リズムを、上の時間・質量は集中時間の累計を表します。成果石・実際の休止日は含めません。")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var totalsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(previewPeriodTitle)の予測")
                .font(PomoGemTheme.brand(20))
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 10
            ) {
                metric(title: "集中時間", value: DurationPresentation.minutesLabel(projection.focusMinutes))
                metric(title: "質量", value: formattedMass(projection.grams))
                metric(title: "予定リズム", value: "\(projection.completionCount.formatted())回")
                metric(title: "表示する可動体", value: "\(projection.studyBodyCount)体")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("planning.accumulation.result")
        .accessibilityValue(Text(verbatim:
            "months=\(projection.elapsedMonths);sessions=\(projection.completionCount);minutes=\(projection.focusMinutes);grams=\(projection.grams);bodies=\(projection.studyBodyCount);consistent=\(projection.isInternallyConsistent)"
        ))
    }

    private var calculationNote: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("試算の前提", systemImage: "info.circle.fill")
                    .font(.subheadline.weight(.bold))
                Text("1年を平均365.25日として週回数を換算し、1回の完走を1粒、集中1分を\(Constants.Mass.gramsPerMinute)gとして計算します。2.50kgごとの瓶の巡回、長期の質量段階、瓶の光は実画面と同じ計算です。10個ずつまとめるため、長期間でも描画する可動体は\(Constants.Jar.maxPhysicsBodies)体以内です。")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Label("保存領域・実績への反映はありません", systemImage: "externaldrive.badge.xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(hex: "#5DE0BD"))
            }
        }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(PomoGemTheme.muted)
            Text(value)
                .font(.system(.headline, design: .rounded, weight: .heavy))
                .monospacedDigit()
                .minimumScaleFactor(0.72)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .padding(.horizontal, 13)
        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 15))
    }

    private var previewPeriodTitle: String {
        let months = Int(previewMonth.rounded())
        guard months > 0 else { return "現在" }
        let wholeYears = months / 12
        let remainingMonths = months % 12
        if wholeYears == 0 { return "\(remainingMonths)か月後" }
        if remainingMonths == 0 { return "\(wholeYears)年後" }
        return "\(wholeYears)年\(remainingMonths)か月後"
    }

    private var bottleCycleTitle: String {
        if accumulationPresence.isCycleBoundary {
            return "\(accumulationPresence.completedCycleCount.formatted())巡目が満ちた"
        }
        let percent = Int((accumulationPresence.cycleProgressFraction * 100).rounded())
        return projection.grams == 0
            ? "最初の2.50kgへ"
            : "瓶の\(percent)%まで積んだ"
    }

    private var bottleCycleStatus: String {
        if accumulationPresence.isCycleBoundary {
            return "満杯を確認 · 累計はそのまま次の巡へ"
        }
        guard let next = accumulationPresence.nextCycleBoundaryGrams else {
            return "1巡 2.50kg · 集中250分相当"
        }
        return "あと\(formattedMass(max(0, next - projection.grams))) · 1巡は集中250分相当"
    }

    private var majorMilestoneStatus: String {
        let reached = "\(accumulationPresence.completedMajorMilestoneCount.formatted())段階"
        if accumulationPresence.isMajorMilestoneBoundary,
           let next = accumulationPresence.nextMajorMilestoneGrams {
            return "\(reached)到達 · 次 \(formattedMass(next))"
        }
        guard let next = accumulationPresence.nextMajorMilestoneGrams else {
            return "\(reached)到達"
        }
        return "\(reached) · 次 \(formattedMass(next))"
    }

    private var majorMilestoneAccessibilityLabel: String {
        accumulationPresence.isMajorMilestoneBoundary
            ? "到達した長期の質量段階"
            : "次の長期の質量段階まで"
    }

    private func formattedMass(_ grams: Int) -> String {
        if grams >= 1_000_000 {
            return String(format: "%.2ft", Double(grams) / 1_000_000)
        }
        if grams >= 1_000 {
            return String(format: "%.1fkg", Double(grams) / 1_000)
        }
        return "\(grams)g"
    }

    @MainActor
    private func refreshScene() {
        // `restore` is intentionally used here rather than the live drop API:
        // it triggers no landing feedback or persistence callback. Avoid
        // mutating `soundEnabled` / `hapticsEnabled` here because JarScene's
        // default dependencies are app-wide shared instances.
        previewScene.restore(pebbles: projection.descriptors)
    }
}
