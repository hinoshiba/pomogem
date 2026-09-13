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
        NonnegativeIntPolicy.sum(levels.map(\.representedPebbleCount))
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
    static let maximumLooseSessionScanRows = looseSessionQueryLimit * 16
    static let aggregateRootLimit = Constants.Jar.maxPhysicsBodies
    static let achievementLimit = Constants.Jar.maximumVisibleAchievementStones * 2
    static let legacyCompatibilityLimit = 16
    /// One extra row is fetched for exact AggregatePebble membership and
    /// lineage lookups. Reaching the sentinel proves that the logical result
    /// cannot be selected safely inside the supported physical-copy bound.
    static let maximumPhysicalAggregateRowsPerExactLookup = 256

    /// Direct UI completions end at the current wall clock even when a focus
    /// spans its maximum seven-day recovery window. Older CloudKit imports are
    /// observed by the source-store notification + verification generation;
    /// this narrow @Query is only the synchronous local-change sentinel.
    static let localSessionChangeWindow =
        StudySessionIntegrityPolicy.maximumCompletionWallSpan

    static func sessionChangeSentinelDescriptor(
        relativeTo referenceDate: Date = .now,
        limit: Int = looseSessionQueryLimit
    ) -> FetchDescriptor<StudySession> {
        let start = referenceDate.addingTimeInterval(-localSessionChangeWindow)
        var descriptor = FetchDescriptor<StudySession>(
            predicate: #Predicate { $0.endAt >= start },
            sortBy: [
                SortDescriptor(\StudySession.endAt, order: .reverse),
                SortDescriptor(\StudySession.id, order: .reverse),
                SortDescriptor(\StudySession.syncRecordID, order: .reverse)
            ]
        )
        descriptor.fetchLimit = max(1, limit)
        return descriptor
    }

    static func looseSessionDescriptor() -> FetchDescriptor<StudySession> {
        var descriptor = FetchDescriptor<StudySession>(
            sortBy: [
                SortDescriptor(\StudySession.endAt, order: .reverse),
                SortDescriptor(\StudySession.id, order: .reverse),
                SortDescriptor(\StudySession.syncRecordID, order: .reverse)
            ]
        )
        descriptor.fetchLimit = looseSessionQueryLimit
        return descriptor
    }

    /// A fixed physical `@Query` page can be filled by invalid rows or losing
    /// CloudKit copies. The shared scanner exact-resolves each candidate ID and
    /// advances until its raw edge proves the logical boundary. At the hard
    /// cap Home receives only resolved groups and marks the projection as a
    /// lower bound; it never guesses an oversized group's winner.
    struct SupportedLooseSessionPage {
        let sessions: [StudySession]
        let scannedRowCount: Int
        let isCompleteForHomeCandidates: Bool
    }

    struct InitialLooseSessionQueryPlan: Equatable {
        let lowerBound: Date?
    }

    /// Small stores can be exhausted exactly, including old rootless data.
    /// Large stores use either the newest currently trusted aggregate as a
    /// useful suffix horizon or a recent fallback while CloudKit verification
    /// is pending. Neither horizon is a source-coverage certificate: omitted
    /// pre-horizon rows therefore remain an explicit lower bound.
    static func initialLooseSessionQueryPlan(
        physicalSessionRowCount: Int?,
        verifiedAggregateEnd: Date?,
        referenceDate: Date = .now
    ) -> InitialLooseSessionQueryPlan {
        if let physicalSessionRowCount,
           physicalSessionRowCount <= maximumLooseSessionScanRows {
            return InitialLooseSessionQueryPlan(
                lowerBound: nil
            )
        }
        return InitialLooseSessionQueryPlan(
            lowerBound: verifiedAggregateEnd
                ?? referenceDate.addingTimeInterval(-localSessionChangeWindow)
        )
    }

    /// A local-only source store needs one background repair request when Home
    /// cannot exhaust its rootless source rows. A trusted aggregate horizon is
    /// already maintained by the normal projection pipeline, so it must not
    /// trigger a full session generation on every launch.
    static func shouldRequestLocalSessionMaintenance(
        trustedAggregateHorizon: Date?,
        requestedLowerBound: Date?,
        pageIsComplete: Bool
    ) -> Bool {
        trustedAggregateHorizon == nil
            && (!pageIsComplete || requestedLowerBound != nil)
    }

    @MainActor
    static func supportedLooseSessionPage(
        context: ModelContext,
        resetMarkers: [ActivityResetSnapshot],
        startingAt lowerBound: Date? = nil
    ) throws -> SupportedLooseSessionPage {
        let page = try BoundedHistoryPolicy.resolvedSessionPage(
            context: context,
            epochID: ActivityResetPolicy.currentEpochID(from: resetMarkers),
            start: lowerBound,
            order: .reverse,
            logicalLimit: looseSessionQueryLimit,
            maximumCandidateRows: maximumLooseSessionScanRows,
            mode: .lowerBound
        )
        // There is currently no durable source-coverage certificate. A raw
        // Boolean must not be able to upgrade a suffix to complete; a future
        // implementation should accept a typed, validated certificate here.
        let requestedRangeIsComplete = lowerBound == nil
        return SupportedLooseSessionPage(
            sessions: page.sessions,
            scannedRowCount: page.scannedPhysicalRowCount,
            isCompleteForHomeCandidates: requestedRangeIsComplete
                && page.boundaryIsProven
                && !page.isPartial
        )
    }

    /// Resolve only the bounded pending reward IDs, even when their records
    /// precede Home's normal page. These are source candidates, not proof that
    /// an aggregate is verified: merge them into the existing membership
    /// projection and retain its accepted-root and cache-generation gates.
    /// Missing, quarantined and unsupported records remain unresolved. An
    /// oversized physical replica group throws rather than guessing a winner.
    @MainActor
    static func pendingRewardSessionCandidates(
        for receipts: [PendingRewardReceipt],
        context: ModelContext,
        resetMarkers: [ActivityResetSnapshot]
    ) throws -> [StudySession] {
        var seen = Set<UUID>()
        let pendingIDs = receipts
            .filter(\.requiresDrop)
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            .filter { seen.insert($0.id).inserted }
            .prefix(PendingRewardReceiptStore.maximumPendingCount)
            .map(\.id)
        let epochID = ActivityResetPolicy.currentEpochID(from: resetMarkers)
        return try pendingIDs.compactMap { id in
            guard let session = try BoundedHistoryPolicy.resolvedSession(
                id: id,
                epochID: epochID,
                context: context
            ), ActivityResetPolicy.isCurrent(session.dataEpochID, markers: resetMarkers),
               StudySessionIntegrityPolicy.isSupported(session)
            else { return nil }
            return session
        }
    }

    struct LocalMembershipProjection: Equatable {
        let representedSessionIDs: Set<UUID>
        let isCompleteForCandidates: Bool
        /// Presented roots that must be omitted for this frame. Keeping a
        /// candidate loose is not fail-safe when an ambiguous root summary is
        /// still counted, because that would make the same mass visible twice.
        let conflictedRootIDs: Set<UUID>
    }

    /// Resolves the only authoritative "grouped" signal: membership stored in
    /// this device's local projection store. `StudySession.isBaked` is a legacy
    /// synchronized field and is deliberately not consulted.
    ///
    /// Higher-level aggregates keep leaf IDs only in their level-one
    /// descendants, so a root-only query is insufficient. A late canonical
    /// StudySession winner can move outside the aggregate's persisted date
    /// span, so each bounded candidate is looked up by exact UUID membership.
    /// Every physical-copy lookup uses a 257th-row sentinel and refuses to
    /// choose a winner when the supported 256-row bound is exceeded.
    @MainActor
    static func localMembershipProjection(
        for candidateSessions: [StudySession],
        representedAggregateRoots: [AggregatePebble],
        legacyStrata: [Stratum] = [],
        context: ModelContext,
        resetMarkers: [ActivityResetSnapshot]
    ) throws -> LocalMembershipProjection {
        let canonicalCandidates = StudySessionSyncPolicy
            .canonicalSessions(from: candidateSessions)
            .filter {
                ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetMarkers)
            }
        let candidateIDs = Set(canonicalCandidates.map(\.id))
        guard !candidateIDs.isEmpty else {
            return LocalMembershipProjection(
                representedSessionIDs: [],
                isCompleteForCandidates: true,
                conflictedRootIDs: []
            )
        }

        var represented = Set<UUID>()
        var isComplete = true
        let roots = AggregatePebblePolicy.disjointRootSummaries(
            from: representedAggregateRoots.filter {
                ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetMarkers)
                    && $0.projectionValidationVersion
                        == AggregateProjectionValidation.currentVersion
            }
        )
        let representedRootIDs = Set(roots.map(\.id))
        var conflictedRootIDs = Set<UUID>()
        let currentEpochID = ActivityResetPolicy.currentEpochID(from: resetMarkers)
        let validationVersion = AggregateProjectionValidation.currentVersion
        let exactLimit = maximumPhysicalAggregateRowsPerExactLookup
        let sentinelLimit = exactLimit + 1

        enum ExactAggregateLookup {
            case value(AggregatePebble)
            case missing
            case ambiguous
        }
        enum PresentedRootResolution {
            case presented(UUID, additionallyConflicted: Set<UUID>)
            case outsidePresentedRoot(conflicted: Set<UUID>)
            case invalid
        }

        func isSameCanonicalPayload(
            _ lhs: AggregatePebble,
            _ rhs: AggregatePebble
        ) -> Bool {
            lhs.level == rhs.level
                && lhs.pebbleCount == rhs.pebbleCount
                && lhs.childAggregateCount == rhs.childAggregateCount
                && lhs.grams == rhs.grams
                && lhs.measuredPebbleCount == rhs.measuredPebbleCount
                && lhs.manualPebbleCount == rhs.manualPebbleCount
                && lhs.goldPebbleCount == rhs.goldPebbleCount
                && lhs.prismPebbleCount == rhs.prismPebbleCount
                && lhs.colorMixJSON == rhs.colorMixJSON
                && lhs.subjectMixJSON == rhs.subjectMixJSON
                && lhs.periodStart == rhs.periodStart
                && lhs.periodEnd == rhs.periodEnd
                && Set(lhs.sessionIDs) == Set(rhs.sessionIDs)
                && Set(lhs.childAggregateIDs) == Set(rhs.childAggregateIDs)
                && lhs.parentAggregateID == rhs.parentAggregateID
        }

        var exactAggregateCache: [UUID: ExactAggregateLookup] = [:]
        func exactAggregate(id: UUID) throws -> ExactAggregateLookup {
            if let cached = exactAggregateCache[id] { return cached }

            let predicate: Predicate<AggregatePebble>
            if let currentEpochID {
                let epochID = currentEpochID
                predicate = #Predicate { aggregate in
                    aggregate.id == id
                        && aggregate.dataEpochID == epochID
                        && aggregate.projectionValidationVersion == validationVersion
                }
            } else {
                predicate = #Predicate { aggregate in
                    aggregate.id == id
                        && aggregate.dataEpochID == nil
                        && aggregate.projectionValidationVersion == validationVersion
                }
            }
            var descriptor = FetchDescriptor<AggregatePebble>(
                predicate: predicate,
                sortBy: [SortDescriptor(\AggregatePebble.createdAt)]
            )
            descriptor.fetchLimit = sentinelLimit
            let rows = try context.fetch(descriptor)
            let result: ExactAggregateLookup
            if rows.count > exactLimit {
                result = .ambiguous
            } else if rows.isEmpty {
                result = .missing
            } else {
                // Match AggregatePebblePolicy's logical precedence only after
                // the raw edge proves that every supported physical copy was
                // observed. A backlink-bearing copy wins over a root copy,
                // followed by level and creation time.
                let parented = rows.filter { $0.parentAggregateID != nil }
                let candidates = parented.isEmpty ? rows : parented
                let maximumLevel = candidates.map(\.level).max() ?? 1
                let atMaximumLevel = candidates.filter { $0.level == maximumLevel }
                let latestCreatedAt = atMaximumLevel.map(\.createdAt).max() ?? .distantPast
                let winners = atMaximumLevel.filter { $0.createdAt == latestCreatedAt }
                if let winner = winners.first,
                   winners.allSatisfy({ isSameCanonicalPayload($0, winner) }) {
                    result = .value(winner)
                } else {
                    // Equal-precedence divergent replicas do not have a
                    // deterministic logical winner.
                    result = .ambiguous
                }
            }
            exactAggregateCache[id] = result
            return result
        }

        func resolvePresentedRoot(
            for aggregateID: UUID
        ) throws -> PresentedRootResolution {
            var cursorID = aggregateID
            var path: [UUID] = []
            var visited = Set<UUID>()
            let maximumDepth = 24

            for _ in 0..<maximumDepth {
                guard visited.insert(cursorID).inserted else {
                    return .invalid
                }
                path.append(cursorID)

                guard case .value(let current) = try exactAggregate(id: cursorID) else {
                    return .invalid
                }
                guard let parentID = current.parentAggregateID else {
                    var pathRootIDs = Set(path).intersection(representedRootIDs)
                    if representedRootIDs.contains(current.id) {
                        pathRootIDs.remove(current.id)
                        return .presented(
                            current.id,
                            additionallyConflicted: pathRootIDs
                        )
                    }
                    return .outsidePresentedRoot(conflicted: pathRootIDs)
                }

                guard current.level >= 1,
                      current.level < Int.max,
                      case .value(let parent) = try exactAggregate(id: parentID),
                      parent.level == NonnegativeIntPolicy.next(
                        after: current.level,
                        minimum: 1
                      ),
                      parent.parentAggregateID != parent.id,
                      Set(parent.childAggregateIDs).contains(current.id),
                      Set(parent.childAggregateIDs).count
                        == parent.childAggregateCount,
                      (1...Constants.Jar.aggregateFanIn)
                        .contains(parent.childAggregateCount)
                else {
                    return .invalid
                }
                cursorID = parent.id
            }
            return .invalid
        }

        var legacyRepresented = Set<UUID>()
        for stratum in legacyStrata {
            guard ActivityResetPolicy.isCurrent(
                stratum.dataEpochID,
                markers: resetMarkers
            ) else { continue }
            legacyRepresented.formUnion(
                Set(stratum.sessionIDs).intersection(candidateIDs)
            )
        }
        represented.formUnion(legacyRepresented)
        var aggregateOwnerRootBySessionID: [UUID: UUID] = [:]

        // Only an exact decoded leaf membership whose complete backlink chain
        // reaches a root actually presented by the caller may hide a session.
        // A malformed or over-cap ownership lookup excludes every presented
        // root for the frame; retaining any of them could turn fail-open loose
        // rendering into an accounting overstatement.
        if !representedRootIDs.isEmpty {
            for candidateID in candidateIDs.sorted(by: {
                $0.uuidString < $1.uuidString
            }) {
                let encodedID = candidateID.uuidString
                let predicate: Predicate<AggregatePebble>
                if let currentEpochID {
                    let epochID = currentEpochID
                    predicate = #Predicate { aggregate in
                        aggregate.dataEpochID == epochID
                            && aggregate.level == 1
                            && aggregate.projectionValidationVersion == validationVersion
                            && aggregate.sessionIDsJSON.contains(encodedID)
                    }
                } else {
                    predicate = #Predicate { aggregate in
                        aggregate.dataEpochID == nil
                            && aggregate.level == 1
                            && aggregate.projectionValidationVersion == validationVersion
                            && aggregate.sessionIDsJSON.contains(encodedID)
                    }
                }
                var descriptor = FetchDescriptor<AggregatePebble>(
                    predicate: predicate,
                    sortBy: [
                        SortDescriptor(\AggregatePebble.id),
                        SortDescriptor(\AggregatePebble.createdAt)
                    ]
                )
                descriptor.fetchLimit = sentinelLimit
                let stringMatches = try context.fetch(descriptor)
                guard stringMatches.count <= exactLimit else {
                    isComplete = false
                    conflictedRootIDs.formUnion(representedRootIDs)
                    continue
                }

                let exactOwnerIDs = Set(stringMatches.compactMap { aggregate in
                    Set(aggregate.sessionIDs).contains(candidateID)
                        ? aggregate.id : nil
                })
                var ownerRootIDs = Set<UUID>()
                var hasInvalidOwner = false
                for ownerID in exactOwnerIDs {
                    guard case .value(let leaf) = try exactAggregate(id: ownerID),
                          leaf.level == 1,
                          Set(leaf.sessionIDs).contains(candidateID),
                          Set(leaf.sessionIDs).count == leaf.pebbleCount,
                          (1...Constants.Jar.aggregateFanIn)
                            .contains(leaf.pebbleCount)
                    else {
                        hasInvalidOwner = true
                        continue
                    }
                    switch try resolvePresentedRoot(for: leaf.id) {
                    case .presented(let rootID, let additionallyConflicted):
                        ownerRootIDs.insert(rootID)
                        if !additionallyConflicted.isEmpty {
                            isComplete = false
                            conflictedRootIDs.formUnion(additionallyConflicted)
                        }
                    case .outsidePresentedRoot(let implicatedRootIDs):
                        // This owner is not part of the caller's displayed
                        // totals. Keep the session loose, but disclose that the
                        // local projection is not a complete accounting cut.
                        isComplete = false
                        conflictedRootIDs.formUnion(implicatedRootIDs)
                    case .invalid:
                        hasInvalidOwner = true
                    }
                }

                if hasInvalidOwner {
                    isComplete = false
                    conflictedRootIDs.formUnion(representedRootIDs)
                    continue
                }
                if ownerRootIDs.count == 1 {
                    let rootID = ownerRootIDs.first!
                    if legacyRepresented.contains(candidateID) {
                        // The legacy layer is also rendered. Prefer it and omit
                        // the overlapping aggregate instead of counting both.
                        isComplete = false
                        conflictedRootIDs.insert(rootID)
                    } else {
                        aggregateOwnerRootBySessionID[candidateID] = rootID
                    }
                } else if ownerRootIDs.count > 1 {
                    isComplete = false
                    conflictedRootIDs.formUnion(ownerRootIDs)
                }
            }
        }
        for (sessionID, rootID) in aggregateOwnerRootBySessionID
        where !conflictedRootIDs.contains(rootID) {
            represented.insert(sessionID)
        }
        return LocalMembershipProjection(
            representedSessionIDs: represented,
            isCompleteForCandidates: isComplete,
            conflictedRootIDs: conflictedRootIDs
        )
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

    /// A projection page whose payload was explicitly refreshed in the main
    /// ModelContext before it was bound to a verification lease. `@Query` is
    /// intentionally only a change trigger for Home: after a background
    /// CloudKit/maintenance save, a registered model can retain its old
    /// payload even though `fetchCount` already sees the updated store.
    struct RefreshedAggregatePresentationPage {
        let aggregateRoots: [AggregatePebble]
        let legacyStrata: [Stratum]
        let acceptedAggregateRootIDs: Set<UUID>
        let rootProjectionIsComplete: Bool
        let aggregateProjectionNeedsMaintenance: Bool
        let cacheStamp: AggregateProjectionCacheStamp
    }

    /// Performs value-bearing fetches for both projection formats in the main
    /// context. The returned stamp is inseparable from those refreshed model
    /// payloads, so callers cannot promote a pre-import `@Query` array merely
    /// because the verification pending flag became false.
    @MainActor
    static func refreshedAggregatePresentationPage(
        context: ModelContext,
        resetMarkers: [ActivityResetSnapshot],
        cacheStamp: AggregateProjectionCacheStamp
    ) throws -> RefreshedAggregatePresentationPage {
        let persistedRootCount = try context.fetchCount(
            FetchDescriptor<AggregatePebble>(
                predicate: #Predicate { aggregate in
                    aggregate.parentAggregateID == nil
                }
            )
        )
        // These explicit fetches are the important refresh boundary. A count
        // query alone does not update the value fields of registered models.
        let fetchedAggregateRoots = try context.fetch(aggregateRootDescriptor())
        let fetchedLegacyStrata = try context.fetch(legacyCompatibilityDescriptor())
        let aggregateRoots = fetchedAggregateRoots.filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetMarkers)
        }
        let legacyStrata = fetchedLegacyStrata.filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: resetMarkers)
        }
        let needsMaintenance = try hasUnverifiedAggregateProjection(
            context: context,
            resetMarkers: resetMarkers
        )
        let acceptedRootIDs = needsMaintenance
            ? []
            : try acceptedRootSummaryIDs(
                roots: aggregateRoots,
                context: context,
                resetMarkers: resetMarkers
            )
        let rootProjectionIsComplete = persistedRootCount <= aggregateRootLimit
            && (fetchedAggregateRoots.count < aggregateRootLimit
                || aggregateRoots.count == fetchedAggregateRoots.count)

        return RefreshedAggregatePresentationPage(
            aggregateRoots: aggregateRoots,
            legacyStrata: legacyStrata,
            acceptedAggregateRootIDs: acceptedRootIDs,
            rootProjectionIsComplete: rootProjectionIsComplete,
            aggregateProjectionNeedsMaintenance: needsMaintenance,
            cacheStamp: cacheStamp
        )
    }

    /// Any migrated or invalidated descendant makes the current aggregate
    /// snapshot non-authoritative. Callers then omit every root until
    /// maintenance rebuilds the complete versioned projection, preserving a
    /// lower bound without recursively materializing decades of descendants.
    @MainActor
    static func hasUnverifiedAggregateProjection(
        context: ModelContext,
        resetMarkers: [ActivityResetSnapshot]
    ) throws -> Bool {
        let currentEpochID = ActivityResetPolicy.currentEpochID(from: resetMarkers)
        let validationVersion = AggregateProjectionValidation.currentVersion
        let descriptor: FetchDescriptor<AggregatePebble>
        if let currentEpochID {
            let epochID = currentEpochID
            descriptor = FetchDescriptor(predicate: #Predicate { aggregate in
                aggregate.dataEpochID == epochID
                    && aggregate.projectionValidationVersion != validationVersion
            })
        } else {
            descriptor = FetchDescriptor(predicate: #Predicate { aggregate in
                aggregate.dataEpochID == nil
                    && aggregate.projectionValidationVersion != validationVersion
            })
        }
        return try context.fetchCount(descriptor) > 0
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
        let hasUnverifiedProjection = try hasUnverifiedAggregateProjection(
            context: context,
            resetMarkers: resetMarkers
        )
        guard !hasUnverifiedProjection else { return [] }
        var trusted = Set<UUID>()
        for root in AggregatePebblePolicy.activeRoots(from: roots) {
            let directCount = Set(root.sessionIDs).count
            if directCount > 0 {
                if directCount == root.pebbleCount,
                   root.level == 1,
                   directCount <= Constants.Jar.aggregateFanIn {
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
                    && $0.projectionValidationVersion
                        == AggregateProjectionValidation.currentVersion
            }
            let children = Dictionary(grouping: fetched, by: \.id).values.compactMap {
                $0.max { lhs, rhs in
                    if lhs.level == rhs.level { return lhs.createdAt < rhs.createdAt }
                    return lhs.level < rhs.level
                }
            }
            guard root.level > 0,
                  Set(children.map(\.id)) == expectedChildIDs,
                  children.allSatisfy({ $0.level == root.level - 1 }),
                  NonnegativeIntPolicy.sum(children.map(\.pebbleCount)) == root.pebbleCount,
                  NonnegativeIntPolicy.sum(children.map(\.grams)) == root.grams
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
        let uniqueLoose = StudySessionSyncPolicy.canonicalSessions(
            from: looseSessions
        )
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
        NonnegativeIntPolicy.sum(values)
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

    /// Aggregate-backed lifetime cadence plus a paged seven-day query. Every
    /// loose or weekly source page is logically deduplicated; no multi-decade
    /// collection of source model objects is materialized on Home.
    @MainActor
    static func completionMetrics(
        context: ModelContext,
        resetMarkers: [ActivityResetSnapshot],
        roots: [AggregatePebble],
        looseSessions: [StudySession],
        at date: Date,
        calendar: Calendar = .autoupdatingCurrent,
        maximumWeeklyPhysicalRows: Int = BoundedHistoryPolicy.weeklySessionRowLimit
    ) throws -> CompletionMetrics {
        // The accepted aggregate summaries already carry exact measured counts,
        // so the long-break cadence does not need to instantiate every historic
        // StudySession. This also avoids SwiftData's runtime-unsupported enum
        // predicates. Home passes only validated roots plus its bounded loose
        // page, making this calculation O(number of rendered bodies).
        let uniqueLoose = StudySessionSyncPolicy.canonicalSessions(
            from: looseSessions
        )
        let completedCount = saturatingNonnegativeSum([
            saturatingNonnegativeSum(roots.map(\.measuredPebbleCount)),
            uniqueLoose.filter { $0.source.isMeasured }.count
        ])

        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else {
            return CompletionMetrics(
                completedFocusCount: completedCount,
                weeklyMeasuredSessionIDs: [],
                weeklyMeasuredDates: [],
                weeklyMeasuredGrams: 0
            )
        }
        // Source remains an in-memory filter for SwiftData compatibility, but
        // logical resolution and interval membership happen first. A losing
        // in-week row therefore cannot survive when its canonical copy is just
        // outside the week, and an adversarial dense week fails at a hard cap.
        let unique = try BoundedHistoryPolicy.resolvedSessionsInFiniteInterval(
            context: context,
            epochID: ActivityResetPolicy.currentEpochID(from: resetMarkers),
            interval: interval,
            maximumPhysicalRows: maximumWeeklyPhysicalRows
        )
            .filter { $0.source.isMeasured }
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
    case projectionBusy
}

/// AggregatePebble is a device-local, derived projection with two writers:
/// foreground jar fusion and background maintenance. Serializing their full
/// preflight-to-save transactions closes the otherwise unavoidable gap between
/// an ownership read and insertion of a differently grouped deterministic ID.
enum AggregateProjectionMutationGate {
    private static let lock = NSLock()

    static func withMaintenanceAccess<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    static func tryAcquireForegroundAccess() -> Bool {
        lock.try()
    }

    static func releaseForegroundAccess() {
        lock.unlock()
    }
}

enum HomeAggregatePersistence {
    private struct Preflight {
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
        guard AggregateProjectionMutationGate.tryAcquireForegroundAccess() else {
            throw HomeAggregatePersistenceError.projectionBusy
        }
        defer { AggregateProjectionMutationGate.releaseForegroundAccess() }
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
              sourceLevel >= 0,
              sourceLevel < Int.max,
              sources.allSatisfy({ $0.level == sourceLevel }),
              request.outputLevel == NonnegativeIntPolicy.next(after: sourceLevel),
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

        for source in sources {
            let sourceID = source.id
            let current: StudySession?
            do {
                current = try BoundedHistoryPolicy.resolvedSession(
                    id: sourceID,
                    epochID: ActivityResetPolicy.currentEpochID(from: resetMarkers),
                    context: context
                )
            } catch {
                // More than 256 physical replicas cannot be safely reduced on
                // the foreground path. Maintenance retains every source copy
                // and retries while Home leaves the projection uncommitted.
                throw HomeAggregatePersistenceError.conflictingSource(sourceID)
            }
            guard let current else {
                throw HomeAggregatePersistenceError.missingCurrentSource(sourceID)
            }
            guard sessionMatchesSource(current, source: source) else {
                throw HomeAggregatePersistenceError.conflictingSource(sourceID)
            }

            // The old synchronized `StudySession.isBaked` bit can arrive
            // without this device's projection row. Ownership is therefore
            // proved only by an exact local AggregatePebble membership.
            let encodedID = sourceID.uuidString
            let epochID = ActivityResetPolicy.currentEpochID(from: resetMarkers)
            let validationVersion = AggregateProjectionValidation.currentVersion
            let predicate: Predicate<AggregatePebble>
            if let epochID {
                predicate = #Predicate { aggregate in
                    aggregate.dataEpochID == epochID
                        && aggregate.projectionValidationVersion
                            == validationVersion
                        && aggregate.level == 1
                        && aggregate.sessionIDsJSON.contains(encodedID)
                }
            } else {
                predicate = #Predicate { aggregate in
                    aggregate.dataEpochID == nil
                        && aggregate.projectionValidationVersion
                            == validationVersion
                        && aggregate.level == 1
                        && aggregate.sessionIDsJSON.contains(encodedID)
                }
            }
            var membershipDescriptor = FetchDescriptor<AggregatePebble>(
                predicate: predicate,
                sortBy: [SortDescriptor(\AggregatePebble.id)]
            )
            membershipDescriptor.fetchLimit = BoundedHistoryPolicy
                .maximumPhysicalRowsPerLogicalSession + 1
            let candidates = try context.fetch(membershipDescriptor)
            guard candidates.count
                    <= BoundedHistoryPolicy.maximumPhysicalRowsPerLogicalSession
            else {
                throw HomeAggregatePersistenceError.alreadyConsumedSource(sourceID)
            }
            let owners = candidates.filter {
                Set($0.sessionIDs).contains(sourceID)
            }
            guard owners.allSatisfy({ $0.id == request.id }) else {
                throw HomeAggregatePersistenceError.alreadyConsumedSource(sourceID)
            }
        }
        return Preflight(
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
            childrenToAdopt: childrenToAdopt,
            shouldInsertAggregate: !isIdempotentReplay
        )
    }

    private static func sessionMatchesSource(
        _ session: StudySession,
        source: AggregateSource
    ) -> Bool {
        let isMeasured = session.source.isMeasured
        return StudySessionIntegrityPolicy.isSupported(session)
            && session.id == source.id
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
