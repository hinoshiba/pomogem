import Foundation
import SwiftData

enum SessionSource: String, Codable, CaseIterable, Sendable {
    case timer
    case manual
    case timerDemoted

    var isMeasured: Bool { self == .timer }
    var isSelfReported: Bool { !isMeasured }
}

enum PebbleKind: String, Codable, CaseIterable, Sendable {
    case normal
    case gold
    case prism
}

enum AchievementKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case perfectScore
    case examPass
    case workMilestone

    var id: Self { self }

    var title: String {
        switch self {
        case .perfectScore: "100点"
        case .examPass: "試験合格"
        case .workMilestone: "仕事の節目"
        }
    }

    var shortMark: String {
        switch self {
        case .perfectScore: "100"
        case .examPass: "✓"
        case .workMilestone: "W"
        }
    }

    var systemImage: String {
        switch self {
        case .perfectScore: "star.circle.fill"
        case .examPass: "checkmark.seal.fill"
        case .workMilestone: "flag.checkered"
        }
    }

    /// A distinct jewel material keeps milestones readable even when their
    /// subject colors are similar. These tokens are shared by the live jar,
    /// history, and exported share card.
    var gemBaseHex: String {
        switch self {
        case .perfectScore: "D93D68"
        case .examPass: "008E76"
        case .workMilestone: "6D50EA"
        }
    }

    var gemEdgeHex: String {
        switch self {
        case .perfectScore: "FF9CB5"
        case .examPass: "70FFD8"
        case .workMilestone: "BDAEFF"
        }
    }

    var gemGlowHex: String {
        switch self {
        case .perfectScore: "FF5E91"
        case .examPass: "27E6BD"
        case .workMilestone: "8F70FF"
        }
    }

    var detail: String {
        switch self {
        case .perfectScore: "満点だったテスト"
        case .examPass: "試験・検定・資格の合格"
        case .workMilestone: "納品・公開・案件完了など、自分で決めた節目"
        }
    }

    var notePlaceholder: String {
        switch self {
        case .perfectScore: "例：2学期 期末テスト"
        case .examPass: "例：簿記2級"
        case .workMilestone: "例：初回リリース"
        }
    }
}

enum ManualDuration: String, Codable, CaseIterable, Sendable {
    case thirtyMinutes
    case sixtyMinutes
    case oneHundredTwentyMinutes

    var minutes: Int {
        switch self {
        case .thirtyMinutes:
            Constants.Mass.manualThirtyMinutes
        case .sixtyMinutes:
            Constants.Mass.manualSixtyMinutes
        case .oneHundredTwentyMinutes:
            Constants.Mass.manualOneTwentyMinutes
        }
    }

    var seconds: Int { minutes * Constants.Timer.secondsPerMinute }
    var grams: Int { minutes * Constants.Mass.gramsPerMinute }
    var radius: CGFloat {
        switch self {
        case .thirtyMinutes:
            Constants.Jar.manualThirtyRadius
        case .sixtyMinutes:
            Constants.Jar.manualSixtyRadius
        case .oneHundredTwentyMinutes:
            Constants.Jar.manualOneTwentyRadius
        }
    }
}

@Model
final class Subject {
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String = Constants.Color.english
    var sortOrder: Int = 0
    var isArchived: Bool = false
    var createdAt: Date = Date()

    /// Explicit optional inverses are required by CloudKit. Nullifying keeps
    /// historical rows and their snapshots intact when a subject is deleted.
    @Relationship(deleteRule: .nullify, inverse: \StudySession.subject)
    var studySessions: [StudySession]?

    @Relationship(deleteRule: .nullify, inverse: \AchievementStone.subject)
    var achievementStones: [AchievementStone]?

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String,
        sortOrder: Int,
        isArchived: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = SubjectNamePolicy.sanitized(name)
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.isArchived = isArchived
        self.createdAt = createdAt
    }
}

@Model
final class StudySession {
    var id: UUID = UUID()
    /// nil is the pre-reset generation. Once a reset marker exists, only rows
    /// carrying that marker's epoch are eligible for display or aggregation.
    var dataEpochID: UUID?
    var subject: Subject?
    /// Stable relationship fallback used when CloudKit delivers a completed
    /// timer before it delivers the referenced Subject row.
    var subjectIDSnapshot: UUID?
    /// Immutable fallbacks keep history understandable after a subject is
    /// deleted while the optional SwiftData relationship is nullified.
    var subjectNameSnapshot: String = ""
    var subjectColorHexSnapshot: String = Constants.Color.textMute
    var startAt: Date = Date()
    var endAt: Date = Date()
    var seconds: Int = 0
    var source: SessionSource = SessionSource.timer
    var pebbleKind: PebbleKind = PebbleKind.normal
    var grams: Int = 0
    var deviceDayKey: String = ""
    /// Nil identifies a completion written before mass-based reward credits.
    /// Versioned rows explicitly record opt-out/non-participation so launch
    /// repair never mistakes a normal OFF-mode pebble for a missed gold draw.
    var rareRewardRuleVersion: Int?
    var rareRewardParticipated: Bool?
    /// Mass accepted into the reward-credit ledger for this completion. This
    /// includes a sub-250g contribution even when no draw occurred yet.
    var rareRewardCreditedGrams: Int?
    /// Comma-separated raw PebbleKind values, one per consumed credit. An empty
    /// string is a versioned completion with no draw; nil is a legacy row.
    var rareRewardOutcomesRawValue: String?

    /// Grouped sessions remain available for the log while their visible pebble
    /// becomes part of an AggregatePebble. The flag is retained for backwards
    /// compatibility with the former Stratum representation.
    var isBaked: Bool = false

    init(
        id: UUID = UUID(),
        subject: Subject? = nil,
        startAt: Date,
        endAt: Date,
        seconds: Int,
        source: SessionSource,
        pebbleKind: PebbleKind = .normal,
        grams: Int? = nil,
        deviceDayKey: String,
        isBaked: Bool = false,
        subjectNameSnapshot: String? = nil,
        subjectColorHexSnapshot: String? = nil,
        subjectIDSnapshot: UUID? = nil,
        rareRewardRuleVersion: Int? = nil,
        rareRewardParticipated: Bool? = nil,
        rareRewardCreditedGrams: Int? = nil,
        rareRewardOutcomesRawValue: String? = nil,
        dataEpochID: UUID? = nil
    ) {
        self.id = id
        self.dataEpochID = dataEpochID
        self.subject = subject
        self.subjectIDSnapshot = subjectIDSnapshot ?? subject?.id
        self.subjectNameSnapshot = SubjectNamePolicy.sanitized(
            subjectNameSnapshot ?? subject?.name ?? ""
        )
        self.subjectColorHexSnapshot = subjectColorHexSnapshot ?? subject?.colorHex ?? Constants.Color.textMute
        self.startAt = startAt
        self.endAt = endAt
        self.seconds = max(0, seconds)
        self.source = source
        self.pebbleKind = pebbleKind
        self.grams = max(0, grams ?? Self.grams(for: seconds))
        self.deviceDayKey = deviceDayKey
        self.isBaked = isBaked
        self.rareRewardRuleVersion = rareRewardRuleVersion.map { max(1, $0) }
        self.rareRewardParticipated = rareRewardParticipated
        self.rareRewardCreditedGrams = rareRewardCreditedGrams.map {
            min(max(0, $0), Constants.Gacha.maximumCreditableGramsPerCompletion)
        }
        self.rareRewardOutcomesRawValue = rareRewardOutcomesRawValue
    }

