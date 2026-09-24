import Foundation
import SwiftUI
import UIKit

/// Human-readable, monotonic presentation rules for decimal aggregates.
///
/// The stored hierarchy remains exact (`pebbleCount` is never rounded). These
/// rules only make a long-lived jar legible at a glance: a ×100_000 aggregate
/// should feel more important than ×10 without becoming a larger physics body
/// that jams the bottle.
enum AggregatePresentation {
    static func countLabel(_ pebbleCount: Int) -> String {
        let count = max(0, pebbleCount)
        switch count {
        case 100_000_000...:
            return "×\(scaled(count, divisor: 100_000_000))億"
        case 10_000...:
            return "×\(scaled(count, divisor: 10_000))万"
        case 1_000...:
            return "×\(scaled(count, divisor: 1_000))千"
        default:
            return "×\(count)"
        }
    }

    static func title(level: Int) -> String {
        switch max(1, level) {
        case 1: "結晶"
        case 2: "星片"
        case 3: "星晶"
        case 4: "星核"
        case 5: "軌道核"
        case 6: "星冠"
        case 7: "光脈核"
        default: "永続核"
        }
    }

    static func ringCount(level: Int) -> Int {
        min(max(level, 1), 6)
    }

    static func facetCount(level: Int) -> Int {
        min(
            NonnegativeIntPolicy.adding(
                4,
                NonnegativeIntPolicy.multiplying(max(level, 1), 2)
            ),
            20
        )
    }

    static func coreBlendAmount(level: Int) -> CGFloat {
        max(0.07, 0.18 - CGFloat(max(level, 1) - 1) * 0.025)
    }

    static func glowScale(level: Int, containsRare: Bool) -> CGFloat {
        min(0.64, 0.16 + CGFloat(max(level, 1)) * 0.055 + (containsRare ? 0.06 : 0))
    }

    private static func scaled(_ count: Int, divisor: Int) -> String {
        if count.isMultiple(of: divisor) {
            return String(count / divisor)
        }
        let value = Double(count) / Double(divisor)
        return String(format: "%.1f", value)
            .replacingOccurrences(of: ".0", with: "")
    }
}

/// A week is a forgiving context cue, not a streak. Missing a day never
/// removes progress; this helper only counts completions inside the calendar's
/// current week and is deterministic across DST and locale changes.
enum WeeklyProgressPolicy {
    struct GrowthState: Equatable, Sendable {
        let outerLitFacetCount: Int
        let activeLayerLitFacetCount: Int
        let completedLayerCount: Int
        let visibleRingCount: Int
    }

    static func completionCount(
        dates: [Date],
        at referenceDate: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Int {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: referenceDate) else {
            return 0
        }
        return dates.reduce(into: 0) { count, date in
            if interval.contains(date) { count += 1 }
        }
    }

    static func litFacetCount(for completionCount: Int, maximum: Int = 12) -> Int {
        min(max(0, completionCount), max(1, maximum))
    }

    /// Completion 13 must not look identical to completion 12. The first
    /// twelve facets remain permanently lit; later completions grow a bright
    /// inner layer and leave a ring behind whenever another twelve complete.
    /// This is cumulative context, never a daily streak or a loss state.
    static func growthState(for completionCount: Int, maximum: Int = 12) -> GrowthState {
        let facetMaximum = max(1, maximum)
        let count = max(0, completionCount)
        guard count > 0 else {
            return GrowthState(
                outerLitFacetCount: 0,
                activeLayerLitFacetCount: 0,
                completedLayerCount: 0,
                visibleRingCount: 0
            )
        }

        let completedLayerCount = (count - 1) / facetMaximum
        return GrowthState(
            outerLitFacetCount: min(count, facetMaximum),
            activeLayerLitFacetCount: completedLayerCount == 0
                ? 0
                : ((count - 1) % facetMaximum) + 1,
            completedLayerCount: completedLayerCount,
            visibleRingCount: min(completedLayerCount, 5)
        )
    }
}

/// The deterministic reward bridge shown immediately after a measured focus.
/// It makes the next ten-to-one transformation visible without introducing a
/// second currency, a streak, or an uncertain target.
struct FusionRewardBridgeState: Equatable, Sendable {
    let totalPebbleCount: Int
    let durableHorizon: FusionHierarchyHorizon
    let immediateHorizon: FusionHierarchyHorizon
    /// A non-empty value means the just-added particle closed one or more
    /// decimal carries. The bridge deliberately freezes the completed beat at
    /// 10/10 instead of instantly resetting to the next, more distant tier.
    let completedFusionLevels: [Int]

    var isFusionComplete: Bool { !completedFusionLevels.isEmpty }

    var destinationLabel: String {
        AggregatePresentation.countLabel(destinationPebbleCount)
    }

    var destinationLevel: Int {
        completedFusionLevels.last ?? immediateHorizon.destinationLevel
    }

    var destinationPebbleCount: Int {
        guard let completedLevel = completedFusionLevels.last else {
            return immediateHorizon.destinationPebbleCount
        }
        return Self.decimalUnit(at: completedLevel)
    }

    var litSlotCount: Int {
        if isFusionComplete { return immediateHorizon.requiredSourceUnitCount }
        return min(
            max(0, immediateHorizon.sourceUnitCount),
            immediateHorizon.requiredSourceUnitCount
        )
    }

    var progressLabel: String {
        if isFusionComplete {
            return "\(destinationLabel)完成 \(litSlotCount)/\(immediateHorizon.requiredSourceUnitCount)"
        }
        return "\(destinationLabel)へ \(litSlotCount)/\(immediateHorizon.requiredSourceUnitCount)"
    }

    var nextStepLabel: String {
        if isFusionComplete {
            if completedFusionLevels.count > 1 {
                return "\(completedFusionLevels.count)段融合が完成。小さな一粒も消えていません"
            }
            return "10粒がひとつの結晶に。中の一粒と質量はそのまま"
        }
        let remaining = max(1, immediateHorizon.remainingPebbleCount)
        if immediateHorizon.cascadingDestinationLevels.count > 1 {
            return "あと\(remaining)粒で\(immediateHorizon.cascadingDestinationLevels.count)段融合"
        }
        return "次のまとまりまで、あと\(remaining)粒"
    }

    /// The first line always rewards the smallest current effort. A separate,
    /// quieter line preserves the broader ×100/×1,000 context without making
    /// particles 11...19 look identical to one another.
    var longTermContextLabel: String? {
        let durableProgress = "\(AggregatePresentation.countLabel(durableHorizon.destinationPebbleCount))へ \(durableHorizon.sourceUnitCount)/\(durableHorizon.requiredSourceUnitCount)"
        if isFusionComplete { return "次は\(durableProgress)" }
        guard durableHorizon.destinationPebbleCount != immediateHorizon.destinationPebbleCount
        else { return nil }
        return "長期：\(durableProgress)"
    }

    private static func decimalUnit(at level: Int) -> Int {
        guard level > 0 else { return 1 }
        return (0..<level).reduce(1) { value, _ in value * FusionHierarchyPresentation.fanIn }
    }
}

/// Copy and slot state for the post-focus bridge. A partial CloudKit
/// projection is intentionally not treated as an exact decimal digit: a known
/// lower bound of 10 can later become 11 and would otherwise appear to regress
/// from 10/10 to 1/10. The just-finished effort remains certain, so the partial
/// state celebrates only that particle until the hierarchy is exact again.
struct FusionRewardBridgeDisplayState: Equatable, Sendable {
    let eyebrow: String
    let progressLabel: String
    let nextStepLabel: String
    let longTermContextLabel: String?
    let litSlotCount: Int?
    let accessibilityLabel: String
}

enum FusionRewardBridgePresentation {
    static func state(totalPebbleCount: Int) -> FusionRewardBridgeState {
        let hierarchy = FusionHierarchyPresentation.snapshot(
            totalPebbleCount: totalPebbleCount
        )
        let completedFusionLevels = completedLevels(
            totalPebbleCount: hierarchy.totalPebbleCount
        )
        return FusionRewardBridgeState(
            totalPebbleCount: hierarchy.totalPebbleCount,
            durableHorizon: hierarchy.homeFusionHorizon,
            immediateHorizon: hierarchy.nextFusionHorizon,
            completedFusionLevels: completedFusionLevels
        )
    }

    static func display(
        state: FusionRewardBridgeState,
        projectionIsLowerBound: Bool
    ) -> FusionRewardBridgeDisplayState {
        guard projectionIsLowerBound else {
            let accessibilityLabel = [
                "結晶の進み",
                state.progressLabel,
                state.nextStepLabel,
                state.longTermContextLabel
            ]
            .compactMap { $0 }
            .joined(separator: "、")
            return FusionRewardBridgeDisplayState(
                eyebrow: "NEXT CRYSTAL",
                progressLabel: state.progressLabel,
                nextStepLabel: state.nextStepLabel,
                longTermContextLabel: state.longTermContextLabel,
                litSlotCount: state.litSlotCount,
                accessibilityLabel: accessibilityLabel
            )
        }

        return FusionRewardBridgeDisplayState(
            eyebrow: "CRYSTAL SYNC",
            progressLabel: "今回 +1粒",
            nextStepLabel: "結晶進捗を整理中",
            longTermContextLabel: "保存データの読み込み後に正確な位置を表示します",
            litSlotCount: nil,
            accessibilityLabel: "今回の完走で1粒追加。結晶進捗を整理中です"
        )
    }

    private static func completedLevels(totalPebbleCount: Int) -> [Int] {
        guard totalPebbleCount > 0 else { return [] }
        var remaining = totalPebbleCount
        var level = 0
        while remaining.isMultiple(of: FusionHierarchyPresentation.fanIn) {
            level += 1
            remaining /= FusionHierarchyPresentation.fanIn
        }
        return level > 0 ? Array(1...level) : []
    }
}

