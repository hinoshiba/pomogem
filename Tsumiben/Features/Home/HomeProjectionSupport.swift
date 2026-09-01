import Foundation
import SwiftData

/// A review request should follow demonstrated return, not a same-day burst or
/// a rare/fusion high. StoreKit still decides whether to show UI; this policy
/// only delays eligibility until the person has used the core loop across time.
enum ReviewRequestPolicy {
    static let minimumCompletionCount = 10
    static let minimumElapsedTime: TimeInterval = 7 * 24 * 60 * 60

    static func isEarned(
        completionCount: Int,
        firstCompletionDate: Date,
        now: Date
    ) -> Bool {
        completionCount >= minimumCompletionCount
            && now.timeIntervalSince(firstCompletionDate) >= minimumElapsedTime
    }
}

/// A duration-normalized, deterministic progress projection over persisted
/// study mass.
///
/// The physical jar deliberately keeps one pebble per completed timer and its
/// ten-to-one aggregation remains a lossless storage/presentation mechanism.
/// Durable motivational progress is different: it must not make ten one-minute
/// timers worth ten times one ten-minute timer. Since every persisted minute is
/// already represented by `Constants.Mass.gramsPerMinute`, this projection can
/// stay migration-free and derive exact progress from existing mass.
struct EffortProgressSnapshot: Equatable, Sendable {
    let totalGrams: Int
    let latestContributionGrams: Int
    /// One means the first 10 x 25-minute milestone, two the next decimal tier.
    let displayedTargetLevel: Int
    let displayedTargetGrams: Int
    let displayedProgressGrams: Int
    /// Non-nil when the latest completion crossed a decimal time milestone.
    /// The post-focus bridge can hold that finite 100% beat instead of jumping
    /// immediately to a 10% view of the following tier.
    let crossedMilestoneGrams: Int?
    let nextTargetLevel: Int
    let nextTargetGrams: Int

    var progressFraction: Double {
        guard displayedTargetGrams > 0 else { return 0 }
        return min(
            1,
            Double(max(0, displayedProgressGrams))
                / Double(displayedTargetGrams)
        )
    }

    var remainingGrams: Int {
        max(0, displayedTargetGrams - displayedProgressGrams)
    }

    var overflowGrams: Int {
        guard let crossedMilestoneGrams else { return 0 }
        return max(0, totalGrams - crossedMilestoneGrams)
    }

    var nextProgressFraction: Double {
        guard nextTargetGrams > 0 else { return 0 }
        return min(1, Double(totalGrams) / Double(nextTargetGrams))
    }
}

enum EffortProgressPolicy {
    /// One historical "standard pebble" is 25 minutes / 250g. Fractional
    /// standard units are retained; no rounding happens at session boundaries.
    static let standardUnitGrams = Constants.Mass.measuredPebbleGrams
    static let firstMilestoneUnitCount = FusionHierarchyPresentation.fanIn
    static let firstMilestoneGrams = standardUnitGrams * firstMilestoneUnitCount

    /// Builds a lifetime state when `latestContributionGrams == 0`, or a
    /// completion receipt state when the latest contribution is supplied.
    /// Supplying it lets the UI prove which milestone that completion crossed,
    /// including an overshoot such as 240 + 60 minutes.
    static func snapshot(
        totalGrams rawTotalGrams: Int,
        latestContributionGrams rawLatestContributionGrams: Int = 0
    ) -> EffortProgressSnapshot {
        let totalGrams = max(0, rawTotalGrams)
        let latestContributionGrams = min(
            totalGrams,
            max(0, rawLatestContributionGrams)
        )
        let previousTotal = totalGrams - latestContributionGrams
        let crossed = highestMilestone(after: previousTotal, through: totalGrams)
        let next = target(strictlyAbove: totalGrams)

        return EffortProgressSnapshot(
            totalGrams: totalGrams,
            latestContributionGrams: latestContributionGrams,
            displayedTargetLevel: crossed?.level ?? next.level,
            displayedTargetGrams: crossed?.grams ?? next.grams,
            displayedProgressGrams: crossed?.grams ?? totalGrams,
            crossedMilestoneGrams: crossed?.grams,
            nextTargetLevel: next.level,
            nextTargetGrams: next.grams
        )
    }