    var displaySubjectName: String {
        SubjectNamePolicy.displayName(
            subject?.name ?? subjectNameSnapshot,
            fallback: "アーカイブ済みのテーマ"
        )
    }

    var displaySubjectColorHex: String {
        subject?.colorHex ?? subjectColorHexSnapshot
    }

    static func grams(for seconds: Int) -> Int {
        max(0, seconds) / Constants.Timer.secondsPerMinute * Constants.Mass.gramsPerMinute
    }

    /// Every 250g credit has its own persisted outcome. `pebbleKind` remains
    /// the representative material for the one physical body, while these
    /// helpers keep secondary outcomes visible in totals and accessibility.
    /// A legacy row has no batch payload, so its representative rare material
    /// is the only outcome that can be recovered without inventing history.
    var effectiveRareRewardOutcomes: [PebbleKind] {
        if let decoded = RareRewardOutcomeCodec.decode(rareRewardOutcomesRawValue) {
            return decoded
        }
        return pebbleKind == .normal ? [] : [pebbleKind]
    }

    var rareRewardCounts: RareRewardCounts {
        RareRewardCounts(outcomes: effectiveRareRewardOutcomes)
    }
}

/// Count projection shared by Home, Log, Share, widgets, and aggregation.
/// Sums saturate so a malformed synced row cannot turn presentation into an
/// integer-overflow crash.
struct RareRewardCounts: Equatable, Sendable {
    let drawCount: Int
    let goldCount: Int
    let prismCount: Int

    init(drawCount: Int, goldCount: Int, prismCount: Int) {
        self.drawCount = max(0, drawCount)
        self.goldCount = max(0, goldCount)
        self.prismCount = max(0, prismCount)
    }

    init(outcomes: [PebbleKind]) {
        self.init(
            drawCount: outcomes.count,
            goldCount: outcomes.filter { $0 == .gold }.count,
            prismCount: outcomes.filter { $0 == .prism }.count
        )
    }

    var normalCount: Int {
        max(0, drawCount - Self.saturatedSum([goldCount, prismCount]))
    }

    var rareCount: Int {
        Self.saturatedSum([goldCount, prismCount])
    }

    /// Human-readable disclosure for the otherwise hidden secondary outcomes
    /// of a multi-credit completion.
    var multiDrawSummary: String? {
        guard drawCount > 1 else { return nil }
        let parts = [
            normalCount > 0 ? "通常\(normalCount)" : nil,
            goldCount > 0 ? "金\(goldCount)" : nil,
            prismCount > 0 ? "虹\(prismCount)" : nil
        ].compactMap { $0 }
        guard !parts.isEmpty else { return "250gごとの抽選\(drawCount)回" }
        return "250gごとの抽選\(drawCount)回（\(parts.joined(separator: "・"))）"
    }

    static func total<S: Sequence>(_ values: S) -> RareRewardCounts
    where S.Element == RareRewardCounts {
        var drawCount = 0
        var goldCount = 0
        var prismCount = 0
        for value in values {
            drawCount = saturatedSum([drawCount, value.drawCount])
            goldCount = saturatedSum([goldCount, value.goldCount])
            prismCount = saturatedSum([prismCount, value.prismCount])
        }
        return RareRewardCounts(
            drawCount: drawCount,
            goldCount: goldCount,
            prismCount: prismCount
        )
    }

    static func saturatedSum(_ values: [Int]) -> Int {
        values.reduce(0) { partial, rawValue in
            let value = max(0, rawValue)
            guard partial <= Int.max - value else { return Int.max }
            return partial + value
        }
    }

}

enum StudySessionSyncPolicy {
    struct RareRewardMetadata: Equatable {
        let ruleVersion: Int
        let participated: Bool
        let creditedGrams: Int
        let outcomesRawValue: String
    }

    /// Concurrent materialization can transiently create two CloudKit rows
    /// with the same logical session UUID. Choosing the rarer observed result
    /// is deterministic and, unlike array order, converges on every device.
    static func mergedPebbleKind(_ values: [PebbleKind]) -> PebbleKind {
        values.max { syncRank($0) < syncRank($1) } ?? .normal
    }

    /// A versioned record wins over a legacy nil when the same logical session
    /// is temporarily duplicated. Conflicting versioned copies resolve to
    /// explicit non-participation rather than creating extra credits or pity.
    static func mergedRareRewardMetadata(
        _ sessions: [StudySession]
    ) -> RareRewardMetadata? {
        let versioned = sessions.filter { $0.rareRewardRuleVersion != nil }
        guard let newestRule = versioned
            .compactMap(\.rareRewardRuleVersion)
            .max() else { return nil }
        let values = versioned.filter {
            $0.rareRewardRuleVersion == newestRule
        }
        guard newestRule == Constants.Gacha.creditRuleVersion else {
            return RareRewardMetadata(
                ruleVersion: newestRule,
                participated: false,
                creditedGrams: 0,
                outcomesRawValue: ""
            )
        }
        guard values.allSatisfy({ $0.rareRewardParticipated == true }) else {
            return RareRewardMetadata(
                ruleVersion: newestRule,
                participated: false,
                creditedGrams: 0,
                outcomesRawValue: ""
            )
        }
        let grams = values.compactMap(\.rareRewardCreditedGrams)
        let outcomes = values.compactMap(\.rareRewardOutcomesRawValue)
        guard grams.count == values.count,
              Set(grams).count == 1,
              outcomes.count == values.count,
              Set(outcomes).count == 1,
              let creditedGrams = grams.first,
              let outcomesRawValue = outcomes.first,
              (0 ... Constants.Gacha.maximumCreditableGramsPerCompletion)
                .contains(creditedGrams),
              let decodedOutcomes = RareRewardOutcomeCodec.decode(outcomesRawValue),
              RareRewardCreditPolicy.isPossibleOutcomeCount(
                decodedOutcomes.count,
                forContributionGrams: creditedGrams
              ) else {
            return RareRewardMetadata(
                ruleVersion: newestRule,
                participated: false,
                creditedGrams: 0,
                outcomesRawValue: ""
            )
        }
        return RareRewardMetadata(
            ruleVersion: newestRule,
            participated: true,
            creditedGrams: max(0, creditedGrams),
            outcomesRawValue: outcomesRawValue
        )
    }

    private static func syncRank(_ kind: PebbleKind) -> Int {
        switch kind {
        case .normal: 0
        case .gold: 1
        case .prism: 2
        }
    }
}

