import Foundation

/// Everything a share card is built from, resolved once from the composer's
/// bounded records.
///
/// The composer used to derive these values in a chain of uncached computed
/// properties over up to 2,048 SwiftData rows. One body pass re-ran session
/// canonicalization about nine times, plus twice per aggregate root for every
/// read of the aggregate list, so each hashtag keystroke, chip, picker or
/// toggle change froze the sheet for 150 ms to about 1 s on a 6–12-month
/// history (history-10). The rules below are the same ones, in the same
/// order; they now run once in `make(_:)`, and `ShareSelectionCache` keeps the
/// result until an input named in `ShareSelectionInput.Key` changes. Preview,
/// caption, photo save and export all read this one value, so they cannot
/// drift apart.
struct ShareSelectionModel {
    /// Card content.
    let sessions: [ShareSessionVisual]
    let aggregates: [ShareAggregateVisual]
    let achievements: [ShareAchievementVisual]
    /// Aggregate visuals index the sessions they contain, so only
    /// compatibility aggregates without membership add mass of their own.
    let totalGrams: Int

    /// Whether the card actually contains self-reported focus, rather than
    /// the state of the toggle. Membership-less compatibility aggregates are
    /// only included when self-reporting is on, so their unknown composition
    /// is disclosed as self-reported.
    let includesSelfReportedFocus: Bool
    /// Self-reported focus exists in this scope but the card leaves it out.
    let hasExcludedSelfReportedContent: Bool
    /// Mass of the self-reported sessions left out, when it is known exactly
    /// (only individual records are excluded and the page is complete).
    let excludedSelfReportedGrams: Int?
    /// Facts the empty state explains without re-reading the records.
    let scopeHasSelfReportedSessions: Bool
    let scopedAggregateHasSelfReportedPebbles: Bool

    let usesCompactRootProjection: Bool
    let compactProjectionIsIncomplete: Bool

    /// Persisted rows the bounded load hands to the local membership
    /// projection. They are read only inside that load.
    let scopedAggregates: [AggregatePebble]
    let scopedLegacyStrata: [Stratum]

    var hasShareableContent: Bool {
        !sessions.isEmpty
            || !aggregates.isEmpty
            || !achievements.isEmpty
            || totalGrams > 0
    }

    static let empty = ShareSelectionModel(
        sessions: [],
        aggregates: [],
        achievements: [],
        totalGrams: 0,
        includesSelfReportedFocus: false,
        hasExcludedSelfReportedContent: false,
        excludedSelfReportedGrams: nil,
        scopeHasSelfReportedSessions: false,
        scopedAggregateHasSelfReportedPebbles: false,
        usesCompactRootProjection: false,
        compactProjectionIsIncomplete: false,
        scopedAggregates: [],
        scopedLegacyStrata: []
    )
}

/// The composer state a `ShareSelectionModel` is derived from.
struct ShareSelectionInput {
    var scope: ShareScope
    var includeManual: Bool
    var resetSnapshots: [ActivityResetSnapshot]
    /// `AggregateProjectionPresentationContext.allowsAggregateSummaries`.
    var allowsAggregateSummaries: Bool
    /// Whether the loaded aggregate page carries the currently verified
    /// cache stamp; otherwise aggregates and legacy strata are ignored.
    var acceptsVerifiedAggregateCache: Bool
    var storedSessions: [StudySession]
    var looseSessions: [StudySession]
    var storedAchievementStones: [AchievementStone]
    var storedAggregatePebbles: [AggregatePebble]
    var storedStrata: [Stratum]
    var acceptedAggregateRootIDs: Set<UUID>
    var localRepresentedSessionIDs: Set<UUID>
    var historyPageIsPartial: Bool
    var loosePageIsPartial: Bool
    var aggregatePageIsPartial: Bool
    var aggregateValidationIsIncomplete: Bool
    var allSessionRowCount: Int

