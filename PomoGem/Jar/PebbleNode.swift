import SpriteKit
import UIKit

struct AggregateMetadata: Equatable, Sendable {
    let level: Int
    let pebbleCount: Int
    let childAggregateCount: Int
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
        level: Int,
        pebbleCount: Int,
        childAggregateCount: Int,
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
        self.level = max(1, level)
        self.pebbleCount = max(0, pebbleCount)
        self.childAggregateCount = max(0, childAggregateCount)
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

    init(aggregate: AggregatePebble) {
        self.init(
            level: aggregate.level,
            pebbleCount: aggregate.pebbleCount,
            childAggregateCount: aggregate.childAggregateCount,
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

    var dominantColorHex: String {
        colorMix.first?.hex ?? Constants.Color.textMute
    }

    var primarySubjectName: String {
        subjectMix.first?.name ?? "過去の集中"
    }

    func accessibilityDescription(
        presentsRareRewards requestedPresentation: Bool
    ) -> String {
        let subject = subjectMix.count > 1 ? "\(primarySubjectName)など" : primarySubjectName
        let hierarchy: String
        if level == 1 {
            hierarchy = "\(pebbleCount)粒を含むまとまり粒"
        } else {
            hierarchy = "\(pebbleCount)粒、\(childAggregateCount)個のまとまりを含むまとまり粒"
        }
        let reporting = manualPebbleCount > 0
            ? "実測\(measuredPebbleCount)粒、自己申告\(manualPebbleCount)粒"
            : "実測\(measuredPebbleCount)粒"
        let presentsRareRewards = RareRewardReleasePolicy
            .permitsInternalTestOverride(requestedPresentation)
        let rare = presentsRareRewards
            ? [
                goldPebbleCount > 0 ? "金\(goldPebbleCount)粒" : nil,
                prismPebbleCount > 0 ? "虹\(prismPebbleCount)粒" : nil
            ].compactMap { $0 }.joined(separator: "、")
            : ""
        let rareSuffix = rare.isEmpty ? "" : "、\(rare)"
        return "\(subject)、\(hierarchy)、\(reporting)\(rareSuffix)"
    }

    var accessibilityDescription: String {
        accessibilityDescription(
            presentsRareRewards: RareRewardReleasePolicy.isEnabled
        )
    }
}

/// Converts persisted study mass into bounded SpriteKit geometry.
///
/// A circle's area is proportional to the square of its radius, so using the
/// square root of the mass ratio makes equal total focus time occupy equal
/// foreground area regardless of how that time was split into completions.
/// The bounds keep very short custom timers visible and very long timers from
/// becoming unstable obstacles in the jar.
enum PebbleRadiusPolicy {
    static let minimumMeasuredScale: CGFloat = 0.60
    static let maximumMeasuredScale: CGFloat = 1.75
    static let minimumAggregateScale: CGFloat = 0.85
    static let maximumAggregateScale: CGFloat = 1.15

    static func measuredRadius(grams rawGrams: Int) -> CGFloat {
        let grams = max(0, rawGrams)
        // Zero-mass tutorial stones and compatibility rows retain the historic
        // visible size without claiming any study value.
        guard grams > 0 else { return Constants.Jar.measuredRadius }
        let nominalGrams = max(1, Constants.Mass.measuredPebbleGrams)
        let rawScale = CGFloat(
            (Double(grams) / Double(nominalGrams)).squareRoot()
        )
        return Constants.Jar.measuredRadius * bounded(
            rawScale,
            minimum: minimumMeasuredScale,
            maximum: maximumMeasuredScale
        )
    }

    static func aggregateRadius(
        grams rawGrams: Int,
        pebbleCount rawPebbleCount: Int,
        level: Int
    ) -> CGFloat {
        let baseRadius = CGFloat(StrataMath.aggregateRadius(level: level))
        let grams = max(0, rawGrams)
        let pebbleCount = max(0, rawPebbleCount)
        // Unknown-mass legacy summaries stay at their established hierarchy
        // size. Modern aggregates always carry exact grams.
        guard grams > 0, pebbleCount > 0 else { return baseRadius }
        let nominalGrams = Double(pebbleCount)
            * Double(max(1, Constants.Mass.measuredPebbleGrams))
        let rawScale = CGFloat((Double(grams) / nominalGrams).squareRoot())
        return baseRadius * bounded(
            rawScale,
            minimum: minimumAggregateScale,
            maximum: maximumAggregateScale
        )
    }

    private static func bounded(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}

/// D4 (decided): one jar-wide scale for every body in the jar
/// (Docs/GemExperienceDesign.md §7.5). `PebbleRadiusPolicy` still sets each
/// body's own radius (area ∝ mass between gems); the scene multiplies all of
/// them by one factor `s = clamp(√(A_budget / A0), 1, maximumScale)`, where
/// `A0` is Σπr² of the bodies at their own radii (study gems, milestone
/// stones and Screen Time stones alike, plus the incoming drop) and
/// `A_budget` a fixed share of the interior. A young jar therefore shows a
/// few large jewels; as the pile grows the jar scales down to the shipping
/// size (s = 1, never below) and every fusion, which lowers `A0`, lets the
/// gems grow again. Presentation only: the stored rows, the grams, the
/// capacity units and the fusion rules never see the scale.
enum JarScalePolicy {
    /// Share of the interior rectangle the scaled bodies may cover
    /// (Σπ(s·r)² ≤ budget while s > 1). Well below the ~66 % at which the
    /// shipping worst case still keeps 17 % free under the mouth.
    static let interiorAreaBudgetFraction: CGFloat = 0.30
    /// A 25-minute gem is about 57 pt across at this scale: 0.19 of the
    /// iPhone 17 Pro Home interior (306 pt) and 0.20 of the 12 mini's
    /// (279 pt); the reference image shows 0.15–0.20. The top is a rung of
    /// the ladder itself (1.04²³ ≈ 2.465, round 12; it was 2.4, one 1.3 %
    /// step above 1.04²²). Its two-rung hysteresis reads the uncapped
    /// target (`uncappedTargetScale`, round 13).
    static let maximumScale: CGFloat = pow(rungRatio, 23)
    static let minimumScale: CGFloat = 1
    /// Scales move on a geometric ladder of 4 % rungs, so a landing that
    /// changes the target by a hair never re-bakes the jar.
    static let rungRatio: CGFloat = 1.04
    /// Hysteresis: a jar shrinks as soon as its target falls below the
    /// current rung, but grows only when the target clears it by two rungs.
    static let growthRungs = 2
    /// Screen Time stones grow at 0.72 × the study scale (a one-unit stone
    /// is then never larger than a ten-minute study gem of the same jar) and
    /// never beyond 1.6.
    static let obstacleScaleRatio: CGFloat = 0.72
    static let maximumObstacleScale: CGFloat = 1.6
    /// Scale changes animate over this long (landing, fusion, resize).
    static let transitionDuration: TimeInterval = 0.5

    /// Σπr² of bodies at their own (unscaled) radii.
    static func baseArea<Radii: Sequence>(radii: Radii) -> CGFloat where Radii.Element == CGFloat {
        radii.reduce(CGFloat.zero) { total, radius in
            guard radius.isFinite, radius > 0 else { return total }
            return total + .pi * radius * radius
        }
    }

    /// The continuous target scale for bodies covering `baseArea` in an
    /// interior of `interiorArea`, clamped to 1…`maximumScale`.
    static func targetScale(baseArea: CGFloat, interiorArea: CGFloat) -> CGFloat {
        min(uncappedTargetScale(baseArea: baseArea, interiorArea: interiorArea), maximumScale)
    }

    /// The same target without the top clamp (never below 1): how large the
    /// budget would let the bodies grow. The hysteresis reads this one
    /// (round 13). With the clamped target, a jar one rung under the top
    /// climbed back as soon as the budget touched 1.04²³, so a load
    /// hovering there flipped 2.37 ↔ 2.465 on every body added or removed;
    /// now the top rung, like every other, waits for a target two rungs
    /// above the rung the jar shows (1.04²⁴).
    static func uncappedTargetScale(baseArea: CGFloat, interiorArea: CGFloat) -> CGFloat {
        guard interiorArea.isFinite, interiorArea > 0 else { return minimumScale }
        guard baseArea.isFinite, baseArea > 0 else { return .infinity }
        let raw = (interiorArea * interiorAreaBudgetFraction / baseArea).squareRoot()
        return raw.isNaN ? minimumScale : max(raw, minimumScale)
    }

    /// Highest ladder rung at or below `scale` (1, 1.04, 1.04², … and
    /// `maximumScale` itself as the top rung). An unbounded target (+∞, an
    /// empty jar's `uncappedTargetScale`) is the top rung; NaN and −∞ are
    /// the floor.
    static func rung(atOrBelow scale: CGFloat) -> CGFloat {
        guard !scale.isNaN else { return minimumScale }
        let clamped = min(max(scale, minimumScale), maximumScale)
        if clamped >= maximumScale { return maximumScale }
        let steps = (log(clamped / minimumScale) / log(rungRatio) + 1e-6).rounded(.down)
        return min(maximumScale, minimumScale * pow(rungRatio, max(0, steps)))
    }

    /// The scale a jar at `current` moves to for `target`: down to the rung
    /// below the target at once (the pile never outgrows its budget), up
    /// only once the target clears the current rung by two rungs, otherwise
    /// unchanged. The growth test reads `target` itself, never clamped, so
    /// pass the uncapped target (or use
    /// `resolvedScale(current:baseArea:interiorArea:)`, as the scene does):
    /// a target clamped at `maximumScale` never lifts a jar off the rung
    /// below the top.
    static func resolvedScale(current rawCurrent: CGFloat, target: CGFloat) -> CGFloat {
        let current = rawCurrent.isFinite ? min(max(rawCurrent, minimumScale), maximumScale) : minimumScale
        let candidate = rung(atOrBelow: target)
        if candidate < current - 1e-6 { return candidate }
        let growthThreshold = current * pow(rungRatio, CGFloat(growthRungs))
        if target >= growthThreshold - 1e-6 { return candidate }
        return current
    }

    /// `resolvedScale(current:target:)` for bodies covering `baseArea`
    /// (at their own radii) in an interior of `interiorArea`.
    static func resolvedScale(current: CGFloat, baseArea: CGFloat, interiorArea: CGFloat) -> CGFloat {
        resolvedScale(
            current: current,
            target: uncappedTargetScale(baseArea: baseArea, interiorArea: interiorArea)
        )
    }

    /// The scale of Screen Time stones in a jar whose study gems use
    /// `studyScale`: never above the study scale, never below 1.
    static func obstacleScale(studyScale: CGFloat) -> CGFloat {
        guard studyScale.isFinite else { return minimumScale }
        return min(max(minimumScale, studyScale * obstacleScaleRatio), maximumObstacleScale, max(minimumScale, studyScale))
    }

    /// The share of the jar-wide scale a body of `descriptor` uses.
    static func bodyScale(for descriptor: PebbleDescriptor, studyScale: CGFloat) -> CGFloat {
        descriptor.isScreenTimeObstacle ? obstacleScale(studyScale: studyScale) : studyScale
    }
}

/// A value boundary between persistence/timer features and SpriteKit.
///
/// Keeping the scene fed with immutable values makes it safe to rebuild the jar from
/// SwiftData, render a share-only jar, and create the zero-gram onboarding pebble.
struct PebbleDescriptor: Identifiable {
    let id: UUID
    let subjectName: String
    let colorHex: String
    let source: SessionSource
    let kind: PebbleKind
    /// All per-credit outcomes represented by this one physical body. The
    /// `kind` above remains the material chosen for rendering.
    let rareRewardCounts: RareRewardCounts
    let achievementKind: AchievementKind?
    let aggregate: AggregateMetadata?
    let grams: Int
    let radius: CGFloat
    let createdAt: Date
    let isTutorial: Bool
    /// Rendering-only obstacle metadata never enters the study data model.
    let screenTimeObstacle: ScreenTimeObstacleDescriptor?

    init(
        id: UUID = UUID(),
        subjectName: String,
        colorHex: String,
        source: SessionSource,
        kind: PebbleKind,
        rareRewardCounts: RareRewardCounts? = nil,
        achievementKind: AchievementKind? = nil,
        aggregate: AggregateMetadata? = nil,
        grams: Int,
        radius: CGFloat? = nil,
        createdAt: Date = .now,
        isTutorial: Bool = false,
        screenTimeObstacle: ScreenTimeObstacleDescriptor? = nil
    ) {
        self.id = id
        self.subjectName = subjectName
        self.colorHex = colorHex
        self.source = source
        self.kind = kind
        self.rareRewardCounts = rareRewardCounts ?? RareRewardCounts(
            outcomes: kind == .normal ? [] : [kind]
        )
        self.achievementKind = achievementKind
        self.aggregate = aggregate
        self.grams = grams
        let massDerivedRadius = Self.recommendedRadius(
            source: source,
            grams: grams,
            achievementKind: achievementKind,
            aggregate: aggregate
        )
        // Aggregate geometry is an invariant derived from its lossless mass and
        // membership. Do not let an older count-only caller bypass it by passing
        // the former hierarchy radius explicitly. Loose/tutorial fixtures may
        // still provide a deliberate radius override.
        self.radius = aggregate == nil ? (radius ?? massDerivedRadius) : massDerivedRadius
        self.createdAt = createdAt
        self.isTutorial = isTutorial
        self.screenTimeObstacle = screenTimeObstacle
    }

    init(session: StudySession) {
        self.init(
            id: session.id,
            subjectName: session.displaySubjectName,
            colorHex: session.displaySubjectColorHex,
            source: session.effectiveSource,
            kind: RareRewardPresentationPolicy.kind(session.pebbleKind),
            rareRewardCounts: session.rareRewardCounts,
            grams: session.grams,
            createdAt: session.endAt
        )
    }

    init(achievement: AchievementStone) {
        self.init(
            id: achievement.id,
            subjectName: achievement.displaySubjectName,
            colorHex: achievement.displaySubjectColorHex,
            source: .manual,
            kind: .normal,
            achievementKind: achievement.kind,
            grams: 0,
            createdAt: achievement.achievedAt
        )
    }

    init(aggregate: AggregatePebble) {
        let metadata = AggregateMetadata(aggregate: aggregate)
        self.init(
            id: aggregate.id,
            subjectName: metadata.primarySubjectName,
            colorHex: metadata.dominantColorHex,
            source: aggregate.manualPebbleCount > aggregate.measuredPebbleCount
                ? .manual
                : .timer,
            kind: .normal,
            aggregate: metadata,
            grams: aggregate.grams,
            radius: CGFloat(StrataMath.aggregateRadius(level: aggregate.level)),
            createdAt: aggregate.createdAt
        )
    }

    var isAchievement: Bool { achievementKind != nil }
    var isAggregate: Bool { aggregate != nil }
    var isScreenTimeObstacle: Bool { screenTimeObstacle != nil }
    var aggregateLevel: Int { aggregate?.level ?? 0 }
    var participatesInAggregation: Bool { !isAchievement && !isTutorial && !isScreenTimeObstacle }
    var participatesInBake: Bool { participatesInAggregation }

    /// UUID identifies the stored row, not an immutable rendering snapshot.
    /// Cloud reconciliation can legitimately update a row in place, so the
    /// scene also compares every field that affects geometry, appearance or
    /// accessibility before deciding an existing body is current.
    func hasSamePresentation(as other: PebbleDescriptor) -> Bool {
        id == other.id
            && subjectName == other.subjectName
            && colorHex == other.colorHex
            && source.rawValue == other.source.rawValue
            && kind.rawValue == other.kind.rawValue
            && rareRewardCounts == other.rareRewardCounts
            && achievementKind?.rawValue == other.achievementKind?.rawValue
            && aggregate == other.aggregate
            && grams == other.grams
            && radius == other.radius
            && createdAt == other.createdAt
            && isTutorial == other.isTutorial
            && screenTimeObstacle == other.screenTimeObstacle
    }

    /// Kept compact enough for the landing card and VoiceOver. This is only
    /// shown for a completion that consumed multiple 250g credits.
    var rewardBatchSummary: String? {
        rareRewardCounts.multiDrawSummary
    }

    var presentationRewardBatchSummary: String? {
        RareRewardPresentationPolicy.counts(rareRewardCounts).multiDrawSummary
    }

    var isMeasured: Bool {
        guard !isScreenTimeObstacle else { return false }
        return switch source {
        case .timer, .screenTime:
            true
        case .manual, .timerDemoted:
            false
        }
    }

    var accessibilityDescription: String {
        if let screenTimeObstacle {
            return screenTimeObstacle.accessibilityDescription
        }
        if let aggregate {
            return "\(aggregate.accessibilityDescription)、\(grams)グラム"
        }
        if let achievementKind {
            return "\(subjectName)、\(achievementKind.title)の記念石、質量には含まれません"
        }
        let measurement = source == .screenTime ? "スクリーンタイム" : (isMeasured ? "実測" : "自己申告")
        let material: String
        let presentationKind = RareRewardPresentationPolicy.kind(kind)
        switch presentationKind {
        case .normal: material = "つぶ"
        case .gold: material = "金のつぶ"
        case .prism: material = "虹のつぶ"
        }
        let rewardDetail = presentationRewardBatchSummary.map { "、\($0)" } ?? ""
        return "\(subjectName)、\(measurement)の\(material)、\(grams)グラム\(rewardDetail)"
    }

    var aggregateSource: AggregateSource {
        precondition(!isScreenTimeObstacle, "Screen Time obstacles cannot enter study aggregation")
        if let aggregate {
            return AggregateSource(
                id: id,
                level: aggregate.level,
                pebbleCount: aggregate.pebbleCount,
                childAggregateCount: aggregate.childAggregateCount,
                grams: grams,
                radius: Double(radius),
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
        return AggregateSource(
            id: id,
            grams: grams,
            radius: Double(radius),
            colorMix: [StratumColorFraction(hex: colorHex, fraction: 1)],
            subjectMix: [AggregateSubjectFraction(
                name: subjectName,
                colorHex: colorHex,
                pebbleCount: 1
            )],
            periodStart: createdAt,
            periodEnd: createdAt,
            sessionIDs: [id],
            measuredPebbleCount: isMeasured ? 1 : 0,
            manualPebbleCount: isMeasured ? 0 : 1,
            goldPebbleCount: rareRewardCounts.goldCount,
            prismPebbleCount: rareRewardCounts.prismCount
        )
    }

    private static func recommendedRadius(
        source: SessionSource,
        grams: Int,
        achievementKind: AchievementKind?,
        aggregate: AggregateMetadata?
    ) -> CGFloat {
        if let aggregate {
            return PebbleRadiusPolicy.aggregateRadius(
                grams: grams,
                pebbleCount: aggregate.pebbleCount,
                level: aggregate.level
            )
        }
        if achievementKind != nil {
            return Constants.Jar.measuredRadius * Constants.Jar.achievementRadiusScale
        }
        return switch source {
        case .timer, .timerDemoted, .screenTime:
            PebbleRadiusPolicy.measuredRadius(grams: grams)
        case .manual:
            // Manual buttons are 30/60/120 minutes and the model stores 10 g/min.
            switch grams {
            case ...ManualDuration.thirtyMinutes.grams: Constants.Jar.manualThirtyRadius
            case ...ManualDuration.sixtyMinutes.grams: Constants.Jar.manualSixtyRadius
            default: Constants.Jar.manualOneTwentyRadius
            }
        }
    }
}

/// A single persistent study pebble. Its physics body stays deliberately circular for
/// reliable high-volume simulation; the irregularity is visual rather than collisional.
final class PebbleNode: SKShapeNode {
    let descriptor: PebbleDescriptor
    /// The body's own radius (`PebbleRadiusPolicy`, from the descriptor).
    /// The physics circle and every child are built on it in the node's
    /// local space; the jar-wide scale (`JarScalePolicy`) is the node's
    /// scale, which SpriteKit applies to the physics body as well.
    let localRadius: CGFloat
    /// Display scale of the gem body bake (from the owning scene's view).
    let artworkScale: CGFloat
    /// This body's share of the jar-wide scale (D4, §7.5): 1 at the
    /// shipping size. Animated by `transitionJarScale(to:duration:)`.
    private(set) var jarScale: CGFloat = 1
    /// The scale a running (or the last) transition ends at.
    private(set) var jarScaleTarget: CGFloat = 1
    /// The jar scale the body texture was baked for (so a scaled gem stays
    /// as crisp as one built at that size).
    private(set) var textureJarScale: CGFloat = 1
    /// Scene-space radius of the collision circle and the visible gem.
    var radius: CGFloat { localRadius * jarScale }
    /// The radius the sound and haptic plan hears. The jar scale is
    /// presentation only, so a larger-looking gem sounds exactly as before.
    var sensoryRadius: CGFloat { localRadius }
    /// The body's mass as if it were unscaled (read when the circle is
    /// built, before the node is scaled). Shake impulses divide by it, so a
    /// jar of large young gems shakes as lively as the shipping jar while
    /// heavier crystals still lag behind lighter ones.
    private(set) var presentationMass: CGFloat = 0

    private(set) var hasLanded = false
    private(set) var lastObservedPosition: CGPoint = .zero
    private(set) var isRemovedForBake = false
    private var reducesVisualMotion: Bool
    /// 演出の強さ as chosen on this device (D17); `effects` is what shows.
    private(set) var effectsIntensity: JarEffectsIntensity
    private(set) var rareRewardMode: RareRewardMode
    private var contactShadowNode: SKShapeNode?
    private var contactCausticNode: SKShapeNode?
    private var dimensionalLightNode: SKSpriteNode?
    private var aggregateAuraNode: SKNode?
    private var earlyEffortAuraNode: SKSpriteNode?
    private var earlyEffortBloomNode: SKSpriteNode?
    /// The warm pool of light the first gems rest in (round 12), in the
    /// light rig so it stays under the gem while it rolls.
    private var earlyEffortPoolNode: SKSpriteNode?
    /// D26 (b): the ×N count as a small engraved copper tag (one sprite).
    private var aggregateTagNode: SKSpriteNode?
    /// How far below the centre the tag sits, as a share of the radius:
    /// `aggregatePlateDrop`, or lower so it clears the theme marks
    /// (Differentiate Without Color, round 14).
    private(set) var aggregateTagDrop: CGFloat = PebbleNode.aggregatePlateDrop
    /// How far the body's theme marks reach from its centre (a share of the
    /// radius), or nil when it shows none.
    private(set) var themeMarkExtent: CGFloat?
    /// 1, or `quietTagScale` while another crystal is emphasised.
    private(set) var aggregateTagEmphasis: CGFloat = 1
    /// The tag's text, exactly the former plate's (`AggregatePresentation`).
    private(set) var aggregateTagText: String?
    /// D21: Pro's month engraving under the count ("2026.9"), or nil.
    private(set) var aggregateTagMonth: String?
    /// Pro shows every crystal's month on its tag (D21).
    private(set) var showsMonthEngraving: Bool
    /// 記念石 (round 13): the mark engraved in the dome, kept upright.
    private var achievementMarkNode: SKSpriteNode?
    /// 記念石: the floating sheen (adularescence) and the soft highlight on
    /// the dome, screen-fixed in the light rig; tilting slides them.
    private var cabochonSheenNode: SKSpriteNode?
    private var cabochonHighlightNode: SKSpriteNode?
    /// Faceted gem skin (loose normal gems, aggregates and achievement
    /// stones). The circular physics body, radius and mass are untouched by
    /// any of these nodes.
    private(set) var gemRung: GemCutRung?
    private var gemBodyNode: SKSpriteNode?
    private var gemBodySpec: GemArtworkSpec?
    /// The baked rock of a Screen Time stone.
    private var obstacleBodyNode: SKSpriteNode?
    private var gemHaloNode: SKSpriteNode?
    /// The jar's fade before the SKView's edge (round 13), set by the
    /// scene: the body, the halo and the first gems' light use its shader,
    /// so a gem entering from the top or a halo past the bottle fades out
    /// instead of being cut by the view's rectangle.
    var lightEdgeFade: JarLightEdgeFade? {
        didSet { applyLightEdgeFade() }
    }
    /// Light inside the jewel (shared additive sprite, tinted pale).
    private var gemInnerGlowNode: SKSpriteNode?
    private var gemInnerGlowBaseAlpha: CGFloat = 0
    /// Screen-fixed light rig: contact shadow, key sheen, pavilion shade,
    /// rims and glints counter-rotate together so the light source stays put
    /// in the scene while the body rolls.
    private var gemLightRigNode: SKNode?
    private var gemGlintNodes: [SKSpriteNode] = []
    private var gemGlintRestPositions: [CGPoint] = []
    private var gemGlintPhases: [CGFloat] = []
    /// Upright count on a Screen Time obstacle. Held directly: the lighting
    /// pass runs for every body on every frame, and a name search there
    /// (`childNode(withName:)` with a dotted name) scans the runtime's type
    /// records each call — it was the jar's single largest frame cost.
    private var obstacleCountNode: SKSpriteNode?
    private var gemHaloBaseAlpha: CGFloat = 0
    /// +10 % for the aggregate that holds the most grams in the pile.
    private var gemHaloEmphasis: CGFloat = 1
    /// Scene time of the last spontaneous flare (per-gem cooldown).
    private(set) var lastGemTwinkleTime: TimeInterval = -.greatestFiniteMagnitude
    /// Reduce Transparency trades additive bloom for crisper edges.
    private var reducesTransparency = UIAccessibility.isReduceTransparencyEnabled

    static let cutLadder = GemCutLadder.standard

    var subjectColor: UIColor { JarPalette.color(hex: descriptor.colorHex) }
    private var presentsRareRewardFeature: Bool {
        RareRewardReleasePolicy.permitsInternalTestOverride(true)
    }
    private var presentationKind: PebbleKind {
        presentsRareRewardFeature ? descriptor.kind : .normal
    }

    /// Bake scale used before a view reports its own (the 3× ceiling of
    /// current iPhones, so a texture is never soft).
    nonisolated static let defaultArtworkScale: CGFloat = 3

    init(
        descriptor: PebbleDescriptor,
        reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled,
        rareRewardMode: RareRewardMode = .standard,
        artworkScale: CGFloat = PebbleNode.defaultArtworkScale,
        jarScale: CGFloat = 1,
        effectsIntensity: JarEffectsIntensity = .standard,
        showsMonthEngraving: Bool = false
    ) {
        self.descriptor = descriptor
        self.localRadius = descriptor.radius
        self.reducesVisualMotion = reduceMotion
        self.effectsIntensity = effectsIntensity
        self.showsMonthEngraving = showsMonthEngraving
        self.rareRewardMode = rareRewardMode
        self.artworkScale = GemArtwork.renderScale(artworkScale)
        let scale = Self.sanitizedJarScale(jarScale)
        self.jarScale = scale
        self.jarScaleTarget = scale
        self.textureJarScale = scale
        super.init()
        configureAppearance()
        configurePhysics()
        setScale(scale)
        updateSemanticLabelScale()
    }

    required init?(coder aDecoder: NSCoder) {
        descriptor = PebbleDescriptor(
            subjectName: "",
            colorHex: Constants.Color.textMute,
            source: .timer,
            kind: .normal,
            aggregate: nil,
            grams: .zero
        )
        localRadius = Constants.Jar.measuredRadius
        reducesVisualMotion = UIAccessibility.isReduceMotionEnabled
        effectsIntensity = .standard
        showsMonthEngraving = false
        rareRewardMode = .standard
        artworkScale = Self.defaultArtworkScale
        super.init(coder: aDecoder)
    }

    func markLanded() {
        hasLanded = true
        physicsBody?.usesPreciseCollisionDetection = false
    }

    func markForBake() {
        isRemovedForBake = true
        physicsBody = nil
    }

    func rememberObservedPosition() {
        lastObservedPosition = position
    }

    // MARK: Jar-wide scale (D4)

    static let jarScaleActionKey = "pebble.jarScale"
    /// Scene-side birth pops (fusion finale, black carry) run under this
    /// key, relative to `jarScale`, so a scale transition can take over.
    static let birthActionKey = "pebble.birth"

    static func sanitizedJarScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0 else { return 1 }
        return min(max(scale, JarScalePolicy.minimumScale), JarScalePolicy.maximumScale)
    }

    /// Moves the body to `rawTarget` of the jar-wide scale over `duration`
    /// (smoothstep; 0 = at once). Visual and physics radius move together
    /// (SpriteKit scales the body with the node), so a growing pile pushes
    /// its neighbours apart a little each frame instead of overlapping them
    /// at once. The body texture is re-baked for the target size first,
    /// unless `refreshesTexture` is false: then the current texture carries
    /// the transition (a few percent soft for at most half a second) until
    /// the scene hands the new one over (`adoptJarScaleTexture`).
    func transitionJarScale(to rawTarget: CGFloat, duration: TimeInterval, refreshesTexture: Bool = true) {
        let target = Self.sanitizedJarScale(rawTarget)
        // Already there, or already on its way (a birth pop included).
        guard abs(target - jarScaleTarget) > 0.0001 else { return }
        removeAction(forKey: Self.jarScaleActionKey)
        // A birth pop still in flight hands its current size over.
        removeAction(forKey: Self.birthActionKey)
        jarScaleTarget = target
        if refreshesTexture { refreshBodyTexture(forJarScale: target) }
        let startScale = jarScale
        let startVisual = xScale
        guard duration > 0, !isRemovedForBake,
              abs(target - startScale) > 0.0001 || abs(target - startVisual) > 0.0001
        else {
            applyJarScale(target, visual: target)
            return
        }
        let seconds = CGFloat(duration)
        let step = SKAction.customAction(withDuration: duration) { node, elapsed in
            guard let pebble = node as? PebbleNode else { return }
            let t = min(1, max(0, elapsed / seconds))
            let eased = t * t * (3 - 2 * t)
            pebble.applyJarScale(
                startScale + (target - startScale) * eased,
                visual: startVisual + (target - startVisual) * eased
            )
        }
        run(.sequence([
            step,
            .run { [weak self] in self?.applyJarScale(target, visual: target) }
        ]), withKey: Self.jarScaleActionKey)
    }

    var isTransitioningJarScale: Bool { action(forKey: Self.jarScaleActionKey) != nil }

    /// Shows the body baked for the scale it is moving to (the scene calls
    /// this once the transition's bake is in; nothing when it already is).
    func adoptJarScaleTexture() {
        refreshBodyTexture(forJarScale: jarScaleTarget)
    }

    /// Ends a running transition at its target (the scene calls this before
    /// it freezes, so a paused jar never keeps a half-scaled body).
    func finishJarScaleTransition() {
        guard isTransitioningJarScale else { return }
        removeAction(forKey: Self.jarScaleActionKey)
        applyJarScale(jarScaleTarget, visual: jarScaleTarget)
    }

    private func applyJarScale(_ scale: CGFloat, visual: CGFloat) {
        jarScale = scale
        setScale(visual)
        updateSemanticLabelScale()
    }

    /// Count tags keep their own on-screen size: they are counter-scaled so
    /// the jar scale never turns them into large numbers.
    private func updateSemanticLabelScale() {
        let inverse = 1 / max(jarScale, 0.01)
        aggregateTagNode?.setScale(inverse * aggregateTagEmphasis)
        obstacleCountNode?.setScale(inverse)
        updateAggregateTagDrop()
    }

    /// Re-reads how far the tag sits below the centre (its on-screen size
    /// and the theme marks it must clear, `GemArtwork.countTagDrop`) and
    /// places it there.
    private func updateAggregateTagDrop() {
        guard aggregateTagNode != nil else { return }
        let fontSize = GemArtwork.countTagFontSize(sceneRadius: localRadius * textureJarScale)
        let countLine = GemArtwork.countEngravingCountLineHeight(fontSize: fontSize)
        // The tag is counter-scaled: in the body's own units its count line
        // is `countLine × emphasis / jarScale` tall.
        let halfHeight = countLine / 2 * aggregateTagEmphasis / max(jarScale, 0.01) / max(localRadius, 0.01)
        aggregateTagDrop = GemArtwork.countTagDrop(themeMarkExtent: themeMarkExtent, tagHalfHeight: halfHeight)
        placeAggregateTag()
    }

    /// The tag upright, `aggregateTagDrop` below the centre in screen space
    /// however the stone has rolled.
    private func placeAggregateTag() {
        guard let tag = aggregateTagNode else { return }
        let cosine = cos(zRotation)
        let sine = sin(zRotation)
        let offset = CGPoint(x: 0, y: -localRadius * aggregateTagDrop)
        tag.zRotation = -zRotation
        tag.position = CGPoint(
            x: cosine * offset.x + sine * offset.y,
            y: -sine * offset.x + cosine * offset.y
        )
    }

    /// SpriteKit shaders keep animating independently of SKActions. Updating
    /// the shader explicitly is therefore required when Reduce Motion changes
    /// while the bottle is already on screen.
    func setReduceMotion(_ enabled: Bool) {
        guard reducesVisualMotion != enabled else { return }
        reducesVisualMotion = enabled
        // Reduce Motion implies 控えめ: halos and breaths follow as well.
        applyEffects()
        guard presentationKind == .prism, !descriptor.isAggregate else { return }
        fillShader = rareRewardMode.usesEnhancedPresentation
            ? (enabled ? Self.staticPrismShader : Self.prismShader)
            : nil
    }

    /// What this gem shows: the preference, or 控えめ under Reduce Motion.
    var effects: JarEffectsIntensity {
        .resolved(preference: effectsIntensity, reduceMotion: reducesVisualMotion)
    }

    /// 演出の強さ changed (D17). Only light and motion change: the body,
    /// its physics, mass and marks stay exactly as they are.
    func setEffectsIntensity(_ intensity: JarEffectsIntensity) {
        guard effectsIntensity != intensity else { return }
        effectsIntensity = intensity
        applyEffects()
    }

    /// Re-applies everything that follows `effects`: halo and inner light,
    /// the early-effort light, the auras' breath and the glints' rest.
    private func applyEffects() {
        applyHaloAlpha()
        applyEarlyEffortAlpha()
        configureAggregateAuraMotion()
        configureEarlyEffortAuraMotion()
        settleGemTwinkle()
    }

    /// Changes only the optional random-reward presentation. The pebble's
    /// persisted kind, mass, mark, accessibility description, and aggregate
    /// membership remain factual in every mode.
    func setRareRewardMode(_ mode: RareRewardMode) {
        guard rareRewardMode != mode else { return }
        rareRewardMode = mode

        if let aggregate = descriptor.aggregate {
            updateAggregateRarePresentation(aggregate)
            return
        }
        guard !descriptor.isAchievement, presentationKind != .normal else { return }
        configureLooseGemMaterial(fill: baseLooseFill)
        updateRareMarkPresentation()
        contactCausticNode?.fillColor = visualAccentColor.withAlphaComponent(0.16)
    }

    /// Makes the first few honest completions readable in a large bottle
    /// without changing their physics radius, collision mass, or recorded
    /// grams. The halo is presentation only and disappears once the bottle has
    /// enough content to speak for itself.
    func setEarlyEffortSpotlight(_ enabled: Bool) {
        guard !descriptor.isTutorial,
              !descriptor.isAchievement,
              !descriptor.isAggregate,
              !descriptor.isScreenTimeObstacle else {
            removeEarlyEffortLight()
            return
        }
        guard enabled else {
            removeEarlyEffortLight()
            return
        }
        if earlyEffortAuraNode == nil {
            // A 520pt bottle makes an honest 11.5pt first stone look like
            // debris. Keep its collision body exact, but give the first three
            // efforts a presentation-only pool of light large enough to read
            // at arm's length. Both layers reuse the shared Gaussian halo
            // texture (one additive batch, no neon ring).
            let tint = GemTone(hex: descriptor.colorHex, muted: !descriptor.isMeasured, glass: false)
                .haloUIColor
            let bloom = Self.sharedLightSprite(
                GemTextureAtlas.SharedName.halo,
                size: CGSize(width: localRadius * 5.6, height: localRadius * 5.6)
            )
            bloom.name = "pebble.earlyEffortBloom"
            bloom.color = tint
            bloom.colorBlendFactor = 1
            bloom.blendMode = .add
            bloom.zPosition = -0.52
            addChild(bloom)
            earlyEffortBloomNode = bloom

            let aura = Self.sharedLightSprite(
                GemTextureAtlas.SharedName.halo,
                size: CGSize(width: localRadius * 3.4, height: localRadius * 3.4)
            )
            aura.name = "pebble.earlyEffortAura"
            aura.color = tint
            aura.colorBlendFactor = 1
            aura.blendMode = .add
            aura.zPosition = -0.45
            addChild(aura)
            earlyEffortAuraNode = aura

            // Round 12: a warm pool of light on the floor under the gem
            // (#FFB38A, α0.35), so the first gem of an empty jar rests in
            // light instead of alone in a dark bottle. Screen-fixed with
            // the light rig, flat, behind the body.
            if let rig = gemLightRigNode {
                let pool = SKSpriteNode(
                    texture: GemArtwork.poolTexture,
                    size: CGSize(width: localRadius * 3.6, height: localRadius * 1.2)
                )
                pool.name = "pebble.earlyEffortPool"
                pool.color = JarPalette.color(hex: "#FFB38A")
                pool.colorBlendFactor = 1
                pool.blendMode = .add
                pool.position = CGPoint(x: 0, y: -localRadius * 0.72)
                pool.zPosition = -1.1
                rig.addChild(pool)
                earlyEffortPoolNode = pool
            }
            applyLightEdgeFade()
            applyEarlyEffortAlpha()
        }
        configureEarlyEffortAuraMotion()
    }

    private func applyLightEdgeFade() {
        guard let lightEdgeFade else { return }
        [gemBodyNode, obstacleBodyNode, gemHaloNode, earlyEffortBloomNode, earlyEffortAuraNode, earlyEffortPoolNode]
            .forEach(lightEdgeFade.apply(to:))
    }

    private func removeEarlyEffortLight() {
        earlyEffortAuraNode?.removeFromParent()
        earlyEffortAuraNode = nil
        earlyEffortBloomNode?.removeFromParent()
        earlyEffortBloomNode = nil
        earlyEffortPoolNode?.removeFromParent()
        earlyEffortPoolNode = nil
    }

    /// The early-effort light (§7.6): lighter with Reduce Transparency and
    /// at 控えめ (the halo scale).
    private func applyEarlyEffortAlpha() {
        let scale = effects.haloScale
        earlyEffortAuraNode?.alpha = (reducesTransparency ? 0.16 : 0.34) * scale
        earlyEffortBloomNode?.alpha = (reducesTransparency ? 0.12 : 0.26) * scale
        earlyEffortPoolNode?.alpha = (reducesTransparency ? 0.16 : 0.35) * scale
    }

    private func configureEarlyEffortAuraMotion() {
        guard let aura = earlyEffortAuraNode else { return }
        let key = "pebble.earlyEffortAura.breath"
        aura.removeAction(forKey: key)
        aura.setScale(1)
        earlyEffortBloomNode?.removeAction(forKey: key)
        earlyEffortBloomNode?.setScale(1)
        guard effects.allowsBreathing else { return }
        // Scale-only breathing keeps the Reduce Transparency alpha intact.
        let expand = SKAction.scale(to: 1.10, duration: 1.15)
        expand.timingMode = .easeInEaseOut
        let contract = SKAction.scale(to: 1, duration: 1.15)
        contract.timingMode = .easeInEaseOut
        aura.run(.repeatForever(.sequence([expand, contract])), withKey: key)
        let bloomExpand = SKAction.scale(to: 1.06, duration: 1.15)
        bloomExpand.timingMode = .easeInEaseOut
        let bloomContract = SKAction.scale(to: 1, duration: 1.15)
        bloomContract.timingMode = .easeInEaseOut
        earlyEffortBloomNode?.run(
            .repeatForever(.sequence([bloomExpand, bloomContract])),
            withKey: key
        )
    }

    /// Keeps the cast shade and key-light fixed in scene space while the stone
    /// rotates. Material marks and speckles still rotate with the physical body,
    /// so the result reads as an actual lit object instead of a spinning sticker.
    func updatePresentationLighting(horizontal: CGFloat) {
        let cosine = cos(zRotation)
        let sine = sin(zRotation)

        let worldOffset = CGPoint(
            x: horizontal * localRadius * 0.12,
            y: -localRadius * 0.63
        )
        for contactNode in [contactShadowNode, contactCausticNode].compactMap({ $0 }) {
            contactNode.position = CGPoint(
                x: cosine * worldOffset.x + sine * worldOffset.y,
                y: -sine * worldOffset.x + cosine * worldOffset.y
            )
            contactNode.zRotation = -zRotation
        }

        if let dimensionalLightNode, gemLightRigNode == nil {
            let worldOffset = CGPoint(x: horizontal * localRadius * 0.055, y: 0)
            dimensionalLightNode.position = CGPoint(
                x: cosine * worldOffset.x + sine * worldOffset.y,
                y: -sine * worldOffset.x + cosine * worldOffset.y
            )
            dimensionalLightNode.zRotation = -zRotation
        }

        if let gemLightRigNode {
            // One transform keeps shadow, sheen, shade, rims and glints fixed
            // to the scene's key light. Tilt slides the highlights a little,
            // like turning a real stone under a lamp.
            gemLightRigNode.zRotation = -zRotation
            dimensionalLightNode?.position = CGPoint(x: horizontal * localRadius * 0.07, y: 0)
            // A moonstone's sheen floats against the tilt; its highlight
            // follows the light like the key sheen.
            if let cabochonSheenNode {
                let rest = Self.cabochonSheenRest(radius: localRadius)
                cabochonSheenNode.position = CGPoint(x: rest.x - horizontal * localRadius * 0.24, y: rest.y)
            }
            if let cabochonHighlightNode {
                let rest = Self.cabochonHighlightRest(radius: localRadius)
                cabochonHighlightNode.position = CGPoint(x: rest.x + horizontal * localRadius * 0.07, y: rest.y)
            }
            for index in gemGlintNodes.indices {
                let glint = gemGlintNodes[index]
                // Each glint owns a narrow window (0.12 wide) in the smoothed
                // tilt, so tilting the phone makes the pile catch the light
                // one stone at a time (about four lit at once in a full jar).
                // 控えめ (and Reduce Motion) keeps one static star: tilt
                // never lights a glint.
                let distance = abs(horizontal - gemGlintPhases[index])
                let window = effects.allowsTiltGlints
                    ? max(0, 1 - distance / (Self.glintTiltWindow / 2))
                    : 0
                let tiltBoost = window * window * (3 - 2 * window)
                let twinkleBoost = max(0, glint.xScale - 1) / (Self.gemTwinkleScale - 1)
                glint.alpha = min(1, glintRestAlpha(index: index) + tiltBoost * 0.55 + twinkleBoost * 0.85)
                let rest = gemGlintRestPositions[index]
                glint.position = CGPoint(x: rest.x + horizontal * localRadius * 0.12, y: rest.y)
            }
        }

        // Counts and achievement marks are semantic labels, not painted
        // speckles. Keeping them upright makes ×1万 / 合格 readable even after
        // a user tilts or taps the physical stone. The aggregate plate sits
        // below the table (screen-fixed offset) so the brightest facets stay
        // visible.
        placeAggregateTag()
        achievementMarkNode?.zRotation = -zRotation
        if let count = obstacleCountNode {
            // Engraved on the rock's lower face, upright in screen space.
            let offset = CGPoint(x: 0, y: -localRadius * ScreenTimeObstacleAppearance.countDrop)
            count.zRotation = -zRotation
            count.position = CGPoint(
                x: cosine * offset.x + sine * offset.y,
                y: -sine * offset.x + cosine * offset.y
            )
        }
    }

    private func configurePhysics() {
        let body = SKPhysicsBody(circleOfRadius: localRadius)
        body.restitution = Constants.Jar.restitution
        body.friction = Constants.Jar.friction
        body.linearDamping = Constants.Jar.linearDamping
        body.angularDamping = Constants.Jar.angularDamping
        body.allowsRotation = Constants.Jar.allowsRotation
        body.usesPreciseCollisionDetection = true
        body.categoryBitMask = JarPhysicsCategory.pebble
        body.collisionBitMask = JarPhysicsCategory.pebble
            | JarPhysicsCategory.wall
            | JarPhysicsCategory.floor
        body.contactTestBitMask = body.collisionBitMask
        physicsBody = body
        presentationMass = body.mass
    }

    private func configureAppearance() {
        name = "pebble.\(descriptor.id.uuidString)"
        path = Self.makeStonePath(radius: localRadius, id: descriptor.id)
        lineWidth = Constants.Jar.outlineWidth
        lineJoin = .round
        zPosition = JarZPosition.pebble
        if let obstacle = descriptor.screenTimeObstacle {
            obstacleCountNode = ScreenTimeObstacleAppearance.apply(
                to: self,
                descriptor: obstacle,
                radius: localRadius,
                scale: artworkScale,
                textureJarScale: textureJarScale
            )
            obstacleBodyNode = childNode(withName: ScreenTimeObstacleAppearance.bodyName) as? SKSpriteNode
            // Obstacles never glow. A normal-blended dark halo (1.6R, black
            // α0.35) sits above the reward halos, so neighbouring light is
            // absorbed instead of washing over the rubble.
            let shadowHalo = Self.sharedLightSprite(
                GemTextureAtlas.SharedName.halo,
                size: CGSize(width: localRadius * 3.2, height: localRadius * 3.2)
            )
            shadowHalo.name = "obstacle.shadowHalo"
            shadowHalo.color = .black
            shadowHalo.colorBlendFactor = 1
            shadowHalo.blendMode = .alpha
            shadowHalo.alpha = 0.35
            shadowHalo.zPosition = -0.4
            addChild(shadowHalo)
            return
        }
        if let aggregate = descriptor.aggregate {
            configureAggregateAppearance(aggregate)
            return
        }

        if descriptor.achievementKind == nil, presentationKind == .normal {
            configureFacetedLooseAppearance()
            return
        }

        if let achievementKind = descriptor.achievementKind {
            configureAchievementCabochon(achievementKind)
            return
        }

        addContactShadow()

        let fill = baseLooseFill

        switch presentationKind {
        case .normal:
            let crystalFill = fill.mixed(with: .white, amount: 0.025)
            fillColor = crystalFill.withAlphaComponent(descriptor.isTutorial ? 0.42 : 1)
            strokeColor = descriptor.isTutorial
                ? JarPalette.glass
                : crystalFill.mixed(with: .white, amount: 0.52).withAlphaComponent(
                    descriptor.isMeasured ? 0.72 : 0.48
                )
            lineWidth = max(1.05, localRadius * 0.09)
            glowWidth = descriptor.isTutorial ? 0 : localRadius * 0.10
        case .gold, .prism:
            configureLooseGemMaterial(fill: fill)
        }

        addCachedDetailTexture()
        addDimensionalOverlay()
        addRareMarkIfNeeded()
    }

    // MARK: Faceted gem skin

    /// Tilt window width of one glint in the smoothed tilt (−1…1).
    static let glintTiltWindow: CGFloat = 0.12
    /// Spontaneous flare: 140 ms rise, 60 ms hold, 220 ms fall, ≤ 1.25×.
    static let gemTwinkleScale: CGFloat = 1.25
    static let gemTwinkleRise: TimeInterval = 0.14
    static let gemTwinkleHold: TimeInterval = 0.06
    static let gemTwinkleFall: TimeInterval = 0.22
    /// A single gem flares at most once per cooldown (flash safety: the same
    /// place never blinks more than once a second).
    static let gemTwinkleCooldown: TimeInterval = 2.5
    /// Resting glint alpha while motion is allowed; tilt and flares add to it.
    static let glintRestAlpha: CGFloat = 0.15
    /// 控えめ (and Reduce Motion, which implies it) keeps one static star
    /// per gem instead of flares and tilt glints: the former Reduce Motion
    /// star (α0.6) at the 控えめ light scale (× 0.7, D17).
    static let reducedMotionStarAlpha: CGFloat = 0.42
    /// The ×N plate rests below the table, as a fraction of the radius
    /// (with theme marks it drops below them: `aggregateTagDrop`).
    static let aggregatePlateDrop: CGFloat = GemArtwork.countTagRestingDrop

    // MARK: Body specs (shared by the node and the texture pre-bake)

    /// The baked texture a descriptor's body shows — the facet body or the
    /// rubble — or nil for the legacy rare materials. The scene bakes these
    /// for a whole restore in parallel before it creates the nodes.
    static func bakeRequest(
        for descriptor: PebbleDescriptor,
        scale rawScale: CGFloat,
        jarScale: CGFloat = 1
    ) -> GemTextureAtlas.BakeRequest? {
        let scale = GemArtwork.renderScale(rawScale)
        let radius = descriptor.radius * sanitizedJarScale(jarScale)
        if let obstacle = descriptor.screenTimeObstacle {
            let variations = ScreenTimeObstacleAppearance.variations(descriptor: obstacle)
            return GemTextureAtlas.BakeRequest(
                name: ScreenTimeObstacleAppearance.textureName(variations: variations, radius: radius, scale: scale)
            ) {
                ScreenTimeObstacleAppearance.image(variations: variations, radius: radius, scale: scale)
            }
        }
        guard let spec = bodySpec(for: descriptor) else { return nil }
        return GemTextureAtlas.BakeRequest(
            name: GemArtwork.bodyTextureName(for: spec, radius: radius, scale: scale)
        ) {
            GemArtwork.renderBodyImage(for: spec, radius: radius, scale: scale)
        }
    }

    /// Launch pre-bake (Docs/GemExperienceDesign.md §7.13): the loose gems
    /// most jars start with — the five starter themes at 25 timer minutes
    /// and a 30-minute self-report, in all four variants, at the jar scale
    /// of a young jar (`JarScalePolicy.maximumScale`: 40 bodies, about 5 MB
    /// at 3×). Everything else bakes on first use.
    static func commonBakeRequests(
        scale rawScale: CGFloat,
        jarScale: CGFloat = JarScalePolicy.maximumScale
    ) -> [GemTextureAtlas.BakeRequest] {
        let scale = GemArtwork.renderScale(rawScale)
        let samples: [(source: SessionSource, grams: Int)] = [
            (.timer, Constants.Mass.measuredPebbleGrams),
            (.manual, ManualDuration.thirtyMinutes.grams)
        ]
        var requests: [GemTextureAtlas.BakeRequest] = []
        for subject in SeedData.subjects {
            for sample in samples {
                let descriptor = PebbleDescriptor(
                    subjectName: subject.name,
                    colorHex: subject.colorHex,
                    source: sample.source,
                    kind: .normal,
                    grams: sample.grams
                )
                let spec = looseSpec(for: descriptor)
                let radius = descriptor.radius * sanitizedJarScale(jarScale)
                for variant in 0 ..< GemArtworkSpec.variantCount {
                    let variantSpec = spec.withVariant(variant)
                    requests.append(GemTextureAtlas.BakeRequest(
                        name: GemArtwork.bodyTextureName(for: variantSpec, radius: radius, scale: scale)
                    ) {
                        GemArtwork.renderBodyImage(for: variantSpec, radius: radius, scale: scale)
                    })
                }
            }
        }
        return requests
    }

    /// `themeMarks` (Differentiate Without Color) engraves each theme's
    /// mark on study gems and crystals; achievement stones keep their own
    /// badge and the tutorial glass has no theme.
    static func bodySpec(
        for descriptor: PebbleDescriptor,
        themeMarks: Bool = GemThemeMark.isSystemEnabled
    ) -> GemArtworkSpec? {
        guard descriptor.screenTimeObstacle == nil else { return nil }
        if let aggregate = descriptor.aggregate {
            return aggregateSpec(for: descriptor, aggregate: aggregate, themeMarks: themeMarks)
        }
        if let achievementKind = descriptor.achievementKind {
            return achievementArtwork(for: descriptor, kind: achievementKind).spec
        }
        guard presentationKind(for: descriptor) == .normal else { return nil }
        return looseSpec(for: descriptor, themeMarks: themeMarks)
    }

    private static func presentationKind(for descriptor: PebbleDescriptor) -> PebbleKind {
        RareRewardReleasePolicy.permitsInternalTestOverride(true) ? descriptor.kind : .normal
    }

    private static func looseSpec(
        for descriptor: PebbleDescriptor,
        themeMarks: Bool = GemThemeMark.isSystemEnabled
    ) -> GemArtworkSpec {
        GemArtworkSpec(
            rung: cutLadder.rung(for: descriptor),
            colors: [GemColorShare(hex: descriptor.colorHex, fraction: 1)],
            variant: GemArtworkSpec.variant(for: descriptor.id),
            isMuted: !descriptor.isMeasured && !descriptor.isTutorial,
            showsDashedRing: !descriptor.isMeasured && !descriptor.isTutorial,
            edgeBoost: edgeBoost,
            showsThemeMarks: themeMarks && !descriptor.isTutorial
        )
    }

    /// 記念石 (round 13): a moonstone of its kind's hue
    /// (`AchievementKind.gemBaseHex`), one of the four variants by its id;
    /// the Overview shows the same stone (`ProgressCrystalGlyph`).
    private static func achievementArtwork(
        for descriptor: PebbleDescriptor,
        kind achievementKind: AchievementKind
    ) -> (spec: GemArtworkSpec, palette: GemArtwork.CabochonPalette) {
        let hex = "#" + achievementKind.gemBaseHex
        let spec = GemArtworkSpec(
            rung: cutLadder.achievement,
            colors: [GemColorShare(hex: hex, fraction: 1)],
            variant: GemArtworkSpec.variant(for: descriptor.id),
            isMuted: false,
            showsDashedRing: false,
            edgeBoost: edgeBoost
        )
        return (spec, GemArtwork.CabochonPalette(hex: hex))
    }

    private static func aggregateSpec(
        for descriptor: PebbleDescriptor,
        aggregate: AggregateMetadata,
        themeMarks: Bool = GemThemeMark.isSystemEnabled
    ) -> GemArtworkSpec {
        GemArtworkSpec(
            rung: cutLadder.rung(aggregateGrams: descriptor.grams),
            colors: GemArtworkSpec.aggregateColors(aggregate.colorMix, fallbackHex: aggregate.dominantColorHex),
            variant: GemArtworkSpec.variant(for: descriptor.id),
            isMuted: aggregate.manualPebbleCount > aggregate.measuredPebbleCount,
            showsDashedRing: aggregate.manualPebbleCount > 0,
            edgeBoost: edgeBoost,
            showsThemeMarks: themeMarks
        )
    }

    private func configureFacetedLooseAppearance() {
        let rung = Self.cutLadder.rung(for: descriptor)
        let spec = Self.looseSpec(for: descriptor)
        // The container keeps the silhouette as its path but draws nothing
        // (measured: no extra draw); the baked body sprite carries facets,
        // edges and the girdle outline. Collision stays the circular body.
        path = GemArtwork.outlinePath(for: spec, radius: localRadius)
        fillColor = .clear
        strokeColor = .clear
        lineWidth = 0
        glowWidth = 0
        let tone = GemTone(hex: descriptor.colorHex, muted: spec.isMuted, glass: descriptor.isTutorial)
        installGemSkin(
            rung: rung,
            spec: spec,
            tone: tone,
            haloStrength: descriptor.isTutorial
                ? 1
                : GemCutLadder.looseHaloStrength(grams: descriptor.grams),
            innerGlowAlpha: descriptor.isTutorial ? 0.18 : (spec.isMuted ? 0.34 : Self.looseInnerGlowAlpha)
        )
    }

    /// 記念石 (round 13, final design): a smooth domed moonstone cabochon —
    /// milky and pearly, a soft sheen of its kind's hue floating inside —
    /// with its mark (✓, W, 100) engraved in the dome. No facets, no
    /// setting, no rim, no ring and no star glints, so it never reads as a
    /// chip or a token, and it stays apart from the faceted study gems and
    /// the dark black stones. The physics circle and mass are unchanged.
    private func configureAchievementCabochon(_ achievementKind: AchievementKind) {
        let rung = Self.cutLadder.achievement
        let (spec, palette) = Self.achievementArtwork(for: descriptor, kind: achievementKind)
        path = GemArtwork.outlinePath(for: spec, radius: localRadius)
        fillColor = .clear
        strokeColor = .clear
        lineWidth = 0
        glowWidth = 0
        installGemSkin(
            rung: rung,
            spec: spec,
            tone: GemTone(hex: palette.body.hexString, muted: false, glass: false),
            haloStrength: 1,
            haloColorOverride: palette.sheen.lighter(0.35).withAlpha(1),
            innerGlowAlpha: 0
        )
        addCabochonLight(palette)
        addAchievementMark(achievementKind)
    }

    /// The dome's light, in the screen-fixed rig and on the shared halo
    /// texture (one additive batch with the halos): the sheen of the
    /// kind's hue floating under the surface, and a soft oval highlight at
    /// the upper left where the key light meets the dome.
    private func addCabochonLight(_ palette: GemArtwork.CabochonPalette) {
        guard let rig = gemLightRigNode else { return }
        let sheen = Self.sharedLightSprite(
            GemTextureAtlas.SharedName.halo,
            size: CGSize(width: localRadius * 1.6, height: localRadius * 1.05)
        )
        sheen.name = "achievement.sheen"
        sheen.color = palette.sheen.withAlpha(1)
        sheen.colorBlendFactor = 1
        sheen.blendMode = .add
        sheen.alpha = 0.65
        sheen.position = Self.cabochonSheenRest(radius: localRadius)
        sheen.zPosition = JarZPosition.pebbleDetail - 0.40
        rig.addChild(sheen)
        cabochonSheenNode = sheen

        let highlight = Self.sharedLightSprite(
            GemTextureAtlas.SharedName.halo,
            size: CGSize(width: localRadius * 0.50, height: localRadius * 0.22)
        )
        highlight.name = "achievement.highlight"
        highlight.color = .white
        highlight.colorBlendFactor = 1
        highlight.blendMode = .add
        highlight.alpha = 1
        highlight.zRotation = .pi / 4
        highlight.position = Self.cabochonHighlightRest(radius: localRadius)
        highlight.zPosition = JarZPosition.pebbleDetail - 0.20
        rig.addChild(highlight)
        cabochonHighlightNode = highlight
    }

    private static func cabochonSheenRest(radius: CGFloat) -> CGPoint {
        CGPoint(x: radius * 0.04, y: radius * 0.18)
    }

    private static func cabochonHighlightRest(radius: CGFloat) -> CGPoint {
        CGPoint(x: -radius * 0.34, y: radius * 0.40)
    }

    /// Increase Contrast brightens facet edges.
    private static var edgeBoost: CGFloat {
        edgeBoost(increasedContrast: UIAccessibility.isDarkerSystemColorsEnabled)
    }

    private static func edgeBoost(increasedContrast: Bool) -> CGFloat {
        increasedContrast ? 0.2 : 0
    }

    private func installGemSkin(
        rung: GemCutRung,
        spec: GemArtworkSpec,
        tone: GemTone,
        haloStrength: CGFloat,
        haloColorOverride: UIColor? = nil,
        innerGlowAlpha: CGFloat = 0,
        haloParent: SKNode? = nil
    ) {
        gemRung = rung
        let body = SKSpriteNode(texture: nil, size: GemArtwork.bodySpriteSize(radius: localRadius))
        gemBodySpec = spec
        showGemBody(spec, on: body)
        body.name = "gem.body"
        body.zPosition = JarZPosition.pebbleDetail - 0.8
        addChild(body)
        gemBodyNode = body

        if innerGlowAlpha > 0 {
            let glow = Self.sharedLightSprite(
                GemTextureAtlas.SharedName.innerGlow,
                size: CGSize(width: localRadius * 2, height: localRadius * 2)
            )
            glow.name = "gem.innerGlow"
            glow.color = tone.innerGlowUIColor
            glow.colorBlendFactor = 1
            glow.blendMode = .add
            glow.zPosition = JarZPosition.pebbleDetail - 0.45
            addChild(glow)
            gemInnerGlowNode = glow
            gemInnerGlowBaseAlpha = innerGlowAlpha
        }

        // One shared additive texture for every halo: all halos in the jar
        // resolve to a single draw batch.
        let haloDiameter = localRadius * 2 * rung.haloScale
        let halo = Self.sharedLightSprite(
            GemTextureAtlas.SharedName.halo,
            size: CGSize(width: haloDiameter, height: haloDiameter)
        )
        halo.name = "gem.halo"
        halo.color = haloColorOverride ?? tone.haloUIColor
        halo.colorBlendFactor = 1
        halo.blendMode = .add
        gemHaloBaseAlpha = min(1, rung.haloAlpha * haloStrength)
        halo.zPosition = -0.6
        (haloParent ?? self).addChild(halo)
        gemHaloNode = halo
        applyHaloAlpha()
        applyLightEdgeFade()

        let rig = SKNode()
        rig.name = "gem.lightRig"
        addChild(rig)
        gemLightRigNode = rig

        let shadow = Self.sharedLightSprite(
            GemTextureAtlas.SharedName.shadow,
            size: CGSize(width: localRadius * 1.5, height: localRadius * 0.5)
        )
        shadow.name = "pebble.contactShadow"
        shadow.position = CGPoint(x: 0, y: -localRadius * 0.63)
        shadow.alpha = descriptor.isTutorial ? 0.16 : 0.38
        shadow.zPosition = -1
        rig.addChild(shadow)

        let shade = Self.sharedLightSprite(
            GemTextureAtlas.SharedName.lightShade,
            size: CGSize(width: localRadius * 2, height: localRadius * 2)
        )
        shade.name = "gem.rig.shade"
        shade.alpha = descriptor.isTutorial ? 0.5 : 1
        shade.zPosition = JarZPosition.pebbleDetail - 0.3
        rig.addChild(shade)

        let light = Self.sharedLightSprite(
            GemTextureAtlas.SharedName.lightAdd,
            size: CGSize(width: localRadius * 2, height: localRadius * 2)
        )
        light.name = "pebble.dimensionalLight"
        light.blendMode = .add
        light.alpha = descriptor.isTutorial ? 0.55 : (spec.isMuted ? 0.72 : 1)
        light.zPosition = JarZPosition.pebbleDetail - 0.25
        rig.addChild(light)
        dimensionalLightNode = light

        // Glint anchors come from the session UUID: upper-half vertices
        // (30°–170°, 0.45–0.75R). The rig keeps them on top while rolling.
        let hash = descriptor.id.presentationHash
        let glintTint = tone.glintUIColor
        for index in 0 ..< rung.glintCount {
            let bits = hash >> UInt64((index * 17) % 48)
            let angleUnit = CGFloat(bits & 0xFF) / 255
            let distanceUnit = CGFloat((bits >> 8) & 0xFF) / 255
            let angle = 30 + (angleUnit * 140 + CGFloat(index) * 47)
                .truncatingRemainder(dividingBy: 140)
            let distance = 0.45 + distanceUnit * 0.30
            let side = localRadius * rung.glintScale * (index == 0 ? 1 : 0.72)
            let glint = Self.sharedLightSprite(
                GemTextureAtlas.SharedName.glint,
                size: CGSize(width: side, height: side)
            )
            glint.name = "gem.glint"
            glint.color = glintTint
            glint.colorBlendFactor = 1
            glint.blendMode = .add
            let rest = CGPoint(
                x: cos(angle * .pi / 180) * localRadius * distance,
                y: sin(angle * .pi / 180) * localRadius * distance
            )
            glint.position = rest
            glint.zPosition = JarZPosition.pebbleDetail + 0.3
            rig.addChild(glint)
            gemGlintNodes.append(glint)
            gemGlintRestPositions.append(rest)
            let phaseBits = (hash >> UInt64(20 + index * 11)) & 0x3FF
            gemGlintPhases.append(CGFloat(phaseBits) / 1_023 * 2 - 1)
            glint.alpha = glintRestAlpha(index: index)
        }
    }

    /// Shows the gem body baked for `localRadius × textureJarScale` on a
    /// sprite sized back to local points, so a scaled gem is as crisp as one
    /// built at that size and its facets land on the collision circle.
    private func showGemBody(_ spec: GemArtworkSpec, on body: SKSpriteNode) {
        let jarScale = max(textureJarScale, 0.01)
        let bakedRadius = localRadius * jarScale
        let bodyScale = artworkScale
        // The marks the bake engraves (the same bucketed radius picks sector
        // or table marks), which the ×N tag keeps clear of.
        themeMarkExtent = spec.showsThemeMarks && aggregateTagNode != nil
            ? GemArtwork.themeMarkExtent(for: spec.colors, radius: GemArtwork.sizeBucket(radius: bakedRadius))
            : nil
        updateAggregateTagDrop()
        let baked = GemArtwork.bodySpriteSize(radius: bakedRadius)
        body.setUnscaledSize(CGSize(width: baked.width / jarScale, height: baked.height / jarScale))
        GemTextureAtlas.shared.show(
            GemArtwork.bodyTextureName(for: spec, radius: bakedRadius, scale: bodyScale),
            on: body
        ) {
            GemArtwork.renderBodyImage(for: spec, radius: bakedRadius, scale: bodyScale)
        }
    }

    /// Re-bakes the body (and the count engraving) for a new jar scale.
    /// Textures come from the atlas, so the scene bakes the misses of a
    /// whole transition in one parallel pass first.
    private func refreshBodyTexture(forJarScale target: CGFloat) {
        guard abs(target - textureJarScale) > 0.0001 else { return }
        textureJarScale = target
        if let spec = gemBodySpec, let body = gemBodyNode {
            showGemBody(spec, on: body)
        }
        if let obstacle = descriptor.screenTimeObstacle {
            if let rock = obstacleBodyNode {
                ScreenTimeObstacleAppearance.showBody(
                    descriptor: obstacle,
                    radius: localRadius,
                    scale: artworkScale,
                    textureJarScale: target,
                    on: rock
                )
            }
            if let count = obstacleCountNode, let text = ScreenTimeObstacleAppearance.countText(descriptor: obstacle) {
                ScreenTimeObstacleAppearance.showCount(
                    text,
                    radius: localRadius,
                    scale: artworkScale,
                    textureJarScale: target,
                    on: count
                )
            }
        }
        showAggregateTag()
        showAchievementEngraving()
    }

    /// The bake spec the body shows now (nil for obstacles and the legacy
    /// rare materials).
    var displayedBodySpec: GemArtworkSpec? { gemBodySpec }

    /// Differentiate Without Color turned on or off: study gems and
    /// crystals re-bake with or without their theme marks. Achievement
    /// stones and the tutorial glass never carry one.
    func setThemeMarks(_ enabled: Bool) {
        guard let spec = gemBodySpec,
              !descriptor.isAchievement,
              !descriptor.isTutorial,
              spec.showsThemeMarks != enabled
        else { return }
        let updated = spec.withThemeMarks(enabled)
        gemBodySpec = updated
        if let body = gemBodyNode {
            showGemBody(updated, on: body)
        }
    }

    /// Increase Contrast turned on or off while the jar is shown (round
    /// 14): the facet edges re-bake with (or without) their boost and a
    /// 記念石's engraving with its deeper groove, so nothing waits for the
    /// next restore. Obstacles have no gem body and no engraving.
    func setIncreasedContrast(_ enabled: Bool) {
        let boost = Self.edgeBoost(increasedContrast: enabled)
        if var spec = gemBodySpec, spec.edgeBoost != boost {
            spec.edgeBoost = boost
            gemBodySpec = spec
            if let body = gemBodyNode {
                showGemBody(spec, on: body)
            }
        }
        showAchievementEngraving(increasedContrast: enabled)
    }

    /// The count tag sized for the crystal's scene radius at the bake scale.
    /// With Pro's month engraving (D21) the tag grows a second line below
    /// the count, and its anchor keeps the count line exactly where the
    /// single-line tag had it (0.40R below the centre).
    private func showAggregateTag() {
        guard let tag = aggregateTagNode, let text = aggregateTagText else { return }
        let fontSize = GemArtwork.countTagFontSize(sceneRadius: localRadius * textureJarScale)
        let month = aggregateTagMonth
        let size = GemArtwork.countEngravingSize(text: text, fontSize: fontSize, style: .copperTag, month: month)
        tag.setUnscaledSize(size)
        let countLine = GemArtwork.countEngravingCountLineHeight(fontSize: fontSize)
        tag.anchorPoint = CGPoint(
            x: 0.5,
            y: month == nil ? 0.5 : 1 - countLine / 2 / max(size.height, 1)
        )
        let scale = artworkScale
        GemTextureAtlas.shared.show(
            GemArtwork.countEngravingTextureName(text: text, fontSize: fontSize, style: .copperTag, scale: scale, month: month),
            on: tag
        ) {
            GemArtwork.countEngravingImage(text: text, fontSize: fontSize, style: .copperTag, scale: scale, month: month)
        }
    }

    /// D21 (Pro): engrave (or remove) the crystal's month under its count.
    /// Only the tag changes: the cut, light, radius and halo of a crystal
    /// never depend on Pro.
    func setMonthEngraving(_ enabled: Bool) {
        guard showsMonthEngraving != enabled else { return }
        showsMonthEngraving = enabled
        aggregateTagMonth = Self.monthEngraving(for: descriptor, enabled: enabled)
        showAggregateTag()
    }

    private static func monthEngraving(for descriptor: PebbleDescriptor, enabled: Bool) -> String? {
        guard enabled, descriptor.isAggregate else { return nil }
        return GemArtwork.monthHallmark(for: descriptor.createdAt)
    }

    /// A shared light sprite on the gem atlas page (see `GemTextureAtlas`).
    private static func sharedLightSprite(_ name: String, size: CGSize) -> SKSpriteNode {
        let sprite = SKSpriteNode(texture: nil, size: size)
        GemTextureAtlas.shared.showShared(name, on: sprite)
        return sprite
    }

    private func glintRestAlpha(index: Int) -> CGFloat {
        // Reduce Motion and 控えめ: one static star per gem, no tilt glints.
        if !effects.allowsTiltGlints {
            return index == 0 ? Self.reducedMotionStarAlpha : 0
        }
        return Self.glintRestAlpha
    }

    private func applyHaloAlpha() {
        let effects = effects
        gemHaloNode?.alpha = min(1, gemHaloBaseAlpha * gemHaloEmphasis)
            * (reducesTransparency ? 0.45 : 1) * effects.haloScale
        gemInnerGlowNode?.alpha = gemInnerGlowBaseAlpha * (reducesTransparency ? 0.6 : 1)
            * effects.innerGlowScale
    }

    /// Inner light of a loose study gem (additive, over the facets).
    static let looseInnerGlowAlpha: CGFloat = 0.56

    /// Current halo alpha (tests and the scene's pile light).
    var gemHaloAlpha: CGFloat { gemHaloNode?.alpha ?? 0 }

    func setReduceTransparency(_ enabled: Bool) {
        guard reducesTransparency != enabled else { return }
        reducesTransparency = enabled
        applyHaloAlpha()
        applyEarlyEffortAlpha()
    }

    /// The aggregate holding the most grams in the pile glows 10 % more.
    func setPileEmphasis(_ emphasized: Bool) {
        // Round 12 (casino review): only the emphasised crystal's copper tag
        // shows at full size; the others step back to 70 % and α0.75, so a
        // pile of crystals never reads as a row of chip values. The text
        // and the D21 month line stay (the tag is only smaller).
        let tagEmphasis: CGFloat = emphasized ? 1 : Self.quietTagScale
        if aggregateTagEmphasis != tagEmphasis {
            aggregateTagEmphasis = tagEmphasis
            aggregateTagNode?.alpha = emphasized ? 1 : Self.quietTagAlpha
            updateSemanticLabelScale()
        }
        let value: CGFloat = emphasized ? 1.1 : 1
        guard gemHaloEmphasis != value else { return }
        gemHaloEmphasis = value
        applyHaloAlpha()
    }

    /// A crystal's copper tag when another crystal in the pile is the
    /// emphasised one (`setPileEmphasis`).
    static let quietTagScale: CGFloat = 0.7
    static let quietTagAlpha: CGFloat = 0.75

    private static let gemTwinkleKey = "gem.glint.twinkle"

    /// Eligible for the scene's bounded twinkle scheduler (ignores cooldown;
    /// see `canGemTwinkle(at:)`).
    var canGemTwinkle: Bool {
        !gemGlintNodes.isEmpty && !isRemovedForBake && effects.allowsSpontaneousTwinkle
    }

    func canGemTwinkle(at time: TimeInterval) -> Bool {
        canGemTwinkle && time - lastGemTwinkleTime >= Self.gemTwinkleCooldown
    }

    var isGemTwinkling: Bool {
        gemGlintNodes.contains { $0.action(forKey: Self.gemTwinkleKey) != nil }
    }

    var gemTwinkleWeight: Int { gemGlintNodes.count }

    /// One short star flare (420 ms, ≤ 1.25×). Alpha follows the flare's
    /// scale in `updatePresentationLighting`, so tilt and twinkle compose.
    func playGemTwinkle(sequence: UInt64, at time: TimeInterval = 0) {
        guard canGemTwinkle else { return }
        lastGemTwinkleTime = time
        let glint = gemGlintNodes[Int(sequence % UInt64(gemGlintNodes.count))]
        glint.removeAction(forKey: Self.gemTwinkleKey)
        glint.setScale(1)
        glint.zRotation = 0
        let rise = SKAction.group([
            .scale(to: Self.gemTwinkleScale, duration: Self.gemTwinkleRise),
            .rotate(byAngle: 0.20, duration: Self.gemTwinkleRise)
        ])
        rise.timingMode = .easeOut
        let fall = SKAction.group([
            .scale(to: 1, duration: Self.gemTwinkleFall),
            .rotate(byAngle: 0.08, duration: Self.gemTwinkleFall)
        ])
        fall.timingMode = .easeIn
        glint.run(
            .sequence([
                rise,
                .wait(forDuration: Self.gemTwinkleHold),
                fall,
                .run { [weak glint] in glint?.zRotation = 0 }
            ]),
            withKey: Self.gemTwinkleKey
        )
    }

    static let landingPulseKey = "gem.halo.landing"

    /// Landing beat (`JarEffectsIntensity.landing`): at 標準 the halo swells
    /// (to 0.95 in 80 ms, back in 360 ms) and the first star flares once; at
    /// 控えめ it swells halfway (60 ms, back in 200 ms) and no star flares.
    /// Nothing runs under Reduce Motion.
    func playLandingPulse() {
        guard !reducesVisualMotion, let halo = gemHaloNode else { return }
        let beat = effects.landing
        halo.removeAction(forKey: Self.landingPulseKey)
        applyHaloAlpha()
        let base = halo.alpha
        let full = max(base, 0.95 * (reducesTransparency ? 0.45 : 1))
        let peak = base + (full - base) * beat.haloSwell
        let rise = SKAction.fadeAlpha(to: peak, duration: beat.haloRise)
        let fall = SKAction.fadeAlpha(to: base, duration: beat.haloFall)
        fall.timingMode = .easeOut
        halo.run(.sequence([rise, fall]), withKey: Self.landingPulseKey)
        if beat.flaresStar, !gemGlintNodes.isEmpty {
            playGemTwinkle(sequence: 0, at: lastGemTwinkleTime)
        }
    }

    /// Stops any flare and returns every glint to its resting alpha. Called
    /// on Reduce Motion, before the idle pause freezes the scene, and before
    /// a snapshot, so a frozen frame never keeps a half-lit star.
    func settleGemTwinkle() {
        for (index, glint) in gemGlintNodes.enumerated() {
            glint.removeAction(forKey: Self.gemTwinkleKey)
            glint.setScale(1)
            glint.zRotation = 0
            glint.alpha = glintRestAlpha(index: index)
        }
    }

    /// Additive light composites incorrectly into a transparent snapshot
    /// texture; while capturing, bake it as ordinary alpha-blended light.
    func setSnapshotBlending(_ capturing: Bool) {
        let additive: [SKSpriteNode?] = [gemHaloNode, gemInnerGlowNode, dimensionalLightNode, earlyEffortAuraNode, earlyEffortBloomNode, earlyEffortPoolNode, cabochonSheenNode, cabochonHighlightNode]
        for node in additive.compactMap({ $0 }) + gemGlintNodes {
            node.blendMode = capturing ? .alpha : .add
        }
    }

    private var baseLooseFill: UIColor {
        var fill = subjectColor
        if descriptor.isTutorial {
            fill = JarPalette.glass.withAlphaComponent(Constants.Jar.tutorialOpacity)
        } else {
            // The same lightness-ordered tone as the faceted gems (§7.4).
            fill = GemTone(hex: descriptor.colorHex, muted: false, glass: false).body.withAlpha(1)
        }
        if !descriptor.isMeasured {
            fill = fill.reducingSaturation(by: Constants.Jar.manualSaturationReduction)
        }
        return fill
    }

    private func configureLooseGemMaterial(fill: UIColor) {
        let enhanced = rareRewardMode.usesEnhancedPresentation
        switch presentationKind {
        case .normal:
            return
        case .gold:
            fillShader = nil
            fillColor = enhanced
                ? JarPalette.gold
                : fill.mixed(with: JarPalette.gold, amount: 0.26)
            strokeColor = enhanced
                ? JarPalette.goldHighlight
                : JarPalette.goldHighlight.withAlphaComponent(0.68)
            lineWidth = max(1.1, localRadius * 0.10)
            glowWidth = localRadius * (enhanced ? Constants.Jar.goldGlowScale : 0.10)
        case .prism:
            fillColor = enhanced ? .white : fill.mixed(with: .white, amount: 0.18)
            strokeColor = .white.withAlphaComponent(
                enhanced ? Constants.Jar.prismStrokeOpacity : 0.62
            )
            lineWidth = max(1.05, localRadius * 0.09)
            glowWidth = localRadius * (enhanced ? Constants.Jar.prismGlowScale : 0.10)
            fillShader = enhanced
                ? (reducesVisualMotion ? Self.staticPrismShader : Self.prismShader)
                : nil
        }
    }

    private static func makeStonePath(radius: CGFloat, id: UUID) -> CGPath {
        let pointCount = 10
        var seed: UInt64 = 1_469_598_103_934_665_603
        for byte in id.uuidString.utf8 {
            seed ^= UInt64(byte)
            seed &*= 1_099_511_628_211
        }

        var points: [CGPoint] = []
        points.reserveCapacity(pointCount)
        for index in 0..<pointCount {
            var value = seed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15
            value ^= value >> 30
            value &*= 0xBF58_476D_1CE4_E5B9
            value ^= value >> 27
            value &*= 0x94D0_49BB_1331_11EB
            value ^= value >> 31
            let unit = CGFloat(value % 10_001) / 10_000
            let radialVariation = 0.90 + unit * 0.12
            let angle = CGFloat(index) / CGFloat(pointCount) * .pi * 2
            points.append(CGPoint(
                x: cos(angle) * radius * radialVariation * 1.035,
                y: sin(angle) * radius * radialVariation * 0.965
            ))
        }

        let path = CGMutablePath()
        guard let first = points.first, let last = points.last else {
            return CGPath(ellipseIn: CGRect(
                x: -radius,
                y: -radius,
                width: radius * 2,
                height: radius * 2
            ), transform: nil)
        }
        path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
        for index in points.indices {
            let control = points[index]
            let next = points[(index + 1) % points.count]
            path.addQuadCurve(
                to: CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2),
                control: control
            )
        }
        path.closeSubpath()
        return path
    }

    private func addContactShadow() {
        let shadow = SKShapeNode(
            ellipseOf: CGSize(width: localRadius * 1.58, height: localRadius * 0.54)
        )
        shadow.name = "pebble.contactShadow"
        shadow.fillColor = UIColor(red: 0.015, green: 0.03, blue: 0.07, alpha: 0.38)
        shadow.strokeColor = UIColor.black.withAlphaComponent(0.12)
        shadow.lineWidth = max(0.5, localRadius * 0.035)
        shadow.glowWidth = localRadius * 0.14
        shadow.alpha = descriptor.isTutorial ? 0.12 : 0.44
        shadow.position = CGPoint(x: 0, y: -localRadius * 0.63)
        shadow.zPosition = -1
        addChild(shadow)
        contactShadowNode = shadow

        let caustic = SKShapeNode(
            ellipseOf: CGSize(width: localRadius * 1.22, height: localRadius * 0.28)
        )
        caustic.name = "pebble.contactCaustic"
        caustic.fillColor = visualAccentColor.withAlphaComponent(
            descriptor.isTutorial ? 0.03 : 0.16
        )
        caustic.strokeColor = UIColor.white.withAlphaComponent(0.12)
        caustic.lineWidth = max(0.45, localRadius * 0.025)
        caustic.glowWidth = localRadius * 0.19
        caustic.position = CGPoint(x: 0, y: -localRadius * 0.63)
        caustic.zPosition = -0.8
        addChild(caustic)
        contactCausticNode = caustic
    }

    private var visualAccentColor: UIColor {
        if let achievementKind = descriptor.achievementKind {
            return JarPalette.achievementMaterial(for: achievementKind).glow
        }
        if let aggregate = descriptor.aggregate {
            return JarPalette.color(hex: aggregate.dominantColorHex)
                .vivid(saturationFloor: 0.70, brightnessFloor: 0.82)
        }
        switch presentationKind {
        case .gold:
            return rareRewardMode.usesEnhancedPresentation
                ? JarPalette.gold
                : subjectColor.vivid()
        case .prism:
            return rareRewardMode.usesEnhancedPresentation
                ? JarPalette.specular
                : subjectColor.vivid()
        case .normal:
            return subjectColor.vivid()
        }
    }

    private func addRareMarkIfNeeded() {
        let markText: String
        switch presentationKind {
        case .normal:
            return
        case .gold:
            markText = "✦"
        case .prism:
            markText = "◇"
        }

        let ring = SKShapeNode(circleOfRadius: localRadius * 0.69)
        ring.name = "rare.innerRing"
        ring.fillColor = .clear
        ring.strokeColor = UIColor.white.withAlphaComponent(0.26)
        ring.lineWidth = max(0.8, localRadius * 0.06)
        ring.zPosition = JarZPosition.pebbleDetail + 0.4
        addChild(ring)

        let mark = SKLabelNode(fontNamed: "AvenirNext-Bold")
        mark.name = "rare.mark"
        mark.text = markText
        mark.fontSize = localRadius * (presentationKind == .gold ? 0.82 : 0.74)
        mark.fontColor = UIColor.white.withAlphaComponent(0.94)
        mark.verticalAlignmentMode = .center
        mark.horizontalAlignmentMode = .center
        mark.zPosition = JarZPosition.pebbleDetail + 0.5
        addChild(mark)
        updateRareMarkPresentation()
    }

    private func updateRareMarkPresentation() {
        let alpha: CGFloat = rareRewardMode.usesEnhancedPresentation ? 1 : 0.70
        childNode(withName: "rare.innerRing")?.alpha = alpha
        childNode(withName: "rare.mark")?.alpha = alpha
    }

    private func configureAggregateAppearance(_ aggregate: AggregateMetadata) {
        // Cut, light budget and halo follow the grams the crystal holds
        // (A0…A4), never its decimal level or pebble count.
        let rung = Self.cutLadder.rung(aggregateGrams: descriptor.grams)
        let spec = Self.aggregateSpec(for: descriptor, aggregate: aggregate)
        // The container draws nothing: no neon rim, no glowWidth. The earned
        // bloom is the shared Gaussian halo inside `aggregate.aura`, whose
        // gentle breath (scale only) keeps the existing action key.
        path = GemArtwork.outlinePath(for: spec, radius: localRadius)
        fillColor = .clear
        strokeColor = .clear
        lineWidth = 0
        glowWidth = 0

        let aura = SKNode()
        aura.name = "aggregate.aura"
        aura.zPosition = 0
        addChild(aura)
        aggregateAuraNode = aura

        installGemSkin(
            rung: rung,
            spec: spec,
            tone: GemTone(hex: aggregate.dominantColorHex, muted: spec.isMuted, glass: false),
            haloStrength: aggregateHaloStrength(aggregate),
            innerGlowAlpha: spec.isMuted ? 0.30 : 0.44,
            haloParent: aura
        )
        updateAggregateRarePresentation(aggregate)
        configureAggregateAuraMotion()

        if presentsRareRewardFeature,
           rareRewardMode.usesEnhancedPresentation,
           aggregate.goldPebbleCount > 0 || aggregate.prismPebbleCount > 0 {
            let composition = SKSpriteNode(
                texture: Self.makeAggregateRareTexture(radius: localRadius, aggregate: aggregate),
                size: CGSize(width: localRadius * 2, height: localRadius * 2)
            )
            composition.name = "aggregate.composition"
            composition.zPosition = JarZPosition.pebbleDetail
            addChild(composition)
        }

        // D26 (b): the count on a small engraved copper tag in the neck
        // collar's material, upright below the table. The text is exactly
        // the former plate's; the tag keeps its own on-screen size at every
        // jar scale (counter-scaled), so the jar never shows a big number.
        let tag = SKSpriteNode(texture: nil, size: .zero)
        tag.name = "aggregate.tag"
        tag.zPosition = JarZPosition.pebbleDetail + 0.9
        tag.blendMode = .alpha
        tag.position = CGPoint(x: 0, y: -localRadius * Self.aggregatePlateDrop)
        addChild(tag)
        aggregateTagNode = tag
        aggregateTagText = AggregatePresentation.countLabel(aggregate.pebbleCount)
        aggregateTagMonth = Self.monthEngraving(for: descriptor, enabled: showsMonthEngraving)
        showAggregateTag()
        // The body was baked before the tag existed: read its marks now.
        if let spec = gemBodySpec, spec.showsThemeMarks {
            themeMarkExtent = GemArtwork.themeMarkExtent(
                for: spec.colors,
                radius: GemArtwork.sizeBucket(radius: localRadius * max(textureJarScale, 0.01))
            )
        }
        updateAggregateTagDrop()
    }

    /// Glow follows recorded grams, never the number of completions, so
    /// splitting the same focus into many one-minute sessions cannot buy a
    /// brighter crystal.
    private func aggregateHaloStrength(_ aggregate: AggregateMetadata) -> CGFloat {
        let nominal = CGFloat(max(1, aggregate.pebbleCount))
            * CGFloat(max(1, Constants.Mass.measuredPebbleGrams))
        let ratio = CGFloat(max(0, descriptor.grams)) / nominal
        return 0.55 + 0.45 * min(max(ratio, 0.25), 1)
    }

    /// Internal builds only (rare rewards are off in release): an enhanced
    /// rare aggregate may glow a little more; quiet and off never dim the
    /// earned base glow.
    private func updateAggregateRarePresentation(_ aggregate: AggregateMetadata) {
        let containsEnhancedRare = presentsRareRewardFeature
            && rareRewardMode.usesEnhancedPresentation
            && (aggregate.goldPebbleCount > 0 || aggregate.prismPebbleCount > 0)
        let rung = gemRung ?? Self.cutLadder.rung(aggregateGrams: descriptor.grams)
        gemHaloBaseAlpha = min(
            1,
            rung.haloAlpha * aggregateHaloStrength(aggregate) * (containsEnhancedRare ? 1.25 : 1)
        )
        applyHaloAlpha()
    }

    private func configureAggregateAuraMotion() {
        guard let aura = aggregateAuraNode else { return }
        let actionKey = "aggregate.aura.breath"
        aura.removeAction(forKey: actionKey)
        aura.setScale(1)
        guard effects.allowsBreathing else { return }

        let tier = GemCutLadder.aggregateTier(grams: descriptor.grams)
        let amplitude = min(1.06, 1.025 + CGFloat(tier) * 0.008)
        let duration = max(1.8, 2.7 - Double(tier) * 0.12)
        let expand = SKAction.scale(to: amplitude, duration: duration / 2)
        expand.timingMode = .easeInEaseOut
        let contract = SKAction.scale(to: 1, duration: duration / 2)
        contract.timingMode = .easeInEaseOut
        aura.run(.repeatForever(.sequence([expand, contract])), withKey: actionKey)
    }

    /// Rare-reward marks for an aggregate (internal builds only; rare
    /// rewards are disabled in release). Facets now come from `GemArtwork`.
    private static func makeAggregateRareTexture(
        radius: CGFloat,
        aggregate: AggregateMetadata
    ) -> SKTexture {
        let size = CGSize(width: radius * 2, height: radius * 2)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            if aggregate.goldPebbleCount > 0 {
                context.setFillColor(JarPalette.gold.withAlphaComponent(0.95).cgColor)
                drawAggregateFacet(
                    in: context,
                    center: CGPoint(x: radius * 1.61, y: radius * 0.41),
                    size: radius * 0.13
                )
            }
            if aggregate.prismPebbleCount > 0 {
                context.setFillColor(UIColor.white.withAlphaComponent(0.95).cgColor)
                drawAggregateFacet(
                    in: context,
                    center: CGPoint(x: radius * 0.40, y: radius * 1.58),
                    size: radius * 0.12
                )
            }
        }
        return SKTexture(image: image)
    }

    private static func drawAggregateFacet(
        in context: CGContext,
        center: CGPoint,
        size: CGFloat
    ) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x, y: center.y - size))
        path.addLine(to: CGPoint(x: center.x + size * 0.82, y: center.y))
        path.addLine(to: CGPoint(x: center.x, y: center.y + size))
        path.addLine(to: CGPoint(x: center.x - size * 0.82, y: center.y))
        path.closeSubpath()
        context.addPath(path)
        context.fillPath()
    }

    /// The mark (✓, W, 100) engraved in the dome (round 13): one upright
    /// sprite baked for the size the stone shows, under the rig's light so
    /// the shade and the highlight fall over it as over the dome. VoiceOver
    /// keeps the kind's title.
    private func addAchievementMark(_ achievementKind: AchievementKind) {
        let mark = SKSpriteNode(texture: nil, size: CGSize(width: 1, height: 1))
        mark.name = "achievement.mark"
        mark.zPosition = JarZPosition.pebbleDetail - 0.35
        mark.blendMode = .alpha
        mark.accessibilityLabel = achievementKind.title
        addChild(mark)
        achievementMarkNode = mark
        showAchievementEngraving()
    }

    /// Bakes (or reuses) the engraving for `localRadius × textureJarScale`
    /// and sizes it back to local points, like the body.
    private func showAchievementEngraving(increasedContrast override: Bool? = nil) {
        guard let mark = achievementMarkNode, let kind = descriptor.achievementKind else { return }
        let increasedContrast = override ?? UIAccessibility.isDarkerSystemColorsEnabled
        let jarScale = max(textureJarScale, 0.01)
        let text = kind.shortMark
        let hex = kind.gemBaseHex
        let fontSize = GemArtwork.achievementEngravingFontSize(mark: text, sceneRadius: localRadius * jarScale)
        let size = GemArtwork.achievementEngravingSize(mark: text, fontSize: fontSize)
        mark.setUnscaledSize(CGSize(width: size.width / jarScale, height: size.height / jarScale))
        let scale = artworkScale
        GemTextureAtlas.shared.show(
            GemArtwork.achievementEngravingTextureName(
                mark: text,
                hex: hex,
                fontSize: fontSize,
                scale: scale,
                increasedContrast: increasedContrast
            ),
            on: mark
        ) {
            GemArtwork.achievementEngravingImage(
                mark: text,
                hex: hex,
                fontSize: fontSize,
                scale: scale,
                increasedContrast: increasedContrast
            )
        }
    }

    private func addCachedDetailTexture() {
        let variantCount = max(Constants.Jar.speckleCount, 1)
        let byteSum = descriptor.id.uuidString.utf8.reduce(Int.zero) {
            $0 + Int($1)
        }
        let variant = byteSum % variantCount
        let key = NSString(
            string: "\(localRadius)-\(descriptor.isMeasured)-\(variant)"
        )
        let texture: SKTexture
        if let cached = Self.detailTextureCache.object(forKey: key) {
            texture = cached
        } else {
            texture = Self.makeDetailTexture(
                radius: localRadius,
                isMeasured: descriptor.isMeasured,
                variant: variant
            )
            Self.detailTextureCache.setObject(texture, forKey: key)
        }

        let detail = SKSpriteNode(
            texture: texture,
            size: CGSize(width: localRadius * 2, height: localRadius * 2)
        )
        detail.zPosition = JarZPosition.pebbleDetail
        addChild(detail)
    }

    private func addDimensionalOverlay() {
        let texture = Self.makeDimensionalTexture(radius: localRadius)
        let light = SKSpriteNode(
            texture: texture,
            size: CGSize(width: localRadius * 1.78, height: localRadius * 1.78)
        )
        light.name = "pebble.dimensionalLight"
        light.zPosition = JarZPosition.pebbleDetail - 0.25
        addChild(light)
        dimensionalLightNode = light
    }

    private static let detailTextureCache = NSCache<NSString, SKTexture>()

    private static func makeDetailTexture(
        radius: CGFloat,
        isMeasured: Bool,
        variant: Int
    ) -> SKTexture {
        let size = CGSize(width: radius * 2, height: radius * 2)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            if isMeasured {
                let highlight = CGMutablePath()
                highlight.move(to: CGPoint(x: radius * 0.38, y: radius * 0.52))
                highlight.addCurve(
                    to: CGPoint(x: radius * 0.84, y: radius * 0.31),
                    control1: CGPoint(x: radius * 0.50, y: radius * 0.30),
                    control2: CGPoint(x: radius * 0.70, y: radius * 0.24)
                )
                highlight.addLine(to: CGPoint(x: radius * 0.72, y: radius * 0.62))
                highlight.addCurve(
                    to: CGPoint(x: radius * 0.38, y: radius * 0.52),
                    control1: CGPoint(x: radius * 0.58, y: radius * 0.64),
                    control2: CGPoint(x: radius * 0.45, y: radius * 0.60)
                )
                highlight.closeSubpath()
                context.setFillColor(JarPalette.warmSpecular.withAlphaComponent(0.28).cgColor)
                context.addPath(highlight)
                context.fillPath()
            } else {
                let dashCount = max(Constants.Jar.manualDashCount, 1)
                let ringRadius = radius * 0.82
                let dashLength = 2 * CGFloat.pi * ringRadius / CGFloat(dashCount * 2)
                context.setStrokeColor(UIColor.white.withAlphaComponent(0.52).cgColor)
                context.setLineWidth(max(Constants.Jar.outlineWidth * 0.42, 0.8))
                context.setLineCap(.round)
                context.setLineDash(phase: .zero, lengths: [dashLength, dashLength])
                context.strokeEllipse(
                    in: CGRect(
                        x: radius - ringRadius,
                        y: radius - ringRadius,
                        width: ringRadius * 2,
                        height: ringRadius * 2
                    )
                )
            }

            let shift = (CGFloat(variant % 5) - 2) * radius * 0.018
            let joint = CGPoint(x: radius * 0.96 + shift, y: radius * 0.98 - shift)
            let anchors = [
                CGPoint(x: radius * 0.34, y: radius * 0.38),
                CGPoint(x: radius * 1.02, y: radius * 0.20),
                CGPoint(x: radius * 1.61, y: radius * 0.56),
                CGPoint(x: radius * 1.55, y: radius * 1.38),
                CGPoint(x: radius * 0.94, y: radius * 1.67),
                CGPoint(x: radius * 0.30, y: radius * 1.26)
            ]

            let lightFacet = CGMutablePath()
            lightFacet.move(to: anchors[0])
            lightFacet.addLine(to: anchors[1])
            lightFacet.addLine(to: joint)
            lightFacet.closeSubpath()
            context.setFillColor(UIColor.white.withAlphaComponent(0.13).cgColor)
            context.addPath(lightFacet)
            context.fillPath()

            let shadeFacet = CGMutablePath()
            shadeFacet.move(to: joint)
            shadeFacet.addLine(to: anchors[3])
            shadeFacet.addLine(to: anchors[4])
            shadeFacet.closeSubpath()
            context.setFillColor(UIColor.black.withAlphaComponent(0.055).cgColor)
            context.addPath(shadeFacet)
            context.fillPath()

            context.setStrokeColor(UIColor.white.withAlphaComponent(0.20).cgColor)
            context.setLineWidth(max(0.42, radius * 0.038))
            context.setLineCap(.round)
            for anchor in anchors {
                context.move(to: joint)
                context.addLine(to: anchor)
            }
            context.strokePath()
        }
        return SKTexture(image: image)
    }

    private static func makeDimensionalTexture(radius: CGFloat) -> SKTexture {
        let key = NSString(string: "dimensional-\(radius)")
        if let cached = detailTextureCache.object(forKey: key) { return cached }
        let size = CGSize(width: radius * 2, height: radius * 2)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            drawDimensionalLight(in: renderer.cgContext, radius: radius)
        }
        let texture = SKTexture(image: image)
        detailTextureCache.setObject(texture, forKey: key)
        return texture
    }

    private static func drawDimensionalLight(in context: CGContext, radius: CGFloat) {
        context.saveGState()
        context.addEllipse(in: CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2))
        context.clip()
        let colors = [
            JarPalette.warmSpecular.withAlphaComponent(0.34).cgColor,
            UIColor.white.withAlphaComponent(0.06).cgColor,
            UIColor.black.withAlphaComponent(0.17).cgColor
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 0.48, 1]
        ) {
            context.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: radius * 0.54, y: radius * 0.46),
                startRadius: radius * 0.05,
                endCenter: CGPoint(x: radius * 1.08, y: radius * 1.12),
                endRadius: radius * 1.32,
                options: [.drawsAfterEndLocation]
            )
        }

        // A faint cool bounce light at the lower edge separates touching stones
        // without outlining every object like a flat icon.
        let bounceColors = [
            UIColor(red: 0.55, green: 0.80, blue: 1, alpha: 0.14).cgColor,
            UIColor.clear.cgColor
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: bounceColors,
            locations: [0, 1]
        ) {
            context.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: radius * 0.44, y: radius * 1.78),
                startRadius: 0,
                endCenter: CGPoint(x: radius * 0.44, y: radius * 1.78),
                endRadius: radius * 0.82,
                options: [.drawsAfterEndLocation]
            )
        }

        context.setStrokeColor(JarPalette.warmSpecular.withAlphaComponent(0.18).cgColor)
        context.setLineWidth(max(0.65, radius * 0.05))
        context.addArc(
            center: CGPoint(x: radius, y: radius),
            radius: radius * 0.78,
            startAngle: .pi * 0.92,
            endAngle: .pi * 1.56,
            clockwise: false
        )
        context.strokePath()
        context.restoreGState()
    }

    private static let prismShader = SKShader(source: """
        void main() {
            float phase = u_time * 0.18;
            vec3 rainbow = 0.58 + 0.42 * cos(
                6.2831853 * (phase + vec3(0.00, 0.33, 0.67))
            );
            gl_FragColor = vec4(rainbow, 1.0) * v_color_mix;
        }
        """)

    private static let staticPrismShader = SKShader(source: """
        void main() {
            vec2 centered = v_tex_coord - vec2(0.5);
            float angle = atan(centered.y, centered.x) / 6.2831853;
            vec3 rainbow = 0.58 + 0.42 * cos(
                6.2831853 * (angle + vec3(0.00, 0.33, 0.67))
            );
            gl_FragColor = vec4(rainbow, 1.0) * v_color_mix;
        }
        """)
}

