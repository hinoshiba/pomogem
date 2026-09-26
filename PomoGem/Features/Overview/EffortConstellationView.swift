import Foundation
import SwiftUI

/// A bounded, read-only point in the long-range effort constellation.
///
/// The live jar remains the tactile view of recent work. These nodes are the
/// same persisted root aggregates seen from farther away, so the overview can
/// feel expansive without inventing progress or loading every historic row.
struct EffortConstellationNode: Identifiable, Equatable, Sendable {
    let id: UUID
    let level: Int
    let pebbleCount: Int
    let grams: Int
    let colorHex: String
    let colorMix: [StratumColorFraction]
    let periodEnd: Date
    let containsRare: Bool

    init(
        id: UUID,
        level: Int,
        pebbleCount: Int,
        grams: Int,
        colorHex: String,
        colorMix: [StratumColorFraction] = [],
        periodEnd: Date,
        containsRare: Bool
    ) {
        self.id = id
        self.level = level
        self.pebbleCount = pebbleCount
        self.grams = grams
        self.colorHex = colorHex
        self.colorMix = colorMix
        self.periodEnd = periodEnd
        self.containsRare = containsRare
    }
}

enum EffortConstellationPresentation {
    static let maximumVisibleNodes = 8

    /// Samples the complete bounded root page across time rather than showing
    /// only the newest roots. Old, middle, and recent effort therefore remain
    /// visible together when a multi-decade account has more roots than fit.
    static func representativeNodes(
        _ values: [EffortConstellationNode],
        maximum: Int = maximumVisibleNodes
    ) -> [EffortConstellationNode] {
        let limit = max(0, maximum)
        guard limit > 0 else { return [] }

        let canonical = Dictionary(grouping: values, by: \.id).values.compactMap { duplicates in
            duplicates.max { lhs, rhs in
                if lhs.pebbleCount == rhs.pebbleCount {
                    return lhs.periodEnd < rhs.periodEnd
                }
                return lhs.pebbleCount < rhs.pebbleCount
            }
        }
        .sorted { lhs, rhs in
            if lhs.periodEnd == rhs.periodEnd { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.periodEnd < rhs.periodEnd
        }

        guard canonical.count > limit else { return canonical }
        guard limit > 1 else { return [canonical[canonical.count - 1]] }

        var selected: [EffortConstellationNode] = []
        var selectedIDs = Set<UUID>()
        for slot in 0 ..< limit {
            let fraction = Double(slot) / Double(limit - 1)
            let index = Int((fraction * Double(canonical.count - 1)).rounded())
            let value = canonical[index]
            if selectedIDs.insert(value.id).inserted { selected.append(value) }
        }

        // Floating-point rounding can theoretically select the same index for
        // very small pages. Fill deterministically while preserving chronology.
        if selected.count < limit {
            for value in canonical where selectedIDs.insert(value.id).inserted {
                selected.append(value)
                if selected.count == limit { break }
            }
            selected.sort { $0.periodEnd < $1.periodEnd }
        }
        return selected
    }

    static func dominantColorHex(
        nodes: [EffortConstellationNode],
        fallback: String = Constants.Color.amberLamp
    ) -> String {
        var weighted: [String: Double] = [:]
        for node in nodes {
            let grams = Double(max(0, node.grams))
            guard grams > 0 else { continue }
            let mix = node.colorMix.isEmpty
                ? [StratumColorFraction(hex: node.colorHex, fraction: 1)]
                : node.colorMix
            for contribution in mix {
                weighted[contribution.hex, default: 0] += grams * max(0, contribution.fraction)
            }
        }
        return weighted.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }.first?.key ?? fallback
    }

    static func coreLevel(totalPebbleCount: Int) -> Int {
        StrataMath.decimalAggregateLevel(forPebbleCount: max(1, totalPebbleCount))
    }

    /// The time core is a persisted decimal form, not a forecast. An exact
    /// count or lower bound of ten proves that at least the first decimal form
    /// exists; only a lower bound below ten keeps the outlined destination.
    static func coreIsMaterialized(
        totalPebbleCount: Int,
        totalGrams: Int? = nil,
        projectionIsLowerBound _: Bool
    ) -> Bool {
        if let totalGrams {
            return max(0, totalGrams) >= EffortProgressPolicy.firstMilestoneGrams
        }
        return totalPebbleCount >= FusionHierarchyPresentation.fanIn
    }

