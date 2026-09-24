import Foundation
import SwiftData

/// What produced a completed record.
///
/// `StudySession.source` stores this enum as its raw String, and CloudKit
/// mirrors that value to every device on the Apple Account, including devices
/// still running the shipped 1.0.2. That build decodes the field with a
/// three-case enum, and SwiftData calls `fatalError` on any other raw value
/// the first time the row is read. The persisted encoding is therefore frozen
/// to `legacyPersistableRawValues`; a newer classification is stored in an
/// older value plus a signature, and resolved by `StudySession.effectiveSource`.
enum SessionSource: String, Codable, CaseIterable, Sendable {
    case timer
    case manual
    case timerDemoted
    /// Completed Screen Time usage thresholds; never a timer or rare draw.
    ///
    /// In-memory classification only. It is persisted as `.manual` with the
    /// Screen Time signature (see `persistedEncoding`). The case stays so a
    /// row a pre-release 1.1.0 build stored with this raw value still decodes.
    case screenTime

    /// The raw values the shipped 1.0.2 decoder accepts. Frozen: a value added
    /// here, or persisted outside it, crash-loops every older device that
    /// shares the iCloud data. `CloudSchemaCompatibilityTests` pins it.
    static let legacyPersistableRawValues: Set<String> = [
        "timer", "manual", "timerDemoted"
    ]

    /// Screen Time learning is only ever recorded in fixed ten-minute chunks.
    static let screenTimeSeconds = 600
    static var screenTimeGrams: Int { StudySession.grams(for: screenTimeSeconds) }

    /// The shape that identifies a Screen Time record stored as `.manual`.
    /// The manual sheet offers only `ManualDuration` (30/60/120 minutes), so a
    /// real manual entry never has it, and 1.0.2's integrity policy rejects it:
    /// an older device keeps such a row hidden instead of misreading it.
    static func hasScreenTimeSignature(seconds: Int, grams: Int) -> Bool {
        seconds == screenTimeSeconds && grams == screenTimeGrams
    }

    /// The value the app writes to storage for this classification. Every
    /// result is in `legacyPersistableRawValues`.
    var persistedEncoding: SessionSource {
        self == .screenTime ? .manual : self
    }

    /// Resolves a stored value back to its classification. A `.screenTime`
    /// written by a pre-release build resolves to itself.
    static func effective(
        persisted: SessionSource,
        seconds: Int,
        grams: Int
    ) -> SessionSource {
        guard persisted == .manual,
              hasScreenTimeSignature(seconds: seconds, grams: grams) else {
            return persisted
        }
        return .screenTime
    }

    var isMeasured: Bool { self == .timer || self == .screenTime }
    var isSelfReported: Bool { !isMeasured }
    var displayName: String { self == .screenTime ? "Screen Time" : (isMeasured ? "実測" : "自己申告") }
}

enum PebbleKind: String, Codable, CaseIterable, Sendable {
    case normal
    case gold
    case prism
}

/// One fail-closed boundary for integers loaded from synchronized or legacy
/// stores. Model initializers are not a sufficient trust boundary: CloudKit
/// can hydrate persisted properties without calling them, and older stores can
/// contain values outside today's UI constraints.
enum NonnegativeIntPolicy {
    static func clamped(_ value: Int, maximum: Int = .max) -> Int {
        min(max(0, value), max(0, maximum))
    }

    /// Converts calculated presentation values without relying on Swift's
    /// trapping `Double`-to-`Int` conversion at or beyond the integer range.
    static func clamped(_ value: Double, maximum: Int = .max) -> Int {
        let upperBound = max(0, maximum)
        guard !value.isNaN, value > 0 else { return 0 }
        guard value.isFinite else { return upperBound }
        guard value < Double(upperBound) else { return upperBound }
        return Int(value)
    }

    static func clamped(_ value: Int64, maximum: Int64 = .max) -> Int64 {
        min(max(0, value), max(0, maximum))
    }

    static func adding(
        _ lhs: Int,
        _ rhs: Int,
        maximum: Int = .max
    ) -> Int {
        let upperBound = max(0, maximum)
        let left = clamped(lhs, maximum: upperBound)
        let right = clamped(rhs, maximum: upperBound)
        guard left <= upperBound - right else { return upperBound }
        return left + right
    }

    static func sum<S: Sequence>(
        _ values: S,
        maximum: Int = .max
    ) -> Int where S.Element == Int {
        values.reduce(0) { adding($0, $1, maximum: maximum) }
    }

    static func adding(
        _ lhs: Int64,
        _ rhs: Int64,
        maximum: Int64 = .max
    ) -> Int64 {
        let upperBound = max(0, maximum)
        let left = clamped(lhs, maximum: upperBound)
        let right = clamped(rhs, maximum: upperBound)
        guard left <= upperBound - right else { return upperBound }
        return left + right
    }

    static func sum<S: Sequence>(
        _ values: S,
        maximum: Int64 = .max
    ) -> Int64 where S.Element == Int64 {
        values.reduce(0) { adding($0, $1, maximum: maximum) }
    }

    static func multiplying(
        _ lhs: Int,
        _ rhs: Int,
        maximum: Int = .max
    ) -> Int {
        let upperBound = max(0, maximum)
        let left = clamped(lhs, maximum: upperBound)
        let right = clamped(rhs, maximum: upperBound)
        guard left > 0, right > 0 else { return 0 }
        guard left <= upperBound / right else { return upperBound }
        return left * right
    }

    /// Advances an externally sourced ordinal without ever trapping. Values
    /// below the domain restart at its minimum; values at the maximum saturate.
    static func next(
        after value: Int?,
        minimum: Int = 0,
        maximum: Int = .max
    ) -> Int {
        let lowerBound = max(0, minimum)
        let upperBound = max(lowerBound, maximum)
        guard let value, value >= lowerBound else { return lowerBound }
        return adding(value, 1, maximum: upperBound)
    }
}

/// Raw reward data remains stored and exportable while version 1.0 keeps the
/// unverified random-reward feature off every user-visible surface. Callers
/// should transform only presentation values through this policy; aggregation
/// and export continue to use the original fields for a future reviewed build.
enum RareRewardPresentationPolicy {
    static var isEnabled: Bool { RareRewardReleasePolicy.isEnabled }

    static func kind(_ rawValue: PebbleKind) -> PebbleKind {
        isEnabled ? rawValue : .normal
    }

    static func counts(_ rawValue: RareRewardCounts) -> RareRewardCounts {
        guard isEnabled else {
            return RareRewardCounts(drawCount: 0, goldCount: 0, prismCount: 0)
        }
        return rawValue
    }

    static func goldCount(_ rawValue: Int) -> Int {
        isEnabled ? NonnegativeIntPolicy.clamped(rawValue) : 0
    }

    static func prismCount(_ rawValue: Int) -> Int {
        isEnabled ? NonnegativeIntPolicy.clamped(rawValue) : 0
    }

    static func containsRare(goldCount: Int, prismCount: Int) -> Bool {
        guard isEnabled else { return false }
        return NonnegativeIntPolicy.adding(goldCount, prismCount) > 0
    }
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

    var seconds: Int {
        NonnegativeIntPolicy.multiplying(
            minutes,
            Constants.Timer.secondsPerMinute
        )
    }
    var grams: Int {
        NonnegativeIntPolicy.multiplying(
            minutes,
            Constants.Mass.gramsPerMinute
        )
    }
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
    /// Application-managed identity for this physical synchronized row.
    /// `persistentModelID` is only stable inside one local SwiftData store, so
    /// presentation and relationship repair use this value as their final
    /// cross-device tie-breaker. It is immutable after initialization.
    var syncRecordID: UUID = UUID()
    /// Reversible subject edits use the same non-destructive replica rule as
    /// preferences. New rows start at one; migrated pre-release rows at zero
    /// enter the deterministic legacy fallback until the next explicit edit.
    var contentRevision: Int = 0
    var contentMutationID: UUID = UUID()
    var name: String = ""
    var colorHex: String = Constants.Color.english
    var sortOrder: Int = 0
    var isArchived: Bool = false
    /// Logical deletion tombstone. Physical CloudKit rows remain available so
    /// a delayed duplicate cannot recreate a category the user deleted.
    var deletedAt: Date?
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
        deletedAt: Date? = nil,
        createdAt: Date = Date(),
        syncRecordID: UUID = UUID(),
        contentRevision: Int = 1,
        contentMutationID: UUID = UUID()
    ) {
        self.id = id
        self.syncRecordID = syncRecordID
        self.contentRevision = min(
            max(0, contentRevision),
            SubjectSyncPolicy.maximumSupportedContentRevision
        )
        self.contentMutationID = contentMutationID
        self.name = SubjectNamePolicy.sanitized(name)
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.isArchived = isArchived
        self.deletedAt = deletedAt
        self.createdAt = createdAt
    }
}

enum SubjectSyncPolicy {
    static let maximumPhysicalRows = 256
    enum MutationError: Error, Equatable {
        case revisionLimitReached
        case tooManyPhysicalRows
    }

    static let maximumSupportedContentRevision = 1_000_000

    static func canonical(from values: [Subject]) -> Subject? {
        let supportedValues = values.filter({ subject in
            (0...maximumSupportedContentRevision)
                .contains(subject.contentRevision)
        })
        // v1 has no restore operation. Once any supported replica carries a
        // deletion tombstone, a higher-revision offline rename cannot revive
        // the logical subject. This includes a migrated revision-zero row.
        let stickyCandidates = supportedValues.contains {
            $0.deletedAt != nil
        } ? supportedValues.filter { $0.deletedAt != nil } : supportedValues
        let versionedCandidates = stickyCandidates.filter({ subject in
            (1...maximumSupportedContentRevision)
                .contains(subject.contentRevision)
        })
        if let versioned = versionedCandidates.max(by: isOrderedBefore) {
            return versioned
        }
        let legacyCandidates = stickyCandidates.filter { $0.contentRevision == 0 }
        return legacyCandidates.max(by: legacyIsOrderedBefore)
    }

