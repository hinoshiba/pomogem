import Foundation

struct StrataPebble: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let y: Double
    let radius: Double
    let colorHex: String
    let grams: Int

    init(
        id: UUID = UUID(),
        y: Double,
        radius: Double = Double(Constants.Jar.measuredRadius),
        colorHex: String,
        grams: Int = Constants.Mass.measuredPebbleGrams
    ) {
        self.id = id
        self.y = y
        self.radius = max(0, radius)
        self.colorHex = colorHex
        self.grams = max(0, grams)
    }
}

struct StratumColorFraction: Equatable, Codable, Sendable {
    let hex: String
    let fraction: Double

    enum CodingKeys: String, CodingKey {
        case hex
        case fraction = "frac"
    }
}

/// A leaf pebble or an existing aggregate expressed without any persistence or
/// SpriteKit dependency. This is the deterministic input to hierarchical
/// aggregation and makes the capacity policy independently testable.
struct AggregateSource: Identifiable, Equatable, Sendable {
    let id: UUID
    let level: Int
    let pebbleCount: Int
    let childAggregateCount: Int
    let grams: Int
    let radius: Double
    let colorMix: [StratumColorFraction]
    let subjectMix: [AggregateSubjectFraction]
    let periodStart: Date
    let periodEnd: Date
    let sessionIDs: [UUID]
    let measuredPebbleCount: Int
    let manualPebbleCount: Int
    let goldPebbleCount: Int
    let prismPebbleCount: Int

    init(
        id: UUID,
        level: Int = 0,
        pebbleCount: Int = 1,
        childAggregateCount: Int = 0,
        grams: Int,
        radius: Double,
        colorMix: [StratumColorFraction],
        subjectMix: [AggregateSubjectFraction],
        periodStart: Date,
        periodEnd: Date,
        sessionIDs: [UUID],
        measuredPebbleCount: Int,
        manualPebbleCount: Int,
        goldPebbleCount: Int,
        prismPebbleCount: Int
    ) {
        self.id = id
        self.level = max(0, level)
        self.pebbleCount = max(0, pebbleCount)
        self.childAggregateCount = max(0, childAggregateCount)
        self.grams = max(0, grams)
        self.radius = max(0, radius)
        self.colorMix = colorMix
        self.subjectMix = subjectMix
        self.periodStart = min(periodStart, periodEnd)
        self.periodEnd = max(periodStart, periodEnd)
        self.sessionIDs = Set(sessionIDs).sorted { $0.uuidString < $1.uuidString }
        self.measuredPebbleCount = max(0, measuredPebbleCount)
        self.manualPebbleCount = max(0, manualPebbleCount)
        self.goldPebbleCount = max(0, goldPebbleCount)
        self.prismPebbleCount = max(0, prismPebbleCount)
    }
}

struct AggregateCalculation: Equatable, Sendable {
    let sources: [AggregateSource]
    let level: Int
    let pebbleCount: Int
    let childAggregateCount: Int
    let grams: Int
    let radius: Double
    let colorMix: [StratumColorFraction]
    let subjectMix: [AggregateSubjectFraction]
    let periodStart: Date
    let periodEnd: Date
    let sessionIDs: [UUID]
    let childAggregateIDs: [UUID]
    let measuredPebbleCount: Int
    let manualPebbleCount: Int
    let goldPebbleCount: Int
    let prismPebbleCount: Int
}

/// App-wide overview data. Only active root aggregates participate, so rolling
/// six children into one parent never changes the totals.
struct AggregateOverview: Equatable, Sendable {
    let rootCount: Int
    let highestLevel: Int
    let pebbleCount: Int
    let grams: Int
    let colorMix: [StratumColorFraction]
    let subjectMix: [AggregateSubjectFraction]
    let periodStart: Date?
    let periodEnd: Date?
}

struct BakeCalculation: Equatable, Sendable {
    let bakedPebbles: [StrataPebble]
    let remainingPebbles: [StrataPebble]
    let heightPt: Double
    let colorMix: [StratumColorFraction]
    let colorMixJSON: String
    let grams: Int

    var pebbleCount: Int { bakedPebbles.count }

    /// Useful for asserting that a visual bake has not changed mass.
    var totalGramsAfterBake: Int {
        grams + remainingPebbles.reduce(0) { $0 + $1.grams }
    }
}

/// A rendering projection for permanent history under the live physics bodies.
///
/// Persisted bedrock and strata may grow without limit. Their on-screen height may
/// not: otherwise old history eventually replaces the part of the bottle the user
/// can still touch and shake. This value keeps storage/accounting independent from
/// the bounded shelf used by SpriteKit.
struct JarArchiveLayout: Equatable, Sendable {
    let bedrockHeight: Double
    let strataScale: Double
    let totalHeight: Double
    let liveChamberHeight: Double
}