    /// Cheap identity of every input. The record arrays and page flags only
    /// change together inside the composer's load and invalidation paths,
    /// which bump `recordsGeneration`; the rest is compared directly.
    struct Key: Equatable {
        let recordsGeneration: Int
        let scope: ShareScope
        let includeManual: Bool
        let resetSnapshots: [ActivityResetSnapshot]
        let allowsAggregateSummaries: Bool
        let acceptsVerifiedAggregateCache: Bool
    }
}

/// Memoizes the selection across body passes. A reference type, so reading
/// or refilling it during `body` is invisible to SwiftUI and never schedules
/// another update.
@MainActor
final class ShareSelectionCache {
    private var key: ShareSelectionInput.Key?
    private var model: ShareSelectionModel?

#if DEBUG
    /// Evidence for tests and the UI-test probe: how often a selection was
    /// resolved versus reused in this process.
    static private(set) var debugBuildCount = 0
    static private(set) var debugLookupCount = 0
#endif

    func model(
        for key: ShareSelectionInput.Key,
        build: () -> ShareSelectionModel
    ) -> ShareSelectionModel {
#if DEBUG
        Self.debugLookupCount += 1
#endif
        if let model, self.key == key { return model }
        let resolved = build()
        self.key = key
        model = resolved
#if DEBUG
        Self.debugBuildCount += 1
#endif
        return resolved
    }
}