    static func canonicalSubjects(from values: [Subject]) -> [Subject] {
        Dictionary(grouping: values, by: \.id)
            .values
            .compactMap(canonical)
            .sorted {
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    /// UI/accounting fail closed when a hostile physical replica set exceeds
    /// the same bounded source catalogue audited by maintenance.
    static func presentationSubjects(from values: [Subject]) -> [Subject] {
        guard values.count <= maximumPhysicalRows else { return [] }
        return canonicalSubjects(from: values).filter { $0.deletedAt == nil }
    }

    @MainActor
    static func presentationSubject(
        id: UUID,
        context: ModelContext
    ) throws -> Subject? {
        var descriptor = FetchDescriptor<Subject>(
            predicate: #Predicate { $0.id == id },
            sortBy: [SortDescriptor(\Subject.syncRecordID)]
        )
        descriptor.fetchLimit = maximumPhysicalRows + 1
        let values = try context.fetch(descriptor)
        guard values.count <= maximumPhysicalRows else {
            throw MutationError.tooManyPhysicalRows
        }
        guard let subject = canonical(from: values), subject.deletedAt == nil else {
            return nil
        }
        return subject
    }

    /// Stamps one explicit edit on the selected physical row. Other CloudKit
    /// rows are immutable evidence: rewriting every observed copy would race a
    /// concurrent edit made through another ModelContext and could erase it.
    static func recordUserMutation(
        from source: Subject,
        among availableValues: [Subject],
        mutationID: UUID = UUID()
    ) throws {
        guard availableValues.count <= maximumPhysicalRows else {
            throw MutationError.tooManyPhysicalRows
        }
        var evidence = availableValues.filter { $0.id == source.id }
        if !evidence.contains(where: { $0 === source }) { evidence.append(source) }
        guard evidence.count <= maximumPhysicalRows else {
            throw MutationError.tooManyPhysicalRows
        }
        let maximum = evidence.filter({ subject in
                (0...maximumSupportedContentRevision)
                    .contains(subject.contentRevision)
            }).map(\.contentRevision)
            .max() ?? 0
        guard maximum < maximumSupportedContentRevision else {
            throw MutationError.revisionLimitReached
        }
        source.contentRevision = maximum + 1
        source.contentMutationID = mutationID
    }

    private static func isOrderedBefore(_ lhs: Subject, _ rhs: Subject) -> Bool {
        if lhs.contentRevision != rhs.contentRevision {
            return lhs.contentRevision < rhs.contentRevision
        }
        // A same-base offline archive intent fails closed over a concurrent
        // rename. Deletion is selected before revision comparison above.
        if (lhs.deletedAt != nil) != (rhs.deletedAt != nil) {
            return lhs.deletedAt == nil
        }
        if lhs.isArchived != rhs.isArchived { return !lhs.isArchived }
        if lhs.contentMutationID != rhs.contentMutationID {
            return lhs.contentMutationID.uuidString
                < rhs.contentMutationID.uuidString
        }
        return lhs.syncRecordID.uuidString < rhs.syncRecordID.uuidString
    }

    private static func legacyIsOrderedBefore(
        _ lhs: Subject,
        _ rhs: Subject
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        if (lhs.deletedAt != nil) != (rhs.deletedAt != nil) {
            return lhs.deletedAt == nil
        }
        if lhs.deletedAt != rhs.deletedAt {
            return (lhs.deletedAt ?? .distantPast) < (rhs.deletedAt ?? .distantPast)
        }
        if lhs.isArchived != rhs.isArchived { return !lhs.isArchived }
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder > rhs.sortOrder }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        if lhs.colorHex != rhs.colorHex { return lhs.colorHex < rhs.colorHex }
        return lhs.syncRecordID.uuidString < rhs.syncRecordID.uuidString
    }
}

@Model
final class StudySession {
    var id: UUID = UUID()
    /// Immutable, CloudKit-synchronized identity of this physical copy. The
    /// logical completion identity remains `id`; duplicate source rows are
    /// retained and converge instead of being destructively compacted.
    var syncRecordID: UUID = UUID()
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
    /// Stored, CloudKit-synchronized encoding of the record's source. Its name
    /// and type are the shipped schema; only the Swift access level is narrow.
    /// It is `fileprivate` so that no reader outside this file can mistake the
    /// encoding for the classification: read `effectiveSource`, and write only
    /// through the initializer or `persistedSource`, which both store
    /// `SessionSource.persistedEncoding`.
    fileprivate var source: SessionSource = SessionSource.timer
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