/// Immutable rendering data for a share card. Keeping this selection math in
/// Core makes measured-only cards deterministic and independently testable.
struct ShareStratumVisual: Identifiable, Equatable {
    let id: UUID
    let bakedAt: Date
    let pebbleCount: Int
    let heightPt: Double
    let colorMix: [StratumColorFraction]
    let monthLabel: String
    let sessionIDs: [UUID]

    init(stratum: Stratum) {
        id = stratum.id
        bakedAt = stratum.bakedAt
        pebbleCount = stratum.pebbleCount
        heightPt = stratum.heightPt
        colorMix = StrataMath.decodeColorMix(stratum.colorMixJSON)
        monthLabel = stratum.monthLabel
        sessionIDs = stratum.sessionIDs
    }

    init?(
        reconstructing stratum: Stratum,
        allMemberSessions: [StudySession],
        includedMemberSessions: [StudySession]
    ) {
        let membership = Set(stratum.sessionIDs)
        guard !membership.isEmpty else { return nil }

        let allMembers = Self.uniqueSessions(allMemberSessions)
            .filter { membership.contains($0.id) }
        let includedMembers = Self.uniqueSessions(includedMemberSessions)
            .filter { membership.contains($0.id) }
        guard !includedMembers.isEmpty else { return nil }

        let includedArea = Self.crossSectionArea(of: includedMembers)
        let knownTotalArea = Self.crossSectionArea(of: allMembers)
        let retainedFraction: Double
        if allMembers.count == membership.count, knownTotalArea > 0 {
            retainedFraction = includedArea / knownTotalArea
        } else {
            retainedFraction = Double(includedMembers.count)
                / Double(max(max(stratum.pebbleCount, membership.count), 1))
        }

        id = stratum.id
        bakedAt = stratum.bakedAt
        pebbleCount = includedMembers.count
        heightPt = max(0, stratum.heightPt * min(max(retainedFraction, 0), 1))
        colorMix = StrataMath.colorMix(
            hexColors: includedMembers.map(\.displaySubjectColorHex)
        )
        monthLabel = stratum.monthLabel
        sessionIDs = includedMembers.map(\.id).sorted {
            $0.uuidString < $1.uuidString
        }
    }

    static func radius(for session: StudySession) -> Double {
        guard session.source == .manual else {
            return Double(Constants.Jar.measuredRadius)
        }
        let thirtyMinuteGrams = Constants.Mass.manualThirtyMinutes
            * Constants.Mass.gramsPerMinute
        let sixtyMinuteGrams = Constants.Mass.manualSixtyMinutes
            * Constants.Mass.gramsPerMinute
        if session.grams <= thirtyMinuteGrams {
            return Double(Constants.Jar.manualThirtyRadius)
        }
        if session.grams <= sixtyMinuteGrams {
            return Double(Constants.Jar.manualSixtyRadius)
        }
        return Double(Constants.Jar.manualOneTwentyRadius)
    }

    private static func crossSectionArea(of sessions: [StudySession]) -> Double {
        sessions.reduce(0) { total, session in
            let radius = radius(for: session)
            return total + Double.pi * radius * radius
        }
    }

    private static func uniqueSessions(_ sessions: [StudySession]) -> [StudySession] {
        Dictionary(grouping: sessions, by: \.id).values.compactMap { duplicates in
            duplicates.max { lhs, rhs in lhs.grams < rhs.grams }
        }
    }
}