/// A result worth remembering, kept separate from study time so it can never
/// inflate mass, measured completion counts, or the manual-entry allowance.
@Model
final class AchievementStone {
    var id: UUID = UUID()
    var dataEpochID: UUID?
    var subject: Subject?
    var subjectNameSnapshot: String = ""
    var subjectColorHexSnapshot: String = Constants.Color.textMute
    var kind: AchievementKind = AchievementKind.perfectScore
    var note: String = ""
    var achievedAt: Date = Date()
    var createdAt: Date = Date()
    /// Monotonic application-level revision used to resolve the rare logical
    /// duplicate that can be delivered after two devices write while offline.
    /// Existing stores migrate to revision 1 through the property default.
    var revision: Int = 1
    /// A durable tombstone prevents a stale offline payload from making a
    /// user-deleted milestone visible again. Only the explicit local Undo flow
    /// clears this value; ordinary edits deliberately leave it untouched.
    var deletedAt: Date?
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        subject: Subject? = nil,
        kind: AchievementKind,
        note: String = "",
        achievedAt: Date = .now,
        createdAt: Date = .now,
        subjectNameSnapshot: String? = nil,
        subjectColorHexSnapshot: String? = nil,
        dataEpochID: UUID? = nil,
        revision: Int = 1,
        deletedAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.dataEpochID = dataEpochID
        self.subject = subject
        self.subjectNameSnapshot = SubjectNamePolicy.sanitized(
            subjectNameSnapshot ?? subject?.name ?? ""
        )
        self.subjectColorHexSnapshot = subjectColorHexSnapshot
            ?? subject?.colorHex
            ?? Constants.Color.textMute
        self.kind = kind
        self.note = Self.sanitizedNote(note)
        self.achievedAt = min(achievedAt, .now)
        self.createdAt = createdAt
        self.revision = max(1, revision)
        self.deletedAt = deletedAt
        self.updatedAt = updatedAt ?? createdAt
    }

    var displaySubjectName: String {
        SubjectNamePolicy.displayName(
            subject?.name ?? subjectNameSnapshot,
            fallback: "アーカイブ済みのテーマ"
        )
    }

    var displaySubjectColorHex: String {
        subject?.colorHex ?? subjectColorHexSnapshot
    }

    var displayTitle: String {
        note.isEmpty ? kind.title : note
    }

    static func sanitizedNote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(40))
    }
}

enum AchievementStonePolicy {
    /// Resolves logical duplicates without depending on CloudKit delivery
    /// order. A tombstone wins a same-revision tie so deletion is fail-closed.
    static func canonicalStones(from values: [AchievementStone]) -> [AchievementStone] {
        Dictionary(grouping: values, by: \.id).values.compactMap(canonicalStone)
    }

    static func canonicalStone(from values: [AchievementStone]) -> AchievementStone? {
        values.max { lhs, rhs in
            isOrderedBefore(lhs, rhs)
        }
    }

    /// Resolves one logical milestone at the database boundary. Candidate
    /// pages may intentionally query only active rows so years of tombstones
    /// cannot starve useful content; every candidate ID must pass through this
    /// exact, one-row lookup before it is rendered or shared. Sorting deletion
    /// ahead of update time makes a same-revision tombstone fail closed.
    static func canonicalDescriptor(
        id: UUID,
        dataEpochID: UUID?
    ) -> FetchDescriptor<AchievementStone> {
        let predicate: Predicate<AchievementStone>
        if let dataEpochID {
            predicate = #Predicate {
                $0.id == id && $0.dataEpochID == dataEpochID
            }
        } else {
            predicate = #Predicate {
                $0.id == id && $0.dataEpochID == nil
            }
        }
        var descriptor = FetchDescriptor<AchievementStone>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\AchievementStone.revision, order: .reverse),
                SortDescriptor(\AchievementStone.deletedAt, order: .reverse),
                SortDescriptor(\AchievementStone.updatedAt, order: .reverse),
                SortDescriptor(\AchievementStone.createdAt, order: .reverse),
                SortDescriptor(\AchievementStone.achievedAt, order: .reverse),
                SortDescriptor(\AchievementStone.note, order: .reverse),
                SortDescriptor(\AchievementStone.subjectNameSnapshot, order: .reverse)
            ]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// Re-resolves a hard-bounded candidate page without widening it to the
    /// lifetime ledger. A tombstone can therefore live far outside the page's
    /// date window and still suppress a late, lower-revision active duplicate.
    @MainActor
    static func resolvedVisibleCandidates(
        from candidates: [AchievementStone],
        context: ModelContext
    ) throws -> [AchievementStone] {
        var seen = Set<String>()
        var resolved: [AchievementStone] = []
        resolved.reserveCapacity(candidates.count)
        for candidate in candidates {
            let key = candidate.id.uuidString
                + "|"
                + (candidate.dataEpochID?.uuidString ?? "legacy")
            guard seen.insert(key).inserted else { continue }
            let winner = try context.fetch(canonicalDescriptor(
                id: candidate.id,
                dataEpochID: candidate.dataEpochID
            )).first
            if let winner, winner.deletedAt == nil {
                resolved.append(winner)
            }
        }
        return resolved
    }

    /// CloudKit can briefly surface duplicate rows. Deduplicate first, prefer
    /// the winning revision, omit durable tombstones, then keep the latest
    /// milestones while returning them oldest-first so jar restoration has a
    /// stable stacking order.
    static func visibleStones(from values: [AchievementStone]) -> [AchievementStone] {
        let unique = canonicalStones(from: values).filter { $0.deletedAt == nil }
        let newestFirst = unique.sorted { lhs, rhs in
            if lhs.achievedAt == rhs.achievedAt {
                return lhs.id.uuidString > rhs.id.uuidString
            }
            return lhs.achievedAt > rhs.achievedAt
        }
        return Array(newestFirst.prefix(Constants.Jar.maximumVisibleAchievementStones).reversed())
    }

    private static func isOrderedBefore(
        _ lhs: AchievementStone,
        _ rhs: AchievementStone
    ) -> Bool {
        if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
        if (lhs.deletedAt != nil) != (rhs.deletedAt != nil) {
            return lhs.deletedAt == nil
        }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.achievedAt != rhs.achievedAt { return lhs.achievedAt < rhs.achievedAt }
        return deterministicPayloadKey(lhs) < deterministicPayloadKey(rhs)
    }

    private static func deterministicPayloadKey(_ stone: AchievementStone) -> String {
        [
            stone.kind.rawValue,
            stone.note,
            stone.subject?.id.uuidString ?? "",
            stone.subjectNameSnapshot,
            stone.subjectColorHexSnapshot,
            stone.deletedAt?.timeIntervalSinceReferenceDate.description ?? ""
        ].joined(separator: "|")
    }
}

/// The immutable user-facing fields needed to restore a just-deleted
/// milestone. This snapshot intentionally has no mass/count fields because an
/// achievement is always a 0g annotation beside the study ledger.
struct AchievementStoneRevisionSnapshot: Equatable, Sendable {
    let id: UUID
    let dataEpochID: UUID?
    let subjectID: UUID?
    let subjectNameSnapshot: String
    let subjectColorHexSnapshot: String
    let kind: AchievementKind
    let note: String
    let achievedAt: Date

    init(_ stone: AchievementStone) {
        id = stone.id
        dataEpochID = stone.dataEpochID
        subjectID = stone.subject?.id
        subjectNameSnapshot = stone.subjectNameSnapshot
        subjectColorHexSnapshot = stone.subjectColorHexSnapshot
        kind = stone.kind
        note = stone.note
        achievedAt = stone.achievedAt
    }
}