    /// Legacy synchronized projection bit retained only for store/schema
    /// compatibility and export transparency. Runtime visibility, accounting,
    /// and aggregation must use local AggregatePebble/Stratum membership.
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
        dataEpochID: UUID? = nil,
        syncRecordID: UUID = UUID()
    ) {
        self.id = id
        self.syncRecordID = syncRecordID
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
        // `.screenTime` is written as `.manual`; the fixed 600 s / 100 g shape
        // of a Screen Time chunk is what `effectiveSource` resolves it from.
        self.source = source.persistedEncoding
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

    /// What this record is. Every consumer (integrity, history, share, jar,
    /// fairness, reward and aggregation) reads this, never the stored encoding.
    var effectiveSource: SessionSource {
        SessionSource.effective(persisted: source, seconds: seconds, grams: grams)
    }

    /// The encoding this build persists for the record. Store-to-store copies
    /// capture and restore this field, so both sides of a copy agree and a copy
    /// never carries the pre-release raw value forward.
    var persistedSource: SessionSource {
        get { source.persistedEncoding }
        set { source = newValue.persistedEncoding }
    }

    /// True only for a row a pre-release 1.1.0 build stored as `screenTime`.
    var hasLegacySourceEncoding: Bool { source != source.persistedEncoding }

    /// Rewrites a pre-release `screenTime` value to the encoding 1.0.2 can
    /// decode. `effectiveSource` is unchanged; only older readers notice.
    @discardableResult
    func normalizeLegacySourceEncoding() -> Bool {
        guard hasLegacySourceEncoding else { return false }
        source = source.persistedEncoding
        return true
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
        NonnegativeIntPolicy.multiplying(
            NonnegativeIntPolicy.clamped(seconds)
                / Constants.Timer.secondsPerMinute,
            Constants.Mass.gramsPerMinute
        )
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

#if DEBUG
extension StudySession {
    /// Tests only: stores a raw value exactly as a pre-release 1.1.0 build
    /// did, bypassing `persistedEncoding`, to exercise legacy rows.
    func overwriteStoredSourceForTesting(_ value: SessionSource) {
        source = value
    }
}
#endif

/// Fail-closed trust boundary for completed activity loaded from CloudKit or a
/// legacy store. Unsupported rows stay persisted (and therefore remain in the
/// raw data export), but must not become history, progress, or maintenance
/// inputs until a future migration can interpret them safely.
enum StudySessionIntegrityPolicy {
    /// The shipping endurance harness covers forty years. These wider rolling
    /// past bounds preserve that contract. A synced completion may lead the
    /// evaluating device by at most one year, which is already a deliberately
    /// generous allowance for device-clock skew without admitting arbitrary
    /// future history into timelines and projections.
    static let maximumPastAge: TimeInterval = 100 * 365.25 * 24 * 60 * 60
    static let maximumFutureLead: TimeInterval = 365 * 24 * 60 * 60
    /// A focus, including all pauses, belongs to one seven-day wall-clock
    /// window. The active award is capped at the timer's public maximum. This permits
    /// multi-day recovery while preventing a short completion from spanning
    /// years because of hostile or uninterpretable legacy timestamps.
    static let maximumCompletionWallSpan: TimeInterval = 7 * 24 * 60 * 60
    static let maximumSeconds = NonnegativeIntPolicy.multiplying(
        Constants.Timer.customMaximumMinutes,
        Constants.Timer.secondsPerMinute
    )
    static let maximumGrams = NonnegativeIntPolicy.multiplying(
        Constants.Timer.customMaximumMinutes,
        Constants.Mass.gramsPerMinute
    )

    static func supportedDateBounds(
        relativeTo now: Date = .now
    ) -> (earliest: Date, latest: Date) {
        (
            now.addingTimeInterval(-maximumPastAge),
            now.addingTimeInterval(maximumFutureLead)
        )
    }

    static func isSupported(
        _ session: StudySession,
        relativeTo now: Date = .now
    ) -> Bool {
        isSupported(
            startAt: session.startAt,
            endAt: session.endAt,
            seconds: session.seconds,
            source: session.effectiveSource,
            grams: session.grams,
            relativeTo: now
        )
    }

    static func isSupported(
        startAt: Date,
        endAt: Date,
        seconds: Int,
        source: SessionSource,
        grams: Int,
        relativeTo now: Date = .now
    ) -> Bool {
        let start = startAt.timeIntervalSinceReferenceDate
        let end = endAt.timeIntervalSinceReferenceDate
        let elapsed = endAt.timeIntervalSince(startAt)
        let nowValue = now.timeIntervalSinceReferenceDate
        let dateBounds = supportedDateBounds(relativeTo: now)
        guard start.isFinite,
              end.isFinite,
              nowValue.isFinite,
              elapsed.isFinite,
              elapsed >= TimeInterval(seconds),
              elapsed <= maximumCompletionWallSpan,
              startAt >= dateBounds.earliest,
              endAt <= dateBounds.latest,
              seconds >= Constants.Timer.secondsPerMinute,
              seconds <= maximumSeconds,
              grams >= 0,
              grams <= maximumGrams
        else { return false }

        switch source {
        case .timer, .timerDemoted:
            // Pauses legitimately make wall-clock span longer than active
            // focus, but active seconds and credited mass still come from one
            // deterministic timer completion.
            return seconds.isMultiple(of: Constants.Timer.secondsPerMinute)
                && grams == StudySession.grams(for: seconds)
        case .screenTime:
            return SessionSource.hasScreenTimeSignature(seconds: seconds, grams: grams)
        case .manual:
            // The product has only these three explicit manual-entry choices.
            // Requiring the paired duration and mass prevents a corrupted row
            // from borrowing the trusted semantics of either field alone.
            return ManualDuration.allCases.contains {
                $0.seconds == seconds && $0.grams == grams
            }
        }
    }

    static func supported<S: Sequence>(
        _ sessions: S
    ) -> [StudySession] where S.Element == StudySession {
        sessions.filter { isSupported($0) }
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
        NonnegativeIntPolicy.sum(values)
    }

}

enum StudySessionSyncPolicy {
    struct ChangeToken: Equatable, Hashable, Sendable {
        let id: UUID
        let syncRecordID: UUID
        let dataEpochID: UUID?
        let subjectID: UUID?
        let subjectName: String
        let subjectColorHex: String
        let subjectIDSnapshot: UUID?
        let subjectNameSnapshot: String
        let subjectColorHexSnapshot: String
        let startAt: Date
        let endAt: Date
        let seconds: Int
        let source: SessionSource
        let pebbleKind: PebbleKind
        let grams: Int
        let deviceDayKey: String
        let rareRewardRuleVersion: Int?
        let rareRewardParticipated: Bool?
        let rareRewardCreditedGrams: Int?
        let rareRewardOutcomesRawValue: String?
        let isBaked: Bool

        /// Length-prefixing prevents delimiter-bearing synchronized strings
        /// from making two distinct change tokens compare equal in RootView's
        /// heterogeneous activity fingerprint.
        var stableFingerprint: String {
            let identityFields = [
                id.uuidString,
                syncRecordID.uuidString,
                dataEpochID?.uuidString ?? "",
                subjectID?.uuidString ?? "",
                subjectName,
                subjectColorHex,
                subjectIDSnapshot?.uuidString ?? "",
                subjectNameSnapshot,
                subjectColorHexSnapshot
            ]
            let timingFields = [
                String(startAt.timeIntervalSinceReferenceDate.bitPattern),
                String(endAt.timeIntervalSinceReferenceDate.bitPattern),
                String(seconds),
                source.rawValue,
                pebbleKind.rawValue,
                String(grams),
                deviceDayKey
            ]
            let rewardFields = [
                rareRewardRuleVersion.map(String.init) ?? "",
                rareRewardParticipated.map(String.init) ?? "",
                rareRewardCreditedGrams.map(String.init) ?? "",
                rareRewardOutcomesRawValue ?? "",
                String(isBaked)
            ]
            return (identityFields + timingFields + rewardFields)
                .map { "\($0.utf8.count):\($0)" }
                .joined()
        }
    }

    struct RareRewardMetadata: Equatable {
        let ruleVersion: Int
        let participated: Bool
        let creditedGrams: Int
        let outcomesRawValue: String
    }

    /// Pure logical projection for transient CloudKit duplicates. Source rows
    /// are never rewritten or deleted by maintenance: a deterministic physical
    /// representative is selected at every read/accounting boundary instead.
    /// Conservative source/reward state sorts before display-only tie-breaks so
    /// a delayed demotion or opt-out cannot be revived by an older copy.
    static func canonicalSession(from values: [StudySession]) -> StudySession? {
        StudySessionIntegrityPolicy.supported(values).max(by: isOrderedBefore)
    }

    static func canonicalSessions(from values: [StudySession]) -> [StudySession] {
        let grouped = Dictionary(grouping: values, by: \.id)
        var seen = Set<UUID>()
        // Preserve the caller's explicit fetch/presentation order while
        // replacing each logical ID with its deterministic physical winner.
        // Dictionary value iteration is intentionally unspecified and used to
        // corrupt chronological page boundaries in aggregate maintenance.
        return values.compactMap { value in
            guard seen.insert(value.id).inserted,
                  let group = grouped[value.id] else { return nil }
            return canonicalSession(from: group)
        }
    }

    static func changeToken(for value: StudySession) -> ChangeToken {
        ChangeToken(
            id: value.id,
            syncRecordID: value.syncRecordID,
            dataEpochID: value.dataEpochID,
            subjectID: value.subject?.id,
            subjectName: value.subject?.name ?? "",
            subjectColorHex: value.subject?.colorHex ?? "",
            subjectIDSnapshot: value.subjectIDSnapshot,
            subjectNameSnapshot: value.subjectNameSnapshot,
            subjectColorHexSnapshot: value.subjectColorHexSnapshot,
            startAt: value.startAt,
            endAt: value.endAt,
            seconds: value.seconds,
            source: value.effectiveSource,
            pebbleKind: value.pebbleKind,
            grams: value.grams,
            deviceDayKey: value.deviceDayKey,
            rareRewardRuleVersion: value.rareRewardRuleVersion,
            rareRewardParticipated: value.rareRewardParticipated,
            rareRewardCreditedGrams: value.rareRewardCreditedGrams,
            rareRewardOutcomesRawValue: value.rareRewardOutcomesRawValue,
            isBaked: value.isBaked
        )
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
        let versioned = StudySessionIntegrityPolicy.supported(sessions)
            .filter { $0.rareRewardRuleVersion != nil }
        guard let newestRule = versioned
            .compactMap(\.rareRewardRuleVersion)
            .max() else { return nil }
        let values = versioned.filter {
            $0.rareRewardRuleVersion == newestRule
        }
        guard newestRule == Constants.Gacha.creditRuleVersion
                || newestRule == RareRewardLedgerV2.ruleVersion else {
            return RareRewardMetadata(
                ruleVersion: newestRule,
                participated: false,
                creditedGrams: 0,
                outcomesRawValue: ""
            )
        }
        // V2 saves the StudySession and local outbox atomically before the
        // custom-zone transaction. A finalized duplicate wins over that
        // intentionally outcome-free pending row; a pending-only group stays
        // pending instead of being rewritten into a permanent opt-out.
        let finalized = newestRule == RareRewardLedgerV2.ruleVersion
            ? values.filter { $0.rareRewardParticipated != nil }
            : values
        guard !finalized.isEmpty else { return nil }
        guard finalized.allSatisfy({ $0.rareRewardParticipated == true }) else {
            return RareRewardMetadata(
                ruleVersion: newestRule,
                participated: false,
                creditedGrams: 0,
                outcomesRawValue: ""
            )
        }
        let grams = finalized.compactMap(\.rareRewardCreditedGrams)
        let outcomes = finalized.compactMap(\.rareRewardOutcomesRawValue)
        guard grams.count == finalized.count,
              Set(grams).count == 1,
              outcomes.count == finalized.count,
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

    private static func isOrderedBefore(
        _ lhs: StudySession,
        _ rhs: StudySession
    ) -> Bool {
        let leftSource = sourceSafetyRank(lhs.effectiveSource)
        let rightSource = sourceSafetyRank(rhs.effectiveSource)
        if leftSource != rightSource { return leftSource < rightSource }

        let leftRule = lhs.rareRewardRuleVersion ?? -1
        let rightRule = rhs.rareRewardRuleVersion ?? -1
        if leftRule != rightRule { return leftRule < rightRule }
        let leftParticipation = participationSafetyRank(
            lhs.rareRewardParticipated
        )
        let rightParticipation = participationSafetyRank(
            rhs.rareRewardParticipated
        )
        if leftParticipation != rightParticipation {
            return leftParticipation < rightParticipation
        }
        if lhs.grams != rhs.grams { return lhs.grams < rhs.grams }
        if lhs.seconds != rhs.seconds { return lhs.seconds < rhs.seconds }
        let leftPebble = syncRank(lhs.pebbleKind)
        let rightPebble = syncRank(rhs.pebbleKind)
        if leftPebble != rightPebble { return leftPebble < rightPebble }
        if lhs.rareRewardCreditedGrams != rhs.rareRewardCreditedGrams {
            return (lhs.rareRewardCreditedGrams ?? -1)
                < (rhs.rareRewardCreditedGrams ?? -1)
        }
        if lhs.rareRewardOutcomesRawValue != rhs.rareRewardOutcomesRawValue {
            return (lhs.rareRewardOutcomesRawValue ?? "")
                < (rhs.rareRewardOutcomesRawValue ?? "")
        }
        // Earlier timestamps are conservative for a logical completion that
        // momentarily has two physical representations.
        if lhs.endAt != rhs.endAt { return lhs.endAt > rhs.endAt }
        if lhs.startAt != rhs.startAt { return lhs.startAt > rhs.startAt }
        if lhs.deviceDayKey != rhs.deviceDayKey {
            return lhs.deviceDayKey > rhs.deviceDayKey
        }
        if lhs.subjectIDSnapshot != rhs.subjectIDSnapshot {
            return (lhs.subjectIDSnapshot?.uuidString ?? "")
                < (rhs.subjectIDSnapshot?.uuidString ?? "")
        }
        if lhs.subjectNameSnapshot != rhs.subjectNameSnapshot {
            return lhs.subjectNameSnapshot < rhs.subjectNameSnapshot
        }
        if lhs.subjectColorHexSnapshot != rhs.subjectColorHexSnapshot {
            return lhs.subjectColorHexSnapshot < rhs.subjectColorHexSnapshot
        }
        return lhs.syncRecordID.uuidString < rhs.syncRecordID.uuidString
    }

    private static func sourceSafetyRank(_ source: SessionSource) -> Int {
        switch source {
        case .timer: 0
        case .screenTime: 1
        case .manual: 2
        case .timerDemoted: 3
        }
    }

    private static func participationSafetyRank(_ value: Bool?) -> Int {
        switch value {
        case true: 0
        case nil: 1
        case false: 2
        }
    }
}

/// A result worth remembering, kept separate from study time so it can never
/// inflate mass, measured completion counts, or the manual-entry allowance.
@Model
final class AchievementStone {
    var id: UUID = UUID()
    /// Immutable physical-row identity used only after every semantic
    /// revision/tombstone field ties. Duplicate CloudKit source rows remain
    /// stored so a late edit cannot be erased by another device's compaction.
    var syncRecordID: UUID = UUID()
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
    /// Unique deletion event acknowledged by an explicit restore. A migrated
    /// tombstone without this field uses `syncRecordID` as its stable token.
    var deletionMutationID: UUID?
    /// Revision at which the latest observed deletion event occurred. This is
    /// retained after an in-place restore so removing `deletedAt` never erases
    /// the only durable proof that a deletion happened.
    var deletionRevision: Int = 0
    /// Proof that an active row observed and explicitly restored the dominant
    /// tombstone. A higher revision alone is insufficient: an offline edit
    /// that never saw the delete must not resurrect the milestone.
    var restoredDeletionMutationID: UUID?
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
        deletionMutationID: UUID? = nil,
        deletionRevision: Int = 0,
        restoredDeletionMutationID: UUID? = nil,
        updatedAt: Date? = nil,
        syncRecordID: UUID = UUID()
    ) {
        self.id = id
        self.syncRecordID = syncRecordID
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
        self.revision = min(
            max(1, revision),
            AchievementStonePolicy.maximumSupportedRevision
        )
        self.deletedAt = deletedAt
        self.deletionMutationID = deletionMutationID
        self.deletionRevision = deletionRevision
        self.restoredDeletionMutationID = restoredDeletionMutationID
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
    struct DeletionEvent: Equatable {
        let revision: Int
        let token: UUID
        let sourceSyncRecordID: UUID
    }

    /// A human cannot approach this ceiling through normal edits. Bounding the
    /// synchronized value lets a forged `Int.max` row fail closed instead of
    /// winning forever or trapping the next mutation.
    static let maximumSupportedRevision = 1_000_000
    static let maximumPhysicalRowsPerLogicalStone = 256

    static func hasSupportedRevision(_ value: AchievementStone) -> Bool {
        (1...maximumSupportedRevision).contains(value.revision)
    }

    /// Resolves logical duplicates without depending on CloudKit delivery
    /// order. A tombstone remains sticky across higher offline edits unless an
    /// active row carries an explicit acknowledgement of the dominant delete.
    static func canonicalStones(from values: [AchievementStone]) -> [AchievementStone] {
        Dictionary(grouping: values, by: \.id).values.compactMap(canonicalStone)
    }

    static func canonicalStone(from values: [AchievementStone]) -> AchievementStone? {
        let supported = values.filter(hasSupportedRevision)
        guard let deletion = dominantDeletionEvent(from: supported) else {
            return supported.max(by: isOrderedBefore)
        }
        let acknowledgedRestores = supported.filter {
            $0.deletedAt == nil
                && $0.revision > deletion.revision
                && $0.deletionRevision == deletion.revision
                && $0.deletionMutationID == deletion.token
                && $0.restoredDeletionMutationID == deletion.token
        }
        if let restored = acknowledgedRestores.max(by: isOrderedBefore) {
            return restored
        }
        return supported.filter {
            guard $0.deletedAt != nil,
                  let event = deletionEvent(for: $0) else { return false }
            return event.revision == deletion.revision
                && event.token == deletion.token
        }.max(by: tombstoneIsOrderedBefore)
    }

    static func deletionToken(for value: AchievementStone) -> UUID {
        value.deletionMutationID ?? value.syncRecordID
    }

    static func dominantDeletionEvent(
        from values: [AchievementStone]
    ) -> DeletionEvent? {
        values.filter(hasSupportedRevision)
            .compactMap(deletionEvent)
            .max(by: deletionEventIsOrderedBefore)
    }

    private static func deletionEvent(
        for value: AchievementStone
    ) -> DeletionEvent? {
        if (1...maximumSupportedRevision).contains(value.deletionRevision),
           let token = value.deletionMutationID {
            return DeletionEvent(
                revision: value.deletionRevision,
                token: token,
                sourceSyncRecordID: value.syncRecordID
            )
        }
        guard value.deletedAt != nil else { return nil }
        return DeletionEvent(
            revision: value.revision,
            token: deletionToken(for: value),
            sourceSyncRecordID: value.syncRecordID
        )
    }

    /// Maintenance-only recovery source when every synchronized revision is
    /// malformed. Invalid revisions are never canonical; this merely chooses
    /// which bounded payload to rewrite at revision one.
    static func repairCandidate(from values: [AchievementStone]) -> AchievementStone? {
        values.max { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            if (lhs.deletedAt != nil) != (rhs.deletedAt != nil) {
                return lhs.deletedAt == nil
            }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            let leftPayload = deterministicPayloadKey(lhs)
            let rightPayload = deterministicPayloadKey(rhs)
            if leftPayload != rightPayload { return leftPayload < rightPayload }
            return lhs.syncRecordID.uuidString < rhs.syncRecordID.uuidString
        }
    }

    /// Resolves one logical milestone at the database boundary. Candidate
    /// pages may intentionally query only active rows so years of tombstones
    /// cannot starve useful content; every candidate ID must pass through this
    /// exact, bounded replica-set lookup before it is rendered or shared.
    static func canonicalDescriptor(
        id: UUID,
        dataEpochID: UUID?
    ) -> FetchDescriptor<AchievementStone> {
        let supportedRevisionMaximum = Self.maximumSupportedRevision
        let predicate: Predicate<AchievementStone>
        if let dataEpochID {
            predicate = #Predicate {
                $0.id == id
                    && $0.dataEpochID == dataEpochID
                    && $0.revision >= 1
                    && $0.revision <= supportedRevisionMaximum
            }
        } else {
            predicate = #Predicate {
                $0.id == id
                    && $0.dataEpochID == nil
                    && $0.revision >= 1
                    && $0.revision <= supportedRevisionMaximum
            }
        }
        var descriptor = FetchDescriptor<AchievementStone>(
            predicate: predicate,
            sortBy: [SortDescriptor(\AchievementStone.syncRecordID)]
        )
        descriptor.fetchLimit = maximumPhysicalRowsPerLogicalStone + 1
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
            let copies = try context.fetch(canonicalDescriptor(
                id: candidate.id,
                dataEpochID: candidate.dataEpochID
            ))
            guard copies.count <= maximumPhysicalRowsPerLogicalStone else {
                continue
            }
            let winner = canonicalStone(from: copies)
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
        let leftPayload = deterministicPayloadKey(lhs)
        let rightPayload = deterministicPayloadKey(rhs)
        if leftPayload != rightPayload { return leftPayload < rightPayload }
        return lhs.syncRecordID.uuidString < rhs.syncRecordID.uuidString
    }

    private static func tombstoneIsOrderedBefore(
        _ lhs: AchievementStone,
        _ rhs: AchievementStone
    ) -> Bool {
        guard let left = deletionEvent(for: lhs),
              let right = deletionEvent(for: rhs) else {
            return deletionEvent(for: lhs) == nil
        }
        if left.revision != right.revision { return left.revision < right.revision }
        if left.token != right.token {
            return left.token.uuidString < right.token.uuidString
        }
        return lhs.syncRecordID.uuidString < rhs.syncRecordID.uuidString
    }

    private static func deletionEventIsOrderedBefore(
        _ lhs: DeletionEvent,
        _ rhs: DeletionEvent
    ) -> Bool {
        if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
        if lhs.token != rhs.token {
            return lhs.token.uuidString < rhs.token.uuidString
        }
        return lhs.sourceSyncRecordID.uuidString
            < rhs.sourceSyncRecordID.uuidString
    }

    private static func deterministicPayloadKey(_ stone: AchievementStone) -> String {
        [
            stone.kind.rawValue,
            stone.note,
            stone.subject?.id.uuidString ?? "",
            stone.subjectNameSnapshot,
            stone.subjectColorHexSnapshot,
            stone.deletedAt?.timeIntervalSinceReferenceDate.description ?? "",
            stone.deletionMutationID?.uuidString ?? "",
            String(stone.deletionRevision),
            stone.restoredDeletionMutationID?.uuidString ?? ""
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
    enum MutationResult: Equatable {
        case applied
        case revisionLimitReached
    }

    @discardableResult
    static func edit(
        _ values: [AchievementStone],
        subject: Subject,
        kind: AchievementKind,
        note: String,
        achievedAt: Date,
        now: Date = .now
    ) -> MutationResult {
        let canonical = AchievementStonePolicy.canonicalStone(from: values)
        return apply(
            values,
            subject: subject,
            subjectNameSnapshot: subject.safeDisplayName,
            subjectColorHexSnapshot: subject.colorHex,
            kind: kind,
            note: note,
            achievedAt: achievedAt,
            deletedAt: canonical?.deletedAt,
            deletionRevision: canonical?.deletionRevision ?? 0,
            deletionMutationID: canonical?.deletionMutationID,
            restoredDeletionMutationID: canonical?.restoredDeletionMutationID,
            now: now
        )
    }

    @discardableResult
    static func delete(
        _ values: [AchievementStone],
        deletionMutationID: UUID = UUID(),
        now: Date = .now
    ) -> MutationResult {
        guard let target = mutationTarget(in: values) else { return .applied }
        guard let nextRevision = nextRevision(in: values) else {
            return .revisionLimitReached
        }
        target.revision = nextRevision
        target.deletedAt = now
        target.deletionRevision = nextRevision
        target.deletionMutationID = deletionMutationID
        target.restoredDeletionMutationID = nil
        target.updatedAt = now
        return .applied
    }

    @discardableResult
    static func restore(
        _ values: [AchievementStone],
        snapshot: AchievementStoneRevisionSnapshot,
        subject: Subject?,
        now: Date = .now
    ) -> MutationResult {
        let acknowledgedDeletion = AchievementStonePolicy.dominantDeletionEvent(
            from: values
        )
        return apply(
            values,
            subject: subject,
            subjectNameSnapshot: snapshot.subjectNameSnapshot,
            subjectColorHexSnapshot: snapshot.subjectColorHexSnapshot,
            kind: snapshot.kind,
            note: snapshot.note,
            achievedAt: snapshot.achievedAt,
            deletedAt: nil,
            deletionRevision: acknowledgedDeletion?.revision ?? 0,
            deletionMutationID: acknowledgedDeletion?.token,
            restoredDeletionMutationID: acknowledgedDeletion?.token,
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
        deletionRevision: Int,
        deletionMutationID: UUID?,
        restoredDeletionMutationID: UUID?,
        now: Date
    ) -> MutationResult {
        guard let value = mutationTarget(in: values) else { return .applied }
        guard let nextRevision = nextRevision(in: values) else {
            return .revisionLimitReached
        }
        value.subject = subject
        value.subjectNameSnapshot = SubjectNamePolicy.sanitized(subjectNameSnapshot)
        value.subjectColorHexSnapshot = subjectColorHexSnapshot
        value.kind = kind
        value.note = AchievementStone.sanitizedNote(note)
        value.achievedAt = min(achievedAt, now)
        value.revision = nextRevision
        value.deletedAt = deletedAt
        value.deletionRevision = deletionRevision
        value.deletionMutationID = deletionMutationID
        value.restoredDeletionMutationID = restoredDeletionMutationID
        value.updatedAt = now
        return .applied
    }

    private static func mutationTarget(
        in values: [AchievementStone]
    ) -> AchievementStone? {
        AchievementStonePolicy.canonicalStone(from: values)
            ?? AchievementStonePolicy.repairCandidate(from: values)
    }

    private static func nextRevision(in values: [AchievementStone]) -> Int? {
        let maximum = values
            .filter(AchievementStonePolicy.hasSupportedRevision)
            .map(\.revision)
            .max()
        guard maximum != AchievementStonePolicy.maximumSupportedRevision else {
            return nil
        }
        return NonnegativeIntPolicy.next(
            after: maximum,
            minimum: 1,
            maximum: AchievementStonePolicy.maximumSupportedRevision
        )
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
enum AggregateProjectionValidation {
    static let currentVersion = 1
}

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
    /// Device-local derivation trust. A zero value is intentionally the
    /// lightweight-migration default: old projections remain a visible lower
    /// bound until maintenance re-derives their leaf payloads from the current
    /// logical StudySession winners and closes every ancestor equation.
    var projectionValidationVersion: Int = 0

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
        dataEpochID: UUID? = nil,
        projectionValidationVersion: Int = AggregateProjectionValidation.currentVersion
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
        self.projectionValidationVersion = max(0, projectionValidationVersion)
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
        Set(canonicalValues(from: values)
            .filter {
                $0.projectionValidationVersion
                    == AggregateProjectionValidation.currentVersion
            }
            .flatMap(\.sessionIDs))
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
            guard let parent = byID[parentID],
                  child.level >= 1,
                  child.level < Int.max,
                  NonnegativeIntPolicy.next(after: child.level, minimum: 1)
                    == parent.level else {
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
            guard let aggregate = byID[id],
                  aggregate.projectionValidationVersion
                    == AggregateProjectionValidation.currentVersion
            else { return false }

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
                        && $0.level >= 1
                        && $0.level < Int.max
                        && NonnegativeIntPolicy.next(
                            after: $0.level,
                            minimum: 1
                        ) == aggregate.level
                        && isComplete($0.id)
                }
                && NonnegativeIntPolicy.sum(children.map(\.pebbleCount))
                    == max(0, aggregate.pebbleCount)
                && NonnegativeIntPolicy.sum(children.map(\.grams))
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
    /// use a bounded level-one query in their local projection store, avoiding
    /// both the legacy synchronized `isBaked` bit and a recursively flattened
    /// multi-decade membership set.
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
            guard !visiting.contains(id),
                  let aggregate = byID[id],
                  aggregate.projectionValidationVersion
                    == AggregateProjectionValidation.currentVersion
            else { return false }
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
                && NonnegativeIntPolicy.sum(children.map(\.pebbleCount))
                    == aggregate.pebbleCount
            memo[id] = valid
            return valid
        }

        return validate(value.id, visiting: [])
    }

    static func lineageReferenceCount(from values: [AggregatePebble]) -> Int {
        canonicalValues(from: values).reduce(0) { total, aggregate in
            NonnegativeIntPolicy.sum([
                total,
                Set(aggregate.sessionIDs).count,
                Set(aggregate.childAggregateIDs).count
            ])
        }
    }

    /// Returns root aggregates in a stable chronological order while shielding
    /// the scene from transient duplicate CloudKit rows.
    static func activeRoots(from values: [AggregatePebble]) -> [AggregatePebble] {
        canonicalValues(from: values)
        .filter {
            $0.isRoot
                && $0.projectionValidationVersion
                    == AggregateProjectionValidation.currentVersion
        }
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
            omittedPebbleCount: NonnegativeIntPolicy.sum(omitted.map(\.pebbleCount)),
            omittedGrams: NonnegativeIntPolicy.sum(omitted.map(\.grams)),
            omittedGoldPebbleCount: NonnegativeIntPolicy.sum(
                omitted.map(\.goldPebbleCount)
            ),
            omittedPrismPebbleCount: NonnegativeIntPolicy.sum(
                omitted.map(\.prismPebbleCount)
            )
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
        self.grams = NonnegativeIntPolicy.clamped(
            grams ?? NonnegativeIntPolicy.multiplying(
                pebbleCount,
                Constants.Mass.measuredPebbleGrams
            )
        )
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

/// Timer-specific choices stay separate from the global sound and haptics
/// switches. Stable raw values are synchronized through `Prefs` and can be
/// extended without changing existing users' selection.
enum TimerCompletionSound: String, CaseIterable, Identifiable, Sendable {
    case standard
    case soft
    case bright

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "澄んだチャイム"
        case .soft: "やわらかいベル"
        case .bright: "明るいチャイム"
        }
    }

    var detail: String {
        switch self {
        case .standard: "区切りが分かる、落ち着いた2音"
        case .soft: "低めで穏やかな2音"
        case .bright: "軽やかに上がる3音"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: "bell.and.waves.left.and.right"
        case .soft: "bell"
        case .bright: "sparkles"
        }
    }

    static func resolved(_ rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .standard
    }
}

enum TimerCompletionHaptic: String, CaseIterable, Identifiable, Sendable {
    case standard
    case gentle
    case strong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "標準・2回"
        case .gentle: "やさしい・1回"
        case .strong: "しっかり・3回"
        }
    }

    var detail: String {
        switch self {
        case .standard: "短い2回で終了を知らせます"
        case .gentle: "控えめな1回で知らせます"
        case .strong: "はっきりした3回で知らせます"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: "waveform"
        case .gentle: "waveform.badge.minus"
        case .strong: "waveform.badge.plus"
        }
    }

    static func resolved(_ rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .standard
    }
}

/// The visual treatment used while a focus or break countdown is running.
/// Raw values are persisted and synchronized, so keep them stable.
enum TimerDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case ringAndTime
    case filledDial
    case timeOnly
    case ringOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ringAndTime: "リング＋時間"
        case .filledDial: "円盤（数字なし）"
        case .timeOnly: "時間のみ"
        case .ringOnly: "リングのみ"
        }
    }

    var detail: String {
        switch self {
        case .ringAndTime:
            "残り時間と、時計回りに減るリングを表示します"
        case .filledDial:
            "物理タイマーのように、色の円盤が時計回りに減ります。数字は表示しません"
        case .timeOnly:
            "残り時間の数字だけを大きく表示します"
        case .ringOnly:
            "時計回りに減るリングと残りの割合を表示します。残り時間の数字は表示しません"
        }
    }

    static func resolved(_ rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .ringAndTime
    }
}