/// Immutable aggregate projection for share cards. It can reconstruct a
/// measured-only subset from the original sessions without flattening the
/// persisted hierarchy or counting a grouped session twice.
struct ShareAggregateVisual: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let level: Int
    let pebbleCount: Int
    let grams: Int
    let radius: Double
    let colorMix: [StratumColorFraction]
    let subjectMix: [AggregateSubjectFraction]
    let sessionIDs: [UUID]
    let measuredPebbleCount: Int
    let manualPebbleCount: Int
    let goldPebbleCount: Int
    let prismPebbleCount: Int

    /// A membership-backed aggregate is only a visual index over sessions that
    /// are already present on the card. A standalone summary has no materialized
    /// membership and therefore contributes its persisted totals itself.
    var contributesStandaloneTotals: Bool { sessionIDs.isEmpty }

    init(aggregate: AggregatePebble) {
        id = aggregate.id
        createdAt = aggregate.createdAt
        level = aggregate.level
        pebbleCount = aggregate.pebbleCount
        grams = aggregate.grams
        radius = StrataMath.aggregateRadius(level: aggregate.level)
        colorMix = aggregate.colorMix
        subjectMix = aggregate.subjectMix
        sessionIDs = aggregate.sessionIDs
        measuredPebbleCount = aggregate.measuredPebbleCount
        manualPebbleCount = aggregate.manualPebbleCount
        goldPebbleCount = aggregate.goldPebbleCount
        prismPebbleCount = aggregate.prismPebbleCount
    }

    /// A root summary used by bounded lifetime/share projections. Clearing the
    /// membership marks this visual as the authoritative compact mass rather
    /// than an index over StudySession objects that are intentionally not
    /// materialized on the destination screen.
    init(aggregateSummary aggregate: AggregatePebble) {
        id = aggregate.id
        createdAt = aggregate.createdAt
        level = aggregate.level
        pebbleCount = aggregate.pebbleCount
        grams = aggregate.grams
        radius = StrataMath.aggregateRadius(level: aggregate.level)
        colorMix = aggregate.colorMix
        subjectMix = aggregate.subjectMix
        sessionIDs = []
        measuredPebbleCount = aggregate.measuredPebbleCount
        manualPebbleCount = aggregate.manualPebbleCount
        goldPebbleCount = aggregate.goldPebbleCount
        prismPebbleCount = aggregate.prismPebbleCount
    }

    init(legacy stratum: Stratum) {
        id = stratum.id
        createdAt = stratum.bakedAt
        level = StrataMath.decimalAggregateLevel(forPebbleCount: stratum.pebbleCount)
        pebbleCount = stratum.pebbleCount
        grams = stratum.grams
        radius = StrataMath.aggregateRadius(level: level)
        colorMix = StrataMath.decodeColorMix(stratum.colorMixJSON)
        subjectMix = colorMix.enumerated().map { index, item in
            AggregateSubjectFraction(
                name: index == 0 ? "過去の集中" : "過去の集中 \(index + 1)",
                colorHex: item.hex,
                pebbleCount: Int((item.fraction * Double(max(stratum.pebbleCount, 1))).rounded())
            )
        }
        sessionIDs = stratum.sessionIDs
        measuredPebbleCount = stratum.pebbleCount
        manualPebbleCount = 0
        goldPebbleCount = 0
        prismPebbleCount = 0
    }

    init(legacySummary stratum: Stratum) {
        id = stratum.id
        createdAt = stratum.bakedAt
        level = StrataMath.decimalAggregateLevel(forPebbleCount: stratum.pebbleCount)
        pebbleCount = stratum.pebbleCount
        grams = stratum.grams
        radius = StrataMath.aggregateRadius(level: level)
        colorMix = StrataMath.decodeColorMix(stratum.colorMixJSON)
        subjectMix = colorMix.enumerated().map { index, item in
            AggregateSubjectFraction(
                name: index == 0 ? "過去の集中" : "過去の集中 \(index + 1)",
                colorHex: item.hex,
                pebbleCount: Int((item.fraction * Double(max(stratum.pebbleCount, 1))).rounded())
            )
        }
        sessionIDs = []
        measuredPebbleCount = stratum.pebbleCount
        manualPebbleCount = 0
        goldPebbleCount = 0
        prismPebbleCount = 0
    }

    init?(
        reconstructing aggregate: AggregatePebble,
        allMemberSessions: [StudySession],
        includedMemberSessions: [StudySession]
    ) {
        self.init(
            id: aggregate.id,
            createdAt: aggregate.createdAt,
            fallbackPebbleCount: aggregate.pebbleCount,
            fallbackGrams: aggregate.grams,
            membership: aggregate.sessionIDs,
            allMemberSessions: allMemberSessions,
            includedMemberSessions: includedMemberSessions
        )
    }

    init?(
        reconstructing aggregate: AggregatePebble,
        resolvedSessionIDs: [UUID],
        allMemberSessions: [StudySession],
        includedMemberSessions: [StudySession]
    ) {
        self.init(
            id: aggregate.id,
            createdAt: aggregate.createdAt,
            fallbackPebbleCount: aggregate.pebbleCount,
            fallbackGrams: aggregate.grams,
            membership: resolvedSessionIDs,
            allMemberSessions: allMemberSessions,
            includedMemberSessions: includedMemberSessions
        )
    }

    init?(
        reconstructing stratum: Stratum,
        allMemberSessions: [StudySession],
        includedMemberSessions: [StudySession]
    ) {
        self.init(
            id: stratum.id,
            createdAt: stratum.bakedAt,
            fallbackPebbleCount: stratum.pebbleCount,
            fallbackGrams: stratum.grams,
            membership: stratum.sessionIDs,
            allMemberSessions: allMemberSessions,
            includedMemberSessions: includedMemberSessions
        )
    }

    private init?(
        id: UUID,
        createdAt: Date,
        fallbackPebbleCount: Int,
        fallbackGrams: Int,
        membership: [UUID],
        allMemberSessions: [StudySession],
        includedMemberSessions: [StudySession]
    ) {
        let memberIDs = Set(membership)
        guard !memberIDs.isEmpty else { return nil }
        let all = Self.uniqueSessions(allMemberSessions).filter { memberIDs.contains($0.id) }
        let included = Self.uniqueSessions(includedMemberSessions)
            .filter { memberIDs.contains($0.id) }
        guard !included.isEmpty else { return nil }

        self.id = id
        self.createdAt = createdAt
        pebbleCount = included.count
        level = StrataMath.decimalAggregateLevel(forPebbleCount: included.count)
        radius = StrataMath.aggregateRadius(level: level)
        sessionIDs = included.map(\.id).sorted { $0.uuidString < $1.uuidString }
        colorMix = StrataMath.colorMix(hexColors: included.map(\.displaySubjectColorHex))
        subjectMix = StrataMath.mergedSubjectMix(included.map {
            [AggregateSubjectFraction(
                name: $0.displaySubjectName,
                colorHex: $0.displaySubjectColorHex,
                pebbleCount: 1
            )]
        })
        measuredPebbleCount = included.filter { $0.source.isMeasured }.count
        manualPebbleCount = included.count - measuredPebbleCount
        let rewards = RareRewardCounts.total(included.map(\.rareRewardCounts))
        goldPebbleCount = rewards.goldCount
        prismPebbleCount = rewards.prismCount

        if all.count == memberIDs.count {
            grams = included.reduce(0) { $0 + $1.grams }
        } else {
            grams = Int(
                (Double(max(0, fallbackGrams))
                    * Double(included.count)
                    / Double(max(fallbackPebbleCount, 1))).rounded()
            )
        }
    }

    private static func uniqueSessions(_ sessions: [StudySession]) -> [StudySession] {
        Dictionary(grouping: sessions, by: \.id).values.compactMap { duplicates in
            duplicates.max { $0.grams < $1.grams }
        }
    }
}