@MainActor
enum AchievementStoneRevisionPolicy {
    static func edit(
        _ values: [AchievementStone],
        subject: Subject,
        kind: AchievementKind,
        note: String,
        achievedAt: Date,
        now: Date = .now
    ) {
        let durableDeletion = AchievementStonePolicy.canonicalStone(from: values)?.deletedAt
        apply(
            values,
            subject: subject,
            subjectNameSnapshot: subject.safeDisplayName,
            subjectColorHexSnapshot: subject.colorHex,
            kind: kind,
            note: note,
            achievedAt: achievedAt,
            deletedAt: durableDeletion,
            now: now
        )
    }

    static func delete(
        _ values: [AchievementStone],
        now: Date = .now
    ) {
        guard !values.isEmpty else { return }
        let nextRevision = nextRevision(in: values)
        for value in values {
            value.revision = nextRevision
            value.deletedAt = now
            value.updatedAt = now
        }
    }

    static func restore(
        _ values: [AchievementStone],
        snapshot: AchievementStoneRevisionSnapshot,
        subject: Subject?,
        now: Date = .now
    ) {
        apply(
            values,
            subject: subject,
            subjectNameSnapshot: snapshot.subjectNameSnapshot,
            subjectColorHexSnapshot: snapshot.subjectColorHexSnapshot,
            kind: snapshot.kind,
            note: snapshot.note,
            achievedAt: snapshot.achievedAt,
            deletedAt: nil,
            now: now
        )
    }

    private static func apply(
        _ values: [AchievementStone],
        subject: Subject?,
        subjectNameSnapshot: String,
        subjectColorHexSnapshot: String,
        kind: AchievementKind,
        note: String,
        achievedAt: Date,
        deletedAt: Date?,
        now: Date
    ) {
        guard !values.isEmpty else { return }
        let nextRevision = nextRevision(in: values)
        for value in values {
            value.subject = subject
            value.subjectNameSnapshot = SubjectNamePolicy.sanitized(subjectNameSnapshot)
            value.subjectColorHexSnapshot = subjectColorHexSnapshot
            value.kind = kind
            value.note = AchievementStone.sanitizedNote(note)
            value.achievedAt = min(achievedAt, now)
            value.revision = nextRevision
            value.deletedAt = deletedAt
            value.updatedAt = now
        }
    }

    private static func nextRevision(in values: [AchievementStone]) -> Int {
        max(1, (values.map(\.revision).max() ?? 0) + 1)
    }
}

/// One subject contribution inside an aggregate pebble.
///
/// Keeping the snapshot name as well as the colour means VoiceOver and future
/// overview screens remain understandable after a subject is renamed or deleted.
struct AggregateSubjectFraction: Codable, Equatable, Sendable {
    let name: String
    let colorHex: String
    let pebbleCount: Int

    init(name: String, colorHex: String, pebbleCount: Int) {
        self.name = name.isEmpty ? "過去の集中" : name
        self.colorHex = colorHex
        self.pebbleCount = max(0, pebbleCount)
    }
}

/// A movable overview stone made from study pebbles.
///
/// All original StudySession rows stay in SwiftData. This model is a reversible
/// visual index over those rows, not a replacement for study history. A root
/// aggregate has no parent; when several aggregates are combined, the children
/// remain stored and point to the new parent so the hierarchy can be explored.
@Model
final class AggregatePebble {
    var id: UUID = UUID()
    var dataEpochID: UUID?
    var createdAt: Date = Date()
    var level: Int = 1
    var pebbleCount: Int = 0
    var childAggregateCount: Int = 0
    var grams: Int = 0
    var measuredPebbleCount: Int = 0
    var manualPebbleCount: Int = 0
    var goldPebbleCount: Int = 0
    var prismPebbleCount: Int = 0
    var colorMixJSON: String = "[]"
    var subjectMixJSON: String = "[]"
    var periodStart: Date = Date()
    var periodEnd: Date = Date()
    var sessionIDsJSON: String = "[]"
    var childAggregateIDsJSON: String = "[]"
    var parentAggregateID: UUID?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        level: Int,
        pebbleCount: Int,
        childAggregateCount: Int = 0,
        grams: Int,
        measuredPebbleCount: Int = 0,
        manualPebbleCount: Int = 0,
        goldPebbleCount: Int = 0,
        prismPebbleCount: Int = 0,
        colorMixJSON: String,
        subjectMixJSON: String = "[]",
        periodStart: Date,
        periodEnd: Date,
        sessionIDs: [UUID] = [],
        childAggregateIDs: [UUID] = [],
        parentAggregateID: UUID? = nil,
        dataEpochID: UUID? = nil
    ) {
        self.id = id
        self.dataEpochID = dataEpochID
        self.createdAt = createdAt
        self.level = max(1, level)
        self.pebbleCount = max(0, pebbleCount)
        self.childAggregateCount = max(0, childAggregateCount)
        self.grams = max(0, grams)
        self.measuredPebbleCount = max(0, measuredPebbleCount)
        self.manualPebbleCount = max(0, manualPebbleCount)
        self.goldPebbleCount = max(0, goldPebbleCount)
        self.prismPebbleCount = max(0, prismPebbleCount)
        self.colorMixJSON = colorMixJSON
        self.subjectMixJSON = subjectMixJSON
        self.periodStart = min(periodStart, periodEnd)
        self.periodEnd = max(periodStart, periodEnd)
        self.sessionIDsJSON = Self.encodeUUIDs(sessionIDs)
        self.childAggregateIDsJSON = Self.encodeUUIDs(childAggregateIDs)
        self.parentAggregateID = parentAggregateID
    }

    var sessionIDs: [UUID] {
        Self.decodeUUIDs(sessionIDsJSON)
    }

    var childAggregateIDs: [UUID] {
        Self.decodeUUIDs(childAggregateIDsJSON)
    }

    var colorMix: [StratumColorFraction] {
        StrataMath.decodeColorMix(colorMixJSON)
    }

    var subjectMix: [AggregateSubjectFraction] {
        StrataMath.decodeSubjectMix(subjectMixJSON)
    }

    var isRoot: Bool { parentAggregateID == nil }

    func replaceSessionIDs(_ ids: [UUID]) {
        sessionIDsJSON = Self.encodeUUIDs(ids)
    }

    func replaceChildAggregateIDs(_ ids: [UUID]) {
        childAggregateIDsJSON = Self.encodeUUIDs(ids)
        childAggregateCount = Set(ids).count
    }

    private static func decodeUUIDs(_ json: String) -> [UUID] {
        guard let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(values.compactMap(UUID.init(uuidString:))).sorted {
            $0.uuidString < $1.uuidString
        }
    }

    private static func encodeUUIDs(_ ids: [UUID]) -> String {
        let values = Set(ids.map(\.uuidString)).sorted()
        guard let data = try? JSONEncoder().encode(values),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }
}

