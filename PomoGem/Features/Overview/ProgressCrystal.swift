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
        let minutes = grams / Constants.Mass.gramsPerMinute
        guard minutes >= 60 else { return "\(minutes)分" }
        let hours = minutes / 60
        let remainder = minutes % 60
        let hourText = hours.formatted(.number.grouping(.automatic))
        return remainder == 0
            ? "\(hourText)時間"
            : "\(hourText)時間\(remainder)分"
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
    /// Grams the destination crystal holds (its rung follows grams, D8);
    /// defaults to its pebble count of 25-minute gems.
    var destinationGrams: Int? = nil
    /// The destination's own colours, as Home shows the same object: the
    /// lifetime fan for the time core (`JarLifetimeCorePresentation`), the
    /// crystal's colour mix for a ×N. Empty falls back to `colorHex`.
    var colorShares: [GemColorShare] = []

    private var destinationShares: [GemColorShare] {
        colorShares.isEmpty ? [GemColorShare(hex: colorHex, fraction: 1)] : colorShares
    }

    /// The source slots take the destination's colours in proportion (a
    /// ×10 of six coral and four blue gems shows six coral and four blue
    /// sources), laid out in share order from 12 o'clock.
    static func sourceHexes(shares: [GemColorShare], count: Int) -> [String] {
        let valid = shares.filter { $0.fraction > 0 }
        guard count > 0, !valid.isEmpty else { return [] }
        let total = valid.reduce(0) { $0 + $1.fraction }
        var counts = valid.map { Int(($0.fraction / total * Double(count)).rounded(.down)) }
        let order = valid.indices.sorted {
            let a = valid[$0].fraction / total * Double(count) - Double(counts[$0])
            let b = valid[$1].fraction / total * Double(count) - Double(counts[$1])
            return a == b ? $0 < $1 : a > b
        }
        var remaining = count - counts.reduce(0, +)
        var cursor = 0
        while remaining > 0 {
            counts[order[cursor % order.count]] += 1
            remaining -= 1
            cursor += 1
        }
        return zip(valid, counts).flatMap { Array(repeating: $0.0.hex, count: $0.1) }
    }

    private var sourceHexes: [String] {
        Self.sourceHexes(shares: destinationShares, count: state.slotCount)
    }

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

                // A quiet progress arc (α ≤ 0.3): no spokes and no bright
                // wheel, so ten gems around one never read as a roulette
                // (Docs/GemExperienceDesign.md §7.14).
                Circle()
                    .trim(from: 0, to: CGFloat(state.progressFraction ?? 0))
                    .stroke(
                        Color.white.opacity(colorSchemeContrast == .increased ? 0.62 : 0.30),
                        style: StrokeStyle(lineWidth: max(1, dimension * 0.008), lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: baseRadius * 2, height: baseRadius * 2)

                ForEach(0 ..< state.slotCount, id: \.self) { index in
                    let angle = Angle.degrees(
                        -90 + Double(index) * 360 / Double(max(1, state.slotCount))
                    )
                    let isLit = state.litSlotCount.map { index < $0 } ?? false
                    let isLatest = state.emphasizesLatestSource
                        && index == state.latestLitSlotIndex

                    FusionOrbitSourceGem(
                        colorHex: index < sourceHexes.count ? sourceHexes[index] : colorHex,
                        variant: index,
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
                    if state.destinationMaterialized, scale == .chronicle {
                        // The Overview's lifetime camera: the time core.
                        LifetimeCorePrism(
                            colorShares: destinationShares,
                            level: state.destinationLevel
                        )
                    } else if state.destinationMaterialized {
                        // A formed crystal: the Home jar's ×N art.
                        GemArtworkStone(
                            spec: GemArtworkStone.aggregateSpec(
                                grams: destinationGrams
                                    ?? state.destinationPebbleCount * Constants.Mass.measuredPebbleGrams,
                                colors: destinationShares,
                                variant: state.destinationLevel
                            )
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

/// One source gem of a ten-to-one carry: the Home jar's own loose-gem art.
/// A waiting slot is the same stone, colourless and faint.
private struct FusionOrbitSourceGem: View {
    let colorHex: String
    let variant: Int
    let isLit: Bool
    let isLatest: Bool
    let highContrast: Bool

    var body: some View {
        ZStack {
            GemArtworkStone(
                spec: GemArtworkStone.looseSpec(hex: colorHex, variant: variant),
                glowHex: isLit ? colorHex : nil,
                glowOpacity: 0.36,
                // A waiting slot is colourless: it belongs to no theme yet.
                themeMarks: isLit ? nil : false
            )
            .saturation(isLit ? 1 : 0)
            .opacity(isLit ? 1 : (highContrast ? 0.70 : 0.45))

            if isLatest {
                Circle()
                    .stroke(Color.white.opacity(0.74), lineWidth: 0.8)
                    .padding(-4)
            }
        }
    }
}

/// 「積み上がりの光」 drawn as a gem bed: small faceted crystal chips that
/// lie behind the physics bodies (Docs/EngagementArchitecture.md §3.2).
///
/// The only inputs are lifetime study grams and the lifetime mass-weighted
/// theme mix (the same fan as the time core). Body count, decimal digits,
/// rarity and fusion timing cannot reach it, so ten bodies fusing into one
/// leave the bed exactly as it was, and Screen Time obstacles (no study
/// mass, no theme) never feed it. Growth is logarithmic and capped.
struct JarGemBedState: Equatable, Sendable {
    let totalGrams: Int
    /// 0…1 share of the capped height (0 at or below 250 g).
    let growthFraction: Double
    /// 0…`JarGemBedPresentation.heightBucketCount`; one baked texture each.
    let heightBucket: Int
    /// The twenty 5 % colour slots of the lifetime fan (chip colours).
    let slotHexes: [String]

    var isVisible: Bool { heightBucket > 0 }

    /// Bed height inside a jar interior of `interiorHeight` points. Nothing
    /// ever rises above `JarGemBedPresentation.capFraction` of it, so the
    /// foreground keeps its free space.
    func height(interiorHeight: CGFloat) -> CGFloat {
        let cap = max(0, interiorHeight) * JarGemBedPresentation.capFraction
        return (cap * CGFloat(heightBucket) / CGFloat(JarGemBedPresentation.heightBucketCount)).rounded()
    }
}

enum JarGemBedPresentation {
    /// Up to 250 g (one ordinary focus) the jar keeps its ordinary glow.
    static let baselineGrams = JarAccumulationPresencePresentation.baselineGrams
    /// The same distant ceiling as the accumulation presence: a million
    /// ordinary focuses fill the bed to its cap.
    static let saturationGrams = JarAccumulationPresencePresentation.saturationGrams
    /// Highest share of the jar interior the bed may cover.
    static let capFraction: CGFloat = 0.18
    static let heightBucketCount = 24

    static func state(totalGrams rawTotalGrams: Int, colorShares: [GemColorShare]) -> JarGemBedState {
        let totalGrams = max(0, rawTotalGrams)
        let slots = GemArtwork.coreSlotHexes(shares: colorShares)
        guard totalGrams > baselineGrams else {
            return JarGemBedState(totalGrams: totalGrams, growthFraction: 0, heightBucket: 0, slotHexes: slots)
        }
        // Six decades from one focus to the cap, then a square root so the
        // first kilograms already read as a bed (3.75 kg ≈ 44 %, 250 kg ≈
        // 71 %, 2.5 t ≈ 82 %). Monotone, and never above 1.
        let decades = log10(Double(saturationGrams) / Double(baselineGrams))
        let progress = min(1, max(0, log10(Double(totalGrams) / Double(baselineGrams)) / decades))
        let growth = progress.squareRoot()
        let bucket = min(heightBucketCount, max(1, Int((growth * Double(heightBucketCount)).rounded(.up))))
        return JarGemBedState(
            totalGrams: totalGrams,
            growthFraction: growth,
            heightBucket: bucket,
            slotHexes: slots
        )
    }

    /// The bed to show while the projection may still be incomplete. A
    /// provisional projection (CloudKit verification pending, or a local
    /// page that is only a lower bound) counts fewer grams than the store
    /// holds, so it may only ever raise the bed: the bed that is already on
    /// screen stays until a verified projection says otherwise. Once the
    /// projection is verified the bed follows it exactly (it is lower only
    /// when the person really deleted records, §9.1).
    static func displayed(
        current: JarGemBedState,
        shown: JarGemBedState?,
        isProvisional: Bool
    ) -> JarGemBedState {
        guard isProvisional, let shown, shown.heightBucket > current.heightBucket else {
            return current
        }
        return shown
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
                    // "N巡" reads at a glance; the long-term milestone traces
                    // moved to the engraved marks on the jar's copper collar.
                    HStack(spacing: 5) {
                        Text(compactCycleCount)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.9))
                        Circle()
                            .fill(Color(hex: colorHex))
                            .frame(width: 6, height: 6)
                    }
                    .padding(.horizontal, 9)
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

    /// #FFC27A / #FF9E6B / #FFE3B0 and a cool #8ACBFF accent.
    private static let bokehGold = Color(red: 1, green: 0.761, blue: 0.478)
    private static let bokehAmber = Color(red: 1, green: 0.620, blue: 0.420)
    private static let bokehPeach = Color(red: 1, green: 0.890, blue: 0.690)
    private static let bokehCool = Color(red: 0.541, green: 0.796, blue: 1)

    private var memoryParticleCount: Int {
        min(40, max(12, Int((12 + state.presenceFraction * 28).rounded())))
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
            // Denser than the lifetime memory layer: the current cycle is
            // the warm, lit volume the gems rest in.
            particleCanvas(
                count: 40,
                opacityScale: opacityScale,
                whiteSparkInterval: 7
            )
        }
        // A feathered (24 pt) top edge: the cycle rises like light, never as
        // a hard seam across the core or the numbers.
        .mask(alignment: .bottom) {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: fraction > 0 ? 24 : 0)
                Rectangle()
                    .frame(height: max(0, size.height * CGFloat(fraction) - 12))
            }
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
                // Coprime strides (moduli larger than any count, so no two
                // specks share a position) spread points reproducibly without
                // a random seed or changing positions between renders.
                let xUnit = (Double((index * 37 + 17) % 107) + 0.5) / 108
                let heightUnit = (Double((index * 53 + 29) % 109) + 0.5) / 110
                // Gold dust rises from the pile: 60 % in the lowest 35 % of
                // the field, 30 % in the middle band, 10 % above.
                let heightFromBottom: Double
                if heightUnit < 0.6 {
                    heightFromBottom = heightUnit / 0.6 * 0.35
                } else if heightUnit < 0.9 {
                    heightFromBottom = 0.35 + (heightUnit - 0.6) / 0.3 * 0.35
                } else {
                    heightFromBottom = 0.70 + (heightUnit - 0.9) / 0.1 * 0.30
                }
                let yUnit = 1 - heightFromBottom
                // Out-of-focus bokeh: 2–7 pt soft discs, warm with one in ten
                // cool, as in a lit showcase.
                let diameter = CGFloat(2 + (index * 7) % 6)
                let alpha = (0.25 + Double((index * 11) % 12) / 11 * 0.55) * opacityScale
                let rect = CGRect(
                    x: size.width * CGFloat(xUnit) - diameter / 2,
                    y: size.height * CGFloat(yUnit) - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                let tone: Color
                switch index % 10 {
                case 0: tone = Self.bokehCool
                case 2, 5, 8: tone = Self.bokehAmber
                case 3, 7: tone = Self.bokehPeach
                default: tone = Self.bokehGold
                }
                let center = CGPoint(x: rect.midX, y: rect.midY)
                context.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: tone.opacity(min(1, alpha * 1.25)), location: 0),
                            .init(color: tone.opacity(alpha * 0.75), location: 0.45),
                            .init(color: tone.opacity(0), location: 1)
                        ]),
                        center: center,
                        startRadius: 0,
                        endRadius: diameter / 2
                    )
                )

                if index.isMultiple(of: whiteSparkInterval) {
                    let spark = rect.insetBy(dx: diameter * 0.34, dy: diameter * 0.34)
                    context.fill(
                        Path(ellipseIn: spark),
                        with: .color(Color.white.opacity(min(0.92, alpha + 0.26)))
                    )
                }
            }
        }
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

    /// Grams under their colours: a root crystal (its colour mix) or a
    /// loose gem (one colour).
    struct ColorContribution: Equatable, Sendable {
        let grams: Int
        let colorMix: [StratumColorFraction]

        init(grams: Int, colorMix: [StratumColorFraction]) {
            self.grams = grams
            self.colorMix = colorMix
        }

        init(grams: Int, hex: String) {
            self.init(grams: grams, colorMix: [StratumColorFraction(hex: hex, fraction: 1)])
        }
    }

    /// The lifetime core's colour weights: every root's grams split by its
    /// colour mix plus every loose gem's grams. Home, the Overview and the
    /// share cards all read the core's fan from here, so the same core is
    /// the same colours everywhere. Aggregate mixes are count-weighted, so
    /// the fan is "おおよそ", never a mass breakdown.
    static func colorWeights(_ contributions: [ColorContribution]) -> [String: Double] {
        var weights: [String: Double] = [:]
        for contribution in contributions {
            let grams = Double(max(0, contribution.grams))
            for share in contribution.colorMix {
                weights[share.hex, default: 0] += grams * max(0, share.fraction)
            }
        }
        return weights
    }

    /// The weights as shares, largest first (ties by hex).
    static func colorShares(weights: [String: Double]) -> [GemColorShare] {
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return [] }
        return weights
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .map { GemColorShare(hex: $0.key, fraction: $0.value / total) }
    }

    static func colorShares(_ contributions: [ColorContribution]) -> [GemColorShare] {
        colorShares(weights: colorWeights(contributions))
    }

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

