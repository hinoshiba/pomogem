import Foundation
import SwiftData

struct GachaHistorySnapshot: Equatable, Sendable {
    let id: UUID
    let endAt: Date
    let seconds: Int
    let source: SessionSource
    let pebbleKind: PebbleKind
    let rareRewardRuleVersion: Int?
    let rareRewardParticipated: Bool?
    let rareRewardCreditedGrams: Int?
    let rareRewardOutcomes: [PebbleKind]?

    init(
        id: UUID,
        endAt: Date,
        seconds: Int,
        source: SessionSource,
        pebbleKind: PebbleKind,
        rareRewardRuleVersion: Int? = nil,
        rareRewardParticipated: Bool? = nil,
        rareRewardCreditedGrams: Int? = nil,
        rareRewardOutcomes: [PebbleKind]? = nil
    ) {
        self.id = id
        self.endAt = endAt
        self.seconds = seconds
        self.source = source
        self.pebbleKind = pebbleKind
        self.rareRewardRuleVersion = rareRewardRuleVersion
        self.rareRewardParticipated = rareRewardParticipated
        self.rareRewardCreditedGrams = rareRewardCreditedGrams
        self.rareRewardOutcomes = rareRewardOutcomes
    }
}

enum GachaHistoryReconciliationPolicy {
    /// SwiftData can persist `SessionSource`, but its SQLite predicate bridge
    /// cannot filter enum values (it throws `unsupportedPredicate` at runtime).
    /// Read a deliberately bounded candidate window, then apply the source
    /// rule in pure Swift. The synced scalar remains authoritative when a
    /// pathological run of newer self-reported rows hides an older timer, so
    /// this bounded fallback can never lower earned pity progress.
    static let maximumCandidateRecordCount = 512

    private struct LogicalRewardEvent {
        let endAt: Date
        let id: UUID
        let outcomes: [PebbleKind]
        /// Nil identifies a legacy completion whose mass must not be
        /// retroactively added to the new credit ledger.
        let creditedGrams: Int?
    }

    /// CloudKit can deliver StudySession rows before the GachaState that was
    /// updated in the same logical completion. The observed history is therefore
    /// only a lower bound during a generic import: it may advance known progress,
    /// but it must never reset or decrease a counter that could include rows not
    /// present locally yet. A local gold draw still resets GachaState atomically
    /// in FocusView before this generic repair runs.
    static func reconciledProgress(
        knownProgress: Int,
        sessions: [GachaHistorySnapshot]
    ) -> Int {
        var observedMisses = 0
        creditLoop: for event in logicalRewardEvents(sessions).reversed() {
            for outcome in event.outcomes.reversed() {
                if outcome == .gold { break creditLoop }
                observedMisses += 1
                if observedMisses == Constants.Gacha.pityMissCount {
                    break creditLoop
                }
            }
        }
        return max(max(0, knownProgress), observedMisses)
    }

    /// Lower bound derived only from versioned participating rows. Legacy
    /// sessions intentionally contribute nil so their old 60-minute completion
    /// is never retroactively converted from one draw into two credits.
    static func observedRewardCreditGrams(
        sessions: [GachaHistorySnapshot]
    ) -> Int {
        logicalRewardEvents(sessions).reduce(into: 0) { total, event in
            guard let creditedGrams = event.creditedGrams else { return }
            total += min(max(0, creditedGrams), Int.max - total)
        }
    }

