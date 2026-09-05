import Foundation

/// User-controlled relationship with the optional random visual reward.
///
/// Deterministic mass, decimal fusion, achievements, and every app feature are
/// identical in all modes. `off` is intentionally stronger than a cosmetic
/// mute: it performs no draw and leaves guarantee progress untouched, so there
/// is no hidden result waiting to be revealed later.
enum RareRewardMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard
    case quiet
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "標準"
        case .quiet: "控えめ"
        case .off: "抽選しない"
        }
    }

    var settingsDescription: String {
        switch self {
        case .standard:
            "種類の色・光と専用の音・触覚を使います"
        case .quiet:
            "種類は残し、追加の発光・専用音・専用触覚を使いません"
        case .off:
            "今後は通常の粒だけを積み、抽選の端数と金の保証は現在の位置で停止します"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: "sparkles"
        case .quiet: "moon.stars"
        case .off: "circle.slash"
        }
    }

    var performsRandomDraw: Bool { self != .off }
    var usesEnhancedPresentation: Bool { self == .standard }

    /// The order used whenever people are asked to make an explicit choice.
    /// It starts with no draw and gives every option the same visual weight;
    /// `allCases` remains source-compatible with older call sites.
    static let choiceOrder: [Self] = [.off, .quiet, .standard]

    /// When two undated legacy duplicates disagree, prefer the mode that gives
    /// the person more control. A real user change always carries a timestamp.
    var autonomyRank: Int {
        switch self {
        case .standard: 0
        case .quiet: 1
        case .off: 2
        }
    }

    static func resolved(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .off
    }

    /// Resolves transient CloudKit duplicates without trusting fetch order.
    /// Newer explicit choices win; an exact/legacy tie chooses the more
    /// autonomy-preserving mode, then a stable UUID tie-breaker.
    static func preferredPreferenceSource(in values: [Prefs]) -> Prefs? {
        values
            .filter { Self(rawValue: $0.rareRewardModeRawValue) != nil }
            .max(by: { lhs, rhs in
                let leftDate = lhs.rareRewardModeUpdatedAt ?? .distantPast
                let rightDate = rhs.rareRewardModeUpdatedAt ?? .distantPast
                if leftDate != rightDate { return leftDate < rightDate }
                let leftMode = resolved(lhs.rareRewardModeRawValue)
                let rightMode = resolved(rhs.rareRewardModeRawValue)
                if leftMode.autonomyRank != rightMode.autonomyRank {
                    return leftMode.autonomyRank < rightMode.autonomyRank
                }
                return lhs.syncRecordID.uuidString < rhs.syncRecordID.uuidString
            })
    }

    static func resolved(preferences: [Prefs]) -> Self {
        selectedMode(preferences: preferences) ?? .off
    }

    /// A stored raw value without an update date is a legacy/default value,
    /// not evidence that a person understood and selected random rewards.
    /// Treat it as no draw until they choose in onboarding, the pre-focus
    /// gate, or Settings. Explicit choices synchronize through CloudKit.
    static func selectedMode(preferences: [Prefs]) -> Self? {
        guard let source = preferredPreferenceSource(in: preferences),
              source.rareRewardModeUpdatedAt != nil
        else { return nil }
        return Self(rawValue: source.rareRewardModeRawValue)
    }

    static func hasExplicitSelection(preferences: [Prefs]) -> Bool {
        selectedMode(preferences: preferences) != nil
    }
}

struct GachaRoll: Equatable, Sendable {
    let kind: PebbleKind
    /// True when this measured completion was accepted into the mass ledger,
    /// including a sub-credit contribution that did not draw yet.
    let participated: Bool
    let wasEligible: Bool
    let triggeredPity: Bool
    let sinceLastGold: Int
    /// Number of 250g reward credits consumed by this persisted completion.
    let consumedCreditCount: Int
    /// Mass retained toward the next credit after this completion.
    let creditRemainderGrams: Int
    let acceptedContributionGrams: Int
    /// Every consumed credit remains durable even though one StudySession has
    /// only one representative physical pebble.
    let creditOutcomes: [PebbleKind]

    init(
        kind: PebbleKind,
        participated: Bool = false,
        wasEligible: Bool,
        triggeredPity: Bool,
        sinceLastGold: Int,
        consumedCreditCount: Int = 0,
        creditRemainderGrams: Int = 0,
        acceptedContributionGrams: Int = 0,
        creditOutcomes: [PebbleKind] = []
    ) {
        self.kind = kind
        self.participated = participated
        self.wasEligible = wasEligible
        self.triggeredPity = triggeredPity
        self.sinceLastGold = max(0, sinceLastGold)
        self.consumedCreditCount = max(0, consumedCreditCount)
        self.creditRemainderGrams = max(0, creditRemainderGrams)
        self.acceptedContributionGrams = max(0, acceptedContributionGrams)
        self.creditOutcomes = creditOutcomes
    }
}