/// Where the time core, its orbit and its labels sit on the jar stage.
///
/// Pure geometry (stage coordinates, y down). The Home HUD's measured bottom
/// edge bounds the top. The orbit column (stone, rings, markers) is drawn
/// behind the scene, so it stays above the gem bed's top edge; the label
/// block below it is drawn in front of the scene, so it has to stay above
/// the gem bed and the resting gems under it. Neither the orbit nor its
/// diamond markers can cross the HUD or the core's own labels. When the
/// band is short (large text, a short stage, a tall bed) the extra orbits
/// close up first, then the orbit tightens toward the stone, then the stone
/// gives way a little (to 0.72) so the markers stay, then the markers hide
/// (the stone may give way again so the ring stays), and last the orbit
/// itself; a band too short for even the bare stone shrinks it to 0.65, and
/// below that the core is buried.
struct JarLifetimeCoreLayout: Equatable {
    let centerY: CGFloat
    let orbitRadius: CGFloat
    let extraOrbitSpacing: CGFloat
    let showsOrbit: Bool
    let showsMarkers: Bool
    /// Highest and lowest drawn points of the stone, rings and markers.
    let columnTop: CGFloat
    let columnBottom: CGFloat
    /// Top of the label block (name plate and progress card).
    let labelTop: CGFloat
    /// Scale of the stone (and its halo) when even the bare stone does not
    /// fit the band: 1 normally, never below `minimumStoneScale`.
    var stoneScale: CGFloat = 1
    /// True when the column cannot fit even at `minimumStoneScale`: the
    /// core is buried, and its labels step behind the scene with it.
    var overflows = false