@Model
final class Prefs {
    var id: UUID = UUID()
    /// Immutable identity of this physical synchronized row. SwiftData's
    /// `persistentModelID` cannot identify the same row across devices.
    var syncRecordID: UUID = UUID()
    /// Account-scoped device identity. Each device mutates only its own row so
    /// concurrent offline writes cannot overwrite every copy of another
    /// device's evidence in the CloudKit conflict resolver.
    var settingsWriterID: String = ""
    var soundRevision: Int = 0
    var soundMutationID: UUID?
    var hapticsRevision: Int = 0
    var hapticsMutationID: UUID?
    var timerCompletionSoundRevision: Int = 0
    var timerCompletionSoundMutationID: UUID?
    var timerCompletionHapticRevision: Int = 0
    var timerCompletionHapticMutationID: UUID?
    var rareRewardRevision: Int = 0
    var rareRewardMutationID: UUID?
    var reminderEnabledRevision: Int = 0
    var reminderEnabledMutationID: UUID?
    var reminderTimeRevision: Int = 0
    var reminderTimeMutationID: UUID?
    var shareIncludesManualRevision: Int = 0
    var shareIncludesManualMutationID: UUID?
    var externalThemeRevision: Int = 0
    var externalThemeMutationID: UUID?
    var keepScreenAwakeRevision: Int = 0
    var keepScreenAwakeMutationID: UUID?
    var preferredFocusMinutesRevision: Int = 0
    var preferredFocusMinutesMutationID: UUID?
    var timerDisplayModeRevision: Int = 0
    var timerDisplayModeMutationID: UUID?
    var usagePurposeRevision: Int = 0
    var usagePurposeMutationID: UUID?
    /// Reset generation for activity-derived counters only. Settings and
    /// onboarding intent remain synchronized across resets.
    var activityEpochID: UUID?
    var manualDayKey: String = ""
    var manualUsedToday: Int = 0
    var soundOn: Bool = true
    var hapticsOn: Bool = true
    var timerCompletionSoundRawValue: String = TimerCompletionSound.standard.rawValue
    var timerCompletionHapticRawValue: String = TimerCompletionHaptic.standard.rawValue
    /// `rareRewardModeUpdatedAt == nil` means the person has not made an
    /// informed choice yet. In that state the reward policy always behaves as
    /// `.off`, regardless of a legacy raw value.
    var rareRewardModeRawValue: String = RareRewardMode.off.rawValue
    var rareRewardModeUpdatedAt: Date?
    var reminderEnabled: Bool = false
    var reminderHour: Int = Constants.Notification.defaultReminderHour
    var reminderMinute: Int = Constants.Notification.defaultReminderMinute
    var shareIncludesManual: Bool = false
    /// Retained for pre-release schema compatibility. Version 1 notifications
    /// and Live Activities ignore this value and never render a user-authored
    /// category name outside the app.
    var showsThemeNameExternally: Bool = false
    /// Retained only for persistent-schema compatibility. StoreKit is the sole
    /// runtime entitlement authority; maintenance always normalizes this false.
    var isPro: Bool = false
    var keepScreenAwake: Bool = true
    var preferredFocusMinutes: Int = Constants.Timer.twentyFiveMinutes
    /// Additive precision for the existing minutes preference. Old clients
    /// still read/write minutes; their next minute mutation invalidates this
    /// extension instead of attaching an old seconds value to a new choice.
    var preferredFocusSeconds: Int?
    var preferredFocusSecondsMutationID: UUID?
    var timerDisplayModeRawValue: String = TimerDisplayMode.ringAndTime.rawValue
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
        timerCompletionSoundRawValue: String = TimerCompletionSound.standard.rawValue,
        timerCompletionHapticRawValue: String = TimerCompletionHaptic.standard.rawValue,
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
        timerDisplayModeRawValue: String = TimerDisplayMode.ringAndTime.rawValue,
        hasCompletedOnboarding: Bool = false,
        usagePurposeRawValue: String = UsagePurpose.study.rawValue,
        usagePurposeUpdatedAt: Date? = nil,
        hasEverImportedBedrock: Bool = false,
        hasCompletedInitialSubjectSeed: Bool = false,
        activityEpochID: UUID? = nil,
        syncRecordID: UUID = UUID(),
        settingsWriterID: String = ""
    ) {
        self.id = id
        self.syncRecordID = syncRecordID
        self.settingsWriterID = settingsWriterID
        self.activityEpochID = activityEpochID
        self.manualDayKey = manualDayKey
        self.manualUsedToday = max(0, manualUsedToday)
        self.soundOn = soundOn
        self.hapticsOn = hapticsOn
        self.timerCompletionSoundRawValue = TimerCompletionSound.resolved(
            timerCompletionSoundRawValue
        ).rawValue
        self.timerCompletionHapticRawValue = TimerCompletionHaptic.resolved(
            timerCompletionHapticRawValue
        ).rawValue
        self.rareRewardModeRawValue = RareRewardMode.resolved(
            rareRewardModeRawValue
        ).rawValue
        self.rareRewardModeUpdatedAt = rareRewardModeUpdatedAt
        self.reminderEnabled = reminderEnabled
        self.reminderHour = reminderHour
        self.reminderMinute = reminderMinute
        self.shareIncludesManual = shareIncludesManual
        self.showsThemeNameExternally = showsThemeNameExternally
        // Ignore a legacy caller's value so a synchronized preference row can
        // never become an entitlement source again.
        self.isPro = false
        self.keepScreenAwake = keepScreenAwake
        self.preferredFocusMinutes = preferredFocusMinutes
        self.timerDisplayModeRawValue = TimerDisplayMode.resolved(
            timerDisplayModeRawValue
        ).rawValue
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.usagePurposeRawValue = UsagePurpose(
            rawValue: usagePurposeRawValue
        )?.rawValue ?? UsagePurpose.study.rawValue
        self.usagePurposeUpdatedAt = usagePurposeUpdatedAt
        self.hasEverImportedBedrock = hasEverImportedBedrock
        self.hasCompletedInitialSubjectSeed = hasCompletedInitialSubjectSeed
    }
}