extension ShareSelectionModel {
    // Each step mirrors one former computed property of ShareComposerView
    // and keeps its comment; only repeated work and per-root full scans
    // were removed.
    static func make(_ input: ShareSelectionInput) -> ShareSelectionModel {
        let markers = input.resetSnapshots
        let includeManual = input.includeManual
        let scope = input.scope
        let allowsSummaries = input.allowsAggregateSummaries

        let sessions = input.storedSessions.filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: markers)
                && StudySessionIntegrityPolicy.isSupported($0)
        }
        let achievementStones = input.storedAchievementStones.filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: markers)
        }
        let aggregatePebbles = input.acceptsVerifiedAggregateCache
            ? input.storedAggregatePebbles.filter {
                ActivityResetPolicy.isCurrent($0.dataEpochID, markers: markers)
            }
            : []
        let strata = input.acceptsVerifiedAggregateCache
            ? input.storedStrata.filter {
                ActivityResetPolicy.isCurrent($0.dataEpochID, markers: markers)
            }
            : []

        let uniqueSessions = StudySessionSyncPolicy.canonicalSessions(from: sessions)
            .sorted { $0.endAt < $1.endAt }
        let uniqueLooseSessions = StudySessionSyncPolicy.canonicalSessions(
            from: input.looseSessions
        )
        .sorted { $0.endAt < $1.endAt }
        let compactLooseSessions = uniqueLooseSessions.filter {
            !input.localRepresentedSessionIDs.contains($0.id)
        }
        let uniqueAggregates = Dictionary(grouping: aggregatePebbles, by: \.id)
            .values
            .compactMap { duplicates in
                duplicates.max { lhs, rhs in
                    if lhs.level == rhs.level { return lhs.createdAt < rhs.createdAt }
                    return lhs.level < rhs.level
                }
            }
            .sorted { $0.createdAt < $1.createdAt }
        let uniqueAchievements = AchievementStonePolicy.canonicalStones(from: achievementStones)
            .filter { $0.deletedAt == nil }
            .sorted { $0.achievedAt < $1.achievedAt }
        let uniqueStrata = Dictionary(grouping: strata, by: \.id).values
            .compactMap { duplicates in
                duplicates.min { lhs, rhs in lhs.bakedAt < rhs.bakedAt }
            }
            .sorted { $0.bakedAt < $1.bakedAt }

        // Canonical sessions are unique by ID. Membership lookups go through
        // this index instead of scanning every session once per aggregate
        // root, and keep the chronological order the scan produced.
        let uniqueSessionPosition = Dictionary(
            uniqueKeysWithValues: uniqueSessions.enumerated().map { ($1.id, $0) }
        )
        func uniqueMembers(_ membership: Set<UUID>) -> [StudySession] {
            membership
                .compactMap { uniqueSessionPosition[$0] }
                .sorted()
                .map { uniqueSessions[$0] }
        }

        let scopedSessions: [StudySession]
        switch scope {
        case .all:
            scopedSessions = uniqueSessions
        case .month:
            scopedSessions = uniqueSessions.filter { scope.contains($0.endAt) }
        case let .aggregate(id, _):
            if !allowsSummaries {
                scopedSessions = []
            } else if let aggregate = uniqueAggregates.first(where: { $0.id == id }) {
                scopedSessions = uniqueMembers(Set(AggregatePebblePolicy.descendantSessionIDs(
                    of: aggregate,
                    in: uniqueAggregates
                )))
            } else if let layer = uniqueStrata.first(where: { $0.id == id }) {
                scopedSessions = uniqueMembers(Set(layer.sessionIDs))
            } else {
                scopedSessions = []
            }
        }
        let scopedSessionIDs = Set(scopedSessions.map(\.id))

        let scopedAggregates: [AggregatePebble]
        if !allowsSummaries {
            scopedAggregates = []
        } else {
            switch scope {
            case .all:
                let trusted = uniqueAggregates.filter {
                    input.acceptedAggregateRootIDs.contains($0.id)
                }
                scopedAggregates = AggregatePebblePolicy.disjointRootSummaries(from: trusted)
            case .month:
                scopedAggregates = AggregatePebblePolicy.activeRoots(from: uniqueAggregates)
                    .filter {
                        let membership = AggregatePebblePolicy.descendantSessionIDs(
                            of: $0,
                            in: uniqueAggregates
                        )
                        return !membership.isEmpty
                            && !scopedSessionIDs.isDisjoint(with: membership)
                    }
            case let .aggregate(id, _):
                scopedAggregates = uniqueAggregates.filter { $0.id == id }
            }
        }

        let scopedAchievements: [AchievementStone]
        switch scope {
        case .all:
            scopedAchievements = uniqueAchievements
        case .month:
            scopedAchievements = uniqueAchievements.filter { scope.contains($0.achievedAt) }
        case .aggregate:
            scopedAchievements = []
        }

        let scopedLegacyStrata: [Stratum]
        if !allowsSummaries {
            scopedLegacyStrata = []
        } else {
            switch scope {
            case .all:
                scopedLegacyStrata = uniqueStrata
            case .month:
                scopedLegacyStrata = uniqueStrata.filter {
                    !$0.sessionIDs.isEmpty && !scopedSessionIDs.isDisjoint(with: $0.sessionIDs)
                }
            case let .aggregate(id, _):
                scopedLegacyStrata = uniqueStrata.filter { $0.id == id }
            }
        }

        let modernIDs = Set(uniqueAggregates.map(\.id))
        let distinctLegacyStrata = scopedLegacyStrata.filter { !modernIDs.contains($0.id) }

        let scopedAggregateProjection: ScopedAggregateShareProjection?
        if case .aggregate = scope, let aggregate = scopedAggregates.first {
            scopedAggregateProjection = .mode(
                for: aggregate,
                includesSelfReportedFocus: includeManual
            )
        } else {
            scopedAggregateProjection = nil
        }

        let usesCompactRootProjection: Bool
        if allowsSummaries,
           scope == .all,
           input.historyPageIsPartial,
           !scopedAggregates.isEmpty || !distinctLegacyStrata.isEmpty {
            usesCompactRootProjection = CompactShareProjectionPolicy.canUseLifetimeRoots(
                includesSelfReportedFocus: includeManual,
                modernSummaryComposition: scopedAggregates.map {
                    .init(
                        pebbleCount: $0.pebbleCount,
                        measuredPebbleCount: $0.measuredPebbleCount,
                        manualPebbleCount: $0.manualPebbleCount
                    )
                },
                hasLegacySummaries: !distinctLegacyStrata.isEmpty,
                looseSources: compactLooseSessions.map(\.effectiveSource)
            )
        } else {
            usesCompactRootProjection = false
        }

        let compactProjectionIsIncomplete: Bool
        if !usesCompactRootProjection {
            compactProjectionIsIncomplete = false
        } else if input.aggregatePageIsPartial
            || input.aggregateValidationIsIncomplete
            || input.loosePageIsPartial {
            compactProjectionIsIncomplete = true
        } else {
            let scopedModernIDs = Set(scopedAggregates.map(\.id))
            let represented = NonnegativeIntPolicy.sum(
                scopedAggregates.map(\.pebbleCount)
                    + scopedLegacyStrata
                        .filter { !scopedModernIDs.contains($0.id) }
                        .map(\.pebbleCount)
                    + [compactLooseSessions.count]
            )
            // Logical CloudKit duplicates make this conservative ("読み込み分")
            // rather than allowing a partial compact projection to claim lifetime.
            compactProjectionIsIncomplete = represented != input.allSessionRowCount
        }

        let selectedSessions: [StudySession]
        if scopedAggregateProjection == .authoritativeSummary {
            // A scoped aggregate summary already owns the exact mass/counts.
            // Passing its descendants as loose rows would count every reward
            // twice in the preview, export, caption, and accessibility value.
            selectedSessions = []
        } else if usesCompactRootProjection {
            // Compact roots are local projections. Only exact local leaf or
            // legacy membership can remove a synchronized session candidate.
            selectedSessions = compactLooseSessions
        } else {
            selectedSessions = includeManual
                ? scopedSessions
                : scopedSessions.filter { $0.effectiveSource.isMeasured }
        }

        // A compatibility summary without membership has an unknown mix
        // unless its counts say every pebble was measured; only then does a
        // measured-only card keep it.
        func isExplicitlyAllMeasured(_ aggregate: AggregatePebble) -> Bool {
            aggregate.manualPebbleCount == 0
                && aggregate.measuredPebbleCount == aggregate.pebbleCount
                && aggregate.pebbleCount > 0
        }

        let selectedAggregates: [ShareAggregateVisual]
        if usesCompactRootProjection {
            let modern = scopedAggregates.map(ShareAggregateVisual.init(aggregateSummary:))
            let legacy = distinctLegacyStrata.map(ShareAggregateVisual.init(legacySummary:))
            selectedAggregates = (modern + legacy).sorted { $0.createdAt < $1.createdAt }
        } else if scopedAggregateProjection == .authoritativeSummary,
                  let aggregate = scopedAggregates.first {
            selectedAggregates = [ShareAggregateVisual(aggregateSummary: aggregate)]
        } else {
            // `selectedSessions` is an ordered subset of `uniqueSessions`
            // here, so filtering each root's members by these IDs yields the
            // same rows, in the same order, as filtering `selectedSessions`.
            let selectedIDs = Set(selectedSessions.map(\.id))
            let modern = scopedAggregates.compactMap { aggregate -> ShareAggregateVisual? in
                let resolvedMembership = AggregatePebblePolicy.descendantSessionIDs(
                    of: aggregate,
                    in: uniqueAggregates
                )
                let membership = Set(resolvedMembership)
                if membership.isEmpty {
                    // A compact parent arriving before its children is not a
                    // membership-less legacy summary. Omitting that transient
                    // visual prevents its full mass being added on top of sessions.
                    guard AggregatePebblePolicy.isUnattributedCompatibility(aggregate) else {
                        return nil
                    }
                    return includeManual || isExplicitlyAllMeasured(aggregate)
                        ? ShareAggregateVisual(aggregate: aggregate)
                        : nil
                }
                let members = uniqueMembers(membership)
                return ShareAggregateVisual(
                    reconstructing: aggregate,
                    resolvedSessionIDs: resolvedMembership,
                    allMemberSessions: members,
                    includedMemberSessions: members.filter { selectedIDs.contains($0.id) }
                )
            }
            let legacy = distinctLegacyStrata.compactMap { layer -> ShareAggregateVisual? in
                let membership = Set(layer.sessionIDs)
                if membership.isEmpty {
                    return includeManual ? ShareAggregateVisual(legacy: layer) : nil
                }
                let members = uniqueMembers(membership)
                return ShareAggregateVisual(
                    reconstructing: layer,
                    allMemberSessions: members,
                    includedMemberSessions: members.filter { selectedIDs.contains($0.id) }
                )
            }
            selectedAggregates = (modern + legacy).sorted { $0.createdAt < $1.createdAt }
        }

        let totalGrams = NonnegativeIntPolicy.sum(
            selectedSessions.map(\.grams)
                + selectedAggregates
                    .filter(\.contributesStandaloneTotals)
                    .map(\.grams)
        )

        let hasUnknownSelfReportComposition: Bool
        if includeManual {
            let unknownModernIDs = Set(scopedAggregates
                .filter(AggregatePebblePolicy.isUnattributedCompatibility)
                .map(\.id))
            let scopedModernIDs = Set(scopedAggregates.map(\.id))
            let unknownLegacyIDs = Set(scopedLegacyStrata
                .filter { !scopedModernIDs.contains($0.id) && $0.sessionIDs.isEmpty }
                .map(\.id))
            let unknownIDs = unknownModernIDs.union(unknownLegacyIDs)
            hasUnknownSelfReportComposition = selectedAggregates.contains {
                unknownIDs.contains($0.id)
            }
        } else {
            hasUnknownSelfReportComposition = false
        }

        let includesSelfReportedFocus = selectedSessions.contains {
            $0.effectiveSource.isSelfReported
        }
            || selectedAggregates.contains { $0.manualPebbleCount > 0 }
            || hasUnknownSelfReportComposition

        let scopedSelfReportedSessions = scopedSessions.filter {
            $0.effectiveSource.isSelfReported
        }
        let scopedAggregateHasSelfReportedPebbles = scopedAggregates.contains {
            $0.manualPebbleCount > 0
        }
        // An all-measured compatibility summary stays on a measured-only
        // card, so it hides nothing; saying 「自己申告は除外」 for it would
        // name an exclusion that did not happen.
        let summariesHideSelfReportedContent = scopedAggregates.contains {
            $0.manualPebbleCount > 0
                || (AggregatePebblePolicy.isUnattributedCompatibility($0)
                    && !isExplicitlyAllMeasured($0))
        }
            || scopedLegacyStrata.contains { $0.sessionIDs.isEmpty }
        let hasExcludedSelfReportedContent = !includeManual
            && (!scopedSelfReportedSessions.isEmpty || summariesHideSelfReportedContent)
        // Name an amount only when it is exact: the excluded part is made of
        // individual records and the page holds every record in scope.
        let excludedSelfReportedGrams: Int? = hasExcludedSelfReportedContent
            && !summariesHideSelfReportedContent
            && !input.historyPageIsPartial
            ? NonnegativeIntPolicy.sum(scopedSelfReportedSessions.map(\.grams))
            : nil

        return ShareSelectionModel(
            sessions: selectedSessions.map(ShareSessionVisual.init),
            aggregates: selectedAggregates,
            achievements: scopedAchievements.map(ShareAchievementVisual.init),
            totalGrams: totalGrams,
            includesSelfReportedFocus: includesSelfReportedFocus,
            hasExcludedSelfReportedContent: hasExcludedSelfReportedContent,
            excludedSelfReportedGrams: excludedSelfReportedGrams,
            scopeHasSelfReportedSessions: !scopedSelfReportedSessions.isEmpty,
            scopedAggregateHasSelfReportedPebbles: scopedAggregateHasSelfReportedPebbles,
            usesCompactRootProjection: usesCompactRootProjection,
            compactProjectionIsIncomplete: compactProjectionIsIncomplete,
            scopedAggregates: scopedAggregates,
            scopedLegacyStrata: scopedLegacyStrata
        )
    }
}