    /// Double-diamond orbit slot (outer square side).
    static let markerSize: CGFloat = 12
    static let hudGap: CGFloat = 8
    static let labelGap: CGFloat = 6
    /// Stone radius as a share of the core frame (the bake keeps a margin).
    static let stoneRadiusFactor: CGFloat = 0.46
    /// Without an overlaid HUD the column starts below the neck and 巡 pill.
    static let topFractionWithoutHUD: CGFloat = 0.16
    /// The stone shrinks to fit a band too short for it, down to this.
    static let minimumStoneScale: CGFloat = 0.65
    /// How far the stone may shrink to keep its orbit (and markers).
    static let orbitStoneScale: CGFloat = 0.72

    /// - Parameters:
    ///   - bottomLimit: lowest y of the orbit column (the gem bed's top).
    ///   - labelBottomLimit: lowest y of the label block; `nil` keeps the
    ///     labels above `bottomLimit` as well.
    static func resolve(
        stageHeight: CGFloat,
        core: CGFloat,
        orbitCount: Int,
        topClearance: CGFloat?,
        bottomLimit: CGFloat?,
        labelBottomLimit: CGFloat? = nil,
        labelHeight: CGFloat
    ) -> JarLifetimeCoreLayout {
        let top = topClearance.map { $0 + hudGap } ?? stageHeight * topFractionWithoutHUD
        let bottom = min(bottomLimit ?? stageHeight - 16, stageHeight)
        let labelBottom = min(labelBottomLimit ?? bottom, stageHeight)
        let columnBudget = min(
            bottom - top,
            labelBottom - top - labelGap - max(0, labelHeight)
        )
        let stone = core * stoneRadiusFactor
        let rings = CGFloat(max(1, orbitCount) - 1)
        let markerHalf = markerSize / 2
        let nominalRadius = core * 1.075
        let nominalSpacing = core * 0.17

        func halfHeight(radius: CGFloat, spacing: CGFloat, markers: Bool) -> CGFloat {
            radius + rings * spacing + (markers ? markerHalf : 1)
        }

        var radius = nominalRadius
        var spacing = nominalSpacing
        var markers = true
        var orbit = true
        var stoneScale: CGFloat = 1
        if 2 * halfHeight(radius: radius, spacing: spacing, markers: true) > columnBudget {
            // 1. Close up the extra orbits, 2. tighten the main orbit while
            // its markers stay clear of the stone.
            spacing = min(nominalSpacing, 5)
            radius = min(nominalRadius, columnBudget / 2 - markerHalf - rings * spacing)
            if radius < stone + markerHalf + 3 {
                // 2b. The stone gives way a little (down to
                // `orbitStoneScale`) so the progress markers stay.
                let fitting = (radius - markerHalf - 3) / max(stone, 1)
                if fitting >= orbitStoneScale {
                    stoneScale = fitting
                } else {
                    // 3. Hide the markers at the same radius (the ring and
                    // its lit arc remain), so the orbit never jumps outward.
                    markers = false
                    let ringFitting = (radius - 3) / max(stone, 1)
                    if ringFitting >= 1 {
                        stoneScale = 1
                    } else if ringFitting >= orbitStoneScale {
                        stoneScale = ringFitting
                    } else {
                        // 4. No room for any orbit: the stone alone.
                        orbit = false
                        stoneScale = 1
                    }
                }
            }
        }
        // 5. Not even the bare stone fits: it shrinks to the band (never
        // below `minimumStoneScale`); below that the core is buried.
        var overflows = false
        if !orbit, 2 * stone > columnBudget {
            let fitting = columnBudget / max(2 * stone, 1)
            stoneScale = max(minimumStoneScale, fitting)
            overflows = fitting < minimumStoneScale
        }
        let half = orbit ? halfHeight(radius: radius, spacing: spacing, markers: markers) : stone * stoneScale
        let slack = max(0, columnBudget - 2 * half)
        let columnTop = top + slack / 2
        let centerY = columnTop + half
        return JarLifetimeCoreLayout(
            centerY: centerY,
            orbitRadius: orbit ? radius : 0,
            extraOrbitSpacing: orbit ? spacing : 0,
            showsOrbit: orbit,
            showsMarkers: orbit && markers,
            columnTop: columnTop,
            columnBottom: centerY + half,
            labelTop: centerY + half + labelGap,
            stoneScale: stoneScale,
            overflows: overflows
        )
    }
}