    /// Standard 25-minute equivalents are deliberately fractional. This is a
    /// diagnostic/presentation value, not a second persisted currency.
    static func standardUnitEquivalent(totalGrams: Int) -> Double {
        guard standardUnitGrams > 0 else { return 0 }
        return Double(max(0, totalGrams)) / Double(standardUnitGrams)
    }

    private static func highestMilestone(
        after lowerBound: Int,
        through upperBound: Int
    ) -> (level: Int, grams: Int)? {
        guard upperBound >= firstMilestoneGrams else { return nil }
        var level = 1
        var milestone = firstMilestoneGrams
        var result: (level: Int, grams: Int)?

        while milestone <= upperBound {
            if milestone > lowerBound {
                result = (level, milestone)
            }
            guard milestone <= Int.max / FusionHierarchyPresentation.fanIn else {
                break
            }
            milestone *= FusionHierarchyPresentation.fanIn
            level += 1
        }
        return result
    }

    private static func target(strictlyAbove grams: Int) -> (level: Int, grams: Int) {
        var level = 1
        var target = firstMilestoneGrams
        while target <= grams {
            guard target <= Int.max / FusionHierarchyPresentation.fanIn else {
                return (level, Int.max)
            }
            target *= FusionHierarchyPresentation.fanIn
            level += 1
        }
        return (level, target)
    }
}

/// One decimal place in the deterministic ten-to-one fusion hierarchy.
///
/// Level zero is the loose-particle digit, level one is the `x10` crystal
/// digit, level two is `x100`, and so on. Keeping zero-valued levels between
/// active digits is intentional: a lifetime such as 350,640 remains an exact,
/// spatially stable hierarchy instead of a compact list whose meaning shifts.
struct FusionHierarchyLevel: Identifiable, Equatable, Sendable {
    let level: Int
    let unitCount: Int
    let unitPebbleCount: Int
    let representedPebbleCount: Int

    var id: Int { level }
    var isLoose: Bool { level == 0 }
    var isActive: Bool { unitCount > 0 }
}

/// A reachable ten-to-one fusion target expressed both in hierarchy units and
/// in the exact number of base particles still needed.
struct FusionHierarchyHorizon: Equatable, Sendable {
    let sourceLevel: Int
    let destinationLevel: Int
    let sourceUnitCount: Int
    let requiredSourceUnitCount: Int
    let representedPebbleCountInDestination: Int
    let destinationPebbleCount: Int
    let remainingPebbleCount: Int
    /// More than one level appears when the target completes a carry chain,
    /// for example 99 -> 100 forms both the x10 and x100 levels.
    let cascadingDestinationLevels: [Int]

    var progressFraction: Double {
        guard destinationPebbleCount > 0 else { return 0 }
        return Double(representedPebbleCountInDestination)
            / Double(destinationPebbleCount)
    }
}

struct FusionHierarchySnapshot: Equatable, Sendable {
    let totalPebbleCount: Int
    let levels: [FusionHierarchyLevel]

    /// The chronologically next physical fusion. This always starts with loose
    /// particles and can expose a multi-level carry at values such as 99.
    let nextFusionHorizon: FusionHierarchyHorizon

    /// A Home-friendly target that does not misleadingly reset to `0/10`
    /// after a crystal already exists. It advances the lowest active crystal
    /// tier; before the first crystal it is identical to `nextFusionHorizon`.
    let homeFusionHorizon: FusionHierarchyHorizon

    var looseLevel: FusionHierarchyLevel { levels[0] }
    var activeLevels: [FusionHierarchyLevel] { levels.filter(\.isActive) }
    var highestActiveLevel: Int { activeLevels.last?.level ?? 0 }
    var representedPebbleCount: Int {
        levels.reduce(0) { $0 + $1.representedPebbleCount }
    }
}

/// Exact decimal presentation for the same fan-in-of-ten rule used by the jar
/// physics. It derives solely from the authoritative lifetime count, so it is
/// independent of which bounded aggregate objects happen to be materialized.
enum FusionHierarchyPresentation {
    static let fanIn = 10