enum RareRewardOutcomeCodec {
    static func encode(_ outcomes: [PebbleKind]) -> String {
        outcomes.map(\.rawValue).joined(separator: ",")
    }

    /// Nil means a pre-credit-rule row. An empty string is a valid versioned
    /// completion which consumed no credit.
    static func decode(_ rawValue: String?) -> [PebbleKind]? {
        guard let rawValue else { return nil }
        guard !rawValue.isEmpty else { return [] }
        let values = rawValue.split(separator: ",", omittingEmptySubsequences: false)
        guard values.count <= RareRewardCreditPolicy.maximumCreditsPerCompletion else {
            return nil
        }
        let outcomes = values.compactMap { PebbleKind(rawValue: String($0)) }
        guard outcomes.count == values.count else { return nil }
        return outcomes
    }
}

struct RareRewardCreditAllocation: Equatable, Sendable {
    let previousTotalGrams: Int
    let acceptedContributionGrams: Int
    let totalGrams: Int
    let earnedCreditCount: Int
    let remainderGrams: Int
}

enum RareRewardCreditPolicy {
    static let maximumCreditsPerCompletion =
        (Constants.Gacha.maximumCreditableGramsPerCompletion
            + Constants.Gacha.creditGrams - 1)
        / Constants.Gacha.creditGrams

    static func isPossibleOutcomeCount(
        _ outcomeCount: Int,
        forContributionGrams rawContributionGrams: Int
    ) -> Bool {
        let contributionGrams = min(
            max(0, rawContributionGrams),
            Constants.Gacha.maximumCreditableGramsPerCompletion
        )
        let minimum = contributionGrams / Constants.Gacha.creditGrams
        let maximum = (contributionGrams + Constants.Gacha.creditGrams - 1)
            / Constants.Gacha.creditGrams
        return (minimum ... maximum).contains(outcomeCount)
    }

    /// Advances the monotonic reward-mass ledger without multiplying or adding
    /// untrusted values before they have been bounded. Manual and demoted
    /// sessions contribute no mass. Product timers are capped at the same
    /// maximum accepted by `PomodoroDuration`, limiting one RNG batch to eight.
    static func allocation(
        previousTotalGrams rawPreviousTotalGrams: Int,
        completedGrams rawCompletedGrams: Int,
        source: SessionSource
    ) -> RareRewardCreditAllocation {
        let previousTotalGrams = max(0, rawPreviousTotalGrams)
        guard source == .timer else {
            return RareRewardCreditAllocation(
                previousTotalGrams: previousTotalGrams,
                acceptedContributionGrams: 0,
                totalGrams: previousTotalGrams,
                earnedCreditCount: 0,
                remainderGrams: previousTotalGrams % Constants.Gacha.creditGrams
            )
        }

        let boundedContribution = min(
            max(0, rawCompletedGrams),
            Constants.Gacha.maximumCreditableGramsPerCompletion
        )
        let acceptedContribution = min(
            boundedContribution,
            Int.max - previousTotalGrams
        )
        let totalGrams = previousTotalGrams + acceptedContribution
        let earnedCreditCount = totalGrams / Constants.Gacha.creditGrams
            - previousTotalGrams / Constants.Gacha.creditGrams
        return RareRewardCreditAllocation(
            previousTotalGrams: previousTotalGrams,
            acceptedContributionGrams: acceptedContribution,
            totalGrams: totalGrams,
            earnedCreditCount: earnedCreditCount,
            remainderGrams: totalGrams % Constants.Gacha.creditGrams
        )
    }
}