extension SKSpriteNode {
    /// Sets the sprite's own size in its local space. `size` alone is the
    /// scaled size, so on a counter-scaled tag it would fold the scale in.
    func setUnscaledSize(_ unscaled: CGSize) {
        let scale = (x: xScale, y: yScale)
        xScale = 1
        yScale = 1
        size = unscaled
        xScale = scale.x
        yScale = scale.y
    }
}

enum JarPhysicsCategory {
    static let pebble: UInt32 = 1 << 0
    static let wall: UInt32 = 1 << 1
    static let floor: UInt32 = 1 << 2
}

enum JarZPosition {
    static let background: CGFloat = -10
    static let strata: CGFloat = -2
    static let pebble: CGFloat = 2
    static let pebbleDetail: CGFloat = 1
    static let effect: CGFloat = 10
    static let glass: CGFloat = 20

    /// Per-body stacking offset. The jar's SKView ignores sibling order so
    /// SpriteKit may batch; each body's own offset (insertion order) then
    /// decides ties exactly as the node tree used to, while the whole span
    /// (0.04) stays below the smallest gap between two layers of one body
    /// (0.05), so every layer of every body remains one contiguous band.
    static let stackingStep: CGFloat = 0.000_01
    static let stackingSlots = 4_000
    static var stackingSpan: CGFloat { stackingStep * CGFloat(stackingSlots) }