enum PrefsSyncError: LocalizedError, Equatable {
    case revisionLimitReached
    case conflictingStampedValues
    case tooManyPhysicalRows
    case invalidFocusDuration

    var errorDescription: String? {
        switch self {
        case .revisionLimitReached:
            "設定の同期履歴が上限に達したため、変更を保存できません。サポートへお問い合わせください。"
        case .conflictingStampedValues:
            "同じ同期履歴を持つ設定内容が一致しないため、変更せず保持しました。サポートへお問い合わせください。"
        case .tooManyPhysicalRows:
            "設定の同期コピーが安全に確認できる上限を超えたため、変更せず保持しました。サポートへお問い合わせください。"
        case .invalidFocusDuration:
            "集中時間は1分から360分の範囲で指定してください。"
        }
    }
}

/// Non-destructive, field-wise convergence for CloudKit preference replicas.
/// Every device writes only its account-scoped writer row. Independent offline
/// changes therefore remain in different records. Maintenance is read-only;
/// only an explicit user mutation copies observed winners into the current
/// device's row before advancing the one changed field-group stamp.
enum PrefsSyncPolicy {
    enum Group: CaseIterable {
        case sound
        case haptics
        case timerCompletionSound
        case timerCompletionHaptic
        case rareReward
        case reminderEnabled
        case reminderTime
        case shareIncludesManual
        case externalTheme
        case keepScreenAwake
        case preferredFocusMinutes
        case timerDisplayMode
        case usagePurpose
    }