enum ScopedAggregateShareProjection: Equatable {
    /// The persisted aggregate is the sole accounting source. Descendant rows
    /// may be loaded for compatibility, but must not be added to the card.
    case authoritativeSummary

    /// Used when a measured-only card must remove self-reported members from a
    /// mixed aggregate and reconstruct the remaining measured subset.
    case filteredMembers

    static func mode(
        for aggregate: AggregatePebble,
        includesSelfReportedFocus: Bool
    ) -> Self {
        includesSelfReportedFocus || aggregate.manualPebbleCount == 0
            ? .authoritativeSummary
            : .filteredMembers
    }
}

enum ShareCardSelection {
    static func visibleLooseSessions(
        from sessions: [StudySession],
        representedBy strata: [ShareStratumVisual]
    ) -> [StudySession] {
        let representedIDs = Set(strata.flatMap(\.sessionIDs))
        return Dictionary(grouping: sessions, by: \.id).values.compactMap { duplicates in
            guard let id = duplicates.first?.id,
                  !representedIDs.contains(id),
                  !duplicates.contains(where: \.isBaked)
            else { return nil }
            return duplicates.max { lhs, rhs in lhs.grams < rhs.grams }
        }
        .sorted { $0.endAt < $1.endAt }
    }

    static func visibleLooseSessions(
        from sessions: [StudySession],
        representedBy aggregates: [ShareAggregateVisual]
    ) -> [StudySession] {
        let representedIDs = Set(aggregates.flatMap(\.sessionIDs))
        return Dictionary(grouping: sessions, by: \.id).values.compactMap { duplicates in
            guard let id = duplicates.first?.id,
                  !representedIDs.contains(id),
                  !duplicates.contains(where: \.isBaked)
            else { return nil }
            return duplicates.max { $0.grams < $1.grams }
        }
        .sorted { $0.endAt < $1.endAt }
    }
}

enum StrataMath {
    /// A movable aggregate grows enough to feel important, then caps so years
    /// of history never turn into an immovable boulder.
    static func aggregateRadius(level: Int) -> Double {
        let safeLevel = max(1, level)
        let proposed = Double(Constants.Jar.aggregateBaseRadius)
            + Double(safeLevel - 1) * Double(Constants.Jar.aggregateRadiusStep)
        return min(Double(Constants.Jar.aggregateMaximumRadius), proposed)
    }

    static func decimalAggregateLevel(forPebbleCount count: Int) -> Int {
        var remaining = max(1, count)
        var level = 0
        while remaining >= Constants.Jar.aggregateFanIn {
            remaining /= Constants.Jar.aggregateFanIn
            level += 1
        }
        return max(1, level)
    }

