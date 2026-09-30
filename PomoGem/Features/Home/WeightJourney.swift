import Foundation

/// 重さの旅 (Weight Journey), GemExperienceDesign §5 and D1/D6/D7.
///
/// A pure, deterministic reading of one number: the lifetime grams the HUD
/// already shows (loose sessions + root aggregates, 1 minute = 10g). Nothing
/// here is stored or synced. Every marker and landmark is derived again from
/// the grams each time, so two devices that agree on the grams agree on the
/// journey, and deleting records honestly walks it back (§5.6, §9.1).
///
/// Two layers sit on top of the grams (§5.2):
///
/// - 一里塚 (milestone markers): one every 10 hours (6kg). The lit ◇ fold
///   decimally, like fusion: 10 ◇ → 1 星 (100 h), 10 星 → 1 冠 (1,000 h),
///   10 冠 → 1 ゾウ (10,000 h). Forty years at 10 h a day is ◇0 星1 冠6 ゾウ14.
/// - 名所 (landmarks): 1-2-5 hours with an everyday weight comparison
///   (Docs/WeightJourneyComparisons.md), then one more ゾウ every 10,000 h.
///   Landmarks on a 10-hour multiple are that marker with a name.
///
/// The core stages (2.5kg × 10ⁿ, `EffortProgressPolicy`) stay their own
/// layer. They never become the Home target (D6) but are reported by
/// `crossing(from:to:)` so one completion can fold every beat it crossed
/// into one choreography (§4.1, §5.6).
enum WeightJourney {
    static let gramsPerMinute = Constants.Mass.gramsPerMinute
    /// One 一里塚 every 10 hours.
    static let markerMinutes = 600
    static let markerGrams = markerMinutes * gramsPerMinute
    /// ◇ → 星 → 冠 → ゾウ, the same fan-in as fusion.
    static let fold = FusionHierarchyPresentation.fanIn
    /// ゾウ1頭ぶん: 10,000 hours, 6t.
    static let elephantMinutes = 600_000
    static let elephantGrams = elephantMinutes * gramsPerMinute
    /// §5.5: Home names the next 名所 when it is at most 10 hours away and
    /// the next 一里塚 otherwise.
    static let landmarkLookaheadGrams = markerGrams
    /// `crossing(from:to:)` lists at most this many unnamed markers and this
    /// many ゾウ herds (plus ゾウ1頭ぶん). A completion (at most 360 minutes)
    /// crosses at most one marker; the cap only bounds a sync jump, where §5.6
    /// names just the highest.
    static let listedCrossingLimit = 10

    // MARK: - Celebration size (§5.3)

    /// The four sizes of §5.3. Ordered, so a crossing can pick its largest.
    enum Celebration: Int, Comparable, Sendable {
        /// A one-line chip in the completion card (「◇ 30時間」, 「2時間。…」).
        case small
        /// A 名所 card.
        case medium
        /// The core's birth or next stage.
        case large
        /// ゾウ1頭ぶん only: the one-time zoom out.
        case extraLarge

        static func < (lhs: Celebration, rhs: Celebration) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    // MARK: - 一里塚

    /// The lit markers, folded decimally (D7). Only `elephants` is unbounded,
    /// and it grows by one per 10,000 hours.
    struct MarkerFold: Equatable, Sendable {
        /// Every 一里塚 reached so far.
        let count: Int
        /// ◇ on the inner orbit, 0–9.
        let diamonds: Int
        /// 100-hour 星 on the outer orbit, 0–9.
        let stars: Int
        /// 1,000-hour 冠 at the top, 0–9.
        let crowns: Int
        /// 10,000-hour ゾウ marks.
        let elephants: Int

        init(count rawCount: Int) {
            let count = max(0, rawCount)
            self.count = count
            diamonds = count % WeightJourney.fold
            stars = count / WeightJourney.fold % WeightJourney.fold
            crowns = count / (WeightJourney.fold * WeightJourney.fold) % WeightJourney.fold
            elephants = count / (WeightJourney.fold * WeightJourney.fold * WeightJourney.fold)
        }
    }