    static func snapshot(totalPebbleCount rawTotalPebbleCount: Int) -> FusionHierarchySnapshot {
        let totalPebbleCount = max(0, rawTotalPebbleCount)
        let levels = makeLevels(totalPebbleCount: totalPebbleCount)
        let nextFusionHorizon = makeHorizon(
            sourceLevel: 0,
            totalPebbleCount: totalPebbleCount,
            levels: levels
        )
        // A theoretical top digit can have no representable Int-sized next
        // tier. In that extreme case the immediate x10 horizon remains safe.
        let homeSourceLevel = levels.dropFirst().first {
            $0.isActive && $0.unitPebbleCount <= Int.max / fanIn
        }?.level ?? 0
        let homeFusionHorizon = makeHorizon(
            sourceLevel: homeSourceLevel,
            totalPebbleCount: totalPebbleCount,
            levels: levels
        )

        return FusionHierarchySnapshot(
            totalPebbleCount: totalPebbleCount,
            levels: levels,
            nextFusionHorizon: nextFusionHorizon,
            homeFusionHorizon: homeFusionHorizon
        )
    }

    private static func makeLevels(totalPebbleCount: Int) -> [FusionHierarchyLevel] {
        var remaining = totalPebbleCount
        var unitPebbleCount = 1
        var level = 0
        var result: [FusionHierarchyLevel] = []

        repeat {
            let unitCount = remaining % fanIn
            result.append(FusionHierarchyLevel(
                level: level,
                unitCount: unitCount,
                unitPebbleCount: unitPebbleCount,
                representedPebbleCount: unitCount * unitPebbleCount
            ))
            remaining /= fanIn
            guard remaining > 0 else { break }
            unitPebbleCount *= fanIn
            level += 1
        } while true

        return result
    }

    private static func makeHorizon(
        sourceLevel: Int,
        totalPebbleCount: Int,
        levels: [FusionHierarchyLevel]
    ) -> FusionHierarchyHorizon {
        let sourceUnitPebbleCount = decimalUnit(at: sourceLevel)
        let destinationLevel = sourceLevel + 1
        let destinationPebbleCount = sourceUnitPebbleCount * fanIn
        let representedPebbleCount = totalPebbleCount % destinationPebbleCount
        let sourceUnitCount = digit(at: sourceLevel, in: levels)

        var cascadingLevels = [destinationLevel]
        var carryLevel = destinationLevel
        while digit(at: carryLevel, in: levels) == fanIn - 1 {
            carryLevel += 1
            cascadingLevels.append(carryLevel)
        }

        return FusionHierarchyHorizon(
            sourceLevel: sourceLevel,
            destinationLevel: destinationLevel,
            sourceUnitCount: sourceUnitCount,
            requiredSourceUnitCount: fanIn,
            representedPebbleCountInDestination: representedPebbleCount,
            destinationPebbleCount: destinationPebbleCount,
            remainingPebbleCount: destinationPebbleCount - representedPebbleCount,
            cascadingDestinationLevels: cascadingLevels
        )
    }

    private static func digit(
        at level: Int,
        in levels: [FusionHierarchyLevel]
    ) -> Int {
        guard levels.indices.contains(level) else { return 0 }
        return levels[level].unitCount
    }

    private static func decimalUnit(at level: Int) -> Int {
        guard level > 0 else { return 1 }
        return (0..<level).reduce(1) { value, _ in value * fanIn }
    }
}

/// Bounded persistence boundary for Home. Multi-decade history remains in
/// SwiftData; the first bottle frame only materializes objects that can be
/// rendered or acted on immediately.
enum HomeProjectionPolicy {
    static let looseSessionLimit = Constants.Jar.maxPhysicsBodies
    /// Overfetch remains hard-bounded so a run of quarantined reset epochs
    /// cannot usually starve the current loose set.
    static let looseSessionQueryLimit = Constants.Jar.maxPhysicsBodies * 4
    static let aggregateRootLimit = Constants.Jar.maxPhysicsBodies
    static let achievementLimit = Constants.Jar.maximumVisibleAchievementStones * 2
    static let legacyCompatibilityLimit = 16