    static func pebble(stackingIndex: Int) -> CGFloat {
        pebble + stackingStep * CGFloat(min(max(stackingIndex, 0), stackingSlots - 1))
    }
}

enum JarPalette {
    static let gold = color(hex: "FFC83D")
    static let goldHighlight = color(hex: "FFF0A0")
    static let glass = color(hex: Constants.Color.glassEdge)
        .withAlphaComponent(Constants.Color.glassEdgeOpacity)
    static let glassEdge = color(hex: Constants.Color.glassEdge).withAlphaComponent(0.76)
    static let backGlass = color(hex: Constants.Color.glassAbsorption).withAlphaComponent(0.20)
    static let deepGlassEdge = color(hex: Constants.Color.auroraViolet).withAlphaComponent(0.18)
    static let glassBase = color(hex: Constants.Color.floorGlow).withAlphaComponent(0.14)
    static let mouthDepth = UIColor(red: 0.025, green: 0.075, blue: 0.14, alpha: 0.48)
    static let lensShade = color(hex: Constants.Color.auroraViolet).withAlphaComponent(0.10)
    static let specular = color(hex: Constants.Color.auroraCool).mixed(with: .white, amount: 0.32)
        .withAlphaComponent(0.72)
    static let warmSpecular = color(hex: Constants.Color.auroraWarm).mixed(with: .white, amount: 0.18)
        .withAlphaComponent(0.72)
    static let aggregateCore = color(hex: Constants.Color.inkRaised)