    private static func logicalRewardEvents(
        _ sessions: [GachaHistorySnapshot]
    ) -> [LogicalRewardEvent] {
        Dictionary(grouping: sessions, by: \.id).values
            .compactMap { duplicates -> LogicalRewardEvent? in
                // Fairness-sensitive eligibility is conservative. A demoted or
                // otherwise self-reported physical copy prevents a concurrent
                // measured duplicate from restoring reward participation.
                guard duplicates.allSatisfy({ $0.source == .timer }),
                      let endAt = duplicates.map(\.endAt).min(),
                      let first = duplicates.first else { return nil }

                let versioned = duplicates.filter {
                    $0.rareRewardRuleVersion != nil
                }
                if !versioned.isEmpty {
                    let newestRule = versioned
                        .compactMap(\.rareRewardRuleVersion)
                        .max() ?? Constants.Gacha.creditRuleVersion
                    let sameRule = versioned.filter {
                        $0.rareRewardRuleVersion == newestRule
                    }
                    guard newestRule == Constants.Gacha.creditRuleVersion
                            || newestRule == RareRewardLedgerV2.ruleVersion else {
                        return LogicalRewardEvent(
                            endAt: endAt,
                            id: first.id,
                            outcomes: [],
                            creditedGrams: 0
                        )
                    }
                    // V2 materializes a deliberately outcome-free StudySession
                    // before its custom-zone receipt is available. Ignore those
                    // pending physical copies when a finalized copy has already
                    // arrived, and never let a pending-only row advance the cache.
                    let finalized = newestRule == RareRewardLedgerV2.ruleVersion
                        ? sameRule.filter { $0.rareRewardParticipated != nil }
                        : sameRule
                    guard !finalized.isEmpty else {
                        return LogicalRewardEvent(
                            endAt: endAt,
                            id: first.id,
                            outcomes: [],
                            creditedGrams: 0
                        )
                    }
                    guard finalized.allSatisfy({
                        $0.rareRewardParticipated == true
                    }) else {
                        return LogicalRewardEvent(
                            endAt: endAt,
                            id: first.id,
                            outcomes: [],
                            creditedGrams: 0
                        )
                    }
                    let creditedValues = finalized.compactMap(
                        \.rareRewardCreditedGrams
                    )
                    let outcomeValues = finalized.compactMap(
                        \.rareRewardOutcomes
                    )
                    // A partially delivered or conflicting duplicate is not
                    // evidence for advancing a fairness-sensitive counter.
                    guard creditedValues.count == finalized.count,
                          Set(creditedValues).count == 1,
                          outcomeValues.count == finalized.count,
                          Set(outcomeValues.map {
                            RareRewardOutcomeCodec.encode($0)
                          }).count == 1,
                          let creditedGrams = creditedValues.first,
                          (0 ... Constants.Gacha.maximumCreditableGramsPerCompletion)
                            .contains(creditedGrams),
                          let outcomes = outcomeValues.first,
                          RareRewardCreditPolicy.isPossibleOutcomeCount(
                            outcomes.count,
                            forContributionGrams: creditedGrams
                          ) else {
                        return LogicalRewardEvent(
                            endAt: endAt,
                            id: first.id,
                            outcomes: [],
                            creditedGrams: 0
                        )
                    }
                    return LogicalRewardEvent(
                        endAt: endAt,
                        id: first.id,
                        outcomes: outcomes,
                        creditedGrams: max(0, creditedGrams)
                    )
                }

                // Pre-credit versions granted at most one draw per qualifying
                // completion. Preserve that rule only as a lower-bound repair;
                // never add legacy mass to the new remainder ledger.
                guard let seconds = duplicates.map(\.seconds).max(),
                      seconds >= Constants.Gacha.minimumEligibleSeconds else {
                    return nil
                }
                return LogicalRewardEvent(
                    endAt: endAt,
                    id: first.id,
                    outcomes: [StudySessionSyncPolicy.mergedPebbleKind(
                        duplicates.map(\.pebbleKind)
                    )],
                    creditedGrams: nil
                )
            }
            .sorted { lhs, rhs in
                if lhs.endAt == rhs.endAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.endAt < rhs.endAt
            }
    }
}

enum SeedData {
    struct Preset: Identifiable, Hashable {
        let id: UUID
        let name: String
        let colorHex: String
    }

    private static let prefsID = UUID(uuidString: "7473756D-6962-456E-8000-000000000001")!
    private static let gachaID = UUID(uuidString: "7473756D-6962-456E-8000-000000000002")!

    static let subjects: [Preset] = [
        Preset(id: UUID(uuidString: "7473756D-6962-456E-8000-000000000101")!, name: "英語", colorHex: Constants.Color.english),
        Preset(id: UUID(uuidString: "7473756D-6962-456E-8000-000000000102")!, name: "数学", colorHex: Constants.Color.mathematics),
        Preset(id: UUID(uuidString: "7473756D-6962-456E-8000-000000000103")!, name: "国語", colorHex: Constants.Color.japanese),
        Preset(id: UUID(uuidString: "7473756D-6962-456E-8000-000000000104")!, name: "理科", colorHex: Constants.Color.science),
        Preset(id: UUID(uuidString: "7473756D-6962-456E-8000-000000000105")!, name: "社会", colorHex: Constants.Color.socialStudies)
    ]

    @MainActor
    static func bootstrap(context: ModelContext) throws {
        let resetMarkers = try ActivityResetStore.snapshots(context: context)
        // Cloud-authored records and the rebuildable local projection live in
        // separate persistent stores. A ModelContext save spanning both stores
        // is not an atomic transaction, so each phase is independently
        // idempotent and reaches a durable boundary before the next begins.
        try purgeStaleCloudActivityData(context: context, markers: resetMarkers)
        let prefs = try reconcilePreferences(
            context: context,
            markers: resetMarkers
        )
        try reconcileSessions(context: context, markers: resetMarkers)
        try reconcileAchievementStones(context: context, markers: resetMarkers)
        try reconcileSubjects(
            context: context,
            insertMissingPresets: !prefs.hasCompletedInitialSubjectSeed
        )
        try reconnectSessionSubjects(context: context, markers: resetMarkers)
        prefs.hasCompletedInitialSubjectSeed = true
        if context.hasChanges { try context.save() }

        try purgeStaleLocalProjection(context: context, markers: resetMarkers)
        try reconcileStrata(context: context, markers: resetMarkers)
        try reconcileAggregates(context: context, markers: resetMarkers)
        try reconcileGacha(context: context, markers: resetMarkers)
        let hasImportedBedrock = try reconcileBedrock(
            context: context,
            markers: resetMarkers
        )
        if context.hasChanges { try context.save() }

        // This synchronized preference is only a convenience hint. If its
        // final cloud save fails after local Bedrock repair, the next
        // idempotent bootstrap derives it again without losing either store.
        if hasImportedBedrock, !prefs.hasEverImportedBedrock {
            prefs.hasEverImportedBedrock = true
            try context.save()
        }
    }