/// Copy and a continuous fraction for the duration-normalized Reward Bridge.
/// This lives beside the count-based bridge so a receipt written by an older
/// build can still render its original, internally consistent payload.
struct EffortProgressDisplayState: Equatable, Sendable {
    let eyebrow: String
    let progressLabel: String
    let nextStepLabel: String
    let longTermContextLabel: String?
    let progressFraction: Double?
    let accessibilityLabel: String
}

enum EffortProgressPresentation {
    static func display(
        snapshot: EffortProgressSnapshot,
        projectionIsLowerBound: Bool
    ) -> EffortProgressDisplayState {
        let contribution = formattedDuration(grams: snapshot.latestContributionGrams)
        let accountingDisclosure = "粒は1完走につき1つ。核の進みは集中時間で計算します"

        guard !projectionIsLowerBound else {
            return EffortProgressDisplayState(
                eyebrow: "TIME CORE SYNC",
                progressLabel: "今回 +\(contribution)",
                nextStepLabel: "時間の核を整理中",
                longTermContextLabel: accountingDisclosure,
                progressFraction: nil,
                accessibilityLabel: "今回の完走で\(contribution)を追加。時間の核を整理中。\(accountingDisclosure)"
            )
        }

        let state: EffortProgressDisplayState
        if snapshot.crossedMilestoneGrams != nil {
            let overflow = snapshot.overflowGrams
            let nextStep = overflow > 0
                ? "超過した\(formattedDuration(grams: overflow))も次の段へ保持"
                : "到達分は次の段の進みとして保持"
            state = EffortProgressDisplayState(
                eyebrow: "TIME CORE",
                progressLabel: "\(targetTitle(level: snapshot.displayedTargetLevel)) 到達",
                nextStepLabel: nextStep,
                longTermContextLabel: "次：\(formattedDuration(grams: snapshot.totalGrams)) / \(formattedDuration(grams: snapshot.nextTargetGrams))",
                progressFraction: 1,
                accessibilityLabel: ""
            )
        } else {
            state = EffortProgressDisplayState(
                eyebrow: "TIME CORE",
                progressLabel: "\(targetTitle(level: snapshot.displayedTargetLevel))へ \(formattedDuration(grams: snapshot.displayedProgressGrams)) / \(formattedDuration(grams: snapshot.displayedTargetGrams))",
                nextStepLabel: "あと\(formattedDuration(grams: snapshot.remainingGrams))",
                longTermContextLabel: accountingDisclosure,
                progressFraction: snapshot.progressFraction,
                accessibilityLabel: ""
            )
        }

        let accessibilityLabel = [
            "時間の核",
            state.progressLabel,
            state.nextStepLabel,
            state.longTermContextLabel
        ]
        .compactMap { $0 }
        .joined(separator: "、")
        return EffortProgressDisplayState(
            eyebrow: state.eyebrow,
            progressLabel: state.progressLabel,
            nextStepLabel: state.nextStepLabel,
            longTermContextLabel: state.longTermContextLabel,
            progressFraction: state.progressFraction,
            accessibilityLabel: accessibilityLabel
        )
    }

    static func targetTitle(level: Int) -> String {
        max(1, level) == 1 ? "最初の時間の核" : "時間の核・\(max(1, level))段目"
    }

    static func formattedDuration(grams rawGrams: Int) -> String {
        let grams = max(0, rawGrams)
        guard grams.isMultiple(of: Constants.Mass.gramsPerMinute) else {
            return "\(grams.formatted(.number.grouping(.automatic)))g相当"
        }
        return DurationPresentation.focusLabel(grams: grams)
    }

    static func formattedStandardUnits(grams: Int) -> String {
        let units = EffortProgressPolicy.standardUnitEquivalent(totalGrams: grams)
        var value = String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            units
        )
        while value.hasSuffix("0"), !value.hasSuffix(".0") {
            value.removeLast()
        }
        return "\(value)標準単位"
    }

    static func formattedMass(grams rawGrams: Int) -> String {
        let grams = max(0, rawGrams)
        guard grams >= 1_000 else { return "\(grams)g" }
        var kilograms = String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            Double(grams) / 1_000
        )
        while kilograms.hasSuffix("0") { kilograms.removeLast() }
        if kilograms.hasSuffix(".") { kilograms.removeLast() }
        return "\(kilograms)kg"
    }
}

/// Exact visual semantics for the ten-to-one hand-off. The orbit is not a
/// second currency: every lit source is a persisted unit from the decimal
/// hierarchy, and the centre names the deterministic destination. Keeping the
/// state pure lets unit tests prove that the visual never invents progress
/// during partial CloudKit projection.
struct FusionOrbitStageState: Equatable, Sendable {
    let slotCount: Int
    let litSlotCount: Int?
    let destinationLevel: Int
    let destinationPebbleCount: Int
    let isFusionComplete: Bool
    /// Whether the centre is a persisted form rather than only the outlined
    /// destination of the active ten-to-one carry. This cannot be inferred
    /// from `isFusionComplete`: the lifetime camera deliberately avoids the
    /// one-shot completion flare while still showing a real existing core.
    let destinationMaterialized: Bool
    let emphasizesLatestSource: Bool

    var latestLitSlotIndex: Int? {
        guard let litSlotCount, litSlotCount > 0 else { return nil }
        return min(slotCount, litSlotCount) - 1
    }

    var progressFraction: Double? {
        guard let litSlotCount else { return nil }
        return Double(min(slotCount, max(0, litSlotCount))) / Double(max(1, slotCount))
    }

    var animationKey: String {
        "\(litSlotCount.map(String.init) ?? "sync")-\(destinationLevel)-\(destinationPebbleCount)-\(isFusionComplete)-\(destinationMaterialized)-\(emphasizesLatestSource)"
    }
}

enum FusionOrbitStagePresentation {
    static let slotCount = FusionHierarchyPresentation.fanIn

    static func bridge(
        state: FusionRewardBridgeState,
        projectionIsLowerBound: Bool
    ) -> FusionOrbitStageState {
        FusionOrbitStageState(
            slotCount: slotCount,
            litSlotCount: projectionIsLowerBound ? nil : state.litSlotCount,
            destinationLevel: max(1, state.destinationLevel),
            destinationPebbleCount: max(1, state.destinationPebbleCount),
            isFusionComplete: !projectionIsLowerBound && state.isFusionComplete,
            destinationMaterialized: !projectionIsLowerBound && state.isFusionComplete,
            emphasizesLatestSource: !projectionIsLowerBound
        )
    }

    static func completedAggregate(
        pebbleCount: Int,
        level: Int? = nil
    ) -> FusionOrbitStageState {
        let safeCount = max(1, pebbleCount)
        return FusionOrbitStageState(
            slotCount: slotCount,
            litSlotCount: slotCount,
            destinationLevel: max(
                1,
                level ?? StrataMath.decimalAggregateLevel(forPebbleCount: safeCount)
            ),
            destinationPebbleCount: safeCount,
            isFusionComplete: true,
            destinationMaterialized: true,
            emphasizesLatestSource: false
        )
    }

    /// Long-range camera over the same decimal hierarchy. The centre is the
    /// accumulated lifetime core; the ten satellites show the active durable
    /// digit toward the next larger form. It is deterministic and never plays
    /// the one-time completion flare merely because the overview was opened.
    static func lifetime(
        totalPebbleCount: Int,
        totalGrams: Int? = nil,
        projectionIsLowerBound: Bool
    ) -> FusionOrbitStageState {
        let safeCount = max(0, totalPebbleCount)
        if let totalGrams {
            let effort = EffortProgressPolicy.snapshot(totalGrams: totalGrams)
            let equivalentCount = max(
                1,
                Int(
                    EffortProgressPolicy.standardUnitEquivalent(totalGrams: totalGrams)
                        .rounded(.down)
                )
            )
            return FusionOrbitStageState(
                slotCount: slotCount,
                litSlotCount: projectionIsLowerBound
                    ? nil
                    : min(
                        slotCount,
                        max(
                            0,
                            Int(
                                (effort.progressFraction * Double(slotCount))
                                    .rounded(.down)
                            )
                        )
                    ),
                destinationLevel: EffortConstellationPresentation.coreLevel(
                    totalPebbleCount: equivalentCount
                ),
                destinationPebbleCount: equivalentCount,
                isFusionComplete: false,
                destinationMaterialized: max(0, totalGrams)
                    >= EffortProgressPolicy.firstMilestoneGrams,
                emphasizesLatestSource: false
            )
        }
        let hierarchy = FusionHierarchyPresentation.snapshot(
            totalPebbleCount: safeCount
        )
        let horizon = hierarchy.homeFusionHorizon
        return FusionOrbitStageState(
            slotCount: slotCount,
            litSlotCount: projectionIsLowerBound
                ? nil
                : min(slotCount, max(0, horizon.sourceUnitCount)),
            destinationLevel: EffortConstellationPresentation.coreLevel(
                totalPebbleCount: safeCount
            ),
            destinationPebbleCount: max(1, safeCount),
            isFusionComplete: false,
            destinationMaterialized: safeCount >= FusionHierarchyPresentation.fanIn,
            emphasizesLatestSource: false
        )
    }
}

enum FusionOrbitStageScale: Sendable {
    case compact
    case hero
    case chronicle

    var sourceDiameterFactor: CGFloat {
        switch self {
        case .compact: 0.105
        case .hero: 0.112
        case .chronicle: 0.094
        }
    }

    var incompleteCoreFactor: CGFloat {
        switch self {
        case .compact: 0.24
        case .hero: 0.27
        case .chronicle: 0.47
        }
    }

    var completeCoreFactor: CGFloat {
        switch self {
        case .compact: 0.39
        case .hero: 0.43
        case .chronicle: 0.47
        }
    }
}

/// A single, finite success beat: the newest source appears, and a completed
/// set briefly converges before returning to a readable 10-around-1 diagram.
/// There is no idle roulette, near miss, or endless chase animation. Reduce
/// Motion renders the same final meaning without interpolation.
struct FusionOrbitStage: View {
    let state: FusionOrbitStageState
    let colorHex: String
    var scale: FusionOrbitStageScale = .compact

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var latestSourceIsVisible = false
    @State private var convergencePulse = false
    @State private var completionFlareIsVisible = false