enum RareRewardPolicy {
    /// Applies the explicit opt-out before asking the random generator for a
    /// value or advancing the mass ledger. Thus disabled-time effort never
    /// becomes a hidden batch waiting to be revealed after re-enabling.
    static func draw<R: RandomNumberGenerator>(
        source: SessionSource,
        completedSeconds: Int,
        completedGrams: Int,
        mode: RareRewardMode,
        state: GachaState,
        using generator: inout R
    ) -> GachaRoll {
        guard mode.performsRandomDraw else {
            return GachaRoll(
                kind: .normal,
                wasEligible: false,
                triggeredPity: false,
                sinceLastGold: state.sinceLastGold,
                creditRemainderGrams: state.rewardCreditRemainderGrams
            )
        }

        let participates = source == .timer
            && completedSeconds >= Constants.Gacha.minimumMeasuredSeconds
        let allocation = RareRewardCreditPolicy.allocation(
            previousTotalGrams: state.rewardCreditGrams,
            completedGrams: completedGrams,
            source: participates ? .timer : .timerDemoted,
        )
        state.rewardCreditGrams = allocation.totalGrams
        guard allocation.earnedCreditCount > 0 else {
            return GachaRoll(
                kind: .normal,
                participated: participates,
                wasEligible: false,
                triggeredPity: false,
                sinceLastGold: state.sinceLastGold,
                creditRemainderGrams: allocation.remainderGrams,
                acceptedContributionGrams: allocation.acceptedContributionGrams
            )
        }

        var awardedKind = PebbleKind.normal
        var triggeredPity = false
        var outcomes: [PebbleKind] = []
        outcomes.reserveCapacity(allocation.earnedCreditCount)
        for _ in 0 ..< allocation.earnedCreditCount {
            let creditRoll = GachaEngine.drawCredit(
                sinceLastGold: state.sinceLastGold,
                using: &generator
            )
            state.sinceLastGold = creditRoll.sinceLastGold
            awardedKind = representativeKind(
                combining: awardedKind,
                with: creditRoll.kind
            )
            triggeredPity = triggeredPity || creditRoll.triggeredPity
            outcomes.append(creditRoll.kind)
        }
        return GachaRoll(
            kind: awardedKind,
            participated: participates,
            wasEligible: true,
            triggeredPity: triggeredPity,
            sinceLastGold: state.sinceLastGold,
            consumedCreditCount: allocation.earnedCreditCount,
            creditRemainderGrams: allocation.remainderGrams,
            acceptedContributionGrams: allocation.acceptedContributionGrams,
            creditOutcomes: outcomes
        )
    }

    /// Source-compatible bridge for callers that only have a duration. New
    /// persistence code passes the already-canonical completion mass directly.
    static func draw<R: RandomNumberGenerator>(
        source: SessionSource,
        completedSeconds: Int,
        mode: RareRewardMode,
        state: GachaState,
        using generator: inout R
    ) -> GachaRoll {
        draw(
            source: source,
            completedSeconds: completedSeconds,
            completedGrams: StudySession.grams(for: completedSeconds),
            mode: mode,
            state: state,
            using: &generator
        )
    }

    /// A completion can persist only one pebble kind even when its mass earns
    /// several credits. Gold takes precedence so a guaranteed-gold credit is
    /// never visually hidden; otherwise the rarer prism mark is retained.
    static func representativeKind(for outcomes: [PebbleKind]) -> PebbleKind {
        outcomes.reduce(.normal) { current, candidate in
            representativeKind(combining: current, with: candidate)
        }
    }

    private static func representativeKind(
        combining current: PebbleKind,
        with candidate: PebbleKind
    ) -> PebbleKind {
        if current == .gold || candidate == .gold { return .gold }
        if current == .prism || candidate == .prism { return .prism }
        return .normal
    }
}

enum GachaEngine {
    /// Natural odds are disclosed in Settings and stay independent from the
    /// pity adjustment. This also gives tests and future UI one canonical way
    /// to describe the three outcomes.
    static func naturalProbability(for kind: PebbleKind) -> Double {
        switch kind {
        case .normal:
            max(
                0,
                1 - Constants.Gacha.goldProbability - Constants.Gacha.prismProbability
            )
        case .gold:
            Constants.Gacha.goldProbability
        case .prism:
            Constants.Gacha.prismProbability
        }
    }

    static func probabilityLabel(for kind: PebbleKind) -> String {
        let percentage = naturalProbability(for: kind) * 100
        if percentage.rounded() == percentage {
            return "\(Int(percentage))%"
        }
        return String(format: "%.1f%%", percentage)
    }

    /// Static, non-personalized disclosure for the deterministic safeguard.
    /// Settings can explain the complete rule without exposing a live
    /// countdown that would encourage someone to chase the next draw.
    static var goldGuaranteeDisclosure: String {
        "250gごとの抽選で金が\(Constants.Gacha.pityMissCount)回続けて出なかった場合、次の抽選は金の粒になります。虹はこの回数をリセットしません。"
    }

    /// The number of additional earned credits before gold is certain.
    /// A natural gold may still arrive sooner. Prism deliberately does not
    /// reset this gold-specific guarantee.
    static func creditsUntilGuaranteedGold(sinceLastGold: Int) -> Int {
        max(1, Constants.Gacha.pityMissCount - max(0, sinceLastGold) + 1)
    }