enum AggregatePebblePolicy {
    /// Bounded SpriteKit selection plus an exact summary of roots that were
    /// intentionally left out of the physical jar.
    ///
    /// The omitted values are not an accounting total: callers must continue
    /// to use `accountingFrontier` for CloudKit conflict handling. They are a
    /// conservation contract for the visual projection, allowing the UI to say
    /// how much persisted effort is represented outside the live physics set
    /// instead of making that effort appear to vanish at the body limit.
    struct VisibleRootProjection {
        let visibleRoots: [AggregatePebble]
        let totalRootCount: Int
        let omittedRootCount: Int
        let omittedPebbleCount: Int
        let omittedGrams: Int
        let omittedGoldPebbleCount: Int
        let omittedPrismPebbleCount: Int

        var hasOmittedRoots: Bool { omittedRootCount > 0 }
    }

    /// A non-overlapping accounting cut through the persisted aggregate graph.
    ///
    /// `summaries` may contain complete descendants when a partially delivered
    /// parent cannot yet be trusted. Known membership is represented at most
    /// once; compatibility rows without membership retain their historic
    /// summary semantics and are disclosed separately.
    struct AccountingFrontier {
        let summaries: [AggregatePebble]
        let representedSessionIDs: Set<UUID>
        let conflictedAggregateIDs: Set<UUID>
        let containsUnknownMembership: Bool
        let isLowerBound: Bool
    }

    /// Rows with neither direct leaf membership nor child links predate the
    /// reversible hierarchy. An empty `sessionIDs` array alone is not enough:
    /// compact level-two-and-higher rows intentionally store only child IDs.
    static func isUnattributedCompatibility(_ value: AggregatePebble) -> Bool {
        value.sessionIDs.isEmpty && value.childAggregateIDs.isEmpty
    }

    /// Direct membership is stored exactly once, on level-one leaves. Legacy
    /// flattened rows are included until bootstrap can prove their child graph
    /// is complete and safely compact them.
    static func directSessionIDs(from values: [AggregatePebble]) -> Set<UUID> {
        Set(canonicalValues(from: values).flatMap(\.sessionIDs))
    }

    /// Builds a deterministic, non-overlapping accounting projection without
    /// mutating the persisted graph.
    ///
    /// A parent's declared child list is sufficient to establish ownership
    /// while an otherwise identical child backlink is still in flight. When a
    /// parent is incomplete, its complete downloaded descendants become the
    /// frontier instead. The traversal stores each direct session reference in
    /// only one candidate set, rather than memoizing a flattened set at every
    /// decimal level, keeping multi-decade accounting linear in persisted
    /// references.
    static func accountingFrontier(
        from values: [AggregatePebble]
    ) -> AccountingFrontier {
        let canonical = canonicalValues(from: values)
        guard !canonical.isEmpty else {
            return AccountingFrontier(
                summaries: [],
                representedSessionIDs: [],
                conflictedAggregateIDs: [],
                containsUnknownMembership: false,
                isLowerBound: false
            )
        }

        let byID = Dictionary(uniqueKeysWithValues: canonical.map { ($0.id, $0) })
        var declaredParentsByChild: [UUID: Set<UUID>] = [:]
        for parent in canonical {
            for childID in Set(parent.childAggregateIDs) {
                declaredParentsByChild[childID, default: []].insert(parent.id)
            }
        }

        // A present backlink and a present declaring parent are two replicas of
        // the same edge. More than one distinct present parent is ambiguous and
        // must not make both ancestor summaries authoritative.
        var parentByChild: [UUID: UUID] = [:]
        var conflictedIDs = Set<UUID>()
        for child in canonical {
            var parentCandidates = declaredParentsByChild[child.id] ?? []
            if let backlink = child.parentAggregateID, byID[backlink] != nil {
                parentCandidates.insert(backlink)
            }
            guard parentCandidates.count == 1, let parentID = parentCandidates.first else {
                if parentCandidates.count > 1 {
                    conflictedIDs.insert(child.id)
                    conflictedIDs.formUnion(parentCandidates)
                }
                continue
            }
            guard let parent = byID[parentID], child.level == parent.level - 1 else {
                conflictedIDs.insert(child.id)
                conflictedIDs.insert(parentID)
                continue
            }
            parentByChild[child.id] = parentID
        }

        // With at most one parent per node, cycle detection is a linear parent
        // walk. Breaking every cycle edge makes the remaining traversal a
        // forest and preserves individually valid descendants as a lower bound.
        var processedIDs = Set<UUID>()
        var cycleIDs = Set<UUID>()
        for startID in byID.keys where !processedIDs.contains(startID) {
            var path: [UUID] = []
            var pathIndex: [UUID: Int] = [:]
            var cursor: UUID? = startID
            while let currentID = cursor, !processedIDs.contains(currentID) {
                if let cycleStart = pathIndex[currentID] {
                    cycleIDs.formUnion(path[cycleStart...])
                    break
                }
                pathIndex[currentID] = path.count
                path.append(currentID)
                cursor = parentByChild[currentID]
            }
            processedIDs.formUnion(path)
        }
        if !cycleIDs.isEmpty {
            conflictedIDs.formUnion(cycleIDs)
            for id in cycleIDs { parentByChild.removeValue(forKey: id) }
        }

        var childrenByParent: [UUID: [UUID]] = [:]
        for (childID, parentID) in parentByChild {
            childrenByParent[parentID, default: []].append(childID)
        }
        for parentID in Array(childrenByParent.keys) {
            childrenByParent[parentID]?.sort { $0.uuidString < $1.uuidString }
        }

        func isCompatibilityTerminal(_ aggregate: AggregatePebble) -> Bool {
            aggregate.sessionIDs.isEmpty
                && aggregate.childAggregateIDs.isEmpty
                && (childrenByParent[aggregate.id]?.isEmpty ?? true)
        }

        // Decimal levels strictly decrease across accepted edges, so normal
        // data has only a handful of recursive frames even after forty years.
        var completeMemo: [UUID: Bool] = [:]
        func isComplete(_ id: UUID) -> Bool {
            if let cached = completeMemo[id] { return cached }
            guard let aggregate = byID[id] else { return false }

            let directCount = Set(aggregate.sessionIDs).count
            if directCount > 0 {
                let valid = directCount == max(0, aggregate.pebbleCount)
                    && (aggregate.level > 1
                        || directCount <= Constants.Jar.aggregateFanIn)
                completeMemo[id] = valid
                return valid
            }

            if isCompatibilityTerminal(aggregate) {
                let valid = aggregate.pebbleCount > 0
                completeMemo[id] = valid
                return valid
            }

            let declaredChildIDs = Set(aggregate.childAggregateIDs)
            guard !conflictedIDs.contains(id),
                  (1...Constants.Jar.aggregateFanIn).contains(declaredChildIDs.count),
                  aggregate.childAggregateCount == declaredChildIDs.count
            else {
                completeMemo[id] = false
                return false
            }

            let children = declaredChildIDs.compactMap { byID[$0] }
            let valid = children.count == declaredChildIDs.count
                && children.allSatisfy {
                    parentByChild[$0.id] == id
                        && $0.level == aggregate.level - 1
                        && isComplete($0.id)
                }
                && children.reduce(0) { $0 + max(0, $1.pebbleCount) }
                    == max(0, aggregate.pebbleCount)
                && children.reduce(0) { $0 + max(0, $1.grams) }
                    == max(0, aggregate.grams)
            completeMemo[id] = valid
            return valid
        }

        // Choose the highest complete node in each component. An incomplete
        // parent contributes nothing itself, but its complete present children
        // remain available as a conservative partial-sync frontier.
        let componentRoots = canonical
            .filter { parentByChild[$0.id] == nil }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.createdAt < rhs.createdAt
            }
        var initialCandidateIDs: [UUID] = []
        var visitedForFrontier = Set<UUID>()
        var isLowerBound = false