/// Lowest stage y (SwiftUI, y down) of the time core's label block, which
/// is drawn in front of the scene. The block never covers the gem bed (its
/// chips would show through the card and dim 11 pt text) nor the resting
/// gems under it:
/// - `floor`: one floor row of gems above the floor, and 6 pt above the
///   bed's top edge, whichever is higher on screen;
/// - `abovePile`: also 6 pt above the highest settled body under the
///   labels (`JarScene.settledPileTop`, 0 when that span is clear).
struct JarLifetimeCoreLabelLimits: Equatable {
    let floor: CGFloat
    let abovePile: CGFloat

    static let clearance: CGFloat = 6

    static func resolve(
        stageHeight: CGFloat,
        floorY: CGFloat,
        bedTop: CGFloat,
        pileTop: CGFloat
    ) -> JarLifetimeCoreLabelLimits {
        let floorRow = stageHeight - floorY - Constants.Jar.measuredRadius * 2 - 7
        let floor = min(floorRow, bedTop - clearance)
        let pile = pileTop > 0 ? stageHeight - pileTop - clearance : floor
        return JarLifetimeCoreLabelLimits(floor: floor, abovePile: min(floor, pile))
    }
}

/// A noninteractive optical layer behind the SpriteKit bottle. The recent
/// physical stones remain touchable in front; this centre makes compressed
/// lifetime effort legible instead of letting higher tiers become a pile of
/// similarly weighted discs.
///
/// Time core v3 (Docs/GemExperienceDesign.md §7.9): a luminous radial
/// brilliant painted by the approximate theme shares, a soft bloom that
/// hugs its girdle, a copper dashed orbit with double-diamond slots (their
/// meaning is unchanged: `litOrbitSlotCount`), and the name plate with the
/// progress card below the orbit (`JarLifetimeCoreLayout`). Growth never
/// stalls: the stone grows to 0.26 of the jar width, then a second orbit
/// (250 kg), a crown of lights (2.5 t) and a third orbit (25 t) appear.
struct JarLifetimeCoreBackdrop: View {
    let state: JarLifetimeCoreState
    let colorHex: String
    var colorShares: [GemColorShare] = []
    /// Measured bottom edge of an overlaid HUD at the top of the stage
    /// (Home); the orbit column stays below it.
    var topClearance: CGFloat?
    /// Stage y the orbit column stays above: the gem bed's top edge, which
    /// the scene draws in front of this layer.
    var bottomLimit: CGFloat?
    /// Stage y the label block (`JarLifetimeCoreLabels`, drawn in front of
    /// the scene) stays above; `nil` keeps it above `bottomLimit`.
    var labelBottomLimit: CGFloat?
    /// Measured height of the label block.
    var labelHeight: CGFloat = JarLifetimeCoreBackdrop.estimatedLabelHeight

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var breathing = false