    static let maximumSupportedRevision = 1_000_000
    static let maximumPhysicalRows = 256

    struct ResolvedState: Equatable {
        let manualDayKey: String
        let manualUsedToday: Int
        let soundOn: Bool
        let hapticsOn: Bool
        let rareRewardModeRawValue: String
        let rareRewardModeUpdatedAt: Date?
        let reminderEnabled: Bool
        let reminderHour: Int
        let reminderMinute: Int
        let shareIncludesManual: Bool
        let showsThemeNameExternally: Bool
        let keepScreenAwake: Bool
        let preferredFocusMinutes: Int
        let preferredFocusSeconds: Int
        let timerDisplayMode: TimerDisplayMode
        let hasCompletedOnboarding: Bool
        let usagePurposeRawValue: String
        let usagePurposeUpdatedAt: Date?
        let hasEverImportedBedrock: Bool
        let hasCompletedInitialSubjectSeed: Bool
    }

    /// Sound and haptics are independent user choices. Resolving them apart
    /// prevents a malformed or concurrently conflicted sound stamp from also
    /// disabling an otherwise valid haptics preference (and vice versa).
    struct ResolvedSensoryState: Equatable {
        let soundOn: Bool
        let hapticsOn: Bool
        let timerCompletionSound: TimerCompletionSound
        let timerCompletionHaptic: TimerCompletionHaptic

        init(
            soundOn: Bool,
            hapticsOn: Bool,
            timerCompletionSound: TimerCompletionSound = .standard,
            timerCompletionHaptic: TimerCompletionHaptic = .standard
        ) {
            self.soundOn = soundOn
            self.hapticsOn = hapticsOn
            self.timerCompletionSound = timerCompletionSound
            self.timerCompletionHaptic = timerCompletionHaptic
        }
    }

    struct WriterRowPreparation {
        let row: Prefs
        let ownedRowCount: Int
        let physicalRowCount: Int
        let created: Bool
    }

    static func resolvedState(
        in values: [Prefs],
        currentEpochID: UUID?,
        writerID: String = FocusDeviceIdentity.current(),
        currentDay: String = FairnessPolicy.deviceDayKey(for: .now)
    ) throws -> ResolvedState {
        guard values.count <= maximumPhysicalRows else {
            throw PrefsSyncError.tooManyPhysicalRows
        }
        let sound = try winner(for: .sound, in: values)
        let haptics = try winner(for: .haptics, in: values)
        let rare = try winner(for: .rareReward, in: values)
        let reminderEnabled = try winner(for: .reminderEnabled, in: values)
        let reminderTime = try winner(for: .reminderTime, in: values)
        let share = try winner(for: .shareIncludesManual, in: values)
        let externalTheme = try winner(for: .externalTheme, in: values)
        let keepAwake = try winner(for: .keepScreenAwake, in: values)
        let focusMinutes = try winner(for: .preferredFocusMinutes, in: values)
        let timerDisplay = try winner(for: .timerDisplayMode, in: values)
        let purpose = try winner(for: .usagePurpose, in: values)
        let currentValues = values.filter {
            $0.activityEpochID == currentEpochID
        }
        let manualUsedToday = manualUsage(
            in: currentValues,
            writerID: writerID,
            currentDay: currentDay
        )
        return ResolvedState(
            manualDayKey: currentDay,
            manualUsedToday: manualUsedToday,
            soundOn: sound?.soundOn ?? true,
            hapticsOn: haptics?.hapticsOn ?? true,
            rareRewardModeRawValue: rare?.rareRewardModeRawValue
                ?? RareRewardMode.off.rawValue,
            rareRewardModeUpdatedAt: rare?.rareRewardModeUpdatedAt,
            reminderEnabled: reminderEnabled?.reminderEnabled ?? false,
            reminderHour: reminderTime?.reminderHour
                ?? Constants.Notification.defaultReminderHour,
            reminderMinute: reminderTime?.reminderMinute
                ?? Constants.Notification.defaultReminderMinute,
            shareIncludesManual: share?.shareIncludesManual ?? false,
            showsThemeNameExternally: externalTheme?.showsThemeNameExternally
                ?? false,
            keepScreenAwake: keepAwake?.keepScreenAwake ?? true,
            preferredFocusMinutes: focusMinutes?.preferredFocusMinutes
                ?? Constants.Timer.twentyFiveMinutes,
            preferredFocusSeconds: focusMinutes.map {
                attachedFocusSeconds(in: $0) ?? $0.preferredFocusMinutes * 60
            } ?? Constants.Timer.twentyFiveMinutes * 60,
            timerDisplayMode: TimerDisplayMode.resolved(
                timerDisplay?.timerDisplayModeRawValue
                    ?? TimerDisplayMode.ringAndTime.rawValue
            ),
            hasCompletedOnboarding: values.contains(
                where: \.hasCompletedOnboarding
            ),
            usagePurposeRawValue: purpose?.usagePurposeRawValue
                ?? UsagePurpose.study.rawValue,
            usagePurposeUpdatedAt: purpose?.usagePurposeUpdatedAt,
            hasEverImportedBedrock: values.contains(
                where: \.hasEverImportedBedrock
            ),
            hasCompletedInitialSubjectSeed: values.contains(
                where: \.hasCompletedInitialSubjectSeed
            )
        )
    }

    static func resolvedSensoryState(in values: [Prefs]) -> ResolvedSensoryState {
        guard values.count <= maximumPhysicalRows else {
            return ResolvedSensoryState(soundOn: false, hapticsOn: false)
        }
        return ResolvedSensoryState(
            soundOn: resolvedSensoryValue(
                group: .sound,
                defaultValue: true,
                in: values
            ) { $0.soundOn },
            hapticsOn: resolvedSensoryValue(
                group: .haptics,
                defaultValue: true,
                in: values
            ) { $0.hapticsOn },
            timerCompletionSound: resolvedSensoryChoice(
                group: .timerCompletionSound,
                defaultValue: .standard,
                in: values
            ) { TimerCompletionSound.resolved($0.timerCompletionSoundRawValue) },
            timerCompletionHaptic: resolvedSensoryChoice(
                group: .timerCompletionHaptic,
                defaultValue: .standard,
                in: values
            ) { TimerCompletionHaptic.resolved($0.timerCompletionHapticRawValue) }
        )
    }

    /// Validates every independently stamped preference group without
    /// coupling presentation fallbacks together. Background maintenance uses
    /// this to detect an exact-stamp conflict even in groups that are consumed
    /// through a fail-soft resolver, such as timer completion sound/haptics.
    static func validateReplicaSet(in values: [Prefs]) throws {
        guard values.count <= maximumPhysicalRows else {
            throw PrefsSyncError.tooManyPhysicalRows
        }
        for group in Group.allCases {
            _ = try winner(for: group, in: values)
        }
    }

    private static func resolvedSensoryChoice<Value>(
        group: Group,
        defaultValue: Value,
        in values: [Prefs],
        value: (Prefs) -> Value
    ) -> Value {
        do {
            return try winner(for: group, in: values).map(value) ?? defaultValue
        } catch {
            return defaultValue
        }
    }

    private static func resolvedSensoryValue(
        group: Group,
        defaultValue: Bool,
        in values: [Prefs],
        value: (Prefs) -> Bool
    ) -> Bool {
        guard values.isEmpty || values.contains(where: {
            validStamp(for: group, in: $0) != nil
        }) else {
            // An empty store is a clean first launch and uses the product
            // default. Existing rows with no valid stamp are corrupt evidence.
            return false
        }
        do {
            return try winner(for: group, in: values).map(value) ?? defaultValue
        } catch {
            // Fail closed for only the corrupt field group. The sibling output
            // remains usable and retains its independently resolved choice.
            return false
        }
    }

    static func fetchBounded(from context: ModelContext) throws -> [Prefs] {
        var descriptor = FetchDescriptor<Prefs>(sortBy: [
            SortDescriptor(\Prefs.syncRecordID)
        ])
        descriptor.fetchLimit = maximumPhysicalRows + 1
        let values = try context.fetch(descriptor)
        guard values.count <= maximumPhysicalRows else {
            throw PrefsSyncError.tooManyPhysicalRows
        }
        return values
    }