    /// One 一里塚. `ordinal` 1 is 10 hours.
    struct Marker: Equatable, Hashable, Sendable {
        /// What lighting this marker completes on the orbit.
        enum Completion: Int, Comparable, Sendable {
            case diamond, star, crown, elephant

            static func < (lhs: Completion, rhs: Completion) -> Bool {
                lhs.rawValue < rhs.rawValue
            }
        }

        let ordinal: Int

        var minutes: Int { WeightJourney.saturatingProduct(ordinal, WeightJourney.markerMinutes) }
        var grams: Int { WeightJourney.saturatingProduct(ordinal, WeightJourney.markerGrams) }

        /// The 10th ◇ gathers into a 星, the 100th into a 冠, the 1,000th
        /// into a ゾウ (§7.10).
        var completes: Completion {
            let fold = WeightJourney.fold
            if ordinal % (fold * fold * fold) == 0 { return .elephant }
            if ordinal % (fold * fold) == 0 { return .crown }
            if ordinal % fold == 0 { return .star }
            return .diamond
        }
    }

    // MARK: - 名所

    /// The everyday object a 名所 is compared with. The weights, sources and
    /// the reasons for every replacement are in
    /// Docs/WeightJourneyComparisons.md; the labels below are the ledger's.
    enum Comparison: Equatable, Hashable, Sendable {
        case apple
        case eggs
        case cabbage
        case salmon
        case largeWatermelon
        case corgi
        case emperorPenguin
        /// Defined as 60kg, so its label drops 「ほど」 (§5.7).
        case riceBale
        case giantPanda
        case zebra
        case dairyCow
        case giraffe
        case newbornBlueWhale
        case bullAfricanElephants(Int)
        /// The sub-label of ゾウ5頭ぶん.
        case humpbackWhale

        /// True only for a quantity that is exact by definition (米俵 = 60kg).
        /// Every other label says 「ほど」 and never claims a balance.
        var isExact: Bool { self == .riceBale }
    }

    /// One 名所 on the ladder of §5.3.
    struct Landmark: Equatable, Hashable, Sendable {
        enum Kind: Equatable, Hashable, Sendable {
            /// 25 minutes: 最初の一粒.
            case firstGem
            /// 1 hour: はじめての1時間.
            case firstHour
            /// 2, 5, 10 … 5,000 hours, named by the time itself.
            case hours
            /// ゾウN頭ぶん, every 10,000 hours.
            case elephants(Int)
        }

        /// The position on the ladder: 0 is 25 minutes, 13 is ゾウ1頭ぶん,
        /// 13 + (n − 1) is ゾウn頭ぶん.
        let index: Int
        let minutes: Int
        let kind: Kind
        let comparison: Comparison
        /// ザトウクジラ1頭ほど under ゾウ5頭ぶん; nil elsewhere.
        let subComparison: Comparison?
        let celebration: Celebration

        var grams: Int { WeightJourney.saturatingProduct(minutes, WeightJourney.gramsPerMinute) }

        /// A landmark on a 10-hour multiple is that 一里塚 with a name
        /// (§5.2): the ◇ and the card are one choreography.
        var marker: Marker? {
            guard minutes % WeightJourney.markerMinutes == 0 else { return nil }
            return Marker(ordinal: minutes / WeightJourney.markerMinutes)
        }
    }

    /// The fixed ladder below ゾウ1頭ぶん, in order. It never mentions a core
    /// stage: those are offset on purpose (4h10m, 41h40m … §5.2).
    static let fixedLandmarks: [Landmark] = {
        let rungs: [(minutes: Int, kind: Landmark.Kind, comparison: Comparison, celebration: Celebration)] = [
            (25, .firstGem, .apple, .small),
            (60, .firstHour, .eggs, .medium),
            (120, .hours, .cabbage, .small),
            (300, .hours, .salmon, .small),
            (600, .hours, .largeWatermelon, .medium),
            (1_200, .hours, .corgi, .medium),
            (3_000, .hours, .emperorPenguin, .medium),
            (6_000, .hours, .riceBale, .medium),
            (12_000, .hours, .giantPanda, .medium),
            (30_000, .hours, .zebra, .medium),
            (60_000, .hours, .dairyCow, .medium),
            (120_000, .hours, .giraffe, .medium),
            (300_000, .hours, .newbornBlueWhale, .medium),
        ]
        return rungs.enumerated().map { index, rung in
            Landmark(
                index: index,
                minutes: rung.minutes,
                kind: rung.kind,
                comparison: rung.comparison,
                subComparison: nil,
                celebration: rung.celebration
            )
        }
    }()