    static func looseSessionDescriptor() -> FetchDescriptor<StudySession> {
        var descriptor = FetchDescriptor<StudySession>(
            predicate: #Predicate { session in
                session.isBaked == false
            },
            sortBy: [SortDescriptor(\StudySession.endAt, order: .reverse)]
        )
        descriptor.fetchLimit = looseSessionQueryLimit
        return descriptor
    }

    static func aggregateRootDescriptor() -> FetchDescriptor<AggregatePebble> {
        var descriptor = FetchDescriptor<AggregatePebble>(
            predicate: #Predicate { aggregate in
                aggregate.parentAggregateID == nil
            },
            sortBy: [SortDescriptor(\AggregatePebble.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = aggregateRootLimit
        return descriptor
    }

    /// Active candidate page for the jar. Home re-resolves every returned ID
    /// with `AchievementStonePolicy.resolvedVisibleCandidates`, whose exact
    /// query includes tombstones. Keeping tombstone-only rows out of this first
    /// page prevents a long deletion history from starving live milestones.
    static func achievementCandidateDescriptor() -> FetchDescriptor<AchievementStone> {
        var descriptor = FetchDescriptor<AchievementStone>(
            predicate: #Predicate { stone in stone.deletedAt == nil },
            sortBy: [SortDescriptor(\AchievementStone.achievedAt, order: .reverse)]
        )
        descriptor.fetchLimit = achievementLimit
        return descriptor
    }

    static func legacyCompatibilityDescriptor() -> FetchDescriptor<Stratum> {
        var descriptor = FetchDescriptor<Stratum>(
            predicate: #Predicate { stratum in
                stratum.sessionIDsJSON == "[]"
            },
            sortBy: [SortDescriptor(\Stratum.bakedAt, order: .reverse)]
        )
        descriptor.fetchLimit = legacyCompatibilityLimit
        return descriptor
    }

    /// Accepts a bounded root summary only after its direct child equation
    /// closes. This is not proof that every descendant has downloaded; Home
    /// therefore adds only demonstrably newer loose rows and labels other
    /// partial states as synchronization maintenance.
    @MainActor
    static func acceptedRootSummaryIDs(
        roots: [AggregatePebble],
        context: ModelContext,
        resetMarkers: [ActivityResetSnapshot]
    ) throws -> Set<UUID> {
        var trusted = Set<UUID>()
        for root in AggregatePebblePolicy.activeRoots(from: roots) {
            let directCount = Set(root.sessionIDs).count
            if directCount > 0 {
                if directCount == root.pebbleCount,
                   root.level > 1 || directCount <= Constants.Jar.aggregateFanIn {
                    trusted.insert(root.id)
                }
                continue
            }
            if AggregatePebblePolicy.isUnattributedCompatibility(root) {
                if root.pebbleCount > 0 { trusted.insert(root.id) }
                continue
            }

            let expectedChildIDs = Set(root.childAggregateIDs)
            guard (1...Constants.Jar.aggregateFanIn).contains(expectedChildIDs.count),
                  root.childAggregateCount == expectedChildIDs.count
            else { continue }

            let rootID = root.id
            var descriptor = FetchDescriptor<AggregatePebble>(
                predicate: #Predicate { aggregate in
                    aggregate.parentAggregateID == rootID
                }
            )
            descriptor.fetchLimit = Constants.Jar.aggregateFanIn * 2
            let fetched = try context.fetch(descriptor).filter {
                ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetMarkers)
            }
            let children = Dictionary(grouping: fetched, by: \.id).values.compactMap {
                $0.max { lhs, rhs in
                    if lhs.level == rhs.level { return lhs.createdAt < rhs.createdAt }
                    return lhs.level < rhs.level
                }
            }
            guard Set(children.map(\.id)) == expectedChildIDs,
                  children.allSatisfy({ $0.level == root.level - 1 }),
                  children.reduce(0, { $0 + max(0, $1.pebbleCount) }) == root.pebbleCount,
                  children.reduce(0, { $0 + max(0, $1.grams) }) == root.grams
            else { continue }
            trusted.insert(root.id)
        }
        let trustedRoots = AggregatePebblePolicy.activeRoots(from: roots).filter {
            trusted.contains($0.id)
        }
        return Set(AggregatePebblePolicy.disjointRootSummaries(from: trustedRoots).map(\.id))
    }

    struct Totals: Equatable {
        let grams: Int
        let pebbleCount: Int
    }

    static func totals(
        roots: [AggregatePebble],
        looseSessions: [StudySession]
    ) -> Totals {
        let uniqueLoose = Dictionary(grouping: looseSessions, by: \.id).values.compactMap {
            $0.max { lhs, rhs in lhs.grams < rhs.grams }
        }
        let rootGrams = saturatingNonnegativeSum(roots.map(\.grams))
        let looseGrams = saturatingNonnegativeSum(uniqueLoose.map(\.grams))
        let rootPebbleCount = saturatingNonnegativeSum(roots.map(\.pebbleCount))
        return Totals(
            grams: saturatingNonnegativeSum([rootGrams, looseGrams]),
            pebbleCount: saturatingNonnegativeSum([
                rootPebbleCount,
                uniqueLoose.count
            ])
        )
    }

    /// Corrupt or future-scale rows must not turn a bounded Home projection
    /// into an integer-overflow crash. Saturation is honest here: callers
    /// already distinguish partial/lower-bound projections from exact totals.
    static func saturatingNonnegativeSum(_ values: [Int]) -> Int {
        values.reduce(0) { partial, rawValue in
            let value = max(0, rawValue)
            guard partial <= Int.max - value else { return Int.max }
            return partial + value
        }
    }

    struct AchievementCountProjection: Equatable {
        let count: Int
        let isLowerBound: Bool
    }

    /// Exact while the complete active candidate set fits in Home's bounded
    /// page. For larger histories the UI reports the resolved page as a lower
    /// bound instead of presenting a duplicate-sensitive database row count as
    /// a lifetime truth.
    @MainActor
    static func currentAchievementCount(
        context: ModelContext,
        resetMarkers: [ActivityResetSnapshot],
        resolvedCandidates: [AchievementStone],
        loadedCandidateRowCount: Int
    ) throws -> AchievementCountProjection {
        let rawActiveCount: Int
        if let epochID = ActivityResetPolicy.currentEpochID(from: resetMarkers) {
            let epoch = epochID
            rawActiveCount = try context.fetchCount(FetchDescriptor<AchievementStone>(
                predicate: #Predicate { stone in
                    stone.dataEpochID == epoch && stone.deletedAt == nil
                }
            ))
        } else {
            rawActiveCount = try context.fetchCount(FetchDescriptor<AchievementStone>(
                predicate: #Predicate { stone in
                    stone.dataEpochID == nil && stone.deletedAt == nil
                }
            ))
        }
        return AchievementCountProjection(
            count: Set(resolvedCandidates.map(\.id)).count,
            isLowerBound: rawActiveCount > loadedCandidateRowCount
        )
    }

    struct CompletionMetrics {
        let completedFocusCount: Int
        let weeklyMeasuredSessionIDs: Set<UUID>
        let weeklyMeasuredDates: [Date]
        /// Exact timer mass for the bounded current-week query. Session count
        /// remains a return-frequency cue; this is the value-bearing measure.
        let weeklyMeasuredGrams: Int
    }

    /// Count-only lifetime cadence plus a paged seven-day query. The lifetime
    /// count can include a transient logical duplicate until bootstrap merges
    /// CloudKit rows; no multi-decade model objects are materialized on Home.
    @MainActor
    static func completionMetrics(
        context: ModelContext,
        resetMarkers: [ActivityResetSnapshot],
        roots: [AggregatePebble],
        looseSessions: [StudySession],
        at date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> CompletionMetrics {
        // The accepted aggregate summaries already carry exact measured counts,
        // so the long-break cadence does not need to instantiate every historic
        // StudySession. This also avoids SwiftData's runtime-unsupported enum
        // predicates. Home passes only validated roots plus its bounded loose
        // page, making this calculation O(number of rendered bodies).
        let uniqueLoose = Dictionary(grouping: looseSessions, by: \.id).values
            .compactMap { duplicates in
                duplicates.max { lhs, rhs in lhs.endAt < rhs.endAt }
            }
        let completedCount = saturatingNonnegativeSum([
            saturatingNonnegativeSum(roots.map(\.measuredPebbleCount)),
            uniqueLoose.filter { $0.source == .timer }.count
        ])

        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else {
            return CompletionMetrics(
                completedFocusCount: completedCount,
                weeklyMeasuredSessionIDs: [],
                weeklyMeasuredDates: [],
                weeklyMeasuredGrams: 0
            )
        }
        let start = interval.start
        let end = interval.end
        // `SessionSource` is intentionally filtered in memory because enum
        // predicates are not reliable across the supported SwiftData
        // runtimes. Applying one fetch limit before that filter silently
        // under-counted unusually dense 1/10-minute weeks or weeks containing
        // many stale/reset rows. Page the finite week in a stable order so the
        // value-bearing mass remains exact without one unbounded fetch.
        let pageSize = 512
        var offset = 0
        var weekly: [StudySession] = []
        while true {
            var descriptor = FetchDescriptor<StudySession>(
                predicate: #Predicate { session in
                    session.endAt >= start && session.endAt < end
                },
                sortBy: [
                    SortDescriptor(\StudySession.endAt, order: .reverse),
                    SortDescriptor(\StudySession.id, order: .reverse)
                ]
            )
            descriptor.fetchLimit = pageSize
            descriptor.fetchOffset = offset
            let page = try context.fetch(descriptor)
            weekly.append(contentsOf: page.filter {
                $0.source == .timer
                    && ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetMarkers)
            })
            guard page.count == pageSize,
                  offset <= Int.max - page.count
            else { break }
            offset += page.count
        }
        let unique = Dictionary(grouping: weekly, by: \.id).values.compactMap {
            $0.max { $0.endAt < $1.endAt }
        }
        return CompletionMetrics(
            completedFocusCount: completedCount,
            weeklyMeasuredSessionIDs: Set(unique.map(\.id)),
            weeklyMeasuredDates: unique.map(\.endAt),
            weeklyMeasuredGrams: saturatingNonnegativeSum(unique.map(\.grams))
        )
    }
}