    var body: some View {
        GeometryReader { proxy in
            let dimension = min(proxy.size.width, proxy.size.height)
            let fraction = CGFloat(state.progressFraction ?? 0)
            let baseRadius = dimension * 0.405
            let orbitRadius = state.isFusionComplete && convergencePulse
                ? dimension * 0.285
                : baseRadius
            let sourceDiameter = max(8, dimension * scale.sourceDiameterFactor)
            let coreFactor = state.isFusionComplete
                ? scale.completeCoreFactor
                : scale.incompleteCoreFactor + fraction * 0.055
            let coreDiameter = dimension * coreFactor

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(completionFlareIsVisible ? 0.18 : 0.04),
                                Color(hex: colorHex).opacity(reduceTransparency ? 0.10 : 0.30),
                                PomoGemTheme.auroraViolet.opacity(reduceTransparency ? 0.03 : 0.13),
                                .clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: dimension * 0.54
                        )
                    )
                    .frame(width: dimension * 1.12, height: dimension * 1.12)
                    .blur(radius: reduceTransparency ? 1 : 8)

                Circle()
                    .stroke(
                        Color(hex: colorHex).opacity(colorSchemeContrast == .increased ? 0.56 : 0.24),
                        style: StrokeStyle(lineWidth: 0.9, dash: [2.5, 5.5])
                    )
                    .frame(width: baseRadius * 2, height: baseRadius * 2)

                Circle()
                    .trim(from: 0, to: CGFloat(state.progressFraction ?? 0))
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(hex: colorHex).opacity(0.30),
                                .white.opacity(0.90),
                                PomoGemTheme.auroraViolet.opacity(0.70)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: max(1.4, dimension * 0.012), lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: baseRadius * 2, height: baseRadius * 2)
                    .shadow(color: Color(hex: colorHex).opacity(0.55), radius: 4)

                sourceConnections(
                    dimension: dimension,
                    orbitRadius: orbitRadius
                )

                ForEach(0 ..< state.slotCount, id: \.self) { index in
                    let angle = Angle.degrees(
                        -90 + Double(index) * 360 / Double(max(1, state.slotCount))
                    )
                    let isLit = state.litSlotCount.map { index < $0 } ?? false
                    let isLatest = state.emphasizesLatestSource
                        && index == state.latestLitSlotIndex

                    FusionOrbitSourceShard(
                        colorHex: colorHex,
                        isLit: isLit,
                        isLatest: isLatest && !state.isFusionComplete,
                        highContrast: colorSchemeContrast == .increased
                    )
                    .frame(width: sourceDiameter, height: sourceDiameter)
                    .scaleEffect(
                        isLatest && !latestSourceIsVisible
                            ? 0.18
                            : (state.isFusionComplete && convergencePulse ? 0.80 : 1)
                    )
                    .opacity(
                        isLatest && !latestSourceIsVisible
                            ? 0
                            : (isLit ? 1 : (state.litSlotCount == nil ? 0.28 : 0.46))
                    )
                    .offset(
                        x: CGFloat(cos(angle.radians)) * orbitRadius,
                        y: CGFloat(sin(angle.radians)) * orbitRadius
                    )
                }

                completionFlare(dimension: dimension)

                Group {
                    if state.destinationMaterialized {
                        LifetimeCorePrism(
                            colorHex: colorHex,
                            level: state.destinationLevel
                        )
                    } else {
                        FusionDestinationVessel(
                            colorHex: colorHex,
                            level: state.destinationLevel,
                            isSyncing: state.litSlotCount == nil
                        )
                    }
                }
                .frame(width: coreDiameter, height: coreDiameter)
                .scaleEffect(state.isFusionComplete && convergencePulse ? 1.16 : 1)
                .opacity(state.litSlotCount == nil ? 0.66 : 1)
                .shadow(
                    color: Color(hex: colorHex).opacity(
                        state.destinationMaterialized
                            ? (state.isFusionComplete ? 0.86 : 0.50)
                            : 0.22
                    ),
                    radius: state.destinationMaterialized
                        ? (state.isFusionComplete ? 16 : 9)
                        : 4
                )
            }
            .frame(width: dimension, height: dimension)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .task(id: state.animationKey) {
            await performEntrance()
        }
        .onChange(of: reduceMotion) { _, _ in
            settleForCurrentMotionPreference()
        }
    }

    private func sourceConnections(
        dimension: CGFloat,
        orbitRadius: CGFloat
    ) -> some View {
        Canvas { context, size in
            guard let lit = state.litSlotCount else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for index in 0 ..< min(state.slotCount, max(0, lit)) {
                let angle = -Double.pi / 2
                    + Double(index) / Double(max(1, state.slotCount)) * Double.pi * 2
                let source = CGPoint(
                    x: center.x + CGFloat(cos(angle)) * orbitRadius,
                    y: center.y + CGFloat(sin(angle)) * orbitRadius
                )
                var ray = Path()
                ray.move(to: source)
                ray.addLine(to: center)
                context.stroke(
                    ray,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(hex: colorHex).opacity(0.42),
                            .white.opacity(state.isFusionComplete ? 0.26 : 0.08)
                        ]),
                        startPoint: source,
                        endPoint: center
                    ),
                    lineWidth: state.isFusionComplete ? 0.9 : 0.55
                )
            }
        }
        .frame(width: dimension, height: dimension)
    }

    @ViewBuilder
    private func completionFlare(dimension: CGFloat) -> some View {
        if state.isFusionComplete {
            ForEach(0 ..< 4, id: \.self) { index in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.92), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: dimension * 0.72, height: max(0.8, dimension * 0.009))
                    .rotationEffect(.degrees(Double(index) * 45))
                    .scaleEffect(completionFlareIsVisible ? 1 : 0.22)
                    .opacity(completionFlareIsVisible ? 0.64 : 0)
            }
        }
    }

    @MainActor
    private func performEntrance() async {
        latestSourceIsVisible = reduceMotion
        convergencePulse = false
        completionFlareIsVisible = reduceMotion && state.isFusionComplete
        guard !reduceMotion else { return }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.66)) {
            latestSourceIsVisible = true
        }
        guard state.isFusionComplete else { return }

        try? await Task.sleep(for: .milliseconds(220))
        guard !Task.isCancelled else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
            convergencePulse = true
            completionFlareIsVisible = true
        }
        try? await Task.sleep(for: .milliseconds(430))
        guard !Task.isCancelled else { return }
        withAnimation(.spring(response: 0.52, dampingFraction: 0.78)) {
            convergencePulse = false
        }
        try? await Task.sleep(for: .milliseconds(260))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.36)) {
            completionFlareIsVisible = false
        }
    }

    private func settleForCurrentMotionPreference() {
        guard reduceMotion else { return }
        latestSourceIsVisible = true
        convergencePulse = false
        completionFlareIsVisible = state.isFusionComplete
    }
}

/// An honest preview of an unproven decimal destination. It deliberately
/// avoids the filled facets and bright highlight of a persisted prism: before
/// the first guaranteed carry, or while an active Reward Bridge cannot certify
/// its just-added carry, the centre is only a translucent vessel waiting to be
/// formed. A lifetime lower bound of ten or more already proves a real core.
private struct FusionDestinationVessel: View {
    let colorHex: String
    let level: Int
    let isSyncing: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let shape = LifetimeCoreShape(pointCount: max(8, min(14, 8 + level)))
            let outlineOpacity = colorSchemeContrast == .increased ? 0.86 : 0.58

            ZStack {
                shape
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(hex: colorHex).opacity(
                                    reduceTransparency ? 0.10 : 0.045
                                ),
                                .clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 0.56
                        )
                    )

                shape
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(outlineOpacity),
                                Color(hex: colorHex).opacity(outlineOpacity),
                                PomoGemTheme.auroraViolet.opacity(outlineOpacity * 0.72)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(
                            lineWidth: max(1, size * 0.042),
                            lineCap: .round,
                            dash: isSyncing ? [2, 3.5] : [3.5, 2.5]
                        )
                    )

                shape
                    .stroke(
                        Color.white.opacity(colorSchemeContrast == .increased ? 0.36 : 0.13),
                        lineWidth: max(0.6, size * 0.015)
                    )
                    .scaleEffect(0.68)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct FusionOrbitSourceShard: View {
    let colorHex: String
    let isLit: Bool
    let isLatest: Bool
    let highContrast: Bool

    var body: some View {
        ZStack {
            DiamondSlot()
                .fill(
                    isLit
                        ? AnyShapeStyle(
                            AngularGradient(
                                colors: [
                                    Color(hex: colorHex),
                                    .white,
                                    PomoGemTheme.auroraBlue,
                                    PomoGemTheme.auroraViolet,
                                    Color(hex: colorHex)
                                ],
                                center: .center
                            )
                        )
                        : AnyShapeStyle(PomoGemTheme.raised.opacity(highContrast ? 0.96 : 0.78))
                )
                .overlay {
                    DiamondSlot()
                        .stroke(
                            isLit
                                ? Color.white.opacity(0.90)
                                : Color.white.opacity(highContrast ? 0.70 : 0.18),
                            lineWidth: highContrast ? 1.4 : 0.85
                        )
                }
                .shadow(
                    color: isLit ? Color(hex: colorHex).opacity(0.80) : .clear,
                    radius: isLit ? 5 : 0
                )

            if isLit {
                Circle()
                    .fill(.white.opacity(0.78))
                    .frame(width: 2.5, height: 2.5)
                    .offset(x: -2, y: -2)
            }

            if isLatest {
                Circle()
                    .stroke(Color.white.opacity(0.74), lineWidth: 0.8)
                    .padding(-4)
            }
        }
        .saturation(isLit ? 1.34 : 0.76)
    }
}