    /// The herd reaches five at 50,000 hours, when ザトウクジラ joins as a
    /// sub-label.
    static let humpbackHerdSize = 5

    /// ゾウn頭ぶん (n ≥ 1): every 10,000 hours, without an upper bound.
    static func elephantLandmark(count rawCount: Int) -> Landmark {
        // Clamped so the grams (and the index) of the herd stay representable.
        let count = min(max(1, rawCount), Int.max / elephantGrams)
        return Landmark(
            index: fixedLandmarks.count + count - 1,
            minutes: saturatingProduct(count, elephantMinutes),
            kind: .elephants(count),
            comparison: .bullAfricanElephants(count),
            subComparison: count == humpbackHerdSize ? .humpbackWhale : nil,
            celebration: count == 1 ? .extraLarge : .medium
        )
    }

    /// The highest 名所 at or below `grams`, or nil before 25 minutes.
    static func landmark(reachedAt rawGrams: Int) -> Landmark? {
        let grams = max(0, rawGrams)
        let herd = grams / elephantGrams
        if herd >= 1 { return elephantLandmark(count: herd) }
        return fixedLandmarks.last { $0.grams <= grams }
    }

    /// The first 名所 strictly above `grams`.
    static func landmark(after rawGrams: Int) -> Landmark {
        let grams = max(0, rawGrams)
        if let fixed = fixedLandmarks.first(where: { $0.grams > grams }) { return fixed }
        return elephantLandmark(count: grams / elephantGrams + 1)
    }

    // MARK: - Home target and the 50% rule (§5.5)

    /// What Home's one line points at.
    enum Target: Equatable, Sendable {
        /// 「つぎの名所　米俵1俵・100時間」
        case landmark(Landmark)
        /// 「つぎの一里塚　80時間」
        case marker(Marker)

        var grams: Int {
            switch self {
            case let .landmark(landmark): return landmark.grams
            case let .marker(marker): return marker.grams
            }
        }

        var minutes: Int {
            switch self {
            case let .landmark(landmark): return landmark.minutes
            case let .marker(marker): return marker.minutes
            }
        }
    }

    /// The stretch from the last 一里塚 or 名所 to the target Home shows.
    struct Segment: Equatable, Sendable {
        /// Koo & Fishbach 2012: say what was stacked up to the halfway point,
        /// and what is left once past it.
        enum Reading: Equatable, Sendable {
            /// 「+3時間10分 積みました」
            case accumulated(grams: Int)
            /// 「あと4時間50分」
            case remaining(grams: Int)
        }

        let startGrams: Int
        let endGrams: Int
        let grams: Int

        var lengthGrams: Int { max(0, endGrams - startGrams) }
        var accumulatedGrams: Int { max(0, grams - startGrams) }
        var remainingGrams: Int { max(0, endGrams - grams) }

        /// Whole minutes stacked in this stretch (rounded down).
        var accumulatedMinutes: Int { accumulatedGrams / WeightJourney.gramsPerMinute }
        /// Minutes left (rounded up, so it never reads 「あと0分」 before the target).
        var remainingMinutes: Int {
            let perMinute = WeightJourney.gramsPerMinute
            return remainingGrams / perMinute + (remainingGrams % perMinute == 0 ? 0 : 1)
        }

        /// Up to and including half the stretch: accumulated. Past half: remaining.
        var isPastHalf: Bool {
            accumulatedGrams > lengthGrams - accumulatedGrams
        }

        var reading: Reading {
            isPastHalf ? .remaining(grams: remainingGrams) : .accumulated(grams: accumulatedGrams)
        }