    /// Physical deletion is only compaction. The append-only reset marker is
    /// what makes this idempotent when an offline device uploads old rows
    /// again. Unknown epochs are quarantined until their marker arrives.
    @MainActor
    private static func purgeStaleCloudActivityData(
        context: ModelContext,
        markers: [ActivityResetSnapshot]
    ) throws {
        func isStale(_ epochID: UUID?) -> Bool {
            ActivityResetPolicy.state(of: epochID, markers: markers) == .stale
        }

        for value in try context.fetch(FetchDescriptor<StudySession>())
        where isStale(value.dataEpochID) {
            context.delete(value)
        }
        for value in try context.fetch(FetchDescriptor<AchievementStone>())
        where isStale(value.dataEpochID) {
            context.delete(value)
        }
        for value in try context.fetch(FetchDescriptor<SyncedFocusTimer>())
        where isStale(value.dataEpochID) {
            context.delete(value)
        }
        for value in try context.fetch(FetchDescriptor<FocusTimerDeviceClaim>())
        where isStale(value.dataEpochID) {
            context.delete(value)
        }
        if RareRewardReleasePolicy.isEnabled {
            for value in try context.fetch(FetchDescriptor<RareRewardPendingCommit>())
            where isStale(value.dataEpochID) {
                context.delete(value)
            }
            for value in try context.fetch(FetchDescriptor<RareRewardLedgerCursor>())
            where isStale(value.dataEpochID) {
                context.delete(value)
            }
        }
    }

    @MainActor
    private static func purgeStaleLocalProjection(
        context: ModelContext,
        markers: [ActivityResetSnapshot]
    ) throws {
        func isStale(_ epochID: UUID?) -> Bool {
            ActivityResetPolicy.state(of: epochID, markers: markers) == .stale
        }

        for value in try context.fetch(FetchDescriptor<AggregatePebble>())
        where isStale(value.dataEpochID) {
            context.delete(value)
        }
        for value in try context.fetch(FetchDescriptor<Stratum>())
        where isStale(value.dataEpochID) {
            context.delete(value)
        }
        for value in try context.fetch(FetchDescriptor<Bedrock>())
        where isStale(value.dataEpochID) {
            context.delete(value)
        }
        for value in try context.fetch(FetchDescriptor<GachaState>())
        where isStale(value.dataEpochID) {
            context.delete(value)
        }
    }

    @MainActor
    private static func reconcilePreferences(
        context: ModelContext,
        markers: [ActivityResetSnapshot]
    ) throws -> Prefs {
        let currentEpochID = ActivityResetPolicy.currentEpochID(from: markers)
        let values = try PrefsSyncPolicy.fetchBounded(from: context)
        let resolved = try PrefsSyncPolicy.resolvedState(
            in: values,
            currentEpochID: currentEpochID
        )
        let writer = try PrefsSyncPolicy.ensureWriterRow(
            context: context,
            currentEpochID: currentEpochID,
            canonicalID: prefsID
        )
        // Only monotone lifecycle facts are mirrored during bootstrap. All
        // reversible fields remain read-only until an explicit user mutation.
        writer.hasCompletedOnboarding = resolved.hasCompletedOnboarding
        writer.hasEverImportedBedrock = resolved.hasEverImportedBedrock
        writer.hasCompletedInitialSubjectSeed = resolved.hasCompletedInitialSubjectSeed
        writer.isPro = false
        return writer
    }