/// Pure, bounded geometry for the jar's non-physical accumulation memory.
///
/// `totalGrams` is the only input. In particular, live SpriteKit body count,
/// decimal digits, rarity, and the current aggregation phase cannot change
/// this state. A carry that replaces many movable bodies with one aggregate
/// therefore leaves the optical mass intact while the foreground stays free
/// to roll, bounce, and respond to tilt.
struct JarAccumulationPresenceState: Equatable, Sendable {
    let totalGrams: Int
    let presenceFraction: Double
    let fieldDiameterFactor: Double
    let shelfHeightFactor: Double
    let fieldOpacity: Double
    /// The repeating, human-scale bottle fill. Every 2,500g starts a fresh
    /// cycle, independent of the much longer decimal hierarchy below.
    let cycleProgressFraction: Double
    let completedCycleCount: Int
    let nextCycleBoundaryGrams: Int?
    let lastCompletedCycleBoundaryGrams: Int?
    let isCycleBoundary: Bool
    /// Durable decimal tiers (2.5kg, 25kg, 250kg...) remain separate from the
    /// repeating bottle fill, so a daily user does not wait years to see a full
    /// bottle while long-term achievements still leave permanent traces.
    let majorMilestoneProgressFraction: Double
    let nextMajorMilestoneGrams: Int?
    let lastCompletedMajorMilestoneGrams: Int?
    let completedMajorMilestoneCount: Int
    let visibleMajorMilestoneTraceCount: Int
    let isMajorMilestoneBoundary: Bool

    var isVisible: Bool { totalGrams > 0 }

    // Compatibility names keep the planning surface on the long-term tier
    // until it can present the repeating cycle and the tier side by side.
    var milestoneProgressFraction: Double { majorMilestoneProgressFraction }
    var nextMilestoneGrams: Int? { nextMajorMilestoneGrams }
    var lastCompletedMilestoneGrams: Int? { lastCompletedMajorMilestoneGrams }
    var completedMilestoneCount: Int { completedMajorMilestoneCount }
    var visibleMilestoneTraceCount: Int { visibleMajorMilestoneTraceCount }
    var isMilestoneBoundary: Bool { isMajorMilestoneBoundary }
}

struct JarAccumulationCycleBeat: Equatable, Sendable {
    let cycleBoundaryGrams: Int
    let completedCycleCount: Int
    let crossedCycleCount: Int
}

struct JarAccumulationMilestoneBeat: Equatable, Sendable {
    let milestoneGrams: Int
    let completedMilestoneCount: Int
    let crossedMilestoneCount: Int
}

struct JarAccumulationPresenceLayoutState: Equatable, Sendable {
    let centerGlowOpacityScale: Double
    let traceBandYFraction: Double
}

enum JarAccumulationPresenceLayoutPresentation {
    static func state(showsLifetimeCore: Bool) -> JarAccumulationPresenceLayoutState {
        JarAccumulationPresenceLayoutState(
            // The particle field remains legible at full strength. Only the
            // redundant central glow recedes behind an already materialized
            // lifetime core.
            centerGlowOpacityScale: showsLifetimeCore ? 0.18 : 1,
            // With a core, the narrow band immediately below the neck stays
            // clear of both lower label plates. Before a core exists, the trace
            // can remain near the base where the original accumulation cue lived.
            traceBandYFraction: showsLifetimeCore ? 0.075 : 0.86
        )
    }
}

struct JarAccumulationLightFieldState: Equatable, Sendable {
    let activeCycleFillFraction: Double
    let completionOverlayFillFraction: Double?
}

enum JarAccumulationLightFieldPresentation {
    static func state(
        presence: JarAccumulationPresenceState,
        cycleBeat: JarAccumulationCycleBeat?
    ) -> JarAccumulationLightFieldState {
        JarAccumulationLightFieldState(
            activeCycleFillFraction: min(
                1,
                max(0, presence.cycleProgressFraction)
            ),
            // A crossing with overflow briefly shows the completed full vessel
            // over the already-carried remainder. Removing the overlay reveals
            // that remainder without animating the fill backwards.
            completionOverlayFillFraction: cycleBeat == nil ? nil : 1
        )
    }
}

enum JarAccumulationPresencePresentation {
    /// One ordinary measured focus establishes the quiet baseline. The field
    /// continues to distinguish smaller custom/manual masses instead of
    /// rounding them up to a particle count.
    static let baselineGrams = EffortProgressPolicy.standardUnitGrams
    /// A million ordinary measured focuses is a deliberately distant visual
    /// ceiling. Reaching it fills the bounded optical field; later effort is
    /// still preserved numerically and in the hierarchy without growing UI.
    static let saturationGrams = Constants.Mass.measuredPebbleGrams * 1_000_000
    /// Ten ordinary 25-minute equivalents. This is intentionally fixed rather
    /// than decimal: at one 25-minute focus per day a full bottle returns every
    /// ten days, even after decades of accumulated work.
    static let cycleGrams = EffortProgressPolicy.firstMilestoneGrams

    static func state(
        totalGrams rawTotalGrams: Int,
        effortSnapshot suppliedEffortSnapshot: EffortProgressSnapshot? = nil
    ) -> JarAccumulationPresenceState {
        let totalGrams = max(0, rawTotalGrams)
        let effortSnapshot = resolvedEffortSnapshot(
            totalGrams: totalGrams,
            supplied: suppliedEffortSnapshot
        )
        let cycle = cycleState(totalGrams: totalGrams)
        let majorMilestone = majorMilestoneState(totalGrams: totalGrams)
        guard totalGrams > 0 else {
            return JarAccumulationPresenceState(
                totalGrams: 0,
                presenceFraction: 0,
                fieldDiameterFactor: 0,
                shelfHeightFactor: 0,
                fieldOpacity: 0,
                cycleProgressFraction: cycle.progressFraction,
                completedCycleCount: cycle.completedCount,
                nextCycleBoundaryGrams: cycle.nextBoundaryGrams,
                lastCompletedCycleBoundaryGrams: cycle.lastCompletedBoundaryGrams,
                isCycleBoundary: cycle.isBoundary,
                majorMilestoneProgressFraction: effortSnapshot.progressFraction,
                nextMajorMilestoneGrams: majorMilestone.nextGrams,
                lastCompletedMajorMilestoneGrams: majorMilestone.lastCompletedGrams,
                completedMajorMilestoneCount: majorMilestone.completedCount,
                visibleMajorMilestoneTraceCount: 0,
                isMajorMilestoneBoundary: majorMilestone.isBoundary
            )
        }

        let presence: Double
        if totalGrams <= baselineGrams {
            // `log1p` makes the very first real gram visible while keeping the
            // 250g reference particle deliberately quiet at 18%.
            let initialProgress = log1p(Double(totalGrams))
                / log1p(Double(baselineGrams))
            presence = 0.06 + initialProgress * 0.12
        } else {
            // Six decades separate the baseline from the cap. Logarithmic
            // growth keeps the forty-year fixture legible without letting the
            // backdrop become a second, ever-growing jar.
            let baselineExponent = log10(Double(baselineGrams))
            let saturationExponent = log10(Double(saturationGrams))
            let logarithmicProgress = min(
                1,
                max(
                    0,
                    (log10(Double(totalGrams)) - baselineExponent)
                        / (saturationExponent - baselineExponent)
                )
            )
            presence = 0.18 + logarithmicProgress * 0.82
        }

        return JarAccumulationPresenceState(
            totalGrams: totalGrams,
            presenceFraction: presence,
            fieldDiameterFactor: 0.74 + presence * 0.60,
            shelfHeightFactor: 0.10 + presence * 0.08,
            fieldOpacity: 0.48 + presence * 0.36,
            cycleProgressFraction: cycle.progressFraction,
            completedCycleCount: cycle.completedCount,
            nextCycleBoundaryGrams: cycle.nextBoundaryGrams,
            lastCompletedCycleBoundaryGrams: cycle.lastCompletedBoundaryGrams,
            isCycleBoundary: cycle.isBoundary,
            majorMilestoneProgressFraction: effortSnapshot.progressFraction,
            nextMajorMilestoneGrams: majorMilestone.nextGrams,
            lastCompletedMajorMilestoneGrams: majorMilestone.lastCompletedGrams,
            completedMajorMilestoneCount: majorMilestone.completedCount,
            visibleMajorMilestoneTraceCount: min(majorMilestone.completedCount, 6),
            isMajorMilestoneBoundary: majorMilestone.isBoundary
        )
    }

    /// One deterministic snapshot is shared by the presence field and the
    /// lifetime core. Exact decimal tiers retain a complete 100% frame and the
    /// following target at the same time; ordinary values remain lifetime
    /// snapshots of the next tier.
    static func effortSnapshot(totalGrams rawTotalGrams: Int) -> EffortProgressSnapshot {
        let totalGrams = max(0, rawTotalGrams)
        let majorMilestone = majorMilestoneState(totalGrams: totalGrams)
        let lifetimeSnapshot = EffortProgressPolicy.snapshot(totalGrams: totalGrams)
        guard majorMilestone.isBoundary,
              let completedGrams = majorMilestone.lastCompletedGrams
        else { return lifetimeSnapshot }

        // This is a static presentation hold, not a newly observed crossing.
        // Keeping `crossedMilestoneGrams` nil prevents a restored view from
        // replaying receipt semantics while both jar layers still render 100%.
        return EffortProgressSnapshot(
            totalGrams: totalGrams,
            latestContributionGrams: 0,
            displayedTargetLevel: majorMilestone.completedCount,
            displayedTargetGrams: completedGrams,
            displayedProgressGrams: completedGrams,
            crossedMilestoneGrams: nil,
            nextTargetLevel: lifetimeSnapshot.nextTargetLevel,
            nextTargetGrams: lifetimeSnapshot.nextTargetGrams
        )
    }