        var fraction: Double {
            guard lengthGrams > 0 else { return 0 }
            return min(1, Double(accumulatedGrams) / Double(lengthGrams))
        }
    }

    struct State: Equatable, Sendable {
        let grams: Int
        /// The input was a lower bound (`projectionIsLowerBound`) or iCloud
        /// has not verified it (`isCloudVerificationPending`).
        let isProvisional: Bool
        let markers: MarkerFold
        let reachedLandmark: Landmark?
        let nextLandmark: Landmark
        let nextMarker: Marker
        let nextTarget: Target
        /// The last 一里塚 or 名所 at or below `grams`: where the stretch
        /// towards `nextTarget` begins. While provisional it is only a floor
        /// (「80時間以上・同期中」).
        let segmentStartGrams: Int
        /// Nil while provisional: a lower bound says nothing about how far
        /// into the stretch the real total is (§5.5).
        let segment: Segment?
    }

    /// The whole journey for one lifetime total. O(1) in the grams except for
    /// the 13-rung fixed ladder.
    static func state(grams rawGrams: Int, isProvisional: Bool) -> State {
        let grams = max(0, rawGrams)
        let markerCount = grams / markerGrams
        let reached = landmark(reachedAt: grams)
        let nextLandmark = landmark(after: grams)
        let nextMarker = Marker(ordinal: markerCount + 1)
        let nextTarget: Target = nextLandmark.grams - grams <= landmarkLookaheadGrams
            ? .landmark(nextLandmark)
            : .marker(nextMarker)
        let segmentStart = max(reached?.grams ?? 0, saturatingProduct(markerCount, markerGrams))
        return State(
            grams: grams,
            isProvisional: isProvisional,
            markers: MarkerFold(count: markerCount),
            reachedLandmark: reached,
            nextLandmark: nextLandmark,
            nextMarker: nextMarker,
            nextTarget: nextTarget,
            segmentStartGrams: segmentStart,
            segment: isProvisional
                ? nil
                : Segment(startGrams: segmentStart, endGrams: nextTarget.grams, grams: grams)
        )
    }

    // MARK: - Crossings (§5.6)

    /// One point on the grams axis that something happens at. A 名所 on a
    /// 10-hour multiple and its 一里塚 are the same threshold.
    struct Threshold: Equatable, Hashable, Sendable {
        let grams: Int
        let landmark: Landmark?
        let marker: Marker?
        /// `EffortProgressSnapshot`'s level: 1 is the core's birth at 2.5kg.
        let coreStage: Int?

        var celebration: Celebration {
            var size = Celebration.small
            if let landmark { size = max(size, landmark.celebration) }
            if coreStage != nil { size = max(size, .large) }
            return size
        }
    }

    struct Crossing: Equatable, Sendable {
        /// Highest first: every crossed core stage and 名所 below the herd,
        /// ゾウ1頭ぶん, the highest `listedCrossingLimit` herds and the highest
        /// `listedCrossingLimit` unnamed 一里塚.
        let thresholds: [Threshold]
        /// Every 一里塚 crossed, named or not, listed or not.
        let markerCount: Int

        var isEmpty: Bool { thresholds.isEmpty }
        /// §5.6: celebrate this one…
        var highest: Threshold? { thresholds.first }
        /// …and list these on the same card.
        var others: [Threshold] { Array(thresholds.dropFirst()) }
        /// One completion gets one choreography of this size (§4.1).
        var largestCelebration: Celebration? { thresholds.map(\.celebration).max() }
    }