    static func achievementMaterial(
        for kind: AchievementKind
    ) -> (base: UIColor, edge: UIColor, glow: UIColor) {
        (
            color(hex: kind.gemBaseHex),
            color(hex: kind.gemEdgeHex),
            color(hex: kind.gemGlowHex)
        )
    }

    static func color(hex: String) -> UIColor {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard clean.count == 6, let value = UInt64(clean, radix: 16) else {
            return color(hex: Constants.Color.textMute)
        }
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

private extension UIColor {
    /// Near-white star with a hint of the gem colour.
    func mixedForGlint() -> UIColor {
        UIColor.white.mixed(with: self, amount: 0.22)
    }

    func vivid(
        saturationFloor: CGFloat = 0.74,
        brightnessFloor: CGFloat = 0.88
    ) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ) else { return self }
        return UIColor(
            hue: hue,
            saturation: max(saturation, saturationFloor),
            brightness: max(brightness, brightnessFloor),
            alpha: alpha
        )
    }

    func mixed(with other: UIColor, amount: CGFloat) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        var otherRed: CGFloat = 0
        var otherGreen: CGFloat = 0
        var otherBlue: CGFloat = 0
        var otherAlpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha),
              other.getRed(
                &otherRed,
                green: &otherGreen,
                blue: &otherBlue,
                alpha: &otherAlpha
              ) else { return self }
        let fraction = min(max(amount, 0), 1)
        return UIColor(
            red: red + (otherRed - red) * fraction,
            green: green + (otherGreen - green) * fraction,
            blue: blue + (otherBlue - blue) * fraction,
            alpha: alpha + (otherAlpha - alpha) * fraction
        )
    }

    func reducingSaturation(by amount: CGFloat) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return self
        }
        return UIColor(
            hue: hue,
            saturation: max(0, saturation * (1 - amount)),
            brightness: brightness,
            alpha: alpha
        )
    }
}