    static func nodeDiameter(level: Int) -> CGFloat {
        min(62, 40 + CGFloat(max(1, level)) * 4)
    }

    /// Current constellation nodes communicate represented effort by mass;
    /// their decimal aggregate level remains a storage/inspection attribute.
    static func nodeDiameter(grams: Int) -> CGFloat {
        let standardUnits = max(
            0.01,
            EffortProgressPolicy.standardUnitEquivalent(totalGrams: grams)
        )
        return min(62, max(30, 40 + CGFloat(log10(standardUnits)) * 5.5))
    }

    static func orbitPosition(
        index: Int,
        count: Int,
        in size: CGSize
    ) -> CGPoint {
        guard count > 0 else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        let angle = -.pi / 2 + (Double(index) / Double(count)) * .pi * 2
        return CGPoint(
            x: size.width / 2 + CGFloat(cos(angle)) * size.width * 0.35,
            y: size.height * 0.46 + CGFloat(sin(angle)) * size.height * 0.29
        )
    }

    static func formattedMass(_ grams: Int) -> String {
        let safe = max(0, grams)
        if safe >= 1_000_000 {
            return String(format: "%.2ft", Double(safe) / 1_000_000)
        }
        if safe >= 1_000 {
            return String(format: safe >= 10_000 ? "%.1fkg" : "%.2fkg", Double(safe) / 1_000)
        }
        return "\(safe)g"
    }

    /// VoiceOver uses the same mass-derived duration horizon as Home. A partial
    /// CloudKit projection is only a lower bound, so it must never announce an
    /// exact fraction or remaining duration that can change as rows arrive.
    static func materializedCoreAccessibilityLabel(
        totalPebbleCount: Int,
        totalGrams: Int,
        projectionIsLowerBound: Bool,
        totalNodeCount: Int,
        visibleNodeCount: Int
    ) -> String {
        var components = [
            "時間の核",
            "集中\(formattedMass(totalGrams))\(projectionIsLowerBound ? "以上" : "")",
            "\(EffortProgressPresentation.formattedStandardUnits(grams: totalGrams))\(projectionIsLowerBound ? "以上" : "")",
            "物理履歴\(totalPebbleCount)粒\(projectionIsLowerBound ? "以上" : "")"
        ]

        if projectionIsLowerBound {
            components.append("進捗を整理中")
        } else if let state = JarLifetimeCorePresentation.state(
            totalPebbleCount: totalPebbleCount,
            totalGrams: totalGrams,
            projectionIsLowerBound: false
        ) {
            components.append(state.progressLabel)
            if let nextFusionLabel = state.nextFusionLabel {
                components.append(nextFusionLabel)
            }
        }

        components.append(
            "表示中のまとまり結晶\(totalNodeCount)個のうち代表\(visibleNodeCount)個を配置"
        )
        components.append("瓶の物理整理：集中\(totalPebbleCount)粒")
        return components.joined(separator: "、")
    }
}

/// A code-native long-range view: one deterministic time core surrounded by a
/// representative set of persisted aggregate roots. Nothing here is a second
/// reward system; it is a different camera distance over the same exact mass.
struct EffortConstellationView: View {
    let nodes: [EffortConstellationNode]
    let totalGrams: Int
    let totalPebbleCount: Int
    let projectionIsLowerBound: Bool
    /// The time core's theme fan, as Home computes it (roots and loose
    /// gems). Empty derives it from the roots alone.
    let coreColorShares: [GemColorShare]
    var onSelect: ((UUID) -> Void)?

    init(
        nodes: [EffortConstellationNode],
        totalGrams: Int,
        totalPebbleCount: Int,
        projectionIsLowerBound: Bool = false,
        coreColorShares: [GemColorShare] = [],
        onSelect: ((UUID) -> Void)? = nil
    ) {
        self.nodes = nodes
        self.totalGrams = totalGrams
        self.totalPebbleCount = totalPebbleCount
        self.projectionIsLowerBound = projectionIsLowerBound
        self.coreColorShares = coreColorShares
        self.onSelect = onSelect
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption2) private var coreLabelTextSize: CGFloat = 11
    @State private var auraExpanded = false