    /// The thresholds in `(previousGrams, grams]`: for a Reward Receipt,
    /// `totalStudyGrams − grams` to `totalStudyGrams`. Pure over the grams;
    /// the caller still applies §5.6 (no big beat from a lower-bound receipt,
    /// no replay below the device's celebration watermark).
    static func crossing(from rawPreviousGrams: Int, to rawGrams: Int) -> Crossing {
        let previous = max(0, rawPreviousGrams)
        let grams = max(0, rawGrams)
        guard grams > previous else { return Crossing(thresholds: [], markerCount: 0) }

        var byGrams: [Int: (landmark: Landmark?, marker: Marker?, coreStage: Int?)] = [:]
        func add(grams: Int, landmark: Landmark? = nil, marker: Marker? = nil, coreStage: Int? = nil) {
            var entry = byGrams[grams] ?? (nil, nil, nil)
            entry.landmark = landmark ?? entry.landmark
            entry.marker = marker ?? entry.marker
            entry.coreStage = coreStage ?? entry.coreStage
            byGrams[grams] = entry
        }

        // 一里塚: the highest few are listed, all are counted.
        let firstMarker = previous / markerGrams + 1
        let lastMarker = grams / markerGrams
        let markerCount = max(0, lastMarker - firstMarker + 1)
        if markerCount > 0 {
            let lowestListed = max(firstMarker, lastMarker - listedCrossingLimit + 1)
            for ordinal in stride(from: lastMarker, through: lowestListed, by: -1) {
                let marker = Marker(ordinal: ordinal)
                add(grams: marker.grams, marker: marker)
            }
        }

        // 名所 below ゾウ1頭ぶん.
        for landmark in fixedLandmarks where landmark.grams > previous && landmark.grams <= grams {
            add(grams: landmark.grams, landmark: landmark, marker: landmark.marker)
        }

        // The ゾウ herd, highest few listed.
        let firstHerd = previous / elephantGrams + 1
        let lastHerd = grams / elephantGrams
        if lastHerd >= firstHerd {
            let lowestListed = max(firstHerd, lastHerd - listedCrossingLimit + 1)
            // ゾウ1頭ぶん is the one extra-large beat, so it is always listed.
            let listed = Array(stride(from: lastHerd, through: lowestListed, by: -1))
                + (firstHerd == 1 && lowestListed > 1 ? [1] : [])
            for count in listed {
                let landmark = elephantLandmark(count: count)
                add(grams: landmark.grams, landmark: landmark, marker: landmark.marker)
            }
        }

        // Core stages: 2.5kg × 10ⁿ, never on a marker or a landmark.
        var stage = 1
        var stageGrams = EffortProgressPolicy.firstMilestoneGrams
        while stageGrams <= grams {
            if stageGrams > previous { add(grams: stageGrams, coreStage: stage) }
            let next = stageGrams.multipliedReportingOverflow(by: fold)
            guard !next.overflow else { break }
            stageGrams = next.partialValue
            stage += 1
        }

        let thresholds = byGrams
            .map { Threshold(grams: $0.key, landmark: $0.value.landmark, marker: $0.value.marker, coreStage: $0.value.coreStage) }
            .sorted { $0.grams > $1.grams }
        return Crossing(thresholds: thresholds, markerCount: markerCount)
    }

    // MARK: - Arithmetic

    static func saturatingProduct(_ lhs: Int, _ rhs: Int) -> Int {
        let result = max(0, lhs).multipliedReportingOverflow(by: max(0, rhs))
        return result.overflow ? Int.max : result.partialValue
    }
}

// MARK: - Text

// The labels come from Docs/WeightJourneyComparisons.md (the source ledger).
// Times use DurationText, so ja reads 「2時間」「1,000時間」 and en "2 hr".
extension WeightJourney.Landmark {
    /// 「最初の一粒」「はじめての1時間」「2時間」…「ゾウ1頭ぶん」.
    var name: String {
        switch kind {
        case .firstGem:
            return String(
                localized: "最初の一粒",
                table: "Home",
                comment: "Weight Journey (重さの旅) landmark (名所) at 25 minutes. Suggested en: 'First Gem'."
            )
        case .firstHour:
            return String(
                localized: "はじめての1時間",
                table: "Home",
                comment: "Weight Journey (重さの旅) landmark (名所) at 1 hour. Suggested en: 'Your First Hour'."
            )
        case .hours:
            return timeText
        case let .elephants(count):
            return String(
                localized: "ゾウ\(count)頭ぶん",
                table: "Home",
                comment: "Weight Journey (重さの旅) landmark (名所) every 10,000 hours (6t each). %lld is the number of elephants (1, 2, 3…). Suggested en: 'One Elephant' / '%lld Elephants' (plural variation)."
            )
        }
    }