    /// Combines sources from one hierarchy level. Requiring a homogeneous level
    /// keeps the tree legible and avoids an old overview pebble swallowing a
    /// just-completed 25-minute session in the same animation.
    static func aggregate(sources: [AggregateSource]) -> AggregateCalculation? {
        let unique = Dictionary(grouping: sources, by: \.id).values.compactMap(\.first)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        guard unique.count == Constants.Jar.aggregateFanIn,
              let sourceLevel = unique.first?.level,
              unique.allSatisfy({ $0.level == sourceLevel })
        else { return nil }

        let pebbleCount = unique.reduce(0) { $0 + $1.pebbleCount }
        guard pebbleCount > 0 else { return nil }
        let level = sourceLevel + 1
        let colorMix = weightedColorMix(
            unique.map { ($0.colorMix, Double(max($0.pebbleCount, 1))) }
        )
        let subjectMix = mergedSubjectMix(unique.map(\.subjectMix))

        return AggregateCalculation(
            sources: unique,
            level: level,
            pebbleCount: pebbleCount,
            childAggregateCount: sourceLevel == 0 ? 0 : unique.count,
            grams: unique.reduce(0) { $0 + $1.grams },
            radius: aggregateRadius(level: level),
            colorMix: colorMix,
            subjectMix: subjectMix,
            periodStart: unique.map(\.periodStart).min() ?? .distantPast,
            periodEnd: unique.map(\.periodEnd).max() ?? .distantPast,
            // Direct StudySession membership lives only on level-one leaves.
            // Higher levels point to their ten children instead of copying the
            // entire descendant UUID list into every CloudKit record.
            sessionIDs: sourceLevel == 0
                ? Set(unique.flatMap(\.sessionIDs)).sorted {
                    $0.uuidString < $1.uuidString
                }
                : [],
            childAggregateIDs: sourceLevel == 0 ? [] : unique.map(\.id),
            measuredPebbleCount: unique.reduce(0) { $0 + $1.measuredPebbleCount },
            manualPebbleCount: unique.reduce(0) { $0 + $1.manualPebbleCount },
            goldPebbleCount: unique.reduce(0) { $0 + $1.goldPebbleCount },
            prismPebbleCount: unique.reduce(0) { $0 + $1.prismPebbleCount }
        )
    }

    /// Returns one decimal fusion step when capacity relief is required. The
    /// caller repeats this ten-at-a-time operation until the post-aggregation
    /// target is reached; the output body's area is included in each step.
    static func aggregateSelectionCount(
        sourceRadiiInOrder radii: [Double],
        existingCapacityUnits: Double,
        outputLevel: Int = 1
    ) -> Int {
        guard existingCapacityUnits >= Constants.Jar.aggregateCapacityUnits,
              outputLevel > 0,
              radii.count >= Constants.Jar.aggregateFanIn
        else { return 0 }
        return Constants.Jar.aggregateFanIn
    }

    static func shouldRollUpAggregateLevel(count: Int) -> Bool {
        max(0, count) >= Constants.Jar.aggregateFanIn
    }

    static func overview(aggregates: [AggregatePebble]) -> AggregateOverview {
        let frontier = AggregatePebblePolicy.accountingFrontier(from: aggregates)
        let summaries = frontier.summaries
        let weights = summaries.map { ($0.colorMix, Double(max($0.pebbleCount, 1))) }
        return AggregateOverview(
            rootCount: summaries.count,
            highestLevel: summaries.map(\.level).max() ?? 0,
            pebbleCount: summaries.reduce(0) { $0 + max(0, $1.pebbleCount) },
            grams: summaries.reduce(0) { $0 + max(0, $1.grams) },
            colorMix: weightedColorMix(weights),
            subjectMix: mergedSubjectMix(summaries.map(\.subjectMix)),
            periodStart: summaries.map(\.periodStart).min(),
            periodEnd: summaries.map(\.periodEnd).max()
        )
    }

    static func archiveLayout(
        rawStrataHeight: Double,
        requestedBedrockHeight: Double,
        interiorHeight: Double
    ) -> JarArchiveLayout {
        let safeInteriorHeight = max(0, interiorHeight)
        let safeStrataHeight = max(0, rawStrataHeight)
        let safeBedrockHeight = max(0, requestedBedrockHeight)
        let archiveBudget = min(
            Double(Constants.Jar.archiveMaximumHeight),
            safeInteriorHeight * Double(Constants.Jar.archiveMaximumFraction)
        )
        let displayedBedrockHeight = min(
            safeBedrockHeight,
            Double(Constants.Jar.bedrockMaximumRenderedHeight),
            archiveBudget
        )
        let strataBudget = max(0, archiveBudget - displayedBedrockHeight)
        let strataScale = safeStrataHeight > strataBudget
                && safeStrataHeight > 0
            ? strataBudget / safeStrataHeight
            : 1
        let displayedStrataHeight = safeStrataHeight * strataScale
        let totalHeight = min(
            archiveBudget,
            displayedBedrockHeight + displayedStrataHeight
        )

        return JarArchiveLayout(
            bedrockHeight: displayedBedrockHeight,
            strataScale: strataScale,
            totalHeight: totalHeight,
            liveChamberHeight: max(0, safeInteriorHeight - totalHeight)
        )
    }