    @MainActor
    private static func reconcileGacha(
        context: ModelContext,
        markers: [ActivityResetSnapshot]
    ) throws {
        let currentEpochID = ActivityResetPolicy.currentEpochID(from: markers)
        let values = try context.fetch(FetchDescriptor<GachaState>()).filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: markers)
        }
        guard let canonical = values.first(where: { $0.id == gachaID }) ?? values.first else {
            context.insert(GachaState(id: gachaID, dataEpochID: currentEpochID))
            return
        }
        canonical.id = gachaID
        canonical.dataEpochID = currentEpochID

        let ledgerCursors: [RareRewardLedgerCursor]
        if RareRewardReleasePolicy.isEnabled {
            ledgerCursors = try context.fetch(
                FetchDescriptor<RareRewardLedgerCursor>(sortBy: [
                    SortDescriptor(\RareRewardLedgerCursor.revision, order: .reverse),
                    SortDescriptor(\RareRewardLedgerCursor.updatedAt, order: .reverse),
                    SortDescriptor(\RareRewardLedgerCursor.id)
                ])
            ).filter {
                ActivityResetPolicy.isCurrent($0.dataEpochID, markers: markers)
            }
        } else {
            ledgerCursors = []
        }
        let validLedgerCursors = ledgerCursors.compactMap { cursor -> (
            cursor: RareRewardLedgerCursor,
            migration: RareRewardLedgerMigration,
            epoch: RareRewardLedgerEpoch
        )? in
            guard let migration = try? cursor.migration(),
                  let epoch = try? cursor.epochMirror() else { return nil }
            return (cursor, migration, epoch)
        }
        if let ledger = validLedgerCursors.first,
           validLedgerCursors.allSatisfy({ $0.migration == ledger.migration }) {
            // Once V2 exists, only the server-issued revision order knows
            // whether a later credit reset pity. Wall-clock StudySession order
            // must never resurrect an older miss counter.
            canonical.rewardCreditGrams = ledger.epoch.totalCreditedGrams
            canonical.sinceLastGold = ledger.epoch.sinceLastGold
            for value in values where value !== canonical { context.delete(value) }
            return
        }

        let descriptor: FetchDescriptor<StudySession>
        if let currentEpochID {
            descriptor = FetchDescriptor(
                predicate: #Predicate<StudySession> { session in
                    session.dataEpochID == currentEpochID
                },
                sortBy: [
                    SortDescriptor(\StudySession.endAt, order: .reverse),
                    SortDescriptor(\StudySession.id, order: .reverse)
                ]
            )
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate<StudySession> { session in
                    session.dataEpochID == nil
                },
                sortBy: [
                    SortDescriptor(\StudySession.endAt, order: .reverse),
                    SortDescriptor(\StudySession.id, order: .reverse)
                ]
            )
        }
        var boundedDescriptor = descriptor
        boundedDescriptor.fetchLimit = GachaHistoryReconciliationPolicy
            .maximumCandidateRecordCount
        let tail = StudySessionIntegrityPolicy.supported(
            try context.fetch(boundedDescriptor)
        ).map {
            GachaHistorySnapshot(
                id: $0.id,
                endAt: $0.endAt,
                seconds: $0.seconds,
                source: $0.effectiveSource,
                pebbleKind: $0.pebbleKind,
                rareRewardRuleVersion: $0.rareRewardRuleVersion,
                rareRewardParticipated: $0.rareRewardParticipated,
                rareRewardCreditedGrams: $0.rareRewardCreditedGrams,
                rareRewardOutcomes: RareRewardOutcomeCodec.decode(
                    $0.rareRewardOutcomesRawValue
                )
            )
        }
        let storedRewardCreditGrams = values.map(\.rewardCreditGrams).max() ?? 0
        let coherentCreditState = values
            .filter { $0.rewardCreditGrams == storedRewardCreditGrams }
            .max { lhs, rhs in
                let lhsIsCanonical = lhs.id == gachaID
                let rhsIsCanonical = rhs.id == gachaID
                if lhsIsCanonical != rhsIsCanonical {
                    return !lhsIsCanonical && rhsIsCanonical
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        // Pre-migration rows all have a zero mass ledger, so retain the old
        // conservative max. Once mass credits exist, pity and credited mass
        // must come from the same state snapshot; independently maximizing the
        // two could resurrect a stale pre-gold miss counter.
        let knownProgress = storedRewardCreditGrams == 0
            ? values.map(\.sinceLastGold).max() ?? 0
            : coherentCreditState?.sinceLastGold ?? 0
        canonical.sinceLastGold = GachaHistoryReconciliationPolicy.reconciledProgress(
            knownProgress: knownProgress,
            sessions: tail
        )
        // New reward-credit mass is monotonic, so a larger synced value is
        // always at least as complete as a smaller duplicate. Legacy rows read
        // as zero and therefore preserve their existing pity counter without
        // inventing a pre-migration remainder.
        canonical.rewardCreditGrams = max(
            storedRewardCreditGrams,
            GachaHistoryReconciliationPolicy.observedRewardCreditGrams(
                sessions: tail
            )
        )
        for value in values where value !== canonical { context.delete(value) }
    }

    @MainActor
    private static func reconcileBedrock(
        context: ModelContext,
        markers: [ActivityResetSnapshot]
    ) throws -> Bool {
        let values = try context.fetch(FetchDescriptor<Bedrock>(
            sortBy: [SortDescriptor(\Bedrock.importedAt)]
        )).filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: markers)
        }
        guard let canonical = values.first else { return false }
        canonical.hours = values.map(\.hours).max() ?? canonical.hours
        canonical.importedAt = values.map(\.importedAt).min() ?? canonical.importedAt
        for value in values.dropFirst() { context.delete(value) }
        return true
    }

    @MainActor
    private static func reconcileSessions(
        context: ModelContext,
        markers: [ActivityResetSnapshot]
    ) throws {
        let values = try context.fetch(FetchDescriptor<StudySession>(
            sortBy: [SortDescriptor(\StudySession.endAt)]
        )).filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: markers)
                && StudySessionIntegrityPolicy.isSupported($0)
        }
        _ = StudySessionSyncPolicy.canonicalSessions(from: values)
    }

    @MainActor
    private static func reconnectSessionSubjects(
        context: ModelContext,
        markers: [ActivityResetSnapshot]
    ) throws {
        let subjects = try context.fetch(FetchDescriptor<Subject>())
        let subjectsByID = Dictionary(grouping: subjects, by: \.id).compactMapValues {
            SubjectSyncPolicy.canonical(from: $0)
        }
        let sessions = try context.fetch(FetchDescriptor<StudySession>()).filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: markers)
                && StudySessionIntegrityPolicy.isSupported($0)
        }
        for session in sessions {
            _ = session.subjectIDSnapshot.flatMap { subjectsByID[$0] }
        }
    }

    @MainActor
    private static func reconcileAchievementStones(
        context: ModelContext,
        markers: [ActivityResetSnapshot]
    ) throws {
        let values = try context.fetch(FetchDescriptor<AchievementStone>(
            sortBy: [SortDescriptor(\AchievementStone.createdAt)]
        )).filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: markers)
        }
        _ = AchievementStonePolicy.canonicalStones(from: values)
    }

    @MainActor
    private static func reconcileStrata(
        context: ModelContext,
        markers: [ActivityResetSnapshot]
    ) throws {
        let values = try context.fetch(FetchDescriptor<Stratum>(
            sortBy: [SortDescriptor(\Stratum.bakedAt)]
        )).filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: markers)
        }
        var survivors: [Stratum] = []
        for group in Dictionary(grouping: values, by: \.id).values where group.count > 1 {
            guard let canonical = group.first else { continue }
            canonical.grams = group.map(\.grams).max() ?? canonical.grams
            canonical.pebbleCount = group.map(\.pebbleCount).max() ?? canonical.pebbleCount
            canonical.heightPt = group.map(\.heightPt).max() ?? canonical.heightPt
            if canonical.colorMixJSON == "[]" {
                canonical.colorMixJSON = group.first { $0.colorMixJSON != "[]" }?.colorMixJSON ?? "[]"
            }
            if canonical.monthLabel.isEmpty {
                canonical.monthLabel = group.first { !$0.monthLabel.isEmpty }?.monthLabel ?? ""
            }
            canonical.replaceSessionIDs(group.flatMap(\.sessionIDs))
            for value in group.dropFirst() { context.delete(value) }
        }

        var seenStratumIDs = Set<UUID>()
        for value in values where seenStratumIDs.insert(value.id).inserted {
            survivors.append(value)
        }

        let sessions = try context.fetch(FetchDescriptor<StudySession>()).filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: markers)
                && StudySessionIntegrityPolicy.isSupported($0)
        }
        let sessionsByID = Dictionary(
            uniqueKeysWithValues: StudySessionSyncPolicy
                .canonicalSessions(from: sessions)
                .map { ($0.id, $0) }
        )

        var claimedSessionIDs = Set<UUID>()
        for stratum in survivors.sorted(by: {
            if $0.bakedAt == $1.bakedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.bakedAt < $1.bakedAt
        }) {
            let membership = Set(stratum.sessionIDs)
            guard !membership.isEmpty else { continue }
            let uniqueMembership = membership.subtracting(claimedSessionIDs)
            guard !uniqueMembership.isEmpty else {
                context.delete(stratum)
                continue
            }
            claimedSessionIDs.formUnion(uniqueMembership)

            guard uniqueMembership != membership else { continue }
            let originalCount = max(membership.count, 1)
            stratum.replaceSessionIDs(Array(uniqueMembership))
            stratum.pebbleCount = uniqueMembership.count
            stratum.heightPt *= Double(uniqueMembership.count) / Double(originalCount)

            let members = uniqueMembership.compactMap { sessionsByID[$0] }
            if members.count == uniqueMembership.count {
                stratum.grams = NonnegativeIntPolicy.sum(members.map(\.grams))
                stratum.colorMixJSON = StrataMath.encodeColorMix(
                    StrataMath.colorMix(hexColors: members.map(\.displaySubjectColorHex))
                )
            } else {
                stratum.grams = NonnegativeIntPolicy.clamped(
                    (Double(stratum.grams) * Double(uniqueMembership.count) / Double(originalCount))
                        .rounded()
                )
            }
        }

        // `StudySession.isBaked` is a legacy synchronized field. Local Stratum
        // membership is the only grouping authority, so reconciliation never
        // republishes a device-specific projection bit through CloudKit.
    }

    /// Migrates fixed strata into movable aggregates without deleting the
    /// legacy rows, then performs deterministic decimal carry (ten roots of one
    /// level become one root of the next level). Child records remain stored so
    /// history can be inspected and CloudKit merges stay reversible.
    @MainActor
    private static func reconcileAggregates(
        context: ModelContext,
        markers: [ActivityResetSnapshot]
    ) throws {
        let currentEpochID = ActivityResetPolicy.currentEpochID(from: markers)
        var values = try context.fetch(FetchDescriptor<AggregatePebble>(
            sortBy: [SortDescriptor(\AggregatePebble.createdAt)]
        )).filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: markers)
        }
        var canonicalValues: [AggregatePebble] = []

        for group in Dictionary(grouping: values, by: \.id).values {
            guard let canonical = group.max(by: { lhs, rhs in
                if lhs.level == rhs.level { return lhs.createdAt < rhs.createdAt }
                return lhs.level < rhs.level
            }) else { continue }
            canonical.level = max(1, group.map(\.level).max() ?? canonical.level)
            canonical.pebbleCount = max(0, group.map(\.pebbleCount).max() ?? 0)
            canonical.childAggregateCount = max(
                group.flatMap(\.childAggregateIDs).count,
                group.map(\.childAggregateCount).max() ?? 0
            )
            canonical.grams = max(0, group.map(\.grams).max() ?? 0)
            canonical.measuredPebbleCount = max(
                0,
                group.map(\.measuredPebbleCount).max() ?? 0
            )
            canonical.manualPebbleCount = max(0, group.map(\.manualPebbleCount).max() ?? 0)
            canonical.goldPebbleCount = max(0, group.map(\.goldPebbleCount).max() ?? 0)
            canonical.prismPebbleCount = max(0, group.map(\.prismPebbleCount).max() ?? 0)
            canonical.periodStart = group.map(\.periodStart).min() ?? canonical.periodStart
            canonical.periodEnd = group.map(\.periodEnd).max() ?? canonical.periodEnd
            canonical.replaceSessionIDs(group.flatMap(\.sessionIDs))
            canonical.replaceChildAggregateIDs(group.flatMap(\.childAggregateIDs))
            if canonical.colorMixJSON == "[]" {
                canonical.colorMixJSON = group.first { $0.colorMixJSON != "[]" }?.colorMixJSON
                    ?? "[]"
            }
            if canonical.subjectMixJSON == "[]" {
                canonical.subjectMixJSON = group.first { $0.subjectMixJSON != "[]" }?.subjectMixJSON
                    ?? "[]"
            }
            canonical.parentAggregateID = group
                .compactMap(\.parentAggregateID)
                .sorted { $0.uuidString < $1.uuidString }
                .first
            for duplicate in group where duplicate !== canonical { context.delete(duplicate) }
            canonicalValues.append(canonical)
        }

        values = canonicalValues.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.createdAt < rhs.createdAt
        }
        var seenIDs = Set(values.map(\.id))
        let sessions = try context.fetch(FetchDescriptor<StudySession>()).filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: markers)
                && StudySessionIntegrityPolicy.isSupported($0)
        }
        let sessionsByID = Dictionary(
            uniqueKeysWithValues: StudySessionSyncPolicy
                .canonicalSessions(from: sessions)
                .map { ($0.id, $0) }
        )
        let strata = try context.fetch(FetchDescriptor<Stratum>(
            sortBy: [SortDescriptor(\Stratum.bakedAt)]
        )).filter {
            ActivityResetPolicy.isCurrent($0.dataEpochID, markers: markers)
        }

        for stratum in strata where !seenIDs.contains(stratum.id) {
            let uniqueLegacyMembership = Set(stratum.sessionIDs)
            // Never duplicate an oversized legacy UUID payload into a new
            // CloudKit record. The read-only Stratum keeps its exact historic
            // membership; its bounded compatibility aggregate carries the
            // immutable mass/composition summary until a proven child graph
            // exists.
            let compactDirectMembership = uniqueLegacyMembership.count
                <= Constants.Jar.aggregateFanIn
                ? stratum.sessionIDs
                : []
            let members = stratum.sessionIDs.compactMap { sessionsByID[$0] }
            let colorMix = StrataMath.decodeColorMix(stratum.colorMixJSON)
            let subjectMix: [AggregateSubjectFraction]
            if members.isEmpty {
                subjectMix = colorMix.enumerated().map { index, item in
                    AggregateSubjectFraction(
                        name: index == 0 ? "過去の集中" : "過去の集中 \(index + 1)",
                        colorHex: item.hex,
                        pebbleCount: NonnegativeIntPolicy.clamped(
                            (item.fraction * Double(max(stratum.pebbleCount, 1))).rounded()
                        )
                    )
                }
            } else {
                subjectMix = subjectMixFromSessions(members)
            }
            let rareRewards = RareRewardCounts.total(members.map(\.rareRewardCounts))
            let aggregate = AggregatePebble(
                id: stratum.id,
                createdAt: stratum.bakedAt,
                level: compactDirectMembership.count == stratum.pebbleCount
                    && !compactDirectMembership.isEmpty
                    ? 1
                    : StrataMath.decimalAggregateLevel(forPebbleCount: stratum.pebbleCount),
                pebbleCount: stratum.pebbleCount,
                grams: stratum.grams,
                measuredPebbleCount: members.filter { $0.effectiveSource.isMeasured }.count,
                manualPebbleCount: members.filter { !$0.effectiveSource.isMeasured }.count,
                goldPebbleCount: rareRewards.goldCount,
                prismPebbleCount: rareRewards.prismCount,
                colorMixJSON: stratum.colorMixJSON,
                subjectMixJSON: StrataMath.encodeSubjectMix(subjectMix),
                periodStart: members.map(\.startAt).min() ?? stratum.bakedAt,
                periodEnd: members.map(\.endAt).max() ?? stratum.bakedAt,
                sessionIDs: compactDirectMembership,
                dataEpochID: currentEpochID
            )
            context.insert(aggregate)
            values.append(aggregate)
            seenIDs.insert(aggregate.id)
        }

        compactFlattenedAggregateLineage(values)
        let aggregatesByID = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })

        for aggregate in values {
            aggregate.level = max(1, aggregate.level)
            aggregate.pebbleCount = max(0, aggregate.pebbleCount)
            aggregate.grams = max(0, aggregate.grams)
            let periodStart = min(aggregate.periodStart, aggregate.periodEnd)
            let periodEnd = max(aggregate.periodStart, aggregate.periodEnd)
            aggregate.periodStart = periodStart
            aggregate.periodEnd = periodEnd
            aggregate.replaceSessionIDs(aggregate.sessionIDs)
            aggregate.replaceChildAggregateIDs(aggregate.childAggregateIDs)
            let members = aggregate.sessionIDs.compactMap { sessionsByID[$0] }
            let children = aggregate.childAggregateIDs.compactMap { aggregatesByID[$0] }
            let memberRareRewards = RareRewardCounts.total(
                members.map(\.rareRewardCounts)
            )
            let hasCompleteChildren = !aggregate.childAggregateIDs.isEmpty
                && children.count == Set(aggregate.childAggregateIDs).count
            let knownComposition = NonnegativeIntPolicy.adding(
                aggregate.measuredPebbleCount,
                aggregate.manualPebbleCount
            )
            if knownComposition < aggregate.pebbleCount {
                if members.count == aggregate.sessionIDs.count, !members.isEmpty {
                    aggregate.measuredPebbleCount = members.filter { $0.effectiveSource.isMeasured }.count
                    aggregate.manualPebbleCount = members.filter { !$0.effectiveSource.isMeasured }.count
                } else if hasCompleteChildren {
                    aggregate.measuredPebbleCount = NonnegativeIntPolicy.sum(
                        children.map(\.measuredPebbleCount)
                    )
                    aggregate.manualPebbleCount = NonnegativeIntPolicy.sum(
                        children.map(\.manualPebbleCount)
                    )
                } else {
                    aggregate.measuredPebbleCount = NonnegativeIntPolicy.adding(
                        aggregate.measuredPebbleCount,
                        aggregate.pebbleCount - knownComposition
                    )
                }
            }
            if members.count == aggregate.sessionIDs.count, !members.isEmpty {
                aggregate.goldPebbleCount = memberRareRewards.goldCount
                aggregate.prismPebbleCount = memberRareRewards.prismCount
            } else if hasCompleteChildren {
                aggregate.goldPebbleCount = RareRewardCounts.saturatedSum(
                    children.map(\.goldPebbleCount)
                )
                aggregate.prismPebbleCount = RareRewardCounts.saturatedSum(
                    children.map(\.prismPebbleCount)
                )
            }
            if aggregate.colorMix.isEmpty {
                if !members.isEmpty {
                    aggregate.colorMixJSON = StrataMath.encodeColorMix(
                        StrataMath.colorMix(hexColors: members.map(\.displaySubjectColorHex))
                    )
                } else if hasCompleteChildren {
                    aggregate.colorMixJSON = StrataMath.encodeColorMix(
                        StrataMath.weightedColorMix(children.map {
                            ($0.colorMix, Double(max($0.pebbleCount, 1)))
                        })
                    )
                }
            }
            if aggregate.subjectMix.isEmpty {
                if !members.isEmpty {
                    aggregate.subjectMixJSON = StrataMath.encodeSubjectMix(
                        subjectMixFromSessions(members)
                    )
                } else if hasCompleteChildren {
                    aggregate.subjectMixJSON = StrataMath.encodeSubjectMix(
                        StrataMath.mergedSubjectMix(children.map(\.subjectMix))
                    )
                }
            }
        }

        try rollUpAggregateRoots(
            values: &values,
            context: context,
            dataEpochID: currentEpochID
        )
    }

    /// Clears a legacy flattened membership list only when every referenced
    /// child is present and recursively resolves to exactly the same original
    /// sessions. Missing children, cycles, overlaps, and partial membership all
    /// preserve the old payload rather than risking irreversible history loss.
    @MainActor
    private static func compactFlattenedAggregateLineage(
        _ values: [AggregatePebble]
    ) {
        let byID = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })

        func resolvedSessions(
            for aggregateID: UUID,
            visiting: Set<UUID>
        ) -> Set<UUID>? {
            guard !visiting.contains(aggregateID), let aggregate = byID[aggregateID] else {
                return nil
            }
            let direct = Set(aggregate.sessionIDs)
            if !direct.isEmpty { return direct }
            let childIDs = Set(aggregate.childAggregateIDs)
            guard (1...Constants.Jar.aggregateFanIn).contains(childIDs.count) else {
                return nil
            }
            var nextVisiting = visiting
            nextVisiting.insert(aggregateID)
            var resolved = Set<UUID>()
            for childID in childIDs {
                guard let childSessions = resolvedSessions(
                    for: childID,
                    visiting: nextVisiting
                ), resolved.isDisjoint(with: childSessions) else {
                    return nil
                }
                resolved.formUnion(childSessions)
            }
            return resolved
        }

        for aggregate in values.sorted(by: { $0.level < $1.level })
        where aggregate.level > 1 && !aggregate.sessionIDs.isEmpty {
            let childIDs = Set(aggregate.childAggregateIDs)
            guard (1...Constants.Jar.aggregateFanIn).contains(childIDs.count),
                  childIDs.allSatisfy({ childID in
                      guard let child = byID[childID] else { return false }
                      return child.level == aggregate.level - 1
                  }) else { continue }

            var resolved = Set<UUID>()
            var isComplete = true
            for childID in childIDs {
                guard let childSessions = resolvedSessions(for: childID, visiting: []),
                      resolved.isDisjoint(with: childSessions) else {
                    isComplete = false
                    break
                }
                resolved.formUnion(childSessions)
            }
            let flattened = Set(aggregate.sessionIDs)
            guard isComplete,
                  resolved == flattened,
                  resolved.count == aggregate.pebbleCount else { continue }
            aggregate.replaceSessionIDs([])
            aggregate.replaceChildAggregateIDs(Array(childIDs))
        }
    }

    @MainActor
    private static func rollUpAggregateRoots(
        values: inout [AggregatePebble],
        context: ModelContext,
        dataEpochID: UUID?
    ) throws {
        while true {
            let roots = AggregatePebblePolicy.activeRoots(from: values)
            let groups = Dictionary(grouping: roots, by: \.level)
            guard let level = groups.keys.sorted().first(where: {
                (groups[$0]?.count ?? 0) >= Constants.Jar.aggregateFanIn
            }), let candidates = groups[level] else { return }

            let selected = Array(candidates.prefix(Constants.Jar.aggregateFanIn))
            let sources = selected.map { aggregate in
                AggregateSource(
                    id: aggregate.id,
                    level: aggregate.level,
                    pebbleCount: aggregate.pebbleCount,
                    childAggregateCount: aggregate.childAggregateCount,
                    grams: aggregate.grams,
                    radius: StrataMath.aggregateRadius(level: aggregate.level),
                    colorMix: aggregate.colorMix,
                    subjectMix: aggregate.subjectMix,
                    periodStart: aggregate.periodStart,
                    periodEnd: aggregate.periodEnd,
                    sessionIDs: aggregate.sessionIDs,
                    measuredPebbleCount: aggregate.measuredPebbleCount,
                    manualPebbleCount: aggregate.manualPebbleCount,
                    goldPebbleCount: aggregate.goldPebbleCount,
                    prismPebbleCount: aggregate.prismPebbleCount
                )
            }
            guard let calculation = StrataMath.aggregate(sources: sources) else { return }
            let parentID = JarAggregateRequest.deterministicID(
                sourceIDs: selected.map(\.id),
                outputLevel: calculation.level
            )
            let parent: AggregatePebble
            if let existing = values.first(where: { $0.id == parentID }) {
                parent = existing
                parent.level = calculation.level
                parent.pebbleCount = calculation.pebbleCount
                parent.grams = calculation.grams
                parent.measuredPebbleCount = calculation.measuredPebbleCount
                parent.manualPebbleCount = calculation.manualPebbleCount
                parent.goldPebbleCount = calculation.goldPebbleCount
                parent.prismPebbleCount = calculation.prismPebbleCount
                parent.colorMixJSON = StrataMath.encodeColorMix(calculation.colorMix)
                parent.subjectMixJSON = StrataMath.encodeSubjectMix(calculation.subjectMix)
                parent.periodStart = calculation.periodStart
                parent.periodEnd = calculation.periodEnd
                parent.replaceSessionIDs(calculation.sessionIDs)
                parent.replaceChildAggregateIDs(calculation.childAggregateIDs)
            } else {
                parent = AggregatePebble(
                    id: parentID,
                    createdAt: selected.map(\.createdAt).max() ?? .now,
                    level: calculation.level,
                    pebbleCount: calculation.pebbleCount,
                    childAggregateCount: calculation.childAggregateCount,
                    grams: calculation.grams,
                    measuredPebbleCount: calculation.measuredPebbleCount,
                    manualPebbleCount: calculation.manualPebbleCount,
                    goldPebbleCount: calculation.goldPebbleCount,
                    prismPebbleCount: calculation.prismPebbleCount,
                    colorMixJSON: StrataMath.encodeColorMix(calculation.colorMix),
                    subjectMixJSON: StrataMath.encodeSubjectMix(calculation.subjectMix),
                    periodStart: calculation.periodStart,
                    periodEnd: calculation.periodEnd,
                    sessionIDs: calculation.sessionIDs,
                    childAggregateIDs: calculation.childAggregateIDs,
                    dataEpochID: dataEpochID
                )
                context.insert(parent)
                values.append(parent)
            }
            selected.forEach { $0.parentAggregateID = parent.id }
        }
    }

    private static func subjectMixFromSessions(
        _ sessions: [StudySession]
    ) -> [AggregateSubjectFraction] {
        let values = StudySessionSyncPolicy.canonicalSessions(from: sessions).map {
            [AggregateSubjectFraction(
                name: $0.displaySubjectName,
                colorHex: $0.displaySubjectColorHex,
                pebbleCount: 1
            )]
        }
        return StrataMath.mergedSubjectMix(values)
    }

    @MainActor
    private static func reconcileSubjects(
        context: ModelContext,
        insertMissingPresets: Bool
    ) throws {
        var existing = try context.fetch(FetchDescriptor<Subject>(
            sortBy: [SortDescriptor(\Subject.createdAt)]
        ))
        for (index, preset) in subjects.enumerated() {
            let matches = existing.filter {
                $0.id == preset.id
                    || ($0.name == preset.name
                        && $0.colorHex.caseInsensitiveCompare(preset.colorHex) == .orderedSame)
            }
            guard !matches.isEmpty else {
                if insertMissingPresets {
                    let value = Subject(
                        id: preset.id,
                        name: preset.name,
                        colorHex: preset.colorHex,
                        sortOrder: index
                    )
                    context.insert(value)
                    existing.append(value)
                }
                continue
            }
            // A matching source row is sufficient. Same-ID duplicates are
            // retained and resolved at presentation boundaries; rewriting
            // relationships or deleting rows here can race an offline edit.
            _ = SubjectSyncPolicy.canonical(from: matches)
        }
    }
}