    /// Name plate + two-line card before the first measurement.
    static let estimatedLabelHeight: CGFloat = 56

    /// Rose-gold orbit tone (#D9967A) from the reference mood (not a reward colour).
    static let orbitCopper = Color(red: 0.851, green: 0.588, blue: 0.478)

    private var shares: [GemColorShare] {
        GemArtwork.quantizedCoreShares(
            colorShares.isEmpty ? [GemColorShare(hex: colorHex, fraction: 1)] : colorShares
        )
    }

    /// Core diameter as a share of the jar width: 0.24 at birth, 0.25 at the
    /// second stage, 0.26 from the third; never above 96 pt (EA: the core
    /// never covers the bodies that really move).
    static func coreDiameter(jarWidth: CGFloat, level: Int) -> CGFloat {
        let factor: CGFloat = level >= 3 ? 0.26 : (level == 2 ? 0.25 : 0.24)
        return min(96, max(1, jarWidth) * factor)
    }

    /// Orbits drawn around the core: one at birth, two from 250 kg (level
    /// 3), three from 25 t (level 5).
    static func orbitCount(level: Int) -> Int {
        level >= 5 ? 3 : (level >= 3 ? 2 : 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let jarWidth = max(1, proxy.size.width - Constants.Jar.horizontalMargin * 2)
            let core = Self.coreDiameter(jarWidth: jarWidth, level: state.coreLevel)
            let orbitCount = Self.orbitCount(level: state.coreLevel)
            let layout = JarLifetimeCoreLayout.resolve(
                stageHeight: proxy.size.height,
                core: core,
                orbitCount: orbitCount,
                topClearance: topClearance,
                bottomLimit: bottomLimit,
                labelBottomLimit: labelBottomLimit,
                labelHeight: labelHeight
            )
            let orbitDiameter = layout.orbitRadius * 2
            // The stone (and its light) shrinks only when even the bare
            // stone does not fit the band; the orbit keeps its own radius.
            let stone = core * layout.stoneScale
            let haloColor = Color(uiColor: GemArtwork.coreHaloColor(shares: shares))
            let lobes = GemArtwork.coreHaloLobeColors(shares: shares)
            let rimColor = Color(uiColor: GemArtwork.coreRimGlowColor(shares: shares))
            let quantized = shares

            ZStack {
                // Broad, soft bloom that seats the core in the jar's light.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                haloColor.opacity(reduceTransparency ? 0.10 : 0.24),
                                PomoGemTheme.auroraViolet.opacity(reduceTransparency ? 0.02 : 0.05),
                                .clear
                            ],
                            center: .center,
                            startRadius: 3,
                            endRadius: stone * 1.25
                        )
                    )
                    .frame(width: stone * 2.5, height: stone * 2.5)

                if layout.showsOrbit {
                    ForEach(1 ..< orbitCount, id: \.self) { index in
                        let diameter = orbitDiameter + CGFloat(index) * layout.extraOrbitSpacing * 2
                        Circle()
                            .stroke(
                                Self.orbitCopper.opacity(colorSchemeContrast == .increased ? 0.62 : 0.30),
                                style: StrokeStyle(lineWidth: 0.8, dash: [2, 6])
                            )
                            .frame(width: diameter, height: diameter)
                    }

                    orbit(diameter: orbitDiameter, shares: quantized, showsMarkers: layout.showsMarkers)
                }