    /// The landmark's time: 「25分」「2時間」「10,000時間」.
    var timeText: String { DurationText.short(minutes: minutes) }
}

extension WeightJourney.Comparison {
    /// 「りんご1個ほど」… 「米俵1俵」. Only natural things, food and animals;
    /// never a person (§5.7).
    var label: String {
        switch self {
        case .apple:
            return String(localized: "りんご1個ほど", table: "Home", comment: "Weight Journey comparison for 250g (名所 at 25 minutes). Suggested en: 'About an apple'.")
        case .eggs:
            return String(localized: "卵10個ほど", table: "Home", comment: "Weight Journey comparison for 600g (名所 at 1 hour): ten M-size hen's eggs. Suggested en: 'About 10 eggs'.")
        case .cabbage:
            return String(localized: "キャベツ1玉ほど", table: "Home", comment: "Weight Journey comparison for 1.2kg (名所 at 2 hours). Suggested en: 'About a head of cabbage'.")
        case .salmon:
            return String(localized: "サケ1尾ほど", table: "Home", comment: "Weight Journey comparison for 3kg (名所 at 5 hours): one chum salmon. Suggested en: 'About a salmon'.")
        case .largeWatermelon:
            return String(localized: "大玉スイカ1玉ほど", table: "Home", comment: "Weight Journey comparison for 6kg (名所 at 10 hours). Suggested en: 'About a large watermelon'.")
        case .corgi:
            return String(localized: "コーギー1頭ほど", table: "Home", comment: "Weight Journey comparison for 12kg (名所 at 20 hours). Suggested en: 'About a corgi'.")
        case .emperorPenguin:
            return String(localized: "コウテイペンギン1羽ほど", table: "Home", comment: "Weight Journey comparison for 30kg (名所 at 50 hours). Suggested en: 'About an emperor penguin'.")
        case .riceBale:
            return String(localized: "米俵1俵", table: "Home", comment: "Weight Journey comparison for 60kg (名所 at 100 hours). Exactly 60kg by definition, so no 'about'. Needs a different object in English (see Docs/WeightJourneyComparisons.md); literal en: 'One rice bale'.")
        case .giantPanda:
            return String(localized: "ジャイアントパンダ1頭ほど", table: "Home", comment: "Weight Journey comparison for 120kg (名所 at 200 hours). Suggested en: 'About a giant panda'.")
        case .zebra:
            return String(localized: "シマウマ1頭ほど", table: "Home", comment: "Weight Journey comparison for 300kg (名所 at 500 hours). Suggested en: 'About a zebra'.")
        case .dairyCow:
            return String(localized: "乳牛1頭ほど", table: "Home", comment: "Weight Journey comparison for 600kg (名所 at 1,000 hours): a Holstein cow. Suggested en: 'About a dairy cow'.")
        case .giraffe:
            return String(localized: "キリン1頭ほど", table: "Home", comment: "Weight Journey comparison for 1.2t (名所 at 2,000 hours). Suggested en: 'About a giraffe'.")
        case .newbornBlueWhale:
            return String(localized: "シロナガスクジラの赤ちゃん1頭ほど", table: "Home", comment: "Weight Journey comparison for 3t (名所 at 5,000 hours): a newborn blue whale calf. Suggested en: 'About a newborn blue whale'.")
        case let .bullAfricanElephants(count):
            return String(localized: "アフリカゾウ（オス）\(count)頭ほど", table: "Home", comment: "Weight Journey comparison every 10,000 hours (6t per elephant). %lld is the number of adult male African elephants. Suggested en: 'About one bull African elephant' / 'About %lld bull African elephants' (plural variation).")
        case .humpbackWhale:
            return String(localized: "ザトウクジラ1頭ほど", table: "Home", comment: "Weight Journey sub-comparison under 'five elephants' (30t, 50,000 hours). Suggested en: 'About a humpback whale'.")
        }
    }
}