/// Aggregate creation has a fan-in of ten, so persistence can resolve its
/// exact source rows on demand without retaining the complete history on Home.
enum HomeAggregatePersistenceError: Error, Equatable {
    case staleEpoch
    case invalidRequest
    case conflictingExistingAggregate(UUID)
    case missingCurrentSource(UUID)
    case conflictingSource(UUID)
    case alreadyConsumedSource(UUID)
    case competingParent(childID: UUID, parentID: UUID)
}

enum HomeAggregatePersistence {
    private struct Preflight {
        let sessionsToBake: [StudySession]
        let childrenToAdopt: [AggregatePebble]
        let shouldInsertAggregate: Bool
    }

    @MainActor
    static func persist(
        _ request: JarAggregateRequest,
        context: ModelContext,
        dataEpochID: UUID?,
        resetMarkers: [ActivityResetSnapshot]
    ) throws {
        // Resolve and validate every logical source before touching any model.
        // SpriteKit requests can outlive a CloudKit reconciliation frame; a
        // partial mutation here would otherwise bake nine rows and strand the
        // tenth, or steal a child that another deterministic parent owns.
        let preflight = try preflight(
            request,
            context: context,
            dataEpochID: dataEpochID,
            resetMarkers: resetMarkers
        )

        for session in preflight.sessionsToBake {
            session.isBaked = true
        }
        for aggregate in preflight.childrenToAdopt {
            aggregate.parentAggregateID = request.id
        }
        if preflight.shouldInsertAggregate {
            let aggregate = request.makeAggregatePebble()
            aggregate.dataEpochID = dataEpochID
            context.insert(aggregate)
        }
#if DEBUG && targetEnvironment(simulator)
        // Inject only after every source/output mutation, immediately before
        // the transaction boundary. This is the only point that proves Home's
        // rollback restores all ten sources and discards the inserted output.
        if UITestFaultInjection.consumeAggregatePersistenceSaveFailure() {
            throw UITestInjectedPersistenceError.aggregatePersistenceSaveOnce
        }
#endif
        try context.save()
    }