                // Halo in two lobes: the left half's colour leaves the left
                // side, the right half's the right (10 % aurora violet),
                // α0.45 out to about 1.35R — light, not a neon ring.
                ForEach(Array([(lobes.left, CGFloat(-1)), (lobes.right, CGFloat(1))].enumerated()), id: \.offset) { _, lobe in
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(uiColor: lobe.0).opacity(reduceTransparency ? 0.20 : 0.45),
                                    Color(uiColor: lobe.0).opacity(reduceTransparency ? 0.08 : 0.20),
                                    .clear
                                ],
                                center: .center,
                                startRadius: stone * 0.30,
                                endRadius: stone * 0.70
                            )
                        )
                        .frame(width: stone * 1.15, height: stone * 1.40)
                        .offset(x: lobe.1 * stone * 0.16)
                }

                // Girdle bloom: pale light hugging the stone's edge.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                rimColor.opacity(reduceTransparency ? 0.34 : 0.95),
                                rimColor.opacity(reduceTransparency ? 0.12 : 0.34),
                                .clear
                            ],
                            center: .center,
                            startRadius: stone * 0.44,
                            endRadius: stone * 0.62
                        )
                    )
                    .frame(width: stone * 1.24, height: stone * 1.24)

                // The unquantised fan: the core's marks (Differentiate
                // Without Color) tell theme arcs from the mixed その他.
                LifetimeCorePrism(
                    colorShares: colorShares.isEmpty ? [GemColorShare(hex: colorHex, fraction: 1)] : colorShares,
                    level: state.coreLevel
                )
                    .frame(width: stone, height: stone)
                    .scaleEffect(breathing ? 1.02 : 1)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .position(x: proxy.size.width / 2, y: layout.centerY)
        }
        // Reduce Transparency must make the summary more solid, not fainter.
        .opacity(reduceTransparency ? 1 : 0.96)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .onAppear { updateMotion() }
        .onChange(of: reduceMotion) { _, _ in updateMotion() }
    }

    /// Copper dashed orbit (α0.55, 1 pt, [3, 5]) with double-diamond slots
    /// (outer 12 pt, inner 5 pt). Lit slots take the share colour of their
    /// position and a white rim; the lit arc is drawn solid. Without room
    /// for the markers the ring and its lit arc still show the progress.
    private func orbit(diameter: CGFloat, shares: [GemColorShare], showsMarkers: Bool) -> some View {
        let lit = state.litOrbitSlotCount
        let slotCount = JarLifetimeCorePresentation.orbitSlotCount
        let radius = diameter / 2
        let litFraction = CGFloat(min(max(lit ?? 0, 0), slotCount)) / CGFloat(max(slotCount, 1))
        return ZStack {
            Circle()
                .stroke(
                    Self.orbitCopper.opacity(colorSchemeContrast == .increased ? 0.85 : 0.55),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 5])
                )
                .frame(width: diameter, height: diameter)
            if litFraction > 0 {
                Circle()
                    .trim(from: 0, to: max(0, litFraction - 0.5 / CGFloat(slotCount)))
                    .stroke(Self.orbitCopper.opacity(0.8), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: diameter, height: diameter)
            }
            if showsMarkers {
                ForEach(0 ..< slotCount, id: \.self) { index in
                    let angle = Angle.degrees(-90 + Double(index) * 360 / Double(max(slotCount, 1)))
                    let isLit = lit.map { index < $0 } ?? false
                    let slotColor = Color(hex: Self.shareColorHex(
                        shares: shares,
                        position: (Double(index) + 0.5) / Double(max(slotCount, 1))
                    ))
                    // Lit slots keep the full double diamond; the waiting
                    // ones recede (outer 8 pt, α0.25) so the ring reads as
                    // progress, not as a dial of equal marks. Meaning and
                    // count are unchanged (`litOrbitSlotCount`).
                    let increased = colorSchemeContrast == .increased
                    let outer: CGFloat = isLit || increased ? 12 : 8
                    ZStack {
                        DiamondSlot()
                            .fill(PomoGemTheme.background.opacity(isLit ? 0.55 : 0.30))
                            .frame(width: outer, height: outer)
                        DiamondSlot()
                            .stroke(
                                isLit
                                    ? Color.white.opacity(0.85)
                                    : Self.orbitCopper.opacity(increased ? 0.95 : 0.25),
                                lineWidth: increased ? 1.3 : 1
                            )
                            .frame(width: outer, height: outer)
                        DiamondSlot()
                            .fill(isLit ? slotColor : Self.orbitCopper.opacity(increased ? 0.30 : 0.16))
                            .overlay {
                                DiamondSlot()
                                    .stroke(
                                        isLit ? Color.white.opacity(0.9) : Self.orbitCopper.opacity(increased ? 0.6 : 0.25),
                                        lineWidth: 0.6
                                    )
                            }
                            .frame(width: isLit || increased ? 5 : 3.5, height: isLit || increased ? 5 : 3.5)
                    }
                    .shadow(color: isLit ? slotColor.opacity(0.85) : .clear, radius: isLit ? 5 : 0)
                    .frame(width: JarLifetimeCoreLayout.markerSize, height: JarLifetimeCoreLayout.markerSize)
                    .offset(
                        x: CGFloat(cos(angle.radians)) * radius,
                        y: CGFloat(sin(angle.radians)) * radius
                    )
                }
            }
        }
    }

    /// The share colour at a clockwise position (0…1) of the 20-slot fan.
    static func shareColorHex(shares: [GemColorShare], position: Double) -> String {
        var cursor = 0.0
        for share in shares {
            cursor += share.fraction
            if position < cursor { return share.hex }
        }
        return shares.last?.hex ?? Constants.Color.textMute
    }

    /// Breathing is 1.0 ↔ 1.02 over 4 s on the sharp stone only (no blurred
    /// layer animates). Off with Reduce Motion and in UI-test mode.
    private func updateMotion() {
        breathing = false
        guard !reduceMotion,
              !LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess
        else { return }
        withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
            breathing = true
        }
    }
}

/// The time core's name plate and progress card. Normally drawn in front of
/// the SpriteKit scene (like the Home HUD), so the gem bed cannot hide them;
/// when a settled pile reaches them the owner draws them behind the scene
/// instead, as the core itself is buried. Placed by the same
/// `JarLifetimeCoreLayout` as the core: directly under the orbit column,
/// never inside it.
struct JarLifetimeCoreLabels: View {
    let state: JarLifetimeCoreState
    var topClearance: CGFloat?
    var bottomLimit: CGFloat?
    var labelBottomLimit: CGFloat?
    /// Measured size of the block (the height feeds the layout, the width
    /// tells the owner which part of the pile could cover it).
    @Binding var measuredSize: CGSize

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    /// Dynamic Type factor for the small label text, capped at 1.3 so the
    /// block stays inside the jar (larger sizes fold the orbit first).
    @ScaledMetric(relativeTo: .caption2) private var dynamicTextScale: CGFloat = 1

    private var textScale: CGFloat { min(max(dynamicTextScale, 1), 1.3) }