    /// Detects one or more fixed 2,500g bottle-fill completions. The highest
    /// crossed boundary is used for the finite full-height beat while any
    /// overflow is already represented by the new state's cycle remainder.
    static func cycleBeat(
        previousTotalGrams rawPreviousTotalGrams: Int,
        currentTotalGrams rawCurrentTotalGrams: Int
    ) -> JarAccumulationCycleBeat? {
        let previousTotalGrams = max(0, rawPreviousTotalGrams)
        let currentTotalGrams = max(0, rawCurrentTotalGrams)
        guard currentTotalGrams > previousTotalGrams else { return nil }

        let previous = cycleState(totalGrams: previousTotalGrams)
        let current = cycleState(totalGrams: currentTotalGrams)
        let crossedCount = current.completedCount - previous.completedCount
        guard crossedCount > 0,
              let boundaryGrams = current.lastCompletedBoundaryGrams
        else { return nil }
        return JarAccumulationCycleBeat(
            cycleBoundaryGrams: boundaryGrams,
            completedCycleCount: current.completedCount,
            crossedCycleCount: crossedCount
        )
    }

    /// Detects a real threshold crossing from two persisted mass frontiers.
    /// Initial render deliberately does not call this function, so reopening
    /// an old jar cannot replay historical completion beats.
    static func milestoneBeat(
        previousTotalGrams rawPreviousTotalGrams: Int,
        currentTotalGrams rawCurrentTotalGrams: Int
    ) -> JarAccumulationMilestoneBeat? {
        let previousTotalGrams = max(0, rawPreviousTotalGrams)
        let currentTotalGrams = max(0, rawCurrentTotalGrams)
        guard currentTotalGrams > previousTotalGrams else { return nil }

        let previous = majorMilestoneState(totalGrams: previousTotalGrams)
        let current = majorMilestoneState(totalGrams: currentTotalGrams)
        let crossedCount = current.completedCount - previous.completedCount
        let effort = EffortProgressPolicy.snapshot(
            totalGrams: currentTotalGrams,
            latestContributionGrams: currentTotalGrams - previousTotalGrams
        )
        guard crossedCount > 0,
              let milestoneGrams = effort.crossedMilestoneGrams
        else { return nil }
        return JarAccumulationMilestoneBeat(
            milestoneGrams: milestoneGrams,
            completedMilestoneCount: current.completedCount,
            crossedMilestoneCount: crossedCount
        )
    }

    private struct MilestoneState {
        let progressFraction: Double
        let nextGrams: Int?
        let lastCompletedGrams: Int?
        let completedCount: Int
        let isBoundary: Bool
    }

    private struct CycleState {
        let progressFraction: Double
        let completedCount: Int
        let nextBoundaryGrams: Int?
        let lastCompletedBoundaryGrams: Int?
        let isBoundary: Bool
    }

    private static func resolvedEffortSnapshot(
        totalGrams: Int,
        supplied: EffortProgressSnapshot?
    ) -> EffortProgressSnapshot {
        guard let supplied, supplied.totalGrams == totalGrams else {
            return effortSnapshot(totalGrams: totalGrams)
        }
        return supplied
    }

    private static func cycleState(totalGrams: Int) -> CycleState {
        let completedCount = totalGrams / cycleGrams
        let remainder = totalGrams % cycleGrams
        let isBoundary = totalGrams > 0 && remainder == 0
        let progress = isBoundary
            ? 1
            : Double(remainder) / Double(cycleGrams)
        let lastCompletedBoundary = completedCount > 0
            ? totalGrams - remainder
            : nil
        let gramsUntilNext = isBoundary ? cycleGrams : cycleGrams - remainder
        let nextBoundary = totalGrams <= Int.max - gramsUntilNext
            ? totalGrams + gramsUntilNext
            : nil
        return CycleState(
            progressFraction: progress,
            completedCount: completedCount,
            nextBoundaryGrams: nextBoundary,
            lastCompletedBoundaryGrams: lastCompletedBoundary,
            isBoundary: isBoundary
        )
    }

    private static func majorMilestoneState(totalGrams: Int) -> MilestoneState {
        var next = EffortProgressPolicy.firstMilestoneGrams
        var lastCompleted: Int?
        var completedCount = 0

        while totalGrams >= next {
            lastCompleted = next
            completedCount += 1
            guard next <= Int.max / 10 else {
                let isBoundary = totalGrams == next
                return MilestoneState(
                    progressFraction: 1,
                    nextGrams: nil,
                    lastCompletedGrams: lastCompleted,
                    completedCount: completedCount,
                    isBoundary: isBoundary
                )
            }
            next *= 10
        }

        let isBoundary = lastCompleted == totalGrams
        // Preserve the just-completed 100% frame. On the following gram the
        // next decimal horizon begins at roughly 10%, while the completed trace
        // count stays permanently incremented.
        let progress = isBoundary
            ? 1
            : min(1, max(0, Double(totalGrams) / Double(next)))
        return MilestoneState(
            progressFraction: progress,
            nextGrams: next,
            lastCompletedGrams: lastCompleted,
            completedCount: completedCount,
            isBoundary: isBoundary
        )
    }
}

/// Static light retained behind the moving particle chamber. It has no hit
/// testing, SpriteKit node, physics body, or animation phase, so it cannot
/// steal gestures or visually fall backward during a decimal carry.
struct JarAccumulationPresenceBackdrop: View {
    let state: JarAccumulationPresenceState
    let colorHex: String
    let showsLifetimeCore: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var lastObservedTotalGrams: Int?
    @State private var highestObservedCompletedCycleCount: Int?
    @State private var highestObservedCompletedMilestoneGrams: Int?
    @State private var cycleBeat: JarAccumulationCycleBeat?
    @State private var majorMilestoneBeat: JarAccumulationMilestoneBeat?

    var body: some View {
        GeometryReader { proxy in
            let dimension = min(190, max(150, proxy.size.width * 0.48))
            let glowDimension = dimension * CGFloat(state.fieldDiameterFactor)
            let stageHeight = min(Constants.Jar.height, max(1, proxy.size.height))
            let lightFieldHeight = max(1, stageHeight - 28)
            let lightFieldWidth = max(1, min(342, proxy.size.width - 48))
            let lightFieldTop = (proxy.size.height - lightFieldHeight) / 2
            let layout = JarAccumulationPresenceLayoutPresentation.state(
                showsLifetimeCore: showsLifetimeCore
            )
            let lightField = JarAccumulationLightFieldPresentation.state(
                presence: state,
                cycleBeat: cycleBeat
            )

            ZStack {
                JarAccumulationLightParticleField(
                    state: state,
                    presentation: lightField,
                    colorHex: colorHex,
                    showsMajorMilestoneBeat: majorMilestoneBeat != nil,
                    reduceTransparency: reduceTransparency
                )
                .frame(width: lightFieldWidth, height: lightFieldHeight)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                // This monotonic memory glow is deliberately separate from the
                // repeating vertical fill. Once the time core exists it recedes
                // so the two optical summaries do not wash each other out.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(hex: colorHex).opacity(reduceTransparency ? 0.12 : 0.25),
                                PomoGemTheme.auroraViolet.opacity(reduceTransparency ? 0.04 : 0.11),
                                .clear
                            ],
                            center: .center,
                            startRadius: 3,
                            endRadius: glowDimension * 0.47
                        )
                    )
                    .frame(width: glowDimension, height: glowDimension)
                    .blur(radius: reduceTransparency ? 2 : 9)
                    .opacity(
                        (reduceTransparency ? 0.76 : state.fieldOpacity)
                            * layout.centerGlowOpacityScale
                    )
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.54)

                if state.completedCycleCount > 0 {
                    HStack(spacing: 4) {
                        Text(compactCycleCount)
                            .font(.system(size: 8, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.82))

                        ForEach(0 ..< state.visibleMajorMilestoneTraceCount, id: \.self) { _ in
                            Circle()
                                .fill(Color(hex: colorHex).opacity(0.86))
                                .overlay {
                                    Circle().stroke(.white.opacity(0.72), lineWidth: 0.6)
                                }
                                .frame(width: 5, height: 5)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        PomoGemTheme.raised.opacity(
                            reduceTransparency ? 0.94 : 0.72
                        ),
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .stroke(Color.white.opacity(0.16), lineWidth: 0.7)
                    }
                    .position(
                        x: proxy.size.width / 2,
                        y: lightFieldTop
                            + lightFieldHeight * CGFloat(layout.traceBandYFraction)
                    )
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .onAppear {
            // Establish a baseline without replaying milestones accumulated
            // before this view was mounted or restored from persistence.
            lastObservedTotalGrams = state.totalGrams
            highestObservedCompletedCycleCount = state.completedCycleCount
            highestObservedCompletedMilestoneGrams = state.lastCompletedMajorMilestoneGrams
        }
        .onChange(of: state.totalGrams) { oldValue, newValue in
            let previous = lastObservedTotalGrams ?? oldValue
            lastObservedTotalGrams = newValue

            let newCycleBeat = JarAccumulationPresencePresentation.cycleBeat(
                previousTotalGrams: previous,
                currentTotalGrams: newValue
            )
            let newMajorMilestoneBeat = JarAccumulationPresencePresentation.milestoneBeat(
                previousTotalGrams: previous,
                currentTotalGrams: newValue
            )

            let acceptedCycleBeat = newCycleBeat.flatMap { beat in
                beat.completedCycleCount > (highestObservedCompletedCycleCount ?? 0)
                    ? beat
                    : nil
            }
            let acceptedMajorMilestoneBeat = newMajorMilestoneBeat.flatMap { beat in
                beat.milestoneGrams > (highestObservedCompletedMilestoneGrams ?? 0)
                    ? beat
                    : nil
            }
            guard acceptedCycleBeat != nil || acceptedMajorMilestoneBeat != nil else {
                return
            }

            if let acceptedCycleBeat {
                highestObservedCompletedCycleCount = acceptedCycleBeat.completedCycleCount
            }
            if let acceptedMajorMilestoneBeat {
                highestObservedCompletedMilestoneGrams = acceptedMajorMilestoneBeat.milestoneGrams
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) {
                cycleBeat = acceptedCycleBeat
                majorMilestoneBeat = acceptedMajorMilestoneBeat
            }
        }
        .task(id: cycleBeat?.cycleBoundaryGrams ?? majorMilestoneBeat?.milestoneGrams) {
            guard cycleBeat != nil || majorMilestoneBeat != nil else { return }
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.32)) {
                cycleBeat = nil
                majorMilestoneBeat = nil
            }
        }
    }

    private var compactCycleCount: String {
        let count = AggregatePresentation.countLabel(state.completedCycleCount)
        return "\(count.dropFirst())巡"
    }
}