    private var visibleNodes: [EffortConstellationNode] {
        EffortConstellationPresentation.representativeNodes(nodes)
    }

    private var coreColorHex: String {
        EffortConstellationPresentation.dominantColorHex(nodes: nodes)
    }

    private var resolvedCoreColorShares: [GemColorShare] {
        guard coreColorShares.isEmpty else { return coreColorShares }
        return JarLifetimeCorePresentation.colorShares(nodes.map { node in
            JarLifetimeCorePresentation.ColorContribution(
                grams: node.grams,
                colorMix: node.colorMix.isEmpty
                    ? [StratumColorFraction(hex: node.colorHex, fraction: 1)]
                    : node.colorMix
            )
        })
    }

    private var coreIsMaterialized: Bool {
        EffortConstellationPresentation.coreIsMaterialized(
            totalPebbleCount: totalPebbleCount,
            totalGrams: totalGrams,
            projectionIsLowerBound: projectionIsLowerBound
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = CGPoint(x: size.width / 2, y: size.height * 0.46)

            ZStack {
                constellationLines(size: size, center: center)

                destinationOrCore(center: center, in: size)

                ForEach(Array(visibleNodes.enumerated()), id: \.element.id) { index, node in
                    orbitNode(node)
                        .position(
                            EffortConstellationPresentation.orbitPosition(
                                index: index,
                                count: visibleNodes.count,
                                in: size
                            )
                        )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .onAppear { updateMotion() }
        .onChange(of: reduceMotion) { _, _ in updateMotion() }
    }

    private func constellationLines(size: CGSize, center: CGPoint) -> some View {
        Canvas { context, canvasSize in
            let orbitRect = CGRect(
                x: canvasSize.width * 0.10,
                y: canvasSize.height * 0.14,
                width: canvasSize.width * 0.80,
                height: canvasSize.height * 0.64
            )
            context.stroke(
                Path(ellipseIn: orbitRect),
                with: .color(Color(hex: coreColorHex).opacity(0.22)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 7])
            )

            for index in visibleNodes.indices {
                let point = EffortConstellationPresentation.orbitPosition(
                    index: index,
                    count: visibleNodes.count,
                    in: canvasSize
                )
                var ray = Path()
                ray.move(to: center)
                ray.addLine(to: point)
                context.stroke(
                    ray,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(hex: coreColorHex).opacity(0.34),
                            Color.white.opacity(0.05)
                        ]),
                        startPoint: center,
                        endPoint: point
                    ),
                    lineWidth: 0.8
                )
            }

            // Stable dust makes the field feel spatial without representing
            // extra sessions or creating a random-reward affordance.
            for index in 0 ..< 18 {
                let x = CGFloat((index * 47 + 19) % 101) / 101 * canvasSize.width
                let y = CGFloat((index * 71 + 13) % 97) / 97 * canvasSize.height
                let diameter: CGFloat = index.isMultiple(of: 4) ? 2.2 : 1.2
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: x - diameter / 2,
                        y: y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )),
                    with: .color(.white.opacity(index.isMultiple(of: 4) ? 0.34 : 0.16))
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func destinationOrCore(center: CGPoint, in size: CGSize) -> some View {
        let stageDiameter = max(
            1,
            min(240, min(size.width * 0.58, size.height * 0.62))
        )
        let labelWidth = stageDiameter * 0.66
        let labelFontSizeForOffset = min(coreLabelTextSize, max(9, stageDiameter * 0.07))
        // Below the whole orbit, never over the core (the stone is the same
        // baked art as Home's and must stay whole).
        let labelOffset = stageDiameter * 0.5
            + (labelFontSizeForOffset * 1.25 + max(4, stageDiameter * 0.024) * 2) / 2 + 4
        let labelFontSize = min(
            coreLabelTextSize,
            max(9, stageDiameter * 0.07)
        )

        return ZStack {
            FusionOrbitStage(
                state: FusionOrbitStagePresentation.lifetime(
                    totalPebbleCount: totalPebbleCount,
                    totalGrams: totalGrams,
                    projectionIsLowerBound: projectionIsLowerBound
                ),
                colorHex: coreColorHex,
                scale: .chronicle,
                colorShares: resolvedCoreColorShares
            )
            .frame(width: stageDiameter, height: stageDiameter)
            .scaleEffect(auraExpanded ? 1.025 : 0.985)

            HStack(spacing: max(3, stageDiameter * 0.018)) {
                Text(coreIsMaterialized ? "時間の核" : "時間の核の器")
                    .font(.system(size: labelFontSize, weight: .black, design: .rounded))
                    .tracking(0.8)
                Text(
                    coreIsMaterialized
                        ? EffortConstellationPresentation.formattedMass(totalGrams)
                            + (projectionIsLowerBound ? "+" : "")
                        : (
                            projectionIsLowerBound
                                ? "整理中"
                                : EffortProgressPresentation.formattedStandardUnits(
                                    grams: totalGrams
                                )
                        )
                )
                    .font(.system(size: labelFontSize, weight: .heavy, design: .rounded))
                    .monospacedDigit()
            }
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .frame(width: labelWidth)
            .foregroundStyle(.white)
            .padding(.vertical, max(4, stageDiameter * 0.024))
            // The crystal color changes with lifetime subjects, so a shadow
            // cannot guarantee text contrast. Keep the core caption on a
            // deterministic dark optical label instead, below the orbit.
            .background(.black.opacity(0.86), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 0.5))
            .offset(y: labelOffset)
        }
        .position(center)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(
            coreIsMaterialized
                ? "overview.constellation.core"
                : "overview.constellation.destination"
        )
        .accessibilityLabel(
            coreIsMaterialized ? "時間の核" : "最初の時間の核"
        )
        .accessibilityValue(
            coreIsMaterialized
                ? EffortConstellationPresentation.materializedCoreAccessibilityLabel(
                    totalPebbleCount: totalPebbleCount,
                    totalGrams: totalGrams,
                    projectionIsLowerBound: projectionIsLowerBound,
                    totalNodeCount: nodes.count,
                    visibleNodeCount: visibleNodes.count
                )
                : (
                    projectionIsLowerBound
                        ? "最初の結晶までの進捗を整理しています"
                        : "\(EffortProgressPresentation.formattedStandardUnits(grams: totalGrams))、\(EffortProgressPresentation.formattedDuration(grams: totalGrams))。最初の結晶まで、あと\(max(0, 10 - min(9, max(0, totalPebbleCount))))粒です"
                )
        )
    }

    @ViewBuilder
    private func orbitNode(_ node: EffortConstellationNode) -> some View {
        let diameter = EffortConstellationPresentation.nodeDiameter(grams: node.grams)
        let accessibilityLabel = "\(EffortConstellationPresentation.formattedMass(node.grams))、\(EffortProgressPresentation.formattedStandardUnits(grams: node.grams))。瓶の整理単位：\(AggregatePresentation.title(level: node.level))、\(node.pebbleCount)粒分"

        if let onSelect {
            Button {
                onSelect(node.id)
            } label: {
                orbitNodeVisual(node, diameter: diameter)
            }
            .buttonStyle(PomoGemBareButtonStyle())
            .accessibilityIdentifier("overview.constellation.node.\(node.id.uuidString)")
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("ダブルタップで内訳を表示します")
        } else {
            orbitNodeVisual(node, diameter: diameter)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("overview.constellation.node.\(node.id.uuidString)")
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private func orbitNodeVisual(
        _ node: EffortConstellationNode,
        diameter: CGFloat
    ) -> some View {
        ZStack {
            Circle()
                .fill(Color(hex: node.colorHex).opacity(0.13))
                .frame(width: diameter + 13, height: diameter + 13)
                .blur(radius: node.containsRare ? 5 : 2)
            ProgressCrystalGlyph(
                completionCount: node.pebbleCount,
                colorHex: node.colorHex,
                level: node.level,
                showsCount: true,
                grams: node.grams,
                // The crystal's own colour mix, as the Home jar paints it.
                colorShares: GemArtworkSpec.aggregateColors(node.colorMix, fallbackHex: node.colorHex)
            )
            .frame(width: diameter, height: diameter)
        }
        .contentShape(Circle())
    }

    private func updateMotion() {
        // A repeat-forever animation prevents XCTest from receiving an idle
        // notification before its next gesture. Disable only in the explicit
        // Debug UI-test protocol; Release always keeps the production motion.
        guard !reduceMotion,
              !LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess
        else {
            auraExpanded = false
            return
        }
        auraExpanded = false
        withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
            auraExpanded = true
        }
    }
}