    /// Compatibility spelling for existing presentation/tests. The value now
    /// counts 250g credits, not completion rows.
    static func completionsUntilGuaranteedGold(sinceLastGold: Int) -> Int {
        creditsUntilGuaranteedGold(sinceLastGold: sinceLastGold)
    }

    /// Maps a uniform [0, 1) roll to the specified natural rates, without pity.
    /// Keeping this primitive public to the module makes rate verification
    /// independent from the deliberately rate-increasing pity system.
    static func naturalKind(forUnitRoll unitRoll: Double) -> PebbleKind {
        let roll = normalized(unitRoll)
        if roll < Constants.Gacha.prismProbability {
            return .prism
        }
        if roll < Constants.Gacha.prismProbability + Constants.Gacha.goldProbability {
            return .gold
        }
        return .normal
    }

    static func draw(
        source: SessionSource,
        completedSeconds: Int,
        sinceLastGold: Int,
        unitRoll: Double
    ) -> GachaRoll {
        let misses = max(0, sinceLastGold)

        // Compatibility primitive for legacy history/debug callers. Product
        // persistence now accumulates mass in `RareRewardPolicy` and invokes
        // `drawCredit` once for every earned 250g credit.
        guard source == .timer,
              completedSeconds >= Constants.Gacha.minimumEligibleSeconds else {
            return GachaRoll(
                kind: .normal,
                wasEligible: false,
                triggeredPity: false,
                sinceLastGold: misses,
                consumedCreditCount: 0
            )
        }

        return drawCredit(sinceLastGold: misses, unitRoll: unitRoll)
    }

    /// Resolves exactly one already-earned 250g credit.
    static func drawCredit(
        sinceLastGold: Int,
        unitRoll: Double
    ) -> GachaRoll {
        let misses = max(0, sinceLastGold)

        if misses >= Constants.Gacha.pityMissCount {
            return GachaRoll(
                kind: .gold,
                participated: true,
                wasEligible: true,
                triggeredPity: true,
                sinceLastGold: 0,
                consumedCreditCount: 1,
                creditOutcomes: [.gold]
            )
        }

        let kind = naturalKind(forUnitRoll: unitRoll)
        return GachaRoll(
            kind: kind,
            participated: true,
            wasEligible: true,
            triggeredPity: false,
            // Prism is not gold, so it does not reset a counter explicitly
            // named `sinceLastGold`.
            sinceLastGold: kind == .gold ? 0 : misses + 1,
            consumedCreditCount: 1,
            creditOutcomes: [kind]
        )
    }

    static func drawCredit<R: RandomNumberGenerator>(
        sinceLastGold: Int,
        using generator: inout R
    ) -> GachaRoll {
        let unitRoll = Double.random(in: 0 ..< 1, using: &generator)
        return drawCredit(sinceLastGold: sinceLastGold, unitRoll: unitRoll)
    }

    @discardableResult
    static func draw(
        source: SessionSource,
        completedSeconds: Int,
        state: GachaState,
        unitRoll: Double
    ) -> GachaRoll {
        let result = draw(
            source: source,
            completedSeconds: completedSeconds,
            sinceLastGold: state.sinceLastGold,
            unitRoll: unitRoll
        )
        state.sinceLastGold = result.sinceLastGold
        return result
    }

    static func draw<R: RandomNumberGenerator>(
        source: SessionSource,
        completedSeconds: Int,
        sinceLastGold: Int,
        using generator: inout R
    ) -> GachaRoll {
        guard source == .timer,
              completedSeconds >= Constants.Gacha.minimumEligibleSeconds else {
            return draw(
                source: source,
                completedSeconds: completedSeconds,
                sinceLastGold: sinceLastGold,
                unitRoll: 0
            )
        }
        let unitRoll = Double.random(in: 0 ..< 1, using: &generator)
        return draw(
            source: source,
            completedSeconds: completedSeconds,
            sinceLastGold: sinceLastGold,
            unitRoll: unitRoll
        )
    }

    @discardableResult
    static func draw<R: RandomNumberGenerator>(
        source: SessionSource,
        completedSeconds: Int,
        state: GachaState,
        using generator: inout R
    ) -> GachaRoll {
        let result = draw(
            source: source,
            completedSeconds: completedSeconds,
            sinceLastGold: state.sinceLastGold,
            using: &generator
        )
        state.sinceLastGold = result.sinceLastGold
        return result
    }

    private static func normalized(_ unitRoll: Double) -> Double {
        guard unitRoll.isFinite else { return 1.nextDown }
        return min(max(0, unitRoll), 1.nextDown)
    }
}