/// A bottle-shaped optical mask. It deliberately owns neither a SpriteKit node
/// nor collision geometry; it only constrains light to the visible chamber.
private struct JarAccumulationLightFieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        let centerX = rect.midX
        let neckHalfWidth = rect.width * 0.32
        let shoulderY = rect.minY + rect.height * 0.14
        let bottomRadius = min(rect.width * 0.08, rect.height * 0.07)
        var path = Path()
        path.move(to: CGPoint(x: centerX - neckHalfWidth, y: rect.minY))
        path.addLine(to: CGPoint(x: centerX + neckHalfWidth, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: shoulderY),
            control1: CGPoint(x: centerX + neckHalfWidth, y: rect.minY + rect.height * 0.07),
            control2: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.08)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: shoulderY))
        path.addCurve(
            to: CGPoint(x: centerX - neckHalfWidth, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.08),
            control2: CGPoint(x: centerX - neckHalfWidth, y: rect.minY + rect.height * 0.07)
        )
        path.closeSubpath()
        return path
    }
}

/// Deterministic floating specks form a translucent progress volume. The quiet
/// full-height layer is lifetime memory; the brighter bottom-up layer is the
/// current 2,500g cycle. Neither layer is a solid floor or a physics object.
private struct JarAccumulationLightParticleField: View {
    let state: JarAccumulationPresenceState
    let presentation: JarAccumulationLightFieldState
    let colorHex: String
    let showsMajorMilestoneBeat: Bool
    let reduceTransparency: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                particleCanvas(
                    count: memoryParticleCount,
                    opacityScale: reduceTransparency ? 0.50 : 0.22,
                    whiteSparkInterval: 11
                )

                activeFill(
                    size: proxy.size,
                    fraction: presentation.activeCycleFillFraction,
                    opacityScale: reduceTransparency ? 0.88 : 0.72
                )

                if let completionFill = presentation.completionOverlayFillFraction {
                    activeFill(
                        size: proxy.size,
                        fraction: completionFill,
                        opacityScale: reduceTransparency ? 1 : 0.94
                    )
                    .transition(.opacity)
                }