    @MainActor
    private static func preflight(
        _ request: JarAggregateRequest,
        context: ModelContext,
        dataEpochID: UUID?,
        resetMarkers: [ActivityResetSnapshot]
    ) throws -> Preflight {
        guard dataEpochID == ActivityResetPolicy.currentEpochID(from: resetMarkers)
        else { throw HomeAggregatePersistenceError.staleEpoch }

        let sources = request.calculation.sources
        let sourceIDs = Set(sources.map(\.id))
        guard request.pebbles.count == Constants.Jar.aggregateFanIn,
              sources.count == Constants.Jar.aggregateFanIn,
              sourceIDs.count == Constants.Jar.aggregateFanIn,
              Set(request.pebbleIDs) == sourceIDs,
              let sourceLevel = sources.first?.level,
              sources.allSatisfy({ $0.level == sourceLevel }),
              request.outputLevel == sourceLevel + 1,
              StrataMath.aggregate(sources: sources) == request.calculation,
              request.id == JarAggregateRequest.deterministicID(
                sourceIDs: Array(sourceIDs),
                outputLevel: request.outputLevel
              ),
              !sourceIDs.contains(request.id)
        else { throw HomeAggregatePersistenceError.invalidRequest }

        let requestID = request.id
        let existingRows = try context.fetch(FetchDescriptor<AggregatePebble>(
            predicate: #Predicate { aggregate in aggregate.id == requestID }
        )).filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetMarkers)
        }
        guard existingRows.allSatisfy({ aggregateMatchesRequest($0, request: request) })
        else {
            throw HomeAggregatePersistenceError.conflictingExistingAggregate(request.id)
        }
        let existingParents = Set(existingRows.compactMap(\.parentAggregateID))
        guard !existingParents.contains(request.id), existingParents.count <= 1 else {
            throw HomeAggregatePersistenceError.conflictingExistingAggregate(request.id)
        }
        let isIdempotentReplay = !existingRows.isEmpty

        if sourceLevel == 0 {
            return try preflightLeafSources(
                sources,
                request: request,
                context: context,
                resetMarkers: resetMarkers,
                isIdempotentReplay: isIdempotentReplay
            )
        }
        return try preflightAggregateSources(
            sources,
            request: request,
            context: context,
            resetMarkers: resetMarkers,
            isIdempotentReplay: isIdempotentReplay
        )
    }

    @MainActor
    private static func preflightLeafSources(
        _ sources: [AggregateSource],
        request: JarAggregateRequest,
        context: ModelContext,
        resetMarkers: [ActivityResetSnapshot],
        isIdempotentReplay: Bool
    ) throws -> Preflight {
        guard request.outputLevel == 1,
              request.calculation.childAggregateCount == 0,
              request.childAggregateIDs.isEmpty,
              Set(request.calculation.sessionIDs) == Set(sources.map(\.id)),
              sources.allSatisfy({
                $0.pebbleCount == 1
                    && $0.childAggregateCount == 0
                    && Set($0.sessionIDs) == [$0.id]
              })
        else { throw HomeAggregatePersistenceError.invalidRequest }

        var rowsToBake: [StudySession] = []
        for source in sources {
            let sourceID = source.id
            let currentRows = try context.fetch(FetchDescriptor<StudySession>(
                predicate: #Predicate { session in session.id == sourceID }
            )).filter {
                ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetMarkers)
            }

            // Once the exact aggregate exists, retries are allowed to repair
            // whichever duplicate leaves have arrived. A missing leaf no longer
            // makes the already-materialized deterministic result unsafe.
            if !isIdempotentReplay {
                guard !currentRows.isEmpty else {
                    throw HomeAggregatePersistenceError.missingCurrentSource(sourceID)
                }
                guard currentRows.allSatisfy({ sessionMatchesSource($0, source: source) }) else {
                    throw HomeAggregatePersistenceError.conflictingSource(sourceID)
                }
                guard currentRows.allSatisfy({ !$0.isBaked }) else {
                    throw HomeAggregatePersistenceError.alreadyConsumedSource(sourceID)
                }
            }
            rowsToBake.append(contentsOf: currentRows)
        }
        return Preflight(
            sessionsToBake: rowsToBake,
            childrenToAdopt: [],
            shouldInsertAggregate: !isIdempotentReplay
        )
    }

    @MainActor
    private static func preflightAggregateSources(
        _ sources: [AggregateSource],
        request: JarAggregateRequest,
        context: ModelContext,
        resetMarkers: [ActivityResetSnapshot],
        isIdempotentReplay: Bool
    ) throws -> Preflight {
        let requestedChildIDs = Set(request.childAggregateIDs)
        guard request.outputLevel > 1,
              requestedChildIDs.count == Constants.Jar.aggregateFanIn,
              requestedChildIDs == Set(sources.map(\.id)),
              request.calculation.childAggregateCount == Constants.Jar.aggregateFanIn,
              request.calculation.sessionIDs.isEmpty
        else { throw HomeAggregatePersistenceError.invalidRequest }

        var childrenToAdopt: [AggregatePebble] = []
        for source in sources {
            let sourceID = source.id
            let currentRows = try context.fetch(FetchDescriptor<AggregatePebble>(
                predicate: #Predicate { aggregate in aggregate.id == sourceID }
            )).filter {
                ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetMarkers)
            }
            if !isIdempotentReplay, currentRows.isEmpty {
                throw HomeAggregatePersistenceError.missingCurrentSource(sourceID)
            }
            for child in currentRows {
                guard aggregateMatchesSource(child, source: source) else {
                    throw HomeAggregatePersistenceError.conflictingSource(sourceID)
                }
                if let parentID = child.parentAggregateID,
                   parentID != request.id {
                    throw HomeAggregatePersistenceError.competingParent(
                        childID: sourceID,
                        parentID: parentID
                    )
                }
            }
            childrenToAdopt.append(contentsOf: currentRows)
        }
        return Preflight(
            sessionsToBake: [],
            childrenToAdopt: childrenToAdopt,
            shouldInsertAggregate: !isIdempotentReplay
        )
    }

    private static func sessionMatchesSource(
        _ session: StudySession,
        source: AggregateSource
    ) -> Bool {
        let isMeasured = session.source.isMeasured
        return session.id == source.id
            && source.level == 0
            && source.pebbleCount == 1
            && source.childAggregateCount == 0
            && source.grams == session.grams
            && source.periodStart == session.endAt
            && source.periodEnd == session.endAt
            && source.measuredPebbleCount == (isMeasured ? 1 : 0)
            && source.manualPebbleCount == (isMeasured ? 0 : 1)
            && source.goldPebbleCount == session.rareRewardCounts.goldCount
            && source.prismPebbleCount == session.rareRewardCounts.prismCount
            && Set(source.sessionIDs) == [session.id]
    }

    private static func aggregateMatchesSource(
        _ aggregate: AggregatePebble,
        source: AggregateSource
    ) -> Bool {
        aggregate.id == source.id
            && aggregate.level == source.level
            && aggregate.pebbleCount == source.pebbleCount
            && aggregate.childAggregateCount == source.childAggregateCount
            && aggregate.grams == source.grams
            && aggregate.measuredPebbleCount == source.measuredPebbleCount
            && aggregate.manualPebbleCount == source.manualPebbleCount
            && aggregate.goldPebbleCount == source.goldPebbleCount
            && aggregate.prismPebbleCount == source.prismPebbleCount
            && aggregate.colorMix == source.colorMix
            && aggregate.subjectMix == source.subjectMix
            && aggregate.periodStart == source.periodStart
            && aggregate.periodEnd == source.periodEnd
            && Set(aggregate.sessionIDs) == Set(source.sessionIDs)
            && Set(aggregate.childAggregateIDs).count == source.childAggregateCount
    }

    private static func aggregateMatchesRequest(
        _ aggregate: AggregatePebble,
        request: JarAggregateRequest
    ) -> Bool {
        let calculation = request.calculation
        return aggregate.id == request.id
            && aggregate.level == calculation.level
            && aggregate.pebbleCount == calculation.pebbleCount
            && aggregate.childAggregateCount == calculation.childAggregateCount
            && aggregate.grams == calculation.grams
            && aggregate.measuredPebbleCount == calculation.measuredPebbleCount
            && aggregate.manualPebbleCount == calculation.manualPebbleCount
            && aggregate.goldPebbleCount == calculation.goldPebbleCount
            && aggregate.prismPebbleCount == calculation.prismPebbleCount
            && aggregate.colorMix == calculation.colorMix
            && aggregate.subjectMix == calculation.subjectMix
            && aggregate.periodStart == calculation.periodStart
            && aggregate.periodEnd == calculation.periodEnd
            && Set(aggregate.sessionIDs) == Set(calculation.sessionIDs)
            && Set(aggregate.childAggregateIDs) == Set(calculation.childAggregateIDs)
    }
}