        func collectFrontier(from id: UUID) {
            guard visitedForFrontier.insert(id).inserted else { return }
            if isComplete(id) {
                initialCandidateIDs.append(id)
                return
            }
            isLowerBound = true
            for childID in childrenByParent[id] ?? [] {
                collectFrontier(from: childID)
            }
        }
        for root in componentRoots { collectFrontier(from: root.id) }

        typealias Candidate = (
            aggregate: AggregatePebble,
            membership: Set<UUID>,
            hasUnknownMembership: Bool
        )
        var candidates: [Candidate] = []

        for candidateID in initialCandidateIDs {
            guard let candidate = byID[candidateID] else { continue }
            var stack = [candidateID]
            var visited = Set<UUID>()
            var membership = Set<UUID>()
            var terminalValues: [AggregatePebble] = []
            var hasInternalOverlap = false
            var hasUnknownMembership = false

            while let currentID = stack.popLast() {
                guard visited.insert(currentID).inserted,
                      let current = byID[currentID] else { continue }
                let direct = Set(current.sessionIDs)
                if !direct.isEmpty {
                    if !membership.isDisjoint(with: direct) {
                        hasInternalOverlap = true
                    }
                    membership.formUnion(direct)
                    terminalValues.append(current)
                    continue
                }
                if isCompatibilityTerminal(current) {
                    hasUnknownMembership = true
                    terminalValues.append(current)
                    continue
                }
                stack.append(contentsOf: childrenByParent[currentID] ?? [])
            }

            let knownMembershipCloses = !hasInternalOverlap
                && (hasUnknownMembership
                    || membership.count == max(0, candidate.pebbleCount))
            if knownMembershipCloses {
                candidates.append((candidate, membership, hasUnknownMembership))
                continue
            }

            // A numerically closed ancestor whose leaf memberships overlap is
            // not authoritative. Its terminal rows are independently safe
            // candidates and are de-duplicated by the global frontier below.
            isLowerBound = true
            conflictedIDs.insert(candidate.id)
            for terminal in terminalValues {
                let direct = Set(terminal.sessionIDs)
                if !direct.isEmpty,
                   direct.count == max(0, terminal.pebbleCount) {
                    candidates.append((terminal, direct, false))
                } else if isCompatibilityTerminal(terminal), terminal.pebbleCount > 0 {
                    candidates.append((terminal, [], true))
                }
            }
        }

        // Prefer the summary that retains the largest proven lower bound. The
        // stable tie-breakers keep CloudKit delivery order from changing which
        // of two overlapping summaries is displayed.
        candidates.sort { lhs, rhs in
            if lhs.aggregate.pebbleCount != rhs.aggregate.pebbleCount {
                return lhs.aggregate.pebbleCount > rhs.aggregate.pebbleCount
            }
            if lhs.aggregate.level != rhs.aggregate.level {
                return lhs.aggregate.level > rhs.aggregate.level
            }
            if lhs.aggregate.createdAt != rhs.aggregate.createdAt {
                return lhs.aggregate.createdAt < rhs.aggregate.createdAt
            }
            return lhs.aggregate.id.uuidString < rhs.aggregate.id.uuidString
        }

        var selected: [AggregatePebble] = []
        var representedSessionIDs = Set<UUID>()
        var membershipOwnerBySessionID: [UUID: UUID] = [:]
        var containsUnknownMembership = false
        var selectedAggregateIDs = Set<UUID>()

        for candidate in candidates where !selectedAggregateIDs.contains(candidate.aggregate.id) {
            let overlappingIDs = candidate.membership.intersection(representedSessionIDs)
            guard overlappingIDs.isEmpty else {
                isLowerBound = true
                conflictedIDs.insert(candidate.aggregate.id)
                for sessionID in overlappingIDs {
                    if let ownerID = membershipOwnerBySessionID[sessionID] {
                        conflictedIDs.insert(ownerID)
                    }
                }
                continue
            }

            selected.append(candidate.aggregate)
            selectedAggregateIDs.insert(candidate.aggregate.id)
            representedSessionIDs.formUnion(candidate.membership)
            for sessionID in candidate.membership {
                membershipOwnerBySessionID[sessionID] = candidate.aggregate.id
            }
            containsUnknownMembership = containsUnknownMembership
                || candidate.hasUnknownMembership
        }