    static func shouldBake(physicalBodyCount: Int, adding incomingCount: Int = 0) -> Bool {
        max(0, physicalBodyCount) + max(0, incomingCount) >= Constants.Jar.bakeThreshold
    }

    /// One normal measured pebble is one capacity unit. Using cross-section
    /// ratios makes a 17pt manual stone consume more room than an 11.5pt stone,
    /// so visually full mixed jars bake before their bodies become wedged.
    static func capacityUnits(
        pebbleRadii: [Double],
        baselineRadius: Double = Double(Constants.Jar.measuredRadius)
    ) -> Double {
        let safeBaseline = max(0, baselineRadius)
        guard safeBaseline > 0 else { return 0 }
        return pebbleRadii.reduce(0) { total, radius in
            let ratio = max(0, radius) / safeBaseline
            return total + ratio * ratio
        }
    }

    static func shouldBake(
        pebbleRadii: [Double],
        adding incomingRadii: [Double] = []
    ) -> Bool {
        capacityUnits(pebbleRadii: pebbleRadii + incomingRadii)
            >= Constants.Jar.bakeCapacityUnits
    }

    /// Returns the smallest prefix of bottom-to-top radii that must become a
    /// stratum to restore the live chamber to its 72-normal-pebble budget.
    static func bakeSelectionCount(
        pebbleRadiiInBakeOrder radii: [Double]
    ) -> Int {
        var remainingCapacity = capacityUnits(pebbleRadii: radii)
        guard remainingCapacity >= Constants.Jar.bakeCapacityUnits else { return 0 }

        for (index, radius) in radii.enumerated() {
            remainingCapacity -= capacityUnits(pebbleRadii: [radius])
            if remainingCapacity <= Constants.Jar.postBakeCapacityUnits {
                return index + 1
            }
        }
        return radii.count
    }

    /// Selects enough of the lowest pebbles to return below the live capacity
    /// target. With 120 normal measured pebbles this is the original 48 pebbles.
    /// Equal y values retain their original order, making the result stable for
    /// deterministic snapshots and tests.
    static func bake(
        pebbles: [StrataPebble],
        innerWidth: Double
    ) -> BakeCalculation? {
        guard shouldBake(pebbleRadii: pebbles.map(\.radius)), innerWidth > 0 else {
            return nil
        }

        let sortedIndices = pebbles.indices.sorted { lhs, rhs in
            let lhsY = pebbles[lhs].y
            let rhsY = pebbles[rhs].y
            if lhsY == rhsY { return lhs < rhs }
            return lhsY < rhsY
        }
        let selectionCount = bakeSelectionCount(
            pebbleRadiiInBakeOrder: sortedIndices.map { pebbles[$0].radius }
        )
        guard selectionCount > 0 else { return nil }
        let bakedIndices = Set(sortedIndices.prefix(selectionCount))
        let baked = sortedIndices.prefix(selectionCount).map { pebbles[$0] }
        let remaining = pebbles.indices
            .filter { !bakedIndices.contains($0) }
            .map { pebbles[$0] }
        let mix = colorMix(hexColors: baked.map(\.colorHex))

        return BakeCalculation(
            bakedPebbles: baked,
            remainingPebbles: remaining,
            heightPt: stratumHeight(
                pebbleRadii: baked.map(\.radius),
                innerWidth: innerWidth
            ),
            colorMix: mix,
            colorMixJSON: encodeColorMix(mix),
            grams: baked.reduce(0) { $0 + $1.grams }
        )
    }

    /// Height = total circular cross-section / inner jar width × packing
    /// factor, rounded to the nearest point as specified.
    static func stratumHeight(
        pebbleRadii: [Double],
        innerWidth: Double
    ) -> Double {
        guard innerWidth > 0 else { return 0 }
        let totalArea = pebbleRadii.reduce(0) { partial, radius in
            let safeRadius = max(0, radius)
            return partial + Double.pi * safeRadius * safeRadius
        }
        return (totalArea / innerWidth * Constants.Jar.strataPackingFactor)
            .rounded(.toNearestOrAwayFromZero)
    }

    static func stratumHeight(
        pebbleCount: Int,
        radius: Double = Double(Constants.Jar.measuredRadius),
        innerWidth: Double
    ) -> Double {
        stratumHeight(
            pebbleRadii: Array(repeating: max(0, radius), count: max(0, pebbleCount)),
            innerWidth: innerWidth
        )
    }

    static func colorMix(hexColors: [String]) -> [StratumColorFraction] {
        guard !hexColors.isEmpty else { return [] }

        var counts: [String: Int] = [:]
        for color in hexColors {
            counts[color.uppercased(), default: 0] += 1
        }

        let ordered = counts.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }
        let total = Double(hexColors.count)
        var accumulated = 0.0