    /// An exact lookup prevents a bounded presentation query from overlooking
    /// the device-owned row and creating another writer. The global evidence
    /// cap is still checked separately before any row is inserted or changed.
    static func fetchOwnedWriterRows(
        from context: ModelContext,
        writerID: String = FocusDeviceIdentity.current(),
        currentEpochID: UUID?
    ) throws -> [Prefs] {
        let predicate: Predicate<Prefs>
        if let currentEpochID {
            predicate = #Predicate {
                $0.settingsWriterID == writerID
                    && $0.activityEpochID == currentEpochID
            }
        } else {
            predicate = #Predicate {
                $0.settingsWriterID == writerID
                    && $0.activityEpochID == nil
            }
        }
        var descriptor = FetchDescriptor<Prefs>(
            predicate: predicate,
            sortBy: [SortDescriptor(\Prefs.syncRecordID)]
        )
        descriptor.fetchLimit = maximumPhysicalRows + 1
        let values = try context.fetch(descriptor)
        guard values.count <= maximumPhysicalRows else {
            throw PrefsSyncError.tooManyPhysicalRows
        }
        return values
    }

    /// Creates the device-owned row without copying any foreign value. This is
    /// appropriate for bounded launch preparation; field anti-entropy is
    /// reserved for the serialized explicit-mutation path below.
    @discardableResult
    static func ensureWriterRow(
        context: ModelContext,
        writerID: String = FocusDeviceIdentity.current(),
        currentEpochID: UUID?,
        canonicalID: UUID = SyncMaintenanceCanonicalIDs.preferences
    ) throws -> Prefs {
        try prepareWriterRowForLaunch(
            context: context,
            writerID: writerID,
            currentEpochID: currentEpochID,
            canonicalID: canonicalID
        ).row
    }

    static func prepareWriterRowForLaunch(
        context: ModelContext,
        writerID: String = FocusDeviceIdentity.current(),
        currentEpochID: UUID?,
        canonicalID: UUID = SyncMaintenanceCanonicalIDs.preferences
    ) throws -> WriterRowPreparation {
        let owned = try fetchOwnedWriterRows(
            from: context,
            writerID: writerID,
            currentEpochID: currentEpochID
        )
        let available = try fetchBounded(from: context)
        if let existing = owned.min(by: {
            $0.syncRecordID.uuidString < $1.syncRecordID.uuidString
        }) {
            return WriterRowPreparation(
                row: existing,
                ownedRowCount: owned.count,
                physicalRowCount: available.count,
                created: false
            )
        }
        guard available.count < maximumPhysicalRows else {
            throw PrefsSyncError.tooManyPhysicalRows
        }
        let writer = Prefs(
            id: canonicalID,
            activityEpochID: currentEpochID,
            settingsWriterID: writerID
        )
        context.insert(writer)
        return WriterRowPreparation(
            row: writer,
            ownedRowCount: owned.count,
            physicalRowCount: available.count,
            created: true
        )
    }

    static func presentationRow(
        in values: [Prefs],
        writerID: String = FocusDeviceIdentity.current()
    ) -> Prefs? {
        let owned = values.filter { $0.settingsWriterID == writerID }
        return (owned.isEmpty ? values : owned).min {
            $0.syncRecordID.uuidString < $1.syncRecordID.uuidString
        }
    }

    /// Creates at most one row owned by this device, then applies every
    /// observed field winner and monotone lifecycle value to only that row.
    /// Foreign rows are immutable inputs to this operation.
    static func prepareWriterRow(
        from availableValues: [Prefs],
        context: ModelContext,
        writerID: String,
        currentEpochID: UUID?,
        currentDay: String,
        canonicalID: UUID
    ) throws -> Prefs {
        guard availableValues.count <= maximumPhysicalRows else {
            throw PrefsSyncError.tooManyPhysicalRows
        }
        // Resolve every group before inserting or changing the writer. A
        // corrupt exact-stamp conflict in a later group must not leave a
        // partially copied in-memory row when callers inspect the thrown path.
        let resolvedWinners = try Group.allCases.map { group in
            (group, try winner(for: group, in: availableValues))
        }
        var currentValues = availableValues.filter {
            $0.activityEpochID == currentEpochID
        }
        let writer: Prefs
        if let existing = currentValues
            .filter({ $0.settingsWriterID == writerID })
            .min(by: {
                $0.syncRecordID.uuidString < $1.syncRecordID.uuidString
            }) {
            writer = existing
        } else {
            guard availableValues.count < maximumPhysicalRows else {
                throw PrefsSyncError.tooManyPhysicalRows
            }
            writer = Prefs(
                id: canonicalID,
                activityEpochID: currentEpochID,
                settingsWriterID: writerID
            )
            context.insert(writer)
            currentValues.append(writer)
        }

        if writer.id != canonicalID { writer.id = canonicalID }
        if writer.activityEpochID != currentEpochID {
            writer.activityEpochID = currentEpochID
        }
        if writer.settingsWriterID != writerID {
            writer.settingsWriterID = writerID
        }

        for (group, winner) in resolvedWinners {
            guard let winner else {
                continue
            }
            copy(group: group, from: winner, to: writer)
        }

        let todayMaximum = manualUsage(
            in: currentValues,
            writerID: writerID,
            currentDay: currentDay
        )
        if writer.manualDayKey != currentDay { writer.manualDayKey = currentDay }
        if writer.manualUsedToday != todayMaximum {
            writer.manualUsedToday = todayMaximum
        }
        let completedOnboarding = availableValues.contains(
            where: \.hasCompletedOnboarding
        )
        if writer.hasCompletedOnboarding != completedOnboarding {
            writer.hasCompletedOnboarding = completedOnboarding
        }
        let importedBedrock = availableValues.contains(
            where: \.hasEverImportedBedrock
        )
        if writer.hasEverImportedBedrock != importedBedrock {
            writer.hasEverImportedBedrock = importedBedrock
        }
        let completedSeed = availableValues.contains(
            where: \.hasCompletedInitialSubjectSeed
        )
        if writer.hasCompletedInitialSubjectSeed != completedSeed {
            writer.hasCompletedInitialSubjectSeed = completedSeed
        }
        if writer.isPro { writer.isPro = false }
        return writer
    }

    /// The manual allowance belongs to this device, unlike synchronized
    /// settings. Keep the maximum only among physical copies of its writer.
    /// Legacy rows without a writer retain their raw counters, but cannot be
    /// attributed to this device after import; the first owned row starts a
    /// fresh allowance instead of inheriting an unknown device's usage.
    private static func manualUsage(
        in currentEpochValues: [Prefs],
        writerID: String,
        currentDay: String
    ) -> Int {
        guard !writerID.isEmpty else { return 0 }
        return max(0, currentEpochValues.lazy
            .filter { $0.settingsWriterID == writerID && $0.manualDayKey == currentDay }
            .map(\.manualUsedToday)
            .max() ?? 0)
    }

    /// Applies one explicit mutation to the device-owned row. The closure runs
    /// only after the next revision has been proven representable.
    @discardableResult
    static func mutate(
        _ group: Group,
        in availableValues: [Prefs],
        context: ModelContext,
        writerID: String = FocusDeviceIdentity.current(),
        currentEpochID: UUID?,
        currentDay: String = FairnessPolicy.deviceDayKey(for: .now),
        canonicalID: UUID = SyncMaintenanceCanonicalIDs.preferences,
        mutationID: UUID = UUID(),
        update: (Prefs) -> Void
    ) throws -> Prefs {
        let observedMaximum = availableValues.compactMap { value in
            validStamp(for: group, in: value)?.revision
        }.max() ?? 0
        guard observedMaximum < maximumSupportedRevision else {
            throw PrefsSyncError.revisionLimitReached
        }
        let writer = try prepareWriterRow(
            from: availableValues,
            context: context,
            writerID: writerID,
            currentEpochID: currentEpochID,
            currentDay: currentDay,
            canonicalID: canonicalID
        )
        update(writer)
        setStamp(
            group,
            revision: observedMaximum + 1,
            mutationID: mutationID,
            on: writer
        )
        return writer
    }

    @discardableResult
    static func mutate(
        _ group: Group,
        context: ModelContext,
        writerID: String = FocusDeviceIdentity.current(),
        currentEpochID: UUID?,
        currentDay: String = FairnessPolicy.deviceDayKey(for: .now),
        canonicalID: UUID = SyncMaintenanceCanonicalIDs.preferences,
        mutationID: UUID = UUID(),
        update: (Prefs) -> Void
    ) throws -> Prefs {
        // Always perform the exact lookup even though the global cap is also
        // fetched. This is part of the no-duplicate-writer contract and keeps
        // it visible in query-level regression tests.
        _ = try fetchOwnedWriterRows(
            from: context,
            writerID: writerID,
            currentEpochID: currentEpochID
        )
        return try mutate(
            group,
            in: fetchBounded(from: context),
            context: context,
            writerID: writerID,
            currentEpochID: currentEpochID,
            currentDay: currentDay,
            canonicalID: canonicalID,
            mutationID: mutationID,
            update: update
        )
    }

    /// Uses the existing preference stamp, preserving ordering with clients
    /// that only understand minutes. The caller saves (or rolls back) together
    /// with its other UI changes; this helper never changes another writer.
    @discardableResult
    static func setPreferredFocusSeconds(
        _ totalSeconds: Int,
        context: ModelContext,
        writerID: String = FocusDeviceIdentity.current(),
        currentEpochID: UUID?,
        currentDay: String = FairnessPolicy.deviceDayKey(for: .now),
        canonicalID: UUID = SyncMaintenanceCanonicalIDs.preferences,
        mutationID: UUID = UUID()
    ) throws -> Prefs {
        guard (Constants.Timer.customMinimumMinutes * 60
               ... Constants.Timer.customMaximumMinutes * 60).contains(totalSeconds) else {
            throw PrefsSyncError.invalidFocusDuration
        }
        return try mutate(
            .preferredFocusMinutes,
            context: context,
            writerID: writerID,
            currentEpochID: currentEpochID,
            currentDay: currentDay,
            canonicalID: canonicalID,
            mutationID: mutationID
        ) { value in
            value.preferredFocusMinutes = totalSeconds / 60
            value.preferredFocusSeconds = totalSeconds
            value.preferredFocusSecondsMutationID = mutationID
        }
    }

    /// Invalid or unattached optional values remain raw exportable evidence,
    /// but never override the valid legacy minutes choice.
    private static func attachedFocusSeconds(in value: Prefs) -> Int? {
        guard let seconds = value.preferredFocusSeconds,
              (Constants.Timer.customMinimumMinutes * 60
               ... Constants.Timer.customMaximumMinutes * 60).contains(seconds),
              seconds / 60 == value.preferredFocusMinutes,
              let anchor = value.preferredFocusSecondsMutationID,
              anchor == value.preferredFocusMinutesMutationID,
              (1...maximumSupportedRevision).contains(value.preferredFocusMinutesRevision)
        else { return nil }
        return seconds
    }

    static func winner(for group: Group, in values: [Prefs]) throws -> Prefs? {
        let candidates = values.filter { validStamp(for: group, in: $0) != nil }
        let versioned = candidates.filter {
            (validStamp(for: group, in: $0)?.revision ?? 0) > 0
        }
        let byExactStamp = Dictionary(grouping: versioned) { value in
            let stamp = rawStamp(for: group, in: value)
            return "\(stamp.revision)|\(stamp.mutationID?.uuidString ?? "missing")"
        }
        guard byExactStamp.values.allSatisfy({ copies in
            guard let first = copies.first else { return true }
            if group == .preferredFocusMinutes,
               Set(copies.compactMap { attachedFocusSeconds(in: $0) }).count > 1 {
                return false
            }
            return copies.dropFirst().allSatisfy {
                groupValueEquals(group, first, $0)
            }
        }) else {
            throw PrefsSyncError.conflictingStampedValues
        }
        return candidates.max {
            lhs, rhs in
            guard let left = validStamp(for: group, in: lhs),
                  let right = validStamp(for: group, in: rhs) else {
                return validStamp(for: group, in: lhs) == nil
            }
            if left.revision != right.revision {
                return left.revision < right.revision
            }
            if left.revision == 0 {
                switch group {
                case .rareReward:
                    let leftDate = lhs.rareRewardModeUpdatedAt ?? .distantPast
                    let rightDate = rhs.rareRewardModeUpdatedAt ?? .distantPast
                    if leftDate != rightDate { return leftDate < rightDate }
                case .usagePurpose:
                    let leftDate = lhs.usagePurposeUpdatedAt ?? .distantPast
                    let rightDate = rhs.usagePurposeUpdatedAt ?? .distantPast
                    if leftDate != rightDate { return leftDate < rightDate }
                default:
                    break
                }
            }
            let leftSafety = safetyRank(group, value: lhs)
            let rightSafety = safetyRank(group, value: rhs)
            if leftSafety != rightSafety { return leftSafety < rightSafety }
            if left.mutationID != right.mutationID {
                return (left.mutationID?.uuidString ?? "")
                    < (right.mutationID?.uuidString ?? "")
            }
            if group == .preferredFocusMinutes {
                // An old client can copy a new client's minutes and stamp
                // without knowing the additive fields. Keep the precision
                // supplied by another copy of that exact same mutation.
                let leftHasSeconds = attachedFocusSeconds(in: lhs) != nil
                let rightHasSeconds = attachedFocusSeconds(in: rhs) != nil
                if leftHasSeconds != rightHasSeconds { return !leftHasSeconds }
            }
            return lhs.syncRecordID.uuidString < rhs.syncRecordID.uuidString
        }
    }

    private struct Stamp: Equatable {
        let revision: Int
        let mutationID: UUID?
    }

    private static func validStamp(
        for group: Group,
        in value: Prefs
    ) -> Stamp? {
        guard hasValidValue(for: group, in: value) else { return nil }
        let stamp = rawStamp(for: group, in: value)
        if stamp.revision == 0, stamp.mutationID == nil { return stamp }
        guard (1...maximumSupportedRevision).contains(stamp.revision),
              stamp.mutationID != nil else { return nil }
        return stamp
    }

    private static func hasValidValue(
        for group: Group,
        in value: Prefs
    ) -> Bool {
        switch group {
        case .sound, .haptics, .reminderEnabled, .shareIncludesManual,
             .externalTheme, .keepScreenAwake:
            return true
        case .timerCompletionSound:
            return TimerCompletionSound(
                rawValue: value.timerCompletionSoundRawValue
            ) != nil
        case .timerCompletionHaptic:
            return TimerCompletionHaptic(
                rawValue: value.timerCompletionHapticRawValue
            ) != nil
        case .rareReward:
            return RareRewardMode(rawValue: value.rareRewardModeRawValue) != nil
        case .reminderTime:
            return (0...23).contains(value.reminderHour)
                && (0...59).contains(value.reminderMinute)
        case .preferredFocusMinutes:
            return (Constants.Timer.customMinimumMinutes
                    ... Constants.Timer.customMaximumMinutes)
                .contains(value.preferredFocusMinutes)
        case .timerDisplayMode:
            return TimerDisplayMode(rawValue: value.timerDisplayModeRawValue) != nil
        case .usagePurpose:
            return UsagePurpose(rawValue: value.usagePurposeRawValue) != nil
        }
    }

    private static func rawStamp(for group: Group, in value: Prefs) -> Stamp {
        switch group {
        case .sound: Stamp(revision: value.soundRevision, mutationID: value.soundMutationID)
        case .haptics: Stamp(revision: value.hapticsRevision, mutationID: value.hapticsMutationID)
        case .timerCompletionSound: Stamp(revision: value.timerCompletionSoundRevision, mutationID: value.timerCompletionSoundMutationID)
        case .timerCompletionHaptic: Stamp(revision: value.timerCompletionHapticRevision, mutationID: value.timerCompletionHapticMutationID)
        case .rareReward: Stamp(revision: value.rareRewardRevision, mutationID: value.rareRewardMutationID)
        case .reminderEnabled: Stamp(revision: value.reminderEnabledRevision, mutationID: value.reminderEnabledMutationID)
        case .reminderTime: Stamp(revision: value.reminderTimeRevision, mutationID: value.reminderTimeMutationID)
        case .shareIncludesManual: Stamp(revision: value.shareIncludesManualRevision, mutationID: value.shareIncludesManualMutationID)
        case .externalTheme: Stamp(revision: value.externalThemeRevision, mutationID: value.externalThemeMutationID)
        case .keepScreenAwake: Stamp(revision: value.keepScreenAwakeRevision, mutationID: value.keepScreenAwakeMutationID)
        case .preferredFocusMinutes: Stamp(revision: value.preferredFocusMinutesRevision, mutationID: value.preferredFocusMinutesMutationID)
        case .timerDisplayMode: Stamp(revision: value.timerDisplayModeRevision, mutationID: value.timerDisplayModeMutationID)
        case .usagePurpose: Stamp(revision: value.usagePurposeRevision, mutationID: value.usagePurposeMutationID)
        }
    }

    private static func setStamp(
        _ group: Group,
        revision: Int,
        mutationID: UUID?,
        on value: Prefs
    ) {
        switch group {
        case .sound:
            value.soundRevision = revision; value.soundMutationID = mutationID
        case .haptics:
            value.hapticsRevision = revision; value.hapticsMutationID = mutationID
        case .timerCompletionSound:
            value.timerCompletionSoundRevision = revision
            value.timerCompletionSoundMutationID = mutationID
        case .timerCompletionHaptic:
            value.timerCompletionHapticRevision = revision
            value.timerCompletionHapticMutationID = mutationID
        case .rareReward:
            value.rareRewardRevision = revision; value.rareRewardMutationID = mutationID
        case .reminderEnabled:
            value.reminderEnabledRevision = revision; value.reminderEnabledMutationID = mutationID
        case .reminderTime:
            value.reminderTimeRevision = revision; value.reminderTimeMutationID = mutationID
        case .shareIncludesManual:
            value.shareIncludesManualRevision = revision; value.shareIncludesManualMutationID = mutationID
        case .externalTheme:
            value.externalThemeRevision = revision; value.externalThemeMutationID = mutationID
        case .keepScreenAwake:
            value.keepScreenAwakeRevision = revision; value.keepScreenAwakeMutationID = mutationID
        case .preferredFocusMinutes:
            value.preferredFocusMinutesRevision = revision; value.preferredFocusMinutesMutationID = mutationID
        case .timerDisplayMode:
            value.timerDisplayModeRevision = revision; value.timerDisplayModeMutationID = mutationID
        case .usagePurpose:
            value.usagePurposeRevision = revision; value.usagePurposeMutationID = mutationID
        }
    }

    private static func copy(group: Group, from source: Prefs, to target: Prefs) {
        switch group {
        case .sound:
            if target.soundOn != source.soundOn { target.soundOn = source.soundOn }
        case .haptics:
            if target.hapticsOn != source.hapticsOn { target.hapticsOn = source.hapticsOn }
        case .timerCompletionSound:
            if target.timerCompletionSoundRawValue != source.timerCompletionSoundRawValue {
                target.timerCompletionSoundRawValue = source.timerCompletionSoundRawValue
            }
        case .timerCompletionHaptic:
            if target.timerCompletionHapticRawValue != source.timerCompletionHapticRawValue {
                target.timerCompletionHapticRawValue = source.timerCompletionHapticRawValue
            }
        case .rareReward:
            if target.rareRewardModeRawValue != source.rareRewardModeRawValue {
                target.rareRewardModeRawValue = source.rareRewardModeRawValue
            }
            if target.rareRewardModeUpdatedAt != source.rareRewardModeUpdatedAt {
                target.rareRewardModeUpdatedAt = source.rareRewardModeUpdatedAt
            }
        case .reminderEnabled:
            if target.reminderEnabled != source.reminderEnabled {
                target.reminderEnabled = source.reminderEnabled
            }
        case .reminderTime:
            if target.reminderHour != source.reminderHour {
                target.reminderHour = source.reminderHour
            }
            if target.reminderMinute != source.reminderMinute {
                target.reminderMinute = source.reminderMinute
            }
        case .shareIncludesManual:
            if target.shareIncludesManual != source.shareIncludesManual {
                target.shareIncludesManual = source.shareIncludesManual
            }
        case .externalTheme:
            if target.showsThemeNameExternally != source.showsThemeNameExternally {
                target.showsThemeNameExternally = source.showsThemeNameExternally
            }
        case .keepScreenAwake:
            if target.keepScreenAwake != source.keepScreenAwake {
                target.keepScreenAwake = source.keepScreenAwake
            }
        case .preferredFocusMinutes:
            if target.preferredFocusMinutes != source.preferredFocusMinutes {
                target.preferredFocusMinutes = source.preferredFocusMinutes
            }
            if target.preferredFocusSeconds != source.preferredFocusSeconds {
                target.preferredFocusSeconds = source.preferredFocusSeconds
            }
            if target.preferredFocusSecondsMutationID != source.preferredFocusSecondsMutationID {
                target.preferredFocusSecondsMutationID = source.preferredFocusSecondsMutationID
            }
        case .timerDisplayMode:
            if target.timerDisplayModeRawValue != source.timerDisplayModeRawValue {
                target.timerDisplayModeRawValue = source.timerDisplayModeRawValue
            }
        case .usagePurpose:
            if target.usagePurposeRawValue != source.usagePurposeRawValue {
                target.usagePurposeRawValue = source.usagePurposeRawValue
            }
            if target.usagePurposeUpdatedAt != source.usagePurposeUpdatedAt {
                target.usagePurposeUpdatedAt = source.usagePurposeUpdatedAt
            }
        }
        let stamp = rawStamp(for: group, in: source)
        let targetStamp = rawStamp(for: group, in: target)
        if targetStamp != stamp {
            setStamp(
                group,
                revision: stamp.revision,
                mutationID: stamp.mutationID,
                on: target
            )
        }
    }

    private static func groupValueEquals(
        _ group: Group,
        _ lhs: Prefs,
        _ rhs: Prefs
    ) -> Bool {
        switch group {
        case .sound:
            lhs.soundOn == rhs.soundOn
        case .haptics:
            lhs.hapticsOn == rhs.hapticsOn
        case .timerCompletionSound:
            lhs.timerCompletionSoundRawValue == rhs.timerCompletionSoundRawValue
        case .timerCompletionHaptic:
            lhs.timerCompletionHapticRawValue == rhs.timerCompletionHapticRawValue
        case .rareReward:
            lhs.rareRewardModeRawValue == rhs.rareRewardModeRawValue
                && lhs.rareRewardModeUpdatedAt == rhs.rareRewardModeUpdatedAt
        case .reminderEnabled:
            lhs.reminderEnabled == rhs.reminderEnabled
        case .reminderTime:
            lhs.reminderHour == rhs.reminderHour
                && lhs.reminderMinute == rhs.reminderMinute
        case .shareIncludesManual:
            lhs.shareIncludesManual == rhs.shareIncludesManual
        case .externalTheme:
            lhs.showsThemeNameExternally == rhs.showsThemeNameExternally
        case .keepScreenAwake:
            lhs.keepScreenAwake == rhs.keepScreenAwake
        case .preferredFocusMinutes:
            lhs.preferredFocusMinutes == rhs.preferredFocusMinutes
        case .timerDisplayMode:
            lhs.timerDisplayModeRawValue == rhs.timerDisplayModeRawValue
        case .usagePurpose:
            lhs.usagePurposeRawValue == rhs.usagePurposeRawValue
                && lhs.usagePurposeUpdatedAt == rhs.usagePurposeUpdatedAt
        }
    }

    /// Higher ranks are conservative for same-base concurrent mutations.
    private static func safetyRank(_ group: Group, value: Prefs) -> Int {
        switch group {
        case .sound: value.soundOn ? 0 : 1
        case .haptics: value.hapticsOn ? 0 : 1
        case .rareReward:
            RareRewardMode.resolved(value.rareRewardModeRawValue).autonomyRank
        case .reminderEnabled: value.reminderEnabled ? 0 : 1
        case .reminderTime: 0
        case .shareIncludesManual: value.shareIncludesManual ? 0 : 1
        case .externalTheme: value.showsThemeNameExternally ? 0 : 1
        case .keepScreenAwake: value.keepScreenAwake ? 0 : 1
        case .timerCompletionSound, .timerCompletionHaptic,
             .preferredFocusMinutes, .timerDisplayMode, .usagePurpose:
            0
        }
    }
}