                if presentation.completionOverlayFillFraction != nil {
                    JarAccumulationLightFieldShape()
                        .stroke(
                            AngularGradient(
                                colors: [
                                    Color(hex: colorHex),
                                    .white,
                                    PomoGemTheme.auroraBlue,
                                    Color(hex: colorHex)
                                ],
                                center: .center
                            ),
                            lineWidth: showsMajorMilestoneBeat
                                ? (reduceTransparency ? 3.4 : 2.8)
                                : (reduceTransparency ? 2.4 : 1.6)
                        )
                        .shadow(
                            color: Color(hex: colorHex).opacity(0.72),
                            radius: reduceTransparency ? 1 : 7
                        )
                        .transition(.opacity)
                }
            }
            .clipShape(JarAccumulationLightFieldShape())
        }
    }

    private var memoryParticleCount: Int {
        min(54, max(12, Int((12 + state.presenceFraction * 42).rounded())))
    }

    private func activeFill(
        size: CGSize,
        fraction rawFraction: Double,
        opacityScale: Double
    ) -> some View {
        let fraction = min(1, max(0, rawFraction))
        return ZStack {
            JarAccumulationLightFieldShape()
                .fill(
                    LinearGradient(
                        colors: [
                            PomoGemTheme.auroraViolet.opacity(
                                reduceTransparency ? 0.06 : 0.025
                            ),
                            Color(hex: colorHex).opacity(
                                reduceTransparency ? 0.14 : 0.075
                            ),
                            PomoGemTheme.auroraBlue.opacity(
                                reduceTransparency ? 0.11 : 0.055
                            )
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            particleCanvas(
                count: 64,
                opacityScale: opacityScale,
                whiteSparkInterval: 7
            )
        }
        .mask(alignment: .bottom) {
            Rectangle()
                .frame(height: size.height * CGFloat(fraction))
        }
    }

    private func particleCanvas(
        count: Int,
        opacityScale: Double,
        whiteSparkInterval: Int
    ) -> some View {
        Canvas { context, size in
            guard count > 0 else { return }
            for index in 0 ..< count {
                // Coprime strides spread points reproducibly without storing a
                // random seed or changing positions between renders.
                let xUnit = (Double((index * 37 + 17) % 101) + 0.5) / 102
                let yUnit = (Double((index * 53 + 29) % 103) + 0.5) / 104
                let diameter = CGFloat(1.8 + Double((index * 7) % 5) * 0.58)
                let alpha = (0.42 + Double((index * 11) % 7) * 0.075) * opacityScale
                let rect = CGRect(
                    x: size.width * CGFloat(xUnit) - diameter / 2,
                    y: size.height * CGFloat(yUnit) - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(Color(hex: colorHex).opacity(alpha))
                )

                if index.isMultiple(of: whiteSparkInterval) {
                    let spark = rect.insetBy(dx: diameter * 0.28, dy: diameter * 0.28)
                    context.fill(
                        Path(ellipseIn: spark),
                        with: .color(Color.white.opacity(min(0.88, alpha + 0.20)))
                    )
                }
            }
        }
        .blur(radius: reduceTransparency ? 0 : 0.45)
    }
}

/// The quiet, deterministic reward that lives behind the physical jar.
///
/// Random rarity is deliberately absent from this state. Current projections
/// advance its value-facing progress from persisted study mass. The count-only
/// path remains available for old receipts and physical-compaction views.
struct JarLifetimeCoreState: Equatable, Sendable {
    let totalPebbleCount: Int
    let coreLevel: Int
    /// Optical diameter relative to the 150...190 pt stage. The first few
    /// efforts remain visibly smaller than a completed ×10 crystal, so the
    /// summary never overwhelms the real, touchable particle in front.
    let prismDiameterFactor: Double
    let visibleHaloRingCount: Int
    let litOrbitSlotCount: Int?
    let title: String
    let countLabel: String
    /// Current mass projections name the remaining duration to the next core.
    /// The compatibility path uses this same field for the next physical
    /// ten-to-one storage event from a legacy count projection.
    let nextFusionLabel: String?
    let progressLabel: String
}

enum JarLifetimeCorePresentation {
    static let orbitSlotCount = FusionHierarchyPresentation.fanIn

    /// Current projections materialize the optical core at 250 minutes / 2.5kg,
    /// independent of how many timer completions produced that mass. The
    /// count-only fallback preserves old physical-compaction presentations.
    static func shouldShowCore(
        totalPebbleCount: Int,
        totalGrams: Int? = nil
    ) -> Bool {
        if let totalGrams {
            return max(0, totalGrams) >= EffortProgressPolicy.firstMilestoneGrams
        }
        return max(0, totalPebbleCount) >= FusionHierarchyPresentation.fanIn
    }

    static func state(
        totalPebbleCount: Int,
        totalGrams: Int? = nil,
        projectionIsLowerBound: Bool,
        effortSnapshot suppliedEffortSnapshot: EffortProgressSnapshot? = nil
    ) -> JarLifetimeCoreState? {
        let count = max(0, totalPebbleCount)
        guard count > 0 else { return nil }

        let hierarchy = FusionHierarchyPresentation.snapshot(
            totalPebbleCount: count
        )
        let effortSnapshot = totalGrams.map { rawTotalGrams in
            let normalizedTotalGrams = max(0, rawTotalGrams)
            if let suppliedEffortSnapshot,
               suppliedEffortSnapshot.totalGrams == normalizedTotalGrams {
                return suppliedEffortSnapshot
            }
            return JarAccumulationPresencePresentation.effortSnapshot(
                totalGrams: normalizedTotalGrams
            )
        }
        let equivalentCount = totalGrams.map {
            max(
                1,
                Int(EffortProgressPolicy.standardUnitEquivalent(totalGrams: $0).rounded(.down))
            )
        } ?? count
        let level = EffortConstellationPresentation.coreLevel(
            totalPebbleCount: equivalentCount
        )
        let compactCount = compactParticleCount(count)

        guard !projectionIsLowerBound else {
            return JarLifetimeCoreState(
                totalPebbleCount: count,
                coreLevel: level,
                prismDiameterFactor: prismDiameterFactor(
                    totalPebbleCount: equivalentCount,
                    coreLevel: level
                ),
                visibleHaloRingCount: AggregatePresentation.ringCount(level: level),
                litOrbitSlotCount: nil,
                title: effortSnapshot == nil
                    ? (count < FusionHierarchyPresentation.fanIn ? "結晶の芽" : "時間の核")
                    : "時間の核",
                countLabel: effortSnapshot.map {
                    "\(EffortProgressPresentation.formattedMass(grams: $0.totalGrams))以上"
                } ?? "\(compactCount)以上",
                nextFusionLabel: nil,
                progressLabel: effortSnapshot == nil ? "結晶を整理中" : "時間の核を整理中"
            )
        }

        let horizon = hierarchy.homeFusionHorizon
        let immediateHorizon = hierarchy.nextFusionHorizon
        if let effortSnapshot {
            let reachedMilestone = effortSnapshot.progressFraction >= 1
                && effortSnapshot.displayedProgressGrams
                    == effortSnapshot.displayedTargetGrams
                && effortSnapshot.nextTargetGrams
                    > effortSnapshot.displayedTargetGrams
            return JarLifetimeCoreState(
                totalPebbleCount: count,
                coreLevel: level,
                prismDiameterFactor: prismDiameterFactor(
                    totalPebbleCount: equivalentCount,
                    coreLevel: level
                ),
                visibleHaloRingCount: AggregatePresentation.ringCount(level: level),
                litOrbitSlotCount: min(
                    orbitSlotCount,
                    max(
                        0,
                        Int(
                            (effortSnapshot.progressFraction * Double(orbitSlotCount))
                                .rounded(.down)
                        )
                    )
                ),
                title: "時間の核",
                countLabel: EffortProgressPresentation.formattedMass(
                    grams: effortSnapshot.totalGrams
                ),
                nextFusionLabel: reachedMilestone
                    ? "次の核：\(EffortProgressPresentation.formattedDuration(grams: effortSnapshot.nextTargetGrams))"
                    : "核まであと\(EffortProgressPresentation.formattedDuration(grams: effortSnapshot.remainingGrams))",
                progressLabel: "時間 \(EffortProgressPresentation.formattedDuration(grams: effortSnapshot.displayedProgressGrams)) / \(EffortProgressPresentation.formattedDuration(grams: effortSnapshot.displayedTargetGrams))"
            )
        }

        let nextFusionLabel: String
        if immediateHorizon.cascadingDestinationLevels.count > 1 {
            nextFusionLabel = "あと\(immediateHorizon.remainingPebbleCount)粒で\(immediateHorizon.cascadingDestinationLevels.count)段融合"
        } else {
            nextFusionLabel = "次の結晶まであと\(immediateHorizon.remainingPebbleCount)粒"
        }
        return JarLifetimeCoreState(
            totalPebbleCount: count,
            coreLevel: level,
            prismDiameterFactor: prismDiameterFactor(
                totalPebbleCount: count,
                coreLevel: level
            ),
            visibleHaloRingCount: AggregatePresentation.ringCount(level: level),
            litOrbitSlotCount: min(
                max(0, horizon.sourceUnitCount),
                horizon.requiredSourceUnitCount
            ),
            title: count < FusionHierarchyPresentation.fanIn ? "結晶の芽" : "時間の核",
            countLabel: compactCount,
            nextFusionLabel: nextFusionLabel,
            progressLabel: "\(AggregatePresentation.countLabel(horizon.destinationPebbleCount))へ \(horizon.sourceUnitCount)/\(horizon.requiredSourceUnitCount)"
        )
    }

    private static func compactParticleCount(_ count: Int) -> String {
        guard count >= 1_000 else {
            return "\(count.formatted(.number.grouping(.automatic)))粒"
        }
        let aggregate = AggregatePresentation.countLabel(count)
        return "\(aggregate.dropFirst())粒"
    }

    /// The input is a count only for legacy projections. Current callers pass
    /// completed 25-minute-equivalent units derived from grams. The optical
    /// core never becomes a physics body that can jam the bottle.
    private static func prismDiameterFactor(
        totalPebbleCount: Int,
        coreLevel: Int
    ) -> Double {
        let count = max(1, totalPebbleCount)
        if count < FusionHierarchyPresentation.fanIn {
            return 0.20 + Double(count - 1) * 0.004375
        }
        return min(0.51, 0.31 + Double(max(0, coreLevel - 1)) * 0.05)
    }
}

/// A noninteractive optical layer behind the SpriteKit bottle. The recent
/// physical stones remain touchable in front; this centre makes compressed
/// lifetime effort legible instead of letting higher tiers become a pile of
/// similarly weighted discs.
struct JarLifetimeCoreBackdrop: View {
    let state: JarLifetimeCoreState
    let colorHex: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var breathing = false

    var body: some View {
        GeometryReader { proxy in
            let dimension = min(190, max(150, proxy.size.width * 0.48))
            let prismFactor = CGFloat(state.prismDiameterFactor)
            // Place the label plate outside the prism with an optical 8–12 pt
            // gap on the iPhone 15+ stage. It must never read as a sticker
            // painted across the crystal.
            let labelOffset = prismFactor / 2 + 0.17
            let progressOffset = min(0.65, labelOffset + 0.19)

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(hex: colorHex).opacity(reduceTransparency ? 0.12 : 0.28),
                                PomoGemTheme.auroraViolet.opacity(reduceTransparency ? 0.04 : 0.13),
                                .clear
                            ],
                            center: .center,
                            startRadius: 3,
                            endRadius: dimension * 0.58
                        )
                    )
                    .frame(width: dimension * 1.34, height: dimension * 1.34)
                    .blur(radius: reduceTransparency ? 2 : 9)
                    .scaleEffect(breathing ? 1.06 : 0.96)

                lifetimeRings(dimension: dimension)

                orbitSlots(dimension: dimension)

                LifetimeCorePrism(
                    colorHex: colorHex,
                    level: state.coreLevel
                )
                .frame(width: dimension * prismFactor, height: dimension * prismFactor)
                .shadow(
                    color: Color(hex: colorHex).opacity(reduceTransparency ? 0.24 : 0.74),
                    radius: 18
                )

                VStack(spacing: 2) {
                    Text(state.title)
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .tracking(1.1)
                    Text(state.countLabel)
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorSchemeContrast == .increased ? 0.10 : 0.16),
                            PomoGemTheme.raised.opacity(
                                reduceTransparency || colorSchemeContrast == .increased ? 0.98 : 0.82
                            )
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            .white.opacity(colorSchemeContrast == .increased ? 0.72 : 0.24),
                            lineWidth: colorSchemeContrast == .increased ? 1.2 : 0.7
                        )
                }
                .offset(y: dimension * labelOffset)

                VStack(spacing: 2) {
                    Text(state.progressLabel)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    if let nextFusionLabel = state.nextFusionLabel {
                        Text(nextFusionLabel)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.86))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(PomoGemTheme.raised.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(hex: colorHex).opacity(0.28), lineWidth: 0.7)
                }
                .offset(y: dimension * progressOffset)
            }
            .frame(width: dimension * 1.42, height: dimension * 1.42)
            .position(x: proxy.size.width / 2, y: proxy.size.height * 0.51)
        }
        // Reduce Transparency must make the summary more solid, not fainter.
        // Blur/glow are already reduced above, so keep the essential core,
        // orbit and labels fully opaque in that accessibility mode.
        .opacity(reduceTransparency ? 1 : 0.92)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .onAppear { updateMotion() }
        .onChange(of: reduceMotion) { _, _ in updateMotion() }
    }

    @ViewBuilder
    private func lifetimeRings(dimension: CGFloat) -> some View {
        ForEach(0 ..< state.visibleHaloRingCount, id: \.self) { index in
            let inset = CGFloat(index) * 8
            Circle()
                .stroke(
                    Color(hex: colorHex).opacity(
                        (colorSchemeContrast == .increased ? 0.50 : 0.13)
                            + CGFloat(index) * (colorSchemeContrast == .increased ? 0.025 : 0.018)
                    ),
                    style: StrokeStyle(
                        lineWidth: index == state.visibleHaloRingCount - 1 ? 1.2 : 0.7,
                        dash: index.isMultiple(of: 2) ? [2.5, 6] : [1, 8]
                    )
                )
                .frame(
                    width: max(80, dimension - inset),
                    height: max(80, dimension - inset)
                )
        }
    }

    private func orbitSlots(dimension: CGFloat) -> some View {
        let lit = state.litOrbitSlotCount
        let radius = dimension * 0.50
        return ZStack {
            ForEach(0 ..< JarLifetimeCorePresentation.orbitSlotCount, id: \.self) { index in
                let angle = Angle.degrees(-90 + Double(index) * 36)
                let isLit = lit.map { index < $0 } ?? false
                DiamondSlot()
                    .fill(
                        isLit
                            ? Color(hex: colorHex)
                            : PomoGemTheme.raised.opacity(
                                colorSchemeContrast == .increased
                                    ? 0.90
                                    : (lit == nil ? 0.26 : 0.58)
                            )
                    )
                    .overlay {
                        DiamondSlot()
                            .stroke(
                                isLit
                                    ? Color.white.opacity(0.82)
                                    : Color.white.opacity(colorSchemeContrast == .increased ? 0.62 : 0.13),
                                lineWidth: colorSchemeContrast == .increased
                                    ? 1.2
                                    : (isLit ? 0.9 : 0.55)
                            )
                    }
                    .shadow(
                        color: isLit ? Color(hex: colorHex).opacity(0.72) : .clear,
                        radius: 5
                    )
                    .frame(width: isLit ? 9 : 7, height: isLit ? 9 : 7)
                    .offset(
                        x: CGFloat(cos(angle.radians)) * radius,
                        y: CGFloat(sin(angle.radians)) * radius
                    )
            }
        }
    }

    private func updateMotion() {
        breathing = false
        guard !reduceMotion,
              !LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess
        else { return }
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
            breathing = true
        }
    }
}

/// A more dimensional material for the one compressed lifetime core. Subject
/// colour remains the anchor, while cool and violet refractions stop a large
/// aggregate from reading as a flat enlarged version of a loose particle.
private struct LifetimeCorePrism: View {
    let colorHex: String
    let level: Int

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                LifetimeCoreShape(pointCount: max(8, min(14, 8 + level)))
                    .fill(
                        AngularGradient(
                            colors: [
                                Color(hex: colorHex),
                                PomoGemTheme.auroraWarm,
                                .white,
                                PomoGemTheme.auroraBlue,
                                PomoGemTheme.auroraViolet,
                                Color(hex: colorHex)
                            ],
                            center: .center,
                            angle: .degrees(-32)
                        )
                    )
                    .overlay {
                        LifetimeCoreShape(pointCount: max(8, min(14, 8 + level)))
                            .fill(
                                RadialGradient(
                                    colors: [
                                        .white.opacity(0.54),
                                        .clear,
                                        Color.black.opacity(0.24)
                                    ],
                                    center: UnitPoint(x: 0.30, y: 0.23),
                                    startRadius: 0,
                                    endRadius: size * 0.70
                                )
                            )
                            .blendMode(.screen)
                    }
                    .overlay {
                        LifetimeCoreShape(pointCount: max(8, min(14, 8 + level)))
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.95), Color(hex: colorHex).opacity(0.86)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: max(1.8, size * 0.035)
                            )
                    }

                Canvas { context, canvasSize in
                    let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                    let radius = min(canvasSize.width, canvasSize.height) * 0.43
                    let facets = max(8, min(14, 8 + level))
                    for index in 0 ..< facets {
                        let angle = -Double.pi / 2 + Double(index) / Double(facets) * Double.pi * 2
                        let next = -Double.pi / 2 + Double(index + 1) / Double(facets) * Double.pi * 2
                        var facet = Path()
                        facet.move(to: center)
                        facet.addLine(to: CGPoint(
                            x: center.x + CGFloat(cos(angle)) * radius,
                            y: center.y + CGFloat(sin(angle)) * radius
                        ))
                        facet.addLine(to: CGPoint(
                            x: center.x + CGFloat(cos(next)) * radius,
                            y: center.y + CGFloat(sin(next)) * radius
                        ))
                        facet.closeSubpath()
                        context.fill(
                            facet,
                            with: .color(
                                index.isMultiple(of: 3)
                                    ? .white.opacity(0.12)
                                    : Color.black.opacity(index.isMultiple(of: 2) ? 0.08 : 0.02)
                            )
                        )
                        context.stroke(facet, with: .color(.white.opacity(0.16)), lineWidth: 0.55)
                    }

                    let coreRadius = radius * min(0.24, 0.12 + CGFloat(level) * 0.018)
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: center.x - coreRadius,
                            y: center.y - coreRadius,
                            width: coreRadius * 2,
                            height: coreRadius * 2
                        )),
                        with: .radialGradient(
                            Gradient(colors: [.white.opacity(0.94), .white.opacity(0)]),
                            center: center,
                            startRadius: 0,
                            endRadius: coreRadius
                        )
                    )
                }

                Capsule()
                    .fill(.white.opacity(0.72))
                    .frame(width: size * 0.24, height: size * 0.075)
                    .blur(radius: size * 0.014)
                    .rotationEffect(.degrees(-18))
                    .offset(x: -size * 0.18, y: -size * 0.22)
            }
            .frame(width: size, height: size)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .saturation(1.22)
        }
    }
}