        return ordered.enumerated().map { index, item in
            let fraction: Double
            if index == ordered.indices.last {
                // Absorb floating-point residue so the encoded mix sums to 1.
                fraction = max(0, 1 - accumulated)
            } else {
                fraction = Double(item.value) / total
                accumulated += fraction
            }
            return StratumColorFraction(hex: item.key, fraction: fraction)
        }
    }

    static func weightedColorMix(
        _ weightedMixes: [([StratumColorFraction], Double)]
    ) -> [StratumColorFraction] {
        var totals: [String: Double] = [:]
        for (mix, rawWeight) in weightedMixes {
            let weight = max(0, rawWeight)
            guard weight > 0 else { continue }
            for item in mix {
                totals[item.hex.uppercased(), default: 0] += max(0, item.fraction) * weight
            }
        }
        let total = totals.values.reduce(0, +)
        guard total > 0 else { return [] }
        let ordered = totals.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }
        var accumulated = 0.0
        return ordered.enumerated().map { index, item in
            let fraction: Double
            if index == ordered.indices.last {
                fraction = max(0, 1 - accumulated)
            } else {
                fraction = item.value / total
                accumulated += fraction
            }
            return StratumColorFraction(hex: item.key, fraction: fraction)
        }
    }

    static func mergedSubjectMix(
        _ mixes: [[AggregateSubjectFraction]]
    ) -> [AggregateSubjectFraction] {
        struct Key: Hashable {
            let name: String
            let colorHex: String
        }
        var counts: [Key: Int] = [:]
        for item in mixes.flatMap({ $0 }) where item.pebbleCount > 0 {
            counts[Key(name: item.name, colorHex: item.colorHex.uppercased()), default: 0]
                += item.pebbleCount
        }
        return counts.map {
            AggregateSubjectFraction(
                name: $0.key.name,
                colorHex: $0.key.colorHex,
                pebbleCount: $0.value
            )
        }
        .sorted { lhs, rhs in
            if lhs.pebbleCount == rhs.pebbleCount {
                if lhs.name == rhs.name { return lhs.colorHex < rhs.colorHex }
                return lhs.name < rhs.name
            }
            return lhs.pebbleCount > rhs.pebbleCount
        }
    }

    static func encodeColorMix(_ mix: [StratumColorFraction]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let data = try? encoder.encode(mix),
            let json = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return json
    }

    static func decodeColorMix(_ json: String) -> [StratumColorFraction] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([StratumColorFraction].self, from: data)) ?? []
    }

    static func encodeSubjectMix(_ mix: [AggregateSubjectFraction]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(mix),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    static func decodeSubjectMix(_ json: String) -> [AggregateSubjectFraction] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([AggregateSubjectFraction].self, from: data)) ?? []
    }

    static func bedrockHeight(hours: Int) -> Double {
        let safeHours = min(max(0, hours), Constants.Fairness.bedrockMaximumHours)
        let rawHeight = Double(Constants.Jar.bedrockBaseHeight)
            + Double(safeHours) / Double(Constants.Jar.bedrockHoursDivisor)
        return min(
            Double(Constants.Jar.bedrockMaxHeight),
            max(Double(Constants.Jar.bedrockMinHeight), rawHeight)
        )
    }

    static func monthLabel(
        for date: Date,
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month], from: date)
        return "\(components.year ?? 0)年\(components.month ?? 0)月"
    }

    /// Total mass remains reconstructible after bake: loose sessions plus the
    /// exact mass captured in persisted strata.
    static func totalGrams(sessions: [StudySession], strata: [Stratum]) -> Int {
        struct SessionAggregate {
            var grams: Int
            var isBaked: Bool
        }
        var sessionsByID: [UUID: SessionAggregate] = [:]
        for session in sessions {
            let safeGrams = max(0, session.grams)
            if var aggregate = sessionsByID[session.id] {
                aggregate.grams = max(aggregate.grams, safeGrams)
                aggregate.isBaked = aggregate.isBaked || session.isBaked
                sessionsByID[session.id] = aggregate
            } else {
                sessionsByID[session.id] = SessionAggregate(
                    grams: safeGrams,
                    isBaked: session.isBaked
                )
            }
        }

        var uniqueStrata: [UUID: Stratum] = [:]
        for stratum in strata where uniqueStrata[stratum.id] == nil {
            uniqueStrata[stratum.id] = stratum
        }
        var representedSessionIDs = Set<UUID>()
        var bakedGrams = 0
        for stratum in uniqueStrata.values.sorted(by: {
            if $0.bakedAt == $1.bakedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.bakedAt < $1.bakedAt
        }) {
            let membership = Set(stratum.sessionIDs).subtracting(representedSessionIDs)
            guard !membership.isEmpty else {
                if stratum.sessionIDs.isEmpty { bakedGrams += max(0, stratum.grams) }
                continue
            }
            representedSessionIDs.formUnion(membership)
            let knownGrams = membership.compactMap { sessionsByID[$0]?.grams }.reduce(0, +)
            if membership.allSatisfy({ sessionsByID[$0] != nil }) {
                bakedGrams += knownGrams
            } else {
                bakedGrams += Int(
                    (Double(max(0, stratum.grams))
                        * Double(membership.count)
                        / Double(max(stratum.sessionIDs.count, 1)))
                        .rounded()
                )
            }
        }
        let hasLegacyUnattributedStratum = uniqueStrata.values.contains { $0.sessionIDs.isEmpty }
        let looseGrams = sessionsByID
            .filter {
                !representedSessionIDs.contains($0.key)
                    && !(hasLegacyUnattributedStratum && $0.value.isBaked)
            }
            .reduce(0) { $0 + $1.value.grams }
        return looseGrams + bakedGrams
    }

    static func totalPebbleCount(sessions: [StudySession], strata: [Stratum]) -> Int {
        var sessionBakeState: [UUID: Bool] = [:]
        for session in sessions {
            sessionBakeState[session.id] = (sessionBakeState[session.id] ?? false) || session.isBaked
        }
        var uniqueStrata: [UUID: Stratum] = [:]
        for stratum in strata where uniqueStrata[stratum.id] == nil {
            uniqueStrata[stratum.id] = stratum
        }
        var representedSessionIDs = Set<UUID>()
        var bakedCount = 0
        for stratum in uniqueStrata.values.sorted(by: {
            if $0.bakedAt == $1.bakedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.bakedAt < $1.bakedAt
        }) {
            let membership = Set(stratum.sessionIDs).subtracting(representedSessionIDs)
            if membership.isEmpty {
                if stratum.sessionIDs.isEmpty { bakedCount += max(0, stratum.pebbleCount) }
            } else {
                representedSessionIDs.formUnion(membership)
                bakedCount += membership.count
            }
        }
        let hasLegacyUnattributedStratum = uniqueStrata.values.contains { $0.sessionIDs.isEmpty }
        let looseCount = sessionBakeState
            .filter {
                !representedSessionIDs.contains($0.key)
                    && !(hasLegacyUnattributedStratum && $0.value)
            }
            .count
        return looseCount + bakedCount
    }

    /// Aggregate-aware lifetime mass. Known StudySession rows are authoritative;
    /// aggregate payloads only fill gaps left by old or partially synced rows.
    static func totalGrams(
        sessions: [StudySession],
        aggregates: [AggregatePebble],
        directSessionIDs _: Set<UUID>? = nil
    ) -> Int {
        struct SessionAggregate {
            var grams: Int
            var isBaked: Bool
        }
        var sessionsByID: [UUID: SessionAggregate] = [:]
        for session in sessions {
            let safeGrams = max(0, session.grams)
            if var existing = sessionsByID[session.id] {
                existing.grams = max(existing.grams, safeGrams)
                existing.isBaked = existing.isBaked || session.isBaked
                sessionsByID[session.id] = existing
            } else {
                sessionsByID[session.id] = SessionAggregate(
                    grams: safeGrams,
                    isBaked: session.isBaked
                )
            }
        }
        let sessionFirstTotal = sessionsByID.values.reduce(0) { $0 + $1.grams }
        let frontier = AggregatePebblePolicy.accountingFrontier(from: aggregates)
        let aggregateFirstTotal = frontier.summaries.reduce(0) {
            $0 + max(0, $1.grams)
        }
            + sessionsByID.reduce(0) { total, entry in
                guard !frontier.representedSessionIDs.contains(entry.key),
                      !(frontier.containsUnknownMembership && entry.value.isBaked)
                else {
                    return total
                }
                return total + entry.value.grams
            }
        // Session-first survives a session-side isBaked flag arriving before
        // its aggregate. Aggregate-first survives the inverse CloudKit order
        // and fills sessions that have not downloaded yet. Taking the larger
        // lower bound avoids double counting either representation.
        return max(sessionFirstTotal, aggregateFirstTotal)
    }

    static func totalPebbleCount(
        sessions: [StudySession],
        aggregates: [AggregatePebble],
        directSessionIDs _: Set<UUID>? = nil
    ) -> Int {
        var sessionBakeState: [UUID: Bool] = [:]
        for session in sessions {
            sessionBakeState[session.id] = (sessionBakeState[session.id] ?? false)
                || session.isBaked
        }
        let sessionFirstTotal = sessionBakeState.count
        let frontier = AggregatePebblePolicy.accountingFrontier(from: aggregates)
        let aggregateFirstTotal = frontier.summaries.reduce(0) {
            $0 + max(0, $1.pebbleCount)
        } + sessionBakeState.reduce(0) { total, entry in
            guard !frontier.representedSessionIDs.contains(entry.key),
                  !(frontier.containsUnknownMembership && entry.value)
            else { return total }
            return total + 1
        }
        return max(sessionFirstTotal, aggregateFirstTotal)
    }
}