        selected.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
        return AccountingFrontier(
            summaries: selected,
            representedSessionIDs: representedSessionIDs,
            conflictedAggregateIDs: conflictedIDs,
            containsUnknownMembership: containsUnknownMembership,
            isLowerBound: isLowerBound || !conflictedIDs.isEmpty
        )
    }

    /// Resolves original sessions only for detail/export flows. Home and the jar
    /// use `directSessionIDs` plus `StudySession.isBaked`, avoiding repeated
    /// construction of a recursively flattened multi-decade membership set.
    static func descendantSessionIDs(
        of value: AggregatePebble,
        in values: [AggregatePebble]
    ) -> [UUID] {
        let canonical = canonicalValues(from: values)
        let byID = Dictionary(uniqueKeysWithValues: canonical.map { ($0.id, $0) })
        var memo: [UUID: Set<UUID>] = [:]

        func resolve(_ id: UUID, visiting: Set<UUID>) -> Set<UUID> {
            if let cached = memo[id] { return cached }
            guard !visiting.contains(id), let aggregate = byID[id] else { return [] }
            let direct = Set(aggregate.sessionIDs)
            if !direct.isEmpty {
                memo[id] = direct
                return direct
            }
            var nextVisiting = visiting
            nextVisiting.insert(id)
            let resolved = aggregate.childAggregateIDs.reduce(into: Set<UUID>()) {
                $0.formUnion(resolve($1, visiting: nextVisiting))
            }
            memo[id] = resolved
            return resolved
        }

        return resolve(value.id, visiting: []).sorted { $0.uuidString < $1.uuidString }
    }

    /// A compact root is trusted for aggregate-first totals only when every
    /// child record is present and the recursive pebble counts close exactly.
    /// This prevents a parent that arrives early through CloudKit from being
    /// added on top of still-loose sessions.
    static func hasCompleteLineage(
        _ value: AggregatePebble,
        in values: [AggregatePebble]
    ) -> Bool {
        let canonical = canonicalValues(from: values)
        let byID = Dictionary(uniqueKeysWithValues: canonical.map { ($0.id, $0) })
        var memo: [UUID: Bool] = [:]

        func validate(_ id: UUID, visiting: Set<UUID>) -> Bool {
            if let cached = memo[id] { return cached }
            guard !visiting.contains(id), let aggregate = byID[id] else { return false }
            let directCount = Set(aggregate.sessionIDs).count
            if directCount > 0 {
                let valid = directCount == aggregate.pebbleCount
                    && (aggregate.level > 1 || directCount <= Constants.Jar.aggregateFanIn)
                memo[id] = valid
                return valid
            }
            if isUnattributedCompatibility(aggregate) {
                let valid = aggregate.pebbleCount > 0
                memo[id] = valid
                return valid
            }
            let childIDs = Set(aggregate.childAggregateIDs)
            guard !childIDs.isEmpty,
                  childIDs.count <= Constants.Jar.aggregateFanIn else {
                memo[id] = false
                return false
            }
            var nextVisiting = visiting
            nextVisiting.insert(id)
            let children = childIDs.compactMap { byID[$0] }
            let valid = children.count == childIDs.count
                && children.allSatisfy { validate($0.id, visiting: nextVisiting) }
                && children.reduce(0) { $0 + max(0, $1.pebbleCount) }
                    == aggregate.pebbleCount
            memo[id] = valid
            return valid
        }

        return validate(value.id, visiting: [])
    }

    static func lineageReferenceCount(from values: [AggregatePebble]) -> Int {
        canonicalValues(from: values).reduce(0) {
            $0 + Set($1.sessionIDs).count + Set($1.childAggregateIDs).count
        }
    }

    /// Returns root aggregates in a stable chronological order while shielding
    /// the scene from transient duplicate CloudKit rows.
    static func activeRoots(from values: [AggregatePebble]) -> [AggregatePebble] {
        canonicalValues(from: values)
        .filter(\.isRoot)
        .sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.createdAt < rhs.createdAt
        }
    }

    /// Removes provably overlapping summaries from a bounded root-only page.
    ///
    /// Home and lifetime sharing intentionally fetch roots without recursively
    /// materializing decades of descendants. During CloudKit delivery, a child
    /// can therefore appear as a root for one frame while its already-arrived
    /// parent declares ownership of that same child. Legacy flattened roots can
    /// also expose overlapping direct session membership. Prefer the larger,
    /// higher summary deterministically and count every known session/child at
    /// most once. Membership-less compatibility summaries remain visible
    /// because overlap cannot be proved from a root-only page.
    static func disjointRootSummaries(
        from values: [AggregatePebble]
    ) -> [AggregatePebble] {
        let preferred = activeRoots(from: values).sorted { lhs, rhs in
            if lhs.pebbleCount != rhs.pebbleCount {
                return lhs.pebbleCount > rhs.pebbleCount
            }
            if lhs.level != rhs.level { return lhs.level > rhs.level }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        var selected: [AggregatePebble] = []
        var selectedIDs = Set<UUID>()
        var representedSessionIDs = Set<UUID>()
        var representedChildIDs = Set<UUID>()

        for candidate in preferred {
            let directSessionIDs = Set(candidate.sessionIDs)
            let directChildIDs = Set(candidate.childAggregateIDs)
            let isDeclaredChild = representedChildIDs.contains(candidate.id)
            let declaresSelectedRoot = !directChildIDs.isDisjoint(with: selectedIDs)
            let overlapsSessions = !directSessionIDs.isDisjoint(with: representedSessionIDs)
            let overlapsChildren = !directChildIDs.isDisjoint(with: representedChildIDs)

            guard !isDeclaredChild,
                  !declaresSelectedRoot,
                  !overlapsSessions,
                  !overlapsChildren
            else { continue }

            selected.append(candidate)
            selectedIDs.insert(candidate.id)
            representedSessionIDs.formUnion(directSessionIDs)
            representedChildIDs.formUnion(directChildIDs)
        }

        return selected.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    /// A pathological multi-decade sync must never exceed SpriteKit's body
    /// budget. Keep recent small increments plus the highest overview levels,
    /// and summarize everything outside the live physical set without
    /// flattening descendant membership.
    static func visibleRootProjection(
        from values: [AggregatePebble]
    ) -> VisibleRootProjection {
        let roots = activeRoots(from: values)
        let limit = Constants.Jar.maximumVisibleAggregateRoots
        guard roots.count > limit else {
            return VisibleRootProjection(
                visibleRoots: roots,
                totalRootCount: roots.count,
                omittedRootCount: 0,
                omittedPebbleCount: 0,
                omittedGrams: 0,
                omittedGoldPebbleCount: 0,
                omittedPrismPebbleCount: 0
            )
        }

        let recentCount = min(Constants.Jar.minimumRecentAggregateRoots, limit)
        let recent = Array(roots.suffix(recentCount))
        let recentIDs = Set(recent.map(\.id))
        let overview = roots
            .filter { !recentIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.level == rhs.level {
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.level > rhs.level
            }
            .prefix(limit - recent.count)
        let visible = (Array(overview) + recent).sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.createdAt < rhs.createdAt
        }
        let visibleIDs = Set(visible.map(\.id))
        let omitted = roots.filter { !visibleIDs.contains($0.id) }
        return VisibleRootProjection(
            visibleRoots: visible,
            totalRootCount: roots.count,
            omittedRootCount: omitted.count,
            omittedPebbleCount: omitted.reduce(0) { $0 + $1.pebbleCount },
            omittedGrams: omitted.reduce(0) { $0 + $1.grams },
            omittedGoldPebbleCount: omitted.reduce(0) { $0 + $1.goldPebbleCount },
            omittedPrismPebbleCount: omitted.reduce(0) { $0 + $1.prismPebbleCount }
        )
    }

    static func visibleRoots(from values: [AggregatePebble]) -> [AggregatePebble] {
        visibleRootProjection(from: values).visibleRoots
    }

    private static func canonicalValues(
        from values: [AggregatePebble]
    ) -> [AggregatePebble] {
        Dictionary(grouping: values, by: \.id).values.compactMap { duplicates in
            let candidates = duplicates.contains { $0.parentAggregateID != nil }
                ? duplicates.filter { $0.parentAggregateID != nil }
                : duplicates
            return candidates.max { lhs, rhs in
                if lhs.level == rhs.level { return lhs.createdAt < rhs.createdAt }
                return lhs.level < rhs.level
            }
        }
    }
}

/// Legacy read-only storage retained so existing stores migrate without losing
/// any study history. New versions persist AggregatePebble instead.
@Model
final class Stratum {
    var id: UUID = UUID()
    var dataEpochID: UUID?
    var bakedAt: Date = Date()
    var pebbleCount: Int = 0
    var heightPt: Double = 0
    var colorMixJSON: String = "[]"
    var monthLabel: String = ""
    /// Session membership makes concurrent CloudKit bakes reconcilable. The
    /// rows remain in StudySession for history, but each ID may belong to only
    /// one persisted stratum after bootstrap reconciliation.
    var sessionIDsJSON: String = "[]"

    /// Exact mass represented by this stratum. This keeps totals reversible
    /// when differently-sized manual entries are baked together.
    var grams: Int = 0

    init(
        id: UUID = UUID(),
        bakedAt: Date = Date(),
        pebbleCount: Int,
        heightPt: Double,
        colorMixJSON: String,
        monthLabel: String,
        grams: Int? = nil,
        sessionIDs: [UUID] = [],
        dataEpochID: UUID? = nil
    ) {
        self.id = id
        self.dataEpochID = dataEpochID
        self.bakedAt = bakedAt
        self.pebbleCount = max(0, pebbleCount)
        self.heightPt = max(0, heightPt)
        self.colorMixJSON = colorMixJSON
        self.monthLabel = monthLabel
        self.grams = max(0, grams ?? pebbleCount * Constants.Mass.measuredPebbleGrams)
        self.sessionIDsJSON = Self.encodeSessionIDs(sessionIDs)
    }

    var sessionIDs: [UUID] {
        guard let data = sessionIDsJSON.data(using: .utf8),
              let strings = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return strings.compactMap(UUID.init(uuidString:))
    }

    func replaceSessionIDs(_ ids: [UUID]) {
        sessionIDsJSON = Self.encodeSessionIDs(ids)
    }

    private static func encodeSessionIDs(_ ids: [UUID]) -> String {
        let values = Set(ids.map(\.uuidString)).sorted()
        guard let data = try? JSONEncoder().encode(values),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }
}

/// Legacy compatibility record for the retired one-time import. It is no longer
/// shown in the UI and never contributes a fixed floor or a physics body.
@Model
final class Bedrock {
    var dataEpochID: UUID?
    var hours: Int = 0
    var importedAt: Date = Date()

    init(
        hours: Int,
        importedAt: Date = Date(),
        dataEpochID: UUID? = nil
    ) {
        self.dataEpochID = dataEpochID
        self.hours = min(max(0, hours), Constants.Fairness.bedrockMaximumHours)
        self.importedAt = importedAt
    }
}

@Model
final class GachaState {
    var id: UUID = UUID()
    var dataEpochID: UUID?
    var sinceLastGold: Int = 0
    /// Total measured mass accepted while random rewards were enabled.
    ///
    /// This is intentionally monotonic rather than storing only a remainder:
    /// duplicate CloudKit rows can preserve the larger value deterministically.
    /// Existing stores migrate to zero, keeping their already-earned pity
    /// counter while starting the new mass ledger with no invented remainder.
    var rewardCreditGrams: Int = 0

    init(
        id: UUID = UUID(),
        sinceLastGold: Int = 0,
        rewardCreditGrams: Int = 0,
        dataEpochID: UUID? = nil
    ) {
        self.id = id
        self.dataEpochID = dataEpochID
        self.sinceLastGold = max(0, sinceLastGold)
        self.rewardCreditGrams = max(0, rewardCreditGrams)
    }

    var earnedRewardCreditCount: Int {
        rewardCreditGrams / Constants.Gacha.creditGrams
    }

    var rewardCreditRemainderGrams: Int {
        rewardCreditGrams % Constants.Gacha.creditGrams
    }
}

@Model
final class Prefs {
    var id: UUID = UUID()
    /// Reset generation for activity-derived counters only. Settings and
    /// onboarding intent remain synchronized across resets.
    var activityEpochID: UUID?
    var manualDayKey: String = ""
    var manualUsedToday: Int = 0
    var soundOn: Bool = true
    var hapticsOn: Bool = true
    /// `rareRewardModeUpdatedAt == nil` means the person has not made an
    /// informed choice yet. In that state the reward policy always behaves as
    /// `.off`, regardless of a legacy raw value.
    var rareRewardModeRawValue: String = RareRewardMode.off.rawValue
    var rareRewardModeUpdatedAt: Date?
    var reminderEnabled: Bool = false
    var reminderHour: Int = Constants.Notification.defaultReminderHour
    var reminderMinute: Int = Constants.Notification.defaultReminderMinute
    var shareIncludesManual: Bool = false
    /// Controls whether a user-authored category name may leave the app UI via
    /// notifications or Live Activities. Privacy-safe false is the universal
    /// default, especially for work categories that may contain client context.
    var showsThemeNameExternally: Bool = false
    var isPro: Bool = false
    var keepScreenAwake: Bool = true
    var preferredFocusMinutes: Int = Constants.Timer.twentyFiveMinutes
    /// Synced user intent. Local AppStorage mirrors these values for fast UI
    /// startup, while CloudKit makes another or replacement iPhone reopen the
    /// same experience instead of showing first-run setup again.
    var hasCompletedOnboarding: Bool = false
    var usagePurposeRawValue: String = UsagePurpose.study.rawValue
    var usagePurposeUpdatedAt: Date?
    /// Tombstone for the lifetime-once bedrock import. It deliberately remains
    /// true when the visible Bedrock row is deleted from Settings.
    var hasEverImportedBedrock: Bool = false
    /// Prevents deleted preset subjects from being recreated on later launches.
    var hasCompletedInitialSubjectSeed: Bool = false

    init(
        id: UUID = UUID(),
        manualDayKey: String = "",
        manualUsedToday: Int = 0,
        soundOn: Bool = true,
        hapticsOn: Bool = true,
        rareRewardModeRawValue: String = RareRewardMode.off.rawValue,
        rareRewardModeUpdatedAt: Date? = nil,
        reminderEnabled: Bool = false,
        reminderHour: Int = Constants.Notification.defaultReminderHour,
        reminderMinute: Int = Constants.Notification.defaultReminderMinute,
        shareIncludesManual: Bool = false,
        showsThemeNameExternally: Bool = false,
        isPro: Bool = false,
        keepScreenAwake: Bool = true,
        preferredFocusMinutes: Int = Constants.Timer.twentyFiveMinutes,
        hasCompletedOnboarding: Bool = false,
        usagePurposeRawValue: String = UsagePurpose.study.rawValue,
        usagePurposeUpdatedAt: Date? = nil,
        hasEverImportedBedrock: Bool = false,
        hasCompletedInitialSubjectSeed: Bool = false,
        activityEpochID: UUID? = nil
    ) {
        self.id = id
        self.activityEpochID = activityEpochID
        self.manualDayKey = manualDayKey
        self.manualUsedToday = max(0, manualUsedToday)
        self.soundOn = soundOn
        self.hapticsOn = hapticsOn
        self.rareRewardModeRawValue = RareRewardMode.resolved(
            rareRewardModeRawValue
        ).rawValue
        self.rareRewardModeUpdatedAt = rareRewardModeUpdatedAt
        self.reminderEnabled = reminderEnabled
        self.reminderHour = reminderHour
        self.reminderMinute = reminderMinute
        self.shareIncludesManual = shareIncludesManual
        self.showsThemeNameExternally = showsThemeNameExternally
        self.isPro = isPro
        self.keepScreenAwake = keepScreenAwake
        self.preferredFocusMinutes = preferredFocusMinutes
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.usagePurposeRawValue = UsagePurpose(
            rawValue: usagePurposeRawValue
        )?.rawValue ?? UsagePurpose.study.rawValue
        self.usagePurposeUpdatedAt = usagePurposeUpdatedAt
        self.hasEverImportedBedrock = hasEverImportedBedrock
        self.hasCompletedInitialSubjectSeed = hasCompletedInitialSubjectSeed
    }
}