private struct LifetimeCoreShape: Shape {
    let pointCount: Int

    func path(in rect: CGRect) -> Path {
        let count = max(6, pointCount)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.46
        var path = Path()
        for index in 0 ..< count {
            let angle = -Double.pi / 2 + Double(index) / Double(count) * Double.pi * 2
            let modulation: CGFloat = index.isMultiple(of: 2) ? 1 : 0.89
            let point = CGPoint(
                x: center.x + CGFloat(cos(angle)) * radius * modulation,
                y: center.y + CGFloat(sin(angle)) * radius * modulation
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

private struct DiamondSlot: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

/// A lightweight, code-native crystal shared by the completion card,
/// aggregation celebration, and the three-scale overview. It grows facets
/// from real completed sessions and remains static when Reduce Motion is on.
struct ProgressCrystalGlyph: View {
    let completionCount: Int
    let colorHex: String
    var level = 1
    var showsCount = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breath = false

    private let facetMaximum = 12

    var body: some View {
        ZStack {
            Canvas { context, size in
                drawCrystal(context: &context, size: size)
            }
            .scaleEffect(breath ? 1.018 : 0.99)
            .shadow(
                color: Color(hex: colorHex).opacity(0.48),
                radius: 9 + CGFloat(min(max(level, 1), 4)) * 2
            )

            if showsCount {
                Text(AggregatePresentation.countLabel(completionCount))
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                    .minimumScaleFactor(0.65)
                    .padding(5)
            }
        }
        .onAppear { updateMotion() }
        .onChange(of: reduceMotion) { _, _ in updateMotion() }
        .accessibilityHidden(true)
    }

    private func drawCrystal(context: inout GraphicsContext, size: CGSize) {
        let diameter = min(size.width, size.height)
        guard diameter > 2 else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = diameter * 0.43
        let base = Color(hex: colorHex)
        let vertices = (0..<facetMaximum).map { index -> CGPoint in
            let angle = -Double.pi / 2 + Double(index) / Double(facetMaximum) * Double.pi * 2
            let modulation = index.isMultiple(of: 2) ? 1.0 : 0.87
            return CGPoint(
                x: center.x + CGFloat(cos(angle)) * radius * modulation,
                y: center.y + CGFloat(sin(angle)) * radius * modulation
            )
        }

        let auraRect = CGRect(
            x: center.x - radius * 1.12,
            y: center.y - radius * 1.12,
            width: radius * 2.24,
            height: radius * 2.24
        )
        context.fill(
            Path(ellipseIn: auraRect),
            with: .radialGradient(
                Gradient(colors: [base.opacity(0.30), base.opacity(0)]),
                center: center,
                startRadius: 0,
                endRadius: radius * 1.12
            )
        )

        let growth = WeeklyProgressPolicy.growthState(
            for: completionCount,
            maximum: facetMaximum
        )
        let lit = growth.outerLitFacetCount
        for index in vertices.indices {
            var facet = Path()
            facet.move(to: center)
            facet.addLine(to: vertices[index])
            facet.addLine(to: vertices[(index + 1) % vertices.count])
            facet.closeSubpath()

            let isLit = index < lit
            let highlight = index.isMultiple(of: 3)
            let color: Color = if isLit {
                highlight ? base.mix(with: .white, by: 0.34) : base
            } else {
                base.mix(with: Color(hex: Constants.Color.inkRaised), by: 0.64)
            }
            context.fill(facet, with: .color(color.opacity(isLit ? 0.96 : 0.72)))
            context.stroke(facet, with: .color(.white.opacity(isLit ? 0.22 : 0.09)), lineWidth: 0.7)
        }

        var outline = Path()
        if let first = vertices.first {
            outline.move(to: first)
            vertices.dropFirst().forEach { outline.addLine(to: $0) }
            outline.closeSubpath()
        }
        context.stroke(
            outline,
            with: .linearGradient(
                Gradient(colors: [.white.opacity(0.82), base.opacity(0.82)]),
                startPoint: CGPoint(x: center.x - radius, y: center.y - radius),
                endPoint: CGPoint(x: center.x + radius, y: center.y + radius)
            ),
            lineWidth: max(1.2, diameter * 0.025)
        )

        drawGrowthLayers(
            context: &context,
            center: center,
            radius: radius,
            base: base,
            state: growth
        )

        let flare = Path(ellipseIn: CGRect(
            x: center.x - radius * 0.35,
            y: center.y - radius * 0.52,
            width: radius * 0.28,
            height: radius * 0.16
        ))
        context.fill(flare, with: .color(.white.opacity(lit > 0 ? 0.62 : 0.18)))
    }

    private func drawGrowthLayers(
        context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        base: Color,
        state: WeeklyProgressPolicy.GrowthState
    ) {
        guard state.completedLayerCount > 0 else { return }

        for index in 0 ..< state.visibleRingCount {
            let inset = radius * (0.18 + CGFloat(index) * 0.105)
            let ringRadius = max(radius * 0.28, radius - inset)
            let ring = Path(ellipseIn: CGRect(
                x: center.x - ringRadius,
                y: center.y - ringRadius,
                width: ringRadius * 2,
                height: ringRadius * 2
            ))
            let dash: [CGFloat] = index.isMultiple(of: 2) ? [] : [2.5, 3.5]
            context.stroke(
                ring,
                with: .color(base.mix(with: .white, by: 0.32).opacity(0.36 + Double(index) * 0.07)),
                style: StrokeStyle(lineWidth: 0.9 + CGFloat(index) * 0.18, dash: dash)
            )
        }

        let innerRadius = radius * 0.34
        let activeLit = state.activeLayerLitFacetCount
        let innerVertices = (0 ..< facetMaximum).map { index -> CGPoint in
            let angle = -Double.pi / 2
                + Double(index) / Double(facetMaximum) * Double.pi * 2
                + Double(state.completedLayerCount) * 0.11
            return CGPoint(
                x: center.x + CGFloat(cos(angle)) * innerRadius,
                y: center.y + CGFloat(sin(angle)) * innerRadius
            )
        }
        for index in innerVertices.indices {
            var facet = Path()
            facet.move(to: center)
            facet.addLine(to: innerVertices[index])
            facet.addLine(to: innerVertices[(index + 1) % innerVertices.count])
            facet.closeSubpath()
            let isLit = index < activeLit
            context.fill(
                facet,
                with: .color(
                    isLit
                        ? base.mix(with: .white, by: 0.46).opacity(0.98)
                        : Color(hex: Constants.Color.inkRaised).opacity(0.74)
                )
            )
            context.stroke(
                facet,
                with: .color(.white.opacity(isLit ? 0.34 : 0.08)),
                lineWidth: 0.55
            )
        }

        let coreRadius = radius * min(0.17, 0.09 + CGFloat(state.completedLayerCount) * 0.012)
        context.fill(
            Path(ellipseIn: CGRect(
                x: center.x - coreRadius,
                y: center.y - coreRadius,
                width: coreRadius * 2,
                height: coreRadius * 2
            )),
            with: .radialGradient(
                Gradient(colors: [.white.opacity(0.92), base.opacity(0.72)]),
                center: center,
                startRadius: 0,
                endRadius: coreRadius
            )
        )
    }

    private func updateMotion() {
        guard !reduceMotion,
              !LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess
        else {
            breath = false
            return
        }
        breath = false
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
            breath = true
        }
    }
}

private extension Color {
    func mix(with other: Color, by amount: CGFloat) -> Color {
        let fraction = min(max(amount, 0), 1)
        return Color(uiColor: UIColor(self).progressMixed(
            with: UIColor(other),
            amount: fraction
        ))
    }
}

private extension UIColor {
    func progressMixed(with other: UIColor, amount: CGFloat) -> UIColor {
        let value = min(max(amount, 0), 1)
        var lhs: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var rhs: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        getRed(&lhs.0, green: &lhs.1, blue: &lhs.2, alpha: &lhs.3)
        other.getRed(&rhs.0, green: &rhs.1, blue: &rhs.2, alpha: &rhs.3)
        return UIColor(
            red: lhs.0 + (rhs.0 - lhs.0) * value,
            green: lhs.1 + (rhs.1 - lhs.1) * value,
            blue: lhs.2 + (rhs.2 - lhs.2) * value,
            alpha: lhs.3 + (rhs.3 - lhs.3) * value
        )
    }
}
