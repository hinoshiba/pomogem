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
        isTutorial: Bool = false
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
    }

    init(session: StudySession) {
        self.init(
            id: session.id,
            subjectName: session.displaySubjectName,
            colorHex: session.displaySubjectColorHex,
            source: session.source,
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
    var aggregateLevel: Int { aggregate?.level ?? 0 }
    var participatesInAggregation: Bool { !isAchievement && !isTutorial }
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
        return switch source {
        case .timer:
            true
        case .manual, .timerDemoted:
            false
        }
    }

    var accessibilityDescription: String {
        if let aggregate {
            return "\(aggregate.accessibilityDescription)、\(grams)グラム"
        }
        if let achievementKind {
            return "\(subjectName)、\(achievementKind.title)の記念石、質量には含まれません"
        }
        let measurement = isMeasured ? "実測" : "自己申告"
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
        case .timer, .timerDemoted:
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
    let radius: CGFloat

    private(set) var hasLanded = false
    private(set) var lastObservedPosition: CGPoint = .zero
    private(set) var isRemovedForBake = false
    private var reducesVisualMotion: Bool
    private(set) var rareRewardMode: RareRewardMode
    private var contactShadowNode: SKShapeNode?
    private var contactCausticNode: SKShapeNode?
    private var dimensionalLightNode: SKSpriteNode?
    private var aggregateAuraNode: SKShapeNode?
    private var earlyEffortAuraNode: SKShapeNode?
    private var earlyEffortBloomNode: SKShapeNode?
    private var aggregateCountNode: SKLabelNode?
    private var achievementMarkBackdropNode: SKShapeNode?
    private var achievementMarkNode: SKLabelNode?

    var subjectColor: UIColor { JarPalette.color(hex: descriptor.colorHex) }
    private var presentsRareRewardFeature: Bool {
        RareRewardReleasePolicy.permitsInternalTestOverride(true)
    }
    private var presentationKind: PebbleKind {
        presentsRareRewardFeature ? descriptor.kind : .normal
    }

    init(
        descriptor: PebbleDescriptor,
        reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled,
        rareRewardMode: RareRewardMode = .standard
    ) {
        self.descriptor = descriptor
        self.radius = descriptor.radius
        self.reducesVisualMotion = reduceMotion
        self.rareRewardMode = rareRewardMode
        super.init()
        configureAppearance()
        configurePhysics()
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
        radius = Constants.Jar.measuredRadius
        reducesVisualMotion = UIAccessibility.isReduceMotionEnabled
        rareRewardMode = .standard
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

    /// SpriteKit shaders keep animating independently of SKActions. Updating
    /// the shader explicitly is therefore required when Reduce Motion changes
    /// while the bottle is already on screen.
    func setReduceMotion(_ enabled: Bool) {
        guard reducesVisualMotion != enabled else { return }
        reducesVisualMotion = enabled
        configureAggregateAuraMotion()
        configureEarlyEffortAuraMotion()
        guard presentationKind == .prism, !descriptor.isAggregate else { return }
        fillShader = rareRewardMode.usesEnhancedPresentation
            ? (enabled ? Self.staticPrismShader : Self.prismShader)
            : nil
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
              !descriptor.isAggregate else {
            earlyEffortAuraNode?.removeFromParent()
            earlyEffortAuraNode = nil
            earlyEffortBloomNode?.removeFromParent()
            earlyEffortBloomNode = nil
            return
        }
        guard enabled else {
            earlyEffortAuraNode?.removeFromParent()
            earlyEffortAuraNode = nil
            earlyEffortBloomNode?.removeFromParent()
            earlyEffortBloomNode = nil
            return
        }
        if earlyEffortAuraNode == nil {
            // A 520pt bottle makes an honest 11.5pt first stone look like
            // debris. Keep its collision body exact, but give the first three
            // efforts a presentation-only pool of light large enough to read
            // at arm's length.
            let bloom = SKShapeNode(circleOfRadius: radius * 1.72)
            bloom.name = "pebble.earlyEffortBloom"
            bloom.fillColor = visualAccentColor.withAlphaComponent(0.10)
            bloom.strokeColor = .clear
            bloom.glowWidth = radius * 1.02
            bloom.zPosition = -0.52
            addChild(bloom)
            earlyEffortBloomNode = bloom

            let aura = SKShapeNode(circleOfRadius: radius * 2.08)
            aura.name = "pebble.earlyEffortAura"
            aura.fillColor = .clear
            aura.strokeColor = visualAccentColor.withAlphaComponent(0.68)
            aura.lineWidth = max(1.15, radius * 0.085)
            aura.glowWidth = radius * 1.02
            aura.zPosition = -0.45
            addChild(aura)
            earlyEffortAuraNode = aura
        }
        configureEarlyEffortAuraMotion()
    }

    private func configureEarlyEffortAuraMotion() {
        guard let aura = earlyEffortAuraNode else { return }
        let key = "pebble.earlyEffortAura.breath"
        aura.removeAction(forKey: key)
        aura.setScale(1)
        aura.alpha = 1
        earlyEffortBloomNode?.removeAction(forKey: key)
        earlyEffortBloomNode?.setScale(1)
        earlyEffortBloomNode?.alpha = 1
        guard !reducesVisualMotion else { return }
        let expand = SKAction.group([
            .scale(to: 1.10, duration: 1.15),
            .fadeAlpha(to: 0.58, duration: 1.15)
        ])
        expand.timingMode = .easeInEaseOut
        let contract = SKAction.group([
            .scale(to: 1, duration: 1.15),
            .fadeAlpha(to: 1, duration: 1.15)
        ])
        contract.timingMode = .easeInEaseOut
        aura.run(.repeatForever(.sequence([expand, contract])), withKey: key)
        let bloomExpand = SKAction.group([
            .scale(to: 1.07, duration: 1.15),
            .fadeAlpha(to: 0.72, duration: 1.15)
        ])
        bloomExpand.timingMode = .easeInEaseOut
        let bloomContract = SKAction.group([
            .scale(to: 1, duration: 1.15),
            .fadeAlpha(to: 1, duration: 1.15)
        ])
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
            x: horizontal * radius * 0.12,
            y: -radius * 0.63
        )
        for contactNode in [contactShadowNode, contactCausticNode].compactMap({ $0 }) {
            contactNode.position = CGPoint(
                x: cosine * worldOffset.x + sine * worldOffset.y,
                y: -sine * worldOffset.x + cosine * worldOffset.y
            )
            contactNode.zRotation = -zRotation
        }

        if let dimensionalLightNode {
            let worldOffset = CGPoint(x: horizontal * radius * 0.055, y: 0)
            dimensionalLightNode.position = CGPoint(
                x: cosine * worldOffset.x + sine * worldOffset.y,
                y: -sine * worldOffset.x + cosine * worldOffset.y
            )
            dimensionalLightNode.zRotation = -zRotation
        }

        // Counts and achievement marks are semantic labels, not painted
        // speckles. Keeping them upright makes ×1万 / 合格 readable even after
        // a user tilts or taps the physical stone.
        aggregateCountNode?.zRotation = -zRotation
        achievementMarkBackdropNode?.zRotation = -zRotation
        achievementMarkNode?.zRotation = -zRotation
    }

    private func configurePhysics() {
        let body = SKPhysicsBody(circleOfRadius: radius)
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
    }

    private func configureAppearance() {
        name = "pebble.\(descriptor.id.uuidString)"
        path = Self.makeStonePath(radius: radius, id: descriptor.id)
        lineWidth = Constants.Jar.outlineWidth
        lineJoin = .round
        zPosition = JarZPosition.pebble
        addContactShadow()

        if let aggregate = descriptor.aggregate {
            configureAggregateAppearance(aggregate)
            addDimensionalOverlay()
            return
        }

        if let achievementKind = descriptor.achievementKind {
            let material = JarPalette.achievementMaterial(for: achievementKind)
            let fill = material.base.mixed(
                with: subjectColor.vivid(saturationFloor: 0.78, brightnessFloor: 0.84),
                amount: 0.18
            )
            fillColor = fill
            strokeColor = material.edge
            lineWidth = Constants.Jar.achievementStrokeWidth
            glowWidth = radius * 0.36
            addDimensionalOverlay()
            addAchievementBevel(edgeColor: material.edge)
            addAchievementMark(achievementKind)
            return
        }

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
            lineWidth = max(1.05, radius * 0.09)
            glowWidth = descriptor.isTutorial ? 0 : radius * 0.10
        case .gold, .prism:
            configureLooseGemMaterial(fill: fill)
        }

        addCachedDetailTexture()
        addDimensionalOverlay()
        addRareMarkIfNeeded()
    }

    private var baseLooseFill: UIColor {
        var fill = subjectColor
        if descriptor.isTutorial {
            fill = JarPalette.glass.withAlphaComponent(Constants.Jar.tutorialOpacity)
        } else {
            fill = fill.vivid(saturationFloor: 0.74, brightnessFloor: 0.88)
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
            lineWidth = max(1.1, radius * 0.10)
            glowWidth = radius * (enhanced ? Constants.Jar.goldGlowScale : 0.10)
        case .prism:
            fillColor = enhanced ? .white : fill.mixed(with: .white, amount: 0.18)
            strokeColor = .white.withAlphaComponent(
                enhanced ? Constants.Jar.prismStrokeOpacity : 0.62
            )
            lineWidth = max(1.05, radius * 0.09)
            glowWidth = radius * (enhanced ? Constants.Jar.prismGlowScale : 0.10)
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
            ellipseOf: CGSize(width: radius * 1.58, height: radius * 0.54)
        )
        shadow.name = "pebble.contactShadow"
        shadow.fillColor = UIColor(red: 0.015, green: 0.03, blue: 0.07, alpha: 0.38)
        shadow.strokeColor = UIColor.black.withAlphaComponent(0.12)
        shadow.lineWidth = max(0.5, radius * 0.035)
        shadow.glowWidth = radius * 0.14
        shadow.alpha = descriptor.isTutorial ? 0.12 : 0.44
        shadow.position = CGPoint(x: 0, y: -radius * 0.63)
        shadow.zPosition = -1
        addChild(shadow)
        contactShadowNode = shadow

        let caustic = SKShapeNode(
            ellipseOf: CGSize(width: radius * 1.22, height: radius * 0.28)
        )
        caustic.name = "pebble.contactCaustic"
        caustic.fillColor = visualAccentColor.withAlphaComponent(
            descriptor.isTutorial ? 0.03 : 0.16
        )
        caustic.strokeColor = UIColor.white.withAlphaComponent(0.12)
        caustic.lineWidth = max(0.45, radius * 0.025)
        caustic.glowWidth = radius * 0.19
        caustic.position = CGPoint(x: 0, y: -radius * 0.63)
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

        let ring = SKShapeNode(circleOfRadius: radius * 0.69)
        ring.name = "rare.innerRing"
        ring.fillColor = .clear
        ring.strokeColor = UIColor.white.withAlphaComponent(0.26)
        ring.lineWidth = max(0.8, radius * 0.06)
        ring.zPosition = JarZPosition.pebbleDetail + 0.4
        addChild(ring)

        let mark = SKLabelNode(fontNamed: "AvenirNext-Bold")
        mark.name = "rare.mark"
        mark.text = markText
        mark.fontSize = radius * (presentationKind == .gold ? 0.82 : 0.74)
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
        let dominant = JarPalette.color(hex: aggregate.dominantColorHex)
            .vivid(saturationFloor: 0.70, brightnessFloor: 0.82)
        let containsRare = presentsRareRewardFeature
            && rareRewardMode.usesEnhancedPresentation
            && (aggregate.goldPebbleCount > 0 || aggregate.prismPebbleCount > 0)
        fillColor = dominant.mixed(
            with: JarPalette.aggregateCore,
            amount: AggregatePresentation.coreBlendAmount(level: aggregate.level)
        )
        strokeColor = dominant.mixed(with: .white, amount: 0.56)
        lineWidth = Constants.Jar.outlineWidth + CGFloat(min(aggregate.level, 5)) * 0.48
        // Every aggregate is earned. Rarity may add sparkle, but a ×10万
        // crystal must never look dull simply because its children were normal.
        glowWidth = radius * AggregatePresentation.glowScale(
            level: aggregate.level,
            containsRare: containsRare
        )

        let aura = SKShapeNode(path: Self.makeStonePath(radius: radius * 1.06, id: descriptor.id))
        aura.name = "aggregate.aura"
        aura.fillColor = .clear
        aura.strokeColor = dominant.withAlphaComponent(0.34)
        aura.lineWidth = max(1, radius * 0.07)
        aura.glowWidth = radius * AggregatePresentation.glowScale(
            level: aggregate.level,
            containsRare: containsRare
        )
        aura.zPosition = -0.35
        addChild(aura)
        aggregateAuraNode = aura
        updateAggregateRarePresentation(aggregate)
        configureAggregateAuraMotion()

        let composition = SKSpriteNode(
            texture: Self.makeAggregateTexture(
                radius: radius,
                aggregate: aggregate,
                presentsRareRewards: presentsRareRewardFeature
                    && rareRewardMode.usesEnhancedPresentation
            ),
            size: CGSize(width: radius * 2, height: radius * 2)
        )
        composition.name = "aggregate.composition"
        composition.zPosition = JarZPosition.pebbleDetail
        addChild(composition)

        let ringCount = AggregatePresentation.ringCount(level: aggregate.level)
        for index in 0..<ringCount {
            let inset = CGFloat(index + 1) * radius * 0.105
            let ring = SKShapeNode(circleOfRadius: max(radius - inset, radius * 0.42))
            ring.name = "aggregate.levelRing"
            ring.fillColor = .clear
            ring.strokeColor = UIColor.white.withAlphaComponent(0.14 + CGFloat(index) * 0.025)
            ring.lineWidth = Constants.Jar.aggregateRingWidth
            ring.zPosition = JarZPosition.pebbleDetail
            addChild(ring)
        }

        let count = SKLabelNode(fontNamed: "AvenirNext-Bold")
        count.name = "aggregate.count"
        count.text = AggregatePresentation.countLabel(aggregate.pebbleCount)
        let characterCount = CGFloat(count.text?.count ?? 2)
        count.fontSize = radius * max(0.27, 0.43 - max(0, characterCount - 3) * 0.025)
        count.fontColor = UIColor.white.withAlphaComponent(0.96)
        count.verticalAlignmentMode = .center
        count.horizontalAlignmentMode = .center
        count.zPosition = JarZPosition.pebbleDetail + 1
        count.blendMode = .alpha
        addChild(count)
        aggregateCountNode = count
    }

    private func updateAggregateRarePresentation(_ aggregate: AggregateMetadata) {
        let containsEnhancedRare = presentsRareRewardFeature
            && rareRewardMode.usesEnhancedPresentation
            && (aggregate.goldPebbleCount > 0 || aggregate.prismPebbleCount > 0)
        let glow = radius * AggregatePresentation.glowScale(
            level: aggregate.level,
            containsRare: containsEnhancedRare
        )
        glowWidth = glow
        aggregateAuraNode?.glowWidth = glow
    }

    private func configureAggregateAuraMotion() {
        guard let aura = aggregateAuraNode else { return }
        let actionKey = "aggregate.aura.breath"
        aura.removeAction(forKey: actionKey)
        aura.setScale(1)
        aura.alpha = 1
        guard !reducesVisualMotion else { return }

        let level = descriptor.aggregate?.level ?? 1
        let amplitude = min(1.07, 1.025 + CGFloat(level) * 0.009)
        let duration = max(1.8, 2.7 - Double(min(level, 5)) * 0.12)
        let expand = SKAction.group([
            .scale(to: amplitude, duration: duration / 2),
            .fadeAlpha(to: 0.68, duration: duration / 2)
        ])
        expand.timingMode = .easeInEaseOut
        let contract = SKAction.group([
            .scale(to: 1, duration: duration / 2),
            .fadeAlpha(to: 1, duration: duration / 2)
        ])
        contract.timingMode = .easeInEaseOut
        aura.run(.repeatForever(.sequence([expand, contract])), withKey: actionKey)
    }

    private static func makeAggregateTexture(
        radius: CGFloat,
        aggregate: AggregateMetadata,
        presentsRareRewards: Bool
    ) -> SKTexture {
        let size = CGSize(width: radius * 2, height: radius * 2)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let mixes = aggregate.colorMix.isEmpty
                ? [StratumColorFraction(hex: Constants.Color.textMute, fraction: 1)]
                : aggregate.colorMix
            let dotCount = max(
                Constants.Jar.aggregateInteriorDotCount,
                AggregatePresentation.facetCount(level: aggregate.level) * 2
            )
            var cumulative: [(fraction: Double, color: UIColor)] = []
            var cursor = 0.0
            for item in mixes {
                cursor += max(0, item.fraction)
                cumulative.append((cursor, JarPalette.color(hex: item.hex)))
            }

            for index in 0..<dotCount {
                let unit = (Double(index) + 0.5) / Double(dotCount)
                let color = cumulative.first(where: { unit <= $0.fraction })?.color
                    ?? cumulative.last?.color
                    ?? JarPalette.aggregateCore
                let angle = CGFloat(index) * 2.399963229728653
                let radial = sqrt(CGFloat(index + 1) / CGFloat(dotCount + 1)) * radius * 0.70
                let center = CGPoint(
                    x: radius + cos(angle) * radial,
                    y: radius + sin(angle) * radial
                )
                let dotRadius = max(1.4, radius * Constants.Jar.aggregateInteriorDotScale)
                context.setFillColor(color.withAlphaComponent(0.88).cgColor)
                let chip = CGMutablePath()
                chip.move(to: CGPoint(x: center.x, y: center.y - dotRadius))
                chip.addLine(to: CGPoint(x: center.x + dotRadius * 0.78, y: center.y))
                chip.addLine(to: CGPoint(x: center.x, y: center.y + dotRadius))
                chip.addLine(to: CGPoint(x: center.x - dotRadius * 0.78, y: center.y))
                chip.closeSubpath()
                context.addPath(chip)
                context.fillPath()
                context.setStrokeColor(UIColor.white.withAlphaComponent(0.16).cgColor)
                context.setLineWidth(max(0.35, radius * 0.018))
                context.addPath(chip)
                context.strokePath()
            }

            if aggregate.manualPebbleCount > 0 {
                let ringRadius = radius * 0.83
                context.setStrokeColor(UIColor.white.withAlphaComponent(0.55).cgColor)
                context.setLineWidth(max(1, radius * 0.06))
                context.setLineDash(phase: 0, lengths: [radius * 0.12, radius * 0.13])
                context.strokeEllipse(in: CGRect(
                    x: radius - ringRadius,
                    y: radius - ringRadius,
                    width: ringRadius * 2,
                    height: ringRadius * 2
                ))
                context.setLineDash(phase: 0, lengths: [])
            }

            if presentsRareRewards,
               aggregate.goldPebbleCount > 0 {
                context.setFillColor(JarPalette.gold.withAlphaComponent(0.95).cgColor)
                drawAggregateFacet(
                    in: context,
                    center: CGPoint(x: radius * 1.61, y: radius * 0.41),
                    size: radius * 0.13
                )
            }
            if presentsRareRewards,
               aggregate.prismPebbleCount > 0 {
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

    private func addAchievementMark(_ achievementKind: AchievementKind) {
        let material = JarPalette.achievementMaterial(for: achievementKind)
        let badgeSize: CGSize
        let fontScale: CGFloat
        switch achievementKind {
        case .perfectScore:
            badgeSize = CGSize(width: radius * 1.64, height: radius * 0.98)
            fontScale = 0.68
        case .examPass:
            badgeSize = CGSize(width: radius * 1.10, height: radius * 1.10)
            fontScale = 0.88
        case .workMilestone:
            badgeSize = CGSize(width: radius * 1.14, height: radius * 1.08)
            fontScale = 0.76
        }

        // The jewel gradients deliberately run bright and saturated. A fixed,
        // opaque ink plate keeps every semantic mark readable independently of
        // hue, while the kind-specific rim preserves the vivid material identity.
        let backdrop = SKShapeNode(
            rectOf: badgeSize,
            cornerRadius: badgeSize.height / 2
        )
        backdrop.name = "achievement.markBackdrop"
        backdrop.fillColor = UIColor(
            red: 0.018,
            green: 0.039,
            blue: 0.075,
            alpha: 1
        )
        backdrop.strokeColor = material.edge.mixed(with: .white, amount: 0.22)
        backdrop.lineWidth = max(1.1, radius * 0.085)
        backdrop.glowWidth = radius * 0.12
        backdrop.zPosition = JarZPosition.pebbleDetail + 0.55
        backdrop.blendMode = .alpha
        addChild(backdrop)
        achievementMarkBackdropNode = backdrop

        let mark = SKLabelNode(fontNamed: "AvenirNext-Bold")
        mark.name = "achievement.mark"
        mark.text = achievementKind.shortMark
        mark.fontSize = radius * fontScale
        mark.fontColor = .white
        mark.verticalAlignmentMode = .center
        mark.horizontalAlignmentMode = .center
        mark.zPosition = JarZPosition.pebbleDetail + 0.65
        mark.blendMode = .alpha
        mark.accessibilityLabel = achievementKind.title
        addChild(mark)
        achievementMarkNode = mark
    }

    private func addAchievementBevel(edgeColor: UIColor) {
        let bevel = SKShapeNode(path: Self.makeStonePath(radius: radius, id: descriptor.id))
        bevel.name = "achievement.bevel"
        bevel.fillColor = .clear
        bevel.strokeColor = UIColor.white.withAlphaComponent(0.46)
        bevel.lineWidth = max(0.8, radius * 0.055)
        bevel.setScale(0.78)
        bevel.zPosition = JarZPosition.pebbleDetail + 0.2
        addChild(bevel)

        let glint = SKShapeNode(rectOf: CGSize(width: radius * 0.20, height: radius * 0.20))
        glint.name = "achievement.glint"
        glint.fillColor = edgeColor.withAlphaComponent(0.88)
        glint.strokeColor = UIColor.white.withAlphaComponent(0.72)
        glint.lineWidth = max(0.45, radius * 0.025)
        glint.zRotation = .pi / 4
        glint.position = CGPoint(x: -radius * 0.34, y: radius * 0.30)
        glint.zPosition = JarZPosition.pebbleDetail + 0.4
        glint.glowWidth = radius * 0.12
        addChild(glint)
    }

    private func addCachedDetailTexture() {
        let variantCount = max(Constants.Jar.speckleCount, 1)
        let byteSum = descriptor.id.uuidString.utf8.reduce(Int.zero) {
            $0 + Int($1)
        }
        let variant = byteSum % variantCount
        let key = NSString(
            string: "\(radius)-\(descriptor.isMeasured)-\(variant)"
        )
        let texture: SKTexture
        if let cached = Self.detailTextureCache.object(forKey: key) {
            texture = cached
        } else {
            texture = Self.makeDetailTexture(
                radius: radius,
                isMeasured: descriptor.isMeasured,
                variant: variant
            )
            Self.detailTextureCache.setObject(texture, forKey: key)
        }

        let detail = SKSpriteNode(
            texture: texture,
            size: CGSize(width: radius * 2, height: radius * 2)
        )
        detail.zPosition = JarZPosition.pebbleDetail
        addChild(detail)
    }

    private func addDimensionalOverlay() {
        let texture = Self.makeDimensionalTexture(radius: radius)
        let light = SKSpriteNode(
            texture: texture,
            size: CGSize(width: radius * 1.78, height: radius * 1.78)
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