    /// The layout the core and its labels share on a stage of `stageSize`.
    static func layout(
        stageSize: CGSize,
        state: JarLifetimeCoreState,
        topClearance: CGFloat?,
        bottomLimit: CGFloat?,
        labelBottomLimit: CGFloat?,
        labelHeight: CGFloat
    ) -> JarLifetimeCoreLayout {
        let jarWidth = max(1, stageSize.width - Constants.Jar.horizontalMargin * 2)
        return JarLifetimeCoreLayout.resolve(
            stageHeight: stageSize.height,
            core: JarLifetimeCoreBackdrop.coreDiameter(jarWidth: jarWidth, level: state.coreLevel),
            orbitCount: JarLifetimeCoreBackdrop.orbitCount(level: state.coreLevel),
            topClearance: topClearance,
            bottomLimit: bottomLimit,
            labelBottomLimit: labelBottomLimit,
            labelHeight: labelHeight
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = Self.layout(
                stageSize: proxy.size,
                state: state,
                topClearance: topClearance,
                bottomLimit: bottomLimit,
                labelBottomLimit: labelBottomLimit,
                labelHeight: measuredSize.height
            )
            labels
                .onGeometryChange(for: CGSize.self) { geometry in
                    geometry.size
                } action: { size in
                    measuredSize = size
                }
                .position(x: proxy.size.width / 2, y: layout.labelTop + measuredSize.height / 2)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var labels: some View {
        VStack(spacing: 4) {
            Text(state.title)
                .font(.system(size: 11 * textScale, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    PomoGemTheme.raised.opacity(
                        reduceTransparency || colorSchemeContrast == .increased ? 0.98 : 0.94
                    ),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .stroke(
                            .white.opacity(colorSchemeContrast == .increased ? 0.72 : 0.20),
                            lineWidth: colorSchemeContrast == .increased ? 1.2 : 0.7
                        )
                }

            VStack(spacing: 1) {
                Text(state.progressLabel)
                    .font(.system(size: 9.5 * textScale, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if let nextFusionLabel = state.nextFusionLabel {
                    Text(nextFusionLabel)
                        .font(.system(size: 8.5 * textScale, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.66))
                }
            }
            .lineLimit(1)
            .foregroundStyle(.white.opacity(0.80))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                PomoGemTheme.raised.opacity(reduceTransparency || colorSchemeContrast == .increased ? 0.98 : 0.94),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .fixedSize()
    }
}

/// The one compressed lifetime core, drawn as a radial brilliant. Facets
/// are baked once by `GemArtwork` (Core Graphics) at a fixed size and cached
/// per (quantised shares, level, display scale); SwiftUI only scales the
/// image, so an animated frame never re-renders on the main thread.
private struct LifetimeCorePrism: View {
    let colorShares: [GemColorShare]
    let level: Int

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    init(colorShares: [GemColorShare], level: Int) {
        self.colorShares = colorShares
        self.level = level
    }

    var body: some View {
        let shares = colorShares
        let level = level
        let scale = displayScale
        // Differentiate Without Color: each theme arc carries its mark.
        let marks = GemThemeMark.isEnabled(environment: differentiateWithoutColor)
        HeroArtworkImage(key: GemArtwork.coreImageKey(shares: shares, level: level, scale: scale, themeMarks: marks)) {
            GemArtwork.coreImage(shares: shares, level: level, scale: scale, themeMarks: marks)
        }
    }
}

/// A baked core or vessel image. A cached bake shows at once; a miss bakes
/// off the main thread (576 px of gradients) while the previous image, if
/// any, stays on screen, so a new share fan or level never stalls a frame.
struct HeroArtworkImage: View {
    let key: String
    let bake: @Sendable () -> UIImage

    @State private var baked: UIImage?

    var body: some View {
        Group {
            if let image = GemArtwork.cachedHeroImage(key: key) ?? baked {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(1, contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .accessibilityHidden(true)
        .task(id: key) {
            if let cached = GemArtwork.cachedHeroImage(key: key) {
                baked = cached
                return
            }
            let bake = bake
            baked = await Task.detached(priority: .userInitiated) { bake() }.value
        }
    }
}

/// Before the first 2.5 kg: a colourless vessel where the core will be
/// born. Its ten sectors light up one per 250 g; no colour enters until
/// the core exists. Static (no animation), decorative.
struct JarLifetimeCoreVessel: View {
    let totalGrams: Int
    var topClearance: CGFloat?
    var bottomLimit: CGFloat?
    var labelBottomLimit: CGFloat?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let jarWidth = max(1, proxy.size.width - Constants.Jar.horizontalMargin * 2)
            let core = JarLifetimeCoreBackdrop.coreDiameter(jarWidth: jarWidth, level: 1)
            let lit = min(10, max(0, totalGrams / max(1, Constants.Mass.measuredPebbleGrams)))
            ZStack {
                // A clear crystal from the first day: white light (α0.3 out
                // to 1.3R) around an ice-white stone. Still no theme colour.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(reduceTransparency ? 0.16 : 0.30),
                                Color.white.opacity(reduceTransparency ? 0.06 : 0.10),
                                .clear
                            ],
                            center: .center,
                            startRadius: core * 0.30,
                            endRadius: core * 0.65
                        )
                    )
                    .frame(width: core * 1.3, height: core * 1.3)
                let scale = displayScale
                HeroArtworkImage(key: GemArtwork.vesselImageKey(litFacets: lit, scale: scale)) {
                    GemArtwork.vesselImage(litFacets: lit, scale: scale)
                }
                .frame(width: core * 0.92, height: core * 0.92)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .position(
                x: proxy.size.width / 2,
                // Where the core will be born: the same column as the core.
                y: JarLifetimeCoreLayout.resolve(
                    stageHeight: proxy.size.height,
                    core: core,
                    orbitCount: 1,
                    topClearance: topClearance,
                    bottomLimit: bottomLimit,
                    labelBottomLimit: labelBottomLimit,
                    labelHeight: JarLifetimeCoreBackdrop.estimatedLabelHeight
                ).centerY
            )
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
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

/// The jar's baked gem art as a SwiftUI view (Docs/GemExperienceDesign.md
/// §7.2–7.3): the same body image the Home jar shows, with the
/// screen-fixed light rig (pavilion shade, key light) laid over it and an
/// optional soft halo. One source of art for the fusion sheet, the
/// Overview and the share cards, so a ×10 looks the same everywhere.
struct GemArtworkStone: View {
    let spec: GemArtworkSpec
    var glowHex: String?
    var glowOpacity: Double = 0.42
    /// Differentiate Without Color marks; nil follows the setting (a
    /// colourless waiting slot or an achievement passes false).
    var themeMarks: Bool?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let radius = side / 2
            let sprite = GemArtwork.bodySpriteSize(radius: radius)
            let spec = spec.withThemeMarks(
                themeMarks ?? GemThemeMark.isEnabled(environment: differentiateWithoutColor)
            )
            ZStack {
                if let glowHex {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(hex: glowHex).opacity(reduceTransparency ? glowOpacity * 0.45 : glowOpacity),
                                    Color(hex: glowHex).opacity(reduceTransparency ? glowOpacity * 0.15 : glowOpacity * 0.32),
                                    .clear
                                ],
                                center: .center,
                                startRadius: radius * 0.55,
                                endRadius: radius * 1.35
                            )
                        )
                        .frame(width: side * 1.4, height: side * 1.4)
                }
                Image(uiImage: GemArtwork.bodyImage(for: spec, radius: radius, scale: displayScale))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: sprite.width, height: sprite.height)
                Image(uiImage: GemArtwork.lightRigShadeImage)
                    .resizable()
                    .frame(width: side, height: side)
                Image(uiImage: GemArtwork.lightRigAddImage)
                    .resizable()
                    .frame(width: side, height: side)
                    .blendMode(.plusLighter)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
    }

    /// The Home art of a crystal holding `grams` (rung by contained grams,
    /// never by level: D8).
    static func aggregateSpec(grams: Int, colors: [GemColorShare], variant: Int = 0) -> GemArtworkSpec {
        GemArtworkSpec(
            rung: GemCutLadder.standard.rung(aggregateGrams: grams),
            colors: colors,
            variant: variant % GemArtworkSpec.variantCount,
            isMuted: false,
            showsDashedRing: false
        )
    }

    /// The Home art of one measured loose gem.
    static func looseSpec(hex: String, variant: Int = 0) -> GemArtworkSpec {
        GemArtworkSpec(
            rung: GemCutLadder.standard.loose,
            colors: [GemColorShare(hex: hex, fraction: 1)],
            variant: variant % GemArtworkSpec.variantCount,
            isMuted: false,
            showsDashedRing: false
        )
    }
}

/// The Overview's crystal: the Home jar's own gem art at the rung of the
/// grams it holds (an achievement shows the copper-set step cut), with the
/// "×N" count on the same dark plate as in the jar. It breathes gently and
/// stays still with Reduce Motion.
struct ProgressCrystalGlyph: View {
    let completionCount: Int
    let colorHex: String
    var level = 1
    var showsCount = false
    /// Grams the crystal holds; defaults to `completionCount` 25-minute
    /// gems when unknown.
    var grams: Int? = nil
    var colorShares: [GemColorShare]? = nil
    var isAchievement = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var breath = false

    private var spec: GemArtworkSpec {
        let colors = colorShares.flatMap { $0.isEmpty ? nil : $0 } ?? [GemColorShare(hex: colorHex, fraction: 1)]
        if isAchievement {
            return GemArtworkSpec(
                rung: GemCutLadder.standard.achievement,
                colors: colors,
                variant: 0,
                isMuted: false,
                showsDashedRing: false
            )
        }
        let contained = grams ?? max(1, completionCount) * Constants.Mass.measuredPebbleGrams
        return GemArtworkStone.aggregateSpec(grams: contained, colors: colors, variant: level)
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                GemArtworkStone(spec: spec, glowHex: colorHex, glowOpacity: 0.40, themeMarks: isAchievement ? false : nil)
                    .frame(width: side * 0.80, height: side * 0.80)
                    .scaleEffect(breath ? 1.018 : 0.99)

                if showsCount {
                    // The jar's own count tag (D26): a small engraved copper
                    // tag below the table, the same text as Home.
                    let text = AggregatePresentation.countLabel(completionCount)
                    let fontSize = GemArtwork.countTagFontSize(sceneRadius: side * 0.40)
                    let tag = GemArtwork.countEngravingSize(text: text, fontSize: fontSize, style: .copperTag)
                    Image(uiImage: GemArtwork.countEngravingImage(text: text, fontSize: fontSize, style: .copperTag, scale: displayScale))
                        .resizable()
                        .frame(width: tag.width, height: tag.height)
                        .offset(y: side * 0.40 * PebbleNode.aggregatePlateDrop)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onAppear { updateMotion() }
        .onChange(of: reduceMotion) { _, _ in updateMotion() }
        .accessibilityHidden(true)
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
